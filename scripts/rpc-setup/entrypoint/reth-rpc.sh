#!/bin/bash

set -e
source /app/.env
echo "SEQUENCER_HTTP_URL: ${SEQUENCER_HTTP_URL}"
echo "OP_GETH_BOOTNODE: ${OP_GETH_BOOTNODE}"
exec op-reth node \
      --datadir=/datadir \
      --chain=/genesis.json \
      --config=/config.toml \
      --http \
      --http.corsdomain=* \
      --http.port=8545 \
      --http.addr=0.0.0.0 \
      --http.api=web3,debug,eth,txpool,net,miner \
      --ws \
      --ws.addr=0.0.0.0 \
      --ws.port=7546 \
      --ws.origins=* \
      --ws.api=debug,eth,txpool,net \
      --disable-discovery \
      --max-outbound-peers=0 \
      --max-inbound-peers=0 \
      --authrpc.addr=0.0.0.0 \
      --authrpc.port=8552 \
      --authrpc.jwtsecret=/jwt.txt \
      --rollup.disable-tx-pool-gossip \
      --rollup.sequencer-http=${SEQUENCER_HTTP_URL} \
      --bootnodes=${OP_GETH_BOOTNODE}