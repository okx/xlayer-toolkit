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

# Check if FORK_BLOCK is set
if [ -z "$FORK_BLOCK" ]; then
    echo " ❌ FORK_BLOCK environment variable is not set"
    echo "Please set FORK_BLOCK in your .env file"
    exit 1
fi

echo "🔧 Setting fork block and parent hash in genesis.json ..."
FORK_BLOCK_HEX=$(printf "0x%x" "$FORK_BLOCK")
sed_inplace '/"config": {/,/}/ s/"optimism": {/"legacyXLayerBlock": '"$((FORK_BLOCK + 1))"',\n    "optimism": {/' ./config-op/genesis.json
sed_inplace 's/"parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000"/"parentHash": "'"$PARENT_HASH"'"/' ./config-op/genesis.json
sed_inplace '/"70997970c51812dc3a010c7d01b50e0d17dc79c8": {/,/}/ s/"balance": "[^"]*"/"balance": "0x446c3b15f9926687d2c40534fdb564000000000000"/' ./config-op/genesis.json
sed_inplace 's/"eip1559DenominatorCanyon": [0-9]*/"eip1559DenominatorCanyon": '"$(jq -r '.config.optimism.eip1559Denominator' ./config-op/genesis.json)"'/' ./config-op/genesis.json
NEXT_BLOCK_NUMBER=$((FORK_BLOCK + 1))
NEXT_BLOCK_NUMBER_HEX=$(printf "0x%x" "$NEXT_BLOCK_NUMBER")
sed_inplace 's/"number": 0/"number": '"$NEXT_BLOCK_NUMBER"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559Elasticity": [0-9]*/"eip1559Elasticity": '"$(jq -r '.config.optimism.eip1559Elasticity' ./config-op/genesis.json)"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559Denominator": [0-9]*/"eip1559Denominator": '"$(jq -r '.config.optimism.eip1559Denominator' ./config-op/genesis.json)"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559DenominatorCanyon": [0-9]*/"eip1559DenominatorCanyon": '"$(jq -r '.config.optimism.eip1559DenominatorCanyon' ./config-op/genesis.json)"'/' ./config-op/rollup.json

# 🔧 Seed the deterministic CREATE2 deploy factory into the L2 genesis. ALWAYS injected: it is a
# generic stateless CREATE2 deployer used by DeployXlayerGaslessWhitelist.s.sol.
./scripts/inject-deploy-factory.sh

if [ "$MERGE_RETH_GENESIS" = "true" ]; then
    echo "🔧 Merging genesis files..."

    if [ -z "$MERGE_RETH_DATADIR_PATH" ]; then
        echo " ❌ MERGE_RETH_DATADIR_PATH environment variable is not set"
        echo "Please set MERGE_RETH_DATADIR_PATH in your .env file"
        exit 1
    fi

    docker run --rm -v "./config-op:/config-op" -v "$MERGE_RETH_DATADIR_PATH:/reth-datadir" $XLAYER_RETH_TOOLS_IMAGE_TAG \
        gen-genesis --datadir /reth-datadir --chain $MERGE_RETH_CHAIN \
        --template-genesis /config-op/genesis.json --output /config-op/genesis-reth.json --output-chainspec /config-op/xlayer-devnet.json
    FORK_BLOCK=$(($(cast to-dec $(jq .number config-op/xlayer-devnet.json|tr -d '"'))-1))
    echo "FORK_BLOCK=$FORK_BLOCK"
    sed_inplace "s/FORK_BLOCK=.*/FORK_BLOCK=$FORK_BLOCK/" .env
    jq '.genesis.l2.number = '"$((FORK_BLOCK+1))" ./config-op/rollup.json > tmp.json && mv tmp.json ./config-op/rollup.json
else
    # Create genesis-reth.json from genesis.json
    echo "🔧 Creating genesis-reth.json from genesis.json ..."
    cp ./config-op/genesis.json ./config-op/genesis-reth.json
    sed_inplace 's/"number": "0x0"/"number": "'"$NEXT_BLOCK_NUMBER_HEX"'"/' ./config-op/genesis-reth.json
fi

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

# Setup System Config Parameters after extracting addresses and updating .env
echo ""
echo "🔧 Setting up System Config Parameters..."
"$PWD_DIR/scripts/setup-system-config-params.sh"

# init geth sequencer (only when the sequencer is geth; skipped for a reth devnet
# so it doesn't require the op-geth image)
if [ "$SEQ_TYPE" = "geth" ]; then
  echo " 🔧 Initializing geth sequencer..."
  OP_GETH_DATADIR="$(pwd)/data/op-geth-seq"
  rm -rf "$OP_GETH_DATADIR"
  mkdir -p "$OP_GETH_DATADIR"

  # Override the entrypoint so init and the nodekey removal happen in the SAME
  # root container.
  docker compose run --no-deps --rm \
    --entrypoint sh \
    -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json" \
    op-geth-seq \
    -c "geth --datadir=/datadir --gcmode=archive --db.engine=$DB_ENGINE init --state.scheme=hash /genesis.json && \
        echo ' 🔑 Removing nodekey to generate unique node ID for other nodes...' && \
        rm -f /datadir/geth/nodekey"
fi

# Get trusted peers enode url
sed_inplace "s|TRUSTED_PEERS=.*|TRUSTED_PEERS=$(./scripts/trusted-peers.sh)|" .env

# Apply the trusted_nodes_only toggle (TRUSTED_NODES_ONLY in .env) to the reth
# seq/rpc configs. When true, reth >=2.2 peers only with TRUSTED_PEERS; when
# false it also accepts untrusted peers.
TRUSTED_NODES_ONLY="${TRUSTED_NODES_ONLY:-true}"
sed_inplace "s/^trusted_nodes_only = .*/trusted_nodes_only = ${TRUSTED_NODES_ONLY}/" ./config-op/test.reth.seq.config.toml
sed_inplace "s/^trusted_nodes_only = .*/trusted_nodes_only = ${TRUSTED_NODES_ONLY}/" ./config-op/test.reth.rpc.config.toml

# init reth sequencer
echo " 🔧 Initializing reth sequencer..."
OP_RETH_DATADIR="$(pwd)/data/op-reth-seq"
OP_RETH_DATADIR2="$(pwd)/data/op-reth-seq2"

rm -rf "$OP_RETH_DATADIR"
mkdir -p "$OP_RETH_DATADIR"

# Build storage flags for op-reth init so the DB is initialized with the
# correct storage_v2 setting (it is written at genesis time and cannot be
# changed later without a full re-sync).
RETH_INIT_STORAGE_FLAGS=""
if [ "${RETH_STORAGE_V2:-false}" = "true" ]; then
    if [ -n "${RETH_ROCKSDB_PATH:-}" ]; then
        RETH_INIT_STORAGE_FLAGS="$RETH_INIT_STORAGE_FLAGS --datadir.rocksdb=$RETH_ROCKSDB_PATH"
    fi
else
    # Opt out of storage v2 — but only if this op-reth build actually exposes the
    # flag. Newer upstream reth (>= v1.11.0) defaults to storage v2 and needs the
    # explicit opt-out; the xlayer gasless reth build has no --storage.v2 flag and
    # would abort init with "unexpected argument '--storage.v2'".
    if docker run --rm --entrypoint op-reth "$OP_RETH_IMAGE_TAG" init --help 2>/dev/null | grep -q -- '--storage.v2'; then
        RETH_INIT_STORAGE_FLAGS="--storage.v2=false"
    else
        echo " ℹ️ op-reth build has no --storage.v2 flag; skipping it"
    fi
fi

# Capture stdout+stderr so a failed init leaves a diagnosable init.log instead of
# an empty one. PIPESTATUS[0] is op-reth's exit code (tee always succeeds).
docker compose run --no-deps --rm \
  -v "$(pwd)/$CONFIG_DIR/genesis-reth.json:/genesis.json" \
  --entrypoint op-reth \
  op-reth-seq \
  init \
  --datadir="/datadir" \
  --chain=/genesis.json \
  $RETH_INIT_STORAGE_FLAGS \
  --log.stdout.format=json 2>&1 | tee init.log
INIT_RC=${PIPESTATUS[0]}
if [ "$INIT_RC" -ne 0 ]; then
    echo " ❌ op-reth init failed (exit $INIT_RC). Last log lines:"
    tail -n 20 init.log
    exit 1
fi

# Pick the genesis hash from the JSON log line that actually carries it, rather
# than blindly taking the last line (later lines / stderr may not have .fields.hash).
NEW_BLOCK_HASH=$(grep '"hash"' init.log | tail -n 1 | jq -r '.fields.hash // empty' 2>/dev/null)
if [ -z "$NEW_BLOCK_HASH" ] || [ "$NEW_BLOCK_HASH" = "null" ]; then
    echo " ❌ Could not parse genesis hash from op-reth init output (NEW_BLOCK_HASH would be empty). Last log lines:"
    tail -n 20 init.log
    exit 1
fi
echo "NEW_BLOCK_HASH=$NEW_BLOCK_HASH"
sed_inplace "s/NEW_BLOCK_HASH=.*/NEW_BLOCK_HASH=$NEW_BLOCK_HASH/" .env

if [ "${USE_CHAINSPEC:-false}" = "true" ]; then
    if [ -z "$OP_RETH_LOCAL_DIRECTORY" ]; then
        echo " ❌ OP_RETH_LOCAL_DIRECTORY environment variable is not set."
        echo "This is required to re-build op-reth with chainspec."
        echo "Please set OP_RETH_LOCAL_DIRECTORY in your .env file"
        exit 1
    fi
    cd "$OP_RETH_LOCAL_DIRECTORY"
    if [ ! -f "crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt" ]; then
        echo " ❌ crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt not found."
        echo "This is required to re-build op-reth with chainspec."
        echo "Please run 'just build-docker' to build op-reth with chainspec."
        exit 1
    fi
    echo $NEW_BLOCK_HASH > crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt
    cp $PWD_DIR/config-op/xlayer-devnet.json crates/chainspec/res/genesis/xlayer-devnet.json
    just build-docker
    cd "$PWD_DIR"

    if [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
        echo " 🔄 Copying database from op-reth-seq to op-reth-rpc..."
        cp -r $OP_RETH_DATADIR "$(pwd)/data/op-reth-rpc"
    fi
fi

# Initialize the op-geth-rpc datadir whenever the RPC node is geth.
# - geth sequencer: copy the already-initialized op-geth-seq datadir.
# - reth sequencer: op-geth-seq is never initialized, so init op-geth-rpc directly
#   from genesis.json. Otherwise geth boots an empty datadir and falls back to the
#   default Ethereum mainnet config (chainId 1) instead of $CHAIN_ID.
if [ "$RPC_TYPE" = "geth" ]; then
  OP_GETH_RPC_DATADIR="$(pwd)/data/op-geth-rpc"
  rm -rf "$OP_GETH_RPC_DATADIR"

  if [ "$SEQ_TYPE" = "geth" ]; then
    echo " 🔄 Copying database from op-geth-seq to op-geth-rpc..."
    # The source datadir is root-owned (written by the init container), so a
    # host-side `cp` runs as the unprivileged user and fails with "Permission
    # denied". Copy inside a root container instead.
    docker run --rm -v "$(pwd)/data:/data" --entrypoint sh "$OP_GETH_IMAGE_TAG" \
      -c "rm -rf /data/op-geth-rpc && cp -r /data/op-geth-seq /data/op-geth-rpc"
  else
    echo " 🔧 Initializing op-geth-rpc from genesis.json (reth sequencer)..."
    mkdir -p "$OP_GETH_RPC_DATADIR"
    # Override the entrypoint: op-geth-rpc's default entrypoint (geth-rpc.sh) starts
    # a full node and never returns, so we invoke geth directly for `init`. The
    # nodekey is removed (for a unique node ID, like the geth sequencer init) in the
    # same root container, because the datadir is written as root and the host user
    # cannot delete files under it.
    docker compose run --no-deps --rm \
      --entrypoint sh \
      -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json" \
      op-geth-rpc \
      -c "geth --datadir=/datadir --gcmode=archive --db.engine=$DB_ENGINE init --state.scheme=hash /genesis.json && rm -f /datadir/geth/nodekey"
  fi
fi

if [ "$LAUNCH_RPC_NODE2" = "true" ] && [ "$RPC_TYPE" = "geth" ]; then
    OP_GETH_RPC2_DATADIR="$(pwd)/data/op-geth-rpc2"
    # Source from op-geth-rpc, which is genesis-initialized above for either
    # sequencer type (op-geth-seq only exists when SEQ_TYPE=geth).
    echo " 🔄 Copying database from op-geth-rpc to op-geth-rpc2..."
    # Source datadir is root-owned (container-written); copy inside a root
    # container so the unprivileged host user doesn't hit "Permission denied".
    docker run --rm -v "$(pwd)/data:/data" --entrypoint sh "$OP_GETH_IMAGE_TAG" \
      -c "rm -rf /data/op-geth-rpc2 && cp -r /data/op-geth-rpc /data/op-geth-rpc2"
fi

if [ "$LAUNCH_RPC_NODE2" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
    echo " 🔄 Copying database from op-reth-seq to op-reth-rpc2..."
    cp -r $OP_RETH_DATADIR "$(pwd)/data/op-reth-rpc2"
fi

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
    if [ "$SEQ_TYPE" = "geth" ]; then
        # op-geth-seq is already genesis-initialized above; clone it.
        cp -r "$OP_GETH_DATADIR" "$OP_GETH_DATADIR3"
    else
        # Sequencer EL is reth, so op-geth-seq was never initialized and
        # OP_GETH_DATADIR is unset. Initialize op-geth-seq3 directly from
        # genesis.json (same approach as the op-geth-rpc reth-sequencer path).
        echo " 🔧 Initializing op-geth-seq3 from genesis.json (reth sequencer)..."
        mkdir -p "$OP_GETH_DATADIR3"
        docker compose run --no-deps --rm \
          --entrypoint sh \
          -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json" \
          op-geth-seq3 \
          -c "geth --datadir=/datadir --gcmode=archive --db.engine=$DB_ENGINE init --state.scheme=hash /genesis.json && rm -f /datadir/geth/nodekey"
    fi
fi

if [ "$SEQ_TYPE" = "reth" ]; then
  echo -n "1aba031aeb5aa8aedadaf04159d20e7d58eeefb3280176c7d59040476c2ab21b" > $OP_RETH_DATADIR/discovery-secret
  if [ "$CONDUCTOR_ENABLED" = "true" ]; then
    echo -n "934ee1c6d37504aa6397b13348d2b5788a0bae5d3a77c71645f8b28be54590d9" > $OP_RETH_DATADIR2/discovery-secret
    if [ "$FLASHBLOCK_ENABLED" = "true" ]; then
        echo -n "60a4284707ef52c2b8486410be2bc7bf3bf803fcd85f0059b87b8b772eba62b421ef496e2a44135cfd9e74133e2e2b3e30a4a6c428d3f41e3537eea14eaf9ea3" > $OP_RETH_DATADIR/fb-p2p-key
        echo -n "6c899cb8b6dadfc34ddde60a57a61b3bdc655247a72feae16b851204fd41596f67a5e73ff50c90ec1755bcf640de7333322cce8612f722732f1244af23be007a" > $OP_RETH_DATADIR2/fb-p2p-key
    fi
  fi
    echo "✅ Set p2p nodekey for reth sequencer"
fi

# Seed a FIXED devp2p secret for the reth RPC node so it has a deterministic
# enode id (61478df8…dc8213e3) that the sequencer trusts (see
# scripts/trusted-peers.sh). reth >=2.2 rejects untrusted *inbound* connections
# when trusted_nodes_only=true, so without a known, trusted id the sequencer
# disconnects the replica and it never syncs.
#
# This runs regardless of USE_CHAINSPEC: in the chainspec path the datadir was
# already copied from the sequencer above; otherwise the dir may not exist yet
# (reth initializes the db from genesis on first start), so create it here.
if [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
  mkdir -p "$(pwd)/data/op-reth-rpc"
  echo -n "357d05aeb6a2660667e6affd9dc6704a4e70f953e2675241f691859185e8cf2c" > "$(pwd)/data/op-reth-rpc/discovery-secret"
  echo "✅ Set fixed p2p nodekey for reth rpc node"
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
