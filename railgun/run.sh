#!/bin/bash
set -e

export USE_LOCAL_CIRCUITS=true

# Build circuits
[ "$USE_LOCAL_CIRCUITS" = "true" ] && ./build-circuits-v2.sh

# Clone and patch contract
if [ ! -d "contract" ]; then
    git clone https://github.com/Railgun-Privacy/contract.git
    cd contract
    git apply ../0001-add-railgun-demo.patch
    git apply ../0002-add-local-circuits-support.patch
else
    cd contract
fi

./run.sh
