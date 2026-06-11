测试计划:devnet 黑名单单 op-geth 节点功能验证(XLOP-1100)

# 测试目标

在单 op-geth 节点的 devnet(chain 195)上,验证应急冻结黑名单的单端功能正确性:

- 开关关闭时全链 no-op,行为同未引入本功能
- 开关打开、mirror 部署后,加黑地址的资产转移被拦截(入口关 + 执行关)
- L1 forced inclusion 的 deposit 命中名单时 included-as-reverted(status=0、gasUsed=gasLimit)
- 解黑后恢复正常
- metrics / 日志证据链可追溯
- 节点通过 getBlacklist 接口读取名单(与本仓 demo 合约对接)

不在本计划内:跨客户端(reth)state root / receipt 逐字段一致(FR-5)——需 reth 到位后混部署才能验;follower 不拦普通 L2 的逻辑(单 seq=geth 走不到)。这些标注为"待 reth"。

# 环境准备

## 前置条件

1. op-geth 已切到含 `getBlacklist` ABI + 195 地址 `0x73511669…F31f` 的提交,且其未提交改动已落地。
2. op-geth 镜像必须重建(新代码进二进制),否则节点仍读旧地址 / 旧 ABI。

## 启动方式

```bash
cd "$(git rev-parse --show-toplevel)/devnet"
./clean.sh          # example.env -> .env(若 .env 已存在不覆盖,需手动同步下列项)
./init.sh           # 重建镜像(SKIP_OP_GETH_BUILD=false 时重建 op-geth)
./0-all.sh          # 起 L1 + 合约 + L2,末尾自动跑 7-deploy-blacklist.sh
```

停止 / 日志:

```bash
docker compose ps
docker compose logs -f op-geth-seq      # seq RPC 8123;rpc 节点 RPC 8124
docker compose down
```

L2 RPC:seq `http://localhost:8123`、rpc `http://localhost:8124`

## 配置变更(.env)

单 op-geth 拓扑(seq=geth + rpc=geth)+ 打开黑名单:

| 配置项 | 原值 | 改为 |
|---|---|---|
| SEQ_TYPE | reth | geth |
| RPC_TYPE | geth | geth |
| SKIP_OP_RETH_BUILD | false | true |
| SKIP_OP_GETH_BUILD | false | false(需重建) |
| FLASHBLOCK_ENABLED | true | false(geth 无 flashblocks) |
| CHAIN_ID | 195 | 195 |
| BLACKLIST_DEMO_ENABLED | false | true |
| LAUNCH_RPC_NODE | true | true(C30/C31/C32 需要 rpc 节点) |

注:`.env` 直接改(clean.sh 不覆盖已存在的 .env);同时同步到 example.env 保持一致。

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

# 测试矩阵

| 类别 | Case | 配置 / 名单 | 验证项 |
|---|---|---|---|
| A 开关/基线 | C1 | BLACKLIST_DEMO_ENABLED=false | 全链 no-op,无 mirror 部署、无拦截 |
| A 开关/基线 | C2 | flag=on,名单空(部署后 clear) | cache_size=0,普通 tx 不受影响 |
| A 开关/基线 | C3 | flag=on,mirror 未部署 | GetCodeSize==0 短路 → no-op,无报错 |
| B 入口关 | C4 | flag=on,名单含 VICTIM | 从 VICTIM 发 tx → 入口关拒绝 -32000;CLEAN 正常 |
| B 入口关 | C5 | flag=on,名单含 VICTIM | 转账 to=VICTIM → 入口关拒绝(to 也查) |
| B 入口关 | C6 | 排队 tx 的 from 被加黑 | 下一区块被移出 mempool、不打包(FR-1 AC2) |
| C 执行关·from/to | C7 | flag=on,名单含 VICTIM | 经 forwarder 内层 CALL 触达 VICTIM → 回滚;触达 CLEAN 成功 |
| C 执行关·from/to | C8 | 一笔多命中 / from==to | 整笔回滚一次,exec_revert +1 不重复计数 |
| D 执行关·event | C9 | 名单含 VICTIM,ERC20 | transferFrom/transfer 的 Transfer event 命中 → hook=log 回滚(A-4,B-2/B-3) |
| D 执行关·event | C10 | approve+helper / permit | 同 Transfer event 机制,不同授权路径(A-5/A-6,B-4) |
| D 执行关·event | C11 | ERC721 | safeTransferFrom 的 Transfer event 命中(B-7) |
| D 执行关·event | C12 | ERC1155 | TransferSingle/Batch(事件结构不同分支)命中(B-8) |
| D 执行关·event | C13 | Transfer 精度负向 | value=0 命中仍回滚;topic0 像 Transfer 但 from/to 不命中 → 不回滚 |
| D 执行关·event | C14 | 协议变体 | Permit2/EIP-3009/4337/7702/DEX/blob —— 机制等同 C9,defense-in-depth |
| E 执行关·balance/精度 | C15 | 名单含 VICTIM | selfdestruct beneficiary=VICTIM → hook=eth_balance 回滚(B-1) |
| E 执行关·balance/精度 | C16 | 名单含 VICTIM | 内层子调用触达 VICTIM 但子调用回滚、整笔成功 → 不拦截(committed-effect) |
| E 执行关·balance/精度 | C17 | coinbase=VICTIM | 仅费用流入不误拦(FR-2 排除集);真实 value 转移仍拦 |
| F L1↔L2 | C18 | 名单含 VICTIM | L1 deposit 涉及 VICTIM → included-as-reverted(status=0、gasUsed=gasLimit) |
| F L1↔L2 | C19 | L1 deposit+helper | deposit 内层 transferFrom 产生 Transfer event 命中 → included-as-reverted(A-9) |
| F L1↔L2 | C20 | deposit address aliasing | L1 合约 deposit,L2 from 被 aliasing 改写;语义先确认(A-8) |
| F L1↔L2 | C21 | 名单含 VICTIM | L2→L1 提款经 helper 触达 VICTIM → from/to 命中回滚(B-12) |
| F L1↔L2 | C22 | 系统 deposit 触达 VICTIM | exempt sender 永不拦截(FR-3 AC2) |
| G 读取接口 | C23 | 名单 > 1 页(≥1025) | 节点分页读全;第 2 页地址仍被拦;cache_size==total |
| G 读取接口 | C24 | 合约写入校验 | add(0x0) revert;重复 add total 不增(去重) |
| G 读取接口 | C25 | getBlacklist 参数边界 | start≥total 返回空;中段分片正确;limit=0 空 |
| H 时序 | C26 | flag=on,remove(VICTIM) | 从 VICTIM 发 tx 恢复成功;cache_size 减 1 |
| H 时序 | C27 | remove 生效时序 | 落 M → M+1 放行,需过一个区块(FR-5) |
| I 负向约束 | C28 | 负向约束 | 无 isBlocked RPC、错误码 -32000 无动态字段、metrics 拆分(FR-7) |
| I 负向约束 | C29 | 非法 CLI 参数 | `--xlayer.blacklist.*` → 进程报错退出(FR-6 AC3) |
| J 共识/同步 | C30 | seq vs rpc 一致 | 含 drop L2 / 拦 deposit 的区块,seq 与 rpc 的 state/receipts root 逐块一致 |
| J 共识/同步 | C31 | RPC 从 0 同步 | 全新 rpc 从创世重放,head 状态与 seq 一致 |
| J 共识/同步 | C32 | 节点重启 | 重启后继续出块、黑名单仍生效、seq/rpc 一致 |
| K 生命周期 | C33 | 激活过渡(部署前→空→add) | 三阶段过渡全程 seq/rpc 一致、无分叉;clear 回滚等同现状 |
| K 生命周期 | C34 | ABI 不变合约升级(proxy) | 升级 impl 后节点透明无感、名单延续、不分叉 |

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

# 本计划不覆盖(UT/IT 或待 reth)

- 区块边界生效时机:add 落入 block N,同块 N 内 from VICTIM 的 tx 不应被拦,从 N+1 才生效。手动难精确控同块时序,UT/IT 覆盖。
- 失败策略 fail-open:getBlacklist revert / 解码失败 → 当空名单 + Error 日志。需故意 revert 的 mirror,UT 覆盖。
- 上限截断:total > 300000 时截断行为。手动构造不现实,UT;且为跨端必须一致项(reth 当前拒绝、op-geth 截断,需统一)。
- reorg 刷新:入口关快照在 reorg 后按新头重建(FR-1 AC4)。单 sequencer 难触发 reorg,待 reth/多节点或 IT。
- 多 sequencer HA / conductor 切主 / 灰度升级(CONDUCTOR_ENABLED=true):切主后新 leader 读同一名单、灰度混跑不分叉。未列正式 case,建议补。
- TPS 性能(G-3 "<1%"):关 / 开空名单 / 开带名单的 loadtest 对照。归性能测试。

一致性分两层:
- 同客户端 seq(geth)vs rpc(geth):build vs import 一致、deposit receipt 奇偶、从 0 重放、重启 —— C30/C31/C32 已覆盖,无需 reth。
- 跨客户端 geth↔reth(FR-5):两种 EVM 实现逐字一致、follower 不拦普通 L2、flashblocks 预确认面 —— 待 reth。

# 结论模板

| 类别 | Case | 配置 | 启动 | 功能正确 | 证据确认 | 备注 |
|---|---|---|---|---|---|---|
| A | C1 | flag=off | | | | no-op 基线 |
| A | C2 | flag=on,空名单 | | | | cache_size=0 |
| A | C3 | mirror 未部署 | | | | no-op 无报错 |
| B | C4 | 名单含 VICTIM(from) | | | | -32000 + pool_rejected |
| B | C5 | 名单含 VICTIM(to) | | | | 入口关 to 拦截 |
| B | C6 | mempool 驱逐 | | | | 排队 tx 被移出 |
| C | C7 | 内层 CALL 触达 | | | | exec_revert + 拦截日志 |
| C | C8 | 多命中/from==to | | | | 回滚一次 |
| D | C9 | ERC20 Transfer event | | | | hook=log,A-4/B-2/B-3 |
| D | C10 | 授权变体 | | | | A-5/A-6/B-4,同 C9 |
| D | C11 | ERC721 | | | | hook=log,B-7 |
| D | C12 | ERC1155 | | | | hook=log(不同分支),B-8 |
| D | C13 | Transfer 精度负向 | | | | value=0 拦、noise 不拦 |
| D | C14 | 协议变体 | | | | 机制等同 C9,可选 |
| E | C15 | selfdestruct | | | | hook=eth_balance,B-1 |
| E | C16 | 回滚子调用触达 | | | | status=1 不拦,committed-effect |
| E | C17 | coinbase=VICTIM | | | | 费用不误拦(FR-2) |
| F | C18 | L1 deposit | | | | status=0,gasUsed=gasLimit |
| F | C19 | deposit+Transfer | | | | A-9 |
| F | C20 | deposit aliasing | | | | A-8,语义待确认 |
| F | C21 | L2→L1 提款 | | | | from/to,B-12 |
| F | C22 | 系统 deposit 豁免 | | | | exempt sender 不拦 |
| G | C23 | 分页(≥1025) | | | | cache_size==total,第 2 页被拦 |
| G | C24 | 零地址/去重 | | | | add(0x0) revert,重复 add 不增 |
| G | C25 | getBlacklist 边界 | | | | start≥total 空、中段分片正确 |
| H | C26 | remove 解黑 | | | | 恢复 status=1 |
| H | C27 | remove 时序 | | | | M+1 放行 |
| I | C28 | FR-7 负向 | | | | 无 RPC/错误码/metrics 拆分 |
| I | C29 | 非法 CLI | | | | 进程退出 |
| J | C30 | seq vs rpc 一致 | | | | state/receipts root 逐块比对 |
| J | C31 | RPC 从 0 同步 | | | | head 状态与 seq 一致 |
| J | C32 | 节点重启 | | | | 仍生效、无分叉 |
| K | C33 | 激活过渡 | | | | 三阶段无分叉,PRD rollout/回滚 |
| K | C34 | ABI 不变升级 | | | | proxy 换 impl,节点无感 |
