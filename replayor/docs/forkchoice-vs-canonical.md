# Forkchoice Head vs Canonical Chain Head

## 问题

如果 canonical chain head 的 block number 是 100，为什么 FCU 设置为 block 10 时，canonical block number (cast bn) 不会变？

## 核心概念

在 Reth 中，存在两个不同的概念：

### 1. Forkchoice Head (通过 FCU 设置)
- **定义**: 通过 `ForkchoiceUpdate` API 显式设置的链头
- **特点**: 
  - 可以是任何已知的 block hash
  - 可以回退到更早的区块
  - 由共识层（如 op-node）控制

### 2. Canonical Chain Head (规范链头)
- **定义**: 基于最长链规则维护的实际规范链的头部
- **特点**:
  - 遵循最长链原则
  - 不会自动回退（除非有更长的分叉链）
  - 由执行层内部维护

## 为什么 FCU 设置为 block 10 时，canonical block number 不变？

### 场景示例

```
当前状态:
- Canonical Chain Head: Block 100 (Hash_100)
- Forkchoice Head: Block 100 (Hash_100)

执行 FCU(block 10):
- Forkchoice Head: Block 10 (Hash_10)  ← 更新了
- Canonical Chain Head: Block 100 (Hash_100)  ← 仍然不变
```

### 原因分析

1. **Forkchoice Head 和 Canonical Chain 是分离的**
   - FCU 只更新 forkchoice head
   - Canonical chain 基于最长链规则，不会因为 forkchoice head 回退而回退

2. **`BlockByNumber(nil)` 返回的是 Canonical Chain Head**
   ```go
   // 在 benchmark.go 中
   currentBlock, err := r.clients.DestNode.BlockByNumber(ctx, nil)
   // 这里返回的是 canonical chain 的 latest block，不是 forkchoice head
   ```

3. **Reth 内部机制**
   - Reth 维护两个独立的状态：
     - **Forkchoice State**: 由 FCU 控制，用于构建新区块
     - **Canonical Chain**: 基于最长链规则，用于查询和状态访问
   - 即使 forkchoice head 回退到 block 10，canonical chain 仍然保持在 block 100（因为它是当前最长链）

## 实际影响

### FCU 设置为更早区块时会发生什么？

1. **Forkchoice Head 会改变**
   - 新的区块构建会基于 block 10 作为父区块
   - 如果继续构建，会创建 block 11, 12, 13...

2. **Canonical Chain 不会立即改变**
   - `BlockByNumber(nil)` 仍然返回 block 100
   - 状态查询仍然基于 block 100 的状态

3. **何时 Canonical Chain 会改变？**
   - 只有当基于新 forkchoice head 构建的链**超过**当前 canonical chain 的长度时
   - 例如：如果从 block 10 构建到 block 101，且这条链的总难度更高，才会触发 reorg

## 代码中的体现

```go
// packages/replayor/benchmark.go:57-60
func (r *Benchmark) getLatestBlockFromDestNode(ctx context.Context) (*types.Block, error) {
    return retry.Do(ctx, 10, retry.Exponential(), func() (*types.Block, error) {
        return r.clients.DestNode.BlockByNumber(ctx, nil)  // 返回 canonical chain head
    })
}
```

这个函数返回的是 **canonical chain** 的 latest block，而不是 forkchoice head。

## 总结

- **FCU 更新的是 Forkchoice Head**，可以设置为任何已知区块
- **Canonical Chain Head 基于最长链规则**，不会因为 forkchoice head 回退而回退
- **`BlockByNumber(nil)` 返回 Canonical Chain Head**，所以即使 FCU 设置为 block 10，查询结果仍然是 block 100
- **只有当新链超过当前链时**，canonical chain 才会切换

## 相关代码位置

- FCU 调用: `packages/replayor/benchmark.go:228, 284`
- 查询 latest block: `packages/replayor/benchmark.go:59`
- 监控进度: `packages/replayor/benchmark.go:407`

