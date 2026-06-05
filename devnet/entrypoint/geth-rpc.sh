#!/bin/sh

set -e

exec geth \
      --verbosity=3 \
      --datadir=/datadir \
      --db.engine=${DB_ENGINE:-pebble} \
      --config=/config.toml \
      --gcmode=archive \
      --rollup.txpool.trusted-peers-only \
      --rollup.enabletxpooladmission \
      --txpool.pricelimit=0 \
      --rollup.allow-gasless=true
