# multithread-test host

Host-side driver for the Jolt zkVM multi-threaded computation test.

## Binaries

| Binary | Command | Description |
|--------|---------|-------------|
| `multithread-test` | `cargo run --release -p multithread-test --bin multithread-test` | Full zkVM flow: compile guest → prove → verify |
| `native` | `cargo run --release -p multithread-test --bin native` | Run guest logic directly on host, no proof generation |

## `main.rs` — Full zkVM Flow

### Overview

```
compile_compute_sum()        Build guest → RISC-V ELF (via cargo-jolt)
        ↓
preprocess_*()               Generate proving key / verifying key
        ↓
analyze_compute_sum(n)       Dry-run to inspect trace length
        ↓
prove_compute_sum(n)         Execute guest inside zkVM, record trace, generate proof
        ↓                    → returns (output, proof, program_io)
verify_compute_sum(...)      Verify proof cryptographically (no re-execution needed)
```

### Stage 1 — Logging setup

```rust
tracing_subscriber::fmt()
    .with_env_filter(
        tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
    )
    .init();
```

Initializes structured logging. Reads log level from the `RUST_LOG` environment variable;
defaults to `info` if not set. This is why each output line has an `INFO` prefix and timestamp.

To increase verbosity:

```bash
RUST_LOG=debug cargo run --release -p multithread-test --bin multithread-test
```

### Stage 2 — Compile guest

```rust
let mut program = guest::compile_compute_sum(target_dir);
```

`compile_compute_sum` is **auto-generated** by the `#[jolt::provable]` macro on `compute_sum` in
the guest crate. At runtime it invokes `cargo-jolt`, which cross-compiles the guest crate to a
custom RISC-V target (with ZeroOS). The resulting ELF is written to `target_dir`
(`/tmp/jolt-guest-targets`).

The macro generates a family of helper functions from a single `fn compute_sum(n: u64) -> ComputeResult`:

```
guest::compile_compute_sum(target_dir)
guest::preprocess_prover_compute_sum(&mut program)
guest::verifier_preprocessing_from_prover_compute_sum(&prover_preprocessing)
guest::build_prover_compute_sum(program, prover_preprocessing)
guest::build_verifier_compute_sum(verifier_preprocessing)
guest::analyze_compute_sum(n)
```

### Stage 3 — Preprocessing

```rust
let prover_preprocessing   = guest::preprocess_prover_compute_sum(&mut program);
let verifier_preprocessing = guest::verifier_preprocessing_from_prover_compute_sum(&prover_preprocessing);

let prove_compute_sum  = guest::build_prover_compute_sum(program, prover_preprocessing);
let verify_compute_sum = guest::build_verifier_compute_sum(verifier_preprocessing);
```

ZK proof systems require a one-time **preprocessing** step to fix the circuit structure and
produce a proving key and a verifying key. This is expensive but only needs to happen once per
program — as long as the guest binary does not change, the result can be reused.

`build_prover_compute_sum` and `build_verifier_compute_sum` return **closures** that are called
in later stages.

### Stage 4 — Trace analysis + Proving

```rust
// Dry-run: execute guest once just to inspect trace length
let program_summary = guest::analyze_compute_sum(n);
let trace_length = program_summary.trace.len();
drop(program_summary);  // free memory immediately — trace can be large

// Generate proof
let (output, proof, program_io) = prove_compute_sum(n);
```

- **trace**: The complete sequence of RISC-V instructions executed by the guest. The ZK proof is
  a cryptographic commitment over this trace.
- `drop(program_summary)` is called immediately because the trace data can be very large (tens of
  MB) and is no longer needed after measuring its length.
- `prove_compute_sum(n)` feeds input `n=100` into the zkVM and returns:
  - `output` — the `ComputeResult` business value
  - `proof` — the cryptographic proof object
  - `program_io` — I/O metadata, including whether the guest panicked

### Stage 5 — Verification

```rust
let is_valid = verify_compute_sum(n, output.clone(), program_io.panic, proof);
```

Verification requires:

| Argument | Visibility | Purpose |
|----------|-----------|---------|
| `n` | public | Original input |
| `output` | public | Claimed computation result |
| `program_io.panic` | public | Whether the guest terminated normally |
| `proof` | — | Cryptographic proof object |

The verifier **does not re-execute the guest**. It only checks the cryptographic validity of the
proof against the public inputs. This is the core value of zkVM: prove once, verify cheaply.

## Relationship with the guest crate

The host imports the guest crate as a dependency:

```toml
# host/Cargo.toml
[dependencies]
guest = { package = "multithread-test-guest", path = "../guest" }
```

- When the host is compiled for `aarch64-apple-darwin`, the `#[jolt::provable]` macro in the
  guest exposes host-side helper functions (`compile_*`, `build_prover_*`, etc.).
- At **runtime**, `compile_compute_sum()` re-invokes `cargo-jolt` to cross-compile the guest for
  the `riscv32im-zeroos` target. This is the step that downloads and rebuilds `core`/`std` from
  source and requires significant memory (8 GB+ recommended).
