# Poseidon2 Solidity Gas Benchmark (Initial)

## Goal

Compare gas costs of three Poseidon2 BN254 implementations (all Noir-compatible: t=4, RF=8, RP=56, x^5 S-box) across hash_1, hash_2, hash_3.

This was the initial benchmark before the comprehensive suite was built. See `BENCHMARK_PLAN.md` for the full plan.

## Implementations Under Test

| ID | Implementation | Source | Description |
|----|---------------|--------|-------------|
| A  | zemse Solidity | [poseidon2-evm](https://github.com/zemse/poseidon2-evm) `src/bn254/solidity/` | Pure Solidity reference, uses `addmod`/`mulmod` |
| B  | zemse Yul | [poseidon2-evm](https://github.com/zemse/poseidon2-evm) `src/bn254/yul/` | Inline assembly, `ADD` replaces `ADDMOD` (dirty value tracking) |
| C  | V-k-h Solidity | [poseidon2-solidity](https://github.com/V-k-h/poseidon2-solidity) `contracts/` | Pure Solidity, hand-unrolled sponge per arity |

## Results

### External Call (contract-to-contract)

| | zemse Solidity | zemse Yul | V-k-h Solidity |
|---|---:|---:|---:|
| **hash_1(0)** | 222,722 | **23,397** | 45,434 |
| **hash_1(42)** | 222,723 | **23,398** | 45,435 |
| **hash_2(1,2)** | 223,257 | **23,445** | 45,479 |
| **hash_2(large)** | 223,497 | **23,685** | 45,719 |
| **hash_3(1,2,3)** | 223,855 | **23,558** | 45,592 |
| **hash_3(large)** | 224,254 | **23,957** | 45,991 |

### Internal Call (library inline)

| | zemse Solidity | zemse Yul | V-k-h Solidity |
|---|---:|---:|---:|
| **hash_1(0)** | 222,711 | **24,847** | 45,479 |
| **hash_1(42)** | 222,712 | **24,848** | 45,480 |
| **hash_2(1,2)** | 223,291 | **24,915** | 45,527 |
| **hash_2(large)** | 223,531 | **25,155** | 45,767 |
| **hash_3(1,2,3)** | 223,823 | **24,962** | 45,614 |
| **hash_3(large)** | 224,222 | **25,361** | 46,013 |

### Key Findings

1. zemse Yul is cheapest at ~23-25k gas (ADD replaces ADDMOD, fully unrolled)
2. V-k-h Solidity is ~45k — 5x cheaper than zemse Solidity due to assembly RC lookup
3. zemse Solidity is ~223k — sponge state machine + memory overhead dominates
4. External vs inline difference is negligible for all implementations
5. Input value (zero vs large) has minimal impact on gas (~1-2% variation)
