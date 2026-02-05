# demo-sp1: ZK Bisection Fault Proof

This demo implements the **ZK Bisection** fault proof mechanism for xlayer-dex, using SP1 zkVM for zero-knowledge proofs.

## Overview

ZK Bisection combines:
- **Fault Proof**: Optimistic execution, challenged only when needed
- **Bisection**: Binary search to locate disputed block (~10 rounds)
- **ZK Proof**: SP1 zkVM proof for single block verification
- **SMT**: Sparse Merkle Tree for state commitment

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Contracts (Solidity)                     │
│                                                                 │
│   OutputOracle.sol      - Batch output submission               │
│   DisputeGame.sol       - Bisection + ZK verification           │
│   ISP1Verifier.sol      - SP1 proof verification                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        Programs (SP1 zkVM)                      │
│                                                                 │
│   block-verify          - Verify block execution in zkVM        │
│     - Verify SMT proofs for initial states                      │
│     - Execute transactions                                      │
│     - Compute state_hash and trace_hash                         │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        Host (Rust)                              │
│                                                                 │
│   crates/core           - Core execution logic                  │
│   crates/smt            - Sparse Merkle Tree                    │
│   crates/host           - Proposer/Challenger/Prover            │
│   bin/proposer          - Proposer binary                       │
│   bin/challenger        - Challenger binary                     │
└─────────────────────────────────────────────────────────────────┘
```

## Flow

### Normal Flow (99%+ of the time)

```
Sequencer:
  1. Execute blocks (0.1s each)
  2. Compute trace_hash per block
  3. Don't compute SMT (hot path)

Every 100s (per batch):
  1. Async update SMT
  2. Submit (state_hash, trace_hash, smt_root) to L1
  3. Start 7-day challenge period
  4. No challenge → Auto-confirm
```

### Challenge Flow (rare)

```
1. Challenger detects invalid output
2. Challenger initiates DisputeGame
3. Bisection (~10 rounds):
   - Proposer: "At block X, trace_hash = Y"
   - Challenger: Agree/Disagree
   - Narrow down to disputed block
4. Proposer generates ZK proof for disputed block
5. L1 verifies proof
6. Winner takes bond
```

## Project Structure

```
demo-sp1/
├── Cargo.toml                    # Workspace
├── README.md
│
├── contracts/                    # Solidity contracts
│   ├── src/
│   │   ├── DisputeGame.sol       # Bisection + ZK verification
│   │   ├── OutputOracle.sol      # Batch output storage
│   │   ├── interfaces/
│   │   │   └── ISP1Verifier.sol
│   │   └── lib/
│   │       └── Types.sol
│   └── foundry.toml
│
├── programs/                     # SP1 zkVM programs
│   └── block-verify/
│       └── src/main.rs           # Block verification program
│
├── crates/
│   ├── core/                     # Core business logic
│   │   └── src/
│   │       ├── block.rs          # Block structure
│   │       ├── tx.rs             # Transaction execution
│   │       ├── state.rs          # State management
│   │       ├── trace.rs          # Trace hash
│   │       ├── executor.rs       # Block executor
│   │       └── dex/              # DEX logic
│   │
│   ├── smt/                      # Sparse Merkle Tree
│   │   └── src/
│   │       ├── tree.rs           # SMT implementation
│   │       ├── proof.rs          # SMT proof
│   │       └── hasher.rs         # Keccak256 hasher
│   │
│   ├── host/                     # Host-side logic
│   │   └── src/
│   │       ├── proposer.rs       # Proposer logic
│   │       ├── challenger.rs     # Challenger logic
│   │       ├── prover.rs         # SP1 proof generation
│   │       ├── bisection.rs      # Bisection manager
│   │       └── witness.rs        # Witness generation
│   │
│   └── bindings/                 # Contract bindings
│
└── bin/
    ├── proposer/                 # Proposer binary
    └── challenger/               # Challenger binary
```

## Key Components

### 1. SMT (Sparse Merkle Tree)

- Fixed depth: 256 levels
- Direct address → path mapping
- Parallel update friendly
- ZK friendly (simple structure)

### 2. Trace Hash

```
trace_hash_N = H(trace_hash_{N-1}, block_hash_N, state_hash_N)
```

Used for Bisection to quickly locate disputed block.

### 3. Bisection

- ~10 rounds (log2(1000 blocks))
- L1 cost: ~$50
- Identifies exact disputed block

### 4. ZK Proof

SP1 program verifies:
1. Initial states belong to SMT (via SMT proofs)
2. Block execution is correct
3. Output hashes match claimed values

## Cost Analysis

| Item | Cost |
|------|------|
| Normal operation (per batch) | ~$10 |
| Challenge - Bisection (~10 rounds) | ~$50 |
| Challenge - ZK proof (1 block) | ~$390 |
| Challenge - L1 verification | ~$50-100 |
| **Total challenge cost** | **~$500** |

Compared to proving entire batch: **~80x cheaper**

## Building

```bash
# Build all crates
cargo build

# Build SP1 program (requires sp1-sdk)
cd programs/block-verify
cargo prove build
```

## Running

### Quick Start (One Command)

```bash
# Start everything with Docker (recommended)
make run

# View logs
make logs              # All logs
make logs-proposer     # Proposer logs
make logs-challenger   # Challenger logs

# Stop
make stop
```

### Configuration

Copy `env.example` to `.env` and configure:

```bash
cp env.example .env
```

**For demo mode (no real ZK proofs):**
```
SP1_PROVER=mock
```

**For real ZK proofs (requires SP1 Network account):**
```
# Get key from https://network.succinct.xyz/
SP1_PRIVATE_KEY=your_sp1_network_key
SP1_PROVER=network
```

### What Happens

1. **Anvil** starts (local L1)
2. **Contracts** are deployed automatically
3. **Node** starts (mock L2 for demo)
4. **Proposer** submits batches every 100 blocks
5. **Challenger** monitors and challenges every 10 batches (for demo)

## Testing

```bash
# Run tests
cargo test

# Run specific crate tests
cargo test -p xlayer-smt
cargo test -p xlayer-core
```

## References

- [ZKBisection.md](../demo/ZKBisection.md) - Detailed design document
- [SP1 Documentation](https://docs.succinct.xyz/)
- [Optimism Fault Proof](https://docs.optimism.io/stack/protocol/fault-proofs/explainer)
