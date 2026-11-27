#!/usr/bin/env python3
"""Paired bootstrap confidence intervals for the fast-vs-control experiment.

Reads data/rounds.csv (long format, one row per arm per round) and resamples
*rounds* (not arms) so each replicate keeps the same-gap pairing. For each
round the paired difference is

    delta_weth = fast.net_profit_eth - control.net_profit_eth
    delta_bps  = fast.net_profit_bps - control.net_profit_bps

Usage:
    python3 analysis/bootstrap.py [--iters 20000] [--seed 0] [--csv data/rounds.csv]
"""
import argparse
import csv
from statistics import mean, median

import numpy as np


def load_pairs(path):
    by = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            by.setdefault(int(row["round_id"]), {})[row["arm"]] = row
    rounds, dw, db, fast_better = [], [], [], 0
    for rid in sorted(by):
        arms = by[rid]
        if "fast" not in arms or "control" not in arms:
            continue
        fw = float(arms["fast"]["net_profit_eth"])
        cw = float(arms["control"]["net_profit_eth"])
        fb = float(arms["fast"]["net_profit_bps"])
        cb = float(arms["control"]["net_profit_bps"])
        rounds.append(rid)
        dw.append(fw - cw)
        db.append(fb - cb)
        fast_better += 1 if fw > cw else 0
    return rounds, np.array(dw), np.array(db), fast_better


def boot_ci(x, stat, iters, seed):
    rng = np.random.default_rng(seed)
    n = len(x)
    idx = rng.integers(0, n, size=(iters, n))
    reps = stat(x[idx], axis=1)
    return np.percentile(reps, 2.5), np.percentile(reps, 97.5)


def fmt(lo, hi, scale=1.0):
    return f"[{lo / scale:+.4g}, {hi / scale:+.4g}]"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--csv", default="data/rounds.csv")
    a = ap.parse_args()

    rounds, dw, db, fast_better = load_pairs(a.csv)
    n = len(rounds)

    print(f"paired rounds: {n}")
    print(f"fast nets more in {fast_better}/{n} rounds")
    print()
    for label, x, unit in (
        ("paired delta net_profit (WETH)", dw, "WETH"),
        ("paired delta net_profit (bps)", db, "bps"),
    ):
        lo_mean, hi_mean = boot_ci(x, np.mean, a.iters, a.seed)
        lo_med, hi_med = boot_ci(x, np.median, a.iters, a.seed + 1)
        print(label)
        print(f"  mean   {x.mean():+.4g} {unit}   95% CI {fmt(lo_mean, hi_mean)} {unit}")
        print(f"  median {median(x):+.4g} {unit}   95% CI {fmt(lo_med, hi_med)} {unit}")
        print()

    # fast > control as a proportion, bootstrap CI over rounds
    wins = (dw > 0).astype(float)
    lo, hi = boot_ci(wins, np.mean, a.iters, a.seed + 2)
    print(f"P(fast > control): {wins.mean():.3f}   95% CI [{lo:.3f}, {hi:.3f}]")


if __name__ == "__main__":
    main()
