# X Layer Infrastructure

## Public vs Dedicated RPC

| | Public | Dedicated |
|---|---|---|
| Rate Limit | 100 req/sec | Unlimited/Enterprise |
| Uptime SLA | None | 99.9–99.99% |
| DDoS Protection | Basic | Advanced |
| Archive Data | Limited | Full |
| Cost | Free | $5–50/month |
| Use Case | Test/prototype | Production |

### Provider List
| Provider | Features |
|---|---|
| QuickNode | Re-genesis aware (`x-qn-height` header), add-on marketplace |
| Blockdaemon | Enterprise grade, dedicated node |
| Getblock | Shared/dedicated options |
| ZAN | OKX ecosystem integration |
| Chainstack | Elastic node, archive data |
| Unifra | Free tier available |
| BlockPI | Global distributed |

---

## Self-hosted RPC (xlayer-toolkit)

### One-Click Setup
```bash
mkdir -p /data/xlayer-mainnet && cd /data/xlayer-mainnet
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/main/rpc-setup/one-click-setup.sh -o one-click-setup.sh
chmod +x one-click-setup.sh && ./one-click-setup.sh
```

### Configuration
- Execution client: **Geth** (stable) or **Reth** (performant, Rust-based)
- Runs via Docker containerization
- Port mapping:
  - `8545` — HTTP RPC
  - `8546` — WebSocket
  - `8551` — Engine API (requires JWT auth)
  - `30303` — P2P
- Disk: ~500 GB+ (archive), ~100 GB (pruned)
- RAM: 16 GB minimum, 32 GB recommended
- CPU: 4+ cores

### xlayer-reth (Recommended — High Performance)
Reth v1.11.0-based, with X Layer-specific optimizations:
```bash
# Docker
docker run -d --name xlayer-reth \
  -p 8545:8545 -p 8546:8546 -p 30303:30303 \
  -v /data/xlayer:/data \
  okx/xlayer-reth:latest \
  node \
  --http --http.port 8545 \
  --ws --ws.port 8546 \
  --datadir /data \
  --chain xlayer-mainnet
```

#### X Layer-Specific CLI Arguments
```bash
# Flashblocks subscription (RPC node)
--xlayer.flashblocks-subscription
--xlayer.flashblocks-subscription-max-addresses 1000

# Sequencer mode (sequencer operators only)
--xlayer.sequencer-mode

# Flashblock consensus (build blocks from WebSocket stream)
--flashblock-consensus
--flashblocks-url wss://sequencer.xlayer.tech/flashblocks

# Legacy RPC routing (for pre-re-genesis blocks)
--rpc.legacy-url https://legacy-erigon.xlayer.tech
--rpc.legacy-timeout 30s
```

#### Crate Structure (source code reference)
| Crate | Description |
|---|---|
| xlayer-flashblocks | Flashblock lifecycle (cache, consensus, pubsub, validation) |
| xlayer-rpc | Custom RPC extensions (`eth_flashblocksEnabled`) |
| xlayer-builder | Block building (sequencer) |
| xlayer-chainspec | Chain spec (mainnet/testnet/devnet genesis, Jovian hardfork) |
| xlayer-monitor | Event subscription monitoring |
| xlayer-legacy-rpc | Block height-based legacy routing |
| Source: [github.com/okx/xlayer-reth](https://github.com/okx/xlayer-reth) |

### JWT Authentication (Engine API)
```bash
# Generate JWT secret
openssl rand -hex 32 > /data/xlayer-mainnet/jwt.hex

# Start Geth
geth --authrpc.jwtsecret=/data/xlayer-mainnet/jwt.hex \
     --http --http.port 8545 --ws --ws.port 8546

# Start Reth
xlayer-reth node --authrpc.jwtsecret=/data/xlayer-mainnet/jwt.hex \
     --http --http.port 8545 --ws --ws.port 8546
```

### Multi-Sequencer Architecture
- Primary sequencer: flashblocks-enabled (xlayer-reth sequencer mode)
- Backup sequencer: flashblocks-less fallback (Conductor cluster for failover)
- 99.9%+ uptime target
- During failover, flashblock stream is interrupted, falls back to standard 1s blocks

### Security Audit
- January 2026: xlayer-reth diff audit report available (`security-reviews/` directory)
- Comprehensive Reth fork change review

---

## Monitoring Stack

### Monitoring Tools
- **Prometheus + Grafana**: Node metrics (port 6060 → Prometheus scrape, Grafana dashboards on port 3000)
- **xlayer-trace-monitor** (`xlayer-toolkit/trace-monitor`): Transaction/block lifecycle tracking, outputs CSV
- **Tenderly**: Smart contract monitoring, alerting, transaction simulation (mainnet fork), gas profiling
- **Alchemy Monitor**: dApp analytics, webhook alerts on contract events

---

## WebSocket Subscriptions

- Endpoint: `wss://xlayerws.okx.com` (primary) or `wss://ws.xlayer.tech` (alternative)
- Supported events: `block`, `pending`, `logs` (contract events)
- ethers v6: `new ethers.WebSocketProvider("wss://xlayerws.okx.com")`
- viem: `createPublicClient({ transport: webSocket("wss://xlayerws.okx.com") })`

### Mandatory Rules
1. **Automatic reconnection** — WS connections can drop at any time; implement reconnect with backoff
2. **Chain reorg handling** — short-lived reorgs are possible; listen for removed logs
3. **Heartbeat/ping** — detect stale connections before they cause missed events
4. **Backpressure** — prevent event queue overflow at high throughput

---

## AggLayer & Cross-Chain

> **Note:** X Layer now runs on OP Stack. AggLayer integration continues but the primary bridge mechanism uses OP Stack's standard bridge.

### OP Stack Bridge (Current — Hybrid)
- `L1→L2` deposit: via OptimismPortal, ~minutes
- `L2→L1` withdrawal: OP Stack standard ~7 day challenge period (PermissionedDisputeGame)
- **AggLayer ZK proof integration** provides faster finality path: `aggsender` submits certificate → `agglayer-prover` generates ZK proof → proof submitted to L1
- Standard OP Stack bridge contracts (addresses in l2-predeploys.md)
- OKX front-end bridge deprecated August 15, 2025 — use community bridges or contracts directly

### AggLayer (Additional Layer)
- Pessimistic proof mechanism: assumes all chains are **insecure**
- Each chain's proof is independently verified
- Unified bridge vision: cross-chain transfer without wrapped tokens

### AggLayer v0.3+
- Non-CDK chain support (Ethereum L1, other L2s)
- Cross-chain atomic swap potential
- Shared liquidity layer vision

### Cross-Chain Message Pattern
For L2→L1 message sending code example, see `l2-predeploys.md` → Cross-Chain Message Pattern.
