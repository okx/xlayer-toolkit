# X Layer Flashblocks

200ms pre-confirmation — instant UX instead of standard 1-second blocks.

## Architecture (xlayer-reth)
- Each 1-second X Layer block is split into **3-5 flashblocks** (~200ms intervals)
- Sequencer **streams** flashblock payloads over **WebSocket**
- RPC nodes receive this stream and build speculative in-memory pending blocks
- Flashblocks use **incremental trie cache** (~2.4-2.5x state root speedup)
- Sequence persistence: flashblocks survive node restarts

## Endpoint
- Mainnet: https://rpc.xlayer.tech/flashblocks
- Use "pending" block tag

## Ethers v6

```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider("https://rpc.xlayer.tech/flashblocks");
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

const tx = await wallet.sendTransaction({ to: recipient, value: ethers.parseEther("0.001") }); // OKB = 18 decimals, parseEther is correct here
await tx.wait(0); // confirmations=0 = flashblock is sufficient
const balance = await provider.getBalance(address, "pending"); // Returns OKB balance (18 decimals)
```

## Viem

```typescript
import { createPublicClient, http, defineChain } from 'viem';

const xlayer = defineChain({
  id: 196,
  name: 'X Layer',
  nativeCurrency: { name: 'OKB', symbol: 'OKB', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.xlayer.tech/flashblocks'] } },
});

const client = createPublicClient({ chain: xlayer, transport: http() });
const balance = await client.getBalance({ address: "0x...", blockTag: 'pending' });
```

## Supported RPC Methods (with pending tag)
eth_blockNumber, eth_call, eth_estimateGas, eth_getBalance,
eth_getTransactionCount, eth_getCode, eth_getStorageAt,
eth_getBlockByNumber, eth_getBlockByHash, eth_getTransactionReceipt,
eth_getBlockReceipts, eth_getTransactionByHash

## Flashblocks Status Check
```typescript
// Check if flashblocks are active
const enabled = await provider.send("eth_flashblocksEnabled", []);
console.log("Flashblocks enabled:", enabled); // true | false
```

## When to Use
- Real-time UX (gaming, chat, social)
- High-frequency trading
- Operations requiring instant feedback

## When NOT to Use
- Deploy scripts (standard RPC is sufficient)
- Testnet (Flashblocks not available on testnet)
- **Critical financial operations** (large transfers, settlement) — wait for finality

## Reorg Risk Warning (CRITICAL)
- Flashblock pre-confirmation ≠ finality
- Short-lived reorgs are possible — flashblock tx may become invalid later
- Wait for at least 1 standard block confirmation before showing "transaction confirmed" to user
- **Multi-sequencer failover:** Primary sequencer (flashblocks-enabled) may fail over to backup sequencer (no flashblocks) — flashblocks may be lost in this scenario
- **Rule:** Use flashblocks for UX speed, but trust finalized blocks for state-critical logic

## xlayer-reth Node Flashblock Configuration
To enable flashblocks on a self-hosted node:
```bash
xlayer-reth node \
  --xlayer.flashblocks-subscription \
  --xlayer.flashblocks-subscription-max-addresses 1000 \
  --flashblock-consensus \
  --flashblocks-url wss://sequencer.xlayer.tech/flashblocks
```
- `--xlayer.sequencer-mode`: Run in sequencer mode (sequencer operators only)
- `--xlayer.flashblocks-subscription-max-addresses`: Max tracked address count

## WebSocket Flashblock Listening
```typescript
// viem
const wsClient = createPublicClient({
    chain: xlayer,
    transport: webSocket("wss://xlayerws.okx.com"),
});

// Get flashblock state via "pending" block tag
const balance = await wsClient.getBalance({
    address: "0x...",
    blockTag: "pending",
});
```
