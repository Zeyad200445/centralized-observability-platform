import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

from .agent import ES_MCP_URL, K8S_MCP_URL, PROM_MCP_URL, run_triage
from .schemas import AlertItem, AlertmanagerPayload, TriageRecord

logger = logging.getLogger("triage-service")

COOLDOWN_SECONDS = int(os.getenv("TRIAGE_COOLDOWN_MINUTES", "10")) * 60
OUTPUT_DIR = Path(os.getenv("TRIAGE_OUTPUT_DIR", "/tmp/triage-reports"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Prometheus self-metrics
TRIAGE_RUNS = Counter("triage_runs_total", "Total alert triage runs", ["alertname", "outcome"])
TRIAGE_DURATION = Histogram("triage_duration_seconds", "Alert triage duration in seconds", ["alertname"])
TRIAGE_TOOL_CALLS = Counter("triage_tool_calls_total", "Total MCP tool calls made by triage agent", ["alertname"])

# In-memory state + sequential worker queue
_queue: asyncio.Queue[AlertItem] = asyncio.Queue()
_records: dict[str, TriageRecord] = {}
_last_seen: dict[str, float] = {}


def _save_report(record: TriageRecord) -> None:
    json_path = OUTPUT_DIR / f"{record.fingerprint}.json"
    json_path.write_text(record.model_dump_json(indent=2), encoding="utf-8")

    md_path = OUTPUT_DIR / f"{record.fingerprint}.md"
    if record.note:
        ev = "\n".join(f"- {e}" for e in record.note.evidence)
        cmds = "\n".join(f"```bash\n{c}\n```" for c in record.note.suggested_commands)
        md = (
            f"# Triage Report: {record.alertname} (`{record.fingerprint}`)\n\n"
            f"- **Outcome:** {record.outcome} | **Confidence:** {record.note.confidence} | "
            f"**Duration:** {record.duration_seconds}s | **Tool Calls:** {record.tool_calls}\n\n"
            f"## Summary\n{record.note.summary}\n\n"
            f"## Evidence\n{ev}\n\n"
            f"## Likely Cause\n{record.note.likely_cause}\n\n"
            f"## Suggested Commands\n{cmds}\n"
        )
    else:
        md = (
            f"# Triage Report: {record.alertname} (`{record.fingerprint}`)\n\n"
            f"- **Outcome:** failed | **Error:** `{record.error}`\n"
        )
    md_path.write_text(md, encoding="utf-8")


async def _worker() -> None:
    while True:
        alert = await _queue.get()
        try:
            record = await run_triage(alert)
            _records[record.fingerprint] = record
            _save_report(record)

            TRIAGE_RUNS.labels(alertname=record.alertname, outcome=record.outcome).inc()
            TRIAGE_DURATION.labels(alertname=record.alertname).observe(record.duration_seconds)
            TRIAGE_TOOL_CALLS.labels(alertname=record.alertname).inc(record.tool_calls)

            logger.info(
                json.dumps(
                    {
                        "event": "triage_complete",
                        "fingerprint": record.fingerprint,
                        "alertname": record.alertname,
                        "outcome": record.outcome,
                        "confidence": record.note.confidence if record.note else None,
                        "duration_seconds": record.duration_seconds,
                        "tool_calls": record.tool_calls,
                    }
                )
            )
        except Exception as exc:
            logger.exception("Unhandled error in triage worker: %s", exc)
        finally:
            _queue.task_done()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    task = asyncio.create_task(_worker())
    yield
    task.cancel()


app = FastAPI(title="Layer E Alert-Triage Agent", version="1.0.0", lifespan=lifespan)


@app.post("/alert")
async def receive_alert(payload: AlertmanagerPayload) -> dict[str, Any]:
    now = time.monotonic()
    queued: list[str] = []
    skipped: list[str] = []

    for alert in payload.alerts:
        if alert.status != "firing":
            skipped.append(f"{alert.fingerprint}:resolved")
            continue
        last = _last_seen.get(alert.fingerprint)
        if last is not None and (now - last) < COOLDOWN_SECONDS:
            skipped.append(f"{alert.fingerprint}:cooldown")
            continue

        _last_seen[alert.fingerprint] = now
        await _queue.put(alert)
        queued.append(alert.fingerprint)

    return {"status": "accepted", "queued": queued, "skipped": skipped}


@app.get("/triage/{fingerprint}")
async def get_triage(fingerprint: str) -> dict[str, Any]:
    if fingerprint in _records:
        return _records[fingerprint].model_dump()
    json_path = OUTPUT_DIR / f"{fingerprint}.json"
    if json_path.is_file():
        return json.loads(json_path.read_text(encoding="utf-8"))
    raise HTTPException(status_code=404, detail=f"No triage report found for '{fingerprint}'")


@app.get("/healthz")
async def healthz() -> dict[str, Any]:
    checks: dict[str, str] = {}
    async with httpx.AsyncClient(timeout=3.0) as client:
        for name, url in [
            ("prometheus_mcp", PROM_MCP_URL),
            ("elasticsearch_mcp", ES_MCP_URL),
            ("kubernetes_mcp", K8S_MCP_URL),
        ]:
            try:
                r = await client.get(url)
                checks[name] = "ok" if r.status_code < 500 else f"http_{r.status_code}"
            except Exception as exc:
                checks[name] = f"unreachable:{type(exc).__name__}"

    all_ok = all(v == "ok" for v in checks.values())
    return {"status": "ok" if all_ok else "degraded", "queue_size": _queue.qsize(), "mcp_servers": checks}


@app.get("/metrics")
async def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
