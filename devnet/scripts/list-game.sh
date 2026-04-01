#!/bin/bash
# Dispute Game List Tool
# List dispute games by game type
#
# Usage:
#   ./list-game.sh [game_type] [start_index end_index]
#
# Examples:
#   ./list-game.sh              # Prompt for game type, show all games
#   ./list-game.sh 42           # List all games of type 42
#   ./list-game.sh 1960         # List all games of type 1960
#   ./list-game.sh 42 10 20     # List type 42 games from index 10 to 20

set -e

# ════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
[ -f "$DEVNET_DIR/.env" ] && source "$DEVNET_DIR/.env"

# Network configuration
FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-""}
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
L2_RPC=${L2_RPC_URL:-"http://localhost:8123"}

# Constants
GENESIS_PARENT_INDEX=4294967295

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Maps indexed by game index, populated during list_games pass 1
declare -A BLOCK_BY_INDEX   # index -> l2BlockNumber
declare -A ADDR_BY_INDEX    # index -> contract address
declare -A TYPE_BY_INDEX    # index -> game type

# ════════════════════════════════════════════════════════════════
# Requirement Checking
# ════════════════════════════════════════════════════════════════

check_basic_requirements() {
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
        exit 1
    fi

    if [ -z "$FACTORY_ADDRESS" ]; then
        echo -e "${RED}Error: DISPUTE_GAME_FACTORY_ADDRESS not set in $DEVNET_DIR/.env${NC}"
        exit 1
    fi
}

# ════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════

# Format unix timestamp to human-readable date (cross-platform)
format_ts() {
    local ts=$1
    [ -z "$ts" ] || [ "$ts" = "0" ] && echo "-" && return
    date -r "$ts" "+%m-%d %H:%M" 2>/dev/null || \
    date -d "@$ts" "+%m-%d %H:%M" 2>/dev/null || \
    echo "$ts"
}

# Fetch claimData(), createdAt(), resolvedAt() in one JSON-RPC batch (requires jq).
# Falls back to sequential cast calls if jq is unavailable.
# Returns: "status_text|deadline_ts|created_ts|resolved_ts"
get_game_data() {
    local addr=$1
    local claim_hex created_hex resolved_hex

    if command -v jq &> /dev/null; then
        # ── JSON-RPC batch: one HTTP round-trip for all 3 calls ──────
        local sig_claim=$(cast sig "claimData()")
        local sig_created=$(cast sig "createdAt()")
        local sig_resolved=$(cast sig "resolvedAt()")
        local body
        printf -v body \
            '[{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]},{"jsonrpc":"2.0","id":2,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]},{"jsonrpc":"2.0","id":3,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}]' \
            "$addr" "$sig_claim" "$addr" "$sig_created" "$addr" "$sig_resolved"
        local resp
        resp=$(curl -s -X POST -H "Content-Type: application/json" --data "$body" "$L1_RPC")
        claim_hex=$(echo "$resp" | jq -r '.[] | select(.id==1) | .result // ""')
        created_hex=$(echo "$resp" | jq -r '.[] | select(.id==2) | .result // ""')
        resolved_hex=$(echo "$resp" | jq -r '.[] | select(.id==3) | .result // ""')
    else
        # ── Fallback: sequential cast calls ─────────────────────────
        claim_hex=$(cast call "$addr" "claimData()"   --rpc-url "$L1_RPC" 2>/dev/null)
        created_hex=$(cast call "$addr" "createdAt()"  --rpc-url "$L1_RPC" 2>/dev/null)
        resolved_hex=$(cast call "$addr" "resolvedAt()" --rpc-url "$L1_RPC" 2>/dev/null)
    fi

    # Parse claimData struct (each field occupies one 32-byte ABI word; 0x prefix = 2 chars):
    #   slot 4 (status,   uint8 ) : chars 259-322
    #   slot 5 (deadline, uint64) : chars 323-386
    local status_hex="0x$(echo "$claim_hex"   | cut -c259-322)"
    local deadline_hex="0x$(echo "$claim_hex" | cut -c323-386)"
    local status=$(cast --to-dec "$status_hex"   2>/dev/null || echo "0")
    local deadline=$(cast --to-dec "$deadline_hex" 2>/dev/null || echo "0")

    # createdAt / resolvedAt are uint64 ABI-encoded into 32-byte words
    local created_ts=$(cast --to-dec "$created_hex"  2>/dev/null || echo "0")
    local resolved_ts=$(cast --to-dec "$resolved_hex" 2>/dev/null || echo "0")

    local status_text
    case $status in
        0) status_text="Unchallenged" ;;
        1) status_text="Challenged" ;;
        2) status_text="Unchal+Proof" ;;
        3) status_text="Chal+Proof" ;;
        4) status_text="Resolved" ;;
        *) status_text="Unknown($status)" ;;
    esac

    echo "$status_text|$deadline|$created_ts|$resolved_ts"
}

# ════════════════════════════════════════════════════════════════
# Display Functions
# ════════════════════════════════════════════════════════════════

show_header() {
    local game_type=$1
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Dispute Game List Tool${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Factory:${NC} ${FACTORY_ADDRESS:0:10}...${FACTORY_ADDRESS: -8}"
    echo -e "  ${BOLD}L1 RPC:${NC}  $L1_RPC"
    echo -e "  ${BOLD}L2 RPC:${NC}  $L2_RPC"
    echo -e "  ${BOLD}Game Type:${NC} ${game_type:-All}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
# Core Functions
# ════════════════════════════════════════════════════════════════

list_games() {
    local game_type=$1
    local filter_start=$2
    local filter_end=$3

    local total=$(cast call $FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null)

    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo -e "${YELLOW}No games found.${NC}"
        return 1
    fi

    local type_label="${game_type:-All Types}"
    if [ -n "$filter_start" ]; then
        echo -e "${BLUE}${BOLD}  Games (Type $type_label) [Showing index $filter_start-$filter_end]${NC}"
    else
        echo -e "${BLUE}${BOLD}  Games (Type $type_label)${NC}"
    fi
    echo -e "${CYAN}Total games in factory: $total${NC}"
    echo ""

    # Table header
    printf "${BOLD}%-6s %-8s %-12s %-22s %-7s %-14s %-13s %-13s %-13s${NC}\n" \
        "Index" "Type" "Parent" "Block Range" "Blocks" "Status" "CreatedAt" "Deadline" "ResolvedAt"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    BLOCK_BY_INDEX=()
    local count=0

    # Single reverse pass: newest game first, print immediately
    for ((i=total-1; i>=0; i--)); do
        local factory_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $i --rpc-url $L1_RPC 2>/dev/null)
        [ -z "$factory_data" ] && continue

        local type=$(echo "$factory_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
        [ -n "$game_type" ] && [ "$type" != "$game_type" ] && continue

        local addr=$(echo "$factory_data" | grep -oE '0x[a-fA-F0-9]{40}')
        local l2_block=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$l2_block" ] && l2_block=0
        BLOCK_BY_INDEX[$i]=$l2_block

        if [ -n "$filter_start" ]; then
            [ $i -lt $filter_start ] || [ $i -gt $filter_end ] && continue
        fi

        local parent=$(cast call $addr "parentIndex()(uint32)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$parent" ] && parent=$GENESIS_PARENT_INDEX

        local start blocks parent_display
        if [ "$parent" = "$GENESIS_PARENT_INDEX" ]; then
            start="?"; blocks="?"; parent_display="genesis"
        else
            parent_display="$parent"
            if [ -z "${BLOCK_BY_INDEX[$parent]+x}" ]; then
                # Parent not yet visited (lower index) — fetch its l2Block on demand
                local pd=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $parent --rpc-url $L1_RPC 2>/dev/null)
                local pa=$(echo "$pd" | grep -oE '0x[a-fA-F0-9]{40}')
                local pb=$(cast call $pa "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
                BLOCK_BY_INDEX[$parent]=${pb:-0}
            fi
            start=${BLOCK_BY_INDEX[$parent]}
            blocks=$((l2_block - start))
        fi

        local game_data
        game_data=$(get_game_data "$addr")
        local status_text deadline_ts created_ts resolved_ts
        IFS='|' read -r status_text deadline_ts created_ts resolved_ts <<< "$game_data"
        local created_fmt deadline_fmt resolved_fmt
        created_fmt=$(format_ts "$created_ts")
        deadline_fmt=$(format_ts "$deadline_ts")
        resolved_fmt=$(format_ts "$resolved_ts")

        printf "%-6s %-8s %-12s %-22s %-7s %-14s %-13s %-13s %-13s\n" \
            "$i" "$type" "$parent_display" "$start-$l2_block" "$blocks" \
            "$status_text" "$created_fmt" "$deadline_fmt" "$resolved_fmt"
        count=$((count + 1))
    done

    echo ""
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}No games of type ${game_type:-any} found.${NC}"
        return 1
    fi
    echo -e "${CYAN}Total: $count games${NC}"
    return 0
}

# ════════════════════════════════════════════════════════════════
# Main Entry Point
# ════════════════════════════════════════════════════════════════

check_basic_requirements

# Parse arguments
GAME_TYPE=""
FILTER_START=""
FILTER_END=""

if [ $# -eq 0 ]; then
    # No args: show all game types
    GAME_TYPE=""
elif [ $# -eq 1 ]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Game type must be a number${NC}"
        exit 1
    fi
    GAME_TYPE="$1"
elif [ $# -eq 3 ]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]] || ! [[ "$2" =~ ^[0-9]+$ ]] || ! [[ "$3" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: All arguments must be numbers${NC}"
        exit 1
    fi
    if [ "$2" -gt "$3" ]; then
        echo -e "${RED}Error: Start index must be <= end index${NC}"
        exit 1
    fi
    GAME_TYPE="$1"
    FILTER_START="$2"
    FILTER_END="$3"
else
    echo -e "${RED}Error: Invalid arguments${NC}"
    echo ""
    echo "Usage: $0 [game_type] [start_index end_index]"
    echo ""
    echo "Examples:"
    echo "  $0              # List all games (all types)"
    echo "  $0 42           # List all games of type 42"
    echo "  $0 1960         # List all games of type 1960"
    echo "  $0 42 10 20     # List type 42 games from index 10 to 20"
    echo ""
    exit 1
fi

show_header "$GAME_TYPE"
list_games "$GAME_TYPE" "$FILTER_START" "$FILTER_END"
