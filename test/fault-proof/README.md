# Fault Proof FPVM Examples

Example project demonstrating how to write programs that run in the Optimism Fault Proof VM system.

## 📁 Project Structure

```
fault-proof/
├── Cargo.toml          # Workspace configuration
├── justfile            # Build and run scripts
└── bin/                # Example program
    ├── Cargo.toml
    └── src/main.rs     # Fibonacci calculator
```

## 🎯 Supported Platforms

1. **Native** - x86_64/ARM64 for local testing
2. **Cannon (MIPS64)** - Fault proof verification
3. **Asterisc (RISC-V64)** - Fault proof verification

## 📋 Prerequisites

**Required:**
- Rust 1.88+
- Just: `cargo install just`

**Optional (for FPVM):**
- Docker (for cross-compilation)
- `cannon` (for MIPS64):
  ```bash
  git clone --depth 1 https://github.com/ethereum-optimism/optimism.git
  cd optimism/cannon && go install .
  ```
- `rvgo` (for RISC-V64):
  ```bash
  git clone --depth 1 https://github.com/ethereum-optimism/asterisc.git
  cd asterisc && git checkout v1.3.0
  make build-rvgo && cd rvgo && go install .
  ```

## 🚀 Usage

### Native

```bash
# Build and run
just run

# Or build only
just build
```

### Cannon (MIPS64)

```bash
# Build and run in Cannon FPVM
just run-cannon

# Or build only
just build-cannon
# Output: target/mips64-unknown-none/release-client-lto/fibonacci
```

### Asterisc (RISC-V64)

```bash
# Build and run in Asterisc FPVM
just run-asterisc

# Or build only
just build-asterisc
# Output: target/riscv64imac-unknown-none-elf/release-client-lto/fibonacci
```

### All Platforms

```bash
# Build all
just build-all

# Run all
just run-all
```

## 🐳 Docker Execution (No Local Installation)

If you don't want to install `cannon` or `asterisc` locally, you can use official Docker images from OP Labs.

### Docker Images

| Tool | Image | Versions |
|------|-------|----------|
| Cannon | `us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon` | v1.0.0, v1.2.0, v1.3.0, v1.4.0, v1.6.0 |
| Asterisc | `us-docker.pkg.dev/oplabs-tools-artifacts/images/asterisc` | v1.2.0, v1.3.0, latest |
| Cannon Builder | `ghcr.io/op-rs/kona/cannon-builder` | 0.3.0 |
| Asterisc Builder | `ghcr.io/op-rs/kona/asterisc-builder` | 0.3.0 |

### Pull Docker Images

```bash
# Pull Cannon image
just pull-cannon-image

# Pull Asterisc image
just pull-asterisc-image
```

### Run with Docker

```bash
# Run Cannon FPVM using Docker
just run-cannon-docker

# Run Asterisc FPVM using Docker
just run-asterisc-docker

# Run all (native + Docker for FPVM)
just run-all-docker
```

### How It Works

1. **Build**: Uses `cannon-builder` / `asterisc-builder` images containing cross-compilation toolchains
2. **Run**: Uses official `cannon` / `asterisc` images to execute the compiled binary in FPVM

Example workflow for Cannon:
```bash
# 1. Build (uses cannon-builder image)
docker run --rm -v $(pwd):/workdir -w /workdir \
  ghcr.io/op-rs/kona/cannon-builder:0.3.0 \
  cargo build -Zbuild-std=core,alloc -p fibonacci-fpvm --profile release-client-lto

# 2. Load ELF (uses cannon image)
docker run --rm -v $(pwd):/workdir -w /workdir \
  --entrypoint /usr/local/bin/cannon \
  us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon:v1.6.0 \
  load-elf --type multithreaded64-5 \
    --path=/workdir/target/mips64-unknown-none/release-client-lto/fibonacci \
    --out=/workdir/bin/state-cannon.bin.gz

# 3. Run FPVM (uses cannon image)
docker run --rm -v $(pwd):/workdir -w /workdir \
  --entrypoint /usr/local/bin/cannon \
  us-docker.pkg.dev/oplabs-tools-artifacts/images/cannon:v1.6.0 \
  run --input /workdir/bin/state-cannon.bin.gz --info-at '%100000'
```

### Clean

```bash
# Clean state files
just clean

# Clean all artifacts
just clean-all
```

## 📚 Example: Fibonacci Calculator

Simple program demonstrating:
- `kona-std-fpvm` for I/O operations
- `#[client_entry]` macro for program entry
- `no_std` Rust programming
- Cross-platform FPVM execution

## 🔧 Dependencies

Dependencies are automatically fetched from [ethereum-optimism/optimism](https://github.com/ethereum-optimism/optimism/tree/develop/kona):

- `kona-std-fpvm` - FPVM standard library
- `kona-std-fpvm-proc` - Entry point macro
- `kona-preimage` - PreimageOracle bindings

## 📖 Resources

- [Optimism Fault Proof Spec](https://specs.optimism.io/experimental/fault-proof/index.html)
- [Kona Project](https://github.com/ethereum-optimism/optimism/tree/develop/kona)
- [Cannon FPVM](https://github.com/ethereum-optimism/optimism/tree/develop/cannon)
- [Asterisc FPVM](https://github.com/ethereum-optimism/asterisc)
