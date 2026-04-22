"""
6551.io Twitter & News API 同步客户端
API base: https://ai.6551.io
Token:    TWITTER_TOKEN 或 OPENNEWS_TOKEN 环境变量
"""

import os
import requests

API_BASE = os.environ.get("TWITTER_API_BASE", "https://ai.6551.io").rstrip("/")
TOKEN = os.environ.get("TWITTER_TOKEN") or os.environ.get("OPENNEWS_TOKEN", "")


def _headers():
    return {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    }


def _post(endpoint: str, body: dict) -> dict:
    resp = requests.post(f"{API_BASE}{endpoint}", headers=_headers(), json=body, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _get(endpoint: str) -> dict:
    resp = requests.get(f"{API_BASE}{endpoint}", headers=_headers(), timeout=30)
    resp.raise_for_status()
    return resp.json()


# ── Twitter endpoints ──────────────────────────────────────────────────────────

def get_user_info(username: str) -> dict:
    """POST /open/twitter_user_info — 按用户名获取用户资料"""
    return _post("/open/twitter_user_info", {"username": username.lstrip("@")})


def get_user_info_by_id(user_id: str) -> dict:
    """POST /open/twitter_user_by_id — 按 ID 获取用户资料"""
    return _post("/open/twitter_user_by_id", {"userId": user_id})


def get_user_tweets(
    username: str,
    max_results: int = 20,
    product: str = "Latest",
    include_replies: bool = False,
    include_retweets: bool = False,
) -> dict:
    """POST /open/twitter_user_tweets — 获取指定用户的最新推文"""
    return _post("/open/twitter_user_tweets", {
        "username": username.lstrip("@"),
        "maxResults": max_results,
        "product": product,
        "includeReplies": include_replies,
        "includeRetweets": include_retweets,
    })


def search_tweets(
    keywords: str = "",
    from_user: str = "",
    to_user: str = "",
    mention_user: str = "",
    hashtag: str = "",
    exclude_replies: bool = False,
    exclude_retweets: bool = True,
    min_likes: int = 0,
    min_retweets: int = 0,
    since_date: str = "",
    until_date: str = "",
    lang: str = "",
    product: str = "Top",
    max_results: int = 20,
) -> dict:
    """POST /open/twitter_search — 高级搜索"""
    body: dict = {"maxResults": max_results, "product": product}
    if keywords:       body["keywords"] = keywords
    if from_user:      body["fromUser"] = from_user.lstrip("@")
    if to_user:        body["toUser"] = to_user.lstrip("@")
    if mention_user:   body["mentionUser"] = mention_user.lstrip("@")
    if hashtag:        body["hashtag"] = hashtag.lstrip("#")
    if exclude_replies:  body["excludeReplies"] = True
    if exclude_retweets: body["excludeRetweets"] = True
    if min_likes > 0:  body["minLikes"] = min_likes
    if min_retweets > 0: body["minRetweets"] = min_retweets
    if since_date:     body["sinceDate"] = since_date
    if until_date:     body["untilDate"] = until_date
    if lang:           body["lang"] = lang
    return _post("/open/twitter_search", body)


def get_follower_events(username: str, is_follow: bool = True, max_results: int = 20) -> dict:
    """POST /open/twitter_follower_events — 关注/取关事件"""
    return _post("/open/twitter_follower_events", {
        "username": username.lstrip("@"),
        "isFollow": is_follow,
        "maxResults": max_results,
    })


def get_kol_followers(username: str) -> dict:
    """POST /open/twitter_kol_followers — 该账号的 KOL 关注者"""
    return _post("/open/twitter_kol_followers", {"username": username.lstrip("@")})


def get_deleted_tweets(username: str, max_results: int = 20) -> dict:
    """POST /open/twitter_deleted_tweets — 已删除推文"""
    return _post("/open/twitter_deleted_tweets", {
        "username": username.lstrip("@"),
        "maxResults": max_results,
    })


# ── News endpoints ─────────────────────────────────────────────────────────────

def get_news_types() -> dict:
    """GET /open/news_type — 获取所有新闻源分类"""
    return _get("/open/news_type")


def search_news(
    query: str = "",
    coins: list = None,
    engine_types: dict = None,
    has_coin: bool = False,
    limit: int = 20,
    page: int = 1,
) -> dict:
    """POST /open/news_search — 搜索新闻"""
    body: dict = {"limit": limit, "page": page}
    if query:        body["q"] = query
    if coins:        body["coins"] = coins
    if engine_types: body["engineTypes"] = engine_types
    if has_coin:     body["hasCoin"] = has_coin
    return _post("/open/news_search", body)


# ── 工具函数 ───────────────────────────────────────────────────────────────────

def extract_tweets(api_response: dict) -> list:
    """从 API 响应中统一提取推文列表"""
    data = api_response.get("data") or api_response.get("tweets") or []
    if isinstance(data, dict):
        data = data.get("tweets") or data.get("list") or []
    return data if isinstance(data, list) else []


def extract_user(api_response: dict) -> dict:
    """从 API 响应中统一提取用户信息"""
    data = api_response.get("data") or api_response.get("user") or {}
    if isinstance(data, list) and data:
        return data[0]
    return data if isinstance(data, dict) else {}


def tweet_url(username: str, tweet_id: str) -> str:
    return f"https://x.com/{username.lstrip('@')}/status/{tweet_id}"
