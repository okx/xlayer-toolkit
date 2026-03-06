# RISC Zero Fibonacci Benchmark

RISC Zero zkVM benchmark using Fibonacci as the guest program, supporting Composite, Succinct, and Groth16 proof modes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)

## Quick Start

### 1. Build Docker Image

Compiles the guest ELF and host binary into the image (only need to do this once, or when source changes):

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
| Peak Memory | Maximum RSS during proving (Linux /proc/self/status) |
| Peak CPU | Peak CPU utilization during proving (Linux /proc/self/stat) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `20` | Fibonacci input number |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `composite` | `composite`, `succinct`, or `groth16` |
| `IMAGE` | `risc0-fibonacci` | Docker image name |
| `RISC0_PROVER` | `local` | `local` or `bonsai` |

## Examples

```sh
# Build image
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
```

## Project Structure

```
benchmark/
├── utils/                    # Shared benchmark utilities
│   └── src/lib.rs            # Peak memory/CPU monitoring
└── risc0/fibonacci/
    ├── Dockerfile            # Multi-stage Docker build
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

1. **Build** (`./run.sh build`): Docker compiles the guest program (`methods/guest/`) to a RISC-V ELF via the RISC Zero toolchain, then embeds it into the host binary via `risc0_build::embed_methods()`.
2. **Execute** (`MODE=execute`): Runs the ELF in the RISC Zero zkVM without generating a proof. Reports cycle count.
3. **Prove** (`MODE=prove`): Executes first to get cycle count, then generates a proof in the selected mode (Composite / Succinct / Groth16). Verifies the receipt and reports metrics.

## Notes

- ELF is compiled once during `docker build`. Changing `N` or `PROOF_MODE` does NOT require rebuilding - they are runtime inputs.
- One image supports all three proof modes. Build once, run with different `PROOF_MODE` values.
- Proof generation uses local CPU mode by default (`RISC0_PROVER=local`). For faster proving, use Bonsai proving service (`RISC0_PROVER=bonsai` + `BONSAI_API_KEY`).
- Docker Desktop memory should be set to at least 8GB for proving.
