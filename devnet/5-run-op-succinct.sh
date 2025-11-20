#!/bin/bash
set -e

# Load environment variables
source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts

# Check if OP_SUCCINCT_ENABLE is set
if [ "$OP_SUCCINCT_ENABLE" != "true" ]; then
    echo "⏭️  OP_SUCCINCT_ENABLE is not set to 'true', skipping OP-Succinct setup..."
    exit 0
fi

if [ "$SEQ_TYPE" != "reth" && "$RPC_TYPE" != "geth" ]; then
    echo "❌ Error: OP-Succinct is only supported for reth as sequencer and geth as RPC"
    exit 1
fi

echo "✅ OP_SUCCINCT_ENABLE is enabled"

# Display OP-Succinct configuration
echo "📋 OP-Succinct Configuration:"
echo "   Mock Mode: ${OP_SUCCINCT_MOCK_MODE:-true}"
echo "   Fast finality mode: ${OP_SUCCINCT_FAST_FINALITY_MODE:-true}"
echo ""

echo "=== Step 1: Preparing OP-Succinct Environment ==="
echo ""

cp ./op-succinct/example.env.proposer ./op-succinct/.env.proposer
cp ./op-succinct/example.env.challenger ./op-succinct/.env.challenger

echo "✅ Environment files prepared"
echo ""

echo "=== Step 2: Configuration Check ==="
echo ""

echo "📋 Mode: ${OP_SUCCINCT_MODE:-validity}"
echo "📋 Mock mode: ${OP_SUCCINCT_MOCK_MODE:-true}"
echo "📋 Fast finality: ${OP_SUCCINCT_FAST_FINALITY_MODE:-true}"
echo ""

echo "=== Step 3: Deploying OP-Succinct Contracts ==="
echo ""

if [ "${OP_SUCCINCT_UPGRADE_FDG:-false}" = "true" ]; then
    echo "🔄 FDG Upgrade Mode: Will deploy and register OPSuccinctFaultDisputeGame"
else
    echo "📦 Standard Mode: Deploying AccessManager and SP1MockVerifier only"
fi
echo ""

# Deploy OP-Succinct contracts using dedicated script
bash "$SCRIPTS_DIR/deploy-op-succinct.sh"

# Load deployed addresses from .env.proposer
if [ -f "./op-succinct/.env.proposer" ]; then
    source ./op-succinct/.env.proposer
    echo "✅ Deployed contracts:"
    echo "   VERIFIER_ADDRESS: $VERIFIER_ADDRESS"
    echo "   ACCESS_MANAGER: $ACCESS_MANAGER"
    if [ "${OP_SUCCINCT_UPGRADE_FDG:-false}" = "true" ] && [ -n "$GAME_IMPLEMENTATION" ]; then
        echo "   GAME_IMPLEMENTATION: $GAME_IMPLEMENTATION"
    fi
fi

echo ""

echo "=== Step 4: Starting OP-Succinct Services ==="
echo ""

# Check required environment variables
if [ -z "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" ]; then
    echo "❌ Error: OP_SUCCINCT_PROPOSER_IMAGE_TAG is not set"
    exit 1
fi

if [ -z "$DOCKER_NETWORK" ]; then
    echo "❌ Error: DOCKER_NETWORK is not set"
    exit 1
fi

# Start Proposer
echo "🚀 Starting OP-Succinct Proposer..."

# Remove existing container if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^op-succinct-proposer$"; then
    echo "Removing existing proposer container..."
    docker rm -f op-succinct-proposer > /dev/null 2>&1
fi

docker run -d \
    --name op-succinct-proposer \
    --network "$DOCKER_NETWORK" \
    -v "$PWD_DIR/op-succinct/.env.proposer:/app/.env:ro" \
    "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" \
    cargo run --bin proposer --release -- --env-file /app/.env

if [ $? -eq 0 ]; then
    echo "✅ Proposer started"
else
    echo "❌ Failed to start proposer"
    exit 1
fi

# Start Challenger (only if fast finality mode is disabled)
if [ "${OP_SUCCINCT_FAST_FINALITY_MODE:-true}" != "true" ]; then
    if [ -z "$OP_SUCCINCT_CHALLENGER_IMAGE_TAG" ]; then
        echo "❌ Error: OP_SUCCINCT_CHALLENGER_IMAGE_TAG is not set"
        exit 1
    fi
    
    echo "🚀 Starting OP-Succinct Challenger..."
    
    # Remove existing container if it exists
    if docker ps -a --format '{{.Names}}' | grep -q "^op-succinct-challenger$"; then
        echo "Removing existing challenger container..."
        docker rm -f op-succinct-challenger > /dev/null 2>&1
    fi
    
    docker run -d \
        --name op-succinct-challenger \
        --network "$DOCKER_NETWORK" \
        -v "$PWD_DIR/op-succinct/.env.challenger:/app/.env.challenger:ro" \
        "$OP_SUCCINCT_CHALLENGER_IMAGE_TAG" \
        cargo run --bin challenger -- --env-file /app/.env.challenger
    
    if [ $? -eq 0 ]; then
        echo "✅ Challenger started"
    else
        echo "❌ Failed to start challenger"
        exit 1
    fi
else
    echo "⏭️  Fast finality mode enabled, skipping challenger"
fi

echo ""

echo "=== Step 5: Verifying Services ==="
echo ""

# Check proposer container
if docker ps | grep -q "op-succinct-proposer"; then
    echo "✅ Proposer is running"
else
    echo "⚠️  Proposer container not found"
fi

# Check challenger container if applicable
if [ "${OP_SUCCINCT_FAST_FINALITY_MODE:-true}" != "true" ]; then
    if docker ps | grep -q "op-succinct-challenger"; then
        echo "✅ Challenger is running"
    else
        echo "⚠️  Challenger container not found"
    fi
fi

echo ""
echo "✅ OP-Succinct setup completed!"

