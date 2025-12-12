# TPS 追踪器使用说明

## 概述

TPS（Transactions Per Second）追踪器用于实时监控发送给执行层（EL）的 ForkchoiceUpdate (FCU) 调用中的交易处理性能。

## 功能特性

TPS 追踪器自动统计以下指标：

- **Current TPS**: 基于 5 秒滑动窗口的当前交易处理速度
- **Average TPS**: 自程序启动以来的平均交易处理速度
- **Max TPS**: 记录到的最大 TPS 值
- **Min TPS**: 记录到的最小 TPS 值（不包括零值）
- **Total Txs**: 累计处理的总交易数
- **Last Update**: 最后一次记录交易的时间
- **Uptime**: 程序运行时间

## 自动集成

TPS 追踪器已经自动集成到 `Benchmark` 中，无需额外配置。当你运行 replayor 时，它会：

1. 在 benchmark 开始时自动启动
2. 每 5 秒自动输出统计信息到 stdout
3. 在 benchmark 结束时自动停止并输出最终统计

## 输出格式示例

```
========== TPS Stats ==========
Current TPS:  1828.16 tx/s
Average TPS:  257.97 tx/s
Max TPS:      2500.00 tx/s
Min TPS:      1200.50 tx/s
Total Txs:    1290
Last Update:  14:17:42
Uptime:       5s
=====================================
```

## 工作原理

### 统计时机

TPS 追踪器在每次 `ForkchoiceUpdate`（带 attributes）调用后记录交易数：

```go
// 在 benchmark.go 的 addBlock 函数中
result, err := r.clients.EngineApi.ForkchoiceUpdate(ctx, state, attrs)
// ... 错误处理 ...

// 记录 TPS
r.tpsTracker.RecordFCU(len(txns))
```

### 滑动窗口算法

- 使用 5 秒滑动窗口计算当前 TPS
- 自动清理超过窗口时间的旧事件
- 动态更新 Max/Min TPS 值

### 线程安全

TPS 追踪器使用 `sync.RWMutex` 保证并发访问安全，可以在多个 goroutine 中安全使用。

## 实现细节

### 核心结构

```go
type TPSTracker struct {
    currentTPS float64      // 当前 TPS
    maxTPS     float64      // 最大 TPS
    minTPS     float64      // 最小 TPS
    totalTxs   uint64       // 总交易数
    startTime  time.Time    // 启动时间
    lastUpdate time.Time    // 最后更新时间
    window     []txEvent    // 滑动窗口事件
    windowSize time.Duration // 窗口大小（5秒）
}
```

### 主要方法

- `NewTPSTracker(logger)`: 创建新的 TPS 追踪器
- `Start(ctx)`: 启动定期报告 goroutine
- `RecordFCU(txCount)`: 记录一次 FCU 调用的交易数
- `GetStats()`: 获取当前统计数据（线程安全）
- `Stop()`: 停止追踪器并输出最终统计

## 测试

运行测试验证功能：

```bash
go test -v ./packages/stats -run TestTPSTracker
```

测试涵盖：
- 基本 TPS 统计
- 零交易场景
- 并发访问安全性

## 日志输出

除了格式化的 stdout 输出，TPS 追踪器还会将统计信息输出到标准日志：

```
INFO [MM-DD|HH:MM:SS] TPS statistics currentTPS=1828.16 avgTPS=257.97 maxTPS=2500.00 minTPS=1200.50 totalTxs=1290 uptime=5s
```

## 性能影响

TPS 追踪器的性能开销极小：
- 记录操作只涉及简单的内存操作和时间戳
- 使用读写锁优化并发访问
- 滑动窗口自动清理，内存占用稳定
- 后台报告独立运行，不影响主流程

## 注意事项

1. **统计粒度**: TPS 基于 FCU 调用，不是单个交易的时间戳
2. **滑动窗口**: 当前 TPS 反映最近 5 秒的性能，可能与平均 TPS 有差异
3. **Min TPS**: 如果 TPS 为零（无交易），不会更新 Min TPS
4. **首次输出**: 第一次统计输出会在启动后 5 秒后显示

## 自定义配置

如果需要自定义报告间隔或窗口大小，可以修改 `tps.go` 中的常量：

```go
// 当前默认值
windowSize: 5 * time.Second     // 滑动窗口大小
ticker := time.NewTicker(5 * time.Second) // 报告间隔
```

