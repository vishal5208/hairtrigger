#!/usr/bin/env python3
"""Backfill the Lasna detection tx hash into data/rounds.csv as `detected_tx`.

A judge clicking a round needs the Lasna transaction that produced the
`GapDetected` log, alongside the origin swap tx and the two fill txs.

Note on how the hash is resolved: on Reactive Network the `react()` call is not
a transaction *to* the reactive contract. A single "reactive transaction" is
sent to the system contract (0x8888...8888), which then invokes `react()` on
each subscribed reactive. So the reactive address never appears as a tx `to`;
it only appears as the *emitter* of the log. We therefore resolve the hash
authoritatively from the `GapDetected` logs the reactive emitted, one per round,
and cross-check that each log's block number equals the CSV's `detected_block`.

Usage:
    python3 analysis/backfill_detected_tx.py [--csv data/rounds.csv] [--rpc URL]
"""
import argparse
import csv
import json
import os
import subprocess
import sys

REACTIVE = "0x882d7B0b7c4414a393374a00Dfe9D2Fe8De2b41D"
GAP_TOPIC0 = "0xd85e65d3de3362f05c886c71c486e9707dc32e32a296179db6862bd556b5bdfd"
CHUNK = 2000


def get_logs(rpc, lo, hi):
    """eth_getLogs for GapDetected from the reactive across [lo, hi], chunked."""
    out = []
    start = lo
    while start <= hi:
        end = min(start + CHUNK - 1, hi)
        flt = {
            "fromBlock": hex(start),
            "toBlock": hex(end),
            "address": REACTIVE,
            "topics": [GAP_TOPIC0],
        }
        res = subprocess.run(
            ["cast", "rpc", "eth_getLogs", json.dumps(flt), "--rpc-url", rpc],
            capture_output=True, text=True,
        )
        if res.returncode != 0:
            sys.exit(f"eth_getLogs failed {start}-{end}: {res.stderr.strip()}")
        out.extend(json.loads(res.stdout))
        start = end + 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="data/rounds.csv")
    ap.add_argument("--rpc", default=os.environ.get("LASNA_RPC", "https://lasna-rpc.rnk.dev/"))
    a = ap.parse_args()

    with open(a.csv) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit("empty csv")

    # round -> expected detected_block (both arm rows agree)
    block_of = {}
    for r in rows:
        rid = int(r["round_id"])
        blk = int(r["detected_block"]) if r["detected_block"] else None
        if blk is not None:
            block_of.setdefault(rid, blk)
    lo, hi = min(block_of.values()), max(block_of.values())
    print(f"resolving {len(block_of)} rounds over Lasna blocks {lo}..{hi}")

    # round -> (tx, log_block)
    found = {}
    for log in get_logs(a.rpc, lo, hi):
        rid = int(log["topics"][1], 16)
        found[rid] = (log["transactionHash"], int(log["blockNumber"], 16))

    # Build output with detected_tx inserted right after detected_block.
    fields = list(rows[0].keys())
    if "detected_tx" not in fields:
        fields.insert(fields.index("detected_block") + 1, "detected_tx")

    missing, mismatched = [], []
    for r in rows:
        rid = int(r["round_id"])
        if rid not in found:
            missing.append(rid)
            r["detected_tx"] = ""
            continue
        tx, log_blk = found[rid]
        exp = block_of.get(rid)
        if exp is not None and log_blk != exp:
            mismatched.append((rid, exp, log_blk))
        r["detected_tx"] = tx

    with open(a.csv, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    print(f"wrote detected_tx for {len(block_of) - len(set(missing))}/{len(block_of)} rounds -> {a.csv}")
    if missing:
        print(f"  MISSING (no GapDetected log found): rounds {sorted(set(missing))}")
    if mismatched:
        print(f"  BLOCK MISMATCH (round, csv_block, log_block): {mismatched}")
    # spot-check round 32
    for r in rows:
        if r["round_id"] == "32" and r["arm"] == "fast":
            print(f"  round 32 detected_tx = {r['detected_tx']} (block {r['detected_block']})")


if __name__ == "__main__":
    main()
