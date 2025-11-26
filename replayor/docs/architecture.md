# Replayor 架构图和泳道图

## 系统架构图

```mermaid
graph TB
    subgraph "数据源层"
        SourceNode[SourceNode<br/>源节点<br/>提供历史区块数据]
    end
    
    subgraph "Replayor 服务层"
        Replayor[Replayor Service<br/>核心服务]
        Strategy[Strategy<br/>策略层<br/>处理区块转换]
        Stats[Stats<br/>统计模块]
        Benchmark[Benchmark<br/>基准测试引擎]
    end
    
    subgraph "执行层"
        Reth[Reth Node<br/>执行节点]
        EngineAPI[Engine API<br/>引擎接口]
        DestNode[DestNode<br/>目标节点RPC]
    end
    
    subgraph "存储层"
        Storage[Storage<br/>统计结果存储<br/>S3/Disk]
    end
    
    SourceNode -->|getBlockByNumber<br/>获取区块| Replayor
    Replayor -->|处理区块| Strategy
    Strategy -->|BlockCreationParams| Benchmark
    Benchmark -->|ForkchoiceUpdate<br/>GetPayload<br/>NewPayload| EngineAPI
    EngineAPI -->|执行区块| Reth
    Benchmark -->|查询状态| DestNode
    Benchmark -->|记录统计| Stats
    Stats -->|保存结果| Storage
    
    style Replayor fill:#e1f5ff
    style Reth fill:#fff4e1
    style SourceNode fill:#e8f5e9
    style EngineAPI fill:#f3e5f5
```

## 组件说明

### SourceNode (源节点)
- **职责**: 提供历史区块数据
- **接口**: `eth_getBlockByNumber`
- **用途**: Replayor从中获取需要重放的区块数据

### Replayor Service (核心服务)
- **职责**: 协调整个重放流程
- **功能**:
  - 初始化客户端连接
  - 管理Benchmark生命周期
  - 监控重放进度

### Strategy (策略层)
- **职责**: 处理区块转换逻辑
- **类型**: 
  - `OneForOne`: 一对一重放
  - `Replay`: 重放策略
  - `Stress`: 压力测试策略
- **功能**: 将区块转换为`BlockCreationParams`

### Benchmark (基准测试引擎)
- **职责**: 执行区块重放的核心逻辑
- **功能**:
  - 从SourceNode加载区块
  - 通过Engine API提交区块
  - 收集性能统计

### Reth (执行节点)
- **职责**: 执行区块并维护状态
- **接口**: Engine API
- **功能**: 执行交易、更新状态树

### Engine API (引擎接口)
- **职责**: 提供区块构建和执行接口
- **主要接口**:
  - `engine_forkchoiceUpdatedV3`
  - `engine_getPayloadV3`
  - `engine_newPayloadV3`

### DestNode (目标节点RPC)
- **职责**: 提供查询接口
- **接口**: 
  - `eth_getBlockByNumber`
  - `eth_getBlockReceipts`
  - `debug_traceTransaction`
  - `debug_traceBlockByHash`

### Stats (统计模块)
- **职责**: 收集和存储性能指标
- **指标**: 
  - FCU时间
  - GetPayload时间
  - NewPayload时间
  - Gas使用情况
  - OpCode统计
  - Storage变化

---

## 泳道图 - 区块重放流程

```mermaid
sequenceDiagram
    participant SourceNode as SourceNode<br/>(源节点)
    participant Replayor as Replayor<br/>(重放服务)
    participant Strategy as Strategy<br/>(策略层)
    participant EngineAPI as Engine API<br/>(Reth)
    participant DestNode as DestNode<br/>(目标节点)
    participant Stats as Stats<br/>(统计模块)
    
    Note over Replayor: 初始化阶段
    Replayor->>DestNode: BlockByNumber(当前区块)
    DestNode-->>Replayor: 当前区块信息
    
    Replayor->>EngineAPI: ForkchoiceUpdate(初始化状态)
    EngineAPI-->>Replayor: PayloadStatus
    
    Note over Replayor: 区块加载阶段
    loop 批量加载区块 (并发25个)
        Replayor->>SourceNode: getBlockByNumber(blockNum)
        SourceNode-->>Replayor: Block数据
    end
    
    Note over Replayor: 区块处理阶段
    Replayor->>Strategy: BlockReceived(Block)
    Strategy-->>Replayor: BlockCreationParams
    
    Note over Replayor: 区块提交阶段
    Replayor->>EngineAPI: ForkchoiceUpdate(state, attrs)<br/>包含PayloadAttributes
    activate EngineAPI
    EngineAPI-->>Replayor: PayloadID, PayloadStatus
    Note over Replayor: 记录FCU时间
    
    Replayor->>EngineAPI: GetPayload(PayloadID)
    EngineAPI-->>Replayor: ExecutionPayloadEnvelope
    Note over Replayor: 记录GetPayload时间
    
    Replayor->>Strategy: ValidateExecution(envelope, params)
    Strategy-->>Replayor: 验证结果
    
    Replayor->>EngineAPI: NewPayload(ExecutionPayload)
    EngineAPI-->>Replayor: PayloadStatus
    Note over Replayor: 记录NewPayload时间
    
    Replayor->>EngineAPI: ForkchoiceUpdate(newState, nil)<br/>更新链头
    EngineAPI-->>Replayor: PayloadStatus
    Note over Replayor: 记录FCU2时间
    deactivate EngineAPI
    
    Replayor->>Strategy: ValidateBlock(envelope, params)
    Strategy-->>Replayor: 验证结果
    
    Note over Replayor: 统计收集阶段
    Replayor->>DestNode: BlockReceipts(blockHash)
    DestNode-->>Replayor: Receipts数组
    
    opt 启用OpCode统计
        Replayor->>DestNode: debug_traceTransaction(txHash)
        DestNode-->>Replayor: TxTrace数据
    end
    
    opt 启用Storage统计
        Replayor->>DestNode: debug_traceBlockByHash(blockHash)
        DestNode-->>Replayor: StorageTrace数据
    end
    
    Replayor->>Stats: RecordBlockStats(stats)
    Stats-->>Replayor: 确认
    
    Note over Replayor: 定期写入
    Replayor->>Stats: Write()<br/>每100个区块或完成时
    Stats-->>Replayor: 确认
```

---

## 详细流程说明

### 1. 初始化阶段
1. Replayor连接DestNode，获取当前区块号
2. 通过ForkchoiceUpdate设置初始状态，等待Reth同步完成
3. 如果设置了BenchmarkStartBlock，会先快速推进到起始区块

### 2. 区块加载阶段
- 使用并发（25个goroutine）从SourceNode批量获取区块
- 通过`getBlockByNumber`获取指定区块号的数据
- 将区块放入`incomingBlocks`通道

### 3. 区块转换阶段
- `mapBlocks`协程从`incomingBlocks`读取区块
- 通过Strategy的`BlockReceived`方法转换为`BlockCreationParams`
- 将转换后的参数放入`processBlocks`通道

### 4. 区块提交阶段（核心流程）
1. **ForkchoiceUpdate (带PayloadAttributes)**
   - 设置父区块的forkchoice状态
   - 提供PayloadAttributes（包含交易、时间戳等）
   - Reth返回PayloadID用于后续获取

2. **GetPayload**
   - 使用PayloadID获取执行后的区块
   - 包含完整的执行结果

3. **验证执行结果**
   - 通过Strategy验证执行结果是否正确

4. **NewPayload**
   - 提交执行结果到Reth
   - Reth验证并接受区块

5. **ForkchoiceUpdate (不带PayloadAttributes)**
   - 更新链头到新提交的区块
   - 完成区块的最终确认

### 5. 统计收集阶段
- 从DestNode获取区块的Receipts
- 可选：通过debug_traceTransaction获取OpCode统计
- 可选：通过debug_traceBlockByHash获取Storage变化
- 记录所有性能指标到Stats模块

### 6. 数据持久化
- 每100个区块自动写入一次
- 测试完成时最终写入
- 支持S3和本地磁盘存储

---

## Engine API 调用时序

```mermaid
sequenceDiagram
    participant Replayor
    participant EngineAPI as Engine API (Reth)
    
    Note over Replayor,EngineAPI: 单个区块的完整流程
    
    Replayor->>EngineAPI: 1. ForkchoiceUpdate(state, attrs)
    Note right of EngineAPI: 设置父区块状态<br/>提供PayloadAttributes<br/>开始构建区块
    EngineAPI-->>Replayor: PayloadID, PayloadStatus
    
    Replayor->>EngineAPI: 2. GetPayload(PayloadID)
    Note right of EngineAPI: 返回构建好的<br/>ExecutionPayload
    EngineAPI-->>Replayor: ExecutionPayloadEnvelope
    
    Replayor->>EngineAPI: 3. NewPayload(ExecutionPayload)
    Note right of EngineAPI: 验证并接受<br/>执行结果
    EngineAPI-->>Replayor: PayloadStatus
    
    Replayor->>EngineAPI: 4. ForkchoiceUpdate(newState, nil)
    Note right of EngineAPI: 更新链头<br/>完成确认
    EngineAPI-->>Replayor: PayloadStatus
```

---

## 数据流图

```mermaid
flowchart LR
    A[SourceNode<br/>历史区块] -->|getBlockByNumber| B[Replayor<br/>加载区块]
    B -->|Block| C[Strategy<br/>转换处理]
    C -->|BlockCreationParams| D[Benchmark<br/>构建Payload]
    D -->|ForkchoiceUpdate| E[Engine API<br/>构建区块]
    E -->|GetPayload| D
    D -->|NewPayload| E
    E -->|执行结果| F[Reth<br/>状态更新]
    D -->|查询Receipts| G[DestNode<br/>获取数据]
    G -->|统计数据| H[Stats<br/>记录指标]
    H -->|持久化| I[Storage<br/>S3/Disk]
    
    style A fill:#e8f5e9
    style B fill:#e1f5ff
    style E fill:#f3e5f5
    style F fill:#fff4e1
    style I fill:#fce4ec
```

