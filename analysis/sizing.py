"""Version 2 (net-optimal sizing) analysis. Reads data/v2-rounds.csv from a dynamic-sizing run.

Shows that trade size now tracks the detected gap (it was constant in Version 1) and reports the
realised outcome. Unlike breakeven.py's linear model, nothing here assumes a fixed trade size.
The default CSV is `data/v2-rounds.csv`; pass a different path as argv[1] to override. The
Version 1 fixed-size run lives at `data/rounds.csv` (see analysis/table.py, breakeven.py).

Same-chain rounds (origin_chain == dest_chain) are EXCLUDED from every statistic: the adaptive
flow can push the just-swapped venue to the cheapest side, so the reactive routes back to the
origin pool and the keeper's mark-to-origin is the destination price itself. The net on those
rounds is meaningless; only cross-chain rounds show a real gap. The exclusion is reported, not
silent.

The offline proof that x* maximises profit — and that a fixed size under-trades wide gaps and over-
trades inside the fee band — lives in test/Hairtrigger.t.sol (`test_dynamicBeatsFixedAtWideGap`,
`test_fixedSizeOverTradesInsideFeeBand`), so it does not need reserves reconstructed here.

Writes nothing; prints markdown to paste into the README.
"""

import csv
import statistics
import sys
from pathlib import Path

CSV_PATH = (
    Path(sys.argv[1])
    if len(sys.argv) > 1
    else Path(__file__).resolve().parent.parent / "data" / "v2-rounds.csv"
)


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx == 0 or vy == 0:
        return float("nan")
    return cov / (vx * vy) ** 0.5


def main():
    if not CSV_PATH.exists():
        sys.exit(f"{CSV_PATH} not found; run analysis/keeper.py first")
    all_rows = list(csv.DictReader(CSV_PATH.open()))
    fast_all = [r for r in all_rows if r["arm"] == "fast"]
    if not fast_all:
        sys.exit("no fast-arm rows in the csv")

    sizes = {r["amount_in_weth"] for r in fast_all}
    if len(sizes) == 1:
        sys.exit(
            f"single trade size ({next(iter(sizes))}): this is the Version 1 fixed-size run, "
            "not a dynamic-sizing run. See analysis/breakeven.py."
        )

    by_round = {}
    for r in all_rows:
        by_round.setdefault(r["round_id"], {})[r["arm"]] = r

    # A round is cross-chain only if its fast leg's origin differs from its destination.
    same_chain = [rid for rid, arms in by_round.items()
                  if "fast" in arms and arms["fast"]["origin_chain"] == arms["fast"]["dest_chain"]]
    clean_ids = [rid for rid, arms in by_round.items()
                 if "fast" in arms and rid not in same_chain]
    if not clean_ids:
        sys.exit("no cross-chain rounds in the csv")

    fast = [by_round[rid]["fast"] for rid in clean_ids]
    control = [by_round[rid]["control"] for rid in clean_ids if "control" in by_round[rid]]

    for r in fast + control:
        r["_gap"] = float(r["gap_at_detection_bps"])
        r["_in"] = float(r["amount_in_weth"])
        r["_net_bps"] = float(r["net_profit_bps"])
        r["_gas_bps"] = float(r["gas_cost_eth"]) / float(r["amount_in_weth"]) * 10000

    r_all = pearson([r["_gap"] for r in fast], [r["_in"] for r in fast])
    print(f"### Version 2 — {len(fast)} cross-chain rounds "
          f"({len(fast_all)} fast fills total; excluded same-chain rounds: "
          f"{', '.join(sorted(same_chain, key=int)) if same_chain else 'none'})")
    print()
    print("### Size tracks the gap (was constant in Version 1)")
    print()
    print(f"- Pearson r(gap at detection, amount_in) = {r_all:.3f} over {len(fast)} fast fills")
    print(
        f"- amount_in: min {min(r['_in'] for r in fast):.8f}, "
        f"median {statistics.median(r['_in'] for r in fast):.8f}, "
        f"max {max(r['_in'] for r in fast):.8f} WETH"
    )
    print(
        f"- gas in bps of the trade now varies: min {min(r['_gas_bps'] for r in fast):.2f}, "
        f"median {statistics.median(r['_gas_bps'] for r in fast):.2f}, "
        f"max {max(r['_gas_bps'] for r in fast):.2f} bps (flat in Version 1)"
    )
    total_net = sum(float(r["net_profit_eth"]) for r in fast)
    print(f"- realised net across fast fills: {total_net:+.8f} WETH")

    if control:
        f_bps = [r["_net_bps"] for r in fast]
        c_bps = [r["_net_bps"] for r in control]
        f_pos = sum(1 for v in f_bps if v > 0)
        c_pos = sum(1 for v in c_bps if v > 0)
        paired = {rid: by_round[rid]["fast"]["_net_bps"] - by_round[rid]["control"]["_net_bps"]
                  for rid in clean_ids if "control" in by_round[rid]}
        print()
        print("### Outcome — fast vs the +7 s copy")
        print()
        print(f"- fast net > 0: {f_pos}/{len(f_bps)}  "
              f"(median {statistics.median(f_bps):+.0f} bps, "
              f"range {min(f_bps):+.0f}…{max(f_bps):+.0f})")
        print(f"- control net > 0: {c_pos}/{len(c_bps)}  "
              f"(median {statistics.median(c_bps):+.0f} bps, "
              f"range {min(c_bps):+.0f}…{max(c_bps):+.0f})")
        print(f"- paired fast − control: median {statistics.median(paired.values()):+.0f} bps "
              f"(fast better in {sum(1 for v in paired.values() if v > 0)}/{len(paired)})")

    print()
    print("### Fast fills, sorted by detected gap")
    print()
    print("| round | detected gap (bps) | amount_in (WETH) | net (bps) |")
    print("|---:|---:|---:|---:|")
    for r in sorted(fast, key=lambda r: r["_gap"]):
        print(f"| {r['round_id']} | {r['_gap']:.0f} | {r['_in']:.8f} | {r['_net_bps']:+.0f} |")


if __name__ == "__main__":
    main()
