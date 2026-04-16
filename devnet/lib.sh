#!/bin/bash
# lib.sh — shared helpers for xlayer-toolkit devnet scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Provides the same interface as the xlayer-node lib.sh so that load-test.sh
# and any other ported scripts run without modification.
#
# Variables set:
#   L2_RPC_URL          — L2 execution RPC (http://localhost:8123)
#   L2_ROLLUP_RPC_URL   — kona-node rollup RPC (http://localhost:9545)
#   AUTH_RPC_URL        — Engine API authrpc (http://localhost:8552)
#   JWT_SECRET_PATH     — path to JWT secret file (config-op/jwt.txt)
#
# Functions:
#   ok/fail/warn/info/step  — coloured log helpers
#   check_deps <cmd...>     — exit if any tool is missing
#   wait_for_rpc <url> [label] [timeout]  — poll until JSON-RPC responds

# Resolve devnet dir (same directory as this lib.sh)
DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from devnet dir
if [ -f "$DEVNET_DIR/.env" ]; then
    set -a
    source "$DEVNET_DIR/.env"
    set +a
else
    echo "[lib] WARNING: $DEVNET_DIR/.env not found"
fi

# RPC endpoints — match docker-compose.yml port mappings
L2_RPC_URL="${L2_RPC_URL:-http://localhost:8123}"
L2_ROLLUP_RPC_URL="${L2_ROLLUP_RPC_URL:-http://localhost:9545}"
AUTH_RPC_URL="${AUTH_RPC_URL:-http://localhost:8552}"

# JWT secret — volume-mounted from config-op/jwt.txt into op-seq container
# load-test.sh reads this file directly on the host to generate Bearer tokens
JWT_SECRET_PATH="${JWT_SECRET_PATH:-$DEVNET_DIR/config-op/jwt.txt}"

# ── colour helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
fail() { echo -e "${RED}❌ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $*${RESET}"; }
info() { echo -e "${CYAN}ℹ  $*${RESET}"; }
step() { echo -e "${BOLD}── $*${RESET}"; }

# ── dependency checks ─────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        fail "Missing required tools: ${missing[*]}"
        echo "  cast:    https://book.getfoundry.sh/getting-started/installation"
        echo "  jq:      brew install jq"
        echo "  curl:    brew install curl"
        echo "  python3: brew install python3"
        exit 1
    fi
}

# ── RPC wait helper ───────────────────────────────────────────────────────────
# Usage: wait_for_rpc <url> [label] [timeout_seconds]
wait_for_rpc() {
    local url="$1"
    local label="${2:-$url}"
    local timeout="${3:-120}"
    local elapsed=0
    step "Waiting for $label to be ready..."
    until curl -sf -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$url" | grep -q '"result"'; do
        if [ $elapsed -ge $timeout ]; then
            fail "Timeout waiting for $label after ${timeout}s"
            exit 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        echo -n "."
    done
    echo ""
    ok "$label is ready (${elapsed}s)"
}
