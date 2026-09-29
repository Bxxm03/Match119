# 로컬 개발 환경(Python 3.13)과 같은 버전을 쓴다.
FROM python:3.13-slim

# 로그가 버퍼에 쌓이지 않고 바로 Cloud Run 로그에 찍히게 한다.
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# 라이브러리 목록만 먼저 복사해 설치한다 — 코드만 바뀌었을 땐 이 단계를 캐시로 건너뛴다.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Cloud Run이 PORT 환경변수로 포트를 알려준다(로컬 실행 시 기본 8080).
CMD uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}
