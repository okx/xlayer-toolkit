#!/bin/bash
# build-prestate.sh - Standalone OP Stack prestate builder
set -euo pipefail

# Usage
usage() {
    cat << EOF
# Mainnet (auto-download genesis to current dir)
$0 --l2-rollup mainnet-rollup.json --output-dir ./mainnet-output --image op-stack:latest

# Testnet (auto-download genesis to current dir)
$0 --l2-rollup testnet-rollup.json --output-dir ./testnet-output --image op-stack:latest

# Devnet (manual genesis required)
$0 --l2-rollup rollup.json --l2-genesis genesis.json.gz --l1-genesis l1-genesis.json --output-dir ./devnet-output --image op-stack:latest
EOF
    exit 1
}

# Get devnet scripts directory (for docker-install-start.sh)
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$CURRENT_DIR/../../devnet/scripts" && pwd)"

# Parse arguments
L2_ROLLUP=""
L2_GENESIS=""
L1_GENESIS=""
OUTPUT_DIR=""
IMAGE_TAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --l2-rollup) L2_ROLLUP="$2"; shift 2 ;;
        --l2-genesis) L2_GENESIS="$2"; shift 2 ;;
        --l1-genesis) L1_GENESIS="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --image) IMAGE_TAG="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

# Validate required arguments
[[ -z "$L2_ROLLUP" ]] && echo "Error: --l2-rollup required" && usage
[[ -z "$OUTPUT_DIR" ]] && echo "Error: --output-dir required" && usage
[[ -z "$IMAGE_TAG" ]] && echo "Error: --image required" && usage

# Validate files exist
[[ ! -f "$L2_ROLLUP" ]] && echo "Error: L2 rollup not found: $L2_ROLLUP" && exit 1
[[ ! -f "$SCRIPTS_DIR/docker-install-start.sh" ]] && echo "Error: docker-install-start.sh not found in $SCRIPTS_DIR" && exit 1

# Validate L2 genesis if provided manually
if [[ -n "$L2_GENESIS" && ! -f "$L2_GENESIS" ]]; then
    echo "Error: L2 genesis not found: $L2_GENESIS"
    exit 1
fi

# Validate L1 genesis if provided
if [[ -n "$L1_GENESIS" && ! -f "$L1_GENESIS" ]]; then
    echo "Error: L1 genesis not found: $L1_GENESIS"
    exit 1
fi

# Extract CHAIN_ID
if command -v jq &> /dev/null; then
    CHAIN_ID=$(jq -r '.l2_chain_id' "$L2_ROLLUP")
else
    CHAIN_ID=$(grep -o '"l2_chain_id"[[:space:]]*:[[:space:]]*[0-9]*' "$L2_ROLLUP" | grep -o '[0-9]*$')
fi
[[ -z "$CHAIN_ID" || "$CHAIN_ID" == "null" ]] && echo "Error: Failed to extract CHAIN_ID" && exit 1

# Auto-download genesis for mainnet/testnet if not provided
if [[ -z "$L2_GENESIS" ]]; then
    case $CHAIN_ID in
        196)
            NETWORK="mainnet"
            GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz"
            ;;
        1952)
            NETWORK="testnet"
            GENESIS_URL="https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz"
            ;;
        *)
            echo "Error: --l2-genesis required for custom chain (chain_id: $CHAIN_ID)"
            exit 1
            ;;
    esac

    # Setup cache directory (current directory)
    CACHE_DIR="$(pwd)"
    
    CACHE_TAR="$CACHE_DIR/genesis-${NETWORK}.tar.gz"
    CACHE_GZ="$CACHE_DIR/genesis-${NETWORK}.json.gz"

    if [[ -f "$CACHE_GZ" ]]; then
        echo "✓ Using cached genesis: $CACHE_GZ"
        CACHE_SIZE=$(du -h "$CACHE_GZ" | cut -f1)
        CACHE_DATE=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$CACHE_GZ" 2>/dev/null || date -r "$CACHE_GZ" "+%Y-%m-%d %H:%M" 2>/dev/null)
        echo "  Size: $CACHE_SIZE, Date: $CACHE_DATE"
        L2_GENESIS="$CACHE_GZ"
    else
        # Download tar.gz if not cached
        if [[ ! -f "$CACHE_TAR" ]]; then
            echo "Downloading ${NETWORK} genesis from OSS..."
            echo "  URL: $GENESIS_URL"
            if command -v pv &> /dev/null; then
                curl -L "$GENESIS_URL" | pv -N "Download" > "$CACHE_TAR"
            else
                curl -L -# -o "$CACHE_TAR" "$GENESIS_URL"
            fi
            
            if [[ ! -f "$CACHE_TAR" || ! -s "$CACHE_TAR" ]]; then
                echo "Error: Download failed"
                exit 1
            fi
            echo "✓ Downloaded to: $CACHE_TAR"
        else
            echo "✓ Using cached tar.gz: $CACHE_TAR"
        fi

        # Convert tar.gz to json.gz
        echo "Converting format: tar.gz → json.gz..."
        if command -v pv &> /dev/null; then
            tar -xzOf "$CACHE_TAR" merged.genesis.json | pv -N "Convert" | gzip > "$CACHE_GZ"
        else
            tar -xzOf "$CACHE_TAR" merged.genesis.json | gzip > "$CACHE_GZ"
        fi
        
        if [[ ! -f "$CACHE_GZ" || ! -s "$CACHE_GZ" ]]; then
            echo "Error: Format conversion failed"
            exit 1
        fi
        echo "✓ Converted to: $CACHE_GZ"
        
        L2_GENESIS="$CACHE_GZ"
    fi
    
    echo ""
fi

# Detect Docker type
if docker info -f "{{println .SecurityOptions}}" 2>/dev/null | grep -q rootless; then
    DOCKER_TYPE="rootless"
    DOCKER_CMD="docker run --rm --privileged"
else
    DOCKER_TYPE="default"
    DOCKER_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock"
fi

# Convert to absolute paths
[[ ! "$L2_ROLLUP" = /* ]] && L2_ROLLUP="$(cd "$(dirname "$L2_ROLLUP")" && pwd)/$(basename "$L2_ROLLUP")"
[[ ! "$L2_GENESIS" = /* ]] && L2_GENESIS="$(cd "$(dirname "$L2_GENESIS")" && pwd)/$(basename "$L2_GENESIS")"
if [[ -n "$L1_GENESIS" && ! "$L1_GENESIS" = /* ]]; then
    L1_GENESIS="$(cd "$(dirname "$L1_GENESIS")" && pwd)/$(basename "$L1_GENESIS")"
fi
mkdir -p "$OUTPUT_DIR" && OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Check and clean output directory
if [[ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
    echo "⚠️  WARNING: $OUTPUT_DIR not empty ($(ls -A "$OUTPUT_DIR" | wc -l | xargs) files) - Cleaning in 3s (Ctrl+C to cancel)..."
    sleep 3 && rm -rf "$OUTPUT_DIR"/* && echo "✓ Cleaned"
fi

# Build
echo "Building prestate..."
echo "  Docker: $DOCKER_TYPE"
echo "  Image: $IMAGE_TAG"
echo "  CHAIN_ID: $CHAIN_ID"
echo "  Output: $OUTPUT_DIR"
echo ""

# Build Docker volume arguments
DOCKER_VOLUMES="-v $SCRIPTS_DIR:/scripts"
DOCKER_VOLUMES="$DOCKER_VOLUMES -v $L2_ROLLUP:/app/op-program/chainconfig/configs/${CHAIN_ID}-rollup.json"
DOCKER_VOLUMES="$DOCKER_VOLUMES -v $L2_GENESIS:/app/op-program/chainconfig/configs/${CHAIN_ID}-genesis-l2.json"
DOCKER_VOLUMES="$DOCKER_VOLUMES -v $OUTPUT_DIR:/app/op-program/bin"

# Add L1 genesis if provided
if [[ -n "$L1_GENESIS" ]]; then
    # Extract L1 chain ID from rollup.json
    if command -v jq &> /dev/null; then
        L1_CHAIN_ID=$(jq -r '.l1_chain_id' "$L2_ROLLUP")
    else
        L1_CHAIN_ID=$(grep -o '"l1_chain_id"[[:space:]]*:[[:space:]]*[0-9]*' "$L2_ROLLUP" | grep -o '[0-9]*$')
    fi
    DOCKER_VOLUMES="$DOCKER_VOLUMES -v $L1_GENESIS:/app/op-program/chainconfig/configs/${L1_CHAIN_ID}-genesis-l1.json"
    echo "  L1 Chain ID: $L1_CHAIN_ID (custom genesis provided)"
fi

$DOCKER_CMD $DOCKER_VOLUMES "${IMAGE_TAG}" \
    bash -c "/scripts/docker-install-start.sh $DOCKER_TYPE && make -C op-program reproducible-prestate"

# Results
if [[ ! -f "$OUTPUT_DIR/prestate-mt64.bin.gz" ]]; then
    echo "Error: Build failed - output files not found"
    exit 1
fi

VERSION=$(gunzip -c "$OUTPUT_DIR/prestate-mt64.bin.gz" 2>/dev/null | od -An -t u1 -N 1 | xargs || echo "N/A")

if command -v jq &> /dev/null && [[ -f "$OUTPUT_DIR/prestate-proof-mt64.json" ]]; then
    HASH=$(jq -r '.pre' "$OUTPUT_DIR/prestate-proof-mt64.json" 2>/dev/null || echo "N/A")
else
    HASH="N/A"
fi

echo ""
echo "Build completed successfully!"
echo "  Version: v${VERSION}"
echo "  Hash: ${HASH}"
echo "  Output: $OUTPUT_DIR"
echo ""
ls -lh "$OUTPUT_DIR" | tail -n +2 | awk '{printf "  %s  %s\n", $5, $9}'
