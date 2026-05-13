# X Layer Expert Skill

An AI coding assistant skill that provides deep expertise for building on [X Layer](https://www.okx.com/xlayer) — OKX's Layer 2 blockchain built on OP Stack.

Works with **Claude Code**, **Claude Desktop**, **Cursor**, **Windsurf**, **Codex CLI**, **Gemini CLI**, and any AI coding tool that supports markdown-based context files.

## What it does

When triggered, this skill gives your AI coding assistant specialized knowledge about:

- **Network configuration** — RPC endpoints, chain IDs (196 mainnet / 1952 testnet), re-genesis block
- **Smart contract security** — 18 Golden Rules covering reentrancy, L2-specific risks, signature replay, oracle safety, and more
- **Contract patterns** — Hardhat & Foundry config, deploy scripts, proxy/upgrade (UUPS), contract verification via OKLink
- **Gas optimization** — OKB economics, L1 data fee structure, calldata compression
- **Bridge & cross-chain** — OP Stack predeploys, L2→L1 withdrawals, L1→L2 deposits, AggLayer
- **Flashblocks** — Sub-second pre-confirmations, reorg handling
- **OnChain Data API** — OKLink REST API with HMAC authentication for querying blocks, transactions, tokens, and event logs
- **Testing** — Mainnet forking, security testing patterns, stress testing

## Installation

### Quick Install (via [skills.sh](https://skills.sh))

```bash
npx skills add berktavsan/xlayer-expert
```

### Claude Code

```bash
# Copy into skills folder
cp -r xlayer-expert ~/.claude/skills/

# Or clone directly
git clone https://github.com/cberktavsan/xlayer-expert.git ~/.claude/skills/xlayer-expert
```

### Cursor / Windsurf

Copy `SKILL.md` and `references/` into your project root, or add them to the tool's context:

```bash
# Add to your project as context
cp SKILL.md your-project/.cursorrules
# Or reference the files via Cursor Settings → Rules
```

### Claude Desktop

Add the reference files as Project Knowledge:

1. Open **Claude Desktop** → create or open a **Project**
2. Click **Project Knowledge** (or the 📎 icon in the project settings)
3. Upload these files:
   - `SKILL.md` (main skill file with Golden Rules)
   - All files from `references/` folder (`security.md`, `contract-patterns.md`, etc.)
4. Every conversation in that project will now have X Layer expertise

> **Tip:** For the best experience, upload all 12 files. If you hit the file limit, prioritize `SKILL.md` + `security.md` + `contract-patterns.md` — these cover the most critical security and deployment patterns.

### Codex CLI / Gemini CLI

Include the reference files as context when starting a session:

```bash
# Codex CLI — add to project instructions
cp SKILL.md your-project/AGENTS.md

# Gemini CLI — add to project instructions
cp SKILL.md your-project/GEMINI.md
```

### Any AI Coding Tool

The skill is plain markdown. Copy `SKILL.md` + `references/` into wherever your tool reads context files from.

## File structure

```
xlayer-expert/
├── SKILL.md                        # Main skill file — Golden Rules, triggers, reference guide
├── LICENSE                         # MIT License
├── README.md                       # This file
├── assets/
│   └── x-layer.png                 # X Layer logo
└── references/
    ├── security.md                 # Solidity security rules, L2 risks, attack patterns
    ├── network-config.md           # RPC URLs, chain IDs, performance specs
    ├── contract-patterns.md        # Hardhat/Foundry config, deploy, verify, proxy
    ├── token-addresses.md          # Token addresses + Multicall3
    ├── l2-predeploys.md            # OP Stack predeploy + L1 bridge addresses
    ├── gas-optimization.md         # OKB fee structure, optimization techniques
    ├── testing-patterns.md         # Forking, security testing, stress testing
    ├── flashblocks.md              # Flashblocks API, reorg risks
    ├── infrastructure.md           # RPC providers, xlayer-reth, monitoring, WebSocket
    ├── onchain-data-api.md         # OKLink REST API — blocks, txs, tokens, logs
    └── zkevm-differences.md        # CDK→OP Stack migration, EVM differences
```

## How it triggers

In Claude Code, the skill activates automatically via triggers. For other tools, the context is available as soon as you include the files. Common trigger patterns:

| Trigger | Examples |
|---------|----------|
| Chain IDs | `chainId: 196`, `chainId: 1952` |
| RPC URLs | `rpc.xlayer.tech`, `xlayerrpc.okx.com` |
| Tokens | OKB, WOKB, OKB as gas token |
| Infrastructure | `xlayer-reth`, flashblocks |
| Contracts | `GasPriceOracle`, `L2CrossDomainMessenger`, `OptimismPortal` |
| Tools | Hardhat/Foundry with X Layer networks |
| API | `OK-ACCESS-KEY`, `/api/v5/xlayer/`, OKLink queries |

## Security

Every Solidity code block written with this skill is checked against 18 Golden Rules covering:

- Reentrancy (CEI pattern + ReentrancyGuard)
- Authentication (`msg.sender` over `tx.origin`)
- Token decimal handling (USDT=6, OKB=18)
- L2-specific risks (sequencer centralization, forced OKB sends)
- Signature safety (replay protection, malleability)
- Oracle integration (staleness checks, TWAP)
- On-chain data privacy (`private` != secret)

## Support

If you find this skill useful, consider supporting the project:

**EVM Wallet:** `0x1dfcf2ac670738e74fb17c2c96da5bf333a3542c`

## License

MIT — see [LICENSE](LICENSE) for details.
