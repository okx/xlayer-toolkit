#!/bin/bash
# deploy-tee-contracts.sh — 资金转账 + TEE 合约部署
# 部署 MockTeeProofVerifier + AccessManager + TeeDisputeGame，注册到 DisputeGameFactory
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEVNET_DIR/.tee.env"

echo "========================================"
echo "  TEE Contract Deployment"
echo "========================================"

# ============================================================
# Phase 0: 给 TEE 角色账户充值
# ============================================================
echo ""
echo "=== Phase 0: Fund TEE accounts ==="

fund_account() {
    local name=$1
    local address=$2
    local balance
    balance=$(cast balance --rpc-url "$L1_RPC_URL" "$address" 2>/dev/null || echo "0")
    echo "  $name ($address): current balance = $balance wei"
    if [ "$balance" = "0" ] || [ "$(echo "$balance < 1000000000000000000" | bc 2>/dev/null || echo 1)" = "1" ]; then
        echo "  Funding $name with $FUND_AMOUNT..."
        cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$RICH_L1_PRIVATE_KEY" \
            --value "$FUND_AMOUNT" "$address" > /dev/null
        echo "  Funded. New balance: $(cast balance --rpc-url "$L1_RPC_URL" "$address") wei"
    else
        echo "  Sufficient balance, skipping funding."
    fi
}

fund_account "TEE Proposer" "$TEE_PROPOSER_ADDRESS"
fund_account "TEE Challenger" "$TEE_CHALLENGER_ADDRESS"
fund_account "External Challenger" "$TEE_EXTERNAL_CHALLENGER_ADDRESS"

# ============================================================
# Phase 1: 获取 AnchorStateRegistry 地址
# ============================================================
echo ""
echo "=== Phase 1: Resolve AnchorStateRegistry ==="

# 从现有 devnet 的 game implementation 中提取 AnchorStateRegistry 地址
ANCHOR_STATE_REGISTRY_ADDR=""
for gtype in 0 1 2; do
    EXISTING_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameImpls(uint32)(address)" "$gtype" 2>/dev/null || echo "")
    if [ -n "$EXISTING_IMPL" ] && [ "$EXISTING_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
        ANCHOR_STATE_REGISTRY_ADDR=$(cast call --rpc-url "$L1_RPC_URL" "$EXISTING_IMPL" \
            "anchorStateRegistry()(address)" 2>/dev/null || echo "")
        if [ -n "$ANCHOR_STATE_REGISTRY_ADDR" ] && [ "$ANCHOR_STATE_REGISTRY_ADDR" != "0x0000000000000000000000000000000000000000" ]; then
            echo "Found AnchorStateRegistry from game type $gtype: $ANCHOR_STATE_REGISTRY_ADDR"
            break
        fi
    fi
done

if [ -z "$ANCHOR_STATE_REGISTRY_ADDR" ] || [ "$ANCHOR_STATE_REGISTRY_ADDR" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: Cannot find AnchorStateRegistry address."
    echo "  Ensure base devnet has at least one game type registered in the factory."
    exit 1
fi

# ============================================================
# Phase 2: 部署合约
# ============================================================
echo ""
echo "=== Phase 2: Deploy TEE Contracts ==="

# 1. 部署 MockTeeProofVerifier
echo ""
echo "--- 1. Deploying MockTeeProofVerifier ---"
MOCK_VERIFIER_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -w /app/packages/contracts-bedrock \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    forge create --json --broadcast --legacy \
        --rpc-url "$L1_RPC_URL_IN_DOCKER" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        test/dispute/tee/mocks/MockTeeProofVerifier.sol:MockTeeProofVerifier)
MOCK_VERIFIER_ADDR=$(echo "$MOCK_VERIFIER_OUTPUT" | jq -r '.deployedTo')
echo "MockTeeProofVerifier deployed at: $MOCK_VERIFIER_ADDR"

# 2. 注册 Mock Signer
echo ""
echo "--- 2. Registering mock signer ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$MOCK_VERIFIER_ADDR" \
    "setRegistered(address,bool)" "$TEE_MOCK_SIGNER_ADDRESS" true > /dev/null
IS_REGISTERED=$(cast call --rpc-url "$L1_RPC_URL" "$MOCK_VERIFIER_ADDR" \
    "isRegistered(address)(bool)" "$TEE_MOCK_SIGNER_ADDRESS")
echo "Signer $TEE_MOCK_SIGNER_ADDRESS registered: $IS_REGISTERED"

# 3. 部署 AccessManager
echo ""
echo "--- 3. Deploying AccessManager ---"
ACCESS_MGR_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -w /app/packages/contracts-bedrock \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    forge create --json --broadcast --legacy \
        --rpc-url "$L1_RPC_URL_IN_DOCKER" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        "src/dispute/tee/AccessManager.sol:AccessManager" \
        --constructor-args "$TEE_FALLBACK_TIMEOUT" "$DISPUTE_GAME_FACTORY_ADDRESS")
ACCESS_MGR_ADDR=$(echo "$ACCESS_MGR_OUTPUT" | jq -r '.deployedTo')
echo "AccessManager deployed at: $ACCESS_MGR_ADDR"

# 4. 设置 proposer 和 challenger 白名单
echo ""
echo "--- 4. Setting proposer/challenger whitelist ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$ACCESS_MGR_ADDR" "setProposer(address,bool)" "$TEE_PROPOSER_ADDRESS" true > /dev/null
echo "Proposer $TEE_PROPOSER_ADDRESS whitelisted"

cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$ACCESS_MGR_ADDR" "setChallenger(address,bool)" "$TEE_CHALLENGER_ADDRESS" true > /dev/null
echo "Challenger $TEE_CHALLENGER_ADDRESS whitelisted"

# 也给外部挑战者加白名单（测试用）
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$ACCESS_MGR_ADDR" "setChallenger(address,bool)" "$TEE_EXTERNAL_CHALLENGER_ADDRESS" true > /dev/null
echo "External Challenger $TEE_EXTERNAL_CHALLENGER_ADDRESS whitelisted"

# 5. 部署 TeeDisputeGame implementation
echo ""
echo "--- 5. Deploying TeeDisputeGame ---"
TEE_GAME_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -w /app/packages/contracts-bedrock \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    forge create --json --broadcast --legacy \
        --rpc-url "$L1_RPC_URL_IN_DOCKER" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        "src/dispute/tee/TeeDisputeGame.sol:TeeDisputeGame" \
        --constructor-args \
            "$TEE_MAX_CHALLENGE_DURATION" \
            "$TEE_MAX_PROVE_DURATION" \
            "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "$MOCK_VERIFIER_ADDR" \
            "$TEE_CHALLENGER_BOND" \
            "$ANCHOR_STATE_REGISTRY_ADDR" \
            "$ACCESS_MGR_ADDR")
TEE_GAME_IMPL=$(echo "$TEE_GAME_OUTPUT" | jq -r '.deployedTo')
echo "TeeDisputeGame deployed at: $TEE_GAME_IMPL"

# ============================================================
# Phase 3: 在 DisputeGameFactory 注册 TEE game type
# ============================================================
echo ""
echo "=== Phase 2: Register TEE game type in factory ==="

# 6. setImplementation
echo "--- 6. Setting implementation ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "setImplementation(uint32,address)" "$TEE_GAME_TYPE" "$TEE_GAME_IMPL" > /dev/null
echo "factory.setImplementation($TEE_GAME_TYPE, $TEE_GAME_IMPL)"

# 7. setInitBond
echo "--- 7. Setting init bond ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "setInitBond(uint32,uint256)" "$TEE_GAME_TYPE" "$TEE_INIT_BOND" > /dev/null
echo "factory.setInitBond($TEE_GAME_TYPE, $TEE_INIT_BOND)"

# ============================================================
# Phase 4: 验证
# ============================================================
echo ""
echo "=== Phase 4: Verification ==="
REGISTERED_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "gameImpls(uint32)(address)" "$TEE_GAME_TYPE")
echo "Factory gameImpls($TEE_GAME_TYPE) = $REGISTERED_IMPL"

REGISTERED_BOND=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "initBonds(uint32)(uint256)" "$TEE_GAME_TYPE")
echo "Factory initBonds($TEE_GAME_TYPE) = $REGISTERED_BOND"

if [ "$REGISTERED_IMPL" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: TEE game type not registered!"
    exit 1
fi

# ============================================================
# 保存合约地址供后续脚本使用
# ============================================================
cat > "$DEVNET_DIR/tee-contracts.env" << EOF
# Auto-generated by deploy-tee-contracts.sh — $(date)
TEE_MOCK_VERIFIER_ADDR=$MOCK_VERIFIER_ADDR
TEE_ACCESS_MANAGER_ADDR=$ACCESS_MGR_ADDR
TEE_GAME_IMPL_ADDR=$TEE_GAME_IMPL
EOF

echo ""
echo "========================================"
echo "  TEE Contracts deployed successfully!"
echo "  Addresses saved to tee-contracts.env"
echo "========================================"
