"""Break-even analysis: the detected gap (bps) at which each arm's fill stops covering costs.

The arbitrage trade is a constant 0.0004 WETH on both arms, so gas expressed in bps of the
trade is flat across the run (it does not move with flow size — only the resulting gap does).
We fit net_bps against the gap at detection (slope ~1, so profit tracks the gap one-for-one)
and report where net crosses zero per arm, plus the observed crossover rounds.

Writes nothing; prints markdown to paste into the README. Reads data/rounds.csv.
"""

import csv
import statistics
import sys
from collections import defaultdict
from decimal import Decimal as D
from pathlib import Path

CSV_PATH = Path(__file__).resolve().parent.parent / "data" / "rounds.csv"


def dec(x):
    return D(x)


def fit(points):
    """Least-squares y = a + b x; returns (a, b)."""
    n = len(points)
    sx = sum(p[0] for p in points)
    sy = sum(p[1] for p in points)
    sxx = sum(p[0] ** 2 for p in points)
    sxy = sum(p[0] * p[1] for p in points)
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    a = (sy - b * sx) / n
    return a, b


def main():
    if not CSV_PATH.exists():
        sys.exit(f"{CSV_PATH} not found; run analysis/keeper.py first")
    rows = list(csv.DictReader(CSV_PATH.open()))
    if not rows:
        sys.exit("no rounds in the csv")

    for r in rows:
        amt = dec(r["amount_in_weth"])
        r["_amt"] = amt
        r["_gas_bps"] = dec(r["gas_cost_eth"]) / amt * 10000
        r["_net_bps"] = dec(r["net_profit_eth"]) / amt * 10000
        r["_det"] = int(r["gap_at_detection_bps"])
        r["_fill"] = int(r["gap_at_fill_bps"])
        r["_flow"] = float(r["flow_size_weth"])

    amts = {r["_amt"] for r in rows}
    assert len(amts) == 1, f"trade size is not constant: {amts}"

    # --- gas in bps of the fixed trade, per arm ---
    print("### Gas in bps of the fixed 0.0004 WETH trade")
    print()
    for arm in ("fast", "control"):
        g = [r["_gas_bps"] for r in rows if r["arm"] == arm]
        print(
            f"- {arm}: min {min(g):.2f}, median {statistics.median(g):.2f}, max {max(g):.2f} bps"
        )

    # --- break-even on the detected gap, per arm ---
    print()
    print("### Break-even on the detected gap (net_bps = a + b x detected)")
    print()
    print("| Arm | net = 0 at detected gap | smallest gap that actually netted |")
    print("|---|---:|---:|")
    be = {}
    for arm in ("fast", "control"):
        pts = [(r["_det"], float(r["_net_bps"])) for r in rows if r["arm"] == arm]
        a, b = fit(pts)
        be[arm] = -a / b
        pos = sorted(x for x, y in pts if y > 0)
        if pos:
            smallest = f"{pos[0]} bps (+{min(y for x, y in pts if y > 0):.0f} bps net)"
        else:
            smallest = "none"
        label = "Fast (2 s)" if arm == "fast" else "Control (+7 s)"
        print(f"| {label} | ≈ {be[arm]:.0f} bps | {smallest} |")

    # --- observed crossover as the gap converged ---
    print()
    print("### Observed crossover (convergence tail)")
    print()
    print("| Round | Detected gap | Fast net | Control net |")
    print("|---:|---:|---:|---:|")
    by_round = defaultdict(dict)
    for r in rows:
        by_round[int(r["round_id"])][r["arm"]] = r
    complete = [rid for rid in sorted(by_round) if "control" in by_round[rid]]
    for rid in complete[-6:]:  # the final convergence run, where the sign flips
        pair = by_round[rid]
        c = pair["control"]
        f = pair.get("fast")
        print(
            f"| {rid} | {c['_det']} bps | "
            f"{'+' if float(f['_net_bps']) >= 0 else ''}{float(f['_net_bps']):.0f} bps | "
            f"{'+' if float(c['_net_bps']) >= 0 else ''}{float(c['_net_bps']):.0f} bps |"
        )


if __name__ == "__main__":
    main()
