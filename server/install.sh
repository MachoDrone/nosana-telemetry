#!/usr/bin/env bash
# Nosana Telemetry Server — Installation Script
# https://github.com/MachoDrone/nosana-telemetry
# Version: 0.01.0
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/server"
INSTALL_DIR="/opt/nosana-telemetry"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
error() { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; }
fatal() { error "$*"; exit 1; }

# ── Banner ───────────────────────────────────────────────────────────────────

cat <<'BANNER'

╔══════════════════════════════════════╗
║   Nosana Telemetry Server Setup     ║
╚══════════════════════════════════════╝

BANNER

# ── Prerequisites ────────────────────────────────────────────────────────────

info "Checking prerequisites..."

# Docker
if ! command -v docker &>/dev/null; then
    fatal "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"
fi

if ! docker info &>/dev/null; then
    fatal "Docker daemon is not running or current user lacks permission. Start Docker or add yourself to the docker group."
fi

# Docker Compose v2 plugin
if ! docker compose version &>/dev/null; then
    fatal "Docker Compose v2 plugin is not available. Install it: https://docs.docker.com/compose/install/"
fi

info "Docker and Docker Compose v2 detected."

# ── Existing Installation Check ─────────────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    warn "An existing installation was found at $INSTALL_DIR"
    read -rp "Overwrite and re-install? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Installation cancelled by user."
        exit 0
    fi
    info "Stopping existing stack..."
    (cd "$INSTALL_DIR" && docker compose down 2>/dev/null) || true
    sleep 2
fi

# Port availability (checked after stopping any existing stack)
REQUIRED_PORTS=(3000 3100 4317 4318 8889 9090)
PORTS_IN_USE=()

for port in "${REQUIRED_PORTS[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        PORTS_IN_USE+=("$port")
    fi
done

if [[ ${#PORTS_IN_USE[@]} -gt 0 ]]; then
    fatal "The following required ports are already in use: ${PORTS_IN_USE[*]}"
fi

info "All required ports are available: ${REQUIRED_PORTS[*]}"

# ── Create Installation Directory ───────────────────────────────────────────

info "Setting up installation directory: $INSTALL_DIR"

if [[ -w "/opt" ]]; then
    mkdir -p "$INSTALL_DIR"
else
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ── Download Server Files ───────────────────────────────────────────────────

info "Downloading server configuration files..."

download() {
    local relpath="$1"
    local dest="${INSTALL_DIR}/${relpath}"
    local dir
    dir="$(dirname "$dest")"
    mkdir -p "$dir"
    if ! wget -qO "$dest" "${REPO_BASE}/${relpath}"; then
        fatal "Failed to download ${relpath}"
    fi
}

download "docker-compose.yml"
download "otel-collector.yaml"
download "loki-config.yaml"
download "prometheus.yml"
download "grafana/provisioning/datasources/datasources.yaml"
download "grafana/provisioning/dashboards/dashboards.yaml"
download "grafana/provisioning/dashboards/nosana-overview.json"
download "grafana/provisioning/dashboards/error-triage.json"

info "All configuration files downloaded."

# ── Generate Secrets & .env ─────────────────────────────────────────────────

info "Generating secrets..."

OTEL_API_KEY="$(openssl rand -hex 32)"
GRAFANA_PASSWORD="$(openssl rand -base64 16)"

cat > "${INSTALL_DIR}/.env" <<EOF
OTEL_API_KEY=${OTEL_API_KEY}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}
EOF

chmod 600 "${INSTALL_DIR}/.env"

info "Secrets written to ${INSTALL_DIR}/.env (mode 600)."

# ── Start the Stack ─────────────────────────────────────────────────────────

info "Starting Nosana Telemetry stack..."

docker compose up -d

info "Waiting for containers to initialise..."
sleep 5

# Verify all containers are running
FAILED_CONTAINERS=()

while IFS= read -r line; do
    name="$(echo "$line" | awk '{print $1}')"
    state="$(echo "$line" | awk '{print $2}')"
    if [[ "$state" != "running" ]]; then
        FAILED_CONTAINERS+=("$name")
    fi
done < <(docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null)

if [[ ${#FAILED_CONTAINERS[@]} -gt 0 ]]; then
    error "The following containers are not running:"
    for c in "${FAILED_CONTAINERS[@]}"; do
        error "  - $c"
        echo "--- Logs for $c ---" >&2
        docker compose logs "$c" --tail 30 >&2 || true
        echo "---" >&2
    done
    fatal "Stack did not start cleanly. Check the logs above."
fi

info "All containers are running."

# ── Detect IP Address ───────────────────────────────────────────────────────

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 addr show scope global 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
        | head -1)" || true
fi

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="<YOUR_SERVER_IP>"
    warn "Could not auto-detect server IP. Replace $SERVER_IP in the output below."
fi

# ── Summary ──────────────────────────────────────────────────────────────────

cat <<EOF

══════════════════════════════════════
  Nosana Telemetry Server is running!
══════════════════════════════════════

  Grafana:     http://${SERVER_IP}:3000
  Username:    admin
  Password:    ${GRAFANA_PASSWORD}

  OTLP gRPC:   ${SERVER_IP}:4317
  OTLP HTTP:   ${SERVER_IP}:4318

  API Key for clients:
  ${OTEL_API_KEY}

  Save these credentials! They are stored in:
  ${INSTALL_DIR}/.env

  Server is ephemeral — containers do not auto-restart.
  Data volumes persist across restarts.

  To stop + clean:   cd ${INSTALL_DIR} && docker compose down
  To wipe all data:  cd ${INSTALL_DIR} && docker compose down -v
  To restart:        re-run this install script

  To set up a client host, run:
  bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/nosana-telemetry/main/client/install.sh) ${SERVER_IP} ${OTEL_API_KEY}
══════════════════════════════════════

EOF
