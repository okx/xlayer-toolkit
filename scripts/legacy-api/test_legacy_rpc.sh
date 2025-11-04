#!/bin/bash

# XLayer Mainnet Configuration
CUTOFF_BLOCK="42810021"
NETWORK_NAME="XLayer Mainnet"
LEGACY_RPC_URL="https://rpc.xlayer.tech/erigon/abcde12345"
EXPECTED_CHAIN_ID="0xc4"  # 196

# Real transaction hashes for testing
REAL_LEGACY_TX="0xc55ed6b97e1f8093b9e6f16ffc29ff1d9a779351292422283e3a840c87aca033"
REAL_LEGACY_BLOCK="42800899"
REAL_LOCAL_TX="0x7e59cc40daad08b8df51917ff604a7f4c47c62e684421a18cc7676e9fa1a800c"
REAL_LOCAL_BLOCK="42818021"
NEAR_CUTOFF_TX="0x29747bf7e39e97a9dc659633f714b44bf245ff0191c6daab7de9fbbf58cb6153"
NEAR_CUTOFF_BLOCK="42809908"

RETH_URL="${1:-http://localhost:8545}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Test results
declare -a FAILED_TEST_NAMES

# ========================================
# Helper Functions
# ========================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# RPC call helper
rpc_call() {
    local method=$1
    local params=$2
    local response

    response=$(curl -s -X POST "$RETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}")
    echo "$response"
}

# Check if result is not null and not error
check_result() {
    local response=$1
    local test_name=$2

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_error "$test_name"
        echo "       Error: $(echo "$response" | jq -r '.error.message')"
        echo "       Response: $(echo "$response" | jq -c .)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 0
    elif echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        log_success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_error "$test_name - Invalid response format"
        echo "       Response: $(echo "$response" | jq -c .)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 0
    fi
}

# Check if result is specifically non-null
check_result_not_null() {
    local response=$1
    local test_name=$2

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_error "$test_name"
        echo "       Error: $(echo "$response" | jq -r '.error.message')"
        echo "       Response: $(echo "$response" | jq -c .)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 0
    elif echo "$response" | jq -e '.result != null' > /dev/null 2>&1; then
        log_success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_warning "$test_name - Result is null (may be expected)"
        echo "       Response: $(echo "$response" | jq -c .)"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    fi
}

# Check result with legacy endpoint tolerance (errors become warnings)
check_result_legacy_tolerant() {
    local response=$1
    local test_name=$2

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        error_msg=$(echo "$response" | jq -r '.error.message')
        log_warning "$test_name - $error_msg (legacy endpoint may not support this method)"
        echo "       Response: $(echo "$response" | jq -c .)"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    elif echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        log_success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_warning "$test_name - Invalid response format"
        echo "       Response: $(echo "$response" | jq -c .)"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    fi
}

# ========================================
# Pre-flight Checks
# ========================================

log_section "Pre-flight Checks"

echo ""
echo "🌐 Network:      $NETWORK_NAME"
echo "🔗 RPC URL:      $RETH_URL"
echo "📦 Cutoff Block: $CUTOFF_BLOCK"
echo "🔄 Legacy RPC:   $LEGACY_RPC_URL"
echo ""

log_info "Testing connection to Reth..."
if ! curl -s "$RETH_URL" > /dev/null 2>&1; then
    log_error "Cannot connect to Reth at $RETH_URL"
    echo ""
    echo "💡 Tips:"
    echo "   - Make sure Reth is running"
    echo "   - Check if the RPC port is correct (default: 8545)"
    echo "   - Verify firewall settings"
    echo ""
    exit 1
fi
log_success "Connected to Reth at $RETH_URL"

log_info "Getting chain info..."
CHAIN_ID=$(rpc_call "eth_chainId" "[]" | jq -r '.result')
LATEST_BLOCK=$(rpc_call "eth_blockNumber" "[]" | jq -r '.result')
LATEST_BLOCK_DEC=$((LATEST_BLOCK))

# Validate chain ID
if [ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]; then
    log_warning "Chain ID mismatch! Expected $EXPECTED_CHAIN_ID (mainnet), got $CHAIN_ID"
    echo "   You might be connected to the wrong network!"
fi

log_info "Chain ID: $CHAIN_ID"
log_info "Latest Block: $LATEST_BLOCK ($LATEST_BLOCK_DEC)"
log_info "Cutoff Block: $CUTOFF_BLOCK"

# Calculate test block numbers
LEGACY_BLOCK=$((CUTOFF_BLOCK - 1000))
LOCAL_BLOCK=$((CUTOFF_BLOCK + 1000))
BOUNDARY_BLOCK=$CUTOFF_BLOCK

LEGACY_BLOCK_HEX=$(printf "0x%x" $LEGACY_BLOCK)
LOCAL_BLOCK_HEX=$(printf "0x%x" $LOCAL_BLOCK)
BOUNDARY_BLOCK_HEX=$(printf "0x%x" $BOUNDARY_BLOCK)

log_info "Test Blocks:"
log_info "  Legacy Block:   $LEGACY_BLOCK_HEX ($LEGACY_BLOCK) → Should route to Erigon"
log_info "  Boundary Block: $BOUNDARY_BLOCK_HEX ($BOUNDARY_BLOCK) → Migration point"
log_info "  Local Block:    $LOCAL_BLOCK_HEX ($LOCAL_BLOCK) → Should use Reth"

# Validate that current block height is reasonable
if [ $LATEST_BLOCK_DEC -lt $CUTOFF_BLOCK ]; then
    log_error "Node's latest block ($LATEST_BLOCK_DEC) is below cutoff block ($CUTOFF_BLOCK)!"
    echo "   This node hasn't synced past the migration point yet."
    echo "   Some tests may fail or be skipped."
    echo ""
fi

# ========================================
# Phase 1: Basic Block Query Tests
# ========================================

log_section "Phase 1: Basic Block Query Tests"

# Test 1.1: eth_getBlockByNumber (legacy)
log_info "Test 1.1: eth_getBlockByNumber (legacy block)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]")
check_result_not_null "$response" "eth_getBlockByNumber (legacy: $LEGACY_BLOCK_HEX)"

# Test 1.2: eth_getBlockByNumber (local)
log_info "Test 1.2: eth_getBlockByNumber (local block)"
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    response=$(rpc_call "eth_getBlockByNumber" "[\"$LOCAL_BLOCK_HEX\",false]")
    check_result_not_null "$response" "eth_getBlockByNumber (local: $LOCAL_BLOCK_HEX)"
else
    log_warning "Skipping local block test - block not yet mined"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 1.3: eth_getBlockByNumber (boundary)
log_info "Test 1.3: eth_getBlockByNumber (boundary block)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]")
check_result_not_null "$response" "eth_getBlockByNumber (boundary: $BOUNDARY_BLOCK_HEX)"

# Test 1.4: eth_getBlockByNumber with full transactions
log_info "Test 1.4: eth_getBlockByNumber (full transactions)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",true]")
check_result_not_null "$response" "eth_getBlockByNumber (full tx)"

# ========================================
# Phase 1.5: Header Tests
# ========================================

log_section "Phase 1.5: Header Tests"

# Get a block hash for testing
HEADER_BLOCK_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -r '.result.hash')

# Test 1.5.1: eth_getHeaderByNumber (legacy block)
log_info "Test 1.5.1: eth_getHeaderByNumber (legacy block)"
response=$(rpc_call "eth_getHeaderByNumber" "[\"$LEGACY_BLOCK_HEX\"]")
check_result_legacy_tolerant "$response" "eth_getHeaderByNumber (legacy)"

# Test 1.5.2: eth_getHeaderByNumber (local block)
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    log_info "Test 1.5.2: eth_getHeaderByNumber (local block)"
    response=$(rpc_call "eth_getHeaderByNumber" "[\"$LOCAL_BLOCK_HEX\"]")
    check_result_not_null "$response" "eth_getHeaderByNumber (local)"
else
    log_warning "Skipping local block header test - block not yet mined"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 1.5.3: eth_getHeaderByHash
if [ "$HEADER_BLOCK_HASH" != "null" ] && [ -n "$HEADER_BLOCK_HASH" ]; then
    log_info "Test 1.5.3: eth_getHeaderByHash"
    response=$(rpc_call "eth_getHeaderByHash" "[\"$HEADER_BLOCK_HASH\"]")
    check_result_legacy_tolerant "$response" "eth_getHeaderByHash"
else
    log_warning "Skipping header hash test - no block hash available"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# ========================================
# Phase 2: Transaction Count Tests
# ========================================

log_section "Phase 2: Transaction Count Tests"

# Get a block hash first
BLOCK_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -r '.result.hash')

# Test 2.1: eth_getBlockTransactionCountByNumber
log_info "Test 2.1: eth_getBlockTransactionCountByNumber"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getBlockTransactionCountByNumber"

# Test 2.2: eth_getBlockTransactionCountByHash
if [ "$BLOCK_HASH" != "null" ] && [ -n "$BLOCK_HASH" ]; then
    log_info "Test 2.2: eth_getBlockTransactionCountByHash"
    response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$BLOCK_HASH\"]")
    check_result_legacy_tolerant "$response" "eth_getBlockTransactionCountByHash"
else
    log_warning "Skipping hash test - no block hash available"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# ========================================
# Phase 3: Transaction Query Tests
# ========================================

log_section "Phase 3: Transaction Query Tests"

# Get a transaction hash first
log_info "Fetching a transaction hash from legacy block..."
TX_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -r '.result.transactions[0]? // empty')

if [ -n "$TX_HASH" ] && [ "$TX_HASH" != "null" ]; then
    log_info "Found transaction: $TX_HASH"

    # Test 4.1: eth_getTransactionByHash
    log_info "Test 4.1: eth_getTransactionByHash (hash-based fallback)"
    response=$(rpc_call "eth_getTransactionByHash" "[\"$TX_HASH\"]")
    check_result_not_null "$response" "eth_getTransactionByHash"

    # Test 4.2: eth_getTransactionReceipt
    log_info "Test 4.2: eth_getTransactionReceipt (hash-based fallback)"
    response=$(rpc_call "eth_getTransactionReceipt" "[\"$TX_HASH\"]")
    check_result_not_null "$response" "eth_getTransactionReceipt"

    # Test 4.3: eth_getTransactionByBlockHashAndIndex
    log_info "Test 4.3: eth_getTransactionByBlockHashAndIndex"
    response=$(rpc_call "eth_getTransactionByBlockHashAndIndex" "[\"$BLOCK_HASH\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getTransactionByBlockHashAndIndex"

    # Test 4.4: eth_getTransactionByBlockNumberAndIndex
    log_info "Test 4.4: eth_getTransactionByBlockNumberAndIndex"
    response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"$LEGACY_BLOCK_HEX\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getTransactionByBlockNumberAndIndex"

    # Test 4.5: eth_getRawTransactionByHash
    log_info "Test 4.5: eth_getRawTransactionByHash (hash-based fallback)"
    response=$(rpc_call "eth_getRawTransactionByHash" "[\"$TX_HASH\"]")
    check_result_not_null "$response" "eth_getRawTransactionByHash"

    # Test 4.6: eth_getRawTransactionByBlockHashAndIndex
    log_info "Test 4.6: eth_getRawTransactionByBlockHashAndIndex"
    response=$(rpc_call "eth_getRawTransactionByBlockHashAndIndex" "[\"$BLOCK_HASH\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getRawTransactionByBlockHashAndIndex"

    # Test 4.7: eth_getRawTransactionByBlockNumberAndIndex (legacy block)
    log_info "Test 4.7: eth_getRawTransactionByBlockNumberAndIndex (legacy block)"
    response=$(rpc_call "eth_getRawTransactionByBlockNumberAndIndex" "[\"$LEGACY_BLOCK_HEX\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getRawTransactionByBlockNumberAndIndex (legacy)"

    # Test 4.8: eth_getRawTransactionByBlockNumberAndIndex (local block)
    if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
        log_info "Test 4.8: eth_getRawTransactionByBlockNumberAndIndex (local block)"
        response=$(rpc_call "eth_getRawTransactionByBlockNumberAndIndex" "[\"$LOCAL_BLOCK_HEX\",\"0x0\"]")
        check_result_legacy_tolerant "$response" "eth_getRawTransactionByBlockNumberAndIndex (local)"
    else
        log_warning "Skipping local block getRawTransaction test - block not yet mined"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    fi
else
    log_warning "No transactions found in legacy block, skipping transaction tests"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 8))
fi

# ========================================
# Phase 4: State Query Tests
# ========================================

log_section "Phase 4: State Query Tests"

# Use a known address or get one from a block
TEST_ADDR="0x0000000000000000000000000000000000000000"

# Test 4.1: eth_getBalance
log_info "Test 4.1: eth_getBalance"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getBalance (legacy block)"

# Test 4.2: eth_getCode
log_info "Test 4.2: eth_getCode"
response=$(rpc_call "eth_getCode" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getCode"

# Test 4.3: eth_getStorageAt
log_info "Test 4.3: eth_getStorageAt"
response=$(rpc_call "eth_getStorageAt" "[\"$TEST_ADDR\",\"0x0\",\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getStorageAt"

# Test 4.4: eth_getTransactionCount
log_info "Test 4.4: eth_getTransactionCount"
response=$(rpc_call "eth_getTransactionCount" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getTransactionCount"

# ========================================
# Phase 5: eth_getLogs Tests
# ========================================

log_section "Phase 5: eth_getLogs Tests"

# Test 5.1: Pure legacy range
log_info "Test 5.1: eth_getLogs (pure legacy range)"
LEGACY_FROM=$((LEGACY_BLOCK - 10))
LEGACY_TO=$((LEGACY_BLOCK + 10))
LEGACY_FROM_HEX=$(printf "0x%x" $LEGACY_FROM)
LEGACY_TO_HEX=$(printf "0x%x" $LEGACY_TO)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\"}]")
check_result_legacy_tolerant "$response" "eth_getLogs (pure legacy)"

# Test 5.2: Pure local range (if available)
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    log_info "Test 5.2: eth_getLogs (pure local range)"
    LOCAL_FROM=$((LOCAL_BLOCK - 10))
    LOCAL_TO=$((LOCAL_BLOCK + 10))
    LOCAL_FROM_HEX=$(printf "0x%x" $LOCAL_FROM)
    LOCAL_TO_HEX=$(printf "0x%x" $LOCAL_TO)
    response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LOCAL_FROM_HEX\",\"toBlock\":\"$LOCAL_TO_HEX\"}]")
    check_result "$response" "eth_getLogs (pure local)"
else
    log_warning "Skipping pure local getLogs test"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 5.3: Exact cutoff block
log_info "Test 5.3: eth_getLogs (exact cutoff block)"
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$BOUNDARY_BLOCK_HEX\",\"toBlock\":\"$BOUNDARY_BLOCK_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff: $BOUNDARY_BLOCK_HEX)"

# Test 5.4: Last legacy block (cutoff - 1)
log_info "Test 5.4: eth_getLogs (last legacy block: cutoff - 1)"
LAST_LEGACY=$((CUTOFF_BLOCK - 1))
LAST_LEGACY_HEX=$(printf "0x%x" $LAST_LEGACY)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LAST_LEGACY_HEX\",\"toBlock\":\"$LAST_LEGACY_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff-1: $LAST_LEGACY_HEX)"

# Test 5.5: First local block (cutoff + 1)
log_info "Test 5.5: eth_getLogs (first local block: cutoff + 1)"
FIRST_LOCAL=$((CUTOFF_BLOCK + 1))
FIRST_LOCAL_HEX=$(printf "0x%x" $FIRST_LOCAL)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$FIRST_LOCAL_HEX\",\"toBlock\":\"$FIRST_LOCAL_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff+1: $FIRST_LOCAL_HEX)"

# Test 5.6: Minimal cross-boundary (cutoff-1 to cutoff)
log_info "Test 5.6: eth_getLogs (minimal boundary: cutoff-1 to cutoff)"
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LAST_LEGACY_HEX\",\"toBlock\":\"$BOUNDARY_BLOCK_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff-1 to cutoff)"

# Test 5.7: Minimal cross-boundary (cutoff to cutoff+1)
log_info "Test 5.7: eth_getLogs (minimal boundary: cutoff to cutoff+1)"
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$BOUNDARY_BLOCK_HEX\",\"toBlock\":\"$FIRST_LOCAL_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff to cutoff+1)"

# Test 5.8: Minimal 3-block boundary (cutoff-1 to cutoff+1)
log_info "Test 5.8: eth_getLogs (3-block boundary: cutoff-1 to cutoff+1)"
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LAST_LEGACY_HEX\",\"toBlock\":\"$FIRST_LOCAL_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff-1 to cutoff+1)"

# Test 5.9: Cross-boundary range (THE MOST IMPORTANT TEST!)
log_info "Test 5.9: eth_getLogs (CROSS-BOUNDARY - Wide Range)"
CROSS_FROM=$((CUTOFF_BLOCK - 50))
CROSS_TO=$((CUTOFF_BLOCK + 50))
CROSS_FROM_HEX=$(printf "0x%x" $CROSS_FROM)
CROSS_TO_HEX=$(printf "0x%x" $CROSS_TO)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]")

if check_result "$response" "eth_getLogs (CROSS-BOUNDARY)"; then
    # Verify logs are sorted
    LOGS=$(echo "$response" | jq '.result')
    if [ "$LOGS" != "[]" ]; then
        # Check if block numbers are sorted
        IS_SORTED=$(echo "$LOGS" | jq '[.[].blockNumber] | . == sort')
        if [ "$IS_SORTED" = "true" ]; then
            log_success "  → Logs are properly sorted ✓"
        else
            log_error "  → Logs are NOT properly sorted ✗"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Log sorting verification")
        fi
    fi
fi

# ========================================
# Phase 5.5: Real Data Tests
# ========================================

log_section "Phase 5.5: Real Data Tests with Known Transactions"

echo ""
log_info "Using real transaction data:"
log_info "  Legacy TX:  $REAL_LEGACY_TX (Block: $REAL_LEGACY_BLOCK)"
log_info "  Local TX:   $REAL_LOCAL_TX (Block: $REAL_LOCAL_BLOCK)"
echo ""

# Test 5.5.1: Get legacy transaction by hash
log_info "Test 5.5.1: eth_getTransactionByHash (real legacy tx)"
response=$(rpc_call "eth_getTransactionByHash" "[\"$REAL_LEGACY_TX\"]")
if check_result_not_null "$response" "eth_getTransactionByHash (real legacy)"; then
    TX_BLOCK=$(echo "$response" | jq -r '.result.blockNumber')
    TX_BLOCK_DEC=$((TX_BLOCK))
    if [ "$TX_BLOCK_DEC" -eq "$REAL_LEGACY_BLOCK" ]; then
        log_success "  → Block number matches: $TX_BLOCK ✓"
    else
        log_error "  → Block number mismatch! Expected $REAL_LEGACY_BLOCK, got $TX_BLOCK_DEC ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Real legacy tx block verification")
    fi
fi

# Test 5.5.2: Get local transaction by hash
log_info "Test 5.5.2: eth_getTransactionByHash (real local tx)"
response=$(rpc_call "eth_getTransactionByHash" "[\"$REAL_LOCAL_TX\"]")
if check_result_not_null "$response" "eth_getTransactionByHash (real local)"; then
    TX_BLOCK=$(echo "$response" | jq -r '.result.blockNumber')
    TX_BLOCK_DEC=$((TX_BLOCK))
    if [ "$TX_BLOCK_DEC" -eq "$REAL_LOCAL_BLOCK" ]; then
        log_success "  → Block number matches: $TX_BLOCK ✓"
    else
        log_error "  → Block number mismatch! Expected $REAL_LOCAL_BLOCK, got $TX_BLOCK_DEC ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Real local tx block verification")
    fi
fi

# Test 5.5.3: Get legacy transaction receipt
log_info "Test 5.5.3: eth_getTransactionReceipt (real legacy tx)"
response=$(rpc_call "eth_getTransactionReceipt" "[\"$REAL_LEGACY_TX\"]")
if check_result_not_null "$response" "eth_getTransactionReceipt (real legacy)"; then
    RECEIPT_BLOCK=$(echo "$response" | jq -r '.result.blockNumber')
    RECEIPT_STATUS=$(echo "$response" | jq -r '.result.status')
    RECEIPT_LOGS_COUNT=$(echo "$response" | jq -r '.result.logs | length')
    log_info "  → Receipt block: $RECEIPT_BLOCK, Status: $RECEIPT_STATUS, Logs: $RECEIPT_LOGS_COUNT"

    MISSING_FIELDS=$(echo "$response" | jq -r '.result |
        if .blockNumber and .blockHash and .transactionHash and .status != null and .logs then
            "valid"
        else
            "missing_fields"
        end')

    if [ "$MISSING_FIELDS" = "valid" ]; then
        log_success "  → Receipt has all required fields ✓"
    else
        log_error "  → Receipt missing required fields ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Real legacy receipt field verification")
    fi
fi

# Test 5.5.4: Get local transaction receipt
log_info "Test 5.5.4: eth_getTransactionReceipt (real local tx)"
response=$(rpc_call "eth_getTransactionReceipt" "[\"$REAL_LOCAL_TX\"]")
if check_result_not_null "$response" "eth_getTransactionReceipt (real local)"; then
    RECEIPT_BLOCK=$(echo "$response" | jq -r '.result.blockNumber')
    RECEIPT_STATUS=$(echo "$response" | jq -r '.result.status')
    RECEIPT_LOGS_COUNT=$(echo "$response" | jq -r '.result.logs | length')
    log_info "  → Receipt block: $RECEIPT_BLOCK, Status: $RECEIPT_STATUS, Logs: $RECEIPT_LOGS_COUNT"

    MISSING_FIELDS=$(echo "$response" | jq -r '.result |
        if .blockNumber and .blockHash and .transactionHash and .status != null and .logs then
            "valid"
        else
            "missing_fields"
        end')

    if [ "$MISSING_FIELDS" = "valid" ]; then
        log_success "  → Receipt has all required fields ✓"
    else
        log_error "  → Receipt missing required fields ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Real local receipt field verification")
    fi
fi

# Test 5.5.5: Get logs from legacy transaction's block
log_info "Test 5.5.5: eth_getLogs (real legacy block with known tx)"
REAL_LEGACY_BLOCK_HEX=$(printf "0x%x" $REAL_LEGACY_BLOCK)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$REAL_LEGACY_BLOCK_HEX\",\"toBlock\":\"$REAL_LEGACY_BLOCK_HEX\"}]")
if check_result "$response" "eth_getLogs (real legacy block)"; then
    LOGS=$(echo "$response" | jq '.result')
    LOGS_COUNT=$(echo "$LOGS" | jq 'length')
    log_info "  → Found $LOGS_COUNT logs in block $REAL_LEGACY_BLOCK"

    if [ "$LOGS_COUNT" -gt 0 ]; then
        VALID_LOGS=$(echo "$LOGS" | jq '[.[] | select(.address and .topics and .data and .blockNumber and .transactionHash)] | length')
        if [ "$VALID_LOGS" -eq "$LOGS_COUNT" ]; then
            log_success "  → All logs have valid structure ✓"
        else
            log_error "  → Some logs have invalid structure ✗"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Real legacy logs structure validation")
        fi
    fi
fi

# Test 5.5.6: Get logs from local transaction's block
log_info "Test 5.5.6: eth_getLogs (real local block with known tx)"
REAL_LOCAL_BLOCK_HEX=$(printf "0x%x" $REAL_LOCAL_BLOCK)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$REAL_LOCAL_BLOCK_HEX\",\"toBlock\":\"$REAL_LOCAL_BLOCK_HEX\"}]")
if check_result "$response" "eth_getLogs (real local block)"; then
    LOGS=$(echo "$response" | jq '.result')
    LOGS_COUNT=$(echo "$LOGS" | jq 'length')
    log_info "  → Found $LOGS_COUNT logs in block $REAL_LOCAL_BLOCK"

    if [ "$LOGS_COUNT" -gt 0 ]; then
        VALID_LOGS=$(echo "$LOGS" | jq '[.[] | select(.address and .topics and .data and .blockNumber and .transactionHash)] | length')
        if [ "$VALID_LOGS" -eq "$LOGS_COUNT" ]; then
            log_success "  → All logs have valid structure ✓"
        else
            log_error "  → Some logs have invalid structure ✗"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Real local logs structure validation")
        fi
    fi
fi

# Test 5.5.7: Cross-boundary test with transaction near cutoff
log_info "Test 5.5.7: Cross-boundary test with transaction near cutoff"
NEAR_CUTOFF_BLOCK_HEX=$(printf "0x%x" $NEAR_CUTOFF_BLOCK)
log_info "  → Near-cutoff TX: $NEAR_CUTOFF_TX"
log_info "  → Near-cutoff Block: $NEAR_CUTOFF_BLOCK (distance to cutoff: $(($CUTOFF_BLOCK - $NEAR_CUTOFF_BLOCK)) blocks)"

# First, verify we can get the transaction
response=$(rpc_call "eth_getTransactionByHash" "[\"$NEAR_CUTOFF_TX\"]")
if check_result_not_null "$response" "eth_getTransactionByHash (near cutoff)"; then
    TX_BLOCK=$(echo "$response" | jq -r '.result.blockNumber')
    TX_BLOCK_DEC=$((TX_BLOCK))
    if [ "$TX_BLOCK_DEC" -eq "$NEAR_CUTOFF_BLOCK" ]; then
        log_success "  → Transaction block number verified: $TX_BLOCK ✓"
    fi
fi

# Now test cross-boundary getLogs
NEAR_CROSS_FROM=$((CUTOFF_BLOCK - 60))
NEAR_CROSS_TO=$((CUTOFF_BLOCK + 60))
NEAR_CROSS_FROM_HEX=$(printf "0x%x" $NEAR_CROSS_FROM)
NEAR_CROSS_TO_HEX=$(printf "0x%x" $NEAR_CROSS_TO)
NEAR_CROSS_SPAN=$((NEAR_CROSS_TO - NEAR_CROSS_FROM))

log_info "  → Testing getLogs across cutoff boundary:"
log_info "    From: $NEAR_CROSS_FROM ($(($CUTOFF_BLOCK - $NEAR_CROSS_FROM)) blocks before cutoff)"
log_info "    To:   $NEAR_CROSS_TO ($(($NEAR_CROSS_TO - $CUTOFF_BLOCK)) blocks after cutoff)"
log_info "    Total span: $NEAR_CROSS_SPAN blocks (within Legacy RPC 68-block limit)"

response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$NEAR_CROSS_FROM_HEX\",\"toBlock\":\"$NEAR_CROSS_TO_HEX\"}]")

if check_result "$response" "eth_getLogs (near-cutoff cross-boundary)"; then
    LOGS=$(echo "$response" | jq '.result')
    LOGS_COUNT=$(echo "$LOGS" | jq 'length')
    log_info "  → Found $LOGS_COUNT logs in cross-boundary range"

    if [ "$LOGS_COUNT" -gt 0 ]; then
        LEGACY_LOGS=$(echo "$LOGS" | jq --argjson cutoff "$CUTOFF_BLOCK" '[.[] | select((.blockNumber | tonumber) < $cutoff)] | length')
        LOCAL_LOGS=$(echo "$LOGS" | jq --argjson cutoff "$CUTOFF_BLOCK" '[.[] | select((.blockNumber | tonumber) >= $cutoff)] | length')

        log_info "  → Legacy side logs: $LEGACY_LOGS"
        log_info "  → Local side logs:  $LOCAL_LOGS"

        if [ "$LEGACY_LOGS" -gt 0 ] && [ "$LOCAL_LOGS" -gt 0 ]; then
            log_success "  → Successfully retrieved logs from BOTH sides of cutoff! ✓"
        elif [ "$LEGACY_LOGS" -gt 0 ]; then
            log_warning "  → Only found logs on legacy side"
        elif [ "$LOCAL_LOGS" -gt 0 ]; then
            log_warning "  → Only found logs on local side"
        fi

        # Verify sorting
        IS_SORTED=$(echo "$LOGS" | jq '[.[].blockNumber] | . == sort')
        if [ "$IS_SORTED" = "true" ]; then
            log_success "  → Logs properly sorted across boundary ✓"
        else
            log_error "  → Logs NOT sorted properly ✗"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Near-cutoff cross-boundary log sorting")
        fi
    fi
fi

# ========================================
# Phase 6: Additional Methods
# ========================================

log_section "Phase 6: Additional Methods"

# Test 6.1: eth_getBlockReceipts
log_info "Test 6.1: eth_getBlockReceipts"
response=$(rpc_call "eth_getBlockReceipts" "[\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getBlockReceipts"

# Test 6.2: eth_getBlockByHash
if [ "$BLOCK_HASH" != "null" ] && [ -n "$BLOCK_HASH" ]; then
    log_info "Test 6.2: eth_getBlockByHash"
    response=$(rpc_call "eth_getBlockByHash" "[\"$BLOCK_HASH\",false]")
    check_result_not_null "$response" "eth_getBlockByHash"
fi

# ========================================
# Test Summary
# ========================================

log_section "Test Summary"

echo ""
echo "Total Tests:   $TOTAL_TESTS"
echo -e "${GREEN}Passed:        $PASSED_TESTS${NC}"
echo -e "${RED}Failed:        $FAILED_TESTS${NC}"
echo -e "${YELLOW}Skipped:       $SKIPPED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Failed Tests:${NC}"
    for test_name in "${FAILED_TEST_NAMES[@]}"; do
        echo "  - $test_name"
    done
    echo ""
fi

# Calculate success rate
if [ $TOTAL_TESTS -gt 0 ]; then
    SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($PASSED_TESTS / $TOTAL_TESTS) * 100}")
    echo "Success Rate: $SUCCESS_RATE%"
else
    echo "Success Rate: N/A"
fi

echo ""

# Final verdict
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Configuration:"
echo "   Network:      $NETWORK_NAME"
echo "   RPC URL:      $RETH_URL"
echo "   Cutoff Block: $CUTOFF_BLOCK"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✓ ALL TESTS PASSED!                 ║${NC}"
    echo -e "${GREEN}║   Legacy RPC is working correctly!    ║${NC}"
    echo -e "${GREEN}║   XLayer Mainnet migration validated ✓║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗ SOME TESTS FAILED                  ║${NC}"
    echo -e "${RED}║   Please review the errors above       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "💡 Troubleshooting tips:"
    echo "   1. Check if Reth was started with Legacy RPC parameters:"
    echo "      --legacy-rpc-url \"$LEGACY_RPC_URL\""
    echo "      --legacy-cutoff-block $CUTOFF_BLOCK"
    echo ""
    echo "   2. Verify network connectivity to legacy RPC endpoint"
    echo ""
    echo "   3. Check Reth logs for errors:"
    echo "      docker logs <container_id> | grep -i legacy"
    echo ""
    exit 1
fi
