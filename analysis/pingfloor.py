#!/usr/bin/env python3
"""No-op callback floor: measure Reactive Network delivery latency for a trivial callback.

Reads PingDetected (Lasna) and PingDelivery (Unichain) events from the measurement-only
PingReactive/PingExecutor pair, recovers the origin block timestamp from Base Sepolia, and
reports the three legs the arb measurement uses:

    msg_sec      = lasnaTs - originTs    (origin swap -> Lasna reaction)
    callback_sec = destTs  - lasnaTs     (Lasna reaction -> destination delivery)
    e2e_sec      = destTs  - originTs

Usage: set BASE_RPC, UNI_RPC, LASNA_RPC in env (or .env), then `python3 analysis/pingfloor.py`.
Override addresses with PING_REACTIVE / PING_EXECUTOR / FROM blocks if redeployed.
"""
import json
import os
import statistics
import subprocess
import sys

ENV = {}
for line in (open(".env").read().splitlines() if os.path.exists(".env") else []):
    if "=" in line and not line.strip().startswith("#"):
        k, v = line.split("=", 1)
        ENV[k.strip()] = v.strip()


def env(name, default=None):
    v = os.environ.get(name, ENV.get(name, default))
    if v is None:
        sys.exit(f"missing env {name}")
    return v


BASE_RPC = env("BASE_RPC")
UNI_RPC = env("UNI_RPC")
LASNA_RPC = env("LASNA_RPC")
PING_REACTIVE = env("PING_REACTIVE", "0xf6b3cd0FA15d4eb29719e68489DAd8A645a8f202")
PING_EXECUTOR = env("PING_EXECUTOR", "0xf10502b11891a5188972917f3f25c6f469ff071c")
FROM_LASNA = env("FROM_LASNA", "9298890")
FROM_UNI = env("FROM_UNI", "68846100")

DET_TOPIC = "0x38242217e63ac6d555bc6b1126617da5e125f2f6c9b5a31f9b16ded2fcc19e6d"
DLV_TOPIC = "0xa98c423f3fa2fa1ed8bf960b9c40a5ea631177ac76347175a7091212f6a1d5ff"

_cache = {}


def cast(*args):
    out = subprocess.run(["cast", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"cast {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout.strip()


def block_ts(rpc, number):
    key = (rpc, number)
    if key not in _cache:
        _cache[key] = int(cast("block", str(number), "--field", "timestamp", "--rpc-url", rpc))
    return _cache[key]


def logs(address, topic, frm, rpc):
    raw = cast("logs", "--address", address, "--from-block", frm, topic, "--rpc-url", rpc, "--json")
    return json.loads(raw)


def words(hexdata):
    d = hexdata[2:]
    return [d[i:i + 64] for i in range(0, len(d), 64)]


def main():
    # PingDetected(uint256 indexed seq, uint256 originChainId, uint256 originBlockNumber,
    #              uint256 originTxHash, uint64 lasnaTs, uint256 destChainId)
    det = {}
    for e in logs(PING_REACTIVE, DET_TOPIC, FROM_LASNA, LASNA_RPC):
        w = words(e["data"])
        seq = int(e["topics"][1], 16)
        det[seq] = {"origin_block": int(w[1], 16), "lasnaTs": int(w[3], 16)}

    # PingDelivery(uint256 indexed seq, uint256 originBlockNumber, uint256 originTxHash,
    #               uint64 lasnaTs, uint64 destTs, uint256 gasLeftAtDelivery)
    rows = []
    for e in logs(PING_EXECUTOR, DLV_TOPIC, FROM_UNI, UNI_RPC):
        w = words(e["data"])
        seq = int(e["topics"][1], 16)
        origin_block = int(w[0], 16)
        lasnaTs = int(w[2], 16)
        destTs = int(w[3], 16)
        gas_left = int(w[4], 16)
        originTs = block_ts(BASE_RPC, origin_block)
        rows.append({
            "seq": seq,
            "origin_ts": originTs,
            "lasna_ts": lasnaTs,
            "dest_ts": destTs,
            "msg": lasnaTs - originTs,
            "callback": destTs - lasnaTs,
            "e2e": destTs - originTs,
            "gas_left": gas_left,
        })
    rows.sort(key=lambda r: r["seq"])

    print(f"{'seq':>3} {'origin':>12} {'lasna':>12} {'dest':>12} {'msg':>4} {'cb':>3} {'e2e':>4} {'gasL':>6}")
    for r in rows:
        print(f"{r['seq']:>3} {r['origin_ts']:>12} {r['lasna_ts']:>12} {r['dest_ts']:>12} "
              f"{r['msg']:>4} {r['callback']:>3} {r['e2e']:>4} {r['gas_left']:>6}")

    def summ(vals):
        return (f"median {statistics.median(vals):g}  "
                f"min {min(vals):g}  max {max(vals):g}  mean {statistics.mean(vals):.2f}")

    msg = [r["msg"] for r in rows]
    cb = [r["callback"] for r in rows]
    e2e = [r["e2e"] for r in rows]
    print(f"\nn={len(rows)}")
    print(f"msg leg      : {summ(msg)}")
    print(f"callback leg : {summ(cb)}")
    print(f"e2e          : {summ(e2e)}")
    print(f"gas left @ delivery: min {min(r['gas_left'] for r in rows)}  "
          f"median {statistics.median([r['gas_left'] for r in rows]):g}")
    assert all(r["msg"] + r["callback"] == r["e2e"] for r in rows), "msg+cb != e2e"
    print("msg + callback == e2e on all rows: OK")


if __name__ == "__main__":
    main()
