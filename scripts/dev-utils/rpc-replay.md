# RPC Replay Tool

**Status:** ✅ Stable  
**Tests:** Manual verification required  
**Purpose:** Build custom Docker images from source and verify RPC node sync from scratch

## Overview

The RPC Replay Tool is a comprehensive automation script that:
- Clones/updates source code repositories from specified branches/tags
- Builds custom Docker images for op-node and execution clients (op-reth/op-geth)
- Updates network configuration with local image tags
- Launches RPC node with automated setup
- Monitors sync progress and verifies block consistency against mainnet

This tool is essential for:
- Testing custom code branches before deployment
- Validating node sync correctness
- Debugging consensus or sync issues
- Development and CI/CD workflows

## Prerequisites

### Required Tools
- `git` - Source code management
- `docker` - Container runtime (daemon must be running)
- `curl` - HTTP requests for RPC calls
- `jq` - JSON parsing
- `expect` - Automated interaction with setup script

### Installation

**macOS:**
```bash
brew install git docker curl jq expect
```

**Ubuntu/Debian:**
```bash
sudo apt-get install git docker.io curl jq expect
```

### System Requirements
- **Disk Space:** ~50GB (repositories + Docker images + chaindata)
- **Memory:** 8GB+ recommended
- **Network:** Stable internet connection for cloning repos and syncing
- **Ports:** 8545 must be available (checked automatically)

## Usage

### Two Modes of Operation

#### Mode 1: Interactive Mode (Default)

Run the script directly and answer prompts:

```bash
cd /path/to/xlayer-toolkit
./scripts/dev-utils/rpc-replay.sh
```

#### Mode 2: Non-Interactive Mode (Recommended for Long Runs)

1. **Edit the configuration section** at the top of `rpc-replay.sh`:

```bash
vi scripts/dev-utils/rpc-replay.sh
```

2. **Fill in the configuration variables** (lines 15-39):

```bash
# Client type: "reth" or "geth"
CLIENT_TYPE="reth"

# Branch/tag for optimism repository
OPTIMISM_BRANCH="v1.9.0"

# Branch/tag for reth (if using reth)
RETH_BRANCH="op-reth/v1.1.0"

# L1 Ethereum endpoint (supports both RPC and Beacon API)
L1_ENDPOINT="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
```

3. **Run in background using screen**:

```bash
# Start new screen session
screen -S rpc-replay

# Run the script
./scripts/dev-utils/rpc-replay.sh

# Detach from session: Ctrl+A then D
# The script continues running in background

# Reattach later to check progress
screen -r rpc-replay
```

Or **using tmux**:

```bash
# Start new tmux session
tmux new -s rpc-replay

# Run the script
./scripts/dev-utils/rpc-replay.sh

# Detach: Ctrl+B then D
# Reattach: tmux attach -t rpc-replay
```

### Interactive Prompts

In interactive mode, the script will prompt for:

1. **Client type** (`reth` or `geth`)
2. **Optimism branch/tag** (e.g., `v1.9.0`, `main`)
3. **Execution client branch/tag**:
   - For reth: `op-reth/v1.1.0`
   - For geth: `v1.101408.0`
4. **L1 Endpoint** (Ethereum L1 endpoint supporting both RPC and Beacon API)

### Example Session

```bash
$ ./scripts/dev-utils/rpc-replay.sh

==================================================
  X Layer RPC Replay Tool
  Build and verify RPC node sync from scratch
==================================================

Step 1: Checking dependencies
ℹ️  ✓ git found
ℹ️  ✓ docker found
ℹ️  ✓ curl found
ℹ️  ✓ jq found
ℹ️  ✓ expect found
✅ All dependencies satisfied

Step 2: Collecting user input
Please provide the following information:

1. Client type (reth/geth): reth
2. Optimism branch/tag: v1.9.0
3. Reth branch/tag: op-reth/v1.1.0
4. L1 Endpoint (Ethereum RPC + Beacon): https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
✅ Input collection completed

Step 3: Preparing source code repositories
ℹ️  Processing repository: optimism
ℹ️  Cloning repository from https://github.com/okx/optimism...
✅ Repository cloned
ℹ️  Checking out v1.9.0...
✅ Repository ready at commit: a1b2c3d
...
```

## Workflow Steps

### Step 1: Dependency Check
Validates all required tools are installed and Docker daemon is running.

### Step 2: User Input Collection
Collects configuration parameters with validation:
- Client type validation (reth/geth only)
- URL format validation (must be HTTP/HTTPS)

### Step 3: Repository Preparation
For each repository:
- **Existing repos:** Reset to clean state (`git reset --hard`, `git clean -fdx`)
- **New repos:** Clone from GitHub
- Checkout specified branch/tag
- Pull latest changes (if branch)
- Extract commit ID for image tagging

Repositories handled:
- `okx/optimism` (op-node)
- `okx/reth` (if reth client)
- `okx/op-geth` (if geth client)

### Step 4: Docker Image Building
Builds images with:
- `--no-cache` flag (ensures fresh build)
- Real-time progress display
- Full logs written to file

Build commands:
```bash
# op-node
docker build --no-cache -t op-stack:branch-commit -f Dockerfile-opstack .

# op-reth
docker build --no-cache -t op-reth:branch-commit -f DockerfileOp .

# op-geth
docker build --no-cache -t op-geth:branch-commit -f Dockerfile .
```

**Note:** Build time is typically 10-30 minutes per image.

### Step 5: Configuration Update
- Backs up `network-presets.env` (with timestamp)
- Updates mainnet image tags:
  - `MAINNET_OP_STACK_IMAGE`
  - `MAINNET_OP_RETH_IMAGE` or `MAINNET_OP_GETH_IMAGE`

### Step 6: Node Startup
- Checks port 8545 availability
- Runs `one-click-setup.sh` with automated inputs via `expect`
- Uses mainnet configuration
- Accepts default ports
- Handles data directory conflicts (auto-delete)
- 1-hour timeout protection

### Step 7: Sync Monitoring
Monitors sync progress every 30 seconds:
- Queries local node (`localhost:8545`)
- Queries mainnet node (`https://xlayerrpc.okx.com`)
- Displays: local height, mainnet height, difference, progress %
- Triggers verification when difference < 100 blocks

Example output:
```
ℹ️  Local: 8500123 | Mainnet: 8500145 | Diff: 22 | Progress: 99.98%
```

### Step 8: Block Verification
Verifies the last 5 blocks by comparing hashes:
- Fetches block hashes from local and mainnet
- Reports MATCH/MISMATCH for each block
- Provides diagnostic information on failure

## Output

### Success Case
```
✅ ✓ Block #8500145: MATCH
  Hash: 0xabc123...

✅ ✓ Block #8500144: MATCH
  Hash: 0xdef456...

========================================
Verification Result
========================================

✅ ALL BLOCKS MATCH!
✅ Your node is correctly synced with the mainnet

========================================
Replay Summary
========================================

ℹ️  Configuration:
ℹ️    Client Type: reth
ℹ️    Optimism: v1.9.0
ℹ️    Reth: op-reth/v1.1.0
ℹ️    L1 Endpoint: https://eth-mainnet.g.alchemy.com/v2/...

ℹ️  Docker Images:
ℹ️    op-stack:v1.9.0-a1b2c3d
ℹ️    op-reth:op-reth/v1.1.0-d4e5f6g

ℹ️  Log file: replay-2025-11-12-143022.log

✅ 🎉 REPLAY SUCCESSFUL!
```

### Failure Case
```
❌ ✗ Block #8500145: MISMATCH
  Local:   0xabc123...
  Mainnet: 0xdef456...

❌ BLOCK MISMATCH DETECTED!
❌ Found 1 mismatched block(s)
❌ Possible reasons:
❌   1. Node is still syncing
❌   2. Fork or consensus issue
❌   3. Configuration error

❌ REPLAY FAILED
```

## Log Files

All operations are logged to timestamped files:
```
replay-2025-11-12-143022.log
```

Log contents include:
- All command outputs
- Git operations
- Docker build logs
- RPC call responses
- Sync progress
- Verification results

## Directory Structure

After execution:
```
workspace/
├── replay-repos/              # Source code repositories
│   ├── optimism/
│   ├── reth/                  # or op-geth/
│   └── .git/
├── replay-YYYY-MM-DD-HHMMSS.log  # Detailed log
└── chaindata/                 # Created by one-click-setup
    └── mainnet-reth/          # or mainnet-geth/
        ├── config/
        ├── data/
        └── logs/
```

## Configuration Backup

Original configuration is backed up to:
```
scripts/rpc-setup/network-presets.env.backup-YYYYMMDD-HHMMSS
```

To restore original configuration:
```bash
cd scripts/rpc-setup
cp network-presets.env.backup-20251112-143022 network-presets.env
```

## Troubleshooting

### Port Already in Use
```
❌ Port 8545 is already in use
```
**Solution:** Stop existing service or choose different port
```bash
docker ps  # Find container
docker stop <container-id>
```

### Docker Build Failed
```
❌ Failed to build op-stack:v1.9.0-a1b2c3d
```
**Solution:** Check log file for build errors
```bash
tail -100 replay-YYYY-MM-DD-HHMMSS.log
```

Common causes:
- Insufficient disk space
- Network timeout
- Missing Dockerfile
- Build dependencies missing

### Cannot Connect to Local RPC
```
⚠️  Cannot connect to local RPC (attempt 3/5)
```
**Solution:** Check if node started successfully
```bash
docker ps  # Should see op-node and op-reth/op-geth containers
docker logs op-reth  # Check for errors
```

### Node Not Syncing
If sync progress is stuck at 0%:
1. Check L1 RPC URL is accessible
2. Verify L1 Beacon URL is accessible
3. Check Docker container logs
4. Ensure sufficient disk space

### Block Hash Mismatch
If blocks don't match mainnet:
1. Wait 5 minutes and check again (node may still be syncing)
2. Verify correct branch/tag was used
3. Check if there's a known fork
4. Review Docker build logs for issues

## Advanced Usage

### Custom Repository URLs
Edit script variables:
```bash
OPTIMISM_REPO="https://github.com/your-fork/optimism"
RETH_REPO="https://github.com/your-fork/reth"
OP_GETH_REPO="https://github.com/your-fork/op-geth"
```

### Skip Dependency Check
Comment out in main():
```bash
# check_dependencies
```

### Custom Sync Threshold
Modify in `monitor_sync_progress()`:
```bash
if [ $diff -lt 10 ] && [ $diff -ge 0 ]; then  # Changed from 100 to 10
```

### More Block Verification
Increase verification sample in `verify_block_consistency()`:
```bash
local blocks_to_check=20  # Changed from 5 to 20
```

## CI/CD Integration

### Non-Interactive Mode
To use in CI/CD, you'll need to modify the script to accept environment variables:
```bash
export CLIENT_TYPE=reth
export OPTIMISM_BRANCH=v1.9.0
export RETH_BRANCH=op-reth/v1.1.0
export L1_RPC_URL=https://...
export L1_BEACON_URL=https://...
```

Then update `get_user_input()` to read from env vars.

### Docker-in-Docker
When running in CI containers:
```yaml
services:
  - docker:dind

before_script:
  - apk add git curl jq expect
```

## Performance Considerations

### Build Time
- First run: 30-60 minutes (cloning + building)
- Subsequent runs: 20-40 minutes (building only)

### Disk Usage
- Source repos: ~5GB
- Docker images: ~10GB
- Chaindata: 30GB+ (grows over time)
- Logs: 100MB-1GB per run

### Network Usage
- Repository cloning: ~2GB
- Blockchain sync: 30GB+ (initial)
- Continuous sync: 1-5GB/day

## Best Practices

1. **Clean up old logs periodically**
   ```bash
   find . -name "replay-*.log" -mtime +7 -delete
   ```

2. **Monitor disk space**
   ```bash
   df -h
   ```

3. **Use persistent L1 RPC** - Free public endpoints may rate-limit

4. **Keep repositories** - Reusing `replay-repos/` saves download time

5. **Review logs on failure** - Detailed diagnostics in log file

6. **Backup configurations** - Keep original `network-presets.env`

## Related Tools

- **test-legacy-rpc.sh** - Test RPC endpoints (71 tests)
- **one-click-setup.sh** - Manual RPC node setup
- **gen-minimal-genesis.sh** - Generate minimal genesis files

## Support

For issues or questions:
1. Check log file for detailed errors
2. Review [one-click-setup documentation](../rpc-setup/README.md)
3. Open issue on GitHub with log excerpt

## Changelog

### v1.0.0 (2025-11-12)
- Initial release
- Support for reth and geth clients
- Automated build and verification
- Real-time progress monitoring
- Block consistency verification

