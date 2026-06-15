#!/bin/bash
#
# Deploy the XLayer GaslessWhitelist (impl + TransparentUpgradeableProxy) onto the RUNNING L2.
#
# Ownership model (OpenZeppelin v5.0.2 TransparentUpgradeableProxy):
#   - The proxy auto-deploys its own ProxyAdmin, owned by `initialOwner`.
#   - We pass OWNER = GASLESS_OWNER for BOTH the ProxyAdmin owner AND the GaslessWhitelist owner.
#   - The broadcaster MUST be GASLESS_OWNER: the proxy is deployed with empty init data and
#     initialize() is then called through the proxy, which asserts msg.sender == ProxyAdmin owner.
# op-reth's gasless hook reads a compiled-in address
# (XLAYER_DEVNET_GASLESS_CONTRACT); that constant MUST equal the proxy address printed below for
# gasless to actually trigger.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEVNET_DIR"

source .env

RPC="${L2_RPC_URL}"
BEDROCK_DIR="${OP_STACK_LOCAL_DIRECTORY:?OP_STACK_LOCAL_DIRECTORY must be set in .env}/packages/contracts-bedrock"
DEPLOY_SCRIPT="scripts/deploy/DeployXlayerGaslessWhitelist.s.sol:DeployGaslessWhitelist"
DEPLOY_FACTORY="0xFaC897544659Fb136C064d5428947f5BC9cC1Fa2"

# OWNER becomes both the ProxyAdmin owner and the GaslessWhitelist owner.
OWNER="${GASLESS_WHITELIST_OWNER:-0x14dC79964da2C08b23698B3D3cc7Ca32193d9955}"
# Broadcaster == OWNER (initialize() asserts msg.sender == ProxyAdmin owner). The owner's key is
# RICH_L1_PRIVATE_KEY (funded on L2 genesis).
OWNER_KEY="${GASLESS_DEPLOYER_KEY:-${RICH_L1_PRIVATE_KEY:?RICH_L1_PRIVATE_KEY (gasless owner) must be set in .env}}"

# --- preflight: L2 RPC live + factory present ------------------------------
echo "⏳ Waiting for L2 RPC ($RPC) ..."
for _ in $(seq 1 60); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 2
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { echo " ❌ L2 RPC $RPC not reachable"; exit 1; }

if [ "$(cast code "$DEPLOY_FACTORY" --rpc-url "$RPC")" = "0x" ]; then
    echo " ❌ deploy factory $DEPLOY_FACTORY has no code on L2."
    echo "      scripts/inject-deploy-factory.sh must seed it into genesis (run at op-init)."
    exit 1
fi

# Idempotent: if the deterministic proxy is already deployed, skip — re-running the CREATE2 deploy
# would revert on address collision. Lets enable-gasless.sh re-invoke this safely.
EXPECTED_GASLESS_ADDR="${GASLESS_PROXY_ADDR:-0x70CA900387FCD29C2A71d511F10E5c961dc9363F}"
if [ "$(cast code "$EXPECTED_GASLESS_ADDR" --rpc-url "$RPC")" != "0x" ]; then
    echo " ✅ GaslessWhitelist proxy already deployed at $EXPECTED_GASLESS_ADDR; skipping deploy."
    echo "      GaslessWhitelist proxy: $EXPECTED_GASLESS_ADDR"
    exit 0
fi

OWNER_ADDR="$(cast wallet address --private-key "$OWNER_KEY")"
if [ "$(echo "$OWNER_ADDR" | tr 'A-Z' 'a-z')" != "$(echo "$OWNER" | tr 'A-Z' 'a-z')" ]; then
    echo " ❌ broadcaster ($OWNER_ADDR) != OWNER ($OWNER); initialize() would revert."
    echo "      GASLESS_WHITELIST_OWNER must match the key in GASLESS_DEPLOYER_KEY/RICH_L1_PRIVATE_KEY."
    exit 1
fi

echo "🚀 Deploying GaslessWhitelist (impl + proxy) via factory, owner=${OWNER} ..."
DEPLOY_OUT="$(cd "$BEDROCK_DIR" && OWNER="$OWNER" forge script "$DEPLOY_SCRIPT" \
    --rpc-url "$RPC" --broadcast --private-key "$OWNER_KEY" 2>&1)" \
    || { echo "$DEPLOY_OUT"; echo " ❌ forge script deploy failed"; exit 1; }

GASLESS_PROXY="$(echo "$DEPLOY_OUT" | grep -iE "GaslessWhitelist proxy:" | grep -oiE '0x[0-9a-fA-F]{40}' | tail -n1)"
GASLESS_IMPL="$(echo "$DEPLOY_OUT" | grep -iE "GaslessWhitelist implementation:" | grep -oiE '0x[0-9a-fA-F]{40}' | tail -n1)"
PROXY_ADMIN="$(echo "$DEPLOY_OUT" | grep -iE "^\s*ProxyAdmin:" | grep -oiE '0x[0-9a-fA-F]{40}' | tail -n1)"
if [ -z "$GASLESS_PROXY" ]; then
    echo "$DEPLOY_OUT"
    echo " ❌ could not parse deployed proxy address from forge output"
    exit 1
fi

echo " ✅ GaslessWhitelist deployed:"
echo "      proxy       = ${GASLESS_PROXY}   (this is the gasless whitelist address)"
echo "      implementation = ${GASLESS_IMPL}"
echo "      proxyAdmin  = ${PROXY_ADMIN}      (owner = ${OWNER})"
echo "      whitelistOwner = ${OWNER}"
echo " ⚠️  op-reth's XLAYER_DEVNET_GASLESS_CONTRACT (chain 195) MUST equal ${GASLESS_PROXY}"
echo "      for the gasless hook to query this contract."
