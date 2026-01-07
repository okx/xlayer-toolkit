#!/bin/bash
set -e

# ============================================================================
# RAILGUN Wallet Test Script (Docker)
# ============================================================================
# This script runs RAILGUN wallet tests in a Docker container
# Use this for quick testing after contracts are already deployed.
# ============================================================================

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 RAILGUN Wallet Test (Docker)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# Load Environment
# ============================================================================

if [ -f "$PWD_DIR/.env" ]; then
    echo "📝 Loading environment from .env..."
    source "$PWD_DIR/.env"
    echo "   ✓ Environment loaded"
else
    echo "❌ .env file not found"
    echo "   Please run ./init.sh first"
    exit 1
fi

# Set default image tag if not configured
RAILGUN_KOHAKUT_IMAGE_TAG="${RAILGUN_KOHAKUT_IMAGE_TAG:-xlayer/railgun-test:latest}"

# ============================================================================
# Pre-flight Checks
# ============================================================================

# Check if Docker image exists
echo ""
echo "🔍 Checking Docker image..."

if ! docker image inspect "$RAILGUN_KOHAKUT_IMAGE_TAG" >/dev/null 2>&1; then
    echo "❌ Docker image '$RAILGUN_KOHAKUT_IMAGE_TAG' not found"
    echo ""
    echo "Please build the image first:"
    echo "  cd $PWD_DIR"
    echo "  ./init.sh"
    echo ""
    echo "Or set SKIP_RAILGUN_TEST_BUILD=false in .env and run ./init.sh"
    exit 1
fi

echo "   ✓ Docker image found: $RAILGUN_KOHAKUT_IMAGE_TAG"

# Check required environment variables
echo ""
echo "📝 Checking required variables..."

REQUIRED_VARS=(
    "CHAIN_ID"
    "L2_RPC_URL"
    "RAILGUN_SMART_WALLET_ADDRESS"
    "RAILGUN_TEST_TOKEN_ADDRESS"
)

MISSING_VARS=()

for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        MISSING_VARS+=("$VAR")
    fi
done

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo "   ❌ Missing required environment variables:"
    for VAR in "${MISSING_VARS[@]}"; do
        echo "      - $VAR"
    done
    echo ""
    echo "   Please run ./7-run-railgain.sh first to:"
    echo "   1. Deploy RAILGUN contracts"
    echo "   2. Deploy test token"
    echo "   3. Setup environment variables"
    exit 1
fi

echo "   ✓ All required variables set"

# Check if L2 is running
echo ""
echo "🔍 Checking L2 connection..."

if ! curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L2_RPC_URL" > /dev/null 2>&1; then
    echo "   ❌ L2 RPC is not responding at: $L2_RPC_URL"
    echo "   ℹ️  Please start L2 services first: ./4-op-start-service.sh"
    exit 1
fi
echo "   ✓ L2 RPC is running: $L2_RPC_URL"

# Display configuration
echo ""
echo "📊 Test Configuration:"
echo "   Chain ID:      $CHAIN_ID"
echo "   RPC URL:       $L2_RPC_URL"
echo "   Contract:      $RAILGUN_SMART_WALLET_ADDRESS"
echo "   Token:         $RAILGUN_TEST_TOKEN_ADDRESS"
echo "   Deploy Block:  ${RAILGUN_DEPLOY_BLOCK:-0}"

# ============================================================================
# Run Docker Container
# ============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Running tests in Docker container..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm \
  -e CHAIN_ID="$CHAIN_ID" \
  -e RPC_URL="$L2_RPC_URL" \
  -e RAILGUN_ADDRESS="$RAILGUN_SMART_WALLET_ADDRESS" \
  -e RAILGUN_RELAY_ADAPT_ADDRESS="${RAILGUN_RELAY_ADAPT_ADDRESS}" \
  -e TOKEN_ADDRESS="$RAILGUN_TEST_TOKEN_ADDRESS" \
  -e RAILGUN_DEPLOY_BLOCK="${RAILGUN_DEPLOY_BLOCK:-0}" \
  --network host \
  "$RAILGUN_KOHAKUT_IMAGE_TAG" || {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ Test failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "💡 Troubleshooting:"
    echo "   • Check logs above for specific errors"
    echo "   • Verify L2 services are running: docker compose ps"
    echo "   • Verify contract is deployed: echo \$RAILGUN_SMART_WALLET_ADDRESS"
    echo "   • Check if token is deployed: echo \$TOKEN_ADDRESS"
    echo ""
    exit 1
  }

# ============================================================================
# Complete
# ============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 RAILGUN Wallet Test Completed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Test Summary:"
echo "   Image:      $RAILGUN_KOHAKUT_IMAGE_TAG"
echo "   Chain ID:   $CHAIN_ID"
echo "   RPC URL:    $L2_RPC_URL"
echo "   Contract:   $RAILGUN_SMART_WALLET_ADDRESS"
echo "   Token:      $RAILGUN_TEST_TOKEN_ADDRESS"
echo ""
echo "   ✅ All privacy transactions tested"
echo ""
