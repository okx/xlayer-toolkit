# EIP-8130 BOUNDARY-PAYER e2e tests (B-250..B-299).
#
# Sourced by run-boundary-tests.sh. Focus: payer / sponsor edges that the
# basic suite (T-50..T-55) and run-boundary-tests.sh (B-70/B-71) don't
# cover — sponsorship economics, payer-bound signature hash mutations
# (BUG-001 surface area), pre-transfer mechanics, configured-owner
# self-pay, multi-tx-same-payer, sponsored reverts, sponsored
# delegation / config-change.
#
# Defines test_BXXX functions and exports BOUNDARY_PAYER_TESTS at the end.
# All tests use the runner-provided helpers (run_case, ok, fail, skip,
# verbose_run, rpc, get_nonce, fresh_secret_key, fund_account,
# extract_dry_run_field, classify_outcome, assert_status, receipt_field,
# receipt_payer). Globals: RPC_URL, CHAIN_ID, SDK_BIN, ADDR_S/KEY_S,
# ADDR_P/KEY_P, ADDR_X/KEY_X, T1, T2, T_REVERT, DEFAULT_ACCOUNT.

# ── Local helpers ────────────────────────────────────────────────────────────

# Returns balance (decimal wei) at `latest`.
_bal_wei() {
    local addr="$1"
    rpc eth_getBalance "[\"$addr\",\"latest\"]" \
        | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('result','0x0'),16))"
}

# Returns balance at the block number where `hash` was mined (decimal wei).
# If hash hasn't mined yet, returns "".
_bal_wei_at_block() {
    local addr="$1" hash="$2"
    local bn; bn=$(receipt_field "$hash" blockNumber)
    [[ -z "$bn" || "$bn" == "null" ]] && return 0
    rpc eth_getBalance "[\"$addr\",\"$bn\"]" \
        | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('result','0x0'),16))"
}

# ── A. Payer identity edges ──────────────────────────────────────────────────

# B-250: payer = 0x0 with a real --payer-key. The validator looks up
# owner_config[(0x0, derived_owner_id)] which doesn't exist, and the
# implicit-EOA rule for the zero address is meaningless (no balance, no
# bytecode, can't ecrecover to it). Mempool must reject.
test_B250() {
    run_case B-250 "payer = 0x0 (zero address) → reject (no balance / not authorized)" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local zero=0x0000000000000000000000000000000000000000
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0250 \
        --payer $zero --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-250 "expected rejected (zero-addr payer); got: $out"; fi
}

# B-251: payer = system precompile (NonceManager at 0x...aa02). It has
# stub bytecode but no owner_config entry, no balance, and isn't a
# regular EOA (implicit-EOA rule won't help). Reject.
test_B251() {
    run_case B-251 "payer = NonceManager precompile (0x...aa02) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local pre=0x000000000000000000000000000000000000aa02
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0251 \
        --payer $pre --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-251 "expected rejected (precompile payer); got: $out"; fi
}

# B-252: --payer set but neither --payer-key nor --payer-auth-hex.
# SDK enforces at args parse: "--payer requires --payer-key or
# --payer-auth-hex" (main.rs:333). Client-side reject expected.
test_B252() {
    run_case B-252 "payer set, no payer-key + no payer-auth-hex → SDK client reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # Run without --payer-key/--payer-auth-hex. SDK errors before any RPC.
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0252 \
        --payer $ADDR_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if grep -qE 'requires --payer-key|payer-auth-hex|Error' <<<"$out"; then ok
    else fail B-252 "expected SDK reject; got: $out"; fi
}

# B-253: payer set, --payer-auth-hex 0x (empty). Mempool sees
# tx.payer_auth.len() == 0, hits validate_payer's "payer_auth too short
# for verifier address" branch (eip8130_validate.rs:985-989) → reject.
test_B253() {
    run_case B-253 "empty payer_auth (0x) with non-empty payer → chain reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0253 \
        --payer $ADDR_P --payer-auth-hex 0x \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-253 "expected rejected (empty payer_auth); got: $out"; fi
}

# ── B. payer_signature_hash binding mutations (BUG-001 surface) ──────────────
#
# Every test in this group:
#   1. Builds a tx with one set of params via --dry-run, captures payer_auth.
#   2. Resubmits the tx with one field mutated, INJECTING the captured
#      payer_auth via --payer-auth-hex (which bypasses re-signing).
#   3. The validator computes payer_signature_hash with the MUTATED tx;
#      ecrecover yields a different ownerId; owner_config lookup fails →
#      reject (per fix in commit 91e7606a6f).

# B-254: mutate nonce_sequence after payer signs.
test_B254() {
    run_case B-254 "payer signs seq=N, sender resubmits as seq=N+1 → reject (sig over wrong seq)" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-254)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)

    # Step 1: dry-run at seq=N to capture payer_auth.
    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0254 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-254 "couldn't capture payer_auth: $dry"; return; }

    # Step 2: resubmit at seq=N+1 with the captured (stale) payer_auth.
    # Note: this would produce a nonce gap as a side effect, but the
    # payer-auth check fires first (mempool order: sender-validation +
    # payer-validation precede nonce ordering).
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0254 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $((n + 1)) --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-254 "stale-seq replay accepted: $out"; fi
}

# B-255: mutate chain_id after payer signs.
test_B255() {
    run_case B-255 "payer signs chain_id=X, sender resubmits chain_id=X+1 → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-255)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local wrong_chain=$(( CHAIN_ID + 1 ))

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0255 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-255 "couldn't capture payer_auth: $dry"; return; }

    # Resubmit with mutated chain_id. (The chain itself will also reject
    # due to chain_id mismatch — see T-96 — but the payer signature is
    # ALSO bound to chain_id, so even if chain_id check were lenient the
    # payer hash would still differ → reject.)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $wrong_chain \
        --private-key $fresh_key --to $T1 --data 0x0255 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-255 "mutated chain_id accepted: $out"; fi
}

# B-256: mutate `to` (calls target) after payer signs.
test_B256() {
    run_case B-256 "payer signs to=T1, sender mutates to=T2 → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-256)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0256 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-256 "couldn't capture payer_auth: $dry"; return; }

    # Resubmit redirected to T2 with the SAME payer_auth bytes.
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T2 --data 0x0256 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-256 "mutated 'to' accepted: $out"; fi
}

# B-257: mutate calldata after payer signs.
test_B257() {
    run_case B-257 "payer signs data=0x257a, sender swaps data=0x257b → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-257)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x257a \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-257 "couldn't capture payer_auth: $dry"; return; }

    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x257b \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-257 "mutated calldata accepted: $out"; fi
}

# B-258: mutate gas_limit after payer signs (sender bumps it to drain
# more of the payer's budget). gas_limit is part of the payer hash so
# any change → recovery yields wrong ownerId → reject.
test_B258() {
    run_case B-258 "payer signs gas_limit=100k, sender bumps to 500k → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-258)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0258 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-258 "couldn't capture payer_auth: $dry"; return; }

    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0258 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 500000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-258 "mutated gas_limit accepted: $out"; fi
}

# B-259: mutate expiry after payer signs (sender pushes expiry farther
# out — would let them sit on a sponsored tx longer than payer
# authorized). Payer hash binds to expiry → mutation → reject.
test_B259() {
    run_case B-259 "payer signs short expiry, sender extends expiry → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-259)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local short_exp=$(( $(now_secs) + 60 ))
    local long_exp=$(( $(now_secs) + 3600 ))

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0259 \
        --payer $ADDR_P --payer-key $KEY_P \
        --expiry $short_exp \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-259 "couldn't capture payer_auth: $dry"; return; }

    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0259 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --expiry $long_exp \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-259 "extended-expiry accepted: $out"; fi
}

# B-260: mutate max_fee_per_gas after payer signs (sender bumps fee →
# drains more of payer's wallet). Bound by payer hash → reject.
test_B260() {
    run_case B-260 "payer signs max_fee=2, sender bumps to max_fee=20 → reject" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-260)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)

    local dry; dry=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0260 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    local pa; pa=$(extract_payer_auth "$dry")
    [[ -z "$pa" ]] && { fail B-260 "couldn't capture payer_auth: $dry"; return; }

    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0260 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 20 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-260 "bumped max_fee accepted: $out"; fi
}

# ── C. Sponsorship economics ─────────────────────────────────────────────────

# B-261: sender == payer with `--from $ADDR --payer $ADDR --payer-key
# $KEY` (configured-owner mode, self-pay). Spec semantics: payer slot
# equals from, treated like a normal sponsored flow against the same
# owner_config. Receipt should report payer == ADDR.
test_B261() {
    run_case B-261 "Configured-owner self-pay (--from = --payer = sender) → success, payer=sender" || return
    # Fresh key so configured-owner mode against the (auto-delegated)
    # account doesn't clash with prior test state.
    local fresh_key; fresh_key=$(fresh_secret_key B-261)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    fund_account "$fresh_addr" 0.05ether
    local n; n=$(get_nonce $fresh_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --from $fresh_addr \
        --to $T1 --data 0x0261 \
        --payer $fresh_addr --payer-key $fresh_key \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local actual; actual=$(receipt_payer "$out")
    local fresh_lc; fresh_lc=$(echo "$fresh_addr" | tr 'A-Z' 'a-z')
    if assert_status "$out" success && [[ "$actual" == "$fresh_lc" ]]; then ok
    else fail B-261 "payer=$actual (expected $fresh_lc); $out"; fi
}

# B-262: payer with EXACTLY enough balance for gas_limit * max_fee.
# Pre-fund payer with exactly that amount, then sponsor a tx whose
# upper-bound budget == balance. Validator's budget check
# (balance >= gas_limit * max_fee_per_gas) at the boundary should
# accept (>=, not >).
test_B262() {
    run_case B-262 "payer balance == gas_limit * max_fee (exact) → success" || return
    local fresh_payer_key; fresh_payer_key=$(fresh_secret_key B-262-payer)
    local fresh_payer_addr; fresh_payer_addr=$(cast wallet address --private-key $fresh_payer_key)
    local fresh_sender_key; fresh_sender_key=$(fresh_secret_key B-262-sender)
    local fresh_sender_addr; fresh_sender_addr=$(cast wallet address --private-key $fresh_sender_key)

    # Budget = gas_limit (100_000) * max_fee_per_gas (2 gwei = 2e9 wei)
    #        = 2e14 wei = 0.0002 ether.
    # Fund with exactly that, plus 0 extra. cast accepts wei suffix.
    local budget_wei=200000000000000  # 2e14
    cast send --private-key "$KEY_S" --rpc-url "$RPC_URL" \
        "$fresh_payer_addr" --value "${budget_wei}wei" >/dev/null 2>&1 || {
        fail B-262 "couldn't pre-fund payer"; return; }
    local actual_bal; actual_bal=$(_bal_wei "$fresh_payer_addr")
    if [[ "$actual_bal" != "$budget_wei" ]]; then
        fail B-262 "expected exact balance $budget_wei, got $actual_bal"; return
    fi

    local n; n=$(get_nonce $fresh_sender_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_sender_key --to $T1 --data 0x0262 \
        --payer $fresh_payer_addr --payer-key $fresh_payer_key \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok
    else fail B-262 "exact-budget sponsorship rejected: $out"; fi
}

# B-263: payer balance EXACTLY 1 wei BELOW budget → reject.
# Tightens the boundary above: validator must enforce strict inequality
# `balance >= cost` (not `>= cost - 1`).
test_B263() {
    run_case B-263 "payer balance = budget - 1 wei → reject (insufficient)" || return
    local fresh_payer_key; fresh_payer_key=$(fresh_secret_key B-263-payer)
    local fresh_payer_addr; fresh_payer_addr=$(cast wallet address --private-key $fresh_payer_key)
    local fresh_sender_key; fresh_sender_key=$(fresh_secret_key B-263-sender)
    local fresh_sender_addr; fresh_sender_addr=$(cast wallet address --private-key $fresh_sender_key)
    fund_account "$fresh_sender_addr" 0.001ether

    local budget_wei=200000000000000        # 2e14
    local short_wei=199999999999999          # budget - 1
    cast send --private-key "$KEY_S" --rpc-url "$RPC_URL" \
        "$fresh_payer_addr" --value "${short_wei}wei" >/dev/null 2>&1 || {
        fail B-263 "couldn't pre-fund payer"; return; }

    local n; n=$(get_nonce $fresh_sender_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_sender_key --to $T1 --data 0x0263 \
        --payer $fresh_payer_addr --payer-key $fresh_payer_key \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-263 "under-funded sponsorship accepted: $out"; fi
}

# B-264: 5 sponsored txs from 5 distinct senders, all paid by ADDR_P,
# all submitted in quick succession. All should succeed and all receipts
# must show payer == ADDR_P.
test_B264() {
    run_case B-264 "5 distinct senders, 1 shared payer → all succeed, payer field consistent" || return
    local payer_before; payer_before=$(_bal_wei "$ADDR_P")
    local hashes=()
    for i in 1 2 3 4 5; do
        local sk; sk=$(fresh_secret_key "B-264-$i")
        local sa; sa=$(cast wallet address --private-key $sk)
        # Senders need their own balance only for nonce/code; payer pays gas.
        # But auto-delegation requires sender balance to cover the empty-
        # account write — fund with a minimal dust amount.
        fund_account "$sa" 0.001ether
        local n; n=$(get_nonce $sa 0x0)
        local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
            --private-key $sk --to $T1 --data "0x0264$i" \
            --payer $ADDR_P --payer-key $KEY_P \
            --nonce-sequence $n --gas-limit 100000 \
            --max-fee-gwei 2 --priority-fee-gwei 1)
        if ! assert_status "$out" success; then
            fail B-264 "sender $i sponsorship failed: $out"; return
        fi
        local h; h=$(extract_tx_hash "$out")
        hashes+=("$h")
        local actual; actual=$(receipt_field "$h" payer | tr 'A-Z' 'a-z')
        if [[ "$actual" != "${ADDR_P,,}" ]]; then
            fail B-264 "sender $i: payer=$actual (expected ${ADDR_P,,})"; return
        fi
    done
    # Verify payer's balance dropped (sum of 5 gas costs > 0).
    local payer_after; payer_after=$(_bal_wei "$ADDR_P")
    if (( payer_after < payer_before )); then ok
    else fail B-264 "payer balance unchanged: $payer_before → $payer_after"; fi
}

# B-265: sponsored tx whose phase reverts. Per spec, payer still pays
# gas (gas_used * effectiveGasPrice). Assert: status=reverted,
# receipt.payer = ADDR_P, payer balance dropped.
test_B265() {
    run_case B-265 "sponsored tx reverts → payer still pays gas, receipt.payer set" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    local payer_before; payer_before=$(_bal_wei "$ADDR_P")
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T_REVERT --data 0x0265 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" reverted; then
        fail B-265 "expected reverted, got: $(classify_outcome "$out"); $out"; return
    fi
    local h; h=$(extract_tx_hash "$out")
    local actual; actual=$(receipt_field "$h" payer | tr 'A-Z' 'a-z')
    if [[ "$actual" != "${ADDR_P,,}" ]]; then
        fail B-265 "receipt.payer=$actual (expected ${ADDR_P,,})"; return
    fi
    local payer_after; payer_after=$(_bal_wei "$ADDR_P")
    # Payer should have paid SOMETHING — balance must strictly decrease.
    if (( payer_after < payer_before )); then ok
    else fail B-265 "payer balance unchanged on revert: $payer_before → $payer_after"; fi
}

# ── D. Sponsored entries (account_changes) ───────────────────────────────────

# B-266: sponsored auto-delegation. Fresh sender (no code, no balance);
# payer pays gas. After tx: sender's code = 0xef0100||DEFAULT_ACCOUNT,
# receipt.payer = ADDR_P.
test_B266() {
    run_case B-266 "sponsor an auto-delegation: payer pays, sender code set" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-266)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    # Do NOT fund — payer pays. (Auto-delegation may still need a tiny
    # bit for the account-creation-write; the spec treats this as part of
    # gas, paid by payer.)
    local n; n=$(get_nonce $fresh_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --to $T1 --data 0x0266 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" success; then
        fail B-266 "sponsored auto-delegation tx failed: $out"; return
    fi
    local h; h=$(extract_tx_hash "$out")
    local actual_payer; actual_payer=$(receipt_field "$h" payer | tr 'A-Z' 'a-z')
    if [[ "$actual_payer" != "${ADDR_P,,}" ]]; then
        fail B-266 "receipt.payer=$actual_payer (expected ${ADDR_P,,})"; return
    fi
    local code; code=$(get_code "$fresh_addr")
    local lower; lower=$(echo "$code" | tr 'A-Z' 'a-z')
    local target; target=$(echo "$DEFAULT_ACCOUNT" | tr 'A-Z' 'a-z' | sed 's/^0x//')
    local expected="ef0100${target}"
    if [[ "$lower" == "$expected" ]]; then ok
    else fail B-266 "sender code=$code expected=ef0100||$target"; fi
}

# B-267: sponsored config-change entry (fresh K1 EOA authorizes a new
# K1 owner). payer ≠ sender; the SDK's authorizer is the implicit EOA
# (same key as the EOA sender) so the config-change passes mempool
# auth. Assertions: success, receipt.payer = ADDR_P.
test_B267() {
    run_case B-267 "sponsor a config-change entry → success, payer paid gas" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-267)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    # Sender does NOT need balance: payer foots the bill.
    local n; n=$(get_nonce $fresh_addr 0x0)
    local k1=0x0000000000000000000000000000000000000001
    local x_lc; x_lc=$(echo "$ADDR_X" | tr 'A-Z' 'a-z' | sed 's/^0x//')
    local owner_id="0x${x_lc}000000000000000000000000"
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key \
        --config-authorize "${k1}:${owner_id}:0x00" \
        --config-sequence 0 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 300000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" success; then
        fail B-267 "sponsored config-change failed: $out"; return
    fi
    local h; h=$(extract_tx_hash "$out")
    local actual; actual=$(receipt_field "$h" payer | tr 'A-Z' 'a-z')
    if [[ "$actual" == "${ADDR_P,,}" ]]; then ok
    else fail B-267 "receipt.payer=$actual (expected ${ADDR_P,,})"; fi
}

# B-268: sponsored explicit-delegation entry (--delegation-target $T1
# rather than the implicit auto-delegation). Same as B-266 but with an
# explicit delegation entry; the SDK tags this as a Delegation
# account_change.
test_B268() {
    run_case B-268 "sponsor an explicit delegation entry → success, code = ef0100||T1" || return
    local fresh_key; fresh_key=$(fresh_secret_key B-268)
    local fresh_addr; fresh_addr=$(cast wallet address --private-key $fresh_key)
    local n; n=$(get_nonce $fresh_addr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $fresh_key --delegation-target $T1 \
        --payer $ADDR_P --payer-key $KEY_P \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" success; then
        fail B-268 "sponsored delegation failed: $out"; return
    fi
    local h; h=$(extract_tx_hash "$out")
    local actual_payer; actual_payer=$(receipt_field "$h" payer | tr 'A-Z' 'a-z')
    if [[ "$actual_payer" != "${ADDR_P,,}" ]]; then
        fail B-268 "receipt.payer=$actual_payer (expected ${ADDR_P,,})"; return
    fi
    local code; code=$(get_code "$fresh_addr")
    local lower; lower=$(echo "$code" | tr 'A-Z' 'a-z')
    local target; target=$(echo "$T1" | tr 'A-Z' 'a-z' | sed 's/^0x//')
    if [[ "$lower" == "ef0100${target}" ]]; then ok
    else fail B-268 "code=$code expected=ef0100||$target"; fi
}

# ── E. Payer-with-delegated-code ─────────────────────────────────────────────

# B-269: payer is itself a delegated AA account (its bytecode is
# ef0100||DEFAULT_ACCOUNT). The payer's role doesn't depend on its
# code, only on owner_config + balance. Sponsorship should still work.
test_B269() {
    run_case B-269 "payer with EIP-7702-style delegated code → sponsorship succeeds" || return
    # Bootstrap a delegated payer: fresh K1 EOA, run a vanilla AA tx to
    # auto-delegate, fund it, then sponsor a 2nd tx.
    local pkey; pkey=$(fresh_secret_key B-269-payer)
    local paddr; paddr=$(cast wallet address --private-key $pkey)
    fund_account "$paddr" 0.05ether
    # Step 1: vanilla AA tx → auto-delegates paddr.
    local n0; n0=$(get_nonce $paddr 0x0)
    "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $pkey --to $T1 --data 0x26900 \
        --nonce-sequence $n0 --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1 >/dev/null 2>&1
    sleep 1
    # Verify delegation indicator is present.
    local code; code=$(get_code "$paddr")
    if [[ -z "$code" || "$code" == "" ]]; then
        fail B-269 "payer didn't auto-delegate (code empty): $code"; return
    fi

    # Step 2: a separate fresh sender lets the delegated payer sponsor.
    local skey; skey=$(fresh_secret_key B-269-sender)
    local saddr; saddr=$(cast wallet address --private-key $skey)
    local n; n=$(get_nonce $saddr 0x0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $skey --to $T1 --data 0x0269 \
        --payer $paddr --payer-key $pkey \
        --nonce-sequence $n --gas-limit 200000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    local actual; actual=$(receipt_payer "$out")
    local paddr_lc; paddr_lc=$(echo "$paddr" | tr 'A-Z' 'a-z')
    if assert_status "$out" success && [[ "$actual" == "$paddr_lc" ]]; then ok
    else fail B-269 "payer=$actual (expected $paddr_lc); $out"; fi
}

# ── F. Payer auth envelope edges ─────────────────────────────────────────────

# B-270: payer_auth = exactly 20 bytes (only verifier, no signature).
# Hits the "data" portion check downstream — 0-byte K1 sig fails to
# ecrecover → reject.
test_B270() {
    run_case B-270 "payer_auth = 20 bytes (verifier only, no sig) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # K1 verifier = 0x0000…0001
    local pa=0x0000000000000000000000000000000000000001
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0270 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-270 "verifier-only payer_auth accepted: $out"; fi
}

# B-271: payer_auth with K1 verifier prefix but truncated 64-byte
# signature (one byte short of 65). K1 sig parser must reject.
test_B271() {
    run_case B-271 "payer_auth = K1 verifier + 64-byte sig (truncated) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # 20 verifier + 64 zeros = 84 bytes, missing v byte.
    local pa=0x0000000000000000000000000000000000000001$(printf '%0128d' 0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0271 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-271 "truncated payer sig accepted: $out"; fi
}

# B-272: payer_auth with unknown verifier address (no contract code).
# verify_auth_with_scope hits the custom-verifier path → call to a
# code-less account → reject (purity / verification gas / "no code").
test_B272() {
    run_case B-272 "payer_auth verifier = 0x...0099 (no contract) → reject" || return
    local n; n=$(get_nonce $ADDR_S 0x0)
    # Bogus verifier with 65 zero bytes as "data".
    local pa=0x0000000000000000000000000000000000000099$(printf '%0130d' 0)
    local out; out=$(verbose_run "$SDK_BIN" --rpc-url $RPC_URL --chain-id $CHAIN_ID \
        --private-key $KEY_S --to $T1 --data 0x0272 \
        --payer $ADDR_P --payer-auth-hex "$pa" \
        --nonce-sequence $n --gas-limit 100000 \
        --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" rejected; then ok
    else fail B-272 "bogus-verifier payer_auth accepted: $out"; fi
}

# ── G. Payer authorization scope ─────────────────────────────────────────────

# B-273: configured-owner sender that authorizes a P256 owner with scope
# = SENDER only (0x02), then attempts to use that owner in the payer
# slot. Per spec, payer requires PAYER scope (0x04). Mempool reject.
#
# This is structurally B-48's twin (boundary suite skips it pending
# --payer-p256-key). The same SDK gap applies — we mark it skip until
# the SDK exposes a P256 payer flag.
test_B273() {
    run_case B-273 "P256 owner with SENDER scope reused as payer → reject (scope mismatch)" || return
    skip B-273 "needs --payer-p256-key SDK flag (same as B-48)"
}

# ── Export ────────────────────────────────────────────────────────────────────

BOUNDARY_PAYER_TESTS=(
    test_B250 test_B251 test_B252 test_B253
    test_B254 test_B255 test_B256 test_B257 test_B258 test_B259 test_B260
    test_B261 test_B262 test_B263 test_B264 test_B265
    test_B266 test_B267 test_B268
    test_B269
    test_B270 test_B271 test_B272
    test_B273
)
