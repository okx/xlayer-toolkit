# RISC Zero SHA-2 Benchmark

RISC Zero zkVM benchmark using SHA-2 hash functions as the guest program, supporting Composite, Succinct, and Groth16 proof modes. Includes an optional SHA-256 precompile mode for accelerated proving.

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
N=256 MODE=execute ./run.sh run
```

### 3. Generate Proof

```sh
# Composite (default, fastest, STARK per segment)
N=256 MODE=prove PROOF_MODE=composite ./run.sh run

# Succinct (aggregated single STARK)
N=256 MODE=prove PROOF_MODE=succinct ./run.sh run

# Groth16 (SNARK, on-chain verifiable, slowest)
N=256 MODE=prove PROOF_MODE=groth16 ./run.sh run
```

### 4. Precompile Mode (SHA-256 only)

Uses RISC Zero's accelerated SHA-256 precompile for faster proving:

```sh
N=256 MODE=prove PROOF_MODE=composite PRECOMPILE=true ./run.sh run
```

## Proof Modes

| Mode | Description | On-chain Verify | Speed |
|------|-------------|-----------------|-------|
| Composite | STARK proof per segment (default) | No | Fast |
| Succinct | Aggregated single STARK | Yes | Medium |
| Groth16 | BN254 SNARK wrapper | Yes | Slow |

## SHA-2 Variants

| Variant | Digest Size | Precompile Support |
|---------|-------------|--------------------|
| SHA-224 | 28 bytes | No |
| SHA-256 | 32 bytes | Yes |
| SHA-384 | 48 bytes | No |
| SHA-512 | 64 bytes | No |

Note: All variants output the first 32 bytes of the digest for uniform comparison.

## Benchmark Metrics

In `--prove` mode, the following metrics are reported:

| Metric | Description |
|--------|-------------|
| SHA Variant | 224 / 256 / 384 / 512 |
| Input Size | Size of input data in bytes |
| Precompile | Whether accelerated precompile is used |
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
| `N` | `256` | SHA-2 variant: `224`, `256`, `384`, or `512` |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `composite` | `composite`, `succinct`, or `groth16` |
| `INPUT_SIZE` | `32` | Size of input data to hash (bytes) |
| `PRECOMPILE` | `false` | `true` to use SHA-256 precompile, `false` for standard |
| `RISC0_PROVER` | `local` | `local` or `bonsai` |
| `RUST_LOG` | `info` | Log level (`info`, `debug`, `trace`) |

## Examples

```sh
# Build
./run.sh build

# Quick test - execute only (seconds)
N=256 MODE=execute ./run.sh run

# Benchmark different SHA variants
N=224 MODE=prove PROOF_MODE=composite ./run.sh run
N=256 MODE=prove PROOF_MODE=composite ./run.sh run
N=384 MODE=prove PROOF_MODE=composite ./run.sh run
N=512 MODE=prove PROOF_MODE=composite ./run.sh run

# Benchmark different proof modes
N=256 MODE=prove PROOF_MODE=composite ./run.sh run
N=256 MODE=prove PROOF_MODE=succinct ./run.sh run
N=256 MODE=prove PROOF_MODE=groth16 ./run.sh run

# Compare standard vs precompile (SHA-256 only)
N=256 MODE=prove PROOF_MODE=composite PRECOMPILE=false ./run.sh run
N=256 MODE=prove PROOF_MODE=composite PRECOMPILE=true ./run.sh run

# Try different input sizes
INPUT_SIZE=64 N=256 MODE=prove PROOF_MODE=composite ./run.sh run
INPUT_SIZE=1024 N=256 MODE=prove PROOF_MODE=composite ./run.sh run

# Enable debug logging
RUST_LOG=debug N=256 MODE=prove PROOF_MODE=composite ./run.sh run
```

## Project Structure

```
benchmark/
├── utils/                         # Shared benchmark utilities
│   └── src/lib.rs                 # Peak memory/CPU monitoring (Linux + macOS)
└── risc0/sha2/
    ├── run.sh                     # Build/run helper script
    ├── Cargo.toml                 # Workspace root
    ├── methods/                   # Guest program build crate
    │   ├── guest/                 # Standard SHA-2 guest (compiled to RISC-V ELF)
    │   │   └── src/main.rs        # SHA-2 logic running inside zkVM
    │   ├── guest-precompile/      # Accelerated SHA-256 guest (uses precompile)
    │   │   └── src/main.rs        # SHA-256 with RISC Zero precompile
    │   ├── build.rs               # risc0_build::embed_methods()
    │   └── src/lib.rs             # Re-exports guest ELFs and IDs
    ├── host/                      # Host program (prover/verifier)
    │   └── src/main.rs            # Benchmark entry point with mode selection
    └── lib/                       # Shared types between guest and host
        └── src/lib.rs             # sha2_hash() host-side implementation
```

## How It Works

1. **Build** (`./run.sh build`): Two guest programs (`methods/guest/` and `methods/guest-precompile/`) are compiled to RISC-V ELFs via `risc0-build` and embedded into the host binary.
2. **Execute** (`MODE=execute`): Runs the selected ELF in the RISC Zero zkVM without generating a proof. Reports cycle count and verifies the digest matches host-side computation.
3. **Prove** (`MODE=prove`): Executes first to get cycle count, then generates a proof in the selected mode (Composite / Succinct / Groth16). Verifies the receipt and reports metrics.

## Notes

- Guest ELFs are compiled once during `./run.sh build`. Changing `N`, `INPUT_SIZE`, or `PROOF_MODE` does NOT require rebuilding - they are runtime inputs.
- The precompile guest (`PRECOMPILE=true`) only supports SHA-256. Both standard and precompile ELFs are compiled during build, so switching `PRECOMPILE` does NOT require rebuilding.
- One binary supports all three proof modes. Build once, run with different `PROOF_MODE` values.
- Proof generation uses local CPU mode by default (`RISC0_PROVER=local`). For faster proving, use Bonsai proving service (`RISC0_PROVER=bonsai` + `BONSAI_API_KEY`).
