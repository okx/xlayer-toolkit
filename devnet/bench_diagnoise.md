# Benchmark Diagnostic Notes

## Follower stuck during AA benchmark

### Phenomenon

During the EIP-8130 AA benchmark, the follower side stopped advancing while the sequencer kept producing blocks.

Observed symptoms:

- `cast bn -r http://localhost:8124` stopped at a fixed height, for example `8597993`.
- `cast bn -r http://localhost:8123` continued to grow, so this was not a sequencer crash.
- The stuck path was the follower/RPC side: `op-reth-rpc` / `op-kona-rpc`.
- `op-kona-rpc` became unhealthy and logged gossip block validity errors.
- `op-reth-rpc` stayed at the old latest block and received forkchoice updates whose payload status was `Syncing`.
- The follower txpool also showed heavy pressure, with queued transactions around `100000` in the sampled run.

Representative log patterns:

```text
Received invalid block err=Timestamp { current, received }
ForkchoiceUpdated { payload_status: Syncing }
```

### Direct Cause

The follower receives sequencer blocks through Kona gossip. Before accepting a gossiped block, Kona validates its timestamp in:

```text
/home/po/now/xlayer-reth/deps/optimism/rust/kona/crates/node/gossip/src/block_validity.rs
```

The check compares the block timestamp with the local wall clock:

```rust
let current_timestamp =
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs();

let is_future = envelope.payload.timestamp() > current_timestamp + 5;
let is_past = envelope.payload.timestamp() < current_timestamp - 60;
```

So the follower rejects gossip blocks if their timestamp is more than 5 seconds in the future or more than 60 seconds in the past relative to the follower machine's local time.

The sequencer does not need to pass this gossip validation to advance its own chain. It builds blocks locally and inserts them through its local engine path. That is why the sequencer RPC on `8123` can keep growing while the follower RPC on `8124` rejects gossip and stalls.

### Why The Timestamp Fell Behind

The devnet rollup config uses a 1 second block time:

```text
devnet/config-op/rollup.json: "block_time": 1
```

Under the AA benchmark, sequencer blocks were effectively full. Example block production logs showed values like:

```text
txs=7623 gas_used=265.35Mgas gas_limit=265.37Mgas full=100.0%
```

For this setup to remain healthy, a worst-case full block must be produced, executed/imported, committed, and propagated within about 1 wall-clock second, with some margin.

When AA full-block processing takes longer than the configured block time, L2 timestamp advances by only 1 second per block while real time advances by more than 1 second. The timestamp debt accumulates. Once the block timestamp is more than 60 seconds behind wall clock, Kona's gossip validity check rejects the sequencer's blocks as too old.

The failure chain is:

```text
AA benchmark fills blocks
-> sequencer full-block production falls behind the 1s cadence
-> L2 block timestamp lags wall clock
-> follower gossip timestamp check rejects blocks older than 60s
-> follower stops advancing and enters bad EL syncing / forkchoice state
```

### What It Is Not

The earlier `nonce_key=max` local-time expiry bug is not the direct cause of this follower stall.

Those invalid nonce-free AA transactions were rejected at txpool admission with errors such as `EIP-8130 nonce-free expiry too far`. They are a separate benchmark transaction-construction bug.

In the stuck follower sample, the queued transactions were sequenced-lane AA transactions such as `nonceKey=0` with future `nonceSequence`, not `nonce_key=max`. The large queued pool is better understood as a symptom or amplifier after the follower falls behind, not the primary timestamp trigger.

### Essential Constraint

With `block_time=1`, the system needs:

```text
worst-case full-block production/import time <= 1 second
```

with enough margin for gossip, engine updates, and local scheduling noise.

If the sequencer cannot consistently handle full AA blocks within that cadence, timestamp debt is expected to accumulate and followers can fall outside Kona's gossip timestamp window.

### Real Fix Directions

The durable fixes are around block workload, configured cadence, or AA execution cost:

1. Reduce per-block workload.

   Lower the block gas limit, or adjust the benchmark so it does not continuously fill every block. This directly reduces worst-case block processing time.

2. Increase `block_time`.

   Match the configured block interval to what the current implementation and hardware can actually sustain for worst-case full AA blocks.

3. Optimize EIP-8130 processing.

   If the target is the current gas limit with 1 second blocks, then the real work is to profile and optimize the AA path: validation, owner config lookup, signature verification, AA pool selection, execution, state root/commit, and payload building.

4. Be careful with gas price as a proposed fix.

   Raising or tuning AA transaction gas price can affect admission, ordering, replacement, and fee policy, but once blocks are already full it does not make transaction execution itself faster. It is not the main throughput fix unless the goal is to throttle which transactions enter blocks.

### Surface Mitigations

These can make the devnet easier to debug, but they do not remove the underlying throughput/cadence mismatch:

- Widen or disable Kona's gossip past-timestamp window in devnet-only builds.
- Improve follower recovery when `engine_forkchoiceUpdated` returns `Syncing` after rejected gossip blocks.
- Reset the follower unsafe head or resync the follower instead of letting it remain permanently behind.
- Restart follower components or clear follower txpool after a failed benchmark run.

### Useful Manual Checks

Compare sequencer and follower heights:

```bash
cast bn -r http://localhost:8123
cast bn -r http://localhost:8124
```

Check timestamp debt on the sequencer:

```bash
date +%s
cast block latest -r http://localhost:8123 --json | jq '{number:.number,timestamp:.timestamp,txs:(.transactions|length)}'
```

Look for follower gossip and forkchoice symptoms:

```bash
docker logs --tail 100 op-kona-rpc | rg 'Timestamp|ForkchoiceUpdated|EL syncing|Received invalid block'
docker logs --tail 100 op-reth-rpc | rg 'Status|Received new payload|Canonical chain committed|WARN'
```

A quick interpretation rule:

- If `8123` grows and `8124` does not, the sequencer is still alive and the follower path is stuck.
- If latest sequencer block timestamps are more than 60 seconds behind local wall clock, Kona gossip timestamp validation is expected to reject those blocks on the follower.
- If blocks are near 100% gas full during AA benchmark, the deeper question is why full AA blocks cannot be processed within the configured block time.


## Sequencer AA TPS Bottleneck

### Test Setup

The comparison below used the same devnet and the same op-reth diagnostic image.

```bash
make aa sig=secp tx=native noncekey=0 payer=sender
make native
```

The op-reth Sequencer was instrumented around payload build, `engine_getPayloadV4`,
`engine_newPayloadV4`, and `engine_forkchoiceUpdatedV3`. Kona's existing engine
logs were used for `block_import_duration`, `insert_duration`, and `fcu_duration`.

The container had no CPU or memory quota:

```text
NanoCpus=0 CpusetCpus="" Memory=0 MemorySwap=0
```


### Sequencer Flow And Engine API Boundaries

The benchmark path is easier to reason about if it is split into four stages:

```text
user RPC
-> op-reth-seq txpool admission / validation
-> Kona starts a payload build
-> op-reth payload builder executes txpool transactions
-> Kona seals, imports, and canonicalizes the built block
```

The Engine API calls belong to those stages like this:

```text
1. User sends txs
   eth_sendRawTransaction / txpool validation
   Engine API: none

2. Kona starts building block N+1
   engine_forkchoiceUpdatedV3(..., payloadAttributes=Some(...))
   This returns a payload_id and starts an async op-reth payload job.

3. op-reth payload build job
   Executes sequencer attribute txs, then txpool txs, then finalizes the block candidate.
   Engine API: none inside the transaction execution loop.
   This is what the `xlayer payload build timing` and
   `xlayer txpool transaction execution timing` logs measure.

4. Sequencer Kona seals and self-imports that payload
   4a. Seal / retrieve the locally built payload from op-reth-seq:
       engine_getPayloadV4(payload_id)

   4b. Insert and canonicalize the payload in the sequencer EL:
       engine_newPayloadV4(payload)
       -> engine_forkchoiceUpdatedV3(..., payloadAttributes=None)

5. Follower / validator imports the sequencer block
   The follower receives the block through gossip/derivation, then imports it
   into its own EL:
       engine_newPayloadV4(payload)
       -> engine_forkchoiceUpdatedV3(..., payloadAttributes=None)

   Follower / validator nodes do not call getPayload for the sequencer's block.
```

So `payload build` is the op-reth async builder work that was triggered by
`engine_forkchoiceUpdatedV3` with payload attributes. `Kona block_import_duration`
is the Sequencer-Kona-side seal/self-import window. It starts when Sequencer Kona
asks op-reth-seq for the built payload and ends after that payload has been
inserted and canonicalized in the sequencer EL.

In this devnet run the seal call is `engine_getPayloadV4`. On older fork
timestamps the same role could be `engine_getPayloadV2` or `engine_getPayloadV3`;
the version changes, but its position in the flow does not.

Important distinction: a follower/validator does not use `getPayload` to follow
the sequencer's block. The sequencer's Kona uses `getPayload` to seal its own
locally built payload. Followers receive blocks through gossip/derivation and
then use `newPayload` plus `forkchoiceUpdated` to import/canonicalize them.


Sequencer self-import should not normally execute the same block from scratch a
second time. The op-reth payload builder produces `OpBuiltPayload` with an
`executed_block` attached. The node launch loop listens for built payloads and
inserts that executed block into the engine tree through `InsertExecutedBlock`.
When Sequencer Kona later calls `engine_newPayloadV4` with the same block, the
engine tree can hit the already-seen block path and return `VALID` without
re-running all transactions.

There is still non-zero `newPayload` cost: payload decoding/conversion, basic
validation, tree lookup, RPC/client overhead, and possible scheduling/cache
waiting. But this path is intended to avoid full tx execution duplication on the
Sequencer's own locally built block.

### Observed Throughput

AA benchmark:

```text
Average BTPS: ~1200-1300
Full block shape: ~7623 txs, ~265.35Mgas, full=100%
```

Native benchmark:

```text
Average BTPS: ~8300-8500
Full/native-heavy block shape: often 6k-12k txs
```

So the low AA TPS is not because the benchmark fails to fill blocks. AA blocks
are gas-full. The problem is that full AA blocks stretch the effective block
interval far beyond the configured 1 second cadence.

### Full-Block Timing Comparison

AA full blocks, using sealed blocks `8594105..8594129`:

```text
payload build total: avg 501.8ms, p50 508.0ms, p90 616.0ms, max 768.8ms
payload txpool execution: avg 419.8ms, p50 435.3ms, p90 514.5ms, max 650.2ms
engine_getPayloadV4 server timing: avg 342.7ms, p50 335.8ms, p90 561.0ms, max 965.7ms
engine_newPayloadV4 server timing: avg 70.9ms, p50 48.6ms, p90 131.2ms, max 342.7ms
Kona block_import_duration: avg 2213.1ms, p50 2287.6ms, p90 3954.7ms, max 5031.9ms
Kona insert_duration: avg 625.0ms, p50 684.9ms, p90 1191.4ms, max 1894.0ms
```

Native full/native-heavy blocks from the comparison run:

```text
payload build total: avg 211.3ms, p50 197.9ms, p90 330.9ms, max 491.5ms
payload txpool execution: avg 125.5ms, p50 112.9ms, p90 206.0ms, max 369.9ms
engine_getPayloadV4 server timing: avg 3.4ms, p50 2.4ms, p90 6.4ms, max 10.9ms
engine_newPayloadV4 server timing: avg 6.2ms, p50 5.6ms, p90 10.3ms, max 14.6ms
Kona block_import_duration: avg 49.2ms, p50 48.5ms, p90 64.7ms, max 75.7ms
Kona insert_duration: avg 20.7ms, p50 20.9ms, p90 28.7ms, max 34.6ms
```


Metric meanings:

- `payload build total`: op-reth async payload builder time after Kona starts
  a build with `engine_forkchoiceUpdatedV3(... payloadAttributes=Some(...))`.
- `payload txpool execution`: the txpool transaction execution subpart of
  payload build.
- `engine_getPayloadV4 server timing`: op-reth's time serving Kona's seal
  request. If the payload is not ready, this can include waiting for the
  pending payload job.
- `engine_newPayloadV4 server timing`: op-reth's time handling the payload
  insertion request.
- `Kona insert_duration`: Kona-side sub-timer around the `newPayload` request.
- `Kona block_import_duration`: Sequencer-Kona-side end-to-end
  seal/self-import/canonicalize timer: `getPayload` plus payload conversion plus
  `newPayload` plus `forkchoiceUpdated`. Follower import has the same
  `newPayload` plus `forkchoiceUpdated` shape, but without `getPayload`.


Metric nesting cheat sheet:

```text
Kona starts payload build with FCU(payloadAttributes=Some)
    |
    |-- op-reth payload build total
    |      |-- payload txpool execution
    |      |-- finish / state root / receipts / trie updates / small overhead
    |
Kona later seals/imports the payload
    |
    |-- Kona block_import_duration
           |-- getPayload client-side time
           |      |-- engine_getPayloadV4 server timing
           |      |-- response serialization / RPC / decode overhead
           |
           |-- local payload -> L2BlockInfo conversion
           |
           |-- InsertTask total_duration
                  |-- Kona insert_duration
                  |      |-- engine_newPayloadV4 server timing
                  |      |-- RPC / decode / local payload->block conversion overhead
                  |
                  |-- forkchoiceUpdated client-side time
                         |-- engine_forkchoiceUpdatedV3 server timing
```

The useful equations are approximate:

```text
payload build total
  ~= payload txpool execution + finish + small builder overhead

Kona insert_duration
  ~= engine_newPayloadV4 server timing + RPC/serialization/conversion overhead

InsertTask total_duration
  ~= Kona insert_duration + forkchoiceUpdated client-side time + small overhead

Kona block_import_duration
  ~= getPayload client-side time + local conversion + InsertTask total_duration
```

Important non-equation:

```text
Kona block_import_duration != payload build total + engine_getPayloadV4 + engine_newPayloadV4
```

`payload build total` happens in an async op-reth payload job that starts before
`getPayload`. If Kona calls `getPayload` after the payload is already ready,
`engine_getPayloadV4` is tiny. If Kona calls `getPayload` while the payload job
is still running, `engine_getPayloadV4` includes waiting for the remaining part
of that same payload build. That means `payload build total` and
`engine_getPayloadV4` can overlap; they should not be blindly added.

### Reth Tracing To Reuse

The current diagnostic timers mix three different clocks: op-reth builder work,
Engine API server handling, and Kona-side client/import windows. For bottleneck
analysis the cleaner axis should be:

```text
txpool admission / validation
-> payload-builder transaction execution and state reads
-> state root / trie computation
-> persistence / database commit
```

Upstream reth already has most of this on the block execution/import side. The
main reusable pieces are:

- `target: "engine::tree::payload_validator"` and `target: "engine::tree"`
  around block validation and execution. Important spans/events include
  `state_provider`, `evm_env`, `pre_execution`, `execution`, per-transaction
  `execute tx`, `BlockExecutor::finish`, `merge_transitions`,
  `hashed_post_state`, `wait_receipt_root`, `wait_payload_tx_root`,
  `wait_hashed_post_state`, and `validate_block_post_execution`.
- `sync.execution` metrics from `ExecutorMetrics`: block execution duration,
  gas/sec, gas-used histogram, pre-execution duration, per-transaction wait
  duration, per-transaction execution duration, post-execution duration, and
  changed account/storage/code counts.
- `sync.block_validation` metrics for state-root and validation work:
  `state_root_duration`, `state_root_histogram`, gas-bucketed state-root
  histograms, deferred trie compute duration, payload validation duration, and
  post-execution validation duration.
- `ExecutionTimingStats`, emitted through `target: "reth::slow_block"` when
  `--engine.slow-block-threshold` is configured. This is the best existing
  one-line summary because it already carries block number/hash, gas, tx count,
  `execution_ms`, `state_read_ms`, `state_hash_ms`, optional `commit_ms`, total
  time, Mgas/s, state read/write counts, and cache hit/miss rates.
- `engine::persistence` and blockchain-tree persistence metrics for database
  flushes. `Persistence::on_save_blocks` measures the `save_blocks + commit`
  window and returns it as `commit_duration`; after persistence completes, the
  tree attaches this duration to the slow-block log.

The relevant upstream files are:

```text
/home/po/now/reth/crates/engine/tree/src/tree/payload_validator.rs
/home/po/now/reth/crates/engine/tree/src/tree/metrics.rs
/home/po/now/reth/crates/evm/evm/src/metrics.rs
/home/po/now/reth/crates/chain-state/src/execution_stats.rs
/home/po/now/reth/crates/node/events/src/node.rs
/home/po/now/reth/crates/engine/tree/src/persistence.rs
```

A useful detail: `state_read_ms` is a subset of `execution_ms`, not an extra
phase to add. The slow-block total is:

```text
total_ms = execution_ms + state_hash_ms + commit_ms
```

when commit is known. `state_read_ms` explains how much of execution was spent
fetching account/storage/code state, including cache hits.

For txpool admission, upstream reth has less ready-made timing. The pool uses
`target: "txpool"` logs and has a validator-task in-flight gauge, but normal
transaction validation does not have a stateless/stateful validation histogram.
Only blob validation has a dedicated duration metric. So for AA txpool
admission we probably need one small extra summary timer around:

```text
eth_sendRawTransaction / batch -> pool.validate -> pool insertion
```

with AA-specific subfields if needed: stateless checks, payer/owner config
lookup, signature verification, balance/nonce-lane checks, and final pool insert.

For the Sequencer builder path, upstream `crates/ethereum/payload/src/lib.rs`
executes txpool transactions directly in `default_ethereum_payload`. It has
coarse `payload_builder` logs such as `building new payload`, `built better
payload`, and `sealed built block`, but it does not emit the same detailed
`ExecutionTimingStats` summary as `engine_newPayload` validation. The clean
reuse strategy is therefore to mirror reth's existing phase names and stats in
the builder path rather than invent unrelated names:

```text
builder_total_ms
builder_tx_iter_wait_ms / skipped_txs
builder_tx_execution_ms
builder_state_read_ms, accounts/storage/code reads, cache hit rates
builder_finish_state_root_ms
builder_receipts_and_finalize_ms
builder_built_block_gas, tx_count, Mgas/s
```

This should be measured at the builder itself, not inferred from
`engine_getPayloadV4`. `getPayload` is a resolver: if the async build is still
running, it waits; if the build is already ready, it is tiny. So
`engine_getPayloadV4` is useful for detecting missed lead time, but it is not
the authoritative builder execution timer.

For Sequencer self-import, `engine_newPayloadV4` should also not be treated as
a second execution timer. op-reth inserts locally built payloads as
`InsertExecutedBlock`; later `newPayload` for the same block should normally hit
the already-seen path and avoid full transaction re-execution. It remains useful
for measuring RPC/conversion/tree lookup overhead, but the execution cost of a
Sequencer-built block belongs to the builder-side metrics above.

A cleaner diagnostic layout for the next round would be:

```text
1. txpool admission
   aa_pool_validation_ms, stateless_ms, stateful_ms, sig_verify_ms, config_lookup_ms

2. builder execution
   builder_total_ms, tx_execution_ms, state_read_ms, tx_count, gas_used, Mgas/s

3. state root / finalize
   state_hash_ms, finish_ms, receipt_root_wait_ms, trie/deferred_trie_ms

4. database persistence
   commit_ms from persistence / reth::slow_block

5. scheduling/API symptoms
   getPayload_wait_ms, newPayload_server_ms, fcu_server_ms, Kona client durations
```

Only the first four should be used to identify the physical bottleneck. The
fifth group explains why the sequencer loop misses its 1 second cadence, but it
should not be mixed into the execution/root/commit totals.

### Root Cause

The direct bottleneck is full AA block processing on the Sequencer Engine API
path, not block packing.

Two effects combine:

1. AA payload building is materially slower than native payload building.

   The txpool execution portion is roughly 3x slower in the sampled full blocks
   (`~420ms` vs `~126ms`), even though the AA block contains fewer transactions.

2. The slower AA build/import path destroys the one-block lead time that Kona's
   sequencer loop expects.

   Kona seals the previous payload first, then starts building the next payload:

   ```text
   seal previous payload -> build next payload -> wait for next tick
   ```

   With native blocks, import is short enough that the next payload is already
   built by the time `getPayload` is called. With AA full blocks, the previous
   seal/import commonly takes longer than the 1 second block time. The next
   tick is already overdue, so Kona starts the next build and then almost
   immediately asks `engine_getPayloadV4` for it. That call then waits on the
   in-flight AA payload build.

   This is why `engine_getPayloadV4` is ~3ms for native full blocks but hundreds
   of milliseconds for AA full blocks.

The larger end-to-end symptom is:

```text
AA full payload build ~= 0.5s
plus getPayload wait ~= 0.3-1.0s
plus newPayload/insert/fcu client path ~= 0.6-1.9s
=> effective full-block interval often 5-7s
```

That interval is far above `block_time=1`, so TPS drops and timestamp debt can
accumulate until the follower rejects gossip blocks.

### Secondary Amplifier

reth's basic payload job can continue rebuilding stale payload jobs until they
are resolved, cancelled, frozen, or hit their deadline. During the AA run there
were repeated logs like:

```text
xlayer payload build aborted: not better than current payload
Seal failed. err=UnsafeHeadChangedSinceBuild
```

The native run also shows stale builds, but stale AA builds are much more
expensive when they execute a large AA candidate set. This consumes extra CPU
while the Sequencer is already late.

### Fix Directions

Short-term devnet knobs:

- Lower the block gas limit for AA stress runs so worst-case full-block
  build/import fits under `block_time`.
- Increase `block_time` if the goal is stable long-running AA load rather than
  maximum 1-second cadence.
- Keep `SKIP_OP_STACK_BUILD=true`, `SKIP_KONA_BUILD=true`, and
  `SKIP_OP_RETH_BUILD=true` after the diagnostic image is built.

Code-level optimization directions:

- Profile and optimize EIP-8130 execution/validation in the payload builder.
  The first target is the txpool execution phase.
- Reduce duplicate/stale payload build work for Sequencer mode, especially
  after `getPayload` resolves or the unsafe head changes.
- Investigate why the Kona Engine API client path expands AA full-block import
  from tens of milliseconds to seconds while the op-reth handler logs are much
  smaller. This may require more granular Kona-side timing around
  `seal_payload`, local payload conversion, `new_payload_v4`, and
  `fork_choice_updated_v3`.

### Useful Log Filters

```bash
docker logs --since 5m op-reth-seq 2>&1 \
  | rg 'xlayer engine getPayloadV4 timing|xlayer engine newPayloadV4 timing|xlayer engine forkchoiceUpdatedV3 timing|xlayer payload build timing|xlayer payload build aborted|xlayer txpool transaction execution timing|Block added to canonical chain'

docker logs --since 5m op-kona-seq 2>&1 \
  | rg -i 'Built and imported new unsafe block|Inserted new unsafe block|block build started|engine_getPayloadV4|engine_newPayloadV4|engine_forkchoiceUpdatedV3|Forkchoice updated|Seal failed'
```

## Disk Pressure Notes

The largest dynamic disk user during repeated devnet builds is Docker BuildKit
cache, not devnet logs or profiling output.

Observed rough sizes:

```text
Docker BuildKit cache: ~117GB
xlayer-reth/target: ~2.6GB
xlayer-reth/deps/optimism/rust/target: ~2.4GB
devnet logs/data in the sampled state: tiny
```

The BuildKit cache growth is expected because `DockerfileOp` uses Rust cache
mounts for Cargo registry/git/target, and the OP stack Docker build also uses
Go build/module caches.

Safer cleanup order:

```bash
docker builder prune
docker image prune
```

More aggressive cleanup such as `docker system prune -a --volumes` can delete
useful images, containers, and volumes, so it should not be used casually on a
devnet machine with chain data.


## Phase-Oriented Timing Plan

The current diagnostic image splits the AA path into the phases we want to compare:

```text
user RPC
-> txpool admission / validation
-> payload builder transaction execution
-> payload finish / state root
-> executed-block import / state root check / DB commit
-> Kona Engine API client wait and scheduling
```

### Sequencer Metrics

AA txpool admission is logged under `txpool::eip8130::diag`:

```text
xlayer aa batch admission timing
  total, accepted, failed_prevalidate, failed_finalize
  prevalidate_us, finalize_us, total_us
```

This measures RPC-side txpool admission before the transaction is available to the
builder. The finer per-transaction debug logs are intentionally behind `debug` so
benchmark logging does not dominate throughput:

```text
xlayer aa validator timing
  inner_us              # standard reth tx validation wrapper
  aa_layer_us           # EIP-8130-specific validation layer
  total_us

xlayer eip8130 validation timing
  structural_us         # envelope/account_changes shape checks
  signature_us          # sender/payer/authorizer native auth resolution
  state_open_us         # open latest StateProvider
  state_read_us         # NONCE_MANAGER / owner_config / balance reads
  intrinsic_us          # EIP-8130 intrinsic gas / payer auth gas
  total_us
```

Sequencer payload build is logged under `payload_builder::diag`:

```text
xlayer payload state provider loaded
  state_provider_us

xlayer txpool transaction execution timing
  considered, included, over_limit, unsupported, interop_invalid,
  nonce_too_low, invalid, gas_used_delta, da_bytes_delta, execution_us

xlayer payload build timing
  txs, gas_used, gas_limit
  setup_us, pre_execution_us, sequencer_execution_us,
  txpool_execution_us, finish_state_root_us, total_us
```

For the current AA benchmark, `txpool_execution_us` is the main builder-side
transaction execution timer. It includes EVM execution plus state reads made by
execution. `finish_state_root_us` is the builder finish step: receipts/block
finalization plus state-root/trie work bundled by `builder.finish(...)`; it is
not pure execution.

Engine API server timing is still logged under `rpc::engine::diag`:

```text
xlayer engine getPayloadV4 timing       # Sequencer seal/get built payload wait
xlayer engine newPayloadV4 timing       # server-side payload insert call
xlayer engine forkchoiceUpdatedV3 timing
```

`engine_getPayloadV4` is not a builder execution timer. If it is large, it means
Kona asked for a payload whose builder job was still running or otherwise not
ready.

### Validator / Import Metrics

reth's existing slow-block instrumentation is enabled in devnet entrypoints with:

```text
--engine.slow-block-threshold=${RETH_SLOW_BLOCK_THRESHOLD:-0}
```

That emits `reth::slow_block` logs on import/canonicalization and gives the
validator/import side without reimplementing reth internals:

```text
timing.execution_ms
timing.state_read_ms
timing.state_hash_ms
timing.commit_ms
timing.total_ms
throughput.mgas_per_sec
state_reads, state_writes, cache_hits, cache_misses
```

For a Sequencer node, these slow-block logs describe import/canonicalization of
an executed payload. For a follower/RPC node, they describe validator import of
the sequencer block via `engine_newPayloadV4` plus `engine_forkchoiceUpdatedV3`.

Important non-additive rule:

```text
state_read_ms is a subcomponent of execution_ms, not execution_ms + state_read_ms.
execution_ms + state_hash_ms + commit_ms ~= total_ms, modulo scheduling/overhead.
```

### Recommended Log Filters

Sequencer overview:

```bash
docker logs --since 5m op-reth-seq 2>&1 \
  | rg 'xlayer aa batch admission timing|xlayer payload build timing|xlayer txpool transaction execution timing|xlayer engine getPayloadV4 timing|reth::slow_block'
```

Validator/RPC import overview:

```bash
docker logs --since 5m op-reth-rpc 2>&1 \
  | rg 'xlayer engine newPayloadV4 timing|xlayer engine forkchoiceUpdatedV3 timing|reth::slow_block'
```

Optional AA validation internals, only for short sampled runs because it is per
transaction:

```bash
# add the target to RUST_LOG / log filter for a short run only
# txpool::eip8130::diag=debug
```

### 2026-05-22 AA Phase Sample

Command:

```bash
make aa sig=secp tx=native noncekey=0 payer=sender
```

Run shape:

```text
sig=secp tx=native noncekey=0 payer=sender gas_limit=55000
benchmark timeout: 90s
reported txs: 48556 by t+56s
reported average BTPS: 856.78
```

Low-noise AA admission summaries on the Sequencer show that txpool validation is
not the current wall-clock bottleneck:

```text
aa validator summary:
  avg_inner_us=15
  avg_aa_layer_us=97
  avg_total_us=114

eip8130 validation summary:
  avg_structural_us=0
  avg_signature_us=36
  avg_state_open_us=2
  avg_state_read_us=7
  avg_intrinsic_us=40
  avg_total_us=92

aa admission summary:
  avg_prevalidate_us=115
  avg_finalize_us=3914
  avg_total_us=4030
```

Interpreting the phases:

- Signature verification is about `36us/tx`.
- EIP-8130 state reads are about `7us/tx`.
- The AA-specific validation layer is about `97us/tx`.
- Full admission including pool finalize/insertion is about `4ms/tx`, but this
  is concurrent RPC admission work and is not the full-block execution/import
  critical path shown below.

Full-block Sequencer payload builder samples:

```text
full_payload_samples=25
avg_txs=5770
avg_txpool_exec_ms=518.76
avg_state_root_ms=137.46
avg_payload_total_ms=658.28
min_total_ms=95.06
max_total_ms=1601.08
```

Sequencer `engine_getPayloadV4` server timing:

```text
getPayload_samples=300
avg_ms=32.00
over_10ms=25
over_100ms=15
max_us=1209227.34
```

This means most `getPayload` calls are tiny, but when the sequencer loop is late
it sometimes waits hundreds of milliseconds to more than one second for an
in-flight payload.

Validator/RPC import samples:

```text
validator_newPayload_samples=12
avg_txs=4932
avg_newPayload_ms=585.58
min_ms=72.46
max_ms=1179.88

validator_fcu_samples=261
avg_fcu_ms=16.58
min_ms=0.04
max_ms=3956.56
```

Kona follower-side insert/import samples:

```text
kona_full_insert_samples=15
avg_insert_ms=870.41
avg_total_ms=1150.46
min_insert_ms=123.55
max_insert_ms=3747.81
```

Sequencer persistence metrics from reth's existing Prometheus exporter:

```text
seq_persistence_count=272
p50_ms=32.45
p90_ms=56.43
max_ms=71.93
save_blocks_commit_sf_last_ms=7.05
save_blocks_commit_mdbx_last_ms=3.62
save_blocks_commit_rocksdb_last_ms=0.0007
```

The validator/RPC reth container did not previously expose metrics. The devnet
configuration now enables validator metrics with `--metrics=0.0.0.0:9001` and
maps it to host port `9002`, so the next clean run can compare Sequencer
`localhost:9001/metrics` with validator `localhost:9002/metrics`.

Current read:

```text
txpool validation/signature/state-read: tens of microseconds per tx
Sequencer full-block execution:        ~519ms average
Sequencer finish/state-root:           ~137ms average
Sequencer full payload build:          ~658ms average
Validator engine_newPayload import:    ~586ms average
Kona insert/import client window:      ~870ms average, with multi-second spikes
```

So for this run the slow path is not EIP-8130 signature verification or owner
config/state lookup during admission. The main physical bottleneck is full-block
execution/import, followed by state-root/finalize work. The follower can still
fall behind because its `engine_newPayloadV4` plus Kona insert/forkchoice client
window is often close to or above the 1 second block cadence, and occasionally
spikes much higher.

Next profiling target should be reth's block execution/import internals for AA
full blocks: EVM execution state reads, interpreter/precompile cost, trie/state
root, and persistence/commit. The existing `reth::slow_block` fields are still
the preferred source for the import side because they split:

```text
execution_ms, state_read_ms, state_hash_ms, commit_ms
```

For the builder side, the next useful refinement is to mirror that same split
inside the payload builder, because `txpool_execution_us` currently bundles EVM
execution and execution-time state reads together.

### 2026-05-22 Validator Metrics Retest

Change:

```text
op-reth-rpc now starts with --metrics=0.0.0.0:9001
host metrics port: localhost:9002
```

No rebuild was needed. Only `op-reth-rpc` was recreated with the new command line
and port mapping.

Benchmark command:

```bash
make aa sig=secp tx=native noncekey=0 payer=sender
```

Run shape:

```text
benchmark timeout: 90s
reported txs: 60984 by t+65s
reported average BTPS: 929.92
sequencer/follower heights after run: 8595865 / 8595865
```

Sequencer payload builder log aggregation:

```text
full_payload_samples=20
avg_txs=7598
avg_txpool_exec_ms=567.32
avg_finish_state_root_ms=149.23
avg_payload_total_ms=718.08
min_total_ms=478.08
max_total_ms=1082.94
```

Validator/RPC Engine API and Kona aggregation:

```text
validator_newPayload_samples=9
avg_txs=7623
avg_newPayload_ms=908.66
min_ms=597.68
max_ms=1330.65

kona_full_insert_samples=11
avg_insert_ms=1124.42
avg_total_ms=1478.33
min_insert_ms=596.39
max_insert_ms=3151.21
```

Validator native reth metrics, calculated as before/after deltas from
`localhost:9002/metrics`:

```text
all imported blocks:
  execution: 129 samples, avg 101.82ms
  state_root blocked wait: 129 samples, avg 4.89ms
  gas: 129 blocks, avg 36.94Mgas/block

>40Mgas full blocks:
  execution: 18 samples, avg 727.51ms
  state_root blocked wait: 18 samples, avg 1.99ms

persistence:
  beacon persistence: 19 samples, avg 121.40ms
  db commit whole rw: 30 samples, avg 11.34ms
  save_blocks sf commit: 30 samples, avg 9.91ms
  save_blocks mdbx commit: 30 samples, avg 11.78ms

per-tx execution metrics:
  tx execution: 136829 samples, avg 0.03ms/tx
  tx wait: 136829 samples, avg 0.06ms/tx
```

Read:

```text
validator newPayload ~= full-block execution + small state-root wait + import overhead
Kona insert       ~= validator newPayload + RPC/client/conversion/scheduling overhead
persistence       ~= separate canonical persistence window, usually ~100ms scale here
```

The strongest signal is the `>40Mgas` validator execution bucket:

```text
avg execution for AA full blocks ~= 728ms
avg state-root blocked wait     ~= 2ms
avg persistence                 ~= 121ms
```

So the follower-side bottleneck is primarily transaction execution of full AA
blocks, not EIP-8130 txpool admission and not state-root waiting. Persistence is
a secondary cost. The `state_root` metric in this reth version measures time
blocked waiting for the state-root task; because trie work can run concurrently,
small `state_root_duration` means it is not blocking the critical path much in
this run, not that it consumes zero CPU.

This also explains the earlier symptom: Sequencer can usually build payloads in
less than one second, but validator full-block `newPayload` plus Kona insert and
persistence often consumes around or above the 1 second cadence, with multi-second
spikes.

### 2026-05-22 ERC20 vs AA Timing Comparison

The ERC20 run used the same `make erc20` flow, split into init and benchmark so
metrics were collected only for the benchmark segment:

```text
erc20-init -> settle -> metrics baseline -> erc20-bench
ERC20 contract: 0x4F14729eA979Dd88642Bf99b44d0f5bE87FaCf68
benchmark timeout: 90s
reported ERC20 average BTPS: 5473.51
sequencer/follower heights after run: 8596504 / 8596504
```

Comparison with the previous AA run:

| Metric | ERC20 | AA tx |
| --- | ---: | ---: |
| Sequencer payload build avg | 352.48ms | 718.08ms |
| Sequencer txpool execution | 177.46ms | 567.32ms |
| Sequencer finish/state-root | 173.65ms | 149.23ms |
| Validator `newPayloadV4` avg | 493.50ms | 908.66ms |
| Kona follower insert avg | 520.85ms | 1124.42ms |
| Kona follower total avg | 537.90ms | 1478.33ms |
| Validator `>40Mgas` execution avg | 402.03ms | 727.51ms |
| Validator `>40Mgas` state-root blocked wait avg | 50.07ms | 1.99ms |
| Validator persistence avg | 463.61ms | 121.40ms |
| Benchmark reported average BTPS | 5473.51 | 929.92 |

Read:

- ERC20 full-block execution is much faster than AA on both Sequencer builder
  and validator import.
- AA's biggest regression remains validator full-block execution plus the Kona
  insert/client window.
- ERC20 persistence is higher in this run, likely because the ERC20 benchmark
  produces many more blocks/transactions during the same wall-clock window and
  drives heavier persistence batches. Even with that, ERC20's follower total
  import window is still far below AA's.
- The AA `state_root blocked wait` metric is tiny because reth's state-root task
  is usually ready by the time validation blocks on it. This does not mean trie
  work is free; it means it is not blocking the critical path much in that AA
  sample.


### EIP-8130 Micro-Tracing

To separate transaction decoding/parser overhead from execution overhead, the
current diagnostic patch adds two EIP-8130-specific log lines:

```text
xlayer eip8130 parts timing summary
xlayer eip8130 execution block timing
```

`xlayer eip8130 parts timing summary` is emitted from:

```text
/home/po/now/xlayer-reth/deps/optimism/rust/alloy-op-evm/src/eip8130/parts.rs
```

It samples every 4096 calls to `eip8130_parts(tx, caller)` and reports cumulative
averages:

```text
avg_total_us
avg_auth_us
avg_account_changes_us
avg_calldata_us
avg_call_phases_us
avg_account_changes
avg_account_change_units
avg_call_phases
avg_calls
avg_call_data_bytes
```

This answers whether `from_encoded_tx -> eip8130_parts` is spending meaningful
time in native auth resolution, account-change projection, sender-signing
payload encoding/calldata gas, or `Vec<Vec<Eip8130Call>>` construction.

`xlayer eip8130 execution block timing` is emitted from:

```text
/home/po/now/xlayer-reth/deps/optimism/rust/op-revm/src/handler.rs
```

It aggregates successful EIP-8130 handler executions per worker thread and
block, then flushes when that thread moves to the next block:

```text
block_number
txs
total_us
setup_us
auth_us
account_changes_us
calls_us
finalize_us
avg_total_us
avg_setup_us
avg_auth_us
avg_account_changes_us
avg_calls_us
avg_finalize_us
call_phases
calls
account_change_units
pre_writes
config_writes
sequence_updates
authorizer_validations
```

For the current benchmark shape:

```bash
make aa sig=secp tx=native noncekey=0 payer=sender
```

the expected transaction shape is simple:

```text
call_phases ~= txs
calls ~= txs
account_change_units/pre_writes/config_writes/sequence_updates/authorizer_validations ~= 0
```

So the interpretation is straightforward:

- If `parts avg_total_us * txs_per_block` is large, the overhead is likely in
  decoding/parser-side allocation or native auth work before execution.
- If execution `auth_us` dominates, the handler-side owner/auth state checks are
  expensive.
- If execution `account_changes_us` is non-zero for this benchmark, something is
  unexpectedly activating config/create/delegation paths.
- If execution `calls_us` dominates, the expensive part is the actual inner EVM
  call path, bytecode loading, balance transfer, journaling, or related state
  access.
- If `finalize_us` dominates, look at receipt/log/final gas accounting and
  post-execution work.

Useful filters:

```bash
docker logs --since 5m op-reth-seq 2>&1 | rg 'xlayer eip8130 parts timing summary|xlayer eip8130 execution block timing'
docker logs --since 5m op-reth-rpc 2>&1 | rg 'xlayer eip8130 parts timing summary|xlayer eip8130 execution block timing'
```

The same filters should be compared between Sequencer and validator/RPC. A
single canonical block can show up as multiple fragments, and the same block can
be executed more than once by payload building / payload validation, so offline
analysis should aggregate by `block_number` and also compare `parts.samples`
against the chain's actual included tx count.

#### 2026-05-22 AA secp/native sample

Command:

```bash
/home/po/go/bin/adventure aa-bench -f ./testdata/config.json --sig secp --tx native --noncekey 0 --payer sender --gaslimit 0
```

Benchmark shape:

```text
sig=secp tx=native noncekey=0 payer=sender gas_limit=55000
included txs reported by benchmark: 63802 by block 8594038
observed TPS: ~0.9k-1.3k
```

Latest `eip8130_parts` cumulative summaries:

| node | samples | avg_total_us | avg_auth_us | avg_account_changes_us | avg_calldata_us | avg_call_phases_us | avg_call_phases | avg_calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sequencer | 647168 | 38 | 37 | 0 | 0 | 0 | 1 | 1 |
| validator/RPC | 217088 | 49 | 47 | 0 | 0 | 0 | 1 | 1 |

Interpretation:

- `Vec<Vec<Eip8130Call>>` / call-phase construction is not the visible bottleneck
  for this benchmark; it rounds to 0us/tx.
- `eip8130_parts` is dominated by native auth/materialization, not calldata or
  account-change projection.
- The call count is a clue, not proof of causality: this run included about 64k
  benchmark txs, while `eip8130_parts` ran about 647k times on the sequencer
  and 217k times on the validator/RPC. The sequencer count can be higher simply
  because its payload builder/handler loop is faster and can attempt more work
  in the same wall-clock window. To decide whether this is a bottleneck, compare
  `parts total_us` against payload-build / import critical-path time, not just
  against included tx count.

Aggregated `op-revm` EIP-8130 handler timing from recent full-ish fragments:

| node | avg txs/sample | avg total_us/sample | avg auth_us/sample | avg calls_us/sample | avg total_us/tx | avg auth_us/tx | avg calls_us/tx |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sequencer | 19715 | 96838 | 36797 | 31088 | 4.76 | 1.78 | 1.62 |
| validator/RPC | 12341 | 313883 | 180093 | 98373 | 24.87 | 14.27 | 7.81 |

Interpretation:

- For the simple `payer=sender` / native-transfer shape, account-change paths are
  inactive as expected (`account_change_units = 0`, no config writes, no
  authorizer validations).
- The EIP-8130 handler body itself is not large enough to explain the previous
  validator import totals on its own. The bigger suspect is repeated transaction
  environment construction, especially `FromTxWithEncoded<TxEip8130>` rebuilding
  `Eip8130Parts` every time the same tx is converted for payload build /
  validation / import execution.



#### 2026-05-22 Fine-grained executor timing

Added a narrower EIP-8130-only timing layer so the next AA run can separate the
executor path instead of inferring it from payload/Kona totals.

New log:

```text
xlayer eip8130 block executor timing
```

Fields:

```text
block_number
txs
tx_env_us / avg_tx_env_us
da_footprint_us / avg_da_footprint_us
transact_us / avg_transact_us
receipt_us / avg_receipt_us
commit_us / avg_commit_us
finish_us
gas_used
```

Meaning:

- `tx_env_us`: `tx.into_parts()`, including `Tx -> TxEnv` conversion and the
  `FromTxWithEncoded<TxEip8130>` path that rebuilds `Eip8130Parts`.
- `transact_us`: the actual `evm.transact(tx_env)` call, including handler
  execution and state reads/writes performed during EVM execution.
- `receipt_us`: receipt construction.
- `commit_us`: `db.commit(state)` for the per-tx state changes.
- `finish_us`: `OpBlockExecutor::finish()`, before the outer block builder
  computes hashed state / state root.

State-root timing is logged separately:

```text
xlayer eip8130 state root timing
```

Builder fields:

```text
block_number
flashblock_index
eip8130_txs
calculated
mode=full|incremental|disabled
state_root_us
state_root
```

Validator fields:

```text
block_number
flashblock_index
target_index
eip8130_txs
calculated
strategy
state_root_us
state_root
```

Useful filters:

```bash
docker logs --since 5m op-reth-seq 2>&1 | rg 'xlayer eip8130 (parts timing summary|execution block timing|block executor timing|state root timing)'
docker logs --since 5m op-reth-rpc 2>&1 | rg 'xlayer eip8130 (parts timing summary|execution block timing|block executor timing|state root timing)'
```

Targeted checks passed after adding these diagnostics:

```bash
cargo check --manifest-path deps/optimism/rust/Cargo.toml -p alloy-op-evm -j 6
cargo check -p xlayer-builder -p xlayer-flashblocks -j 6
```

#### Sequencer vs validator handler timing caveat

Do not compare Sequencer and validator handler averages as if they were one
canonical block executed once on both sides. Current `xlayer eip8130 execution
block timing` is thread-local and keyed by `block_number`; it measures execution
samples seen by that worker, not the unique canonical block transaction set.

Important implications:

- Sequencer payload building can execute txpool candidates that never enter the
  final payload, and may execute the same transaction again across payload jobs,
  flashblock paths, fallback payloads, or cache replay.
- Validator import usually sees the finalized payload shape, but may also hit or
  miss flashblock/prefix caches depending on the path.
- Higher `eip8130_parts.samples` on the Sequencer is not a root cause by itself.
  It can simply mean the Sequencer loop is faster and attempts more work in the
  same wall-clock interval.
- If Sequencer `avg_total_us/tx` is lower than validator/RPC, the likely
  explanations are different cache warmth, different execution paths, fewer cold
  state reads, or metric aggregation over different sample sets.

The next useful comparison is therefore:

```text
tx_env_us vs transact_us vs commit_us vs state_root_us
```

for the same benchmark window on both nodes, plus included transaction count per
block. That will tell whether the expensive part is repeated `Eip8130Parts`
construction, handler/EVM execution, state commit, or root calculation.

#### 2026-05-22 AA vs ERC20 run with fine-grained timings

Commands:

```bash
make aa sig=secp tx=native noncekey=0 payer=sender
make erc20
```

AA run details:

- Started AA bench at `2026-05-22 13:13:04 UTC`.
- Benchmark block range: `8594051..8594069`.
- Final benchmark line before timeout: `140030` txs, `1007.56` TPS over `138s`.
- AA tx gas limit in the tool: `55000`.
- The follower/RPC node lagged during the run, but later caught up (`8123`:
  `8594329`, `8124`: `8594328` right after the backlog cleared).

ERC20 control details:

- Started ERC20 bench at `2026-05-22 13:27:14 UTC`.
- Benchmark block range: `8594909..8594977`.
- Final benchmark line before timeout: `494805` txs, `7160.55` TPS over `69s`.
- The sender hit some `in-flight transaction limit reached` / `nonce too low`
  retries, but blocks stayed full enough for timing comparison.

Main timing comparison, average per selected full block:

| Metric | ERC20 | AA secp/native | Notes |
| --- | ---: | ---: | --- |
| Benchmark TPS | `7160.55` | `1007.56` | Adventure summary line |
| Sequencer payload build total | `365.3 ms` | `702.0 ms` | Final payload per block |
| Sequencer txpool execution | `217.3 ms` | `586.2 ms` | `xlayer payload build timing` |
| Sequencer finish/state-root | `147.4 ms` | `114.4 ms` | AA state root is not the obvious bottleneck here |
| Sequencer `engine_newPayloadV4` | `8.7 ms` | `119.3 ms` | Sequencer self-import / engine timing |
| Validator `engine_newPayloadV4` | `471.8 ms` | `861.2 ms` | AA value covers the first 9 directly `Valid` full blocks |
| Validator slow-block execution | `388.1 ms` | `752.3 ms` | Reth slow block timing, 69 ERC20 blocks / 19 AA blocks |
| Validator state read | `4.1 ms` | `92.9 ms` | AA adds much more cold-ish state access |
| Validator state hash/root | `43.6 ms` | `1.4 ms` | Not the AA bottleneck in this run |
| Validator commit/persistence | `390.4 ms` | `632.5 ms` | Reth slow block timing with delayed commit row |
| Validator slow-block total | `823.1 ms` | `1386.8 ms` | Execution + commit/persistence view |
| Kona follower total / insert | `510.2 / 495.2 ms` | `906.8 / 892.2 ms` | AA value covers first 9 direct inserts |

AA-only EIP-8130 timing:

| Metric | Sequencer | Validator/RPC | Notes |
| --- | ---: | ---: | --- |
| `block executor transact_us` | `108.7 ms` | `187.9 ms` | Sum of `evm.transact(tx_env)` over txs in block |
| `block executor commit_us` | `18.0 ms` | `38.0 ms` | Per-tx `db.commit(state)` sum |
| Matched handler total | `30.5 ms` | `83.8 ms` | Best-effort: handler timing record whose `txs` matched executor txs |
| Matched handler auth | `10.9 ms` | `41.4 ms` | Inside EIP-8130 handler |
| Matched handler calls | `11.2 ms` | `27.5 ms` | Inside EIP-8130 handler |
| `eip8130_parts` samples | `1,331,200` | `327,680` | Delta during AA window |
| `eip8130_parts` total | `48.13 s` | `17.44 s` | Cumulative across repeated conversions |
| `eip8130_parts` avg/sample | `36.2 us` | `53.2 us` | Last-window delta |

Interpretation:

- The AA slowdown is not explained by state-root calculation. In this run AA
  state hash/root time is tiny on the validator slow-block logs, and Sequencer
  `finish_state_root_us` is lower than ERC20.
- The direct EVM portion is larger for AA, but not by the full TPS gap:
  validator `evm.transact(tx_env)` is about `188 ms/block`, and matched 8130
  handler work is about `84 ms/block`.
- A very large amount of time is visible in `eip8130_parts`: about `17.44s` on
  the validator/RPC during the AA window, or roughly `125 us` per actually
  included AA tx if normalized by the `140030` benchmark txs. Because these
  samples are emitted from repeated conversion paths, this is a strong suspect
  for the gap outside `evm.transact`.
- AA also causes much higher validator state-read time (`92.9 ms` vs `4.1 ms`)
  and higher commit/persistence time (`632.5 ms` vs `390.4 ms`).
- The current `xlayer eip8130 state root timing` logs did not fire in this run,
  so those flashblocks-specific probes are not on the active path for this
  benchmark. Use payload `finish_state_root_us` plus reth slow-block
  `timing.state_hash_ms` until the state-root probe is moved to the active path.

Next optimization direction:

- First try caching or carrying parsed `Eip8130Parts` through decoded tx / tx env
  construction so `FromTxWithEncoded<TxEip8130>` does not rebuild it repeatedly.
- Then reduce AA validation state reads if possible.
- Only after those two are understood does it make sense to tune block gas limit
  or AA gas pricing, because those settings hide the bottleneck rather than
  explaining it.

## AA txpool optimization follow-up, 2026-05-22 19:33 UTC

Command:

```sh
make aa sig=secp tx=native noncekey=0 payer=sender
```

Code changes in the tested image:

- Keep AA pool pending/queued counts incrementally instead of scanning the pool
  on every gauge/cap refresh.
- Remove mined sequenced txs in a lane without demoting/promoting the same
  descendants repeatedly; only rebalance the lane once after the mined prefix is
  drained.
- Replace the AA best-transaction iterator's per-build `HashMap` snapshot with a
  `Vec` snapshot ordered like `by_id`, and advance same-lane successors by
  adjacent index lookup.
- Fix the `pending_tip_by_seq` cursor path so skipped pending prefixes still
  leave the lane head anchored at the chain nonce.

Validation:

- `cargo fmt --manifest-path deps/optimism/rust/Cargo.toml --package reth-optimism-txpool`
- `cargo check --manifest-path deps/optimism/rust/Cargo.toml -p reth-optimism-txpool -j 6`
- `cargo test --manifest-path deps/optimism/rust/Cargo.toml -p reth-optimism-txpool best --lib -j 6`
- `cargo test --manifest-path deps/optimism/rust/Cargo.toml -p reth-optimism-txpool eip8130_pool --lib -j 6`
- Rebuilt `op-reth:latest` and restarted `op-reth-seq` / `op-reth-rpc`.

Benchmark result:

| Metric | Before | After |
| --- | ---: | ---: |
| Final AA benchmark line | `4203.36 TPS` at `143s` | `7510.06 TPS` at `148s` |
| Stable range during run | about `4.2k TPS` | about `7.5k-7.9k TPS` |
| Included txs per full block | about `7618` | about `7618` |

Sequencer full-block averages after the optimization (`txs > 7000`, 163
blocks):

| Metric | Average |
| --- | ---: |
| Payload build total | `466.2 ms` |
| Payload txpool execution | `269.0 ms` |
| Payload finish/state-root | `194.1 ms` |
| Txpool transaction execution | `226.8 ms` |
| EIP-8130 executor `transact_us` | `117.9 ms` |
| EIP-8130 executor `commit_us` | `23.7 ms` |
| EIP-8130 DA footprint | `7.3 ms` |
| AA bundle state update total | `109.1 ms` |
| AA bundle state lock held | `84.2 ms` |
| AA bundle balance lock held | `18.2 ms` |
| AA admission average | `249 us/tx` |

Interpretation:

- The major regression was the repeated AA pool/best-iterator work around
  payload construction, not EVM execution itself. After the iterator/counter/lane
  fixes, AA secp/native is back above the 5k target and close to the ERC20
  control range from the previous run.
- `eip8130_parts` is no longer the dominant visible cost in this run:
  `2,454,349 us / 2,490,368 samples`, about `1 us` per call.
- Remaining sequencer cost is now mostly normal block construction:
  transaction execution plus state-root/finish. The AA bundle-state update still
  costs around `109 ms` on full blocks and is the next local optimization target
  if more headroom is needed.

Follower/RPC note after the run:

- `op-reth-rpc` exited with `OOMKilled=true`, `ExitCode=137` shortly after the
  high-throughput AA run.
- After restart, `cast bn -r http://localhost:8124` still reported `8600213`,
  while logs showed it receiving new payloads around `8602440+` and returning
  `Ok(Syncing)` from `engine_newPayloadV4` / `engine_forkchoiceUpdatedV3`.
- This looks like a separate follower recovery/backfill issue: once the follower
  is far behind or restarted, Kona keeps feeding future payloads while the EL is
  missing intermediate parents, so the EL can accumulate non-canonical/syncing
  payload state until memory pressure kills the container. It should be tracked
  separately from the sequencer-side TPS regression fixed above.

## AA cached parts / auth reuse follow-up, 2026-05-23

The later p256 / payer=random tests found a second hot path after the iterator
fixes above.

### Root cause

`Eip8130Parts` and native auth state were still rebuilt in more than one place
after txpool validation had already resolved the same data:

- txpool admission validated sender/payer auth and built execution parts;
- payload building rebuilt the tx env from the encoded transaction;
- AA invalidation-rule generation rebuilt sender/payer auth again while holding
  the AA side-pool write lock.

For `payer=sender` + `secp`, the duplicate work was small enough to hide behind
the other txpool fixes. For `p256` / `p256_webauthn`, or `payer=random`, the same
pattern repeated expensive native verification and increased write-lock hold
time during batch admission. Before this fix, the AA side-pool finalize path
showed millisecond-scale lock waits and hundreds of microseconds of side-pool
work per tx.

### Fix

The fix is to compute the expensive AA execution material once and carry it
through the pooled transaction:

- cache `OpTx` / `Eip8130Parts` on `OpPooledTransaction` with `OnceLock`;
- build those cached parts during AA validation, reusing the already recovered
  sender and already resolved sender/payer auth states;
- make payload building consume the cached tx env through `into_with_tx_env()`;
- make AA invalidation-rule generation reuse cached `Eip8130Parts` instead of
  rebuilding sender/payer auth under the side-pool lock;
- keep batch AA admission split into parallel validation plus one batched
  side-pool write-lock section.

After this, the side-pool finalize path dropped to roughly `8-11 us` of
side-pool work per tx, and the batch lock wait dropped from about `1.7 ms/tx`
to about `0.1-0.2 ms/tx` in the sampled logs.

### Benchmark results

All runs used:

```sh
aa-bench -f ./testdata/config.json --tx native --noncekey 0 --gaslimit 0
```

with only `--sig` and `--payer` varied. Results are from the latest optimized
image before cleaning detailed tracing.

| Case | Command shape | Result |
| --- | --- | ---: |
| secp, payer=sender | `--sig secp --payer sender` | avg `7419.36 TPS`, max `7935.36 TPS` |
| secp, payer=random | `--sig secp --payer random` | avg `5921.66 TPS`, max `10503.50 TPS` |
| p256 raw, payer=sender | `--sig p256 --payer sender` | avg `6698.64 TPS`, max `6844.34 TPS` |
| p256 raw, payer=random | `--sig p256 --payer random` | avg `5466.51 TPS`, max `8484.03 TPS` |
| p256 webauthn, payer=sender | `--sig p256_webauthn --payer sender` | stable `6k-7k TPS`, max `7397.44 TPS` |

Interpretation:

- `payer=random` is slower than `payer=sender`, but it still stays above the
  original 5k target after payer/auth reuse.
- `p256` raw is close to secp and much better than the expected failure mode of
  repeating verification under lock.
- `p256_webauthn` also stays in the same broad range after the cache fix; later
  dips in that run correlated with follower/RPC health rather than txpool
  admission counters.
- The remaining gap between `payer=sender` and `payer=random` is expected:
  sponsored payer mode has extra auth material, owner-config checks, and payer
  balance/account invalidation rules.

### Tracing cleanup policy

The very fine-grained probes used to find this issue were useful during the
debug window, but they should not remain as production tracing. The useful
long-lived observability is stage-level:

- payload build total;
- txpool transaction execution;
- block finish / state-root;
- validator `newPayload`;
- persistence / commit;
- gauges for latest block gas, transaction count, and size.

High-frequency internal probes such as per-call `Eip8130Parts` construction,
per-auth validation micro-timers, or per-admission lock timing are better kept
for local profiling / flamegraphs and removed once the hot path is fixed.

