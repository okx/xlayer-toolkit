#!/usr/bin/env python3
"""
patch-avg-stats.py — retroactively compute avg (arithmetic mean) for all 5 timing
intervals from saved .cl.log files and patch into the existing JSON sidecar.

Uses IDENTICAL parsing logic as bench-adventure.sh so values are consistent.

Usage:
    python3 bench/scripts/patch-avg-stats.py bench/runs/<session>/
    python3 bench/scripts/patch-avg-stats.py bench/runs/session-A/ bench/runs/session-B/
"""

import sys, re, json
from pathlib import Path

_ANSI = re.compile(r'\x1b\[[0-9;]*[mK]')
_NUM  = re.compile(r'^([\d.]+)(.+)$')

CLS = ["op-node", "kona-okx-baseline", "kona-okx-optimised", "base-cl"]

# ── unit → ms conversion (identical to bench-adventure.sh) ───────────────────
def to_ms(v):
    v = v.strip().rstrip(')')
    m = _NUM.match(v)
    if not m:
        return 0.0
    num, unit = float(m.group(1)), m.group(2)
    if 'ns' in unit:              return num / 1_000_000.0
    if 'µs' in unit or 'us' in unit: return num / 1000.0
    if 'ms' in unit:              return num
    if unit.startswith('s'):      return num * 1000.0
    return 0.0

# ── patterns (identical to bench-adventure.sh) ────────────────────────────────
pat_fcu_dur    = re.compile(r'\bfcu_duration=([\d.]+[a-zµ]+)')
pat_build_wait = re.compile(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)')
pat_total_wait = re.compile(r'\bsequencer_total_wait=([\d.]+[a-zµ]+)')

def mean(arr):
    return round(sum(arr) / len(arr), 3) if arr else None

# ── parse one .cl.log → {interval: [ms, ...]} ────────────────────────────────
def parse_log(logpath):
    timings = {k: [] for k in ("fcu_attrs", "build_wait", "total_wait",
                                "queue_wait", "attr_prep")}
    try:
        fh = open(logpath, errors='replace')
    except FileNotFoundError:
        return None, f"log file not found: {logpath}"

    for raw in fh:
        line = _ANSI.sub('', raw)

        # must be from the sequencer container
        if line.startswith('[seq] '):
            line = line[6:]
        else:
            continue

        # ── op-node: "FCU+attrs ok" carries all three fields on one line ──────
        if 'FCU+attrs ok' in line:
            m_fcu = pat_fcu_dur.search(line)
            m_bw  = pat_build_wait.search(line)
            m_tw  = pat_total_wait.search(line)
            if m_fcu: timings["fcu_attrs"].append(to_ms(m_fcu.group(1)))
            if m_bw:  timings["build_wait"].append(to_ms(m_bw.group(1)))
            if m_tw:  timings["total_wait"].append(to_ms(m_tw.group(1)))

        # ── kona / base-cl: "block build started" carries fcu_duration ────────
        elif 'block build started' in line:
            m_fcu = pat_fcu_dur.search(line)
            if m_fcu: timings["fcu_attrs"].append(to_ms(m_fcu.group(1)))

        # ── kona / base-cl: "build request completed" carries build+total ─────
        elif 'build request completed' in line:
            m_bw = pat_build_wait.search(line)
            m_tw = pat_total_wait.search(line)
            if m_bw: timings["build_wait"].append(to_ms(m_bw.group(1)))
            if m_tw: timings["total_wait"].append(to_ms(m_tw.group(1)))

    # ── derive queue_wait = build_wait − fcu_attrs (paired per block) ─────────
    n_pairs = min(len(timings["build_wait"]), len(timings["fcu_attrs"]))
    for bw, fa in zip(timings["build_wait"][:n_pairs], timings["fcu_attrs"][:n_pairs]):
        timings["queue_wait"].append(round(max(bw - fa, 0.0), 3))

    # ── derive attr_prep = total_wait − build_wait (paired per block) ─────────
    n_pairs2 = min(len(timings["total_wait"]), len(timings["build_wait"]))
    for tw, bw in zip(timings["total_wait"][:n_pairs2], timings["build_wait"][:n_pairs2]):
        timings["attr_prep"].append(round(max(tw - bw, 0.0), 3))

    # ── sanity: we expect ~120 events per interval ────────────────────────────
    counts = {k: len(v) for k, v in timings.items() if v}
    return timings, counts

# ── patch avg fields into JSON ────────────────────────────────────────────────
INTERVAL_MAP = {
    "attr_prep":  "cl_attr_prep_avg",
    "queue_wait": "cl_queue_wait_avg",
    "build_wait": "cl_build_wait_avg",
    "fcu_attrs":  "cl_fcu_attrs_avg",
    "total_wait": "cl_total_wait_avg",
}

def patch_session(session_dir):
    session_dir = Path(session_dir)
    if not session_dir.is_dir():
        print(f"❌ not a directory: {session_dir}")
        return False

    session_ok = True
    print(f"\n{'─'*60}")
    print(f"Session: {session_dir.name}")
    print(f"{'─'*60}")

    for cl in CLS:
        logpath  = session_dir / f"{cl}.cl.log"
        jsonpath = session_dir / f"{cl}.json"

        # ── check both files exist ────────────────────────────────────────────
        if not logpath.exists():
            print(f"  {cl}: ⚠️  .cl.log missing — skipping")
            session_ok = False
            continue
        if not jsonpath.exists():
            print(f"  {cl}: ⚠️  .json missing — skipping")
            session_ok = False
            continue

        # ── parse log ─────────────────────────────────────────────────────────
        timings, result = parse_log(logpath)
        if timings is None:
            print(f"  {cl}: ❌ parse error: {result}")
            session_ok = False
            continue

        counts = result  # {interval: count}

        # ── require build_wait present (primary signal) ───────────────────────
        if not timings["build_wait"]:
            print(f"  {cl}: ❌ no build_wait entries found in log — cannot patch")
            session_ok = False
            continue

        # ── load existing JSON ────────────────────────────────────────────────
        with open(jsonpath) as f:
            existing = json.load(f)

        # ── compute and inject avg fields ─────────────────────────────────────
        patched = {}
        for interval, json_key in INTERVAL_MAP.items():
            vals = timings[interval]
            avg  = mean(vals)
            existing[json_key] = avg
            patched[interval]  = (avg, len(vals))

        # ── write back ────────────────────────────────────────────────────────
        with open(jsonpath, 'w') as f:
            json.dump(existing, f, indent=2)

        # ── report ────────────────────────────────────────────────────────────
        print(f"  {cl}: ✅ patched")
        for interval, (avg, n) in patched.items():
            flag = "" if avg is not None else " ⚠️ no data"
            avg_str = f"{avg:.2f} ms" if avg is not None else "None"
            print(f"    {interval:12s}  avg={avg_str:12s}  n={n}{flag}")

    return session_ok

# ── main ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: patch-avg-stats.py <run_dir> [<run_dir> ...]")
        sys.exit(1)

    all_ok = True
    for d in sys.argv[1:]:
        ok = patch_session(d)
        all_ok = all_ok and ok

    print()
    if all_ok:
        print("✅ All sessions patched cleanly.")
    else:
        print("⚠️  Some CLs had issues — check output above.")
    sys.exit(0 if all_ok else 1)
