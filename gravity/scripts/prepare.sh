#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAVITY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$GRAVITY_DIR"

git clone -b gravity-v0.4.1 https://github.com/Galxe/gravity-reth.git

git clone -b v0.4.1 https://github.com/Galxe/gravity-sdk.git

cd $GRAVITY_DIR/gravity-reth && git apply ../0001-local-testing.patch

cd $GRAVITY_DIR && ./scripts/add_patch.sh
