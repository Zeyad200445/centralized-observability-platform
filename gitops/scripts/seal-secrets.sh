#!/usr/bin/env bash
# Usage: ELASTIC_PASSWORD=... KIBANA_ENCRYPTION_KEY=... GRAFANA_ADMIN_PASSWORD=... \
#        gitops/scripts/seal-secrets.sh <local|gke>
# Requires: kubectl (pointing at the target cluster), kubeseal, and the
# Sealed Secrets controller already installed (done by the Ansible bootstrap).
set -euo pipefail
ENV="${1:?usage: $0 <local|gke>}"
: "${ELASTIC_PASSWORD:?}" "${KIBANA_ENCRYPTION_KEY:?}" "${GRAFANA_ADMIN_PASSWORD:?}"
ELASTIC_USERNAME="${ELASTIC_USERNAME:-elastic}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
CTRL_NS="${SEALED_SECRETS_NS:-kube-system}"
CTRL_NAME="${SEALED_SECRETS_NAME:-sealed-secrets}"
OUT="$(dirname "$0")/../manifests/platform-base/${ENV}/sealed-secrets"

seal() { # name namespace key=value...
  local name="$1" ns="$2"; shift 2
  local args=() kv
  for kv in "$@"; do args+=("--from-literal=${kv}"); done
  kubectl create secret generic "$name" -n "$ns" "${args[@]}" --dry-run=client -o yaml \
    | kubeseal --controller-namespace "$CTRL_NS" --controller-name "$CTRL_NAME" --format yaml \
    > "${OUT}/${name}.yaml"
  echo "sealed ${ns}/${name}"
}

seal elasticsearch-master-credentials logging "username=${ELASTIC_USERNAME}" "password=${ELASTIC_PASSWORD}" "elastic=${ELASTIC_PASSWORD}"
seal kibana-credentials              logging "username=${ELASTIC_USERNAME}" "password=${ELASTIC_PASSWORD}" "encryptionkey=${KIBANA_ENCRYPTION_KEY}"
seal logstash-es-credentials         logging "username=${ELASTIC_USERNAME}" "password=${ELASTIC_PASSWORD}"
seal grafana-admin-credentials       monitoring "admin-user=${GRAFANA_ADMIN_USER}" "admin-password=${GRAFANA_ADMIN_PASSWORD}"
seal grafana-es-credentials          monitoring "password=${ELASTIC_PASSWORD}"
