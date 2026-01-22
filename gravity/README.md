# Gravity Node Management

A simple management tool for running Gravity Node in MOCK mode for local testing.

## Prerequisites

- `jq` - JSON processor (required for parsing configuration)
- `make` - Build automation tool
- `git` - Version control
- Rust toolchain (for building gravity_node)

## Quick Start

1. **Prepare environment** (clone repositories and apply patches):
   ```bash
   make prepare
   ```

2. **Build gravity_node**:
   ```bash
   make build
   ```

3. **Start gravity_node**:
   ```bash
   make start
   ```

## Configuration

The node reads configuration from `my_config/reth_config.json`. This file should contain:
- `env_vars`: Environment variables to export
- `reth_args`: Command-line arguments for gravity_node

### Configuration Options

**Environment Variables:**
- `MOCK_CONSENSUS`: Enable mock consensus mode
- `MOCK_SET_ORDERED_INTERVAL_MS`: Block interval in ms (e.g., `200`)
- `MOCK_MAX_BLOCK_SIZE`: Max transactions per block
  - **Native transfer (Pay) testing**: Set to `1000`
  - **ERC20 token testing**: Set to `10000`

**Performance Optimization (in reth_args):**
- `gravity.disable-grevm`: `true` to disable / `false` to enable parallel EVM
- `gravity.disable-pipe-execution`: `true` to disable / `false` to enable pipeline

Examples:
```json
// Fastest mode (both enabled)
"gravity.disable-grevm": false,
"gravity.disable-pipe-execution": false

// Debug mode (both disabled)
"gravity.disable-grevm": true,
"gravity.disable-pipe-execution": true

// Grevm disabled, Pipeline enabled
"gravity.disable-grevm": true,
"gravity.disable-pipe-execution": false
```

## Available Commands

Run `make help` to see all available commands:

- `make prepare` - Clone repositories and apply patches
- `make build` - Build gravity_node binary
- `make start` - Start gravity_node in background
- `make stop` - Stop running gravity_node
- `make logs` - View real-time logs
- `make clean` - Stop node and clean log files

## Project Structure

```
gravity/
├── Makefile              # Main entry point
├── README.md             # This file
├── 0001-local-testing.patch  # Patch for gravity-reth
├── my_config/            # Configuration files
│   └── reth_config.json  # Main configuration
└── scripts/              # Helper scripts
    ├── prepare.sh        # Setup script
    ├── add_patch.sh      # Patch management
    ├── build_gravity_node.sh  # Build script
    └── start_mock.sh     # Start script
```

## How It Works

1. **prepare**: Clones `gravity-reth` and `gravity-sdk` repositories, applies local testing patches
2. **build**: Adds Cargo.toml patch configuration (if needed) and builds the binary
3. **start**: Parses configuration, exports environment variables, and starts gravity_node in background
4. **stop**: Kills the process running on port 8545
5. **clean**: Stops the node (if running) and removes log files

## Logs

Logs are written to `gravity_node.out` in the gravity directory. View them with:
```bash
make logs
```

Or directly:
```bash
tail -f gravity_node.out
```

## Troubleshooting

- **Port 8545 already in use**: Run `make stop` first, or manually kill the process
- **Build fails**: Ensure Rust toolchain is installed and `make prepare` has been run
- **Config file not found**: Ensure `my_config/reth_config.json` exists
- **jq not found**: Install jq using the commands in Prerequisites section

## Notes

- The node runs in MOCK mode for local testing
- All scripts automatically handle directory navigation
- The build process automatically adds required Cargo.toml patches

