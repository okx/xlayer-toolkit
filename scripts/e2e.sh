#!/usr/bin/env bash
# e2e.sh — End-to-end test for ERC-8021 Schema 1 + BuilderCodes on Anvil
#
# Prerequisites:
#   - Anvil running at RPC_URL (default http://127.0.0.1:8545)
#   - forge & cast (Foundry) in PATH
#
# Usage:
#   anvil &                   # start a local node in the background
#   bash scripts/e2e.sh       # run this script
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${CHAIN_ID:-31337}"
CONTRACTS_DIR="$(cd "$(dirname "$0")/../contracts" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Anvil account #0 — deployer / owner / REGISTER_ROLE signer
KEY0="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ADDR0="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Anvil account #1 — code owner (initialOwner / payoutAddress)
KEY1="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ADDR1="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

BUILDER_CODE="${BUILDER_CODE:-xlayer}"
BASE_URI="https://xlayer.com/"
ERC_MARKER_HEX="80218021802180218021802180218021"

# ── Helpers ───────────────────────────────────────────────────────────────────
step() { echo; echo "=== $* ==="; }
info() { echo "  >  $*"; }
ok()   { echo "  ok  $*"; }

encode_hex() {
  local s="$1" hex="" i
  for (( i=0; i<${#s}; i++ )); do hex+=$(printf '%02x' "'${s:$i:1}"); done
  printf '%s' "$hex"
}

# Verify Anvil is reachable
cast block latest --rpc-url "$RPC_URL" > /dev/null 2>&1 \
  || { echo "ERROR: no Anvil node at $RPC_URL — run 'anvil' first."; exit 1; }

cd "$CONTRACTS_DIR"

# ── Step 1: Deploy BuilderCodes ───────────────────────────────────────────────
step "Step 1: Deploy BuilderCodes (implementation + ERC-1967 proxy)"

info "Deploying implementation..."
IMPL=$(forge create src/BuilderCodes.sol:BuilderCodes \
  --broadcast --private-key "$KEY0" --rpc-url "$RPC_URL" 2>&1 \
  | grep "Deployed to:" | awk '{print $3}')
ok "Implementation: $IMPL"

# Encode proxy init call: owner=ADDR0, initialRegistrar=ADDR0, placeholder URI
INIT_DATA=$(cast calldata \
  "initialize(address,address,string)" "$ADDR0" "$ADDR0" "https://placeholder.com/")

info "Deploying ERC-1967 proxy..."
# forge create has issues passing bytes constructor args in Foundry v1.x;
# use cast send --create with manually assembled deploy bytecode instead.
PROXY_BYTECODE=$(cat "$CONTRACTS_DIR/out/ERC1967Proxy.sol/ERC1967Proxy.json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['bytecode']['object'])")
PROXY_CTOR=$(cast abi-encode "constructor(address,bytes)" "$IMPL" "$INIT_DATA")
PROXY_DEPLOY_DATA="${PROXY_BYTECODE}${PROXY_CTOR#0x}"
PROXY=$(cast send \
  --private-key "$KEY0" --rpc-url "$RPC_URL" \
  --create "$PROXY_DEPLOY_DATA" 2>&1 \
  | grep "contractAddress" | awk '{print $2}')
ok "Proxy (BuilderCodes): $PROXY"

# ── Step 2: Grant roles ───────────────────────────────────────────────────────
step "Step 2: Grant REGISTER_ROLE + METADATA_ROLE to $ADDR0"

# ADDR0 is already the owner (hasRole override grants owner all roles), but we
# grant explicitly to match the GrantRegisterRole script pattern.
REGISTER_ROLE=$(cast call "$PROXY" "REGISTER_ROLE()(bytes32)" --rpc-url "$RPC_URL")
METADATA_ROLE=$(cast call "$PROXY" "METADATA_ROLE()(bytes32)" --rpc-url "$RPC_URL")

cast send "$PROXY" "grantRole(bytes32,address)" \
  "$REGISTER_ROLE" "$ADDR0" \
  --private-key "$KEY0" --rpc-url "$RPC_URL" > /dev/null
ok "REGISTER_ROLE granted"

cast send "$PROXY" "grantRole(bytes32,address)" \
  "$METADATA_ROLE" "$ADDR0" \
  --private-key "$KEY0" --rpc-url "$RPC_URL" > /dev/null
ok "METADATA_ROLE  granted"

# ── Step 3: registerWithSignature + updateBaseURI ─────────────────────────────
step "Step 3: Key #1 requests code registration; key #0 signs & submits"

# Key #1 provides: the code name + their address as initialOwner/payoutAddress
info "Key #1 (code owner):     $ADDR1"
info "Builder code requested:  $BUILDER_CODE"

# Deadline = latest block timestamp + 1 hour
CURRENT_TS=$(cast block latest --rpc-url "$RPC_URL" --field timestamp 2>/dev/null \
  || cast block latest --rpc-url "$RPC_URL" | grep "^timestamp" | awk '{print $2}')
DEADLINE=$(( CURRENT_TS + 3600 ))
info "Registration deadline:   $DEADLINE"

# ── EIP-712 domain separator
#   keccak256(abi.encode(
#     keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
#     keccak256("Builder Codes"),
#     keccak256("1"),
#     chainId,
#     proxy
#   ))
DOMAIN_TYPEHASH=$(cast keccak \
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
NAME_HASH=$(cast keccak "Builder Codes")
VERSION_HASH=$(cast keccak "1")
DOMAIN_SEP_ENC=$(cast abi-encode \
  "f(bytes32,bytes32,bytes32,uint256,address)" \
  "$DOMAIN_TYPEHASH" "$NAME_HASH" "$VERSION_HASH" "$CHAIN_ID" "$PROXY")
DOMAIN_SEP=$(cast keccak "$DOMAIN_SEP_ENC")

# ── EIP-712 struct hash
#   keccak256(abi.encode(
#     keccak256("BuilderCodeRegistration(string code,address initialOwner,address payoutAddress,uint48 deadline)"),
#     keccak256(bytes(code)),
#     initialOwner,
#     payoutAddress,
#     deadline
#   ))
TYPEHASH=$(cast keccak \
  "BuilderCodeRegistration(string code,address initialOwner,address payoutAddress,uint48 deadline)")
CODE_HASH=$(cast keccak "$BUILDER_CODE")
STRUCT_ENC=$(cast abi-encode \
  "f(bytes32,bytes32,address,address,uint48)" \
  "$TYPEHASH" "$CODE_HASH" "$ADDR1" "$ADDR1" "$DEADLINE")
STRUCT_HASH=$(cast keccak "$STRUCT_ENC")

# ── Final digest: keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash))
DIGEST=$(cast keccak "0x1901${DOMAIN_SEP#0x}${STRUCT_HASH#0x}")
info "EIP-712 digest: $DIGEST"

# Key #0 signs the digest (raw ECDSA, no personal_sign prefix)
SIG=$(cast wallet sign --no-hash "$DIGEST" --private-key "$KEY0")
info "Signature:      $SIG"

# Submit: signer=ADDR0 (REGISTER_ROLE), tx sender=ADDR0
cast send "$PROXY" \
  "registerWithSignature(string,address,address,uint48,address,bytes)" \
  "$BUILDER_CODE" "$ADDR1" "$ADDR1" "$DEADLINE" "$ADDR0" "$SIG" \
  --private-key "$KEY0" --rpc-url "$RPC_URL" > /dev/null
ok "registerWithSignature submitted"

IS_REG=$(cast call "$PROXY" \
  "isRegistered(string)(bool)" "$BUILDER_CODE" --rpc-url "$RPC_URL")
TOKEN_ID=$(cast call "$PROXY" \
  "toTokenId(string)(uint256)" "$BUILDER_CODE" --rpc-url "$RPC_URL" | awk '{print $1}')
OWNER=$(cast call "$PROXY" \
  "ownerOf(uint256)(address)" "$TOKEN_ID" --rpc-url "$RPC_URL")
PAYOUT=$(cast call "$PROXY" \
  "payoutAddress(string)(address)" "$BUILDER_CODE" --rpc-url "$RPC_URL")
ok "isRegistered('$BUILDER_CODE') = $IS_REG"
ok "NFT owner                     = $OWNER"
ok "Payout address                = $PAYOUT"

# Update base URI (METADATA_ROLE)
cast send "$PROXY" "updateBaseURI(string)" "$BASE_URI" \
  --private-key "$KEY0" --rpc-url "$RPC_URL" > /dev/null
ok "Base URI updated to: $BASE_URI"

# ── Step 4: Send ERC-8021 Schema 1 transaction ────────────────────────────────
step "Step 4: Send ERC-8021 Schema 1 transaction"

# txData: transfer(address,uint256) — swap with any real calldata as needed
TX_DATA=$(cast calldata "transfer(address,uint256)" "$ADDR1" "1000000000000000000")
TX_DATA_HEX="${TX_DATA#0x}"

# ── Schema 1 calldata layout (left to right):
#
#   txData
#   ‖ codeRegistryAddress(20 bytes)
#   ‖ codeRegistryChainId(N bytes, big-endian minimal)
#   ‖ codeRegistryChainIdLength(1 byte)
#   ‖ codes(M bytes, comma-delimited ASCII)
#   ‖ codesLength(1 byte)
#   ‖ schemaId(1 byte = 0x01)
#   ‖ ercMarker(16 bytes)

# Registry address: 20 bytes, lowercase hex, no 0x
PROXY_HEX=$(printf '%s' "${PROXY#0x}" | tr '[:upper:]' '[:lower:]')

# Chain ID: minimal big-endian encoding (no leading zero bytes)
CHAIN_ID_HEX=$(printf '%x' "$CHAIN_ID")
(( ${#CHAIN_ID_HEX} % 2 == 1 )) && CHAIN_ID_HEX="0${CHAIN_ID_HEX}"
CHAIN_ID_LEN=$(( ${#CHAIN_ID_HEX} / 2 ))
CHAIN_ID_LEN_HEX=$(printf '%02x' "$CHAIN_ID_LEN")

CODES_HEX=$(encode_hex "$BUILDER_CODE")
CODES_LEN_HEX=$(printf '%02x' "${#BUILDER_CODE}")

FULL_CALLDATA="0x${TX_DATA_HEX}${PROXY_HEX}${CHAIN_ID_HEX}${CHAIN_ID_LEN_HEX}${CODES_HEX}${CODES_LEN_HEX}01${ERC_MARKER_HEX}"

info "Registry : $PROXY"
info "ChainID  : $CHAIN_ID  (0x${CHAIN_ID_HEX}, len=0x${CHAIN_ID_LEN_HEX})"
info "Code     : $BUILDER_CODE  (hex=0x${CODES_HEX}, len=0x${CODES_LEN_HEX})"
info "Calldata : $FULL_CALLDATA"

# Send to ADDR1 (EOA) so the base calldata is accepted by the EVM.
# ERC-8021 attribution is in the suffix — the target doesn't need to implement
# the base function; any address that won't revert works fine.
TX_HASH=$(cast send "$ADDR1" "$FULL_CALLDATA" \
  --value 0 \
  --private-key "$KEY0" \
  --rpc-url "$RPC_URL" \
  | grep "transactionHash" | awk '{print $2}')

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "================================================"
echo "  ERC-8021 Schema 1 transaction submitted"
echo "================================================"
echo "  TxHash   : $TX_HASH"
echo "  Registry : $PROXY"
echo "  RPC      : $RPC_URL"
echo
echo "  Parse with the indexer:"
echo "    cd $REPO_ROOT"
echo "    erc8021cmd -txhash $TX_HASH -rpc $RPC_URL"
echo "================================================"
