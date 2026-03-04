# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is an ERC-8021 attribution SDK demo. The repo has three main components:

- **`contracts/`** — Solidity smart contracts (Foundry). `BuilderCodes.sol` is the only production contract: an ERC-721 NFT registry where builders register unique codes (e.g. `"myapp"`) for on-chain revenue attribution.
- **`parser/`** — Go library (`module erc8021`) for parsing ERC-8021 attribution calldata and querying the registry on-chain.
- **`indexer/`** — Go CLI (`module erc8021cmd`) that wraps the parser. Uses `replace erc8021 => ../parser` in its `go.mod`.
- **`scripts/`** — Bash scripts for manual testing:
  - `cast-send-data.sh` — Schema 0 example transaction
  - `e2e.sh` — Full end-to-end: deploy → register → send Schema 1 tx → print txhash

## ERC-8021 Calldata Format

Parsed **right-to-left** from the end of calldata:

```
txData || [Schema 1 fields] || codes || codesLength(1) || schemaId(1) || ercMarker(16)
```

**Schema 0 (0x00)** — Canonical Code Registry: codes = comma-delimited ASCII, registry address supplied externally.

**Schema 1 (0x01)** — Custom Code Registry: extends Schema 0 with three additional fields left of codes:
```
txData || codeRegistryAddress(20) || codeRegistryChainId(N) || codeRegistryChainIdLength(1) || codes || codesLength(1) || 0x01 || ercMarker(16)
```

## Commands

### Contracts (`contracts/`)

```bash
# Build (skipping tests if OZ remappings are an issue)
forge build
forge build --skip test

# Run all tests
forge test

# Run a single test file
forge test --match-path test/unit/BuilderCodes/register.t.sol

# Run a single test function
forge test --match-test test_register_revert_senderInvalidRole

# Run with verbosity for traces
forge test -vvvv

# Production build
FOUNDRY_PROFILE=production forge build --build-info src
```

**Dependency setup** (if `lib/` is empty after cloning):
```bash
cd contracts && forge install
```
This installs forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable, and solady.

**Foundry version note**: This repo uses Foundry v1.x. `forge create` requires `--broadcast` to actually send transactions. When deploying contracts with `bytes` constructor args, use `cast send --create` with manually assembled bytecode instead of `forge create --constructor-args`.

### Parser library (`parser/`)

```bash
cd parser
go test ./...
go test -run TestParseSchema1   # single test
```

### Indexer CLI (`indexer/`)

```bash
cd indexer
go build -o erc8021 .

# Usage (Anvil must be running for txhash lookup)
erc8021 -txhash <0x...> -rpc http://127.0.0.1:8545
erc8021 -txhash <0x...> -rpc http://127.0.0.1:8545 -ca <registry-contract-address>
```

### End-to-end test (`scripts/e2e.sh`)

Requires Anvil running locally:
```bash
anvil &
bash scripts/e2e.sh
# Prints a txhash; verify with:
erc8021 -txhash <printed-hash> -rpc http://127.0.0.1:8545
```

## Code Architecture

### `contracts/src/BuilderCodes.sol`

- UUPS upgradeable ERC-721 (ERC-1967 proxy pattern)
- ERC-7201 namespaced storage to prevent upgrade collisions
- `toTokenId(string)` / `toCode(uint256)`: deterministic bidirectional mapping via 7-bit ASCII encoding — no separate storage needed
- `register()`: direct registration, requires `REGISTER_ROLE`
- `registerWithSignature()`: gasless EIP-712 registration; signer must have `REGISTER_ROLE`
- `payoutAddress(string)`: separate from NFT owner, configurable via `updatePayoutAddress()`
- Transfer gating: only addresses with `TRANSFER_ROLE` can initiate transfers (owner still needs to approve)
- Owner has all roles via `hasRole()` override

**EIP-712 struct for registration:**
```
BuilderCodeRegistration(string code, address initialOwner, address payoutAddress, uint48 deadline)
```

**Foundry remappings** (foundry.toml):
- `openzeppelin-contracts/` → `lib/openzeppelin-contracts/contracts/`
- `openzeppelin-contracts-upgradeable/` → `lib/openzeppelin-contracts-upgradeable/contracts/`
- `@openzeppelin/contracts/` → `lib/openzeppelin-contracts/contracts/` (tests use this form)
- `solady/` → `lib/solady/src/`

### `parser/` (module `erc8021`)

| File | Purpose |
|---|---|
| `types.go` | `Data`, `Attribution`, `Schema0`, `Schema1` structs; `String()` methods |
| `parser.go` | `Parse([]byte)`, `ParseHex(string)`, `HasMarker()`, `DecodeSchema0/1()` |
| `rpc.go` | `FetchCalldata(ctx, rpcURL, txHash)` via go-ethereum `ethclient` |
| `registry.go` | `QueryRegistry(ctx, rpcURL, registryAddr, codes)` — ABI calls to BuilderCodes |

`registry.go` uses a hand-written minimal ABI JSON (no generated bindings) for `isRegistered`, `payoutAddress`, `toTokenId`, `ownerOf`.

### `indexer/main.go` (module `erc8021cmd`)

CLI flags: `-txhash` (required), `-rpc` (default `http://localhost:8545`), `-ca` (registry address for Schema 0).

- Schema 0: uses `-ca` flag address for registry lookup
- Schema 1: uses `RegistryAddress` embedded in calldata; `-ca` is ignored

### `contracts/script/`

- `DeployBuilderCodes.s.sol` — production deployment with CREATE2 salts targeting vanity addresses; has hardcoded `assert()` checks that only pass on mainnet with correct configuration — **do not use for local dev**
- `GrantRegisterRole.s.sol` — grants `REGISTER_ROLE` to a specific address on a deployed contract

### Test structure (`contracts/test/`)

- `test/lib/BuilderCodesTest.sol` — abstract base; deploys impl+proxy in `setUp()`, provides `_generateValidCode()` / `_generateInvalidCode()` helpers
- `test/unit/BuilderCodes/` — one file per public function
- `test/integration/` — cross-function flows
- Tests use fuzzing extensively (`uint256 codeSeed`, `address sender` parameters)
