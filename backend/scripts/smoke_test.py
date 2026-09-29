"""배포 전후 스모크 테스트: /api/uploads → GCS PUT → /api/analyze 전 과정을 실제로 돌려 본다.

사용법 (backend/ 에서, gcloud auth application-default login 이후):
    python scripts/smoke_test.py <오디오> [--photo 사진 ...] [--server 주소] [--duration 초]

    예) python scripts/smoke_test.py sample.m4a --duration 47
        python scripts/smoke_test.py sample.wav --photo a.jpg --photo b.png
        python scripts/smoke_test.py sample.m4a --duration 47 --server https://rapid-backend-xxxx.a.run.app

- 토큰(APP_TOKEN)과 PROJECT_ID·BUCKET은 backend/.env에서 읽는다. 토큰 값은 출력하지 않는다.
- --duration을 빼면 .wav는 파일에서 길이를 읽고, 그 외 형식은 오류로 멈춘다.
- 정상 분석 뒤 실패 확인(토큰 없음 401, 1초 녹음 → 빈 결과 + 원본 삭제)도 돌린다.
  --skip-failure-checks로 끌 수 있다.
- 이 스크립트가 만든 Firestore metrics 기록은 지우지 않고 test: true와
  case("normal" | "failure_check")를 덧붙여 실제 기록과 구분한다.
- 하나라도 실패하면 종료 코드 1.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from dotenv import load_dotenv
from google.cloud import firestore, storage

BACKEND_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BACKEND_DIR / ".env")

AUDIO_TYPES = {".m4a": "audio/mp4", ".mp4": "audio/mp4", ".wav": "audio/wav"}
PHOTO_TYPES = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png"}
MAX_PHOTOS = 3
EMPTY_FIELDS = (
    "chief_complaint", "past_history", "onset", "last_normal_time",
    "guardian", "etc", "ai_impression",
)


class Checks:
    """확인 항목의 통과/실패를 모아 마지막에 요약한다."""

    def __init__(self) -> None:
        self.results: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append((name, ok, detail))
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {name}" + (f" — {detail}" if detail else ""))
        return ok

    @property
    def failed(self) -> int:
        return sum(1 for _, ok, _ in self.results if not ok)


def section(title: str) -> None:
    print(f"\n=== {title} " + "=" * max(0, 60 - len(title)))


def show_json(data: object) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def http(method: str, url: str, *, headers: dict | None = None, body: bytes | None = None,
         timeout: float = 100) -> tuple[int, bytes, float]:
    """(상태코드, 본문, 소요 ms)를 돌려준다. 4xx/5xx도 예외 대신 코드로 돌려준다."""
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            status, data = res.status, res.read()
    except urllib.error.HTTPError as e:
        status, data = e.code, e.read()
    return status, data, (time.perf_counter() - started) * 1000


def post_json(server: str, path: str, payload: dict, token: str | None) -> tuple[int, object, float]:
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-RAPID-Token"] = token
    status, data, ms = http(
        "POST", f"{server}{path}", headers=headers,
        body=json.dumps(payload).encode(),
    )
    try:
        parsed = json.loads(data.decode("utf-8"))
    except ValueError:
        parsed = data.decode("utf-8", errors="replace")
    return status, parsed, ms


def upload_session(server: str, token: str, audio: Path, photos: list[Path],
                   checks: Checks) -> tuple[dict, dict] | None:
    """/api/uploads로 주소를 받아 PUT까지 한다. (uploads 응답, 단계별 ms)를 돌려준다."""
    timings: dict[str, float] = {}
    payload = {
        "audio_mime": AUDIO_TYPES[audio.suffix.lower()],
        "photo_mimes": [PHOTO_TYPES[p.suffix.lower()] for p in photos],
    }
    status, uploads, timings["uploads"] = post_json(server, "/api/uploads", payload, token)
    if not checks.check("/api/uploads 200", status == 200, f"{status}"):
        show_json(uploads)
        return None
    print(f"  session_id = {uploads['session_id']}")

    targets = [(uploads["audio"], audio)] + list(zip(uploads["photos"], photos))
    put_started = time.perf_counter()
    for target, path in targets:
        status, data, ms = http(
            target["method"], target["url"], headers=target["headers"],
            body=path.read_bytes(), timeout=120,
        )
        name = target["object"].rsplit("/", 1)[-1]
        if not checks.check(f"PUT {name}", status == 200, f"{status}, {ms:.0f}ms, {path.stat().st_size:,} bytes"):
            print(data.decode("utf-8", errors="replace")[:300])
            return None
    timings["put"] = (time.perf_counter() - put_started) * 1000
    return uploads, timings


def analyze(server: str, token: str, uploads: dict, duration: int,
            upload_ms: float | None) -> tuple[int, object, float]:
    payload = {
        "session_id": uploads["session_id"],
        "audio_object": uploads["audio"]["object"],
        "photo_objects": [p["object"] for p in uploads["photos"]],
        "duration_seconds": duration,
        "client_upload_ms": round(upload_ms) if upload_ms is not None else None,
    }
    return post_json(server, "/api/analyze", payload, token)


def verify_cleanup(bucket: storage.Bucket, db: firestore.Client, session_id: str,
                   case: str, checks: Checks) -> dict | None:
    """세션 원본이 지워졌는지 보고, metrics를 읽어 test·case 표시를 덧붙인다."""
    left = [b.name for b in bucket.list_blobs(prefix=f"sessions/{session_id}/")]
    checks.check("GCS 세션 원본 삭제됨", not left, f"남은 객체 {left}" if left else "")

    ref = db.collection("metrics").document(session_id)
    snap = ref.get()
    if not checks.check("Firestore metrics 기록 있음", snap.exists):
        return None
    # 스모크 테스트 기록은 지우지 않고 표시만 남겨 실제 기록과 구분한다.
    ref.update({"test": True, "case": case})
    return ref.get().to_dict()


def print_metrics(metrics: dict) -> None:
    keys = (
        "test", "case", "success", "error_type", "skipped", "prompt_version",
        "prompt_missing_now", "model", "vertex_location", "duration_seconds",
        "audio_bytes", "photo_count", "photo_bytes_total", "audio_tokens",
        "retries", "retries_by_code", "finish_reason", "delete_ok", "timings_ms",
    )
    show_json({k: metrics.get(k) for k in keys})


def main() -> int:
    parser = argparse.ArgumentParser(description="RAPID 백엔드 스모크 테스트")
    parser.add_argument("audio", type=Path, help="오디오 파일(.m4a/.wav)")
    parser.add_argument("--photo", type=Path, action="append", default=[],
                        help=f"사진 파일(.jpg/.png), 최대 {MAX_PHOTOS}장 — 여러 번 지정")
    parser.add_argument("--server", default="http://127.0.0.1:8000", help="서버 주소")
    parser.add_argument("--duration", type=int, help="녹음 길이(초). .wav는 생략 가능")
    parser.add_argument("--skip-failure-checks", action="store_true",
                        help="토큰 없음·1초 녹음 확인을 건너뛴다")
    args = parser.parse_args()

    server = args.server.rstrip("/")
    token = os.environ.get("APP_TOKEN", "")
    project_id = os.environ.get("PROJECT_ID", "")
    bucket_name = os.environ.get("BUCKET", "")
    missing = [n for n, v in (("APP_TOKEN", token), ("PROJECT_ID", project_id), ("BUCKET", bucket_name)) if not v]
    if missing:
        parser.error(f"backend/.env에 {', '.join(missing)}이(가) 없습니다")

    if not args.audio.is_file() or args.audio.suffix.lower() not in AUDIO_TYPES:
        parser.error(f"오디오 파일을 확인하세요(.m4a/.wav): {args.audio}")
    if len(args.photo) > MAX_PHOTOS:
        parser.error(f"사진은 최대 {MAX_PHOTOS}장입니다")
    for p in args.photo:
        if not p.is_file() or p.suffix.lower() not in PHOTO_TYPES:
            parser.error(f"사진 파일을 확인하세요(.jpg/.png): {p}")

    duration = args.duration
    if duration is None:
        if args.audio.suffix.lower() != ".wav":
            parser.error(".wav가 아니면 --duration(초)을 지정하세요")
        with wave.open(str(args.audio)) as w:
            duration = round(w.getnframes() / w.getframerate())

    bucket = storage.Client(project=project_id).bucket(bucket_name)
    db = firestore.Client(project=project_id)
    checks = Checks()

    print(f"서버 {server} / 오디오 {args.audio.name} ({duration}초) / 사진 {len(args.photo)}장")
    print("토큰: backend/.env의 APP_TOKEN (값은 출력하지 않음)")

    section("0. health")
    status, data, ms = http("GET", f"{server}/api/health", timeout=10)
    checks.check("/api/health 200", status == 200, f"{status}, {ms:.0f}ms")
    if status == 200:
        show_json(json.loads(data))

    section("1. 정상 분석 (case: normal)")
    uploaded = upload_session(server, token, args.audio, args.photo, checks)
    if uploaded:
        uploads, timings = uploaded
        status, result, timings["analyze"] = analyze(
            server, token, uploads, duration, timings["put"]
        )
        analyzed = checks.check("/api/analyze 200", status == 200, f"{status}")
        print("\n  결과 JSON:")
        show_json(result)

        # 한글 라벨은 폭이 달라 줄이 안 맞으므로 숫자를 앞에 둔다.
        print("\n  단계별 소요시간(클라이언트 측정):")
        for name, label in (("uploads", "URL 발급"), ("put", "GCS PUT"), ("analyze", "분석 요청")):
            print(f"    {timings[name]:>8.0f} ms  {label}")
        print(f"    {sum(timings.values()):>8.0f} ms  합계")

        print("\n  사후 확인:")
        metrics = verify_cleanup(bucket, db, uploads["session_id"], "normal", checks)
        if metrics:
            checks.check(
                "prompt_version이 Firestore 프롬프트",
                metrics.get("prompt_version") not in (None, "builtin"),
                f"prompt_version={metrics.get('prompt_version')}",
            )
            if analyzed:  # 모델 호출이 실패했으면 토큰 사용량 자체가 없다
                checks.check("AUDIO 토큰 있음", bool(metrics.get("audio_tokens")),
                             f"audio_tokens={metrics.get('audio_tokens')}")
            print("\n  metrics:")
            print_metrics(metrics)

    if not args.skip_failure_checks:
        section("2. 실패 확인: 토큰 없음 (401)")
        status, data, _ = post_json(
            server, "/api/uploads", {"audio_mime": AUDIO_TYPES[args.audio.suffix.lower()]}, None
        )
        checks.check("토큰 없이 /api/uploads → 401", status == 401, f"{status} {data}")

        section("3. 실패 확인: 1초 녹음 (case: failure_check)")
        uploaded = upload_session(server, token, args.audio, [], checks)
        if uploaded:
            uploads, _ = uploaded
            status, result, _ = analyze(server, token, uploads, 1, None)
            is_empty = (
                status == 200 and isinstance(result, dict)
                and all(result.get(f) == "" for f in EMPTY_FIELDS)
                and result.get("reasons") == []
            )
            checks.check("1초 녹음 → 빈 결과", is_empty, f"{status}")
            metrics = verify_cleanup(bucket, db, uploads["session_id"], "failure_check", checks)
            if metrics:
                checks.check("metrics skipped=too_short", metrics.get("skipped") == "too_short",
                             f"skipped={metrics.get('skipped')}")

    section("요약")
    total = len(checks.results)
    print(f"  {total - checks.failed}/{total} 통과")
    for name, ok, detail in checks.results:
        if not ok:
            print(f"  FAIL: {name} {detail}")
    return 1 if checks.failed else 0


if __name__ == "__main__":
    sys.exit(main())
