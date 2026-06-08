#!/bin/bash
# Enable XLayer gasless on the running L2.
#
# scripts/inject-gasless-predeploy.sh pre-deploys the new per-target GaslessWhitelist
# (contracts-bedrock src/L2/XlayerGaslessWhitelist.sol) into the L2 genesis but seeds ONLY the
# owner — `gaslessEnabled` starts false. This script turns it on by calling setGaslessEnabled(true)
# from the owner account once the L2 RPC is live.
#
# Per-target / per-token rules (setFullyGaslessTarget / setGaslessTransferToken) should be register by yourself.
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
GASLESS_ADDR="0x4200000000000000000000000000000000000700"
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

ENABLED=$(cast call "$GASLESS_ADDR" "gaslessEnabled()(bool)" --rpc-url "$RPC")
echo " ✅ gaslessEnabled() = ${ENABLED}"
if [ "$ENABLED" != "true" ]; then
    echo " ❌ failed to enable gasless"
    exit 1
fi
