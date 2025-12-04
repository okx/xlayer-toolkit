#!/bin/bash

set -e

CONTAINER=${1:-op-reth-seq}

echo "=== Verifying Profiling Setup for $CONTAINER ==="
echo ""

# Check if container is running
if ! docker ps | grep -q "$CONTAINER"; then
    echo "❌ ERROR: Container $CONTAINER is not running"
    echo ""
    echo "Start the container first:"
    echo "  docker-compose up -d $CONTAINER"
    exit 1
fi

echo "✓ Container is running"
echo ""

# Check for privileged mode / capabilities
echo "[1/5] Checking container privileges..."
PRIVILEGED=$(docker inspect "$CONTAINER" --format='{{.HostConfig.Privileged}}')
CAPABILITIES=$(docker inspect "$CONTAINER" --format='{{.HostConfig.CapAdd}}')

if [ "$PRIVILEGED" = "true" ]; then
    echo "✓ Container is running in privileged mode"
elif echo "$CAPABILITIES" | grep -q "SYS_ADMIN"; then
    echo "✓ Container has SYS_ADMIN capability"
else
    echo "⚠️  WARNING: Container lacks SYS_ADMIN capability"
    echo "   Off-CPU profiling may not work without privileged mode or SYS_ADMIN"
fi
echo ""

# Check for tracefs/debugfs mount
echo "[2/5] Checking tracing filesystem..."
TRACEFS_CHECK=$(docker exec "$CONTAINER" sh -c '
    if [ -d /sys/kernel/tracing/events ]; then
        echo "TRACEFS:/sys/kernel/tracing"
    elif [ -d /sys/kernel/debug/tracing/events ]; then
        echo "DEBUGFS:/sys/kernel/debug/tracing"
    else
        echo "MISSING"
    fi
' 2>/dev/null)

if [ "$TRACEFS_CHECK" = "MISSING" ]; then
    echo "❌ ERROR: Tracing filesystem not mounted"
    echo ""
    echo "Add to docker-compose.yml:"
    echo "  $CONTAINER:"
    echo "    volumes:"
    echo "      - /sys/kernel/tracing:/sys/kernel/tracing:ro"
    echo ""
    echo "Or for older systems:"
    echo "      - /sys/kernel/debug:/sys/kernel/debug:ro"
    echo ""
    exit 1
else
    TRACEFS_TYPE=$(echo "$TRACEFS_CHECK" | cut -d: -f1)
    TRACEFS_PATH=$(echo "$TRACEFS_CHECK" | cut -d: -f2)
    echo "✓ Tracing filesystem mounted: $TRACEFS_PATH ($TRACEFS_TYPE)"
fi
echo ""

# Check for perf binary
echo "[3/5] Checking perf availability..."
PERF_BIN=$(docker exec "$CONTAINER" sh -c 'command -v perf 2>/dev/null || find /usr/local/bin /usr/bin -name "perf" -type f 2>/dev/null | head -1' 2>/dev/null)

if [ -z "$PERF_BIN" ]; then
    echo "❌ ERROR: perf binary not found in container"
    echo ""
    echo "Rebuild the container with profiling support:"
    echo "  ./scripts/build-reth-with-profiling.sh"
    exit 1
else
    PERF_VERSION=$(docker exec "$CONTAINER" sh -c "$PERF_BIN --version 2>&1" | head -1)
    echo "✓ perf found: $PERF_BIN"
    echo "  Version: $PERF_VERSION"
fi
echo ""

# Check if perf can access tracepoints
echo "[4/5] Testing perf tracepoint access..."
TEST_RESULT=$(docker exec "$CONTAINER" sh -c "$PERF_BIN list syscalls:sys_enter_futex 2>&1" | head -1)

if echo "$TEST_RESULT" | grep -q "Tracepoint event"; then
    echo "✓ perf can access tracepoint events"
else
    echo "⚠️  WARNING: perf cannot access tracepoint events"
    echo "   Output: $TEST_RESULT"
fi
echo ""

# Check profiling directory
echo "[5/5] Checking profiling directory..."
if docker exec "$CONTAINER" sh -c '[ -d /profiling ] && [ -w /profiling ]' 2>/dev/null; then
    echo "✓ Profiling directory exists and is writable: /profiling"
else
    echo "⚠️  WARNING: /profiling directory missing or not writable"
    echo ""
    echo "Add to docker-compose.yml:"
    echo "  $CONTAINER:"
    echo "    volumes:"
    echo "      - ./profiling/$CONTAINER:/profiling"
fi
echo ""

# Summary
echo "=== Summary ==="
if [ "$TRACEFS_CHECK" != "MISSING" ] && [ -n "$PERF_BIN" ]; then
    echo "✅ Profiling setup looks good!"
    echo ""
    echo "You can now run profiling scripts:"
    echo "  ./scripts/profile-reth-perf.sh $CONTAINER 30"
    echo "  ./scripts/profile-reth-offcpu.sh $CONTAINER 30"
    echo ""
else
    echo "❌ Profiling setup incomplete. Please fix the issues above."
    echo ""
    exit 1
fi
