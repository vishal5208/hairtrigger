// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {PingReactive} from "../src/PingReactive.sol";

/// @notice Wires the PingExecutor address into PingReactive on Lasna.
/// @dev Env: PRIVATE_KEY, PING_REACTIVE, PING_TARGET.
contract SetPingTarget is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        PingReactive ping = PingReactive(payable(vm.envAddress("PING_REACTIVE")));
        address target = vm.envAddress("PING_TARGET");

        vm.startBroadcast(pk);
        ping.setTarget(target);
        vm.stopBroadcast();

        console2.log("PingReactive", address(ping));
        console2.log("target      ", target);
    }
}
