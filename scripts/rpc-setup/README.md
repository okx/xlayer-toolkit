# X Layer RPC Node Setup

Complete self-hosted X Layer RPC node deployment solution, supporting quick deployment and management of your own X Layer RPC endpoint.

## 📋 Overview

X Layer is a Layer 2 network built on Optimism OP Stack. This project provides a comprehensive set of tools for deploying and managing your own X Layer RPC node.

### Core Components

- **op-geth**: X Layer execution layer client (modified version based on Geth)
- **op-node**: X Layer consensus layer client, connects to Ethereum L1 and manages L2 state

### Network Support

- **Testnet (Chain ID: 1952)**: Test network
- **Mainnet (Chain ID: 196)**: Main network

## 🚀 Quick Start

### Method 1: One-Click Deployment (Recommended)

Use the one-click deployment script to automatically complete all configuration:

```bash
# One-click installation and setup
curl -fsSL https://raw.githubusercontent.com/okx/xlayer-toolkit/main/scripts/rpc-setup/one-click-setup.sh -o one-click-setup.sh
chmod +x one-click-setup.sh && ./one-click-setup.sh
```

### Method 2: Step-by-Step Deployment

If you want to manually control the deployment process:

#### 1. Initialize Node

```bash
# Initialize testnet
./init.sh testnet

# Or initialize mainnet
./init.sh mainnet
```

This will complete the following operations:
- Download and extract Genesis file
- Copy configuration files to corresponding network directories
- Initialize op-geth database

#### 2. Configure Environment Variables

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

## 📁 Project Structure

```
rpc-setup/
├── init.sh                 # Initialization script
├── start.sh                # Start script
├── stop.sh                 # Stop script
├── one-click-setup.sh     # One-click deployment script
├── env.example             # Environment variable template
├── config/                 # Configuration directory
│   ├── op-geth-config-testnet.toml   # Testnet op-geth config
│   ├── op-geth-config-mainnet.toml   # Mainnet op-geth config
│   ├── rollup-testnet.json           # Testnet rollup config
│   └── rollup-mainnet.json           # Mainnet rollup config
├── data-testnet/           # Testnet data directory (generated after init)
├── data-mainnet/           # Mainnet data directory (generated after init)
├── config-testnet/         # Testnet config directory (generated after init)
├── config-mainnet/         # Mainnet config directory (generated after init)
└── logs-testnet/           # Testnet logs directory
    logs-mainnet/           # Mainnet logs directory
```

## 🔧 System Requirements

### Minimum Requirements

- **CPU**: 4 cores
- **Memory**: 8 GB RAM
- **Storage**: 50 GB available space (testnet), 300+ GB (mainnet)
- **Network**: Stable internet connection (recommended upload bandwidth > 10 Mbps)

### Software Dependencies

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

## 🌐 Port Configuration

Default port configuration:

| Service | Port | Protocol | Description |
|---------|------|----------|-------------|
| op-geth HTTP RPC | 8545 | HTTP | JSON-RPC API |
| op-geth WebSocket | 8546 | WebSocket | WebSocket API |
| op-geth Engine API | 8552 | HTTP | Consensus layer communication (internal) |
| op-node RPC | 9545 | HTTP | Consensus layer API |
| op-geth P2P | 30303 | TCP/UDP | Geth P2P network |
| op-node P2P | 9223 | TCP/UDP | Consensus layer P2P network |

## 📡 RPC API Endpoints

After starting the node, you can access it through the following endpoints:

### HTTP RPC

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
```

### WebSocket

```javascript
const ws = new WebSocket('ws://localhost:8546');
```

### Test Connection

```bash
# Get latest block number
curl http://127.0.0.1:8545 \
  -X POST \
  -H "Content-Type: application/json" \
  --data '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}'
```

## 📊 Monitoring and Logs

### Check Service Status

```bash
docker compose ps
```

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

## 🛠️ Advanced Configuration

### Custom Ports

Select custom ports in `one-click-setup.sh`, or directly modify port mapping in `start.sh`.

### Modify P2P Settings

Edit P2P related parameters in configuration file:

```toml
[Node.P2P]
MaxPeers = 30  # Maximum connections
```

### Enable Debug Mode

Increase log verbosity:

Modify `--verbosity` parameter in `start.sh`:
- `0` = Silent
- `1` = Error
- `2` = Warning
- `3` = Info
- `4` = Debug
- `5` = Trace

## 🔄 Update Node

### Update Docker Images

```bash
# Stop node
./stop.sh

# Pull latest images
docker pull xlayer/op-geth:latest
docker pull xlayer/op-stack:latest

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

## ⚠️ Important Notes

1. **Testnet**: Suitable for development and testing, data may be reset
2. **Mainnet**: Production environment use, requires higher resource requirements
3. **Backup**: Regularly backup data directory and configuration files
4. **Monitoring**: Continuously monitor node status and sync progress

## 📄 License

Please refer to the LICENSE file in the project root directory.
