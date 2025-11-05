#!/bin/bash

# Verify Empty Block Bug - Test eth_getBlockReceipts on empty blocks
# This script tests if Reth has the same bug as op-geth PR #125

RETH_URL="${1:-http://localhost:8545}"
CUTOFF_BLOCK="42810021"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Empty Block Bug Verification${NC}"
echo -e "${BLUE}Testing: op-geth PR #125 equivalent${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# RPC call helper
rpc_call() {
    local method=$1
    local params=$2
    curl -s -X POST "$RETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
}

# Test empty block
test_empty_block() {
    local block_num=$1
    local block_hex=$(printf "0x%x" $block_num)
    
    echo -e "${BLUE}Testing block $block_num ($block_hex)...${NC}"
    
    # 1. Check if block exists
    block_response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",false]")
    if ! echo "$block_response" | jq -e '.result' > /dev/null 2>&1; then
        echo -e "${YELLOW}  ⚠️  Block not found, skipping${NC}"
        return
    fi
    
    # 2. Get transaction count
    tx_count=$(echo "$block_response" | jq -r '.result.transactions | length')
    echo -e "  Transaction count: $tx_count"
    
    if [ "$tx_count" -ne 0 ]; then
        echo -e "${YELLOW}  ⚠️  Not an empty block, skipping${NC}"
        return
    fi
    
    echo -e "${GREEN}  ✓ Empty block confirmed${NC}"
    
    # 3. Test eth_getBlockReceipts
    echo -e "\n  Testing eth_getBlockReceipts..."
    receipts_response=$(rpc_call "eth_getBlockReceipts" "[\"$block_hex\"]")
    
    # Check for error
    if echo "$receipts_response" | jq -e '.error' > /dev/null 2>&1; then
        error_msg=$(echo "$receipts_response" | jq -r '.error.message')
        echo -e "${RED}  ✗ BUG DETECTED!${NC}"
        echo -e "${RED}    Error: $error_msg${NC}"
        echo -e "    Full response: $(echo "$receipts_response" | jq -c .)"
        echo ""
        echo -e "${YELLOW}  This is the same bug as op-geth PR #125!${NC}"
        echo -e "${YELLOW}  Empty blocks should return [] not an error.${NC}"
        return 1
    fi
    
    # Check for empty array
    if echo "$receipts_response" | jq -e '.result' > /dev/null 2>&1; then
        result_type=$(echo "$receipts_response" | jq -r '.result | type')
        result_length=$(echo "$receipts_response" | jq -r '.result | length')
        
        if [ "$result_type" = "array" ] && [ "$result_length" -eq 0 ]; then
            echo -e "${GREEN}  ✓ CORRECT: Returns empty array []${NC}"
            echo -e "${GREEN}  ✓ Bug is FIXED!${NC}"
            return 0
        else
            echo -e "${RED}  ✗ Unexpected result:${NC}"
            echo -e "    Type: $result_type, Length: $result_length"
            echo -e "    Response: $(echo "$receipts_response" | jq -c .)"
            return 1
        fi
    fi
    
    echo -e "${RED}  ✗ Invalid response format${NC}"
    echo -e "    Response: $(echo "$receipts_response" | jq -c .)"
    return 1
}

echo -e "${BLUE}Searching for empty blocks near cutoff...${NC}\n"

# Test known empty block (cutoff block)
BOUNDARY_BLOCK_HEX=$(printf "0x%x" $CUTOFF_BLOCK)
echo -e "${BLUE}Test 1: Known empty block (cutoff: $CUTOFF_BLOCK)${NC}"
test_empty_block $CUTOFF_BLOCK
test1_result=$?

# Test nearby blocks
echo -e "\n${BLUE}Test 2: Cutoff-1 block${NC}"
test_empty_block $((CUTOFF_BLOCK - 1))
test2_result=$?

echo -e "\n${BLUE}Test 3: Cutoff+1 block${NC}"
test_empty_block $((CUTOFF_BLOCK + 1))
test3_result=$?

# Scan for more empty blocks
echo -e "\n${BLUE}Scanning for empty blocks in range...${NC}"
empty_blocks_found=0
bugs_found=0

for offset in $(seq 2 100); do
    block_num=$((CUTOFF_BLOCK - offset))
    block_hex=$(printf "0x%x" $block_num)
    
    # Quick check for empty block
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",false]")
    tx_count=$(echo "$response" | jq -r '.result.transactions | length' 2>/dev/null)
    
    if [ "$tx_count" = "0" ]; then
        empty_blocks_found=$((empty_blocks_found + 1))
        echo -e "\n${BLUE}Test 4+: Empty block found at $block_num${NC}"
        test_empty_block $block_num
        if [ $? -ne 0 ]; then
            bugs_found=$((bugs_found + 1))
        fi
        
        # Limit tests to avoid spam
        if [ $empty_blocks_found -ge 5 ]; then
            break
        fi
    fi
done

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Empty blocks tested: $((empty_blocks_found + 3))"
echo -e "Bugs detected: $bugs_found"

if [ $bugs_found -gt 0 ]; then
    echo -e "\n${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ BUG CONFIRMED                       ║${NC}"
    echo -e "${RED}║  Same issue as op-geth PR #125         ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Recommended fix in crates/optimism/rpc/src/eth/receipt.rs:${NC}"
    echo ""
    echo "  fn convert_receipts_with_block(...) -> Result<...> {"
    echo "      // Add this at the beginning:"
    echo "      if inputs.is_empty() {"
    echo "          return Ok(vec![]);"
    echo "      }"
    echo "      // ... rest of the function"
    echo "  }"
    echo ""
    exit 1
else
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ NO BUGS FOUND                       ║${NC}"
    echo -e "${GREEN}║  Empty blocks handled correctly        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    exit 0
fi

