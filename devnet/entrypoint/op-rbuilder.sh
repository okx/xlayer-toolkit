#!/bin/bash

set -e

source /.env

# Enable jemalloc profiling if requested
# Note: tikv-jemalloc (used by Rust) uses _RJEM_MALLOC_CONF, not MALLOC_CONF
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

exec op-rbuilder node \
      --datadir=/datadir \
      --chain=/genesis.json \
      --http \
      --http.corsdomain=* \
      --http.port=8545 \
      --http.addr=0.0.0.0 \
      --http.api=web3,debug,eth,txpool,net,miner \
      --disable-discovery \
      --max-outbound-peers=10 \
      --max-inbound-peers=10 \
      --authrpc.addr=0.0.0.0 \
      --authrpc.port=8552 \
      --authrpc.jwtsecret=/jwt.txt \
      --trusted-peers="${TRUSTED_PEERS}" \
      --tx-propagation-policy=all \
      --txpool.max-account-slots=100000 \
      --txpool.pending-max-count=100000 \
      --txpool.queued-max-count=100000 \
      --txpool.basefee-max-count=100000 \
      --txpool.max-pending-txns=100000 \
      --txpool.max-new-txns=100000 \
      --txpool.pending-max-size=2000 \
      --txpool.basefee-max-size=2000 \
      --flashblocks.enabled \
      --flashblocks.disable-state-root \
      --flashblocks.addr=0.0.0.0 \
      --flashblocks.port=1111 \
      --flashblocks.block-time=200
