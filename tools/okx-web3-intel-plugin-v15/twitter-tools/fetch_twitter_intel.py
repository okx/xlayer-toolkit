#!/usr/bin/env python3
"""
批量从 sources.md P0/P1 账号抓取最新推文，供 web3-intel-filter 消费。

用法：
  python fetch_twitter_intel.py                          # 默认：P0+P1，全团队，最近6h
  python fetch_twitter_intel.py --priority P0            # 只抓 P0
  python fetch_twitter_intel.py --teams xlayer,wallet    # 只抓指定团队
  python fetch_twitter_intel.py --hours 24 --max 10      # 最近24h，每账号最多10条
  python fetch_twitter_intel.py --search "OP Stack"      # 额外关键词搜索

输出：JSON 到 stdout，进度/错误 到 stderr
"""

import os
import sys
import json
import re
import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path

# 添加同目录到路径
sys.path.insert(0, str(Path(__file__).parent))
from twitter_api import TOKEN, get_user_tweets, search_tweets, extract_tweets, tweet_url

# sources.md 路径（相对本文件往上两级 skill-updates/web3-sources/references/）
_HERE = Path(__file__).parent
SOURCES_CANDIDATES = [
    _HERE.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "skill-updates/web3-sources/references/sources.md",
]


def find_sources_md() -> Path:
    for p in SOURCES_CANDIDATES:
        if p.exists():
            return p
    raise FileNotFoundError(f"sources.md not found, tried: {SOURCES_CANDIDATES}")


def parse_sources(path: Path) -> list[dict]:
    """解析 sources.md 表格，返回信息源列表"""
    sources = []
    content = path.read_text(encoding="utf-8")

    # 匹配带 teams 列的表格行：| @handle | 名称 | 说明 | 粉丝 | 优先级 | teams | 日期 |
    pattern = r'\|\s*(@\w+)\s*\|[^|]*\|[^|]*\|[^|]*\|\s*(P\d)\s*\|\s*([^|]+)\|'
    for m in re.finditer(pattern, content):
        handle = m.group(1).lstrip("@").strip()
        priority = m.group(2).strip()
        teams_raw = m.group(3).strip()
        teams = [t.strip() for t in re.split(r'[,，]', teams_raw) if t.strip()]
        if handle:
            sources.append({
                "handle": handle,
                "priority": priority,
                "teams": teams,
            })
    return sources


def normalize_tweet(raw: dict, handle: str, priority: str, teams: list) -> dict:
    """统一推文字段格式"""
    tid = str(raw.get("id") or raw.get("tweetId") or raw.get("tweet_id") or "")
    text = raw.get("text") or raw.get("content") or raw.get("full_text") or ""
    created = (raw.get("created_at") or raw.get("createdAt") or raw.get("publishTime") or "")
    likes = raw.get("likeCount") or raw.get("likes") or raw.get("favorite_count") or 0
    rts = raw.get("retweetCount") or raw.get("retweets") or raw.get("retweet_count") or 0

    return {
        "source": f"@{handle}",
        "priority": priority,
        "teams": teams,
        "tweet_id": tid,
        "text": text.strip(),
        "created_at": created,
        "likes": int(likes) if likes else 0,
        "retweets": int(rts) if rts else 0,
        "url": tweet_url(handle, tid) if tid else f"https://x.com/{handle}",
    }


def main():
    parser = argparse.ArgumentParser(description="批量抓取 Web3 Twitter 情报")
    parser.add_argument("--priority", default="P0,P1",
                        help="逗号分隔的优先级，如 P0 或 P0,P1（默认：P0,P1）")
    parser.add_argument("--teams", default="all",
                        help="逗号分隔的团队标签，如 xlayer,wallet（默认：all=全部）")
    parser.add_argument("--hours", type=int, default=6,
                        help="只保留最近 N 小时内的推文（默认：6）")
    parser.add_argument("--max", type=int, default=5, dest="max_per_user",
                        help="每个账号最多取几条（默认：5）")
    parser.add_argument("--search", default="",
                        help="额外执行关键词搜索（可选）")
    parser.add_argument("--no-filter-time", action="store_true",
                        help="不按时间过滤（返回 API 默认最新 N 条）")
    args = parser.parse_args()

    # ── Token 检查 ─────────────────────────────────────────────────────────────
    if not TOKEN:
        result = {
            "error": "TWITTER_TOKEN 未配置",
            "hint": "请访问 https://6551.io/mcp 获取 token，然后设置环境变量：export TWITTER_TOKEN=your_token",
            "tweets": [],
            "count": 0,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        sys.exit(0)  # 不 exit(1)，让 pipeline 可以 fallback 到 WebSearch

    # ── 加载信息源 ─────────────────────────────────────────────────────────────
    try:
        sources_path = find_sources_md()
    except FileNotFoundError as e:
        print(json.dumps({"error": str(e), "tweets": [], "count": 0}), file=sys.stdout)
        sys.exit(1)

    allowed_priorities = set(p.strip() for p in args.priority.split(","))
    filter_teams = set(t.strip() for t in args.teams.split(","))

    all_sources = parse_sources(sources_path)

    # 过滤优先级和团队
    if "all" in filter_teams:
        targets = [s for s in all_sources if s["priority"] in allowed_priorities]
    else:
        targets = [
            s for s in all_sources
            if s["priority"] in allowed_priorities
            and bool(filter_teams & (set(s["teams"]) | {"all"}))
        ]

    print(f"[INFO] 目标账号：{len(targets)} 个 | 优先级：{args.priority} | 团队：{args.teams} | 时间范围：最近 {args.hours}h",
          file=sys.stderr)

    # ── 批量抓取 ───────────────────────────────────────────────────────────────
    cutoff = datetime.now(timezone.utc) - timedelta(hours=args.hours)
    all_tweets = []
    errors = []

    for src in targets:
        try:
            resp = get_user_tweets(src["handle"], max_results=args.max_per_user)
            raw_tweets = extract_tweets(resp)

            for raw in raw_tweets:
                t = normalize_tweet(raw, src["handle"], src["priority"], src["teams"])

                # 时间过滤
                if not args.no_filter_time and t["created_at"]:
                    try:
                        created = datetime.fromisoformat(
                            t["created_at"].replace("Z", "+00:00")
                        )
                        if created < cutoff:
                            continue
                    except (ValueError, TypeError):
                        pass  # 解析失败则不过滤

                if t["text"]:
                    all_tweets.append(t)

            print(f"  ✓ @{src['handle']}: {len(raw_tweets)} 条", file=sys.stderr)

        except Exception as e:
            err_msg = f"@{src['handle']}: {type(e).__name__}: {e}"
            errors.append(err_msg)
            print(f"  ✗ {err_msg}", file=sys.stderr)

    # ── 额外关键词搜索 ─────────────────────────────────────────────────────────
    if args.search:
        try:
            print(f"[INFO] 关键词搜索：{args.search}", file=sys.stderr)
            resp = search_tweets(
                keywords=args.search,
                exclude_retweets=True,
                max_results=20,
                product="Top",
            )
            raw_tweets = extract_tweets(resp)
            for raw in raw_tweets:
                t = normalize_tweet(raw, "search", "P1", ["all"])
                t["source"] = f"search:{args.search}"
                if t["text"]:
                    all_tweets.append(t)
            print(f"  ✓ 搜索「{args.search}」: {len(raw_tweets)} 条", file=sys.stderr)
        except Exception as e:
            errors.append(f"search({args.search}): {e}")

    # ── 按 likes+retweets 排序，优先返回高互动内容 ─────────────────────────────
    all_tweets.sort(key=lambda t: (t["likes"] + t["retweets"] * 2), reverse=True)

    output = {
        "tweets": all_tweets,
        "count": len(all_tweets),
        "sources_count": len(targets),
        "errors": errors,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "params": {
            "priority": args.priority,
            "teams": args.teams,
            "hours": args.hours,
        },
    }

    print(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"[INFO] 完成，共 {len(all_tweets)} 条推文", file=sys.stderr)


if __name__ == "__main__":
    main()
