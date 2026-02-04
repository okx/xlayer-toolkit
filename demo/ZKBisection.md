# ZK Bisection 方案

xlayerdex 作为一个高性能区块链，需要有方法保证链安全（去中心化）。本文探讨了使用 **ZK Bisection** 机制保证 xlayerdex 链安全时遇到的问题及解决方案。

**目标**：确认 ZK Bisection 模式下本文给出的方案的可行性。

---

## 1. 背景

### 1.1 Hybrid Proof 的一般流程

使用 Hybrid Proof 机制时，Proposer 只提交 batch 信息，不提交 ZK proof；当有人发起挑战时，才生成 ZK proof 并提交。

```mermaid
sequenceDiagram
    participant Sequencer
    participant L1
    participant Challenger

    Sequencer->>L1: 提交 batch (output_hash, commitment)
    L1->>L1: 开始 7 天挑战期
    
    alt 无人挑战
        L1->>L1: 7 天后自动确认
    else 有人挑战
        Challenger->>L1: 质押 bond，发起挑战
        Sequencer->>L1: 提交 ZK proof
        L1->>L1: 验证 proof，决定胜负
    end
```

### 1.2 原方案设计

原方案引入两个概念：
- `state_hash`：增量哈希，用于区块同步
- `commitment`：异步计算的 Merkle 结构，用于 ZK 证明时验证状态

| 概念 | 用途 | 计算方式 |
|------|------|---------|
| state_hash | 区块同步 | 同步计算（每区块） |
| commitment | ZK 证明 | 异步计算（每 N 区块） |

### 1.3 场景需求

xlayerdex 需要支持：
- **极高 TPS**：10 万+ TPS（0.1 秒出块，每区块 1 万笔交易）
- **大规模账户**：1 亿+ 账户
- **低延迟**：出块不能有性能瓶颈

---

## 2. 问题

原方案存在两个问题：

### 2.1 问题一：commitment 的具体实现未明确

原方案提到 commitment 是 Merkle 结构，但未明确是 **MPT** 还是 **SMT**。

在高 TPS + 异步更新场景下，MPT 存在以下问题：

| 问题 | 说明 |
|------|------|
| 并行更新困难 | 路径可能冲突，难以并行 |
| ZK 不友好 | 结构复杂，电路复杂 |
| 更新路径不可预测 | 需要遍历查找 |

### 2.2 问题二：证明整个 Batch 成本过高

原方案被挑战时需要证明**整个 batch 的所有交易**：

| 证明范围 | 成本 |
|---------|------|
| 100 万笔交易 | ~$39,000 |
| 1 笔交易 | ~$1-10 |

**核心问题**：如何将证明范围从整个 batch 缩小到单笔交易？

---

## 3. 目标

| 优先级 | 目标 | 说明 |
|--------|------|------|
| P0 | **性能** | 不让状态树成为瓶颈，支持 10 万 TPS |
| P1 | **安全** | L1 可验证 L2 状态转换正确性 |
| P2 | **成本** | 被挑战成本可接受（<$500） |
| P3 | **终局性** | 可接受 7 天延迟 |

---

## 4. 解决方案

针对上述两个问题，提出两个优化：

| 问题 | 优化方案 |
|------|---------|
| commitment 实现不明确 | **优化一：用 SMT 替代 MPT** |
| 证明整个 batch 成本高 | **优化二：trace_hash + Bisection** |

### 4.1 优化一：用 SMT 替代 MPT

**SMT (Sparse Merkle Tree)** 相比 **MPT** 更适合异步并行更新：

| 特性 | MPT | SMT |
|------|-----|-----|
| 树深度 | 可变（复杂） | 固定 256 层（简单） |
| 账户定位 | 需要遍历查找 | 直接索引（地址→位置） |
| 并行更新 | 困难（路径可能冲突） | 容易（路径独立） |
| ZK 友好性 | 一般（结构复杂） | 更好（结构简单） |

**异步 SMT 更新流程**：

```mermaid
flowchart LR
    subgraph 每100秒
        A[汇总 RW log] --> B["~200 万账户变化"]
        B --> C["并行更新 SMT (16-32s)"]
        C --> D[生成 commitment]
    end
    
    D --> E[提交 L1]
```

**性能对比**：

| 方案 | 更新 200 万账户 |
|------|----------------|
| MPT | ~60-120 秒（难以并行） |
| SMT | ~16-32 秒（16 核并行） |

### 4.2 优化二：trace_hash + Bisection

引入 **trace_hash** 用于 Bisection 定位争议点，将证明范围从整个 batch 缩小到单个区块。

> **为什么是区块而不是交易？** DEX 交易是并行执行的，以区块为单位更合适。

#### 4.2.1 Block Trace Hash

每个区块计算：
```
trace_hash_N = H(trace_hash_{N-1}, block_hash_N, state_hash_N)
```

```mermaid
flowchart LR
    T0["trace_0 = H(0, block_0, state_0)"]
    T1["trace_1 = H(trace_0, block_1, state_1)"]
    T2["trace_2 = H(trace_1, block_2, state_2)"]
    TN["trace_N = H(..., block_N, state_N)"]
    
    T0 --> T1 --> T2 --> TN
```

开销：每区块 3 次 hash ≈ 可忽略

#### 4.2.2 Bisection 定位

被挑战时，通过 ~10 轮二分法定位到单个争议区块：

```mermaid
sequenceDiagram
    participant C as Challenger
    participant L1 as L1 Contract
    participant P as Proposer

    C->>L1: 质押 bond，发起挑战
    
    loop ~10 轮二分 (log2(1000))
        P->>L1: "执行到区块 X 后，trace_hash = Y"
        C->>L1: "同意" or "不同意"
        L1->>L1: 缩小争议范围
    end
    
    Note over L1: 定位到争议区块 block_N
```

#### 4.2.3 ZK 证明单个区块

定位到 block_N 后，只需证明这一个区块（1 万笔交易）：

```mermaid
flowchart LR
    A[重建 block_N 前的状态] --> B[生成 SMT proof]
    B --> C[生成 ZK proof]
    C --> D[L1 验证]
```

**成本对比**：

| 方案 | 证明范围 | 成本 |
|------|---------|------|
| 原方案 | 100 万笔（整个 batch） | ~$39,000 |
| ZK Bisection | 1 万笔（单个区块） | ~$390 |

---

## 5. 完整方案

### 5.1 整体架构

```mermaid
flowchart TB
    subgraph 热路径["热路径 (出块时, 每 0.1s)"]
        A1[并行执行交易] --> A2[更新内存 KV]
        A2 --> A3["计算 state_hash"]
        A3 --> A4["计算 block trace_hash"]
    end
    
    subgraph 冷路径["冷路径 (异步, 每 100s)"]
        B1[汇总 RW log] --> B2[更新 SMT]
        B2 --> B3[生成 commitment]
    end
    
    subgraph L1["L1 (Ethereum)"]
        C1[提交 output_hash + commitment]
        C2[7 天挑战期]
        C3[无人挑战 → 确认]
    end
    
    A4 --> B1
    B3 --> C1
    C1 --> C2
    C2 --> C3
```

### 5.2 正常流程

```mermaid
sequenceDiagram
    participant Seq as Sequencer
    participant SMT as SMT Worker
    participant L1 as L1 Contract

    loop 每 0.1 秒 (每区块)
        Seq->>Seq: 并行执行交易，更新 KV
        Seq->>Seq: 计算 state_hash
        Seq->>Seq: 计算 block trace_hash
        Note over Seq: 不计算 SMT!
    end
    
    loop 每 100 秒 (每 batch = 1000 区块)
        Seq->>SMT: 发送 RW log
        SMT->>SMT: 异步更新 SMT (16-32s)
        SMT->>L1: 提交 (output_hash, commitment, final_trace_hash)
        L1->>L1: 开始 7 天挑战期
    end
    
    Note over L1: 无人挑战 → 自动确认
```

### 5.3 被挑战流程

```mermaid
sequenceDiagram
    participant C as Challenger
    participant L1 as L1 Contract
    participant P as Proposer

    C->>L1: 质押 bond，发起挑战
    
    rect rgb(240, 240, 240)
        Note over C,P: 阶段一：Bisection 定位 (~10 轮)
        loop ~10 轮二分
            P->>L1: "执行到区块 X 后，trace_hash = Y"
            C->>L1: "同意" or "不同意"
        end
        Note over L1: 定位到争议区块 block_N
    end
    
    rect rgb(240, 240, 240)
        Note over P: 阶段二：重建状态
        P->>P: 加载 SMT 快照 + 增量
        P->>P: 重放到 block_N 之前
        P->>P: 生成 SMT proof
    end
    
    rect rgb(240, 240, 240)
        Note over P,L1: 阶段三：ZK 证明
        P->>P: 生成 ZK proof (证明 block_N, 1万笔交易)
        P->>L1: 提交 ZK proof
        L1->>L1: 验证 proof
    end
    
    alt 验证通过
        L1->>P: Proposer 获胜
    else 验证失败
        L1->>C: Challenger 获胜
    end
```

### 5.4 zkVM 证明逻辑

```rust
fn prove(
    // private input:
    initial_used_states,        // block_N 涉及的账户状态
    initial_used_states_proof,  // SMT proof
    transactions,               // block_N 的所有交易 (1万笔)
    
    // public input:
    prev_commitment,            // 执行前的 SMT root
    prev_trace_hash,            // block_{N-1} 后的 trace_hash
    expected_block_hash,        // block_N 的 block_hash
    expected_state_hash,        // block_N 后的 state_hash
    expected_trace_hash,        // block_N 后的 trace_hash
) {
    // 1. 验证输入状态属于 prev_commitment
    verify_smt_proof(prev_commitment, initial_used_states, initial_used_states_proof);
    
    // 2. 并行执行区块内所有交易
    new_states = execute_block(transactions, initial_used_states);
    
    // 3. 计算 block_hash 和 state_hash
    computed_block_hash = hash(transactions);
    computed_state_hash = calc_state_hash(new_states);
    
    // 4. 计算 trace_hash
    computed_trace_hash = H(prev_trace_hash, computed_block_hash, computed_state_hash);
    
    // 5. 验证结果
    assert_eq!(computed_block_hash, expected_block_hash);
    assert_eq!(computed_state_hash, expected_state_hash);
    assert_eq!(computed_trace_hash, expected_trace_hash);
}
```

### 5.5 增量 SMT + 定期快照

为了节省存储，采用增量存储：

```mermaid
flowchart TB
    subgraph Day0["Day 0"]
        S0["Snapshot_0 (~10 GB)"]
        D0["delta_0...delta_863"]
    end
    
    subgraph Day1["Day 1"]
        S1["Snapshot_1 (~10 GB)"]
        D1["delta_864...delta_1727"]
    end
    
    S0 --> S1
```

存储需求（7 天）：
- 快照：7 × 10 GB = ~70 GB
- 增量：6048 × 200 MB = ~1.2 TB
- **总计：~1.3 TB** ✅

---

## 6. 成本分析

### 6.1 正常运营成本

| 项目 | 频率 | 单价 | 日成本 |
|------|------|------|--------|
| L1 提交 batch | 864 次/天 | ~$10 | ~$8,640 |
| SMT 计算 | 864 次/天 | 计算资源 | 可忽略 |
| 存储 | - | - | ~$50/天 |
| **总计** | | | **~$8,700/天** |

### 6.2 被挑战成本

| 项目 | 成本 |
|------|------|
| Bisection L1 Gas (~10 轮) | ~$50 |
| ZK 证明生成 (1 万笔) | ~$390 |
| L1 验证 Gas | ~$50-100 |
| **总计** | **~$500/次** |

---

## 7. 总结

### 7.1 两个优化

| 优化 | 解决问题 | 效果 |
|------|---------|------|
| **SMT 替代 MPT** | 异步更新性能 | 更新时间 60-120s → 16-32s |
| **trace_hash + Bisection** | 证明成本过高 | 成本 $39,000 → ~$500 |

### 7.2 与原方案对比

| 方面 | 原方案 | ZK Bisection |
|------|--------|--------------|
| commitment 实现 | Merkle（未明确） | SMT（明确） |
| 并行更新 | 困难 | 容易（16 核并行） |
| Bisection | ❌ 无 | ✅ 有 (~10 轮) |
| trace_hash | ❌ 无 | ✅ 每区块记录 |
| 证明范围 | 整个 batch (100 万笔) | 单个区块 (1 万笔) |
| 被挑战成本 | ~$39,000 | ~$500 |

### 7.3 优缺点

| 优点 | 缺点 |
|------|------|
| ✅ 正常情况无 ZK 成本 | ❌ 终局性 7 天 |
| ✅ 出块性能不受影响（10 万 TPS） | ❌ 需要异步 SMT 更新 |
| ✅ 被挑战成本低（~$500） | ❌ 被挑战时需要重建状态 |
| ✅ 支持 1 亿账户 | ❌ 存储需求 ~4.5 TB |
| ✅ DEX 并行执行友好 | |

---

## 8. 附录

### 8.1 关键参数

| 参数 | 值 |
|------|-----|
| 出块速度 | 0.1 秒 |
| 每区块交易 | 10,000 笔（并行执行） |
| TPS | 100,000 |
| Batch 大小 | 1000 区块（100 秒） |
| SMT 更新 | 16-32 秒（16 核并行） |
| 快照频率 | 每天 1 次 |
| 挑战期 | 7 天 |
| Bisection 轮数 | ~10 轮（定位到区块） |

### 8.2 硬件需求

| 组件 | CPU | 内存 | 存储 |
|------|-----|------|------|
| Sequencer | 32+ 核 | 128 GB | 500 GB SSD |
| RPC 节点 | 64 核 | 256 GB | 5 TB |
| Prover | 16 核 × 10 台 | 64 GB × 10 | - |

### 8.3 存储需求

| 内容 | 7 天总量 |
|------|---------|
| 交易数据 | ~3 TB |
| Trace Hash | ~190 GB |
| SMT 增量 | ~1.2 TB |
| SMT 快照 | ~70 GB |
| **总计** | **~4.5 TB** |

---

## 9. 参考资料

- [Optimism Fault Proof](https://docs.optimism.io/stack/protocol/fault-proofs/explainer)
- [op-succinct](https://github.com/succinctlabs/op-succinct)
- [SP1 zkVM](https://github.com/succinctlabs/sp1)
- [Sparse Merkle Tree](https://medium.com/@kelvinfichter/sparse-merkle-trees-explained-f41e6cbb2d6b)
