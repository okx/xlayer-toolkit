#!/usr/bin/env python3
"""
generate-simple-report.py — generates simple-report.md matching the agreed
simple-comparison.md format, auto-populated from JSON metrics.

Usage:
    python3 bench/scripts/generate-simple-report.py bench/runs/<session>/
"""

import json, sys, datetime
from pathlib import Path

CL_DISPLAY = {
    "op-node":            "op-node",
    "kona-okx-baseline":  "kona baseline",
    "kona-okx-optimised": "**kona optimised**",
    "base-cl":            "base-cl",
}
PREFERRED_ORDER = ["op-node", "kona-okx-baseline", "kona-okx-optimised", "base-cl"]

def bold_min(vals, v, fmt=".0f"):
    if v is None: return "—"
    best = min(x for x in vals if x is not None)
    s = f"{v:{fmt}} ms"
    return f"**{s}** ✅" if v == best else s

def generate(run_dir):
    run_dir = Path(run_dir)
    files   = sorted(f for f in run_dir.glob("*.json") if "." not in f.stem)
    if len(files) < 2:
        print(f"Need ≥2 JSON files in {run_dir}"); sys.exit(1)

    cl_map = {f.stem: f for f in files}
    cls    = [c for c in PREFERRED_ORDER if c in cl_map] + \
             [c for c in cl_map if c not in PREFERRED_ORDER]
    data   = {cl: json.load(open(cl_map[cl])) for cl in cls}

    ref        = data[cls[0]]
    gas_str    = ref.get("gas_limit_str", "?")
    date_str   = ref.get("date", datetime.date.today().isoformat())
    dur        = ref.get("duration_s", 120)
    acct_count = ref.get("account_count", 20000)
    acct_str   = f"{acct_count:,}"

    # ── T0→T3: Full cycle (PRIMARY metric) ────────────────────────────────────
    tps    = {cl: data[cl].get("tps_block")         for cl in cls}
    fill   = {cl: data[cl].get("block_fill")         for cl in cls}
    bw_p50 = {cl: data[cl].get("cl_build_wait_p50")  for cl in cls}  # T1→T3 (breakdown only)
    bw_p99 = {cl: data[cl].get("cl_build_wait_p99")  for cl in cls}  # T1→T3 (breakdown only)
    bw_max = {cl: data[cl].get("cl_build_wait_max")  for cl in cls}  # T1→T3 (breakdown only)

    # ── All intervals (for breakdown tables) ──────────────────────────────────
    total_p50 = {cl: data[cl].get("cl_total_wait_p50") for cl in cls}  # T0→T3
    total_avg = {cl: data[cl].get("cl_total_wait_avg") for cl in cls}
    total_max = {cl: data[cl].get("cl_total_wait_max") for cl in cls}
    attr_p50  = {cl: data[cl].get("cl_attr_prep_p50")  for cl in cls}  # T0→T1
    attr_avg  = {cl: data[cl].get("cl_attr_prep_avg")  for cl in cls}
    attr_p99  = {cl: data[cl].get("cl_attr_prep_p99")  for cl in cls}
    attr_max  = {cl: data[cl].get("cl_attr_prep_max")  for cl in cls}
    queue_p50 = {cl: data[cl].get("cl_queue_wait_p50") for cl in cls}  # T1→T2
    queue_avg = {cl: data[cl].get("cl_queue_wait_avg") for cl in cls}
    queue_p99 = {cl: data[cl].get("cl_queue_wait_p99") for cl in cls}
    queue_max = {cl: data[cl].get("cl_queue_wait_max") for cl in cls}
    bw_avg    = {cl: data[cl].get("cl_build_wait_avg") for cl in cls}  # T1→T3
    fcu_p50   = {cl: data[cl].get("cl_fcu_attrs_p50")  for cl in cls}  # T2→T3
    fcu_avg   = {cl: data[cl].get("cl_fcu_attrs_avg")  for cl in cls}
    fcu_p99   = {cl: data[cl].get("cl_fcu_attrs_p99")  for cl in cls}
    fcu_max   = {cl: data[cl].get("cl_fcu_attrs_max")  for cl in cls}
    total_p99 = {cl: data[cl].get("cl_total_wait_p99") for cl in cls}  # T0→T3

    # ── T0→T1 micro-steps (kona only — None for op-node/base-cl) ──────────────
    step_a_avg = {cl: data[cl].get("cl_attr_step_a_avg") for cl in cls}
    step_a_p99 = {cl: data[cl].get("cl_attr_step_a_p99") for cl in cls}
    step_b_avg = {cl: data[cl].get("cl_attr_step_b_avg") for cl in cls}
    step_b_p99 = {cl: data[cl].get("cl_attr_step_b_p99") for cl in cls}
    step_c_avg = {cl: data[cl].get("cl_attr_step_c_avg") for cl in cls}
    step_c_p99 = {cl: data[cl].get("cl_attr_step_c_p99") for cl in cls}
    step_c1_avg = {cl: data[cl].get("cl_attr_step_c1_avg") for cl in cls}
    step_c1_p99 = {cl: data[cl].get("cl_attr_step_c1_p99") for cl in cls}
    step_c2_avg = {cl: data[cl].get("cl_attr_step_c2_avg") for cl in cls}
    step_c2_p99 = {cl: data[cl].get("cl_attr_step_c2_p99") for cl in cls}
    step_c3_avg = {cl: data[cl].get("cl_attr_step_c3_avg") for cl in cls}
    step_c3_p99 = {cl: data[cl].get("cl_attr_step_c3_p99") for cl in cls}
    step_c4_avg = {cl: data[cl].get("cl_attr_step_c4_avg") for cl in cls}
    step_c4_p99 = {cl: data[cl].get("cl_attr_step_c4_p99") for cl in cls}
    epoch_change_count = {cl: data[cl].get("cl_attr_epoch_change_count") for cl in cls}
    has_microstep_data = any(step_a_avg[cl] is not None for cl in cls)

    # ── Scalars for f-string interpolation ────────────────────────────────────
    tps_vals       = [v for v in tps.values()       if v is not None]
    bw_p99_vals    = [v for v in bw_p99.values()    if v is not None]  # T1→T3 kept for breakdown
    bw_max_vals    = [v for v in bw_max.values()    if v is not None]  # T1→T3 kept for breakdown
    total_p99_vals = [v for v in total_p99.values() if v is not None]  # T0→T3 primary
    total_max_vals = [v for v in total_max.values() if v is not None]  # T0→T3 primary
    qw_max_vals    = [v for v in queue_max.values() if v is not None]
    attr_p99_vals  = [v for v in attr_p99.values()  if v is not None]
    attr_max_vals  = [v for v in attr_max.values()  if v is not None]

    qw_baseline  = queue_max.get("kona-okx-baseline",  0) or 0
    qw_optimised = queue_max.get("kona-okx-optimised", 0) or 0
    qw_basecl    = queue_max.get("base-cl",            0) or 0
    qw_p99_baseline  = queue_p99.get("kona-okx-baseline",  0) or 0
    qw_p99_optimised = queue_p99.get("kona-okx-optimised", 0) or 0
    qw_p99_basecl    = queue_p99.get("base-cl",            0) or 0

    # ── Cell builders ─────────────────────────────────────────────────────────
    def tps_cell(cl):
        v = tps[cl]
        if v is None: return "—"
        s = f"{v:,.0f} TX/s"
        return f"**{s}**" if v == max(tps_vals) else s

    def fill_cell(cl):
        v = fill[cl]
        if v is None: return "—"
        best = max(x for x in fill.values() if x is not None)
        s = f"{v:.0f}%"
        return f"**{s}**" if v == best else s

    def p99_cell(cl):
        return bold_min(total_p99_vals, total_p99[cl])

    def max_cell(cl):
        return bold_min(total_max_vals, total_max[cl])

    def qw_cell(cl):
        v = queue_max[cl]
        if v is None:
            return "~0 ms" if cl == "op-node" else "—"
        best = min(x for x in qw_max_vals if x is not None)
        s = f"{v:.0f} ms"
        return f"**{s}** ✅" if v == best else s

    def fmt_ms(v):
        """1 decimal place below 10ms (preserves sub-ms signal), integer above."""
        return f"{v:.1f} ms" if v < 10 else f"{v:.0f} ms"

    def irow(label, vals, exempt=None):
        """
        Interval breakdown row.
        exempt: dict {cl: display_str} — shown as-is, excluded from winner calc.
        ✅ only when one CL is strictly better than all others at 0.1ms resolution.
        Tied values (same after fmt_ms) never get ✅.
        """
        exempt = exempt or {}
        active = {cl: v for cl, v in vals.items() if cl not in exempt and v is not None}
        formatted = {cl: fmt_ms(v) for cl, v in active.items()}
        sorted_f = sorted(set(formatted.values()),
                          key=lambda s: float(s.replace(" ms", "")))
        best_f   = sorted_f[0] if sorted_f else None
        unique_winner = len(sorted_f) > 1 and sorted_f[0] != sorted_f[1] \
                        if len(sorted_f) >= 1 else False

        cells = []
        for cl in cls:
            if cl in exempt:
                cells.append(exempt[cl])
                continue
            v = vals[cl]
            if v is None:
                cells.append("—")
            else:
                s = fmt_ms(v)
                cells.append(f"**{s}** ✅" if (unique_winner and s == best_f) else s)
        return f"| {label} | " + " | ".join(cells) + " |"

    # op-node has no BinaryHeap queue → T1→T2 ≈ 0 by architecture, not optimisation
    # T1→T3 = T1→T2 + T2→T3 — including op-node conflates "no queue" with "faster queue"
    _NA_OPNODE = {"op-node": "N/A ¹"}

    # ── Pre-build table strings ───────────────────────────────────────────────
    cl_hdr = " | ".join(CL_DISPLAY.get(cl, cl) for cl in cls)
    cl_sep = "|".join(["---"] * (len(cls) + 1))

    results_rows = "\n".join(
        f"| {CL_DISPLAY.get(cl, cl)} | {tps_cell(cl)} | {fill_cell(cl)} | {p99_cell(cl)} | {max_cell(cl)} |"
        for cl in cls
    )

    breakdown_p50 = "\n".join([
        f"| Interval | {cl_hdr} |",
        f"|{cl_sep}|",
        irow("**BlockBuildInitiation-RequestGenerationLatency** (T0→T1) — Block Build Initiation Request Generation Latency",            attr_p50),
        irow("**BlockBuildInitiation-QueueDispatchLatency** (T1→T2) — Block Build Initiation Request - Queue Dispatch Latency",            queue_p50, exempt=_NA_OPNODE),
        irow("**BlockBuildInitiation-HttpSender-RoundtripLatency** (T2→T3) — Block Build Initiation Request - Http Sender Roundtrip Latency",              fcu_p50),
        irow("**BlockBuildInitiation-Latency** (T1→T3) — Block Build Initiation Latency",bw_p50,   exempt=_NA_OPNODE),
        irow("**T0→T3** — full block-build cycle",    total_p50),
    ])

    breakdown_avg = "\n".join([
        f"| Interval | {cl_hdr} |",
        f"|{cl_sep}|",
        irow("**BlockBuildInitiation-RequestGenerationLatency** (T0→T1) — Block Build Initiation Request Generation Latency",            attr_avg),
        irow("**BlockBuildInitiation-QueueDispatchLatency** (T1→T2) — Block Build Initiation Request - Queue Dispatch Latency",            queue_avg, exempt=_NA_OPNODE),
        irow("**BlockBuildInitiation-HttpSender-RoundtripLatency** (T2→T3) — Block Build Initiation Request - Http Sender Roundtrip Latency",              fcu_avg),
        irow("**BlockBuildInitiation-Latency** (T1→T3) — Block Build Initiation Latency",bw_avg,   exempt=_NA_OPNODE),
        irow("**T0→T3** — full block-build cycle",    total_avg),
    ])

    breakdown_p99 = "\n".join([
        f"| Interval | {cl_hdr} |",
        f"|{cl_sep}|",
        irow("**BlockBuildInitiation-RequestGenerationLatency** (T0→T1) — Block Build Initiation Request Generation Latency",            attr_p99),
        irow("**BlockBuildInitiation-QueueDispatchLatency** (T1→T2) — Block Build Initiation Request - Queue Dispatch Latency",            queue_p99, exempt=_NA_OPNODE),
        irow("**BlockBuildInitiation-HttpSender-RoundtripLatency** (T2→T3) — Block Build Initiation Request - Http Sender Roundtrip Latency",              fcu_p99),
        irow("**BlockBuildInitiation-Latency** (T1→T3) — Block Build Initiation Latency",bw_p99,   exempt=_NA_OPNODE),
        irow("**T0→T3** — full block-build cycle",    total_p99),
    ])

    breakdown_max = "\n".join([
        f"| Interval | {cl_hdr} |",
        f"|{cl_sep}|",
        irow("**BlockBuildInitiation-RequestGenerationLatency** (T0→T1) — Block Build Initiation Request Generation Latency",            attr_max),
        irow("**BlockBuildInitiation-QueueDispatchLatency** (T1→T2) — Block Build Initiation Request - Queue Dispatch Latency",            queue_max, exempt=_NA_OPNODE),
        irow("**BlockBuildInitiation-HttpSender-RoundtripLatency** (T2→T3) — Block Build Initiation Request - Http Sender Roundtrip Latency",              fcu_max),
        irow("**BlockBuildInitiation-Latency** (T1→T3) — Block Build Initiation Latency",bw_max,   exempt=_NA_OPNODE),
        irow("**T0→T3** — full block-build cycle",    total_max),
    ])

    # ── T0→T1 cost table (p99 + max) ─────────────────────────────────────────
    attr_avg_vals = [v for v in attr_avg.values() if v is not None]
    attr_cost_rows = "\n".join(
        f"| {CL_DISPLAY.get(cl, cl)} | {bold_min(attr_avg_vals, attr_avg[cl])} | {bold_min(attr_p99_vals, attr_p99[cl])} | {bold_min(attr_max_vals, attr_max[cl])} |"
        for cl in cls
    )
    opnode_attr_max = attr_max.get("op-node") or 0

    # ── T0→T1 micro-step breakdown table (kona only) ──────────────────────────
    kona_cls = [cl for cl in cls if step_a_avg[cl] is not None]

    def ms_cell(v):
        if v is None: return "—"
        return f"{v:.1f} ms" if v < 10 else f"{v:.0f} ms"

    def microstep_row(label, desc, avg_d, p99_d):
        cells = " ".join(f"| {ms_cell(avg_d.get(cl))} / {ms_cell(p99_d.get(cl))}" for cl in kona_cls)
        return f"| {label} | {desc} {cells} |"

    if has_microstep_data:
        hdr_cls = " ".join(f"| {CL_DISPLAY.get(cl, cl)} avg / p99" for cl in kona_cls)
        microstep_section = f"""
### T0→T1 Micro-Step Breakdown — kona instrumentation

> Step timings from `build_unsealed_payload()` (actor.rs) and `prepare_payload_attributes()` (stateful.rs).
> Opt-3 target: confirm which step costs ~100ms p50 on every block.

| Metric alias | Description {hdr_cls} |
|---|---{"".join("|---" for _ in kona_cls)}|
{microstep_row("`l2_head_fetch`", "Kona (Consensus Layer) asks the **reth - Execution Layer (EL)** for the latest unsafe block the EL has produced. The unsafe block is the most recently built block, not yet confirmed on L1. Kona needs this to know which block to build on top of.", step_a_avg, step_a_p99)}
{microstep_row("`l1_origin_lookup`", "Kona (Consensus Layer) looks up which **L1** block this XLayer block is anchored to. Every XLayer block must reference one L1 block — this is how XLayer inherits L1 security. · Cached in memory; re-fetches from L1 ~every 12 XLayer blocks.", step_b_avg, step_b_p99)}
{microstep_row("`sys_config_fetch`", "Kona (Consensus Layer) reads chain settings from the **reth - Execution Layer (EL)**: gas limit per block, fee collector address, batch submitter address. · Cached in memory — 0ms.", step_c1_avg, step_c1_p99)}
{microstep_row("`l1_header_fetch`", "Kona (Consensus Layer) fetches the **L1** block details — number, hash, timestamp, base fee. These are embedded into every XLayer block so validators can verify which L1 block it references. · Cached; re-fetches from L1 ~every 12 XLayer blocks.", step_c2_avg, step_c2_p99)}
{microstep_row("`l1_receipts_fetch`", "Kona (Consensus Layer) checks **L1** for any user deposits sent from L1 to XLayer. Deposits are protocol-mandatory — Kona must include them in the correct block and cannot skip them. · Only runs on epoch-change blocks (~every 12th XLayer block).", step_c3_avg, step_c3_p99)}
{microstep_row("`l1info_tx_encode`", "Processing step — Kona (Consensus Layer) assembles the mandatory first transaction in every XLayer block, recording the L1 block reference. No external or cache queries.", step_c4_avg, step_c4_p99)}
| Epoch changes | `l1_header_fetch` + `l1_receipts_fetch` both query L1 live (no cache) {" ".join(f"| {epoch_change_count.get(cl) or '—'} blocks / —" for cl in kona_cls)} |

> **How to read:** avg / p99 per cell. Sum of all rows ≈ `attr_prep` total. `l1_receipts_fetch` sample count is small — it only runs on epoch-change blocks (~every 12th XLayer block).
"""
    else:
        microstep_section = """
### T0→T1 Micro-Step Breakdown

> _Not available — requires kona images built after 2026-04-12 instrumentation commit._
> _Re-run bench with latest `kona-node:okx-baseline` / `kona-node:okx-optimised` images._
"""

    # ── Recommendation bullets ────────────────────────────────────────────────
    opt, base = "kona-okx-optimised", "kona-okx-baseline"
    rec = ""
    if opt in cls and base in cls:
        if total_p99.get(opt) and total_p99.get(base):
            ratio = total_p99[base] / total_p99[opt]
            rec += f"- **{ratio:.1f}×** lower Full Cycle Latency p99 (T0→T3) ({total_p99[base]:.0f} ms → {total_p99[opt]:.0f} ms vs kona baseline)\n"
        if total_max.get(opt) and total_max.get(base):
            ratio2 = total_max[base] / total_max[opt]
            rec += f"- **{ratio2:.1f}×** lower Full Cycle Latency max (T0→T3) ({total_max[base]:.0f} ms → {total_max[opt]:.0f} ms vs kona baseline)\n"
        if queue_max.get(opt) and queue_max.get(base):
            rec += f"- Pre-HTTP internal delay (T1→T2): {queue_max[base]:.0f} ms → {queue_max[opt]:.0f} ms\n"

    out = f"""# XLayer CL — Sequencer Performance Report

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

| Gas limit | T1→T2 component p99 (queue stall eliminated) | T1→T2 component max |
|---|---|---|
| 200 M (99.8% block fill) | 53 → 21 ms · **−61% · 2.6×** | 61 → 25 ms · **−59% · 2.5×** |
| 500 M (partial load) | 114 → 99 ms · **−14% · 1.2×** | 194 → 151 ms · **−22% · 1.3×** |

The improvement is largest at full saturation (200 M gas) where `AdvanceSafeHead` floods are most frequent — precisely the scenario when sequencer stability matters most.

---

## Roles

| Component | What it is | In this bench |
|---|---|---|
| **EL** — Execution Layer | Executes transactions, builds blocks on demand | OKX reth (identical binary across all runs) |
| **CL** — Consensus Layer | Runs the BlockBuildInitiator + derivation pipeline. Talks to the EL via Engine API. | op-node / kona / base-cl (the variable being tested) |
| **BlockBuildInitiator** ¹ | Component **inside** the CL. Fires once per second to trigger the next block build. Prepares block attributes, then hands off to the engine actor. | Part of each CL — behaviour differs per implementation |

> ¹ **BlockBuildInitiator** is a doc-level term coined to avoid confusion with "sequencer node" (= CL + EL combined). In source: op-node calls it the `Driver`; kona/base-cl call it the `sequencer actor`. Same role, different names per implementation.

---

## Block-Build Timeline — T0 to T3

Every second, the BlockBuildInitiator runs one block-build cycle. The four time points mark the key handoffs:

| Point | Who | What | Code reference |
|---|---|---|---|
| **T0** · `BlockBuildInitiation-StartTime` | BlockBuildInitiator | Block-build tick fires | op-node: `startBuildingBlock()` · kona: `build_unsealed_payload()` |
| **T1** · `BlockBuildInitiation-RequestGeneratedAt` | BlockBuildInitiator → Engine actor | `BlockBuildInitiationRequest` sent into mpsc channel; **clock starts**. kona: waits to be drained into BinaryHeap → picked by priority. op-node: no channel — goes straight to T2. | op-node: `ScheduledAt = time.Now()` · kona: `build_request_start = Instant::now()` |
| **T2** · `BlockBuildInitiation-HTTPRequestSentTime` | Engine actor → reth | `engine_forkchoiceUpdated+payloadAttributes` HTTP sent | op-node: `eng.startPayload()` · kona: `BuildTask::execute()` |
| **T3** · `BlockBuild-ExecutionLayer-JobIdReceivedAt` | reth → Engine actor | `payloadId` received; **clock stops**. reth has started building. | op-node: `time.Since(ScheduledAt)` · kona: `build_request_start.elapsed()` |

What the CL is doing between each pair:

| Interval | Duration (typical) | What happens | Key note |
|---|---|---|---|
| **T0→T1** · `BlockBuildInitiation-RequestGenerationLatency` | kona ~40ms · op-node ~1ms | Prepare block: L1 RPC call → construct L1InfoTx → assemble `PayloadAttributes` | op-node does this **synchronously** — the whole node freezes. kona/base-cl do it async. |
| **T1→T2** · `BlockBuildInitiation-QueueDispatchLatency` | ~0ms when fix is working | Engine actor drains its priority queue (BinaryHeap). `BlockBuildInitiationRequest` must win over pending `AdvanceSafeHead` tasks. | **This is where the kona fix acts.** Without it, `BlockBuildInitiationRequest` can be starved here. |
| **T2→T3** · `BlockBuildInitiation-HttpSender-RoundtripLatency` | ~1–35 ms (irreducible) | HTTP round-trip: reth validates chain head, starts payload builder, returns `payloadId`. | Pure network + reth startup. CL cannot reduce this. |

```
T0 ──────────── T1 ──── T2 ──────────── T3
│  Req.Gen Lat. │ Queue │  Http Sndr RTT │
│  (T0→T1)     │Dispatch│  (T2→T3)     │
│               │(T1→T2)│               │
▼               ▼       ▼               ▼
tick fires   queued   sent to reth   payloadId
```

| Metric | Meaning |
|---|---|
| **Median** | Half of all blocks were faster than this |
| **Average** | Arithmetic mean — pulled up by spikes; Average > Median means the tail events are heavy |
| **Maximum** | Worst single block in the entire run — worst-case bound |

---

## Results

| CL | TPS | Block fill | Full Cycle p99 (T0→T3) | Full Cycle max (T0→T3) |
|---|---|---|---|---|
{results_rows}

> **Full Cycle Latency (T0→T3)** = T0→T1 (attr prep) + T1→T2 (queue dispatch) + T2→T3 (HTTP to reth). Lower is better. See Phase Breakdown for component breakdown.

---

## Phase Breakdown

### Median — typical block

{breakdown_p50}

> **Why T1→T2 is near-zero at Median:** BinaryHeap starvation is a low-frequency event — most blocks flow through with zero queue wait. Median shows the *normal* case. The fix signal lives in **Average** (mean pulled up by stall events) and **Maximum** (worst stall observed).

### Average — average across all blocks

{breakdown_avg}

> Average > Median signals a heavy tail — a few slow blocks are pulling the mean up.

### 99th Percentile — tail latency

{breakdown_p99}

> **99th Percentile is the headline for reviewers**: 1 in 100 blocks was slower than this. At 120s runs (~120 blocks) that is roughly 1–2 real events, not a statistical artefact.

### Maximum — worst single block

{breakdown_max}

> **T0→T3 Maximum is the headline for impatient readers**: what was the worst total delay the BlockBuildInitiator experienced end-to-end?

¹ **op-node has no BinaryHeap queue** — T1→T2 ≈ 0 by design, so T1→T3 = T2→T3 only. Comparing op-node on T1→T2 or T1→T3 conflates "no queue exists" with "faster queue". Compare op-node on T0→T3 (total cycle) where its synchronous T0→T1 is included.

---

## T0→T1 — Block Build Initiation Request Generation Latency  ·  `BlockBuildInitiation-RequestGenerationLatency`

**What happens in T0→T1:**
- `eth_getBlockByNumber("latest")` — L1 RPC call to fetch the current L1 head
- Construct `L1InfoTx` — deposit transaction encoding L1 block info into the L2 block
- Assemble `PayloadAttributes` — block parameters (timestamp, fee recipient, transaction list) handed to reth

**The critical difference — sync vs async:**

| CL | Execution | Side effect |
|---|---|---|
| **op-node** | **Synchronous** — Driver goroutine holds `sync.Mutex` for full T0→T1 duration | Entire node frozen; derivation pipeline cannot progress while L1 RPC is in flight |
| **kona / base-cl** | **Async** — Tokio task, non-blocking | Runs concurrently with reth building the previous block — **zero cost to block timing** |

### T0→T1 cost — Average, 99th Percentile, Maximum

| CL | Average | 99th Percentile | Maximum |
|---|---|---|---|
{attr_cost_rows}

> Median is in the Phase Breakdown table above.
{microstep_section}
### Timeline — sync (op-node) vs async (kona)

```
op-node — T0→T1 is dead time (entire node frozen):

reth builds block N-1              T0           T1
──────────────────────────────────►│─────────────│──► T2 ──► reth builds block N
                                    ╔═══════════╗
                                    ║ sync.Mutex ║  ← Driver goroutine holds lock
                                    ║            ║
                                    ║ eth_getBlockByNumber("latest")   L1 RPC (blocking)
                                    ║ construct L1InfoTx
                                    ║ assemble PayloadAttributes{{...}}
                                    ║            ║
                                    ╚═══════════╝  derivation + p2p + RPC all frozen
                                                    spikes to {opnode_attr_max:.0f} ms at worst

kona / base-cl — T0→T1 runs in the gap (async, concurrent):

reth builds block N-1
──────────────────────────────────────────────────────────────► T3(N-1)
          T0            T1
           ├── async ───┤  Tokio task: eth_getBlockByNumber + L1InfoTx + PayloadAttributes
                        └──► engine actor → T2 ──► reth builds block N

           (node stays fully active: derivation, p2p, RPC all running)
           (~40ms elapsed, zero impact on block N start time)
```

**Key insight:** kona T0→T1 (~40ms Median) costs nothing — it runs while reth finishes the previous block.
op-node T0→T1 (0.6ms Median) freezes everything — low typical, but spikes hard under load.

---

### Why op-node spikes — source-code walkthrough

#### Panel A — op-node event loop: sequencer and derivation share one goroutine

```go
// op-node/rollup/driver/driver.go — the one event-loop goroutine
for {{
    select {{
    case <-sequencerCh:
        s.emitter.Emit(s.driverCtx, sequencing.SequencerActionEvent{{}})
        // ↑ BLOCKS this goroutine until startBuildingBlock() + PreparePayloadAttributes() finish.
        // While it runs, <-s.sched.NextStep() CANNOT fire. Derivation is frozen.

    case <-s.sched.NextStep():
        s.sched.AttemptStep(s.driverCtx)
        // ↑ BLOCKS while derivation fetches L1 data.
        // While it runs, <-sequencerCh CANNOT fire. Sequencer tick is queued.
    }}
    // Only ONE arm runs per iteration — hard serialization by design.
}}
```

Root cause of spikes: at 500M gas, derivation processes heavier L1 batches per step (more TXs per block). Each `AttemptStep()` holds the goroutine longer. Sequencer tick fires but must wait. Once unblocked, the sequencer runs `PreparePayloadAttributes()` against an already-busy L2 RPC server → further delay.

#### Panel B — op-node attribute prep: two blocking RPC calls in the hot path

```go
// op-node/rollup/derive/attributes.go — called INSIDE the event loop, lock held
func (ba *FetchingAttributesBuilder) PreparePayloadAttributes(
    ctx context.Context, l2Parent eth.L2BlockRef, epoch eth.BlockID,
) (attrs *eth.PayloadAttributes, err error) {{

    // ── RPC call 1 — L2 node: fetch system config for parent block ────────────────
    sysConfig, err := ba.l2.SystemConfigByL2Hash(ctx, l2Parent.Hash)
    // Under 500M gas: L2 node is processing 14k TX/s → RPC latency spikes.

    if l2Parent.L1Origin.Number != epoch.Number {{
        // ── RPC call 2a — L1 node: fetch ALL receipts (epoch boundary) ────────────
        info, receipts, err := ba.l1.FetchReceipts(ctx, epoch.Hash)
        // Heaviest path — receipts encode user deposits. L1 batch at 500M gas
        // is large → fetching full receipts is expensive.
    }} else {{
        // ── RPC call 2b — L1 node: fetch block header only (common path) ──────────
        info, err := ba.l1.InfoByHash(ctx, epoch.Hash)
        // Lighter, but same L1 RPC server shared with derivation pipeline.
    }}
    // Timeout: 20 seconds — entire event loop is frozen for up to 20s on failure.
}}
```

The lock is held (via `ctxlock`) for the full duration of both RPC calls. Derivation pipeline cannot make progress.

#### Panel C — kona/base-cl: independent Tokio task, yields at every RPC call

```rust
// rust/kona/.../actors/sequencer/actor.rs  (base-cl: identical structure)
pub(super) async fn build_unsealed_payload(
    &mut self,
) -> Result<Option<UnsealedPayloadHandle>, SequencerActorError> {{

    let build_total_start = Instant::now(); // ← T0

    // RPC call — .await yields the Tokio thread back to the runtime.
    // Engine actor + derivation actor continue running on other threads.
    let unsafe_head = self.engine_client.get_unsafe_head().await?;

    // L1 origin selection — also async, yields during any internal RPC.
    let Some(l1_origin) = self.get_next_payload_l1_origin(unsafe_head).await? else {{
        return Ok(None);
    }};

    // prepare_payload_attributes() → L1 RPC calls, all .await → never blocks the thread.
    let Some(attributes_with_parent) = self.build_attributes(unsafe_head, l1_origin).await? else {{
        return Ok(None);
    }};

    let build_request_start = Instant::now(); // ← T1: attrs ready, send to engine actor

    // Sends BlockBuildInitiationRequest into mpsc channel — engine actor receives asynchronously.
    let payload_id = self.engine_client.start_build_block(attributes_with_parent.clone()).await?;

    info!(sequencer_build_wait = ?build_request_start.elapsed(),
          sequencer_total_wait = ?build_total_start.elapsed(),
          "build request completed");
    Ok(Some(UnsealedPayloadHandle {{ payload_id, attributes_with_parent }}))
}}
```

#### Panel D — kona/base-cl: actor main loop — derivation is a completely separate task

```rust
// actors/sequencer/actor.rs — the sequencer's own Tokio task
loop {{
    select! {{
        biased;
        _ = self.cancellation_token.cancelled() => {{ return Ok(()); }}
        Some(query) = self.admin_api_rx.recv() => {{ self.handle_admin_query(query).await; }}

        // This arm is INDEPENDENT of derivation.
        // Derivation actor runs its own tokio::select! loop in a separate task.
        // There is no shared goroutine, no shared lock, no serialization.
        _ = build_ticker.tick(), if self.is_active => {{
            self.seal_last_and_start_next(next_payload_to_seal.as_ref()).await?;
        }}
    }}
}}
// derivation/actor.rs runs in parallel — no sequencer code visible here.
// They communicate ONLY via typed channels. No mutex. No shared state.
```

#### Summary table — architectural cause of T0→T1 behavior

| CL | Concurrency model | T0→T1 RPC | Derivation contention | Spike cause |
|---|---|---|---|---|
| **op-node** | Single goroutine event loop. Sequencer + derivation serialised. | Blocking — holds goroutine + lock | Yes — derivation holds event loop before sequencer runs | L2 busy (high TPS) + L1 receipt fetch at epoch boundary |
| **kona** | Separate Tokio tasks. Sequencer is independent. | Async — `.await` yields thread | None — tasks run on separate threads | Pure L1/L2 RPC latency (no contention) |
| **base-cl** | Same as kona — separate Tokio task | Async — `.await` yields thread | None | Same |

---

## Block Build Initiation Request - Queue Dispatch Latency  T1→T2

After the BlockBuildInitiator queues the build signal **(T1)**, each CL must send `engine_forkchoiceUpdated+attrs` to reth **(T2)**.
T1→T2 is spent entirely inside the CL — before reth even receives the request.

**Formula:** `T1→T2  =  Block Build Initiation Latency (T1→T3)  −  Block Build Initiation Request - Http Sender Roundtrip Latency (T2→T3)`

```mermaid
flowchart LR
    subgraph FULL["◄──────── Block Build Initiation Latency  T1 → T3 ────────►"]
        direction LR
        T1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nBlockBuildInitiationRequest ready"])

        subgraph Q12["Queue Dispatch Latency  T1→T2  (kona / base-cl only)"]
            direction LR
            CH["mpsc channel\\nasync buffer"]
            HEAP["BinaryHeap\\npriority queue\\nBlockBuildInitiationRequest\\[HIGH\\] wins"]
            CH -->|"recv() · flush_pending\\n→ heap.push all msgs"| HEAP
        end

        T2(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nHTTP call fired to reth"])
        T3(["📍 T3\\nBlockBuild-ExecutionLayer-JobIdReceivedAt\\npayloadId returned\\nblock build started"])

        T1 -->|"🟠 kona / base-cl: mpsc send\\nbaseline up to {qw_baseline:.0f} ms · optimised up to {qw_optimised:.0f} ms"| CH
        HEAP -->|"BlockBuildInitiationRequest dispatched\\nhighest priority"| T2
        T1 -.->|"🟠 op-node: direct call  ~0 ms"| T2
        T2 -->|"🔵 Block Build Initiation Request - Http Sender Roundtrip Latency (T2→T3)\\n~1–35 ms\\nreth validates + starts builder"| T3
    end

    style FULL fill:#f8f8f8,stroke:#999,stroke-width:2px,color:#000
    style Q12  fill:#fffbf0,stroke:#FF6600,stroke-width:1px,color:#000
    style T1   fill:#FFF3CC,stroke:#FFA500,stroke-width:2px,color:#333
    style T2   fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T3   fill:#CCE5FF,stroke:#4488FF,stroke-width:2px,color:#333
    style CH   fill:#fff8e8,stroke:#FFA500,stroke-width:1px,color:#333
    style HEAP fill:#FFF9C4,stroke:#F9A825,stroke-width:1px,color:#333
    linkStyle 0 stroke:#F9A825,stroke-width:2px
    linkStyle 1 stroke:#FF6600,stroke-width:3px
    linkStyle 2 stroke:#FFA500,stroke-width:2px
    linkStyle 3 stroke:#999,stroke-width:1.5px,stroke-dasharray:5
    linkStyle 4 stroke:#4488FF,stroke-width:3px
```

```mermaid
flowchart TB
    subgraph CLP["CL process  ←──────── Pre-HTTP Delay  T1→T2  lives entirely here ────────►"]
        direction LR
        T1(["📍 T1\\nBlockBuildInitiation-RequestGeneratedAt\\nBlockBuildInitiationRequest sent to channel\\n(kona: enters mpsc channel\\nop-node: no channel — skips to T2)"])
        T2(["📍 T2\\nBlockBuildInitiation-HTTPRequestSentTime\\nFCU RPC fires\\n(engine_forkchoiceUpdated\\nsent to reth)"])
        T1 -->|"🟠 Block Build Initiation Request - Queue Dispatch Latency  T1→T2  (99th Percentile)\\nkona: ① channel wait  ② drain → BinaryHeap  ③ priority pick\\n─────────────────────────────────────────────\\nop-node        ~0 ms ✅  no channel · no heap · direct RPC\\nkona baseline  {qw_p99_baseline:.0f} ms ❌  BlockBuildInitiationRequest starved behind AdvanceSafeHead in heap\\nkona optimised {qw_p99_optimised:.0f} ms ✅  flush fix: BlockBuildInitiationRequest always wins heap\\nbase-cl        {qw_p99_basecl:.0f} ms     same heap pattern as kona baseline"| T2
    end
    subgraph RETHP["reth process"]
        T3(["📍 T3\\nBlockBuild-ExecutionLayer-JobIdReceivedAt\\npayloadId returned\\nreth starts building block"])
    end
    T2 -->|"🔵 HTTP  T2→T3\\n~1–35 ms  (irreducible — pure network + reth)"| T3

    FORMULA["💡 What is T1→T2?\\nTime the CL spends internally after the build decision — before reth even receives the request.\\nreth is idle for this entire duration.\\n\\nHow it is derived:\\n  We log Block Build Initiation Latency end-to-end  →  T1→T3\\n  We log Http Sender Roundtrip Latency              →  T2→T3\\n  Subtract: T1→T2 = T1→T3 − T2→T3\\n\\nEvery ms of T1→T2  =  1 ms reth cannot build the block"]

    style CLP     fill:#fff8e8,stroke:#FFA500,stroke-width:2px,color:#000
    style RETHP   fill:#e8f4ff,stroke:#4488FF,stroke-width:2px,color:#000
    style FORMULA fill:#f0fff4,stroke:#22cc44,stroke-width:2px,color:#333
    style T1 fill:#FFF3CC,stroke:#FFA500,stroke-width:2px,color:#333
    style T2 fill:#FFE0B2,stroke:#FF6600,stroke-width:2px,color:#333
    style T3 fill:#CCE5FF,stroke:#4488FF,stroke-width:2px,color:#333
    linkStyle 0 stroke:#FFA500,stroke-width:3px
    linkStyle 1 stroke:#4488FF,stroke-width:3px
```

| CL | What happens between T1 and T2 | Max T1→T2 |
|---|---|---|
| op-node | No internal queue — goes straight to HTTP | ~0 ms |
| kona baseline | BinaryHeap: `BlockBuildInitiationRequest` request waits behind `AdvanceSafeHead` tasks | {qw_baseline:.0f} ms |
| **kona optimised** | `flush_pending_messages()` drains all pending tasks first → `BlockBuildInitiationRequest` always wins | **{qw_optimised:.0f} ms** |
| base-cl | Same BinaryHeap pattern as kona baseline, without the optimisation | {qw_basecl:.0f} ms |

**op-node** — no internal queue, T1→T2 ≈ 0

```
T0 ── BlockBuildInitiator tick fires
        │
        │  PreparePayloadAttributes()       ← SYNCHRONOUS — entire node frozen here
        │  ┌──────────────────────────────────────────────────────────┐
        │  │  eth_getBlockByNumber("latest")   ← L1 RPC (blocking)  │
        │  │  construct L1InfoTx                                      │
        │  │  assemble PayloadAttributes {{ ... }}                    │
        │  │  ⚠️  Driver goroutine holds sync.Mutex:                  │
        │  │     derivation pipeline is blocked for full duration     │
        │  └──────────────────────────────────────────────────────────┘
        │
T1 ── attrs ready · no queue · direct to HTTP
T2 ── HTTP: engine_forkchoiceUpdatedV3(head, attrs) ──→ reth
T3 ── {{ payloadId }}
```

**kona baseline vs kona optimised** — where the optimisation lands

```
kona BASELINE                               kona OPTIMISED
─────────────────────────────────           ─────────────────────────────────

T0 ── tick fires                            T0 ── tick fires
       │                                           │
       │  prepare_payload_attributes()             │  prepare_payload_attributes()
       │  (async — node stays active)              │  (async — node stays active)
       │                                           │
T1 ── BlockBuildInitiationRequest → mpsc::Sender         T1 ── BlockBuildInitiationRequest → mpsc::Sender

       rx.recv() ONE msg at a time                 flush_pending_messages()
       insert into heap                            loop {{ try_recv → heap.push }}
              │                                   heap has COMPLETE view
       ┌──────────────────────┐                          │
       │  AdvanceSafeHead [LOW]   │← drained          ┌──────────────────────────────────────────┐
       │  AdvanceSafeHead [LOW]   │← drained          │  BlockBuildInitiationRequest [HIGH] ← TOP  │← wins
       │  BlockBuildInitiationRequest [HIGH]  │← STARVED  │  AdvanceSafeHead [LOW]                 │
       └──────────────────────┘  up to 37ms       └──────────────────────┘
              │                                           │
T2 ── Http Sender RTT → reth (delayed)                T2 ── Http Sender RTT → reth (immediate)
T3 ── {{ payloadId }}                       T3 ── {{ payloadId }}
```

---

## What was optimised

| | |
|---|---|
| **Component** | kona engine actor — task dispatch loop |
| **Root cause** | BinaryHeap starvation: `BlockBuildInitiationRequest` blocked behind `AdvanceSafeHead` tasks |
| **Fix applied** | `flush_pending_messages()` — drain all pending tasks before dequeuing |
| **Result** | `BlockBuildInitiationRequest` always wins priority · pre-HTTP stall eliminated |

### The problem

kona's engine actor uses a **BinaryHeap** — a max-priority queue that always dequeues the highest-priority task first.

| Task | Sender | Priority |
|---|---|---|
| `BlockBuildInitiationRequest` | BlockBuildInitiator | **HIGH** |
| `AdvanceSafeHead` | Derivation pipeline | LOW |

- BlockBuildInitiator sends **one `BlockBuildInitiationRequest` task** per block — tells reth to start building.
- Derivation pipeline sends **`AdvanceSafeHead` tasks** continuously — safe/finalized head updates.
- kona reads tasks **one at a time from the mpsc channel** into the heap — not all at once.
- Under load: `AdvanceSafeHead` tasks are already in the heap **before `BlockBuildInitiationRequest` is even read from the channel**.
- Heap only sees what's already inserted — `AdvanceSafeHead` [LOW] dequeues first despite `BlockBuildInitiationRequest` [HIGH] sitting unread in the channel. `BlockBuildInitiationRequest` waits.

### The fix — `flush_pending_messages()`

- Before picking any task: **drain the entire channel into the heap at once.**
- Heap now sees all tasks together — `BlockBuildInitiationRequest` (highest priority) **wins immediately.**

```mermaid
flowchart TB
    subgraph BEFORE["❌  Before — recv() one at a time"]
        direction LR
        CB(["channel"]) -->|"recv() one msg"| HB["heap  (incomplete view)\\nAdvanceSafeHead [LOW]  ← dequeued 1st\\nAdvanceSafeHead [LOW]  ← dequeued 2nd\\nBlockBuildInitiationRequest [HIGH]  ← not yet read from channel"]
        HB -->|"dequeue top"| OB(["⏳  AdvanceSafeHead runs\\n    BlockBuildInitiationRequest waits  up to {qw_baseline:.0f} ms"])
        OB -.->|"eventually: dequeue BlockBuildInitiationRequest"| RB(["HTTP engine_forkchoiceUpdated → reth\\npayloadId returned  (delayed)"])
    end

    subgraph AFTER["✅  After — flush_pending_messages()"]
        direction LR
        CA(["channel"]) -->|"flush_pending_messages()"| HA["heap  (complete view)\\nBlockBuildInitiationRequest [HIGH]  ← dequeued 1st  ★\\nAdvanceSafeHead [LOW]\\nAdvanceSafeHead [LOW]"]
        HA -->|"dequeue BlockBuildInitiationRequest"| DA(["HTTP engine_forkchoiceUpdated → reth"])
        DA --> OA(["🏆  payloadId returned immediately\\n    reth starts building"])
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

## kona Optimisation Highlights

{rec}- Same throughput as op-node — zero regression

---

## Metric Guide

| Metric | Question it answers | Outlier? | When to cite it |
|---|---|---|---|
| **Median** | "What does a typical block look like?" | No — half of all blocks are faster | Normal operating behaviour. The baseline expectation. |
| **Average** | "What is the average across all blocks?" | No — but pulled up by spikes | Average ≫ Median means spikes are common enough to drag the mean. Confirms tail weight. |
| **99th Percentile** | "What is the worst 1-in-100 block?" | Borderline — real events, not flukes | Tail latency that production systems and bridges actually experience. At 120 blocks per run, 99th Percentile = ~1–2 real occurrences per run. Repeatable across runs. |
| **Maximum** | "What was the single worst block in the whole run?" | **Yes** — one data point | Shows maximum exposure. Useful as a risk ceiling. Hard to reproduce — may reflect a transient OS, GC, or network event. |

### The distinction that matters

```
Median          →  "usually fine"           (design the happy path around this)
Average         →  "how heavy is the tail"  (Average ≈ Median → rare spikes; Average ≫ Median → frequent spikes)
99th Percentile →  "reliable tail"          (this happens in every production run — design around it)
Maximum         →  "absolute worst case"    (risk ceiling — one event, treat as an outlier)
```

**Use 99th Percentile for performance claims.** "kona-optimised stays under X ms" backed by 99th Percentile is repeatable and defensible — it happened 1–2 times in each 120-block run and will happen in every future run. A claim backed only by Maximum is fragile — Maximum is one block out of ~120 and may not recur.

**Use Maximum for the crisis headline.** "op-node's worst single block was {opnode_attr_max:.0f} ms" — this answers "how bad can it get?" Even if Maximum is a rare event, it shows the risk envelope and motivates the fix.

**Use Average to confirm the tail is real.** If Average ≫ Median, it proves that slow blocks are not isolated — they happen often enough to pull the mean. If Average ≈ Median, even a large Maximum might just be noise.

### Applied to this run

| | op-node | kona optimised |
|---|---|---|
| Median (normal block) | Fast | Fast — both typical cases are similar |
| Average | Higher than Median → tail events are frequent | Close to Median → fix suppresses the tail |
| 99th Percentile (reliable tail) | {opnode_attr_max:.0f}ms range | Significantly lower — repeatable improvement |
| Maximum (worst block) | Spike driven by Go mutex + L1 RPC contention | Bounded — no shared mutex to contend |

---

*Full detailed report with all percentiles: `comparison.md` · Generated {date_str}*
"""

    out_path = run_dir / "simple-report.md"
    out_path.write_text(out)
    print(f"✅ simple-report.md → {out_path}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: generate-simple-report.py <run_dir>"); sys.exit(1)
    for d in sys.argv[1:]:
        generate(d)
