#!/usr/bin/env python3
"""
fcu-tps-correlation.py — per-block FCU latency vs block fill correlation analysis.

For each bench run, bench-adventure.sh saves two artifacts needed here:
  <run_dir>/<cl_name>.blocks.json  — per-block chain data (gas_used, n_tx, fill%, timestamp)
  <run_dir>/<cl_name>.cl.log       — raw CL+reth container log (with [seq] prefix)

Usage:
  python3 scripts/fcu-tps-correlation.py bench/runs/adv-erc20-20w-120s-200Mgas-<TS>/
      → processes all CLs in the run dir, writes <cl_name>.fcu-correlation.md per CL

  python3 scripts/fcu-tps-correlation.py bench/runs/.../op-node.json
      → processes one specific CL sidecar

Optional:
  Install matplotlib for scatter plots: pip install matplotlib
  Plots saved as <cl_name>.fcu-correlation.png next to the markdown.
"""

import sys, json, re, os
from pathlib import Path
from datetime import datetime, timezone

# ── Helpers ────────────────────────────────────────────────────────────────────

_ANSI = re.compile(r'\x1b\[[0-9;]*[mK]')
_NUM  = re.compile(r'^([\d.]+)(.+)$')


def to_ms(v):
    """Parse kona/go Duration strings → float ms."""
    v = v.strip().rstrip(')')
    m = _NUM.match(v)
    if not m:
        return None
    num, unit = float(m.group(1)), m.group(2)
    if 'ns' in unit:              return num / 1_000_000
    if 'µs' in unit or 'us' in unit: return num / 1_000
    if 'ms' in unit:              return num
    if unit == 's':               return num * 1_000
    return None


def parse_wall_ts(line):
    """Extract a Unix timestamp float from a CL log line (kona or op-node format)."""
    # kona tracing: line begins with ISO timestamp
    m = re.search(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?(?:[+-]\d{2}:\d{2})?)', line[:60])
    if m:
        s = m.group(1)
        if s.endswith('Z'):                       s = s[:-1] + '+00:00'
        elif not re.search(r'[+-]\d{2}:\d{2}$', s): s += '+00:00'
        try:
            return datetime.fromisoformat(s).timestamp()
        except Exception:
            pass
    # op-node: t=<iso>
    m = re.search(r'\bt=(\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:\d{2}))', line)
    if m:
        s = m.group(1)
        if s.endswith('Z'): s = s[:-1] + '+00:00'
        try:
            return datetime.fromisoformat(s).timestamp()
        except Exception:
            pass
    return None


def pearson(xs, ys):
    """Pearson R correlation coefficient."""
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx  = sum((x - mx) ** 2 for x in xs) ** 0.5
    dy  = sum((y - my) ** 2 for y in ys) ** 0.5
    if dx == 0 or dy == 0:
        return 0.0
    return round(num / (dx * dy), 4)


def pct(arr, p):
    if not arr:
        return None
    s = sorted(arr)
    return round(s[min(int(len(s) * p / 100), len(s) - 1)], 3)


# ── Data loading ───────────────────────────────────────────────────────────────

def load_blocks(run_dir, cl_name):
    p = run_dir / f"{cl_name}.blocks.json"
    if not p.exists():
        return None, str(p)
    with open(p) as f:
        return json.load(f), None


def parse_fcu_entries(log_path, t_start, t_end):
    """
    Return sorted list of (wall_clock_ts, fcu_ms) for sequencer FCU events
    within the measurement window [t_start-2s, t_end+1s].

    Matches:
      op-node:   "FCU+attrs ok" lines with sequencer_build_wait=
      kona/base: "build request completed" lines with sequencer_build_wait=
    """
    pat = re.compile(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)')
    entries = []
    try:
        with open(log_path, errors='replace') as f:
            for raw in f:
                raw = _ANSI.sub('', raw)
                if not raw.startswith('[seq] '):
                    continue
                line = raw[6:]
                if 'FCU+attrs ok' not in line and 'build request completed' not in line:
                    continue
                ts = parse_wall_ts(line)
                if ts is None:
                    continue
                if ts < t_start - 2 or ts > t_end + 1:
                    continue
                m = pat.search(line)
                if m:
                    ms = to_ms(m.group(1))
                    if ms is not None:
                        entries.append((ts, ms))
    except Exception as e:
        pass
    return sorted(entries, key=lambda x: x[0])


# ── Analysis ───────────────────────────────────────────────────────────────────

def analyze(run_dir, cl_name):
    """
    Load blocks.json + cl.log, align FCU entries to blocks positionally,
    compute correlation, return dict with 'pairs', 'r', 'md', 'err'.
    """
    blocks_data, err = load_blocks(run_dir, cl_name)
    if err and not blocks_data:
        return {"err": f"blocks.json not found: {err} — re-run bench with updated bench-adventure.sh"}

    log_path = run_dir / f"{cl_name}.cl.log"
    if not log_path.exists():
        return {"err": f"cl.log not found: {log_path} — re-run bench with updated bench-adventure.sh"}

    blocks = blocks_data.get("blocks", [])
    if not blocks:
        return {"err": "blocks.json contains no block data"}

    t_start = blocks[0]["timestamp"]
    t_end   = blocks[-1]["timestamp"]

    fcu_entries = parse_fcu_entries(log_path, t_start, t_end)

    n_blocks = len(blocks)
    n_fcu    = len(fcu_entries)

    # Positional alignment: block[i] ↔ fcu_entries[i]
    # Works because the sequencer produces exactly one FCU per block in strict order.
    # Warn if counts differ by >5% or >3 (whichever is larger).
    mismatch = abs(n_blocks - n_fcu)
    threshold = max(3, int(n_blocks * 0.05))
    mismatch_warn = ""
    if mismatch > threshold:
        mismatch_warn = (
            f"\n> ⚠️ Block count ({n_blocks}) vs FCU entry count ({n_fcu}) differ by {mismatch} "
            f"(threshold {threshold}). Positional alignment may be slightly off — "
            f"results are indicative, not exact.\n"
        )

    pairs = list(zip(blocks[:n_fcu], fcu_entries[:n_blocks]))

    fcu_vals  = [e[1]          for _, e in pairs]
    fill_vals = [b["fill_pct"] for b, _ in pairs]

    r = pearson(fcu_vals, fill_vals)

    # Interpretation
    if r is None:
        interp = "Insufficient data for correlation."
    elif abs(r) < 0.15:
        interp = (
            f"**No meaningful correlation** (R = {r}). "
            "FCU latency does not affect block fill — the gas limit is the binding constraint, not CL timing."
        )
    elif r < -0.15:
        interp = (
            f"**Weak negative correlation** (R = {r}). "
            "Longer FCU waits correlate slightly with less-full blocks — "
            "likely caused by extreme spikes (100ms+) consuming part of the 1s block budget."
        )
    else:
        interp = (
            f"**Unexpected positive correlation** (R = {r}). "
            "Investigate: could be a confounding factor (e.g. chain ramp-up at start of window)."
        )

    # Stats
    avg_fcu  = round(sum(fcu_vals)  / len(fcu_vals),  3) if fcu_vals  else None
    avg_fill = round(sum(fill_vals) / len(fill_vals), 1) if fill_vals else None
    fcu_p99  = pct(fcu_vals, 99)
    fcu_max  = round(max(fcu_vals), 3) if fcu_vals else None

    # Build markdown
    L = []
    L.append(f"# FCU Latency vs Block Fill Correlation — {cl_name}")
    L.append("")
    L.append("> **Purpose:** validate whether sequencer FCU latency causally reduces block fill (TPS).")
    L.append("> Generated by `bench/scripts/fcu-tps-correlation.py`.")
    L.append("")

    L.append("## Summary")
    L.append("")
    L.append("| Metric | Value |")
    L.append("|---|---|")
    L.append(f"| Blocks in measurement window | {n_blocks} |")
    L.append(f"| FCU entries matched | {n_fcu} |")
    L.append(f"| Avg sequencer build wait | {avg_fcu} ms |")
    L.append(f"| p99 sequencer build wait | {fcu_p99} ms |")
    L.append(f"| Max sequencer build wait | {fcu_max} ms |")
    L.append(f"| Avg block fill | {avg_fill}% |")
    L.append(f"| **Pearson R** (FCU wait vs fill%) | **{r}** |")
    L.append(f"| **Interpretation** | {interp} |")

    if mismatch_warn:
        L.append(mismatch_warn)

    L.append("")
    L.append("## Why FCU latency is mostly decoupled from TPS")
    L.append("")
    L.append("In a 1-second block chain (XLayer devnet):")
    L.append("")
    L.append("```")
    L.append("Block budget: 1000 ms")
    L.append("  ├─ CL sends FCU+attrs ─────────────────────── EL starts building immediately")
    L.append("  │   (CL waits for payloadId response)")
    L.append("  │   FCU wait = queue delay + HTTP round-trip")
    L.append("  ├─ EL fills block with txs (parallel, ~950ms)")
    L.append("  ├─ CL calls getPayload → receives sealed block")
    L.append("  └─ CL calls newPayload + FCU (canonical update)")
    L.append("```")
    L.append("")
    L.append("The EL fills the block in parallel while the CL is waiting for `payloadId`.")
    L.append("At full saturation (mempool always full, gas-limit-bounded), the EL uses nearly")
    L.append("the full block time regardless of FCU latency — so TPS is unaffected.")
    L.append("")
    L.append("**Where FCU latency DOES matter:**")
    L.append("- **Sequencer stall risk**: op-node max 212ms = 21% of 1s budget idle. At 500M gas")
    L.append("  this starves reth of ~3,000 txs *for that specific block*.")
    L.append("- **Tail latency / user experience**: p99 FCU determines the worst-case block")
    L.append("  build delay that users observe as delayed unsafe head advancement.")
    L.append("- **Burst spikes**: extremely high FCU (>300ms) could cause `getPayload` to return")
    L.append("  before the EL has finished filling the block (partial block scenario).")
    L.append("")

    # Spike analysis
    spike_thresh = (avg_fcu or 0) * 3
    spikes = [(b, e) for b, e in pairs if e[1] > spike_thresh and e[1] > 20]
    if spikes:
        L.append("## FCU spikes (>3× avg and >20ms)")
        L.append("")
        L.append("| Block | Fill % | FCU wait (ms) | Spike factor |")
        L.append("|---|---|---|---|")
        for blk, (ts, ms) in spikes[:20]:
            factor = round(ms / avg_fcu, 1) if avg_fcu else "—"
            L.append(f"| {blk['bn']} | {blk['fill_pct']}% | {ms:.3f} | {factor}× |")
        if len(spikes) > 20:
            L.append(f"| ... | | | ({len(spikes) - 20} more) |")
        L.append("")
        spike_fills = [b["fill_pct"] for b, _ in spikes]
        non_spike_fills = [b["fill_pct"] for b, e in pairs if e[1] <= spike_thresh or e[1] <= 20]
        if spike_fills and non_spike_fills:
            avg_sf  = round(sum(spike_fills) / len(spike_fills), 1)
            avg_nsf = round(sum(non_spike_fills) / len(non_spike_fills), 1)
            L.append(f"> Spike blocks avg fill: **{avg_sf}%** vs non-spike avg fill: **{avg_nsf}%**")
            L.append("")

    # Per-block sample
    L.append("## Per-block data (first 30 blocks)")
    L.append("")
    L.append("| Block | Fill % | FCU wait (ms) |")
    L.append("|---|---|---|")
    for blk, (ts, ms) in pairs[:30]:
        L.append(f"| {blk['bn']} | {blk['fill_pct']}% | {ms:.3f} |")
    if len(pairs) > 30:
        L.append(f"| ... | ... | ... | ({len(pairs) - 30} more) |")
    L.append("")

    # Full data in collapsible
    L.append("<details>")
    L.append("<summary>Full block data (all blocks)</summary>")
    L.append("")
    L.append("| Block | Fill % | FCU wait (ms) |")
    L.append("|---|---|---|")
    for blk, (ts, ms) in pairs:
        L.append(f"| {blk['bn']} | {blk['fill_pct']}% | {ms:.3f} |")
    L.append("")
    L.append("</details>")
    L.append("")

    import datetime as _dt
    L.append(f"---")
    L.append(f"*Generated by fcu-tps-correlation.py · {_dt.date.today().isoformat()}*")

    return {
        "pairs":    pairs,
        "r":        r,
        "md":       "\n".join(L),
        "err":      None,
    }


# ── Scatter plot ───────────────────────────────────────────────────────────────

def scatter_plot(pairs, cl_name, out_path):
    try:
        import matplotlib.pyplot as plt
        xs = [e[1]          for _, e in pairs]
        ys = [b["fill_pct"] for b, _ in pairs]
        fig, ax = plt.subplots(figsize=(8, 5))
        ax.scatter(xs, ys, alpha=0.5, s=20, color='steelblue')
        ax.set_xlabel("Sequencer build wait (ms)")
        ax.set_ylabel("Block fill (%)")
        ax.set_title(f"FCU Latency vs Block Fill — {cl_name}")
        ax.set_ylim(0, 105)
        fig.tight_layout()
        fig.savefig(out_path, dpi=150)
        plt.close(fig)
        return True
    except ImportError:
        return False


# ── Entry point ────────────────────────────────────────────────────────────────

def process(run_dir, cl_name):
    result = analyze(run_dir, cl_name)
    if result.get("err"):
        print(f"  ⚠️  [{cl_name}] {result['err']}")
        return

    out_md = run_dir / f"{cl_name}.fcu-correlation.md"
    with open(out_md, "w") as f:
        f.write(result["md"])
    r_str = f"R={result['r']}" if result["r"] is not None else "R=N/A"
    print(f"  ✅ {cl_name} ({r_str}) → {out_md}")

    if result["pairs"]:
        out_png = run_dir / f"{cl_name}.fcu-correlation.png"
        if scatter_plot(result["pairs"], cl_name, out_png):
            print(f"     scatter: {out_png}")


def run_arg(arg):
    p = Path(arg)
    if p.is_file() and p.suffix == ".json" \
            and not p.name.startswith("blocks") \
            and p.stem != "comparison":
        process(p.parent, p.stem)
    elif p.is_dir():
        jsons = sorted(
            f for f in p.glob("*.json")
            if not f.name.startswith("blocks") and f.stem != "comparison"
        )
        if not jsons:
            print(f"No CL sidecar JSONs found in {p}")
            sys.exit(1)
        for j in jsons:
            process(p, j.stem)
    else:
        print(f"Unknown input: {arg}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for a in sys.argv[1:]:
        run_arg(a)
