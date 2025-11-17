#!/bin/bash

set -e

source .env

set -x

if [ "$RPC_TYPE" = "geth" ]; then
  OP_GETH_GENESIS_JSON="$(pwd)/config-op/genesis.json"
  OP_GETH_RPC_DATADIR="$(pwd)/data/op-geth-rpc"
  docker run --rm -v $OP_GETH_RPC_DATADIR:/datadir -v $OP_GETH_GENESIS_JSON:/genesis.json $OP_GETH_IMAGE_TAG init --datadir /datadir /genesis.json
  sleep 3
fi

docker compose up -d op-rpc
