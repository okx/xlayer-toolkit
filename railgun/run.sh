#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============ CONFIGURATION ============
# Set to 'true' to use locally compiled circuits
# Set to 'false' to use IPFS circuits (default)
export USE_LOCAL_CIRCUITS=true
# =======================================

echo "=========================================="
echo "🚀 Railgun Demo Setup"
echo "=========================================="
echo "USE_LOCAL_CIRCUITS=$USE_LOCAL_CIRCUITS"
echo ""

# Step 1: Build circuits if using local
if [ "$USE_LOCAL_CIRCUITS" = "true" ]; then
    echo "📦 Building local circuits..."
    ./build-circuits-v2.sh
    echo ""
fi

# Step 2: Clone and patch contract
if [ ! -d "$SCRIPT_DIR/contract" ]; then
    echo "📥 Cloning contract repository..."
    cd "$SCRIPT_DIR"
    git clone https://github.com/Railgun-Privacy/contract.git
    cd contract
    
    echo "🔧 Applying patches..."
    git apply ../0001-add-railgun-demo.patch
    echo "  ✅ Applied 0001-add-railgun-demo.patch"
    
    git apply ../0002-add-local-circuits-support.patch
    echo "  ✅ Applied 0002-add-local-circuits-support.patch"
else
    echo "📁 Contract directory already exists"
    cd "$SCRIPT_DIR/contract"
fi

# Step 3: Run contract demo
echo ""
echo "🚀 Running contract demo..."
./run.sh
