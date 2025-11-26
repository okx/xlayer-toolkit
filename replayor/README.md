### Replayor

This is a very rough, very WIP tool for replaying blocks on an op-stack network and outputting engine API timing information.

It uses a fork of [op-geth](https://github.com/ethereum-optimism/op-geth/compare/optimism...danyalprout:op-geth:danyal-wip?expand=1) which contains a hack to drop individual failed transactions from the block, instead of the whole block. This is necessary for replaying blocks with different parameters as some of the original transactions may fail due to the change in parameters.

### Configuration

The project uses environment-based configuration for flexible deployment. Each component has its own configuration file:

- **reth.env** - Configuration for Reth execution client
- **geth.env** - Configuration for Geth execution client  
- **replayor.env** - Configuration for the replayor tool

Example configuration files are provided with `.example` extension. To set up:

```bash
# Copy example configs and customize for your environment
cp reth.env.example reth.env
cp geth.env.example geth.env
cp replayor.env.example replayor.env

# Edit the configuration files
vim reth.env
vim geth.env
vim replayor.env
```

Key configuration options:
- Binary paths (e.g., `RETH_BINARY`, `GETH_BINARY`)
- Data directories
- Chain/rollup configuration files
- JWT secrets for authenticated RPC
- Network ports (HTTP, WS, AuthRPC, P2P)
- API modules and verbosity levels

### Run a test

```bash
# Initialize the engine jwt
make init

# Copy a snapshot which you want to test on top of
# note you can run this without a snapshot from genesis, but it's less effective for testing
cp /path/to/snapshot /path/to/replayor/geth-data-archive

# Configure your environment files (see Configuration section above)
vim reth.env
vim geth.env
vim replayor.env

# Or configure test parameters in test-configs directory
vim test-configs/my-test.env

# Update the components to use this test information
# by changing the env_file properties in the docker-compose.yml
vim docker-compose.yml

# Run the test
make run

# Or run individual components directly
./reth.sh      # Start Reth node
./geth.sh      # Start Geth node
./replayor.sh  # Run replayor tool

# If using local file system for results, you can view them in the results/ directory
```

### Running Scripts Directly

Each script can be run independently and will load configuration from its corresponding `.env` file:

```bash
# Run with default config (loads reth.env)
./reth.sh

# Run with custom config file
ENV_FILE=./test-configs/my-reth.env ./reth.sh

# Same for other scripts
./geth.sh
./replayor.sh
```

### Database Management

Initialize a new Reth database:

```bash
# Initialize Reth database (uses reth.env config)
./op-reth-init.sh

# Or with custom config
ENV_FILE=./test-configs/my-reth.env ./op-reth-init.sh
```

Unwind the Reth database to a specific block:

```bash
# Unwind to a specific block (uses reth.env config)
./unwind.sh 8594000

# Or set the target block in environment
UNWIND_TO_BLOCK=8594000 ./unwind.sh

# Or configure in reth.env and run without arguments
# (will use UNWIND_TO_BLOCK from reth.env, or default to 8594000)
./unwind.sh
```