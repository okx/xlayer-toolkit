#!/bin/bash

set -x
set -e

BRANCH_NAME=${1:-""}
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIMISM_DIR=$(git rev-parse --show-toplevel)

[ ! -f .env ] && cp example.env .env

source .env

if [ "$OP_GETH_LOCAL_DIRECTORY" = "" ]; then
    git submodule update --init --recursive
    OP_GETH_DIR="$OPTIMISM_DIR/op-geth"
else
    OP_GETH_DIR="$OP_GETH_LOCAL_DIRECTORY"
fi

# Switch to specified branch if provided
if [ -n "$OP_GETH_BRANCH" ]; then
    echo "Switching op-geth to branch: $OP_GETH_BRANCH"
    cd $OP_GETH_DIR
    git fetch origin
    git checkout "$OP_GETH_BRANCH"
    git pull origin "$OP_GETH_BRANCH"
    cd "$PWD_DIR"
else
    echo "Using op-geth default branch"
fi

# TODO: need to further confirm why it fails if we do not add require in this contract
cp $PWD_DIR/contracts/Transactor.sol $OPTIMISM_DIR/packages/contracts-bedrock/src/periphery/Transactor.sol

cd $OPTIMISM_DIR

# Build OP_CONTRACTS image if not skipping
if [ $SKIP_OP_CONTRACTS_BUILD = "true" ]; then
    echo "skipping op-contracts build"
else
    echo "Building $OP_CONTRACTS_IMAGE_TAG..."
    docker build -t $OP_CONTRACTS_IMAGE_TAG -f ./Dockerfile-contracts .
fi

# Build OP_STACK image if not skipping
if [ $SKIP_OP_STACK_BUILD = "true" ]; then
    echo "skipping op-stack build"
else
    echo "Building $OP_STACK_IMAGE_TAG..."
    docker build -t $OP_STACK_IMAGE_TAG -f ./Dockerfile-opstack .
fi

# Build OP_GETH image if not skipping
if [ $SKIP_OP_GETH_BUILD = "true" ]; then
    echo "skipping op-geth build"
else
    echo "Building $OP_GETH_IMAGE_TAG"
    cd $OP_GETH_DIR
    docker build -t $OP_GETH_IMAGE_TAG .
fi

# Build OP_RETH image if not skipping
if [ $SKIP_OP_RETH_BUILD = "true" ]; then
    echo "skipping op-reth build"
else
    if [ "$OP_RETH_LOCAL_DIRECTORY" = "" ]; then
        echo "Please set OP_RETH_LOCAL_DIRECTORY in .env"
        exit 1
    else
        echo "Building $OP_RETH_IMAGE_TAG"
        cd $OP_RETH_LOCAL_DIRECTORY
        if [ -n "$OP_RETH_BRANCH" ]; then
            echo "Switching op-reth to branch: $OP_RETH_BRANCH"
            git fetch origin
            git checkout "$OP_RETH_BRANCH"
            git pull origin "$OP_RETH_BRANCH"
        else
            echo "Using op-reth branch: $(git branch --show-current)"
        fi
        docker build -t $OP_RETH_IMAGE_TAG -f ./DockerfileOp .
        cd $OPTIMISM_DIR
    fi
fi
