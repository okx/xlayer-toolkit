#!/bin/bash
# test_prove_timeout.sh — 场景 B: Prove 超时 → CHALLENGER_WINS
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario B: Prove Timeout ==="

# 1. 控制 Mock Prover 永不完成
mock_prover_never_finish

# 2. 等待 game 创建
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Game created at: $GAME_ADDR"

# 2.5 暂停 proposer，防止 sleep 期间创建新 game chain off 当前 game
# 当前 game 最终 CHALLENGER_WINS，如果 proposer 继续创建 child game 会导致级联 CHALLENGER_WINS
echo "Pausing tee-op-proposer to prevent cascading CHALLENGER_WINS..."
docker pause tee-op-proposer

# 3. 外部挑战者 challenge
echo ""
echo "Challenging game..."
challenge_game "$GAME_ADDR" "$TEE_EXTERNAL_CHALLENGER_PRIVATE_KEY" "$TEE_CHALLENGER_BOND"

# 验证 challenge 成功
PSTATUS=$(proposal_status "$GAME_ADDR")
if [ "$PSTATUS" != "$PROPOSAL_CHALLENGED" ]; then
    echo "FAIL: proposalStatus=$PSTATUS after challenge, expected $PROPOSAL_CHALLENGED"
    mock_prover_reset
    exit 1
fi
echo "  proposalStatus: $PSTATUS (Challenged, correct)"

# 4. 快进时间超过 MAX_PROVE_DURATION
echo ""
echo "Time traveling past prove duration..."
time_travel $((TEE_MAX_PROVE_DURATION + 10))

# 5. 等待 resolve → CHALLENGER_WINS
# op-challenger 应检测到 prove deadline 过期并调用 resolve
echo "Waiting for CHALLENGER_WINS (up to 60s)..."
wait_for_game_status "$GAME_ADDR" "$STATUS_CHALLENGER_WINS" 60
echo "  Game resolved: CHALLENGER_WINS"

# 6. 验证最终状态
echo ""
echo "Final state:"
print_game_info "$GAME_ADDR"

# 7. 恢复 proposer
echo "Resuming tee-op-proposer..."
docker unpause tee-op-proposer

# 8. 重置 Mock 行为
mock_prover_reset

echo ""
echo "=== PASS: Prove Timeout ==="
