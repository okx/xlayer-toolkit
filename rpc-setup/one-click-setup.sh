#!/bin/bash
set -e

BRANCH="main"
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

# Quick start flag
QUICK_START=false

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
ENGINE_API_PORT=""
FLASHBLOCKS_ENABLED=""
FLASHBLOCKS_URL=""

# Colors
C_RESET="\033[0m"
C_CYAN="\033[0;36m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[0;31m"
C_BLUE="\033[0;34m"
C_MAGENTA="\033[0;35m"
C_BOLD="\033[1m"
C_DIM="\033[2m"

print_info() { echo -e "${C_CYAN}  [*] $1${C_RESET}"; }
print_success() { echo -e "${C_GREEN}  [+] $1${C_RESET}"; }
print_warning() { echo -e "${C_YELLOW}  [!] $1${C_RESET}"; }
print_error() { echo -e "${C_RED}  [-] $1${C_RESET}"; }
print_prompt() {
    if ! printf "${C_CYAN}%s${C_RESET}" "$1" > /dev/tty 2>/dev/null; then
        printf "${C_CYAN}%s${C_RESET}" "$1"
    fi
}
# Spinner frames
SPINNER_FRAMES=('/' '-' '\' '|')
SPINNER_IDX=0

# Print in place with spinner (single frame)
print_step() {
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_FRAMES[@]} ))
    printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$SPINNER_IDX]} %s${C_RESET}" "$1"
}
# Finish step with result
print_step_ok() { printf "\r\033[K${C_GREEN}  ✓ %s${C_RESET}\n" "$1"; }
print_step_fail() { printf "\r\033[K${C_RED}  ✗ %s${C_RESET}\n" "$1"; }

# Run a command with animated spinner
# Usage: run_with_spinner "message" command [args...]
run_with_spinner() {
    local msg=$1
    shift
    # Run command in background
    "$@" &>/dev/null &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
        printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$i]} %s${C_RESET}" "$msg"
        sleep 0.25
    done
    wait "$pid"
    return $?
}

# Download with progress bar (hides raw wget output)
# Usage: download_with_progress "message" url output_file
download_with_progress() {
    local msg=$1
    local url=$2
    local output=$3

    # Get remote file size
    local total_size=$(curl -sI "$url" | grep -i content-length | tail -1 | tr -d '\r' | awk '{print $2}')

    # Start wget in background, suppress output
    wget -c -q "$url" -O "$output" 2>/dev/null &
    local pid=$!
    local i=0
    local bar_width=30

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
        local current_size=0
        if [ -f "$output" ]; then
            current_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null || echo 0)
        fi

        if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null; then
            local pct=$(( current_size * 100 / total_size ))
            [ $pct -gt 100 ] && pct=100
            local filled=$(( pct * bar_width / 100 ))
            local empty=$(( bar_width - filled ))
            local bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
            local size_mb=$(( current_size / 1048576 ))
            local total_mb=$(( total_size / 1048576 ))
            printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$i]} %s ${C_BOLD}[%s]${C_RESET} ${C_DIM}%d%%  %dMB/%dMB${C_RESET}" "$msg" "$bar" "$pct" "$size_mb" "$total_mb"
        else
            local size_mb=0
            if [ "$current_size" -gt 0 ] 2>/dev/null; then
                size_mb=$(( current_size / 1048576 ))
            fi
            printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$i]} %s ${C_DIM}%dMB downloaded${C_RESET}" "$msg" "$size_mb"
        fi
        sleep 0.3
    done

    wait "$pid"
    local ret=$?
    printf "\r\033[K"
    return $ret
}

# Extract with progress bar (monitors target directory size growth)
# Usage: extract_with_progress "message" archive_file tar_args...
extract_with_progress() {
    local msg=$1
    local archive=$2
    shift 2

    # Estimate uncompressed size (~3x compressed size as heuristic)
    local archive_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null || echo 0)
    local est_total=$(( archive_size * 3 ))

    # Determine target directory for size monitoring
    local target_dir="."
    local next_is_dir=false
    for arg in "$@"; do
        if [ "$next_is_dir" = true ]; then
            target_dir="$arg"
            break
        fi
        [ "$arg" = "-C" ] && next_is_dir=true
    done

    local base_size=0
    if [ -d "$target_dir" ]; then
        base_size=$(du -sb "$target_dir" 2>/dev/null | awk '{print $1}' || du -sk "$target_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    fi

    tar "$@" "$archive" &>/dev/null &
    local pid=$!
    local i=0
    local bar_width=30

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#SPINNER_FRAMES[@]} ))
        local current_size=0
        if [ -d "$target_dir" ]; then
            current_size=$(du -sb "$target_dir" 2>/dev/null | awk '{print $1}' || du -sk "$target_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
            current_size=$(( current_size - base_size ))
            [ "$current_size" -lt 0 ] 2>/dev/null && current_size=0
        fi

        if [ "$est_total" -gt 0 ] 2>/dev/null; then
            local pct=$(( current_size * 100 / est_total ))
            [ $pct -gt 99 ] && pct=99
            local filled=$(( pct * bar_width / 100 ))
            local empty=$(( bar_width - filled ))
            local bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
            local size_mb=$(( current_size / 1048576 ))
            printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$i]} %s ${C_BOLD}[%s]${C_RESET} ${C_DIM}%d%%  %dMB${C_RESET}" "$msg" "$bar" "$pct" "$size_mb"
        else
            printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$i]} %s${C_RESET}" "$msg"
        fi
        sleep 0.3
    done

    wait "$pid"
    local ret=$?
    printf "\r\033[K"
    return $ret
}

# Section header
print_section() {
    local text=$1
    local box_width=50
    local text_len=${#text}
    local pad_left=$(( (box_width - text_len) / 2 ))
    local pad_right=$(( box_width - text_len - pad_left ))
    local line=$(printf '%*s' "$box_width" '' | tr ' ' '-')
    local content="$(printf '%*s' "$pad_left" '')${text}$(printf '%*s' "$pad_right" '')"
    echo ""
    echo -e "${C_CYAN}  +${line}+${C_RESET}"
    echo -e "${C_CYAN}  |${C_BOLD}${content}${C_RESET}${C_CYAN}|${C_RESET}"
    echo -e "${C_CYAN}  +${line}+${C_RESET}"
}

# Banner
print_banner() {
    echo ""
    echo -e "${C_CYAN}${C_BOLD}  X Layer RPC Node${C_RESET} ${C_DIM}· One-Click Setup${C_RESET}"
    echo -e "${C_DIM}  ──────────────────────────────────────${C_RESET}"
    echo ""
}

# Show usage information
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --rpc_type=<geth|reth>   RPC client type (default: reth)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Note: Network type (mainnet/testnet) will be prompted during setup"
    echo ""
    echo "Examples:"
    echo "  $0                  # Use default reth (network type will be prompted)"
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
    RPC_TYPE="${RPC_TYPE:-reth}"
    
    # Validate RPC_TYPE if provided
    if ! validate_rpc_type "$RPC_TYPE"; then
        exit 1
    fi
}

# Check and display existing configurations
check_existing_configurations() {
    local configs=""
    for config in mainnet-geth mainnet-reth testnet-geth testnet-reth; do
        if [ -d "$config" ]; then
            local size=$(du -sh "$config" 2>/dev/null | cut -f1 || echo "?")
            configs="${configs}${config}(${size}) "
        fi
    done
    if [ -n "$configs" ]; then
        print_step_ok "Existing configs: $configs"
    fi
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
    local docker_version="" compose_version=""

    run_with_spinner "Checking docker..." sleep 0.3
    if command_exists docker; then
        docker_version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    else
        print_step_fail "Docker is not installed. Please install Docker 20.10+ first."
        exit 1
    fi

    run_with_spinner "Checking docker compose..." sleep 0.3
    if command_exists docker-compose; then
        compose_version=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    elif docker compose version &> /dev/null; then
        compose_version=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    else
        print_step_fail "Docker Compose is not installed."
        exit 1
    fi

    if ! run_with_spinner "Checking docker daemon..." docker info; then
        print_step_fail "Docker daemon is not running."
        exit 1
    fi

    print_step_ok "Docker ready (docker $docker_version, compose $compose_version)"
}
    
# Check required system tools
check_required_tools() {
    local missing_required=()
    local required_tools=("wget" "tar" "openssl" "curl" "sed" "make")

    for tool in "${required_tools[@]}"; do
        run_with_spinner "Checking $tool..." sleep 0.3
        if ! command_exists "$tool"; then
            missing_required+=("$tool")
        fi
    done

    if [ ${#missing_required[@]} -gt 0 ]; then
        print_step_fail "Missing: ${missing_required[*]}"
        echo -e "  ${C_DIM}macOS: brew install ${missing_required[*]}${C_RESET}"
        echo -e "  ${C_DIM}Ubuntu: sudo apt-get install ${missing_required[*]}${C_RESET}"
        exit 1
    fi

    print_step_ok "Tools ready (${required_tools[*]})"
}

# Countdown prompt that updates in place
# Usage: countdown_prompt "prompt text" VAR_NAME [timeout]
# Result is stored in the named variable. Empty if timed out.
# Returns 0 if user pressed a key, 1 if timed out
countdown_prompt() {
    local prompt_text=$1
    local var_name=$2
    local timeout=${3:-5}
    local input_label=${4:-$1}
    local input=""

    local countdown=$timeout
    while [ $countdown -gt 0 ]; do
        local idx=$(( countdown % ${#SPINNER_FRAMES[@]} ))
        printf "\r\033[K${C_CYAN}  ${SPINNER_FRAMES[$idx]} %s ${C_DIM}(%ds)${C_RESET}" "$prompt_text" "$countdown"
        # read -n 1 detects any keypress, stops countdown immediately
        if read -r -t 1 -n 1 input </dev/tty 2>/dev/null; then
            # Show input prompt, read full line
            printf "\r\033[K${C_CYAN}  > %s: ${C_RESET}" "$input_label"
            local rest=""
            read -r rest </dev/tty 2>/dev/null || read -r rest
            input="${input}${rest}"
            printf "\r\033[K"
            eval "$var_name=\"\$input\""
            return 0
        fi
        countdown=$((countdown - 1))
    done

    # Timeout - no input
    printf "\r\033[K"
    eval "$var_name=''"
    return 1
}

# Quick start prompt with countdown
prompt_quick_start() {
    print_section "Launch X Layer Mainnet RPC ($RPC_TYPE)"
    echo ""

    local choice=""
    if countdown_prompt "Auto-starting... Press any key for custom setup" choice 5; then
        QUICK_START=false
        print_info "Entering custom setup mode..."
    else
        QUICK_START=true
        print_success "Quick start: X Layer Mainnet RPC ($RPC_TYPE)"
        NETWORK_TYPE="mainnet"
        SYNC_MODE="${DEFAULT_SYNC_MODE:-snapshot}"
    fi
}

check_system_requirements() {
    check_docker
    check_required_tools
}

# Get file from repository or download from GitHub
get_file_from_source() {
    local file=$1
    local target_path="$WORK_DIR/$file"

    if [ -f "$target_path" ]; then
        return 0
    fi

    if [ "$IN_REPO" = true ]; then
        local source_path="$REPO_RPC_SETUP_DIR/$file"
        if [ -f "$source_path" ]; then
            run_with_spinner "Preparing $file..." cp "$source_path" "$target_path"
            return 0
        fi
    fi

    local url="${REPO_URL}/${file}"
    if run_with_spinner "Downloading $file..." wget -q "$url" -O "$target_path"; then
        return 0
    else
        print_step_fail "Failed to get $file"
        return 1
    fi
}

check_required_files() {
    if ! get_file_from_source "Makefile"; then
        print_step_fail "Failed to get required file: Makefile"
        exit 1
    fi
    print_step_ok "Required files ready"
}

# Get configuration files based on network and RPC type
download_config_files() {
    load_network_config "$NETWORK_TYPE"

    local config_dir="${TARGET_DIR}/config"
    mkdir -p "$config_dir"

    local config_files=("presets/$ROLLUP_CONFIG")
    [ "$RPC_TYPE" = "reth" ] && config_files+=("presets/$RETH_CONFIG") || config_files+=("presets/$GETH_CONFIG")

    for file in "${config_files[@]}"; do
        local filename=$(basename "$file")
        local target="$config_dir/$filename"

        if [ "$IN_REPO" = true ] && [ -f "$REPO_RPC_SETUP_DIR/$file" ]; then
            run_with_spinner "Preparing $filename..." cp "$REPO_RPC_SETUP_DIR/$file" "$target"
        else
            if ! run_with_spinner "Downloading $filename..." wget -q "$REPO_URL/$file" -O "$target"; then
                print_step_fail "Failed to get $file"
                exit 1
            fi
        fi
    done

    print_step_ok "Configuration files ready"
}

# Styled input prompt with validation
prompt_input() {
    local prompt_text=$1
    local default_value=$2
    local validator=$3
    local result
    local input

    while true; do
        printf "${C_CYAN}  > %s${C_RESET}" "$prompt_text" > /dev/tty
        if read -r input </dev/tty 2>/dev/null; then
            result="${input:-$default_value}"
        elif read -r input; then
            result="${input:-$default_value}"
        else
            result="$default_value"
        fi

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

validate_ws_url() {
    [[ "$1" =~ ^wss?:// ]] || { print_error "Please enter a valid WebSocket URL"; return 1; }
}

# Validate if snapshot mode is supported for the given RPC type and network
validate_snapshot_support() {
    local rpc_type=$1
    local network=$2
    
    if [ "$network" != "testnet" ] && [ "$network" != "mainnet" ]; then
        print_error "Snapshot mode is currently only supported for testnet and mainnet"
        return 1
    fi

    # All testnet + mainnet combinations support snapshot mode
    
    return 0
}

check_existing_data() {
    local target_dir="$1"

    if [ ! -d "$target_dir" ]; then
        print_info "New setup: $target_dir"
        return 0
    fi

    local size=$(du -sh "$target_dir" 2>/dev/null | cut -f1 || echo "?")
    local status="empty"
    if [ -d "$target_dir/data" ] && [ -d "$target_dir/config" ] && [ "$(ls -A "$target_dir/data" 2>/dev/null)" ]; then
        status="initialized"
    fi

    print_section "Existing data found"
    echo -e "${C_DIM}    Path: $target_dir | Size: $size | Status: $status${C_RESET}"
    echo ""
    echo -e "${C_CYAN}    [1] Keep existing data (recommended)${C_RESET}"
    echo -e "${C_CYAN}    [2] Delete and re-initialize${C_RESET}"
    echo -e "${C_CYAN}    [3] Cancel${C_RESET}"
    echo ""

    while true; do
        printf "${C_CYAN}  > Choose [1/2/3, default: 1]: ${C_RESET}"
        if ! read -r choice </dev/tty 2>/dev/null && ! read -r choice; then
            choice="1"
        fi
        choice="${choice:-1}"

        case $choice in
            1)
                print_step_ok "Keeping existing data"
                return 1
                ;;
            2)
                run_with_spinner "Removing $target_dir..." rm -rf "$target_dir"
                print_step_ok "Directory removed"
                return 0
                ;;
            3)
                print_info "Cancelled"
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
    done
}

get_user_input() {
    if [ "$QUICK_START" = true ]; then
        print_info "Network: $NETWORK_TYPE | Sync: $SYNC_MODE | RPC: $RPC_TYPE"
    else
        print_section "Network Configuration"
        echo ""
        NETWORK_TYPE=$(prompt_input "Network type (testnet/mainnet) [${DEFAULT_NETWORK}]: " "$DEFAULT_NETWORK" "validate_network")
        SYNC_MODE=$(prompt_input "Sync mode (genesis/snapshot) [${DEFAULT_SYNC_MODE}]: " "$DEFAULT_SYNC_MODE" "validate_sync_mode")
        print_step_ok "Network: $NETWORK_TYPE | Sync: $SYNC_MODE | RPC: $RPC_TYPE"
    fi

    # Set target directory
    TARGET_DIR="${NETWORK_TYPE}-${RPC_TYPE}"

    # testnet only supports snapshot mode (both geth and reth)
    if [ "$NETWORK_TYPE" = "testnet" ] && [ "$SYNC_MODE" = "genesis" ]; then
        print_error "Testnet does not support genesis mode"
        print_info "Please use 'snapshot' sync mode for testnet"
        exit 1
    fi

    # Validate snapshot support
    if [ "$SYNC_MODE" = "snapshot" ]; then
        if ! validate_snapshot_support "$RPC_TYPE" "$NETWORK_TYPE"; then
            exit 1
        fi
    fi

    if [ "$QUICK_START" = true ]; then
        echo ""
        countdown_prompt "L1 RPC URL(recommended)... Press any key to input" L1_RPC_URL 5 "L1 RPC URL"
        print_success "L1 RPC URL: ${L1_RPC_URL:-(skip)}"

        if [ -n "$L1_RPC_URL" ]; then
            countdown_prompt "L1 Beacon URL(recommended)... Press any key to input" L1_BEACON_URL 5 "L1 Beacon URL"
            print_success "L1 Beacon URL: ${L1_BEACON_URL:-(empty)}"
        else
            L1_BEACON_URL=""
        fi
    else
        print_section "L1 Endpoints"
        echo ""
        countdown_prompt "L1 RPC URL... Press any key to input" L1_RPC_URL 5 "L1 RPC URL"
        if [ -n "$L1_RPC_URL" ] && ! validate_url "$L1_RPC_URL"; then
            L1_RPC_URL=""
        fi
        print_success "L1 RPC URL: ${L1_RPC_URL:-(skip)}"

        if [ -n "$L1_RPC_URL" ]; then
            countdown_prompt "L1 Beacon URL... Press any key to input" L1_BEACON_URL 5 "L1 Beacon URL"
            if [ -n "$L1_BEACON_URL" ] && ! validate_url "$L1_BEACON_URL"; then
                L1_BEACON_URL=""
            fi
            print_success "L1 Beacon URL: ${L1_BEACON_URL:-(skip)}"
        else
            L1_BEACON_URL=""
        fi
    fi

    # Check existing data directory
    echo ""
    if [ "$QUICK_START" = true ] && [ -d "$TARGET_DIR" ] && [ -d "$TARGET_DIR/data" ] && [ -d "$TARGET_DIR/config" ] && [ "$(ls -A "$TARGET_DIR/data" 2>/dev/null)" ]; then
        print_success "Quick start: keeping existing data in $TARGET_DIR"
        SKIP_INIT=1
    else
        # Temporarily disable set -e to capture return value safely
        set +e
        check_existing_data "$TARGET_DIR"
        SKIP_INIT=$?  # Save return value: 0=initialize, 1=skip
        set -e
    fi

    if [ "$QUICK_START" = true ]; then
        # Quick start: use all default ports and op-node extra args
        RPC_PORT="$DEFAULT_RPC_PORT"
        WS_PORT="$DEFAULT_WS_PORT"
        NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
        GETH_P2P_PORT="$DEFAULT_GETH_P2P_PORT"
        NODE_P2P_PORT="$DEFAULT_NODE_P2P_PORT"
        ENGINE_API_PORT="$DEFAULT_ENGINE_API_PORT"
        FLASHBLOCKS_ENABLED="${DEFAULT_FLASHBLOCKS_ENABLED:-false}"
        FLASHBLOCKS_URL="${DEFAULT_FLASHBLOCKS_URL:-}"
        L1_BEACON_IGNORE="true"
        L2_FOLLOW_SOURCE="https://xlayerrpc.okx.com"
        L2_FOLLOW_SOURCE_SKIP_L1_CHECK="true"
        print_info "Using default ports: RPC=$RPC_PORT, WS=$WS_PORT, Node=$NODE_RPC_PORT, Engine=$ENGINE_API_PORT"
    else
        print_section "Port Configuration"
        echo -e "${C_DIM}    Press Enter to use defaults${C_RESET}"
        echo ""

        RPC_PORT=$(prompt_input "RPC port [${DEFAULT_RPC_PORT}]: " "$DEFAULT_RPC_PORT" "") || RPC_PORT="$DEFAULT_RPC_PORT"
        WS_PORT=$(prompt_input "WebSocket port [${DEFAULT_WS_PORT}]: " "$DEFAULT_WS_PORT" "") || WS_PORT="$DEFAULT_WS_PORT"
        NODE_RPC_PORT=$(prompt_input "Node RPC port [${DEFAULT_NODE_RPC_PORT}]: " "$DEFAULT_NODE_RPC_PORT" "") || NODE_RPC_PORT="$DEFAULT_NODE_RPC_PORT"
        GETH_P2P_PORT=$(prompt_input "EL P2P port [${DEFAULT_GETH_P2P_PORT}]: " "$DEFAULT_GETH_P2P_PORT" "") || GETH_P2P_PORT="$DEFAULT_GETH_P2P_PORT"
        NODE_P2P_PORT=$(prompt_input "Node P2P port [${DEFAULT_NODE_P2P_PORT}]: " "$DEFAULT_NODE_P2P_PORT" "") || NODE_P2P_PORT="$DEFAULT_NODE_P2P_PORT"
        ENGINE_API_PORT=$(prompt_input "Engine API port [${DEFAULT_ENGINE_API_PORT}]: " "$DEFAULT_ENGINE_API_PORT" "") || ENGINE_API_PORT="$DEFAULT_ENGINE_API_PORT"

        FLASHBLOCKS_ENABLED=$(prompt_input "Flashblocks enabled [${DEFAULT_FLASHBLOCKS_ENABLED}]: " "$DEFAULT_FLASHBLOCKS_ENABLED" "") || FLASHBLOCKS_ENABLED="$DEFAULT_FLASHBLOCKS_ENABLED"

        if [ "$FLASHBLOCKS_ENABLED" = "true" ]; then
            FLASHBLOCKS_URL=$(prompt_input "Flashblocks URL [${DEFAULT_FLASHBLOCKS_URL}]: " "$DEFAULT_FLASHBLOCKS_URL" "validate_ws_url") || FLASHBLOCKS_URL="$DEFAULT_FLASHBLOCKS_URL"
        fi

        # Custom mode: initialize op-node extra args based on L1 input
        L1_BEACON_IGNORE="false"
        L2_FOLLOW_SOURCE=""
        L2_FOLLOW_SOURCE_SKIP_L1_CHECK="false"

        print_step_ok "Ports: RPC=$RPC_PORT WS=$WS_PORT Node=$NODE_RPC_PORT Engine=$ENGINE_API_PORT"
    fi

    # Apply constraints after all variables are set
    # Constraint 1: L1_BEACON_URL requires L1_RPC_URL
    if [ -n "$L1_BEACON_URL" ] && [ -z "$L1_RPC_URL" ]; then
        print_error "L1 Beacon URL requires L1 RPC URL"
        exit 1
    fi
    # Constraint 2: L1_RPC_URL provided -> no need to skip L1 check
    if [ -n "$L1_RPC_URL" ]; then
        L2_FOLLOW_SOURCE_SKIP_L1_CHECK="false"
    fi
    # Constraint 3: L1_BEACON_URL provided -> use beacon, no follow source
    if [ -n "$L1_BEACON_URL" ]; then
        L1_BEACON_IGNORE="false"
        L2_FOLLOW_SOURCE=""
    fi
}

generate_or_verify_jwt() {
    local jwt_file=$1
    if [ ! -s "$jwt_file" ]; then
        openssl rand -hex 32 | tr -d '\n' > "$jwt_file"
        return 0
    fi
    local jwt_content=$(cat "$jwt_file" 2>/dev/null | tr -d '\n\r ' || echo "")
    if [ ${#jwt_content} -ne 64 ]; then
        openssl rand -hex 32 | tr -d '\n' > "$jwt_file"
    fi
}

generate_config_files() {
    run_with_spinner "Generating configuration files..." sleep 0.3

    cd "$WORK_DIR" || exit 1
    load_network_config "$NETWORK_TYPE"

    if [ "$RPC_TYPE" = "reth" ]; then
        EXEC_IMAGE_TAG="$OP_RETH_IMAGE_TAG"
        EXEC_CONFIG="$RETH_CONFIG"
        EXEC_CLIENT="op-reth"
    else
        EXEC_IMAGE_TAG="$OP_GETH_IMAGE_TAG"
        EXEC_CONFIG="$GETH_CONFIG"
        EXEC_CLIENT="op-geth"
    fi

    DATA_DIR="${TARGET_DIR}/data"
    CONFIG_DIR="${TARGET_DIR}/config"
    LOGS_DIR="${TARGET_DIR}/logs"
    GENESIS_FILE="genesis-${NETWORK_TYPE}.json"

    if [ "$SYNC_MODE" = "snapshot" ]; then
        if [ ! -d "$TARGET_DIR" ]; then
            print_step_fail "Snapshot directory not found: $TARGET_DIR"
            exit 1
        fi
    else
        mkdir -p "$CONFIG_DIR" "$LOGS_DIR" "$DATA_DIR/op-node/p2p"
        if [ "$RPC_TYPE" = "reth" ]; then
            mkdir -p "$DATA_DIR/op-reth"
        else
            mkdir -p "$DATA_DIR/op-geth"
        fi
        generate_or_verify_jwt "$CONFIG_DIR/jwt.txt"
    fi

    generate_env_file

    print_step_ok "Configuration files generated"
}

generate_env_file() {
    
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
ENGINE_API_PORT=${ENGINE_API_PORT:-8552}
NODE_RPC_PORT=${NODE_RPC_PORT:-9545}
P2P_TCP_PORT=${GETH_P2P_PORT:-30303}
P2P_UDP_PORT=${GETH_P2P_PORT:-30303}
NODE_P2P_PORT=${NODE_P2P_PORT:-9223}

# Sequencer HTTP URL
SEQUENCER_HTTP_URL=$SEQUENCER_HTTP

# Legacy RPC Configuration
LEGACY_RPC_URL=$LEGACY_RPC_URL
LEGACY_RPC_TIMEOUT=$LEGACY_RPC_TIMEOUT

# Flashblocks Configuration
FLASHBLOCKS_ENABLED=${FLASHBLOCKS_ENABLED:-${DEFAULT_FLASHBLOCKS_ENABLED:-false}}
FLASHBLOCKS_URL=${FLASHBLOCKS_URL:-${DEFAULT_FLASHBLOCKS_URL:-}}

# Op-node L1 Beacon ignore (skip beacon chain dependency)
L1_BEACON_IGNORE=${L1_BEACON_IGNORE:-false}

# Op-node L2 follow source (trusted L2 RPC for fast sync)
L2_FOLLOW_SOURCE=${L2_FOLLOW_SOURCE:-}

# Op-node skip L1 check for follow source
L2_FOLLOW_SOURCE_SKIP_L1_CHECK=${L2_FOLLOW_SOURCE_SKIP_L1_CHECK:-false}
EOF
    
}

download_genesis() {
    local genesis_url=$1
    local network=$2
    local genesis_file="genesis-${network}.tar.gz"

    if [ "$IN_REPO" = true ] && [ -f "$genesis_file" ]; then
        return 0
    fi

    if ! download_with_progress "Downloading genesis..." "$genesis_url" "$genesis_file"; then
        print_step_fail "Failed to download genesis file"
        rm -f "$genesis_file"
        exit 1
    fi
    print_step_ok "Genesis file downloaded"
}

extract_genesis() {
    local target_dir=$1
    local target_file=$2
    
    # Get genesis filename (consistent with download_genesis)
    local genesis_file="genesis-${NETWORK_TYPE}.tar.gz"
    
    if ! extract_with_progress "Extracting genesis file..." "$genesis_file" -xzf -C "$target_dir/"; then
        print_step_fail "Failed to extract genesis file"
        rm -f "$genesis_file"
        exit 1
    fi

    if [ -f "$target_dir/merged.genesis.json" ]; then
        mv "$target_dir/merged.genesis.json" "$target_dir/$target_file"
    elif [ -f "$target_dir/genesis.json" ]; then
        mv "$target_dir/genesis.json" "$target_dir/$target_file"
    else
        print_step_fail "Failed to find genesis.json in the archive"
        rm -f "$genesis_file"
        exit 1
    fi

    if [ ! -f "$target_dir/$target_file" ]; then
        print_step_fail "Genesis file not found after extraction"
        exit 1
    fi

    print_step_ok "Genesis file extracted"
}

# Download snapshot for geth/reth testnet/mainnet
download_snapshot() {
    local target_dir=$1  # Target directory (e.g., testnet-geth or mainnet-geth)
    local network=$2     # Network type (testnet or mainnet)
    local rpc_type=$3    # RPC type (geth or reth)
    
    # Determine snapshot URL and file name based on network and RPC type
    local snapshot_url
    local snapshot_file
    
    print_step "Fetching latest $network snapshot for $rpc_type..."

    if [ "$network" = "testnet" ]; then
        local latest_url
        if [ "$rpc_type" = "geth" ]; then
            latest_url="${TESTNET_GETH_SNAPSHOT_LATEST_URL}"
        elif [ "$rpc_type" = "reth" ]; then
            latest_url="${TESTNET_RETH_SNAPSHOT_LATEST_URL}"
        else
            print_step_fail "Unsupported RPC type for testnet snapshot: $rpc_type"
            exit 1
        fi
        local latest_filename
        latest_filename=$(curl -s -f "$latest_url" | tr -d '\n\r' | xargs)
        if [ -z "$latest_filename" ]; then
            print_step_fail "Failed to fetch latest testnet snapshot filename"
            exit 1
        fi
        snapshot_url="${TESTNET_SNAPSHOT_BASE_URL}/${latest_filename}"
        snapshot_file="$latest_filename"
        export TESTNET_SNAPSHOT_FILE="$snapshot_file"
    elif [ "$network" = "mainnet" ]; then
        local latest_url
        if [ "$rpc_type" = "geth" ]; then
            latest_url="${MAINNET_GETH_SNAPSHOT_LATEST_URL}"
        elif [ "$rpc_type" = "reth" ]; then
            latest_url="${MAINNET_RETH_SNAPSHOT_LATEST_URL}"
        else
            print_step_fail "Unsupported RPC type for snapshot: $rpc_type"
            exit 1
        fi
        local latest_filename
        latest_filename=$(curl -s -f "$latest_url" | tr -d '\n\r' | xargs)
        if [ -z "$latest_filename" ]; then
            print_step_fail "Failed to fetch latest snapshot filename"
            exit 1
        fi
        snapshot_url="${MAINNET_SNAPSHOT_BASE_URL}/${latest_filename}"
        snapshot_file="$latest_filename"
        export MAINNET_SNAPSHOT_FILE="$snapshot_file"
    else
        print_step_fail "Unsupported network for snapshot: $network"
        exit 1
    fi

    # Check if target directory already exists (data already extracted)
    if [ -n "$target_dir" ] && [ -d "$target_dir" ] && [ -d "$target_dir/data" ] && [ -d "$target_dir/config" ]; then
        print_step_ok "Snapshot data exists: $target_dir"
        return 0
    fi

    # Check if snapshot file already exists and verify MD5
    if [ -f "$snapshot_file" ]; then
        run_with_spinner "Verifying MD5 of $snapshot_file..." sleep 0.3
        local remote_md5=$(curl -s -f "${snapshot_url}.md5" 2>/dev/null | awk '{print $1}' | tr -d '\r\n')
        if [ -n "$remote_md5" ]; then
            local local_md5
            if command -v md5sum &>/dev/null; then
                local_md5=$(md5sum "$snapshot_file" | awk '{print $1}')
            else
                local_md5=$(md5 -q "$snapshot_file")
            fi
            if [ "$local_md5" = "$remote_md5" ]; then
                print_step_ok "MD5 verified: $snapshot_file"
                return 0
            else
                print_step "MD5 mismatch, re-downloading..."
                rm -f "$snapshot_file"
            fi
        else
            print_step_ok "Using existing snapshot: $snapshot_file"
            return 0
        fi
    fi

    if ! download_with_progress "Downloading snapshot..." "$snapshot_url" "$snapshot_file"; then
        print_step_fail "Failed to download snapshot"
        rm -f "$snapshot_file"
        exit 1
    fi

    print_step_ok "Snapshot downloaded: $snapshot_file"
}

# Extract snapshot
extract_snapshot() {
    local target_dir=$1
    local network=$2
    local rpc_type=$3
    
    local snapshot_file
    if [ "$network" = "testnet" ]; then
        if [ -n "$TESTNET_SNAPSHOT_FILE" ]; then
            snapshot_file="$TESTNET_SNAPSHOT_FILE"
        else
            snapshot_file=$(ls -t testnet-${rpc_type}*.tar.gz 2>/dev/null | head -1)
            [ -z "$snapshot_file" ] && snapshot_file="${rpc_type}-testnet.tar.gz"
        fi
    elif [ "$network" = "mainnet" ]; then
        if [ -n "$MAINNET_SNAPSHOT_FILE" ]; then
            snapshot_file="$MAINNET_SNAPSHOT_FILE"
        else
            snapshot_file=$(ls -t mainnet-${rpc_type}*.tar.gz 2>/dev/null | head -1)
            if [ -z "$snapshot_file" ]; then
                print_step_fail "Snapshot file not found for $network $rpc_type"
                exit 1
            fi
        fi
    else
        print_step_fail "Unsupported network: $network"
        exit 1
    fi

    if [ -d "$target_dir" ] && [ -d "$target_dir/data" ] && [ -d "$target_dir/config" ]; then
        print_step_ok "Snapshot directory exists: $target_dir"
        return 0
    fi

    if [ ! -f "$snapshot_file" ]; then
        print_step_fail "Snapshot file not found: $snapshot_file"
        exit 1
    fi

    if ! extract_with_progress "Extracting snapshot..." "$snapshot_file" -zxf; then
        print_step_fail "Failed to extract snapshot"
        exit 1
    fi

    if [ ! -d "$target_dir/data" ] || [ ! -d "$target_dir/config" ]; then
        print_step_fail "Snapshot extraction failed: invalid structure in $target_dir"
        exit 1
    fi

    print_step_ok "Snapshot extracted to $target_dir"
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
    
    print_step "Initializing op-geth..."

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
        print_step_fail "Failed to initialize op-geth"
        exit 1
    fi

    print_step_ok "op-geth initialized"
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
    
    print_step "Initializing op-reth..."

    if ! docker run --rm \
        -v "$data_dir:/datadir" \
        -v "$genesis_file:/genesis.json" \
        "${OP_RETH_IMAGE_TAG}" \
        init \
        --datadir /datadir \
        --chain /genesis.json; then
        print_step_fail "Failed to initialize op-reth"
        exit 1
    fi

    local auto_config="$data_dir/reth.toml"
    [ -f "$auto_config" ] && rm -f "$auto_config"

    print_step_ok "op-reth initialized"
}

initialize_node() {
    cd "$WORK_DIR" || exit 1

    if [ "$SYNC_MODE" = "snapshot" ]; then
        download_snapshot "$TARGET_DIR" "$NETWORK_TYPE" "$RPC_TYPE"
        extract_snapshot "$TARGET_DIR" "$NETWORK_TYPE" "$RPC_TYPE"
    else
        download_genesis "$GENESIS_URL" "$NETWORK_TYPE"
        extract_genesis "$CONFIG_DIR" "$GENESIS_FILE"

        if [ "$RPC_TYPE" = "reth" ]; then
            init_reth "$DATA_DIR/op-reth" "$CONFIG_DIR/$GENESIS_FILE"
        else
            init_geth "$DATA_DIR/op-geth" "$CONFIG_DIR/$GENESIS_FILE"
        fi

        # Clean up genesis file after initialization (only for reth)
        if [ "$RPC_TYPE" = "reth" ]; then
            run_with_spinner "Cleaning up genesis file..." sleep 0.3
            [ -f "$CONFIG_DIR/$GENESIS_FILE" ] && rm -f "$CONFIG_DIR/$GENESIS_FILE"
            local genesis_tarball="genesis-${NETWORK_TYPE}.tar.gz"
            [ "$IN_REPO" = false ] && [ -f "$genesis_tarball" ] && rm -f "$genesis_tarball"
            print_step_ok "Genesis cleaned up (6.8GB freed)"
        fi
    fi
}

# Generate docker-compose.yml based on sync mode
generate_docker_compose() {
    cd "$WORK_DIR" || exit 1
    if ! get_file_from_source "docker-compose.yml"; then
        print_step_fail "Failed to get docker-compose.yml"
        exit 1
    fi
    print_step_ok "docker-compose.yml ready ($SYNC_MODE mode)"
}

start_services() {
    cd "$WORK_DIR" || exit 1

    if [ ! -f "./Makefile" ]; then
        print_step_fail "Makefile not found in $WORK_DIR"
        exit 1
    fi

    print_step "Starting Docker services..."
    if ! make --no-print-directory run; then
        print_step_fail "Failed to start services"
        exit 1
    fi

    print_step_ok "Services started successfully"
}

main() {
    print_banner

    detect_repository
    if [ "$IN_REPO" = true ]; then
        print_info "Source: local repository"
    else
        print_info "Source: GitHub (standalone mode)"
    fi

    parse_arguments "$@"
    print_info "RPC Client: $RPC_TYPE"
    
    # Load configuration from network-presets.env
    load_configuration

    # Quick start prompt with 5s countdown
    prompt_quick_start

    # System checks
    check_system_requirements
    check_required_files
    
    # User interaction (network type, L1 URLs and ports)
    # This also calls check_existing_data and sets SKIP_INIT
    get_user_input
    
    check_existing_configurations

    generate_docker_compose

    if [ "$SKIP_INIT" -eq 0 ]; then
        if [ "$SYNC_MODE" = "snapshot" ]; then
            initialize_node
            generate_config_files
            load_network_config "$NETWORK_TYPE"
            generate_env_file
        else
            download_config_files
            generate_config_files
            initialize_node
        fi
        start_services
    else
        print_step "Updating configuration..."
        if [ "$SYNC_MODE" != "snapshot" ]; then
            mkdir -p "$TARGET_DIR/config" "$TARGET_DIR/logs" "$TARGET_DIR/data"
        fi
        load_network_config "$NETWORK_TYPE"
        generate_env_file
        print_step_ok "Configuration updated"
        start_services
    fi
    
    cleanup_standalone_files

    # Final summary
    echo ""
    local summary_text="X Layer RPC Node is running!"
    local slen=${#summary_text}
    local spad_left=$(( (50 - slen) / 2 ))
    local spad_right=$(( 50 - slen - spad_left ))
    local sline=$(printf '%*s' 50 '' | tr ' ' '-')
    echo -e "${C_GREEN}  +${sline}+${C_RESET}"
    echo -e "${C_GREEN}  |${C_BOLD}$(printf '%*s' "$spad_left" '')${summary_text}$(printf '%*s' "$spad_right" '')${C_RESET}${C_GREEN}|${C_RESET}"
    echo -e "${C_GREEN}  +${sline}+${C_RESET}"
    echo -e "${C_DIM}    Network: $NETWORK_TYPE | Client: $RPC_TYPE | Mode: $SYNC_MODE${C_RESET}"
    echo -e "${C_DIM}    RPC: http://localhost:${RPC_PORT:-8545} | WS: ws://localhost:${WS_PORT:-8546}${C_RESET}"
    echo ""
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
