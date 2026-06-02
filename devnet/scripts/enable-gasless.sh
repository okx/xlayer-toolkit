#!/bin/bash
# Enable XLayer gasless on the running L2.
#
# scripts/inject-gasless-predeploy.sh pre-deploys the GaslessWhitelist contract into the L2 genesis
# but seeds ONLY the owner — `isGaslessEnabled` starts false. This script turns it on by calling
# setGaslessEnabled(true) from the owner account once the L2 RPC is live, so zero-gas-price
# (gasless) transactions are actually accepted by the mempool / executor.
#
# Owner = GASLESS_WHITELIST_OWNER, whose key is RICH_L1_PRIVATE_KEY (referenced via env var, never
# inlined). No-op unless ENABLE_GASLESS=true.
set -euo pipefail
source .env

if [ "${ENABLE_GASLESS:-false}" != "true" ]; then
    echo "ℹ️  ENABLE_GASLESS != true; skipping gasless enable"
    exit 0
fi

export PATH="$HOME/.foundry/bin:$PATH"

# XLAYER_DEVNET_GASLESS_CONTRACT (chain id 195) — see deps/optimism .../xlayer_gasless_contract.rs
GASLESS_ADDR="0x0000000000000000000000000000000000009999"
RPC="${L2_RPC_URL:-http://localhost:8123}"
OWNER_KEY="${RICH_L1_PRIVATE_KEY:?RICH_L1_PRIVATE_KEY (gasless owner) must be set in .env}"

echo "⏳ Waiting for L2 RPC ($RPC) ..."
for _ in $(seq 1 60); do
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
    sleep 2
done

echo "🔧 Enabling gasless: setGaslessEnabled(true) on ${GASLESS_ADDR} ..."
cast send "$GASLESS_ADDR" "setGaslessEnabled(bool)" true \
    --rpc-url "$RPC" \
    --private-key "$OWNER_KEY" >/dev/null

# The predeploy injects runtime bytecode directly, so the constructor never runs and
# `defaultGasLimit` (the per-tx gasless gas allowance) is 0 — which would reject every
# gasless tx with "exceeds max transaction gas limit". Set a generous allowance.
GASLESS_GAS_ALLOWANCE="${GASLESS_GAS_ALLOWANCE:-30000000}"
echo "🔧 Setting gasless gas allowance: setAllowance(${GASLESS_GAS_ALLOWANCE}) ..."
cast send "$GASLESS_ADDR" "setAllowance(uint64)" "$GASLESS_GAS_ALLOWANCE" \
    --rpc-url "$RPC" \
    --private-key "$OWNER_KEY" >/dev/null
echo " ✅ defaultGasLimit() = $(cast call "$GASLESS_ADDR" "defaultGasLimit()(uint64)" --rpc-url "$RPC")"

ENABLED=$(cast call "$GASLESS_ADDR" "isGaslessEnabled()(bool)" --rpc-url "$RPC")
echo " ✅ isGaslessEnabled() = ${ENABLED}"
if [ "$ENABLED" != "true" ]; then
    echo " ❌ failed to enable gasless"
    exit 1
fi
