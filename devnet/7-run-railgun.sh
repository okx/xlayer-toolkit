#!/bin/bash
set -e

# ============================================================================
# RAILGUN Contract Deployment Script (Minimal Version)
# ============================================================================
# This script deploys RAILGUN smart contracts to the L2 network
# For full deployment guide, see: devnet/RAILGUN_INTEGRATION.md
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
# Step 1: Prepare Configuration Files
# ============================================================================
echo ""
echo "📝 Step 1: Preparing RAILGUN configuration..."

# Create directories
mkdir -p "$RAILGUN_DIR/deployments" "$RAILGUN_DIR/config"

# Copy example env file if it doesn't exist
if [ ! -f "$RAILGUN_DIR"/.env.contract ]; then
    cp "$RAILGUN_DIR"/example.env.contract "$RAILGUN_DIR"/.env.contract
    echo "   ✓ Created .env.contract from example"
fi

# Update .env.contract with current network settings
sed_inplace "s|^RPC_URL=.*|RPC_URL=$L2_RPC_URL_IN_DOCKER|" "$RAILGUN_DIR"/.env.contract
sed_inplace "s|^CHAIN_ID=.*|CHAIN_ID=$CHAIN_ID|" "$RAILGUN_DIR"/.env.contract
sed_inplace "s|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY|" "$RAILGUN_DIR"/.env.contract
echo "   ✓ Updated contract configuration"

# ============================================================================
# Step 2: Deploy RAILGUN Smart Contracts
# ============================================================================
echo ""
echo "📜 Step 2: Deploying RAILGUN smart contracts to L2..."

# Check if contracts are already deployed
if [ -n "$RAILGUN_SMART_WALLET_ADDRESS" ] && [ "$RAILGUN_SMART_WALLET_ADDRESS" != "" ]; then
    echo "   ⚠️  RAILGUN contracts already deployed at: $RAILGUN_SMART_WALLET_ADDRESS"
    echo "   ⏭️  Skipping contract deployment"
else
    echo "   🚀 Deploying contracts using image: $RAILGUN_CONTRACT_IMAGE_TAG"
    echo "   ℹ️  Note: If image not found, run './init.sh' first to build images"

    # Deploy contracts using Docker
    docker run --rm \
      --network "$DOCKER_NETWORK" \
      --env-file "$RAILGUN_DIR"/.env.contract \
      -v "$RAILGUN_DIR/deployments:/app/deployments" \
      --add-host=host.docker.internal:host-gateway \
      "$RAILGUN_CONTRACT_IMAGE_TAG" \
      deploy:test --network xlayer-devnet || {
        echo "   ❌ Contract deployment failed"
        exit 1
      }

    echo "   ✓ Contracts deployed successfully"

    # Extract contract addresses from deployment files
    if [ -d "$RAILGUN_DIR/deployments" ]; then
        # Try to find RailgunSmartWallet address
        DEPLOYED_WALLET=$(find "$RAILGUN_DIR/deployments" -name "*.json" -exec cat {} \; | jq -r 'select(.contractName=="RailgunSmartWallet" or .name=="RailgunSmartWallet") | .address' 2>/dev/null | head -1)

        if [ -n "$DEPLOYED_WALLET" ] && [ "$DEPLOYED_WALLET" != "null" ]; then
            export RAILGUN_SMART_WALLET_ADDRESS=$DEPLOYED_WALLET
            echo "   ✅ RailgunSmartWallet deployed to: $RAILGUN_SMART_WALLET_ADDRESS"
            # Update .env with the deployed address for future runs
            sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" .env
        else
            echo "   ❌ Could not find RailgunSmartWallet address in deployment files."
            exit 1
        fi

        # Try to find RelayAdapt address
        DEPLOYED_RELAY_ADAPT=$(find "$RAILGUN_DIR/deployments" -name "*.json" -exec cat {} \; | jq -r 'select(.contractName=="RelayAdapt" or .name=="RelayAdapt") | .address' 2>/dev/null | head -1)

        if [ -n "$DEPLOYED_RELAY_ADAPT" ] && [ "$DEPLOYED_RELAY_ADAPT" != "null" ]; then
            export RAILGUN_RELAY_ADAPT_ADDRESS=$DEPLOYED_RELAY_ADAPT
            echo "   ✅ RelayAdapt deployed to: $DEPLOYED_RELAY_ADAPT"
            # Update .env with the deployed address for future runs
            sed_inplace "s|^RAILGUN_RELAY_ADAPT_ADDRESS=.*|RAILGUN_RELAY_ADAPT_ADDRESS=$RAILGUN_RELAY_ADAPT_ADDRESS|" .env
        else
            echo "   ⚠️  Could not find RelayAdapt address in deployment files. This might be optional."
        fi
    else
        echo "   ❌ Deployment directory not found: $RAILGUN_DIR/deployments"
        exit 1
    fi
fi

# ============================================================================
# Step 3: Verification
# ============================================================================
echo ""
echo "🔍 Step 3: Verifying RAILGUN deployment..."

# Check if contract address is set
if [ -z "$RAILGUN_SMART_WALLET_ADDRESS" ]; then
    echo "   ❌ RAILGUN_SMART_WALLET_ADDRESS is not set"
    exit 1
fi

# Verify contract deployment on L2
echo "   📡 Verifying contract on L2..."
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
if [ -n "$RAILGUN_RELAY_ADAPT_ADDRESS" ]; then
    echo "   RelayAdapt:      $RAILGUN_RELAY_ADAPT_ADDRESS"
fi
echo ""
echo "📝 Next Steps:"
echo "   1. Deploy Subgraph for event indexing (see RAILGUN_INTEGRATION.md)"
echo "   2. Test with wallet container (see test-wallet/)"
echo "   3. Check deployment files: ls -la $RAILGUN_DIR/deployments/"
echo ""
echo "💡 Integration Guide:"
echo "   See devnet/RAILGUN_INTEGRATION.md for complete setup instructions"
echo ""
