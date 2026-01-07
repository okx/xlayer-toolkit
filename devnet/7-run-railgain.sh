#!/bin/bash
set -e

# ============================================================================
# RAILGUN Complete Deploy and Test Script (Kohaku SDK)
# ============================================================================
# This script combines:
#   - Contract deployment
#   - ERC20 token deployment
#   - Kohaku SDK wallet testing
# Uses the simplified Kohaku SDK for faster development
# ============================================================================

# Load environment variables
source .env

# ============================================================================
# Helper Functions
# ============================================================================
sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ============================================================================
# Pre-flight Checks
# ============================================================================
if [ "$RAILGUN_ENABLE" != "true" ]; then
  echo "⏭️  Skipping RAILGUN (RAILGUN_ENABLE=$RAILGUN_ENABLE)"
  exit 0
fi

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAILGUN_DIR="$PWD_DIR/railgun"
RAILGUN_TEST_DIR="$PWD_DIR/railgun-test"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 RAILGUN Complete Test Flow (Kohaku SDK)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This script will:"
echo "  1. Deploy fresh RAILGUN contracts"
echo "  2. Deploy test ERC20 token"
echo "  3. Setup Kohaku SDK"
echo "  4. Run wallet tests"
echo ""
echo "Using Kohaku SDK for simplified integration."
echo ""

# ============================================================================
# Step 0: Check Node.js Version
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Checking Node.js version"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)

# Kohaku SDK is more flexible with Node.js versions
# We recommend v16+ but v14+ should work
if [ "$NODE_VERSION" -lt 14 ]; then
    echo "   ⚠️  Node.js version v$NODE_VERSION detected"
    echo "   ℹ️  Kohaku SDK requires Node.js v14+"
    echo ""
    echo "   Please upgrade Node.js:"
    echo ""
    
    if command -v n &> /dev/null; then
        echo "   Using 'n':"
        echo "   $ n 18"
    elif command -v nvm &> /dev/null || [ -f "$HOME/.nvm/nvm.sh" ]; then
        echo "   Using 'nvm':"
        echo "   $ nvm install 18"
        echo "   $ nvm use 18"
    else
        echo "   Install Node.js 18+:"
        echo "   $ npm install -g n"
        echo "   $ n 18"
    fi
    echo ""
    exit 1
fi

echo "   ✅ Node.js v$NODE_VERSION (compatible with Kohaku SDK)"

# ============================================================================
# Step 1: Deploy RAILGUN Contracts
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📜 Step 1/3: Deploying RAILGUN Contracts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verify prerequisites
echo "📝 Verifying prerequisites..."

if [ -z "$RAILGUN_CONTRACT_DIR" ]; then
    echo "   ❌ RAILGUN_CONTRACT_DIR is not set in .env"
    echo "   ℹ️  Example: RAILGUN_CONTRACT_DIR=/Users/oker/workspace/xlayer/pt/contract"
    exit 1
fi

if [ ! -d "$RAILGUN_CONTRACT_DIR" ]; then
    echo "   ❌ Contract directory not found: $RAILGUN_CONTRACT_DIR"
    exit 1
fi
echo "   ✓ Contract directory: $RAILGUN_CONTRACT_DIR"

# Check if L2 is running
if ! curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L2_RPC_URL" > /dev/null 2>&1; then
    echo "   ❌ L2 RPC is not responding at: $L2_RPC_URL"
    echo "   ℹ️  Please start L2 services first: ./4-op-start-service.sh"
    exit 1
fi
echo "   ✓ L2 RPC is running: $L2_RPC_URL"

# Check if node_modules exists
if [ ! -d "$RAILGUN_CONTRACT_DIR/node_modules" ]; then
    echo "   ⚠️  node_modules not found, installing dependencies..."
    
    if [ -f "$RAILGUN_CONTRACT_DIR/yarn.lock" ]; then
        echo "   📦 Using yarn..."
        cd "$RAILGUN_CONTRACT_DIR"
        yarn install --frozen-lockfile --network-timeout 300000
        cd "$PWD_DIR"
    else
        echo "   📦 Using npm..."
        cd "$RAILGUN_CONTRACT_DIR"
        npm install
        cd "$PWD_DIR"
    fi
fi
echo "   ✓ Dependencies installed"

# Configure Hardhat Network
echo ""
echo "📝 Configuring Hardhat for devnet..."

HARDHAT_CONFIG_FILE="$RAILGUN_CONTRACT_DIR/hardhat.config.ts"

if [ ! -f "$HARDHAT_CONFIG_FILE" ]; then
    echo "   ❌ hardhat.config.ts not found in $RAILGUN_CONTRACT_DIR"
    exit 1
fi

if grep -q "xlayer-devnet" "$HARDHAT_CONFIG_FILE"; then
    echo "   ✓ xlayer-devnet network already configured"
else
    echo "   ℹ️  Adding xlayer-devnet network to hardhat.config.ts..."
    
    if [ ! -f "$HARDHAT_CONFIG_FILE.devnet.backup" ]; then
        cp "$HARDHAT_CONFIG_FILE" "$HARDHAT_CONFIG_FILE.devnet.backup"
        echo "   ✓ Backed up original config"
    fi
    
    cd "$RAILGUN_CONTRACT_DIR"
    
    sed -i.tmp '/etherscan: {/,/},/ {
        /},/ a\
  networks: {\
    "xlayer-devnet": {\
      url: process.env.RPC_URL || "http://localhost:8123",\
      chainId: parseInt(process.env.CHAIN_ID || "195"),\
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],\
      gasPrice: 1000000000,\
    },\
  },
    }' "$HARDHAT_CONFIG_FILE"
    
    rm -f "$HARDHAT_CONFIG_FILE.tmp"
    cd "$PWD_DIR"
    
    echo "   ✅ Added xlayer-devnet network to hardhat.config.ts"
fi

# Deploy contracts
echo ""
echo "📜 Deploying RAILGUN smart contracts to L2..."

mkdir -p "$RAILGUN_DIR/deployments"

# Deploy contracts
cd "$RAILGUN_CONTRACT_DIR"

echo "   🚀 Deploying contracts using Hardhat..."
echo "   ℹ️  Network: xlayer-devnet"
echo "   ℹ️  RPC: $L2_RPC_URL"
echo "   ℹ️  Chain ID: $CHAIN_ID"
echo ""

export RPC_URL="$L2_RPC_URL"
export DEPLOYER_PRIVATE_KEY="$OP_PROPOSER_PRIVATE_KEY"

echo "   📝 Deploying contracts (this may take a few minutes)..."
echo ""

TEMP_DEPLOY_LOG="/tmp/railgun-deploy-$$.log"
npx hardhat deploy:test --network xlayer-devnet 2>&1 | tee "$TEMP_DEPLOY_LOG"
DEPLOY_STATUS=${PIPESTATUS[0]}

DEPLOY_OUTPUT=$(cat "$TEMP_DEPLOY_LOG")

echo ""

if [ $DEPLOY_STATUS -ne 0 ]; then
    echo "   ❌ Contract deployment failed"
    rm -f "$TEMP_DEPLOY_LOG" 2>/dev/null
    cd "$PWD_DIR"
    exit 1
fi

cd "$PWD_DIR"

echo "   ✅ Contracts deployed successfully"

# Extract contract addresses
echo ""
echo "🔍 Extracting contract addresses..."

PROXY_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -A 20 "DEPLOY CONFIG:" | grep "proxy:" | sed -n "s/.*proxy: '\([^']*\)'.*/\1/p" | head -1)
RELAY_ADAPT_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -A 20 "DEPLOY CONFIG:" | grep "relayAdapt:" | sed -n "s/.*relayAdapt: '\([^']*\)'.*/\1/p" | head -1)
POSEIDON_T4_ADDR=$(echo "$DEPLOY_OUTPUT" | grep -A 20 "DEPLOY CONFIG:" | grep "poseidonT4:" | sed -n "s/.*poseidonT4: '\([^']*\)'.*/\1/p" | head -1)

if [ -n "$PROXY_ADDR" ] && [ "$PROXY_ADDR" != "null" ]; then
    echo "   ✅ Found RailgunSmartWallet (proxy): $PROXY_ADDR"
    export RAILGUN_SMART_WALLET_ADDRESS="$PROXY_ADDR"
    sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" .env
fi

if [ -n "$RELAY_ADAPT_ADDR" ] && [ "$RELAY_ADAPT_ADDR" != "null" ]; then
    echo "   ✅ Found RelayAdapt: $RELAY_ADAPT_ADDR"
    export RAILGUN_RELAY_ADAPT_ADDRESS="$RELAY_ADAPT_ADDR"
    sed_inplace "s|^RAILGUN_RELAY_ADAPT_ADDRESS=.*|RAILGUN_RELAY_ADAPT_ADDRESS=$RELAY_ADAPT_ADDR|" .env
fi

if [ -n "$POSEIDON_T4_ADDR" ] && [ "$POSEIDON_T4_ADDR" != "null" ]; then
    echo "   ✅ Found PoseidonT4: $POSEIDON_T4_ADDR"
    export RAILGUN_POSEIDONT4_ADDRESS="$POSEIDON_T4_ADDR"
    sed_inplace "s|^RAILGUN_POSEIDONT4_ADDRESS=.*|RAILGUN_POSEIDONT4_ADDRESS=$POSEIDON_T4_ADDR|" .env
fi

# Verify contract
echo ""
echo "🔍 Verifying contract deployment..."

VERIFICATION_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$RAILGUN_SMART_WALLET_ADDRESS\",\"latest\"],\"id\":1}" \
    "$L2_RPC_URL" 2>/dev/null)

if echo "$VERIFICATION_RESPONSE" | grep -q '"result":"0x"'; then
    echo "   ❌ Contract not found at address: $RAILGUN_SMART_WALLET_ADDRESS"
    exit 1
else
    echo "   ✅ Contract verified on L2"
fi

# Get and save deployment block height
echo ""
echo "🔍 Getting deployment block height..."

BLOCK_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L2_RPC_URL" 2>/dev/null)

DEPLOY_BLOCK=$(echo "$BLOCK_RESPONSE" | grep -o '"result":"0x[^"]*"' | cut -d'"' -f4)
DEPLOY_BLOCK_DEC=$((16#${DEPLOY_BLOCK#0x}))

if [ -n "$DEPLOY_BLOCK_DEC" ]; then
    echo "   ✅ Deployment block: $DEPLOY_BLOCK_DEC"
    export RAILGUN_DEPLOY_BLOCK="$DEPLOY_BLOCK_DEC"
    
    # Save to .env
    if grep -q "^RAILGUN_DEPLOY_BLOCK=" .env; then
        sed_inplace "s|^RAILGUN_DEPLOY_BLOCK=.*|RAILGUN_DEPLOY_BLOCK=$RAILGUN_DEPLOY_BLOCK|" .env
    else
        echo "RAILGUN_DEPLOY_BLOCK=$RAILGUN_DEPLOY_BLOCK" >> .env
    fi
else
    echo "   ⚠️  Could not determine deployment block, using 0"
    export RAILGUN_DEPLOY_BLOCK="0"
fi

rm -f "$TEMP_DEPLOY_LOG" 2>/dev/null

echo ""
echo "✅ Contract deployment completed"

# ============================================================================
# Step 2: Deploy Test ERC20 Token
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🪙 Step 2/3: Deploying Test ERC20 Token"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

./scripts/deploy-test-token.sh || {
    echo "❌ Failed to deploy test token"
    exit 1
}

# ============================================================================
# Step 3: Run Wallet Tests
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Step 3/3: Run Wallet Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "🚀 Calling wallet test script..."
echo ""

./scripts/run-railgun-wallet.sh || {
    echo ""
    echo "❌ Wallet test failed"
    echo ""
    echo "💡 Troubleshooting:"
    echo "   • Check error messages above"
    echo "   • Re-run tests only: ./scripts/run-railgun-wallet.sh"
    echo "   • Full redeploy: ./7-run-railgain.sh"
    echo ""
    exit 1
}

# ============================================================================
# Complete
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Complete Test Flow Finished Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Summary:"
echo "   SDK:             Kohaku (kohaku-eth/railgun)"
echo "   Chain ID:        $CHAIN_ID"
echo "   RPC URL:         $L2_RPC_URL"
echo "   Contract:        $RAILGUN_SMART_WALLET_ADDRESS"
echo "   RelayAdapt:      $RAILGUN_RELAY_ADAPT_ADDRESS"
echo "   Test Token:      $TOKEN_ADDRESS"
echo ""
echo "   ✅ Fresh contracts deployed"
echo "   ✅ Test token deployed"
echo "   ✅ Kohaku SDK initialized"
echo "   ✅ All privacy transactions tested"