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
count_transactions() {
    local start=$1 end=$2 total=0
    for ((block=start; block<=end; block++)); do
        local count=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq '.transactions | length' 2>/dev/null || echo "0")
        total=$((total + count))
    done
    echo "$total"
}

# Analyze transaction types (detailed)
analyze_transactions() {
    local start=$1 end=$2
    local native=0 erc20=0 contract=0 system=0
    
    for ((block=start; block<=end; block++)); do
        local txs=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq -r '.transactions[]?' 2>/dev/null || echo "")
        [ -z "$txs" ] && continue
        
        while IFS= read -r tx; do
            [ -z "$tx" ] && continue
            local tx_data=$(cast tx $tx --rpc-url $L2_RPC --json 2>/dev/null || echo '{}')
            local from=$(echo "$tx_data" | jq -r '.from // "0x0"')
            local input=$(echo "$tx_data" | jq -r '.input // "0x"')
            
            # System transaction
            if [[ "$from" == *"dead"* ]] || [[ "$from" == *"Dead"* ]]; then
                system=$((system + 1))
            # Native transfer
            elif [ "$input" = "0x" ]; then
                native=$((native + 1))
            # ERC20 transfer (0xa9059cbb)
            elif [[ "$input" == 0xa9059cbb* ]]; then
                erc20=$((erc20 + 1))
            # Contract call
            else
                contract=$((contract + 1))
            fi
        done <<< "$txs"
    done
    
    echo "$native,$erc20,$contract,$system"
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

# Get game range from cached data (based on actual on-chain intervals)
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
    
    local start=${GAME_STARTS[$pos]}
    local addr=${GAME_ADDRS[$pos]}
    local end blocks
    local count=${#GAME_INDICES[@]}
    
    # For non-last game: use next game's start block (100% accurate)
    if [ $pos -lt $((count - 1)) ]; then
        end=$((GAME_STARTS[$pos+1] - 1))
        blocks=$((GAME_STARTS[$pos+1] - start))
    # For last game: use previous game's actual interval
    elif [ $count -gt 1 ]; then
        local prev_interval=$((start - GAME_STARTS[$pos-1]))
        end=$((start + prev_interval - 1))
        blocks=$prev_interval
    # Only one game: cannot infer
    else
        end="?"
        blocks="?"
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
    
    if [ "$show_header" = true ]; then
        echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}${BOLD}  OP-Succinct Games (Type $GAME_TYPE)${NC}"
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
    
    for ((i=0; i<total; i++)); do
        local game_data=$(cast call $FACTORY_ADDRESS "gameAtIndex(uint256)((uint32,uint64,address))" $i --rpc-url $L1_RPC 2>/dev/null)
        [ -z "$game_data" ] && continue
        
        local type=$(echo "$game_data" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
        [ "$type" != "$GAME_TYPE" ] && continue
        
        local addr=$(echo "$game_data" | grep -oE '0x[a-fA-F0-9]{40}')
        local start=$(cast call $addr "l2BlockNumber()(uint256)" --rpc-url $L1_RPC 2>/dev/null | awk '{print $1}')
        [ -z "$start" ] && start=0
        
        GAME_INDICES+=("$i")
        GAME_ADDRS+=("$addr")
        GAME_STARTS+=("$start")
    done
    
    local count=${#GAME_INDICES[@]}
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}No OP-Succinct games found.${NC}"
        return 1
    fi
    
    # Table header
    printf "${BOLD}%-6s %-8s %-25s %-10s %-10s %-20s${NC}\n" \
        "Index" "Type" "Block Range" "Blocks" "Txs" "Status"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    
    # Display games
    for ((j=0; j<count; j++)); do
        local idx=${GAME_INDICES[j]}
        local addr=${GAME_ADDRS[j]}
        local start=${GAME_STARTS[j]}
        
        # Calculate end block based on actual on-chain intervals
        local end blocks
        if [ $j -lt $((count - 1)) ]; then
            # Non-last game: use next game's start block (100% accurate)
            end=$((GAME_STARTS[j+1] - 1))
            blocks=$((GAME_STARTS[j+1] - start))
        elif [ $count -gt 1 ]; then
            # Last game: use previous game's actual interval
            local prev_interval=$((start - GAME_STARTS[j-1]))
            end=$((start + prev_interval - 1))
            blocks=$prev_interval
        else
            # Only one game: cannot infer
            end="?"
            blocks="?"
        fi
        
        # Count transactions (skip if range unknown)
        local txs
        if [ "$end" = "?" ]; then
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
    echo -e "${CYAN}OP-Succinct Games: $count${NC}"
    echo ""
    
    return 0
}

analyze_game_quick() {
    local idx=$1
    
    local range_info=$(get_game_range $idx)
    
    if [ -z "$range_info" ]; then
        echo -e "${RED}Error: Game #$idx not found${NC}"
        return 1
    fi
    
    IFS=',' read -r start end blocks addr <<< "$range_info"
    
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Quick Analysis: Game #$idx${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Address:${NC} $addr"
    
    # Handle case where range is unknown (only one game)
    if [ "$end" = "?" ]; then
        echo -e "${BOLD}Block Range:${NC} $start - ? (pending, only one game exists)"
    else
        echo -e "${BOLD}Block Range:${NC} $start - $end ($blocks blocks)"
    fi
    
    # Get status
    local status_info=$(get_game_status $addr)
    local status_text=$(echo "$status_info" | cut -d'|' -f1)
    local status_code=$(echo "$status_info" | cut -d'|' -f2)
    
    echo -e "${BOLD}Status:${NC} $status_text"
    echo ""
    
    # Analyze transactions (skip if range unknown)
    if [ "$end" = "?" ]; then
        echo -e "${YELLOW}⚠️  Cannot analyze transactions: block range unknown (only one game exists)${NC}"
        echo ""
        echo -e "${MAGENTA}💡 Wait for the next game to be created to see complete analysis${NC}"
        echo ""
        return 0
    fi
    
    echo -e "${YELLOW}Analyzing transactions...${NC}"
    local analysis=$(analyze_transactions $start $end)
    IFS=',' read -r native erc20 contract system <<< "$analysis"
    local total=$((native + erc20 + contract))
    
    echo ""
    echo -e "${BOLD}Transaction Breakdown:${NC}"
    echo "────────────────────────────────────────────────────────────────"
    printf "  %-20s ${GREEN}%s${NC}\n" "Native Transfers:" "$native"
    printf "  %-20s ${CYAN}%s${NC}\n" "ERC20 Transfers:" "$erc20"
    printf "  %-20s ${BLUE}%s${NC}\n" "Contract Calls:" "$contract"
    printf "  %-20s ${YELLOW}%s${NC}\n" "System Txs:" "$system"
    printf "  %-20s ${BOLD}%s${NC}\n" "Total User Txs:" "$total"
    echo ""
    
    # Status check
    if [ "$status_code" != "0" ]; then
        echo -e "${YELLOW}⚠️  Game status: $status_text${NC}"
        echo ""
    fi
    
    echo -e "${MAGENTA}💡 For precise cost estimation, use 'Estimate Cost' option${NC}"
    echo ""
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
        echo -e "${CYAN}💡 The quick analysis above can still help you assess:${NC}"
        echo -e "   - Transaction complexity (Native/ERC20/Contract breakdown)"
        echo -e "   - Workload level (Low/Medium/High)"
        echo -e "   - Whether the game is worth challenging"
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
    
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Precise Cost Estimation: Game #$idx${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Block Range:${NC} $start - $end ($blocks blocks)"
    echo -e "  ${BOLD}Batch Size:${NC} $blocks"
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
    local bond_eth=$(echo "scale=4; $bond / 1000000000000000000" | bc)
    
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Challenge Game #$idx${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Address:${NC} $addr"
    
    # Handle case where range is unknown
    if [ "$end" = "?" ]; then
        echo -e "${BOLD}Block Range:${NC} $start - ? (pending)"
    else
        echo -e "${BOLD}Block Range:${NC} $start - $end ($blocks blocks)"
    fi
    
    echo -e "${BOLD}Status:${NC} $status_text"
    echo -e "${BOLD}Required Bond:${NC} $bond_eth ETH"
    echo ""
    
    # Check if already challenged/resolved
    if [ "$status_code" != "0" ]; then
        echo -e "${YELLOW}⚠️  This game has status: $status_text${NC}"
        echo -e "${YELLOW}   It may already be challenged or resolved.${NC}"
        echo ""
    fi
    
    echo -e "${YELLOW}⚠️  WARNING: This will send a transaction with bond deposit!${NC}"
    echo ""
    echo -n "Proceed with challenge? [y/N]: "
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        return 0
    fi
    
    echo ""
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
    
    # Quick analysis
    echo ""
    analyze_game_quick "$idx"
    
    # Run estimator
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
    
    # Quick analysis
    analyze_game_quick "$idx"
    
    # Challenge
    challenge_game "$idx"
}

# ════════════════════════════════════════════════════════════════
# Interactive Mode
# ════════════════════════════════════════════════════════════════

interactive_mode() {
    check_basic_requirements
    
    # Show header
    show_header
    
    # List games
    if ! list_games false; then
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

# Start interactive mode
interactive_mode
