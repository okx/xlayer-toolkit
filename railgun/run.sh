#!/bin/bash
set -e
export USE_LOCAL_CIRCUITS=true

if [ "$USE_LOCAL_CIRCUITS" = "true" ]; then
    if [ ! -d "circuits-v2" ]; then
        git clone https://github.com/Railgun-Privacy/circuits-v2.git
        cd circuits-v2
        git apply ../0001-circuits-v2-macos-fix.patch
    else
        cd circuits-v2
    fi
    [ ! -d "node_modules" ] && npm install
    npm run build
    mkdir -p zkeys bin
    POT_FILE="bin/pot.ptau"
    [ ! -f "$POT_FILE" ] && curl -L "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau" -o "$POT_FILE"
    for r1cs_file in build/*.r1cs; do
        [ -f "$r1cs_file" ] || continue
        name=$(basename "$r1cs_file" .r1cs)
        [ ! -f "zkeys/${name}.zkey" ] && npx snarkjs groth16 setup "$r1cs_file" "$POT_FILE" "zkeys/${name}.zkey"
        [ ! -f "zkeys/${name}.vkey.json" ] && npx snarkjs zkey export verificationkey "zkeys/${name}.zkey" "zkeys/${name}.vkey.json"
    done
    cd ..
fi

if [ ! -d "contract" ]; then
    git clone https://github.com/Railgun-Privacy/contract.git
    cd contract
    git apply ../0001-add-railgun-demo.patch
    git apply ../0002-add-local-circuits-support.patch
else
    cd contract
fi

./run.sh
