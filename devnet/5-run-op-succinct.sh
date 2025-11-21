#!/bin/bash
set -e

# ============================================================================
# OP-Succinct Setup Script
# ============================================================================

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
PROJECT_DIR=$PWD_DIR

# Source deployment functions
source "$SCRIPTS_DIR/deploy-op-succinct.sh"

# ============================================================================
# Pre-flight Checks
# ============================================================================

# Check if OP_SUCCINCT_ENABLE is set
if [ "$OP_SUCCINCT_ENABLE" != "true" ]; then
    echo "⏭️  OP-Succinct is disabled, skipping..."
    exit 0
fi

# Validate sequencer and RPC configuration
if [ "$SEQ_TYPE" != "reth" ] || [ "$RPC_TYPE" != "geth" ]; then
    echo "❌ Error: OP-Succinct requires reth sequencer and geth RPC"
    exit 1
fi

# Validate Docker images
if [ -z "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" ] || [ -z "$OP_SUCCINCT_CHALLENGER_IMAGE_TAG" ]; then
    echo "❌ Error: Missing OP-Succinct Docker image tags"
    exit 1
fi

# Check if Docker images exist
if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${OP_SUCCINCT_PROPOSER_IMAGE_TAG}$"; then
    echo "❌ Error: Docker image $OP_SUCCINCT_PROPOSER_IMAGE_TAG not found"
    echo "   Please run: ./init.sh"
    exit 1
fi

if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${OP_SUCCINCT_CHALLENGER_IMAGE_TAG}$"; then
    echo "❌ Error: Docker image $OP_SUCCINCT_CHALLENGER_IMAGE_TAG not found"
    echo "   Please run: ./init.sh"
    exit 1
fi

echo "✅ Docker images verified"

echo ""
echo "🚀 OP-Succinct Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Configuration:"
echo "   • Mock Mode: ${OP_SUCCINCT_MOCK_MODE:-true}"
echo "   • Fast Finality: ${OP_SUCCINCT_FAST_FINALITY_MODE:-true}"
echo ""

# ============================================================================
# Step 1: Prepare Environment
# ============================================================================

echo "📁 Preparing environment files..."
cp ./op-succinct/example.env.proposer ./op-succinct/.env.proposer
cp ./op-succinct/example.env.challenger ./op-succinct/.env.challenger

# Set NETWORK_PRIVATE_KEY from main .env if available
if [ -n "$OP_SUCCINCT_NETWORK_PRIVATE_KEY" ]; then
    # Ensure 0x prefix is present
    NETWORK_KEY="$OP_SUCCINCT_NETWORK_PRIVATE_KEY"
    if [[ ! "$NETWORK_KEY" =~ ^0x ]]; then
        NETWORK_KEY="0x$NETWORK_KEY"
    fi
    sed -i "s|^NETWORK_PRIVATE_KEY=.*|NETWORK_PRIVATE_KEY=$NETWORK_KEY|" ./op-succinct/.env.proposer
fi

echo "   ✓ Environment files prepared"
echo ""

# ============================================================================
# Step 2: Deploy Contracts
# ============================================================================

# Deploy OP-Succinct contracts
deploy_op_succinct_contracts

# Setup FDG (deploy and register)
setup_op_succinct_fdg

# Show deployed addresses
echo ""
echo "✅ Contract Deployment Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📍 Deployed Addresses:"
echo "   • Verifier:     $VERIFIER_ADDRESS"
echo "   • AccessManager: $ACCESS_MANAGER_ADDRESS"
echo "   • Game:         $GAME_IMPLEMENTATION"
echo ""

# ============================================================================
# Step 3: Start Services
# ============================================================================

echo "🚀 Starting services..."

# Start proposer
docker compose up -d op-succinct-proposer
echo "   ✓ Proposer started"

# Start challenger if fast finality mode is disabled
if [ "${OP_SUCCINCT_FAST_FINALITY_MODE:-true}" != "true" ]; then
    docker compose up -d op-succinct-challenger
    echo "   ✓ Challenger started"
else
    echo "   ⏭  Challenger skipped (fast finality mode)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ OP-Succinct Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

