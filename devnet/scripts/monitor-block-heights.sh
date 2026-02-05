#!/bin/bash

# Script to monitor safe and unsafe block heights
# Usage: ./monitor-block-heights.sh [RPC_URL]
# Default RPC_URL: http://localhost:8123

# Don't exit on error, continue monitoring even if one query fails
set +e

# Get RPC URL from argument or use default
RPC_URL="${1:-http://localhost:8123}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "🔍 Monitoring block heights via: $RPC_URL"
echo "Press Ctrl+C to stop"
echo ""
printf "%-19s %-15s %-15s %-10s\n" "Time" "Safe Height" "Unsafe Height" "Diff"
echo "────────────────────────────────────────────────────────────"

# Function to query block height by tag (safe/latest)
get_block_height() {
    local tag=$1
    # Use cast block which returns decimal number directly
    local result=$(cast block "$tag" --rpc-url "$RPC_URL" 2>/dev/null | grep -E "^number" | awk '{print $2}' 2>/dev/null || echo "0")
    
    # If cast block failed, try direct RPC call and convert hex to decimal
    if [ -z "$result" ] || [ "$result" = "0" ]; then
        local hex_result=$(cast rpc eth_getBlockByNumber "\"$tag\"" false --rpc-url "$RPC_URL" 2>/dev/null | jq -r '.number // empty' 2>/dev/null || echo "")
        if [ -n "$hex_result" ] && [ "$hex_result" != "null" ] && [ "$hex_result" != "" ]; then
            # Convert hex to decimal
            result=$(cast --to-dec "$hex_result" 2>/dev/null || echo "0")
        fi
    fi
    
    # Return result (should be decimal number)
    if [[ "$result" =~ ^[0-9]+$ ]]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Main monitoring loop
while true; do
    # Get current timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Query safe and unsafe heights
    # Note: "latest" represents the unsafe (unconfirmed) head in OP Stack
    safe_height=$(get_block_height "safe")
    unsafe_height=$(get_block_height "latest")
    
    # Calculate difference
    if [ "$safe_height" != "0" ] && [ "$unsafe_height" != "0" ]; then
        diff=$((unsafe_height - safe_height))
        
        # Color code based on diff
        if [ $diff -gt 500 ]; then
            color="${RED}"
        elif [ $diff -gt 300 ]; then
            color="${YELLOW}"
        else
            color="${GREEN}"
        fi
        
        printf "${color}%-19s %-15s %-15s %-10s${NC}\n" "$timestamp" "$safe_height" "$unsafe_height" "$diff"
    else
        printf "${YELLOW}%-19s %-15s %-15s %-10s${NC}\n" "$timestamp" "ERROR" "ERROR" "N/A"
    fi
    
    # Wait 5 seconds
    sleep 5
done
