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

# Global arrays for caching game data
declare -a GAME_INDICES
declare -a GAME_ADDRS
declare -a GAME_STARTS
declare -a GAME_PARENTS
declare -a GAME_TYPES

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

# Get game status
get_game_status() {
    local addr=$1
    local claim_hex=$(cast call $addr "claimData()" --rpc-url $L1_RPC 2>/dev/null)
    local status_hex="0x$(echo "$claim_hex" | cut -c259-322)"
    local status=$(cast --to-dec "$status_hex" 2>/dev/null || echo "0")

    case $status in
        0) echo "Unchallenged|0" ;;
        1) echo "Challenged|1" ;;
        2) echo "Unchal+Proof|2" ;;
        3) echo "Chal+Proof|3" ;;
        4) echo "Resolved|4" ;;
        *) echo "Unknown|$status" ;;
    esac
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
    echo -e "${YELLOW}Loading games of type $type_label...${NC}"
    echo ""

    # Clear and collect all matching games
    GAME_INDICES=()
    GAME_ADDRS=()
    GAME_STARTS=()
    GAME_PARENTS=()
    GAME_TYPES=()

    for ((i=0; i<total; i++)); do
        local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $i --rpc-url $L1_RPC 2>/dev/null)
        [ -z "$game_data" ] && continue

        local type=$(echo "$game_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
        [ -n "$game_type" ] && [ "$type" != "$game_type" ] && continue

        local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
        local l2_block=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$l2_block" ] && l2_block=0

        local parent=$(cast call $addr "parentIndex()(uint32)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$parent" ] && parent=$GENESIS_PARENT_INDEX

        GAME_INDICES+=("$i")
        GAME_ADDRS+=("$addr")
        GAME_STARTS+=("$l2_block")
        GAME_PARENTS+=("$parent")
        GAME_TYPES+=("$type")
    done

    local count=${#GAME_INDICES[@]}

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}No games of type ${game_type:-any} found.${NC}"
        return 1
    fi

    # Count filtered games
    local filtered_count=0
    if [ -n "$filter_start" ]; then
        for idx in "${GAME_INDICES[@]}"; do
            if [ $idx -ge $filter_start ] && [ $idx -le $filter_end ]; then
                filtered_count=$((filtered_count + 1))
            fi
        done
    else
        filtered_count=$count
    fi

    if [ -n "$filter_start" ]; then
        echo -e "${CYAN}Showing $filtered_count games (filtered from $count total games of type $type_label)${NC}"
    else
        echo -e "${CYAN}Total games of type $type_label: $count${NC}"
    fi
    echo ""

    if [ $filtered_count -eq 0 ]; then
        echo -e "${YELLOW}No games found in range $filter_start-$filter_end${NC}"
        return 1
    fi

    # Table header
    printf "${BOLD}%-6s %-8s %-12s %-25s %-10s %-20s${NC}\n" \
        "Index" "Type" "Parent" "Block Range" "Blocks" "Status"
    echo "────────────────────────────────────────────────────────────────────────────────────────"

    for ((j=count-1; j>=0; j--)); do
        local idx=${GAME_INDICES[j]}

        # Apply filter if specified
        if [ -n "$filter_start" ]; then
            if [ $idx -lt $filter_start ] || [ $idx -gt $filter_end ]; then
                continue
            fi
        fi

        local addr=${GAME_ADDRS[j]}
        local end=${GAME_STARTS[j]}
        local parent_idx=${GAME_PARENTS[j]}

        # Calculate proof range
        local start blocks parent_display
        if [ "$parent_idx" = "$GENESIS_PARENT_INDEX" ]; then
            start="?"
            blocks="?"
            parent_display="genesis"
        else
            parent_display="$parent_idx"
            local parent_found=false
            for ((k=0; k<count; k++)); do
                if [ "${GAME_INDICES[k]}" = "$parent_idx" ]; then
                    start=${GAME_STARTS[k]}
                    blocks=$((end - start))
                    parent_found=true
                    break
                fi
            done
            if [ "$parent_found" = false ]; then
                start="?"
                blocks="?"
            fi
        fi

        # Get status
        local status_info=$(get_game_status $addr)
        local status_text=$(echo "$status_info" | cut -d'|' -f1)

        printf "%-6s %-8s %-12s %-25s %-10s %-20s\n" \
            "$idx" "${GAME_TYPES[j]}" "$parent_display" "$start-$end" "$blocks" "$status_text"
    done

    echo ""
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
