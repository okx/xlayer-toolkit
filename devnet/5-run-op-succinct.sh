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

# GPU prover mode: layer in sp1-cluster's compose file via COMPOSE_FILE, and
# pre-create the host dir for trusted-setup params so docker doesn't bind-mount
# a root-owned empty.
if [ "$PROOF_USE_GPU_PROVER" = "true" ]; then
    export SP1_CIRCUITS_HOST_DIR
    mkdir -p "$SP1_CIRCUITS_HOST_DIR"
    export COMPOSE_FILE="docker-compose.yml:docker-compose-sp1-cluster.yml"
fi

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


# Bring up sp1-cluster + point .env.proposer at it.
if [ "$PROOF_USE_GPU_PROVER" = "true" ]; then
    echo "   → starting sp1-cluster..."
    docker compose up -d \
        sp1-redis sp1-postgresql sp1-api sp1-coordinator sp1-cpu-node \
        sp1-gpu0 sp1-gpu1 sp1-gpu2 sp1-gpu3

    # Coordinator readiness: API + DB migration cold-start takes 20-40s.
    # We can't use /dev/tcp probes because the image's sh is dash. Look for
    # the periodic "GetStatsResponse" log line — coordinator only emits that
    # once it has finished startup and is serving the stats RPC.
    echo "   → waiting for sp1-coordinator..."
    for i in $(seq 1 60); do
        if docker logs sp1-coordinator 2>&1 | grep -q GetStatsResponse; then
            echo "   ✓ sp1-coordinator ready"
            break
        fi
        sleep 2
        if [ "$i" = "60" ]; then
            echo "   ✗ sp1-coordinator did not become ready within 120s"
            docker logs --tail 50 sp1-coordinator || true
            exit 1
        fi
    done

    # Coordinator is up, but PlonkWrap needs the cpu-node registered too.
    # If cpu-node failed to start (most often: missing trusted-setup params at
    # $SP1_CIRCUITS_HOST_DIR), we'd fail later inside the prove pipeline.
    # Surface it now.
    echo "   → waiting for sp1-cpu-node to register..."
    for i in $(seq 1 30); do
        if docker logs sp1-coordinator 2>&1 | grep -E "cpu_workers: [1-9]" -q; then
            echo "   ✓ sp1-cpu-node registered"
            break
        fi
        sleep 2
        if [ "$i" = "30" ]; then
            echo "   ✗ sp1-cpu-node never registered (cpu_workers still 0)"
            echo "   most likely cause: missing trusted-setup params at $SP1_CIRCUITS_HOST_DIR"
            docker logs --tail 50 sp1-cpu-node || true
            exit 1
        fi
    done

    upsert_proposer_env() {
        local key="$1" value="$2" file="$OP_SUCCINCT_DIR/.env.proposer"
        if grep -q "^${key}=" "$file"; then
            sed_inplace "s|^${key}=.*|${key}=${value}|" "$file"
        else
            echo "${key}=${value}" >> "$file"
        fi
    }

    # ClusterProofProvider reads these to talk to the local coordinator.
    upsert_proposer_env "SP1_PROVER"      "cluster"
    upsert_proposer_env "CLI_CLUSTER_RPC" "http://sp1-coordinator:50051"
    upsert_proposer_env "CLI_REDIS_NODES" "redis://:redispassword@sp1-redis:6379/0"
    upsert_proposer_env "MOCK_MODE"       "false"
fi

docker compose up -d op-succinct-proposer
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