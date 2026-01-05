#!/bin/bash
set -e

# ============================================================================
# RAILGUN Subgraph Deployment Script (Using Source Code)
# ============================================================================
# This script deploys RAILGUN Subgraph using Graph CLI directly
# Graph Node runs in Docker, but subgraph deployment uses source code
# ============================================================================

# Load environment variables
source .env

if [ "$RAILGUN_ENABLE" != "true" ]; then
  echo "⏭️  Skipping RAILGUN Subgraph (RAILGUN_ENABLE=$RAILGUN_ENABLE)"
  exit 0
fi

echo "🚀 Starting RAILGUN Subgraph deployment..."

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

# Check if Subgraph directory is configured
if [ -z "$RAILGUN_SUBGRAPH_DIR" ]; then
    echo "   ❌ RAILGUN_SUBGRAPH_DIR is not set in .env"
    echo "   ℹ️  Example: RAILGUN_SUBGRAPH_DIR=/Users/oker/workspace/xlayer/pt/subgraph-v3-template"
    exit 1
fi

if [ ! -d "$RAILGUN_SUBGRAPH_DIR" ]; then
    echo "   ❌ Subgraph directory not found: $RAILGUN_SUBGRAPH_DIR"
    exit 1
fi
echo "   ✓ Subgraph directory: $RAILGUN_SUBGRAPH_DIR"

# Check if Graph Node is running
if ! docker ps | grep -q "railgun-graph-node"; then
    echo "   ❌ Graph Node is not running"
    echo "   ℹ️  Please start Graph Node: docker compose up -d railgun-postgres railgun-ipfs railgun-graph-node"
    exit 1
fi
echo "   ✓ Graph Node is running"

# Wait for Graph Node to be ready
echo "   ⏳ Waiting for Graph Node to be ready..."
for i in {1..30}; do
    if curl -f -s http://localhost:8000/ >/dev/null 2>&1; then
        echo "   ✅ Graph Node is healthy"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "   ❌ Graph Node is not responding after 60 seconds"
        echo "   ℹ️  Check logs: docker compose logs railgun-graph-node"
        exit 1
    fi
    sleep 2
done

# Check if Graph CLI is installed
if ! command -v graph &> /dev/null; then
    echo "   ⚠️  Graph CLI not found, installing globally..."
    npm install -g @graphprotocol/graph-cli
fi
echo "   ✓ Graph CLI installed"

# Check if dependencies are installed
if [ ! -d "$RAILGUN_SUBGRAPH_DIR/node_modules" ]; then
    echo "   ⚠️  node_modules not found, installing dependencies..."
    
    # Use yarn if yarn.lock exists, otherwise use npm
    if [ -f "$RAILGUN_SUBGRAPH_DIR/yarn.lock" ]; then
        echo "   📦 Using yarn (detected yarn.lock)..."
        cd "$RAILGUN_SUBGRAPH_DIR"
        yarn install --frozen-lockfile --network-timeout 300000
        cd "$PWD_DIR"
    elif [ -f "$RAILGUN_SUBGRAPH_DIR/package-lock.json" ]; then
        echo "   📦 Using npm (detected package-lock.json)..."
        cd "$RAILGUN_SUBGRAPH_DIR"
        npm ci --prefer-offline
        cd "$PWD_DIR"
    else
        echo "   📦 Using npm (no lock file found)..."
        cd "$RAILGUN_SUBGRAPH_DIR"
        npm install
        cd "$PWD_DIR"
    fi
fi
echo "   ✓ Dependencies installed"

# ============================================================================
# Step 2: Configure Subgraph for DevNet
# ============================================================================
echo ""
echo "📝 Step 2: Configuring Subgraph for DevNet..."

cd "$RAILGUN_SUBGRAPH_DIR"

# Get contract deployment block
echo "   🔍 Getting contract deployment block..."
DEPLOY_BLOCK=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$L2_RPC_URL" | jq -r '.result' | xargs printf "%d")

if [ -z "$DEPLOY_BLOCK" ] || [ "$DEPLOY_BLOCK" = "0" ]; then
    echo "   ⚠️  Could not get current block number, using block 0"
    DEPLOY_BLOCK=0
else
    echo "   ✓ Current L2 block: $DEPLOY_BLOCK"
fi

# Backup original files if they exist
if [ -f "networks.json" ] && [ ! -f "networks.json.devnet.backup" ]; then
    cp networks.json networks.json.devnet.backup
    echo "   ✓ Backed up original networks.json"
fi

if [ -f "subgraph.yaml" ] && [ ! -f "subgraph.yaml.devnet.backup" ]; then
    cp subgraph.yaml subgraph.yaml.devnet.backup
    echo "   ✓ Backed up original subgraph.yaml"
fi

# Create networks.json for devnet
echo "   📝 Creating networks.json..."
cat > networks.json << EOF
{
  "xlayer-devnet": {
    "PoseidonMerkleAccumulator": {
      "address": "$RAILGUN_SMART_WALLET_ADDRESS",
      "startBlock": $DEPLOY_BLOCK
    }
  }
}
EOF
echo "   ✓ Created networks.json"

# Create subgraph.yaml for devnet
echo "   📝 Creating subgraph.yaml..."
cat > subgraph.yaml << EOF
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: PoseidonMerkleAccumulator
    network: xlayer-devnet
    source:
      abi: PoseidonMerkleAccumulator
      address: "$RAILGUN_SMART_WALLET_ADDRESS"
      startBlock: $DEPLOY_BLOCK
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Token
        - CommitmentPreimage
        - Commitment
        - Unshield
      abis:
        - name: PoseidonMerkleAccumulator
          file: ./abis/PoseidonMerkleAccumulator.json
        - name: PoseidonT4
          file: ./abis/PoseidonT4.json
      eventHandlers:
        - event: AccumulatorStateUpdate((bytes32[],(bytes32[],uint8,uint32,(bytes32,(uint8,address,uint256),uint120),bytes32)[],(address,(bytes32,(uint8,address,uint256),uint120),(bytes32[3],bytes32))[],(bytes,bytes32,bytes32)[],(bytes32,uint256)[],bytes),uint32,uint224))
          handler: handleAccumulatorStateUpdate
      file: ./src/poseidon-merkle-accumulator-events.ts
EOF
echo "   ✓ Created subgraph.yaml"

# Update chain ID in source files if script exists
if [ -f "./replace-chain-id" ]; then
    chmod +x ./replace-chain-id
    ./replace-chain-id "$CHAIN_ID"
    echo "   ✓ Updated chain ID to $CHAIN_ID"
fi

# ============================================================================
# Step 3: Build Subgraph
# ============================================================================
echo ""
echo "🔨 Step 3: Building Subgraph..."

# Generate AssemblyScript types
echo "   🔧 Generating types..."
graph codegen

# Build Subgraph
echo "   🔨 Building..."
graph build

echo "   ✅ Subgraph built successfully"

# ============================================================================
# Step 4: Deploy to Graph Node
# ============================================================================
echo ""
echo "🚀 Step 4: Deploying Subgraph to Graph Node..."

# Create Subgraph (ignore error if already exists)
echo "   📦 Creating subgraph..."
graph create --node http://localhost:8020 "$RAILGUN_SUBGRAPH_NAME" 2>/dev/null || true

# Deploy Subgraph
echo "   🚀 Deploying..."
graph deploy \
  --node http://localhost:8020 \
  --ipfs http://localhost:5001 \
  "$RAILGUN_SUBGRAPH_NAME" || {
    echo ""
    echo "   ❌ Subgraph deployment failed"
    echo ""
    echo "   💡 Common issues:"
    echo "      1. Graph Node not responding (check: docker compose logs railgun-graph-node)"
    echo "      2. IPFS not responding (check: docker compose logs railgun-ipfs)"
    echo "      3. Network name mismatch in subgraph.yaml"
    echo ""
    cd "$PWD_DIR"
    exit 1
  }

cd "$PWD_DIR"

echo "   ✅ Subgraph deployed successfully"

# ============================================================================
# Step 5: Verification
# ============================================================================
echo ""
echo "🔍 Step 5: Verifying Subgraph deployment..."

# Wait for indexing to start
echo "   ⏳ Waiting for indexing to start..."
sleep 10

# Query Subgraph status
echo "   📊 Querying Subgraph status..."
SUBGRAPH_STATUS=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data "{\"query\":\"{ indexingStatusForCurrentVersion(subgraphName: \\\"$RAILGUN_SUBGRAPH_NAME\\\") { synced health chains { network latestBlock { number } } } }\"}" \
  http://localhost:8030/graphql)

if echo "$SUBGRAPH_STATUS" | jq -e '.data' >/dev/null 2>&1; then
    echo "   ✅ Subgraph is indexing"
    echo ""
    echo "$SUBGRAPH_STATUS" | jq '.data'
else
    echo "   ⚠️  Could not get Subgraph status"
fi

# Test GraphQL query
echo ""
echo "   🧪 Testing GraphQL query..."
TEST_QUERY=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data '{"query":"{ tokens(first: 5) { id tokenType tokenAddress tokenSubID } }"}' \
  "http://localhost:8000/subgraphs/name/$RAILGUN_SUBGRAPH_NAME")

if echo "$TEST_QUERY" | jq -e '.data' >/dev/null 2>&1; then
    echo "   ✅ GraphQL endpoint is responding"
else
    echo "   ⚠️  GraphQL query returned unexpected response"
fi

# ============================================================================
# Deployment Complete
# ============================================================================
echo ""
echo "🎉 RAILGUN Subgraph deployment completed successfully!"
echo ""
echo "📊 Subgraph Details:"
echo "   Name:            $RAILGUN_SUBGRAPH_NAME"
echo "   Contract:        $RAILGUN_SMART_WALLET_ADDRESS"
echo "   Start Block:     $DEPLOY_BLOCK"
echo "   Chain ID:        $CHAIN_ID"
echo ""
echo "🔗 Endpoints:"
echo "   GraphQL HTTP:    http://localhost:8000/subgraphs/name/$RAILGUN_SUBGRAPH_NAME"
echo "   GraphQL WS:      ws://localhost:8001/subgraphs/name/$RAILGUN_SUBGRAPH_NAME"
echo "   Index Status:    http://localhost:8030/graphql"
echo "   Metrics:         http://localhost:8040/"
echo ""
echo "📝 Example Queries:"
echo "   # Get all tokens"
echo "   curl -X POST -H \"Content-Type: application/json\" \\"
echo "     --data '{\"query\":\"{ tokens(first: 10) { id tokenType tokenAddress } }\"}' \\"
echo "     http://localhost:8000/subgraphs/name/$RAILGUN_SUBGRAPH_NAME"
echo ""
echo "   # Get commitments"
echo "   curl -X POST -H \"Content-Type: application/json\" \\"
echo "     --data '{\"query\":\"{ commitments(first: 10) { id treeNumber } }\"}' \\"
echo "     http://localhost:8000/subgraphs/name/$RAILGUN_SUBGRAPH_NAME"
echo ""
echo "💡 Next Steps:"
echo "   1. Test wallet: ./9-test-wallet.sh"
echo "   2. Monitor indexing: docker compose logs -f railgun-graph-node"
echo ""
echo "📖 Source code: $RAILGUN_SUBGRAPH_DIR"
echo ""

