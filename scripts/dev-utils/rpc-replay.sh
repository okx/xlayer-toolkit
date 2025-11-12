#!/bin/bash
set -e

#######################################
# X Layer RPC Replay Tool
# Build and verify RPC node sync from scratch
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
RPC_SETUP_DIR="${SCRIPT_DIR}/../rpc-setup"
REPOS_DIR="${WORK_DIR}/replay-repos"
LOG_FILE="${WORK_DIR}/replay-$(date +%Y-%m-%d-%H%M%S).log"

# Repository URLs
OPTIMISM_REPO="https://github.com/okx/optimism"
RETH_REPO="https://github.com/okx/reth"
OP_GETH_REPO="https://github.com/okx/op-geth"

# User input variables
CLIENT_TYPE=""
OPTIMISM_BRANCH=""
RETH_BRANCH=""
OP_GETH_BRANCH=""
L1_RPC_URL=""
L1_BEACON_URL=""
NETWORK_TYPE="mainnet"

# Docker image tags
OP_STACK_IMAGE_TAG=""
OP_RETH_IMAGE_TAG=""
OP_GETH_IMAGE_TAG=""

#######################################
# Utility Functions
#######################################

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$LOG_FILE"
}

log_info() {
    log "ℹ️  $*"
    echo -e "\033[0;34mℹ️  $*\033[0m"
}

log_success() {
    log "✅ $*"
    echo -e "\033[0;32m✅ $*\033[0m"
}

log_warning() {
    log "⚠️  $*"
    echo -e "\033[1;33m⚠️  $*\033[0m"
}

log_error() {
    log "❌ $*"
    echo -e "\033[0;31m❌ $*\033[0m"
}

log_step() {
    log ""
    log "=========================================="
    log "$*"
    log "=========================================="
    echo ""
    echo -e "\033[1;36m=========================================="
    echo "$*"
    echo "=========================================\033[0m"
    echo ""
}

command_exists() {
    command -v "$1" &> /dev/null
}

#######################################
# Check Dependencies
#######################################

check_dependencies() {
    log_step "Step 1: Checking dependencies"
    
    local missing_deps=()
    
    # Required tools
    local required_tools=("git" "docker" "curl" "jq" "expect")
    
    for tool in "${required_tools[@]}"; do
        if command_exists "$tool"; then
            log_info "✓ $tool found"
        else
            missing_deps+=("$tool")
            log_error "✗ $tool not found"
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_deps[*]}"
        log_info "Please install them first:"
        echo "  # macOS:"
        echo "  brew install ${missing_deps[*]}"
        echo ""
        echo "  # Ubuntu/Debian:"
        echo "  sudo apt-get install ${missing_deps[*]}"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

#######################################
# User Input
#######################################

get_user_input() {
    log_step "Step 2: Collecting user input"
    
    echo "Please provide the following information:"
    echo ""
    
    # Client type
    while true; do
        read -p "1. Client type (reth/geth): " CLIENT_TYPE
        if [[ "$CLIENT_TYPE" =~ ^(reth|geth)$ ]]; then
            log "Client type: $CLIENT_TYPE"
            break
        else
            log_error "Invalid client type. Please enter 'reth' or 'geth'"
        fi
    done
    
    # Optimism branch/tag
    read -p "2. Optimism branch/tag: " OPTIMISM_BRANCH
    log "Optimism branch: $OPTIMISM_BRANCH"
    
    # Reth branch/tag (if reth client)
    if [ "$CLIENT_TYPE" = "reth" ]; then
        read -p "3. Reth branch/tag: " RETH_BRANCH
        log "Reth branch: $RETH_BRANCH"
    fi
    
    # Op-geth branch/tag (if geth client)
    if [ "$CLIENT_TYPE" = "geth" ]; then
        read -p "3. Op-geth branch/tag: " OP_GETH_BRANCH
        log "Op-geth branch: $OP_GETH_BRANCH"
    fi
    
    # L1 RPC URL
    while true; do
        read -p "4. L1 RPC URL: " L1_RPC_URL
        if [[ "$L1_RPC_URL" =~ ^https?:// ]]; then
            log "L1 RPC URL: $L1_RPC_URL"
            break
        else
            log_error "Please enter a valid HTTP/HTTPS URL"
        fi
    done
    
    # L1 Beacon URL
    while true; do
        read -p "5. L1 Beacon URL: " L1_BEACON_URL
        if [[ "$L1_BEACON_URL" =~ ^https?:// ]]; then
            log "L1 Beacon URL: $L1_BEACON_URL"
            break
        else
            log_error "Please enter a valid HTTP/HTTPS URL"
        fi
    done
    
    log_success "Input collection completed"
}

#######################################
# Clone/Update Repository
#######################################

clone_or_update_repo() {
    local repo_url=$1
    local repo_name=$2
    local branch=$3
    local repo_path="${REPOS_DIR}/${repo_name}"
    
    log_info "Processing repository: $repo_name"
    
    if [ -d "$repo_path" ]; then
        log_warning "Repository exists, resetting to clean state..."
        cd "$repo_path"
        
        # Reset repository
        log_info "Resetting repository..."
        git fetch --all >> "$LOG_FILE" 2>&1
        git reset --hard >> "$LOG_FILE" 2>&1
        git clean -fdx >> "$LOG_FILE" 2>&1
        
        log_success "Repository reset completed"
    else
        log_info "Cloning repository from $repo_url..."
        mkdir -p "$REPOS_DIR"
        cd "$REPOS_DIR"
        
        if ! git clone "$repo_url" "$repo_name" >> "$LOG_FILE" 2>&1; then
            log_error "Failed to clone $repo_name"
            exit 1
        fi
        
        cd "$repo_path"
        log_success "Repository cloned"
    fi
    
    # Checkout specified branch/tag
    log_info "Checking out $branch..."
    if ! git checkout "$branch" >> "$LOG_FILE" 2>&1; then
        log_error "Failed to checkout $branch"
        exit 1
    fi
    
    # Pull latest changes if it's a branch
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        log_info "Pulling latest changes..."
        git pull origin "$branch" >> "$LOG_FILE" 2>&1
    fi
    
    # Get commit ID
    local commit_id=$(git rev-parse --short HEAD)
    log_success "Repository ready at commit: $commit_id"
    
    cd "$WORK_DIR"
    echo "$commit_id"
}

prepare_repositories() {
    log_step "Step 3: Preparing source code repositories"
    
    # Clone/update optimism
    local optimism_commit=$(clone_or_update_repo "$OPTIMISM_REPO" "optimism" "$OPTIMISM_BRANCH")
    OP_STACK_IMAGE_TAG="op-stack:${OPTIMISM_BRANCH}-${optimism_commit}"
    
    # Handle client-specific repository
    if [ "$CLIENT_TYPE" = "reth" ]; then
        local reth_commit=$(clone_or_update_repo "$RETH_REPO" "reth" "$RETH_BRANCH")
        OP_RETH_IMAGE_TAG="op-reth:${RETH_BRANCH}-${reth_commit}"
    else
        local geth_commit=$(clone_or_update_repo "$OP_GETH_REPO" "op-geth" "$OP_GETH_BRANCH")
        OP_GETH_IMAGE_TAG="op-geth:${OP_GETH_BRANCH}-${geth_commit}"
    fi
    
    log_success "All repositories prepared"
}

#######################################
# Build Docker Image
#######################################

build_docker_image() {
    local repo_path=$1
    local image_tag=$2
    local dockerfile=$3
    local build_context=${4:-.}
    
    log_info "Building Docker image: $image_tag"
    log_info "This may take 10-30 minutes depending on your system..."
    
    cd "$repo_path"
    
    # Check if Dockerfile exists
    if [ ! -f "$dockerfile" ]; then
        log_error "Dockerfile not found: $dockerfile"
        log_error "Repository path: $repo_path"
        exit 1
    fi
    
    local build_cmd="docker build --no-cache -t $image_tag -f $dockerfile $build_context"
    log_info "Build command: $build_cmd"
    
    # Show real-time progress and write to log
    if ! eval "$build_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to build $image_tag"
        log_error "Check log file for details: $LOG_FILE"
        exit 1
    fi
    
    log_success "Image built successfully: $image_tag"
    cd "$WORK_DIR"
}

build_docker_images() {
    log_step "Step 4: Building Docker images"
    
    # Build op-stack (op-node)
    build_docker_image \
        "${REPOS_DIR}/optimism" \
        "$OP_STACK_IMAGE_TAG" \
        "Dockerfile-opstack" \
        "."
    
    # Build client-specific image
    if [ "$CLIENT_TYPE" = "reth" ]; then
        build_docker_image \
            "${REPOS_DIR}/reth" \
            "$OP_RETH_IMAGE_TAG" \
            "DockerfileOp" \
            "."
    else
        build_docker_image \
            "${REPOS_DIR}/op-geth" \
            "$OP_GETH_IMAGE_TAG" \
            "Dockerfile" \
            "."
    fi
    
    log_success "All Docker images built successfully"
}

#######################################
# Update Configuration File
#######################################

update_network_presets() {
    log_step "Step 5: Updating network configuration"
    
    local config_file="${RPC_SETUP_DIR}/network-presets.env"
    local backup_file="${config_file}.backup-$(date +%Y%m%d-%H%M%S)"
    local temp_file="${config_file}.tmp"
    
    # Backup original config file
    log_info "Backing up configuration file..."
    cp "$config_file" "$backup_file"
    log_success "Backup created: $backup_file"
    
    # Update image configuration (using temp file for better cross-platform compatibility)
    log_info "Updating image tags to local builds..."
    
    # Update OP_STACK_IMAGE
    sed "s|^MAINNET_OP_STACK_IMAGE=.*|MAINNET_OP_STACK_IMAGE=\"$OP_STACK_IMAGE_TAG\"|" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # Update client-specific image
    if [ "$CLIENT_TYPE" = "reth" ]; then
        sed "s|^MAINNET_OP_RETH_IMAGE=.*|MAINNET_OP_RETH_IMAGE=\"$OP_RETH_IMAGE_TAG\"|" "$config_file" > "$temp_file"
        mv "$temp_file" "$config_file"
    else
        sed "s|^MAINNET_OP_GETH_IMAGE=.*|MAINNET_OP_GETH_IMAGE=\"$OP_GETH_IMAGE_TAG\"|" "$config_file" > "$temp_file"
        mv "$temp_file" "$config_file"
    fi
    
    log_success "Configuration file updated"
    log_info "Updated values:"
    log_info "  MAINNET_OP_STACK_IMAGE=$OP_STACK_IMAGE_TAG"
    if [ "$CLIENT_TYPE" = "reth" ]; then
        log_info "  MAINNET_OP_RETH_IMAGE=$OP_RETH_IMAGE_TAG"
    else
        log_info "  MAINNET_OP_GETH_IMAGE=$OP_GETH_IMAGE_TAG"
    fi
}

#######################################
# Start Node (using expect for automation)
#######################################

start_node_with_expect() {
    log_step "Step 6: Starting RPC node"
    
    local setup_script="${RPC_SETUP_DIR}/one-click-setup.sh"
    
    if [ ! -f "$setup_script" ]; then
        log_error "Setup script not found: $setup_script"
        exit 1
    fi
    
    # Check if port is already in use
    log_info "Checking if port 8545 is available..."
    if command_exists lsof; then
        if lsof -Pi :8545 -sTCP:LISTEN -t >/dev/null 2>&1; then
            log_error "Port 8545 is already in use"
            log_error "Please stop the existing service or choose a different port"
            exit 1
        fi
    elif command_exists netstat; then
        if netstat -an | grep -q ":8545.*LISTEN"; then
            log_error "Port 8545 is already in use"
            log_error "Please stop the existing service or choose a different port"
            exit 1
        fi
    else
        log_warning "Cannot check port availability (lsof/netstat not found)"
    fi
    log_success "Port 8545 is available"
    
    log_info "Running one-click-setup.sh with automated input..."
    
    # Create expect script (with 1 hour timeout)
    local expect_script=$(cat <<EOF
#!/usr/bin/expect -f
set timeout 3600

spawn bash $setup_script

# Network type
expect "Network type*"
send "mainnet\r"

# L1 RPC URL
expect "L1 RPC URL*"
send "$L1_RPC_URL\r"

# L1 Beacon URL
expect "L1 Beacon URL*"
send "$L1_BEACON_URL\r"

# RPC client type
expect "RPC client type*"
send "$CLIENT_TYPE\r"

# Handle potential data directory conflict
expect {
    "Do you want to delete it*" {
        send "yes\r"
        exp_continue
    }
    "RPC port*" {
        send "\r"
    }
}

# WebSocket port
expect "WebSocket port*"
send "\r"

# Node RPC port
expect "Node RPC port*"
send "\r"

# Execution client P2P port
expect "Execution client P2P port*"
send "\r"

# Node P2P port
expect "Node P2P port*"
send "\r"

# Wait for startup completion
expect {
    "Services started successfully" {
        puts "\nNode started successfully"
    }
    timeout {
        puts "\nTimeout waiting for node to start"
        exit 1
    }
    eof {
        puts "\nSetup script completed"
    }
}

expect eof
EOF
)
    
    # Execute expect script
    echo "$expect_script" | expect >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "Node started successfully"
    else
        log_error "Failed to start node"
        log_error "Check log file for details: $LOG_FILE"
        exit 1
    fi
    
    # Wait for node to be fully ready
    log_info "Waiting for node to be ready..."
    sleep 10
}

#######################################
# RPC Call Functions
#######################################

get_block_number() {
    local rpc_url=$1
    
    # Add timeout and error handling
    local response=$(curl -s --max-time 10 --connect-timeout 5 \
        -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$rpc_url" 2>/dev/null)
    
    # Check if curl succeeded
    if [ $? -ne 0 ]; then
        echo "0"
        return 1
    fi
    
    # Check if response is empty
    if [ -z "$response" ]; then
        echo "0"
        return 1
    fi
    
    # Parse JSON response
    local result=$(echo "$response" | jq -r '.result' 2>/dev/null)
    
    # Check for errors
    local error=$(echo "$response" | jq -r '.error' 2>/dev/null)
    if [ "$error" != "null" ] && [ -n "$error" ]; then
        echo "0"
        return 1
    fi
    
    # Check if result is valid
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        echo "0"
        return 1
    fi
    
    # Convert hex to decimal
    printf "%d" "$result" 2>/dev/null || echo "0"
}

get_block_hash() {
    local rpc_url=$1
    local block_number=$2
    local block_hex=$(printf "0x%x" "$block_number")
    
    # Add timeout and error handling
    local response=$(curl -s --max-time 10 --connect-timeout 5 \
        -X POST -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$block_hex\",false],\"id\":1}" \
        "$rpc_url" 2>/dev/null)
    
    # Check if curl succeeded
    if [ $? -ne 0 ]; then
        echo "null"
        return 1
    fi
    
    # Check if response is empty
    if [ -z "$response" ]; then
        echo "null"
        return 1
    fi
    
    # Parse block hash
    local result=$(echo "$response" | jq -r '.result.hash' 2>/dev/null)
    
    # Check for errors
    local error=$(echo "$response" | jq -r '.error' 2>/dev/null)
    if [ "$error" != "null" ] && [ -n "$error" ]; then
        echo "null"
        return 1
    fi
    
    echo "$result"
}

#######################################
# Monitor Sync Progress
#######################################

monitor_sync_progress() {
    log_step "Step 7: Monitoring sync progress"
    
    local local_rpc="http://localhost:8545"
    local mainnet_rpc="https://xlayerrpc.okx.com"
    local check_interval=30
    local max_retries=5
    local retry_count=0
    
    log_info "Local RPC: $local_rpc"
    log_info "Mainnet RPC: $mainnet_rpc"
    log_info "Check interval: ${check_interval}s"
    echo ""
    
    while true; do
        # Get local node height
        local local_height=$(get_block_number "$local_rpc")
        
        if [ "$local_height" = "0" ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -ge $max_retries ]; then
                log_error "Failed to connect to local RPC after $max_retries retries"
                log_error "Please check if the node is running properly"
                exit 1
            fi
            log_warning "Cannot connect to local RPC (attempt $retry_count/$max_retries)"
            sleep 10
            continue
        fi
        
        retry_count=0
        
        # Get mainnet height
        local mainnet_height=$(get_block_number "$mainnet_rpc")
        
        if [ "$mainnet_height" = "0" ]; then
            log_warning "Cannot connect to mainnet RPC, retrying..."
            sleep 10
            continue
        fi
        
        # Calculate difference
        local diff=$((mainnet_height - local_height))
        local progress_pct=$(awk "BEGIN {printf \"%.2f\", ($local_height / $mainnet_height) * 100}")
        
        log_info "Local: $local_height | Mainnet: $mainnet_height | Diff: $diff | Progress: ${progress_pct}%"
        
        # Check if close to synced
        if [ $diff -lt 100 ] && [ $diff -ge 0 ]; then
            log_success "Node is catching up! Block difference: $diff"
            break
        fi
        
        sleep "$check_interval"
    done
}

#######################################
# Verify Block Consistency
#######################################

verify_block_consistency() {
    log_step "Step 8: Verifying block consistency"
    
    local local_rpc="http://localhost:8545"
    local mainnet_rpc="https://xlayerrpc.okx.com"
    
    # Get current height
    local local_height=$(get_block_number "$local_rpc")
    local mainnet_height=$(get_block_number "$mainnet_rpc")
    
    log_info "Comparing blocks at height: $local_height"
    echo ""
    
    # Compare recent blocks
    local blocks_to_check=5
    local mismatches=0
    
    for i in $(seq 0 $((blocks_to_check - 1))); do
        local check_height=$((local_height - i))
        
        if [ $check_height -lt 0 ]; then
            break
        fi
        
        log_info "Checking block #$check_height..."
        
        local local_hash=$(get_block_hash "$local_rpc" "$check_height")
        local mainnet_hash=$(get_block_hash "$mainnet_rpc" "$check_height")
        
        if [ "$local_hash" = "null" ] || [ -z "$local_hash" ]; then
            log_warning "Cannot get local block hash for #$check_height"
            continue
        fi
        
        if [ "$mainnet_hash" = "null" ] || [ -z "$mainnet_hash" ]; then
            log_warning "Cannot get mainnet block hash for #$check_height"
            continue
        fi
        
        if [ "$local_hash" = "$mainnet_hash" ]; then
            log_success "✓ Block #$check_height: MATCH"
            log_info "  Hash: $local_hash"
        else
            log_error "✗ Block #$check_height: MISMATCH"
            log_error "  Local:   $local_hash"
            log_error "  Mainnet: $mainnet_hash"
            mismatches=$((mismatches + 1))
        fi
        
        echo ""
    done
    
    # Output final result
    echo ""
    log_step "Verification Result"
    
    if [ $mismatches -eq 0 ]; then
        log_success "✅ ALL BLOCKS MATCH!"
        log_success "Your node is correctly synced with the mainnet"
        return 0
    else
        log_error "❌ BLOCK MISMATCH DETECTED!"
        log_error "Found $mismatches mismatched block(s)"
        log_error "Possible reasons:"
        log_error "  1. Node is still syncing"
        log_error "  2. Fork or consensus issue"
        log_error "  3. Configuration error"
        return 1
    fi
}

#######################################
# Generate Report
#######################################

generate_report() {
    local status=$1
    
    log_step "Replay Summary"
    
    log_info "Configuration:"
    log_info "  Client Type: $CLIENT_TYPE"
    log_info "  Optimism: $OPTIMISM_BRANCH"
    if [ "$CLIENT_TYPE" = "reth" ]; then
        log_info "  Reth: $RETH_BRANCH"
    else
        log_info "  Op-geth: $OP_GETH_BRANCH"
    fi
    log_info "  L1 RPC: $L1_RPC_URL"
    log_info "  L1 Beacon: $L1_BEACON_URL"
    echo ""
    
    log_info "Docker Images:"
    log_info "  $OP_STACK_IMAGE_TAG"
    if [ "$CLIENT_TYPE" = "reth" ]; then
        log_info "  $OP_RETH_IMAGE_TAG"
    else
        log_info "  $OP_GETH_IMAGE_TAG"
    fi
    echo ""
    
    log_info "Log file: $LOG_FILE"
    echo ""
    
    if [ $status -eq 0 ]; then
        log_success "🎉 REPLAY SUCCESSFUL!"
    else
        log_error "❌ REPLAY FAILED"
    fi
}

#######################################
# Main Flow
#######################################

main() {
    echo "=================================================="
    echo "  X Layer RPC Replay Tool"
    echo "  Build and verify RPC node sync from scratch"
    echo "=================================================="
    echo ""
    
    log "Starting replay at $(date)"
    log "Working directory: $WORK_DIR"
    log "Log file: $LOG_FILE"
    echo ""
    
    # Execute steps
    check_dependencies
    get_user_input
    prepare_repositories
    build_docker_images
    update_network_presets
    start_node_with_expect
    monitor_sync_progress
    
    # Verify and generate report
    if verify_block_consistency; then
        generate_report 0
        exit 0
    else
        generate_report 1
        exit 1
    fi
}

# Catch interrupt signals
trap 'log_error "Script interrupted by user"; exit 130' INT TERM

# Run main flow
main "$@"

