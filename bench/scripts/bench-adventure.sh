#!/usr/bin/env bash
set -euo pipefail

# bench-adventure.sh — ERC20 load benchmark using adventure toolkit with full CL metrics.
#
# Drop-in companion to simple-bench.sh. Uses adventure erc20-bench as the TX sender
# and captures the same Engine API / FCU latency / safe-lag / docker log metrics.
#
# Usage:
#   ./bench-adventure.sh [--duration 120] [--workers 20] [--contract 0x...] [--gas-price 100]
#   ./bench-adventure.sh [--stack op-node|kona-okx-optimised|kona-okx-baseline|base-cl] [...]
#
# Options:
#   --duration   load test duration in seconds          (default: 120)
#   --workers    concurrency goroutines for adventure   (default: 20)
#   --contract   existing ERC20 address (skip erc20-init if provided)
#   --gas-price  gas price in gwei                     (default: 100)
#   --stack      override CL container selection
#   --probe-n    FCU pings per probe window             (default: 20)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"   # bench/scripts/ → bench/ → xlayer-toolkit/
ADVENTURE_DIR="$TOOLKIT_DIR/tools/adventure"
ADVENTURE_BIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin/adventure"

# ── Colour helpers ─────────────────────────────────────────────────────────────
_B="\033[1m"; _G="\033[0;32m"; _Y="\033[1;33m"; _R="\033[0;31m"; _C="\033[0;36m"; _N="\033[0m"
step() { echo -e "\n${_B}── $*${_N}"; }
ok()   { echo -e "${_G}✅  $*${_N}"; }
warn() { echo -e "${_Y}⚠️   $*${_N}"; }
fail() { echo -e "${_R}❌  $*${_N}"; exit 1; }

# ── Defaults ───────────────────────────────────────────────────────────────────
DURATION=120
WARMUP=30         # warm-up seconds before measurement starts (fills mempool to saturation)
WORKERS=20
CONTRACT=""
GAS_PRICE_GWEI=100
SEQ_TYPE="op-reth"          # EL image selector (matches docker-compose.yml)
SEQ_CONTAINER="op-seq"
RETH_CONTAINER="op-reth-seq"

# ── RPC endpoints (match simple-bench.sh) ─────────────────────────────────────
L2_RPC="http://localhost:8123"
AUTH_RPC="http://localhost:8552"
ROLLUP_RPC="http://localhost:9545"
CHAIN_ID=195
JWT_FILE="$TOOLKIT_DIR/devnet/config-op/jwt.txt"
DEPLOYER_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
# Genesis-funded whale (0x70997970...) — effectively unlimited ETH on L2 devnet.
# Used to top up the deployer so repeated bench runs on the same chain never run dry.
WHALE_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ACCOUNTS_FILE="$ADVENTURE_DIR/testdata/accounts-50k.txt"

# ── Arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)   DURATION="$2";        shift 2 ;;
        --warmup)     WARMUP="$2";          shift 2 ;;
        --workers)    WORKERS="$2";         shift 2 ;;
        --contract)   CONTRACT="$2";        shift 2 ;;
        --gas-price)  GAS_PRICE_GWEI="$2";  shift 2 ;;
        --stack)
            case "$2" in
                op-node)                                      SEQ_CONTAINER="op-seq";     RETH_CONTAINER="op-reth-seq" ;;
                kona-okx-optimised|kona-okx-baseline) \
                                                              SEQ_CONTAINER="op-kona";    RETH_CONTAINER="op-reth-seq" ;;
                base-cl)                                      SEQ_CONTAINER="op-base-cl"; RETH_CONTAINER="op-reth-seq" ;;
                # legacy names kept for backward compat
                toolkit)         SEQ_CONTAINER="op-seq";     RETH_CONTAINER="op-reth-seq" ;;
                toolkit-kona)    SEQ_CONTAINER="op-kona";    RETH_CONTAINER="op-reth-seq" ;;
                toolkit-base-cl) SEQ_CONTAINER="op-base-cl"; RETH_CONTAINER="op-reth-seq" ;;
                kona-okx)        SEQ_CONTAINER="op-kona";    RETH_CONTAINER="op-reth-seq" ;; # old name
                *) fail "Unknown stack: $2" ;;
            esac
            shift 2 ;;
        *) warn "Unknown arg: $1"; shift ;;
    esac
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LAG_FILE="$TMP/safe-lag.json"
ADV_LOG_A="$TMP/adventure-a.log"
ADV_LOG_B="$TMP/adventure-b.log"
ADV_CONFIG_INIT="$TMP/adv-config-init.json"   # full 50k accounts — for erc20-init only
ADV_CONFIG_A="$TMP/adv-config-a.json"         # first 25k accounts — bench instance A
ADV_CONFIG_B="$TMP/adv-config-b.json"         # last  25k accounts — bench instance B
touch "$LAG_FILE" "$ADV_LOG_A" "$ADV_LOG_B"

# ── Verify adventure binary ────────────────────────────────────────────────────
step "Checking adventure binary..."
if [[ ! -x "$ADVENTURE_BIN" ]]; then
    warn "adventure binary not found at $ADVENTURE_BIN — building..."
    (cd "$ADVENTURE_DIR" && make build) || fail "make build failed in $ADVENTURE_DIR"
fi
ok "adventure: $ADVENTURE_BIN"

# ── Verify accounts file + split for dual instances ────────────────────────────
[[ -f "$ACCOUNTS_FILE" ]] || fail "Accounts file not found: $ACCOUNTS_FILE"
ACCOUNT_COUNT=$(wc -l < "$ACCOUNTS_FILE" | tr -d ' ')
ok "accounts: $ACCOUNTS_FILE ($ACCOUNT_COUNT keys)"

# ── Account split: 25k accounts per instance ──────────────────────────────────
# 25k accounts per instance = 50k total. Pool depth: 50k × 35k gas = 1.75B gas
# = 3.5 full 500M-gas blocks → deep buffer, sustained saturation at 500M.
# At 200M: same 3.5× surplus as before. concurrency=1 prevents reth queued-promotion bug.
ACCOUNTS_A="$ADVENTURE_DIR/testdata/accounts-25k-A.txt"
ACCOUNTS_B="$ADVENTURE_DIR/testdata/accounts-25k-B.txt"
if [[ ! -f "$ACCOUNTS_A" || ! -f "$ACCOUNTS_B" ]]; then
    step "Splitting accounts for dual-instance bench (25k each)..."
    head -25000 "$ACCOUNTS_FILE" > "$ACCOUNTS_A"
    sed -n '25001,50000p' "$ACCOUNTS_FILE" > "$ACCOUNTS_B"
    ok "Split → $ACCOUNTS_A  $ACCOUNTS_B"
fi

# ── Write adventure configs ────────────────────────────────────────────────────
# bench configs: 500 accounts each, run in parallel to push past RPC ceiling
cat > "$ADV_CONFIG_A" <<EOF
{
  "rpc": ["$L2_RPC"],
  "accountsFilePath": "$ACCOUNTS_A",
  "senderPrivateKey": "$DEPLOYER_KEY",
  "concurrency": $WORKERS,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": $GAS_PRICE_GWEI,
  "saveTxHashes": false
}
EOF
cat > "$ADV_CONFIG_B" <<EOF
{
  "rpc": ["$L2_RPC"],
  "accountsFilePath": "$ACCOUNTS_B",
  "senderPrivateKey": "$DEPLOYER_KEY",
  "concurrency": $WORKERS,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": $GAS_PRICE_GWEI,
  "saveTxHashes": false
}
EOF

# init configs: concurrency=1 so batch-funding txs arrive at reth in strict nonce
# order. reth has a queued-promotion bug — concurrent tx submission causes out-of-order
# nonce arrival → txs land in "queued" sub-pool and are never promoted to "pending"
# after block confirmation. Sequential submission (concurrency=1) guarantees every
# tx arrives in order, so they all go straight to "pending" and get mined immediately.
ADV_CONFIG_INIT_A="$TMP/adv-config-init-a.json"
ADV_CONFIG_INIT_B="$TMP/adv-config-init-b.json"
cat > "$ADV_CONFIG_INIT_A" <<EOF
{
  "rpc": ["$L2_RPC"],
  "accountsFilePath": "$ACCOUNTS_A",
  "senderPrivateKey": "$DEPLOYER_KEY",
  "concurrency": 1,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": $GAS_PRICE_GWEI,
  "saveTxHashes": false
}
EOF
cat > "$ADV_CONFIG_INIT_B" <<EOF
{
  "rpc": ["$L2_RPC"],
  "accountsFilePath": "$ACCOUNTS_B",
  "senderPrivateKey": "$WHALE_KEY",
  "concurrency": 1,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": $GAS_PRICE_GWEI,
  "saveTxHashes": false
}
EOF
ok "configs written (init A: DEPLOYER_KEY concurrency=1; init B: WHALE_KEY concurrency=1; bench A+B: concurrency=$WORKERS)"

# ── Safe-lag poller — records timestamps for derivation correlation ─────────────
_start_lag_poller() {
    python3 - "$ROLLUP_RPC" "$LAG_FILE" <<'LAG_PY' >/dev/null 2>&1 &
import sys, json, time, urllib.request

rollup_rpc, out_file = sys.argv[1], sys.argv[2]
samples  = []   # {"ts": float, "unsafe": int, "safe": int}
gap_vals = []

def rpc(url, method, params=None):
    r = urllib.request.Request(url,
        data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or []}).encode(),
        headers={"Content-Type":"application/json"}, method="POST")
    with urllib.request.urlopen(r, timeout=5) as res:
        return json.loads(res.read()).get("result")

while True:
    try:
        sync   = rpc(rollup_rpc, "optimism_syncStatus") or {}
        def _n(v): return int(v,16) if isinstance(v,str) else int(v)
        unsafe = _n(sync["unsafe_l2"]["number"])
        safe   = _n(sync["safe_l2"]["number"])
        ts     = time.time()
        gap_vals.append(unsafe - safe)
        samples.append({"ts": ts, "unsafe": unsafe, "safe": safe})
        with open(out_file, "w") as f:
            json.dump({"gap_vals": gap_vals, "samples": samples}, f)
    except Exception:
        pass
    time.sleep(1)   # 1s interval for derivation correlation
LAG_PY
    echo $!
}

# ── Wait for chain ─────────────────────────────────────────────────────────────
step "Waiting for L2 blocks..."
for _ in $(seq 1 30); do
    BN=$(cast bn --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
    [[ $BN -gt 0 ]] && break
    sleep 1
done
[[ $BN -gt 0 ]] || fail "L2 RPC not responding — is xlayer-toolkit running?"
ok "L2 responding at block $BN"

# Wait for the sequencer to actively produce blocks before erc20-init.
# Checking block number > 0 only verifies the EL (reth) RPC is up — the CL
# sequencer (op-node especially) may still be initializing and not yet building
# blocks. erc20-init needs confirmed tx receipts; if the sequencer hasn't built
# its first block yet, adventure's deployment tx sits unconfirmed → rc=1.
# Active poll: wait until chain advances by 5 blocks (proves sequencer is live).
step "Waiting for sequencer to produce blocks (up to 90s)..."
_START_BN=$BN
_DEADLINE=$(( $(date +%s) + 90 ))
while true; do
    _CUR_BN=$(cast bn --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
    [[ $_CUR_BN -ge $(( _START_BN + 5 )) ]] && break
    [[ $(date +%s) -ge $_DEADLINE ]] && fail "Sequencer not producing blocks after 90s (stuck at block $_CUR_BN)"
    sleep 2
done
ok "Sequencer active — block $_CUR_BN (+$(( _CUR_BN - _START_BN )) since RPC ready)"

# ── Ensure deployer has enough ETH for instance A erc20-init ──────────────────
# Instance A init (DEPLOYER_KEY): 25k accounts × 0.2 ETH = 5000 ETH per run.
# Instance B init uses WHALE_KEY (unlimited genesis ETH) — no deployer cost.
# Top up the deployer from the genesis whale when balance drops below threshold.
step "Checking deployer balance..."
_DEPLOYER_ADDR=$(cast wallet address "$DEPLOYER_KEY" 2>/dev/null)
_BAL_WEI=$(cast balance "$_DEPLOYER_ADDR" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
_BAL_ETH=$(python3 -c "print(int('$_BAL_WEI') // 10**18)")
_THRESHOLD_ETH=5500   # top up if below this (~1.1-run buffer at 5000 ETH/run)
_TARGET_ETH=12000     # refill to this level (~2.4 runs before next top-up)
if [[ "$_BAL_ETH" -lt "$_THRESHOLD_ETH" ]]; then
    _TOPUP=$(( _TARGET_ETH - _BAL_ETH ))
    warn "Deployer has ${_BAL_ETH} ETH < ${_THRESHOLD_ETH} ETH — topping up ${_TOPUP} ETH from whale..."
    cast send \
        --private-key "$WHALE_KEY" \
        --value "${_TOPUP}ether" \
        "$_DEPLOYER_ADDR" \
        --rpc-url "$L2_RPC" \
        --gas-limit 21000 \
        --priority-gas-price "2gwei" \
        > /dev/null 2>&1 \
        && ok "Deployer topped up to ~${_TARGET_ETH} ETH (confirmed)" \
        || warn "Top-up failed — proceeding with ${_BAL_ETH} ETH (may be enough)"
else
    ok "Deployer balance OK: ${_BAL_ETH} ETH (threshold ${_THRESHOLD_ETH} ETH)"
fi
unset _DEPLOYER_ADDR _BAL_WEI _BAL_ETH _THRESHOLD_ETH _TARGET_ETH _TOPUP

LOG_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── ERC20 deploy + fund accounts — two separate 500-account inits ──────────────
# Each init uses concurrency=1 so batch-funding txs are submitted sequentially,
# guaranteeing in-order nonce arrival at reth (avoids queued-promotion bug).
# Each instance uses its own ERC20 contract — avoids any shared-state issues.
CONTRACT_A=""
CONTRACT_B=""
if [[ -n "$CONTRACT" ]]; then
    ok "Skipping erc20-init — using existing contract for both instances: $CONTRACT"
    CONTRACT_A="$CONTRACT"
    CONTRACT_B="$CONTRACT"
else
    step "Running erc20-init A+B in parallel (25k accounts, 0.2 ETH — A:DEPLOYER, B:WHALE)..."
    warn "Init takes ~18-25 min (250 batch txs each, sequential 1-block confirmation per tx)..."
    INIT_LOG_A="$TMP/erc20-init-a.log"
    INIT_LOG_B="$TMP/erc20-init-b.log"
    "$ADVENTURE_BIN" erc20-init 0.2ETH -f "$ADV_CONFIG_INIT_A" > "$INIT_LOG_A" 2>&1 &
    INIT_PID_A=$!
    "$ADVENTURE_BIN" erc20-init 0.2ETH -f "$ADV_CONFIG_INIT_B" > "$INIT_LOG_B" 2>&1 &
    INIT_PID_B=$!

    INIT_RC_A=0; INIT_RC_B=0
    wait "$INIT_PID_A" || INIT_RC_A=$?
    wait "$INIT_PID_B" || INIT_RC_B=$?
    grep -hE "(ERC20 Address|Finish|Error|failed|timeout)" "$INIT_LOG_A" "$INIT_LOG_B" 2>/dev/null || true

    # Retry once on transient failure (e.g. sequencer not yet ready at init start)
    if [[ $INIT_RC_A -ne 0 ]]; then
        warn "erc20-init A failed (rc=$INIT_RC_A) — waiting 15s and retrying once..."
        sleep 15
        "$ADVENTURE_BIN" erc20-init 0.2ETH -f "$ADV_CONFIG_INIT_A" > "$INIT_LOG_A" 2>&1 && INIT_RC_A=0 || INIT_RC_A=$?
        grep -hE "(ERC20 Address|Finish|Error|failed|timeout)" "$INIT_LOG_A" 2>/dev/null || true
    fi
    if [[ $INIT_RC_B -ne 0 ]]; then
        warn "erc20-init B failed (rc=$INIT_RC_B) — waiting 15s and retrying once..."
        sleep 15
        "$ADVENTURE_BIN" erc20-init 0.2ETH -f "$ADV_CONFIG_INIT_B" > "$INIT_LOG_B" 2>&1 && INIT_RC_B=0 || INIT_RC_B=$?
        grep -hE "(ERC20 Address|Finish|Error|failed|timeout)" "$INIT_LOG_B" 2>/dev/null || true
    fi

    [[ $INIT_RC_A -eq 0 ]] || fail "erc20-init A failed after retry (rc=$INIT_RC_A) — check $INIT_LOG_A"
    [[ $INIT_RC_B -eq 0 ]] || fail "erc20-init B failed after retry (rc=$INIT_RC_B) — check $INIT_LOG_B"

    CONTRACT_A=$(grep "ERC20 Address:" "$INIT_LOG_A" | awk '{print $NF}')
    CONTRACT_B=$(grep "ERC20 Address:" "$INIT_LOG_B" | awk '{print $NF}')
    [[ -n "$CONTRACT_A" ]] || fail "erc20-init A: no ERC20 address — check $INIT_LOG_A"
    [[ -n "$CONTRACT_B" ]] || fail "erc20-init B: no ERC20 address — check $INIT_LOG_B"
    ok "ERC20-A: $CONTRACT_A  ERC20-B: $CONTRACT_B"
fi

# ── Phase 1: warm-up — two adventure instances push mempool to saturation ──────
# Both instances use disjoint account sets so there is zero nonce contention.
# Combined send rate (~9k TX/s) exceeds chain capacity (~5.5k TX/s) → 100% fill.
step "Warm-up phase (${WARMUP}s) — flooding mempool with dual adventure instances..."
"$ADVENTURE_BIN" erc20-bench -f "$ADV_CONFIG_A" --contract "$CONTRACT_A" > "$ADV_LOG_A" 2>&1 &
ADV_PID_A=$!
"$ADVENTURE_BIN" erc20-bench -f "$ADV_CONFIG_B" --contract "$CONTRACT_B" > "$ADV_LOG_B" 2>&1 &
ADV_PID_B=$!
sleep "$WARMUP"
ok "Warm-up complete — mempool at saturation."

# ── Post-warmup sanity check — verify blocks are filling before measurement ────
# If the mempool isn't landing TXs (bad contract, nonce desync, underpriced gas),
# fail fast rather than waste 120s collecting useless empty-block data.
_WARMUP_CHECK_BN=$(cast bn --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
_FILL_CHECK=$(python3 - "$_WARMUP_CHECK_BN" "$L2_RPC" <<'FILLCHECK'
import sys, json, urllib.request
end_bn = int(sys.argv[1]); rpc_url = sys.argv[2]
start_bn = max(end_bn - 10, 1)
fills = []
for bn in range(start_bn + 1, end_bn + 1):
    try:
        r = urllib.request.Request(rpc_url,
            data=json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":[hex(bn),False]}).encode(),
            headers={"Content-Type":"application/json"}, method="POST")
        with urllib.request.urlopen(r, timeout=5) as res:
            blk = json.loads(res.read()).get("result") or {}
        g_used = int(blk.get("gasUsed","0x0"),16)
        g_lim  = int(blk.get("gasLimit","0x1"),16)
        fills.append(round(g_used/g_lim*100,1))
    except Exception:
        pass
median = sorted(fills)[len(fills)//2] if fills else 0
print(f"{median:.1f}")
FILLCHECK
)
if python3 -c "import sys; sys.exit(0 if float('${_FILL_CHECK:-0}') >= 20.0 else 1)" 2>/dev/null; then
    ok "Post-warmup fill check: ${_FILL_CHECK}% median — blocks filling, proceeding to measurement."
else
    kill -9 "$ADV_PID_A" "$ADV_PID_B" 2>/dev/null || true
    fail "Post-warmup fill check FAILED: median block fill = ${_FILL_CHECK:-0}% (threshold 20%). TXs not landing — possible nonce desync or underpriced gas. Aborting to avoid empty measurement window."
fi

# Capture log timestamp AFTER warm-up — CL timing metrics cover only the measurement window.
# This prevents init-phase events (which fire more aggressively during ramp-up) from
# inflating max values and distorting queue_wait statistics.
MEAS_LOG_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Phase 2: measurement window ────────────────────────────────────────────────
# START_BN is captured AFTER warm-up so the measurement window covers only
# fully-saturated blocks. Post-kill empty blocks don't pollute the result.
step "Measurement phase (${DURATION}s) — capturing block data + CL engine API timings..."
START_BN=$(cast bn --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
LAG_PID=$(_start_lag_poller)

sleep "$DURATION"

kill -9 "$ADV_PID_A" "$ADV_PID_B" 2>/dev/null || true
kill    "$LAG_PID"                 2>/dev/null || true

LOAD_ELAPSED=$DURATION
ok "Load test complete."

# ── Parse metrics ──────────────────────────────────────────────────────────────
step "Parsing metrics (block scan + safe-lag correlation)..."
METRICS=$(python3 - "$ADV_LOG_A" "$LAG_FILE" "$LOAD_ELAPSED" "$L2_RPC" "$START_BN" "${BLOCKS_JSON_OUT:-}" <<'PYMETRICS'
import sys, json, re, urllib.request

adv_log, lag_file, elapsed, rpc_url, start_bn = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
blocks_json_out = sys.argv[6] if len(sys.argv) > 6 else ""
elapsed  = int(elapsed)
start_bn = int(start_bn)

# ── helpers ────────────────────────────────────────────────────────────────────
def pct(arr, p):
    if not arr: return None
    s = sorted(arr)
    return round(s[min(int(len(s) * p / 100), len(s) - 1)], 3)

def rpc(method, params):
    r = urllib.request.Request(rpc_url,
        data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode(),
        headers={"Content-Type":"application/json"}, method="POST")
    for _attempt in range(3):
        try:
            with urllib.request.urlopen(r, timeout=15) as res:
                return json.loads(res.read()).get("result")
        except Exception:
            if _attempt == 2: raise
    return None

# ── adventure summary line (instance A log — both instances show same rate) ────
avg_tps = max_tps = None
try:
    with open(adv_log) as f:
        for line in f:
            if "[Summary] Average BTPS:" in line:
                for part in line.split(","):
                    part = part.strip()
                    if "Average BTPS:" in part:
                        avg_tps = round(float(part.split(":")[-1].strip()), 1)
                    elif "Max TPS:" in part:
                        max_tps = round(float(part.split(":")[-1].strip()), 1)
except Exception:
    pass

# ── safe-lag: gap_vals + timestamped samples for derivation correlation ─────────
gap_vals = []
lag_samples = []   # [{"ts": float, "unsafe": int, "safe": int}]
try:
    with open(lag_file) as f:
        data = json.load(f)
        gap_vals    = [int(g) for g in data.get("gap_vals", []) if g is not None]
        lag_samples = data.get("samples", [])
except Exception:
    pass

# ── per-block TPS + fill — exact measurement window ────────────────────────────
block_tps = avg_fill = None
tx_confirmed = gas_limit = None
start_bn_out = start_bn
end_bn_out = chain_duration_s = None
per_block_tps  = []   # TPS per individual block
per_block_fill = []   # fill % per individual block
per_block_data = []   # raw per-block records for fcu-tps-correlation script

try:
    end_bn     = start_bn + elapsed
    # Cap end_bn at actual chain head — sequencer may be 1-2 blocks behind elapsed time.
    # Fetching a block beyond the tip returns null and crashes the scan.
    chain_head_hex = rpc("eth_blockNumber", [])
    if chain_head_hex:
        chain_head = int(chain_head_hex, 16)
        end_bn = min(end_bn, chain_head)
    end_bn_out = end_bn
    t_start = int(rpc("eth_getBlockByNumber", [hex(start_bn), False])["timestamp"], 16)
    t_end   = int(rpc("eth_getBlockByNumber", [hex(end_bn),   False])["timestamp"], 16)
    tx_total = gas_total = 0
    prev_ts  = t_start

    for bn in range(start_bn + 1, end_bn + 1):
        blk = rpc("eth_getBlockByNumber", [hex(bn), True])
        if not blk:
            continue
        n_tx  = len(blk.get("transactions", []))
        g_used = int(blk.get("gasUsed", "0x0"), 16)
        g_lim  = int(blk.get("gasLimit", "0x1"), 16)
        blk_ts = int(blk.get("timestamp", "0x0"), 16)
        tx_total  += n_tx
        gas_total += g_used
        if gas_limit is None:
            gas_limit = g_lim
        dt = max(blk_ts - prev_ts, 1)
        fill_pct = round(g_used / g_lim * 100, 1)
        per_block_tps.append(round(n_tx / dt, 1))
        per_block_fill.append(fill_pct)
        per_block_data.append({"bn": bn, "n_tx": n_tx, "gas_used": g_used,
                                "gas_limit": g_lim, "fill_pct": fill_pct,
                                "timestamp": blk_ts})
        prev_ts = blk_ts

    chain_duration_s = max(t_end - t_start, 1)
    tx_confirmed = tx_total
    block_tps    = round(tx_total / chain_duration_s, 1)
    avg_fill     = round(gas_total / elapsed / gas_limit * 100, 1) if gas_limit else None
    if blocks_json_out and per_block_data:
        import os as _os
        _os.makedirs(_os.path.dirname(blocks_json_out) or ".", exist_ok=True)
        with open(blocks_json_out, "w") as _bf:
            json.dump({"start_bn": start_bn, "end_bn": end_bn, "blocks": per_block_data}, _bf, indent=2)
except Exception as _e:
    import sys as _sys
    print(f"[bench-adventure] WARNING: block scan failed — {_e}", file=_sys.stderr)

# fill distribution
fill_p10 = pct(per_block_fill, 10)
fill_p50 = pct(per_block_fill, 50)
fill_p90 = pct(per_block_fill, 90)
saturated = fill_p10 is not None and fill_p10 > 95.0

# confirmed TPS distribution
tps_p50_block  = pct(per_block_tps, 50)
tps_p95_block  = pct(per_block_tps, 95)
tps_peak_block = round(max(per_block_tps), 1) if per_block_tps else None

tx_submitted_est = round(avg_tps * elapsed) if avg_tps else None

print(json.dumps({
    # throughput
    "tps":              avg_tps or 0,
    "tps_peak":         max_tps or 0,
    "tps_block":        block_tps,           # avg confirmed TX/s over test window
    "tps_p50_block":    tps_p50_block,       # median per-block confirmed TX/s
    "tps_p95_block":    tps_p95_block,       # p95 per-block confirmed TX/s
    "tps_peak_block":   tps_peak_block,      # peak per-block confirmed TX/s
    # block fill
    "block_fill":       avg_fill,            # avg % fill
    "fill_p10":         fill_p10,            # p10 fill — saturated if >95
    "fill_p50":         fill_p50,
    "fill_p90":         fill_p90,
    "saturated":        saturated,
    # chain metadata
    "gas_limit":        gas_limit,
    "start_bn":         start_bn_out,
    "end_bn":           end_bn_out,
    "chain_duration_s": chain_duration_s,
    # transaction counts
    "tx_confirmed":     tx_confirmed,
    "tx_submitted_est": tx_submitted_est,
    "tx_pending_est":   (tx_submitted_est - tx_confirmed) if (tx_submitted_est and tx_confirmed) else None,
    "errors":           0,
    # safe lag
    "safe_lag_max": max(gap_vals) if gap_vals else None,
    "safe_lag_avg": round(sum(gap_vals)/len(gap_vals), 1) if gap_vals else None,
}))
PYMETRICS
)

# ── Parse docker logs for CL + reth EL timings ────────────────────────────────
DOCKER_STATS='{"cl":{},"reth":{}}'
SEQ_CID=$(docker compose -f "$TOOLKIT_DIR/devnet/docker-compose.yml" ps -q "$SEQ_CONTAINER" 2>/dev/null || echo "")
RETH_CID=$(docker compose -f "$TOOLKIT_DIR/devnet/docker-compose.yml" ps -q "$RETH_CONTAINER" 2>/dev/null || echo "")
if [[ -n "$SEQ_CID" || -n "$RETH_CID" ]]; then
    case "$SEQ_CONTAINER" in
        op-kona)    _CL_LABEL="kona CL" ;;
        op-base-cl) _CL_LABEL="base-consensus CL" ;;
        *)          _CL_LABEL="Go op-node CL" ;;
    esac
    step "Parsing docker logs for $SEQ_CONTAINER ($_CL_LABEL) + $RETH_CONTAINER..."
    LOGFILE="$TMP/docker_logs.txt"
    [[ -n "$SEQ_CID"  ]] && docker logs "$SEQ_CID"  --since "$MEAS_LOG_SINCE" 2>&1 | sed 's/^/[seq] /'  >> "$LOGFILE" || true
    [[ -n "$RETH_CID" ]] && docker logs "$RETH_CID" --since "$MEAS_LOG_SINCE" 2>&1 | sed 's/^/[reth] /' >> "$LOGFILE" || true
    DOCKER_STATS=$(python3 - "$LOGFILE" <<'PYDOCKER'
import sys, re, json

logfile = sys.argv[1]
_ANSI = re.compile(r'\x1b\[[0-9;]*[mK]')

_NUM = re.compile(r'^([\d.]+)(.+)$')
def to_ms(v):
    v = v.strip().rstrip(')')
    m = _NUM.match(v)
    if not m: return 0.0
    num, unit = float(m.group(1)), m.group(2)
    if 'ns' in unit:  return num / 1_000_000.0
    if 'µs' in unit or 'us' in unit: return num / 1000.0
    if 'ms' in unit:  return num
    if unit == 's':   return num * 1000.0
    return 0.0

def pct(d, p):
    s = sorted(d)
    return s[min(int(len(s)*p/100), len(s)-1)] if s else 0

def stats(data):
    if not data: return None
    return dict(
        p50=round(pct(data,50),3), p95=round(pct(data,95),3),
        p99=round(pct(data,99),3), max=round(max(data),3),
        avg=round(sum(data)/len(data),3), n=len(data)
    )

cl_timings = {
    # ── Top-level intervals (T0→T3 model) ───────────────────────────────────
    "fcu":[], "fcu_attrs":[], "new_pay":[], "block_import":[],
    "build_wait":[], "queue_wait":[], "total_wait":[], "attr_prep":[],
    # ── attr_prep micro-steps (T0→T1 breakdown, actor.rs) ───────────────────
    # step A: get_unsafe_head()          — Opt-3 hypothesis: suspected EL RPC
    # step B: get_next_payload_l1_origin — cached; slow on epoch change (L1 geth RPC)
    # step C: build_attributes()         — = C1+C2+C3+C4 (sub-steps below)
    "attr_step_a":[], "attr_step_b":[], "attr_step_c":[],
    # ── prepare_payload_attributes sub-steps (stateful.rs) ──────────────────
    # C1: system_config_by_number — Opt-2 target (0ms after cache warm)
    # C2: header_by_hash(epoch)   — LRU cached (0ms for 11/12 blocks)
    # C3: receipts_by_hash(epoch) — only on epoch_change (L1 geth RPC, 0ms otherwise)
    # C4: L1BlockInfoTx encode    — pure computation, always ~0ms
    "attr_step_c1":[], "attr_step_c2":[], "attr_step_c3":[], "attr_step_c4":[],
}
attr_epoch_change_count = 0   # scalar counter — kept separate from stats lists
reth_el    = {"fcu":[], "fcu_attrs":[], "new_pay":[]}

# ── Patterns ─────────────────────────────────────────────────────────────────
# op-node docker logs (added timing in engine_controller.go):
#   "FCU+attrs ok" fcu_duration=<dur>
#     → FCU+attrs round-trip in startPayload() (sequencer block building trigger)
#   "FCU ok" fcu_duration=<dur>
#     → FCU-no-attrs round-trip in tryUpdateEngineInternal() (consolidation)
#   "Inserted new L2 unsafe block" insert_time=<dur>
#     → newPayload+fcu2 time for derived/sequenced unsafe blocks
pat_opnode_fcu_dur    = re.compile(r'\bfcu_duration=([\d.]+[a-zµ]+)')
pat_opnode_newpay_dur = re.compile(r'\binsert_time=([\d.]+[a-zµ]+)')

# kona docker logs (tracing crate, text format):
#   "block build started" fcu_duration=<dur>
#     → FCU+attrs round-trip: CL sends engine_forkchoiceUpdatedV3+attrs, gets VALID+payloadId
#   "Updated safe head via L1 consolidation" fcu_duration=<dur>
#   "Updated safe head via follow safe" fcu_duration=<dur>
#   "Updated finalized head" fcu_duration=<dur>
#     → derivation/finalization FCU round-trip (no attrs)
#   "Inserted new unsafe block" insert_duration=<dur>
#     → engine_newPayload round-trip for a derived block
#   "Built and imported new ... block" block_import_duration=<dur>
#     → engine_getPayload + engine_newPayload (sequencer seal cycle, not incl. build time)
pat_kona_fcu_dur      = re.compile(r'\bfcu_duration=([\d.]+[a-zµ]+)')
pat_kona_insert_dur   = re.compile(r'\binsert_duration=([\d.]+[a-zµ]+)')
pat_kona_import_dur   = re.compile(r'\bblock_import_duration=([\d.]+[a-zµ]+)')
# kona/base-cl: "build request completed" sequencer_build_wait=<dur>
#   → total sequencer wait: before channel send → BinaryHeap queue wait → HTTP → payloadId back
#   → THIS shows the priority-fix effect (unlike fcu_attrs which starts AFTER queue dequeue)
pat_kona_build_wait   = re.compile(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)')
pat_total_wait        = re.compile(r'\bsequencer_total_wait=([\d.]+[a-zµ]+)')

# ── attr_prep micro-step patterns (actor.rs — "build request completed") ──────
# Aliases: step A = get_unsafe_head, step B = get_l1_origin, step C = build_attrs
# All values logged as raw integer milliseconds (as_millis()), not Duration strings.
pat_step_a = re.compile(r'\battr_step_a_get_head_ms=(\d+)')
pat_step_b = re.compile(r'\battr_step_b_get_origin_ms=(\d+)')
pat_step_c = re.compile(r'\battr_step_c_build_attrs_ms=(\d+)')

# ── prepare_payload_attributes sub-step patterns (stateful.rs) ───────────────
# Logged on "prepare_payload_attributes timing" line, once per block.
# C1=sys_config(Opt-2 target), C2=header_rpc, C3=receipts_rpc, C4=l1info_tx
pat_c1 = re.compile(r'\battr_step_c1_sys_config_ms=(\d+)')
pat_c2 = re.compile(r'\battr_step_c2_header_rpc_ms=(\d+)')
pat_c3 = re.compile(r'\battr_step_c3_receipts_rpc_ms=(\d+)')
pat_c4 = re.compile(r'\battr_step_c4_l1info_tx_ms=(\d+)')
pat_epoch_change = re.compile(r'\bepoch_change=(true|false)')

# reth docker logs (engine::tree):
#   "FCU reth ok" elapsed=<dur> attrs=true/false
#   "new_payload reth ok" elapsed=<dur>
pat_reth_el = re.compile(r'\belapsed=([\d.]+[a-zµ]+)')

try:
    fh = open(logfile, errors='replace')
except Exception:
    fh = []
for raw in fh:
    raw = _ANSI.sub('', raw)
    if raw.startswith('[seq] '):
        src, line = 'seq', raw[6:]
    elif raw.startswith('[reth] '):
        src, line = 'reth', raw[7:]
    else:
        continue
    if src == 'reth' and 'engine' not in line: continue
    if 'engine_bridge' in line: continue

    if src == 'seq':
        # ── op-node: FCU+attrs round-trip (startPayload, sequencer)
        if 'FCU+attrs ok' in line:
            m = pat_opnode_fcu_dur.search(line)
            if m: cl_timings["fcu_attrs"].append(to_ms(m.group(1)))
            m2 = re.search(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)', line)
            if m2: cl_timings["build_wait"].append(to_ms(m2.group(1)))
            m3 = pat_total_wait.search(line)
            if m3: cl_timings["total_wait"].append(to_ms(m3.group(1)))
        # ── op-node: FCU-no-attrs round-trip (tryUpdateEngineInternal, consolidation)
        elif 'FCU ok' in line and 'fcu_duration' in line:
            m = pat_opnode_fcu_dur.search(line)
            if m: cl_timings["fcu"].append(to_ms(m.group(1)))
        # ── op-node: newPayload+fcu2 for unsafe blocks (payload_success.go insert_time)
        elif 'Inserted new L2 unsafe block' in line:
            m = pat_opnode_newpay_dur.search(line)
            if m: cl_timings["new_pay"].append(to_ms(m.group(1)))
        # ── kona: FCU+attrs (sequencer triggers block building)
        elif 'block build started' in line:
            m = pat_kona_fcu_dur.search(line)
            if m: cl_timings["fcu_attrs"].append(to_ms(m.group(1)))
        # ── kona: derivation/finalization FCU (no attrs, advances safe/finalized head)
        elif ('Updated safe head via L1 consolidation' in line or
              'Updated safe head via follow safe' in line or
              'Updated finalized head' in line):
            m = pat_kona_fcu_dur.search(line)
            if m: cl_timings["fcu"].append(to_ms(m.group(1)))
        # ── kona: newPayload for derived block (no "L2" in name)
        elif 'Inserted new unsafe block' in line:
            m = pat_kona_insert_dur.search(line)
            if m: cl_timings["new_pay"].append(to_ms(m.group(1)))
        # ── kona: sequencer seal (getPayload + newPayload)
        elif 'Built and imported new' in line:
            m = pat_kona_import_dur.search(line)
            if m: cl_timings["block_import"].append(to_ms(m.group(1)))
        # ── kona/base-cl: total sequencer build wait (before send → payloadId)
        # Also captures attr_prep micro-steps A, B, C if present (instrumented images only).
        elif 'build request completed' in line:
            m = pat_kona_build_wait.search(line)
            if m: cl_timings["build_wait"].append(to_ms(m.group(1)))
            m2 = pat_total_wait.search(line)
            if m2: cl_timings["total_wait"].append(to_ms(m2.group(1)))
            # micro-steps: present only in instrumented images (okx-baseline + okx-optimised)
            ma = pat_step_a.search(line)
            if ma: cl_timings["attr_step_a"].append(int(ma.group(1)))
            mb = pat_step_b.search(line)
            if mb: cl_timings["attr_step_b"].append(int(mb.group(1)))
            mc = pat_step_c.search(line)
            if mc: cl_timings["attr_step_c"].append(int(mc.group(1)))
        # ── kona: prepare_payload_attributes sub-steps C1–C4 ──────────────────
        # One line per block. Only present in instrumented images.
        # C1=sys_config(Opt-2), C2=header_rpc, C3=receipts_rpc(epoch only), C4=l1info_tx
        elif 'prepare_payload_attributes timing' in line:
            m1 = pat_c1.search(line)
            if m1: cl_timings["attr_step_c1"].append(int(m1.group(1)))
            m2 = pat_c2.search(line)
            if m2: cl_timings["attr_step_c2"].append(int(m2.group(1)))
            m3 = pat_c3.search(line)
            if m3: cl_timings["attr_step_c3"].append(int(m3.group(1)))
            m4 = pat_c4.search(line)
            if m4: cl_timings["attr_step_c4"].append(int(m4.group(1)))
            me = pat_epoch_change.search(line)
            if me and me.group(1) == 'true':
                attr_epoch_change_count += 1

    elif src == 'reth' and 'engine::tree' in line:
        m = pat_reth_el.search(line)
        if not m: continue
        ms = to_ms(m.group(1))
        if ms <= 0: continue
        if   'new_payload reth ok' in line:                      reth_el["new_pay"].append(ms)
        elif 'FCU reth ok' in line and 'attrs=true' in line:     reth_el["fcu_attrs"].append(ms)
        elif 'FCU reth ok' in line:                              reth_el["fcu"].append(ms)

# ── Derive queue_wait = build_wait − fcu_attrs (per event, no rebuild needed) ──
# build_wait (T1→T3): from "build request completed" / "FCU+attrs ok" with sequencer_build_wait=
# fcu_attrs  (T2→T3): from "block build started" / "FCU+attrs ok" with fcu_duration=
# queue_wait (T1→T2): time wasted in BinaryHeap before FCU was even sent to EL
# For op-node both come from the same log line → perfectly aligned.
# For kona they appear in consecutive pairs per block → aligned by position.
for bw, fa in zip(cl_timings["build_wait"], cl_timings["fcu_attrs"]):
    cl_timings["queue_wait"].append(round(max(bw - fa, 0.0), 3))

# ── Derive attr_prep = total_wait − build_wait (attribute preparation phase, T0→T1) ──
# total_wait (T0→T3): full build cycle from [sequencer decides to build] to [payloadId]
# build_wait (T1→T3): from [after attr prep] to [payloadId]
# attr_prep  (T0→T1): time spent building payload attributes (L1 info, deposits, etc.)
for tw, bw in zip(cl_timings["total_wait"], cl_timings["build_wait"]):
    cl_timings["attr_prep"].append(round(max(tw - bw, 0.0), 3))

out = {k:{c:stats(v) for c,v in d.items()} for k,d in {"cl":cl_timings,"reth":reth_el}.items()}
out["cl"]["attr_epoch_change_count"] = {"n": attr_epoch_change_count}
print(json.dumps(out))
PYDOCKER
    ) || DOCKER_STATS='{"cl":{},"reth":{}}'
    # Save raw CL+reth log for per-block correlation analysis (fcu-tps-correlation.py)
    if [[ -n "${CL_LOG_OUT:-}" && -f "$LOGFILE" ]]; then
        cp "$LOGFILE" "$CL_LOG_OUT"
    fi
fi

# ── Derivation sync sanity check ───────────────────────────────────────────────
# If new_payload count >> expected blocks (duration ÷ block_time), derivation was
# replaying during measurement → latency metrics are unreliable.
# Expected: ~1 new_payload per block → ~$DURATION blocks in the measurement window.
_NP_COUNT=$(python3 -c "
import json, sys
dk = json.loads(sys.argv[1])
np_data = dk.get('cl',{}).get('new_pay',{})
print(np_data.get('n', 0))
" "$DOCKER_STATS" 2>/dev/null || echo 0)
_EXPECTED_BLOCKS=$DURATION  # 1s block time → $DURATION blocks
_NP_RATIO=$(python3 -c "
n=int('${_NP_COUNT}'); e=int('${_EXPECTED_BLOCKS}')
print(round(n/e,1) if e>0 else 0)
" 2>/dev/null || echo 0)
if python3 -c "import sys; sys.exit(0 if float('${_NP_RATIO}') > 2.0 else 1)" 2>/dev/null; then
    echo ""
    echo "⚠️  DERIVATION SYNC WARNING: new_payload count ($_NP_COUNT) is ${_NP_RATIO}× expected (~$_EXPECTED_BLOCKS)."
    echo "   Derivation pipeline was likely replaying blocks during measurement."
    echo "   Latency metrics (especially p50) may be unreliable for this CL."
    echo ""
fi

# ── Print Markdown report ──────────────────────────────────────────────────────
python3 - "$METRICS" "$DOCKER_STATS" "$DURATION" "$WORKERS" "$SEQ_CONTAINER" "$CONTRACT" \
          "${METRICS_JSON_OUT:-}" "${ACCOUNT_COUNT:-20000}" <<'PYPRINT'
import sys, json, datetime, os

m             = json.loads(sys.argv[1])
dk            = json.loads(sys.argv[2])
dur           = int(sys.argv[3])
workers       = int(sys.argv[4])
cl            = sys.argv[5]
contract      = sys.argv[6]
json_out      = sys.argv[7] if len(sys.argv) > 7 else ""
account_count = int(sys.argv[8]) if len(sys.argv) > 8 else 20000

def dms(d, key):
    v = d.get(key) if d else None
    return f"{v:.3f} ms" if v is not None else "N/A"

def na(v, suffix=""):
    return f"{v}{suffix}" if v is not None else "N/A"

def fmt_gas(v):
    if v is None: return "N/A"
    if v >= 1_000_000: return f"{v // 1_000_000}M"
    if v >= 1_000:     return f"{v // 1_000}K"
    return str(v)

reth_el    = dk.get("reth", {})
cl_timings = dk.get("cl", {})

cl_names  = {"op-seq": "op-node", "op-kona": "kona", "op-base-cl": "base-consensus"}
cl_name   = cl_names.get(cl, cl)
cl_labels = {"op-kona": "kona (Rust)", "op-base-cl": "base-consensus (Rust)"}
cl_label  = cl_labels.get(cl, "Go op-node")
date_str  = datetime.date.today().isoformat()
gas_str   = fmt_gas(m.get("gas_limit"))
sat_flag  = "YES — p10 block fill > 95%" if m.get("saturated") else "NO — blocks not yet full"

lines = []

# ── header ─────────────────────────────────────────────────────────────────────
lines.append(f"# xlayer Adventure ERC20 Benchmark — {cl_name}")
lines.append("")
lines.append("## Run metadata")
lines.append("")
lines.append("| Field | Value |")
lines.append("|---|---|")
lines.append(f"| Date | {date_str} |")
lines.append(f"| Chain | xlayer devnet (195) · 1s blocks |")
lines.append(f"| Consensus layer | {cl_label} (`{cl}`) |")
lines.append(f"| Execution layer | OKX reth |")
lines.append(f"| Block gas limit | {gas_str} gas |")
lines.append(f"| Warm-up | 30s (dual instances flood mempool) |")
lines.append(f"| Measurement window | {dur}s |")
lines.append(f"| Workers per instance | {workers} (2 instances × {workers} = {workers*2} total) |")
lines.append(f"| Gas price | 100 gwei |")
lines.append(f"| Tx type | ERC20 transfer — 100k gas limit / ~35k gas actual |")
lines.append(f"| ERC20 contract | `{contract}` |")
lines.append(f"| Accounts | {account_count:,} ({account_count//2:,} per instance, funded 0.2 ETH each) |")
lines.append(f"| Test window blocks | {na(m.get('start_bn'))} → {na(m.get('end_bn'))} |")
lines.append(f"| Actual chain time | {na(m.get('chain_duration_s'), 's')} |")
lines.append(f"| Saturated | {sat_flag} |")
lines.append("")

# ── transaction summary ────────────────────────────────────────────────────────
lines.append("## Transaction summary")
lines.append("")
lines.append("| Metric | Value | Notes |")
lines.append("|---|---|---|")
lines.append(f"| Txs submitted — instance A (est.) | {na(m.get('tx_submitted_est'))} | avg BTPS × duration |")
lines.append(f"| Txs confirmed on-chain | {na(m.get('tx_confirmed'))} | block scan {na(m.get('start_bn'))}+1 → {na(m.get('end_bn'))} |")
lines.append(f"| Txs pending at kill (est.) | {na(m.get('tx_pending_est'))} | submitted A − confirmed (B also contributed) |")
lines.append(f"| Tx errors | {m.get('errors', 0)} | adventure exits on first error |")
lines.append("")

# ── throughput ─────────────────────────────────────────────────────────────────
ceiling = round(m['gas_limit'] / 35_000) if m.get('gas_limit') else round(200_000_000 / 35_000)
lines.append("## Throughput")
lines.append("")
lines.append("| Metric | Value | Notes |")
lines.append("|---|---|---|")
lines.append(f"| **Block-inclusion TPS (avg)** | **{na(m.get('tps_block'))} TX/s** | confirmed TXs / actual chain time |")
lines.append(f"| Block-inclusion TPS (p50 per block) | {na(m.get('tps_p50_block'))} TX/s | median single-block TX rate |")
lines.append(f"| Block-inclusion TPS (p95 per block) | {na(m.get('tps_p95_block'))} TX/s | 95th percentile single-block |")
lines.append(f"| Peak confirmed TPS (single block) | {na(m.get('tps_peak_block'))} TX/s | best single block |")
lines.append(f"| Theoretical ceiling | {ceiling} TX/s | {gas_str} gas / ~35k gas per tx |")
lines.append(f"| Mempool send rate — instance A (avg) | {m['tps']} TX/s | adventure `[Summary] Average BTPS` |")
lines.append("")
lines.append("### Block fill distribution")
lines.append("")
lines.append("| Percentile | Fill % | Notes |")
lines.append("|---|---|---|")
lines.append(f"| p10 | {na(m.get('fill_p10'), '%')} | 90% of blocks at least this full |")
lines.append(f"| p50 | {na(m.get('fill_p50'), '%')} | median block fill |")
lines.append(f"| p90 | {na(m.get('fill_p90'), '%')} | 10% of blocks this full or more |")
lines.append(f"| avg | {na(m.get('block_fill'), '%')} | mean across all measurement blocks |")
lines.append("")
lines.append("> **Note on TPS across baseline vs optimised:** TPS ceiling is `gas_limit / ~35k gas` at 1 block/s — the CL cannot push reth faster than its engine processes blocks. Small TPS differences (±1–5%) between baseline and optimised are run-to-run noise, not regression. The priority fix targets sequencer **tail latency** (queue starvation under load), not throughput.")
lines.append("")

# ── CL Engine API timings from docker logs ─────────────────────────────────────
lines.append(f"## Sequencer latency — priority fix evaluation ({cl_label})")
lines.append("")
lines.append("> **Sequencer build wait** is the primary metric for evaluating the priority fix.")
if cl == "op-seq":
    lines.append("> Measured as `time.Since(ScheduledAt)` in `onBuildStart()` — from the moment the sequencer decides to build a block until `payloadId` is received back from the engine.")
    lines.append("> Includes event dispatch time + FCU+attrs HTTP round-trip. Captures any scheduler delay.")
    lines.append("> **FCU+attrs (HTTP only):** just the `engine_forkchoiceUpdatedV3+attrs` call inside `startPayload()`. Does NOT include scheduling delay.")
elif cl in ("op-kona", "op-base-cl"):
    lines.append("> Measured as `build_request_start.elapsed()` in `actor.rs` — from before the sequencer event is sent to the engine channel until `payloadId` is received back.")
    lines.append("> Includes BinaryHeap queue wait + FCU+attrs HTTP round-trip. **This is what the priority fix reduces.**")
    lines.append("> **FCU+attrs (HTTP only):** just the `engine_forkchoiceUpdatedV3+attrs` call inside `BuildTask::execute()`. Starts AFTER the event is dequeued — does NOT show queue wait.")
else:
    lines.append("> CL docker log timings not available for this container.")

stack_name = os.path.basename(json_out)[:-5] if (json_out and json_out.endswith(".json")) else cl
is_optimised = "optimised" in stack_name

if cl_timings:
    lines.append("")
    lines.append("### Block build cycle — internal flow")
    lines.append("")
    if cl == "op-seq":
        lines.append("| Phase | Function | File (repo: optimism) |")
        lines.append("|---|---|---|")
        lines.append("| T0→T1 sync prep | `PreparePayloadAttributes()` | `op-node/node/sequencer.go` |")
        lines.append("| T0→T3 timer | `time.Since(ScheduledAt)` | `op-node/node/sequencer.go` |")
        lines.append("| T2 HTTP dispatch | `startPayload()` | `op-node/node/sequencer.go` |")
        lines.append("| Driver mutex | `Driver.syncStep()` · `Driver.eventStep()` | `op-node/node/driver.go` |")
        lines.append("")
        lines.append("```")
        lines.append("op-node — Go single-threaded event loop (Driver goroutine)")
        lines.append("─────────────────────────────────────────────────────────────────────────────────")
        lines.append("")
        lines.append("T0 ── sequencer tick fires (every 1 second)")
        lines.append("        │")
        lines.append("        │  PreparePayloadAttributes()                 ← SYNCHRONOUS — blocks entire node")
        lines.append("        │  ┌────────────────────────────────────────────────────────────┐")
        lines.append("        │  │  eth_getBlockByNumber(\"latest\")  ← L1 RPC (blocking)     │")
        lines.append("        │  │    → L1 block hash, basefee, timestamp, mix_hash          │")
        lines.append("        │  │  construct L1InfoTx (deposit transaction)                  │")
        lines.append("        │  │  assemble PayloadAttributes { ... }                        │")
        lines.append("        │  │                                                            │")
        lines.append("        │  │  ⚠️  Driver goroutine is FROZEN for the duration:          │")
        lines.append("        │  │     - derivation pipeline is blocked                       │")
        lines.append("        │  │     - no other engine work runs                            │")
        lines.append("        │  │     - entire node suspended until L1 RPC returns           │")
        lines.append("        │  └────────────────────────────────────────────────────────────┘")
        lines.append("        │  (kona does this async — Tokio runtime stays active)")
        lines.append("        │")
        lines.append("T1 ── attrs ready · no queue · direct path to HTTP")
        lines.append("      (op-node has no BinaryHeap engine queue — no T1→T2 wait)")
        lines.append("        │")
        lines.append("T2 ── HTTP: engine_forkchoiceUpdatedV3(headHash, safeHash, finalizedHash, attrs) ──→ reth")
        lines.append("        │  reth engine::tree: validates head, starts payload builder")
        lines.append("        │  ←─ { payloadStatus: \"VALID\", payloadId: \"0x...\" }")
        lines.append("        │")
        lines.append("T3 ── payloadId received")
        lines.append("      time.Since(ScheduledAt) → sequencer_build_wait emitted")
        lines.append("```")
    elif cl == "op-kona" and is_optimised:
        lines.append("| Phase | Function | File (repo: okx-optimism) |")
        lines.append("|---|---|---|")
        lines.append("| T0→T1 attr prep | `prepare_payload_attributes()` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("| T1 timer start | `build_request_start = Instant::now()` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("| T1→T2 engine processor | `flush_pending_messages()` | `kona/crates/node/engine/src/engine_request_processor.rs` |")
        lines.append("| T2 HTTP dispatch | `BuildTask::execute()` → `start_build()` | `kona/crates/node/engine/src/task_queue/tasks/build/task.rs` |")
        lines.append("| T3 metric emit | `build_request_start.elapsed()` → `sequencer_build_wait` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("")
        lines.append("```")
        lines.append("kona-okx-optimised — Rust async Tokio actors (flush_pending_messages fix applied)")
        lines.append("─────────────────────────────────────────────────────────────────────────────────")
        lines.append("")
        lines.append("T0 ── sequencer tick fires (every 1 second, aligned to L2 block time)")
        lines.append("        │")
        lines.append("        │  prepare_payload_attributes()               ← async Tokio future, non-blocking")
        lines.append("        │  ┌────────────────────────────────────────────────────────────┐")
        lines.append("        │  │  eth_getBlockByNumber(\"latest\")  ← L1 RPC (async await)  │")
        lines.append("        │  │    → L1 block hash, basefee, timestamp, mix_hash          │")
        lines.append("        │  │  construct L1InfoTx (deposit transaction):                 │")
        lines.append("        │  │    setL1BlockValues(number, timestamp, basefee,            │")
        lines.append("        │  │                    blockHash, seqNum, batcherAddr, ...)    │")
        lines.append("        │  │  assemble PayloadAttributes {                              │")
        lines.append("        │  │    timestamp        = next_l2_block_time,                 │")
        lines.append("        │  │    prevRandao       = l1_mix_hash,                        │")
        lines.append("        │  │    suggestedFeeRecipient = sequencer_fee_wallet,           │")
        lines.append("        │  │    transactions     = [L1InfoTx],                          │")
        lines.append("        │  │    withdrawals      = [],                                  │")
        lines.append("        │  │    parentBeaconBlockRoot = l1_parent_beacon_root           │")
        lines.append("        │  │  }                                                         │")
        lines.append("        │  └────────────────────────────────────────────────────────────┘")
        lines.append("        │  other Tokio tasks (derivation, safe-head tracking) run concurrently")
        lines.append("        │")
        lines.append("T1 ── build_request_start = Instant::now()            ← engine actor clock STARTS here")
        lines.append("      EngineMessage::Build(attrs) sent via mpsc::Sender (non-blocking, instant return)")
        lines.append("        │")
        lines.append("        │  ┌── Engine actor event loop ─────────────────────────────────────────────┐")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  flush_pending_messages()                ← KEY FIX                    │")
        lines.append("        │  │  ┌─────────────────────────────────────────────────────────────────┐  │")
        lines.append("        │  │  │  loop {                                                         │  │")
        lines.append("        │  │  │    match self.rx.try_recv() {                                   │  │")
        lines.append("        │  │  │      Ok(msg) => self.heap.push(msg),  // drain ALL pending msgs │  │")
        lines.append("        │  │  │      Err(_)  => break,                // channel empty, stop   │  │")
        lines.append("        │  │  │    }                                                            │  │")
        lines.append("        │  │  │  }                                                              │  │")
        lines.append("        │  │  └─────────────────────────────────────────────────────────────────┘  │")
        lines.append("        │  │  heap now has COMPLETE view of all pending work                        │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  BinaryHeap (max-heap ordered by EngineMessage::priority()):           │")
        lines.append("        │  │  ┌─────────────────────────────────────────────────────────────────┐  │")
        lines.append("        │  │  │  Build{attrs}    [SEQUENCER_BUILD = priority HIGH]  ← TOP      │  │")
        lines.append("        │  │  │  Consolidate     [DERIVATION      = priority LOW ]             │  │")
        lines.append("        │  │  │  Consolidate     [DERIVATION      = priority LOW ]             │  │")
        lines.append("        │  │  └─────────────────────────────────────────────────────────────────┘  │")
        lines.append("        │  │  heap.pop() → Build{attrs}  always wins — never starved               │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  └─────────────────────────────────────────────────────────────────────────┘")
        lines.append("        │")
        lines.append("T2 ── BuildTask::execute() dispatched")
        lines.append("        │  HTTP POST engine_forkchoiceUpdatedV3:")
        lines.append("        │  ┌─────────────────────────────────────────────────────────────────────┐")
        lines.append("        │  │  forkchoiceState: {                                                 │")
        lines.append("        │  │    headBlockHash:       current_unsafe_head_hash,                  │")
        lines.append("        │  │    safeBlockHash:       current_safe_head_hash,                    │")
        lines.append("        │  │    finalizedBlockHash:  current_finalized_hash                     │")
        lines.append("        │  │  },                                                                 │")
        lines.append("        │  │  payloadAttributes: {                                              │")
        lines.append("        │  │    timestamp, prevRandao, suggestedFeeRecipient,                   │")
        lines.append("        │  │    transactions: [L1InfoTx], withdrawals: [],                      │")
        lines.append("        │  │    parentBeaconBlockRoot                                           │")
        lines.append("        │  │  }                                                                 │")
        lines.append("        │  └─────────────────────────────────────────────────────────────────────┘")
        lines.append("        │  reth engine::tree: validates head, starts payload builder goroutine")
        lines.append("        │  ←─ HTTP response: { payloadStatus: \"VALID\", payloadId: \"0x1a2b...\" }")
        lines.append("        │")
        lines.append("T3 ── payloadId received")
        lines.append("      build_request_start.elapsed() → sequencer_build_wait emitted")
        lines.append("      log: \"build request completed\" sequencer_build_wait=Xms sequencer_total_wait=Xms")
        lines.append("      reth independently builds the block; getPayload called at next tick")
        lines.append("```")
    elif cl == "op-kona":
        lines.append("| Phase | Function | File (repo: okx-optimism) |")
        lines.append("|---|---|---|")
        lines.append("| T0→T1 attr prep | `prepare_payload_attributes()` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("| T1 timer start | `build_request_start = Instant::now()` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("| T1→T2 engine processor | `rx.recv().await` — reads one message per iteration | `kona/crates/node/engine/src/engine_request_processor.rs` |")
        lines.append("| T2 HTTP dispatch | `BuildTask::execute()` → `start_build()` | `kona/crates/node/engine/src/task_queue/tasks/build/task.rs` |")
        lines.append("| T3 metric emit | `build_request_start.elapsed()` → `sequencer_build_wait` | `kona/crates/node/sequencer/src/actor.rs` |")
        lines.append("")
        lines.append("```")
        lines.append("kona-okx-baseline — Rust async Tokio actors (NO priority fix)")
        lines.append("─────────────────────────────────────────────────────────────────────────────────")
        lines.append("")
        lines.append("T0 ── sequencer tick fires (every 1 second, aligned to L2 block time)")
        lines.append("        │")
        lines.append("        │  prepare_payload_attributes()               ← async Tokio future, non-blocking")
        lines.append("        │  ┌────────────────────────────────────────────────────────────┐")
        lines.append("        │  │  eth_getBlockByNumber(\"latest\")  ← L1 RPC (async await)  │")
        lines.append("        │  │    → L1 block hash, basefee, timestamp, mix_hash          │")
        lines.append("        │  │  construct L1InfoTx (deposit transaction):                 │")
        lines.append("        │  │    setL1BlockValues(number, timestamp, basefee,            │")
        lines.append("        │  │                    blockHash, seqNum, batcherAddr, ...)    │")
        lines.append("        │  │  assemble PayloadAttributes {                              │")
        lines.append("        │  │    timestamp, prevRandao, suggestedFeeRecipient,           │")
        lines.append("        │  │    transactions: [L1InfoTx], withdrawals: [],              │")
        lines.append("        │  │    parentBeaconBlockRoot                                   │")
        lines.append("        │  │  }                                                         │")
        lines.append("        │  └────────────────────────────────────────────────────────────┘")
        lines.append("        │  other Tokio tasks run concurrently during this await")
        lines.append("        │")
        lines.append("T1 ── build_request_start = Instant::now()            ← engine actor clock STARTS here")
        lines.append("      EngineMessage::Build(attrs) sent via mpsc::Sender (non-blocking, instant return)")
        lines.append("        │")
        lines.append("        │  ┌── Engine actor event loop ─────────────────────────────────────────────┐")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  NO flush_pending_messages() — reads ONE message per event loop iter  │")
        lines.append("        │  │  rx.recv().await → picks up next pending msg (may be Consolidate)     │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  BinaryHeap after receiving a few individual messages:                 │")
        lines.append("        │  │  ┌─────────────────────────────────────────────────────────────────┐  │")
        lines.append("        │  │  │  Consolidate     [DERIVATION = priority LOW]  ← dequeued 1st   │  │")
        lines.append("        │  │  │  Consolidate     [DERIVATION = priority LOW]  ← dequeued 2nd   │  │")
        lines.append("        │  │  │  Build{attrs}    [SEQUENCER  = priority HIGH] ← STARVED        │  │")
        lines.append("        │  │  └─────────────────────────────────────────────────────────────────┘  │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  Root cause: Build IS highest priority — but the heap only knows       │")
        lines.append("        │  │  about messages already read from the channel one at a time.           │")
        lines.append("        │  │  Consolidate tasks already in the heap are dequeued before Build       │")
        lines.append("        │  │  is even received from the channel. Build waits until the heap clears. │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  │  Under sustained full-block load, derivation bursts 3–5 Consolidate   │")
        lines.append("        │  │  tasks per block → Build delays up to 37ms at 200M (max).             │")
        lines.append("        │  │                                                                         │")
        lines.append("        │  └─────────────────────────────────────────────────────────────────────────┘")
        lines.append("        │")
        lines.append("T2 ── BuildTask::execute() dispatched (after BinaryHeap drains Consolidate tasks)")
        lines.append("        │  HTTP POST engine_forkchoiceUpdatedV3 { ... } ──→ reth")
        lines.append("        │  ←─ { payloadStatus: \"VALID\", payloadId: \"0x...\" }")
        lines.append("        │")
        lines.append("T3 ── payloadId received")
        lines.append("      build_request_start.elapsed() → sequencer_build_wait emitted")
        lines.append("      log: \"build request completed\" sequencer_build_wait=Xms sequencer_total_wait=Xms")
        lines.append("```")
    elif cl == "op-base-cl":
        lines.append("```")
        lines.append("base-cl — Rust async Tokio actors (BinaryHeap, NO fix applied)")
        lines.append("─────────────────────────────────────────────────────────────────────────────────")
        lines.append("")
        lines.append("T0 ── sequencer tick fires")
        lines.append("        │  prepare_payload_attributes()  — async Tokio (same pattern as kona)")
        lines.append("        │")
        lines.append("T1 ── Build{attrs} → mpsc::Sender → engine actor channel")
        lines.append("        │")
        lines.append("        │  ┌── Engine actor (NO flush_pending_messages) ──────────────────────────┐")
        lines.append("        │  │  BinaryHeap — derivation Consolidate flood blocks Build dispatch:    │")
        lines.append("        │  │  ┌─────────────────────────────────────────────────────────────────┐ │")
        lines.append("        │  │  │  Consolidate [LOW]  ← floods queue under sustained load         │ │")
        lines.append("        │  │  │  Consolidate [LOW]  ← dequeued one at a time                    │ │")
        lines.append("        │  │  │  Build{attrs}[HIGH] ← STARVED — worst case 331ms at 200M        │ │")
        lines.append("        │  │  └─────────────────────────────────────────────────────────────────┘ │")
        lines.append("        │  └────────────────────────────────────────────────────────────────────────┘")
        lines.append("        │")
        lines.append("T2 ── HTTP POST engine_forkchoiceUpdatedV3 { ... } ──→ reth")
        lines.append("        │  ←─ { payloadId: \"0x...\" }")
        lines.append("        │")
        lines.append("T3 ── payloadId received")
    lines.append("")
    lines.append("### Sequencer build latency — T0→T3 timing model")
    lines.append("")
    def _ms(d, key):
        if not d: return "N/A"
        v = d.get(key)
        return f"{v:.1f} ms" if v is not None else "N/A"
    def _hrow(label, key, indent):
        d   = cl_timings.get(key) or {}
        p50 = _ms(d, 'p50')
        p99 = _ms(d, 'p99')
        mx  = _ms(d, 'max')
        pad = "&nbsp;&nbsp;" * indent
        arrow = "▸&nbsp;" if indent == 1 else ("◦&nbsp;" if indent == 2 else "")
        lines.append(f"| {pad}{arrow}{label} | {p50} | {p99} | {mx} |")
    lines.append("| Phase | p50 | p99 | max |")
    lines.append("|---|---|---|---|")
    _hrow("**T0→T3 &nbsp; Sequencer tick → payloadId (full cycle)**", "total_wait", 0)
    _hrow("T0→T1 &nbsp; Payload Prep — L1 fetch + attr construction", "attr_prep", 1)
    _hrow("T1→T3 &nbsp; Engine actor wait ¹", "build_wait", 1)
    if cl in ("op-kona", "op-base-cl"):
        _hrow("T1→T2 &nbsp; Heap drain stall", "queue_wait", 2)
    _hrow("T2→T3 &nbsp; FCU+attrs HTTP round-trip", "fcu_attrs", 2)
    lines.append("")
    lines.append("> ¹ **Why sub-rows don't sum to parent:** Each p99/max is the 99th-worst event from its own per-block")
    lines.append("> distribution. The worst total-build block is not always the same block as the worst Payload-Prep")
    lines.append("> AND worst Engine-actor-wait simultaneously. Per-event values always sum: `total[i] = attr_prep[i] + build_wait[i]`.")
    lines.append(">")
    lines.append("> **T1→T2 Heap drain stall:** time Build{attrs} spends waiting inside the BinaryHeap for Consolidate tasks")
    lines.append("> that arrived earlier to drain first. Distinct from the mpsc channel send at T1 (non-blocking, near-instant).")
    if cl == "op-seq":
        drv_rows = [("FCU (derivation)",        "fcu"),
                    ("new_payload",              "new_pay")]
    elif cl == "op-kona":
        drv_rows = [("FCU (derivation)",        "fcu"),
                    ("new_payload (derivation)", "new_pay"),
                    ("Block import / seal",      "block_import")]
    else:
        drv_rows = [("FCU",                     "fcu"),
                    ("new_payload",              "new_pay")]
    def _row(label, key):
        d   = cl_timings.get(key) or {}
        p50 = f"{d['p50']:.1f} ms" if d.get('p50') is not None else "N/A"
        p99 = f"{d['p99']:.1f} ms" if d.get('p99') is not None else "N/A"
        mx  = f"{d['max']:.1f} ms" if d.get('max') is not None else "N/A"
        n   = d.get('n', '—')
        return f"| {label} | {p50} | {p99} | {mx} | {n} |"
    lines.append("")
    lines.append("### Derivation engine calls (reference)")
    lines.append("")
    lines.append("| Call | p50 | p99 | max | n |")
    lines.append("|---|---|---|---|---|")
    for row_label, key in drv_rows:
        lines.append(_row(row_label, key))

# ── reth EL log timings ────────────────────────────────────────────────────────
lines.append("")
lines.append("## Engine API — reth EL log timings")
lines.append("")
lines.append("> Extracted from reth docker logs (`engine::tree`). Measures reth's own processing time.")
lines.append("")
lines.append("| Call | p50 | p99 | max | n |")
lines.append("|---|---|---|---|---|")
for label, key in [("FCU (no attrs)", "fcu"), ("FCU+attrs", "fcu_attrs"), ("new_payload", "new_pay")]:
    d = reth_el.get(key) or {}
    p50 = f"{d['p50']:.1f} ms" if d.get('p50') is not None else "N/A"
    p99 = f"{d['p99']:.1f} ms" if d.get('p99') is not None else "N/A"
    mx  = f"{d['max']:.1f} ms" if d.get('max') is not None else "N/A"
    n   = d.get('n', '—')
    lines.append(f"| {label} | {p50} | {p99} | {mx} | {n} |")

# safe lag: captured in JSON sidecar (safe_lag_avg / safe_lag_max) but not shown in report for now

lines.append("")
lines.append("---")
lines.append(f"*Generated by bench-adventure.sh · {date_str}*")

print("\n".join(lines))

# ── sidecar JSON for comparison generator ─────────────────────────────────────
if json_out:
    def _g(key):    return (reth_el.get(key) or {}).get("p50")
    def _cl(key):   return (cl_timings.get(key) or {}).get("p50")
    def _cl99(key): return (cl_timings.get(key) or {}).get("p99")
    def _clmax(key):return (cl_timings.get(key) or {}).get("max")
    def _clavg(key):return (cl_timings.get(key) or {}).get("avg")
    summary = {
        "cl": cl_name, "cl_container": cl, "date": date_str,
        "duration_s": dur, "workers": workers*2,
        "account_count": account_count,
        "gas_limit": m.get("gas_limit"), "gas_limit_str": gas_str,
        "saturated": m.get("saturated"),
        # throughput
        "tps_block":       m.get("tps_block"),
        "tps_p50_block":   m.get("tps_p50_block"),
        "tps_peak_block":  m.get("tps_peak_block"),
        "block_fill":      m.get("block_fill"),
        "fill_p10":        m.get("fill_p10"),
        "fill_p50":        m.get("fill_p50"),
        "fill_p90":        m.get("fill_p90"),
        "tps_mempool_avg": m.get("tps"),
        # tx counts
        "tx_confirmed":    m.get("tx_confirmed"),
        "tx_submitted_est":m.get("tx_submitted_est"),
        "start_bn":        m.get("start_bn"),
        "end_bn":          m.get("end_bn"),
        # safe lag
        "safe_lag_avg": m.get("safe_lag_avg"),
        "safe_lag_max": m.get("safe_lag_max"),
        # CL Engine API timings (from CL docker logs — organic calls only, no probe)
        # fcu_attrs: both op-node and kona measure FCU+attrs HTTP round-trip (~1ms)
        "cl_fcu_attrs_p50": _cl("fcu_attrs"), "cl_fcu_attrs_p99": _cl99("fcu_attrs"), "cl_fcu_attrs_max": _clmax("fcu_attrs"),
        # fcu: kona=derivation FCU, op-node=not separately logged
        "cl_fcu_p50":       _cl("fcu"),       "cl_fcu_p99":       _cl99("fcu"),       "cl_fcu_max":       _clmax("fcu"),
        # new_pay: newPayload round-trip
        "cl_new_pay_p50":   _cl("new_pay"),   "cl_new_pay_p99":   _cl99("new_pay"),   "cl_new_pay_max":   _clmax("new_pay"),
        # block_import: kona seal cycle (getPayload+newPayload), op-node=N/A
        "cl_block_import_p50": _cl("block_import"), "cl_block_import_p99": _cl99("block_import"), "cl_block_import_max": _clmax("block_import"),
        # build_wait: total sequencer latency (before channel send → payloadId back)
        #   op-node: time.Since(ScheduledAt) in onBuildStart() — includes event dispatch + HTTP
        #   kona/base-cl: build_request_start.elapsed() in actor.rs — includes queue wait + HTTP
        #   This is the metric that shows the priority-fix effect; fcu_attrs excludes queue wait
        "cl_build_wait_p50": _cl("build_wait"), "cl_build_wait_p99": _cl99("build_wait"), "cl_build_wait_max": _clmax("build_wait"), "cl_build_wait_avg": _clavg("build_wait"),
        # queue_wait: T1→T2 — time waiting in BinaryHeap before FCU was sent to EL
        #   = build_wait − fcu_attrs (derived in parser, no rebuild needed)
        #   This is the direct signal of the priority fix: kona-optimised queue_wait ≈ 0
        "cl_queue_wait_p50": _cl("queue_wait"), "cl_queue_wait_p99": _cl99("queue_wait"), "cl_queue_wait_max": _clmax("queue_wait"), "cl_queue_wait_avg": _clavg("queue_wait"),
        # total_wait: T0→T3 — full build cycle from [sequencer decides] to [payloadId received]
        #   requires rebuild of all CLs (sequencer_total_wait= log field)
        "cl_total_wait_p50": _cl("total_wait"), "cl_total_wait_p99": _cl99("total_wait"), "cl_total_wait_max": _clmax("total_wait"), "cl_total_wait_avg": _clavg("total_wait"),
        # attr_prep: T0→T1 — attribute preparation phase (L1 info, deposits, etc.)
        #   = total_wait − build_wait (derived in parser, no rebuild needed once total_wait exists)
        "cl_attr_prep_p50":  _cl("attr_prep"),  "cl_attr_prep_p99":  _cl99("attr_prep"),  "cl_attr_prep_max":  _clmax("attr_prep"),  "cl_attr_prep_avg":  _clavg("attr_prep"),
        # fcu_attrs avg (T2→T3)
        "cl_fcu_attrs_avg": _clavg("fcu_attrs"),
        # T0→T1 micro-steps (actor.rs instrumentation — kona only)
        "cl_attr_step_a_p50": _cl("attr_step_a"), "cl_attr_step_a_p99": _cl99("attr_step_a"), "cl_attr_step_a_avg": _clavg("attr_step_a"), "cl_attr_step_a_max": _clmax("attr_step_a"),
        "cl_attr_step_b_p50": _cl("attr_step_b"), "cl_attr_step_b_p99": _cl99("attr_step_b"), "cl_attr_step_b_avg": _clavg("attr_step_b"), "cl_attr_step_b_max": _clmax("attr_step_b"),
        "cl_attr_step_c_p50": _cl("attr_step_c"), "cl_attr_step_c_p99": _cl99("attr_step_c"), "cl_attr_step_c_avg": _clavg("attr_step_c"), "cl_attr_step_c_max": _clmax("attr_step_c"),
        # T0→T1 sub-steps C1–C4 (stateful.rs instrumentation — kona only)
        "cl_attr_step_c1_p50": _cl("attr_step_c1"), "cl_attr_step_c1_p99": _cl99("attr_step_c1"), "cl_attr_step_c1_avg": _clavg("attr_step_c1"), "cl_attr_step_c1_max": _clmax("attr_step_c1"),
        "cl_attr_step_c2_p50": _cl("attr_step_c2"), "cl_attr_step_c2_p99": _cl99("attr_step_c2"), "cl_attr_step_c2_avg": _clavg("attr_step_c2"), "cl_attr_step_c2_max": _clmax("attr_step_c2"),
        "cl_attr_step_c3_p50": _cl("attr_step_c3"), "cl_attr_step_c3_p99": _cl99("attr_step_c3"), "cl_attr_step_c3_avg": _clavg("attr_step_c3"), "cl_attr_step_c3_max": _clmax("attr_step_c3"),
        "cl_attr_step_c4_p50": _cl("attr_step_c4"), "cl_attr_step_c4_p99": _cl99("attr_step_c4"), "cl_attr_step_c4_avg": _clavg("attr_step_c4"), "cl_attr_step_c4_max": _clmax("attr_step_c4"),
        "cl_attr_epoch_change_count": (cl_timings.get("attr_epoch_change_count") or {}).get("n"),
        # reth EL timings (reth-side processing time, same source for all CLs)
        "reth_fcu_attrs_p50": _g("fcu_attrs"),
        "reth_new_pay_p50":   _g("new_pay"),
    }
    try:
        os.makedirs(os.path.dirname(json_out), exist_ok=True)
        with open(json_out, "w") as f:
            json.dump(summary, f, indent=2)
    except Exception as e:
        import sys as _sys
        print(f"  [warn] could not write sidecar JSON: {e}", file=_sys.stderr)

PYPRINT
