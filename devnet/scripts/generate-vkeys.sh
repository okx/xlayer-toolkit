#!/bin/bash
set -e

# ============================================================================
# Generate VKeys for OP-Succinct Real Mode
# ============================================================================
# This script generates the verification keys (VKeys) required for real
# SP1 proof verification from the OP-Succinct ELF files.
# ============================================================================

echo "🔑 Generating VKeys for OP-Succinct Real Mode"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if OP_SUCCINCT_DIRECTORY is set
if [ -z "$OP_SUCCINCT_DIRECTORY" ]; then
    echo "❌ Error: OP_SUCCINCT_DIRECTORY is not set"
    echo "   Please set it in your .env file"
    exit 1
fi

if [ ! -d "$OP_SUCCINCT_DIRECTORY" ]; then
    echo "❌ Error: OP_SUCCINCT_DIRECTORY ($OP_SUCCINCT_DIRECTORY) does not exist"
    exit 1
fi

echo "📁 OP-Succinct directory: $OP_SUCCINCT_DIRECTORY"
echo ""

# Check if Docker image is available
if [ -z "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" ]; then
    echo "❌ Error: OP_SUCCINCT_PROPOSER_IMAGE_TAG is not set"
    exit 1
fi

echo "🐳 Using Docker image: $OP_SUCCINCT_PROPOSER_IMAGE_TAG"
echo ""

# Generate VKeys using the config binary
echo "🔧 Running config binary to generate VKeys..."
VKEY_OUTPUT=$(docker run --rm \
    -v "$OP_SUCCINCT_DIRECTORY:/workspace" \
    -w /workspace \
    "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" \
    cargo run --bin config --release 2>&1)

# Check if generation succeeded
if echo "$VKEY_OUTPUT" | grep -q "Error"; then
    echo "❌ Failed to generate VKeys"
    echo "$VKEY_OUTPUT"
    exit 1
fi

echo "$VKEY_OUTPUT"
echo ""

# Extract VKeys from output
AGGREGATION_VKEY=$(echo "$VKEY_OUTPUT" | grep "aggregation_vkey:" | awk '{print $2}' | tr -d '[:space:]')
RANGE_VKEY_COMMITMENT=$(echo "$VKEY_OUTPUT" | grep "range_vkey_commitment:" | awk '{print $2}' | tr -d '[:space:]')
ROLLUP_CONFIG_HASH=$(echo "$VKEY_OUTPUT" | grep "rollup_config_hash:" | awk '{print $2}' | tr -d '[:space:]')

if [ -z "$AGGREGATION_VKEY" ] || [ -z "$RANGE_VKEY_COMMITMENT" ] || [ -z "$ROLLUP_CONFIG_HASH" ]; then
    echo "❌ Failed to extract VKeys from output"
    exit 1
fi

echo "✅ VKeys Generated Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Generated Values:"
echo "   • AGGREGATION_VKEY:      $AGGREGATION_VKEY"
echo "   • RANGE_VKEY_COMMITMENT: $RANGE_VKEY_COMMITMENT"
echo "   • ROLLUP_CONFIG_HASH:    $ROLLUP_CONFIG_HASH"
echo ""

# Update .env.proposer if it exists
ENV_PROPOSER_FILE="$(dirname "$0")/../op-succinct/.env.proposer"

if [ -f "$ENV_PROPOSER_FILE" ]; then
    echo "📝 Updating .env.proposer..."
    
    sed_inplace() {
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
      else
        sed -i "$@"
      fi
    }
    
    sed_inplace "s|^AGGREGATION_VKEY=.*|AGGREGATION_VKEY=$AGGREGATION_VKEY|" "$ENV_PROPOSER_FILE"
    sed_inplace "s|^RANGE_VKEY_COMMITMENT=.*|RANGE_VKEY_COMMITMENT=$RANGE_VKEY_COMMITMENT|" "$ENV_PROPOSER_FILE"
    sed_inplace "s|^ROLLUP_CONFIG_HASH=.*|ROLLUP_CONFIG_HASH=$ROLLUP_CONFIG_HASH|" "$ENV_PROPOSER_FILE"
    
    echo "✅ Updated .env.proposer"
else
    echo "⚠️  .env.proposer not found, skipping update"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ VKey Generation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "💡 Next Steps:"
echo "   1. Verify the VKeys are correct"
echo "   2. Update your .env.proposer with these values if not done automatically"
echo "   3. Deploy contracts with: ./scripts/deploy-op-succinct.sh"
echo ""



