#!/bin/bash
# one-click-setup.sh
# X Layer RPC Node One-Click Installation Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TODO: Change to main after release
REPO_BRANCH="feature/reth-rpc"
REPO_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/$REPO_BRANCH/scripts/rpc-setup"
TEMP_DIR="/tmp/xlayer-setup-$$"

# Default values
DEFAULT_NETWORK="testnet"
DEFAULT_RPC_TYPE="geth"
DEFAULT_DATA_DIR="./data"
DEFAULT_RPC_PORT="8123"
DEFAULT_ENGINE_API_PORT="8552"
DEFAULT_WS_PORT="8546"
DEFAULT_NODE_RPC_PORT="9545"
DEFAULT_RPC_P2P_PORT="30303"
DEFAULT_NODE_P2P_PORT="9223"

# Testnet configuration
TESTNET_BOOTNODE_OP_NODE="enode://eaae9fe2fc758add65fe4cfd42918e898e16ab23294db88f0dcdbcab2773e75bbea6bfdaa42b3ed502dfbee1335c242c602078c4aa009264e4705caa20d3dca7@8.210.181.50:9223"
TESTNET_BOOTNODE_OP_GETH="enode://2104d54a7fbd58a408590035a3628f1e162833c901400d490ccc94de416baf13639ce2dad388b7a5fd43c535468c106b660d42d94451e39b08912005aa4e4195@8.210.181.50:30303"
TESTNET_OP_STACK_IMAGE="xlayer/op-stack:release-testnet"
TESTNET_OP_GETH_IMAGE="xlayer/op-geth:release-testnet"
TESTNET_OP_RETH_IMAGE="xlayer/op-reth:release-testnet"

# Mainnet configuration (for future use)
MAINNET_BOOTNODE_OP_NODE=""
MAINNET_BOOTNODE_OP_GETH=""
MAINNET_OP_STACK_IMAGE="xlayer/op-stack:release"
MAINNET_OP_GETH_IMAGE="xlayer/op-geth:release"
MAINNET_OP_RETH_IMAGE="xlayer/op-reth:release"

# User input variables
NETWORK_TYPE=""
L1_RPC_URL=""
L1_BEACON_URL=""
DATA_DIR=""
RPC_PORT=""
ENG_PORT=""
WS_PORT=""
NODE_RPC_PORT=""
RPC_P2P_PORT=""
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

    # Check if running on Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        print_warning "This script is designed for Linux systems. You're running on $OSTYPE"
        print_warning "Proceeding anyway, but some features may not work correctly."
    fi

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

    # Check available memory (minimum 8GB)
    if command -v free &> /dev/null; then
        MEMORY_GB=$(free -g | awk '/^Mem:/{print $2}')
        if [ "$MEMORY_GB" -lt 8 ]; then
            print_warning "Available memory is ${MEMORY_GB}GB. Minimum 8GB recommended."
        fi
    fi

    # Check available disk space (minimum 100GB)
    if command -v df &> /dev/null; then
        DISK_SPACE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
        if [ "$DISK_SPACE" -lt 100 ]; then
            print_warning "Available disk space is ${DISK_SPACE}GB. Minimum 100GB recommended."
        fi
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
    mkdir -p "$TEMP_DIR"

    # Download configuration files
    local config_files=(
        "config/rollup.json"
        "config/op-geth-config-testnet.toml"
        "config/op-reth-config-testnet.toml"
        "entrypoint/reth-rpc.sh"
        "docker-compose.yml"
        "env.example"
        "init.sh"
        "start.sh"
        "stop.sh"
    )

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
        L2_ENGINEKIND="$DEFAULT_RPC_TYPE"
        DATA_DIR="$DEFAULT_DATA_DIR"
        RPC_PORT="$DEFAULT_RPC_PORT"
        ENG_PORT="$DEFAULT_ENGINE_API_PORT"
        WS_PORT="$DEFAULT_WS_PORT"
        NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
        RPC_P2P_PORT="$DEFAULT_RPC_P2P_PORT"
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

    # Check if mainnet is supported
    if [[ "$NETWORK_TYPE" == "mainnet" ]]; then
        print_error "Mainnet is not currently supported"
        print_info "Please use 'testnet' for now. Mainnet support will be available in future releases."
        exit 1
    fi

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

    # RPC Type
    while true; do
        echo -n "4. RPC Type (geth/reth) [default: $DEFAULT_RPC_TYPE]: "
        read -r input
        L2_ENGINEKIND="${input:-$DEFAULT_RPC_TYPE}"
        if [[ "$L2_ENGINEKIND" == "geth" || "$L2_ENGINEKIND" == "reth" ]]; then
            break
        else
            print_error "Invalid RPC type. Please enter 'geth' or 'reth'"
        fi
    done

    echo -n "5. Data directory [default: $DEFAULT_DATA_DIR]: "
    read -r input
    DATA_DIR="${input:-$DEFAULT_DATA_DIR}"

    while true; do
        echo -n "6. RPC port [default: $DEFAULT_RPC_PORT]: "
        read -r input
        RPC_PORT="${input:-$DEFAULT_RPC_PORT}"
        if validate_port "$RPC_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done

    while true; do
        echo -n "7. Engine API port [default: $DEFAULT_ENGINE_API_PORT]: "
        read -r input
        ENG_PORT="${input:-$DEFAULT_ENGINE_API_PORT}"
        if validate_port "$ENG_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done

    while true; do
        echo -n "8. WebSocket port [default: $DEFAULT_WS_PORT]: "
        read -r input
        WS_PORT="${input:-$DEFAULT_WS_PORT}"
        if validate_port "$WS_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done

    while true; do
        echo -n "9. Node RPC port [default: $DEFAULT_NODE_RPC_PORT]: "
        read -r input
        NODE_RPC_PORT="${input:-$DEFAULT_NODE_RPC_PORT}"
        if validate_port "$NODE_RPC_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done

    while true; do
        echo -n "10. RPC P2P port [default: $DEFAULT_RPC_P2P_PORT]: "
        read -r input
        RPC_P2P_PORT="${input:-$DEFAULT_RPC_P2P_PORT}"
        if validate_port "$RPC_P2P_PORT"; then
            break
        else
            print_error "Invalid port number. Must be between 1 and 65535"
        fi
    done

    while true; do
        echo -n "11. Node P2P port [default: $DEFAULT_NODE_P2P_PORT]: "
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
    if ! cd "$WORK_DIR"; then
        print_error "Failed to change to working directory: $WORK_DIR"
        exit 1
    fi

    # Create necessary directories
    if ! mkdir -p config entrypoint data/op-node/p2p; then
        print_error "Failed to create necessary directories"
        exit 1
    fi

    # Generate .env file
    print_info "Generating .env file..."

    # Set bootnode configuration based on network type
    local BOOTNODE_OP_NODE
    local BOOTNODE_OP_GETH
    local OP_STACK_IMAGE
    local OP_GETH_IMAGE
    local OP_RETH_IMAGE

    if [[ "$NETWORK_TYPE" == "mainnet" ]]; then
        BOOTNODE_OP_NODE="$MAINNET_BOOTNODE_OP_NODE"
        BOOTNODE_OP_GETH="$MAINNET_BOOTNODE_OP_GETH"
        OP_STACK_IMAGE="$MAINNET_OP_STACK_IMAGE"
        OP_GETH_IMAGE="$MAINNET_OP_GETH_IMAGE"
        OP_RETH_IMAGE="$MAINNET_OP_RETH_IMAGE"
    else
        BOOTNODE_OP_NODE="$TESTNET_BOOTNODE_OP_NODE"
        BOOTNODE_OP_GETH="$TESTNET_BOOTNODE_OP_GETH"
        OP_STACK_IMAGE="$TESTNET_OP_STACK_IMAGE"
        OP_GETH_IMAGE="$TESTNET_OP_GETH_IMAGE"
        OP_RETH_IMAGE="$TESTNET_OP_RETH_IMAGE"
    fi

    cat > .env << EOF
# X Layer $NETWORK_TYPE Configuration
L1_RPC_URL=$L1_RPC_URL
L1_BEACON_URL=$L1_BEACON_URL

# Bootnode Configuration
OP_NODE_BOOTNODE=$BOOTNODE_OP_NODE
OP_GETH_BOOTNODE=$BOOTNODE_OP_GETH

# RPC Type
L2_ENGINEKIND=$L2_ENGINEKIND
RPC_TYPE=op-$L2_ENGINEKIND

# Docker Image Tags
OP_STACK_IMAGE_TAG=$OP_STACK_IMAGE
OP_GETH_IMAGE_TAG=$OP_GETH_IMAGE
OP_RETH_IMAGE_TAG=$OP_RETH_IMAGE

# Ports
HTTP_RPC_PORT=$RPC_PORT
ENGINE_API_PORT=$ENG_PORT
WEBSOCKET_PORT=$WS_PORT
P2P_TCP_PORT=$RPC_P2P_PORT
P2P_UDP_PORT=$RPC_P2P_PORT
NODE_RPC_PORT=$NODE_RPC_PORT
NODE_P2P_PORT=$NODE_P2P_PORT
EOF

    # Copy configuration files from temp directory
    print_info "Copying configuration files..."

    # Verify and copy files
    local files_to_copy=(
        "$TEMP_DIR/config/rollup.json:config/"
        "$TEMP_DIR/config/op-geth-config-testnet.toml:config/"
        "$TEMP_DIR/docker-compose.yml:."
        "$TEMP_DIR/config/op-reth-config-testnet.toml:config/"
        "$TEMP_DIR/entrypoint/reth-rpc.sh:entrypoint/"
        "$TEMP_DIR/init.sh:."
        "$TEMP_DIR/start.sh:."
        "$TEMP_DIR/stop.sh:."
    )

    for file_pair in "${files_to_copy[@]}"; do
        local src="${file_pair%%:*}"
        local dst="${file_pair##*:}"
        if [ ! -f "$src" ]; then
            print_error "Required file not found: $src"
            exit 1
        fi
        if ! cp "$src" "$dst"; then
            print_error "Failed to copy $src to $dst"
            exit 1
        fi
    done

    # Set execute permissions
    local exec_files=(
        "./entrypoint/reth-rpc.sh"
        "./init.sh"
        "./start.sh"
        "./stop.sh"
    )

    for exec_file in "${exec_files[@]}"; do
        if ! chmod +x "$exec_file"; then
            print_error "Failed to set execute permission on $exec_file"
            exit 1
        fi
    done

    print_success "Configuration files generated successfully"
}

# Function to initialize the node
initialize_node() {
    print_info "Initializing X Layer RPC node..."

    if [ ! -f "./init.sh" ]; then
        print_error "init.sh not found in current directory"
        exit 1
    fi

    if ! ./init.sh "$NETWORK_TYPE"; then
        print_error "Node initialization failed"
        exit 1
    fi

    print_success "X Layer RPC node initialization completed"
}

# Function to start services
start_services() {
    print_info "Starting Docker services..."

    if [ ! -f "./start.sh" ]; then
        print_error "start.sh not found in current directory"
        exit 1
    fi

    if ! ./start.sh "$NETWORK_TYPE"; then
        print_error "Failed to start services"
        exit 1
    fi

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
    echo "  View logs: $DOCKER_COMPOSE_CMD logs -f"
    echo "  Stop services: $DOCKER_COMPOSE_CMD down"
    echo "  Restart services: $DOCKER_COMPOSE_CMD restart"
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

    # Download configuration files
    download_config_files

    # Get user input
    get_user_input

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
