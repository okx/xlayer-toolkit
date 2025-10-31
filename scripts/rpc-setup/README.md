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
- [Monitoring and Logs](#monitoring-and-logs)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)

## Overview

X Layer is a Layer 2 network built on Optimism OP Stack. This project provides a comprehensive set of tools for deploying and managing your own X Layer RPC node.

### Core Components

- **op-geth**: X Layer execution layer client (modified version based on Geth)
- **op-node**: X Layer consensus layer client, connects to Ethereum L1 and manages L2 state

### Network Support

- **Testnet (Chain ID: 1952)**: Test network
- **Mainnet (Chain ID: 196)**: Main network

## Features

- ✅ **One-Click Setup**: Automated installation script for quick deployment
- 🐳 **Docker-Based**: Easy deployment with Docker Compose
- 🔄 **Full RPC Support**: HTTP, WebSocket, and Admin RPC endpoints
- 📊 **Archive Mode**: Full blockchain data with archive node capability
- 🌐 **P2P Network**: Connect to X Layer network via bootnodes
- 🔐 **JWT Authentication**: Secure communication between components
- 🌍 **Multi-Network**: Support for both Testnet and Mainnet

## Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu 24.04+ recommended)
- **Memory**: 16GB RAM minimum (32GB+ recommended)
- **Storage**: 
  - Testnet: 50GB+ available space
  - Mainnet: 300GB+ available space (SSD recommended)
- **CPU**: 4+ cores recommended
- **Network**: Stable internet connection (recommended upload bandwidth > 10 Mbps)

### Software Requirements

- Docker 20.10+
- Docker Compose 2.0+
- wget
- tar
- openssl

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
3. Prompt for configuration (L1 RPC URL, network type, ports, etc.)
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
```

#### 2. Initialize Node

```bash
# Initialize testnet
./init.sh testnet

# Or initialize mainnet
./init.sh mainnet
```

This will complete the following operations:
- Download and extract Genesis file (~500MB+)
- Copy configuration files to corresponding network directories
- Initialize op-geth database

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

# L1 Beacon URL (Ethereum Beacon chain endpoint)
L1_BEACON_URL=https://your-ethereum-l1-beacon-endpoint
```

### Step 3: Initialize the Node

```bash
# Run initialization script for your chosen network
./init.sh testnet  # or mainnet
```

This will:
- Download the genesis file
- Extract and prepare genesis configuration
- Initialize op-geth with the genesis state

### Step 4: Start the Services

```bash
# Start the RPC node
./start.sh testnet  # or mainnet
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `L1_RPC_URL` | Ethereum L1 RPC endpoint | *Required* |
| `L1_BEACON_URL` | Ethereum L1 Beacon endpoint | *Required* |

Network-specific configurations (bootnode URLs, image tags, etc.) are automatically set based on the network type you choose (testnet/mainnet).

### Port Configuration

Default port configuration:

| Service | Port | Protocol | Description |
|---------|------|----------|-------------|
| op-geth HTTP RPC | 8545 | HTTP | JSON-RPC API |
| op-geth WebSocket | 7546 | WebSocket | WebSocket API |
| op-geth Engine API | 8552 | HTTP | Consensus layer communication (internal) |
| op-node RPC | 9545 | HTTP | Consensus layer API |
| op-geth P2P | 30303 | TCP/UDP | Geth P2P network |
| op-node P2P | 9223 | TCP/UDP | Consensus layer P2P network |

To customize ports, you can select them during one-click setup, or modify the generated `docker-compose.yml` file.

### Configuration Files

- **`config-{network}/genesis-{network}.json`**: Genesis state for op-geth
- **`config-{network}/rollup-{network}.json`**: Rollup configuration for op-node
- **`config-{network}/op-geth-config-{network}.toml`**: op-geth node configuration
- **`config-{network}/jwt.txt`**: JWT secret for secure communication (auto-generated)

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

## Endpoints and Ports

Once running, your RPC node will be accessible at:

### HTTP RPC Endpoint
```bash
http://localhost:8545
```

Example request:
```bash
curl http://127.0.0.1:8545 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
```

### WebSocket Endpoint
```bash
ws://localhost:7546
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

## Monitoring and Logs

### View Logs

```bash
# View all service logs
docker compose logs -f

# View op-geth logs
docker compose logs -f op-geth

# View op-node logs
docker compose logs -f op-node
```

### Persistent Logs

Log files are saved in the following locations:
- op-geth: `logs-{network}/op-geth/geth.log`
- op-node: `logs-{network}/op-node/op-node.log`

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
   curl http://127.0.0.1:8545 \
     -X POST \
     -H "Content-Type: application/json" \
     --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
   ```

3. **Check op-geth logs:**
   ```bash
   docker logs -f xlayer-testnet-op-geth  # or xlayer-mainnet-op-geth
   ```

### Slow Sync

- **Initial sync can take hours or days** depending on your connection and system resources
- Monitor sync progress in op-node logs:
  ```bash
  docker logs -f xlayer-testnet-op-node  # or xlayer-mainnet-op-node
  ```
- Ensure you have sufficient disk space for the growing database

### Port Already in Use

If ports are already in use, you can modify them during one-click setup or in the generated `docker-compose.yml`:

```yaml
ports:
  - "CUSTOM_PORT:8545"  # Change CUSTOM_PORT to your preferred port
```

### L1 Connection Issues

- Verify your `L1_RPC_URL` and `L1_BEACON_URL` are correct and accessible
- Ensure the L1 RPC provider supports the required methods
- Check network connectivity to the L1 endpoints

## File Structure

```
rpc-setup/
├── one-click-setup.sh           # Automated setup script
├── init.sh                      # Manual initialization script
├── start.sh                     # Start services script
├── stop.sh                      # Stop services script
├── env.example                  # Example environment file
├── config/                      # Configuration templates
│   ├── op-geth-config-testnet.toml
│   ├── op-geth-config-mainnet.toml
│   ├── rollup-testnet.json
│   └── rollup-mainnet.json
├── data-testnet/                # Testnet data directory (generated after init)
│   ├── op-node/                 # op-node data
│   └── geth/                    # op-geth data
├── data-mainnet/                # Mainnet data directory (generated after init)
│   ├── op-node/                 # op-node data
│   └── geth/                    # op-geth data
├── config-testnet/              # Testnet config directory (generated after init)
│   ├── genesis-testnet.json
│   ├── rollup-testnet.json
│   ├── op-geth-config-testnet.toml
│   └── jwt.txt
├── config-mainnet/              # Mainnet config directory (generated after init)
│   ├── genesis-mainnet.json
│   ├── rollup-mainnet.json
│   ├── op-geth-config-mainnet.toml
│   └── jwt.txt
├── logs-testnet/                # Testnet logs directory
│   ├── op-geth/
│   └── op-node/
└── logs-mainnet/                # Mainnet logs directory
    ├── op-geth/
    └── op-node/
```

## Advanced Configuration

### Custom Ports

Select custom ports during `one-click-setup.sh`, or directly modify port mapping in the generated `docker-compose.yml`.

### Modify P2P Settings

Edit P2P related parameters in configuration file:

```toml
[Node.P2P]
MaxPeers = 30  # Maximum connections
```

### Enable Debug Mode

Increase log verbosity by modifying `--verbosity` parameter in the `start.sh` or generated docker-compose.yml:
- `0` = Silent
- `1` = Error
- `2` = Warning  
- `3` = Info (default)
- `4` = Debug
- `5` = Trace

### Archive Node

By default, the node runs in **archive mode** (`--gcmode=archive`), which stores the complete historical state. This requires more disk space but allows querying historical data.

To run in full mode (less storage), edit the generated `docker-compose.yml` and change:
```yaml
--gcmode=archive  # Change to --gcmode=full
```

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
cp -r data-testnet data-testnet.backup

# Re-initialize (will delete existing data)
./init.sh testnet
```

## Network Information

### Testnet
- **Network ID**: 1952
- **Chain Name**: X Layer Testnet
- **Currency**: OKB

### Mainnet
- **Network ID**: 196
- **Chain Name**: X Layer
- **Currency**: OKB

## Important Notes

1. **Testnet**: Suitable for development and testing, data may be reset
2. **Mainnet**: Production environment use, requires higher resource requirements
3. **Backup**: Regularly backup data directory and configuration files
4. **Monitoring**: Continuously monitor node status and sync progress

## Support and Resources

- **Official Documentation**: [X Layer Docs](https://web3.okx.com/xlayer/docs/developer/build-on-xlayer/about-xlayer)
- **GitHub Repository**: [xlayer-toolkit](https://github.com/okx/xlayer-toolkit)

## License

This project is part of the X Layer toolkit. Please refer to the main repository for licensing information.
