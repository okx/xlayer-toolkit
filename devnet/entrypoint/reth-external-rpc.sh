#!/bin/bash

set -e

source /.env

# Enable jemalloc profiling if requested
# Note: tikv-jemalloc (used by Rust) uses _RJEM_MALLOC_CONF, not MALLOC_CONF
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

# Read the first argument (1 or 0), default to 0 if not provided
FLASHBLOCKS_RPC=${FLASHBLOCKS_RPC:-"true"}

# Build the command with common arguments
#      --trusted-peers=enode://da6f07c5216e51cfab6320ffeebc6e8fadbb8ce32d489c8dedba9f910fa91b82a534ecef67a42202e7beb92313ee9023bd6dd9a9b2548d175baabf3842dc3053@op-geth-rpc:30303 \
CMD="op-reth node \
      --datadir=/datadir \
      --chain=/genesis.json \
      --config=/config.toml \
      --http \
      --http.corsdomain=* \
      --http.port=8545 \
      --http.addr=0.0.0.0 \
      --http.api=web3,debug,eth,txpool,net,miner,admin \
      --ws \
      --ws.addr=0.0.0.0 \
      --ws.port=7546 \
      --ws.origins=* \
      --ws.api=web3,debug,eth,txpool,net \
      --disable-discovery \
      --max-outbound-peers=10 \
      --max-inbound-peers=10 \
      --authrpc.addr=0.0.0.0 \
      --authrpc.port=8552 \
      --authrpc.jwtsecret=/jwt.txt \
      --trusted-peers=enode://0e7f8211528ab10718a0c7f4e55db3c7342fe9e21b42112770168b82ff0b3864b2edff8f49c7ae753cab57ceb0d87bfdd433559b82d449a55c0076723d95d790@op-geth-rpc:30303 \
      --tx-propagation-policy=trusted \
      --txpool.max-account-slots=100000 \
      --txpool.pending-max-count=100000 \
      --txpool.queued-max-count=100000 \
      --txpool.basefee-max-count=100000 \
      --txpool.max-pending-txns=100000 \
      --txpool.max-new-txns=100000 \
      --rpc.eth-proof-window=10000 \
      --rollup.sequencer-http=http://op-geth-rpc:8545"

# For flashblocks architecture. Enable flashblocks RPC
if [ "$FLASHBLOCK_ENABLED" = "true" ] && [ "$FLASHBLOCKS_RPC" = "true" ]; then
    CMD="$CMD \
        --flashblocks-url=ws://op-reth-seq:1111"
fi

exec $CMD
