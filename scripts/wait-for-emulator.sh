#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wait-for-emulator.sh
#
# Blocks until the floci-gcp emulator is serving its control-plane health
# endpoint, then verifies that the Docker socket really was passed through.
# Terraform will happily fire a cluster-create call at a half-booted emulator
# and fail in a confusing way, so every `make up` gates on this script.
#
# Usage: ./wait-for-emulator.sh [BASE_URL] [TIMEOUT_SECONDS]
# ---------------------------------------------------------------------------
set -euo pipefail

BASE_URL="${1:-${EMULATOR_URL:-http://localhost:4588}}"
TIMEOUT="${2:-180}"
INTERVAL=3
CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-floci-gcp}"

HEALTH_URL="${BASE_URL%/}/_floci-gcp/health"
INFO_URL="${BASE_URL%/}/_floci-gcp/info"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

echo "Waiting for floci-gcp at ${BASE_URL} (timeout ${TIMEOUT}s)"

deadline=$(( $(date +%s) + TIMEOUT ))
attempt=0

while true; do
  attempt=$(( attempt + 1 ))

  # The health endpoint is the authoritative readiness signal. Fall back to a
  # raw TCP probe so the script still works on trimmed-down emulator builds
  # that do not expose /_floci-gcp.
  if curl -fsS --max-time 5 "${HEALTH_URL}" >/dev/null 2>&1; then
    ok "health endpoint responded after ${attempt} attempt(s)"
    break
  fi

  if (echo > "/dev/tcp/$(echo "${BASE_URL}" | sed -E 's#^https?://##; s#:.*$##')/4588") >/dev/null 2>&1; then
    warn "port 4588 is open but ${HEALTH_URL} is not answering yet"
  fi

  if [[ $(date +%s) -ge ${deadline} ]]; then
    echo "--- last 50 lines of emulator logs -------------------------------"
    docker logs --tail 50 "${CONTAINER_NAME}" 2>&1 || true
    echo "------------------------------------------------------------------"
    die "emulator did not become healthy within ${TIMEOUT}s"
  fi

  sleep "${INTERVAL}"
done

# ---------------------------------------------------------------------------
# Verify the Docker socket passthrough. GKE is a Docker-backed service: if the
# socket is missing, cluster creation silently degrades and the resulting
# "cluster" has no reachable API server.
# ---------------------------------------------------------------------------
if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  if docker inspect -f '{{ range .Mounts }}{{ .Source }}{{ "\n" }}{{ end }}' "${CONTAINER_NAME}" \
       | grep -q '^/var/run/docker.sock$'; then
    ok "/var/run/docker.sock is mounted into ${CONTAINER_NAME}"
  else
    die "/var/run/docker.sock is NOT mounted into ${CONTAINER_NAME}. Terraform cannot create a real k3s-backed GKE cluster. Fix docker-compose.yml and re-run 'make up'."
  fi

  if docker exec "${CONTAINER_NAME}" sh -c 'test -S /var/run/docker.sock' 2>/dev/null; then
    ok "emulator can see the Docker socket as a socket file"
  else
    warn "could not stat the socket inside the container (non-fatal)"
  fi
else
  warn "container ${CONTAINER_NAME} not found locally; skipping socket check (remote emulator?)"
fi

# Informational: which services this build exposes.
if curl -fsS --max-time 5 "${INFO_URL}" >/dev/null 2>&1; then
  echo "--- emulator info -------------------------------------------------"
  curl -fsS --max-time 5 "${INFO_URL}" || true
  echo ""
  echo "-------------------------------------------------------------------"
fi

ok "floci-gcp is ready. Terraform may now target ${BASE_URL}."
