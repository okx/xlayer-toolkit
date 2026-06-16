#!/bin/bash
# Deploy + enable the XLayer GaslessWhitelist on the running L2.
#
# Gated entirely by CONTRACT_ALLOW_GASLESS. When true, this script (1) deploys the GaslessWhitelist
# (impl + TransparentUpgradeableProxy) via the CREATE2 factory by delegating to deploy-gasless.sh,
# then (2) turns it on via setGaslessEnabled(true). When false it is a no-op (contract left
# undeployed / gaslessEnabled=false).
#
# Per-target / per-token rules (setFullyGaslessTarget / setGaslessTransferToken) should be registered
# by yourself.
#
# Owner = GASLESS_WHITELIST_OWNER, whose key is RICH_L1_PRIVATE_KEY (referenced via env var, never
# inlined).
set -euo pipefail
source .env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${CONTRACT_ALLOW_GASLESS:-false}" != "true" ]; then
    echo "ℹ️  CONTRACT_ALLOW_GASLESS != true; leaving contract gaslessEnabled=false"
    exit 0
fi

# Step 1: deploy the contract (idempotent — deploy-gasless.sh skips if already deployed).
"$SCRIPT_DIR/deploy-gasless.sh"

# Step 2: turn it on via setGaslessEnabled(true).

# Deterministic CREATE2 address of the GaslessWhitelist proxy deployed by
# scripts/deploy-gasless.sh.
# MUST equal op-reth's compiled-in XLAYER_DEVNET_GASLESS_CONTRACT (chain id 195) for the gasless
# hook to query it. 
GASLESS_ADDR="${GASLESS_PROXY_ADDR:-0xA9092BC02e2000a3F8996D1991621E9A03Ef2dfE}"
RPC="${L2_RPC_URL:-http://localhost:8123}"
OWNER_KEY="${RICH_L1_PRIVATE_KEY:?RICH_L1_PRIVATE_KEY (gasless owner) must be set in .env}"

# Safety assert: the proxy MUST be at op-reth's compiled-in XLAYER_DEVNET_GASLESS_CONTRACT (chain
# 195). A mismatch means the gasless hook queries a different address and silently never fires.
EXPECTED_GASLESS_ADDR="0xA9092BC02e2000a3F8996D1991621E9A03Ef2dfE"
if [ "$(echo "$GASLESS_ADDR" | tr 'A-Z' 'a-z')" != "$(echo "$EXPECTED_GASLESS_ADDR" | tr 'A-Z' 'a-z')" ]; then
    echo " ❌ GASLESS_ADDR ($GASLESS_ADDR) != expected $EXPECTED_GASLESS_ADDR (op-reth XLAYER_DEVNET_GASLESS_CONTRACT)"
    exit 1
fi

echo "⏳ Waiting for L2 RPC ($RPC) ..."
for _ in $(seq 1 60); do
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
    sleep 2
done

# The contract must already be deployed (deploy-gasless.sh / step 1 above).
if [ "$(cast code "$GASLESS_ADDR" --rpc-url "$RPC")" = "0x" ]; then
    echo " ❌ no contract deployed at $GASLESS_ADDR; run scripts/deploy-gasless.sh first"
    exit 1
fi

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
