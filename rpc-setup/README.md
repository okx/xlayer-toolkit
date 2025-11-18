# 🚀 X Layer RPC Node Deployment Guide

## 📋 Overview

Deploy a self-hosted X Layer RPC node with support for both **op-geth** (Go-based, **production-ready** ✅) and **op-reth** (Rust-based, testing phase ⚠️) execution clients, providing complete L2 blockchain data access services.

**Recommendation**: Use **op-geth** for production deployments.

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

> **⚠️ For existing node operators**: If you're upgrading from a previous version, please note that old blockchain data is incompatible. You'll need to deploy a fresh node instance.

## ⚡ Quick Deployment

### 🎯 One-Click Setup (Recommended)

The easiest way to deploy your X Layer RPC node using the setup script from [xlayer-toolkit](https://github.com/okx/xlayer-toolkit):

> **💡 Important**: Each directory manages **ONE node instance**. To run multiple nodes, use separate directories.

**Deployment Steps:**

```bash
# 1. Create and enter your node directory, and run the setup script
#    Example for mainnet: /data/xlayer-mainnet
#    Example for testnet: /data/xlayer-testnet
mkdir -p /data/xlayer-mainnet && cd /data/xlayer-mainnet
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/reth/rpc-setup/one-click-setup.sh | bash

# Or specify RPC client type (default is geth):
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/reth/rpc-setup/one-click-setup.sh | bash -s -- --rpc_type=reth

# The script will interactively prompt you to configure:
#    - Network type (mainnet/testnet) - interactive
#    - L1 RPC URL (required)
#    - L1 Beacon URL (required)
#    - Optional: Custom ports (press Enter for defaults)
#
# Note: RPC client type can be specified via --rpc_type=geth|reth (default: geth)
```

**What the script does:**
- ✅ Checks all system dependencies (Docker, Make, etc.)
- ✅ Detects existing configurations and offers to keep data
- ✅ Interactively prompts for configuration
- ✅ Downloads latest configuration files and genesis data
- ✅ Generates `.env` and all necessary config files
- ✅ Initializes blockchain data (skipped if keeping existing data)
- ✅ Starts services with proper health checks
- ✅ Displays connection details and management commands

**After Installation:**

Your RPC node will be available at:
- **HTTP RPC**: `http://localhost:8545` (or custom port from `.env`)
- **WebSocket**: `ws://localhost:8546` (or custom port from `.env`)
- **op-node RPC**: `http://localhost:9545` (or custom port from `.env`)

**Switching Configurations:**

To switch between configurations (e.g., from mainnet to testnet, or from geth to reth):

```bash
# Run the setup script again
./one-click-setup.sh --rpc_type=reth

# Select different network type when prompted
# Choose [1] to keep existing data when detected
# The script will generate a new .env pointing to the new configuration

# Restart services
make stop && make run
```

### 📁 Deployment Directory Structure

After running the setup script, your deployment directory will contain:

```
/data/xlayer-mainnet/              # Your working directory
├── .env                            # Environment configuration
├── docker-compose.yml              # Docker services definition
├── Makefile                        # Service management commands
├── one-click-setup.sh              # Setup script (downloaded)
├── network-presets.env             # Network configurations (downloaded in standalone mode)
├── presets/                        # Configuration templates (in repository mode)
│   ├── network-presets.env
│   ├── op-geth-config-mainnet.toml
│   ├── op-geth-config-testnet.toml
│   ├── op-reth-config-mainnet.toml
│   ├── op-reth-config-testnet.toml
│   ├── rollup-mainnet.json
│   └── rollup-testnet.json
├── mainnet-geth/                   # Configuration-specific directory
│   ├── data/                       # Blockchain data
│   │   ├── op-geth/                # Execution client database
│   │   └── op-node/                # Consensus layer data
│   ├── config/                     # Runtime configuration files
│   │   ├── genesis-mainnet.json    # (only for geth)
│   │   ├── rollup-mainnet.json
│   │   ├── op-geth-config-mainnet.toml
│   │   └── jwt.txt
│   └── logs/                       # Service logs
│       ├── geth.log
│       └── op-node.log
├── mainnet-reth/                   # Another configuration (if created)
├── testnet-geth/                   # Testnet configuration (if created)
└── testnet-reth/                   # Testnet reth (if created)
```

**Directory Structure Features:**

- **Flat hierarchy**: Configuration directories (`mainnet-geth/`, `mainnet-reth/`, etc.) are at the root level
- **Multiple configurations**: You can have multiple network/client combinations in the same directory
- **Smart switching**: Re-running the script detects existing configurations and offers to:
  - **Keep data** and update `.env` only (recommended for switching configurations)
  - **Delete and re-initialize** (for fresh start)
  - **Cancel** (exit without changes)
- **Automatic naming**: Directory names follow the pattern `{network}-{rpc_type}` (e.g., `mainnet-geth`, `testnet-reth`)

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

## 🔧 Configuration Files

### `.env` File

Generated by `one-click-setup.sh`, contains the active configuration:

```bash
# Network Configuration
NETWORK_TYPE=mainnet           # or testnet
RPC_TYPE=geth                  # or reth
CHAIN_NAME=xlayer-mainnet      # Chain identifier

# Directory Configuration
TARGET_DIR=mainnet-geth        # Current active configuration directory

# L1 Configuration
L1_RPC_URL=https://...
L1_BEACON_URL=https://...

# L2 Engine URL
L2_ENGINE_URL=http://op-geth:8552  # or http://op-reth:8552

# Port Mappings
HTTP_RPC_PORT=8545
WEBSOCKET_PORT=8546
ENGINE_API_PORT=8552
NODE_RPC_PORT=9545
P2P_TCP_PORT=30303
P2P_UDP_PORT=30303
NODE_P2P_PORT=9223

# Image Tags (auto-configured from presets)
OP_STACK_IMAGE_TAG=xlayer/op-node:0.0.9
OP_GETH_IMAGE_TAG=xlayer/op-geth:0.0.6
OP_RETH_IMAGE_TAG=xlayer/op-reth:load-genesis-fd6b19

# Bootnode and P2P Configuration
OP_NODE_BOOTNODE=enode://...
OP_GETH_BOOTNODE=enode://...
P2P_STATIC_PEERS=/ip4/...

# Sequencer Configuration
SEQUENCER_HTTP_URL=https://rpc.xlayer.tech

# Legacy RPC Configuration (for reth)
LEGACY_RPC_URL=https://rpc.xlayer.tech
LEGACY_RPC_TIMEOUT=3s
```

### `presets/` Directory (Repository Mode)

Contains template configurations for all network/client combinations:

- `network-presets.env` - Network-specific settings, image tags, bootnode addresses
- `op-geth-config-*.toml` - Geth execution client configurations
- `op-reth-config-*.toml` - Reth execution client configurations
- `rollup-*.json` - Rollup/consensus layer configurations

**Note**: In standalone mode (running outside repository), `network-presets.env` is downloaded to the working directory.

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