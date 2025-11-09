# Minimal Genesis Generator

Generate minimal XLayer genesis.json files by removing the `alloc` field from full genesis.

## Why?

**Problem**: Reth loads genesis on every startup, taking **~1 minute** because full genesis files are **huge** (over 1 GB):

**Solution**: This tool generates **minimal genesis** files (~1 KB) that can be embedded directly into Reth source code, reducing startup time from **1 minute to <1 second**.

### Use Cases
- **Embedded genesis**: Hardcode minimal genesis in Reth to eliminate loading time
- **Development**: Fast node initialization for testing
- **CI/CD**: Quick environment setup
- **Genesis constants extraction**: Generate Reth chain spec constants

## Usage

```bash
./gen-minimal-genesis.sh <network>
```

### Arguments

| Argument | Description | Options |
|----------|-------------|---------|
| `network` | Target network | `mainnet` or `testnet` |

### Examples

```bash
# Generate mainnet minimal genesis
./gen-minimal-genesis.sh mainnet

# Generate testnet minimal genesis
./gen-minimal-genesis.sh testnet
```

## How It Works

1. **Download** full genesis from OSS (cached locally)
2. **Extract** archive to get `merged.genesis.json`
3. **Update** genesis `number` field to `config.legacyXLayerBlock` value (migration cutoff block)
4. **Remove** `alloc` field (~99% size reduction)
5. **Verify** all other fields remain unchanged
6. **Output** minimal genesis ready for embedding

## Output Files

Generated files are placed in `genesis/` directory:

```
scripts/dev-utils/genesis/
├── xlayer_mainnet.json    # Mainnet minimal genesis
└── xlayer_testnet.json    # Testnet minimal genesis
```

## Features

### Caching
Downloaded archives and extracted JSON are cached in `.genesis_cache/`:
```
.genesis_cache/
├── mainnet.tar.gz         # Cached mainnet archive
├── mainnet.genesis.json   # Cached full genesis
├── testnet.tar.gz         # Cached testnet archive
└── testnet.genesis.json   # Cached full genesis
```

Clear cache: `rm -rf .genesis_cache`

### Verification
The script verifies that the minimal genesis matches the original (excluding `alloc`):
- All config fields preserved
- Block number correctly updated to cutoff point
- Genesis hash components unchanged

## Next Steps

After generating minimal genesis, extract genesis constants for Reth:

```bash
# 1. Generate minimal genesis
./gen-minimal-genesis.sh mainnet

# 2. Extract constants using the cached FULL genesis
op-reth --chain .genesis_cache/mainnet.genesis.json node --help 2>&1 | grep -A 10 'GENESIS CONSTANTS'

# 3. Embed minimal genesis in Reth source code
# src/xlayer_mainnet.rs
```

## Source URLs

Genesis files are downloaded from OKG CDN:

- **Mainnet**: `https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.mainnet.tar.gz`
- **Testnet**: `https://okg-pub-hk.oss-cn-hongkong.aliyuncs.com/cdn/chain/xlayer/snapshot/merged.genesis.json.tar.gz`

## Error Handling

The script handles:
- Network connectivity issues
- Invalid archives
- Missing JSON files
- Verification failures
- Disk space issues

All errors are clearly reported with troubleshooting hints.

## Requirements

- `bash` 4.0+
- `jq` (JSON processor)
- `wget` or `curl`
- `tar`
- Sufficient disk space (~500 MB for cache)
