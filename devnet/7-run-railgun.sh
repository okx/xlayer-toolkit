#!/bin/bash
set -e

# ============================================================================
# RAILGUN Privacy System Setup Script
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

echo "🚀 Starting RAILGUN Privacy System deployment..."

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAILGUN_DIR=$PWD_DIR/railgun

# ============================================================================
# Step 1: Prepare Configuration Files
# ============================================================================
echo "📝 Step 1: Preparing RAILGUN configuration files..."

# Copy example env files if they don't exist
if [ ! -f "$RAILGUN_DIR"/.env.contract ]; then
    cp "$RAILGUN_DIR"/example.env.contract "$RAILGUN_DIR"/.env.contract
    echo "   ✓ Created .env.contract from example"
fi

if [ ! -f "$RAILGUN_DIR"/.env.poi ]; then
    cp "$RAILGUN_DIR"/example.env.poi "$RAILGUN_DIR"/.env.poi
    echo "   ✓ Created .env.poi from example"
fi

if [ ! -f "$RAILGUN_DIR"/.env.broadcaster ]; then
    cp "$RAILGUN_DIR"/example.env.broadcaster "$RAILGUN_DIR"/.env.broadcaster
    echo "   ✓ Created .env.broadcaster from example"
fi

# Update .env.contract
sed_inplace "s|^RPC_URL=.*|RPC_URL=$L2_RPC_URL_IN_DOCKER|" "$RAILGUN_DIR"/.env.contract
sed_inplace "s|^CHAIN_ID=.*|CHAIN_ID=$CHAIN_ID|" "$RAILGUN_DIR"/.env.contract
sed_inplace "s|^DEPLOYER_PRIVATE_KEY=.*|DEPLOYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY|" "$RAILGUN_DIR"/.env.contract
echo "   ✓ Updated contract deployment configuration"

# Update .env.poi
sed_inplace "s|^RPC_URL=.*|RPC_URL=http://op-${SEQ_TYPE}-seq:8545|" "$RAILGUN_DIR"/.env.poi
sed_inplace "s|^CHAIN_ID=.*|CHAIN_ID=$CHAIN_ID|" "$RAILGUN_DIR"/.env.poi
echo "   ✓ Updated POI node configuration"

# Update .env.broadcaster
sed_inplace "s|^RPC_URL=.*|RPC_URL=http://op-${SEQ_TYPE}-seq:8545|" "$RAILGUN_DIR"/.env.broadcaster
sed_inplace "s|^CHAIN_ID=.*|CHAIN_ID=$CHAIN_ID|" "$RAILGUN_DIR"/.env.broadcaster
sed_inplace "s|^WALLET_PRIVATE_KEY=.*|WALLET_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY|" "$RAILGUN_DIR"/.env.broadcaster
echo "   ✓ Updated broadcaster configuration"

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
      $RAILGUN_CONTRACT_IMAGE_TAG \
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
            echo "   ✅ RailgunSmartWallet deployed at: $RAILGUN_SMART_WALLET_ADDRESS"
            
            # Update .env file with deployed address
            sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" .env
            
            # Update POI node config
            sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" "$RAILGUN_DIR"/.env.poi
        else
            echo "   ⚠️  Warning: Could not extract RailgunSmartWallet address from deployment files"
        fi
        
        # Extract other contract addresses
        DEPLOYED_RELAY=$(find "$RAILGUN_DIR/deployments" -name "*.json" -exec cat {} \; | jq -r 'select(.contractName=="RelayAdapt" or .name=="RelayAdapt") | .address' 2>/dev/null | head -1)
        if [ -n "$DEPLOYED_RELAY" ] && [ "$DEPLOYED_RELAY" != "null" ]; then
            export RAILGUN_RELAY_ADAPT_ADDRESS=$DEPLOYED_RELAY
            echo "   ✅ RelayAdapt deployed at: $RAILGUN_RELAY_ADAPT_ADDRESS"
            sed_inplace "s|^RAILGUN_RELAY_ADAPT_ADDRESS=.*|RAILGUN_RELAY_ADAPT_ADDRESS=$RAILGUN_RELAY_ADAPT_ADDRESS|" .env
        fi
    fi
fi

# ============================================================================
# Step 3: Start RAILGUN Services
# ============================================================================
echo ""
echo "🚀 Step 3: Starting RAILGUN services..."

# Start MongoDB for POI node
echo "   📦 Starting MongoDB for POI node..."
docker compose up -d railgun-poi-mongodb
sleep 5
echo "   ✓ MongoDB started"

# Start POI node (image should be built by init.sh)
echo "   🛡️  Starting POI node..."
docker compose up -d railgun-poi-node
echo "   ✓ POI node started"

# Wait for POI node to be healthy
echo "   ⏳ Waiting for POI node to be ready..."
MAX_WAIT=60
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if curl -f -s http://localhost:${RAILGUN_POI_PORT}/health >/dev/null 2>&1; then
        echo "   ✅ POI node is healthy"
        break
    fi
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "   ⚠️  Warning: POI node health check timeout (continuing anyway)"
fi

# Start Broadcaster (image should be built by init.sh)
echo "   📡 Starting Broadcaster service..."
if docker compose config | grep -q "railgun-broadcaster"; then
    docker compose up -d railgun-broadcaster
    echo "   ✓ Broadcaster started"
else
    echo "   ⚠️  Broadcaster service not defined in docker-compose.yml"
    echo "   ℹ️  To start Broadcaster manually, run:"
    echo "      cd $RAILGUN_LOCAL_DIRECTORY/ppoi-safe-broadcaster-example/docker"
    echo "      ./setup.sh"
fi

# ============================================================================
# Step 4: Verification
# ============================================================================
echo ""
echo "🔍 Step 4: Verifying RAILGUN deployment..."

# Check services status
echo "   📊 Service Status:"
docker compose ps | grep railgun || echo "   ⚠️  No RAILGUN services found"

# Display deployment summary
echo ""
echo "✅ RAILGUN Privacy System deployment completed!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Deployment Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Network Information:"
echo "   Chain ID:        $CHAIN_ID"
echo "   L2 RPC URL:      $L2_RPC_URL"
echo ""
echo "📜 Contract Addresses:"
if [ -n "$RAILGUN_SMART_WALLET_ADDRESS" ]; then
    echo "   RailgunSmartWallet: $RAILGUN_SMART_WALLET_ADDRESS"
else
    echo "   RailgunSmartWallet: (not deployed or not found)"
fi
if [ -n "$RAILGUN_RELAY_ADAPT_ADDRESS" ]; then
    echo "   RelayAdapt:         $RAILGUN_RELAY_ADAPT_ADDRESS"
fi
echo ""
echo "🛡️  POI Node:"
echo "   URL:             http://localhost:${RAILGUN_POI_PORT}"
echo "   Health Check:    http://localhost:${RAILGUN_POI_PORT}/health"
echo ""
echo "📡 Broadcaster:"
echo "   API Port:        ${RAILGUN_BROADCASTER_API_PORT}"
echo "   Waku Ports:      ${RAILGUN_WAKU_PORT_1}, ${RAILGUN_WAKU_PORT_2}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📖 Next Steps:"
echo "   1. Test POI node:  curl http://localhost:${RAILGUN_POI_PORT}/health"
echo "   2. View logs:      docker compose logs -f railgun-poi-node"
echo "   3. Check services: docker compose ps | grep railgun"
echo ""
echo ""

