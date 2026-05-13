# X Layer Toolkit

X Layer Toolkit is a collection of development and maintenance tools provided by OKX to support the X Layer ecosystem development and operations.

## 📚 Project Overview

X Layer is a Layer 2 blockchain network built on Optimism OP Stack. This project provides a set of practical tools to help developers and service providers interact with the X Layer network.

## 🎯 Modules

### RPC Setup

Complete self-hosted X Layer RPC node solution, supporting quick deployment and management of dedicated RPC nodes.

**Quick Start:**
```bash
cd rpc-setup
./one-click-setup.sh
```

**Key Features**:
- ✅ Support for Testnet and Mainnet
- ✅ One-click deployment scripts
- ✅ Support geth and reth client
- ✅ Docker containerized deployment
- ✅ Automatic initialization and synchronization
- ✅ Complete logging

[📖 Full Documentation →](rpc-setup/README.md)

### Development Network (Devnet)

Complete local Optimism test environment for development and testing, supporting both Geth and Reth execution clients.

**Key Features:**
- ✅ Full OP Stack deployment (L1 + L2)
- ✅ Support for op-geth and op-reth sequencers
- ✅ High availability with op-conductor cluster
- ✅ One-click deployment and step-by-step setup
- ✅ Parallel and sequential Docker image builds
- ✅ Dispute game and fault proof support
- ✅ Gray upgrade simulation for zero-downtime updates

**Detailed Documentation:** [devnet/README.md](devnet/README.md)

### X Layer Expert (AI Coding Skill)

AI coding assistant skill that provides deep expertise for building on X Layer — smart contract security, gas optimization, deployment patterns, and more.

**Quick Start:**
```bash
cd tools/xlayer-expert
# Claude Code
cp -r . ~/.claude/skills/xlayer-expert

# Or install via skills.sh
npx skills add berktavsan/xlayer-expert
```

**Key Features:**
- ✅ 22 Security Golden Rules for Solidity
- ✅ Network config, RPC endpoints, chain IDs
- ✅ Hardhat & Foundry deployment patterns
- ✅ Gas optimization (OKB economics, L1 data fees)
- ✅ Bridge & cross-chain patterns
- ✅ OKLink OnChain Data API integration
- ✅ Works with Claude Code, Cursor, Windsurf, Codex CLI, Gemini CLI

[📖 Full Documentation →](tools/xlayer-expert/README.md)

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📄 License

This project follows the corresponding open source license.

## 🔗 Related Links

- [X Layer RPC Endpoint](https://rpc.xlayer.tech)
- [GitHub Repository](https://github.com/okx/xlayer-toolkit)

## 💡 Support

If you encounter any issues:

1. Check the relevant documentation
2. Submit an Issue on GitHub
