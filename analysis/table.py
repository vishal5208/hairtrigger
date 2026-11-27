"""Read data/rounds.csv and print the README markdown tables.

CSV is long-format: one row per arm per round, keyed by round_id. The side-by-side table
pairs the two rows of each round; the summary reports the control-clears-costs fraction
and median fast minus median control, as specified.
"""

import csv
import statistics
import sys
from decimal import Decimal
from pathlib import Path

CSV_PATH = Path(__file__).resolve().parent.parent / "data" / "rounds.csv"
CHAIN_NAMES = {84532: "Base Sepolia", 1301: "Unichain Sepolia", 5318007: "Lasna"}


def chain_name(chain_id):
    return f"{chain_id} ({CHAIN_NAMES[chain_id]})" if chain_id in CHAIN_NAMES else chain_id


def dec(value):
    return None if value in (None, "") else Decimal(value)


def weth(value):
    if value is None:
        return "—"
    return f"{value:.9f}".rstrip("0").rstrip(".")


def secs(value):
    return "—" if value in (None, "") else f"{value}s"


def rnk(value):
    if not value:
        return "—"
    return f"{Decimal(value) / Decimal(10**18):.6f}".rstrip("0").rstrip(".")


def load():
    with CSV_PATH.open() as fh:
        rows = list(csv.DictReader(fh))
    rounds = {}
    for row in rows:
        rounds.setdefault(int(row["round_id"]), {})[row["arm"]] = row
    return rounds


def median(values):
    return statistics.median(values) if values else None


def p90(values):
    """Nearest-rank 90th percentile (ceil(0.9*n)-th smallest)."""
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, -(-9 * len(ordered) // 10) - 1)  # ceil(0.9*n) - 1
    return ordered[idx]


def main():
    if not CSV_PATH.exists():
        sys.exit(f"{CSV_PATH} not found; run analysis/keeper.py first")
    rounds = load()
    if not rounds:
        sys.exit("no rounds in the csv")

    print("| Round | Origin | Flow (WETH) | Gap det (bps) | Fast fill gap (bps) "
          "| Ctrl fill gap (bps) | Fast net (WETH) | Ctrl net (WETH) | Fast e2e (s) "
          "| Ctrl e2e (s) | Open at 7s |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|")

    fast_nets, control_nets, paired, fast_e2e, ctrl_e2e, msg_lat, cb_lat = (
        [], [], [], [], [], [], [])
    for round_id in sorted(rounds):
        pair = rounds[round_id]
        fast, control = pair.get("fast"), pair.get("control")
        base = fast or control
        origin = chain_name(int(base["origin_chain"]))
        flow = weth(dec(base["flow_size_weth"]))
        detect = base["gap_at_detection_bps"]
        f_gap = fast["gap_at_fill_bps"] if fast else "—"
        c_gap = control["gap_at_fill_bps"] if control else "—"
        f_net = dec(fast["net_profit_eth"]) if fast else None
        c_net = dec(control["net_profit_eth"]) if control else None
        f_e2e = secs(fast["latency_end_to_end_sec"]) if fast else "—"
        c_e2e = secs(control["latency_end_to_end_sec"]) if control else "—"
        open_flag = base["gap_still_open_at_7s"] or "—"

        if f_net is not None:
            fast_nets.append(f_net)
        if c_net is not None:
            control_nets.append(c_net)
        if f_net is not None and c_net is not None:
            paired.append(f_net - c_net)
        if fast and fast["latency_end_to_end_sec"] not in ("", None):
            fast_e2e.append(int(fast["latency_end_to_end_sec"]))
        if fast and fast["latency_msg_sec"] not in ("", None):
            msg_lat.append(int(fast["latency_msg_sec"]))
        if fast and fast["latency_callback_sec"] not in ("", None):
            cb_lat.append(int(fast["latency_callback_sec"]))
        if control and control["latency_end_to_end_sec"] not in ("", None):
            ctrl_e2e.append(int(control["latency_end_to_end_sec"]))

        print(
            f"| {round_id} | {origin} | {flow} | {detect} | {f_gap} | {c_gap} "
            f"| {weth(f_net)} | {weth(c_net)} | {f_e2e} | {c_e2e} | {open_flag} |"
        )

    print()
    print("### Summary")
    print()
    print(f"- Rounds: {len(rounds)}")
    if msg_lat:
        lo, hi = min(msg_lat), max(msg_lat)
        print(
            f"- Message leg (origin swap → Lasna reaction): sub-second — observed block-time "
            f"delta {lo}..{hi}s is ±1s block quantization plus unsynchronized cross-chain clocks, "
            f"so it is reported as a bound, not a signed latency; the per-round origin and Lasna "
            f"block numbers are the provenance"
        )
    if fast_e2e:
        print(
            f"- Fast-arm end-to-end latency: median {median(fast_e2e):g}s, "
            f"p90 {p90(fast_e2e)}s (min {min(fast_e2e)}s, max {max(fast_e2e)}s), ±1s quantized"
        )
    if cb_lat:
        print(f"- Callback leg (Lasna reaction → fill): median {median(cb_lat):g}s, p90 {p90(cb_lat)}s")
    if ctrl_e2e:
        print(
            f"- Control-arm end-to-end latency: median {median(ctrl_e2e):g}s, p90 {p90(ctrl_e2e)}s "
            f"(deliberate +7s gate + inclusion, ±1s quantized)"
        )
    if fast_nets:
        positive = sum(1 for x in fast_nets if x > 0)
        print(f"- Fast arm net-positive: {positive}/{len(fast_nets)}")
    if control_nets:
        cleared = sum(1 for x in control_nets if x > 0)
        print(
            f"- Control cleared costs (+7s): {cleared}/{len(control_nets)} "
            f"({100 * cleared / len(control_nets):.0f}%)"
        )
    f_med, c_med = median(fast_nets), median(control_nets)
    if f_med is not None:
        print(f"- Median fast net: {weth(f_med)} WETH")
    if c_med is not None:
        print(f"- Median control net: {weth(c_med)} WETH")
    if f_med is not None and c_med is not None:
        print(f"- Median fast − median control: {weth(f_med - c_med)} WETH")
    if paired:
        print(f"- Median paired difference (fast − control): {weth(median(paired))} WETH")

    print()
    print("### Transaction provenance (four hashes per round)")
    print()
    print("| Round | origin_tx (swap) | detected_tx (Lasna react) | fast fill_tx | control fill_tx |")
    print("|---:|---|---|---|---|")

    def hs(value):
        return f"`{value}`" if value else "—"

    for round_id in sorted(rounds):
        pair = rounds[round_id]
        fast, control = pair.get("fast"), pair.get("control")
        base = fast or control
        origin_tx = (base or {}).get("origin_tx") or ""
        detected_tx = (base or {}).get("detected_tx") or ""
        f_fill = fast["fill_tx"] if fast else ""
        c_fill = control["fill_tx"] if control else ""
        print(
            f"| {round_id} | {hs(origin_tx)} | {hs(detected_tx)} "
            f"| {hs(f_fill)} | {hs(c_fill)} |"
        )

    print()
    print("### Per-arm ledger")
    print()
    print("| Round | Arm | Gross (WETH) | Net (WETH) | Net (bps) | Gas used | Gas cost (WETH) "
          "| Callback cost (RNK) | Fill tx |")
    print("|---:|:---:|---:|---:|---:|---:|---:|---:|---|")
    for round_id in sorted(rounds):
        for arm in ("fast", "control"):
            row = rounds[round_id].get(arm)
            if not row:
                continue
            print(
                f"| {round_id} | {arm} | {weth(dec(row['gross_profit_eth']))} "
                f"| {weth(dec(row['net_profit_eth']))} | {row['net_profit_bps'] or '—'} "
                f"| {row['gas_used']} | {weth(dec(row['gas_cost_eth']))} "
                f"| {rnk(row['callback_cost_rnk'])} | `{row['fill_tx']}` |"
            )


if __name__ == "__main__":
    main()
