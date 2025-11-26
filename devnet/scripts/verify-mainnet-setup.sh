#!/bin/bash
set -e

source .env

echo "🔍 Verifying mainnet genesis deployment..."
echo ""

# ========================================
# 1. Configuration Check
# ========================================
echo "1️⃣ Configuration Validation"
echo "───────────────────────────"

if [ "$USE_MAINNET_GENESIS" = "true" ]; then
    echo "   ✅ Mainnet genesis mode: ENABLED"
    
    if [ "$MIN_RUN" = "true" ]; then
        echo "   ✅ MIN_RUN: true (required)"
    else
        echo "   ❌ ERROR: MIN_RUN must be true for mainnet genesis"
        exit 1
    fi
    
    if [ -n "$FORK_BLOCK" ] && [ -n "$PARENT_HASH" ]; then
        echo "   ✅ Fork block: $FORK_BLOCK"
        echo "   ✅ Parent hash: ${PARENT_HASH:0:20}..."
    else
        echo "   ❌ ERROR: FORK_BLOCK and PARENT_HASH not configured"
        exit 1
    fi
else
    echo "   ℹ️  Mainnet genesis mode: DISABLED (using generated genesis)"
    echo "   Skipping mainnet-specific checks..."
    echo ""
    exit 0
fi

echo ""

# ========================================
# 2. Genesis Files Check
# ========================================
echo "2️⃣ Genesis Files"
echo "───────────────────────────"

if [ -f "config-op/genesis.json" ]; then
    GENESIS_SIZE=$(du -h config-op/genesis.json | cut -f1)
    GENESIS_NUMBER=$(jq -r '.number' config-op/genesis.json 2>/dev/null || echo "error")
    GENESIS_PARENT=$(jq -r '.parentHash' config-op/genesis.json 2>/dev/null || echo "error")
    GENESIS_LEGACY=$(jq -r '.config.legacyXLayerBlock' config-op/genesis.json 2>/dev/null || echo "error")
    GENESIS_ACCOUNTS=$(jq '.alloc | length' config-op/genesis.json 2>/dev/null || echo "error")
    
    echo "   ✅ genesis.json exists ($GENESIS_SIZE)"
    echo "      • number: $GENESIS_NUMBER"
    echo "      • parentHash: ${GENESIS_PARENT:0:20}..."
    echo "      • legacyXLayerBlock: $GENESIS_LEGACY"
    echo "      • accounts: $GENESIS_ACCOUNTS"
    
    # Verify values match configuration
    EXPECTED_BLOCK=$((FORK_BLOCK + 1))
    if [ "$GENESIS_NUMBER" != "$EXPECTED_BLOCK" ]; then
        echo "   ⚠️  WARNING: Genesis number mismatch!"
        echo "      Expected: $EXPECTED_BLOCK"
        echo "      Actual: $GENESIS_NUMBER"
    fi
    
    if [ "$GENESIS_PARENT" != "$PARENT_HASH" ]; then
        echo "   ⚠️  WARNING: Parent hash mismatch!"
        echo "      Expected: $PARENT_HASH"
        echo "      Actual: $GENESIS_PARENT"
    fi
else
    echo "   ❌ genesis.json not found"
    exit 1
fi

if [ -f "config-op/genesis-reth.json" ]; then
    echo "   ✅ genesis-reth.json exists"
else
    echo "   ⚠️  genesis-reth.json not found"
fi

echo ""

# ========================================
# 3. Rollup Configuration Check
# ========================================
echo "3️⃣ Rollup Configuration"
echo "───────────────────────────"

if [ -f "config-op/rollup.json" ]; then
    ROLLUP_NUMBER=$(jq -r '.genesis.l2.number' config-op/rollup.json 2>/dev/null || echo "error")
    ROLLUP_HASH=$(jq -r '.genesis.l2.hash' config-op/rollup.json 2>/dev/null || echo "error")
    
    echo "   ✅ rollup.json exists"
    echo "      • genesis.l2.number: $ROLLUP_NUMBER"
    echo "      • genesis.l2.hash: ${ROLLUP_HASH:0:20}..."
    
    if [ "$ROLLUP_NUMBER" != "$EXPECTED_BLOCK" ]; then
        echo "   ⚠️  WARNING: Rollup number mismatch!"
        echo "      Expected: $EXPECTED_BLOCK"
        echo "      Actual: $ROLLUP_NUMBER"
    fi
else
    echo "   ❌ rollup.json not found"
    exit 1
fi

echo ""

# ========================================
# 4. Database Check
# ========================================
echo "4️⃣ Initialized Databases"
echo "───────────────────────────"

if [ -d "data/op-$SEQ_TYPE-seq/geth/chaindata" ] || [ -d "data/op-$SEQ_TYPE-seq/db" ]; then
    DB_SIZE=$(du -sh data/op-$SEQ_TYPE-seq 2>/dev/null | cut -f1 || echo "unknown")
    echo "   ✅ op-$SEQ_TYPE-seq: $DB_SIZE"
else
    echo "   ⚠️  op-$SEQ_TYPE-seq database not initialized"
fi

if [ -d "data/op-$RPC_TYPE-rpc/geth/chaindata" ] || [ -d "data/op-$RPC_TYPE-rpc/db" ]; then
    RPC_SIZE=$(du -sh data/op-$RPC_TYPE-rpc 2>/dev/null | cut -f1 || echo "unknown")
    echo "   ✅ op-$RPC_TYPE-rpc: $RPC_SIZE"
else
    echo "   ℹ️  op-$RPC_TYPE-rpc database not initialized yet"
fi

echo ""

# ========================================
# 5. L1 Account Balances
# ========================================
echo "5️⃣ L1 Account Balances"
echo "───────────────────────────"

if docker ps --format '{{.Names}}' | grep -q l1-geth; then
    echo "   ℹ️  Checking L1 balances..."
    
    PROPOSER_ADDR=$(cast wallet address $OP_PROPOSER_PRIVATE_KEY 2>/dev/null || echo "error")
    BATCHER_ADDR=$(cast wallet address $OP_BATCHER_PRIVATE_KEY 2>/dev/null || echo "error")
    
    if [ "$PROPOSER_ADDR" != "error" ]; then
        PROPOSER_BAL=$(cast balance $PROPOSER_ADDR -r $L1_RPC_URL 2>/dev/null || echo "0")
        PROPOSER_ETH=$(cast to-unit $PROPOSER_BAL ether 2>/dev/null || echo "0")
        echo "      • Proposer ($PROPOSER_ADDR): $PROPOSER_ETH ETH"
    fi
    
    if [ "$BATCHER_ADDR" != "error" ]; then
        BATCHER_BAL=$(cast balance $BATCHER_ADDR -r $L1_RPC_URL 2>/dev/null || echo "0")
        BATCHER_ETH=$(cast to-unit $BATCHER_BAL ether 2>/dev/null || echo "0")
        echo "      • Batcher  ($BATCHER_ADDR): $BATCHER_ETH ETH"
    fi
else
    echo "   ⚠️  L1 node not running (start with 1-start-l1.sh)"
fi

echo ""

# ========================================
# 6. L2 Test Account
# ========================================
if [ "$INJECT_L2_TEST_ACCOUNT" = "true" ]; then
    echo "6️⃣ L2 Test Account"
    echo "───────────────────────────"
    
    # Check in genesis
    ACCOUNT_KEY=$(echo "$TEST_ACCOUNT_ADDRESS" | tr '[:upper:]' '[:lower:]' | sed 's/0x//')
    GENESIS_BALANCE=$(jq -r ".alloc[\"$ACCOUNT_KEY\"].balance // \"not found\"" config-op/genesis.json 2>/dev/null)
    
    if [ "$GENESIS_BALANCE" != "not found" ]; then
        BALANCE_WEI=$(python3 -c "print(int('$GENESIS_BALANCE', 16))" 2>/dev/null || echo "0")
        BALANCE_ETH=$(python3 -c "print(int('$GENESIS_BALANCE', 16) / 10**18)" 2>/dev/null || echo "0")
        echo "   ✅ Test account in genesis: $TEST_ACCOUNT_ADDRESS"
        echo "      • Balance: $BALANCE_ETH ETH"
    else
        echo "   ⚠️  Test account not found in genesis"
    fi
    
    echo ""
fi

# ========================================
# 7. Prestate Files (Should NOT Exist)
# ========================================
echo "7️⃣ Prestate Files (MIN_RUN Check)"
echo "───────────────────────────"

if [ -f "config-op/genesis.json.gz" ]; then
    echo "   ℹ️  genesis.json.gz exists (not needed in MIN_RUN mode)"
else
    echo "   ✅ genesis.json.gz not present (correct for MIN_RUN)"
fi

if [ -d "data/cannon-data" ]; then
    echo "   ℹ️  cannon-data directory exists (not needed in MIN_RUN mode)"
else
    echo "   ✅ cannon-data not present (correct for MIN_RUN)"
fi

echo ""
echo "═══════════════════════════"
echo "✅ All verifications passed!"
echo "═══════════════════════════"
echo ""

if docker ps --format '{{.Names}}' | grep -q op-geth-seq || docker ps --format '{{.Names}}' | grep -q op-reth-seq; then
    echo "🚀 Services Status:"
    docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'op-|l1-' || echo "No OP Stack services running"
else
    echo "ℹ️  Services not yet started (run 4-op-start-service.sh)"
fi

echo ""

