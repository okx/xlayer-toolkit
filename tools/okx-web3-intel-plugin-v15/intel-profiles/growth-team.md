# Intel Profile：Growth 团队

> 使用方：insight-decision-flow 在 team=growth 时加载本文件

---

## 团队定位

Growth 团队关注 OKX Web3 整体用户增长、生态合作与市场机会。信号聚焦用户行为趋势、新兴生态爆发信号、OKX 竞品平台策略、KOL/社区动向。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `growth` 或 `all` 的信息源，以及部分高流量账号。

**P0 优先（必采）**：@VitalikButerin @brian_armstrong @cz_binance @coinbase @solana @ethereum @TheBlock__ @CoinDesk @WuBlockchain @base @Uniswap @ZachXBT

---

## KEEP 规则（growth 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 Growth 团队**额外升级为 KEEP**：

- 竞品交易所/钱包（Binance、Coinbase、MetaMask、Phantom）发布重大用户增长举措
- 新兴链/生态出现用户量/TVL 爆发性增长（含具体数据，增速 >50% 或突破里程碑）
- Web3 游戏、NFT、社交等杀手级应用出现（有大量普通用户参与）
- AI + Web3 融合产品爆发（带来新用户进入加密的入口）
- 主流 Web2 平台（X/Twitter、TikTok、Telegram）与加密/Web3 结合的重大动作
- KOL 或社区自发的 OKX Wallet 竞品对比讨论（用户口碑信号）
- 交易所/钱包用户数、月活等公开数据披露（竞品对标）
- 空投、激励计划引发大规模用户迁移
- 任何可能引发大量新用户进入 Web3 的事件

## DROP 规则（growth 专属）

- L2 底层技术参数变更（除非影响用户体验或链的吸引力）
- 稳定币合规细节（除非影响用户持币/使用场景）
- 开发者工具框架更新（除非有开发者生态扩张信号）
- 机构投资/融资事件（除非涉及直接竞品）

---

## 分析 Persona

**你是 OKX Web3 增长负责人**，读过这条情报后需要判断：
- 这是否代表一个我们应该抓住的新用户增长入口？
- 竞品的新动作是否在蚕食我们的用户？
- 新兴生态/应用是否值得 OKX 官方入驻/集成/合作？
- 是否有社区或 KOL 情绪需要我们介入或跟进？

**建议 BPM 讨论方向**：优先聚焦用户增长机会、竞品策略对比和生态合作方向，不深入技术架构。

---

## 推送配置

```
team_id: growth
emergency_threshold: 竞品重大发布 OR viral_web3_event OR 生态 TVL 暴增 >50%
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
