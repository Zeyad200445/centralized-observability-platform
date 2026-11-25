import os
from typing import Any, Optional
from mcp.server.mcpserver import MCPServer
from kubernetes import client, config

ALLOWED_NAMESPACES = {
    ns.strip()
    for ns in os.getenv("TRIAGE_ALLOWED_NAMESPACES", "workload,monitoring,logging").split(",")
    if ns.strip()
}
MAX_LOG_LINES = 50
MAX_LOG_BYTES = 4096

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config(config_file=os.getenv("KUBECONFIG"))

v1 = client.CoreV1Api()
apps_v1 = client.AppsV1Api()

mcp = MCPServer("kubernetes-mcp")


def _check_ns(namespace: str) -> None:
    if namespace not in ALLOWED_NAMESPACES:
        raise ValueError(
            f"Namespace '{namespace}' is not allowed. Allowed: {sorted(ALLOWED_NAMESPACES)}"
        )


@mcp.tool()
def get_pod(namespace: str, pod_name: str) -> dict[str, Any]:
    """Get phase, restarts, and container statuses for a single pod (read-only)."""
    _check_ns(namespace)
    pod = v1.read_namespaced_pod(name=pod_name, namespace=namespace)
    statuses = []
    for cs in pod.status.container_statuses or []:
        state = {}
        if cs.state.running:
            state = {"running_since": str(cs.state.running.started_at)}
        elif cs.state.waiting:
            state = {"waiting_reason": cs.state.waiting.reason, "message": cs.state.waiting.message}
        elif cs.state.terminated:
            state = {
                "terminated_reason": cs.state.terminated.reason,
                "exit_code": cs.state.terminated.exit_code,
            }
        last_state = {}
        if cs.last_state and cs.last_state.terminated:
            last_state = {
                "last_reason": cs.last_state.terminated.reason,
                "last_exit_code": cs.last_state.terminated.exit_code,
            }
        statuses.append(
            {
                "name": cs.name,
                "ready": cs.ready,
                "restart_count": cs.restart_count,
                "state": state,
                "last_state": last_state,
            }
        )
    return {
        "name": pod.metadata.name,
        "namespace": pod.metadata.namespace,
        "node": pod.spec.node_name,
        "phase": pod.status.phase,
        "labels": pod.metadata.labels or {},
        "containers": statuses,
    }


@mcp.tool()
def describe_pod(namespace: str, pod_name: str) -> dict[str, Any]:
    """Return pod conditions, container resource limits/probes (no Secret values), and recent events."""
    _check_ns(namespace)
    pod = v1.read_namespaced_pod(name=pod_name, namespace=namespace)
    conditions = [
        {"type": c.type, "status": c.status, "reason": c.reason, "message": c.message}
        for c in (pod.status.conditions or [])
    ]
    containers = [
        {
            "name": c.name,
            "image": c.image,
            "requests": (c.resources.requests if c.resources else None),
            "limits": (c.resources.limits if c.resources else None),
            "has_readiness_probe": c.readiness_probe is not None,
            "has_liveness_probe": c.liveness_probe is not None,
        }
        for c in pod.spec.containers
    ]
    events = list_events(namespace=namespace, object_name=pod_name)
    return {
        "pod": get_pod(namespace=namespace, pod_name=pod_name),
        "conditions": conditions,
        "containers_spec": containers,
        "events": events["events"],
    }


@mcp.tool()
def list_events(namespace: str, object_name: Optional[str] = None, limit: int = 20) -> dict[str, Any]:
    """List recent Kubernetes events in a namespace, optionally filtered by involved object name."""
    _check_ns(namespace)
    field_selector = f"involvedObject.name={object_name}" if object_name else None
    ev_list = v1.list_namespaced_event(namespace=namespace, field_selector=field_selector)
    items = sorted(
        ev_list.items,
        key=lambda e: str(e.last_timestamp or e.event_time or ""),
        reverse=True,
    )[: min(limit, 50)]
    return {
        "namespace": namespace,
        "count": len(items),
        "events": [
            {
                "type": e.type,
                "reason": e.reason,
                "object": f"{e.involved_object.kind}/{e.involved_object.name}",
                "count": e.count,
                "message": e.message,
                "last_seen": str(e.last_timestamp or e.event_time or ""),
            }
            for e in items
        ],
    }


@mcp.tool()
def get_pod_logs(
    namespace: str,
    pod_name: str,
    container: Optional[str] = None,
    previous: bool = False,
    tail_lines: int = 25,
) -> dict[str, Any]:
    """Fetch bounded tail logs from a pod container (current or previous terminated container)."""
    _check_ns(namespace)
    lines = max(1, min(tail_lines, MAX_LOG_LINES))
    raw = v1.read_namespaced_pod_log(
        name=pod_name,
        namespace=namespace,
        container=container,
        previous=previous,
        tail_lines=lines,
        limit_bytes=MAX_LOG_BYTES,
    )
    return {
        "namespace": namespace,
        "pod": pod_name,
        "container": container,
        "previous": previous,
        "logs": raw,
    }


@mcp.tool()
def get_workload_status(namespace: str) -> dict[str, Any]:
    """Summarize Deployments and Pods in a namespace (read-only)."""
    _check_ns(namespace)
    deps = apps_v1.list_namespaced_deployment(namespace=namespace).items
    pods = v1.list_namespaced_pod(namespace=namespace).items
    return {
        "namespace": namespace,
        "deployments": [
            {
                "name": d.metadata.name,
                "desired": d.spec.replicas,
                "ready": d.status.ready_replicas or 0,
                "available": d.status.available_replicas or 0,
            }
            for d in deps
        ],
        "pods": [
            {
                "name": p.metadata.name,
                "phase": p.status.phase,
                "restarts": sum((cs.restart_count for cs in (p.status.container_statuses or []))),
            }
            for p in pods
        ],
    }


if __name__ == "__main__":
    port = int(os.getenv("MCP_PORT", "8003"))
    mcp.run(transport="streamable-http", host="0.0.0.0", port=port)
