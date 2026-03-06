# SP1 Fibonacci Benchmark

SP1 zkVM benchmark using Fibonacci as the guest program, supporting Core, Compressed, and Groth16 proof modes.

## Prerequisites

- [Rust](https://rustup.rs/)
- [Docker](https://docs.docker.com/get-docker/) (for guest ELF compilation via `sp1-build`)

## Quick Start

### 1. Build

Guest ELF is compiled inside Docker (via `sp1-build` with `docker: true`), host binary is compiled natively. No SP1 toolchain needed on the host.

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
| Peak Memory | Maximum RSS during proving |
| Peak CPU | Peak CPU utilization during proving |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `20` | Fibonacci input number |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `core` | `core`, `compressed`, or `groth16` |
| `SP1_PROVER` | `cpu` | `cpu` or `network` |
| `RUST_LOG` | `info` | Log level (`info`, `debug`, `trace`) |

## Examples

```sh
# Build
./run.sh build

# Quick test — execute only (seconds)
N=20 MODE=execute ./run.sh run

# Benchmark Core proof
N=20 MODE=prove PROOF_MODE=core ./run.sh run

# Benchmark Compressed proof
N=20 MODE=prove PROOF_MODE=compressed ./run.sh run

# Benchmark Groth16 proof (requires download-params first)
./run.sh download-params
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run

# Try different input sizes
N=100 MODE=prove PROOF_MODE=core ./run.sh run
N=1000 MODE=prove PROOF_MODE=core ./run.sh run

# Enable debug logging for detailed SP1 statistics
RUST_LOG=debug N=20 MODE=prove PROOF_MODE=core ./run.sh run
```

## Project Structure

```
benchmark/
├── utils/                  # Shared benchmark utilities
│   └── src/lib.rs          # Peak memory/CPU monitoring
└── sp1/fibonacci/
    ├── run.sh              # Build/run helper script
    ├── Cargo.toml          # Workspace root
    ├── program/            # Guest program (compiled to RISC-V ELF)
    │   └── src/main.rs     # Fibonacci logic running inside zkVM
    ├── script/             # Host script (prover/verifier)
    │   ├── build.rs        # sp1-build with docker: true
    │   └── src/bin/main.rs # Benchmark entry point with mode selection
    └── lib/                # Shared types between guest and host
        └── src/lib.rs      # PublicValuesStruct, fibonacci()
```

## How It Works

1. **Build** (`./run.sh build`): The guest program (`program/`) is compiled to a RISC-V ELF inside Docker via `sp1-build` (`docker: true` in `build.rs`). The host binary is compiled natively on the host and embeds the ELF via `include_elf!`.
2. **Execute** (`MODE=execute`): Runs the ELF in the SP1 zkVM without generating a proof. Reports cycle count.
3. **Prove** (`MODE=prove`): Runs setup, then generates a proof in the selected mode (Core / Compressed / Groth16). Verifies the proof for Compressed and Groth16 modes.

## Notes

- Guest ELF is compiled once during `./run.sh build`. Changing `N` or `PROOF_MODE` does NOT require rebuilding — they are runtime inputs.
- One binary supports all three proof modes. Build once, run with different `PROOF_MODE` values.
- Proof generation uses CPU mode by default (`SP1_PROVER=cpu`). For faster proving, use Succinct's prover network (`SP1_PROVER=network` + `NETWORK_PRIVATE_KEY`).
- Groth16 mode requires pre-downloading circuit params: `./run.sh download-params`.
