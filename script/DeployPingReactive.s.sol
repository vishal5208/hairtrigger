// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {PingReactive} from "../src/PingReactive.sol";

/// @notice Deploys the measurement-only PingReactive on Lasna and optionally funds it with RNK.
/// @dev Env: PRIVATE_KEY, ORIGIN_CHAIN_ID, ORIGIN_TOKEN, DEST_CHAIN_ID, RNK_FUND (default 0).
contract DeployPingReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address originToken = vm.envAddress("ORIGIN_TOKEN");
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        uint256 rnkFund = vm.envOr("RNK_FUND", uint256(0));

        vm.startBroadcast(pk);
        PingReactive ping = new PingReactive{value: 0}(originChainId, originToken, destChainId);
        if (rnkFund != 0) {
            (bool ok,) = payable(address(ping)).call{value: rnkFund}("");
            require(ok, "RNK_FUND");
        }
        vm.stopBroadcast();

        console2.log("chainId   ", block.chainid);
        console2.log("PingReactive", address(ping));
        console2.log("originChain", originChainId);
        console2.log("originToken", originToken);
        console2.log("destChain ", destChainId);
        console2.log("RNK_FUND  ", rnkFund);
    }
}
