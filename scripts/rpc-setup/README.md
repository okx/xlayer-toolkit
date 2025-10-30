# X Layer RPC Node Setup

A comprehensive toolkit for deploying and managing an X Layer RPC node using Docker. This setup provides a full-featured, self-hosted RPC endpoint for the X Layer network (OP Stack based Layer 2 solution) with **dual execution engine support** and **legacy RPC fallback** capabilities.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Manual Setup](#manual-setup)
- [Configuration](#configuration)
- [Service Management](#service-management)
- [Endpoints and Ports](#endpoints-and-ports)
- [Monitoring and Logs](#monitoring-and-logs)
- [Troubleshooting](#troubleshooting)
- [Advanced Configuration](#advanced-configuration)
- [File Structure](#file-structure)

## Overview

X Layer is a Layer 2 network built on Optimism OP Stack. This project provides a comprehensive set of tools for deploying and managing your own X Layer RPC node.

### Core Components

- **op-geth** / **op-reth**: Execution layer clients (choose one)
  - op-geth: Layer 2 Ethereum client (stable, default)
  - op-reth: Rust-based execution client (experimental, higher performance)
- **op-node**: Consensus layer client, connects to Ethereum L1 and manages L2 state

Both components run in Docker containers and work together to sync and validate blocks from the X Layer network.

### Network Support

- **Testnet (Chain ID: 1952)**: Test network for development and testing
- **Mainnet (Chain ID: 196)**: Production main network

## Features

- ✅ **One-Click Setup**: Automated installation script for quick deployment
- 🐳 **Docker-Based**: Easy deployment with Docker Compose
- ⚡ **Dual Execution Engine**: Choose between op-geth (stable) or op-reth (experimental, high-performance)
- 🔄 **Legacy RPC Fallback**: Automatic fallback to legacy RPC for historical data before cutoff block
- 📊 **Archive Mode**: Full blockchain data with archive node capability
- 🌐 **P2P Network**: Connect to X Layer network via bootnodes
- 🔐 **JWT Authentication**: Secure communication between components
- 🎛️ **Customizable Ports**: Full control over all exposed ports
- 📡 **Full RPC Support**: HTTP, WebSocket, and Admin RPC endpoints
- 🌍 **Multi-Network**: Support for both testnet and mainnet

## Prerequisites

### System Requirements

#### Minimum Requirements

- **OS**: Linux (Ubuntu 24.04+ recommended)
- **CPU**: 4 cores
- **Memory**: 8 GB RAM minimum (16GB+ recommended)
- **Storage**: 50 GB available space (testnet), 300+ GB (mainnet)
- **Network**: Stable internet connection (recommended upload bandwidth > 10 Mbps)

#### Recommended Requirements

- **Memory**: 32GB+ RAM
- **Storage**: SSD for better performance
- **CPU**: 4+ cores

### Software Requirements

- Docker 20.10+
- Docker Compose 2.0+
- wget
- tar
- openssl
- curl (for testing)

### Install Docker

**Ubuntu/Debian:**

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

**macOS:**

```bash
brew install --cask docker
```

## Quick Start

### Method 1: One-Click Deployment (Recommended)

Use the one-click deployment script to automatically complete all configuration:

```bash
# One-click installation and setup
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/main/scripts/rpc-setup/one-click-setup.sh -o one-click-setup.sh
chmod +x one-click-setup.sh && ./one-click-setup.sh
```

The script will:
1. Check system requirements
2. Download necessary configuration files
3. Prompt for configuration (L1 RPC URL, ports, execution engine, etc.)
4. Initialize the node with genesis data
5. Start all services
6. Verify the installation

### Method 2: Step-by-Step Deployment

If you want to manually control the deployment process:

#### 1. Configure Environment Variables

Copy and edit the environment variable template:

```bash
cp env.example .env
vim .env
```

Edit the `.env` file and set the following required parameters:

```bash
L1_RPC_URL={your-l1-url}  # Ethereum L1 RPC endpoint
L1_BEACON_URL={your-l1-beacon-url}  # Ethereum Beacon API endpoint

# Choose execution engine: geth (default, stable) or reth (experimental)
L2_ENGINEKIND=geth

# For legacy RPC fallback (optional)
L2_RPC_URL=https://testrpc.xlayer.tech  # Legacy RPC URL
L2_CUTOFF_BLOCK=12241701  # Blocks before this use legacy RPC
```

#### 2. Initialize Node

```bash
# Initialize testnet
./init.sh testnet

# Or initialize mainnet
./init.sh mainnet
```

This will complete the following operations:
- Download and extract Genesis file
- Generate genesis-reth.json (for op-reth)
- Copy configuration files
- Initialize execution client database

#### 3. Start Node

```bash
# Start testnet node
./start.sh testnet

# Or start mainnet node
./start.sh mainnet
```

#### 4. Stop Node

```bash
./stop.sh
```

## Configuration

### Environment Variables

#### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `L1_RPC_URL` | Ethereum L1 RPC endpoint | `https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY` |
| `L1_BEACON_URL` | Ethereum L1 Beacon chain endpoint | `https://ethereum-beacon-api.publicnode.com` |

#### Execution Engine Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `L2_ENGINEKIND` | Execution client type (`geth` or `reth`) | `geth` |
| `OP_GETH_IMAGE_TAG` | Docker image for op-geth | `xlayer/op-geth:0.0.6` |
| `OP_RETH_IMAGE_TAG` | Docker image for op-reth | `xlayer/op-reth:release-testnet` |

#### Legacy RPC Configuration

For accessing historical data before the cutoff block:

| Variable | Description | Default (Testnet) |
|----------|-------------|-------------------|
| `L2_RPC_URL` | Legacy RPC endpoint URL | `https://testrpc.xlayer.tech` |
| `L2_CUTOFF_BLOCK` | Block number to switch from legacy | `12241701` |
| `L2_RPC_TIMEOUT` | Timeout for legacy RPC calls | `30s` |

**Mainnet Legacy RPC:**
- `L2_RPC_URL=https://xlayerrpc.okx.com`
- `L2_CUTOFF_BLOCK=42810021`

#### Network Configuration

| Variable | Description |
|----------|-------------|
| `OP_NODE_BOOTNODE` | OP Node bootnode enode URLs |
| `OP_GETH_BOOTNODE` | OP Geth bootnode enode URLs |
| `P2P_STATIC` | Static P2P peers |

### Port Configuration

Default port configuration (customizable via environment variables):

| Service | Variable | Default | Protocol | Description |
|---------|----------|---------|----------|-------------|
| Execution Client HTTP RPC | `HTTP_RPC_PORT` | 8123 | HTTP | JSON-RPC API |
| Execution Client WebSocket | `WEBSOCKET_PORT` | 7546 | WebSocket | WebSocket API |
| Execution Client Engine API | `ENGINE_API_PORT` | 8552 | HTTP | Consensus layer communication (internal) |
| op-node RPC | `NODE_RPC_PORT` | 9545 | HTTP | Consensus layer API |
| Execution Client P2P | `P2P_TCP_PORT`, `P2P_UDP_PORT` | 30303 | TCP/UDP | P2P network |
| op-node P2P | `NODE_P2P_PORT` | 9223 | TCP/UDP | Consensus layer P2P network |

To customize ports, edit the `.env` file before starting:

```bash
HTTP_RPC_PORT=8545
WEBSOCKET_PORT=8546
NODE_RPC_PORT=9545
```

### Configuration Files

- **`config/genesis.json`**: Genesis state for op-geth
- **`config/genesis-reth.json`**: Genesis state for op-reth (auto-generated)
- **`config/rollup-testnet.json`** / **`config/rollup-mainnet.json`**: Rollup configuration for op-node
- **`config/op-geth-config-testnet.toml`** / **`config/op-geth-config-mainnet.toml`**: op-geth node configuration
- **`config/op-reth-config-testnet.toml`**: op-reth node configuration
- **`config/jwt.txt`**: JWT secret for secure communication (auto-generated)

## Service Management

### Start Services

```bash
./start.sh testnet  # or mainnet
```

Or using Docker Compose directly:
```bash
docker compose up -d
```

### Stop Services

```bash
./stop.sh
```

Or using Docker Compose:
```bash
docker compose down
```

### Check Service Status

```bash
docker compose ps
```

### Restart Services

```bash
docker compose restart
```

### View Logs

```bash
# View all logs
docker compose logs -f

# View execution client logs
docker logs -f xlayer-op-geth
# or for reth:
docker logs -f xlayer-op-reth

# View op-node logs
docker logs -f xlayer-op-node
```

## Endpoints and Ports

Once running, your RPC node will be accessible at:

### HTTP RPC Endpoint
```bash
http://localhost:8123  # (or your custom HTTP_RPC_PORT)
```

Example request:
```bash
curl http://127.0.0.1:8123 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
```

### WebSocket Endpoint
```bash
ws://localhost:7546  # (or your custom WEBSOCKET_PORT)
```

### Node RPC Endpoint (Consensus Layer)
```bash
http://localhost:9545  # (or your custom NODE_RPC_PORT)
```

### Available RPC Methods

The node supports standard Ethereum JSON-RPC methods including:
- `eth_*` - Ethereum state and transaction methods
- `web3_*` - Web3 utility methods
- `net_*` - Network information
- `debug_*` - Debug methods (archive node)
- `txpool_*` - Transaction pool methods
- `admin_*` - Admin methods

## Monitoring and Logs

### Persistent Logs

Log files are saved in the `data/` directory:
- Execution client: Docker container logs
- op-node: Docker container logs

### Check Sync Status

```bash
# Check current block number
curl http://127.0.0.1:8123 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'

# Check sync status
curl http://127.0.0.1:8123 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_syncing","params":[],"id":1,"jsonrpc":"2.0"}'
```

## Troubleshooting

### Services Not Starting

1. **Check Docker is running:**
   ```bash
   docker info
   ```

2. **Check logs for errors:**
   ```bash
   docker compose logs
   ```

3. **Verify environment variables:**
   ```bash
   cat .env
   ```

### RPC Not Responding

1. **Check if services are healthy:**
   ```bash
   docker compose ps
   ```

2. **Test the endpoint:**
   ```bash
   curl http://127.0.0.1:8123 \
     -X POST \
     -H "Content-Type: application/json" \
     --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
   ```

3. **Check execution client logs:**
   ```bash
   docker logs -f xlayer-op-geth
   # or
   docker logs -f xlayer-op-reth
   ```

### Slow Sync

- **Initial sync can take hours or days** depending on your connection and system resources
- Monitor sync progress in op-node logs:
  ```bash
  docker logs -f xlayer-op-node
  ```
- Ensure you have sufficient disk space for the growing database

### Port Already in Use

If ports are already in use, edit `.env` and change the port variables:

```bash
HTTP_RPC_PORT=9999  # Use a different port
WEBSOCKET_PORT=9998
```

Then restart:
```bash
./stop.sh
./start.sh testnet
```

### L1 Connection Issues

- Verify your `L1_RPC_URL` is correct and accessible
- Ensure the L1 RPC provider supports the required methods
- Check network connectivity to the L1 endpoint

### Switching Between op-geth and op-reth

To switch execution clients:

1. Stop current services:
   ```bash
   ./stop.sh
   ```

2. Edit `.env`:
   ```bash
   L2_ENGINEKIND=reth  # or geth
   ```

3. Reinitialize if needed (data directories are separate):
   ```bash
   ./init.sh testnet
   ```

4. Restart:
   ```bash
   ./start.sh testnet
   ```

## Advanced Configuration

### Using op-reth Instead of op-geth

To use op-reth (experimental, Rust-based, higher performance):

1. Edit `.env`:
   ```bash
   L2_ENGINEKIND=reth
   ```

2. Initialize and start:
   ```bash
   ./init.sh testnet
   ./start.sh testnet
   ```

**Note**: op-reth uses separate data directory (`data/op-reth`) from op-geth (`data/op-geth`).

### Archive Node

By default, the node runs in **archive mode** (`--gcmode=archive`), which stores the complete historical state. This requires more disk space but allows querying historical data.

To run in full mode (less storage), edit the command in `docker-compose.yml`:
```yaml
--gcmode=full  # Instead of --gcmode=archive
```

### Custom P2P Settings

Edit P2P related parameters in `.env`:

```bash
OP_GETH_BOOTNODE=enode://...
P2P_STATIC=/ip4/...
```

### Enable Debug Mode

Increase log verbosity by editing the `--verbosity` parameter in `docker-compose.yml`:
- `0` = Silent
- `1` = Error
- `2` = Warning  
- `3` = Info (default)
- `4` = Debug
- `5` = Trace

## Update Node

### Update Docker Images

```bash
# Stop node
./stop.sh

# Pull latest images
docker pull xlayer/op-geth:latest
docker pull xlayer/op-node:latest

# Restart
./start.sh testnet  # or mainnet
```

### Data Migration

Usually no need to re-download data, but if you encounter issues:

```bash
# Backup current data
cp -r data data.backup

# Re-initialize (will delete existing data)
./init.sh testnet
```

## File Structure

```
rpc-setup/
├── one-click-setup.sh           # Automated setup script
├── init.sh                      # Manual initialization script
├── start.sh                     # Start services script
├── stop.sh                      # Stop services script
├── docker-compose.yml           # Docker Compose configuration (generated)
├── env.example                  # Example environment file
├── config/                      # Configuration templates
│   ├── genesis.json            # Genesis state (downloaded)
│   ├── genesis-reth.json       # Genesis for Reth (generated)
│   ├── rollup-testnet.json     # Testnet rollup config
│   ├── rollup-mainnet.json     # Mainnet rollup config
│   ├── op-geth-config-testnet.toml  # op-geth testnet settings
│   ├── op-geth-config-mainnet.toml  # op-geth mainnet settings
│   ├── op-reth-config-testnet.toml  # op-reth settings
│   └── jwt.txt                 # JWT secret (auto-generated)
├── data/                        # Blockchain data directory
│   ├── op-node/                # op-node data
│   ├── op-geth/                # op-geth data (if using geth)
│   └── op-reth/                # op-reth data (if using reth)
└── entrypoint/                  # Custom entrypoint scripts
    └── reth-rpc.sh             # Reth RPC docker entrypoint
```

## Network Information

### Testnet
- **Network ID**: 1952
- **Chain Name**: X Layer Testnet
- **Currency**: OKB
- **Legacy RPC**: https://testrpc.xlayer.tech
- **Legacy Cutoff Block**: 12241701

### Mainnet
- **Network ID**: 196
- **Chain Name**: X Layer
- **Currency**: OKB
- **Legacy RPC**: https://xlayerrpc.okx.com
- **Legacy Cutoff Block**: 42810021

## Support and Resources

- **Official Documentation**: [X Layer Docs](https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer)
- **X Layer RPC Endpoint**: [https://rpc.xlayer.tech](https://rpc.xlayer.tech)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)

## ⚠️ Important Notes

1. **Testnet**: Suitable for development and testing, data may be reset
2. **Mainnet**: Production environment use, requires higher resource requirements
3. **Backup**: Regularly backup data directory and configuration files
4. **Monitoring**: Continuously monitor node status and sync progress
5. **op-reth**: Experimental feature, use at your own risk
6. **Legacy RPC**: Automatically falls back to legacy RPC for blocks before cutoff block

## License

This project is part of the X Layer toolkit. Please refer to the main repository for licensing information.

---

**Note**: This setup supports dual execution engines (op-geth/op-reth), legacy RPC fallback, and both testnet/mainnet deployments.
