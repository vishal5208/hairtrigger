// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {HairtriggerReactive} from "../src/HairtriggerReactive.sol";

/// @notice Wires a destination executor into the reactive contract on Lasna. Run twice.
/// @dev Env: PRIVATE_KEY, REACTIVE, EXEC_CHAIN_ID, EXECUTOR.
contract SetExecutor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        HairtriggerReactive reactive = HairtriggerReactive(payable(vm.envAddress("REACTIVE")));
        uint256 chainId = vm.envUint("EXEC_CHAIN_ID");
        address executor = vm.envAddress("EXECUTOR");

        vm.startBroadcast(pk);
        reactive.setExecutor(chainId, executor);
        vm.stopBroadcast();

        console2.log("setExecutor", chainId, executor);
    }
}
