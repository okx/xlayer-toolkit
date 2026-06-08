#!/bin/bash
#
# Pre-deploy the XLayer GaslessWhitelist contract into the L2 genesis alloc at
# the fixed devnet address op-reth expects.
#
# op-reth (chain id 195 / devnet) evaluates gasless eligibility by issuing view
# system-calls to XLAYER_DEVNET_GASLESS_CONTRACT =
#   0x4200000000000000000000000000000000000700
# so the contract code MUST already exist at that exact address at genesis.
#
# This injects the newer per-target GaslessWhitelist from contracts-bedrock
# (src/L2/XlayerGaslessWhitelist.sol). It is an upgradeable (Initializable +
# OwnableUpgradeable) contract, so its storage layout is NOT slot-0-packed:
#   slot 51  (0x33)  = _owner        (address, left-padded to 32 bytes)
#   slot 105 (0x69)  = gaslessEnabled (bool)
# We seed only `_owner`; gaslessEnabled stays false and is turned on later via
# setGaslessEnabled(true) from the owner account (enable-gasless.sh, the e2e
# tests, or adventure), so the contract writes its own rule slots.
set -e

source .env

GENESIS="./config-op/genesis.json"
GASLESS_ADDR_NO0X="4200000000000000000000000000000000000700"
GASLESS_OWNER="${GASLESS_WHITELIST_OWNER:-0x14dC79964da2C08b23698B3D3cc7Ca32193d9955}"

# The optimism monorepo that ships the GaslessWhitelist contract is always at
# OP_STACK_LOCAL_DIRECTORY (whether it's a standalone checkout or vendored under
# op-reth/deps/optimism), so derive the artifact path straight from it. The
# contracts-bedrock foundry project writes artifacts under `forge-artifacts/`.
BEDROCK_DIR="$OP_STACK_LOCAL_DIRECTORY/packages/contracts-bedrock"
ARTIFACT="$BEDROCK_DIR/forge-artifacts/XlayerGaslessWhitelist.sol/GaslessWhitelist.json"

if [ ! -f "$GENESIS" ]; then
    echo " ❌ $GENESIS not found (run after op-deployer generates genesis.json)"
    exit 1
fi

if [ ! -f "$ARTIFACT" ]; then
    echo " 🔧 GaslessWhitelist artifact missing; building it with forge ..."
    export PATH="$HOME/.foundry/bin:$PATH"
    # Build only the target source so we reuse the bedrock compile cache (a full
    # `forge clean` would force a multi-minute rebuild of contracts-bedrock).
    ( cd "$BEDROCK_DIR" && forge build src/L2/XlayerGaslessWhitelist.sol ) \
        || { echo " ❌ forge build of GaslessWhitelist failed"; exit 1; }
fi

if [ ! -f "$ARTIFACT" ]; then
    echo " ❌ GaslessWhitelist artifact still not found at:"
    echo "      $ARTIFACT"
    exit 1
fi

CODE=$(jq -r '.deployedBytecode.object' "$ARTIFACT")
if [ -z "$CODE" ] || [ "$CODE" = "null" ]; then
    echo " ❌ Could not read .deployedBytecode.object from $ARTIFACT"
    exit 1
fi

# _owner is at slot 51 (OwnableUpgradeable, after Initializable + a 50-word gap).
# Normalize the owner address first: strip 0x, drop any non-hex chars (guards
# against a stray CR / trailing whitespace when .env was saved with CRLF), and
# lowercase. A storage value MUST be exactly 32 bytes (64 hex chars) or op-reth
# rejects the genesis with a "wrong length" error and init produces no block hash.
OWNER_NO0X=$(echo "${GASLESS_OWNER#0x}" | tr -cd '0-9A-Fa-f' | tr 'A-F' 'a-f')
if [ "${#OWNER_NO0X}" -ne 40 ]; then
    echo " ❌ GASLESS_WHITELIST_OWNER has wrong length: expected a 20-byte (40 hex char) address, got ${#OWNER_NO0X} hex chars from '${GASLESS_OWNER}'"
    exit 1
fi
# Left-pad the 40-char address to a full 64-char (32-byte) slot value.
OWNER_SLOT_VALUE=$(printf "0x%064s" "$OWNER_NO0X" | tr ' ' '0')
# Storage key for slot 51 (decimal) == 0x33.
OWNER_SLOT_KEY="0x0000000000000000000000000000000000000000000000000000000000000033"

echo "🔧 Pre-deploying GaslessWhitelist at 0x${GASLESS_ADDR_NO0X} (owner=${GASLESS_OWNER}, slot 51) ..."
jq --arg addr "$GASLESS_ADDR_NO0X" \
   --arg code "$CODE" \
   --arg slotkey "$OWNER_SLOT_KEY" \
   --arg slotval "$OWNER_SLOT_VALUE" \
   '.alloc[$addr] = {balance: "0x0", nonce: "0x1", code: $code, storage: {($slotkey): $slotval}}' \
   "$GENESIS" > "${GENESIS}.tmp" && mv "${GENESIS}.tmp" "$GENESIS"

echo " ✅ GaslessWhitelist predeploy injected into genesis.json"
