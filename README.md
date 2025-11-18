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

### [RPC Node Setup](rpc-setup/README.md)

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
cd rpc-setup
./one-click-setup.sh
```

[📖 Full RPC Setup Documentation →](rpc-setup/README.md)

## 🛠️ System Requirements

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

## 📞 Support and Resources

- **Official Documentation**: [X Layer Docs](https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)

## 📄 License

This project is part of the X Layer ecosystem. Please refer to individual tool directories for specific licensing information.

---

**Built with ❤️ for the X Layer community**