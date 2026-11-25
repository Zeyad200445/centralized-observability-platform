import os
from datetime import datetime, timedelta, timezone
from typing import Any
import httpx
from mcp.server.mcpserver import MCPServer

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://127.0.0.1:9090").rstrip("/")
MAX_QUERY_LEN = 500
MAX_RANGE_MINUTES = 120
MAX_SERIES = 25
HTTP_TIMEOUT = 15.0

mcp = MCPServer("prometheus-mcp")


def _validate_query(promql: str) -> str:
    q = promql.strip()
    if not q:
        raise ValueError("PromQL query cannot be empty.")
    if len(q) > MAX_QUERY_LEN:
        raise ValueError(f"Query exceeds max length of {MAX_QUERY_LEN} chars.")
    return q


@mcp.tool()
def query(promql: str) -> dict[str, Any]:
    """Run an instant read-only PromQL query against Prometheus."""
    q = _validate_query(promql)
    with httpx.Client(timeout=HTTP_TIMEOUT) as client:
        resp = client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": q})
        resp.raise_for_status()
        payload = resp.json()

    results = payload.get("data", {}).get("result", [])
    truncated = len(results) > MAX_SERIES
    return {
        "status": payload.get("status"),
        "result_count": len(results),
        "truncated": truncated,
        "results": results[:MAX_SERIES],
    }


@mcp.tool()
def query_range(promql: str, minutes: int = 30, step: str = "60s") -> dict[str, Any]:
    """Run a read-only PromQL range query over the last N minutes (max 120)."""
    q = _validate_query(promql)
    if minutes < 1 or minutes > MAX_RANGE_MINUTES:
        raise ValueError(f"minutes must be between 1 and {MAX_RANGE_MINUTES}.")

    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=minutes)
    params = {
        "query": q,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "step": step,
    }
    with httpx.Client(timeout=HTTP_TIMEOUT) as client:
        resp = client.get(f"{PROMETHEUS_URL}/api/v1/query_range", params=params)
        resp.raise_for_status()
        payload = resp.json()

    results = payload.get("data", {}).get("result", [])
    truncated = len(results) > MAX_SERIES
    return {
        "status": payload.get("status"),
        "window_minutes": minutes,
        "result_count": len(results),
        "truncated": truncated,
        "results": results[:MAX_SERIES],
    }


@mcp.tool()
def get_alerts() -> dict[str, Any]:
    """Return currently active (pending or firing) Prometheus alerts."""
    with httpx.Client(timeout=HTTP_TIMEOUT) as client:
        resp = client.get(f"{PROMETHEUS_URL}/api/v1/alerts")
        resp.raise_for_status()
        payload = resp.json()

    alerts = payload.get("data", {}).get("alerts", [])
    return {
        "status": payload.get("status"),
        "active_count": len(alerts),
        "alerts": [
            {
                "alertname": a.get("labels", {}).get("alertname"),
                "state": a.get("state"),
                "labels": a.get("labels", {}),
                "annotations": a.get("annotations", {}),
                "activeAt": a.get("activeAt"),
            }
            for a in alerts[:MAX_SERIES]
        ],
    }


if __name__ == "__main__":
    port = int(os.getenv("MCP_PORT", "8001"))
    mcp.run(transport="streamable-http", host="0.0.0.0", port=port)
