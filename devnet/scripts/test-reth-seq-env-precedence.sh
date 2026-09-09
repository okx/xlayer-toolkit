#!/bin/bash
# Regression test for devnet/entrypoint/reth-seq.sh environment precedence.
#
# Docker Compose injects a per-sequencer RCS_BASE_URL (http://rcsN:9195) into
# each op-reth-seqN container. The entrypoint sources the shared /.env, whose
# own RCS_BASE_URL must not override the injected per-sequencer value.
#
# A fake op-reth records the RCS_BASE_URL it is exec'd with, so no Docker
# runtime is required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${ENTRYPOINT:-$SCRIPT_DIR/../entrypoint/reth-seq.sh}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Fake op-reth: ignore the --help probe, otherwise record the environment the
# entrypoint exec's it with.
cat > "$WORKDIR/op-reth" <<'EOF'
#!/bin/bash
case " $* " in
    *" --help "*) exit 0 ;;
esac
printf '%s\n' "${RCS_BASE_URL:-<unset>}" > "${RCS_CAPTURE_FILE:?RCS_CAPTURE_FILE not set}"
EOF
chmod +x "$WORKDIR/op-reth"

# run_case <name> <injected RCS_BASE_URL> <shared .env value> <expected>
run_case() {
    local name="$1" injected="$2" shared_env="$3" expected="$4"
    local env_file="$WORKDIR/$name.env"
    printf 'RCS_BASE_URL=%s\n' "$shared_env" > "$env_file"

    local captured="$WORKDIR/$name.captured"
    (
        ENV_FILE="$env_file" \
        RCS_CAPTURE_FILE="$captured" \
        PATH="$WORKDIR:$PATH" \
        RCS_BASE_URL="$injected" \
        "$ENTRYPOINT"
    )
    local got
    if [ ! -f "$captured" ]; then
        echo "FAIL: $name: entrypoint did not exec op-reth (no capture file)" >&2
        return 1
    fi
    got="$(cat "$captured")"
    if [ "$got" != "$expected" ]; then
        echo "FAIL: $name: expected RCS_BASE_URL=$expected, got $got" >&2
        return 1
    fi
    echo "PASS: $name -> RCS_BASE_URL=$got"
}

# Case 1 — Compose-injected per-sequencer URL must win over the shared .env value.
run_case "injected-overrides-shared" "http://rcs2:9195" "http://shared-host:9195" "http://rcs2:9195"

# Case 2 — no injected value: the shared .env value is left in place (guard's false branch).
run_case "no-injection-keeps-shared" "" "http://shared-host:9195" "http://shared-host:9195"

echo "All reth-seq env precedence checks passed."
