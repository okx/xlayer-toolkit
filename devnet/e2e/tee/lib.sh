#!/bin/bash
# lib.sh — TEE E2E 测试辅助函数库
# 所有测试脚本 source 此文件获取通用函数和常量

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$DEVNET_DIR/.tee.env"
source "$DEVNET_DIR/tee-contracts.env" 2>/dev/null || true

# ====== 常量 ======
STATUS_IN_PROGRESS=0
STATUS_CHALLENGER_WINS=1
STATUS_DEFENDER_WINS=2

PROPOSAL_UNCHALLENGED=0
PROPOSAL_CHALLENGED=1
PROPOSAL_UNCHALLENGED_AND_VALID_PROOF=2
PROPOSAL_CHALLENGED_AND_VALID_PROOF=3
PROPOSAL_RESOLVED=4

# ====== 链上查询 ======

# 获取 factory 中 game 总数
game_count() {
    cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameCount()(uint256)"
}

# 获取指定 index 的 game 信息 (gameType, timestamp, proxy)
game_at_index() {
    local index=$1
    cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameAtIndex(uint256)(uint32,uint64,address)" "$index"
}

# 获取指定 index 的 game 代理地址
game_addr_at_index() {
    local index=$1
    local result
    result=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameAtIndex(uint256)(uint32,uint64,address)" "$index")
    # 第三个返回值是地址
    echo "$result" | tail -1
}

# 获取 game 的 status (0=InProgress, 1=ChallengerWins, 2=DefenderWins)
game_status() {
    local game_addr=$1
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "status()(uint8)"
}

# 获取 game 的 proposalStatus
proposal_status() {
    local game_addr=$1
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "proposalStatus()(uint8)"
}

# 获取 game 的 gameType
game_type() {
    local game_addr=$1
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "gameType()(uint32)"
}

# 获取 game 的 rootClaim
root_claim() {
    local game_addr=$1
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "rootClaim()(bytes32)"
}

# 获取 game 的 extraData
extra_data() {
    local game_addr=$1
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "extraData()(bytes)"
}

# 获取 credit
get_credit() {
    local game_addr=$1
    local recipient=$2
    cast call --rpc-url "$L1_RPC_URL" "$game_addr" "credit(address)(uint256)" "$recipient"
}

# ====== 链上操作 ======

# 挑战一个 game
challenge_game() {
    local game_addr=$1
    local challenger_key=$2
    local bond=$3
    echo "  Challenging game $game_addr..."
    cast send --legacy --rpc-url "$L1_RPC_URL" \
        --private-key "$challenger_key" \
        --value "$bond" \
        "$game_addr" "challenge()" > /dev/null
    echo "  Challenge submitted."
}

# resolve 一个 game
resolve_game() {
    local game_addr=$1
    local caller_key=$2
    echo "  Resolving game $game_addr..."
    cast send --legacy --rpc-url "$L1_RPC_URL" \
        --private-key "$caller_key" \
        "$game_addr" "resolve()" > /dev/null
    echo "  Resolve submitted."
}

# claimCredit
claim_credit() {
    local game_addr=$1
    local recipient=$2
    local caller_key=$3
    cast send --legacy --rpc-url "$L1_RPC_URL" \
        --private-key "$caller_key" \
        "$game_addr" "claimCredit(address)" "$recipient" > /dev/null
}

# ====== 等待 ======

# 等待 game 创建 (factory game count 增加)
# 用法: wait_for_game_created <initial_count> [timeout_seconds]
# 返回: 新的 game count
wait_for_game_created() {
    local initial_count=$1
    local timeout=${2:-180}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(game_count)
        if [ "$count" -gt "$initial_count" ] 2>/dev/null; then
            echo "$count"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "TIMEOUT waiting for game creation (waited ${timeout}s, count still $initial_count)" >&2
    return 1
}

# 等待 game 达到指定 status
# 用法: wait_for_game_status <game_addr> <expected_status> [timeout_seconds]
wait_for_game_status() {
    local game_addr=$1
    local expected=$2
    local timeout=${3:-120}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(game_status "$game_addr")
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    local final_status
    final_status=$(game_status "$game_addr")
    echo "TIMEOUT: game $game_addr status=$final_status, expected=$expected (waited ${timeout}s)" >&2
    return 1
}

# 等待 proposal 达到指定 status
# 用法: wait_for_proposal_status <game_addr> <expected_status> [timeout_seconds]
wait_for_proposal_status() {
    local game_addr=$1
    local expected=$2
    local timeout=${3:-120}
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(proposal_status "$game_addr")
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    local final_status
    final_status=$(proposal_status "$game_addr")
    echo "TIMEOUT: game $game_addr proposalStatus=$final_status, expected=$expected (waited ${timeout}s)" >&2
    return 1
}

# ====== L1 时间控制 ======

# L1 时间快进（仅适用于 dev L1 geth）
time_travel() {
    local seconds=$1
    local hex_seconds
    hex_seconds=$(printf "0x%x" "$seconds")
    echo "  Time traveling ${seconds}s..."
    cast rpc --rpc-url "$L1_RPC_URL" evm_increaseTime "$hex_seconds" > /dev/null
    cast rpc --rpc-url "$L1_RPC_URL" evm_mine > /dev/null
    echo "  Time traveled."
}

# ====== Mock 组件控制 ======

mock_prover_fail_next() {
    curl -s -X POST http://localhost:8690/admin/fail-next > /dev/null
    echo "  Mock prover: next task will fail"
}

mock_prover_never_finish() {
    curl -s -X POST http://localhost:8690/admin/never-finish > /dev/null
    echo "  Mock prover: tasks will never finish"
}

mock_prover_reset() {
    curl -s -X POST http://localhost:8690/admin/reset > /dev/null
    echo "  Mock prover: behavior reset"
}

mock_prover_stats() {
    curl -s http://localhost:8690/admin/stats
}

mock_tz_node_check() {
    curl -s http://localhost:8090/v1/chain/confirmed_block_info
}

# ====== 辅助 ======

# 找到最后一个 TEE game type 的 game
find_latest_tee_game() {
    local count
    count=$(game_count)
    local i=$((count - 1))
    while [ $i -ge 0 ]; do
        local info
        info=$(game_at_index "$i")
        local gtype
        gtype=$(echo "$info" | head -1)
        if [ "$gtype" = "$TEE_GAME_TYPE" ]; then
            game_addr_at_index "$i"
            return 0
        fi
        i=$((i - 1))
    done
    echo "No TEE game found" >&2
    return 1
}

# 打印 game 详情（调试用）
print_game_info() {
    local game_addr=$1
    echo "  Game: $game_addr"
    echo "  Type: $(game_type "$game_addr")"
    echo "  Status: $(game_status "$game_addr")"
    echo "  Proposal Status: $(proposal_status "$game_addr")"
    echo "  Root Claim: $(root_claim "$game_addr")"
}
