/**
 * browser_twitter_tools.js
 * 在 X.com 页面内执行的 DOM 抓取函数集合
 * 通过 mcp__Claude_in_Chrome__javascript_tool 注入执行
 * 无需 API Token，直接利用已登录的浏览器 session
 */

// ── 核心：提取当前页面所有推文 ────────────────────────────────────────────────
const EXTRACT_TWEETS = `
(function() {
  const articles = document.querySelectorAll('article[data-testid="tweet"]');
  const tweets = [];

  articles.forEach(article => {
    const textEl  = article.querySelector('[data-testid="tweetText"]');
    const timeEl  = article.querySelector('time');
    const likeEl  = article.querySelector('[data-testid="like"]');
    const rtEl    = article.querySelector('[data-testid="retweet"]');
    const replyEl = article.querySelector('[data-testid="reply"]');
    // 找到推文本身的链接（跳过转推来源链接）
    const links   = article.querySelectorAll('a[href*="/status/"]');
    const tweetLink = Array.from(links).find(a => !a.href.includes('photo') && !a.href.includes('analytics'));

    if (!textEl) return;

    // 解析数字（"3986 喜欢次数" → 3986）
    function parseCount(label) {
      if (!label) return 0;
      const m = label.match(/^([\\d,]+)/);
      return m ? parseInt(m[1].replace(/,/g, '')) : 0;
    }

    // 提取用户名（从 tweet URL）
    let handle = '';
    if (tweetLink) {
      const m = tweetLink.href.match(/x\\.com\\/([^\\/]+)\\/status/);
      if (m) handle = m[1];
    }

    // 跳过转推（推文链接账号和页面账号不同时可能是转推）
    const isRetweet = !!article.querySelector('[data-testid="socialContext"]');

    tweets.push({
      handle:   handle,
      text:     textEl.innerText.replace(/\\n+/g, ' ').trim(),
      time:     timeEl ? timeEl.getAttribute('datetime') : '',
      url:      tweetLink ? tweetLink.href : '',
      likes:    parseCount(likeEl ? likeEl.getAttribute('aria-label') : ''),
      retweets: parseCount(rtEl ? rtEl.getAttribute('aria-label') : ''),
      replies:  parseCount(replyEl ? replyEl.getAttribute('aria-label') : ''),
      is_retweet: isRetweet,
    });
  });

  return JSON.stringify({ count: tweets.length, tweets: tweets });
})()
`;

// ── 提取用户资料（在用户主页执行）──────────────────────────────────────────────
const EXTRACT_USER_PROFILE = `
(function() {
  const nameEl    = document.querySelector('[data-testid="UserName"]');
  const bioEl     = document.querySelector('[data-testid="UserDescription"]');
  const statsEls  = document.querySelectorAll('[href*="/followers"], [href*="/following"]');

  // followers 数量（从 aria-label 或文本）
  const followersEl = document.querySelector('a[href$="/verified_followers"], a[href$="/followers"]');
  const followersText = followersEl ? followersEl.innerText : '';

  return JSON.stringify({
    name: nameEl ? nameEl.innerText.split('\\n')[0] : '',
    bio:  bioEl  ? bioEl.innerText  : '',
    followers_text: followersText,
    url: window.location.href,
  });
})()
`;

// ── 搜索页面提取推文（在 x.com/search?q=... 执行）────────────────────────────
const EXTRACT_SEARCH_RESULTS = `
(function() {
  const articles = document.querySelectorAll('article[data-testid="tweet"]');
  const results = [];

  articles.forEach(article => {
    const textEl  = article.querySelector('[data-testid="tweetText"]');
    const timeEl  = article.querySelector('time');
    const likeEl  = article.querySelector('[data-testid="like"]');
    const links   = article.querySelectorAll('a[href*="/status/"]');
    const tweetLink = Array.from(links).find(a => !a.href.includes('photo'));

    if (!textEl) return;

    function parseCount(label) {
      if (!label) return 0;
      const m = label.match(/^([\\d,]+)/);
      return m ? parseInt(m[1].replace(/,/g, '')) : 0;
    }

    // 提取作者账号和账号名
    const userEl = article.querySelector('[data-testid="User-Name"]');
    let handle = '', displayName = '';
    if (userEl) {
      const spans = userEl.querySelectorAll('span');
      displayName = spans[0] ? spans[0].innerText : '';
      const atSpan = Array.from(spans).find(s => s.innerText.startsWith('@'));
      handle = atSpan ? atSpan.innerText.replace('@','') : '';
    }
    if (!handle && tweetLink) {
      const m = tweetLink.href.match(/x\\.com\\/([^\\/]+)\\/status/);
      if (m) handle = m[1];
    }

    results.push({
      handle, displayName,
      text:     textEl.innerText.replace(/\\n+/g, ' ').trim(),
      time:     timeEl ? timeEl.getAttribute('datetime') : '',
      url:      tweetLink ? tweetLink.href : '',
      likes:    parseCount(likeEl ? likeEl.getAttribute('aria-label') : ''),
    });
  });

  return JSON.stringify({ count: results.length, results });
})()
`;

// ── 等待推文加载（Twitter 是 SPA，需等内容渲染）──────────────────────────────
const WAIT_FOR_TWEETS = `
(function() {
  const count = document.querySelectorAll('article[data-testid="tweet"]').length;
  return JSON.stringify({ loaded: count > 0, count });
})()
`;

// ── "建议用户" / 右侧栏相关账号（在用户主页执行）────────────────────────────
const EXTRACT_RELATED_ACCOUNTS = `
(function() {
  // 右侧 "你可能喜欢" 或 "相关账号"
  const cells = document.querySelectorAll('[data-testid="UserCell"]');
  const accounts = [];
  cells.forEach(cell => {
    const nameEl = cell.querySelector('[data-testid="User-Name"]');
    const link   = cell.querySelector('a[href^="/"]');
    if (nameEl && link) {
      const handle = link.getAttribute('href').replace('/', '');
      const spans = nameEl.querySelectorAll('span');
      accounts.push({
        handle,
        name: spans[0] ? spans[0].innerText : handle,
      });
    }
  });
  return JSON.stringify(accounts);
})()
`;

module.exports = {
  EXTRACT_TWEETS,
  EXTRACT_USER_PROFILE,
  EXTRACT_SEARCH_RESULTS,
  WAIT_FOR_TWEETS,
  EXTRACT_RELATED_ACCOUNTS,
};
