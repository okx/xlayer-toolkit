# Session Context Handoff — xlayer-toolkit bench

> Paste this entire file at the start of a new Claude session.
> Working directory: `/Users/lakshmikanth/Documents/xlayer/xlayer-toolkit`
> Branch: `feature/kona-cl-hypothesis`
> Date generated: 2026-04-11

---

## 1 — What This Project Is

Benchmarking **6 consensus layers (CLs)** against the OKX reth execution layer on XLayer devnet.
- Chain: 195 · 1-second blocks · 500M gas limit
- EL: always `op-reth-seq` (OKX reth, identical binary for all CLs)
- Goal: prove `kona-okx-optimised` (with FCU priority fix) outperforms op-node and baseline kona

---

## 2 — Consensus Layer Map

| `bench.sh` arg | Docker image | Container | Meaning |
|---|---|---|---|
| `op-node` | `op-stack:latest` | `op-seq` | Go op-node reference |
| `kona-okx-baseline` | `kona-node:okx-baseline` | `op-kona` | OKX kona, no fix |
| `kona-okx-optimised` | `kona-node:okx-optimised` | `op-kona` | OKX kona + optimisations ← main candidate |
| `base-cl` | `base-consensus:dev` | `op-base-cl` | Coinbase base-cl |

---

## 3 — Key File Paths

```
xlayer-toolkit/
├── bench/
│   ├── bench.sh                          # Main orchestrator — call this to run a CL
│   ├── bench-orchestrate.sh              # Runs all 4 CLs at 200M + 500M automatically
│   ├── build-bench-images.sh             # Builds kona/base-cl docker images from source
│   ├── scripts/
│   │   ├── bench-adventure.sh            # 7-phase ERC20 load test (called by bench.sh)
│   │   ├── generate-phase-report.py      # Generates phase-report.md from run JSONs
│   │   ├── generate-simple-report.py     # Generates simple-report.md from run JSONs
│   │   └── generate-report.py            # Generates comparison.md (auto-called by bench.sh)
│   ├── runs/
│   │   ├── adv-erc20-20w-120s-200Mgas-20260407_172944/   # ← canonical 200M reference run
│   │   └── adv-erc20-40w-120s-500Mgas-20260408_030806/   # ← canonical 500M reference run
│   ├── kona/
│   │   ├── kona-fcu-fix-deep-dive.md     # kona FCU fix deep-dive (reference doc)
│   │   ├── cl-swap-keepchain-approach.md # Design doc for --keep-chain fast rerun feature
│   │   ├── team-strategy.md              # Narrative + offensive/defensive arguments
│   │   └── fcu-timing-model.md           # T0→T3 5-tier timing model
│   └── base/
│       ├── base-cl-deep-dive.md          # base-cl architecture deep-dive
│       └── base-cl-fcu-deepdive.md       # base-cl FCU+attrs flow (NEW — created this session)
├── devnet/
│   └── config-op/intent.toml.bak        # Gas limit config source (NOT intent.toml)
└── tools/adventure/testdata/
    └── accounts-50k.txt                  # 50k pre-funded accounts for bench
```

---

## 4 — How to Run a Benchmark

```bash
# From xlayer-toolkit/ root:

# Single CL run
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure

# Grouped session (all 4 CLs share one output directory)
export SESSION_TS=$(date +%Y%m%d_%H%M%S)
SESSION_TS=$SESSION_TS bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-baseline  --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$SESSION_TS bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure

# Full automated suite (200M + 500M, all 4 CLs, auto-retry on failure)
bash bench/bench-orchestrate.sh
```

### Gas limit → worker count rule
- 200M gas → 20 workers (send rate >> ceiling → 99%+ fill)
- 500M gas → 40 workers (need 2× ceiling to saturate → ~80% avg fill)

---

## 5 — Phase Report Generation

### What it generates
`bench/scripts/generate-phase-report.py <run_dir>` reads all `*.json` files in a run directory and writes `phase-report.md`.

### Input: per-CL JSON files
Each CL produces one JSON after a run. Key fields:

```
cl_fcu_attrs_p50/p99/max     T2→T3 (FCU HTTP round-trip only)
cl_build_wait_p50/p99/max    T1→T3 (queue + HTTP = component metric)
cl_queue_wait_p50/p99/max    T1→T2 (queue dispatch latency — direct fix signal)
cl_total_wait_p50/p99/max    T0→T3 (full block build cycle = canonical bench metric)
cl_attr_prep_p50/p99/max     T0→T1 (payload attributes assembly)
cl_attr_prep_avg / cl_queue_wait_avg / cl_build_wait_avg / cl_fcu_attrs_avg / cl_total_wait_avg
tps_block                    confirmed TX/s
block_fill                   avg block fill %
fill_p50 / fill_p90 / fill_p10
reth_fcu_attrs_p50           reth-side FCU measurement
reth_new_pay_p50             reth-side new_payload measurement
```

### How to run it
```bash
python3 bench/scripts/generate-phase-report.py bench/runs/adv-erc20-40w-120s-500Mgas-20260408_030806/
# → writes bench/runs/.../phase-report.md
```

### How to run simple-report
```bash
python3 bench/scripts/generate-simple-report.py bench/runs/adv-erc20-40w-120s-500Mgas-20260408_030806/
# → writes bench/runs/.../simple-report.md
```

---

## 6 — Checkpoint Aliases (LOCKED — do not change)

### T-point names (moments in time)
| Alias | Short | Meaning |
|---|---|---|
| `BlockBuildInitiation-StartTime` | T0 | Sequencer timer fires, decides to build |
| `BlockBuildInitiation-RequestGeneratedAt` | T1 | PayloadAttributes assembled, before channel send |
| `BlockBuildInitiation-HTTPRequestSentTime` | T2 | FCU HTTP request leaves CL → reth |
| `BlockBuild-ExecutionLayer-JobIdReceivedAt` | T3 | payloadId received back from reth |

### Interval names (durations)
| Alias | JSON key | Duration |
|---|---|---|
| `BlockBuildInitiation-RequestGenerationLatency` | `cl_attr_prep_*` | T0→T1 |
| `BlockBuildInitiation-QueueDispatchLatency` | `cl_queue_wait_*` | T1→T2 |
| `BlockBuildInitiation-HttpSender-RoundtripLatency` | `cl_fcu_attrs_*` | T2→T3 |
| `BlockBuildInitiation-Latency` | `cl_build_wait_*` | T1→T3 (component metric) |
| Full cycle | `cl_total_wait_*` | T0→T3 ← **canonical bench metric** |

### BANNED words (do not use in docs or reports)
`"fix"` · `"no fix"` · `"worst/bad/slow block"` · `"queue wait"` · `"priority stall"` · `"dispatch delay"` · `"FCU build latency"` · `"engine actor wait"`

---

## 7 — Canonical Benchmark Results

### 200M gas — 20 workers — SESSION 20260407_172944
Run dir: `bench/runs/adv-erc20-20w-120s-200Mgas-20260407_172944/`

| CL | TPS | Fill avg | T1→T3 p99 | T1→T3 max | T0→T1 p99 | T1→T2 p99 |
|---|---|---|---|---|---|---|
| op-node | 5,705 | 99.8% | 15.8 ms | 212 ms | 453 ms | — |
| kona-okx-baseline | 5,705 | 99.8% | ~65 ms | ~80 ms | 224 ms | ~50 ms |
| **kona-okx-optimised** | 5,705 | 99.8% | **8.2 ms** | **13 ms** | 224 ms | **~0 ms** |
| base-cl | 5,705 | 99.8% | ~40 ms | ~50 ms | 326 ms | ~30 ms |

**Headline at 200M**: op-node FCU max = 212 ms (Go mutex stall). kona-optimised max = 13 ms. 2× p99 improvement.

### 500M gas — 40 workers — SESSION 20260408_030806
Run dir: `bench/runs/adv-erc20-40w-120s-500Mgas-20260408_030806/`

| CL | TPS | Fill avg | T1→T3 p99 | T1→T3 max | T0→T1 p99 | T1→T2 p99 |
|---|---|---|---|---|---|---|
| op-node | 11,249 | 78.8% | 111 ms | 119 ms | 453 ms | — |
| kona-okx-baseline | 12,055 | 84.5% | 114 ms | 194 ms | 224 ms | ~133 ms |
| **kona-okx-optimised** | 11,682 | 81.9% | **99 ms** | **151 ms** | 224 ms | **~3 ms** |
| base-cl | 11,600 | 81.3% | 152 ms | 153 ms | 326 ms | ~133 ms |

---

## 8 — T-point Timing Model

```
T0 ──── T0→T1 ──── T1 ──── T1→T2 ──── T2 ──── T2→T3 ──── T3
        attr prep         queue           HTTP RPC
        (L1 fetch)        (BinaryHeap)    (reth round-trip)
```

| Point | What happens | Code |
|---|---|---|
| T0 | Sequencer block timer fires → `build_unsealed_payload()` | `actor.rs:430` (kona/base-cl) · `startBuildingBlock()` (op-node) |
| T1 | PayloadAttributes assembled → `BuildRequest` sent to engine channel | `engine_client.rs:209` (base-cl) · `actor.rs` (kona) |
| T2 | `engine_forkchoiceUpdatedV3` HTTP fires to reth | `build/task.rs:168` (base-cl) · `BuildTask::execute()` (kona) |
| T3 | `payloadId` returned by reth | `client.rs:367` (base-cl/kona) · `startPayload()` (op-node) |

---

## 9 — Documents Created / Modified This Session (2026-04-11)

| File | Status | What it is |
|---|---|---|
| `bench/base/base-cl-fcu-deepdive.md` | **NEW** | base-cl FCU+attrs full deep-dive — swim-lane diagram, field map, all RPC calls, latency analysis |
| `bench/base/base-cl-deep-dive.md` | Updated | base-cl architecture deep-dive (architecture, actor model, benchmark evidence) |
| `bench/runs/adv-erc20-40w-120s-500Mgas-20260408_030806/phase-report.md` | Updated | Phase report with checkpoint alias fixes |
| `bench/runs/adv-erc20-40w-120s-500Mgas-20260409_125935/phase-report.md` | Updated | Same fixes applied |

---

## 10 — Pending Work (priority order)

1. **Final report / presentation document** — fill company-specific report template with bench data. See `bench/kona/team-strategy.md` for narrative.
2. **--keep-chain implementation** (NOT started, only designed) — design doc at `bench/kona/cl-swap-keepchain-approach.md`. Implement in a NEW git worktree (`feature/cl-swap-keepchain`), NOT in main branch scripts.
3. **Update bench-adventure.sh init warning** — currently says "~18-25 min", should say "~33-35 min" (50k accounts, A+B parallel).
4. **Generate simple-report for 20260409_125935** and compare vs 20260408_030806.

---

## 11 — Key Architectural Decisions

- **200M gas is the PRIMARY demo scenario** (99.8% fill → fix fires every block → clearest signal)
- **500M gas is appendix** (partial fill → noisier signal)
- **kona-okx-optimised** is the recommended production candidate
- The FCU priority fix: after `recv()` in the BinaryHeap loop, drain all remaining channel messages via `try_recv()` before calling `drain()` — ensures `Build` task always visible for priority ordering
- All kona variants use `KONA_IMAGE` env var → docker-compose picks up via `${KONA_IMAGE:-kona-node:okx-optimised}`
- Gas limit config lives in `devnet/config-op/intent.toml.bak` (NOT `intent.toml` — that gets overwritten on deploy)

---

## 12 — RPC Endpoints (devnet)

| Endpoint | URL |
|---|---|
| L2 RPC | http://localhost:8123 |
| L2 Auth RPC (Engine API) | http://localhost:8552 |
| L2 Rollup RPC | http://localhost:9545 |
| L1 RPC | http://localhost:8545 (l1-geth) |
