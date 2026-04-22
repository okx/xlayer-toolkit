# 自定义信息源参考库

> 由 OKX Wallet BPM 维护的高质量自定义信息源，供 `/start` 向导 AI 自动匹配推荐。
> 每条信息源均经过人工验证：内容活跃、信噪比高、与 Web3 业务直接相关。
>
> **使用规则**：Phase 3 中，根据团队描述语义匹配 `topics` 标签，选取相关性 ≥ 0.6 的条目（最多 8 条，优先 P0），生成 `{CUSTOM_SOURCES}` 表格行。

---

## 格式说明

每条来源包含：
- **URL**：直接可访问的 URL
- **描述**：简短中文描述（10字以内）
- **类型**：`rss` / `webpage` / `github_release` / `eip_tracker`
- **优先级**：`P0`（核心必看）/ `P1`（按需）
- **topics**：匹配标签列表（用于 AI 自动选取）

---

## EIP / 标准提案追踪

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://eips.ethereum.org/all | 以太坊 EIP 全量列表 | eip_tracker | P0 | eip, ethereum, standards, defi, wallet, xlayer, developer |
| https://ethereum-magicians.org/latest.json | Ethereum Magicians 论坛 | rss | P0 | eip, ethereum, standards, developer, xlayer |
| https://ercs.ethereum.org/ | ERC 标准追踪 | eip_tracker | P0 | eip, standards, wallet, developer, defi |
| https://github.com/ethereum/EIPs/releases | EIP 仓库 Release | github_release | P1 | eip, ethereum, developer |

---

## 深度技术博客 & 研究

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://vitalik.eth.limo/feed.xml | Vitalik 个人博客 | rss | P0 | ethereum, eip, research, defi, wallet, xlayer, developer |
| https://www.paradigm.xyz/feed.xml | Paradigm 研究报告 | rss | P0 | defi, research, wallet, xlayer, developer, security |
| https://a16zcrypto.com/posts/feed/ | a16z Crypto 研究 | rss | P0 | research, wallet, defi, growth, regulatory |
| https://blog.ethereum.org/feed.xml | 以太坊基金会博客 | rss | P0 | ethereum, xlayer, eip, developer, standards |
| https://mirror.xyz/optimismfoundation.eth/rss | Optimism 官方博客 | rss | P1 | xlayer, l2, ethereum |
| https://www.coinbase.com/blog/rss.xml | Coinbase 技术博客 | rss | P1 | wallet, pay, regulatory, growth |
| https://blog.uniswap.org/rss.xml | Uniswap 官方博客 | rss | P0 | defi, dex, wallet |
| https://research.2077.xyz/rss.xml | 2077 Research | rss | P1 | ethereum, xlayer, eip, developer, research |
| https://scroll.io/blog/rss.xml | Scroll 技术博客 | rss | P1 | xlayer, l2, zk |
| https://www.zkresear.ch/feed | ZK Research | rss | P1 | xlayer, zk, developer, research |

---

## DeFi 协议 & 数据分析

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://governance.aave.com/latest.json | Aave 治理论坛 | rss | P0 | defi, governance, security, wallet |
| https://gov.uniswap.org/latest.json | Uniswap 治理论坛 | rss | P0 | defi, dex, governance |
| https://research.lido.fi/latest.json | Lido 研究论坛 | rss | P1 | defi, staking, wallet |
| https://www.comp.xyz/latest.json | Compound 治理 | rss | P1 | defi, governance |
| https://forum.makerdao.com/latest.json | MakerDAO 论坛 | rss | P1 | defi, stablecoin, pay, governance |
| https://defillama.com/blog/rss.xml | DefiLlama 分析博客 | rss | P1 | defi, data, growth, dex |

---

## L2 / 跨链 / 基础设施

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://l2beat.com/blog/rss.xml | L2Beat 分析报告 | rss | P0 | xlayer, l2, security, research |
| https://www.growthepie.xyz/blog/rss.xml | GrowThePie L2 数据 | rss | P1 | xlayer, l2, data, growth |
| https://github.com/ethereum-optimism/optimism/releases | Optimism 客户端 Release | github_release | P0 | xlayer, l2, developer |
| https://github.com/OffchainLabs/nitro/releases | Arbitrum Nitro Release | github_release | P1 | xlayer, l2, developer |
| https://github.com/matter-labs/zksync-era/releases | zkSync Era Release | github_release | P1 | xlayer, zk, developer |
| https://github.com/scroll-tech/scroll/releases | Scroll Release | github_release | P1 | xlayer, zk, developer |
| https://github.com/celestiaorg/celestia-node/releases | Celestia Node Release | github_release | P1 | xlayer, l2, developer |

---

## 钱包 & AA / 账户抽象

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://github.com/eth-infinitism/account-abstraction/releases | ERC-4337 AA Release | github_release | P0 | wallet, aa, developer, eip |
| https://erc4337.io/feed.xml | ERC-4337 生态进展 | rss | P0 | wallet, aa, developer |
| https://github.com/wevm/viem/releases | Viem 前端库 Release | github_release | P1 | wallet, developer |
| https://github.com/wagmi-dev/wagmi/releases | Wagmi Release | github_release | P1 | wallet, developer |
| https://github.com/WalletConnect/walletconnect-monorepo/releases | WalletConnect Release | github_release | P0 | wallet, developer, dapp |

---

## 安全 & 审计

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://rekt.news/rss/ | Rekt 漏洞事件报告 | rss | P0 | security, defi, wallet |
| https://blog.openzeppelin.com/feed | OpenZeppelin 安全博客 | rss | P0 | security, developer, defi |
| https://immunefi.com/blog/rss.xml | Immunefi 赏金公告 | rss | P0 | security, defi, wallet |
| https://medium.com/feed/slowmist | SlowMist 安全分析 | rss | P0 | security, wallet, defi |
| https://blog.trailofbits.com/feed | Trail of Bits 审计 | rss | P1 | security, developer |

---

## 支付 & PayFi & 稳定币

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://www.circle.com/blog/rss.xml | Circle 官方博客 | rss | P0 | pay, stablecoin, regulatory |
| https://visaonchainanalytics.com/blog/rss.xml | Visa 链上分析 | rss | P0 | pay, data, stablecoin, growth |
| https://stable.fish/blog/rss.xml | Stable.fish 稳定币 | rss | P1 | pay, stablecoin, data |
| https://www.centrifuge.io/blog/rss.xml | Centrifuge RWA 博客 | rss | P1 | pay, rwa, defi |
| https://github.com/ethereum/ERCs/releases | ERC 标准 Release（含支付类） | github_release | P1 | pay, eip, standards, developer |

---

## 监管 & 合规

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://www.coinbase.com/institutional/research-insights/rss.xml | Coinbase 政策研究 | rss | P1 | regulatory, pay, growth |
| https://a16zcrypto.com/regulatory-clarity/feed/ | a16z 监管追踪 | rss | P1 | regulatory, pay, wallet |

---

## 开发者工具 & 基础设施

| URL | 描述 | 类型 | 优先级 | topics |
|-----|------|------|--------|--------|
| https://github.com/NomicFoundation/hardhat/releases | Hardhat Release | github_release | P1 | developer, tools |
| https://github.com/foundry-rs/foundry/releases | Foundry Release | github_release | P1 | developer, tools, security |
| https://github.com/ethereum/go-ethereum/releases | Geth 客户端 Release | github_release | P0 | developer, ethereum, xlayer |
| https://github.com/alloy-rs/alloy/releases | Alloy（Rust 以太坊库）Release | github_release | P1 | developer, tools |
| https://soliditylang.org/blog/rss.xml | Solidity 语言博客 | rss | P1 | developer, security, tools |

---

## AI 匹配规则（供 Phase 3 参考）

| 团队描述关键词/话题 | 优先匹配的 topics 标签 |
|-------------------|----------------------|
| EIP、提案、标准、以太坊规范 | `eip`, `standards` |
| 技术博客、研究、深度分析 | `research`, `developer` |
| DeFi、流动性、协议、DEX | `defi`, `dex`, `governance` |
| L2、Layer2、Rollup、ZK | `xlayer`, `l2`, `zk` |
| 钱包、AA、账户抽象 | `wallet`, `aa` |
| 安全、漏洞、审计、攻击 | `security` |
| 支付、PayFi、稳定币 | `pay`, `stablecoin` |
| 监管、合规、法律 | `regulatory` |
| 增长、数据、用户数 | `growth`, `data` |
| 开发者、工具、SDK | `developer`, `tools` |
| 治理、DAO、投票 | `governance` |

**选取数量上限**：最多 8 条（P0 优先全取，P1 按相关性从高到低补足至 8 条）。若匹配结果不足 3 条，向用户说明并建议可在 Lark 文档中手动添加。
