#!/bin/bash
# init.sh

set -e

LOCAL_GENESIS_TESTNET="/Users/oker/Downloads/merged.genesis.json.testnet.tar.gz"
LOCAL_GENESIS_MAINNET="/Users/oker/Downloads/merged.genesis.json.mainnet.tar.gz"

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
TESTNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
TESTNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"

# Mainnet configuration
MAINNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
MAINNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz"

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

# Load environment variables if .env exists (for CHAIN_DATA_ROOT and L2_ENGINEKIND)
if [ -f .env ]; then
    source .env
fi

# Set L2_ENGINEKIND default if not set
L2_ENGINEKIND="${L2_ENGINEKIND:-geth}"

# Data root directory (can be overridden via .env)
CHAIN_DATA_ROOT="${CHAIN_DATA_ROOT:-chaindata}"

# Network and engine specific directory structure
# Format: chaindata/{network}-{engine}/
CHAIN_DATA_DIR="$CHAIN_DATA_ROOT/${NETWORK_TYPE}-${L2_ENGINEKIND}"
DATA_DIR="$CHAIN_DATA_DIR/data"
CONFIG_DIR="$CHAIN_DATA_DIR/config"
LOGS_DIR="$CHAIN_DATA_DIR/logs"
# Use simple filename without network suffix (directory already contains network info)
GENESIS_FILE="genesis.json"

echo "📁 Data will be stored in: $CHAIN_DATA_DIR"

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node" "$LOGS_DIR/op-reth"

# Download the genesis file to chaindata directory
GENESIS_TAR_PATH="$CHAIN_DATA_DIR/genesis.tar.gz"

# Select local genesis file based on network type
if [ "$NETWORK_TYPE" = "testnet" ]; then
    LOCAL_GENESIS_FILE="$LOCAL_GENESIS_TESTNET"
else
    LOCAL_GENESIS_FILE="$LOCAL_GENESIS_MAINNET"
fi

# Check if local genesis file is configured and exists
if [ -n "$LOCAL_GENESIS_FILE" ] && [ -f "$LOCAL_GENESIS_FILE" ]; then
    echo "📋 Using local pre-downloaded genesis file: $LOCAL_GENESIS_FILE"
    echo "📁 Copying to: $GENESIS_TAR_PATH"
    cp "$LOCAL_GENESIS_FILE" "$GENESIS_TAR_PATH"
    USE_LOCAL_GENESIS=true
elif [ -n "$LOCAL_GENESIS_FILE" ]; then
    echo "⚠️  Local genesis file configured but not found: $LOCAL_GENESIS_FILE"
    echo "⬇️  Falling back to download from network..."
    echo "📥 Downloading genesis file from $GENESIS_URL..."
    echo "📁 Download location: $GENESIS_TAR_PATH"
    wget -c "$GENESIS_URL" -O "$GENESIS_TAR_PATH"
    USE_LOCAL_GENESIS=false
else
    # No local path configured, download from network
    echo "📥 Downloading genesis file from $GENESIS_URL..."
    echo "📁 Download location: $GENESIS_TAR_PATH"
    wget -c "$GENESIS_URL" -O "$GENESIS_TAR_PATH"
    USE_LOCAL_GENESIS=false
fi

# Extract the genesis file
echo "📦 Extracting genesis file..."
tar -xzf "$GENESIS_TAR_PATH" -C "$CONFIG_DIR/"

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
if [ "$USE_LOCAL_GENESIS" = "true" ]; then
    # Keep the file when using local genesis (for reuse)
    echo "ℹ️  Keeping genesis archive for reuse: $GENESIS_TAR_PATH"
else
    # Remove the file when downloaded from network
    echo "🧹 Cleaning up downloaded archive..."
    rm "$GENESIS_TAR_PATH"
    echo "✅ Temporary file removed: $GENESIS_TAR_PATH"
fi

# Check if genesis file exists
if [ ! -f "$CONFIG_DIR/$GENESIS_FILE" ]; then
    echo "❌ Error: Failed to extract genesis file"
    exit 1
fi

echo "✅ Genesis file extracted successfully to $CONFIG_DIR/$GENESIS_FILE"

# Determine config file names based on network
if [ "$NETWORK_TYPE" = "testnet" ]; then
    ROLLUP_CONFIG="rollup-testnet.json"
    GETH_CONFIG="op-geth-config-testnet.toml"
else
    ROLLUP_CONFIG="rollup-mainnet.json"
    GETH_CONFIG="op-geth-config-mainnet.toml"
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

if [ -f "config/$GETH_CONFIG" ]; then
    cp "config/$GETH_CONFIG" "$CONFIG_DIR/"
    echo "✅ Copied $GETH_CONFIG"
else
    echo "❌ Error: Configuration file config/$GETH_CONFIG does not exist"
    exit 1
fi

# Modify genesis file for Reth if needed (reth needs different "number" value)
if [ "$L2_ENGINEKIND" = "reth" ]; then
  echo "📋 Modifying genesis.json for op-reth (updating number field)..."
  
  sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "$@"
    else
      sed -i "$@"
    fi
  }
  
  BLKNO=$(grep "legacyXLayerBlock" "$CONFIG_DIR/$GENESIS_FILE" | tr -d ', ' | cut -d ':' -f 2)
  if [ -z "$BLKNO" ]; then
    echo "❌ Error: Failed to extract legacyXLayerBlock from $GENESIS_FILE"
    exit 1
  fi
  sed_inplace 's/"number": "0x0"/"number": "'"$BLKNO"'"/' "$CONFIG_DIR/$GENESIS_FILE"
  echo "✅ Genesis file modified for op-reth (number set to $BLKNO)"
fi

# Initialize based on L2_ENGINEKIND
if [ "$L2_ENGINEKIND" = "geth" ]; then
    # Initialize op-geth with the genesis file (geth requires init)
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
    echo "✅ op-geth initialization completed!"
else
    # op-reth does not need init command, it will load genesis on first start
    echo "ℹ️  op-reth does not require initialization"
    echo "ℹ️  Genesis file will be loaded automatically on first start"
    echo "✅ op-reth configuration ready!"
fi

echo "✅ X Layer RPC node initialization completed!"
echo ""
echo "📁 Generated directories for $NETWORK_TYPE:"
echo "  - $DATA_DIR/: Contains op-geth blockchain data"
echo "  - $CONFIG_DIR/: Contains configuration files (genesis, rollup, and geth config)"
echo "  - $LOGS_DIR/: Contains log files"
