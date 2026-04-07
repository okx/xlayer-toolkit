# Force Inclusion

Send L2 transactions from L1 via OP Stack deposit mechanism on XLayer devnet.

The entire flow runs through L1 only — no L2 wallet or OKB gas token needed. Deposit transactions execute on L2 as system transactions at zero gas price.

## How It Works

```
L1 EOA
 ├─ Portal.depositTransaction(isCreation=true, data=bytecode)  → deploy contract on L2
 └─ Portal.depositTransaction(to=contract, data=calldata)      → call contract on L2
```

Both deploy and call go through the same path: `writeContract` on L1 → `OptimismPortalProxy.depositTransaction()` → L1 confirmation → derive L2 tx hash from `TransactionDeposited` event → L2 confirmation.

### CGT Mode (Custom Gas Token)

XLayer uses OKB as native L2 gas token. In CGT mode, `depositTransaction` requires `msg.value == 0` and `_value == 0`. This means:

- Force inclusion of contract calls works (value=0)
- Force inclusion of contract deployments works (isCreation=true)
- Native OKB transfers via deposit are **not possible** (Portal enforces `_value == 0`)
- To bridge OKB, use `depositERC20Transaction` (not implemented here)

### Sender Address

For EOA callers, L2 `msg.sender` equals the L1 address (no aliasing). Contract callers get aliased (`+0x1111000000000000000000000000000000001111`).

## Prerequisites

- Node.js 22+
- [Foundry](https://book.getfoundry.sh/) (forge)
- Running XLayer devnet (`~/dev/xlayer/xlayer-toolkit/devnet/`)

## Setup

```bash
# Install dependencies
npm install

# Compile contracts
npm run build
```

No `.env` file needed — all config defaults to reading from the devnet:

- `PRIVATE_KEY` ← `RICH_L1_PRIVATE_KEY` from `devnet/.env`
- `L1_RPC_URL` ← `L1_RPC_URL` from `devnet/.env`
- `L2_RPC_URL` ← `L2_RPC_URL` from `devnet/.env`
- Portal address ← `deposit_contract_address` from `devnet/config-op/rollup.json`

To override any value, create a `.env` file (see `.env.example`):

| Variable | Default source | Description |
|----------|---------------|-------------|
| `PRIVATE_KEY` | `devnet/.env` → `RICH_L1_PRIVATE_KEY` | L1 account private key (needs ETH for L1 gas) |
| `L1_RPC_URL` | `devnet/.env` | L1 RPC endpoint |
| `L2_RPC_URL` | `devnet/.env` | L2 RPC endpoint |
| `ROLLUP_JSON_PATH` | `../../devnet/config-op/rollup.json` | Path to devnet rollup config |

## Usage

```bash
# Deploy Counter + force include increment()
npm run send

# Attempt OKB transfer (demonstrates CGT mode revert)
npm run send:transfer
```

### `npm run send`

1. Read portal address from `rollup.json`
2. Deploy a Counter contract to L2 via L1 deposit (isCreation)
3. Call `Counter.increment()` on L2 via L1 deposit
4. Verify count changed from 0 to 1

### `npm run send:transfer`

Attempts to force include an OKB transfer on L2. Both attempts revert, demonstrating the CGT mode limitation:

| Attempt | Parameters | Result |
|---------|-----------|--------|
| 1 | `_value=1 OKB, msg.value=0` | `InsufficientDeposit` — okx fork enforces `msg.value == _value` |
| 2 | `_value=1 OKB, msg.value=1 ETH` | `NotAllowedOnCGTMode` — CGT mode forbids `msg.value > 0` |

The upstream OP Stack removed the `msg.value == _value` check, which would allow spending existing L2 balance via deposit. The okx fork re-added it (commit `d0cb1130d8`).

## Project Structure

```
├── contracts/
│   ├── foundry.toml
│   └── src/Counter.sol        # Solidity source
├── src/
│   ├── config.ts              # Chain definitions from rollup.json
│   ├── clients.ts             # L1/L2 viem clients
│   ├── artifacts.ts           # Load ABI + bytecode from forge output
│   ├── deposit.ts             # submitDeposit() — shared L1→L2 deposit pipeline
│   ├── counter.ts             # Counter deploy + read helpers
│   ├── send-tx.ts             # Entry point: deploy + increment
│   └── send-transfer.ts      # OKB transfer attempt (CGT revert demo)
└── package.json
```

### Adding New Contracts

1. Add `.sol` file to `contracts/src/`
2. Run `npm run build`
3. Load with `loadArtifact("YourContract")` to get `{ abi, bytecode }`
4. Deploy via `submitDeposit({ isCreation: true, data: bytecode, ... })`
5. Call via `submitDeposit({ to: address, data: calldata, ... })`

## Known Issues

- `receipt.contractAddress` is unreliable for deposit tx contract creations (nonce computation differs). The code uses `debug_traceTransaction` with `callTracer` to get the actual deployed address.
- viem's `buildDepositTransaction` does not support `isCreation: true`, so we call the Portal contract directly via `writeContract`.
