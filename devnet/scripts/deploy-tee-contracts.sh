#!/bin/bash
# deploy-tee-contracts.sh — 资金转账 + TEE 合约部署
# 部署 MockTeeProofVerifier + AccessManager + TeeDisputeGame，注册到 DisputeGameFactory
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 保存调用方 export 的值（source .tee.env 可能覆盖）
_FACTORY_ADDR="${DISPUTE_GAME_FACTORY_ADDRESS:-}"
_ANCHOR_ADDR="${ANCHOR_STATE_REGISTRY_ADDRESS:-}"
source "$DEVNET_DIR/.tee.env"
# 恢复调用方 export 的值（优先于 .tee.env 中的硬编码值）
[ -n "$_FACTORY_ADDR" ] && DISPUTE_GAME_FACTORY_ADDRESS="$_FACTORY_ADDR"
[ -n "$_ANCHOR_ADDR" ] && ANCHOR_STATE_REGISTRY_ADDRESS="$_ANCHOR_ADDR"

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

# 优先使用调用方传入的地址
if [ -n "$ANCHOR_STATE_REGISTRY_ADDRESS" ] && [ "$ANCHOR_STATE_REGISTRY_ADDRESS" != "0x0000000000000000000000000000000000000000" ]; then
    ANCHOR_STATE_REGISTRY_ADDR="$ANCHOR_STATE_REGISTRY_ADDRESS"
    echo "  Using provided AnchorStateRegistry: $ANCHOR_STATE_REGISTRY_ADDR"
else
    # 从现有 devnet 的 game implementation 中提取 AnchorStateRegistry 地址
    ANCHOR_STATE_REGISTRY_ADDR=""
    for gtype in 0 1 2; do
        EXISTING_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "gameImpls(uint32)(address)" "$gtype" 2>/dev/null || echo "")
        if [ -n "$EXISTING_IMPL" ] && [ "$EXISTING_IMPL" != "0x0000000000000000000000000000000000000000" ]; then
            ANCHOR_STATE_REGISTRY_ADDR=$(cast call --rpc-url "$L1_RPC_URL" "$EXISTING_IMPL" \
                "anchorStateRegistry()(address)" 2>/dev/null || echo "")
            if [ -n "$ANCHOR_STATE_REGISTRY_ADDR" ] && [ "$ANCHOR_STATE_REGISTRY_ADDR" != "0x0000000000000000000000000000000000000000" ]; then
                echo "  Found AnchorStateRegistry from game type $gtype: $ANCHOR_STATE_REGISTRY_ADDR"
                break
            fi
        fi
    done

    if [ -z "$ANCHOR_STATE_REGISTRY_ADDR" ] || [ "$ANCHOR_STATE_REGISTRY_ADDR" = "0x0000000000000000000000000000000000000000" ]; then
        echo "ERROR: Cannot find AnchorStateRegistry address."
        echo "  Ensure base devnet has at least one game type registered in the factory."
        exit 1
    fi
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

# 5. 部署 TeeDisputeGame implementation（短 duration 用于 bootstrap）
echo ""
echo "--- 5. Deploying TeeDisputeGame (bootstrap, short durations) ---"
BOOTSTRAP_CHALLENGE_DURATION=10  # 10 秒，仅用于 bootstrap game
BOOTSTRAP_PROVE_DURATION=10
TEE_GAME_OUTPUT=$(docker run --rm \
    --network "$DOCKER_NETWORK" \
    -w /app/packages/contracts-bedrock \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    forge create --json --broadcast --legacy \
        --rpc-url "$L1_RPC_URL_IN_DOCKER" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        "src/dispute/tee/TeeDisputeGame.sol:TeeDisputeGame" \
        --constructor-args \
            "$BOOTSTRAP_CHALLENGE_DURATION" \
            "$BOOTSTRAP_PROVE_DURATION" \
            "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "$MOCK_VERIFIER_ADDR" \
            "$TEE_CHALLENGER_BOND" \
            "$ANCHOR_STATE_REGISTRY_ADDR" \
            "$ACCESS_MGR_ADDR")
BOOTSTRAP_GAME_IMPL=$(echo "$TEE_GAME_OUTPUT" | jq -r '.deployedTo')
echo "TeeDisputeGame (bootstrap) deployed at: $BOOTSTRAP_GAME_IMPL"

# ============================================================
# Phase 3: 注册 bootstrap impl → 创建 bootstrap game → resolve → setAnchorState
# ============================================================
echo ""
echo "=== Phase 3: Bootstrap anchor state ==="

# 6. setImplementation（短 duration impl）
echo "--- 6. Setting bootstrap implementation ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "setImplementation(uint32,address)" "$TEE_GAME_TYPE" "$BOOTSTRAP_GAME_IMPL" > /dev/null
echo "factory.setImplementation($TEE_GAME_TYPE, $BOOTSTRAP_GAME_IMPL)"

# 7. setInitBond
echo "--- 7. Setting init bond ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "setInitBond(uint32,uint256)" "$TEE_GAME_TYPE" "$TEE_INIT_BOND" > /dev/null
echo "factory.setInitBond($TEE_GAME_TYPE, $TEE_INIT_BOND)"

# 8. 设置 respectedGameType 为 TEE game type
# setAnchorState 要求 wasRespectedGameTypeWhenCreated == true，
# 而 TeeDisputeGame.initialize() 在创建时检查 respectedGameType == GAME_TYPE。
# 只有 Guardian（= deployer）可以调用 setRespectedGameType。
echo "--- 8. Setting respectedGameType to $TEE_GAME_TYPE ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$ANCHOR_STATE_REGISTRY_ADDR" \
    "setRespectedGameType(uint32)" "$TEE_GAME_TYPE" > /dev/null
echo "anchorStateRegistry.setRespectedGameType($TEE_GAME_TYPE)"

# anchor state 默认是 0xdead... sentinel，prove() 无法通过校验。
# 创建一个 bootstrap game，等 deadline 过期后 resolve，然后设为 anchor。

ANCHOR_BLK_HASH=0x0000000000000000000000000000000000000000000000000000000000000001
ANCHOR_ST_HASH=0x0000000000000000000000000000000000000000000000000000000000000001
ANCHOR_ROOT=$(cast keccak "$(cast abi-encode "f(bytes32,bytes32)" "$ANCHOR_BLK_HASH" "$ANCHOR_ST_HASH")")

# extraData: tightly packed (100 bytes)
L2_SEQ_HEX=$(printf '%064x' 1)
PARENT_IDX_HEX="ffffffff"
BLK_HASH_HEX=$(echo "$ANCHOR_BLK_HASH" | sed 's/^0x//')
ST_HASH_HEX=$(echo "$ANCHOR_ST_HASH" | sed 's/^0x//')
BOOTSTRAP_EXTRA="${L2_SEQ_HEX}${PARENT_IDX_HEX}${BLK_HASH_HEX}${ST_HASH_HEX}"

INIT_BOND=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "initBonds(uint32)(uint256)" "$TEE_GAME_TYPE" | awk '{print $1}')

echo "  Creating bootstrap game (challengeDuration=${BOOTSTRAP_CHALLENGE_DURATION}s)..."
echo "    rootClaim: $ANCHOR_ROOT"
echo "    initBond: $INIT_BOND wei"

cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$TEE_PROPOSER_PRIVATE_KEY" \
    --value "$INIT_BOND" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "create(uint32,bytes32,bytes)(address)" \
    "$TEE_GAME_TYPE" "$ANCHOR_ROOT" "0x${BOOTSTRAP_EXTRA}" > /dev/null

GAME_COUNT=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" | awk '{print $1}')
BOOTSTRAP_GAME=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "gameAtIndex(uint256)(uint32,uint64,address)" "$((GAME_COUNT - 1))" | tail -1)
echo "  Bootstrap game: $BOOTSTRAP_GAME"

# 等待短 challenge deadline 过期
WAIT_SECS=$((BOOTSTRAP_CHALLENGE_DURATION + 15))
echo "  Waiting ${WAIT_SECS}s for bootstrap challenge deadline..."
sleep "$WAIT_SECS"

# Resolve (no challenge → DEFENDER_WINS)
echo "  Resolving bootstrap game..."
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$BOOTSTRAP_GAME" "resolve()" > /dev/null

BOOT_STATUS=$(cast call --rpc-url "$L1_RPC_URL" "$BOOTSTRAP_GAME" "status()(uint8)" | awk '{print $1}')
if [ "$BOOT_STATUS" != "2" ]; then
    echo "  ERROR: Bootstrap game status=$BOOT_STATUS, expected 2 (DEFENDER_WINS)"
    exit 1
fi
echo "  Bootstrap game resolved: DEFENDER_WINS"

# 等待 finality delay（isGameFinalized 要求 block.timestamp - resolvedAt > FINALITY_DELAY）
FINALITY_DELAY=${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-5}
echo "  Waiting $((FINALITY_DELAY + 5))s for finality delay..."
sleep "$((FINALITY_DELAY + 5))"

# setAnchorState
echo "  Setting anchor state..."
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$ANCHOR_STATE_REGISTRY_ADDR" \
    "setAnchorState(address)" "$BOOTSTRAP_GAME" > /dev/null

NEW_ANCHOR=$(cast call --rpc-url "$L1_RPC_URL" "$ANCHOR_STATE_REGISTRY_ADDR" \
    "anchors(uint32)(bytes32,uint256)" "$TEE_GAME_TYPE" | head -1)
echo "  New anchor root: $NEW_ANCHOR"

# ============================================================
# Phase 4: 部署正式 TeeDisputeGame impl（正常 duration）并替换
# ============================================================
echo ""
echo "=== Phase 4: Deploy production TeeDisputeGame ==="

echo "--- 8. Deploying TeeDisputeGame (production durations) ---"
echo "    maxChallengeDuration: $TEE_MAX_CHALLENGE_DURATION"
echo "    maxProveDuration: $TEE_MAX_PROVE_DURATION"
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
echo "TeeDisputeGame (production) deployed at: $TEE_GAME_IMPL"

# 9. 替换 factory 的 implementation 为正式版
echo "--- 9. Updating factory implementation to production ---"
cast send --legacy --rpc-url "$L1_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
    "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "setImplementation(uint32,address)" "$TEE_GAME_TYPE" "$TEE_GAME_IMPL" > /dev/null
echo "factory.setImplementation($TEE_GAME_TYPE, $TEE_GAME_IMPL)"

# ============================================================
# Phase 5: 验证
# ============================================================
echo ""
echo "=== Phase 5: Verification ==="
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
