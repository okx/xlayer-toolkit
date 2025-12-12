# Replayor 架构图和泳道图

## 系统架构图

```mermaid
graph TB
    subgraph "数据源"
        SN[SourceNode<br/>源节点<br/>提供历史区块]
    end
    
    subgraph "Replayor 服务"
        RS[Replayor Service]
        ST[Strategy<br/>策略处理]
        BM[Benchmark<br/>基准引擎]
        SS[Stats<br/>统计]
    end
    
    subgraph "执行层"
        RE[Reth Node]
        EA[Engine API]
        DN[DestNode RPC]
    end
    
    subgraph "存储"
        STO[Storage<br/>S3/Disk]
    end
    
    SN -->|getBlockByNumber| RS
    RS --> ST
    ST --> BM
    BM -->|ForkchoiceUpdate<br/>GetPayload<br/>NewPayload| EA
    EA --> RE
    BM -->|查询状态| DN
    BM --> SS
    SS --> STO
```

## 完整泳道图 - 区块重放流程

```mermaid
sequenceDiagram
    participant SN as SourceNode
    participant RP as Replayor
    participant ST as Strategy
    participant EA as Engine API
    participant DN as DestNode
    participant SS as Stats
    
    Note over RP: 初始化
    RP->>DN: BlockByNumber(当前)
    DN-->>RP: 当前区块
    RP->>EA: ForkchoiceUpdate(初始化)
    EA-->>RP: PayloadStatus
    
    Note over RP: 加载区块
    loop 批量加载(25并发)
        RP->>SN: getBlockByNumber(n)
        SN-->>RP: Block
    end
    
    Note over RP: 处理区块
    RP->>ST: BlockReceived(Block)
    ST-->>RP: BlockCreationParams
    
    Note over RP: 提交区块
    RP->>EA: ForkchoiceUpdate(state, attrs)
    activate EA
    EA-->>RP: PayloadID
    Note over RP: 记录FCU时间
    
    RP->>EA: GetPayload(PayloadID)
    EA-->>RP: ExecutionPayload
    Note over RP: 记录Get时间
    
    RP->>EA: NewPayload(ExecutionPayload)
    EA-->>RP: PayloadStatus
    Note over RP: 记录New时间
    
    RP->>EA: ForkchoiceUpdate(newState, nil)
    EA-->>RP: PayloadStatus
    Note over RP: 记录FCU2时间
    deactivate EA
    
    Note over RP: 收集统计
    RP->>DN: BlockReceipts(hash)
    DN-->>RP: Receipts
    
    opt OpCode统计
        RP->>DN: debug_traceTransaction
        DN-->>RP: Trace
    end
    
    opt Storage统计
        RP->>DN: debug_traceBlockByHash
        DN-->>RP: StorageTrace
    end
    
    RP->>SS: RecordBlockStats
    SS-->>RP: OK
```

## Engine API 调用流程

```mermaid
sequenceDiagram
    participant RP as Replayor
    participant EA as Engine API (Reth)
    
    Note over RP,EA: 单个区块处理流程
    
    RP->>EA: 1. ForkchoiceUpdate(state, attrs)
    Note right of EA: 设置父区块<br/>提供交易和时间戳<br/>开始构建
    EA-->>RP: PayloadID
    
    RP->>EA: 2. GetPayload(PayloadID)
    Note right of EA: 返回构建好的<br/>执行结果
    EA-->>RP: ExecutionPayload
    
    RP->>EA: 3. NewPayload(ExecutionPayload)
    Note right of EA: 验证并接受<br/>执行结果
    EA-->>RP: PayloadStatus
    
    RP->>EA: 4. ForkchoiceUpdate(newState, nil)
    Note right of EA: 更新链头<br/>完成确认
    EA-->>RP: PayloadStatus
```

## 组件交互图

```mermaid
flowchart TD
    A[SourceNode<br/>getBlockByNumber] --> B[Replayor<br/>加载区块]
    B --> C[Strategy<br/>转换BlockCreationParams]
    C --> D[Benchmark<br/>处理区块]
    
    D --> E1[ForkchoiceUpdate<br/>带attrs]
    E1 --> E2[GetPayload]
    E2 --> E3[NewPayload]
    E3 --> E4[ForkchoiceUpdate<br/>无attrs]
    
    E1 --> F[Engine API]
    E2 --> F
    E3 --> F
    E4 --> F
    
    F --> G[Reth<br/>执行节点]
    
    D --> H[DestNode<br/>查询Receipts/Trace]
    H --> I[Stats<br/>记录指标]
    I --> J[Storage<br/>持久化]
    
    style A fill:#e8f5e9
    style B fill:#e1f5ff
    style F fill:#f3e5f5
    style G fill:#fff4e1
    style J fill:#fce4ec
```

## 关键接口说明

### SourceNode 接口
- `eth_getBlockByNumber`: 获取指定区块号的完整区块数据

### Engine API 接口
- `engine_forkchoiceUpdatedV3`: 更新forkchoice状态，可选提供PayloadAttributes
- `engine_getPayloadV3`: 根据PayloadID获取构建好的执行结果
- `engine_newPayloadV3`: 提交执行结果到执行层

### DestNode 接口
- `eth_getBlockByNumber`: 获取当前区块
- `eth_getBlockReceipts`: 获取区块的收据
- `debug_traceTransaction`: 追踪交易执行过程
- `debug_traceBlockByHash`: 追踪区块的存储变化

