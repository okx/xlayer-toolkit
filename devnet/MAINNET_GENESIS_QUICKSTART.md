# Mainnet Genesis 快速开始

## 🚀 5 分钟快速部署

### 1. 配置（30 秒）

```bash
cd devnet
cp example.env .env
vim .env
```

修改以下配置：

```bash
# 启用主网 genesis
USE_MAINNET_GENESIS=true

# 必须启用 MIN_RUN
MIN_RUN=true

# 注入测试账户（推荐）
INJECT_L2_TEST_ACCOUNT=true
TEST_ACCOUNT_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TEST_ACCOUNT_BALANCE=0x52B7D2DCC80CD2E4000000  # 100K ETH

# Fork 配置（使用你的主网快照点）
FORK_BLOCK=8593920
PARENT_HASH=0x6912fea590fd46ca6a63ec02c6733f6ffb942b84cdf86f7894c21e1757a1f68a
```

### 2. 部署（15-20 分钟）

```bash
# 确保 genesis 文件存在
ls -lh mainnet.genesis.json  # 或 ../rpc-setup/genesis-mainnet.tar.gz

# 一键部署
./0-all.sh
```

### 3. 验证（1 分钟）

```bash
# 运行验证
./scripts/verify-mainnet-setup.sh

# 检查 L2 状态
cast block-number -r http://localhost:8123
# 应该输出: 8593921

# 检查测试账户
cast balance 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 -r http://localhost:8123
# 应该输出: 100000000000000000000000 (100K ETH)
```

### 4. 测试交易（可选）

```bash
# 使用测试账户发送交易
cast send \
    --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
    --value 1ether \
    <目标地址> \
    -r http://localhost:8123
```

## ⚠️ 重要提示

1. **必须 MIN_RUN=true** - 主网 genesis 太大，无法构建 prestate
2. **需要 50GB+ 磁盘空间** - genesis + 数据库
3. **推荐 SSD** - 初始化速度快 3-5 倍
4. **需要 16GB+ 内存** - Docker 配置

## 📖 完整文档

详细说明请查看：`MAINNET_GENESIS_GUIDE.md`

## 🆘 故障排查

### 错误 1: "Mainnet genesis requires MIN_RUN=true"
```bash
# 解决：在 .env 中设置
MIN_RUN=true
```

### 错误 2: Genesis 文件未找到
```bash
# 解决：确保文件存在
ls mainnet.genesis.json
# 或
ls ../rpc-setup/genesis-mainnet.tar.gz
```

### 错误 3: 磁盘空间不足
```bash
# 检查空间
df -h
# 需要至少 50GB
```

## 🎉 完成！

现在你可以：
- ✅ 与主网合约交互
- ✅ 测试主网账户状态
- ✅ 验证迁移逻辑
- ✅ 进行功能测试

**注意：** 此模式不支持争议游戏和欺诈证明（需要完整模式）
