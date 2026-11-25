// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HairtriggerToken} from "../src/HairtriggerToken.sol";
import {MockPool} from "../src/MockPool.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Deploys HTRG + the WETH/HTRG pool on one chain and seeds it.
/// @dev Run once on Base Sepolia and once on Unichain Sepolia with the same seed amounts so the
///      two pools start at an identical price.
///      Env: PRIVATE_KEY, WETH, SEED_WETH (default 0.1e18), SEED_HTRG (default 1000e18).
contract DeployPool is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address weth = vm.envAddress("WETH");
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.1 ether));
        uint256 seedHtrg = vm.envOr("SEED_HTRG", uint256(1000 ether));

        vm.startBroadcast(pk);

        HairtriggerToken htrg = new HairtriggerToken(deployer);
        htrg.mint(deployer, 1_000_000 ether);

        IWETH(weth).deposit{value: seedWeth}();

        MockPool pool = new MockPool(weth, address(htrg));
        IERC20(weth).approve(address(pool), seedWeth);
        IERC20(address(htrg)).approve(address(pool), seedHtrg);
        pool.seed(seedWeth, seedHtrg);

        vm.stopBroadcast();

        console2.log("chainId       ", block.chainid);
        console2.log("HTRG          ", address(htrg));
        console2.log("MockPool      ", address(pool));
        console2.log("sqrtPriceX96  ", pool.sqrtPriceX96());
        console2.log("priceX1e18    ", pool.priceX1e18());
    }
}
