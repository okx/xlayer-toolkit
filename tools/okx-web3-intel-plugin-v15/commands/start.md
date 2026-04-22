---
description: 首次配置向导 — 收集团队信息、写入 pipeline_config.json、测试推送、创建定时任务
allowed-tools: Read, Write, Edit, Glob, Bash, WebSearch, mcp__Claude_in_Chrome__javascript_tool, mcp__Claude_in_Chrome__navigate, mcp__Claude_in_Chrome__tabs_context_mcp, mcp__scheduled-tasks__create_scheduled_task
---

# OKX Wallet BPM — 首次配置向导

## 你的职责

全程自动完成配置，用户只需提供两样东西：

1. **关注的业务方向**（如 wallet、xlayer、pay、dex 等）
2. **Lark Webhook URL**

所有配置写入 `pipeline_config.json`（唯一配置文件）。
KEEP/DROP 规则、Persona 等使用内置 Profile 文件（`intel-profiles/{team_id}-team.md`），按 team_id 自动匹配。

---

## 全局常量（硬编码，不询问用户）

```
TWEET_DB_SHEET_URL = https://okg-block.sg.larksuite.com/base/L2fZbt0QzaA1UIskbkTlZ8ylgog?table=tbl37Y8bF0sNt2Eo&view=vewB8RsqtK
```

---

## 向导流程（严格按顺序执行）

### Phase 1：检查现有配置

用 Glob 搜索 `**/pipeline_config.json`，优先读取路径含 `/mnt/` 的可写副本。

**判断逻辑：**
- 若 `team.id` 不是默认值（不是 `all`）且 `lark.webhook_url` 非空 → 已配置过，询问用户："已有配置（团队：{team.name}），要重新配置还是跳过？"
- 若未配置 → 直接进入 Phase 2

---

### Phase 2：收集团队信息

依次询问用户（每次只问一个问题，等用户回复后再继续）：

**问题 1 — 关注的业务方向**
```
你想关注哪个业务方向？（如 wallet / xlayer / pay / dex / growth / web3，或自定义名称）
```
- 接受任意小写英文字符串，作为 `{TEAM_ID}`
- 若用户说"钱包"自动映射为 `wallet`，"支付"映射为 `pay`，以此类推

**（自动推断团队名称 — 不询问用户）**
- `wallet` → "OKX Wallet Team"
- `xlayer` → "X Layer Team"
- `pay` → "OKX Pay Team"
- `dex` → "OKX DEX Team"
- `growth` → "OKX Growth Team"
- `web3` → "OKX Web3 Team"
- 其他 → "OKX {ID 首字母大写} Team"

**问题 2 — Webhook URL**
```
此功能需要有 Lark 机器人配合，请在群里自行创建机器人后，复制粘贴你的 Lark 机器人的 Webhook URL：
（Lark 群 → 右上角「...」→ 设置 → 机器人 → 添加自定义机器人 → 复制 Webhook 地址）

格式：https://open.larksuite.com/open-apis/bot/v2/hook/xxxxxxxx
```
- 如用户暂时没有 webhook：记录为空字符串，后续可直接编辑 pipeline_config.json 补充

---

### Phase 3：写入配置 + 确保 Profile 就绪

#### 3-A：确定写入路径

用 Glob 搜索所有 `**/pipeline_config.json`，按以下规则确定写入目标：

- **首选**：路径**不含** `.local-plugins` 或 `.skills` 的文件（用户 workspace 副本）
- **若不存在用户副本**：从插件目录复制一份到 workspace 根目录

> 📌 **绝对不要**写入路径含 `.local-plugins` 或 `.skills` 的文件——那是插件内置只读模板。

#### 3-B：写入 pipeline_config.json

用 Edit 工具更新以下字段：
```json
{
  "team": {
    "id": "{TEAM_ID}",
    "name": "{TEAM_NAME}"
  },
  "lark": {
    "webhook_url": "{WEBHOOK_URL}"
  },
  "tweet_db_sheet_url": "https://okg-block.sg.larksuite.com/base/L2fZbt0QzaA1UIskbkTlZ8ylgog?table=tbl37Y8bF0sNt2Eo&view=vewB8RsqtK"
}
```

#### 3-C：确保 Profile 文件存在

检查 `intel-profiles/{TEAM_ID}-team.md` 是否存在（Glob 搜索 `**/intel-profiles/{TEAM_ID}-team.md`）：

- **已存在**（wallet/xlayer/pay/growth 等内置团队）→ 直接使用
- **不存在**（自定义团队）→ 自动生成新 profile 文件（见下方模板）

**自定义团队 Profile 模板**：

在 pipeline_config.json 同级目录下创建 `intel-profiles/{TEAM_ID}-team.md`：

```markdown
# Intel Profile：{TEAM_NAME}

> 使用方：insight-decision-flow 在 team={TEAM_ID} 时加载本文件

---

## 团队定位

{根据 TEAM_ID 自动推断的 2-4 句话团队定位}

---

## 信息源过滤规则

从 sources.md 中采集 `teams` 包含 `{TEAM_ID}` 或 `all` 的信息源。

**P0 优先（必采）**：{根据团队类型推断的 P0 必采账号}

---

## KEEP 规则（{TEAM_ID} 专属补充）

在 web3-intel-filter 通用规则之外，以下信号额外升级为 KEEP：

{根据 TEAM_ID 对应业务线推断 5-8 条 KEEP 规则}

## DROP 规则（{TEAM_ID} 专属）

{根据 TEAM_ID 对应业务线推断 3-5 条 DROP 规则}

---

## 分析 Persona

**你是 {TEAM_NAME} 产品负责人**，读过这条情报后需要判断：

{根据团队定位生成 3-4 个判断问题}

**建议 BPM 讨论方向**：{简短建议}

---

## 推送配置

team_id: {TEAM_ID}
emergency_threshold: {根据业务线推断的紧急阈值}
```

**KEEP/DROP 规则推断参考：**
- 钱包类：KEEP 竞品钱包功能、AA 进展、安全事件；DROP L2 技术细节、DeFi 收益
- 支付类：KEEP PayFi 基础设施、稳定币监管、链上结算；DROP 纯 DeFi 炒作、交易量排名
- L2 类：KEEP 以太坊升级、L2 技术进展、ZK 标准；DROP 纯代币价格、交易所上币
- 增长类：KEEP 用户增长数据、产品病毒性案例、竞品运营；DROP 技术底层细节

写入完成后向用户确认："✅ 配置已写入 pipeline_config.json，Profile 已就绪。"

---

### Phase 4：测试推送（连通性诊断）

向用户确认后执行测试推送，验证 Webhook 是否畅通：

```
如果 Webhook URL 已填写：
  调用 Skill("lark-intel-notify")，推送一条测试卡片：
    - 标题：🧪 OKX Web3 Intel — 配置成功测试
    - 内容："{TEAM_NAME} 的情报配置已完成 ✅  推送通道验证通过。"
    - 卡片颜色：blue

  推送结果处理：
  - 成功 → 告知用户："✅ 推送通道验证通过。"
  - 失败 → 告知用户："⚠️ 推送测试失败，请检查 Webhook URL。"

如果 Webhook URL 为空：
  跳过测试，提示："Webhook URL 未填写，跳过推送测试。可随时编辑 pipeline_config.json 补充。"
```

---

### Phase 5：自动创建定时任务

询问用户推送频率（**只问频率，一个问题**）：

```
情报机器人多久自动推送一次？（活跃时段 08:00–22:00 北京时间，系统自动控制）

  [1] 每小时（推荐，内容最新鲜）
  [2] 每 2 小时
  [3] 每 3 小时
  [4] 每天 3 次（早 9 点 / 下午 1 点 / 傍晚 6 点）
  [5] 暂不设置，我手动触发
```

| 选项 | cronExpression | 说明 |
|------|---------------|------|
| [1] | `0 * * * *` | 每小时整点 |
| [2] | `0 */2 * * *` | 每 2 小时 |
| [3] | `0 */3 * * *` | 每 3 小时 |
| [4] | `0 9,13,18 * * *` | 每天 3 次 |
| [5] | 不传 cronExpression | 仅手动触发 |

调用 `mcp__scheduled-tasks__create_scheduled_task`：

```
taskId:        {TEAM_ID}intelpipeline
description:   {TEAM_NAME} Web3 情报流水线（{频率描述}，08:00–22:00 北京时间）
prompt:        跑一下情报流水线 team={TEAM_ID}
cronExpression: {映射值}
```

---

### Phase 6：配置完成确认

```
✅ OKX Web3 Intel — 配置完成！

团队：{TEAM_NAME}（ID: {TEAM_ID}）
配置文件：pipeline_config.json
Profile：intel-profiles/{TEAM_ID}-team.md
Webhook：{已配置 / 未配置}
推文数据库：✅ 已内置
定时任务：{每 N 小时 / 手动触发}
推送测试：{✅ 已验证 / ⏭️ 已跳过}

BPM Partner 已配置为整点自动触发，无需手动操作。 如果你想现在立刻跑一次，说「跑一下」即可。
```

---

## 注意事项

- 整个向导**全程自动完成**，不需要用户手动编辑任何本地文件
- `pipeline_config.json` 是唯一配置文件（team ID + webhook URL + 全局常量）
- `intel-profiles/{team}-team.md` 是 KEEP/DROP/Persona 配置的唯一来源
- **不再使用 `pipeline_registry.json`**
