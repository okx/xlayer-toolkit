#!/bin/bash

rcs_is_boolean() {
    case "$1" in true|false) return 0 ;; *) return 1 ;; esac
}

rcs_service_suffix() {
    local index="$1"
    if ! [[ "$index" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ RCS service index must be a positive integer, got: '$index'" >&2
        return 1
    fi
    [ "$index" -eq 1 ] || printf '%s' "$index"
}

rcs_service_name() {
    local suffix
    suffix=$(rcs_service_suffix "$1") || return 1
    printf 'rcs%s\n' "$suffix"
}

rcs_seq_service_name() {
    local index="$1" seq_type="$2" suffix
    suffix=$(rcs_service_suffix "$index") || return 1
    printf 'op-%s-seq%s\n' "$seq_type" "$suffix"
}

rcs_l2_endpoint() {
    local index="$1" rpc_count="$2" rpc_type="$3" seq_type="$4" suffix
    suffix=$(rcs_service_suffix "$index") || return 1
    if [ "$index" -le "$rpc_count" ]; then
        printf 'http://op-%s-rpc%s:8545\n' "$rpc_type" "$suffix"
    else
        printf 'http://op-%s-seq%s:8545\n' "$seq_type" "$suffix"
    fi
}

rcs_host_port() {
    local index="$1" base="${RCS_HOST_PORT_BASE:-9195}"
    rcs_service_suffix "$index" >/dev/null || return 1
    if ! [[ "$base" =~ ^[0-9]+$ ]]; then
        echo "❌ RCS_HOST_PORT_BASE must be an integer, got: '$base'" >&2
        return 1
    fi
    printf '%s\n' "$((base + index - 1))"
}

rcs_resolve_source_dir() {
    local source_dir="${RCS_LOCAL_DIRECTORY:-}"
    [ -n "$source_dir" ] || {
        echo "❌ RCS_LOCAL_DIRECTORY is required when an RCS image build is enabled" >&2
        return 1
    }
    case "$source_dir" in
        /*) ;;
        *) source_dir="${RCS_DEVNET_DIR:-$PWD}/$source_dir" ;;
    esac
    [ -d "$source_dir" ] || {
        echo "❌ RCS_LOCAL_DIRECTORY does not exist: $source_dir" >&2
        return 1
    }
    (cd "$source_dir" && pwd -P)
}

rcs_validate_known_bridge_addresses() {
    local addresses="${RCS_KNOWN_BRIDGE_ADDRESSES:-}"
    local pattern='^\[[[:blank:]]*"0x[0-9a-fA-F]{40}"([[:blank:]]*,[[:blank:]]*"0x[0-9a-fA-F]{40}")*[[:blank:]]*\]$'

    [ -n "$addresses" ] || {
        echo "❌ RCS_KNOWN_BRIDGE_ADDRESSES is required when RCS is enabled" >&2
        return 1
    }
    [[ "$addresses" =~ $pattern ]] || {
        echo "❌ RCS_KNOWN_BRIDGE_ADDRESSES must be a non-empty TOML array of quoted 0x addresses" >&2
        return 1
    }
}

rcs_validate_settings() {
    local seq_count="$1" seq_type="$2"
    local enabled="${RCS_ENABLED:-false}" count="${RCS_COUNT:-1}"
    local rcs_port_base="${RCS_HOST_PORT_BASE:-9195}"
    local tzmock_port="${TZMOCK_HOST_PORT:-9500}" last_rcs_port

    rcs_is_boolean "$enabled" || {
        echo "❌ RCS_ENABLED must be 'true' or 'false', got: '$enabled'" >&2
        return 1
    }
    [ "$enabled" = true ] || return 0

    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ RCS_COUNT must be a positive integer, got: '$count'" >&2
        return 1
    fi
    if [ "$count" -gt "$seq_count" ]; then
        echo "❌ RCS_COUNT=$count exceeds effective sequencer count $seq_count" >&2
        return 1
    fi
    if [ "$seq_type" != reth ]; then
        echo "❌ RCS_ENABLED=true requires SEQ_TYPE=reth, got: '$seq_type'" >&2
        return 1
    fi
    rcs_validate_known_bridge_addresses || return 1

    rcs_is_boolean "${SKIP_RCS_BUILD:-false}" || {
        echo "❌ SKIP_RCS_BUILD must be 'true' or 'false'" >&2
        return 1
    }
    rcs_is_boolean "${SKIP_TZMOCK_BUILD:-false}" || {
        echo "❌ SKIP_TZMOCK_BUILD must be 'true' or 'false'" >&2
        return 1
    }

    if ! [[ "$rcs_port_base" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ RCS_HOST_PORT_BASE must be a positive integer, got: '$rcs_port_base'" >&2
        return 1
    fi
    if ! [[ "$tzmock_port" =~ ^[1-9][0-9]*$ ]] || [ "$tzmock_port" -gt 65535 ]; then
        echo "❌ TZMOCK_HOST_PORT must be within 1..65535, got: '$tzmock_port'" >&2
        return 1
    fi
    last_rcs_port=$((rcs_port_base + count - 1))
    if [ "$last_rcs_port" -gt 65535 ]; then
        echo "❌ RCS host port range ends outside 1..65535: $last_rcs_port" >&2
        return 1
    fi

    if [ "${SKIP_RCS_BUILD:-false}" = false ] || [ "${SKIP_TZMOCK_BUILD:-false}" = false ]; then
        rcs_resolve_source_dir >/dev/null || return 1
    fi
    [ -n "${RCS_IMAGE_TAG:-xlayer-rcs:latest}" ] || {
        echo "❌ RCS_IMAGE_TAG must not be empty" >&2
        return 1
    }
    [ -n "${TZMOCK_IMAGE_TAG:-tzmock:latest}" ] || {
        echo "❌ TZMOCK_IMAGE_TAG must not be empty" >&2
        return 1
    }
}

rcs_emit_inventory() {
    local seq_count="$1" rpc_count="$2" rpc_type="$3" seq_type="$4"
    local count="${RCS_COUNT:-1}" services="" i service seq_service endpoint host_port

    if [ "${RCS_ENABLED:-false}" != true ]; then
        printf '%s\n' 'RCS_EFFECTIVE_COUNT=0' 'RCS_SERVICES=""' 'TZMOCK_SERVICE=""'
        return 0
    fi

    rcs_validate_settings "$seq_count" "$seq_type" || return 1
    for ((i = 1; i <= count; i++)); do
        service=$(rcs_service_name "$i") || return 1
        services="${services:+$services }$service"
    done
    printf 'RCS_EFFECTIVE_COUNT=%s\n' "$count"
    printf 'RCS_SERVICES="%s"\n' "$services"
    printf '%s\n' 'TZMOCK_SERVICE="tzmock"'
    for ((i = 1; i <= count; i++)); do
        service=$(rcs_service_name "$i") || return 1
        seq_service=$(rcs_seq_service_name "$i" "$seq_type") || return 1
        endpoint=$(rcs_l2_endpoint "$i" "$rpc_count" "$rpc_type" "$seq_type") || return 1
        host_port=$(rcs_host_port "$i") || return 1
        printf 'RCS_SERVICE_%s=%s\n' "$i" "$service"
        printf 'RCS_SEQ_SERVICE_%s=%s\n' "$i" "$seq_service"
        printf 'RCS_L2_ENDPOINT_%s=%s\n' "$i" "$endpoint"
        printf 'RCS_HOST_PORT_%s=%s\n' "$i" "$host_port"
    done
}

rcs_reserve_host_ports() {
    local seq_count="$1" count="${RCS_COUNT:-1}" i port
    [ "${RCS_ENABLED:-false}" = true ] || return 0
    rcs_validate_settings "$seq_count" "${SEQ_TYPE:-reth}" || return 1
    if [ "$(type -t reserve_port_key 2>/dev/null)" != function ]; then
        echo "❌ rcs_reserve_host_ports requires reserve_port_key" >&2
        return 1
    fi
    reserve_port_key "${TZMOCK_HOST_PORT:-9500}" tcp tzmock
    for ((i = 1; i <= count; i++)); do
        port=$(rcs_host_port "$i") || return 1
        reserve_port_key "$port" tcp "$(rcs_service_name "$i")"
    done
}

rcs_prepare_runtime_config() {
    local devnet_dir="$1" rpc_count="$2" rpc_type="$3" seq_type="$4"
    local count="${RCS_EFFECTIVE_COUNT:-0}" config_root rules_tmp known_bridge_addresses i endpoint start_height
    local instance_dir config_tmp data_dir

    [ "$count" -gt 0 ] || return 0
    rcs_validate_known_bridge_addresses || return 1
    known_bridge_addresses="${RCS_KNOWN_BRIDGE_ADDRESSES}"
    config_root="$devnet_dir/config-op/rcs"
    rm -rf "$config_root"
    mkdir -p "$config_root"

    start_height=$(( ${FORK_BLOCK:-0} + 1 ))
    rules_tmp=$(mktemp "$config_root/rules.json.tmp.XXXXXX") || return 1
    printf '%s\n' '{"rules":[]}' > "$rules_tmp"
    # mktemp creates 0600 files; the RCS container runs as non-root UID 10001 and
    # must be able to read the bind-mounted rules.json, so widen to 0644 before publishing.
    chmod 0644 "$rules_tmp" || return 1
    mv "$rules_tmp" "$config_root/rules.json"

    for ((i = 1; i <= count; i++)); do
        instance_dir="$config_root/rcs$i"
        data_dir="$devnet_dir/data/rcs/rcs$i"
        mkdir -p "$instance_dir" "$data_dir"
        chmod 0777 "$data_dir"
        endpoint=$(rcs_l2_endpoint "$i" "$rpc_count" "$rpc_type" "$seq_type") || return 1
        config_tmp=$(mktemp "$instance_dir/config.toml.tmp.XXXXXX") || return 1
        cat > "$config_tmp" <<EOF
# Generated by scripts/lib/rcs-services.sh. Regenerate through clean.sh/0-all.sh.
listen_addr = ":9195"
sqlite_path = "/app/data/rcs.db"
rules_path = "/app/config/rules.json"
log_level = "info"

tz_quota = true
known_bridge_addresses = $known_bridge_addresses
audit_timeout_action = "allow"

tz_source_url = "http://tzmock:9500"
tz_chain_id = "${CHAIN_ID:-195}"
tz_sync_interval_seconds = 5

xlayer_rpc_url = "$endpoint"
xlayer_sync_interval_seconds = 5
xlayer_sync_start_height = $start_height
xlayer_sync_max_block_range = 1000

approval_ttl_seconds = 30
outdated_release_delay_seconds = 20
reservation_sweep_interval_seconds = 5
startup_grace_seconds = 0

debug_endpoints_enabled = true

l1_rpc_ws_url = ""
l1_rpc_http_url = "${L1_RPC_URL_IN_DOCKER:-http://l1-geth:8545}"
optimism_portal_address = ""
l1_reorg_window_blocks = 0
l1_sync_start_height = 0

xlayer_audit_rpc_url = "$endpoint"
signer_private_key_env = ""
tx_blacklist_contract_address = ""
EOF
        # mktemp creates 0600 files; the RCS container runs as non-root UID 10001 and
        # must be able to read the bind-mounted config.toml, so widen to 0644 before publishing.
        chmod 0644 "$config_tmp" || return 1
        mv "$config_tmp" "$instance_dir/config.toml"
    done
}

rcs_seq_environment_yaml() {
    local index="$1" count="${RCS_EFFECTIVE_COUNT:-0}" service
    if [ "$count" -gt 0 ] && [ "$index" -le "$count" ]; then
        service=$(rcs_service_name "$index") || return 1
        printf '%s\n' \
            '      - RCS_FILTER_ENABLED=true' \
            "      - RCS_BASE_URL=http://$service:9195"
    else
        printf '%s\n' '      - RCS_FILTER_ENABLED=false'
    fi
}

rcs_append_compose() {
    local compose_output="$1" devnet_dir="$2" count="${RCS_EFFECTIVE_COUNT:-0}"
    local source_dir="" tz_context="" i service host_port

    [ "$count" -gt 0 ] || return 0
    if [ "${SKIP_RCS_BUILD:-false}" = false ] || [ "${SKIP_TZMOCK_BUILD:-false}" = false ]; then
        RCS_DEVNET_DIR="$devnet_dir" source_dir=$(rcs_resolve_source_dir) || return 1
        tz_context="$source_dir/cmd/mock/tz"
    fi

    cat >> "$compose_output" <<EOF

  tzmock:
    image: "${TZMOCK_IMAGE_TAG:-tzmock:latest}"
    container_name: tzmock
EOF
    if [ "${SKIP_TZMOCK_BUILD:-false}" = false ]; then
        cat >> "$compose_output" <<EOF
    build:
      context: $tz_context
      dockerfile: $tz_context/Dockerfile
EOF
    fi
    cat >> "$compose_output" <<EOF
    ports:
      - "${TZMOCK_HOST_PORT:-9500}:9500"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9500/healthz"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
EOF

    for ((i = 1; i <= count; i++)); do
        service=$(rcs_service_name "$i") || return 1
        host_port=$(rcs_host_port "$i") || return 1
        cat >> "$compose_output" <<EOF

  $service:
    image: "${RCS_IMAGE_TAG:-xlayer-rcs:latest}"
    container_name: $service
EOF
        # Every RCS instance runs the same image tag, so only the first service
        # declares a build; the image is built once and the remaining instances
        # reuse it. To make that reuse work, the non-first instances pin
        # pull_policy: never so Compose uses the locally built image instead of
        # trying to pull the (registry-less) xlayer-rcs tag. Only applied when we
        # build locally; with SKIP_RCS_BUILD=true the image is provided
        # externally, so the default pull policy is left in place.
        if [ "${SKIP_RCS_BUILD:-false}" = false ]; then
            if [ "$i" -eq 1 ]; then
                cat >> "$compose_output" <<EOF
    build:
      context: $source_dir
      dockerfile: $source_dir/Dockerfile
EOF
            else
                cat >> "$compose_output" <<EOF
    pull_policy: never
EOF
            fi
        fi
        cat >> "$compose_output" <<EOF
    command: ["/app/config.toml"]
    volumes:
      - ./config-op/rcs/rcs$i/config.toml:/app/config.toml:ro
      - ./config-op/rcs/rules.json:/app/config/rules.json
      - ./data/rcs/rcs$i:/app/data
    ports:
      - "$host_port:9195"
    depends_on:
      tzmock:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:9195/debug/healthz"]
      interval: 2s
      timeout: 2s
      retries: 30
      start_period: 2s
EOF
    done
}
