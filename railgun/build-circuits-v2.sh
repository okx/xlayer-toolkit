#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIRCUITS_DIR="$SCRIPT_DIR/circuits-v2"

echo "=========================================="
echo "🔧 Building circuits-v2"
echo "=========================================="

# Clone if not exists
if [ ! -d "$CIRCUITS_DIR" ]; then
    echo "📥 Cloning circuits-v2..."
    git clone https://github.com/Railgun-Privacy/circuits-v2.git "$CIRCUITS_DIR"
    
    # Apply patch after clone
    cd "$CIRCUITS_DIR"
    echo "🔧 Applying patch..."
    git apply ../0001-circuits-v2-macos-fix.patch
    echo "  ✅ Applied 0001-circuits-v2-macos-fix.patch"
else
    echo "📁 circuits-v2 directory already exists"
fi

cd "$CIRCUITS_DIR"

# Install dependencies
if [ ! -d "node_modules" ]; then
    echo "📦 Installing dependencies..."
    npm install
fi

# Step 1: Prepare (fetch circom binary)
echo "🔧 Step 1: Fetching circom..."
npm run prepare

# Step 2: Generate circuit files
echo "📝 Step 2: Generating circuit files..."
./scripts/generate_circuits

# Step 3: Compile circuits (generates wasm, r1cs)
echo "⚙️  Step 3: Compiling circuits..."
./scripts/compile_circuits

# Step 4: Generate zkeys (trusted setup)
echo "🔐 Step 4: Generating zkeys (this may take a while)..."
mkdir -p zkeys

# Download Powers of Tau if not exists
POT_FILE="bin/pot.ptau"
if [ ! -f "$POT_FILE" ]; then
    echo "📥 Downloading Powers of Tau..."
    curl -L "https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_20.ptau" -o "$POT_FILE"
fi

# Generate zkey and vkey for each circuit
echo "🔑 Generating zkey and vkey for each circuit..."

# Get list of compiled circuits
for r1cs_file in build/*.r1cs; do
    if [ -f "$r1cs_file" ]; then
        circuit_name=$(basename "$r1cs_file" .r1cs)
        zkey_file="zkeys/${circuit_name}.zkey"
        vkey_file="zkeys/${circuit_name}.vkey.json"
        
        if [ ! -f "$zkey_file" ]; then
            echo "  🔐 Generating ${circuit_name}.zkey..."
            npx snarkjs groth16 setup "$r1cs_file" "$POT_FILE" "$zkey_file"
        else
            echo "  ✅ ${circuit_name}.zkey already exists"
        fi
        
        if [ ! -f "$vkey_file" ]; then
            echo "  📤 Exporting ${circuit_name}.vkey.json..."
            npx snarkjs zkey export verificationkey "$zkey_file" "$vkey_file"
        else
            echo "  ✅ ${circuit_name}.vkey.json already exists"
        fi
    fi
done

echo ""
echo "=========================================="
echo "✅ Circuit build complete!"
echo "=========================================="
echo ""
echo "Generated files:"
echo "  📁 $CIRCUITS_DIR/build/     - WASM and R1CS files"
echo "  📁 $CIRCUITS_DIR/zkeys/     - ZKey and VKey files"
echo ""
