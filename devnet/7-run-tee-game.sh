#!/bin/bash
set -e

source .env

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts

# Check required images exist
MISSING_IMAGES=()
for IMG_VAR in OP_CONTRACTS_TEE_IMAGE_TAG OP_STACK_TEE_IMAGE_TAG MOCKTEERPC_IMAGE_TAG; do
  IMG="${!IMG_VAR}"
  if ! docker image inspect "$IMG" > /dev/null 2>&1; then
    MISSING_IMAGES+=("$IMG_VAR=$IMG")
  fi
done

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
  echo "❌ The following required Docker images are missing:"
  for ENTRY in "${MISSING_IMAGES[@]}"; do
    echo "   - $ENTRY"
  done
  echo ""
  echo "To build them, set the corresponding SKIP flags to 'false' in .env:"
  for ENTRY in "${MISSING_IMAGES[@]}"; do
    VAR_NAME="${ENTRY%%=*}"
    case "$VAR_NAME" in
      OP_CONTRACTS_TEE_IMAGE_TAG) echo "   SKIP_OP_CONTRACTS_TEE_BUILD=false" ;;
      OP_STACK_TEE_IMAGE_TAG)     echo "   SKIP_OP_STACK_TEE_BUILD=false" ;;
      MOCKTEERPC_IMAGE_TAG)       echo "   SKIP_MOCKTEERPC_BUILD=false" ;;
    esac
  done
  echo ""
  echo "Then run:  bash init.sh"
  echo ""
  echo "After init.sh completes, re-run this script:  bash 7-run-tee-game.sh"
  exit 1
fi

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
echo ""
echo "To list all games, run:"
echo "   bash scripts/list-game.sh"
