# Bench Guide — Build · Run · Debug · Read Reports

XLayer is an OP Stack L2 chain. This bench system measures how fast different **Consensus Layer
(CL)** implementations can drive the shared **Execution Layer (EL)** — OKX reth — to fill blocks
under high transaction load. The CL tells reth _when_ to build a block; reth does the actual
building. A faster CL gives reth more time per 1-second slot, which means fuller blocks and
higher throughput.

**CLs available:** `op-node` (Go) · `kona-okx-optimised` / `kona-okx-baseline` (Rust/OKX) ·
`base-cl` (Rust/Coinbase)

**EL:** OKX reth — identical binary and config across all CL runs.

For architecture details and optimisation analysis, see [`bench/presentation/presentation.md`](presentation/presentation.md).

---

> **Run all commands from the repo root** (`xlayer-toolkit/`).
> Scripts live in `bench/`, docker-compose lives in `devnet/`.

## Glossary

| Term | Meaning |
|---|---|
| **CL (Consensus Layer)** | The component that decides _when_ to build a block and _what L1 data_ to include. Examples: op-node, kona, base-cl. Communicates with the EL via the Engine API. |
| **EL (Execution Layer)** | The component that actually builds and executes blocks. In this bench system, always OKX reth. Receives instructions from the CL. |
| **Engine API** | JSON-RPC protocol between CL and EL. Key calls: `engine_forkchoiceUpdatedV3` (trigger block build), `engine_getPayloadV3` (retrieve built block), `engine_newPayloadV3` (validate and import block). |
| **FCU (`forkchoiceUpdated`)** | Short for `engine_forkchoiceUpdatedV3`. When sent with `payloadAttributes`, it triggers reth to start building a new block. |
| **PayloadAttributes** | The set of parameters (timestamp, gas limit, L1 origin, deposits) the CL assembles and sends with FCU to tell reth how to build the next block. |
| **Block Build Initiation** | The full cycle from the CL's 1-second tick firing to reth acknowledging the build request. This is the primary metric we benchmark. |
| **Safe head** | The latest L2 block whose data has been confirmed on L1 via the batcher. The CL advances this by running the derivation pipeline. |
| **Derivation** | The process of reading L1 batch data and re-deriving L2 blocks from it. Advances the safe head. Generates `Consolidate` tasks in kona/base-cl. |
| **TPS** | Transactions per second — confirmed on-chain, not just submitted to mempool. |
| **Block fill** | `gasUsed ÷ gasLimit × 100` — how full each block is. 100% = reth used the entire gas budget. |
| **adventure** | Go-based transaction sender that generates ERC20 transfer load. Runs two parallel instances with independent deployer keys. |

## Quick Start

```bash
# Build images (first time only)
bash bench/build-bench-images.sh

# Single run — 200M gas (default)
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure

# Single run — 500M gas (use 40 workers to saturate)
bash bench/bench.sh op-node --gas-limit 500M --duration 120 --workers 40 --sender adventure

# Grouped session — all CLs in one comparison report
export SESSION_TS=$(date +%Y%m%d_%H%M%S)
SESSION_TS=$SESSION_TS bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure
# → bench/runs/adv-erc20-20w-120s-200Mgas-{SESSION_TS}/comparison.md
```

---

## Prerequisites

```bash
pip3 install eth-account   # Python metrics collection
cast --version             # Foundry cast
docker compose version     # must be v2.x
go version                 # 1.21+ (builds adventure binary)

# Build adventure binary (once, or after source changes)
cd tools/adventure && make build
# lands at: $(go env GOPATH)/bin/adventure
```

Source repos and branches are configured in `devnet/.env` (Bench CL Image Sources section).

---

## Repo Setup

### Clone the required repositories

The bench system builds Docker images from local git clones. You need these repos:

```
~/Documents/bench/
├── okx-optimism/          ← OKX fork of kona (KONA_OKX_REPO)
├── okx-reth/              ← OKX reth EL (OP_RETH_LOCAL_DIRECTORY)
├── optimism/              ← Go op-node (OP_STACK_LOCAL_DIRECTORY)
└── base-base/             ← Coinbase base-cl (BASE_CL_REPO)
```

Clone each repo and check out the appropriate branch. The exact repos and branches are
defined in `devnet/.env`.

### Configure `devnet/.env`

Edit `devnet/.env` to point each `*_LOCAL_DIRECTORY` and `*_REPO` variable at your local
clones. The key variables:

```bash
# CL sources
KONA_OKX_REPO=/path/to/okx-optimism
KONA_OKX_BASELINE_BRANCH=dev
KONA_OKX_FIX_BRANCH=fix/kona-engine-drain-priority

BASE_CL_REPO=/path/to/base-base

# EL source
OP_RETH_LOCAL_DIRECTORY=/path/to/okx-reth
OP_RETH_BRANCH=dev

# Go op-node source
OP_STACK_LOCAL_DIRECTORY=/path/to/optimism
```

After editing, verify paths are correct:

```bash
ls -d $(grep '_REPO\|_LOCAL_DIRECTORY' devnet/.env | grep -v '^#' | cut -d= -f2 | grep -v '^$')
```

---

## Step 1 — Build CL Images

### Check what you already have

```bash
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" \
    | grep -E "^(kona-node|base-consensus)"
```

Cross-reference against the table below. **Build only what is missing or stale.**

> The `^` anchor limits output to locally-built images. Any `ghcr.io/...` prefixed kona images
> are unrelated upstream pulls — not part of this bench system.

### When to rebuild

| Situation | Action |
|---|---|
| First time setup | `bash bench/build-bench-images.sh` (all) |
| Image tag missing from `docker images` | Build that specific target |
| Pulled new commits on a branch | Rebuild that variant |
| Branch/repo changed in `.env` | Rebuild affected variant |

### Build commands

```bash
# Build everything (first time, or after branch changes)
bash bench/build-bench-images.sh

# Build a specific image
bash bench/build-bench-images.sh kona-okx-baseline       # kona-node:okx-baseline
bash bench/build-bench-images.sh kona-okx-optimised      # kona-node:okx-optimised
bash bench/build-bench-images.sh kona-all                # all kona variants
bash bench/build-bench-images.sh base-cl                 # base-consensus:dev
```

Build times: kona ~15–20 min (Rust). base-cl ~5 min. Reth is built by `init.sh`, not here.

**Naming convention:** `-baseline` = unpatched reference. `-optimised` = Engine Priority Drain fix applied.

### Build target → image → bench.sh argument

| Build target | Docker image | `bench.sh` argument |
|---|---|---|
| `kona-okx-baseline` | `kona-node:okx-baseline` | `kona-okx-baseline` |
| `kona-okx-optimised` | `kona-node:okx-optimised` | `kona-okx-optimised` |
| `base-cl` | `base-consensus:dev` | `base-cl` |

---

## Devnet Startup (First Time)

`bench.sh` handles all devnet lifecycle automatically — you do **not** need to start the
devnet manually. When you run `bench.sh`, it will:

1. Tear down any running stack
2. Start L1 (geth + Prysm beacon chain) with a fresh genesis
3. Fund operator accounts (batcher, proposer, challenger) on L1
4. Deploy OP contracts to L1
5. Initialize L2 genesis
6. Start L2 services (reth EL + chosen CL + batcher)
7. Wait for engine API readiness (blocks advancing)
8. Wait for derivation pipeline to sync (safe head catches up)

**First run takes ~4 minutes** (L1 init + contract deploy + L2 genesis). Subsequent runs
with the same CL skip the startup entirely (~0s). Switching between CLs takes ~30–60s.

### Manual devnet start (without bench.sh)

If you need the devnet running for non-bench work:

```bash
cd devnet
bash init.sh                   # builds images (op-node, reth, etc.)
bash 1-start-l1.sh             # starts L1 geth + beacon chain
bash 2-deploy-op-contracts.sh  # deploys OP contracts to L1
bash 3-op-init.sh              # generates L2 genesis
bash 4-op-start-service.sh     # starts L2 services

# Verify
cast bn --rpc-url http://localhost:8123   # L2 block number (should increase)
cast bn --rpc-url http://localhost:8545   # L1 block number
```

---

## Step 2 — Run Benchmarks

All runs go through `bench.sh`. It handles stack switching, fresh chain init, and report
generation. No separate scripts needed.

### Available consensus layers

| `bench.sh` argument | Docker image | CL |
|---|---|---|
| `op-node` | `op-stack:latest` | Go op-node (Optimism reference) |
| `kona-okx-baseline` | `kona-node:okx-baseline` | Rust kona — OKX fork, no optimisations |
| `kona-okx-optimised` | `kona-node:okx-optimised` | Rust kona — OKX fork + Engine Priority Drain fix |
| `base-cl` | `base-consensus:dev` | Rust base-consensus (Coinbase) |

All share the same EL: `op-reth-seq` (OKX reth).

### All bench.sh flags

```bash
bash bench/bench.sh <CL> [--gas-limit 200M|500M] [--duration N] [--workers N] [--sender adventure] [--contract 0x...]
```

| Flag | Default | Meaning |
|---|---|---|
| `<CL>` | required | CL name from table above |
| `--gas-limit 200M\|500M` | (unchanged) | Patch gas limit in intent.toml before stack start |
| `--duration N` | 120 | Measurement window in seconds |
| `--workers N` | 20 | Goroutines per adventure instance (×2 instances; 200M → 40 total, 500M → 80 total) |
| `--warmup N` | 30 | Seconds to pre-fill mempool before measurement |
| `--sender adventure` | — | Use adventure ERC20 sender (required for high-load bench) |
| `--contract 0x...` | (empty) | Skip erc20-init, reuse existing ERC20 contract address |

> **Gas limit / worker count pairing:**
> - 200M gas → 20 workers (20 × 2 instances = 40 total; ~14,000 TX/s send rate — 50k accounts saturate)
> - 500M gas → 40 workers (40 × 2 instances = 80 total; ~28,000 TX/s send rate needed to fill 14,286 TX/s ceiling with buffer)

### Option A — Single CL run

```bash
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure
```

### Option B — Grouped session (multiple CLs → shared comparison.md)

Set `SESSION_TS` before the first run. All CLs land in the same `bench/runs/` dir and
`comparison.md` is auto-generated when ≥2 CLs complete.

```bash
export SESSION_TS=$(date +%Y%m%d_%H%M%S)

SESSION_TS=$SESSION_TS bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure
```

### Option C — Kona baseline vs optimised

```bash
export SESSION_TS=$(date +%Y%m%d_%H%M%S)

SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-baseline  --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
```

### Option D — Reuse existing contract (skip erc20-init)

If erc20-init ran on this chain already and you have the contract address:

```bash
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure \
    --contract 0xYourERC20ContractAddress
```

### Option E — Run bench-adventure.sh directly (bypass stack switching)

Useful when the devnet is already running and you don't want bench.sh to restart containers:

```bash
SEQ_CONTAINER=op-seq bash bench/scripts/bench-adventure.sh \
    --stack op-node --duration 120 --workers 20
```

### Rebuild one variant and re-bench

```bash
bash bench/build-bench-images.sh kona-okx-optimised
bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
```

---

## Step 3 — Read Reports

Reports land in `bench/runs/{session-dir}/`.

### Session directory name

`adv-erc20-{W}w-{D}s-{gas}gas-{SESSION_TS}`

Example: `adv-erc20-20w-120s-200Mgas-20260404_150219`

### Files in each session dir

| File | Contents |
|---|---|
| `{cl}.md` | Human-readable report: TPS, FCU latency, block fill, safe lag, reth EL timings |
| `{cl}.json` | Machine-readable sidecar — same data, feeds comparison.md generator |
| `comparison.md` | Auto-generated when ≥2 CL JSON files exist — side-by-side table with verdict |
| `detailed-report.md` | Extended per-metric breakdown with percentile distributions |

### Key metrics to read first

| Metric | What it measures | Why it matters |
|---|---|---|
| **TPS** | Confirmed TX/s over the measurement window | Are we saturating the gas ceiling? |
| **Block fill avg** | Average gas used / gas limit across all blocks | < 90% = not saturated |
| **FCU+attrs median** | Typical SequencerActor→reth build round-trip (CL log) | Normal sequencer health |
| **FCU+attrs 99th percentile** | Tail latency — 1 in 100 blocks exceeded this | Derivation contention shows up here |
| **FCU+attrs max** | Single worst block in the entire run | "How bad was the worst moment?" |
| **Safe lag avg / worst** | `unsafe_head − safe_head` in blocks | Lower = faster L1 confirmation |

### Understanding the numbers

| Metric | Good | Concerning | Meaning |
|---|---|---|---|
| Block TPS | ~5700 TX/s (200M) | < 1000 TX/s | Confirmed txs per second |
| fill median | ~100% | < 50% | Sustained saturation |
| FCU+attrs median | < 2ms | > 10ms | Normal CL→reth round-trip |
| FCU+attrs 99th percentile | < 10ms | > 30ms | Tail latency under derivation load |
| safe_lag avg | < 70 blocks | > 200 blocks | Batcher L1 confirmation speed |

> **What FCU+attrs latency actually measures:** The clock starts in `SequencerActor` when it
> sends the Build request and stops when `payloadId` returns. It includes channel queue wait
> time (Build waiting behind Consolidates) + HTTP round-trip to reth. The fix reduces the
> queue wait component, not reth's processing speed.

> See `report-read-guide.md` for complete metric definitions and percentile explanations.

---

## Full Walkthrough — Zero to Report

```bash
# 1. Verify chain is running
docker compose -f devnet/docker-compose.yml ps
cast bn --rpc-url http://localhost:8123   # should return > 0

# 2. Check deployer balance (auto top-up kicks in at < 3000 ETH)
cast balance 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
    --rpc-url http://localhost:8123 --ether

# 3. Run the bench
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure

# 4. What you will see:
#   ── Checking adventure binary...
#   ── Checking deployer balance...       ← may top-up from whale automatically
#   ── Running erc20-init A+B in parallel...
#   ⚠️  Init takes ~7-10 min...           ← one-time per fresh chain
#   ✅ ERC20-A deployed, 25k accounts funded
#   ✅ ERC20-B deployed, 25k accounts funded
#   ── Warm-up phase (30s)...
#   ── Measurement phase (120s)...
#   ── Parsing metrics...
#   ✅ Report saved → bench/runs/.../op-node.md

# 5. View the report
ls -lt bench/runs/ | head -3
cat "bench/runs/$(ls -t bench/runs/ | head -1)/op-node.md"
```

---

## Debugging

### Is the chain up?

```bash
cast bn --rpc-url http://localhost:8123
# 0 or error → chain not running

docker compose -f devnet/docker-compose.yml ps
# look for "Exited" or "Restarting" containers

docker compose -f devnet/docker-compose.yml logs op-reth-seq --tail 50
docker compose -f devnet/docker-compose.yml logs op-seq --tail 50
```

### erc20-init failed

Symptom: `erc20-init A failed (rc=1)` or `no ERC20 address`

```bash
ADVENTURE_BIN=$(go env GOPATH)/bin/adventure

cat > /tmp/adv-init-debug.json <<EOF
{
  "rpc": ["http://localhost:8123"],
  "accountsFilePath": "tools/adventure/testdata/accounts-25k-A.txt",
  "senderPrivateKey": "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "concurrency": 1,
  "mempoolPauseThreshold": 50000,
  "targetTPS": 0,
  "maxBatchSize": 100,
  "gasPriceGwei": 100,
  "saveTxHashes": false
}
EOF

$ADVENTURE_BIN erc20-init 0.2ETH -f /tmp/adv-init-debug.json
# "contract deployment timeout" → chain slow or not producing blocks
# "insufficient funds"          → deployer drained (auto top-up should catch this)
# "Failed to query nonce"       → RPC not reachable
```

### Deployer out of ETH

```bash
cast balance 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
    --rpc-url http://localhost:8123 --ether

# Manual top-up from whale
cast send \
    --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
    --value 5000ether \
    0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
    --rpc-url http://localhost:8123 --legacy
```

### Low TPS / under-saturated blocks

```bash
# Look at fill distribution in the report:
# fill_p10=0%, fill_p90=100% → bimodal → not enough accounts to sustain saturation
# fill median < 80%          → send rate too low

# Account count check
wc -l tools/adventure/testdata/accounts-25k-A.txt   # must be 25000

# Gas ceiling math:
# gas_limit / 35000 = max TPS   (200M / 35k = 5714,  500M / 35k = 14286)
# Need ≥ gas_ceiling accounts to sustain full saturation
```

### Python crash — partial report

Symptom: `⚠️ Bench exited with code 1 — partial report saved`

```bash
tail -50 bench/runs/adv-erc20-.../op-node.md
# Look for Python traceback at the bottom
# If CL docker logs were empty for a metric, the key will be None — add `or {}` guard
```

### Mempool stuck — txs not mined

```bash
cast rpc txpool_status --rpc-url http://localhost:8123
# High "queued" count → reth queued-promotion bug
# → accounts stuck. Re-run erc20-init to re-fund fresh accounts.

docker compose -f devnet/docker-compose.yml logs op-reth-seq --since 10m \
    | grep -i "queue\|pending\|pool"
```

---

## Common Commands Cheatsheet

```bash
# ── Devnet health ───────────────────────────────────────────────────────────────
docker compose -f devnet/docker-compose.yml ps
cast bn --rpc-url http://localhost:8123                         # L2 block number
cast bn --rpc-url http://localhost:8545                         # L1 block number
cast balance 0x3C44... --rpc-url http://localhost:8123 --ether  # deployer ETH

# ── Build images ────────────────────────────────────────────────────────────────
bash bench/build-bench-images.sh                              # all images
bash bench/build-bench-images.sh kona-okx-optimised          # one image

# ── Run benchmarks — 200M gas (20 workers) ──────────────────────────────────────
bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure

# ── Run benchmarks — 500M gas (40 workers) ──────────────────────────────────────
bash bench/bench.sh op-node            --gas-limit 500M --duration 120 --workers 40 --sender adventure
bash bench/bench.sh kona-okx-optimised --gas-limit 500M --duration 120 --workers 40 --sender adventure
bash bench/bench.sh base-cl            --gas-limit 500M --duration 120 --workers 40 --sender adventure

# ── Grouped session — 200M ──────────────────────────────────────────────────────
export SESSION_TS=$(date +%Y%m%d_%H%M%S)
SESSION_TS=$SESSION_TS bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure

# ── View latest report ──────────────────────────────────────────────────────────
ls -lt bench/runs/ | head -5
cat "bench/runs/$(ls -t bench/runs/ | head -1)/op-node.md"
cat "bench/runs/$(ls -t bench/runs/ | head -1)/comparison.md"

# ── Manual deployer top-up ──────────────────────────────────────────────────────
cast send \
    --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
    --value 5000ether \
    0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
    --rpc-url http://localhost:8123 --legacy

# ── Mempool inspection ──────────────────────────────────────────────────────────
cast rpc txpool_status --rpc-url http://localhost:8123
cast rpc txpool_content --rpc-url http://localhost:8123 | python3 -m json.tool | head -50

# ── Live monitoring ─────────────────────────────────────────────────────────────
watch -n1 'cast block latest --rpc-url http://localhost:8123 | grep -E "number|gasUsed|gasLimit"'
docker compose -f devnet/docker-compose.yml logs -f op-reth-seq
docker compose -f devnet/docker-compose.yml logs -f op-seq
docker compose -f devnet/docker-compose.yml logs -f op-kona
docker compose -f devnet/docker-compose.yml logs -f op-base-cl
```

---

## Key Addresses (devnet only — never use on mainnet)

| Role | Address | Private key |
|---|---|---|
| Deployer (instance A) | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111...` |
| Whale (instance B) | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e...` |

Standard Hardhat dev accounts — public knowledge, no secrets.

---

## Component Map

```
Your machine (repo root: xlayer-toolkit/)
├── bench/bench.sh           ← stack switcher + report orchestrator
├── bench/scripts/bench-adventure.sh ← load test driver (7 phases)
├── adventure (binary)       ← Go tx sender, 2 instances in parallel
└── Python inline scripts    ← block scan, docker log parsing, report

Docker containers
├── l1-geth + l1-beacon-chain       ← L1 Ethereum
├── op-reth-seq                     ← L2 EL (OKX reth)
│     :8123  JSON-RPC  ← adventure sends 40–80 goroutines × ERC20 txs here
│     :8552  authrpc   ← CL sends FCU + new_payload here every 1s
├── op-seq / op-kona / op-base-cl   ← L2 CL (one at a time)
├── op-batcher                      ← posts L2 batch data → L1
└── op-proposer                     ← posts L2 output roots → L1
```

### What each component does during a run

**L2 EL — `op-reth-seq`:** Most stressed component. Receives 40–80 goroutines (depending on gas limit) of ERC20 txs on
`:8123`, processes Engine API (FCU + new_payload) on `:8552` every 1s. Under bench: blocks
at 100% fill (5700–6000 txs at 200M gas).

**L2 CL — `op-seq` / `op-kona` / `op-base-cl`:** Drives block production every ~1s:
FCU+attrs → getPayload → new_payload. Simultaneously watches L1 for batch data → advances
safe_head (derivation). Gossips new unsafe blocks to P2P.

**`op-batcher`:** Reads unsafe L2 blocks, compresses tx data, submits calldata to L1.
~1 L1 tx per L2 epoch. Does not affect bench TPS directly.

---

## Repo Sources (`devnet/.env`)

| Image | Repo var | Branch var |
|---|---|---|
| `kona-node:okx-baseline` | `KONA_OKX_REPO` | `KONA_OKX_BASELINE_BRANCH` (`dev`) |
| `kona-node:okx-optimised` | `KONA_OKX_REPO` | `KONA_OKX_FIX_BRANCH` (`fix/kona-engine-drain-priority`) |
| `base-consensus:dev` | `BASE_CL_REPO` | current HEAD |
| `op-reth:latest` | `OP_RETH_LOCAL_DIRECTORY` | `OP_RETH_BRANCH` |

To change a repo or branch: edit `devnet/.env` → `bash bench/build-bench-images.sh <target>`.

---

## Internals — How bench-adventure.sh Works

### Phase walkthrough

```
boot
 │
 ├─ [SETUP]     Build adventure binary, verify accounts-50k.txt, write JSON configs
 │
 ├─ [TOP-UP]    Check deployer balance → top-up from whale if < 3000 ETH
 │
 ├─ [INIT]      erc20-init A (DEPLOYER_KEY) ──┐  parallel, ~7-10 min each
 │              erc20-init B (WHALE_KEY)    ──┘
 │              → deploys BatchTransfer + ERC20 contracts
 │              → funds 25k accounts each: 0.2 ETH + 100M ERC20 tokens shared
 │
 ├─ [WARM-UP]   Both adventure instances flood mempool for 30s
 │              Measurement NOT yet started — mempool fills to saturation
 │
 ├─ [MEASURE]   START_BN = cast bn  ← measurement window begins here
 │              Safe-lag poller (1 sample/s to rollup_rpc) starts
 │              120s passes — blocks fill at 100% throughout
 │              Both adventure instances killed
 │
 ├─ [PARSE]     Python: scans blocks START_BN+1 → START_BN+120
 │                      reads docker logs: CL (FCU/new_payload durations) + reth (engine::tree)
 │                      reads safe-lag JSON
 │
 └─ [REPORT]    Markdown → bench/runs/{run-type}-{ts}/{cl}.md
                JSON sidecar written alongside for comparison generator
```

### Why warmup?

Without warmup, the first blocks of the measurement window would be partially empty — the
mempool hasn't filled yet. The 30s warmup ensures every block in the measurement window
immediately fills to 100%, measuring **steady-state throughput**, not the ramp-up.

```
Without warmup:          With warmup:
Block N:    5% fill      Block N:   100% fill  ← measurement starts here
Block N+2: 60% fill      Block N+1: 100% fill
Block N+4: 100% fill     Block N+2: 100% fill
```

### Account math — two constraints for saturation

reth has a **queued-promotion bug**: if tx nonce N+1 arrives before N is mined, it goes to
reth's "queued" sub-pool and is never promoted. Each account holds exactly 1 live tx in the
pending pool at any time. This creates two independent constraints:

**Constraint 1 — Send rate must exceed mine rate**

```
Gas ceiling:    200M / 35k gas per ERC20 = 5,714 TX/s   (blocks drain pool at this rate)
                500M / 35k gas per ERC20 = 14,286 TX/s

Adventure send rate (20 workers × 2 instances = 40 total):  ~14,000 TX/s
Adventure send rate (40 workers × 2 instances = 80 total):  ~28,000 TX/s

200M (40 total workers):  14,000 ÷  5,714 = 2.5× surplus  → pool always refills between blocks ✅
500M (80 total workers):  28,000 ÷ 14,286 = 2.0× surplus  → sustained saturation ✅
```

**Constraint 2 — Pool must be deep enough to absorb block drain**

```
Pool depth = accounts / TXs per block

200M:  50k accounts ÷  5,714 = 8.7 blocks deep  → plenty of buffer ✅
500M:  50k accounts ÷ 14,286 = 3.5 blocks deep  → sufficient buffer ✅
```

**What "bimodal" looks like (under-provisioned workers warning):**

If you run 500M with only 20 workers per instance (40 total), the send rate (~14,000 TX/s) barely
matches the drain rate (14,286 TX/s). The pool empties between blocks, causing bimodal fill:

```
Bimodal (500M, 20 workers per instance):   Saturated (500M, 40 workers per instance):
Block N:   100% fill                       Block N:   100% fill
Block N+1:   4% fill  ← pool              Block N+1: 100% fill
Block N+2: 100% fill    emptied            Block N+2: 100% fill
Block N+3:   8% fill  before              Block N+3: 100% fill
              refill
Average: ~41%  ← misleading               Average: ~99.8%
```

Not "partially filled" — two distinct modes (near-empty alternating with full). The average of
~41% is deceiving; the histogram has two peaks at 0–10% and 95–100%.
Always use the recommended worker count for each gas limit (20 for 200M, 40 for 500M).

### Init design: parallel instances, separate deployer keys

Two adventure instances (A and B) use different deployer keys so their init txs have
independent nonce sequences and can run in parallel — cutting init time from ~14 min to ~7 min.

| Instance | Deployer key | Accounts |
|---|---|---|
| A | `DEPLOYER_KEY` (0x3C44...) | accounts-25k-A.txt (first 25k) |
| B | `WHALE_KEY` (0x70997970...) | accounts-25k-B.txt (last 25k) |

Init uses `concurrency=1` to avoid the reth queued-promotion bug during nonce sequencing.

### Metrics source table

| Metric | Source | Log pattern |
|---|---|---|
| Block TPS / fill | On-chain blocks | Python `eth_getBlockByNumber` scan |
| Mempool send rate | adventure log | `[Summary] Average BTPS:` |
| FCU+attrs latency | CL docker logs | `block build started fcu_duration=` (kona/base-cl); `FCU+attrs ok fcu_duration=` (op-node) |
| FCU (derivation) latency | CL docker logs | `Updated safe head via follow safe fcu_duration=` (kona) |
| new_payload latency | CL docker logs | `Inserted new unsafe block insert_duration=` |
| Block import / seal | CL docker logs | `Built and imported new block block_import_duration=` (kona) |
| reth EL timings | reth docker logs | `engine::tree fcu_with_attrs latency=` / `new_payload latency=` |
| Safe lag | `optimism_syncStatus` | 1 sample/s poller on rollup_rpc |

### Known bugs and fixes

| Bug | Symptom | Fix |
|---|---|---|
| reth queued-promotion | init funding txs stuck in queued, never mined | `concurrency=1` + wait for committed nonce per batch |
| Deployer depleted | `erc20-init` fails "insufficient funds" | Auto top-up from whale before init |
| bench.sh silent empty dirs | Crash leaves empty run dir, no report | `set +o pipefail` + `PIPESTATUS[0]` + always write report |
| Python NoneType crash | `AttributeError: 'NoneType' has no attribute 'get'` | `(op_node.get(key) or {})` guard |
| 500-account TPS floor | 696 TX/s instead of ~5714 TX/s | Switched to 25k accounts per instance |

### Files and locations

```
bench/bench.sh                    ← orchestrator (entry point)
bench/build-bench-images.sh       ← builds CL docker images (entry point)
bench/bench-orchestrate.sh        ← multi-CL unattended runner (entry point)
bench/scripts/bench-adventure.sh  ← load test driver, 7 phases (internal)
bench/scripts/generate-report.py  ← detailed-report.md generator (internal)
tools/adventure/            ← Go source for adventure binary
tools/adventure/testdata/
  accounts-50k.txt          ← master key file (50k private keys)
  accounts-25k-A.txt        ← first 25k (instance A — DEPLOYER_KEY)
  accounts-25k-B.txt        ← last 25k  (instance B — WHALE_KEY)
devnet/docker-compose.yml   ← stack definitions (used by bench.sh internally)

bench/runs/{run-type}-{ts}/{cl}.md   ← auto-generated report
bench/runs/{run-type}-{ts}/{cl}.json ← machine-readable sidecar
bench/runs/{run-type}-{ts}/comparison.md ← auto-generated when ≥2 JSON files exist
```

---

## Stack Switching

`bench.sh` manages which CL is running. Only one CL runs at a time — all share the same
reth EL and L1.

### What happens during a switch

When you run `bench.sh kona-okx-optimised` and op-node is currently active:

1. **Teardown**: all containers stopped and removed (L1 + L2 + batcher)
2. **Fresh L1 genesis**: L1 reinitialised at current time (avoids Prysm beacon catch-up)
3. **OP contracts redeployed** to fresh L1
4. **L2 genesis regenerated** with current gas limit config
5. **New CL started** with reth EL and batcher
6. **Engine readiness check**: waits for blocks to advance (CL→reth engine API working)
7. **Derivation sync check**: waits for `unsafe_head − safe_head` gap to shrink below 10

**Why always fresh genesis?** The L1 uses Prysm, which enters a slow beacon catch-up mode
after a restart. Fresh genesis at current time avoids this entirely.

### Same-CL re-run (no switch)

If the requested CL is already running and healthy (blocks advancing), bench.sh skips all
startup steps and goes straight to the load test. This makes back-to-back runs on the same
CL nearly instant.

### Forcing a fresh start

Use `--force-clean` to tear down and reinitialise even when the same CL is already running:

```bash
bash bench/bench.sh kona-okx-optimised --force-clean --gas-limit 500M --duration 120 --workers 40 --sender adventure
```

This is useful when you want to reset chain state (e.g., after a failed run left stale data).

---

## Expected Run Times

| Phase | Duration | Notes |
|---|---|---|
| Stack switch (different CL) | ~60–90s | L1 init + contract deploy + L2 genesis + engine ready |
| Stack switch (same CL, healthy) | ~0s | Skipped entirely |
| Image build (kona, first time) | ~15–20 min | Rust compilation |
| Image build (base-cl) | ~5 min | Rust compilation |
| Image build (op-node) | ~2 min | Go compilation |
| erc20-init (first run per chain) | ~7–10 min | Deploys contracts + funds 50k accounts |
| erc20-init (reuse contract) | ~0s | Pass `--contract 0x...` to skip |
| Warmup | 30s | Fills mempool to saturation |
| Measurement | 120s (configurable) | Steady-state throughput capture |
| Report generation | ~5s | Block scan + log parsing + markdown |

**Total for a single run (first time, new CL):** ~12–15 min
**Total for a re-run (same CL, reuse contract):** ~3 min (warmup + measurement + report)

**Grouped session (3 CLs):** ~40–50 min total (each CL switch reinitialises, but erc20-init
runs fresh for each since chain state is wiped).

---

## Cleanup and Reset

### Stop all containers

```bash
docker compose -f devnet/docker-compose.yml down --remove-orphans --timeout 10
```

### Wipe Docker volumes (full reset)

Removes all chain data (L1 + L2). Next `bench.sh` run will reinitialise from scratch.

```bash
docker compose -f devnet/docker-compose.yml down -v --remove-orphans
```

### Remove built images

```bash
docker rmi kona-node:okx-baseline kona-node:okx-optimised \
           base-consensus:dev 2>/dev/null
```

### Clean stale run directories

```bash
# List empty or incomplete run dirs
find bench/runs -maxdepth 1 -type d -empty
# Remove them
find bench/runs -maxdepth 1 -type d -empty -delete
```

### Force-clean a stuck bench

If a previous run left containers in a bad state:

```bash
bash bench/bench.sh <CL> --force-clean --gas-limit 500M --duration 120 --workers 40 --sender adventure
```

`--force-clean` tears down everything and reinitialises from scratch, regardless of current state.

---

## Sample Report Walkthrough

A per-CL report (e.g., `kona-okx-optimised.md`) has these sections. Here's what to look at:

### 1. Run metadata

Confirms the test configuration — chain ID, gas limit, worker count, measurement window.
Check that `Saturated = YES` — if not, results are unreliable (send rate too low).

### 2. Transaction summary

| What to check | Healthy | Problem |
|---|---|---|
| `Txs confirmed on-chain` | Close to submitted count | Large gap = txs stuck in mempool |
| `Tx errors` | 0 | > 0 = adventure hit RPC errors |

### 3. Throughput

The headline metric. **Block-inclusion TPS** is the ground truth — confirmed txs divided by
actual chain time. Compare against the theoretical ceiling (`gas_limit / 35000`).

### 4. Block fill distribution

| What to check | Healthy | Problem |
|---|---|---|
| `p10 fill` | > 95% | < 50% = under-saturated or bimodal |
| `median fill` | ~100% | < 80% = send rate too low |
| `p10` much lower than `p90` | Bimodal | Increase workers or accounts |

### 5. Engine API latency (CL → reth)

The core benchmark data. Read in this order:

1. **Block Build Initiation — End to End Latency median**: typical block-build trigger time
2. **Block Build Initiation — End to End Latency 99th percentile**: worst-case under load
3. **RequestGenerationLatency**: time to assemble PayloadAttributes (dominated by RPC calls)
4. **QueueDispatchLatency**: time waiting in the engine queue (scheduling contention)
5. **HttpSender-RoundtripLatency**: HTTP round-trip to reth (irreducible ~1–4ms)

### 6. reth EL internal timings

Parsed from reth's own docker logs. Shows how long reth itself took to process each Engine API
call. If CL latency is high but reth latency is low, the bottleneck is in the CL.

### 7. Safe lag

`unsafe_head − safe_head` in blocks. Measures how quickly the derivation pipeline catches up.
Lower is better. High safe lag under load can indicate derivation backpressure.

### comparison.md

Auto-generated when ≥2 CL JSON files exist in the same session directory. Contains:
- Side-by-side throughput table
- Latency breakdown for all CLs
- Verdict section identifying the best/worst CL per metric

---

## Cross-References

| Topic | Document |
|---|---|
| Architecture, actor model, Engine API flow | [`bench/presentation/presentation.md`](presentation/presentation.md) §4.1 |
| kona optimisations (Chain Config Cache, Engine Priority Drain) | [`bench/presentation/presentation.md`](presentation/presentation.md) §4.2 |
| base-cl vs kona comparison | [`bench/presentation/presentation.md`](presentation/presentation.md) §4.3 |
| Optimisation technical deep-dives | [`bench/kona/optimisations/`](kona/optimisations/) |
| Terminology and metric definitions | [`bench/kona/architecture/terminology.md`](kona/architecture/terminology.md) |
| kona architecture (actor model, message flow) | [`bench/kona/architecture/kona-architecture.md`](kona/architecture/kona-architecture.md) |
| Report reading guide (metric definitions) | [`bench/report-read-guide.md`](report-read-guide.md) |
| Detailed kona FCU deep-dive | [`bench/kona/architecture/kona-fcu-deepdive.md`](kona/architecture/kona-fcu-deepdive.md) |

---

*Last updated: 2026-04-16 · branch: feature/kona-cl-hypothesis*
*Single reference doc — covers build, run, debug, and internals.*
