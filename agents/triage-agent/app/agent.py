import httpx
# Compatibility shim for openai >= 2.x InputTokensDetails.cache_write_tokens
try:
    from openai.types.responses.response_usage import InputTokensDetails
    if "cache_write_tokens" in InputTokensDetails.model_fields:
        InputTokensDetails.model_fields["cache_write_tokens"].default = 0
        InputTokensDetails.model_rebuild(force=True)
except Exception:
    pass

import asyncio
import hashlib
import json
import logging
import os
import time
from typing import Any

from openai import AsyncOpenAI
from agents import Agent, ModelSettings, Runner, OpenAIChatCompletionsModel, RunHooks, set_tracing_disabled
from agents.mcp import MCPServerStreamableHttp

from .prompts import SYSTEM_PROMPT, load_runbook
from .schemas import AlertItem, TriageNote, TriageRecord

set_tracing_disabled(True)

logger = logging.getLogger("triage-agent")
logging.basicConfig(level=logging.INFO, format="%(message)s")

LLM_BASE_URL = os.getenv(
    "TRIAGE_LLM_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/"
)
LLM_MODEL = os.getenv("TRIAGE_LLM_MODEL", "gemini-3.5-flash-lite")
LLM_API_KEY = os.getenv("TRIAGE_LLM_API_KEY") or os.getenv("GEMINI_API_KEY", "")

PROM_MCP_URL = os.getenv("PROMETHEUS_MCP_URL", "http://127.0.0.1:8001/mcp")
ES_MCP_URL = os.getenv("ELASTICSEARCH_MCP_URL", "http://127.0.0.1:8002/mcp")
K8S_MCP_URL = os.getenv("KUBERNETES_MCP_URL", "http://127.0.0.1:8003/mcp")

MAX_TOOL_CALLS = int(os.getenv("TRIAGE_MAX_TOOL_CALLS", "8"))
RUN_TIMEOUT_SECONDS = int(os.getenv("TRIAGE_RUN_TIMEOUT", "120"))


class AuditHooks(RunHooks):
    """Logs tool name, args, and result size/hash to stdout — never the result body."""

    def __init__(self, fingerprint: str):
        self.fingerprint = fingerprint
        self.tool_calls = 0

    async def on_tool_start(self, context, agent, tool) -> None:
        self.tool_calls += 1
        logger.info(
            json.dumps(
                {
                    "event": "tool_start",
                    "fingerprint": self.fingerprint,
                    "tool": tool.name,
                    "call_index": self.tool_calls,
                }
            )
        )

    async def on_tool_end(self, context, agent, tool, result: Any) -> None:
        raw = str(result)
        digest = hashlib.sha256(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]
        logger.info(
            json.dumps(
                {
                    "event": "tool_end",
                    "fingerprint": self.fingerprint,
                    "tool": tool.name,
                    "result_bytes": len(raw.encode("utf-8", errors="ignore")),
                    "result_sha256": digest,
                }
            )
        )


def _build_model() -> OpenAIChatCompletionsModel:
    if not LLM_API_KEY:
        raise RuntimeError("Missing TRIAGE_LLM_API_KEY / GEMINI_API_KEY environment variable.")
    client = AsyncOpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY, timeout=60.0, max_retries=1, http_client=httpx.AsyncClient(event_hooks={"request": [_inject_thought_signature]}, timeout=60.0))
    return OpenAIChatCompletionsModel(model=LLM_MODEL, openai_client=client)



async def _inject_thought_signature(request: httpx.Request) -> None:
    if request.method == "POST" and request.content:
        try:
            body = json.loads(request.content)
        except Exception:
            return
        changed = False
        for msg in body.get("messages", []):
            if msg.get("role") == "assistant" and msg.get("tool_calls"):
                for tc in msg["tool_calls"]:
                    if "extra_content" not in tc:
                        tc["extra_content"] = {
                            "google": {"thought_signature": "skip_thought_signature_validator"}
                        }
                        changed = True
        if changed:
            new_bytes = json.dumps(body).encode("utf-8")
            request._content = new_bytes
            request.stream = httpx.ByteStream(new_bytes)
            request.headers["content-length"] = str(len(new_bytes))

async def run_triage(alert: AlertItem) -> TriageRecord:
    start = time.monotonic()
    alertname = alert.labels.get("alertname", "UnknownAlert")
    runbook = load_runbook(alertname)
    hooks = AuditHooks(fingerprint=alert.fingerprint)

    user_prompt = (
        f"Investigate this firing alert:\n"
        f"- Alertname: {alertname}\n"
        f"- Status: {alert.status}\n"
        f"- Labels: {json.dumps(alert.labels)}\n"
        f"- Annotations: {json.dumps(alert.annotations)}\n"
        f"- StartsAt: {alert.startsAt}\n\n"
        f"Applicable Runbook:\n{runbook}\n\n"
        f"Return your final diagnosis strictly as the TriageNote schema."
    )

    prom_srv = MCPServerStreamableHttp(params={"url": PROM_MCP_URL}, name="prometheus-mcp")
    es_srv = MCPServerStreamableHttp(params={"url": ES_MCP_URL}, name="elasticsearch-mcp")
    k8s_srv = MCPServerStreamableHttp(params={"url": K8S_MCP_URL}, name="kubernetes-mcp")

    last_error = None
    async with prom_srv, es_srv, k8s_srv:
        agent = Agent(
            name="AlertTriageAgent",
            instructions=SYSTEM_PROMPT,
            model=_build_model(),
            mcp_servers=[prom_srv, es_srv, k8s_srv],
            output_type=TriageNote,
        )

        # Retry once on malformed output or transient LLM error
        for attempt in range(2):
            try:
                result = await asyncio.wait_for(
                    Runner.run(
                        agent,
                        input=user_prompt,
                        max_turns=MAX_TOOL_CALLS + 2,
                        hooks=hooks,
                    ),
                    timeout=RUN_TIMEOUT_SECONDS,
                )
                note = result.final_output_as(TriageNote)
                duration = round(time.monotonic() - start, 2)
                return TriageRecord(
                    fingerprint=alert.fingerprint,
                    alertname=alertname,
                    outcome="ok",
                    duration_seconds=duration,
                    tool_calls=hooks.tool_calls,
                    note=note,
                    raw_labels=alert.labels,
                )
            except Exception as exc:
                body = getattr(exc, "body", None) or getattr(getattr(exc, "response", None), "text", "")
                last_error = f"attempt {attempt + 1}: {type(exc).__name__}: {exc} | body={body}"
                logger.warning(
                    json.dumps(
                        {
                            "event": "triage_retry",
                            "fingerprint": alert.fingerprint,
                            "error": last_error,
                        }
                    )
                )

    duration = round(time.monotonic() - start, 2)
    return TriageRecord(
        fingerprint=alert.fingerprint,
        alertname=alertname,
        outcome="failed",
        duration_seconds=duration,
        tool_calls=hooks.tool_calls,
        error=last_error,
        raw_labels=alert.labels,
    )
