# SP1 SHA-2 Benchmark

SP1 zkVM benchmark using SHA-2 hashing as the guest program, supporting SHA-224/256/384/512 variants and Core, Compressed, Groth16 proof modes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)

## Quick Start

### 1. Build Docker Image

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
```

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
| SHA Variant | SHA-224 / SHA-256 / SHA-384 / SHA-512 |
| Input Size | Size of data hashed (bytes) |
| Cycle Count | Total RISC-V instruction cycles executed |
| Prove Time | Wall-clock time for proof generation |
| Proof Size | Size of the proof (postcard serialized) |
| Verify Time | Wall-clock time for proof verification (skipped for Core) |
| Peak Memory | Maximum RSS during proving (Linux /proc/self/status) |
| Peak CPU | Peak CPU utilization during proving (Linux /proc/self/stat) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `N` | `256` | SHA-2 variant: 224, 256, 384, or 512 |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `core` | `core`, `compressed`, or `groth16` |
| `INPUT_SIZE` | `32` | Input data size in bytes |
| `IMAGE` | `sp1-sha2` | Docker image name |
| `SP1_PROVER` | `cpu` | `cpu` or `network` |

## Project Structure

```
benchmark/
├── utils/                  # Shared benchmark utilities
│   └── src/lib.rs          # Peak memory/CPU monitoring
└── sp1/sha2/
    ├── Dockerfile          # Multi-stage Docker build
    ├── run.sh              # Build/run helper script
    ├── Cargo.toml          # Workspace root
    ├── program/            # Guest program (compiled to RISC-V ELF)
    │   └── src/main.rs     # SHA-2 hashing inside zkVM
    ├── script/             # Host script (prover/verifier)
    │   └── src/bin/main.rs # Benchmark entry point
    └── lib/                # Shared types between guest and host
        └── src/lib.rs      # PublicValuesStruct, sha2_hash()
```

## Notes

- ELF is compiled once during `docker build`. Changing `N`, `INPUT_SIZE`, or `PROOF_MODE` does NOT require rebuilding.
- Input data is deterministic (`0xAB` repeated) for reproducible results.
- Docker Desktop memory should be set to at least 8GB for proving.
