"""Public-RPC helpers built on `cast`. No API keys, no paid infrastructure."""

import json
import subprocess
import time

BPS = 10_000


class CastError(RuntimeError):
    pass


def _run(args, timeout=60):
    proc = subprocess.run(
        ["cast", *[str(a) for a in args]],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise CastError(proc.stderr.strip() or proc.stdout.strip() or f"cast exited {proc.returncode}")
    return proc.stdout.strip()


def read(*args, retries=4):
    """Idempotent call: safe to retry on transient public-RPC failures."""
    last = None
    for attempt in range(retries):
        try:
            return _run(args)
        except (CastError, subprocess.TimeoutExpired) as exc:
            last = exc
            if attempt + 1 < retries:
                time.sleep(1.5 * (attempt + 1))
    raise CastError(f"cast {' '.join(map(str, args))}: {last}")


def read_json(*args, retries=4):
    return json.loads(read(*args, "--json", retries=retries))


def send(*args):
    """Signed transaction: never retried automatically (a duplicate would double-fill)."""
    return _run(args)


def block_number(rpc):
    return int(read("block-number", "--rpc-url", rpc))


def block_timestamp(rpc, number=None):
    data = read_json("block", number if number is not None else "latest", "--rpc-url", rpc)
    return _hexint(data["timestamp"])


def receipt(rpc, tx_hash):
    return read_json("receipt", tx_hash, "--rpc-url", rpc)


def logs(rpc, address, topic0, from_block, to_block, extra_topics=()):
    args = [
        "logs",
        "--address",
        address,
        "--from-block",
        str(from_block),
        "--to-block",
        str(to_block),
        topic0,
        *extra_topics,
        "--rpc-url",
        rpc,
    ]
    return read_json(*args)


def call(rpc, to, signature, block="latest"):
    """Single-value eth_call decoded to an int."""
    out = read("call", to, signature, "--rpc-url", rpc, "--block", str(block))
    return int(out.split()[0])


def topic_for_uint(value):
    return "0x{:064x}".format(int(value))


def data_words(raw):
    blob = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
    return [int.from_bytes(blob[i : i + 32], "big") for i in range(0, len(blob), 32)]


def _hexint(value):
    if isinstance(value, int):
        return value
    return int(value, 16) if value.startswith("0x") else int(value)


def relative_gap_bps(hi, lo):
    """((hi/lo)^2 - 1) * 10000 as an int, matching HairtriggerReactive._relativeGapBps."""
    hi, lo = int(hi), int(lo)
    if lo == 0:
        return 0
    # Exact integer form of (hi^2 - lo^2) * BPS / lo^2, rounded down.
    return ((hi * hi - lo * lo) * BPS) // (lo * lo)


def residual_gap_bps(origin_price, dest_price):
    """Positive while HTRG is still cheaper on the destination; negative once we overshoot.

    sqrtPriceX96 = sqrt(HTRG per WETH), so the higher price is the venue where 1 WETH buys
    more HTRG, i.e. where HTRG is cheaper.
    """
    origin_price, dest_price = int(origin_price), int(dest_price)
    if dest_price >= origin_price:
        return relative_gap_bps(dest_price, origin_price)
    return -relative_gap_bps(origin_price, dest_price)
