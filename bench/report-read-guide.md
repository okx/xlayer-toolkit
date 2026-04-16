# Bench Report Reader Guide

Everything you need to read, understand, and explain any benchmark report in this repo.
Covers terminology, metric definitions, why each percentile was chosen, and exactly how each number was collected.

---

## Fixed Terminology

These terms are used consistently across all reports, Lark messages, and conversations.
Do not substitute synonyms — it causes confusion.

| Term | Unit | Never say |
|---|---|---|
| **Safe lag** | blocks | "confirmation lag in seconds", "batcher lag in seconds" |
| **TPS** | tx/s | "transactions per second" (redundant, just TPS) |
| **FCU p50 / p99** | ms | "average FCU", "FCU latency" (always specify percentile) |
| **new_payload p50** | ms | "block import time" without percentile |
| **Txs confirmed** | count | "transactions processed", "throughput count" |
| **Derivation active** | % of samples | "derivation busy", "derivation running" |

> At 1s/block, safe lag in blocks = safe lag in seconds numerically.
> We always report **blocks** — it is the canonical unit.

---

## Architecture Background

Understanding two concepts makes every metric self-explanatory.

### The CL / EL split

Every node is two processes talking over the Engine API (HTTP on authrpc port):

```
CL (consensus layer)          EL (execution layer)
op-node / kona / base-cl  ←── Engine API (authrpc) ───→  reth

CL decides: what is the head, when to build, derivation
EL does:    build blocks, execute txs, manage state
```

The CL is the brain. The EL is the muscle. They communicate exclusively via Engine API calls.

### The two CL jobs running concurrently

The CL runs two independent pipelines at the same time:

```
Job 1 — SEQUENCER (produces new blocks)
  Every 1 second:
  CL → FCU+attrs ──────────► reth  ("start building; here are the block attributes")
  CL ◄── payloadId ◄────────  reth  (HTTP response back immediately ~2ms; building starts in background)
  [reth builds block asynchronously — ~950ms for 200M gas fill]
  CL → getPayload(id) ──────► reth  ("give me the sealed block")
  CL ◄── sealed block ◄─────  reth
  CL → new_payload ────────► reth  ("import this sealed block")
  unsafe_head advances by 1

  ⚠️  FCU latency is only the HTTP round-trip of the FCU+attrs call (first two lines above).
      Block building (~950ms) is decoupled and NOT included in FCU latency.

Job 2 — DERIVATION PIPELINE (catches up safe_head to L1)
  Continuously:
  CL reads L1 blocks
  → finds batcher txs (compressed L2 batches posted to L1 by the batcher)
  → decodes batches → reconstructs L2 blocks
  → CL → new_payload(derived block) ──► reth  ("import this safe block")
  → CL → FCU(no attrs, safe_head=X) ──► reth  ("update safe pointer")
  safe_head advances
```

**Key point:** Derivation is about L1 → L2 data flow. FCU in derivation just moves a pointer. The actual L2 transaction data from L1 batches is carried in `new_payload`, not FCU.

### The shared authrpc queue

All Engine API calls from both jobs go through **one shared connection** to reth's authrpc.
reth processes one request at a time (FIFO):

```
Sequencer actor  ──┐
                   ├──► single HTTP conn ──► reth authrpc (FIFO queue)
Derivation actor ──┘
+ FCU probe      ──┘
```

This is the root cause of FCU tail latency differences across CLs.
When derivation fires a burst of `new_payload` calls, sequencer FCU+attrs and any probes queue behind them.

### Kona's actor model

Kona separates its internal logic into independent Rust async actors:

| Actor | Job |
|---|---|
| Sequencer actor | FCU+attrs → build → new_payload |
| Derivation actor | Read L1 → decode → new_payload → FCU(safe_head) |
| Engine actor | Owns the Engine API client — serialises all outbound calls |

The actor model gives internal isolation (no shared memory, clean state separation).
It does **not** solve authrpc queue contention — all actors still funnel through one outbound connection.

> Analogy: multiple cashiers preparing orders in the kitchen (isolated, parallel) but
> one delivery window they all pass through. The kitchen is clean. The window is one lane.

---

## Metrics Reference

### TPS — block-inclusion

**What:** Transactions confirmed on-chain per second.
```
TPS = txs confirmed in blocks ÷ actual chain time (seconds)
```

**Why this number:** It is the only honest throughput figure.
It counts only txs that landed in blocks — no mempool noise, no warmup skew.

**How collected:** bench-adventure.sh scans every block in the measurement window via `eth_getBlockByNumber`, sums tx counts, divides by elapsed seconds between first and last block.

**Percentile used:** Not applicable — this is a single aggregate number over the full measurement window.

**Theoretical ceiling:**
```
200M gas ÷ ~35k gas per ERC20 tx = 5,714 TX/s
```
Hitting 5,705 TX/s = 99.8% of ceiling. The remaining 0.2% is reth's `eth_sendRawTransaction` throughput limit on a single RPC connection, not a CL bottleneck.

---

### Txs confirmed

**What:** Total transaction count landed on-chain during the measurement window.

**Why include it:** TPS alone doesn't convey scale. "5,705 TX/s for 120s = 684,600 txs" tells the reader exactly how loaded the test was.

**How collected:** Same block scan as TPS — sum of `transactions` field across all measurement blocks.

---

### Safe lag (avg / worst)

**What:** `unsafe_head − safe_head` at each sample point. Reported in **blocks**.

**Why blocks not seconds:** Blocks is the canonical OP-stack unit. At 1s/block they are numerically equal to seconds, but blocks is what the protocol tracks.

**Why lower is better:** A smaller gap means the batcher is posting L2 batches to L1 faster. Bridges and withdrawals require safe confirmation — every block of lag = one second of extra wait for a user withdrawing.

**Why avg and worst:**
- **avg** = steady-state health of the batcher throughout the run
- **worst** = single worst spike, tells you if there were bursts of falling behind

**How collected:** bench-adventure.sh runs a background poller that calls `optimism_syncStatus` on the CL's rollup RPC once per second during the measurement window, records `(unsafe_head, safe_head)` pairs, computes lag per sample, then takes avg and max.

**Which percentile:** Not a latency distribution — avg and worst are the right summaries for a count that drifts slowly over time rather than spiking per call.

---

### FCU+attrs p50 / p99 / max (CL docker log)

**What:** HTTP round-trip time of the sequencer's `engine_forkchoiceUpdatedV3` with payload attributes — the block-build trigger call — as measured inside the CL itself.

**Precise definition:**
```
CL sends FCU+attrs HTTP POST → reth receives, queues, responds → CL receives HTTP response
FCU latency = wall-clock time from POST sent to HTTP response received, inside the CL process
```
Everything after reth sends the response — block building, state root computation, payload assembly — happens asynchronously and is **not included** in FCU latency.

**How collected:** bench-adventure.sh greps CL docker logs during the parse phase:
- **kona / base-cl:** `block build started fcu_duration=1.234ms` emitted by the engine builder actor
- **op-node:** `FCU+attrs ok fcu_duration=1.234ms` emitted by `engine_controller.go` (patched)

Percentiles computed from all samples captured during the 120s measurement window.

**FCU (derivation) variant — p50 / p99:** Same log grep but for the derivation pipeline's FCU without attrs:
- **kona:** `Updated safe head via follow safe fcu_duration=` in derivation logs

This isolates derivation-specific FCU traffic from the sequencer's FCU+attrs calls.

**Why FCU latency spikes:** When reth's engine API queue is occupied by a `new_payload` call from derivation, the sequencer's FCU+attrs HTTP request queues behind it. The spike (e.g. 15ms) is queue wait time, not reth processing time (reth itself handles FCU in ~0.08ms once it starts).

**Why p99 for tail comparison:**
- p50 is ~0.4–1ms for all CLs — similar, hides the difference
- p99 exposes the worst 1% — where derivation bursts push latency up
- The differences between CLs are largest at p99

**Why p50 for normal operation:**
- p50 tells you what the sequencer experiences on a typical second
- At p50 CLs are within 0.5ms of each other — essentially the same reth cost

---

### Block import / seal p50 (kona docker log)

> ⚠️ This metric is DIFFERENT from FCU latency. FCU latency = HTTP round-trip (~1–5ms).
> This metric = full seal cycle (~18–20ms). Do not confuse the two.

**What:** Time from kona's sequencer sending `FCU+attrs` until the sealed block is fully imported via `new_payload`. Measured by kona's seal actor.

**Timeline covered:**
```
kona → FCU+attrs ─► reth   (HTTP round-trip ~1ms — payloadId returned immediately)
[reth builds block asynchronously — ~950ms for 500M gas fill]
kona → getPayload ─► reth  (retrieve sealed block)
kona → new_payload ─► reth (import sealed block)
block_import_duration = getPayload + new_payload round-trip
```

**How collected:** kona logs to docker stdout:
```
Built and imported new unsafe block block_import_duration=18.44ms
```
bench-adventure.sh greps `docker logs op-kona`, extracts `block_import_duration=`.

**op-node equivalent:** `Inserted new L2 unsafe block build_time=951ms insert_time=20ms` — the `insert_time` field captures the `new_payload` round-trip only (not the full seal cycle). Parsed from `docker logs op-seq`.

---

### new_payload p50 (CL log)

**What:** Time from the CL sending a sealed block to reth via `engine_newPayloadV3` until reth returns confirmation. This is the block import round-trip.

**Why p50:** Same as FCU+attrs — we want the typical import cost. p99 would show rare GC pauses or OS jitter, not the steady-state sequencer experience.

**How collected:** Same docker log grep as FCU+attrs — extracted from `insert_time=` field in op-node logs. N/A for kona/base-cl for the same Prometheus-only reason.

---

### reth FCU+attrs p50 / reth new_payload p50 (reth EL log)

**What:** Reth's own internal processing time for each Engine API call — measured inside reth itself, excluding network and HTTP overhead.

**Why this matters:** It isolates reth's cost from queue wait. If reth internal is fast but external probe is slow, the gap is pure queue wait caused by derivation traffic.

**How collected:** reth logs structured lines to docker stdout:
```
engine::tree: fcu_with_attrs latency=0.083ms
engine::tree: new_payload latency=0.069ms
```
bench-adventure.sh greps `docker logs op-reth-seq`, extracts `latency=` fields, computes percentiles.

**Key insight from post-fix runs (500M gas):**
- reth internal FCU+attrs: kona (0.084ms) and base-cl (0.049ms) faster than op-node (0.156ms)
- CL log FCU+attrs p99: kona (4.8ms) and base-cl (2.4ms) far better than op-node (39.1ms)
- The difference is entirely queue wait — reth itself is fast with all three CLs

---

### Derivation active %

**What:** Fraction of FCU probe samples taken within ±2 seconds of `safe_head` advancing.

**What it measures:** A proxy for how often the derivation pipeline is actively processing L1 batches and firing Engine API calls.

**How collected:** For each probe sample timestamp, check if `safe_head` moved within ±2s in the safe-lag time-series. Count matches ÷ total samples.

**Why this matters:**
- op-node: ~45% of samples — derivation active less than half the time
- kona: ~76% of samples — derivation active three-quarters of the time
- Higher % = more derivation new_payload bursts = more authrpc queue contention

**Caveat:** This is a proxy, not a direct derivation CPU measurement. "Safe_head advancing" = derivation successfully completed a batch, not derivation CPU was running at that moment. Actual derivation may be running more often without advancing (e.g. waiting on L1 data).

---

## Percentile Cheat Sheet

| Percentile | Meaning | Use when |
|---|---|---|
| p50 | Median — 50% of calls were at or below this | "What does normal operation feel like?" |
| p95 | 95th percentile — 5% of calls were worse | "Occasional contention — 1 in 20 calls" |
| p99 | 99th percentile — 1% of calls were worse | "Tail — worst 1 in 100 calls" |
| max | Single worst observed sample | "Absolute worst case" |

> **p99 does NOT mean "99% of the time the value is X."**
> It means "99% of calls were at or BELOW X. 1% of calls were WORSE."

Rule of thumb for which to report:
- Want to show **typical health** → p50
- Want to show **tail / worst case** → p99
- Comparing CLs where p50 is identical → p99 (otherwise the comparison is flat and useless)

---

## FCU tail latency — root cause and fix

### Why kona's pre-fix FCU p99 was higher than op-node

All Engine API calls from the sequencer and derivation actors share reth's single authrpc FIFO queue.

When derivation fires a burst of `new_payload` calls (catching up on L1 batches), the sequencer's FCU+attrs queues behind them. reth processes FCU in ~0.08ms but the queue wait was what dominated the tail.

```
op-node derivation active: 45% of time → smaller bursts → shorter queue → FCU p99 = 9.2ms (pre-fix)
kona derivation active:    76% of time → larger bursts → longer queue → FCU p99 = 16.5ms (pre-fix)
```

**The kona-specific bug:** kona's engine loop drained the entire BinaryHeap before reading the next request from the channel. When derivation sent 10 Consolidate tasks, the sequencer's Build (FCU+attrs) request waiting in the channel never entered the BinaryHeap — priority ordering (`Build > Consolidate`) never fired. The Build waited behind all 10 Consolidates.

### The fix (applied — commit a93c6cd)

```
engine_request_processor.rs: after blocking recv(), flush ALL pending channel requests
into the BinaryHeap before the next drain(). Any Build task in the channel now enters
the heap and runs before remaining Consolidates.

derivation/actor.rs: add tokio::task::yield_now() after each send_safe_l2_signal().
Prevents derivation tight loop from monopolising the Tokio scheduler between submits.
```

**Post-fix results (500M gas):** kona FCU+attrs p99 = **4.8ms** vs op-node **39.1ms**.

### Why op-node doesn't have this bug

Go's goroutine scheduler is **preemptive** — the runtime interrupts running goroutines at any point. Even under tight derivation loops, the sequencer goroutine gets CPU time.

Tokio is **cooperative** — a task runs until it `.await`s. Without `yield_now()`, derivation could enqueue 10 Consolidates without yielding. The `yield_now()` fix makes derivation cooperate.

### What remains

reth's shared authrpc queue still serialises all Engine API calls. The remaining improvement is **Safe-FCU Coalescing**: send 1 Consolidate per L1 batch instead of 1 per L2 block (currently 10–20×). Expected result: FCU p99 drops from 4.8ms → ~2ms. See `kona/engine-optimisation-deepdive.md`.

---

## Report Format — At a Glance Table

The comparison report shows:

| Row | Unit | Percentile | What it measures | Story it tells |
|---|---|---|---|---|
| TPS | tx/s | aggregate avg | Confirmed txs / elapsed time | Are all CLs hitting the gas ceiling? |
| FCU p50 | ms | p50 | HTTP round-trip to reth authrpc (no block building) | Typical Engine API response time — idle path |
| FCU p95 | ms | p95 | HTTP round-trip to reth authrpc (no block building) | Typical response under load — reference for decisions |
| FCU p99 | ms | p99 | HTTP round-trip to reth authrpc (no block building) | Tail — derivation queue contention visible here |
| Block production cycle p50 | ms | p50 | FCU+attrs → getPayload → new_payload (full cycle) | Does a typical block fit in the 1000ms slot? |
| new_payload insert p50 | ms | p50 | HTTP round-trip for block import confirmation | Typical block import cost |
| Safe lag avg | blocks | average | unsafe_head − safe_head | Batcher health — L1 confirmation speed |
| Safe lag worst | blocks | max | unsafe_head − safe_head | Worst spike during run |

---

## How a Bench Run is Structured

```
Phase 1 — SETUP
  Build adventure binary, verify accounts-20k.txt, write JSON configs

Phase 2 — TOP-UP
  Check deployer balance. If < 3000 ETH, top-up from whale to 7000 ETH.

Phase 3 — INIT (parallel, ~7-10 min)
  Instance A: deploy BatchTransfer + ERC20, fund 10k accounts (0.2 ETH + tokens)
  Instance B: same for 10k accounts from WHALE_KEY
  Both run simultaneously.

Phase 4 — WARM-UP (30s)
  Both adventure instances flood mempool.
  Probes NOT yet started. Blocks reach 100% fill.
  Purpose: measurement window starts at saturation, not at empty mempool.

Phase 5 — MEASURE (120s)
  START_BN captured.
  FCU probe starts (1 sample/s).
  Safe-lag poller starts (1 sample/s).
  Blocks fill 100% throughout.

Phase 6 — PARSE
  Python scans blocks (TPS, fill).
  FCU time-series percentiles computed.
  Docker logs parsed (CL build cycle, reth internals).
  Safe-lag time-series percentiles computed.

Phase 7 — REPORT
  Markdown report written to bench/runs/{run-type}-{ts}/{cl}.md
  JSON sidecar written alongside for comparison aggregation.
```

**Why warmup matters:** Mempool starts empty. Without 30s warmup, first measurement blocks are partially empty → artificially low TPS. Warmup pre-fills mempool so every measurement block hits 100% fill immediately.

---

## Extending This Guide

When adding a new metric to bench-adventure.sh:

1. Add the metric definition here — what it measures, which percentile, why
2. Add the extraction method — which log source, which regex/field
3. Add it to the JSON sidecar key list in bench.sh PYCOMPARE
4. Add a row to the comparison table
5. Update the "At a Glance" cheat sheet at the bottom of this file
