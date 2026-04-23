# bench/ — XLayer Consensus Layer Benchmarking

This directory contains everything needed to benchmark, compare, and report on consensus layer (CL)
performance on the XLayer L2 devnet. All scripts, reports, docs, and tooling live here.

---

## Table of Contents

1. [If you're new to blockchain](#1-if-youre-new-to-blockchain)
2. [What we're benchmarking and why](#2-what-were-benchmarking-and-why)
3. [The 4 consensus layers under test](#3-the-4-consensus-layers-under-test)
4. [Understanding the metrics](#4-understanding-the-metrics)
5. [Quick start — zero to report](#5-quick-start--zero-to-report)
6. [Prerequisites and build](#6-prerequisites-and-build)
7. [Running benchmarks](#7-running-benchmarks)
8. [Reading the reports](#8-reading-the-reports)
9. [Directory layout](#9-directory-layout)
10. [Further reading](#10-further-reading)

---

## 1. If you're new to blockchain

You don't need to know Solidity or DeFi. You need to understand one thing: **XLayer is a
high-throughput transaction processing system**, and this benchmark measures how fast and
reliably its sequencer can process those transactions.

### The two-process architecture

XLayer's sequencer is split into two cooperating processes, like a producer-consumer pair in
any distributed system:

```
┌─────────────────────────────────────────────────────────────┐
│  Consensus Layer (CL)              Execution Layer (EL)      │
│                                                              │
│  "The brain"                       "The worker"              │
│  Decides what goes in each block.  Builds and executes txs.  │
│  Manages chain state.              Maintains the EVM state.  │
│                                                              │
│  op-node / kona / base-cl    ←──── reth (OKX fork)          │
│                              Engine API (HTTP/JSON-RPC)      │
└─────────────────────────────────────────────────────────────┘
```

- **Execution Layer (reth)** — the database engine. It executes transactions,
  maintains account balances, and builds block payloads. Same binary across all tests.
- **Consensus Layer (CL)** — the orchestrator. It tells reth when to build a new block, fetches
  the result, and advances chain state. This is what we're comparing.
- **Engine API** — the HTTP interface between them. Every latency number in our reports comes
  from measuring calls across this API.

### Blocks and the 1-second slot

XLayer produces one block per second. Each block can hold up to ~5,714 ERC20 token transfers
(at 200M gas limit). The CL has exactly 1 second to trigger block building, fetch the result,
and submit it — or the slot is wasted.

```
Second 0          Second 1          Second 2
│                 │                 │
├─── FCU+attrs ──►│                 │   ← CL tells reth: "start building block N+1"
│                 ├─── FCU+attrs ──►│   ← Happens again for block N+2
│   reth builds ──►                 │
│   CL seals ─────►                 │
│                 │                 │
[  Block N fills  ][  Block N+1     ]
```

If FCU+attrs is slow, the next block starts late — transactions queue up, throughput drops.
This is why FCU+attrs latency is the most important metric in all our reports.

### L1 vs L2 and safe lag

XLayer is a **Layer 2** chain. It processes transactions fast locally (the **unsafe head**),
then periodically batches and posts them to Ethereum L1 for finality (the **safe head**).
Until a block reaches L1 (safe), bridges and withdrawals can't confirm.

**Safe lag** = `unsafe_head − safe_head` in blocks. At 1 block/second, 1 block = 1 second of
bridge delay. The faster the batcher submits L1 batches, the lower the lag.

---

## 2. What we're benchmarking and why

We are comparing **4 different consensus layer implementations** — all running against the
**same reth binary** on the same hardware — to decide which CL XLayer should run in production.

### What we found

op-node's sequencer stalls for up to **212ms** in a single call under peak load — that's 21%
of the 1-second block slot. Root cause: a shared mutex between the sequencer and derivation
goroutines, where derivation holds the lock during large L1 batch processing.

kona-okx-optimised eliminates this with a priority queue fix. The worst-case stall drops from
**212ms → 9ms** under the same load.

For the full technical breakdown and evidence, see [kona-cl-hypothesis.md](./kona-cl-hypothesis.md).

### The recommendation

Move XLayer from op-node to **kona-okx-optimised**.

---

## 3. The 4 consensus layers under test

| Name | Language | Description |
|---|---|---|
| **op-node** | Go | OP Stack reference CL. Currently in production on XLayer. Used as baseline reference. |
| **kona-okx-baseline** | Rust | OKX fork of kona — instrumented and patched for XLayer genesis, **without** the priority queue fix. Shows pre-fix kona behaviour. |
| **kona-okx-optimised** | Rust | Same as baseline **plus** the priority queue drain fix and cooperative scheduling. The recommended production upgrade. |
| **base-cl** | Rust | OP Stack reference Rust CL (Coinbase). Clean upstream — used as a second independent Rust data point. |

All 4 CLs run against the **same** OKX reth binary and identical chain configuration. The only
variable is the consensus layer implementation.

---

## 4. Understanding the metrics

### Percentiles: p50, p99, max

> **Use p99 for production decisions. p50 for intuition. max for worst-case risk.**

| Term | What it means | When to use |
|---|---|---|
| **p50 (median)** | Half of calls finish faster than this. The "typical" case under normal conditions. | Understand baseline behaviour only. **Do not use for decisions** — hides all tail problems. A system can have great p50 while failing 1-in-100 times. |
| **p99** | 99% of calls finish faster. 1-in-100 are slower. In a 120s run with ~120 FCU+attrs calls, p99 ≈ the 2nd worst event observed. | **Primary production decision metric.** Captures systematic tail. A bad p99 means the system *reliably* has slow moments, not just noise. |
| **max** | The single worst call in the entire run. May be OS jitter or a real structural problem. | Cross-check with p99. If max >> p99 → likely a rare spike. If max ≈ p99 → fat tail, frequent problem. |

**Why not average?** Average hides everything. A system that takes 1ms for 99 calls and
500ms for 1 call averages to ~6ms — which looks fine. p99 shows you the 500ms.

**At 120 blocks/run:** p99 FCU+attrs = the ~2nd worst block-build trigger. Over 86,400
blocks/day, that threshold is crossed ~864 times. p50 would never tell you this.

### The Engine API calls

```
CL                                          reth (EL)
 │                                               │
 │──── FCU+attrs ────────────────────────────────►│  "Start building block N+1 now"
 │◄─── (payloadId returned) ─────────────────────│  reth starts building in background
 │                                               │
 │  [reth builds block — takes ~1s]              │
 │                                               │
 │──── getPayload ────────────────────────────────►│  "Give me the built block"
 │◄─── (block data) ──────────────────────────────│
 │                                               │
 │──── new_payload ───────────────────────────────►│  "Here's the sealed block, validate it"
 │◄─── (VALID / INVALID) ─────────────────────────│
 │                                               │
 │──── FCU (no attrs) ────────────────────────────►│  "Advance safe/finalized head to block M"
 │◄─── () ────────────────────────────────────────│  (called ~47x/run, after L1 batches land)
```

| Call | Frequency | On 1s critical path? | What slow means |
|---|---|---|---|
| **FCU+attrs** | Once per second — every block | **YES** | Sequencer misses its slot. Next block starts late. Most important metric. |
| **new_payload** | ~984 per 120s run | Indirectly | reth falling behind block submissions. CL may queue up. Measured as CL HTTP round-trip. |
| **FCU (no attrs)** | ~47–54 per 120s run | No | Safe head falls further behind → longer bridge/withdrawal wait for users. |
| **getPayload** | ~120 per run (kona/base-cl) | Yes | Part of the block seal cycle. op-node handles this internally, not separately logged. |

### TPS, block fill, safe lag

| Metric | What it means | Target |
|---|---|---|
| **Block-inclusion TPS** | Transactions confirmed on-chain per second | 5,705 TX/s at 200M (theoretical ceiling) |
| **Block fill %** | Average % of block gas limit used per block | 99%+ at 200M with 20k accounts |
| **Mempool send rate** | TX/s submitted by load generator | Must exceed TPS to keep mempool full |
| **Safe lag (avg)** | Mean blocks between unsafe and safe head. 1 block = 1 second. | 33–40 blocks at 200M; 64–66 at 500M |

> **200M vs 500M:** At 200M gas, 20k test accounts saturate the chain (99% fill — every
> block is a full stress test). At 500M, the same accounts only fill ~41% because the
> ceiling is too high for the sender. **Use 200M for definitive CL comparison.**
> 500M shows the scaling story: how op-node's stall grows with gas limit.

---

## 5. Quick start — zero to report

**Prerequisites:** Docker, Go 1.21+, Python 3.9+, `cast` (Foundry), devnet running.

```bash
cd /Users/lakshmikanth/Documents/xlayer/xlayer-toolkit

# 1. Build all CL Docker images (one-time, ~10 min)
bash bench/build-bench-images.sh

# 2. Run a single CL (~25 min)
bash bench/bench.sh op-node --gas-limit 200M --duration 120 --workers 20 --sender adventure

# 3. View the report
cat bench/runs/adv-erc20-20w-120s-200Mgas-<timestamp>/op-node.md
```

**Run all 4 CLs unattended (recommended for full comparison):**
```bash
bash bench/bench-orchestrate.sh
# Runs 200M (4 CLs) then 500M (4 CLs). ~3.5 hours total.
# Auto-generates comparison.md + detailed-report.md after each session.
```

---

## 6. Prerequisites and build

### System requirements

| Tool | Purpose | Install |
|---|---|---|
| Docker + Docker Compose | Run CL and EL containers | `brew install --cask docker` |
| Go 1.21+ | Build the adventure load generator | `brew install go` |
| Python 3.9+ | Parse metrics, generate reports | comes with macOS or `brew install python3` |
| `cast` (Foundry) | Query L2 RPC for block numbers | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| `jq` | JSON parsing in scripts | `brew install jq` |

### Build CL Docker images

```bash
bash bench/build-bench-images.sh
```

Builds 3 images used by bench.sh:

| Image tag | Used for |
|---|---|
| `kona-node:dev` | kona-okx-optimised — the patched build |
| `kona-node:baseline` | kona-okx-baseline — pre-fix reference |
| `base-consensus:dev` | base-cl |

op-node uses the standard upstream image (pulled automatically on first run).

See [BENCH-GUIDE.md](./BENCH-GUIDE.md) for image naming, Dockerfile locations, and rebuilding individual images.

### Build the adventure load generator

```bash
cd tools/adventure
go install .
# Binary lands at $(go env GOPATH)/bin — add to PATH if not already:
export PATH="$(go env GOPATH)/bin:$PATH"
adventure --help   # should print usage
```

bench-adventure.sh finds the binary via `$(go env GOPATH)/bin/adventure` automatically — the
`export PATH` line above is only needed if you want to call `adventure` directly from your shell.

See [BENCH-GUIDE.md](./BENCH-GUIDE.md) for the full command reference and troubleshooting.

---

## 7. Running benchmarks

### Single CL

```bash
bash bench/bench.sh <cl-name> [options]
```

| Argument | Values | Description |
|---|---|---|
| `<cl-name>` | `op-node`, `kona-okx-optimised`, `kona-okx-baseline`, `base-cl` | Which CL to test |
| `--gas-limit` | `200M` or `500M` | Block gas limit (patches the devnet config) |
| `--duration` | seconds | Measurement window (120 recommended) |
| `--workers` | integer | Adventure goroutine count (20 for 200M, 40 for 500M) |
| `--sender` | `adventure` | Load generator — always use `adventure` |

```bash
# 200M — the definitive comparison
bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
bash bench/bench.sh kona-okx-baseline  --gas-limit 200M --duration 120 --workers 20 --sender adventure
bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure

# 500M — the scaling story
bash bench/bench.sh op-node            --gas-limit 500M --duration 120 --workers 40 --sender adventure
```

### Grouped session — all CLs in one comparison

Set a shared `SESSION_TS` so all CLs land in the same directory:

```bash
TS=$(date +%Y%m%d_%H%M%S)

SESSION_TS=$TS bash bench/bench.sh op-node            --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$TS bash bench/bench.sh kona-okx-baseline  --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$TS bash bench/bench.sh kona-okx-optimised --gas-limit 200M --duration 120 --workers 20 --sender adventure
SESSION_TS=$TS bash bench/bench.sh base-cl            --gas-limit 200M --duration 120 --workers 20 --sender adventure

# All results in: bench/runs/adv-erc20-20w-120s-200Mgas-$TS/
# comparison.md and detailed-report.md are auto-generated after each CL completes
```

### Fully unattended (200M + 500M)

```bash
bash bench/bench-orchestrate.sh
```

- Runs 200M (20 workers) then 500M (40 workers), all 4 CLs each
- If any CL fails, logs the error and continues — the session is not aborted
- After 500M completes, retries any 200M CLs that failed into the original session directory
- Generates `comparison.md` and `detailed-report.md` automatically

### What happens inside a run

```
bench.sh
  │
  ├─ 1. Patch gas limit in devnet config (intent.toml.bak)
  ├─ 2. Switch Docker stack to the requested CL
  ├─ 3. Wait for engine API to become ready (blocks advancing)
  ├─ 4. Call bench-adventure.sh
  │       ├─ SETUP:    Build adventure binary, verify account files
  │       ├─ TOP-UP:   Check deployer ETH balance, top up from whale if < 3000 ETH
  │       ├─ INIT:     Deploy BatchTransfer + ERC20 contracts (parallel, ~7–10 min)
  │       │            Fund 20,000 accounts with 0.2 ETH + ERC20 tokens each
  │       ├─ WARMUP:   Flood mempool for 30s — pre-fills to saturation so measurement
  │       │            starts with 100% block fill immediately
  │       ├─ MEASURE:  120s window — capture block data + CL/reth docker log timings
  │       └─ PARSE:    Python extracts all metrics, writes <cl>.md + <cl>.json
  │
  ├─ 5. Auto-generate comparison.md   (triggered when ≥2 CLs in session)
  └─ 6. Auto-generate detailed-report.md  (via generate-report.py)
```

See the [Internals section of BENCH-GUIDE.md](./BENCH-GUIDE.md#internals--how-bench-adventuresh-works) for a full phase-by-phase breakdown.

---

## 8. Reading the reports

### Where reports live

```
bench/runs/
└── adv-erc20-20w-120s-200Mgas-20260404_150219/
    ├── op-node.json                  ← raw metrics (all numbers, machine-readable)
    ├── op-node.md                    ← per-CL narrative with context
    ├── kona-okx-baseline.json
    ├── kona-okx-baseline.md
    ├── kona-okx-optimised.json
    ├── kona-okx-optimised.md
    ├── base-cl.json
    ├── base-cl.md
    ├── comparison.md                 ← quick flat table across all CLs
    └── detailed-report.md            ← full analysis: sections, descriptions, winner column
```

Directory name format: `{sender}-{workers}w-{duration}s-{gas}Mgas-{timestamp}`.

### The two report files

**`comparison.md`** — auto-generated after each CL completes. A flat table of every metric,
all CLs side-by-side. No explanations, just numbers. Good for a quick scan.

**`detailed-report.md`** — the full report, auto-generated by `generate-report.py`. Sections:

| Section | What it covers |
|---|---|
| How to Read | Percentile primer, Engine API call guide |
| 1 — Throughput | TPS, block fill (p10/p50/p90/avg), mempool rate, confirmed txs |
| 2 — FCU+attrs | Block-build trigger latency p50/p99/max. **Start here.** |
| 3 — FCU derivation | Safe-head advancement latency. Not critical path. |
| 4 — new_payload | Block import round-trip (CL HTTP perspective, not reth internals) |
| 5 — Block seal cycle | getPayload+newPayload combined (kona/base-cl only) |
| 6 — Safe lag | Bridge/withdrawal confirmation lag in blocks |
| 7 — Full comparison | **All CLs ranked per metric with inline descriptions. The decision table.** |
| 8 — Opinion | Per-CL assessment, recommendation, root cause |
| Presentation | Slide deck headlines |
| Data quality | Known caveats for this session |

Every metric row has an inline description — the table is self-explanatory, no lookup needed.

### Generate or refresh reports manually

```bash
# One session
python3 bench/scripts/generate-report.py bench/runs/adv-erc20-20w-120s-200Mgas-20260404_150219/

# All sessions at once
python3 bench/scripts/generate-report.py bench/runs/adv-erc20-*/
```

### How to interpret results

Open `detailed-report.md` and go straight to **Section 7 (Full Comparison)**. Every row has an
inline description — no lookup needed. The ⭐ rows (Full Cycle T0→T3) are the primary decision signal.
Bold = best (lowest latency). The Winner column names the CL that wins each metric.

### Data quality flags

- **500M p50 metrics** — block fill averages 41% at 500M (bimodal). p50 reflects empty blocks.
  Use p99/max at 500M. Only 200M has 99%+ fill where p50 is meaningful.
- **kona-baseline p50** — occasionally artificially fast (warm reth cache from running after
  op-node). Always use p99/max as ground truth.
- **kona-optimised derivation FCU p99** — looks high at 500M bimodal load. This is a known,
  understood trade-off from the `yield_now()` fix. It reverses at 200M saturated load.

### Latest results

| Session | Gas | Load | Report |
|---|---|---|---|
| `20260404_150219` | 200M | **99%+ fill — definitive** | [detailed-report.md](./runs/adv-erc20-20w-120s-200Mgas-20260404_150219/detailed-report.md) |
| `20260404_161448` | 500M | 41% bimodal — scaling story | [detailed-report.md](./runs/adv-erc20-40w-120s-500Mgas-20260404_161448/detailed-report.md) |

**200M headline:** op-node stalled for **31ms**. kona-optimised never exceeded **15ms**.

**500M headline:** At double gas limit, op-node's stall grew from 31ms → **77ms**. kona-optimised stayed at **18ms**.

---

## 9. Directory layout

```
bench/
├── README.md                        ← you are here
│
├── — Entry points ──────────────────────────────────────────────────────────────
├── bench.sh                         ← main script: switch Docker stack, run, save report
├── bench-orchestrate.sh             ← unattended 200M+500M runner with failure recovery
│
├── — Load generators ───────────────────────────────────────────────────────────
├── scripts/
│   ├── bench-adventure.sh           ← ERC20 load generator (init + warmup + measure + parse)
│   └── generate-report.py          ← reads *.json → detailed-report.md
│
├── — Utilities ─────────────────────────────────────────────────────────────────
├── build-bench-images.sh            ← builds kona + base-cl Docker images
│
├── — Output ────────────────────────────────────────────────────────────────────
├── runs/                            ← all benchmark session data
│   └── adv-erc20-{w}w-{d}s-{gas}Mgas-{ts}/
│       ├── {cl}.md                  ← per-CL narrative
│       ├── {cl}.json                ← per-CL raw metrics (machine-readable)
│       ├── comparison.md            ← quick cross-CL table (auto-generated)
│       └── detailed-report.md       ← full analysis with all 8 sections (auto-generated)
│
├── — Investigation docs ────────────────────────────────────────────────────────
├── kona-cl-hypothesis.md            ← complete investigation: baseline → fix → results → verdict
├── kona/                            ← detailed kona-specific analysis
│
├── — Reference docs ────────────────────────────────────────────────────────────
├── BENCH-GUIDE.md                   ← build images, run commands, debug, internals (start here)
├── adventure-architecture.md        ← adventure tool design + sequence diagrams
├── load-guide.md                    ← DEPRECATED: old Python sender docs (see BENCH-GUIDE.md)
├── report-read-guide.md             ← all metrics defined, percentile guide, CL/EL split
├── FCU_scratchpad.md                ← running technical notes (Engine API, block lifecycle)
│
├── — Kona docs ─────────────────────────────────────────────────────────────────
├── kona/kona-fcu-fix-deep-dive.md   ← master doc: architecture, 9-Q drain deep-dive, fix, benchmarks
├── kona/engine-optimisation-deepdive.md ← 4 further optimisations beyond the fix
├── kona/kona-proposal.md            ← migration proposal for xlayer
├── kona/team-strategy.md            ← team presentation strategy
└── kona/okx-fix-branch-changes.md   ← code change reference for fix branch
```

---

## 10. Further reading

### Benchmarking and tooling

| Doc | What it covers |
|---|---|
| [BENCH-GUIDE.md](./BENCH-GUIDE.md) | Build images, run commands, output file structure, CL naming conventions |
| [BENCH-GUIDE.md](./BENCH-GUIDE.md) | Complete reference — prerequisites, commands, debugging checklist, zero-to-report walkthrough, internals |
| [adventure-architecture.md](./adventure-architecture.md) | How the adventure Go tool works — reth queued-promotion bug fix, nonce sequencing, sequence diagrams |
| [BENCH-GUIDE.md § Internals](./BENCH-GUIDE.md#internals--how-bench-adventuresh-works) | bench-adventure.sh phase-by-phase breakdown, account math, known bugs and fixes |
| [load-guide.md](./load-guide.md) | Mempool math, how many accounts needed to saturate a gas limit, TPS ceiling formulas |

### Understanding the metrics

| Doc | What it covers |
|---|---|
| [report-read-guide.md](./report-read-guide.md) | Every metric defined — TPS, safe lag, FCU latency, block import, reth internals, percentiles |
| [kona/kona-fcu-fix-deep-dive.md §3](kona/architecture/kona-fcu-fix-deep-dive.md) | Full OP Stack block lifecycle — Build/Seal/Consolidate/Finalize/Insert phases, canonical vs uncanonical, timing |
| [kona/kona-fcu-fix-deep-dive.md §1](kona/architecture/kona-fcu-fix-deep-dive.md) | FCU+attrs vs FCU no-attrs explained, Engine API call anatomy, JSON examples |

### Kona fix — reading path for new developers

Start here if you want to understand what was wrong, what was fixed, and why it works.
Read in order:

| Step | Doc | What it covers |
|---|---|---|
| 1 — Architecture | [kona/kona-fcu-fix-deep-dive.md §2–3](kona/architecture/kona-fcu-fix-deep-dive.md) | Actor model, block lifecycle (Build/Seal/Consolidate/Finalize/Insert), all diagrams. |
| 2 — The drain Q&A | [kona/kona-fcu-fix-deep-dive.md §5](kona/architecture/kona-fcu-fix-deep-dive.md) | 9 developer questions: what is draining, who drains, why heap vs channel, ownership. |
| 3 — The bug | [kona/kona-fcu-fix-deep-dive.md §6](kona/architecture/kona-fcu-fix-deep-dive.md) | Priority starvation root cause, sequence diagrams, before/after heap state. |
| 4 — The fix | [kona/kona-fcu-fix-deep-dive.md §7–9](kona/architecture/kona-fcu-fix-deep-dive.md) | Exact code changes in `engine_request_processor.rs` and `actor.rs`, line by line. |
| 5 — Branch changes | [kona/okx-fix-branch-changes.md](kona/misc/okx-fix-branch-changes.md) | Every change on `fix/kona-engine-drain-priority` — full checkpoint. |
| 6 — Further improvements | [kona/engine-optimisation-deepdive.md](kona/misc/engine-optimisation-deepdive.md) | Analysis of 4+ further optimisations not yet implemented. |

### Kona — results and recommendation

| Doc | What it covers |
|---|---|
| [kona-cl-hypothesis.md](./kona-cl-hypothesis.md) | Complete investigation: baseline → root cause → fix → post-fix validation → final verdict |
| [kona/kona-proposal.md](kona/misc/kona-proposal.md) | Migration proposal — what changes on XLayer infra when switching from op-node |
| [kona/team-strategy.md](kona/misc/team-strategy.md) | Team-facing strategy doc and rollout plan |

---

*All bench scripts were consolidated here from `devnet/` — infra and benchmarking are now cleanly separated.*
*Reports auto-generate on every run — no manual refresh needed after `bench.sh` or `bench-orchestrate.sh`.*
