#!/bin/bash
# build-tee-images.sh — 构建 TEE Docker 镜像 + 安装宿主机 Mock 组件
set -e

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEVNET_DIR/.tee.env"

echo "========================================"
echo "  Building TEE Images & Components"
echo "========================================"

# 1. 构建 TEE OP Stack 镜像（op-proposer TEE + op-challenger TEE）
if [ "$SKIP_TEE_OP_STACK_BUILD" != "true" ]; then
    echo "=== Building TEE OP Stack image ==="
    if [ -n "$TEE_OP_STACK_LOCAL_DIRECTORY" ]; then
        SRC_DIR="$TEE_OP_STACK_LOCAL_DIRECTORY"
    else
        SRC_DIR="/tmp/optimism-tee"
        if [ -d "$SRC_DIR" ]; then
            echo "Updating existing clone at $SRC_DIR..."
            (cd "$SRC_DIR" && git fetch origin && git checkout "$TEE_OP_STACK_BRANCH" && git pull)
        else
            echo "Cloning optimism ($TEE_OP_STACK_BRANCH)..."
            git clone --branch "$TEE_OP_STACK_BRANCH" --depth 1 \
                https://github.com/okx/optimism.git "$SRC_DIR"
        fi
    fi
    echo "Building image: $TEE_OP_STACK_IMAGE_TAG"
    docker build -t "$TEE_OP_STACK_IMAGE_TAG" \
        -f "$SRC_DIR/ops/docker/op-stack-go/Dockerfile" "$SRC_DIR"
    echo "TEE OP Stack image built: $TEE_OP_STACK_IMAGE_TAG"
else
    echo "Skipping TEE OP Stack build (SKIP_TEE_OP_STACK_BUILD=true)"
fi

# 2. 构建 TEE 合约镜像
if [ "$SKIP_TEE_CONTRACTS_BUILD" != "true" ]; then
    echo "=== Building TEE contracts image ==="
    if [ -n "$TEE_CONTRACTS_LOCAL_DIRECTORY" ]; then
        CONTRACTS_DIR="$TEE_CONTRACTS_LOCAL_DIRECTORY"
    else
        CONTRACTS_DIR="/tmp/optimism-tee-contracts"
        if [ -d "$CONTRACTS_DIR" ]; then
            echo "Updating existing clone at $CONTRACTS_DIR..."
            (cd "$CONTRACTS_DIR" && git fetch origin && git checkout "$TEE_CONTRACTS_BRANCH" && git pull)
        else
            echo "Cloning optimism ($TEE_CONTRACTS_BRANCH)..."
            git clone --branch "$TEE_CONTRACTS_BRANCH" --depth 1 \
                https://github.com/okx/optimism.git "$CONTRACTS_DIR"
        fi
    fi
    echo "Building image: $TEE_CONTRACTS_IMAGE_TAG"
    docker build -t "$TEE_CONTRACTS_IMAGE_TAG" \
        -f "$CONTRACTS_DIR/ops/docker/op-stack-go/Dockerfile" "$CONTRACTS_DIR"
    echo "TEE contracts image built: $TEE_CONTRACTS_IMAGE_TAG"
else
    echo "Skipping TEE contracts build (SKIP_TEE_CONTRACTS_BUILD=true)"
fi

# 3. 安装宿主机 Mock 组件
echo ""
echo "=== Installing Mock components on host ==="

# 3a. 安装 mockteerpc（从 op-proposer TEE 分支）
echo "--- Installing mockteerpc ---"
if [ -n "$TEE_OP_STACK_LOCAL_DIRECTORY" ]; then
    PROPOSER_SRC="$TEE_OP_STACK_LOCAL_DIRECTORY"
elif [ -d "/tmp/optimism-tee" ]; then
    PROPOSER_SRC="/tmp/optimism-tee"
else
    echo "WARNING: No optimism source available for mockteerpc installation."
    echo "  Set TEE_OP_STACK_LOCAL_DIRECTORY or run with SKIP_TEE_OP_STACK_BUILD=false first."
    PROPOSER_SRC=""
fi

if [ -n "$PROPOSER_SRC" ] && [ -d "$PROPOSER_SRC/op-proposer/mock" ]; then
    (cd "$PROPOSER_SRC/op-proposer" && go install ./mock/cmd/mockteerpc)
    echo "mockteerpc installed to $(go env GOPATH)/bin/mockteerpc"
else
    echo "Skipping mockteerpc installation (source not found)"
fi

# 3b. 编译 mock-tee-prover
echo "--- Building mock-tee-prover ---"
MOCK_PROVER_DIR="$DEVNET_DIR/e2e/mock-tee-prover"
if [ -d "$MOCK_PROVER_DIR" ]; then
    (cd "$MOCK_PROVER_DIR" && go build -o mock-tee-prover .)
    echo "mock-tee-prover built at: $MOCK_PROVER_DIR/mock-tee-prover"
else
    echo "WARNING: mock-tee-prover source not found at $MOCK_PROVER_DIR"
fi

echo ""
echo "========================================"
echo "  Build complete!"
echo "========================================"
