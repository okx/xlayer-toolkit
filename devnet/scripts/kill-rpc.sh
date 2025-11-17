#!/bin/bash

set -e

source .env

set -x

docker compose kill op-$RPC_TYPE-rpc
docker compose kill op-rpc
docker rm -f op-$RPC_TYPE-rpc
docker rm -f op-rpc
rm -rf data/op-$RPC_TYPE-rpc
rm -rf data/op-rpc
