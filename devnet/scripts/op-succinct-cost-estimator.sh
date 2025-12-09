#!/bin/bash
# OP-Succinct Cost Estimator
# Estimate proof cost for dispute games using cost-estimator tool

set -e

# ════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables
[ -f "$DEVNET_DIR/.env" ] && source "$DEVNET_DIR/.env"

# Paths
FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-""}
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
L1_BEACON_RPC=${L1_BEACON_RPC:-"http://localhost:3500"}  # L1 beacon chain (consensus layer)
L2_RPC=${L2_RPC_URL:-"http://localhost:8123"}  # L2 execution layer (op-geth/op-reth)
L2_NODE_RPC=${L2_NODE_RPC_URL:-"http://localhost:9545"}  # L2 consensus layer (op-node)
GAME_TYPE=42  # OP-Succinct game type

# op-succinct directory (read from .env or use default)
OP_SUCCINCT_DIR=${OP_SUCCINCT_LOCAL_DIRECTORY:-"/Users/oker/workspace/xlayer/op-succinct"}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════

check_requirements() {
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
        exit 1
    fi
    
    if [ -z "$FACTORY_ADDRESS" ]; then
        echo -e "${RED}Error: DISPUTE_GAME_FACTORY_ADDRESS not set in $DEVNET_DIR/.env${NC}"
        exit 1
    fi
    
    if ! command -v just &> /dev/null; then
        echo -e "${RED}Error: 'just' command not found${NC}"
        echo ""
        echo -e "${YELLOW}To install just:${NC}"
        echo -e "  cargo install just"
        echo -e "  ${CYAN}or${NC}"
        echo -e "  brew install just  ${CYAN}(macOS)${NC}"
        echo ""
        exit 1
    fi
    
    if [ ! -d "$OP_SUCCINCT_DIR" ]; then
        echo -e "${RED}Error: op-succinct directory not found at $OP_SUCCINCT_DIR${NC}"
        echo ""
        echo -e "${YELLOW}Please set OP_SUCCINCT_LOCAL_DIRECTORY in $DEVNET_DIR/.env${NC}"
        echo -e "  ${CYAN}Example:${NC}"
        echo -e "  OP_SUCCINCT_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/op-succinct"
        echo ""
        exit 1
    fi
    
    if [ ! -f "$OP_SUCCINCT_DIR/justfile" ]; then
        echo -e "${RED}Error: justfile not found in $OP_SUCCINCT_DIR${NC}"
        echo -e "${YELLOW}Make sure $OP_SUCCINCT_DIR points to the op-succinct repository${NC}"
        exit 1
    fi
}

# Count transactions in block range
count_transactions() {
    local start=$1 end=$2 total=0
    for ((block=start; block<=end; block++)); do
        local count=$(cast block $block --rpc-url $L2_RPC --json 2>/dev/null | jq '.transactions | length' 2>/dev/null || echo "0")
        total=$((total + count))
    done
    echo "$total"
}

# ════════════════════════════════════════════════════════════════
# Main Functions
# ════════════════════════════════════════════════════════════════

# List all OP-Succinct games (simplified version)
list_games() {
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  OP-Succinct Games (Type $GAME_TYPE)${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local total=$(cast call $FACTORY_ADDRESS "gameCount()(uint256)" --rpc-url $L1_RPC 2>/dev/null)
    
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        echo -e "${YELLOW}No games found.${NC}"
        return 1
    fi
    
    echo -e "${CYAN}Total Games: $total${NC}"
    echo -e "${YELLOW}Loading game details...${NC}"
    echo ""
    
    # Collect all OP-Succinct games
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
    
    # Calculate average interval
    local total_intervals=0
    local sum_intervals=0
    for ((j=0; j<count-1; j++)); do
        local interval=$((GAME_STARTS[j+1] - GAME_STARTS[j]))
        sum_intervals=$((sum_intervals + interval))
        total_intervals=$((total_intervals + 1))
    done
    local avg_interval=$((sum_intervals / total_intervals))
    [ $avg_interval -eq 0 ] && avg_interval=10
    
    # Store average interval globally
    AVG_INTERVAL=$avg_interval
    
    # Table header
    printf "${BOLD}%-6s %-8s %-25s %-10s %-10s${NC}\n" \
        "Index" "Type" "Block Range" "Blocks" "Txs"
    echo "───────────────────────────────────────────────────────────────"
    
    # Display games
    for ((j=0; j<count; j++)); do
        local idx=${GAME_INDICES[j]}
        local addr=${GAME_ADDRS[j]}
        local start=${GAME_STARTS[j]}
        
        # Infer end block
        local end blocks
        if [ $j -lt $((count - 1)) ]; then
            end=$((GAME_STARTS[j+1] - 1))
            blocks=$((GAME_STARTS[j+1] - start))
        else
            end=$((start + avg_interval - 1))
            blocks=$avg_interval
        fi
        
        local txs=$(count_transactions $start $end)
        
        printf "%-6s %-8s %-25s %-10s %-10s\n" \
            "$idx" "$GAME_TYPE" "$start-$end" "$blocks" "$txs"
    done
    
    echo ""
    echo -e "${CYAN}OP-Succinct Games: $count${NC}"
    echo -e "${CYAN}Avg Interval: $avg_interval blocks (inferred from L1)${NC}"
    echo ""
}

# Get block range for a specific game
get_game_range() {
    local target_idx=$1
    
    # Find the game in our cached arrays
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
    local end blocks
    
    # Calculate end block
    if [ $pos -lt $((${#GAME_INDICES[@]} - 1)) ]; then
        end=$((GAME_STARTS[$pos+1] - 1))
        blocks=$((GAME_STARTS[$pos+1] - start))
    else
        end=$((start + AVG_INTERVAL - 1))
        blocks=$AVG_INTERVAL
    fi
    
    # Return: start,end,blocks
    echo "$start,$end,$blocks"
}

# Run cost estimator
run_estimator() {
    local start=$1
    local end=$2
    local batch_size=${3:-$DEFAULT_BATCH_SIZE}
    
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Running Cost Estimator${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Block Range:${NC} $start - $end"
    echo -e "  ${BOLD}Batch Size:${NC} $batch_size"
    echo -e "  ${BOLD}L1 RPC:${NC} $L1_RPC"
    echo -e "  ${BOLD}L1 Beacon RPC:${NC} $L1_BEACON_RPC"
    echo -e "  ${BOLD}L2 RPC:${NC} $L2_RPC"
    echo -e "  ${BOLD}L2 Node RPC:${NC} $L2_NODE_RPC"
    echo -e "  ${BOLD}Config Dir:${NC} $DEVNET_DIR/op-succinct/configs"
    echo -e "  ${BOLD}Working Dir:${NC} $OP_SUCCINCT_DIR"
    echo ""
    echo -e "${YELLOW}Building and running cost-estimator (release mode)...${NC}"
    echo -e "${YELLOW}This may take a few minutes...${NC}"
    echo ""
    
    # Export environment variables
    export L1_RPC
    export L1_BEACON_RPC
    export L2_RPC
    export L2_NODE_RPC
    
    # Set config directories (use op-succinct configs)
    export L1_CONFIG_DIR="$DEVNET_DIR/op-succinct/configs/L1"
    export L2_CONFIG_DIR="$DEVNET_DIR/op-succinct/configs/L2"
    
    echo -e "${CYAN}Command:${NC} cd $OP_SUCCINCT_DIR && just cost-estimator --start $start --end $end --batch-size $batch_size"
    echo ""
    
    # Run in op-succinct directory using justfile
    cd "$OP_SUCCINCT_DIR"
    just cost-estimator --start $start --end $end --batch-size $batch_size 2>&1 | tee /tmp/cost-estimator-output.txt
    local exit_code=${PIPESTATUS[0]}
    
    echo ""
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ Cost estimation completed successfully${NC}"
    else
        echo -e "${RED}❌ Cost estimation failed (exit code: $exit_code)${NC}"
        return 1
    fi
    
    # Try to extract key information from output
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  Summary${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Extract SP1 gas info if available
    if grep -q "Total SP1 gas" /tmp/cost-estimator-output.txt 2>/dev/null; then
        echo -e "${BOLD}SP1 Gas Statistics:${NC}"
        grep -E "(Total SP1 gas|Average|Range)" /tmp/cost-estimator-output.txt | sed 's/^/  /'
    fi
    
    echo ""
    echo -e "${CYAN}Full output saved to: /tmp/cost-estimator-output.txt${NC}"
    echo ""
}

# Estimate cost for a specific game
estimate_game() {
    local idx=$1
    local batch_size_override=${2:-""}
    
    # Get game range
    local range_info=$(get_game_range $idx)
    
    if [ -z "$range_info" ]; then
        echo -e "${RED}Error: Game #$idx not found${NC}"
        return 1
    fi
    
    IFS=',' read -r start end blocks <<< "$range_info"
    
    # Use game's block count as batch size (or override if specified)
    local batch_size=${batch_size_override:-$blocks}
    
    echo ""
    echo -e "${GREEN}Estimating cost for Game #$idx${NC}"
    echo -e "  ${BOLD}Blocks:${NC} $start - $end ($blocks blocks)"
    echo -e "  ${BOLD}Batch Size:${NC} $batch_size"
    echo ""
    
    # Run estimator
    run_estimator $start $end $batch_size
}

# ════════════════════════════════════════════════════════════════
# Interactive Mode
# ════════════════════════════════════════════════════════════════

interactive_mode() {
    check_requirements
    
    # Show header
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  OP-Succinct Cost Estimator${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # List games
    list_games
    
    # Prompt for game selection
    echo -n "Enter game index (or press ENTER to exit): "
    read -r idx
    
    # Exit if empty
    [ -z "$idx" ] && { echo ""; exit 0; }
    
    # Estimate (batch size will be automatically set to game's block count)
    estimate_game "$idx"
}

# ════════════════════════════════════════════════════════════════
# Main Entry Point
# ════════════════════════════════════════════════════════════════

if [ $# -eq 0 ]; then
    interactive_mode
else
    check_requirements
    
    case "$1" in
        list)
            list_games
            ;;
        estimate)
            [ -z "$2" ] && { echo "Usage: $0 estimate <game_index> [batch_size]"; exit 1; }
            
            # List games first to populate arrays
            list_games > /dev/null
            
            # Estimate
            estimate_game "$2" "${3:-$DEFAULT_BATCH_SIZE}"
            ;;
        *)
            echo "Usage: $0 [COMMAND] [ARGS]"
            echo ""
            echo "Commands:"
            echo "  list                          List all games"
            echo "  estimate <index> [batch_size] Estimate cost for a specific game"
            echo "                                (batch_size defaults to game's block count)"
            echo ""
            echo "Interactive mode: $0"
            exit 1
            ;;
    esac
fi

