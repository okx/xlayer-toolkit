#!/usr/bin/env bash
# Generate minimal X Layer genesis.json by removing 'alloc' field
# Usage: ./gen_genesis_xlayer.sh <network>

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

readonly TESTNET_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"
readonly MAINNET_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${SCRIPT_DIR}/.genesis_cache"
TEMP_FILES=()

# ==============================================================================
# Helper Functions
# ==============================================================================

cleanup() {
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        [ -f "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT

die() {
    echo "❌ $*" >&2
    exit 1
}

log() {
    echo "✅ $*"
}

info() {
    echo "$*"
}

# Download file with wget or curl
download() {
    local url=$1 output=$2

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$output" "$url"
    elif command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$output" "$url"
    else
        die "Neither wget nor curl found. Please install one."
    fi
}

# Extract tar.gz and return path to JSON file
extract_genesis() {
    local archive=$1
    local temp_dir=$(mktemp -d)

    tar -xzf "$archive" -C "$temp_dir" 2>/dev/null || {
        rm -rf "$temp_dir"
        die "Failed to extract archive"
    }

    local json=$(find "$temp_dir" -name "*.json" -type f | head -1)
    [ -z "$json" ] && { rm -rf "$temp_dir"; die "No JSON file in archive"; }

    echo "$json"
}

# Verify consistency between two genesis files (excluding alloc)
verify_consistency() {
    local original=$1 minimal=$2

    local temp_orig=$(mktemp) temp_min=$(mktemp)
    TEMP_FILES+=("$temp_orig" "$temp_min")

    # Normalize and sort JSON for comparison
    jq 'del(.alloc) | walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end)' \
        "$original" > "$temp_orig"
    jq 'walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end)' \
        "$minimal" > "$temp_min"

    if ! diff -q "$temp_orig" "$temp_min" &>/dev/null; then
        info "Differences found:"
        diff -u "$temp_orig" "$temp_min" | head -20
        return 1
    fi
    return 0
}

# ==============================================================================
# Main Script
# ==============================================================================

# Parse arguments
[ $# -ne 1 ] && {
    cat <<EOF
Usage: $0 <network>

Arguments:
  network       Network type: mainnet, testnet

Example:
  $0 mainnet
  $0 testnet
EOF
    exit 1
}

NETWORK=$1
[[ "$NETWORK" =~ ^(mainnet|testnet)$ ]] || die "Invalid network: $NETWORK (must be mainnet or testnet)"

# Set network-specific variables
case "$NETWORK" in
    mainnet) GENESIS_URL=$MAINNET_URL ;;
    testnet) GENESIS_URL=$TESTNET_URL ;;
esac

ARCHIVE="${CACHE_DIR}/${NETWORK}.tar.gz"
CACHED_JSON="${CACHE_DIR}/${NETWORK}.genesis.json"
OUTPUT="${SCRIPT_DIR}/genesis/xlayer_${NETWORK}.json"

# Print header
cat <<EOF
=== X Layer Genesis Generator ===

Network: $NETWORK
Cache:   $CACHE_DIR

EOF

# Create cache directory
mkdir -p "$CACHE_DIR"

# Download archive if needed
if [ -f "$ARCHIVE" ]; then
    log "Using cached archive: $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))"
else
    info "📥 Downloading from OSS..."
    download "$GENESIS_URL" "$ARCHIVE" || { rm -f "$ARCHIVE"; die "Download failed"; }
    log "Downloaded: $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))"
fi

# Extract JSON if needed
if [ -f "$CACHED_JSON" ]; then
    log "Using cached JSON: $(basename "$CACHED_JSON") ($(du -h "$CACHED_JSON" | cut -f1))"
else
    info "📦 Extracting archive..."
    EXTRACTED=$(extract_genesis "$ARCHIVE")
    mv "$EXTRACTED" "$CACHED_JSON"
    rm -rf "$(dirname "$EXTRACTED")"
    log "Extracted: $(basename "$CACHED_JSON") ($(du -h "$CACHED_JSON" | cut -f1))"
fi

echo ""

# Process genesis
info "🔧 Processing genesis..."

# Work on a copy
PROCESSING="${CACHED_JSON}.tmp"
cp "$CACHED_JSON" "$PROCESSING"
TEMP_FILES+=("$PROCESSING")

# Update block number from legacyXLayerBlock
LEGACY_BLOCK=$(jq -r '.config.legacyXLayerBlock // "null"' "$PROCESSING")
if [ "$LEGACY_BLOCK" != "null" ]; then
    BLOCK_HEX=$(printf '0x%x' $LEGACY_BLOCK)
    TEMP=$(mktemp)
    TEMP_FILES+=("$TEMP")
    jq ".number = \"$BLOCK_HEX\"" "$PROCESSING" > "$TEMP" && mv "$TEMP" "$PROCESSING"
    info "   Block number: $LEGACY_BLOCK ($BLOCK_HEX)"
fi

# Get stats
CHAIN_ID=$(jq -r '.config.chainId' "$PROCESSING")
SIZE_MB=$(du -m "$PROCESSING" | cut -f1)
ALLOC_COUNT=$(jq '.alloc | length' "$PROCESSING")

info "   Chain ID: $CHAIN_ID, Size: ${SIZE_MB} MB, Alloc: ${ALLOC_COUNT} accounts"

# Generate minimal genesis (remove alloc field only)
mkdir -p "$(dirname "$OUTPUT")"
jq 'del(.alloc)' "$PROCESSING" > "$OUTPUT"

log "Generated: $OUTPUT ($(du -k "$OUTPUT" | cut -f1) KB)"
echo ""

# Verify
info "🔍 Verifying consistency..."
if verify_consistency "$PROCESSING" "$OUTPUT"; then
    log "All fields match (excluding alloc)"
else
    die "Verification failed"
fi

# Summary
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Success!

Generated: $OUTPUT
  - Removed: ${ALLOC_COUNT} accounts (~${SIZE_MB} MB)
  - Clean minimal genesis (no comments)

Cached:
  - Archive: $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f1))
  - JSON:    $(basename "$CACHED_JSON") ($(du -h "$CACHED_JSON" | cut -f1))

Next steps:
  1. Get genesis constants (~40s):
     op-reth --chain $CACHED_JSON node --help 2>&1 | grep -A 10 'GENESIS CONSTANTS'

  2. Copy constants to: src/xlayer_${NETWORK}.rs

💡 Clear cache: rm -rf $CACHE_DIR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
