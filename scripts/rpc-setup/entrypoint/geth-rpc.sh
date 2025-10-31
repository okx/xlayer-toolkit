#!/bin/bash

set -e

source /app/.env

echo "SEQUENCER_HTTP_URL: ${SEQUENCER_HTTP_URL}"

exec geth \
  --verbosity=3 \
  --datadir=/data \
  --config=/config.toml \
  --db.engine=pebble \
  --gcmode=archive \
  --rollup.enabletxpooladmission \
  --rollup.sequencerhttp=${SEQUENCER_HTTP_URL} \
  --log.file=/var/log/op-geth/geth.log

