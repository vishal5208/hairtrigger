// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HairtriggerReactive} from "../src/HairtriggerReactive.sol";

/// @notice Deploys the reactive contract on Lasna and optionally funds it with RNK in the same tx.
/// @dev Run from a Lasna RPC (https://lasna-rpc.rnk.dev). The initial sqrt price and liquidity are
///      derived from the seed amounts and MUST match the seeded pools; set SEED_WETH/SEED_HTRG
///      explicitly to the values the pools were seeded with rather than relying on the defaults.
///      Env: PRIVATE_KEY, POOL_A, POOL_B, CHAIN_A (default 84532), CHAIN_B (default 1301),
///           SEED_WETH (default 0.1e18), SEED_HTRG (default 1000e18), THRESHOLD_BPS (default 150),
///           MIN_TRADE_WETH (default 0.0002e18), MAX_TRADE_WETH (default 0.05e18),
///           SLIPPAGE_BPS (default 300), COOLDOWN (default 30), RNK_FUND (optional, in wei).
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
        uint256 minTradeWeth = vm.envOr("MIN_TRADE_WETH", uint256(0.0002 ether));
        uint256 maxTradeWeth = vm.envOr("MAX_TRADE_WETH", uint256(0.05 ether));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(300));
        uint64 cooldown = uint64(vm.envOr("COOLDOWN", uint256(30)));
        uint256 rnkFund = vm.envOr("RNK_FUND", uint256(0));

        // Same formulas as MockPool: sqrtPriceX96 = sqrt(HTRG/WETH)*2^96, liquidity = floor(sqrt(r0*r1)).
        uint256 p = Math.mulDiv(seedHtrg, uint256(1) << 96, seedWeth);
        uint160 initialSqrtPrice = uint160(Math.sqrt(p) * (uint256(1) << 48));
        uint128 initialLiquidity = uint128(Math.sqrt(Math.mulDiv(seedWeth, seedHtrg, 1)));

        // The reactive routes across N venues given as index-aligned arrays. This two-chain env
        // interface covers the live Base/Unichain deployment; add more pairs here to watch more
        // chains with one contract. All pools are seeded identically, so they share a launch price.
        uint256[] memory chains = new uint256[](2);
        chains[0] = chainA;
        chains[1] = chainB;
        address[] memory pools = new address[](2);
        pools[0] = poolA;
        pools[1] = poolB;

        vm.startBroadcast(pk);
        HairtriggerReactive reactive = new HairtriggerReactive{value: rnkFund}(
            chains, pools, initialSqrtPrice, initialLiquidity, thresholdBps, minTradeWeth, maxTradeWeth, slippageBps, cooldown
        );
        vm.stopBroadcast();

        console2.log("Reactive          ", address(reactive));
        console2.log("initialSqrtPrice  ", initialSqrtPrice);
        console2.log("initialLiquidity  ", initialLiquidity);
        console2.log("thresholdBps      ", thresholdBps);
        console2.log("minTradeWeth      ", minTradeWeth);
        console2.log("maxTradeWeth      ", maxTradeWeth);
        console2.log("RNK funded (wei)  ", rnkFund);
    }
}
