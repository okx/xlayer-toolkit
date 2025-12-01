# Perf Report TUI Quick Reference

## Starting Perf Report with Different Views

### Basic View
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data
```

### By Function Hotspots (Flat View)
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data --sort=symbol --no-call-graph
```

### By Library/Binary
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data --sort=dso,symbol
```

### Caller View (Who Calls This?)
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data -g caller
```

### Callee View (What Does This Call?)
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data -g callee
```

### Filter to Significant Functions (>1% CPU)
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data --percent-limit=1.0
```

### Focus on Specific Function
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data --symbols=function_name
```

### Focus on Op-Reth Binary Only
```bash
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data --dso=/usr/local/bin/op-reth
```

## Interactive TUI Keyboard Shortcuts

### Navigation
| Key | Action |
|-----|--------|
| `↑/↓` or `j/k` | Move cursor up/down |
| `PgUp/PgDn` | Page up/down |
| `Home/End` | Jump to top/bottom |
| `Enter` | Expand/collapse call stack |
| `Tab` | Switch between panes |

### Analysis
| Key | Action |
|-----|--------|
| `a` | Annotate - view assembly/source code for selected function |
| `d` | Display assembly from different DSO/offset |
| `P` | Show parent function info |
| `h` | Show all available keyboard shortcuts |
| `o` | **Options menu** - change display settings interactively |

### Filtering & Search
| Key | Action |
|-----|--------|
| `/` | Search/filter by pattern (use `n` for next, `N` for previous) |
| `t` | Filter/switch to specific thread |
| `C` | Collapse all call chains |
| `E` | Expand all call chains |
| `z` | Toggle zeroing of excluded symbols |

### Display Options
| Key | Action |
|-----|--------|
| `s` | Change sort order |
| `v` | Toggle verbose mode (show more details) |
| `r` | Refresh the display |

### Other
| Key | Action |
|-----|--------|
| `q` | Quit |
| `?` | Help |

## Common Workflows

### 1. Find Top CPU Consumers (Flat View)
```bash
# Start with flat view, sorted by overhead
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data \
  --sort=overhead,symbol --no-call-graph --percent-limit=0.5
```
**Then in TUI:**
- Browse top functions
- Press `a` on interesting functions to see code

### 2. Understand Call Paths (Hierarchical)
```bash
# Start with default hierarchical view
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data -g
```
**Then in TUI:**
- Navigate to expensive functions
- Press `Enter` to expand call stacks
- Press `a` to see annotated code

### 3. Focus on Reth Code Only
```bash
# Filter to op-reth binary and Rust code
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data \
  --dso=/usr/local/bin/op-reth --sort=symbol
```
**Then in TUI:**
- Use `/` to search for specific modules (e.g., `/reth_executor`)
- Press `n` to jump to next match

### 4. Compare Functions Side-by-Side
```bash
# Use stdio output for grep-able format
docker exec op-reth-seq perf_5.10 report -i /profiling/perf-*.data \
  --stdio --sort=overhead,symbol --percent-limit=1.0 | less
```

### 5. Deep Dive with Annotation
```bash
# Start TUI
docker exec -it op-reth-seq perf_5.10 report -i /profiling/perf-*.data
```
**Then in TUI:**
1. Navigate to interesting function
2. Press `a` - see assembly with CPU % per instruction
3. Press `o` - toggle source code view (if available)
4. Use `j/k` to navigate, look for hot instructions

## Understanding the Display

### Columns in Default View
```
Children    Self    Command    Shared Object       Symbol
22.18%     0.00%   op-reth    [kernel.kallsyms]   [k] el0t_64_sync
```

- **Children**: CPU time in this function + all functions it calls
- **Self**: CPU time spent in this function alone
- **Command**: Process name
- **Shared Object**: Binary/library
- **Symbol**: Function name
  - `[k]` = kernel function
  - `[.]` = user-space function

### Reading Call Graphs
```
22.18%  function_a
  |
  |--15.59%--function_b
  |          function_c
  |
  |--5.98%--function_d
```
- Width (%) = CPU time
- Indentation = call depth
- `--XX%--` = percentage of parent's time

## Tips

1. **Start broad, drill down**: Begin with default view, then use filters
2. **Use `o` key liberally**: Opens interactive options menu
3. **Combine with grep**: Use `--stdio` for scriptable output
4. **Focus on "Self" column**: Shows actual CPU consumers (not just call stack)
5. **Filter noise**: Use `--percent-limit=1.0` to hide small functions
6. **Compare DSOs**: Use `--sort=dso,symbol` to see library breakdown
7. **Search is powerful**: `/` lets you filter interactively

## Text Mode Alternative

If TUI doesn't work, use stdio mode:
```bash
# Full report
docker exec op-reth-seq perf_5.10 report -i /profiling/perf-*.data --stdio

# Top 20 functions
docker exec op-reth-seq perf_5.10 report -i /profiling/perf-*.data --stdio -n 20

# Specific sort
docker exec op-reth-seq perf_5.10 report -i /profiling/perf-*.data --stdio \
  --sort=dso,symbol --percent-limit=1.0
```
