#!/bin/bash

# Smart Test Data Scanner for XLayer Legacy RPC
# Automatically finds blocks with real data for comprehensive testing
# ⚠️  Rate limited to avoid API throttling

CUTOFF_BLOCK="42810021"
RETH_URL="${1:-http://localhost:8545}"

# Rate limiting (adjust if needed)
REQUEST_DELAY=0.5  # 500ms between requests (2 req/sec)
BATCH_DELAY=2      # 2s after every 10 requests

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Results storage
declare -a LOCAL_BLOCKS_WITH_LOGS
declare -a LOCAL_BLOCKS_WITH_TXS
declare -a CONTRACT_ADDRESSES
declare -a ACTIVE_EOAS

REQUEST_COUNT=0

echo -e "${CYAN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  XLayer Test Data Scanner                      ║${NC}"
echo -e "${CYAN}║  Rate Limited: ${REQUEST_DELAY}s delay between requests   ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════╝${NC}"
echo ""

# RPC call with rate limiting
rpc_call() {
    local method=$1
    local params=$2
    
    REQUEST_COUNT=$((REQUEST_COUNT + 1))
    
    # Batch delay every 10 requests
    if [ $((REQUEST_COUNT % 10)) -eq 0 ]; then
        echo -e "${YELLOW}  [Rate Limit] Batch pause...${NC}"
        sleep $BATCH_DELAY
    else
        sleep $REQUEST_DELAY
    fi
    
    curl -s -X POST "$RETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
}

# Progress indicator
print_progress() {
    echo -ne "${BLUE}$1${NC}\r"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Phase 1: Scanning Local Blocks${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Looking for blocks after cutoff (≥$CUTOFF_BLOCK) with logs..."
echo -e "Target: Find 3 blocks with logs"
echo ""

# Scan local blocks (after cutoff)
# Strategy: Check every 50 blocks to find candidates quickly
SCAN_START=$((CUTOFF_BLOCK + 100))
SCAN_END=$((CUTOFF_BLOCK + 10000))
SCAN_STEP=50

local_blocks_found=0

block_num=$SCAN_START
while [ $block_num -le $SCAN_END ]; do
    print_progress "  Scanning block $block_num..."
    
    block_hex=$(printf "0x%x" $block_num)
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",false]")
    
    # Check if block has transactions
    if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        tx_count=$(echo "$response" | jq -r '.result.transactions | length')
        
        if [ "$tx_count" -gt 0 ]; then
            # Get receipts to check for logs
            receipts_response=$(rpc_call "eth_getBlockReceipts" "[\"$block_hex\"]")
            
            if echo "$receipts_response" | jq -e '.result' > /dev/null 2>&1; then
                log_count=0
                receipts=$(echo "$receipts_response" | jq -r '.result')
                
                # Count total logs
                for i in $(seq 0 $((tx_count - 1))); do
                    receipt_logs=$(echo "$receipts" | jq -r ".[$i].logs | length")
                    log_count=$((log_count + receipt_logs))
                done
                
                if [ "$log_count" -gt 0 ]; then
                    echo -e "${GREEN}✓ Found: Block $block_num - $tx_count txs, $log_count logs${NC}"
                    LOCAL_BLOCKS_WITH_LOGS+=("$block_num:$tx_count:$log_count")
                    local_blocks_found=$((local_blocks_found + 1))
                    
                    # Stop after finding 3 blocks
                    if [ $local_blocks_found -ge 3 ]; then
                        echo -e "${GREEN}  → Found enough local blocks with logs!${NC}"
                        break
                    fi
                fi
            fi
        fi
    fi
    
    block_num=$((block_num + SCAN_STEP))
done

if [ $local_blocks_found -eq 0 ]; then
    echo -e "${RED}✗ No local blocks with logs found${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Phase 2: Cross-Boundary Scan${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Looking for blocks near cutoff with logs..."
echo ""

# Scan legacy side (before cutoff)
echo -e "${BLUE}Scanning legacy side (cutoff - 500 to cutoff - 50)...${NC}"
LEGACY_BOUNDARY_START=$((CUTOFF_BLOCK - 500))
LEGACY_BOUNDARY_END=$((CUTOFF_BLOCK - 50))
LEGACY_SCAN_STEP=20

legacy_found=""

block_num=$LEGACY_BOUNDARY_START
while [ $block_num -le $LEGACY_BOUNDARY_END ]; do
    print_progress "  Scanning legacy block $block_num..."
    
    block_hex=$(printf "0x%x" $block_num)
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",false]")
    
    if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        tx_count=$(echo "$response" | jq -r '.result.transactions | length')
        
        if [ "$tx_count" -gt 0 ]; then
            # Quick check for logs by getting block receipts
            receipts_response=$(rpc_call "eth_getBlockReceipts" "[\"$block_hex\"]")
            
            if echo "$receipts_response" | jq -e '.result' > /dev/null 2>&1; then
                log_count=0
                receipts=$(echo "$receipts_response" | jq -r '.result')
                
                for i in $(seq 0 $((tx_count - 1))); do
                    receipt_logs=$(echo "$receipts" | jq -r ".[$i].logs | length")
                    log_count=$((log_count + receipt_logs))
                done
                
                if [ "$log_count" -gt 0 ]; then
                    echo -e "${GREEN}✓ Legacy boundary: Block $block_num - $tx_count txs, $log_count logs${NC}"
                    legacy_found="$block_num"
                    break
                fi
            fi
        fi
    fi
    
    block_num=$((block_num + LEGACY_SCAN_STEP))
done

# Scan local side (after cutoff)
echo -e "${BLUE}Scanning local side (cutoff + 50 to cutoff + 500)...${NC}"
LOCAL_BOUNDARY_START=$((CUTOFF_BLOCK + 50))
LOCAL_BOUNDARY_END=$((CUTOFF_BLOCK + 500))
LOCAL_SCAN_STEP=20

local_found=""

block_num=$LOCAL_BOUNDARY_START
while [ $block_num -le $LOCAL_BOUNDARY_END ]; do
    print_progress "  Scanning local block $block_num..."
    
    block_hex=$(printf "0x%x" $block_num)
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",false]")
    
    if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        tx_count=$(echo "$response" | jq -r '.result.transactions | length')
        
        if [ "$tx_count" -gt 0 ]; then
            receipts_response=$(rpc_call "eth_getBlockReceipts" "[\"$block_hex\"]")
            
            if echo "$receipts_response" | jq -e '.result' > /dev/null 2>&1; then
                log_count=0
                receipts=$(echo "$receipts_response" | jq -r '.result')
                
                for i in $(seq 0 $((tx_count - 1))); do
                    receipt_logs=$(echo "$receipts" | jq -r ".[$i].logs | length")
                    log_count=$((log_count + receipt_logs))
                done
                
                if [ "$log_count" -gt 0 ]; then
                    echo -e "${GREEN}✓ Local boundary: Block $block_num - $tx_count txs, $log_count logs${NC}"
                    local_found="$block_num"
                    break
                fi
            fi
        fi
    fi
    
    block_num=$((block_num + LOCAL_SCAN_STEP))
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Phase 3: Finding Contract Addresses${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Looking for deployed contracts..."
echo ""

# Strategy: Check transactions from blocks we already found
contracts_found=0

# Check first local block with logs
if [ ${#LOCAL_BLOCKS_WITH_LOGS[@]} -gt 0 ]; then
    first_block=$(echo "${LOCAL_BLOCKS_WITH_LOGS[0]}" | cut -d':' -f1)
    block_hex=$(printf "0x%x" $first_block)
    
    echo -e "${BLUE}Checking block $first_block for contracts...${NC}"
    
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",true]")
    
    if echo "$response" | jq -e '.result.transactions' > /dev/null 2>&1; then
        tx_count=$(echo "$response" | jq -r '.result.transactions | length')
        
        for i in $(seq 0 $((tx_count - 1))); do
            to=$(echo "$response" | jq -r ".result.transactions[$i].to")
            
            if [ "$to" != "null" ] && [ "$to" != "0x0000000000000000000000000000000000000000" ]; then
                # Check if it's a contract
                code_response=$(rpc_call "eth_getCode" "[\"$to\",\"$block_hex\"]")
                code=$(echo "$code_response" | jq -r '.result')
                
                if [ "$code" != "0x" ] && [ "$code" != "null" ]; then
                    code_length=${#code}
                    echo -e "${GREEN}✓ Contract found: $to (code: $code_length bytes)${NC}"
                    CONTRACT_ADDRESSES+=("$to:$first_block")
                    contracts_found=$((contracts_found + 1))
                    
                    if [ $contracts_found -ge 2 ]; then
                        break
                    fi
                fi
            fi
        done
    fi
fi

if [ $contracts_found -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No contracts found in scanned blocks${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Phase 4: Finding Active EOA Addresses${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Looking for addresses with transaction history..."
echo ""

# Strategy: Find addresses with nonce > 0
eoa_found=0

if [ ${#LOCAL_BLOCKS_WITH_LOGS[@]} -gt 0 ]; then
    first_block=$(echo "${LOCAL_BLOCKS_WITH_LOGS[0]}" | cut -d':' -f1)
    block_hex=$(printf "0x%x" $first_block)
    
    echo -e "${BLUE}Checking transactions for active EOAs...${NC}"
    
    response=$(rpc_call "eth_getBlockByNumber" "[\"$block_hex\",true]")
    
    if echo "$response" | jq -e '.result.transactions' > /dev/null 2>&1; then
        tx_count=$(echo "$response" | jq -r '.result.transactions | length')
        
        for i in $(seq 0 $((tx_count - 1))); do
            from=$(echo "$response" | jq -r ".result.transactions[$i].from")
            
            if [ "$from" != "null" ]; then
                # Check nonce
                nonce_response=$(rpc_call "eth_getTransactionCount" "[\"$from\",\"$block_hex\"]")
                nonce=$(echo "$nonce_response" | jq -r '.result')
                nonce_dec=$(printf "%d" $nonce)
                
                if [ $nonce_dec -gt 0 ]; then
                    echo -e "${GREEN}✓ Active EOA: $from (nonce: $nonce_dec)${NC}"
                    ACTIVE_EOAS+=("$from:$first_block:$nonce_dec")
                    eoa_found=$((eoa_found + 1))
                    
                    if [ $eoa_found -ge 2 ]; then
                        break
                    fi
                fi
            fi
        done
    fi
fi

if [ $eoa_found -eq 0 ]; then
    echo -e "${YELLOW}⚠️  No active EOAs found${NC}"
fi

# ========================================
# Summary and Output
# ========================================

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Scan Complete!                                ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Total API requests made: $REQUEST_COUNT${NC}"
echo ""

# Generate configuration
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}📋 Suggested Configuration for test_legacy_rpc.sh${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ ${#LOCAL_BLOCKS_WITH_LOGS[@]} -gt 0 ]; then
    echo -e "${CYAN}# Local blocks with logs${NC}"
    first_local=$(echo "${LOCAL_BLOCKS_WITH_LOGS[0]}" | cut -d':' -f1)
    first_local_txs=$(echo "${LOCAL_BLOCKS_WITH_LOGS[0]}" | cut -d':' -f2)
    first_local_logs=$(echo "${LOCAL_BLOCKS_WITH_LOGS[0]}" | cut -d':' -f3)
    
    echo "LOCAL_BLOCK_WITH_LOGS=\"$first_local\""
    echo "EXPECTED_LOCAL_LOGS=\"$first_local_logs\""
    echo "# Block has $first_local_txs transactions and $first_local_logs logs"
    echo ""
fi

if [ -n "$legacy_found" ] && [ -n "$local_found" ]; then
    echo -e "${CYAN}# Cross-boundary blocks${NC}"
    echo "CROSS_LEGACY_BLOCK=\"$legacy_found\"  # Legacy side with logs"
    echo "CROSS_LOCAL_BLOCK=\"$local_found\"    # Local side with logs"
    echo ""
fi

if [ ${#CONTRACT_ADDRESSES[@]} -gt 0 ]; then
    echo -e "${CYAN}# Contract addresses${NC}"
    first_contract=$(echo "${CONTRACT_ADDRESSES[0]}" | cut -d':' -f1)
    contract_block=$(echo "${CONTRACT_ADDRESSES[0]}" | cut -d':' -f2)
    
    echo "CONTRACT_ADDRESS=\"$first_contract\""
    echo "CONTRACT_TEST_BLOCK=\"$contract_block\""
    echo ""
fi

if [ ${#ACTIVE_EOAS[@]} -gt 0 ]; then
    echo -e "${CYAN}# Active EOA addresses${NC}"
    first_eoa=$(echo "${ACTIVE_EOAS[0]}" | cut -d':' -f1)
    eoa_block=$(echo "${ACTIVE_EOAS[0]}" | cut -d':' -f2)
    eoa_nonce=$(echo "${ACTIVE_EOAS[0]}" | cut -d':' -f3)
    
    echo "ACTIVE_ADDRESS=\"$first_eoa\""
    echo "ACTIVE_ADDRESS_BLOCK=\"$eoa_block\""
    echo "EXPECTED_NONCE=\"$eoa_nonce\""
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Next Steps:${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "1. Copy the configuration above"
echo "2. Update test_legacy_rpc.sh with these values"
echo "3. Run ./test_legacy_rpc.sh to validate with real data"
echo ""

if [ ${#LOCAL_BLOCKS_WITH_LOGS[@]} -eq 0 ]; then
    echo -e "${YELLOW}⚠️  Warning: No local blocks with logs found${NC}"
    echo "   Consider extending scan range or checking if local node is synced"
    echo ""
fi

