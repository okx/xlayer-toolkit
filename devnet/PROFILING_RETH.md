# Op-Reth Profiling Guide

This guide explains how to profile op-reth in the local development environment using `perf` for CPU profiling and flamegraph generation.

## Overview

The profiling setup uses [Linux perf](https://perf.wiki.kernel.org/) for CPU profiling with full debug symbol support. Profiles are visualized using interactive [flamegraphs](https://www.brendangregg.com/flamegraphs.html) that can be viewed in any web browser.

**Why perf?**
- ✅ Full function name symbolication (no hex addresses)
- ✅ Works offline without symbol servers
- ✅ Generates self-contained SVG flamegraphs
- ✅ Better integration with debug symbols
- ✅ Standard Linux profiling tool

## Prerequisites

- Docker and Docker Compose
- Op-reth source code (if building with profiling support)
- macOS, Linux, or Windows WSL2

## Quick Start

### 1. Enable Profiling in Configuration

Edit your `.env` file:

```bash
# Be sure to enable reth
SEQ_TYPE=reth

# Profiling configuration for op-reth
RETH_PROFILING_ENABLED=true
RETH_CPU_PROFILING=true

# To build reth (init.sh)
SKIP_OP_RETH_BUILD=false

# Depending on which service you want to capture perf.
SEQ_TYPE=reth
RPC_TYPE=reth

# Set your reth source directory (if building from source)
OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth
```

### 2. Build and Start the Environment

```bash
cd test
# This will build op-reth with debug symbols and perf pre-installed
./init.sh

# Start the environment
./0-all.sh
```

### 3. Collect a CPU Profile

```bash
# Profile for 60 seconds (default)
./scripts/profile-reth-perf.sh op-reth-seq 60

# Profile for 30 seconds
./scripts/profile-reth-perf.sh op-reth-seq 30
```

### 4. Generate and View Flamegraph

```bash
# Generate interactive flamegraph
./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP.script

# The SVG will open automatically in your browser
# Or manually open: open ./profiling/op-reth-seq/perf-TIMESTAMP.svg
```

## Detailed Usage

### Available Scripts

#### `profile-reth-perf.sh`

Captures a CPU profile using perf with full debug symbols.

```bash
./scripts/profile-reth-perf.sh [container_name] [duration_seconds]
```

**Examples:**
```bash
# Profile sequencer for 60 seconds
./scripts/profile-reth-perf.sh op-reth-seq 60

# Profile RPC node for 30 seconds
./scripts/profile-reth-perf.sh op-reth-rpc 30
```

**Output:**
- `./profiling/[container_name]/perf-TIMESTAMP.data` - Raw perf data
- `./profiling/[container_name]/perf-TIMESTAMP.script` - Symbolicated stack traces

#### `generate-flamegraph.sh`

Generates an interactive SVG flamegraph from perf data.

```bash
./scripts/generate-flamegraph.sh [container_name] [perf_script_file]
```

**Examples:**
```bash
# Generate flamegraph from perf script
./scripts/generate-flamegraph.sh op-reth-seq perf-20241117-143022.script

# The output will be: ./profiling/op-reth-seq/perf-20241117-143022.svg
```

**Flamegraph Features:**
- **Interactive**: Click to zoom, hover for details
- **Self-contained**: No external dependencies
- **Searchable**: Ctrl+F to find functions
- **Color-coded**: Visual distinction of code areas

### Building Op-Reth with Profiling Support

The profiling-enabled image includes:
- **Release optimizations** - Fast performance
- **Debug symbols (debuginfo=2)** - Full function names and line numbers
- **Frame pointers** - Accurate stack traces
- **Perf pre-installed** - Ready for CPU profiling

**Build command:**
```bash
# Set your reth source directory in .env or export it
export OP_RETH_LOCAL_DIRECTORY=/path/to/your/reth

# Build profiling-enabled image
./scripts/build-reth-with-profiling.sh
```

The build script creates a Docker image with:
```dockerfile
ENV RUSTFLAGS="-C force-frame-pointers=yes -C debuginfo=2"
RUN cargo build --bin op-reth --features "jemalloc asm-keccak" --release
```

## Analyzing Profiles

### Understanding Flamegraphs

Flamegraphs visualize where CPU time is spent:

- **Width** = CPU time (wider = more time spent)
- **Height** = Call stack depth (top = leaf functions, bottom = root)
- **Color** = Visual distinction (not meaningful for perf)

**Reading the graph:**
1. The bottom shows the entry point (usually `main` or thread start)
2. Each box above represents a function call
3. Wide boxes are CPU hotspots
4. Tall stacks show deep call chains

**Interactive features:**
- **Click** any box to zoom in and focus on that subtree
- **Hover** to see full function name and percentage
- **Search** (Ctrl+F) to highlight specific functions
- **Reset Zoom** to return to full view

### Common Profiling Scenarios

#### 1. Finding CPU Hotspots

1. Collect profile during active operation:
   ```bash
   ./scripts/profile-reth-perf.sh op-reth-seq 60
   ```
2. Generate flamegraph:
   ```bash
   ./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP.script
   ```
3. Look for wide boxes - these are your hotspots
4. Click to zoom and examine the call stack

#### 2. Analyzing Block Processing

1. Send transactions or wait for block activity
2. Profile during active processing:
   ```bash
   ./scripts/profile-reth-perf.sh op-reth-seq 30
   ```
3. Generate flamegraph and look for:
   - `reth_*` functions (Reth-specific code)
   - `tokio::*` functions (Async runtime)
   - Wide bars in execution/validation code

#### 3. Comparing Performance

```bash
# Before optimization
./scripts/profile-reth-perf.sh op-reth-seq 60
./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP1.script

# Make changes, restart

# After optimization
./scripts/profile-reth-perf.sh op-reth-seq 60
./scripts/generate-flamegraph.sh op-reth-seq perf-TIMESTAMP2.script

# Compare the two SVG files side-by-side
```

#### 4. Profiling Under Load

For meaningful profiles, op-reth should be actively processing:

```bash
# Terminal 1: Send transactions to generate load
cast send --rpc-url http://localhost:8123 ...

# Terminal 2: Profile during load
./scripts/profile-reth-perf.sh op-reth-seq 60
```

**Note:** Idle systems will show very few samples. Look for output like:
```
[ perf record: Captured and wrote 0.235 MB perf.data (1000+ samples) ]
```
More samples = better data.

## Profiling Data

### Storage

Profiles are stored in:
```
test/profiling/
├── op-reth-seq/
│   ├── perf-20241117-143022.data      # Raw perf data
│   ├── perf-20241117-143022.script    # Symbolicated output
│   ├── perf-20241117-143022.folded    # Folded stacks
│   ├── perf-20241117-143022.svg       # Flamegraph (view in browser)
│   └── ...
├── op-reth-rpc/
│   └── ...
└── FlameGraph/                         # Flamegraph tools (cloned once)
```

### File Sizes

Typical profile sizes:
- **perf.data**: 0.1-5 MB (raw perf data)
- **perf.script**: 1-50 MB (symbolicated stacks)
- **flamegraph SVG**: 10-200 KB (compressed, interactive)

### Cleanup

```bash
# Remove old profiles
rm -rf test/profiling/op-reth-seq/perf-*

# Keep only recent profiles (last 7 days)
find test/profiling -name "perf-*" -mtime +7 -delete

# Clean up FlameGraph tools (will be re-downloaded if needed)
rm -rf test/profiling/FlameGraph
```

## Configuration Options

### Docker Compose Settings

For profiling, the following capabilities are enabled in `docker-compose.yml`:

```yaml
privileged: true
cap_add:
  - SYS_ADMIN
  - SYS_PTRACE
security_opt:
  - seccomp=unconfined
```

These allow perf to access performance monitoring capabilities.

### Perf Sampling Rate

Default: 999 Hz (999 samples per second)

To change, edit `scripts/profile-reth-perf.sh`:
```bash
perf record -F 1000 -p $RETH_PID ...  # 1000 Hz
```

Higher rates = more detail but larger files.

## Platform-Specific Notes

### macOS (M1/M2/M3)

- ✅ Fully supported via Docker Desktop
- ✅ ARM64 native performance
- ✅ Perf works in Linux containers
- ✅ Flamegraphs viewable in Safari/Chrome
- ℹ️ Profiling happens inside the Linux container

### Linux

- ✅ Native support
- ✅ Best performance
- ✅ All profiling features available
- ✅ Direct access to perf

### Windows

- ✅ Supported via WSL2
- ℹ️ Use WSL2 Linux distribution
- ✅ Flamegraphs viewable in browser

## Troubleshooting

### "perf: command not found"

Perf should be pre-installed in the profiling image. Check:
```bash
docker exec op-reth-seq which perf
docker exec op-reth-seq perf --version
```

If missing, the container may not be using the profiling-enabled image.

### "Error: Could not find op-reth process"

Check if the container is running:
```bash
docker ps | grep reth
docker exec op-reth-seq pgrep -f "op-reth node"
```

### "Permission denied" errors

Ensure the container has profiling capabilities:
```bash
docker inspect op-reth-seq | grep -i privileged
```

Should show: `"Privileged": true`

### No function names (hex addresses)

This means debug symbols are missing. Verify:
```bash
docker exec op-reth-seq file /usr/local/bin/op-reth
```

Should show: `with debug_info, not stripped`

If symbols are missing, rebuild with:
```bash
./scripts/build-reth-with-profiling.sh
```

### Very few samples collected

Op-reth may be idle. Check CPU usage:
```bash
docker stats op-reth-seq
```

For better profiles:
1. Generate load (send transactions)
2. Profile during active block processing
3. Increase profiling duration (60-120 seconds)

### "addr2line: not found" warnings

These are non-critical warnings. Function names will still appear in the flamegraph. To fix:
```bash
# Add binutils to the Dockerfile if desired
RUN apt-get install -y binutils
```

### Flamegraph shows black bars

This was fixed in the latest version. If you still see black bars:
1. Regenerate with: `./scripts/generate-flamegraph.sh ...`
2. Check that perf.script has content: `head -50 ./profiling/op-reth-seq/perf-*.script`
3. Ensure op-reth was active during profiling

## Advanced Usage

### Custom Flamegraph Options

Edit `scripts/generate-flamegraph.sh` to customize:

```bash
flamegraph.pl \
    --title "Custom Title" \
    --width 2400 \            # Wider graph
    --fontsize 16 \           # Larger text
    --colors hot \            # Color scheme
    --inverted \              # Reverse (icicle graph)
    input.folded > output.svg
```

### Profiling Specific Operations

```bash
# Start profiling just before operation
./scripts/profile-reth-perf.sh op-reth-seq 30 &
PROF_PID=$!

# Trigger operation
cast send --rpc-url http://localhost:8123 ...

# Wait for profiling to complete
wait $PROF_PID

# Generate flamegraph
./scripts/generate-flamegraph.sh op-reth-seq perf-*.script
```

### Using perf report (Alternative View)

View in terminal using perf's built-in TUI:

```bash
# Copy perf.data to container (if not already there)
docker cp ./profiling/op-reth-seq/perf-TIMESTAMP.data op-reth-seq:/tmp/perf.data

# View interactive report
docker exec -it op-reth-seq perf report -i /tmp/perf.data

# Or generate text report
docker exec op-reth-seq perf report -i /tmp/perf.data --stdio
```

## Resources

- [Linux Perf](https://perf.wiki.kernel.org/)
- [Brendan Gregg's Flamegraphs](https://www.brendangregg.com/flamegraphs.html)
- [FlameGraph GitHub](https://github.com/brendangregg/FlameGraph)
- [Rust Performance Book](https://nnethercote.github.io/perf-book/profiling.html)
- [Reth Documentation](https://reth.rs)

## Support

For issues or questions:
1. Check container logs: `docker logs op-reth-seq`
2. Verify perf installation: `docker exec op-reth-seq perf --version`
3. Check debug symbols: `docker exec op-reth-seq file /usr/local/bin/op-reth`
4. Review this guide's troubleshooting section
5. Check [perf documentation](https://perf.wiki.kernel.org/)
