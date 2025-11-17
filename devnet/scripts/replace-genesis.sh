#!/bin/bash
set -e

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

ROOT_DIR=$(git rev-parse --show-toplevel)

# TODO: change to the real location of genesis file
NEW_GENESIS_FILE="$ROOT_DIR/../genesis.json"

TESTING_GENESIS_FILE="$ROOT_DIR/test/config-op/genesis.json"

if [ -f ${TESTING_GENESIS_FILE} ]; then
    mv ${TESTING_GENESIS_FILE} ${TESTING_GENESIS_FILE}.bak
fi

cp ${NEW_GENESIS_FILE} ${TESTING_GENESIS_FILE}

current_timestamp=$(date +%s)
hex_timestamp=$(printf "0x%x\n" "$current_timestamp")
echo "hex_timestamp: $hex_timestamp"

sed_inplace "s/\"timestamp\": \"0x[0-9a-fA-F]*\"/\"timestamp\": \"$hex_timestamp\"/" ${TESTING_GENESIS_FILE}
