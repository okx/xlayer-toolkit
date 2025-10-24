# X Layer RPC Node Setup

A comprehensive toolkit for deploying and managing an X Layer RPC node using Docker. This setup provides a full-featured, self-hosted RPC endpoint for the X Layer network (OP Stack based Layer 2 solution).

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Manual Setup](#manual-setup)
- [Configuration](#configuration)
- [Service Management](#service-management)
- [Endpoints and Ports](#endpoints-and-ports)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)

## Overview

X Layer RPC Node is a self-hosted setup for running a full RPC node on the X Layer testnet. It consists of two main components:

- **op-geth**: The execution layer client (Layer 2 Ethereum client)
- **op-node**: The consensus layer client (rollup node)

Both components run in Docker containers and work together to sync and validate blocks from the X Layer network.

## Features

- ✅ **One-Click Setup**: Automated installation script for quick deployment
- 🐳 **Docker-Based**: Easy deployment with Docker Compose
- 🔄 **Full RPC Support**: HTTP, WebSocket, and Admin RPC endpoints
- 📊 **Archive Mode**: Full blockchain data with archive node capability
- 🌐 **P2P Network**: Connect to X Layer testnet via bootnodes
- 🔐 **JWT Authentication**: Secure communication between components
- 📦 **Modular**: Support for both op-geth and op-reth (experimental)

## Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu 24.04+ recommended)
- **Memory**: 16GB RAM minimum (32GB+ recommended)
- **Storage**: 100GB+ available disk space (SSD recommended)
- **CPU**: 4+ cores recommended

### Software Requirements

- Docker 20.10+
- Docker Compose 2.0+
- wget
- tar
- openssl
- curl (for testing)

## Quick Start

### Option 1: One-Click Setup Script

The easiest way to get started is using the automated setup script:

```bash
# Download and run the one-click setup script
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/main/scripts/rpc-setup/one-click-setup.sh | bash
```

Or download and run locally:

```bash
# Download the script
wget https://raw.githubusercontent.com/okx/xlayer-toolkit/main/scripts/rpc-setup/one-click-setup.sh

# Make it executable
chmod +x one-click-setup.sh

# Run the setup
./one-click-setup.sh
```

The script will:
1. Check system requirements
2. Download necessary configuration files
3. Prompt for configuration (L1 RPC URL, ports, etc.)
4. Initialize the node with genesis data
5. Start all services
6. Verify the installation

## Manual Setup

If you prefer manual setup or want more control:

### Step 1: Clone or Download Configuration Files

Ensure you have all the required files in the `rpc-setup` directory.

### Step 2: Configure Environment

```bash
# Copy the example environment file
cp env.example .env

# Edit the .env file and configure your settings
nano .env
# or
vim .env
```

Required configuration in `.env`:
```bash
# L1 RPC URL (Ethereum mainnet RPC endpoint)
L1_RPC_URL=https://your-ethereum-rpc-endpoint

# Bootnode Configuration (pre-configured for testnet)
OP_NODE_BOOTNODE=enode://eaae9fe2fc758add65fe4cfd42918e898e16ab23294db88f0dcdbcab2773e75bbea6bfdaa42b3ed502dfbee1335c242c602078c4aa009264e4705caa20d3dca7@8.210.181.50:9223
OP_GETH_BOOTNODE=enode://2104d54a7fbd58a408590035a3628f1e162833c901400d490ccc94de416baf13639ce2dad388b7a5fd43c535468c106b660d42d94451e39b08912005aa4e4195@8.210.181.50:30303

# Docker Image Tags
OP_STACK_IMAGE_TAG=xlayer/op-stack:release-testnet
OP_GETH_IMAGE_TAG=xlayer/op-geth:release-testnet

# RPC Type (geth or reth)
L2_ENGINEKIND=geth
```

### Step 3: Initialize the Node

```bash
# Run initialization script
./init.sh testnet
```

This will:
- Download the genesis file (~500MB+)
- Extract and prepare genesis configuration
- Initialize op-geth with the genesis state

### Step 4: Start the Services

```bash
# Start the RPC node
./start.sh testnet
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `L1_RPC_URL` | Ethereum L1 RPC endpoint | *Required* |
| `OP_NODE_BOOTNODE` | OP Node bootnode enode URL | Pre-configured |
| `OP_GETH_BOOTNODE` | OP Geth bootnode enode URL | Pre-configured |
| `OP_STACK_IMAGE_TAG` | Docker image for op-node | `xlayer/op-stack:release-testnet` |
| `OP_GETH_IMAGE_TAG` | Docker image for op-geth | `xlayer/op-geth:release-testnet` |
| `L2_ENGINEKIND` | RPC engine type (geth/reth) | `geth` |

### Port Configuration

Default ports exposed by the services:

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| op-geth | 8123 | HTTP | JSON-RPC API |
| op-geth | 8546 | WebSocket | WebSocket API |
| op-geth | 8552 | HTTP | Engine API (authenticated) |
| op-geth | 30303 | TCP/UDP | P2P Network |
| op-node | 9545 | HTTP | Consensus Layer API |
| op-node | 9223 | TCP/UDP | P2P Network |

To customize ports, edit the `docker-compose.yml` file.

### Configuration Files

- **`config/genesis.json`**: Genesis state for op-geth
- **`config/rollup.json`**: Rollup configuration for op-node
- **`config/op-geth-config-testnet.toml`**: op-geth node configuration
- **`config/jwt.txt`**: JWT secret for secure communication (auto-generated)

## Service Management

### Start Services

```bash
./start.sh testnet
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

### View Logs

```bash
# View all logs
docker compose logs -f

# View op-geth logs only
docker logs -f xlayer-op-geth

# View op-node logs only
docker logs -f xlayer-op-node
```

### Check Service Status

```bash
docker compose ps
```

### Restart Services

```bash
docker compose restart
```

## Endpoints and Ports

Once running, your RPC node will be accessible at:

### HTTP RPC Endpoint
```bash
http://localhost:8123
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
ws://localhost:8546
```

### Node RPC Endpoint (Consensus Layer)
```bash
http://localhost:9545
```

### Available RPC Methods

The node supports standard Ethereum JSON-RPC methods including:
- `eth_*` - Ethereum state and transaction methods
- `web3_*` - Web3 utility methods
- `net_*` - Network information
- `debug_*` - Debug methods (archive node)
- `txpool_*` - Transaction pool methods
- `admin_*` - Admin methods

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

3. **Check op-geth logs:**
   ```bash
   docker logs -f xlayer-op-geth
   ```

### Slow Sync

- **Initial sync can take hours or days** depending on your connection and system resources
- Monitor sync progress in op-node logs:
  ```bash
  docker logs -f xlayer-op-node
  ```
- Ensure you have sufficient disk space for the growing database

### Port Already in Use

If ports are already in use, you can modify them in `docker-compose.yml`:

```yaml
ports:
  - "CUSTOM_PORT:8545"  # Change CUSTOM_PORT to your preferred port
```

### L1 Connection Issues

- Verify your `L1_RPC_URL` is correct and accessible
- Ensure the L1 RPC provider supports the required methods
- Check network connectivity to the L1 endpoint

## File Structure

```
rpc-setup/
├── one-click-setup.sh           # Automated setup script
├── init.sh                      # Manual initialization script
├── start.sh                     # Start services script
├── stop.sh                      # Stop services script
├── docker-compose.yml           # Docker Compose configuration
├── env.example                  # Example environment file
├── config/                      # Configuration directory
│   ├── genesis.json            # Genesis state (downloaded)
│   ├── genesis-reth.json       # Genesis for Reth (generated)
│   ├── rollup.json             # Rollup configuration
│   ├── op-geth-config-testnet.toml  # op-geth settings
│   ├── op-reth-config-testnet.toml  # op-reth settings
│   └── jwt.txt                 # JWT secret (auto-generated)
├── data/                        # Blockchain data directory
│   ├── op-node/                # op-node data
│   └── op-reth/                # op-reth data (if using reth)
└── entrypoint/                  # Custom entrypoint scripts
    └── reth-rpc.sh             # Reth RPC entrypoint
```

## Advanced Configuration

### Using op-reth Instead of op-geth

To use op-reth (experimental) as the execution client:

1. Edit `.env`:
   ```bash
   L2_ENGINEKIND=reth
   ```

2. Reinitialize and restart:
   ```bash
   ./init.sh testnet
   ./start.sh testnet
   ```

### Archive Node

By default, the node runs in **archive mode** (`--gcmode=archive`), which stores the complete historical state. This requires more disk space but allows querying historical data.

To run in full mode (less storage), edit `docker-compose.yml` and change:
```yaml
--gcmode=archive  # Change to --gcmode=full
```

## Network Information

### Testnet
- **Network ID**: 1952
- **Chain Name**: X Layer Testnet
- **Currency**: OKB

### Mainnet
⚠️ Mainnet support coming soon

## Support and Resources

- **Official Documentation**: [X Layer Docs](https://docs.okx.com/xlayer)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)
- **Discord**: [X Layer Community](https://discord.gg/xlayer)

## License

This project is part of the X Layer toolkit. Please refer to the main repository for licensing information.

---

**Note**: This setup is designed for testnet. Mainnet support will be available in future releases.

