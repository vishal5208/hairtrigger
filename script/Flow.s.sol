// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMockPool} from "../src/MockPool.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

/// @notice Generates synthetic flow: wraps ETH and swaps it on one pool to open a gap.
/// @dev This is the disclosed flow generator. It is the only source of swaps on these testnets.
///      FLOW_WETH defaults to 1.2% of the 0.1 WETH seed, which opens a ~240 bps gap. Sizes of
///      0.8%-2.0% of the seed produce ~160-400 bps gaps.
///      Env: PRIVATE_KEY, POOL, WETH, FLOW_WETH (default 0.0012e18),
///           ZERO_FOR_ONE (default true; true = buy HTRG with WETH).
contract Flow is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        IMockPool pool = IMockPool(vm.envAddress("POOL"));
        address weth = vm.envAddress("WETH");
        uint256 amount = vm.envOr("FLOW_WETH", uint256(0.0012 ether));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        vm.startBroadcast(pk);
        IWETHDeposit(weth).deposit{value: amount}();
        IERC20(weth).approve(address(pool), amount);
        uint256 out = pool.swap(zeroForOne, amount, 0, deployer);
        vm.stopBroadcast();

        console2.log("swap amountIn ", amount);
        console2.log("swap amountOut", out);
        console2.log("post sqrtPrice", pool.sqrtPriceX96());
        console2.log("post price    ", pool.priceX1e18());
    }
}
