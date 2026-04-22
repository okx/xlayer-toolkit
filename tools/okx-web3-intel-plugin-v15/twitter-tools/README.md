# Twitter Intel Tools

基于 [6551.io opentwitter-mcp](https://github.com/6551Team/opentwitter-mcp) 和 [opennews-mcp](https://github.com/6551Team/opennews-mcp) 封装的 Web3 Twitter 情报采集工具集。

---

## 文件结构

```
twitter-tools/
├── twitter_api.py          # 核心 API 客户端（同步封装）
├── fetch_twitter_intel.py  # 批量抓取 sources.md 信息源推文
├── update_sources.py       # 信息源验证与更新工具
└── README.md               # 本文件
```

---

## 第一步：获取 Token

1. 访问 **https://6551.io/mcp**
2. 登录后获取 Token（基础版免费）
3. 设置环境变量：

```bash
export TWITTER_TOKEN=your_token_here
```

永久生效（写入 ~/.zshrc 或 ~/.bashrc）：
```bash
echo 'export TWITTER_TOKEN=your_token_here' >> ~/.zshrc
source ~/.zshrc
```

> 同一个 Token 同时支持 Twitter API 和 News API（`TWITTER_TOKEN` 和 `OPENNEWS_TOKEN` 等效）。

---

## 安装依赖

```bash
pip install requests --break-system-packages
```

---

## 工具使用

### fetch_twitter_intel.py — 批量抓取推文

```bash
# 抓取所有 P0+P1 账号的最近 6h 推文
python fetch_twitter_intel.py

# 只抓 P0 账号，最近 12h
python fetch_twitter_intel.py --priority P0 --hours 12

# 只抓 XLayer 相关账号
python fetch_twitter_intel.py --teams xlayer --hours 6

# 抓取 + 额外关键词搜索
python fetch_twitter_intel.py --search "OP Stack upgrade"

# 每个账号最多 10 条，不过滤时间
python fetch_twitter_intel.py --max 10 --no-filter-time

# 输出保存到文件
python fetch_twitter_intel.py --priority P0 > /tmp/intel.json 2>/dev/null
```

输出格式（JSON）：
```json
{
  "tweets": [
    {
      "source": "@VitalikButerin",
      "priority": "P0",
      "teams": ["all"],
      "tweet_id": "12345...",
      "text": "推文内容...",
      "created_at": "2026-02-27T10:00:00+00:00",
      "likes": 1200,
      "retweets": 340,
      "url": "https://x.com/VitalikButerin/status/12345..."
    }
  ],
  "count": 87,
  "sources_count": 45,
  "errors": [],
  "fetched_at": "2026-02-27T14:00:00+00:00"
}
```

---

### update_sources.py — 信息源管理

**添加新账号**（先验证账号存在，再写入 sources.md）：
```bash
python update_sources.py add @jessepollak "Base 链创建者，Coinbase 钱包负责人" \
  --category "核心开发者" \
  --priority P0 \
  --teams "xlayer,wallet"
```

**发现 KOL 关注者**（挖掘潜在新信息源）：
```bash
python update_sources.py discover @VitalikButerin
python update_sources.py discover @aeyakovenko
```

**批量验证账号活跃状态**：
```bash
python update_sources.py verify --priority P0
python update_sources.py verify --priority P0,P1
```

**通过关键词发现相关账号**：
```bash
python update_sources.py search "ZK proof Ethereum"
python update_sources.py search "OP Stack L2" --min-followers 50000
```

---

## 与 intel 流水线集成

在 `web3-intel-filter` skill 中，检测到 `TWITTER_TOKEN` 后自动切换为 Twitter 实时模式：

```bash
# 在 Claude Code 内 Bash 执行：
cd skill-updates/twitter-tools
python fetch_twitter_intel.py --priority P0,P1 --hours 6 --max 5
```

输出的 JSON 直接传入过滤矩阵，替代 WebSearch 结果。

---

## API 端点参考

> Base URL: `https://ai.6551.io`，所有请求需 `Authorization: Bearer {TOKEN}` 头

| 功能 | Method | Endpoint | 关键参数 |
|------|--------|----------|----------|
| 获取用户信息 | POST | `/open/twitter_user_info` | `username` |
| 获取用户推文 | POST | `/open/twitter_user_tweets` | `username`, `maxResults`, `product` |
| 搜索推文 | POST | `/open/twitter_search` | `keywords`, `fromUser`, `minLikes` |
| KOL 关注者 | POST | `/open/twitter_kol_followers` | `username` |
| 关注事件 | POST | `/open/twitter_follower_events` | `username`, `isFollow` |
| 新闻搜索 | POST | `/open/news_search` | `q`, `coins`, `limit` |
| 新闻分类 | GET  | `/open/news_type` | — |

---

## 常见问题

**Q: Token 未设置时怎么办？**
A: `fetch_twitter_intel.py` 会输出 `{"error": "TWITTER_TOKEN 未配置", "tweets": [], "count": 0}`，intel 流水线会自动降级到 WebSearch 模式，不会报错中断。

**Q: 某个账号返回空数据？**
A: 会打印警告到 stderr，其他账号继续正常采集。最终 `errors` 字段记录失败账号列表。

**Q: 如何测试 API 连通性？**
```bash
python -c "
import sys; sys.path.insert(0, '.')
from twitter_api import get_user_info
print(get_user_info('VitalikButerin'))
"
```
