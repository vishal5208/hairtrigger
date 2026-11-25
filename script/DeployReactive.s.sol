// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HairtriggerReactive} from "../src/HairtriggerReactive.sol";

/// @notice Deploys the reactive contract on Lasna and optionally funds it with RNK in the same tx.
/// @dev Run from a Lasna RPC (https://lasna-rpc.rnk.dev). The initial sqrt price is derived from the
///      seed amounts and must match the seeded pools.
///      Env: PRIVATE_KEY, POOL_A, POOL_B, CHAIN_A (default 84532), CHAIN_B (default 1301),
///           SEED_WETH (default 0.1e18), SEED_HTRG (default 1000e18), THRESHOLD_BPS (default 150),
///           TRADE_WETH (default 0.0008e18 = 0.8% of the seed), SLIPPAGE_BPS (default 300),
///           COOLDOWN (default 30), RNK_FUND (optional, in wei).
contract DeployReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address poolA = vm.envAddress("POOL_A");
        address poolB = vm.envAddress("POOL_B");
        uint256 chainA = vm.envOr("CHAIN_A", uint256(84532));
        uint256 chainB = vm.envOr("CHAIN_B", uint256(1301));
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.1 ether));
        uint256 seedHtrg = vm.envOr("SEED_HTRG", uint256(1000 ether));
        uint256 thresholdBps = vm.envOr("THRESHOLD_BPS", uint256(150));
        uint256 tradeWeth = vm.envOr("TRADE_WETH", uint256(0.0008 ether));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(300));
        uint64 cooldown = uint64(vm.envOr("COOLDOWN", uint256(30)));
        uint256 rnkFund = vm.envOr("RNK_FUND", uint256(0));

        // Same formula as MockPool.sqrtPriceX96(): both tokens are 18 decimals.
        uint256 p = Math.mulDiv(seedHtrg, uint256(1) << 96, seedWeth);
        uint160 initialSqrtPrice = uint160(Math.sqrt(p) * (uint256(1) << 48));

        vm.startBroadcast(pk);
        HairtriggerReactive reactive = new HairtriggerReactive{value: rnkFund}(
            chainA, poolA, chainB, poolB, initialSqrtPrice, thresholdBps, tradeWeth, slippageBps, cooldown
        );
        vm.stopBroadcast();

        console2.log("Reactive          ", address(reactive));
        console2.log("initialSqrtPrice  ", initialSqrtPrice);
        console2.log("thresholdBps      ", thresholdBps);
        console2.log("tradeWeth         ", tradeWeth);
        console2.log("RNK funded (wei)  ", rnkFund);
    }
}
