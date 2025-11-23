#!/bin/bash
# Sync contract addresses from optimism/test to xlayer-toolkit/devnet
set -e

echo "🔄 Syncing contract addresses from optimism/test..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Source and destination paths
SOURCE_ENV="/data1/ericqin/optimism/test/.env"
DEST_ENV="/data1/ericqin/xlayer-toolkit/devnet/.env"

if [ ! -f "$SOURCE_ENV" ]; then
    echo "❌ Error: Source .env not found at $SOURCE_ENV"
    exit 1
fi

if [ ! -f "$DEST_ENV" ]; then
    echo "❌ Error: Destination .env not found at $DEST_ENV"
    exit 1
fi

# Function to sync a variable
sync_var() {
    local var_name=$1
    local source_value=$(grep "^${var_name}=" "$SOURCE_ENV" | cut -d'=' -f2-)
    
    if [ -n "$source_value" ]; then
        if grep -q "^${var_name}=" "$DEST_ENV"; then
            # Update existing variable
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^${var_name}=.*|${var_name}=${source_value}|" "$DEST_ENV"
            else
                sed -i "s|^${var_name}=.*|${var_name}=${source_value}|" "$DEST_ENV"
            fi
            echo "   ✓ Updated $var_name"
        else
            # Add new variable
            echo "${var_name}=${source_value}" >> "$DEST_ENV"
            echo "   ✓ Added $var_name"
        fi
    else
        echo "   ⚠️  $var_name not found in source"
    fi
}

# Sync critical contract addresses
echo "📝 Syncing contract addresses..."
sync_var "DISPUTE_GAME_FACTORY_ADDRESS"
sync_var "OPTIMISM_PORTAL_PROXY_ADDRESS"
sync_var "ANCHOR_STATE_REGISTRY"
sync_var "TRANSACTOR"
sync_var "L2OO_PROXY"
sync_var "DELAYED_WETH"
sync_var "PREIMAGE_ORACLE"
sync_var "MIPS_ADDRESS"

echo ""
echo "✅ Sync complete!"
echo ""
echo "📋 Synced addresses:"
grep -E "^(DISPUTE_GAME_FACTORY_ADDRESS|OPTIMISM_PORTAL_PROXY_ADDRESS|ANCHOR_STATE_REGISTRY)=" "$DEST_ENV" | sed 's/^/   /'

