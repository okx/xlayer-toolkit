#!/usr/bin/env python3
"""
discover_sources.py — 自动发现并更新 Web3 信息源（无需 Twitter API）

⚠️  本脚本是纯 Python 工具，配合 Claude 浏览器操作使用：
    Claude 负责实际浏览器导航 + JS 抠取，本脚本负责：
      1. 解析 sources.md，返回「已有账号集合」
      2. 接收 Claude 从 X.com 搜索/主页发现的新账号候选列表，做「是否已收录」判断
      3. 过滤 + 排序新候选账号，输出推荐列表
      4. 将确认账号写入 sources.md（append 模式）

典型工作流（在 SKILL.md 中描述）：
  Step A: python discover_sources.py --mode existing → 获取已有 handles 集合
  Step B: Claude 导航到关键词搜索页面 x.com/search?q=...&f=user，
           注入 EXTRACT_SEARCH_RESULTS 抠取搜索结果中的账号
  Step C: python discover_sources.py --mode compare --input candidates.json
           → 判断哪些是新账号，哪些已存在
  Step D: Claude 审阅推荐列表，确认后执行：
           python discover_sources.py --mode add --handle @xxx --description "..." --priority P1 --teams wallet,xlayer

子命令（--mode）：
  existing   输出 sources.md 中已有的 handle 集合
  compare    接收候选账号 JSON，输出新发现 vs 已有
  add        将单个新账号追加到 sources.md
  batch-add  批量添加账号（从 JSON 文件读取）
  stats      输出 sources.md 统计信息（各优先级、团队覆盖等）
"""

import os
import sys
import json
import re
import argparse
from datetime import date
from pathlib import Path

_HERE = Path(__file__).parent

SOURCES_CANDIDATES = [
    _HERE.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "skill-updates/web3-sources/references/sources.md",
]

# 关键词搜索建议（用于指导 Claude 做浏览器搜索）
SEARCH_KEYWORDS = {
    "wallet": [
        "web3 wallet developer",
        "smart account ERC-4337",
        "account abstraction wallet",
        "embedded wallet SDK",
    ],
    "xlayer": [
        "OP Stack L2 developer",
        "ZK rollup Ethereum",
        "Layer 2 infrastructure",
        "appchain sovereign rollup",
    ],
    "pay": [
        "PayFi stablecoin payment",
        "crypto payment infrastructure",
        "USDC USDT payment rails",
        "on-chain payment protocol",
    ],
    "defi": [
        "DeFi protocol developer",
        "AMM liquidity protocol",
        "lending protocol Ethereum",
        "yield aggregator DeFi",
    ],
    "dev": [
        "Ethereum developer tools",
        "blockchain SDK developer",
        "web3 dev infrastructure",
        "EVM toolchain developer",
    ],
}


def find_sources_md() -> Path:
    for p in SOURCES_CANDIDATES:
        if p.exists():
            return p
    return None


def load_sources(path: Path) -> list:
    """解析 sources.md，返回所有 {handle, priority, teams, name} 列表"""
    content = path.read_text(encoding="utf-8")
    pattern = r'\|\s*@(\w+)\s*\|\s*([^|]*)\|\s*([^|]*)\|\s*([^|]*)\|\s*(P\d)\s*\|\s*([^|]+)\|'
    sources = []
    for m in re.finditer(pattern, content):
        handle = m.group(1).strip().lower()
        name = m.group(2).strip()
        priority = m.group(5).strip()
        teams_raw = m.group(6).strip()
        teams = [t.strip() for t in re.split(r'[,，]', teams_raw) if t.strip()]
        sources.append({
            "handle": handle,
            "name": name,
            "priority": priority,
            "teams": teams,
        })
    return sources


def get_existing_set(path: Path) -> set:
    """返回已收录 handle 集合（小写）"""
    sources = load_sources(path)
    return {s["handle"] for s in sources}


def fmt_followers(n: int) -> str:
    if n >= 1_000_000:
        return "1M+"
    if n >= 500_000:
        return "500K+"
    if n >= 100_000:
        return "100K+"
    if n >= 50_000:
        return "50K+"
    if n >= 10_000:
        return "10K+"
    return f"{max(n // 1000, 1)}K+"


# ── 子命令实现 ────────────────────────────────────────────────────────────────

def mode_existing(args):
    """输出已有 handles 集合（供 Claude 比对用）"""
    path = find_sources_md()
    if not path:
        print(json.dumps({"error": "sources.md 未找到", "handles": [], "count": 0},
                         ensure_ascii=False, indent=2))
        sys.exit(1)

    sources = load_sources(path)
    existing = {s["handle"] for s in sources}

    # 统计信息
    by_priority = {}
    for s in sources:
        by_priority.setdefault(s["priority"], []).append(s["handle"])

    out = {
        "handles": sorted(existing),
        "count": len(existing),
        "by_priority": {k: len(v) for k, v in sorted(by_priority.items())},
        "search_keywords": SEARCH_KEYWORDS if args.with_keywords else None,
        "browser_instructions": (
            "Claude: 请在浏览器中执行以下步骤来发现新账号：\n"
            "1. 导航到 x.com/search?q={关键词}&f=user\n"
            "2. 等待 2s，注入 EXTRACT_SEARCH_RESULTS js 获取账号列表\n"
            "3. 也可以导航到 P0 账号主页，注入 EXTRACT_RELATED_ACCOUNTS 获取「你可能喜欢」\n"
            "4. 把发现的账号写入 candidates.json：\n"
            "   { \"candidates\": [{\"handle\": \"xxx\", \"followers\": 50000, "
            "\"description\": \"...\", \"source\": \"search:wallet\"}] }\n"
            "5. 然后运行：python discover_sources.py --mode compare --input candidates.json"
        ) if args.with_keywords else None,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def mode_compare(args):
    """比较候选账号 vs 已有账号，输出「新发现」列表"""
    if not args.input or not Path(args.input).exists():
        print(json.dumps({"error": f"input 文件不存在：{args.input}"}, ensure_ascii=False))
        sys.exit(1)

    path = find_sources_md()
    if not path:
        print(json.dumps({"error": "sources.md 未找到"}, ensure_ascii=False))
        sys.exit(1)

    existing = get_existing_set(path)

    raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
    candidates = raw.get("candidates") or raw.get("accounts") or raw.get("results") or []

    new_accounts = []
    already_in = []

    for c in candidates:
        handle = (c.get("handle") or c.get("username") or "").strip().lstrip("@").lower()
        if not handle:
            continue

        followers = int(c.get("followers") or c.get("followersCount") or 0)
        if followers < args.min_followers:
            continue

        entry = {
            "handle": handle,
            "display_name": c.get("name") or c.get("displayName") or handle,
            "followers": followers,
            "followers_fmt": fmt_followers(followers),
            "description": (c.get("description") or c.get("bio") or "")[:100],
            "source": c.get("source") or "unknown",
        }

        if handle in existing:
            already_in.append(entry)
        else:
            new_accounts.append(entry)

    # 按粉丝数排序
    new_accounts.sort(key=lambda x: x["followers"], reverse=True)

    # 生成 add 命令建议
    add_commands = []
    for a in new_accounts[:10]:
        cmd = (
            f"python discover_sources.py --mode add "
            f"--handle @{a['handle']} "
            f"\"{''.join(a['description'][:50].splitlines())}\" "
            f"--priority P2 --teams all"
        )
        add_commands.append(cmd)

    out = {
        "new_count": len(new_accounts),
        "existing_count": len(already_in),
        "new_accounts": new_accounts[:20],
        "already_in_sources": [a["handle"] for a in already_in],
        "suggested_add_commands": add_commands,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def mode_add(args):
    """将单个账号追加到 sources.md"""
    path = find_sources_md()
    if not path:
        print(json.dumps({"error": "sources.md 未找到", "ok": False}, ensure_ascii=False))
        sys.exit(1)

    handle = args.handle.lstrip("@").strip()
    existing = get_existing_set(path)

    if handle.lower() in existing:
        print(json.dumps({"ok": False, "reason": f"@{handle} 已存在于 sources.md"}, ensure_ascii=False))
        return

    # 构造新行
    today = date.today().isoformat()
    display_name = args.display_name or handle
    description = args.description or "—"
    followers_fmt = fmt_followers(args.followers) if args.followers else "—"
    new_row = f"| @{handle} | {display_name} | {description} | {followers_fmt} | {args.priority} | {args.teams} | {today} |"

    # 找到目标分类插入位置
    content = path.read_text(encoding="utf-8")
    lines = content.split("\n")

    category = args.category
    insert_idx = len(lines)
    in_section = False
    last_table_row = -1

    for i, line in enumerate(lines):
        # 检测 section header（模糊匹配）
        cat_pattern = re.escape(category).replace(r"\ ", ".*").replace(r"\&", ".*")
        if re.search(cat_pattern, line, re.IGNORECASE) and line.startswith("#"):
            in_section = True
            last_table_row = -1
            continue
        if in_section:
            if line.startswith("|") and not line.startswith("|---"):
                last_table_row = i
            elif line.startswith("##") and last_table_row > 0:
                insert_idx = last_table_row + 1
                break

    if last_table_row > 0 and insert_idx == len(lines):
        insert_idx = last_table_row + 1

    lines.insert(insert_idx, new_row)
    path.write_text("\n".join(lines), encoding="utf-8")

    out = {
        "ok": True,
        "added": f"@{handle}",
        "row": new_row,
        "line": insert_idx + 1,
        "category": category,
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def mode_batch_add(args):
    """从 JSON 文件批量添加账号"""
    if not args.input or not Path(args.input).exists():
        print(json.dumps({"error": f"input 文件不存在：{args.input}"}, ensure_ascii=False))
        sys.exit(1)

    raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
    accounts = raw.get("accounts") or raw.get("new_accounts") or []

    results = {"added": [], "skipped": [], "errors": []}

    for a in accounts:
        handle = (a.get("handle") or "").lstrip("@").strip()
        if not handle:
            continue
        # 构造 args-like 对象
        class FakeArgs:
            pass
        fa = FakeArgs()
        fa.handle = handle
        fa.display_name = a.get("display_name") or a.get("name") or handle
        fa.description = (a.get("description") or "")[:80]
        fa.followers = int(a.get("followers") or 0)
        fa.priority = a.get("priority") or "P2"
        fa.teams = a.get("teams") or "all"
        fa.category = a.get("category") or "行业媒体 & KOL"

        try:
            path = find_sources_md()
            if not path:
                results["errors"].append(f"@{handle}: sources.md 未找到")
                continue

            existing = get_existing_set(path)
            if handle.lower() in existing:
                results["skipped"].append(handle)
                continue

            mode_add(fa)
            results["added"].append(handle)
        except Exception as e:
            results["errors"].append(f"@{handle}: {e}")

    print(json.dumps(results, ensure_ascii=False, indent=2))


def mode_stats(args):
    """输出 sources.md 统计信息"""
    path = find_sources_md()
    if not path:
        print(json.dumps({"error": "sources.md 未找到"}, ensure_ascii=False))
        sys.exit(1)

    sources = load_sources(path)
    total = len(sources)

    by_priority = {}
    by_team = {}
    for s in sources:
        by_priority.setdefault(s["priority"], 0)
        by_priority[s["priority"]] += 1
        for team in s["teams"]:
            by_team.setdefault(team, 0)
            by_team[team] += 1

    out = {
        "total": total,
        "by_priority": dict(sorted(by_priority.items())),
        "by_team": dict(sorted(by_team.items(), key=lambda x: -x[1])),
        "sources_path": str(path),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Web3 信息源发现与更新工具（无需 Twitter API）")
    parser.add_argument("--mode",
                        choices=["existing", "compare", "add", "batch-add", "stats"],
                        default="existing", help="运行模式")

    # existing
    parser.add_argument("--with-keywords", action="store_true", dest="with_keywords",
                        help="输出关键词搜索建议（existing 模式）")

    # compare
    parser.add_argument("--input", default="", help="候选账号 JSON 文件路径（compare/batch-add 模式）")
    parser.add_argument("--min-followers", type=int, default=5000, dest="min_followers",
                        help="最小粉丝数门槛（默认：5000）")

    # add
    parser.add_argument("--handle", default="", help="Twitter handle（add 模式），如 @VitalikButerin")
    parser.add_argument("description", nargs="?", default="", help="账号描述")
    parser.add_argument("--display-name", default="", dest="display_name", help="显示名称")
    parser.add_argument("--followers", type=int, default=0, help="粉丝数（用于格式化）")
    parser.add_argument("--priority", default="P2", help="优先级（默认：P2）")
    parser.add_argument("--teams", default="all", help="团队标签，逗号分隔（默认：all）")
    parser.add_argument("--category", default="行业媒体 & KOL",
                        help="插入分类（默认：行业媒体 & KOL）")

    args = parser.parse_args()

    if args.mode == "existing":
        mode_existing(args)
    elif args.mode == "compare":
        mode_compare(args)
    elif args.mode == "add":
        if not args.handle:
            print(json.dumps({"error": "--handle 必填"}, ensure_ascii=False))
            sys.exit(1)
        mode_add(args)
    elif args.mode == "batch-add":
        mode_batch_add(args)
    elif args.mode == "stats":
        mode_stats(args)


if __name__ == "__main__":
    main()
