#!/bin/bash
set -e

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/.env"

sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
    else
    sed -i "$@"
    fi
}

# ============================================================================
# Generate VKeys for OP-Succinct Real Mode
# ============================================================================
# This script generates the verification keys (VKeys) required for real
# SP1 proof verification from the OP-Succinct ELF files.
# ============================================================================

# Check if OP_SUCCINCT_LOCAL_DIRECTORY is set
if [ -z "$OP_SUCCINCT_LOCAL_DIRECTORY" ]; then
    echo "❌ Error: OP_SUCCINCT_LOCAL_DIRECTORY is not set"
    exit 1
fi

# Check if Docker image is available
if [ -z "$OP_SUCCINCT_PROPOSER_IMAGE_TAG" ]; then
    echo "❌ Error: OP_SUCCINCT_PROPOSER_IMAGE_TAG is not set"
    exit 1
fi

# Generate VKeys using the config binary
echo "🔧 Generating VKeys..."

PROPOSER_ENV="$PROJECT_DIR/op-succinct/.env.proposer"
CONFIGS_DIR="$PROJECT_DIR/op-succinct/configs"

VKEY_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$PROPOSER_ENV:/.env.proposer" \
    -v "$CONFIGS_DIR:/usr/src/app/configs" \
    -v op-succinct-target:/usr/src/app/target \
    "$OP_SUCCINCT_BUILDER_IMAGE_TAG" \
    cargo run --bin config --release -- --env-file /.env.proposer)

echo "VKEY_OUTPUT: $VKEY_OUTPUT"

# Check if generation succeeded
if echo "$VKEY_OUTPUT" | grep -q "Error"; then
    echo "❌ Failed to generate VKeys"
    echo "$VKEY_OUTPUT"
    exit 1
fi

# Extract VKeys from output
RANGE_VKEY_COMMITMENT=$(echo "$VKEY_OUTPUT" | grep "Range Verification Key Hash:" | awk '{print $5}' | tr -d '[:space:]')
AGGREGATION_VKEY=$(echo "$VKEY_OUTPUT" | grep "Aggregation Verification Key Hash:" | awk '{print $5}' | tr -d '[:space:]')
ROLLUP_CONFIG_HASH=$(echo "$VKEY_OUTPUT" | grep "Rollup Config Hash:" | awk '{print $4}' | tr -d '[:space:]')

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

if [ -f "$PROPOSER_ENV" ]; then
    sed_inplace "s|^AGGREGATION_VKEY=.*|AGGREGATION_VKEY=$AGGREGATION_VKEY|" "$PROPOSER_ENV"
    sed_inplace "s|^RANGE_VKEY_COMMITMENT=.*|RANGE_VKEY_COMMITMENT=$RANGE_VKEY_COMMITMENT|" "$PROPOSER_ENV"
    sed_inplace "s|^ROLLUP_CONFIG_HASH=.*|ROLLUP_CONFIG_HASH=$ROLLUP_CONFIG_HASH|" "$PROPOSER_ENV"
    echo "✅ VKeys generated and updated in .env.proposer"
else
    echo "⚠️  .env.proposer not found, skipping update"
fi



