// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {HairtriggerToken} from "../src/HairtriggerToken.sol";
import {MockPool, IMockPool} from "../src/MockPool.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";
import {HairtriggerReactive} from "../src/HairtriggerReactive.sol";

contract HairtriggerTest is Test {
    uint256 private constant CHAIN_A = 84532; // Base Sepolia
    uint256 private constant CHAIN_B = 1301; // Unichain Sepolia
    uint256 private constant SWAP_TOPIC0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    address private constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 private constant Q96 = 1 << 96;

    uint256 private constant SEED_WETH = 0.5 ether;
    uint256 private constant SEED_HTRG = 5_000 ether;
    uint256 private constant TRADE_WETH = 0.002 ether;

    HairtriggerToken private weth;
    HairtriggerToken private poolHtrg;

    MockPool private poolA;
    MockPool private poolB;
    uint160 private sp0;

    HairtriggerReactive private reactive;

    function setUp() public {
        // The reactive constructor calls SYSTEM.subscribe; give it a no-op contract.
        vm.etch(SYSTEM_ADDR, hex"00");

        weth = new HairtriggerToken(address(this));
        poolHtrg = new HairtriggerToken(address(this));

        poolA = _deploySeededPool();
        poolB = _deploySeededPool();

        sp0 = poolA.sqrtPriceX96();
        assertEq(sp0, poolB.sqrtPriceX96(), "pools must start at the same price");

        reactive =
            new HairtriggerReactive(CHAIN_A, address(poolA), CHAIN_B, address(poolB), sp0, 150, TRADE_WETH, 300, 30);
        reactive.setExecutor(CHAIN_A, address(0xEA1));
        reactive.setExecutor(CHAIN_B, address(0xEA2));
    }

    function _deploySeededPool() private returns (MockPool pool) {
        pool = new MockPool(address(weth), address(poolHtrg));
        weth.mint(address(this), SEED_WETH);
        poolHtrg.mint(address(this), SEED_HTRG);
        weth.approve(address(pool), SEED_WETH);
        poolHtrg.approve(address(pool), SEED_HTRG);
        pool.seed(SEED_WETH, SEED_HTRG);
    }

    // ---------------------------------------------------------------------
    // Pool
    // ---------------------------------------------------------------------

    function test_poolEmitsCanonicalSwapTopic() public pure {
        assertEq(SWAP_TOPIC0, uint256(keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")));
    }

    function test_swapMovesPriceDownWhenBuyingHtrg() public {
        uint256 priceBefore = poolA.priceX1e18();
        uint160 spBefore = poolA.sqrtPriceX96();

        weth.mint(address(this), TRADE_WETH);
        weth.approve(address(poolA), TRADE_WETH);
        uint256 out = poolA.swap(true, TRADE_WETH, 0, address(this));

        assertLt(poolA.priceX1e18(), priceBefore, "price must fall");
        assertLt(poolA.sqrtPriceX96(), spBefore, "sqrt price must fall");
        assertGt(out, 0, "must receive HTRG");
        assertLt(out, TRADE_WETH * 10_000, "output must pay the fee and slippage");
    }

    function test_swapRevertsBelowMinOut() public {
        vm.expectRevert();
        poolA.swap(true, TRADE_WETH, type(uint256).max, address(this));
    }

    // ---------------------------------------------------------------------
    // Reactive
    // ---------------------------------------------------------------------

    function test_reactFiresOnGap() public {
        uint160 spA = uint160((uint256(sp0) * 98) / 100); // A ~2% cheaper HTRG
        uint256 gapBps = _gapBps(sp0, spA);
        assertGt(gapBps, 150);

        uint256 expectedOut = Math.mulDiv(Math.mulDiv(TRADE_WETH, sp0, Q96), sp0, Q96);
        uint256 minOut = (expectedOut * 9_700) / 10_000;

        vm.expectEmit(true, true, true, true, address(reactive));
        emit HairtriggerReactive.GapDetected(
            1, CHAIN_A, CHAIN_B, gapBps, spA, sp0, TRADE_WETH, minOut, uint64(block.timestamp), 1, 0
        );

        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));

        assertEq(reactive.roundCounter(), 1);
        assertEq(reactive.lastFireAt(), block.timestamp);
    }

    function test_reactRespectsCooldown() public {
        uint160 spA = uint160((uint256(sp0) * 98) / 100);

        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 1);

        // Same gap again inside the cooldown: the venue price updates but no callback.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 1);

        vm.warp(block.timestamp + 31);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 2);
    }

    function test_reactIgnoresSmallGap() public {
        uint160 spA = uint160((uint256(sp0) * 999) / 1000); // ~20 bps
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 0);
    }

    function test_reactIgnoresUnsubscribedChain() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(999, address(poolA), sp0));
        assertEq(reactive.roundCounter(), 0);
    }

    function test_reactOnlySystem() public {
        vm.expectRevert();
        reactive.react(_swapLog(CHAIN_A, address(poolA), sp0));
    }

    function _swapLog(uint256 chainId_, address pool_, uint160 sqrtPrice_)
        private
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId_,
            contractAddress: pool_,
            topic0: SWAP_TOPIC0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(int256(0), int256(0), sqrtPrice_, uint128(0), int24(0)),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _gapBps(uint160 hi, uint160 lo) private pure returns (uint256) {
        uint256 ratio = (uint256(hi) * 1e18) / uint256(lo);
        uint256 squared = (ratio * ratio) / 1e18;
        return ((squared - 1e18) * 10_000) / 1e18;
    }
}
