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
# GaslessWhitelist storage layout (both vars pack into slot 0):
#   slot0 = [ 11 bytes zero | isGaslessEnabled (1 byte) | owner (20 bytes) ]
# We seed only `owner` (isGaslessEnabled stays false). Gasless is turned on later
# via setGaslessEnabled(true) from the owner account, which lets the contract
# write the correctly-packed slot itself.
set -e

source .env

GENESIS="./config-op/genesis.json"
GASLESS_ADDR_NO0X="4200000000000000000000000000000000000700"
GASLESS_OWNER="${GASLESS_WHITELIST_OWNER:-0x14dC79964da2C08b23698B3D3cc7Ca32193d9955}"

# The optimism monorepo that ships the GaslessWhitelist contract is always at
# OP_STACK_LOCAL_DIRECTORY (whether it's a standalone checkout or vendored under
# op-reth/deps/optimism), so derive the artifact path straight from it.
ARTIFACT="$OP_STACK_LOCAL_DIRECTORY/packages/contracts-xlayer/GaslessWhitelist/out/GaslessWhitelist.sol/GaslessWhitelist.json"

if [ ! -f "$GENESIS" ]; then
    echo " ❌ $GENESIS not found (run after op-deployer generates genesis.json)"
    exit 1
fi

if [ ! -f "$ARTIFACT" ]; then
    echo " 🔧 GaslessWhitelist artifact missing; building it with forge ..."
    export PATH="$HOME/.foundry/bin:$PATH"
    GW_DIR="$(dirname "$(dirname "$(dirname "$ARTIFACT")")")"
    # `forge clean` first: a stale cache + the parent contracts-bedrock/foundry.toml
    # otherwise make forge report "Nothing to compile". Skip the test/ sources so a
    # missing forge-std lib can't fail the build of this dependency-free contract.
    ( cd "$GW_DIR" && forge clean && forge build --root "$GW_DIR" --skip "test/**" --skip "*.t.sol" ) \
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

# slot 0 = owner left-padded to 32 bytes (isGaslessEnabled = false initially).
# Normalize first: strip 0x, drop any non-hex chars (guards against a stray CR /
# trailing whitespace when .env was saved with CRLF), and lowercase. A storage
# value MUST be exactly 32 bytes (64 hex chars) or op-reth rejects the genesis
# with a "wrong length" error and init produces no block hash.
OWNER_NO0X=$(echo "${GASLESS_OWNER#0x}" | tr -cd '0-9A-Fa-f' | tr 'A-F' 'a-f')
if [ "${#OWNER_NO0X}" -ne 40 ]; then
    echo " ❌ GASLESS_WHITELIST_OWNER has wrong length: expected a 20-byte (40 hex char) address, got ${#OWNER_NO0X} hex chars from '${GASLESS_OWNER}'"
    exit 1
fi
# Left-pad the 40-char address to a full 64-char (32-byte) slot value.
SLOT0=$(printf "0x%064s" "$OWNER_NO0X" | tr ' ' '0')
SLOT_KEY="0x0000000000000000000000000000000000000000000000000000000000000000"

echo "🔧 Pre-deploying GaslessWhitelist at 0x${GASLESS_ADDR_NO0X} (owner=${GASLESS_OWNER}) ..."
jq --arg addr "$GASLESS_ADDR_NO0X" \
   --arg code "$CODE" \
   --arg slotkey "$SLOT_KEY" \
   --arg slot0 "$SLOT0" \
   '.alloc[$addr] = {balance: "0x0", nonce: "0x1", code: $code, storage: {($slotkey): $slot0}}' \
   "$GENESIS" > "${GENESIS}.tmp" && mv "${GENESIS}.tmp" "$GENESIS"

echo " ✅ GaslessWhitelist predeploy injected into genesis.json"
