测试计划:devnet 黑名单跨客户端功能验证(XLOP-1100,op-geth + xlayer-reth)

# 测试目标

在 devnet(chain 195)上同时验证 op-geth 与 xlayer-reth 两个客户端的黑名单功能正确性,以及跨端 / 多节点 / 长跑场景下的一致性。重点覆盖:

- **单端基线**:每个客户端独立 build 时,入口关 + 执行关 + 读 API + 时序 + 重启 全部正确
- **L1 forced inclusion**:deposit 命中名单时 included-as-reverted (status=0、gasUsed=gasLimit);跨端 receipt 字节一致
- **跨端 anti-fork**:同一区块在 op-geth seq 与 reth follower 上算出的 state/receipts root 必须 byte-identical;reorg、proxy upgrade、fail-open 路径两端语义对齐
- **多节点 HA**:conductor 切主、跨客户端 leader 轮换、多 rpc 并发 import、mempool 跨端一致
- **长跑稳态**:高负载 + churn(高频 add/remove)+ 切主 下持续无分叉、无 bad block
- **对抗性**:恶意 sequencer 包黑名单 tx → follower 必须拒块(P0 anti-fork)
- **reth-only 特性**:bd6dc9c 的 mempool 主动驱逐;flashblocks 预确认面行为
- **黑名单 × gasless 交互**:同账户同时在两个白名单/黑名单中的判定优先级

# 客户端 × 角色词汇

每个 case 的"复测范围"列遵循以下词汇,直接表达"几个客户端×角色组合 = 几组"(实际工作量):

| 写法 | 含义 |
|---|---|
| `reth-seq + geth-seq(2组)` | 两个客户端各做 seq 角色,跑两遍 |
| `reth-rpc + geth-rpc(2组)` | 两客户端各做 rpc 角色 |
| `异类双向 reth-seq×geth-rpc + geth-seq×reth-rpc(2组)` | 跨端双向(seq=A、rpc=B 和 反过来)|
| `reth-seq + geth-seq + reth-rpc + geth-rpc(4组)` | 4 个角色全跑 |
| `任一客户端(1组,读合约)` | 合约纯读,跑一次即可 |
| `flag-关节点 reth+geth(2组)` | 关 flag 的两端 |
| `档二(多实例选主)` | conductor + 多实例独立端口 |
| `档二(多节点 P2P)` | 多 rpc 并发 |
| `档二(混选集群 soak)` | 长跑稳态 |

# 档位定义

| 档位 | 覆盖类别 | 开箱可跑 | 搭建要求 |
|---|---|---|---|
| 档一 单 EL + 异类 RPC | A B C D E F G H I + 部分 J/K | 是 | 改 .env 的 `SEQ_TYPE` / `RPC_TYPE` 即可 |
| 档二 conductor 混选 | CX 多节点、CXR (reorg)、CHURN、ST (soak) | 否 | docker-compose 改给 reth/geth 实例独立端口;`CONDUCTOR_ENABLED=true`;4 个 seq 纳入同一 raft |

档二需要额外搭建;档一只动 .env 即可。本计划默认先在档一完成全部档一 case,再切档二跑剩下的。

# 环境准备

## 前置条件

1. **op-geth** 切到 `xl/blacklist_latest`,含 `getBlacklist` ABI + 195 地址硬编码 `0x73511669…F31f` + 最新 `EvaluateDeposit` 跳 check① 的 commit(509447e84+),未提交改动需落地后镜像重建。
2. **xlayer-reth** 切到 `xl/blacklist_latest`,含 5 个相关 commit(`8dc76e4 feat / b93718c sequencer deposit skip check① / 9280dc9 align placeholders / bd6dc9c pool 主动驱逐 / 790ba45 archive`)。
3. 两个客户端镜像都须重建(`SKIP_OP_GETH_BUILD=false` + `SKIP_OP_RETH_BUILD=false`),首次跑各 5-10 分钟。

## 启动方式

```bash
cd "$(git rev-parse --show-toplevel)/devnet"
./clean.sh          # example.env -> .env(若 .env 已存在不覆盖,需手动同步下列项)
./init.sh           # 重建镜像
./0-all.sh          # 起 L1 + 合约 + L2,末尾自动跑 7-deploy-blacklist.sh
```

停止 / 日志:

```bash
docker compose ps
docker compose logs -f op-${SEQ_TYPE}-seq      # seq RPC 8123;rpc 节点 RPC 8124
docker compose down
```

L2 RPC:seq `http://localhost:8123`、rpc `http://localhost:8124`(注意:**不是 9123**;之前 PRD 写错)
Metrics:`http://localhost:9092/debug/metrics/prometheus`(op-geth)、`http://localhost:9092/...`(reth 同样路径,镜像端口要查 docker-compose.yml)

## 配置变更(.env)— 档一

按你要测的拓扑切 `SEQ_TYPE` / `RPC_TYPE`:

| 配置项 | T1 (geth+geth) | T2 (reth+reth) | T3 (geth+reth) | T4 (reth+geth) |
|---|---|---|---|---|
| SEQ_TYPE | geth | reth | geth | reth |
| RPC_TYPE | geth | reth | reth | geth |
| FLASHBLOCK_ENABLED | false | true(reth 支持)| 任选 | 任选 |
| SKIP_OP_GETH_BUILD | false 首次 | true | false 首次 | true(已建)|
| SKIP_OP_RETH_BUILD | true | false 首次 | true(已建)| false 首次 |
| CONDUCTOR_ENABLED | false | false | false | false |
| LAUNCH_RPC_NODE | true | true | true | true |
| CHAIN_ID | 195 | 195 | 195 | 195 |
| BLACKLIST_DEMO_ENABLED | true | true | true | true |
| BLACKLIST_DEPLOYER_INDEX | 19 | 19 | 19 | 19 |
| BLACKLIST_MIRROR_ADDRESS | `0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f` | (同) | (同) | (同) |

## 配置变更(.env)— 档二(多实例 conductor)

```env
CONDUCTOR_ENABLED=true
LAUNCH_RPC_NODE=true
LAUNCH_RPC_NODE2=true
# 还需要改 docker-compose.yml 给 reth/geth 实例独立端口
# 参考 gasless 测试计划的"档二"搭建说明:把 4 个 seq 纳入同一 raft,端口分开
```

注:`.env` 直接改(`clean.sh` 不覆盖已存在的 `.env`);若 `.env` 缺 `BLACKLIST_DEPLOYER_INDEX` 或 `BLACKLIST_MIRROR_ADDRESS`,从 example.env 同步过来(否则 7-deploy-blacklist.sh 第一次跑会 `invalid value '' for '<WHO>'`)。

## 测试用账户(devnet 标准助记词 test…junk)

```bash
MN="test test test test test test test test test test test junk"
# 受害账户(被加黑、有余额、可签名)— 选未被 devnet 占用的高位 index,如 6
VICTIM=$(cast wallet address --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/6")
VKEY()  { cast wallet private-key --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/6"; }
# 第二个受害账户(C8 多命中用),如 index 9
VICTIM2=$(cast wallet address --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/9")
# 正常对照账户(不加黑),如 index 7
CLEAN=$(cast wallet address --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/7")
MIRROR=0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f
RPC=http://localhost:8123
# L2 真富户 = RICH_L1_PRIVATE_KEY(见 .env,地址 0x14dC…9955 = idx7,genesis 10000 ETH)。
# 注意:CLEAN 也用了 idx7,与 RICH 同一账户——CLEAN 仅作收款方,撞号无害。
# DEPLOYER(DEPLOYER_PRIVATE_KEY / DEPLOYER_ADDRESS,= anvil#0/f39F)在 L2 上余额很少,
# 由公共准备段从 RICH 充值后再当 sender。
```

部署脚本默认 seed 的是 `0x00…AA`(仅证明合约可写),功能测试请用上面可签名的 VICTIM。

## 临时代码改动

无需临时改日志:入口关错误、执行关 WARN 日志均为默认可见级别,metrics 默认注册。
（若 metrics HTTP 端点未开,需确认 op-geth 启动带 `--metrics`;否则本计划以 docker 日志为主证据,metrics 为辅。）

# 证据链

| 证据 | 位置 | 级别 | 内容 | 默认可见 |
|---|---|---|---|---|
| 入口关拒绝错误 | core/error.go:158 | RPC error | `xlayer-blacklist: sender or recipient is on the blacklist`(JSON-RPC -32000) | 是 |
| 执行关拦截日志 | core/blacklist_gate_xlayer.go:253 | Warn | `xlayer-blacklist: tx intercepted at exec gate` + hash/category/deposit | 是 |
| 出块 drop 日志 | miner/worker.go | — | 普通 L2 命中被 drop(出块路径) | 是 |
| metric cache_size | core/blacklist_metrics_xlayer.go:15 | Prometheus | `xlayer_blacklist_cache_size` 当前名单快照大小 | 需 --metrics |
| metric pool_rejected | :19 | Prometheus | `xlayer_blacklist_pool_rejected_total` | 需 --metrics |
| metric exec_revert | :27 | Prometheus | `xlayer_blacklist_exec_revert_total{hook=call|log|selfdestruct|eth_balance}` | 需 --metrics |
| metric snapshot_read | :23 | Prometheus | `xlayer_blacklist_snapshot_read_duration_seconds` | 需 --metrics |

# 测试矩阵(唯一权威:序号 | 分类 | case | 复测范围 | 预期 | 实际)

本表是用例规格的唯一权威来源,结构固定。复测时只更新「实际」列(标 PASS,或 TODO 并写明原因),不要改动序号/分类/case/复测范围/预期。下方「验证步骤」为各类 case 的命令参考。

「实际」列:每个 case 跑完后填 `✅ PASS T<n> (简述结果 + 证据子目录)`,例如 `✅ PASS T3 (cast send drop, VICTIM 余额 0→0, devnet/test-results/<run-ts>/Cn.md)`。失败填 `❌ FAIL` + 现象;暂跳填 `⏸ DEFER` + 原因。

证据目录结构建议:`devnet/test-results/blacklist-XLOP-1100-<拓扑代号>-<timestamp>/Cn.md` —— 每个 case 一个 .md,含 pre-state / 命令 / 输出 / post-state / 结论。

**Anti-fork P0 强调段** —— 以下三条任一不通过即 P0 阻塞上线(客户端不一致 = 分叉):CX5、CX6、CX10。

| 序号 | 分类 | case | 复测范围 | 预期 | 实际 |
|---|---|---|---|---|---|
| 1 | A 开关/基线 | C1 flag=off baseline | reth-seq + geth-seq(2组) | 全链 no-op、metrics 全 0、无 intercept 日志 | ⏳ pending |
| 2 | A 开关/基线 | C2 flag=on 空名单 | reth-seq + geth-seq(2组) | total=0、cache_size=0、普通 tx 成功 | ⏳ pending |
| 3 | A 开关/基线 | C3 mirror 未部署短路 | reth-seq + geth-seq(2组) | 同 C1 | ⏳ pending |
| 4 | B 入口关 | C4 入口关 from | reth-seq + geth-seq(2组) | -32000、nonce 不增、pool_rejected+1 | ⏳ pending |
| 5 | B 入口关 | C5 入口关 to | reth-seq + geth-seq(2组) | to 命中拒,counter +1 | ⏳ pending |
| 6 | B 入口关 | C6 mempool 池删除 三段 | reth-seq + geth-seq(2组) | 三段行为跨客户端一致 | ⏳ pending |
| 7 | C 执行关 | C7 内层 CALL drop (check③ balance) | reth-seq + geth-seq(2组) | drop、VICTIM 余额不变、exec_revert+1 | ⏳ pending |
| 8 | C 执行关 | C8 多命中 / event from==to | reth-seq + geth-seq(2组) | 单次 drop、counter 不重复 | ⏳ pending |
| 9 | C 执行关 | C8-ext 多加黑账户互发 | reth-seq + geth-seq(2组) | 入口关 from 优先,counter 不重复 | ⏳ pending |
| 10 | D 执行关·event | C9 ERC20 Transfer event | reth-seq + geth-seq(2组) | hook=log drop、余额不变 | ⏳ pending |
| 11 | D 执行关·event | C10 授权变体 | 覆盖 | 同 C9 | ⏳ pending |
| 12 | D 执行关·event | C11 ERC721 | reth-seq + geth-seq | hook=log + drop | ⏳ pending |
| 13 | D 执行关·event | C12 ERC1155 | reth-seq + geth-seq(2组) | hook=log + drop | ⏳ pending |
| 14 | D 执行关·event | C13 精度负向 | reth-seq + geth-seq(2组) | value=0 仍拦、noise 不拦 | ⏳ pending |
| 15 | D 执行关·event | C14 协议变体 | 覆盖 | 同 C9 | ⏳ pending |
| 16 | E 执行关·balance | C15 selfdestruct | reth-seq + geth-seq(2组) | drop、VICTIM ETH 不变 | ⏳ pending |
| 17 | E 执行关·balance | C16 committed-effect | reth-seq + geth-seq(2组) | 不误拦 | ⏳ pending |
| 18 | E 执行关·balance | C17 coinbase=VICTIM | NA | — | ⏳ pending |
| 19 | F L1↔L2 | C18 L1 deposit pure-CALL-touch | reth-seq + geth-seq(2组) + 异类双向(2组) | 跨端 byte-identical | ⏳ pending |
| 20 | F L1↔L2 | C19 deposit + Transfer event | reth-seq + geth-seq(2组) + 异类双向(2组) | status=0、gasUsed≈gasLimit、logs=0 | ⏳ pending |
| 21 | F L1↔L2 | C20 deposit aliasing | NA | — | ⏳ pending |
| 22 | F L1↔L2 | C21 L2→L1 提款 initiateWithdrawal | NA | — | ⏳ pending |
| 23 | F L1↔L2 | CXW1-helper L2 inner-touch | reth-seq + geth-seq(2组) + 异类双向(2组) | 执行关拦,跨端一致 | ⏳ pending |
| 24 | F L1↔L2 | C22 系统 deposit 豁免 | reth-seq + geth-seq(2组) + 异类双向(2组) | from=0xdead...0001 status=0x1 | ⏳ pending |
| 25 | G 读取接口 | C23 分页 >1024 | reth-seq + geth-seq(2组) + 异类双向(2组) | cache==1025、第 2 页可拦 | ⏳ pending |
| 26 | G 读取接口 | C24 写入校验 | reth-seq + geth-seq(2组) | add(0x0) revert + 去重 | ⏳ pending |
| 27 | G 读取接口 | C25 边界 | 任一客户端(1组,读合约) | 6 个边界符合契约 | ⏳ pending |
| 28 | H 时序 | C26 remove 恢复 | reth-seq + geth-seq(2组) | VICTIM 发 tx status=1 | ⏳ pending |
| 29 | H 时序 | C27 时序对称 | reth-seq + geth-seq(2组) | M+1 放行 | ⏳ pending |
| 30 | I 负向约束 | C28 FR-7 负向 | reth-rpc + geth-rpc(2组) | 无 RPC + message 固定 + metrics 拆分 | ⏳ pending |
| 31 | I 负向约束 | C29 非法 CLI | reth + geth 二进制(2组) | exit≠0 | ⏳ pending |
| 32 | J 共识/同步 | C30 跨端 state/receipts root | 异类双向(2组) | 0 divergent | ⏳ pending |
| 33 | J 共识/同步 | C31 RPC 从 0 同步 | BLOCKED | — | ⏳ pending |
| 34 | J 共识/同步 | C32 节点重启 | 4 组 | 重启续效 | ⏳ pending |
| 35 | K 生命周期 | C33 激活过渡三阶段 | reth-seq + geth-seq(2组) + 异类双向(2组) | 跨端三阶段 0 divergent | ⏳ pending |
| 36 | K 生命周期 | C34 ABI proxy 升级 | reth-seq + geth-seq(2组) + 异类双向(2组) | impl 切换无感 | ⏳ pending |
| 37 | CX 跨端 anti-fork | CX5 恶意 seq 包黑名单 | 异类双向(2组) | follower 拒块 | ⏳ pending |
| 38 | CX 跨端 anti-fork | CX6 恶意 seq 漏 deposit | 异类双向(2组) | follower 拒块 | ⏳ pending |
| 39 | CX 跨端 anti-fork | CX10 fail-open parity | 异类双向(2组) | 两端 fail-open | ⏳ pending |
| 40 | CX reth-only | CX11 reth pool 主动驱逐 | reth-seq(1组) | reth 主动删 | ⏳ pending |
| 41 | CX reth-only | CX7 flashblocks pre-confirm | flashblock(2组) | 预确认面拦截 | ⏳ pending |
| 42 | CX 多节点 | CX3 mirror snapshot 跨端 read parity | 异类双向(2组) | hash 一致 | ⏳ pending |
| 43 | CX 多节点 | CX8 conductor handover mid-add | 档二 | 切主后名单延续 | ⏳ pending |
| 44 | CX 多节点 | CX13 multi-rpc 并发 import | 档二 | 并发 import 一致 | ⏳ pending |
| 45 | CX 多节点 | CX14 混合 seq pool 一致 | 档二 | 行为等价 | ⏳ pending |
| 46 | CX 多节点 | CX9 proxy upgrade in mixed topology | 异类双向(2组) | 跨端无延迟分叉 | ⏳ pending |
| 47 | CX reorg | CXR1 reorg 后快照重建 | 档二 (leader kill) | 重建一致 | ⏳ pending |
| 48 | CX churn | CXW1 toggle 高频翻转 | 档二 | 三节点 stateRoot 一致 | ⏳ pending |
| 49 | CX churn | CXW2 batch churn | 档二 | 同上 | ⏳ pending |
| 50 | CX churn | CXW3 churn 跨切主 | 档二 | 同上 | ⏳ pending |
| 51 | CX 交互 | CXG1 黑名单 × gasless 交互 | reth-seq + geth-seq(2组) | 入口关优先 | ⏳ pending |
| 52 | CX soak | ST1 5min soak | 档二(混选集群) | 0 div + no bad block | ⏳ pending |
| 53 | CX soak | ST2 15min soak | 档二 | 同上 | ⏳ pending |
| 54 | CX soak | ST3 30min soak | 档二 | 同上 | ⏳ pending |

汇总:**54 行**,其中:
- 已知 BLOCKED:C31(devnet 工具链限制,需 IT 环境)
- 已知 NA:C17(OP Stack 无 miner coinbase)、C20(EOA 不 aliasing)、C21(L2 端 withdrawal 仅 emit event)

# 公共准备(fixtures,所有 case 前执行一次)

辅助合约是通用测试 mock(与黑名单无关,任何 devnet 测试可复用),落成真实文件、零依赖、已编译验证:
`devnet/contracts/testkit/src/Mocks.sol` —— 含 `ValueForwarder` / `MockERC20` / `MockERC1155` / `SelfDestructor` / `CallSwallower`。非生产合约,`out/` 已 gitignore。

执行顺序:devnet 起好(seq+rpc)且 mirror 已部署后,先跑下面这一段,把工具合约部署好、账户充值好,导出后续 case 用的变量。这样消除 case 之间的部署顺序依赖(任何 case 不再"用到还没部署的合约")。

```bash
# DEPLOYER(anvil #0 / f39F)不是 L2 富户(genesis 上仅 ~100 ETH 甚至 0),而后面所有
# deploy/send 都用 DEPLOYER 签名。先用 L2 真富户 RICH_L1_PRIVATE_KEY
# (地址 0x14dC…9955 = idx7,见 .env)给 DEPLOYER 充足额,放在任何 DEPLOYER 操作之前。
cast send --rpc-url $RPC --private-key $RICH_L1_PRIVATE_KEY --value 1000ether $DEPLOYER_ADDRESS

TESTKIT=contracts/testkit
DEPLOY() { cd $TESTKIT && forge create "src/Mocks.sol:$1" --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast --json | jq -r .deployedTo; cd - >/dev/null; }

FWD=$(DEPLOY ValueForwarder)   # C7、C17
TOK=$(DEPLOY MockERC20)        # C8、C9、C13、C16
T1155=$(DEPLOY MockERC1155)    # C12
DES=$(DEPLOY SelfDestructor)   # C15
SW=$(DEPLOY CallSwallower)     # C16
echo "FWD=$FWD TOK=$TOK T1155=$T1155 DES=$DES SW=$SW"

# 账户充值(被加黑账户也要有余额,才能验"发 tx 被拦"而非"余额不足")
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 5ether $VICTIM
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 5ether $VICTIM2
# 给 token:VICTIM 持币、并授权一个非名单 spender(DEPLOYER)走 transferFrom
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "mint(address,uint256)" $VICTIM 1000
cast send --rpc-url $RPC --private-key $(VKEY)               $TOK "approve(address,uint256)" $DEPLOYER_ADDRESS 1000
```

名单状态约定(消除"中途解黑后又假设在名单"的坑):
- 每个需要"VICTIM 在名单"的 case,在开头自己 `add(VICTIM)`(合约去重,重复 add 无害、幂等),不依赖上一个 case 的残留。
- 解黑类 case(C26/C27)自包含;跑完后若后续还要 VICTIM 在名单,后续 case 会自行重新 add。

# 验证步骤

## A 开关/基线

### C1:开关关闭基线(no-op)

设 `BLACKLIST_DEMO_ENABLED=false`,`./0-all.sh`。
正向(链正常出块):
```bash
for i in 1 2 3; do cast block-number --rpc-url $RPC; sleep 2; done   # 块高递增
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN       # 普通转账成功
```
负向(黑名单完全没启用):
```bash
docker compose logs op-geth-seq | grep -i "blacklist" | grep -v "disabled" ; echo "<-- 应为空"
docker compose logs op-geth-seq | grep "7-deploy-blacklist" ; echo "<-- 应显示 no-op skip"
```

### C2:开关开、名单空

`BLACKLIST_DEMO_ENABLED=true` 起链;部署后清空名单:
```bash
cast send --rpc-url $RPC --private-key $(VKEY) $MIRROR "clear()"
```
正向(空名单 = no-op):
```bash
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 | head -1  # total=0
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN                                      # 成功
```
负向:
```bash
docker compose logs op-geth-seq | grep "intercepted at exec gate" ; echo "<-- 应为空"
```

### C3:mirror 未部署 → no-op

开关打开但合约未部署(地址处无 code)。节点应短路为空名单、no-op、无报错。
```bash
cast code $MIRROR --rpc-url $RPC   # 返回 0x
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN   # 正常
docker compose logs op-geth-seq | grep -iE "blacklist.*(call failed|decode failed|error)" ; echo "<-- 应为空"
```

## B 入口关(FR-1)

### C4:入口关拒绝(from)

```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 5ether $VICTIM   # 充值
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM
sleep 3   # add 落 N,从 N+1 生效
```
正向(被加黑账户发 tx 被拒,固定错误码/文案):
```bash
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "\-32000|sender or recipient is on the blacklist"
```
负向(未加黑账户照常成功;被拒交易不上链):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN   # 成功 status=1
cast nonce $VICTIM --rpc-url $RPC                                              # 不因被拒交易增长
```
metrics(若启用):pool_rejected_total 递增;cache_size ≥ 1;exec_revert_total 不变。

### C5:入口关拒绝(to)

正向:
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $VICTIM 2>&1 | grep -iE "\-32000|on the blacklist"
```
负向:
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN   # to=CLEAN 成功
```

### C6:mempool 驱逐(FR-1 AC2)

排队 tx 的 from 被加黑后,下一区块应被移出、不打包。用 nonce gap 让 tx 稳定 pending:
```bash
X=$(cast wallet address --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/8")
XKEY=$(cast wallet private-key --mnemonic "$MN" --mnemonic-derivation-path "m/44'/60'/0'/0/8")
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 5ether $X
NONCE=$(cast nonce $X --rpc-url $RPC)
cast send --rpc-url $RPC --private-key $XKEY --nonce $((NONCE+1)) --value 1 --async $CLEAN   # nonce gap → queued
cast rpc txpool_content --rpc-url $RPC | grep -i $X   # 确认在池中
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $X ; sleep 3
```
正向(被驱逐):
```bash
cast rpc txpool_content --rpc-url $RPC | grep -i $X ; echo "<-- 应为空(已被移出)"
# metrics: pool_rejected_total 递增
```

## C 执行关·from/to(FR-2)

### C7:内层 CALL 触达(绕过入口关)

入口关只查顶层 from/to;内层触达由执行关兜底。$FWD 来自公共准备段,顶层 to=FWD(不在名单),内层打给 VICTIM。
前置:`cast send ... $MIRROR "add(address)" $VICTIM`(幂等)。
正向(内层触达 VICTIM → 回滚):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $FWD "forward(address)" $VICTIM
docker compose logs op-geth-seq | grep "intercepted at exec gate" | tail -1
# metrics: exec_revert_total{hook=call 或 eth_balance} 递增
```
负向(内层触达 CLEAN → 成功 status=1):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $FWD "forward(address)" $CLEAN
```

### C8:一笔多命中 / from==to

$TOK 来自公共准备段。
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM    # 幂等,确保在名单
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM2
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "transferFrom(address,address,uint256)" $VICTIM $VICTIM 10   # from==to==VICTIM
```
正向(整笔回滚一次,不重复计数):
```bash
docker compose logs op-geth-seq | grep "intercepted at exec gate" | tail -1   # 单条日志,exec_revert_total +1(非 +2)
```

## D 执行关·Transfer event(FR-2)

### C9:Transfer event(ERC20 transferFrom / transfer)

$TOK 来自公共准备段(已 mint 给 VICTIM 1000、VICTIM 已 approve DEPLOYER)。前置:`add(VICTIM)`(幂等)。
正向(from=VICTIM 的 Transfer event 命中;顶层 to=TOK 绕过入口关):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "transferFrom(address,address,uint256)" $VICTIM $CLEAN 10
docker compose logs op-geth-seq | grep "intercepted at exec gate" | tail -1
# metrics: exec_revert_total{hook=log} 递增;VICTIM token 余额不变(整笔回滚)
cast call --rpc-url $RPC $TOK "balanceOf(address)(uint256)" $VICTIM   # 仍 1000
```
to=VICTIM 方向:
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "mint(address,uint256)" $DEPLOYER_ADDRESS 100
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "transfer(address,uint256)" $VICTIM 10   # Transfer(to=VICTIM) → 回滚
```
负向(holder 非名单 → 成功):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "transfer(address,uint256)" $CLEAN 10     # status=1
```

### C10:授权变体(approve+helper / permit)

机制同 C9(都产生 from=VICTIM 的 Transfer event),换授权方式:
- approve+helper:VICTIM 提前 `approve(helper)`,helper 触发 transferFrom —— 复用 C9 的 transferFrom 路径,spender 换成 helper。
- EIP-2612 permit:若 token 支持 permit,用离线签名替代 approve 后 transferFrom。
验证点同 C9:exec_revert_total{hook=log} 递增 + intercepted 日志。

### C11:ERC721(Transfer event,tokenId indexed)

ERC721 的 Transfer 与 ERC20 同 topic0 但 tokenId 也 indexed;验证 from/to 仍从 topics 正确提取。
```bash
# 最小 ERC721 合约 emit Transfer(from=VICTIM, to, tokenId);顶层 to=NFT 合约
# 正向:from=VICTIM → hook=log 回滚;负向:from/to 均非名单 → 成功
```

### C12:ERC1155(TransferSingle/Batch,不同事件分支)

$T1155 来自公共准备段。前置:`add(VICTIM)`(幂等)。
正向(TransferSingle from=VICTIM 命中):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $T1155 "move(address,address,uint256,uint256)" $VICTIM $CLEAN 1 5
docker compose logs op-geth-seq | grep "intercepted at exec gate" | tail -1   # hook=log
```
负向(from/to 均非名单 → 成功):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $T1155 "move(address,address,uint256,uint256)" $CLEAN $DEPLOYER_ADDRESS 1 5
```

### C13:Transfer 检查精度负向

```bash
# value=0 但 from=VICTIM 的 Transfer 仍须回滚
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "transferFrom(address,address,uint256)" $VICTIM $CLEAN 0   # 仍回滚
# topic0 像 Transfer 但 from/to 都不命名单(victim 只在 data)→ 不回滚
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $TOK "noise(address)" $CLEAN                                   # status=1,无拦截
```

### C14:协议变体(机制等同 C9,defense-in-depth)

下列协议的资产转移最终都落到 Transfer event(或内层 from/to),与 C9 同一段检测代码,机制层已覆盖:

| 变体 | 触发方式 | 命中支柱 |
|---|---|---|
| Permit2(B-5) | 部署 Permit2,permitTransferFrom(VICTIM) | Transfer event |
| EIP-3009(B-6) | token.transferWithAuthorization(VICTIM 签名) | Transfer event |
| DEX swap(B-9) | Router → 多个 transferFrom(VICTIM) | Transfer event |
| ERC-4337(B-10) | EntryPoint.handleOps,内层 UserOp 触达 VICTIM | 内层 from/to + Transfer |
| EIP-7702(B-11) | VICTIM 委托代码后被调用 | 内层 from/to + Transfer |
| blob tx(B-14) | type-3 tx,载荷同普通 tx | 同底层机制 |

不单列正式 case;做 defense-in-depth 时验证点统一为:exec_revert_total{hook=log 或 call} 递增 + intercepted 日志 + 整笔回滚。

## E 执行关·ETH balance / 精度(FR-2)

### C15:ETH balance / selfdestruct(B-1)

$DES 来自公共准备段。前置:`add(VICTIM)`(幂等)。
正向(selfdestruct 把 ETH 打给 VICTIM,顶层 to=DES 不在名单 → ETH balance 命中):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1ether $DES "destroyTo(address)" $VICTIM
docker compose logs op-geth-seq | grep "intercepted at exec gate" | tail -1
# metrics: exec_revert_total{hook=eth_balance 或 selfdestruct} 递增;VICTIM ETH 余额不变
```
负向(beneficiary 非名单 → 成功):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1ether $DES "destroyTo(address)" $CLEAN
```

### C16:committed-effect 精度 —— 回滚子调用触达不计

内层子调用触达 VICTIM 但该子调用自身回滚、整笔仍成功 → 不应拦截(只看已提交效果)。$SW(CallSwallower)/ $TOK 来自公共准备段。前置:`add(VICTIM)`(幂等)。
```bash
# CallSwallower.swallow(TOK, transferFrom(VICTIM, CLEAN, 1)):
# 内层 transferFrom 因 $SW 无 VICTIM 的 allowance 而 revert,被低层 call 吞掉,整笔成功。
INNER=$(cast calldata "transferFrom(address,address,uint256)" $VICTIM $CLEAN 1)
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $SW "swallow(address,bytes)" $TOK $INNER
```
正向(整笔成功、不拦截):
```bash
# 该 tx receipt status=1;日志无 "intercepted at exec gate"
docker compose logs op-geth-seq | grep "intercepted at exec gate" | grep <该_tx_hash> ; echo "<-- 应为空"
```
说明:此 case 也是 reth/op-geth 跨端结论必须一致的点,单端先确认 op-geth 为 status=1。

### C17:费用/coinbase 排除集(FR-2 误报精度)

名单地址若仅因 gas 费 / coinbase 优先费 / L1 data fee / base fee 销毁 引起余额变化,不得回滚。
手动最佳努力:把出块 coinbase 设成 VICTIM(op-geth `--miner.etherbase=$VICTIM`,改 compose 后重启 seq),让每块费用流向 VICTIM:
```bash
for i in 1 2 3; do cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN; sleep 2; done
```
正向(不被误拦):
```bash
docker compose logs op-geth-seq | grep "intercepted at exec gate" ; echo "<-- 应为空(费用流入不触发)"
# metrics: exec_revert_total 全程不增
```
负向(真实 value 转移给 VICTIM 仍拦):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1ether $FWD "forward(address)" $VICTIM   # 内层转 → 回滚
```
说明:精确排除集(逐项断言)更适合 UT;此手动 case 验"费用流入不误拦"的宏观行为。若不便改 etherbase,降级为 UT。

## F L1↔L2(FR-3)

### C18:L1 deposit included-as-reverted

```bash
PORTAL=$(grep '^OPTIMISM_PORTAL_PROXY_ADDRESS=' .env | cut -d= -f2)
cast send --rpc-url $L1_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY $PORTAL \
  "depositTransaction(address,uint256,uint64,bool,bytes)" $VICTIM 1 100000 false 0x --value 1
# 等 deposit 被 L2 打包
```
正向(命中 deposit 必上链但 reverted,receipt 逐字段):
```bash
cast receipt <L2_TX_HASH> --rpc-url $RPC --json | jq '{status, gasUsed}'
#   status == 0x0;gasUsed == gasLimit(0x186a0=100000),强制全额、非自然消耗
docker compose logs op-geth-seq | grep "intercepted at exec gate" | grep "deposit=true"
```
全字段奇偶(FR-3 / I-6,keep-mint + nonce+1):
```bash
cast balance <DEPOSIT_FROM> --rpc-url $RPC   # mint 已入账(未回滚)
cast nonce   <DEPOSIT_FROM> --rpc-url $RPC   # +1
```
负向 1(未命中 → status=1):
```bash
cast send --rpc-url $L1_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY $PORTAL \
  "depositTransaction(address,uint256,uint64,bool,bytes)" $CLEAN 1 100000 false 0x --value 1
# 对应 L2 tx status=0x1,无 intercepted 日志
```
负向 2(系统/L1-attributes deposit,from=0xDeaD…0001):应 status=1,无拦截。
说明:deposit 在 build 与 follower import 两路径拦截一致(不同于普通 L2 tx 只在 build 拦);单 seq 节点走不到 follower import,该一致性待 reth/多节点。

### C19:deposit + Transfer event(A-9)

在 C18 基础上,让 deposit 内层产生 from=VICTIM 的 Transfer event:
```bash
# deposit 的 calldata 让 L2 侧执行 transferFrom(VICTIM,...) → 内层 Transfer event 命中
# 正向:included-as-reverted(status=0、gasUsed=gasLimit),hook=log;负向:系统 deposit 不拦
```

### C20:deposit address aliasing(A-8)

⚠ 先确认语义(已抛给 op-geth):L1 合约调 portal 时 L2 `from = L1地址 + 0x1111…1111`(aliased)。名单匹配的是 L1 原始地址 还是 aliased 后 L2 地址 —— op-geth 与 reth 必须一致,否则既漏拦又分叉。
```bash
# L1 部署调 portal 的合约 C1L,L2 from 被 aliasing 改写;aliased = C1L + 0x1111000000000000000000000000000000001111
```
分支 A(语义=匹配 aliased L2 地址):把 aliased(C1L) 加入名单 → 顶层 from=aliased 命中 from/to → included-as-reverted。
分支 B(语义=匹配 L1 原始地址):把 C1L 加入名单,from=aliased≠C1L → from/to 漏,只能靠内层 Transfer event 兜底;若内层无 Transfer 且仅靠 from → 漏拦(语义确认时定清)。
说明:精确改写规则与漏拦边界更适合 UT;手动 case 验宏观行为,语义口径必须先与 op-geth/reth 对齐。

### C21:L2→L1 提款(B-12)

```bash
# L2ToL1MessagePasser 预部署地址 0x4200000000000000000000000000000000000016
# 经 helper 让内层 from/to 触达 VICTIM(顶层走 helper 绕过入口关)
# 正向:涉及 VICTIM 的提款被执行关拦;负向:涉及 CLEAN 的提款成功
```

### C22:deposit 豁免边界(FR-3 AC2)

系统 / L1-attributes deposit(from=`0xDeaD…0001`)即使内层触达 VICTIM 也永不拦截。
```bash
# 每区块开头的 L1-attributes deposit receipt 应 status=1,无 intercepted 日志
```
说明:伪造 from=系统地址的 deposit 触达 VICTIM 在手动环境难构造,主要由 UT 覆盖(对 exempt sender 直接返回 false);手动验证退化为"系统 deposit 全程 status=1、无拦截"。

## G 数据源 / 读取接口(FR-4)

### C23:分页读取(名单跨多页)

页大小编译期固定 1024,触发翻页需名单 > 1024。批量加入 1030 个确定性地址,VICTIM 最后加入(落第 2 页):
```bash
for i in $(seq 1 1029); do
  ADDR=$(printf '0x%040x' "$i")
  cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" "$ADDR" >/dev/null
done
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM   # 索引约 1029
sleep 3
```
正向(第 2 页的 VICTIM 仍被拦):
```bash
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 | head -1   # total=1030
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "\-32000|on the blacklist"
# metrics: cache_size == 1030(== total,无截断、无漏页)
```
边界变体:恰好 1024(单页读完)、1025(触发第 2 页)。

### C24:合约写入校验(零地址 / 去重)

```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" 0x0000000000000000000000000000000000000000 2>&1 | grep -i "zero address"
T1=$(cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 1 | head -1)
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM >/dev/null
T2=$(cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 1 | head -1)
[ "$T1" = "$T2" ] && echo "dedup OK"
```

### C25:getBlacklist 参数边界

```bash
TOTAL=$(cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 1 | head -1)
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" "$TOTAL" 16   # start>=total → 空数组
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 1 2            # 中段分片
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 0            # limit=0 → 空
```

## H 生效时序(FR-5)

### C26:解黑恢复

```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "remove(address)" $VICTIM
sleep 3   # 等区块边界,从 M+1 生效
```
正向(恢复正常):
```bash
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN   # 成功 status=1
```
负向:
```bash
cast call --rpc-url $RPC $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 | head -1  # total 减 1
```

### C27:生效时序对称(FR-5)

remove 落入 block M → 从 M+1 起放行(与 add 落 N → N+1 对称)。
```bash
# 承接 C4(VICTIM 已在名单)
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "remove(address)" $VICTIM
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "32000|blacklist" || echo "已放行"   # 同块窗口可能仍被拒 → 1 块延迟
sleep 3
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN   # 现在应成功 status=1
```
说明:同块 add 不立即生效无法手动稳定复现,归 UT;本 case 验"remove 需过一个区块才放行"。

## I 负向约束(FR-6 / FR-7)

### C28:FR-7 负向约束

无 isBlocked / blacklist 查询 RPC(AC3):
```bash
cast rpc xlayer_isBlocked $VICTIM --rpc-url $RPC 2>&1 | grep -iE "method not found|does not exist"
cast rpc eth_isBlocked    $VICTIM --rpc-url $RPC 2>&1 | grep -iE "method not found|does not exist"
```
Pool 错误码精度(AC4)—— 复用 C4 被拒交易:
```bash
ERR=$(cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1)
echo "$ERR" | grep -- "-32000"
echo "$ERR" | grep -F "xlayer-blacklist: sender or recipient is on the blacklist"
echo "$ERR" | grep -i "${VICTIM#0x}" ; echo "<-- 应为空(message 不含地址)"
```
metrics 拆分(AC2):入口关拦截(C4)仅 pool_rejected_total +1;执行关拦截(C18 deposit / C9 event)仅 exec_revert_total +1。
```bash
curl -s localhost:<metrics_port>/debug/metrics/prometheus | grep -E "xlayer_blacklist_(pool_rejected_total|exec_revert)"
```

### C29:无黑名单 CLI 参数(FR-6 AC3)

```bash
docker run --rm <op-geth-image> --xlayer.blacklist.enabled=true 2>&1 | grep -iE "flag provided but not defined|unknown|invalid"
# 期望:flag 未定义 → 进程退出码非 0
```

## J 共识 / 同步

### C30:seq vs rpc 状态一致(anti-fork 核心)

本拓扑已起 seq(geth,8123)+ rpc(geth,8124)。rpc 导入 seq 区块时必须算出一致的 state/receipts root,否则拒块 → 分叉。这是 build vs import 路径一致性的直接验证(deposit 奇偶、L2-tx drop-vs-不拦截不对称都在此暴露),无需 reth。
前置:确保 VICTIM 在名单并制造活动(C26/C27 可能已解黑,这里重新 add 再造一笔被拦交易):
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM ; sleep 3   # 幂等
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN   # 制造一笔被 drop 的 L2 tx
# 再发一笔涉及 VICTIM 的 deposit(同 C18)制造 included-as-reverted
HEAD=$(cast block-number --rpc-url http://localhost:8123)
for n in $(seq $((HEAD-20)) $HEAD); do
  S=$(cast block $n --rpc-url http://localhost:8123 --json | jq -r '.stateRoot,.receiptsRoot' | paste -sd,)
  R=$(cast block $n --rpc-url http://localhost:8124 --json | jq -r '.stateRoot,.receiptsRoot' | paste -sd,)
  [ "$S" = "$R" ] && echo "block $n OK" || echo "block $n DIVERGE: seq=$S rpc=$R"
done
```
重点比对含 intercepted deposit 的区块 receiptsRoot。
负向(rpc 不拒块):
```bash
docker compose logs op-geth-rpc | grep -iE "bad block|invalid merkle root|invalid gas used|state root mismatch" ; echo "<-- 应为空"
```

### C31:RPC 从 0 同步(历史重放)

链上已有黑名单历史后,起一个全新 rpc 从创世重放,必须重建出与 seq 一致的 head 状态(含"未部署→部署"过渡)。
```bash
docker compose stop op-geth-rpc
# 清 rpc datadir(按 devnet 数据目录约定)
docker compose start op-geth-rpc
# 等同步到 head
```
正向:
```bash
H=$(cast block-number --rpc-url http://localhost:8123)
cast block $H --rpc-url http://localhost:8123 --json | jq -r .stateRoot
cast block $H --rpc-url http://localhost:8124 --json | jq -r .stateRoot   # 应相等
docker compose logs op-geth-rpc | grep -iE "bad block|state root mismatch" ; echo "<-- 应为空"
```

### C32:节点重启(FR-4 无冷启动重建)

```bash
docker compose restart op-geth-seq op-geth-rpc
sleep 5
```
正向:
```bash
for i in 1 2 3; do cast block-number --rpc-url http://localhost:8123; sleep 2; done   # 块高继续递增
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "32000|blacklist"   # 仍生效
# seq/rpc 仍一致(复用 C30 比对)
```
负向:
```bash
docker compose logs op-geth-seq op-geth-rpc | grep -iE "bad block|state root mismatch|panic" ; echo "<-- 应为空"
```

## K 合约生命周期 / 升级

### C33:激活过渡(部署前→空→add,PRD 三阶段上线/回滚)

运行中的链上走完三阶段,验证每个过渡无分叉(对应 PRD「代码升级 → 部署空名单合约 → 首次 add 激活」与「未部署/空名单等同现状」回滚)。需关掉自动部署(`BLACKLIST_DEMO_ENABLED=false` 起链),手动按阶段部署。
阶段 A — 未部署:
```bash
cast code $MIRROR --rpc-url $RPC                                              # 0x
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN # 正常
```
阶段 B — 部署空合约(仍 no-op):
```bash
DEPLOY_BLOCK=$(cast block-number --rpc-url $RPC)
# 用 19 号账户部署到确定性地址(同 7-deploy-blacklist),断言地址==$MIRROR
cast call $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 --rpc-url $RPC | head -1   # total=0
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY --value 1 $CLEAN                          # 仍正常
```
阶段 C — 首次 add 激活:
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM ; sleep 3
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "32000|blacklist"      # 已拦截
```
过渡一致性(核心,无分叉):
```bash
HEAD=$(cast block-number --rpc-url http://localhost:8123)
for n in $(seq $DEPLOY_BLOCK $HEAD); do
  S=$(cast block $n --rpc-url http://localhost:8123 --json | jq -r .stateRoot)
  R=$(cast block $n --rpc-url http://localhost:8124 --json | jq -r .stateRoot)
  [ "$S" = "$R" ] && echo "block $n OK" || echo "block $n DIVERGE"
done
```
回滚验证:
```bash
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "clear()" ; sleep 3
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN   # 恢复正常,等同未部署
```

### C34:ABI 不变的合约升级(approach B 解耦验证)

节点只依赖 `getBlacklist` ABI、不读 storage,故合约内部实现可换而节点无感。需 mirror 以 proxy 形态部署在确定性地址(impl 可换、地址不变)。
```bash
# 1) 确定性地址部署 proxy(impl=v1,enumerable set);走黑名单活动
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM ; sleep 3
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "32000|blacklist"   # 升级前已拦
# 2) 升级 impl 到 v2(内部存储结构不同,但 getBlacklist ABI 不变):proxy admin 调 upgradeTo(v2)
```
正向(升级后节点透明无感、名单延续、不分叉):
```bash
cast call $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 16 --rpc-url $RPC | head -1   # total 不变,VICTIM 仍在
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $CLEAN 2>&1 | grep -iE "32000|blacklist"     # 升级后仍拦
# 升级块前后 seq vs rpc state root 一致(复用 C30 比对)
```
负向 / 失败模式(ABI 破坏性升级,归 UT):改坏 getBlacklist 签名 → 节点读失败 → fail-open 当空名单(静默关闭),但须确定性、seq/rpc 一致、不分叉。
说明:升级需 proxy(保持确定性地址);demo 合约当前非 proxy,本 case 要先把 mirror 改成 proxy 形态。若暂不引 proxy,降级为"换地址重部署=冷升级"(需节点重新硬编码地址 + 重建,等同 C2/C3 路径)。

## L 新增跨端 / 多节点 / 对抗 / 长跑 case

下列 case 在原计划中没有命令,补充骨架。具体测试代码 / harness 在第一次执行时落到 `devnet/test-results/.../Cn.sh` 持久化。

### C8-ext:多加黑账户互发(Gap 6)
```bash
# VICTIM 和 VICTIM2 都在名单。VICTIM → VICTIM2 转账。
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM
cast send --rpc-url $RPC --private-key $DEPLOYER_PRIVATE_KEY $MIRROR "add(address)" $VICTIM2
sleep 3
cast send --rpc-url $RPC --private-key $(VKEY) --value 1 $VICTIM2 2>&1 | grep "32000"   # 入口关 from 先拦
# 期望:pool_rejected +1(不重复计数);message 固定
```

### CXW1:L2 提款 helper 内层触达 VICTIM(Gap 1, 替换 C21)
```bash
# 部署一个 helper 合约,它调 L2ToL1MessagePasser.initiateWithdrawal 同时内部转账给 VICTIM
# 顶层 to=helper(非名单),inner-call/balance 涉及 VICTIM
# 期望:执行关拦截(hook=eth_balance 或 log,取决于触达方式);跨端 receipt 字节一致
```

### CX3:mirror snapshot 跨端 read parity
```bash
H=$(cast block-number --rpc-url $RPC_GETH)
R_geth=$(cast call $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 64 --rpc-url $RPC_GETH --block $H)
R_reth=$(cast call $MIRROR "getBlacklist(uint256,uint256)(uint256,address[])" 0 64 --rpc-url $RPC_RETH --block $H)
[ "$R_geth" = "$R_reth" ] || echo "DIVERGENCE at block $H"
```

### CX5/CX6 anti-fork 复现(共用 patch + 不同 env 模式)

测重点:malicious sequencer 双向偏离 deposit gate → honest follower 拒块。

#### 准备 patch(测试专用,跑完必须 revert,严禁带进生产)

文件:`op-geth/core/blacklist_gate_xlayer.go`

```diff
@@ -36,6 +36,7 @@ package core
 import (
 	"errors"
 	"math/big"
+	"os"
 	"time"

 	"github.com/ethereum/go-ethereum/common"
@@ -238,6 +239,27 @@ func applyTransactionWithBlacklistGate(...) {
 	if hit && !tx.IsDepositTx() && !dropNormalHit {
 		hit = false
 	}
+	// CX5/CX6 anti-fork test ONLY: when XLAYER_BYPASS_BLACKLIST_GATE=1 is set on
+	// a SEQUENCER process, bypass the gate so the seq produces a block where a
+	// blacklisted deposit succeeds (or a clean one fails — toggled by =2). An
+	// honest follower (no env var) will still apply the gate during re-exec and
+	// detect the divergence as a bad block. DO NOT enable in production.
+	if hit && os.Getenv("XLAYER_BYPASS_BLACKLIST_GATE") == "1" {
+		log.Warn("xlayer-blacklist: GATE BYPASSED (CX5 test mode)",
+			"hash", tx.Hash(), "deposit", tx.IsDepositTx(), "category", category)
+		hit = false
+	}
+	// CX6: when env=2, FORCE a synthetic hit on every clean deposit to simulate
+	// a malicious seq that revert-overrides a deposit that should have succeeded.
+	if !hit && tx.IsDepositTx() && os.Getenv("XLAYER_BYPASS_BLACKLIST_GATE") == "2" {
+		if !params.IsDepositExemptSender(msg.From) {
+			log.Warn("xlayer-blacklist: GATE FORCE-HIT (CX6 test mode)",
+				"hash", tx.Hash())
+			hit = true
+			category = "cx6_force"
+		}
+	}
 	if hit {
```

`devnet/docker-compose.yml` `op-geth-seq` 服务加 environment 段:

```yaml
  op-geth-seq:
    environment:
      XLAYER_BYPASS_BLACKLIST_GATE: "${XLAYER_BYPASS_BLACKLIST_GATE:-}"
```

`devnet/.env` 加:
```
XLAYER_BYPASS_BLACKLIST_GATE=1   # CX5
# XLAYER_BYPASS_BLACKLIST_GATE=2   # CX6
```

打包步骤:
```bash
# 1. 应用 patch
cd /Users/oker/workspace/xlayer/op-geth
git apply <patch>   # 或手工编辑

# 2. 重建 op-geth 镜像
GITTAG=$(git rev-parse --short HEAD)
docker build -t op-geth:$GITTAG -f Dockerfile .
docker tag op-geth:$GITTAG op-geth:latest

# 3. 验证 patch 进了 binary
docker run --rm --entrypoint sh op-geth:latest -c \
  "strings /usr/local/bin/geth | grep -E 'BYPASSED|FORCE-HIT'"
```

#### CX5:malicious seq 包黑名单 deposit → follower 拒块

`.env` 设 `XLAYER_BYPASS_BLACKLIST_GATE=1`,T3 拓扑 (SEQ_TYPE=geth, RPC_TYPE=reth):

```bash
# 部署 FakeTransferEmitter 到 L2
forge create src/FakeTransferEmitter.sol:FakeTransferEmitter --rpc-url L2 ...
# add(VICTIM) 到 mirror
cast send MIRROR "add(address)" VICTIM ...
# L1 deposit:to=Emitter, data=emitFakeTransfer(SENDER, VICTIM, 1)
DATA=$(cast calldata "emitFakeTransfer(address,address,uint256)" SENDER VICTIM 1)
cast send --rpc-url L1 PORTAL \
  "depositERC20Transaction(address,uint256,uint256,uint64,bool,bytes)" \
  EMITTER 0 0 300000 false "$DATA"
# 等 ~15s 让 op-node derive
# 期望:
# - op-geth-seq 日志: "GATE BYPASSED (CX5 test mode) ... deposit=true"
# - L2 deposit tx status=1 on seq (本该是 0)
# - op-reth-rpc 日志: "Encountered invalid block ... Bad block with existing invalid ancestor"
# - reth stuck at parent block; geth seq 继续出块
# 跨端验证:cast block N --rpc-url reth-rpc 在 N>=bad_block_number 时报 NOT_FOUND
```

#### CX6:malicious seq 反向偏离 → follower 同样拒块

`.env` 改 `XLAYER_BYPASS_BLACKLIST_GATE=2`, clean + reboot devnet (reth 在 CX5 后会 stuck):

```bash
# Mirror 任意非空状态(自动 seed 的 0xAA 即可),CLEAN 不在名单
# L1 发 clean deposit:to=CLEAN, data=0x
cast send --rpc-url L1 PORTAL \
  "depositERC20Transaction(address,uint256,uint256,uint64,bool,bytes)" \
  CLEAN 0 0 100000 false 0x
# 期望:
# - op-geth-seq 日志: "GATE FORCE-HIT (CX6 test mode)"
# - 该 clean deposit 被 seq 强制 include-as-reverted (status=0)
# - reth 期望该 deposit 应 status=1,re-exec 后 state root 不一致 → 拒块
# - reth stuck at parent block
```

#### 跑完后 revert(必做)

```bash
cd /Users/oker/workspace/xlayer/op-geth
git checkout core/blacklist_gate_xlayer.go      # 撤 patch
docker build -t op-geth:latest -f Dockerfile .   # 重建干净 binary
# 撤 docker-compose.yml 的 XLAYER_BYPASS_BLACKLIST_GATE env 段
# 撤 .env 的 XLAYER_BYPASS_BLACKLIST_GATE 行
```

### CX7:flashblocks pre-confirm 拦截边界(reth-only)
```bash
# FLASHBLOCK_ENABLED=true,SEQ=reth
# add(VICTIM),让 VICTIM 发 tx
# 观察 reth flashblock 预确认面是否在 pre-confirm 阶段就拦,还是仅在 finalize 拦
# 关键:确认 reth 的 builder 路径在 flashblock 周期内正确刷新 snapshot
```

### CX8:conductor handover mid-add
```bash
# 档二集群:3 个 conductor(混选 reth/geth)
# 启动一笔 add(VICTIM)tx,在它落入区块前 / 立即后,强制切主到另一类型 leader
# 期望:无论切主何时发生,最终名单状态在 3 节点一致;后续 VICTIM 发 tx 跨任意 seq 都被拦
```

### CX9:proxy upgrade in mixed topology
```bash
# 同 C34,但顶层拓扑切为 reth+geth 异类
# upgradeTo(V2)tx 落在 block M
# 验证:M+1 块在 reth-rpc 和 geth-rpc 上读到的 ABI 行为一致;升级块前后 stateRoot 跨端一致
```

### CX10:fail-open parity(P0 anti-fork)
```bash
# 部署一个 V3 mirror impl,getBlacklist 内永远 revert
# upgradeTo(V3),让 mirror 在 block M 起 fail
# 两端必须都 fail-open:
#   - 节点日志出现 "getBlacklist call failed" / Error
#   - 行为等价于空名单,VICTIM 此后发 tx 应 status=1
#   - 关键:两端的 fail-open 时点一致,否则一端拒一端过 → 分叉
```

### CX11:reth pool 主动驱逐(bd6dc9c 专项)
```bash
# 仅 reth-seq 拓扑
# 让 X 提交 nonce-gap queued tx 入池
# add(X) → 等 1-2 块
# 期望:reth 主动从 pool 中删除 X 的 queued tx(对比 op-geth 不删)
# 验证:txpool_content 不再包含 X 的该笔 tx
```

### CX13:multi-rpc 并发 import
```bash
# 档二:1 个 reth-seq + (1 geth-rpc + 1 reth-rpc)
# seq 持续出含 deposit + drop 的块
# 两个 rpc 并发拉同一 block,期望两边 stateRoot 一致
```

### CX14:混合 seq pool 一致
```bash
# 档二:2 reth-seq + 1 geth-seq,VICTIM 在名单
# 把 VICTIM 的 tx 同时提交给三种 seq 的 RPC,各自的入口关都应拒
# 没有"某 seq 不拦"的偏差
```

### CXR1:reorg 后黑名单快照重建
```bash
# 档二:三 seq raft
# add(VICTIM)在 leader-A,落入 block M
# kill leader-A → raft 重选 leader-B → reorg M 之后的几个块
# 期望:new leader 的 blacklist snapshot 基于新 head 重建;若 add tx 还在 canonical chain → VICTIM 仍被拦;若被 reorg 出去 → VICTIM 暂不被拦,等 add tx 重新打包后恢复
# 关键:三节点最终 stateRoot 一致
```

### CXW1-3:churn(高频 add/remove)
```bash
# CXW1 toggle:while true; do add(X); sleep 1; remove(X); sleep 1; done & 同时持续发 X 的 tx
# CXW2 batch:批量 addBatch(N) / removeBatch(N) + 发 X 的 tx
# CXW3 churn 跨切主:CXW1 同时持续 + 每 5s 在 reth↔geth 之间切主,持续 1-2 分钟
# 期望:全程三节点逐块 stateRoot 一致、无 bad block
```

### CXG1:黑名单 × gasless 交互
```bash
# 启用 gasless(参考 gasless 测试计划)
# 在 gasless 白名单中 add 某 EOA,同时在 blacklist 中也 add 同一 EOA
# 该 EOA 发 0 价 tx
# 期望:入口关优先级高于 gasless 放行 → tx 仍被入口关 -32000 拒(不靠 gasless 路径绕过 blacklist)
```

### ST1/ST2/ST3:soak(5min / 15min / 30min)
```bash
# 档二:adventure 工具 + cast churn 线程 + 多端点提交,负载 ~300-400 TPS,混合 普通 tx + blacklist 拦截场景
# 全程逐块三节点 diff stateRoot + 真实坏块日志扫描
# 期望:零分叉、无 bad block、pool 大小回落、内存平稳
# 三轮时长递增,5min 验功能、15min 验中等累积、30min 验长时间退化
```

# 本计划不覆盖

- **区块边界生效时机**:add 落入 block N,同块 N 内 from VICTIM 的 tx 不应被拦,从 N+1 才生效。手动难精确控同块时序,归 UT/IT 覆盖。
- **上限截断**:total > 300000 时截断行为。手动构造不现实,归 UT;**跨端必须一致项**(若 reth 拒绝、op-geth 截断 → 跨端分叉,需统一)。
- **TPS 性能**(G-3 "<1%"):关/开空名单/开带名单 loadtest 对照。归性能测试。
- **形式化验证 / 模糊测试**:归专项。
- **`RETH_STORAGE_V2=true` 存储变体**:本计划默认 v1,v2 一致性归 reth 团队专项。
- **网络分区**:raft 自身处理,跟 blacklist 无关。
- **合约层 access control**:demo mirror 故意无 ACL,跟节点测试无关。
- **deposit 仅 pure CALL 触达(A-7/B-13)且无 event 无 balance 变化**:两端 Decision B 都跳过 check①,这类路径不拦——属架构权衡,不是 bug。

# 复测流程建议

1. **档一 reth 单端 baseline**(T2 ≈ SEQ=reth+RPC=reth):全量跑序号 1-31 中所有标"reth-seq + geth-seq" 的 case 的 reth 那一组
2. **档一 跨端**(T3/T4 ≈ 异类双向):跑序号 19-21、24、25、32、34、35-36、42、46(共 ~10 case × 2 组 = 20 跑)
3. **档二 多节点**(CX8/13/14、CXR1、CXW1-3、CXG1):需要先改 docker-compose 给 reth/geth 实例独立端口、开 CONDUCTOR_ENABLED=true
4. **档二 soak**(ST1/2/3):最后跑,确认稳态无退化
5. **CX5/CX6 对抗**:按本文档前面 patch 段步骤,跑完务必 git checkout op-geth 还原
6. **跑完每 case 后**:更新本文件「实际」列(从 ⏳ pending 改成 ✅/❌/⏸ + 简述结果),保留原始证据到 `devnet/test-results/blacklist-XLOP-1100-<ts>/Cn.md`
