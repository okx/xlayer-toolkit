#!/bin/bash
# get-game.sh — Show detailed info for a single dispute game by index.
#
# Usage:
#   ./get-game.sh <game_id>
#
# Examples:
#   ./get-game.sh 0        # Show game at index 0
#   ./get-game.sh 42       # Show game at index 42

set -euo pipefail

# ════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[ -f "$DEVNET_DIR/.env" ] && source "$DEVNET_DIR/.env"

FACTORY_ADDRESS=${DISPUTE_GAME_FACTORY_ADDRESS:-""}
L1_RPC=${L1_RPC_URL:-"http://localhost:8545"}
L2_RPC=${L2_RPC_URL:-"http://localhost:8123"}

GENESIS_PARENT_INDEX=4294967295

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ════════════════════════════════════════════════════════════════
# Usage / Arg Parsing
# ════════════════════════════════════════════════════════════════
usage() {
  echo "Usage: $0 <game_id>"
  echo ""
  echo "  game_id   Index of the dispute game in the factory"
  echo ""
  echo "Examples:"
  echo "  $0 0"
  echo "  $0 42"
  exit 1
}

if [[ $# -ne 1 ]] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
  usage
fi

GAME_ID="$1"

# ════════════════════════════════════════════════════════════════
# Requirements
# ════════════════════════════════════════════════════════════════
if ! command -v cast &>/dev/null; then
  echo -e "${RED}Error: 'cast' not found. Install Foundry: https://getfoundry.sh${NC}"
  exit 1
fi

if [[ -z "$FACTORY_ADDRESS" ]]; then
  echo -e "${RED}Error: DISPUTE_GAME_FACTORY_ADDRESS not set in $DEVNET_DIR/.env${NC}"
  exit 1
fi

# ════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════

proposal_status_name() {
  case "$1" in
    0) echo "Unchallenged" ;;
    1) echo "Challenged" ;;
    2) echo "UnchallengedAndValidProofProvided" ;;
    3) echo "ChallengedAndValidProofProvided" ;;
    4) echo "Resolved" ;;
    *) echo "Unknown($1)" ;;
  esac
}

game_status_name() {
  case "$1" in
    0) echo "IN_PROGRESS" ;;
    1) echo "CHALLENGER_WINS" ;;
    2) echo "DEFENDER_WINS" ;;
    *) echo "Unknown($1)" ;;
  esac
}

bond_mode_name() {
  case "$1" in
    0) echo "UNDECIDED" ;;
    1) echo "NORMAL" ;;
    2) echo "REFUND" ;;
    *) echo "Unknown($1)" ;;
  esac
}

fmt_ts_field() {
  local raw="$1"
  local num
  num=$(echo "$raw" | awk '{print $1}')
  if [[ "$num" == "0" || "$num" == "N/A" || -z "$num" ]]; then
    echo "N/A"
    return
  fi
  local human
  human=$(date -r "$num" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
          || date -d "@$num" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
          || echo "?")
  echo "${num}  (${human})"
}

fmt_duration() {
  local secs="$1"
  if [[ "$secs" == "N/A" ]]; then echo "N/A"; return; fi
  printf "%dh %dm %ds" "$((secs/3600))" "$(((secs%3600)/60))" "$((secs%60))"
}

row()         { printf "  %-32s %s\n" "$1" "$2"; }
section()     { echo "  ┌─── $1"; }
section_end() { echo "  └$(printf '─%.0s' {1..100})┘"; }
phase()       { printf "  ├─ %s\n" "$1"; }
trow()        { printf "  │      %-26s %s\n" "$1" "$2"; }

# ════════════════════════════════════════════════════════════════
# Header
# ════════════════════════════════════════════════════════════════
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}${BOLD}  Dispute Game Inspector${NC}"
echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Factory:${NC} ${FACTORY_ADDRESS:0:10}...${FACTORY_ADDRESS: -8}"
echo -e "  ${BOLD}L1 RPC:${NC}  $L1_RPC"
echo -e "  ${BOLD}L2 RPC:${NC}  $L2_RPC"
echo -e "  ${BOLD}Game ID:${NC} $GAME_ID"
echo ""

# ════════════════════════════════════════════════════════════════
# Validate game ID within range
# ════════════════════════════════════════════════════════════════
TOTAL=$(cast call "$FACTORY_ADDRESS" "gameCount()(uint256)" --rpc-url "$L1_RPC")
echo -e "  ${CYAN}Total games in factory: $TOTAL${NC}"
echo ""

if [[ "$TOTAL" -eq 0 ]]; then
  echo -e "${YELLOW}No games yet.${NC}"
  exit 0
fi

if [[ "$GAME_ID" -ge "$TOTAL" ]]; then
  echo -e "${RED}Error: game ID $GAME_ID out of range (0 – $((TOTAL-1)))${NC}"
  exit 1
fi

# ════════════════════════════════════════════════════════════════
# Factory record
# ════════════════════════════════════════════════════════════════
INFO=$(cast call "$FACTORY_ADDRESS" "gameAtIndex(uint256)(uint8,uint64,address)" "$GAME_ID" --rpc-url "$L1_RPC")
GAME_TYPE=$(echo "$INFO" | awk 'NR==1')
ADDR=$(echo "$INFO"      | awk 'NR==3')

echo "╔══════════════════════════════════════════════════════════════╗"
printf "║  GAME #%-6s  │  GameType: %-33s║\n" "$GAME_ID" "$GAME_TYPE"
echo "╚══════════════════════════════════════════════════════════════╝"

# ════════════════════════════════════════════════════════════════
# Fetch all fields
# ════════════════════════════════════════════════════════════════

# Immutables
MAX_CHAL_DUR=$(cast call "$ADDR" "maxChallengeDuration()(uint64)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
MAX_PROVE_DUR=$(cast call "$ADDR" "maxProveDuration()(uint64)"    --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
CHAL_BOND=$(   cast call "$ADDR" "challengerBond()(uint256)"      --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

# Identity
GAME_CREATOR=$(  cast call "$ADDR" "gameCreator()(address)"                    --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
PROPOSER_ADDR=$( cast call "$ADDR" "proposer()(address)"                       --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
WAS_RESPECTED=$( cast call "$ADDR" "wasRespectedGameTypeWhenCreated()(bool)"   --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

# Proposal range
L2_BLOCK=$(     cast call "$ADDR" "l2BlockNumber()(uint256)"       --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
PARENT_IDX=$(   cast call "$ADDR" "parentIndex()(uint32)"          --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
STARTING_BN=$(  cast call "$ADDR" "startingBlockNumber()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
STARTING_HASH=$(cast call "$ADDR" "startingRootHash()(bytes32)"    --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
ROOT_CLAIM=$(   cast call "$ADDR" "rootClaim()(bytes32)"           --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
BLOCK_HASH=$(   cast call "$ADDR" "blockHash()(bytes32)"           --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
STATE_HASH=$(   cast call "$ADDR" "stateHash()(bytes32)"           --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

# ClaimData struct: (uint32 parentIndex, address counteredBy, address prover,
#                   bytes32 claim, uint8 status, uint64 deadline)
CLAIM_RAW=$(cast call "$ADDR" "claimData()(uint32,address,address,bytes32,uint8,uint64)" \
              --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
if [[ "$CLAIM_RAW" != "N/A" ]]; then
  CD_COUNTERED=$(  echo "$CLAIM_RAW" | awk 'NR==2')
  CD_PROVER=$(     echo "$CLAIM_RAW" | awk 'NR==3')
  CD_STATUS_RAW=$( echo "$CLAIM_RAW" | awk 'NR==5')
  CD_DEADLINE=$(   echo "$CLAIM_RAW" | awk 'NR==6')
else
  CD_COUNTERED="N/A"; CD_PROVER="N/A"; CD_STATUS_RAW="N/A"; CD_DEADLINE="N/A"
fi

# Game-level state
GAME_STATUS_RAW=$(cast call "$ADDR" "status()(uint8)"               --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
CREATED_AT_RAW=$( cast call "$ADDR" "createdAt()(uint64)"           --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
RESOLVED_AT_RAW=$(cast call "$ADDR" "resolvedAt()(uint64)"          --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
BOND_MODE_RAW=$(  cast call "$ADDR" "bondDistributionMode()(uint8)" --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")
GAME_OVER=$(      cast call "$ADDR" "gameOver()(bool)"              --rpc-url "$L1_RPC" 2>/dev/null || echo "N/A")

# ════════════════════════════════════════════════════════════════
# Derived values
# ════════════════════════════════════════════════════════════════
CD_STATUS=$(proposal_status_name  "$CD_STATUS_RAW")
GAME_STATUS=$(game_status_name    "$GAME_STATUS_RAW")
BOND_MODE=$(bond_mode_name        "$BOND_MODE_RAW")

CREATED_AT_FMT=$( fmt_ts_field "$CREATED_AT_RAW")
RESOLVED_AT_FMT=$(fmt_ts_field "$RESOLVED_AT_RAW")
DEADLINE_FMT=$(   fmt_ts_field "$(echo "$CD_DEADLINE" | awk '{print $1}')")

MAX_CHAL_FMT="N/A"
MAX_PROVE_FMT="N/A"
if [[ "$MAX_CHAL_DUR" != "N/A" ]]; then
  MAX_CHAL_NUM=$(echo "$MAX_CHAL_DUR" | awk '{print $1}')
  MAX_CHAL_FMT="${MAX_CHAL_NUM}s  ($(fmt_duration "$MAX_CHAL_NUM"))"
fi
if [[ "$MAX_PROVE_DUR" != "N/A" ]]; then
  MAX_PROVE_NUM=$(echo "$MAX_PROVE_DUR" | awk '{print $1}')
  MAX_PROVE_FMT="${MAX_PROVE_NUM}s  ($(fmt_duration "$MAX_PROVE_NUM"))"
fi

CHAL_BOND_FMT="N/A"
if [[ "$CHAL_BOND" != "N/A" ]]; then
  CHAL_BOND_ETH=$(cast to-unit "$CHAL_BOND" ether 2>/dev/null || echo "?")
  CHAL_BOND_FMT="${CHAL_BOND_ETH} ETH  (${CHAL_BOND} wei)"
fi

# Parent block range
PARENT_DISPLAY="$PARENT_IDX"
BLOCK_RANGE="N/A"
if [[ "$PARENT_IDX" == "$GENESIS_PARENT_INDEX" ]]; then
  PARENT_DISPLAY="genesis"
  BLOCK_RANGE="? – ${L2_BLOCK}"
else
  PARENT_DATA=$(cast call "$FACTORY_ADDRESS" "gameAtIndex(uint256)(uint8,uint64,address)" \
                  "$PARENT_IDX" --rpc-url "$L1_RPC" 2>/dev/null || echo "")
  if [[ -n "$PARENT_DATA" ]]; then
    PARENT_ADDR=$(echo "$PARENT_DATA" | awk 'NR==3')
    PARENT_L2=$(cast call "$PARENT_ADDR" "l2BlockNumber()(uint256)" --rpc-url "$L1_RPC" 2>/dev/null | awk '{print $1}')
    BLOCK_RANGE="${PARENT_L2} – ${L2_BLOCK}  ($(( $(echo "$L2_BLOCK" | awk '{print $1}') - PARENT_L2 )) blocks)"
  fi
fi

# ════════════════════════════════════════════════════════════════
# Output
# ════════════════════════════════════════════════════════════════

# Section 1: Identity & Config
echo ""
section "[1] Identity & Config ──────────────────────────────────────────────────────────────────────────┐"
phase "Identity"
trow "Address:"              "$ADDR"
trow "GameType:"             "$GAME_TYPE"
trow "GameCreator:"          "$GAME_CREATOR"
trow "Proposer:"             "$PROPOSER_ADDR"
trow "WasRespectedGameType:" "$WAS_RESPECTED"
phase "Config"
trow "MaxChallengeDuration:" "$MAX_CHAL_FMT"
trow "MaxProveDuration:"     "$MAX_PROVE_FMT"
trow "ChallengerBond:"       "$CHAL_BOND_FMT"
section_end

# Section 2: Proposal
echo ""
section "[2] Proposal  ──────────────────────────────────────────────────────────────────────────────────┐"
phase "Starting State"
trow "ParentIndex:"          "$PARENT_DISPLAY"
trow "StartingBlockNumber:"  "$STARTING_BN"
trow "StartingRootHash:"     "$STARTING_HASH"
phase "Target State"
trow "L2BlockNumber:"        "$L2_BLOCK"
trow "BlockRange:"           "$BLOCK_RANGE"
trow "BlockHash:"            "$BLOCK_HASH"
trow "StateHash:"            "$STATE_HASH"
trow "RootClaim:"            "$ROOT_CLAIM"
section_end

# Section 3: Lifecycle State
echo ""
section "[3] Lifecycle State ────────────────────────────────────────────────────────────────────────────┐"
phase "Initialize"
trow "CreatedAt:"            "$CREATED_AT_FMT"
phase "Challenge Window"
trow "CounteredBy:"          "$CD_COUNTERED"
trow "ClaimData.status:"     "$CD_STATUS"
trow "ClaimData.deadline:"   "$DEADLINE_FMT"
phase "Prove"
trow "Prover:"               "$CD_PROVER"
trow "GameOver:"             "$GAME_OVER"
phase "Resolve"
trow "GameStatus:"           "$GAME_STATUS"
trow "ResolvedAt:"           "$RESOLVED_AT_FMT"
phase "CloseGame/ClaimCredit"
trow "BondDistributionMode:" "$BOND_MODE"
section_end

echo ""
echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}Done.${NC}"
