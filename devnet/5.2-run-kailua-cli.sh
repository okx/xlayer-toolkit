#!/bin/bash

set -e
# ============================================================================
# Kailua Setup Script (using local kailua-cli)
# Supports both Fault Proof and Validity (Fast Finality) modes
# Supports Mock Mode (dev) and Boundless Mode (production)
# Supports Pinata (IPFS) and S3/R2 storage providers
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables
source .env

# Helper function for sed (macOS compatible)
sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Check kailua-cli is available
if ! command -v kailua-cli &> /dev/null; then
    echo "❌ Error: kailua-cli not found in PATH"
    echo "Please install kailua-cli or add it to your PATH"
    exit 1
fi

# Local RPC URLs (not Docker internal)
L1_RPC=${L1_RPC_URL:-http://localhost:8545}
L2_NODE_RPC=${L2_NODE_RPC_URL:-http://localhost:9545}
L2_GETH_RPC=${L2_RPC_URL:-http://localhost:8123}
L1_BEACON_RPC=${L1_BEACON_URL:-http://localhost:3500}

# Check RPC services are available before proceeding
check_rpc() {
    local url=$1
    local name=$2
    if ! curl -s --max-time 3 "$url" > /dev/null 2>&1; then
        echo "❌ $name ($url) is not responding"
        echo "   Please ensure the service is running before starting kailua-cli"
        exit 1
    fi
    echo "✓ $name OK"
}

echo "🔍 Checking RPC services..."
check_rpc "$L1_RPC" "L1 RPC"
check_rpc "$L2_NODE_RPC" "L2 Node RPC"
check_rpc "$L2_GETH_RPC" "L2 Geth RPC"
echo ""

# Get anchor root height from AnchorStateRegistry
ANCHOR_STATE_REGISTRY=$(cast call "$OPTIMISM_PORTAL_PROXY_ADDRESS" 'anchorStateRegistry()(address)' -r "$L1_RPC")
ANCHOR_HEIGHT=$(cast call "$ANCHOR_STATE_REGISTRY" "getAnchorRoot()(bytes32,uint256)" --json -r "$L1_RPC" | jq -r '.[1]')
echo "📍 Current Anchor Height: $ANCHOR_HEIGHT"

# Default values (can be overridden in .env)
KAILUA_STARTING_BLOCK_NUMBER=${KAILUA_STARTING_BLOCK_NUMBER:-$ANCHOR_HEIGHT}
KAILUA_PROPOSAL_OUTPUT_COUNT=${KAILUA_PROPOSAL_OUTPUT_COUNT:-2}
KAILUA_OUTPUT_BLOCK_SPAN=${KAILUA_OUTPUT_BLOCK_SPAN:-1}
KAILUA_COLLATERAL_AMOUNT=${KAILUA_COLLATERAL_AMOUNT:-100000000000000000}  # 0.1 ETH
KAILUA_CHALLENGE_TIMEOUT=${KAILUA_CHALLENGE_TIMEOUT:-86400}  # 24 hours
KAILUA_MAX_FAULT_PROVING_DELAY=${KAILUA_MAX_FAULT_PROVING_DELAY:-60}  # 1 min
KAILUA_GAME_TYPE=${KAILUA_GAME_TYPE:-1337}

# Fast Finality / Validity mode configuration
# Set KAILUA_FAST_FINALITY=true to enable validity proofs for fast finality
KAILUA_FAST_FINALITY=${KAILUA_FAST_FINALITY:-false}
KAILUA_FAST_FORWARD_START=${KAILUA_FAST_FORWARD_START:-$KAILUA_STARTING_BLOCK_NUMBER}
KAILUA_FAST_FORWARD_TARGET=${KAILUA_FAST_FORWARD_TARGET:-999999999}
KAILUA_MAX_VALIDITY_PROVING_DELAY=${KAILUA_MAX_VALIDITY_PROVING_DELAY:-0}

# Mock Mode configuration
# Set KAILUA_MOCK_MODE=false to use Boundless for real proving
KAILUA_MOCK_MODE=${KAILUA_MOCK_MODE:-true}

# Boundless configuration (required when KAILUA_MOCK_MODE=false)
BOUNDLESS_RPC_URL=${BOUNDLESS_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}
BOUNDLESS_CHAIN_ID=${BOUNDLESS_CHAIN_ID:-11155111}
BOUNDLESS_WALLET_KEY=${BOUNDLESS_WALLET_KEY:-}
BOUNDLESS_MARKET_ADDRESS=${BOUNDLESS_MARKET_ADDRESS:-}
BOUNDLESS_VERIFIER_ROUTER_ADDRESS=${BOUNDLESS_VERIFIER_ROUTER_ADDRESS:-}
BOUNDLESS_SET_VERIFIER_ADDRESS=${BOUNDLESS_SET_VERIFIER_ADDRESS:-}
BOUNDLESS_COLLATERAL_TOKEN_ADDRESS=${BOUNDLESS_COLLATERAL_TOKEN_ADDRESS:-}

# Boundless order pricing parameters
# These control how much you pay provers and how long they have to complete
BOUNDLESS_CYCLE_MIN_WEI=${BOUNDLESS_CYCLE_MIN_WEI:-200000000}              # Starting price (wei/cycle)
BOUNDLESS_CYCLE_MAX_WEI=${BOUNDLESS_CYCLE_MAX_WEI:-1000000000}     # Max price (wei/cycle), 2 gwei
BOUNDLESS_MEGA_CYCLE_COLLATERAL=${BOUNDLESS_MEGA_CYCLE_COLLATERAL:-1000}  # Collateral per megacycle

# Boundless order timing parameters (in seconds per segment, where 1 segment = 1M cycles)
# lock_timeout = (ramp_up_factor + lock_timeout_factor) * segment_count
# expiry = (ramp_up_factor + lock_timeout_factor + expiry_factor) * segment_count
BOUNDLESS_ORDER_BID_DELAY_FACTOR=${BOUNDLESS_ORDER_BID_DELAY_FACTOR:-1.0}      # Delay before price ramp starts
BOUNDLESS_ORDER_RAMP_UP_FACTOR=${BOUNDLESS_ORDER_RAMP_UP_FACTOR:-5.0}          # Time for price to ramp from min to max
BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR=${BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR:-60.0}  # Time for prover to complete after lock
BOUNDLESS_ORDER_EXPIRY_FACTOR=${BOUNDLESS_ORDER_EXPIRY_FACTOR:-30.0}           # Additional time before order expires

# Storage provider configuration (required when KAILUA_MOCK_MODE=false)
# Options: "pinata" or "s3"
STORAGE_PROVIDER=${STORAGE_PROVIDER:-pinata}

# Pinata configuration (when STORAGE_PROVIDER=pinata)
PINATA_JWT=${PINATA_JWT:-}
PINATA_API_URL=${PINATA_API_URL:-https://api.pinata.cloud}
IPFS_GATEWAY_URL=${IPFS_GATEWAY_URL:-https://gateway.pinata.cloud}

# S3/R2 configuration (when STORAGE_PROVIDER=s3)
S3_ACCESS_KEY=${S3_ACCESS_KEY:-}
S3_SECRET_KEY=${S3_SECRET_KEY:-}
S3_BUCKET=${S3_BUCKET:-}
S3_URL=${S3_URL:-}
AWS_REGION=${AWS_REGION:-auto}
R2_DOMAIN=${R2_DOMAIN:-}

# Determine proving mode
if [ "$KAILUA_FAST_FINALITY" = "true" ]; then
    PROVING_MODE="VALIDITY (Fast Finality)"
    PROVING_MODE_COLOR="\033[0;32m"  # Green
else
    PROVING_MODE="FAULT PROOF"
    PROVING_MODE_COLOR="\033[0;33m"  # Yellow
fi

# Determine execution mode
if [ "$KAILUA_MOCK_MODE" = "true" ]; then
    EXEC_MODE="MOCK (Dev Mode)"
    EXEC_MODE_COLOR="\033[0;36m"  # Cyan
else
    EXEC_MODE="BOUNDLESS (Production)"
    EXEC_MODE_COLOR="\033[0;35m"  # Magenta
    
    # Validate Boundless configuration
    if [ -z "$BOUNDLESS_WALLET_KEY" ]; then
        echo "❌ Error: BOUNDLESS_WALLET_KEY is required when KAILUA_MOCK_MODE=false"
        exit 1
    fi
    
    # Validate storage provider configuration
    if [ "$STORAGE_PROVIDER" = "pinata" ]; then
        if [ -z "$PINATA_JWT" ]; then
            echo "❌ Error: PINATA_JWT is required when STORAGE_PROVIDER=pinata"
            exit 1
        fi
        STORAGE_DESC="Pinata (IPFS)"
    elif [ "$STORAGE_PROVIDER" = "s3" ]; then
        if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_URL" ]; then
            echo "❌ Error: S3_ACCESS_KEY, S3_SECRET_KEY, S3_BUCKET, and S3_URL are required when STORAGE_PROVIDER=s3"
            exit 1
        fi
        STORAGE_DESC="S3/R2 ($S3_BUCKET)"
    else
        echo "❌ Error: STORAGE_PROVIDER must be 'pinata' or 's3'"
        exit 1
    fi
fi

NC="\033[0m"  # No Color

echo "============================================"
echo "  Kailua Fast-Track Deployment (CLI)"
echo "============================================"
echo -e "Proving Mode: ${PROVING_MODE_COLOR}${PROVING_MODE}${NC}"
echo -e "Execution Mode: ${EXEC_MODE_COLOR}${EXEC_MODE}${NC}"
echo ""
echo "Starting Block: $KAILUA_STARTING_BLOCK_NUMBER"
echo "Output Count: $KAILUA_PROPOSAL_OUTPUT_COUNT"
echo "Block Span: $KAILUA_OUTPUT_BLOCK_SPAN"
echo "Collateral: $KAILUA_COLLATERAL_AMOUNT wei"
echo "Challenge Timeout: $KAILUA_CHALLENGE_TIMEOUT seconds"
echo "Game Type: $KAILUA_GAME_TYPE"

if [ "$KAILUA_FAST_FINALITY" = "true" ]; then
    echo ""
    echo "Fast Finality Settings:"
    echo "  Fast Forward Start: $KAILUA_FAST_FORWARD_START"
    echo "  Fast Forward Target: $KAILUA_FAST_FORWARD_TARGET"
    echo "  Max Validity Proving Delay: $KAILUA_MAX_VALIDITY_PROVING_DELAY"
fi

if [ "$KAILUA_MOCK_MODE" = "false" ]; then
    echo ""
    echo "Boundless Settings:"
    echo "  RPC URL: $BOUNDLESS_RPC_URL"
    echo "  Chain ID: $BOUNDLESS_CHAIN_ID"
    echo "  Storage: $STORAGE_DESC"
    echo ""
    echo "Boundless Order Pricing:"
    echo "  Min Price: $BOUNDLESS_CYCLE_MIN_WEI wei/cycle"
    echo "  Max Price: $BOUNDLESS_CYCLE_MAX_WEI wei/cycle"
    echo "  Collateral: $BOUNDLESS_MEGA_CYCLE_COLLATERAL per megacycle"
    echo ""
    echo "Boundless Order Timing (factor × segments):"
    echo "  Bid Delay Factor: $BOUNDLESS_ORDER_BID_DELAY_FACTOR"
    echo "  Ramp Up Factor: $BOUNDLESS_ORDER_RAMP_UP_FACTOR"
    echo "  Lock Timeout Factor: $BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR"
    echo "  Expiry Factor: $BOUNDLESS_ORDER_EXPIRY_FACTOR"
fi

echo ""
echo "RPC URLs:"
echo "  L1: $L1_RPC"
echo "  L2 Node: $L2_NODE_RPC"
echo "  L2 Geth: $L2_GETH_RPC"
echo "  L1 Beacon: $L1_BEACON_RPC"
echo ""

# ============================================
# Calculate correct genesis_time for contract
# ============================================
L1_BLOCK_JSON=$(cast block --rpc-url "$L1_RPC" --json)
L1_TIMESTAMP=$(echo "$L1_BLOCK_JSON" | jq -r '.timestamp' | xargs printf "%d")
L2_BLOCK_TIME=${L2_BLOCK_TIME:-2}
GENESIS_TIME_OVERRIDE=$((L1_TIMESTAMP - KAILUA_STARTING_BLOCK_NUMBER * L2_BLOCK_TIME))

echo "Time Calculation:"
echo "  L1 Timestamp: $L1_TIMESTAMP"
echo "  Starting Block: $KAILUA_STARTING_BLOCK_NUMBER"
echo "  L2 Block Time: $L2_BLOCK_TIME seconds"
echo "  Genesis Time Override: $GENESIS_TIME_OVERRIDE"
echo ""

# Deploy Kailua contracts via fast-track (using local kailua-cli)
echo "🚀 Deploying Kailua contracts..."

# Set RISC0_DEV_MODE only in mock mode
if [ "$KAILUA_MOCK_MODE" = "true" ]; then
    export RISC0_DEV_MODE=1
else
    unset RISC0_DEV_MODE
fi

export RUST_LOG="kailua=info,alloy=warn,hyper=warn,warn"
export NO_COLOR=1

# Create log directory
mkdir -p "$SCRIPT_DIR/kailua/logs"
DEPLOY_LOG="$SCRIPT_DIR/kailua/logs/kailua-deploy.log"

kailua-cli fast-track \
  --op-node-url "$L2_NODE_RPC" \
  --op-geth-url "$L2_GETH_RPC" \
  --eth-rpc-url "$L1_RPC" \
  --starting-block-number "$KAILUA_STARTING_BLOCK_NUMBER" \
  --genesis-time-override "$GENESIS_TIME_OVERRIDE" \
  --proposal-output-count "$KAILUA_PROPOSAL_OUTPUT_COUNT" \
  --output-block-span "$KAILUA_OUTPUT_BLOCK_SPAN" \
  --collateral-amount "$KAILUA_COLLATERAL_AMOUNT" \
  --challenge-timeout "$KAILUA_CHALLENGE_TIMEOUT" \
  --deployer-key "$DEPLOYER_PRIVATE_KEY" \
  --owner-key "$DEPLOYER_PRIVATE_KEY" \
  --guardian-key "$DEPLOYER_PRIVATE_KEY" \
  --txn-timeout 300 \
  --exec-gas-premium 200 \
  --bypass-chain-registry 2>&1 | tee "$DEPLOY_LOG"

DEPLOY_OUTPUT=$(cat "$DEPLOY_LOG")

# Extract KAILUA_GAME_ADDRESS from output (if available)
KAILUA_GAME_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'game.*0x[a-fA-F0-9]{40}' | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true)
if [ -n "$KAILUA_GAME_ADDRESS" ]; then
    echo "✅ Kailua Game Address: $KAILUA_GAME_ADDRESS"
    sed_inplace "s|^KAILUA_GAME_ADDRESS=.*|KAILUA_GAME_ADDRESS=$KAILUA_GAME_ADDRESS|" .env
fi

# Set respected game type on AnchorStateRegistry
echo ""
echo "📝 Setting respected game type to $KAILUA_GAME_TYPE..."
cast send "$ANCHOR_STATE_REGISTRY" "setRespectedGameType(uint32)" "$KAILUA_GAME_TYPE" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --rpc-url "$L1_RPC"
echo "✅ Respected game type set to $KAILUA_GAME_TYPE"

# Query and export Kailua game implementation address
echo ""
echo "🔍 Querying Kailua game implementation..."
KAILUA_GAME_IMPL=$(cast call "$DISPUTE_GAME_FACTORY_ADDRESS" "gameImpls(uint32)(address)" "$KAILUA_GAME_TYPE" --rpc-url "$L1_RPC")
if [ -n "$KAILUA_GAME_IMPL" ] && [ "$KAILUA_GAME_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
    echo "✅ Kailua Game Implementation: $KAILUA_GAME_IMPL"
    sed_inplace "s|^KAILUA_GAME_ADDRESS=.*|KAILUA_GAME_ADDRESS=$KAILUA_GAME_IMPL|" .env
else
    echo "⚠️  No game implementation found for type $KAILUA_GAME_TYPE"
fi

# Stop OP proposer/challenger if running
echo ""
echo "🛑 Stopping OP proposer and challenger..."
docker compose down op-proposer op-challenger 2>/dev/null || true

# Log files
PROPOSER_LOG="$SCRIPT_DIR/kailua/logs/kailua-proposer.log"
VALIDATOR_LOG="$SCRIPT_DIR/kailua/logs/kailua-validator.log"

# Create data directories
mkdir -p "$SCRIPT_DIR/kailua/propose-data"
mkdir -p "$SCRIPT_DIR/kailua/validate-data"

echo ""
echo "🚀 Starting Kailua proposer..."
echo "   Log: $PROPOSER_LOG"

kailua-cli propose \
  --op-node-url "$L2_NODE_RPC" \
  --op-geth-url "$L2_GETH_RPC" \
  --eth-rpc-url "$L1_RPC" \
  --beacon-rpc-url "$L1_BEACON_RPC" \
  --data-dir "$SCRIPT_DIR/kailua/propose-data" \
  --proposer-key "$KAILUA_PROPOSER_KEY" \
  --kailua-game-implementation "$KAILUA_GAME_IMPL" \
  --bypass-chain-registry \
  > "$PROPOSER_LOG" 2>&1 &
PROPOSER_PID=$!
echo "   ✓ Proposer started (PID: $PROPOSER_PID)"

echo ""
echo -e "🚀 Starting Kailua validator (${PROVING_MODE_COLOR}${PROVING_MODE}${NC}, ${EXEC_MODE_COLOR}${EXEC_MODE}${NC})..."
echo "   Log: $VALIDATOR_LOG"

# Build validator command with optional fast-forward parameters
VALIDATOR_CMD="kailua-cli validate \
  --op-node-url \"$L2_NODE_RPC\" \
  --op-geth-url \"$L2_GETH_RPC\" \
  --eth-rpc-url \"$L1_RPC\" \
  --beacon-rpc-url \"$L1_BEACON_RPC\" \
  --data-dir \"$SCRIPT_DIR/kailua/validate-data\" \
  --validator-key \"$KAILUA_VALIDATOR_KEY\" \
  --kailua-game-implementation \"$KAILUA_GAME_IMPL\" \
  --kailua-cli \"$(which kailua-cli)\" \
  --bypass-chain-registry \
  --max-fault-proving-delay \"$KAILUA_MAX_FAULT_PROVING_DELAY\""

# Add fast-forward parameters if fast finality mode is enabled
if [ "$KAILUA_FAST_FINALITY" = "true" ]; then
    VALIDATOR_CMD="$VALIDATOR_CMD \
  --fast-forward-start \"$KAILUA_FAST_FORWARD_START\" \
  --fast-forward-target \"$KAILUA_FAST_FORWARD_TARGET\" \
  --max-validity-proving-delay \"$KAILUA_MAX_VALIDITY_PROVING_DELAY\""
fi

# Add Boundless parameters if not in mock mode
if [ "$KAILUA_MOCK_MODE" = "false" ]; then
    VALIDATOR_CMD="$VALIDATOR_CMD \
  --boundless-rpc-url \"$BOUNDLESS_RPC_URL\" \
  --boundless-wallet-key \"$BOUNDLESS_WALLET_KEY\" \
  --boundless-chain-id \"$BOUNDLESS_CHAIN_ID\" \
  --boundless-cycle-min-wei \"$BOUNDLESS_CYCLE_MIN_WEI\" \
  --boundless-cycle-max-wei \"$BOUNDLESS_CYCLE_MAX_WEI\" \
  --boundless-mega-cycle-collateral \"$BOUNDLESS_MEGA_CYCLE_COLLATERAL\" \
  --boundless-order-bid-delay-factor \"$BOUNDLESS_ORDER_BID_DELAY_FACTOR\" \
  --boundless-order-ramp-up-factor \"$BOUNDLESS_ORDER_RAMP_UP_FACTOR\" \
  --boundless-order-lock-timeout-factor \"$BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR\" \
  --boundless-order-expiry-factor \"$BOUNDLESS_ORDER_EXPIRY_FACTOR\""
  
    # Add storage provider configuration
    if [ "$STORAGE_PROVIDER" = "pinata" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD \
  --storage-provider pinata \
  --pinata-jwt \"$PINATA_JWT\""
        if [ -n "$PINATA_API_URL" ]; then
            VALIDATOR_CMD="$VALIDATOR_CMD --pinata-api-url \"$PINATA_API_URL\""
        fi
        if [ -n "$IPFS_GATEWAY_URL" ]; then
            VALIDATOR_CMD="$VALIDATOR_CMD --ipfs-gateway-url \"$IPFS_GATEWAY_URL\""
        fi
    elif [ "$STORAGE_PROVIDER" = "s3" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD \
  --storage-provider s3 \
  --s3-access-key \"$S3_ACCESS_KEY\" \
  --s3-secret-key \"$S3_SECRET_KEY\" \
  --s3-bucket \"$S3_BUCKET\" \
  --s3-url \"$S3_URL\" \
  --aws-region \"$AWS_REGION\""
        if [ -n "$R2_DOMAIN" ]; then
            VALIDATOR_CMD="$VALIDATOR_CMD --r2-domain \"$R2_DOMAIN\""
        fi
    fi
  
    # Add optional Boundless addresses if provided
    if [ -n "$BOUNDLESS_MARKET_ADDRESS" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD --boundless-market-address \"$BOUNDLESS_MARKET_ADDRESS\""
    fi
    if [ -n "$BOUNDLESS_VERIFIER_ROUTER_ADDRESS" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD --boundless-verifier-router-address \"$BOUNDLESS_VERIFIER_ROUTER_ADDRESS\""
    fi
    if [ -n "$BOUNDLESS_SET_VERIFIER_ADDRESS" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD --boundless-set-verifier-address \"$BOUNDLESS_SET_VERIFIER_ADDRESS\""
    fi
    if [ -n "$BOUNDLESS_COLLATERAL_TOKEN_ADDRESS" ]; then
        VALIDATOR_CMD="$VALIDATOR_CMD --boundless-collateral-token-address \"$BOUNDLESS_COLLATERAL_TOKEN_ADDRESS\""
    fi
fi

# Set log level
export RUST_LOG="warn,kailua=info,kailua_validator=info,kailua_proposer=info,kailua_prover=info,kailua_sync=info,oracle_server=off,oracle_client=off,host_backend=off,risc0_zkvm=off,risc0=off,alloy=warn,alloy_rpc_client=off,alloy_json_rpc=off,alloy_transport_http=off,hyper=off,hyper_util=off,reqwest=off,kona=warn,kona_derive=warn,kona_executor=warn,kona_mpt=warn,batch_validator=warn,hint_writer=off,hint_reader=off,frame_queue=warn,channel_reader=warn,pipeline=warn"

# Execute validator command
eval "$VALIDATOR_CMD" > "$VALIDATOR_LOG" 2>&1 &
VALIDATOR_PID=$!
echo "   ✓ Validator started (PID: $VALIDATOR_PID)"

# Save PIDs to file for later management
echo "$PROPOSER_PID" > "$SCRIPT_DIR/kailua/proposer.pid"
echo "$VALIDATOR_PID" > "$SCRIPT_DIR/kailua/validator.pid"

echo ""
echo "============================================"
echo "  Kailua Setup Complete"
echo "============================================"
echo -e "Proving Mode: ${PROVING_MODE_COLOR}${PROVING_MODE}${NC}"
echo -e "Execution Mode: ${EXEC_MODE_COLOR}${EXEC_MODE}${NC}"
echo "Proposer PID: $PROPOSER_PID"
echo "Validator PID: $VALIDATOR_PID"
echo ""
echo "To stop:"
echo "  kill $PROPOSER_PID $VALIDATOR_PID"
echo "  # or"
echo "  kill \$(cat $SCRIPT_DIR/kailua/proposer.pid) \$(cat $SCRIPT_DIR/kailua/validator.pid)"
echo ""
echo "To view logs:"
echo "  tail -f $PROPOSER_LOG"
echo "  tail -f $VALIDATOR_LOG"
echo ""

if [ "$KAILUA_MOCK_MODE" = "true" ]; then
    echo "📝 Mock Mode is ENABLED (RISC0_DEV_MODE=1)"
    echo "   Proofs are simulated, not cryptographically verified"
    echo ""
    echo "   To use Boundless for real proving, set in .env:"
    echo "   KAILUA_MOCK_MODE=false"
    echo "   BOUNDLESS_WALLET_KEY=your_private_key"
    echo ""
    echo "   For Pinata storage:"
    echo "   STORAGE_PROVIDER=pinata"
    echo "   PINATA_JWT=your_pinata_jwt"
    echo ""
    echo "   For S3/R2 storage:"
    echo "   STORAGE_PROVIDER=s3"
    echo "   S3_ACCESS_KEY=your_access_key"
    echo "   S3_SECRET_KEY=your_secret_key"
    echo "   S3_BUCKET=your_bucket"
    echo "   S3_URL=https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com"
    echo "   AWS_REGION=auto"
else
    echo "📝 Boundless Mode is ENABLED"
    echo "   Proofs are delegated to the Boundless proving network"
    echo "   Storage: $STORAGE_DESC"
    echo ""
    echo "   Order timing for 100M cycles (100 segments):"
    echo "   - Bid starts after: $(echo "$BOUNDLESS_ORDER_BID_DELAY_FACTOR * 100" | bc) seconds"
    echo "   - Price ramps over: $(echo "$BOUNDLESS_ORDER_RAMP_UP_FACTOR * 100" | bc) seconds"
    echo "   - Lock timeout: $(echo "($BOUNDLESS_ORDER_RAMP_UP_FACTOR + $BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR) * 100" | bc) seconds"
    echo "   - Order expires: $(echo "($BOUNDLESS_ORDER_RAMP_UP_FACTOR + $BOUNDLESS_ORDER_LOCK_TIMEOUT_FACTOR + $BOUNDLESS_ORDER_EXPIRY_FACTOR) * 100" | bc) seconds"
fi
echo ""

if [ "$KAILUA_FAST_FINALITY" = "true" ]; then
    echo "📝 Fast Finality Mode is ENABLED"
    echo "   Validator will generate validity proofs for canonical proposals"
    echo "   from block $KAILUA_FAST_FORWARD_START to $KAILUA_FAST_FORWARD_TARGET"
else
    echo "📝 Fault Proof Mode is ENABLED"
    echo "   Validator will only generate fault proofs when disputes occur"
    echo ""
    echo "   To enable Fast Finality mode, set:"
    echo "   export KAILUA_FAST_FINALITY=true"
fi
echo ""

# Wait for background processes
wait
