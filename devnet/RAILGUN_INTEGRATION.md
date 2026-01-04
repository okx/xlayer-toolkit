# RAILGUN 隐私系统集成指南

本文档说明如何在 devnet 中启用和使用 RAILGUN 隐私支付系统。

## 📖 概述

RAILGUN 是一个基于零知识证明的隐私支付协议，已集成到 devnet 作为可选组件（第 7 步）。

### 集成架构

```
devnet 部署流程:
├── 1-start-l1.sh           # L1 链启动
├── 2-deploy-op-contracts.sh # OP Stack 合约部署
├── 3-op-init.sh            # L2 初始化
├── 4-op-start-service.sh   # L2 服务启动
├── 5-run-op-succinct.sh    # OP-Succinct (可选)
├── 6-run-kailua.sh         # Kailua (可选)
└── 7-run-railgun.sh        # RAILGUN (新增) ⭐
```

### RAILGUN 组件

```
RAILGUN 系统:
├── 智能合约 (Contract)
│   ├── RailgunSmartWallet    # 隐私钱包核心
│   ├── RailgunLogic          # 业务逻辑
│   ├── RelayAdapt            # 中继适配
│   └── Voting/Staking        # 治理模块
│
├── POI 节点 (Proof of Innocence)
│   ├── MongoDB               # 数据存储
│   ├── Event Indexer         # 事件索引
│   └── RPC API               # 客户端接口
│
└── Broadcaster
    ├── Waku P2P Network      # 交易广播
    ├── Fee Manager           # 费率管理
    └── Transaction Relayer   # 交易中继
```

## 🚀 快速启动

### 前置条件

1. **RAILGUN 源码**: 确保已克隆 RAILGUN 仓库
   ```bash
   # 如果还没有克隆
   cd /Users/oker/workspace/xlayer
   git clone <railgun-repo-url> pt
   ```

2. **Docker 环境**: 确保 Docker 和 Docker Compose 已安装

3. **L2 网络运行**: devnet 的 L2 网络应该已经在运行

### 启用 RAILGUN

#### 方法 1: 完整部署（推荐）

```bash
cd /Users/oker/workspace/xlayer/xlayer-toolkit/devnet

# 1. 编辑配置
vim example.env

# 修改以下配置:
RAILGUN_ENABLE=true
RAILGUN_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/pt

# 首次部署需要构建镜像
SKIP_RAILGUN_CONTRACT_BUILD=false
SKIP_RAILGUN_POI_BUILD=false
SKIP_RAILGUN_BROADCASTER_BUILD=false

# 2. 同步配置（会清理旧数据并从 example.env 创建 .env）
./clean.sh

# 3. 构建 RAILGUN 镜像（首次部署必需）
./init.sh

# 4. 完整部署（包含 RAILGUN）
make run
```

**说明**：
- `clean.sh` 会清理所有旧数据（包括 RAILGUN 部署记录和配置）
- `init.sh` 会根据配置构建所需的 Docker 镜像
- `make run` = `clean.sh` + `init.sh` + `0-all.sh`（完整流程）

#### 方法 2: 单独部署 RAILGUN

如果 L2 网络已经在运行，只需部署 RAILGUN：

```bash
cd /Users/oker/workspace/xlayer/xlayer-toolkit/devnet

# 1. 启用 RAILGUN
vim example.env
# 设置 RAILGUN_ENABLE=true

# 2. 同步配置
./clean.sh

# 3. 仅运行 RAILGUN 部署
./7-run-railgun.sh
```

## 📋 配置详解

### 主配置文件 (example.env)

```bash
# ==============================================================================
# RAILGUN Privacy System Configuration
# ==============================================================================

# 启用/禁用 RAILGUN
RAILGUN_ENABLE=false              # 改为 true 启用

# RAILGUN 源码路径（必填）
RAILGUN_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/pt

# Docker 镜像配置
RAILGUN_CONTRACT_IMAGE_TAG=railgun-contract:latest
RAILGUN_POI_IMAGE_TAG=railgun-poi-node:latest
RAILGUN_BROADCASTER_IMAGE_TAG=railgun-broadcaster:latest

# 构建选项（首次部署设为 false）
SKIP_RAILGUN_CONTRACT_BUILD=true  # false = 构建镜像
SKIP_RAILGUN_POI_BUILD=true       # false = 构建镜像
SKIP_RAILGUN_BROADCASTER_BUILD=true

# 合约地址（部署后自动填充）
RAILGUN_SMART_WALLET_ADDRESS=
RAILGUN_RELAY_ADAPT_ADDRESS=
```

### 子配置文件

配置文件位于 `railgun/` 目录：

1. **`.env.contract`** - 合约部署配置
2. **`.env.poi`** - POI 节点配置
3. **`.env.broadcaster`** - Broadcaster 配置

这些文件会从 `example.env.*` 自动生成，并由脚本自动更新。

### 💡 配置简化说明

**最小化配置** - 对于快速测试，只需配置以下 2 项：

```bash
RAILGUN_ENABLE=true
RAILGUN_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/pt
```

**所有默认值已硬编码**：
- ✅ **端口** - POI: 8080, Broadcaster: 3000, Waku: 60001/60002
- ✅ **密码** - MongoDB: railgun-poi-pass（开发环境默认）
- ✅ **代币** - 默认支持 native token (OKB/ETH)

**无需额外配置**：
- ❌ 不需要配置端口（已硬编码）
- ❌ 不需要配置密码（已硬编码）
- ❌ 不需要配置测试代币（支持 native token）

**如需自定义端口或密码**：
直接修改 `docker-compose.yml` 中的硬编码值即可。

## 🔍 验证部署

### 1. 检查服务状态

```bash
# 查看所有 RAILGUN 服务
docker compose ps | grep railgun

# 应该看到:
# railgun-poi-mongodb    Up (healthy)
# railgun-poi-node       Up (healthy)
# railgun-broadcaster    Up
```

### 2. 验证合约部署

```bash
# 查看部署的合约地址
cat railgun/deployments/*.json | jq '.address'

# 或查看环境变量
source .env
echo "RailgunSmartWallet: $RAILGUN_SMART_WALLET_ADDRESS"
echo "RelayAdapt: $RAILGUN_RELAY_ADAPT_ADDRESS"
```

### 3. 测试 POI 节点

```bash
# 健康检查
curl http://localhost:8080/health

# 应该返回:
# {"status":"healthy","network":"XLayer DevNet","chainId":195}

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

### 4. 查看日志

```bash
# POI 节点日志
docker compose logs -f railgun-poi-node

# Broadcaster 日志
docker compose logs -f railgun-broadcaster

# 查看所有 RAILGUN 日志
docker compose logs -f railgun-poi-mongodb railgun-poi-node railgun-broadcaster
```

## 🛠️ 常用操作

### 重新部署合约

```bash
# 1. 停止服务
docker compose stop railgun-poi-node railgun-broadcaster

# 2. 清理部署记录
rm -rf railgun/deployments/*

# 3. 清空合约地址
vim .env
# 设置 RAILGUN_SMART_WALLET_ADDRESS=

# 4. 重新部署
./7-run-railgun.sh
```

### 重启服务

```bash
# 重启所有 RAILGUN 服务
docker compose restart railgun-poi-mongodb railgun-poi-node railgun-broadcaster

# 仅重启 POI 节点
docker compose restart railgun-poi-node
```

### 停止服务

```bash
# 停止所有 RAILGUN 服务
docker compose stop railgun-poi-mongodb railgun-poi-node railgun-broadcaster

# 或使用 down（会删除容器）
docker compose down railgun-poi-mongodb railgun-poi-node railgun-broadcaster
```

### 查看数据库

```bash
# 连接到 MongoDB
docker exec -it railgun-poi-mongodb mongosh \
  -u railgun \
  -p railgun-poi-pass \
  --authenticationDatabase admin

# 在 mongosh 中:
use poi-xlayer-devnet
show collections
db.events.find().limit(5)
```

## 🐛 故障排查

### 问题 1: 脚本跳过 RAILGUN 部署

**症状**: 运行 `./7-run-railgun.sh` 显示 "Skipping RAILGUN"

**原因**: `RAILGUN_ENABLE` 未设置为 `true`

**解决**:
```bash
# 编辑 example.env
vim example.env
# 设置 RAILGUN_ENABLE=true

# 同步配置
./clean.sh

# 重新运行
./7-run-railgun.sh
```

### 问题 2: 找不到 RAILGUN 源码目录

**症状**: 错误信息 "RAILGUN_LOCAL_DIRECTORY not set"

**原因**: 未配置 RAILGUN 源码路径

**解决**:
```bash
# 编辑 example.env
vim example.env
# 设置 RAILGUN_LOCAL_DIRECTORY=/Users/oker/workspace/xlayer/pt

# 同步配置
./clean.sh
```

### 问题 3: POI 节点无法连接 L2

**症状**: POI 节点日志显示 RPC 连接错误

**原因**: L2 网络未运行或 RPC URL 配置错误

**解决**:
```bash
# 1. 确认 L2 服务运行
docker compose ps | grep "op-.*-seq"

# 2. 测试 RPC 连接
curl -X POST http://localhost:8123 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 3. 检查 POI 节点配置
cat railgun/.env.poi | grep RPC_URL
```

### 问题 4: 合约部署失败

**症状**: 合约部署返回 Gas 错误或余额不足

**原因**: 部署者账户余额不足或 Gas 配置不当

**解决**:
```bash
# 1. 检查部署者账户余额
cast balance $DEPLOYER_ADDRESS --rpc-url http://localhost:8123

# 2. 如果余额不足，从测试账户转账
cast send $DEPLOYER_ADDRESS \
  --value 10ether \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8123

# 3. 调整 Gas 配置
vim railgun/.env.contract
# 增加 GAS_LIMIT 或 GAS_PRICE
```

### 问题 5: MongoDB 无法启动

**症状**: POI 节点依赖的 MongoDB 一直重启

**原因**: 数据目录权限问题或端口冲突

**解决**:
```bash
# 1. 检查端口占用
lsof -i :27017

# 2. 清理数据目录
docker compose down railgun-poi-mongodb
rm -rf data/railgun-mongodb/*

# 3. 重新启动
docker compose up -d railgun-poi-mongodb

# 4. 查看日志
docker compose logs railgun-poi-mongodb
```

## 📊 监控和日志

### 实时日志

```bash
# 所有 RAILGUN 服务日志
docker compose logs -f --tail=100 \
  railgun-poi-mongodb \
  railgun-poi-node \
  railgun-broadcaster

# 仅 POI 节点
docker compose logs -f --tail=100 railgun-poi-node

# 仅 Broadcaster
docker compose logs -f --tail=100 railgun-broadcaster
```

### 服务健康检查

```bash
# POI 节点健康
curl -s http://localhost:8080/health | jq

# 容器健康状态
docker compose ps | grep railgun
```

### 资源使用

```bash
# 查看容器资源使用
docker stats --no-stream \
  railgun-poi-mongodb \
  railgun-poi-node \
  railgun-broadcaster
```

## 📚 相关文档

- **RAILGUN 完整部署指南**: `/Users/oker/workspace/xlayer/pt/DevNet部署指南-ChainID195.md`
- **系统架构文档**: `/Users/oker/workspace/xlayer/pt/完整系统架构与密钥体系.md`
- **电路模块详解**: `/Users/oker/workspace/xlayer/pt/电路模块详解.md`
- **配置目录 README**: `railgun/README.md`

## 🤝 集成测试

完整的端到端测试流程，请参考 RAILGUN 部署指南中的测试章节。

## 🔧 脚本说明

### init.sh - 镜像构建脚本

**作用**: 构建所有必需的 Docker 镜像（构建阶段 - 一次性）

**RAILGUN 镜像构建逻辑**:
```bash
# 1. RAILGUN 合约部署镜像
if [ "$SKIP_RAILGUN_CONTRACT_BUILD" != "true" ]; then
  build_and_tag_image "railgun-contract" "$RAILGUN_CONTRACT_IMAGE_TAG" \
    "$RAILGUN_LOCAL_DIRECTORY/contract" "Dockerfile"
fi

# 2. POI 节点镜像
if [ "$SKIP_RAILGUN_POI_BUILD" != "true" ]; then
  build_and_tag_image "railgun-poi-node" "$RAILGUN_POI_IMAGE_TAG" \
    "$RAILGUN_LOCAL_DIRECTORY" "Dockerfile.poi-node"
fi

# 3. Broadcaster 镜像
if [ "$SKIP_RAILGUN_BROADCASTER_BUILD" != "true" ]; then
  cd "$RAILGUN_LOCAL_DIRECTORY/ppoi-safe-broadcaster-example/docker"
  ./build.sh --no-swag
fi
```

**职责**:
- ✅ 仅负责构建镜像
- ✅ 不负责部署和启动服务
- ✅ 遵循单一职责原则

**何时运行**:
- ✅ 首次部署
- ✅ 更新 RAILGUN 源码后
- ✅ 切换 RAILGUN 版本后

### 7-run-railgun.sh - RAILGUN 部署脚本

**作用**: 部署 RAILGUN 系统（部署阶段 - 可多次运行）

**核心逻辑**:
```bash
# Step 1: 准备配置文件
# - 从 example.env.* 生成实际配置
# - 自动更新 RPC URL、Chain ID 等

# Step 2: 部署智能合约
# - 使用已构建的 railgun-contract 镜像
# - 提取合约地址并保存到 .env

# Step 3: 启动服务
# - 启动 MongoDB
# - 启动 POI 节点（使用已构建的镜像）
# - 启动 Broadcaster（使用已构建的镜像）
```

**职责**:
- ✅ 准备配置文件
- ✅ 部署智能合约
- ✅ 启动服务
- ❌ **不负责构建镜像**（假设已由 init.sh 构建）

**何时运行**:
- ✅ 首次部署时
- ✅ 重新部署时
- ✅ 配置更新后

**注意**: 如果镜像不存在，会提示先运行 `./init.sh`

### clean.sh - 环境清理脚本

**作用**: 清理所有生成的数据和配置

**RAILGUN 清理内容**:
```bash
# 1. 停止所有服务（包括 RAILGUN）
docker compose down

# 2. 清理数据目录
rm -rf data/                    # 包含 railgun-mongodb, railgun-poi 等

# 3. 清理 RAILGUN 部署记录
rm -rf railgun/deployments/*    # 合约部署结果
rm -rf railgun/config/*         # 运行时配置

# 4. 同步配置文件
cp example.env .env             # 从模板创建新的 .env
```

**何时运行**:
- ✅ 重新部署前
- ✅ 切换配置后
- ✅ 遇到环境问题时

**注意**: `clean.sh` 会删除所有数据，包括合约部署记录！

## 💡 最佳实践

1. **首次部署**: 设置 `SKIP_*_BUILD=false` 构建镜像
2. **后续部署**: 设置 `SKIP_*_BUILD=true` 使用已有镜像
3. **生产环境**: 修改默认密码和私钥
4. **监控**: 定期检查服务健康状态和日志
5. **备份**: 定期备份 MongoDB 数据和合约部署记录
6. **镜像管理**: 使用 `docker images | grep railgun` 查看镜像
7. **清理镜像**: 使用 `docker rmi railgun-*` 删除旧镜像

## 🆘 获取帮助

如遇到问题：
1. 查看本文档的故障排查章节
2. 检查服务日志: `docker compose logs`
3. 查看脚本输出: `./7-run-railgun.sh`
4. 参考 RAILGUN 官方文档

