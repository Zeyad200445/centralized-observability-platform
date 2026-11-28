{{/* Shared syncPolicy: automated + selfHeal + prune on every app. */}}
{{- define "obs.syncPolicy" -}}
syncPolicy:
  automated:
    selfHeal: true
    prune: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
  retry:
    limit: 5
    backoff:
      duration: 20s
      factor: 2
      maxDuration: 5m
{{- end -}}
