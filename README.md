# ERC-8021 Demo

A proof-of-concept covering the three pillars of [ERC-8021](https://eip.tools/eip/8021) on-chain attribution:

1. **Construct** a transaction with ERC-8021 attribution calldata
2. **Parse** ERC-8021 attribution from raw calldata hex
3. **Parse** ERC-8021 attribution from a transaction hash
4. **Deploy** the `BuilderCodes` registry contract, register a code, and send + parse a Schema 1 attribution transaction

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`) — v1.x
- [Go](https://go.dev/dl/) ≥ 1.22
- Python 3 (used in `e2e.sh` for JSON parsing)

## Repository Structure

```
contracts/   Solidity — BuilderCodes ERC-721 registry (Foundry)
parser/      Go library (module erc8021) — ERC-8021 calldata parser + registry client
indexer/     Go CLI (module erc8021cmd) — parses a tx by hash and queries the registry
scripts/
  cast-create-8021tx.sh   Send a Schema 0 attribution tx against any RPC
  e2e.sh                  Full end-to-end: deploy → register → send Schema 1 tx → parse
```

## Build the Indexer CLI

```bash
cd indexer
go build -o erc8021 .
# Optional: install globally
sudo mv erc8021 /usr/local/bin/erc8021
```

---

## 1. Construct a Transaction with ERC-8021 Attribution

`scripts/cast-create-8021tx.sh` appends a **Schema 0** ERC-8021 suffix to any transaction calldata and broadcasts it via `cast send`.

```
ERC-8021 Schema 0 suffix (appended right-to-left to the end of calldata):
  txData || codes || codesLength(1 byte) || schemaId(0x00) || ercMarker(16 bytes)
```

**Start Anvil:**
```bash
anvil
```

**Send a Schema 0 attribution tx (defaults to Anvil account #0):**
```bash
bash scripts/cast-create-8021tx.sh
```

The script prints the full calldata and transaction receipt.

---

## 2. Parse ERC-8021 Attribution from Raw Calldata

The `parse` subcommand decodes a hex calldata string directly — no RPC or transaction hash needed.

```bash
erc8021 parse --input <hex> [-ca <0x…>] [-rpc <url>]
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--input` | _(required)_ | Hex-encoded calldata to parse |
| `--rpc` | `http://localhost:8545` | JSON-RPC endpoint (for registry lookup) |
| `--ca` | _(optional)_ | BuilderCodes registry address (Schema 0 only) |

**Schema 0 example:**
```bash
erc8021 parse --input 0x74657374040080218021802180218021802180218021
```
```
TxData(without attribution): 0x

── Attribution ──────────────────────────────────────────
SchemaID: 0x00 (Canonical Code Registry)
Codes:    test

(pass -ca <address> to query the BuilderCodes registry)
```

**Schema 1 example** (registry address is embedded in the calldata):
```bash
erc8021 parse --input 0x<hex>
```

If the registry is not deployed at the embedded address, the CLI reports:
```
error: registry not deployed at 0x<addr> (rpc: http://localhost:8545)
```

---

## 4. Parse ERC-8021 Attribution from a Transaction Hash

The `erc8021` indexer CLI fetches calldata from any EVM-compatible RPC, detects the ERC-8021 marker, and decodes the attribution fields.

```bash
erc8021 -txhash <0x...> -rpc <rpc-url>
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `-txhash` | _(required)_ | Transaction hash to inspect |
| `-rpc` | `http://localhost:8545`(default) | JSON-RPC endpoint |
| `-ca` | _(optional)_ | BuilderCodes registry address (Schema 0 only) |

**Schema 0 example** (supply `-ca` to look up codes in the on-chain registry):
```bash
erc8021 -txhash 0xabc... -rpc http://127.0.0.1:8545 -ca 0xRegistryAddress
```

**Schema 1 example** (registry address is embedded in the calldata; `-ca` not needed):
```bash
erc8021 -txhash 0xabc... -rpc http://127.0.0.1:8545
```

**Example output:**
```
TxData: 0xa9059cbb...

── Attribution ──────────────────────────────────────────
SchemaID:        0x01 (Custom Code Registry)
Codes:           xlayer
RegistryChainID: 0x7a69
RegistryAddress: 0xa513e6e4b8f2a923d98304ec87f64353c4d5c853

── Registry: 0xa513e6e4... (chain 0x7a69) ────────────────────────

  Code:          xlayer
  IsRegistered:  true
  Owner:         0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  PayoutAddress: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```

---

## 5. Full End-to-End: Deploy Registry, Register a Code, Send + Parse a Schema 1 Tx

`scripts/e2e.sh` automates the complete Schema 1 flow on a local Anvil node:

1. Deploy `BuilderCodes` (implementation + ERC-1967 proxy)
2. Grant `REGISTER_ROLE` and `METADATA_ROLE` to Anvil account #0
3. Register builder code `"xlayer"` via EIP-712 `registerWithSignature` (account #1 owns it, account #0 signs and pays gas)
4. Send a Schema 1 ERC-8021 attribution transaction embedding the registry address and chain ID in calldata

```
ERC-8021 Schema 1 calldata layout (left to right):
  txData || registryAddress(20) || chainId(N) || chainIdLength(1) || codes || codesLength(1) || 0x01 || ercMarker(16)
```

**Run:**
```bash
anvil &
bash scripts/e2e.sh
```

**Parse the output tx hash with the indexer:**
```bash
erc8021 -txhash <printed-hash> -rpc http://127.0.0.1:8545
```

The indexer will decode the Schema 1 suffix, resolve the embedded registry address, and query `isRegistered`, `ownerOf`, and `payoutAddress` from the on-chain contract.

**Custom builder code:**
```bash
BUILDER_CODE=myapp bash scripts/e2e.sh
```
