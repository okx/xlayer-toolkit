# XLayer Development Utilities

Development and testing utilities for XLayer.

## Available Tools

| Tool | Description | Documentation |
|------|-------------|---------------|
| `test-legacy-rpc.sh` | Legacy RPC testing (71 tests) | [legacy-rpc.md](./legacy-rpc.md) |
| `gen-minimal-genesis.sh` | Minimal genesis generator | [gen-minimal-genesis.md](./gen-minimal-genesis.md) |

## Quick Start

```bash
cd scripts/dev-utils

# Test Legacy RPC
./test-legacy-rpc.sh [rpc_url]

# Generate minimal genesis
./gen-minimal-genesis.sh mainnet
```

## Contributing

When adding new utilities:
1. Place script in `scripts/dev-utils/`
2. Use kebab-case naming
3. Create a separate `.md` documentation file
4. Add entry to the table above
