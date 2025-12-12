# Configuration Guide

This document explains how to configure and use the environment-based configuration system for all scripts in this project.

## Quick Start

1. **Copy example configurations:**
   ```bash
   cp reth.env.example reth.env
   cp geth.env.example geth.env
   cp replayor.env.example replayor.env
   ```

2. **Edit configurations for your environment:**
   ```bash
   vim reth.env    # Configure Reth paths and settings
   vim geth.env    # Configure Geth paths and settings
   vim replayor.env # Configure replayor settings
   ```

3. **Run scripts:**
   ```bash
   ./reth.sh       # Start Reth node
   ./geth.sh       # Start Geth node
   ./replayor.sh   # Run replayor
   ```

## Configuration Files

### reth.env
Configuration for all Reth-related scripts:
- `reth.sh` - Runs the Reth node
- `op-reth-init.sh` - Initializes Reth database
- `unwind.sh` - Unwinds Reth database

**Key settings:**
- `RETH_BINARY` - Path to op-reth or reth binary
- `RETH_DATA_DIR` - Data directory path
- `RETH_CHAIN` - Chain/genesis configuration file
- `RETH_JWT_SECRET` - JWT secret for authenticated RPC
- `RETH_HTTP_PORT`, `RETH_WS_PORT`, `RETH_AUTHRPC_PORT` - Network ports
- `UNWIND_TO_BLOCK` - Default block number for unwinding

### geth.env
Configuration for Geth node:
- `geth.sh` - Runs the Geth node

**Key settings:**
- `GETH_BINARY` - Path to op-geth or geth binary
- `GETH_DATA_DIR` - Data directory path
- `GETH_JWT_SECRET` - JWT secret for authenticated RPC
- `GETH_HTTP_PORT`, `GETH_WS_PORT`, `GETH_AUTHRPC_PORT` - Network ports
- `GETH_TXPOOL_*` - Transaction pool settings

### replayor.env
Configuration for the replayor tool:
- `replayor.sh` - Runs the replayor

**Key settings:**
- `REPLAYOR_BINARY` - Path to replayor binary
- `ENGINE_API_SECRET` - JWT secret for engine API
- `ENGINE_API_URL` - Authenticated RPC endpoint
- `EXECUTION_URL` - HTTP RPC endpoint
- `SOURCE_NODE_URL` - Source node to fetch blocks from
- `STRATEGY` - Replay strategy (replay, stress, erc20)
- `ROLLUP_CONFIG_PATH` - Path to rollup configuration
- `DISK_PATH` - Path to store results
- `STORAGE_TYPE` - Storage type (disk, s3)
- `BLOCK_COUNT` - Number of blocks to process

## Using Custom Configuration Files

All scripts support the `ENV_FILE` environment variable to specify a custom configuration file:

```bash
# Use custom Reth configuration
ENV_FILE=./test-configs/my-reth.env ./reth.sh

# Use custom Geth configuration
ENV_FILE=./test-configs/my-geth.env ./geth.sh

# Use custom replayor configuration
ENV_FILE=./test-configs/my-test.env ./replayor.sh
```

## Script Reference

### Node Management

```bash
# Initialize Reth database
./op-reth-init.sh

# Start Reth node
./reth.sh

# Start Geth node
./geth.sh
```

### Database Operations

```bash
# Unwind to specific block (command line argument)
./unwind.sh 8594000

# Unwind using environment variable
UNWIND_TO_BLOCK=8594000 ./unwind.sh

# Unwind using value from reth.env
./unwind.sh
```

### Running Replayor

```bash
# Run with default settings from replayor.env
./replayor.sh

# Override specific settings
BLOCK_COUNT=100 STRATEGY=stress ./replayor.sh

# Use completely different config
ENV_FILE=./test-configs/stress-test.env ./replayor.sh
```

## Debugging

All scripts support standard bash debugging flags:

```bash
# Enable debug output (already in reth.sh and replayor.sh)
bash -x ./reth.sh

# Or add to script temporarily
set -x  # Enable debug mode
```

## Security Notes

1. **Never commit `.env` files** - They contain sensitive paths and secrets
2. **Always commit `.env.example` files** - These provide templates for others
3. **Update `.gitignore`** - Already configured to ignore `*.env` but keep `*.env.example`
4. **Use different JWT secrets** - Change the default secrets in production

## Default Values

All scripts include sensible defaults if configuration is not provided:
- Binaries: Assumes tools are in PATH (e.g., `op-reth`, `geth`, `replayor`)
- Data directories: Uses `./reth-data`, `./geth-data` in current directory
- Ports: Standard ports (HTTP: 9123, WS: 9124, AuthRPC: 8553)
- Chain config: `./rollup.json`
- JWT secret: `./jwt.txt`

## Troubleshooting

### "Warning: .env not found"
- Copy the `.env.example` file to `.env` for the relevant script
- Or use `ENV_FILE` to point to your config file

### "Command not found"
- Specify full path to binary in `.env` file (e.g., `RETH_BINARY=/path/to/op-reth`)
- Or ensure binary is in your PATH

### "Permission denied"
- Ensure scripts are executable: `chmod +x *.sh`

