#!/usr/bin/env bash
# Nosana Telemetry Client — Installation Script
# Version: 0.02.7
# Usage: bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client/install.sh) <server_address> <api_key>
set -euo pipefail

INSTALL_DIR="/opt/nosana-telemetry"
GITHUB_RAW="https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client"
CONTAINER_NAME="nosana-telemetry-client"
DIAG_CONTAINER_NAME="nosana-diagnostics"

# Use sudo only when not already root (e.g. inside updater container)
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# ─── Helpers ───────────────────────────────────────────────────────────────────

err()  { echo "ERROR: $*" >&2; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "  $*"; }

# ─── 1. Banner ─────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Nosana Telemetry Client Setup     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ─── 2. Validate arguments ────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
    err "Missing required arguments."
    echo "" >&2
    echo "Usage: install.sh <server_address> <api_key>" >&2
    echo "Example: install.sh 154.54.100.193 abc123def456..." >&2
    exit 1
fi

SERVER_ADDRESS="$1"
API_KEY="$2"

info "Server address: ${SERVER_ADDRESS}"
info "API key:        ${API_KEY:0:8}..."
echo ""

# ─── 3. Check prerequisites ───────────────────────────────────────────────────

echo "Checking prerequisites..."

# Docker installed
if ! command -v docker &>/dev/null; then
    err "Docker is not installed. Please install Docker first."
    exit 1
fi
info "Docker is installed."

# Docker daemon running
if ! docker info &>/dev/null; then
    err "Docker daemon is not running. Start it with: sudo systemctl start docker"
    exit 1
fi
info "Docker daemon is running."

# Podman container running
if ! docker ps --format '{{.Names}}' | grep -q '^podman$'; then
    err "The 'podman' container is not running."
    err "Ensure the Nosana node stack is started before installing telemetry."
    exit 1
fi
info "Podman container is running."

# podman-cache volume exists
if ! docker volume ls --format '{{.Name}}' | grep -q '^podman-cache$'; then
    err "The 'podman-cache' volume does not exist."
    err "This volume is required for monitoring Nosana container logs."
    exit 1
fi
info "podman-cache volume exists."

# Determine the podman-cache volume mount point
VOLUME_MOUNTPOINT=""
VOLUME_MOUNTPOINT=$(docker volume inspect podman-cache --format '{{.Mountpoint}}' 2>/dev/null || true)

if [[ -z "${VOLUME_MOUNTPOINT}" ]]; then
    # Fallback to the default Docker path
    VOLUME_MOUNTPOINT="/var/lib/docker/volumes/podman-cache/_data"
fi

OVERLAY_CONTAINERS_DIR="${VOLUME_MOUNTPOINT}/storage/overlay-containers"

# Check overlay-containers directory (may need sudo)
if [[ -d "${OVERLAY_CONTAINERS_DIR}" ]]; then
    info "Podman container log directory found: ${OVERLAY_CONTAINERS_DIR}"
elif $SUDO test -d "${OVERLAY_CONTAINERS_DIR}" 2>/dev/null; then
    info "Podman container log directory found (via sudo): ${OVERLAY_CONTAINERS_DIR}"
else
    err "Podman container log directory not found at:"
    err "  ${OVERLAY_CONTAINERS_DIR}"
    err "The podman-cache volume may not have been populated yet."
    err "Ensure at least one Nosana job has run before installing telemetry."
    exit 1
fi

echo ""

# ─── 4. Detect node name ──────────────────────────────────────────────────────

echo "Detecting node name..."

NODE_NAME=""

# Helper: extract Solana public key (base58) from keypair JSON on stdin
extract_pubkey() {
    python3 -c "
import json, sys
key = json.load(sys.stdin)
pubkey = bytes(key[32:])
alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
n = int.from_bytes(pubkey, 'big')
result = ''
while n > 0:
    n, r = divmod(n, 58)
    result = alphabet[r] + result
for b in pubkey:
    if b == 0: result = '1' + result
    else: break
print(result)
" 2>/dev/null
}

# Try 1: Host keypair file
if [[ -f "${HOME}/.nosana/nosana_key.json" ]]; then
    NODE_NAME=$(extract_pubkey < "${HOME}/.nosana/nosana_key.json" || true)
    if [[ -n "${NODE_NAME}" ]]; then
        info "Node name (wallet from host keypair): ${NODE_NAME}"
    fi
fi

# Try 2: Keypair inside nosana-node container
if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME=$(docker exec podman podman exec nosana-node \
        cat /root/.nosana/nosana_key.json 2>/dev/null | extract_pubkey || true)
    if [[ -n "${NODE_NAME}" ]]; then
        info "Node name (wallet from container keypair): ${NODE_NAME}"
    fi
fi

# Try 3: NOSANA_NODE_NAME env var
if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME=$(docker exec podman podman exec nosana-node printenv 2>/dev/null \
        | sed -n 's/^NOSANA_NODE_NAME=//p' || true)
    if [[ -n "${NODE_NAME}" ]]; then
        info "Node name (from nosana-node env): ${NODE_NAME}"
    fi
fi

# Try 4: Hostname fallback
if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME=$(hostname)
    info "Node name (from hostname): ${NODE_NAME}"
fi

echo ""

# ─── 5. Create installation directory ─────────────────────────────────────────

echo "Setting up installation directory..."

$SUDO mkdir -p "${INSTALL_DIR}"
# Give current user ownership so docker compose can be run without sudo later
$SUDO chown "$(id -u):$(id -g)" "${INSTALL_DIR}"

info "Directory: ${INSTALL_DIR}"
echo ""

# ─── 6. Download client files ─────────────────────────────────────────────────

echo "Downloading client files..."

wget -qO "${INSTALL_DIR}/otel-collector.yaml" "${GITHUB_RAW}/otel-collector.yaml"
info "Downloaded otel-collector.yaml"

wget -qO "${INSTALL_DIR}/diagnostics.sh" "${GITHUB_RAW}/diagnostics.sh"
info "Downloaded diagnostics.sh"

wget -qO "${INSTALL_DIR}/Dockerfile.diagnostics" "${GITHUB_RAW}/Dockerfile.diagnostics"
info "Downloaded Dockerfile.diagnostics"

wget -qO "${INSTALL_DIR}/playbooks.yaml" "${GITHUB_RAW}/playbooks.yaml"
info "Downloaded playbooks.yaml"

wget -qO "${INSTALL_DIR}/VERSION" "${GITHUB_RAW}/VERSION"
info "Downloaded VERSION"

echo ""

# ─── 7. Discover podman containers ────────────────────────────────────────────

echo "Discovering podman containers..."

PODMAN_PS_OUTPUT=""
PODMAN_PS_OUTPUT=$(docker exec podman podman ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

if [[ -n "${PODMAN_PS_OUTPUT}" ]]; then
    echo "${PODMAN_PS_OUTPUT}" | while IFS=' ' read -r cid cname; do
        info "  ${cid:0:12} = ${cname}"
    done
else
    warn "No podman containers found (this is normal if no job is running)."
fi

echo ""

# ─── 8. Write .env file ───────────────────────────────────────────────────────

echo "Writing configuration..."

cat > "${INSTALL_DIR}/.env" <<ENVEOF
OTEL_SERVER=${SERVER_ADDRESS}
OTEL_API_KEY=${API_KEY}
NODE_NAME=${NODE_NAME}
ENVEOF

chmod 600 "${INSTALL_DIR}/.env"
info "Configuration written to ${INSTALL_DIR}/.env (permissions: 600)"
echo ""

# ─── 9. Start the collector (ephemeral: --rm auto-removes on stop) ───────────

echo "Starting telemetry collector..."

# Create shared volume for diagnostics logs
docker volume create nosana-diag-logs 2>/dev/null || true
info "Diagnostics log volume ready."

# Stop existing container if running (idempotent)
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Stopping existing ${CONTAINER_NAME} container..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    sleep 1
fi

docker run -d --rm \
    --name "${CONTAINER_NAME}" \
    --user 0:0 \
    -v "${INSTALL_DIR}/otel-collector.yaml:/etc/otelcol-contrib/config.yaml:ro" \
    -v "${OVERLAY_CONTAINERS_DIR}:/var/log/containers:ro" \
    -v /proc:/hostfs/proc:ro \
    -v /sys:/hostfs/sys:ro \
    -v /etc/hostname:/etc/hostname:ro \
    -v nosana-diag-logs:/var/log/diagnostics:ro \
    -e "OTEL_SERVER=${SERVER_ADDRESS}" \
    -e "OTEL_API_KEY=${API_KEY}" \
    -e "NODE_NAME=${NODE_NAME}" \
    -e "HOST_PROC=/hostfs/proc" \
    -e "HOST_SYS=/hostfs/sys" \
    "otel/opentelemetry-collector-contrib:0.120.0"

# Wait for container to start
sleep 3

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Container '${CONTAINER_NAME}' is running (ephemeral: self-removes on stop)."
else
    err "Container '${CONTAINER_NAME}' failed to start. Recent logs:"
    docker logs "${CONTAINER_NAME}" --tail=20 2>&1 >&2 || true
    exit 1
fi

echo ""

# ─── 9b. Build and start diagnostics sidecar ─────────────────────────────────

echo "Setting up diagnostics sidecar..."

# Build diagnostics image
cd "${INSTALL_DIR}"
docker build -q -t nosana-diagnostics:latest -f Dockerfile.diagnostics . >/dev/null 2>&1
info "Built nosana-diagnostics image."

# Stop existing diagnostics container if running
if docker ps -a --format '{{.Names}}' | grep -q "^${DIAG_CONTAINER_NAME}$"; then
    info "Stopping existing ${DIAG_CONTAINER_NAME} container..."
    docker stop "${DIAG_CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${DIAG_CONTAINER_NAME}" 2>/dev/null || true
    sleep 1
fi

# Detect nvidia-smi on host for GPU diagnostics
NVIDIA_MOUNTS=""
if command -v nvidia-smi &>/dev/null; then
    NVIDIA_SMI_PATH=$(command -v nvidia-smi)
    NVIDIA_MOUNTS="-v ${NVIDIA_SMI_PATH}:${NVIDIA_SMI_PATH}:ro --gpus all"
    info "nvidia-smi detected — GPU diagnostics enabled."
fi

docker run -d --rm \
    --name "${DIAG_CONTAINER_NAME}" \
    --user 0:0 \
    --network host \
    -v "${OVERLAY_CONTAINERS_DIR}:/var/log/containers:ro" \
    -v nosana-diag-logs:/var/log/diagnostics \
    -v /etc/resolv.conf:/etc/resolv.conf:ro \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -e "NODE_NAME=${NODE_NAME}" \
    -e "OTEL_SERVER=${SERVER_ADDRESS}" \
    -e "OTEL_API_KEY=${API_KEY}" \
    -e "GITHUB_RAW=${GITHUB_RAW}" \
    ${NVIDIA_MOUNTS} \
    nosana-diagnostics:latest

sleep 2

if docker ps --format '{{.Names}}' | grep -q "^${DIAG_CONTAINER_NAME}$"; then
    info "Container '${DIAG_CONTAINER_NAME}' is running."
else
    warn "Diagnostics sidecar failed to start (non-fatal). Check: docker logs ${DIAG_CONTAINER_NAME}"
fi

echo ""

# ─── 10. Verify connectivity ──────────────────────────────────────────────────

echo "Verifying connectivity to server..."

CONNECTIVITY_STATUS="Unknown"
if command -v curl &>/dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${SERVER_ADDRESS}:4318" 2>/dev/null || true)
    if [[ -n "${HTTP_CODE}" && "${HTTP_CODE}" != "000" ]]; then
        CONNECTIVITY_STATUS="Connected (HTTP ${HTTP_CODE})"
        info "Successfully reached server at ${SERVER_ADDRESS}:4318"
    else
        warn "Could not reach server at ${SERVER_ADDRESS}:4318"
        CONNECTIVITY_STATUS="Unreachable"
    fi
else
    warn "curl not available — skipping connectivity check."
fi

echo ""

# ─── 11. Summary ──────────────────────────────────────────────────────────────

# Re-fetch container list for summary
PODMAN_PS_SUMMARY=""
PODMAN_PS_SUMMARY=$(docker exec podman podman ps --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

echo "══════════════════════════════════════"
echo "  Nosana Telemetry Client is running!"
echo "══════════════════════════════════════"
echo ""
echo "  Node name:    ${NODE_NAME}"
echo "  Server:       ${SERVER_ADDRESS}:4318"
echo "  Status:       ${CONNECTIVITY_STATUS}"
echo ""
echo "  Containers being monitored:"

if [[ -n "${PODMAN_PS_SUMMARY}" ]]; then
    echo "${PODMAN_PS_SUMMARY}" | while IFS=' ' read -r cid cname; do
        echo "    ${cid:0:12} = ${cname}"
    done
else
    echo "    (none currently running)"
fi

echo ""
echo "  Logs will appear in Grafana at:"
echo "  http://${SERVER_ADDRESS}:3000"
echo ""
echo "  Container is ephemeral — it self-removes when stopped."
echo "  To re-run after reboot or stop, use the install command again."
echo ""
echo "  To check status:  docker logs ${CONTAINER_NAME}"
echo "  To stop + remove: docker stop ${CONTAINER_NAME}"
echo "  To update/start:  re-run this install script"
echo "  Diagnostics:      docker logs ${DIAG_CONTAINER_NAME}"
echo "══════════════════════════════════════"
echo ""
