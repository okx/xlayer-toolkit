#!/bin/bash
set -e

# ============================================================================
# RAILGUN Wallet Test Script (Kohaku SDK)
# ============================================================================
# This script runs RAILGUN wallet tests without deploying contracts.
# Use this for quick testing after contracts are already deployed.
# ============================================================================

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
RAILGUN_TEST_DIR="$PWD_DIR/railgun-test"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 RAILGUN Wallet Test (Kohaku SDK)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ============================================================================
# Pre-flight Checks
# ============================================================================

# Load environment variables
if [ -f "$PWD_DIR/.env" ]; then
    echo "📝 Loading environment from .env..."
    source "$PWD_DIR/.env"
    echo "   ✓ Environment loaded"
else
    echo "❌ .env file not found"
    echo "   Please run ./7-run-railgain.sh first to deploy contracts"
    exit 1
fi

# Debug: Show what was loaded
echo ""
echo "🔍 Environment variables:"
echo "   CHAIN_ID=${CHAIN_ID:-<not set>}"
echo "   L2_RPC_URL=${L2_RPC_URL:-<not set>}"
echo "   RAILGUN_SMART_WALLET_ADDRESS=${RAILGUN_SMART_WALLET_ADDRESS:-<not set>}"
echo "   RAILGUN_TEST_TOKEN_ADDRESS=${RAILGUN_TEST_TOKEN_ADDRESS:-<not set>}"
echo "   RAILGUN_DEPLOY_BLOCK=${RAILGUN_DEPLOY_BLOCK:-<not set>}"

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

# Verify contracts are deployed
echo ""
echo "🔍 Verifying contracts..."

VERIFICATION_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$RAILGUN_SMART_WALLET_ADDRESS\",\"latest\"],\"id\":1}" \
    "$L2_RPC_URL" 2>/dev/null)

if echo "$VERIFICATION_RESPONSE" | grep -q '"result":"0x"'; then
    echo "   ❌ RAILGUN contract not found at: $RAILGUN_SMART_WALLET_ADDRESS"
    echo "   ℹ️  Please run ./7-run-railgain.sh to deploy contracts"
    exit 1
fi

echo "   ✓ RAILGUN contract: $RAILGUN_SMART_WALLET_ADDRESS"
echo "   ✓ Test token: $RAILGUN_TEST_TOKEN_ADDRESS"

# ============================================================================
# Setup Kohaku SDK
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Setting up Kohaku SDK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$RAILGUN_TEST_DIR"

# Check if Kohaku is cloned
if [ ! -d "kohaku" ]; then
    echo "📦 Cloning Kohaku SDK..."
    git clone https://github.com/ethereum/kohaku.git
    echo "   ✓ Kohaku cloned"
else
    echo "   ✓ Kohaku already cloned"
fi

# Build Kohaku
echo ""
echo "🔨 Building Kohaku SDK..."

cd kohaku

if [ ! -d "node_modules" ]; then
    echo "   📦 Installing Kohaku dependencies..."
    npx -y pnpm install
fi

echo "   🔧 Building Kohaku packages..."
echo "   ℹ️  Note: docs package may fail on Node.js < 22 (this is OK)"
echo ""

# Build all packages, capture output but don't fail
BUILD_OUTPUT=$(npx -y pnpm -r build 2>&1) || true
BUILD_EXIT_CODE=$?

# Check if railgun package was built successfully
echo ""
echo "   🔍 Verifying railgun package build..."

if [ -d "packages/railgun/dist" ] && [ -f "packages/railgun/dist/index.d.ts" ]; then
    echo "   ✅ Railgun package built successfully"
    
    # Check if docs failed (expected on Node.js < 22)
    if echo "$BUILD_OUTPUT" | grep -q "docs.*Failed"; then
        echo "   ℹ️  Docs package build failed (not required for tests)"
    fi
else
    echo "   ❌ Railgun package build failed"
    echo ""
    echo "   Build output:"
    echo "$BUILD_OUTPUT" | tail -20
    echo ""
    cd "$RAILGUN_TEST_DIR"
    exit 1
fi

cd "$RAILGUN_TEST_DIR"
echo "   ✓ Kohaku railgun package built successfully"

# ============================================================================
# Install Test Dependencies
# ============================================================================
echo ""
echo "📦 Installing test dependencies..."

if [ ! -d "node_modules" ]; then
    npx -y pnpm install
fi
echo "   ✓ Test dependencies installed"

# ============================================================================
# Check Circuit Artifacts
# ============================================================================
echo ""
echo "🔍 Checking Circuit Artifacts..."

ARTIFACTS_PATH="kohaku/node_modules/@railgun-community/circuit-artifacts"

if [ ! -d "$ARTIFACTS_PATH" ]; then
    echo "   ⚠️  Circuit artifacts not pre-installed"
    echo "   ℹ️  They will be downloaded automatically on first use (~500MB)"
    echo "   ℹ️  This may take a few minutes for Transfer/Unshield operations"
    echo ""
else
    echo "   ✓ Circuit artifacts found"
fi

# ============================================================================
# Prepare Environment and Run Tests
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Running RAILGUN Wallet Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Prepare environment variables
echo "📝 Setting environment variables..."

export CHAIN_ID="$CHAIN_ID"
export CHAIN_NAME="XLayerDevNet"
export RPC_URL="$L2_RPC_URL"
export RAILGUN_ADDRESS="$RAILGUN_SMART_WALLET_ADDRESS"
export RAILGUN_RELAY_ADAPT_ADDRESS="$RAILGUN_RELAY_ADAPT_ADDRESS"
export POSEIDON_ADDRESS="$RAILGUN_POSEIDONT4_ADDRESS"
export TOKEN_ADDRESS="$RAILGUN_TEST_TOKEN_ADDRESS"
export RAILGUN_DEPLOY_BLOCK="${RAILGUN_DEPLOY_BLOCK:-0}"

echo "   ✓ Environment variables set:"
echo "      CHAIN_ID=$CHAIN_ID"
echo "      RPC_URL=$RPC_URL"
echo "      RAILGUN_ADDRESS=$RAILGUN_ADDRESS"
echo "      TOKEN_ADDRESS=$TOKEN_ADDRESS"
echo "      DEPLOY_BLOCK=$RAILGUN_DEPLOY_BLOCK"

# Run Kohaku test
echo ""
echo "🚀 Starting Kohaku SDK test..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

npx -y pnpm test:kohaku || {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "❌ Kohaku test failed"
    echo ""
    echo "💡 Troubleshooting:"
    echo "   • Check logs above for specific errors"
    echo "   • Verify L2 services are running: docker compose ps"
    echo "   • Verify contract is deployed: echo \$RAILGUN_SMART_WALLET_ADDRESS"
    echo "   • Check if token is deployed: echo \$TOKEN_ADDRESS"
    echo "   • Review test output for balance sync issues"
    echo ""
    echo "📚 Documentation:"
    echo "   • Quick Start: $RAILGUN_TEST_DIR/QUICK_START.md"
    echo "   • README: $RAILGUN_TEST_DIR/README_KOHAKU.md"
    echo ""
    exit 1
}

# ============================================================================
# Complete
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 RAILGUN Wallet Test Completed Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Test Summary:"
echo "   SDK:        Kohaku (kohaku-eth/railgun)"
echo "   Chain ID:   $CHAIN_ID"
echo "   RPC URL:    $L2_RPC_URL"
echo "   Contract:   $RAILGUN_ADDRESS"
echo "   Token:      $TOKEN_ADDRESS"
echo ""
echo "   ✅ All privacy transactions tested"
