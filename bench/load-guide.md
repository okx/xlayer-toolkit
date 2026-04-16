# Benchmark Load Parameters — A Guide for Junior Developers

> **⚠️ DEPRECATED** — This document describes the old Python-based load sender (`high-load-sender.py`)
> which has been removed. The current bench stack uses the **adventure** Go toolkit instead.
>
> For current documentation see: [`BENCH-GUIDE.md`](./BENCH-GUIDE.md)
>
> This file is kept as historical reference only.

---

This document explains what the benchmark naming convention means, how the load
generator works, and how to read the results. If you have ever seen `50w-10f-120s`
in a filename and wondered what it is, start here.

---

## What does `50w-10f-120s` mean?

The shorthand encodes three parameters:

```
50w  -  10f  -  120s
 │        │       │
 │        │       └── duration: run the test for 120 seconds
 │        └────────── in-flight: each wallet keeps 10 pending TXs in the mempool at all times
 └─────────────────── wallets: 50 funded Ethereum addresses are sending transactions
```

| Part | Full name | What it controls |
|---|---|---|
| `Nw` | wallets | Number of funded sender accounts |
| `Ff` | in-flight | Max pending (unconfirmed) TXs per wallet at any moment |
| `Ts` | duration | How many seconds the test runs |

---

## What is a "wallet" in this context?

A wallet is just an Ethereum address that has been funded with ETH (from a Hardhat
deployer account). Each wallet is a completely independent sender. It signs its own
transactions locally — there is no central coordinator.

In the `high-load-sender.py` script each wallet runs its own async loop. All wallets
start at the same time and stop after the duration expires.

---

## What does "in-flight" mean?

In-flight is the maximum number of unconfirmed transactions a single wallet has in
the mempool at any moment.

Think of it like a pipeline. A wallet submits TX #1, then immediately submits TX #2,
TX #3, ... up to TX #10 without waiting for any of them to confirm. Once a TX is
confirmed (included in a block), the wallet immediately submits a replacement to keep
the pipeline full.

```
Wallet pipeline (10 in-flight):

  submitted ──► mempool ──► included in block ──► wallet submits a new TX
  TX #1            ↑
  TX #2            │ 10 slots always occupied
  TX #3            │ (as long as blocks keep confirming them)
  ...             ...
  TX #10
```

**Why does this matter?**
More in-flight TXs = more pressure on the RPC node to accept and sequence them.
If in-flight is too low, the pipeline drains faster than it refills and TPS drops.
If in-flight is too high, you flood the mempool and nonces can get stuck.
10 is a good balance for a single-sequencer devnet.

---

## Mempool math: how many TXs are in flight at once?

```
Total pending TXs in mempool ≈ wallets × in-flight

  50w × 10f  =    500 TXs in mempool at any time
 150w × 10f  =  1 500 TXs in mempool at any time
 600w × 10f  =  6 000 TXs in mempool at any time  ← estimated for block saturation
```

Note "at any time" — this is a moving pool. As blocks confirm TXs, wallets refill
immediately. At steady state the mempool hovers around this number.

---

## Block capacity math: what is the maximum possible TPS?

The chain configuration fixes the throughput ceiling:

```
Block gas limit  =  30 000 000 gas
TX gas cost      =      21 000 gas  (simple ETH transfer, the cheapest TX type)
Block time       =           1 s    (xlayer production)

Max TXs per block  =  30 000 000 ÷ 21 000  =  1 428 TXs
Max TPS            =  1 428 TXs ÷ 1 s      =  1 428 TX/s  ← the hard ceiling
```

The tests in this repo ran at ~237 TX/s with 50 wallets and ~238 TX/s with 150 wallets.
That is only **~17% of the 1 428 TX/s ceiling**. Blocks were never full.

---

## Why did tripling wallets (50 → 150) barely move TPS?

This was the key finding that surprised us. The numbers:

| Config | TPS (block-inclusion) | Block capacity used |
|---|---|---|
| 50w-10f-120s | 235–237 TX/s | ~17% |
| 150w-10f-120s | 230–241 TX/s | ~17% |

Going from 500 pending TXs to 1 500 pending TXs produced at most +2.5% more TPS.

**The bottleneck was not the sequencer — it was the sender.**

The `high-load-sender.py` is a Python script using `eth-account` + `aiohttp`. On macOS
(Apple Silicon, under enterprise MDM) each HTTP RPC call to `eth_sendRawTransaction`
takes a small but non-trivial amount of time. With 150 wallets all hammering the same
RPC endpoint over localhost, the Python process saturates its event loop and OS socket
queue before the sequencer's mempool fills.

```
What you want:                         What actually happened:

  Wallets ──► RPC ──► mempool ──► EL     Wallets ──► RPC  ← bottleneck here
                       (full)                         (Python sender saturates)
                       ↓                              ↓
                  1 428 TX/s                   ~237 TX/s
```

To truly saturate blocks (push to ~80% = ~1 143 TX/s), you need one of:
- **600+ wallets** — more senders to overcome the per-sender latency cost
- **Pre-signed batch flood** — sign all TXs offline, blast them directly to the mempool
- **In-Docker sender** — run the sender inside the Docker network to cut TCP overhead
- **Different language** — Go or Rust sender instead of Python aiohttp

---

## What do the three TPS numbers mean?

Every result file reports three TPS numbers. They measure different things:

| Metric | How it is calculated | What it tells you |
|---|---|---|
| **TPS — whole-run avg** | Total submitted TXs ÷ wall-clock seconds | How fast the sender was firing (includes warmup/cooldown noise) |
| **TPS — 10s peak window** | Highest TXs confirmed in any 10-second window | The best sustained throughput observed |
| **TPS — block-inclusion** | Total TXs confirmed in blocks ÷ block time elapsed | Actual throughput the chain delivered ← **most important** |

Block-inclusion TPS is the number to compare across CLs. It counts only TXs that were
actually mined, ignoring queued but unconfirmed TXs still in the mempool at test end.

---

## What does "safe lag" mean?

The OP Stack separates blocks into two categories:

- **Unsafe head** — the latest block the sequencer has built but not yet confirmed via L1
- **Safe head** — the latest block that has been verified against L1 batch data

```
L2 chain:
  block 100 (safe)  101  102  103  104  105 (unsafe head)
                    └─────── safe lag = 5 blocks ──────┘
```

Safe lag = `unsafe_head − safe_head` in blocks. Lower is better — it means the
derivation pipeline is keeping up with new blocks.

A high safe lag is not an error, but it means the batcher needs to work harder to catch
up. If the lag grows unboundedly, that is a batcher or CL problem.

---

## What does "FCU delta" mean?

FCU = `engine_forkchoiceUpdated` — the Engine API call the CL sends to the EL every
block to say "this is the new canonical head, start building the next block".

FCU latency is measured in two conditions:

- **FCU idle** — roundtrip time when no load generator is running (baseline)
- **FCU under load** — roundtrip time while 50/150 wallets are hammering the mempool
- **FCU delta** = FCU under load − FCU idle

A high FCU delta means the CL's internal machinery is adding latency to the Engine API
when the chain is busy. The root cause is usually derivation pressure — the CL is
sending too many Engine API calls at the same time the sequencer is trying to use it.

```
Good (op-node at 50w):
  FCU idle = 0.975 ms
  FCU load = 0.948 ms
  Delta    = −0.027 ms  ← within noise; derivation not interfering

Bad (kona at 50w):
  FCU idle = 0.771 ms
  FCU load = 1.598 ms
  Delta    = +0.827 ms  ← derivation flooding the shared HTTP client
```

At 17% block capacity a 0.827ms FCU delay has almost no effect on TPS (the block build
window has ~830ms of unused slack). At 80%+ saturation, every millisecond matters.

---

## Two outputs from every bench run — don't confuse them

When you run `bench.sh` two things are produced:

| Output | Location | What it is |
|---|---|---|
| `bench-{stack}-{ts}.txt` | `~/xlayer-bench-reports/` — **your home dir, not the repo** | Raw terminal output from `simple-bench.sh`. Auto-generated. Contains numbers, probe logs, raw metrics. |
| `toolkit-*.md` | `bench/{cl}/results/{load}/` — **inside the repo** | A structured markdown document you write by hand using the numbers from the `.txt` file. This is what gets committed. |

The `.txt` file is the raw material. The `.md` file is the record you keep.
Neither is generated from the other automatically — you copy the numbers manually.

---

## Future bench run directory guide

When you add a new bench run, write a `.md` and save it in the CL-specific directory:

```
bench/
├── op-node/results/{Nw-Ff-Ts}/toolkit-YYYYMMDD.md
├── kona/results/{Nw-Ff-Ts}/toolkit-kona-YYYYMMDD.md
└── base/results/{Nw-Ff-Ts}/toolkit-base-cl-YYYYMMDD.md
```

If you add a new load configuration, also add a comparative `README.md` under:

```
bench/reports/results/{Nw-Ff-Ts}/README.md
```

Copy from `bench/reports/results/TEMPLATE.md` and link to the individual CL run files
using relative paths (e.g. `../../../op-node/results/{Nw-Ff-Ts}/toolkit-YYYYMMDD.md`).

### Naming rules

| Part | Format | Example |
|---|---|---|
| Load config dir | `{wallets}w-{in-flight}f-{duration}s` | `600w-10f-120s` |
| op-node run file | `toolkit-YYYYMMDD.md` | `toolkit-20260331.md` |
| kona run file | `toolkit-kona-YYYYMMDD.md` | `toolkit-kona-20260331.md` |
| base run file | `toolkit-base-cl-YYYYMMDD.md` | `toolkit-base-cl-20260331.md` |

If you run multiple runs on the same day, append `-N`: `toolkit-20260331-2.md`.

---

## Quick reference: load levels tried so far

| Config | Wallets | Mempool pressure | Achieved TPS | Block % | Bottleneck |
|---|---|---|---|---|---|
| `50w-10f-120s` | 50 | ~500 pending | ~237 TX/s | ~17% | Python sender |
| `150w-10f-120s` | 150 | ~1 500 pending | ~238 TX/s | ~17% | Python sender |
| `600w-10f-120s` | 600 | ~6 000 pending | not yet tested | est. ~60% | sequencer? |
| `1428w-10f-120s` | ~1 428 | ~14 000 pending | not yet tested | ~100% | EL block build |
