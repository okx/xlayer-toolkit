# Jolt + ZeroOS Multi-threaded Test

Multi-threaded parallel computation test using Jolt zkVM and ZeroOS.

Based on [jolt-on-zeroos](https://github.com/zouguangxian/jolt-on-zeroos).

## Quick Start (Devcontainer)

1. Open this directory in Cursor / VS Code
2. Click the bottom-left `><` icon → **"Reopen in Container"**
3. Wait for the container to build (auto-installs Rust 1.90 + cargo-jolt)
4. Run:
   ```bash
   ./bootstrap

   cargo run --release -p multithread-test
   ```

## Test Description

- **Task**: 4 threads compute partial sums of 1+2+...+n in parallel, then aggregate
- **Result**: Always deterministic (n*(n+1)/2)
- **Key Feature**: Thread scheduling in ZeroOS is cooperative and deterministic

## Project Structure

```
jolt/
├── .devcontainer/           # Devcontainer config
├── .cargo/config.toml
├── bootstrap                # Install cargo-jolt
├── Cargo.toml               # Workspace config
├── rust-toolchain.toml      # Rust 1.90 (ZeroOS compatible)
└── crates/
    └── multithread-test/
        ├── guest/           # Guest program (runs inside zkVM)
        │   ├── Cargo.toml
        │   └── src/
        │       ├── lib.rs   # #[jolt::provable] multi-thread logic
        │       └── main.rs
        └── host/            # Host program (prover/verifier)
            ├── Cargo.toml
            └── src/
                └── main.rs
```

## Key Features

- `guest-std`: Enable std via ZeroOS + musl
- `thread`: Enable std::thread via ZeroOS cooperative scheduler
- `stdout`: Enable println! via ZeroOS VFS
