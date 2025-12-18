#!/bin/bash
set -e

# ============================================================================
# Kailua Setup Script
# ============================================================================

# Load environment variables
source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

if [ "$PROOF_ENGINE" != "kailua" ]; then
  echo "skip launching kailua (PROOF_ENGINE=$PROOF_ENGINE)"
  exit 0
fi

if [ "$OWNER_TYPE" != "safe" ]; then
  echo "❌ Error: Need safe wallet to deploy kailua"
  exit 1
fi

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts
DIR=$PWD_DIR/kailua

# Copy example env files if they don't exist
if [ ! -f "$DIR"/.env.deploy ]; then
    cp "$DIR"/example.env.deploy "$DIR"/.env.deploy
fi

if [ ! -f "$DIR"/.env.proposer ]; then
    cp "$DIR"/example.env.proposer "$DIR"/.env.proposer
fi

if [ ! -f "$DIR"/.env.validator ]; then
    cp "$DIR"/example.env.validator "$DIR"/.env.validator
fi

if [ "$MIN_RUN" = "true" ]; then
    "$SCRIPTS_DIR"/update-anchor-root.sh
fi

# Get anchor root height from AnchorStateRegistry
ANCHOR_STATE_REGISTRY=$(cast call "$OPTIMISM_PORTAL_PROXY_ADDRESS" 'anchorStateRegistry()(address)' -r "$L1_RPC_URL")
ANCHOR_HEIGHT=$(cast call "$ANCHOR_STATE_REGISTRY" "getAnchorRoot()(bytes32,uint256)" --json -r "$L1_RPC_URL" | jq -r '.[1]')
echo "📍 Current Anchor Height: $ANCHOR_HEIGHT"

# Default values (can be overridden in .env)
STARTING_BLOCK_NUMBER=$ANCHOR_HEIGHT

# Calculate genesis time override
L1_BLOCK_JSON=$(cast block --rpc-url "$L1_RPC_URL" --json)
L1_TIMESTAMP=$(echo "$L1_BLOCK_JSON" | jq -r '.timestamp' | xargs printf "%d")
L2_BLOCK_TIME=${L2_BLOCK_TIME:-2}
GENESIS_TIME_OVERRIDE=$((L1_TIMESTAMP - STARTING_BLOCK_NUMBER * L2_BLOCK_TIME))

# Update .env.deploy
sed_inplace "s|^OP_NODE_URL=.*|OP_NODE_URL=$L2_NODE_RPC_URL_IN_DOCKER|" "$DIR"/.env.deploy
sed_inplace "s|^OP_GETH_URL=.*|OP_GETH_URL=$L2_RPC_URL_IN_DOCKER|" "$DIR"/.env.deploy
sed_inplace "s|^ETH_RPC_URL=.*|ETH_RPC_URL=$L1_RPC_URL_IN_DOCKER|" "$DIR"/.env.deploy

sed_inplace "s|^STARTING_BLOCK_NUMBER=.*|STARTING_BLOCK_NUMBER=$STARTING_BLOCK_NUMBER|" "$DIR"/.env.deploy
sed_inplace "s|^GENESIS_TIME_OVERRIDE=.*|GENESIS_TIME_OVERRIDE=$GENESIS_TIME_OVERRIDE|" "$DIR"/.env.deploy

# Update .env.proposer
sed_inplace "s|^OP_NODE_URL=.*|OP_NODE_URL=$L2_NODE_RPC_URL_IN_DOCKER|" "$DIR"/.env.proposer
sed_inplace "s|^OP_GETH_URL=.*|OP_GETH_URL=$L2_RPC_URL_IN_DOCKER|" "$DIR"/.env.proposer
sed_inplace "s|^ETH_RPC_URL=.*|ETH_RPC_URL=$L1_RPC_URL_IN_DOCKER|" "$DIR"/.env.proposer
sed_inplace "s|^BEACON_RPC_URL=.*|BEACON_RPC_URL=$L1_BEACON_URL_IN_DOCKER|" "$DIR"/.env.proposer

# Update .env.validator
sed_inplace "s|^OP_NODE_URL=.*|OP_NODE_URL=$L2_NODE_RPC_URL_IN_DOCKER|" "$DIR"/.env.validator
sed_inplace "s|^OP_GETH_URL=.*|OP_GETH_URL=$L2_RPC_URL_IN_DOCKER|" "$DIR"/.env.validator
sed_inplace "s|^ETH_RPC_URL=.*|ETH_RPC_URL=$L1_RPC_URL_IN_DOCKER|" "$DIR"/.env.validator
sed_inplace "s|^BEACON_RPC_URL=.*|BEACON_RPC_URL=$L1_BEACON_URL_IN_DOCKER|" "$DIR"/.env.validator

# Set RISC0_DEV_MODE based on mock mode
if [ "$PROOF_MOCK_MODE" = "true" ]; then
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=1|" "$DIR"/.env.deploy
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=1|" "$DIR"/.env.proposer
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=1|" "$DIR"/.env.validator
else
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=0|" "$DIR"/.env.deploy
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=0|" "$DIR"/.env.proposer
    sed_inplace "s|^RISC0_DEV_MODE=.*|RISC0_DEV_MODE=0|" "$DIR"/.env.validator
fi

# Set fast finality mode
if [ "$PROOF_FAST_FINALITY_MODE" = "true" ]; then
    sed_inplace "s|^FAST_FORWARD_START=.*|FAST_FORWARD_START=$STARTING_BLOCK_NUMBER|" "$DIR"/.env.validator
    sed_inplace "s|^FAST_FORWARD_TARGET=.*|FAST_FORWARD_TARGET=999999999|" "$DIR"/.env.validator
else
    sed_inplace "s|^FAST_FORWARD_START=.*|FAST_FORWARD_START=0|" "$DIR"/.env.validator
    sed_inplace "s|^FAST_FORWARD_TARGET=.*|FAST_FORWARD_TARGET=0|" "$DIR"/.env.validator
fi

docker compose up kailua-contracts
cast send "$ANCHOR_STATE_REGISTRY" "setRespectedGameType(uint32)" 1337 --private-key="$DEPLOYER_PRIVATE_KEY"
GAME_IMPL=$(cast call "$DISPUTE_GAME_FACTORY_ADDRESS" "gameImpls(uint32)(address)" 1337 --rpc-url "$L1_RPC_URL")

if [ -n "$GAME_IMPL" ] && [ "$GAME_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
    sed_inplace "s|^KAILUA_GAME_IMPLEMENTATION=.*|KAILUA_GAME_IMPLEMENTATION=$GAME_IMPL|" "$DIR"/.env.proposer
    sed_inplace "s|^KAILUA_GAME_IMPLEMENTATION=.*|KAILUA_GAME_IMPLEMENTATION=$GAME_IMPL|" "$DIR"/.env.validator
else
    echo "⚠️  No game implementation found for type $GAME_TYPE"
    exit 1
fi

docker compose up -d kailua-proposer kailua-validator