FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --create-home --uid 10001 appuser && mkdir -p /data/triage && chown -R appuser:appuser /data/triage
USER appuser

ENV TRIAGE_OUTPUT_DIR=/data/triage
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
