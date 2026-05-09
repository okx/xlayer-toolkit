#!/usr/bin/env bash
# Shared shell helpers for cross_check.sh and bench_full.sh.
# Source me as: . "$REPO_ROOT/scripts/lib.sh"

# Print an actionable "missing dependency" diagnostic to stderr and return
# non-zero. Callers run under `set -e`, so the failed `||` chain makes the
# whole script abort. Using `return` (not `exit`) keeps the contract local —
# refactoring callers does not depend on this function's process-exit
# semantics.
#
# Uses ${0##*/} so the message names the entry-point script (cross_check.sh
# or bench_full.sh) automatically — $0 is preserved across function calls.
preflight_fail() {
    echo "" >&2
    echo "ERROR: ${0##*/} prerequisite missing: $1" >&2
    echo "       $2" >&2
    echo "" >&2
    return 1
}

# Verify a command is on PATH; preflight_fail otherwise.
require_command() {
    command -v "$1" >/dev/null 2>&1 || preflight_fail "$1" "$2"
}

# Locate circom and export the absolute path as $CIRCOM. Prefer
# ~/.cargo/bin/circom — the path used by the official install instruction
# `cargo install --git https://github.com/iden3/circom` — to avoid silently
# picking up an older system-installed circom that may not support the
# pragma version our circuits declare.
detect_circom() {
    if [ -x "$HOME/.cargo/bin/circom" ]; then
        CIRCOM="$HOME/.cargo/bin/circom"
    elif command -v circom >/dev/null 2>&1; then
        CIRCOM="$(command -v circom)"
    else
        preflight_fail "circom" \
            "Install via: cargo install --git https://github.com/iden3/circom"
    fi
}

# Map an arbitrary human-readable label (e.g. "T2 hash1(0)", "fuzz[1] T8")
# to a path-safe filename. printf avoids the trailing newline `echo` would
# inject; `tr -c` maps every character outside [A-Za-z0-9._-] to `_`;
# `tr -s '_'` collapses runs so the result stays compact.
slugify() {
    printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]._-' '_' | tr -s '_'
}
