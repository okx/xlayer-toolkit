#!/bin/bash

set -e

# ============================================================================
# Kailua Setup Script (using local kailua-cli)
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
KAILUA_OUTPUT_BLOCK_SPAN=${KAILUA_OUTPUT_BLOCK_SPAN:-50}
KAILUA_COLLATERAL_AMOUNT=${KAILUA_COLLATERAL_AMOUNT:-100000000000000000}  # 0.1 ETH
KAILUA_CHALLENGE_TIMEOUT=${KAILUA_CHALLENGE_TIMEOUT:-86400}  # 24 hours
KAILUA_MAX_FAULT_PROVING_DELAY=${KAILUA_MAX_FAULT_PROVING_DELAY:-60}  # 1 min
KAILUA_GAME_TYPE=${KAILUA_GAME_TYPE:-1337}

echo "============================================"
echo "  Kailua Fast-Track Deployment (CLI)"
echo "============================================"
echo "Starting Block: $KAILUA_STARTING_BLOCK_NUMBER"
echo "Output Count: $KAILUA_PROPOSAL_OUTPUT_COUNT"
echo "Block Span: $KAILUA_OUTPUT_BLOCK_SPAN"
echo "Collateral: $KAILUA_COLLATERAL_AMOUNT wei"
echo "Challenge Timeout: $KAILUA_CHALLENGE_TIMEOUT seconds"
echo "Game Type: $KAILUA_GAME_TYPE"
echo ""
echo "RPC URLs:"
echo "  L1: $L1_RPC"
echo "  L2 Node: $L2_NODE_RPC"
echo "  L2 Geth: $L2_GETH_RPC"
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
export RISC0_DEV_MODE=1
export RUST_LOG="kailua=info,alloy=warn,hyper=warn,warn"
export NO_COLOR=1

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

L1_BEACON_RPC=${L1_BEACON_URL:-http://localhost:3500}

# Log files
PROPOSER_LOG="$SCRIPT_DIR/kailua/logs/kailua-proposer.log"
VALIDATOR_LOG="$SCRIPT_DIR/kailua/logs/kailua-validator.log"

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
echo "🚀 Starting Kailua validator..."
echo "   Log: $VALIDATOR_LOG"

RUST_LOG="warn,kailua=info,kailua_validator=info,kailua_proposer=info,kailua_prover=info,kailua_sync=info,oracle_server=off,oracle_client=off,host_backend=off,risc0_zkvm=off,risc0=off,alloy=warn,alloy_rpc_client=off,alloy_json_rpc=off,alloy_transport_http=off,hyper=off,hyper_util=off,reqwest=off,kona=warn,kona_derive=warn,kona_executor=warn,kona_mpt=warn,batch_validator=warn,hint_writer=off,hint_reader=off,frame_queue=warn,channel_reader=warn,pipeline=warn" \
kailua-cli validate \
  --op-node-url "$L2_NODE_RPC" \
  --op-geth-url "$L2_GETH_RPC" \
  --eth-rpc-url "$L1_RPC" \
  --beacon-rpc-url "$L1_BEACON_RPC" \
  --data-dir "$SCRIPT_DIR/kailua/validate-data" \
  --validator-key "$KAILUA_VALIDATOR_KEY" \
  --kailua-game-implementation "$KAILUA_GAME_IMPL" \
  --kailua-cli "$(which kailua-cli)" \
  --bypass-chain-registry \
  --max-fault-proving-delay "$KAILUA_MAX_FAULT_PROVING_DELAY" \
  > "$VALIDATOR_LOG" 2>&1 &

VALIDATOR_PID=$!
echo "   ✓ Validator started (PID: $VALIDATOR_PID)"

echo ""
echo "============================================"
echo "  Kailua Setup Complete"
echo "============================================"
echo "Proposer PID: $PROPOSER_PID"
echo "Validator PID: $VALIDATOR_PID"
echo ""
echo "To stop:"
echo "  kill $PROPOSER_PID $VALIDATOR_PID"
echo ""
echo "To view logs:"
echo "  tail -f $PROPOSER_LOG"
echo "  tail -f $VALIDATOR_LOG"

# Wait for background processes
wait