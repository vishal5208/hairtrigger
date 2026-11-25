// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IMockPool} from "./MockPool.sol";

/// @title ArbExecutor
/// @notice Destination-chain executor for Hairtrigger. Deployed identically on Base Sepolia and
///         Unichain Sepolia. Executes a single buy of HTRG with WETH on the local pool.
/// @dev Two entry points share one execution path:
///      - `onArb` is only reachable through the callback proxy, from the Hairtrigger reactive contract.
///      - `runControl` is the control arm: the owner submits the identical trade >= 7 seconds after
///        detection. It executes unconditionally (no minOut) so the realized fill is measurable;
///        whether that fill still clears cost is scored off-chain. A shared minOut would make the
///        control outcome a step function of slippage tolerance instead of a measurement.
contract ArbExecutor is AbstractCallback {
    using SafeERC20 for IERC20;

    uint64 public constant CONTROL_DELAY = 7;

    /// @notice Canonical token0 of the pool; the executor always pays token0 and receives token1.
    address public immutable weth;
    IMockPool public immutable pool;
    address public immutable owner;

    event Fill(
        uint256 indexed roundId,
        uint8 indexed arm,
        uint256 amountIn,
        uint256 amountOut,
        uint160 postSqrtPriceX96,
        uint64 detectedAt,
        uint256 filledAt
    );

    error NotOwner(address caller_);
    error TooEarly(uint256 now_, uint256 allowedAt_);

    constructor(IPayable callbackProxy_, address callbackSender_, address weth_, IMockPool pool_, address owner_)
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        require(weth_ != address(0) && address(pool_) != address(0) && owner_ != address(0), "BAD_ARGS");
        require(pool_.token0() == weth_, "TOKEN0_NOT_WETH");

        weth = weth_;
        pool = pool_;
        owner = owner_;

        IERC20(weth_).forceApprove(address(pool_), type(uint256).max);
    }

    /// @notice Fast arm. Called by the Reactive Network callback proxy with the requesting reactive
    ///         contract injected as the first payload argument.
    function onArb(address reactive_, uint256 roundId_, uint256 amountIn_, uint256 minAmountOut_, uint64 detectedAt_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        _trade(roundId_, 0, amountIn_, minAmountOut_, detectedAt_);
    }

    /// @notice Control arm. Held >= 7 seconds after detection, submitted by the keeper.
    /// @dev Deliberately executes with `minAmountOut == 0`: the point is to measure what the same
    ///      trade would actually fill at 7 seconds late, not to gate it.
    function runControl(uint256 roundId_, uint256 amountIn_, uint64 detectedAt_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);

        uint256 allowedAt = uint256(detectedAt_) + CONTROL_DELAY;
        if (block.timestamp < allowedAt) revert TooEarly(block.timestamp, allowedAt);

        _trade(roundId_, 1, amountIn_, 0, detectedAt_);
    }

    function _trade(uint256 roundId_, uint8 arm_, uint256 amountIn_, uint256 minAmountOut_, uint64 detectedAt_)
        internal
    {
        uint256 amountOut = pool.swap(true, amountIn_, minAmountOut_, address(this));
        emit Fill(roundId_, arm_, amountIn_, amountOut, pool.sqrtPriceX96(), detectedAt_, block.timestamp);
    }

    /// @notice Pays any outstanding callback debt the proxy has recorded against this contract.
    function coverDebt() external {
        _coverDebt();
    }
}
