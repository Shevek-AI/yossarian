FROM python:3.12-slim-bookworm

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY app.py /app/app.py
COPY static /app/static

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
