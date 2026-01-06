#!/bin/bash
set -e

# ============================================================================
# RAILGUN Test Wallet Script (Docker Only)
# ============================================================================
# This script runs RAILGUN wallet tests in Docker container with Node.js v16
# ============================================================================

# Load environment variables
source .env

if [ "$RAILGUN_ENABLE" != "true" ]; then
  echo "⏭️  Skipping RAILGUN test wallet (RAILGUN_ENABLE=$RAILGUN_ENABLE)"
  exit 0
fi

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Starting RAILGUN wallet test (Docker mode)..."
echo ""
echo "📦 Using Docker with Node.js v16"

# ============================================================================
# Build and Run Docker Container
# ============================================================================
echo ""
echo "🔨 Step 1: Building Docker image..."

cd "$PWD_DIR"
docker compose build railgun-test-wallet || {
    echo "❌ Failed to build Docker image"
    exit 1
}
echo "   ✓ Docker image built successfully"

echo ""
echo "🧪 Step 2: Running RAILGUN wallet test in container..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run container with environment variables from .env
docker compose run --rm railgun-test-wallet || {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "❌ Test wallet failed in Docker container"
    echo ""
    echo "💡 Troubleshooting:"
    echo "   • Check logs above for specific errors"
    echo "   • Verify L2 services are running: docker compose ps"
    echo "   • Verify contract is deployed: echo \$RAILGUN_SMART_WALLET_ADDRESS"
    echo "   • Check RAILGUN engine initialization errors"
    echo ""
    exit 1
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎉 RAILGUN wallet test completed successfully!"
echo ""
echo "📊 Test Details:"
echo "   Mode:            Docker (Node.js v16)"
echo "   Chain ID:        $CHAIN_ID"
echo "   RPC URL:         $L2_RPC_URL"
echo "   Contract:        $RAILGUN_SMART_WALLET_ADDRESS"
echo ""
echo "💡 Next Steps:"
echo "   • Review test output above"
echo "   • Query Subgraph for indexed events"
echo ""
