#!/bin/bash

# Test script for flashblocks subscription
# This script connects to the WebSocket endpoint and monitors flashblocks

WS_URL="${WS_URL:-ws://localhost:7547}"
LAST_BLOCK_NUM=""
BLOCK_HISTORY=()
MAX_HISTORY=10

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' 

echo "Connecting to $WS_URL..."
echo "Monitoring flashblocks subscription..."
echo "---"

# Check if wscat is available
if ! command -v wscat &> /dev/null; then
    echo -e "${RED}Error: wscat is not installed${NC}"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    exit 1
fi

check_block_progression() {
    local current_block_hex="$1"
    local current_block_num=$((current_block_hex))

    if [ -z "$LAST_BLOCK_NUM" ]; then
        LAST_BLOCK_NUM=$current_block_num
        BLOCK_HISTORY=($current_block_num)
        echo -e "${GREEN}First block received: $current_block_num (0x$(printf '%x' $current_block_num))${NC}"
        echo -e "Monitoring block progression, will report if block number is missed..."
        return
    fi

    if [ $current_block_num -gt $LAST_BLOCK_NUM ]; then
        local diff=$((current_block_num - LAST_BLOCK_NUM))
        
        if [ $diff -gt 1 ]; then
            echo -e "${RED}ERROR: Missed $(($diff - 1)) block(s)! Jumped from $LAST_BLOCK_NUM to $current_block_num${NC}"
        fi
        
        if [ $diff -eq 1 ] && [ ${#BLOCK_HISTORY[@]} -gt 0 ]; then
            local had_repeat=false
            for ((i=${#BLOCK_HISTORY[@]}-1; i>=0; i--)); do
                if [ ${BLOCK_HISTORY[$i]} -eq $LAST_BLOCK_NUM ]; then
                    local count=0
                    for block in "${BLOCK_HISTORY[@]}"; do
                        if [ $block -eq $LAST_BLOCK_NUM ]; then
                            count=$((count + 1))
                        fi
                    done
                    if [ $count -gt 1 ]; then
                        had_repeat=true
                        break
                    fi
                fi
            done
            
            if [ "$had_repeat" = false ]; then
                echo -e "${YELLOW}WARNING: Block $LAST_BLOCK_NUM was not repeated (flashblocks should typically have repeats)${NC}"
            fi
        fi
        
        LAST_BLOCK_NUM=$current_block_num
    # Uncomment to check for block number repetition
    # elif [ $current_block_num -eq $LAST_BLOCK_NUM ]; then
    #     echo "  Block: $current_block_num (0x$(printf '%x' $current_block_num)) [repeat - OK]"
    fi

    # Add to history and maintain max size
    BLOCK_HISTORY+=($current_block_num)
    if [ ${#BLOCK_HISTORY[@]} -gt $MAX_HISTORY ]; then
        BLOCK_HISTORY=("${BLOCK_HISTORY[@]:1}")
    fi
}

wscat -c "$WS_URL" \
    -x '{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["flashblocks",{"headerInfo":true}]}' \
    --no-color \
    -w -1 2>&1 | while IFS= read -r line; do

    if echo "$line" | jq -e '.result' > /dev/null 2>&1 && ! echo "$line" | jq -e '.params' > /dev/null 2>&1; then
        subscription_id=$(echo "$line" | jq -r '.result')
        echo -e "${GREEN}Subscription ID: $subscription_id${NC}"
        echo "---"
        continue
    fi

    if echo "$line" | jq -e '.params.result.header.number' > /dev/null 2>&1; then
        block_number_hex=$(echo "$line" | jq -r '.params.result.header.number')
        tx_count=$(echo "$line" | jq -r '.params.result.transactions | length')
        block_hash=$(echo "$line" | jq -r '.params.result.header.hash')
        timestamp_hex=$(echo "$line" | jq -r '.params.result.header.timestamp')
        timestamp=$((timestamp_hex))

        check_block_progression "$block_number_hex"
    elif echo "$line" | jq -e '.error' > /dev/null 2>&1; then
        error_msg=$(echo "$line" | jq -r '.error.message')
        echo -e "${RED}Error: $error_msg${NC}"
        exit 1
    fi
done
