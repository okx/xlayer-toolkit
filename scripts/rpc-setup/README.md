# 🚀 X Layer RPC Node Deployment Guide

## 📋 Overview

Deploy a self-hosted X Layer RPC node with support for both **op-geth** (Go-based) and **op-reth** (Rust-based) execution clients, providing complete L2 blockchain data access services.

## ⚠️ Important: Migration from Legacy Mainnet/Testnet

If you were previously running nodes on the legacy X Layer mainnet/testnet:

- **Data incompatibility**: Previous blockchain data cannot be migrated to the current version
- **Configuration changes**: Updated bootnodes, network parameters, and P2P configurations
- **Fresh deployment required**: You must deploy a completely new node instance
- **Recommended**: Use `op-geth` for production stability; `op-reth` is available for testing

## 💻 System Requirements
- **CPU**: 8+ cores recommended
- **Memory**: Minimum 8GB, recommended 16GB+
- **Storage**: Minimum 100GB SSD, recommended 500GB+
- **Network**: Stable internet connection with sufficient bandwidth
- **Operating System**: Linux (Ubuntu 20.04+ recommended), macOS 10.15+
- **Docker**: 20.10+ 
- **Docker Compose**: 2.0+
- **Make**: GNU Make (for service management)

## 🎯 Execution Client Comparison

| Feature | op-geth | op-reth |
|---------|---------|---------|
| **Language** | Go | Rust |
| **Maturity** | Stable, production-ready | Testing phase |
| **Memory Usage** | ~8-16GB | ~8-16GB |
| **Sync Speed** | Standard | Faster |
| **Network** | Mainnet + Testnet | Mainnet + Testnet |
| **Status** | ✅ Recommended | ⚠️ Under testing |

**Recommendation**: Use **op-geth** for production deployments. **op-reth** is currently undergoing integration testing and should be used for testing purposes only.

## ⚡ Quick Deployment

### 🎯 One-Click Setup (Recommended)

The easiest way to deploy your X Layer RPC node:

```bash
# Download and run the setup script
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/reth/scripts/rpc-setup/one-click-setup.sh | bash
```

Or download first, then execute:

```bash
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/reth/scripts/rpc-setup/one-click-setup.sh -o one-click-setup.sh
chmod +x one-click-setup.sh
./one-click-setup.sh
```

**What the script does:**
- ✅ Checks all system dependencies (Docker, Make, etc.)
- ✅ Detects if running from cloned repository or standalone
- ✅ Downloads latest configuration files if needed
- ✅ Interactively prompts for configuration parameters
- ✅ Generates `.env` and all necessary config files
- ✅ Downloads and initializes genesis data
- ✅ Starts services with proper health checks
- ✅ Displays connection details and management commands

**Interactive Configuration:**

The script will prompt you for:

1. **Network Selection**: `testnet` or `mainnet`
2. **RPC Type**: `geth` or `reth` (execution client)
3. **L1 RPC URL**: Ethereum L1 RPC endpoint (e.g., QuickNode, Alchemy)
4. **L1 Beacon URL**: Ethereum L1 Beacon API endpoint
5. **Optional Settings**: Ports, data directory (defaults provided)

**After Installation:**

Your RPC node will be available at:
- **HTTP RPC**: `http://localhost:8545`
- **WebSocket**: `ws://localhost:8546`
- **op-node RPC**: `http://localhost:9545`

## 🛠️ Manual Setup (Advanced)

### Step 1: Clone Repository

```bash
git clone https://github.com/okx/xlayer-toolkit.git
cd xlayer-toolkit/scripts/rpc-setup
```

### Step 2: Run Setup

```bash
chmod +x one-click-setup.sh
./one-click-setup.sh
```

Follow the interactive prompts to configure your node.

### Step 3: Verify Installation

```bash
# Check service status
make status

# View logs
docker compose logs -f
```

## 📊 Service Management

All services are managed via **Makefile** commands:

```bash
# Start services (with health checks)
make run

# Stop all services
make stop

# Check service status with connection info
make status

# View logs
docker compose logs          # View all logs
docker compose logs -f       # Follow logs in real-time
docker compose logs op-reth  # View specific service (op-reth, op-geth, op-node)
```

### Service Startup Behavior

The `make run` command intelligently manages service startup:

1. **Reads configuration** from `.env` file
2. **Starts execution client** first (op-reth or op-geth)
3. **Waits for health check** to pass (up to 10 minutes for genesis loading)
4. **Starts op-node** after execution client is ready
5. **Displays status** with connection details

**Important**: First startup takes longer (5-15 minutes) due to genesis file loading.

## 🗂️ Directory Structure

```
scripts/rpc-setup/
├── one-click-setup.sh          # Main setup script
├── network-presets.env         # Network configuration presets
├── Makefile                    # Service management
├── docker-compose.yml          # Service definitions
├── .env                        # Generated environment variables
└── chaindata/                  # Blockchain data directory
    ├── mainnet-reth/           # Mainnet + Reth data
    ├── mainnet-geth/           # Mainnet + Geth data
    ├── testnet-reth/           # Testnet + Reth data
    └── testnet-geth/           # Testnet + Geth data
        ├── data/               # Blockchain state
        │   ├── op-reth/       # or op-geth/
        │   └── op-node/
        ├── config/             # Runtime configs
        │   ├── genesis.json
        │   ├── rollup-*.json
        │   └── jwt.txt
        └── logs/               # Service logs
```

## 🔧 Configuration Files

### `.env` File

Generated by `one-click-setup.sh`, contains:

```bash
NETWORK_TYPE=mainnet           # or testnet
RPC_TYPE=reth                  # or geth

# L1 Configuration
L1_RPC_URL=https://...
L1_BEACON_URL=https://...

# Port Mappings
RPC_PORT=8545
WS_PORT=8546
NODE_RPC_PORT=9545

# Image Tags (auto-configured)
OP_STACK_IMAGE_TAG=xlayer/op-node:0.0.9
OP_GETH_IMAGE_TAG=xlayer/op-geth:0.0.6
OP_RETH_IMAGE_TAG=xlayer/op-reth:release-testnet

# Bootnode and P2P Configuration
OP_NODE_BOOTNODE=enode://...
OP_GETH_BOOTNODE=enode://...
P2P_STATIC_PEERS=/ip4/...
```

### `network-presets.env`

Network configuration presets containing:
- Network-specific settings (testnet/mainnet)
- Docker image tags
- Genesis file URLs
- Bootnode addresses
- P2P static peers

## 📡 Network Endpoints

### Service Ports

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| op-reth/op-geth RPC | 8545 | HTTP | JSON-RPC API |
| op-reth/op-geth WebSocket | 8546 | WebSocket | Real-time events |
| op-node RPC | 9545 | HTTP | Consensus API |
| op-reth/op-geth P2P | 30303 | TCP/UDP | Peer discovery |
| op-node P2P | 9223 | TCP/UDP | Peer discovery |

### RPC API Examples

```bash
# Check sync status
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'

# Get latest block
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Check op-node sync status
curl -X POST http://localhost:9545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}'

# Check P2P connections
curl -X POST http://localhost:9545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"opp2p_peerStats","params":[],"id":1}'
```

## 🔄 Upgrade & Migration

### Upgrading to Latest Version

```bash
# Stop services
make stop

# Pull latest changes
git pull origin main

# Re-run setup (will preserve existing .env)
./one-click-setup.sh

# Start services
make run
```

### Switching Between Geth and Reth

```bash
# Stop current services
make stop

# Re-run setup and choose different RPC type
./one-click-setup.sh

# Start with new configuration
make run
```

**Note**: Switching execution clients requires re-downloading genesis data.

### Complete Reset

```bash
# Stop all services
make stop

# Remove all data
make clean

# Or manually:
rm -rf chaindata/ .env

# Re-initialize
./one-click-setup.sh
```

## 🐛 Troubleshooting

### Check System Requirements

The setup script automatically checks dependencies. To manually verify:

```bash
# Check Docker
docker --version
docker compose version

# Check Make
make --version

# Check other tools
wget --version
curl --version
jq --version
```

### Service Won't Start

```bash
# Check logs
docker compose logs

# Check specific service
docker compose logs op-reth  # or op-geth, op-node

# Follow logs in real-time
docker compose logs -f

# Verify .env file exists
cat .env

# Check service health
docker compose ps
```

### Slow Initial Sync

- **First startup**: Genesis loading takes 5-15 minutes
- **Check progress**: `docker compose logs -f` to see current block height

### P2P Connection Issues

```bash
# Check P2P peers
curl -X POST http://localhost:9545 \
  -d '{"jsonrpc":"2.0","method":"opp2p_peerStats","params":[],"id":1}'

# Expected result: connected > 0
```

### Port Conflicts

If ports are already in use, edit `.env` and change:

```bash
RPC_PORT=8545        # Change to available port
WS_PORT=8546
NODE_RPC_PORT=9545
```

Then restart: `make stop && make run`

## 📚 Additional Resources

- **Main Documentation**: [README.md](README.md)
- **X Layer Official Site**: https://www.okx.com/xlayer
- **GitHub Repository**: https://github.com/okx/xlayer-toolkit
- **Discord Community**: [Join our Discord](https://discord.gg/xlayer)

## 🆘 Support

If you encounter issues:

1. Check the [Troubleshooting](#-troubleshooting) section
2. Review service logs: `docker compose logs -f`
3. Open an issue on [GitHub](https://github.com/okx/xlayer-toolkit/issues)

---

**Thank you for building with X Layer!** 💪 🚀