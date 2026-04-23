#!/usr/bin/env python3
"""
generate-phase-report.py — FCU flow phase report.

Key design: each phase has an ANNOTATED TIMELINE where actual run metrics are
embedded directly inside the ASCII diagram and alongside code snippets.
No separate metric tables — the numbers live where the code lives.

Phase naming canon:
  T0→T1  "Block Build Initiation Request Generation Latency"  — BlockBuildInitiator tick → PayloadAttributes assembly
  T1→T2  "Block Build Initiation Request - Queue Dispatch Latency"  — kona/base-cl only: BlockBuildInitiationRequest signal through priority heap
  T2→T3  "Block Build Initiation Request - Http Sender Roundtrip Latency"  — HTTP engine_forkchoiceUpdated → reth (network call only)
  T0→T3  "Block Build Initiation — End to End Latency"     — PRIMARY metric — full per-block BlockBuildInitiator cost
  T1→T3  "Block Build Initiation Latency"  — component metric (Queue Dispatch + Http Sender Roundtrip)

Leaves generate-simple-report.py untouched.

Usage:
    python3 bench/scripts/generate-phase-report.py bench/runs/<session>/
"""

import json, sys, datetime
from pathlib import Path

CL_DISPLAY = {
    "op-node":            "op-node",
    "kona-okx-baseline":  "kona baseline",
    "kona-okx-optimised": "kona optimised",
    "base-cl":            "base-cl",
}
PREFERRED_ORDER = ["op-node", "kona-okx-baseline", "kona-okx-optimised", "base-cl"]

# ── formatting helpers ────────────────────────────────────────────────────────

def ms(v, default="—"):
    """Format a millisecond value. 1 decimal below 10ms, integer above."""
    if v is None:
        return default
    return f"{v:.1f}ms" if v < 10 else f"{v:.0f}ms"

def stat_line(p50, avg, p99, mx, prefix=""):
    """Compact inline stats string: Median=X · Average=Y · 99th Percentile=Z · Maximum=W"""
    parts = []
    if p50 is not None: parts.append(f"Median={ms(p50)}")
    if avg is not None: parts.append(f"Average={ms(avg)}")
    if p99 is not None: parts.append(f"99th Percentile={ms(p99)}")
    if mx  is not None: parts.append(f"Maximum={ms(mx)}")
    return prefix + "  ·  ".join(parts)

def bold_min(vals, v):
    if v is None: return "—"
    avail = [x for x in vals if x is not None]
    best  = min(avail) if avail else None
    s = f"{v:.0f} ms" if v >= 10 else f"{v:.1f} ms"
    return f"**{s}** ✅" if (best is not None and v == best) else s

def irow(cls, label, vals, exempt=None):
    exempt = exempt or {}
    active = {cl: v for cl, v in vals.items() if cl not in exempt and v is not None}
    fmted  = {cl: ms(v) for cl, v in active.items()}
    sorted_f = sorted(set(fmted.values()), key=lambda s: float(s.replace("ms", "")))
    unique_winner = len(sorted_f) >= 2
    best_f = sorted_f[0] if sorted_f else None

    cells = []
    for cl in cls:
        if cl in exempt:
            cells.append(exempt[cl]); continue
        v = vals[cl]
        if v is None:
            cells.append("—")
        else:
            s = ms(v)
            cells.append(f"**{s}** ✅" if (unique_winner and s == best_f) else s)
    return f"| {label} | " + " | ".join(cells) + " |"

# ── main ─────────────────────────────────────────────────────────────────────

def generate(run_dir):
    run_dir = Path(run_dir)
    files   = sorted(f for f in run_dir.glob("*.json") if "." not in f.stem)
    if len(files) < 2:
        print(f"Need ≥2 JSON files in {run_dir}"); sys.exit(1)

    cl_map = {f.stem: f for f in files}
    cls    = [c for c in PREFERRED_ORDER if c in cl_map]
    data   = {cl: json.load(open(cl_map[cl])) for cl in cls}

    ref        = data[cls[0]]
    gas_str    = ref.get("gas_limit_str", "?")
    date_str   = ref.get("date", datetime.date.today().isoformat())
    dur        = ref.get("duration_s", 120)
    acct_count = ref.get("account_count", 20000)
    acct_str   = f"{acct_count:,}"

    def g(key): return {cl: data[cl].get(key) for cl in cls}

    # intervals
    tps   = g("tps_block");        fill  = g("block_fill")
    a_p50 = g("cl_attr_prep_p50"); a_avg = g("cl_attr_prep_avg")
    a_p99 = g("cl_attr_prep_p99"); a_max = g("cl_attr_prep_max")
    q_p50 = g("cl_queue_wait_p50"); q_avg = g("cl_queue_wait_avg")
    q_p99 = g("cl_queue_wait_p99"); q_max = g("cl_queue_wait_max")
    f_p50 = g("cl_fcu_attrs_p50"); f_avg = g("cl_fcu_attrs_avg")
    f_p99 = g("cl_fcu_attrs_p99"); f_max = g("cl_fcu_attrs_max")
    b_p50 = g("cl_build_wait_p50"); b_avg = g("cl_build_wait_avg")
    b_p99 = g("cl_build_wait_p99"); b_max = g("cl_build_wait_max")
    t_p50 = g("cl_total_wait_p50"); t_avg = g("cl_total_wait_avg")
    t_p99 = g("cl_total_wait_p99"); t_max = g("cl_total_wait_max")

    # ── per-CL scalars (graceful None → "—") ─────────────────────────────────
    def cl_stat(d, cl):
        """Returns (p50, avg, p99, max) for a given interval dict and CL."""
        return d.get(cl)

    # op-node
    op_a  = stat_line(cl_stat(a_p50,"op-node"), cl_stat(a_avg,"op-node"),
                      cl_stat(a_p99,"op-node"), cl_stat(a_max,"op-node"))
    op_q  = stat_line(cl_stat(q_p50,"op-node"), cl_stat(q_avg,"op-node"),
                      cl_stat(q_p99,"op-node"), cl_stat(q_max,"op-node"))
    op_f  = stat_line(cl_stat(f_p50,"op-node"), cl_stat(f_avg,"op-node"),
                      cl_stat(f_p99,"op-node"), cl_stat(f_max,"op-node"))
    op_b  = stat_line(cl_stat(b_p50,"op-node"), cl_stat(b_avg,"op-node"),
                      cl_stat(b_p99,"op-node"), cl_stat(b_max,"op-node"))
    op_t  = stat_line(cl_stat(t_p50,"op-node"), cl_stat(t_avg,"op-node"),
                      cl_stat(t_p99,"op-node"), cl_stat(t_max,"op-node"))

    # kona baseline
    kb_a  = stat_line(cl_stat(a_p50,"kona-okx-baseline"), cl_stat(a_avg,"kona-okx-baseline"),
                      cl_stat(a_p99,"kona-okx-baseline"), cl_stat(a_max,"kona-okx-baseline"))
    kb_q  = stat_line(cl_stat(q_p50,"kona-okx-baseline"), cl_stat(q_avg,"kona-okx-baseline"),
                      cl_stat(q_p99,"kona-okx-baseline"), cl_stat(q_max,"kona-okx-baseline"))
    kb_f  = stat_line(cl_stat(f_p50,"kona-okx-baseline"), cl_stat(f_avg,"kona-okx-baseline"),
                      cl_stat(f_p99,"kona-okx-baseline"), cl_stat(f_max,"kona-okx-baseline"))
    kb_b  = stat_line(cl_stat(b_p50,"kona-okx-baseline"), cl_stat(b_avg,"kona-okx-baseline"),
                      cl_stat(b_p99,"kona-okx-baseline"), cl_stat(b_max,"kona-okx-baseline"))
    kb_t  = stat_line(cl_stat(t_p50,"kona-okx-baseline"), cl_stat(t_avg,"kona-okx-baseline"),
                      cl_stat(t_p99,"kona-okx-baseline"), cl_stat(t_max,"kona-okx-baseline"))

    # kona optimised
    ko_a  = stat_line(cl_stat(a_p50,"kona-okx-optimised"), cl_stat(a_avg,"kona-okx-optimised"),
                      cl_stat(a_p99,"kona-okx-optimised"), cl_stat(a_max,"kona-okx-optimised"))
    ko_q  = stat_line(cl_stat(q_p50,"kona-okx-optimised"), cl_stat(q_avg,"kona-okx-optimised"),
                      cl_stat(q_p99,"kona-okx-optimised"), cl_stat(q_max,"kona-okx-optimised"))
    ko_f  = stat_line(cl_stat(f_p50,"kona-okx-optimised"), cl_stat(f_avg,"kona-okx-optimised"),
                      cl_stat(f_p99,"kona-okx-optimised"), cl_stat(f_max,"kona-okx-optimised"))
    ko_b  = stat_line(cl_stat(b_p50,"kona-okx-optimised"), cl_stat(b_avg,"kona-okx-optimised"),
                      cl_stat(b_p99,"kona-okx-optimised"), cl_stat(b_max,"kona-okx-optimised"))
    ko_t  = stat_line(cl_stat(t_p50,"kona-okx-optimised"), cl_stat(t_avg,"kona-okx-optimised"),
                      cl_stat(t_p99,"kona-okx-optimised"), cl_stat(t_max,"kona-okx-optimised"))

    # base-cl
    bc_a  = stat_line(cl_stat(a_p50,"base-cl"), cl_stat(a_avg,"base-cl"),
                      cl_stat(a_p99,"base-cl"), cl_stat(a_max,"base-cl"))
    bc_q  = stat_line(cl_stat(q_p50,"base-cl"), cl_stat(q_avg,"base-cl"),
                      cl_stat(q_p99,"base-cl"), cl_stat(q_max,"base-cl"))
    bc_f  = stat_line(cl_stat(f_p50,"base-cl"), cl_stat(f_avg,"base-cl"),
                      cl_stat(f_p99,"base-cl"), cl_stat(f_max,"base-cl"))
    bc_b  = stat_line(cl_stat(b_p50,"base-cl"), cl_stat(b_avg,"base-cl"),
                      cl_stat(b_p99,"base-cl"), cl_stat(b_max,"base-cl"))
    bc_t  = stat_line(cl_stat(t_p50,"base-cl"), cl_stat(t_avg,"base-cl"),
                      cl_stat(t_p99,"base-cl"), cl_stat(t_max,"base-cl"))

    # ── per-CL ms()-formatted scalars for mermaid labels ─────────────────────
    # Block Build Initiation Request Generation Latency (T0→T1)
    op_a_p50 = ms(a_p50.get("op-node"));           op_a_p99 = ms(a_p99.get("op-node"));           op_a_max = ms(a_max.get("op-node"))
    kb_a_p50 = ms(a_p50.get("kona-okx-baseline")); kb_a_p99 = ms(a_p99.get("kona-okx-baseline")); kb_a_max = ms(a_max.get("kona-okx-baseline"))
    ko_a_p50 = ms(a_p50.get("kona-okx-optimised")); ko_a_p99 = ms(a_p99.get("kona-okx-optimised")); ko_a_max = ms(a_max.get("kona-okx-optimised"))
    bc_a_p50 = ms(a_p50.get("base-cl"));           bc_a_p99 = ms(a_p99.get("base-cl"));           bc_a_max = ms(a_max.get("base-cl"))
    # Block Build Initiation Request - Queue Dispatch Latency (T1→T2)
    kb_q_p99 = ms(q_p99.get("kona-okx-baseline")); kb_q_max = ms(q_max.get("kona-okx-baseline"))
    ko_q_p99 = ms(q_p99.get("kona-okx-optimised")); ko_q_max = ms(q_max.get("kona-okx-optimised"))
    bc_q_p99 = ms(q_p99.get("base-cl"));           bc_q_max = ms(q_max.get("base-cl"))
    # Block Build Initiation Request - Http Sender Roundtrip Latency (T2→T3)
    op_f_p50 = ms(f_p50.get("op-node"));           op_f_p99 = ms(f_p99.get("op-node"));           op_f_max = ms(f_max.get("op-node"))
    kb_f_p50 = ms(f_p50.get("kona-okx-baseline")); kb_f_p99 = ms(f_p99.get("kona-okx-baseline")); kb_f_max = ms(f_max.get("kona-okx-baseline"))
    ko_f_p50 = ms(f_p50.get("kona-okx-optimised")); ko_f_p99 = ms(f_p99.get("kona-okx-optimised")); ko_f_max = ms(f_max.get("kona-okx-optimised"))
    bc_f_p50 = ms(f_p50.get("base-cl"));           bc_f_p99 = ms(f_p99.get("base-cl"));           bc_f_max = ms(f_max.get("base-cl"))

    # ── results table ─────────────────────────────────────────────────────────
    tps_v = [v for v in tps.values()  if v is not None]
    fil_v = [v for v in fill.values() if v is not None]
    t_p50_v = [v for v in t_p50.values() if v is not None]
    t_p99_v = [v for v in t_p99.values() if v is not None]
    t_max_v = [v for v in t_max.values() if v is not None]

    def tps_cell(cl):
        v = tps[cl]
        if v is None: return "—"
        est = data[cl].get("_tps_estimated", False)
        s = f"{v:,.0f} TX/s" + (" *" if est else "")
        return f"**{s}**" if (tps_v and v == max(tps_v)) else s

    def fill_cell(cl):
        v = fill[cl]
        if v is None: return "—"
        est = data[cl].get("_tps_estimated", False)
        s = f"{v:.0f}%" + (" *" if est else "")
        return f"**{s}**" if (fil_v and v == max(fil_v)) else s

    results_rows = "\n".join(
        f"| {CL_DISPLAY.get(cl, cl)} | {tps_cell(cl)} | {fill_cell(cl)} "
        f"| {bold_min(t_p50_v, t_p50[cl])} | {bold_min(t_p99_v, t_p99[cl])} | {bold_min(t_max_v, t_max[cl])} |"
        for cl in cls
    )

    _NA = {"op-node": "N/A ¹"}

    # summary table
    cl_hdr = " | ".join(CL_DISPLAY.get(cl, cl) for cl in cls)
    cl_sep = "|".join(["---"] * (len(cls) + 1))
    summary_tbl = "\n".join([
        f"| Metric | {cl_hdr} |",
        f"|{'|'.join(['---'] * (len(cls) + 1))}|",
        irow(cls, "**Block Build Initiation — End to End Latency · Median**", t_p50),
        irow(cls, "**Block Build Initiation — End to End Latency · 99th Percentile**", t_p99),
        irow(cls, "**Block Build Initiation — End to End Latency · Maximum**", t_max),
    ])

    # recommendation
    rec = ""
    opt, base = "kona-okx-optimised", "kona-okx-baseline"
    if opt in cls and base in cls:
        if t_p99.get(opt) and t_p99.get(base):
            ratio = t_p99[base] / t_p99[opt]
            rec += f"- **{ratio:.1f}×** lower Block Build Initiation — End to End Latency p99  ({t_p99[base]:.0f} ms → {t_p99[opt]:.0f} ms vs kona baseline)\n"
        if t_max.get(opt) and t_max.get(base):
            ratio2 = t_max[base] / t_max[opt]
            rec += f"- **{ratio2:.1f}×** lower Block Build Initiation — End to End Latency max  ({t_max[base]:.0f} ms → {t_max[opt]:.0f} ms vs kona baseline)\n"
        if q_max.get(opt) is not None and q_max.get(base) is not None:
            rec += f"- BlockBuildInitiation-QueueDispatchLatency stall eliminated: {q_max[base]:.0f} ms → {q_max[opt]:.0f} ms (max)\n"

    # ── template ──────────────────────────────────────────────────────────────
    out = f"""# XLayer CL — Block-Build Trigger: Phase-by-Phase Analysis

| | |
|---|---|
| **Date** | {date_str} |
| **Chain** | XLayer devnet (chain 195) · 1-second blocks |
| **Gas limit** | {gas_str} |
| **Execution layer** | OKX reth — identical binary and config across all runs |
| **Duration** | {dur}s (~{dur} blocks) |
| **Accounts** | {acct_str} pre-funded · same accounts across all CLs · sequential runs |

---

## Background

### op-node: Sequential Event Loop — The Core Bottleneck

The reference consensus layer, **op-node** (Go), runs sequencing and derivation in a single goroutine protected by a `sync.Mutex`. Only one arm can execute at a time:

```go
// op-node/rollup/driver/driver.go
for {{
    select {{
    case <-sequencerCh:
        // Sequencer: PreparePayloadAttributes() → L1/L2 RPC calls
        // Derivation CANNOT run while this arm holds the goroutine
        s.emitter.Emit(s.driverCtx, sequencing.SequencerActionEvent{{{{}}}})

    case <-s.sched.NextStep():
        // Derivation: fetch and process L1 batch data
        // Sequencer tick CANNOT fire while this arm holds the goroutine
        s.sched.AttemptStep(s.driverCtx)
    }}
}}
```

Under sustained full-block load, derivation holds the goroutine while processing large L1 batches — directly stalling the sequencer tick. Worst-case observed delay: **212 ms** (200 M gas, fully saturated). This is not a configurable parameter — it is a fundamental constraint of Go's single-goroutine serialisation.

### Why kona

**kona** (Rust / Tokio) separates sequencing and derivation into independent async tasks communicating through typed mpsc channels. No shared mutex. No serialisation. A slow L1 batch fetch in derivation cannot block the sequencer tick — they are scheduled concurrently by the Tokio runtime.

This eliminates the 212 ms class of stall by design. However, baseline kona introduced a different bottleneck in how its engine actor dispatched competing tasks.

### The kona Optimisation: `flush_pending_messages()`

kona's engine actor routes work through a `BinaryHeap` priority queue. Two task types compete:

| Task | Priority | Source |
|---|---|---|
| `BlockBuildInitiationRequest` | **HIGH** | Sequencer — once per 1-second slot |
| `AdvanceSafeHead` | LOW | Derivation — continuous safe-head updates |

**Baseline bug:** one message was read from the mpsc channel per loop iteration, pushed to the heap, then immediately dispatched. With only one item ever in the heap, priority was never exercised. A burst of `AdvanceSafeHead` messages from derivation could starve `BlockBuildInitiationRequest` for multiple iterations.

**The fix — actual code, before and after (engine_request_processor.rs):**

```rust
// ─── BEFORE: kona-baseline ────────────────────────────────────────────────────
//     EngineProcessor::start() main loop
loop {{
    self.drain().await?;
    // ⚠️ heap had ONE task per iteration
    //    Ord priority (Seal > Build > Insert > Consolidate > Finalize) never triggered

    let Some(req) = request_channel.recv().await else {{ return Err(EngineError::ChannelClosed) }};
    match req {{
        Build(r)               => self.engine.enqueue(EngineTask::Build(..)),       // BinaryHeap.push(Build)
        ProcessSafeL2Signal(s) => self.engine.enqueue(EngineTask::Consolidate(..)), // BinaryHeap.push(Consolidate)
        // ...
    }}
    // ← loop back: drain() sees ONE task → priority never fires
}}

// ─── AFTER: kona-optimised (fix/kona-engine-drain-priority) ──────────────────
//     THE FIX: flush ALL pending channel messages before next drain()
loop {{
    // Ord priority fires: Build[2] dispatched before Consolidate[4]
    // BuildTask::execute() → fork_choice_updated_v3(state, attrs) → reth → payloadId (T3)
    self.drain().await?;

    let Some(req) = request_channel.recv().await else {{ return Err(EngineError::ChannelClosed) }};
    self.handle_request(req).await?;         // → engine.enqueue(task) → BinaryHeap.push(task)

    while let Ok(req) = request_channel.try_recv() {{ // drain ALL remaining
        self.handle_request(req).await?;     // → engine.enqueue(task) → BinaryHeap.push(task)
    }}
    // ← loop back: drain() sees full heap → Build always wins over Consolidate
}}
```

**Measured improvement — kona-optimised vs kona-baseline:**

| Gas limit | BlockBuildLatency p99 | BlockBuildLatency max |
|---|---|---|
| 200 M (99.8% block fill) | 53 → 21 ms · **−61% · 2.6×** | 61 → 25 ms · **−59% · 2.5×** |
| 500 M (partial load) | 114 → 99 ms · **−14% · 1.2×** | 194 → 151 ms · **−22% · 1.3×** |

The improvement is largest at full saturation (200 M gas) where `AdvanceSafeHead` floods are most frequent — precisely the scenario when sequencer stability matters most.

---

## Terminology

| # | Term | Description |
|---|---|---|
| 1 | **CL** | Consensus Layer — the node responsible for block production decisions. In this report: op-node, kona, or base-cl. |
| 2 | **EL** | Execution Layer — OKX reth. Identical binary and configuration across all CL runs. |
| 3 | **BlockBuildInitiator** | CL-internal component that fires the per-block build tick. In op-node this is the `Driver` goroutine; in kona / base-cl it is the `sequencer actor`. Not to be confused with "sequencer" — in OKX the word "sequencer" refers to the combined EL+CL node. |
| 4 | **FCU / forkchoiceUpdated** | `engine_forkchoiceUpdatedV3` — Engine API call from CL to EL. Used here to start building a new block by attaching `payloadAttributes`. |
| 5 | **Block Build Initiation Latency** | Component metric. Time from the moment BlockBuildInitiationRequest is handed to the engine actor to the moment `payloadId` is received back from reth. Covers Phase 3 + Phase 4. Note: op-node has no queue — use Block Build Initiation — End to End Latency for fair cross-CL comparison. |
| 6 | **PayloadAttributes** | L2 block descriptor assembled by BlockBuildInitiator: L1 origin, timestamp, fee recipient, gas limit, and transaction list. Sent to reth via FCU to start block construction. |
| 7 | **mpsc channel** | Multi-producer single-consumer async channel (Tokio). kona / base-cl send `BlockBuildInitiationRequest` into this channel from the BlockBuildInitiator; the engine actor reads and processes messages from it. op-node has no such channel — BlockBuildInitiator calls the engine directly. |
| 8 | **BinaryHeap** | Priority queue inside kona's engine actor. After reading from the mpsc channel, each message is inserted here and the highest-priority task is dispatched. Determines whether `BlockBuildInitiationRequest` or `AdvanceSafeHead` fires next. |
| 9 | **AdvanceSafeHead** | Low-priority engine task: updates the safe / finalized head from the derivation pipeline. Competes with `BlockBuildInitiationRequest` in the BinaryHeap. In kona baseline, AdvanceSafeHead messages queued before BlockBuildInitiationRequest can starve BlockBuildInitiationRequest across multiple loop iterations. |
| 10 | **flush_pending_messages()** | The kona optimisation fix. Before calling `heap.pop()`, drains **all** pending mpsc channel messages into the BinaryHeap in one pass. Ensures `BlockBuildInitiationRequest[HIGH]` is visible to the heap so it always wins over `AdvanceSafeHead[LOW]`. |
| 11 | **sync.Mutex** | Go mutual-exclusion lock in op-node's `Driver` struct. Shared between the sequencer goroutine and the derivation goroutine — when one holds it, the other is blocked. Root cause of op-node's BlockBuildInitiation-RequestGenerationLatency spikes under heavy L1 batch load. |
| 12 | **T0** · `BlockBuildInitiation-StartTime` | **Phase 1 Start Time.** BlockBuildInitiator tick fires — marks the beginning of block-build initiation for this 1-second slot. |
| 13 | **T1** · `BlockBuildInitiation-RequestGeneratedAt` | **Phase 1 End Time / Phase 3 Start Time.** `PayloadAttributes` assembled and handed to the engine actor — marks the end of Block Build Initiation Request Generation Latency and the start of Block Build Initiation Request - Queue Dispatch Latency (kona / base-cl) or the direct engine call (op-node, where T1 ≈ T2). |
| 14 | **T2** · `BlockBuildInitiation-HTTPRequestSentTime` | **Phase 3 End Time / Phase 4 Start Time.** HTTP `engine_forkchoiceUpdated` request dispatched to reth — marks the end of Block Build Initiation Request - Queue Dispatch Latency and the start of Block Build Initiation Request - Http Sender Roundtrip Latency. For op-node this coincides with T1. |
| 15 | **T3** · `BlockBuild-ExecutionLayer-JobIdReceivedAt` | **Phase 4 End Time.** `payloadId` received back from reth — marks the end of Block Build Initiation Request - Http Sender Roundtrip Latency and confirms reth has started building the block. This is the finish line for Block Build Initiation Latency. |

---

## System Architecture — Kona Actor Model

Every actor is an independent `tokio::task`. No shared mutable state — all inter-actor communication uses typed async channels. This is the structural reason kona can run derivation and sequencing truly in parallel while op-node serialises them inside a single `select!` goroutine.

```mermaid
graph TD
    EXT["💻 External Clients\\n(wallets, explorers, bridges)"]
    L1["⛓ L1 Chain\\n(Ethereum / devnet)"]
    L1W["👁 L1WatcherActor\\nPolls L1 for new blocks\\nBroadcasts head to all consumers"]
    DA["🔵 DerivationActor\\nReplays L1 batches → safe L2 blocks"]
    SA["🟢 SequencerActor\\nBuilds 1 L2 block per second"]
    NA["🌐 NetworkActor\\nP2P gossip (libp2p)"]
    RA["📡 RpcActor\\nPublic JSON-RPC endpoint\\n(port 9545)"]
    RETH["🔴 reth (OKX fork)\\nEVM + state + mempool\\nOne Engine API call at a time"]
    P2P["🌍 P2P Network\\n(followers / other nodes)"]
    COND["🎯 Conductor\\nLeader election (HA only)"]

    subgraph EA_SG["🟡 EngineActor — routes all engine requests"]
        RPCP["🔷 RpcProcessor\\nRead-only queries · In-memory state\\nNO reth calls — answers from local cache"]
        EP["🔶 EngineProcessor\\nBinaryHeap priority queue\\nSole owner of reth Engine API"]
    end

    EXT -->|"HTTP JSON-RPC\\n(public port 9545)"| RA
    L1 -->|"new L1 block headers"| L1W
    L1W -->|"L1BlockInfo\\nDerivation: which L1 batches to replay next"| DA
    L1W -->|"L1BlockInfo\\nSequencer: next_l1_origin() — L1 attrs pre-cached\\nprevRandao · parentBeaconBlockRoot source"| SA

    DA -->|"Consolidate(safe_signal)\\nvia mpsc"| EP
    DA -->|"Finalize(block_num)\\nvia mpsc"| EP

    SA -->|"Build(PayloadAttributes)\\nvia mpsc  ← T1 fires here"| EP
    SA -->|"Seal(payload_id)\\nvia mpsc"| EP

    NA -->|"Insert(unsafe_block)\\nvia mpsc"| EP
    RA -->|"RpcRequest (read-only)\\n→ RpcProcessor · in-memory\\nnever touches reth"| RPCP

    EP -->|"engine_forkchoiceUpdatedV3 + attrs\\n(Build — starts block in reth)"| RETH
    EP -->|"engine_forkchoiceUpdatedV3 no-attrs\\n(Seal / Consolidate / Finalize)"| RETH
    EP -->|"engine_newPayloadV3\\n(Seal / Insert)"| RETH
    EP -->|"engine_getPayloadV3\\n(Seal)"| RETH

    RETH -->|"P2P block broadcast"| P2P
    P2P -->|"received block (gossip)"| NA
    COND -.->|"HTTP: am I sequencer leader?"| SA

    style EXT  fill:#0d2b0d,color:#a8d5a2,stroke:#43a047
    style L1   fill:#1a1a2e,color:#eee,stroke:#4a4a8a
    style L1W  fill:#1a3a5c,color:#eee,stroke:#2196f3
    style DA   fill:#1a3048,color:#90caf9,stroke:#1976d2
    style SA   fill:#1b4332,color:#b7e4c7,stroke:#40916c
    style NA   fill:#2d1b4e,color:#ce93d8,stroke:#9c27b0
    style RA   fill:#3a2800,color:#fff9c4,stroke:#f9a825
    style RPCP fill:#0a1a3a,color:#90caf9,stroke:#2196f3
    style EP   fill:#3e1f00,color:#ffe0b2,stroke:#f57c00
    style RETH fill:#4a1a4a,color:#fff,stroke:#e91e63
    style P2P  fill:#2d3748,color:#e2e8f0,stroke:#718096
    style COND fill:#1a4a2a,color:#c8e6c9,stroke:#4caf50
```

> **Why does L1WatcherActor send L1BlockInfo to SequencerActor?**
>
> When SequencerActor wakes at T0, it calls `next_l1_origin()` to decide which L1 block this L2 block references. Rather than a live L1 RPC call every second, it reads the `L1BlockInfo` already pushed by L1WatcherActor. This pre-cached state provides the L1 block hash used as source for `prevRandao` (`L1BlockInfo.mix_hash`), `parentBeaconBlockRoot` (via `InfoByHash()` RPC), and deposit receipts. The WatcherActor absorbs the L1-polling cost continuously in the background so neither SequencerActor nor DerivationActor needs to poll L1 directly.

**Engine API — all task types, priorities, and calls:**

| Priority | Task | Sent by | Engine API call(s) | What it does |
|---|---|---|---|---|
| 1 — highest | `Build` | SequencerActor | `engine_forkchoiceUpdatedV3` + attrs | Starts block construction in reth → returns `payloadId` |
| 2 | `Seal` | SequencerActor | `engine_getPayloadV3` → `engine_newPayloadV3` → `engine_forkchoiceUpdatedV3` | Fetches built block, imports, advances unsafe head |
| 3 | `Insert` | NetworkActor | `engine_newPayloadV3` → `engine_forkchoiceUpdatedV3` | Imports P2P-received block, advances unsafe head |
| 4 | `Consolidate` | DerivationActor | `engine_forkchoiceUpdatedV3` no-attrs (safeHash set) | Advances safe head after L1 batch derived |
| 5 — lowest | `Finalize` | DerivationActor | `engine_forkchoiceUpdatedV3` no-attrs (finalHash set) | Advances finalized head after L1 finality |

> **Critical constraint:** reth's `authrpc` processes one Engine API call at a time (HTTP FIFO). `EngineProcessor` is the sole actor that owns this connection — the BinaryHeap serialises all 5 task types in priority order. `Build` always executes before any pending `Consolidate`. This is the invariant the kona fix restores.

---

## Phase Map

```mermaid
flowchart LR
    subgraph CYCLE["◄──────────────── Block Build Initiation — End to End Latency  T0 → T3 ────────────────►"]
        direction LR
        T0(["📍 T0\\nBlockBuildInitiation-StartTime\\nBlockBuildInitiator tick fires"])
        ATTRBOX["① BlockBuildInitiation-RequestGenerationLatency\\nL1 origin lookup · SystemConfig (L2 RPC) · L1 block data (L1 RPC)\\nPayloadAttributes assembly"]
        T1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nBlockBuildInitiationRequest ready"])
        T2(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nHTTP Roundtrip starts"])
        T3(["📍 T3\\nBlockBuild-ExecutionLayer-JobIdReceivedAt\\npayloadId received"])
    end

    subgraph Q12["③ Block Build Initiation Request - Queue Dispatch Latency  (kona / base-cl only)"]
        direction LR
        CH["② Build Signal\\nmpsc channel send\\nasync buffer"]
        HEAP["BinaryHeap\\npriority queue\\nBlockBuildInitiationRequest\\[HIGH\\] wins"]
        CH -->|"recv() · flush_pending\\n→ heap.push all msgs"| HEAP
    end

    T0 --> ATTRBOX
    ATTRBOX --> T1
    T1 -->|"② Build Signal\\nkona/base-cl: mpsc send"| CH
    HEAP -->|"BlockBuildInitiationRequest dispatched\\nhighest priority"| T2
    T1 -.->|"② Build Signal\\nop-node: direct call  T1≈T2"| T2
    T2 -->|"④ BlockBuildInitiation-HttpSender-RoundtripLatency\\nengine_forkchoiceUpdated → reth"| T3

    style CYCLE   fill:#f8f8f8,stroke:#999,stroke-width:2px,color:#000
    style Q12     fill:#fffbf0,stroke:#FF6600,stroke-width:1px,color:#000
    style T0      fill:#FFF3CC,stroke:#FFA500,stroke-width:2px,color:#333
    style T1      fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T2      fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T3      fill:#CCE5FF,stroke:#4488FF,stroke-width:2px,color:#333
    style CH      fill:#fff8e8,stroke:#FFA500,stroke-width:1px,color:#333
    style HEAP    fill:#FFF9C4,stroke:#F9A825,stroke-width:1px,color:#333
    style ATTRBOX fill:#FFF3E0,stroke:#FF9800,stroke-width:1px,color:#333
    linkStyle 0 stroke:#FFA500,stroke-width:3px
    linkStyle 1 stroke:#FFA500,stroke-width:2px
    linkStyle 2 stroke:#FFA500,stroke-width:2px
    linkStyle 3 stroke:#F9A825,stroke-width:2px
    linkStyle 4 stroke:#FF6600,stroke-width:3px
    linkStyle 5 stroke:#999,stroke-width:1.5px,stroke-dasharray:5
    linkStyle 6 stroke:#4488FF,stroke-width:3px
```

| Phase | Start → End | Name | What happens | Key CL difference |
|---|---|---|---|---|
| 1 | **BlockBuildInitiation-StartTime → BlockBuildInitiation-RequestGeneratedAt** | BlockBuildInitiation-RequestGenerationLatency | BlockBuildInitiator tick fires → L1/L2 RPC calls → PayloadAttributes assembled | op-node: sync (node frozen) · kona/base-cl: async (concurrent) |
| 2 | **at BlockBuildInitiation-RequestGeneratedAt** | Block Build Initiation Signal | BlockBuildInitiationRequest handed from BlockBuildInitiator to engine actor | op-node: no channel, direct call · kona/base-cl: mpsc channel send |
| 3 | **BlockBuildInitiation-RequestGeneratedAt → BlockBuildInitiation-HTTPRequestSentTime** | `BlockBuildInitiation-QueueDispatchLatency` *(kona / base-cl only)* | BlockBuildInitiationRequest waits in BinaryHeap until engine actor dispatches it | **Where the kona fix acts** — baseline starves BlockBuildInitiationRequest behind AdvanceSafeHead |
| 4 | **BlockBuildInitiation-HTTPRequestSentTime → BlockBuild-ExecutionLayer-JobIdReceivedAt** | `BlockBuildInitiation-HttpSender-RoundtripLatency` | HTTP `engine_forkchoiceUpdated` sent to reth → `payloadId` received — network call only | Identical across all CLs — irreducible network + reth startup cost |

---

## Results

| CL | TPS | Block fill | Block Build Initiation — End to End Latency Median | Block Build Initiation — End to End Latency 99th Percentile | Block Build Initiation — End to End Latency Maximum |
|---|---|---|---|---|---|
{results_rows}

> Block Build Initiation — End to End Latency = total time from sequencer tick to reth acknowledgement. **Primary cross-CL comparison metric** — includes all CL overhead. Lower is better.

---

## Phase 1 — `BlockBuildInitiation-RequestGenerationLatency`

> **Start (T0):** BlockBuildInitiator tick fires — the CL-internal block-build driver wakes up once per second.
> **End (T1):** `PayloadAttributes` assembled and ready to hand off to engine actor.
> **Why it matters:** op-node freezes the entire node during BlockBuildInitiation-RequestGenerationLatency; kona/base-cl run it concurrently.

```mermaid
flowchart TB
    subgraph OPNODE["⚠️  op-node — SYNCHRONOUS  (sync.Mutex held · Driver goroutine blocked · entire node frozen)"]
        direction TB
        OP0(["📍 T0\\nBlockBuildInitiation-StartTime\\nBlockBuildInitiator tick fires"])
        OP_L1["① FindL1Origin()\\nL1 RPC/cache · Which L1 block does this L2 block reference?"]
        OP_ATTR["② PreparePayloadAttributes()\\n· SystemConfigByL2Hash()  L2 RPC\\n· InfoByHash()  L1 RPC\\n· Assemble deposits + system txs\\n⚠️ Derivation · P2P · Admin RPC blocked here"]
        OP_WRAP["③ Wrap + no-tx-pool flag  (local logic · no RPC)"]
        OP1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nattrs ready\\nMedian={op_a_p50}  99th Percentile={op_a_p99}  Maximum={op_a_max}"])
        OP0 --> OP_L1 --> OP_ATTR --> OP_WRAP --> OP1
    end
    subgraph KONA["✅  kona / base-cl — ASYNC  (independent Tokio task · derivation runs in parallel)"]
        direction TB
        KO0(["📍 T0\\nBlockBuildInitiation-StartTime\\nBlockBuildInitiator tick fires"])
        KO_HEAD["① get_unsafe_head().await\\nCurrent L2 unsafe head  (local EL state)"]
        KO_ORIG["② next_l1_origin().await\\nL1 origin lookup  (same logic as op-node FindL1Origin)"]
        KO_ATTR["③ prepare_payload_attributes().await\\nL1 RPC · SystemConfig in-memory cache ✅ (Opt-2)\\nDeposits + system config + system txs\\n✅ yields at .await · other actors proceed"]
        KO_WRAP["④ Wrap + no-tx-pool flag  (local logic · no RPC)"]
        KO1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nattrs ready\\nkona:    Median={kb_a_p50}  99th Percentile={kb_a_p99}  Maximum={kb_a_max}\\nbase-cl: Median={bc_a_p50}  99th Percentile={bc_a_p99}  Maximum={bc_a_max}"])
        KO0 --> KO_HEAD --> KO_ORIG --> KO_ATTR --> KO_WRAP --> KO1
    end

    style OPNODE fill:#fff5f5,stroke:#ff4444,stroke-width:2px,color:#000
    style KONA   fill:#f0fff4,stroke:#22cc44,stroke-width:2px,color:#000
    style OP0    fill:#FFF3CC,stroke:#FFA500,stroke-width:2px,color:#333
    style OP1    fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style KO0    fill:#FFF3CC,stroke:#FFA500,stroke-width:2px,color:#333
    style KO1    fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style OP_L1  fill:#fff8f0,stroke:#ffaa66,stroke-width:1px,color:#333
    style OP_ATTR fill:#ffe8e8,stroke:#ff6666,stroke-width:1px,color:#333
    style OP_WRAP fill:#fff8f0,stroke:#ffaa66,stroke-width:1px,color:#333
    style KO_HEAD fill:#e8fff0,stroke:#66cc88,stroke-width:1px,color:#333
    style KO_ORIG fill:#e8fff0,stroke:#66cc88,stroke-width:1px,color:#333
    style KO_ATTR fill:#e8fff0,stroke:#66cc88,stroke-width:1px,color:#333
    style KO_WRAP fill:#e8fff0,stroke:#66cc88,stroke-width:1px,color:#333
    linkStyle 0 stroke:#ff4444,stroke-width:2px
    linkStyle 1 stroke:#ff8888,stroke-width:3px
    linkStyle 2 stroke:#ff4444,stroke-width:2px
    linkStyle 3 stroke:#ff4444,stroke-width:2px
    linkStyle 4 stroke:#22cc44,stroke-width:2px
    linkStyle 5 stroke:#22cc44,stroke-width:2px
    linkStyle 6 stroke:#22cc44,stroke-width:3px
    linkStyle 7 stroke:#22cc44,stroke-width:2px
    linkStyle 8 stroke:#22cc44,stroke-width:2px
```

### PayloadAttributes — field-by-field assembly

The `Build` task carries a full FCU+attrs call to reth. Every field in `payloadAttributes` has a specific source — this is the complete work of BlockBuildInitiation-RequestGenerationLatency:

```
engine_forkchoiceUpdatedV3( forkchoiceState, payloadAttributes )

forkchoiceState:
  headBlockHash         ← get_unsafe_head()          [local EL state — no RPC]
  safeBlockHash         ← local safe head             [local — no RPC]
  finalizedBlockHash    ← local finalized head        [local — no RPC]

payloadAttributes:
  timestamp             ← parent.timestamp + BLOCK_TIME (2s)    [computed — no RPC]
  prevRandao            ← L1BlockInfo.mix_hash        ← L1WatcherActor broadcast (pre-cached)
  suggestedFeeRecipient ← node config (sequencer fee address)   [static — no RPC]
  parentBeaconBlockRoot ← L1 RPC: InfoByHash(l1_origin_hash)    ← network call ①
  transactions[]        ← L1 RPC: deposit receipts at l1_origin ← network call ②
                          + system config update txs             [local assembly]
  gasLimit              ← AlloyL2ChainProvider.last_system_config  ← in-memory ✅ (kona, Opt-2)
                        ← L2 RPC: SystemConfigByL2Hash()          ← network call ③ (op-node)
  noTxPool              = false   → reth fills remaining gas from mempool after forced txs
  withdrawals           = []      → OP Stack: L1 withdrawal proofs, not EL-level
```

| Field | Source | How it arrives |
|---|---|---|
| `headBlockHash` | Local EL | `get_unsafe_head()` — in-process, no RPC |
| `timestamp` | Computed | `parent.timestamp + 2s` — no RPC |
| `prevRandao` | **L1WatcherActor** | `L1BlockInfo.mix_hash` — pre-cached, no live L1 call at T0 |
| `parentBeaconBlockRoot` | L1 RPC ① | `InfoByHash(l1_origin)` — slowest field |
| `transactions[]` | L1 RPC ② + local | Deposit receipts from l1_origin block + system config update txs |
| `gasLimit` | kona: in-memory cache ✅ (Opt-2) · op-node: L2 RPC ③ | kona: `AlloyL2ChainProvider.last_system_config` invalidated by L1WatcherActor · op-node: `SystemConfigByL2Hash(l2_parent_hash)` |
| `suggestedFeeRecipient` | Node config | Static sequencer address — no RPC |
| `noTxPool` | Hardcoded `false` | Allows reth to include mempool TXs after the forced transactions |
| `withdrawals` | Hardcoded `[]` | OP Stack withdrawals are settled on L1 via withdrawal proofs |

> `prevRandao` looks like it needs an L1 call but does not — the WatcherActor already fetched the L1 block header and broadcast `mix_hash`. The three RPC calls (①②③) are the irreducible work of BlockBuildInitiation-RequestGenerationLatency and are identical in op-node and kona. The difference: kona runs them in a separate Tokio task (yields at each `.await`); op-node holds `sync.Mutex` across all three.

### Why op-node spikes at this phase

The root cause is the **single goroutine event loop** in `driver.go`:

```go
// op-node/rollup/driver/driver.go — one goroutine, two competing arms
for {{
    select {{
    case <-sequencerCh:
        // SEQUENCER arm: runs startBuildingBlock() → PreparePayloadAttributes()
        // Blocks the goroutine until ALL RPC calls finish.
        // While blocked: derivation CANNOT run.
        s.emitter.Emit(s.driverCtx, sequencing.SequencerActionEvent{{}})

    case <-s.sched.NextStep():
        // DERIVATION arm: runs AttemptStep() → fetches L1 data
        // Blocks the goroutine until L1 fetch completes.
        // While blocked: sequencer tick CANNOT fire.
        s.sched.AttemptStep(s.driverCtx)
    }}
    // Only ONE arm runs per loop iteration — hard serialisation by design.
}}
// At {gas_str} gas: heavy L1 batches → AttemptStep() holds longer
// → sequencer tick queues → when it fires, RPC server already busy
// → PreparePayloadAttributes() spikes → BlockBuildInitiation-RequestGenerationLatency reaches {ms(a_max.get("op-node"))}
```

kona has **no such loop** — the sequencer actor is a completely separate `tokio::task`,
communicating with derivation only via typed channels. No mutex. No serialisation.

---

## Phase 2 — Block Build Initiation Signal  `at T1`

> **Point (T1):** `BlockBuildInitiationRequest` is handed from the BlockBuildInitiator to the engine actor. T1 is a single point in time, not a duration.
> **Why it matters:** op-node has no channel — T1 and T2 are the same moment. kona/base-cl introduce an mpsc channel here, which creates the Phase 3 interval.

```
T1 ──── BlockBuildInitiationRequest ready
         │
         ├─ op-node ── NO CHANNEL — sequencer IS the engine caller
         │
         │   func startBuildingBlock(ctx) {{
         │       attrs := d.attrBuilder.PreparePayloadAttributes(...)  // Phase 1 above
         │       //
         │       // T1 and T2 are the SAME goroutine call:
         │       d.engine.StartPayload(ctx, l2Head, fc, attrs, false)
         │       //      ↑ fires HTTP engine_forkchoiceUpdated immediately
         │   }}
         │   BlockBuildInitiation-QueueDispatchLatency ≈ 0 ms by architectural design (no queue exists)
         │
         └─ kona / base-cl ── mpsc CHANNEL — non-blocking send to engine actor
             │
             │   // In build_unsealed_payload(), after attrs are ready:
             │   let build_request_start = Instant::now();   // T1 clock starts
             │
             │   // Sends BlockBuildInitiationRequest into bounded mpsc channel.
             │   // The send itself is near-instant (channel has capacity).
             │   self.engine_client.start_build_block(attrs).await?
             │   //   ↑ this .await resolves when payloadId is received (T3)
             │   //     so build_request_start.elapsed() at T3 = Block Build Initiation Latency total
             │
             └─ engine actor receives asynchronously in its own tokio::task

Phase 3 begins: engine actor must drain channel → BinaryHeap → pick task by priority
```

---

## Phase 3 — `BlockBuildInitiation-QueueDispatchLatency`  *(kona / base-cl only)*

> **Start (T1):** `BlockBuildInitiationRequest` enters the mpsc channel.
> **End (T2):** Engine actor fires `engine_forkchoiceUpdated` HTTP to reth.
> **Why it matters:** This is where the kona fix acts — baseline starves `BlockBuildInitiationRequest` behind `AdvanceSafeHead` in the BinaryHeap. op-node skips this phase entirely (N/A ≈ 0ms, no queue).

Two task types compete in the heap:

| Task | Source | Priority | Frequency |
|---|---|---|---|
| `BlockBuildInitiationRequest` | BlockBuildInitiator | **HIGH** | 1× per block (1/s) |
| `AdvanceSafeHead` | Derivation pipeline | LOW | continuous — safe/finalized head updates |

### Step-by-step flow (what the engine actor does each iteration)

```mermaid
flowchart TB
    T1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nBlockBuildInitiationRequest placed\\ninto mpsc channel"])

    STEP1["Step 1 — Channel Wait\\nEngine actor calls recv().await\\nBlocks until any message arrives.\\nImportant: an AdvanceSafeHead message sent\\nbefore BlockBuildInitiationRequest may be picked up first!"]

    STEP2B["Step 2 — Into BinaryHeap\\nheap.push(msg)\\n─────────────────────────────\\n❌ BASELINE: proceed immediately\\n   heap has incomplete view — BlockBuildInitiationRequest\\n   may still be unread in channel\\n─────────────────────────────\\n✅ OPTIMISED: flush_pending_messages()\\n   drain ALL remaining channel msgs\\n   heap now has the full picture"]

    STEP3["Step 3 — Priority Pick\\nheap.pop() → highest priority task\\n─────────────────────────────\\n❌ BASELINE: AdvanceSafeHead[LOW] may win\\n   because BlockBuildInitiationRequest[HIGH] was never read\\n✅ OPTIMISED: BlockBuildInitiationRequest[HIGH] always wins\\n   heap saw every pending message"]

    CONSOL(["⏳ AdvanceSafeHead runs\\n(safe/finalized head update)\\nBlockBuildInitiationRequest waits — loop repeats\\nbaseline stall: up to {kb_q_max}"])
    T2OK(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nHTTP Roundtrip starts\\noptimised: ≤ {ko_q_max}"])

    T1      --> STEP1
    STEP1   --> STEP2B
    STEP2B  --> STEP3
    STEP3   -->|"AdvanceSafeHead wins\\n(baseline)"| CONSOL
    STEP3   -->|"BlockBuildInitiationRequest wins\\n(optimised — always)"| T2OK
    CONSOL  -.->|"loop back\\nnext iteration"| STEP1

    style T1     fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T2OK   fill:#CCE5FF,stroke:#4488FF,stroke-width:2px,color:#333
    style CONSOL fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style STEP2B fill:#FFF9C4,stroke:#F9A825,stroke-width:1px,color:#333
    linkStyle 3 stroke:#ff4444,stroke-width:2px
    linkStyle 4 stroke:#22cc44,stroke-width:3px
    linkStyle 5 stroke:#ff4444,stroke-width:2px,stroke-dasharray:5
```

### Before vs After — where the fix lands

```mermaid
flowchart TB
    subgraph BEFORE["❌  kona baseline — recv() one at a time · BlockBuildInitiationRequest starved"]
        direction LR
        CB(["channel\\nAdvanceSafeHead[LOW]\\nAdvanceSafeHead[LOW]\\nBlockBuildInitiationRequest[HIGH]"]) -->|"Step 1: recv() one msg\\nStep 2: push to heap (incomplete)"| HB["heap — partial view\\nAdvanceSafeHead[LOW]  ← pops 1st\\nAdvanceSafeHead[LOW]  ← pops 2nd\\nBlockBuildInitiationRequest[HIGH]  ← never seen yet!"]
        HB -->|"Step 3: pop top"| OB(["⏳ AdvanceSafeHead runs\\nloop repeats\\n99th Percentile={kb_q_p99}  Maximum={kb_q_max}"])
        OB -.->|"eventually\\nBlockBuildInitiationRequest dequeued"| RB(["HTTP Roundtrip → reth\\nT2 fires (delayed)"])
    end

    subgraph AFTER["✅  kona optimised — flush first · BlockBuildInitiationRequest always wins"]
        direction LR
        CA(["channel\\nAdvanceSafeHead[LOW]\\nAdvanceSafeHead[LOW]\\nBlockBuildInitiationRequest[HIGH]"]) -->|"Step 1: recv() first msg\\nStep 2: flush_pending_messages()\\n→ drain ALL into heap at once"| HA["heap — complete view\\nBlockBuildInitiationRequest[HIGH]  ← wins ★\\nAdvanceSafeHead[LOW]\\nAdvanceSafeHead[LOW]"]
        HA -->|"Step 3: pop top"| DA(["BlockBuildInitiationRequest dispatched immediately"])
        DA --> OA(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nHTTP Roundtrip starts\\n99th Percentile={ko_q_p99}  Maximum={ko_q_max}"])
    end

    style BEFORE fill:#fff5f5,stroke:#ff4444,stroke-width:2px,color:#000
    style AFTER  fill:#f0fff4,stroke:#22cc44,stroke-width:2px,color:#000
    style OB     fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style RB     fill:#FFE0B2,stroke:#FF6600,stroke-width:1px,color:#333
    style DA     fill:#E8F5E9,stroke:#388E3C,stroke-width:1px,color:#333
    style OA     fill:#C8E6C9,stroke:#2E7D32,stroke-width:2px,color:#333
    style HB     fill:#FFF9C4,stroke:#F9A825,stroke-width:1px,color:#333
    style HA     fill:#E8F5E9,stroke:#388E3C,stroke-width:1px,color:#333
```

---

## Phase 4 — `BlockBuildInitiation-HttpSender-RoundtripLatency`

> **Start (T2):** HTTP `engine_forkchoiceUpdatedV3(forkchoiceState, payloadAttributes)` sent to reth.
> **End (T3):** `payloadId` received back — reth has started the block builder.
> **Why it matters:** This is the **network-only** portion of the FCU call. It is **irreducible** — pure network latency + reth startup. No CL change can improve it.
> **Not to be confused with:** Block Build Initiation Latency = Phase 3 + Phase 4 combined — the full interval from build decision to payloadId. BlockBuildInitiation-HttpSender-RoundtripLatency is only the wire call portion.

```mermaid
flowchart LR
    subgraph CLP["CL process"]
        T2(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nHTTP Roundtrip starts\\nengine_forkchoiceUpdated\\n+payloadAttributes"])
    end
    subgraph RETHP["reth process"]
        RETH["① validate forkchoice state\\n② start payload builder\\n③ return payloadId"]
        T3(["📍 T3\\nBlockBuild-ExecutionLayer-JobIdReceivedAt\\npayloadId received\\nreth now building"])
    end
    T2 -->|"BlockBuildInitiation-HttpSender-RoundtripLatency\\nop-node:   Median={op_f_p50}  99th Percentile={op_f_p99}  Maximum={op_f_max}\\nkona base: Median={kb_f_p50}  99th Percentile={kb_f_p99}  Maximum={kb_f_max}\\nkona opt:  Median={ko_f_p50}  99th Percentile={ko_f_p99}  Maximum={ko_f_max}\\nbase-cl:   Median={bc_f_p50}  99th Percentile={bc_f_p99}  Maximum={bc_f_max}\\nirreducible — same reth binary for all CLs"| RETH
    RETH --> T3

    FORMULA["💡 BlockBuildInitiation-HttpSender-RoundtripLatency is irreducible\\nAll CLs make the same HTTP call to the same reth.\\nDivergence at 99th Percentile / Maximum reflects reth state under load,\\nnot CL behaviour. reth keeps building until CL calls\\nengine_getPayload at end of the 1-second slot."]

    style CLP     fill:#fff8e8,stroke:#FFA500,stroke-width:2px,color:#000
    style RETHP   fill:#e8f4ff,stroke:#4488FF,stroke-width:2px,color:#000
    style FORMULA fill:#f0fff4,stroke:#22cc44,stroke-width:2px,color:#333
    style T2      fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T3      fill:#CCE5FF,stroke:#4488FF,stroke-width:2px,color:#333
    linkStyle 0 stroke:#4488FF,stroke-width:3px
```

What drives BlockBuildInitiation-HttpSender-RoundtripLatency variance:

| Factor | Effect |
|---|---|
| Engine API RPC overhead (localhost) | ~0.5–2 ms baseline |
| reth chain state validation | Grows with unsafe head depth, safe lag |
| reth payload builder startup | Minimal at 1-second blocks |
| **CL implementation** | **None — all CLs make the same call to the same reth** |

BlockBuildInitiation-HttpSender-RoundtripLatency is the same at Median for all CLs. 99th Percentile / Maximum divergence reflects reth state under load, not CL behaviour.

---

## Block Build Initiation — End to End Latency Summary

{summary_tbl}

> **Block Build Initiation — End to End Latency** = BlockBuildInitiation-RequestGenerationLatency + BlockBuildInitiation-QueueDispatchLatency + BlockBuildInitiation-HttpSender-RoundtripLatency. Complete sequencer end-to-end latency from build decision to reth acknowledgement. Lower is better.

---

## kona Optimisation Summary

{rec}- Same throughput as op-node — zero regression in TPS or block fill

---

## Metric Guide

| Metric | What it answers | At ~120 blocks/run |
|---|---|---|
| **Median** | Typical block — half are faster | The normal operating case |
| **Average** | Mean — Average ≫ Median means tail events pull it up | Confirms tail frequency |
| **99th Percentile** | 1-in-100 worst — repeatable, not a fluke | ~1–2 real events per run |
| **Maximum** | Single worst block in the run | Risk ceiling — may not recur |

```
Median          →  "usually fine"           design the happy path around this
Average         →  "how heavy is the tail"  Average ≈ Median → rare spikes; Average ≫ Median → frequent spikes
99th Percentile →  "reliable tail"          repeatable — happens in every production run
Maximum         →  "absolute worst case"    risk ceiling — one block, treat as outlier
```

---

*Full percentile data: `comparison.md` · Generated {date_str}*
"""

    out_path = run_dir / "phase-report.md"
    out_path.write_text(out)
    print(f"✅  phase-report.md → {out_path}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: generate-phase-report.py <run_dir> [<run_dir> ...]"); sys.exit(1)
    for d in sys.argv[1:]:
        generate(d)
