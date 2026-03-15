# X Layer Gas Optimization

## OKB Gas Token Economics

- **Native gas token:** OKB (NOT ETH!)
- **Fixed supply:** 21 million OKB (fully unlocked after August 2025)
- **Average tx cost:** ~$0.0005 USD
- Users must hold OKB balance — gas cannot be paid with ETH or stablecoins
- OKB has 18 decimals (as native token)

## Fee Structure (Multi-Component)

X Layer transaction fee = **L2 execution fee** + **L1 data fee**

| Component | Description | Variability |
|---|---|---|
| L2 execution fee | L2 computation cost | Low |
| L1 data fee | Cost of posting calldata to L1 | **High** (depends on L1 gas price) |

- L1 gas spikes → directly increase L2 costs
- Cost may vary between batches

## GasPriceOracle Predeploy

Address: `0x420000000000000000000000000000000000000f`

Provides L1 base fee and overhead information:
```solidity
interface IGasPriceOracle {
    function l1BaseFee() external view returns (uint256);
    function gasPrice() external view returns (uint256);
    function baseFee() external view returns (uint256);
}

// Usage
IGasPriceOracle oracle = IGasPriceOracle(0x420000000000000000000000000000000000000F);
uint256 l1Fee = oracle.l1BaseFee();
```

To get dynamic gas price:
```typescript
const gasPrice = await provider.send("eth_gasPrice", []);
```

## EIP-1559 Support

X Layer supports EIP-1559:
```typescript
// ethers v6
const feeData = await provider.getFeeData();
const tx = await wallet.sendTransaction({
    to: recipient,
    value: ethers.parseEther("0.01"),
    maxFeePerGas: feeData.maxFeePerGas,
    maxPriorityFeePerGas: feeData.maxPriorityFeePerGas,
});

// viem
const request = await walletClient.prepareTransactionRequest({
    to: recipient,
    value: parseEther("0.01"),
    // viem automatically calculates EIP-1559 parameters
});
```

- Base fee is burned (deflationary pressure)
- Priority fee goes to sequencer (validator)
- Prefer `type: 2` (EIP-1559) transactions over `type: 0` (legacy)

## Optimization Strategies

### Contract Size (EIP-170)
- Limit: **24,576 bytes** (24 KB) deployed bytecode
- Deploy reverts if exceeded
- Check: `npx hardhat compile` → look at artifact size
- Foundry: `forge build --sizes`

Reduction techniques:
1. Libraries for code sharing (external library → DELEGATECALL)
2. Custom errors instead of string messages (`error InsufficientBalance()`)
3. Internal functions are inlined — make them external if too large
4. Diamond pattern (EIP-2535) as a last resort

### Compiler Optimizer
```json
{
  "solidity": {
    "version": "0.8.34",
    "settings": {
      "optimizer": {
        "enabled": true,
        "runs": 200
      }
    }
  }
}
```
- `runs: 200` — general purpose, deploy + runtime balance
- `runs: 1` — cheap deploy, expensive runtime (rarely called contracts)
- `runs: 10000` — expensive deploy, cheap runtime (frequently called contracts)

### Multicall3
Address: `0xcA11bde05977b3631167028862bE2a173976CA11`

Batch multiple read calls into a single transaction:
```typescript
import { Contract } from "ethers";

const multicall = new Contract("0xcA11bde05977b3631167028862bE2a173976CA11", [
    "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) view returns (tuple(bool success, bytes returnData)[])"
], provider);

const calls = [
    { target: tokenAddr, allowFailure: false, callData: erc20.interface.encodeFunctionData("balanceOf", [user]) },
    { target: tokenAddr, allowFailure: false, callData: erc20.interface.encodeFunctionData("totalSupply") },
];
const results = await multicall.aggregate3(calls);
```

### Storage Optimization
```solidity
// ❌ 3 storage slots (96 bytes)
uint256 a;  // slot 0
uint256 b;  // slot 1
uint256 c;  // slot 2

// ✅ 1 storage slot (32 bytes) — packed
uint128 a;  // slot 0 (first 16 bytes)
uint64 b;   // slot 0 (next 8 bytes)
uint64 c;   // slot 0 (last 8 bytes)
```
- SSTORE (20,000 gas cold / 5,000 warm) is the most expensive opcode
- Variables in the same slot only need one SSTORE when written together
- Mappings and dynamic arrays always use separate slots

### Calldata vs Memory
```solidity
// ✅ Read-only parameters: calldata (cheap)
function process(bytes calldata data) external { ... }

// Memory: when modification is needed
function modify(bytes memory data) internal { ... }
```

### Events vs Storage
```solidity
// ❌ Expensive: write to storage
mapping(uint256 => string) public logs;
function log(uint256 id, string memory msg) external {
    logs[id] = msg;  // ~20,000+ gas
}

// ✅ Cheap: emit event
event LogEntry(uint256 indexed id, string message);
function log(uint256 id, string memory msg) external {
    emit LogEntry(id, msg);  // ~375 + 8*len gas
}
```
- Events cannot be read on-chain (only via off-chain indexers)
- Use events for audit trails, activity logs
