<!-- prd-plan
pr_type: tech-improvement
team: X Layer
prd_score: 86
status: valid
generated_at: 2026-06-11T11:26:28
isc_total: 18
isc_anti: 4
original_score: 86
decision_log:
  - "chose tech-improvement: devnet 工具链/测试环境改造,非业务功能、非生产 bug"
  - "ISC grouped by 4 phases mapped to actual work: 编译期地址对齐 → 合约+脚本(flag off) → 开关激活拦截闭环 → 跨客户端一致性+文档,每个 Phase 可独立验证回滚"
  - "ISC-A focused on no-op 默认快路径 / 不动 1952&196 / 地址不一致必须 fail-fast / 禁止非可枚举布局: 这四条对应本改造最大的分叉与回归风险面"
  - "确定性地址改用 test 助记词 19 号账户而非 f39F(#0): f39F 的 nonce-0/1 合约地址已被 devnet 占用(见 .env),专用账户保证 nonce=0"
-->

# devnet 黑名单合约 demo 闭环(chain 195)

## Document Control

| 序号 | 字段 | 值 |
|:--:|---|---|
| 1 | Version | v1 |
| 2 | Status | Draft |
| 3 | Author | 朱建国 Barry Zhu |
| 4 | PR Type | `tech-improvement` |
| 5 | Owner Team | X Layer |
| 6 | Last Updated | 2026-06-11T11:26:28 |

## TL; DR

现状:XLOP-1100 黑名单功能在 xlayer-reth 与 op-geth 各有首版实现,但 mirror 合约地址是编译期硬编码占位值,两端对不上(reth 三链共用 `0x…B1AC`、op-geth 195 用 `0x…blacklist0195`),且 devnet 上没有可一键部署的 mirror 合约,无法端到端验证拦截。

改造:在 devnet 引入一个确定性地址的 `L2BlacklistMirror` demo 合约 + `.env` 开关 + 新部署脚本,把"部署合约 → 激活拦截 → 验证跨客户端一致"在 chain 195 上闭环;默认开关关闭,`make run` 行为不变。

预期:开关打开后,一条 `make run` 起的最小环境里即可复现"加黑 → 拦截 → 解黑 → 放行"全链路,且 reth(seq)/geth(rpc) 对同一被拦截交易 state root 一致。

## Domain Sketch · 领域草图

| 实体 | 当前状态 | 目标状态 | 归属模块 |
|---|---|---|---|
| L2BlacklistMirror 合约 | 仅外部 contracts 仓规划,devnet 无 stub | devnet 内最小 demo stub,可枚举 `address[]` | xlayer-toolkit/devnet/contracts |
| mirror 地址(chain 195) | reth=`0x…B1AC`(三链共用)、geth=`0x…blacklist0195` | 两端统一为确定性地址 `0x73511669…F31f` | xlayer-reth / op-geth |
| 确定性部署账户 | 无,易与 f39F 冲突 | test 助记词 19 号 `0x8626…1199`,专用、nonce 必为 0 | devnet 部署脚本 |
| devnet 启动流程 | `0-all.sh` 链至 `4-op-start-service` | 末尾追加可选的 `7-deploy-blacklist.sh` | xlayer-toolkit/devnet |
| 开关配置 | 无 | `BLACKLIST_DEMO_ENABLED` 等三个 `.env` 键 | xlayer-toolkit/devnet/example.env |
| 块首名单快照读取 | 两端均按 Solidity 动态数组布局读 slot 0 | demo 合约 storage 严格对齐该布局 | reth reader.rs / op-geth blacklist_xlayer.go |

---

## 1. Background & Goals · 背景与目标 🔴

**现状与问题**:

- XLOP-1100 在两个出块客户端有首版黑名单实现,但 `L2BlacklistMirror` 真实地址待外部 contracts 仓提供(Blocking open item B-1),当前是占位值。
- 两端占位值形态不一致:xlayer-reth `crates/builder/src/blacklist/mirror.rs` 三链共用一个 `BLACKLIST_MIRROR_PLACEHOLDER`;op-geth `params/config_xlayer.go` 每链一个不同占位地址。在同一条链上两端去不同地址读名单——目前因都读空 storage 而碰巧一致,一旦填真值即分叉(违反 FR-5 / G-2)。
- devnet 上没有现成可部署的 mirror stub,黑名单拦截无法端到端验证。

**改进动因**:黑名单功能要在 devnet 做功能与跨客户端一致性验证,必须先有一个"地址确定、可重复部署、两端一致"的 mirror 合约。这是后续所有 FR-1~FR-7 验收的前置条件。

**目标(可量化)**:

- 一条 `make run`(开关打开)即可在 chain 195 复现"加黑 → 拦截 → 解黑 → 放行"全链路,无需手工算地址或手工部署。
- mirror 合约地址在每次重建 devnet 后保持恒定(确定性 = `0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f`)。
- 两客户端对 chain 195 的 mirror 地址逐字节一致;对同一被拦截交易 state root 一致,不分叉。

**Non-Goals**:

- 不处理 1952 / 196 两条链的 mirror 地址与行为(本期只动 195;两端各自占位保留)。
- 不实现风控侧名单生成/下发,不实现 L1 admin Registry 经 OptimismPortal 下发。
- 不交付生产级合约(权限治理、审计由外部 contracts 仓负责);本期仅 devnet demo stub。
- 不改 reth/op-reth/op-node/OP 协议上游。

---

## 2. Technical Solution · 技术方案 🔴

**现状架构 → 目标架构**:

- 现状:节点编译期硬编码占位 mirror 地址(两端不一致)→ devnet 无 mirror 合约 → 块首读到空 storage → 全程 no-op,拦截无法触发。
- 目标:两端编译期常量对齐为同一确定性地址(chain 195)→ devnet 脚本按开关用专用账户部署 demo mirror 到同一地址 → 块首读到名单 → 拦截生效;开关关闭则回到 no-op,行为同改造前。

**关键设计决策**:

| 序号 | 决策点 | 选项对比 | 决策 | 理由 |
|:--:|---|---|---|---|
| 1 | 地址确定性方案 | A: CREATE+固定 nonce / B: CREATE2 | A | 用专用账户保证 nonce=0,实现简单;devnet 无需 CREATE2 的顺序无关性 |
| 2 | 部署账户 | f39F(#0) / 专用 #19 | 专用 #19 | f39F 的 nonce-0/1 合约地址已被 devnet 占用(.env 可证),专用账户才能锁定 nonce=0 |
| 3 | 合约 storage 布局 | `mapping(address=>bool)` / 可枚举 `address[]` | `address[]`@slot0 | 两端 reader 只认可枚举布局,mapping 会被判 MalformedLayout 拒绝 |
| 4 | 开关粒度 | 改 reth/geth CLI / devnet `.env` 开关 | `.env` 开关 | FR-6 规定节点无 CLI 开关;开关只控制 devnet 运行期是否部署+激活,不碰节点参数 |
| 5 | reth 地址映射形态 | 维持三链共用 / 拆成按链返回 | 按链返回 | 顺带修掉跨客户端不一致隐患,195 闭环,1952/196 保留占位 |

**数据 / Schema / 配置变更**:

- demo 合约 `L2BlacklistMirror.sol`:第一个状态变量必须是 `address[]`(占 slot 0),提供 `add/remove/clear/entries`;storage 布局 = slot0 存长度、元素 i 在 `keccak256(0)+i` 低 20 字节(与两端 reader 逐字对齐)。
- `.env` / `example.env` 新增:`BLACKLIST_DEMO_ENABLED`(默认 false)、`BLACKLIST_DEPLOYER_INDEX=19`、`BLACKLIST_MIRROR_ADDRESS=0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f`。
- 编译期常量:op-geth `params/config_xlayer.go` 195 槽位、xlayer-reth `mirror.rs` 改为按 chain_id 返回(195 用新地址)。改常量需 `init.sh` 重建镜像才生效。
- 回滚路径:`BLACKLIST_DEMO_ENABLED=false`(默认)即不部署、不激活,全链 no-op。

**备选方案对比**:

| 序号 | 方案 | 优 | 劣 | 取舍 |
|:--:|---|---|---|---|
| 1 | CREATE2 部署 | 顺序无关、最稳 | 需走 factory、合约部署更复杂 | 弃,devnet 不需要 |
| 2 | 改节点 CLI 加运行期地址参数 | 不用重建镜像 | 违反 FR-6(节点无 CLI 开关) | 弃 |

---

## 3. Impact Scope · 影响范围 🔴

| 序号 | 服务 / 模块 | 变更类型 | 兼容性 | 责任人 |
|:--:|---|---|---|---|
| 1 | xlayer-toolkit/devnet/contracts/L2BlacklistMirror.sol | 新增 | 向后兼容 | 朱建国 |
| 2 | xlayer-toolkit/devnet/7-deploy-blacklist.sh | 新增 | 向后兼容(默认 no-op) | 朱建国 |
| 3 | xlayer-toolkit/devnet/0-all.sh | 改造(末尾追加调用) | 向后兼容 | 朱建国 |
| 4 | xlayer-toolkit/devnet/example.env | 改造(新增 3 键) | 向后兼容(默认 off) | 朱建国 |
| 5 | op-geth params/config_xlayer.go | 改造(195 槽位地址) | 仅影响 chain 195 | 朱建国 |
| 6 | xlayer-reth crates/builder/src/blacklist/mirror.rs | 改造(按链返回地址) | 仅影响 chain 195 | 朱建国 |

**调用方 / 客户端影响**:改两端编译期常量后必须 `init.sh` 重建 op-geth / xlayer-reth 镜像,常量才进二进制;不重建则地址仍是旧占位,部署的 mirror 读不到。

**回滚预案**:`BLACKLIST_DEMO_ENABLED=false`(默认值)→ 脚本立即退出,不部署合约,全链行为等同未引入本功能。常量改动若需回退,git revert 两端 commit 后重建镜像。预计回滚耗时 = 一次 `init.sh` 重建时间。

**灰度策略**:仅限 devnet(chain 195),不涉及测试网/主网灰度;1952/196 不在本期范围。

---

## 4. Acceptance Criteria · ISC 验收 + 阶段拆解 🔴

> 每条 ISC = 原子化、可验证的最终状态。门槛:≥16 ISC + ≥3 ISC-A。每个 Phase 可独立验证、独立回滚。

### Phase 0 · 编译期地址对齐

- [ ] ISC-1: 确定性 mirror 地址 = test 助记词 19 号账户(`0x8626…1199`)nonce-0 推导值 `0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f`,且不与 devnet 现用任何地址冲突  
  → 验证: `cast compute-address 0x8626…1199 --nonce 0` 得该值 + grep `.env`/`scripts` 无冲突
- [ ] ISC-2: op-geth `params/config_xlayer.go` 195 槽位地址 = `0x7351…F31f`  
  → 触及: `params/config_xlayer.go` | 验证: `go test ./params -run Blacklist` 通过
- [ ] ISC-3: xlayer-reth `mirror.rs` 按 chain_id 返回地址,195 = `0x7351…F31f`(1952/196 保留各自占位,不再三链共用)  
  → 触及: `crates/builder/src/blacklist/mirror.rs` | 验证: `cargo test -p ... blacklist::mirror`
- [ ] ISC-4: 两客户端对 chain_id=195 返回的 mirror 地址逐字节相等  
  → 验证: 两端单测各断言该字面量 + 常量注释互相回指
- [ ] ISC-5: 重建后的 op-geth 与 xlayer-reth 镜像内含新常量  
  → 触及: `devnet/init.sh` | 验证: `init.sh` 成功产出镜像,启动节点查 195 行为非 no-op

### Phase 1 · demo 合约 + 部署脚本(开关默认 off)

- [ ] ISC-6: `L2BlacklistMirror.sol` 以 `address[]` 作为 slot 0 第一个状态变量,提供 `add/remove/clear/entries`  
  → 触及: `devnet/contracts/L2BlacklistMirror.sol` | 验证: `forge build` + storage layout 显示数组在 slot 0
- [ ] ISC-7: 合约 storage 布局与两端 reader 一致(slot0=length、元素在 `keccak256(0)+i` 低 20 字节)  
  → 验证: 部署后 `cast storage` 读取与 reader 解析结果一致
- [ ] ISC-8: `example.env` 新增 `BLACKLIST_DEMO_ENABLED`(默认 false)、`BLACKLIST_DEPLOYER_INDEX=19`、`BLACKLIST_MIRROR_ADDRESS=0x7351…F31f`  
  → 触及: `devnet/example.env` | 验证: grep 命中三键且默认 false
- [ ] ISC-9: `7-deploy-blacklist.sh` 在 `BLACKLIST_DEMO_ENABLED!=true` 时立即 no-op 退出(退出码 0)  
  → 触及: `devnet/7-deploy-blacklist.sh` | 验证: flag=false 跑脚本,无部署、退出码 0
- [ ] ISC-10: `0-all.sh` 在 `4-op-start-service.sh` 之后调用 `7-deploy-blacklist.sh`  
  → 触及: `devnet/0-all.sh` | 验证: 脚本调用顺序 grep
- [ ] ISC-11: `make run`(默认 flag off)行为与改造前一致,不部署任何 mirror  
  → 验证: `make run` 后 `cast code 0x7351…F31f` 返回 `0x`

### Phase 2 · 开关激活与拦截闭环(flag on)

- [ ] ISC-12: flag=on 时脚本用 19 号账户部署 mirror,实际部署地址 == `0x7351…F31f`  
  → 触及: `devnet/7-deploy-blacklist.sh` | 验证: 脚本断言部署地址相等,否则失败退出
- [ ] ISC-13: 部署后 `eth_getCode(0x7351…F31f)` 非空  
  → 验证: `cast code` 非 `0x`
- [ ] ISC-14: 脚本 `add()` 一个 demo 地址后,下一区块两端块首快照含该地址  
  → 验证: metrics `xlayer_blacklist_cache_size` ≥ 1 或节点日志
- [ ] ISC-15: 被加黑地址发起转出交易被拦截(入口关拒绝或执行关回滚)  
  → 验证: `cast send` 返回 JSON-RPC `-32000` / 或交易不上链
- [ ] ISC-16: `remove`/`clear` 后该地址转账恢复正常上链  
  → 验证: 下一区块后 `cast send` 成功上链(status=1)

### Phase 3 · 跨客户端一致性 + 文档

- [ ] ISC-17: 同一被拦截交易在 reth(seq)与 geth(rpc)两端 state root 一致  
  → 验证: 两节点 `eth_getBlockByNumber` 的 `stateRoot` 相等
- [ ] ISC-18: devnet README/脚本注释记录开关用法、确定性地址来源、nonce-0 前提  
  → 触及: `devnet/README.md` | 验证: 文档含 `BLACKLIST_DEMO_ENABLED` 说明与地址推导

### 里程碑

| 序号 | 里程碑 | 涵盖 ISC | 时间窗 |
|:--:|---|---|---|
| 1 | M1 地址对齐+重建 | ISC-1..5, ISC-A-2 | (待补充) |
| 2 | M2 合约+脚本就绪(off) | ISC-6..11, ISC-A-1, ISC-A-4 | (待补充) |
| 3 | M3 拦截闭环(on) | ISC-12..16, ISC-A-3 | (待补充) |
| 4 | M4 一致性+文档 | ISC-17..18 | (待补充) |

---

## 5. Safeguards · 红线约束 (ISC-A) 🔴

> 必须 NOT 发生的事——显式声明红线。

- [ ] ISC-A-1: 开关关闭(默认)时全链行为与未引入本功能逐字节一致,state root 不变(no-op 快路径不被破坏)
- [ ] ISC-A-2: 不改动 1952 / 196 两条链的 mirror 地址与行为(本期只动 195)
- [ ] ISC-A-3: 实际部署地址与编译期常量不一致时脚本必须 fail-fast 退出,绝不静默部署到错误地址(防分叉)
- [ ] ISC-A-4: 合约 storage 不得使用 `mapping(address=>bool)` 等非可枚举布局(会被 reader 判 MalformedLayout)

---

## 6. Risk Assessment · 风险评估 🟡

| 序号 | 类型 | 风险 | 概率 | 影响 | 应对 |
|:--:|---|---|---|---|---|
| 1 | 确定性 | 19 号账户在 L2 部署前已发过交易,nonce≠0,地址漂移 | 低 | 高 | 脚本部署前断言地址相等,不等即 fail;账户专用不复用 |
| 2 | 一致性 | 改了一端常量、漏改另一端或漏重建镜像 → 分叉 | 中 | 高 | ISC-4 两端互断言;ISC-5 强制重建;Phase 0 先于部署 |
| 3 | 布局 | demo 合约 storage 与 reader 布局不符 → 读不到/MalformedLayout | 中 | 中 | ISC-7 部署后 cast storage 实测对齐;ISC-A-4 红线 |
| 4 | 预置余额 | genesis 未给 19 号账户预置 L2 余额,无 gas 部署 | 低 | 中 | 脚本先从 rich 账户给其转 gas(不改其 nonce)再部署 |

---

## 7. 关联资料

- Epic: https://okcoin.atlassian.net/browse/XLOP-1100
- PRD(合并规格): https://okg-block.sg.larksuite.com/docx/JczldD5I7ox2U6xvJp9ldnFYgXb
- 相关代码: xlayer-reth `crates/builder/src/blacklist/`、op-geth `core/blacklist_xlayer*.go` / `params/config_xlayer.go`
