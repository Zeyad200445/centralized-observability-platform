#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-test.sh - end-to-end verification of the observability platform
#                 with the VProfile multi-tier workload.
# ---------------------------------------------------------------------------
set -uo pipefail

EMULATOR_URL="${EMULATOR_URL:-http://localhost:4588}"
NS_LOGGING="${NS_LOGGING:-logging}"
NS_MONITORING="${NS_MONITORING:-monitoring}"
NS_WORKLOAD="${NS_WORKLOAD:-workload}"

ES_SVC="${ES_SVC:-svc/elasticsearch-master}"
ES_LOCAL_PORT="${ES_LOCAL_PORT:-9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASSWORD:-}"

PROM_SVC="${PROM_SVC:-svc/kube-prometheus-stack-prometheus}"
PROM_LOCAL_PORT="${PROM_LOCAL_PORT:-9090}"

VPROFILE_SVC="${VPROFILE_SVC:-svc/vproweb}"
VPROFILE_LOCAL_PORT="${VPROFILE_LOCAL_PORT:-8088}"

INDEX_PREFIX="${INDEX_PREFIX:-logstash-k8s-}"
LOG_PROPAGATION_WAIT="${LOG_PROPAGATION_WAIT:-45}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0; PF_PIDS=()

section() { echo -e "\n${BLUE}==> $*${NC}"; }
pass()    { echo -e "  ${GREEN}PASS${NC}  $*"; PASS=$((PASS+1)); }
fail()    { echo -e "  ${RED}FAIL${NC}  $*"; FAIL=$((FAIL+1)); }
info()    { echo -e "  ${YELLOW}..${NC}    $*"; }

cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] && kill "${pid}" >/dev/null 2>&1
  done
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

port_forward() {
  local ns="$1" target="$2" local_port="$3" remote_port="$4"
  kubectl -n "${ns}" port-forward "${target}" "${local_port}:${remote_port}" \
    >/dev/null 2>&1 &
  local pid=$!
  PF_PIDS+=("${pid}")
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/127.0.0.1/${local_port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required binary: $1"; exit 2; }
}
require kubectl
require curl

echo "==========================================================="
echo " Centralized Observability Platform - VProfile Smoke Test"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "==========================================================="

# ---------------------------------------------------------------- 1. emulator
section "1. floci-gcp control plane"
if [[ "${SKIP_EMULATOR:-0}" == "1" ]]; then
  info "SKIP_EMULATOR=1 (assuming real GCP); skipping emulator checks"
else
  if curl -fsS --max-time 5 "${EMULATOR_URL}/_floci-gcp/health" >/dev/null 2>&1; then
    pass "health endpoint ${EMULATOR_URL}/_floci-gcp/health is responding"
  elif (echo > /dev/tcp/127.0.0.1/4588) >/dev/null 2>&1; then
    pass "port 4588 is reachable (health path unavailable on this build)"
  else
    fail "floci-gcp is not reachable at ${EMULATOR_URL} - run 'make up'"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^floci-gcp$'; then
    if docker inspect -f '{{ range .Mounts }}{{ .Source }} {{ end }}' floci-gcp 2>/dev/null \
         | grep -q '/var/run/docker.sock'; then
      pass "docker.sock is mounted (Docker-backed GKE enabled)"
    else
      fail "docker.sock is NOT mounted - GKE would be a mock, not real k3s"
    fi
  fi
fi

# ------------------------------------------------------------------ 2. nodes
section "2. GKE cluster nodes"
if ! kubectl cluster-info >/dev/null 2>&1; then
  fail "kubectl cannot reach the cluster API server (is KUBECONFIG set?)"
  echo -e "\n${RED}Aborting: no cluster.${NC}"
  exit 1
fi
pass "kubectl reached the API server"

NODE_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NODE_READY=$(kubectl get nodes --no-headers 2>/dev/null \
  | awk '{print $2}' | grep -cw 'Ready')
if [[ "${NODE_TOTAL}" -gt 0 && "${NODE_READY}" -eq "${NODE_TOTAL}" ]]; then
  pass "${NODE_READY}/${NODE_TOTAL} nodes are Ready"
else
  fail "only ${NODE_READY}/${NODE_TOTAL} nodes are Ready"
  kubectl get nodes || true
fi

# ------------------------------------------------------------------- 3. pods
section "3. Pod health in logging / monitoring / workload"
for ns in "${NS_LOGGING}" "${NS_MONITORING}" "${NS_WORKLOAD}"; do
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    fail "namespace ${ns} does not exist"
    continue
  fi

  total=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${total}" -eq 0 ]]; then
    fail "namespace ${ns} has no pods"
    continue
  fi

  bad=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | awk '
    {
      status=$3; ready=$2
      split(ready, r, "/")
      if (status == "Succeeded" || status == "Completed") next
      if (status != "Running" || r[1] != r[2]) print $1" ("status" "ready")"
    }')

  if [[ -z "${bad}" ]]; then
    pass "all ${total} pods in ${ns} are Running and Ready"
  else
    fail "unhealthy pods in ${ns}:"
    echo "${bad}" | sed 's/^/          /'
  fi
done

# -------------------------------------------------------- 4. generate traffic
section "4. Generate HTTP 200 and HTTP 404 access logs on VProfile"
if kubectl -n "${NS_WORKLOAD}" get "${VPROFILE_SVC}" >/dev/null 2>&1; then
  if port_forward "${NS_WORKLOAD}" "${VPROFILE_SVC}" "${VPROFILE_LOCAL_PORT}" 80; then
    pass "port-forward to ${VPROFILE_SVC} established on :${VPROFILE_LOCAL_PORT}"

    code200=$(curl -s -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${VPROFILE_LOCAL_PORT}/" || echo "000")
    [[ "${code200}" == "200" ]] \
      && pass "GET / (VProfile Login) returned 200" \
      || fail "GET / returned ${code200}, expected 200"

    code404=$(curl -s -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${VPROFILE_LOCAL_PORT}/vprofile-missing-page" || echo "000")
    [[ "${code404}" == "404" ]] \
      && pass "GET /vprofile-missing-page returned 404" \
      || fail "GET /vprofile-missing-page returned ${code404}, expected 404"

    for i in $(seq 1 20); do
      curl -s -o /dev/null "http://127.0.0.1:${VPROFILE_LOCAL_PORT}/" || true
      curl -s -o /dev/null "http://127.0.0.1:${VPROFILE_LOCAL_PORT}/vprofile-404-${i}" || true
    done
    info "generated 40 extra VProfile requests (20x200, 20x404)"
  else
    fail "could not port-forward to ${VPROFILE_SVC}"
  fi
else
  fail "${VPROFILE_SVC} not found in ${NS_WORKLOAD} - run 'kubectl apply -f workloads/vprofile.yaml'"
fi

info "waiting ${LOG_PROPAGATION_WAIT}s for Filebeat -> Logstash -> Elasticsearch"
sleep "${LOG_PROPAGATION_WAIT}"

# ------------------------------------------------------ 5. logging pipeline
section "5. Elasticsearch: VProfile indices and parsed Grok fields"
if [[ -z "${ES_PASSWORD}" ]]; then
  for secret_name in elasticsearch-master-credentials elastic-credentials; do
    ES_PASSWORD=$(kubectl -n "${NS_LOGGING}" get secret "${secret_name}" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [[ -n "${ES_PASSWORD}" ]]; then
      ES_USER_FROM_SECRET=$(kubectl -n "${NS_LOGGING}" get secret "${secret_name}" \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
      [[ -n "${ES_USER_FROM_SECRET}" ]] && ES_USER="${ES_USER_FROM_SECRET}"
      break
    fi
  done
fi
ES_AUTH=()
[[ -n "${ES_PASSWORD}" ]] && ES_AUTH=(-u "${ES_USER}:${ES_PASSWORD}")

if port_forward "${NS_LOGGING}" "${ES_SVC}" "${ES_LOCAL_PORT}" 9200; then
  pass "port-forward to ${ES_SVC} established on :${ES_LOCAL_PORT}"
  ES="http://127.0.0.1:${ES_LOCAL_PORT}"

  health=$(curl -s "${ES_AUTH[@]}" "${ES}/_cluster/health" \
    | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
  case "${health}" in
    green|yellow) pass "Elasticsearch cluster health is ${health}" ;;
    *)            fail "Elasticsearch cluster health is '${health:-unreachable}'" ;;
  esac

  idx_count=$(curl -s "${ES_AUTH[@]}" "${ES}/_cat/indices/${INDEX_PREFIX}*?h=index" \
    | grep -c "${INDEX_PREFIX}" || true)
  if [[ "${idx_count}" -gt 0 ]]; then
    pass "found ${idx_count} daily index/indices matching ${INDEX_PREFIX}*"
  else
    fail "no ${INDEX_PREFIX}* index exists - Logstash never wrote to Elasticsearch"
  fi

  # Verify VProfile (vproweb) 404 logs were Grok-parsed
  resp=$(curl -s "${ES_AUTH[@]}" -H 'Content-Type: application/json' \
    -XPOST "${ES}/${INDEX_PREFIX}*/_search?size=1" -d '{
      "query": { "bool": { "filter": [
        { "term": { "kubernetes.labels.app": "vproweb" } },
        { "term": { "http_status": 404 } },
        { "exists": { "field": "client_ip" } },
        { "exists": { "field": "request_path" } }
      ]}},
      "sort": [{ "@timestamp": { "order": "desc" } }]
    }')
  hits=$(echo "${resp}" | sed -n 's/.*"hits":{"total":{"value":\([0-9]*\).*/\1/p')
  if [[ -n "${hits}" && "${hits}" -gt 0 ]]; then
    pass "VProfile Grok parsing verified: ${hits} vproweb doc(s) with http_status=404 + client_ip + request_path"
  else
    fail "no structured vproweb 404 document found - check Logstash grok filter or propagation time"
    echo "${resp}" | head -c 600 | sed 's/^/          /'
  fi

  for field in http_method request_path http_status bytes_sent; do
    f=$(curl -s "${ES_AUTH[@]}" -H 'Content-Type: application/json' \
      -XPOST "${ES}/${INDEX_PREFIX}*/_search?size=0" \
      -d "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"kubernetes.labels.app\":\"vproweb\"}},{\"exists\":{\"field\":\"${field}\"}}]}}}" \
      | sed -n 's/.*"hits":{"total":{"value":\([0-9]*\).*/\1/p')
    if [[ -n "${f}" && "${f}" -gt 0 ]]; then
      pass "vproweb field '${field}' is indexed (${f} docs)"
    else
      fail "vproweb field '${field}' is missing"
    fi
  done

  k8s=$(curl -s "${ES_AUTH[@]}" -H 'Content-Type: application/json' \
    -XPOST "${ES}/${INDEX_PREFIX}*/_search?size=0" \
    -d '{"query":{"term":{"kubernetes.namespace":"workload"}}}' \
    | sed -n 's/.*"hits":{"total":{"value":\([0-9]*\).*/\1/p')
  [[ -n "${k8s}" && "${k8s}" -gt 0 ]] \
    && pass "Kubernetes metadata enrichment works (${k8s} docs from ns 'workload')" \
    || fail "no document carries kubernetes.namespace=workload"
else
  fail "could not port-forward to ${ES_SVC}"
fi

# ------------------------------------------------------ 6. metrics pipeline
section "6. Prometheus: exporter and VProfile targets"
if port_forward "${NS_MONITORING}" "${PROM_SVC}" "${PROM_LOCAL_PORT}" 9090; then
  pass "port-forward to ${PROM_SVC} established on :${PROM_LOCAL_PORT}"
  PROM="http://127.0.0.1:${PROM_LOCAL_PORT}"

  targets=$(curl -s "${PROM}/api/v1/targets?state=active")
  if [[ -z "${targets}" ]]; then
    fail "Prometheus /api/v1/targets returned nothing"
  else
    up=$(echo "${targets}" | grep -o '"health":"up"' | wc -l | tr -d ' ')
    down=$(echo "${targets}" | grep -o '"health":"down"' | wc -l | tr -d ' ')
    pass "Prometheus reports ${up} UP target(s), ${down} DOWN"
    [[ "${down}" -gt 0 ]] && info "some targets are down; inspect ${PROM}/targets"

    for job in node-exporter kube-state-metrics gcp-stackdriver-exporter; do
      if echo "${targets}" | grep -q "\"job\":\"[^\"]*${job}[^\"]*\""; then
        pass "scrape job matching '${job}' is registered"
      else
        fail "no scrape job matching '${job}' - check the ServiceMonitor"
      fi
    done
  fi

  check_query() {
    local label="$1" query="$2"
    local n
    n=$(curl -s --get "${PROM}/api/v1/query" --data-urlencode "query=${query}" \
      | grep -o '"metric"' | wc -l | tr -d ' ')
    [[ "${n}" -gt 0 ]] \
      && pass "${label}: '${query}' returned ${n} series" \
      || fail "${label}: '${query}' returned no series"
  }
  check_query "Node Exporter"      'up{job=~".*node-exporter.*"}'
  check_query "Kube State Metrics" 'kube_pod_status_phase{namespace="workload", pod=~"vpro.*"}'
  check_query "GCP Exporter"       'up{job=~".*gcp.*|.*stackdriver.*"}'
  check_query "VProfile NGINX"     'nginx_http_requests_total'
else
  fail "could not port-forward to ${PROM_SVC}"
fi

# ----------------------------------------------------------------- summary
echo ""
echo "==========================================================="
echo -e " Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo "==========================================================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo -e "${GREEN}Both pipelines are live end to end for VProfile.${NC}"
  exit 0
fi
echo -e "${RED}${FAIL} check(s) failed.${NC}"
exit 1
