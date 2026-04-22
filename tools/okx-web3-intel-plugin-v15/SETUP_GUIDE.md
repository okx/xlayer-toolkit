# OKX Web3 情报流水线 — 快速部署指南

> 任何团队下载插件后，按本文档操作即可在 15 分钟内完成部署。

---

## 第一步：运行配置向导（推荐，1 分钟）

在 Claude 对话框中输入：

```
/start
```

向导会自动收集团队信息、写入配置、测试推送。

### （可选）手动配置

如果你更喜欢手动配置，编辑 `pipeline_config.json`（与 SKILL.md 同级目录），修改两处：

```json
{
  "team": {
    "id": "wallet"   ← 改成你的团队：wallet / xlayer / pay / growth / all
  },
  "lark": {
    "webhook_url": "https://open.larksuite.com/open-apis/bot/v2/hook/你的URL"
  }
}
```

其他参数保持默认即可。

---

## 第二步：选择运行方式

### 方式 A：Claude 桌面应用定期触发（推荐新手）

在 Claude 桌面应用中，对话框输入：

```
每天 8:00-22:00，每小时运行 Web3 情报流水线
```

Claude 会自动设置定时任务。**只要桌面应用保持开启，任务就会按时自动执行。**

或者手动触发任意一次：
```
跑一下情报流水线
```

---

### 方式 B：服务器 Cron（适合 7×24 小时无人值守）

**前提**：服务器已安装 `claude` CLI

```bash
# 安装 Claude CLI（如尚未安装）
npm install -g @anthropic-ai/claude-code
claude login  # 登录账号

# 给脚本加执行权限
chmod +x /path/to/okx-wallet-bpm-v11/run_pipeline.sh

# 添加 cron 任务（每天 8:00-22:00 每小时运行）
crontab -e
```

在 crontab 中添加：
```cron
# Web3 情报流水线（本地时间 8-22 点整点触发）
0 8-22 * * * /path/to/okx-wallet-bpm-v11/run_pipeline.sh >> /var/log/web3-intel.log 2>&1

# 每周一 9:00 自动发现新信息源
0 9 * * 1 claude --print "更新 web3 信息源，发现新账号候选" >> /var/log/web3-sources.log 2>&1
```

---

### 方式 C：Mac/Linux 本地 cron（无需服务器）

```bash
# 同样编辑 crontab
crontab -e

# 添加（需要电脑不休眠）
0 8-22 * * * /path/to/okx-wallet-bpm-v11/run_pipeline.sh
```

---

## 第三步：验证配置（3 分钟）

手动触发一次测试运行：

```bash
# 测试信息源解析工具（无需 Token）
python /path/to/okx-wallet-bpm-v11/twitter-tools/discover_sources.py --mode stats
```

在 Claude 对话框中确认完整流水线和 Lark 推送：
```
跑一下情报流水线，推送到 Lark
```

> **注意**：`twitter-tools/` 中的 `run_twitter_intel.py`、`fetch_twitter_intel.py`、`twitter_api.py`
> 是备用 API 模式脚本，需要 `TWITTER_TOKEN` 环境变量才能运行。默认推荐使用浏览器抓取模式，
> 无需任何 Token，直接通过 Claude in Chrome 扩展即可工作。

---

## 文件结构说明

```
okx-wallet-bpm-v11/
├── pipeline_config.json          ← 团队配置（/start 向导自动生成，或手动编辑）
├── run_pipeline.sh               ← 服务器 cron 启动脚本
├── SETUP_GUIDE.md                ← 本文件
│
├── commands/
│   └── start.md                  ← /start 向导 Skill
│
├── intel-profiles/               ← 团队专属过滤规则和分析 Persona
│   ├── wallet-team.md
│   ├── xlayer-team.md
│   ├── pay-team.md
│   └── growth-team.md
│
├── twitter-tools/                ← 推特采集工具集
│   ├── browser_twitter_tools.js  ← DOM 抓取 JS 片段（Claude 注入用，无需 Token）
│   ├── discover_sources.py       ← 信息源自动发现工具（Python，无需 Token）
│   └── ...                       ← 备用 API 模式脚本（需 TWITTER_TOKEN）
│
├── skills/
│   ├── insight-decision-flow/
│   │   └── SKILL.md              ← 流水线主 Skill
│   ├── intel-reviewer/
│   │   └── SKILL.md              ← 情报审核 Skill
│   ├── web3-intel-filter/
│   │   └── SKILL.md              ← 过滤矩阵 Skill
│   ├── okx-impact-analyst/
│   │   └── SKILL.md              ← 战略分析 Skill
│   ├── lark-intel-notify/
│   │   └── SKILL.md              ← Lark 推送格式 Skill
│   └── web3-sources/
│       └── references/sources.md ← 信息源列表（188+ 账号）
```

---

## 团队快速配置表

| 团队 | team.id | 信息源过滤 | 专属 Profile |
|------|---------|-----------|-------------|
| OKX Wallet | `wallet` | wallet + all 标签 | `intel-profiles/wallet-team.md` |
| X Layer | `xlayer` | xlayer + all 标签 | `intel-profiles/xlayer-team.md` |
| OKX Pay | `pay` | pay + all 标签 | `intel-profiles/pay-team.md` |
| Growth | `growth` | growth + all 标签 | `intel-profiles/growth-team.md` |
| 通用（全业务线） | `all` | 全部账号 | 无（通用视角） |

---

## 常见问题

**Q: 推文抓取失败/X.com 显示登录页怎么办？**
A: 在 Claude 浏览器扩展中打开 X.com 并登录后重试。浏览器需保持登录状态。

**Q: Lark Webhook 推送失败怎么办？**
A: 不要用 Python curl 推送，必须通过浏览器 JavaScript fetch 发送（绕过 VM 网络代理限制）。

**Q: 如何添加新团队？**
A: 推荐使用 `/start` 向导，它会自动生成 Profile 文件。也可手动在 `intel-profiles/` 目录下新建 `{team}-team.md`，参考 `wallet-team.md` 格式。

**Q: 没有 Twitter API Token 怎么办？**
A: 默认已使用浏览器抓取模式（无需 API）。如有 [6551.io](https://6551.io/mcp) Token，设置 `TWITTER_TOKEN` 环境变量可启用 API 模式（更快，无需浏览器）。

---

## 信息源维护（每周建议）

```bash
# 查看当前信息源统计
python okx-wallet-bpm-v11/twitter-tools/discover_sources.py --mode stats

# 发现新账号候选（Claude 会用浏览器搜索并比对）
# 在 Claude 对话框输入：
# "更新 web3 信息源，搜索最新的 wallet 和 xlayer 相关账号"
```

---

*最后更新：2026-02-27 | 版本：1.0.0*
