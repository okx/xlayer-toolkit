#!/bin/bash
# test_prove_timeout.sh — 场景 B: Prove 超时 → CHALLENGER_WINS → proposer 自动恢复
#
# 测试流程:
#   1. mock prover 设为永不完成
#   2. 等 proposer 创建 game，外部挑战者 challenge
#   3. prove 超时 → CHALLENGER_WINS
#   4. 期间 proposer 可能创建 child game 被级联 CHALLENGER_WINS（正常行为）
#   5. 重置 mock prover，等待所有级联 game 被 resolve
#   6. proposer 自动恢复，创建新 game 以正确 parent
#   7. 验证新 game 能被正常 defend → DEFENDER_WINS
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario B: Prove Timeout + Proposer Recovery ==="

# 1. 控制 Mock Prover 永不完成
mock_prover_never_finish

# 2. 等待 game 创建
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Target game created at: $GAME_ADDR (index $GAME_INDEX)"

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

# 4. 等待 prove deadline 过期
echo ""
echo "Time traveling past prove duration..."
time_travel $((TEE_MAX_PROVE_DURATION + 10))

# 5. 等待 resolve → CHALLENGER_WINS
echo "Waiting for CHALLENGER_WINS (up to 60s)..."
wait_for_game_status "$GAME_ADDR" "$STATUS_CHALLENGER_WINS" 60
echo "  Game resolved: CHALLENGER_WINS"

# 6. 重置 Mock Prover
echo ""
echo "Resetting mock prover to normal behavior..."
mock_prover_reset

# 7. 等待所有级联 game 被 challenger resolve
#    proposer 在 prove timeout 期间可能创建了 child game，它们的 parent 链指向
#    已 CHALLENGER_WINS 的 game。challenger 需要时间逐个 resolve 这些级联 game。
#    只有当所有 IN_PROGRESS 的 TEE game 都被清理后，proposer 创建的新 game
#    才能找到真正干净的 parent（已 DEFENDER_WINS 的 game）。
echo ""
echo "Waiting for cascaded games to be resolved..."
MAX_CASCADE_WAIT=300
CASCADE_ELAPSED=0
while [ $CASCADE_ELAPSED -lt $MAX_CASCADE_WAIT ]; do
    CURRENT_COUNT=$(game_count)
    ALL_RESOLVED=true
    CASCADE_COUNT=0
    PENDING_COUNT=0
    for (( i=GAME_INDEX+1; i<CURRENT_COUNT; i++ )); do
        INFO=$(game_at_index "$i")
        GTYPE=$(echo "$INFO" | head -1)
        if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
            continue
        fi
        ADDR=$(game_addr_at_index "$i")
        S=$(game_status "$ADDR")
        if [ "$S" = "$STATUS_IN_PROGRESS" ]; then
            ALL_RESOLVED=false
            PENDING_COUNT=$((PENDING_COUNT + 1))
        elif [ "$S" = "$STATUS_CHALLENGER_WINS" ]; then
            CASCADE_COUNT=$((CASCADE_COUNT + 1))
        fi
    done

    if $ALL_RESOLVED; then
        break
    fi

    echo "  Waiting... ($PENDING_COUNT games still IN_PROGRESS, $CASCADE_COUNT cascaded)"
    sleep 10
    CASCADE_ELAPSED=$((CASCADE_ELAPSED + 10))
done
echo "  Cascaded CHALLENGER_WINS games: $CASCADE_COUNT"
if [ "$PENDING_COUNT" -gt 0 ] 2>/dev/null; then
    echo "  WARNING: $PENDING_COUNT games still IN_PROGRESS after ${MAX_CASCADE_WAIT}s"
fi

# 8. 等待 proposer 自动恢复，创建新的 game
#    现在所有级联 game 已 resolve，FindLastGameIndex 会跳过 CHALLENGER_WINS，
#    找到之前的 DEFENDER_WINS game 作为 parent。
echo ""
echo "Waiting for proposer to recover and create new game..."
RECOVERY_COUNT=$(game_count)
NEW_RECOVERY_COUNT=$(wait_for_game_created "$RECOVERY_COUNT" 180)
RECOVERY_INDEX=$((NEW_RECOVERY_COUNT - 1))
RECOVERY_ADDR=$(game_addr_at_index "$RECOVERY_INDEX")
echo "Recovery game created at: $RECOVERY_ADDR (index $RECOVERY_INDEX)"
print_game_info "$RECOVERY_ADDR"

# 9. 挑战新 game → challenger prove → DEFENDER_WINS（验证完整恢复）
echo ""
echo "Challenging recovery game to verify full recovery..."
challenge_game "$RECOVERY_ADDR" "$TEE_EXTERNAL_CHALLENGER_PRIVATE_KEY" "$TEE_CHALLENGER_BOND"

PSTATUS=$(proposal_status "$RECOVERY_ADDR")
if [ "$PSTATUS" != "$PROPOSAL_CHALLENGED" ]; then
    echo "FAIL: recovery game proposalStatus=$PSTATUS, expected $PROPOSAL_CHALLENGED"
    exit 1
fi

echo "Waiting for prove submission on recovery game (up to 120s)..."
wait_for_proposal_status "$RECOVERY_ADDR" "$PROPOSAL_CHALLENGED_AND_VALID_PROOF" 120
echo "  Prove submitted on recovery game!"

echo ""
echo "Time traveling past prove duration..."
time_travel $((TEE_MAX_PROVE_DURATION + 10))

echo "Waiting for recovery game DEFENDER_WINS (up to 60s)..."
wait_for_game_status "$RECOVERY_ADDR" "$STATUS_DEFENDER_WINS" 60
echo "  Recovery game resolved: DEFENDER_WINS"

# 10. 最终验证
echo ""
echo "Final state:"
echo "  Original game (timeout):"
echo "    $GAME_ADDR → status=$(game_status "$GAME_ADDR") (CHALLENGER_WINS)"
echo "  Recovery game:"
echo "    $RECOVERY_ADDR → status=$(game_status "$RECOVERY_ADDR") (DEFENDER_WINS)"
echo "  Cascaded games: $CASCADE_COUNT"

echo ""
echo "=== PASS: Prove Timeout + Proposer Recovery ==="
