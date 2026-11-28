# GitOps (Argo CD, App-of-Apps)

```
root-app.yaml  ->  apps/ (Helm chart; templates = child Applications)
```

| Wave | Application | Source |
|---|---|---|
| 0 | platform-base | manifests/platform-base/<env> (namespaces, RBAC, SealedSecrets) |
| 1 | elasticsearch | elastic/elasticsearch + values/elasticsearch |
| 2 | logstash | elastic/logstash |
| 3 | filebeat, kibana | elastic/filebeat, elastic/kibana |
| 4 | kube-prometheus-stack | includes alert rules (additionalPrometheusRulesMap) |
| 5 | gcp-exporter | manifests/gcp-exporter/<env> |

Environment: `env` parameter in root-app.yaml (`local` | `gke`) selects `values-<env>.yaml`.
Secrets: run `scripts/seal-secrets.sh <env>` and commit the output.
Requires Argo CD >= 2.6 (multi-source) with Application health checks.
