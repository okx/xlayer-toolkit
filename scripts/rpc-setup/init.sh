#!/bin/bash
# init.sh

set -e

# Genesis file local paths (if files exist locally, they will be used instead of downloading)
LOCAL_TESTNET_GENESIS="/Users/oker/Downloads/merged.genesis.json.testnet.tar.gz"
LOCAL_MAINNET_GENESIS="/Users/oker/Downloads/merged.genesis.json.mainnet.tar.gz"

# Parse command line arguments
NETWORK_TYPE=${1:-""}
RPC_TYPE=${2:-"geth"}

# Validate network type
if [ -z "$NETWORK_TYPE" ]; then
    echo "❌ Error: Network type is required"
    echo "Usage: $0 [testnet|mainnet] [geth|reth]"
    exit 1
fi

if [ "$NETWORK_TYPE" != "testnet" ] && [ "$NETWORK_TYPE" != "mainnet" ]; then
    echo "❌ Error: Invalid network type. Please use 'testnet' or 'mainnet'"
    echo "Usage: $0 [testnet|mainnet] [geth|reth]"
    exit 1
fi

# Validate RPC type
if [ "$RPC_TYPE" != "geth" ] && [ "$RPC_TYPE" != "reth" ]; then
    echo "❌ Error: Invalid RPC type. Please use 'geth' or 'reth'"
    echo "Usage: $0 [testnet|mainnet] [geth|reth]"
    exit 1
fi

# Testnet configuration
TESTNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
TESTNET_OP_RETH_IMAGE="xlayer/op-reth:release-testnet"
TESTNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"

# Mainnet configuration
MAINNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
MAINNET_OP_RETH_IMAGE="xlayer/op-reth:release-testnet"
MAINNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz"

# Load network-specific configuration
case "$NETWORK_TYPE" in
    testnet)
        OP_GETH_IMAGE_TAG="$TESTNET_OP_GETH_IMAGE"
        OP_RETH_IMAGE_TAG="$TESTNET_OP_RETH_IMAGE"
        GENESIS_URL="$TESTNET_GENESIS_URL"
        ;;
    mainnet)
        OP_GETH_IMAGE_TAG="$MAINNET_OP_GETH_IMAGE"
        OP_RETH_IMAGE_TAG="$MAINNET_OP_RETH_IMAGE"
        GENESIS_URL="$MAINNET_GENESIS_URL"
        ;;
    *)
        echo "❌ Error: Unknown network type: $NETWORK_TYPE"
        exit 1
        ;;
esac

# Set execution client image based on RPC type
if [ "$RPC_TYPE" = "reth" ]; then
    EXEC_IMAGE_TAG="$OP_RETH_IMAGE_TAG"
    EXEC_CLIENT="op-reth"
else
    EXEC_IMAGE_TAG="$OP_GETH_IMAGE_TAG"
    EXEC_CLIENT="op-geth"
fi

echo "🚀 Initializing X Layer Self-hosted RPC node for $NETWORK_TYPE network with $RPC_TYPE..."

# Unified chaindata directory structure
CHAINDATA_BASE="chaindata/${NETWORK_TYPE}-${RPC_TYPE}"
DATA_DIR="${CHAINDATA_BASE}/data"
CONFIG_DIR="${CHAINDATA_BASE}/config"
LOGS_DIR="${CHAINDATA_BASE}/logs"
GENESIS_FILE="genesis-${NETWORK_TYPE}.json"

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node"

# Determine local genesis file path
if [ "$NETWORK_TYPE" = "testnet" ]; then
    LOCAL_GENESIS="$LOCAL_TESTNET_GENESIS"
else
    LOCAL_GENESIS="$LOCAL_MAINNET_GENESIS"
fi

# Check if local genesis file exists
if [ -f "$LOCAL_GENESIS" ]; then
    echo "📥 Using local genesis file: $LOCAL_GENESIS"
    cp "$LOCAL_GENESIS" genesis.tar.gz
else
    echo "📥 Local genesis file not found, downloading from $GENESIS_URL..."
    wget -c "$GENESIS_URL" -O genesis.tar.gz
fi

# Extract the genesis file
echo "📦 Extracting genesis file..."
tar -xzf genesis.tar.gz -C "$CONFIG_DIR/"

# Handle different genesis file names and rename to network-specific name
if [ -f "$CONFIG_DIR/merged.genesis.json" ]; then
    mv "$CONFIG_DIR/merged.genesis.json" "$CONFIG_DIR/$GENESIS_FILE"
elif [ -f "$CONFIG_DIR/genesis.json" ]; then
    mv "$CONFIG_DIR/genesis.json" "$CONFIG_DIR/$GENESIS_FILE"
else
    echo "❌ Error: Failed to find genesis.json in the archive"
    exit 1
fi

# Clean up the downloaded archive
echo "🧹 Cleaning up downloaded archive..."
rm genesis.tar.gz

# Check if genesis file exists
if [ ! -f "$CONFIG_DIR/$GENESIS_FILE" ]; then
    echo "❌ Error: Failed to extract genesis file"
    exit 1
fi

echo "✅ Genesis file extracted successfully to $CONFIG_DIR/$GENESIS_FILE"

# Determine config file names based on network and RPC type
if [ "$NETWORK_TYPE" = "testnet" ]; then
    ROLLUP_CONFIG="rollup-testnet.json"
    if [ "$RPC_TYPE" = "reth" ]; then
        EXEC_CONFIG="op-reth-config-testnet.toml"
    else
        EXEC_CONFIG="op-geth-config-testnet.toml"
    fi
else
    ROLLUP_CONFIG="rollup-mainnet.json"
    if [ "$RPC_TYPE" = "reth" ]; then
        EXEC_CONFIG="op-reth-config-mainnet.toml"
    else
        EXEC_CONFIG="op-geth-config-mainnet.toml"
    fi
fi

# Copy configuration files from config/ directory
echo "📋 Copying configuration files..."
if [ -f "config/$ROLLUP_CONFIG" ]; then
    cp "config/$ROLLUP_CONFIG" "$CONFIG_DIR/"
    echo "✅ Copied $ROLLUP_CONFIG"
else
    echo "❌ Error: Configuration file config/$ROLLUP_CONFIG does not exist"
    exit 1
fi

if [ -f "config/$EXEC_CONFIG" ]; then
    cp "config/$EXEC_CONFIG" "$CONFIG_DIR/"
    echo "✅ Copied $EXEC_CONFIG"
else
    echo "❌ Error: Configuration file config/$EXEC_CONFIG does not exist"
    exit 1
fi

# Initialize execution client with the genesis file
if [ "$RPC_TYPE" = "reth" ]; then
    echo "✅ op-reth setup completed!"
    echo "ℹ️  Note: op-reth does not require separate initialization."
    echo "ℹ️  It will automatically initialize on first startup."
else
    echo "🔧 Initializing op-geth with genesis file... (It may take a while, please wait patiently.)"
    docker run --rm \
        -v "$(pwd)/$DATA_DIR:/data" \
        -v "$(pwd)/$CONFIG_DIR/$GENESIS_FILE:/genesis.json" \
        ${OP_GETH_IMAGE_TAG} \
        --datadir /data \
        --gcmode=archive \
        --db.engine=pebble \
        --log.format json \
        init \
        --state.scheme=hash \
        /genesis.json
fi

echo "✅ X Layer RPC node initialization completed!"
echo ""
echo "📁 Generated directories for $NETWORK_TYPE with $RPC_TYPE:"
echo "  - $DATA_DIR/: Contains $EXEC_CLIENT blockchain data"
echo "  - $CONFIG_DIR/: Contains configuration files (genesis, rollup, and exec client config)"
echo "  - $LOGS_DIR/: Contains log files"
