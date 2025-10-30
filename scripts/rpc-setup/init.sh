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

# Check if .env exists (optional but recommended)
if [ ! -f .env ]; then
    echo "⚠️  Warning: .env file does not exist"
    echo "You can copy env.example to .env and fill in the correct configuration after initialization"
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

# Create shared directories (for non-network-specific files)
mkdir -p data
mkdir -p config

# Download the genesis file to shared config directory
if [ ! -f "config/genesis.json" ]; then
  echo "📥 Downloading genesis file from $GENESIS_URL..."
  wget -c "$GENESIS_URL" -O merged.genesis.json.tar.gz

  # Extract the genesis file
  echo "📦 Extracting genesis file..."
  tar -xzf merged.genesis.json.tar.gz -C config/
  
  # Handle different genesis file names
  if [ -f "config/merged.genesis.json" ]; then
      mv config/merged.genesis.json config/genesis.json
  fi

  # Clean up the downloaded archive
  echo "🧹 Cleaning up downloaded archive..."
  rm merged.genesis.json.tar.gz

  echo "✅ Genesis file extracted successfully to config/genesis.json"
fi

# Prepare genesis file for Reth RPC (if doesn't exist)
sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

if [ ! -f "config/genesis-reth.json" ]; then
  echo "🔧 Generating genesis-reth.json for op-reth..."
  cp config/genesis.json config/genesis-reth.json
  BLKNO=$(grep "legacyXLayerBlock" config/genesis.json | tr -d ', ' | cut -d ':' -f 2)
  if [ -z "$BLKNO" ]; then
    echo "❌ Error: Failed to extract legacyXLayerBlock from genesis.json"
    exit 1
  fi
  sed_inplace 's/"number": "0x0"/"number": "'"$BLKNO"'"/' ./config/genesis-reth.json
  echo "✅ Genesis file for op-reth extracted successfully to config/genesis-reth.json"
fi

# Load L2_ENGINEKIND from .env if it exists, default to geth
L2_ENGINEKIND="geth"
if [ -f .env ]; then
    source .env
    L2_ENGINEKIND="${L2_ENGINEKIND:-geth}"
fi

echo "🔍 Execution engine type: $L2_ENGINEKIND"

# Initialize execution client based on engine type
if [ "${L2_ENGINEKIND}" = "geth" ] || [ "${L2_ENGINEKIND}" = "reth" ]; then
  if [ "${L2_ENGINEKIND}" = "geth" ]; then
    # Initialize op-geth with the genesis file
    echo "🔧 Initializing op-geth with genesis file... (It may take a while, please wait patiently.)"
    docker run --rm \
      -v "$(pwd)/data/op-geth:/data" \
      -v "$(pwd)/config/genesis.json:/genesis.json" \
      ${OP_GETH_IMAGE_TAG} \
      --datadir /data \
      --gcmode=archive \
      --db.engine=pebble \
      --log.format json \
      init \
      --state.scheme=hash \
      /genesis.json
  else
    # For op-reth, initialization happens on first run
    echo "🔧 op-reth will initialize on first run"
    mkdir -p data/op-reth
  fi
else
  echo "❌ Error: Unknown L2_ENGINEKIND: ${L2_ENGINEKIND}"
  exit 1
fi

echo "✅ X Layer RPC node initialization completed!"
echo ""
echo "📁 Generated directories:"
echo "  - data/: Contains blockchain data"
echo "  - data/op-geth/: op-geth blockchain data"
echo "  - data/op-reth/: op-reth blockchain data (if using reth)"
echo "  - data/op-node/: op-node data"
echo "  - config/: Contains configuration files (genesis.json, genesis-reth.json)"
echo ""
echo "📝 Next steps:"
echo "  1. Copy env.example to .env and configure your settings (if not done yet)"
echo "  2. Run ./start.sh $NETWORK_TYPE to start the node"
