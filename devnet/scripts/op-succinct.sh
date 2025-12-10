#!/bin/bash
# OP-Succinct Management Tool
# Interactive tool for managing OP-Succinct dispute games
# 
# Features:
#   - List all OP-Succinct games
#   - Analyze transaction breakdown
#   - Estimate precise PROVE cost
#   - Challenge dispute games
# 
# Usage:
#   ./op-succinct.sh
#
# Simply run the script and follow the interactive prompts!

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
L1_BEACON_RPC=${L1_BEACON_RPC:-"http://localhost:3500"}
L2_RPC=${L2_RPC_URL:-"http://localhost:8123"}
L2_NODE_RPC=${L2_NODE_RPC_URL:-"http://localhost:9545"}
CHALLENGER_KEY=${CHALLENGER_PRIVATE_KEY:-""}
GAME_TYPE=42  # OP-Succinct game type

# Constants
# uint32 max value (2^32 - 1) used in contracts to indicate "no parent" for genesis game
GENESIS_PARENT_INDEX=4294967295

# op-succinct directory
OP_SUCCINCT_DIR=${OP_SUCCINCT_LOCAL_DIRECTORY:-"/Users/oker/workspace/xlayer/op-succinct"}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Global arrays for caching game data
declare -a GAME_INDICES
declare -a GAME_ADDRS
declare -a GAME_STARTS
declare -a GAME_PARENTS

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

check_estimator_requirements() {
    local has_error=false
    
    if ! command -v just &> /dev/null; then
        echo -e "${RED}Error: 'just' command not found${NC}"
        echo -e "${YELLOW}Install: cargo install just  ${CYAN}or${NC}  brew install just${NC}"
        has_error=true
    fi
    
    if [ ! -d "$OP_SUCCINCT_DIR" ]; then
        echo -e "${RED}Error: op-succinct directory not found at $OP_SUCCINCT_DIR${NC}"
        echo -e "${YELLOW}Set OP_SUCCINCT_LOCAL_DIRECTORY in $DEVNET_DIR/.env${NC}"
        has_error=true
    elif [ ! -f "$OP_SUCCINCT_DIR/justfile" ]; then
        echo -e "${RED}Error: justfile not found in $OP_SUCCINCT_DIR${NC}"
        has_error=true
    fi
    
    if [ "$has_error" = true ]; then
        return 1
    fi
    return 0
}

check_challenger_key() {
    if [ -z "$CHALLENGER_KEY" ]; then
        echo -e "${RED}Error: CHALLENGER_PRIVATE_KEY not set in $DEVNET_DIR/.env${NC}"
        return 1
    fi
    return 0
}

# ════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════

# Count transactions in block range (fast)
# Range is [start, end) - exclusive end, matching proof logic
count_transactions() {
    local start=$1 end=$2 total=0
    for ((block=start; block<end; block++)); do
        local count=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq '.transactions | length' 2>/dev/null || echo "0")
        total=$((total + count))
    done
    echo "$total"
}

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

# Check if game index is valid
is_valid_game() {
    local idx=$1
    for i in "${GAME_INDICES[@]}"; do
        if [ "$i" = "$idx" ]; then
            return 0
        fi
    done
    return 1
}

# Get game range from cached data (based on proof logic: parent_l2_block to current_l2_block)
get_game_range() {
    local target_idx=$1
    
    local found=false
    local pos=-1
    
    for ((i=0; i<${#GAME_INDICES[@]}; i++)); do
        if [ "${GAME_INDICES[i]}" = "$target_idx" ]; then
            found=true
            pos=$i
            break
        fi
    done
    
    if [ "$found" = false ]; then
        echo ""
        return 1
    fi
    
    local end=${GAME_STARTS[$pos]}  # Current game's l2_block is the END of proof range
    local addr=${GAME_ADDRS[$pos]}
    local parent_idx=${GAME_PARENTS[$pos]}
    local start blocks
    
    # Find parent game's l2_block as START of proof range
    if [ "$parent_idx" = "$GENESIS_PARENT_INDEX" ]; then
        # Genesis game (no parent): cannot determine start from parent
        start="?"
        blocks="?"
    else
        # Find parent in our cache
        local parent_found=false
        for ((j=0; j<${#GAME_INDICES[@]}; j++)); do
            if [ "${GAME_INDICES[j]}" = "$parent_idx" ]; then
                start=${GAME_STARTS[$j]}
                blocks=$((end - start))  # PROPOSAL_INTERVAL_IN_BLOCKS blocks (exclusive end)
                parent_found=true
                break
            fi
        done
        
        if [ "$parent_found" = false ]; then
            # Parent not in cache (shouldn't happen)
            start="?"
            blocks="?"
        fi
    fi
    
    # Return: start,end,blocks,addr
    echo "$start,$end,$blocks,$addr"
}

# ════════════════════════════════════════════════════════════════
# Display Functions
# ════════════════════════════════════════════════════════════════

show_header() {
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  OP-Succinct Management Tool${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Factory:${NC} ${FACTORY_ADDRESS:0:10}...${FACTORY_ADDRESS: -8}"
    echo -e "  ${BOLD}L1 RPC:${NC} $L1_RPC"
    echo -e "  ${BOLD}L2 RPC:${NC} $L2_RPC"
    echo ""
}

show_menu() {
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}What would you like to do?${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} 💰 ${BOLD}Estimate Cost${NC}   - Analyze + calculate precise PROVE cost"
    echo -e "  ${CYAN}2)${NC} ⚔️  ${BOLD}Challenge Game${NC}   - Submit challenge transaction"
    echo ""
    echo -n "Enter your choice [1-2]: "
}

# ════════════════════════════════════════════════════════════════
# Core Functions
# ════════════════════════════════════════════════════════════════

list_games() {
    local show_header=${1:-true}
    local filter_start=$2
    local filter_end=$3
    
    if [ "$show_header" = true ]; then
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if [ -n "$filter_start" ]; then
            echo -e "${BLUE}${BOLD}  OP-Succinct Games (Type $GAME_TYPE) [Showing $filter_start-$filter_end]${NC}"
        else
            echo -e "${BLUE}${BOLD}  OP-Succinct Games (Type $GAME_TYPE)${NC}"
        fi
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
    
    local total=$(cast call $FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null)
    
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo -e "${YELLOW}No games found.${NC}"
        return 1
    fi
    
    if [ "$show_header" = true ]; then
        echo -e "${CYAN}Total Games: $total${NC}"
        echo -e "${YELLOW}Loading OP-Succinct games...${NC}"
        echo ""
    fi
    
    # Clear and collect all OP-Succinct games
    GAME_INDICES=()
    GAME_ADDRS=()
    GAME_STARTS=()
    GAME_PARENTS=()
    
    for ((i=0; i<total; i++)); do
        local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $i --rpc-url $L1_RPC 2>/dev/null)
        [ -z "$game_data" ] && continue
        
        local type=$(echo "$game_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
        [ "$type" != "$GAME_TYPE" ] && continue
        
        local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
        local start=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$start" ] && start=0
        
        # Get parent index directly from contract
        local parent=$(cast call $addr "parentIndex()(uint32)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$parent" ] && parent=$GENESIS_PARENT_INDEX
        
        GAME_INDICES+=("$i")
        GAME_ADDRS+=("$addr")
        GAME_STARTS+=("$start")
        GAME_PARENTS+=("$parent")
    done
    
    local count=${#GAME_INDICES[@]}
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}No OP-Succinct games found.${NC}"
        return 1
    fi
    
    # Count filtered games first
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
    
    # Display game count before table
    if [ -n "$filter_start" ]; then
        echo -e "${CYAN}Showing $filtered_count games (filtered from $count total OP-Succinct games)${NC}"
    else
        echo -e "${CYAN}Total OP-Succinct Games: $count${NC}"
    fi
    echo ""
    
    # Check if filter resulted in no games
    if [ $filtered_count -eq 0 ]; then
        echo -e "${YELLOW}No games found in range $filter_start-$filter_end${NC}"
        return 1
    fi
    
    # Table header
    printf "${BOLD}%-6s %-8s %-25s %-10s %-10s %-20s${NC}\n" \
        "Index" "Type" "Block Range" "Blocks" "Txs" "Status"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    
    # Display games
    for ((j=0; j<count; j++)); do
        local idx=${GAME_INDICES[j]}
        
        # Apply filter if specified
        if [ -n "$filter_start" ]; then
            if [ $idx -lt $filter_start ] || [ $idx -gt $filter_end ]; then
                continue
            fi
        fi
        
        local addr=${GAME_ADDRS[j]}
        local end=${GAME_STARTS[j]}  # Current game's l2_block is the END
        local parent_idx=${GAME_PARENTS[j]}
        
        # Calculate proof range: parent_l2_block to current_l2_block
        local start blocks
        if [ "$parent_idx" = "$GENESIS_PARENT_INDEX" ]; then
            # Genesis game (no parent)
            start="?"
            blocks="?"
        else
            # Find parent's l2_block
            local parent_found=false
            for ((k=0; k<count; k++)); do
                if [ "${GAME_INDICES[k]}" = "$parent_idx" ]; then
                    start=${GAME_STARTS[k]}
                    blocks=$((end - start))  # PROPOSAL_INTERVAL_IN_BLOCKS blocks (exclusive end)
                    parent_found=true
                    break
                fi
            done
            
            if [ "$parent_found" = false ]; then
                start="?"
                blocks="?"
            fi
        fi
        
        # Count transactions (skip if range unknown)
        local txs
        if [ "$start" = "?" ] || [ "$end" = "?" ]; then
            txs="?"
        else
            txs=$(count_transactions $start $end)
        fi
        
        # Get status
        local status_info=$(get_game_status $addr)
        local status_text=$(echo "$status_info" | cut -d'|' -f1)
        
        printf "%-6s %-8s %-25s %-10s %-10s %-20s\n" \
            "$idx" "$GAME_TYPE" "$start-$end" "$blocks" "$txs" "$status_text"
    done
    
    echo ""
    return 0
}

run_estimator_for_game() {
    local idx=$1
    
    # Check requirements
    if ! check_estimator_requirements; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  Precise cost estimation unavailable (missing dependencies)${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${CYAN}💡 The quick analysis above shows:${NC}"
        echo -e "   - Total transaction count"
        echo -e "   - Game status"
        echo ""
        echo -e "${CYAN}To enable precise cost estimation, install:${NC}"
        echo -e "   1. just: ${BOLD}cargo install just${NC} or ${BOLD}brew install just${NC}"
        echo -e "   2. Set ${BOLD}OP_SUCCINCT_LOCAL_DIRECTORY${NC} in .env"
        echo ""
        return 1
    fi
    
    local range_info=$(get_game_range $idx)
    
    if [ -z "$range_info" ]; then
        echo -e "${RED}Error: Game #$idx not found${NC}"
        return 1
    fi
    
    IFS=',' read -r start end blocks addr <<< "$range_info"
    
    # Handle genesis game (unknown range)
    if [ "$start" = "?" ] || [ "$end" = "?" ]; then
        echo ""
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}  Cost Estimation: Game #$idx${NC}"
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "${BOLD}Address:${NC} $addr"
        echo -e "${BOLD}Block Range:${NC} $start - $end (genesis game, no parent)"
        echo -e "${BOLD}Status:${NC} $(get_game_status $addr | cut -d'|' -f1)"
        echo ""
        echo -e "${YELLOW}⚠️  Cannot estimate cost: genesis game has no parent${NC}"
        echo ""
        return 1
    fi
    
    # Get status
    local status_info=$(get_game_status $addr)
    local status_text=$(echo "$status_info" | cut -d'|' -f1)
    
    # Count transactions (silently)
    local txs=$(count_transactions $start $end 2>/dev/null)
    
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Cost Estimation: Game #$idx${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Address:${NC} $addr"
    echo -e "${BOLD}Block Range:${NC} $start - $end ($blocks blocks)"
    echo -e "${BOLD}Status:${NC} $status_text"
    echo -e "${BOLD}Total Transactions:${NC} $txs"
    echo -e "${BOLD}Batch Size:${NC} $blocks"
    echo ""
    echo -e "${YELLOW}⚙️  Building and running cost-estimator...${NC}"
    echo -e "${YELLOW}   This may take 2-5 minutes, please wait...${NC}"
    echo ""
    
    # Export environment variables
    export L1_RPC
    export L1_BEACON_RPC
    export L2_RPC
    export L2_NODE_RPC
    export L1_CONFIG_DIR="$DEVNET_DIR/op-succinct/configs/L1"
    export L2_CONFIG_DIR="$DEVNET_DIR/op-succinct/configs/L2"
    
    # Run in op-succinct directory
    cd "$OP_SUCCINCT_DIR"
    just cost-estimator --start $start --end $end --batch-size $blocks 2>&1 | tee /tmp/cost-estimator-output.txt
    local exit_code=${PIPESTATUS[0]}
    cd - > /dev/null
    
    echo ""
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ Cost estimation completed successfully${NC}"
        
        # Try to extract summary
        if grep -q "Total SP1 gas" /tmp/cost-estimator-output.txt 2>/dev/null; then
            echo ""
            echo -e "${BOLD}Summary:${NC}"
            grep -E "(Total SP1 gas|Average|Range)" /tmp/cost-estimator-output.txt | sed 's/^/  /'
        fi
        
        echo ""
        echo -e "${CYAN}Full output: /tmp/cost-estimator-output.txt${NC}"
    else
        echo -e "${RED}❌ Cost estimation failed (exit code: $exit_code)${NC}"
    fi
    
    echo ""
    return $exit_code
}

challenge_game() {
    local idx=$1
    
    if ! check_challenger_key; then
        echo ""
        return 1
    fi
    
    local range_info=$(get_game_range $idx)
    
    if [ -z "$range_info" ]; then
        echo -e "${RED}Error: Game #$idx not found${NC}"
        return 1
    fi
    
    IFS=',' read -r start end blocks addr <<< "$range_info"
    
    # Get status
    local status_info=$(get_game_status $addr)
    local status_text=$(echo "$status_info" | cut -d'|' -f1)
    local status_code=$(echo "$status_info" | cut -d'|' -f2)
    
    # Get bond
    local bond=$(cast call $addr "challengerBond()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
    [ -z "$bond" ] && bond="1000000000000000"  # Default: 0.001 ETH
    
    # Check if already challenged/resolved
    if [ "$status_code" != "0" ]; then
        echo ""
        echo -e "${YELLOW}⚠️  Game #$idx has status: $status_text${NC}"
        echo -e "${YELLOW}   It may already be challenged or resolved.${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}Sending challenge transaction...${NC}"
    
    # Send challenge transaction
    local result=$(cast send $addr "challenge()" \
        --value $bond \
        --private-key $CHALLENGER_KEY \
        --rpc-url $L1_RPC \
        --timeout 60 \
        --confirmations 1 \
        --json 2>&1)
    local exit_code=$?
    
    # Extract TX hash
    local tx=$(echo "$result" | jq -r '.transactionHash' 2>/dev/null)
    
    # Check if successful
    if [ $exit_code -ne 0 ] || [ -z "$tx" ] || [ "$tx" = "null" ]; then
        echo -e "${RED}❌ Transaction failed${NC}"
        echo -e "${YELLOW}Error: $result${NC}"
        echo ""
        return 1
    fi
    
    echo -e "${GREEN}✅ Challenge submitted successfully!${NC}"
    echo ""
    echo -e "${BOLD}Transaction:${NC} $tx"
    echo ""
    echo -e "${CYAN}💡 Monitor proposer response:${NC}"
    echo -e "   docker logs -f op-succinct-proposer"
    echo ""
}

# ════════════════════════════════════════════════════════════════
# Action Handlers (Interactive Mode)
# ════════════════════════════════════════════════════════════════

handle_estimate() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Cost Estimation${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Get game index
    while true; do
        echo -n "Enter game index: "
        read -r idx
        
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid input. Please enter a number.${NC}"
            continue
        fi
        
        if ! is_valid_game "$idx"; then
            echo -e "${RED}Game #$idx not found. Please check the list above.${NC}"
            continue
        fi
        
        # Valid input, proceed
        break
    done
    
    # Run estimator (it will display all info in one place)
    run_estimator_for_game "$idx"
}

handle_challenge() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Challenge Game${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Get game index
    while true; do
        echo -n "Enter game index: "
        read -r idx
        
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid input. Please enter a number.${NC}"
            continue
        fi
        
        if ! is_valid_game "$idx"; then
            echo -e "${RED}Game #$idx not found. Please check the list above.${NC}"
            continue
        fi
        
        # Valid input, proceed
        break
    done
    
    # Challenge directly (no quick analysis)
    challenge_game "$idx"
}

# ════════════════════════════════════════════════════════════════
# Interactive Mode
# ════════════════════════════════════════════════════════════════

interactive_mode() {
    local filter_start=$1
    local filter_end=$2
    
    check_basic_requirements
    
    # Show header
    show_header
    
    # List games with optional filtering
    if ! list_games false "$filter_start" "$filter_end"; then
        echo ""
        echo -e "${RED}No games available.${NC}"
        exit 1
    fi
    
    # Show menu and get choice
    while true; do
        show_menu
        read -r choice
        
        # Validate choice
        case $choice in
            1)
                handle_estimate
                exit 0
                ;;
            2)
                handle_challenge
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please enter 1 or 2.${NC}"
                ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════
# Main Entry Point
# ════════════════════════════════════════════════════════════════

# Validate arguments
if [ $# -eq 1 ]; then
    echo -e "${RED}Error: Must provide both start and end index, or no arguments${NC}"
    echo ""
    echo "Usage: $0 [start_index end_index]"
    echo ""
    echo "Examples:"
    echo "  $0           # Show all games"
    echo "  $0 10 20     # Show games from index 10 to 20"
    echo ""
    exit 1
fi

if [ $# -eq 2 ]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Arguments must be numbers${NC}"
        exit 1
    fi
    
    if [ $1 -gt $2 ]; then
        echo -e "${RED}Error: Start index must be <= end index${NC}"
        exit 1
    fi
    
    # Start with filter
    interactive_mode "$1" "$2"
elif [ $# -eq 0 ]; then
    # Start without filter
    interactive_mode
else
    echo -e "${RED}Error: Too many arguments${NC}"
    echo "Usage: $0 [start_index end_index]"
    exit 1
fi
