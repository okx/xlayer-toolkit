#!/bin/bash
# Regression test for devnet/entrypoint/reth-seq.sh environment precedence.
#
# Docker Compose injects a per-sequencer RCS_BASE_URL (http://rcsN:9195) into
# each op-reth-seqN container. The entrypoint sources the shared /.env, whose
# own RCS_BASE_URL must not override the injected per-sequencer value; and when
# nothing is injected, the entrypoint must still export the shared value so
# op-reth (which reads RCS_BASE_URL from its environment) receives it.
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

# run_case <name> <mode> <injected value> <shared .env value> <expected>
#   mode: inject = RCS_BASE_URL present (Compose injection)
#         unset  = RCS_BASE_URL truly absent (env -u RCS_BASE_URL)
#         empty  = RCS_BASE_URL present but empty ("")
run_case() {
    local name="$1" mode="$2" injected="$3" shared_env="$4" expected="$5"
    local env_file="$WORKDIR/$name.env"
    printf 'RCS_BASE_URL=%s\n' "$shared_env" > "$env_file"   # plain, non-exported

    local captured="$WORKDIR/$name.captured"
    case "$mode" in
        unset)
            env -u RCS_BASE_URL \
                ENV_FILE="$env_file" RCS_CAPTURE_FILE="$captured" PATH="$WORKDIR:$PATH" \
                "$ENTRYPOINT" ;;
        *)  # inject / empty: the variable exists (possibly empty)
            ENV_FILE="$env_file" RCS_CAPTURE_FILE="$captured" PATH="$WORKDIR:$PATH" \
                RCS_BASE_URL="$injected" "$ENTRYPOINT" ;;
    esac

    local got
    [ -f "$captured" ] || { echo "FAIL: $name: entrypoint did not exec op-reth (no capture file)" >&2; return 1; }
    got="$(cat "$captured")"
    [ "$got" = "$expected" ] || { echo "FAIL: $name: expected RCS_BASE_URL=$expected, got $got" >&2; return 1; }
    echo "PASS: $name -> RCS_BASE_URL=$got"
}

# Case 1 (binding) — Compose-injected per-sequencer URL wins over the shared .env value.
run_case "injected-overrides-shared"   inject "http://rcs2:9195" "http://shared-host:9195" "http://rcs2:9195"
# Case 2 (binding, fixed) — genuinely NOT injected (env -u): the shared value must be exported to op-reth.
run_case "no-injection-keeps-shared"    unset  ""                "http://shared-host:9195" "http://shared-host:9195"
# Case 3 (defensive gray zone) — injected-but-empty is treated as not-injected; shared value applies.
run_case "empty-injection-keeps-shared" empty  ""                "http://shared-host:9195" "http://shared-host:9195"

echo "All reth-seq env precedence checks passed."
