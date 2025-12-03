#!/bin/bash

set -e

source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ========================================
# Genesis Preparation (unified script)
# ========================================
source scripts/prepare-genesis.sh
prepare_genesis

# Extract contract addresses from state.json and update .env file
echo "🔧 Extracting contract addresses from state.json..."
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_JSON="$PWD_DIR/config-op/state.json"

if [ -f "$STATE_JSON" ]; then
    # Extract contract addresses from state.json
    DEPLOYMENTS_TYPE=$(jq -r 'type' "$STATE_JSON")
    if [ "$DEPLOYMENTS_TYPE" = "object" ]; then
        OPCD_TYPE=$(jq -r '.opChainDeployments | type' "$STATE_JSON" 2>/dev/null)
        if [ "$OPCD_TYPE" = "object" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments.DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments.L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments.SystemConfigProxy // empty' "$STATE_JSON")
            OPTIMISM_PORTAL_PROXY_ADDRESS=$(jq -r '.opChainDeployments.OptimismPortalProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        elif [ "$OPCD_TYPE" = "array" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments[0].L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].SystemConfigProxy // empty' "$STATE_JSON")
            OPTIMISM_PORTAL_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].OptimismPortalProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        else
            DISPUTE_GAME_FACTORY_ADDRESS=""
            L2OO_ADDRESS=""
            OPCM_IMPL_ADDRESS=""
            SYSTEM_CONFIG_PROXY_ADDRESS=""
            OPTIMISM_PORTAL_PROXY_ADDRESS=""
            PROXY_ADMIN=""
        fi

        # Update .env if found
        if [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
            echo " ✅ Found DisputeGameFactoryProxy address: $DISPUTE_GAME_FACTORY_ADDRESS"
            sed_inplace "s/DISPUTE_GAME_FACTORY_ADDRESS=.*/DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS/" .env
        else
            echo " ⚠️ DisputeGameFactoryProxy address not found in opChainDeployments"
        fi

        if [ -n "$L2OO_ADDRESS" ]; then
            echo " ✅ Found L2OutputOracleProxy address: $L2OO_ADDRESS"
            sed_inplace "s/L2OO_ADDRESS=.*/L2OO_ADDRESS=$L2OO_ADDRESS/" .env
        else
            echo " ⚠️ L2OutputOracleProxy address not found in opChainDeployments"
        fi

        if [ -n "$OPCM_IMPL_ADDRESS" ]; then
            echo " ✅ Found opcmAddress address: $OPCM_IMPL_ADDRESS"
            sed_inplace "s/OPCM_IMPL_ADDRESS=.*/OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS/" .env
        else
            echo " ⚠️ opcmAddress address not found in opChainDeployments"
        fi

        if [ -n "$SYSTEM_CONFIG_PROXY_ADDRESS" ]; then
            echo " ✅ Found SystemConfigProxy address: $SYSTEM_CONFIG_PROXY_ADDRESS"
            sed_inplace "s/SYSTEM_CONFIG_PROXY_ADDRESS=.*/SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS/" .env
        else
            echo " ⚠️ SystemConfigProxy address not found in opChainDeployments"
        fi

        if [ -n "$OPTIMISM_PORTAL_PROXY_ADDRESS" ]; then
            echo " ✅ Found OptimismPortalProxy address: $OPTIMISM_PORTAL_PROXY_ADDRESS"
            sed_inplace "s/OPTIMISM_PORTAL_PROXY_ADDRESS=.*/OPTIMISM_PORTAL_PROXY_ADDRESS=$OPTIMISM_PORTAL_PROXY_ADDRESS/" .env
        else
            echo " ⚠️ OptimismPortalProxy address not found in opChainDeployments"
        fi

        if [ -n "$PROXY_ADMIN" ]; then
            echo " ✅ Found ProxyAdmin address: $PROXY_ADMIN"
            sed_inplace "s/PROXY_ADMIN=.*/PROXY_ADMIN=$PROXY_ADMIN/" .env
        else
            echo " ⚠️ ProxyAdmin address not found in opChainDeployments"
        fi

        # Show summary
        echo " 📄 Contract addresses updated in .env:"
        echo "   DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS"
        echo "   L2OO_ADDRESS=$L2OO_ADDRESS"
        echo "   OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS"
        echo "   SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS"
        echo "   OPTIMISM_PORTAL_PROXY_ADDRESS=$OPTIMISM_PORTAL_PROXY_ADDRESS"
        echo "   PROXY_ADMIN=$PROXY_ADMIN"
    else
        echo " ❌ $STATE_JSON is not a valid JSON object"
    fi
else
    echo " ❌ state.json not found at $STATE_JSON"
fi

# init geth sequencer
echo " 🔧 Initializing geth sequencer..."
OP_GETH_DATADIR="$(pwd)/data/op-geth-seq"
rm -rf "$OP_GETH_DATADIR"
mkdir -p "$OP_GETH_DATADIR"

docker compose run --no-deps --rm \
  -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json" \
  op-geth-seq \
  --datadir "/datadir" \
  --gcmode=archive \
  --db.engine=$DB_ENGINE \
  init \
  --state.scheme=hash \
  /genesis.json

# Remove nodekey to ensure other nodes generates a unique node ID
echo " 🔑 Removing nodekey to generate unique node ID for other nodes..."
rm -f "$OP_GETH_DATADIR/geth/nodekey"

# Get trusted peers enode url
sed_inplace "s|TRUSTED_PEERS=.*|TRUSTED_PEERS=$(./scripts/trusted-peers.sh)|" .env

# init reth sequencer
echo " 🔧 Initializing reth sequencer..."
OP_RETH_DATADIR="$(pwd)/data/op-reth-seq"
OP_RETH_DATADIR2="$(pwd)/data/op-reth-seq2"

rm -rf "$OP_RETH_DATADIR"
mkdir -p "$OP_RETH_DATADIR"
INIT_LOG=$(docker compose run --no-deps --rm \
  -v "$(pwd)/$CONFIG_DIR/genesis-reth.json:/genesis.json" \
  --entrypoint op-reth \
  op-reth-seq \
  init \
  --datadir="/datadir" \
  --chain=/genesis.json \
  --log.stdout.format=json | tee init.log)

NEW_BLOCK_HASH=$(tail -n 1 init.log | jq -r .fields.hash)
echo "NEW_BLOCK_HASH=$NEW_BLOCK_HASH"
sed_inplace "s/NEW_BLOCK_HASH=.*/NEW_BLOCK_HASH=$NEW_BLOCK_HASH/" .env


# Copy initialized database from op-geth-seq to other nodes
OP_GETH_RPC_DATADIR="$(pwd)/data/op-geth-rpc"

echo " 🔄 Copying database from op-geth-seq to op-geth-rpc..."
rm -rf "$OP_GETH_RPC_DATADIR"
cp -r "$OP_GETH_DATADIR" "$OP_GETH_RPC_DATADIR"

if [ "$CONDUCTOR_ENABLED" = "true" ]; then
    if [ "$SEQ_TYPE" = "geth" ]; then
        OP_GETH_DATADIR2="$(pwd)/data/op-geth-seq2"
        rm -rf "$OP_GETH_DATADIR2"
        cp -r $OP_GETH_DATADIR $OP_GETH_DATADIR2
    elif [ "$SEQ_TYPE" = "reth" ]; then
        rm -rf "$OP_RETH_DATADIR2"
        cp -r $OP_RETH_DATADIR $OP_RETH_DATADIR2
    fi

    # op-seq3 default EL is always op-geth to ensure multiple seqs' geth and reth compatibilities
    OP_GETH_DATADIR3="$(pwd)/data/op-geth-seq3"
    rm -rf "$OP_GETH_DATADIR3"
    cp -r $OP_GETH_DATADIR $OP_GETH_DATADIR3
fi

SEQ_L2_EXECUTION_CLIENT="op-${SEQ_TYPE}-seq"
SEQ_L2_EXECUTION_PORT=8545

# For flashblocks architecture
if [ "$FLASHBLOCK_ENABLED" = "true" ]; then
    # Copy initialized database from op-geth-seq to op-rbuilder
    OP_RBUILDER_DATADIR="$(pwd)/data/op-rbuilder"
    rm -rf "$OP_RBUILDER_DATADIR"
    cp -r $OP_RETH_DATADIR $OP_RBUILDER_DATADIR
    if [ "$CONDUCTOR_ENABLED" = "true" ]; then
        OP_RBUILDER_DATADIR2="$(pwd)/data/op-rbuilder2"
        rm -rf "$OP_RBUILDER_DATADIR2"
        cp -r $OP_RETH_DATADIR $OP_RBUILDER_DATADIR2
    fi

    # Set sequencer L2 execution client into env
    SEQ_L2_EXECUTION_CLIENT="rollup-boost"
    SEQ_L2_EXECUTION_PORT=8552

    # Set p2p nodekey
    echo -n "b04fab1a632f3371f90ba4a24853e1b42b5625418f07e042151185e818d0c5f6" > $OP_RBUILDER_DATADIR/discovery-secret
    if [ "$CONDUCTOR_ENABLED" = "true" ]; then
        echo -n "35d2f79381dc94a7818e27c4b130d4ae934550a18787d2ba102b20a26577a172" > $OP_RBUILDER_DATADIR2/discovery-secret
        echo "✅ Set p2p nodekey for op-rbuilder"
    fi
fi

sed_inplace "s/^SEQ_L2_EXECUTION_CLIENT=.*/SEQ_L2_EXECUTION_CLIENT=$SEQ_L2_EXECUTION_CLIENT/" .env
sed_inplace "s/^SEQ_L2_EXECUTION_PORT=.*/SEQ_L2_EXECUTION_PORT=$SEQ_L2_EXECUTION_PORT/" .env

if [ "$SEQ_TYPE" = "reth" ]; then
  echo -n "1aba031aeb5aa8aedadaf04159d20e7d58eeefb3280176c7d59040476c2ab21b" > $OP_RETH_DATADIR/discovery-secret
  if [ "$CONDUCTOR_ENABLED" = "true" ]; then
    echo -n "934ee1c6d37504aa6397b13348d2b5788a0bae5d3a77c71645f8b28be54590d9" > $OP_RETH_DATADIR2/discovery-secret
  fi
    echo "✅ Set p2p nodekey for reth sequencer"
fi

echo "✅ Finished init op-$SEQ_TYPE-seq and op-$RPC_TYPE-rpc."

# genesis.json is too large to embed in go, so we compress it now and decompress it in go code
gzip -c config-op/genesis.json > config-op/genesis.json.gz

# Check if MIN_RUN mode is enabled
if [ "$MIN_RUN" = "true" ]; then
    echo "⚡ MIN_RUN mode enabled: Skipping op-program prestate build"
    echo "✅ Initialization completed for minimal run (no dispute game support)"
    exit 0
fi

# Ensure prestate files exist and devnetL1.json is consistent before deploying contracts
EXPORT_DIR="$PWD_DIR/data/cannon-data"
SAVED_CANNON_DATA_DIR="$PWD_DIR/saved-cannon-data"

if [ "$SKIP_BUILD_PRESTATE" = "true" ] && [ -d "$SAVED_CANNON_DATA_DIR" ]; then
    echo "🔄 Skipping building op-program prestate files. Copying saved cannon data from $SAVED_CANNON_DATA_DIR to $EXPORT_DIR..."
    cp -r $SAVED_CANNON_DATA_DIR $EXPORT_DIR
    exit 0
fi

rm -rf $EXPORT_DIR
mkdir -p $EXPORT_DIR

echo "🔨 Building op-program prestate files..."

# Determine if we are using rootless Docker and set the appropriate Docker command
ROOTLESS_DOCKER=$(docker info -f "{{println .SecurityOptions}}" | grep rootless || true)
if ! [ -z "$ROOTLESS_DOCKER" ]; then
echo "Using rootless Docker!"
DOCKER_CMD="docker run --rm --privileged "
DOCKER_TYPE="rootless"
else
DOCKER_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "
DOCKER_TYPE="default"
fi

# Run the reproducible-prestate command
$DOCKER_CMD \
    -v "$(pwd)/scripts:/scripts" \
    -v "$(pwd)/config-op/rollup.json:/app/op-program/chainconfig/configs/${CHAIN_ID}-rollup.json" \
    -v "$(pwd)/config-op/genesis.json.gz:/app/op-program/chainconfig/configs/${CHAIN_ID}-genesis-l2.json" \
    -v "$(pwd)/l1-geth/execution/genesis.json:/app/op-program/chainconfig/configs/1337-genesis-l1.json" \
    -v "$EXPORT_DIR:/app/op-program/bin" \
    "${OP_STACK_IMAGE_TAG}" \
    bash -c " \
      /scripts/docker-install-start.sh $DOCKER_TYPE
      make -C op-program reproducible-prestate
    "

echo "🔄 Copying built prestate files from $EXPORT_DIR to $SAVED_CANNON_DATA_DIR..."
cp -r $EXPORT_DIR $SAVED_CANNON_DATA_DIR
