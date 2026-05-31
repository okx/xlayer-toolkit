#!/usr/bin/env python3
"""Measure actual gasUsed per EIP-8130 AA transaction for several aa-bench configs.

For each configuration we:
  1. snapshot the current head on the sequencer RPC
  2. spawn `adventure aa-bench ...`, let it warm up, then sample for N seconds
  3. kill the bench and collect block receipts in the sampled range
  4. average gasUsed across receipts of type 0x7b (EIP-8130 AA)
"""

import json
import os
import signal
import statistics
import subprocess
import sys
import time
import urllib.request

RPC = "http://127.0.0.1:8123"
ADVENTURE = "/home/po/go/bin/adventure"
WORKDIR = "/home/po/now/xlayer-toolkit/tools/adventure"
CONFIG = "./testdata/config.json"

WARMUP_SECS = 8     # let the bench ramp before sampling
WINDOW_SECS = 20    # capture window
SETTLE_SECS = 8     # pause between configs so pools/mempool drain
EDGE_BLOCKS = 1     # trim 1 block off each end of the sampled range

ERC20_SECP = "0x4a3928405B6F0207c4659ADE27c1594A5F14F5A1"
ERC20_P256 = "0x08324Ca4d2368fB96f377fdff529C72d284342d4"


def _aa(args, extra=None):
    cmd = [ADVENTURE, "aa-bench", "-f", CONFIG, "--noncekey", "0"]
    cmd += args
    if extra:
        cmd += extra
    return cmd


CONFIGS = [
    ("secp/native/sender",  _aa(["--sig", "secp", "--tx", "native", "--payer", "sender"])),
    ("secp/native/random",  _aa(["--sig", "secp", "--tx", "native", "--payer", "random"])),
    ("secp/erc20/sender",   _aa(["--sig", "secp", "--tx", "erc20",  "--payer", "sender", "--contract", ERC20_SECP])),
    ("secp/erc20/random",   _aa(["--sig", "secp", "--tx", "erc20",  "--payer", "random", "--contract", ERC20_SECP])),
    ("p256/native/sender",  _aa(["--sig", "p256", "--tx", "native", "--payer", "sender"])),
    ("p256/native/random",  _aa(["--sig", "p256", "--tx", "native", "--payer", "random"])),
    ("p256/erc20/sender",   _aa(["--sig", "p256", "--tx", "erc20",  "--payer", "sender", "--contract", ERC20_P256])),
    ("p256/erc20/random",   _aa(["--sig", "p256", "--tx", "erc20",  "--payer", "random", "--contract", ERC20_P256])),
]


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]


def latest_block():
    return int(rpc("eth_blockNumber", []), 16)


def block_receipts(n):
    return rpc("eth_getBlockReceipts", [hex(n)])


def kill_bench(proc):
    try:
        os.killpg(proc.pid, signal.SIGINT)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def measure(label, cmd):
    log_path = f"/tmp/aa_gas_{label.replace('/', '_')}.log"
    print(f"== {label} ==", flush=True)
    print(f"  cmd: {' '.join(cmd)}", flush=True)
    print(f"  log: {log_path}", flush=True)
    with open(log_path, "w") as fout:
        proc = subprocess.Popen(
            cmd,
            cwd=WORKDIR,
            stdout=fout,
            stderr=subprocess.STDOUT,
            preexec_fn=os.setsid,
        )
    start_block = end_block = None
    try:
        time.sleep(WARMUP_SECS)
        start_block = latest_block()
        t0 = time.time()
        time.sleep(WINDOW_SECS)
        end_block = latest_block()
        elapsed = time.time() - t0
    finally:
        kill_bench(proc)

    lo = start_block + EDGE_BLOCKS
    hi = end_block - EDGE_BLOCKS
    if hi < lo:
        print(f"  too few blocks in window: {start_block}..{end_block}")
        return None

    gases = []
    block_summaries = []
    for n in range(lo, hi + 1):
        try:
            recs = block_receipts(n)
        except Exception as e:
            print(f"  block {n}: receipts error {e}")
            continue
        block_total = 0
        block_aa = 0
        block_gas_used = 0
        for r in recs or []:
            block_total += 1
            g = int(r["gasUsed"], 16)
            block_gas_used += g
            if r.get("type") == "0x7b":
                block_aa += 1
                gases.append(g)
        block_summaries.append((n, block_total, block_aa, block_gas_used))

    aa_count = len(gases)
    if aa_count == 0:
        print(f"  no AA receipts captured in [{lo}..{hi}]")
        return None

    avg = sum(gases) / aa_count
    med = statistics.median(gases)
    p90 = sorted(gases)[int(aa_count * 0.9) - 1] if aa_count >= 10 else max(gases)
    blk_min = min(g for _, _, aa, g in block_summaries if aa)
    blk_max = max(g for _, _, aa, g in block_summaries if aa)
    blocks_with_aa = sum(1 for _, _, aa, _ in block_summaries if aa)
    print(
        f"  blocks {lo}..{hi} ({hi - lo + 1}), with_aa={blocks_with_aa}, "
        f"aa_txs={aa_count}, elapsed={elapsed:.1f}s"
    )
    print(f"  per-AA-tx gas: avg={avg:.0f} median={med:.0f} p90={p90} min={min(gases)} max={max(gases)}")
    print(f"  block.gasUsed (AA blocks): min={blk_min} max={blk_max}")
    return {
        "label": label,
        "range": (lo, hi),
        "blocks_with_aa": blocks_with_aa,
        "aa_txs": aa_count,
        "avg": avg,
        "median": med,
        "p90": p90,
        "min": min(gases),
        "max": max(gases),
    }


def main():
    results = []
    for label, cmd in CONFIGS:
        try:
            r = measure(label, cmd)
        except KeyboardInterrupt:
            print("interrupted; stopping")
            break
        except Exception as e:
            print(f"  ERROR: {e}")
            r = None
        if r is not None:
            results.append(r)
        time.sleep(SETTLE_SECS)

    print("\n=== summary ===")
    header = f"{'config':28s} {'blocks':>7s} {'aa_txs':>8s} {'avg':>8s} {'median':>8s} {'p90':>8s} {'min':>8s} {'max':>8s}"
    print(header)
    for r in results:
        print(
            f"{r['label']:28s} {r['blocks_with_aa']:7d} {r['aa_txs']:8d} "
            f"{r['avg']:8.0f} {r['median']:8.0f} {r['p90']:8.0f} {r['min']:8.0f} {r['max']:8.0f}"
        )


if __name__ == "__main__":
    sys.exit(main())
