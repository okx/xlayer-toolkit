#!/bin/bash
# init.sh

set -e

# Parse command line arguments
NETWORK_TYPE=${1:-""}

# Validate network type
if [ -z "$NETWORK_TYPE" ]; then
    echo "❌ Error: Network type is required"
    echo "Usage: $0 [testnet|mainnet]"
    exit 1
fi

if [ "$NETWORK_TYPE" != "testnet" ] && [ "$NETWORK_TYPE" != "mainnet" ]; then
    echo "❌ Error: Invalid network type. Please use 'testnet' or 'mainnet'"
    echo "Usage: $0 [testnet|mainnet]"
    exit 1
fi

# Testnet configuration
TESTNET_OP_GETH_IMAGE="xlayer/op-geth:v0.0.6"
TESTNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"

# Mainnet configuration
MAINNET_OP_GETH_IMAGE="xlayer/op-geth:v0.0.6"
MAINNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"

# Load network-specific configuration
case "$NETWORK_TYPE" in
    testnet)
        OP_GETH_IMAGE_TAG="$TESTNET_OP_GETH_IMAGE"
        GENESIS_URL="$TESTNET_GENESIS_URL"
        ;;
    mainnet)
        OP_GETH_IMAGE_TAG="$MAINNET_OP_GETH_IMAGE"
        GENESIS_URL="$MAINNET_GENESIS_URL"
        ;;
    *)
        echo "❌ Error: Unknown network type: $NETWORK_TYPE"
        exit 1
        ;;
esac

echo "🚀 Initializing X Layer Self-hosted RPC node for $NETWORK_TYPE network..."

# Network-specific directories and files
DATA_DIR="data-${NETWORK_TYPE}"
CONFIG_DIR="config-${NETWORK_TYPE}"
GENESIS_FILE="genesis-${NETWORK_TYPE}.json"

mkdir -p "$DATA_DIR" "$CONFIG_DIR"

# Download the genesis file
echo "📥 Downloading genesis file from $GENESIS_URL..."
wget -c "$GENESIS_URL" -O genesis.tar.gz

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

# Initialize op-geth with the genesis file
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

echo "✅ X Layer RPC node initialization completed!"
echo ""
echo "📁 Generated directories for $NETWORK_TYPE:"
echo "  - $DATA_DIR/: Contains op-geth blockchain data"
echo "  - $CONFIG_DIR/: Contains configuration files"
