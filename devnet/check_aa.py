import json, urllib.request

RPC = "http://127.0.0.1:8124"
START = 8597344
END = 8597347

def call(method, params):
    data = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=data, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]

for n in range(START, END + 1):
    b = call("eth_getBlockByNumber", [hex(n), True])
    gas_used = int(b["gasUsed"], 16)
    gas_limit = int(b["gasLimit"], 16)
    txs = b["transactions"]
    aa = sum(1 for tx in txs if tx.get("type") == "0x7b")
    print(
        "block", n,
        "ts", int(b["timestamp"], 16),
        "txs", len(txs),
        "aa", aa,
        "gasUsed", gas_used,
        "gasLimit", gas_limit,
        "fill", f"{gas_used / gas_limit:.2%}",
    )