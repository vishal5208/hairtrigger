// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title HairtriggerReactive
/// @notice Reactive contract on Lasna. Watches the same WETH/HTRG pool on Base Sepolia and
///         Unichain Sepolia. When the two observed prices diverge by more than the cost threshold,
///         it requests a callback on the venue where HTRG is cheaper, in the same second.
/// @dev Price is carried in the canonical Uniswap V3 Swap event's `sqrtPriceX96` field:
///      sqrt(HTRG per WETH) * 2^96. Both pools are ours and use the same token roles on both
///      chains, so the two values are directly comparable. All timing uses block.timestamp;
///      block numbers are logged for joins only and never used for delay math.
contract HairtriggerReactive is AbstractReactive {
    /// @dev keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")
    uint256 private constant SWAP_TOPIC0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10_000;
    uint64 private constant CALLBACK_GAS_LIMIT = 400_000;

    struct Venue {
        address pool;
        address executor;
        bool observed;
        uint160 sqrtPriceX96;
        uint64 lastUpdatedAt;
    }

    uint256 public immutable chainA;
    uint256 public immutable chainB;

    address public owner;
    uint256 public immutable thresholdBps;
    uint256 public immutable amountIn;
    uint256 public immutable slippageBps;
    uint64 public immutable cooldown;

    uint256 public roundCounter;
    uint256 public lastFireAt;

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

    error OnlyOwner(address caller_);

    constructor(
        uint256 chainA_,
        address poolA_,
        uint256 chainB_,
        address poolB_,
        uint160 initialSqrtPriceX96_,
        uint256 thresholdBps_,
        uint256 amountIn_,
        uint256 slippageBps_,
        uint64 cooldown_
    ) payable {
        require(chainA_ != 0 && chainB_ != 0 && chainA_ != chainB_, "BAD_CHAINS");
        require(poolA_ != address(0) && poolB_ != address(0), "BAD_POOLS");
        require(initialSqrtPriceX96_ != 0, "BAD_PRICE");
        require(thresholdBps_ != 0 && thresholdBps_ <= BPS, "BAD_THRESHOLD");
        require(amountIn_ != 0, "BAD_AMOUNT");
        require(slippageBps_ < BPS, "BAD_SLIPPAGE");

        owner = msg.sender;
        chainA = chainA_;
        chainB = chainB_;
        thresholdBps = thresholdBps_;
        amountIn = amountIn_;
        slippageBps = slippageBps_;
        cooldown = cooldown_;

        _venues[chainA_] = Venue(poolA_, address(0), true, initialSqrtPriceX96_, uint64(block.timestamp));
        _venues[chainB_] = Venue(poolB_, address(0), true, initialSqrtPriceX96_, uint64(block.timestamp));

        SYSTEM.subscribe(chainA_, poolA_, SWAP_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainB_, poolB_, SWAP_TOPIC0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Sets the destination executor for a chain. Executors cannot be known before the
    ///         reactive contract exists (their constructor pins this address), so this is a
    ///         one-time wiring step after both are deployed.
    function setExecutor(uint256 chainId_, address executor_) external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        Venue storage venue = _venues[chainId_];
        require(venue.pool != address(0), "UNKNOWN_CHAIN");
        venue.executor = executor_;
        emit ExecutorSet(chainId_, executor_);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        Venue storage venue = _venues[log_.chainId];
        if (venue.pool == address(0) || log_.contractAddress != venue.pool || log_.topic0 != SWAP_TOPIC0) {
            return;
        }
        if (log_.data.length < 160) return;

        // Uniswap V3 Swap data: (int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)
        (,, uint160 sqrtPrice,,) = abi.decode(log_.data, (int256, int256, uint160, uint128, int24));

        venue.sqrtPriceX96 = sqrtPrice;
        venue.lastUpdatedAt = uint64(block.timestamp);
        venue.observed = true;

        emit VenueUpdated(log_.chainId, sqrtPrice, uint64(block.timestamp));

        uint256 otherChainId = log_.chainId == chainA ? chainB : chainA;
        Venue storage other = _venues[otherChainId];
        if (!other.observed) return;

        (uint256 gapBps, uint256 destChainId, uint160 destPrice) =
            _gap(log_.chainId, sqrtPrice, otherChainId, other.sqrtPriceX96);
        if (gapBps < thresholdBps) return;
        if (lastFireAt != 0 && block.timestamp < lastFireAt + cooldown) return;

        Venue storage dest = _venues[destChainId];
        if (dest.executor == address(0)) return;

        // Output expected at the destination's last observed price. The slippage tolerance covers
        // the pool fee and any drift between the observed price and execution.
        uint256 expectedOut = Math.mulDiv(Math.mulDiv(amountIn, destPrice, Q96), destPrice, Q96);
        uint256 minAmountOut = (expectedOut * (BPS - slippageBps)) / BPS;
        if (minAmountOut == 0) return;

        uint256 roundId = ++roundCounter;
        uint64 detectedAt = uint64(block.timestamp);

        bytes memory payload = abi.encodeWithSignature(
            "onArb(address,uint256,uint256,uint256,uint64)", address(0), roundId, amountIn, minAmountOut, detectedAt
        );

        lastFireAt = block.timestamp;

        try SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: dest.executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
            })
        ) {}
            catch {}

        emit GapDetected(
            roundId,
            log_.chainId,
            destChainId,
            gapBps,
            sqrtPrice,
            other.sqrtPriceX96,
            amountIn,
            minAmountOut,
            detectedAt,
            log_.blockNumber,
            log_.txHash
        );
    }

    /// @dev Returns the gap in bps relative to the cheaper venue, and the venue (chain + price)
    ///      where HTRG trades cheapest, i.e. the destination to buy on.
    function _gap(uint256 originChainId, uint160 originPrice, uint256 otherChainId, uint160 otherPrice)
        internal
        pure
        returns (uint256 gapBps, uint256 destChainId, uint160 destPrice)
    {
        if (originPrice >= otherPrice) {
            return (_relativeGapBps(originPrice, otherPrice), originChainId, originPrice);
        }
        return (_relativeGapBps(otherPrice, originPrice), otherChainId, otherPrice);
    }

    /// @dev ((hi / lo)^2 - 1) * 10000, computed via a Q18 ratio to avoid squaring sqrt prices.
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
