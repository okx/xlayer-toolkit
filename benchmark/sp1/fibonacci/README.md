# SP1 Fibonacci Benchmark (Hypercube)

SP1 zkVM benchmark using Fibonacci as the guest program, with compressed (Hypercube) proof mode.

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
N=20 MODE=execute ./run.sh
```

### 3. Generate Proof (Hypercube compressed)

```sh
N=20 MODE=prove ./run.sh
```

## Benchmark Metrics

In `--prove` mode, the following metrics are reported:

| Metric | Description |
|--------|-------------|
| Cycle Count | Total RISC-V instruction cycles executed |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Size of the compressed proof (JSON serialized) |
| Verify Time | Wall-clock time for proof verification |
| Peak Memory | Maximum RSS during proving (Linux /proc/self/status) |
| Peak CPU | Peak CPU utilization during proving (Linux /proc/self/stat) |

## Examples

```sh
# Build image
./run.sh build

# Quick test — execute only (seconds)
N=20 MODE=execute ./run.sh

# Full benchmark — generate & verify proof (minutes)
N=20 MODE=prove ./run.sh

# Try different input sizes
N=100 MODE=prove ./run.sh
N=1000 MODE=prove ./run.sh
```

## Project Structure

```
fibonacci/
├── Dockerfile          # Multi-stage Docker build
├── run.sh              # Build/run helper script
├── rust-toolchain      # Rust toolchain config for SP1
├── Cargo.toml          # Workspace root
├── program/            # Guest program (compiled to RISC-V ELF)
│   └── src/main.rs     # Fibonacci logic running inside zkVM
├── script/             # Host script (prover/verifier)
│   └── src/bin/main.rs # Benchmark entry point with metrics collection
└── lib/                # Shared types between guest and host
    └── src/lib.rs      # PublicValuesStruct, fibonacci()
```

## How It Works

1. **Build** (`./run.sh build`): Docker compiles the guest program (`program/`) to a RISC-V ELF via the SP1 toolchain, then embeds it into the host binary via `include_elf!`.
2. **Execute** (`MODE=execute`): Runs the ELF in the SP1 zkVM without generating a proof. Reports cycle count.
3. **Prove** (`MODE=prove`): Runs setup (derives proving key from ELF), then generates a compressed STARK proof (Hypercube), and verifies it. Reports all 6 benchmark metrics.

## Notes

- ELF is compiled once during `docker build`. Changing `N` does NOT require rebuilding — `N` is a runtime input via `SP1Stdin`.
- Proof generation uses CPU mode by default (`SP1_PROVER=cpu`). For faster proving, use Succinct's prover network (`SP1_PROVER=network` + `NETWORK_PRIVATE_KEY`).
- Docker Desktop memory should be set to at least 8GB for proving.
