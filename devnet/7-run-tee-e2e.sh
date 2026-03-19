#!/bin/bash
# 7-run-tee-e2e.sh — TEE Dispute Game E2E 测试主入口
#
# 前提条件:
#   1. 基础 devnet 已启动 (./0-all.sh)
#   2. .tee.env 已配置 (cp tee.env .tee.env && 编辑)
#   3. 宿主机 Mock 组件已启动:
#      - mockteerpc --addr=:8090 --init-height=1000000
#      - SIGNER_PRIVATE_KEY=xxx ./e2e/mock-tee-prover/mock-tee-prover
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEVNET_DIR"

source .tee.env
source tee-contracts.env 2>/dev/null || true

SCRIPTS_DIR="$DEVNET_DIR/scripts"
E2E_DIR="$DEVNET_DIR/e2e"

echo "========================================"
echo "  TEE Dispute Game E2E Tests"
echo "========================================"
echo ""

# ============================================================
# Phase 0: 前置检查
# ============================================================
echo "=== Phase 0: Pre-flight checks ==="

# 检查 L1 节点
echo "  Checking L1 node..."
if ! cast block-number --rpc-url "$L1_RPC_URL" > /dev/null 2>&1; then
    echo "ERROR: L1 node not reachable at $L1_RPC_URL"
    echo "  Run ./0-all.sh first to start the devnet."
    exit 1
fi
echo "  L1 node: OK (block $(cast block-number --rpc-url "$L1_RPC_URL"))"

# 检查 mockteerpc
echo "  Checking mockteerpc..."
if ! curl -s http://localhost:8090/v1/chain/confirmed_block_info > /dev/null 2>&1; then
    echo "ERROR: mockteerpc not running on :8090"
    echo "  Start it: mockteerpc --addr=:8090 --init-height=1000000"
    exit 1
fi
echo "  mockteerpc: OK"

# 检查 mock-tee-prover
echo "  Checking mock-tee-prover..."
if ! curl -s http://localhost:8690/health > /dev/null 2>&1; then
    echo "ERROR: mock-tee-prover not running on :8690"
    echo "  Start it: SIGNER_PRIVATE_KEY=\$TEE_MOCK_SIGNER_PRIVATE_KEY ./e2e/mock-tee-prover/mock-tee-prover"
    exit 1
fi
echo "  mock-tee-prover: OK"

# 检查 DisputeGameFactory
echo "  Checking DisputeGameFactory..."
GAME_COUNT=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" 2>/dev/null || echo "ERROR")
if [ "$GAME_COUNT" = "ERROR" ]; then
    echo "ERROR: Cannot reach DisputeGameFactory at $DISPUTE_GAME_FACTORY_ADDRESS"
    exit 1
fi
echo "  DisputeGameFactory: OK (game count: $GAME_COUNT)"

echo ""

# ============================================================
# Phase 1: 部署 TEE 合约（如尚未部署）
# ============================================================
echo "=== Phase 1: Deploy TEE contracts ==="

if [ ! -f tee-contracts.env ]; then
    echo "  tee-contracts.env not found, deploying..."
    bash "$SCRIPTS_DIR/deploy-tee-contracts.sh"
    source tee-contracts.env
    echo ""
else
    echo "  tee-contracts.env exists, verifying..."
    source tee-contracts.env
    REGISTERED_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameImpls(uint32)(address)" "$TEE_GAME_TYPE" 2>/dev/null || echo "0x0")
    if [ "$REGISTERED_IMPL" = "0x0000000000000000000000000000000000000000" ]; then
        echo "  WARNING: TEE game type not registered, re-deploying..."
        rm -f tee-contracts.env
        bash "$SCRIPTS_DIR/deploy-tee-contracts.sh"
        source tee-contracts.env
    else
        echo "  TEE contracts verified: gameImpls($TEE_GAME_TYPE) = $REGISTERED_IMPL"
    fi
    echo ""
fi

# ============================================================
# Phase 2: 启动 TEE Docker 服务
# ============================================================
echo "=== Phase 2: Start TEE services ==="

echo "  Starting tee-op-proposer and tee-op-challenger..."
docker compose --env-file .env --env-file .tee.env -f docker-compose.yml -f docker-compose.tee.yml up -d tee-op-proposer tee-op-challenger

# 等待容器启动
echo "  Waiting for containers to start..."
sleep 5

# 验证容器运行中
for svc in tee-op-proposer tee-op-challenger; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        echo "  $svc: running"
    else
        echo "ERROR: $svc is not running"
        docker logs "$svc" 2>&1 | tail -20
        exit 1
    fi
done
echo ""

# ============================================================
# Phase 3: 执行测试
# ============================================================
echo "=== Phase 3: Run test scenarios ==="
PASS=0
FAIL=0
SKIP=0

run_test() {
    local name=$1
    local script=$2
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if bash "$script"; then
        echo "✓ PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# 场景 E 先跑（最简单，只验证 proposer 创建 game）
run_test "Scenario E: Proposer Creates Game" "$E2E_DIR/tee/test_proposer_create.sh"

# 场景 A: Happy Path
run_test "Scenario A: Defend Success" "$E2E_DIR/tee/test_defend_success.sh"

# 场景 B: Prove Timeout
run_test "Scenario B: Prove Timeout" "$E2E_DIR/tee/test_prove_timeout.sh"

# 场景 C: Unchallenged
run_test "Scenario C: Unchallenged" "$E2E_DIR/tee/test_unchallenged.sh"

# 场景 F: Prove Retry
run_test "Scenario F: Prove Retry" "$E2E_DIR/tee/test_prove_retry.sh"

# ============================================================
# Phase 4: 结果汇总
# ============================================================
echo ""
echo "========================================"
echo "  TEE E2E Test Results"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  Total: $((PASS + FAIL))"
echo "========================================"

# ============================================================
# Phase 5: 清理
# ============================================================
echo ""
echo "=== Phase 5: Cleanup ==="
echo "  Stopping TEE Docker services..."
docker compose --env-file .env --env-file .tee.env -f docker-compose.yml -f docker-compose.tee.yml stop tee-op-proposer tee-op-challenger
echo "  Done. (Mock components on host are still running)"
echo ""
echo "  To stop mock components:"
echo "    pkill -f mockteerpc"
echo "    pkill -f mock-tee-prover"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Some tests FAILED. Check logs:"
    echo "  docker logs tee-op-proposer"
    echo "  docker logs tee-op-challenger"
    exit 1
fi

exit 0
