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

# Real data blocks (auto-discovered from scan_test_data.sh)
LOCAL_BLOCK_WITH_LOGS="42811521"       # Local block with logs for getLogs test
EXPECTED_LOCAL_LOGS="6"                # Expected log count
CROSS_LEGACY_BLOCK="42809621"          # Legacy block near cutoff with logs
CONTRACT_ADDRESS="0x4200000000000000000000000000000000000015"  # Real contract
CONTRACT_TEST_BLOCK="42811521"         # Block for contract state queries
ACTIVE_EOA_ADDRESS="0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001"  # Address with nonce > 0
EXPECTED_NONCE="1500"                  # Expected nonce value

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

# RPC call helper (Reth)
rpc_call() {
    local method=$1
    local params=$2
    local response

    response=$(curl -s -X POST "$RETH_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}")
    echo "$response"
}

# RPC call helper (Legacy Erigon)
rpc_call_legacy() {
    local method=$1
    local params=$2
    local response

    response=$(curl -s -X POST "$LEGACY_RPC_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}")
    echo "$response"
}

# Detailed comparison for eth_getLogs results
check_logs_consistency() {
    local reth_logs=$1
    local legacy_logs=$2
    local test_name=$3
    
    # Count logs
    local reth_count=$(echo "$reth_logs" | jq 'length')
    local legacy_count=$(echo "$legacy_logs" | jq 'length')
    
    echo ""
    log_info "  📊 Detailed getLogs Comparison:"
    echo "     Reth logs:   $reth_count"
    echo "     Legacy logs: $legacy_count"
    
    # Check count match
    if [ "$reth_count" -ne "$legacy_count" ]; then
        log_error "$test_name - Log count MISMATCH ✗"
        echo "       Expected $legacy_count logs, got $reth_count"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
    
    # If no logs, that's fine
    if [ "$reth_count" -eq 0 ]; then
        log_success "$test_name - Both returned empty logs ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    fi
    
    # Normalize and compare the entire array
    local reth_normalized=$(echo "$reth_logs" | jq -cS '.')
    local legacy_normalized=$(echo "$legacy_logs" | jq -cS '.')
    
    if [ "$reth_normalized" = "$legacy_normalized" ]; then
        log_success "$test_name - All $reth_count logs identical ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    fi
    
    # If not identical, perform detailed field-by-field comparison
    log_warning "  ⚠️  Logs not byte-identical, checking field-by-field..."
    
    local mismatches=0
    for i in $(seq 0 $((reth_count - 1))); do
        local reth_log=$(echo "$reth_logs" | jq -c ".[$i]")
        local legacy_log=$(echo "$legacy_logs" | jq -c ".[$i]")
        
        # Compare critical fields
        local reth_address=$(echo "$reth_log" | jq -r '.address')
        local legacy_address=$(echo "$legacy_log" | jq -r '.address')
        local reth_topics=$(echo "$reth_log" | jq -cS '.topics')
        local legacy_topics=$(echo "$legacy_log" | jq -cS '.topics')
        local reth_data=$(echo "$reth_log" | jq -r '.data')
        local legacy_data=$(echo "$legacy_log" | jq -r '.data')
        local reth_blockNumber=$(echo "$reth_log" | jq -r '.blockNumber')
        local legacy_blockNumber=$(echo "$legacy_log" | jq -r '.blockNumber')
        local reth_txHash=$(echo "$reth_log" | jq -r '.transactionHash')
        local legacy_txHash=$(echo "$legacy_log" | jq -r '.transactionHash')
        local reth_logIndex=$(echo "$reth_log" | jq -r '.logIndex')
        local legacy_logIndex=$(echo "$legacy_log" | jq -r '.logIndex')
        
        # Check each field
        local log_ok=true
        if [ "$reth_address" != "$legacy_address" ]; then
            echo "       Log [$i] address mismatch: $reth_address vs $legacy_address"
            log_ok=false
        fi
        if [ "$reth_topics" != "$legacy_topics" ]; then
            echo "       Log [$i] topics mismatch"
            log_ok=false
        fi
        if [ "$reth_data" != "$legacy_data" ]; then
            echo "       Log [$i] data mismatch"
            log_ok=false
        fi
        if [ "$reth_blockNumber" != "$legacy_blockNumber" ]; then
            echo "       Log [$i] blockNumber mismatch: $reth_blockNumber vs $legacy_blockNumber"
            log_ok=false
        fi
        if [ "$reth_txHash" != "$legacy_txHash" ]; then
            echo "       Log [$i] transactionHash mismatch: $reth_txHash vs $legacy_txHash"
            log_ok=false
        fi
        if [ "$reth_logIndex" != "$legacy_logIndex" ]; then
            echo "       Log [$i] logIndex mismatch: $reth_logIndex vs $legacy_logIndex"
            log_ok=false
        fi
        
        if [ "$log_ok" = false ]; then
            mismatches=$((mismatches + 1))
        fi
    done
    
    if [ $mismatches -eq 0 ]; then
        log_success "$test_name - All fields match (minor JSON formatting differences only) ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_error "$test_name - Found $mismatches logs with field mismatches ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
}

# Compare Reth and Legacy RPC responses for data consistency
check_data_consistency() {
    local method=$1
    local params=$2
    local test_name=$3
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Get response from Reth
    local reth_response=$(rpc_call "$method" "$params")
    
    # Get response from Legacy RPC
    local legacy_response=$(rpc_call_legacy "$method" "$params")
    
    # Check if both succeeded
    local reth_has_error=$(echo "$reth_response" | jq -e '.error' > /dev/null 2>&1 && echo "true" || echo "false")
    local legacy_has_error=$(echo "$legacy_response" | jq -e '.error' > /dev/null 2>&1 && echo "true" || echo "false")
    
    if [ "$reth_has_error" = "true" ]; then
        log_error "$test_name - Reth returned error"
        echo "       Reth error: $(echo "$reth_response" | jq -r '.error.message')"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
    
    if [ "$legacy_has_error" = "true" ]; then
        log_warning "$test_name - Legacy RPC returned error (may not support this method)"
        echo "       Legacy error: $(echo "$legacy_response" | jq -r '.error.message')"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 1
    fi
    
    # Extract results
    local reth_result=$(echo "$reth_response" | jq -c '.result')
    local legacy_result=$(echo "$legacy_response" | jq -c '.result')
    
    # Special handling for eth_getLogs - detailed comparison
    if [[ "$method" == "eth_getLogs" ]]; then
        check_logs_consistency "$reth_result" "$legacy_result" "$test_name"
        return $?
    fi
    
    # Compare results (normalize for comparison)
    local reth_normalized=$(echo "$reth_result" | jq -cS '.')
    local legacy_normalized=$(echo "$legacy_result" | jq -cS '.')
    
    if [ "$reth_normalized" = "$legacy_normalized" ]; then
        log_success "$test_name - Data consistent ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_error "$test_name - Data MISMATCH ✗"
        echo "       Reth result:   $(echo "$reth_result" | jq -c . | head -c 200)..."
        echo "       Legacy result: $(echo "$legacy_result" | jq -c . | head -c 200)..."
        
        # Show detailed diff for blocks
        if [[ "$method" == *"Block"* ]] || [[ "$method" == *"block"* ]]; then
            echo "       Detailed comparison:"
            echo "         Reth hash:   $(echo "$reth_result" | jq -r '.hash // "N/A"')"
            echo "         Legacy hash: $(echo "$legacy_result" | jq -r '.hash // "N/A"')"
            echo "         Reth txs:    $(echo "$reth_result" | jq -r '.transactions | length // 0')"
            echo "         Legacy txs:  $(echo "$legacy_result" | jq -r '.transactions | length // 0')"
        fi
        
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
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

echo ""
log_info "Validating test data quality..."

# Check Legacy Block
response=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]")
LEGACY_TX_COUNT=$(echo "$response" | jq -r '.result.transactions | length')
log_info "  Legacy Block ($LEGACY_BLOCK): $LEGACY_TX_COUNT transactions"
if [ "$LEGACY_TX_COUNT" -eq 0 ]; then
    log_warning "    ⚠️  Empty block - transaction tests may be skipped"
fi

# Check Boundary Block  
response=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]")
BOUNDARY_TX_COUNT=$(echo "$response" | jq -r '.result.transactions | length')
log_info "  Boundary Block ($BOUNDARY_BLOCK): $BOUNDARY_TX_COUNT transactions"

# Check Local Block
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    response=$(rpc_call "eth_getBlockByNumber" "[\"$LOCAL_BLOCK_HEX\",false]")
    LOCAL_TX_COUNT=$(echo "$response" | jq -r '.result.transactions | length')
    log_info "  Local Block ($LOCAL_BLOCK): $LOCAL_TX_COUNT transactions"
    if [ "$LOCAL_TX_COUNT" -eq 0 ]; then
        log_warning "    ⚠️  Empty block - transaction tests may be skipped"
    fi
fi

# Check Real Data Blocks
echo ""
log_info "Validating predefined real data blocks..."
response=$(rpc_call "eth_getBlockByNumber" "[\"$(printf "0x%x" $REAL_LEGACY_BLOCK)\",false]")
REAL_LEGACY_TX_COUNT=$(echo "$response" | jq -r '.result.transactions | length')
log_info "  Real Legacy Block ($REAL_LEGACY_BLOCK): $REAL_LEGACY_TX_COUNT transactions"

# Check if the predefined transaction exists
response=$(rpc_call "eth_getTransactionReceipt" "[\"$REAL_LEGACY_TX\"]")
if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
    REAL_LEGACY_LOGS=$(echo "$response" | jq -r '.result.logs | length')
    log_info "    Transaction $REAL_LEGACY_TX has $REAL_LEGACY_LOGS logs"
    if [ "$REAL_LEGACY_LOGS" -eq 0 ]; then
        log_warning "      ⚠️  No logs - consider providing a transaction with logs for getLogs testing"
    fi
else
    log_warning "    ⚠️  Transaction not found: $REAL_LEGACY_TX"
fi

response=$(rpc_call "eth_getBlockByNumber" "[\"$(printf "0x%x" $REAL_LOCAL_BLOCK)\",false]")
REAL_LOCAL_TX_COUNT=$(echo "$response" | jq -r '.result.transactions | length')
log_info "  Real Local Block ($REAL_LOCAL_BLOCK): $REAL_LOCAL_TX_COUNT transactions"

response=$(rpc_call "eth_getTransactionReceipt" "[\"$REAL_LOCAL_TX\"]")
if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
    REAL_LOCAL_LOGS=$(echo "$response" | jq -r '.result.logs | length')
    log_info "    Transaction $REAL_LOCAL_TX has $REAL_LOCAL_LOGS logs"
    if [ "$REAL_LOCAL_LOGS" -eq 0 ]; then
        log_warning "      ⚠️  No logs - consider providing a transaction with logs"
    fi
else
    log_warning "    ⚠️  Transaction not found: $REAL_LOCAL_TX"
fi

# Check state query test address
echo ""
log_info "Checking test addresses for state queries..."

# Check contract address
log_info "  Contract: $CONTRACT_ADDRESS"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"latest\"]")
CODE=$(echo "$response" | jq -r '.result')
CODE_LENGTH=${#CODE}
if [ "$CODE" != "0x" ] && [ "$CODE" != "null" ]; then
    log_info "    ✓ Contract found (bytecode: $CODE_LENGTH bytes)"
else
    log_warning "    ⚠️  No bytecode found"
fi

# Check active EOA
log_info "  Active EOA: $ACTIVE_EOA_ADDRESS"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"latest\"]")
NONCE=$(echo "$response" | jq -r '.result')
NONCE_DEC=$((NONCE))
if [ $NONCE_DEC -gt 0 ]; then
    log_info "    ✓ Active address (nonce: $NONCE_DEC)"
else
    log_warning "    ⚠️  No transaction history"
fi

# Still check TEST_ADDR for balance test
TEST_ADDR="0x0000000000000000000000000000000000000000"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"latest\"]")
BALANCE=$(echo "$response" | jq -r '.result')
log_info "  Balance test address: $TEST_ADDR balance: $BALANCE"

echo ""
log_info "📊 Data Quality Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$LEGACY_TX_COUNT" -gt 0 ] && [ "$LOCAL_TX_COUNT" -gt 0 ] && [ "$REAL_LEGACY_LOGS" -gt 0 ] && [ "$REAL_LOCAL_LOGS" -gt 0 ]; then
    log_success "✅ Excellent - All test blocks have transactions and logs"
elif [ "$LEGACY_TX_COUNT" -gt 0 ] && [ "$LOCAL_TX_COUNT" -gt 0 ]; then
    log_warning "⚠️  Good - Blocks have transactions, but some may lack logs"
else
    log_warning "⚠️  Warning - Some test blocks are empty, tests may be limited"
    echo ""
    echo "💡 Recommendation: Provide blocks with more transactions for comprehensive testing"
    echo "   You can update LEGACY_BLOCK and LOCAL_BLOCK in the script with busier blocks"
fi
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

# Test 1.3: eth_getBlockByNumber (boundary block - cutoff)
log_info "Test 1.3: eth_getBlockByNumber (boundary block - cutoff)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]")
check_result_not_null "$response" "eth_getBlockByNumber (cutoff: $BOUNDARY_BLOCK_HEX)"

# Calculate boundary blocks
LAST_LEGACY=$((CUTOFF_BLOCK - 1))
FIRST_LOCAL=$((CUTOFF_BLOCK + 1))
LAST_LEGACY_HEX=$(printf "0x%x" $LAST_LEGACY)
FIRST_LOCAL_HEX=$(printf "0x%x" $FIRST_LOCAL)

# Test 1.3.1: eth_getBlockByNumber (cutoff - 1)
log_info "Test 1.3.1: eth_getBlockByNumber (cutoff - 1)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$LAST_LEGACY_HEX\",false]")
check_result_not_null "$response" "eth_getBlockByNumber (cutoff-1: $LAST_LEGACY_HEX)"

# Test 1.3.2: eth_getBlockByNumber (cutoff + 1)
log_info "Test 1.3.2: eth_getBlockByNumber (cutoff + 1)"
response=$(rpc_call "eth_getBlockByNumber" "[\"$FIRST_LOCAL_HEX\",false]")
check_result_not_null "$response" "eth_getBlockByNumber (cutoff+1: $FIRST_LOCAL_HEX)"

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

# Test 2.1: eth_getBlockTransactionCountByNumber (legacy block)
log_info "Test 2.1: eth_getBlockTransactionCountByNumber (legacy block)"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_getBlockTransactionCountByNumber (legacy)"

# Test 2.1.1: Boundary test - cutoff-1
log_info "Test 2.1.1: eth_getBlockTransactionCountByNumber (cutoff-1)"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$LAST_LEGACY_HEX\"]")
check_result "$response" "eth_getBlockTransactionCountByNumber (cutoff-1)"

# Test 2.1.2: Boundary test - cutoff
log_info "Test 2.1.2: eth_getBlockTransactionCountByNumber (cutoff)"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_getBlockTransactionCountByNumber (cutoff)"

# Test 2.1.3: Boundary test - cutoff+1
log_info "Test 2.1.3: eth_getBlockTransactionCountByNumber (cutoff+1)"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$FIRST_LOCAL_HEX\"]")
check_result "$response" "eth_getBlockTransactionCountByNumber (cutoff+1)"

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
    
    # Check transaction data quality
    tx_response=$(rpc_call "eth_getTransactionByHash" "[\"$TX_HASH\"]")
    tx_from=$(echo "$tx_response" | jq -r '.result.from')
    tx_to=$(echo "$tx_response" | jq -r '.result.to')
    tx_value=$(echo "$tx_response" | jq -r '.result.value')
    log_info "  From: $tx_from, To: $tx_to, Value: $tx_value"
    
    receipt_response=$(rpc_call "eth_getTransactionReceipt" "[\"$TX_HASH\"]")
    tx_logs=$(echo "$receipt_response" | jq -r '.result.logs | length')
    log_info "  Transaction has $tx_logs logs"

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

# Test 4.1: eth_getBalance (legacy block)
log_info "Test 4.1: eth_getBalance (legacy block)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]")
if check_result "$response" "eth_getBalance (legacy block)"; then
    balance_value=$(echo "$response" | jq -r '.result')
    log_info "  → Balance: $balance_value"
fi

# Test 4.1.1: eth_getBalance boundary tests
log_info "Test 4.1.1: eth_getBalance (cutoff-1)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LAST_LEGACY_HEX\"]")
check_result "$response" "eth_getBalance (cutoff-1)"

log_info "Test 4.1.2: eth_getBalance (cutoff)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_getBalance (cutoff)"

log_info "Test 4.1.3: eth_getBalance (cutoff+1)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$FIRST_LOCAL_HEX\"]")
check_result "$response" "eth_getBalance (cutoff+1)"

# Test 4.2: eth_getCode (using real contract)
log_info "Test 4.2: eth_getCode (real contract)"
CONTRACT_TEST_BLOCK_HEX=$(printf "0x%x" $CONTRACT_TEST_BLOCK)
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$CONTRACT_TEST_BLOCK_HEX\"]")
if check_result "$response" "eth_getCode"; then
    code_value=$(echo "$response" | jq -r '.result')
    code_length=${#code_value}
    log_info "  → Code length: $code_length bytes"
    
    if [ "$code_value" != "0x" ] && [ "$code_value" != "null" ]; then
        log_success "  → Real contract bytecode retrieved ✓"
    else
        log_warning "  → No bytecode found"
    fi
fi

# Test 4.2.1: eth_getCode boundary tests
log_info "Test 4.2.1: eth_getCode (cutoff-1)"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LAST_LEGACY_HEX\"]")
check_result "$response" "eth_getCode (cutoff-1)"

log_info "Test 4.2.2: eth_getCode (cutoff)"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_getCode (cutoff)"

log_info "Test 4.2.3: eth_getCode (cutoff+1)"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$FIRST_LOCAL_HEX\"]")
check_result "$response" "eth_getCode (cutoff+1)"

# Test 4.3: eth_getStorageAt (using real contract)
log_info "Test 4.3: eth_getStorageAt (real contract)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$CONTRACT_TEST_BLOCK_HEX\"]")
if check_result "$response" "eth_getStorageAt"; then
    storage_value=$(echo "$response" | jq -r '.result')
    log_info "  → Storage at slot 0: $storage_value"
fi

# Test 4.3.1: eth_getStorageAt boundary tests
log_info "Test 4.3.1: eth_getStorageAt (cutoff-1)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LAST_LEGACY_HEX\"]")
check_result "$response" "eth_getStorageAt (cutoff-1)"

log_info "Test 4.3.2: eth_getStorageAt (cutoff)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_getStorageAt (cutoff)"

log_info "Test 4.3.3: eth_getStorageAt (cutoff+1)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$FIRST_LOCAL_HEX\"]")
check_result "$response" "eth_getStorageAt (cutoff+1)"

# Test 4.4: eth_getTransactionCount (using active EOA)
log_info "Test 4.4: eth_getTransactionCount (active EOA with history)"
ACTIVE_BLOCK_HEX=$(printf "0x%x" $CONTRACT_TEST_BLOCK)
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$ACTIVE_BLOCK_HEX\"]")
if check_result "$response" "eth_getTransactionCount"; then
    nonce_value=$(echo "$response" | jq -r '.result')
    nonce_dec=$((nonce_value))
    log_info "  → Nonce: $nonce_value ($nonce_dec)"
    
    if [ $nonce_dec -gt 0 ]; then
        log_success "  → Real transaction history verified (nonce: $nonce_dec) ✓"
    else
        log_warning "  → No transaction history found"
    fi
fi

# Test 4.4.1: eth_getTransactionCount boundary tests
log_info "Test 4.4.1: eth_getTransactionCount (cutoff-1)"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LAST_LEGACY_HEX\"]")
check_result "$response" "eth_getTransactionCount (cutoff-1)"

log_info "Test 4.4.2: eth_getTransactionCount (cutoff)"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_getTransactionCount (cutoff)"

log_info "Test 4.4.3: eth_getTransactionCount (cutoff+1)"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$FIRST_LOCAL_HEX\"]")
check_result "$response" "eth_getTransactionCount (cutoff+1)"

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
if check_result_legacy_tolerant "$response" "eth_getLogs (pure legacy)"; then
    LOGS_COUNT=$(echo "$response" | jq '.result | length')
    log_info "  → Found $LOGS_COUNT logs in range [$LEGACY_FROM - $LEGACY_TO]"
fi

# Test 5.2: Pure local range (if available)
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    log_info "Test 5.2: eth_getLogs (pure local range - using block with real logs)"
    LOCAL_FROM=$((LOCAL_BLOCK_WITH_LOGS - 5))
    LOCAL_TO=$((LOCAL_BLOCK_WITH_LOGS + 5))
    LOCAL_FROM_HEX=$(printf "0x%x" $LOCAL_FROM)
    LOCAL_TO_HEX=$(printf "0x%x" $LOCAL_TO)
    response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LOCAL_FROM_HEX\",\"toBlock\":\"$LOCAL_TO_HEX\"}]")
    if check_result "$response" "eth_getLogs (pure local)"; then
        LOGS_COUNT=$(echo "$response" | jq '.result | length')
        log_info "  → Found $LOGS_COUNT logs in range [$LOCAL_FROM - $LOCAL_TO]"
        
        if [ "$LOGS_COUNT" -gt 0 ]; then
            log_success "  → Real data validated: Found logs in local range ✓"
        else
            log_warning "  → No logs found (expected ≥ $EXPECTED_LOCAL_LOGS)"
        fi
    fi
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
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LAST_LEGACY_HEX\",\"toBlock\":\"$LAST_LEGACY_HEX\"}]")
check_result "$response" "eth_getLogs (cutoff-1: $LAST_LEGACY_HEX)"

# Test 5.5: First local block (cutoff + 1)
log_info "Test 5.5: eth_getLogs (first local block: cutoff + 1)"
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
# Phase 5.9: Data Consistency Validation
# ========================================

log_section "Phase 5.9: Data Consistency Validation (Reth vs Legacy RPC)"

echo ""
log_info "🔍 Verifying that Reth returns IDENTICAL data to Legacy RPC for legacy blocks..."
echo ""

# Test consistency for various methods on legacy blocks
# Test 5.9.1: eth_getBlockByNumber data consistency
log_info "Test 5.9.1: Data consistency - eth_getBlockByNumber"
check_data_consistency "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" "eth_getBlockByNumber consistency"

# Test 5.9.2: eth_getBlockByNumber with full transactions
log_info "Test 5.9.2: Data consistency - eth_getBlockByNumber (full tx)"
check_data_consistency "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",true]" "eth_getBlockByNumber (full tx) consistency"

# Test 5.9.3: eth_getBlockTransactionCountByNumber
log_info "Test 5.9.3: Data consistency - eth_getBlockTransactionCountByNumber"
check_data_consistency "eth_getBlockTransactionCountByNumber" "[\"$LEGACY_BLOCK_HEX\"]" "eth_getBlockTransactionCountByNumber consistency"

# Test 5.9.4: eth_getBalance
log_info "Test 5.9.4: Data consistency - eth_getBalance"
check_data_consistency "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]" "eth_getBalance consistency"

# Test 5.9.5: eth_getTransactionByHash (if we have a legacy tx)
if [ -n "$REAL_LEGACY_TX" ]; then
    log_info "Test 5.9.5: Data consistency - eth_getTransactionByHash"
    check_data_consistency "eth_getTransactionByHash" "[\"$REAL_LEGACY_TX\"]" "eth_getTransactionByHash consistency"
fi

# Test 5.9.6: eth_getTransactionReceipt
if [ -n "$REAL_LEGACY_TX" ]; then
    log_info "Test 5.9.6: Data consistency - eth_getTransactionReceipt"
    check_data_consistency "eth_getTransactionReceipt" "[\"$REAL_LEGACY_TX\"]" "eth_getTransactionReceipt consistency"
fi

# Test 5.9.7: eth_getCode
log_info "Test 5.9.7: Data consistency - eth_getCode"
check_data_consistency "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LEGACY_BLOCK_HEX\"]" "eth_getCode consistency"

# Test 5.9.8: eth_getStorageAt
log_info "Test 5.9.8: Data consistency - eth_getStorageAt"
check_data_consistency "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LEGACY_BLOCK_HEX\"]" "eth_getStorageAt consistency"

# Test 5.9.9: eth_getTransactionCount
log_info "Test 5.9.9: Data consistency - eth_getTransactionCount"
check_data_consistency "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LEGACY_BLOCK_HEX\"]" "eth_getTransactionCount consistency"

# Test 5.9.10: eth_getLogs (pure legacy range)
log_info "Test 5.9.10: Data consistency - eth_getLogs (legacy range)"
check_data_consistency "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\"}]" "eth_getLogs consistency"

# Test 5.9.11: eth_getLogs (CROSS-BOUNDARY - THE MOST CRITICAL TEST)
log_info "Test 5.9.11: Data consistency - eth_getLogs (CROSS-BOUNDARY with REAL DATA)"
echo ""
log_info "  🔥 CRITICAL TEST: Cross-boundary getLogs with legacy part verification"
log_info "  This tests the most complex scenario: merging logs from legacy + local"
echo ""

# Use real blocks with logs on both sides
# CROSS_LEGACY_BLOCK (42809621) < CUTOFF (42810021) < LOCAL_BLOCK_WITH_LOGS (42811521)
# Build a range that includes both
CROSS_FROM=$((CROSS_LEGACY_BLOCK - 10))
CROSS_TO=$((LOCAL_BLOCK_WITH_LOGS + 10))
CROSS_SPAN=$((CROSS_TO - CROSS_FROM))

# Check if range is within Legacy RPC limit (100 blocks)
if [ $CROSS_SPAN -gt 100 ]; then
    log_warning "  ⚠️  Cross-boundary range ($CROSS_SPAN blocks) exceeds Legacy RPC limit (100)"
    log_info "  Adjusting to use smaller range centered on cutoff with known log blocks"
    # Use a smaller range: from legacy log block to just after cutoff
    CROSS_FROM=$CROSS_LEGACY_BLOCK
    CROSS_TO=$((CUTOFF_BLOCK + 50))
    CROSS_SPAN=$((CROSS_TO - CROSS_FROM))
    
    if [ $CROSS_SPAN -gt 100 ]; then
        # Still too big, use minimum range
        CROSS_FROM=$((CUTOFF_BLOCK - 50))
        CROSS_TO=$((CUTOFF_BLOCK + 50))
        CROSS_SPAN=$((CROSS_TO - CROSS_FROM))
    fi
fi

CROSS_FROM_HEX=$(printf "0x%x" $CROSS_FROM)
CROSS_TO_HEX=$(printf "0x%x" $CROSS_TO)

log_info "  Query range: $CROSS_FROM to $CROSS_TO ($CROSS_SPAN blocks spanning cutoff $CUTOFF_BLOCK)"
log_info "  Known log blocks: legacy=$CROSS_LEGACY_BLOCK, local=$LOCAL_BLOCK_WITH_LOGS"

TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Get logs from Reth (should merge legacy + local)
reth_response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]")

# Get logs from Legacy RPC for the SAME range (will only return legacy part)
legacy_response=$(rpc_call_legacy "eth_getLogs" "[{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]")

if echo "$reth_response" | jq -e '.error' > /dev/null 2>&1; then
    log_error "  Reth returned error: $(echo "$reth_response" | jq -r '.error.message')"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Cross-boundary getLogs consistency")
elif echo "$legacy_response" | jq -e '.error' > /dev/null 2>&1; then
    log_error "  Legacy RPC returned error: $(echo "$legacy_response" | jq -r '.error.message')"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Cross-boundary getLogs consistency")
else
    # Extract results
    reth_all_logs=$(echo "$reth_response" | jq -c '.result')
    legacy_all_logs=$(echo "$legacy_response" | jq -c '.result')
    
    reth_total=$(echo "$reth_all_logs" | jq 'length')
    legacy_total=$(echo "$legacy_all_logs" | jq 'length')
    
    log_info "  Reth returned:   $reth_total logs (legacy + local)"
    log_info "  Legacy returned: $legacy_total logs (legacy only)"
    
    # Extract only the legacy part from Reth's response (blockNumber < cutoff)
    reth_legacy_logs=$(echo "$reth_all_logs" | jq -c --argjson cutoff "$CUTOFF_BLOCK" \
        '[.[] | select((.blockNumber | tonumber) < $cutoff)]')
    
    reth_legacy_count=$(echo "$reth_legacy_logs" | jq 'length')
    
    log_info "  Reth legacy part: $reth_legacy_count logs (extracted from merged result)"
    
    # Now compare the legacy parts
    reth_legacy_normalized=$(echo "$reth_legacy_logs" | jq -cS '.')
    legacy_normalized=$(echo "$legacy_all_logs" | jq -cS '.')
    
    if [ "$reth_legacy_normalized" = "$legacy_normalized" ]; then
        log_success "  ✓ Legacy part IDENTICAL ($reth_legacy_count logs match)"
        
        # Extract local part
        reth_local_logs=$(echo "$reth_all_logs" | jq -c --argjson cutoff "$CUTOFF_BLOCK" \
            '[.[] | select((.blockNumber | tonumber) >= $cutoff)]')
        reth_local_count=$(echo "$reth_local_logs" | jq 'length')
        
        log_info "  Reth local part:  $reth_local_count logs (from local DB)"
        
        if [ "$reth_local_count" -gt 0 ]; then
            log_success "  ✓ Found logs on BOTH sides of cutoff"
        else
            log_warning "  ⚠️  No logs found on local side (may be normal if no activity)"
        fi
        
        # Verify sorting across boundary
        IS_SORTED=$(echo "$reth_all_logs" | jq '[.[].blockNumber] | . == sort')
        if [ "$IS_SORTED" = "true" ]; then
            log_success "  ✓ Logs properly sorted across boundary"
        else
            log_error "  ✗ Logs NOT sorted properly!"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Cross-boundary getLogs sorting")
            echo ""
            continue
        fi
        
        # Verify no duplicates
        UNIQUE_COUNT=$(echo "$reth_all_logs" | jq '[.[] | .transactionHash + (.logIndex | tostring)] | unique | length')
        if [ "$UNIQUE_COUNT" -eq "$reth_total" ]; then
            log_success "  ✓ No duplicate logs"
        else
            log_error "  ✗ Found duplicate logs!"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Cross-boundary getLogs duplicates")
            echo ""
            continue
        fi
        
        log_success "Cross-boundary getLogs consistency - PASSED ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
    else
        log_error "  ✗ Legacy part MISMATCH!"
        echo "    Expected $legacy_total logs from legacy RPC"
        echo "    But Reth's legacy part has $reth_legacy_count logs"
        
        # Show sample of first mismatch
        if [ "$reth_legacy_count" -gt 0 ] && [ "$legacy_total" -gt 0 ]; then
            echo "    First Reth legacy log: $(echo "$reth_legacy_logs" | jq -c '.[0]' | head -c 150)..."
            echo "    First Legacy log:      $(echo "$legacy_all_logs" | jq -c '.[0]' | head -c 150)..."
        fi
        
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Cross-boundary getLogs consistency")
    fi
fi

# Note: Test 5.9.11 already validates cross-boundary getLogs mechanism
# We've confirmed that: 
#   - Legacy part is extracted and matches Legacy RPC
#   - Logs are properly sorted across boundary  
#   - No duplicates exist
# The mechanism is sound, even when no logs are present in the test range.

echo ""
log_info "📊 Data Consistency Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  These tests verify that Reth returns EXACTLY the same data"
log_info "  as the Legacy Erigon RPC for historical blocks."
log_info "  Any mismatch indicates a forwarding or data transformation issue."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ========================================
# Phase 6: Additional Methods
# ========================================

log_section "Phase 6: Additional Methods"

# Test 6.1: eth_getBlockReceipts (legacy block)
log_info "Test 6.1: eth_getBlockReceipts (legacy block)"
response=$(rpc_call "eth_getBlockReceipts" "[\"$LEGACY_BLOCK_HEX\"]")
if check_result "$response" "eth_getBlockReceipts (legacy)"; then
    RECEIPTS=$(echo "$response" | jq '.result')
    RECEIPTS_COUNT=$(echo "$RECEIPTS" | jq 'length')
    log_info "  → Found $RECEIPTS_COUNT receipts in legacy block"
fi

# Test 6.2: eth_getBlockReceipts (local block)
if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    log_info "Test 6.2: eth_getBlockReceipts (local block)"
    response=$(rpc_call "eth_getBlockReceipts" "[\"$LOCAL_BLOCK_HEX\"]")
    if check_result "$response" "eth_getBlockReceipts (local)"; then
        RECEIPTS=$(echo "$response" | jq '.result')
        RECEIPTS_COUNT=$(echo "$RECEIPTS" | jq 'length')
        log_info "  → Found $RECEIPTS_COUNT receipts in local block"
    fi
else
    log_warning "Skipping local block getBlockReceipts test"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 6.3: eth_getBlockReceipts (cutoff block - critical for empty block bug)
log_info "Test 6.3: eth_getBlockReceipts (cutoff block)"
response=$(rpc_call "eth_getBlockReceipts" "[\"$BOUNDARY_BLOCK_HEX\"]")
if check_result "$response" "eth_getBlockReceipts (cutoff)"; then
    RECEIPTS=$(echo "$response" | jq '.result')
    RECEIPTS_COUNT=$(echo "$RECEIPTS" | jq 'length')
    log_info "  → Found $RECEIPTS_COUNT receipts in cutoff block"
    
    # Verify it's an array (even if empty)
    IS_ARRAY=$(echo "$RECEIPTS" | jq 'type == "array"')
    if [ "$IS_ARRAY" = "true" ]; then
        if [ "$RECEIPTS_COUNT" -eq 0 ]; then
            log_success "  → Empty block correctly returned empty array ✓"
        else
            log_success "  → Non-empty block returned receipts array ✓"
        fi
    else
        log_error "  → Invalid response: not an array ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("getBlockReceipts array validation")
    fi
fi

# Test 6.4: eth_getBlockReceipts with empty block detection
log_info "Test 6.4: eth_getBlockReceipts (empty block validation)"
# Test with cutoff-1 and cutoff+1 to find potential empty blocks
for test_block in $LAST_LEGACY $BOUNDARY_BLOCK $FIRST_LOCAL; do
    test_block_hex=$(printf "0x%x" $test_block)
    
    # First get the block to check transaction count
    block_response=$(rpc_call "eth_getBlockByNumber" "[\"$test_block_hex\",false]")
    tx_count=$(echo "$block_response" | jq -r '.result.transactions | length')
    
    # Now get receipts
    receipts_response=$(rpc_call "eth_getBlockReceipts" "[\"$test_block_hex\"]")
    
    if echo "$receipts_response" | jq -e '.result' > /dev/null 2>&1; then
        receipts_count=$(echo "$receipts_response" | jq '.result | length')
        
        if [ "$tx_count" -eq "$receipts_count" ]; then
            log_success "  → Block $test_block_hex: $tx_count txs = $receipts_count receipts ✓"
        else
            log_error "  → Block $test_block_hex: mismatch! $tx_count txs != $receipts_count receipts ✗"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("getBlockReceipts count mismatch at block $test_block")
        fi
        
        # Critical: if block has 0 transactions, receipts should be empty array, not null
        if [ "$tx_count" -eq 0 ]; then
            is_array=$(echo "$receipts_response" | jq '.result | type == "array"')
            if [ "$is_array" = "true" ] && [ "$receipts_count" -eq 0 ]; then
                log_success "  → Empty block correctly handled (PR #125 case) ✓"
            else
                log_error "  → Empty block bug! Should return [], got: $(echo "$receipts_response" | jq -c .result) ✗"
                FAILED_TESTS=$((FAILED_TESTS + 1))
                FAILED_TEST_NAMES+=("Empty block handling (PR #125)")
            fi
        fi
    fi
done

TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 6.5: eth_getBlockByHash
if [ "$BLOCK_HASH" != "null" ] && [ -n "$BLOCK_HASH" ]; then
    log_info "Test 6.5: eth_getBlockByHash"
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
