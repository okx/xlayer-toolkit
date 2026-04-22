# Web3 信息源列表

> 最后全量更新: 2026-02-28
> 总计: 200+ 信息源（含 Twitter/X、GitHub、RSS/博客、数据&安全平台）
> 维护方: web3-sources skill

---

## Teams 标签说明

每个信息源的 `teams` 列表明该信息源与哪些团队业务线直接相关：

| 标签 | 对应团队 |
|------|---------|
| `all` | 所有团队均采集 |
| `wallet` | OKX Wallet 团队专属关注 |
| `xlayer` | X Layer 团队专属关注 |
| `pay` | OKX Pay 团队专属关注 |
| `defi` | OKX DEX / DeFi 相关 |
| `dev` | Web3 开发者生态相关 |
| `growth` | Growth 团队关注 |

---

## 信息源类型说明

| 类型标识 | 采集方式 | 说明 |
|---------|---------|------|
| `twitter` | 浏览器导航到 x.com/@handle | 实时推文，需已登录 X.com |
| `github_release` | VM curl/WebFetch GitHub releases.atom | 协议/框架版本发布，VM 可直接访问 |
| `rss` | 浏览器 fetch() 抓取 RSS XML | 技术博客、研究论坛，通过浏览器走本机网络 |
| `data_api` | 浏览器 fetch() / WebFetch | L2 数据平台、安全监控，按需轮询 |

## 目录

**Twitter/X（1-11类）**
1. [主流公链官推](#1-主流公链官推)
2. [新兴项目](#2-新兴项目)
3. [核心开发者 & 技术领袖](#3-核心开发者--技术领袖)
4. [公司创始人 & CEO](#4-公司创始人--ceo)
5. [DeFi 协议](#5-defi-协议)
6. [钱包 & 基础设施](#6-钱包--基础设施)
7. [支付 & PayFi](#7-支付--payfi)
8. [开发者工具](#8-开发者工具)
9. [VC & 投资人](#9-vc--投资人)
10. [竞品交易所](#10-竞品交易所)
11. [行业媒体 & KOL](#11-行业媒体--kol)

**非 Twitter 信息源（12-14类）**

12. [GitHub Release 监控](#12-github-release-监控)
13. [RSS / 技术博客 & 研究论坛](#13-rss--技术博客--研究论坛)
14. [数据平台 & 安全监控](#14-数据平台--安全监控)

---

## 1. 主流公链官推

与 OKX Web3 钱包多链支持、X Layer 竞品分析直接相关。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @ethereum | Ethereum | 以太坊官方，OKX Web3 钱包核心支持链 | 1M+ | P0 | all | 2026-02-27 |
| @solana | Solana | Solana 官方，OKX 重点支持的高性能链 | 1M+ | P0 | all | 2026-02-27 |
| @base | Base | Coinbase L2，X Layer 直接竞品 | 500K+ | P0 | xlayer,wallet | 2026-02-27 |
| @arbitrum | Arbitrum | 头部 L2，X Layer 竞品 | 500K+ | P0 | xlayer | 2026-02-27 |
| @optimism | Optimism | OP Stack L2，X Layer 上游依赖 | 500K+ | P0 | xlayer | 2026-02-27 |
| @0xPolygon | Polygon | X Layer 前技术依赖方（已迁移至 OP Stack） | 1M+ | P1 | xlayer | 2026-02-27 |
| @avax | Avalanche | 高性能 L1，OKX 钱包支持 | 500K+ | P1 | wallet | 2026-02-27 |
| @BNBCHAIN | BNB Chain | 币安链，竞品交易所生态链 | 500K+ | P1 | all | 2026-02-27 |
| @SuiNetwork | Sui | Move 系 L1，新兴热门链 | 100K+ | P1 | wallet,growth | 2026-02-27 |
| @Aptos | Aptos | Move 系 L1，OKX 钱包已支持 | 500K+ | P1 | wallet | 2026-02-27 |
| @ton_blockchain | TON | Telegram 生态链，用户基数大 | 100K+ | P1 | pay,wallet | 2026-02-27 |
| @Starknet | Starknet | zkSTARK L2，ZK 赛道代表 | 100K+ | P1 | xlayer | 2026-02-27 |
| @Scroll_ZKP | Scroll | zkEVM L2，与 X Layer 同赛道 | 100K+ | P1 | xlayer | 2026-02-27 |
| @zksync | zkSync | zkEVM L2，ZK 赛道竞品 | 100K+ | P1 | xlayer | 2026-02-27 |
| @LineaBuild | Linea | ConsenSys 的 zkEVM L2 | 100K+ | P2 | xlayer | 2026-02-27 |
| @MantaNetwork | Manta Network | 模块化 L2，隐私计算方向 | 100K+ | P2 | xlayer | 2026-02-27 |
| @SeiNetwork | Sei | 高性能交易链 | 100K+ | P2 | wallet | 2026-02-27 |
| @CelestiaOrg | Celestia | 模块化区块链 DA 层 | 100K+ | P1 | xlayer | 2026-02-27 |

---

## 2. 新兴项目

近 1 年内上线或社区热度飙升的项目，潜在合作或上币标的。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @monad_xyz | Monad | 高性能 EVM 兼容 L1，2025 年热门项目 | 100K+ | P1 | xlayer,growth | 2026-02-27 |
| @berachain | Berachain | PoL 共识机制，DeFi 原生链 | 100K+ | P1 | defi,growth | 2026-02-27 |
| @movementlabsxyz | Movement | Move 语言 Rollup，跨生态桥梁 | 50K+ | P1 | xlayer,growth | 2026-02-27 |
| @MegaETH | MegaETH | 实时区块链，超高 TPS | 50K+ | P1 | xlayer | 2026-02-27 |
| @hyperlane | Hyperlane | 无许可跨链互操作协议 | 100K+ | P2 | wallet | 2026-02-27 |
| @eigenlayer | EigenLayer | 再质押协议，以太坊安全层 | 100K+ | P1 | defi | 2026-02-27 |
| @alt_layer | AltLayer | 模块化 Rollup-as-a-Service | 50K+ | P2 | xlayer | 2026-02-27 |
| @babylonlabs_io | Babylon | BTC 质押协议，Bitcoin DeFi | 50K+ | P1 | defi,growth | 2026-02-27 |
| @SonicSVM | Sonic SVM | 游戏专用 Solana VM | 50K+ | P2 | growth | 2026-02-27 |
| @EclipseFND | Eclipse | SVM 执行层 + 以太坊 DA | 50K+ | P2 | xlayer | 2026-02-27 |
| @farcaster_xyz | Farcaster | 去中心化社交协议，建立在 Optimism 上，Web3 开发者社区最活跃集散地，高质量技术讨论和早期项目信号 | 100K+ | P1 | dev,growth | 2026-02-27 |

---

## 3. 核心开发者 & 技术领袖

链和协议的核心技术贡献者，对技术趋势有第一手洞察。

| Handle | 姓名 | 角色 | 项目 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|------|------|----------|--------|-------|----------|
| @VitalikButerin | Vitalik Buterin | 联合创始人 | Ethereum | 以太坊核心思想领袖，技术路线制定者 | 5M+ | P0 | all | 2026-02-27 |
| @TimBeiko | Tim Beiko | 协议研发负责人 | Ethereum Foundation | 以太坊协议升级协调人 | 50K+ | P1 | xlayer,dev | 2026-02-27 |
| @peter_szilagyi | Péter Szilágyi | 核心开发者 | Ethereum (Geth) | Geth 客户端核心维护者 | 50K+ | P1 | xlayer,dev | 2026-02-27 |
| @aeyakovenko | Anatoly Yakovenko | 联合创始人 & CEO | Solana Labs | Solana 技术架构师 | 300K+ | P0 | all | 2026-02-27 |
| @rajgokal | Raj Gokal | 联合创始人 & COO | Solana Labs | Solana 生态发展 | 100K+ | P1 | growth | 2026-02-27 |
| @jessepollak | Jesse Pollak | 创建者 & 负责人 | Base | Base 链创建者，Coinbase 钱包负责人 | 100K+ | P0 | xlayer,wallet | 2026-02-27 |
| @EliBenSasson | Eli Ben-Sasson | 联合创始人 & CEO | StarkWare | zkSTARK 发明人，ZK 技术先驱 | 100K+ | P1 | xlayer | 2026-02-27 |
| @EdFelten | Ed Felten | 联合创始人 & 首席科学家 | Offchain Labs (Arbitrum) | Arbitrum 技术架构 | 50K+ | P1 | xlayer | 2026-02-27 |
| @gakonst | Georgios Konstantopoulos | CTO | Paradigm / Foundry | Foundry 开发框架创建者 | 100K+ | P1 | dev | 2026-02-27 |
| @SergeyNazarov | Sergey Nazarov | 联合创始人 | Chainlink | 预言机基础设施，DeFi 核心依赖 | 500K+ | P0 | defi,dev | 2026-02-27 |
| @sandeepnailwal | Sandeep Nailwal | 联合创始人 | Polygon | Polygon CDK = X Layer 前底层 | 100K+ | P1 | xlayer | 2026-02-27 |
| @jdkanani | Jaynti Kanani | 联合创始人 | Polygon | Polygon 技术架构 | 100K+ | P1 | xlayer | 2026-02-27 |
| @EvanCheng | Evan Cheng | 联合创始人 & CEO | Mysten Labs (Sui) | Sui 技术架构，前 Meta 工程副总裁 | 100K+ | P1 | wallet | 2026-02-27 |
| @AveryChing | Avery Ching | CTO | Aptos Labs | Aptos 技术负责人 | 50K+ | P1 | wallet | 2026-02-27 |
| @moshaikhs | Mo Shaikh | 联合创始人 & CEO | Aptos Labs | Aptos 生态战略 | 50K+ | P1 | wallet | 2026-02-27 |
| @gavofyork | Gavin Wood | 创始人 | Polkadot / Parity | 以太坊联合创始人，跨链先驱 | 250K+ | P1 | xlayer | 2026-02-27 |

---

## 4. 公司创始人 & CEO

头部 Web3 公司领导者，行业战略风向标。

| Handle | 姓名 | 角色 | 公司 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|------|------|----------|--------|-------|----------|
| @cz_binance | Changpeng Zhao (CZ) | 创始人 | Binance | 最大竞品交易所创始人 | 10M+ | P0 | all | 2026-02-27 |
| @_RichardTeng | Richard Teng | CEO | Binance | 现任币安 CEO，合规方向 | 500K+ | P0 | all | 2026-02-27 |
| @brian_armstrong | Brian Armstrong | CEO & 联合创始人 | Coinbase | Base 链母公司，美国最大合规交易所 | 1M+ | P0 | all | 2026-02-27 |
| @benbybit | Ben Zhou | 联合创始人 & CEO | Bybit | 头部竞品交易所 | 300K+ | P0 | all | 2026-02-27 |
| @paoloardoino | Paolo Ardoino | CEO | Tether | USDT 发行方 + tether.wallet 自托管钱包 | 1M+ | P0 | pay,wallet | 2026-04-15 |
| @jerallaire | Jeremy Allaire | 联合创始人 & CEO | Circle | USDC + Arc Network（稳定币原生 L1）+ AI Agent 基础设施 | 500K+ | P0 | pay,wallet,ai_agent | 2026-04-15 |
| @justinsuntron | Justin Sun | 创始人 | TRON / HTX | TRON 创始人，亚洲区重要人物 | 3M+ | P1 | all | 2026-02-27 |
| @ysiu | Yat Siu | 创始人 & 董事长 | Animoca Brands | Web3 游戏/NFT 领军人物，亚洲 Web3 代表 | 500K+ | P1 | growth | 2026-02-27 |
| @CryptoHayes | Arthur Hayes | 联合创始人 | BitMEX / 100x Group | 衍生品交易先驱，市场分析影响力大 | 500K+ | P1 | growth | 2026-02-27 |
| @haydenzadams | Hayden Adams | 创始人 | Uniswap | 最大 DEX 创始人，DeFi 标杆 | 300K+ | P0 | defi | 2026-02-27 |
| @StaniKulechov | Stani Kulechov | 创始人 & CEO | Aave | 最大借贷协议创始人 | 300K+ | P1 | defi | 2026-02-27 |
| @newmichwill | Michael Egorov | 创始人 | Curve Finance | 稳定币交换核心协议 | 100K+ | P1 | defi,pay | 2026-02-27 |
| @nikil | Nikil Viswanathan | 联合创始人 & CEO | Alchemy | Web3 开发平台领导者 | 100K+ | P1 | dev | 2026-02-27 |
| @AntonioMJuliano | Antonio Juliano | 创始人 & CEO | dYdX | 去中心化衍生品交易 | 50K+ | P1 | defi | 2026-02-27 |
| @jespow | Jesse Powell | 联合创始人 & 董事长 | Kraken | 老牌交易所 | 300K+ | P1 | all | 2026-02-27 |
| @durov | Pavel Durov | 创始人 | Telegram / TON | TON 生态核心，用户基数巨大 | 2M+ | P1 | pay,growth | 2026-02-27 |

---

## 5. DeFi 协议

OKX DEX 聚合、Web3 钱包 DeFi 入口的核心数据源。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @Uniswap | Uniswap | 最大 DEX，OKX DEX 聚合核心流动性来源 | 1M+ | P0 | defi,wallet | 2026-02-27 |
| @AaveAave | Aave | 最大借贷协议，DeFi 基础设施 | 500K+ | P0 | defi | 2026-02-27 |
| @LidoFinance | Lido Finance | 最大液态质押协议，ETH 质押核心 | 100K+ | P0 | defi | 2026-02-27 |
| @CurveFinance | Curve Finance | 稳定币交换核心，深度流动性 | 100K+ | P1 | defi,pay | 2026-02-27 |
| @MakerDAO | MakerDAO / Sky | DAI 稳定币，DeFi 借贷基础 | 100K+ | P1 | defi,pay | 2026-02-27 |
| @1inch | 1inch | DEX 聚合器，OKX DEX 聚合竞品 | 100K+ | P0 | defi | 2026-02-27 |
| @dydx | dYdX | 去中心化永续合约，OKX 合约竞品 | 100K+ | P1 | defi | 2026-02-27 |
| @GMX_IO | GMX | 去中心化永续合约 | 50K+ | P1 | defi | 2026-02-27 |
| @compoundfinance | Compound | 借贷协议先驱 | 100K+ | P2 | defi | 2026-02-27 |
| @RaydiumProtocol | Raydium | Solana 最大 AMM DEX | 100K+ | P1 | defi | 2026-02-27 |
| @orca_so | Orca | Solana DEX，用户体验好 | 50K+ | P2 | defi | 2026-02-27 |
| @PancakeSwap | PancakeSwap | BSC 最大 DEX | 100K+ | P1 | defi | 2026-02-27 |
| @SynthetixIO | Synthetix | 合成资产协议 | 100K+ | P2 | defi | 2026-02-27 |
| @Balancer | Balancer | 可编程流动性 AMM | 100K+ | P2 | defi | 2026-02-27 |
| @pendle_fi | Pendle | 收益代币化协议，DeFi 创新代表 | 100K+ | P1 | defi | 2026-02-27 |
| @JupiterExchange | Jupiter | Solana DEX 聚合器，Solana DeFi 核心 | 100K+ | P0 | defi | 2026-02-27 |
| @StargateFinance | Stargate Finance | 跨链桥协议，LayerZero 生态 | 100K+ | P1 | wallet,defi | 2026-02-27 |
| @ethena_fi | Ethena | USDe 合成美元协议，新兴稳定币 | 100K+ | P1 | defi,pay | 2026-02-27 |
| @HyperliquidX | Hyperliquid | 去中心化永续合约 DEX，2026年1月超越 Binance BTC 流动性深度，MetaMask 已集成，OKX DEX 直接竞品 | 500K+ | P0 | defi | 2026-02-27 |

---

## 6. 钱包 & 基础设施

Web3 钱包竞品和核心基础设施服务商。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @MetaMask | MetaMask | 最大浏览器钱包，OKX Web3 钱包核心竞品 | 1M+ | P0 | wallet | 2026-02-27 |
| @phantom | Phantom | 多链钱包，Solana 生态领先 | 500K+ | P0 | wallet | 2026-02-27 |
| @ledger | Ledger | 硬件钱包领导者 | 500K+ | P1 | wallet | 2026-02-27 |
| @Trezor | Trezor | 硬件钱包竞品 | 100K+ | P2 | wallet | 2026-02-27 |
| @safe | Safe (Gnosis Safe) | 多签钱包，机构标准 | 100K+ | P1 | wallet | 2026-02-27 |
| @rainbowdotme | Rainbow Wallet | 移动端钱包竞品 | 50K+ | P2 | wallet | 2026-02-27 |
| @Chainlink | Chainlink | 预言机龙头，DeFi 基础设施 | 1M+ | P0 | defi,dev | 2026-02-27 |
| @LayerZero_Labs | LayerZero | 全链互操作协议，跨链基础设施 | 100K+ | P1 | wallet,xlayer | 2026-02-27 |
| @wormhole | Wormhole | 跨链桥协议 | 100K+ | P1 | wallet | 2026-02-27 |
| @the_graph | The Graph | 链上数据索引，开发者基础设施 | 100K+ | P1 | dev | 2026-02-27 |
| @_SEAL_Org | Security Alliance (SEAL) | Web3 安全联盟，MetaMask 和 Phantom 均已加入其实时钓鱼防护网络，负责安全事件响应和威胁情报共享 | 50K+ | P1 | wallet | 2026-02-27 |
| @BackpackExchange | Backpack | 多链钱包+交易所，BPM Profile 列为竞品钱包 | 100K+ | P1 | wallet | 2026-04-15 |

---

## 7. 支付 & PayFi

与 OKX Pay 直接相关的支付解决方案和稳定币项目。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @Tether_to | Tether | USDT 发行方，最大稳定币；已发布 tether.wallet 自托管钱包，正式成为钱包竞品 | 1M+ | P0 | pay,wallet | 2026-04-15 |
| @circle | Circle | USDC 发行方，合规稳定币；Arc Network（稳定币原生 L1）+ AI Agent 基础设施战略 | 100K+ | P0 | pay,wallet,ai_agent | 2026-04-15 |
| @moonpay | MoonPay | 法币出入金服务商 | 100K+ | P1 | pay | 2026-02-27 |
| @transak | Transak | 法币出入金聚合器 | 50K+ | P2 | pay | 2026-02-27 |
| @OndoFinance | Ondo Finance | RWA 代币化，机构级 DeFi | 50K+ | P1 | pay,defi | 2026-02-27 |
| @PayPal | PayPal | 传统支付巨头的加密布局 | 1M+ | P1 | pay | 2026-02-27 |
| @stripe | Stripe | 支付基础设施，加密支付整合 | 1M+ | P1 | pay | 2026-02-27 |
| @tempo | Tempo (Stripe) | Stripe 旗下 Agent 商务 L1 区块链，Visa/渣打 Zodia 已加入验证者 | 10K+ | P1 | pay,wallet,ai_agent | 2026-04-15 |
| @fraxfinance | Frax Finance | 混合稳定币协议 | 50K+ | P2 | pay,defi | 2026-02-27 |
| @Edenaofficial | EDENA Capital | 全球 STO 交易所，机构级 RWA 代币化（房产/碳信用/REIT），zkSync ZK 基础设施深度集成，$2亿代币化额度 | 10K+ | P1 | pay,xlayer | 2026-02-28 |

---

## 8. 开发者工具

Web3 开发者生态相关，对 OKX 开发者关系和 X Layer 开发者拉新至关重要。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @AlchemyPlatform | Alchemy | Web3 开发平台，RPC & API | 100K+ | P0 | dev,xlayer | 2026-02-27 |
| @infura_io | Infura | 以太坊 RPC 服务商 | 100K+ | P1 | dev | 2026-02-27 |
| @HardhatHQ | Hardhat | 以太坊开发框架 | 50K+ | P1 | dev | 2026-02-27 |
| @getfoundry_sh | Foundry | Rust 开发框架，性能优先 | 50K+ | P1 | dev,xlayer | 2026-02-27 |
| @wevm_dev | Viem / Wagmi | TypeScript Web3 库 | 50K+ | P1 | dev | 2026-02-27 |
| @ethersproject | Ethers.js | JavaScript Web3 库 | 50K+ | P2 | dev | 2026-02-27 |
| @OpenZeppelin | OpenZeppelin | 智能合约安全库 | 100K+ | P1 | dev,xlayer | 2026-02-27 |
| @DuneAnalytics | Dune Analytics | 链上数据分析平台 | 100K+ | P1 | dev | 2026-02-27 |
| @nansen_ai | Nansen | 链上数据智能平台 | 100K+ | P1 | dev,growth | 2026-02-27 |
| @DefiLlama | DefiLlama | DeFi TVL 追踪，行业标准数据 | 100K+ | P0 | defi,dev | 2026-02-27 |
| @TenderlyApp | Tenderly | 智能合约调试 & 模拟 | 50K+ | P2 | dev | 2026-02-27 |

---

## 9. VC & 投资人

加密 VC 和知名投资人，投资趋势是项目发现的领先指标。

| Handle | 姓名/名称 | 角色 | 机构 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|-----------|------|------|------|----------|--------|-------|----------|
| @a16zcrypto | a16z crypto | 机构账号 | a16z | 头部加密 VC，投资风向标 | 500K+ | P0 | all | 2026-02-27 |
| @cdixon | Chris Dixon | 管理合伙人 | a16z crypto | 加密投资思想领袖 | 500K+ | P0 | all | 2026-02-27 |
| @matthuang | Matt Huang | 联合创始人 | Paradigm | 头部加密 VC 领导者 | 200K+ | P0 | all | 2026-02-27 |
| @FEhrsam | Fred Ehrsam | 联合创始人 | Paradigm | Coinbase 联合创始人，投资策略 | 200K+ | P1 | all | 2026-02-27 |
| @danrobinson | Dan Robinson | 研究合伙人 | Paradigm | DeFi 研究先驱 | 100K+ | P1 | defi | 2026-02-27 |
| @hasufl | Hasu | 策略主管 | Flashbots | MEV 研究，加密经济学 | 300K+ | P1 | defi | 2026-02-27 |
| @KyleSamani | Kyle Samani | 联合创始人 | Multicoin Capital | Solana 生态早期投资者 | 300K+ | P1 | growth | 2026-02-27 |
| @DoveyWan | Dovey Wan | 创始人 | Primitive Ventures | 中国/亚洲加密投资，OKX 文化圈 | 300K+ | P0 | all | 2026-02-27 |
| @Rewkang | Andrew Kang | 合伙人 | Mechanism Capital | 加密市场分析，交易策略 | 200K+ | P1 | growth | 2026-02-27 |
| @RaoulGMI | Raoul Pal | CEO & 创始人 | Real Vision | 宏观分析师，加密宏观叙事 | 1M+ | P1 | growth | 2026-02-27 |
| @balajis | Balaji Srinivasan | 天使投资人 | 独立 | 加密哲学，技术趋势预测 | 500K+ | P1 | all | 2026-02-27 |
| @pythianism | Vance Spencer | 联合创始人 | Framework Ventures | DeFi 投资专注 | 100K+ | P2 | defi | 2026-02-27 |

---

## 10. 竞品交易所

OKX 直接竞品的官方账号和核心高管。

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @binance | Binance | 最大竞品，全球市场份额第一 | 10M+ | P0 | all | 2026-02-27 |
| @coinbase | Coinbase | 美国最大合规交易所，Base 链母公司 | 1M+ | P0 | all | 2026-02-27 |
| @Bybit_Official | Bybit | 亚洲核心竞品 | 500K+ | P0 | all | 2026-02-27 |
| @krakenfx | Kraken | 老牌交易所，美国市场 | 500K+ | P1 | all | 2026-02-27 |
| @kucoincom | KuCoin | 中型交易所竞品 | 500K+ | P1 | all | 2026-02-27 |
| @Bitget_Official | Bitget | 亚洲竞品，合约交易 | 500K+ | P1 | all | 2026-02-27 |
| @gate_io | Gate.io | 中型交易所竞品 | 100K+ | P2 | all | 2026-02-27 |
| @mexc_global | MEXC | 中型交易所竞品 | 100K+ | P2 | all | 2026-02-27 |

---

## 11. 行业媒体 & KOL

行业舆情监控、内容合作、市场情绪感知。

### 媒体 & 研究机构

| Handle | 名称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|------|------|----------|--------|-------|----------|
| @TheBlock__ | The Block | 头部加密媒体，独家新闻 | 500K+ | P0 | all | 2026-02-27 |
| @CoinDesk | CoinDesk | 老牌加密媒体 | 1M+ | P0 | all | 2026-02-27 |
| @Cointelegraph | Cointelegraph | 全球加密新闻 | 1M+ | P1 | all | 2026-02-27 |
| @BanklessHQ | Bankless | DeFi/以太坊生态媒体 | 500K+ | P1 | defi,xlayer | 2026-02-27 |
| @MessariCrypto | Messari | 加密研究 & 数据 | 100K+ | P1 | all | 2026-02-27 |
| @glassnode | Glassnode | 链上数据分析 | 500K+ | P1 | all | 2026-02-27 |
| @WuBlockchain | 吴说区块链 (Wu Blockchain) | 中文圈第一加密媒体，OKX 高度相关 | 100K+ | P0 | all | 2026-02-27 |
| @BlockBeatsAsia | 律动 BlockBeats | 中文加密媒体 | 50K+ | P1 | all | 2026-02-27 |

### 影响力 KOL

| Handle | 姓名/昵称 | 说明 | 粉丝量级 | 优先级 | teams | 最后验证 |
|--------|-----------|------|----------|--------|-------|----------|
| @aantonop | Andreas Antonopoulos | 比特币教育家，行业布道者 | 500K+ | P1 | growth | 2026-02-27 |
| @RyanSAdams | Ryan Sean Adams | Bankless 创始人，以太坊 KOL | 400K+ | P1 | growth | 2026-02-27 |
| @cobie | Cobie | 加密交易员 & 评论员，社区影响力大 | 250K+ | P1 | growth | 2026-02-27 |
| @DegenSpartan | DegenSpartan | 匿名 DeFi KOL，市场情绪指标 | 100K+ | P2 | defi | 2026-02-27 |
| @ZachXBT | ZachXBT | 链上侦探，安全 & 欺诈调查 | 500K+ | P0 | all | 2026-02-27 |
| @lookonchain | Lookonchain | 链上数据分析 KOL | 100K+ | P1 | all | 2026-02-27 |
| @EmberCN | Ember（余烬） | 中文链上分析 KOL | 100K+ | P1 | all | 2026-02-27 |

---

---

## 12. GitHub Release 监控

协议和框架的版本发布，是技术变更最早的第一手信号，比 Twitter 公告提前 12-48 小时。**按 OKX 四条业务线分组覆盖。**

**采集方式**：VM `curl -s "{repo}/releases.atom"`，取最近 5 条，过滤 48 小时内发布的。VM 可直接访问 GitHub，无需代理。

### OKX Wallet（多链钱包、账户抽象、DApp 接入）

| 仓库 | 名称 | 说明 | 优先级 | teams |
|------|------|------|--------|-------|
| MetaMask/metamask-extension | MetaMask Extension | 最大竞品钱包，版本变化即竞品情报 | P0 | wallet |
| WalletConnect/walletconnect-monorepo | WalletConnect | 钱包连接标准，DApp 接入层基础协议 | P0 | wallet,dev |
| eth-infinitism/account-abstraction | ERC-4337 AA | 账户抽象标准参考实现，Smart Account 基础 | P0 | wallet,xlayer |
| wevm/viem | viem | 主流 TypeScript Web3 库，钱包 SDK 底层 | P1 | wallet,dev |
| wevm/wagmi | wagmi | React Web3 钩子库，前端 DApp 标准 | P1 | wallet,dev |
| safe-global/safe-smart-account | Safe Smart Account | 多签账户合约，机构钱包标准 | P1 | wallet |

### X Layer / L2（OP Stack、ZK、DA 层）

| 仓库 | 名称 | 说明 | 优先级 | teams |
|------|------|------|--------|-------|
| ethereum-optimism/optimism | OP Stack Core | X Layer 直接依赖，op-node / op-proposer 核心组件 | P0 | xlayer |
| ethereum-optimism/op-geth | op-geth | OP Stack go-ethereum fork，L2 执行层 | P0 | xlayer |
| matter-labs/zksync-era | zkSync Era | ZK Rollup 竞品，ZK 证明系统参考 | P0 | xlayer |
| ethereum/consensus-specs | Ethereum Consensus Specs | 以太坊共识层规范，影响 L2 最终性设计 | P0 | xlayer,dev |
| ethereum-optimism/superchain-registry | Superchain Registry | Superchain 成员链注册动态 | P1 | xlayer |
| celestiaorg/celestia-node | Celestia Node | DA 层核心实现，模块化 L2 基础 | P1 | xlayer |
| Layr-Labs/eigenlayer-contracts | EigenLayer Contracts | 再质押协议，影响 L2 安全设计 | P1 | xlayer,defi |
| starkware-libs/cairo | Cairo Language | ZK 证明语言，ZK 技术研究参考 | P1 | xlayer,dev |

### OKX Pay（稳定币、跨链支付、法币通道）

| 仓库 | 名称 | 说明 | 优先级 | teams |
|------|------|------|--------|-------|
| circlefin/evm-cctp-contracts | Circle CCTP | 跨链稳定币协议核心合约，OKX Pay 跨链通道依赖 | P0 | pay |
| ethereum/EIPs | Ethereum EIPs | 支付相关 EIP 状态变更（EIP-3643 RWA、EIP-7540 异步保险库、ERC-20 Payment Streams） | P0 | pay,xlayer,dev |
| makerdao/dss | MakerDAO DSS | DAI/USDS 合约，最大去中心化稳定币核心逻辑变更 | P1 | pay,defi |
| ethena-labs/ethena-contracts | Ethena Contracts | USDe 合成美元协议，新兴稳定币竞品 | P1 | pay,defi |

### Agent Payment / MPP（链上支付协议）

| 仓库 | 名称 | 说明 | 优先级 | teams |
|------|------|------|--------|-------|
| solana-foundation/mpp-specs | MPP Specification | Machine Payment Protocol 规范定义，Agent 支付协议标准 | P0 | ai_agent,pay |
| solana-foundation/mpp-sdk | MPP SDK | MPP 官方 SDK，session/charge intent 实现 | P0 | ai_agent,pay |
| solana-foundation/fiber | Fiber | Solana 链级支付通道优化研究，targeting MPP session | P1 | ai_agent,pay |
| coinbase/x402 | x402 Protocol | Coinbase x402 HTTP 支付协议，Agent 微支付标准 | P0 | ai_agent,pay |

### Web3 开发者 / 全业务线安全

| 仓库 | 名称 | 说明 | 优先级 | teams |
|------|------|------|--------|-------|
| OpenZeppelin/openzeppelin-contracts | OpenZeppelin Contracts | 智能合约安全库，漏洞影响全业务线合约 | P0 | dev,all |
| foundry-rs/foundry | Foundry | 主流 Rust 智能合约开发框架 | P0 | dev,xlayer |
| NomicFoundation/hardhat | Hardhat | 以太坊开发框架，插件生态丰富 | P1 | dev |
| graphprotocol/graph-node | The Graph Node | 链上数据索引协议，DApp 查询基础设施 | P1 | dev |
| smartcontractkit/chainlink | Chainlink | 预言机合约，DeFi/Pay 数据来源 | P1 | dev,defi,pay |

---

## 13. RSS / 技术博客 & 研究论坛

技术深度和信噪比最高的文字信息源。**按 OKX 四条业务线分组覆盖。**

**采集方式**：浏览器 `fetch()` 解析 RSS/Atom XML，取最近 7 天内发布的条目（VM 代理拦截外部 URL，必须通过浏览器本机网络）。

### 全业务线共用（协议基础 & 行业综合）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| Ethereum Blog | 以太坊基金会官方博客，协议升级第一手 | P0 | all | https://blog.ethereum.org/feed.xml |
| Vitalik's Blog | Vitalik 长文分析，密码学/协议设计/社会思考 | P0 | all | https://vitalik.eth.limo/feed.xml |
| Rekt News | DeFi/链上安全事件专项追踪，每次黑客攻击必报 | P0 | all | https://rekt.news/rss/ |
| The Block Research | 机构级研究报告，覆盖全业务线 | P0 | all | https://www.theblock.co/rss.xml |
| The Defiant | DeFi/L2/监管/支付高质量日报 | P1 | all | https://thedefiant.io/feed |
| a16z Crypto Blog | 头部 VC 研究，技术趋势与监管判断 | P1 | all | https://a16zcrypto.com/posts/feed/ |
| Paradigm Research | 顶级加密研究，密码学/DeFi/协议设计前沿 | P1 | all | https://www.paradigm.xyz/blog/rss.xml |

### OKX Wallet（钱包安全、账户抽象、竞品动态）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| MetaMask Blog | 竞品钱包功能发布，含 SDK/Snaps 生态更新 | P0 | wallet | https://medium.com/feed/metamask |
| WalletConnect Blog | 钱包连接标准更新，DApp 接入协议变化 | P1 | wallet,dev | https://medium.com/feed/walletconnect |
| Immunefi Disclosures | 漏洞披露，覆盖主流钱包合约安全问题 | P1 | wallet,xlayer | https://medium.com/feed/immunefi |
| Halborn Security Blog | Web3 安全审计报告，钱包/桥接漏洞分析 | P1 | wallet,xlayer | https://www.halborn.com/blog/feed |

### X Layer / L2（协议升级、竞品 Rollup、ZK 研究）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| ethresear.ch | 以太坊研究论坛，EIP/L2 技术提案比 Twitter 早数周 | P0 | xlayer,dev | https://ethresear.ch/latest.rss |
| Ethereum Magicians | EIP 流程推进核心论坛，标准化讨论 | P0 | xlayer,dev | https://ethereum-magicians.org/latest.rss |
| L2Beat Blog | L2 安全/去中心化/TVL 深度分析，行业标准参考 | P0 | xlayer | https://l2beat.com/blog/feed.xml |
| Arbitrum Blog (Offchain Labs) | Arbitrum 技术博客，竞品 L2 第一手动态 | P0 | xlayer | https://medium.com/feed/@offchain_labs |
| Optimism Blog | OP Stack 技术更新，X Layer 上游依赖 | P0 | xlayer | https://optimism.mirror.xyz/feed.rss |
| zkSync Blog | ZK Rollup 竞品深度，Matter Labs 研究 | P1 | xlayer | https://medium.com/feed/matter-labs |
| StarkWare Blog | ZK 证明技术前沿，STARK/Cairo 动态 | P1 | xlayer | https://medium.com/feed/starkware |
| Week in Ethereum News | 以太坊生态权威周报，EIP/研究/工具更新汇总 | P1 | xlayer,dev | https://weekinethereumnews.com/feed/ |

### OKX Pay（稳定币、支付基础设施、监管）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| Circle Blog | USDC 发行方官方博客，稳定币监管/技术动态 | P0 | pay | https://www.circle.com/blog/rss |
| MakerDAO/Sky Blog | DAI/USDS 稳定币机制更新，DeFi 支付研究 | P1 | pay,defi | https://medium.com/feed/makerdao |
| Coinbase Blog (Payments) | Coinbase 支付/合规动态，Base 链支付场景 | P1 | pay | https://www.coinbase.com/blog/rss |
| BIS Research (加密支付) | 国际清算银行 CBDC/稳定币研究，监管走向领先指标 | P1 | pay | https://www.bis.org/rss/topics/crypto.xml |

### Web3 开发者（工具链、SDK、开发者生态）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| Solidity Blog | Solidity 语言官方博客，编译器版本和安全公告 | P0 | dev | https://blog.soliditylang.org/feed.xml |
| OpenZeppelin Blog | 智能合约安全最佳实践，审计发现和工具更新 | P0 | dev,all | https://blog.openzeppelin.com/feed |
| The Graph Blog | 链上数据索引协议更新，DApp 查询基础设施 | P1 | dev | https://thegraph.com/blog/feed.xml |
| Bankless Dev | 面向开发者的以太坊生态深度内容 | P1 | dev,xlayer | https://banklesshq.com/rss/ |

### BPM 业务线新增（竞品钱包、AA/智能账户、Agent 支付、Agent+DeFi）

| 名称 | 说明 | 优先级 | teams | RSS URL |
|------|------|--------|-------|---------|
| Phantom Blog | 竞品多链钱包官方博客，功能发布与产品更新 | P0 | wallet,ai_agent | https://phantom.com/blog/rss.xml |
| Rainbow Blog | 竞品钱包官方博客，钱包 UX 创新与多链支持 | P0 | wallet,ai_agent | https://rainbow.me/blog/rss.xml |
| Safe Blog | Safe (Gnosis Safe) 官方博客，多签/智能账户标准与生态 | P0 | wallet,ai_agent | https://safe.global/blog/rss.xml |
| Ithaca Updates | Ithaca (Odyssey) 团队博客，ERC-7702 参考实现与智能账户标准前沿 | P0 | wallet,ai_agent | https://ithaca.xyz/blog/rss.xml |
| Biconomy Blog | AA SDK/Paymaster/Bundler 产品更新，智能账户基础设施标杆 | P0 | wallet,ai_agent | https://www.biconomy.io/blog/rss.xml |
| ZeroDev Blog | Kernel 智能账户框架，SessionKey/权限委派等 AA 原语更新 | P0 | wallet,ai_agent | https://zerodev.app/blog/rss.xml |
| Tempo Blog | Tempo 官方博客，MPP/x402/Agent Payment 协议更新 | P0 | ai_agent,pay | https://docs.tempo.xyz/blog/rss.xml |
| Stripe Engineering | Stripe 工程博客，AI Agent 支付集成与稳定币支付基础设施 | P1 | ai_agent,pay | https://stripe.com/blog/engineering/rss.xml |
| Morpho Blog | 模块化借贷协议官方博客，AI Agent 链上执行潜在集成目标 | P1 | ai_agent,wallet | https://morpho.org/blog/rss.xml |
| Polymarket Blog | 预测市场官方博客，钱包内嵌事件合约交易参考 | P1 | wallet,ai_agent | https://polymarket.com/blog/rss.xml |
| Binance Blog | 竞品交易所官方博客，Web3 钱包与生态动态 | P0 | wallet,ai_agent | https://www.binance.com/en/blog/rss |

---

## 14. 数据平台 & 安全监控

实时链上数据，是推文内容的客观验证层，也是识别异常的领先指标。**按需采集，非每次常规运行都执行（开销较大）。**

**采集方式**：浏览器 WebFetch 定向页面快照，或调用平台公开 API（无需鉴权）。所有采集渠道默认全开，按需执行。

### OKX Wallet 相关（钱包市占率、DApp 生态）

| 名称 | 说明 | 优先级 | teams | 采集方式 |
|------|------|--------|-------|---------|
| DappRadar | DApp 用户活跃度排名，钱包 DApp 生态健康度指标 | P1 | wallet,growth | https://dappradar.com/rankings（WebFetch）|
| Artemis.xyz | 链上协议用户/收入数据，钱包竞品对比 | P1 | wallet,xlayer | https://app.artemis.xyz/（WebFetch）|

### X Layer / L2 相关（TVL、性能、安全评级）

| 名称 | 说明 | 优先级 | teams | 采集方式 |
|------|------|--------|-------|---------|
| L2Beat | L2 安全评级、TVL 排名、去中心化进度，行业标准 | P0 | xlayer | https://l2beat.com/scaling/summary（WebFetch）|
| GrowThePie | 专注 L2 指标：TPS、Gas 费、DAU、跨链量 | P0 | xlayer | https://www.growthepie.xyz/（WebFetch）|
| DefiLlama | DeFi TVL 全链聚合，判断 L2 生态资金流向 | P1 | xlayer,defi | https://defillama.com/chains（WebFetch）|

### OKX Pay 相关（稳定币流通、支付量）

| 名称 | 说明 | 优先级 | teams | 采集方式 |
|------|------|--------|-------|---------|
| Stable.fish | 稳定币供应量/流通量实时追踪，USDC/USDT/DAI 对比 | P0 | pay | https://stable.fish/（WebFetch）|
| Visa Onchain Analytics | Visa 官方稳定币链上支付数据看板 | P0 | pay | https://visaonchainanalytics.com/（WebFetch）|
| Token Terminal | 协议收入/费用对比，PayFi 协议业务健康度 | P1 | pay,defi | https://tokenterminal.com/（WebFetch）|

### 全业务线安全监控

| 名称 | 说明 | 优先级 | teams | 采集方式 |
|------|------|--------|-------|---------|
| SlowMist Hacked | 最全链上安全事件数据库，中文市场覆盖好 | P0 | all | https://hacked.slowmist.io/（WebFetch）|
| Immunefi Bug Bounty | 主流协议漏洞披露，影响全业务线合约安全 | P0 | all | https://immunefi.com/explore/（WebFetch）|
| Certik Skynet | 全链安全评分和实时事件流 | P1 | all | https://skynet.certik.com/（WebFetch）|
| Forta Network | 链上实时威胁检测，机器人级别的异常监控 | P1 | xlayer,wallet | https://explorer.forta.network/（WebFetch）|

---

## 统计摘要

| 类别 | 类型 | 数量 | P0 | P1 | P2 | 主要覆盖业务线 |
|------|------|------|----|----|-----|--------------|
| 1. 主流公链 | twitter | 18 | 6 | 9 | 3 | all |
| 2. 新兴项目 | twitter | 11 | 0 | 7 | 4 | xlayer,growth |
| 3. 核心开发者 | twitter | 16 | 4 | 12 | 0 | all |
| 4. 创始人/CEO | twitter | 16 | 7 | 9 | 0 | all |
| 5. DeFi 协议 | twitter | 19 | 5 | 10 | 4 | defi,pay |
| 6. 钱包/基础设施 | twitter | 11 | 3 | 6 | 2 | wallet |
| 7. 支付/PayFi | twitter | 9 | 2 | 5 | 2 | pay |
| 8. 开发者工具 | twitter | 11 | 2 | 7 | 2 | dev |
| 9. VC/投资人 | twitter | 12 | 3 | 8 | 1 | all |
| 10. 竞品交易所 | twitter | 8 | 3 | 3 | 2 | all |
| 11. 媒体/KOL | twitter | 15 | 3 | 9 | 3 | all |
| 12. GitHub Release | github_release | 28 | 12 | 16 | 0 | wallet/xlayer/pay/dev/ai_agent 各组 |
| 13. RSS/技术博客 | rss | 41 | 18 | 23 | 0 | wallet/xlayer/pay/dev/ai_agent 各组 |
| 14. 数据平台&安全 | data_api | 12 | 6 | 6 | 0 | wallet/xlayer/pay/all 各组 |
| **总计** | — | **227** | **74** | **130** | **23** | — |

> 最近更新（2026-04-14）：
> - **Agent Payment/MPP GitHub 监控**：新增 4 个 GitHub 仓库（solana-foundation/mpp-specs、mpp-sdk、fiber，coinbase/x402），覆盖 Agent 支付协议核心生态，GitHub 从 24 增至 28，总信息源从 223 增至 227。
>
> 历史更新（2026-04-13）：
> - **BPM 业务线 RSS 扩充**：新增 11 个 RSS 订阅源，覆盖竞品钱包官博（Phantom/Rainbow/Safe）、AA/智能账户标准（Ithaca/Biconomy/ZeroDev）、Agent 支付（Tempo/Stripe）、Agent+DeFi（Morpho/Polymarket）、竞品交易所（Binance），RSS 从 30 个增至 41 个，总信息源从 212 增至 223。
>
> 历史更新（2026-02-28）：
> - **重构非 Twitter 信源（类别 12-14）**：从 XLayer 单线覆盖扩展为按 OKX 四条业务线（Wallet / X Layer / Pay / Dev）分组覆盖，GitHub 仓库从 12 个增至 24 个，RSS 从 22 个增至 30 个，数据平台从 9 个增至 12 个。
> - **Intel-Driven 新增**：[@Edenaofficial](https://x.com/Edenaofficial)（EDENA Capital，机构级 RWA STO，zkSync ZK 基础设施集成，发现于 XLayer 流水线运行）→ P1 / pay,xlayer
