FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY prometheus_mcp.py elasticsearch_mcp.py kubernetes_mcp.py ./

RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8001 8002 8003
CMD ["python3", "prometheus_mcp.py"]
