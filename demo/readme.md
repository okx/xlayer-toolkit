# demo DEX - MVP 实现方案

## 项目概述

demo 是一个类似 Cosmos 架构的去中心化交易所 (DEX)，使用 Cannon 作为 Dispute Fault Proof 机制，实现 L2 到 L1 的安全性继承。

## 核心特性

- **无 EVM**: 原生 Rust/Go 实现，不依赖 EVM
- **混合状态承诺**: 区块级增量哈希 + Batch 级 MPT Root
- **Cannon Fault Proof**: 使用 Optimism 的 Cannon 进行交互式二分挑战
- **Anvil L1**: 开发环境使用 Anvil 模拟 L1

---

## 组件总览

### 服务 (4 个)

| 服务 | 语言 | 职责 | 运行环境 |
|------|------|------|----------|
| **Sequencer** | Go | 收集交易、执行交易、生产区块、计算增量 StateHash | L2 |
| **Batcher** | Go | 收集多个区块的交易数据、压缩、提交到 L1 BatchInbox | L2 → L1 |
| **Proposer** | Go | **计算 MPT Root**、提交状态承诺 (StateHash + MPT Root) 到 L1 | L2 → L1 |
| **Challenger** | Go | 监控争议游戏、攻击错误声明、防御正确声明 | L2 ↔ L1 |

> **说明**:
> - 参考 Optimism 的设计，**Batcher 只提交交易数据，不计算状态**
> - **MPT Root 由 Proposer 计算**，因为 MPT 是状态承诺的一部分
> - Challenger 既负责攻击也负责防御

### 合约 (3 个)

| 合约 | 职责 | 提交者 | 部署位置 |
|------|------|--------|----------|
| **DEMOBatchInbox.sol** | 接收交易数据 (Batch) | Batcher | L1 |
| **DEMOOutputOracle.sol** | 存储状态哈希和 MPT Root，管理挑战期 | Proposer | L1 |
| **DEMODisputeGame.sol** | Cannon 二分挑战游戏逻辑 | Challenger | L1 |

### 程序 (2 个)

| 程序 | 语言 | 职责 | 运行环境 |
|------|------|------|----------|
| **node** | Go | L2 节点，执行交易、生产区块 | **原生运行** (服务器/云) |
| **program** | Go → MIPS | 验证状态转换，用于 Fault Proof | **Cannon VM** (链上仲裁) |

### 共享库 (1 个)

| 库 | 语言 | 职责 |
|------|------|------|
| **core** | Go | 核心逻辑（状态、交易执行、MPT），被 node 和 program 共享 |

---

## node 与 program 的关系

### 核心概念

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    node vs program                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  node (生产环境)                  program (争议验证)                  │
│  ┌─────────────────────────┐        ┌─────────────────────────┐            │
│  │ 作用: 运行 L2 区块链     │        │ 作用: 验证状态转换       │            │
│  │ 运行: 原生 (Linux/Mac)   │        │ 运行: Cannon MIPS VM    │            │
│  │ 场景: 7x24 持续运行      │        │ 场景: 仅在争议时运行     │            │
│  │ 性能: 需要高性能         │        │ 性能: 可以很慢           │            │
│  └─────────────────────────┘        └─────────────────────────┘            │
│              │                                   │                          │
│              │         共享核心逻辑              │                          │
│              └───────────────┬───────────────────┘                          │
│                              ▼                                              │
│                    ┌─────────────────────┐                                  │
│                    │      core        │                                  │
│                    │  - 状态结构定义     │                                  │
│                    │  - 交易执行逻辑     │                                  │
│                    │  - MPT 实现         │                                  │
│                    │  - DEX 业务逻辑     │                                  │
│                    └─────────────────────┘                                  │
│                                                                             │
│  ⚠️ 关键: node 和 program 必须使用完全相同的状态转换逻辑！            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 为什么需要两个程序？

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       为什么需要两个程序？                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 如何证明 L2 的状态转换是正确的？                                      │
│                                                                             │
│  方案: 两阶段验证                                                           │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │ 阶段 1: 乐观执行 (node)                                         │    │
│  │                                                                    │    │
│  │   - node 在服务器上高速运行                                     │    │
│  │   - 执行交易，生产区块                                             │    │
│  │   - 提交状态哈希到 L1                                              │    │
│  │   - 假设状态是正确的 (乐观假设)                                    │    │
│  │                                                                    │    │
│  │   特点: 快速、高吞吐量、原生性能                                   │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                              │                                              │
│                              │ 如果有人质疑...                              │
│                              ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────┐    │
│  │ 阶段 2: 争议验证 (program + Cannon)                             │    │
│  │                                                                    │    │
│  │   - program 编译为 MIPS 字节码                                  │    │
│  │   - 在 Cannon VM 中逐指令执行                                      │    │
│  │   - 通过二分定位到争议的单条指令                                   │    │
│  │   - 链上 (MIPS.sol) 执行该指令，确定对错                           │    │
│  │                                                                    │    │
│  │   特点: 慢但可验证、确定性、链上可仲裁                             │    │
│  └────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 两者的详细对比

| 维度 | node | program |
|------|---------|------------|
| **目的** | 运行 L2 区块链 | 验证状态转换 (Fault Proof) |
| **运行时** | 原生 (Linux/Mac/Windows) | Cannon MIPS VM |
| **编译目标** | 原生二进制 | MIPS 字节码 |
| **运行时机** | 7x24 持续运行 | 仅在争议时运行 |
| **性能要求** | 高性能 (毫秒级) | 无要求 (可以很慢) |
| **并发** | 可以多线程 | 必须单线程 (确定性) |
| **I/O** | 直接访问磁盘/网络 | 通过 Preimage Oracle |
| **包含服务** | Sequencer, Batcher, Proposer, Challenger | 无 (纯验证逻辑) |

### 代码共享策略

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         代码共享策略                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  目录结构:                                                                  │
│                                                                             │
│  demo/                                                                        │
│  ├── core/              ← 共享库 (核心逻辑)                              │
│  │   ├── state/            # 状态结构和管理                                 │
│  │   ├── tx/               # 交易定义和执行                                 │
│  │   ├── mpt/              # Merkle Patricia Trie                          │
│  │   ├── dex/              # DEX 业务逻辑 (Swap, AddLiquidity 等)          │
│  │   └── types/            # 公共类型定义                                   │
│  │                                                                          │
│  ├── node/              ← L2 节点 (使用 core)                         │
│  │   ├── cmd/              # 服务入口 (sequencer, batcher 等)              │
│  │   ├── p2p/              # 网络层 (program 不需要)                     │
│  │   ├── rpc/              # RPC 接口 (program 不需要)                   │
│  │   └── db/               # 数据库 (program 不需要)                     │
│  │                                                                          │
│  └── program/           ← Cannon 程序 (使用 core)                     │
│      ├── main.go           # 入口，读取输入，输出结果                       │
│      ├── preimage/         # Preimage Oracle 接口                          │
│      └── verify/           # 验证逻辑封装                                   │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  关键原则:                                                                  │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ 1. core 包含所有状态转换逻辑                               │         │
│  │ 2. node 和 program 都依赖 core                       │         │
│  │ 3. 任何业务逻辑修改都在 core 中进行                        │         │
│  │ 4. node 和 program 的差异仅在 I/O 和服务层              │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 执行流程对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         执行流程对比                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  node 执行流程 (正常运行):                                               │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │                                                               │         │
│  │   1. 从 mempool 获取交易                                      │         │
│  │   2. 从数据库加载当前状态                                     │         │
│  │   3. 调用 core 执行交易                                    │         │
│  │   4. 计算 StateHash                                           │         │
│  │   5. 保存状态到数据库                                         │         │
│  │   6. 广播区块到 P2P 网络                                      │         │
│  │                                                               │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  program 执行流程 (争议验证):                                            │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │                                                               │         │
│  │   1. 通过 Preimage Oracle 获取区块数据                        │         │
│  │   2. 通过 Preimage Oracle 获取前置状态 + Merkle Proof         │         │
│  │   3. 验证状态数据的 Merkle Proof                              │         │
│  │   4. 调用 core 执行交易 (与 node 完全相同!)            │         │
│  │   5. 计算 StateHash                                           │         │
│  │   6. 输出结果供链上验证                                       │         │
│  │                                                               │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  共同点: 步骤 3-5 使用完全相同的 core 代码                               │
│  差异点: I/O 方式不同 (数据库 vs Preimage Oracle)                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 类比理解

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            类比理解                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  想象一个银行系统:                                                          │
│                                                                             │
│  node = 银行的日常运营系统                                               │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ - 处理存款、取款、转账                                        │         │
│  │ - 高速运行，每秒处理大量交易                                  │         │
│  │ - 记录账本                                                    │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  program = 审计程序                                                      │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ - 验证账本是否正确                                            │         │
│  │ - 只在有人质疑时运行                                          │         │
│  │ - 逐笔核对每一笔交易                                          │         │
│  │ - 可以很慢，但必须准确                                        │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  core = 会计准则                                                         │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ - 定义如何计算余额                                            │         │
│  │ - 定义转账规则                                                │         │
│  │ - 银行系统和审计程序都必须遵守相同的准则                      │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 脚本/工具 (3 个)

| 脚本 | 职责 |
|------|------|
| **run-anvil.sh** | 启动 Anvil (本地 L1 模拟) |
| **deploy.sh** | 部署 L1 合约 |
| **test-dispute.sh** | 测试争议流程 |

### 组件关系图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            组件关系图                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        node (Go)                                  │   │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐            │   │
│  │  │ Sequencer │ │  Batcher  │ │ Proposer  │ │Challenger │            │   │
│  │  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬─────┘            │   │
│  │        │             │             │             │                   │   │
│  │        └──────┬──────┴──────┬──────┴──────┬──────┘                   │   │
│  │               │             │             │                          │   │
│  │               ▼             ▼             ▼                          │   │
│  │        ┌─────────────────────────────────────────┐                   │   │
│  │        │              core (共享库)            │                   │   │
│  │        │  - state/    状态管理                    │                   │   │
│  │        │  - mpt/      Merkle Patricia Trie       │                   │   │
│  │        │  - tx/       交易执行                    │                   │   │
│  │        │  - dex/      DEX 业务逻辑                │                   │   │
│  │        └─────────────────────────────────────────┘                   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    │  共享                                  │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      program (Go → MIPS)                          │   │
│  │  - 编译为 MIPS 字节码                                                 │   │
│  │  - 运行在 Cannon VM 中                                                │   │
│  │  - 验证状态转换正确性                                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│  ══════════════════════════════════╪════════════════════════════════════   │
│                                    │  L1 / L2 边界                          │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         L1 合约 (Solidity)                           │   │
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐        │   │
│  │  │ DEMOBatchInbox    │ │ DEMOOutputOracle  │ │ DEMODisputeGame   │        │   │
│  │  │ - 交易数据      │ │ - StateHash     │ │ - 二分挑战      │        │   │
│  │  │ ← Batcher       │ │ - MPT Root      │ │ - 单步验证      │        │   │
│  │  │                 │ │ ← Proposer      │ │                 │        │   │
│  │  └─────────────────┘ └─────────────────┘ └─────────────────┘        │   │
│  │                                                  │                   │   │
│  │                                                  ▼                   │   │
│  │                                         ┌─────────────────┐          │   │
│  │                                         │    MIPS.sol     │          │   │
│  │                                         │  (Cannon 依赖)  │          │   │
│  │                                         └─────────────────┘          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 数据流向

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            数据流向                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  正常流程:                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                                                                      │  │
│  │  用户交易 ──▶ Sequencer ──▶ 区块                                    │  │
│  │                              │                                       │  │
│  │              ┌───────────────┴───────────────┐                       │  │
│  │              ▼                               ▼                       │  │
│  │         Batcher                          Proposer                    │  │
│  │         (交易数据)                       (计算 MPT Root)             │  │
│  │              │                               │                       │  │
│  │              ▼                               ▼                       │  │
│  │      DEMOBatchInbox (L1)              DEMOOutputOracle (L1)             │  │
│  │      [txData]                       [StateHash + MPT Root]          │  │
│  │                                                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  挑战流程:                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                                                                      │  │
│  │  Challenger 发现错误的 Output                                       │  │
│  │       │                                                              │  │
│  │       ▼                                                              │  │
│  │  DEMODisputeGame.challenge()                                          │  │
│  │       │                                                              │  │
│  │       ▼                                                              │  │
│  │  二分游戏 (多个 Challenger 参与 attack/defend)                      │  │
│  │       │                                                              │  │
│  │       ▼                                                              │  │
│  │  定位到单条 MIPS 指令                                                │  │
│  │       │                                                              │  │
│  │       ▼                                                              │  │
│  │  MIPS.sol 链上执行验证                                               │  │
│  │       │                                                              │  │
│  │       ▼                                                              │  │
│  │  确定胜负，分配保证金                                                │  │
│  │                                                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 架构设计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              demo 架构                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                         L2: demo DEX                               │        │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │        │
│  │  │   Sequencer     │  │   Batcher       │  │  Proposer       │  │        │
│  │  │  (区块生产)     │  │  (批量提交)     │  │  (状态提交)     │  │        │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘  │        │
│  │         │                    │                    │              │        │
│  │         ▼                    │                    │              │        │
│  │  ┌─────────────────┐        │                    │              │        │
│  │  │  demo State       │        │                    │              │        │
│  │  │  Machine        │        │                    │              │        │
│  │  │  ┌───────────┐  │        │                    │              │        │
│  │  │  │ Block     │  │        │                    │              │        │
│  │  │  │ StateHash │──┼────────┼────────────────────┘              │        │
│  │  │  └───────────┘  │        │                                   │        │
│  │  └─────────────────┘        │                                   │        │
│  │                             ▼                                   │        │
│  │                    ┌─────────────────┐                          │        │
│  │                    │  Batch MPT      │                          │        │
│  │                    │  Calculator     │                          │        │
│  │                    │  (批次时计算)   │                          │        │
│  │                    └─────────────────┘                          │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                   │                                         │
│                                   ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                      L1: Anvil (开发环境)                         │        │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │        │
│  │  │  BatchInbox     │  │  OutputOracle   │  │  DisputeGame    │  │        │
│  │  │  (交易数据)     │  │  (StateHash +   │  │  (Cannon 挑战)  │  │        │
│  │  │  ← Batcher      │  │   MPT Root)     │  │                 │  │        │
│  │  │                 │  │  ← Proposer     │  │                 │  │        │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘  │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 状态承诺机制

### 混合状态承诺方案

demo 采用 **区块级增量哈希 + Batch 级 MPT Root** 的混合方案：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         混合状态承诺方案                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  区块级别: 增量状态哈希 (快速)                                               │
│  ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐                       │
│  │ B1  │───▶│ B2  │───▶│ B3  │───▶│ B4  │───▶│ B5  │  ...                  │
│  │ H1  │    │ H2  │    │ H3  │    │ H4  │    │ H5  │                       │
│  └─────┘    └─────┘    └─────┘    └─────┘    └─────┘                       │
│     │          │          │          │          │                          │
│     │          │          │          │          │                          │
│     │    Hi = SHA256(H_{i-1} || changes_i)     │                          │
│     │                                           │                          │
│  ───┴───────────────┬───────────────────────────┴──────────────────────    │
│                     │                                                      │
│  Batch 级别: MPT Root (可证明)                                              │
│  ┌─────────────────────────────────────────────┐                           │
│  │              Batch 1 (B1-B5)                │                           │
│  │                                             │                           │
│  │   计算该批次结束时的完整状态 MPT Root:       │                           │
│  │   - 收集 B1-B5 的所有状态变更               │                           │
│  │   - 应用到状态                              │                           │
│  │   - 构建 Merkle Patricia Trie              │                           │
│  │   - 计算 MPT Root                           │                           │
│  │                                             │                           │
│  │   提交到 L1:                                │                           │
│  │   - Batch 交易数据                          │                           │
│  │   - 最终 StateHash (H5)                    │                           │
│  │   - MPT Root                               │                           │
│  └─────────────────────────────────────────────┘                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 为什么需要 Batch 级 MPT？

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       增量哈希 vs MPT Root                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  增量哈希:                                                                  │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ ✅ 计算快速: 只需哈希变更部分                                  │         │
│  │ ✅ 存储小: 只需保存哈希值                                      │         │
│  │ ❌ 无法证明单个数据: 验证某个账户余额需要重放所有历史           │         │
│  │ ❌ Preimage 验证困难: 无法证明提供的状态数据是正确的            │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  MPT Root:                                                                  │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ ✅ 可验证任意数据: 通过 Merkle Proof 证明任意 key-value        │         │
│  │ ✅ Preimage 可验证: 链上可验证提供的数据属于已提交的状态        │         │
│  │ ❌ 计算慢: 需要更新整棵树                                      │         │
│  │ ❌ 存储大: 需要存储树结构                                      │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  混合方案:                                                                  │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ ✅ 区块生产快: 只计算增量哈希                                  │         │
│  │ ✅ 状态可证明: Batch 提交时计算 MPT Root                       │         │
│  │ ✅ L1 验证: 挑战时可用 Merkle Proof 验证任意状态数据           │         │
│  │ ✅ 成本分摊: MPT 计算成本分摊到多个区块                        │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### MPT 在 Cannon 挑战中的作用

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    MPT Root 在 Cannon 挑战中的作用                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景: 挑战区块 B5 的状态转换                                                │
│                                                                             │
│  1. program 需要验证输入状态的正确性:                                     │
│     ┌───────────────────────────────────────────────────────────────┐      │
│     │  Input:                                                        │      │
│     │  - PreStateHash (B4 的状态哈希)                                │      │
│     │  - PreState (B4 结束时的完整状态数据)                          │      │
│     │  - 上一个 Batch 的 MPT Root (已提交到 L1)                      │      │
│     │                                                                │      │
│     │  验证流程:                                                      │      │
│     │  1. 对于需要读取的每个状态数据 (账户余额、订单等):             │      │
│     │     - 提供该数据的 Merkle Proof                                │      │
│     │     - 验证 Proof 与 MPT Root 一致                              │      │
│     │  2. 使用验证过的数据执行交易                                    │      │
│     │  3. 计算 PostStateHash                                         │      │
│     └───────────────────────────────────────────────────────────────┘      │
│                                                                             │
│  2. Preimage Oracle 提供数据时附带 Merkle Proof:                            │
│     ┌───────────────────────────────────────────────────────────────┐      │
│     │  Preimage Request:  account_0x1234_balance                     │      │
│     │  Preimage Response:                                            │      │
│     │  {                                                             │      │
│     │    value: 1000000,                                             │      │
│     │    proof: [node1, node2, node3, ...]                           │      │
│     │  }                                                             │      │
│     │                                                                │      │
│     │  program 验证:                                              │      │
│     │  verify_merkle_proof(MPT_ROOT, key, value, proof) == true     │      │
│     └───────────────────────────────────────────────────────────────┘      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 目录结构

```
demo/
├── readme.md                    # 本文档
│
├── contracts/                   # L1 合约 (Solidity)
│   ├── DEMOBatchInbox.sol         # Batch 数据接收合约 (Batcher 提交)
│   ├── DEMOOutputOracle.sol       # 状态承诺合约 (Proposer 提交)
│   └── DEMODisputeGame.sol        # Cannon 争议游戏合约
│
├── core/                     # 共享库 (核心逻辑) ⚠️ 关键！
│   ├── state/                   # 状态结构和管理
│   ├── tx/                      # 交易定义和执行
│   ├── mpt/                     # Merkle Patricia Trie
│   ├── dex/                     # DEX 业务逻辑 (Swap, AddLiquidity 等)
│   └── types/                   # 公共类型定义
│
├── node/                     # L2 节点 (Go, 原生运行)
│   ├── cmd/
│   │   ├── sequencer/           # Sequencer 入口
│   │   ├── batcher/             # Batcher 入口
│   │   ├── proposer/            # Proposer 入口
│   │   └── challenger/          # Challenger 入口
│   ├── p2p/                     # P2P 网络层
│   ├── rpc/                     # RPC 接口
│   ├── db/                      # 数据库层
│   └── derivation/              # 派生逻辑 (从 L1 派生 L2 区块)
│
├── program/                  # Cannon 程序 (Go → MIPS)
│   ├── main.go                  # 入口
│   ├── preimage/                # Preimage Oracle 接口
│   └── verify/                  # 验证逻辑封装
│
├── scripts/                     # 脚本
│   ├── deploy.sh                # 部署 L1 合约
│   ├── run-anvil.sh             # 启动 Anvil
│   └── test-dispute.sh          # 测试争议流程
│
└── test/                        # 测试
    ├── e2e/                     # 端到端测试
    └── unit/                    # 单元测试
```

> **重要**: `core` 是共享库，`node` 和 `program` 都依赖它，确保状态转换逻辑完全一致。

---

## 核心数据结构

### 区块结构

```go
// node/core/block/block.go

type Block struct {
    Header       BlockHeader
    Transactions []Transaction
}

type BlockHeader struct {
    Number           uint64      // 区块号
    ParentHash       [32]byte    // 父区块哈希
    StateHash        [32]byte    // 执行后的增量状态哈希
    TransactionsRoot [32]byte    // 交易 Merkle 根
    Timestamp        uint64      // 时间戳
    Proposer         Address     // 提议者
}
```

### Batch 结构 (Batcher 使用)

```go
// node/core/batch/batch.go
// Batcher 只负责交易数据，不包含状态

type Batch struct {
    StartBlock    uint64      // 起始区块号
    EndBlock      uint64      // 结束区块号
    Transactions  [][]byte    // 压缩的交易数据
    Timestamp     uint64      // 提交时间
}
```

### Output 结构 (Proposer 使用)

```go
// node/core/output/output.go
// Proposer 负责状态承诺

type Output struct {
    L2BlockNumber  uint64      // L2 区块号
    StateHash      [32]byte    // 增量状态哈希 (来自区块头)
    MPTRoot        [32]byte    // MPT Root (Proposer 计算)
    L1BlockHash    [32]byte    // L1 区块哈希 (用于锚定)
}
```

### 交易结构

```go
// node/core/tx/transaction.go

type Transaction struct {
    Type      TxType
    From      Address
    Payload   []byte      // 根据 Type 解析
    Fee       Fee
    Nonce     uint64
    Signature Signature
}

type TxType uint8

const (
    TxTypeTransfer        TxType = 1  // 转账
    TxTypeSwap            TxType = 2  // AMM 兑换
    TxTypeAddLiquidity    TxType = 3  // 添加流动性
    TxTypeRemoveLiquidity TxType = 4  // 移除流动性
    TxTypeCreatePool      TxType = 5  // 创建交易对
)
```

### 状态结构

```go
// node/core/state/state.go

type State struct {
    Accounts map[Address]*Account   // 用户账户
    Tokens   map[TokenID]*Token     // 代币信息
    Pools    map[PoolID]*Pool       // 流动性池

    // MPT 相关
    mptTree  *MPT           // Merkle Patricia Trie
    dirty    bool           // 是否有未提交的变更
}

// 区块级: 计算增量状态哈希
func (s *State) ComputeIncrementalHash(prevHash [32]byte, changes []StateChange) [32]byte {
    // StateHash = SHA256(prevHash || serialize(changes))
    data := append(prevHash[:], serializeChanges(changes)...)
    return sha256.Sum256(data)
}

// Batch 级: 计算 MPT Root
func (s *State) ComputeMPTRoot() [32]byte {
    // 将所有状态数据插入 MPT
    s.mptTree.Clear()

    for addr, account := range s.Accounts {
        key := accountKey(addr)
        value := serializeAccount(account)
        s.mptTree.Insert(key, value)
    }

    for orderID, order := range s.Orders {
        key := orderKey(orderID)
        value := serializeOrder(order)
        s.mptTree.Insert(key, value)
    }

    for poolID, pool := range s.Pools {
        key := poolKey(poolID)
        value := serializePool(pool)
        s.mptTree.Insert(key, value)
    }

    return s.mptTree.Root()
}

// 生成 Merkle Proof
func (s *State) GenerateProof(key []byte) ([]byte, [][]byte, error) {
    return s.mptTree.Prove(key)
}
```

---

## DEX 功能设计

### 功能概览

demo 实现一个简单的 **AMM (自动做市商) DEX**，类似 Uniswap V2：

| 功能 | 说明 |
|------|------|
| **转账** | 用户之间转移代币 |
| **创建池** | 创建新的交易对 (Token A / Token B) |
| **添加流动性** | 向池中注入代币，获得 LP Token |
| **移除流动性** | 销毁 LP Token，取回代币 |
| **兑换** | 使用 AMM 公式进行代币兑换 |

### 数据结构

#### 代币 (Token)

```go
// node/core/dex/token.go

type TokenID [20]byte  // 代币唯一标识

type Token struct {
    ID          TokenID
    Name        string
    Symbol      string
    Decimals    uint8
    TotalSupply *big.Int
}

// 预置代币
var (
    TokenETH  = TokenID{0x00}  // 原生代币
    TokenUSDC = TokenID{0x01}  // 稳定币
    TokenBTC  = TokenID{0x02}  // 包装 BTC
)
```

#### 账户 (Account)

```go
// node/core/dex/account.go

type Address [20]byte

type Account struct {
    Address  Address
    Nonce    uint64
    Balances map[TokenID]*big.Int  // 各代币余额
}

// 获取余额
func (a *Account) GetBalance(token TokenID) *big.Int {
    if bal, ok := a.Balances[token]; ok {
        return bal
    }
    return big.NewInt(0)
}

// 扣减余额
func (a *Account) SubBalance(token TokenID, amount *big.Int) error {
    bal := a.GetBalance(token)
    if bal.Cmp(amount) < 0 {
        return ErrInsufficientBalance
    }
    a.Balances[token] = new(big.Int).Sub(bal, amount)
    return nil
}

// 增加余额
func (a *Account) AddBalance(token TokenID, amount *big.Int) {
    bal := a.GetBalance(token)
    a.Balances[token] = new(big.Int).Add(bal, amount)
}
```

#### 流动性池 (Pool)

```go
// node/core/dex/pool.go

type PoolID [32]byte  // = Hash(TokenA, TokenB)

type Pool struct {
    ID         PoolID
    TokenA     TokenID
    TokenB     TokenID
    ReserveA   *big.Int    // Token A 储备量
    ReserveB   *big.Int    // Token B 储备量
    TotalLP    *big.Int    // LP Token 总量
    FeeRate    uint64      // 手续费率 (万分比，如 30 = 0.3%)
}

// 创建 Pool ID
func NewPoolID(tokenA, tokenB TokenID) PoolID {
    // 确保顺序一致
    if bytes.Compare(tokenA[:], tokenB[:]) > 0 {
        tokenA, tokenB = tokenB, tokenA
    }
    data := append(tokenA[:], tokenB[:]...)
    return PoolID(sha256.Sum256(data))
}

// 获取 LP Token ID
func (p *Pool) LPTokenID() TokenID {
    // LP Token ID 基于 Pool ID 生成
    hash := sha256.Sum256(p.ID[:])
    var id TokenID
    copy(id[:], hash[:20])
    return id
}
```

### 交易处理

#### 1. 转账 (Transfer)

```go
// node/core/dex/transfer.go

type TransferPayload struct {
    To     Address
    Token  TokenID
    Amount *big.Int
}

func ExecuteTransfer(state *State, from Address, payload TransferPayload) error {
    sender := state.GetAccount(from)
    receiver := state.GetOrCreateAccount(payload.To)

    // 扣减发送方余额
    if err := sender.SubBalance(payload.Token, payload.Amount); err != nil {
        return err
    }

    // 增加接收方余额
    receiver.AddBalance(payload.Token, payload.Amount)

    return nil
}
```

#### 2. 创建池 (CreatePool)

```go
// node/core/dex/create_pool.go

type CreatePoolPayload struct {
    TokenA   TokenID
    TokenB   TokenID
    AmountA  *big.Int
    AmountB  *big.Int
    FeeRate  uint64      // 默认 30 (0.3%)
}

func ExecuteCreatePool(state *State, from Address, payload CreatePoolPayload) error {
    // 检查池是否已存在
    poolID := NewPoolID(payload.TokenA, payload.TokenB)
    if state.Pools[poolID] != nil {
        return ErrPoolExists
    }

    sender := state.GetAccount(from)

    // 扣减代币
    if err := sender.SubBalance(payload.TokenA, payload.AmountA); err != nil {
        return err
    }
    if err := sender.SubBalance(payload.TokenB, payload.AmountB); err != nil {
        return err
    }

    // 计算初始 LP Token 数量 (sqrt(amountA * amountB))
    initialLP := new(big.Int).Sqrt(new(big.Int).Mul(payload.AmountA, payload.AmountB))

    // 创建池
    pool := &Pool{
        ID:       poolID,
        TokenA:   payload.TokenA,
        TokenB:   payload.TokenB,
        ReserveA: payload.AmountA,
        ReserveB: payload.AmountB,
        TotalLP:  initialLP,
        FeeRate:  payload.FeeRate,
    }
    state.Pools[poolID] = pool

    // 给创建者发放 LP Token
    sender.AddBalance(pool.LPTokenID(), initialLP)

    return nil
}
```

#### 3. 添加流动性 (AddLiquidity)

```go
// node/core/dex/add_liquidity.go

type AddLiquidityPayload struct {
    PoolID   PoolID
    AmountA  *big.Int    // 希望添加的 Token A 数量
    AmountB  *big.Int    // 希望添加的 Token B 数量
    MinLP    *big.Int    // 最小获得的 LP 数量 (滑点保护)
}

func ExecuteAddLiquidity(state *State, from Address, payload AddLiquidityPayload) error {
    pool := state.Pools[payload.PoolID]
    if pool == nil {
        return ErrPoolNotFound
    }

    sender := state.GetAccount(from)

    // 计算实际添加比例 (保持池子比例)
    // 如果 AmountA / AmountB != ReserveA / ReserveB，取较小比例
    ratioA := new(big.Int).Mul(payload.AmountA, pool.ReserveB)
    ratioB := new(big.Int).Mul(payload.AmountB, pool.ReserveA)

    var actualA, actualB *big.Int
    if ratioA.Cmp(ratioB) <= 0 {
        // AmountA 决定比例
        actualA = payload.AmountA
        actualB = new(big.Int).Div(
            new(big.Int).Mul(payload.AmountA, pool.ReserveB),
            pool.ReserveA,
        )
    } else {
        // AmountB 决定比例
        actualB = payload.AmountB
        actualA = new(big.Int).Div(
            new(big.Int).Mul(payload.AmountB, pool.ReserveA),
            pool.ReserveB,
        )
    }

    // 计算获得的 LP Token
    // lpAmount = totalLP * actualA / reserveA
    lpAmount := new(big.Int).Div(
        new(big.Int).Mul(pool.TotalLP, actualA),
        pool.ReserveA,
    )

    // 滑点检查
    if lpAmount.Cmp(payload.MinLP) < 0 {
        return ErrSlippageExceeded
    }

    // 扣减代币
    if err := sender.SubBalance(pool.TokenA, actualA); err != nil {
        return err
    }
    if err := sender.SubBalance(pool.TokenB, actualB); err != nil {
        return err
    }

    // 更新池状态
    pool.ReserveA = new(big.Int).Add(pool.ReserveA, actualA)
    pool.ReserveB = new(big.Int).Add(pool.ReserveB, actualB)
    pool.TotalLP = new(big.Int).Add(pool.TotalLP, lpAmount)

    // 发放 LP Token
    sender.AddBalance(pool.LPTokenID(), lpAmount)

    return nil
}
```

#### 4. 移除流动性 (RemoveLiquidity)

```go
// node/core/dex/remove_liquidity.go

type RemoveLiquidityPayload struct {
    PoolID    PoolID
    LPAmount  *big.Int    // 销毁的 LP Token 数量
    MinA      *big.Int    // 最小获得的 Token A (滑点保护)
    MinB      *big.Int    // 最小获得的 Token B (滑点保护)
}

func ExecuteRemoveLiquidity(state *State, from Address, payload RemoveLiquidityPayload) error {
    pool := state.Pools[payload.PoolID]
    if pool == nil {
        return ErrPoolNotFound
    }

    sender := state.GetAccount(from)

    // 计算获得的代币数量
    // amountA = reserveA * lpAmount / totalLP
    amountA := new(big.Int).Div(
        new(big.Int).Mul(pool.ReserveA, payload.LPAmount),
        pool.TotalLP,
    )
    amountB := new(big.Int).Div(
        new(big.Int).Mul(pool.ReserveB, payload.LPAmount),
        pool.TotalLP,
    )

    // 滑点检查
    if amountA.Cmp(payload.MinA) < 0 || amountB.Cmp(payload.MinB) < 0 {
        return ErrSlippageExceeded
    }

    // 销毁 LP Token
    if err := sender.SubBalance(pool.LPTokenID(), payload.LPAmount); err != nil {
        return err
    }

    // 更新池状态
    pool.ReserveA = new(big.Int).Sub(pool.ReserveA, amountA)
    pool.ReserveB = new(big.Int).Sub(pool.ReserveB, amountB)
    pool.TotalLP = new(big.Int).Sub(pool.TotalLP, payload.LPAmount)

    // 返还代币
    sender.AddBalance(pool.TokenA, amountA)
    sender.AddBalance(pool.TokenB, amountB)

    return nil
}
```

#### 5. 兑换 (Swap)

```go
// node/core/dex/swap.go

type SwapPayload struct {
    PoolID      PoolID
    TokenIn     TokenID
    AmountIn    *big.Int
    MinAmountOut *big.Int   // 最小获得数量 (滑点保护)
}

func ExecuteSwap(state *State, from Address, payload SwapPayload) error {
    pool := state.Pools[payload.PoolID]
    if pool == nil {
        return ErrPoolNotFound
    }

    sender := state.GetAccount(from)

    // 确定输入输出代币
    var reserveIn, reserveOut *big.Int
    var tokenOut TokenID

    if payload.TokenIn == pool.TokenA {
        reserveIn = pool.ReserveA
        reserveOut = pool.ReserveB
        tokenOut = pool.TokenB
    } else if payload.TokenIn == pool.TokenB {
        reserveIn = pool.ReserveB
        reserveOut = pool.ReserveA
        tokenOut = pool.TokenA
    } else {
        return ErrInvalidToken
    }

    // 计算输出数量 (AMM 恒定乘积公式)
    // amountOut = reserveOut * amountIn * (10000 - feeRate) / (reserveIn * 10000 + amountIn * (10000 - feeRate))
    amountInWithFee := new(big.Int).Mul(
        payload.AmountIn,
        big.NewInt(int64(10000-pool.FeeRate)),
    )
    numerator := new(big.Int).Mul(reserveOut, amountInWithFee)
    denominator := new(big.Int).Add(
        new(big.Int).Mul(reserveIn, big.NewInt(10000)),
        amountInWithFee,
    )
    amountOut := new(big.Int).Div(numerator, denominator)

    // 滑点检查
    if amountOut.Cmp(payload.MinAmountOut) < 0 {
        return ErrSlippageExceeded
    }

    // 扣减输入代币
    if err := sender.SubBalance(payload.TokenIn, payload.AmountIn); err != nil {
        return err
    }

    // 更新池状态
    if payload.TokenIn == pool.TokenA {
        pool.ReserveA = new(big.Int).Add(pool.ReserveA, payload.AmountIn)
        pool.ReserveB = new(big.Int).Sub(pool.ReserveB, amountOut)
    } else {
        pool.ReserveB = new(big.Int).Add(pool.ReserveB, payload.AmountIn)
        pool.ReserveA = new(big.Int).Sub(pool.ReserveA, amountOut)
    }

    // 发放输出代币
    sender.AddBalance(tokenOut, amountOut)

    return nil
}
```

### AMM 公式说明

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AMM 恒定乘积公式                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  核心公式: x * y = k                                                        │
│                                                                             │
│  其中:                                                                      │
│  - x = Token A 储备量                                                       │
│  - y = Token B 储备量                                                       │
│  - k = 常量 (每次交易后保持不变)                                            │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  Swap 计算 (输入 Δx，计算输出 Δy):                                          │
│                                                                             │
│  1. 交易前: x * y = k                                                       │
│  2. 交易后: (x + Δx) * (y - Δy) = k                                        │
│  3. 推导:   Δy = y * Δx / (x + Δx)                                         │
│                                                                             │
│  考虑手续费 (0.3%):                                                         │
│  Δx_fee = Δx * 0.997                                                       │
│  Δy = y * Δx_fee / (x + Δx_fee)                                            │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  示例:                                                                      │
│  - 池子: 1000 ETH / 2,000,000 USDC                                         │
│  - 输入: 1 ETH                                                              │
│  - 手续费后: 0.997 ETH                                                      │
│  - 输出: 2,000,000 * 0.997 / (1000 + 0.997) ≈ 1,992 USDC                   │
│                                                                             │
│  价格影响 (滑点):                                                           │
│  - 理想价格: 2000 USDC/ETH                                                  │
│  - 实际获得: 1992 USDC                                                      │
│  - 滑点: (2000 - 1992) / 2000 = 0.4%                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 交易执行主入口

```go
// node/core/tx/executor.go

func ExecuteTransaction(state *State, tx *Transaction) error {
    // 验证签名
    if !tx.VerifySignature() {
        return ErrInvalidSignature
    }

    // 验证 Nonce
    account := state.GetAccount(tx.From)
    if account.Nonce != tx.Nonce {
        return ErrInvalidNonce
    }

    // 扣除手续费
    if err := account.SubBalance(TokenETH, tx.Fee.Amount); err != nil {
        return ErrInsufficientFee
    }

    // 执行交易
    var err error
    switch tx.Type {
    case TxTypeTransfer:
        var payload TransferPayload
        if err = decode(tx.Payload, &payload); err != nil {
            return err
        }
        err = ExecuteTransfer(state, tx.From, payload)

    case TxTypeCreatePool:
        var payload CreatePoolPayload
        if err = decode(tx.Payload, &payload); err != nil {
            return err
        }
        err = ExecuteCreatePool(state, tx.From, payload)

    case TxTypeAddLiquidity:
        var payload AddLiquidityPayload
        if err = decode(tx.Payload, &payload); err != nil {
            return err
        }
        err = ExecuteAddLiquidity(state, tx.From, payload)

    case TxTypeRemoveLiquidity:
        var payload RemoveLiquidityPayload
        if err = decode(tx.Payload, &payload); err != nil {
            return err
        }
        err = ExecuteRemoveLiquidity(state, tx.From, payload)

    case TxTypeSwap:
        var payload SwapPayload
        if err = decode(tx.Payload, &payload); err != nil {
            return err
        }
        err = ExecuteSwap(state, tx.From, payload)

    default:
        return ErrUnknownTxType
    }

    if err != nil {
        return err
    }

    // 更新 Nonce
    account.Nonce++

    return nil
}
```

### DEX 状态示意

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DEX 状态示意                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Accounts:                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Address: 0xAlice                                                     │   │
│  │ Nonce: 5                                                             │   │
│  │ Balances:                                                            │   │
│  │   - ETH:  10.5                                                       │   │
│  │   - USDC: 25,000                                                     │   │
│  │   - LP(ETH/USDC): 500                                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Address: 0xBob                                                       │   │
│  │ Nonce: 12                                                            │   │
│  │ Balances:                                                            │   │
│  │   - ETH:  5.2                                                        │   │
│  │   - BTC:  0.5                                                        │   │
│  │   - LP(ETH/BTC): 100                                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Pools:                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Pool: ETH/USDC                                                       │   │
│  │ ReserveA (ETH):  1,000                                               │   │
│  │ ReserveB (USDC): 2,000,000                                           │   │
│  │ TotalLP: 44,721                                                      │   │
│  │ FeeRate: 30 (0.3%)                                                   │   │
│  │ Price: 1 ETH = 2,000 USDC                                            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Pool: ETH/BTC                                                        │   │
│  │ ReserveA (ETH):  100                                                 │   │
│  │ ReserveB (BTC):  5                                                   │   │
│  │ TotalLP: 22.36                                                       │   │
│  │ FeeRate: 30 (0.3%)                                                   │   │
│  │ Price: 1 BTC = 20 ETH                                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 关键流程

### 1. 区块生产流程

```
┌─────────────────────────────────────────────────────────────────┐
│                       区块生产流程                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Sequencer 收集交易                                           │
│     ↓                                                           │
│  2. 执行交易，记录状态变更 (changes)                              │
│     ↓                                                           │
│  3. 计算增量状态哈希 (快速)                                       │
│     StateHash = SHA256(PrevStateHash || changes)                │
│     ↓                                                           │
│  4. 打包成区块                                                    │
│     ↓                                                           │
│  5. 广播区块                                                      │
│                                                                 │
│  ⚠️ 注意: 区块生产时不计算 MPT，保持高性能                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Batch 提交流程 (Batcher)

```
┌─────────────────────────────────────────────────────────────────┐
│                   Batch 提交流程 (Batcher)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Batcher 只负责提交交易数据，不计算状态！                         │
│                                                                 │
│  1. Batcher 收集多个 L2 区块 (例如 100 个区块)                    │
│     ↓                                                           │
│  2. 压缩交易数据                                                  │
│     ↓                                                           │
│  3. 提交到 L1 BatchInbox 合约                                     │
│     DEMOBatchInbox.submitBatch({                                  │
│         startBlock:  blockStart,                                │
│         endBlock:    blockEnd,                                  │
│         txData:      compressedTxData                           │
│     })                                                          │
│                                                                 │
│  ⚠️ 注意: Batcher 不提交状态哈希和 MPT Root                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3. 状态提交流程 (Proposer)

```
┌─────────────────────────────────────────────────────────────────┐
│                   状态提交流程 (Proposer)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Proposer 负责计算 MPT Root 并提交状态承诺！                      │
│                                                                 │
│  1. Proposer 等待足够的 L2 区块确认                               │
│     ↓                                                           │
│  2. 获取目标区块的增量 StateHash                                  │
│     ↓                                                           │
│  3. 计算该区块的 MPT Root                                         │
│     - 获取当前完整状态                                           │
│     - 构建 Merkle Patricia Trie                                 │
│     - 计算 MPT Root                                             │
│     ↓                                                           │
│  4. 提交到 L1 OutputOracle 合约                                   │
│     DEMOOutputOracle.proposeOutput(                               │
│         l2BlockNumber,    // 目标区块号                         │
│         stateHash,        // 增量状态哈希                       │
│         mptRoot,          // MPT Root (Proposer 计算)          │
│         l1BlockHash                                             │
│     )                                                           │
│     ↓                                                           │
│  5. 进入挑战期 (例如 7 天)                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4. Cannon 挑战流程

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cannon 挑战流程                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Challenger 发现错误的 StateHash 或 MPTRoot                   │
│     ↓                                                           │
│  2. 调用 DEMODisputeGame.challenge() 创建争议游戏                   │
│     ↓                                                           │
│  3. 开始二分游戏                                                  │
│     - 参与者提交 move (attack 或 defend)                         │
│     - 每轮将争议范围缩小一半                                      │
│     ↓                                                           │
│  4. 定位到单条指令                                                │
│     ↓                                                           │
│  5. 链上执行该指令 (MIPS.sol)                                     │
│     - 如果涉及状态读取，验证 Merkle Proof                        │
│     ↓                                                           │
│  6. 确定胜负，分配保证金                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 争议游戏的 Attack 与 Defend

参考 Optimism 的 `op-challenger` 设计：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Attack vs Defend 机制                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  核心概念:                                                                  │
│  - 争议游戏是一棵 claim tree                                                │
│  - 每个 claim 包含一个状态声明 (state hash at position)                     │
│  - Challenger 可以对任意 claim 进行 Attack 或 Defend                        │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  Attack (攻击):                                                             │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ 含义: "我不同意这个 claim，我认为它是错的"                     │         │
│  │                                                               │         │
│  │ 场景: Challenger 本地计算的状态哈希与 claim 中的不同           │         │
│  │                                                               │         │
│  │ 操作: 提交一个新的 claim，声称正确的状态                       │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  Defend (防御):                                                             │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ 含义: "我同意这个 claim，但我要反驳它的父 claim"               │         │
│  │                                                               │         │
│  │ 场景: 有人攻击了一个正确的 claim，需要防御                     │         │
│  │                                                               │         │
│  │ 操作: 提交一个新的 claim，证明原 claim 是正确的                │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  示例 (claim tree):                                                         │
│                                                                             │
│         [Root Claim: StateHash=0xabc]  ← Proposer 提交                     │
│                    │                                                        │
│                    ▼                                                        │
│         [Attack: StateHash=0xdef]      ← Challenger A 攻击 (认为 0xabc 错) │
│                    │                                                        │
│                    ▼                                                        │
│         [Defend: StateHash=0x123]      ← Challenger B 防御 (认为 0xabc 对) │
│                    │                                                        │
│                   ...                                                       │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  Challenger 服务的行为:                                                     │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ 1. 监控所有进行中的争议游戏                                    │         │
│  │ 2. 对于每个 claim:                                            │         │
│  │    - 计算本地正确的状态哈希                                    │         │
│  │    - if 本地哈希 != claim 哈希 → Attack                       │         │
│  │    - if 本地哈希 == claim 哈希 且 claim 被错误攻击 → Defend   │         │
│  │ 3. 当游戏到达叶子节点，执行 step 进行最终验证                  │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  关键点:                                                                    │
│  - 任何人都可以运行 Challenger                                              │
│  - 诚实的 Challenger 会自动攻击错误的 claim，防御正确的 claim               │
│  - Proposer 不需要单独的防御服务，只要有诚实节点运行 Challenger 即可        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## L1 合约

### DEMOBatchInbox.sol

```solidity
// contracts/DEMOBatchInbox.sol
// Batcher 只提交交易数据，不提交状态

contract DEMOBatchInbox {
    struct BatchData {
        uint256 startBlock;
        uint256 endBlock;
        bytes32 txDataHash;     // 交易数据的哈希 (用于验证)
        uint256 l1Timestamp;
    }

    BatchData[] public batches;

    event BatchSubmitted(
        uint256 indexed batchIndex,
        uint256 startBlock,
        uint256 endBlock,
        bytes32 txDataHash
    );

    function submitBatch(
        uint256 _startBlock,
        uint256 _endBlock,
        bytes calldata _txData    // 只有交易数据，没有状态
    ) external {
        bytes32 txDataHash = keccak256(_txData);

        batches.push(BatchData({
            startBlock: _startBlock,
            endBlock: _endBlock,
            txDataHash: txDataHash,
            l1Timestamp: block.timestamp
        }));

        emit BatchSubmitted(
            batches.length - 1,
            _startBlock,
            _endBlock,
            txDataHash
        );
    }

    function getBatch(uint256 _index) external view returns (BatchData memory) {
        return batches[_index];
    }
}
```

### DEMOOutputOracle.sol

```solidity
// contracts/DEMOOutputOracle.sol

contract DEMOOutputOracle {
    struct OutputProposal {
        bytes32 stateHash;      // 增量状态哈希
        bytes32 mptRoot;        // Batch MPT Root
        uint256 l2BlockNumber;
        uint256 timestamp;
    }

    OutputProposal[] public outputs;
    uint256 public constant FINALIZATION_PERIOD = 7 days;

    function proposeOutput(
        uint256 _l2BlockNumber,
        bytes32 _stateHash,
        bytes32 _mptRoot,
        bytes32 _l1BlockHash
    ) external {
        // 验证 L1 区块哈希
        require(blockhash(block.number - 1) == _l1BlockHash, "Invalid L1 block");

        outputs.push(OutputProposal({
            stateHash: _stateHash,
            mptRoot: _mptRoot,
            l2BlockNumber: _l2BlockNumber,
            timestamp: block.timestamp
        }));
    }

    function deleteOutput(uint256 _index) external {
        // 只能由 DisputeGame 合约调用
        require(msg.sender == disputeGame, "Unauthorized");
        // 删除错误的 output
    }

    function getOutput(uint256 _index) external view returns (OutputProposal memory) {
        return outputs[_index];
    }
}
```

### DEMODisputeGame.sol

```solidity
// contracts/DEMODisputeGame.sol

contract DEMODisputeGame {
    // 使用 Cannon 的标准接口
    // 参考 optimism/packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol

    IDEMOOutputOracle public outputOracle;
    IDEMOBatchInbox public batchInbox;

    function challenge(uint256 _outputIndex) external payable {
        // 开始挑战
        // 获取被挑战的 output
        OutputProposal memory output = outputOracle.getOutput(_outputIndex);

        // 创建争议游戏
        // ...
    }

    function move(uint256 _parentIndex, Claim _claim, bool _isAttack) external {
        // 二分移动
    }

    function step(
        uint256 _claimIndex,
        bool _isAttack,
        bytes calldata _stateData,
        bytes calldata _proof
    ) external {
        // 单步执行验证
        // 使用 Merkle Proof 验证状态数据
    }

    function resolve() external {
        // 解析游戏结果
    }
}
```

---

## program (Cannon Fault Proof)

program 是运行在 Cannon MIPS VM 中的程序，用于验证 demo 状态转换。

### 入口程序

```go
// program/main.go

func main() {
    // 1. 读取输入
    batchIndex := readPreimage(batchIndexKey)
    batch := readPreimage(batchDataKey)

    // 获取上一个 Batch 的 MPT Root (已在 L1 提交)
    prevMPTRoot := readPreimage(prevMPTRootKey)

    // 2. 从 L1 派生 L2 区块
    blocks := deriveBlocks(batch)

    // 3. 初始化状态 (使用 Preimage + Merkle Proof)
    state := NewVerifiableState(prevMPTRoot)

    // 4. 执行所有区块
    for _, block := range blocks {
        for _, tx := range block.Transactions {
            // 执行交易
            // ⚠️ 这里的执行逻辑必须与 node 完全一致！
            changes := execute(state, tx)

            // 更新增量哈希
            state.UpdateIncrementalHash(changes)
        }
    }

    // 5. 计算最终 MPT Root
    finalMPTRoot := state.ComputeMPTRoot()

    // 6. 验证结果
    require(state.IncrementalHash() == batch.FinalStateHash)
    require(finalMPTRoot == batch.MPTRoot)

    // 7. 输出结果
    writeOutput(finalMPTRoot)
}
```

### 可验证状态

```go
// program/state/verifiable_state.go

type VerifiableState struct {
    mptRoot        [32]byte
    incrementalHash [32]byte

    // 已验证的状态数据缓存
    verifiedData   map[string][]byte
}

// 读取状态数据时验证 Merkle Proof
func (s *VerifiableState) Get(key []byte) ([]byte, error) {
    // 检查缓存
    if data, ok := s.verifiedData[string(key)]; ok {
        return data, nil
    }

    // 从 Preimage Oracle 获取数据和证明
    data, proof := readPreimageWithProof(key)

    // 验证 Merkle Proof
    if !verifyMerkleProof(s.mptRoot, key, data, proof) {
        return nil, errors.New("invalid merkle proof")
    }

    // 缓存已验证的数据
    s.verifiedData[string(key)] = data

    return data, nil
}

// 设置状态数据
func (s *VerifiableState) Set(key, value []byte) {
    s.verifiedData[string(key)] = value
    // 标记需要重新计算 MPT
}

// 计算新的 MPT Root
func (s *VerifiableState) ComputeMPTRoot() [32]byte {
    // 基于 verifiedData 构建新的 MPT
    mpt := NewMPT()
    for key, value := range s.verifiedData {
        mpt.Insert([]byte(key), value)
    }
    return mpt.Root()
}
```

### 代码一致性要求

```
┌─────────────────────────────────────────────────────────────────┐
│                   代码一致性要求                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  node                          program                    │
│  ┌─────────────────────┐          ┌─────────────────────┐       │
│  │ state/state.go      │    =     │ state/state.go      │       │
│  │ mpt/mpt.go          │    =     │ mpt/mpt.go          │       │
│  │ tx/execution.go     │    =     │ tx/execution.go     │       │
│  │ dex/swap.go         │    =     │ dex/swap.go         │       │
│  │ ...                 │    =     │ ...                 │       │
│  └─────────────────────┘          └─────────────────────┘       │
│                                                                 │
│  ⚠️ 核心执行逻辑和 MPT 实现必须完全相同！                         │
│  建议: 抽取为共享库 (core)                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Batch MPT 计算优化

### 性能考虑

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Batch MPT 计算优化                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 1TB 状态数据，每次 Batch 都计算完整 MPT 不现实                         │
│                                                                             │
│  解决方案: 增量 MPT 更新                                                     │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │                                                               │         │
│  │  1. 持久化 MPT 结构                                           │         │
│  │     - MPT 节点存储在磁盘上                                    │         │
│  │     - 只加载需要的节点到内存                                  │         │
│  │                                                               │         │
│  │  2. 增量更新                                                  │         │
│  │     - 只更新变更的 key-value                                  │         │
│  │     - 只重新计算受影响的路径                                  │         │
│  │                                                               │         │
│  │  3. 异步计算                                                  │         │
│  │     - 区块生产后，后台线程更新 MPT                            │         │
│  │     - Batch 提交时，MPT Root 已计算完成                       │         │
│  │                                                               │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  实现示例:                                                                  │
│                                                                             │
│  type IncrementalMPT struct {                                              │
│      db       *leveldb.DB    // 节点存储                                   │
│      root     *Node          // 根节点                                     │
│      dirty    map[string][]byte  // 待更新的 key-value                    │
│  }                                                                         │
│                                                                             │
│  func (m *IncrementalMPT) Update(key, value []byte) {                      │
│      m.dirty[string(key)] = value                                          │
│  }                                                                         │
│                                                                             │
│  func (m *IncrementalMPT) Commit() [32]byte {                              │
│      // 只更新变更的节点                                                   │
│      for key, value := range m.dirty {                                     │
│          m.updatePath([]byte(key), value)                                  │
│      }                                                                      │
│      m.dirty = make(map[string][]byte)                                     │
│      return m.root.Hash()                                                  │
│  }                                                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Batch 大小与 MPT 计算权衡

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Batch 大小与 MPT 计算权衡                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Batch 大小影响:                                                            │
│                                                                             │
│  小 Batch (10 区块):                                                        │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ ✅ 挑战窗口短，更快确认                                        │         │
│  │ ✅ MPT 增量更新小                                              │         │
│  │ ❌ L1 提交频繁，Gas 成本高                                     │         │
│  │ ❌ 更多 MPT Root 需要存储                                      │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  大 Batch (1000 区块):                                                      │
│  ┌───────────────────────────────────────────────────────────────┐         │
│  │ ✅ L1 提交少，Gas 成本低                                       │         │
│  │ ✅ MPT 存储点少                                                │         │
│  │ ❌ 挑战窗口长，确认慢                                          │         │
│  │ ❌ MPT 增量更新大                                              │         │
│  └───────────────────────────────────────────────────────────────┘         │
│                                                                             │
│  建议: 100-500 区块/Batch (根据实际状态变更量调整)                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## MVP 实现计划

### Phase 1: 基础框架 (2 周)

- [ ] 搭建项目结构
- [ ] 实现基本数据结构 (Block, Transaction, State, Batch)
- [ ] 实现简单的状态转换逻辑
- [ ] 实现增量状态哈希计算

### Phase 2: MPT 实现 (2 周)

- [ ] 实现 Merkle Patricia Trie
- [ ] 实现增量 MPT 更新
- [ ] 实现 Merkle Proof 生成与验证
- [ ] 集成到状态管理

### Phase 3: 核心模块 (3 周)

- [ ] 实现 Sequencer (区块生产)
- [ ] 实现 Batcher (批量提交 + MPT Root)
- [ ] 实现 Proposer (状态提交)
- [ ] 部署 L1 合约 (Anvil)

### Phase 4: Cannon 集成 (3 周)

- [ ] 实现 program (与 node 共享核心逻辑)
- [ ] 实现可验证状态 (Merkle Proof 验证)
- [ ] 编译为 MIPS
- [ ] 实现 Challenger
- [ ] 集成 Cannon 争议游戏

### Phase 5: 测试 (2 周)

- [ ] 单元测试
- [ ] 端到端测试
- [ ] 争议场景测试

---

## 开发环境

### 依赖

```bash
# Go 1.21+
go version

# Foundry (用于 Anvil 和合约部署)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Cannon
cd ../cannon && make cannon
```

### 启动开发环境

```bash
# 1. 启动 Anvil
./scripts/run-anvil.sh

# 2. 部署 L1 合约
./scripts/deploy.sh

# 3. 启动 demo 节点
cd node && go run ./cmd/sequencer

# 4. 启动 Batcher
cd node && go run ./cmd/batcher

# 5. 启动 Proposer
cd node && go run ./cmd/proposer
```

---

## 关键设计决策

### 1. 为什么选择混合状态承诺？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 仅增量哈希 | 计算快，存储小 | 无法证明单个数据 |
| 仅 MPT | 可证明任意数据 | 计算慢，每区块都需更新 |
| **混合方案** | 两者优点结合 | 实现复杂度稍高 |

### 2. 为什么在 Batch 级别计算 MPT？

- **性能**: 区块生产不需要等待 MPT 计算
- **成本**: MPT 计算成本分摊到多个区块
- **安全**: 每个 Batch 都有可验证的状态承诺
- **灵活**: 可根据需要调整 Batch 大小

### 3. Cannon 如何利用 MPT Root？

- 二分定位到具体指令后，执行该指令时可能需要读取状态
- 通过 Preimage Oracle 获取状态数据 + Merkle Proof
- 链上验证 Merkle Proof 与 MPT Root 一致
- 确保状态数据是正确的

---

## 参考资料

- [Optimism Cannon](https://github.com/ethereum-optimism/optimism/tree/develop/cannon)
- [Optimism Fault Proof Specs](https://specs.optimism.io/fault-proof/index.html)
- [Merkle Patricia Trie](https://ethereum.org/en/developers/docs/data-structures-and-encoding/patricia-merkle-trie/)
- [Cosmos SDK](https://docs.cosmos.network/)
