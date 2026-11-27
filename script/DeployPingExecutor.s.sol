// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {PingExecutor} from "../src/PingExecutor.sol";

/// @notice Deploys the measurement-only PingExecutor on the destination chain and optionally funds it.
/// @dev Env: PRIVATE_KEY, CALLBACK_PROXY, PING_REACTIVE, FUND_ETH (default 0).
contract DeployPingExecutor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IPayable proxy = IPayable(payable(vm.envAddress("CALLBACK_PROXY")));
        address pingReactive = vm.envAddress("PING_REACTIVE");
        uint256 fundEth = vm.envOr("FUND_ETH", uint256(0));

        vm.startBroadcast(pk);
        PingExecutor executor = new PingExecutor(proxy, pingReactive);
        if (fundEth != 0) {
            (bool ok,) = payable(address(executor)).call{value: fundEth}("");
            require(ok, "ETH_FUND");
        }
        vm.stopBroadcast();

        console2.log("chainId   ", block.chainid);
        console2.log("PingExecutor", address(executor));
        console2.log("pingReactive", pingReactive);
        console2.log("FUND_ETH  ", fundEth);
    }
}
