#!/bin/bash

# test-bridge-intercept.sh
#
# Deploy BridgeContractMock & BridgeCallerMock to L2, then test bridge intercept
# with --xlayer.intercept.target-token support.
#
# Test matrix (direct = tx to bridge contract, indirect = tx via caller contract):
#   Phase 1 (before intercept enabled): all txs should succeed
#   Phase 2 (after intercept enabled with bridge-contract + target-token):
#     - bridge+token match   (direct & indirect) -> timeout (intercepted)
#     - bridge match only    (direct & indirect) -> success (bridge matches but token mismatch, NOT intercepted)
#     - no bridge event      (direct & indirect) -> success (no BridgeEvent emitted, NOT intercepted)
#   Phase 3 (intercept with target-token = "*", wildcard mode):
#     - any bridge event     (direct & indirect) -> timeout (intercepted, wildcard matches ALL tokens)
#     - no bridge event      (direct & indirect) -> success (no BridgeEvent emitted, NOT intercepted)

set -e

ROOT_DIR=$(git rev-parse --show-toplevel)
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd $PWD_DIR

source .env

# Check required variables
for var in RICH_L1_PRIVATE_KEY OP_CONTRACTS_IMAGE_TAG DOCKER_NETWORK SEQ_TYPE RPC_TYPE; do
  if [ -z "${!var}" ]; then
    echo "ERROR: missing env var: $var"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TARGET_TOKEN="0x0000000000000000000000000000000000000001"
NON_TARGET_TOKEN="0x0000000000000000000000000000000000000099"
DESTINATION_ADDR="0x0000000000000000000000000000000000000002"
AMOUNT=100
TX_TIMEOUT=20            # seconds - intercepted txs will timeout after this
GAS_PRICE=1000000000     # 1 gwei - high enough to replace any stuck pending tx

L2_RPC="http://op-${SEQ_TYPE}-seq:8545"

# ---------------------------------------------------------------------------
# Cleanup: restore .env on exit (normal or abnormal)
# ---------------------------------------------------------------------------
cleanup() {
  if [ -f ".env.bak.intercept" ]; then
    mv .env.bak.intercept .env
    echo "[cleanup] .env restored"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# send_tx <to> <sig> <token> - returns 0 on success, non-zero on failure/timeout
send_tx() {
  local to="$1" sig="$2" token="$3"
  docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/contracts:/app/packages/contracts-bedrock" \
    -w /app/packages/contracts-bedrock \
    "${OP_CONTRACTS_IMAGE_TAG}" \
    cast send $to \
      --private-key $RICH_L1_PRIVATE_KEY \
      --rpc-url $L2_RPC \
      --timeout $TX_TIMEOUT \
      --gas-price $GAS_PRICE \
      "$sig" \
      $token $AMOUNT $DESTINATION_ADDR > /dev/null 2>&1
}

# wait for the L2 sequencer container to be healthy AND producing blocks
wait_for_seq_ready() {
  local container="op-${SEQ_TYPE}-seq"

  # 1. Wait for healthcheck
  echo "Waiting for $container to be healthy..."
  local max_wait=120 elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    local hstatus
    hstatus=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
    if [ "$hstatus" = "healthy" ]; then
      echo "$container is healthy"
      break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  if [ $elapsed -ge $max_wait ]; then
    echo "ERROR: $container did not become healthy within ${max_wait}s"
    return 1
  fi

  # 2. Wait for new block (proves CL reconnected and chain is producing)
  echo "Waiting for chain to produce a new block..."
  local start_block
  start_block=$(docker run --rm --network "$DOCKER_NETWORK" "${OP_CONTRACTS_IMAGE_TAG}" \
    cast block-number --rpc-url $L2_RPC 2>/dev/null || echo "0")
  elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    local cur_block
    cur_block=$(docker run --rm --network "$DOCKER_NETWORK" "${OP_CONTRACTS_IMAGE_TAG}" \
      cast block-number --rpc-url $L2_RPC 2>/dev/null || echo "0")
    if [ "$cur_block" -gt "$start_block" ] 2>/dev/null; then
      echo "New block produced: $cur_block (was $start_block)"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "ERROR: no new blocks produced within ${max_wait}s"
  return 1
}

# result tracking
PASS=0; FAIL=0
check() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  [PASS] $label"
  else
    FAIL=$((FAIL + 1))
    echo "  [FAIL] $label (expected=$expected actual=$actual)"
  fi
}

# ============================================================
# Phase 0: Reset - ensure nodes run WITHOUT intercept
# ============================================================
echo "========================================="
echo "  Phase 0: Resetting nodes (disable intercept)"
echo "========================================="

# Clean up leftover intercept config from a previous run
if [ -f ".env.bak.intercept" ]; then
  mv .env.bak.intercept .env
  source .env
  echo "Restored .env from previous run's backup"
fi

docker compose up -d --force-recreate "op-${SEQ_TYPE}-seq" "op-${RPC_TYPE}-rpc" op-seq op-rpc
wait_for_seq_ready

echo ""

# ============================================================
# Deploy contracts to L2
# ============================================================
echo "========================================="
echo "  Deploying contracts to L2"
echo "========================================="

BRIDGE_DEPLOY_OUTPUT=$(docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/contracts:/app/packages/contracts-bedrock" \
  -w /app/packages/contracts-bedrock \
  "${OP_CONTRACTS_IMAGE_TAG}" \
  forge create --json --broadcast --legacy \
    --rpc-url $L2_RPC \
    --private-key $RICH_L1_PRIVATE_KEY \
    --gas-price $GAS_PRICE \
    BridgeContractMock.sol:BridgeContractMock)

BRIDGE_ADDR=$(echo "$BRIDGE_DEPLOY_OUTPUT" | jq -r '.deployedTo // empty')
if [ -z "$BRIDGE_ADDR" ] || [ "$BRIDGE_ADDR" = "null" ]; then
  echo "ERROR: BridgeContractMock deploy failed"
  echo "$BRIDGE_DEPLOY_OUTPUT"
  exit 1
fi
echo "[OK] BridgeContractMock: $BRIDGE_ADDR"

CALLER_DEPLOY_OUTPUT=$(docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/contracts:/app/packages/contracts-bedrock" \
  -w /app/packages/contracts-bedrock \
  "${OP_CONTRACTS_IMAGE_TAG}" \
  forge create --json --broadcast --legacy \
    --rpc-url $L2_RPC \
    --private-key $RICH_L1_PRIVATE_KEY \
    --gas-price $GAS_PRICE \
    BridgeCallerMock.sol:BridgeCallerMock \
    --constructor-args $BRIDGE_ADDR)

CALLER_ADDR=$(echo "$CALLER_DEPLOY_OUTPUT" | jq -r '.deployedTo // empty')
if [ -z "$CALLER_ADDR" ] || [ "$CALLER_ADDR" = "null" ]; then
  echo "ERROR: BridgeCallerMock deploy failed"
  echo "$CALLER_DEPLOY_OUTPUT"
  exit 1
fi
echo "[OK] BridgeCallerMock: $CALLER_ADDR"

echo ""
echo "TARGET_TOKEN:     $TARGET_TOKEN"
echo "NON_TARGET_TOKEN: $NON_TARGET_TOKEN"
echo ""

# ============================================================
# Phase 1: Before intercept - all txs should succeed
# ============================================================
echo "========================================="
echo "  Phase 1: Before intercept (expect all success)"
echo "========================================="

set +e

# Category 1: bridge+token match (emit BridgeEvent with matching token)
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $TARGET_TOKEN
p1_direct_match=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $TARGET_TOKEN
p1_indirect_match=$?

# Category 2: bridge match, token mismatch (emit BridgeEvent with wrong token)
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $NON_TARGET_TOKEN
p1_direct_bridge_only=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $NON_TARGET_TOKEN
p1_indirect_bridge_only=$?

# Category 3: no bridge event (call bridge contract but no BridgeEvent emitted)
send_tx $BRIDGE_ADDR "bridgeDirectNoEvent(address,uint256,address)" $TARGET_TOKEN
p1_direct_noevent=$?

send_tx $CALLER_ADDR "callBridgeNoEvent(address,uint256,address)" $TARGET_TOKEN
p1_indirect_noevent=$?

set -e

echo "  bridge+token match     (direct):  $([ $p1_direct_match -eq 0 ] && echo 'success' || echo 'FAILED')"
echo "  bridge+token match     (indirect):$([ $p1_indirect_match -eq 0 ] && echo 'success' || echo 'FAILED')"
echo "  bridge match only      (direct):  $([ $p1_direct_bridge_only -eq 0 ] && echo 'success' || echo 'FAILED')"
echo "  bridge match only      (indirect):$([ $p1_indirect_bridge_only -eq 0 ] && echo 'success' || echo 'FAILED')"
echo "  no bridge event        (direct):  $([ $p1_direct_noevent -eq 0 ] && echo 'success' || echo 'FAILED')"
echo "  no bridge event        (indirect):$([ $p1_indirect_noevent -eq 0 ] && echo 'success' || echo 'FAILED')"
echo ""

# ============================================================
# Enable intercept: update .env & restart reth nodes
# ============================================================
echo "========================================="
echo "  Enabling intercept"
echo "========================================="

cp .env .env.bak.intercept

cat >> .env << EOF

# --- Bridge Intercept Test Config (auto-added) ---
XLAYER_INTERCEPT_ENABLED=true
XLAYER_INTERCEPT_BRIDGE_CONTRACT=$BRIDGE_ADDR
XLAYER_INTERCEPT_TARGET_TOKEN=$TARGET_TOKEN
# --- End Bridge Intercept Test Config ---
EOF

source .env

echo "Intercept config:"
echo "  bridge-contract = $BRIDGE_ADDR"
echo "  target-token    = $TARGET_TOKEN"
echo ""

echo "Restarting op-${SEQ_TYPE}-seq and op-${RPC_TYPE}-rpc with intercept..."
docker compose up -d --force-recreate "op-${SEQ_TYPE}-seq" "op-${RPC_TYPE}-rpc" op-seq op-rpc

wait_for_seq_ready

echo ""

# ============================================================
# Phase 2: After intercept - matching token should timeout
# ============================================================
echo "========================================="
echo "  Phase 2: After intercept (matching token -> timeout)"
echo "========================================="

set +e

# Send non-intercepted txs FIRST (should succeed), then intercepted txs last
# (will block the nonce). This order avoids nonce-gap issues.

# Category 2: bridge match, token mismatch -> should succeed
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $NON_TARGET_TOKEN
p2_direct_bridge_only=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $NON_TARGET_TOKEN
p2_indirect_bridge_only=$?

# Category 3: no bridge event -> should succeed
send_tx $BRIDGE_ADDR "bridgeDirectNoEvent(address,uint256,address)" $TARGET_TOKEN
p2_direct_noevent=$?

send_tx $CALLER_ADDR "callBridgeNoEvent(address,uint256,address)" $TARGET_TOKEN
p2_indirect_noevent=$?

# Category 1: bridge+token match -> should timeout (intercepted) — MUST BE LAST
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $TARGET_TOKEN
p2_direct_match=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $TARGET_TOKEN
p2_indirect_match=$?

set -e

echo "  bridge match only      (direct):  $([ $p2_direct_bridge_only -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  bridge match only      (indirect):$([ $p2_indirect_bridge_only -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  no bridge event        (direct):  $([ $p2_direct_noevent -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  no bridge event        (indirect):$([ $p2_indirect_noevent -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  bridge+token match     (direct):  $([ $p2_direct_match -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo "  bridge+token match     (indirect):$([ $p2_indirect_match -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo ""

# ============================================================
# Phase 3: Wildcard mode - target-token = "*"
# ============================================================
echo "========================================="
echo "  Enabling wildcard mode (target-token=*)"
echo "========================================="

# Restore clean .env, then write wildcard config
mv .env.bak.intercept .env
source .env
cp .env .env.bak.intercept

cat >> .env << EOF

# --- Bridge Intercept Test Config (auto-added) ---
XLAYER_INTERCEPT_ENABLED=true
XLAYER_INTERCEPT_BRIDGE_CONTRACT=$BRIDGE_ADDR
XLAYER_INTERCEPT_TARGET_TOKEN=*
# --- End Bridge Intercept Test Config ---
EOF

source .env

echo "Intercept config:"
echo "  bridge-contract = $BRIDGE_ADDR"
echo "  target-token    = * (wildcard)"
echo ""

echo "Restarting op-${SEQ_TYPE}-seq and op-${RPC_TYPE}-rpc with wildcard intercept..."
docker compose up -d --force-recreate "op-${SEQ_TYPE}-seq" "op-${RPC_TYPE}-rpc" op-seq op-rpc

wait_for_seq_ready

echo ""

echo "========================================="
echo "  Phase 3: Wildcard intercept (all bridge events -> timeout)"
echo "========================================="

# Bump gas price to replace any stuck Phase 2 intercepted txs that may persist in txpool
GAS_PRICE=2000000000  # 2 gwei

set +e

# no bridge event -> should succeed (send first to avoid nonce gap)
send_tx $BRIDGE_ADDR "bridgeDirectNoEvent(address,uint256,address)" $TARGET_TOKEN
p3_direct_noevent=$?

send_tx $CALLER_ADDR "callBridgeNoEvent(address,uint256,address)" $TARGET_TOKEN
p3_indirect_noevent=$?

# bridge+token match -> should timeout (wildcard intercepts)
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $TARGET_TOKEN
p3_direct_match=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $TARGET_TOKEN
p3_indirect_match=$?

# bridge match, token mismatch -> should ALSO timeout (wildcard intercepts ALL tokens)
send_tx $BRIDGE_ADDR "bridgeDirect(address,uint256,address)" $NON_TARGET_TOKEN
p3_direct_bridge_only=$?

send_tx $CALLER_ADDR "callBridge(address,uint256,address)" $NON_TARGET_TOKEN
p3_indirect_bridge_only=$?

set -e

echo "  no bridge event        (direct):  $([ $p3_direct_noevent -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  no bridge event        (indirect):$([ $p3_indirect_noevent -eq 0 ] && echo 'success' || echo 'UNEXPECTED FAIL')"
echo "  bridge+token match     (direct):  $([ $p3_direct_match -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo "  bridge+token match     (indirect):$([ $p3_indirect_match -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo "  bridge match only      (direct):  $([ $p3_direct_bridge_only -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo "  bridge match only      (indirect):$([ $p3_indirect_bridge_only -ne 0 ] && echo 'timeout (expected)' || echo 'UNEXPECTED SUCCESS')"
echo ""

# ============================================================
# Summary
# ============================================================
echo "========================================="
echo "  Summary"
echo "========================================="

# Phase 1: all should succeed (exit code 0)
check $p1_direct_match         0 "Phase1: bridge+token match  (direct)  -> success"
check $p1_indirect_match       0 "Phase1: bridge+token match  (indirect)-> success"
check $p1_direct_bridge_only   0 "Phase1: bridge match only   (direct)  -> success"
check $p1_indirect_bridge_only 0 "Phase1: bridge match only   (indirect)-> success"
check $p1_direct_noevent       0 "Phase1: no bridge event     (direct)  -> success"
check $p1_indirect_noevent     0 "Phase1: no bridge event     (indirect)-> success"

# Phase 2: bridge+token match should timeout, everything else should succeed
check $p2_direct_bridge_only   0 "Phase2: bridge match only   (direct)  -> success"
check $p2_indirect_bridge_only 0 "Phase2: bridge match only   (indirect)-> success"
check $p2_direct_noevent       0 "Phase2: no bridge event     (direct)  -> success"
check $p2_indirect_noevent     0 "Phase2: no bridge event     (indirect)-> success"

if [ $p2_direct_match -ne 0 ]; then
  check 0 0 "Phase2: bridge+token match  (direct)  -> timeout (expected)"
else
  check 1 0 "Phase2: bridge+token match  (direct)  -> timeout (expected)"
fi

if [ $p2_indirect_match -ne 0 ]; then
  check 0 0 "Phase2: bridge+token match  (indirect)-> timeout (expected)"
else
  check 1 0 "Phase2: bridge+token match  (indirect)-> timeout (expected)"
fi

# Phase 3: wildcard - all bridge events should timeout, no-event should succeed
check $p3_direct_noevent       0 "Phase3: no bridge event     (direct)  -> success"
check $p3_indirect_noevent     0 "Phase3: no bridge event     (indirect)-> success"

if [ $p3_direct_match -ne 0 ]; then
  check 0 0 "Phase3: bridge+token match  (direct)  -> timeout (expected)"
else
  check 1 0 "Phase3: bridge+token match  (direct)  -> timeout (expected)"
fi

if [ $p3_indirect_match -ne 0 ]; then
  check 0 0 "Phase3: bridge+token match  (indirect)-> timeout (expected)"
else
  check 1 0 "Phase3: bridge+token match  (indirect)-> timeout (expected)"
fi

if [ $p3_direct_bridge_only -ne 0 ]; then
  check 0 0 "Phase3: bridge match only   (direct)  -> timeout (expected)"
else
  check 1 0 "Phase3: bridge match only   (direct)  -> timeout (expected)"
fi

if [ $p3_indirect_bridge_only -ne 0 ]; then
  check 0 0 "Phase3: bridge match only   (indirect)-> timeout (expected)"
else
  check 1 0 "Phase3: bridge match only   (indirect)-> timeout (expected)"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  echo "TEST FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
fi
