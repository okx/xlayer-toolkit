#!/bin/bash
# ============================================================================
# Common utility functions for devnet scripts
# ============================================================================

# Cross-platform sed in-place edit function
# Usage: sed_inplace 's/old/new/' file
sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

