import sys
sys.path.insert(0, "agents/mcp-servers")
import kubernetes_mcp, prometheus_mcp, elasticsearch_mcp

print("1. K8s MCP -> get_workload_status('workload'):")
ws = kubernetes_mcp.get_workload_status("workload")
print("   Deployments:", [d["name"] for d in ws["deployments"]])

print("2. Prometheus MCP -> query('up'):")
pq = prometheus_mcp.query("up")
print("   Series returned:", pq["result_count"])

print("3. Elasticsearch MCP -> search_logs('workload', minutes=60, size=3):")
es = elasticsearch_mcp.search_logs("workload", minutes=60, size=3)
print("   Total hits:", es["total_hits"], "| Returned:", es["returned"])

print("4. Security check -> Elasticsearch MCP must reject 'kube-system':")
try:
    elasticsearch_mcp.search_logs("kube-system")
    print("   FAIL: kube-system was not blocked!")
except ValueError as e:
    print("   PASS (blocked):", e)
