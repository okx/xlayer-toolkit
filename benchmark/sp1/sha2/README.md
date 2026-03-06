# SP1 SHA-2 Benchmark

SP1 zkVM benchmark using SHA-2 hashing as the guest program, supporting SHA-224/256/384/512 variants, Core/Compressed/Groth16 proof modes, and optional SP1 precompile acceleration.

## Prerequisites

- [Rust](https://rustup.rs/)
- [Docker](https://docs.docker.com/get-docker/) (for guest ELF compilation via `sp1-build`)

## Quick Start

### 1. Build

Guest ELFs (vanilla + precompile) are compiled inside Docker (via `sp1-build` with `docker: true`), host binary is compiled natively.

```sh
./run.sh build
```

### 2. Execute (verify correctness, no proof)

```sh
N=256 MODE=execute ./run.sh run
N=512 MODE=execute ./run.sh run
```

### 3. Generate Proof

```sh
# SHA-256, Core proof
N=256 MODE=prove PROOF_MODE=core ./run.sh run

# SHA-512, Compressed proof
N=512 MODE=prove PROOF_MODE=compressed ./run.sh run

# SHA-256, larger input (1KB)
N=256 MODE=prove PROOF_MODE=core INPUT_SIZE=1024 ./run.sh run

# SHA-256 with SP1 precompile (accelerated syscall)
N=256 MODE=prove PROOF_MODE=core PRECOMPILE=true ./run.sh run
```

## Precompile

The `--precompile` flag selects an ELF built with SP1's patched `sha2` crate, which routes SHA-256 operations through a zkVM syscall for significantly fewer cycles. Both ELFs (vanilla and precompile) are built during `./run.sh build`.

## Proof Modes

| Mode | Description | On-chain Verify | Speed |
|------|-------------|-----------------|-------|
| Core | Raw STARK proof, no compression | No | Fast |
| Compressed | Recursively compressed STARK | Yes | Medium |
| Groth16 | SNARK wrapper over compressed proof | Yes | Slow |

## Benchmark Metrics

| Metric | Description |
|--------|-------------|
| Proof Mode | Core / Compressed / Groth16 |
| Precompile | Whether SP1 precompile is used |
| SHA Variant | SHA-224 / SHA-256 / SHA-384 / SHA-512 |
| Input Size | Size of data hashed (bytes) |
| Cycle Count | Total RISC-V instruction cycles executed |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Size of the proof (postcard serialized) |
| Verify Time | Wall-clock time for proof verification (skipped for Core) |
| Peak Memory | Maximum RSS during proving |
| Peak CPU | Peak CPU utilization during proving |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `256` | SHA-2 variant: 224, 256, 384, or 512 |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `core` | `core`, `compressed`, or `groth16` |
| `INPUT_SIZE` | `32` | Input data size in bytes |
| `PRECOMPILE` | `false` | `true` or `false` (use SP1 precompile) |
| `SP1_PROVER` | `cpu` | `cpu` or `network` |
| `RUST_LOG` | `info` | Log level (`info`, `debug`, `trace`) |

## Project Structure

```
benchmark/
├── utils/                  # Shared benchmark utilities
│   └── src/lib.rs          # Peak memory/CPU monitoring (Linux + macOS)
└── sp1/sha2/
    ├── run.sh              # Build/run helper script
    ├── Cargo.toml          # Workspace root
    ├── program/            # Guest program (compiled to RISC-V ELF)
    │   └── src/main.rs     # SHA-2 hashing inside zkVM (self-contained)
    ├── script/             # Host script (prover/verifier)
    │   ├── build.rs        # sp1-build with docker: true (vanilla + precompile)
    │   └── src/bin/main.rs # Benchmark entry point
    └── lib/                # Shared types for host
        └── src/lib.rs      # PublicValuesStruct, sha2_hash()
```

## Notes

- Two guest ELFs are built during `./run.sh build`: vanilla and precompile. Selected at runtime via `PRECOMPILE=true|false`.
- Changing `N`, `INPUT_SIZE`, or `PROOF_MODE` does NOT require rebuilding — they are runtime inputs.
- Input data is deterministic (`0xAB` repeated) for reproducible results.
- Groth16 mode requires pre-downloading circuit params: `./run.sh download-params`.
