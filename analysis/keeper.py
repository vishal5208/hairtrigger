"""Hairtrigger keeper: watches Lasna for GapDetected and runs the 7s control arm.

Fast arm: the reactive contract's callback fills on the destination chain (~1s).
Control arm: this keeper executes the identical call 7s later, unconditionally.

Every round is appended to data/rounds_raw.jsonl and data/rounds.csv is rebuilt.
Both arms are real on-chain transactions; nothing here is simulated.

Environment:
  PRIVATE_KEY                 owner key for runControl (required unless --dry-run)
  REACTIVE                    HairtriggerReactive address on Lasna
  LASNA_RPC                   default https://lasna-rpc.rnk.dev/
  RPC_<chainId>               destination/origin RPC, e.g. RPC_84532, RPC_1301
  EXECUTOR_<chainId>          ArbExecutor address on each chain
  START_BLOCK_LASNA           first Lasna block to scan (required on first run)
  CONTROL_DELAY               default 7 (seconds; matches ArbExecutor.CONTROL_DELAY)
"""

import argparse
import csv
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chain  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
RAW_PATH = DATA_DIR / "rounds_raw.jsonl"
CSV_PATH = DATA_DIR / "rounds.csv"
STATE_PATH = DATA_DIR / "keeper_state.json"

SYSTEM = "0x8888888888888888888888888888888888888888"
GAP_TOPIC0 = "0xd85e65d3de3362f05c886c71c486e9707dc32e32a296179db6862bd556b5bdfd"
FILL_TOPIC0 = "0x315b38b7541b63cbc5869731981e3329bb4a32919ba18156e7940439716ee671"
SWAP_TOPIC0 = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
Q96 = 1 << 96
BPS = 10_000

CSV_FIELDS = [
    "round_id",
    "arm",
    "origin_tx",
    "origin_chain",
    "dest_chain",
    "gap_at_detection_bps",
    "gap_at_fill_bps",
    "latency_msg_sec",
    "latency_callback_sec",
    "latency_end_to_end_sec",
    "gas_used",
    "gas_cost_eth",
    "callback_cost_rnk",
    "gross_profit_eth",
    "net_profit_eth",
    "net_profit_bps",
    "gap_still_open_at_7s",
    "flow_size_weth",
    "amount_in_weth",
    "amount_out_htrg",
    "origin_block",
    "detected_block",
    "detected_tx",
    "fill_block",
    "origin_timestamp",
    "reactive_timestamp",
    "fill_timestamp",
    "fill_tx",
]


def env(name, default=None, required=False):
    value = os.environ.get(name, default)
    if required and not value:
        raise SystemExit(f"missing required env var {name}")
    return value


class Config:
    def __init__(self, dry_run=False):
        self.dry_run = dry_run
        self.pk = env("PRIVATE_KEY")
        self.reactive = env("REACTIVE", required=True)
        self.lasna_rpc = env("LASNA_RPC", "https://lasna-rpc.rnk.dev/")
        self.control_delay = int(env("CONTROL_DELAY", "7"))
        self.start_block = env("START_BLOCK_LASNA")
        self.executors = {}

    def rpc(self, chain_id):
        return env(f"RPC_{chain_id}", required=True)

    def executor(self, chain_id):
        if chain_id not in self.executors:
            self.executors[chain_id] = env(f"EXECUTOR_{chain_id}", required=True)
        return self.executors[chain_id]


# --- state -----------------------------------------------------------------

def load_state():
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {"last_lasna_block": None, "spend": 0, "liability": None, "inflight": []}


def save_state(state):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_PATH)


# --- decoding ---------------------------------------------------------------

def decode_gap(log):
    words = chain.data_words(log["data"])
    if len(words) < 8:
        raise ValueError(f"short GapDetected payload: {len(words)} words")
    return {
        "round": int(log["topics"][1], 16),
        "origin_chain": int(log["topics"][2], 16),
        "dest_chain": int(log["topics"][3], 16),
        "gap_at_detection_bps": words[0],
        "origin_price_at_detect": words[1],
        "dest_price_at_detect": words[2],
        "amount_in": words[3],
        "min_amount_out": words[4],
        "detected_at": words[5],
        "origin_block": words[6],
        "origin_tx": "0x{:064x}".format(words[7]),
        # Lasna block holding this log: same block that emitted CallbackRequest, because
        # react() requests the callback synchronously. Used for latency_msg_sec.
        "lasna_block": int(log["blockNumber"], 16) if isinstance(log["blockNumber"], str) else log["blockNumber"],
        # Lasna tx that emitted this GapDetected, so a rebuild from raw keeps the provenance
        # link. Note this is the reactive transaction addressed to the system contract
        # (0x8888...8888) that invoked react(); the reactive address is only the log emitter.
        "detected_tx": log["transactionHash"],
    }


def decode_fill(log):
    words = chain.data_words(log["data"])
    return {
        "round": int(log["topics"][1], 16),
        "arm": int(log["topics"][2], 16),
        "amount_in": words[0],
        "amount_out": words[1],
        "post_price": words[2],
        "detected_at": words[3],
        "filled_at": words[4],
        "tx": log["transactionHash"],
        "block": int(log["blockNumber"], 16),
        "timestamp": int(log["blockTimestamp"], 16),
    }


# --- collection -------------------------------------------------------------

def poll_fill(cfg, chain_id, round_id, arm, timeout=90):
    rpc = cfg.rpc(chain_id)
    executor = cfg.executor(chain_id)
    topics = [chain.topic_for_uint(round_id), chain.topic_for_uint(arm)]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            head = chain.block_number(rpc)
            # 190 blocks: stays inside the 200-block eth_getLogs cap on the Base Sepolia RPC.
            found = chain.logs(rpc, executor, FILL_TOPIC0, max(0, head - 190), head, topics)
        except chain.CastError as exc:
            print(f"  ! fill poll: {exc}")
            time.sleep(2)
            continue
        if found:
            return decode_fill(found[-1])
        time.sleep(1)
    return None


def origin_context(cfg, gap):
    """Origin swap timestamp and post-trade price, read from the origin tx receipt.

    The origin pool is idle between rounds (flow is spaced well past the cooldown), so its
    post-swap price at the origin tx is the price the destination is measured against at fill.
    """
    rpc = cfg.rpc(gap["origin_chain"])
    out = {"origin_timestamp": None, "origin_price": None, "flow_size": None}
    try:
        rec = chain.receipt(rpc, gap["origin_tx"])
        out["origin_timestamp"] = chain.block_timestamp(rpc, int(rec["blockNumber"], 16))
        for log in rec.get("logs", []):
            topics = log.get("topics") or []
            if topics and topics[0].lower() == SWAP_TOPIC0:
                words = chain.data_words(log["data"])
                out["origin_price"] = words[2]  # sqrtPriceX96
                out["flow_size"] = words[0]  # amount0 = WETH in (zeroForOne)
                break
    except Exception as exc:  # noqa: BLE001 - best-effort enrichment
        print(f"  ! origin receipt for {gap['origin_tx']}: {exc}")
    return out


def reactive_timestamp(cfg, gap):
    """Lasna block timestamp of the round's GapDetected log.

    `detected_at` in the event is block.timestamp inside react(), which is the same second,
    so it is a safe fallback if the block lookup fails. Cross-chain timestamps are Unix
    seconds on both chains, so they are directly comparable (block *numbers* are not).
    """
    if gap.get("lasna_block") is not None:
        try:
            return chain.block_timestamp(cfg.lasna_rpc, gap["lasna_block"])
        except Exception as exc:  # noqa: BLE001
            print(f"  ! lasna block {gap['lasna_block']} timestamp: {exc}")
    return gap.get("detected_at")


def arm_metrics(cfg, gap, fill, origin_price, reactive_ts):
    rpc = cfg.rpc(gap["dest_chain"])
    rec = chain.receipt(rpc, fill["tx"])
    gas_used = int(rec["gasUsed"], 16) if isinstance(rec["gasUsed"], str) else rec["gasUsed"]
    gas_price = rec.get("effectiveGasPrice", 0)
    gas_price = int(gas_price, 16) if isinstance(gas_price, str) else int(gas_price or 0)
    gas_cost = gas_used * gas_price

    # WETH value of the HTRG received at the origin venue, minus the WETH spent.
    gross = fill["amount_out"] * Q96 * Q96 // (origin_price * origin_price) - gap["amount_in"]
    net = gross - gas_cost
    origin_ts = gap["origin_timestamp"]
    net_bps = None
    if gap["amount_in"]:
        scaled = abs(net) * BPS // gap["amount_in"]
        net_bps = scaled if net >= 0 else -scaled

    # Cross-chain latency decomposition, all in whole seconds (block timestamps are
    # second-granular on both chains, hence the +/-1s quantization).
    #   msg       origin swap -> reactive reaction      (how fast Lasna saw the swap)
    #   callback  reactive reaction -> destination fill (callback delivery + execution)
    #   e2e       origin swap -> destination fill       (the headline)
    msg = None if origin_ts is None or reactive_ts is None else reactive_ts - origin_ts
    callback = None if reactive_ts is None else fill["timestamp"] - reactive_ts
    e2e = None if origin_ts is None else fill["timestamp"] - origin_ts

    return {
        **fill,
        "origin_price": origin_price,
        "gap_at_fill_bps": chain.residual_gap_bps(origin_price, fill["post_price"]),
        "latency_msg_sec": msg,
        "latency_callback_sec": callback,
        "latency_end_to_end_sec": e2e,
        "gas_used": gas_used,
        "gas_cost_wei": gas_cost,
        "gross_wei": gross,
        "net_wei": net,
        "net_bps": net_bps,
    }


def read_liability(cfg):
    """Reactive native balance minus outstanding system debt, in wei.

    The system either pulls RNK from the contract (balance falls) or accrues debt (debt rises);
    either way the cost of a round shows up as a drop in this number.
    """
    try:
        balance = int(chain.read("balance", cfg.reactive, "--rpc-url", cfg.lasna_rpc))
    except Exception as exc:  # noqa: BLE001 - cost is informational
        print(f"  ! balance read failed: {exc}")
        return None
    try:
        debt = int(
            chain.read(
                "call", SYSTEM, "debt(address)(uint256)", cfg.reactive, "--rpc-url", cfg.lasna_rpc
            ).split()[0]
        )
    except Exception as exc:  # noqa: BLE001
        print(f"  ! debt read failed: {exc}")
        debt = 0
    return balance - debt


def accrue_cost(cfg, state):
    now = read_liability(cfg)
    if now is None:
        return None
    before = state["spend"]
    state["spend"] += max(0, state["liability"] - now)
    state["liability"] = now
    save_state(state)
    return state["spend"] - before


def wait_for_dest_time(cfg, dest_chain, allowed_at, poll=1.0, limit=120):
    rpc = cfg.rpc(dest_chain)
    deadline = time.time() + limit
    while time.time() < deadline:
        if chain.block_timestamp(rpc) >= allowed_at:
            return True
        time.sleep(poll)
    return False


def run_control(cfg, gap):
    rpc = cfg.rpc(gap["dest_chain"])
    allowed_at = gap["detected_at"] + cfg.control_delay
    if not wait_for_dest_time(cfg, gap["dest_chain"], allowed_at):
        raise RuntimeError(f"destination chain clock did not reach {allowed_at}")
    chain.send(
        "send",
        "--private-key",
        cfg.pk,
        "--rpc-url",
        rpc,
        cfg.executor(gap["dest_chain"]),
        "runControl(uint256,uint256,uint64)",
        str(gap["round"]),
        str(gap["amount_in"]),
        str(gap["detected_at"]),
    )


def process_round(cfg, state, gap):
    print(
        f"round {gap['round']}: gap {gap['gap_at_detection_bps']} bps "
        f"{gap['origin_chain']} -> {gap['dest_chain']}, det {gap['detected_at']}"
    )
    rec = {
        "status": "pending",
        **gap,
        "fast": None,
        "control": None,
        "callback_cost_rnk": None,
        "gap_still_open_at_7s": None,
    }

    # Fire the control immediately, before any RPC enrichment. run_control blocks until the
    # destination clock reaches detectedAt+control_delay, so the send lands at ~detectedAt+7s.
    # Enrichment (accrue_cost/origin_context/reactive_timestamp) takes ~12s; doing it first
    # pushed the send to detectedAt+19s and invalidated the measurement.
    if not cfg.dry_run:
        run_control(cfg, gap)

    rec["callback_cost_rnk"] = accrue_cost(cfg, state)
    context = origin_context(cfg, gap)
    rec["origin_timestamp"] = context["origin_timestamp"]
    rec["flow_size"] = context["flow_size"]
    rec["reactive_timestamp"] = reactive_timestamp(cfg, gap)
    gap["origin_timestamp"] = context["origin_timestamp"]
    origin_price = context["origin_price"] or gap["origin_price_at_detect"]

    fast = poll_fill(cfg, gap["dest_chain"], gap["round"], 0, timeout=120)
    if fast is None:
        print(f"  ! round {gap['round']}: fast arm fill not found")
        rec["status"] = "fast_missing"
    else:
        rec["fast"] = arm_metrics(cfg, gap, fast, origin_price, rec["reactive_timestamp"])
        print(f"  fast: {fast['amount_out']} HTRG @ {fast['timestamp']} ({fast['tx']})")

    if not cfg.dry_run:
        control = poll_fill(cfg, gap["dest_chain"], gap["round"], 1, timeout=120)
        if control is None:
            print(f"  ! round {gap['round']}: control fill not found after send")
            rec["status"] = "control_missing"
        else:
            rec["control"] = arm_metrics(cfg, gap, control, origin_price, rec["reactive_timestamp"])
            print(f"  control: {control['amount_out']} HTRG @ {control['timestamp']} ({control['tx']})")

    if rec["control"] is not None:
        rec["gap_still_open_at_7s"] = rec["control"]["net_wei"] > 0
        if rec["status"] == "pending":
            rec["status"] = "done"

    append_record(rec)
    rebuild_csv()
    return rec


# --- output -----------------------------------------------------------------

def append_record(record):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with RAW_PATH.open("a") as fh:
        fh.write(json.dumps(record) + "\n")


def load_rounds():
    rounds = {}
    if not RAW_PATH.exists():
        return rounds
    for line in RAW_PATH.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        rounds[rec["round"]] = rec  # last write wins
    return rounds


def _eth(value):
    """Exact wei -> ETH decimal string (no float rounding)."""
    if value is None:
        return ""
    value = int(value)
    sign = "-" if value < 0 else ""
    whole, frac = divmod(abs(value), 10**18)
    frac_digits = f"{frac:018d}".rstrip("0")
    return f"{sign}{whole}" + (f".{frac_digits}" if frac_digits else "")


def _cell(value):
    return "" if value is None else value


def rebuild_csv():
    rounds = load_rounds()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for round_id in sorted(rounds):
            rec = rounds[round_id]
            for arm in ("fast", "control"):
                fill = rec.get(arm)
                if fill is None:
                    continue
                writer.writerow(
                    {
                        "round_id": rec["round"],
                        "arm": arm,
                        "origin_tx": rec["origin_tx"],
                        "origin_chain": rec["origin_chain"],
                        "dest_chain": rec["dest_chain"],
                        "gap_at_detection_bps": rec["gap_at_detection_bps"],
                        "gap_at_fill_bps": fill["gap_at_fill_bps"],
                        "latency_msg_sec": _cell(fill.get("latency_msg_sec")),
                        "latency_callback_sec": _cell(fill.get("latency_callback_sec")),
                        "latency_end_to_end_sec": _cell(fill.get("latency_end_to_end_sec")),
                        "gas_used": fill["gas_used"],
                        "gas_cost_eth": _eth(fill["gas_cost_wei"]),
                        # The reactive execution/request is billed once per round; only the
                        # fast arm is callback-driven, so the control row leaves it blank.
                        "callback_cost_rnk": rec.get("callback_cost_rnk")
                        if arm == "fast" and rec.get("callback_cost_rnk") is not None
                        else "",
                        "gross_profit_eth": _eth(fill["gross_wei"]),
                        "net_profit_eth": _eth(fill["net_wei"]),
                        "net_profit_bps": _cell(fill["net_bps"]),
                        "gap_still_open_at_7s": _cell(
                            None
                            if rec.get("gap_still_open_at_7s") is None
                            else str(bool(rec["gap_still_open_at_7s"])).lower()
                        ),
                        "flow_size_weth": _eth(rec.get("flow_size")),
                        "amount_in_weth": _eth(rec["amount_in"]),
                        "amount_out_htrg": _eth(fill["amount_out"]),
                        "origin_block": _cell(rec.get("origin_block")),
                        "detected_block": _cell(rec.get("lasna_block")),
                        "detected_tx": _cell(rec.get("detected_tx")),
                        "fill_block": _cell(fill.get("block")),
                        "origin_timestamp": _cell(rec.get("origin_timestamp")),
                        "reactive_timestamp": _cell(rec.get("reactive_timestamp")),
                        "fill_timestamp": fill["timestamp"],
                        "fill_tx": fill["tx"],
                    }
                )


# --- main loop --------------------------------------------------------------

def scan_gap_logs(cfg, state):
    rpc = cfg.lasna_rpc
    head = chain.block_number(rpc)
    start = state["last_lasna_block"]
    if start is None:
        if not cfg.start_block:
            raise SystemExit("set START_BLOCK_LASNA to the reactive deployment block on first run")
        start = int(cfg.start_block)
    else:
        start = start + 1
    if start > head:
        return []

    found = []
    cursor = start
    while cursor <= head:
        end = min(head, cursor + 999)
        batch = chain.logs(rpc, cfg.reactive, GAP_TOPIC0, cursor, end)
        found.extend(log for log in batch if not log.get("removed"))
        cursor = end + 1

    state["last_lasna_block"] = head
    save_state(state)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="decode and log, never send runControl")
    parser.add_argument("--once", action="store_true", help="scan once and exit")
    parser.add_argument("--rebuild", action="store_true", help="rebuild rounds.csv from rounds_raw.jsonl")
    args = parser.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if args.rebuild:
        rebuild_csv()
        print(f"wrote {CSV_PATH}")
        return

    cfg = Config(dry_run=args.dry_run)
    state = load_state()
    if state.get("liability") is None:
        state["liability"] = read_liability(cfg) or 0
        save_state(state)
    if state.get("inflight"):
        print(f"! dropping {len(state['inflight'])} in-flight round(s) from a previous run: {state['inflight']}")
        state["inflight"] = []
        save_state(state)

    print(f"watching {cfg.reactive} on {cfg.lasna_rpc}; control delay {cfg.control_delay}s")
    while True:
        try:
            logs = scan_gap_logs(cfg, state)
        except chain.CastError as exc:
            print(f"! lasna scan: {exc}")
            if args.once:
                raise
            time.sleep(3)
            continue
        gaps = []
        for log in logs:
            try:
                gaps.append(decode_gap(log))
            except ValueError as exc:
                print(f"! skipping unreadable log: {exc}")
        for gap in gaps:
            state["inflight"] = [gap["round"]]
            save_state(state)
            try:
                process_round(cfg, state, gap)
            except Exception as exc:  # noqa: BLE001 - keep the keeper alive
                print(f"! round {gap['round']} failed: {exc}")
            state["inflight"] = []
            save_state(state)
        if args.once:
            break
        time.sleep(1)


if __name__ == "__main__":
    main()
