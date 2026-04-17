# Poseidon2 Optimized Implementations

Gas-optimized Poseidon2 hash function implementations in **Solidity** and **Circom**, targeting **BN254 scalar field** with **x^5 S-box**. Compatible with Noir/Barretenberg.

## Quick Start

On a fresh checkout, no manual dependency setup is required — every `make` target auto-populates `lib/` and downloads `pot12.ptau` on first use.

```shell
make test          # correctness suite (forge test)
make bench         # Solidity gas benchmark
make cross-check   # Solidity <-> Circom output equality
make bench-circom  # Circom R1CS + Groth16 proving benchmark
make help          # list all targets
```

To populate dependencies manually (e.g. before running `forge` directly):

```shell
make setup         # or: bash scripts/setup-libs.sh
```

This clones `forge-std`, `zemse/poseidon2-evm` and `V-k-h/poseidon2-solidity` into `lib/` at pinned refs, and downloads the Powers-of-Tau file into `bench/circom/`. Both `lib/` and `pot12.ptau` are **gitignored** — they live locally only.

## Implementations

| Contract / Circuit | t | Interface | Key Optimization |
|--------------------|---|-----------|------------------|
| **Poseidon2T2** | 2 | `hash1(uint256)` | D=[1,2], zero mulmod in internal matrix |
| **Poseidon2T2FF** | 2 | `compress(uint256, uint256)` | Feed-forward, optimal for Merkle trees |
| **Poseidon2T3** | 3 | `hash2(uint256, uint256)` | D=[1,1,2], zero mulmod |
| **Poseidon2T4** | 4 | `hash3(uint256, uint256, uint256)` | M4 matrix manually unrolled |
| **Poseidon2T4Sponge** | 4 | `hash1` - `hash9` | Sponge with dirty-value tracking, Noir-compatible IV |
| **Poseidon2T8** | 8 | `hash7`, `hash4_padded` - `hash6_padded` | M4 Kronecker product, packed RC storage |

All Solidity implementations are `library` contracts with `internal pure` functions. Circom circuits mirror the same algorithms with `var` optimization to minimize R1CS constraints.

### Optimization Techniques

- **Dirty-value tracking**: Annotate value bounds (0/3, 1/3, 2/3) to safely use `add` instead of `addmod`, saving gas in hot loops
- **Packed RC storage**: Partial rounds store only 1 RC per round (for state[0]) instead of t, reducing bytecode by 60-77%
- **S-box function extraction** (T4S, T8): Deduplicate inline x^5 S-box blocks into a reusable Yul function
- **Circom var optimization**: Use `var` for matrix intermediates instead of `signal`, reducing R1CS constraints (e.g. T4: 612 vs NethermindEth 648)

## Project Structure

```
src/
├── solidity/              # Solidity implementations (Poseidon2T2..T8)
└── circom/                # Circom implementations (poseidon2_t2..t8)

bench/                     # Benchmark suite (Poseidon1 vs Poseidon2 vs third-party)
├── solidity/              # Gas benchmarks (wrappers, vendored, FullBenchmark.t.sol)
└── circom/                # Constraint benchmarks (circuits, vendored, scripts)

test/
├── Correctness.t.sol      # Output correctness verification (test vectors + cross-impl)
└── cross_check.sh         # Solidity <-> Circom automated cross-check

scripts/
└── setup-libs.sh          # Idempotent bootstrap: clones lib/* at pinned refs + fetches pot12.ptau

Makefile                   # Wraps forge/cross-check/bench workflows with auto-setup
```

## Usage

The recommended entry points are the Makefile targets in [Quick Start](#quick-start). Each auto-runs `setup-libs.sh`, so a fresh clone works out of the box.

Under the hood they map to:

| Make target         | Underlying command                                    |
| ------------------- | ----------------------------------------------------- |
| `make build`        | `forge build`                                         |
| `make test`         | `forge test` (correctness suite, `test/` profile)     |
| `make bench`        | `FOUNDRY_PROFILE=bench forge test -vv`                |
| `make cross-check`  | `bash test/cross_check.sh`                            |
| `make bench-circom` | `bash bench/circom/scripts/bench_full.sh`             |
| `make clean`        | `forge clean && rm -rf bench/circom/build_*`          |

External prerequisites (must be installed on the host):

- [Foundry](https://book.getfoundry.sh/) — `forge build` / `forge test`
- [`circom`](https://docs.circom.io/) + [`snarkjs`](https://github.com/iden3/snarkjs) + `node` — only for `cross-check` and `bench-circom`
- `curl` or `wget` — used once by `setup-libs.sh` to fetch `pot12.ptau`

## Adding a New Implementation for Comparison

To add a new Poseidon-family implementation to the benchmark matrix:

### Solidity (gas benchmark)

1. **Import or vendor the source** into `bench/solidity/vendored/<impl>.sol`, or add it as a git dependency in `scripts/setup-libs.sh`.
2. **Write a thin wrapper** at `bench/solidity/wrappers/<Impl>Wrapper.sol` with one `external view` method per arity the impl supports. For `internal pure` libraries the wrapper inlines them; for standalone contracts (non-standard ABI like zemse-yul) staticcall them directly from `FullBenchmark` helpers instead.
3. **Wire into `bench/solidity/FullBenchmark.t.sol`**: add the wrapper instance in `setUp()` and a `g = gasleft(); <wrapper>.hash_N(...); console.log(...)` line in the matching `test_gas_N_inputs()` function.
4. Run `make bench` to see the number next to the others.

### Circom (constraint benchmark)

1. **Vendor the `.circom` source(s)** under `bench/circom/vendored/` (re-namespaced if needed to avoid `include` collisions).
2. **Add a per-arity wrapper circuit** at `bench/circom/circuits/bench_<label>_<hashN>.circom` whose `component main = …(N)` instantiates the benchmark target. Keep it under 3 lines per circuit.
3. **Add one `bench` line per arity** in `bench/circom/scripts/bench_full.sh` pointing at the new circuit and an input file from `mk_input`.
4. Run `make bench-circom` to see R1CS constraint count and Groth16 proving time.

### Correctness

If the new implementation shares RCs with any `lib/` dependency or `src/` variant, add an `assertEq` against it in `test/Correctness.t.sol`. If it uses different RCs, cross-checking is not meaningful and you can skip this step.

## Key Results

| Scenario | Best Choice | Solidity Gas | Circom Constraints |
|----------|-------------|-------------|-------------------|
| Merkle tree 2-to-1 | T2FF compress | 17,468 | 419 |
| 3-input hash | T4S | 28,779 | 612 |
| Variable-length (1-9) | T4S sponge | 28K-71K | 612-1,842 |
| 5-7 inputs (exact) | T8 | 58,692 | 1,120 |

vs Poseidon1: **30-40% gas savings** for 2+ inputs. vs other Poseidon2 (NethermindEth, Worldcoin): **lowest constraint count** at every t value.

## Benchmarked Implementations

| ID | Source | Type | Deployable |
|----|--------|------|------------|
| P1-chancehudson | [poseidon-solidity](https://github.com/chancehudson/poseidon-solidity) | Poseidon1, hand-written assembly, t=2-6 | Yes |
| P1-circomlibjs | [circomlibjs](https://github.com/iden3/circomlibjs) | Poseidon1, JS-generated bytecode, t=2-7 | Yes (t=7 near 24KB limit) |
| P2-zemse | [poseidon2-evm](https://github.com/zemse/poseidon2-evm) | Poseidon2, Yul inline assembly, t=4 | No (32KB, exceeds EIP-170) |
| P2-Vkh | [poseidon2-solidity](https://github.com/V-k-h/poseidon2-solidity) | Poseidon2, pure Solidity sponge, t=4 | No (63KB, exceeds EIP-170) |
| P2-sserrano44 | [elHub](https://github.com/sserrano44/elHub) | Poseidon2, pure Solidity, t=3 | Yes |

### Bytecode Size Note

Gas benchmarks measure external calls to wrapper contracts. For implementations using `internal` library functions (ours, P1-chancehudson, P2-Vkh, P2-sserrano44), the library code is **inlined** into the wrapper at compile time, so wrapper bytecode size closely reflects the actual library size. P1-circomlibjs contracts are deployed directly via `vm.etch`. P2-zemse is a standalone contract called via `staticcall` -- the reported 32,207 bytes is the library contract itself, not the thin wrapper.

## Dependencies

Build / toolchain:

- [Foundry](https://book.getfoundry.sh/) — Solc 0.8.30, Cancun EVM
- [forge-std](https://github.com/foundry-rs/forge-std) — pinned `v1.15.0`

Benchmarked (cloned into `lib/` by `setup-libs.sh`; **not tracked**):

- [poseidon2-evm](https://github.com/zemse/poseidon2-evm) — pinned `v1.0.0` (zemse)
- [poseidon2-solidity](https://github.com/V-k-h/poseidon2-solidity) — pinned `f48a837` (V-k-h)
