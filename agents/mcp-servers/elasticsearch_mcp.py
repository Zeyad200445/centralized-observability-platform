import os
from typing import Any, Optional
import httpx
from mcp.server.mcpserver import MCPServer

ES_URL = os.getenv("ELASTICSEARCH_URL", "http://127.0.0.1:9200").rstrip("/")
ES_USER = os.getenv("ELASTICSEARCH_USERNAME", "elastic")
ES_PASS = os.getenv("ELASTICSEARCH_PASSWORD", "")
INDEX_PATTERN = "logstash-k8s-*"
ALLOWED_NAMESPACES = {
    ns.strip()
    for ns in os.getenv("TRIAGE_ALLOWED_NAMESPACES", "workload,monitoring").split(",")
    if ns.strip()
}
MAX_MINUTES = 60
MAX_SIZE = 50
HTTP_TIMEOUT = 15.0

mcp = MCPServer("elasticsearch-mcp")


@mcp.tool()
def search_logs(
    namespace: str,
    pod: Optional[str] = None,
    level: Optional[str] = None,
    text: Optional[str] = None,
    minutes: int = 30,
    size: int = 25,
) -> dict[str, Any]:
    """Search parsed Kubernetes logs in Elasticsearch (logstash-k8s-*) scoped to allowed namespaces."""
    if namespace not in ALLOWED_NAMESPACES:
        raise ValueError(
            f"Namespace '{namespace}' is not allowed. Allowed: {sorted(ALLOWED_NAMESPACES)}"
        )
    if minutes < 1 or minutes > MAX_MINUTES:
        raise ValueError(f"minutes must be between 1 and {MAX_MINUTES}.")
    size = max(1, min(size, MAX_SIZE))

    filters: list[dict[str, Any]] = [
        {"range": {"@timestamp": {"gte": f"now-{minutes}m", "lte": "now"}}},
        {"term": {"kubernetes.namespace": namespace}},
    ]
    if pod:
        filters.append({"prefix": {"kubernetes.pod": pod}})
    if level:
        filters.append({"term": {"log_level": level.upper()}})
    if text:
        filters.append({"match_phrase": {"raw_message": text[:200]}})

    body = {
        "size": size,
        "sort": [{"@timestamp": {"order": "desc"}}],
        "_source": [
            "@timestamp",
            "log_level",
            "http_status",
            "http_method",
            "request_path",
            "raw_message",
            "kubernetes.namespace",
            "kubernetes.pod",
            "kubernetes.container",
        ],
        "query": {"bool": {"filter": filters}},
    }

    auth = (ES_USER, ES_PASS) if ES_PASS else None
    with httpx.Client(timeout=HTTP_TIMEOUT, auth=auth, verify=False) as client:
        resp = client.post(f"{ES_URL}/{INDEX_PATTERN}/_search", json=body)
        resp.raise_for_status()
        data = resp.json()

    hits = data.get("hits", {}).get("hits", [])
    total = data.get("hits", {}).get("total", {}).get("value", len(hits))
    return {
        "namespace": namespace,
        "total_hits": total,
        "returned": len(hits),
        "logs": [h.get("_source", {}) for h in hits],
    }


if __name__ == "__main__":
    port = int(os.getenv("MCP_PORT", "8002"))
    mcp.run(transport="streamable-http", host="0.0.0.0", port=port)
