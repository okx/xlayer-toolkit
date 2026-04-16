#!/usr/bin/env python3
"""
repair-500m-stats.py — Re-parse 500M cl.log files restricted to measurement window.

Root cause: LOG_SINCE was set before init, capturing 13+ min of init/warm-up events.
This inflated n (985→2314 for kona-optimised) and contaminated max values.

Fix: filter each cl.log to timestamps within the measurement window from blocks.json,
then re-run the same PYDOCKER parsing logic and update the JSON sidecars.

Usage: python3 bench/scripts/repair-500m-stats.py <run_dir>
"""
import sys, re, json, os
from datetime import datetime, timezone

_ANSI = re.compile(r'\x1b\[[0-9;]*[mK]')
_TS   = re.compile(r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})')  # ISO timestamp prefix

_NUM  = re.compile(r'^([\d.]+)(.+)$')
def to_ms(v):
    v = v.strip().rstrip(')')
    m = _NUM.match(v)
    if not m: return 0.0
    num, unit = float(m.group(1)), m.group(2)
    if 'ns' in unit:  return num / 1_000_000.0
    if 'µs' in unit or 'us' in unit: return num / 1000.0
    if 'ms' in unit:  return num
    if unit == 's':   return num * 1000.0
    return 0.0

def pct(d, p):
    s = sorted(d)
    return s[min(int(len(s)*p/100), len(s)-1)] if s else 0

def stats(data):
    if not data: return None
    return dict(
        p50=round(pct(data,50),3), p95=round(pct(data,95),3),
        p99=round(pct(data,99),3), max=round(max(data),3),
        avg=round(sum(data)/len(data),3), n=len(data)
    )

pat_opnode_fcu_dur    = re.compile(r'\bfcu_duration=([\d.]+[a-zµ]+)')
pat_opnode_newpay_dur = re.compile(r'\binsert_time=([\d.]+[a-zµ]+)')
pat_kona_fcu_dur      = re.compile(r'\bfcu_duration=([\d.]+[a-zµ]+)')
pat_kona_insert_dur   = re.compile(r'\binsert_duration=([\d.]+[a-zµ]+)')
pat_kona_import_dur   = re.compile(r'\bblock_import_duration=([\d.]+[a-zµ]+)')
pat_kona_build_wait   = re.compile(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)')
pat_total_wait        = re.compile(r'\bsequencer_total_wait=([\d.]+[a-zµ]+)')
pat_reth_el           = re.compile(r'\belapsed=([\d.]+[a-zµ]+)')

def parse_log(logfile, window_start_ts, window_end_ts):
    """Parse logfile restricted to unix timestamp range [window_start_ts, window_end_ts+5]."""
    cl_timings = {k:[] for k in ["fcu","fcu_attrs","new_pay","block_import","build_wait","queue_wait","total_wait","attr_prep"]}
    reth_el    = {k:[] for k in ["fcu","fcu_attrs","new_pay"]}

    # Add 5s slack on each side to capture events that straddle block boundaries
    t_start = window_start_ts - 5
    t_end   = window_end_ts   + 5

    lines_total = lines_kept = 0
    try:
        fh = open(logfile, errors='replace')
    except Exception:
        return cl_timings, reth_el, 0, 0

    for raw in fh:
        lines_total += 1
        raw = _ANSI.sub('', raw)

        # Extract log line timestamp and filter to measurement window
        m_ts = _TS.search(raw)
        if m_ts:
            try:
                dt = datetime.strptime(m_ts.group(1), '%Y-%m-%dT%H:%M:%S')
                dt = dt.replace(tzinfo=timezone.utc)
                line_ts = dt.timestamp()
                if line_ts < t_start or line_ts > t_end:
                    continue
            except Exception:
                pass  # if we can't parse the timestamp, include the line

        lines_kept += 1

        if raw.startswith('[seq] '):
            src, line = 'seq', raw[6:]
        elif raw.startswith('[reth] '):
            src, line = 'reth', raw[7:]
        else:
            continue

        if src == 'reth' and 'engine' not in line: continue
        if 'engine_bridge' in line: continue

        if src == 'seq':
            if 'FCU+attrs ok' in line:
                m = pat_opnode_fcu_dur.search(line)
                if m: cl_timings["fcu_attrs"].append(to_ms(m.group(1)))
                m2 = re.search(r'\bsequencer_build_wait=([\d.]+[a-zµ]+)', line)
                if m2: cl_timings["build_wait"].append(to_ms(m2.group(1)))
                m3 = pat_total_wait.search(line)
                if m3: cl_timings["total_wait"].append(to_ms(m3.group(1)))
            elif 'FCU ok' in line and 'fcu_duration' in line:
                m = pat_opnode_fcu_dur.search(line)
                if m: cl_timings["fcu"].append(to_ms(m.group(1)))
            elif 'Inserted new L2 unsafe block' in line:
                m = pat_opnode_newpay_dur.search(line)
                if m: cl_timings["new_pay"].append(to_ms(m.group(1)))
            elif 'block build started' in line:
                m = pat_kona_fcu_dur.search(line)
                if m: cl_timings["fcu_attrs"].append(to_ms(m.group(1)))
            elif ('Updated safe head via L1 consolidation' in line or
                  'Updated safe head via follow safe' in line or
                  'Updated finalized head' in line):
                m = pat_kona_fcu_dur.search(line)
                if m: cl_timings["fcu"].append(to_ms(m.group(1)))
            elif 'Inserted new unsafe block' in line:
                m = pat_kona_insert_dur.search(line)
                if m: cl_timings["new_pay"].append(to_ms(m.group(1)))
            elif 'Built and imported new' in line:
                m = pat_kona_import_dur.search(line)
                if m: cl_timings["block_import"].append(to_ms(m.group(1)))
            elif 'build request completed' in line:
                m = pat_kona_build_wait.search(line)
                if m: cl_timings["build_wait"].append(to_ms(m.group(1)))
                m2 = pat_total_wait.search(line)
                if m2: cl_timings["total_wait"].append(to_ms(m2.group(1)))

        elif src == 'reth' and 'engine::tree' in line:
            m = pat_reth_el.search(line)
            if not m: continue
            ms = to_ms(m.group(1))
            if ms <= 0: continue
            if   'new_payload reth ok' in line:                      reth_el["new_pay"].append(ms)
            elif 'FCU reth ok' in line and 'attrs=true' in line:     reth_el["fcu_attrs"].append(ms)
            elif 'FCU reth ok' in line:                              reth_el["fcu"].append(ms)

    # Derive queue_wait and attr_prep
    for bw, fa in zip(cl_timings["build_wait"], cl_timings["fcu_attrs"]):
        cl_timings["queue_wait"].append(round(max(bw - fa, 0.0), 3))
    for tw, bw in zip(cl_timings["total_wait"], cl_timings["build_wait"]):
        cl_timings["attr_prep"].append(round(max(tw - bw, 0.0), 3))

    return cl_timings, reth_el, lines_total, lines_kept


def repair_cl(run_dir, cl_name):
    blocks_json = os.path.join(run_dir, f"{cl_name}.blocks.json")
    cl_log      = os.path.join(run_dir, f"{cl_name}.cl.log")
    json_sidecar = os.path.join(run_dir, f"{cl_name}.json")

    if not os.path.exists(blocks_json):
        print(f"  SKIP {cl_name}: no blocks.json")
        return None
    if not os.path.exists(cl_log):
        print(f"  SKIP {cl_name}: no cl.log")
        return None
    if not os.path.exists(json_sidecar):
        print(f"  SKIP {cl_name}: no json sidecar")
        return None

    with open(blocks_json) as f:
        bdata = json.load(f)
    blocks = bdata.get('blocks', [])
    if not blocks:
        print(f"  SKIP {cl_name}: empty blocks")
        return None

    window_start = blocks[0]['timestamp']
    window_end   = blocks[-1]['timestamp']

    cl_timings, reth_el, total, kept = parse_log(cl_log, window_start, window_end)

    result = {k: {c: stats(v) for c, v in d.items()}
              for k, d in {"cl": cl_timings, "reth": reth_el}.items()}

    # Update JSON sidecar — replace cl/reth sections only
    with open(json_sidecar) as f:
        sidecar = json.load(f)

    # Map new stats into sidecar keys
    def _s(key, sub='p99'):
        st = result['cl'].get(key)
        return st[sub] if st else None
    def _sr(key, sub='p50'):
        st = result['reth'].get(key)
        return st[sub] if st else None

    # Update all cl_* fields
    updates = {
        'cl_build_wait_p50':   _s('build_wait','p50'),
        'cl_build_wait_p99':   _s('build_wait','p99'),
        'cl_build_wait_max':   _s('build_wait','max'),
        'cl_build_wait_n':     result['cl']['build_wait']['n'] if result['cl'].get('build_wait') else None,
        'cl_fcu_attrs_p50':    _s('fcu_attrs','p50'),
        'cl_fcu_attrs_p99':    _s('fcu_attrs','p99'),
        'cl_fcu_attrs_max':    _s('fcu_attrs','max'),
        'cl_queue_wait_p50':   _s('queue_wait','p50'),
        'cl_queue_wait_p99':   _s('queue_wait','p99'),
        'cl_queue_wait_max':   _s('queue_wait','max'),
        'cl_total_wait_p50':   _s('total_wait','p50'),
        'cl_total_wait_p99':   _s('total_wait','p99'),
        'cl_total_wait_max':   _s('total_wait','max'),
        'cl_attr_prep_p50':    _s('attr_prep','p50'),
        'cl_attr_prep_p99':    _s('attr_prep','p99'),
        'cl_attr_prep_max':    _s('attr_prep','max'),
        'cl_fcu_p50':          _s('fcu','p50'),
        'cl_fcu_p99':          _s('fcu','p99'),
        'cl_fcu_max':          _s('fcu','max'),
        'cl_new_pay_p50':      _s('new_pay','p50'),
        'cl_new_pay_p99':      _s('new_pay','p99'),
        'cl_new_pay_max':      _s('new_pay','max'),
        'cl_block_import_p50': _s('block_import','p50'),
        'cl_block_import_p99': _s('block_import','p99'),
        'cl_block_import_max': _s('block_import','max'),
        'reth_fcu_attrs_p50':  _sr('fcu_attrs','p50'),
        'reth_fcu_attrs_p99':  _sr('fcu_attrs','p99'),
        'reth_new_pay_p50':    _sr('new_pay','p50'),
        'reth_new_pay_p99':    _sr('new_pay','p99'),
    }
    for k, v in updates.items():
        if v is not None:
            sidecar[k] = v

    with open(json_sidecar, 'w') as f:
        json.dump(sidecar, f, indent=2)

    n_build = result['cl']['build_wait']['n'] if result['cl'].get('build_wait') else 0
    print(f"  {cl_name}: lines {total}→{kept} kept, n_build={n_build}, "
          f"total_p99={_s('total_wait','p99')}ms max={_s('total_wait','max')}ms, "
          f"queue_max={_s('queue_wait','max')}ms")
    return result


def main():
    run_dir = sys.argv[1] if len(sys.argv) > 1 else \
        'bench/runs/adv-erc20-40w-120s-500Mgas-20260407_084500'

    print(f"Repairing: {run_dir}")
    CLs = ['op-node', 'kona-okx-baseline', 'kona-okx-optimised', 'base-cl']
    results = {}
    for cl in CLs:
        print(f"\n[{cl}]")
        r = repair_cl(run_dir, cl)
        if r: results[cl] = r

    print("\n=== Repaired Stats (measurement window only) ===")
    print(f"{'CL':<25} {'n_build':>8} {'total_p99':>12} {'total_max':>12} {'queue_max':>12}")
    print("-" * 75)
    for cl, r in results.items():
        bw = r['cl'].get('build_wait') or {}
        tw = r['cl'].get('total_wait') or {}
        qw = r['cl'].get('queue_wait') or {}
        print(f"{cl:<25} {bw.get('n',0):>8} {tw.get('p99','—'):>12} {tw.get('max','—'):>12} {qw.get('max','—'):>12}")

    print("\nDone. JSON sidecars updated. Re-run comparison generation if needed.")


if __name__ == '__main__':
    main()
