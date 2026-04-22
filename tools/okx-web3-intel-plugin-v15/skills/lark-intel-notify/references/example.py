# lark-intel-notify skill — 完整示例
# 可直接复制进 web3pay_bot.py 的 PENDING_MESSAGES 列表

build_impact_message(
    title          = "Base 脱离 OP Stack",
    business_lines = "XLayer / OKX Wallet / OKX DEX",
    concept        = (
        "Base（Coinbase 旗下 L2，TVL $38 亿）宣布从 Optimism 的 OP Stack 迁出，"
        "迁移至自研的 `base/base` 统一技术栈，同时停止向 Optimism Collective 分成收入。"
    ),
    engineering    = (
        "OP Stack 是多团队协作的模块化框架，Base 此前依赖 OP Labs + Flashbots + Paradigm "
        "多方协同升级，导致每年只能做 3 次大版本迭代。独立后，Base 将排序器、证明系统、跨链桥"
        "全部收归自有代码库，并将乐观欺诈证明替换为 TEE + ZK Proof。"
    ),
    strategy       = (
        'Coinbase 的目标是将 Base 从"Superchain 成员"升级为一条完全自主的主权链——'
        "控制升级节奏、控制经济模型、控制技术路线。这是为 Base 未来独立发行原生代币、"
        "构建自有链上经济体清路。Superchain 的收入分成模型对 Coinbase 已没有对等回报，"
        "退出是理性选择，不是关系破裂。"
    ),
    discussion_points=[
        "XLayer 技术路线：XLayer 在 Superchain 内的跨链互操作依赖有多深？Base 独立后的实际断裂影响是什么？工程团队需要做一次完整的依赖项盘点，这是后续所有决策的前提",
        "ZK Proof 路线时机：Base V1 换用 TEE+ZK 是行业级别的方向信号，XLayer 是否需要跟进 ZK 路线，以及何时是合适的切换时机，值得提上议程讨论",
        "Superchain 剩余生态走向：Unichain、Soneium、Ink 等链在 Base 出走后的动向，将决定 Superchain 是否进入结构性衰退，进而影响 OKX 在 OP 生态的整体资源投入判断",
    ],
    sources=[
        {"name": "The Block", "url": "https://www.theblock.co"},
        {"name": "CoinDesk",  "url": "https://www.coindesk.com"},
    ],
),

build_impact_message(
    title          = "MetaMask 启动社交登录",
    business_lines = "OKX Wallet",
    concept        = (
        "MetaMask 于 2025 年 8 月上线社交登录功能，允许用户用 Google 或 Apple 账号"
        "创建并管理钱包，无需手动保存 12 位助记词。"
    ),
    engineering    = (
        "底层使用了一种叫 TOPRF（Threshold Oblivious Pseudorandom Function）的密码学原语，"
        "配合分布式密钥管理协议，将助记词拆分存储，确保 MetaMask 本身和 Google/Apple "
        "都无法单独还原私钥，只有社交凭证加用户密码组合才能解锁。"
    ),
    strategy       = (
        'MetaMask 在做的事不是功能迭代，是用户群扩张——把目标用户从"愿意管理助记词的 '
        'crypto native"扩展到"只用过 Google 登录的普通人"。这是 MetaMask 在为自己的'
        "代币发行铺用户基础，MAU 从 3000 万往上推是前提条件。\n\n"
        "更深的逻辑是：一旦大量 Web2 用户通过 Google/Apple 进入 MetaMask，这批用户的"
        "身份和钱包就和 MetaMask 强绑定，很难迁移到其他钱包。社交登录表面上是降低门槛，"
        "实质上是在建立用户锁定。"
    ),
    discussion_points=[
        "OKX Wallet 新用户引导：OKX Wallet 是否需要跟进社交登录方案？这是一个用户获取的竞争决策，不跟进意味着在 Web2 用户转化这个战场上主动放弃",
        "技术路线选型：TOPRF 是 MetaMask 自研方案，OKX 如果跟进，是复用同类密码学方案还是走 MPC 托管路线，两条路的工程复杂度和安全模型差异很大，需要工程侧先做评估",
        "用户锁定风险：MetaMask 的社交登录天然形成用户绑定，OKX Wallet 的多链聚合优势在新用户那里是否还能成立，值得产品侧重新审视差异化定位",
    ],
    sources=[
        {"name": "MetaMask 官方公告", "url": "https://metamask.io/news"},
        {"name": "The Block",         "url": "https://www.theblock.co"},
        {"name": "CryptoSlate",       "url": "https://cryptoslate.com"},
    ],
),
