# Optimism Test Environment Setup Guide

## Environment Configuration

Configure `example.env` (do not modify `.env` directly) and run `./clean.sh` to sync changes.

| Case | .env Configuration |
|------|---------------------|
| **Geth as Sequencer** | `SEQ_TYPE=geth`<br>`SKIP_OP_RETH_BUILD=true`<br>`DB_ENGINE=pebble` |
| **Reth as Sequencer** | `SEQ_TYPE=reth`<br>`SKIP_OP_RETH_BUILD=false`<br>`OP_RETH_LOCAL_DIRECTORY=/absolute/path/to/reth/repository`<br>`OP_RETH_BRANCH=dev` |
| **Geth as RPC** | `RPC_TYPE=geth`<br>`LAUNCH_RPC_NODE=true`<br>`SKIP_OP_RETH_BUILD=true`<br>`DB_ENGINE=pebble` |
| **Reth as RPC** | `RPC_TYPE=reth`<br>`LAUNCH_RPC_NODE=true`<br>`SKIP_OP_RETH_BUILD=false`<br>`OP_RETH_LOCAL_DIRECTORY=/absolute/path/to/reth/repository`<br>`OP_RETH_BRANCH=dev` |
| **OP-Succinct Enabled** | `OP_SUCCINCT_ENABLE=true`<br>`OP_SUCCINCT_MOCK_MODE=true` (optional, for testing)<br>`OP_SUCCINCT_FAST_FINALITY_MODE=true` (optional, skip challenger) |
| **Kailua Enabled** | `KAILUA_ENABLE=true`<br> `OWNER_TYPE=safe`<br> `KAILUA_MOCK_MODE=true` (optional, use RISC0_DEV_MODE)<br>`KAILUA_FAST_FINALITY_MODE=true` (optional, enable validity proofs) |
| **RCS Enabled** | `SEQ_TYPE=reth`<br>`RCS_ENABLED=true`<br>`RCS_COUNT=1`<br>`RCS_LOCAL_DIRECTORY=/absolute/path/to/xlayer-rcs` |

**Notes:**
- Always modify `example.env`, then run `./clean.sh` to sync to `.env`
- Run `./init.sh` to build Docker images after configuration changes. By default, Docker images are not build locally.
- `DB_ENGINE` can be `pebble` or `leveldb` (only required for Geth)

## Prerequisites

### System Requirements
- Docker 20.10.0 or higher
- Docker Compose
- At least 32GB RAM
- At least 32GB available disk space

> **Important**: If you encounter performance issues, increase Docker engine memory limit to over 32GB
> ![issue](./images/stuck.png)
> ![solution](./images/docker.png)

### Initial Setup (First Time Only)
1. Run `./init.sh` or `./init-parallel.sh` to build Docker images locally. By default, Docker images are not built locally. You need to set the following variables to ``true`` in `example.env` and set the corresponding paths to build Docker images locally:
```
OP_STACK_LOCAL_DIRECTORY=<path to a clone of https://github.com/okx/optimism>
OP_GETH_LOCAL_DIRECTORY=<path to a clone of https://github.com/okx/op-geth>
OP_RETH_LOCAL_DIRECTORY=<path to a clone of https://github.com/okx/reth>
OP_GETH_BRANCH=<default is dev>
OP_RETH_BRANCH=<default is dev>
SKIP_OP_STACK_BUILD=true
SKIP_OP_CONTRACTS_BUILD=true
SKIP_OP_GETH_BUILD=true
SKIP_OP_RETH_BUILD=true
```

> Important: `init.sh` should only be run once during initial setup. Re-run only if you need to rebuild Docker images after code changes.

### Code Updates and Image Rebuilding (Optional)
If you've updated the Optimism codebase and need to rebuild Docker images:

1. **Update image tags** in `example.env`:
   ```bash
   # Example: increment version numbers
   OP_GETH_IMAGE_TAG=op-geth:v1.101512.0-patch
   OP_STACK_IMAGE_TAG=op-stack:v1.13.5
   OP_CONTRACTS_IMAGE_TAG=op-contracts:v1.13.5
   ```

2. **Apply changes**:
   ```bash
   ./clean.sh  # This will update .env from example.env
   ```

3. **Rebuild images**:
   ```bash
   ./init.sh  # Rebuilds all Docker images

   # Or in parallel (add -v for verbose output)
   ./init-parallel.sh

   # Or rebuild specific images only (optional)
   source .env && cd .. && docker build -t ${OP_STACK_IMAGE_TAG} -f Dockerfile-opstack . && cd -
   ```

### Directory Structure
```
devnet/
├── 0-all.sh            # One-click deployment script
├── init.sh             # Initialization script
├── init-parallel.sh    # Parallel initialization script
├── clean.sh            # Environment cleanup script
├── 1-start-l1.sh       # L1 chain startup script
├── 2-deploy-op-contracts.sh  # Contract deployment script
├── 3-op-init.sh        # Environment initialization script
├── 4-op-start-service.sh    # Service startup script
├── 5-run-op-succinct.sh # OP-Succinct components setup script
├── 6-run-kailua.sh   # Kailua components setup script
├── docker-compose.yml  # Docker Compose configuration
├── Makefile            # Build automation
├── scripts/            # Utility scripts
│   ├── transfer-leader.sh      # Leader transfer script
│   ├── stop-leader-sequencer.sh # Sequencer stop script
│   ├── active-sequencer.sh      # Check active sequencer
│   ├── add-game-type.sh         # Add dispute game type
│   ├── add-peers.sh             # Add peer connections
│   ├── docker-install-start.sh # Docker installation helper
│   ├── gray-upgrade-simulation.sh # Gray upgrade simulation
│   ├── kill-rpc.sh              # Kill RPC node
│   ├── mempool-rebroadcaster-scheduler.sh # Compares and rebroadcasts missing txs between reth and geth
│   ├── replace-genesis.sh       # Replace genesis configuration
│   ├── setup-cgt-function.sh    # Setup CGT functions
│   ├── show-dev-accounts.sh     # Display dev accounts info
│   ├── start-rpc.sh             # Start RPC node
│   ├── stop-rpc.sh              # Stop RPC node
│   ├── test-cgt.sh              # Test CGT functionality
│   ├── generate-cluster.sh      # Generate the N-node conductor cluster (identities + docker-compose.cluster.yml)
│   ├── update-anchor-root.sh    # Update anchor root by creating and resolving a dispute game
│   └── kailua-test-fault.sh     # Kailua malicious challenge testing tool
├── config-op/          # Configuration directory
├── entrypoint/         # Container entrypoint scripts
├── l1-geth/            # L1 Geth configuration and data
├── saved-cannon-data/  # Pre-generated cannon/dispute game data
├── op-succinct/        # OP-Succinct configuration files
├── kailua/             # Kailua configuration files
├── contracts/          # Smart contracts
├── images/             # Documentation images
├── example.env         # Environment template
```

## Quick Start

### One-Click Deployment

```bash
make run
```

This command automatically:
- Cleans up previous deployment
- Builds Docker images
- Deploys complete environment

⚠️ **Important Notes**:

1. Configuration Management:
   - if `.env` file does NOT exist, it will be created from `example.env`, when call `./init.sh`
   - if `.env` file exists, it will NOT be overwritten

2. Environment Reset:
   - `clean.sh` will stop all containers
   - Clean all data directories

> Note: For first-time setup, we recommend following the step-by-step deployment process to better understand each component and troubleshoot any potential issues.

### Fast Verify Deployment
```bash
# Send test transaction
cast send 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955 \
  --value 1 \
  --gas-price 2000000000 \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  --rpc-url http://localhost:8223
```

### Step-by-Step Deployment
For more granular control or troubleshooting, follow the steps below.

## Deployment Process

### 1. L1 Environment Setup
Run `./1-start-l1.sh`:
- Starts a complete PoS L1 test chain (EL + CL)
- CL node handles blob data storage
- Automatically funds test accounts:
  - Batcher
  - Proposer
  - Challenger

### 2. Smart Contract Deployment
Run `./2-deploy-op-contracts.sh`:
- Deploys Transactor contract
- Deploys and initializes all Optimism L1 contracts
- Generates configuration files:
  - `rollup.json`: op-node configuration
  - `genesis.json`: L2 initial state

### 3. Environment Initialization
Run `./3-op-init.sh`:
- Initializes op-geth database
  - Sequencer node
  - RPC node
- Generates dispute game components:
  - Compiles op-program
  - Generates prestate files
  - Creates state proofs

### 4. Service Startup
Run `./4-op-start-service.sh`:
- Launches core services:
  - op-batcher: L2 transaction batch processing
  - op-proposer: L2 state submission
  - op-node: State sync and validation
  - op-geth: L2 execution engine
  - op-challenger: State validation
  - op-dispute-mon: Dispute monitoring
  - op-conductor: Sequencer HA management

### 5. OP-Succinct Setup (Optional)
Run `./5-run-op-succinct.sh`:
- Only runs if `OP_SUCCINCT_ENABLE=true` in `.env`
- Deploys OP-Succinct contracts (AccessManager, Verifier, FaultDisputeGame)
- Starts services:
  - op-succinct-proposer: ZK validity proof proposer
  - op-succinct-challenger: Optional challenger (disabled if `OP_SUCCINCT_FAST_FINALITY_MODE=true`)

### 5.1 Kailua Setup (Optional)
Run `./6-run-kailua.sh`:
- Only runs if `KAILUA_ENABLE=true` and `OWNER_TYPE=safe` in `.env`
- Deploys Kailua contracts via `kailua-cli fast-track` (RISC0-based ZK proofs)
- Starts services:
  - kailua-proposer: Proposes L2 state to L1
  - kailua-validator: Validates proposals and generates fault/validity proofs
- Test fault proofs: `./scripts/kailua-test-fault.sh` submits malicious proposals to verify dispute resolution

### 6. Conductor Management
The test environment can run a single sequencer or a conductor-managed sequencer cluster for
high availability (HA). `CONDUCTOR_ENABLED=false` is the default, so `SEQ_COUNT` is ignored and
the generated topology has one sequencer. HA requires at least two sequencers: the generator
rejects `CONDUCTOR_ENABLED=true` with `SEQ_COUNT=1`.

#### Consensus-layer topology compatibility

| Topology | `SEQ_CL=opnode` | `SEQ_CL=kona` |
|---|---:|---:|
| One Sequencer, no Conductor | Supported | Supported |
| Multiple Sequencers with Conductor | Supported | Rejected |

`RPC_CL=opnode` and `RPC_CL=kona` both support every node generated by
`RPC_COUNT`. Change `SEQ_COUNT`, `RPC_COUNT`, or either CL selection only after
running `clean.sh` so identities and generated Compose services are rebuilt.

`SEQ_CL=kona` is deliberately limited to the one-effective-sequencer,
non-Conductor topology; the generator rejects a Kona sequencer combined with
`CONDUCTOR_ENABLED=true`. `RPC_CL` is independent of `SEQ_CL`: all generated
RPC EL nodes are started before their selected op-node or Kona CL services.

#### Architecture
- **Cluster Type**: N-node Raft consensus cluster when `CONDUCTOR_ENABLED=true`
- **Active Sequencer**: Only runs on leader node
- **Failover**: Automatic when leader becomes unhealthy
- **High Availability**: Ensures continuous L2 block production

#### Configuration
Enable or disable conductor cluster in `example.env`:
```bash
# Enable HA mode with conductor cluster
CONDUCTOR_ENABLED=true

# Number of sequencer nodes in the cluster (ignored when CONDUCTOR_ENABLED=false)
SEQ_COUNT=3

# Disable HA, run single sequencer
CONDUCTOR_ENABLED=false

# Number of RPC nodes, independent of SEQ_COUNT (ignored when LAUNCH_RPC_NODE=false)
RPC_COUNT=1
```

The cluster (seq + RPC identities, ports, and `docker-compose.cluster.yml`) is generated fresh by `scripts/generate-cluster.sh` every time `3-op-init.sh` runs — changing `SEQ_COUNT`/`RPC_COUNT` requires a `./clean.sh` before the next `./0-all.sh` run. Each RPC node's EL/rollup layers connect to the **entire** seq cluster (not just one node); its flashblocks subscription pairs 1:1 with one seq node (round-robin by index when `RPC_COUNT > SEQ_COUNT`).

### 7. RCS Risk-Control Sidecars (Optional)

`RCS_ENABLED=false` is the default and preserves the existing devnet topology. When enabled,
the generator adds one TZMock service and `RCS_COUNT` RCS services. RCS requires Reth
sequencers, and `RCS_COUNT` must not exceed the effective sequencer count.

RCS instances are paired by index: RCS 1 filters sequencer 1, RCS 2 filters sequencer 2,
and so on. A paired RCS reads from RPC node N when that RPC exists; otherwise it reads from
sequencer N. Sequencers without a paired RCS keep the filter disabled. The bridge list in
every generated RCS configuration is copied directly from `RCS_KNOWN_BRIDGE_ADDRESSES`,
which must be a non-empty TOML array of quoted `0x` addresses.

```bash
RCS_ENABLED=true
RCS_COUNT=3
RCS_LOCAL_DIRECTORY=/absolute/path/to/xlayer-rcs
RCS_KNOWN_BRIDGE_ADDRESSES='["0x14dC79964da2C08b23698B3D3cc7Ca32193d9955"]'

# Set these to true only when the corresponding local image already exists.
SKIP_RCS_BUILD=false
SKIP_TZMOCK_BUILD=false
```

The generated host ports are `9500` for TZMock and `9195`, `9196`, ... for RCS. Runtime
configuration is written under `config-op/rcs/`, while independent SQLite data is written
under `data/rcs/`. Both are removed by `clean.sh`.

`FLASHBLOCK_ENABLED=true` requires the selected Sequencer EL to be Reth. It
also requires `RPC_TYPE=reth` when RPC nodes are actually launched; when the
effective RPC count is zero, an inactive stale `RPC_TYPE` value is ignored.

#### Network Ports
Each node's host-facing port starts with a preferred `base + index` value
(index starting at 1). A single protocol-aware allocator then skips static
Compose ports and every earlier generated allocation; TCP and UDP may share a
number, but two TCP or two UDP listeners may not. Consequently the formulas
below describe the normal defaults, while a collision can move a later service
to the next free in-range port:
- **Seq EL http** (`8122 + index`): Seq 1: 8123, Seq 2: 8124, Seq 3: 8125
- **RPC EL http** (`8222 + index`): RPC 1: 8223, RPC 2: 8224
- **Conductor RPC Port** (`8546 + index`): Node 1: 8547, Node 2: 8548, Node 3: 8549
- **Conductor Consensus Port** (`50049 + index`): Node 1: 50050, Node 2: 50051, Node 3: 50052
- **Seq op-node RPC** (`9544 + index`): Node 1: 9545, Node 2: 9546, Node 3: 9547
- **RPC op-node RPC** (`9644 + index`): RPC 1: 9645, RPC 2: 9646

Host-side scripts read two distinct L2 JSON-RPC endpoints from `.env` (generated
from `example.env`); they are separate settings and neither aliases the other:
- `L2_SEQ_URL` (default `http://localhost:8123`): the L2 **sequencer** entry.
  Flows that submit transactions or need immediate sequencer state — Gasless
  deploy/enable/upgrade, dispute-game / OP-Succinct / Kailua host-side L2 reads,
  and Custom Gas Token verification — target this URL. Override it to point at a
  non-default host or port.
- `L2_RPC_URL` (default `http://localhost:8223`): the normal L2 **RPC node**
  entry for general queries. Its default is unchanged.

The actual generated values are always in `config-op/cluster/cluster.env` after
`3-op-init.sh` has run. It includes the effective counts and CL selections,
service lists, `TRUSTED_PEERS`, and per-node `EL_HTTP_PORT_$i`,
`CONDUCTOR_RPC_PORT_$i`, `OPNODE_RPC_PORT_$i`, and `RPC_EL_HTTP_PORT_$i` values.
Use this file rather than reconstructing ports in tools or scripts:

```bash
source config-op/cluster/cluster.env
printf 'seq 1: EL=http://127.0.0.1:%s conductor=http://127.0.0.1:%s\n' \
  "$EL_HTTP_PORT_1" "$CONDUCTOR_RPC_PORT_1"
```

`scripts/test_flashblock_reorg.py` reads this inventory automatically. Its
defaults can be overridden with `FLASHBLOCK_REORG_WS_URLS` (comma- or
space-separated) and `FLASHBLOCK_REORG_RPC_URL`; set `CLUSTER_ENV_PATH` to use
another inventory. The nested op-geth test manager follows the same generated
EL ports and accepts `XLAYER_CLUSTER_ENV`, `XLAYER_L2_SEQ_URL`, and
`XLAYER_L2_RPC_URL` overrides.

For a conductor topology, pass those generated conductor/sequencer pairs to
the Flashblocks monitor as described in
[`tools/flashblocks-monitoring/README.md`](../tools/flashblocks-monitoring/README.md).

#### Trusted-peer topology

`TRUSTED_PEERS` is regenerated into both `.env` and `cluster.env`. It always
contains every generated sequencer enode. When `TRUSTED_NODES_ONLY=true`, it
also contains every generated RPC-node enode, and `3-op-init.sh` writes
`trusted_nodes_only = true` into both Reth TOMLs. This makes Reth restrict
peering to the generated trusted list. Discovery remains disabled in the Reth
entrypoints, so the generated trusted peers are still used for explicit
connectivity even when the restriction is `false`.

The generator also writes a node-specific Geth TOML and identity file. Geth
entrypoints consume the generated node key, so the advertised enode and the
running process have the same identity in Geth/Geth and mixed Reth/Geth
topologies. They add gasless and txpool flags only when the selected binary
advertises those flags.

Startup is deliberately phased: every selected EL container is created before
any EL is started, which ensures all strict-peer DNS names exist before a Reth
or Geth process attempts to connect. The sequencer ELs and CLs then become
ready, all conductor RPCs become ready and elect a leader, and the active
sequencer is activated and validated with bounded retries. Monitoring starts
next in the existing upstream order, followed by RPC ELs and their selected CLs;
the batcher and existing challenger flow remain later in the startup script.

#### Genesis TxBlacklist and Reth storage

During `3-op-init.sh`, `scripts/inject-txblacklist-genesis-alloc.sh` compiles
the test-only, owner-stripped TxBlacklist contract and injects its runtime bytecode into `genesis.json` at
`0xb1ac000000000000000000000000000000000001`, before `genesis-reth.json` is
derived. The address must remain aligned with the Rust devnet blacklist
constant; it lets the deposit-blacklist path query the same contract from
the devnet genesis block.

The injector accepts only that fixed address and uses the pinned Foundry
configuration with the solc version bundled in `OP_CONTRACTS_IMAGE_TAG`. Runtime bytecode is cached under
`.cache/txblacklist/`, keyed by the Solidity source, compiler configuration,
Docker image ID, and cache schema. A matching cache entry avoids recompilation;
`clean.sh` deliberately preserves this local, Git-ignored cache.

`RETH_STORAGE_V2` is a genesis-initialization choice, but it is conditional on
the selected Reth image. With `true`, the scripts use the image's default-v2
behavior rather than passing `--storage.v2=true`; on a supported image where
v2 is the default, this keeps the v2 layout (history indexes in RocksDB and
several data sets in static files), and `RETH_ROCKSDB_PATH` optionally supplies
its RocksDB path. It does not force v2 on an image with a different default.
With `false`, the scripts pass `--storage.v2=false` only when that image
advertises the option. Changing either storage setting for an existing datadir
requires a full re-sync.

#### Gasless behavior

`ENABLE_GASLESS=true` enables the Reth/geth mempool path for zero-price
transactions. For Reth, the generated sequencer and RPC commands also use the
configured mock-price percentile and pending lifetime when their binary
supports those options; the sequencer additionally uses the configured
per-block gas budget when supported. The entrypoint passes that block-budget
option to both Reth roles for a shared invocation contract, although only the
Sequencer actually builds blocks.

This is separate from `CONTRACT_ALLOW_GASLESS`. When that switch is `true`,
`0-all.sh` runs `scripts/enable-gasless.sh`, which deploys the runtime
GaslessWhitelist proxy and calls `setGaslessEnabled(true)`. On chain ID 195,
the proxy must be `0xA9092BC02e2000a3F8996D1991621E9A03Ef2dfE`, the address
compiled into op-reth's gasless hook. Its owner is
`GASLESS_WHITELIST_OWNER` (the funded `RICH_L1_PRIVATE_KEY` account by
default). Enabling the node flag alone does not deploy or enable that contract;
per-target or per-token rules must still be registered separately.

#### Health Monitoring
The conductor cluster monitors each node's:
- Sync status with L1
- P2P network connectivity
- Block production rate

When leader becomes unhealthy:
- Automatically transfers leadership
- Deactivates unhealthy sequencer
- Activates sequencer on new leader

#### Leadership Management
There are two ways to trigger leader transfer:

1. Using `transfer-leader.sh`:
```bash
# Auto transfer to any healthy node
./scripts/transfer-leader.sh

# Transfer to specific node (1 or 2 or 3)
./scripts/transfer-leader.sh 2
```

2. Force transfer by stopping leader's sequencer:
```bash
# Stops block production while keeping the container running
# Automatically triggers leader transfer after health check timeout
# Can be run multiple times to test different leadership scenarios
./scripts/stop-leader-sequencer.sh
```

This method simulates a sequencer failure scenario, enabling comprehensive testing of automatic failover mechanisms. Each execution stops the current leader's sequencer and triggers a transfer to another node, allowing you to test different leadership scenarios by running the script multiple times. The cluster maintains high availability through dynamic role switching - when a sequencer stops producing blocks, it transitions to follower status while another node assumes leadership. The system remains resilient as any follower can automatically promote to leader if the current leader encounters issues.

3. Gray upgrade using op-conductor:
```bash
# Emulate the whole gray upgrade process to achieve 0 downtime
./scripts/gray-upgrade-simulation.sh
# Meanwhile, open another terminal window to load test
polycli loadtest --rpc-url http://localhost:8223 \
  --private-key "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356" \
  --verbosity 700 --requests 50000  -c 1 --rate-limit -1
```

The `scripts/gray-upgrade-simulation.sh` script simulates a rolling upgrade process for the sequencer cluster managed by op-conductor. It upgrades a follower sequencer while keeping the leader running, then transfers leadership to the upgraded node. This approach ensures service continuity and validates the cluster's resilience during upgrades. The script resolves the selected sequencer EL and CL service names from `config-op/cluster/cluster.env`, so both Geth and Reth EL selections are supported. Gray upgrade, `transfer-leader.sh`, and `stop-leader-sequencer.sh` require a conductor-managed op-node topology and fail with a clear error for unsupported selections such as a single Sequencer or Kona.

## Utility Scripts

### Development Accounts Display Script

The `scripts/show-dev-accounts.sh` script displays all development accounts with their private keys:

#### Features
- **Account Listing**: Shows all 30 development accounts (paths 0-29)
- **Private Key Display**: Reveals private keys for testing
- **Address Generation**: Shows corresponding addresses
- **Mnemonic Path**: Displays derivation paths

#### Usage
```bash
# Display all dev accounts
./scripts/show-dev-accounts.sh
```

#### What it does
1. **Generates Accounts**: Creates 30 accounts from standard mnemonic (paths 0-29)
2. **Shows Details**: Displays address, private key, and derivation path
3. **Standard Mnemonic**: Uses "test test test test test test test test test test test junk"
4. **Path Format**: Uses `m/44'/60'/0'/0/{i}` derivation paths

#### Important Notes
- **Balance Status**: Most dev accounts are pre-funded with 10,000 ETH, but some accounts may have zero initial balance

### Mempool rebroadcaster scheduler

The `scripts/mempool-rebroadcaster-scheduler.sh` script facilitates running the mempool rebroadcaster tool periodically in a default 1 minute interval. Its Geth and Reth endpoints are generated from the selected sequencer and RPC services; a mixed topology may put either client in either role. A homogeneous topology has no cross-client pair and is rejected with a clear error.

### Usage

- The mempool rebroadcaster tool is crucial to ensure reth and geth transaction pool consistency.
- In production, the mempool-rebroadcaster should be running inside a scheduler or cron job.
- For our local devnet, we can deploy the tool inside the scheduler by running the script.

### Reth vs geth txpool

- There are slight differences in the txpool behaviour between opgeth and reth which thus the need for the tool.

||Geth|Reth|
|---------|------|------|
|Pending| Next nonce transactions with no nonce gap | Next nonce transactions with a fee higher than the base fee|
|Queued| Transactions with a nonce gap | Transactions below the base fee, even if they are next nonce, and transactions with a nonce gap|

## Testing

### End-to-end (e2e) Testing

#### 1. Geth

To run e2e tests for geth, first build op-stack using geth as the sequencer and rpc by setting the following environment variables
```
SEQ_TYPE=geth
RPC_TYPE=geth
DB_ENGINE="pebble"
```

After devnet is started, run the e2e test:
```
make run-geth-test
```

#### 2. Reth

To run e2e tests for reth, first build op-stack using reth as the sequencer and rpc and set the following environment variables
```
SEQ_TYPE=reth
RPC_TYPE=reth
FLASHBLOCK_ENABLED=true
```

After devnet is started, run the reth e2e test without benchmark and comparison tests (non-flashblock node not started):
```
make run-reth-test
```

To run the full reth e2e test suite for flashblocks (starts the non-flashblock node):
```
make run-reth-test-all
```

## Troubleshooting

### Common Issues

#### 1. Service Startup Failures
- **Check Docker logs**: `docker compose logs <service-name>`
- **Verify port availability**: Ensure ports 8545, 8546, 4000, 3500 are free
- **Validate environment variables**: Check `.env` file matches `example.env`
- **Memory issues**: Increase Docker memory limit to 32GB+

#### 2. Contract Deployment Issues
- **Verify L1 node is running**: Check `docker compose ps`
- **Check account balances**: Ensure test accounts have sufficient ETH
- **Validate gas settings**: Check gas limit and price in deployment logs

#### 3. Synchronization Issues
- **L2 not syncing**: Check op-geth-seq is running and producing blocks
- **RPC node issues**: Verify each `op-${RPC_TYPE}-rpc{N}` can connect to the seq cluster (check `--trusted-peers`/`--p2p.static` resolve, and that `RPC_COUNT`/`SEQ_COUNT` in `.env` match what's actually running)
- **Genesis mismatch**: Ensure rollup.json matches actual L2 genesis

#### 4. Conductor Cluster Issues
- **Leader election problems**: Check Raft consensus logs
- **Sequencer not switching**: Verify health check configuration
- **P2P connectivity**: Check network configuration and firewall

## Service Ports Overview

| Service | Port | Description |
|---------|------|-------------|
| **L1 Services** | | |
| l1-geth | 8545 | L1 Ethereum RPC |
| l1-geth | 8546 | L1 Ethereum WebSocket |
| l1-geth | 8551 | L1 Ethereum Engine API |
| l1-beacon-chain | 4000 | L1 Beacon RPC |
| l1-beacon-chain | 3500 | L1 Beacon HTTP |
| l1-beacon-chain | 18080 | L1 Beacon Metrics |
| **L2 Services** | | |
| op-reth-seq | 8123 | L2 Sequencer RPC (node 1; `8122+index` per node) |
| op-reth-seq | 7546 | L2 Sequencer WebSocket (node 1 only) |
| op-reth-seq | 8552 | L2 Sequencer Engine API (node 1 only) |
| op-reth-seq | 9002 | L2 Sequencer metrics (node 1 default; container port 9001) |
| op-reth-rpc | 8223 | L2 RPC Node RPC (node 1; `8222+index` per node) |
| op-seq | 9545 | L2 Node RPC (node 1; `9544+index` per node) |
| op-seq | 7070 | L2 Node P2P (node 1 only) |
| op-seq | 9223 | L2 Node P2P UDP (node 1; `9222+index` per node) |
| op-rpc | 9645 | L2 RPC Node RPC (node 1; `9644+index` per node) |
| **Conductor Cluster** | | |
| op-conductor | 8547 | Conductor 1 RPC |
| op-conductor | 50050 | Conductor 1 Consensus |
| op-conductor2 | 8548 | Conductor 2 RPC |
| op-conductor2 | 50051 | Conductor 2 Consensus |
| op-conductor3 | 8549 | Conductor 3 RPC |
| op-conductor3 | 50052 | Conductor 3 Consensus |
| **Other Services** | | |
| op-batcher | 8548 | Batcher RPC |
| op-proposer | 8560 | Proposer RPC |

## Profiling Documentation

| Guide | Description |
|-------|-------------|
| [Profiling Reth](../docs/PROFILING_RETH.md) | Main profiling guide for op-reth with CPU and memory profiling |
| [Off-CPU Profiling](../docs/OFFCPU_PROFILING.md) | Guide for profiling lock contention, I/O waits, and scheduler delays |
| [Memory Profiling](../docs/MEMORY_PROFILING.md) | Jemalloc heap profiling for memory leaks and allocation patterns |
| [Perf TUI Reference](../docs/PERF_TUI_REFERENCE.md) | Quick reference for perf report interactive commands |
