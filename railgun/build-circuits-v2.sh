#!/bin/bash
set -e

# Clone and patch circuits-v2
if [ ! -d "circuits-v2" ]; then
    git clone https://github.com/Railgun-Privacy/circuits-v2.git
    cd circuits-v2
    git apply ../0001-circuits-v2-macos-fix.patch
else
    cd circuits-v2
fi

# Install and build
[ ! -d "node_modules" ] && npm install
npm run prepare
./scripts/generate_circuits
./scripts/compile_circuits

# Download Powers of Tau
mkdir -p zkeys bin
POT_FILE="bin/pot.ptau"
[ ! -f "$POT_FILE" ] && curl -L "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau" -o "$POT_FILE"

# Generate zkey and vkey for each circuit
for r1cs_file in build/*.r1cs; do
    [ -f "$r1cs_file" ] || continue
    name=$(basename "$r1cs_file" .r1cs)
    [ ! -f "zkeys/${name}.zkey" ] && npx snarkjs groth16 setup "$r1cs_file" "$POT_FILE" "zkeys/${name}.zkey"
    [ ! -f "zkeys/${name}.vkey.json" ] && npx snarkjs zkey export verificationkey "zkeys/${name}.zkey" "zkeys/${name}.vkey.json"
done

echo "✅ Circuit build complete!"
