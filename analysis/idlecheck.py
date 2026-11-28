"""Verify the destination pool is idle between the fast fill and the control fill.

For each of the 28 Version 1 rounds, count the Swap events emitted on the destination
(Unichain Sepolia) MockPool in blocks ``(fastFillBlock, controlFillBlock]`` — after the
fast fill block up to and including the control fill block. If the pool is idle between
the two fills, that window holds exactly one Swap: the control's own fill.

Reads the fill blocks from data/rounds.csv and the Swap logs from the Unichain RPC
(UNI_RPC). Prints one row per round plus the total, and flags any round whose window
holds more than one Swap, or whose fast and control fills share a block.
"""

import csv
import os
import sys
from pathlib import Path

import chain  # analysis/chain.py (same directory on sys.path when run directly)

DATA = Path(__file__).resolve().parent.parent / "data" / "rounds.csv"

# Version 1 destination pool on Unichain Sepolia; all 28 rounds trade this one pool.
DEFAULT_POOL = "0xb28611F84E3E5FC0cD1a2511A187B31f69C7b9f2"
SWAP_TOPIC0 = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
DEST_CHAIN = 1301


def load_rounds():
    rounds = {}
    for row in csv.DictReader(DATA.open()):
        rounds.setdefault(int(row["round_id"]), {})[row["arm"]] = row
    return rounds


def main():
    rpc = os.environ.get("UNI_RPC")
    if not rpc:
        sys.exit("UNI_RPC not set; export the Unichain Sepolia RPC URL")
    pool = os.environ.get("UNI_POOL", DEFAULT_POOL)

    rounds = load_rounds()
    complete = sorted(k for k, v in rounds.items() if "fast" in v and "control" in v)
    if not complete:
        sys.exit("no paired rounds in the csv")

    print(f"pool {pool} on chain {DEST_CHAIN}")
    print(f"{'round':>5}  {'fastBlock':>10}  {'controlBlock':>12}  {'swapCount':>9}")

    total = 0
    offenders = []
    same_block = []
    for rid in complete:
        pair = rounds[rid]
        if int(pair["fast"]["dest_chain"]) != DEST_CHAIN:
            sys.exit(f"round {rid}: dest_chain {pair['fast']['dest_chain']} != {DEST_CHAIN}")
        fast_block = int(pair["fast"]["fill_block"])
        control_block = int(pair["control"]["fill_block"])
        if fast_block == control_block:
            same_block.append(rid)
        if control_block <= fast_block:
            sys.exit(f"round {rid}: control block {control_block} is not after fast block {fast_block}")

        # (fastBlock, controlBlock]: excludes the fast fill's own Swap, includes the control's.
        count = len(chain.logs(rpc, pool, SWAP_TOPIC0, fast_block + 1, control_block))
        total += count
        print(f"{rid:>5}  {fast_block:>10}  {control_block:>12}  {count:>9}")
        if count > 1:
            offenders.append((rid, fast_block, control_block, count))

    if same_block:
        print(f"\n! fast and control fills share a block in rounds: {same_block}")

    if offenders:
        print("\n! FAIL: Swap count above 1 in these rounds — not hidden, listed for review:")
        for rid, fb, cb, n in offenders:
            print(f"  round {rid}: blocks {fb}..{cb} hold {n} Swap events")
        sys.exit(1)

    print(f"\nTotal Swap events across all {len(complete)} rounds: {total}")
    print(f"Expected {len(complete)} (one per round, the control's own fill); observed {total}.")


if __name__ == "__main__":
    main()
