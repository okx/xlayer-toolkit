# zkVM Benchmark Suite

Benchmarks for SP1, RISC Zero, and Jolt across Fibonacci and SHA-2 workloads.

## Quick Start

```bash
# 1. Build
cd <framework>/<benchmark>
./run.sh build        # Build all variants (CPU + GPU for SP1/RISC0)

# 2. Run
MODE=prove ./run.sh run
```

## Directory Structure

```
benchmark/
  sp1/fibonacci/       # SP1 Fibonacci
  sp1/sha2/            # SP1 SHA-2
  risc0/fibonacci/     # RISC Zero Fibonacci
  risc0/sha2/          # RISC Zero SHA-2
  jolt/fibonacci/      # Jolt Fibonacci
  jolt/sha2/           # Jolt SHA-2
  utils/               # Shared benchmark utilities (peak memory monitor)
```

---

## Prerequisites

### SP1

```bash
# Install SP1 toolchain
curl -L https://sp1.succinct.xyz | bash
sp1up

# (Optional) Groth16 circuit params (~1GB, only needed for PROOF_MODE=groth16)
cd sp1/fibonacci && ./run.sh download-params
cd sp1/sha2      && ./run.sh download-params
```

### RISC Zero

```bash
# Install RISC Zero toolchain
curl -L https://risczero.com/install | bash
rzup install rust
rzup install cpp

# (Optional) Pre-download recursion circuit artifacts (~100MB, speeds up build)
cd risc0/fibonacci && ./run.sh download-params
cd risc0/sha2      && ./run.sh download-params

# (Optional) Groth16 prover (~2.2GB, only needed for PROOF_MODE=groth16, x86 only)
rzup install risc0-groth16
```

### Jolt

```bash
# Install RISC-V target and Jolt CLI
rustup target add riscv64imac-unknown-none-elf
cd jolt/fibonacci && ./run.sh install-cli
```

### Ubuntu GPU Machine

```bash
# One-click setup script (system deps, Go, Rust, SP1, RISC Zero, Docker)
./setup-ubuntu.sh
```

---

## SP1 Fibonacci

```bash
cd sp1/fibonacci
```

### Build

```bash
./run.sh build          # Build both CPU and GPU binaries
./run.sh build-cpu      # CPU only
./run.sh build-gpu      # GPU only (requires CUDA)
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `20` | Fibonacci number to compute |
| `MODE` | `execute` | `execute` (dry run) or `prove` (generate proof) |
| `PROOF_MODE` | `core` | `core`, `compressed`, or `groth16` |
| `SP1_PROVER` | `cpu` | `cpu` or `cuda` (auto-selects binary) |

```bash
# Execute only (get cycle count, no proof)
N=20 MODE=execute ./run.sh run

# Prove with CPU
N=20 MODE=prove PROOF_MODE=core ./run.sh run

# Prove with GPU
N=20 MODE=prove PROOF_MODE=core SP1_PROVER=cuda ./run.sh run

# Prove with compressed proof
N=20 MODE=prove PROOF_MODE=compressed ./run.sh run

# Prove with Groth16 (requires download-params)
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run
```

---

## SP1 SHA-2

```bash
cd sp1/sha2
```

### Build

```bash
./run.sh build          # Build both CPU and GPU binaries
./run.sh build-cpu      # CPU only
./run.sh build-gpu      # GPU only (requires CUDA)
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `256` | SHA variant: `224`, `256`, `384`, `512` |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `core` | `core`, `compressed`, `groth16` |
| `INPUT_SIZE` | `32` | Input data size in bytes |
| `PRECOMPILE` | `false` | `true` to use SP1 SHA-256 precompile (accelerated syscall) |
| `SP1_PROVER` | `cpu` | `cpu` or `cuda` |

```bash
# Execute SHA-256 with 32 bytes input
N=256 MODE=execute ./run.sh run

# Prove SHA-256 with CPU
N=256 MODE=prove PROOF_MODE=core INPUT_SIZE=32 ./run.sh run

# Prove SHA-256 with GPU
N=256 MODE=prove PROOF_MODE=core SP1_PROVER=cuda ./run.sh run

# Prove with precompile (accelerated SHA-256)
N=256 MODE=prove PROOF_MODE=core PRECOMPILE=true ./run.sh run

# Prove SHA-512
N=512 MODE=prove PROOF_MODE=core INPUT_SIZE=64 ./run.sh run
```

---

## RISC Zero Fibonacci

```bash
cd risc0/fibonacci
```

### Build

```bash
./run.sh build          # Build both CPU and GPU binaries
./run.sh build-cpu      # CPU only
./run.sh build-gpu      # GPU only (requires CUDA)
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `20` | Fibonacci number to compute |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `composite` | `composite`, `succinct`, `groth16` |
| `RISC0_CUDA` | (unset) | Set to `1` to select GPU binary |

```bash
# Execute only
N=20 MODE=execute ./run.sh run

# Prove with CPU (composite)
N=20 MODE=prove PROOF_MODE=composite ./run.sh run

# Prove with GPU
N=20 MODE=prove PROOF_MODE=composite RISC0_CUDA=1 ./run.sh run

# Prove with succinct proof
N=20 MODE=prove PROOF_MODE=succinct ./run.sh run

# Prove with Groth16 (requires rzup install risc0-groth16)
N=20 MODE=prove PROOF_MODE=groth16 ./run.sh run
```

---

## RISC Zero SHA-2

```bash
cd risc0/sha2
```

### Build

```bash
./run.sh build          # Build both CPU and GPU binaries
./run.sh build-cpu      # CPU only
./run.sh build-gpu      # GPU only (requires CUDA)
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `256` | SHA variant: `224`, `256`, `384`, `512` |
| `MODE` | `execute` | `execute` or `prove` |
| `PROOF_MODE` | `composite` | `composite`, `succinct`, `groth16` |
| `INPUT_SIZE` | `32` | Input data size in bytes |
| `PRECOMPILE` | `false` | `true` to use RISC Zero SHA-256 precompile |
| `RISC0_CUDA` | (unset) | Set to `1` to select GPU binary |

```bash
# Execute SHA-256
N=256 MODE=execute ./run.sh run

# Prove with CPU
N=256 MODE=prove PROOF_MODE=composite INPUT_SIZE=32 ./run.sh run

# Prove with GPU
N=256 MODE=prove PROOF_MODE=composite RISC0_CUDA=1 ./run.sh run

# Prove with precompile
N=256 MODE=prove PROOF_MODE=composite PRECOMPILE=true ./run.sh run
```

---

## Jolt Fibonacci

```bash
cd jolt/fibonacci
```

### Build

```bash
./run.sh install-cli    # One-time: install Jolt CLI
./run.sh build          # Build guest ELF + host binary
./run.sh build-guest    # Guest ELF only
./run.sh build-host     # Host binary only
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `20` | Fibonacci number to compute |
| `MODE` | `execute` | `execute` or `prove` |

```bash
# Execute only
N=20 MODE=execute ./run.sh run

# Prove
N=20 MODE=prove ./run.sh run
```

> Jolt is CPU-only, no GPU support.

---

## Jolt SHA-2

```bash
cd jolt/sha2
```

### Build

```bash
./run.sh install-cli    # One-time: install Jolt CLI
./run.sh build          # Build guest ELFs + host binary
./run.sh build-guest    # Guest ELFs only
./run.sh build-host     # Host binary only
```

### Run

| Env Var | Default | Description |
|---------|---------|-------------|
| `N` | `1000` | Number of SHA-256 iterations |
| `MODE` | `execute` | `execute` or `prove` |
| `INLINE` | `false` | `true` to use inline SHA-256 implementation |

```bash
# Execute
N=1000 MODE=execute ./run.sh run

# Prove (native SHA-256)
N=1000 MODE=prove ./run.sh run

# Prove (inline SHA-256)
N=1000 MODE=prove INLINE=true ./run.sh run
```

> Jolt is CPU-only, no GPU support.

---

## Output Metrics

All benchmarks in prove mode report:

| Metric | Description |
|--------|-------------|
| **Cycle Count** | Total guest instruction count |
| **Prove Time** | Wall-clock time for proof generation |
| **Proof Size** | Serialized proof size in bytes/KB |
| **Verify Time** | Time to verify the proof (skipped for Core/Composite) |
| **Peak Memory** | Peak RSS memory during proving (MB) |
| **Peak CPU** | Peak CPU utilization (%) |

---

## CPU vs GPU Comparison

Build once, run both:

```bash
# SP1 example
cd sp1/fibonacci
./run.sh build                                          # Builds fibonacci-cpu + fibonacci-gpu

N=32768 MODE=prove PROOF_MODE=core ./run.sh run                       # CPU
N=32768 MODE=prove PROOF_MODE=core SP1_PROVER=cuda ./run.sh run       # GPU

# RISC Zero example
cd risc0/fibonacci
./run.sh build                                          # Builds fibonacci-bench-cpu + fibonacci-bench-gpu

N=20 MODE=prove PROOF_MODE=composite ./run.sh run                     # CPU
N=20 MODE=prove PROOF_MODE=composite RISC0_CUDA=1 ./run.sh run        # GPU
```

---

## Proof Mode Comparison

| | SP1 | RISC Zero | Jolt |
|---|---|---|---|
| **Basic** | `core` | `composite` | (single mode) |
| **Compressed** | `compressed` | `succinct` | N/A |
| **On-chain (Groth16)** | `groth16` | `groth16` | N/A |
| **Params Required** | Groth16 only (~1GB) | Groth16 only (~2.2GB) | None |
