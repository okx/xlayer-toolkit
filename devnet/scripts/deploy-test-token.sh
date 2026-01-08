#!/bin/bash
set -e

PWD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAILGUN_ENV_FILE="$PWD_DIR/railgun/.env.railgun"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🪙 Deploying Test ERC20 Token"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$PWD_DIR"
source .env

# Load RAILGUN internal configuration
if [ -f "$RAILGUN_ENV_FILE" ]; then
    source "$RAILGUN_ENV_FILE"
fi

PRIVATE_KEY=${OP_PROPOSER_PRIVATE_KEY}
RPC_URL="http://127.0.0.1:8123"

echo "📦 Compiling and deploying ERC20..."

cat > /tmp/SimpleToken.sol << 'SOLIDITY'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SimpleToken {
    string public name = "MyToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor() {
        totalSupply = 1000000 * 10**18;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }
    
    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
    
    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
}
SOLIDITY

echo "   Using solc to compile..."
BYTECODE=$(solc --bin --optimize /tmp/SimpleToken.sol 2>/dev/null | tail -1)

echo "   ✓ Bytecode ready"
echo "   📤 Deploying to L2..."

DEPLOY_TX=$(cast send --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --create "$BYTECODE" \
    --json 2>&1)

if echo "$DEPLOY_TX" | grep -q "contractAddress"; then
    TOKEN_ADDRESS=$(echo "$DEPLOY_TX" | jq -r '.contractAddress')
    echo "   ✅ Token deployed!"
    echo ""
    echo "   📋 Token Address: $TOKEN_ADDRESS"
    echo ""
    echo "   💾 Saving to railgun/.env.railgun..."
    
    if grep -q "^RAILGUN_TEST_TOKEN_ADDRESS=" "$RAILGUN_ENV_FILE"; then
        sed -i.bak "s|^RAILGUN_TEST_TOKEN_ADDRESS=.*|RAILGUN_TEST_TOKEN_ADDRESS=$TOKEN_ADDRESS|" "$RAILGUN_ENV_FILE"
    else
        echo "RAILGUN_TEST_TOKEN_ADDRESS=$TOKEN_ADDRESS" >> "$RAILGUN_ENV_FILE"
    fi
    rm -f "$RAILGUN_ENV_FILE.bak"
    
    echo "🎉 Test token deployed successfully!"
else
    echo "   ❌ Deployment failed!"
    echo "$DEPLOY_TX"
    exit 1
fi
