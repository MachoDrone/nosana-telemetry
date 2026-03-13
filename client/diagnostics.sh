#!/usr/bin/env bash
# Version: 0.02.8
# Nosana Telemetry — Diagnostics Sidecar
# Runs inside Alpine container; watches container logs and executes playbooks on pattern matches.
set -uo pipefail

# ---------------------------------------------------------------------------
# SECTION 1: Configuration & Globals
# ---------------------------------------------------------------------------
PLAYBOOKS_FILE="/etc/diagnostics/playbooks.yaml"
DIAG_LOG="/var/log/diagnostics/diag.log"
COOLDOWN_DIR="/tmp/diag-cooldowns"
RATE_FILE="/tmp/diag-rate-limit"
LOG_DIR="/var/log/containers"
DIAG_LOG_MAX_BYTES=1048576   # 1 MB

NODE_NAME="${NODE_NAME:-$(hostname)}"
GITHUB_RAW="${GITHUB_RAW:-}"
OTEL_SERVER="${OTEL_SERVER:-}"
OTEL_API_KEY="${OTEL_API_KEY:-}"

VERSION_FILE="/etc/diagnostics/VERSION"
UPDATE_COOLDOWN_FILE="/var/log/diagnostics/update-cooldown"
UPDATE_CHECK_INTERVAL=30     # seconds between version checks
UPDATE_COOLDOWN_SECS=600     # 10 minutes between update attempts
UPDATE_INITIAL_DELAY=60      # seconds before first check
UPDATE_JITTER_MAX=300        # random 0–300s spread for 1300-host fleet

RATE_LIMIT_MAX=10            # max diagnostic runs per hour per host
RATE_WINDOW=3600             # seconds (1 hour)
PLAYBOOK_REFRESH_INTERVAL=3600  # 60 minutes

# Globals populated by load_playbooks
declare -a PB_IDS=()
declare -A PB_NAME=()
declare -A PB_PATTERN=()
declare -A PB_COOLDOWN=()
declare -A PB_TIMEOUT=()
declare -A PB_CMD_COUNT=()
declare -A PB_CMDS=()        # key: "<id>_<index>"
MAX_OUTPUT_LINES=50

# ---------------------------------------------------------------------------
# SECTION 2: Logging helpers
# ---------------------------------------------------------------------------
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_diag() {
    local line="$(ts) $*"
    printf '%s\n' "$line" >> "$DIAG_LOG"
    printf '%s\n' "$line" >&2
}

log_info() {
    printf '%s [INFO] %s\n' "$(ts)" "$*" >&2
}

log_warn() {
    printf '%s [WARN] %s\n' "$(ts)" "$*" >&2
}

# ---------------------------------------------------------------------------
# SECTION 3: Log rotation
# ---------------------------------------------------------------------------
maybe_rotate_log() {
    if [[ -f "$DIAG_LOG" ]]; then
        local size
        size=$(stat -c%s "$DIAG_LOG" 2>/dev/null || echo 0)
        if (( size > DIAG_LOG_MAX_BYTES )); then
            log_info "Rotating $DIAG_LOG (size=${size} > ${DIAG_LOG_MAX_BYTES})"
            : > "$DIAG_LOG"
        fi
    fi
}

# ---------------------------------------------------------------------------
# SECTION 4: Playbook loading (yq)
# ---------------------------------------------------------------------------
load_playbooks() {
    if [[ ! -f "$PLAYBOOKS_FILE" ]]; then
        log_warn "Playbooks file not found: $PLAYBOOKS_FILE"
        return 1
    fi

    PB_IDS=()
    unset PB_NAME PB_PATTERN PB_COOLDOWN PB_TIMEOUT PB_CMD_COUNT PB_CMDS
    declare -gA PB_NAME=() PB_PATTERN=() PB_COOLDOWN=() PB_TIMEOUT=() PB_CMD_COUNT=() PB_CMDS=()

    # Load global defaults
    local default_cooldown default_timeout
    default_cooldown=$(yq e '.defaults.cooldown // 300' "$PLAYBOOKS_FILE" 2>/dev/null || echo 300)
    default_timeout=$(yq e '.defaults.timeout // 10' "$PLAYBOOKS_FILE" 2>/dev/null || echo 10)
    MAX_OUTPUT_LINES=$(yq e '.defaults.max_output_lines // 50' "$PLAYBOOKS_FILE" 2>/dev/null || echo 50)

    # Count playbooks
    local count
    count=$(yq e '.playbooks | length' "$PLAYBOOKS_FILE" 2>/dev/null || echo 0)

    if (( count == 0 )); then
        log_warn "No playbooks found in $PLAYBOOKS_FILE"
        return 0
    fi

    local i
    for (( i=0; i<count; i++ )); do
        local id name pattern cooldown timeout cmd_count
        id=$(yq e ".playbooks[$i].id" "$PLAYBOOKS_FILE")
        name=$(yq e ".playbooks[$i].name" "$PLAYBOOKS_FILE")
        pattern=$(yq e ".playbooks[$i].pattern" "$PLAYBOOKS_FILE")
        cooldown=$(yq e ".playbooks[$i].cooldown // ${default_cooldown}" "$PLAYBOOKS_FILE")
        timeout=$(yq e ".playbooks[$i].timeout // ${default_timeout}" "$PLAYBOOKS_FILE")
        cmd_count=$(yq e ".playbooks[$i].commands | length" "$PLAYBOOKS_FILE")

        PB_IDS+=("$id")
        PB_NAME["$id"]="$name"
        PB_PATTERN["$id"]="$pattern"
        PB_COOLDOWN["$id"]="${cooldown:-$default_cooldown}"
        PB_TIMEOUT["$id"]="${timeout:-$default_timeout}"
        PB_CMD_COUNT["$id"]="${cmd_count:-0}"

        local j
        for (( j=0; j<cmd_count; j++ )); do
            local cmd
            cmd=$(yq e ".playbooks[$i].commands[$j]" "$PLAYBOOKS_FILE")
            PB_CMDS["${id}_${j}"]="$cmd"
        done
    done

    log_info "Loaded ${#PB_IDS[@]} playbooks from $PLAYBOOKS_FILE (max_output_lines=$MAX_OUTPUT_LINES)"
}

# ---------------------------------------------------------------------------
# SECTION 5: Playbook refresh from GitHub
# ---------------------------------------------------------------------------
playbook_refresh_loop() {
    [[ -z "$GITHUB_RAW" ]] && { log_info "GITHUB_RAW not set — skipping playbook refresh loop"; return; }

    while true; do
        sleep "$PLAYBOOK_REFRESH_INTERVAL"
        log_info "Checking for updated playbooks from $GITHUB_RAW"

        local tmp_file="/tmp/playbooks_new.yaml"
        local fetch_url="${GITHUB_RAW}/playbooks.yaml"
        if ! wget -q -O "$tmp_file" "$fetch_url" 2>/dev/null; then
            log_warn "Failed to fetch playbooks from $fetch_url"
            continue
        fi

        local old_sum new_sum
        old_sum=$(md5sum "$PLAYBOOKS_FILE" 2>/dev/null | awk '{print $1}' || echo "")
        new_sum=$(md5sum "$tmp_file" 2>/dev/null | awk '{print $1}' || echo "")

        if [[ "$old_sum" != "$new_sum" ]]; then
            log_info "Playbooks changed (old=$old_sum new=$new_sum) — reloading"
            cp "$tmp_file" "$PLAYBOOKS_FILE"
            load_playbooks
        else
            log_info "Playbooks unchanged"
        fi
        rm -f "$tmp_file"
    done
}

# ---------------------------------------------------------------------------
# SECTION 6: Rate limiting
# ---------------------------------------------------------------------------
# Rate file format: "<window_start_unix> <count>"
rate_limit_check() {
    local now
    now=$(date +%s)

    if [[ -f "$RATE_FILE" ]]; then
        local window_start count
        read -r window_start count < "$RATE_FILE" 2>/dev/null || { window_start=0; count=0; }
        local age=$(( now - window_start ))
        if (( age > RATE_WINDOW )); then
            # Window expired — reset
            printf '%s 0\n' "$now" > "$RATE_FILE"
            count=0
        fi
        if (( count >= RATE_LIMIT_MAX )); then
            return 1   # rate limited
        fi
        printf '%s %s\n' "$window_start" "$(( count + 1 ))" > "$RATE_FILE"
    else
        printf '%s 1\n' "$now" > "$RATE_FILE"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: Cooldown check
# ---------------------------------------------------------------------------
cooldown_check() {
    local pb_id="$1"
    local cooldown_secs="$2"
    local now
    now=$(date +%s)
    local stamp_file="${COOLDOWN_DIR}/${pb_id}"

    if [[ -f "$stamp_file" ]]; then
        local last_run
        last_run=$(cat "$stamp_file" 2>/dev/null || echo 0)
        local elapsed=$(( now - last_run ))
        if (( elapsed < cooldown_secs )); then
            return 1   # still in cooldown
        fi
    fi
    # Record new timestamp
    printf '%s\n' "$now" > "$stamp_file"
    return 0
}

# ---------------------------------------------------------------------------
# SECTION 8: Execute a single playbook
# ---------------------------------------------------------------------------
execute_playbook() {
    local pb_id="$1"
    local trigger_line="$2"
    local start_ts end_ts duration

    start_ts=$(date +%s)

    # Truncate trigger line to 120 chars
    local short_trigger="${trigger_line:0:120}"

    log_diag "DIAG ${pb_id} TRIGGERED host=${NODE_NAME} trigger=\"${short_trigger}\""
    maybe_rotate_log

    local cmd_count="${PB_CMD_COUNT[$pb_id]:-0}"
    local timeout_secs="${PB_TIMEOUT[$pb_id]:-10}"
    local j

    for (( j=0; j<cmd_count; j++ )); do
        local cmd="${PB_CMDS[${pb_id}_${j}]:-}"
        [[ -z "$cmd" ]] && continue

        local raw_output status
        # Run command with timeout; capture stdout+stderr; limit to MAX_OUTPUT_LINES
        raw_output=$(timeout "$timeout_secs" bash -c "$cmd" 2>&1 | head -n "$MAX_OUTPUT_LINES") && status="OK" || status="FAIL"

        # Collapse newlines to literal \n for single-line output
        local oneliner
        oneliner=$(printf '%s' "$raw_output" | tr '\n' '\\' | sed 's/\\/\\n/g')
        # Remove trailing \n artifact
        oneliner="${oneliner%\\n}"

        log_diag "DIAG ${pb_id} RESULT cmd=\"${cmd}\" status=${status} output=\"${oneliner}\""
    done

    end_ts=$(date +%s)
    duration=$(( end_ts - start_ts ))
    log_diag "DIAG ${pb_id} END duration=${duration}s"
}

# ---------------------------------------------------------------------------
# SECTION 9: CRI log line parser
# ---------------------------------------------------------------------------
# CRI format: <timestamp> <stream> <flags> <actual message>
# e.g.:       2026-03-10T15:30:44.123Z stdout F {"level":"error","msg":"EAI_AGAIN"}
strip_cri_prefix() {
    local raw="$1"
    # Match timestamp, stream tag, flag, then capture the rest
    if [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+[[:space:]][^[:space:]]+[[:space:]][PF][[:space:]](.*)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        # Not CRI format — return as-is
        printf '%s' "$raw"
    fi
}

# ---------------------------------------------------------------------------
# SECTION 10: Match line against all playbooks
# ---------------------------------------------------------------------------
match_and_dispatch() {
    local log_line="$1"

    for pb_id in "${PB_IDS[@]}"; do
        local pattern="${PB_PATTERN[$pb_id]:-}"
        [[ -z "$pattern" ]] && continue

        if printf '%s' "$log_line" | grep -qEi "$pattern" 2>/dev/null; then
            local cooldown="${PB_COOLDOWN[$pb_id]:-300}"

            if ! cooldown_check "$pb_id" "$cooldown"; then
                log_info "Playbook ${pb_id} matched but still in cooldown — skipping"
                continue
            fi

            if ! rate_limit_check; then
                log_warn "Global rate limit reached (${RATE_LIMIT_MAX}/hr) — suppressing playbook ${pb_id}"
                continue
            fi

            execute_playbook "$pb_id" "$log_line"
        fi
    done
}

# ---------------------------------------------------------------------------
# SECTION 11: Wait for log files to appear
# ---------------------------------------------------------------------------
wait_for_logs() {
    log_info "Waiting for container log files under ${LOG_DIR}..."
    while true; do
        local found
        found=$(find "$LOG_DIR" -name "ctr.log" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            log_info "Found log files — starting tail"
            return
        fi
        log_info "No ctr.log files yet — retrying in 30s"
        sleep 30
    done
}

# ---------------------------------------------------------------------------
# SECTION 12: Main log tail loop
# ---------------------------------------------------------------------------
tail_loop() {
    # tail -F follows new files matching the glob as they appear
    tail -F "${LOG_DIR}"/*/userdata/ctr.log 2>/dev/null | while IFS= read -r raw_line; do
        # Skip tail header lines (e.g. "==> /var/log/... <==")
        [[ "$raw_line" =~ ^==\> ]] && continue
        [[ -z "$raw_line" ]] && continue

        local log_msg
        log_msg=$(strip_cri_prefix "$raw_line")

        match_and_dispatch "$log_msg"
    done
}

# ---------------------------------------------------------------------------
# SECTION 13: Auto-update mechanism
# ---------------------------------------------------------------------------
get_local_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "unknown"
    fi
}

check_for_update() {
    [[ -z "$GITHUB_RAW" ]] && return 1

    local remote_version
    remote_version=$(wget -qO- "${GITHUB_RAW}/VERSION" 2>/dev/null | tr -d '[:space:]') || return 1

    if [[ -z "$remote_version" ]]; then
        log_warn "auto_update: empty remote VERSION"
        return 1
    fi

    local local_version
    local_version=$(get_local_version)

    if [[ "$local_version" != "$remote_version" ]]; then
        log_info "auto_update: version mismatch local=${local_version} remote=${remote_version}"
        return 0  # update available
    fi
    return 1  # up to date
}

spawn_updater() {
    # Lock: skip if updater already running
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^nosana-updater$'; then
        log_warn "auto_update: nosana-updater container already exists — skipping"
        return 1
    fi

    # Cooldown: check persistent cooldown file on diag-logs volume
    local now
    now=$(date +%s)
    if [[ -f "$UPDATE_COOLDOWN_FILE" ]]; then
        local last_attempt
        last_attempt=$(cat "$UPDATE_COOLDOWN_FILE" 2>/dev/null || echo 0)
        local elapsed=$(( now - last_attempt ))
        if (( elapsed < UPDATE_COOLDOWN_SECS )); then
            log_info "auto_update: cooldown active (${elapsed}s < ${UPDATE_COOLDOWN_SECS}s) — skipping"
            return 1
        fi
    fi

    # Write cooldown stamp
    printf '%s\n' "$now" > "$UPDATE_COOLDOWN_FILE"

    # Validate required env vars
    if [[ -z "$OTEL_SERVER" || -z "$OTEL_API_KEY" ]]; then
        log_warn "auto_update: OTEL_SERVER or OTEL_API_KEY not set — cannot spawn updater"
        return 1
    fi

    local local_version
    local_version=$(get_local_version)

    log_diag "DIAG auto_update TRIGGERED host=${NODE_NAME} local_version=${local_version}"

    log_diag "DIAG auto_update STARTED host=${NODE_NAME}"

    docker run -d --rm \
        --name nosana-updater \
        --network host \
        --pid host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /opt/nosana-telemetry:/opt/nosana-telemetry \
        -v /var/lib/docker:/var/lib/docker:ro \
        -v /etc/hostname:/etc/hostname:ro \
        -v /proc:/hostfs/proc:ro \
        -v /sys:/hostfs/sys:ro \
        alpine:3.21 \
        sh -c "
            apk add --no-cache bash wget curl docker-cli python3 >/dev/null 2>&1
            wget -qO /tmp/install.sh '${GITHUB_RAW}/install.sh'
            for attempt in 1 2 3; do
                bash /tmp/install.sh '${OTEL_SERVER}' '${OTEL_API_KEY}' && exit 0
                sleep 10
            done
            exit 1
        " 2>/dev/null

    local rc=$?
    if (( rc == 0 )); then
        log_diag "DIAG auto_update END host=${NODE_NAME} status=updater_spawned"
    else
        log_warn "auto_update: docker run failed (rc=${rc})"
    fi
    return $rc
}

update_check_loop() {
    [[ -z "$GITHUB_RAW" ]] && { log_info "GITHUB_RAW not set — auto-update disabled"; return; }
    [[ -z "$OTEL_SERVER" || -z "$OTEL_API_KEY" ]] && { log_info "OTEL_SERVER/OTEL_API_KEY not set — auto-update disabled"; return; }

    # Initial delay + jitter to spread fleet-wide checks
    local jitter=0
    if command -v shuf &>/dev/null; then
        jitter=$(shuf -i 0-${UPDATE_JITTER_MAX} -n 1)
    else
        jitter=$(( RANDOM % UPDATE_JITTER_MAX ))
    fi
    local total_delay=$(( UPDATE_INITIAL_DELAY + jitter ))
    log_info "auto_update: first check in ${total_delay}s (base=${UPDATE_INITIAL_DELAY}s + jitter=${jitter}s)"
    sleep "$total_delay"

    while true; do
        if check_for_update; then
            if spawn_updater; then
                # Updater spawned — install.sh will kill this sidecar, so just exit the loop
                log_info "auto_update: updater spawned — exiting check loop (sidecar will be replaced)"
                return
            fi
        fi
        sleep "$UPDATE_CHECK_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# SECTION 14: Startup initialization
# ---------------------------------------------------------------------------
main() {
    local sidecar_version
    sidecar_version=$(get_local_version)
    log_info "Nosana Diagnostics Sidecar starting (version ${sidecar_version}) node=${NODE_NAME}"

    # Create required directories and log file
    mkdir -p "$(dirname "$DIAG_LOG")" "$COOLDOWN_DIR"
    touch "$DIAG_LOG"

    # Load playbooks
    if ! load_playbooks; then
        log_warn "Initial playbook load failed — will retry after refresh"
    fi

    # Start background playbook refresh loop (runs in subshell)
    playbook_refresh_loop &
    REFRESH_PID=$!
    log_info "Playbook refresh loop started (pid=$REFRESH_PID, interval=${PLAYBOOK_REFRESH_INTERVAL}s)"

    # Start background auto-update check loop
    update_check_loop &
    UPDATE_PID=$!
    log_info "Auto-update check loop started (pid=$UPDATE_PID, interval=${UPDATE_CHECK_INTERVAL}s)"

    # Wait until container log files exist before starting tail
    wait_for_logs

    # Enter the main tail loop (blocks until container exits)
    tail_loop

    # Cleanup (reached only on SIGTERM/container stop)
    log_info "Diagnostics sidecar exiting — stopping background loops"
    kill "$REFRESH_PID" 2>/dev/null || true
    kill "$UPDATE_PID" 2>/dev/null || true
}

main "$@"
