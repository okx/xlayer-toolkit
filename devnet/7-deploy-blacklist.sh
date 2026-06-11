#!/bin/bash
# 7-deploy-blacklist.sh — deploy the L2BlacklistMirror demo stub (XLOP-1100).
#
# Devnet-only, chain_id 195. Gated by BLACKLIST_DEMO_ENABLED in .env; when off
# this is a no-op so `make run` / 0-all.sh behave exactly as before.
#
# The mirror is deployed by a DEDICATED test-mnemonic account (index
# BLACKLIST_DEPLOYER_INDEX) whose only job is this one deployment, so its L2
# nonce is 0 and the CREATE address is deterministic
# (= BLACKLIST_MIRROR_ADDRESS). The script fails fast if the nonce has drifted
# or the deployed address does not match, to avoid silently deploying to the
# wrong address (which would diverge from the node-hardcoded address).
#
# NOTE: until op-geth (params/config_xlayer.go) and xlayer-reth
# (crates/builder/src/blacklist/mirror.rs) hardcode BLACKLIST_MIRROR_ADDRESS for
# chain 195 and are rebuilt, the nodes still read the old placeholder address,
# so the deployed contract is NOT yet read by the execution gate. This script
# only provisions the contract; end-to-end interception needs that client change.
set -e

cd "$(dirname "$0")"
source .env

MNEMONIC="test test test test test test test test test test test junk"

if [ "${BLACKLIST_DEMO_ENABLED}" != "true" ]; then
  echo "ℹ️  BLACKLIST_DEMO_ENABLED != true — skipping blacklist mirror deploy (no-op)."
  exit 0
fi

# Only the three XLayer chains are blacklist-enabled; devnet is 195.
if [ "${CHAIN_ID}" != "195" ]; then
  echo "⚠️  BLACKLIST_DEMO_ENABLED=true but CHAIN_ID=${CHAIN_ID} (expected 195). Skipping."
  exit 0
fi

echo "🚫 Deploying L2BlacklistMirror demo stub to chain ${CHAIN_ID} ..."

# Idempotent: if the mirror is already deployed (e.g. 0-all.sh re-run on a live
# devnet), there is nothing to do — the deterministic address already holds code.
EXISTING_CODE=$(cast code "$BLACKLIST_MIRROR_ADDRESS" --rpc-url "$L2_RPC_URL")
if [ "$EXISTING_CODE" != "0x" ] && [ -n "$EXISTING_CODE" ]; then
  echo "ℹ️  Mirror already deployed at ${BLACKLIST_MIRROR_ADDRESS} — nothing to do."
  exit 0
fi

# Sign as the dedicated deployer via mnemonic + derivation path (the signer is
# passed directly to forge/cast; the private key is never materialised here).
DPATH="m/44'/60'/0'/0/${BLACKLIST_DEPLOYER_INDEX}"
DEPLOYER_ADDR=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-derivation-path "$DPATH")

echo "   deployer (index ${BLACKLIST_DEPLOYER_INDEX}): ${DEPLOYER_ADDR}"
echo "   expected mirror address:                     ${BLACKLIST_MIRROR_ADDRESS}"

# --- Pre-flight: nonce must be 0, else the CREATE address would not match. ---
NONCE=$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$L2_RPC_URL")
if [ "$NONCE" != "0" ]; then
  echo "❌ Deployer L2 nonce is ${NONCE}, expected 0. The deterministic address"
  echo "   only holds for the account's first deploy. Aborting to avoid a"
  echo "   mismatch with the node-hardcoded address. Reset the devnet or use a"
  echo "   fresh BLACKLIST_DEPLOYER_INDEX."
  exit 1
fi

# --- Ensure the deployer has gas (fund from the rich deployer if empty). ---
BAL=$(cast balance "$DEPLOYER_ADDR" --rpc-url "$L2_RPC_URL")
if [ "$BAL" = "0" ]; then
  echo "   deployer has 0 balance — funding 1 ETH from DEPLOYER_PRIVATE_KEY ..."
  cast send --rpc-url "$L2_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    --value 1ether "$DEPLOYER_ADDR" >/dev/null
fi

# --- Deploy (forge compiles the self-contained stub on the fly). ---
CREATE_JSON=$(cd contracts/blacklist && forge create \
  src/L2BlacklistMirror.sol:L2BlacklistMirror \
  --rpc-url "$L2_RPC_URL" \
  --mnemonic "$MNEMONIC" --mnemonic-derivation-path "$DPATH" \
  --broadcast --json)

DEPLOYED=$(echo "$CREATE_JSON" | jq -r '.deployedTo // empty')
if [ -z "$DEPLOYED" ]; then
  echo "❌ forge create did not return a deployed address. Output:"
  echo "$CREATE_JSON"
  exit 1
fi

# --- Assert the deployed address matches the expected deterministic one. ---
shopt -s nocasematch
if [[ "$DEPLOYED" != "$BLACKLIST_MIRROR_ADDRESS" ]]; then
  echo "❌ Deployed at ${DEPLOYED} but expected ${BLACKLIST_MIRROR_ADDRESS}."
  echo "   Address drift — refusing to continue (would diverge from node config)."
  exit 1
fi
shopt -u nocasematch
echo "   ✅ mirror deployed at ${DEPLOYED} (matches expected)"

# --- Optional: seed one demo entry and verify the enumerable layout works. ---
DEMO_LISTED="${BLACKLIST_DEMO_SEED:-0x00000000000000000000000000000000000000AA}"
echo "   seeding demo blacklisted address: ${DEMO_LISTED}"
cast send --rpc-url "$L2_RPC_URL" --mnemonic "$MNEMONIC" --mnemonic-derivation-path "$DPATH" \
  "$BLACKLIST_MIRROR_ADDRESS" "add(address)" "$DEMO_LISTED" >/dev/null

# Verify via the node read interface getBlacklist(start, limit) -> (total, addresses).
# total is the first return value; one call returns total + the (single) page.
TOTAL=$(cast call --rpc-url "$L2_RPC_URL" "$BLACKLIST_MIRROR_ADDRESS" \
  "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 | head -1)
echo "   getBlacklist total = ${TOTAL}"
if [ "$TOTAL" != "1" ]; then
  echo "❌ Expected total==1 after one add(), got ${TOTAL}."
  exit 1
fi

echo "✅ L2BlacklistMirror demo ready at ${BLACKLIST_MIRROR_ADDRESS}."
echo "   (Reminder: nodes intercept only after op-geth / xlayer-reth hardcode"
echo "    this address for chain 195 and are rebuilt.)"
