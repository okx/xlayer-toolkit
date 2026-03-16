# How to Apply the Kona Single-Image Changes

> For any developer taking a fresh branch from `main` and wanting to reproduce
> the kona single-image sequencer setup from scratch, by hand.
>
> **6 files to change. 2 new files to create. Done.**

---

## Overview of What You Are Doing

You are replacing two separate sequencer containers (`op-seq` + `op-reth-seq`) with a
single unified container (`op-seq`) that runs both kona-node and op-reth inside one image.

```
BEFORE                                AFTER
──────────────────────────────────    ──────────────────────────
op-seq      (op-node, Go)             op-seq  (kona-node + op-reth, Rust)
op-reth-seq (op-reth, Rust)
```

---

## Prerequisites

- Fresh branch from `main`
- `op-reth:al-prefetch` image built locally (the OKX custom op-reth build)
- `ghcr.io/op-rs/kona/kona-node:latest` pullable from GHCR

---

## Step 1 — Create the Dockerfile

Create a new file: `devnet/Dockerfile.xlayer-kona-seq`

```dockerfile
# op-xlayer-kona-seq — unified sequencer image
# Combines OKX op-reth (execution) + kona-node (consensus) in one container.
# Engine API runs on 127.0.0.1:8552 — never exposed outside the container.

FROM op-reth:al-prefetch AS reth-bin
FROM ghcr.io/op-rs/kona/kona-node:latest AS kona-bin

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=reth-bin  /usr/local/bin/op-reth    /usr/local/bin/op-reth
COPY --from=kona-bin  /usr/local/bin/kona-node  /usr/local/bin/kona-node

# Bake in the supervisor entrypoint so the image is self-contained.
# In devnet, docker-compose volume-mounts ./entrypoint:/entrypoint which
# overrides this copy at runtime (useful for editing without rebuilding).
# For distribution / docker run without xlayer-toolkit, this copy is used.
COPY entrypoint/xlayer-kona-seq.sh /entrypoint/xlayer-kona-seq.sh
RUN chmod +x /entrypoint/xlayer-kona-seq.sh

# Verify both binaries are present and the entrypoint is executable
RUN op-reth --version && kona-node --version && test -x /entrypoint/xlayer-kona-seq.sh

ENTRYPOINT ["/entrypoint/xlayer-kona-seq.sh"]
```

---

## Step 2 — Create the Entrypoint Script

Create a new file: `devnet/entrypoint/xlayer-kona-seq.sh`

> Make it executable after creating: `chmod +x devnet/entrypoint/xlayer-kona-seq.sh`

```bash
#!/bin/bash
# xlayer-kona-seq supervisor entrypoint
#
# Starts op-reth in the background, waits until its HTTP RPC is ready,
# then execs kona-node in the foreground (PID 1 receives Docker signals).
#
# Engine API (--authrpc) binds to 127.0.0.1:8552 — internal only, never
# reachable from outside the container.

set -e

# Export all sourced vars to child processes
set -a
source /.env
set +a

# ---------------------------------------------------------------------------
# 1. Optional: jemalloc profiling
# ---------------------------------------------------------------------------
if [ "${JEMALLOC_PROFILING:-false}" = "true" ]; then
    export _RJEM_MALLOC_CONF="prof:true,prof_prefix:/profiling/jeprof,lg_prof_interval:30"
    echo "[xlayer-kona-seq] Jemalloc profiling enabled: _RJEM_MALLOC_CONF=$_RJEM_MALLOC_CONF"
fi

# ---------------------------------------------------------------------------
# 2. Build and start op-reth (background)
# ---------------------------------------------------------------------------
echo "[xlayer-kona-seq] AL prefetch env: TXPOOL_AL_PREFETCH_ONLY=${TXPOOL_AL_PREFETCH_ONLY:-NOT_SET}"
echo "[xlayer-kona-seq] Starting op-reth (execution layer, background)..."

CMD="op-reth node \
  --datadir=/datadir \
  --chain=/genesis.json \
  --http \
  --http.corsdomain=* \
  --http.port=8545 \
  --http.addr=0.0.0.0 \
  --http.api=web3,debug,eth,txpool,net,miner,admin \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=7546 \
  --ws.origins=* \
  --ws.api=web3,debug,eth,txpool,net \
  --disable-discovery \
  --max-outbound-peers=10 \
  --max-inbound-peers=10 \
  --rpc.eth-proof-window=10000 \
  --authrpc.addr=127.0.0.1 \
  --authrpc.port=8552 \
  --authrpc.jwtsecret=/jwt.txt \
  --trusted-peers=${TRUSTED_PEERS:-} \
  --tx-propagation-policy=all \
  --txpool.max-account-slots=100000 \
  --txpool.pending-max-count=100000 \
  --txpool.queued-max-count=100000 \
  --txpool.basefee-max-count=100000 \
  --txpool.max-pending-txns=100000 \
  --txpool.max-new-txns=100000 \
  --txpool.pending-max-size=2000 \
  --txpool.basefee-max-size=2000 \
  --engine.persistence-threshold=${ENGINE_PERSISTENCE_THRESHOLD:-2} \
  --log.file.directory=/logs/reth \
  --log.file.filter=info \
  --metrics=0.0.0.0:9001"

# Pre-warming flags (only for pre-warming builds)
if [ "${TXPOOL_PRE_WARMING:-false}" = "true" ]; then
    CMD="$CMD \
        --txpool.pre-warming=${TXPOOL_PRE_WARMING} \
        --txpool.pre-warming-workers=${TXPOOL_PRE_WARMING_WORKERS:-8} \
        --txpool.pre-fetch-workers=${TXPOOL_PRE_FETCH_WORKERS:-16}"
fi

# Flashblock flags
if [ "${FLASHBLOCK_ENABLED:-false}" = "true" ]; then
    CMD="$CMD \
        --flashblocks.enabled \
        --flashblocks.disable-rollup-boost \
        --flashblocks.disable-state-root \
        --flashblocks.disable-async-calculate-state-root \
        --flashblocks.addr=0.0.0.0 \
        --flashblocks.port=1111 \
        --flashblocks.block-time=${FLASHBLOCK_BLOCK_TIME:-200}"

    if [ "${FLASHBLOCK_P2P_ENABLED:-false}" = "true" ] && [ "${CONDUCTOR_ENABLED:-false}" = "true" ]; then
        CMD="$CMD \
            --flashblocks.p2p_enabled \
            --flashblocks.p2p_port=9009 \
            --flashblocks.p2p_private_key_file=/datadir/fb-p2p-key"

        INDEX="${1:-}"
        if [ -z "$INDEX" ]; then
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq2/tcp/9009/p2p/12D3KooWGnxtRXJWhNtwKmRjpqj5QFQPskjWJkC7AkGWhCXBM6ed"
        else
            CMD="$CMD --flashblocks.p2p_known_peers=/dns4/op-reth-seq/tcp/9009/p2p/12D3KooWC6qFQzcS6V6Tp53nRqw2pmU1snjSYq7H4Q6ckTWAskTt"
        fi
    fi

    echo "[xlayer-kona-seq] Flashblocks enabled (block-time=${FLASHBLOCK_BLOCK_TIME:-200}ms)"
fi

eval $CMD &
RETH_PID=$!
echo "[xlayer-kona-seq] op-reth started (pid $RETH_PID)"

# ---------------------------------------------------------------------------
# 3. Wait for op-reth HTTP RPC to be ready
# ---------------------------------------------------------------------------
echo "[xlayer-kona-seq] Waiting for op-reth HTTP RPC (127.0.0.1:8545)..."
until curl -sf \
    -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 | grep -q '"result"'; do
    if ! kill -0 $RETH_PID 2>/dev/null; then
        echo "[xlayer-kona-seq] ERROR: op-reth exited unexpectedly during startup"
        exit 1
    fi
    sleep 1
done
echo "[xlayer-kona-seq] op-reth is ready"

# ---------------------------------------------------------------------------
# 4. Start kona-node in foreground (becomes PID 1, receives SIGTERM on stop)
# ---------------------------------------------------------------------------
echo "[xlayer-kona-seq] Starting kona-node (consensus layer, foreground)..."

exec kona-node \
    --chain=195 \
    --metrics.enabled \
    --metrics.port=9002 \
    node \
    --mode=sequencer \
    --l1="${L1_RPC_URL_IN_DOCKER}" \
    --l1-beacon="${L1_BEACON_URL_IN_DOCKER}" \
    --l2=http://127.0.0.1:8552 \
    --l2.jwt-secret=/jwt.txt \
    --l2-config-file=/rollup.json \
    --l1-config-file=/l1-genesis.json \
    --rpc.addr=0.0.0.0 \
    --rpc.port=9545 \
    --rpc.enable-admin \
    --p2p.listen.tcp=9223 \
    --p2p.listen.udp=9223 \
    --p2p.priv.raw=e054b5748fb29a82994ea170af9e6094a163a0d11308dea91a38744c4e7c94da \
    --p2p.no-discovery \
    --p2p.sequencer.key="${SEQUENCER_P2P_KEY}" \
    --p2p.bootstore=/data/p2p/bootstore \
    --sequencer.l1-confs=5
```

---

## Step 3 — Update `.env`

In `devnet/.env`, make the following changes:

**3a. Add the unified image tag** (after the existing `OP_RETH_IMAGE_TAG` line):
```bash
# Unified sequencer image — op-reth + kona-node in one container (Phase 2 single-image)
# Built from Dockerfile.xlayer-kona-seq; replaces separate op-reth-seq + op-seq services
OP_XLAYER_IMAGE_TAG=op-xlayer:latest
```

**3b. Fix the `TRUSTED_PEERS` enode** — change the hostname at the end:
```bash
# Change:
TRUSTED_PEERS=enode://...@op-reth-seq:30303

# To:
TRUSTED_PEERS=enode://...@op-seq:30303
```

> Keep the enode pubkey unchanged — only the hostname suffix changes from `op-reth-seq` to `op-seq`.

**3c. Disable conductor and RPC node** (reduces complexity for kona validation):
```bash
CONDUCTOR_ENABLED=false
LAUNCH_RPC_NODE=false
```

---

## Step 4 — Update `docker-compose.yml`

### 4a. Delete the entire `op-reth-seq` service block

Find and remove this entire block (approximately lines 211–255 on main):

```yaml
  op-reth-seq:
    image: "${OP_RETH_IMAGE_TAG}"
    container_name: op-reth-seq
    ...
    networks:
      default:
        aliases:
          - op-seq-el
```

> Remove everything from `op-reth-seq:` down to and including the `op-seq-el` alias under it.

### 4b. Replace the entire `op-seq` service block

Find the existing `op-seq:` block and replace it entirely with:

```yaml
  op-seq:
    # Unified sequencer: op-reth (execution) + kona-node (consensus) in one container.
    # xlayer-kona-seq.sh starts op-reth in background, waits for HTTP ready, then execs kona-node.
    # Engine API (--authrpc) binds to 127.0.0.1:8552 — internal only, never exposed.
    image: "${OP_XLAYER_IMAGE_TAG}"
    container_name: op-seq
    entrypoint: /entrypoint/xlayer-kona-seq.sh
    env_file:
      - .env
    privileged: true
    cap_add:
      - SYS_ADMIN
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    volumes:
      - ./data/op-reth-seq:/datadir
      - ./config-op/jwt.txt:/jwt.txt
      - ./config-op/genesis-reth.json:/genesis.json
      - ./config-op/rollup.json:/rollup.json
      - ./l1-geth/execution/genesis.json:/l1-genesis.json
      - ./entrypoint:/entrypoint
      - ./.env:/.env
      - ./data/op-seq:/data
      - ./logs/op-reth-seq:/logs/reth
    ports:
      - "8123:8545"    # L2 public RPC
      - "7546:7546"    # WebSocket
      - "30303:30303"  # P2P TCP
      - "30303:30303/udp"
      - "9001:9001"    # reth metrics
      - "11111:1111"   # flashblocks outbound WS (only active when FLASHBLOCK_ENABLED=true)
      - "9545:9545"    # kona-node rollup RPC
      - "9223:9223"    # kona-node P2P TCP
      - "9223:9223/udp"
      - "9002:9002"    # kona-node metrics
    healthcheck:
      test: ["CMD", "curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_syncStatus\",\"params\":[],\"id\":1}", "http://localhost:9545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 15s
    networks:
      default:
        aliases:
          - op-seq-el
```

> **Key things to notice vs the old block:**
> - `image` → `OP_XLAYER_IMAGE_TAG` (not `OP_STACK_IMAGE_TAG`)
> - `entrypoint` → `xlayer-kona-seq.sh` (not the op-node command block)
> - The long `command:` block with op-node flags is **gone entirely**
> - `depends_on: op-${SEQ_TYPE}-seq` is **gone** (no longer two services)
> - healthcheck uses `POST optimism_syncStatus` not `GET /` (kona-node returns 405 on GET)
> - `start_period` is `15s` not `3s` (reth needs time to start before kona health is reachable)

### 4c. Update downstream service references

Find and replace all remaining references to `op-${SEQ_TYPE}-seq` or `op-reth-seq` in the file:

| Location | Old value | New value |
|---|---|---|
| `op-conductor` command | `--execution.rpc=http://op-${SEQ_TYPE}-seq:8545` | `--execution.rpc=http://op-seq:8545` |
| `op-batcher` command | `--l2-eth-rpc=...op-${SEQ_TYPE}-seq:8545` | `--l2-eth-rpc=...op-seq:8545` |
| `op-challenger` command | `--l2-eth-rpc=http://op-${SEQ_TYPE}-seq:8545` | `--l2-eth-rpc=http://op-seq:8545` |
| `mempool-rebroadcaster` command | `--reth-mempool-endpoint=http://op-reth-seq:8545` | `--reth-mempool-endpoint=http://op-seq:8545` |

---

## Step 5 — Update `3-op-init.sh`

Find the `docker compose run` block that initialises the reth database.

```bash
# Change:
  op-reth-seq \

# To:
  op-seq \
```

Full context (the surrounding lines, for reference):
```bash
INIT_LOG=$(docker compose run --no-deps --rm \
  -v "$(pwd)/$CONFIG_DIR/genesis-reth.json:/genesis.json" \
  --entrypoint op-reth \
  op-seq \          # <-- this line changed
  init \
  --datadir="/datadir" \
  --chain=/genesis.json \
```

---

## Step 6 — Update `4-op-start-service.sh`

Find the single sequencer mode block:

```bash
# Change:
export OP_BATCHER_L2_ETH_RPC="http://op-${SEQ_TYPE}-seq:8545"

# To:
export OP_BATCHER_L2_ETH_RPC="http://op-seq:8545"
```

---

## Step 7 — Build the Image

```bash
cd devnet
docker build -f Dockerfile.xlayer-kona-seq -t op-xlayer:latest .
```

Expected output at the end:
```
op-reth --version  → shows reth version
kona-node --version → shows kona version
```

If either binary is missing the build will fail here — good, catches problems early.

---

## Step 8 — Run and Verify

```bash
# Full 4-step init + start sequence
./1-start-l1.sh
./2-deploy-op-contracts.sh
./3-op-init.sh
./4-op-start-service.sh

# Verify
docker compose ps                    # op-seq should show healthy
cast block latest --rpc-url http://localhost:8123   # L2 blocks advancing
cast rpc optimism_syncStatus --rpc-url http://localhost:9545  # safe/finalized advancing
docker logs op-seq -f                # watch for:
                                     #   [xlayer-kona-seq] op-reth is ready
                                     #   [xlayer-kona-seq] Starting kona-node...
                                     #   engine: Built and imported new unsafe block
```

---

## What You Should NOT See

If any of these appear, something went wrong:

| Error | Cause | Fix |
|---|---|---|
| `permission denied` on entrypoint | Script not executable — creating a file manually gives `644` not `755` | `chmod +x devnet/entrypoint/xlayer-kona-seq.sh` (or whatever you named it) |
| `no such service: op-reth-seq` | Old reference in init script | Re-check Step 5 |
| Container `unhealthy` despite blocks producing | healthcheck using GET not POST | Re-check Step 4b healthcheck |
| `port already allocated` on start | Old `op-reth-seq` container still running | `docker compose down --remove-orphans` |

---

## Summary of All Files Changed

| File | Action | What changed |
|---|---|---|
| `devnet/Dockerfile.xlayer-kona-seq` | **Created** | Multi-stage build combining both binaries |
| `devnet/entrypoint/xlayer-kona-seq.sh` | **Created** | Supervisor script: reth bg → wait → exec kona-node |
| `devnet/.env` | **Modified** | Add `OP_XLAYER_IMAGE_TAG`, fix `TRUSTED_PEERS` hostname |
| `devnet/docker-compose.yml` | **Modified** | Delete `op-reth-seq`, rewrite `op-seq`, update 4 downstream refs |
| `devnet/3-op-init.sh` | **Modified** | One line: `op-reth-seq` → `op-seq` |
| `devnet/4-op-start-service.sh` | **Modified** | One line: `op-${SEQ_TYPE}-seq` → `op-seq` |

---

## Step 9 — Assert You Are on Kona (Not op-node)

Run these checks after startup to confirm kona-node is running and the old op-node/op-geth setup is fully gone.

### Quick one-liner

```bash
docker exec op-seq kona-node --version && echo "✅ kona-node confirmed" || echo "❌ kona-node NOT found"
```

---

### Positive assertions — all must pass

```bash
# 1. Container is using the unified image (not op-stack:latest)
docker inspect op-seq --format '{{.Config.Image}}' | grep -q "op-xlayer" \
  && echo "✅ image: op-xlayer" \
  || echo "❌ FAIL: wrong image — $(docker inspect op-seq --format '{{.Config.Image}}')"

# 2. kona-node binary present inside container
docker exec op-seq which kona-node \
  && echo "✅ kona-node binary present" \
  || echo "❌ FAIL: kona-node binary not found"

# 3. kona-node version readable
docker exec op-seq kona-node --version 2>&1 | grep -q "kona-node Version" \
  && echo "✅ $(docker exec op-seq kona-node --version 2>&1 | head -1)" \
  || echo "❌ FAIL: unexpected kona-node version output"

# 4. op-reth binary also present (both must coexist)
docker exec op-seq which op-reth \
  && echo "✅ op-reth binary present" \
  || echo "❌ FAIL: op-reth binary not found"

# 5. kona-node RPC responding on port 9545
curl -sf -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | grep -q '"current_l1"' \
  && echo "✅ kona-node RPC responding (optimism_syncStatus OK)" \
  || echo "❌ FAIL: kona-node RPC not responding on :9545"

# 6. kona-node metrics port up
curl -sf http://localhost:9002/metrics | grep -q "kona" \
  && echo "✅ kona-node metrics on :9002" \
  || echo "❌ FAIL: kona metrics not found on :9002"

# 7. kona-node log signature in container logs
docker logs op-seq 2>&1 | grep -q "kona_node_service" \
  && echo "✅ kona_node_service logs confirmed" \
  || echo "❌ FAIL: kona_node_service not seen in logs"

# 8. L2 blocks advancing
BLOCK=$(cast block latest --rpc-url http://localhost:8123 2>/dev/null | grep "^number" | awk '{print $2}')
[ -n "$BLOCK" ] \
  && echo "✅ L2 block production confirmed (latest: $BLOCK)" \
  || echo "❌ FAIL: cannot reach L2 RPC on :8123"
```

---

### Negative assertions — all must be absent

```bash
# 1. op-reth-seq container must NOT exist
docker ps -a --filter name=op-reth-seq --format "{{.Names}}" | grep -q "op-reth-seq" \
  && echo "❌ FAIL: op-reth-seq container still running — old setup not fully removed" \
  || echo "✅ op-reth-seq container absent"

# 2. op-seq must NOT be using op-stack image (old op-node)
docker inspect op-seq --format '{{.Config.Image}}' | grep -q "op-stack" \
  && echo "❌ FAIL: op-seq is using op-stack image — still on old op-node" \
  || echo "✅ op-seq is NOT on op-stack image"

# 3. Engine API port 8552 must NOT be reachable from host
curl -sf --max-time 2 http://localhost:8552 > /dev/null 2>&1 \
  && echo "❌ FAIL: Engine API :8552 is exposed on host — security issue" \
  || echo "✅ Engine API :8552 not reachable from host (internal only)"

# 4. op-node log signatures must NOT appear
docker logs op-seq 2>&1 | grep -q "op-node" \
  && echo "❌ FAIL: op-node log signatures detected" \
  || echo "✅ No op-node log signatures"

# 5. Port 8552 must NOT be in external port bindings
docker inspect op-seq --format '{{json .HostConfig.PortBindings}}' | grep -q "8552" \
  && echo "❌ FAIL: port 8552 is bound externally" \
  || echo "✅ Port 8552 not bound externally"
```

---

### Run all checks in one block

```bash
echo "=== Kona Single-Image Assertions ==="
echo ""
echo "--- POSITIVE (must pass) ---"
docker inspect op-seq --format '{{.Config.Image}}' | grep -q "op-xlayer"             && echo "✅ image: op-xlayer"                   || echo "❌ wrong image"
docker exec op-seq which kona-node > /dev/null 2>&1                                   && echo "✅ kona-node binary present"           || echo "❌ kona-node binary missing"
docker exec op-seq which op-reth > /dev/null 2>&1                                     && echo "✅ op-reth binary present"            || echo "❌ op-reth binary missing"
curl -sf -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | grep -q '"current_l1"'                                       && echo "✅ kona-node RPC on :9545"            || echo "❌ kona-node RPC not responding"
curl -sf http://localhost:9002/metrics | grep -q "kona"                               && echo "✅ kona metrics on :9002"             || echo "❌ kona metrics not found"
docker logs op-seq 2>&1 | grep -q "kona_node_service"                                 && echo "✅ kona_node_service in logs"         || echo "❌ kona logs not found"
cast block latest --rpc-url http://localhost:8123 > /dev/null 2>&1                    && echo "✅ L2 RPC on :8123"                   || echo "❌ L2 RPC not responding"
echo ""
echo "--- NEGATIVE (must be absent) ---"
docker ps -a --filter name=op-reth-seq --format "{{.Names}}" | grep -q "op-reth-seq"  && echo "❌ op-reth-seq still running"        || echo "✅ op-reth-seq absent"
docker inspect op-seq --format '{{.Config.Image}}' | grep -q "op-stack"               && echo "❌ still on op-stack image"          || echo "✅ not on op-stack image"
curl -sf --max-time 2 http://localhost:8552 > /dev/null 2>&1                          && echo "❌ Engine API :8552 exposed"         || echo "✅ Engine API :8552 internal only"
docker inspect op-seq --format '{{json .HostConfig.PortBindings}}' | grep -q "8552"   && echo "❌ port 8552 bound externally"       || echo "✅ port 8552 not in bindings"
echo ""
echo "=== Done ==="
```

**Expected output on a healthy setup:**
```
=== Kona Single-Image Assertions ===

--- POSITIVE (must pass) ---
✅ image: op-xlayer
✅ kona-node binary present
✅ op-reth binary present
✅ kona-node RPC on :9545
✅ kona metrics on :9002
✅ kona_node_service in logs
✅ L2 RPC on :8123

--- NEGATIVE (must be absent) ---
✅ op-reth-seq absent
✅ not on op-stack image
✅ Engine API :8552 internal only
✅ port 8552 not in bindings

=== Done ===
```

---

## Step 10 — Run as a Standalone Image (The USP)

This is the key value of the single-image approach. Once built, `op-xlayer:latest`
is a self-contained sequencer. No xlayer-toolkit. No docker-compose. Just `docker run`.

You only need 5 config files — all produced by the 4-step init sequence.

---

### What you need

```
devnet/config-op/genesis-reth.json   → L2 genesis block
devnet/config-op/rollup.json         → L2 rollup config
devnet/config-op/jwt.txt             → JWT secret for Engine API auth
devnet/l1-geth/execution/genesis.json → L1 genesis
devnet/.env                          → all environment variables
```

These are chain-specific. They are NOT inside the image — mount them at runtime.

---

### Step 1 — Export the config files (once per devnet)

After running `./3-op-init.sh`, copy the config files to a portable directory:

```bash
mkdir -p ~/xlayer-standalone/config
mkdir -p ~/xlayer-standalone/data/reth
mkdir -p ~/xlayer-standalone/data/p2p
mkdir -p ~/xlayer-standalone/logs

cp devnet/config-op/genesis-reth.json   ~/xlayer-standalone/config/genesis.json
cp devnet/config-op/rollup.json         ~/xlayer-standalone/config/rollup.json
cp devnet/config-op/jwt.txt             ~/xlayer-standalone/config/jwt.txt
cp devnet/l1-geth/execution/genesis.json ~/xlayer-standalone/config/l1-genesis.json
cp devnet/.env                          ~/xlayer-standalone/config/.env
```

---

### Step 2 — Init the reth database (one-time only)

The reth database must be seeded from the L2 genesis before first run:

```bash
docker run --rm \
  -v ~/xlayer-standalone/config/genesis.json:/genesis.json:ro \
  -v ~/xlayer-standalone/data/reth:/datadir \
  --entrypoint op-reth \
  op-xlayer:latest \
  init --datadir=/datadir --chain=/genesis.json

echo "✅ reth database initialised"
```

Skip this step on subsequent runs — the database persists in `~/xlayer-standalone/data/reth`.

---

### Step 3 — Run the sequencer

```bash
docker run -d \
  --name xlayer-node \
  --network dev-op \
  -v ~/xlayer-standalone/config/genesis.json:/genesis.json:ro \
  -v ~/xlayer-standalone/config/rollup.json:/rollup.json:ro \
  -v ~/xlayer-standalone/config/jwt.txt:/jwt.txt:ro \
  -v ~/xlayer-standalone/config/l1-genesis.json:/l1-genesis.json:ro \
  -v ~/xlayer-standalone/config/.env:/.env:ro \
  -v ~/xlayer-standalone/data/reth:/datadir \
  -v ~/xlayer-standalone/data/p2p:/data \
  -v ~/xlayer-standalone/logs:/logs/reth \
  -e L1_RPC_URL_IN_DOCKER=http://l1-geth:8545 \
  -e L1_BEACON_URL_IN_DOCKER=http://l1-beacon-chain:3500 \
  -e SEQUENCER_P2P_KEY=${SEQUENCER_P2P_KEY} \
  -p 8123:8545 \
  -p 9545:9545 \
  -p 9223:9223 \
  -p 9001:9001 \
  -p 9002:9002 \
  op-xlayer:latest
```

> `--network dev-op` connects to the local devnet L1. For a remote L1, drop the network
> flag and set `L1_RPC_URL_IN_DOCKER` and `L1_BEACON_URL_IN_DOCKER` to your RPC endpoints.

---

### Step 4 — Verify it works

```bash
# Watch startup sequence
docker logs xlayer-node -f
# Expect to see:
#   [xlayer-kona-seq] op-reth is ready
#   [xlayer-kona-seq] Starting kona-node (consensus layer, foreground)...
#   engine: Built and imported new unsafe block  l2_number=...

# L2 blocks advancing
cast block latest --rpc-url http://localhost:8123

# Rollup sync status
cast rpc optimism_syncStatus --rpc-url http://localhost:9545
```

---

### What is NOT inside the image

| Provided by image | Must be mounted at runtime |
|---|---|
| `op-reth` binary | `/genesis.json` — L2 genesis |
| `kona-node` binary | `/rollup.json` — rollup config |
| `xlayer-kona-seq.sh` entrypoint | `/l1-genesis.json` — L1 genesis |
| System libs (`libssl3`, `curl`) | `/jwt.txt` — JWT secret |
| | `/.env` — environment variables |
| | `/datadir` — reth database (persistent) |
| | `/data` — kona-node P2P state (persistent) |
| | `/logs/reth` — log output |

---

### Hand it to another developer

To give someone else the image and have them run it independently:

```bash
# 1. Save the image to a tar file
docker save op-xlayer:latest | gzip > op-xlayer.tar.gz

# 2. Bundle the config files
tar czf xlayer-configs.tar.gz -C ~/xlayer-standalone/config .

# 3. Share both files
# They run:
#   docker load < op-xlayer.tar.gz
#   tar xzf xlayer-configs.tar.gz -C ~/xlayer-standalone/config
#   docker run ... op-xlayer:latest   (Step 3 above)
```

Or push to a registry:
```bash
docker tag op-xlayer:latest ghcr.io/yourorg/op-xlayer:latest
docker push ghcr.io/yourorg/op-xlayer:latest
# They run: docker pull ghcr.io/yourorg/op-xlayer:latest
```

**One image. Any machine. Zero build steps for the recipient.**

---

## Step 11 — Load Test (Validate TPS)

Run the adventure benchmark to confirm the sequencer handles load correctly.

### Prerequisites

```bash
# Check if adventure binary is already installed
which adventure || echo "not installed"

# If not installed, build it:
cd tools/adventure
make build
```

### Run the benchmark

**Terminal 1 — watch blocks:**
```bash
docker logs op-seq -f 2>&1 | grep "Block added to canonical chain"
```

**Terminal 2 — run load test:**
```bash
cd tools/adventure

# Step 1: Fund 20k test accounts (one-time, ~1-2 min)
adventure native-init 100ETH -f ./testdata/config.json

# Step 2: Wait for funding to settle
sleep 10

# Step 3: Run benchmark
adventure native-bench -f ./testdata/config.json
```

Or run all three steps in one command:
```bash
cd tools/adventure && make native
```

### What to look for

**In adventure output:**
```
TPS: 142.3  total_txs: 8540  elapsed: 60s
```

**In block logs (Terminal 1):**
```
txs=47 gas_throughput=805Mgas/second full=0.02% elapsed=57µs
```

**Expected warning — safe to ignore:**
```
WARN kona_node_service: Failed to publish unsafe payload: PublishError(NoPeersSubscribedToTopic)
```
This is normal on devnet — no peer nodes are connected. Does not affect TPS or block production.

### Config reference

`tools/adventure/testdata/config.json`:
```json
{
  "rpc": ["http://127.0.0.1:8123"],
  "concurrency": 20,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": 100
}
```

Adjust `concurrency` up to increase load pressure. `targetTPS: 0` means unlimited — runs as fast as possible.
