L2BlacklistMirror 读取接口对齐方案(XLOP-1100)

目的:统一 op-geth、xlayer-reth、contracts 三方对 L2BlacklistMirror 的读取接口。节点只依赖下面这一个 view 方法,不依赖合约存储布局。三方任一改动都要同步另外两方。

# 合约对外接口

节点只调用这一个只读方法:

```solidity
function getBlacklist(uint256 start, uint256 limit)
    external view returns (uint256 total, address[] addresses);
```

语义:

- total:名单里地址的总数量(固定值,与 start/limit 无关)。
- addresses:从下标 start 起、最多 limit 个地址;剩余不足 limit 时返回剩余部分;start >= total 时返回空数组。
- 纯只读,不改状态。
- 顺序在同一区块快照内稳定即可(同一份父状态读出的顺序一致);跨区块允许变化(节点每块重新整读)。

合约内部存储不限定,推荐用 OpenZeppelin EnumerableSet(数组+索引 mapping,add/remove/contains 均 O(1))。admin 写接口(add/remove/clear)由 contracts 仓定义,节点不调用、不做二次鉴权。

为什么是单方法:名单 ≤ 一页时节点只需 1 次 EVM 调用就能同时拿到 total 和全部地址;只有名单超过一页才翻页。

# 节点读取算法(op-geth / reth 必须一致)

每个区块,在进入交易循环前,从块首(父)状态读一次,构建内存快照:

1. 若 chain_id 不在启用集合 {195,1952,196} → 空快照,不调用。
2. 若 mirror 地址无 code(未部署)→ 空快照,no-op。
3. 调 getBlacklist(0, PAGE_SIZE),拿到 total 和第一页。
4. total == 0 → 空快照,no-op。
5. total > 上限 MAX_ENTRIES → 按失败策略处理(见下)。
6. 把 addresses 收进集合(跳过零地址);若 total > 已读数量,继续 getBlacklist(offset, PAGE_SIZE) 翻页,直到读满 total 或达上限。
7. 之后该块所有交易的判定都用这份内存快照,不再读状态、不再调合约。

入口关(mempool)同样用这份快照,在每次 pool reset(commit + reorg)时按上面算法刷新一次。

# 跨端一致性约束(任一处不一致都会分叉)

下列常量和行为,op-geth 与 xlayer-reth 必须逐字一致:

## 接口

同一个方法 getBlacklist(uint256,uint256) -> (uint256,address[]),函数选择器、入参、返回类型完全相同。

## 分页参数

PAGE_SIZE 两端取同一值(建议 1024)。每页 staticcall 的 gas 预算两端取同一值(建议 50_000_000)。
说明:页大小本身不改变最终集合,但与 gas 预算配合——若一端页太大导致 OOG、另一端不 OOG,会一端拿到空名单、一端拿到全量 → 分叉。故必须一致。

## 数量上限

MAX_ENTRIES 两端取同一值。op-geth 现为 1<<20(约 104 万),reth 现为 300000,必须统一成同一个数(建议沿用 PRD 工程上界 300000,或双方重新约定一个,只要相等)。

## 超上限行为

total > MAX_ENTRIES 时两端动作必须一致。建议两端都"判为异常,当空名单 + Error 日志",不要截断——截断会悄悄放行超出部分的黑名单地址(不安全),且对枚举顺序敏感、两端难保证砍得一样。

## 零地址

addresses 里若出现 address(0),两端都跳过(或在合约 add() 里直接禁止 0 地址,二选一,但两端要统一)。

## 失败策略

getBlacklist 调用失败 / 解码失败 → 两端都当空名单(该块黑名单失效)+ Error 日志。一个良构 mirror 不会失败;此策略只为保证两端在异常时仍一致(都关闭,不分叉)。

## 读取时机

必须读块首/父状态,不读块内 live state。保证 add 落入 block N 后从 N+1 生效,无块内 delta(FR-4 / FR-5)。

## import vs build 路径(已与 op-geth 现实现对齐,reth 必须照做)

- 出块(sequencer build)路径:命中名单的普通 L2 交易整笔 drop、移出 mempool。
- follower 验证/导入路径:不拦截普通 L2 交易(执行如常、跟随 sequencer);只拦截 L1->L2 deposit。
  理由:强行 fail 一笔已上链的 L2 tx 会留下不一致 post-state(nonce/gas 已回滚但 gas 已计),且易分叉;L2 拦截只由 sequencer 负责。
- deposit 命中(两路径一致):included-as-reverted,status=0,gasUsed=gasLimit,keep-mint、nonce+1、全额 gasLimit 计入区块。

注:此 import 路径行为偏离 PRD 字面("两端 follower 也拦 L2"),建议同步回写 PRD/TD,避免 reth 照字面实现成"follower 也拦 L2"导致分叉。

# devnet 部署信息(chain 195)

- mirror 确定性地址:0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f
  由专用部署账户(test 助记词 index 19,EOA 0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199)在 L2 的 nonce-0 部署得到,每次重建 devnet 地址不变。
- op-geth params/config_xlayer.go 与 xlayer-reth mirror.rs 的 195 槽位都要硬编码这个地址并重建镜像,节点才会真正读取该合约;1952/196 本期不动。
- devnet 侧已具备:demo 合约 + 开关 BLACKLIST_DEMO_ENABLED + 部署脚本(待按本方案把合约接口改成 getBlacklist 后生效)。

# 验收要点

- 共享对抗测试向量(两仓 CI 各自断言):被拦 deposit 的 receipt 逐字段一致;子调用回滚后的触达不计;名单空/未部署时 state root 与基线一致。
- 名单 < 一页时,节点单块单次 EVM 调用即拿全量。
