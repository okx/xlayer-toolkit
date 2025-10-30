```
 __  __  _                             _____           _ _    _ _
 \ \/ / | |                           |_   _|         | | |  (_) |
  \  /  | |     __ _ _   _  ___ _ __   | | ___   ___ | | | ___| |_
  /  \  | |    / _` | | | |/ _ \ '__|  | |/ _ \ / _ \| | |/ / | __|
 / /\ \ | |___| (_| | |_| |  __/ |    _| | (_) | (_) | |   <| | |_
/_/  \_\|______\__,_|\__, |\___|_|    \___/\___/ \___/|_|_|\_\_|\__|
                      __/ |
                     |___/
```

# X Layer Toolkit

A comprehensive collection of tools and scripts for deploying and managing X Layer infrastructure.

## 📚 Project Overview

X Layer is a Layer 2 blockchain network built on Optimism OP Stack. This toolkit provides a set of practical tools to help developers and service providers interact with the X Layer network, deploy infrastructure, and manage operations.

## 📦 Available Tools

### [RPC Node Setup](scripts/rpc-setup/README.md)

Deploy and manage your own X Layer RPC node with Docker. This toolkit provides everything you need to run a self-hosted, full-featured RPC endpoint.

**Features:**
- ✅ Support for Testnet and Mainnet
- ✅ One-click automated setup
- 🐳 Docker-based deployment
- 🔄 **Dual execution engine support (op-geth / op-reth)**
- 📊 Archive node capability
- 🌐 P2P network connectivity
- 🔐 Secure JWT authentication
- ⚡ **Legacy RPC fallback for historical data**
- 🔧 Full RPC support (HTTP, WebSocket, Admin)
- 🎛️ Customizable ports

**Quick Start:**
```bash
cd scripts/rpc-setup
./one-click-setup.sh
```

[📖 Full RPC Setup Documentation →](scripts/rpc-setup/README.md)

## 🛠️ System Requirements

- **OS**: Linux (Ubuntu 24.04+ recommended)
- **Memory**: 16GB RAM minimum (32GB+ recommended for RPC nodes)
- **Storage**: 100GB+ available disk space (SSD recommended)
- **Docker**: 20.10+
- **Docker Compose**: 2.0+

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📞 Support and Resources

- **Official Documentation**: [X Layer Docs](https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer)
- **X Layer RPC Endpoint**: [https://rpc.xlayer.tech](https://rpc.xlayer.tech)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)

## 💡 Support

If you encounter any issues:

1. Check the relevant documentation
2. Submit an Issue on GitHub

## 📄 License

This project is part of the X Layer ecosystem. Please refer to individual tool directories for specific licensing information.

---

**Built with ❤️ for the X Layer community**
