#!/bin/bash
# one-click-setup.sh
# X Layer RPC Node One-Click Installation Script

set -e
set -x

# ============================================================================
# Script Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="/tmp/xlayer-setup-$$"

# Configuration file URL (will be downloaded before execution)
CONFIG_BASE_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/feature/reth-rpc-v1/scripts/rpc-setup"
CONFIG_FILE="latest.cfg"
LOCAL_CONFIG_FILE="$TEMP_DIR/$CONFIG_FILE"

# ============================================================================
# Local Genesis File Configuration (Optional - for Testing)
# ============================================================================
LOCAL_GENESIS_TESTNET="/Users/oker/Downloads/merged.genesis.json.testnet.tar.gz"
LOCAL_GENESIS_MAINNET="/Users/oker/Downloads/merged.genesis.json.mainnet.tar.gz"

# ============================================================================
# Color Output
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# User input variables
NETWORK_TYPE=""
L1_RPC_URL=""
L1_BEACON_URL=""
L2_ENGINEKIND=""
DOCKER_COMPOSE_CMD=""

# ============================================================================
# Utility Functions
# ============================================================================

# Function to print colored output
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

print_header() {
    echo -e "${BLUE}"
    echo "=========================================="
    echo "  X Layer RPC Node One-Click Setup"
    echo "=========================================="
    echo -e "${NC}"
}

# Function to validate port number
validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Function to prompt for port with validation
prompt_port() {
    local prompt_text=$1
    local default_value=$2
    local result_var=$3
    
    while true; do
        echo -n "$prompt_text [default: $default_value]: "
        read -r input
        local value="${input:-$default_value}"
        if validate_port "$value"; then
            eval "$result_var='$value'"
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done
}

# Function to prompt for URL with validation
prompt_url() {
    local prompt_text=$1
    local result_var=$2
    local required=${3:-true}
    
    while true; do
        echo -n "$prompt_text: "
        read -r url
        
        if [ -n "$url" ]; then
            if [[ "$url" =~ ^https?:// ]]; then
                eval "$result_var='$url'"
                break
            else
                print_error "Please enter a valid HTTP/HTTPS URL"
            fi
        elif [ "$required" = "false" ]; then
            eval "$result_var=''"
            break
        else
            print_error "This field is required"
        fi
    done
}

# ============================================================================
# Configuration Management
# ============================================================================

# Function to download and load configuration file
download_and_load_config() {
    print_info "Downloading latest configuration from remote repository..."
    mkdir -p "$TEMP_DIR"
    
    if wget -q "$CONFIG_BASE_URL/$CONFIG_FILE" -O "$LOCAL_CONFIG_FILE" 2>/dev/null; then
        print_success "Configuration file downloaded successfully"
    elif [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
        print_warning "Failed to download remote config, using local config file"
        cp "$SCRIPT_DIR/$CONFIG_FILE" "$LOCAL_CONFIG_FILE"
    else
        print_error "Failed to download configuration file and no local fallback found"
        exit 1
    fi
    
    print_info "Loading configuration..."
    # shellcheck disable=SC1090
    source "$LOCAL_CONFIG_FILE"
    REPO_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/$REPO_BRANCH/scripts/rpc-setup"
    print_success "Configuration loaded successfully"
}

# Function to load network-specific configuration (simplified with dynamic variable names)
load_network_config() {
    local network=$1
    [ "$network" != "testnet" ] && [ "$network" != "mainnet" ] && {
        print_error "Unknown network type: $network"
        exit 1
    }
    
    # Convert to uppercase for variable prefix (compatible with bash 3.x)
    local prefix=$(echo "$network" | tr '[:lower:]' '[:upper:]')
    
    # Load all configuration variables dynamically
    OP_NODE_BOOTNODE="${prefix}_BOOTNODE_OP_NODE"
    OP_NODE_BOOTNODE="${!OP_NODE_BOOTNODE}"
    P2P_STATIC="${prefix}_P2P_STATIC"
    P2P_STATIC="${!P2P_STATIC}"
    OP_STACK_IMAGE_TAG="${prefix}_OP_STACK_IMAGE"
    OP_STACK_IMAGE_TAG="${!OP_STACK_IMAGE_TAG}"
    OP_GETH_IMAGE_TAG="${prefix}_OP_GETH_IMAGE"
    OP_GETH_IMAGE_TAG="${!OP_GETH_IMAGE_TAG}"
    OP_RETH_IMAGE_TAG="${prefix}_OP_RETH_IMAGE"
    OP_RETH_IMAGE_TAG="${!OP_RETH_IMAGE_TAG}"
    GENESIS_URL="${prefix}_GENESIS_URL"
    GENESIS_URL="${!GENESIS_URL}"
    SEQUENCER_HTTP="${prefix}_SEQUENCER_HTTP"
    SEQUENCER_HTTP="${!SEQUENCER_HTTP}"
    ROLLUP_CONFIG="${prefix}_ROLLUP_CONFIG"
    ROLLUP_CONFIG="${!ROLLUP_CONFIG}"
    GETH_CONFIG="${prefix}_GETH_CONFIG"
    GETH_CONFIG="${!GETH_CONFIG}"
    RETH_CONFIG="${prefix}_RETH_CONFIG"
    RETH_CONFIG="${!RETH_CONFIG}"
}

# ============================================================================
# System Checks
# ============================================================================

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
    for tool in wget tar openssl; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "$tool is not installed. Please install it first."
            exit 1
        fi
    done

    print_success "System requirements check completed"
}

# ============================================================================
# User Input
# ============================================================================

get_user_input() {
    print_info "Please provide the following information:"
    echo ""

    # Check if running in non-interactive mode - use defaults
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        print_info "🚀 Auto-mode: Using default configuration"
        NETWORK_TYPE="$DEFAULT_NETWORK"
        L1_RPC_URL="https://placeholder-l1-rpc-url"
        L1_BEACON_URL="https://placeholder-l1-beacon-url"
        L2_ENGINEKIND="geth"
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
        [[ "$NETWORK_TYPE" == "testnet" || "$NETWORK_TYPE" == "mainnet" ]] && break
        print_error "Invalid network type. Please enter 'testnet' or 'mainnet'"
    done
    
    # L1 RPC URL
    prompt_url "2. L1 RPC URL (Ethereum L1 RPC endpoint)" L1_RPC_URL

    # L1 Beacon URL
    prompt_url "3. L1 Beacon URL (Ethereum L1 Beacon chain endpoint)" L1_BEACON_URL

    # Optional configurations
    echo ""
    print_info "Optional configurations (press Enter to use defaults):"
    
    # L2 Engine Type selection
    while true; do
        echo -n "4. L2 Engine Type (geth/reth) [default: geth]: "
        read -r input
        L2_ENGINEKIND="${input:-geth}"
        [[ "$L2_ENGINEKIND" == "geth" || "$L2_ENGINEKIND" == "reth" ]] && break
        print_error "Invalid engine type. Please enter 'geth' or 'reth'"
    done
    
    print_info "Note: Data will be stored in chaindata/${NETWORK_TYPE}-${L2_ENGINEKIND}/"
    
    # Port configurations
    prompt_port "5. RPC port" "$DEFAULT_RPC_PORT" RPC_PORT
    prompt_port "6. WebSocket port" "$DEFAULT_WS_PORT" WS_PORT
    prompt_port "7. Node RPC port" "$DEFAULT_NODE_RPC_PORT" NODE_RPC_PORT
    prompt_port "8. Geth P2P port" "$DEFAULT_GETH_P2P_PORT" GETH_P2P_PORT
    prompt_port "9. Node P2P port" "$DEFAULT_NODE_P2P_PORT" NODE_P2P_PORT
    
    print_success "Configuration input completed"
}

# ============================================================================
# Configuration File Management
# ============================================================================

download_config_files() {
    print_info "Downloading configuration files..."
    mkdir -p "$TEMP_DIR/config"
    load_network_config "$NETWORK_TYPE"
    
    # Determine which config files to download
    local config_files=("config/$ROLLUP_CONFIG")
    [ "$L2_ENGINEKIND" = "reth" ] && config_files+=("config/${RETH_CONFIG}") || config_files+=("config/$GETH_CONFIG")

    for file in "${config_files[@]}"; do
        print_info "Downloading $file..."
        local target_file="$TEMP_DIR/$file"
        mkdir -p "$(dirname "$target_file")"
        if ! wget -q "$REPO_URL/$file" -O "$target_file"; then
            print_error "Failed to download $file"
            exit 1
        fi
    done

    print_success "Configuration files downloaded successfully"
}

generate_env_and_configs() {
    print_info "Generating configuration files..."
    cd "$SCRIPT_DIR"
    load_network_config "$NETWORK_TYPE"
    
    # Setup directory structure
    CHAIN_DATA_ROOT="${CHAIN_DATA_ROOT:-chaindata}"
    CHAIN_DATA_DIR="$CHAIN_DATA_ROOT/${NETWORK_TYPE}-${L2_ENGINEKIND}"
    DATA_DIR="$CHAIN_DATA_DIR/data"
    CONFIG_DIR="$CHAIN_DATA_DIR/config"
    LOGS_DIR="$CHAIN_DATA_DIR/logs"
    GENESIS_FILE="genesis.json"
    
    print_info "📁 Data will be stored in: $CHAIN_DATA_DIR"
    mkdir -p "$CONFIG_DIR" "$DATA_DIR/op-node/p2p" "$DATA_DIR/op-reth" "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node" "$LOGS_DIR/op-reth"
    
    # Generate JWT secret
    if [ ! -s "$CONFIG_DIR/jwt.txt" ] || [ ${#$(cat "$CONFIG_DIR/jwt.txt" 2>/dev/null | tr -d '\n\r ')} -ne 64 ]; then
        print_info "Generating JWT secret for $NETWORK_TYPE..."
        openssl rand -hex 32 | tr -d '\n' > "$CONFIG_DIR/jwt.txt"
        print_success "JWT secret generated at $CONFIG_DIR/jwt.txt"
    else
        print_info "Using existing JWT secret from $CONFIG_DIR/jwt.txt"
    fi
    
    # Generate .env file
    print_info "Generating .env file..."
    cat > .env << EOF
# X Layer $NETWORK_TYPE Configuration
L1_RPC_URL=$L1_RPC_URL
L1_BEACON_URL=$L1_BEACON_URL

# Network Type
NETWORK_TYPE=$NETWORK_TYPE

# L2 Engine Type: geth or reth (Docker Compose profiles will be set automatically)
L2_ENGINEKIND=$L2_ENGINEKIND

# Data Directory Root
CHAIN_DATA_ROOT=chaindata

# Port Configuration
RPC_PORT=$RPC_PORT
WS_PORT=$WS_PORT
NODE_RPC_PORT=$NODE_RPC_PORT
GETH_P2P_PORT=$GETH_P2P_PORT
NODE_P2P_PORT=$NODE_P2P_PORT

# Network-specific configuration (auto-populated)
SEQUENCER_HTTP_URL=$SEQUENCER_HTTP
OP_NODE_BOOTNODE=$OP_NODE_BOOTNODE
P2P_STATIC=$P2P_STATIC

# Docker Image Tags
OP_STACK_IMAGE_TAG=$OP_STACK_IMAGE_TAG
OP_GETH_IMAGE_TAG=$OP_GETH_IMAGE_TAG
OP_RETH_IMAGE_TAG=$OP_RETH_IMAGE_TAG
EOF

    # Copy configuration files
    cp "$TEMP_DIR/config/$ROLLUP_CONFIG" "$CONFIG_DIR/"
    [ "$L2_ENGINEKIND" = "reth" ] && cp "$TEMP_DIR/config/${RETH_CONFIG}" "$CONFIG_DIR/" || cp "$TEMP_DIR/config/$GETH_CONFIG" "$CONFIG_DIR/"
    
    print_success "Configuration files generated successfully"
}

# ============================================================================
# Genesis and Initialization
# ============================================================================

download_and_extract_genesis() {
    local genesis_tar="$CHAIN_DATA_DIR/genesis.tar.gz"
    local local_genesis=$([ "$NETWORK_TYPE" = "testnet" ] && echo "$LOCAL_GENESIS_TESTNET" || echo "$LOCAL_GENESIS_MAINNET")
    local use_local=false
    
    # Determine genesis source
    if [ -n "$local_genesis" ] && [ -f "$local_genesis" ]; then
        print_info "Using local pre-downloaded genesis file: $local_genesis"
        cp "$local_genesis" "$genesis_tar"
        use_local=true
    else
        [ -n "$local_genesis" ] && print_warning "Local genesis file configured but not found: $local_genesis"
        print_info "Downloading genesis file from $GENESIS_URL..."
        wget -c "$GENESIS_URL" -O "$genesis_tar"
    fi
    
    # Extract genesis
    print_info "Extracting genesis file..."
    tar -xzf "$genesis_tar" -C "$CONFIG_DIR/"
    
    # Rename to standard name
    [ -f "$CONFIG_DIR/merged.genesis.json" ] && mv "$CONFIG_DIR/merged.genesis.json" "$CONFIG_DIR/$GENESIS_FILE"
    [ -f "$CONFIG_DIR/$GENESIS_FILE" ] || { print_error "Failed to find genesis.json in the archive"; exit 1; }
    
    # Cleanup
    if [ "$use_local" = "true" ]; then
        print_info "Keeping genesis archive for reuse: $genesis_tar"
    else
        rm "$genesis_tar"
        print_success "Temporary file removed: $genesis_tar"
    fi
    
    print_success "Genesis file extracted successfully to $CONFIG_DIR/$GENESIS_FILE"
}

modify_genesis_for_reth() {
    [ "$L2_ENGINEKIND" != "reth" ] && return
    
    print_info "📋 Modifying genesis.json for op-reth (updating number field)..."
    local blkno=$(grep "legacyXLayerBlock" "$CONFIG_DIR/$GENESIS_FILE" | tr -d ', ' | cut -d ':' -f 2)
    [ -z "$blkno" ] && { print_error "Failed to extract legacyXLayerBlock from $GENESIS_FILE"; exit 1; }
    
    # Use appropriate sed for macOS or Linux
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/"number": "0x0"/"number": "'"$blkno"'"/' "$CONFIG_DIR/$GENESIS_FILE"
    else
        sed -i 's/"number": "0x0"/"number": "'"$blkno"'"/' "$CONFIG_DIR/$GENESIS_FILE"
    fi
    print_success "Genesis file modified for op-reth (number set to $blkno)"
}

verify_genesis_chain_id() {
    print_info "Verifying genesis file chain ID..."
    command -v jq &> /dev/null || { print_warning "jq not found, skipping chain ID verification"; return; }
    
    local chain_id=$(jq -r '.config.chainId // .chainId' "$CONFIG_DIR/$GENESIS_FILE" 2>/dev/null || echo "")
    [ -z "$chain_id" ] && { print_warning "Could not read chain ID from genesis file, skipping verification"; return; }
    
    print_info "Genesis file chain ID: $chain_id"
    local expected_id=$([ "$NETWORK_TYPE" == "testnet" ] && echo "1952" || echo "196")
    [ "$chain_id" != "$expected_id" ] && {
        print_error "Genesis file chain ID mismatch! Expected $expected_id ($NETWORK_TYPE), got $chain_id"
        exit 1
    }
    print_success "Genesis file chain ID verified"
}

initialize_node() {
    print_info "Initializing X Layer RPC node..."
    load_network_config "$NETWORK_TYPE"
    
    # Check if already initialized
    if [ -d "$DATA_DIR/geth" ]; then
        print_warning "Data directory $DATA_DIR already contains a geth database."
        if [ -t 0 ] && [ -t 1 ]; then
            read -p "Do you want to remove the existing data and reinitialize? (y/N): " -r
            [[ ! $REPLY =~ ^[Yy]$ ]] && { print_success "Skipping initialization (using existing data)"; return 0; }
            print_info "Cleaning up old data directory..."
            rm -rf "$DATA_DIR"
            mkdir -p "$DATA_DIR/op-node/p2p"
            print_success "Old data removed"
        else
            print_info "Auto-mode: Keeping existing data directory"
            print_success "Skipping initialization (using existing data)"
            return 0
        fi
    fi
    
    # Process genesis file
    download_and_extract_genesis
    modify_genesis_for_reth
    verify_genesis_chain_id
    
    # Initialize based on engine type
    if [ "$L2_ENGINEKIND" = "geth" ]; then
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
        print_info "op-reth does not require initialization"
        print_info "Genesis file will be loaded automatically on first start"
        print_success "op-reth configuration ready"
    fi
    
    print_success "X Layer RPC node initialization completed"
}

# ============================================================================
# Service Management
# ============================================================================

start_services() {
    print_info "Starting Docker services..."
    load_network_config "$NETWORK_TYPE"
    
    # Reconstruct paths
    CHAIN_DATA_ROOT="${CHAIN_DATA_ROOT:-chaindata}"
    CHAIN_DATA_DIR="$CHAIN_DATA_ROOT/${NETWORK_TYPE}-${L2_ENGINEKIND}"
    CONFIG_DIR="$CHAIN_DATA_DIR/config"
    
    # Verify JWT file exists
    [ ! -f "$CONFIG_DIR/jwt.txt" ] && {
        print_error "JWT file not found at $CONFIG_DIR/jwt.txt"
        print_info "Please run the setup script again to generate JWT secret"
        exit 1
    }

    # Set environment variables and start
    export OP_GETH_IMAGE_TAG OP_STACK_IMAGE_TAG OP_RETH_IMAGE_TAG
    export COMPOSE_PROFILES="$L2_ENGINEKIND"  # Activate the correct Docker Compose profile
    $DOCKER_COMPOSE_CMD up -d
    print_success "X Layer RPC node startup completed"
}

verify_installation() {
    print_info "Verifying installation..."
    sleep 10

    [ ! -f "./docker-compose.yml" ] && { print_error "docker-compose.yml not found"; return 1; }

    # Check running services
    local running_services=$($DOCKER_COMPOSE_CMD ps --services --filter "status=running" 2>/dev/null | wc -l)
    [ "$running_services" -eq 0 ] && {
        print_error "No services are running"
        print_info "Check logs with: $DOCKER_COMPOSE_CMD logs"
        return 1
    }

    # Test RPC endpoint
    if command -v curl &> /dev/null; then
        print_info "Testing RPC endpoint..."
        if curl -s -X POST -H "Content-Type: application/json" \
            --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' \
            --max-time 5 "http://127.0.0.1:$RPC_PORT" > /dev/null 2>&1; then
            print_success "RPC endpoint is responding"
        else
            print_warning "RPC endpoint test failed, but services are running"
            print_info "The node may need more time to sync before accepting requests"
        fi
    fi

    print_success "Installation verification completed"
}

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
    echo "  View logs: $DOCKER_COMPOSE_CMD logs -f"
    echo "  Stop services: $DOCKER_COMPOSE_CMD down"
    echo "  Restart services: $DOCKER_COMPOSE_CMD restart"
    echo ""
    echo "📁 Working Directory: $(pwd)"
    echo "📁 Data Directory: $DATA_DIR"
    echo "🌍 Network: $NETWORK_TYPE"
    echo ""

    # Warn about placeholder URLs
    if [[ "$L1_RPC_URL" == "https://placeholder-l1-rpc-url" ]]; then
        echo "⚠️  IMPORTANT: Configure L1 RPC URLs to complete setup!"
        print_info "1. Edit .env file: nano .env"
        print_info "2. Update L1 URLs"
        print_info "3. Restart: $DOCKER_COMPOSE_CMD down && $DOCKER_COMPOSE_CMD up -d"
        echo ""
    fi

    print_info "Your X Layer RPC node is now running and ready to serve requests!"
}

# ============================================================================
# Main Execution
# ============================================================================

cleanup() {
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}

main() {
    trap cleanup EXIT
    download_and_load_config
    print_header
    check_system_requirements
    get_user_input
    download_config_files
    generate_env_and_configs
    initialize_node
    start_services
    verify_installation || print_warning "Installation verification had issues, but continuing..."
    display_connection_info
    print_success "Setup completed successfully!"
}

main "$@"
