# SP1 Fibonacci Benchmark

SP1 zkVM benchmark using Fibonacci as the guest program, supporting Core, Compressed, and Groth16 proof modes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)

## Quick Start

### 1. Build Docker Image

Compiles the guest ELF and script binary into the image (only need to do this once, or when source changes):

```sh
./run.sh build
```

### 2. Execute (verify correctness, no proof)

```sh
N=20 MODE=execute ./run.sh run
```

### 3. Generate Proof

```sh
# Core (default, fastest, not on-chain verifiable)
N=20 MODE=prove PROOF_MODE=core ./run.sh run

# Compressed (recursive STARK compression)
N=20 MODE=prove PROOF_MODE=compressed ./run.sh run

# Groth16 (SNARK, on-chain verifiable, slowest)
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run
```

## Proof Modes

| Mode | Description | On-chain Verify | Speed |
|------|-------------|-----------------|-------|
| Core | Raw STARK proof, no compression | No | Fast |
| Compressed | Recursively compressed STARK | Yes | Medium |
| Groth16 | SNARK wrapper over compressed proof | Yes | Slow |

## Benchmark Metrics

In `--prove` mode, the following metrics are reported:

| Metric | Description |
|--------|-------------|
| Proof Mode | Core / Compressed / Groth16 |
| Cycle Count | Total RISC-V instruction cycles executed |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Size of the proof (postcard serialized) |
| Verify Time | Wall-clock time for proof verification (skipped for Core) |
| Peak Memory | Maximum RSS during proving (Linux /proc/self/status) |
| Peak CPU | Peak CPU utilization during proving (Linux /proc/self/stat) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `20` | Fibonacci input number |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `core` | `core`, `compressed`, or `groth16` |
| `IMAGE` | `sp1-fibonacci` | Docker image name |
| `SP1_PROVER` | `cpu` | `cpu` or `network` |

## Examples

```sh
# Build image
./run.sh build

# Quick test — execute only (seconds)
N=20 MODE=execute ./run.sh run

# Benchmark Core proof
N=20 MODE=prove PROOF_MODE=core ./run.sh run

# Benchmark Compressed proof
N=20 MODE=prove PROOF_MODE=compressed ./run.sh run

# Benchmark Groth16 proof
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run

# Try different input sizes
N=100 MODE=prove PROOF_MODE=core ./run.sh run
N=1000 MODE=prove PROOF_MODE=core ./run.sh run
```

## Project Structure

```
benchmark/
├── utils/                  # Shared benchmark utilities
│   └── src/lib.rs          # Peak memory/CPU monitoring
└── sp1/fibonacci/
    ├── Dockerfile          # Multi-stage Docker build
    ├── run.sh              # Build/run helper script
    ├── Cargo.toml          # Workspace root
    ├── program/            # Guest program (compiled to RISC-V ELF)
    │   └── src/main.rs     # Fibonacci logic running inside zkVM
    ├── script/             # Host script (prover/verifier)
    │   └── src/bin/main.rs # Benchmark entry point with mode selection
    └── lib/                # Shared types between guest and host
        └── src/lib.rs      # PublicValuesStruct, fibonacci()
```

## How It Works

1. **Build** (`./run.sh build`): Docker compiles the guest program (`program/`) to a RISC-V ELF via the SP1 toolchain, then embeds it into the host binary via `include_elf!`.
2. **Execute** (`MODE=execute`): Runs the ELF in the SP1 zkVM without generating a proof. Reports cycle count.
3. **Prove** (`MODE=prove`): Runs setup, then generates a proof in the selected mode (Core → Compressed → Groth16). Verifies the proof for Compressed and Groth16 modes.

## Notes

- ELF is compiled once during `docker build`. Changing `N` or `PROOF_MODE` does NOT require rebuilding — they are runtime inputs.
- One image supports all three proof modes. Build once, run with different `PROOF_MODE` values.
- Proof generation uses CPU mode by default (`SP1_PROVER=cpu`). For faster proving, use Succinct's prover network (`SP1_PROVER=network` + `NETWORK_PRIVATE_KEY`).
- Docker Desktop memory should be set to at least 8GB for proving.
