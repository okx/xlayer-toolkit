#!/bin/bash

set -e

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go to devnet directory
cd "$SCRIPT_DIR/.."

source .env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Setup System Config Parameters function
setup_system_config_params() {
  echo ""
  echo "=== Setting OP System Config Parameters ==="
  echo ""
  
  # Check if required environment variables are set
  if [ -z "$SYSTEM_CONFIG_PROXY_ADDRESS" ]; then
    echo "❌ ERROR: SYSTEM_CONFIG_PROXY_ADDRESS not found in .env"
    return 1
  fi
  
  if [ -z "$L1_RPC_URL" ]; then
    echo "❌ ERROR: L1_RPC_URL not found in .env"
    return 1
  fi
  
  if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    echo "❌ ERROR: DEPLOYER_PRIVATE_KEY not found in .env"
    return 1
  fi
  
  echo "📋 Configuration:"
  echo "   System Config Address: $SYSTEM_CONFIG_PROXY_ADDRESS"
  echo "   L1 RPC URL: $L1_RPC_URL"
  echo ""

  # 1. Set EIP1559 Parameters (denominator=100000000, elasticity=1)
  echo "📝 Step 1: Setting EIP1559 Parameters..."
  echo "   Denominator: 100000000"
  echo "   Elasticity: 1"
  
  cast send "$SYSTEM_CONFIG_PROXY_ADDRESS" \
    "setEIP1559Params(uint32,uint32)" \
    100000000 1 \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --legacy

  if [ $? -eq 0 ]; then
    echo "   ✅ EIP1559 parameters set successfully"
  else
    echo "   ❌ Failed to set EIP1559 parameters"
    return 1
  fi
  echo ""

  # 2. Set Gas Config Ecotone (scalar=0, blobBaseFeeScalar=0)
  echo "📝 Step 2: Setting Gas Config Ecotone..."
  echo "   Scalar: 0"
  echo "   Blob Base Fee Scalar: 0"
  
  cast send "$SYSTEM_CONFIG_PROXY_ADDRESS" \
    "setGasConfigEcotone(uint32,uint32)" \
    0 0 \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --legacy

  if [ $? -eq 0 ]; then
    echo "   ✅ Gas config ecotone set successfully"
  else
    echo "   ❌ Failed to set gas config ecotone"
    return 1
  fi
  echo ""

  # 3. Set Min Base Fee (99999999)
  echo "📝 Step 3: Setting Min Base Fee..."
  echo "   Min Base Fee: 99999999"
  
  cast send "$SYSTEM_CONFIG_PROXY_ADDRESS" \
    "setMinBaseFee(uint64)" \
    99999999 \
    --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --legacy

  if [ $? -eq 0 ]; then
    echo "   ✅ Min base fee set successfully"
  else
    echo "   ❌ Failed to set min base fee"
    return 1
  fi
  echo ""

  echo "✅ All System Config parameters set successfully!"
  echo ""
}

# Verify System Config Parameters function
verify_system_config_params() {
  echo "=== Verifying OP System Config Parameters ==="
  echo ""

  local ALL_CORRECT=true

  # 1. Check EIP1559 Parameters
  echo "📝 Checking EIP1559 Parameters..."
  EIP1559_DENOMINATOR_RAW=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "eip1559Denominator()(uint32)" --rpc-url "$L1_RPC_URL")
  EIP1559_ELASTICITY_RAW=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "eip1559Elasticity()(uint32)" --rpc-url "$L1_RPC_URL")

  # Extract numeric value (remove scientific notation part if present)
  EIP1559_DENOMINATOR=$(echo "$EIP1559_DENOMINATOR_RAW" | awk '{print $1}')
  EIP1559_ELASTICITY=$(echo "$EIP1559_ELASTICITY_RAW" | awk '{print $1}')

  echo "   Denominator: $EIP1559_DENOMINATOR_RAW (expected: 100000000)"
  echo "   Elasticity: $EIP1559_ELASTICITY_RAW (expected: 1)"

  if [ "$EIP1559_DENOMINATOR" = "100000000" ] && [ "$EIP1559_ELASTICITY" = "1" ]; then
    echo "   ✅ EIP1559 parameters are correct"
  else
    echo "   ❌ EIP1559 parameters mismatch!"
    ALL_CORRECT=false
  fi
  echo ""

  # 2. Check Gas Config Ecotone
  echo "📝 Checking Gas Config Ecotone..."
  SCALAR_RAW=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "basefeeScalar()(uint32)" --rpc-url "$L1_RPC_URL")
  BLOB_BASE_FEE_SCALAR_RAW=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "blobbasefeeScalar()(uint32)" --rpc-url "$L1_RPC_URL")

  # Extract numeric value (remove scientific notation part if present)
  SCALAR=$(echo "$SCALAR_RAW" | awk '{print $1}')
  BLOB_BASE_FEE_SCALAR=$(echo "$BLOB_BASE_FEE_SCALAR_RAW" | awk '{print $1}')

  echo "   Scalar: $SCALAR_RAW (expected: 0)"
  echo "   Blob Base Fee Scalar: $BLOB_BASE_FEE_SCALAR_RAW (expected: 0)"

  if [ "$SCALAR" = "0" ] && [ "$BLOB_BASE_FEE_SCALAR" = "0" ]; then
    echo "   ✅ Gas config ecotone parameters are correct"
  else
    echo "   ❌ Gas config ecotone parameters mismatch!"
    ALL_CORRECT=false
  fi
  echo ""

  # 3. Check Min Base Fee
  echo "📝 Checking Min Base Fee..."
  MIN_BASE_FEE_RAW=$(cast call "$SYSTEM_CONFIG_PROXY_ADDRESS" "minBaseFee()(uint64)" --rpc-url "$L1_RPC_URL")

  # Extract numeric value (remove scientific notation part if present)
  MIN_BASE_FEE=$(echo "$MIN_BASE_FEE_RAW" | awk '{print $1}')

  echo "   Min Base Fee: $MIN_BASE_FEE_RAW (expected: 99999999)"

  if [ "$MIN_BASE_FEE" = "99999999" ]; then
    echo "   ✅ Min base fee is correct"
  else
    echo "   ❌ Min base fee mismatch!"
    ALL_CORRECT=false
  fi
  echo ""

  if [ "$ALL_CORRECT" = true ]; then
    echo "✅ All System Config parameters verified successfully!"
    echo ""
    return 0
  else
    echo "❌ Some System Config parameters verification failed!"
    echo ""
    return 1
  fi
}

# Main execution
setup_system_config_params

# Verify parameters after setup
verify_system_config_params
