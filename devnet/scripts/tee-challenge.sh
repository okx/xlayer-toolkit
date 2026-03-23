#!/bin/bash
# tee-challenge.sh — 对 TEE Dispute Game 发起挑战
#
# 用法:
#   bash scripts/tee-challenge.sh <game_address>           # 挑战指定 game
#   bash scripts/tee-challenge.sh latest                   # 挑战最新的 IN_PROGRESS game
#   bash scripts/tee-challenge.sh all                      # 挑战所有 Unchallenged 的 game
#
# 环境变量:
#   CHALLENGER_PRIVATE_KEY   挑战者私钥（必须在 AccessManager 白名单中）
#   L1_RPC_URL               L1 RPC 地址
#   DISPUTE_GAME_FACTORY_ADDRESS  factory 合约地址
#   TEE_GAME_TYPE            game type（默认 1960）
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 保存命令行传入的环境变量（优先级高于 .tee.env）
_CLI_FACTORY=${DISPUTE_GAME_FACTORY_ADDRESS:-}
_CLI_RPC=${L1_RPC_URL:-}
_CLI_GAME_TYPE=${TEE_GAME_TYPE:-}
_CLI_KEY=${CHALLENGER_PRIVATE_KEY:-}

[ -f "$DEVNET_DIR/.tee.env" ] && source "$DEVNET_DIR/.tee.env"

# 命令行参数覆盖 .tee.env
[ -n "$_CLI_FACTORY" ] && DISPUTE_GAME_FACTORY_ADDRESS="$_CLI_FACTORY"
[ -n "$_CLI_RPC" ] && L1_RPC_URL="$_CLI_RPC"
[ -n "$_CLI_GAME_TYPE" ] && TEE_GAME_TYPE="$_CLI_GAME_TYPE"
[ -n "$_CLI_KEY" ] && CHALLENGER_PRIVATE_KEY="$_CLI_KEY"

TEE_GAME_TYPE=${TEE_GAME_TYPE:-1960}
L1_RPC=${L1_RPC_URL:-http://localhost:8545}

if [ -z "$CHALLENGER_PRIVATE_KEY" ]; then
    echo "ERROR: CHALLENGER_PRIVATE_KEY is required"
    echo "  export CHALLENGER_PRIVATE_KEY=0x..."
    exit 1
fi

if [ -z "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
    echo "ERROR: DISPUTE_GAME_FACTORY_ADDRESS is required"
    exit 1
fi

# 挑战单个 game
challenge_game() {
    local PROXY=$1

    # 查询 game status
    STATUS=$(cast call --rpc-url "$L1_RPC" "$PROXY" "status()(uint8)" 2>/dev/null | awk '{print $1}')
    if [ "$STATUS" != "0" ]; then
        echo "  SKIP: game status=$STATUS (not IN_PROGRESS)"
        return 1
    fi

    # 查询 proposalStatus（claimData 第5个字段）
    CLAIM_DATA=$(cast call --rpc-url "$L1_RPC" "$PROXY" \
        "claimData()(uint32,address,address,bytes32,uint8,uint64)" 2>/dev/null || echo "")
    PSTATUS=$(echo "$CLAIM_DATA" | sed -n '5p' | awk '{print $1}')
    if [ "$PSTATUS" != "0" ]; then
        echo "  SKIP: proposalStatus=$PSTATUS (not Unchallenged)"
        return 1
    fi

    # 查询 challengerBond
    BOND=$(cast call --rpc-url "$L1_RPC" "$PROXY" "challengerBond()(uint256)" 2>/dev/null | awk '{print $1}')
    if [ -z "$BOND" ] || [ "$BOND" = "0" ]; then
        echo "  ERROR: cannot read challengerBond"
        return 1
    fi
    BOND_ETH=$(cast from-wei "$BOND" 2>/dev/null || echo "$BOND wei")
    echo "  challengerBond: $BOND_ETH ETH ($BOND wei)"

    # 发起挑战
    echo "  Sending challenge() tx..."
    TX_HASH=$(cast send --rpc-url "$L1_RPC" \
        --private-key "$CHALLENGER_PRIVATE_KEY" \
        --value "$BOND" \
        "$PROXY" "challenge()" 2>&1)

    if echo "$TX_HASH" | grep -q "transactionHash"; then
        HASH=$(echo "$TX_HASH" | grep "transactionHash" | awk '{print $2}')
        echo "  SUCCESS: tx=$HASH"
    else
        echo "  TX output: $TX_HASH"
    fi

    # 验证状态变化
    NEW_CLAIM=$(cast call --rpc-url "$L1_RPC" "$PROXY" \
        "claimData()(uint32,address,address,bytes32,uint8,uint64)" 2>/dev/null || echo "")
    NEW_PSTATUS=$(echo "$NEW_CLAIM" | sed -n '5p' | awk '{print $1}')
    if [ "$NEW_PSTATUS" = "1" ]; then
        echo "  VERIFIED: proposalStatus → Challenged"
    else
        echo "  WARNING: proposalStatus=$NEW_PSTATUS (expected 1=Challenged)"
    fi
}

# 查找最新的 IN_PROGRESS TEE game
find_latest_game() {
    TOTAL=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" | awk '{print $1}')
    if [ "$TOTAL" = "0" ]; then
        echo ""
        return
    fi

    for (( i=TOTAL-1; i>=0; i-- )); do
        INFO=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "gameAtIndex(uint256)(uint32,uint64,address)" "$i" 2>/dev/null) || continue
        GTYPE=$(echo "$INFO" | sed -n '1p' | awk '{print $1}')
        PROXY=$(echo "$INFO" | sed -n '3p')

        if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
            continue
        fi

        STATUS=$(cast call --rpc-url "$L1_RPC" "$PROXY" "status()(uint8)" 2>/dev/null | awk '{print $1}')
        if [ "$STATUS" = "0" ]; then
            echo "$PROXY"
            return
        fi
    done
    echo ""
}

# 查找所有 Unchallenged 的 TEE game
find_unchallenged_games() {
    TOTAL=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" | awk '{print $1}')
    local GAMES=()

    for (( i=0; i<TOTAL; i++ )); do
        INFO=$(cast call --rpc-url "$L1_RPC" "$DISPUTE_GAME_FACTORY_ADDRESS" \
            "gameAtIndex(uint256)(uint32,uint64,address)" "$i" 2>/dev/null) || continue
        GTYPE=$(echo "$INFO" | sed -n '1p' | awk '{print $1}')
        PROXY=$(echo "$INFO" | sed -n '3p')

        if [ "$GTYPE" != "$TEE_GAME_TYPE" ]; then
            continue
        fi

        STATUS=$(cast call --rpc-url "$L1_RPC" "$PROXY" "status()(uint8)" 2>/dev/null | awk '{print $1}')
        if [ "$STATUS" != "0" ]; then
            continue
        fi

        CLAIM_DATA=$(cast call --rpc-url "$L1_RPC" "$PROXY" \
            "claimData()(uint32,address,address,bytes32,uint8,uint64)" 2>/dev/null || echo "")
        PSTATUS=$(echo "$CLAIM_DATA" | sed -n '5p' | awk '{print $1}')
        if [ "$PSTATUS" = "0" ]; then
            GAMES+=("$PROXY")
        fi
    done

    echo "${GAMES[@]}"
}

# ─── 主逻辑 ───

TARGET=${1:-}

if [ -z "$TARGET" ]; then
    echo "Usage: bash scripts/tee-challenge.sh <game_address|latest|all>"
    exit 1
fi

CHALLENGER_ADDR=$(cast wallet address --private-key "$CHALLENGER_PRIVATE_KEY" 2>/dev/null)
echo "Challenger: $CHALLENGER_ADDR"
echo "Factory:    $DISPUTE_GAME_FACTORY_ADDRESS"
echo "L1 RPC:     $L1_RPC"
echo ""

if [ "$TARGET" = "latest" ]; then
    echo "Finding latest IN_PROGRESS TEE game..."
    GAME=$(find_latest_game)
    if [ -z "$GAME" ]; then
        echo "No IN_PROGRESS TEE game found"
        exit 0
    fi
    echo "Found: $GAME"
    challenge_game "$GAME"

elif [ "$TARGET" = "all" ]; then
    echo "Finding all Unchallenged TEE games..."
    GAMES=$(find_unchallenged_games)
    if [ -z "$GAMES" ]; then
        echo "No Unchallenged TEE games found"
        exit 0
    fi
    COUNT=0
    for GAME in $GAMES; do
        COUNT=$((COUNT + 1))
        echo ""
        echo "━━━ Game $COUNT: $GAME ━━━"
        challenge_game "$GAME" || true
    done
    echo ""
    echo "Challenged $COUNT games"

else
    # 直接指定 game 地址
    echo "Challenging game: $TARGET"
    challenge_game "$TARGET"
fi
