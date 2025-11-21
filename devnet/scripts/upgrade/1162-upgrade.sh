#!/bin/bash

################################################################################
# 1161-upgrade.sh - Upgrade script for sync-1161 prestate (v7 → v8)
#
# This script automates the process of:
# 1. Building new prestate files with sync-1161 branch code (v8)
# 2. Comparing old (v7) and new (v8) prestate hashes
# 3. Deploying new FaultDisputeGame contract with v8 prestate
# 4. Updating game type 0 to use the new v8 implementation
# 5. Restarting affected services (op-challenger, op-proposer)
#
# Version Info:
# - dev branch:      VersionMultiThreaded64_v4 (constant value 7)
# - sync-1161 branch: VersionMultiThreaded64_v5 (constant value 8)
#
# Important Notes:
# - This script updates game type 0 (not creating a new game type)
# - op-challenger will skip old v7 games (they expire in 7 days)
# - New games will use v8 prestate and can be challenged
#
# Usage:
#   ./scripts/upgrade/1161-upgrade.sh
#
# The script will prompt for confirmation at critical steps.
# Press Enter or type 'yes' to continue, type 'no' to abort.
#
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_step() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Confirmation function
confirm_action() {
    local prompt="$1"
    local danger_level="$2"  # low, medium, high, critical

    echo ""
    case $danger_level in
        critical)
            echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║ 🔴🔴🔴 CRITICAL OPERATION - CONFIRMATION REQUIRED 🔴🔴🔴        ║${NC}"
            echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            ;;
        high)
            echo -e "${RED}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║ 🔴 HIGH RISK OPERATION - CONFIRMATION REQUIRED 🔴              ║${NC}"
            echo -e "${RED}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            ;;
        medium)
            echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║ ⚠️  MEDIUM RISK OPERATION - CONFIRMATION REQUIRED ⚠️            ║${NC}"
            echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            ;;
        low)
            echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║ ℹ️  CONFIRMATION REQUIRED                                        ║${NC}"
            echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            ;;
    esac

    echo -e "${CYAN}$prompt${NC}"
    echo ""

    while true; do
        read -p "Continue? (Press Enter for YES, or type 'no' to abort): " yn
        # Default to yes if empty (just pressed Enter)
        yn=${yn:-yes}
        case $yn in
            [Yy]es|[Yy])
                log_success "Confirmed. Proceeding..."
                return 0
                ;;
            [Nn]o|[Nn])
                log_warning "Operation cancelled by user."
                exit 0
                ;;
            *)
                log_error "Please press Enter to continue, or type 'no' to abort"
                ;;
        esac
    done
}

# Get script's directory (devnet/scripts/upgrade/) and parent directory (devnet/)
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PWD_DIR="$(cd "$SCRIPTS_DIR/../.." && pwd)"

# Load environment variables from devnet/.env
if [ ! -f "$PWD_DIR/.env" ]; then
    log_error ".env file not found at $PWD_DIR/.env"
    log_error "Please make sure you have a .env file in the devnet/ directory"
    exit 1
fi

source "$PWD_DIR/.env"

################################################################################
# Step 0: Pre-flight checks
################################################################################

log_step "Step 0: Pre-flight Checks"

# Check if required commands exist
for cmd in docker jq cast; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd is not installed. Please install it first."
        exit 1
    fi
done

# Check if docker is running
if ! docker info &> /dev/null; then
    log_error "Docker is not running. Please start Docker first."
    exit 1
fi

# Check if we're in the correct directory (should be executed from devnet/)
if [ ! -f "$PWD_DIR/docker-compose.yml" ]; then
    log_error "docker-compose.yml not found. Please run this script from devnet/ directory: ./scripts/upgrade/1161-upgrade.sh"
    exit 1
fi

log_success "All pre-flight checks passed"

################################################################################
# Step 1: Identify current Cannon version
################################################################################

log_step "Step 1: Identify Current Cannon Version"

OLD_PRESTATE_DIR="$PWD_DIR/saved-cannon-data"
OLD_PRESTATE_FILE="$OLD_PRESTATE_DIR/prestate-mt64.bin.gz"
OLD_PROOF_FILE="$OLD_PRESTATE_DIR/prestate-proof-mt64.json"

if [ ! -f "$OLD_PRESTATE_FILE" ]; then
    log_error "Old prestate file not found at $OLD_PRESTATE_FILE"
    log_info "Please run 3-op-init.sh first to generate initial prestate files"
    exit 1
fi

# Extract version from old prestate file
OLD_VERSION=$(gunzip -c "$OLD_PRESTATE_FILE" 2>/dev/null | od -An -t u1 -N 1 | xargs)
OLD_HASH=$(jq -r '.pre' "$OLD_PROOF_FILE")

log_info "Current prestate version: v${OLD_VERSION}"
log_info "Current prestate hash: ${OLD_HASH}"

# Map constant value to version name
case $OLD_VERSION in
    4)
        OLD_VERSION_NAME="VersionMultiThreaded64_v2"
        ;;
    5)
        OLD_VERSION_NAME="VersionMultiThreaded_v2"
        ;;
    6)
        OLD_VERSION_NAME="VersionMultiThreaded64_v3"
        ;;
    7)
        OLD_VERSION_NAME="VersionMultiThreaded64_v4"
        ;;
    8)
        OLD_VERSION_NAME="VersionMultiThreaded64_v5"
        ;;
    *)
        OLD_VERSION_NAME="Unknown"
        ;;
esac

log_info "Version name: ${OLD_VERSION_NAME}"

################################################################################
# Step 2: Build new prestate files
################################################################################

log_step "Step 2: Build New Prestate Files"

# Determine target version from current branch (check xlayer-toolkit repo)
CURRENT_BRANCH=$(cd "$PWD_DIR/.." && git rev-parse --abbrev-ref HEAD)
log_info "Current branch: ${CURRENT_BRANCH}"

# sync-1161 branch uses VersionMultiThreaded64_v5 (constant value 8)
EXPECTED_VERSION=8
EXPECTED_VERSION_NAME="VersionMultiThreaded64_v5"

log_info "Expected new version: v${EXPECTED_VERSION} (${EXPECTED_VERSION_NAME})"

# Create new prestate directory
NEW_PRESTATE_DIR="$PWD_DIR/saved-cannon-data-v${EXPECTED_VERSION#v}"
EXPORT_DIR="$NEW_PRESTATE_DIR"

log_info "Building new prestate files..."
log_info "Output directory: ${NEW_PRESTATE_DIR}"

# Confirmation 1: Build prestate
confirm_action "This will build new prestate files using Docker.
- Estimated time: 5-10 minutes
- Version: v${EXPECTED_VERSION} (${EXPECTED_VERSION_NAME})
- Output directory: ${NEW_PRESTATE_DIR}
- Impact: Uses Docker resources, no changes to active system
- Reversible: Yes (can delete the directory)" "low"

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# Determine if we are using rootless Docker
ROOTLESS_DOCKER=$(docker info -f "{{println .SecurityOptions}}" | grep rootless || true)
if ! [ -z "$ROOTLESS_DOCKER" ]; then
    log_info "Using rootless Docker"
    DOCKER_CMD="docker run --rm --privileged "
    DOCKER_TYPE="rootless"
else
    DOCKER_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "
    DOCKER_TYPE="default"
fi

# Run the reproducible-prestate command
log_info "Running reproducible-prestate build (this may take 5-10 minutes)..."
$DOCKER_CMD \
    -v "$SCRIPTS_DIR/../:/scripts" \
    -v "$PWD_DIR/config-op/rollup.json:/app/op-program/chainconfig/configs/${CHAIN_ID}-rollup.json" \
    -v "$PWD_DIR/config-op/genesis.json.gz:/app/op-program/chainconfig/configs/${CHAIN_ID}-genesis-l2.json" \
    -v "$PWD_DIR/l1-geth/execution/genesis.json:/app/op-program/chainconfig/configs/1337-genesis-l1.json" \
    -v "$EXPORT_DIR:/app/op-program/bin" \
    "${OP_STACK_IMAGE_TAG}" \
    bash -c " \
      /scripts/docker-install-start.sh $DOCKER_TYPE
      make -C op-program reproducible-prestate
    "

log_success "Prestate files built successfully"

################################################################################
# Step 3: Compare old and new prestate hashes
################################################################################

log_step "Step 3: Compare Prestate Hashes"

NEW_PRESTATE_FILE="$NEW_PRESTATE_DIR/prestate-mt64.bin.gz"
NEW_PROOF_FILE="$NEW_PRESTATE_DIR/prestate-proof-mt64.json"

if [ ! -f "$NEW_PRESTATE_FILE" ]; then
    log_error "New prestate file not found at $NEW_PRESTATE_FILE"
    exit 1
fi

# Extract version from new prestate file
NEW_VERSION=$(gunzip -c "$NEW_PRESTATE_FILE" 2>/dev/null | od -An -t u1 -N 1 | xargs)
NEW_HASH=$(jq -r '.pre' "$NEW_PROOF_FILE")

log_info "New prestate version: v${NEW_VERSION}"
log_info "New prestate hash: ${NEW_HASH}"

# Use the expected version name from Step 2
NEW_VERSION_NAME="$EXPECTED_VERSION_NAME"
log_info "New version name: ${NEW_VERSION_NAME}"

# Verify the version matches expectation
if [ "$NEW_VERSION" != "$EXPECTED_VERSION" ]; then
    log_warning "Version mismatch! Expected v${EXPECTED_VERSION}, got v${NEW_VERSION}"
    log_warning "This may indicate a problem with the build process"
fi

# Create comparison table
echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    PRESTATE COMPARISON                             ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-20s │ %-45s ║\n" "Property" "Value"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-20s │ %-45s ║\n" "Old Version" "v${OLD_VERSION} (${OLD_VERSION_NAME})"
printf "║ %-20s │ %-45s ║\n" "New Version" "v${NEW_VERSION} (${NEW_VERSION_NAME})"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-20s │ %-45s ║\n" "Old Hash" "${OLD_HASH:0:45}"
printf "║ %-20s │ %-45s ║\n" "" "${OLD_HASH:45}"
printf "║ %-20s │ %-45s ║\n" "New Hash" "${NEW_HASH:0:45}"
printf "║ %-20s │ %-45s ║\n" "" "${NEW_HASH:45}"
echo "╠════════════════════════════════════════════════════════════════════╣"

if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    printf "║ %-20s │ %-45s ║\n" "Hashes Match?" "YES (No L1 update needed)"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    log_success "Prestate hashes are identical!"
    log_info "You can skip L1 update and only need to restart services"
    HASH_CHANGED=false
else
    printf "║ %-20s │ %-45s ║\n" "Hashes Match?" "NO (L1 update required)"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    log_warning "Prestate hashes are different!"
    log_info "L1 contracts need to be updated with new prestate hash"
    HASH_CHANGED=true
fi

################################################################################
# Step 4: Update active prestate files
################################################################################

log_step "Step 4: Update Active Prestate Files"

ACTIVE_PRESTATE_DIR="$PWD_DIR/data/cannon-data"

# Confirmation 2: Update active files
confirm_action "This will REPLACE active prestate files.
- Will DELETE: ${ACTIVE_PRESTATE_DIR}/
- Will COPY: ${NEW_PRESTATE_DIR}/ → ${ACTIVE_PRESTATE_DIR}/
- Backup will be created: ${ACTIVE_PRESTATE_DIR}.backup.<timestamp>
- Impact: Affects op-challenger and op-proposer (when restarted)
- Reversible: Yes (restore from backup)" "high"

log_info "Backing up old prestate files..."
if [ -d "$ACTIVE_PRESTATE_DIR" ]; then
    BACKUP_DIR="$PWD_DIR/data/cannon-data.backup.$(date +%Y%m%d_%H%M%S)"
    cp -r "$ACTIVE_PRESTATE_DIR" "$BACKUP_DIR"
    log_success "Backup saved to ${BACKUP_DIR}"
fi

log_info "Copying new prestate files to ${ACTIVE_PRESTATE_DIR}..."
rm -rf "$ACTIVE_PRESTATE_DIR"
cp -r "$NEW_PRESTATE_DIR" "$ACTIVE_PRESTATE_DIR"
log_success "Active prestate files updated"

log_info "op-challenger will use v8 prestate: ${NEW_HASH:0:20}..."
log_info "Old v7 games (type 0) will be automatically skipped"
log_info "They will resolve naturally after 7 days (no challenger)"

################################################################################
# Step 5: Update L1 contracts (if hash changed)
################################################################################

if [ "$HASH_CHANGED" = true ]; then
    log_step "Step 5: Update L1 Contracts"

    # Check if required environment variables are set
    REQUIRED_VARS=(
        "L1_RPC_URL"
        "DEPLOYER_PRIVATE_KEY"
        "DISPUTE_GAME_FACTORY_ADDRESS"
        "OPCM_IMPL_ADDRESS"
        "SYSTEM_CONFIG_PROXY_ADDRESS"
        "SAFE_ADDRESS"
    )

    MISSING_VARS=()
    for var in "${REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            MISSING_VARS+=("$var")
        fi
    done

    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${MISSING_VARS[@]}"; do
            log_error "  - $var"
        done
        log_info "Please set these variables in your .env file"
        exit 1
    fi

    # Check if add-game-type.sh exists
    ADD_GAME_TYPE_SCRIPT="$PWD_DIR/scripts/add-game-type.sh"
    if [ ! -f "$ADD_GAME_TYPE_SCRIPT" ]; then
        log_error "add-game-type.sh not found at $ADD_GAME_TYPE_SCRIPT"
        exit 1
    fi

    log_info "Updating Game Type 0 with new v8 FaultDisputeGame..."
    log_info "New Hash: ${NEW_HASH}"

    # Confirmation 3: Update game type 0 (CRITICAL)
    confirm_action "This will UPDATE Game Type 0 on L1 (send transactions).
- Contract: DisputeGameFactory at ${DISPUTE_GAME_FACTORY_ADDRESS}
- Operation:
  1. Deploy new FaultDisputeGame contract (v8)
  2. Update game type 0 implementation via DGF.setImplementation()
- Game Type: 0 (Permissionless Cannon - UPDATE to v8)
- Impact:
  * Will send transactions to L1 (requires gas)
  * Game type 0 will use new v8 prestate: ${NEW_HASH}
  * Old v7 games remain unchanged (will expire in 7 days)
  * New games will use v8 prestate
  * op-challenger can handle new v8 games (supports game type 0)
- Reversible: Partially (can deploy another contract and update again)
- Cost: L1 gas fees

⚠️  CRITICAL: This changes on-chain state!" "critical"

    log_info "Step 5.1: Deploying new FaultDisputeGame contract (v8)..."

    # Get reference parameters from existing game type 1
    REF_GAME=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" 'gameImpls(uint32)(address)' 1)
    log_info "Reference game (type 1): $REF_GAME"

    # Get constructor parameters
    MAX_GAME_DEPTH=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'maxGameDepth()')
    SPLIT_DEPTH=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'splitDepth()')
    CLOCK_EXT=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'clockExtension()(uint64)')
    MAX_CLOCK=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'maxClockDuration()(uint64)')
    VM=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'vm()(address)')
    WETH=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'weth()(address)')
    ASR=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'anchorStateRegistry()(address)')
    L2_CHAIN_ID=$(cast call --rpc-url "$L1_RPC_URL" "$REF_GAME" 'l2ChainId()')

    log_info "Parameters retrieved successfully"

    # Get FaultDisputeGame bytecode
    log_info "Fetching FaultDisputeGame bytecode from Docker..."
    BYTECODE=$(docker run --rm "${OP_STACK_IMAGE_TAG}" bash -c "
        cd /app/packages/contracts-bedrock && \
        forge inspect src/dispute/FaultDisputeGame.sol:FaultDisputeGame bytecode
    ")

    if [ -z "$BYTECODE" ]; then
        log_error "Failed to fetch bytecode"
        exit 1
    fi

    log_info "Bytecode fetched (${#BYTECODE} chars)"

    # Encode constructor arguments
    GAME_TYPE_FOR_DEPLOY=0
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(uint32,bytes32,uint256,uint256,uint64,uint64,address,address,address,uint256)" \
        $GAME_TYPE_FOR_DEPLOY "$NEW_HASH" "$MAX_GAME_DEPTH" "$SPLIT_DEPTH" "$CLOCK_EXT" "$MAX_CLOCK" "$VM" "$WETH" "$ASR" "$L2_CHAIN_ID")

    # Deploy contract
    log_info "Deploying new FaultDisputeGame contract..."
    DEPLOY_DATA="${BYTECODE}${CONSTRUCTOR_ARGS:2}"

    TX_OUTPUT=$(cast send \
        --rpc-url "$L1_RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --legacy \
        --create "$DEPLOY_DATA" \
        --json)

    NEW_GAME_ADDRESS=$(echo "$TX_OUTPUT" | jq -r '.contractAddress')

    if [ -z "$NEW_GAME_ADDRESS" ] || [ "$NEW_GAME_ADDRESS" = "null" ]; then
        log_error "Failed to deploy FaultDisputeGame"
        exit 1
    fi

    log_success "New FaultDisputeGame deployed at: $NEW_GAME_ADDRESS"

    # Verify prestate
    DEPLOYED_PRESTATE=$(cast call --rpc-url "$L1_RPC_URL" "$NEW_GAME_ADDRESS" 'absolutePrestate()')
    if [ "$DEPLOYED_PRESTATE" = "$NEW_HASH" ]; then
        log_success "Prestate verified: $DEPLOYED_PRESTATE"
    else
        log_error "Prestate mismatch! Expected: $NEW_HASH, Got: $DEPLOYED_PRESTATE"
        exit 1
    fi

    log_info "Step 5.2: Updating game type 0 implementation..."

    # Update game type 0 via Transactor.CALL(DGF.setImplementation)
    SET_IMPL_CALLDATA=$(cast calldata "setImplementation(uint32,address,bytes)" 0 "$NEW_GAME_ADDRESS" "0x")

    TX_OUTPUT=$(cast send \
        --rpc-url "$L1_RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --legacy \
        --json \
        "$TRANSACTOR" \
        "CALL(address,bytes,uint256)" \
        "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "$SET_IMPL_CALLDATA" \
        0)

    TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status')

    if [ "$TX_STATUS" != "0x1" ]; then
        log_error "Failed to update game type 0"
        echo "$TX_OUTPUT"
        exit 1
    fi

    log_success "Game type 0 updated successfully"

    # Verify update
    VERIFIED_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameImpls(uint32)(address)" 0)

    if [ "$(echo $VERIFIED_IMPL | tr '[:upper:]' '[:lower:]')" = "$(echo $NEW_GAME_ADDRESS | tr '[:upper:]' '[:lower:]')" ]; then
        log_success "Verification passed: Game type 0 now points to $NEW_GAME_ADDRESS"
    else
        log_error "Verification failed! Expected: $NEW_GAME_ADDRESS, Got: $VERIFIED_IMPL"
        exit 1
    fi
else
    log_step "Step 5: Update L1 Contracts"
    log_info "Hashes are identical, skipping L1 update"
fi

################################################################################
# Step 5.5: Update op-proposer configuration
################################################################################

if [ "$HASH_CHANGED" = true ]; then
    log_step "Step 5.5: Update op-proposer Configuration"

    confirm_action "This will UPDATE op-proposer to use updated game type 0.
- Will modify: .env file
- Change: Ensure GAME_TYPE=0
- Impact:
  * Future proposals will use game type 0 (now with v8 prestate)
  * op-proposer needs to be restarted for this to take effect
- Reversible: Yes (edit .env file manually)" "medium"

    # Update GAME_TYPE in .env file
    if grep -q "^GAME_TYPE=" "$PWD_DIR/.env"; then
        # Update existing GAME_TYPE
        sed_inplace "s/^GAME_TYPE=.*/GAME_TYPE=0/" "$PWD_DIR/.env"
        log_success "Updated GAME_TYPE=0 in .env"
    else
        # Add GAME_TYPE if not exists
        echo "" >> "$PWD_DIR/.env"
        echo "# Game type for op-proposer (updated by 1161-upgrade.sh)" >> "$PWD_DIR/.env"
        echo "GAME_TYPE=0" >> "$PWD_DIR/.env"
        log_success "Added GAME_TYPE=0 to .env"
    fi

    log_info "op-proposer will use game type 0 (v8) after restart"
fi

################################################################################
# Step 6: Restart affected services
################################################################################

log_step "Step 6: Restart Affected Services"

SERVICES_TO_RESTART=(
    "op-challenger"
    "op-proposer"
)

# Confirmation 4: Restart services
confirm_action "This will RESTART critical services.
- Services to restart: ${SERVICES_TO_RESTART[*]}
- Downtime per service: ~5-10 seconds
- Total downtime: ~10-20 seconds
- Impact:
  * op-challenger: Will stop monitoring games temporarily
  * op-proposer: Will stop proposing outputs temporarily
  * L2 chain: Will continue running (op-node & op-geth not affected)
  * User transactions: Not affected
- Reversible: Yes (can restart again immediately)" "medium"

log_info "Stopping services to reload environment variables..."
(cd "$PWD_DIR" && docker compose stop "${SERVICES_TO_RESTART[@]}")

if [ $? -eq 0 ]; then
    log_success "Services stopped"
else
    log_error "Failed to stop services"
    exit 1
fi

log_info "Starting services with updated configuration..."
(cd "$PWD_DIR" && docker compose up -d "${SERVICES_TO_RESTART[@]}")

if [ $? -eq 0 ]; then
    log_success "All services restarted with new configuration"
else
    log_error "Failed to start services"
    exit 1
fi

log_info "Services restarted: ${SERVICES_TO_RESTART[*]}"

################################################################################
# Step 7: Verify
################################################################################

log_step "Step 7: Verification"

log_info "Waiting 10 seconds for services to stabilize..."
sleep 10

# Check op-challenger logs
log_info "Checking op-challenger logs..."
CHALLENGER_LOGS=$(docker logs op-challenger --tail 50 2>&1)

if echo "$CHALLENGER_LOGS" | grep -q "unknown version"; then
    log_error "op-challenger still has version errors!"
    echo "$CHALLENGER_LOGS" | grep "unknown version" | tail -5
elif echo "$CHALLENGER_LOGS" | grep -q "Loaded absolute pre-state"; then
    log_success "op-challenger loaded prestate successfully"
    echo "$CHALLENGER_LOGS" | grep "Loaded absolute pre-state" | tail -1
else
    log_warning "Could not determine op-challenger status from logs"
fi

# Check op-proposer logs
log_info "Checking op-proposer logs..."
PROPOSER_LOGS=$(docker logs op-proposer --tail 50 2>&1)

if echo "$PROPOSER_LOGS" | grep -qi "error"; then
    log_warning "op-proposer has some errors in logs:"
    echo "$PROPOSER_LOGS" | grep -i "error" | tail -3
elif echo "$PROPOSER_LOGS" | grep -q "Proposing"; then
    log_success "op-proposer is running normally"
else
    log_info "op-proposer logs look normal (no errors detected)"
fi

# Verify GAME_TYPE configuration
log_info "Verifying GAME_TYPE configuration..."
CURRENT_GAME_TYPE=$(grep "^GAME_TYPE=" "$PWD_DIR/.env" | cut -d'=' -f2)
if [ "$CURRENT_GAME_TYPE" = "0" ]; then
    log_success "GAME_TYPE correctly set to 0 in .env"

    # Verify game type 0 uses v8 prestate
    GAME0_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameImpls(uint32)(address)" 0)
    GAME0_PRESTATE=$(cast call --rpc-url "$L1_RPC_URL" "$GAME0_IMPL" 'absolutePrestate()')
    log_info "Game type 0 prestate: $GAME0_PRESTATE"

    if [ "$GAME0_PRESTATE" = "$NEW_HASH" ]; then
        log_success "Game type 0 is using v8 prestate!"
    else
        log_warning "Game type 0 prestate does not match expected v8 hash"
    fi
else
    log_error "GAME_TYPE is NOT set to 0!"
    log_error "Current value: GAME_TYPE=${CURRENT_GAME_TYPE:-not set}"
    log_warning "This means op-proposer might not use the updated game type!"
    log_info "To fix: Run 'echo GAME_TYPE=0 >> .env' and restart op-proposer"
fi

################################################################################
# Summary
################################################################################

log_step "Summary"

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                       UPGRADE SUMMARY                              ║"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-66s ║\n" "Old Version: v${OLD_VERSION} (${OLD_VERSION_NAME})"
printf "║ %-66s ║\n" "New Version: v${NEW_VERSION} (${NEW_VERSION_NAME})"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-66s ║\n" "Old Hash: ${OLD_HASH:0:66}"
printf "║ %-66s ║\n" "New Hash: ${NEW_HASH:0:66}"
echo "╠════════════════════════════════════════════════════════════════════╣"

if [ "$HASH_CHANGED" = true ]; then
    printf "║ %-66s ║\n" "L1 Update: Required and COMPLETED"
else
    printf "║ %-66s ║\n" "L1 Update: Not required (hashes identical)"
fi

printf "║ %-66s ║\n" "Services Restarted: ${SERVICES_TO_RESTART[*]}"
echo "╠════════════════════════════════════════════════════════════════════╣"
printf "║ %-66s ║\n" "New Prestate Dir: ${NEW_PRESTATE_DIR##*/}"
printf "║ %-66s ║\n" "Active Prestate: data/cannon-data/"
echo "╚════════════════════════════════════════════════════════════════════╝"

echo ""

log_success "Upgrade completed successfully!"

