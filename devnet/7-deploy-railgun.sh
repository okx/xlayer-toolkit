#!/bin/bash
set -e

# ============================================================================
# RAILGUN Contract Deployment Script (Using Source Code)
# ============================================================================
# This script deploys RAILGUN smart contracts using Hardhat directly
# No Docker image required - uses source code from RAILGUN_CONTRACT_DIR
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

if [ "$RAILGUN_ENABLE" != "true" ]; then
  echo "⏭️  Skipping RAILGUN (RAILGUN_ENABLE=$RAILGUN_ENABLE)"
  exit 0
fi

echo "🚀 Starting RAILGUN Contract deployment..."

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAILGUN_DIR="$PWD_DIR/railgun"

# ============================================================================
# Step 0: Check Node.js Version
# ============================================================================
echo ""
echo "🔍 Checking Node.js version..."

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
REQUIRED_NODE_VERSIONS="14, 16, 17, 18, 19"

if [ "$NODE_VERSION" -gt 19 ]; then
    echo "   ⚠️  Node.js version v$NODE_VERSION detected"
    echo "   ℹ️  RAILGUN requires Node.js v14-v19"
    echo ""
    echo "   Please switch to a compatible Node.js version:"
    echo ""
    
    # Check if n is installed
    if command -v n &> /dev/null; then
        echo "   Using 'n' (detected):"
        echo "   $ n 18"
        echo "   $ n lts"
        echo ""
        read -p "   Do you want to auto-switch to Node.js v18 using 'n'? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "   🔄 Switching to Node.js v18..."
            n 18
            echo "   ✅ Switched to Node.js $(node -v)"
            echo "   ℹ️  Please run this script again"
            exit 0
        else
            echo "   ℹ️  Please manually switch Node.js version and run again"
            exit 1
        fi
    # Check if nvm is available
    elif command -v nvm &> /dev/null || [ -f "$HOME/.nvm/nvm.sh" ]; then
        echo "   Using 'nvm' (detected):"
        echo "   $ nvm install 18"
        echo "   $ nvm use 18"
        echo ""
        echo "   ℹ️  Please manually switch and run again"
        exit 1
    else
        echo "   Install 'n' or 'nvm' to manage Node.js versions:"
        echo "   $ npm install -g n"
        echo "   $ n 18"
        echo ""
        exit 1
    fi
fi

echo "   ✅ Node.js v$NODE_VERSION (compatible)"

# ============================================================================
# Step 1: Verify Prerequisites
# ============================================================================
echo ""
echo "📝 Step 1: Verifying prerequisites..."

# Check if contract directory is configured
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
    
    # Use yarn if yarn.lock exists, otherwise use npm
    if [ -f "$RAILGUN_CONTRACT_DIR/yarn.lock" ]; then
        echo "   📦 Using yarn (detected yarn.lock)..."
        cd "$RAILGUN_CONTRACT_DIR"
        yarn install --frozen-lockfile --network-timeout 300000
        cd "$PWD_DIR"
    elif [ -f "$RAILGUN_CONTRACT_DIR/package-lock.json" ]; then
        echo "   📦 Using npm (detected package-lock.json)..."
        cd "$RAILGUN_CONTRACT_DIR"
        npm ci --prefer-offline
        cd "$PWD_DIR"
    else
        echo "   📦 Using npm (no lock file found)..."
        cd "$RAILGUN_CONTRACT_DIR"
        npm install
        cd "$PWD_DIR"
    fi
fi
echo "   ✓ Dependencies installed"

# ============================================================================
# Step 2: Configure Hardhat Network
# ============================================================================
echo ""
echo "📝 Step 2: Configuring Hardhat for devnet..."

# Create hardhat config snippet for xlayer-devnet
HARDHAT_CONFIG_FILE="$RAILGUN_CONTRACT_DIR/hardhat.config.ts"

if [ ! -f "$HARDHAT_CONFIG_FILE" ]; then
    echo "   ❌ hardhat.config.ts not found in $RAILGUN_CONTRACT_DIR"
    exit 1
fi

# Check if xlayer-devnet network already exists
if grep -q "xlayer-devnet" "$HARDHAT_CONFIG_FILE"; then
    echo "   ✓ xlayer-devnet network already configured"
else
    echo "   ℹ️  Adding xlayer-devnet network to hardhat.config.ts..."
    
    # Backup original file
    if [ ! -f "$HARDHAT_CONFIG_FILE.devnet.backup" ]; then
        cp "$HARDHAT_CONFIG_FILE" "$HARDHAT_CONFIG_FILE.devnet.backup"
        echo "   ✓ Backed up original config"
    fi
    
    # Create a temporary modified config
    cd "$RAILGUN_CONTRACT_DIR"
    
    # Add networks configuration in the config object (before the closing brace and export)
    awk '
    /^};$/ && !done {
        print "  networks: {"
        print "    \"xlayer-devnet\": {"
        print "      url: process.env.RPC_URL || \"http://localhost:8123\","
        print "      chainId: parseInt(process.env.CHAIN_ID || \"195\"),"
        print "      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],"
        print "      gasPrice: 1000000000,"
        print "    },"
        print "  },"
        done = 1
    }
    { print }
    ' "$HARDHAT_CONFIG_FILE" > "$HARDHAT_CONFIG_FILE.tmp"
    
    # Replace original file
    mv "$HARDHAT_CONFIG_FILE.tmp" "$HARDHAT_CONFIG_FILE"
    
    cd "$PWD_DIR"
    
    echo "   ✅ Added xlayer-devnet network to hardhat.config.ts"
fi

# ============================================================================
# Step 3: Deploy RAILGUN Smart Contracts
# ============================================================================
echo ""
echo "📜 Step 3: Deploying RAILGUN smart contracts to L2..."

# Create deployments directory
mkdir -p "$RAILGUN_DIR/deployments"

# Check if contracts are already deployed
if [ -n "$RAILGUN_SMART_WALLET_ADDRESS" ] && [ "$RAILGUN_SMART_WALLET_ADDRESS" != "" ]; then
    echo "   ⚠️  RAILGUN contracts already deployed at: $RAILGUN_SMART_WALLET_ADDRESS"
    read -p "   Do you want to redeploy? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "   ⏭️  Skipping contract deployment"
        exit 0
    fi
fi

cd "$RAILGUN_CONTRACT_DIR"

echo "   🚀 Deploying contracts using Hardhat..."
echo "   ℹ️  Network: xlayer-devnet"
echo "   ℹ️  RPC: $L2_RPC_URL"
echo "   ℹ️  Chain ID: $CHAIN_ID"
echo ""

# Export environment variables for Hardhat
export RPC_URL="$L2_RPC_URL"
export DEPLOYER_PRIVATE_KEY="$OP_PROPOSER_PRIVATE_KEY"

# Run Hardhat deployment
npx hardhat deploy:test --network xlayer-devnet || {
    echo ""
    echo "   ❌ Contract deployment failed"
    echo ""
    echo "   💡 Common issues:"
    echo "      1. Check if xlayer-devnet network is configured in hardhat.config.ts"
    echo "      2. Check if deployer has sufficient balance"
    echo "      3. Check Hardhat deploy scripts exist (scripts/deploy-*.ts)"
    echo ""
    cd "$PWD_DIR"
    exit 1
}

cd "$PWD_DIR"

echo "   ✅ Contracts deployed successfully"

# ============================================================================
# Step 4: Extract Contract Addresses
# ============================================================================
echo ""
echo "🔍 Step 4: Extracting contract addresses..."

# Try to find deployment artifacts in common locations
DEPLOYMENT_DIRS=(
    "$RAILGUN_CONTRACT_DIR/deployments"
    "$RAILGUN_CONTRACT_DIR/artifacts/deployments"
    "$RAILGUN_CONTRACT_DIR/.openzeppelin"
)

FOUND_ADDRESS=""

for DEPLOY_DIR in "${DEPLOYMENT_DIRS[@]}"; do
    if [ -d "$DEPLOY_DIR" ]; then
        echo "   🔍 Checking: $DEPLOY_DIR"
        
        # Try to find RailgunSmartWallet address
        WALLET_ADDR=$(find "$DEPLOY_DIR" -name "*.json" -type f -exec cat {} \; 2>/dev/null | \
            jq -r 'select(.contractName=="RailgunSmartWallet" or .name=="RailgunSmartWallet") | .address' 2>/dev/null | \
            head -1)
        
        if [ -n "$WALLET_ADDR" ] && [ "$WALLET_ADDR" != "null" ]; then
            FOUND_ADDRESS="$WALLET_ADDR"
            echo "   ✅ Found RailgunSmartWallet: $FOUND_ADDRESS"
            break
        fi
    fi
done

if [ -z "$FOUND_ADDRESS" ]; then
    echo "   ⚠️  Could not automatically find contract address"
    echo ""
    echo "   Please manually check deployment output above and enter the contract address:"
    read -p "   RailgunSmartWallet address: " MANUAL_ADDRESS
    
    if [ -n "$MANUAL_ADDRESS" ]; then
        FOUND_ADDRESS="$MANUAL_ADDRESS"
    else
        echo "   ❌ No address provided"
        exit 1
    fi
fi

# Update .env with the deployed address
export RAILGUN_SMART_WALLET_ADDRESS="$FOUND_ADDRESS"
sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" .env

echo "   ✅ Updated .env with contract address"

# ============================================================================
# Step 5: Verification
# ============================================================================
echo ""
echo "🔍 Step 5: Verifying contract deployment..."

# Verify contract on L2
echo "   📡 Checking contract code on L2..."
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

# ============================================================================
# Deployment Complete
# ============================================================================
echo ""
echo "🎉 RAILGUN Contract deployment completed successfully!"
echo ""
echo "📊 Contract Details:"
echo "   Chain ID:        $CHAIN_ID"
echo "   RPC URL:         $L2_RPC_URL"
echo "   SmartWallet:     $RAILGUN_SMART_WALLET_ADDRESS"
echo ""
echo "📝 Next Steps:"
echo "   1. Deploy Subgraph: ./8-deploy-subgraph.sh"
echo "   2. Test wallet:     ./9-test-wallet.sh"
echo ""
echo "💡 Contract Info:"
echo "   • Address saved to .env: RAILGUN_SMART_WALLET_ADDRESS"
echo "   • Source code: $RAILGUN_CONTRACT_DIR"
echo ""

