#!/bin/bash
# scripts/start.sh

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

echo "🚀 Starting X Layer Self-hosted RPC node for $NETWORK_TYPE network..."

# Check environment variables file
if [ ! -f .env ]; then
    echo "❌ Error: .env file does not exist"
    echo "Please copy env.example to .env and fill in the correct configuration"
    exit 1
fi

# Load environment variables
source .env

if [ "${RPC_TYPE}" = "op-reth" ]; then
    echo "🔍 RPC type: op-reth"
else
    echo "🔍 RPC type: op-geth"
fi

# Check required environment variables
required_vars=("L1_RPC_URL" "L1_BEACON_URL" "OP_NODE_BOOTNODE" "OP_GETH_BOOTNODE")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Environment variable $var is not set"
        exit 1
    fi
done

# Create necessary directories
echo "📁 Creating data directories..."
mkdir -p data/op-node/p2p
mkdir -p config

# Check configuration files
echo "🔍 Checking configuration files..."
if [ "$RPC_TYPE" = "op-reth" ]; then
    config_files=("config/rollup.json" "config/genesis-reth.json")
else
    config_files=("config/rollup.json" "config/genesis.json")
fi
for file in "${config_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Error: Configuration file $file does not exist"
        echo "Please place X Layer configuration files in the config/ directory"
        exit 1
    fi
done

# Generate JWT secret (if it does not exist)
if [ ! -s config/jwt.txt ]; then
    echo "🔑 Generating JWT secret..."
    openssl rand -hex 32 > config/jwt.txt
fi

# Start services
echo "🐳 Starting Docker services..."
if [ "$RPC_TYPE" = "op-reth" ]; then
    OP_RETH_WAIT_TIME=60
    OP_RETH_DATA_DIR="./data/op-reth"
    if [ ! -d "$OP_RETH_DATA_DIR" ]; then
        # Wait for 3 minutes if the data directory does not exist
        OP_RETH_WAIT_TIME=180
    fi
    echo "⏳ Starting op-reth service first and wait $OP_RETH_WAIT_TIME seconds for it to load the genesis..."
    docker compose up -d op-reth
    sleep $OP_RETH_WAIT_TIME
    echo "🚀 Starting op-node service..."
fi
docker compose up -d op-node

# Wait for services to start
echo "⏳ Waiting for services to start..."
sleep 10

# Check service status
echo "🔍 Checking service status..."
docker compose ps

echo "✅ X Layer RPC node startup completed!"

echo ""
echo "📋 Service Information:"
echo "======================"
echo ""
echo "🔍 View service logs:"
echo "  docker logs -f xlayer-op-node"
echo "  docker logs -f xlayer-${RPC_TYPE}"
echo ""
echo "🌐 Exposed Ports:"
echo "| Service | Port | Protocol | Purpose |"
echo "|---------|------|----------|---------|"
echo "| ${RPC_TYPE} RPC | 8123 | HTTP | JSON-RPC API |"
echo "| ${RPC_TYPE} WebSocket | 8546 | WebSocket | WebSocket API |"
echo "| op-node RPC | 9545 | HTTP | Consensus layer API |"
echo "| ${RPC_TYPE} P2P | 30303 | TCP/UDP | P2P network |"
echo "| op-node P2P | 9223 | TCP/UDP | P2P network |"
echo ""
echo "🛑 Stop services:"
echo "  ./stop.sh"
echo ""
echo "🔍 Check if blocks are syncing:"
echo "  curl http://127.0.0.1:8123 \\"
echo "    -X POST \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    --data '{\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1,\"jsonrpc\":\"2.0\"}'"
echo ""
