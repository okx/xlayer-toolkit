#!/bin/bash

set -e

source /.env

INDEX=${1:-""}

exec entrypoint \
      --external-state-root \
      --l2-url=http://op-"${SEQ_TYPE}"-seq"${INDEX}":8552 \
      --l2-jwt-path=/jwt.txt \
      --l2-timeout=1000 \
      --builder-url=http://op-rbuilder"${INDEX}":8552 \
      --builder-jwt-path=/jwt.txt \
      --builder-timeout=1000 \
      --flashblocks \
      --flashblocks-builder-url=ws://op-rbuilder"${INDEX}":1111 \
      --flashblocks-host=0.0.0.0 \
      --flashblocks-port=1111 \
      --rpc-host=0.0.0.0 \
      --rpc-port=8552 \
      --tracing \
      --log-level=info \
      --debug-host=0.0.0.0 \
      --debug-server-port=5555
