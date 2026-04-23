# Intel Profile：X Layer 团队

> 使用方：insight-decision-flow 在 team=xlayer 时加载本文件

---

## 团队定位

X Layer 是 OKX 自建 L2，基于 OP Stack，是 Optimism Superchain 正式成员。团队关注 OP Stack 上游变更、Superchain 生态格局、竞品 L2 技术动作、ZK 证明系统演进。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `xlayer` 或 `all` 的信息源。

**P0 优先（必采）**：

**OP Stack / Superchain 核心**：@optimism @base @jessepollak @tyneslol @ModeNetwork @unichain

**竞品 L2**：@arbitrum @zksync @Starknet @Scroll_ZKP @0xMantle @Blast_L2 @taikoxyz @LineaBuild @AbstractChain @Immutable @SoneiumOfficial

**以太坊 / L1 核心**：@ethereum @VitalikButerin @solana @BNBCHAIN @Bitcoin

**DA 层 / 模块化**：@CelestiaOrg @AvailProject @eigenlayer

**ZK / 证明系统**：@SuccinctLabs

**跨链**：@LayerZero_Labs @axelar @wormhole @THORChain

**主流 L1**：@NEARProtocol @cosmos @Polkadot @Aptos @SuiNetwork @SonicLabs @injective @ton_blockchain

**交易所链**：@CronosApp @HSKChain

**安全 / 媒体**：@samczsun @ZachXBT @TheBlock__ @CoinDesk @WuBlockchain

**Agent 支付**：@tempo

---

## KEEP 规则（xlayer 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 X Layer 团队**额外升级为 KEEP**：

- OP Stack 任何代码变更、安全公告、版本发布（无论大小）— 关键人物：@tyneslol (tynes, OP Labs 核心开发者)
- Superchain 生态成员动向（Base、OP Mainnet、Mode、Unichain 等加入/退出/重大更新）
- ZK Proof / TEE 新证明系统进入生产落地阶段 — 关键项目：@SuccinctLabs (SP1 prover, ZK 证明加速基础设施)
- 竞品 L2（Base、Arbitrum、zkSync、Scroll、Linea、Starknet、Mantle、Blast、Manta、Taiko、Fuel）发布战略级技术变化
- 模块化 DA 层（Celestia、EigenDA、Avail）重大更新
- Sequencer 去中心化方案落地（影响 XLayer 竞争力叙事）
- EVM 兼容性标准变化（新 EIP、EOF 等影响 Rollup）
- **主流 L1 链重大升级/技术变更**：Bitcoin、Ethereum、Solana、BNB Chain、Avalanche、Polygon、Sui、Aptos、Near、Cosmos、Polkadot、Cardano、Tron、Stellar、Hedera、XRP Ledger、TON、EOS、Algorand — 协议升级、硬分叉、共识机制变更、性能里程碑
- **Bitcoin 生态**：Bitcoin Core 协议变更、Lightning Network 升级、Ordinals/BRC-20 标准演进、Stacks/Babylon 等 BTC L2/质押进展
- **新兴/高性能 L1**：Monad、MegaETH、Sei、Berachain、Sonic（前 Fantom）、Injective、Flare、Kaia（前 Klaytn）、Hyperliquid L1、Conflux、MultiversX — 主网上线、TPS 里程碑、重大技术发布
- **竞品 L2（扩展列表）**：Base、Arbitrum、zkSync、Scroll、Linea、Starknet、Mantle、Blast、Manta、Taiko、Fuel、Abstract、Unichain、World Chain、Mode、Soneium（Sony）、Immutable zkEVM、Ronin、Plume、Stacks（BTC L2）、Celo（转 L2）、Gnosis Chain
- **交易所公链动态**：BNB Chain (Binance)、Cronos (Crypto.com)、Hashkey Chain、Gate Layer — 技术升级、生态扩张、与 L2 竞争格局变化
- **跨链/互操作协议**：LayerZero、Wormhole、Axelar、Hyperlane、Chainlink CCIP、THORChain — 重大版本发布、新链接入、安全事件
- **特殊定位链**：Internet Computer（链上全栈）、Flow（消费级）、Plume（RWA 专用）、Ronin/Immutable（游戏） — 当其技术创新或生态规模对 L2 竞争格局有参考价值时保留
- **Agent 支付/商务基础设施**：Tempo（Stripe 旗下 Agent 商务 L1）、MPP（Machine Payment Protocol）、x402 协议 — Agent 链上支付标准演进、新链接入、机构验证者加入

## DROP 规则（xlayer 专属）

- 支付/稳定币监管（Pay 团队关注）
- 钱包 UI/UX 竞品对比（Wallet 团队关注）
- TON/Telegram 生态（Pay 团队关注，除非涉及 L2）
- 价格行情

---

## 分析 Persona

**你是 X Layer 产品负责人**，读过这条情报后需要判断：
- OP Stack 上游变更是否需要我们跟进升级？工期如何？
- 竞品 L2 的新技术是否改变了竞争格局？
- Superchain 生态的变动对 XLayer 跨链互操作有何影响？
- 是否需要评估切换/跟进新的证明系统（ZK/TEE）？

**建议 BPM 讨论方向**：优先聚焦技术栈升级决策、Superchain 生态战略，不深入支付/用户增长。

---

## 推送配置

```
team_id: xlayer
emergency_threshold: OP Stack 安全漏洞 OR Superchain 重大成员退出 OR 竞品 L2 发布颠覆性技术
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
