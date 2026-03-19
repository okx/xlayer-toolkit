#!/bin/bash
# test_defend_success.sh — 场景 A: Happy Path — 被挑战 → prove → DEFENDER_WINS
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario A: Defend Success ==="

# 确保 mock prover 行为正常
mock_prover_reset

# 1. 记录当前 game count
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

# 2. 等待 tee-op-proposer 创建 game
echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Game created at: $GAME_ADDR"
print_game_info "$GAME_ADDR"

# 3. 验证 game type
GTYPE=$(game_type "$GAME_ADDR")
if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
    echo "FAIL: gameType=$GTYPE, expected $TEE_GAME_TYPE"
    exit 1
fi

# 4. 外部挑战者 challenge
echo ""
echo "Challenging game..."
challenge_game "$GAME_ADDR" "$TEE_EXTERNAL_CHALLENGER_PRIVATE_KEY" "$TEE_CHALLENGER_BOND"

# 5. 验证 proposalStatus == Challenged
PSTATUS=$(proposal_status "$GAME_ADDR")
if [ "$PSTATUS" != "$PROPOSAL_CHALLENGED" ]; then
    echo "FAIL: proposalStatus=$PSTATUS after challenge, expected $PROPOSAL_CHALLENGED"
    exit 1
fi
echo "  proposalStatus: $PSTATUS (Challenged, correct)"

# 6. 等待 op-challenger TEE Actor 提交 prove
echo ""
echo "Waiting for prove submission (up to 120s)..."
wait_for_proposal_status "$GAME_ADDR" "$PROPOSAL_CHALLENGED_AND_VALID_PROOF" 120
echo "  Prove submitted! proposalStatus = $PROPOSAL_CHALLENGED_AND_VALID_PROOF"

# 7. 验证 Mock Prover 收到请求
PROVER_STATS=$(mock_prover_stats)
TASK_COUNT=$(echo "$PROVER_STATS" | jq '.task_count' 2>/dev/null || echo "0")
if [ "$TASK_COUNT" -lt 1 ] 2>/dev/null; then
    echo "FAIL: mock prover received 0 tasks"
    exit 1
fi
echo "  Mock prover tasks: $TASK_COUNT"

# 8. 快进时间 → 让 deadline 过期 → op-challenger resolve
echo ""
echo "Time traveling past prove duration..."
time_travel $((TEE_MAX_PROVE_DURATION + 10))

# 9. 等待 resolve → DEFENDER_WINS
echo "Waiting for DEFENDER_WINS (up to 60s)..."
wait_for_game_status "$GAME_ADDR" "$STATUS_DEFENDER_WINS" 60
echo "  Game resolved: DEFENDER_WINS"

# 10. 验证最终状态
echo ""
echo "Final state:"
print_game_info "$GAME_ADDR"

echo ""
echo "=== PASS: Defend Success ==="
