# Layer E: Read-Only Alert-Triage Agent over MCP

An optional, feature-flagged (`triage_agent_enabled: false` by default) SRE assistant built on top of the Centralized Observability Platform (Layers A-D). When a Prometheus alert fires, Alertmanager triggers a FastAPI service (`triage-agent`) that investigates the incident through three **read-only MCP servers** (Prometheus, Elasticsearch, Kubernetes) and produces a structured, evidence-backed `TriageNote` with suggested commands for a human operator.

> **Core Security Invariant:** The agent reads evidence and proposes actions; it **never** mutates the cluster or reads Kubernetes Secrets.

---

## Implementation Roadmap & Phases

### Phase 0 — Preparation, Model Selection & Branching (Completed ✅)
1. **Isolated Feature Branch:** Created `feat/layer-e-triage-agent` from `main` to keep Layers A-D untouched.
2. **LLM Selection & Verification:** Tested Google AI Studio's OpenAI-compatible endpoint (`https://generativelanguage.googleapis.com/v1beta/openai/`) and selected **`gemini-3.5-flash`** as the zero-cost default (avoiding local 7B-8B RAM contention on a 16 GB host running k3s + ELK + Prometheus + VProfile). Switching to Ollama or any other OpenAI-compatible provider requires only changing environment variables.
3. **Cluster Baseline:** Verified `floci-gcp` + `rancher/k3s` and all pods across `logging`, `monitoring`, and `workload` (VProfile 5-tier stack) are `Running`.

---

### Phase 1 — Project Layout & Three Read-Only MCP Servers (Completed ✅)
Separated data access from LLM reasoning by building three independent `FastMCP` servers with hard limits enforced in server code (not just prompts):

1. **Workspace & Isolated Environment:** Created `agents/mcp-servers/`, `agents/triage-agent/app/`, `agents/eval/{faults,payloads}/`, and `agents/.venv`.
2. **Prometheus MCP (`agents/mcp-servers/prometheus_mcp.py`, port `8001`):**
   - Tools: `query`, `query_range`, `get_alerts`.
   - Hard limits: max PromQL length (500 chars), max range (120 min), 15s HTTP timeout, max 25 series returned.
3. **Elasticsearch MCP (`agents/mcp-servers/elasticsearch_mcp.py`, port `8002`):**
   - Tool: `search_logs(namespace, pod?, level?, text?, minutes, size)`.
   - Hard limits: index pinned to `logstash-k8s-*`, namespace allowlist (`TRIAGE_ALLOWED_NAMESPACES`, blocking `kube-system`), max 60 min window, max 50 hits, returns only parsed Grok fields (`raw_message`, `log_level`, `http_status`, `kubernetes.*`).
4. **Kubernetes MCP (`agents/mcp-servers/kubernetes_mcp.py`, port `8003`):**
   - Tools: `get_pod`, `describe_pod`, `list_events`, `get_pod_logs`, `get_workload_status`.
   - Hard limits: read-only verbs only, no Secrets or ConfigMap data, log tail capped at 100 lines / 16 KB.
5. **Verification (`test_mcp.py`):** Verified live queries against VProfile deployments, Prometheus series, Elasticsearch, and confirmed `kube-system` rejection.

---

### Phase 2 — Agent Loop, Runbooks & Guardrails (In Progress 🔄)
Building the reasoning engine inside `agents/triage-agent/app/` using **OpenAI Agents SDK**:

1. **Structured Schemas (`schemas.py`):** `AlertmanagerPayload`, `AlertItem`, `TriageNote` (`summary`, `evidence[]`, `likely_cause`, `confidence: low|medium|high`, `suggested_commands[]`), and `TriageRecord`.
2. **System Prompt & Runbooks (`prompts.py`):**
   - Prompt-injection guardrails treating all tool outputs and logs strictly as untrusted data.
   - Five built-in runbooks matching the platform's existing `PrometheusRule` alerts (`WorkloadPodCrashLooping`, `LogstashNotIngesting`, `FilebeatDown`, `ElasticsearchClusterUnhealthy`, `GCPExporterDown`), with `ConfigMap` override support.
3. **Agent Execution & Audit (`agent.py`):**
   - Connects to all three MCP servers via `MCPServerStreamableHttp` using `gemini-3.5-flash`.
   - Enforces `max_turns` budget (`TRIAGE_MAX_TOOL_CALLS=8`), per-run timeout (`90s`), and retry-once on malformed output.
   - `AuditHooks` logs tool name, call index, result byte size, and SHA-256 hash to `stdout` without logging raw log bodies.
4. **Local Verification (`test_agent.py`):** End-to-end agent test against a real cluster alert (`GCPExporterDown`).

---

### Phase 3 — FastAPI Service, Webhook Sink & Self-Metrics (Upcoming ⏳)
1. **FastAPI Service (`agents/triage-agent/app/main.py`):**
   - `POST /alert`: validates Alertmanager v4 webhook payload, applies 10-minute per-fingerprint deduplication/cool-down, and runs triage sequentially via a queue.
   - `GET /triage/{fingerprint}`: returns the stored `TriageRecord`.
   - `GET /healthz`: reports service health and reachability of all three MCP servers.
   - `GET /metrics`: exposes Prometheus metrics (`triage_runs_total{outcome}`, `triage_duration_seconds`, `triage_tool_calls_total{tool}`).
2. **Persistence & Sink:** Saves JSON/Markdown triage notes to a PVC-backed directory and logs one-line JSON summaries to `stdout` for Filebeat ingestion.
3. **Containerization:** Minimal non-root `Dockerfile`s for `triage-agent` and the three MCP servers.

---

### Phase 4 — Kubernetes, Ansible, Alertmanager & Smoke Test Integration (Upcoming ⏳)
All changes gated behind `triage_agent_enabled: false` so Layers A-D remain unchanged when disabled:

1. **`ansible/group_vars/all.yml`:** Add Layer E variables (`triage_agent_enabled`, `triage_namespace`, `triage_llm_base_url`, `triage_llm_model`, `vault_triage_llm_api_key`, budgets, allowlists).
2. **`ansible/templates/monitoring-values.yml.j2`:** Enable Alertmanager locally when `triage_agent_enabled` is true; add webhook receiver (`http://triage-agent.triage.svc:8080/alert`) with `continue: true`.
3. **New Jinja2 Templates:**
   - `ansible/templates/triage-runbooks.yml.j2`: `ConfigMap` keyed by `alertname`.
   - `ansible/templates/triage-agent.yml.j2`: `triage` namespace, `ResourceQuota`, 4 Deployments, 4 Services, 4 isolated ServiceAccounts, read-only `ClusterRole/obs-triage-reader` (no Secrets access), egress-restricted `NetworkPolicy`, `ServiceMonitor`, and results PVC.
4. **`ansible/playbook.yml`:** Add `triage` task group (guarded by `when: triage_agent_enabled`) to create secrets (`no_log: true`), Elasticsearch `triage_reader` role/user, and apply templates.
5. **`Makefile` & `scripts/smoke-test.sh`:** Add `triage-build`, `triage-deploy`, `triage-eval`, `triage-logs` targets, and append smoke test group 7 (`7a`–`7f`, including `kubectl auth can-i` RBAC assertions and namespace scope checks).

---

### Phase 5 — Evaluation Harness & Fault Injection (Upcoming ⏳)
Measure diagnosis accuracy empirically instead of assuming it:

1. **Fault Library (`agents/eval/faults/` & `payloads/`):** Six deterministic faults (CrashLoop non-zero exit, bad readiness probe, OOMKilled, `ImagePullBackOff`, unavailable DB dependency, `vproweb` 5xx spike).
2. **Runner (`agents/eval/run_eval.py`):** Injects each fault, waits for observability signals, triggers `POST /alert`, scores `likely_cause` and `evidence` against ground truth, cleans up, and reports the hit rate (`X of Y`).
