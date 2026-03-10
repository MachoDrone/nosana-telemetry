#!/usr/bin/env bash
# Nosana Telemetry Client — Installation Script
# Version: 0.01.2
# Usage: bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client/install.sh) <server_address> <api_key>
set -euo pipefail

INSTALL_DIR="/opt/nosana-telemetry"
GITHUB_RAW="https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client"
CONTAINER_NAME="nosana-telemetry-client"

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
elif sudo test -d "${OVERLAY_CONTAINERS_DIR}" 2>/dev/null; then
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
NODE_NAME=$(docker exec podman podman exec nosana-node printenv 2>/dev/null \
    | grep -oP 'NOSANA_NODE_NAME=\K.*' || true)

if [[ -z "${NODE_NAME}" ]]; then
    NODE_NAME=$(hostname)
    info "Node name (from hostname): ${NODE_NAME}"
else
    info "Node name (from nosana-node): ${NODE_NAME}"
fi

echo ""

# ─── 5. Create installation directory ─────────────────────────────────────────

echo "Setting up installation directory..."

sudo mkdir -p "${INSTALL_DIR}"
# Give current user ownership so docker compose can be run without sudo later
sudo chown "$(id -u):$(id -g)" "${INSTALL_DIR}"

info "Directory: ${INSTALL_DIR}"
echo ""

# ─── 6. Download client files ─────────────────────────────────────────────────

echo "Downloading client files..."

wget -qO "${INSTALL_DIR}/otel-collector.yaml" "${GITHUB_RAW}/otel-collector.yaml"
info "Downloaded otel-collector.yaml"

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

# ─── 10. Verify connectivity ──────────────────────────────────────────────────

echo "Verifying connectivity to server..."

CONNECTIVITY_STATUS="Unknown"
if (echo > /dev/tcp/"${SERVER_ADDRESS}"/4318) 2>/dev/null; then
    CONNECTIVITY_STATUS="Connected"
    info "Successfully reached server at ${SERVER_ADDRESS}:4318"
else
    warn "Could not reach server at ${SERVER_ADDRESS}:4318"
    CONNECTIVITY_STATUS="Unreachable"
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
echo "══════════════════════════════════════"
echo ""
