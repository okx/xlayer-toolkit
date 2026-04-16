# op-node vs kona — Comparison

> Presentation-ready summary. Full analysis: `bench/op-node/op-node-deep-dive.md` §12.
> Benchmark source: `bench/runs/adv-erc20-40w-120s-500Mgas-20260414_074944/` (Run 3)

---

## Architecture

Fundamentally different concurrency models:

```
op-node (Go)                           kona (Rust)
┌────────────────────────┐             ┌────────────────────────┐
│ eventLoop goroutine    │             │ SequencerActor         │
│ ├─ Sequencer           │             │ DerivationActor        │
│ ├─ DerivationPipeline  │  serialized │ EngineActor            │  concurrent
│ └─ EngineController    │             │ L1WatcherActor         │
│     (gosync.RWMutex)   │             │ NetworkActor           │
└────────────────────────┘             └────────────────────────┘
  1 goroutine does ALL                   5 independent Tokio tasks
```

| Dimension | op-node | kona |
|---|---|---|
| **Language** | Go | Rust + Tokio async |
| **Concurrency** | Single goroutine event loop — sequencer and derivation serialized | Independent actors — sequencer and derivation concurrent |
| **`PayloadAttributes` assembly** | Synchronous — blocks event loop for entire duration | Async — yields to Tokio scheduler, loop not blocked |
| **Engine dispatch** | Direct synchronous call | mpsc → BinaryHeap → async HTTP |
| **Priority enforcement** | None — FIFO event drain | BinaryHeap: Build > Seal > Insert > Consolidate > Finalize |
| **Why `RequestGenerationLatency` is high** | **Goroutine contention** — derivation holds the loop, sequencer queues behind (~221ms) | `SystemConfigByL2Hash` RPC (~102ms baseline, ~1.6ms with Opt-2 cache) |

---

## Benchmark Numbers (Run 3 — 500M gas)

| Metric | kona optimised | kona baseline | op-node |
|---|---|---|---|
| **Block Build Initiation — End to End Latency p50** | **6.5 ms** | 107.2 ms | 222.6 ms |
| **Block Build Initiation — End to End Latency p99** | **142.9 ms** | 265.8 ms | 331.3 ms |
| `BlockBuildInitiation-RequestGenerationLatency` p50 | **1.6 ms** | 102.1 ms | 221.6 ms |
| `BlockBuildInitiation-HttpSender-RoundtripLatency` p50 | 3.7 ms | 1.7 ms | **1.5 ms** |
| `BlockSealRequest-With-Payload-Submit-To-EL-Latency` p50 | 65.9 ms | 63.6 ms | **47.9 ms** |
| TPS | **13,860** | 13,388 | 12,641 |
| Block fill | **97.1%** | 93.8% | 88.6% |

---

## Key Insights

1. **op-node's latency bottleneck is architectural.** The 221.6ms `BlockBuildInitiation-RequestGenerationLatency` is NOT slow RPCs (~4ms) — it's goroutine wait time. Derivation holds the event loop; the sequencer tick queues behind it. kona eliminates this by running derivation in a separate actor.

2. **kona-baseline already 2× faster than op-node** (107ms vs 223ms p50) — purely from the actor model enabling concurrent sequencer and derivation.

3. **kona-optimised is 34× faster than op-node** (6.5ms vs 222.6ms p50) — Opt-2 eliminates the remaining `SystemConfigByL2Hash` RPC cost on top of the architectural advantage.

4. **op-node wins on per-call efficiency.** Lower `BlockBuildInitiation-HttpSender-RoundtripLatency` (1.5ms vs 3.7ms) and `BlockSealRequest-With-Payload-Submit-To-EL-Latency` (47.9ms vs 65.9ms) — its simpler model has less scheduling overhead per individual engine call. But these savings are dwarfed by the 200ms+ `BlockBuildInitiation-RequestGenerationLatency` penalty from the serialized goroutine.

---

*Source data: `bench/runs/adv-erc20-40w-120s-500Mgas-20260414_074944/`*
*Reference: `bench/op-node/op-node-deep-dive.md` · `bench/kona/architecture/kona-architecture.md`*
