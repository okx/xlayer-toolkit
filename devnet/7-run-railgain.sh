#!/bin/bash
set -e

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAILGUN_DIR="$PWD_DIR/railgun"
RAILGUN_ENV_FILE="$RAILGUN_DIR/.env.railgun"

# Load environment variables
source .env

# Load RAILGUN internal configuration (if exists)
if [ -f "$RAILGUN_ENV_FILE" ]; then
  source "$RAILGUN_ENV_FILE"
fi

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

# Initialize RAILGUN internal config file (if not exists)
if [ ! -f "$RAILGUN_ENV_FILE" ]; then
  cp "$RAILGUN_DIR/example.env.railgun" "$RAILGUN_ENV_FILE"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 RAILGUN Complete Test Flow (Kohaku SDK)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📜 Step 1/3: Deploying RAILGUN Contracts (Docker)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if Docker image exists
RAILGUN_CONTRACT_IMAGE_TAG="${RAILGUN_CONTRACT_IMAGE_TAG:-railgun-contract:latest}"

# Deploy contracts using Docker
echo ""
echo "📜 Deploying RAILGUN smart contracts using Docker..."
echo "   ℹ️  Network: xlayer-devnet"
echo "   ℹ️  RPC: $L2_RPC_URL"
echo "   ℹ️  Chain ID: $CHAIN_ID"
echo ""

TEMP_DEPLOY_LOG="/tmp/railgun-deploy-$$.log"

# Convert localhost to host.docker.internal for Docker container
DOCKER_RPC_URL="${L2_RPC_URL/localhost/host.docker.internal}"

docker run --rm \
  -e RPC_URL="$DOCKER_RPC_URL" \
  -e CHAIN_ID="$CHAIN_ID" \
  -e DEPLOYER_PRIVATE_KEY="$OP_PROPOSER_PRIVATE_KEY" \
  --network host \
  "$RAILGUN_CONTRACT_IMAGE_TAG" \
  deploy:test --network xlayer-devnet 2>&1 | tee "$TEMP_DEPLOY_LOG"

DEPLOY_STATUS=${PIPESTATUS[0]}
DEPLOY_OUTPUT=$(cat "$TEMP_DEPLOY_LOG")

echo ""

if [ $DEPLOY_STATUS -ne 0 ]; then
    echo "   ❌ Contract deployment failed"
    rm -f "$TEMP_DEPLOY_LOG" 2>/dev/null
    exit 1
fi

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
    sed_inplace "s|^RAILGUN_SMART_WALLET_ADDRESS=.*|RAILGUN_SMART_WALLET_ADDRESS=$RAILGUN_SMART_WALLET_ADDRESS|" "$RAILGUN_ENV_FILE"
fi

if [ -n "$RELAY_ADAPT_ADDR" ] && [ "$RELAY_ADAPT_ADDR" != "null" ]; then
    echo "   ✅ Found RelayAdapt: $RELAY_ADAPT_ADDR"
    export RAILGUN_RELAY_ADAPT_ADDRESS="$RELAY_ADAPT_ADDR"
    sed_inplace "s|^RAILGUN_RELAY_ADAPT_ADDRESS=.*|RAILGUN_RELAY_ADAPT_ADDRESS=$RELAY_ADAPT_ADDR|" "$RAILGUN_ENV_FILE"
fi

if [ -n "$POSEIDON_T4_ADDR" ] && [ "$POSEIDON_T4_ADDR" != "null" ]; then
    echo "   ✅ Found PoseidonT4: $POSEIDON_T4_ADDR"
    export RAILGUN_POSEIDONT4_ADDRESS="$POSEIDON_T4_ADDR"
    sed_inplace "s|^RAILGUN_POSEIDONT4_ADDRESS=.*|RAILGUN_POSEIDONT4_ADDRESS=$POSEIDON_T4_ADDR|" "$RAILGUN_ENV_FILE"
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
    
    # Save to railgun/.env.railgun
    if grep -q "^RAILGUN_DEPLOY_BLOCK=" "$RAILGUN_ENV_FILE"; then
        sed_inplace "s|^RAILGUN_DEPLOY_BLOCK=.*|RAILGUN_DEPLOY_BLOCK=$RAILGUN_DEPLOY_BLOCK|" "$RAILGUN_ENV_FILE"
    else
        echo "RAILGUN_DEPLOY_BLOCK=$RAILGUN_DEPLOY_BLOCK" >> "$RAILGUN_ENV_FILE"
    fi
else
    echo "   ⚠️  Could not determine deployment block, using 0"
    export RAILGUN_DEPLOY_BLOCK="0"
fi

rm -f "$TEMP_DEPLOY_LOG" 2>/dev/null

echo ""
echo "✅ Contract deployment completed"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🪙 Step 2/3: Deploying Test ERC20 Token"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

./scripts/deploy-test-token.sh || {
    echo "❌ Failed to deploy test token"
    exit 1
}

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