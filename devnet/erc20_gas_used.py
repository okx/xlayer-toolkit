#!/usr/bin/env python3
"""Measure actual gasUsed per regular (non-AA) ERC20 transfer for erc20-bench."""

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
CONTRACT = "0x4a3928405B6F0207c4659ADE27c1594A5F14F5A1"

WARMUP_SECS = 8
WINDOW_SECS = 20
EDGE_BLOCKS = 1


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


def main():
    cmd = [ADVENTURE, "erc20-bench", "-f", CONFIG, "--contract", CONTRACT]
    log_path = "/tmp/erc20_gas.log"
    print(f"cmd: {' '.join(cmd)}")
    print(f"log: {log_path}")
    with open(log_path, "w") as fout:
        proc = subprocess.Popen(
            cmd, cwd=WORKDIR, stdout=fout, stderr=subprocess.STDOUT, preexec_fn=os.setsid
        )
    try:
        time.sleep(WARMUP_SECS)
        start_block = latest_block()
        t0 = time.time()
        time.sleep(WINDOW_SECS)
        end_block = latest_block()
        elapsed = time.time() - t0
    finally:
        try:
            os.killpg(proc.pid, signal.SIGINT)
            proc.wait(timeout=8)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()

    lo = start_block + EDGE_BLOCKS
    hi = end_block - EDGE_BLOCKS
    print(f"block range: {start_block}..{end_block} -> sampling {lo}..{hi} (elapsed={elapsed:.1f}s)")

    gases_by_type = {}
    erc20_gases = []
    block_summaries = []
    for n in range(lo, hi + 1):
        try:
            recs = block_receipts(n)
        except Exception as e:
            print(f"  block {n}: receipts error {e}")
            continue
        total = 0
        gas_total = 0
        for r in recs or []:
            total += 1
            t = r.get("type", "?")
            g = int(r["gasUsed"], 16)
            gas_total += g
            gases_by_type.setdefault(t, []).append(g)
            to = (r.get("to") or "").lower()
            if to == CONTRACT.lower() and t != "0x7e":
                erc20_gases.append(g)
        block_summaries.append((n, total, gas_total))

    print("\nper-type sample counts and avg gas:")
    for t, gs in sorted(gases_by_type.items()):
        avg = sum(gs) / len(gs)
        med = statistics.median(gs)
        print(f"  type={t}  n={len(gs):8d}  avg={avg:9.1f}  median={med:9.0f}  min={min(gs)}  max={max(gs)}")

    if erc20_gases:
        n = len(erc20_gases)
        avg = sum(erc20_gases) / n
        med = statistics.median(erc20_gases)
        p90 = sorted(erc20_gases)[int(n * 0.9) - 1] if n >= 10 else max(erc20_gases)
        print(f"\nERC20 transfers (to={CONTRACT}): n={n}, avg={avg:.1f}, median={med:.0f}, p90={p90}, min={min(erc20_gases)}, max={max(erc20_gases)}")
    else:
        print("\nno txs to the ERC20 contract found in window")

    print("\nblock totals:")
    for n, tx_count, gu in block_summaries:
        print(f"  block {n}: txs={tx_count} gasUsed={gu}")


if __name__ == "__main__":
    sys.exit(main())
