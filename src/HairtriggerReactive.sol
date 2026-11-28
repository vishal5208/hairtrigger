// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title HairtriggerReactive
/// @notice Reactive contract on Lasna. Watches the same WETH/HTRG pool on any number of chains and,
///         when two observed prices diverge by more than the cost threshold, sizes the trade to
///         maximise profit and requests a callback on the venue where HTRG is cheapest, in the same
///         second.
/// @dev Price is carried in the canonical Uniswap V3 Swap event's `sqrtPriceX96` field:
///      sqrt(HTRG per WETH) * 2^96. A higher sqrt price means HTRG is cheaper. All pools are ours and
///      use the same token roles on every chain, so the values are directly comparable. Reserves are
///      recovered from each event's (`sqrtPriceX96`, `liquidity`) pair, so a position is rebuilt
///      exactly from the log without tracking signed deltas. All timing uses block.timestamp; block
///      numbers are logged for joins only and never used for delay math.
///
///      Routing is N-venue: on every observed swap we re-scan all venues, choose the cheapest one
///      that has an executor as the destination, and use the dearest observed price as the
///      mark-to-market reference. With two venues this reduces exactly to "compare the two and buy
///      on the cheaper one".
contract HairtriggerReactive is AbstractReactive {
    /// @dev keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")
    uint256 private constant SWAP_TOPIC0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    /// @dev keccak256("Fill(uint256,uint8,uint256,uint256,uint160,uint64,uint256)") — ArbExecutor.Fill
    uint256 private constant FILL_TOPIC0 = 0x315b38b7541b63cbc5869731981e3329bb4a32919ba18156e7940439716ee671;

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10_000;
    uint256 private constant GAMMA_BPS = 9_970; // 1 - 0.3% pool fee, in 1e4
    uint64 private constant CALLBACK_GAS_LIMIT = 400_000;

    struct Venue {
        address pool;
        address executor;
        bool observed;
        uint160 sqrtPriceX96;
        uint64 lastUpdatedAt;
        uint256 reserve0; // WETH side
        uint256 reserve1; // HTRG side
    }

    /// @notice Every watched chain, in subscription order. Iterated by the routing scan.
    uint256[] public chainIds;

    address public owner;
    uint256 public immutable thresholdBps;
    /// @notice Smallest trade worth a callback; below this the optimum is not worth the gas.
    uint256 public immutable minTradeWeth;
    /// @notice Hard cap on trade size, so a wild price cannot drain the executor's inventory.
    uint256 public immutable maxTradeWeth;
    uint256 public immutable slippageBps;
    uint64 public immutable cooldown;
    /// @dev sqrt(gamma) * 2^96, precomputed once for the closed-form optimum.
    uint256 public immutable sqrtGammaQ96;

    uint256 public roundCounter;
    uint256 public lastFireAt;
    /// @notice One arbitrage in flight at a time. Set when a callback is requested, cleared when the
    ///         executor's fast `Fill` for that round is observed, or released by `inFlightTimeout` if
    ///         the callback is lost. Prevents a second trigger before the first has landed — including
    ///         a trigger caused by the fast fill's own Swap on the destination pool.
    bool public inFlight;
    uint256 public inFlightSince;
    uint256 public inFlightRoundId;
    uint256 public inFlightTimeout = 30; // seconds; covers a lost/reverted callback
    /// @notice Emergency stop. When paused, prices and fills are still observed but no callback is
    ///         requested, so the agent stops auto-trading without losing its price feed.
    bool public paused;

    mapping(uint256 chainId => Venue) private _venues;

    event ExecutorSet(uint256 indexed chainId, address indexed executor);
    event VenueUpdated(uint256 indexed chainId, uint160 sqrtPriceX96, uint64 timestamp);
    event GapDetected(
        uint256 indexed roundId,
        uint256 indexed originChainId,
        uint256 indexed destChainId,
        uint256 gapBps,
        uint160 originSqrtPriceX96,
        uint160 destSqrtPriceX96,
        uint256 amountIn,
        uint256 minAmountOut,
        uint64 detectedAt,
        uint256 originBlockNumber,
        uint256 originTxHash
    );

    event LoopClosed(uint256 indexed roundId, uint256 closedAt);
    /// @notice Emitted when a gap was actionable but the system rejected the callback request. No
    ///         round, cooldown or in-flight window is consumed; the next price tick retries.
    event CallbackFailed(uint256 indexed attemptedRoundId, uint256 indexed destChainId);
    event PausedSet(bool paused);

    error OnlyOwner(address caller_);

    /// @param chainIds_ Chains to watch (>= 2, distinct). Each must host one WETH/HTRG pool.
    /// @param pools_ Pool address on each chain, index-aligned with `chainIds_`.
    /// @param initialSqrtPriceX96_ Launch price shared by every pool (they are seeded identically).
    /// @param initialLiquidity_ Launch liquidity shared by every pool.
    constructor(
        uint256[] memory chainIds_,
        address[] memory pools_,
        uint160 initialSqrtPriceX96_,
        uint128 initialLiquidity_,
        uint256 thresholdBps_,
        uint256 minTradeWeth_,
        uint256 maxTradeWeth_,
        uint256 slippageBps_,
        uint64 cooldown_
    ) payable {
        uint256 n = chainIds_.length;
        require(n >= 2 && pools_.length == n, "BAD_VENUES");
        require(initialSqrtPriceX96_ != 0, "BAD_PRICE");
        require(thresholdBps_ != 0 && thresholdBps_ <= BPS, "BAD_THRESHOLD");
        require(minTradeWeth_ <= maxTradeWeth_ && maxTradeWeth_ != 0, "BAD_TRADE_RANGE");
        require(slippageBps_ < BPS, "BAD_SLIPPAGE");

        owner = msg.sender;
        thresholdBps = thresholdBps_;
        minTradeWeth = minTradeWeth_;
        maxTradeWeth = maxTradeWeth_;
        slippageBps = slippageBps_;
        cooldown = cooldown_;
        sqrtGammaQ96 = Math.sqrt(Math.mulDiv(GAMMA_BPS, Q96 * Q96, BPS));

        for (uint256 i = 0; i < n; ++i) {
            uint256 cid = chainIds_[i];
            address pool = pools_[i];
            require(cid != 0 && pool != address(0), "BAD_VENUE");
            require(_venues[cid].pool == address(0), "DUP_CHAIN");

            Venue storage v = _venues[cid];
            v.pool = pool;
            v.observed = true;
            v.sqrtPriceX96 = initialSqrtPriceX96_;
            v.lastUpdatedAt = uint64(block.timestamp);
            _applySwap(v, initialSqrtPriceX96_, initialLiquidity_);
            chainIds.push(cid);

            SYSTEM.subscribe(cid, pool, SWAP_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @notice Number of venues being watched.
    function chainCount() external view returns (uint256) {
        return chainIds.length;
    }

    /// @notice Sets the destination executor for a chain. Executors cannot be known before the
    ///         reactive contract exists (their constructor pins this address), so this is a
    ///         one-time wiring step after both are deployed.
    function setExecutor(uint256 chainId_, address executor_) external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        Venue storage venue = _venues[chainId_];
        require(venue.pool != address(0), "UNKNOWN_CHAIN");
        venue.executor = executor_;
        // Watch the executor's Fill events so a fast fill can close the in-flight window.
        if (executor_ != address(0)) {
            SYSTEM.subscribe(chainId_, executor_, FILL_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit ExecutorSet(chainId_, executor_);
    }

    /// @notice How long an in-flight round may stay open before another trigger is allowed.
    function setInFlightTimeout(uint256 timeoutSec_) external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        inFlightTimeout = timeoutSec_;
    }

    /// @notice Emergency stop: block new callbacks. Price observation and fill accounting continue.
    function setPaused(bool paused_) external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        paused = paused_;
        emit PausedSet(paused_);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.topic0 == FILL_TOPIC0) {
            _onFill(log_);
            return;
        }
        Venue storage venue = _venues[log_.chainId];
        if (venue.pool == address(0) || log_.contractAddress != venue.pool || log_.topic0 != SWAP_TOPIC0) {
            return;
        }
        if (log_.data.length < 160) return;

        // Uniswap V3 Swap data: (int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)
        (,, uint160 sqrtPrice, uint128 liquidity,) = abi.decode(log_.data, (int256, int256, uint160, uint128, int24));
        if (sqrtPrice == 0) return; // never let a malformed log zero the venue price (gap math divides by it)

        venue.sqrtPriceX96 = sqrtPrice;
        venue.lastUpdatedAt = uint64(block.timestamp);
        venue.observed = true;
        _applySwap(venue, sqrtPrice, liquidity);

        emit VenueUpdated(log_.chainId, sqrtPrice, uint64(block.timestamp));
        if (paused) return; // keep observing prices, but do not request new callbacks

        // Re-scan every venue: buy on the cheapest executable one, mark at the dearest price.
        (uint256 destChainId, uint256 dearChainId, uint256 gapBps) = _bestArb();
        if (destChainId == 0 || gapBps < thresholdBps) return;
        if (lastFireAt != 0 && block.timestamp < lastFireAt + cooldown) return;
        // Still waiting on the previous callback: do not stack a second arb before it lands.
        if (inFlight && block.timestamp < inFlightSince + inFlightTimeout) return;

        Venue storage dest = _venues[destChainId];
        uint256 sDear = _venues[dearChainId].sqrtPriceX96;
        (uint256 amountIn, uint256 minAmountOut) = optimalIn(dest.reserve0, dest.reserve1, dest.sqrtPriceX96, sDear);
        if (amountIn == 0) return; // no size is profitable, or below the dust floor

        // Preview the round id, but commit nothing until the system actually accepts the callback. A
        // rejected request (unfunded RNK, system pause, bad config) must not burn a round id, start
        // the cooldown, open an in-flight window, or emit a phantom GapDetected the keeper would wait
        // on for a fill that can never arrive.
        uint256 roundId = roundCounter + 1;
        uint64 detectedAt = uint64(block.timestamp);

        bytes memory payload = abi.encodeWithSignature(
            "onArb(address,uint256,uint256,uint256,uint64)", address(0), roundId, amountIn, minAmountOut, detectedAt
        );

        bool requested;
        try SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: dest.executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        ) {
            requested = true;
        } catch {
            requested = false;
        }

        if (!requested) {
            // The price observation above is already persisted; surface the failure and let the next
            // price tick retry with no cooldown or in-flight penalty.
            emit CallbackFailed(roundId, destChainId);
            return;
        }

        roundCounter = roundId;
        lastFireAt = detectedAt;
        inFlight = true;
        inFlightSince = detectedAt;
        inFlightRoundId = roundId;

        emit GapDetected(
            roundId,
            log_.chainId,
            destChainId,
            gapBps,
            sqrtPrice,
            dest.sqrtPriceX96,
            amountIn,
            minAmountOut,
            detectedAt,
            log_.blockNumber,
            log_.txHash
        );
    }

    /// @notice Profit-maximising WETH input to buy HTRG on the cheaper venue and mark it at the dear
    ///         venue's price, plus the fee/impact-aware `minAmountOut` for that input.
    /// @dev With dest reserves (r0 = WETH, r1 = HTRG), gamma = 0.997 and reference price
    ///      p_ref = (sDear/Q96)^2 (HTRG per WETH at the dear venue):
    ///        x* = r0 * (sqrt(gamma * (sDest/sDear)^2) - 1) / gamma
    ///           = r0 * (sqrt(gamma)*sDest - sDear) / (gamma * sDear)
    ///      Additive costs (gas, callback fee) do not shift the argmax, so we maximise gross here
    ///      and let the executor's realised fill decide whether the round clears.
    function optimalIn(uint256 r0, uint256 r1, uint256 sDest, uint256 sDear)
        public
        view
        returns (uint256 amountIn, uint256 minAmountOut)
    {
        if (r0 == 0 || r1 == 0 || sDest == 0 || sDear == 0) return (0, 0);
        uint256 w = Math.mulDiv(sqrtGammaQ96, sDest, Q96); // sqrt(gamma) * sDest
        if (w <= sDear) return (0, 0); // even the optimal size cannot beat the fee band
        uint256 t = Math.mulDiv(r0, w - sDear, sDear);
        uint256 x = Math.mulDiv(t, BPS, GAMMA_BPS); // x* = t / gamma
        if (x > maxTradeWeth) x = maxTradeWeth;
        if (x < minTradeWeth) return (0, 0); // too small to justify a callback

        uint256 inAfterFee = Math.mulDiv(x, GAMMA_BPS, BPS);
        uint256 out = Math.mulDiv(r1, inAfterFee, r0 + inAfterFee);
        minAmountOut = Math.mulDiv(out, BPS - slippageBps, BPS);
        return (x, minAmountOut);
    }

    /// @dev Closes the in-flight window when the executor reports the fast fill for the matching round.
    ///      `Fill(roundId indexed, arm indexed, ...)`: topic1 = roundId, topic2 = arm.
    function _onFill(LogRecord calldata log_) internal {
        Venue storage v = _venues[log_.chainId];
        if (v.executor == address(0) || log_.contractAddress != v.executor) return;
        if (log_.topic2 != 0) return; // only the fast arm (0) closes the window; ignore control
        if (inFlight && log_.topic1 == inFlightRoundId) {
            inFlight = false;
            emit LoopClosed(log_.topic1, block.timestamp);
        }
    }

    /// @notice Recovered reserves for a venue, rebuilt from its last (sqrtPriceX96, liquidity).
    function venueReserves(uint256 chainId_) external view returns (uint256 reserve0, uint256 reserve1) {
        Venue storage v = _venues[chainId_];
        return (v.reserve0, v.reserve1);
    }

    /// @dev Scans all watched venues and returns the routing decision:
    ///      - `destChainId`: venue with the highest sqrt price (cheapest HTRG) that can execute
    ///        (has an executor and non-zero reserves);
    ///      - `dearChainId`: venue with the lowest sqrt price (dearest HTRG) among observed venues,
    ///        used purely as the mark-to-market reference;
    ///      - `gapBps`: relative gap between the two.
    ///      Returns zeros when there is no executable destination or no gap.
    function _bestArb() internal view returns (uint256 destChainId, uint256 dearChainId, uint256 gapBps) {
        uint256 n = chainIds.length;
        uint160 bestPrice; // highest executable price => dest
        uint160 worstPrice; // lowest observed price => dear reference

        for (uint256 i = 0; i < n; ++i) {
            uint256 cid = chainIds[i];
            Venue storage v = _venues[cid];
            if (!v.observed || v.sqrtPriceX96 == 0) continue;

            if (worstPrice == 0 || v.sqrtPriceX96 < worstPrice) {
                worstPrice = v.sqrtPriceX96;
                dearChainId = cid;
            }
            if (v.executor != address(0) && v.reserve0 != 0 && v.reserve1 != 0) {
                if (v.sqrtPriceX96 > bestPrice) {
                    bestPrice = v.sqrtPriceX96;
                    destChainId = cid;
                }
            }
        }

        if (destChainId == 0 || worstPrice == 0 || bestPrice <= worstPrice) return (0, 0, 0);
        gapBps = _relativeGapBps(bestPrice, worstPrice);
    }

    /// @dev Recovers reserves from a V3 Swap event: liquidity L = sqrt(r0*r1), price p = r1/r0 = S^2/Q96^2,
    ///      so r0 = L*Q96/S and r1 = L*S/Q96. Zero fields leave the known reserves untouched.
    function _applySwap(Venue storage v, uint160 sqrtPrice, uint128 liquidity) private {
        if (sqrtPrice == 0 || liquidity == 0) return;
        v.reserve0 = Math.mulDiv(liquidity, Q96, sqrtPrice);
        v.reserve1 = Math.mulDiv(liquidity, sqrtPrice, Q96);
    }

    /// @dev ((hi / lo)^2 - 1) * 10000, computed via a Q18 ratio to avoid squaring sqrt prices.
    ///      Requires hi >= lo.
    function _relativeGapBps(uint160 hi, uint160 lo) internal pure returns (uint256) {
        uint256 ratio = (uint256(hi) * 1e18) / uint256(lo);
        uint256 ratioSquared = (ratio * ratio) / 1e18;
        return ((ratioSquared - 1e18) * BPS) / 1e18;
    }

    /// @notice Pays outstanding debt to the system contract from this contract's RNK balance.
    function coverDebt() external {
        _coverDebt();
    }
}
