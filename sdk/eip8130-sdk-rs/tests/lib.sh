#!/usr/bin/env bash
# Shared helpers + config for the EIP-8130 e2e test scripts.
# Sourced by run-basic-tests.sh and run-boundary-tests.sh.
#
# Globals exposed:
#   RPC_URL CHAIN_ID HERE SDK_BIN
#   ADDR_S/KEY_S ADDR_P/KEY_P ADDR_X/KEY_X
#   DEFAULT_ACCOUNT NONCE_KEY_MAX_HEX
#   T1 T2 T3 T_REVERT
#   VERBOSE SELECTED PASS FAIL SKIP FAILED
#
# Helpers exposed:
#   run_case ok fail skip verbose_run
#   rpc get_nonce now_secs
#   extract_field extract_tx_hash extract_dry_run_field extract_payer_auth
#   receipt_field classify_outcome assert_status phase_statuses
#   receipt_payer receipt_type
#   fresh_secret_key fund_account get_code
#   parse_common_args print_summary

set -u
set -o pipefail

# ── Config ───────────────────────────────────────────────────────────────────

RPC_URL="${RPC_URL:-http://localhost:8123}"
CHAIN_ID="${CHAIN_ID:-195}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_BIN="${SDK_BIN:-$HERE/../target/release/eip8130-send}"

# anvil-style mnemonic dev keys (well-funded on devnet L2)
ADDR_S=0x70997970C51812dc3A010C7d01b50e0d17dc79C8  # sender (account 1)
KEY_S=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ADDR_P=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC  # payer (account 2)
KEY_P=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ADDR_X=0x90F79bf6EB2c4f870365E785982E1f101E93b906  # 3rd party (account 3)
KEY_X=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

DEFAULT_ACCOUNT=0xAb4eE49EE97e49807e180BD5Fb9D9F35783b84F2
NONCE_KEY_MAX_HEX=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

# Dedicated funder: anvil account 0. Never participates in AA flows so it
# stays un-delegated → no EIP-7702 1-slot in-flight throttle on funding.
FUNDER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
FUNDER_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266

# Pre-funded key pool — built lazily by `bulk_prefund` in preflight when
# running the full suite. Per-test calls to `fresh_secret_key` pop from
# this pool; when empty (single-test runs or pool exhausted), each call
# falls back to fresh-generation + per-test funding.
POOL_KEYS=()
POOL_IDX=0

# Targets without code: calls succeed (no-op return).
T1=0x1111111111111111111111111111111111111111
T2=0x2222222222222222222222222222222222222222
T3=0x3333333333333333333333333333333333333333

# Reverting target: NonceManager precompile address has stub bytecode `0xfe`
# (INVALID opcode), so any plain call reverts. Useful for phase-revert tests
# without deploying a custom contract.
T_REVERT=0x000000000000000000000000000000000000aa02

VERBOSE=0
SELECTED=()

PASS=0
FAIL=0
SKIP=0
FAILED=()

# ── Argument parser ─────────────────────────────────────────────────────────
# Caller passes its own positional args here (e.g. parse_common_args "$@").
parse_common_args() {
    for arg in "$@"; do
        case "$arg" in
            -v|--verbose) VERBOSE=1 ;;
            T-*|B-*) SELECTED+=("$arg") ;;
            *) echo "unknown arg: $arg" >&2; exit 2 ;;
        esac
    done
}

# ── Helpers ──────────────────────────────────────────────────────────────────

run_case() {
    local id="$1" desc="$2"
    if (( ${#SELECTED[@]} > 0 )); then
        local match=0
        for sel in "${SELECTED[@]}"; do [[ "$sel" == "$id" ]] && match=1; done
        # Return non-zero so callers using `|| return` skip the test
        # body entirely.
        (( match == 0 )) && return 1
    fi
    printf '  %-7s %s ... ' "$id" "$desc"
    return 0
}

ok()   { echo "ok"; PASS=$((PASS+1)); }
fail() { echo "FAIL — $*"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
skip() { echo "skip — $*"; SKIP=$((SKIP+1)); }

verbose_run() {
    [[ "$VERBOSE" == "1" ]] && echo
    [[ "$VERBOSE" == "1" ]] && echo "    \$ $*"
    "$@" 2>&1
}

rpc() {
    local method="$1" params="$2"
    curl -fsS -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
        "$RPC_URL"
}

get_nonce() {
    local addr="$1" key="${2:-0x0}"
    local resp; resp=$(rpc eth_getTransactionCount "[\"$addr\",\"latest\",\"$key\"]")
    python3 -c "import json,sys; r=json.loads('''$resp'''); print(int(r['result'],16) if 'result' in r else -1)"
}

now_secs() { date +%s; }

extract_field() {
    awk -v p="$2" 'index($0,p){print; exit}' <<<"$1"
}

extract_tx_hash() {
    awk 'match($0,/submitted: 0x[0-9a-fA-F]+/){print substr($0,RSTART+11,RLENGTH-11); exit}' <<<"$1"
}

extract_dry_run_field() {
    local out="$1" field="$2"
    grep -E '^\{".*"' <<<"$out" | tail -1 | python3 -c "
import json, sys
line = sys.stdin.read().strip()
if not line: sys.exit(0)
print(json.loads(line).get('$field', ''))
" 2>/dev/null
}

extract_payer_auth() {
    extract_dry_run_field "$1" payer_auth
}

receipt_field() {
    local hash="$1" field="$2"
    [[ -z "$hash" ]] && return 1
    local resp; resp=$(rpc eth_getTransactionReceipt "[\"$hash\"]")
    python3 -c "
import json, sys
r = json.loads('''$resp''').get('result') or {}
v = r.get('$field')
if v is None: print('')
elif isinstance(v, list): print(','.join('true' if x in (True,1,'0x1') else 'false' for x in v))
else: print(v)
" 2>/dev/null
}

classify_outcome() {
    local out="$1"
    local hash; hash=$(extract_tx_hash "$out")
    if [[ -n "$hash" ]]; then
        local status; status=$(receipt_field "$hash" status)
        case "$status" in
            0x1) echo "success" ;;
            0x0) echo "reverted" ;;
            *)   echo "" ;;
        esac
        return 0
    fi
    if grep -qE 'error code -[0-9]+|server returned an error' <<<"$out"; then
        echo "rejected"
        return 0
    fi
    if grep -q 'Error:' <<<"$out"; then
        echo "rejected"
        return 0
    fi
    echo ""
}

assert_status() {
    local out="$1" want="$2"
    local got; got=$(classify_outcome "$out")
    [[ "$got" == "$want" ]]
}

phase_statuses() {
    local hash; hash=$(extract_tx_hash "$1")
    receipt_field "$hash" phaseStatuses
}

receipt_payer() {
    local hash; hash=$(extract_tx_hash "$1")
    receipt_field "$hash" payer | tr 'A-Z' 'a-z'
}

receipt_type() {
    local hash; hash=$(extract_tx_hash "$1")
    receipt_field "$hash" type
}

# Internal: generate a brand-new secp256k1 key without consulting the pool.
fresh_secret_key_raw() {
    python3 -c "
import hashlib, secrets, time
seed = hashlib.sha256(f'$1-{time.time_ns()}-{secrets.token_hex(8)}'.encode()).digest()
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
k = (int.from_bytes(seed,'big') % (N-1)) + 1
print('0x{:064x}'.format(k))
"
}

# Public: returns a fresh-or-pool secp256k1 key. When the pre-funded pool
# (built by `bulk_prefund` in preflight for full suite runs) has remaining
# entries, pop one (already funded). Otherwise generate a new key — the
# caller's `fund_account` will handle per-test funding.
fresh_secret_key() {
    if (( POOL_IDX < ${#POOL_KEYS[@]} )); then
        echo "${POOL_KEYS[$POOL_IDX]}"
        ((POOL_IDX++))
        return
    fi
    fresh_secret_key_raw "$1"
}

# Generates a fresh P256 (secp256r1) private key.
fresh_p256_secret_key() {
    python3 -c "
import hashlib, secrets, time
seed = hashlib.sha256(f'$1-p256-{time.time_ns()}-{secrets.token_hex(8)}'.encode()).digest()
# secp256r1 group order n.
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
k = (int.from_bytes(seed,'big') % (N-1)) + 1
print('0x{:064x}'.format(k))
"
}

fund_account() {
    local addr="$1" amount="${2:-0.01ether}"
    # Quick path: pre-funded pool keys already have balance; skip cast send.
    local bal; bal=$(rpc eth_getBalance "[\"$addr\",\"latest\"]" \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result','0x0'); print(int(r,16))")
    [[ "$bal" != "0" ]] && return 0
    # Slow path: send a fresh funding tx from FUNDER (un-delegated, no
    # EIP-7702 in-flight throttle) and poll until balance is non-zero.
    local attempt
    for attempt in 1 2 3; do
        cast send --private-key "$FUNDER_KEY" --rpc-url "$RPC_URL" \
            "$addr" --value "$amount" >/dev/null 2>&1 || true
        bal=$(rpc eth_getBalance "[\"$addr\",\"latest\"]" \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result','0x0'); print(int(r,16))")
        [[ "$bal" != "0" ]] && return 0
        sleep 1
    done
    return 1
}

# Build the pre-funded key pool by submitting N funding txs in parallel.
# Each tx uses an explicit nonce so cast doesn't race on `eth_getTransactionCount`.
# Returns once the highest-nonce funding has confirmed (so all keys are funded).
bulk_prefund() {
    local n="$1"
    local amount="${2:-0.01ether}"
    POOL_KEYS=()
    POOL_IDX=0
    local addrs=()

    echo "  [preflight] generating $n keys + bulk-funding via account 0..."
    for i in $(seq 1 "$n"); do
        local k; k=$(fresh_secret_key_raw "pool-$i")
        POOL_KEYS+=("$k")
    done
    for k in "${POOL_KEYS[@]}"; do
        addrs+=("$(cast wallet address --private-key "$k")")
    done

    # Read funder's next nonce ONCE; assign nonces sequentially to async sends.
    local start_nonce
    start_nonce=$(rpc eth_getTransactionCount "[\"$FUNDER_ADDR\",\"pending\"]" \
        | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")

    # Fan out: submit all $n funding txs concurrently with explicit nonces.
    for i in "${!addrs[@]}"; do
        cast send --private-key "$FUNDER_KEY" --rpc-url "$RPC_URL" \
            --nonce $((start_nonce + i)) --async \
            "${addrs[$i]}" --value "$amount" >/dev/null 2>&1 &
    done
    wait

    # The highest-nonce tx mines last; once its balance is set, all earlier
    # ones must have mined too (nonce ordering).
    local last="${addrs[$((n-1))]}"
    local deadline=$((SECONDS + 60))
    until (( $(rpc eth_getBalance "[\"$last\",\"latest\"]" \
        | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('result','0x0'),16))") > 0 ))
    do
        (( SECONDS > deadline )) && { echo "  [preflight] bulk_prefund timed out" >&2; return 1; }
        sleep 1
    done
    echo "  [preflight] pool ready: $n keys funded"
}

get_code() {
    local addr="$1"
    local resp; resp=$(rpc eth_getCode "[\"$addr\",\"latest\"]")
    python3 -c "import json,sys; r=json.loads('''$resp'''); print((r.get('result') or '0x')[2:])"
}

# Drain a single (account, channel) of any stuck-queued AA txs by submitting
# a fresh high-fee no-op. Called by preflight on the channels the suite
# touches most often. Silent on failure — drain is best-effort and not load-
# bearing for correctness; a failure here just leaves the test author to
# discover a stuck pool the hard way.
drain_channel() {
    local key="$1" channel="$2"
    "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" \
        --private-key "$key" --to "$T1" --data 0x \
        --nonce-key "$channel" --auto-nonce --gas-limit 100000 \
        --max-fee-gwei 50 --priority-fee-gwei 25 \
        >/dev/null 2>&1 || true
}

# Pre-flight: SDK present, RPC reachable, chain ID matches, common
# (sender, channel) pairs drained of stuck tx residue from prior runs.
preflight() {
    if [[ ! -x "$SDK_BIN" ]]; then
        echo "SDK binary not found at $SDK_BIN — run \`cargo build --release\` first." >&2
        exit 1
    fi
    if ! curl -fsS -X POST -H 'Content-Type: application/json' \
            --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
            "$RPC_URL" >/dev/null; then
        echo "RPC at $RPC_URL not reachable." >&2
        exit 1
    fi
    # Drain ADDR_S on the channels tests use most: 0 (default), 0xdead (T-11),
    # 0x1, 0x2222 (B-22). Quick high-fee no-ops kick out stuck residue.
    if [[ "${SKIP_DRAIN:-0}" != "1" ]]; then
        for ch in 0x0 0xdead 0x1 0x2222; do
            drain_channel "$KEY_S" "$ch"
        done
    fi

    # Pre-fund a pool of fresh keys when running the full suite (or a
    # large selection). Single-test runs skip this — per-test funding
    # in the few-seconds range is fine and saves the ~30s preflight.
    # Override with `SKIP_PREFUND=1` to force per-test funding even on
    # full runs (useful when devnet basefee is volatile).
    local pool_size="${PREFUND_POOL_SIZE:-200}"
    if [[ "${SKIP_PREFUND:-0}" != "1" ]] \
        && (( ${#SELECTED[@]} == 0 || ${#SELECTED[@]} > 5 )); then
        bulk_prefund "$pool_size" || true
    fi
}

print_summary() {
    local label="${1:-suite}"
    echo
    echo "[$label] pass: $PASS  fail: $FAIL  skip: $SKIP"
    if (( FAIL > 0 )); then
        echo "FAILED: ${FAILED[*]}"
        return 1
    fi
    return 0
}
