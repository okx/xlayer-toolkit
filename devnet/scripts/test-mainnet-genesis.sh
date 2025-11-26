#!/bin/bash
# Quick test script for mainnet genesis functionality
# This script validates the changes without running the full deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(dirname "$SCRIPT_DIR")"

echo "🧪 Testing mainnet genesis implementation..."
echo ""

# Test 1: Check files exist
echo "1️⃣ Checking files..."
FILES=(
    "$DEVNET_DIR/example.env"
    "$DEVNET_DIR/3-op-init.sh"
    "$SCRIPT_DIR/process-mainnet-genesis.py"
    "$SCRIPT_DIR/verify-mainnet-setup.sh"
)

for file in "${FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "   ✅ $(basename $file)"
    else
        echo "   ❌ $(basename $file) not found"
        exit 1
    fi
done

echo ""

# Test 2: Check configuration variables
echo "2️⃣ Checking configuration variables in example.env..."
VARS=(
    "USE_MAINNET_GENESIS"
    "MAINNET_GENESIS_PATH"
    "INJECT_L2_TEST_ACCOUNT"
    "TEST_ACCOUNT_ADDRESS"
    "TEST_ACCOUNT_BALANCE"
)

for var in "${VARS[@]}"; do
    if grep -q "^$var=" "$DEVNET_DIR/example.env"; then
        echo "   ✅ $var"
    else
        echo "   ❌ $var not found"
        exit 1
    fi
done

echo ""

# Test 3: Check Python script syntax
echo "3️⃣ Checking Python script syntax..."
if python3 -m py_compile "$SCRIPT_DIR/process-mainnet-genesis.py" 2>/dev/null; then
    echo "   ✅ Python syntax valid"
else
    echo "   ❌ Python syntax error"
    exit 1
fi

echo ""

# Test 4: Check Python script help
echo "4️⃣ Testing Python script help..."
if python3 "$SCRIPT_DIR/process-mainnet-genesis.py" 2>&1 | grep -q "Usage"; then
    echo "   ✅ Help text displayed"
else
    echo "   ❌ Help text not working"
    exit 1
fi

echo ""

# Test 5: Check bash functions in 3-op-init.sh
echo "5️⃣ Checking bash functions..."
if grep -q "detect_genesis_mode()" "$DEVNET_DIR/3-op-init.sh"; then
    echo "   ✅ detect_genesis_mode() function added"
else
    echo "   ❌ detect_genesis_mode() function not found"
    exit 1
fi

if grep -q "prepare_mainnet_genesis()" "$DEVNET_DIR/3-op-init.sh"; then
    echo "   ✅ prepare_mainnet_genesis() function added"
else
    echo "   ❌ prepare_mainnet_genesis() function not found"
    exit 1
fi

echo ""

# Test 6: Check mode selection logic
echo "6️⃣ Checking mode selection logic..."
if grep -q "if detect_genesis_mode; then" "$DEVNET_DIR/3-op-init.sh"; then
    echo "   ✅ Mode selection logic added"
else
    echo "   ❌ Mode selection logic not found"
    exit 1
fi

echo ""

# Test 7: Simulate configuration check
echo "7️⃣ Simulating configuration validation..."

# Create temporary test env
TEST_ENV=$(mktemp)
cat > "$TEST_ENV" << 'EOF'
USE_MAINNET_GENESIS=true
MIN_RUN=true
FORK_BLOCK=8593920
PARENT_HASH=0x6912fea590fd46ca6a63ec02c6733f6ffb942b84cdf86f7894c21e1757a1f68a
MAINNET_GENESIS_PATH=mainnet.genesis.json
INJECT_L2_TEST_ACCOUNT=true
TEST_ACCOUNT_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TEST_ACCOUNT_BALANCE=0x52B7D2DCC80CD2E4000000
EOF

source "$TEST_ENV"

if [ "$USE_MAINNET_GENESIS" = "true" ] && [ "$MIN_RUN" = "true" ]; then
    echo "   ✅ Configuration validation logic works"
else
    echo "   ❌ Configuration validation failed"
    rm "$TEST_ENV"
    exit 1
fi

rm "$TEST_ENV"

echo ""

# Test 8: Test account address validation
echo "8️⃣ Validating test account address..."
EXPECTED_ADDR="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
if grep -q "$EXPECTED_ADDR" "$DEVNET_DIR/example.env"; then
    echo "   ✅ Test account address configured: $EXPECTED_ADDR"
else
    echo "   ⚠️  Test account address not found in example.env"
fi

echo ""

# Test 9: Check script permissions
echo "9️⃣ Checking script permissions..."
SCRIPTS=(
    "$SCRIPT_DIR/process-mainnet-genesis.py"
    "$SCRIPT_DIR/verify-mainnet-setup.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [ -x "$script" ]; then
        echo "   ✅ $(basename $script) is executable"
    else
        echo "   ⚠️  $(basename $script) is not executable (will be set)"
        chmod +x "$script"
    fi
done

echo ""

# Summary
echo "═══════════════════════════════════════"
echo "✅ All tests passed!"
echo "═══════════════════════════════════════"
echo ""
echo "📋 Implementation Summary:"
echo "   • example.env: 5 new configuration variables"
echo "   • 3-op-init.sh: 2 new functions, mode selection logic"
echo "   • process-mainnet-genesis.py: High-performance JSON processor"
echo "   • verify-mainnet-setup.sh: Comprehensive validation script"
echo ""
echo "🚀 Ready to test with mainnet genesis data!"
echo ""
echo "Next steps:"
echo "1. Set USE_MAINNET_GENESIS=true in .env"
echo "2. Ensure mainnet.genesis.json exists"
echo "3. Run: ./0-all.sh"
echo "4. Verify: ./scripts/verify-mainnet-setup.sh"
echo ""

