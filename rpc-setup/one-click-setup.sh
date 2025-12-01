#!/bin/bash
set -e

# TODO: Change back to "main" after merging to main branch
BRANCH="geth-testnet-snapshot"
REPO_URL="https://raw.githubusercontent.com/okx/xlayer-toolkit/${BRANCH}/rpc-setup"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"  # Working directory is where the user runs the script

# Repository detection
IN_REPO=false
REPO_ROOT=""
REPO_RPC_SETUP_DIR=""

# Detect if running from repository (check if presets/ directory exists in SCRIPT_DIR)
# This is more reliable than checking docker-compose.yml which might be downloaded
detect_repository() {
    if [ -d "$SCRIPT_DIR/presets" ]; then
        IN_REPO=true
        REPO_RPC_SETUP_DIR="$SCRIPT_DIR"
        REPO_ROOT="$(dirname "$SCRIPT_DIR")"
    fi
}

# Load configuration from network-presets.env
load_configuration() {
    local config_file
    
    # If running from repository, use the file directly from presets/
    if [ "$IN_REPO" = true ] && [ -f "$REPO_RPC_SETUP_DIR/presets/network-presets.env" ]; then
        config_file="$REPO_RPC_SETUP_DIR/presets/network-presets.env"
        print_info "Using configuration from local repository"
    else
        # For standalone mode, download to work directory
        config_file="$WORK_DIR/network-presets.env"
        if [ ! -f "$config_file" ]; then
            print_info "Downloading configuration file..."
            local config_url="${REPO_URL}/presets/network-presets.env"
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
SYNC_MODE=""  # Sync mode: genesis or snapshot
L1_RPC_URL=""
L1_BEACON_URL=""
TARGET_DIR=""  # Target directory for configuration (${NETWORK_TYPE}-${RPC_TYPE})
SKIP_INIT=0  # Flag to skip initialization if directory exists
RPC_PORT=""
WS_PORT=""
NODE_RPC_PORT=""
GETH_P2P_PORT=""
NODE_P2P_PORT=""

print_info() { echo -e "\033[0;34mℹ️  $1\033[0m"; }
print_success() { echo -e "\033[0;32m✅ $1\033[0m"; }
print_warning() { echo -e "\033[1;33m⚠️  $1\033[0m"; }
print_error() { echo -e "\033[0;31m❌ $1\033[0m"; }
print_prompt() { 
    # Try /dev/tty first, fallback to stdout
    if ! printf "\033[0;34m%s\033[0m" "$1" > /dev/tty 2>/dev/null; then
        printf "\033[0;34m%s\033[0m" "$1"
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --rpc_type=<geth|reth>   RPC client type (default: geth)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Note: Network type (mainnet/testnet) will be prompted during setup"
    echo ""
    echo "Examples:"
    echo "  $0                  # Use default geth (network type will be prompted)"
    echo "  $0 --rpc_type=reth  # Use reth (network type will be prompted)"
}

# Parse command line arguments
parse_arguments() {
    for arg in "$@"; do
        case $arg in
            --rpc_type=*)
                RPC_TYPE="${arg#*=}"
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown argument: $arg"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set default for RPC_TYPE only
    RPC_TYPE="${RPC_TYPE:-geth}"
    
    # Validate RPC_TYPE if provided
    if ! validate_rpc_type "$RPC_TYPE"; then
        exit 1
    fi
}

# Check and display existing configurations
check_existing_configurations() {
    print_info "Checking existing configurations..."
    echo ""
    
    local has_configs=false
    
    for config in mainnet-geth mainnet-reth testnet-geth testnet-reth; do
        if [ -d "$config" ]; then
            has_configs=true
            local size=$(du -sh "$config" 2>/dev/null | cut -f1 || echo "unknown")
            if [ "$config" = "$TARGET_DIR" ]; then
                echo "  📦 $config ($size) ← Current"
            else
                echo "  📦 $config ($size)"
            fi
        fi
    done
    
    if [ "$has_configs" = false ]; then
        echo "  ℹ️  No existing configurations found"
    fi
    
    echo ""
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
    eval "LEGACY_RPC_URL=\${${prefix}_LEGACY_RPC_URL}"
    eval "LEGACY_RPC_TIMEOUT=\${${prefix}_LEGACY_RPC_TIMEOUT}"
    
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
    
    # Always need Makefile
    if ! get_file_from_source "Makefile"; then
        print_error "Failed to get required file: Makefile"
        exit 1
    fi
    
    # docker-compose.yml will be generated later based on sync mode
    # For genesis mode, we'll get it from source; for snapshot mode, we'll generate it
    
    print_success "Required files ready"
}

# Get configuration files based on network and RPC type
download_config_files() {
    print_info "Getting configuration files..."
    
    load_network_config "$NETWORK_TYPE"
    
    # Target directory config folder
    local config_dir="${TARGET_DIR}/config"
    mkdir -p "$config_dir"
    
    local config_files=("presets/$ROLLUP_CONFIG")
    
    # Add execution client config
    [ "$RPC_TYPE" = "reth" ] && config_files+=("presets/$RETH_CONFIG") || config_files+=("presets/$GETH_CONFIG")
    
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
    local input
    
    while true; do
        print_prompt "$prompt_text"
        # Try to read from /dev/tty, fallback to stdin if it fails
        if read -r input </dev/tty 2>/dev/null; then
            result="${input:-$default_value}"
        elif read -r input; then
            result="${input:-$default_value}"
        else
            # If both fail, use default value
            result="$default_value"
        fi
        
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

validate_sync_mode() {
    [[ "$1" =~ ^(genesis|snapshot)$ ]] || { print_error "Invalid sync mode. Must be 'genesis' or 'snapshot'"; return 1; }
}

validate_url() {
    [[ "$1" =~ ^https?:// ]] || { print_error "Please enter a valid HTTP/HTTPS URL"; return 1; }
}

# Validate if snapshot mode is supported for the given RPC type and network
validate_snapshot_support() {
    local rpc_type=$1
    local network=$2
    
    if [ "$rpc_type" != "geth" ]; then
        print_error "Snapshot mode is currently only supported for geth"
        print_info "Supported combinations:"
        print_info "  - geth + testnet: ✅ snapshot supported"
        print_info "  - geth + mainnet: ✅ snapshot supported"
        print_info "  - reth + testnet: ❌ snapshot not supported"
        print_info "  - reth + mainnet: ❌ snapshot not supported"
        print_info ""
        print_info "Please use 'genesis' sync mode for your selected configuration"
        return 1
    fi
    
    if [ "$network" != "testnet" ] && [ "$network" != "mainnet" ]; then
        print_error "Snapshot mode is currently only supported for testnet and mainnet"
        return 1
    fi
    
    return 0
}

check_existing_data() {
    local target_dir="$1"
    
    if [ ! -d "$target_dir" ]; then
        print_info "Directory does not exist, will initialize: $target_dir"
        return 0  # Continue with initialization
    fi
    
    print_warning "Directory already exists: $target_dir"
    echo ""
    
    # Display directory information
    local size=$(du -sh "$target_dir" 2>/dev/null | cut -f1 || echo "unknown")
    echo "  📂 Location: $target_dir"
    echo "  💾 Size: $size"
    
    # Check if initialized (different structure for snapshot vs genesis mode)
    # Note: SYNC_MODE is not yet set when this function is called, so we check both structures
    if [ -d "$target_dir/data" ] && [ "$(ls -A "$target_dir/data" 2>/dev/null)" ]; then
        echo "  ✅ Status: Initialized with data (genesis mode)"
    elif [ -d "$target_dir/op-geth" ] && [ "$(ls -A "$target_dir/op-geth" 2>/dev/null)" ]; then
        echo "  ✅ Status: Initialized with data (snapshot mode)"
    else
        echo "  ⚠️  Status: Empty or incomplete"
    fi
    
    echo ""
    echo "Options:"
    echo "  [1] Keep existing data and skip initialization (recommended)"
    echo "  [2] Delete and re-initialize (will lose all data)"
    echo "  [3] Cancel"
    echo ""
    
    while true; do
        print_prompt "Your choice [1/2/3, default: 1]: "
        if ! read -r choice </dev/tty 2>/dev/null && ! read -r choice; then
            choice="1"  # Default to keeping data if read fails
        fi
        choice="${choice:-1}"
        
        case $choice in
            1)
                print_success "Keeping existing data"
                return 1  # Skip initialization
                ;;
            2)
                print_warning "Deleting existing directory: $target_dir"
                if rm -rf "$target_dir"; then
                    print_success "Directory removed successfully"
                    return 0  # Continue with initialization
                else
                    print_error "Failed to remove directory"
                    exit 1
                fi
                ;;
            3)
                print_info "Setup cancelled by user"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 1, 2, or 3"
                ;;
        esac
    done
}

get_user_input() {
    print_info "Please provide the following information:"
    echo ""
    
    # Step 1: Network type (interactive)
    NETWORK_TYPE=$(prompt_input "1. Network type (testnet/mainnet) [default: $DEFAULT_NETWORK]: " "$DEFAULT_NETWORK" "validate_network")
    
    # Set target directory
    TARGET_DIR="${NETWORK_TYPE}-${RPC_TYPE}"
    
    # Step 1.5: Sync mode (interactive)
    SYNC_MODE=$(prompt_input "2. Sync mode (genesis/snapshot) [default: genesis]: " "genesis" "validate_sync_mode")
    
    # Validate snapshot support
    if [ "$SYNC_MODE" = "snapshot" ]; then
        if ! validate_snapshot_support "$RPC_TYPE" "$NETWORK_TYPE"; then
            exit 1
        fi
    fi
    
    # Step 3-4: L1 URLs (required)
    while true; do
        print_prompt "3. L1 RPC URL (Ethereum L1 RPC endpoint): "
        if ! read -r L1_RPC_URL </dev/tty 2>/dev/null && ! read -r L1_RPC_URL; then
            print_error "Failed to read input"
            exit 1
        fi
        [ -n "$L1_RPC_URL" ] && validate_url "$L1_RPC_URL" && break
    done
    
    while true; do
        print_prompt "4. L1 Beacon URL (Ethereum L1 Beacon chain endpoint): "
        if ! read -r L1_BEACON_URL </dev/tty 2>/dev/null && ! read -r L1_BEACON_URL; then
            print_error "Failed to read input"
            exit 1
        fi
        [ -n "$L1_BEACON_URL" ] && validate_url "$L1_BEACON_URL" && break
    done
    
    # Check existing data directory
    echo ""
    # Temporarily disable set -e to capture return value safely
    set +e
    check_existing_data "$TARGET_DIR"
    SKIP_INIT=$?  # Save return value: 0=initialize, 1=skip
    set -e
    
    # Optional configurations (always collect, regardless of SKIP_INIT)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Port Configuration (Step 2/2)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "Press Enter to use default values, or type new values:"
    echo ""
    
    RPC_PORT=$(prompt_input "5. RPC port [default: $DEFAULT_RPC_PORT]: " "$DEFAULT_RPC_PORT" "") || RPC_PORT="$DEFAULT_RPC_PORT"
    WS_PORT=$(prompt_input "6. WebSocket port [default: $DEFAULT_WS_PORT]: " "$DEFAULT_WS_PORT" "") || WS_PORT="$DEFAULT_WS_PORT"
    NODE_RPC_PORT=$(prompt_input "7. Node RPC port [default: $DEFAULT_NODE_RPC_PORT]: " "$DEFAULT_NODE_RPC_PORT" "") || NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
    GETH_P2P_PORT=$(prompt_input "8. Execution client P2P port [default: $DEFAULT_GETH_P2P_PORT]: " "$DEFAULT_GETH_P2P_PORT" "") || GETH_P2P_PORT="$DEFAULT_GETH_P2P_PORT"
    NODE_P2P_PORT=$(prompt_input "9. Node P2P port [default: $DEFAULT_NODE_P2P_PORT]: " "$DEFAULT_NODE_P2P_PORT" "") || NODE_P2P_PORT="$DEFAULT_NODE_P2P_PORT"
    
    print_info "Using ports: RPC=$RPC_PORT, WS=$WS_PORT, Node=$NODE_RPC_PORT"
    
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
    
    # Use different directory structure based on sync mode and network
    # Mainnet snapshot uses the same structure as genesis mode (nested: data/, config/, logs/)
    # Testnet snapshot uses flat structure (op-geth/, op-node/) - TODO: will be unified with mainnet
    if [ "$SYNC_MODE" = "snapshot" ] && [ "$NETWORK_TYPE" = "testnet" ]; then
        # Testnet snapshot: flat structure (op-geth, op-node at root) - temporary special handling
        CONFIG_DIR="${TARGET_DIR}/config"  # Not used in testnet snapshot mode
        LOGS_DIR="${TARGET_DIR}/logs"  # Not used in testnet snapshot mode
        GENESIS_FILE="genesis-${NETWORK_TYPE}.json"
        DATA_DIR="${TARGET_DIR}/data"  # Not used in testnet snapshot mode
        
        # Ensure snapshot directory exists (should be created by extract_snapshot)
        if [ ! -d "$TARGET_DIR" ]; then
            print_error "Snapshot directory not found: $TARGET_DIR. Please run extract_snapshot first."
            exit 1
        fi
        
        print_info "Using snapshot data directory: $TARGET_DIR (flat structure: op-geth, op-node)"
    else
        # Genesis mode OR mainnet snapshot: nested structure (data/, config/, logs/)
        DATA_DIR="${TARGET_DIR}/data"
        CONFIG_DIR="${TARGET_DIR}/config"
        LOGS_DIR="${TARGET_DIR}/logs"
        GENESIS_FILE="genesis-${NETWORK_TYPE}.json"
        
        if [ "$SYNC_MODE" = "snapshot" ]; then
            # Mainnet snapshot: directory already exists from extraction, just verify
            if [ ! -d "$TARGET_DIR" ]; then
                print_error "Snapshot directory not found: $TARGET_DIR. Please run extract_snapshot first."
                exit 1
            fi
            print_info "Using snapshot data directory: $TARGET_DIR (nested structure: data/, config/, logs/)"
        else
            # Genesis mode: create directory structure
            mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$DATA_DIR/op-node/p2p"
            
            # Create execution client specific data directory
            if [ "$RPC_TYPE" = "reth" ]; then
                mkdir -p "$DATA_DIR/op-reth"
            else
                mkdir -p "$DATA_DIR/op-geth"
            fi
            
            # Generate and verify JWT
            generate_or_verify_jwt "$CONFIG_DIR/jwt.txt"
        fi
    fi
    
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
    
    # Determine chain name based on network type
    local chain_name="xlayer-${NETWORK_TYPE}"
    
    cat > .env << EOF
# X Layer RPC Node Configuration
# Generated by one-click-setup.sh

# Network Configuration
NETWORK_TYPE=$NETWORK_TYPE
RPC_TYPE=$RPC_TYPE
SYNC_MODE=$SYNC_MODE
CHAIN_NAME=$chain_name

# Directory Configuration
TARGET_DIR=$TARGET_DIR

# L2 Engine URL (Docker Compose service name)
L2_ENGINE_URL=$l2_engine_url

# L1 Configuration
L1_RPC_URL=$L1_RPC_URL
L1_BEACON_URL=$L1_BEACON_URL

# Bootnode Configuration  
OP_NODE_BOOTNODE=$OP_NODE_BOOTNODE
OP_GETH_BOOTNODE=$OP_GETH_BOOTNODE
P2P_STATIC_PEERS=$P2P_STATIC

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

# Legacy RPC Configuration
LEGACY_RPC_URL=$LEGACY_RPC_URL
LEGACY_RPC_TIMEOUT=$LEGACY_RPC_TIMEOUT
EOF
    
    print_success ".env file generated"
}

download_genesis() {
    local genesis_url=$1
    local network=$2
    
    # Unified genesis filename with network type
    local genesis_file="genesis-${network}.tar.gz"
    
    print_info "Preparing genesis file for $network..."
    
    # Repository mode: check if file already exists (cache for faster re-runs)
    if [ "$IN_REPO" = true ] && [ -f "$genesis_file" ]; then
        local file_size=$(du -h "$genesis_file" 2>/dev/null | cut -f1 || echo "unknown")
        print_success "Using cached genesis: $genesis_file ($file_size)"
        print_info "Repository mode: Skip download, reusing existing file"
        return 0
    fi
    
    # Download genesis file
    if [ "$IN_REPO" = true ]; then
        print_info "Repository mode: Downloading (will be kept for next run)..."
    else
        print_info "Standalone mode: Downloading (will be cleaned up after use)..."
    fi
    
    if ! wget -c "$genesis_url" -O "$genesis_file"; then
        print_error "Failed to download genesis file"
        rm -f "$genesis_file"  # Clean up failed download
        exit 1
    fi
    
    if [ "$IN_REPO" = true ]; then
        print_success "Downloaded and cached: $genesis_file"
    else
        print_success "Downloaded: $genesis_file"
    fi
}

extract_genesis() {
    local target_dir=$1
    local target_file=$2
    
    # Get genesis filename (consistent with download_genesis)
    local genesis_file="genesis-${NETWORK_TYPE}.tar.gz"
    
    print_info "Extracting genesis file..."
    
    if ! tar -xzf "$genesis_file" -C "$target_dir/"; then
        print_error "Failed to extract genesis file"
        rm -f "$genesis_file"
        exit 1
    fi
    
    # Handle different genesis file names
    if [ -f "$target_dir/merged.genesis.json" ]; then
        mv "$target_dir/merged.genesis.json" "$target_dir/$target_file"
    elif [ -f "$target_dir/genesis.json" ]; then
        mv "$target_dir/genesis.json" "$target_dir/$target_file"
    else
        print_error "Failed to find genesis.json in the archive"
        rm -f "$genesis_file"
        exit 1
    fi
    
    # Standalone mode: clean up temporary file
    # if [ "$IN_REPO" = false ]; then
    #     rm -f "$genesis_file"
    #     print_info "Cleaned up temporary genesis file"
    # else
    #     print_info "Kept genesis file for future use: $genesis_file"
    # fi
    
    if [ ! -f "$target_dir/$target_file" ]; then
        print_error "Genesis file not found after extraction"
        exit 1
    fi
    
    print_success "Genesis file extracted to $target_dir/$target_file"
}

# Download snapshot for geth testnet
download_snapshot() {
    local target_dir=$1  # Target directory (e.g., testnet-geth or mainnet-geth)
    local network=$2     # Network type (testnet or mainnet)
    
    # Determine snapshot URL and file name based on network
    local snapshot_url
    local snapshot_file
    
    if [ "$network" = "testnet" ]; then
        snapshot_url="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/xlayerdata_new.tar.gz"
        snapshot_file="geth-testnet.tar.gz"
    elif [ "$network" = "mainnet" ]; then
        snapshot_url="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/mainnet-geth.tar.gz"
        snapshot_file="mainnet-geth.tar.gz"
    else
        print_error "Unsupported network for snapshot: $network"
        exit 1
    fi
    
    # Check if target directory already exists (data already extracted)
    # For testnet: check for op-geth and op-node directories (flat structure)
    # For mainnet: check for data, config, logs directories (nested structure)
    if [ "$network" = "testnet" ]; then
        if [ -n "$target_dir" ] && [ -d "$target_dir" ] && [ -d "$target_dir/op-geth" ] && [ -d "$target_dir/op-node" ]; then
            print_success "Target directory already exists: $target_dir, skipping download"
            return 0
        fi
    elif [ "$network" = "mainnet" ]; then
        if [ -n "$target_dir" ] && [ -d "$target_dir" ] && [ -d "$target_dir/data" ] && [ -d "$target_dir/config" ]; then
            print_success "Target directory already exists: $target_dir, skipping download"
            return 0
        fi
    fi
    
    # Check if snapshot file already exists
    if [ -f "$snapshot_file" ]; then
        local file_size=$(du -h "$snapshot_file" 2>/dev/null | cut -f1 || echo "unknown")
        print_success "Using existing snapshot file: $snapshot_file ($file_size)"
        return 0
    fi
    
    # Check if xlayerdata exists (from previous extraction, not yet renamed) - only for testnet
    if [ "$network" = "testnet" ]; then
        if [ -d "xlayerdata" ] && [ -d "xlayerdata/op-geth" ] && [ -d "xlayerdata/op-node" ]; then
            print_success "Found existing xlayerdata directory, skipping download"
            return 0
        fi
    fi
    
    print_info "Downloading snapshot (this may take a while)..."
    
    if ! wget -c "$snapshot_url" -O "$snapshot_file"; then
        print_error "Failed to download snapshot file"
        rm -f "$snapshot_file"
        exit 1
    fi
    
    print_success "Snapshot downloaded: $snapshot_file"
}

# Extract snapshot
extract_snapshot() {
    local target_dir=$1
    local network=$2
    
    # Determine snapshot file name based on network
    local snapshot_file
    if [ "$network" = "testnet" ]; then
        snapshot_file="geth-testnet.tar.gz"
    elif [ "$network" = "mainnet" ]; then
        snapshot_file="mainnet-geth.tar.gz"
    else
        print_error "Unsupported network for snapshot: $network"
        exit 1
    fi
    
    # Priority 1: Check if target directory already exists with valid data
    # If it exists, skip everything (no download, no extract, no rename)
    if [ "$network" = "testnet" ]; then
        # Testnet: flat structure with op-geth and op-node
        if [ -d "$target_dir" ] && [ -d "$target_dir/op-geth" ] && [ -d "$target_dir/op-node" ]; then
            print_success "Found existing snapshot directory: $target_dir, skipping extraction"
            return 0
        fi
    elif [ "$network" = "mainnet" ]; then
        # Mainnet: nested structure with data, config, logs
        if [ -d "$target_dir" ] && [ -d "$target_dir/data" ] && [ -d "$target_dir/config" ]; then
            print_success "Found existing snapshot directory: $target_dir, skipping extraction"
            return 0
        fi
    fi
    
    # Priority 2: Check if xlayerdata exists (from previous extraction, not yet renamed) - only for testnet
    if [ "$network" = "testnet" ]; then
        if [ -d "xlayerdata" ] && [ -d "xlayerdata/op-geth" ] && [ -d "xlayerdata/op-node" ]; then
            print_info "Found xlayerdata directory, renaming to $target_dir..."
            if [ -d "$target_dir" ]; then
                print_error "Target directory $target_dir already exists but doesn't contain valid snapshot data"
                print_info "Please remove $target_dir and try again"
                exit 1
            fi
            mv xlayerdata "$target_dir"
            print_success "Renamed xlayerdata to $target_dir"
            return 0
        fi
    fi
    
    # Priority 3: Extract from snapshot file (only if target directory doesn't exist)
    # Check if snapshot file exists before extracting
    if [ ! -f "$snapshot_file" ]; then
        print_error "Snapshot file not found: $snapshot_file"
        print_info "Please run download_snapshot() first"
        exit 1
    fi
    
    print_info "Extracting snapshot (this may take a while)..."
    
    if ! tar -zxvf "$snapshot_file"; then
        print_error "Failed to extract snapshot file"
        exit 1
    fi
    
    if [ "$network" = "testnet" ]; then
        # Testnet: extracts to xlayerdata, need to rename
        if [ ! -d "xlayerdata" ]; then
            print_error "Snapshot extraction failed: xlayerdata directory not found"
            exit 1
        fi
        
        # Rename xlayerdata to target directory name (e.g., testnet-geth)
        if [ -d "$target_dir" ]; then
            print_warning "Target directory $target_dir already exists (this shouldn't happen)"
            if [ -d "$target_dir/op-geth" ] && [ -d "$target_dir/op-node" ]; then
                print_info "Target directory already contains snapshot data, using existing directory"
                rm -rf xlayerdata
            else
                print_error "Target directory exists but doesn't contain valid snapshot data"
                print_info "Please remove $target_dir and try again"
                exit 1
            fi
        else
            print_info "Renaming xlayerdata to $target_dir..."
            mv xlayerdata "$target_dir"
            print_success "Snapshot extracted and renamed to $target_dir"
        fi
    elif [ "$network" = "mainnet" ]; then
        # Mainnet: extracts directly to mainnet-geth (already correct name)
        if [ ! -d "$target_dir" ]; then
            print_error "Snapshot extraction failed: $target_dir directory not found"
            exit 1
        fi
        
        # Verify structure
        if [ ! -d "$target_dir/data" ] || [ ! -d "$target_dir/config" ]; then
            print_error "Snapshot extraction failed: invalid structure in $target_dir"
            print_info "Expected: $target_dir/data and $target_dir/config"
            exit 1
        fi
        
        print_success "Snapshot extracted to $target_dir"
    fi
}

init_geth() {
    local data_dir=$1
    local genesis_file=$2
    
    # Convert to absolute paths
    if [[ ! "$data_dir" = /* ]]; then
        data_dir="$(pwd)/$data_dir"
    fi
    if [[ ! "$genesis_file" = /* ]]; then
        genesis_file="$(pwd)/$genesis_file"
    fi
    
    print_info "Initializing op-geth... (This may take a while)"
    
    if ! docker run --rm \
        -v "$data_dir:/data" \
        -v "$genesis_file:/genesis.json" \
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

init_reth() {
    local data_dir=$1
    local genesis_file=$2
    
    # Convert to absolute paths
    if [[ ! "$data_dir" = /* ]]; then
        data_dir="$(pwd)/$data_dir"
    fi
    if [[ ! "$genesis_file" = /* ]]; then
        genesis_file="$(pwd)/$genesis_file"
    fi
    
    print_info "Initializing op-reth... (This may take a while)"
    print_info "This is a one-time operation during setup"
    
    if ! docker run --rm \
        -v "$data_dir:/datadir" \
        -v "$genesis_file:/genesis.json" \
        "${OP_RETH_IMAGE_TAG}" \
        init \
        --datadir /datadir \
        --chain /genesis.json; then
        print_error "Failed to initialize op-reth"
        exit 1
    fi
    
    # Remove auto-generated reth.toml (we use custom config mounted as /config.toml)
    local auto_config="$data_dir/reth.toml"
    if [ -f "$auto_config" ]; then
        rm -f "$auto_config"
        print_info "Removed auto-generated reth.toml (using custom config instead)"
    fi
    
    print_success "op-reth initialized successfully"
}

initialize_node() {
    print_info "Initializing X Layer RPC node..."
    
    cd "$WORK_DIR" || exit 1
    
    if [ "$SYNC_MODE" = "snapshot" ]; then
        # Snapshot mode: download and extract snapshot
        download_snapshot "$TARGET_DIR" "$NETWORK_TYPE"
        extract_snapshot "$TARGET_DIR" "$NETWORK_TYPE"
        
        if [ "$NETWORK_TYPE" = "testnet" ]; then
            # Testnet snapshot: temporary special handling (flat structure)
            # TODO: Remove this when testnet snapshot structure is unified with mainnet
            # Remove EnableInnerTx = true from config.toml
            local config_file="$TARGET_DIR/op-geth/config.toml"
            if [ -f "$config_file" ]; then
                print_info "Removing EnableInnerTx = true from config.toml..."
                sed -i '/^EnableInnerTx = true$/d' "$config_file"
                print_success "Updated config.toml"
            fi
            
            # Ensure op-node logs directory exists (needed for log output)
            if [ ! -d "$TARGET_DIR/op-node/logs" ]; then
                mkdir -p "$TARGET_DIR/op-node/logs"
                print_info "Created logs directory for op-node"
            fi
            
            print_success "Node initialization completed (snapshot mode - testnet)"
            print_info "Using snapshot data directory: $TARGET_DIR"
            print_info "  - $TARGET_DIR/op-geth/: Geth blockchain data (from snapshot)"
            print_info "  - $TARGET_DIR/op-node/: Op-node data (from snapshot)"
        else
            # Mainnet snapshot: uses same structure as genesis mode, no special handling needed
            print_success "Node initialization completed (snapshot mode - mainnet)"
            print_info "Using snapshot data directory: $TARGET_DIR"
            print_info "  - $TARGET_DIR/data/: Blockchain data (from snapshot)"
            print_info "  - $TARGET_DIR/config/: Configuration files (from snapshot)"
            print_info "  - $TARGET_DIR/logs/: Service logs (from snapshot)"
        fi
    else
        # Genesis mode: download and extract genesis, then initialize
        download_genesis "$GENESIS_URL" "$NETWORK_TYPE"
        extract_genesis "$CONFIG_DIR" "$GENESIS_FILE"
        
        # Initialize execution client
        if [ "$RPC_TYPE" = "reth" ]; then
            init_reth "$DATA_DIR/op-reth" "$CONFIG_DIR/$GENESIS_FILE"
        else
            init_geth "$DATA_DIR/op-geth" "$CONFIG_DIR/$GENESIS_FILE"
        fi
        
        print_success "Node initialization completed"
        print_info "Directory structure created at: ${TARGET_DIR}"
        print_info "  - data/"
        if [ "$RPC_TYPE" = "reth" ]; then
            print_info "    - op-reth/: Reth blockchain data"
        else
            print_info "    - op-geth/: Geth blockchain data"
        fi
        print_info "    - op-node/: Op-node data"
        print_info "  - config/: Configuration files"
        print_info "  - logs/: Log files"
        
        # Clean up genesis file after initialization (only for reth)
        if [ "$RPC_TYPE" = "reth" ]; then
            echo ""
            print_info "Cleaning up genesis file (no longer needed for reth startup)..."
            
            # Remove extracted genesis file
            if [ -f "$CONFIG_DIR/$GENESIS_FILE" ]; then
                rm -f "$CONFIG_DIR/$GENESIS_FILE"
                print_success "Removed $GENESIS_FILE (6.8GB freed)"
            fi
            
            # Remove genesis tarball in standalone mode
            local genesis_tarball="genesis-${NETWORK_TYPE}.tar.gz"
            if [ "$IN_REPO" = false ] && [ -f "$genesis_tarball" ]; then
                rm -f "$genesis_tarball"
                print_info "Removed genesis tarball"
            elif [ "$IN_REPO" = true ] && [ -f "$genesis_tarball" ]; then
                print_info "Kept genesis tarball for repository mode: $genesis_tarball"
            fi
            
            print_success "Optimization enabled: Fast startup mode"
            print_info "Subsequent restarts will use built-in 'xlayer-${NETWORK_TYPE}' chain for <1s startup"
            print_info "Genesis file cleaned up - 6.8GB disk space saved!"
        fi
    fi
}

# Generate docker-compose.yml based on sync mode
generate_docker_compose() {
    print_info "Generating docker-compose.yml..."
    
    cd "$WORK_DIR" || exit 1

    # Mainnet snapshot uses the same docker-compose.yml as genesis mode (same structure)
    # Only testnet snapshot needs special docker-compose.yml (flat structure) - TODO: will be unified
    if [ "$SYNC_MODE" = "snapshot" ] && [ "$NETWORK_TYPE" = "testnet" ]; then
        # Generate snapshot mode docker-compose.yml for testnet (flat structure) - temporary special handling
        cat > docker-compose.yml << 'EOF'
networks:
  xlayer-network:
    name: xlayer-network

services:
  op-node:
    image: "${OP_STACK_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-node
    entrypoint: sh
    networks:
      - xlayer-network
    ports:
      - "${NODE_RPC_PORT:-9545}:9545"
      - "${NODE_P2P_PORT:-9223}:9223"
      - "${NODE_P2P_PORT:-9223}:9223/udp"
    volumes:
      - ./${TARGET_DIR}/op-node:/data
      - ./${TARGET_DIR}/op-node/rollup.json:/rollup.json
      - ./${TARGET_DIR}/op-node/jwt.txt:/jwt.txt
      - ./${TARGET_DIR}/op-node/logs:/logs
    command:
      - -c
      - |
        exec /app/op-node/bin/op-node \
          --log.level=info \
          --l2=${L2_ENGINE_URL} \
          --l2.jwt-secret=/jwt.txt \
          --sequencer.enabled=false \
          --verifier.l1-confs=1 \
          --rollup.config=/rollup.json \
          --rpc.addr=0.0.0.0 \
          --rpc.port=9545 \
          --p2p.listen.tcp=9223 \
          --p2p.listen.udp=9223 \
          --p2p.peerstore.path=/data/p2p/opnode_peerstore_db \
          --p2p.discovery.path=/data/p2p/opnode_discovery_db \
          --p2p.bootnodes=${OP_NODE_BOOTNODE} \
          --p2p.static=${P2P_STATIC_PEERS} \
          --rpc.enable-admin=true \
          --l1=${L1_RPC_URL} \
          --l1.beacon=${L1_BEACON_URL} \
          --l1.rpckind=standard \
          --conductor.enabled=false \
          --safedb.path=/data/safedb \
          --l2.enginekind=${RPC_TYPE} \
          2>&1 | tee /logs/op-node.log
    restart: unless-stopped

  op-geth:
    image: "${OP_GETH_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-geth
    entrypoint: geth
    networks:
      - xlayer-network
    ports:
      - "${HTTP_RPC_PORT:-8123}:8545"
      - "${ENGINE_API_PORT:-8552}:8552"
      - "${WEBSOCKET_PORT:-8546}:8546"
      - "${P2P_TCP_PORT:-30303}:30303"
      - "${P2P_UDP_PORT:-30303}:30303/udp"
    volumes:
      - ./${TARGET_DIR}/op-geth/data:/data
      - ./${TARGET_DIR}/op-geth/jwt.txt:/jwt.txt
      - ./${TARGET_DIR}/op-geth/config.toml:/config.toml
      - ./${TARGET_DIR}/op-geth/data/logs:/logs
    command:
      - --verbosity=3
      - --datadir=/data
      - --config=/config.toml
      - --db.engine=pebble
      - --gcmode=archive
      - --pp-rpc-url=${LEGACY_RPC_URL}
      - --rollup.enabletxpooladmission
      - --rollup.sequencerhttp=${SEQUENCER_HTTP_URL}
      - --log.file=/logs/geth.log
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:8545"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 60s

  op-reth:
    image: "${OP_RETH_IMAGE_TAG}"
    container_name: xlayer-${NETWORK_TYPE}-op-reth
    entrypoint: sh
    networks:
      - xlayer-network
    ports:
      - "${HTTP_RPC_PORT:-8123}:8545"
      - "${WEBSOCKET_PORT:-8546}:8546"
      - "${ENGINE_API_PORT:-8552}:8552"
      - "${P2P_TCP_PORT:-30303}:30303"
      - "${P2P_UDP_PORT:-30303}:30303/udp"
    volumes:
      - ./${TARGET_DIR}/data/op-reth:/datadir
      - ./${TARGET_DIR}/config/jwt.txt:/jwt.txt
      - ./${TARGET_DIR}/config/op-reth-config-${NETWORK_TYPE}.toml:/config.toml
      - ./${TARGET_DIR}/logs:/logs
    command:
      - -c
      - |
        exec op-reth node \
          --datadir=/datadir \
          --chain=${CHAIN_NAME:-xlayer-mainnet} \
          --config=/config.toml \
          --http \
          --http.corsdomain=* \
          --http.port=8545 \
          --http.addr=0.0.0.0 \
          --http.api=web3,debug,eth,txpool,net,miner \
          --ws \
          --ws.addr=0.0.0.0 \
          --ws.port=8546 \
          --ws.origins=* \
          --ws.api=debug,eth,txpool,net \
          --authrpc.addr=0.0.0.0 \
          --authrpc.port=8552 \
          --authrpc.jwtsecret=/jwt.txt \
          --rollup.disable-tx-pool-gossip \
          --rollup.sequencer-http=${SEQUENCER_HTTP_URL} \
          --disable-discovery \
          --max-outbound-peers=0 \
          --max-inbound-peers=0 \
          --rpc.legacy-url=${LEGACY_RPC_URL} \
          --rpc.legacy-timeout=${LEGACY_RPC_TIMEOUT} \
          --log.stdout.filter=info \
          --log.file.directory=/logs/ \
          --log.file.filter=info
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json", "--data", "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}", "http://localhost:8545"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s
EOF
        print_success "docker-compose.yml generated (snapshot mode - testnet)"
    else
        # Genesis mode OR mainnet snapshot: use standard docker-compose.yml (same structure)
        if ! get_file_from_source "docker-compose.yml"; then
            print_error "Failed to get docker-compose.yml"
            exit 1
        fi
        if [ "$SYNC_MODE" = "snapshot" ]; then
            print_success "docker-compose.yml generated (snapshot mode - mainnet, using standard structure)"
        else
            print_success "docker-compose.yml generated (genesis mode)"
        fi
    fi
}

start_services() {
    print_info "Starting Docker services..."
    
    cd "$WORK_DIR" || exit 1
    
    if [ ! -f "./Makefile" ]; then
        print_error "Makefile not found in $WORK_DIR"
        exit 1
    fi
    
    print_info "Running 'make run'..."
    if ! make run; then
        print_error "Failed to start services"
        exit 1
    fi
    
    print_success "Services started successfully"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  X Layer RPC Node One-Click Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    detect_repository
    if [ "$IN_REPO" = true ]; then
        print_info "📂 Running from repository: $REPO_ROOT"
    else
        print_info "🌐 Running standalone mode (will download files from GitHub)"
    fi
    
    # Parse command line arguments first (only rpc_type)
    parse_arguments "$@"
    
    # Show selected RPC type
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_info "RPC Client: $RPC_TYPE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Load configuration from network-presets.env
    load_configuration
    
    # System checks
    check_system_requirements
    check_required_files
    
    # User interaction (network type, L1 URLs and ports)
    # This also calls check_existing_data and sets SKIP_INIT
    get_user_input
    
    # Check existing configurations after network type is determined
    echo ""
    check_existing_configurations
    
    # Generate docker-compose.yml based on sync mode
    generate_docker_compose
    
    # Conditional initialization
    if [ "$SKIP_INIT" -eq 0 ]; then
        # Full initialization process
        print_info "Performing full initialization..."
        if [ "$SYNC_MODE" = "snapshot" ] && [ "$NETWORK_TYPE" = "testnet" ]; then
            # Testnet snapshot: extract snapshot, then generate .env file
            initialize_node
            load_network_config "$NETWORK_TYPE"  # Load network config for .env generation
            generate_env_file
        elif [ "$SYNC_MODE" = "snapshot" ]; then
            # Mainnet snapshot: uses same structure as genesis, need to set directory variables
            initialize_node
            generate_config_files  # Set CONFIG_DIR, DATA_DIR, LOGS_DIR variables (no dir creation)
            load_network_config "$NETWORK_TYPE"  # Load network config for .env generation
            generate_env_file
        else
            # Genesis mode: download config files and initialize
            download_config_files
            generate_config_files
            initialize_node
        fi
        start_services
    else
        # Skip initialization, only generate .env
        print_info "Skipping initialization, updating configuration only..."
        
        # Ensure basic directory structure exists (only for genesis mode)
        if [ "$SYNC_MODE" != "snapshot" ]; then
            mkdir -p "$TARGET_DIR/config" "$TARGET_DIR/logs" "$TARGET_DIR/data"
        fi
        
        # Load network config for .env generation
        load_network_config "$NETWORK_TYPE"
        
        # Generate .env file
        generate_env_file
        
        print_success "Configuration updated"
        
        # Auto-start services after configuration update
        start_services
    fi
    
    # Cleanup for standalone mode
    cleanup_standalone_files
}

# Clean up downloaded files in standalone mode
cleanup_standalone_files() {
    if [ "$IN_REPO" = false ]; then
        if [ -f "$WORK_DIR/network-presets.env" ]; then
            rm -f "$WORK_DIR/network-presets.env"
            print_info "Cleaned up network-presets.env (already loaded into .env)"
        fi
    fi
}

# Run main function
main "$@"
