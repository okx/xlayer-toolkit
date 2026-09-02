#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV_PATH="${CLUSTER_ENV_PATH:-config-op/cluster/cluster.env}"
[ -f "$CLUSTER_ENV_PATH" ] || { echo "❌ Missing generated cluster environment: $CLUSTER_ENV_PATH" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV_PATH"

START_PHASE="${1:-}"
case "$START_PHASE" in
    prepare|risk-control|seq-el|seq-cl|conductors|activate|monitoring|rpc-el|rpc-cl) ;;
    *) echo "❌ start phase must be prepare, risk-control, seq-el, seq-cl, conductors, activate, monitoring, rpc-el, or rpc-cl" >&2; exit 1 ;;
esac

[ -n "${SEQ_EL_SERVICES:-}" ] || { echo "❌ SEQ_EL_SERVICES is empty" >&2; exit 1; }
[ -n "${SEQ_CL_SERVICES:-}" ] || { echo "❌ SEQ_CL_SERVICES is empty" >&2; exit 1; }
[ -n "${ALL_EL_SERVICES:-}" ] || { echo "❌ ALL_EL_SERVICES is empty" >&2; exit 1; }

wait_for_el_to_start() {
    local container_name="$1"
    local ready_log
    case "$container_name" in
        op-geth-*) ready_log="HTTP server started" ;;
        *) ready_log="Starting consensus engine" ;;
    esac

    echo "⏳ Waiting for execution layer $container_name ..."
    local elapsed=0 max_wait="${EL_START_TIMEOUT_SECONDS:-300}"
    while [ "$elapsed" -lt "$max_wait" ]; do
        # Drain the full log stream after a match. With pipefail, grep -q closes
        # the pipe early and Docker can exit with SIGPIPE (141), which makes a
        # healthy execution client look unavailable.
        if docker logs "$container_name" 2>&1 | grep -F "$ready_log" >/dev/null; then
            echo "✅ $container_name is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "❌ Timeout waiting for $container_name after ${max_wait}s" >&2
    return 1
}

wait_for_cl_to_start() {
    local container_name="$1"
    local elapsed=0 max_wait="${CL_START_TIMEOUT_SECONDS:-300}" status published_port host_port
    echo "⏳ Waiting for consensus layer $container_name ..."
    while [ "$elapsed" -lt "$max_wait" ]; do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)
        case "$status" in
            healthy) echo "✅ $container_name is ready"; return 0 ;;
            running)
                case "$container_name" in
                    op-kona-*)
                        published_port=$(docker port "$container_name" 9545/tcp 2>/dev/null | sed -n '1p' || true)
                        host_port="${published_port##*:}"
                        if [[ "$host_port" =~ ^[0-9]+$ ]] && curl -sf "http://localhost:${host_port}/healthz" > /dev/null 2>&1; then
                            echo "✅ $container_name is ready"
                            return 0
                        fi
                        ;;
                    *) echo "✅ $container_name is ready"; return 0 ;;
                esac
                ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "❌ Timeout waiting for $container_name after ${max_wait}s" >&2
    return 1
}

wait_for_service_health() {
    local service_name="$1"
    local elapsed=0
    local max_wait="${RCS_START_TIMEOUT_SECONDS:-120}"
    local interval="${RCS_START_RETRY_SECONDS:-2}"
    local status

    echo "⏳ Waiting for risk-control service $service_name ..."
    while [ "$elapsed" -lt "$max_wait" ]; do
        status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
            "$service_name" 2>/dev/null || true)
        case "$status" in
            healthy|running)
                echo "✅ $service_name is ready"
                return 0
                ;;
        esac
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    echo "❌ Timeout waiting for $service_name after ${max_wait}s (last status: ${status:-missing})" >&2
    return 1
}

print_rcs_mapping() {
    local i service_var seq_var endpoint_var port_var
    local service seq_service endpoint host_port

    for ((i = 1; i <= ${RCS_EFFECTIVE_COUNT:-0}; i++)); do
        service_var="RCS_SERVICE_$i"
        seq_var="RCS_SEQ_SERVICE_$i"
        endpoint_var="RCS_L2_ENDPOINT_$i"
        port_var="RCS_HOST_PORT_$i"
        service="${!service_var:-}"
        seq_service="${!seq_var:-}"
        endpoint="${!endpoint_var:-}"
        host_port="${!port_var:-}"
        if [ -z "$service" ] || [ -z "$seq_service" ] || [ -z "$endpoint" ] || [ -z "$host_port" ]; then
            echo "❌ Incomplete generated RCS mapping for index $i" >&2
            return 1
        fi
        echo "🔗 RCS $service -> sequencer $seq_service -> L2 $endpoint -> host :$host_port"
    done
}

wait_for_conductor_election() {
    local max_attempts="${CONDUCTOR_ELECTION_MAX_ATTEMPTS:-60}"
    local interval="${CONDUCTOR_ELECTION_RETRY_SECONDS:-2}"
    local attempt i port_var port response result ready leader

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        ready=0
        leader=false
        for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
            port_var="CONDUCTOR_RPC_PORT_$i"
            port="${!port_var:-}"
            [ -n "$port" ] || { echo "❌ Missing generated $port_var" >&2; return 1; }
            response=$(curl --fail --silent --show-error -X POST -H 'Content-Type: application/json' \
                --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
                "http://localhost:$port" 2>/dev/null || true)
            result=$(printf '%s' "$response" | jq -r \
                'if (.error == null) and ((.result | type) == "boolean") then (.result | tostring) else empty end' \
                2>/dev/null || true)
            case "$result" in
                true) ready=$((ready + 1)); leader=true ;;
                false) ready=$((ready + 1)) ;;
            esac
        done
        if [ "$ready" -eq "$SEQ_EFFECTIVE_COUNT" ] && [ "$leader" = "true" ]; then
            echo "✅ All $ready conductor RPCs are ready and a leader is elected"
            return 0
        fi
        echo "⏳ Conductor election attempt $attempt/$max_attempts: ready=$ready/$SEQ_EFFECTIVE_COUNT leader=$leader"
        [ "$attempt" -eq "$max_attempts" ] || sleep "$interval"
    done
    echo "❌ No conductor leader elected after $max_attempts attempts (ready=$ready/$SEQ_EFFECTIVE_COUNT)" >&2
    return 1
}

activate_sequencer_with_retry() {
    [ -n "${CONDUCTOR_SERVICES:-}" ] || return 0
    local active_script="${ACTIVE_SEQUENCER_SCRIPT:-$SCRIPT_DIR/active-sequencer.sh}"
    local max_attempts="${ACTIVE_SEQUENCER_MAX_ATTEMPTS:-10}"
    local interval="${ACTIVE_SEQUENCER_RETRY_SECONDS:-2}"
    local attempt
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if "$active_script"; then
            echo "✅ Active sequencer validated on attempt $attempt"
            return 0
        fi
        echo "⏳ Active sequencer validation failed on attempt $attempt/$max_attempts" >&2
        [ "$attempt" -eq "$max_attempts" ] || sleep "$interval"
    done
    echo "❌ Failed to activate and validate a sequencer after $max_attempts attempts" >&2
    return 1
}

case "$START_PHASE" in
    prepare)
        # Create every EL container/DNS name up front for strict peer lists,
        # without starting RPC ELs before the sequencer cluster is established.
        docker compose create $ALL_EL_SERVICES
        ;;
    risk-control)
        if [ "${RCS_EFFECTIVE_COUNT:-0}" -gt 0 ]; then
            [ -n "${TZMOCK_SERVICE:-}" ] || { echo "❌ TZMOCK_SERVICE is empty" >&2; exit 1; }
            [ -n "${RCS_SERVICES:-}" ] || { echo "❌ RCS_SERVICES is empty" >&2; exit 1; }
            print_rcs_mapping
            # Only the first RCS service declares a build; the rest reuse the
            # locally built xlayer-rcs image via pull_policy: never. A combined
            # `up --build` resolves the build-less instances in parallel with the
            # build and can race a registry pull before the image exists, so
            # build the shared images first, then start every service.
            docker compose build $TZMOCK_SERVICE $RCS_SERVICES
            docker compose up -d $TZMOCK_SERVICE $RCS_SERVICES
            for service in $TZMOCK_SERVICE $RCS_SERVICES; do
                wait_for_service_health "$service"
            done
        fi
        ;;
    seq-el)
        docker compose start $SEQ_EL_SERVICES
        for service in $SEQ_EL_SERVICES; do wait_for_el_to_start "$service"; done
        ;;
    seq-cl)
        docker compose up -d --no-deps $SEQ_CL_SERVICES
        for service in $SEQ_CL_SERVICES; do wait_for_cl_to_start "$service"; done
        ;;
    conductors)
        if [ -n "${CONDUCTOR_SERVICES:-}" ]; then
            docker compose up -d --no-deps $CONDUCTOR_SERVICES
            wait_for_conductor_election
        fi
        ;;
    activate)
        activate_sequencer_with_retry
        ;;
    monitoring)
        "${MONITORING_START_SCRIPT:-$SCRIPT_DIR/start-monitoring.sh}"
        ;;
    rpc-el)
        if [ -n "${RPC_EL_SERVICES:-}" ]; then
            docker compose start $RPC_EL_SERVICES
            for service in $RPC_EL_SERVICES; do wait_for_el_to_start "$service"; done
        fi
        ;;
    rpc-cl)
        if [ -n "${RPC_CL_SERVICES:-}" ]; then
            docker compose up -d --no-deps $RPC_CL_SERVICES
            for service in $RPC_CL_SERVICES; do wait_for_cl_to_start "$service"; done
        fi
        ;;
esac
