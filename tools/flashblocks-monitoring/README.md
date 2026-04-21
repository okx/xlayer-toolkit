# Flashblocks Monitor

Monitors XLayer testnet flashblocks behavior, verifying that flashblocks do not reorg, and p2p static peers are not disconnected.

## Alerts

### Alert 1: Latency Check (latency)

The time a txHash is received via flashblocks WS should not be later than the block's `blocktime + 1s`.

- Trigger: `receivedAt > blockTimestamp + MaxFlashblockDelay (default 1s)`
- Timing: Checked **immediately** when a transaction event is received (each tx checked independently)

### Alert 2: Transaction Existence Verification (missing)

A txHash received via flashblocks WS must exist in the canonical block when verified after a 1s delay.

- Trigger: `eth_getBlockByNumber(blockNum, false)` returns a block whose tx list does not contain the flashblock tx
- Timing: Txs from the same block are batch-collected; **verification is triggered when a new block header arrives** (one RPC call per block)
- Fallback timeout: If no new block header is received within `VERIFY_TIMEOUT_S` (default 5s), verification is forced to avoid missed txs
- If the block is not yet on-chain, retries up to 4 times (500ms apart)
- Pending verification queue is cleared on WS reconnect to avoid false positives from incomplete data during disconnect

### Alert 3: WS Disconnected (ws_down)

Alerts when the WebSocket connection is disconnected.

### Alert 4: WS Long Downtime (ws_long_down)

Alerts when WebSocket has >= 3 consecutive failures and the first failure occurred more than `WS_LONG_DOWN_THRESHOLD_S` (default 60s) ago.

### Alert 5: Subscribe Failed (subscribe_fail)

Alerts when the `eth_subscribe` request fails (timeout, RPC error, or empty subscription ID).

### Alert 6: Static Peer Disconnected (peer_disconnect)

Finds the leader sequencer via `conductor_leader`, then calls `eth_flashblocksPeerStatus` to check static peer connection status.

- Trigger: Any peer with `isStatic == true` has `connectionState == "disconnected"`
- Timing: Polled every `PEER_STATUS_POLL_INTERVAL_S` (default 5s)
- Flow: Iterates all configured conductor-sequencer pairs, calls `conductor_leader` to find leader → uses the paired sequencer RPC URL → calls `eth_flashblocksPeerStatus` for peer status
- Alerts and logs include PeerID and IP address for each disconnected peer

### Alert 7: Leader Discovery Failed (leader_find_fail)

Alerts when all configured conductors fail to respond or none is the leader.

- Trigger: All conductors are unreachable or none reports as leader
- Timing: Each peer status poll cycle

### Alert 8: Peer Status RPC Failed (peer_status_fail)

Alerts when `eth_flashblocksPeerStatus` call fails after finding the leader sequencer.

- Trigger: RPC request fails, times out, or returns an error
- Timing: Each peer status poll cycle

## WS Protocol

Uses JSON-RPC `eth_subscribe` protocol (port 8546):

```
1. WS connect to ws://host:8546
2. Send subscribe: {"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["flashblocks",{"headerInfo":true,"subTxFilter":{"txInfo":true,"txReceipt":true}}]}
3. Receive confirmation: {"jsonrpc":"2.0","id":1,"result":"<subscription_id>"}
4. Continuously receive two event types:
   - type: "header"      — block header (new block and every 200ms flashblock tick)
   - type: "transaction"  — single transaction (txHash + txData + receipt)
```

## Configuration

Supports YAML config file + environment variable overrides. Specify config file path at startup with `-config` (default `cfg.yml`).

```yaml
# Flashblocks WebSocket address (JSON-RPC eth_subscribe)
WS_URL: "ws://localhost:7547"

# XLayer RPC address
RPC_URL: "http://localhost:8545"

# Lark config (xmonitor format)
APM_BOT_URL: ""
LARK_GROUP_ID: ""

# Enable Lark alerts (false = log only, no messages sent)
ALERT_ENABLED: true

# Alert 1: flashblock receive latency threshold (milliseconds)
MAX_FLASHBLOCK_DELAY_MS: 1000

# Alert 2: delay before verifying tx against block (milliseconds), wait for block to be on-chain
TX_CHECK_DELAY_MS: 1000

# Lark alert rate limit interval (seconds), max 1 alert per type within this interval
ALERT_RATE_LIMIT_S: 30

# WebSocket long downtime alert threshold (seconds)
WS_LONG_DOWN_THRESHOLD_S: 60

# Alert 2 batch verification fallback timeout (seconds), forces verification if no new block header received
VERIFY_TIMEOUT_S: 5

# RPC request timeout (seconds)
RPC_TIMEOUT_S: 10

# Conductor to sequencer RPC pairs
CONDUCTOR1_URL: "http://localhost:8547"
SEQUENCER1_URL: "http://localhost:8123"
CONDUCTOR2_URL: "http://localhost:8548"
SEQUENCER2_URL: "http://localhost:8223"

# Peer status poll interval (seconds)
PEER_STATUS_POLL_INTERVAL_S: 5

# Enable verbose logging
VERBOSE: false
```

All config options can be overridden with environment variables of the same name, e.g. `WS_URL=ws://xxx ./flashblocks-monitor`.

## Data Flow

```
WS connect --> eth_subscribe --> continuously receive events
                                      |
                        +-------------+-------------+
                        |                           |
                  type: header               type: transaction
                update blockContext           filter deposit (0x7e)
                on blockNum change                  |
                trigger prev block           +------+-------+
                batch verification           |              |
                                         Alert 1        Alert 2
                                      (immediate)    (collect to batch)
                                      delay > 1s?    wait for new block
                                           |          or timeout, then
                                      alert Lark      batch RPC verify
                                                     tx not in block?
                                                          |
                                                    alert Lark

Peer Status Monitor (separate goroutine, polls every 5s):
  Conductor-Sequencer pairs --> conductor_leader --> find leader
        |                                             failure? --> Alert 7 (leader_find_fail)
  use paired sequencer URL --> eth_flashblocksPeerStatus
        |                                      failure? --> Alert 8 (peer_status_fail)
  check isStatic && disconnected --> Alert 6 (peer_disconnect)
```

## Log Reference

### 1. Startup Config

```
========================================
  Flashblocks Monitor
========================================
  WS URL:          ws://localhost:7547
  RPC URL:         http://localhost:8545
  Lark Bot URL:    
  Lark Group ID:   
  Alert Enabled:   false
  Max Delay:       1s
  TX Check Delay:  1s
  Alert Rate Limit:30s
  Verify Timeout:  5s
  RPC Timeout:     10s
  Conductor 1:     http://localhost:8547 -> http://localhost:8123
  Conductor 2:     http://localhost:8548 -> http://localhost:8223
  Peer Poll:       5s
  Verbose:         false
========================================
```

### 2. WS Connection & Subscription

```
[WS] Connecting to ws://localhost:7547 ...
[WS] Connected to ws://localhost:7547
[WS] Sent eth_subscribe request
[WS] Subscribed successfully, subscription ID: 0x863aa52cc1d8770170737deb785bc7cb
```

Full flow of connect, subscribe, and confirmation.

### 3. User Transaction Received

```
[WS] Block #26488167: tx 0xabc123...def456 (type: 0x2, from: 0x1234abcd5678...)
```

| Field | Description |
|-------|-------------|
| `Block #26488167` | Block number containing the transaction |
| `tx 0xabc123...` | Transaction hash |
| `type: 0x2` | Transaction type (0x2 = EIP-1559, 0x0 = legacy, etc.; 0x7e deposit is filtered out) |
| `from: 0x1234...` | Sender address (truncated to first 16 characters) |

Logged for every user transaction. Deposit system transactions (type 0x7e) are automatically skipped.

### 4. Periodic Stats (every 60 seconds)

```
[STATS] flashblocks=1440 tracked=4 confirmed=4 missing=0 latency_alerts=0 reconnects=0
```

| Field | Description |
|-------|-------------|
| `flashblocks` | Total WS events received (header + transaction, including deposit) |
| `tracked` | Total user transactions tracked (after filtering deposit) |
| `confirmed` | Alert 2 verifications passed (tx found on-chain) |
| `missing` | Alert 2 verifications failed (tx not in block, possible reorg) |
| `latency_alerts` | Alert 1 triggered count (received time > blocktime + 1s) |
| `reconnects` | WS reconnection count |

During normal operation `tracked == confirmed + missing`, and `missing` and `latency_alerts` should be 0.

### 5. Alert 1 — Latency Alert

```
[ALERT][latency] Flashblock latency > 1s at block #26488167
Block: #26488167
Block time: 08:48:30
Received at: 08:48:31.500
Delay: 1.5s
Threshold: 1s
Tx: 0xabc123...
```

Triggered immediately when `receivedAt > blockTimestamp + 1s`. Same alert type is rate-limited to max 1 Lark message per 30s.

### 6. Alert 2 — Missing Transaction Alert (possible reorg)

Normal trigger (new block arrives):
```
[REORG] Block #26488167: 3 confirmed, 1 MISSING
```

Fallback timeout trigger:
```
[CHECK] Block #26488167: verify timeout triggered (5s), forcing verification
[REORG] Block #26488167: 3 confirmed, 1 MISSING
```

Lark alert content:
```
[ALERT][missing] Tx missing from block #26488167 (1 txs)
Block: #26488167
Checked after: 1s
Confirmed: 3
MISSING: 1

Missing tx hashes:
  0xabc123...
```

Txs from the same block are batch-collected and verified in a single RPC call. Verification is triggered by:
- **Normal**: When a new block header arrives, triggers verification of the previous block
- **Fallback**: When no new block header is received within `VERIFY_TIMEOUT_S` (default 5s), forces verification

### 7. Alert 3 — WS Disconnected Alert

```
[WS] Disconnected: read: websocket: close 1006: abnormal closure, reconnecting in 1s... (consecutive fails: 1)
[ALERT][ws_down] WebSocket disconnected
```

Printed on every WS disconnect. Lark alerts are subject to rate limiting.

### 8. Alert 4 — WS Long Downtime Alert

```
[ALERT][ws_long_down] WebSocket unavailable for 65s
URL: ws://localhost:8546
Consecutive failures: 5
First failure: 2026-04-01 08:45:47
Last error: dial: connection refused
```

Triggered when >= 3 consecutive failures and first failure was more than `WS_LONG_DOWN_THRESHOLD_S` (default 60s) ago.

### 9. Alert 5 — Subscribe Failed Alert

```
[ALERT][subscribe_fail] Flashblocks subscribe failed
URL: ws://localhost:8546
RPC Error: [-32601] method not found
```

Triggered when `eth_subscribe` request fails (timeout, RPC error, or empty subscription ID).

### 10. Alert 6 — Static Peer Disconnected Alert

Terminal log (one line per disconnected peer):
```
[PEER] Static peer disconnected: peerID=16Uiu2HAm... addr=/ip4/localhost/tcp/9222 disconnected_for=45.2s connections=12
```

Lark alert content:
```
[ALERT][peer_disconnect] 1 static peer(s) disconnected
Leader Sequencer: http://localhost:8123
Local Peer: 16Uiu2HAm...
Disconnected static peers: 1 / 3 static

  PeerID: 16Uiu2HAm...
  Addr: /ip4/localhost/tcp/9222
  Disconnected for: 45.2s
  Connection count: 12
```

Peer status monitor polls every 5s, triggers when static peers are disconnected. When all peers are connected:
```
[PEER] All 3 static peers connected
```

### 11. Alert 7 — Leader Discovery Failed Alert

```
[PEER] no leader found among conductors [http://localhost:8547 http://localhost:8548]
[ALERT][leader_find_fail] Failed to find leader sequencer
Conductors: [{http://localhost:8547 http://localhost:8123} {http://localhost:8548 http://localhost:8223}]
Error: no leader found among conductors [...]
```

Triggered when all conductors are unreachable or none reports as leader.

### 12. Alert 8 — Peer Status RPC Failed Alert

```
[PEER] Failed to get peer status from http://localhost:8123: rpc post: connection refused
[ALERT][peer_status_fail] Peer status RPC failed
Leader Sequencer: http://localhost:8123
Error: rpc post: connection refused
```

Triggered when `eth_flashblocksPeerStatus` call fails after finding the leader.

### 13. Block Query Retries (verbose mode or final failure)

```
[CHECK] Block #26488167 not available (attempt 1/4): block not found, retrying...
[CHECK] Block #26488167 still unavailable after retries: block not found, skipping
```

Retry logs during Alert 2 verification when the block is not yet on-chain. Retry attempt logs only print with `VERBOSE: true`; final failure logs always print.

### 14. Verbose Mode Extra Logs (VERBOSE: true)

```
[WS] New block #26488167 (ts: 1775123456, hash: 0xbd83b4c392300...)
[WS] Skipping deposit tx: 0x2dc9d13d...
[WS] Transaction 0xabc123... but no block context, skipping
[WS] Ignoring non-subscription message: method=eth_subscription
[WS] Unknown event type: newPendingTransactions
[OK] Block #26488167: all 3 txs confirmed
```

Recommended to keep verbose off during normal operation; enable when troubleshooting.

## Lark Alert Message Format

All alerts sent to Lark use this format:

```
Flashblocks Monitor Alert

[{alertType}] {title}

{details}

Time: 2026-04-01 08:48:31
```

Where `alertType` is one of: `latency` / `missing` / `ws_down` / `ws_long_down` / `subscribe_fail` / `peer_disconnect` / `leader_find_fail` / `peer_status_fail`.

Alerts are sent to the specified Lark group via xmonitor format:
- 8 alert types are rate-limited independently
- Max 1 alert per type within `ALERT_RATE_LIMIT_S` (default 30s)
- When `ALERT_ENABLED: false`, all alerts are logged only, no Lark messages sent

## Reconnection

WS reconnects automatically with exponential backoff:

```
disconnect -> sleep 1s -> reconnect
again      -> sleep 2s -> reconnect
again      -> sleep 4s -> reconnect
... max 30s
```

If connection was stable for >30s before disconnecting, backoff resets to 1s.

`pendingTxs` are cleared on reconnect since data may be incomplete during the disconnect period, and stale data would produce unreliable verification results.

## Build & Run

```bash
# Build locally
go build -o flashblocks-monitor .

# Run (reads cfg.yml by default)
./flashblocks-monitor

# Specify config file
./flashblocks-monitor -config /path/to/config.yml

# Override with environment variables
WS_URL=ws://127.0.0.1:8546 VERBOSE=true ./flashblocks-monitor

# Run Peer Status Monitor only (Alert 6/7/8), skip WS monitoring (Alert 1-5)
WS_URL="" CONDUCTOR1_URL="http://localhost:8547" SEQUENCER1_URL="http://localhost:8123" CONDUCTOR2_URL="http://localhost:8548" SEQUENCER2_URL="http://localhost:8223" ./flashblocks-monitor
```

## Docker

```bash
# Build (x86_64/amd64)
docker buildx build --platform linux/amd64 -t flashblocks-monitor .

# Run
docker run flashblocks-monitor

# Override with environment variables
docker run -e WS_URL=ws://host:8546 -e LARK_GROUP_ID=oc_xxx flashblocks-monitor
```

## Deposit Transaction Filtering

L1 deposit transactions (type 0x7e) are system transactions present in every block — monitoring them is not useful. The program automatically filters them via `txData.type == "0x7e"`, excluding them from tracking and verification.
