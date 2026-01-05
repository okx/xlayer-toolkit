#!/bin/bash
set -e

# ============================================================================
# RAILGUN Subgraph Deployment Script
# ============================================================================
# This script deploys the RAILGUN Subgraph to the Graph Node for fast event indexing
# For full deployment guide, see: devnet/RAILGUN_INTEGRATION.md
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
# Step 1: Verify Prerequisites
# ============================================================================
echo ""
echo "📝 Step 1: Verifying prerequisites..."

# Check if contract is deployed
if [ -z "$RAILGUN_SMART_WALLET_ADDRESS" ] || [ "$RAILGUN_SMART_WALLET_ADDRESS" = "" ]; then
    echo "   ❌ RAILGUN_SMART_WALLET_ADDRESS is not set"
    echo "   ℹ️  Please run './7-run-railgun.sh' first to deploy contracts"
    exit 1
fi
echo "   ✓ Contract deployed at: $RAILGUN_SMART_WALLET_ADDRESS"

# Check if Subgraph directory is configured
if [ -z "$RAILGUN_SUBGRAPH_DIRECTORY" ] || [ "$RAILGUN_SUBGRAPH_DIRECTORY" = "" ]; then
    echo "   ❌ RAILGUN_SUBGRAPH_DIRECTORY is not set in .env"
    echo "   ℹ️  Example: RAILGUN_SUBGRAPH_DIRECTORY=/Users/oker/workspace/xlayer/pt/subgraph-v3-template"
    exit 1
fi

if [ ! -d "$RAILGUN_SUBGRAPH_DIRECTORY" ]; then
    echo "   ❌ Subgraph directory not found: $RAILGUN_SUBGRAPH_DIRECTORY"
    exit 1
fi
echo "   ✓ Subgraph directory found: $RAILGUN_SUBGRAPH_DIRECTORY"

# Check if Graph Node is running
if ! docker ps | grep -q "railgun-graph-node"; then
    echo "   ❌ Graph Node is not running"
    echo "   ℹ️  Please start services: docker compose up -d railgun-graph-node"
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
        echo "   ⚠️  Warning: Graph Node health check timeout (continuing anyway)"
    fi
    sleep 2
done

# Check if Graph CLI is installed
if ! command -v graph &> /dev/null; then
    echo "   ⚠️  Graph CLI not found, installing..."
    npm install -g @graphprotocol/graph-cli
fi
echo "   ✓ Graph CLI installed"

# ============================================================================
# Step 2: Configure Subgraph for DevNet
# ============================================================================
echo ""
echo "📝 Step 2: Configuring Subgraph for DevNet..."

cd "$RAILGUN_SUBGRAPH_DIRECTORY"

# Backup original networks.json if it exists
if [ -f "networks.json" ] && [ ! -f "networks.json.backup" ]; then
    cp networks.json networks.json.backup
    echo "   ✓ Backed up original networks.json"
fi

# Get contract deployment block (approximate from L2)
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

# Create networks.json for devnet
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
echo "   ✓ Created networks.json for devnet"

# Backup original subgraph.yaml if it exists
if [ -f "subgraph.yaml" ] && [ ! -f "subgraph.yaml.backup" ]; then
    cp subgraph.yaml subgraph.yaml.backup
    echo "   ✓ Backed up original subgraph.yaml"
fi

# Update subgraph.yaml for devnet
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
        - event: AccumulatorStateUpdate((bytes32[],(bytes32[],uint8,uint32,(bytes32,(uint8,address,uint256),uint120),bytes32)[],(address,(bytes32,(uint8,address,uint256),uint120),(bytes32[3],bytes32))[],(bytes,bytes32,bytes32)[],(bytes32,uint256)[],bytes),uint32,uint224)
          handler: handleAccumulatorStateUpdate
      file: ./src/poseidon-merkle-accumulator-events.ts
EOF
echo "   ✓ Created subgraph.yaml for devnet"

# Update chain ID in source files if replace-chain-id script exists
if [ -f "./replace-chain-id" ]; then
    chmod +x ./replace-chain-id
    ./replace-chain-id "$CHAIN_ID"
    echo "   ✓ Updated chain ID to $CHAIN_ID"
fi

# ============================================================================
# Step 3: Build and Deploy Subgraph
# ============================================================================
echo ""
echo "🔨 Step 3: Building Subgraph..."

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "   📦 Installing dependencies..."
    yarn install --frozen-lockfile --network-timeout 300000
fi

# Generate code
echo "   🔧 Generating AssemblyScript types..."
graph codegen

# Build Subgraph
echo "   🔨 Building Subgraph..."
graph build

echo "   ✅ Subgraph built successfully"

# ============================================================================
# Step 4: Deploy to Graph Node
# ============================================================================
echo ""
echo "🚀 Step 4: Deploying Subgraph to Graph Node..."

# Create Subgraph if it doesn't exist
graph create --node http://localhost:8020 "$RAILGUN_SUBGRAPH_NAME" 2>/dev/null || true

# Deploy Subgraph
graph deploy --node http://localhost:8020 --ipfs http://localhost:5001 "$RAILGUN_SUBGRAPH_NAME" || {
    echo "   ❌ Subgraph deployment failed"
    exit 1
}

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
SUBGRAPH_STATUS=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data "{\"query\":\"{ indexingStatusForCurrentVersion(subgraphName: \\\"$RAILGUN_SUBGRAPH_NAME\\\") { synced health chains { network latestBlock { number } } } }\"}" \
  http://localhost:8030/graphql)

echo "   📊 Subgraph Status:"
echo "$SUBGRAPH_STATUS" | jq .

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
echo "   Version:         $RAILGUN_SUBGRAPH_VERSION"
echo "   Contract:        $RAILGUN_SMART_WALLET_ADDRESS"
echo "   Start Block:     $DEPLOY_BLOCK"
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
echo "   1. Test with wallet container: cd test-wallet && make test"
echo "   2. Monitor indexing: watch -n 2 'curl -s http://localhost:8030/graphql -d \"{\\\"query\\\":\\\"{indexingStatusForCurrentVersion(subgraphName:\\\\\\\"$RAILGUN_SUBGRAPH_NAME\\\\\\\"){synced health}}\\\"}\"|jq'"
echo ""

