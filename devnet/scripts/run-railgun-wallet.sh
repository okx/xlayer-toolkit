#!/bin/bash
set -e

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 RAILGUN Wallet Test (Docker)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$PWD_DIR/.env" ]; then
    echo "📝 Loading environment from .env..."
    source "$PWD_DIR/.env"
    echo "   ✓ Environment loaded"
else
    echo "❌ .env file not found"
    echo "   Please run ./init.sh first"
    exit 1
fi

RAILGUN_KOHAKUT_IMAGE_TAG="${RAILGUN_KOHAKUT_IMAGE_TAG}"

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

# Display configuration
echo ""
echo "📊 Test Configuration:"
echo "   Chain ID:      $CHAIN_ID"
echo "   RPC URL:       $L2_RPC_URL"
echo "   Contract:      $RAILGUN_SMART_WALLET_ADDRESS"
echo "   Token:         $RAILGUN_TEST_TOKEN_ADDRESS"
echo "   Deploy Block:  ${RAILGUN_DEPLOY_BLOCK:-0}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Running tests in Docker container..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm \
  -e CHAIN_ID="$CHAIN_ID" \
  -e RPC_URL="$L2_RPC_URL" \
  -e RAILGUN_ADDRESS="$RAILGUN_SMART_WALLET_ADDRESS" \
  -e RAILGUN_RELAY_ADAPT_ADDRESS="${RAILGUN_RELAY_ADAPT_ADDRESS}" \
  -e TOKEN_ADDRESS="$RAILGUN_TEST_TOKEN_ADDRESS" \
  -e RAILGUN_DEPLOY_BLOCK="${RAILGUN_DEPLOY_BLOCK:-0}" \
  --network host \
  "$RAILGUN_KOHAKUT_IMAGE_TAG"