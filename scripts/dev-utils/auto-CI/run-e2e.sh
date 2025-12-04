#!/bin/bash
# =============================================================================
# Run E2E Devnet Script
# =============================================================================
# This script starts the devnet with configurable execution client type.
# 
# Usage:
#   ./run-e2e.sh -geth    # Run with geth as sequencer and RPC
#   ./run-e2e.sh -reth    # Run with reth as sequencer and RPC
#   ./run-e2e.sh          # Run with default settings from .env
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Change Rust cache directory to a temporary directory
export CARGO_HOME=/data1/brendon/rust/cargo
export RUSTUP_HOME=/data1/brendon/rust/rustup
export PATH=$CARGO_HOME/bin:$PATH

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Start the devnet and run E2E tests.

OPTIONS:
  -geth         Run with geth as both sequencer and RPC
  -reth         Run with reth as both sequencer and RPC
  -h, --help    Show this help message

EXAMPLES:
  $0 -geth      # Run with geth, enable geth build, then run go E2E tests
  $0 -reth      # Run with reth, enable reth build, then run cargo E2E tests
  $0            # Run with default settings from .env, then run corresponding tests

WORKFLOW:
  1. Clean up previous devnet (run clean.sh)
  2. Configure .env with local repository paths
  3. Start devnet (make run)
  4. Run E2E tests based on client type:
     - If reth: cargo test from xlayer-reth repository
     - If geth: go test from op-geth repository
  5. Automatically stop devnet (make stop) and report results

EOF
}

# Absolute paths configuration
# Override with XLAYER_TOOLKIT_REPO environment variable if needed
XLAYER_TOOLKIT_REPO="${XLAYER_TOOLKIT_REPO:-/data1/brendon/xlayer-repos/xlayer-toolkit}"
DEVNET_DIR="$XLAYER_TOOLKIT_REPO/devnet"
ENV_FILE="$DEVNET_DIR/.env"

log_section "E2E Devnet Runner"

log_info "Using xlayer-toolkit repository: $XLAYER_TOOLKIT_REPO"

# Verify the repository exists
if [ ! -d "$XLAYER_TOOLKIT_REPO" ]; then
    log_error "xlayer-toolkit repository not found at: $XLAYER_TOOLKIT_REPO"
    log_error "Please set XLAYER_TOOLKIT_REPO environment variable or update the script"
    exit 1
fi

# Parse command-line arguments
CLIENT_TYPE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -geth)
            CLIENT_TYPE="geth"
            shift
            ;;
        -reth)
            CLIENT_TYPE="reth"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Check if devnet directory exists
if [ ! -d "$DEVNET_DIR" ]; then
    log_error "Devnet directory not found: $DEVNET_DIR"
    exit 1
fi

cd "$DEVNET_DIR"

# Check if .env file exists, create from example.env if not
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$DEVNET_DIR/example.env" ]; then
        log_info "Creating .env from example.env..."
        cp "$DEVNET_DIR/example.env" "$ENV_FILE"
        log_success ".env created from example.env"
    else
        log_error ".env file not found and example.env doesn't exist"
        exit 1
    fi
fi

# Helper function to update or add env variable
update_env_var() {
    local var_name="$1"
    local var_value="$2"
    
    if grep -q "^${var_name}=" "$ENV_FILE"; then
        sed -i.bak "s|^${var_name}=.*|${var_name}=${var_value}|" "$ENV_FILE"
    else
        echo "${var_name}=${var_value}" >> "$ENV_FILE"
    fi
}

# Always update local repository paths
log_info "Setting local repository paths..."
update_env_var "OP_STACK_LOCAL_DIRECTORY" "/data1/brendon/xlayer-repos/optimism"
update_env_var "OP_GETH_LOCAL_DIRECTORY" "/data1/brendon/xlayer-repos/op-geth"
update_env_var "OP_RETH_LOCAL_DIRECTORY" "/data1/brendon/xlayer-repos/reth"
log_success "Local repository paths configured"

# Update .env based on client type
if [ -n "$CLIENT_TYPE" ]; then
    log_info "Configuring devnet for ${CLIENT_TYPE}..."
    
    if [ "$CLIENT_TYPE" = "geth" ]; then
        # Update for geth
        log_info "Setting SEQ_TYPE=geth, RPC_TYPE=geth"
        log_info "Setting SKIP_OP_GETH_BUILD=false"
        
        update_env_var "SEQ_TYPE" "geth"
        update_env_var "RPC_TYPE" "geth"
        update_env_var "SKIP_OP_GETH_BUILD" "false"
        update_env_var "SKIP_OP_RETH_BUILD" "true"
        
        log_success "Configured for geth"
        
    elif [ "$CLIENT_TYPE" = "reth" ]; then
        # Update for reth
        log_info "Setting SEQ_TYPE=reth, RPC_TYPE=reth"
        log_info "Setting SKIP_OP_RETH_BUILD=false"
        
        update_env_var "SEQ_TYPE" "reth"
        update_env_var "RPC_TYPE" "reth"
        update_env_var "SKIP_OP_RETH_BUILD" "false"
        update_env_var "SKIP_OP_GETH_BUILD" "true"
        
        log_success "Configured for reth"
    fi
    
    # Clean up backup files
    rm -f "$ENV_FILE.bak"
    
    # Show configuration
    echo ""
    log_info "Current configuration:"
    echo "  SEQ_TYPE:              $(grep "^SEQ_TYPE=" "$ENV_FILE" | cut -d'=' -f2)"
    echo "  RPC_TYPE:              $(grep "^RPC_TYPE=" "$ENV_FILE" | cut -d'=' -f2)"
    echo "  SKIP_OP_GETH_BUILD:    $(grep "^SKIP_OP_GETH_BUILD=" "$ENV_FILE" | cut -d'=' -f2)"
    echo "  SKIP_OP_RETH_BUILD:    $(grep "^SKIP_OP_RETH_BUILD=" "$ENV_FILE" | cut -d'=' -f2)"
    echo ""
else
    log_info "Using existing .env configuration (no client type specified)"
    echo ""
    log_info "Current configuration:"
    echo "  SEQ_TYPE:              $(grep "^SEQ_TYPE=" "$ENV_FILE" | cut -d'=' -f2 || echo 'not set')"
    echo "  RPC_TYPE:              $(grep "^RPC_TYPE=" "$ENV_FILE" | cut -d'=' -f2 || echo 'not set')"
    echo "  SKIP_OP_GETH_BUILD:    $(grep "^SKIP_OP_GETH_BUILD=" "$ENV_FILE" | cut -d'=' -f2 || echo 'not set')"
    echo "  SKIP_OP_RETH_BUILD:    $(grep "^SKIP_OP_RETH_BUILD=" "$ENV_FILE" | cut -d'=' -f2 || echo 'not set')"
    echo ""
fi

# Show local repository paths
log_info "Local repository paths:"
echo "  OP_STACK:              $(grep "^OP_STACK_LOCAL_DIRECTORY=" "$ENV_FILE" | cut -d'=' -f2)"
echo "  OP_GETH:               $(grep "^OP_GETH_LOCAL_DIRECTORY=" "$ENV_FILE" | cut -d'=' -f2)"
echo "  OP_RETH:               $(grep "^OP_RETH_LOCAL_DIRECTORY=" "$ENV_FILE" | cut -d'=' -f2)"
echo ""

# Clean up existing devnet
log_section "Cleaning Up Previous Devnet"

CLEAN_SCRIPT="$DEVNET_DIR/clean.sh"
if [ ! -f "$CLEAN_SCRIPT" ]; then
    log_error "clean.sh not found at: $CLEAN_SCRIPT"
    exit 1
fi

log_info "Running clean.sh to remove previous devnet data..."
if bash "$CLEAN_SCRIPT"; then
    log_success "Cleanup completed successfully"
else
    log_error "Cleanup failed"
    exit 1
fi

# Start the devnet
log_section "Starting Devnet"

# Pre-create data directory with proper permissions for Docker containers
log_info "Setting up data directory permissions for Docker containers..."
mkdir -p "$DEVNET_DIR/data"
chmod -R 777 "$DEVNET_DIR/data"
log_success "Data directory permissions configured"
echo ""

log_info "Running 'make run' in $DEVNET_DIR"
echo ""

if ! make run; then
    log_error "Failed to start devnet"
    echo ""
    log_info "Check the logs in $DEVNET_DIR for more details"
    exit 1
fi

log_success "Devnet started successfully!"
echo ""
log_info "Waiting for devnet to be fully ready..."
sleep 5

# Set up trap to ensure devnet is stopped on exit (success, failure, or interrupt)
cleanup() {
    log_section "Cleanup"
    log_info "Stopping devnet..."
    cd "$DEVNET_DIR"
    if make stop; then
        log_success "Devnet stopped successfully"
    else
        log_warning "Failed to stop devnet cleanly"
    fi
}

trap cleanup EXIT

# Run E2E tests
log_section "Running E2E Tests"

# Determine which client type is being used
SEQ_TYPE=$(grep "^SEQ_TYPE=" "$ENV_FILE" | cut -d'=' -f2)
RPC_TYPE=$(grep "^RPC_TYPE=" "$ENV_FILE" | cut -d'=' -f2)

log_info "Detected configuration: SEQ_TYPE=$SEQ_TYPE, RPC_TYPE=$RPC_TYPE"

# Set up trap to ensure we report test results
TEST_EXIT_CODE=0

if [ "$SEQ_TYPE" = "reth" ] || [ "$RPC_TYPE" = "reth" ]; then
    # Run reth E2E tests
    XLAYER_RETH_DIR="/data1/brendon/xlayer-repos/xlayer-reth"
    
    log_info "Running reth E2E tests..."
    log_info "Checking xlayer-reth repository..."
    if [ ! -d "$XLAYER_RETH_DIR" ]; then
        log_error "xlayer-reth repository not found at: $XLAYER_RETH_DIR"
        log_warning "Devnet will be automatically stopped on exit."
        exit 1
    fi
    
    log_info "Changing directory to: $XLAYER_RETH_DIR"
    cd "$XLAYER_RETH_DIR"
    
    log_info "Running cargo E2E tests..."
    echo ""
    echo "Command: cargo test -p xlayer-e2e-test --test e2e_tests -- --nocapture --test-threads=1"
    echo ""
    
    if cargo test -p xlayer-e2e-test --test e2e_tests -- --nocapture --test-threads=1; then
        TEST_EXIT_CODE=0
        log_success "Reth E2E tests passed!"
    else
        TEST_EXIT_CODE=$?
        log_error "Reth E2E tests failed with exit code: $TEST_EXIT_CODE"
    fi
    
elif [ "$SEQ_TYPE" = "geth" ] || [ "$RPC_TYPE" = "geth" ]; then
    # Run geth E2E tests
    OP_GETH_TEST_DIR="/data1/brendon/xlayer-repos/op-geth/test/e2e"
    
    log_info "Running geth E2E tests..."
    log_info "Checking op-geth test directory..."
    if [ ! -d "$OP_GETH_TEST_DIR" ]; then
        log_error "op-geth test directory not found at: $OP_GETH_TEST_DIR"
        log_warning "Devnet will be automatically stopped on exit."
        exit 1
    fi
    
    log_info "Changing directory to: $OP_GETH_TEST_DIR"
    cd "$OP_GETH_TEST_DIR"
    
    log_info "Running go E2E tests..."
    echo ""
    echo "Command: go test -v ."
    echo ""
    
    if go test -v .; then
        TEST_EXIT_CODE=0
        log_success "Geth E2E tests passed!"
    else
        TEST_EXIT_CODE=$?
        log_error "Geth E2E tests failed with exit code: $TEST_EXIT_CODE"
    fi
    
else
    log_error "Unknown or unset SEQ_TYPE/RPC_TYPE: SEQ_TYPE=$SEQ_TYPE, RPC_TYPE=$RPC_TYPE"
    log_error "Expected either 'reth' or 'geth'"
    exit 1
fi

echo ""
log_section "Summary"

if [ $TEST_EXIT_CODE -eq 0 ]; then
    log_success "✅ All tests passed!"
    echo ""
    log_info "Devnet will be automatically stopped on exit"
    exit 0
else
    log_error "❌ Tests failed!"
    echo ""
    log_info "Devnet will be automatically stopped on exit"
    exit 1
fi

