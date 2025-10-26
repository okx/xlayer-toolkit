# RPC Block Hash Compare Tool

A Golang tool to quickly locate the first inconsistent block height between two blockchain RPC nodes using binary search.

## Features

- Binary search algorithm for efficient comparison (O(log n))
- Compares block hashes from two RPC nodes
- Reports the first height where hashes differ
- Supports environment file (.env) configuration
- Log file output support
- Background daemon mode support

## Quick Start

### 1. Configuration

```bash
# Copy the example environment file
cp env.example .env

# Edit .env with your settings
vim .env
```

Example `.env` file:
```ini
URL1=http://127.0.0.1:8123
URL2=https://testrpc.xlayer.tech
START_HEIGHT=12703783
END_HEIGHT=12710000
```

### 2. Run

#### Option A: Direct Run
```bash
# Run with .env configuration
go run main.go

# Run with custom log file
go run main.go -log=compare.log

# Override config with command line flags
go run main.go -url1 http://localhost:8123 -start 12703783 -end 12710000
```

#### Option B: Background Mode
```bash
# Start in background (uses start.sh)
make start

# Or manually
bash start.sh

# Check status
make status

# View logs
make logs

# Stop background process
make stop
```

#### Option C: Build Binary
```bash
# Build
make build
./rpc-compare

# Install system-wide
make install
rpc-compare
```

## Configuration

### Environment Variables (.env file)

| Variable | Description | Default |
|----------|-------------|---------|
| `URL1` | First RPC URL | http://127.0.0.1:8123 |
| `URL2` | Second RPC URL | https://testrpc.xlayer.tech |
| `START_HEIGHT` | Start height for comparison | 12703783 |
| `END_HEIGHT` | End height for comparison | 12710000 |

### Command Line Flags

All flags can override .env values:

- `-env`: Path to environment file (default: .env)
- `-log`: Path to log file (default: console only)
- `-url1`: First RPC URL
- `-url2`: Second RPC URL
- `-start`: Start height
- `-end`: End height

## How It Works

1. Verifies that start height is consistent between both nodes
2. Verifies that end height is inconsistent between both nodes
3. Uses binary search to efficiently locate the first inconsistent height
4. Logs all operations to file (if specified)
5. Reports the block height where hashes first diverge

## Makefile Commands

```bash
make build    # Build binary
make run      # Run directly
make start    # Start in background
make stop     # Stop background process
make status   # Check running status
make logs     # Follow log file
make tail     # Show last 50 lines
make clean    # Remove build artifacts
```

## Background Mode

When running in background:

- Log file: `compare.log`
- Process ID is displayed on start
- Use `make logs` or `tail -f compare.log` to monitor
- Use `make stop` or `kill PID` to stop

## Examples

```bash
# Use .env configuration with log file
go run main.go -log=output.log

# Override URLs only
go run main.go -url1 http://node1:8123 -url2 http://node2:8123

# Override everything
go run main.go \
  -url1 http://127.0.0.1:8123 \
  -url2 https://testrpc.xlayer.tech \
  -start 12703783 \
  -end 12710000 \
  -log compare.log

# Background mode with all default settings
./start.sh

# Build and run as daemon
make build
nohup ./rpc-compare -log=daemon.log > daemon.log 2>&1 &
```

