#!/usr/bin/env python3
"""
验证 Twitter 账号并维护 sources.md 信息源列表。

子命令：
  add      <@handle> "<描述>" [--category ...] [--priority P1] [--teams xlayer,wallet]
             验证账号真实存在后，添加到 sources.md 对应分类中

  discover <@handle>
             查看该账号的 KOL 关注者，发现潜在新信息源

  verify   [--priority P0]
             批量验证 sources.md 中现有账号是否仍活跃，输出失效账号列表

  search   "<关键词>" [--min-followers 50000]
             搜索与关键词相关的活跃账号（通过关键词搜推文，再提取作者）

用法示例：
  export TWITTER_TOKEN=your_token

  # 添加新账号
  python update_sources.py add @jessepollak "Base 链创建者" --category "核心开发者" --priority P0 --teams xlayer,wallet

  # 从 Vitalik 的 KOL 关注者发现新账号
  python update_sources.py discover @VitalikButerin

  # 批量验证 P0 账号是否仍活跃
  python update_sources.py verify --priority P0

  # 搜索"ZK proof"相关活跃账号
  python update_sources.py search "ZK proof" --min-followers 10000
"""

import os
import sys
import json
import re
import argparse
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from twitter_api import (
    TOKEN, get_user_info, get_kol_followers, search_tweets,
    extract_tweets, extract_user
)

# ── sources.md 路径 ────────────────────────────────────────────────────────────
_HERE = Path(__file__).parent
SOURCES_CANDIDATES = [
    _HERE.parent / "web3-sources/references/sources.md",
    _HERE.parent.parent / "web3-sources/references/sources.md",
]


def find_sources_md() -> Path:
    for p in SOURCES_CANDIDATES:
        if p.exists():
            return p
    raise FileNotFoundError(f"sources.md 未找到，已尝试：{SOURCES_CANDIDATES}")


# ── 工具函数 ───────────────────────────────────────────────────────────────────

def fmt_followers(n: int) -> str:
    if n >= 1_000_000: return "1M+"
    if n >= 500_000:   return "500K+"
    if n >= 100_000:   return "100K+"
    if n >= 50_000:    return "50K+"
    if n >= 10_000:    return "10K+"
    return f"{n//1000}K+"


def verify_handle(handle: str) -> dict:
    """验证账号是否存在，返回用户信息"""
    try:
        resp = get_user_info(handle.lstrip("@"))
        user = extract_user(resp)
        if not user:
            return {"exists": False, "error": "API 返回空数据"}
        return {
            "exists": True,
            "username": user.get("username") or user.get("screen_name") or handle.lstrip("@"),
            "name": user.get("name") or user.get("displayName") or "",
            "followers": int(user.get("followersCount") or user.get("followers_count") or 0),
            "verified": bool(user.get("isVerified") or user.get("verified") or False),
            "description": (user.get("description") or "")[:100],
        }
    except Exception as e:
        return {"exists": False, "error": str(e)}


def get_existing_handles(sources_path: Path) -> set:
    """获取 sources.md 中已有的所有 handle（小写）"""
    content = sources_path.read_text(encoding="utf-8")
    return set(m.group(1).lower() for m in re.finditer(r'\|\s*@(\w+)\s*\|', content))


# ── 子命令：add ────────────────────────────────────────────────────────────────

def cmd_add(args):
    sources_path = find_sources_md()
    handle = args.handle.lstrip("@")

    # 检查是否已存在
    existing = get_existing_handles(sources_path)
    if handle.lower() in existing:
        print(f"⚠️  @{handle} 已在 sources.md 中，跳过添加")
        return

    # 验证账号
    print(f"🔍 验证 @{handle} ...")
    info = verify_handle(handle)
    if not info["exists"]:
        print(f"❌ 账号不存在或无法访问：{info.get('error')}")
        sys.exit(1)

    followers_str = fmt_followers(info["followers"])
    today = date.today().isoformat()
    description = args.description or info["description"] or "—"
    new_row = f"| @{handle} | {info['name'] or handle} | {description} | {followers_str} | {args.priority} | {args.teams} | {today} |"

    print(f"✅ 账号验证成功：")
    print(f"   名称：{info['name']}")
    print(f"   粉丝：{info['followers']:,} ({followers_str})")
    print(f"   简介：{info['description']}")
    print(f"\n📝 即将添加到「{args.category}」：")
    print(f"   {new_row}")

    content = sources_path.read_text(encoding="utf-8")
    lines = content.split("\n")

    # 找到对应 category section 末尾的表格行后面插入
    insert_idx = len(lines)
    in_section = False
    last_table_row = -1

    for i, line in enumerate(lines):
        # 检测 section header
        if re.search(args.category.replace(" ", ".*").replace("&", ".*"), line, re.IGNORECASE) and line.startswith("#"):
            in_section = True
            last_table_row = -1
            continue
        if in_section:
            if line.startswith("|") and not line.startswith("|---"):
                last_table_row = i
            elif line.startswith("##") and last_table_row > 0:
                # 下一个 section 开始了
                insert_idx = last_table_row + 1
                break

    if last_table_row > 0 and insert_idx == len(lines):
        insert_idx = last_table_row + 1

    lines.insert(insert_idx, new_row)
    sources_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n✅ 已成功添加到 sources.md（第 {insert_idx + 1} 行）")


# ── 子命令：discover ───────────────────────────────────────────────────────────

def cmd_discover(args):
    handle = args.handle.lstrip("@")
    print(f"🔍 获取 @{handle} 的 KOL 关注者...\n")

    try:
        resp = get_kol_followers(handle)
        followers = resp.get("data") or resp.get("followers") or []
        if isinstance(followers, dict):
            followers = followers.get("list") or followers.get("users") or []
    except Exception as e:
        print(f"❌ 请求失败：{e}")
        sys.exit(1)

    if not followers:
        print("未找到 KOL 关注者数据")
        return

    sources_path = find_sources_md()
    existing = get_existing_handles(sources_path)

    print(f"{'Handle':<28} {'名称':<22} {'粉丝':>10}  {'是否已收录'}")
    print("─" * 80)

    new_candidates = []
    for f in followers[:30]:
        uname = (f.get("username") or f.get("screen_name") or "").strip()
        name = (f.get("name") or f.get("displayName") or "")[:20]
        fc = int(f.get("followersCount") or f.get("followers_count") or 0)
        in_sources = "✅ 已收录" if uname.lower() in existing else "⭐ 待添加"
        print(f"@{uname:<27} {name:<22} {fc:>10,}  {in_sources}")
        if uname.lower() not in existing and fc >= 10000:
            new_candidates.append({"handle": uname, "name": name, "followers": fc})

    print(f"\n💡 发现 {len(new_candidates)} 个未收录的潜在信息源（粉丝 > 10K）")
    if new_candidates:
        print("\n可以用以下命令添加：")
        for c in new_candidates[:5]:
            print(f'  python update_sources.py add @{c["handle"]} "{c["name"]}" --priority P2 --teams all')


# ── 子命令：verify ─────────────────────────────────────────────────────────────

def cmd_verify(args):
    sources_path = find_sources_md()
    content = sources_path.read_text(encoding="utf-8")

    # 提取所有 handle
    allowed_priorities = set(p.strip() for p in args.priority.split(","))
    pattern = r'\|\s*(@\w+)\s*\|[^|]*\|[^|]*\|[^|]*\|\s*(P\d)\s*\|'
    handles = [(m.group(1).lstrip("@"), m.group(2)) for m in re.finditer(pattern, content)
               if m.group(2) in allowed_priorities]

    print(f"🔍 验证 {len(handles)} 个账号（优先级：{args.priority}）...\n")

    ok, failed = [], []
    for handle, priority in handles:
        info = verify_handle(handle)
        if info["exists"]:
            ok.append(handle)
            print(f"  ✓ @{handle:<30} {info['followers']:>10,} 粉丝")
        else:
            failed.append((handle, info.get("error", "未知错误")))
            print(f"  ✗ @{handle:<30} ❌ {info.get('error', '')}")

    print(f"\n📊 结果：{len(ok)} 个正常 / {len(failed)} 个失效")
    if failed:
        print("\n失效账号（建议从 sources.md 移除或更新）：")
        for h, err in failed:
            print(f"  @{h}: {err}")


# ── 子命令：search ─────────────────────────────────────────────────────────────

def cmd_search(args):
    print(f"🔍 搜索「{args.keyword}」相关账号...\n")

    sources_path = find_sources_md()
    existing = get_existing_handles(sources_path)

    try:
        resp = search_tweets(
            keywords=args.keyword,
            exclude_retweets=True,
            min_likes=50,
            max_results=50,
            product="Top",
        )
        tweets = extract_tweets(resp)
    except Exception as e:
        print(f"❌ 搜索失败：{e}")
        sys.exit(1)

    # 提取作者信息（去重）
    seen = {}
    for t in tweets:
        author = t.get("author") or t.get("user") or {}
        if isinstance(author, dict):
            uname = (author.get("username") or author.get("screen_name") or "").strip()
            if not uname:
                continue
            fc = int(author.get("followersCount") or author.get("followers_count") or 0)
            if fc >= args.min_followers and uname.lower() not in seen:
                seen[uname] = {
                    "handle": uname,
                    "name": author.get("name") or author.get("displayName") or "",
                    "followers": fc,
                    "in_sources": uname.lower() in existing,
                }

    candidates = sorted(seen.values(), key=lambda x: x["followers"], reverse=True)

    if not candidates:
        print("未找到符合条件的账号（可能 API 响应中未包含作者信息）")
        return

    print(f"{'Handle':<28} {'名称':<22} {'粉丝':>10}  {'是否已收录'}")
    print("─" * 80)
    for c in candidates[:20]:
        status = "✅ 已收录" if c["in_sources"] else "⭐ 待添加"
        print(f"@{c['handle']:<27} {c['name']:<22} {c['followers']:>10,}  {status}")

    new = [c for c in candidates if not c["in_sources"]]
    print(f"\n💡 {len(new)} 个未收录账号，用以下命令添加：")
    for c in new[:5]:
        print(f'  python update_sources.py add @{c["handle"]} "{c["name"]}" --priority P2 --teams all')


# ── main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Web3 Twitter 信息源维护工具")
    sub = parser.add_subparsers(dest="cmd")

    # add
    p_add = sub.add_parser("add", help="添加新信息源")
    p_add.add_argument("handle", help="Twitter handle，如 @VitalikButerin")
    p_add.add_argument("description", nargs="?", default="", help="账号描述")
    p_add.add_argument("--category", default="行业媒体 & KOL", help="插入的分类名（默认：行业媒体 & KOL）")
    p_add.add_argument("--priority", default="P2", help="优先级 P0/P1/P2（默认：P2）")
    p_add.add_argument("--teams", default="all", help="团队标签，逗号分隔（默认：all）")

    # discover
    p_disc = sub.add_parser("discover", help="从 KOL 关注者发现新信息源")
    p_disc.add_argument("handle", help="目标账号")

    # verify
    p_ver = sub.add_parser("verify", help="批量验证账号活跃状态")
    p_ver.add_argument("--priority", default="P0,P1", help="验证的优先级（默认：P0,P1）")

    # search
    p_srch = sub.add_parser("search", help="通过关键词发现相关账号")
    p_srch.add_argument("keyword", help="搜索关键词")
    p_srch.add_argument("--min-followers", type=int, default=10000, dest="min_followers",
                        help="最小粉丝数（默认：10000）")

    args = parser.parse_args()

    if not TOKEN:
        print("❌ TWITTER_TOKEN 未设置")
        print("   请访问 https://6551.io/mcp 获取 token")
        print("   然后：export TWITTER_TOKEN=your_token_here")
        sys.exit(1)

    if args.cmd == "add":
        cmd_add(args)
    elif args.cmd == "discover":
        cmd_discover(args)
    elif args.cmd == "verify":
        cmd_verify(args)
    elif args.cmd == "search":
        cmd_search(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
