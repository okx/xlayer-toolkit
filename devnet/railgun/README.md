# RAILGUN Privacy System Integration

这个目录包含 RAILGUN 隐私支付系统在 devnet 中的集成配置。

## 📋 目录结构

```
railgun/
├── README.md                    # 本文档
├── example.env.contract         # 合约部署配置示例
├── example.env.poi              # POI 节点配置示例
├── example.env.broadcaster      # Broadcaster 配置示例
├── .env.contract               # 实际合约部署配置（自动生成）
├── .env.poi                    # 实际 POI 节点配置（自动生成）
├── .env.broadcaster            # 实际 Broadcaster 配置（自动生成）
├── config/                     # 运行时配置目录
└── deployments/                # 合约部署结果目录
```

## 🚀 快速开始

### 1. 启用 RAILGUN

编辑 `devnet/example.env`：

```bash
# 最小化配置（仅需 2 项）
RAILGUN_ENABLE=true
RAILGUN_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/pt

# 首次部署需要构建镜像（可选）
SKIP_RAILGUN_CONTRACT_BUILD=false
SKIP_RAILGUN_POI_BUILD=false
SKIP_RAILGUN_BROADCASTER_BUILD=false
```

**注意**：
- ✅ 所有端口和密码已硬编码为默认值
- ✅ POI: 8080, Broadcaster: 3000, Waku: 60001/60002
- ✅ MongoDB 密码: railgun-poi-pass
- ✅ Native token (OKB/ETH) 默认支持，无需额外配置

### 2. 同步配置

```bash
cd /Users/oker/workspace/xlayer/xlayer-toolkit/devnet
./clean.sh
```

### 3. 运行部署

```bash
# 方式 1: 完整部署（包含 RAILGUN）
make run

# 方式 2: 仅部署 RAILGUN（假设 L2 已运行）
./7-run-railgun.sh
```

## 💰 代币支持

RAILGUN 支持以下代币的隐私交易：

### Native Token（推荐用于测试）
- ✅ **OKB** - X Layer 原生代币
- ✅ **ETH** - 以太坊原生代币
- ✅ **无需额外配置** - 开箱即用

### ERC20 代币（可选）
- ✅ **USDC** - 稳定币
- ✅ **DAI** - 稳定币
- ✅ **任何 ERC20 代币** - 需要配置合约地址

**建议**：
- 🧪 **开发测试**: 使用 Native Token (OKB)，最简单
- 🏭 **生产环境**: 根据业务需求配置具体的 ERC20 代币

## 📦 组件说明

### 1. 智能合约 (Contract)

**作用**: RAILGUN 隐私交易核心合约

**部署内容**:
- `RailgunSmartWallet` - 隐私钱包主合约
- `RailgunLogic` - 业务逻辑合约
- `RelayAdapt` - 中继适配器
- `Voting` - 治理投票合约
- `Staking` - 质押合约

**配置文件**: `.env.contract`

### 2. POI 节点 (Proof of Innocence Node)

**作用**: 验证用户隐私证明，防止非法资金进入隐私池

**功能**:
- 监听 L2 区块链上的 RAILGUN 事件
- 维护 Merkle 树状态
- 提供 RPC API 供客户端查询
- 存储黑名单和白名单

**端口**: 8080 (可配置)

**配置文件**: `.env.poi`

**健康检查**:
```bash
curl http://localhost:8080/health
```

### 3. Broadcaster (交易广播服务)

**作用**: 通过 Waku P2P 网络广播隐私交易

**功能**:
- 接收客户端的隐私交易请求
- 通过 Waku 网络广播交易
- 代付 Gas 费用（用户用代币支付）
- 广播费率信息

**端口**:
- API: 3000
- Waku P2P: 60001, 60002

**配置文件**: `.env.broadcaster`

## 🔧 配置说明

### 合约部署配置 (.env.contract)

```bash
# L2 RPC URL（自动配置）
RPC_URL=http://op-seq-el:8545

# Chain ID（自动配置）
CHAIN_ID=195

# 部署者私钥（从主配置继承）
DEPLOYER_PRIVATE_KEY=0x...

# Gas 配置
GAS_PRICE=1000000000
GAS_LIMIT=10000000

# 是否部署测试代币
DEPLOY_TEST_TOKENS=true
```

### POI 节点配置 (.env.poi)

```bash
# L2 RPC URL
RPC_URL=http://op-seq-el:8545

# RAILGUN 合约地址（部署后自动填充）
RAILGUN_SMART_WALLET_ADDRESS=0x...

# MongoDB 连接
MONGODB_URL=mongodb://railgun:pass@railgun-poi-mongodb:27017

# 同步配置
START_BLOCK=0
SYNC_BATCH_SIZE=1000
SYNC_INTERVAL_MS=5000

# 日志级别
LOG_LEVEL=info
```

### Broadcaster 配置 (.env.broadcaster)

```bash
# L2 RPC URL
RPC_URL=http://op-seq-el:8545

# POI 节点 URL
POI_NODE_URL=http://railgun-poi-node:8080

# Broadcaster 钱包私钥
WALLET_PRIVATE_KEY=0x...

# Waku 配置
WAKU_PUBSUB_TOPIC=/waku/2/railgun-xlayer-devnet
WAKU_CONTENT_TOPIC_TRANSACT=/railgun/v2/transact-xlayer-devnet

# Gas 配置
GAS_PRICE_MULTIPLIER=1.1
MAX_GAS_PRICE_GWEI=50

# 费率广播间隔
FEE_BROADCAST_INTERVAL_MS=30000
```

## 📊 服务管理

### 查看服务状态

```bash
docker compose ps | grep railgun
```

### 查看日志

```bash
# POI 节点日志
docker compose logs -f railgun-poi-node

# Broadcaster 日志
docker compose logs -f railgun-broadcaster

# MongoDB 日志
docker compose logs -f railgun-poi-mongodb
```

### 重启服务

```bash
# 重启所有 RAILGUN 服务
docker compose restart railgun-poi-mongodb railgun-poi-node railgun-broadcaster

# 重启单个服务
docker compose restart railgun-poi-node
```

### 停止服务

```bash
# 停止所有 RAILGUN 服务
docker compose stop railgun-poi-mongodb railgun-poi-node railgun-broadcaster

# 停止单个服务
docker compose stop railgun-poi-node
```

## 🧪 测试验证

### 1. 验证合约部署

```bash
# 查看部署的合约地址
cat deployments/*.json | jq '.address'

# 或查看环境变量
source ../.env
echo $RAILGUN_SMART_WALLET_ADDRESS
```

### 2. 验证 POI 节点

```bash
# 健康检查
curl http://localhost:8080/health

# 获取 Merkle Root
curl -X POST http://localhost:8080/rpc \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "poi_merkleroot",
    "params": [{
      "chain": {"type": 0, "id": 195},
      "listKey": "default"
    }],
    "id": 1
  }'
```

### 3. 验证 Broadcaster

```bash
# 检查 Broadcaster API
curl http://localhost:3000/health

# 查看 Waku 节点连接
docker compose logs railgun-broadcaster | grep -i "waku"
```

## 🔍 故障排查

### POI 节点无法启动

**问题**: POI 节点容器一直重启

**解决方案**:
1. 检查 MongoDB 是否正常运行
2. 检查 L2 RPC URL 是否可访问
3. 查看日志: `docker compose logs railgun-poi-node`

### 合约部署失败

**问题**: 合约部署返回错误

**解决方案**:
1. 确认 L2 网络正常运行
2. 检查部署者账户余额
3. 验证 Gas 配置是否合理
4. 查看部署日志

### Broadcaster 无法连接 POI 节点

**问题**: Broadcaster 日志显示无法连接 POI 节点

**解决方案**:
1. 确认 POI 节点已启动并健康
2. 检查网络连接: `docker network inspect dev-op`
3. 验证 POI_NODE_URL 配置

## 📚 相关文档

- [RAILGUN 完整部署指南](/Users/oker/workspace/xlayer/pt/DevNet部署指南-ChainID195.md)
- [RAILGUN 系统架构](/Users/oker/workspace/xlayer/pt/完整系统架构与密钥体系.md)
- [电路模块详解](/Users/oker/workspace/xlayer/pt/电路模块详解.md)

## 🆘 获取帮助

如遇到问题，请查看：
1. POI 节点日志: `docker compose logs railgun-poi-node`
2. Broadcaster 日志: `docker compose logs railgun-broadcaster`
3. 合约部署日志: `cat deployments/*.log`
4. 主部署脚本: `../7-run-railgun.sh`

