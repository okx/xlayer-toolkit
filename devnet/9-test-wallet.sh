#!/bin/bash
set -e

# ============================================================================
# RAILGUN Test Wallet Script (Using Source Code)
# ============================================================================
# This script runs RAILGUN wallet tests using source code directly
# No Docker required - runs directly with Node.js
# ============================================================================

# Load environment variables
source .env

if [ "$RAILGUN_ENABLE" != "true" ]; then
  echo "⏭️  Skipping RAILGUN test wallet (RAILGUN_ENABLE=$RAILGUN_ENABLE)"
  exit 0
fi

echo "🚀 Starting RAILGUN wallet test..."

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# Step 0: Check Node.js Version
# ============================================================================
echo ""
echo "🔍 Checking Node.js version..."

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)

if [ "$NODE_VERSION" -gt 19 ]; then
    echo "   ⚠️  Node.js version v$NODE_VERSION detected"
    echo "   ℹ️  RAILGUN requires Node.js v14-v19"
    echo "   ℹ️  Please switch to a compatible version (e.g., n 18 or nvm use 18)"
    exit 1
fi

echo "   ✅ Node.js v$NODE_VERSION (compatible)"

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================
echo ""
echo "📝 Step 1: Verifying prerequisites..."

# Check if contract is deployed
if [ -z "$RAILGUN_SMART_WALLET_ADDRESS" ] || [ "$RAILGUN_SMART_WALLET_ADDRESS" = "" ]; then
    echo "   ❌ RAILGUN_SMART_WALLET_ADDRESS is not set"
    echo "   ℹ️  Please run './7-deploy-railgun.sh' first to deploy contracts"
    exit 1
fi
echo "   ✓ Contract deployed at: $RAILGUN_SMART_WALLET_ADDRESS"

# Check if test wallet directory is configured
if [ -z "$RAILGUN_TEST_WALLET_DIR" ]; then
    echo "   ❌ RAILGUN_TEST_WALLET_DIR is not set in .env"
    echo "   ℹ️  Example: RAILGUN_TEST_WALLET_DIR=/Users/oker/workspace/xlayer/pt/test-wallet"
    exit 1
fi

if [ ! -d "$RAILGUN_TEST_WALLET_DIR" ]; then
    echo "   ❌ Test wallet directory not found: $RAILGUN_TEST_WALLET_DIR"
    exit 1
fi
echo "   ✓ Test wallet directory: $RAILGUN_TEST_WALLET_DIR"

# Check if L2 is running
if ! curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L2_RPC_URL" > /dev/null 2>&1; then
    echo "   ❌ L2 RPC is not responding at: $L2_RPC_URL"
    echo "   ℹ️  Please start L2 services first"
    exit 1
fi
echo "   ✓ L2 RPC is running: $L2_RPC_URL"

# Check if Subgraph is deployed (optional but recommended)
SUBGRAPH_URL="http://localhost:8000/subgraphs/name/$RAILGUN_SUBGRAPH_NAME"
if curl -f -s "$SUBGRAPH_URL" >/dev/null 2>&1; then
    echo "   ✓ Subgraph is available: $SUBGRAPH_URL"
    SUBGRAPH_AVAILABLE=true
else
    echo "   ⚠️  Subgraph is not available (optional, but recommended)"
    echo "   ℹ️  Run './8-deploy-subgraph.sh' for faster wallet sync"
    SUBGRAPH_AVAILABLE=false
fi

# Check if dependencies are installed
if [ ! -d "$RAILGUN_TEST_WALLET_DIR/node_modules" ]; then
    echo "   ⚠️  node_modules not found, installing dependencies..."
    
    # Use yarn if yarn.lock exists, otherwise use npm
    if [ -f "$RAILGUN_TEST_WALLET_DIR/yarn.lock" ]; then
        echo "   📦 Using yarn (detected yarn.lock)..."
        cd "$RAILGUN_TEST_WALLET_DIR"
        yarn install --frozen-lockfile --network-timeout 300000
        cd "$PWD_DIR"
    elif [ -f "$RAILGUN_TEST_WALLET_DIR/package-lock.json" ]; then
        echo "   📦 Using npm (detected package-lock.json)..."
        cd "$RAILGUN_TEST_WALLET_DIR"
        npm ci --prefer-offline
        cd "$PWD_DIR"
    else
        echo "   📦 Using npm (no lock file found)..."
        cd "$RAILGUN_TEST_WALLET_DIR"
        npm install
        cd "$PWD_DIR"
    fi
fi
echo "   ✓ Dependencies installed"

# ============================================================================
# Step 2: Run Test Wallet
# ============================================================================
echo ""
echo "🧪 Step 2: Running RAILGUN wallet test..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$RAILGUN_TEST_WALLET_DIR"

# Export environment variables for the test script
export CHAIN_ID="$CHAIN_ID"
export CHAIN_NAME="XLayer_DevNet"
export RPC_URL="$L2_RPC_URL"
export RAILGUN_ADDRESS="$RAILGUN_SMART_WALLET_ADDRESS"
export EOA_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"

if [ "$SUBGRAPH_AVAILABLE" = true ]; then
    export SUBGRAPH_URL="$SUBGRAPH_URL"
fi

# Check if test script exists
if [ -f "test-wallet.ts" ]; then
    TEST_SCRIPT="test-wallet.ts"
elif [ -f "test.ts" ]; then
    TEST_SCRIPT="test.ts"
elif [ -f "index.ts" ]; then
    TEST_SCRIPT="index.ts"
else
    echo "❌ No test script found (test-wallet.ts, test.ts, or index.ts)"
    cd "$PWD_DIR"
    exit 1
fi

# Run the test
npx tsx "$TEST_SCRIPT" || {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "❌ Test wallet failed"
    echo ""
    echo "💡 Common issues:"
    echo "   1. Insufficient balance (check deployer account has ETH)"
    echo "   2. Contract address mismatch"
    echo "   3. RPC connection issues"
    echo "   4. Missing USDC or test tokens"
    echo ""
    cd "$PWD_DIR"
    exit 1
}

cd "$PWD_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# Test Complete
# ============================================================================
echo "🎉 RAILGUN wallet test completed successfully!"
echo ""
echo "📊 Test Details:"
echo "   Chain ID:        $CHAIN_ID"
echo "   RPC URL:         $L2_RPC_URL"
echo "   Contract:        $RAILGUN_SMART_WALLET_ADDRESS"
if [ "$SUBGRAPH_AVAILABLE" = true ]; then
    echo "   Subgraph:        $SUBGRAPH_URL"
fi
echo ""
echo "💡 Next Steps:"
echo "   • Review test output above"
echo "   • Check wallet balance and transactions"
echo "   • Query Subgraph for indexed events"
echo ""
echo "📖 Source code: $RAILGUN_TEST_WALLET_DIR"
echo ""

