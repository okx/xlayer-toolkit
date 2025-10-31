#!/bin/bash
# one-click-setup.sh
# X Layer RPC Node One-Click Installation Script

set -e

LOCAL_GENESIS_TESTNET="/Users/oker/Downloads/merged.genesis.json.testnet.tar.gz"
LOCAL_GENESIS_MAINNET="/Users/oker/Downloads/merged.genesis.json.mainnet.tar.gz"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TODO: Change to main after release
REPO_BRANCH="feature/reth-rpc-v1"
REPO_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/$REPO_BRANCH/scripts/rpc-setup"
TEMP_DIR="/tmp/xlayer-setup-$$"

# Default values
DEFAULT_NETWORK="testnet"
DEFAULT_DATA_DIR="./data"
DEFAULT_RPC_PORT="8545"
DEFAULT_WS_PORT="7546"
DEFAULT_NODE_RPC_PORT="9545"
DEFAULT_GETH_P2P_PORT="30303"
DEFAULT_NODE_P2P_PORT="9223"

# Testnet configuration
TESTNET_BOOTNODE_OP_NODE="enode://eaae9fe2fc758add65fe4cfd42918e898e16ab23294db88f0dcdbcab2773e75bbea6bfdaa42b3ed502dfbee1335c242c602078c4aa009264e4705caa20d3dca7@8.210.181.50:9223"
TESTNET_P2P_STATIC="/ip4/47.242.219.101/tcp/9223/p2p/16Uiu2HAkwUdbn9Q7UBKQYRsfjm9SQX5Yc2e96HUz2pyR3cw1FZLv,/ip4/47.242.235.15/tcp/9223/p2p/16Uiu2HAmThDG9xMpADbyGo1oCU8fndztwNg1PH6A7yp1BhCk5jfE"
TESTNET_OP_STACK_IMAGE="xlayer/op-node:0.0.9"
TESTNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
TESTNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"
TESTNET_SEQUENCER_HTTP="https://testrpc.xlayer.tech"
TESTNET_ROLLUP_CONFIG="rollup-testnet.json"
TESTNET_GETH_CONFIG="op-geth-config-testnet.toml"

# Mainnet configuration
MAINNET_BOOTNODE_OP_NODE="enode://c67d7f63c5483ab8311123d2997bfe6a8aac2b117a40167cf71682f8a3e37d3b86547c786559355c4c05ae0b1a7e7a1b8fde55050b183f96728d62e276467ce1@8.210.177.150:9223,enode://28e3e305b266e01226a7cc979ab692b22507784095157453ee0e34607bb3beac9a5b00f3e3d7d3ac36164612ca25108e6b79f75e3a9ecb54a0b3e7eb3e097d37@8.210.15.172:9223,enode://b5aa43622aad25c619650a0b7f8bb030161dfbfd5664233f92d841a33b404cea3ffffdc5bc8d6667c7dc212242a52f0702825c1e51612047f75c847ab96ef7a6@8.210.69.97:9223"
MAINNET_P2P_STATIC="/ip4/47.242.38.0/tcp/9223/p2p/16Uiu2HAmH1AVhKWR29mb5s8Cubgsbh4CH1G86A6yoVtjrLWQgiY3,/ip4/8.210.153.12/tcp/9223/p2p/16Uiu2HAkuerkmQYMZxYiQYfQcPob9H7XHPwS7pd8opPTMEm2nsAp,/ip4/8.210.117.27/tcp/9223/p2p/16Uiu2HAmQEzn2WQj4kmWVrK9aQsfyQcETgXQKjcKGrTPsKcJBv7a"
MAINNET_OP_STACK_IMAGE="xlayer/op-node:0.0.9"
MAINNET_OP_GETH_IMAGE="xlayer/op-geth:0.0.6"
MAINNET_GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz"
MAINNET_SEQUENCER_HTTP="https://rpc.xlayer.tech"
MAINNET_ROLLUP_CONFIG="rollup-mainnet.json"
MAINNET_GETH_CONFIG="op-geth-config-mainnet.toml"

# User input variables
NETWORK_TYPE=""
L1_RPC_URL=""
L1_BEACON_URL=""
DATA_DIR=""
RPC_PORT=""
WS_PORT=""
NODE_RPC_PORT=""
GETH_P2P_PORT=""
NODE_P2P_PORT=""
DOCKER_COMPOSE_CMD=""

# Function to print colored output
print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header() {
    echo -e "${BLUE}"
    echo "=========================================="
    echo "  X Layer RPC Node One-Click Setup"
    echo "=========================================="
    echo -e "${NC}"
}

# Function to load network-specific configuration
load_network_config() {
    local network=$1
    
    case "$network" in
        testnet)
            OP_NODE_BOOTNODE="$TESTNET_BOOTNODE_OP_NODE"
            P2P_STATIC="$TESTNET_P2P_STATIC"
            OP_STACK_IMAGE_TAG="$TESTNET_OP_STACK_IMAGE"
            OP_GETH_IMAGE_TAG="$TESTNET_OP_GETH_IMAGE"
            GENESIS_URL="$TESTNET_GENESIS_URL"
            SEQUENCER_HTTP="$TESTNET_SEQUENCER_HTTP"
            ROLLUP_CONFIG="$TESTNET_ROLLUP_CONFIG"
            GETH_CONFIG="$TESTNET_GETH_CONFIG"
            ;;
        mainnet)
            OP_NODE_BOOTNODE="$MAINNET_BOOTNODE_OP_NODE"
            P2P_STATIC="$MAINNET_P2P_STATIC"
            OP_STACK_IMAGE_TAG="$MAINNET_OP_STACK_IMAGE"
            OP_GETH_IMAGE_TAG="$MAINNET_OP_GETH_IMAGE"
            GENESIS_URL="$MAINNET_GENESIS_URL"
            SEQUENCER_HTTP="$MAINNET_SEQUENCER_HTTP"
            ROLLUP_CONFIG="$MAINNET_ROLLUP_CONFIG"
            GETH_CONFIG="$MAINNET_GETH_CONFIG"
            ;;
        *)
            print_error "Unknown network type: $network"
            exit 1
            ;;
    esac
}

# Function to validate port number
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Function to check system requirements
check_system_requirements() {
    print_info "Checking system requirements..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker 20.10+ first."
        print_info "Visit: https://docs.docker.com/get-docker/"
        exit 1
    fi

    # Check Docker Compose
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        print_error "Docker Compose is not installed. Please install Docker Compose 2.0+ first."
        print_info "Visit: https://docs.docker.com/compose/install/"
        exit 1
    fi
    print_info "Using Docker Compose command: $DOCKER_COMPOSE_CMD"

    # Check Docker daemon
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    
    # Check required tools
    REQUIRED_TOOLS=("wget" "tar" "openssl")
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "$tool is not installed. Please install it first."
            exit 1
        fi
    done

    print_success "System requirements check completed"
}

# Function to download configuration files
download_config_files() {
    print_info "Downloading configuration files..."

    # Create temporary directory
    mkdir -p "$TEMP_DIR/config"
    
    # Load network-specific configuration to know which files to download
    load_network_config "$NETWORK_TYPE"
    
    # Download configuration files based on network
    local config_files=(
        "config/$ROLLUP_CONFIG"
        "config/$GETH_CONFIG"
    )

    for file in "${config_files[@]}"; do
        print_info "Downloading $file..."
        local target_file="$TEMP_DIR/$file"
        mkdir -p "$(dirname "$target_file")"
        if ! wget -q "$REPO_URL/$file" -O "$target_file"; then
            print_error "Failed to download $file"
            print_info "If this is a mainnet config file, make sure it exists in the repository"
            exit 1
        fi
    done

    print_success "Configuration files downloaded successfully"
}

# Function to get user input
get_user_input() {
    print_info "Please provide the following information:"
    echo ""

    # Check if running from pipe (curl | bash) or in non-interactive mode - use defaults
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        print_info "🚀 Auto-mode: Using default configuration"
        NETWORK_TYPE="$DEFAULT_NETWORK"
        L1_RPC_URL="https://placeholder-l1-rpc-url"
        L1_BEACON_URL="https://placeholder-l1-beacon-url"
        L2_ENGINEKIND="geth"
        # DATA_DIR will be set in generate_config_files based on NETWORK_TYPE and L2_ENGINEKIND
        RPC_PORT="$DEFAULT_RPC_PORT"
        WS_PORT="$DEFAULT_WS_PORT"
        NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
        GETH_P2P_PORT="$DEFAULT_GETH_P2P_PORT"
        NODE_P2P_PORT="$DEFAULT_NODE_P2P_PORT"
        print_warning "⚠️  L1 URLs will need to be configured after setup"
        return 0
    fi

    # Network type selection
    while true; do
        echo -n "1. Network type (testnet/mainnet) [default: $DEFAULT_NETWORK]: "
        read -r input
        NETWORK_TYPE="${input:-$DEFAULT_NETWORK}"

        if [[ "$NETWORK_TYPE" == "testnet" || "$NETWORK_TYPE" == "mainnet" ]]; then
            break
        else
            print_error "Invalid network type. Please enter 'testnet' or 'mainnet'"
        fi
    done
    
    # L1 RPC URL
    while true; do
        echo -n "2. L1 RPC URL (Ethereum L1 RPC endpoint): "
        read -r L1_RPC_URL
        if [[ -n "$L1_RPC_URL" ]]; then
            # Basic URL validation
            if [[ "$L1_RPC_URL" =~ ^https?:// ]]; then
                break
            else
                print_error "Please enter a valid HTTP/HTTPS URL"
            fi
        else
            print_error "L1 RPC URL is required"
        fi
    done

    # L1 Beacon URL
    while true; do
        echo -n "3. L1 Beacon URL (Ethereum L1 Beacon chain endpoint): "
        read -r L1_BEACON_URL
        if [[ -n "$L1_BEACON_URL" ]]; then
            # Basic URL validation
            if [[ "$L1_BEACON_URL" =~ ^https?:// ]]; then
                break
            else
                print_error "Please enter a valid HTTP/HTTPS URL"
            fi
        else
            print_error "L1 Beacon URL is required"
        fi
    done

    # Optional configurations
    echo ""
    print_info "Optional configurations (press Enter to use defaults):"
    
    # L2 Engine Type selection
    while true; do
        echo -n "4. L2 Engine Type (geth/reth) [default: geth]: "
        read -r input
        L2_ENGINEKIND="${input:-geth}"
        if [[ "$L2_ENGINEKIND" == "geth" || "$L2_ENGINEKIND" == "reth" ]]; then
            break
        else
            print_error "Invalid engine type. Please enter 'geth' or 'reth'"
        fi
    done
    
    print_info "Note: Data will be stored in chaindata/${NETWORK_TYPE}-${L2_ENGINEKIND}/"
    
    # Skip data directory input - will be auto-determined
    # DATA_DIR will be set in generate_config_files as: chaindata/{network}-{engine}/data
    
    while true; do
        echo -n "5. RPC port [default: $DEFAULT_RPC_PORT]: "
        read -r input
        RPC_PORT="${input:-$DEFAULT_RPC_PORT}"
        if validate_port "$RPC_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
    
    while true; do
        echo -n "6. WebSocket port [default: $DEFAULT_WS_PORT]: "
        read -r input
        WS_PORT="${input:-$DEFAULT_WS_PORT}"
        if validate_port "$WS_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
    
    while true; do
        echo -n "7. Node RPC port [default: $DEFAULT_NODE_RPC_PORT]: "
        read -r input
        NODE_RPC_PORT="${input:-$DEFAULT_NODE_RPC_PORT}"
        if validate_port "$NODE_RPC_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
    
    while true; do
        echo -n "8. Geth P2P port [default: $DEFAULT_GETH_P2P_PORT]: "
        read -r input
        GETH_P2P_PORT="${input:-$DEFAULT_GETH_P2P_PORT}"
        if validate_port "$GETH_P2P_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
    
    while true; do
        echo -n "9. Node P2P port [default: $DEFAULT_NODE_P2P_PORT]: "
        read -r input
        NODE_P2P_PORT="${input:-$DEFAULT_NODE_P2P_PORT}"
        if validate_port "$NODE_P2P_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
    
    print_success "Configuration input completed"
}

# Function to generate configuration files
generate_config_files() {
    print_info "Generating configuration files..."

    # Create working directory
    WORK_DIR="$SCRIPT_DIR"
    cd "$WORK_DIR"
    
    # Load network-specific configuration
    load_network_config "$NETWORK_TYPE"
    
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
    
    print_info "📁 Data will be stored in: $CHAIN_DATA_DIR"
    
    # Create necessary directories
    mkdir -p "$CONFIG_DIR" "$DATA_DIR/op-node/p2p" "$DATA_DIR/op-reth" "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node" "$LOGS_DIR/op-reth"
    
    # Generate JWT secret for this network
    print_info "Generating JWT secret for $NETWORK_TYPE..."
    if [ ! -s "$CONFIG_DIR/jwt.txt" ]; then
        openssl rand -hex 32 | tr -d '\n' > "$CONFIG_DIR/jwt.txt"
        print_success "JWT secret generated at $CONFIG_DIR/jwt.txt"
    else
        print_info "Using existing JWT secret from $CONFIG_DIR/jwt.txt"
    fi
    
    # Verify JWT file format
    JWT_CONTENT=$(cat "$CONFIG_DIR/jwt.txt" 2>/dev/null | tr -d '\n\r ' || echo "")
    if [ ${#JWT_CONTENT} -ne 64 ]; then
        print_warning "JWT file has incorrect format (expected 64 hex chars, got ${#JWT_CONTENT}), regenerating..."
        openssl rand -hex 32 | tr -d '\n' > "$CONFIG_DIR/jwt.txt"
        print_success "JWT secret regenerated"
    fi
    
    # Generate .env file
    print_info "Generating .env file..."

    cat > .env << EOF
# X Layer $NETWORK_TYPE Configuration
L1_RPC_URL=$L1_RPC_URL
L1_BEACON_URL=$L1_BEACON_URL

# L2 Engine Type: geth or reth
L2_ENGINEKIND=$L2_ENGINEKIND

# Data Directory Root (default: chaindata)
# All blockchain data will be stored under: chaindata/{network}-{engine}/
# CHAIN_DATA_ROOT=chaindata

# Docker Image Tags (optional, will use defaults if not set)
# OP_STACK_IMAGE_TAG=$OP_STACK_IMAGE_TAG
# OP_GETH_IMAGE_TAG=$OP_GETH_IMAGE_TAG
# OP_RETH_IMAGE_TAG=xlayer/op-reth:release-testnet
EOF

    # Copy configuration files from temp directory
    cp "$TEMP_DIR/config/$ROLLUP_CONFIG" "$CONFIG_DIR/"
    cp "$TEMP_DIR/config/$GETH_CONFIG" "$CONFIG_DIR/"
    
    # Determine RETH config file based on network
    if [ "$NETWORK_TYPE" = "testnet" ]; then
        RETH_CONFIG="op-reth-config-testnet.toml"
    else
        RETH_CONFIG="op-reth-config-mainnet.toml"
    fi
    
    # Set RPC_TYPE for docker-compose
    RPC_TYPE="op-${L2_ENGINEKIND}"
    
    # Set default image tags if not provided
    OP_RETH_IMAGE_TAG="${OP_RETH_IMAGE_TAG:-xlayer/op-reth:release-testnet}"
    
    # Generate docker-compose.yml with custom ports - dynamically based on L2_ENGINEKIND
    print_info "Generating docker-compose.yml for $L2_ENGINEKIND with custom ports..."
    
    cat > docker-compose.yml << EOF
version: '3.8'

networks:
  xlayer-network:
    name: xlayer-network

services:
EOF

    # Add op-geth or op-reth service based on L2_ENGINEKIND
    if [ "$L2_ENGINEKIND" = "reth" ]; then
        cat >> docker-compose.yml << EOF
  op-reth:
    image: "$OP_RETH_IMAGE_TAG"
    container_name: xlayer-${NETWORK_TYPE}-op-reth
    networks:
      - xlayer-network
    entrypoint: /entrypoint/reth-rpc.sh
    env_file:
      - .env
    environment:
      - L1_RPC_URL=\${L1_RPC_URL}
      - L1_BEACON_URL=\${L1_BEACON_URL}
      - SEQUENCER_HTTP_URL=$SEQUENCER_HTTP
    volumes:
      - ./$DATA_DIR/op-reth:/datadir
      - ./$CONFIG_DIR/jwt.txt:/jwt.txt
      - ./$CONFIG_DIR/genesis-reth.json:/genesis.json
      - ./$CONFIG_DIR/$RETH_CONFIG:/config.toml
      - ./entrypoint/reth-rpc.sh:/entrypoint/reth-rpc.sh
      - ./.env:/app/.env
      - ./$LOGS_DIR/op-reth:/var/log/op-reth
    ports:
      - "$RPC_PORT:8545"   # HTTP RPC
      - "8552:8552"        # Engine API
      - "$WS_PORT:7546"     # WebSocket
      - "$GETH_P2P_PORT:30303" # P2P TCP
      - "$GETH_P2P_PORT:30303/udp" # P2P UDP
    healthcheck:
      test: ["CMD", "curl", "-X", "POST", "http://localhost:8545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s

EOF
    else
        cat >> docker-compose.yml << EOF
  op-geth:
    image: "\${OP_GETH_IMAGE_TAG:-$OP_GETH_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-geth
    entrypoint: geth
    ports:
      - "$RPC_PORT:8545"   # HTTP RPC
      - "8552:8552"
      - "$WS_PORT:7546"     # WebSocket
      - "$GETH_P2P_PORT:30303" # P2P TCP
      - "$GETH_P2P_PORT:30303/udp" # P2P UDP
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

EOF
    fi
    
    # Add op-node service (common for both geth and reth)
    cat >> docker-compose.yml << EOF
  op-node:
    image: "\${OP_STACK_IMAGE_TAG:-$OP_STACK_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-node
    entrypoint: sh
    networks:
      - xlayer-network
    ports:
      - "$NODE_RPC_PORT:9545"
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
          --l2=http://$RPC_TYPE:8552 \\
          --l2.jwt-secret=/jwt.txt \\
          --sequencer.enabled=false \\
          --verifier.l1-confs=1 \\
          --rollup.config=/rollup.json \\
          --rpc.addr=0.0.0.0 \\
          --rpc.port=9545 \\
          --p2p.listen.tcp=$NODE_P2P_PORT \\
          --p2p.listen.udp=$NODE_P2P_PORT \\
          --p2p.peerstore.path=/data/p2p/opnode_peerstore_db \\
          --p2p.discovery.path=/data/p2p/opnode_discovery_db \\
          --p2p.bootnodes=$OP_NODE_BOOTNODE \\
          --p2p.static=$P2P_STATIC \\
          --rpc.enable-admin=true \\
          --l1.trustrpc \\
          --l1=\${L1_RPC_URL} \\
          --l1.beacon=\${L1_BEACON_URL} \\
          --l1.rpckind=standard \\
          --conductor.enabled=false \\
          --safedb.path=/data/safedb \\
          --l2.enginekind=$L2_ENGINEKIND \\
          2>&1 | tee /var/log/op-node/op-node.log
    depends_on:
      - $RPC_TYPE
EOF
    
    print_success "Configuration files generated successfully"
}

# Function to initialize the node
initialize_node() {
    print_info "Initializing X Layer RPC node..."
    
    # Load network configuration
    load_network_config "$NETWORK_TYPE"
    
    # Check if data directory already exists and has geth data
    if [ -d "$DATA_DIR/geth" ]; then
        print_warning "Data directory $DATA_DIR already contains a geth database."
        print_warning "This might be initialized for a different network."
        if [ -t 0 ] && [ -t 1 ]; then
            read -p "Do you want to remove the existing data and reinitialize? (y/N): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                print_info "Cleaning up old data directory..."
                rm -rf "$DATA_DIR"
                # Recreate necessary directories
                mkdir -p "$DATA_DIR/op-node/p2p"
                print_success "Old data removed"
            else
                print_info "Keeping existing data directory"
                print_success "Skipping initialization (using existing data)"
                return 0
            fi
        else
            print_info "Auto-mode: Keeping existing data directory"
            print_success "Skipping initialization (using existing data)"
            return 0
        fi
    fi
    
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
        print_info "Using local pre-downloaded genesis file: $LOCAL_GENESIS_FILE"
        print_info "Copying to: $GENESIS_TAR_PATH"
        cp "$LOCAL_GENESIS_FILE" "$GENESIS_TAR_PATH"
        USE_LOCAL_GENESIS=true
    elif [ -n "$LOCAL_GENESIS_FILE" ]; then
        print_warning "Local genesis file configured but not found: $LOCAL_GENESIS_FILE"
        print_info "Falling back to download from network..."
        print_info "Downloading genesis file from $GENESIS_URL..."
        print_info "Download location: $GENESIS_TAR_PATH"
        wget -c "$GENESIS_URL" -O "$GENESIS_TAR_PATH"
        USE_LOCAL_GENESIS=false
    else
        # No local path configured, download from network
        print_info "Downloading genesis file from $GENESIS_URL..."
        print_info "Download location: $GENESIS_TAR_PATH"
        wget -c "$GENESIS_URL" -O "$GENESIS_TAR_PATH"
        USE_LOCAL_GENESIS=false
    fi
    
    # Extract the genesis file
    print_info "Extracting genesis file..."
    tar -xzf "$GENESIS_TAR_PATH" -C "$CONFIG_DIR/"
    
    # Handle different genesis file names and rename to network-specific name
    if [ -f "$CONFIG_DIR/merged.genesis.json" ]; then
        mv "$CONFIG_DIR/merged.genesis.json" "$CONFIG_DIR/$GENESIS_FILE"
    elif [ -f "$CONFIG_DIR/genesis.json" ]; then
        mv "$CONFIG_DIR/genesis.json" "$CONFIG_DIR/$GENESIS_FILE"
    else
        print_error "Failed to find genesis.json in the archive"
        exit 1
    fi
    
    # Clean up the downloaded archive
    if [ "$USE_LOCAL_GENESIS" = "true" ]; then
        # Keep the file when using local genesis (for reuse)
        print_info "Keeping genesis archive for reuse: $GENESIS_TAR_PATH"
    else
        # Remove the file when downloaded from network
        print_info "Cleaning up downloaded archive..."
        rm "$GENESIS_TAR_PATH"
        print_success "Temporary file removed: $GENESIS_TAR_PATH"
    fi
    
    # Check if genesis file exists
    if [ ! -f "$CONFIG_DIR/$GENESIS_FILE" ]; then
        print_error "Failed to extract genesis file"
        exit 1
    fi
    
    print_success "Genesis file extracted successfully to $CONFIG_DIR/$GENESIS_FILE"
    
    # Verify genesis file chain ID matches network configuration
    print_info "Verifying genesis file chain ID..."
    if command -v jq &> /dev/null; then
        GENESIS_CHAIN_ID=$(jq -r '.config.chainId // .chainId' "$CONFIG_DIR/$GENESIS_FILE" 2>/dev/null || echo "")
        if [ -n "$GENESIS_CHAIN_ID" ]; then
            print_info "Genesis file chain ID: $GENESIS_CHAIN_ID"
            # Validate against expected chain IDs
            if [ "$NETWORK_TYPE" == "testnet" ] && [ "$GENESIS_CHAIN_ID" != "1952" ]; then
                print_error "Genesis file chain ID mismatch! Expected 1952 (testnet), got $GENESIS_CHAIN_ID"
                exit 1
            elif [ "$NETWORK_TYPE" == "mainnet" ] && [ "$GENESIS_CHAIN_ID" != "196" ]; then
                print_error "Genesis file chain ID mismatch! Expected 196 (mainnet), got $GENESIS_CHAIN_ID"
                exit 1
            fi
            print_success "Genesis file chain ID verified"
        else
            print_warning "Could not read chain ID from genesis file, skipping verification"
        fi
    else
        print_warning "jq not found, skipping chain ID verification"
    fi
    
    # Initialize based on L2_ENGINEKIND
    if [ "$L2_ENGINEKIND" = "geth" ]; then
        # Initialize op-geth with the genesis file (geth requires init)
        print_info "Initializing op-geth with genesis file... (This may take a while, please wait patiently.)"
        docker run --rm \
            -v "$(pwd)/$DATA_DIR:/data" \
            -v "$(pwd)/$CONFIG_DIR/$GENESIS_FILE:/genesis.json" \
            "$OP_GETH_IMAGE_TAG" \
            --datadir /data \
            --gcmode=archive \
            --db.engine=pebble \
            --log.format json \
            init \
            --state.scheme=hash \
            /genesis.json
        print_success "op-geth initialization completed"
    else
        # op-reth does not need init command, it will load genesis on first start
        print_info "op-reth does not require initialization"
        print_info "Genesis file will be loaded automatically on first start"
        print_success "op-reth configuration ready"
    fi
    
    print_success "X Layer RPC node initialization completed"
}

# Function to start services
start_services() {
    print_info "Starting Docker services..."
    
    # Load network configuration to ensure CONFIG_DIR is set
    load_network_config "$NETWORK_TYPE"
    
    # Reconstruct directory paths (matching generate_config_files)
    CHAIN_DATA_ROOT="${CHAIN_DATA_ROOT:-chaindata}"
    CHAIN_DATA_DIR="$CHAIN_DATA_ROOT/${NETWORK_TYPE}-${L2_ENGINEKIND}"
    CONFIG_DIR="$CHAIN_DATA_DIR/config"
    
    # Verify JWT file exists
    if [ ! -f "$CONFIG_DIR/jwt.txt" ]; then
        print_error "JWT file not found at $CONFIG_DIR/jwt.txt"
        print_info "Please run the setup script again to generate JWT secret"
        exit 1
    fi

    # Set environment variables for docker-compose
    export OP_GETH_IMAGE_TAG
    export OP_STACK_IMAGE_TAG
    
    $DOCKER_COMPOSE_CMD up -d

    print_success "X Layer RPC node startup completed"
}

# Function to verify installation
verify_installation() {
    print_info "Verifying installation..."

    # Wait a bit more for services to be fully ready
    sleep 10

    # Check if docker-compose.yml exists
    if [ ! -f "./docker-compose.yml" ]; then
        print_error "docker-compose.yml not found"
        return 1
    fi

    # Check if services are running
    local running_services
    running_services=$($DOCKER_COMPOSE_CMD ps --services --filter "status=running" 2>/dev/null | wc -l)

    if [ "$running_services" -eq 0 ]; then
        print_error "No services are running"
        print_info "Check logs with: $DOCKER_COMPOSE_CMD logs"
        return 1
    fi

    # Test RPC endpoint if curl is available
    if command -v curl &> /dev/null; then
        print_info "Testing RPC endpoint..."
        if curl -s -X POST \
            -H "Content-Type: application/json" \
            --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' \
            --max-time 5 \
            "http://127.0.0.1:$RPC_PORT" > /dev/null 2>&1; then
            print_success "RPC endpoint is responding"
        else
            print_warning "RPC endpoint test failed, but services are running"
            print_info "The node may need more time to sync before accepting requests"
        fi
    else
        print_warning "curl not found, skipping RPC endpoint test"
    fi

    print_success "Installation verification completed"
}

# Function to display connection information
display_connection_info() {
    echo ""
    print_success "🎉 X Layer RPC Node Setup Complete!"
    echo ""
    echo "📋 Connection Information:"
    echo "========================"
    echo ""
    echo "🌐 RPC Endpoints:"
    echo "  HTTP RPC: http://localhost:$RPC_PORT"
    echo "  WebSocket: ws://localhost:$WS_PORT"
    echo "  Node RPC: http://localhost:$NODE_RPC_PORT"
    echo ""
    echo "🔍 Service Management:"
    echo "  View logs: docker compose logs -f"
    echo "  View op-geth logs: docker compose logs -f op-geth"
    echo "  View op-node logs: docker compose logs -f op-node"
    echo "  Persisted logs (full): ./$LOGS_DIR/op-geth/ and ./$LOGS_DIR/op-node/"
    echo "  Stop services: docker compose down"
    echo "  Restart services: docker compose restart"
    echo ""
    echo "🧪 Test Commands:"
    echo "  Test RPC: curl http://127.0.0.1:$RPC_PORT \\"
    echo "    -X POST \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    --data '{\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1,\"jsonrpc\":\"2.0\"}'"
    echo ""
    echo "📁 Working Directory: $(pwd)"
    if [ -d "$DATA_DIR" ]; then
        echo "📁 Data Directory: $(cd "$DATA_DIR" && pwd)"
    else
        echo "📁 Data Directory: $DATA_DIR (will be created on first run)"
    fi
    echo "🌍 Network: $NETWORK_TYPE"
    echo ""

    # Check if L1 URLs are placeholder values
    if [[ "$L1_RPC_URL" == "https://placeholder-l1-rpc-url" ]]; then
        echo "⚠️  IMPORTANT: Configure L1 RPC URLs to complete setup!"
        echo "=========================================="
        echo ""
        print_info "📝 Next Steps:"
        print_info "1. Edit .env file: nano .env"
        print_info "2. Update L1 URLs:"
        echo "   L1_RPC_URL=https://your-ethereum-l1-rpc-endpoint"
        echo "   L1_BEACON_URL=https://your-ethereum-l1-beacon-endpoint"
        print_info "3. Restart: $DOCKER_COMPOSE_CMD down && $DOCKER_COMPOSE_CMD up -d"
        echo ""
    fi

    print_info "Your X Layer RPC node is now running and ready to serve requests!"
}

# Function to cleanup temporary files
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Main execution
main() {
    # Set up cleanup trap
    trap cleanup EXIT

    print_header

    # Check system requirements
    check_system_requirements
    
    # Get user input FIRST (before downloading config files)
    get_user_input
    
    # Download configuration files
    download_config_files
    
    # Generate configuration files
    generate_config_files

    # Initialize the node
    initialize_node

    # Start services
    start_services

    # Verify installation
    if ! verify_installation; then
        print_warning "Installation verification had issues, but continuing..."
    fi

    # Display connection information
    display_connection_info

    print_success "Setup completed successfully!"
}

# Run main function
main "$@"
