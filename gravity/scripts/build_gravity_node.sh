#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAVITY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$GRAVITY_DIR/gravity-sdk" && make gravity_node
