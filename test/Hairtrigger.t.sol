// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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
    uint256 private constant CHAIN_C = 11155111; // Eth Sepolia, used only for N-venue routing tests
    uint256 private constant SWAP_TOPIC0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    uint256 private constant FILL_TOPIC0 = 0x315b38b7541b63cbc5869731981e3329bb4a32919ba18156e7940439716ee671;
    address private constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 private constant Q96 = 1 << 96;

    uint256 private constant SEED_WETH = 0.5 ether;
    uint256 private constant SEED_HTRG = 5_000 ether;
    uint256 private constant TRADE_WETH = 0.002 ether;
    uint256 private constant MIN_TRADE_WETH = 0.0001 ether;
    uint256 private constant MAX_TRADE_WETH = 1 ether;

    HairtriggerToken private weth;
    HairtriggerToken private poolHtrg;

    MockPool private poolA;
    MockPool private poolB;
    uint160 private sp0;
    uint128 private liq;

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
        liq = uint128(Math.sqrt(SEED_WETH * SEED_HTRG)); // same as MockPool.liquidity at seed

        reactive = _deploy2(sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 30);
    }

    /// @dev Deploys a two-venue reactive over poolA/poolB with executors wired (A -> 0xEA1, B -> 0xEA2).
    function _deploy2(
        uint160 initialPrice,
        uint128 liquidity,
        uint256 threshold,
        uint256 minT,
        uint256 maxT,
        uint256 slip,
        uint64 cd
    ) private returns (HairtriggerReactive r) {
        uint256[] memory chains = new uint256[](2);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        address[] memory pools = new address[](2);
        pools[0] = address(poolA);
        pools[1] = address(poolB);
        r = new HairtriggerReactive(chains, pools, initialPrice, liquidity, threshold, minT, maxT, slip, cd);
        r.setExecutor(CHAIN_A, address(0xEA1));
        r.setExecutor(CHAIN_B, address(0xEA2));
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
        uint160 spA = uint160((uint256(sp0) * 98) / 100); // A ~2% cheaper HTRG -> buy on B
        uint256 gapBps = _gapBps(sp0, spA);
        assertGt(gapBps, 150);

        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        (uint256 expectedIn, uint256 minOut) = reactive.optimalIn(r0, r1, sp0, spA);
        assertGt(expectedIn, 0);

        vm.expectEmit(true, true, true, true, address(reactive));
        emit HairtriggerReactive.GapDetected(
            1, CHAIN_A, CHAIN_B, gapBps, spA, sp0, expectedIn, minOut, uint64(block.timestamp), 1, 0
        );

        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));

        assertEq(reactive.roundCounter(), 1);
        assertEq(reactive.lastFireAt(), block.timestamp);
    }

    function test_optimalInZeroInsideFeeBand() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        uint160 near = uint160((uint256(sp0) * 9_995) / 10_000); // ~0.05% below: inside the two-fee band
        (uint256 size,) = reactive.optimalIn(r0, r1, sp0, near);
        assertEq(size, 0, "no profitable size inside the fee band");
    }

    function test_optimalInGrowsWithGap() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        (uint256 wide,) = reactive.optimalIn(r0, r1, sp0, uint160((uint256(sp0) * 98) / 100));
        (uint256 narrow,) = reactive.optimalIn(r0, r1, sp0, uint160((uint256(sp0) * 99) / 100));
        assertGt(narrow, 0);
        assertGt(wide, narrow, "wider gap buys more");
    }

    function test_optimalInClampsToMax() public {
        uint256 cap = 0.003 ether;
        HairtriggerReactive tight = _deploy2(sp0, liq, 150, MIN_TRADE_WETH, cap, 300, 30);
        (uint256 r0, uint256 r1) = tight.venueReserves(CHAIN_B);
        (uint256 size,) = tight.optimalIn(r0, r1, sp0, uint160((uint256(sp0) * 90) / 100)); // very wide gap
        assertEq(size, cap, "clamped to maxTradeWeth");
    }

    function test_minAmountOutReflectsFeeAndImpact() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        uint160 sDear = uint160((uint256(sp0) * 98) / 100);
        (uint256 size, uint256 minOut) = reactive.optimalIn(r0, r1, sp0, sDear);
        assertGt(size, 0);

        // Spot-price output ignores fee + impact; the realised output must be strictly smaller.
        uint256 spotOut = Math.mulDiv(Math.mulDiv(size, sp0, Q96), sp0, Q96);
        uint256 inAfterFee = Math.mulDiv(size, 9_970, 10_000);
        uint256 realOut = Math.mulDiv(r1, inAfterFee, r0 + inAfterFee);
        assertLt(realOut, spotOut, "fee + impact reduce output below spot");
        assertEq(minOut, Math.mulDiv(realOut, 9_700, 10_000), "minOut = realised out less slippage");
    }

    function test_reserveRecoveryMatchesSeed() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_A);
        assertEq(r0, SEED_WETH, "recovered WETH reserve equals seed");
        assertEq(r1, SEED_HTRG, "recovered HTRG reserve equals seed");
    }

    function test_reactSkipsUnprofitableSizedGap() public {
        HairtriggerReactive lowThresh = _deploy2(sp0, liq, 1, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 30);
        uint160 spNear = uint160((uint256(sp0) * 9_995) / 10_000); // ~10 bps: clears threshold, below fee band
        assertGt(_gapBps(sp0, spNear), 1);

        vm.prank(SYSTEM_ADDR);
        lowThresh.react(_swapLog(CHAIN_A, address(poolA), spNear));
        assertEq(lowThresh.roundCounter(), 0, "gap clears threshold but has no profitable size");
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
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId_,
            contractAddress: pool_,
            topic0: SWAP_TOPIC0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(int256(0), int256(0), sqrtPrice_, liq, int24(0)),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _fillLog(uint256 chainId_, address exec_, uint256 roundId_, uint256 arm_)
        private
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId_,
            contractAddress: exec_,
            topic0: FILL_TOPIC0,
            topic1: roundId_,
            topic2: arm_,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function test_fillTopicMatchesSignature() public pure {
        assertEq(
            FILL_TOPIC0, uint256(keccak256("Fill(uint256,uint8,uint256,uint256,uint160,uint64,uint256)"))
        );
    }

    function _reactiveWithCooldown(uint64 cooldown_) private returns (HairtriggerReactive r) {
        r = _deploy2(sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, cooldown_);
    }

    function test_inFlightBlocksSecondTriggerUntilFill() public {
        HairtriggerReactive r = _reactiveWithCooldown(0); // no cooldown: isolate the in-flight lock
        uint160 spA = uint160((uint256(sp0) * 98) / 100);

        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA)); // dest = B
        assertEq(r.roundCounter(), 1);
        assertTrue(r.inFlight());
        assertEq(r.inFlightRoundId(), 1);

        // Same open gap again, cooldown elapsed — blocked by the in-flight window.
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(r.roundCounter(), 1, "in-flight blocks a second trigger");

        // The executors' fast Fill on the destination (B) closes the window.
        vm.prank(SYSTEM_ADDR);
        r.react(_fillLog(CHAIN_B, address(0xEA2), 1, 0));
        assertFalse(r.inFlight(), "fast fill closes the in-flight window");

        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(r.roundCounter(), 2, "after the fill, a new round can fire");
    }

    function test_controlFillDoesNotCloseInFlight() public {
        HairtriggerReactive r = _reactiveWithCooldown(0);
        uint160 spA = uint160((uint256(sp0) * 98) / 100);
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertTrue(r.inFlight());

        vm.prank(SYSTEM_ADDR);
        r.react(_fillLog(CHAIN_B, address(0xEA2), 1, 1)); // arm 1 = control, must not close
        assertTrue(r.inFlight(), "control fill leaves the fast window open");
    }

    function test_inFlightTimeoutReleases() public {
        HairtriggerReactive r = _reactiveWithCooldown(0);
        r.setInFlightTimeout(30);
        uint160 spA = uint160((uint256(sp0) * 98) / 100);
        vm.warp(1_000);

        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(r.roundCounter(), 1);

        vm.warp(1_029);
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(r.roundCounter(), 1, "still in flight one second before the timeout");

        vm.warp(1_030);
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(r.roundCounter(), 2, "after the timeout the open gap triggers again");
    }

    // ---------------------------------------------------------------------
    // Fuzz — sizing math invariants over arbitrary reserves and prices
    // ---------------------------------------------------------------------

    function testFuzz_optimalInRespectsBounds(uint256 r0, uint256 r1, uint256 sDest, uint256 sDear) public view {
        r0 = bound(r0, 1, 1e30);
        r1 = bound(r1, 1, 1e30);
        sDest = bound(sDest, 1e20, 1e40);
        sDear = bound(sDear, 1e20, 1e40);
        (uint256 size,) = reactive.optimalIn(r0, r1, sDest, sDear);
        assertLe(size, MAX_TRADE_WETH, "never above the cap");
        if (size != 0) assertGe(size, MIN_TRADE_WETH, "either skipped or at least the floor");
    }

    function testFuzz_zeroInsideFeeBand(uint256 r0, uint256 r1, uint256 sDear, uint256 bps) public view {
        r0 = bound(r0, 1e6, 1e30);
        r1 = bound(r1, 1e6, 1e30);
        sDear = bound(sDear, 1e22, 1e36);
        bps = bound(bps, 0, 14); // up to +0.14% — inside 1/sqrt(gamma)-1 (~0.1503%)
        uint256 sDest = sDear + (sDear * bps) / 10_000;
        (uint256 size,) = reactive.optimalIn(r0, r1, sDest, sDear);
        assertEq(size, 0, "inside the two-fee band the optimum is zero");
    }

    function testFuzz_optimalInMonotoneInDestPrice(uint256 r0, uint256 r1, uint256 sDear, uint256 m1, uint256 m2)
        public
        view
    {
        r0 = bound(r0, 1e12, 1e28);
        r1 = bound(r1, 1e12, 1e28);
        sDear = bound(sDear, 1e22, 1e34);
        m1 = bound(m1, 10_100, 20_000); // dest 1.01x..2.0x the dear price
        m2 = bound(m2, m1, 20_000); // wider gap
        (uint256 a,) = reactive.optimalIn(r0, r1, (sDear * m1) / 10_000, sDear);
        (uint256 b,) = reactive.optimalIn(r0, r1, (sDear * m2) / 10_000, sDear);
        assertGe(b, a, "a wider gap never sizes smaller");
    }

    function testFuzz_minAmountOutBelowSpot(uint256 liqFuzz, uint256 sDear, uint256 m) public view {
        uint256 liquidity = bound(liqFuzz, 1e18, 1e30);
        sDear = bound(sDear, 1e22, 1e34);
        m = bound(m, 10_100, 20_000);
        uint256 sDest = (sDear * m) / 10_000;

        // Reserves consistent with the dest price — the exact relation the reactive recovers from a
        // Swap log (r0 = L*Q96/S, r1 = L*S/Q96). Fuzzing them independently would compare against a
        // spot price the reserves do not actually imply.
        uint256 r0 = Math.mulDiv(liquidity, Q96, sDest);
        uint256 r1 = Math.mulDiv(liquidity, sDest, Q96);
        if (r0 == 0 || r1 == 0) return;

        (uint256 size, uint256 minOut) = reactive.optimalIn(r0, r1, sDest, sDear);
        if (size == 0) return;
        uint256 spotOut = Math.mulDiv(Math.mulDiv(size, sDest, Q96), sDest, Q96); // ignores fee + impact
        assertLe(minOut, spotOut, "guaranteed output is at or below the naive spot estimate");
        assertGt(minOut, 0);
    }

    // ---------------------------------------------------------------------
    // Adversarial / robustness scenarios
    // ---------------------------------------------------------------------

    function test_bothDirections() public {
        // origin = B, dest = A (B becomes dear, so we buy on A)
        uint160 spB = uint160((uint256(sp0) * 95) / 100);
        (uint256 a0, uint256 a1) = reactive.venueReserves(CHAIN_A);
        (uint256 expIn, uint256 expOut) = reactive.optimalIn(a0, a1, sp0, spB);
        assertGt(expIn, 0);
        uint256 gap = _gapBps(sp0, spB);

        vm.expectEmit(true, true, true, true, address(reactive));
        emit HairtriggerReactive.GapDetected(
            1, CHAIN_B, CHAIN_A, gap, spB, sp0, expIn, expOut, uint64(block.timestamp), 1, 0
        );
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_B, address(poolB), spB));
        assertEq(reactive.roundCounter(), 1);
    }

    function test_zeroPriceLogIgnored() public {
        // A malformed Swap log (sqrtPrice 0) must not fire nor corrupt the stored reserves.
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), 0));
        assertEq(reactive.roundCounter(), 0);
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_A);
        assertEq(r0, SEED_WETH);
        assertEq(r1, SEED_HTRG);
    }

    function test_killSwitchStopsFiring() public {
        uint160 spA = uint160((uint256(sp0) * 98) / 100);
        reactive.setPaused(true);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 0, "paused: no callback requested");
        assertTrue(reactive.paused());

        reactive.setPaused(false);
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 1, "unpaused fires again");
    }

    function test_killSwitchOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(HairtriggerReactive.OnlyOwner.selector, address(0xBEEF)));
        reactive.setPaused(true);
    }

    function test_failedCallbackRequestIsNotRecorded() public {
        // Make the system contract reject every callback request.
        vm.etch(SYSTEM_ADDR, hex"60006000fd"); // PUSH1 0x00 PUSH1 0x00 REVERT

        uint160 spA = uint160((uint256(sp0) * 98) / 100);
        vm.recordLogs();
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));

        // Nothing is committed: no round, no cooldown, no in-flight window.
        assertEq(reactive.roundCounter(), 0, "failed request must not consume a round");
        assertFalse(reactive.inFlight(), "failed request must not open the in-flight window");
        assertEq(reactive.lastFireAt(), 0, "failed request must not start the cooldown");

        // No phantom GapDetected (the keeper would wait 120s for a fill that can never come), but the
        // failure is surfaced.
        bool sawGap;
        bool sawFailure;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == HairtriggerReactive.GapDetected.selector) sawGap = true;
            if (logs[i].topics[0] == HairtriggerReactive.CallbackFailed.selector) sawFailure = true;
        }
        assertFalse(sawGap, "no phantom GapDetected on a rejected callback");
        assertTrue(sawFailure, "CallbackFailed must be emitted");

        // The price observation still landed (reserves recomputed at the new price) — the feed is kept.
        (uint256 r0,) = reactive.venueReserves(CHAIN_A);
        assertGt(r0, SEED_WETH, "venue price was still observed despite the failed request");
    }

    function test_retryAfterFailedCallbackReusesRoundId() public {
        vm.etch(SYSTEM_ADDR, hex"60006000fd");
        uint160 spA = uint160((uint256(sp0) * 98) / 100);

        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 0);

        // System recovers; the next tick fires with the same would-be round id — no cooldown penalty.
        vm.etch(SYSTEM_ADDR, hex"00");
        vm.prank(SYSTEM_ADDR);
        reactive.react(_swapLog(CHAIN_A, address(poolA), spA));
        assertEq(reactive.roundCounter(), 1, "retry succeeds and consumes round 1");
        assertTrue(reactive.inFlight());
        assertEq(reactive.inFlightRoundId(), 1);
    }

    /// @dev Gross profit of buying x WETH -> HTRG on the dest pool (r0,r1) and marking the HTRG at the
    ///      dear venue's price (sDear). Excludes gas/callback, which are additive and do not move the argmax.
    function _profit1(uint256 x, uint256 r0, uint256 r1, uint256 sDear) private pure returns (int256) {
        uint256 inAfterFee = Math.mulDiv(x, 9_970, 10_000);
        uint256 outHtrg = Math.mulDiv(r1, inAfterFee, r0 + inAfterFee);
        uint256 value = Math.mulDiv(Math.mulDiv(outHtrg, Q96, sDear), Q96, sDear); // out * Q96^2 / sDear^2
        return int256(value) - int256(x);
    }

    function test_dynamicBeatsFixedAtWideGap() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        uint160 sDear = uint160((uint256(sp0) * 90) / 100); // very wide gap
        (uint256 opt,) = reactive.optimalIn(r0, r1, sp0, sDear); // unclamped (MAX is 1 ether)
        assertGt(opt, TRADE_WETH, "optimum is larger than the old fixed size");
        assertGt(_profit1(opt, r0, r1, sDear), _profit1(TRADE_WETH, r0, r1, sDear), "sizing up beats fixed");
    }

    function test_fixedSizeOverTradesInsideFeeBand() public view {
        (uint256 r0, uint256 r1) = reactive.venueReserves(CHAIN_B);
        uint160 sDear = uint160((uint256(sp0) * 9_997) / 10_000); // inside the two-fee band
        (uint256 opt,) = reactive.optimalIn(r0, r1, sp0, sDear);
        assertEq(opt, 0, "optimum is to not trade");
        assertLt(_profit1(TRADE_WETH, r0, r1, sDear), 0, "fixed size loses gross money inside the band");
    }

    // ---------------------------------------------------------------------
    // N-venue routing
    // ---------------------------------------------------------------------

    function test_nVenueSkipsCheapestWithoutExecutor() public {
        MockPool poolC = _deploySeededPool();

        uint256[] memory chains = new uint256[](3);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        chains[2] = CHAIN_C;
        address[] memory pools = new address[](3);
        pools[0] = address(poolA);
        pools[1] = address(poolB);
        pools[2] = address(poolC);

        // Wide threshold so the intermediate price feeds stay quiet; only the final state fires.
        HairtriggerReactive r =
            new HairtriggerReactive(chains, pools, sp0, liq, 3000, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 0);
        // Executors on A and C only: B is a price source, not a venue we can trade on.
        r.setExecutor(CHAIN_A, address(0xEA1));
        r.setExecutor(CHAIN_C, address(0xEA3));

        uint160 spA = uint160((uint256(sp0) * 98) / 100); // A dear (low price)
        uint160 spB = uint160((uint256(sp0) * 140) / 100); // B cheapest overall, but no executor
        uint160 spC = uint160((uint256(sp0) * 130) / 100); // C cheapest *executable*

        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA));
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_B, address(poolB), spB)); // B is now the global max price
        assertEq(r.roundCounter(), 0, "B has no executor, so its wide price cannot fire");

        // Triggers with dest = C (cheapest place we can actually execute), not B.
        vm.expectEmit(true, true, true, false, address(r));
        emit HairtriggerReactive.GapDetected(1, CHAIN_C, CHAIN_C, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_C, address(poolC), spC));

        assertEq(r.roundCounter(), 1);
        assertEq(r.chainCount(), 3);
    }

    function test_nVenueRoutesToCheapestWhenExecutable() public {
        MockPool poolC = _deploySeededPool();

        uint256[] memory chains = new uint256[](3);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        chains[2] = CHAIN_C;
        address[] memory pools = new address[](3);
        pools[0] = address(poolA);
        pools[1] = address(poolB);
        pools[2] = address(poolC);

        HairtriggerReactive r =
            new HairtriggerReactive(chains, pools, sp0, liq, 3000, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 0);
        r.setExecutor(CHAIN_A, address(0xEA1));
        r.setExecutor(CHAIN_B, address(0xEA2));
        r.setExecutor(CHAIN_C, address(0xEA3));

        uint160 spA = uint160((uint256(sp0) * 98) / 100); // A dear
        uint160 spB = uint160((uint256(sp0) * 140) / 100); // B cheapest overall and executable

        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_A, address(poolA), spA)); // gap stays under the wide threshold
        assertEq(r.roundCounter(), 0);

        vm.expectEmit(true, true, true, false, address(r));
        emit HairtriggerReactive.GapDetected(1, CHAIN_B, CHAIN_B, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(CHAIN_B, address(poolB), spB));

        assertEq(r.roundCounter(), 1);
    }

    function test_constructorRejectsMismatchedArrays() public {
        uint256[] memory chains = new uint256[](2);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        address[] memory pools = new address[](1);
        pools[0] = address(poolA);
        vm.expectRevert("BAD_VENUES");
        new HairtriggerReactive(chains, pools, sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 30);
    }

    function test_constructorRejectsSingleVenue() public {
        uint256[] memory chains = new uint256[](1);
        chains[0] = CHAIN_A;
        address[] memory pools = new address[](1);
        pools[0] = address(poolA);
        vm.expectRevert("BAD_VENUES");
        new HairtriggerReactive(chains, pools, sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 30);
    }

    function test_constructorRejectsDuplicateChain() public {
        uint256[] memory chains = new uint256[](2);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_A;
        address[] memory pools = new address[](2);
        pools[0] = address(poolA);
        pools[1] = address(poolB);
        vm.expectRevert("DUP_CHAIN");
        new HairtriggerReactive(chains, pools, sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 30);
    }

    function _gapBps(uint160 hi, uint160 lo) private pure returns (uint256) {
        uint256 ratio = (uint256(hi) * 1e18) / uint256(lo);
        uint256 squared = (ratio * ratio) / 1e18;
        return ((squared - 1e18) * 10_000) / 1e18;
    }
}
