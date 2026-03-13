#!/usr/bin/env bash
# Update the Grafana dashboard from the repo without restarting.
# Downloads the latest dashboard JSON from GitHub and triggers a Grafana reload.
#
# Usage: ./update-dashboard.sh [commit_or_branch] [grafana_password]
#   Defaults: main, reads from GRAFANA_ADMIN_PW env
set -euo pipefail

INSTALL_DIR="/opt/nosana-telemetry"
DASHBOARD_PATH="grafana/provisioning/dashboards/nosana-overview.json"
GRAFANA_URL="http://localhost:3000"
GITHUB_REPO="MachoDrone/nosana-telemetry"

REF="${1:-main}"
GRAFANA_PW="${2:-${GRAFANA_ADMIN_PW:-}}"

if [[ -z "${GRAFANA_PW}" ]]; then
    echo "Usage: $0 [commit_or_branch] [grafana_password]" >&2
    echo "   or: GRAFANA_ADMIN_PW=... $0 [commit_or_branch]" >&2
    exit 1
fi

GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/${REF}/server"

echo "Downloading dashboard from ${REF}..."
wget -qO "${INSTALL_DIR}/${DASHBOARD_PATH}" "${GITHUB_RAW}/${DASHBOARD_PATH}"
echo "  Saved to ${INSTALL_DIR}/${DASHBOARD_PATH}"

echo "Reloading Grafana provisioning..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST \
    -u "admin:${GRAFANA_PW}" \
    "${GRAFANA_URL}/api/admin/provisioning/dashboards/reload")

if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "Dashboard updated successfully — no restart needed."
else
    echo "ERROR: Grafana reload returned HTTP ${HTTP_CODE}" >&2
    exit 1
fi
