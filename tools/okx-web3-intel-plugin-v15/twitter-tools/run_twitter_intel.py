#!/usr/bin/env python3
"""
run_twitter_intel.py — 浏览器抓取模式的推文采集辅助工具

⚠️  本脚本不直接控制浏览器，而是与 Claude 协同运行：
    Claude 负责调用 mcp__Claude_in_Chrome__javascript_tool 进行实际抓取，
    本脚本负责：
      1. 读取 sources.md，输出待抓取账号列表（--mode list）
      2. 接收 Claude 抓取结果，过滤 + 去重 + 时间筛选（--mode filter）
      3. 写入/读取本地缓存（--mode save / --mode load）
      4. 与 sent_history.md 去重（--mode dedup）

在 SKILL.md 中的典型用法：
    python run_twitter_intel.py --mode list --priority P0,P1 --hours 6
    → 输出 JSON，Claude 遍历 handles 做浏览器抓取
    → Claude 把结果汇总写入 /tmp/raw_tweets.json
    python run_twitter_intel.py --mode filter --input /tmp/raw_tweets.json --hours 6
    → 输出过滤后的 JSON，进入 intel-filter 矩阵

子命令（--mode）：
  list     读 sources.md，输出 {handles, count, config}
  filter   读原始推文 JSON，时间过滤 + 去重，输出精炼 JSON
  save     将过滤后推文保存到缓存文件
  dedup    与 sent_history.md 比较，去掉已推送内容
  merge    合并多个来源 JSON（用于关键词搜索结果 + 用户推文合并）
"""

import os
import sys
import json
import re
import hashlib
import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path

_HERE = Path(__file__).parent

# ── 路径查找 ──────────────────────────────────────────────────────────────────

SOURCES_CANDIDATES = [
    _HERE.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "skill-updates/web3-sources/references/sources.md",
]

SENT_HISTORY_CANDIDATES = [
    _HERE.parent.parent / "outputs/sent_history.md",
    _HERE.parent / "../../outputs/sent_history.md",
]

CACHE_DIR = _HERE.parent.parent / "outputs" / "twitter_cache"


def find_file(candidates):
    for p in candidates:
        if p.exists():
            return p
    return None


# ── sources.md 解析 ───────────────────────────────────────────────────────────

def parse_sources(path: Path, priority_filter: set, team_filter: set) -> list:
    """解析 sources.md 表格，按优先级和团队过滤，返回账号列表"""
    content = path.read_text(encoding="utf-8")
    pattern = r'\|\s*(@\w+)\s*\|[^|]*\|[^|]*\|[^|]*\|\s*(P\d)\s*\|\s*([^|]+)\|'
    sources = []
    seen = set()

    for m in re.finditer(pattern, content):
        handle = m.group(1).lstrip("@").strip()
        priority = m.group(2).strip()
        teams_raw = m.group(3).strip()
        teams = [t.strip() for t in re.split(r'[,，]', teams_raw) if t.strip()]

        if not handle or handle.lower() in seen:
            continue
        if priority not in priority_filter:
            continue
        if "all" not in team_filter:
            if not (team_filter & (set(teams) | {"all"})):
                continue

        seen.add(handle.lower())
        sources.append({
            "handle": handle,
            "priority": priority,
            "teams": teams,
        })

    return sources


# ── 推文过滤 ──────────────────────────────────────────────────────────────────

def tweet_fingerprint(tweet: dict) -> str:
    """生成推文去重指纹（URL 优先，否则用文本 hash）"""
    url = tweet.get("url", "").strip()
    if url and "/status/" in url:
        return url
    text = tweet.get("text", "").strip()[:120]
    return hashlib.md5(text.encode()).hexdigest()


def filter_tweets(tweets: list, hours: int, min_likes: int = 0) -> list:
    """时间过滤 + 品质过滤"""
    if hours <= 0:
        return tweets

    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    result = []

    for t in tweets:
        # 时间过滤
        created = t.get("created_at") or t.get("time") or ""
        if created:
            try:
                dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                if dt < cutoff:
                    continue
            except (ValueError, TypeError):
                pass  # 解析失败则不过滤

        # 互动量过滤
        likes = int(t.get("likes", 0) or 0)
        if likes < min_likes:
            continue

        # 过滤空文本
        if not (t.get("text") or "").strip():
            continue

        result.append(t)

    return result


def dedup_tweets(tweets: list) -> list:
    """推文内部去重"""
    seen = set()
    result = []
    for t in tweets:
        fp = tweet_fingerprint(t)
        if fp not in seen:
            seen.add(fp)
            result.append(t)
    return result


# ── sent_history 去重 ─────────────────────────────────────────────────────────

def load_sent_fingerprints(history_path: Path) -> set:
    """从 sent_history.md 提取已推送内容的指纹"""
    if not history_path or not history_path.exists():
        return set()

    content = history_path.read_text(encoding="utf-8")
    fps = set()

    # 提取 URL（x.com/status/...）
    for url in re.findall(r'https://x\.com/\S+/status/\d+', content):
        fps.add(url.split("?")[0].rstrip("/"))

    # 提取文本 hash（若有）
    for m in re.finditer(r'\[fp:([a-f0-9]{32})\]', content):
        fps.add(m.group(1))

    return fps


def dedup_against_history(tweets: list, history_path: Path) -> tuple:
    """去掉已推送的推文，返回 (新推文列表, 被去掉数量)"""
    sent = load_sent_fingerprints(history_path)
    result = []
    removed = 0
    for t in tweets:
        fp = tweet_fingerprint(t)
        if fp in sent:
            removed += 1
        else:
            result.append(t)
    return result, removed


# ── 主逻辑 ────────────────────────────────────────────────────────────────────

def mode_list(args):
    """输出待抓取账号列表，供 Claude 浏览器循环使用"""
    sources_path = find_file(SOURCES_CANDIDATES)
    if not sources_path:
        out = {"error": "sources.md 未找到", "handles": [], "count": 0}
        print(json.dumps(out, ensure_ascii=False, indent=2))
        sys.exit(1)

    priority_filter = set(p.strip() for p in args.priority.split(","))
    team_filter = set(t.strip() for t in args.teams.split(","))

    sources = parse_sources(sources_path, priority_filter, team_filter)

    out = {
        "handles": sources,
        "count": len(sources),
        "config": {
            "priority": args.priority,
            "teams": args.teams,
            "hours": args.hours,
            "max_per_user": args.max_per_user,
        },
        "js_script_path": str(_HERE / "browser_twitter_tools.js"),
        "instructions": (
            "Claude: 请对 handles 列表中每个账号执行以下步骤：\n"
            "1. navigate to https://x.com/{handle}\n"
            "2. wait 2s for page load\n"
            "3. inject EXTRACT_TWEETS js snippet\n"
            "4. collect result\n"
            "完成后将所有推文合并写入 /tmp/raw_tweets.json，格式：\n"
            "{ \"tweets\": [...], \"scraped_at\": \"ISO timestamp\" }"
        ),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def mode_filter(args):
    """读取原始推文 JSON，过滤 + 去重"""
    if not args.input or not Path(args.input).exists():
        print(json.dumps({"error": f"input 文件不存在：{args.input}", "tweets": [], "count": 0},
                         ensure_ascii=False))
        sys.exit(1)

    raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
    tweets = raw.get("tweets") or raw.get("results") or []

    # 统一字段名（兼容 browser DOM 抠取格式 和 API 格式）
    normalized = []
    for t in tweets:
        normalized.append({
            "source": f"@{t.get('handle', t.get('source', 'unknown'))}".lstrip("@"),
            "text": (t.get("text") or "").strip(),
            "created_at": t.get("time") or t.get("created_at") or "",
            "url": t.get("url") or "",
            "likes": int(t.get("likes", 0) or 0),
            "retweets": int(t.get("retweets", 0) or 0),
            "replies": int(t.get("replies", 0) or 0),
            "priority": t.get("priority", "P1"),
            "teams": t.get("teams", ["all"]),
            "is_retweet": t.get("is_retweet", False),
        })

    # 过滤转推（可选）
    if args.no_retweets:
        normalized = [t for t in normalized if not t["is_retweet"]]

    # 时间过滤
    filtered = filter_tweets(normalized, args.hours, args.min_likes)

    # 内部去重
    deduped = dedup_tweets(filtered)

    # sent_history 去重
    removed = 0
    if not args.no_history_dedup:
        history_path = find_file(SENT_HISTORY_CANDIDATES)
        if history_path:
            deduped, removed = dedup_against_history(deduped, history_path)

    # 按互动量排序
    deduped.sort(key=lambda t: (t["likes"] + t["retweets"] * 2), reverse=True)

    out = {
        "tweets": deduped,
        "count": len(deduped),
        "stats": {
            "raw_count": len(tweets),
            "after_time_filter": len(filtered),
            "after_dedup": len(deduped) + removed,
            "removed_by_history": removed,
            "final_count": len(deduped),
        },
        "filtered_at": datetime.now(timezone.utc).isoformat(),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def mode_save(args):
    """将推文 JSON 保存到本地缓存"""
    if not args.input:
        print(json.dumps({"error": "--input 必填"}))
        sys.exit(1)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M")
    cache_file = CACHE_DIR / f"tweets_{timestamp}.json"

    content = Path(args.input).read_text(encoding="utf-8")
    cache_file.write_text(content, encoding="utf-8")
    print(json.dumps({"saved": str(cache_file), "ok": True}, ensure_ascii=False))


def mode_merge(args):
    """合并多个推文 JSON 文件"""
    all_tweets = []
    for f in args.files:
        p = Path(f)
        if p.exists():
            data = json.loads(p.read_text(encoding="utf-8"))
            tweets = data.get("tweets") or data.get("results") or []
            all_tweets.extend(tweets)

    deduped = dedup_tweets(all_tweets)
    deduped.sort(key=lambda t: (int(t.get("likes", 0) or 0) + int(t.get("retweets", 0) or 0) * 2),
                 reverse=True)
    out = {
        "tweets": deduped,
        "count": len(deduped),
        "source_files": args.files,
        "merged_at": datetime.now(timezone.utc).isoformat(),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Twitter 浏览器采集辅助工具（无需 API）")
    parser.add_argument("--mode", choices=["list", "filter", "save", "merge"],
                        default="list", help="运行模式（默认：list）")

    # list / filter 共用参数
    parser.add_argument("--priority", default="P0,P1", help="优先级，逗号分隔（默认：P0,P1）")
    parser.add_argument("--teams", default="all", help="团队标签（默认：all）")
    parser.add_argument("--hours", type=int, default=6, help="时间过滤：最近 N 小时（默认：6）")
    parser.add_argument("--max-per-user", type=int, default=5, dest="max_per_user",
                        help="每账号最多抓取条数（仅 list 模式输出，Claude 自行控制）")

    # filter 参数
    parser.add_argument("--input", default="", help="输入 JSON 文件路径（filter/save 模式）")
    parser.add_argument("--min-likes", type=int, default=0, dest="min_likes",
                        help="最小点赞数过滤（默认：0）")
    parser.add_argument("--no-retweets", action="store_true", dest="no_retweets",
                        help="过滤转推")
    parser.add_argument("--no-history-dedup", action="store_true", dest="no_history_dedup",
                        help="不与 sent_history 比较去重")

    # merge 参数
    parser.add_argument("--files", nargs="+", default=[], help="要合并的 JSON 文件列表（merge 模式）")

    args = parser.parse_args()

    if args.mode == "list":
        mode_list(args)
    elif args.mode == "filter":
        mode_filter(args)
    elif args.mode == "save":
        mode_save(args)
    elif args.mode == "merge":
        mode_merge(args)


if __name__ == "__main__":
    main()
