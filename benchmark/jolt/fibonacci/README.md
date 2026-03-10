# Jolt Fibonacci Benchmark

Jolt zkVM benchmark using Fibonacci as the guest program. Jolt uses a sumcheck-based proving system (Lasso/Spartan) and produces a single proof type.

## Prerequisites

This project uses **Dev Containers** for the build environment. You need:

- [Docker](https://www.docker.com/get-started)
- [VS Code](https://code.visualstudio.com/) + [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

## Quick Start

### 1. Open in Dev Container

```
Cmd+Shift+P → "Dev Containers: Open Folder in Container..." → select benchmark/jolt/fibonacci/
```

The container automatically installs Rust nightly, RISC-V target, and `jolt` CLI via `post-create.sh`.

### 2. Build guest ELF and host binary

```sh
jolt build -p fibonacci-guest --backtrace off --stack-size 4096 --heap-size 32768 \
  -- --release --target-dir ./target/jolt-guest/fibonacci-guest-fib --features guest
./run.sh build
```

### 3. Execute (verify correctness, no proof)

```sh
N=20 MODE=execute ./run.sh run
```

### 4. Generate and Verify Proof

```sh
N=20 MODE=prove ./run.sh run
N=32768 MODE=prove ./run.sh run
```

## Proof System

Unlike SP1 and RISC Zero which offer multiple proof modes (Core/Compressed/Groth16), Jolt currently has a **single proof type** based on sumcheck + Lasso lookup arguments + Spartan.

| Feature | Status |
|---------|--------|
| Sumcheck-based proof | Available |
| Zero-knowledge (BlindFold) | Available via `zk` feature |
| Proof compression / recursion | Roadmap |
| On-chain verification (Groth16) | Roadmap |

## Benchmark Metrics

In `--prove` mode, the following metrics are reported:

| Metric | Description |
|--------|-------------|
| Preprocess | Preprocessing time (Dory setup + shared + prover + verifier) |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Serialized proof size |
| Verify Time | Wall-clock time for proof verification |
| Peak Memory | Maximum RSS during proving |
| Peak CPU | Peak CPU utilization during proving |

> **Note:** First run generates the Dory setup (`~/.cache/dory/`), which may take extra time. Subsequent runs load from cache.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `20` | Fibonacci input number |
| `MODE` | `execute` | `execute` or `prove` |
| `RUST_LOG` | `info` | Log level (`info`, `debug`, `trace`) |

## Examples

```sh
# Quick test - execute only
N=20 MODE=execute ./run.sh run

# Benchmark proof generation
N=20 MODE=prove ./run.sh run

# Try different input sizes
N=100 MODE=prove ./run.sh run
N=1000 MODE=prove ./run.sh run
N=32768 MODE=prove ./run.sh run

# Enable debug logging
RUST_LOG=debug N=20 MODE=prove ./run.sh run
```

## Project Structure

```
benchmark/jolt/fibonacci/
├── .devcontainer/
│   ├── devcontainer.json       # Dev Container config (Rust + jolt CLI)
│   └── post-create.sh          # Installs nightly, RISC-V target, jolt CLI
├── run.sh                      # Build/run helper script
├── Cargo.toml                  # Host crate (benchmark entry point)
├── Dockerfile                  # Alternative: Docker-based guest build
├── src/
│   └── main.rs                 # Benchmark with execute/prove modes
└── guest/
    ├── Cargo.toml              # Guest crate (jolt-sdk dependency)
    └── src/
        ├── lib.rs              # Fibonacci with #[jolt::provable] macro
        └── main.rs             # Binary stub (#![no_main])
```

## How It Works

1. **Dev Container**: Opens a Linux container with Rust nightly + `jolt` CLI pre-installed, bypassing macOS security restrictions (Santa).
2. **Build guest**: `jolt build` compiles the guest crate to a RISC-V ELF binary. The `#[jolt::provable]` macro injects a `main()` entry point.
3. **Build host**: `./run.sh build` compiles the host benchmark binary.
4. **Run**: The host detects the pre-built guest ELF and skips runtime compilation. It preprocesses, proves, and verifies.

## Notes

- Guest ELF is pre-built via `jolt build` and detected at `target/jolt-guest/fibonacci-guest-fib/`. If not found, falls back to runtime compilation.
- `max_trace_length` in `guest/src/lib.rs` limits the maximum program size (currently 2^24 = ~16M cycles). Increase if needed for very large N.
- Jolt targets RV64IMAC (64-bit RISC-V), unlike SP1/RISC Zero which use RV32IM.
- Jolt is alpha software and not yet suitable for production use.
