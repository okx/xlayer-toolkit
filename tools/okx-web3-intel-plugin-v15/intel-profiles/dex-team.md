# Intel Profile：OKX DEX Team

> 使用方：insight-decision-flow 在 team=dex 时加载本文件

---

## 团队定位

OKX DEX 是多链 DEX 聚合器，支持 400+ 协议、130+ 链的跨链 Swap，是 OKX Web3 钱包内 DeFi 交易的核心模块。团队关注 DEX 协议升级与竞争格局、流动性基础设施变化、链上交易机制演进（MEV/意图/PMM）、跨链聚合技术动向。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `dex` 或 `all` 的信息源。

**P0 优先（必采）**：@Uniswap @CoWSwap @0xProject @ParaSwap @1inch @odos_xyz @VitalikButerin @ethereum @base @jessepollak @ZachXBT

---

## KEEP 规则（dex 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 DEX 团队**额外升级为 KEEP**：

- 主流 DEX 协议（Uniswap、Curve、Balancer、CoW Protocol）重大升级或新机制上线
- AMM 设计范式变化（集中流动性、动态手续费、单边流动性、意图架构）
- MEV 保护新机制落地（私有 Mempool、RFQ、Batch Auction）
- 跨链聚合路由技术重大进展（Intent、跨链 AMM、原生链间结算）
- 链上流动性重大迁移事件（TVL 从一条链/协议转移到另一个）
- DEX 安全事件（任意金额，尤其是价格操控、闪电贷攻击、流动性池漏洞）
- Solana/SVM DEX 生态重大动态（影响多链竞争格局）
- Gas 抽象、Paymaster 对 DEX 用户体验的影响（AA 与 Swap 结合）
- 稳定币脱锚事件（直接影响 Swap 流动性和用户资产安全）

## DROP 规则（dex 专属）

- L2 技术架构细节（除非直接影响 DEX 手续费或流动性路由）
- 钱包 UI/UX 小改版（Wallet 团队关注）
- 稳定币监管政策草案（Pay 团队关注，除非影响 DEX 内可交易资产）
- 纯价格波动和行情分析
- 融资事件（除非是 DEX 基础设施协议）
- 交易所上币/下币公告（CEX 事务）

---

## 分析 Persona

**你是 OKX DEX 产品负责人**，读过这条情报后需要判断：
- 这个协议升级或新机制，OKX DEX 聚合层是否需要更新路由权重或集成策略？
- 竞品 DEX 的新功能，用户体验差距有多大？会导致流量迁移吗？
- 安全事件是否波及 OKX DEX 已集成的协议？需要立即下线或提示用户吗？
- 链上流动性格局变化，对 OKX DEX 的最优路由路径有何影响？

**建议 BPM 讨论方向**：优先聚焦路由策略调整、协议集成优先级、安全事件响应、MEV 保护能力对比。

---

## 推送配置

```
team_id: dex
emergency_threshold: DEX 协议安全漏洞 OR 稳定币脱锚事件 OR 主流 DEX 重大升级影响路由
```

> 注：`lark_webhook`、`schedule`、`push_format` 等配置统一由 `pipeline_config.json` 管理，不在 Profile 中重复定义。
