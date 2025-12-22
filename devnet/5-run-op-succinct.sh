#!/bin/bash
set -e

# ============================================================================
# OP-Succinct Setup Script
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

if [ "$OP_SUCCINCT_ENABLE" = "false" ]; then
  echo "skip launching op succinct"
  exit 0
fi

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts
OP_SUCCINCT_DIR=$PWD_DIR/op-succinct

if [ ! -f "$OP_SUCCINCT_DIR"/.env.deploy ]; then
    cp "$OP_SUCCINCT_DIR"/example.env.deploy "$OP_SUCCINCT_DIR"/.env.deploy
fi

if [ ! -f "$OP_SUCCINCT_DIR"/.env.proposer ]; then
    cp "$OP_SUCCINCT_DIR"/example.env.proposer "$OP_SUCCINCT_DIR"/.env.proposer
fi

if [ ! -f "$OP_SUCCINCT_DIR"/.env.challenger ]; then
    cp "$OP_SUCCINCT_DIR"/example.env.challenger "$OP_SUCCINCT_DIR"/.env.challenger
fi

mkdir -p "$OP_SUCCINCT_DIR"/configs/L1
cp ./l1-geth/execution/genesis-raw.json "$OP_SUCCINCT_DIR"/configs/L1/1337.json

ANCHOR_STATE_REGISTRY=$(cast call "$OPTIMISM_PORTAL_PROXY_ADDRESS" 'anchorStateRegistry()(address)' -r "$L1_RPC_URL")
if [ "$MIN_RUN" = "true" ]; then
    "$SCRIPTS_DIR"/update-anchor-root.sh
fi

# update .env.deploy
sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^L2_NODE_RPC=.*|L2_NODE_RPC=$L2_NODE_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.deploy

sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^OPTIMISM_PORTAL2_ADDRESS=.*|OPTIMISM_PORTAL2_ADDRESS=$OPTIMISM_PORTAL_PROXY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^ANCHOR_STATE_REGISTRY=.*|ANCHOR_STATE_REGISTRY=$ANCHOR_STATE_REGISTRY|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^TRANSACTOR_ADDRESS=.*|TRANSACTOR_ADDRESS=$TRANSACTOR|" "$OP_SUCCINCT_DIR"/.env.deploy
sed_inplace "s|^STARTING_L2_BLOCK_NUMBER=.*|STARTING_L2_BLOCK_NUMBER=$((FORK_BLOCK + 1))|" "$OP_SUCCINCT_DIR"/.env.deploy

sed_inplace "s|^OP_SUCCINCT_MOCK=.*|OP_SUCCINCT_MOCK=$OP_SUCCINCT_MOCK_MODE|" "$OP_SUCCINCT_DIR"/.env.deploy

STARTING_L2_BLOCK_NUMBER=$(cast call "$ANCHOR_STATE_REGISTRY" "getAnchorRoot()(bytes32,uint256)" --json | jq -r '.[1]')
sed_inplace "s|^STARTING_L2_BLOCK_NUMBER=.*|STARTING_L2_BLOCK_NUMBER=$STARTING_L2_BLOCK_NUMBER|" "$OP_SUCCINCT_DIR"/.env.deploy

# update .env.proposer
sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L1_BEACON_RPC=.*|L1_BEACON_RPC=$L1_BEACON_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^DGF_ADDRESS=.*|DGF_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L2_NODE_RPC=.*|L2_NODE_RPC=$L2_NODE_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer

sed_inplace "s|^MOCK_MODE=.*|MOCK_MODE=$OP_SUCCINCT_MOCK_MODE|" "$OP_SUCCINCT_DIR"/.env.proposer

# update .env.challenger
sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.challenger
sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.challenger
sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.challenger

docker compose up op-succinct-fetch-config
OP_DEPLOYER_ADDR=$(cast wallet a "$DEPLOYER_PRIVATE_KEY")
cast send --private-key "$RICH_L1_PRIVATE_KEY" --value 1ether "$OP_DEPLOYER_ADDR" --legacy --rpc-url "$L1_RPC_URL"
docker compose up op-succinct-contracts

cast send "$ANCHOR_STATE_REGISTRY" "setRespectedGameType(uint32)" 42 --private-key="$DEPLOYER_PRIVATE_KEY"

TARGET_HEIGHT=$(cast call "$ANCHOR_STATE_REGISTRY" "getAnchorRoot()(bytes32,uint256)" --json | jq -r '.[1]')

while true; do
    CURRENT_HEIGHT=$(cast bn -r "$L2_RPC_URL" finalized 2>/dev/null || echo "0")
    if [ "$CURRENT_HEIGHT" -ge "$TARGET_HEIGHT" ]; then
        echo "✓ Finalized height reached: ${CURRENT_HEIGHT}"
        break
    fi

    REMAINING=$((TARGET_HEIGHT - CURRENT_HEIGHT))
    echo "[$(date +'%H:%M:%S')] Finalized: ${CURRENT_HEIGHT}, Anchor: ${TARGET_HEIGHT}, Remaining: ${REMAINING}"
    sleep 5
done


docker compose up -d op-succinct-proposer
echo "   ✓ Proposer started"

# Start challenger if fast finality mode is disabled
if [ "${OP_SUCCINCT_FAST_FINALITY_MODE}" != "true" ]; then
    docker compose up -d op-succinct-challenger
    echo "   ✓ Challenger started"
else
    echo "   ⏭  Challenger skipped (fast finality mode)"
fi