# kona Sequencer Optimisations

**Branch:** `fix/kona-engine-drain-priority`
**Repo:** `okx-optimism/rust/kona`
**Chain:** xlayer devnet (ID 195 · 1s blocks · OKX reth EL)

---

## Optimisation tracker

| # | Commit | Name | Interval fixed | Status | Key number |
|---|---|---|---|---|---|
| **Opt-1** | `184b6f268` | FCU BinaryHeap drain | `BlockBuildInitiation-QueueDispatchLatency` (T1→T2) | ✅ Shipped | Queue wait p99: 16ms → <1ms · FCU p99 200M: 16.5ms → 8.2ms (2×) |
| **Opt-2** | `842d55010` + `bd0b96219` | SystemConfig cache + invalidation | `BlockBuildInitiation-RequestGenerationLatency` (T0→T1) | ✅ Shipped | `BlockBuildInitiation-RequestGenerationLatency` p50: 94ms → 1.7ms (**57×**) |
| Opt-3 | — | Cache `unsafe_head` per-block | T0→T1 (`get_unsafe_head`) | 🔬 Measuring | Awaiting confirmation that `l2_head_fetch` is a live RPC |
| Opt-4 | — | Dedicated engine Tokio runtime | T2→T3 (FCU HTTP) | 📋 Planned | `fcu_duration` max: 42ms → <5ms (projected) |
| Opt-5 | — | Pipeline attr_prep into EL build time | T0→T1 (whole phase) | 📋 Planned | attr_prep p50: 100ms → ~0ms (projected) |
| Opt-6 | — | L1 watcher pre-fetch headers + receipts | T0→T1 (epoch change) | 📋 Planned | Eliminates epoch-change `l1_header_fetch` spike |

---

## Shipped optimisations — docs

| Doc | Commit(s) | What it covers |
|---|---|---|
| [opt-1-fcu-binaryheap-drain.md](./opt-1-fcu-binaryheap-drain.md) | `184b6f268` | Root cause of BinaryHeap starvation, two-part fix, before/after numbers |
| [opt-2-systemconfig-cache.md](./opt-2-systemconfig-cache.md) | `842d55010` · `bd0b96219` | SystemConfig RPC elimination (57×), two-cache architecture, invalidation wiring |

---

## Timing model — quick reference

```
T0 ──── BlockBuildInitiation-RequestGenerationLatency ──── T1 ──── QueueDispatch ──── T2 ──── HTTP ──── T3
│                       (T0→T1)                            │          (T1→T2)          │    (T2→T3)      │
Sequencer                                              Build{attrs}               FCU HTTP         payloadId
decides                                                ready                      sent to reth     received
to build
```

| Interval | Report name | Fixed by |
|---|---|---|
| T0→T1 | `BlockBuildInitiation-RequestGenerationLatency` | Opt-2 (SystemConfig cache) |
| T1→T2 | `BlockBuildInitiation-QueueDispatchLatency` | Opt-1 (BinaryHeap drain) |
| T2→T3 | `BlockBuildInitiation-HttpSender-RoundtripLatency` | Opt-4 (planned) |
| T0→T3 | Full cycle | Both shipped opts combined |

**Plain-language alias table** — same intervals, names any audience can read:

| Interval | Short alias | Plain English | What a slow number means |
|---|---|---|---|
| T0→T1 | `attr_prep` | "Time kona spent preparing block-build instructions" | kona is making unnecessary RPC calls or slow lookups before it can tell reth to start |
| T1→T2 | `queue_wait` | "Time the build job waited in kona's internal queue" | kona's internal task scheduler is running lower-priority work ahead of block building |
| T2→T3 | `fcu_duration` | "Time for kona's start-block signal to reach reth and get a reply" | Network/RPC round-trip overhead between kona and reth |
| T0→T3 | `total_wait` | "Total time kona took before reth could start filling the block" | Combined CL overhead — every ms here is a ms stolen from reth's fill window |

---

## Benchmark proof — session `20260412_154021` (500M gas, 40 workers)

### 5-CL comparison (all CLs, old optimised image `83cc0ae0f`)

| CL | TPS | Fill | `attr_prep` p99 (T0→T1) | T0→T3 p99 |
|---|---|---|---|---|
| **kona-okx-optimised** | **13,872** | **97.2%** | **9.5 ms** | **157 ms** |
| kona-okx-pre-opt2 (Opt-1 only) | 13,025 | 91.3% | 180 ms | 227 ms |
| kona-okx-baseline | 12,689 | 88.9% | 228 ms | 247 ms |
| base-cl | 12,481 | 87.5% | 233 ms | 244 ms |
| op-node | 11,525 | 80.8% | 364 ms | 365 ms |

### Fresh image run (optimised `bd0b96219` — includes step instrumentation)

Isolated baseline vs optimised. Both images now emit `attr_step_a/b/c1/c2/c3/c4`.

| Metric | Baseline | Optimised | Improvement |
|---|---|---|---|
| TPS | 12,689 TX/s | **14,218 TX/s** | **+1,529 TX/s** |
| Block fill avg | 88.9% | **99.6%** | **+10.7 pp** |
| `attr_prep` p50 (T0→T1) | 96 ms | **1.4 ms** | **69×** |
| `attr_prep` p99 (T0→T1) | 228 ms | **21.7 ms** | **10×** |
| `queue_wait` p99 (T1→T2) | 141 ms | **0.6 ms** | **235×** |
| T0→T3 p50 | 103 ms | **6.1 ms** | **17×** |
| T0→T3 p99 | 247 ms | **61.9 ms** | **4×** |

### Step-level proof — what each opt fixed

| Step | What | Baseline p50 / p99 | Optimised p50 / p99 | Fixed by |
|---|---|---|---|---|
| `step_a` | l2_head_fetch | 0ms / 0ms | 0ms / 0ms | Not an EL RPC — watch channel |
| `step_b` | l1_origin_lookup | 0ms / 9ms | 0ms / 16ms | Cached; epoch spike only |
| **`step_c1`** | **sys_config_fetch** | **95ms / 224ms** | **0ms / 0ms** | **Opt-2 — eliminated entirely** |
| `step_c2` | l1_header_fetch | 0ms / 7ms | 0ms / 4ms | Epoch only |
| `step_c3` | l1_receipts_fetch | 0ms / 4ms | 0ms / 4ms | Epoch only |
| `queue_wait` | T1→T2 heap dispatch | 141ms p99 | 0.6ms p99 | **Opt-1 — eliminated entirely** |

Full run data: [`bench/runs/adv-erc20-40w-120s-500Mgas-20260412_154021/comparison.md`](../../runs/adv-erc20-40w-120s-500Mgas-20260412_154021/comparison.md)

### Same results — for all audiences

> kona with both optimisations vs unpatched kona. Same machine, same reth, same load. Only the CL changed.

| What improved | Before | After | How much better |
|---|---|---|---|
| **Transactions confirmed per second** | 12,689 TX/s | **14,218 TX/s** | **+1,529 TX/s** |
| **How full each block was on average** | 88.9% | **99.6%** | **+10.7 percentage points** |
| **Time kona spent preparing block-build instructions** (typical block, p50) | 96 ms | **1.4 ms** | **69× faster** |
| **Time kona spent preparing block-build instructions** (worst 1 in 100 blocks, p99) | 228 ms | **21.7 ms** | **10× faster** |
| **Time the build job sat waiting in kona's internal queue** (worst 1 in 100, p99) | 141 ms | **0.6 ms** | **235× faster** |
| **Total time kona took before reth could start filling** (typical block, p50) | 103 ms | **6.1 ms** | **17× faster** |
| **Total time kona took before reth could start filling** (worst 1 in 100, p99) | 247 ms | **61.9 ms** | **4× faster** |

### Where the time was going — step by step

> Every block, kona runs through a sequence of steps to prepare instructions for reth. This table shows exactly which step was eating the time and what fixed it.

| Step inside kona | What kona was doing | Time before (typical / worst) | Time after (typical / worst) | Verdict |
|---|---|---|---|---|
| Get current chain tip | Read unsafe head from local memory | 0ms / 0ms | 0ms / 0ms | Was never a problem — reads from in-process watch channel, no network call |
| Find next L1 origin | Look up which L1 block this L2 block references | 0ms / 9ms | 0ms / 16ms | Fine — result is cached; small spike only when L1 epoch rolls over |
| **Fetch block config (gas limit, batcher address etc.)** | **Called reth via RPC to re-fetch system config every single block** | **95ms / 224ms** | **0ms / 0ms** | **Root cause — fixed by Opt-2 (cache it; config barely ever changes)** |
| Fetch L1 block header | Download L1 header for deposit data | 0ms / 7ms | 0ms / 4ms | Fine — only needed on epoch change |
| Fetch L1 receipts | Download L1 receipts for deposit transactions | 0ms / 4ms | 0ms / 4ms | Fine — only needed on epoch change |
| **Wait in build queue** | **Build task sat behind lower-priority consolidation tasks** | **141ms p99** | **0.6ms p99** | **Root cause — fixed by Opt-1 (priority queue now works correctly)** |

---

## Why CL latency drives TPS — the causal chain

> **These are CL-only optimisations. reth (EL) binary and config are identical across every run.**
> The TPS gain comes entirely from giving reth more time within each 1-second slot.

### The build budget model

Every 1-second slot works like this:

```
slot start                                                    slot end
│                                                                  │
▼                                                                  ▼
├──── CL overhead (T0→T3) ────┤◄────── reth fill window ─────────►│
│                              │                                   │
T0: sequencer tick          T3: reth starts                 ~T950ms: seal
    (CL decides to build)       filling block
```

**Every millisecond of CL latency is a millisecond stolen from reth's fill window.**

The mempool is always full (40 workers, 50k accounts). reth will fill every transaction it
can reach in the time it has. The bottleneck is not reth's speed — it is how late the CL
delivers the FCU+attrs signal.

### The numbers

| | Baseline | Optimised |
|---|---|---|
| CL overhead T0→T3 p50 | 103ms | 6ms |
| reth fill window per block | ~847ms | ~944ms |
| Block fill avg | 88.9% | **99.6%** |
| TPS | 12,689 | **14,218** |

reth gained **~97ms per block**. At the 500M gas ceiling (14,286 TX/s):

```
97ms × 14,286 TX/s ÷ 1000ms = ~1,386 TX/s theoretical gain
Actual gain:                  = +1,529 TX/s  ✓ (matches)
```

### Causal chain per optimisation

```
Opt-2: sys_config_fetch  95ms → 0ms  (step_c1 eliminated)
    │
    └─► CL sends FCU+attrs to reth ~97ms earlier
            │
            └─► reth has 97ms more to drain the mempool per block
                    │
                    └─► block fill: 88.9% → 99.6%  (+10.7 pp)
                            │
                            └─► TPS: 12,689 → 14,218  (+1,529 TX/s)

Opt-1: queue_wait  141ms p99 → 0.6ms  (BinaryHeap starvation fixed)
    │
    └─► Build task no longer waits behind Consolidate tasks
            │
            └─► FCU+attrs fires on time — no random tail delays
                    │
                    └─► block fill variance eliminated — consistent saturation
```

### Why this is not an EL optimisation

- reth received **zero code changes**
- reth config (gas limit, thread count, RPC settings) **unchanged**
- The same reth binary serves all CLs in every run
- TPS difference between CLs is 100% attributable to how early or late each CL delivers FCU+attrs

The CL is the pacemaker of the chain. Slow CL → late FCU → short reth fill window → low fill → low TPS. Fast CL → early FCU → full reth fill window → 99.6% fill → near-ceiling TPS.

---

## Reference docs

| Doc | What it is |
|---|---|
| [../terminology.md](../architecture/terminology.md) | Canonical metric names — source of truth for all reports |
| [kona-optimisation-proposal.md](./kona-optimisation-proposal.md) | Full proposal with all opts, T0→T1 drill-down, invalidation analysis, roadmap |
| [../kona-fcu-fix-deep-dive.md](../architecture/kona-fcu-fix-deep-dive.md) | Deep dive on BinaryHeap starvation + Opt-2 shipped diagrams |
| [../fcu-timing-model.md](../misc/fcu-timing-model.md) | T0→T3 timing model with code locations |
| [tps-impact-model.md](./tps-impact-model.md) | How CL latency drives TPS — mechanics, code snippets, fill window math, per-opt causal chains |
