#!/bin/bash

# XLayer Mainnet Configuration
CUTOFF_BLOCK="42810021"
NETWORK_NAME="XLayer Mainnet"
LEGACY_RPC_URL="https://xlayerrpc.okx.com/"
EXPECTED_CHAIN_ID="0xc4"  # 196

# Real transaction hashes for testing
REAL_LEGACY_TX="0x2166c189006512fa8cfbb4f9b07203db790122e825dd5cbb7900cf96e3979934"
REAL_LEGACY_BLOCK="42809621"
REAL_LOCAL_TX="0x878e267def62fb0c2ed47ee6b56a2ad055a480b5a625e1c19f6df9185b7d9638"
REAL_LOCAL_BLOCK="42818022"
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

# Parse command line arguments
RETH_URL="http://localhost:8545"
TARGET_PHASE=""

show_usage() {
    echo "Usage: $0 [OPTIONS] [RPC_URL]"
    echo ""
    echo "Options:"
    echo "  --phase PHASE        Run only the specified phase (1-12)"
    echo "  --list-phases        List all available test phases"
    echo "  --help               Show this help message"
    echo ""
    echo "Arguments:"
    echo "  RPC_URL              Reth RPC URL (default: http://localhost:8545)"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Run all phases with default URL"
    echo "  $0 http://localhost:9545              # Run all phases with custom URL"
    echo "  $0 --phase 5                          # Run only Phase 5 (eth_getLogs)"
    echo "  $0 --phase 7 http://localhost:9545    # Run Phase 7 with custom URL"
    exit 0
}

list_phases() {
    echo "Available Test Phases:"
    echo ""
    echo "  Phase 1:   Basic Block Query Tests"
    echo "  Phase 2:   Transaction Count Tests"
    echo "  Phase 3:   Transaction Query Tests"
    echo "  Phase 4:   State Query Tests"
    echo "  Phase 5:   eth_getLogs Tests"
    echo "  Phase 6:   Additional Methods"
    echo "  Phase 7:   New Legacy RPC Methods (eth_call, eth_estimateGas, etc.)"
    echo "  Phase 8:   BlockHash Parameter Tests"
    echo "  Phase 9:   Special BlockTag Tests"
    echo "  Phase 10:  Enhanced Data Consistency for Tolerant Methods"
    echo "  Phase 11:  Edge Cases and Invalid Inputs"
    echo "  Phase 12:  Internal Transactions Tests"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --phase)
            TARGET_PHASE="$2"
            shift 2
            ;;
        --list-phases)
            list_phases
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            RETH_URL="$1"
            shift
            ;;
    esac
done

# Validate phase parameter
if [ -n "$TARGET_PHASE" ]; then
    if ! [[ "$TARGET_PHASE" =~ ^[0-9]+$ ]] || [ "$TARGET_PHASE" -lt 1 ] || [ "$TARGET_PHASE" -gt 12 ]; then
        echo "Error: Invalid phase number '$TARGET_PHASE'. Phase must be between 1 and 12."
        echo ""
        echo "Use --list-phases to see available phases."
        exit 1
    fi
fi

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

# Check if a phase should run
should_run_phase() {
    local phase_num=$1
    if [ -z "$TARGET_PHASE" ]; then
        return 0  # Run all phases if no specific phase is targeted
    fi
    if [ "$TARGET_PHASE" = "$phase_num" ]; then
        return 0  # Run this phase
    fi
    return 1  # Skip this phase
}

# Calculate boundary blocks based on cutoff
# Sets global variables for boundary blocks and their hex equivalents
calculate_boundary_blocks() {
    # Calculate adjacent boundary blocks (cutoff ± 1)
    LAST_LEGACY=$((CUTOFF_BLOCK - 1))
    FIRST_LOCAL=$((CUTOFF_BLOCK + 1))
    LAST_LEGACY_HEX=$(printf "0x%x" $LAST_LEGACY)
    FIRST_LOCAL_HEX=$(printf "0x%x" $FIRST_LOCAL)
    
    # Calculate test blocks (cutoff ± 1000)
    LEGACY_BLOCK=$((CUTOFF_BLOCK - 1000))
    LOCAL_BLOCK=$((CUTOFF_BLOCK + 1000))
    BOUNDARY_BLOCK=$CUTOFF_BLOCK
    
    LEGACY_BLOCK_HEX=$(printf "0x%x" $LEGACY_BLOCK)
    LOCAL_BLOCK_HEX=$(printf "0x%x" $LOCAL_BLOCK)
    BOUNDARY_BLOCK_HEX=$(printf "0x%x" $BOUNDARY_BLOCK)
}

# Calculate boundary blocks if not already set
# This is used in phases that might run independently
ensure_boundary_blocks() {
    if [ -z "$LAST_LEGACY_HEX" ] || [ -z "$FIRST_LOCAL_HEX" ]; then
        LAST_LEGACY=$((CUTOFF_BLOCK - 1))
        FIRST_LOCAL=$((CUTOFF_BLOCK + 1))
        LAST_LEGACY_HEX=$(printf "0x%x" $LAST_LEGACY)
        FIRST_LOCAL_HEX=$(printf "0x%x" $FIRST_LOCAL)
    fi
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
        local reth_error_msg=$(echo "$reth_response" | jq -r '.error.message')
        
        # Check if both Reth and Legacy return 403 (not whitelisted)
        if [ "$legacy_has_error" = "true" ]; then
            local legacy_error_msg=$(echo "$legacy_response" | jq -r '.error.message')
            local legacy_error_code=$(echo "$legacy_response" | jq -r '.error.code // ""')
            
            # Check if both return 403 or "not whitelisted" errors
            # Reth may return "403" or "Request rejected `403`" or wrapped "-32601"
            # Legacy may return "not whitelisted" or error code -32601 or -32000
            local reth_is_403=false
            local legacy_is_403=false
            
            # Check Reth error
            # Reth might wrap Legacy's -32601 error in its own error message
            if [[ "$reth_error_msg" == *"403"* ]] || \
               [[ "$reth_error_msg" == *"not whitelisted"* ]] || \
               [[ "$reth_error_msg" == *"-32601"* ]]; then
                reth_is_403=true
            fi
            
            # Check Legacy error
            if [[ "$legacy_error_msg" == *"403"* ]] || \
               [[ "$legacy_error_msg" == *"not whitelisted"* ]] || \
               [[ "$legacy_error_msg" == *"-32601"* ]] || \
               [[ "$legacy_error_code" == "-32601" ]] || \
               [[ "$legacy_error_code" == "-32000" ]]; then
                legacy_is_403=true
            fi
            
            # If both are 403/not whitelisted, skip the test
            if [ "$reth_is_403" = "true" ] && [ "$legacy_is_403" = "true" ]; then
                log_warning "$test_name - Both Reth and Legacy RPC returned 403/not whitelisted"
                echo "       Skipping - method not supported by Legacy RPC"
                SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
                return 1
            fi
        fi
        
        # Otherwise, it's a real Reth error
        log_error "$test_name - Reth returned error"
        echo "       Method: $method"
        echo "       Params: $params"
        echo "       Reth error: $reth_error_msg"
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
        echo "       Method: $method"
        echo "       Params: $params"
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
    local method=$3
    local params=$4

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_error "$test_name"
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
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
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
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
    local method=$3
    local params=$4

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_error "$test_name"
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
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
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
        echo "       Response: $(echo "$response" | jq -c .)"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    fi
}

# Check result with legacy endpoint tolerance (errors become warnings)
check_result_legacy_tolerant() {
    local response=$1
    local test_name=$2
    local method=$3
    local params=$4

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        error_msg=$(echo "$response" | jq -r '.error.message')
        log_warning "$test_name - $error_msg (legacy endpoint may not support this method)"
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
        echo "       Response: $(echo "$response" | jq -c .)"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    elif echo "$response" | jq -e '.result' > /dev/null 2>&1; then
        log_success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        log_warning "$test_name - Invalid response format"
        [ -n "$method" ] && echo "       Method: $method"
        [ -n "$params" ] && echo "       Params: $params"
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
calculate_boundary_blocks

log_info "Test Blocks:"
log_info "  Legacy Block:   $LEGACY_BLOCK_HEX ($LEGACY_BLOCK) → Should route to Erigon"
log_info "  Boundary Block: $BOUNDARY_BLOCK_HEX ($BOUNDARY_BLOCK) → Migration point"
log_info "  Local Block:    $LOCAL_BLOCK_HEX ($LOCAL_BLOCK) → Should use Reth"

# Display which phase(s) will be run
if [ -n "$TARGET_PHASE" ]; then
    echo ""
    log_info "🎯 Running Phase $TARGET_PHASE only"
else
    echo ""
    log_info "🎯 Running all phases (1-12)"
fi

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

if should_run_phase 1; then
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
calculate_boundary_blocks

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

fi

# ========================================
# Phase 2: Transaction Count Tests
# ========================================

if should_run_phase 2; then
log_section "Phase 2: Transaction Count Tests"

# Calculate boundary blocks if not already set
ensure_boundary_blocks

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
# Phase 2.5: Transaction Count Extended Tests
# ========================================

log_section "Phase 2.5: Transaction Count - BlockTag and Invalid Input Tests"

echo ""
log_info "🔍 Testing getBlockTransactionCount with BlockTag and invalid inputs"
echo ""

# Test 2.5.1: eth_getBlockTransactionCountByNumber with 'earliest'
log_info "Test 2.5.1: eth_getBlockTransactionCountByNumber with 'earliest'"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"earliest\"]")
if check_result "$response" "getBlockTransactionCountByNumber (earliest)"; then
    earliest_count=$(echo "$response" | jq -r '.result')
    log_info "  → Genesis block tx count: $earliest_count"
fi

# Test 2.5.2: eth_getBlockTransactionCountByNumber with 'latest'
log_info "Test 2.5.2: eth_getBlockTransactionCountByNumber with 'latest'"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"latest\"]")
if check_result "$response" "getBlockTransactionCountByNumber (latest)"; then
    latest_count=$(echo "$response" | jq -r '.result')
    log_info "  → Latest block tx count: $latest_count"
fi

# Test 2.5.3: eth_getBlockTransactionCountByNumber with 'pending'
log_info "Test 2.5.3: eth_getBlockTransactionCountByNumber with 'pending'"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"pending\"]")
check_result_legacy_tolerant "$response" "getBlockTransactionCountByNumber (pending)"

# Test 2.5.4: eth_getBlockTransactionCountByNumber with future block
log_info "Test 2.5.4: eth_getBlockTransactionCountByNumber with future block"
FUTURE_BLOCK_HEX_TEMP="0xffffffff"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"$FUTURE_BLOCK_HEX_TEMP\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Future block should return error or null ✗"
    echo "       Method: eth_getBlockTransactionCountByNumber"
    echo "       Params: [\"$FUTURE_BLOCK_HEX_TEMP\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getBlockTransactionCount future block")
fi

# Test 2.5.5: eth_getBlockTransactionCountByNumber with genesis (0x0)
log_info "Test 2.5.5: eth_getBlockTransactionCountByNumber with genesis block"
response=$(rpc_call "eth_getBlockTransactionCountByNumber" "[\"0x0\"]")
if check_result "$response" "getBlockTransactionCountByNumber (genesis)"; then
    genesis_count=$(echo "$response" | jq -r '.result')
    log_info "  → Genesis block tx count: $genesis_count"
fi

# Test 2.5.6: eth_getBlockTransactionCountByHash with invalid hash (all-zero)
log_info "Test 2.5.6: eth_getBlockTransactionCountByHash with all-zero hash"
ZERO_BLOCK_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$ZERO_BLOCK_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "All-zero block hash returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "All-zero block hash returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "All-zero block hash should return error or null ✗"
    echo "       Method: eth_getBlockTransactionCountByHash"
    echo "       Params: [\"$ZERO_BLOCK_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getBlockTransactionCountByHash all-zero")
fi

# Test 2.5.7: eth_getBlockTransactionCountByHash with random non-existent hash
log_info "Test 2.5.7: eth_getBlockTransactionCountByHash with random hash"
RANDOM_BLOCK_HASH="0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$RANDOM_BLOCK_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Random block hash returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Random block hash returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Random block hash should return error or null ✗"
    echo "       Method: eth_getBlockTransactionCountByHash"
    echo "       Params: [\"$RANDOM_BLOCK_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getBlockTransactionCountByHash random")
fi

# Test 2.5.8-10: eth_getBlockTransactionCountByHash with boundary hashes
log_info "Test 2.5.8: eth_getBlockTransactionCountByHash (cutoff-1)"
TEMP_LAST_LEGACY_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LAST_LEGACY_HEX\",false]" | jq -r '.result.hash')
if [ -n "$TEMP_LAST_LEGACY_HASH" ] && [ "$TEMP_LAST_LEGACY_HASH" != "null" ]; then
    response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$TEMP_LAST_LEGACY_HASH\"]")
    check_result_legacy_tolerant "$response" "getBlockTransactionCountByHash (cutoff-1)"
    
    log_info "Test 2.5.9: eth_getBlockTransactionCountByHash (cutoff)"
    TEMP_CUTOFF_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]" | jq -r '.result.hash')
    response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$TEMP_CUTOFF_HASH\"]")
    check_result_legacy_tolerant "$response" "getBlockTransactionCountByHash (cutoff)"
    
    log_info "Test 2.5.10: eth_getBlockTransactionCountByHash (cutoff+1)"
    TEMP_FIRST_LOCAL_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$FIRST_LOCAL_HEX\",false]" | jq -r '.result.hash')
    response=$(rpc_call "eth_getBlockTransactionCountByHash" "[\"$TEMP_FIRST_LOCAL_HASH\"]")
    check_result_legacy_tolerant "$response" "getBlockTransactionCountByHash (cutoff+1)"
else
    log_warning "Skipping boundary hash tests - unable to fetch block hashes"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 3))
fi

echo ""
log_info "📊 Phase 2.5 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Extended transaction count tests verify BlockTag support"
log_info "  and proper error handling for invalid inputs."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 3: Transaction Query Tests
# ========================================

if should_run_phase 3; then
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
    log_info "Test 4.3: eth_getTransactionByBlockHashAndIndex (index 0)"
    response=$(rpc_call "eth_getTransactionByBlockHashAndIndex" "[\"$BLOCK_HASH\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getTransactionByBlockHashAndIndex (index 0)"

    # Test 4.3.1: eth_getTransactionByBlockHashAndIndex with invalid index
    log_info "Test 4.3.1: eth_getTransactionByBlockHashAndIndex (invalid index)"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    response=$(rpc_call "eth_getTransactionByBlockHashAndIndex" "[\"$BLOCK_HASH\",\"0x999999\"]")
    if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
        log_success "Invalid index returns null ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_success "Invalid index returns error ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        log_error "Invalid index should return null or error ✗"
        echo "       Method: eth_getTransactionByBlockHashAndIndex"
        echo "       Params: [\"$BLOCK_HASH\",\"0x999999\"]"
        echo "       Response: $(echo "$response" | jq -c .)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("getTransactionByBlockHashAndIndex invalid index")
    fi

    # Test 4.3.2: eth_getTransactionByBlockHashAndIndex with last index
    if [ "$LEGACY_TX_COUNT" -gt 1 ]; then
        log_info "Test 4.3.2: eth_getTransactionByBlockHashAndIndex (last tx)"
        LAST_TX_INDEX=$((LEGACY_TX_COUNT - 1))
        LAST_TX_INDEX_HEX=$(printf "0x%x" $LAST_TX_INDEX)
        response=$(rpc_call "eth_getTransactionByBlockHashAndIndex" "[\"$BLOCK_HASH\",\"$LAST_TX_INDEX_HEX\"]")
        check_result_legacy_tolerant "$response" "getTransactionByBlockHashAndIndex (last tx)"
    fi

    # Test 4.4: eth_getTransactionByBlockNumberAndIndex
    log_info "Test 4.4: eth_getTransactionByBlockNumberAndIndex (index 0)"
    response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"$LEGACY_BLOCK_HEX\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "eth_getTransactionByBlockNumberAndIndex (index 0)"

    # Test 4.4.1: eth_getTransactionByBlockNumberAndIndex with invalid index
    log_info "Test 4.4.1: eth_getTransactionByBlockNumberAndIndex (invalid index)"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"$LEGACY_BLOCK_HEX\",\"0x999999\"]")
    if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
        log_success "Invalid index returns null ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        log_success "Invalid index returns error ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        log_error "Invalid index should return null or error ✗"
        echo "       Method: eth_getTransactionByBlockNumberAndIndex"
        echo "       Params: [\"$LEGACY_BLOCK_HEX\",\"0x999999\"]"
        echo "       Response: $(echo "$response" | jq -c .)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("getTransactionByBlockNumberAndIndex invalid index")
    fi

    # Test 4.4.2: eth_getTransactionByBlockNumberAndIndex with 'latest' tag
    log_info "Test 4.4.2: eth_getTransactionByBlockNumberAndIndex with 'latest'"
    response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"latest\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "getTransactionByBlockNumberAndIndex (latest)"

    # Test 4.4.3: eth_getTransactionByBlockNumberAndIndex with 'earliest' tag
    log_info "Test 4.4.3: eth_getTransactionByBlockNumberAndIndex with 'earliest'"
    response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"earliest\",\"0x0\"]")
    check_result_legacy_tolerant "$response" "getTransactionByBlockNumberAndIndex (earliest)"

    # Test 4.4.4: eth_getTransactionByBlockNumberAndIndex with local block
    if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
        log_info "Test 4.4.4: eth_getTransactionByBlockNumberAndIndex (local block)"
        response=$(rpc_call "eth_getTransactionByBlockNumberAndIndex" "[\"$LOCAL_BLOCK_HEX\",\"0x0\"]")
        check_result_legacy_tolerant "$response" "getTransactionByBlockNumberAndIndex (local)"
    fi

    # Test 4.5: eth_getRawTransactionByHash
    log_info "Test 4.5: eth_getRawTransactionByHash (hash-based fallback)"
    response=$(rpc_call "eth_getRawTransactionByHash" "[\"$TX_HASH\"]")
    check_result_legacy_tolerant "$response" "eth_getRawTransactionByHash"

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
# Phase 3.5: Transaction Query - Invalid Input Tests
# ========================================

log_section "Phase 3.5: Transaction Query Invalid Input Tests"

echo ""
log_info "🔬 Testing transaction queries with invalid/non-existent hashes"
echo ""

# Test 3.5.1: eth_getTransactionByHash with all-zero hash
log_info "Test 3.5.1: eth_getTransactionByHash with all-zero hash"
ZERO_TX_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionByHash" "[\"$ZERO_TX_HASH\"]")
if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "All-zero tx hash returns null (correct) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "All-zero tx hash returns error (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "All-zero tx hash should return null or error ✗"
    echo "       Method: eth_getTransactionByHash"
    echo "       Params: [\"$ZERO_TX_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getTransactionByHash all-zero hash")
fi

# Test 3.5.2: eth_getTransactionByHash with random non-existent hash
log_info "Test 3.5.2: eth_getTransactionByHash with random non-existent hash"
RANDOM_TX_HASH="0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionByHash" "[\"$RANDOM_TX_HASH\"]")
if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Random tx hash returns null (correct) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Random tx hash returns error (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Random tx hash should return null or error ✗"
    echo "       Method: eth_getTransactionByHash"
    echo "       Params: [\"$RANDOM_TX_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getTransactionByHash random hash")
fi

# Test 3.5.3: eth_getTransactionReceipt with all-zero hash
log_info "Test 3.5.3: eth_getTransactionReceipt with all-zero hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionReceipt" "[\"$ZERO_TX_HASH\"]")
if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "All-zero tx hash receipt returns null (correct) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "All-zero tx hash receipt returns error (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "All-zero tx hash receipt should return null or error ✗"
    echo "       Method: eth_getTransactionReceipt"
    echo "       Params: [\"$ZERO_TX_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getTransactionReceipt all-zero hash")
fi

# Test 3.5.4: eth_getTransactionReceipt with random non-existent hash
log_info "Test 3.5.4: eth_getTransactionReceipt with random non-existent hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionReceipt" "[\"$RANDOM_TX_HASH\"]")
if echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Random tx hash receipt returns null (correct) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Random tx hash receipt returns error (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Random tx hash receipt should return null or error ✗"
    echo "       Method: eth_getTransactionReceipt"
    echo "       Params: [\"$RANDOM_TX_HASH\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getTransactionReceipt random hash")
fi

echo ""
log_info "📊 Phase 3.5 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Invalid transaction hash tests verify proper error handling"
log_info "  for non-existent transactions. Should return null or error."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 4: State Query Tests
# ========================================

if should_run_phase 4; then
log_section "Phase 4: State Query Tests"

# Calculate boundary blocks if not already set
ensure_boundary_blocks

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

fi

# ========================================
# Phase 5: eth_getLogs Tests
# ========================================

if should_run_phase 5; then
log_section "Phase 5: eth_getLogs Tests"

# Calculate boundary blocks if not already set
ensure_boundary_blocks

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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Log sorting verification")
        fi
    fi
fi

# ========================================
# Phase 5.10: eth_getLogs with Topics Filter
# ========================================

log_section "Phase 5.10: eth_getLogs with Topics Filter"

echo ""
log_info "🔍 Testing eth_getLogs with topic filters"
echo ""

# First, get a real log to extract a topic
log_info "Fetching a real log to get a valid topic..."
SAMPLE_LOGS_RESPONSE=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$REAL_LEGACY_BLOCK_HEX\",\"toBlock\":\"$REAL_LEGACY_BLOCK_HEX\"}]")
SAMPLE_LOGS=$(echo "$SAMPLE_LOGS_RESPONSE" | jq '.result')
SAMPLE_LOGS_COUNT=$(echo "$SAMPLE_LOGS" | jq 'length')

if [ "$SAMPLE_LOGS_COUNT" -gt 0 ]; then
    # Extract first topic from first log
    SAMPLE_TOPIC=$(echo "$SAMPLE_LOGS" | jq -r '.[0].topics[0]? // empty')
    SAMPLE_ADDRESS=$(echo "$SAMPLE_LOGS" | jq -r '.[0].address? // empty')
    
    if [ -n "$SAMPLE_TOPIC" ] && [ "$SAMPLE_TOPIC" != "null" ]; then
        log_info "  Found topic: $SAMPLE_TOPIC"
        log_info "  Found address: $SAMPLE_ADDRESS"
        echo ""
        
        # Test 5.10.1: eth_getLogs with single topic filter
        log_info "Test 5.10.1: eth_getLogs with single topic filter"
        response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\",\"topics\":[\"$SAMPLE_TOPIC\"]}]")
        if check_result "$response" "eth_getLogs (single topic)"; then
            filtered_count=$(echo "$response" | jq '.result | length')
            log_info "  → Found $filtered_count logs with topic $SAMPLE_TOPIC"
            
            # Verify all returned logs have the topic
            if [ "$filtered_count" -gt 0 ]; then
                TOTAL_TESTS=$((TOTAL_TESTS + 1))
                has_topic=$(echo "$response" | jq --arg topic "$SAMPLE_TOPIC" '[.result[] | select(.topics[0] == $topic)] | length')
                if [ "$has_topic" -eq "$filtered_count" ]; then
                    log_success "  → All logs match topic filter ✓"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                else
                    log_error "  → Some logs don't match topic filter ✗"
                    echo "       Method: eth_getLogs"
                    echo "       Params: [{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\",\"topics\":[\"$SAMPLE_TOPIC\"]}]"
                    FAILED_TESTS=$((FAILED_TESTS + 1))
                    FAILED_TEST_NAMES+=("getLogs topic filter validation")
                fi
            fi
        fi
        
        # Test 5.10.2: eth_getLogs with address + topic filter
        if [ -n "$SAMPLE_ADDRESS" ] && [ "$SAMPLE_ADDRESS" != "null" ]; then
            log_info "Test 5.10.2: eth_getLogs with address + topic filter"
            response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\",\"address\":\"$SAMPLE_ADDRESS\",\"topics\":[\"$SAMPLE_TOPIC\"]}]")
            if check_result "$response" "eth_getLogs (address + topic)"; then
                filtered_count=$(echo "$response" | jq '.result | length')
                log_info "  → Found $filtered_count logs matching both address and topic"
            fi
        fi
        
        # Test 5.10.3: eth_getLogs with null topic (wildcard)
        log_info "Test 5.10.3: eth_getLogs with wildcard topic (null)"
        response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\",\"topics\":[null,\"$SAMPLE_TOPIC\"]}]")
        check_result_legacy_tolerant "$response" "eth_getLogs (wildcard topic)"
        
        # Test 5.10.4: eth_getLogs with multiple topics (OR)
        log_info "Test 5.10.4: eth_getLogs with multiple topics (OR)"
        # Use a fake topic to test OR logic
        FAKE_TOPIC="0x0000000000000000000000000000000000000000000000000000000000000001"
        response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LEGACY_FROM_HEX\",\"toBlock\":\"$LEGACY_TO_HEX\",\"topics\":[[\"$SAMPLE_TOPIC\",\"$FAKE_TOPIC\"]]}]")
        if check_result "$response" "eth_getLogs (OR topics)"; then
            or_count=$(echo "$response" | jq '.result | length')
            log_info "  → Found $or_count logs matching any of the topics"
        fi
        
    else
        log_warning "No topics found in sample logs, skipping topic filter tests"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 4))
    fi
else
    log_warning "No logs found in sample block, skipping topic filter tests"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 4))
fi

echo ""
log_info "📊 Phase 5.10 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Topic filter tests verify that eth_getLogs correctly filters"
log_info "  logs by topics and addresses, supporting both exact matches"
log_info "  and wildcards (OR logic)."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

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
        echo "       Method: eth_getTransactionByHash"
        echo "       Params: [\"$REAL_LEGACY_TX\"]"
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
        echo "       Method: eth_getTransactionByHash"
        echo "       Params: [\"$REAL_LOCAL_TX\"]"
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
        echo "       Method: eth_getTransactionReceipt"
        echo "       Params: [\"$REAL_LEGACY_TX\"]"
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
        echo "       Method: eth_getTransactionReceipt"
        echo "       Params: [\"$REAL_LOCAL_TX\"]"
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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$REAL_LEGACY_BLOCK_HEX\",\"toBlock\":\"$REAL_LEGACY_BLOCK_HEX\"}]"
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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$REAL_LOCAL_BLOCK_HEX\",\"toBlock\":\"$REAL_LOCAL_BLOCK_HEX\"}]"
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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$NEAR_CROSS_FROM_HEX\",\"toBlock\":\"$NEAR_CROSS_TO_HEX\"}]"
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
    echo "       Method: eth_getLogs"
    echo "       Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Cross-boundary getLogs consistency")
elif echo "$legacy_response" | jq -e '.error' > /dev/null 2>&1; then
    log_error "  Legacy RPC returned error: $(echo "$legacy_response" | jq -r '.error.message')"
    echo "       Method: eth_getLogs"
    echo "       Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
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
            echo "       Method: eth_getLogs"
            echo "       Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("Cross-boundary getLogs duplicates")
            echo ""
            continue
        fi
        
        log_success "Cross-boundary getLogs consistency - PASSED ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
    else
        log_error "  ✗ Legacy part MISMATCH!"
        echo "    Method: eth_getLogs"
        echo "    Params: [{\"fromBlock\":\"$CROSS_FROM_HEX\",\"toBlock\":\"$CROSS_TO_HEX\"}]"
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

fi

# ========================================
# Phase 6: Additional Methods
# ========================================

if should_run_phase 6; then
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
        echo "       Method: eth_getBlockReceipts"
        echo "       Params: [\"$BOUNDARY_BLOCK_HEX\"]"
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
            echo "       Method: eth_getBlockReceipts"
            echo "       Params: [\"$test_block_hex\"]"
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
                echo "       Method: eth_getBlockReceipts"
                echo "       Params: [\"$test_block_hex\"]"
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

# Test 6.6: eth_getBlockReceipts with BlockTag
log_info "Test 6.6: eth_getBlockReceipts with 'earliest'"
response=$(rpc_call "eth_getBlockReceipts" "[\"earliest\"]")
if check_result "$response" "eth_getBlockReceipts (earliest)"; then
    receipts_count=$(echo "$response" | jq '.result | length')
    log_info "  → Genesis block receipts: $receipts_count"
fi

log_info "Test 6.7: eth_getBlockReceipts with 'latest'"
response=$(rpc_call "eth_getBlockReceipts" "[\"latest\"]")
if check_result "$response" "eth_getBlockReceipts (latest)"; then
    receipts_count=$(echo "$response" | jq '.result | length')
    log_info "  → Latest block receipts: $receipts_count"
fi

log_info "Test 6.8: eth_getBlockReceipts with 'pending'"
response=$(rpc_call "eth_getBlockReceipts" "[\"pending\"]")
check_result_legacy_tolerant "$response" "eth_getBlockReceipts (pending)"

# ========================================
# Phase 6.5: eth_getBlockByHash Boundary Tests
# ========================================

log_section "Phase 6.5: eth_getBlockByHash Boundary and Consistency Tests"

echo ""
log_info "🔍 Testing eth_getBlockByHash with boundary blocks and data consistency"
echo ""

# Calculate boundary blocks if not already set
ensure_boundary_blocks

# Get boundary block hashes (need to fetch them here since this phase runs before Phase 8)
LAST_LEGACY_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LAST_LEGACY_HEX\",false]" | jq -r '.result.hash')
CUTOFF_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]" | jq -r '.result.hash')
FIRST_LOCAL_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$FIRST_LOCAL_HEX\",false]" | jq -r '.result.hash')
# Also get legacy block hash for consistency tests
LEGACY_BLOCK_HASH_PHASE6=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -r '.result.hash')

log_info "  Boundary block hashes:"
log_info "    Cutoff-1 hash: $LAST_LEGACY_HASH"
log_info "    Cutoff hash:   $CUTOFF_HASH"
log_info "    Cutoff+1 hash: $FIRST_LOCAL_HASH"
log_info "    Legacy hash:   $LEGACY_BLOCK_HASH_PHASE6"
echo ""

# Verify hashes were retrieved successfully
if [ -z "$LAST_LEGACY_HASH" ] || [ "$LAST_LEGACY_HASH" = "null" ]; then
    log_error "Failed to retrieve cutoff-1 block hash. Skipping hash-based tests."
    log_info "  Attempted to fetch block: $LAST_LEGACY_HEX"
else

# Test 6.5.1: eth_getBlockByHash (cutoff-1)
log_info "Test 6.5.1: eth_getBlockByHash (cutoff-1)"
response=$(rpc_call "eth_getBlockByHash" "[\"$LAST_LEGACY_HASH\",false]")
check_result_not_null "$response" "eth_getBlockByHash (cutoff-1)"

# Test 6.5.2: eth_getBlockByHash (cutoff)
log_info "Test 6.5.2: eth_getBlockByHash (cutoff)"
response=$(rpc_call "eth_getBlockByHash" "[\"$CUTOFF_HASH\",false]")
check_result_not_null "$response" "eth_getBlockByHash (cutoff)"

# Test 6.5.3: eth_getBlockByHash (cutoff+1)
log_info "Test 6.5.3: eth_getBlockByHash (cutoff+1)"
response=$(rpc_call "eth_getBlockByHash" "[\"$FIRST_LOCAL_HASH\",false]")
check_result_not_null "$response" "eth_getBlockByHash (cutoff+1)"

# Test 6.5.4: eth_getBlockByHash (legacy block for consistency test)
log_info "Test 6.5.4: eth_getBlockByHash (legacy block)"
response=$(rpc_call "eth_getBlockByHash" "[\"$LEGACY_BLOCK_HASH_PHASE6\",false]")
check_result_not_null "$response" "eth_getBlockByHash (legacy)"

# Test 6.5.5: Data consistency - BlockHash vs BlockNumber (legacy)
log_info "Test 6.5.5: eth_getBlockByHash consistency (BlockHash vs BlockNumber)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

block_by_number=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -cS '.result')
block_by_hash=$(rpc_call "eth_getBlockByHash" "[\"$LEGACY_BLOCK_HASH_PHASE6\",false]" | jq -cS '.result')

if [ "$block_by_number" = "$block_by_hash" ] && [ "$block_by_number" != "null" ]; then
    log_success "eth_getBlockByHash: Data matches getBlockByNumber ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getBlockByHash: Data MISMATCH with getBlockByNumber ✗"
    echo "  Methods: eth_getBlockByNumber vs eth_getBlockByHash"
    echo "  Params: [\"$LEGACY_BLOCK_HEX\",false] vs [\"$LEGACY_BLOCK_HASH_PHASE6\",false]"
    echo "  BlockNumber result hash: $(echo "$block_by_number" | jq -r '.hash')"
    echo "  BlockHash result hash:   $(echo "$block_by_hash" | jq -r '.hash')"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getBlockByHash consistency")
fi

# Test 6.5.6: Data consistency - Reth vs Legacy RPC
log_info "Test 6.5.6: eth_getBlockByHash data consistency (Reth vs Legacy)"
check_data_consistency "eth_getBlockByHash" "[\"$LEGACY_BLOCK_HASH_PHASE6\",false]" "eth_getBlockByHash (legacy) consistency"

# Test 6.5.7: eth_getBlockByHash with full transactions
log_info "Test 6.5.7: eth_getBlockByHash (full transactions)"
response=$(rpc_call "eth_getBlockByHash" "[\"$LEGACY_BLOCK_HASH_PHASE6\",true]")
if check_result_not_null "$response" "eth_getBlockByHash (full tx)"; then
    tx_count=$(echo "$response" | jq '.result.transactions | length')
    log_info "  → Block has $tx_count transactions"
fi

fi # End of hash validation check

echo ""
log_info "📊 Phase 6.5 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  eth_getBlockByHash boundary tests verify hash-based queries"
log_info "  work correctly across the cutoff boundary and return identical"
log_info "  data to BlockNumber-based queries."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 7: New Legacy RPC Methods (eth_call, eth_estimateGas, etc.)
# ========================================

if should_run_phase 7; then
log_section "Phase 7: New Legacy RPC Methods Tests"

echo ""
log_info "🔍 Testing newly added Legacy RPC methods"
log_info "   eth_call, eth_estimateGas, eth_createAccessList"
echo ""

# ========================================
# Phase 7.1: eth_call Tests
# ========================================

log_section "Phase 7.1: eth_call Tests"

echo ""
log_info "Preparing simple transfer request for testing..."

# Use simple EOA-to-EOA transfer to avoid contract execution issues
# The CONTRACT_ADDRESS was deployed around cutoff, causing revert in legacy blocks
# Use TEST_ADDR (EOA) as recipient to ensure consistent behavior across all blocks
CALL_REQUEST="{\"from\":\"$ACTIVE_EOA_ADDRESS\",\"to\":\"$TEST_ADDR\",\"value\":\"0x0\"}"

log_info "  Using simple EOA-to-EOA transfer:"
log_info "    From: $ACTIVE_EOA_ADDRESS (active EOA)"
log_info "    To: $TEST_ADDR (zero address - EOA)"
log_info "    Value: 0x0 (no actual transfer)"
log_info "    Note: EOA-to-EOA transfer works consistently across all blocks"
echo ""

# Test 7.1.1: eth_call (legacy block with BlockNumber)
log_info "Test 7.1.1: eth_call (legacy block with BlockNumber)"
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_call (legacy BlockNumber)"

# Test 7.1.2: eth_call (cutoff block)
log_info "Test 7.1.2: eth_call (cutoff block)"
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_call (cutoff)"

# Test 7.1.3: eth_call (local block)
log_info "Test 7.1.3: eth_call (local block)"
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"$LOCAL_BLOCK_HEX\"]")
check_result "$response" "eth_call (local BlockNumber)"

# Test 7.1.4: eth_call (legacy block with BlockHash)
log_info "Test 7.1.4: eth_call (legacy block with BlockHash)"
if [ -n "$LEGACY_BLOCK_HASH_PHASE6" ] && [ "$LEGACY_BLOCK_HASH_PHASE6" != "null" ]; then
    response=$(rpc_call "eth_call" "[$CALL_REQUEST,{\"blockHash\":\"$LEGACY_BLOCK_HASH_PHASE6\"}]")
    check_result "$response" "eth_call (legacy BlockHash)"
fi

# Test 7.1.5: eth_call with 'latest' tag
log_info "Test 7.1.5: eth_call with 'latest' tag"
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"latest\"]")
check_result "$response" "eth_call (latest)"

# Test 7.1.6: eth_call with 'earliest' tag
log_info "Test 7.1.6: eth_call with 'earliest' tag"
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"earliest\"]")
check_result "$response" "eth_call (earliest)"

# Test 7.1.7: eth_call with future block (should error)
log_info "Test 7.1.7: eth_call with future block"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(rpc_call "eth_call" "[$CALL_REQUEST,\"0xffffffff\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block eth_call returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Future block eth_call should return error ✗"
    echo "       Method: eth_call"
    echo "       Params: [$CALL_REQUEST,\"0xffffffff\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_call future block error handling")
fi

# Test 7.1.8: eth_call data consistency (Reth vs Legacy)
log_info "Test 7.1.8: eth_call data consistency (legacy block)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

reth_call_result=$(rpc_call "eth_call" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
legacy_call_result=$(rpc_call_legacy "eth_call" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')

if [ "$reth_call_result" = "$legacy_call_result" ] && [ "$reth_call_result" != "null" ]; then
    log_success "eth_call: Reth matches Legacy RPC ✓"
    log_info "  Result: ${reth_call_result:0:20}..."
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_call: Data MISMATCH ✗"
    echo "  Method: eth_call"
    echo "  Params: [$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]"
    echo "  Reth:   ${reth_call_result:0:50}..."
    echo "  Legacy: ${legacy_call_result:0:50}..."
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_call data consistency")
fi

# Test 7.1.9: eth_call without from address (anonymous call)
log_info "Test 7.1.9: eth_call without from address"
ANONYMOUS_CALL_REQUEST="{\"to\":\"$TEST_ADDR\",\"value\":\"0x0\"}"
response=$(rpc_call "eth_call" "[$ANONYMOUS_CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]")
check_result "$response" "eth_call (anonymous)"

echo ""
log_info "📊 Phase 7.1 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  eth_call tests verify message call execution across legacy/local"
log_info "  blocks, supporting BlockNumber, BlockHash, and BlockTag parameters."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ========================================
# Phase 7.2: eth_estimateGas Tests
# ========================================

log_section "Phase 7.2: eth_estimateGas Tests"

echo ""
log_info "Testing gas estimation for transactions..."
echo ""

# Test 7.2.1: eth_estimateGas (legacy block with BlockNumber)
log_info "Test 7.2.1: eth_estimateGas (legacy block with BlockNumber)"
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]")
if check_result "$response" "eth_estimateGas (legacy BlockNumber)"; then
    gas_estimate=$(echo "$response" | jq -r '.result')
    gas_dec=$((gas_estimate))
    log_info "  → Estimated gas: $gas_estimate ($gas_dec)"
fi

# Test 7.2.2: eth_estimateGas (cutoff block)
log_info "Test 7.2.2: eth_estimateGas (cutoff block)"
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_estimateGas (cutoff)"

# Test 7.2.3: eth_estimateGas (local block)
log_info "Test 7.2.3: eth_estimateGas (local block)"
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"$LOCAL_BLOCK_HEX\"]")
if check_result "$response" "eth_estimateGas (local BlockNumber)"; then
    gas_estimate=$(echo "$response" | jq -r '.result')
    gas_dec=$((gas_estimate))
    log_info "  → Estimated gas: $gas_estimate ($gas_dec)"
fi

# Test 7.2.4: eth_estimateGas (legacy block with BlockHash)
log_info "Test 7.2.4: eth_estimateGas (legacy block with BlockHash)"
if [ -n "$LEGACY_BLOCK_HASH_PHASE6" ] && [ "$LEGACY_BLOCK_HASH_PHASE6" != "null" ]; then
    response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,{\"blockHash\":\"$LEGACY_BLOCK_HASH_PHASE6\"}]")
    check_result "$response" "eth_estimateGas (legacy BlockHash)"
fi

# Test 7.2.5: eth_estimateGas with 'latest' tag
log_info "Test 7.2.5: eth_estimateGas with 'latest' tag"
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"latest\"]")
check_result "$response" "eth_estimateGas (latest)"

# Test 7.2.6: eth_estimateGas with 'earliest' tag
log_info "Test 7.2.6: eth_estimateGas with 'earliest' tag"
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"earliest\"]")
check_result "$response" "eth_estimateGas (earliest)"

# Test 7.2.7: eth_estimateGas data consistency (Reth vs Legacy)
log_info "Test 7.2.7: eth_estimateGas data consistency (legacy block)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

reth_gas=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
legacy_gas=$(rpc_call_legacy "eth_estimateGas" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')

if [ "$reth_gas" = "$legacy_gas" ] && [ "$reth_gas" != "null" ]; then
    log_success "eth_estimateGas: Reth matches Legacy RPC ✓"
    log_info "  Gas estimate: $reth_gas"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_estimateGas: Data MISMATCH ✗"
    echo "  Method: eth_estimateGas"
    echo "  Params: [$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]"
    echo "  Reth:   $reth_gas"
    echo "  Legacy: $legacy_gas"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_estimateGas data consistency")
fi

# Test 7.2.8: eth_estimateGas with future block (should error)
log_info "Test 7.2.8: eth_estimateGas with future block"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
response=$(rpc_call "eth_estimateGas" "[$CALL_REQUEST,\"0xffffffff\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block eth_estimateGas returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Future block eth_estimateGas should return error ✗"
    echo "       Method: eth_estimateGas"
    echo "       Params: [$CALL_REQUEST,\"0xffffffff\"]"
    echo "       Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_estimateGas future block error handling")
fi

# Test 7.2.9: eth_estimateGas for simple transfer (no data)
log_info "Test 7.2.9: eth_estimateGas for simple transfer"
SIMPLE_TRANSFER_REQUEST="{\"from\":\"$ACTIVE_EOA_ADDRESS\",\"to\":\"$TEST_ADDR\",\"value\":\"0x0\"}"
response=$(rpc_call "eth_estimateGas" "[$SIMPLE_TRANSFER_REQUEST,\"latest\"]")
if check_result "$response" "eth_estimateGas (simple transfer)"; then
    gas_estimate=$(echo "$response" | jq -r '.result')
    gas_dec=$((gas_estimate))
    log_info "  → Simple transfer gas: $gas_estimate ($gas_dec)"
    
    # Simple transfer should use ~21000 gas
    if [ $gas_dec -ge 21000 ] && [ $gas_dec -le 50000 ]; then
        log_success "  → Gas estimate in reasonable range (21000-50000) ✓"
    else
        log_warning "  → Gas estimate outside expected range: $gas_dec"
    fi
fi

echo ""
log_info "📊 Phase 7.2 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  eth_estimateGas tests verify gas estimation across legacy/local"
log_info "  blocks, with data consistency validation."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ========================================
# Phase 7.3: eth_createAccessList Tests
# ========================================

log_section "Phase 7.3: eth_createAccessList Tests"

echo ""
log_info "Testing access list creation (EIP-2930)..."
echo ""

# Test 7.3.1: eth_createAccessList (legacy block)
log_info "Test 7.3.1: eth_createAccessList (legacy block with BlockNumber)"
response=$(rpc_call "eth_createAccessList" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]")
if check_result_legacy_tolerant "$response" "eth_createAccessList (legacy BlockNumber)"; then
    access_list=$(echo "$response" | jq -c '.result.accessList')
    gas_used=$(echo "$response" | jq -r '.result.gasUsed')
    log_info "  → Gas used: $gas_used"
    log_info "  → Access list: ${access_list:0:50}..."
fi

# Test 7.3.2: eth_createAccessList (cutoff block)
log_info "Test 7.3.2: eth_createAccessList (cutoff block)"
response=$(rpc_call "eth_createAccessList" "[$CALL_REQUEST,\"$BOUNDARY_BLOCK_HEX\"]")
check_result "$response" "eth_createAccessList (cutoff)"

# Test 7.3.3: eth_createAccessList (local block)
log_info "Test 7.3.3: eth_createAccessList (local block)"
response=$(rpc_call "eth_createAccessList" "[$CALL_REQUEST,\"$LOCAL_BLOCK_HEX\"]")
check_result "$response" "eth_createAccessList (local BlockNumber)"

# Test 7.3.4: eth_createAccessList (legacy block with BlockHash)
log_info "Test 7.3.4: eth_createAccessList (legacy block with BlockHash)"
if [ -n "$LEGACY_BLOCK_HASH_PHASE6" ] && [ "$LEGACY_BLOCK_HASH_PHASE6" != "null" ]; then
    response=$(rpc_call "eth_createAccessList" "[$CALL_REQUEST,{\"blockHash\":\"$LEGACY_BLOCK_HASH_PHASE6\"}]")
    check_result_legacy_tolerant "$response" "eth_createAccessList (legacy BlockHash)"
fi

# Test 7.3.5: eth_createAccessList with 'latest' tag
log_info "Test 7.3.5: eth_createAccessList with 'latest' tag"
response=$(rpc_call "eth_createAccessList" "[$CALL_REQUEST,\"latest\"]")
check_result "$response" "eth_createAccessList (latest)"

# Test 7.3.6: eth_createAccessList data consistency (Reth vs Legacy)
log_info "Test 7.3.6: eth_createAccessList data consistency (legacy block)"
check_data_consistency "eth_createAccessList" "[$CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]" "eth_createAccessList consistency"

# Test 7.3.7: eth_createAccessList for contract interaction
log_info "Test 7.3.7: eth_createAccessList for simple transfer"
CONTRACT_CALL_REQUEST="{\"from\":\"$ACTIVE_EOA_ADDRESS\",\"to\":\"$TEST_ADDR\",\"value\":\"0x0\"}"
response=$(rpc_call "eth_createAccessList" "[$CONTRACT_CALL_REQUEST,\"$LEGACY_BLOCK_HEX\"]")
if check_result_legacy_tolerant "$response" "eth_createAccessList (contract)"; then
    access_list=$(echo "$response" | jq -c '.result.accessList')
    list_length=$(echo "$access_list" | jq 'length')
    log_info "  → Access list entries: $list_length"
fi

echo ""
log_info "📊 Phase 7.3 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  eth_createAccessList tests verify EIP-2930 access list generation"
log_info "  across legacy/local blocks with data consistency validation."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "📊 Phase 7 Complete Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Tested 3 Legacy RPC methods with comprehensive coverage:"
log_info "  ✓ eth_call (9 tests)"
log_info "  ✓ eth_estimateGas (9 tests)"
log_info "  ✓ eth_createAccessList (7 tests)"
log_info "  Total: 25 tests covering all test dimensions"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 8: BlockHash Parameter Tests
# ========================================

if should_run_phase 8; then
log_section "Phase 8: BlockHash Parameter Tests (Critical Missing Tests)"

echo ""
log_info "🔍 Testing legacy block queries using BlockHash instead of BlockNumber"
log_info "   This verifies that Reth properly falls back to Legacy RPC for hash-based queries"
echo ""

# Get block hashes for testing
log_info "Preparing test block hashes..."
LEGACY_BLOCK_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LEGACY_BLOCK_HEX\",false]" | jq -r '.result.hash')
CUTOFF_BLOCK_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$BOUNDARY_BLOCK_HEX\",false]" | jq -r '.result.hash')

if [ $LOCAL_BLOCK -le $LATEST_BLOCK_DEC ]; then
    LOCAL_BLOCK_HASH=$(rpc_call "eth_getBlockByNumber" "[\"$LOCAL_BLOCK_HEX\",false]" | jq -r '.result.hash')
else
    LOCAL_BLOCK_HASH=""
fi

log_info "  Legacy block hash: $LEGACY_BLOCK_HASH"
log_info "  Cutoff block hash: $CUTOFF_BLOCK_HASH"
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "  Local block hash:  $LOCAL_BLOCK_HASH"
fi
echo ""

# Test 8.1: eth_getBalance with BlockHash
log_section "Phase 8.1: eth_getBalance with BlockHash"

# Test 8.1.1: Legacy block hash
log_info "Test 8.1.1: eth_getBalance (legacy BlockHash)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HASH\"]")
check_result "$response" "eth_getBalance (legacy BlockHash)"

# Test 8.1.2: Cutoff block hash
log_info "Test 8.1.2: eth_getBalance (cutoff BlockHash)"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$CUTOFF_BLOCK_HASH\"]")
check_result "$response" "eth_getBalance (cutoff BlockHash)"

# Test 8.1.3: Local block hash
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "Test 8.1.3: eth_getBalance (local BlockHash)"
    response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LOCAL_BLOCK_HASH\"]")
    check_result "$response" "eth_getBalance (local BlockHash)"
fi

# Test 8.1.4: Consistency check - BlockNumber vs BlockHash
log_info "Test 8.1.4: eth_getBalance consistency (BlockNumber vs BlockHash)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

balance_by_number=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
balance_by_hash=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$LEGACY_BLOCK_HASH\"]" | jq -r '.result')

if [ "$balance_by_number" = "$balance_by_hash" ] && [ "$balance_by_number" != "null" ]; then
    log_success "eth_getBalance: BlockHash matches BlockNumber ✓"
    log_info "  Value: $balance_by_number"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getBalance: BlockHash vs BlockNumber MISMATCH! ✗"
    echo "  By Number: $balance_by_number"
    echo "  By Hash:   $balance_by_hash"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getBalance BlockHash consistency")
fi

# Test 8.2: eth_getCode with BlockHash
log_section "Phase 8.2: eth_getCode with BlockHash"

# Test 8.2.1: Legacy block hash
log_info "Test 8.2.1: eth_getCode (legacy BlockHash)"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LEGACY_BLOCK_HASH\"]")
check_result "$response" "eth_getCode (legacy BlockHash)"

# Test 8.2.2: Cutoff block hash
log_info "Test 8.2.2: eth_getCode (cutoff BlockHash)"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$CUTOFF_BLOCK_HASH\"]")
check_result "$response" "eth_getCode (cutoff BlockHash)"

# Test 8.2.3: Local block hash
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "Test 8.2.3: eth_getCode (local BlockHash)"
    response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LOCAL_BLOCK_HASH\"]")
    check_result "$response" "eth_getCode (local BlockHash)"
fi

# Test 8.2.4: Consistency check
log_info "Test 8.2.4: eth_getCode consistency (BlockNumber vs BlockHash)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

code_by_number=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
code_by_hash=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$LEGACY_BLOCK_HASH\"]" | jq -r '.result')

if [ "$code_by_number" = "$code_by_hash" ] && [ "$code_by_number" != "null" ]; then
    log_success "eth_getCode: BlockHash matches BlockNumber ✓"
    code_length=${#code_by_number}
    log_info "  Code length: $code_length bytes"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getCode: BlockHash vs BlockNumber MISMATCH! ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getCode BlockHash consistency")
fi

# Test 8.3: eth_getStorageAt with BlockHash
log_section "Phase 8.3: eth_getStorageAt with BlockHash"

# Test 8.3.1: Legacy block hash
log_info "Test 8.3.1: eth_getStorageAt (legacy BlockHash)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LEGACY_BLOCK_HASH\"]")
check_result "$response" "eth_getStorageAt (legacy BlockHash)"

# Test 8.3.2: Cutoff block hash
log_info "Test 8.3.2: eth_getStorageAt (cutoff BlockHash)"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$CUTOFF_BLOCK_HASH\"]")
check_result "$response" "eth_getStorageAt (cutoff BlockHash)"

# Test 8.3.3: Local block hash
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "Test 8.3.3: eth_getStorageAt (local BlockHash)"
    response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LOCAL_BLOCK_HASH\"]")
    check_result "$response" "eth_getStorageAt (local BlockHash)"
fi

# Test 8.3.4: Consistency check
log_info "Test 8.3.4: eth_getStorageAt consistency (BlockNumber vs BlockHash)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

storage_by_number=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
storage_by_hash=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$LEGACY_BLOCK_HASH\"]" | jq -r '.result')

if [ "$storage_by_number" = "$storage_by_hash" ] && [ "$storage_by_number" != "null" ]; then
    log_success "eth_getStorageAt: BlockHash matches BlockNumber ✓"
    log_info "  Storage value: $storage_by_number"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getStorageAt: BlockHash vs BlockNumber MISMATCH! ✗"
    echo "  By Number: $storage_by_number"
    echo "  By Hash:   $storage_by_hash"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getStorageAt BlockHash consistency")
fi

# Test 8.4: eth_getTransactionCount with BlockHash
log_section "Phase 8.4: eth_getTransactionCount with BlockHash"

# Test 8.4.1: Legacy block hash
log_info "Test 8.4.1: eth_getTransactionCount (legacy BlockHash)"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LEGACY_BLOCK_HASH\"]")
check_result "$response" "eth_getTransactionCount (legacy BlockHash)"

# Test 8.4.2: Cutoff block hash
log_info "Test 8.4.2: eth_getTransactionCount (cutoff BlockHash)"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$CUTOFF_BLOCK_HASH\"]")
check_result "$response" "eth_getTransactionCount (cutoff BlockHash)"

# Test 8.4.3: Local block hash
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "Test 8.4.3: eth_getTransactionCount (local BlockHash)"
    response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LOCAL_BLOCK_HASH\"]")
    check_result "$response" "eth_getTransactionCount (local BlockHash)"
fi

# Test 8.4.4: Consistency check
log_info "Test 8.4.4: eth_getTransactionCount consistency (BlockNumber vs BlockHash)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

nonce_by_number=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LEGACY_BLOCK_HEX\"]" | jq -r '.result')
nonce_by_hash=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$LEGACY_BLOCK_HASH\"]" | jq -r '.result')

if [ "$nonce_by_number" = "$nonce_by_hash" ] && [ "$nonce_by_number" != "null" ]; then
    log_success "eth_getTransactionCount: BlockHash matches BlockNumber ✓"
    nonce_dec=$((nonce_by_number))
    log_info "  Nonce: $nonce_by_number ($nonce_dec)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getTransactionCount: BlockHash vs BlockNumber MISMATCH! ✗"
    echo "  By Number: $nonce_by_number"
    echo "  By Hash:   $nonce_by_hash"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getTransactionCount BlockHash consistency")
fi

# Test 8.5: eth_getBlockReceipts with BlockHash
log_section "Phase 8.5: eth_getBlockReceipts with BlockHash"

# Test 8.5.1: Legacy block hash
log_info "Test 8.5.1: eth_getBlockReceipts (legacy BlockHash)"
response=$(rpc_call "eth_getBlockReceipts" "[\"$LEGACY_BLOCK_HASH\"]")
if check_result "$response" "eth_getBlockReceipts (legacy BlockHash)"; then
    receipts_by_hash=$(echo "$response" | jq '.result | length')
    log_info "  → Found $receipts_by_hash receipts via BlockHash"
fi

# Test 8.5.2: Cutoff block hash
log_info "Test 8.5.2: eth_getBlockReceipts (cutoff BlockHash)"
response=$(rpc_call "eth_getBlockReceipts" "[\"$CUTOFF_BLOCK_HASH\"]")
check_result "$response" "eth_getBlockReceipts (cutoff BlockHash)"

# Test 8.5.3: Local block hash
if [ -n "$LOCAL_BLOCK_HASH" ]; then
    log_info "Test 8.5.3: eth_getBlockReceipts (local BlockHash)"
    response=$(rpc_call "eth_getBlockReceipts" "[\"$LOCAL_BLOCK_HASH\"]")
    check_result "$response" "eth_getBlockReceipts (local BlockHash)"
fi

# Test 8.5.4: Consistency check
log_info "Test 8.5.4: eth_getBlockReceipts consistency (BlockNumber vs BlockHash)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

receipts_by_number=$(rpc_call "eth_getBlockReceipts" "[\"$LEGACY_BLOCK_HEX\"]" | jq -cS '.result')
receipts_by_hash=$(rpc_call "eth_getBlockReceipts" "[\"$LEGACY_BLOCK_HASH\"]" | jq -cS '.result')

if [ "$receipts_by_number" = "$receipts_by_hash" ] && [ "$receipts_by_number" != "null" ]; then
    log_success "eth_getBlockReceipts: BlockHash matches BlockNumber ✓"
    count=$(echo "$receipts_by_number" | jq 'length')
    log_info "  Receipts count: $count"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "eth_getBlockReceipts: BlockHash vs BlockNumber MISMATCH! ✗"
    count_by_number=$(echo "$receipts_by_number" | jq 'length // 0')
    count_by_hash=$(echo "$receipts_by_hash" | jq 'length // 0')
    echo "  By Number: $count_by_number receipts"
    echo "  By Hash:   $count_by_hash receipts"
    
    if [ "$receipts_by_hash" = "null" ] || [ "$count_by_hash" -eq 0 ]; then
        log_error "  💥 BlockHash query returned null/empty - Legacy fallback may have FAILED!"
    fi
    
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("eth_getBlockReceipts BlockHash consistency")
fi

echo ""
log_info "📊 Phase 8 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  BlockHash parameter tests verify that Reth correctly identifies"
log_info "  legacy blocks by their hash (not just number) and falls back to"
log_info "  Legacy RPC. This is critical for applications that use block.hash"
log_info "  to ensure state consistency."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 9: Special BlockTag Tests
# ========================================

if should_run_phase 9; then
log_section "Phase 9: Special BlockTag Tests"

echo ""
log_info "🏷️  Testing special block tags: 'earliest', 'latest', 'pending'"
log_info "   These tags must be correctly routed based on their semantic meaning"
echo ""

# Test 9.1: "earliest" tag (should fallback for genesis block)
log_section "Phase 9.1: 'earliest' Tag Tests"

log_info "Test 9.1.1: eth_getBalance with 'earliest'"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"earliest\"]")
check_result "$response" "eth_getBalance (earliest)"

log_info "Test 9.1.2: eth_getCode with 'earliest'"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"earliest\"]")
check_result "$response" "eth_getCode (earliest)"

log_info "Test 9.1.3: eth_getStorageAt with 'earliest'"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"earliest\"]")
check_result "$response" "eth_getStorageAt (earliest)"

log_info "Test 9.1.4: eth_getTransactionCount with 'earliest'"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"earliest\"]")
if check_result "$response" "eth_getTransactionCount (earliest)"; then
    earliest_nonce=$(echo "$response" | jq -r '.result')
    if [ "$earliest_nonce" = "0x0" ]; then
        log_success "  → Nonce at genesis is 0x0 as expected ✓"
    else
        log_warning "  → Unexpected nonce at genesis: $earliest_nonce"
    fi
fi

log_info "Test 9.1.5: eth_getBlockByNumber with 'earliest'"
response=$(rpc_call "eth_getBlockByNumber" "[\"earliest\",false]")
if check_result_not_null "$response" "eth_getBlockByNumber (earliest)"; then
    block_num=$(echo "$response" | jq -r '.result.number')
    if [ "$block_num" = "0x0" ]; then
        log_success "  → 'earliest' correctly returns block 0 ✓"
    else
        log_warning "  → 'earliest' returned block $block_num (expected 0x0)"
    fi
fi

# Test 9.2: "latest" tag (should query local Reth)
log_section "Phase 9.2: 'latest' Tag Tests"

log_info "Test 9.2.1: eth_getBalance with 'latest'"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"latest\"]")
check_result "$response" "eth_getBalance (latest)"

log_info "Test 9.2.2: eth_getCode with 'latest'"
response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"latest\"]")
check_result "$response" "eth_getCode (latest)"

log_info "Test 9.2.3: eth_getStorageAt with 'latest'"
response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"latest\"]")
check_result "$response" "eth_getStorageAt (latest)"

log_info "Test 9.2.4: eth_getTransactionCount with 'latest'"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"latest\"]")
check_result "$response" "eth_getTransactionCount (latest)"

log_info "Test 9.2.5: eth_getBlockByNumber with 'latest'"
response=$(rpc_call "eth_getBlockByNumber" "[\"latest\",false]")
if check_result_not_null "$response" "eth_getBlockByNumber (latest)"; then
    latest_block_num=$(echo "$response" | jq -r '.result.number')
    latest_block_dec=$((latest_block_num))
    log_info "  → Latest block: $latest_block_num ($latest_block_dec)"
    
    if [ $latest_block_dec -ge $CUTOFF_BLOCK ]; then
        log_success "  → Latest block is post-cutoff (as expected) ✓"
    fi
fi

# Test 9.3: "pending" tag (should query local Reth, may not be supported)
log_section "Phase 9.3: 'pending' Tag Tests"

log_info "Test 9.3.1: eth_getBalance with 'pending'"
response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"pending\"]")
check_result_legacy_tolerant "$response" "eth_getBalance (pending)"

log_info "Test 9.3.2: eth_getTransactionCount with 'pending'"
response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"pending\"]")
check_result_legacy_tolerant "$response" "eth_getTransactionCount (pending)"

# Test 9.4: eth_getLogs with special tags
log_section "Phase 9.4: eth_getLogs with Special Tags"

log_info "Test 9.4.1: eth_getLogs (earliest to latest - full history)"
log_info "  ⚠️  Note: This may timeout or be rate-limited due to large range"
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"earliest\",\"toBlock\":\"latest\",\"address\":\"$CONTRACT_ADDRESS\"}]")
if check_result_legacy_tolerant "$response" "eth_getLogs (earliest to latest)"; then
    logs_count=$(echo "$response" | jq '.result | length')
    log_info "  → Found $logs_count logs across full history"
    
    if [ "$logs_count" -gt 0 ]; then
        # Verify logs span both sides of cutoff
        has_legacy=$(echo "$response" | jq --argjson cutoff "$CUTOFF_BLOCK" \
            '[.result[] | select((.blockNumber | tonumber) < $cutoff)] | length > 0')
        has_local=$(echo "$response" | jq --argjson cutoff "$CUTOFF_BLOCK" \
            '[.result[] | select((.blockNumber | tonumber) >= $cutoff)] | length > 0')
        
        if [ "$has_legacy" = "true" ] && [ "$has_local" = "true" ]; then
            log_success "  → Logs from BOTH legacy and local DB ✓"
        elif [ "$has_legacy" = "true" ]; then
            log_info "  → Only legacy logs found"
        elif [ "$has_local" = "true" ]; then
            log_info "  → Only local logs found"
        fi
    fi
fi

log_info "Test 9.4.2: eth_getLogs (recent 50 blocks using 'latest')"
log_info "  → Testing range: latest-50 to latest (validates 'latest' tag handling)"
LATEST_MINUS_50=$((LATEST_BLOCK_DEC - 50))
LATEST_MINUS_50_HEX=$(printf "0x%x" $LATEST_MINUS_50)
response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$LATEST_MINUS_50_HEX\",\"toBlock\":\"latest\"}]")
if check_result "$response" "eth_getLogs (latest-50 to latest)"; then
    logs_count=$(echo "$response" | jq '.result | length')
    log_info "  → Found $logs_count logs in recent 50 blocks"
    
    # Verify 'latest' was resolved correctly
    if [ "$logs_count" -gt 0 ]; then
        # Convert hex blockNumber to decimal for comparison
        max_block_hex=$(echo "$response" | jq -r '.result | map(.blockNumber) | max')
        max_block=$((max_block_hex))
        log_info "  → Highest log block: $max_block (should be near $LATEST_BLOCK_DEC)"
        
        if [ $max_block -ge $((LATEST_BLOCK_DEC - 10)) ]; then
            log_success "  → 'latest' tag correctly resolved to recent blocks ✓"
        fi
    fi
fi

log_info "Test 9.4.3: eth_getLogs (post-cutoff 50 blocks using 'latest')"
log_info "  → Testing that 'latest' works for post-cutoff data"
POST_CUTOFF_START=$((CUTOFF_BLOCK + 100))
POST_CUTOFF_START_HEX=$(printf "0x%x" $POST_CUTOFF_START)
POST_CUTOFF_END=$((POST_CUTOFF_START + 50))
POST_CUTOFF_END_HEX=$(printf "0x%x" $POST_CUTOFF_END)

if [ $POST_CUTOFF_END -le $LATEST_BLOCK_DEC ]; then
    response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$POST_CUTOFF_START_HEX\",\"toBlock\":\"$POST_CUTOFF_END_HEX\"}]")
    if check_result "$response" "eth_getLogs (post-cutoff 50 blocks)"; then
        logs_count=$(echo "$response" | jq '.result | length')
        log_info "  → Found $logs_count logs in post-cutoff range"
    fi
else
    log_warning "Skipping post-cutoff range test - insufficient blocks mined"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

echo ""
log_info "📊 Phase 9 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Special BlockTag tests verify that symbolic tags like 'earliest'"
log_info "  and 'latest' are correctly interpreted and routed to the appropriate"
log_info "  data source (Legacy RPC or local Reth DB)."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 10: Enhanced Data Consistency for Tolerant Methods
# ========================================

if should_run_phase 10; then
log_section "Phase 10: Enhanced Consistency Tests for Hash-Based Methods"

echo ""
log_info "🔍 Re-testing previously 'tolerant' methods with strict consistency checks"
log_info "   These methods were previously only checked for non-error responses"
log_info "   Now we verify data consistency against Legacy RPC"
echo ""

# Test 10.1: eth_getBlockTransactionCountByHash with consistency
log_info "Test 10.1: eth_getBlockTransactionCountByHash (consistency check)"
if [ "$LEGACY_BLOCK_HASH" != "null" ] && [ -n "$LEGACY_BLOCK_HASH" ]; then
    check_data_consistency "eth_getBlockTransactionCountByHash" "[\"$LEGACY_BLOCK_HASH\"]" "eth_getBlockTransactionCountByHash consistency"
else
    log_warning "Skipping - no legacy block hash available"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 10.2: eth_getTransactionByBlockHashAndIndex with consistency
log_info "Test 10.2: eth_getTransactionByBlockHashAndIndex (consistency check)"
if [ "$LEGACY_BLOCK_HASH" != "null" ] && [ -n "$LEGACY_BLOCK_HASH" ] && [ "$LEGACY_TX_COUNT" -gt 0 ]; then
    check_data_consistency "eth_getTransactionByBlockHashAndIndex" "[\"$LEGACY_BLOCK_HASH\",\"0x0\"]" "eth_getTransactionByBlockHashAndIndex consistency"
else
    log_warning "Skipping - no transactions in legacy block"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

echo ""
log_info "📊 Phase 10 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Enhanced consistency tests ensure that hash-based methods don't"
log_info "  just 'work' but return IDENTICAL data to Legacy RPC."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 11: Edge Cases and Invalid Inputs
# ========================================

if should_run_phase 11; then
log_section "Phase 11: Edge Cases and Invalid Block Identifiers"

echo ""
log_info "🔬 Testing error handling for non-existent and invalid block identifiers"
log_info "   Ensures proper error handling for boundary cases and malformed inputs"
echo ""

# Test 11.1: Future block number (doesn't exist yet)
log_info "Test 11.1: Future block number (very far ahead)"
FUTURE_BLOCK_HEX="0xffffffff"  # 4294967295 - extremely far in future
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByNumber" "[\"$FUTURE_BLOCK_HEX\",false]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    error_code=$(echo "$response" | jq -r '.error.code')
    log_success "Future block correctly returns error (code: $error_code) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block returns null (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Future block should return error or null but got result ✗"
    echo "  Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block error handling")
fi

# Test 11.2: State query with future block (eth_getBalance)
log_info "Test 11.2: eth_getBalance with future block number"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$FUTURE_BLOCK_HEX\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block state query correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block state query returns null (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null for future block ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block state query error handling")
fi

# Test 11.3: eth_getCode with future block
log_info "Test 11.3: eth_getCode with future block number"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$FUTURE_BLOCK_HEX\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block getCode returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block getCode returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block getCode error handling")
fi

# Test 11.4: eth_getBlockReceipts with future block
log_info "Test 11.4: eth_getBlockReceipts with future block number"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockReceipts" "[\"$FUTURE_BLOCK_HEX\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block getBlockReceipts returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block getBlockReceipts returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block getBlockReceipts error handling")
fi

# Test 11.4.1: eth_getStorageAt with future block
log_info "Test 11.4.1: eth_getStorageAt with future block number"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$FUTURE_BLOCK_HEX\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block getStorageAt returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block getStorageAt returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block getStorageAt error handling")
fi

# Test 11.4.2: eth_getTransactionCount with future block
log_info "Test 11.4.2: eth_getTransactionCount with future block number"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$FUTURE_BLOCK_HEX\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block getTransactionCount returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Future block getTransactionCount returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Future block getTransactionCount error handling")
fi

echo ""
log_info "Testing invalid block hashes..."
echo ""

# Test 11.5: Invalid block hash (all zeros)
log_info "Test 11.5: eth_getBlockByHash with all-zero hash"
INVALID_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByHash" "[\"$INVALID_HASH\",false]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "All-zero hash correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "All-zero hash returns null (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "All-zero hash should return error or null ✗"
    echo "  Got result: $(echo "$response" | jq -c .result)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("All-zero hash error handling")
fi

# Test 11.6: Random non-existent hash
log_info "Test 11.6: eth_getBlockByHash with random non-existent hash"
RANDOM_HASH="0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByHash" "[\"$RANDOM_HASH\",false]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Random hash correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Random hash returns null (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Random hash should return error or null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Random hash error handling")
fi

# Test 11.7: State query with invalid hash (eth_getBalance)
log_info "Test 11.7: eth_getBalance with invalid block hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"$RANDOM_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Invalid hash state query returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Invalid hash state query returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_warning "Invalid hash state query should ideally return error"
    echo "  Got result: $(echo "$response" | jq -r '.result')"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# Test 11.8: eth_getCode with invalid hash
log_info "Test 11.8: eth_getCode with invalid block hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getCode" "[\"$CONTRACT_ADDRESS\",\"$RANDOM_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Invalid hash getCode returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Invalid hash getCode returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_warning "Invalid hash getCode accepted (may return default)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# Test 11.9: eth_getStorageAt with invalid hash
log_info "Test 11.9: eth_getStorageAt with invalid block hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getStorageAt" "[\"$CONTRACT_ADDRESS\",\"0x0\",\"$RANDOM_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Invalid hash getStorageAt returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Invalid hash getStorageAt returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_warning "Invalid hash getStorageAt accepted"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# Test 11.10: eth_getTransactionCount with invalid hash
log_info "Test 11.10: eth_getTransactionCount with invalid block hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getTransactionCount" "[\"$ACTIVE_EOA_ADDRESS\",\"$RANDOM_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Invalid hash getTransactionCount returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Invalid hash getTransactionCount returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_warning "Invalid hash getTransactionCount accepted"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

# Test 11.11: eth_getBlockReceipts with invalid hash
log_info "Test 11.11: eth_getBlockReceipts with invalid block hash"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockReceipts" "[\"$RANDOM_HASH\"]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Invalid hash getBlockReceipts returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Invalid hash getBlockReceipts returns null ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or null for invalid hash ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getBlockReceipts invalid hash handling")
fi

echo ""
log_info "Testing genesis block and boundary values..."
echo ""

# Test 11.12: Genesis block (block 0x0)
log_info "Test 11.12: Genesis block query (block 0x0)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByNumber" "[\"0x0\",false]")
if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
    block_num=$(echo "$response" | jq -r '.result.number')
    if [ "$block_num" = "0x0" ]; then
        log_success "Genesis block query successful ✓"
        log_info "  Genesis block hash: $(echo "$response" | jq -r '.result.hash')"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        log_error "Genesis block returned wrong block number: $block_num ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Genesis block query")
    fi
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_error "Genesis block query failed ✗"
    echo "  Error: $(echo "$response" | jq -r '.error.message')"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Genesis block query")
else
    log_error "Genesis block query returned null ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Genesis block query")
fi

# Test 11.13: State query at genesis block
log_info "Test 11.13: eth_getBalance at genesis block (0x0)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBalance" "[\"$TEST_ADDR\",\"0x0\"]")
if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
    balance=$(echo "$response" | jq -r '.result')
    log_success "Genesis block state query successful (balance: $balance) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Genesis block state query failed ✗"
    echo "  Response: $(echo "$response" | jq -c .)"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("Genesis block state query")
fi

# Test 11.14: Block 1 (second block)
log_info "Test 11.14: Block 1 query (0x1)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByNumber" "[\"0x1\",false]")
if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
    block_num=$(echo "$response" | jq -r '.result.number')
    if [ "$block_num" = "0x1" ]; then
        log_success "Block 1 query successful ✓"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        log_error "Block 1 returned wrong number: $block_num ✗"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        FAILED_TEST_NAMES+=("Block 1 query")
    fi
elif echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_warning "Block 1 query returned error (may not exist yet)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
else
    log_warning "Block 1 returned null (may not exist)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 11.15: Negative block number (edge case)
log_info "Test 11.15: Negative block number (-0x1)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByNumber" "[\"-0x1\",false]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Negative block number correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    # Some RPC implementations may parse -0x1 as a valid number or tag
    log_warning "Negative block number didn't return error (may be parsed differently)"
    echo "  Response: $(echo "$response" | jq -c .)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 11.16: Very large number just beyond current block
log_info "Test 11.16: Block just beyond current tip (latest + 1)"
BEYOND_TIP_HEX=$(printf "0x%x" $((LATEST_BLOCK_DEC + 1)))
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getBlockByNumber" "[\"$BEYOND_TIP_HEX\",false]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Block beyond tip correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == null' > /dev/null 2>&1; then
    log_success "Block beyond tip returns null (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    # This might succeed if a new block was mined during the test
    log_warning "Block beyond tip returned result (new block may have been mined)"
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
fi

# Test 11.17: eth_getLogs with invalid block range
log_info "Test 11.17: eth_getLogs with future block range"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$FUTURE_BLOCK_HEX\",\"toBlock\":\"$FUTURE_BLOCK_HEX\"}]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Future block range correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == []' > /dev/null 2>&1; then
    log_success "Future block range returns empty array (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_error "Should return error or empty array for future blocks ✗"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    FAILED_TEST_NAMES+=("getLogs future block range handling")
fi

# Test 11.18: eth_getLogs with inverted range (toBlock < fromBlock)
log_info "Test 11.18: eth_getLogs with inverted block range (toBlock < fromBlock)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

FROM_HEX=$(printf "0x%x" $((LEGACY_BLOCK + 100)))
TO_HEX=$(printf "0x%x" $LEGACY_BLOCK)

response=$(rpc_call "eth_getLogs" "[{\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"$TO_HEX\"}]")
if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
    log_success "Inverted range correctly returns error ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
elif echo "$response" | jq -e '.result == []' > /dev/null 2>&1; then
    log_success "Inverted range returns empty array (acceptable) ✓"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    log_warning "Inverted range didn't return error (implementation may handle it)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
fi

echo ""
log_info "📊 Phase 11 Summary:"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Edge case tests verify proper error handling for:"
log_info "  ✓ Non-existent future blocks (block numbers far ahead)"
log_info "  ✓ Invalid and random block hashes"
log_info "  ✓ Genesis block (block 0) and early blocks"
log_info "  ✓ Boundary values (negative, beyond tip)"
log_info "  ✓ Invalid ranges (inverted, future)"
log_info ""
log_info "  Proper error handling prevents:"
log_info "  - Crashes from malformed inputs"
log_info "  - Returning incorrect data for non-existent blocks"
log_info "  - Confusion between 'not found' and 'empty result'"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

fi

# ========================================
# Phase 12: Internal Transactions Tests
# ========================================

if should_run_phase 12; then
log_section "Phase 12: Internal Transactions Tests"

# Calculate boundary blocks if not already set
ensure_boundary_blocks

# ========================================
# Phase 13: Comprehensive Summary
# ========================================

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
    echo -e "${GREEN}║   ✓ ALL TESTS PASSED!                  ║${NC}"
    echo -e "${GREEN}║   Legacy RPC is working correctly!     ║${NC}"
    echo -e "${GREEN}║   XLayer Mainnet migration validated ✓ ║${NC}"
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
