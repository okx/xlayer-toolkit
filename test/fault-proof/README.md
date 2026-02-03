# Fault Proof FPVM Examples

An independent Fault Proof VM (FPVM) example project demonstrating how to write programs that run in the Optimism Fault Proof system.

## 📁 Project Structure

```
fault-proof/
├── Cargo.toml          # Workspace configuration
├── Cargo.lock          # Dependency lock file
├── justfile            # Build and run scripts
├── README.md           # This file
└── bin/                # Example program directory
    ├── Cargo.toml      # Fibonacci program configuration
    └── src/
        └── main.rs     # Fibonacci source code
```

## 🎯 Supported Target Platforms

This project can compile and run on three different platforms:

1. **Native** - Standard x86_64/ARM64 binary for local development and testing
2. **Cannon (MIPS64)** - Runs in Cannon FPVM for fault proof verification
3. **Asterisc (RISC-V64)** - Runs in Asterisc FPVM for fault proof verification

## 📋 Prerequisites

### Required

- **Rust**: Version 1.88 or higher
- **Just**: Command-line tool
  ```bash
  cargo install just
  ```

### Optional (for FPVM targets)

- **Docker**: For cross-compiling to MIPS64 and RISC-V64
- **cannon**: Cannon FPVM emulator (for running MIPS64 version)
- **rvgo**: Asterisc FPVM emulator (for running RISC-V64 version)

#### Installing Asterisc

```bash
git clone --depth 1 https://github.com/ethereum-optimism/asterisc.git
cd asterisc && git checkout v1.3.0
make build-rvgo && cd rvgo && go install .
```

#### Installing Cannon

```bash
git clone --depth 1 https://github.com/ethereum-optimism/optimism.git
cd optimism/cannon && go install .
```

## 🚀 Quick Start

### View All Available Commands

```bash
just --list
```

## 🔨 Build Commands

### Build Native Binary

```bash
just build
```

Compiles the program for your local machine (x86_64 or ARM64).

### Build Cannon (MIPS64) Binary

```bash
just build-cannon
```

Cross-compiles to MIPS64 architecture using Docker. The binary will be located at:
```
target/mips64-unknown-none/release-client-lto/fibonacci
```

### Build Asterisc (RISC-V64) Binary

```bash
just build-asterisc
```

Cross-compiles to RISC-V64 architecture using Docker. The binary will be located at:
```
target/riscv64imac-unknown-none-elf/release-client-lto/fibonacci
```

### Build All Versions

```bash
just build-all
```

Builds native, Cannon, and Asterisc versions in sequence.

## ▶️ Run Commands

### Run Native Version

```bash
just run
```

Builds and executes the native binary directly on your machine.

### Run Cannon (MIPS64) Version

```bash
just run-cannon
```

Builds the MIPS64 binary, loads it into Cannon FPVM, and executes it. Requires `cannon` to be installed.

### Run Asterisc (RISC-V64) Version

```bash
just run-asterisc
```

Builds the RISC-V64 binary, loads it into Asterisc FPVM, and executes it. Requires `rvgo` to be installed.

### Run All Versions

```bash
just run-all
```

Runs native, Cannon, and Asterisc versions in sequence.

## 🧹 Clean Commands

### Clean Generated State Files

```bash
just clean
```

Removes generated FPVM state files (`state-*.bin.gz`, `meta.json`).

### Clean All Build Artifacts

```bash
just clean-all
```

Removes all build artifacts and state files.

## 📚 Example Program

### Fibonacci Calculator

A simple Fibonacci sequence calculator that demonstrates:
- How to use `kona-std-fpvm` for I/O operations
- How to use the `#[client_entry]` macro to simplify program entry
- How to write Rust programs in a `no_std` environment
- How to run the same code on multiple FPVM platforms

## 🔧 Dependencies

This project depends on the following libraries (automatically fetched from GitHub):

- **kona-std-fpvm**: FPVM standard library providing I/O, memory management, and other features
- **kona-std-fpvm-proc**: Provides the `#[client_entry]` macro
- **kona-preimage**: PreimageOracle bindings (indirect dependency)

These dependencies come from the [ethereum-optimism/optimism](https://github.com/ethereum-optimism/optimism/tree/develop/kona) repository.

## 📖 Related Resources

- [Optimism Fault Proof Specification](https://specs.optimism.io/experimental/fault-proof/index.html)
- [Kona Project](https://github.com/ethereum-optimism/optimism/tree/develop/kona)
- [Cannon FPVM](https://github.com/ethereum-optimism/optimism/tree/develop/cannon)
- [Asterisc FPVM](https://github.com/ethereum-optimism/asterisc)
