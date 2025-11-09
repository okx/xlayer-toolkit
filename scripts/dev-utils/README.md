# XLayer Development Utilities

Development and testing utilities for XLayer.

## Available Tools

| Tool | Description | Documentation |
|------|-------------|---------------|
| `gen-minimal-genesis.sh` | Minimal genesis generator | [genesis-generator.md](./genesis-generator.md) |

## Quick Start

```bash
cd scripts/dev-utils

# Generate minimal genesis
./gen-minimal-genesis.sh mainnet
```

## Contributing

When adding new utilities:
1. Place script in `scripts/dev-utils/`
2. Use kebab-case naming
3. Create a separate `.md` documentation file
4. Add entry to the table above
