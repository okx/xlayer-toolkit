#!/bin/bash
#
# Rebuild + upgrade the XLayer GaslessWhitelist implementation behind the live devnet proxy.
#
# Topology (OZ v5 TransparentUpgradeableProxy, deployed at runtime by deploy-gasless.sh):
#   PROXY      -> deterministic CREATE2 address (== op-reth XLAYER_DEVNET_GASLESS_CONTRACT). All
#                 logic state lives here.
#   PROXYADMIN -> the proxy's auto-deployed ProxyAdmin contract (read from the EIP-1967 admin slot),
#                 owned by GASLESS_WHITELIST_OWNER.
#
# OZ v5 differs from the old OP Stack Proxy model:
#   - The proxy exposes NO admin()/implementation()/upgradeTo() getters; only the ProxyAdmin can
#     upgrade, via ProxyAdmin.upgradeAndCall(proxy, newImpl, data).
#   - The upgrade is signed by the PROXYADMIN OWNER (GASLESS_WHITELIST_OWNER), not a separate admin
#     EOA. We read impl/admin from the EIP-1967 storage slots via `cast storage`.
#
# This script:
#   1. forge build src/L2/XlayerGaslessWhitelist.sol
#   2. forge create the new GaslessWhitelist implementation onto L2 (signed by the owner)
#   3. ProxyAdmin.upgradeAndCall(proxy, newImpl, data) from the owner key
#      (data = empty, or `cast calldata $REINIT_SIG` to re-initialize atomically)
#   4. verify the EIP-1967 implementation slot now points at the new impl
#
# Usage (run from the devnet root):
#   ./scripts/upgrade-gasless-impl.sh
#   REINIT_SIG='reinitializeV2()' ./scripts/upgrade-gasless-impl.sh   # upgrade + re-init atomically
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEVNET_DIR"

source .env

# --- config -----------------------------------------------------------------
# Deterministic CREATE2 proxy address (see deploy-gasless.sh / enable-gasless.sh).
GASLESS_PROXY="${GASLESS_PROXY_ADDR:-0xA9092BC02e2000a3F8996D1991621E9A03Ef2dfE}"
RPC="${L2_RPC_URL}"

# EIP-1967 reserved slots.
IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

# The ProxyAdmin owner key (== GASLESS_WHITELIST_OWNER). It is funded on L2 genesis (RICH_L1).
OWNER_KEY="${GASLESS_DEPLOYER_KEY:-${RICH_L1_PRIVATE_KEY:?RICH_L1_PRIVATE_KEY (proxy admin owner) must be set in .env}}"

BEDROCK_DIR="${OP_STACK_LOCAL_DIRECTORY:?OP_STACK_LOCAL_DIRECTORY must be set in .env}/packages/contracts-bedrock"
IMPL_SRC="src/L2/XlayerGaslessWhitelist.sol"
IMPL_CONTRACT="GaslessWhitelist"
REINIT_SIG="${REINIT_SIG:-}"

slot_to_addr() { echo "0x${1: -40}"; }   # last 20 bytes of a 32-byte slot value

# --- 0. preflight: RPC live + resolve ProxyAdmin + verify owner key --------
echo "⏳ Waiting for L2 RPC ($RPC) ..."
for _ in $(seq 1 60); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 2
done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { echo " ❌ L2 RPC $RPC not reachable"; exit 1; }

[ "$(cast code "$GASLESS_PROXY" --rpc-url "$RPC")" != "0x" ] \
    || { echo " ❌ no proxy code at $GASLESS_PROXY (run deploy-gasless.sh first)"; exit 1; }

PROXY_ADMIN="$(slot_to_addr "$(cast storage "$GASLESS_PROXY" "$ADMIN_SLOT" --rpc-url "$RPC")")"
echo "🔐 ProxyAdmin (from EIP-1967 admin slot): $PROXY_ADMIN"

OWNER_ADDR="$(cast wallet address --private-key "$OWNER_KEY")"
ON_CHAIN_OWNER="$(cast call "$PROXY_ADMIN" "owner()(address)" --rpc-url "$RPC")"
if [ "$(echo "$ON_CHAIN_OWNER" | tr 'A-Z' 'a-z')" != "$(echo "$OWNER_ADDR" | tr 'A-Z' 'a-z')" ]; then
    echo " ❌ key mismatch: ProxyAdmin.owner() = $ON_CHAIN_OWNER, but OWNER_KEY is $OWNER_ADDR"
    echo "      only the ProxyAdmin owner can upgrade; set GASLESS_DEPLOYER_KEY/RICH_L1_PRIVATE_KEY accordingly."
    exit 1
fi
echo " ℹ️  current implementation = $(slot_to_addr "$(cast storage "$GASLESS_PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")"

# --- 1. rebuild the new implementation -------------------------------------
echo "🔧 forge build $IMPL_SRC ..."
( cd "$BEDROCK_DIR" && forge build "$IMPL_SRC" ) \
    || { echo " ❌ forge build of $IMPL_SRC failed"; exit 1; }

# --- 2. deploy the new implementation onto L2 ------------------------------
echo "🚀 Deploying new $IMPL_CONTRACT implementation ..."
CREATE_OUT="$(cd "$BEDROCK_DIR" && forge create "$IMPL_SRC:$IMPL_CONTRACT" \
    --rpc-url "$RPC" --private-key "$OWNER_KEY" --broadcast 2>&1)" \
    || { echo "$CREATE_OUT"; echo " ❌ forge create failed"; exit 1; }

NEW_IMPL="$(echo "$CREATE_OUT" | grep -oiE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oiE '0x[0-9a-fA-F]{40}' | tail -n1)"
[ -n "$NEW_IMPL" ] || { echo "$CREATE_OUT"; echo " ❌ could not parse 'Deployed to:' address"; exit 1; }
echo " ✅ new impl deployed at $NEW_IMPL"

# --- 3. upgrade through the ProxyAdmin (owner-signed) ----------------------
if [ -n "$REINIT_SIG" ]; then
    DATA="$(cast calldata "$REINIT_SIG")"
    echo "🔁 ProxyAdmin.upgradeAndCall($GASLESS_PROXY, $NEW_IMPL, $REINIT_SIG) ..."
else
    DATA="0x"
    echo "🔁 ProxyAdmin.upgradeAndCall($GASLESS_PROXY, $NEW_IMPL, 0x) ..."
fi
cast send "$PROXY_ADMIN" "upgradeAndCall(address,address,bytes)" "$GASLESS_PROXY" "$NEW_IMPL" "$DATA" \
    --rpc-url "$RPC" --private-key "$OWNER_KEY" >/dev/null

# --- 4. verify via the EIP-1967 implementation slot ------------------------
ON_CHAIN_IMPL="$(slot_to_addr "$(cast storage "$GASLESS_PROXY" "$IMPL_SLOT" --rpc-url "$RPC")")"
if [ "$(echo "$ON_CHAIN_IMPL" | tr 'A-Z' 'a-z')" != "$(echo "$NEW_IMPL" | tr 'A-Z' 'a-z')" ]; then
    echo " ❌ upgrade verification failed: implementation slot = $ON_CHAIN_IMPL, expected $NEW_IMPL"
    exit 1
fi

echo " ✅ proxy $GASLESS_PROXY now delegates to $ON_CHAIN_IMPL"
echo " ℹ️  gaslessEnabled() = $(cast call "$GASLESS_PROXY" "gaslessEnabled()(bool)" --rpc-url "$RPC")"
echo "🎉 gasless implementation upgrade complete"
