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
