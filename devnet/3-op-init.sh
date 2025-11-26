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
# Genesis Mode Detection
# ========================================
detect_genesis_mode() {
    if [ "$USE_MAINNET_GENESIS" = "true" ]; then
        echo "🌐 Mainnet genesis mode enabled"
        
        # Enforce MIN_RUN requirement
        if [ "$MIN_RUN" != "true" ]; then
            echo ""
            echo "❌ ERROR: Mainnet genesis requires MIN_RUN=true"
            echo ""
            echo "Reason:"
            echo "  • Mainnet genesis is too large (6.6GB+)"
            echo "  • Building op-program prestate would fail or timeout"
            echo "  • Dispute game features are not compatible with mainnet data"
            echo ""
            echo "Solution:"
            echo "  Set MIN_RUN=true in your .env file"
            echo ""
            exit 1
        fi
        
        echo "✅ MIN_RUN=true verified"
        return 0
    else
        echo "🔧 Using generated genesis mode"
        return 1
    fi
}

# ========================================
# Prepare Mainnet Genesis
# ========================================
prepare_mainnet_genesis() {
    echo ""
    echo "📦 Preparing mainnet genesis..."
    
    PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Check if genesis file exists
    if [ ! -f "$MAINNET_GENESIS_PATH" ]; then
        echo "🔍 Genesis not found at: $MAINNET_GENESIS_PATH"
        
        # Try to extract from tar.gz
        TAR_PATH="../rpc-setup/genesis-mainnet.tar.gz"
        if [ -f "$TAR_PATH" ]; then
            echo "📂 Extracting from $TAR_PATH..."
            echo "⏳ This may take 2-5 minutes (1.6GB → 6.6GB)..."
            
            tar -xzf "$TAR_PATH" -C "$PWD_DIR"
            
            if [ -f "$PWD_DIR/merged.genesis.json" ]; then
                mv "$PWD_DIR/merged.genesis.json" "$MAINNET_GENESIS_PATH"
                echo "✅ Extracted successfully"
            else
                echo "❌ ERROR: Extraction failed (merged.genesis.json not found)"
                exit 1
            fi
        else
            echo "❌ ERROR: Neither genesis file nor tar.gz found"
            echo "   Looking for:"
            echo "   - $MAINNET_GENESIS_PATH"
            echo "   - $TAR_PATH"
            exit 1
        fi
    fi
    
    # Verify file
    GENESIS_SIZE_MB=$(du -m "$MAINNET_GENESIS_PATH" | cut -f1)
    GENESIS_SIZE_GB=$(echo "scale=2; $GENESIS_SIZE_MB / 1024" | bc)
    echo "✅ Found mainnet genesis ($GENESIS_SIZE_GB GB)"
    
    # Validate configuration
    if [ -z "$FORK_BLOCK" ] || [ -z "$PARENT_HASH" ]; then
        echo "❌ ERROR: FORK_BLOCK and PARENT_HASH must be set"
        exit 1
    fi
    
    NEXT_BLOCK=$((FORK_BLOCK + 1))
    echo "🎯 Fork configuration:"
    echo "   • FORK_BLOCK: $FORK_BLOCK"
    echo "   • PARENT_HASH: $PARENT_HASH"
    echo "   • Next block: $NEXT_BLOCK"
    
    # Process genesis using Python (fast)
    echo ""
    echo "🔧 Processing genesis (this may take 1-2 minutes)..."
    
    mkdir -p "$CONFIG_DIR"
    
    # Prepare arguments
    PROCESS_ARGS=(
        "$MAINNET_GENESIS_PATH"
        "$CONFIG_DIR/genesis.json"
        "$NEXT_BLOCK"
        "$PARENT_HASH"
    )
    
    # Add test account injection if enabled
    if [ "$INJECT_L2_TEST_ACCOUNT" = "true" ]; then
        echo "💰 Test account injection enabled"
        PROCESS_ARGS+=("$TEST_ACCOUNT_ADDRESS" "$TEST_ACCOUNT_BALANCE")
    fi
    
    # Run Python script
    if ! python3 scripts/process-mainnet-genesis.py "${PROCESS_ARGS[@]}"; then
        echo "❌ ERROR: Failed to process mainnet genesis"
        exit 1
    fi
    
    echo ""
    echo "✅ Mainnet genesis prepared"
    echo "   • Output: $CONFIG_DIR/genesis.json"
    echo "   • Reth version: $CONFIG_DIR/genesis-reth.json"
    echo "   • Accounts: $(python3 -c "import json; print(len(json.load(open('$CONFIG_DIR/genesis.json'))['alloc']))")"
    echo ""
}

# Check if FORK_BLOCK is set
if [ -z "$FORK_BLOCK" ]; then
    echo " ❌ FORK_BLOCK environment variable is not set"
    echo "Please set FORK_BLOCK in your .env file"
    exit 1
fi

# ========================================
# Genesis Processing - Mode Selection
# ========================================
if detect_genesis_mode; then
    # Mainnet genesis mode
    prepare_mainnet_genesis
    
    # Update rollup.json
    NEXT_BLOCK_NUMBER=$((FORK_BLOCK + 1))
    sed_inplace 's/"number": 0/"number": '"$NEXT_BLOCK_NUMBER"'/' ./config-op/rollup.json
    
else
    # Generated genesis mode (original logic)
    FORK_BLOCK_HEX=$(printf "0x%x" "$FORK_BLOCK")
    sed_inplace '/"config": {/,/}/ s/"optimism": {/"legacyXLayerBlock": '"$((FORK_BLOCK + 1))"',\n    "optimism": {/' ./config-op/genesis.json
    sed_inplace 's/"parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000"/"parentHash": "'"$PARENT_HASH"'"/' ./config-op/genesis.json
    sed_inplace '/"70997970c51812dc3a010c7d01b50e0d17dc79c8": {/,/}/ s/"balance": "[^"]*"/"balance": "0x446c3b15f9926687d2c40534fdb564000000000000"/' ./config-op/genesis.json
    NEXT_BLOCK_NUMBER=$((FORK_BLOCK + 1))
    NEXT_BLOCK_NUMBER_HEX=$(printf "0x%x" "$NEXT_BLOCK_NUMBER")
    sed_inplace 's/"number": 0/"number": '"$NEXT_BLOCK_NUMBER"'/' ./config-op/rollup.json
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
    echo ""
    echo "⚡ MIN_RUN mode enabled: Skipping op-program prestate build"
    
    # Show mainnet-specific summary
    if [ "$USE_MAINNET_GENESIS" = "true" ]; then
        echo ""
        echo "🌐 Mainnet Genesis Deployment Summary:"
        echo "   • Source: $MAINNET_GENESIS_PATH"
        echo "   • Starting block: $((FORK_BLOCK + 1))"
        echo "   • Genesis size: $(du -h $CONFIG_DIR/genesis.json | cut -f1)"
        
        if [ "$INJECT_L2_TEST_ACCOUNT" = "true" ]; then
            echo "   • Test account: $TEST_ACCOUNT_ADDRESS (injected)"
            BALANCE_ETH=$(python3 -c "print(int('$TEST_ACCOUNT_BALANCE', 16) / 10**18)")
            echo "   • Test balance: $BALANCE_ETH ETH on L2"
        fi
        
        echo "   • Database: $(du -sh data/op-$SEQ_TYPE-seq 2>/dev/null | cut -f1 || echo 'initializing...')"
        echo ""
        echo "ℹ️  Notes:"
        echo "   • All mainnet accounts preserved in L2 genesis"
        echo "   • L1 accounts funded by 1-start-l1.sh (100 ETH each)"
        echo "   • Dispute game features skipped (not compatible with mainnet data)"
    fi
    
    echo ""
    echo "✅ Initialization completed for minimal run"
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
