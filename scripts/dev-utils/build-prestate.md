# X Layer Prestate Build Scripts

## Background
Unified build script for X Layer prestate generation with:
## Files

- `build-prestate.sh` - Main build script
- `build-prestate.patch` - Makefile modifications for cross-platform support

## Usage

### 1. Copy Script

```bash
cp build-prestate.sh build-prestate.patch /path/to/optimism/
cd /path/to/optimism
git apply build-prestate.patch
chmod +x build-prestate.sh
```

### 3. Run Build

```bash
# Testnet
./build-prestate.sh testnet

# Mainnet
./build-prestate.sh mainnet
```

Output:
Generates: `xlayer-{network}-prestate-{chainid}-{timestamp}.tar.gz`

## Configuration
To modify network configs, edit the top of `build-prestate.sh`:

```bash
# Testnet
TESTNET_CHAIN_ID=1952
TESTNET_JOVIAN_TIME=1764327600

# Mainnet
MAINNET_CHAIN_ID=196
MAINNET_JOVIAN_TIME=1764691201
```
