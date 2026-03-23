#!/bin/bash
# 7-run-tee-e2e.sh — TEE Dispute Game E2E 测试主入口（一键运行）
#
# 前提条件:
#   1. .tee.env 已配置 (cp tee.env .tee.env && 编辑)
#
# 本脚本自动完成:
#   - 清理旧环境
#   - 检查/构建 Docker 镜像
#   - 启动 L1 + 部署全套合约（使用 TEE 合约镜像里的 op-deployer）
#   - 编译并启动 Mock 组件（mockteerpc、mock-tee-prover）
#   - 部署 TEE 合约 + 充值账户
#   - 启动 tee-op-proposer / tee-op-challenger 容器
#   - 运行 5 个测试场景
#   - 清理
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEVNET_DIR"

# 加载配置
if [ ! -f .tee.env ]; then
    echo "ERROR: .tee.env not found. Run: cp tee.env .tee.env && edit .tee.env"
    exit 1
fi
source .tee.env
source .env
[ -f tee-contracts.env ] && source tee-contracts.env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

SCRIPTS_DIR="$DEVNET_DIR/scripts"
E2E_DIR="$DEVNET_DIR/e2e"

# Mock 进程 PID（用于清理）
MOCKTEERPC_PID=""

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    # 停止 TEE Docker 服务
    echo "  Stopping TEE Docker services..."
    docker compose --env-file .env --env-file .tee.env \
        -f docker-compose.yml -f docker-compose.tee.yml \
        stop tee-op-proposer tee-op-challenger 2>/dev/null || true

    # 停止 Mock 组件
    if [ -n "$MOCKTEERPC_PID" ] && kill -0 "$MOCKTEERPC_PID" 2>/dev/null; then
        echo "  Stopping mockteerpc (PID $MOCKTEERPC_PID)..."
        kill "$MOCKTEERPC_PID" 2>/dev/null || true
        wait "$MOCKTEERPC_PID" 2>/dev/null || true
    fi
    if docker ps --format '{{.Names}}' | grep -q '^mock-tee-prover$'; then
        echo "  Stopping mock-tee-prover container..."
        docker rm -f mock-tee-prover 2>/dev/null || true
    fi
    echo "  Cleanup done."
}
trap cleanup EXIT

echo "========================================"
echo "  TEE Dispute Game E2E Tests"
echo "========================================"
echo ""

# ============================================================
# Phase 0: 清理旧环境
# ============================================================
echo "=== Phase 0: Clean up previous environment ==="

echo "  Stopping and removing containers..."
docker compose --env-file .env -f docker-compose.yml \
    down --remove-orphans 2>/dev/null || true
if [ -f docker-compose.tee.yml ]; then
    docker compose --env-file .env --env-file .tee.env \
        -f docker-compose.yml -f docker-compose.tee.yml \
        down --remove-orphans 2>/dev/null || true
fi

echo "  Removing L1 chain data..."
rm -rf "$DEVNET_DIR/l1-geth/execution/geth"
rm -rf "$DEVNET_DIR/l1-geth/consensus/beacondata"
rm -rf "$DEVNET_DIR/l1-geth/consensus/validatordata"
rm -rf "$DEVNET_DIR/l1-geth/consensus/genesis.ssz"

rm -f "$DEVNET_DIR/tee-contracts.env"

echo "  Cleanup done."
echo ""

# ============================================================
# Phase 1: 构建 Docker 镜像（如未跳过）
# ============================================================
echo "=== Phase 1: Build Docker images ==="

# 1a. TEE OP Stack 镜像（包含 op-proposer + op-challenger）
if [ "$SKIP_TEE_OP_STACK_BUILD" != "true" ]; then
    if [ -n "$TEE_OP_STACK_LOCAL_DIRECTORY" ]; then
        SRC_DIR="$TEE_OP_STACK_LOCAL_DIRECTORY"
    else
        SRC_DIR="/tmp/optimism-tee"
        if [ -d "$SRC_DIR" ]; then
            echo "  Updating existing clone at $SRC_DIR..."
            (cd "$SRC_DIR" && git fetch origin && git checkout "$TEE_OP_STACK_BRANCH" && git pull)
        else
            echo "  Cloning optimism ($TEE_OP_STACK_BRANCH)..."
            git clone --branch "$TEE_OP_STACK_BRANCH" --depth 1 \
                https://github.com/okx/optimism.git "$SRC_DIR"
        fi
    fi
    echo "  Building image: $TEE_OP_STACK_IMAGE_TAG (this may take a while)..."
    # 临时复制 .dockerignore 到 build context，排除 op-reth/target 等大目录
    _NEED_CLEANUP_DOCKERIGNORE=""
    if [ -f "$SRC_DIR/.dockerignore" ]; then
        cp "$SRC_DIR/.dockerignore" "$SRC_DIR/.dockerignore.bak"
    fi
    cp "$E2E_DIR/Dockerfile-opstack.dockerignore" "$SRC_DIR/.dockerignore"
    _NEED_CLEANUP_DOCKERIGNORE="true"

    docker build -t "$TEE_OP_STACK_IMAGE_TAG" \
        -f "$E2E_DIR/Dockerfile-opstack" "$SRC_DIR"

    # 恢复原 .dockerignore
    if [ "$_NEED_CLEANUP_DOCKERIGNORE" = "true" ]; then
        if [ -f "$SRC_DIR/.dockerignore.bak" ]; then
            mv "$SRC_DIR/.dockerignore.bak" "$SRC_DIR/.dockerignore"
        else
            rm -f "$SRC_DIR/.dockerignore"
        fi
    fi
    echo "  TEE OP Stack image built: $TEE_OP_STACK_IMAGE_TAG"
else
    if ! docker image inspect "$TEE_OP_STACK_IMAGE_TAG" > /dev/null 2>&1; then
        echo "ERROR: Image $TEE_OP_STACK_IMAGE_TAG not found and SKIP_TEE_OP_STACK_BUILD=true"
        echo "  Set SKIP_TEE_OP_STACK_BUILD=false in .tee.env to build it."
        exit 1
    fi
    echo "  TEE OP Stack image: $TEE_OP_STACK_IMAGE_TAG (exists, skip build)"
fi

# 1b. TEE 合约镜像（forge + op-deployer + contracts-bedrock 源码）
if [ "$SKIP_TEE_CONTRACTS_BUILD" != "true" ]; then
    echo "  Building TEE contracts image..."
    if [ -n "$TEE_CONTRACTS_LOCAL_DIRECTORY" ]; then
        CONTRACTS_DIR="$TEE_CONTRACTS_LOCAL_DIRECTORY"
    else
        CONTRACTS_DIR="/tmp/optimism-tee-contracts"
        if [ -d "$CONTRACTS_DIR" ]; then
            echo "  Updating existing clone at $CONTRACTS_DIR..."
            (cd "$CONTRACTS_DIR" && git fetch origin && git checkout "$TEE_CONTRACTS_BRANCH" && git pull)
        else
            echo "  Cloning optimism ($TEE_CONTRACTS_BRANCH)..."
            git clone --branch "$TEE_CONTRACTS_BRANCH" --depth 1 \
                https://github.com/okx/optimism.git "$CONTRACTS_DIR"
        fi
    fi
    echo "  Building image: $TEE_CONTRACTS_IMAGE_TAG (using Dockerfile-contracts, this may take a while)..."
    docker build -t "$TEE_CONTRACTS_IMAGE_TAG" \
        -f "$CONTRACTS_DIR/Dockerfile-contracts" "$CONTRACTS_DIR"
    echo "  TEE contracts image built: $TEE_CONTRACTS_IMAGE_TAG"
else
    if ! docker image inspect "$TEE_CONTRACTS_IMAGE_TAG" > /dev/null 2>&1; then
        echo "ERROR: Image $TEE_CONTRACTS_IMAGE_TAG not found and SKIP_TEE_CONTRACTS_BUILD=true"
        echo "  Set SKIP_TEE_CONTRACTS_BUILD=false in .tee.env to build it."
        exit 1
    fi
    echo "  TEE contracts image: $TEE_CONTRACTS_IMAGE_TAG (exists, skip build)"
fi

echo ""

# ============================================================
# Phase 2: 启动 L1 + 部署全套 OP 合约
# ============================================================
echo "=== Phase 2: Start L1 & deploy OP contracts ==="

# 2a. 启动 L1
echo "  Starting L1 via 1-start-l1.sh..."
bash "$DEVNET_DIR/1-start-l1.sh"
echo ""

# 2b. 用 TEE 合约镜像部署全套 OP 合约（替代 2-deploy-op-contracts.sh）
echo "  Deploying OP contracts using $TEE_CONTRACTS_IMAGE_TAG..."

# Derive addresses
CHALLENGER=$(cast wallet address "$OP_CHALLENGER_PRIVATE_KEY")
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
echo "  Deployer: $DEPLOYER_ADDRESS"
echo "  Challenger: $CHALLENGER"

# E2E 测试直接用 deployer EOA 做 owner（不需要 Transactor/Safe）
L1_PROXY_ADMIN_OWNER="$DEPLOYER_ADDRESS"
echo "  l1ProxyAdminOwner (deployer EOA): $L1_PROXY_ADMIN_OWNER"

# Bootstrap superchain
echo "  Bootstrapping superchain..."
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/$CONFIG_DIR:/deployments" \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    bash -c "
      set -e
      /app/op-deployer/bin/op-deployer bootstrap superchain \
        --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --artifacts-locator file:///app/packages/contracts-bedrock/forge-artifacts \
        --superchain-proxy-admin-owner $L1_PROXY_ADMIN_OWNER \
        --protocol-versions-owner $DEPLOYER_ADDRESS \
        --guardian $DEPLOYER_ADDRESS \
        --outfile /deployments/superchain.json
    "

SUPERCHAIN_JSON="$CONFIG_DIR/superchain.json"
PROTOCOL_VERSIONS_PROXY=$(jq -r '.protocolVersionsProxyAddress' "$SUPERCHAIN_JSON")
SUPERCHAIN_CONFIG_PROXY=$(jq -r '.superchainConfigProxyAddress' "$SUPERCHAIN_JSON")
PROXY_ADMIN=$(jq -r '.proxyAdminAddress' "$SUPERCHAIN_JSON")

# Bootstrap implementations
echo "  Bootstrapping implementations..."
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/$CONFIG_DIR:/deployments" \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    bash -c "
      set -e
      /app/op-deployer/bin/op-deployer bootstrap implementations \
        --artifacts-locator file:///app/packages/contracts-bedrock/forge-artifacts \
        --l1-rpc-url $L1_RPC_URL_IN_DOCKER \
        --outfile /deployments/implementations.json \
        --mips-version 8 \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --protocol-versions-proxy $PROTOCOL_VERSIONS_PROXY \
        --superchain-config-proxy $SUPERCHAIN_CONFIG_PROXY \
        --superchain-proxy-admin $PROXY_ADMIN \
        --upgrade-controller $DEPLOYER_ADDRESS \
        --challenger $CHALLENGER \
        --challenge-period-seconds ${CHALLENGE_PERIOD_SECONDS:-10} \
        --withdrawal-delay-seconds ${MAX_CLOCK_DURATION:-20} \
        --proof-maturity-delay-seconds ${MAX_CLOCK_DURATION:-20} \
        --dispute-game-finality-delay-seconds ${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-5} \
        --dispute-clock-extension ${TEMP_CLOCK_EXTENSION:-5} \
        --dispute-max-clock-duration ${TEMP_MAX_CLOCK_DURATION:-20}
    "

# Prepare intent.toml and state.json
cp ./config-op/intent.toml.bak ./config-op/intent.toml
cp ./config-op/state.json.bak ./config-op/state.json
CHAIN_ID_UINT256=$(cast to-uint256 "$CHAIN_ID")
sed_inplace 's/id = .*/id = "'"$CHAIN_ID_UINT256"'"/' ./config-op/intent.toml
sed_inplace "s/l1ProxyAdminOwner = .*/l1ProxyAdminOwner = \"$L1_PROXY_ADMIN_OWNER\"/" "$CONFIG_DIR/intent.toml"
sed_inplace "s/faultGameClockExtension = .*/faultGameClockExtension = ${TEMP_CLOCK_EXTENSION:-5}/" "$CONFIG_DIR/intent.toml"
sed_inplace "s/faultGameMaxClockDuration = .*/faultGameMaxClockDuration = ${TEMP_MAX_CLOCK_DURATION:-20}/" "$CONFIG_DIR/intent.toml"
OPCM_ADDRESS=$(jq -r '.opcmAddress' ./config-op/implementations.json)
sed_inplace "s/^opcmAddress = \".*\"/opcmAddress = \"$OPCM_ADDRESS\"/" ./config-op/intent.toml

# Deploy chain contracts via op-deployer apply
echo "  Deploying chain contracts (op-deployer apply)..."
docker run --rm \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/$CONFIG_DIR:/deployments" \
    "${TEE_CONTRACTS_IMAGE_TAG}" \
    bash -c "
      set -e
      /app/op-deployer/bin/op-deployer apply \
        --workdir /deployments \
        --private-key $DEPLOYER_PRIVATE_KEY \
        --l1-rpc-url $L1_RPC_URL_IN_DOCKER
    "

# Extract deployed addresses from state.json
DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy // .DisputeGameFactoryProxy' "$CONFIG_DIR/state.json")
ANCHOR_STATE_REGISTRY_ADDRESS=$(jq -r '.opChainDeployments[0].AnchorStateRegistryProxy // .AnchorStateRegistryProxy' "$CONFIG_DIR/state.json")
if [ -z "$DISPUTE_GAME_FACTORY_ADDRESS" ] || [ "$DISPUTE_GAME_FACTORY_ADDRESS" = "null" ]; then
    echo "ERROR: Failed to extract DisputeGameFactoryProxy from state.json"
    exit 1
fi
echo "  DisputeGameFactory: $DISPUTE_GAME_FACTORY_ADDRESS"
echo "  AnchorStateRegistry: $ANCHOR_STATE_REGISTRY_ADDRESS"

# Verify on-chain
GAME_COUNT=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" "gameCount()(uint256)" 2>/dev/null || echo "ERROR")
if [ "$GAME_COUNT" = "ERROR" ]; then
    echo "ERROR: DisputeGameFactory not reachable at $DISPUTE_GAME_FACTORY_ADDRESS"
    exit 1
fi
echo "  OP contracts deployed. Factory game count: $GAME_COUNT"

# Export for downstream scripts (deploy-tee-contracts.sh etc.)
export DISPUTE_GAME_FACTORY_ADDRESS
export ANCHOR_STATE_REGISTRY_ADDRESS

# Update .tee.env so docker-compose picks up the real addresses
sed_inplace "s|^DISPUTE_GAME_FACTORY_ADDRESS=.*|DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS|" .tee.env
echo "  Updated .tee.env with deployed factory address"
echo ""

# ============================================================
# Phase 3: 编译并启动 Mock 组件
# ============================================================
echo "=== Phase 3: Build & start mock components ==="

# 确定 optimism 源码目录（用于 mockteerpc）
if [ -n "$TEE_OP_STACK_LOCAL_DIRECTORY" ]; then
    OPTIMISM_SRC="$TEE_OP_STACK_LOCAL_DIRECTORY"
elif [ -d "/tmp/optimism-tee" ]; then
    OPTIMISM_SRC="/tmp/optimism-tee"
else
    OPTIMISM_SRC=""
fi

# --- 3a. mockteerpc ---
echo "  --- mockteerpc ---"
if curl -s "http://localhost${MOCKTEERPC_ADDR}/v1/chain/confirmed_block_info" > /dev/null 2>&1; then
    echo "  mockteerpc already running on $MOCKTEERPC_ADDR"
else
    if ! command -v mockteerpc > /dev/null 2>&1; then
        echo "  Installing mockteerpc..."
        if [ -n "$OPTIMISM_SRC" ] && [ -d "$OPTIMISM_SRC/op-proposer/mock" ]; then
            (cd "$OPTIMISM_SRC/op-proposer" && go install ./mock/cmd/mockteerpc)
            echo "  Installed to $(go env GOPATH)/bin/mockteerpc"
        else
            echo "ERROR: Cannot find optimism source for mockteerpc."
            echo "  Set TEE_OP_STACK_LOCAL_DIRECTORY in .tee.env"
            exit 1
        fi
    else
        echo "  mockteerpc found at $(command -v mockteerpc)"
    fi

    echo "  Starting mockteerpc on $MOCKTEERPC_ADDR (init-height=$MOCKTEERPC_INIT_HEIGHT)..."
    mockteerpc \
        --addr="$MOCKTEERPC_ADDR" \
        --init-height="$MOCKTEERPC_INIT_HEIGHT" \
        --error-rate=0 \
        --delay=0 \
        > /tmp/mockteerpc.log 2>&1 &
    MOCKTEERPC_PID=$!
    echo "  mockteerpc started (PID $MOCKTEERPC_PID, log: /tmp/mockteerpc.log)"

    for i in $(seq 1 10); do
        if curl -s "http://localhost${MOCKTEERPC_ADDR}/v1/chain/confirmed_block_info" > /dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$MOCKTEERPC_PID" 2>/dev/null; then
            echo "ERROR: mockteerpc exited unexpectedly. Check /tmp/mockteerpc.log"
            cat /tmp/mockteerpc.log
            exit 1
        fi
        sleep 1
    done
    echo "  mockteerpc: OK"
fi

# --- 3b. mock-tee-prover (Docker) ---
echo "  --- mock-tee-prover ---"
MOCK_PROVER_PORT="${MOCK_TEE_PROVER_ADDR#:}"  # ":8690" → "8690"
MOCK_PROVER_CONTAINER="mock-tee-prover"

if curl -s "http://localhost:${MOCK_PROVER_PORT}/health" > /dev/null 2>&1; then
    echo "  mock-tee-prover already running on port $MOCK_PROVER_PORT"
else
    # 清理旧容器
    docker rm -f "$MOCK_PROVER_CONTAINER" 2>/dev/null || true

    # 构建镜像
    MOCK_PROVER_DIR="$E2E_DIR/mock-tee-prover"
    echo "  Building mock-tee-prover image..."
    docker build -t mock-tee-prover:latest -q "$MOCK_PROVER_DIR"

    # 启动容器
    echo "  Starting mock-tee-prover on port $MOCK_PROVER_PORT..."
    docker run -d --rm \
        --name "$MOCK_PROVER_CONTAINER" \
        --network "$DOCKER_NETWORK" \
        -p "${MOCK_PROVER_PORT}:${MOCK_PROVER_PORT}" \
        -e SIGNER_PRIVATE_KEY="$TEE_MOCK_SIGNER_PRIVATE_KEY" \
        -e LISTEN_ADDR=":${MOCK_PROVER_PORT}" \
        -e TASK_DELAY="$MOCK_TEE_PROVER_TASK_DELAY" \
        mock-tee-prover:latest

    for i in $(seq 1 10); do
        if curl -s "http://localhost:${MOCK_PROVER_PORT}/health" > /dev/null 2>&1; then
            break
        fi
        if ! docker ps --format '{{.Names}}' | grep -q "^${MOCK_PROVER_CONTAINER}$"; then
            echo "ERROR: mock-tee-prover container exited unexpectedly:"
            docker logs "$MOCK_PROVER_CONTAINER" 2>&1 | tail -20
            exit 1
        fi
        sleep 1
    done
    echo "  mock-tee-prover: OK"
fi

echo ""

# ============================================================
# Phase 4: 部署 TEE 合约 + 充值
# ============================================================
echo "=== Phase 4: Deploy TEE contracts ==="
echo "  Factory: $DISPUTE_GAME_FACTORY_ADDRESS"
echo "  AnchorStateRegistry: $ANCHOR_STATE_REGISTRY_ADDRESS"

if [ ! -f tee-contracts.env ]; then
    echo "  tee-contracts.env not found, deploying..."
    bash "$SCRIPTS_DIR/deploy-tee-contracts.sh"
    source tee-contracts.env
    echo ""
else
    echo "  tee-contracts.env exists, verifying..."
    source tee-contracts.env
    REGISTERED_IMPL=$(cast call --rpc-url "$L1_RPC_URL" "$DISPUTE_GAME_FACTORY_ADDRESS" \
        "gameImpls(uint32)(address)" "$TEE_GAME_TYPE" 2>/dev/null || echo "0x0")
    if [ "$REGISTERED_IMPL" = "0x0000000000000000000000000000000000000000" ]; then
        echo "  WARNING: TEE game type not registered, re-deploying..."
        rm -f tee-contracts.env
        bash "$SCRIPTS_DIR/deploy-tee-contracts.sh"
        source tee-contracts.env
    else
        echo "  TEE contracts verified: gameImpls($TEE_GAME_TYPE) = $REGISTERED_IMPL"
    fi
    echo ""
fi

# ============================================================
# Phase 5: 启动 TEE Docker 服务
# ============================================================
echo "=== Phase 5: Start TEE Docker services ==="

echo "  Starting tee-op-proposer and tee-op-challenger..."
docker compose --env-file .env --env-file .tee.env \
    -f docker-compose.yml -f docker-compose.tee.yml \
    up -d tee-op-proposer tee-op-challenger

echo "  Waiting for containers to start..."
sleep 5

for svc in tee-op-proposer tee-op-challenger; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        echo "  $svc: running"
    else
        echo "ERROR: $svc is not running"
        docker logs "$svc" 2>&1 | tail -20
        exit 1
    fi
done
echo ""

# ============================================================
# Phase 5.5: 验证 anchor state（bootstrap 已在 deploy-tee-contracts.sh 完成）
# ============================================================
echo "=== Phase 5.5: Verify anchor state ==="
CURRENT_ANCHOR=$(cast call --rpc-url "$L1_RPC_URL" "$ANCHOR_STATE_REGISTRY_ADDRESS" \
    "anchors(uint32)(bytes32,uint256)" "$TEE_GAME_TYPE" 2>/dev/null | head -1 || echo "")
echo "  Anchor root: $CURRENT_ANCHOR"

DEAD_SENTINEL="0xdead000000000000000000000000000000000000000000000000000000000000"
if [ "$CURRENT_ANCHOR" = "$DEAD_SENTINEL" ] || [ -z "$CURRENT_ANCHOR" ] || [ "$CURRENT_ANCHOR" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    echo "  ERROR: Anchor state is still sentinel/zero. Bootstrap may have failed."
    exit 1
fi
echo "  Anchor state OK."
echo ""

# ============================================================
# Phase 6: 执行测试
# ============================================================
echo "=== Phase 6: Run test scenarios ==="
PASS=0
FAIL=0

run_test() {
    local name=$1
    local script=$2
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if bash "$script"; then
        echo "✓ PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# 注意顺序：B（Prove Timeout）会产生 CHALLENGER_WINS 级联，必须放最后。
# 父 game 是 CHALLENGER_WINS 后，所有后续子 game 都会自动判负。
run_test "Scenario E: Proposer Creates Game" "$E2E_DIR/tee/test_proposer_create.sh"
run_test "Scenario A: Defend Success" "$E2E_DIR/tee/test_defend_success.sh"
run_test "Scenario B: Prove Timeout" "$E2E_DIR/tee/test_prove_timeout.sh"
run_test "Scenario C: Unchallenged" "$E2E_DIR/tee/test_unchallenged.sh"
run_test "Scenario F: Prove Retry" "$E2E_DIR/tee/test_prove_retry.sh"

# ============================================================
# Phase 7: 结果汇总
# ============================================================
echo ""
echo "========================================"
echo "  TEE E2E Test Results"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  Total: $((PASS + FAIL))"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Some tests FAILED. Check logs:"
    echo "  docker logs tee-op-proposer"
    echo "  docker logs tee-op-challenger"
    echo "  cat /tmp/mockteerpc.log"
    echo "  cat /tmp/mock-tee-prover.log"
    exit 1
fi

exit 0
