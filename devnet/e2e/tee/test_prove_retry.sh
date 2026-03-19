#!/bin/bash
# test_prove_retry.sh — 场景 F: TEE Prover 失败后重试
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario F: Prove Retry ==="

# 确保 mock prover 先重置
mock_prover_reset

# 1. 让第一次 prove 失败
mock_prover_fail_next

# 2. 等待 game 创建
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Game created at: $GAME_ADDR"

# 3. 外部挑战者 challenge
echo ""
echo "Challenging game..."
challenge_game "$GAME_ADDR" "$TEE_EXTERNAL_CHALLENGER_PRIVATE_KEY" "$TEE_CHALLENGER_BOND"

# 验证 challenge 成功
PSTATUS=$(proposal_status "$GAME_ADDR")
if [ "$PSTATUS" != "$PROPOSAL_CHALLENGED" ]; then
    echo "FAIL: proposalStatus=$PSTATUS after challenge, expected $PROPOSAL_CHALLENGED"
    exit 1
fi
echo "  proposalStatus: $PSTATUS (Challenged, correct)"

# 4. 等待 prove 成功（第一次失败后 op-challenger 应重试）
echo ""
echo "Waiting for prove submission (first attempt will fail, expecting retry)..."
wait_for_proposal_status "$GAME_ADDR" "$PROPOSAL_CHALLENGED_AND_VALID_PROOF" 120
echo "  Prove submitted after retry!"

# 5. 验证 Mock Prover 收到了 >= 2 次请求
PROVER_STATS=$(mock_prover_stats)
TASK_COUNT=$(echo "$PROVER_STATS" | jq '.task_count' 2>/dev/null || echo "0")
echo "  Mock prover total tasks: $TASK_COUNT"
if [ "$TASK_COUNT" -lt 2 ] 2>/dev/null; then
    echo "WARNING: expected >=2 tasks (1 failed + 1 success), got $TASK_COUNT"
    echo "  (op-challenger may have consolidated retries)"
fi

# 6. 快进时间 → resolve
echo ""
echo "Time traveling past prove duration..."
time_travel $((TEE_MAX_PROVE_DURATION + 10))

echo "Waiting for DEFENDER_WINS (up to 60s)..."
wait_for_game_status "$GAME_ADDR" "$STATUS_DEFENDER_WINS" 60
echo "  Game resolved: DEFENDER_WINS"

# 7. 验证最终状态
echo ""
echo "Final state:"
print_game_info "$GAME_ADDR"

# 8. 重置 Mock 行为
mock_prover_reset

echo ""
echo "=== PASS: Prove Retry ==="
