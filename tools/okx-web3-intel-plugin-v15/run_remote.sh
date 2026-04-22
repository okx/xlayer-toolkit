#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# OKX Web3 Intel Pipeline — Remote Runner
#
# Two modes:
#   1. Single run:  ./run_remote.sh --team wallet
#   2. Daemon mode: ./run_remote.sh --daemon  (long-running, matches cron from config)
#
# Requirements:
#   - claude CLI installed and logged in (npm install -g @anthropic-ai/claude-code && claude login)
#   - jq installed (for parsing pipeline_config.json)
#   - TWITTER_TOKEN env var set (optional, for 6551.io API)
#
# All times are in CST (UTC+8).
# ─────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR"
CONFIG_FILE="$SCRIPT_DIR/pipeline_config.json"
LOGS_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOGS_DIR"

# ── Logging ──────────────────────────────────────────────────────────

log() {
    echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

LOG_FILE="$LOGS_DIR/pipeline_$(TZ=Asia/Shanghai date +%Y-%m-%d).log"

# ── Run a single pipeline job ────────────────────────────────────────

run_job() {
    local team="$1"
    log ">>> Starting pipeline: team=${team}"

    local job_log="$LOGS_DIR/${team}_$(TZ=Asia/Shanghai date +%Y%m%d_%H%M).log"

    # Run Claude CLI with the plugin loaded
    # --dangerously-skip-permissions: no interactive prompts (required for automation)
    # --plugin-dir: load the plugin so skills are available
    # -p: non-interactive/headless mode
    claude \
        --dangerously-skip-permissions \
        -p "Run the Web3 intel pipeline for team=${team} and push to Lark. Read the insight-decision-flow SKILL.md and follow all steps." \
        --plugin-dir "$PLUGIN_DIR" \
        --output-format text \
        > "$job_log" 2>&1

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log "<<< Pipeline done: team=${team} (log: $job_log)"
    else
        log "!!! Pipeline FAILED: team=${team} exit_code=${exit_code} (log: $job_log)"
    fi

    return $exit_code
}

# ── Cron matching (for daemon mode) ──────────────────────────────────

matches_cron() {
    local cron="$1"
    local cron_min cron_hour _rest
    read -r cron_min cron_hour _rest <<< "$cron"
    local cur_min=$(TZ=Asia/Shanghai date +%-M)
    local cur_hour=$(TZ=Asia/Shanghai date +%-H)

    # Match minute
    local min_ok=false
    if [ "$cron_min" = "*" ]; then
        min_ok=true
    else
        IFS=',' read -ra mins <<< "$cron_min"
        for m in "${mins[@]}"; do
            [ "$m" -eq "$cur_min" ] 2>/dev/null && min_ok=true && break
        done
    fi

    # Match hour
    local hour_ok=false
    if [ "$cron_hour" = "*" ]; then
        hour_ok=true
    else
        IFS=',' read -ra hours <<< "$cron_hour"
        for h in "${hours[@]}"; do
            [ "$h" -eq "$cur_hour" ] 2>/dev/null && hour_ok=true && break
        done
    fi

    [ "$min_ok" = "true" ] && [ "$hour_ok" = "true" ]
}

sleep_to_next_minute() {
    local now_sec=$(date +%S)
    now_sec=$((10#$now_sec))
    local wait=$(( 60 - now_sec ))
    sleep "$wait"
}

# ── Daemon mode ──────────────────────────────────────────────────────

run_daemon() {
    # Load jobs from config
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: $CONFIG_FILE not found"
        exit 1
    fi

    local JOBS=()
    while IFS= read -r line; do
        JOBS+=("$line")
    done < <(jq -r '.schedule.jobs[] | "\(.cron)|\(.team)"' "$CONFIG_FILE")

    log "=== Daemon started (${#JOBS[@]} jobs) ==="
    for job in "${JOBS[@]}"; do
        local cron="${job%%|*}"
        local team="${job##*|}"
        log "  Registered: team=${team}  cron=\"${cron}\""
    done

    # Align to next minute
    sleep_to_next_minute

    while true; do
        # Rotate log file daily
        LOG_FILE="$LOGS_DIR/pipeline_$(TZ=Asia/Shanghai date +%Y-%m-%d).log"

        for job in "${JOBS[@]}"; do
            local cron="${job%%|*}"
            local team="${job##*|}"

            if matches_cron "$cron"; then
                # Run in background so multiple jobs at the same minute don't block each other
                run_job "$team" &
            fi
        done

        # Wait for background jobs to finish before sleeping
        wait

        sleep_to_next_minute
    done
}

# ── Main ─────────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
Usage:
  ./run_remote.sh                      Run pipeline for xlayer (default)
  ./run_remote.sh --team <team_id>     Run pipeline once for a specific team
  ./run_remote.sh --daemon             Long-running daemon (matches cron from config)
  ./run_remote.sh --help               Show this help

Examples:
  ./run_remote.sh                      # Run xlayer team (default)
  ./run_remote.sh --team wallet        # Single run for wallet team
  ./run_remote.sh --team web3          # Single run for web3 team
  ./run_remote.sh --daemon             # Start daemon (runs forever)

  # Via system cron (alternative to daemon mode):
  # 0 8,20 * * *  /path/to/run_remote.sh --team web3
  # 0 10 * * *    /path/to/run_remote.sh --team wallet
  # 0 12 * * *    /path/to/run_remote.sh --team xlayer
  # 0 14 * * *    /path/to/run_remote.sh --team dex
  # 0 18 * * *    /path/to/run_remote.sh --team pay
EOF
}

case "${1:-}" in
    --team)
        if [ -z "${2:-}" ]; then
            echo "ERROR: --team requires a team ID"
            usage
            exit 1
        fi
        run_job "$2"
        ;;
    --daemon)
        run_daemon
        ;;
    --help|-h)
        usage
        ;;
    "")
        log "=== Running xlayer team ==="
        run_job "xlayer" || true
        log "=== Done ==="
        ;;
    *)
        echo "ERROR: Unknown option '${1:-}'"
        usage
        exit 1
        ;;
esac
