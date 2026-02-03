#!/bin/bash
# Wrapper script to run cannon in Docker
# Usage: ./cannon.sh <command> [args...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"

# Ensure work directory exists
mkdir -p "${WORK_DIR}"

# Run cannon in docker
docker run --rm \
    -v "${SCRIPT_DIR}/../bin:/app/bin:ro" \
    -v "${WORK_DIR}:/work" \
    -w /work \
    cannon-runner \
    "$@"
