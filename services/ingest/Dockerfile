FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY local_sync.py /app/local_sync.py

ENTRYPOINT ["python3", "/app/local_sync.py"]
