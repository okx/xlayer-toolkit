#!/bin/bash
# tee-game-status.sh — 查询所有 TEE Dispute Game 的状态
#
# 过滤用法:
#   FILTER=progress  bash scripts/tee-game-status.sh   # 只看 IN_PROGRESS
#   FILTER=defender  bash scripts/tee-game-status.sh   # 只看 DEFENDER_WINS
#   FILTER=challenger bash scripts/tee-game-status.sh  # 只看 CHALLENGER_WINS
#   FILTER=resolved  bash scripts/tee-game-status.sh   # 只看已 resolve 的 (DEFENDER_WINS + CHALLENGER_WINS)
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 保存命令行传入的环境变量（优先级高于 .tee.env）
_CLI_FACTORY=${DISPUTE_GAME_FACTORY_ADDRESS:-}
_CLI_RPC=${L1_RPC_URL:-}
_CLI_GAME_TYPE=${TEE_GAME_TYPE:-}
_CLI_REGISTRY=${ANCHOR_STATE_REGISTRY_ADDRESS:-}

[ -f "$DEVNET_DIR/.tee.env" ] && source "$DEVNET_DIR/.tee.env"

# 命令行参数覆盖 .tee.env
[ -n "$_CLI_FACTORY" ] && DISPUTE_GAME_FACTORY_ADDRESS="$_CLI_FACTORY"
[ -n "$_CLI_RPC" ] && L1_RPC_URL="$_CLI_RPC"
[ -n "$_CLI_GAME_TYPE" ] && TEE_GAME_TYPE="$_CLI_GAME_TYPE"
[ -n "$_CLI_REGISTRY" ] && ANCHOR_STATE_REGISTRY_ADDRESS="$_CLI_REGISTRY"

TEE_GAME_TYPE=${TEE_GAME_TYPE:-1960}
L1_RPC=${L1_RPC_URL:-http://localhost:8545}
FILTER=$(echo "${FILTER:-}" | tr '[:upper:]' '[:lower:]')

# 状态过滤: 返回 0 表示显示，1 表示跳过
should_show() {
    local status=$1
    case "$FILTER" in
        progress)   [ "$status" = "0" ] ;;
        challenger) [ "$status" = "1" ] ;;
        defender)   [ "$status" = "2" ] ;;
        resolved)   [ "$status" = "1" ] || [ "$status" = "2" ] ;;
        *)          true ;;
    esac
}

# 状态映射
game_status_name() {
    case $1 in
        0) echo "IN_PROGRESS" ;;
        1) echo "CHALLENGER_WINS" ;;
        2) echo "DEFENDER_WINS" ;;
        *) echo "UNKNOWN($1)" ;;
    esac
}

proposal_status_name() {
    case $1 in
        0) echo "Unchallenged" ;;
        1) echo "Challenged" ;;
        2) echo "Unchallenged+Proven" ;;
        3) echo "Challenged+Proven" ;;
        4) echo "Resolved" ;;
        *) echo "UNKNOWN($1)" ;;
    esac
}

# 获取 game count
TOTAL=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" | awk '{print $1}')
echo "Factory: $DISPUTE_GAME_FACTORY_ADDRESS"
echo "Total games in factory: $TOTAL"
echo ""

TEE_COUNT=0
SHOWN_COUNT=0

for (( i=0; i<TOTAL; i++ )); do
    INFO=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameAtIndex(uint256)(uint32,uint64,address)" "$i" 2>/dev/null) || continue

    GTYPE=$(echo "$INFO" | sed -n '1p' | awk '{print $1}')
    TIMESTAMP=$(echo "$INFO" | sed -n '2p' | awk '{print $1}')
    PROXY=$(echo "$INFO" | sed -n '3p')

    if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
        continue
    fi

    TEE_COUNT=$((TEE_COUNT + 1))

    # 查 game status
    STATUS=$(cast call --rpc-url "$L1_RPC" "$PROXY" "status()(uint8)" 2>/dev/null | awk '{print $1}')
    [ -z "$STATUS" ] && STATUS="?"
    STATUS_NAME=$(game_status_name "$STATUS")

    # 过滤
    if ! should_show "$STATUS"; then
        TEE_COUNT=$((TEE_COUNT + 1))
        continue
    fi
    SHOWN_COUNT=$((SHOWN_COUNT + 1))

    # 查 claimData → proposalStatus (第5个字段)
    CLAIM_DATA=$(cast call --rpc-url "$L1_RPC" "$PROXY" \
        "claimData()(uint32,address,address,bytes32,uint8,uint64)" 2>/dev/null || echo "")
    PARENT_INDEX=$(echo "$CLAIM_DATA" | sed -n '1p' | awk '{print $1}')
    PROVER=$(echo "$CLAIM_DATA" | sed -n '3p')
    ROOT_CLAIM=$(echo "$CLAIM_DATA" | sed -n '4p')
    PSTATUS=$(echo "$CLAIM_DATA" | sed -n '5p' | awk '{print $1}')
    DEADLINE=$(echo "$CLAIM_DATA" | sed -n '6p' | awk '{print $1}')
    PSTATUS_NAME=$(proposal_status_name "$PSTATUS")

    # 查 startingBlockNumber (start 高度) 和 l2SequenceNumber (end 高度)
    START_BLK=$(cast call --rpc-url "$L1_RPC" "$PROXY" "startingBlockNumber()(uint256)" 2>/dev/null | awk '{print $1}')
    [ -z "$START_BLK" ] && START_BLK="?"
    L2SEQ=$(cast call --rpc-url "$L1_RPC" "$PROXY" "l2SequenceNumber()(uint256)" 2>/dev/null | awk '{print $1}')
    [ -z "$L2SEQ" ] && L2SEQ="?"

    # 查 startingRootHash
    START_ROOT=$(cast call --rpc-url "$L1_RPC" "$PROXY" "startingRootHash()(bytes32)" 2>/dev/null || echo "?")

    # 查 blockHash / stateHash
    BLK_HASH=$(cast call --rpc-url "$L1_RPC" "$PROXY" "blockHash()(bytes32)" 2>/dev/null || echo "?")
    ST_HASH=$(cast call --rpc-url "$L1_RPC" "$PROXY" "stateHash()(bytes32)" 2>/dev/null || echo "?")

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Game #$i  |  $PROXY"
    echo "  status:          $STATUS ($STATUS_NAME)"
    echo "  proposalStatus:  $PSTATUS ($PSTATUS_NAME)"
    echo "  parentIndex:     $PARENT_INDEX"
    echo "  startHeight:     $START_BLK"
    echo "  endHeight:       $L2SEQ"
    echo "  startingRoot:    $START_ROOT"
    echo "  rootClaim:       $ROOT_CLAIM"
    echo "  blockHash:       $BLK_HASH"
    echo "  stateHash:       $ST_HASH"
    echo "  prover:          $PROVER"
    echo "  deadline:        $DEADLINE"
    echo "  created:         $TIMESTAMP"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "$FILTER" ]; then
    echo "TEE games (type $TEE_GAME_TYPE): showing $SHOWN_COUNT ($FILTER) / $TEE_COUNT total"
else
    echo "TEE games (type $TEE_GAME_TYPE): $TEE_COUNT / $TOTAL total"
fi

# 查 anchor state
ANCHOR=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" \
    "gameImpls(uint32)(address)" "$TEE_GAME_TYPE" 2>/dev/null || echo "?")
echo "TEE game impl:     $ANCHOR"

# 查 AnchorStateRegistry 中的 anchor
if [ -n "$ANCHOR_STATE_REGISTRY_ADDRESS" ] && [ "$ANCHOR_STATE_REGISTRY_ADDRESS" != "0x0000000000000000000000000000000000000000" ]; then
    ANCHOR_DATA=$(cast call --rpc-url "$L1_RPC" "$ANCHOR_STATE_REGISTRY_ADDRESS" \
        "anchors(uint32)(bytes32,uint256)" "$TEE_GAME_TYPE" 2>/dev/null || echo "")
    ANCHOR_ROOT=$(echo "$ANCHOR_DATA" | sed -n '1p')
    ANCHOR_L2=$(echo "$ANCHOR_DATA" | sed -n '2p')
    echo "Anchor root:       $ANCHOR_ROOT"
    echo "Anchor l2BlockNum: $ANCHOR_L2"
fi
