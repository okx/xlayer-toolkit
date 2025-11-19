# X Layer RPC Node Deployment Guide

## 📋 Overview

This guide will help you quickly deploy an X Layer self-hosted RPC node, providing complete L2 blockchain data access services.

## 💻 System Requirements

* **Operating System**: Linux (Ubuntu 20.04+ recommended)
* **Memory**: Minimum 8GB, recommended 16GB+
* **Storage**: Minimum 100GB SSD, recommended 500GB+
* **Network**: Stable internet connection
* **Docker**: Docker 20.10+ and Docker Compose 2.0+

## ⚡ Quick Deployment

### 🎯 Option 1: One-Click Installation (Recommended)

The easiest way to deploy your X Layer RPC node with minimal configuration:

```bash
# Create your node directory and run setup
mkdir -p /data/xlayer-mainnet && cd /data/xlayer-mainnet
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/main/rpc-setup/one-click-setup.sh | bash
```

This script will:

* ✅ Automatically detect your system requirements
* ✅ Download the latest configuration files
* ✅ Prompt you for required parameters interactively
* ✅ Generate all necessary configuration files
* ✅ Start the RPC node services
* ✅ Verify the installation and show connection details

**Interactive prompts will ask for:**

* Network type: `testnet` or `mainnet`
* L1 RPC URL - Ethereum L1 RPC endpoint
* L1 Beacon URL - Ethereum L1 Beacon RPC endpoint
* Optional: Custom port mappings

**After installation, your RPC node will be available at:**

* HTTP RPC: `http://localhost:8545`
* WebSocket: `ws://localhost:8546`

### 🎯 Option 2: Repository Mode (Advanced Users))

For users working with the repository directly:

```bash
# Clone the repository
git clone https://github.com/okx/xlayer-toolkit.git
cd xlayer-toolkit/rpc-setup

# Run setup script (will use local presets/)
./one-click-setup.sh

# Or specify parameters directly (⚠️ Under testing)
./one-click-setup.sh --rpc_type=reth
```

## 📊 Service Management

```bash
# Start services
make run

# Stop services (preserves data)
make stop

# Check service status
make status

# View logs
docker compose logs -f
```

## 📡 Service Ports

| Service           | Port  | Protocol  | Purpose             |
| ----------------- | ----- | --------- | ------------------- |
| op-geth RPC       | 8545  | HTTP      | JSON-RPC API        |
| op-geth WebSocket | 8546  | WebSocket | WebSocket API       |
| op-node RPC       | 9545  | HTTP      | Consensus layer API |
| op-geth P2P       | 30303 | TCP/UDP   | P2P network         |
| op-node P2P       | 9223  | TCP/UDP   | P2P network         |

**Thank you for building with X Layer!** 💪
