```
 __  __  _                            _              _ _    _ _   
 \ \/ / | |                          | |            | | |  (_) |  
  \  /  | |     __ _ _   _  ___ _ __ | |_ ___   ___ | | | ___| |_ 
  / \  | |    / _` | | | |/ _ \ '__| | __/ _ \ / _ \| | |/ / | __|
 / /\ \ | |___| (_| | |_| |  __/ |    | || (_) | (_) | |   <| | |_ 
/_/  \_\|______\__,_|\__, |\___|_|     \__\___/ \___/|_|_|\_\_|\__|
                      __/ |                                        
                     |___/                                         
```

# X Layer Toolkit

A comprehensive collection of tools and scripts for deploying and managing X Layer infrastructure.

## 📦 Available Tools

### [RPC Node Setup](scripts/rpc-setup/README.md)

Deploy your own X Layer RPC node with support for both Geth and Reth execution clients.

**Features:**
- ✅ One-click automated setup
- 🐳 Docker-based deployment
- 🔄 Full RPC support (HTTP, WebSocket, Admin)
- 📊 Archive node capability
- 🌐 P2P network connectivity
- 🔐 Secure JWT authentication
- ⚡ Support for both op-geth and op-reth clients

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

## 📞 Support and Resources

- **Official Documentation**: [X Layer Docs](https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)

## 📄 License

This project is part of the X Layer ecosystem. Please refer to individual tool directories for specific licensing information.

---

**Built with ❤️ for the X Layer community**