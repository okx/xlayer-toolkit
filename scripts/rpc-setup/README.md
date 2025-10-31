# X Layer RPC Node Setup

Complete self-hosted X Layer RPC node deployment solution, supporting quick deployment and management of your own X Layer RPC endpoint.

## 📋 Overview

X Layer is a Layer 2 network built on Optimism OP Stack. This project provides a comprehensive set of tools for deploying and managing your own X Layer RPC node.

### Core Components

- **Execution Layer Client** (choose one):
  - **op-geth**: Go-based execution client (default, stable and battle-tested)
  - **op-reth**: Rust-based execution client (high performance, lower memory footprint)
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

The script will prompt you to choose:
- Network type: `testnet` or `mainnet`
- RPC client type: `geth` (default) or `reth`

### Method 2: Step-by-Step Deployment

If you want to manually control the deployment process:

#### 1. Initialize Node

```bash
# Initialize testnet with op-geth (default)
./init.sh testnet

# Initialize testnet with op-reth
./init.sh testnet reth

# Or initialize mainnet with op-geth
./init.sh mainnet

# Or initialize mainnet with op-reth
./init.sh mainnet reth
```

This will complete the following operations:
- Download and extract Genesis file
- Copy configuration files to corresponding network directories
- Initialize execution client (op-geth or op-reth) database

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
# Start testnet node with op-geth (default)
./start.sh testnet

# Start testnet node with op-reth
./start.sh testnet reth

# Or start mainnet node with op-geth
./start.sh mainnet

# Or start mainnet node with op-reth
./start.sh mainnet reth
```

**Note**: The RPC type must match what you used in the initialization step.

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
│   ├── op-reth-config-testnet.toml   # Testnet op-reth config
│   ├── op-reth-config-mainnet.toml   # Mainnet op-reth config
│   ├── rollup-testnet.json           # Testnet rollup config
│   └── rollup-mainnet.json           # Mainnet rollup config
├── data-testnet-geth/      # Testnet Geth data (generated after init)
├── data-testnet-reth/      # Testnet Reth data (generated after init)
├── data-mainnet-geth/      # Mainnet Geth data (generated after init)
├── data-mainnet-reth/      # Mainnet Reth data (generated after init)
├── config-testnet-geth/    # Testnet Geth config (generated after init)
├── config-testnet-reth/    # Testnet Reth config (generated after init)
├── config-mainnet-geth/    # Mainnet Geth config (generated after init)
├── config-mainnet-reth/    # Mainnet Reth config (generated after init)
└── logs-testnet-geth/      # Testnet Geth logs
    logs-testnet-reth/      # Testnet Reth logs
    logs-mainnet-geth/      # Mainnet Geth logs
    logs-mainnet-reth/      # Mainnet Reth logs
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

### Choosing Between Geth and Reth

**Use op-geth if:**
- You prefer stability and proven track record
- You need maximum compatibility
- You're familiar with Geth's tooling

**Use op-reth if:**
- You want better performance and efficiency
- You need lower memory consumption
- You're interested in Rust-based infrastructure

### Custom Ports

Select custom ports in `one-click-setup.sh`, or directly modify port mapping in `start.sh`.

### Modify P2P Settings

**For op-geth**, edit P2P related parameters in configuration file:

```toml
[Node.P2P]
MaxPeers = 30  # Maximum connections
```

**For op-reth**, edit in configuration file:

```toml
[p2p]
max_outbound_peers = 30
max_inbound_peers = 30
```

### Enable Debug Mode

**For op-geth**, modify `--verbosity` parameter in `start.sh`:
- `0` = Silent
- `1` = Error
- `2` = Warning  
- `3` = Info
- `4` = Debug
- `5` = Trace

**For op-reth**, modify `--log.level` parameter:
- `error`, `warn`, `info`, `debug`, `trace`

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
5. **Client Choice**: Once initialized with a specific client (geth/reth), you should continue using the same client. Switching requires re-initialization
6. **Reth Status**: op-reth is a newer client. While highly performant, it may have different compatibility characteristics than op-geth

## 📄 License

Please refer to the LICENSE file in the project root directory.