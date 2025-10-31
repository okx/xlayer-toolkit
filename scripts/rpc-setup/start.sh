#!/bin/bash
# start.sh
# X Layer RPC Node Start Script

set -e

# Check if network type is provided
if [ -z "$1" ]; then
    echo "❌ Error: Network type is required"
    echo "Usage: ./start.sh [testnet|mainnet]"
    exit 1
fi

NETWORK_TYPE=$1

if [[ "$NETWORK_TYPE" != "testnet" && "$NETWORK_TYPE" != "mainnet" ]]; then
    echo "❌ Error: Invalid network type"
    echo "Usage: ./start.sh [testnet|mainnet]"
    exit 1
fi

echo "🚀 Starting X Layer Self-hosted RPC node for $NETWORK_TYPE network..."

# Check environment variables file
if [ ! -f .env ]; then
    echo "❌ Error: .env file does not exist"
    echo "Please copy env.example to .env and fill in the correct configuration"
    exit 1
fi

# Load environment variables first
source .env

# Set RPC_TYPE based on L2_ENGINEKIND
L2_ENGINEKIND="${L2_ENGINEKIND:-geth}"
RPC_TYPE="op-${L2_ENGINEKIND}"

echo "🔍 RPC type: $RPC_TYPE"

# Verify static docker-compose.yml exists
if [ ! -f docker-compose.yml ]; then
    echo "❌ Error: docker-compose.yml not found"
    echo "Please ensure docker-compose.yml exists in the current directory"
    exit 1
fi

echo "✅ Using static docker-compose.yml with profile: $L2_ENGINEKIND"

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

echo "📁 Using data directory: $CHAIN_DATA_DIR"

# Check required environment variables (only L1 URLs from .env)
required_vars=("L1_RPC_URL" "L1_BEACON_URL")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set in .env file"
        exit 1
    fi
done

# Create necessary directories
echo "📁 Creating data directories..."
mkdir -p "$DATA_DIR/op-node/p2p"
mkdir -p "$DATA_DIR/op-reth"  # For reth data
mkdir -p "$LOGS_DIR/op-geth"
mkdir -p "$LOGS_DIR/op-node"
mkdir -p "$LOGS_DIR/op-reth"

# Set network-specific configuration
ROLLUP_CONFIG="rollup-${NETWORK_TYPE}.json"
if [ "$L2_ENGINEKIND" = "reth" ]; then
    RETH_CONFIG="op-reth-config-${NETWORK_TYPE}.toml"
else
    GETH_CONFIG="op-geth-config-${NETWORK_TYPE}.toml"
fi

# Check configuration files
echo "🔍 Checking configuration files for $NETWORK_TYPE..."
config_files=("$CONFIG_DIR/$ROLLUP_CONFIG" "$CONFIG_DIR/$GENESIS_FILE")
for file in "${config_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Error: Configuration file $file does not exist"
        echo "Please run ./init.sh $NETWORK_TYPE first to initialize the node"
        exit 1
    fi
done

# Start services with profiles
echo "🐳 Starting Docker services for $NETWORK_TYPE with engine: $L2_ENGINEKIND..."

# Set COMPOSE_PROFILES to activate the correct service
export COMPOSE_PROFILES="$L2_ENGINEKIND"

# For op-reth, we need special startup handling
if [ "$L2_ENGINEKIND" = "reth" ]; then
    # op-reth needs special startup sequence
    OP_RETH_WAIT_TIME=60
    OP_RETH_DATA_DIR="./$DATA_DIR/op-reth"
    
    if [ ! -d "$OP_RETH_DATA_DIR" ]; then
        # Wait longer if the data directory does not exist (first time initialization)
        OP_RETH_WAIT_TIME=180
        echo "⏳ Starting op-reth service first and waiting $OP_RETH_WAIT_TIME seconds for it to load the genesis..."
    else
        echo "⏳ Starting op-reth service first and waiting $OP_RETH_WAIT_TIME seconds..."
    fi
    
    # Start op-reth first
    docker compose up -d op-reth
    
    # Wait for op-reth to load genesis and be ready
    echo "⏳ Waiting for op-reth to initialize..."
    sleep "$OP_RETH_WAIT_TIME"
    
    # Check if op-reth container is running
    if ! docker compose ps | grep -q "op-reth.*running"; then
        echo "❌ Error: op-reth failed to start"
        echo "📋 Checking op-reth logs:"
        docker compose logs op-reth --tail 50
        exit 1
    fi
    
    echo "✅ op-reth is running, now starting op-node..."
    # Start op-node
    docker compose up -d op-node
else
    # For op-geth, normal startup
    docker compose up -d
fi

echo "✅ X Layer RPC node startup completed"
echo "📋 View logs: docker compose logs -f"
