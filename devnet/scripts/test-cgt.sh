#!/bin/bash
set -e

ROOT_DIR=$(git rev-parse --show-toplevel)

# Use current working directory to allow symlinks to work
# This way test/ and test-pp-op/ can each use their own .env
PWD_DIR="$(pwd)"

# Validate we're in a test directory with .env
if [ ! -f "$PWD_DIR/.env" ]; then
  echo "❌ ERROR: .env file not found in current directory: $PWD_DIR"
  echo "Please run this script from a test directory (test/ or test-pp-op/)"
  exit 1
fi

source .env

SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].SystemConfigProxy' $PWD_DIR/config-op/state.json)

# Query ADAPTER_ADDRESS from SystemConfig.gasPayingToken()
echo "📝 Querying ADAPTER_ADDRESS from SystemConfig..."
ADAPTER_ADDRESS=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "gasPayingToken()(address,uint8)" --rpc-url "$L1_RPC_URL" | head -n1)
if [ -z "$ADAPTER_ADDRESS" ] || [ "$ADAPTER_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
  echo "❌ ERROR: Could not query ADAPTER_ADDRESS from SystemConfig or CGT not configured"
  echo "   SystemConfig address: $SYSTEM_CONFIG_PROXY_ADDRESS"
  exit 1
fi

# Query OKB_TOKEN_ADDRESS from the adapter
echo "📝 Querying OKB_TOKEN_ADDRESS from adapter..."
OKB_TOKEN_ADDRESS=$(cast call "$ADAPTER_ADDRESS" "OKB()(address)" --rpc-url "$L1_RPC_URL")
if [ -z "$OKB_TOKEN_ADDRESS" ] || [ "$OKB_TOKEN_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
  echo "❌ ERROR: Could not query OKB_TOKEN_ADDRESS from adapter"
  echo "   Adapter address: $ADAPTER_ADDRESS"
  exit 1
fi

# Query INIT_TOTAL_SUPPLY from OKB token contract
echo "📝 Querying INIT_TOTAL_SUPPLY from OKB token..."
INIT_TOTAL_SUPPLY=$(cast call "$OKB_TOKEN_ADDRESS" "totalSupply()(uint256)" --rpc-url "$L1_RPC_URL")

echo ""
echo "🧪 Testing Custom Gas Token (CGT) configuration..."
echo ""
echo "📋 Using Contract Addresses:"
echo "   OKB Token:          $OKB_TOKEN_ADDRESS"
echo "   Adapter:            $ADAPTER_ADDRESS (queried from SystemConfig)"
echo "   Initial Supply:     $INIT_TOTAL_SUPPLY (queried from OKB)"
echo ""

# Check if L2 is running before verifying L2 configuration
if curl -s -X POST "$L2_RPC_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  > /dev/null 2>&1; then

  echo "📝 Step 1: Verifying L2 configuration..."
  echo ""

  # Call L1Block predeploy to check configuration
  L1_BLOCK_ADDR="0x4200000000000000000000000000000000000015"

  # Check isCustomGasToken
  IS_CUSTOM_GAS_TOKEN=$(cast call "$L1_BLOCK_ADDR" \
    "isCustomGasToken()(bool)" \
    --rpc-url "$L2_RPC_URL")

  echo "  L1Block.isCustomGasToken(): $IS_CUSTOM_GAS_TOKEN"

  # Check gasPayingTokenName
  TOKEN_NAME=$(cast call "$L1_BLOCK_ADDR" \
    "gasPayingTokenName()(string)" \
    --rpc-url "$L2_RPC_URL")

  echo "  L1Block.gasPayingTokenName(): $TOKEN_NAME"

  # Check gasPayingTokenSymbol
  TOKEN_SYMBOL=$(cast call "$L1_BLOCK_ADDR" \
    "gasPayingTokenSymbol()(string)" \
    --rpc-url "$L2_RPC_URL")

  echo "  L1Block.gasPayingTokenSymbol(): $TOKEN_SYMBOL"

  echo ""
  if [ "$IS_CUSTOM_GAS_TOKEN" = "true" ]; then
    echo "✅ L2 Custom Gas Token configuration verified!"
  else
    echo "⚠️  WARNING: L2 custom gas token not yet active"
    echo "   The L2 chain needs to process the setCustomGasToken transaction"
    echo "   This will happen automatically when the chain processes L1 data"
  fi
else
  echo "⚠️  L2 node is not running yet - skipping L2 verification"
  echo "   Please verify L2 configuration after the L2 node starts"
fi

echo ""
echo "🎉 Custom Gas Token verification completed!"
echo ""

# Perform test deposit
if [ -n "$OKB_TOKEN_ADDRESS" ] && [ -n "$ADAPTER_ADDRESS" ]; then
  echo "📝 Step 2: Performing test deposit..."
  echo ""

  DEPOSIT_AMOUNT="7999000000000000"

  # Get deployer address and verify it's the adapter owner
  DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
  ADAPTER_OWNER=$(cast call "$ADAPTER_ADDRESS" "owner()(address)" --rpc-url "$L1_RPC_URL")

  echo "  Deployer Address: $DEPLOYER_ADDRESS"
  echo "  Adapter Owner:    $ADAPTER_OWNER"

  if [ "$DEPLOYER_ADDRESS" != "$ADAPTER_OWNER" ]; then
    echo ""
    echo "❌ ERROR: Deployer is not the adapter owner"
    echo "   This script assumes deployer has ownership of the adapter"
    echo "   Current owner: $ADAPTER_OWNER"
    exit 1
  fi

  echo "  ✅ Deployer is verified as adapter owner"
  echo ""

  # Check deployer's OKB balance
  DEPLOYER_OKB_BALANCE=$(cast call "$OKB_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$DEPLOYER_ADDRESS" --rpc-url "$L1_RPC_URL")
  echo "  Deployer OKB Balance: $DEPLOYER_OKB_BALANCE"
  echo ""

  # Step 2a: Add deployer to whitelist
  echo "  Adding deployer to whitelist..."
  cast send "$ADAPTER_ADDRESS" \
    "addToWhitelistBatch(address[])" \
    "[$DEPLOYER_ADDRESS]" \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"
  echo "  ✅ Deployer added to whitelist"
  echo ""

  # Step 2b: Approve the adapter to spend OKB
  cast send "$OKB_TOKEN_ADDRESS" \
    "approve(address,uint256)" \
    "$ADAPTER_ADDRESS" \
    "$DEPOSIT_AMOUNT" \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  # L2 recipient address
  L2_RECIPIENT=$DEPLOYER_ADDRESS

  # Step 2c: Perform the deposit
  cast send "$ADAPTER_ADDRESS" \
    "deposit(address,uint256)" \
    "$L2_RECIPIENT" \
    "$DEPOSIT_AMOUNT" \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  echo ""
  echo "✅ Test deposit transaction sent!"
  echo ""
  echo "⏳ Waiting for L2 to process the deposit..."
  echo "   Checking balance every 5 seconds..."
  echo ""

  INIT_BALANCE=$(cast balance $L2_RECIPIENT --rpc-url $L2_RPC_URL)
  echo "  Deposit From $DEPLOYER_ADDRESS to $L2_RECIPIENT"
  echo "  Deposit Amount: $DEPOSIT_AMOUNT"
  echo "  L2 Recipient:   $L2_RECIPIENT"
  echo "  L2 Recipient Initial Balance: $INIT_BALANCE"
  echo ""

  # Expected final balance
  EXPECTED_BALANCE=$((INIT_BALANCE + DEPOSIT_AMOUNT))

  # Timeout after 5 minutes (60 attempts * 5 seconds)
  MAX_ATTEMPTS=60
  ATTEMPT=0

  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    CURRENT_BALANCE=$(cast balance $L2_RECIPIENT --rpc-url $L2_RPC_URL)

    echo "  [Attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS] Current Balance: $CURRENT_BALANCE (Expected: $EXPECTED_BALANCE)"

    if [ "$CURRENT_BALANCE" = "$EXPECTED_BALANCE" ]; then
      echo ""
      echo "🎉 Deposit processed successfully!"
      echo ""

      # Query OKB total supply after successful deposit
      DEPOSIT_FINAL_TOTAL_SUPPLY=$(cast call "$OKB_TOKEN_ADDRESS" "totalSupply()(uint256)" --rpc-url "$L1_RPC_URL")

      echo "📊 Final Status:"
      echo "   Initial Balance:  $INIT_BALANCE"
      echo "   Deposit Amount:   $DEPOSIT_AMOUNT"
      echo "   Final Balance:    $CURRENT_BALANCE"
      echo "   L2 Recipient:     $L2_RECIPIENT"
      echo ""
      echo "🔥 OKB Token Supply Status:"
      echo "   Initial Total Supply: $INIT_TOTAL_SUPPLY"
      echo "   Final Total Supply:   $DEPOSIT_FINAL_TOTAL_SUPPLY"
      echo ""
      break
    fi

    ATTEMPT=$((ATTEMPT + 1))

    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      sleep 5
    fi
  done

  if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo ""
    echo "⚠️  WARNING: Deposit not processed within timeout period (5 minutes)"
    echo "   Current Balance:  $CURRENT_BALANCE"
    echo "   Expected Balance: $EXPECTED_BALANCE"
    echo ""
    echo "📚 Troubleshooting:"
    echo "   1. Check if L2 node is running and syncing"
    echo "   2. Check L1 transaction status"
    echo "   3. Monitor TransactionDeposited events on OptimismPortal: $OPTIMISM_PORTAL_PROXY_ADDRESS"
    echo "   4. Manually check balance: cast balance $L2_RECIPIENT --rpc-url $L2_RPC_URL"
  fi
fi
