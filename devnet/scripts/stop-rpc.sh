#!/bin/bash

set -e

source .env

set -x

docker compose kill op-$RPC_TYPE-rpc
docker compose kill op-rpc
