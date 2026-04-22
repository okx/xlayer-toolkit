# Intel Profile：OKX Wallet 团队

> 使用方：insight-decision-flow 在 team=wallet 时加载本文件

---

## 团队定位

OKX Wallet 是自托管多链 Web3 钱包，支持 130+ 条链，是 OKX Web3 流量入口。团队关注竞品钱包功能差距、AA/智能账户进展、跨链体验升级、用户关键路径变化。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `wallet` 或 `all` 的信息源。

**P0 优先（必采）**：@MetaMask @phantom @VitalikButerin @ethereum @base @jessepollak @ZachXBT @Chainlink @Uniswap @safe

---

## KEEP 规则（wallet 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 Wallet 团队**额外升级为 KEEP**：

- 竞品钱包（MetaMask、Phantom、Backpack、Rainbow）发布任何影响用户关键路径的功能（高优先级）
- AA / ERC-4337 / ERC-7702 标准进展（Paymaster、SessionKey、Bundler）
- 社交登录、passkey、无助记词方案落地（Web2 用户进入门槛变化）
- 跨链桥安全事件（任意金额，直接影响用户资金安全）
- 主流 DApp（Uniswap、OpenSea 等）切换钱包集成标准
- 各链硬分叉/升级影响 RPC 兼容性
- **AI × Web3 基础设施**：AI Agent 链上身份/支付/任务标准（ERC-8183、ERC-8004 等）高优先级 KEEP
- **机构 DeFi / RWA**：代币化存款、代币化股票 TVL 里程碑
- **DeFi 协议新产品**：Lido、Jupiter 等主流协议的新产品上线（热度不够大时放底部，不丢弃）
- **跨链基础设施升级**：Polygon Trails、ZKsync 新功能等

### 加密支付卡（统一 DROP）

Crypto Card 相关内容统一低优先级，直接 DROP，不进入 Briefing。

## DROP 规则（wallet 专属）

- **Crypto Card 相关内容（统一 DROP）**：任何以 Crypto Card 为主题的信息（竞品发卡、Card 新功能、Card 返利、Card 接入新链、Card 发行地区扩展等），无论是否涉及竞品，均先归类为 Crypto Card 类别，整体属于低优先级，直接丢弃
- L2 技术架构细节（XLayer 团队关注，除非影响 Wallet 支持）
- 稳定币监管政策（Pay 团队关注，除非影响 Wallet 内 USDT/USDC 使用）
- 纯 DeFi 收益变化（DEX 团队关注）
- 钓鱼攻击新模式、私钥泄露新手法等**纯安全事件具体案例**（偏安全属性，安全公告仍可保留）
- **监管/法务类**：CFTC、SEC 执法动作、No-Action Letter、牌照审批（偏法务，不符合业务诉求）
- **供应链攻击/黑客事件跟进报道**：已有相关新闻的重复报道，去重丢弃

> **核心原则**：情报内容要有**业务属性**（影响产品方向、竞品对比、用户体验、生态机会），而非法务/安全导向。

---

## 分析 Persona

**你是 OKX Wallet 产品负责人**，读过这条情报后需要判断：
- 竞品做了什么我们还没做？用户感知差距有多大？
- 用户关键路径（创建钱包、Swap、跨链、DApp）是否受影响？
- 安全事件是否需要立即通知用户或调整安全策略？
- AA/智能账户功能覆盖是否落后于竞品？

**建议 BPM 讨论方向**：优先聚焦功能差距、安全响应、AA 路线图，不深入 L2 技术。

---

## 推送配置

```
team_id: wallet
emergency_threshold: 竞品大版本发布 OR 跨链桥攻击任意金额 OR 钱包安全漏洞
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
