#!/usr/bin/env bash
set -euo pipefail

CONTAINER_DIR="/var/log/containers"
MAP_FILE="/tmp/container-map.env"

echo "=== Nosana Telemetry Client ==="
echo "Discovering podman containers..."
echo ""

: > "$MAP_FILE"

count=0
for userdata_dir in "$CONTAINER_DIR"/*/userdata/; do
    [ -d "$userdata_dir" ] || continue

    config_file="${userdata_dir}config.json"
    container_path="$(dirname "$userdata_dir")"
    full_id="$(basename "$container_path")"
    short_id="${full_id:0:12}"

    if [ -f "$config_file" ]; then
        # Extract container name from config.json without jq
        # Looks for "name": "container_name" pattern
        name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/"//')

        if [ -n "$name" ]; then
            echo "${short_id}=${name}" >> "$MAP_FILE"
            echo "  [${short_id}] ${name}"
            count=$((count + 1))
        else
            echo "${short_id}=unknown" >> "$MAP_FILE"
            echo "  [${short_id}] (name not found)"
            count=$((count + 1))
        fi
    else
        echo "${short_id}=unknown" >> "$MAP_FILE"
        echo "  [${short_id}] (no config.json)"
        count=$((count + 1))
    fi
done

echo ""
echo "Discovered ${count} container(s)"
echo "Container map written to ${MAP_FILE}"
echo ""
echo "Starting OpenTelemetry Collector..."
echo "==================================="

exec /otelcol-contrib --config=/etc/otelcol-contrib/config.yaml "$@"
