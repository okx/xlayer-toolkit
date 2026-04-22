# Intel Profile：X Layer 团队

> 使用方：insight-decision-flow 在 team=xlayer 时加载本文件

---

## 团队定位

X Layer 是 OKX 自建 L2，基于 OP Stack，是 Optimism Superchain 正式成员。团队关注 OP Stack 上游变更、Superchain 生态格局、竞品 L2 技术动作、ZK 证明系统演进。

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `xlayer` 或 `all` 的信息源。

**P0 优先（必采）**：@optimism @base @arbitrum @VitalikButerin @jessepollak @ethereum @Starknet @Scroll_ZKP @zksync @CelestiaOrg

---

## KEEP 规则（xlayer 专属补充）

在 web3-intel-filter 通用规则之外，以下信号对 X Layer 团队**额外升级为 KEEP**：

- OP Stack 任何代码变更、安全公告、版本发布（无论大小）
- Superchain 生态成员动向（Base、OP Mainnet、Mode、Unichain 等加入/退出/重大更新）
- ZK Proof / TEE 新证明系统进入生产落地阶段
- 竞品 L2（Base、Arbitrum、zkSync、Scroll、Linea）发布战略级技术变化
- 模块化 DA 层（Celestia、EigenDA）重大更新
- Sequencer 去中心化方案落地（影响 XLayer 竞争力叙事）
- EVM 兼容性标准变化（新 EIP、EOF 等影响 Rollup）

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
