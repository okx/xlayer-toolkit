# base-cl vs kona — Comparison

> Presentation-ready summary. Full analysis: `bench/base/base-cl-deep-dive.md`.
> Benchmark source: `bench/runs/adv-erc20-40w-120s-500Mgas-20260414_074944/` (Run 3)

---

## Architecture

Both are Rust/Tokio actor-model CLs with BinaryHeap engine scheduling. Core differences:

```
base-cl                                kona
┌────────────────────────┐             ┌────────────────────────┐
│ SequencerActor         │             │ SequencerActor         │
│ DerivationActor (FSM)  │ ← unique    │ DerivationActor (free) │
│ EngineActor            │             │ EngineActor            │
│ ├─ EngineProcessor     │ ← unique    │ └─ (single processor)  │
│ └─ RpcProcessor        │ ← unique    │                        │
│ L1WatcherActor         │             │ L1WatcherActor         │
└────────────────────────┘             └────────────────────────┘
```

| Dimension | base-cl | kona |
|---|---|---|
| **Derivation model** | 6-state FSM (`DerivationStateMachine`) — max 1 Consolidate in-flight | Free-running loop — unbounded Consolidate bursts |
| **EngineActor** | Split: EngineProcessor (state) + RpcProcessor (queries) | Single processor for all requests |
| **Channels** | Bounded MPSC (1024) | Unbounded MPSC |
| **`SystemConfigByL2Hash` cache** | No — live RPC every block (~95ms) | **Yes** — Opt-2 in kona-optimised |

---

## Benchmark Numbers (Run 3 — 500M gas)

| Metric | kona optimised | kona baseline | base-cl |
|---|---|---|---|
| **Block Build Initiation — End to End Latency p50** | **6.5 ms** | 107.2 ms | 101.3 ms |
| **Block Build Initiation — End to End Latency p99** | **142.9 ms** | 265.8 ms | 258.8 ms |
| `BlockBuildInitiation-RequestGenerationLatency` p50 | **1.6 ms** | 102.1 ms | 98.9 ms |
| `BlockBuildInitiation-QueueDispatchLatency` p99 | 139.3 ms | 87.0 ms | **28.5 ms** |
| `BlockBuildInitiation-HttpSender-RoundtripLatency` p99 | 44.1 ms | 55.6 ms | **23.6 ms** |
| TPS | **13,860** | 13,388 | 11,758 |
| Block fill | **97.1%** | 93.8% | 82.4% |

---

## Key Insights

1. **Without Opt-2, they're near-identical.** kona-baseline (107ms p50) ≈ base-cl (101ms p50) — both pay ~95ms per block for `SystemConfigByL2Hash`.

2. **base-cl wins on tail latency.** Its `DerivationStateMachine` caps BinaryHeap depth at 1 Consolidate, giving 28.5ms `BlockBuildInitiation-QueueDispatchLatency` p99 vs kona's 139ms. The FSM also keeps safe lag bounded, yielding better `BlockBuildInitiation-HttpSender-RoundtripLatency` tail (23.6ms vs 44.1ms).

3. **kona-optimised wins overall** because Opt-2 eliminates the dominant cost. The 6.5ms p50 is 15× faster than base-cl.

4. **Ideal CL = Opt-2 + FSM.** base-cl with `SystemConfigByL2Hash` cache would project to ~5-8ms p50 with lower p99 tail than kona-optimised, thanks to the FSM's hard scheduling bounds.

---

*Source data: `bench/runs/adv-erc20-40w-120s-500Mgas-20260414_074944/`*
*Reference: `bench/base/base-cl-deep-dive.md` · `bench/kona/architecture/kona-architecture.md`*
