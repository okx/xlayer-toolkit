#!/bin/sh

set -e

CMD="geth \
      --verbosity=3 \
      --datadir=/datadir \
      --db.engine=${DB_ENGINE:-pebble} \
      --config=/config.toml \
      --gcmode=archive \
      --rollup.txpool.trusted-peers-only \
      --rollup.enabletxpooladmission"

# Enable XLayer gasless flags only on builds that include gasless; blacklist-only op-geth doesn't have them.
if [ "${ENABLE_GASLESS:-false}" = "true" ]; then
    CMD="$CMD --rollup.allow-gasless"
    CMD="$CMD --rollup.gasless-mock-gas-price-percentile=${GASLESS_MOCK_GAS_PRICE_PERCENTILE:-0.1}"
fi

exec $CMD
