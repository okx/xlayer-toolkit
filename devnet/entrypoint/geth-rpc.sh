#!/bin/sh

set -e

exec geth \
      --verbosity=3 \
      --datadir=/datadir \
      --db.engine=${DB_ENGINE:-pebble} \
      --config=/config.toml \
      --gcmode=archive \
      --rollup.enabletxpooladmission
