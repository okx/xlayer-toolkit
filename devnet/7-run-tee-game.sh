#!/bin/bash
set -e

source .env

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts

ENCLAVE_ADDRESS=$(cast wallet address --private-key "$OP_CHALLENGER_PRIVATE_KEY")

echo "🔧 Adding TEE game type..."
echo "   Image:           $OP_CONTRACTS_TEE_IMAGE_TAG"
echo "   Enclave address: $ENCLAVE_ADDRESS"

# Create a temp .env with L1_RPC_URL replaced by docker-internal URL,
# because add-tee-game-type.sh sources .env internally and would overwrite -e overrides.
TEMP_ENV=$(mktemp)
trap "rm -f $TEMP_ENV" EXIT
sed "s|^L1_RPC_URL=.*|L1_RPC_URL=$L1_RPC_URL_IN_DOCKER|" .env > "$TEMP_ENV"

docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/scripts:/devnet/scripts" \
  -v "$TEMP_ENV:/devnet/.env" \
  "$OP_CONTRACTS_TEE_IMAGE_TAG" \
  bash /devnet/scripts/add-tee-game-type.sh \
    --max-challenge-duration 120 \
    --max-prove-duration 60 \
    --mock-verifier \
    --enclave "$ENCLAVE_ADDRESS" \
    /app/packages/contracts-bedrock

echo "🚀 Starting mockteerpc..."
docker compose up -d mockteerpc

echo "🚀 Starting tee-proposer..."
docker compose up -d tee-proposer

echo "🚀 Starting tee-challenger..."
docker compose up -d tee-challenger

echo "✅ TEE game setup complete!"
