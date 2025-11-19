# XLayer Development Utilities

Development and testing utilities for XLayer.

## Available Tools

| Tool | Description | Documentation |
|------|-------------|---------------|
| `compare-legacy-rpc.sh` | Legacy RPC comparison testing (200+ tests) | [compare-legacy-rpc.md](./compare-legacy-rpc.md) |
| `gen-minimal-genesis.sh` | Minimal genesis generator | [gen-minimal-genesis.md](./gen-minimal-genesis.md) |

## Quick Start

```bash
cd scripts/dev-utils

# Compare Legacy RPC compatibility
./compare-legacy-rpc.sh [rpc_url]

# Generate minimal genesis
./gen-minimal-genesis.sh mainnet
```

## Contributing

When adding new utilities:
1. Place script in `scripts/dev-utils/`
2. Use kebab-case naming
3. Create a separate `.md` documentation file
4. Add entry to the table above
