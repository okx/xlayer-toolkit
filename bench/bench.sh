#!/usr/bin/env bash
# bench.sh — switch to a stack, verify health, run bench, save report
#
# Usage:
#   bash bench.sh op-node               [--duration 60] [--workers 20] --sender adventure
#   bash bench.sh kona-okx-baseline     [--duration 60] [--workers 20] --sender adventure
#   bash bench.sh kona-okx-optimised     [--duration 60] [--workers 20] --sender adventure
#   bash bench.sh base-cl               [--duration 60] [--workers 20] --sender adventure
#   bash bench.sh xlayer-node           [--duration 60] [--workers 6]
#
# HOW IT WORKS:
#   All toolkit stacks share the same L1 (l1-geth + l1-beacon-chain).
#   toolkit vs toolkit-kona vs toolkit-base-cl differ only in the CL container.
#   bench.sh ensures exactly one stack is running, then runs simple-bench.sh.
#
# STACK SWITCH (~4 min for toolkit, ~30s for toolkit→toolkit-kona/base-cl):
#   toolkit start = L1 fresh init (init containers) + OP contract deploy +
#                   L2 genesis init + L2 service start.  One-time reliable path.
#   toolkit-kona    = same L1 init + kona-node as CL instead of op-geth.
#   toolkit-base-cl = same L1 init + base-consensus as CL instead of op-geth.
#   xlayer-node     = delegates to start-all.sh (smart resume/fresh-init).
#
# SAME STACK RE-RUN (~0 s):
#   If correct stack is already running, switch is skipped entirely.
#
# REPORTS: ~/xlayer-bench-reports/bench-{stack}-{YYYYMMDD_HHMMSS}.txt

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$BENCH_DIR/../devnet"
XLAYER_DIR="/Users/lakshmikanth/Documents/projects/xlayer-node-components/working/xlayer"
TOOLKIT_COMPOSE="$TOOLKIT_DIR/docker-compose.yml"
L1_RPC="http://localhost:8545"
L2_RPC="http://localhost:8123"

# ── Colour helpers ─────────────────────────────────────────────────────────────
_B="\033[1m"; _G="\033[0;32m"; _Y="\033[1;33m"; _R="\033[0;31m"; _C="\033[0;36m"; _N="\033[0m"
step() { echo -e "${_B}── $*${_N}"; }
ok()   { echo -e "${_G}✅ $*${_N}"; }
warn() { echo -e "${_Y}⚠️  $*${_N}"; }
fail() { echo -e "${_R}❌ $*${_N}"; exit 1; }
info() { echo -e "${_C}ℹ  $*${_N}"; }

# ── Args ───────────────────────────────────────────────────────────────────────
STACK="${1:-}"
shift || true
[[ "$STACK" == "op-node" || "$STACK" == "kona-okx-baseline" || "$STACK" == "kona-okx-optimised" || \
   "$STACK" == "base-cl" || "$STACK" == "xlayer-node" ]] || {
    echo "Usage: bench.sh [op-node|kona-okx-baseline|kona-okx-optimised|base-cl|xlayer-node] [--gas-limit 200M|500M] [--duration N] [--workers N] [--sender native|adventure]"
    exit 1
}

# Parse --sender / --workers / --duration / --gas-limit out of remaining args, pass everything else through
SENDER="native"
WORKERS=20
DURATION=120
GAS_LIMIT=""   # 200M | 500M — patches intent.toml.bak before stack start
FORCE_CLEAN=false  # --force-clean: tear down + fresh genesis even if same CL is healthy
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sender)      SENDER="${2:?--sender requires a value}";    shift 2 ;;
        --workers)     WORKERS="${2:?--workers requires a value}";  shift 2 ;;
        --duration)    DURATION="${2:?--duration requires a value}"; shift 2 ;;
        --gas-limit)   GAS_LIMIT="${2:?--gas-limit requires 200M or 500M}"; shift 2 ;;
        --force-clean) FORCE_CLEAN=true; shift ;;
        *)             PASS_ARGS+=("$1"); shift ;;
    esac
done
set -- "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}"

# ── Nuclear stop: wipe all containers for a compose project ───────────────────
nuke_compose() {
    local compose_file="$1"
    [[ -f "$compose_file" ]] || return 0
    docker compose -f "$compose_file" down --remove-orphans --timeout 10 2>/dev/null || true
}

# Force-remove every container that could conflict by name
nuke_shared_containers() {
    for c in l1-geth l1-geth-remove-db l1-beacon-chain l1-beacon-remove-db \
              l1-create-beacon-chain-genesis l1-fix-genesis-fork-times l1-geth-genesis \
              l1-validator op-seq op-kona op-base-cl op-reth-seq op-batcher; do
        docker rm -f "$c" 2>/dev/null || true
    done
}

# Remove xlayer-devnet network (each compose project must own it)
clean_network() {
    local containers
    containers=$(docker network inspect xlayer-devnet \
        --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    for c in $containers; do
        docker network disconnect -f xlayer-devnet "$c" 2>/dev/null || true
    done
    docker network rm xlayer-devnet 2>/dev/null || true
}

# ── Gas limit patcher ──────────────────────────────────────────────────────────
# Patches intent.toml.bak before stack start so op-deployer bakes the correct
# gas limit into genesis.json on the next deployment.
patch_gas_limit() {
    local mode="$1"
    local toml="$TOOLKIT_DIR/config-op/intent.toml.bak"
    [[ -f "$toml" ]] || { warn "intent.toml.bak not found at $toml — skipping gas limit patch"; return; }
    case "$mode" in
        200M)
            sed -i '' 's/gasLimit = [0-9]*/gasLimit = 200000000/' "$toml"
            sed -i '' 's/l2GenesisBlockGasLimit = ".*"/l2GenesisBlockGasLimit = "0xbebc200"/' "$toml"
            ;;
        500M)
            sed -i '' 's/gasLimit = [0-9]*/gasLimit = 500000000/' "$toml"
            sed -i '' 's/l2GenesisBlockGasLimit = ".*"/l2GenesisBlockGasLimit = "0x1dcd6500"/' "$toml"
            ;;
        *) fail "--gas-limit must be 200M or 500M (got: $mode)" ;;
    esac
    ok "Gas limit patched to $mode in intent.toml.bak"
}

# ── Stop toolkit ───────────────────────────────────────────────────────────────
stop_toolkit() {
    step "Stopping xlayer-toolkit..."
    nuke_compose "$TOOLKIT_COMPOSE"
    nuke_shared_containers
    ok "xlayer-toolkit stopped"
}

# ── Stop toolkit-kona (just the CL + EL + batcher, keeps L1 running) ──────────
stop_toolkit_kona() {
    step "Stopping toolkit-kona services..."
    docker rm -f op-kona op-reth-seq op-batcher 2>/dev/null || true
    ok "toolkit-kona stopped"
}

# ── Stop toolkit-base-cl (just the CL + EL + batcher, keeps L1 running) ───────
stop_toolkit_base_cl() {
    step "Stopping toolkit-base-cl services..."
    docker rm -f op-base-cl op-reth-seq op-batcher 2>/dev/null || true
    ok "toolkit-base-cl stopped"
}

# ── Stop xlayer-node ───────────────────────────────────────────────────────────
stop_xlayer_node() {
    step "Stopping xlayer-node..."
    pkill -f "xlayer-node node" 2>/dev/null || true
    sleep 1
    # stop xlayer-node's docker-managed L1 + op-batcher
    XLAYER_COMPOSE="$XLAYER_DIR/docker/docker-compose.devnet.yml"
    nuke_compose "$XLAYER_COMPOSE"
    nuke_shared_containers
    ok "xlayer-node stopped"
}

# ── Wait for L1 blocks to advance ─────────────────────────────────────────────
wait_l1_advancing() {
    local timeout="${1:-180}"
    local prev; prev=$(cast bn --rpc-url "$L1_RPC" 2>/dev/null || echo 0)
    local deadline=$(( SECONDS + timeout ))
    echo -n "    waiting for L1 to advance (up to ${timeout}s)"
    while [[ $SECONDS -lt $deadline ]]; do
        sleep 3
        local cur; cur=$(cast bn --rpc-url "$L1_RPC" 2>/dev/null || echo 0)
        if [[ "$cur" -gt "$prev" ]]; then
            echo "  block $prev → $cur"
            ok "L1 is advancing"
            return 0
        fi
        echo -n "."
    done
    echo ""
    return 1
}

# ── Wait for engine API to be ready (sequencer advancing proxy) ───────────────
# After a stack switch, reth may respond on the L2 RPC before its engine API
# is fully initialized. The sequencer CL (kona / op-node) will try to call the
# engine API immediately on start and stall if it isn't ready yet.
#
# Strategy: poll until blocks actually advance (proves CL→reth engine API path
# is working). If not advancing within timeout, restart the CL container once
# and retry. Hard-fail if still stuck after the retry.
#
# Args: $1 = CL container name (for restart on failure)
#        $2 = timeout seconds (default 90)
wait_engine_ready() {
    local cl_container="${1:-}"
    local timeout="${2:-90}"
    local deadline=$(( SECONDS + timeout ))
    local prev
    prev=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        2>/dev/null | python3 -c \
        "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
    echo -n "    waiting for sequencer/engine-API to advance blocks (up to ${timeout}s)"
    while [[ $SECONDS -lt $deadline ]]; do
        sleep 3
        local cur
        cur=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            2>/dev/null | python3 -c \
            "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
        if [[ "$cur" -gt "$prev" ]]; then
            echo "  block $prev → $cur"
            ok "Engine API ready — sequencer advancing"
            return 0
        fi
        echo -n "."
    done
    echo ""
    # ── Auto-recovery: restart the CL container and give it one more chance ───
    if [[ -n "$cl_container" ]]; then
        warn "Engine API not ready after ${timeout}s — restarting CL container: $cl_container"
        docker restart "$cl_container" 2>/dev/null || true
        sleep 10
        # Refresh baseline after restart
        prev=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            2>/dev/null | python3 -c \
            "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
        echo -n "    retrying after restart (up to 90s)"
        local retry_deadline=$(( SECONDS + 90 ))
        while [[ $SECONDS -lt $retry_deadline ]]; do
            sleep 3
            local rcur
            rcur=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
                2>/dev/null | python3 -c \
                "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
            if [[ "$rcur" -gt "$prev" ]]; then
                echo "  block $prev → $rcur"
                ok "Engine API ready after restart"
                return 0
            fi
            echo -n "."
        done
        echo ""
    fi
    fail "Sequencer stuck — engine API not responding. Check: docker logs $cl_container"
}

# ── Wait for derivation pipeline to sync (unsafe-safe gap < threshold) ────────
# After a fresh genesis, the derivation pipeline replays blocks from L1.
# If measurement starts while derivation is still catching up, Consolidate
# tasks flood the engine queue and distort latency metrics.
#
# Strategy: poll optimism_syncStatus until unsafe_l2 − safe_l2 < MAX_GAP.
# Hard-fail after timeout — something is wrong with derivation.
#
# Args: $1 = max allowed gap (default 10)
#        $2 = timeout seconds (default 120)
wait_derivation_sync() {
    local max_gap="${1:-10}"
    local timeout="${2:-120}"
    local rollup_rpc="http://localhost:9545"
    local deadline=$(( SECONDS + timeout ))
    echo -n "    waiting for derivation sync (unsafe-safe gap < ${max_gap})"
    while [[ $SECONDS -lt $deadline ]]; do
        local gap
        gap=$(python3 -c "
import json, urllib.request, sys
try:
    r = urllib.request.Request('$rollup_rpc',
        data=json.dumps({'jsonrpc':'2.0','id':1,'method':'optimism_syncStatus','params':[]}).encode(),
        headers={'Content-Type':'application/json'}, method='POST')
    with urllib.request.urlopen(r, timeout=5) as res:
        s = json.loads(res.read()).get('result', {})
    unsafe = int(s.get('unsafe_l2',{}).get('number',0))
    safe   = int(s.get('safe_l2',{}).get('number',0))
    print(unsafe - safe)
except Exception as e:
    print(-1)
" 2>/dev/null || echo -1)
        if [[ "$gap" -ge 0 ]] && [[ "$gap" -lt "$max_gap" ]]; then
            echo "  gap=$gap"
            ok "Derivation pipeline synced (unsafe-safe gap=$gap)"
            return 0
        fi
        echo -n " gap=${gap}."
        sleep 3
    done
    echo ""
    warn "Derivation pipeline still catching up after ${timeout}s — measurement may be unreliable"
    return 0   # warn but don't block — let the run proceed with a warning
}

# ── Wait for L2 RPC ────────────────────────────────────────────────────────────
wait_l2() {
    echo -n "    waiting for L2 RPC"
    local deadline=$(( SECONDS + 180 ))
    while [[ $SECONDS -lt $deadline ]]; do
        local bn
        bn=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            2>/dev/null | python3 -c \
            "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
        if [[ "$bn" -gt 0 ]]; then
            echo "  block $bn"
            ok "L2 RPC ready"
            return 0
        fi
        echo -n "."; sleep 2
    done
    echo ""
    fail "L2 RPC did not respond after 180s"
}

# ── Start toolkit stack (always fresh init — avoids beacon catch-up issues) ───
#
# Why always fresh, not resume?
#   The toolkit L1 uses Prysm + geth. After a stop, Prysm restarts in beacon
#   catch-up mode and does NOT advance geth's EL canonical head until it has
#   fully synced all missed epochs. This can take many minutes and is unreliable.
#   A fresh genesis init (via init containers) sidesteps this entirely — genesis
#   starts at current real time so Prysm never needs to catch up.
#
# This path is only reached when toolkit is NOT currently running (stack switch).
# When toolkit is already running, detect_active() returns "toolkit" and the
# switch is skipped entirely (fast path).
start_toolkit() {
    cd "$TOOLKIT_DIR"
    source .env 2>/dev/null || true

    # ── L1: fresh init (init containers generate genesis at current time) ──────
    step "Starting toolkit L1 (fresh genesis — init containers)..."
    docker compose -f "$TOOLKIT_COMPOSE" up -d l1-geth l1-beacon-chain l1-validator

    echo -n "    waiting for L1 geth"
    until cast rpc eth_syncing --rpc-url "$L1_RPC" 2>/dev/null | grep -q "false"; do
        echo -n "."; sleep 1
    done
    echo "  block $(cast bn --rpc-url "$L1_RPC")"
    ok "L1 geth ready"

    if ! wait_l1_advancing 120; then
        warn "L1 stuck — restarting beacon chain..."
        docker compose -f "$TOOLKIT_COMPOSE" restart l1-beacon-chain l1-validator 2>/dev/null || true
        sleep 15
        wait_l1_advancing 180 || fail "L1 not advancing. Run: docker logs l1-beacon-chain"
    fi

    # ── Fund operator accounts (batcher / proposer / challenger) ──────────────
    step "Funding operator accounts on L1..."
    for key_var in OP_BATCHER_PRIVATE_KEY OP_PROPOSER_PRIVATE_KEY OP_CHALLENGER_PRIVATE_KEY; do
        local key="${!key_var:-}"
        [[ -z "$key" ]] && continue
        local addr; addr=$(cast wallet address "$key" 2>/dev/null || true)
        [[ -z "$addr" ]] && continue
        cast send --private-key "$RICH_L1_PRIVATE_KEY" --value 100ether "$addr" \
            --legacy --rpc-url "$L1_RPC" > /dev/null 2>&1 || true
    done
    ok "Operators funded"

    # ── Deploy OP contracts ────────────────────────────────────────────────────
    step "Deploying OP contracts to L1..."
    bash 2-deploy-op-contracts.sh

    # ── Initialize L2 genesis (skip dispute-game prestate for speed) ──────────
    step "Initializing L2 genesis (MIN_RUN)..."
    MIN_RUN=true bash 3-op-init.sh

    # ── Start L2 services ─────────────────────────────────────────────────────
    step "Starting L2 services..."
    bash 4-op-start-service.sh

    wait_l2
}

# ── Start toolkit-kona stack ──────────────────────────────────────────────────
# Same L1 as toolkit, but uses kona-node (image from KONA_IMAGE env var) as CL.
# Requires L1 to already be running (call start_toolkit first, or reuse running L1).
start_toolkit_kona() {
    cd "$TOOLKIT_DIR"
    source .env 2>/dev/null || true

    # L1 must be running — start fresh if not yet up
    local l1_bn
    l1_bn=$(cast bn --rpc-url "$L1_RPC" 2>/dev/null || echo 0)
    if [[ "$l1_bn" -eq 0 ]]; then
        # ── L1: fresh init ────────────────────────────────────────────────────
        step "Starting toolkit L1 (fresh genesis — init containers)..."
        docker compose -f "$TOOLKIT_COMPOSE" up -d l1-geth l1-beacon-chain l1-validator

        echo -n "    waiting for L1 geth"
        until cast rpc eth_syncing --rpc-url "$L1_RPC" 2>/dev/null | grep -q "false"; do
            echo -n "."; sleep 1
        done
        echo "  block $(cast bn --rpc-url "$L1_RPC")"
        ok "L1 geth ready"

        if ! wait_l1_advancing 120; then
            warn "L1 stuck — restarting beacon chain..."
            docker compose -f "$TOOLKIT_COMPOSE" restart l1-beacon-chain l1-validator 2>/dev/null || true
            sleep 15
            wait_l1_advancing 180 || fail "L1 not advancing. Run: docker logs l1-beacon-chain"
        fi

        # Fund + deploy contracts (fresh L1 needs them)
        step "Funding operator accounts on L1..."
        for key_var in OP_BATCHER_PRIVATE_KEY OP_PROPOSER_PRIVATE_KEY OP_CHALLENGER_PRIVATE_KEY; do
            local key="${!key_var:-}"
            [[ -z "$key" ]] && continue
            local addr; addr=$(cast wallet address "$key" 2>/dev/null || true)
            [[ -z "$addr" ]] && continue
            cast send --private-key "$RICH_L1_PRIVATE_KEY" --value 100ether "$addr" \
                --legacy --rpc-url "$L1_RPC" > /dev/null 2>&1 || true
        done
        ok "Operators funded"

        step "Deploying OP contracts to L1..."
        bash 2-deploy-op-contracts.sh

        step "Initializing L2 genesis (MIN_RUN)..."
        MIN_RUN=true bash 3-op-init.sh

        # Update rollup.json genesis.l2.hash — 3-op-init.sh writes NEW_BLOCK_HASH to .env
        # but only 4-op-start-service.sh normally patches rollup.json. Do it here instead.
        source .env 2>/dev/null || true
        if [[ -n "${NEW_BLOCK_HASH:-}" ]]; then
            jq ".genesis.l2.hash = \"$NEW_BLOCK_HASH\"" config-op/rollup.json \
                > config-op/rollup.json.tmp && mv config-op/rollup.json.tmp config-op/rollup.json
            ok "rollup.json genesis.l2.hash = $NEW_BLOCK_HASH"
        else
            fail "NEW_BLOCK_HASH not set after 3-op-init.sh — cannot update rollup.json"
        fi
    else
        ok "L1 already running at block $l1_bn — reusing"
    fi

    # ── Start L2 with kona as CL ──────────────────────────────────────────────
    # Override batcher endpoints: kona RPC is op-kona:9545 not op-seq:9545
    # KONA_IMAGE is exported by bench.sh (_KONA_IMAGE) so docker-compose picks
    # up the right variant via ${KONA_IMAGE:-kona-node:okx-optimised} in the image field.
    step "Starting op-reth-seq (EL) + op-kona (${KONA_IMAGE:-kona-node:okx-optimised}) + op-batcher..."
    OP_BATCHER_ROLLUP_RPC="http://op-kona:9545" \
    OP_BATCHER_L2_ETH_RPC="http://op-reth-seq:8545" \
    docker compose -f "$TOOLKIT_COMPOSE" up -d op-reth-seq op-kona op-batcher

    wait_l2
}

# ── Start toolkit-base-cl stack ───────────────────────────────────────────────
# Same L1 as toolkit, but uses base-consensus (base-consensus:dev) as CL.
# Requires L1 to already be running (call start_toolkit first, or reuse running L1).
start_toolkit_base_cl() {
    cd "$TOOLKIT_DIR"
    source .env 2>/dev/null || true

    # L1 must be running — start fresh if not yet up
    local l1_bn
    l1_bn=$(cast bn --rpc-url "$L1_RPC" 2>/dev/null || echo 0)
    if [[ "$l1_bn" -eq 0 ]]; then
        # ── L1: fresh init ────────────────────────────────────────────────────
        step "Starting toolkit L1 (fresh genesis — init containers)..."
        docker compose -f "$TOOLKIT_COMPOSE" up -d l1-geth l1-beacon-chain l1-validator

        echo -n "    waiting for L1 geth"
        until cast rpc eth_syncing --rpc-url "$L1_RPC" 2>/dev/null | grep -q "false"; do
            echo -n "."; sleep 1
        done
        echo "  block $(cast bn --rpc-url "$L1_RPC")"
        ok "L1 geth ready"

        if ! wait_l1_advancing 120; then
            warn "L1 stuck — restarting beacon chain..."
            docker compose -f "$TOOLKIT_COMPOSE" restart l1-beacon-chain l1-validator 2>/dev/null || true
            sleep 15
            wait_l1_advancing 180 || fail "L1 not advancing. Run: docker logs l1-beacon-chain"
        fi

        # Fund + deploy contracts (fresh L1 needs them)
        step "Funding operator accounts on L1..."
        for key_var in OP_BATCHER_PRIVATE_KEY OP_PROPOSER_PRIVATE_KEY OP_CHALLENGER_PRIVATE_KEY; do
            local key="${!key_var:-}"
            [[ -z "$key" ]] && continue
            local addr; addr=$(cast wallet address "$key" 2>/dev/null || true)
            [[ -z "$addr" ]] && continue
            cast send --private-key "$RICH_L1_PRIVATE_KEY" --value 100ether "$addr" \
                --legacy --rpc-url "$L1_RPC" > /dev/null 2>&1 || true
        done
        ok "Operators funded"

        step "Deploying OP contracts to L1..."
        bash 2-deploy-op-contracts.sh

        step "Initializing L2 genesis (MIN_RUN)..."
        MIN_RUN=true bash 3-op-init.sh

        # Update rollup.json genesis.l2.hash
        source .env 2>/dev/null || true
        if [[ -n "${NEW_BLOCK_HASH:-}" ]]; then
            jq ".genesis.l2.hash = \"$NEW_BLOCK_HASH\"" config-op/rollup.json \
                > config-op/rollup.json.tmp && mv config-op/rollup.json.tmp config-op/rollup.json
            ok "rollup.json genesis.l2.hash = $NEW_BLOCK_HASH"
        else
            fail "NEW_BLOCK_HASH not set after 3-op-init.sh — cannot update rollup.json"
        fi
    else
        ok "L1 already running at block $l1_bn — reusing"
    fi

    # ── Start L2 with base-consensus as CL ───────────────────────────────────
    # Override batcher endpoints: base-consensus RPC is op-base-cl:9545
    step "Starting op-reth-seq (EL) + op-base-cl (base-consensus CL) + op-batcher..."
    OP_BATCHER_ROLLUP_RPC="http://op-base-cl:9545" \
    OP_BATCHER_L2_ETH_RPC="http://op-reth-seq:8545" \
    docker compose -f "$TOOLKIT_COMPOSE" up -d op-reth-seq op-base-cl op-batcher

    wait_l2
}

# ── Start xlayer-node stack ────────────────────────────────────────────────────
# Delegates to start-all.sh which has built-in smart resume/reinit logic.
start_xlayer_node() {
    step "Starting xlayer-node stack..."
    cd "$XLAYER_DIR"
    bash scripts/devnet/start-all.sh --no-build
}

# ── Detect active stack ────────────────────────────────────────────────────────
detect_active() {
    local bn
    bn=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        2>/dev/null | python3 -c \
        "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
    [[ "$bn" -eq 0 ]] && echo "none" && return
    pgrep -qf "xlayer-node node" && echo "xlayer-node" && return
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^op-base-cl$"; then
        echo "base-cl"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^op-kona$"; then
        # Identify kona variant by comparing running image ID against known tags
        local running_img; running_img=$(docker inspect op-kona --format '{{.Image}}' 2>/dev/null || echo "")
        for entry in "kona-okx-baseline:kona-node:okx-baseline" \
                     "kona-okx-optimised:kona-node:okx-optimised"; do
            local vname="${entry%%:*}"
            local vtag="${entry#*:}"
            local vid; vid=$(docker inspect "$vtag" --format '{{.Id}}' 2>/dev/null || echo "")
            [[ -n "$vid" && "$running_img" == "$vid" ]] && echo "$vname" && return
        done
        echo "kona-okx-optimised"  # fallback if image ID doesn't match any known tag
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^op-seq$"; then
        echo "op-node"
    else
        echo "none"
    fi
}

# ── Verify active stack is actually healthy (blocks advancing) ─────────────────
# Prevents re-using a stack that is running but stuck (e.g. no contracts on L1).
verify_stack_healthy() {
    local prev; prev=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        2>/dev/null | python3 -c \
        "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
    sleep 5
    local cur; cur=$(curl -sf -X POST "$L2_RPC" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        2>/dev/null | python3 -c \
        "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo 0)
    [[ "$cur" -gt "$prev" ]]
}

# ── Main ───────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Patch gas limit in intent.toml.bak before stack start (if requested)
[[ -n "$GAS_LIMIT" ]] && patch_gas_limit "$GAS_LIMIT"

# Map stack → CL name (report filename), container name, kona image tag
case "$STACK" in
    op-node)                  _CL_NAME="op-node";                  _CL_CONTAINER="op-seq";     _KONA_IMAGE="" ;;
    kona-okx-baseline)        _CL_NAME="kona-okx-baseline";        _CL_CONTAINER="op-kona";    _KONA_IMAGE="kona-node:okx-baseline" ;;
    kona-okx-optimised)       _CL_NAME="kona-okx-optimised";       _CL_CONTAINER="op-kona";    _KONA_IMAGE="kona-node:okx-optimised" ;;
    base-cl)                  _CL_NAME="base-cl";                  _CL_CONTAINER="op-base-cl"; _KONA_IMAGE="" ;;
    xlayer-node)              _CL_NAME="xlayer-node";              _CL_CONTAINER="";           _KONA_IMAGE="" ;;
esac

# Fetch block gas limit for run directory naming.
# If --gas-limit was provided, use it directly — reading from the chain before
# the stack switch returns the PREVIOUS stack's gas limit (timing race), which
# causes the first CL in a session to land in a misnamed directory.
if [[ -n "$GAS_LIMIT" ]]; then
    _GAS_LIMIT_RAW="$GAS_LIMIT"
else
    _GAS_LIMIT_RAW=$(python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.Request('$L2_RPC',
        data=json.dumps({'jsonrpc':'2.0','id':1,'method':'eth_getBlockByNumber','params':['latest',False]}).encode(),
        headers={'Content-Type':'application/json'}, method='POST')
    with urllib.request.urlopen(r, timeout=3) as res:
        b = json.loads(res.read()).get('result',{})
        g = int(b.get('gasLimit','0x0'), 16)
        if g >= 1_000_000: print(f'{g//1_000_000}M')
        elif g >= 1_000:   print(f'{g//1_000}K')
        else:              print(str(g))
except: print('unknown')
" 2>/dev/null)
fi

# Run-type label: {sender}-{workers}w-{duration}s-{gaslimit}gas
if [[ "$SENDER" == "adventure" ]]; then
    _RUN_TYPE="adv-erc20-${WORKERS}w-${DURATION}s-${_GAS_LIMIT_RAW}gas"
else
    _RUN_TYPE="native-${WORKERS}w-${DURATION}s-${_GAS_LIMIT_RAW}gas"
fi

# All CLs for the same run-type + timestamp share one session directory.
# Pass SESSION_TS=<timestamp> from outside to group all 3 CLs in one dir.
_SESSION_TS="${SESSION_TS:-$TIMESTAMP}"
REPORT_DIR="$BENCH_DIR/runs/${_RUN_TYPE}-${_SESSION_TS}"
mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/${_CL_NAME}.md"
export METRICS_JSON_OUT="$REPORT_DIR/${_CL_NAME}.json"
export BLOCKS_JSON_OUT="$REPORT_DIR/${_CL_NAME}.blocks.json"
export CL_LOG_OUT="$REPORT_DIR/${_CL_NAME}.cl.log"

ACTIVE=$(detect_active)
info "Active: ${ACTIVE}  →  target: ${STACK}"

NEED_SWITCH=false
if [[ "$FORCE_CLEAN" == "true" ]]; then
    warn "--force-clean: tearing down and re-initialising from scratch..."
    NEED_SWITCH=true
elif [[ "$ACTIVE" != "$STACK" ]]; then
    NEED_SWITCH=true
elif ! verify_stack_healthy; then
    warn "Stack '${STACK}' is running but L2 blocks are not advancing — forcing restart..."
    NEED_SWITCH=true
fi

if [[ "$NEED_SWITCH" == "true" ]]; then
    # All toolkit variants share the same L1 + init scripts.
    # Any switch between them requires a full teardown so start functions
    # get a clean slate (no orphan L1 containers, no stale contract addresses).
    if [[ "$ACTIVE" == "op-node" || "$ACTIVE" == base-cl || "$ACTIVE" == kona-* ]]; then
        stop_toolkit
    elif [[ "$ACTIVE" == "xlayer-node" ]]; then
        stop_xlayer_node
    else
        # "none" or unknown stuck state — clean up everything
        stop_toolkit 2>/dev/null || true
        stop_xlayer_node 2>/dev/null || true
    fi
    clean_network

    # Start target stack
    if [[ "$STACK" == "op-node" ]]; then
        start_toolkit
    elif [[ "$STACK" == kona-* ]]; then
        export KONA_IMAGE="$_KONA_IMAGE"
        start_toolkit_kona
    elif [[ "$STACK" == "base-cl" ]]; then
        start_toolkit_base_cl
    else
        start_xlayer_node
    fi

    # After any stack switch, verify the sequencer is actually advancing blocks.
    # wait_l2 only checks that the RPC responds — reth's engine API may not be
    # ready yet. wait_engine_ready polls until blocks advance, auto-restarting
    # the CL container once if stuck.
    if [[ "$STACK" != "xlayer-node" ]]; then
        wait_engine_ready "$_CL_CONTAINER" 90
        # Ensure derivation pipeline has caught up before handing off to
        # bench-adventure.sh.  Without this, a cold-start CL can still be
        # replaying blocks from L1, flooding Consolidate tasks into the
        # engine queue and distorting latency metrics (see: Run 2 base-cl
        # incident — p50 dropped 70× because measurement started mid-sync).
        wait_derivation_sync 10 120
    fi
else
    ok "Stack '${STACK}' is running and healthy — skipping switch"
fi

# ── Run bench, live output + save clean report ─────────────────────────────────
echo ""
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

if [[ "$STACK" != "xlayer-node" ]]; then
    if [[ "$SENDER" == "adventure" ]]; then
        step "Running bench-adventure.sh for ${STACK} (adventure sender)..."
        set +o pipefail
        SEQ_CONTAINER="$_CL_CONTAINER" bash "$BENCH_DIR/scripts/bench-adventure.sh" \
            --stack "$STACK" --workers "$WORKERS" --duration "$DURATION" "$@" 2>&1 | tee "$TMPOUT"
        _BENCH_RC=${PIPESTATUS[0]}
        set -o pipefail
    else
        fail "Native sender is no longer supported. Use --sender adventure."
    fi
else
    if [[ "$SENDER" == "adventure" ]]; then
        step "Running bench-adventure.sh for xlayer-node (adventure sender)..."
        set +o pipefail
        bash "$BENCH_DIR/scripts/bench-adventure.sh" --stack "$STACK" --workers "$WORKERS" --duration "$DURATION" "$@" 2>&1 | tee "$TMPOUT"
        _BENCH_RC=${PIPESTATUS[0]}
        set -o pipefail
    else
        fail "Native sender is no longer supported. Use --sender adventure."
    fi
fi

# Strip ANSI escape codes and save report — always, even on partial failure
python3 -c "
import sys, re
txt = open(sys.argv[1]).read()
print(re.sub(r'\x1b\[[0-9;]*[mK]', '', txt), end='')
" "$TMPOUT" > "$REPORT_FILE"

echo ""
if [[ "${_BENCH_RC:-0}" -ne 0 ]]; then
    warn "Bench exited with code ${_BENCH_RC} — partial report saved → $REPORT_FILE"
    exit "${_BENCH_RC}"
else
    ok "Report saved → $REPORT_FILE"
fi

# ── Auto-generate comparison.md whenever ≥2 CL JSON sidecars exist ────────────
_JSON_FILES=("$REPORT_DIR"/*.json)
# Filter out *.blocks.json and *.fcu-correlation files — only CL sidecar JSONs
_CL_JSON_FILES=()
for _f in "${_JSON_FILES[@]}"; do
    [[ "$_f" == *.blocks.json ]] && continue
    [[ -f "$_f" ]] && _CL_JSON_FILES+=("$_f")
done
if [[ "${#_CL_JSON_FILES[@]}" -ge 2 ]]; then
    step "${#_CL_JSON_FILES[@]} CLs complete — generating comparison.md..."
    python3 - "$REPORT_DIR" <<'PYCOMPARE'
import json, os, sys, datetime, glob

run_dir = sys.argv[1]
json_files = sorted(f for f in glob.glob(os.path.join(run_dir, "*.json"))
                    if not os.path.basename(f).endswith(".blocks.json"))
cls = [os.path.basename(f)[:-5] for f in json_files]
if len(cls) < 2:
    print("Need at least 2 CL JSON files — skipping")
    sys.exit(0)

data = {}
for cl in cls:
    with open(os.path.join(run_dir, f"{cl}.json")) as f:
        data[cl] = json.load(f)

CL_DISPLAY = {
    "op-node":                  "op-node",
    "kona-okx-baseline":        "kona baseline",
    "kona-okx-optimised":       "kona optimised",
    "base-cl":                  "base-cl",
}
KNOWN_CLS = set(CL_DISPLAY.keys())
cls = [cl for cl in cls if cl in KNOWN_CLS]
if len(cls) < 2:
    print("Need at least 2 known CL JSON files — skipping")
    sys.exit(0)
data = {cl: data[cl] for cl in cls}
def dn(cl): return CL_DISPLAY.get(cl, cl)

def na(v, suffix=""):
    return f"{v}{suffix}" if v is not None else "N/A"

ref = next(iter(data.values()))
gas_str  = ref.get("gas_limit_str", "N/A")
dur      = ref.get("duration_s", "N/A")
workers  = ref.get("workers", "N/A")
date_str = ref.get("date", datetime.date.today().isoformat())

def thdr(*extra):
    return "| " + " | ".join(["Metric"] + [dn(c) for c in cls] + list(extra)) + " |"
def tsep(*extra):
    return "|" + "|".join(["---"] * (1 + len(cls) + len(extra))) + "|"

lines = []
lines.append("# Consensus Layer Comparison — Adventure ERC20")
lines.append("")
lines.append("## Run configuration")
lines.append("")
lines.append("| Field | Value |")
lines.append("|---|---|")
lines.append(f"| Date | {date_str} |")
lines.append(f"| CLs compared | {', '.join(dn(c) for c in cls)} |")
lines.append(f"| Chain | xlayer devnet (195) · 1-second blocks |")
lines.append(f"| Execution layer | OKX reth — identical binary and config |")
lines.append(f"| Block gas limit | {gas_str} gas |")
lines.append(f"| Test duration | {dur}s |")
lines.append(f"| Workers | {workers} |")
lines.append(f"| Tx type | ERC20 token transfer — 100k gas limit / ~35k gas actual |")
acct_count = ref.get("account_count", 20000)
lines.append(f"| Sender | adventure `erc20-bench` — {acct_count:,} pre-funded accounts |")
lines.append("")

def row(label, key, suffix="", bold_winner="low"):
    vals = {cl: data[cl].get(key) for cl in cls}
    available = [v for v in vals.values() if v is not None]
    best = (min(available) if bold_winner == "low" else max(available)) if len(available) >= 2 else None
    cells = []
    for cl in cls:
        v = vals[cl]
        if v is None:
            cells.append("N/A")
        elif best is not None and v == best:
            cells.append(f"**{v}{suffix}**")
        else:
            cells.append(f"{v}{suffix}")
    lines.append("| " + label + " | " + " | ".join(cells) + " |")

lines.append("## At a glance")
lines.append("")
lines.append(thdr()); lines.append(tsep())
row("Block-inclusion TPS",                              "tps_block",           " TX/s", "high")
row("Block fill (avg)",                                 "block_fill",          "%",     "high")
row("Txs confirmed on-chain",                           "tx_confirmed",        "",      "high")
row("Block Build Initiation — End to End Latency (median)", "cl_total_wait_p50",   " ms",   "low")
lines.append("")

def sum_row(label, keys):
    """Emit a row whose value is the arithmetic sum of the given keys (per CL)."""
    cells = []
    for cl in cls:
        parts = [data[cl].get(k) for k in keys]
        if any(p is None for p in parts):
            cells.append("N/A")
        else:
            cells.append(f"{round(sum(parts), 3)} ms")
    lines.append("| " + label + " | " + " | ".join(cells) + " |")

lines.append("### Block Build Initiation — Median (p50) breakdown")
lines.append("")
lines.append(thdr()); lines.append(tsep())
row("**End to End Latency** (`FCU+attrs` full cycle)",                          "cl_total_wait_p50",   " ms",   "low")
row("\u21b3 RequestGenerationLatency (`PayloadAttributes` assembly)",            "cl_attr_prep_p50",    " ms",   "low")
row("\u21b3 QueueDispatchLatency (`mpsc` channel dispatch)",                     "cl_queue_wait_p50",   " ms",   "low")
row("\u21b3 HttpSender-RoundtripLatency (`engine_forkchoiceUpdatedV3` HTTP)",    "cl_fcu_attrs_p50",    " ms",   "low")
lines.append("")
lines.append("*Sub-steps are independent percentiles \u2014 they may not sum to End to End.*")
lines.append("")

lines.append("### Block Build Initiation — Tail (p99) breakdown")
lines.append("")
lines.append(thdr()); lines.append(tsep())
row("**End to End Latency** (`FCU+attrs` full cycle)",                          "cl_total_wait_p99",   " ms",   "low")
row("\u21b3 RequestGenerationLatency (`PayloadAttributes` assembly)",            "cl_attr_prep_p99",    " ms",   "low")
row("\u21b3 QueueDispatchLatency (`mpsc` channel dispatch)",                     "cl_queue_wait_p99",   " ms",   "low")
row("\u21b3 HttpSender-RoundtripLatency (`engine_forkchoiceUpdatedV3` HTTP)",    "cl_fcu_attrs_p99",    " ms",   "low")
lines.append("")
lines.append("*Sub-steps are independent percentiles \u2014 they may not sum to End to End.*")
lines.append("")

lines.append("## Individual run reports")
lines.append("")
for cl in cls:
    lines.append(f"- [{dn(cl)}](./{cl}.md)")
lines.append("")

lines.append("## Throughput")
lines.append("")
tps_vals = [data[cl].get("tps_block") for cl in cls]
tps_set = set(v for v in tps_vals if v is not None)
if len(tps_set) == 1:
    lines.append(f"All CLs confirmed identical block-inclusion TPS: **{next(iter(tps_set))} TX/s**")
    lines.append("")
    lines.append("The CL is not the throughput bottleneck. All CLs send FCU+attrs at the same 1-second cadence.")
    lines.append("The ceiling is reth's `eth_sendRawTransaction` throughput on a single RPC connection.")
else:
    lines.append("| CL | Block-inclusion TPS | Block fill |")
    lines.append("|---|---|---|")
    for cl in cls:
        d = data[cl]
        lines.append(f"| {dn(cl)} | {na(d.get('tps_block'), ' TX/s')} | {na(d.get('block_fill'), '%')} |")
lines.append("")

def engine_section(title, rows_def):
    lines.append(f"### {title}")
    lines.append("")
    lines.append(thdr("Notes")); lines.append(tsep("Notes"))
    for label, key, note in rows_def:
        vals = [data[cl].get(key) for cl in cls]
        available = [v for v in vals if v is not None]
        best = min(available) if len(available) >= 2 else None
        cells = []
        for v in vals:
            if v is None:
                cells.append("N/A")
            elif best is not None and v == best:
                cells.append(f"**{v} ms**")
            else:
                cells.append(f"{v} ms")
        lines.append("| " + label + " | " + " | ".join(cells) + f" | {note} |")
    lines.append("")

lines.append("## Engine API latency — phase breakdown")
lines.append("")
lines.append("> **Block Build Initiation — End to End Latency** = BlockBuildInitiation-RequestGenerationLatency + BlockBuildInitiation-QueueDispatchLatency + BlockBuildInitiation-HttpSender-RoundtripLatency.")
lines.append("> Complete sequencer end-to-end latency from build decision to reth acknowledgement. Lower is better.")
lines.append("")

engine_section("Block Build Initiation — End to End Latency (`FCU+attrs` full cycle) — primary metric", [
    ("**End to End Latency p50 (median)**",      "cl_total_wait_p50",  "typical — sequencer tick to payloadId received"),
    ("**End to End Latency p99 (99th pctl)**",   "cl_total_wait_p99",  "tail — 1-in-100 worst"),
    ("End to End Latency max",                   "cl_total_wait_max",  "single worst block in the run"),
])
engine_section("BlockBuildInitiation-RequestGenerationLatency (`PayloadAttributes` assembly)", [
    ("p50 (median)",        "cl_attr_prep_p50",   "typical — L1/L2 RPC calls to assemble block-build instructions"),
    ("p99 (99th pctl)",     "cl_attr_prep_p99",   "tail — worst 1 in 100"),
])
engine_section("BlockBuildInitiation-QueueDispatchLatency (`mpsc` channel dispatch — kona/base-cl only)", [
    ("p50 (median)",        "cl_queue_wait_p50",  "typical queue dispatch time"),
    ("p99 (99th pctl)",     "cl_queue_wait_p99",  "tail — BinaryHeap starvation signal"),
    ("max",                 "cl_queue_wait_max",   "worst queue stall in the run"),
])
engine_section("BlockBuildInitiation-HttpSender-RoundtripLatency (`engine_forkchoiceUpdatedV3` HTTP — irreducible)", [
    ("p50 (median)",        "cl_fcu_attrs_p50",   "typical HTTP round-trip to reth"),
    ("p99 (99th pctl)",     "cl_fcu_attrs_p99",   "tail HTTP round-trip"),
    ("max",                 "cl_fcu_attrs_max",    "worst HTTP round-trip"),
])
engine_section("Derivation engine calls (reference)", [
    ("DerivationPipeline-HeadUpdate-Latency p50 (median) (`engine_forkchoiceUpdatedV3` no-attrs)",  "cl_fcu_p50",    "safe/finalized head advancement"),
    ("DerivationPipeline-HeadUpdate-Latency p99 (99th pctl)",                                       "cl_fcu_p99",    "tail — worst 1 in 100"),
    ("BlockSealRequest-With-Payload-Submit-To-EL-Latency p50 (median) (`engine_newPayloadV3`)",     "cl_new_pay_p50",  "sealed block submitted to reth for validation"),
    ("BlockSealRequest-With-Payload-Submit-To-EL-Latency max",                                      "cl_new_pay_max",  "worst import"),
    ("Block import / seal p50 (median) (`getPayload` + `newPayload` + `FCU`)",                      "cl_block_import_p50", "kona: full seal cycle"),
])
engine_section("reth EL internal timings (from reth docker logs)", [
    ("FCU+attrs p50 (median) (`engine_forkchoiceUpdatedV3`)",                                       "reth_fcu_attrs_p50", "reth's own time to accept block-build trigger"),
    ("BlockSealRequest-With-Payload-Submit-To-EL-Latency p50 (median) (`engine_newPayloadV3`)",     "reth_new_pay_p50",   "reth's own time to validate+import sealed block"),
])

lines.append("## Verdict")
lines.append("")

# Block Build Initiation — End to End Latency verdict — the primary metric
tw_p99 = [(data[cl].get("cl_total_wait_p99"), cl) for cl in cls]
tw_p99_avail = [(v, c) for v, c in tw_p99 if v is not None]
tw_p50 = [(data[cl].get("cl_total_wait_p50"), cl) for cl in cls]
tw_p50_avail = [(v, c) for v, c in tw_p50 if v is not None]

lines.append("| Metric | Best | Worst | Improvement |")
lines.append("|---|---|---|---|")

if len(tps_set) == 1:
    lines.append(f"| TPS | **tie** | — | All CLs: {next(iter(tps_set))} TX/s |")
elif tps_set:
    best_cl = cls[tps_vals.index(max(v for v in tps_vals if v is not None))]
    worst_cl = cls[tps_vals.index(min(v for v in tps_vals if v is not None))]
    lines.append(f"| TPS | **{dn(best_cl)}** ({max(v for v in tps_vals if v is not None):,.0f} TX/s) | {dn(worst_cl)} ({min(v for v in tps_vals if v is not None):,.0f} TX/s) | +{max(v for v in tps_vals if v is not None) - min(v for v in tps_vals if v is not None):,.0f} TX/s |")

if tw_p50_avail:
    best_v, best_c = min(tw_p50_avail)
    worst_v, worst_c = max(tw_p50_avail)
    ratio = round(worst_v / best_v, 1) if best_v and best_v > 0 else "—"
    lines.append(f"| Block Build Initiation — End to End Latency p50 (median) | **{dn(best_c)}** ({best_v:.1f} ms) | {dn(worst_c)} ({worst_v:.1f} ms) | {ratio}× |")

if tw_p99_avail:
    best_v, best_c = min(tw_p99_avail)
    worst_v, worst_c = max(tw_p99_avail)
    ratio = round(worst_v / best_v, 1) if best_v and best_v > 0 else "—"
    lines.append(f"| Block Build Initiation — End to End Latency p99 (99th pctl) | **{dn(best_c)}** ({best_v:.1f} ms) | {dn(worst_c)} ({worst_v:.1f} ms) | {ratio}× |")

lines.append("")

out_path = os.path.join(run_dir, "comparison.md")
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"comparison.md written → {out_path}")
PYCOMPARE
    ok "comparison.md → $REPORT_DIR/comparison.md"

    # ── Auto-generate detailed-report.md via generate-report.py ───────────────
    _GENREPORT="$BENCH_DIR/scripts/generate-report.py"
    if [[ -f "$_GENREPORT" ]]; then
        python3 "$_GENREPORT" "$REPORT_DIR" \
            && ok "detailed-report.md → $REPORT_DIR/detailed-report.md" \
            || warn "detailed-report.md generation failed — run manually: python3 bench/scripts/generate-report.py $REPORT_DIR"
    fi
fi
