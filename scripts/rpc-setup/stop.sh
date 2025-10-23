#!/bin/bash
# scripts/stop.sh

set -e

echo "🛑 Stopping X Layer RPC node..."

# Stop Docker services
docker compose down

echo "✅ X Layer RPC node has been stopped"
