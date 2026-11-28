// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {IMockPool} from "../src/MockPool.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

/// @notice Deploys the callback executor on one chain and optionally funds it.
/// @dev Must run after the reactive contract exists (its address is pinned in the executor).
///      The callback proxy bills the executor in native ETH per callback; the executor also
///      needs WETH to swap. FUND_ETH and FUND_WETH cover both, in the same script run.
///      Each round spends up to 2 x MAX_TRADE_WETH (fast + control); trades are sized dynamically
///      per gap, so fund at least a few times MAX_TRADE_WETH of WETH for a run.
///      Env: PRIVATE_KEY, CALLBACK_PROXY, REACTIVE, WETH, POOL,
///           FUND_WETH (default 0), FUND_ETH (default 0).
contract DeployExecutor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPayable proxy = IPayable(payable(vm.envAddress("CALLBACK_PROXY")));
        address reactive = vm.envAddress("REACTIVE");
        address weth = vm.envAddress("WETH");
        IMockPool pool = IMockPool(vm.envAddress("POOL"));
        uint256 fundWeth = vm.envOr("FUND_WETH", uint256(0));
        uint256 fundEth = vm.envOr("FUND_ETH", uint256(0));

        vm.startBroadcast(pk);
        ArbExecutor executor = new ArbExecutor(proxy, reactive, weth, pool, deployer);
        if (fundWeth != 0) {
            IWETHDeposit(weth).deposit{value: fundWeth}();
            IERC20(weth).transfer(address(executor), fundWeth);
        }
        if (fundEth != 0) {
            (bool ok,) = payable(address(executor)).call{value: fundEth}("");
            require(ok, "ETH_FUND");
        }
        vm.stopBroadcast();

        console2.log("chainId   ", block.chainid);
        console2.log("Executor  ", address(executor));
        console2.log("reactive  ", reactive);
        console2.log("pool      ", address(pool));
        console2.log("FUND_WETH ", fundWeth);
        console2.log("FUND_ETH  ", fundEth);
    }
}
