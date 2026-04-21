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

if [ "$PROOF_ENGINE" != "op-succinct" ]; then
  echo "skip launching op succinct (PROOF_ENGINE=$PROOF_ENGINE)"
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

sed_inplace "s|^OP_SUCCINCT_MOCK=.*|OP_SUCCINCT_MOCK=$PROOF_MOCK_MODE|" "$OP_SUCCINCT_DIR"/.env.deploy

STARTING_L2_BLOCK_NUMBER=$(cast call "$ANCHOR_STATE_REGISTRY" "getAnchorRoot()(bytes32,uint256)" --json | jq -r '.[1]')
sed_inplace "s|^STARTING_L2_BLOCK_NUMBER=.*|STARTING_L2_BLOCK_NUMBER=$STARTING_L2_BLOCK_NUMBER|" "$OP_SUCCINCT_DIR"/.env.deploy

# update .env.proposer
sed_inplace "s|^L1_RPC=.*|L1_RPC=$L1_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L1_BEACON_RPC=.*|L1_BEACON_RPC=$L1_BEACON_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L2_RPC=.*|L2_RPC=$L2_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^FACTORY_ADDRESS=.*|FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" "$OP_SUCCINCT_DIR"/.env.proposer
sed_inplace "s|^L2_NODE_RPC=.*|L2_NODE_RPC=$L2_NODE_RPC_URL_IN_DOCKER|" "$OP_SUCCINCT_DIR"/.env.proposer

sed_inplace "s|^MOCK_MODE=.*|MOCK_MODE=$PROOF_MOCK_MODE|" "$OP_SUCCINCT_DIR"/.env.proposer

# ANCHOR_STATE_REGISTRY_ADDRESS is required by proposer since op-succinct PR #746
# (Dec 2025). Reuses $ANCHOR_STATE_REGISTRY computed above for .env.deploy.
upsert_env() {
    local key=$1 value=$2 file=$3
    if grep -qE "^${key}=" "$file"; then
        sed_inplace "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}
upsert_env ANCHOR_STATE_REGISTRY_ADDRESS "$ANCHOR_STATE_REGISTRY" "$OP_SUCCINCT_DIR"/.env.proposer

# Local GPU proving: SP1_PROVER=local and MOCK_MODE=true are mutually exclusive
# in op-succinct. When GPU is enabled, force MOCK_MODE=false and write SP1_PROVER /
# CUDA_GPU_IDS into the proposer env (appending if the keys don't exist).
COMPOSE_GPU_ARGS=()
if [ "$OP_SUCCINCT_USE_GPU" = "true" ]; then
    echo "🎮 Enabling local GPU proving (CUDA_GPU_IDS=${OP_SUCCINCT_CUDA_GPU_IDS})"
    sed_inplace "s|^MOCK_MODE=.*|MOCK_MODE=false|" "$OP_SUCCINCT_DIR"/.env.proposer

    upsert_env SP1_PROVER local "$OP_SUCCINCT_DIR"/.env.proposer
    upsert_env CUDA_GPU_IDS "$OP_SUCCINCT_CUDA_GPU_IDS" "$OP_SUCCINCT_DIR"/.env.proposer
    # The CUDA image pre-bakes groth16 trusted-setup params (SP1_BAKE_PARAMS=groth16).
    # Align the proposer's agg-proof mode so it doesn't try to fetch plonk params at runtime.
    upsert_env AGG_PROOF_MODE groth16 "$OP_SUCCINCT_DIR"/.env.proposer

    COMPOSE_GPU_ARGS=(-f docker-compose.yml -f docker-compose-op-succinct-gpu.yml)
fi

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


docker compose "${COMPOSE_GPU_ARGS[@]}" up -d op-succinct-proposer
echo "   ✓ Proposer started"

if [ "$MIN_RUN" = "false" ]; then
    docker-compose down op-proposer
    docker-compose down op-challenger
    echo "   ✓ Older proposer and challenger stopped"
fi

# Start challenger if fast finality mode is disabled
if [ "${PROOF_FAST_FINALITY_MODE}" != "true" ]; then
    docker compose up -d op-succinct-challenger
    echo "   ✓ Challenger started"
else
    echo "   ⏭  Challenger skipped (fast finality mode)"
fi