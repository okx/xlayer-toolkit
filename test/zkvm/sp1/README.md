# SP1 zkVM Exploration

This project explores [SP1](https://github.com/succinctlabs/sp1) zkVM execution to evaluate its compatibility with multi-threaded programs.

> **Note**: This exploration focuses on **execution simulation only** — no proof generation is required.

## Requirements

- [Rust](https://rustup.rs/)
- [SP1](https://docs.succinct.xyz/docs/sp1/getting-started/install)

## Running the Project

### Build the Program

The program is automatically built through `script/build.rs` when the script is built.

### Execute the Program

To run the program in simulation mode (without generating a proof):

```sh
cd script
cargo run --release -- --execute
```

This will execute the program inside the SP1 zkVM simulator and display the output. The `--execute` flag runs the program without generating any cryptographic proofs, which is sufficient for:

- Verifying program correctness
- Testing zkVM compatibility
- Benchmarking execution performance
- Exploring multi-threading behavior

## Why Execution Only?

For the purpose of exploring zkVM compatibility with multi-threaded execution patterns, we only need to verify that:

1. The program compiles successfully for the SP1 target
2. The program executes correctly inside the zkVM environment
3. The zkVM handles (or rejects) multi-threading constructs as expected

Proof generation is computationally expensive and not necessary for this exploration phase.
