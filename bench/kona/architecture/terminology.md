# Benchmark Terminology Reference

Source of truth: `bench/runs/adv-erc20-40w-120s-500Mgas-20260412_154021/comparison.md`

---

## Naming rules (enforced in all reports)

| What to say | What NOT to say |
|---|---|
| Kona (Consensus Layer) | "kona", "the sequencer", "CL node" |
| reth - Execution Layer (EL) | "EL", "reth", "execution engine" |
| L1 | "Ethereum mainnet", "L1 chain" |
| XLayer devnet | "XLayer (our node)", "our node" |
| BlockBuildInitiationRequest | "FCU request", "build request", "payload request" |

---

## Timing points

| Point | Internal code name | Report name | What it marks |
|---|---|---|---|
| T0 | `build_total_start` | `BlockBuildInitiation-StartTime` | Kona (Consensus Layer) tick fires — decision to build |
| T1 | `build_request_start` | `BlockBuildInitiation-RequestGeneratedAt` | `PayloadAttributes` assembled, `BlockBuildInitiationRequest` ready to send |
| T2 | (derived) | `BlockBuildInitiation-HTTPRequestSentTime` | HTTP `engine_forkchoiceUpdatedV3` dispatched to reth - Execution Layer (EL) |
| T3 | (derived) | `BlockBuild-ExecutionLayer-JobIdReceivedAt` | `payloadId` received — reth - EL starts block construction |

---

## Metric aliases — Block Build Initiation (primary)

| Alias | Technical equivalent | Internal key | Interval | What it covers |
|---|---|---|---|---|
| **Block Build Initiation — End to End Latency** | `FCU+attrs` full cycle | `total_wait` | T0→T3 | Complete cost from decision to reth - EL acknowledgement |
| ↳ `BlockBuildInitiation-RequestGenerationLatency` | `PayloadAttributes` assembly | `attr_prep` | T0→T1 | L1 origin lookup + `SystemConfigByL2Hash` + deposits + `L1InfoTx` encoding |
| ↳ `BlockBuildInitiation-QueueDispatchLatency` | `mpsc` channel dispatch | `queue_wait` | T1→T2 | Time `BlockBuildInitiationRequest` waits in BinaryHeap before dispatch |
| ↳ `BlockBuildInitiation-HttpSender-RoundtripLatency` | `engine_forkchoiceUpdatedV3` HTTP | `fcu_attrs` | T2→T3 | HTTP round-trip to reth - EL only — irreducible |
| `Block Build Initiation Latency` (component) | Queue + HTTP combined | `build_wait` | T1→T3 | Queue dispatch + HTTP round-trip combined |

## Metric aliases — Seal & Derivation

| Alias | Technical equivalent | Internal key | What it covers |
|---|---|---|---|
| **`BlockSealRequest-With-Payload-Submit-To-EL-Latency`** | `engine_newPayloadV3` | `cl_new_pay` | CL submits sealed block to reth for validation and chain insertion |
| **`DerivationPipeline-HeadUpdate-Latency`** | `engine_forkchoiceUpdatedV3` no-attrs | `cl_fcu` | Safe/finalized head advancement after L1 batch derives |

> `attr_prep`, `queue_wait`, `total_wait`, `fcu_attrs`, `build_wait` are internal metric keys used in JSON output and scripts.
> **Never use these names in reports.** Use the Alias column instead.

---

## T0→T1 micro-steps (inside `BlockBuildInitiation-RequestGenerationLatency`)

| Internal key | Report name | Queries | Cached? | Notes |
|---|---|---|---|---|
| `attr_step_a` | `get_unsafe_head` | reth - Execution Layer (EL) | No — in-process local state | Latest unsafe block hash — used as `headBlockHash` in FCU |
| `attr_step_b` | `next_l1_origin` | L1 (cached) | Yes — L1WatcherActor pre-fetches | Which L1 block this XLayer block references |
| `attr_step_c1` | `SystemConfigByL2Hash` | reth - Execution Layer (EL) | **Yes — after Opt-2 cache** | Gas limit, fee collector, batch submitter address → `gasLimit` field in `PayloadAttributes` |
| `attr_step_c2` | `InfoByHash (L1 header)` | L1 | Yes — epoch cache | L1 block hash, number, timestamp, base fee → embedded in every XLayer block |
| `attr_step_c3` | `deposit receipts` | L1 | Epoch-only | User deposits from L1 → XLayer. Protocol-mandatory. Only on epoch-change blocks (~every 12th block) |
| `attr_step_c4` | `L1InfoTx encode` | None | N/A — CPU only | Assembles mandatory first transaction in every XLayer block. No external queries. |

> Internal keys `attr_step_a` through `attr_step_c4` appear in JSON output and kona log lines.
> Use the Report name column in all reports.

---

## Engine task priorities (BinaryHeap — kona / base-cl only)

| Priority | Task | Source | Engine API call | Active mode |
|---|---|---|---|---|
| 1 — highest | `Build` (`BlockBuildInitiationRequest`) | Kona (Consensus Layer) — SequencerActor | `engine_forkchoiceUpdatedV3` + `payloadAttributes` | **Sequencer only** |
| 2 | `Seal` | Kona (Consensus Layer) — SequencerActor | `engine_getPayloadV3` → `engine_newPayloadV3` → `engine_forkchoiceUpdatedV3` | **Sequencer only** |
| 3 | `Insert` | NetworkActor | `engine_newPayloadV3` → `engine_forkchoiceUpdatedV3` | **Non-sequencer only** (follower/verifier) |
| 4 | `Consolidate` (`AdvanceSafeHead`) | DerivationActor | `engine_forkchoiceUpdatedV3` no-attrs | All nodes |
| 5 — lowest | `Finalize` | DerivationActor | `engine_forkchoiceUpdatedV3` no-attrs | All nodes |

> All five task types exist in the same `EngineTask` enum and BinaryHeap implementation.
> On the active sequencer, Build + Seal fire but Insert is dormant (no P2P blocks to import).
> On non-sequencer nodes, Insert fires but Build + Seal are dormant (SequencerActor tick never fires).
> Consolidate and Finalize fire on **all** nodes — they advance safeHead / finalizedHead from L1 derivation.

---

## Key optimisations

| Name | What it fixes | Metric directly improved | Merged? |
|---|---|---|---|
| **Engine priority fix** (Opt-1) | BinaryHeap received one message at a time → `Build` could be starved behind `Consolidate`. Fix: `flush_pending_messages()` drains all pending messages before `heap.pop()` so `Build[HIGH]` always wins. | `BlockBuildInitiation-QueueDispatchLatency` (T1→T2) p99 | ✅ Yes — in `kona-node:okx-optimised` |
| **`SystemConfigByL2Hash` cache** (Opt-2) | `SystemConfigByL2Hash` called reth - Execution Layer (EL) via RPC on every block (~94ms at 500M load). Fix: cache result in memory, invalidate on system-config log events. | `BlockBuildInitiation-RequestGenerationLatency` (T0→T1) p50: 94ms → 2ms | ✅ Yes — in `kona-node:okx-optimised` |

---

## Stat guide

| Stat | What it tells you | At ~120 blocks / 120s run |
|---|---|---|
| **p50 (median)** | Typical block — half are faster, half slower | The normal operating case |
| **avg (mean)** | Arithmetic mean — if avg >> p50, tail events are frequent | Confirms tail weight |
| **p99 (99th percentile)** | 1-in-100 worst — repeatable, not a fluke | ~1–2 real events per run |
| **max** | Single worst block across the entire run | Risk ceiling — treat as outlier |
