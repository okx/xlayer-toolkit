#!/usr/bin/env bash
# Minimal cast script: send a tx with data using Anvil's default key (or from env)
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
# Use ANVIL_PRIVATE_KEY env var if set, otherwise falls back to Anvil's default account #0
PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
TO_ADDRESS="${TO_ADDRESS:-0x0000000000000000000000000000000000000000}"
DATA="${DATA:-0xdeadbeef}"
VALUE="${VALUE:-0}"

if [[ "$PRIVATE_KEY" == "0xREPLACE_WITH_ANVIL_DEFAULT_PRIVATE_KEY" ]]; then
  echo "ERROR: set ANVIL_PRIVATE_KEY or replace placeholder PRIVATE_KEY with your Anvil private key."
  exit 1
fi

# ── cast send with ERC-8021 attribution suffix ────────────────────────────────
#
# ERC-8021 suffix layout (parsed right-to-left from end of calldata):
#   ercMarker   (16 bytes): 0x80218021802180218021802180218021
#   schemaId    (1  byte ): 0x00 = Canonical Code Registry
#   codesLength (1  byte ): byte length of the codes field
#   codes       (variable): ASCII attribution code(s), comma-delimited
#
# Final input = txData || codes || codesLength || schemaId || ercMarker

ERC8021_CODE="${ERC8021_CODE:-baseapp}"           # attribution code; replace with your builder code
ERC8021_CONTRACT="${ERC8021_CONTRACT:-$TO_ADDRESS}"
ERC8021_VALUE="${ERC8021_VALUE:-0}"

# 1. Build the original calldata (example: transfer(address,uint256); swap out as needed)
ERC8021_RECIPIENT="${ERC8021_RECIPIENT:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
ERC8021_AMOUNT="${ERC8021_AMOUNT:-1000000000000000000}"  # 1 ether in wei
TX_DATA=$(cast calldata "transfer(address,uint256)" "$ERC8021_RECIPIENT" "$ERC8021_AMOUNT")
# Strip 0x prefix
TX_DATA_HEX="${TX_DATA#0x}"

# 2. Encode the ERC-8021 suffix (pure bash, no external tools required)
encode_hex() {
  # Convert an ASCII string to its hex representation
  local s="$1"
  local hex=""
  for (( i=0; i<${#s}; i++ )); do
    hex+=$(printf '%02x' "'${s:$i:1}")
  done
  echo "$hex"
}

CODES_HEX=$(encode_hex "$ERC8021_CODE")
CODES_LEN_HEX=$(printf '%02x' "${#ERC8021_CODE}")   # codesLength: byte count of codes
SCHEMA_ID_HEX="00"                                   # Schema 0 = Canonical Registry
ERC_MARKER_HEX="80218021802180218021802180218021"

# 3. Concatenate into the final calldata
FULL_CALLDATA="0x${TX_DATA_HEX}${CODES_HEX}${CODES_LEN_HEX}${SCHEMA_ID_HEX}${ERC_MARKER_HEX}"

echo "=== ERC-8021 cast send ==="
echo "  contract : $ERC8021_CONTRACT"
echo "  code     : $ERC8021_CODE"
echo "  calldata : $FULL_CALLDATA"
echo ""

cast send "$ERC8021_CONTRACT" \
  "$FULL_CALLDATA" \
  --value "$ERC8021_VALUE" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL"
