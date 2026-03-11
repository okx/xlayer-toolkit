# RISC Zero Fibonacci Benchmark

RISC Zero zkVM benchmark using Fibonacci as the guest program, supporting Composite, Succinct, and Groth16 proof modes.

## Prerequisites

- [Rust](https://rustup.rs/)
- [RISC Zero toolchain](https://dev.risczero.com/api/zkvm/install) (`curl -L https://risczero.com/install | bash && rzup install`)

## Quick Start

### 1. Build

Guest ELF is compiled via `risc0-build`, host binary is compiled natively.

```sh
./run.sh build
```

### 2. Execute (verify correctness, no proof)

```sh
N=20 MODE=execute ./run.sh run
```

### 3. Generate Proof

```sh
# Composite (default, fastest, STARK per segment)
N=20 MODE=prove PROOF_MODE=composite ./run.sh run

# Succinct (aggregated single STARK)
N=20 MODE=prove PROOF_MODE=succinct ./run.sh run

# Groth16 (SNARK, on-chain verifiable, slowest)
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run
```

## Proof Modes

| Mode | Description | On-chain Verify | Speed |
|------|-------------|-----------------|-------|
| Composite | STARK proof per segment (default) | No | Fast |
| Succinct | Aggregated single STARK | Yes | Medium |
| Groth16 | BN254 SNARK wrapper | Yes | Slow |

## Benchmark Metrics

In `--prove` mode, the following metrics are reported:

| Metric | Description |
|--------|-------------|
| Proof Mode | Composite / Succinct / Groth16 |
| Cycle Count | Total RISC-V instruction cycles executed |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Size of the receipt (bincode serialized) |
| Verify Time | Wall-clock time for receipt verification |
| Peak Memory | Maximum RSS during proving |
| Peak CPU | Peak CPU utilization during proving |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `20` | Fibonacci input number |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `composite` | `composite`, `succinct`, or `groth16` |
| `RISC0_PROVER` | `local` | `local` or `bonsai` |
| `RISC0_CUDA` | - | Set to `1` to enable CUDA feature at build time |
| `RUST_LOG` | `info` | Log level (`info`, `debug`, `trace`) |

## Examples

```sh
# Build
./run.sh build

# Quick test - execute only (seconds)
N=20 MODE=execute ./run.sh run

# Benchmark Composite proof
N=20 MODE=prove PROOF_MODE=composite ./run.sh run

# Benchmark Succinct proof
N=20 MODE=prove PROOF_MODE=succinct ./run.sh run

# Benchmark Groth16 proof
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run

# Try different input sizes
N=100 MODE=prove PROOF_MODE=composite ./run.sh run
N=1000 MODE=prove PROOF_MODE=composite ./run.sh run

# Enable debug logging
RUST_LOG=debug N=20 MODE=prove PROOF_MODE=composite ./run.sh run
```

## Project Structure

```
benchmark/
├── utils/                    # Shared benchmark utilities
│   └── src/lib.rs            # Peak memory/CPU monitoring (Linux + macOS)
└── risc0/fibonacci/
    ├── run.sh                # Build/run helper script
    ├── Cargo.toml            # Workspace root
    ├── methods/              # Guest program build crate
    │   ├── guest/            # Guest program (compiled to RISC-V ELF)
    │   │   └── src/main.rs   # Fibonacci logic running inside zkVM
    │   ├── build.rs          # risc0_build::embed_methods()
    │   └── src/lib.rs        # Re-exports FIBONACCI_GUEST_ELF and ID
    ├── host/                 # Host program (prover/verifier)
    │   └── src/main.rs       # Benchmark entry point with mode selection
    └── lib/                  # Shared types between guest and host
        └── src/lib.rs        # FibonacciOutput, fibonacci()
```

## How It Works

1. **Build** (`./run.sh build`): The guest program (`methods/guest/`) is compiled to a RISC-V ELF via `risc0-build` and embedded into the host binary.
2. **Execute** (`MODE=execute`): Runs the ELF in the RISC Zero zkVM without generating a proof. Reports cycle count.
3. **Prove** (`MODE=prove`): Executes first to get cycle count, then generates a proof in the selected mode (Composite / Succinct / Groth16). Verifies the receipt and reports metrics.

## CUDA (GPU) Proving

RISC Zero supports CUDA-accelerated proving on NVIDIA GPUs. Requirements:

- NVIDIA GPU with sufficient VRAM (>= 24 GB recommended)
- CUDA Toolkit >= 12.x
- CUDA drivers installed

### Build with CUDA

```sh
RISC0_CUDA=1 ./run.sh build
```

This enables the `cuda` feature flag in risc0-zkvm. Unlike SP1, CUDA is a **compile-time only** option — the runtime prover is still `local`.

### Run with CUDA

```sh
N=20 MODE=prove PROOF_MODE=succinct ./run.sh run
```

The local prover automatically uses GPU acceleration when compiled with the `cuda` feature. No special env var needed at runtime.

> **Note:** Switching between CPU and CUDA requires rebuilding (`RISC0_CUDA=1 ./run.sh build`), since CUDA support is a compile-time feature.

## Notes

- Guest ELF is compiled once during `./run.sh build`. Changing `N` or `PROOF_MODE` does NOT require rebuilding - they are runtime inputs.
- One binary supports all three proof modes. Build once, run with different `PROOF_MODE` values.
- Proof generation uses local CPU mode by default (`RISC0_PROVER=local`). For GPU acceleration, rebuild with `RISC0_CUDA=1 ./run.sh build`. For remote proving, use Bonsai (`RISC0_PROVER=bonsai` + `BONSAI_API_KEY`).
