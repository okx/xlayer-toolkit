#!/bin/bash
#
# Predeploy the deterministic CREATE2 deploy factory into the L2 genesis alloc.
#
# DeployXlayerGaslessWhitelist.s.sol deploys the GaslessWhitelist impl + TransparentUpgradeableProxy
# THROUGH this factory (DEPLOY_FACTORY = 0xFaC897544659Fb136C064d5428947f5BC9cC1Fa2). Because the
# gasless contracts are now deployed AT RUNTIME (after the L2 is up) rather than seeded into genesis,
# the factory must already exist on-chain at genesis so the post-start deploy can call it.
#
# The factory is a pure stateless CREATE2 deployer (deploy(bytes,bytes32) / getAddress(bytes,bytes32)),
# so it only needs `code` injected — no storage. Address + runtime code come from
# config-op/factory-bytecode.json.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEVNET_DIR"

source .env

GENESIS="./config-op/genesis.json"
FACTORY_JSON="./config-op/factory-bytecode.json"

if [ ! -f "$GENESIS" ]; then
    echo " ❌ $GENESIS not found (run after op-deployer generates genesis.json)"
    exit 1
fi
if [ ! -f "$FACTORY_JSON" ]; then
    echo " ❌ $FACTORY_JSON not found"
    exit 1
fi

# Genesis alloc keys are lowercase, no 0x prefix.
FACTORY_ADDR_NO0X=$(jq -r '.address' "$FACTORY_JSON" | sed 's/^0x//' | tr 'A-F' 'a-f')
FACTORY_CODE=$(jq -r '.code' "$FACTORY_JSON")
if [ -z "$FACTORY_ADDR_NO0X" ] || [ -z "$FACTORY_CODE" ] || [ "$FACTORY_CODE" = "null" ]; then
    echo " ❌ could not read address/code from $FACTORY_JSON"
    exit 1
fi

echo "🔧 Injecting CREATE2 deploy factory into genesis: 0x${FACTORY_ADDR_NO0X}"

jq --arg addr "$FACTORY_ADDR_NO0X" --arg code "$FACTORY_CODE" \
   '.alloc[$addr] = { balance: "0x0", nonce: "0x1", code: $code }' \
   "$GENESIS" > "${GENESIS}.tmp" && mv "${GENESIS}.tmp" "$GENESIS"

echo " ✅ deploy factory injected into genesis.json"
