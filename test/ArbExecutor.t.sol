// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {HairtriggerToken} from "../src/HairtriggerToken.sol";
import {MockPool, IMockPool} from "../src/MockPool.sol";
import {ArbExecutor} from "../src/ArbExecutor.sol";

contract ArbExecutorTest is Test {
    address private constant PROXY = address(0xBEEF);
    address private constant REACTIVE = address(0x9EAC7);
    uint256 private constant TRADE_WETH = 0.002 ether;

    HairtriggerToken private weth;
    HairtriggerToken private htrg;
    MockPool private pool;
    ArbExecutor private executor;

    function setUp() public {
        weth = new HairtriggerToken(address(this));
        htrg = new HairtriggerToken(address(this));

        pool = new MockPool(address(weth), address(htrg));
        weth.mint(address(this), 0.5 ether);
        htrg.mint(address(this), 5_000 ether);
        weth.approve(address(pool), 0.5 ether);
        htrg.approve(address(pool), 5_000 ether);
        pool.seed(0.5 ether, 5_000 ether);

        executor =
            new ArbExecutor(IPayable(payable(PROXY)), REACTIVE, address(weth), IMockPool(address(pool)), address(this));
        weth.mint(address(executor), 1 ether);
    }

    function test_fastArmFills() public {
        vm.expectEmit(true, true, false, false, address(executor));
        emit ArbExecutor.Fill(1, 0, 0, 0, 0, 0, 0);

        vm.prank(PROXY);
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, uint64(block.timestamp));

        assertGt(htrg.balanceOf(address(executor)), 0);
    }

    function test_fastArmRejectsNonProxyCaller() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(0xCAFE), PROXY));
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, uint64(block.timestamp));
    }

    function test_fastArmRejectsWrongReactive() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xB0B), REACTIVE)
        );
        executor.onArb(address(0xB0B), 1, TRADE_WETH, 0, uint64(block.timestamp));
    }

    function test_controlRejectsNonOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.NotOwner.selector, address(0xB0B)));
        executor.runControl(2, TRADE_WETH, uint64(block.timestamp));
    }

    function test_controlRevertsBeforeSevenSeconds() public {
        uint64 detectedAt = uint64(block.timestamp);
        vm.warp(uint256(detectedAt) + 6);
        vm.expectRevert(
            abi.encodeWithSelector(ArbExecutor.TooEarly.selector, uint256(detectedAt) + 6, uint256(detectedAt) + 7)
        );
        executor.runControl(2, TRADE_WETH, detectedAt);
    }

    function test_controlFillsAtSevenSecondsAndPairedFillIsWorse() public {
        uint64 detectedAt = uint64(block.timestamp);

        // Fast arm captures the gap.
        vm.prank(PROXY);
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, detectedAt);
        uint256 outFast = htrg.balanceOf(address(executor));
        assertGt(outFast, 0);

        // Control arm executes the identical trade 7 seconds later, unconditionally.
        vm.warp(uint256(detectedAt) + 7);
        vm.expectEmit(true, true, false, false, address(executor));
        emit ArbExecutor.Fill(1, 1, 0, 0, 0, 0, 0);
        executor.runControl(1, TRADE_WETH, detectedAt);

        uint256 outControl = htrg.balanceOf(address(executor)) - outFast;
        assertLt(outControl, outFast, "7s-late fill must be worse than the 1s fill");
    }

    function test_duplicateFastCallbackReverts() public {
        uint64 detectedAt = uint64(block.timestamp);
        vm.prank(PROXY);
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, detectedAt);

        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.AlreadyFilled.selector, 1, 0));
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, detectedAt);
    }

    function test_fastAndControlSameRoundAreIndependent() public {
        uint64 detectedAt = uint64(block.timestamp);
        vm.prank(PROXY);
        executor.onArb(REACTIVE, 7, TRADE_WETH, 0, detectedAt); // arm 0

        vm.warp(uint256(detectedAt) + 7);
        executor.runControl(7, TRADE_WETH, detectedAt); // arm 1, same round, allowed
        assertTrue(executor.filled(7, 0));
        assertTrue(executor.filled(7, 1));
    }

    function test_lateCallbackRevertsWhenPriceMovedPastMinOut() public {
        uint64 detectedAt = uint64(block.timestamp);

        // The reactive priced the trade at the pre-move spot and set this as its floor.
        uint256 minOut = _quoteOut(TRADE_WETH);

        // Somebody (a competing arb, or the flow) moves the pool before our callback lands,
        // so the exact same trade now yields less than that floor.
        weth.mint(address(this), 0.1 ether);
        weth.approve(address(pool), 0.1 ether);
        pool.swap(true, 0.1 ether, 0, address(this));
        assertLt(_quoteOut(TRADE_WETH), minOut, "the move lowered the achievable output");

        vm.prank(PROXY);
        vm.expectRevert(); // MockPool.SlippageExceeded — the stale trade no longer clears its floor
        executor.onArb(REACTIVE, 9, TRADE_WETH, minOut, detectedAt);

        // Nothing was recorded: the round is still available to fill at a revised price.
        assertFalse(executor.filled(9, 0));
    }

    /// @dev Constant-product output for selling `amountIn` token0 at the pool's current reserves.
    function _quoteOut(uint256 amountIn) private view returns (uint256) {
        uint256 r0 = MockPool(address(pool)).reserve0();
        uint256 r1 = MockPool(address(pool)).reserve1();
        uint256 inAfterFee = (amountIn * 9_970) / 10_000;
        return (r1 * inAfterFee) / (r0 + inAfterFee);
    }

    function test_killSwitchBlocksBothArms() public {
        executor.setPaused(true);

        vm.prank(PROXY);
        vm.expectRevert(ArbExecutor.Paused.selector);
        executor.onArb(REACTIVE, 1, TRADE_WETH, 0, uint64(block.timestamp));

        uint64 detectedAt = uint64(block.timestamp);
        vm.warp(uint256(detectedAt) + 7);
        vm.expectRevert(ArbExecutor.Paused.selector);
        executor.runControl(1, TRADE_WETH, detectedAt);
    }

    function test_killSwitchOnlyOwner() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(ArbExecutor.NotOwner.selector, address(0xB0B)));
        executor.setPaused(true);
    }
}
