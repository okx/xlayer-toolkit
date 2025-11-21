#!/bin/bash

source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Setup Custom Gas Token (CGT) function
setup_cgt() {
  local ROOT_DIR=$1
  local CONFIG_DIR=$2
  local L1_RPC_URL=$3

  echo "🔧 Setting up Custom Gas Token (CGT) configuration..."
  echo ""

  # Check if OKB_TOKEN_ADDRESS is already set in environment
  if [ -n "$OKB_TOKEN_ADDRESS" ]; then
    echo "📝 Step 1: Using existing OKB token..."
    echo "   Found OKB_TOKEN_ADDRESS in environment: $OKB_TOKEN_ADDRESS"
    echo ""

    # Verify the token exists at the specified address
    cd $ROOT_DIR/packages/contracts-bedrock
    echo "   Verifying OKB token at address..."

    # Try to call a basic function to verify it's a valid ERC20
    if ! cast call "$OKB_TOKEN_ADDRESS" "name()(string)" --rpc-url "$L1_RPC_URL" >/dev/null 2>&1; then
      echo ""
      echo "❌ ERROR: Invalid OKB token address or token not deployed"
      echo "   Address: $OKB_TOKEN_ADDRESS"
      echo "   Please check the address or remove OKB_TOKEN_ADDRESS from .env to deploy a new MockOKB"
      echo ""
      return 1
    fi

    TOKEN_NAME=$(cast call "$OKB_TOKEN_ADDRESS" "name()(string)" --rpc-url "$L1_RPC_URL")
    TOKEN_SYMBOL=$(cast call "$OKB_TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$L1_RPC_URL")
    echo "   ✅ Token verified: $TOKEN_NAME ($TOKEN_SYMBOL)"
    echo ""
  else
    # Deploy MockOKB token if not already set
    echo "📝 Step 1: Deploying MockOKB token..."
    cd $ROOT_DIR/packages/contracts-bedrock

    # Temporarily disable set -e to capture forge output properly
    set +e
    MOCK_OKB_OUTPUT_FILE=$(mktemp)
    forge script scripts/DeployMockOKB.s.sol:DeployMockOKB \
      --rpc-url "$L1_RPC_URL" \
      --private-key "$DEPLOYER_PRIVATE_KEY" \
      --broadcast 2>&1 | tee $MOCK_OKB_OUTPUT_FILE
    MOCK_OKB_EXIT_CODE=$?
    set -e

    # Check if MockOKB deployment failed
    if [ $MOCK_OKB_EXIT_CODE -ne 0 ]; then
      echo ""
      echo "❌ ERROR: MockOKB deployment failed with exit code $MOCK_OKB_EXIT_CODE"
      echo "Error output shown above ☝️"
      echo ""
      return $MOCK_OKB_EXIT_CODE
    fi

    # Extract MockOKB contract address from forge output
    OKB_TOKEN_ADDRESS=$(cat $MOCK_OKB_OUTPUT_FILE | grep "MockOKB deployed at:" | awk '{print $NF}')
    rm $MOCK_OKB_OUTPUT_FILE

    if [ -z "$OKB_TOKEN_ADDRESS" ]; then
      echo ""
      echo "❌ ERROR: Could not extract MockOKB address from deployment output"
      echo "Please check the deployment logs above"
      echo ""
      return 1
    fi

    echo ""
    echo "✅ MockOKB deployed successfully!"
    echo "   Address: $OKB_TOKEN_ADDRESS"
    echo ""
    echo "💡 TIP: Add this to your .env file to reuse in future runs:"
    echo "   export OKB_TOKEN_ADDRESS=$OKB_TOKEN_ADDRESS"
    echo ""
  fi

  # Export OKB_TOKEN_ADDRESS for the setup script
  export OKB_TOKEN_ADDRESS="$OKB_TOKEN_ADDRESS"

  # Get required addresses from state.json
  echo "📝 Step 2: Running Custom Gas Token setup script..."
  STATE_JSON="$CONFIG_DIR/state.json"
  SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].SystemConfigProxy' "$STATE_JSON")
  OPTIMISM_PORTAL_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].OptimismPortalProxy' "$STATE_JSON")

  # Export required environment variables for the setup script
  export SYSTEM_CONFIG_PROXY_ADDRESS="$SYSTEM_CONFIG_PROXY_ADDRESS"
  export OPTIMISM_PORTAL_PROXY_ADDRESS="$OPTIMISM_PORTAL_PROXY_ADDRESS"
  export OKB_ADAPTER_OWNER_ADDRESS="$OKB_ADAPTER_OWNER_ADDRESS"

  # Temporarily disable set -e to capture forge output properly
  set +e
  FORGE_OUTPUT_FILE=$(mktemp)
  forge script scripts/SetupCustomGasToken.s.sol:SetupCustomGasToken \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --broadcast 2>&1 | tee $FORGE_OUTPUT_FILE
  FORGE_EXIT_CODE=$?
  set -e

  # Check if forge script failed
  if [ $FORGE_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "❌ ERROR: Custom Gas Token setup failed with exit code $FORGE_EXIT_CODE"
    echo "Error output shown above ☝️"
    echo ""
    return $FORGE_EXIT_CODE
  fi

  # Extract adapter address from setup script output
  ADAPTER_ADDRESS=$(cat $FORGE_OUTPUT_FILE | grep "DepositedOKBAdapter deployed at:" | awk '{print $NF}')
  rm $FORGE_OUTPUT_FILE

  # Use the already deployed OKB token address
  OKB_TOKEN="$OKB_TOKEN_ADDRESS"

  # Query initial OKB total supply
  INIT_TOTAL_SUPPLY=$(cast call "$OKB_TOKEN" "totalSupply()(uint256)" --rpc-url "$L1_RPC_URL")
  echo ""
  echo "📊 Initial OKB Total Supply: $INIT_TOTAL_SUPPLY"

  echo ""
  echo "✅ L1 Custom Gas Token setup complete!"
  echo ""
  echo "📋 Setup Contract Addresses:"
  echo "   OKB Token:          $OKB_TOKEN"
  echo "   Adapter:            $ADAPTER_ADDRESS"
  echo ""
}

if [ -z "$1" ]; then
  echo "❌ ERROR: ROOT_DIR is not passed as an argument"
  echo "Please pass the ROOT_DIR as the first argument"
  exit 1
fi
if [ -z "$2" ]; then
  echo "❌ ERROR: CONFIG_DIR is not passed as an argument"
  echo "Please pass the CONFIG_DIR as the second argument"
  exit 1
fi
if [ -z "$3" ]; then
  echo "❌ ERROR: L1_RPC_URL is not passed as an argument"
  echo "Please pass the L1_RPC_URL as the third argument"
  exit 1
fi

setup_cgt $1 $2 $3
