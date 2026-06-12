#!/bin/sh

set -e

CMD="geth \
      --verbosity=3 \
      --datadir=/datadir \
      --db.engine=${DB_ENGINE:-pebble} \
      --config=/config.toml \
      --gcmode=archive \
      --rollup.txpool.trusted-peers-only \
      --rollup.enabletxpooladmission \
      --rollup.gasless-mock-gas-price-percentile=${GASLESS_MOCK_GAS_PRICE_PERCENTILE:-0.1}"

# Enable XLayer gasless flag to forward gasless (0-price) txs to the sequencer node.
if [ "${ENABLE_GASLESS:-false}" = "true" ]; then
    CMD="$CMD --rollup.allow-gasless"
fi

exec $CMD
