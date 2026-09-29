"""내장 기본 프롬프트를 Firestore `prompts/current`에 올리는 1회성 스크립트.

사용법 (backend/ 에서, gcloud auth application-default login 이후):
    python seed_prompt.py <버전 이름>
    예) python seed_prompt.py 2026-09-28a

이미 문서가 있으면 덮어쓴다. 서버는 프롬프트를 1분간 캐시하므로,
수정 내용은 캐시 TTL(1분) 내에 반영된다.
"""

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from google.cloud import firestore

from prompts import DEFAULT_PROMPT_TEMPLATE

load_dotenv(Path(__file__).parent / ".env")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("사용법: python seed_prompt.py <버전 이름>")
    version = sys.argv[1]

    project_id = os.environ.get("PROJECT_ID")
    if not project_id:
        sys.exit("PROJECT_ID 환경변수가 필요합니다")

    db = firestore.Client(project=project_id)
    db.collection("prompts").document("current").set({
        "version": version,
        "template": DEFAULT_PROMPT_TEMPLATE,
        "updated_at": firestore.SERVER_TIMESTAMP,
    })
    print(f"prompts/current 갱신 완료 (version={version})")


if __name__ == "__main__":
    main()
