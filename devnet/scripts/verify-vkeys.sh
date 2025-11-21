#!/bin/bash
set -e

# ============================================================================
# Verify VKeys Consistency
# ============================================================================
# This script verifies that the VKeys in the configuration match the VKeys
# derived from the ELF files and the on-chain game implementation.
# ============================================================================

echo "🔍 Verifying VKey Consistency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
ENV_PROPOSER_FILE="$PWD_DIR/op-succinct/.env.proposer"

# Load environment
if [ ! -f "$ENV_PROPOSER_FILE" ]; then
    echo "❌ Error: $ENV_PROPOSER_FILE not found"
    exit 1
fi

source "$ENV_PROPOSER_FILE"

# Check required variables
if [ -z "$OP_SUCCINCT_DIRECTORY" ]; then
    echo "❌ Error: OP_SUCCINCT_DIRECTORY is not set"
    exit 1
fi

if [ -z "$FACTORY_ADDRESS" ]; then
    echo "❌ Error: FACTORY_ADDRESS is not set"
    exit 1
fi

if [ -z "$GAME_TYPE" ]; then
    GAME_TYPE=42
fi

echo "📋 Configuration:"
echo "   • OP-Succinct Dir: $OP_SUCCINCT_DIRECTORY"
echo "   • Factory Address: $FACTORY_ADDRESS"
echo "   • Game Type:       $GAME_TYPE"
echo ""

# Step 1: Get VKey from ELF
echo "🔧 Step 1/3: Extracting VKey from ELF..."
VKEY_FROM_ELF=$(docker run --rm \
    -v "$OP_SUCCINCT_DIRECTORY:/workspace" \
    -w /workspace \
    "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" \
    cargo run --bin config --release 2>&1 | grep "aggregation_vkey:" | awk '{print $2}' | tr -d '[:space:]')

if [ -z "$VKEY_FROM_ELF" ]; then
    echo "❌ Failed to extract VKey from ELF"
    exit 1
fi

echo "   ELF VKey: $VKEY_FROM_ELF"

# Step 2: Get VKey from configuration
echo ""
echo "🔧 Step 2/3: Reading VKey from configuration..."
VKEY_FROM_CONFIG=$(grep "^AGGREGATION_VKEY=" "$ENV_PROPOSER_FILE" | cut -d'=' -f2 | tr -d '[:space:]')

if [ -z "$VKEY_FROM_CONFIG" ]; then
    echo "❌ AGGREGATION_VKEY not found in configuration"
    exit 1
fi

echo "   Config VKey: $VKEY_FROM_CONFIG"

# Step 3: Get VKey from on-chain game
echo ""
echo "🔧 Step 3/3: Reading VKey from on-chain game..."

# Get game implementation address
GAME_IMPL=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    "$OP_SUCCINCT_CONTRACTS_IAMGE_TAG" \
    cast call \
      --rpc-url "$L1_RPC_URL_IN_DOCKER" \
      "$FACTORY_ADDRESS" \
      'gameImpls(uint32)(address)' \
      "$GAME_TYPE" 2>/dev/null | tr -d '[:space:]')

if [ -z "$GAME_IMPL" ] || [ "$GAME_IMPL" = "0x0000000000000000000000000000000000000000" ]; then
    echo "   ⚠️  Game implementation not deployed yet"
    VKEY_FROM_CHAIN=""
else
    echo "   Game Implementation: $GAME_IMPL"
    
    # Get AGGREGATION_VKEY from contract
    VKEY_FROM_CHAIN=$(docker run --rm \
        --network "$DOCKER_NETWORK" \
        "$OP_SUCCINCT_CONTRACTS_IAMGE_TAG" \
        cast call \
          --rpc-url "$L1_RPC_URL_IN_DOCKER" \
          "$GAME_IMPL" \
          'AGGREGATION_VKEY()(bytes32)' 2>/dev/null | tr -d '[:space:]')
    
    if [ -z "$VKEY_FROM_CHAIN" ]; then
        echo "   ⚠️  Failed to read VKey from chain"
    else
        echo "   Chain VKey: $VKEY_FROM_CHAIN"
    fi
fi

# Compare VKeys
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Verification Results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ALL_MATCH=true

# Compare ELF vs Config
if [ "$VKEY_FROM_ELF" = "$VKEY_FROM_CONFIG" ]; then
    echo "✅ ELF ↔ Config:  MATCH"
else
    echo "❌ ELF ↔ Config:  MISMATCH"
    echo "   ELF:    $VKEY_FROM_ELF"
    echo "   Config: $VKEY_FROM_CONFIG"
    ALL_MATCH=false
fi

# Compare Config vs Chain (if available)
if [ -n "$VKEY_FROM_CHAIN" ]; then
    if [ "$VKEY_FROM_CONFIG" = "$VKEY_FROM_CHAIN" ]; then
        echo "✅ Config ↔ Chain: MATCH"
    else
        echo "❌ Config ↔ Chain: MISMATCH"
        echo "   Config: $VKEY_FROM_CONFIG"
        echo "   Chain:  $VKEY_FROM_CHAIN"
        ALL_MATCH=false
    fi
else
    echo "⏭️  Config ↔ Chain: SKIPPED (game not deployed)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$ALL_MATCH" = true ]; then
    echo ""
    echo "✅ All VKeys are consistent!"
    echo ""
    exit 0
else
    echo ""
    echo "❌ VKey mismatch detected!"
    echo ""
    echo "💡 To fix:"
    echo "   1. Run: ./scripts/generate-vkeys.sh"
    echo "   2. Re-deploy contracts with new VKey"
    echo ""
    exit 1
fi



