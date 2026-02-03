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

## ✨ Features

- **Fully Independent**: Dependencies referenced via GitHub repository, no local code copying required
- **Multi-Platform Support**: Supports native execution, Cannon (MIPS64), and Asterisc (RISC-V64)
- **Easy to Use**: Build and run with `just` commands
- **Lightweight**: Contains only necessary code and configuration

## 🚀 Quick Start

### 1. View All Available Commands

```bash
just --list
```

### 2. Build and Run

```bash
# Build and run native version
just run

# Build all versions (native + Cannon + Asterisc)
just build-all

# Run Cannon (MIPS64) version
just run-cannon

# Run Asterisc (RISC-V64) version
just run-asterisc
```

## 📋 Prerequisites

### Required

- **Rust**: Version 1.88 or higher
- **Just**: Command-line tool
  ```bash
  cargo install just
  ```

### Optional (for cross-compilation and execution)

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

## 📚 Example Programs

### Fibonacci Calculator

A Fibonacci sequence calculator program that demonstrates:
- How to use `kona-std-fpvm` for I/O operations
- How to use the `#[client_entry]` macro to simplify program entry
- How to write Rust programs in a `no_std` environment
- How to run on multiple FPVM platforms

## 🔧 Dependencies

This project depends on the following libraries (automatically fetched from GitHub):

- **kona-std-fpvm**: FPVM standard library providing I/O, memory management, and other features
- **kona-std-fpvm-proc**: Provides the `#[client_entry]` macro
- **kona-preimage**: PreimageOracle bindings (indirect dependency)

These dependencies come from the [ethereum-optimism/optimism](https://github.com/ethereum-optimism/optimism/tree/develop/kona) repository.

## 🛠️ Development

### Building the Project

```bash
# Build native version
just build

# Build all versions
just build-all
```

### Cleaning Build Artifacts

```bash
# Clean generated state files
just clean

# Clean all build artifacts
just clean-all
```

## 📖 Related Resources

- [Optimism Fault Proof Specification](https://specs.optimism.io/experimental/fault-proof/index.html)
- [Kona Project](https://github.com/ethereum-optimism/optimism/tree/develop/kona)
- [Cannon FPVM](https://github.com/ethereum-optimism/optimism/tree/develop/cannon)
- [Asterisc FPVM](https://github.com/ethereum-optimism/asterisc)

## 📄 License

MIT License
