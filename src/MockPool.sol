// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sqrtPriceX96() external view returns (uint160);
    function priceX1e18() external view returns (uint256);
    function swap(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
}

/// @title MockPool
/// @notice Minimal constant-product pool for WETH/HTRG, deployed identically on both chains.
/// @dev Emits the canonical Uniswap V3 `Swap` event so the reactive contract decodes it with the
///      same code path a real V3 pool would need. This pool is intentionally NOT a real Uniswap
///      pool: token0 is always WETH and token1 is always HTRG (no address sorting), so the price
///      direction is identical on both chains. The `liquidity` and `tick` fields are informational
///      only; `tick` is emitted as 0 and nothing in the system reads it.
contract MockPool is IMockPool {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 30; // 0.30%, same as the Uniswap V3 0.3% tier
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;

    /// @notice WETH side (canonical token0).
    address public immutable override token0;
    /// @notice HTRG side (canonical token1).
    address public immutable override token1;

    uint256 public reserve0;
    uint256 public reserve1;

    /// @dev Same signature and topic0 as the canonical Uniswap V3 pool event.
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    event Seeded(uint256 reserve0, uint256 reserve1);

    error AlreadySeeded();
    error ZeroAmount();
    error NoLiquidity();
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    constructor(address token0_, address token1_) {
        require(token0_ != address(0) && token1_ != address(0) && token0_ != token1_, "BAD_TOKENS");
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Pulls initial liquidity. Callable once, permissionlessly.
    function seed(uint256 amount0_, uint256 amount1_) external {
        if (reserve0 != 0 || reserve1 != 0) revert AlreadySeeded();
        if (amount0_ == 0 || amount1_ == 0) revert ZeroAmount();

        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0_);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1_);

        reserve0 = amount0_;
        reserve1 = amount1_;
        emit Seeded(amount0_, amount1_);
    }

    /// @notice Sells `amountIn` of token0 for token1 (`zeroForOne == true`) or the reverse.
    /// @dev Fee is charged on the input. Output is sent to `to`.
    function swap(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        if (reserveIn == 0 || reserveOut == 0) revert NoLiquidity();

        uint256 inAfterFee = (amountIn * (BPS - FEE_BPS)) / BPS;
        amountOut = (reserveOut * inAfterFee) / (reserveIn + inAfterFee);
        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        uint160 sp = sqrtPriceX96();
        emit Swap(
            msg.sender,
            to,
            zeroForOne ? int256(amountIn) : -int256(amountOut),
            zeroForOne ? -int256(amountOut) : int256(amountIn),
            sp,
            uint128(Math.sqrt(Math.mulDiv(reserve0, reserve1, 1))),
            int24(0)
        );
    }

    /// @notice Spot price as sqrt(token1/token0) * 2^96, i.e. sqrt(HTRG per WETH) * 2^96.
    function sqrtPriceX96() public view override returns (uint160) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        // price = reserve1 / reserve0 (raw units, both tokens are 18 decimals)
        // sqrtPriceX96 = sqrt(price) * 2^96 = sqrt(price * 2^96) * 2^48
        uint256 p = Math.mulDiv(reserve1, Q96, reserve0);
        return uint160(Math.sqrt(p) * (1 << 48));
    }

    /// @notice Spot price in HTRG per WETH, scaled by 1e18. Convenience for scripts and tests.
    function priceX1e18() external view returns (uint256) {
        if (reserve0 == 0) return 0;
        return Math.mulDiv(reserve1, 1e18, reserve0);
    }
}
