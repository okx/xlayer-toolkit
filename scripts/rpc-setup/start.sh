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

# Network-specific configuration (fixed values)
if [ "$NETWORK_TYPE" = "testnet" ]; then
    P2P_STATIC="/ip4/47.242.219.101/tcp/9223/p2p/16Uiu2HAkwUdbn9Q7UBKQYRsfjm9SQX5Yc2e96HUz2pyR3cw1FZLv,/ip4/47.242.235.15/tcp/9223/p2p/16Uiu2HAmThDG9xMpADbyGo1oCU8fndztwNg1PH6A7yp1BhCk5jfE"
    SEQUENCER_HTTP="https://testrpc.xlayer.tech"
    # TODO: fix images name
    OP_STACK_IMAGE_TAG="xlayer/op-stack:v0.0.6"
    OP_GETH_IMAGE_TAG="xlayer/op-geth:v0.0.6"
    OP_NODE_BOOTNODE="enode://eaae9fe2fc758add65fe4cfd42918e898e16ab23294db88f0dcdbcab2773e75bbea6bfdaa42b3ed502dfbee1335c242c602078c4aa009264e4705caa20d3dca7@8.210.181.50:9223"
elif [ "$NETWORK_TYPE" = "mainnet" ]; then
    P2P_STATIC="/ip4/47.242.38.0/tcp/9223/p2p/16Uiu2HAmH1AVhKWR29mb5s8Cubgsbh4CH1G86A6yoVtjrLWQgiY3,/ip4/8.210.153.12/tcp/9223/p2p/16Uiu2HAkuerkmQYMZxYiQYfQcPob9H7XHPwS7pd8opPTMEm2nsAp,/ip4/8.210.117.27/tcp/9223/p2p/16Uiu2HAmQEzn2WQj4kmWVrK9aQsfyQcETgXQKjcKGrTPsKcJBv7a"
    SEQUENCER_HTTP="https://rpc.xlayer.tech"
    # TODO: fix images name
    OP_STACK_IMAGE_TAG="xlayer/op-stack:v0.0.6"
    OP_GETH_IMAGE_TAG="xlayer/op-geth:v0.0.6"
    OP_NODE_BOOTNODE="enode://c67d7f63c5483ab8311123d2997bfe6a8aac2b117a40167cf71682f8a3e37d3b86547c786559355c4c05ae0b1a7e7a1b8fde55050b183f96728d62e276467ce1@8.210.177.150:9223,enode://28e3e305b266e01226a7cc979ab692b22507784095157453ee0e34607bb3beac9a5b00f3e3d7d3ac36164612ca25108e6b79f75e3a9ecb54a0b3e7eb3e097d37@8.210.15.172:9223,enode://b5aa43622aad25c619650a0b7f8bb030161dfbfd5664233f92d841a33b404cea3ffffdc5bc8d6667c7dc212242a52f0702825c1e51612047f75c847ab96ef7a6@8.210.69.97:9223"
fi

# Network-specific directories and files
DATA_DIR="data-${NETWORK_TYPE}"
CONFIG_DIR="config-${NETWORK_TYPE}"
GENESIS_FILE="genesis-${NETWORK_TYPE}.json"
LOGS_DIR="logs-${NETWORK_TYPE}"

# Check environment variables file
if [ ! -f .env ]; then
    echo "❌ Error: .env file does not exist"
    echo "Please copy env.example to .env and fill in the correct configuration"
    exit 1
fi

# Load environment variables
source .env

# Check required environment variables (only L1 URLs from .env)
required_vars=("L1_RPC_URL" "L1_BEACON_URL")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: Environment variable $var is not set"
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
else
    ROLLUP_CONFIG="rollup-mainnet.json"
    GETH_CONFIG="op-geth-config-mainnet.toml"
fi

# Check configuration files
echo "🔍 Checking configuration files for $NETWORK_TYPE..."
config_files=("$CONFIG_DIR/$ROLLUP_CONFIG" "$CONFIG_DIR/$GETH_CONFIG" "$CONFIG_DIR/$GENESIS_FILE")
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

# Generate network-specific docker-compose file
echo "🐳 Generating docker-compose file for $NETWORK_TYPE..."

# Generate docker-compose.yml with network-specific paths
cat > docker-compose.yml << EOF
version: '3.8'

networks:
  xlayer-network:
    name: xlayer-network

services:
  op-geth:
    image: "\${OP_GETH_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-geth
    entrypoint: geth
    ports:
      - "8545:8545"   # HTTP RPC
      - "8552:8552"
      - "7546:7546"
      - "30303:30303" # P2P TCP
      - "30303:30303/udp" # P2P UDP
    volumes:
      - ./$DATA_DIR:/data
      - ./$CONFIG_DIR/jwt.txt:/jwt.txt
      - ./$CONFIG_DIR/$GETH_CONFIG:/config.toml
      - ./$LOGS_DIR/op-geth:/var/log/op-geth
    command:
      - --verbosity=3
      - --datadir=/data
      - --config=/config.toml
      - --db.engine=pebble
      - --gcmode=archive
      - --rollup.enabletxpooladmission
      - --rollup.sequencerhttp=$SEQUENCER_HTTP
      - --log.file=/var/log/op-geth/geth.log
    networks:
      - xlayer-network
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:8545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s

  op-node:
    image: "\${OP_STACK_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-node
    entrypoint: sh
    networks:
      - xlayer-network
    ports:
      - "9545:9545"
    volumes:
      - ./$DATA_DIR/op-node:/data
      - ./$CONFIG_DIR/$ROLLUP_CONFIG:/rollup.json
      - ./$CONFIG_DIR/jwt.txt:/jwt.txt
      - ./$LOGS_DIR/op-node:/var/log/op-node
    command:
      - -c
      - |
        exec /app/op-node/bin/op-node \\
          --log.level=info \\
          --l2=http://op-geth:8552 \\
          --l2.jwt-secret=/jwt.txt \\
          --sequencer.enabled=false \\
          --verifier.l1-confs=1 \\
          --rollup.config=/rollup.json \\
          --rpc.addr=0.0.0.0 \\
          --rpc.port=9545 \\
          --p2p.listen.tcp=9223 \\
          --p2p.listen.udp=9223 \\
          --p2p.peerstore.path=/data/p2p/opnode_peerstore_db \\
          --p2p.discovery.path=/data/p2p/opnode_discovery_db \\
          --p2p.bootnodes=$OP_NODE_BOOTNODE \\
          --p2p.static=$P2P_STATIC \\
          --rpc.enable-admin=true \\
          --l1=\${L1_RPC_URL} \\
          --l1.beacon=\${L1_BEACON_URL} \\
          --l1.rpckind=standard \\
          --conductor.enabled=false \\
          --safedb.path=/data/safedb \\
          2>&1 | tee /var/log/op-node/op-node.log
    depends_on:
      - op-geth
EOF

# Start services
echo "🐳 Starting Docker services for $NETWORK_TYPE..."
docker compose up -d

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
echo "  docker logs -f xlayer-op-geth"
echo ""
echo "🌐 Exposed Ports:"
echo "| Service | Port | Protocol | Purpose |"
echo "|---------|------|----------|---------|"
echo "| op-geth RPC | 8545 | HTTP | JSON-RPC API |"
echo "| op-geth WebSocket | 8546 | WebSocket | WebSocket API |"
echo "| op-node RPC | 9545 | HTTP | Consensus layer API |"
echo "| op-geth P2P | 30303 | TCP/UDP | P2P network |"
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
