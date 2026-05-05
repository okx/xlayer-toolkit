#!/usr/bin/env bash

_b300_owner_id() {
    local a
    a=$(echo "$1" | tr 'A-Z' 'a-z' | sed 's/^0x//')
    printf '0x%s000000000000000000000000\n' "$a"
}

_b300_wait_receipt() {
    local h="$1" b=""
    for _ in $(seq 1 20); do
        b=$(receipt_field "$h" blockNumber)
        [[ -n "$b" && "$b" != "null" ]] && return 0
        sleep 0.5
    done
    return 1
}

_b300_cast_send_hash() {
    cast send --private-key "$1" --rpc-url "$RPC_URL" "$2" --value 0 --json 2>/dev/null \
        | python3 -c "import json,sys; j=json.load(sys.stdin); print(j.get('transactionHash') or j.get('hash') or '')" 2>/dev/null
}

_b300_set_nonce_storage() {
    local account="$1" nonce_key="$2" value_hex="$3" inner slot resp
    inner=$(cast index address "$account" 1 2>/dev/null) || return 1
    slot=$(cast index bytes32 "$nonce_key" "$inner" 2>/dev/null) || return 1
    resp=$(rpc anvil_setStorageAt "[\"0x000000000000000000000000000000000000aa02\",\"$slot\",\"$value_hex\"]" 2>/dev/null || true)
    if grep -q '"result"' <<<"$resp"; then return 0; fi
    resp=$(rpc evm_setAccountStorageAt "[\"0x000000000000000000000000000000000000aa02\",\"$slot\",\"$value_hex\"]" 2>/dev/null || true)
    grep -q '"result"' <<<"$resp"
}

test_B300() {
    run_case B-300 "SENDER-only owner used as PAYER -> reject" || return
    # validation.rs:362-365 enforces PAYER scope; types.rs:106-111 defines scope bits.
    local payer_key payer_addr owner_key owner_addr owner_id k1 n out1 out2
    payer_key=$(fresh_secret_key B-300-payer); payer_addr=$(cast wallet address --private-key "$payer_key")
    owner_key=$(fresh_secret_key B-300-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    fund_account "$payer_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$payer_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$payer_key" --config-authorize "${k1}:${owner_id}:0x02" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-300 "setup: $out1"; return; fi
    n=$(get_nonce "$ADDR_S" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$KEY_S" --to "$T1" --data 0xb300 --payer "$payer_addr" --payer-key "$owner_key" --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" rejected; then ok; else fail B-300 "expected PAYER scope reject; got: $out2"; fi
}

test_B301() {
    run_case B-301 "PAYER-only owner used as SENDER -> reject" || return
    # validation.rs:333-336 enforces SENDER scope; types.rs:106-111 defines scope bits.
    local acct_key acct_addr owner_key owner_addr owner_id k1 n out1 out2
    acct_key=$(fresh_secret_key B-301-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    owner_key=$(fresh_secret_key B-301-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    fund_account "$acct_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${owner_id}:0x04" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-301 "setup: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$owner_key" --from "$acct_addr" --to "$T1" --data 0xb301 --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" rejected; then ok; else fail B-301 "expected SENDER scope reject; got: $out2"; fi
}

test_B302() {
    run_case B-302 "CONFIG-only owner used as SENDER -> reject" || return
    # validation.rs:333-336 enforces SENDER scope; constants.rs:83 defines CONFIG=0x08.
    local acct_key acct_addr owner_key owner_addr owner_id k1 n out1 out2
    acct_key=$(fresh_secret_key B-302-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    owner_key=$(fresh_secret_key B-302-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    fund_account "$acct_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${owner_id}:0x08" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-302 "setup: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$owner_key" --from "$acct_addr" --to "$T1" --data 0xb302 --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" rejected; then ok; else fail B-302 "expected SENDER scope reject; got: $out2"; fi
}

test_B303() {
    run_case B-303 "all-bits owner (0x0E) used as SENDER -> success" || return
    # validation.rs:333-337 accepts configured SENDER scope; types.rs:106-111 defines 0x0E bits.
    local acct_key acct_addr owner_key owner_addr owner_id k1 n out1 out2
    acct_key=$(fresh_secret_key B-303-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    owner_key=$(fresh_secret_key B-303-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    fund_account "$acct_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${owner_id}:0x0e" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-303 "setup: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$owner_key" --from "$acct_addr" --to "$T1" --data 0xb303 --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" success; then ok; else fail B-303 "$out2"; fi
}

test_B304() {
    run_case B-304 "all-bits owner (0x0E) used as PAYER -> success" || return
    # validation.rs:362-366 accepts configured PAYER scope; types.rs:106-111 defines 0x0E bits.
    local payer_key payer_addr owner_key owner_addr owner_id k1 n out1 out2 actual
    payer_key=$(fresh_secret_key B-304-payer); payer_addr=$(cast wallet address --private-key "$payer_key")
    owner_key=$(fresh_secret_key B-304-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    fund_account "$payer_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$payer_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$payer_key" --config-authorize "${k1}:${owner_id}:0x0e" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-304 "setup: $out1"; return; fi
    n=$(get_nonce "$ADDR_S" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$KEY_S" --to "$T1" --data 0xb304 --payer "$payer_addr" --payer-key "$owner_key" --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    actual=$(receipt_payer "$out2")
    if assert_status "$out2" success && [[ "$actual" == "${payer_addr,,}" ]]; then ok; else fail B-304 "payer=$actual; $out2"; fi
}

test_B305() {
    run_case B-305 "all-bits owner (0x0E) authorizes CONFIG change -> success" || return
    # handler_aa_helpers.rs:610-619 requires CONFIG scope for authorizer chain.
    local acct_key acct_addr owner_key owner_addr next_key next_addr owner_id next_owner_id k1 n out1 out2
    acct_key=$(fresh_secret_key B-305-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    owner_key=$(fresh_secret_key B-305-owner); owner_addr=$(cast wallet address --private-key "$owner_key")
    next_key=$(fresh_secret_key B-305-next); next_addr=$(cast wallet address --private-key "$next_key")
    fund_account "$acct_addr" 0.05ether
    owner_id=$(_b300_owner_id "$owner_addr"); next_owner_id=$(_b300_owner_id "$next_addr"); k1=0x0000000000000000000000000000000000000001
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${owner_id}:0x0e" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-305 "setup: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --authorizer-key "$owner_key" --config-authorize "${k1}:${next_owner_id}:0x02" --config-sequence 1 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" success; then ok; else fail B-305 "$out2"; fi
}

test_B306() {
    run_case B-306 "multichain config sequence=0 and local sequence=0 both succeed" || return
    # accessors.rs:118-129 separates chain_id==0 from local sequence; handler_aa_helpers.rs:432-457 checks both lanes.
    local acct_key acct_addr k1 x_owner p_owner n out1 out2
    acct_key=$(fresh_secret_key B-306-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.05ether
    k1=0x0000000000000000000000000000000000000001; x_owner=$(_b300_owner_id "$ADDR_X"); p_owner=$(_b300_owner_id "$ADDR_P")
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-chain-id 0 --config-authorize "${k1}:${x_owner}:0x02" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-306 "multichain: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-chain-id "$CHAIN_ID" --config-authorize "${k1}:${p_owner}:0x02" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" success; then ok; else fail B-306 "local: $out2"; fi
}

test_B307() {
    run_case B-307 "same config channel sequence=0 then sequence=1 -> both succeed" || return
    # validation.rs:402-408 and handler_aa_helpers.rs:438-457 require exact config sequence progression.
    local acct_key acct_addr k1 x_owner p_owner n out1 out2
    acct_key=$(fresh_secret_key B-307-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.05ether
    k1=0x0000000000000000000000000000000000000001; x_owner=$(_b300_owner_id "$ADDR_X"); p_owner=$(_b300_owner_id "$ADDR_P")
    n=$(get_nonce "$acct_addr" 0x0)
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${x_owner}:0x02" --config-sequence 0 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-307 "seq0: $out1"; return; fi
    n=$(get_nonce "$acct_addr" 0x0)
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${p_owner}:0x02" --config-sequence 1 --nonce-sequence "$n" --gas-limit 250000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out2" success; then ok; else fail B-307 "seq1: $out2"; fi
}

test_B308() {
    run_case B-308 "2D nonce near u64::MAX: max-1 then max succeed, wrap to 0 rejects" || return
    # handler.rs:316-350 validates and increments nonce_sequence; storage.rs:97-112 defines nonce slot derivation.
    local acct_key acct_addr key max_minus max value out1 out2 out3
    acct_key=$(fresh_secret_key B-308-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.05ether
    key=0xbeef8130; max_minus=18446744073709551614; max=18446744073709551615; value=0x000000000000000000000000000000000000000000000000fffffffffffffffe
    if ! _b300_set_nonce_storage "$acct_addr" "$key" "$value"; then skip B-308 "dev RPC does not expose anvil_setStorageAt/evm_setAccountStorageAt for nonce setup"; return; fi
    out1=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --to "$T1" --data 0xb30801 --nonce-key "$key" --nonce-sequence "$max_minus" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out1" success; then fail B-308 "max-1: $out1"; return; fi
    out2=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --to "$T1" --data 0xb30802 --nonce-key "$key" --nonce-sequence "$max" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out2" success; then fail B-308 "max: $out2"; return; fi
    out3=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --to "$T1" --data 0xb30803 --nonce-key "$key" --nonce-sequence 0 --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out3" rejected; then ok; else fail B-308 "wrap accepted unexpectedly: $out3"; fi
}

test_B309() {
    run_case B-309 "self-revoke implicit EOA + register new SENDER owner signed by new owner -> success" || return
    # handler.rs:630-641 validates account changes before sender auth; transaction/eip8130.rs:178 notes resulting owner state.
    local acct_key acct_addr new_key new_addr new_owner_id k1 n out
    acct_key=$(fresh_secret_key B-309-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    new_key=$(fresh_secret_key B-309-new); new_addr=$(cast wallet address --private-key "$new_key")
    fund_account "$acct_addr" 0.05ether
    new_owner_id=$(_b300_owner_id "$new_addr"); k1=0x0000000000000000000000000000000000000001; n=$(get_nonce "$acct_addr" 0x0)
    out=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$new_key" --from "$acct_addr" --authorizer-key "$acct_key" --revoke-eoa-owner --config-authorize "${k1}:${new_owner_id}:0x02" --config-sequence 0 --nonce-sequence "$n" --gas-limit 300000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok; else fail B-309 "$out"; fi
}

test_B310() {
    run_case B-310 "NONCE_KEY_MAX nonce-free + config-change in same tx -> success" || return
    # validation.rs:159-165 allows nonce-free with seq=0 and expiry; handler.rs:625-641 validates config changes independently.
    local acct_key acct_addr x_owner k1 exp out
    acct_key=$(fresh_secret_key B-310-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.05ether
    x_owner=$(_b300_owner_id "$ADDR_X"); k1=0x0000000000000000000000000000000000000001; exp=$(( $(now_secs) + 5 ))
    out=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --config-authorize "${k1}:${x_owner}:0x02" --config-sequence 0 --nonce-free --expiry "$exp" --gas-limit 300000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if assert_status "$out" success; then ok; else fail B-310 "$out"; fi
}

test_B311() {
    run_case B-311 "delegation target = sender (self-delegation) -> indicator written" || return
    # types.rs:244-251 allows any Delegation target; handler.rs:451-470 writes EIP-7702 code.
    local acct_key acct_addr n out code expected target
    acct_key=$(fresh_secret_key B-311-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.03ether
    n=$(get_nonce "$acct_addr" 0x0)
    out=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --delegation-target "$acct_addr" --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" success; then fail B-311 "tx: $out"; return; fi
    code=$(get_code "$acct_addr" | tr 'A-Z' 'a-z'); target=$(echo "$acct_addr" | tr 'A-Z' 'a-z' | sed 's/^0x//'); expected="ef0100${target}"
    if [[ "$code" == "$expected" ]]; then ok; else fail B-311 "code=$code expected=$expected"; fi
}

test_B312() {
    run_case B-312 "delegation target = NonceManager precompile (0x...aa02) -> indicator written" || return
    # predeploys.rs:68-70 defines NonceManager; handler.rs:451-470 permits delegation indicator targets.
    local acct_key acct_addr target n out code expected target_lc
    acct_key=$(fresh_secret_key B-312-acct); acct_addr=$(cast wallet address --private-key "$acct_key")
    fund_account "$acct_addr" 0.03ether
    target=0x000000000000000000000000000000000000aa02; n=$(get_nonce "$acct_addr" 0x0)
    out=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$acct_key" --delegation-target "$target" --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1)
    if ! assert_status "$out" success; then fail B-312 "tx: $out"; return; fi
    code=$(get_code "$acct_addr" | tr 'A-Z' 'a-z'); target_lc=$(echo "$target" | tr 'A-Z' 'a-z' | sed 's/^0x//'); expected="ef0100${target_lc}"
    if [[ "$code" == "$expected" ]]; then ok; else fail B-312 "code=$code expected=$expected"; fi
}

test_B313() {
    run_case B-313 "vanilla EIP-1559 receipt has no AA payer/phaseStatuses fields" || return
    # rpc-types/receipt.rs:25-40 flattens EIP-8130 receipt fields only for AA receipts.
    local hash payer ps ty
    hash=$(_b300_cast_send_hash "$KEY_S" "$T1")
    [[ -z "$hash" ]] && { fail B-313 "cast send did not return a transaction hash"; return; }
    _b300_wait_receipt "$hash" || { fail B-313 "receipt not available for $hash"; return; }
    payer=$(receipt_field "$hash" payer); ps=$(receipt_field "$hash" phaseStatuses); ty=$(receipt_field "$hash" type)
    if [[ -z "$payer" && -z "$ps" && ( "$ty" == "0x2" || "$ty" == "0x02" ) ]]; then ok; else fail B-313 "type=$ty payer=$payer phaseStatuses=$ps"; fi
}

test_B314() {
    run_case B-314 "eth_sendRawTransaction interleaves EIP-1559 + EIP-8130 submissions" || return
    # handler.rs:102-109 gates only AA tx type; rpc-types/receipt.rs:25-40 keeps receipt fields type-specific.
    local n dry raw aa_resp aa_hash v1 v2 aa_status v1_status v2_status
    n=$(get_nonce "$ADDR_S" 0x0)
    dry=$(verbose_run "$SDK_BIN" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --private-key "$KEY_S" --to "$T1" --data 0xb314 --nonce-sequence "$n" --gas-limit 120000 --max-fee-gwei 2 --priority-fee-gwei 1 --dry-run)
    raw=$(extract_dry_run_field "$dry" encoded)
    [[ -z "$raw" ]] && { fail B-314 "dry-run did not emit encoded tx: $dry"; return; }
    v1=$(_b300_cast_send_hash "$KEY_X" "$T2"); [[ -z "$v1" ]] && { fail B-314 "first EIP-1559 send failed"; return; }
    aa_resp=$(rpc eth_sendRawTransaction "[\"$raw\"]"); aa_hash=$(python3 -c "import json,sys; print(json.loads('''$aa_resp''').get('result',''))" 2>/dev/null)
    [[ -z "$aa_hash" ]] && { fail B-314 "AA raw send failed: $aa_resp"; return; }
    v2=$(_b300_cast_send_hash "$KEY_X" "$T3"); [[ -z "$v2" ]] && { fail B-314 "second EIP-1559 send failed"; return; }
    _b300_wait_receipt "$aa_hash" || { fail B-314 "AA receipt missing: $aa_hash"; return; }
    aa_status=$(receipt_field "$aa_hash" status); v1_status=$(receipt_field "$v1" status); v2_status=$(receipt_field "$v2" status)
    if [[ "$aa_status" == "0x1" && "$v1_status" == "0x1" && "$v2_status" == "0x1" ]]; then ok; else fail B-314 "aa=$aa_status v1=$v1_status v2=$v2_status"; fi
}

test_B315() {
    run_case B-315 "account creation entry (type 0x00) boundary coverage" || return
    # types.rs:188-200 defines Create as account_changes type 0x00; SDK currently exposes no CREATE2 args.
    skip B-315 "SDK has no account creation / CREATE2 CLI surface"
}

test_B316() {
    run_case B-316 "account lock blocks config changes" || return
    # handler_aa_helpers.rs:414-425 rejects config changes while AccountConfiguration lock is active.
    skip B-316 "SDK has no account lock/unlock CLI surface"
}

test_B317() {
    run_case B-317 "two config changes in one tx chain seq=0 then seq=1" || return
    # handler_aa_helpers.rs:432-457 supports in-tx sequence chaining, but SDK emits at most one ConfigChangeEntry.
    skip B-317 "SDK can only build one config-change entry per transaction"
}

BOUNDARY_SPEC_TESTS=(
    test_B300
    test_B301
    test_B302
    test_B303
    test_B304
    test_B305
    test_B306
    test_B307
    test_B308
    test_B309
    test_B310
    test_B311
    test_B312
    test_B313
    test_B314
    test_B315
    test_B316
    test_B317
)
