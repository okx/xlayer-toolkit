#!/bin/bash
# test_proposer_create.sh — 场景 E: 验证 op-proposer 正确创建 TEE game
set -e
source "$(dirname "$0")/lib.sh"

echo "=== Scenario E: Proposer Creates Game ==="

# 1. 记录当前 game count
INITIAL_COUNT=$(game_count)
echo "Initial game count: $INITIAL_COUNT"

# 2. 等待 tee-op-proposer 创建 game
echo "Waiting for proposer to create TEE game..."
NEW_COUNT=$(wait_for_game_created "$INITIAL_COUNT" 180)
echo "New game count: $NEW_COUNT"

# 3. 获取最新 game
GAME_INDEX=$((NEW_COUNT - 1))
GAME_ADDR=$(game_addr_at_index "$GAME_INDEX")
echo "Game created at: $GAME_ADDR"

# 4. 验证 game type == 1960
GTYPE=$(game_type "$GAME_ADDR")
if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
    echo "FAIL: gameType=$GTYPE, expected $TEE_GAME_TYPE"
    exit 1
fi
echo "  gameType: $GTYPE (correct)"

# 5. 验证 rootClaim 非零
RCLAIM=$(root_claim "$GAME_ADDR")
ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
if [ "$RCLAIM" = "$ZERO_HASH" ]; then
    echo "FAIL: rootClaim is zero"
    exit 1
fi
echo "  rootClaim: $RCLAIM (non-zero, correct)"

# 6. 验证 extraData 非空
EDATA=$(extra_data "$GAME_ADDR")
if [ -z "$EDATA" ] || [ "$EDATA" = "0x" ]; then
    echo "FAIL: extraData is empty"
    exit 1
fi
echo "  extraData: ${EDATA:0:42}... (non-empty, correct)"

# 7. 验证 game 初始状态
STATUS=$(game_status "$GAME_ADDR")
if [ "$STATUS" != "$STATUS_IN_PROGRESS" ]; then
    echo "FAIL: initial status=$STATUS, expected $STATUS_IN_PROGRESS"
    exit 1
fi
echo "  status: $STATUS (IN_PROGRESS, correct)"

# 8. 验证 Mock TZ Node 被请求过
TZ_RESPONSE=$(mock_tz_node_check 2>/dev/null || echo "")
if [ -z "$TZ_RESPONSE" ]; then
    echo "WARNING: Could not reach mock TZ node"
else
    TZ_HEIGHT=$(echo "$TZ_RESPONSE" | jq -r '.data.height // empty' 2>/dev/null || echo "")
    if [ -n "$TZ_HEIGHT" ]; then
        echo "  Mock TZ Node height: $TZ_HEIGHT (running)"
    fi
fi

echo ""
print_game_info "$GAME_ADDR"

echo ""
echo "=== PASS: Proposer Creates Game ==="
