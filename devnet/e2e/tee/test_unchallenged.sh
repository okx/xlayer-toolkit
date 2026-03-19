#!/bin/bash
# test_unchallenged.sh — 场景 C: 无人挑战 → DEFENDER_WINS by default
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario C: Unchallenged ==="

# 确保 mock prover 行为正常
mock_prover_reset

# 1. 等待 game 创建
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Game created at: $GAME_ADDR"

# 2. 不 challenge，验证初始状态
PSTATUS=$(proposal_status "$GAME_ADDR")
echo "  proposalStatus: $PSTATUS (should be Unchallenged)"
if [ "$PSTATUS" != "$PROPOSAL_UNCHALLENGED" ]; then
    echo "FAIL: initial proposalStatus=$PSTATUS, expected $PROPOSAL_UNCHALLENGED"
    exit 1
fi

# 3. 快进时间超过 MAX_CHALLENGE_DURATION
echo ""
echo "Time traveling past challenge duration..."
time_travel $((TEE_MAX_CHALLENGE_DURATION + 10))

# 4. 等待 op-challenger resolve → DEFENDER_WINS
echo "Waiting for DEFENDER_WINS (up to 60s)..."
wait_for_game_status "$GAME_ADDR" "$STATUS_DEFENDER_WINS" 60
echo "  Game resolved: DEFENDER_WINS"

# 5. 验证最终状态
echo ""
echo "Final state:"
print_game_info "$GAME_ADDR"

echo ""
echo "=== PASS: Unchallenged ==="
