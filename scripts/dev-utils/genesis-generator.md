# Minimal Genesis Generator

Generate minimal XLayer genesis.json files by removing the `alloc` field from full genesis.

## Why?

**Problem**: Reth loads genesis on every startup, taking **~1 minute** because full genesis files are **huge** (over 1 GB):

**Solution**: This tool generates **minimal genesis** files (~1 KB) that can be embedded directly into Reth source code, reducing startup time from **1 minute to <1 second**.

### Use Cases
- **Embedded genesis**: Hardcode minimal genesis in Reth to eliminate loading time
- **Development**: Fast node initialization for testing
- **CI/CD**: Quick environment setup
- **Genesis constants extraction**: Generate Reth chain spec constants

## 使用方法

```bash
./gen-minimal-genesis.sh <network>
```

### 参数

| 参数 | 说明 | 可选值 |
|----------|-------------|---------|
| `network` | 目标网络 | `mainnet` 或 `testnet` |

### 示例

```bash
# 生成 mainnet 最小化 genesis
./gen-minimal-genesis.sh mainnet

# 生成 testnet 最小化 genesis
./gen-minimal-genesis.sh testnet
```

## 工作原理

1. **下载** 从 OSS 下载完整 genesis（本地缓存）
2. **解压** 提取 `merged.genesis.json`
3. **更新** 将 genesis 的 `number` 字段设置为 `config.legacyXLayerBlock` 的值
4. **移除** `alloc` 字段（体积减少 ~99%）
5. **验证** 确保其他所有字段保持不变
6. **输出** 最小化 genesis

## 输出文件

生成的文件放置在 `genesis/` 目录：

```
scripts/dev-utils/genesis/
├── xlayer_mainnet.json    # Mainnet 最小化 genesis
└── xlayer_testnet.json    # Testnet 最小化 genesis
```

## 功能特性

### 缓存机制
下载的压缩包和解压后的 JSON 会缓存在 `.genesis_cache/`：
```
.genesis_cache/
├── mainnet.tar.gz         # 缓存的 mainnet 压缩包
├── mainnet.genesis.json   # 缓存的完整 genesis
├── testnet.tar.gz         # 缓存的 testnet 压缩包
└── testnet.genesis.json   # 缓存的完整 genesis
```

清除缓存：`rm -rf .genesis_cache`

### 验证机制
脚本会验证最小化 genesis 与原始文件的一致性（不包括 `alloc`）：
- 所有 config 字段保持不变
- Block number 正确更新
- Genesis hash 组成部分未改变

### 体积缩减

| 网络 | 完整 Genesis | 最小化 Genesis | 缩减比例 |
|---------|--------------|-----------------|-----------|
| Mainnet | ~400 MB | ~1 KB | 99.9% |
| Testnet | ~200 MB | ~1 KB | 99.9% |

## 后续步骤

生成最小化 genesis 后，提取 genesis 常量用于 Reth：

```bash
# 1. 生成最小化 genesis
./gen-minimal-genesis.sh mainnet

# 2. 使用缓存的**完整** genesis 提取常量
op-reth --chain .genesis_cache/mainnet.genesis.json node --help 2>&1 | grep -A 10 'GENESIS CONSTANTS'

# 3. 将常量复制到 Reth 源码
# src/xlayer_mainnet.rs
```

## 源文件 URL

Genesis 文件从 OKG CDN 下载：

- **Mainnet**: `https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz`
- **Testnet**: `https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz`

## 错误处理

脚本会处理以下情况：
- 网络连接问题
- 无效的压缩包
- 缺失的 JSON 文件
- 验证失败
- 磁盘空间不足

所有错误都会清晰报告并提供故障排除提示。

## 系统要求

- `bash` 4.0+
- `jq` (JSON 处理工具)
- `wget` 或 `curl`
- `tar`
- 足够的磁盘空间（缓存需要约 500 MB）

