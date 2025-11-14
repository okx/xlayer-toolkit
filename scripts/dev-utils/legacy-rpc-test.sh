#!/bin/bash

# Comprehensive RPC forwarding test
# Usage: ./legacy-rpc-test.sh [migration_block]

#RPC_URL="https://xlayerrpc.okx.com"
RPC_URL="http://localhost:8545"
MIGRATION_BLOCK=${1:-42810021}

FOR_ERIGON_BLOCK_HASH="0xd94e93be380f6034712e466dca99849a3231b34aff5a662bbb6a5995c35f3cab" # block 42800000
FOR_OP_BLOCK_HASH="0xdc33d8c0ec9de14fc2c21bd6077309a0a856df22821bd092a2513426e096a789"

FOR_ERIGON_TRANSACTION_HASH="0x8d7c7927a74c0245f06b1da06bfaa727396c2bd47349de6f7fc579febce30fae" # transaction in block 42800000
FOR_OP_TRANSACTION_HASH="0x9b52d72be301ae6928830be4a1cf25749f2d230a4bee940f1b55e9311960a4f5"

# Real test parameters from production
PREEXEC_FROM="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
PREEXEC_TO="0x8ec198c4149280e4004a64531648640b862fb887"

# Real contract address
CONTRACT_ADDRESS="0x4AAaCCfe00090665Dd74C56Db013978891D142f4"

echo "Testing RPC Forwarding (Migration Block: $MIGRATION_BLOCK)"
echo "RPC URL: $RPC_URL"
echo "=================================================="

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

TEST_ADDR="0x7b33d603d20c4d442455eec964f0f2bf20fae5dd"
BELOW=$((MIGRATION_BLOCK - 10))
ABOVE=$((MIGRATION_BLOCK + 10))

call_rpc() {
    local method=$1
    local params=$2
    local desc=$3
    
    echo -e "\n${BLUE}$desc${NC}"
    echo "→ $method"
    
    response=$(curl -s -X POST $RPC_URL \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}")
    
    error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$error" ]; then
        echo -e "${YELLOW}✗ Error: $error${NC}"
        echo -e "${YELLOW}Request: {\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}${NC}"
    else
        echo -e "${GREEN}✓ Success${NC}"
    fi
}

# ============================================
# BlockChainAPI Tests
# ============================================

echo -e "\n${GREEN}=== BlockChainAPI: Block Queries ===${NC}"

call_rpc "eth_getBlockByNumber" "[\"0x$(printf '%x' $BELOW)\", false]" \
    "eth_getBlockByNumber (block $BELOW) → PROXY"

call_rpc "eth_getBlockByNumber" "[\"latest\", false]" \
    "eth_getBlockByNumber (latest) → LOCAL"

call_rpc "eth_getBlockByHash" "[\"$FOR_OP_BLOCK_HASH\", false]" \
    "eth_getBlockByHash (op-geth block) → LOCAL"

call_rpc "eth_getBlockByHash" "[\"$FOR_ERIGON_BLOCK_HASH\", false]" \
    "eth_getBlockByHash (erigon block) → fallback to PROXY"

call_rpc "eth_getHeaderByNumber" "[\"0x$(printf '%x' $BELOW)\"]" \
    "eth_getHeaderByNumber (block $BELOW) → PROXY"

call_rpc "eth_getHeaderByNumber" "[\"latest\"]" \
    "eth_getHeaderByNumber (latest) → LOCAL"

call_rpc "eth_getHeaderByHash" "[\"$FOR_OP_BLOCK_HASH\"]" \
    "eth_getHeaderByHash (op-geth block) → LOCAL"

call_rpc "eth_getHeaderByHash" "[\"$FOR_ERIGON_BLOCK_HASH\"]" \
    "eth_getHeaderByHash (erigon block) → fallback to PROXY"

echo -e "\n${GREEN}=== BlockChainAPI: State Queries ===${NC}"

call_rpc "eth_getBalance" "[\"$TEST_ADDR\", \"0x$(printf '%x' $BELOW)\"]" \
    "eth_getBalance (block $BELOW) → PROXY"

call_rpc "eth_getBalance" "[\"$TEST_ADDR\", \"latest\"]" \
    "eth_getBalance (latest) → LOCAL"

call_rpc "eth_getCode" "[\"$TEST_ADDR\", \"0x$(printf '%x' $BELOW)\"]" \
    "eth_getCode (block $BELOW) → PROXY"

call_rpc "eth_getCode" "[\"$TEST_ADDR\", \"latest\"]" \
    "eth_getCode (latest) → LOCAL"

call_rpc "eth_getStorageAt" "[\"$TEST_ADDR\", \"0x0\", \"0x$(printf '%x' $BELOW)\"]" \
    "eth_getStorageAt (block $BELOW) → PROXY"

call_rpc "eth_getStorageAt" "[\"$TEST_ADDR\", \"0x0\", \"latest\"]" \
    "eth_getStorageAt (latest) → LOCAL"

echo -e "\n${GREEN}=== BlockChainAPI: Call & Estimate ===${NC}"

# eth_call tests
call_rpc "eth_call" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"0x$(printf '%x' $BELOW)\"]" \
    "eth_call (block number $BELOW) → PROXY"

call_rpc "eth_call" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_ERIGON_BLOCK_HASH\"}]" \
    "eth_call (erigon block hash) → fallback to PROXY"

call_rpc "eth_call" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"latest\"]" \
    "eth_call (latest) → LOCAL"

call_rpc "eth_call" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_OP_BLOCK_HASH\"}]" \
    "eth_call (op-geth block hash) → LOCAL"

# eth_estimateGas tests
call_rpc "eth_estimateGas" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"0x$(printf '%x' $BELOW)\"]" \
    "eth_estimateGas (block number $BELOW) → PROXY"

call_rpc "eth_estimateGas" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_ERIGON_BLOCK_HASH\"}]" \
    "eth_estimateGas (erigon block hash) → fallback to PROXY"

call_rpc "eth_estimateGas" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"latest\"]" \
    "eth_estimateGas (latest) → LOCAL"

call_rpc "eth_estimateGas" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_OP_BLOCK_HASH\"}]" \
    "eth_estimateGas (op-geth block hash) → LOCAL"

call_rpc "eth_estimateGas" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"0x$(printf '%x' $ABOVE)\"]" \
    "eth_estimateGas (block number $ABOVE) → LOCAL"

# eth_createAccessList tests
call_rpc "eth_createAccessList" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"0x$(printf '%x' $BELOW)\"]" \
    "eth_createAccessList (block number $BELOW) → PROXY"

call_rpc "eth_createAccessList" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_ERIGON_BLOCK_HASH\"}]" \
    "eth_createAccessList (erigon block hash) → fallback to PROXY"

call_rpc "eth_createAccessList" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"latest\"]" \
    "eth_createAccessList (latest) → LOCAL"

call_rpc "eth_createAccessList" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, {\"blockHash\":\"$FOR_OP_BLOCK_HASH\"}]" \
    "eth_createAccessList (op-geth block hash) → LOCAL"

call_rpc "eth_createAccessList" "[{\"to\":\"$TEST_ADDR\",\"data\":\"0x\"}, \"0x$(printf '%x' $ABOVE)\"]" \
    "eth_createAccessList (block number $ABOVE) → LOCAL"

echo -e "\n${GREEN}=== BlockChainAPI: Receipts ===${NC}"

call_rpc "eth_getBlockReceipts" "[\"0x$(printf '%x' $BELOW)\"]" \
    "eth_getBlockReceipts (block $BELOW) → PROXY"

call_rpc "eth_getBlockReceipts" "[\"latest\"]" \
    "eth_getBlockReceipts (latest) → LOCAL"

echo -e "\n${GREEN}=== BlockChainAPI: TransactionPreExec (XLayer Specific) ===${NC}"

call_rpc "eth_transactionPreExec" \
    "[[{\"from\":\"$PREEXEC_FROM\",\"to\":\"$PREEXEC_TO\",\"gas\":\"0x30000\",\"gasPrice\":\"0x4a817c800\",\"value\":\"0x0\",\"nonce\":\"0x11\",\"data\":\"0xf18c388a\"}], {\"blockNumber\":\"0x$(printf '%x' $BELOW)\"}, {\"$PREEXEC_FROM\":{\"balance\":\"0x56bc75e2d630eb20000\"}}]" \
    "eth_transactionPreExec (block number $BELOW with state override) → PROXY"

call_rpc "eth_transactionPreExec" \
    "[[{\"from\":\"$PREEXEC_FROM\",\"to\":\"$PREEXEC_TO\",\"gas\":\"0x30000\",\"gasPrice\":\"0x4a817c800\",\"value\":\"0x0\",\"nonce\":\"0x11\",\"data\":\"0xf18c388a\"}], {\"blockHash\":\"$FOR_ERIGON_BLOCK_HASH\"}, {\"$PREEXEC_FROM\":{\"balance\":\"0x56bc75e2d630eb20000\"}}]" \
    "eth_transactionPreExec (erigon block hash with state override) → fallback to PROXY"

call_rpc "eth_transactionPreExec" \
    "[[{\"from\":\"$PREEXEC_FROM\",\"to\":\"$PREEXEC_TO\",\"gas\":\"0x30000\",\"gasPrice\":\"0x4a817c800\",\"value\":\"0x0\",\"nonce\":\"0x11\",\"data\":\"0xf18c388a\"}], \"latest\", {\"$PREEXEC_FROM\":{\"balance\":\"0x56bc75e2d630eb20000\"}}]" \
    "eth_transactionPreExec (latest with state override) → LOCAL"

call_rpc "eth_transactionPreExec" \
    "[[{\"from\":\"$PREEXEC_FROM\",\"to\":\"$PREEXEC_TO\",\"gas\":\"0x30000\",\"gasPrice\":\"0x4a817c800\",\"value\":\"0x0\",\"nonce\":\"0x11\",\"data\":\"0xf18c388a\"}], {\"blockHash\":\"$FOR_OP_BLOCK_HASH\"}, {\"$PREEXEC_FROM\":{\"balance\":\"0x56bc75e2d630eb20000\"}}]" \
    "eth_transactionPreExec (op-geth block hash with state override) → LOCAL"

# ============================================
# TransactionAPI Tests
# ============================================

echo -e "\n${GREEN}=== TransactionAPI: Transaction Queries ===${NC}"

call_rpc "eth_getTransactionByHash" "[\"$FOR_OP_TRANSACTION_HASH\"]" \
    "eth_getTransactionByHash (op-geth tx) → LOCAL"

call_rpc "eth_getTransactionByHash" "[\"$FOR_ERIGON_TRANSACTION_HASH\"]" \
    "eth_getTransactionByHash (erigon tx) → fallback to PROXY"

call_rpc "eth_getTransactionReceipt" "[\"$FOR_OP_TRANSACTION_HASH\"]" \
    "eth_getTransactionReceipt (op-geth tx) → LOCAL"

call_rpc "eth_getTransactionReceipt" "[\"$FOR_ERIGON_TRANSACTION_HASH\"]" \
    "eth_getTransactionReceipt (erigon tx) → fallback to PROXY"

call_rpc "eth_getRawTransactionByHash" "[\"$FOR_OP_TRANSACTION_HASH\"]" \
    "eth_getRawTransactionByHash (op-geth tx) → LOCAL"

call_rpc "eth_getRawTransactionByHash" "[\"$FOR_ERIGON_TRANSACTION_HASH\"]" \
    "eth_getRawTransactionByHash (erigon tx) → fallback to PROXY"

echo -e "\n${GREEN}=== TransactionAPI: Block Transaction Counts ===${NC}"

call_rpc "eth_getBlockTransactionCountByNumber" "[\"0x$(printf '%x' $BELOW)\"]" \
    "eth_getBlockTransactionCountByNumber (block $BELOW) → PROXY"

call_rpc "eth_getBlockTransactionCountByNumber" "[\"latest\"]" \
    "eth_getBlockTransactionCountByNumber (latest) → LOCAL"

call_rpc "eth_getBlockTransactionCountByHash" "[\"$FOR_OP_BLOCK_HASH\"]" \
    "eth_getBlockTransactionCountByHash (op-geth block) → LOCAL"

call_rpc "eth_getBlockTransactionCountByHash" "[\"$FOR_ERIGON_BLOCK_HASH\"]" \
    "eth_getBlockTransactionCountByHash (erigon block) → fallback to PROXY"

echo -e "\n${GREEN}=== TransactionAPI: Transaction by Index ===${NC}"

call_rpc "eth_getTransactionByBlockNumberAndIndex" "[\"0x$(printf '%x' $BELOW)\", \"0x0\"]" \
    "eth_getTransactionByBlockNumberAndIndex (block $BELOW) → PROXY"

call_rpc "eth_getTransactionByBlockNumberAndIndex" "[\"latest\", \"0x0\"]" \
    "eth_getTransactionByBlockNumberAndIndex (latest) → LOCAL"

call_rpc "eth_getTransactionByBlockHashAndIndex" "[\"$FOR_OP_BLOCK_HASH\", \"0x0\"]" \
    "eth_getTransactionByBlockHashAndIndex (op-geth block) → LOCAL"

call_rpc "eth_getTransactionByBlockHashAndIndex" "[\"$FOR_ERIGON_BLOCK_HASH\", \"0x0\"]" \
    "eth_getTransactionByBlockHashAndIndex (erigon block) → fallback to PROXY"

call_rpc "eth_getRawTransactionByBlockNumberAndIndex" "[\"0x$(printf '%x' $BELOW)\", \"0x0\"]" \
    "eth_getRawTransactionByBlockNumberAndIndex (block $BELOW) → PROXY"

call_rpc "eth_getRawTransactionByBlockNumberAndIndex" "[\"latest\", \"0x0\"]" \
    "eth_getRawTransactionByBlockNumberAndIndex (latest) → LOCAL"

call_rpc "eth_getRawTransactionByBlockHashAndIndex" "[\"$FOR_OP_BLOCK_HASH\", \"0x0\"]" \
    "eth_getRawTransactionByBlockHashAndIndex (op-geth block) → LOCAL"

call_rpc "eth_getRawTransactionByBlockHashAndIndex" "[\"$FOR_ERIGON_BLOCK_HASH\", \"0x0\"]" \
    "eth_getRawTransactionByBlockHashAndIndex (erigon block) → fallback to PROXY"

echo -e "\n${GREEN}=== TransactionAPI: Transaction Count ===${NC}"

call_rpc "eth_getTransactionCount" "[\"$TEST_ADDR\", \"0x$(printf '%x' $BELOW)\"]" \
    "eth_getTransactionCount (block $BELOW) → PROXY"

call_rpc "eth_getTransactionCount" "[\"$TEST_ADDR\", \"latest\"]" \
    "eth_getTransactionCount (latest) → LOCAL"

echo -e "\n${GREEN}=== TransactionAPI: Internal Transactions (XLayer Specific) ===${NC}"

call_rpc "eth_getBlockInternalTransactions" "[\"0x$(printf '%x' $BELOW)\"]" \
    "eth_getBlockInternalTransactions (block $BELOW) → PROXY"

call_rpc "eth_getBlockInternalTransactions" "[\"latest\"]" \
    "eth_getBlockInternalTransactions (latest) → LOCAL"

call_rpc "eth_getInternalTransactions" "[\"$FOR_OP_TRANSACTION_HASH\"]" \
    "eth_getInternalTransactions (op-geth tx) → LOCAL"

call_rpc "eth_getInternalTransactions" "[\"$FOR_ERIGON_TRANSACTION_HASH\"]" \
    "eth_getInternalTransactions (erigon tx) → fallback to PROXY"

# ============================================
# FilterAPI Tests
# ============================================

echo -e "\n${GREEN}=== FilterAPI: Log Queries ===${NC}"

# Test getLogs with range before migration
call_rpc "eth_getLogs" "[{\"fromBlock\":\"0x$(printf '%x' $((BELOW - 5)))\",\"toBlock\":\"0x$(printf '%x' $BELOW)\"}]" \
    "eth_getLogs (range before migration) → PROXY"

# Test getLogs with range after migration
call_rpc "eth_getLogs" "[{\"fromBlock\":\"0x$(printf '%x' $MIGRATION_BLOCK)\",\"toBlock\":\"0x$(printf '%x' $ABOVE)\"}]" \
    "eth_getLogs (range after migration) → LOCAL"

# Test getLogs with overlapping range (should handle specially)
call_rpc "eth_getLogs" "[{\"fromBlock\":\"0x$(printf '%x' $BELOW)\",\"toBlock\":\"0x$(printf '%x' $ABOVE)\"}]" \
    "eth_getLogs (overlapping range) → COMBINED"

# Test getLogs with only contract address (no block range) - should run locally
call_rpc "eth_getLogs" "[{\"address\":\"$CONTRACT_ADDRESS\"}]" \
    "eth_getLogs (only contract address, no block range) → LOCAL"

# Test getLogs with contract address and range before migration
call_rpc "eth_getLogs" "[{\"address\":\"$CONTRACT_ADDRESS\",\"fromBlock\":\"0x$(printf '%x' $BELOW)\",\"toBlock\":\"0x$(printf '%x' $((BELOW + 5)))\"}]" \
    "eth_getLogs (contract address with range before migration) → PROXY"

echo -e "\n${GREEN}=== FilterAPI: Filter Management ===${NC}"

# Create filter before migration
FILTER_ID=$(curl -s -X POST $RPC_URL \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_newFilter\",\"params\":[{\"fromBlock\":\"0x$(printf '%x' $((BELOW - 5)))\",\"toBlock\":\"0x$(printf '%x' $BELOW)\"}],\"id\":1}" \
    | jq -r '.result')

if [ "$FILTER_ID" != "null" ] && [ -n "$FILTER_ID" ]; then
    echo -e "\n${BLUE}eth_newFilter (range before migration) → PROXY${NC}"
    echo "→ Created filter: $FILTER_ID"
    
    call_rpc "eth_getFilterLogs" "[\"$FILTER_ID\"]" \
        "eth_getFilterLogs (Erigon filter) → PROXY"
    
    call_rpc "eth_getFilterChanges" "[\"$FILTER_ID\"]" \
        "eth_getFilterChanges (Erigon filter) → PROXY"
    
    call_rpc "eth_uninstallFilter" "[\"$FILTER_ID\"]" \
        "eth_uninstallFilter (Erigon filter) → PROXY"
fi

# Create filter spanning migration block
FILTER_ID_LOCAL=$(curl -s -X POST $RPC_URL \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_newFilter\",\"params\":[{\"fromBlock\":\"0x$(printf '%x' $MIGRATION_BLOCK)\",\"toBlock\":\"0x$(printf '%x' $ABOVE)\"}],\"id\":1}" \
    | jq -r '.result')

if [ "$FILTER_ID_LOCAL" != "null" ] && [ -n "$FILTER_ID_LOCAL" ]; then
    echo -e "\n${BLUE}eth_newFilter (range spanning migration block) → LOCAL${NC}"
    echo "→ Created filter: $FILTER_ID_LOCAL"
    
    call_rpc "eth_getFilterLogs" "[\"$FILTER_ID_LOCAL\"]" \
        "eth_getFilterLogs (spanning filter) → LOCAL"
    
    call_rpc "eth_getFilterChanges" "[\"$FILTER_ID_LOCAL\"]" \
        "eth_getFilterChanges (spanning filter) → LOCAL"
    
    call_rpc "eth_uninstallFilter" "[\"$FILTER_ID_LOCAL\"]" \
        "eth_uninstallFilter (spanning filter) → LOCAL"
fi

# Test overlapping filter (should error)
echo -e "\n${BLUE}eth_newFilter (overlapping range) → ERROR EXPECTED${NC}"
curl -s -X POST $RPC_URL \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_newFilter\",\"params\":[{\"fromBlock\":\"0x$(printf '%x' $BELOW)\",\"toBlock\":\"0x$(printf '%x' $ABOVE)\"}],\"id\":1}" \
    | jq -r '.error // "No error"'

# ============================================
# Summary
# ============================================

echo -e "\n${GREEN}=================================================="
echo "Test Complete"
echo "==================================================${NC}"
echo ""
echo "Routing Summary:"
echo "  FORWARD:     Block number queries route based on migration cutoff"
echo "  LOCAL:       Hash-based queries try local first, fallback to Erigon"
echo "  SPECIAL:     Filter overlapping ranges are handled specially"
echo ""
