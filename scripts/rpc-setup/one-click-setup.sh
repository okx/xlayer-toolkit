#!/bin/bash
set -e
# set -x

BRANCH="zjg/reth"
REPO_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/${BRANCH}/scripts/rpc-setup"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"  # Working directory is where the user runs the script

# Repository detection
IN_REPO=false
REPO_ROOT=""
REPO_RPC_SETUP_DIR=""

# Detect if running from repository (check if docker-compose.yml exists in SCRIPT_DIR)
detect_repository() {
    if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        IN_REPO=true
        REPO_RPC_SETUP_DIR="$SCRIPT_DIR"
        REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
    fi
}

# Load configuration from latest.cfg
load_configuration() {
    local config_file="$WORK_DIR/latest.cfg"
    
    # Try to get latest.cfg to current directory if not already present
    if [ ! -f "$config_file" ]; then
        if [ "$IN_REPO" = true ] && [ -f "$REPO_RPC_SETUP_DIR/latest.cfg" ]; then
            # Copy from local repository
            cp "$REPO_RPC_SETUP_DIR/latest.cfg" "$config_file"
            print_info "Using configuration from local repository"
        else
            # Download from GitHub
            print_info "Downloading configuration file..."
            local config_url="${REPO_URL}/latest.cfg"
            if ! wget -q "$config_url" -O "$config_file" 2>/dev/null; then
                print_error "Failed to download configuration file from GitHub"
                print_info "This script requires network-specific configuration (bootnodes, image tags, etc.)"
                print_info "Please ensure you have internet connectivity or run from within the repository"
                exit 1
            fi
        fi
    fi
    
    # Source the config file (will override built-in defaults)
    source "$config_file"
    print_success "Configuration loaded successfully"
}

# User input variables (runtime values, not in config file)
NETWORK_TYPE=""
RPC_TYPE=""
L1_RPC_URL=""
L1_BEACON_URL=""
DATA_DIR=""
RPC_PORT=""
WS_PORT=""
NODE_RPC_PORT=""
GETH_P2P_PORT=""
NODE_P2P_PORT=""

print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_prompt() { 
    printf "\033[0;34m%s\033[0m" "$1" > /dev/tty
}

# Load network-specific configuration dynamically
load_network_config() {
    local network=$1
    # Convert to uppercase using tr (more compatible)
    local prefix=$(echo "$network" | tr '[:lower:]' '[:upper:]')
    
    # Dynamically set variables based on network prefix
    eval "OP_NODE_BOOTNODE=\${${prefix}_BOOTNODE_OP_NODE}"
    eval "OP_GETH_BOOTNODE=\${${prefix}_GETH_BOOTNODE}"
    eval "P2P_STATIC=\${${prefix}_P2P_STATIC}"
    eval "OP_STACK_IMAGE_TAG=\${${prefix}_OP_STACK_IMAGE}"
    eval "OP_GETH_IMAGE_TAG=\${${prefix}_OP_GETH_IMAGE}"
    eval "OP_RETH_IMAGE_TAG=\${${prefix}_OP_RETH_IMAGE}"
    eval "GENESIS_URL=\${${prefix}_GENESIS_URL}"
    eval "SEQUENCER_HTTP=\${${prefix}_SEQUENCER_HTTP}"
    eval "ROLLUP_CONFIG=\${${prefix}_ROLLUP_CONFIG}"
    eval "GETH_CONFIG=\${${prefix}_GETH_CONFIG}"
    eval "RETH_CONFIG=\${${prefix}_RETH_CONFIG}"
    
    # Validate that configuration was loaded
    if [ -z "$OP_STACK_IMAGE_TAG" ]; then
        print_error "Failed to load configuration for network: $network"
        exit 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check Docker and Docker Compose
check_docker() {
    print_info "Checking Docker environment..."
    
    # Check Docker
    if command_exists docker; then
        local docker_version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "  ✓ docker ($docker_version)"
    else
        echo "  ✗ docker (missing)"
        print_error "Docker is not installed. Please install Docker 20.10+ first."
        print_info "Visit: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Check Docker Compose
    if command_exists docker-compose; then
        local compose_version=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "  ✓ docker-compose ($compose_version)"
    elif docker compose version &> /dev/null; then
        local compose_version=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "  ✓ docker compose ($compose_version)"
    else
        echo "  ✗ docker compose (missing)"
        print_error "Docker Compose is not installed. Please install Docker Compose 2.0+ first."
        print_info "Visit: https://docs.docker.com/compose/install/"
        exit 1
    fi
    
    # Check Docker daemon
    if docker info &> /dev/null; then
        echo "  ✓ docker daemon (running)"
    else
        echo "  ✗ docker daemon (not running)"
        print_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
}

# Check required system tools
check_required_tools() {
    local missing_required=()
    local missing_optional=()
    
    # Required tools
    local required_tools=("wget" "tar" "openssl" "curl" "sed" "make")
    
    # Optional tools (script works without them but with degraded functionality)
    local optional_tools=("jq")
    
    print_info "Checking required tools..."
    for tool in "${required_tools[@]}"; do
        if command_exists "$tool"; then
            echo "  ✓ $tool"
        else
            missing_required+=("$tool")
            echo "  ✗ $tool (missing)"
        fi
    done
    
    print_info "Checking optional tools..."
    for tool in "${optional_tools[@]}"; do
        if command_exists "$tool"; then
            echo "  ✓ $tool"
        else
            missing_optional+=("$tool")
            echo "  ⚠ $tool (optional, recommended)"
        fi
    done
    
    # Exit if required tools are missing
    if [ ${#missing_required[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_required[*]}"
        print_info "Please install them first. Example:"
        echo "  # macOS:"
        echo "  brew install ${missing_required[*]}"
        echo ""
        echo "  # Ubuntu/Debian:"
        echo "  sudo apt-get install ${missing_required[*]}"
        exit 1
    fi
    
    # Warn if optional tools are missing
    if [ ${#missing_optional[@]} -gt 0 ]; then
        print_warning "Optional tools not found: ${missing_optional[*]}"
        print_info "The script will work but some features may be slower"
    fi
}

check_system_requirements() {
    print_info "Checking system requirements..."
    check_docker
    check_required_tools
    print_success "All system requirements satisfied"
}

# Get file from repository or download from GitHub
get_file_from_source() {
    local file=$1
    local target_path="$WORK_DIR/$file"
    
    # If file already exists in work directory, skip
    if [ -f "$target_path" ]; then
        print_info "✓ Using existing $file"
        return 0
    fi
    
    # Try to copy from local repository
    if [ "$IN_REPO" = true ]; then
        local source_path="$REPO_RPC_SETUP_DIR/$file"
        if [ -f "$source_path" ]; then
            cp "$source_path" "$target_path"
            print_success "Copied $file from local repository"
            return 0
        fi
    fi
    
    # Download from GitHub
    local url="${REPO_URL}/${file}"
    print_info "Downloading $file from GitHub..."
    if wget -q "$url" -O "$target_path"; then
        print_success "Downloaded $file"
        return 0
    else
        print_error "Failed to get $file"
        return 1
    fi
}

check_required_files() {
    print_info "Checking required files..."
    
    local files=("Makefile" "docker-compose.yml")
    
    for file in "${files[@]}"; do
        if ! get_file_from_source "$file"; then
            print_error "Failed to get required file: $file"
            exit 1
        fi
    done
    
    print_success "Required files ready"
}

# Get configuration files based on network and RPC type
download_config_files() {
    print_info "Getting configuration files..."
    
    load_network_config "$NETWORK_TYPE"
    
    # Determine CONFIG_DIR early
    local chaindata_base="chaindata/${NETWORK_TYPE}-${RPC_TYPE}"
    local config_dir="${chaindata_base}/config"
    mkdir -p "$config_dir"
    
    local config_files=("config/$ROLLUP_CONFIG")
    
    # Add execution client config
    [ "$RPC_TYPE" = "reth" ] && config_files+=("config/$RETH_CONFIG") || config_files+=("config/$GETH_CONFIG")
    
    for file in "${config_files[@]}"; do
        local filename=$(basename "$file")
        local target="$config_dir/$filename"
        
        # Try to copy from local repository first
        if [ "$IN_REPO" = true ] && [ -f "$REPO_RPC_SETUP_DIR/$file" ]; then
            cp "$REPO_RPC_SETUP_DIR/$file" "$target"
            print_info "✓ Copied $filename from local repository"
        else
            # Download from GitHub
            print_info "Downloading $filename from GitHub..."
            if ! wget -q "$REPO_URL/$file" -O "$target"; then
                print_error "Failed to get $file"
                exit 1
            fi
        fi
    done
    
    print_success "Configuration files ready"
}

# Generic input prompt with validation
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local validator=$3
    local result
    
    while true; do
        print_prompt "$prompt_text"
        read -r input </dev/tty
        result="${input:-$default_value}"
        
        # If validator function provided, call it
        if [ -n "$validator" ] && ! $validator "$result"; then
            continue
        fi
        
        echo "$result"
        return 0
    done
}

# Validators
validate_network() {
    [[ "$1" =~ ^(testnet|mainnet)$ ]] || { print_error "Invalid network type"; return 1; }
}

validate_rpc_type() {
    [[ "$1" =~ ^(geth|reth)$ ]] || { print_error "Invalid RPC type"; return 1; }
}

validate_url() {
    [[ "$1" =~ ^https?:// ]] || { print_error "Please enter a valid HTTP/HTTPS URL"; return 1; }
}

get_user_input() {
    print_info "Please provide the following information:"
    echo ""
    
    # Auto-mode detection (curl | bash)
    if [ ! -t 0 ]; then
        print_info "🚀 Auto-mode: Using default configuration"
        NETWORK_TYPE="$DEFAULT_NETWORK"
        RPC_TYPE="geth"
        L1_RPC_URL="https://placeholder-l1-rpc-url"
        L1_BEACON_URL="https://placeholder-l1-beacon-url"
        DATA_DIR="chaindata/${NETWORK_TYPE}-${RPC_TYPE}/data"
        RPC_PORT="$DEFAULT_RPC_PORT"
        WS_PORT="$DEFAULT_WS_PORT"
        NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
        GETH_P2P_PORT="$DEFAULT_GETH_P2P_PORT"
        NODE_P2P_PORT="$DEFAULT_NODE_P2P_PORT"
        print_warning "⚠️  L1 URLs will need to be configured after setup"
        return 0
    fi
    
    # Interactive mode
    NETWORK_TYPE=$(prompt_input "1. Network type (testnet/mainnet) [default: $DEFAULT_NETWORK]: " "$DEFAULT_NETWORK" "validate_network")
    RPC_TYPE=$(prompt_input "2. RPC client type (geth/reth) [default: geth]: " "geth" "validate_rpc_type")
    
    # L1 URLs (required)
    while true; do
        print_prompt "3. L1 RPC URL (Ethereum L1 RPC endpoint): "
        read -r L1_RPC_URL </dev/tty
        [ -n "$L1_RPC_URL" ] && validate_url "$L1_RPC_URL" && break
    done
    
    while true; do
        print_prompt "4. L1 Beacon URL (Ethereum L1 Beacon chain endpoint): "
        read -r L1_BEACON_URL </dev/tty
        [ -n "$L1_BEACON_URL" ] && validate_url "$L1_BEACON_URL" && break
    done
    
    # Optional configurations
    echo ""
    print_info "Optional configurations (press Enter to use defaults):"
    
    local default_data_dir="chaindata/${NETWORK_TYPE}-${RPC_TYPE}/data"
    DATA_DIR=$(prompt_input "5. Data directory [default: $default_data_dir]: " "$default_data_dir" "")
    RPC_PORT=$(prompt_input "6. RPC port [default: $DEFAULT_RPC_PORT]: " "$DEFAULT_RPC_PORT" "")
    WS_PORT=$(prompt_input "7. WebSocket port [default: $DEFAULT_WS_PORT]: " "$DEFAULT_WS_PORT" "")
    NODE_RPC_PORT=$(prompt_input "8. Node RPC port [default: $DEFAULT_NODE_RPC_PORT]: " "$DEFAULT_NODE_RPC_PORT" "")
    GETH_P2P_PORT=$(prompt_input "9. Execution client P2P port [default: $DEFAULT_GETH_P2P_PORT]: " "$DEFAULT_GETH_P2P_PORT" "")
    NODE_P2P_PORT=$(prompt_input "10. Node P2P port [default: $DEFAULT_NODE_P2P_PORT]: " "$DEFAULT_NODE_P2P_PORT" "")
    
    print_success "Configuration input completed"
}

generate_or_verify_jwt() {
    local jwt_file=$1
    
    print_info "Checking JWT secret..."
    
    # Generate if not exists
    if [ ! -s "$jwt_file" ]; then
        openssl rand -hex 32 | tr -d '\n' > "$jwt_file"
        print_success "JWT secret generated"
        return 0
    fi
    
    # Verify existing JWT format (should be 64 hex characters)
    local jwt_content=$(cat "$jwt_file" 2>/dev/null | tr -d '\n\r ' || echo "")
    if [ ${#jwt_content} -ne 64 ]; then
        print_warning "JWT file has incorrect format (expected 64 hex chars, got ${#jwt_content}), regenerating..."
        openssl rand -hex 32 | tr -d '\n' > "$jwt_file"
        print_success "JWT secret regenerated"
    else
        print_info "Using existing JWT secret"
    fi
}

generate_config_files() {
    print_info "Generating configuration files..."
    
    cd "$WORK_DIR" || exit 1
    load_network_config "$NETWORK_TYPE"
    
    # Set execution client specific variables
    if [ "$RPC_TYPE" = "reth" ]; then
        EXEC_IMAGE_TAG="$OP_RETH_IMAGE_TAG"
        EXEC_CONFIG="$RETH_CONFIG"
        EXEC_CLIENT="op-reth"
    else
        EXEC_IMAGE_TAG="$OP_GETH_IMAGE_TAG"
        EXEC_CONFIG="$GETH_CONFIG"
        EXEC_CLIENT="op-geth"
    fi
    
    # Unified directory structure
    CHAINDATA_BASE="chaindata/${NETWORK_TYPE}-${RPC_TYPE}"
    DATA_DIR="${DATA_DIR:-${CHAINDATA_BASE}/data}"
    CONFIG_DIR="${CHAINDATA_BASE}/config"
    LOGS_DIR="${CHAINDATA_BASE}/logs"
    GENESIS_FILE="genesis-${NETWORK_TYPE}.json"
    
    # Create directory structure
    mkdir -p "$CONFIG_DIR" "$DATA_DIR/op-node/p2p" \
        "$LOGS_DIR/op-geth" "$LOGS_DIR/op-node" "$LOGS_DIR/op-reth"
    
    # Generate and verify JWT
    generate_or_verify_jwt "$CONFIG_DIR/jwt.txt"
    
    # Note: Configuration files are already downloaded to CONFIG_DIR by download_config_files()
    
    # Generate .env file
    generate_env_file
    
    print_success "Configuration files generated"
}

generate_env_file() {
    print_info "Generating .env file..."
    
    # Determine L2 engine URL based on RPC type (use service name, not container name)
    local l2_engine_url
    if [ "$RPC_TYPE" = "reth" ]; then
        l2_engine_url="http://op-reth:8552"
    else
        l2_engine_url="http://op-geth:8552"
    fi
    
    cat > .env << EOF
# X Layer RPC Node Configuration
# Generated by one-click-setup.sh

# Network Configuration
NETWORK_TYPE=$NETWORK_TYPE
RPC_TYPE=$RPC_TYPE

# L2 Engine URL (Docker Compose service name)
L2_ENGINE_URL=$l2_engine_url

# L1 Configuration
L1_RPC_URL=$L1_RPC_URL
L1_BEACON_URL=$L1_BEACON_URL

# Bootnode Configuration  
OP_NODE_BOOTNODE=$OP_NODE_BOOTNODE
OP_GETH_BOOTNODE=$OP_GETH_BOOTNODE

# Docker Image Tags
OP_STACK_IMAGE_TAG=$OP_STACK_IMAGE_TAG
OP_GETH_IMAGE_TAG=$OP_GETH_IMAGE_TAG
OP_RETH_IMAGE_TAG=$OP_RETH_IMAGE_TAG

# Port Configuration
HTTP_RPC_PORT=${RPC_PORT:-8123}
WEBSOCKET_PORT=${WS_PORT:-8546}
ENGINE_API_PORT=8552
NODE_RPC_PORT=${NODE_RPC_PORT:-9545}
P2P_TCP_PORT=${GETH_P2P_PORT:-30303}
P2P_UDP_PORT=${GETH_P2P_PORT:-30303}
NODE_P2P_PORT=${NODE_P2P_PORT:-9223}

# Sequencer HTTP URL
SEQUENCER_HTTP_URL=$SEQUENCER_HTTP
EOF
    
    print_success ".env file generated"
}

download_genesis() {
    local genesis_url=$1
    local local_genesis_path=$2
    
    print_info "Preparing genesis file..."
    
    if [ -f "$local_genesis_path" ]; then
        print_info "Using local genesis file: $local_genesis_path"
        cp "$local_genesis_path" genesis.tar.gz
    else
        print_info "Downloading from $genesis_url..."
        if ! wget -c "$genesis_url" -O genesis.tar.gz; then
            print_error "Failed to download genesis file"
            exit 1
        fi
    fi
}

extract_genesis() {
    local target_dir=$1
    local target_file=$2
    
    print_info "Extracting genesis file..."
    
    if ! tar -xzf genesis.tar.gz -C "$target_dir/"; then
        print_error "Failed to extract genesis file"
        rm -f genesis.tar.gz
        exit 1
    fi
    
    # Handle different genesis file names
    if [ -f "$target_dir/merged.genesis.json" ]; then
        mv "$target_dir/merged.genesis.json" "$target_dir/$target_file"
    elif [ -f "$target_dir/genesis.json" ]; then
        mv "$target_dir/genesis.json" "$target_dir/$target_file"
    else
        print_error "Failed to find genesis.json in the archive"
        rm -f genesis.tar.gz
        exit 1
    fi
    
    rm -f genesis.tar.gz
    
    if [ ! -f "$target_dir/$target_file" ]; then
        print_error "Genesis file not found after extraction"
        exit 1
    fi
    
    print_success "Genesis file extracted to $target_dir/$target_file"
}

prepare_reth_genesis() {
    local genesis_file=$1
    
    print_info "Preparing genesis file for op-reth..."
    
    # Extract legacyXLayerBlock value
    local blkno
    if command_exists jq; then
        blkno=$(jq -r '.config.legacyXLayerBlock' "$genesis_file" 2>/dev/null || echo "")
    else
        blkno=$(grep "legacyXLayerBlock" "$genesis_file" | tr -d ', ' | cut -d ':' -f 2 || echo "")
    fi
    
    if [ -z "$blkno" ]; then
        print_error "Failed to extract legacyXLayerBlock from genesis file"
        exit 1
    fi
    
    print_info "Setting genesis block number to $blkno (0x$(printf '%x' $blkno))"
    
    # Update genesis file with correct block number
    if command_exists jq; then
        jq ".number = \"0x$(printf '%x' $blkno)\"" "$genesis_file" > "$genesis_file.tmp"
        mv "$genesis_file.tmp" "$genesis_file"
    else
        # Fallback to sed
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' 's/"number": "0x0"/"number": "0x'"$(printf '%x' $blkno)"'"/' "$genesis_file"
        else
            sed -i 's/"number": "0x0"/"number": "0x'"$(printf '%x' $blkno)"'"/' "$genesis_file"
        fi
    fi
    
    print_success "Genesis file prepared with block number $blkno"
}

init_geth() {
    local data_dir=$1
    local genesis_file=$2
    
    print_info "Initializing op-geth... (This may take a while)"
    
    if ! docker run --rm \
        -v "$(pwd)/$data_dir:/data" \
        -v "$(pwd)/$genesis_file:/genesis.json" \
        "${OP_GETH_IMAGE_TAG}" \
        --datadir /data \
        --gcmode=archive \
        --db.engine=pebble \
        --log.format json \
        init \
        --state.scheme=hash \
        /genesis.json; then
        print_error "Failed to initialize op-geth"
        exit 1
    fi
    
    print_success "op-geth initialized successfully"
}

initialize_node() {
    print_info "Initializing X Layer RPC node..."
    
    cd "$WORK_DIR" || exit 1
    
    # Determine local genesis file path
    local local_genesis
    [ "$NETWORK_TYPE" = "testnet" ] && local_genesis="$LOCAL_TESTNET_GENESIS" || local_genesis="$LOCAL_MAINNET_GENESIS"
    
    # Download and extract genesis
    download_genesis "$GENESIS_URL" "$local_genesis"
    extract_genesis "$CONFIG_DIR" "$GENESIS_FILE"
    
    # Initialize execution client
    if [ "$RPC_TYPE" = "reth" ]; then
        prepare_reth_genesis "$CONFIG_DIR/$GENESIS_FILE"
        print_success "op-reth setup completed!"
        print_info "Note: op-reth will auto-initialize on first startup"
    else
        init_geth "$DATA_DIR" "$CONFIG_DIR/$GENESIS_FILE"
    fi
    
    print_success "Node initialization completed"
    print_info "Generated directories for $NETWORK_TYPE with $RPC_TYPE:"
    print_info "  - $DATA_DIR: Blockchain data"
    print_info "  - $CONFIG_DIR: Configuration files"
    print_info "  - $LOGS_DIR: Log files"
}

start_services() {
    print_info "Starting Docker services..."
    
    cd "$WORK_DIR" || exit 1
    
    if [ ! -f "./Makefile" ]; then
        print_error "Makefile not found in $WORK_DIR"
        exit 1
    fi
    
    print_info "Running 'make start'..."
    if ! make start; then
        print_error "Failed to start services"
        exit 1
    fi
    
    print_success "Services started successfully"
}

main() {
    echo "  X Layer RPC Node One-Click Setup"
    detect_repository
    if [ "$IN_REPO" = true ]; then
        print_info "📂 Running from repository: $REPO_ROOT"
    else
        print_info "🌐 Running standalone mode (will download files from GitHub)"
    fi
    
    # Load configuration first
    load_configuration
    
    # System checks
    check_system_requirements
    check_required_files
    
    # User interaction
    get_user_input
    
    # Setup process
    download_config_files
    generate_config_files
    initialize_node
    start_services
}

# Run main function
main "$@"
