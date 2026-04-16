# How CL Latency Drives TPS — The Mechanics

**Audience:** Developer unfamiliar with the OP Stack internals.
**Purpose:** Explain why shaving milliseconds off the consensus layer (CL) translates directly into more transactions per second — without touching the execution layer (EL) at all.

---

## Plain English — Read This First

### What is block fill rate?

Every block has a gas limit — think of it as the **size of a truck**. Every transaction takes up space in that truck (~35k gas each). Block fill rate is simply:

> **How full was the truck when it left?**

99.6% fill = the truck was almost completely packed. 88.9% fill = it left with 11% of space wasted.

### Why does it matter for TPS?

More fill = more transactions per block = more TPS. At 500M gas limit:

```
100% fill = 500M ÷ gas_per_tx = max TPS
 88% fill =                   = lower TPS
```

The ceiling is fixed by the gas limit. The only question is: **how close to the ceiling can we get?**

### How much gas does one ERC20 transfer actually use?

It is not a fixed constant — it depends on EVM storage access patterns (cold vs warm slots). But it is approximately **~35,000 gas** for a standard ERC20 transfer:

| Component | Gas | Why |
|---|---|---|
| Base tx cost | 21,000 | Fixed by protocol (EIP-2028) |
| Contract execution | ~14,000 | 2× SLOAD (read balances) + 2× SSTORE (write balances) + event log |
| **Total** | **~35,000** | Varies ±2k depending on cold/warm storage state |

Rather than trusting this estimate, the bench data itself validates it. Back-calculating from the optimised run (99.6% fill, 14,218 TPS, 500M gas limit, 1s blocks):

```
gas_used per block = 500,000,000 × 0.996  = 498,000,000
gas per tx         = 498,000,000 ÷ 14,218 = ~35,025 gas  ✓
```

The bench data confirms ~35k gas per ERC20 transfer. The gas limit per tx in the adventure sender is set to 100k (a safe ceiling), but actual execution consumes ~35k.

### Who loads the truck?

```
                   ┌─────────────────────────────────────────────────────────┐
                   │                   Every 1 second                        │
                   └─────────────────────────────────────────────────────────┘
                                            │
          ┌─────────────────────────────────▼──────────────────────────────────┐
          │  kona (CL) — the DISPATCHER                                        │
          │                                                                     │
          │  1. Decides it's time to build a new block                         │
          │  2. Prepares instructions (block attributes)                        │
          │  3. Sends "start loading" signal to reth  ──────────────────────►  │
          └─────────────────────────────────────────────────────────────────── │
                                                                               │
          ┌────────────────────────────────────────────────────────────────────▼
          │  reth (EL) — the LOADER                                            │
          │                                                                     │
          │  ← receives "start loading" signal                                  │
          │  picks tx from mempool → executes → adds to block                  │
          │  picks tx from mempool → executes → adds to block                  │
          │  picks tx from mempool → executes → adds to block  (loop...)       │
          │  ← receives "stop, seal it" signal from kona                       │
          │  returns sealed block                                               │
          └─────────────────────────────────────────────────────────────────────
```

**reth loads as many transactions as it can in the time between "start" and "stop".**

### What was the problem?

kona was slow to send the "start loading" signal — spending 95ms per block on an unnecessary RPC call to fetch system config (which never changes block-to-block). Those 95ms were wasted before reth even began loading.

```
BEFORE optimisation (95ms wasted on RPC):

 slot start                                           slot end (1000ms)
 │                                                         │
 ├──── kona overhead 103ms ────┤◄──── reth loads ─────────►│
 │                              │                          │
 │  ← 95ms: RPC to fetch        │                          │
 │    system config  (wasted)   │                          │
 │                              │                          │
 T0                            T3                       T_seal
                         reth starts                  reth stops
                         at 103ms                     at ~1000ms
                         fill window = ~897ms
```

```
AFTER optimisation (system config cached, 0ms):

 slot start                                           slot end (1000ms)
 │                                                         │
 ├── kona 6ms ─┤◄────────── reth loads ───────────────────►│
 │              │                                          │
 T0            T3                                       T_seal
         reth starts                                  reth stops
         at 6ms                                       at ~1000ms
         fill window = ~994ms
```

reth gained **97ms more per block** to load transactions. That translated directly to:

```
fill rate:  88.9%  →  99.6%   (+10.7 percentage points)
TPS:       12,689  →  14,218  (+1,529 transactions/second)
```

### How is fill rate measured?

After the test, the script reads every block that was produced during the measurement window from the chain and computes:

```
fill % per block = gasUsed ÷ gasLimit × 100
```

Then takes the average across all blocks. It is reading on-chain data — `gasUsed` is in every block header. No estimation, no inference. The chain itself is the source of truth.

---

## Who Does What

Two processes run the sequencer. They talk over the Engine API (HTTP).

```
┌─────────────────────────────────┐        Engine API (HTTP)        ┌──────────────────────────────────┐
│  Consensus Layer (CL)           │ ──────────────────────────────► │  Execution Layer (EL) — reth     │
│  kona / op-node                 │                                  │                                  │
│                                 │                                  │  • Holds the mempool             │
│  • Decides WHEN to build        │  engine_forkchoiceUpdated        │  • Builds blocks (fills txs)     │
│  • Prepares block attributes    │  + payload attributes   ──────► │  • Starts filling on FCU signal  │
│  • Sends FCU + attrs to reth    │                                  │  • Stops when getPayload called  │
│  • Tells reth to stop (seal)    │  engine_getPayload      ──────► │  • Returns sealed block          │
│                                 │ ◄──────────────────────────────  │                                  │
└─────────────────────────────────┘                                  └──────────────────────────────────┘
```

**The CL is the director. reth is the factory floor.**

The CL does not fill transactions. reth does. But reth cannot start until the CL sends the signal. Everything the CL does before sending that signal is overhead that steals time from reth's fill window.

---

## The Slot Lifecycle — One Block, One Second

XLayer runs 1-second blocks. Every second, this sequence repeats:

```
T=0ms                                              T≈1000ms
│                                                       │
▼                                                       ▼
[slot N starts]                               [slot N+1 starts]
│                                                       │
│  CL overhead (T0→T3)     │◄── reth fill window ─────►│
│                           │                           │
T0        T1        T2     T3                      T_seal
│         │         │      │                           │
│         │         │      └── reth filling txs ───────┤
│         │         │                                  │
│         │         └── FCU HTTP in-flight ────────────┤
│         │                                            │
│         └── attrs in engine queue ──────────────────┤
│                                                      │
└── CL building attributes ───────────────────────────┘
```

| Point | Name | What happens | Code location |
|---|---|---|---|
| **T0** | Sequencer tick | CL decides to build next block | `build_unsealed_payload()` top |
| **T1** | Attrs ready | CL sends `Build{attrs}` to engine actor channel | After `build_attributes()` returns |
| **T2** | FCU fired | Engine actor sends `engine_forkchoiceUpdated` + attrs to reth via HTTP | Inside `BuildTask::execute()` |
| **T3** | payloadId back | reth acknowledges — **reth starts filling transactions NOW** | `start_build()` returns |
| **T_seal** | Block sealed | CL calls `engine_getPayload` — reth stops filling | `SealTask::seal_payload()` |

**reth fills transactions between T3 and T_seal.** The CL controls both endpoints.

---

## The Code

### Step 1 — CL builds attributes (T0 → T1)

`actor.rs` — `build_unsealed_payload()`:

```rust
let build_total_start = Instant::now();   // T0: sequencer tick

// step A: get current unsafe head (watch channel — NOT an EL RPC)
let unsafe_head = self.engine_client.get_unsafe_head().await?;

// step B: determine L1 origin for this block (cached for 11/12 blocks)
let l1_origin = self.get_next_payload_l1_origin(unsafe_head).await?;

// step C: build payload attributes (THIS was the bottleneck before Opt-2)
//   step C1: system_config_by_number() — was 95ms/block, now 0ms (cached)
//   step C2: l1_header_fetch           — epoch-change only
//   step C3: l1_receipts_fetch         — epoch-change only
//   step C4: encode L1 info tx         — pure computation, ~0ms
let attributes_with_parent = self.build_attributes(unsafe_head, l1_origin).await?;

let build_request_start = Instant::now();   // T1: attrs ready, about to send

// Send Build{attrs} into engine actor channel
let payload_id = self.engine_client.start_build_block(attributes_with_parent).await?;

let build_elapsed = build_request_start.elapsed();   // T1→T3
let total_elapsed = build_total_start.elapsed();     // T0→T3
info!(sequencer_build_wait = ?build_elapsed, sequencer_total_wait = ?total_elapsed, "build request completed");
```

### Step 2 — Engine actor fires FCU to reth (T2 → T3)

`engine/task_queue/tasks/build/task.rs` — `BuildTask::execute()`:

```rust
async fn execute(&self, state: &mut EngineState) -> Result<PayloadId, BuildTaskError> {
    // T2: send engine_forkchoiceUpdatedV3 with payload attributes
    let fcu_start_time = Instant::now();
    let payload_id = self.start_build(state, &self.engine, self.attributes.clone()).await?;
    let fcu_duration = fcu_start_time.elapsed();
    // T3: reth returned payloadId — reth is now filling the block

    info!(target: "engine_builder", fcu_duration = ?fcu_duration, "block build started");
    Ok(payload_id)
}
```

`start_build()` calls `engine_forkchoiceUpdatedV3(forkchoice, Some(attrs))` over HTTP and returns the `payloadId`. At this moment, reth starts its payload builder loop.

### Step 3 — reth fills transactions (T3 → T_seal)

This happens **entirely inside reth**. The CL is not involved. reth's payload builder:
1. Takes transactions from the pending mempool in fee-priority order
2. Executes each transaction against the EVM state
3. Keeps filling until `engine_getPayload` arrives

### Step 4 — CL seals the block (T_seal)

`engine/task_queue/tasks/seal/task.rs` — `SealTask::seal_payload()`:

```rust
async fn seal_payload(&self, cfg: &RollupConfig, engine: &EngineClient_, payload_id: PayloadId, ...)
    -> Result<OpExecutionPayloadEnvelope, SealTaskError>
{
    let get_payload_version = EngineGetPayloadVersion::from_cfg(cfg, payload_timestamp);
    // T_seal: engine_getPayload — reth STOPS filling and returns the block
    let payload_envelope = match get_payload_version {
        EngineGetPayloadVersion::V3 => engine.get_payload_v3(payload_id).await?,
        EngineGetPayloadVersion::V4 => engine.get_payload_v4(payload_id).await?,
        // ...
    };
    Ok(payload_envelope)
}
```

`engine_getPayload` is called at approximately T=1000ms — the start of the next slot. This is determined by the CL's timer, not by a wall-clock interrupt.

---

## Block Fill Rate — What It Is and How It Works

**Block fill rate** = `gas_used ÷ gas_limit` for a given block.

At 500M gas limit with ERC20 transfers (~35k gas each):

```
gas_limit  = 500,000,000 gas
gas per tx = ~35,000 gas
max tx/block = 500M ÷ 35k = ~14,286 transactions
```

100% fill = 14,286 TX in one block = 14,286 TPS at 1s blocks. This is the ceiling.

### How block fill rate is measured

The script runs in two phases before the block scan ever happens:

```
Phase 1 — Warmup (30s):  adventure senders run, mempool fills to saturation
                          START_BN NOT captured yet — warmup blocks excluded

Phase 2 — Measurement (120s):
  START_BN = current chain head  ← captured via `cast bn` right at measurement start
  ... adventure keeps sending for DURATION seconds ...
  end_bn   = START_BN + elapsed  ← 1s blocks → elapsed seconds = elapsed blocks
             capped at actual chain head (chain may be 1-2 blocks behind)
```

Only after the measurement window ends does the block scan run:

```python
# bench/scripts/bench-adventure.sh
start_bn = int(START_BN)               # block at measurement start (post-warmup)
end_bn   = start_bn + elapsed          # block at measurement end
end_bn   = min(end_bn, chain_head)     # cap at actual tip

for bn in range(start_bn + 1, end_bn + 1):   # every block created during the window
    blk    = eth_getBlockByNumber(bn)
    g_used = int(blk["gasUsed"],  16)
    g_lim  = int(blk["gasLimit"], 16)
    fill_pct = round(g_used / g_lim * 100, 1)
    per_block_fill.append(fill_pct)

# percentiles and avg over all scanned blocks
fill_p10  = pct(per_block_fill, 10)    # saturated flag: fill_p10 > 95%
fill_p50  = pct(per_block_fill, 50)
fill_p90  = pct(per_block_fill, 90)
avg_fill  = mean(per_block_fill)       # → "block_fill" in JSON
```

The trigger is time, not block events. The script waits `DURATION` seconds, then scans the blocks that were **created during that window** by querying `gasUsed` and `gasLimit` from each block header on-chain. No CL involvement — pure chain data.

### How reth fills a block

reth's payload builder runs a tight loop from the moment it receives `engine_forkchoiceUpdated` + attrs:

```
loop:
  1. pick next tx from pending mempool (highest fee first)
  2. execute tx against EVM state
  3. accumulate gas: gas_used += tx.gas
  4. if gas_used >= gas_limit → stop (block full)
  5. if engine_getPayload arrives  → stop (CL sealed the block)
  6. else → go to 1
```

**The loop stops at whichever condition fires first: gas full OR CL calls getPayload.**

At 500M gas with a deep mempool (40 workers, 50k accounts), the mempool is never empty — condition 4 (gas full) is the intended stop. But if the CL sends `engine_getPayload` early — before reth has filled all 14,286 slots — the block seals with whatever gas was consumed up to that point.

### Why CL latency directly sets the fill rate

```
T3 (FCU arrives at reth)      T_seal (engine_getPayload arrives)
│                                        │
│◄──────── reth fill window ────────────►│
│                                        │
│  loop iter 1 → tx #1                  │
│  loop iter 2 → tx #2                  │
│  ...                                  │
│  loop iter N → tx #N                  │
│                                        │
└── N transactions in the block ─────────┘

fill_rate = N × 35k gas ÷ 500M gas = N ÷ 14,286
```

T_seal is approximately fixed (next slot boundary, ~1000ms after slot start). T3 is what CL latency controls. A later T3 means fewer loop iterations before T_seal arrives — lower fill rate.

**Baseline (T0→T3 = 103ms p50):** reth starts at T3 ≈ 103ms, fills until ~1000ms → ~897ms of filling.

**Optimised (T0→T3 = 6ms p50):** reth starts at T3 ≈ 6ms, fills until ~1000ms → ~994ms of filling.

The delta is 97ms. That is 97ms more loop iterations, which at ~15,800 TX/s effective execution rate yields ~1,529 more transactions per second.

---

## Why Earlier FCU = More Transactions

The fill window is:

```
fill_window = T_seal − T3
```

T_seal is approximately fixed (the CL fires it at the next slot boundary, ~1000ms). T3 is what we optimise. Every millisecond we reduce T3 adds a millisecond to the fill window.

### Before and after the optimisations

| | Baseline | Optimised | Delta |
|---|---|---|---|
| T0→T3 p50 (`sequencer_total_wait`) | **103ms** | **6ms** | **97ms** |
| reth fill window per block | ~897ms | ~994ms | +97ms |
| Block fill avg | 88.9% | **99.6%** | +10.7pp |
| TPS | 12,689 | **14,218** | **+1,529** |

### The math

reth gained **97ms per block**. How does that turn into 1,529 more TX/s?

```
implied reth execution rate = observed TX gain ÷ time gained
                            = 1,529 TX/s ÷ (97ms ÷ 1000ms)
                            = 15,758 TX/s   ← reth's effective ERC20 execution speed

theoretical gain = 97ms × 14,286 TX/s ÷ 1000ms = ~1,386 TX/s
actual gain                                      = +1,529 TX/s  ✓ (close match)
```

The ~10% overshoot (1,529 vs 1,386) is consistent: as blocks fill closer to 100%, reth operates closer to its peak throughput. At 88.9% fill there is some padding overhead; at 99.6% fill that overhead disappears.

### Three conditions that must hold (all verified)

| Condition | Why needed | Evidence |
|---|---|---|
| **Deep mempool** | reth must always have txs ready to fill | Block fill p50 = **100%** — mempool never ran dry |
| **Fixed seal timing** | T_seal must be approximately constant across runs | CL timer fires at slot boundary — same code path for all CLs |
| **Constant reth execution rate** | reth binary and config unchanged | Zero code changes to reth; same binary serves all 5 CLs |

---

## Causal Chain Per Optimisation

### Opt-2 — SystemConfig cache (the dominant gain)

```
Before: system_config_by_number() → eth_getBlockByNumber RPC → reth → ~95ms per block

After:  system_config_by_number() → last_system_config (in-memory) → ~0ms per block

step_c1 baseline: p50 = 95ms, p99 = 224ms
step_c1 optimised: p50 = 0ms, p99 = 0ms   ← eliminated entirely
     │
     └─► T0→T3 shrinks 103ms → 6ms
             │
             └─► reth gets +97ms per block to drain the mempool
                     │
                     └─► block fill: 88.9% → 99.6%
                             │
                             └─► TPS: 12,689 → 14,218  (+1,529 TX/s)
```

### Opt-1 — BinaryHeap drain fix (tail latency elimination)

```
Before: Build{attrs} waits behind burst of Consolidate tasks in engine queue
        queue_wait p99: 141ms  (1 in 100 blocks stalled for 141ms)

After:  try_recv() loop flushes all pending channel messages into BinaryHeap before drain()
        Build priority fires correctly — Build always beats Consolidate
        queue_wait p99: 0.6ms

     │
     └─► FCU+attrs fires on time every block — no random tail delays
             │
             └─► Block fill variance eliminated — consistent 99.6% saturation
                     │
                     └─► TPS variance eliminated — no bimodal oscillation
```

Opt-1 and Opt-2 address different intervals. Opt-2 reduces the p50 (every block is faster). Opt-1 eliminates the p99 spike (occasional stalls vanish). Together they produce both sustained throughput gain and consistent saturation.

---

## What This Is NOT

- **Not an EL optimisation.** reth received zero code changes. The same reth binary, same config, same hardware serves all 5 CLs in every bench run.
- **Not a network optimisation.** The FCU is a loopback HTTP call on the same machine.
- **Not a transaction pool optimisation.** The mempool was already full (40 workers, 50k accounts, 2× surplus send rate).

The CL is the pacemaker. A slow pacemaker sends the signal late. A late signal shortens reth's fill window. A shorter fill window means fewer transactions per block. Fewer transactions per block means lower TPS — despite reth being fully capable of more.

---

## Bench data reference

Full run: `bench/runs/adv-erc20-40w-120s-500Mgas-20260412_154021/`
- Baseline (kona-okx-baseline): `kona-okx-baseline.json`
- Optimised (kona-okx-optimised, bd0b96219): `kona-okx-optimised.json`

Step-level proof (attr_step_a/b/c1-c4): `kona-okx-baseline.cl.log`

| Step | Baseline p50 / p99 | Optimised p50 / p99 | Fixed by |
|---|---|---|---|
| `step_a` (get_unsafe_head) | 0ms / 0ms | 0ms / 0ms | Not an EL RPC — watch channel |
| `step_b` (l1_origin_lookup) | 0ms / 9ms | 0ms / 16ms | Cached; epoch spike only |
| **`step_c1` (sys_config_fetch)** | **95ms / 224ms** | **0ms / 0ms** | **Opt-2 — eliminated entirely** |
| `step_c2` (l1_header_fetch) | 0ms / 7ms | 0ms / 4ms | Epoch only |
| `step_c3` (l1_receipts_fetch) | 0ms / 4ms | 0ms / 4ms | Epoch only |
| `queue_wait` (T1→T2) | 141ms p99 | 0.6ms p99 | **Opt-1 — BinaryHeap fix** |
