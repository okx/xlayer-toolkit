# Flashblocks Monitor

监控 XLayer 测试网 flashblocks 行为，确认 flashblocks 不会 reorg。

- JIRA: https://okcoin.atlassian.net/browse/XLOP-858
- GitLab: https://gitlab.okg.com/github/flashblocks-monitor

## 监控项

### Alert 1: 延迟检查 (latency)

通过 flashblocks WS 收到 txHash 的时间不应晚于该 tx 所在区块的 `blocktime + 1s`。

- 触发条件: `receivedAt > blockTimestamp + MaxFlashblockDelay(默认1s)`
- 时机: 收到 transaction 事件时**立刻**判断（每笔 tx 独立检查）

### Alert 2: 交易存在性验证 (missing)

不能出现 flashblocks WS 中收到了 txHash，但延迟 1s 后反查该 txHash 发现不存在于区块中。

- 触发条件: `eth_getBlockByNumber(blockNum, false)` 查区块 tx 列表，flashblock 中的 tx 不在其中
- 时机: 同一区块的 tx 批量收集，**新 block header 到来时触发上一个 block 的验证**（一个 block 只发一次 RPC）
- 超时兜底: 如果 `VERIFY_TIMEOUT_S`（默认 5s）内未收到新 block header，强制触发验证，不会漏交易
- 如果区块尚未上链，会重试最多 4 次（每次间隔 500ms）
- WS 重连时自动清空待验证队列，避免断连期间数据不完整导致误报

### Alert 3: WS 断开 (ws_down)

WebSocket 连接断开时告警。

### Alert 4: WS 长时间不可用 (ws_long_down)

WebSocket 连续失败 >= 3 次且首次失败超过 `WS_LONG_DOWN_THRESHOLD_S`（默认 60s）时告警。

### Alert 5: 订阅失败 (subscribe_fail)

`eth_subscribe` 订阅请求失败时告警（超时、RPC 错误、空 subscription ID）。

### Alert 6: 静态 Peer 断开 (peer_disconnect)

通过 `conductor_leader` 找到 leader sequencer，再调用 `eth_flashblocksPeerStatus` 检查静态 peer 连接状态。

- 触发条件: 任何 `isStatic == true` 的 peer 的 `connectionState == "disconnected"`
- 时机: 每 `PEER_STATUS_POLL_INTERVAL_S`（默认 30s）轮询一次
- 流程: 遍历所有 `CONDUCTOR_URL`，调用 `conductor_leader` 找到 leader → 将 conductor 端口替换为 8123 得到 sequencer RPC → 调用 `eth_flashblocksPeerStatus` 获取 peer 状态
- 告警和日志包含每个断开 peer 的 PeerID 和 IP 地址

### Alert 7: Leader 查找失败 (leader_find_fail)

遍历所有 `CONDUCTOR_URL` 调用 `conductor_leader` 均失败或无 leader 时告警。

- 触发条件: 所有 conductor 均不可达或均非 leader
- 时机: 每次 peer status 轮询时

### Alert 8: Peer Status RPC 失败 (peer_status_fail)

找到 leader sequencer 后，调用 `eth_flashblocksPeerStatus` 失败时告警。

- 触发条件: RPC 请求失败、超时或返回错误
- 时机: 每次 peer status 轮询时

## WS 协议

使用 JSON-RPC `eth_subscribe` 协议（端口 8546）：

```
1. WS 连接 ws://host:8546
2. 发送订阅: {"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["flashblocks",{"headerInfo":true,"subTxFilter":{"txInfo":true,"txReceipt":true}}]}
3. 收到确认: {"jsonrpc":"2.0","id":1,"result":"<subscription_id>"}
4. 持续接收两种事件:
   - type: "header"      — 区块头（新 block 和每 200ms flashblock tick）
   - type: "transaction"  — 单笔交易（txHash + txData + receipt）
```

## 配置

支持 YAML 配置文件 + 环境变量覆盖。启动时通过 `-config` 指定配置文件路径（默认 `cfg.yml`）。

```yaml
# Flashblocks WebSocket 地址 (JSON-RPC eth_subscribe)
WS_URL: "ws://10.2.29.244:8546"

# XLayer RPC 地址
RPC_URL: "http://10.2.29.244:8545"

# Lark 配置 (xmonitor 格式)
APM_BOT_URL: "https://apm.okg.com/alarm/channel/robot/send?receiveIdType=chat_id"
LARK_GROUP_ID: ""

# 是否开启 Lark 告警 (false 时仅打日志不发消息)
ALERT_ENABLED: true

# Alert 1: flashblock 接收延迟阈值（毫秒）
MAX_FLASHBLOCK_DELAY_MS: 1000

# Alert 2: 触发验证后延迟多久再查区块（毫秒），等区块上链
TX_CHECK_DELAY_MS: 1000

# Lark 告警限频间隔（秒），同类型告警在此间隔内最多发 1 条
ALERT_RATE_LIMIT_S: 30

# WebSocket 长时间连不上告警阈值（秒）
WS_LONG_DOWN_THRESHOLD_S: 60

# Alert 2 批量验证超时兜底（秒），超过此时间未收到新 block header 则强制触发验证
VERIFY_TIMEOUT_S: 5

# RPC 请求超时（秒）
RPC_TIMEOUT_S: 10

# Conductor 地址 (逗号分隔)
CONDUCTOR_URL: "http://10.2.29.244:50050,http://10.2.27.29:50050"

# Peer status 轮询间隔（秒）
PEER_STATUS_POLL_INTERVAL_S: 30

# 是否开启详细日志
VERBOSE: false
```

所有配置项都可通过同名环境变量覆盖，例如 `WS_URL=ws://xxx ./flashbox-monitor`。

## 数据流

```
WS 连接 --> eth_subscribe --> 持续接收事件
                                  |
                    +-------------+-------------+
                    |                           |
              type: header               type: transaction
            更新 blockContext            过滤 deposit (0x7e)
            blockNum 变化时                    |
            触发上一 block             +-------+-------+
            的批量验证                 |               |
                                  Alert 1         Alert 2
                               (立刻判断)     (收集到 batch)
                             延迟 > 1s ?     等新 block 或超时
                                  |           批量 RPC 验证
                            告警 Lark        tx 不在区块中?
                                                   |
                                             告警 Lark

Peer Status Monitor (独立 goroutine，每 30s 轮询):
  CONDUCTOR_URL 列表 --> conductor_leader --> 找到 leader
        |                                      失败? --> Alert 7 (leader_find_fail)
  替换端口为 8123 --> eth_flashblocksPeerStatus
        |                                      失败? --> Alert 8 (peer_status_fail)
  检查 isStatic && disconnected --> Alert 6 (peer_disconnect)
```

## 日志说明

### 1. 启动配置

```
========================================
  Flashblocks Monitor
========================================
  WS URL:          ws://10.2.29.244:8546
  RPC URL:         http://10.2.29.244:8545
  Lark Bot URL:    https://apmapi.okg.com/alarm/...
  Lark Group ID:   oc_16b2e6dbfde509708503a76cee8ae8e4
  Alert Enabled:   true
  Max Delay:       1s
  TX Check Delay:  1s
  Alert Rate Limit:30s
  Verify Timeout:  5s
  RPC Timeout:     10s
  Conductors:      [http://10.2.29.244:50050 http://10.2.27.29:50050]
  Peer Poll:       30s
  Verbose:         false
========================================
```

### 2. WS 连接与订阅

```
[WS] Connecting to ws://10.2.29.244:8546 ...
[WS] Connected to ws://10.2.29.244:8546
[WS] Sent eth_subscribe request
[WS] Subscribed successfully, subscription ID: 0x863aa52cc1d8770170737deb785bc7cb
```

连接、发送订阅、收到确认的完整流程。

### 3. 收到用户交易

```
[WS] Block #26488167: tx 0xabc123...def456 (type: 0x2, from: 0x1234abcd5678...)
```

| 字段 | 含义 |
|------|------|
| `Block #26488167` | 交易所在区块号 |
| `tx 0xabc123...` | 交易哈希 |
| `type: 0x2` | 交易类型（0x2 = EIP-1559，0x0 = legacy 等，0x7e deposit 已过滤） |
| `from: 0x1234...` | 发送者地址（截取前 16 字符） |

每笔用户交易都会打印此日志。deposit 系统交易（type 0x7e）自动跳过不打印。

### 4. 定时统计（每 60 秒）

```
[STATS] flashblocks=1440 tracked=4 confirmed=4 missing=0 latency_alerts=0 reconnects=0
```

| 字段 | 含义 |
|------|------|
| `flashblocks` | 累计收到的 WS 事件总数（header + transaction，含 deposit） |
| `tracked` | 累计跟踪的用户交易数（过滤 deposit 后） |
| `confirmed` | Alert 2 验证通过的数量（tx 在链上） |
| `missing` | Alert 2 验证失败的数量（tx 不在区块中，疑似 reorg） |
| `latency_alerts` | Alert 1 触发的交易数（收到时间 > blocktime + 1s） |
| `reconnects` | WS 断线重连次数 |

正常运行时 `tracked == confirmed + missing`，`missing` 和 `latency_alerts` 应该是 0。

### 5. Alert 1 — 延迟告警

```
[ALERT][latency] Flashblock latency > 1s at block #26488167
Block: #26488167
Block time: 08:48:30
Received at: 08:48:31.500
Delay: 1.5s
Threshold: 1s
Tx: 0xabc123...
```

收到 transaction 事件时立刻判断 `receivedAt > blockTimestamp + 1s` 就触发。同类型告警 30s 内最多发一次 Lark。

### 6. Alert 2 — 交易缺失告警（疑似 reorg）

正常触发（新 block 到来时）：
```
[REORG] Block #26488167: 3 confirmed, 1 MISSING
```

超时兜底触发：
```
[CHECK] Block #26488167: verify timeout triggered (5s), forcing verification
[REORG] Block #26488167: 3 confirmed, 1 MISSING
```

Lark 告警内容：
```
[ALERT][missing] Tx missing from block #26488167 (1 txs)
Block: #26488167
Checked after: 1s
Confirmed: 3
MISSING: 1

Missing tx hashes:
  0xabc123...
```

同一区块的 tx 批量收集、一次 RPC 验证。验证由两种方式触发：
- **正常**: 收到新 block header 时触发上一个 block 的验证
- **兜底**: 超过 `VERIFY_TIMEOUT_S`（默认 5s）未收到新 block header，强制触发

### 7. Alert 3 — WS 断开告警

```
[WS] Disconnected: read: websocket: close 1006: abnormal closure, reconnecting in 1s... (consecutive fails: 1)
[ALERT][ws_down] WebSocket disconnected
```

每次 WS 断开打印。Lark 告警受限频控制。

### 8. Alert 4 — WS 长时间不可用告警

```
[ALERT][ws_long_down] WebSocket unavailable for 65s
URL: ws://10.2.29.244:8546
Consecutive failures: 5
First failure: 2026-04-01 08:45:47
Last error: dial: connection refused
```

连续失败 >= 3 次且首次失败超过 `WS_LONG_DOWN_THRESHOLD_S`（默认 60s）时触发。

### 9. Alert 5 — 订阅失败告警

```
[ALERT][subscribe_fail] Flashblocks subscribe failed
URL: ws://10.2.29.244:8546
RPC Error: [-32601] method not found
```

`eth_subscribe` 请求失败时触发（超时、RPC 错误、返回空 subscription ID）。

### 10. Alert 6 — 静态 Peer 断开告警

终端日志（每个断开的 peer 单独一行）：
```
[PEER] Static peer disconnected: peerID=16Uiu2HAm... addr=/ip4/10.2.27.29/tcp/9222 disconnected_for=45.2s connections=12
```

Lark 告警内容：
```
[ALERT][peer_disconnect] 1 static peer(s) disconnected
Leader Sequencer: http://10.2.29.244:8123
Local Peer: 16Uiu2HAm...
Disconnected static peers: 1 / 3 static

  PeerID: 16Uiu2HAm...
  Addr: /ip4/10.2.27.29/tcp/9222
  Disconnected for: 45.2s
  Connection count: 12
```

Peer status monitor 每 30s 轮询一次，发现静态 peer 断开时触发。所有 peer 正常连接时打印：
```
[PEER] All 3 static peers connected
```

### 11. Alert 7 — Leader 查找失败告警

```
[PEER] no leader found among conductors [http://10.2.29.244:8547 http://10.2.27.29:8547]
[ALERT][leader_find_fail] Failed to find leader sequencer
Conductors: [http://10.2.29.244:8547 http://10.2.27.29:8547]
Error: no leader found among conductors [...]
```

所有 conductor 均不可达或均非 leader 时触发。

### 12. Alert 8 — Peer Status RPC 失败告警

```
[PEER] Failed to get peer status from http://10.2.29.244:8123: rpc post: connection refused
[ALERT][peer_status_fail] Peer status RPC failed
Leader Sequencer: http://10.2.29.244:8123
Error: rpc post: connection refused
```

找到 leader 后调用 `eth_flashblocksPeerStatus` 失败时触发。

### 13. 区块查询重试（Verbose 模式或最终失败时）

```
[CHECK] Block #26488167 not available (attempt 1/4): block not found, retrying...
[CHECK] Block #26488167 still unavailable after retries: block not found, skipping
```

Alert 2 验证时区块尚未上链的重试日志。重试中的日志仅 `VERBOSE: true` 时打印，全部失败的日志始终打印。

### 14. Verbose 模式额外日志（VERBOSE: true）

```
[WS] New block #26488167 (ts: 1775123456, hash: 0xbd83b4c392300...)
[WS] Skipping deposit tx: 0x2dc9d13d...
[WS] Transaction 0xabc123... but no block context, skipping
[WS] Ignoring non-subscription message: method=eth_subscription
[WS] Unknown event type: newPendingTransactions
[OK] Block #26488167: all 3 txs confirmed
```

日常运行建议关闭 verbose，排查问题时打开。

## Lark 告警消息格式

所有告警发送到 Lark 时的消息格式：

```
Flashblocks Monitor Alert

[{alertType}] {title}

{details}

Time: 2026-04-01 08:48:31
```

其中 `alertType` 为 `latency` / `missing` / `ws_down` / `ws_long_down` / `subscribe_fail` / `peer_disconnect` / `leader_find_fail` / `peer_status_fail` 八种之一。

告警通过 xmonitor 格式发送到指定 Lark 群：
- 8 种告警类型独立限频，互不影响
- 同类型告警在 `ALERT_RATE_LIMIT_S`（默认 30s）内最多发 1 条
- `ALERT_ENABLED: false` 时所有告警仅打日志，不发 Lark

## 重连机制

WS 断开后自动重连，指数退避：

```
断开 -> sleep 1s -> 重连
再断 -> sleep 2s -> 重连
再断 -> sleep 4s -> 重连
... 最大 30s
```

如果连接成功且持续超过 30s 后再断开，退避时间重置为 1s。

重连时自动清空 `pendingTxs`，因为断连期间可能错过了一些 tx 和 header，残留数据验证意义不大。

## 构建与运行

```bash
# 本地构建
go build -o flashbox-monitor .

# 运行（默认读取 cfg.yml）
./flashbox-monitor

# 指定配置文件
./flashbox-monitor -config /path/to/config.yml

# 环境变量覆盖
WS_URL=ws://127.0.0.1:8546 VERBOSE=true ./flashbox-monitor

# 仅运行 Peer Status Monitor（Alert 6/7/8），跳过 WS 相关监控（Alert 1-5）
WS_URL="" CONDUCTOR_URL="http://10.2.29.244:8547,http://10.2.27.29:8547" ./flashbox-monitor
```

## Docker

```bash
# 构建（x86_64/amd64）
docker buildx build --platform linux/amd64 -t flashbox-monitor .

# 运行
docker run flashbox-monitor

# 环境变量覆盖
docker run -e WS_URL=ws://host:8546 -e LARK_GROUP_ID=oc_xxx flashbox-monitor
```

## Deposit 交易过滤

L1 deposit 交易（type 0x7e）是每个区块必有的系统交易，监控它没有意义。程序通过 `txData.type == "0x7e"` 自动过滤，不纳入跟踪和验证。
