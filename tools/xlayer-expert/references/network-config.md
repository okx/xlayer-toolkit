# X Layer Network Configuration

## Architecture
- **Current:** OP Stack-based optimistic rollup (migrated from Polygon CDK on October 27, 2025)
- **Execution client:** Geth or Reth (xlayer-reth)
- **Custom hardfork:** Jovian (mainnet: 2025-12-02 16:00:01 UTC, testnet: 2025-11-28 11:00:00 UTC)
- Re-genesis block 42,810,021 = CDK → OP Stack transition point

## Mainnet (chainId: 196 / 0xC4)
- RPC: https://rpc.xlayer.tech
- RPC (alt): https://xlayerrpc.okx.com
- Flashblocks RPC: https://rpc.xlayer.tech/flashblocks
- WSS: wss://xlayerws.okx.com
- WSS (alt): wss://ws.xlayer.tech
- Explorer: https://www.okx.com/web3/explorer/xlayer
- Gas Token: OKB (native)

## Testnet (chainId: 1952 / 0x7A0)
- RPC: https://testrpc.xlayer.tech
- RPC (terigon): https://testrpc.xlayer.tech/terigon
- RPC (alt): https://xlayertestrpc.okx.com/terigon
- Explorer: https://www.oklink.com/x-layer-testnet
- Gas Station: GET https://testrpc.xlayer.tech/terigon/gasstation
- **WARNING:** ChainId 195 is WRONG (legacy CDK era). ALWAYS use **1952** for testnet. Source: xlayer-reth chainspec. Never use 195 — it will fail to connect.

## Performance
- Block time: ~1 second (faster than standard OP Stack 2-second blocks)
- TPS: 5,000
- Rate limit: 100 req/sec per IP (public RPC)

## Re-genesis (CRITICAL)
- Mainnet re-genesis at block **42,810,021** (October 27, 2025)
- Testnet re-genesis at block **12,241,700**
- Pre-re-genesis data requires a different node type (cdk-Erigon)
- Details → `zkevm-differences.md`

## EIP-1559 Support
- `maxFeePerGas` and `maxPriorityFeePerGas` are supported
- Prefer `type: 2` transactions over legacy
- Details → `gas-optimization.md`

## WebSocket Subscriptions
- WSS endpoint: `wss://xlayerws.okx.com` (primary) or `wss://ws.xlayer.tech` (alternative)
- Supported events: `block`, `pending`, `logs`
- Automatic reconnection is mandatory
- Details → `infrastructure.md`
> **Note:** Official documentation also lists `wss://xlayerws.okx.com` and `wss://ws.xlayer.tech`. If one endpoint is unreachable, try the alternatives.

## Infrastructure Providers (Dedicated RPC)
QuickNode, Blockdaemon, Getblock, ZAN, Chainstack, Unifra, BlockPI
- Details → `infrastructure.md`
