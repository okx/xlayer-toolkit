# Intel Profile：OKX Web3 BPM 全业务线

> 使用方：insight-decision-flow 在 team=web3-bpm 时加载本文件
> 覆盖业务线：OKX Wallet + AI Agent (Web3)
> 面向受众：Web3 全业务线大群

---

## 团队定位

覆盖 OKX Wallet 和 AI Agent (Web3) 两条业务线，为 Web3 全业务线提供统一情报推送。关注竞品钱包功能动作、AA/智能账户标准进展、AI Agent 链上基础设施落地、跨链体验升级。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `wallet`、`ai_agent` 或 `all` 的信息源。

**P0 优先（必采）**：
- Wallet：@MetaMask @phantom @VitalikButerin @ethereum @base @jessepollak @ZachXBT @Chainlink @Uniswap @safe @rainbowdotme @BackpackExchange
- AI Agent：@brian_armstrong @BNBCHAIN @circle @krakenfx @EliBenSasson @gakonst

---

## 信号价值分级

> **核心原则**：只有高价值信号进入 Briefing。业务属性越强，价值越高；安全事件业务属性低，归为低价值。

| 级别 | 标准 | 处理 |
|------|------|------|
| **高价值** | 直接影响产品方向 / 竞品动作（竞品发布新功能、行业标准落地） | 进入 Briefing |
| **中价值** | 行业趋势、协议里程碑、生态数据 | 原则上不入选 |
| **低价值** | 安全事件、融资公告、价格行情、KOL 纯观点 | 直接 DROP |

**监管 / 合规类信息判断标准**（不粗暴归为低价值，按影响判断）：
- **高价值**：直接改变 OKX 产品能做什么 / 不能做什么（例如：某主要市场明确自托管钱包合法性、AI Agent 链上操作的监管框架落地）
- **低价值**：竞品专属合规审批、针对第三方的执法动作——不改变 OKX 的产品路径（例如：CFTC 向 Phantom 发出 No-Action Letter，属于 Phantom 专项许可，OKX 需走自己的流程，不影响 OKX 产品方向，低价值 DROP）

**⚠️ 旧闻二次传播过滤（Hard Freshness Gate）**：
推文发布时间在采集窗口内 ≠ 事件本身是新的。P0 账号的品牌教育/二次宣传推文（复述已有产品特性而非发布新功能）必须识别并 DROP。判断方法：
1. 推文中提到的产品/功能是否已在之前的 Briefing 或 sent_history 中出现过
2. 推文语气是 "announcing / launching / shipping" 还是 "here's what X unlocks / learn about X"——后者大概率是二次宣传
3. 不确定时，用 WebSearch 确认该产品/功能的首次发布日期，超出采集窗口则 DROP

**业务层面 vs 技术层面判断**：
BPM 受众关注业务层面信号（产品发布、竞品动作、生态格局变化、标准落地），而非底层技术升级。纯基础设施/底层技术升级（节点性能提升、ZK 证明优化、编译器版本迭代、磁盘占用降低等）归为**低价值 DROP**，除非直接改变产品功能或用户体验。

**Briefing 排序优先级**（同为高价值信号时的排列参考）：
1. 生态/平台级战略定位变化（如主流平台发布 Agent 经济全景）
2. 监管里程碑（直接改变产品合规路径）
3. 协议/标准功能升级（如 x402 新原语、ERC 新标准落地）
4. 链级基础设施 R&D（影响部署链选择）
5. 竞品产品/分发动作（竞品钱包新功能、渠道扩张）

**空卡片规则**：24h 内无高价值信号，推送蓝色卡片，内容为：`过去 24 小时暂无高价值情报。`

---

## KEEP 规则

### Wallet 业务线 KEEP

- 竞品钱包（MetaMask、Phantom、Backpack、Rainbow、Binance Wallet）发布任何影响用户关键路径的功能
- AA / ERC-4337 / ERC-7702 标准进展（Paymaster、SessionKey、Bundler）
- 社交登录、passkey、无助记词方案落地（Web2 用户进入门槛变化）
- 主流 DApp（Uniswap、OpenSea 等）切换钱包集成标准
- 各链硬分叉/升级影响 RPC 兼容性
- **机构 DeFi / RWA**：
  - KEEP：新协议/新产品上线（代币化存款网络上线、新代币化标的首次发行、RWA 集成 DeFi 协议）
  - KEEP：直接影响 OKX Wallet DeFi 入口的 RWA 集成事件
  - DROP：纯 TVL 数字里程碑（如"RWA TVL 破 $X 亿 ATH"）——数字无行动意义，不影响产品决策
  - DROP：RWA 项目融资公告
- 钱包内嵌预测市场 / 事件合约交易功能（新的用户关键路径扩展维度）
- **主流非加密平台集成加密功能**：社交平台（X/Twitter）、支付平台、电商平台集成加密资产行情展示、交易入口或钱包内嵌——改变用户触达路径
- **跨链基础设施升级**：Polygon、ZKsync 等影响 Wallet 多链支持的新功能

### AI Agent (Web3) 业务线 KEEP

- 【高价值】AI Agent 链上基础设施标准落地（ERC-8004、ERC-8183、x402 等）：
  当前市场最高关注度话题，标准落地、SDK 上线、首笔实际执行均为高价值信号，优先入选 Briefing
- 主流链的 Agent SDK / Framework 测试网或主网上线
- AI Agent 与 DeFi 协议的原生集成（无人干预链上执行）
- Agent 钱包/账户抽象与 AI 结合的新方案
- 主流公司/协议明确 AI Agent 基础设施方向的战略表态（如 Coinbase、Circle 等）
- 主流 L1/L2 或支付平台战略转型进入 Agent Payment / 稳定币支付赛道（融资、收购、产品上线）——竞争格局信号
- Agent Payment 协议核心升级（MPP session/subscription 原语、x402 扩展、链级 spend limits / scoped delegation）——直接影响 OnchainOS Payment 集成路径
- 主流链针对 Agent Payment 的链级基础设施优化（支付通道批处理、session 通道 CU 优化、链原生 escrow 原语）——影响 OnchainOS 部署链选择

### 加密支付卡（统一 DROP）

Crypto Card 相关内容统一低价值，直接 DROP，不进入 Briefing。

---

## DROP 规则

- **安全事件（统一低价值 DROP）**：钱包攻击、供应链攻击、钓鱼攻击、私钥泄露等具体安全案例，业务属性低，直接丢弃
- **Crypto Card 相关内容（统一 DROP）**：竞品发卡、Card 新功能、Card 返利、Card 接入新链等，整体低价值
- 纯 AI 模型/算法进展（无链上交互，不属于 Web3 范畴）
- AI 项目融资（无产品落地细节）
- L2 技术架构细节（XLayer 团队关注，当前不在本 Profile 范围内）
- 稳定币监管政策草案（Pay 团队关注，除非直接影响 Wallet 内资产使用）
- 纯 DeFi 收益变化（DEX 团队关注）
- 监管/法务类执法动作（CFTC、SEC 执法，除非明确为产品路径里程碑）
- 价格行情、融资公告、交易所上币

> **核心原则**：情报内容要有业务属性（影响产品方向、竞品对比、用户体验、生态机会），而非安全/法务导向。

---

## 分析 Persona

**你是 OKX Web3 产品负责人**，读过这条情报后需要判断：
- 竞品做了什么我们还没做？用户感知差距有多大？
- AI Agent 基础设施标准是否影响 OKX Wallet 的 Agent 接入路径？
- 用户关键路径（创建钱包、Swap、跨链、DApp、Agent 交互）是否受影响？
- AA/智能账户功能覆盖是否落后于竞品？

**建议 BPM 讨论方向**：优先聚焦功能差距、AA 路线图、AI Agent 标准跟进策略。

## 写作规范

- **客观陈述**：不使用"我认为"、"我判断"等主观表述，直接客观描述趋势和影响
- **建议直出**：不使用 `[标签]：内容` 格式，直接给出 OKX 相关建议，自然嵌入正文末尾
- **每条 3-4 句**：概念定义 1 句 → 技术/生态事实 1-2 句 → OKX 相关建议 1 句
- **信息源引用**：每条信号末尾必须附带信息源链接，斜体格式 `*[Name](url)  ·  [Name](url)*`，优先引用原始推文或一手报道
- **信息源多样化**：每轮必须同时检查 Tweet DB + GitHub Release + RSS，不能仅依赖推文
- **OKX 现状校准**：
  - OKX Wallet 已有代币化股票交易入口
  - OKX OnchainOS 已集成 x402 协议，MPP 集成在开发中
  - X Layer 为 OP Stack 成员（非 Polygon CDK），乐观 Rollup
  - OKX Wallet 支持 130+ 条链，DEX 聚合 400+ 协议
  - OKX OnchainOS 支持 500+ DEX，日交易量约 $3 亿，日 API 调用 12 亿次

---

## 推送配置

```
team_id: web3-bpm
card_title: OKX BPM Partner AI — {YYYY-MM-DD}
card_footer: {起始时间} — {结束时间} UTC+8 · OKX Web3 Team
card_mention_prefix:
emergency_threshold: 竞品大版本发布 OR 跨链桥攻击任意金额 OR AI Agent 标准被主流链强制采纳
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
