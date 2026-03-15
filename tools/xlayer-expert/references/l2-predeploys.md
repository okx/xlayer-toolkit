# X Layer Predeploy & Bridge Addresses

## L2 Predeploy Addresses (Mainnet & Testnet — same)

| Contract               | Address                                     |
|------------------------|---------------------------------------------|
| L2CrossDomainMessenger | 0x4200000000000000000000000000000000000007  |
| GasPriceOracle         | 0x420000000000000000000000000000000000000f  |
| L1Block                | 0x4200000000000000000000000000000000000015  |
| L2ToL1MessagePasser    | 0x4200000000000000000000000000000000000016  |
| SequencerFeeVault      | 0x4200000000000000000000000000000000000011  |
| BaseFeeVault           | 0x4200000000000000000000000000000000000019  |
| L1FeeVault             | 0x420000000000000000000000000000000000001a  |
| ProxyAdmin             | 0x4200000000000000000000000000000000000018  |

## L1 Bridge Contracts (Ethereum Mainnet)

> **Verification note:** These addresses were sourced from X Layer documentation. Before relying on them in production, verify on [Etherscan](https://etherscan.io) by checking that each address has the expected contract name and is associated with X Layer / OKX deployment.

| Contract               | Address                                     |
|------------------------|---------------------------------------------|
| OptimismPortal         | 0x64057ad1DdAc804d0D26A7275b193D9DACa19993  |
| L1CrossDomainMessenger | 0xF94B553F3602a03931e5D10CaB343C0968D793e3  |
| SystemConfig           | 0x5065809Af286321a05fBF85713B5D5De7C8f0433  |
| DisputeGameFactory     | 0x9D4c8FAEadDdDeeE1Ed0c92dAbAD815c2484f675  |

## L1 Bridge Contracts (Sepolia Testnet)

| Contract               | Address                                     |
|------------------------|---------------------------------------------|
| OptimismPortal         | 0x1529a34331D7d85C8868Fc88EC730aE56d3Ec9c0  |
| L1CrossDomainMessenger | 0xEf40d5432D37B3935a11710c73F395e2c9921295  |
| SystemConfig           | 0x06BE4b4A9a28fF8EED6da09447Bc5DAA676efac3  |
| DisputeGameFactory     | 0x80388586ab4580936BCb409Cc2dC6BC0221e1B6F  |

## Important Notes (OP Stack — Current Architecture)
- **L2→L1 withdrawal:** OP Stack standard ~7 day challenge period (PermissionedDisputeGame active), but AggLayer ZK proofs can provide faster finality
- **Soft finality:** ~1 second (sequencer confirmation), ~200ms with flashblocks pre-confirmation
- **Front-end bridge:** OKX web bridge deprecated August 15, 2025 — use community bridges or contract calls directly
- FaultDisputeGame: Not deployed (0x0000...) — **PermissionedDisputeGame active** (only authorized participants can open disputes)
- Bridge stages: deposit → L2 execute → challenge period → L1 finality
- GasPriceOracle (`0x420...000f`): provides L1 fee info — for gas optimization see → `gas-optimization.md`
- Predeploy addresses are standard OP Stack addresses (`0x4200...` prefix)

## Cross-Chain Message Pattern
```solidity
// L2 → L1 message sending
IL2CrossDomainMessenger messenger = IL2CrossDomainMessenger(
    0x4200000000000000000000000000000000000007
);

messenger.sendMessage(
    l1TargetAddress,     // Target contract on L1
    abi.encodeCall(ITarget.handleMessage, (data)),
    200_000              // L1 gas limit
);
```

## L1 → L2 Deposit Pattern
```solidity
// On L1 (Ethereum Mainnet): deposit OKB/ETH to X Layer via OptimismPortal
interface IOptimismPortal {
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes calldata _data
    ) external payable;
}

// Simple L1 → L2 OKB deposit
IOptimismPortal portal = IOptimismPortal(0x64057ad1DdAc804d0D26A7275b193D9DACa19993); // Mainnet

portal.depositTransaction{value: msg.value}(
    recipientOnL2,   // Target address on X Layer
    msg.value,       // Amount to deposit
    100_000,         // L2 gas limit
    false,           // Not a contract creation
    ""               // No calldata (simple transfer)
);
```

```typescript
// TypeScript: L1 → L2 deposit via ethers.js
import { ethers } from "ethers";

const OPTIMISM_PORTAL = "0x64057ad1DdAc804d0D26A7275b193D9DACa19993"; // Mainnet
const PORTAL_ABI = [
  "function depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes _data) payable"
];

const l1Provider = new ethers.JsonRpcProvider(process.env.ETH_RPC_URL);
const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY!, l1Provider);
const portal = new ethers.Contract(OPTIMISM_PORTAL, PORTAL_ABI, wallet);

const tx = await portal.depositTransaction(
  recipientOnL2,
  ethers.parseEther("1.0"),  // 1 OKB
  100_000n,                  // L2 gas limit
  false,                     // Not contract creation
  "0x",                      // No calldata
  { value: ethers.parseEther("1.0") }
);
await tx.wait();
// Deposit typically arrives on L2 within minutes
```

## AggLayer
- X Layer continues AggLayer integration (on top of OP Stack)
- Unified bridge vision: cross-chain transfer without wrapped tokens
- AggLayer v0.3+: non-CDK chain support
- Details → `infrastructure.md`
