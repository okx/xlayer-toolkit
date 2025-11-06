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

# Check for required tools
if ! command -v envsubst &> /dev/null; then
    echo "❌ Error: envsubst is not installed. Please install gettext package."
    exit 1
fi

# Network-specific configuration (fixed values)
if [ "$NETWORK_TYPE" = "testnet" ]; then
    P2P_STATIC="/ip4/47.242.219.101/tcp/9223/p2p/16Uiu2HAkwUdbn9Q7UBKQYRsfjm9SQX5Yc2e96HUz2pyR3cw1FZLv,/ip4/47.242.235.15/tcp/9223/p2p/16Uiu2HAmThDG9xMpADbyGo1oCU8fndztwNg1PH6A7yp1BhCk5jfE"
    SEQUENCER_HTTP="https://testrpc.xlayer.tech"
    OP_STACK_IMAGE_TAG="xlayer/op-node:0.0.9"
    OP_GETH_IMAGE_TAG="xlayer/op-geth:0.0.6"
    OP_RETH_IMAGE_TAG="xlayer/op-reth:1.8.2"
    OP_NODE_BOOTNODE="enode://eaae9fe2fc758add65fe4cfd42918e898e16ab23294db88f0dcdbcab2773e75bbea6bfdaa42b3ed502dfbee1335c242c602078c4aa009264e4705caa20d3dca7@8.210.181.50:9223"
elif [ "$NETWORK_TYPE" = "mainnet" ]; then
    P2P_STATIC="/ip4/47.242.38.0/tcp/9223/p2p/16Uiu2HAmH1AVhKWR29mb5s8Cubgsbh4CH1G86A6yoVtjrLWQgiY3,/ip4/8.210.153.12/tcp/9223/p2p/16Uiu2HAkuerkmQYMZxYiQYfQcPob9H7XHPwS7pd8opPTMEm2nsAp,/ip4/8.210.117.27/tcp/9223/p2p/16Uiu2HAmQEzn2WQj4kmWVrK9aQsfyQcETgXQKjcKGrTPsKcJBv7a"
    SEQUENCER_HTTP="https://rpc.xlayer.tech"
    OP_STACK_IMAGE_TAG="xlayer/op-node:0.0.9"
    OP_GETH_IMAGE_TAG="xlayer/op-geth:0.0.6"
    OP_RETH_IMAGE_TAG="xlayer/op-reth:1.8.2"
    OP_NODE_BOOTNODE="enode://c67d7f63c5483ab8311123d2997bfe6a8aac2b117a40167cf71682f8a3e37d3b86547c786559355c4c05ae0b1a7e7a1b8fde55050b183f96728d62e276467ce1@8.210.177.150:9223,enode://28e3e305b266e01226a7cc979ab692b22507784095157453ee0e34607bb3beac9a5b00f3e3d7d3ac36164612ca25108e6b79f75e3a9ecb54a0b3e7eb3e097d37@8.210.15.172:9223,enode://b5aa43622aad25c619650a0b7f8bb030161dfbfd5664233f92d841a33b404cea3ffffdc5bc8d6667c7dc212242a52f0702825c1e51612047f75c847ab96ef7a6@8.210.69.97:9223"
fi

# Network-specific directories and files
DATA_DIR="data-${NETWORK_TYPE}"
CONFIG_DIR="config-${NETWORK_TYPE}"
GENESIS_FILE="genesis-${NETWORK_TYPE}.json"
GENESIS_FILE_RETH="genesis-reth-${NETWORK_TYPE}.json"
RETH_CONFIG="op-reth-config-${NETWORK_TYPE}.toml"
LOGS_DIR="logs-${NETWORK_TYPE}"

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

# Check required environment variables from .env
required_vars=("L1_RPC_URL" "L1_BEACON_URL")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Environment variable $var is not set in .env file"
        exit 1
    fi
done

# Validate network-specific configuration
if [ "$NETWORK_TYPE" = "mainnet" ]; then
    if [ -z "$OP_NODE_BOOTNODE" ]; then
        echo "❌ Error: Mainnet bootnode configuration is not complete"
        echo "Please edit start.sh and fill in OP_NODE_BOOTNODE for mainnet"
        exit 1
    fi
fi

# Create necessary directories
echo "📁 Creating data directories..."
mkdir -p "$DATA_DIR/op-node/p2p"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node"

# Determine config file names based on network
if [ "$NETWORK_TYPE" = "testnet" ]; then
    ROLLUP_CONFIG="rollup-testnet.json"
    GETH_CONFIG="op-geth-config-testnet.toml"
    RETH_CONFIG="op-reth-config-testnet.toml"
else
    ROLLUP_CONFIG="rollup-mainnet.json"
    GETH_CONFIG="op-geth-config-mainnet.toml"
    RETH_CONFIG="op-reth-config-mainnet.toml"
fi

# Check configuration files
echo "🔍 Checking configuration files for $NETWORK_TYPE..."
if [ "$RPC_TYPE" = "op-reth" ]; then
    config_files=("$CONFIG_DIR/$ROLLUP_CONFIG" "$CONFIG_DIR/$RETH_CONFIG" "$CONFIG_DIR/$GENESIS_FILE_RETH")
else
    config_files=("$CONFIG_DIR/$ROLLUP_CONFIG" "$CONFIG_DIR/$GETH_CONFIG" "$CONFIG_DIR/$GENESIS_FILE")
fi
for file in "${config_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Error: Configuration file $file does not exist"
        echo "Please run ./init.sh $NETWORK_TYPE first to initialize the node"
        exit 1
    fi
done

# Generate JWT secret (if it does not exist)
if [ ! -s "$CONFIG_DIR/jwt.txt" ]; then
    echo "🔑 Generating JWT secret..."
    openssl rand -hex 32 | tr -d '\n' > "$CONFIG_DIR/jwt.txt"
fi

# Append network-specific environment variables to .env
echo "📝 Updating .env file with network-specific configuration..."
cp env.example .env
cat >> .env << EOF

# Network-specific configuration (auto-generated by start.sh)
NETWORK_TYPE=$NETWORK_TYPE
DATA_DIR=$DATA_DIR
CONFIG_DIR=$CONFIG_DIR
LOGS_DIR=$LOGS_DIR

# Configuration files
ROLLUP_CONFIG=$ROLLUP_CONFIG
GETH_CONFIG=$GETH_CONFIG
RETH_CONFIG=$RETH_CONFIG
GENESIS_FILE=$GENESIS_FILE
GENESIS_FILE_RETH=$GENESIS_FILE_RETH

# Docker images
OP_STACK_IMAGE_TAG=$OP_STACK_IMAGE_TAG
OP_GETH_IMAGE_TAG=$OP_GETH_IMAGE_TAG
OP_RETH_IMAGE_TAG=$OP_RETH_IMAGE_TAG

# Network configuration
OP_NODE_BOOTNODE=$OP_NODE_BOOTNODE
P2P_STATIC=$P2P_STATIC
SEQUENCER_HTTP=$SEQUENCER_HTTP
EOF

echo "✅ Environment variables updated in .env"

# Start services
echo "🐳 Starting Docker services..."
if [ "$RPC_TYPE" = "op-reth" ]; then
    OP_RETH_WAIT_TIME=60
    OP_RETH_DATA_DIR="./data-${NETWORK_TYPE}/op-reth"
    if [ ! -d "$OP_RETH_DATA_DIR" ]; then
        # Wait for 3 minutes if the data directory does not exist
        OP_RETH_WAIT_TIME=180
    fi
    echo "⏳ Starting op-reth service first and wait $OP_RETH_WAIT_TIME seconds for it to load the genesis..."
    docker compose up -d op-reth
    sleep $OP_RETH_WAIT_TIME
    echo "🚀 Starting op-node service..."
    docker compose up -d op-node
else
    echo "🚀 Starting op-geth and op-node services..."
    docker compose up -d op-node
fi

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
echo "  docker logs -f xlayer-${NETWORK_TYPE}-op-node"
echo "  docker logs -f xlayer-${NETWORK_TYPE}-${RPC_TYPE}"
echo ""
echo "🌐 Exposed Ports:"
echo "| Service | Port | Protocol | Purpose |"
echo "|---------|------|----------|---------|"
echo "| ${RPC_TYPE} RPC | 8545 | HTTP | JSON-RPC API |"
echo "| ${RPC_TYPE} WebSocket | 8546 | WebSocket | WebSocket API |"
echo "| op-node RPC | 9545 | HTTP | Consensus layer API |"
echo "| ${RPC_TYPE} P2P | 30303 | TCP/UDP | P2P network |"
echo "| op-node P2P | 9223 | TCP/UDP | P2P network |"
echo ""
echo "🛑 Stop services:"
echo "  ./stop.sh"
echo ""
echo "🔍 Check if blocks are syncing:"
echo "  curl http://127.0.0.1:8545 \\"
echo "    -X POST \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    --data '{\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1,\"jsonrpc\":\"2.0\"}'"
echo ""
