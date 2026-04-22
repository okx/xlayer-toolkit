---
name: insight-decision-flow
description: >
   OKX Web3 情报全自动流水线（V14 — 24H 全覆盖分页修复版）：严格串联 web3-sources → web3-intel-filter →
   okx-impact-analyst → intel-reviewer 四个 skill，完成采集 → 过滤 → 去重 → Lark 推送情报
   自动去重（不发重复内容）、质量过滤（没有好内容就不发）。
   支持任意 team 参数（如 wallet / xlayer / pay / growth，或任何自定义 team ID），不传则读 pipeline_config.json 中的默认 team。
   触发场景："Run the Web3 intel pipeline","push to Lark","跑一下情报流水线"、"推送情报到 Lark"、"intel pipeline"、"跑情报"、
   "采集一下最新动态"、"有什么新情报"、"定时情报"、"发情报到群里"。
   也适用于定时任务调度（每小时整点触发）。
   即使用户只是说"有什么新的 Web3 消息"，只要语境暗示需要采集+推送，就应该触发此 skill。
version: 12.0.0
---

# Web3 情报全自动流水线（V14 — 24H 全覆盖分页修复版）

你是 OKX Web3 情报自动化引擎。你的工作是**严格按顺序调用子 skill**，串联成完整的情报流水线，最终通过 Lark Webhook 推送结果。

核心原则：**宁缺毋滥**。没有真正重要的内容就不发，不硬凑，不注水。

### 推送时间规则

- **执行窗口**：每天 08:00 - 22:00 **（CST / UTC+8，北京时间）**，每个整点触发一次（共 15 次/天）
- **静默窗口**：22:00 - 次日 08:00（CST），**不采集、不推送、不打扰**
- **紧急模式例外**：`is_emergency = true` 时无视静默窗口，立即推送（见下文 Emergency Mode）
- 如果当前时间在静默窗口内被触发且非紧急模式，直接退出，不执行任何步骤
- Cron 表达式：**`0 * * * *`**（每小时整点，CST 窗口由内部代码判断）

**⚠️ Cron 修正说明**：不使用 `0 8-22 * * *`，因为 Cowork 调度器会将 hour-range 误解为"仅在第一个匹配小时运行一次"。改用 `0 * * * *`（每小时整点），由流水线内部做 CST 时间窗口判断。

**⚠️ 时区检查（重要）**：Cowork VM 内部使用 UTC，必须转换为 CST 再判断时间窗口：

```bash
# 获取当前 CST 时间（UTC+8），用于时间窗口判断
CURRENT_HOUR=$(TZ='Asia/Shanghai' date +%H)
if [ "$CURRENT_HOUR" -lt 8 ] || [ "$CURRENT_HOUR" -ge 22 ]; then
  echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')] 静默窗口（CST ${CURRENT_HOUR}:xx），退出" >> /tmp/pipeline_log.txt
  exit 0
fi
```

直接用 `date +%H` 不加 TZ 会得到 UTC 时间，**会导致 08:00-15:59 CST 的运行被错误拦截**。

### 时间窗口参数（TIME_WINDOW）

- **默认值**：`TIME_WINDOW = 24`（小时），即采集最近 24 小时内的信息
- **用户自定义**：若用户在指令中明确指定了时间范围（如"最近3小时"、"过去6小时"、"最近12h"），则 `TIME_WINDOW` 严格使用用户指定的值
- **全流程统一**：`TIME_WINDOW` 在 Step 0 确定后，贯穿整个流水线——Tweet DB 的 cutoff、GitHub Release 的 cutoff、RSS 的 maxAgeDays、WebSearch 的日期限定词，全部统一使用同一个时间窗口
- **传递方式**：在调用各子 skill 时，将 `TIME_WINDOW` 作为上下文参数传入

### ⚠️ 硬性时间门控（Hard Time Gate）— 全流程强制执行

这是整个流水线最重要的数据质量规则：**任何进入 Briefing 或 Impact Analysis 的信号，其发布时间必须经过验证且落在 TIME_WINDOW 窗口内。没有例外。**

为什么这条规则至关重要：曾经发生过 WebSearch 补充采集将 19 天前和 39 天前的历史事件混入 24h 情报推送的事故，导致情报时效性严重失真。根因是 WebSearch 返回的结果没有可靠时间戳，而流水线没有在最终输出前执行统一的时间校验。

**各数据源的时间验证方式**：

| 数据源 | 时间字段 | 验证方式 | 未通过验证的处理 |
|--------|---------|---------|----------------|
| Tweet DB (Bitable) | `create_time` (精确时间戳) | `create_time >= cutoff` 字符串比较 | 直接丢弃 |
| GitHub releases.atom | `<updated>` (ISO 时间戳) | `updated > cutoff` | 直接丢弃 |
| RSS/博客 | `<pubDate>` (结构化时间) | `pubDate > cutoff` | 直接丢弃 |
| 浏览器抓取推文 | `time` 字段 | `time` 在 TIME_WINDOW 内 | 直接丢弃 |
| **WebSearch（最危险）** | **无可靠时间元数据** | **必须执行四步验证流程（见 web3-intel-filter）** | **验证失败 → 直接 DROP，不允许降级保留** |

**Step 4 终极时间校验**：在去重+质量关卡环节，对所有保留信号执行最后一道时间检查：
1. 每条信号必须附带 `confirmed_publish_date`（格式：YYYY-MM-DD 或 YYYY-MM-DD HH:MM:SS）
2. `confirmed_publish_date` 不在 `[now - TIME_WINDOW, now]` 范围内 → **强制移除，无论内容多重要**
3. WebSearch 来源的信号如果无法确认发布日期 → **强制移除**（不再允许标注"[日期未确认]"后降级保留）
4. 唯一例外：`is_emergency = true` 且事件仍在持续发酵中（如安全漏洞尚未修复）

**传递要求**：在调用 `web3-intel-filter` 时，必须明确传入：
- `TIME_WINDOW`：时间窗口小时数
- `cutoff_datetime`：精确截止时间字符串（CST，格式 `YYYY-MM-DD HH:MM:SS`）
- `hard_time_gate = true`：启用硬性时间门控

**子 skill 执行方式（避免中断）**：不使用 `Skill()` 工具调用子 skill——`Skill()` 调用会在每次 sub-skill 返回时结束当前 turn，导致流水线必须等用户发消息才能继续。正确方式是：用 Glob 搜索 `**/skills/{skill-name}/SKILL.md`，用 Read 读取其内容，然后在当前会话中**直接内联执行**该 skill 的完整指令。这样整个流水线在同一个连续 turn 内完成，不会中断。

---

## ⚠️ 步骤容错原则（Step Fault Tolerance）

**每个步骤相互独立，任何步骤中断或失败都不能阻塞后续步骤执行。**

规则：
- 每个步骤（Step 0 至 Step 9）执行失败、超时、抛出异常或被中断时，**立即记录日志，用空值/默认值替代该步骤输出，然后继续执行下一步**
- 禁止因单步失败而整体退出，除非是 Step 4 明确判断"本轮无新情报"（这是正常的质量门控，不是错误）
- 每步开始前输出 `[Step X 开始]`，结束后输出 `[Step X 完成]` 或 `[Step X 跳过：{原因}]`，便于定位中断点

各步骤中断时的默认降级值：

| 步骤                  | 中断时默认值 | 对后续影响 |
|---------------------|------------|-----------|
| Step 0-A（读配置）       | 使用硬编码默认值 | webhook 为空则不推送 |
| Step 0-B（读 Profile） | 通用模式运行 | 无 team-aware 过滤 |
| Step 0-C（Tweet DB）  | `sheet_tweets = []` | Step 2.5 降级为完整浏览器抓取 |
| Step 1（读历史）         | `sent_history = []`（不做去重） | 可能重复推送，可接受 |
| Step 2（信息源列表）       | 使用 Profile P0 账号内置列表 | 覆盖面缩小 |
| Step 2.5（Twitter）   | `twitter_signals = []` | 依赖 GitHub+RSS+WebSearch |
| Step 2.6（GitHub）    | `github_signals = []` | 依赖其他源 |
| Step 2.7（RSS）       | `rss_signals = []` | 依赖其他源 |
| Step 2.8（自定义源）      | 跳过 | 无影响 |
| Step 3（过滤）          | 将上游所有信号直接传入 Step 4 | Step 4 承担过滤责任 |
| Step 5.5（CTO审核）     | 使用 Step 3/5 原始输出 | 不经审核直接推送 |
| Step 6（推送蓝卡）        | 写日志跳过 | 不推送 |
| Step 7（更新历史）        | 写日志跳过 | 下次可能重复推送 |

---

## ⚠️ 定时任务防卡死规则（Anti-Freeze）

> **整个流水线（包括所有子 skill）在定时任务中绝对禁止调用 `AskUserQuestion`。**
> 定时任务无人值守，任何等待用户输入的操作会导致 Session 永久挂起。

防卡死策略：

| 场景 | 交互式会话 | 定时任务 |
|------|-----------|---------|
| Webhook URL 为空 | 提示用户填写 | 写日志跳过，不推送 |
| Profile 文件不存在 | 提示用户运行 /start | 通用模式运行 |
| 推送失败 | 重试 + 告知用户 | 三级降级（curl → 浏览器 → 日志） |
| 新信源候选（Step 9） | 正常执行 | 跳过，仅交互式运行 |

**判断运行模式**：检查当前 session 来源——若由 `mcp__scheduled-tasks` 触发则为定时任务模式，否则为交互式。

---

## Emergency Mode（紧急模式）

**触发条件**：采集过程中发现满足 `emergency_threshold` 的事件（默认：竞品大版本发布 OR 安全漏洞 >$1M）。

**行为差异**：
- `is_emergency = true` → 无视静默窗口，立即执行完整流水线
- 红色卡片标题加 🚨 前缀
- 不等到下一个整点，发现即推送

---

## team 参数说明

`team` 参数值为任意英文 ID（如 `wallet`、`xlayer`、`pay`、`growth`，或任何自定义名称）。

- **传入 team** → 读取 `intel-profiles/{team}-team.md`，使用该团队的 KEEP/DROP 规则和 Persona
- **不传 team** → 从 `pipeline_config.json` 的 `team.id` 读取默认团队 ID
- **Profile 文件不存在** → 以通用模式运行，流程结束后提示用户运行 `/start` 命令创建团队配置

Webhook URL 统一从 `pipeline_config.json` 的 `lark.webhook_url` 读取，所有团队共用。

团队配置存储在本地 `intel-profiles/{team}-team.md` 文件中，可随时编辑（修改 KEEP/DROP 规则、Persona 等），下次情报运行时自动读取最新版本。

---

## 首次配置向导

**触发条件**：用户首次运行，或明确说"帮我配置情报机器人"。

直接调用 `/start` 命令（`commands/start.md`），该命令包含完整的向导流程：
- 收集团队信息 → 写入 `pipeline_config.json` → 确保 Profile 文件就绪 → 测试推送 → 设置定时任务

⚠️ **不要在此处内联实现向导逻辑**，`/start` 命令有完整的流程设计。

---

## 前置配置

### Lark Webhook URL

Webhook URL 存储在 `pipeline_config.json` 的 `lark.webhook_url` 字段中。

读取逻辑（**全程不询问用户**）：
1. 从 `pipeline_config.json` → 取 `lark.webhook_url`
2. 若为空 → **跳过推送，写入日志后返回**：
   ```bash
   echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')] [WARN] Webhook URL 未配置，已跳过本次 Lark 推送。请运行 /start 配置。" >> /tmp/pipeline_log.txt
   ```

### 去重历史文件

**路径推导规则**：从 `pipeline_config.json` 的实际路径推导 `sent_history` 所在目录。

```
config_path   = Glob 搜到的 pipeline_config.json 路径（优先 /mnt/ 下的可写副本）
history_dir   = dirname(config_path)
team_id       = pipeline_config.json 中的 team.id（或用户传入的 team 参数）
sent_history_path = {history_dir}/sent_history_{team_id}.md
```

不存在时自动创建。

---

## 执行流程

### Step 0：加载配置（始终执行，两步完成）

**每次运行均必须执行此步。**

#### Step 0-A：读取 pipeline_config.json

用 Glob 搜索 `**/pipeline_config.json`，**优先读取路径含 `/mnt/` 的可写副本**。

从中提取：
```
team_id            → team.id（用户传入 team 参数时以参数为准）
team_name          → team.name
webhook_url        → lark.webhook_url
tweet_db_sheet_url → tweet_db_sheet_url
poc_mentions       → poc_mentions（数组，默认 []）
```

**poc_mentions 读取示例（严禁硬编码，必须 for 循环）**：
```python
import json

with open(config_path) as f:
    config = json.load(f)

poc_mentions = config.get("poc_mentions", [])  # 默认 []，支持随时新增

# 传给 lark-intel-notify 时直接传数组，由其内部 for 循环展开：
# for poc in poc_mentions:
#     email = poc.get("email", "").strip()
#     name  = poc.get("name", "")
#     → 有 email → <at email=xxx@okg.com></at>
#     → 无 email → @{name}
```

team_name 映射规则（若 config 中未写 name）：
- `wallet` → "OKX Wallet Team"
- `xlayer` → "X Layer Team"
- `pay` → "OKX Pay Team"
- `dex` → "OKX DEX Team"
- `growth` → "OKX Growth Team"
- `web3` → "OKX Web3 Team"
- 其他 → "OKX {ID 首字母大写} Team"

固定默认值（不再从外部读取）：
```
interval_hours         → 1
active_hours_start     → 8
active_hours_end       → 22
max_signals_per_run    → 5
push_format            → briefing + top1_impact
source_priority        → P0, P1
```

#### Step 0-B：读取团队 Profile 文件

使用 Glob 搜索 `**/intel-profiles/{team_id}-team.md`，读取本地 Profile 文件。

**Profile 文件包含**：团队定位、KEEP/DROP 规则、分析 Persona、P0 必采账号、紧急阈值等。

提取以下区块的文本内容：
- `## 团队定位` → 团队背景
- `## KEEP 规则` → team 专属保留规则
- `## DROP 规则` → team 专属过滤规则
- `## 分析 Persona` → 分析视角
- `## 信息源过滤规则` → P0 必采账号列表
- `## 推送配置` → `emergency_threshold` 紧急推送条件

**若 Profile 文件不存在**：
- 以通用模式运行（不应用 KEEP/DROP 专属规则，使用 okx-impact-analyst 的内置 Persona）
- 流程结束后提示用户运行 `/start` 命令创建团队配置

Step 0 完成后输出一行摘要即可，例如：
```
✅ 配置加载完毕：team=web3，webhook=已配置，Profile=web3-team.md
```

#### Step 0-C：Tweet DB Bitable 读取（⚠️ 有 URL 时强制执行，不可跳过）

**触发条件**：`pipeline_config.json` 中配置了 `tweet_db_sheet_url`。

> **⚠️ 强制性**：当 `tweet_db_sheet_url` 存在时，此步**必须执行，禁止跳过或省略**。
> 这是 Twitter 数据的**最可靠来源**——外部脚本已按小时批次抓取推文并存入此 Lark Bitable。
> 比浏览器实时抓 x.com 覆盖广、成功率高。跳过此步将直接导致大量热点遗漏。

**Lark Bitable 结构**：
- 支持两种 URL 格式：`/wiki/` 内嵌 Bitable 和 `/base/` 独立 Bitable（自动识别）
- **只需读四个字段**（其他字段忽略）：

  | 字段 | 含义 | 类型 |
    |------|------|------|
  | `username` | 推文作者 handle | 富文本数组 |
  | `source_url` | 推文原始链接 | 富文本数组 |
  | `content` | 推文完整文本 | 富文本数组 |
  | `create_time` | 推文写入时间（格式：`YYYY-MM-DD HH:MM:SS`，可直接做字符串比较） | 富文本数组 |

  > **⚠️ 字段值格式**：所有字段均为 Lark 富文本数组 `[{"text": "...", "type": "text"}]`，
  > 读取时必须提取各元素的 `.text` 拼接，不能直接当字符串使用：
  > ```python
  > def extract_text(v):
  >     if isinstance(v, list): return "".join(i.get("text","") for i in v)
  >     return str(v) if v else ""
  > ```

  > **字段兼容说明**：正式数据表（`/base/` URL）含 `create_time`（Text，`YYYY-MM-DD HH:MM:SS`）；
  > 旧版归档表（`/wiki/` URL）含 `import_time_by_hour`（DateTime 类型）。始终先用 `listFields` 探测，不猜测。

**执行步骤（Lark MCP API）**：

1. **从 URL 提取参数**：
   - 正则匹配 `table=([^&]+)` → `tableId`
   - **判断 URL 类型**：
      - 若 URL 包含 `/wiki/`：提取 `/wiki/([^?]+)` → `wiki_token`，继续步骤 2
      - 若 URL 包含 `/base/`：提取 `/base/([^?]+)` → 直接作为 `appToken`，**跳过步骤 2，直接执行步骤 3**

2. **（仅 /wiki/ URL）调用 getWikiNode 获取 appToken**：
   ```
   mcp__e6224747-8fdf-4f4d-9014-2fc040a50f37__getWikiNode(token=wiki_token)
   ```
   - 从返回值取 `obj_token` → 即 `appToken`
   - 验证 `obj_type === "bitable"`，若不是则报错

3. **探测时间字段名（必须执行，不可跳过）**：

   > ⚠️ **不要猜测字段名**。Lark Bitable 的字段名因表而异，必须通过 API 确认后再使用。

   调用 `listFields` 获取实际 schema：
   ```
   mcp__e6224747-8fdf-4f4d-9014-2fc040a50f37__listFields(
     appToken = appToken,
     tableId  = tableId
   )
   ```

   从返回的 fields 列表中，按以下优先级找出时间字段名，记为 `time_field_name`：
   - 精确匹配 `create_time` → 优先
   - 精确匹配 `import_time_by_hour` → 次选
   - 包含 `time` 字样的字段名 → 兜底
   - 均不存在 → `time_field_name = null`，只读 username/source_url/content，**跳过时间过滤**

4. **分页读取（TIME_WINDOW 全覆盖策略）**：

   > ⚠️ **sort 参数必须为数组格式** `[{...}]`，传入对象格式 `{...}` 会触发 `field validation failed`（code 99992402）。
   > 这是 Bitable searchRecords API 的已知格式要求，不论字段类型。

   > ℹ️ **为什么需要分页**：`page_size=500` 单页只覆盖约 35 小时的最新数据，无法保证完整覆盖
   > 时间窗口。Bitable 的 `page_token` 是 offset-based，在活跃写入的表上存在轻微位移，
   > 但通过 `record_id` 去重后，多页合并可稳定覆盖所需数据量。
   > 最多读 4 页（2000 条）= 约 5-7 天数据，完全覆盖任何合理的 TIME_WINDOW，且有足够冗余。

   **先计算截止时间（`cutoff`），供循环的提前退出判断使用**：
   ```bash
   # TIME_WINDOW 默认 24，用户指定时间范围时按用户值
   cutoff = $(TZ='Asia/Shanghai' date -d "${TIME_WINDOW} hours ago" '+%Y-%m-%d %H:%M:%S')
   ```

   分页循环（立即串联，最小化页间延迟）：

   ```
   all_records_map = {}   // key: record_id → 自动去重（多页 offset 漂移时不会重复计入）
   page_token_next = null
   max_pages = 4          // 安全上限：4 × 500 = 2000 条

   for page_num in 1..max_pages:
       result = searchRecords(
         appToken    = appToken,
         tableId     = tableId,
         field_names = ["username", "source_url", "content", time_field_name].filter(非null),
         sort        = [{"field_name": time_field_name, "desc": true}],
         page_size   = 500,
         page_token  = page_token_next   // 第 1 页传 null
       )

       // 去重写入（record_id 唯一）
       for record in result.items:
           all_records_map[record.record_id] = record

       // 提前退出：若当前页最旧记录已早于 TIME_WINDOW 截止时间，后续页更旧，无需继续
       if time_field_name:
           page_times = [extract_text(r.fields.get(time_field_name, [])) for r in result.items if time_field_name in r.fields]
           valid_times = [t for t in page_times if t]
           if valid_times and min(valid_times) < cutoff:
               break

       // 是否有下一页
       if result.has_more and result.page_token:
           page_token_next = result.page_token
       else:
           break   // 无更多页

   all_records = list(all_records_map.values())
   ```

   > 💡 **去重说明**：Bitable offset-based pagination 在活跃写入的表上，相邻两页之间可能有少量
   > 重叠（约 0-10 条）。`record_id` 去重确保不重复计入，实际覆盖范围 = 各页的时间区间**并集**。

5. **时间过滤（内存中执行，使用上面已计算的 `cutoff`）**：

   过滤规则（`time_field_name` 非 null 时执行）：
   - 字段值为富文本数组，须先 `extract_text()` 再做字符串比较
   - 保留 `extract_text(record.fields[time_field_name]) >= cutoff` 的记录
   - 若过滤后为空：写日志 `[WARN] Tweet DB：TIME_WINDOW 内无新推文`，`sheet_tweets = []`
   - 若过滤后 >= 1 条：正常继续，写日志记录实际条数和最新记录时间

   将过滤后的 records 映射为 `sheet_tweets` 列表（所有字段均需富文本展开）：
   ```python
   filtered_records = [r for r in all_records
                       if extract_text(r["fields"].get(time_field_name, [])) >= cutoff]
   sheet_tweets = [
       {
           "username":   extract_text(r["fields"].get("username", [])),
           "source_url": extract_text(r["fields"].get("source_url", [])),
           "content":    extract_text(r["fields"].get("content", []))
       }
       for r in filtered_records
   ]
   ```

   > ℹ️ `time_field_name = null` 时跳过过滤，`sheet_tweets` 直接映射自全部 `all_records`（不做时间裁剪）。

6. **输出**：`sheet_tweets` 列表 → Step 2.5 的 **#1 优先级数据源**

**失败处理**：
- `/wiki/` URL 且 `getWikiNode` 失败 → `sheet_tweets = []`，写日志 `[WARN] Tweet DB Bitable 读取失败：getWikiNode error`，继续后续步骤
- `/base/` URL 解析失败 → `sheet_tweets = []`，写日志 `[WARN] Tweet DB Bitable 读取失败：base URL parse error`，继续后续步骤
- `listFields` 失败 → 以 `time_field_name = null` 继续，只读内容三列，不做时间过滤
- `searchRecords` 失败（非 sort 相关错误） → `sheet_tweets = []`，写日志警告，Step 2.5 将完全依赖浏览器抓取和 WebSearch
- 时间过滤后为空 → `sheet_tweets = []`，写日志，后续步骤降级到浏览器和 WebSearch
- 任何 MCP API 调用超时 → 同上，降级为空列表

### Step 1：加载去重历史

读取 `sent_history_{team_id}.md`，路径按前置配置中的推导规则。记住已发送过的所有条目标题和关键事实，用于 Step 4 的去重比对。

### Step 2：内联执行 `web3-sources` — 获取信息源

用 Glob 搜索 `**/skills/web3-sources/SKILL.md`，Read 读取后在当前会话内联执行。这个 skill 会引导你读取它维护的信息源列表（188+ 个信息源，覆盖 Twitter/X、GitHub、RSS/博客、数据平台四类渠道，14 个类别）。

**Team-Aware 过滤**：
- 若有 team 参数：只提取 `teams` 列包含该 team 值 **或** `all` 的信息源，及 Team Profile 指定的 P0 信源
- 若无 team 参数：提取全部 P0 + P1 信息源

本步结束时，你手上应有四份列表：
1. **Twitter 账号列表**（供 Step 2.5）
2. **GitHub releases.atom URL 列表**（供 Step 2.6）
3. **RSS URL 列表**（供 Step 2.7）
4. **数据平台 URL 列表**（按需，不每次都跑）

### Step 2.5：Twitter 数据获取（三级数据优先级）

**三级优先级**：
1. **🔴 sheet_tweets**（来自 Step 0-C 的 Lark Sheet 推文数据库）→ **最高优先级**，有数据时直接作为 Twitter 信号源主体，**不再跳过浏览器抓取但浏览器抓取降为补充**
2. **浏览器实时抓取**（无 API 模式）→ 始终执行作为**补充**（但 sheet_tweets 已覆盖的账号可跳过）
3. **WebSearch 兜底**（Step 3 中自动执行）→ 浏览器也失败时的最终保障

> **⚠️ 关键变更**：当 `sheet_tweets` 有数据时，它是 Twitter 信号的**主体**。浏览器抓取降为补充——只抓 sheet_tweets 中**未覆盖**的 P0 账号。这避免了浏览器抓取成功率低导致大量热点遗漏的问题。

**合并逻辑**：
- `sheet_tweets`（Step 0-C）+ 浏览器补充抓取 → 去重（按 source_url 或 username+content 前50字符去重）→ 合并为最终 Twitter 信号列表

**浏览器抓取循环**（始终执行，但范围可缩小）：

**待抓取队列**：
- 若 `sheet_tweets` 非空：只抓取 sheet_tweets 中**未出现**的 P0 账号（通常很少，2-5 个）
- 若 `sheet_tweets` 为空：回退到完整抓取——P0 全部（约 37 个），P1 最多 25 个

对每个 handle，依次执行：
1. 用 `mcp__Claude_in_Chrome__navigate` 导航到 `https://x.com/{handle}`
2. 用 `mcp__Claude_in_Chrome__computer` wait 2 秒（SPA 渲染）
3. 注入 `EXTRACT_TWEETS` 脚本（从 `browser_twitter_tools.js` 读取）：
   - 用 `Glob("**/browser_twitter_tools.js")` 定位文件
   - 用 `Read` 读取文件内容，提取 `EXTRACT_TWEETS` 变量中的 JS 代码
   - 通过 `mcp__Claude_in_Chrome__javascript_tool` 注入执行
   - ⚠️ **不要内联复制 JS 脚本**，始终从 `browser_twitter_tools.js` 读取最新版本
   - 如需限制返回条数，在内存中对结果做 `.tweets.slice(0, N)` 截取，不修改原始脚本

4. 收集推文，追加到内存列表。抓取失败则静默跳过。

**汇总处理**：

将所有账号的推文（prefetched + 实时抓取）合并写入 `/tmp/raw_tweets.json`，然后在内存中过滤：
- 去除 `is_retweet: true` 的条目
- 只保留 `time` 字段在过去 6 小时内的推文

过滤结果作为 **Twitter 实时情报**，暂存内存，与后续步骤合并后统一传入 Step 3。

**操作规则**：
- P0 账号优先全部抓取（约 38 个），P1 按团队筛选最多抓 25 个
- 单次完整抓取约 2-3 分钟，定时任务场景可控制在 5 分钟内
- 若浏览器未登录 X.com（导航后出现登录页）→ 立即跳过此步，进入 Step 2.6
- 关键词补充搜索：对主要话题在 `x.com/search?q={keyword}&f=live` 额外抓取

### Step 2.6：GitHub Release 监控（VM 直接抓取）

**在 Step 2.5 结束后立即执行，耗时约 30 秒，信噪比极高。**

对 Step 2 获取的 GitHub releases.atom URL 列表，逐一用 `curl` 拉取：

```bash
# 批量拉取，只取 24 小时内发布的 release
for url in \
  "https://github.com/ethereum-optimism/optimism/releases.atom" \
  "https://github.com/ethereum-optimism/op-geth/releases.atom" \
  "https://github.com/matter-labs/zksync-era/releases.atom" \
  "https://github.com/ethereum/consensus-specs/releases.atom" \
  "https://github.com/starkware-libs/cairo/releases.atom" \
  "https://github.com/celestiaorg/celestia-node/releases.atom" \
  "https://github.com/Layr-Labs/eigenlayer-contracts/releases.atom" \
  "https://github.com/foundry-rs/foundry/releases.atom" \
  "https://github.com/OpenZeppelin/openzeppelin-contracts/releases.atom" \
  "https://github.com/MetaMask/metamask-extension/releases.atom"; do
  echo "=== $url ===" && curl -s "$url" | python3 -c "
import sys, xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
root = ET.parse(sys.stdin).getroot()
ns = {'a': 'http://www.w3.org/2005/Atom'}
cutoff = datetime.now(timezone.utc) - timedelta(hours=TIME_WINDOW)  # TIME_WINDOW 默认 24，用户指定时按用户值
for entry in root.findall('a:entry', ns)[:5]:
    updated_str = entry.find('a:updated', ns).text
    try:
        updated = datetime.fromisoformat(updated_str.replace('Z','+00:00'))
        if updated > cutoff:
            title = entry.find('a:title', ns).text
            link = entry.find('a:link', ns).attrib.get('href', '')
            print(f'  [{updated_str[:10]}] {title}  {link}')
    except: pass
"
done
```

**处理规则**：
- 只保留 **TIME_WINDOW 小时内**的 release（`updated` 字段，默认 24h）
- 每个仓库最多取 2 条
- release 标题 + 链接 + 仓库名 组合为结构化条目，追加到内存信号列表
- 格式标注 `[source_type: github_release]`，供过滤矩阵识别

**跳过条件**：curl 返回非 200 或解析失败 → 静默跳过该仓库

### Step 2.7：RSS / 技术博客抓取（浏览器 fetch，按需执行）

**默认执行**。所有已注册团队均执行 RSS 采集，不限制业务线。

**采集方式**：在浏览器（已处于 open.larksuite.com 或其他页面）执行 fetch() 拉取 RSS XML 并解析，不依赖 VM 网络。

对每个 RSS URL 注入以下 JS 脚本：

```javascript
(async function fetchRSS(rssUrl, maxAgeDays = 3, maxItems = 3) {
  try {
    const resp = await fetch(rssUrl);
    if (!resp.ok) return { url: rssUrl, error: resp.status, items: [] };
    const text = await resp.text();
    const parser = new DOMParser();
    const doc = parser.parseFromString(text, 'text/xml');
    const isAtom = doc.querySelector('feed') !== null;
    const entries = isAtom
      ? doc.querySelectorAll('entry')
      : doc.querySelectorAll('item');
    const cutoff = new Date(Date.now() - maxAgeDays * 86400000);
    const items = [];
    entries.forEach(e => {
      if (items.length >= maxItems) return;
      const title = e.querySelector('title')?.textContent?.trim() || '';
      const link  = isAtom
        ? (e.querySelector('link')?.getAttribute('href') || e.querySelector('link')?.textContent?.trim() || '')
        : (e.querySelector('link')?.textContent?.trim() || '');
      const pubRaw = e.querySelector('pubDate, published, updated, dc\\:date')?.textContent || '';
      const pub = pubRaw ? new Date(pubRaw) : null;
      if (pub && pub < cutoff) return;
      const summary = (e.querySelector('description, summary, content\\:encoded, content')?.textContent || '')
        .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 400);
      items.push({ title, link, pubDate: pubRaw.slice(0, 16), summary });
    });
    return { url: rssUrl, items };
  } catch(err) {
    return { url: rssUrl, error: err.toString(), items: [] };
  }
})("RSS_URL_HERE")
```

**批量执行**：依次替换 `RSS_URL_HERE` 为各 RSS 地址，将结果追加到内存信号列表，标注 `[source_type: rss]`。

**RSS 采集优先级**（P0 RSS）：
1. `https://blog.ethereum.org/feed.xml` — 以太坊基金会
2. `https://vitalik.eth.limo/feed.xml` — Vitalik 博客
3. `https://ethresear.ch/latest.rss` — 以太坊研究论坛
4. `https://l2beat.com/blog/feed.xml` — L2Beat 分析
5. `https://weekinethereumnews.com/feed/` — Week in Ethereum 周报
6. `https://rekt.news/rss/` — 安全事件追踪

P1 RSS（时间允许时补充）：ethresear.ch Magicians、Arbitrum/Optimism blog、Paradigm、Bankless 等。

**⚠️ 容错规则（强制）**：Step 2.7 中任何报错（浏览器工具不可用、网络超时、fetch 被拦截、XML 解析失败、JS 注入异常等）均**静默跳过**，不中断主流程：
```bash
echo "[$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')] [WARN] Step 2.7 RSS 采集跳过：{原因}" >> /tmp/pipeline_log.txt
```
跳过后直接进入 Step 2.8，`rss_signals = []`（空列表），后续步骤正常使用其他信号源继续执行。

**计时**：Step 2.7 结束时打印：`⏱ Step 2.7 完成：{ms}ms（RSS 新文章 {N} 条）`（跳过时打印：`⏱ Step 2.7 跳过：{原因}`）

### Step 2.8：自定义信息源采集（团队专属）

**执行条件**：`custom-sources-reference.md` 中有与当前 team 匹配的信息源条目（由 web3-sources skill 基于 team 过滤返回）。

对匹配的自定义信息源 URL，按类型分发采集：

| 类型 | 采集方式 | 说明 |
|------|---------|------|
| `rss` | 同 Step 2.7 的 fetchRSS 脚本 | RSS/Atom feed |
| `github_release` | 同 Step 2.6 的 curl + Python | GitHub Release Atom feed |
| `webpage` | 浏览器导航 + `get_page_text` 提取文本 | 博客/技术文章页，取最新 1 篇 |
| `eip_tracker` | 浏览器导航 + JS 提取最新条目 | EIP/ERC 提案追踪列表 |

**处理规则**：
- P0 全部采集，P1 最多补 5 条
- 每条 URL 超时 10 秒则跳过
- 采集结果标注 `[source_type: custom_{type}]`，追加到内存信号列表
- 与 Step 2.5/2.6/2.7 的结果合并后传入 Step 3

**跳过条件**：自定义信息源列表为空，或所有 URL 采集失败 → 静默跳过

### Step 3：内联执行 `web3-intel-filter` — 采集 + 过滤

用 Glob 搜索 `**/skills/web3-intel-filter/SKILL.md`，Read 读取后在当前会话内联执行。这个 skill 有完整的方法论：

- **信息来源**：Step 2.5 浏览器抓取的推文（如有）**优先使用**，WebSearch 作为补充和兜底
- **三维度搜索策略**：头部信源主动播报 → 协议/项目官方更新 → 安全事件雷达
- **基础过滤矩阵**：8 类保留（竞品动作、协议升级、技术原语、安全事件 >$1M 等）+ 8 类丢弃（价格、八卦、融资等）
- **Team 专属补充**（如有 team 参数）：在基础矩阵之外，额外应用 Profile 中的 KEEP/DROP 覆盖规则
- **Intel Briefing 输出格式**：最多 8 条，按重要性排序，含来源链接

**⚠️ P0 来源强制候选规则**：

Intel Profile 中标注为 **P0** 的账号，其推文满足以下全部条件时，**直接进入候选池，不参与关键词评分竞争**：
- 非纯转推（not retweet）
- 非价格行情 / 融资公告 / Crypto Card 相关
- 发布时间在 TIME_WINDOW 内

原因：P0 账号的表态本身即为信号，即使推文措辞简短（如 CEO 的一句战略预告），语义价值也高于普通长推文。关键词匹配数量不能作为 P0 来源的过滤依据。

**⚠️ 传入 TIME_WINDOW**：告知 web3-intel-filter 当前的时间窗口（默认 24h 或用户指定值），使其在 WebSearch 时正确过滤。

**⚠️ WebSearch 发布日期验证**：web3-intel-filter 内置了 WebSearch 结果的发布日期验证流程（自动 DROP 年度回顾/旧文、URL 日期校验、摘要日期校验、必要时 WebFetch 确认）。确保此验证步骤被正确执行——**这是防止旧闻混入实时信号的关键关卡**。Tweet DB 和 GitHub/RSS 的结构化时间数据不需要此验证。

严格按照 web3-intel-filter 的指示操作。

### Step 4：去重 + 质量关卡 + 硬性时间门控

将 Step 3 产出的情报条目与 Step 1 加载的历史文件逐条比对，同时执行硬性时间门控：

**4-A. 硬性时间门控（最高优先级，先于其他所有检查执行）**：
- 每条信号必须有 `confirmed_publish_date`，不在 `[cutoff_datetime, now]` 范围内 → **强制移除**
- `source_type: web` 且无法确认发布日期 → **强制移除**（不允许"[日期未确认]"降级保留）
- `source_type: twitter/github_release/rss` 的时间已在采集环节校验过，此处做二次确认
- 唯一例外：`is_emergency = true` 且事件仍在持续（安全漏洞未修复等）

**4-B. 去重检查**：
- 核心事件已发过（即使措辞不同）→ 移除
- 信息质量不够（模糊、投机、无实锤）→ 移除

**4-C. 最终校验**：
- 全部被过滤掉 → 直接停止，不推送任何内容，输出"本轮无重大新情报"
- 保留的信号按重要性排序

**Emergency 检测**：在此步检查是否有满足 `emergency_threshold` 的事件。若有，设 `is_emergency = true`。

### Step 5：暂无步骤

### Step 5.5：内联执行 `intel-reviewer` — CTO 审核

**紧接 Step 5 完成后执行**。用 Glob 搜索 `**/skills/intel-reviewer/SKILL.md`，Read 读取后在当前会话内联执行，传入：
- Step 3 的 Intel Briefing 全文

`intel-reviewer` 以 CTO 视角进行 5 维度审核：
1. **事实准确性**：数据、日期、版本号是否正确
2. **技术准确性**：技术细节是否准确，有无混淆
3. **叙事一致性**：与 `strategic-narratives.md` 中的已有叙事是否一致或冲突
4. **战略判断质量**：推断逻辑是否 solid，有无过度解读
5. **OKX 内部对齐**：与 `okx-business-context.md` 中的业务线定位是否匹配

**审核输出**：
- 修订后的 Briefing
- 若发现需要追加的叙事条目 → 自动 append 到 `strategic-narratives.md`

**跳过条件**：Step 5 被跳过时（无值得分析的内容），此步也跳过。

### Step 6：内联执行 `lark-intel-notify` — 推送情报 Briefing 到 Lark（蓝色卡片）

用 Glob 搜索 `**/skills/lark-intel-notify/SKILL.md`，Read 读取后在当前会话内联执行。按照 lark-intel-notify 的格式要求，构建**蓝色 header** 的情报 Briefing 卡片。

**推送内容**：仅推送 Step 3/4 过滤后的情报信号汇总简报（经 Step 5.5 审核修订的 Briefing 部分）。

**传入变量**：调用 lark-intel-notify 时，将 Step 0-A 从 `pipeline_config.json` 读取的 `poc_mentions` 数组以 `poc_mentions` 变量一并传入。lark-intel-notify 会 **for 循环**遍历数组中每个 POC 对象生成 `<at email=...></at>`，**严禁硬编码**，以确保新增 POC 后自动生效。

**推送三级降级**：lark-intel-notify 会自动按优先级尝试 ① curl → ② 浏览器导航 Fetch → ③ 写日志跳过。详见 `lark-intel-notify/SKILL.md`。

卡片颜色：**blue**（Intel Briefing）

若有 team 参数，在卡片标题加上团队标记，如 `Web3 Intel Briefing — 2026-02-27 · OKX Web3 Team`

**Emergency 模式**：若 `is_emergency = true`，卡片标题加 🚨 前缀。

### Step 7：暂时不做

### Step 8：更新去重历史

将本次推送的所有条目**追加**到去重历史文件。

**⚠️ 必须使用 `>>` append**，不能用 Write 工具覆盖（会丢失历史记录）：

```bash
cat >> "{sent_history_path}" << 'EOF'
[YYYY-MM-DD HH:MM] | 标题 | 一句话摘要
[YYYY-MM-DD HH:MM] | 标题 | 一句话摘要
EOF
```

### Step 9（可选，仅交互式）：内联执行 `web3-sources` — 摄入新信源候选

**触发条件**：
1. Step 3 的 Intel Briefing 末尾存在 `🔍 新信息源候选` 区块
2. **当前为交互式会话**（定时任务跳过此步，避免无人值守时修改信源列表）

调用 `web3-sources` 并传入候选列表，执行**模式 B（Intel-Driven Update）**：快速验证候选账号 → 摄入通过验证的账号 → 更新 sources.md。

若无候选区块或当前为定时任务，跳过本步。

---

## Skill 调用链路图

```
Step 0-A  读取 pipeline_config.json（优先 /mnt/ 可写副本）
          → 获取 team_id、webhook_url、tweet_db_sheet_url
  ↓
Step 0-B  读取 intel-profiles/{team_id}-team.md → 获取 KEEP/DROP/Persona
  ↓
Step 0-C  ⚠️ Tweet DB Sheet 读取（有 URL 时强制！listFields 探测字段名 → DESC 分页拉取最多 4 页 2000 条 → record_id 去重 → TIME_WINDOW 时间过滤）
  ↓
Step 1    读取 sent_history_{team_id}.md（路径从 config_path 推导）
  ↓
Step 2    Read web3-sources/SKILL.md → 内联执行 → 获取 188+ 信息源（4类，按 team 过滤）
          → 输出：Twitter 账号列表 + GitHub URL 列表 + RSS URL 列表 + 数据平台列表
  ↓
Step 2.5  三级优先：🔴 sheet_tweets（Step 0-C）→ 浏览器补充抓取 → WebSearch 兜底
  ↓
Step 2.6  VM curl GitHub releases.atom（P0仓库，24h内发版）→ 内存信号列表
  ↓
Step 2.7  浏览器 fetch() RSS（P0 RSS，3天内文章，默认全团队开启）→ 内存信号列表
  ↓
Step 2.8  [可选] 自定义信息源采集（rss/github_release/webpage/eip_tracker）
  ↓
Step 3    Read web3-intel-filter/SKILL.md → 内联执行 → 五源合并（推文+GitHub+RSS+自定义+WebSearch）
          → 过滤矩阵（含 source_type 标注）+ WebSearch 发布日期验证 → Intel Briefing
  ↓
Step 4    去重 + 质量关卡（比对 sent_history）+ 时效性二次校验 + Emergency 检测
  ↓
Step 5  Read intel-reviewer/SKILL.md → 内联执行 → CTO 5 维度审核 → 修订输出 + 叙事备忘录维护
  ↓
Step 6    Read lark-intel-notify/SKILL.md → 内联执行 → Lark 推送蓝色卡片（三级降级：curl → 浏览器 → 日志）
  ↓
Step 7    >> append 到 sent_history_{team_id}.md
  ↓
Step 8    [仅交互式] Read web3-sources/SKILL.md → 内联执行模式B → 摄入新信源候选 → 更新 sources.md
```

---

## 信息源自动发现（每周定期维护）

除情报流水线外，每周执行一次信源发现，确保 sources.md 与行业动态同步。

**触发词**："更新信息源"、"发现新账号"、"信源维护"、"更新 sources"。

### 发现流程

先用 Glob 定位脚本路径（脚本随 plugin 一起安装，位置因安装环境而异）：
```
Glob 搜索：**/twitter-tools/discover_sources.py
```
将找到的路径记为 `DISCOVER_SCRIPT`，后续所有命令替换此变量。

```bash
# 1. 查看当前信息源状态
python "$DISCOVER_SCRIPT" --mode stats

# 2. 获取现有 handles + 关键词建议
python "$DISCOVER_SCRIPT" --mode existing --with-keywords
```

然后 Claude 执行浏览器搜索（每个关键词组）：
- 导航到 `https://x.com/search?q={keyword}&f=user`（人物搜索模式）
- 等待 2s，注入 `EXTRACT_SEARCH_RESULTS` 脚本抓取账号
- 也可访问 P0 账号主页，注入 `EXTRACT_RELATED_ACCOUNTS` 抓取「你可能喜欢」

将所有候选账号写入 `/tmp/candidates.json`：
```json
{"candidates": [{"handle": "xxx", "followers": 50000, "description": "..."}]}
```

然后比对并添加：
```bash
# 3. 比较发现哪些是新账号
python "$DISCOVER_SCRIPT" --mode compare --input /tmp/candidates.json --min-followers 10000

# 4. 添加通过审核的账号（Claude 审阅后确认）
python "$DISCOVER_SCRIPT" --mode add \
  --handle @newhandle "账号描述" --priority P1 --teams wallet,xlayer
```

---

## 定时运行配置

**⚠️ 关键修正**：Cron 使用 `0 * * * *`（每小时整点），时间窗口由流水线内部 CST 判断。

```bash
# 示例（team 参数可以是任意自定义 ID）
0 * * * * claude -p "运行 web3 情报流水线 team=web3"
0 * * * * claude -p "运行 web3 情报流水线 team=wallet"
```

每次运行是独立的，不假设前一次的上下文。去重历史是跨次运行的唯一状态。

---

## 常见问题

**Q: 为什么不能自己做搜索和过滤，而要调用子 skill？**
A: 每个子 skill 都有经过验证的方法论。web3-sources 维护了 212+ 个按业务相关性分级的信息源（四类渠道），web3-intel-filter 有严格的过滤矩阵和三维度搜索策略，okx-impact-analyst 有 Team-Aware 分析框架、OKX 业务背景和叙事备忘录体系，intel-reviewer 有 CTO 视角的 5 维度审核框架——对任意自定义团队，Profile 文件中的 Persona 会被直接注入，分析视角自动适配。你自己做会丢失这些沉淀，输出质量会显著下降。

**Q: Webhook 请求被 VM 网络拦截怎么办？**
A: lark-intel-notify skill 有三级降级策略：先尝试 curl 直推 → 降级到浏览器导航同源 Fetch → 最终写日志跳过。浏览器走用户本机网络，不受 VM 代理限制。

**Q: 搜索结果全是旧闻怎么办？**
A: 正常现象。如果过滤 + 去重后没有新内容，直接结束，不要硬凑。质量比频率重要。

**Q: emergency_threshold 触发了怎么办？**
A: 设 `is_emergency = true`，无视静默窗口，直接推送。红色卡片标题加 🚨 前缀，不等到下一个整点。

**Q: 定时任务跑到一半卡住了怎么办？**
A: 全面消除了定时任务中的 AskUserQuestion 调用。如果仍然卡住，检查 `/tmp/pipeline_log.txt` 日志，定位是哪个步骤超时。

**Q: intel-reviewer 修改了分析结论怎么办？**
A: 正常现象。intel-reviewer 的修订版直接替换原始输出用于推送。若 reviewer 发现重大事实错误，会在修订中标注，但不会阻断推送流程。

**Q: 叙事备忘录（strategic-narratives.md）会无限膨胀吗？**
A: 不会。条目保留标准为 90 天。超过 90 天且行业叙事已明显转变的条目，由 intel-reviewer 标注 `[已过时]` 但不删除，保留历史记录。
