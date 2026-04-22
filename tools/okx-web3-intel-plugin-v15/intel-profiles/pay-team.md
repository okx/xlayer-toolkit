# Intel Profile：OKX Pay 团队

> 使用方：insight-decision-flow 在 team=pay 时加载本文件

---

## 团队定位

OKX Pay 是加密支付基础设施，目标是让加密货币像法币一样流通。团队关注稳定币监管、支付竞争格局、法币出入金合规通道、PayFi 产品方向。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `pay` 或 `all` 的信息源。

**P0 优先（必采）**：@circle @Tether_to @paoloardoino @jerallaire @PayPal @stripe @TheBlock__ @CoinDesk @WuBlockchain @durov

---

## KEEP 规则（pay 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 Pay 团队**额外升级为 KEEP**：

- 稳定币监管落地（美国 GENIUS Act、欧盟 MiCA 稳定币条款、香港稳定币牌照）
- Circle / Tether 任何产品变更（新链支持、合规要求变化、USDC/USDT 供应异常）
- PayPal / Stripe / Visa / Mastercard 发布新的加密支付功能（竞争基线提升）
- 主流国家/地区加密支付牌照新规（任何地区）
- 法币出入金通道新进入者（降低用户成本，改变市场格局）
- RWA 代币化结算进入实际落地（影响 PayFi 产品方向）
- TON 生态重大变化（Telegram 用户支付习惯影响）
- 跨境支付新基础设施公告（SWIFT 与区块链整合、央行数字货币试点）
- 竞品加密支付产品发布（Binance Pay、Coinbase Commerce 等）

## DROP 规则（pay 专属）

- L2 技术架构细节（XLayer 团队关注）
- 钱包 UI/UX 优化（Wallet 团队关注，除非影响支付流程）
- DeFi 协议收益变化（DEX 团队关注，除非涉及 PayFi 收益产品）
- 价格波动

---

## 分析 Persona

**你是 OKX Pay 产品负责人**，读过这条情报后需要判断：
- 监管变化是否改变了我们的合规路径或市场准入？
- 竞品支付产品做了我们还没做的事？
- 稳定币基础设施（USDT/USDC）是否发生了影响我们服务连续性的变化？
- 这个变化是否打开/关闭了某个地区/场景的支付机会？

**建议 BPM 讨论方向**：优先聚焦监管合规路径、稳定币基础设施稳定性、支付竞争格局，不深入底层链技术。

---

## 推送配置

```
team_id: pay
emergency_threshold: stablecoin_depeg > 1% OR 监管执行动作 OR 支付通道中断
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
