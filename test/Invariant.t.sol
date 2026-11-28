// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {HairtriggerToken} from "../src/HairtriggerToken.sol";
import {MockPool} from "../src/MockPool.sol";
import {HairtriggerReactive} from "../src/HairtriggerReactive.sol";

/// @dev Stateful handler for the reactive contract. Drives random Swap logs, Fill logs, clock
///      advances and pause toggles, so the invariant runner explores interleavings of fires,
///      fast-fill closures, timeouts and the kill switch. Plain contract (not `Test`) so the
///      invariant runner only fuzzes these four actions.
contract ReactiveHandler {
    Vm private constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    uint256 private constant SWAP_TOPIC0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    uint256 private constant FILL_TOPIC0 = 0x315b38b7541b63cbc5869731981e3329bb4a32919ba18156e7940439716ee671;
    address private constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    HairtriggerReactive public immutable r;
    MockPool public immutable poolA;
    MockPool public immutable poolB;
    address public immutable owner;
    uint256 public immutable chainA;
    uint256 public immutable chainB;
    uint160 public immutable sp0;
    uint128 public immutable liq;
    address public immutable execA;
    address public immutable execB;

    constructor(
        HairtriggerReactive r_,
        MockPool poolA_,
        MockPool poolB_,
        address owner_,
        uint256 chainA_,
        uint256 chainB_,
        uint160 sp0_,
        uint128 liq_,
        address execA_,
        address execB_
    ) {
        r = r_;
        poolA = poolA_;
        poolB = poolB_;
        owner = owner_;
        chainA = chainA_;
        chainB = chainB_;
        sp0 = sp0_;
        liq = liq_;
        execA = execA_;
        execB = execB_;
    }

    /// @notice Feed a Swap log whose price sits anywhere in [0.5x, 1.5x] of the launch price.
    function swap(uint256 chainSeed, uint256 priceBps) external {
        uint256 chainId = chainSeed % 2 == 0 ? chainA : chainB;
        MockPool pool = chainId == chainA ? poolA : poolB;
        uint256 bps = _bound(priceBps, 5_000, 15_000);
        uint160 sp = uint160((uint256(sp0) * bps) / 10_000);
        if (sp == 0) return;
        vm.prank(SYSTEM_ADDR);
        r.react(_swapLog(chainId, address(pool), sp));
    }

    /// @notice Feed a Fill log. Bounded round/arm so some match the open window and some are noise.
    function fill(uint256 chainSeed, uint256 roundSeed, uint256 armSeed) external {
        uint256 chainId = chainSeed % 2 == 0 ? chainA : chainB;
        address exec = chainId == chainA ? execA : execB;
        uint256 roundId = roundSeed % (r.roundCounter() + 1);
        uint256 arm = armSeed % 2;
        vm.prank(SYSTEM_ADDR);
        r.react(_fillLog(chainId, exec, roundId, arm));
    }

    /// @notice Move the clock forward, so in-flight windows can time out.
    function advance(uint256 dt) external {
        vm.warp(block.timestamp + _bound(dt, 0, 40));
    }

    /// @notice Toggle the kill switch as the owner would.
    function togglePause(uint256 pick) external {
        vm.prank(owner);
        r.setPaused(pick % 2 == 1);
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

    function _bound(uint256 x, uint256 min, uint256 max) private pure returns (uint256) {
        return min + (x % (max - min + 1));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract HairtriggerInvariantTest is Test {
    uint256 private constant CHAIN_A = 84532;
    uint256 private constant CHAIN_B = 1301;
    address private constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address private constant EXEC_A = address(0xEA1);
    address private constant EXEC_B = address(0xEA2);

    uint256 private constant SEED_WETH = 0.5 ether;
    uint256 private constant SEED_HTRG = 5_000 ether;
    uint256 private constant MIN_TRADE_WETH = 0.0001 ether;
    uint256 private constant MAX_TRADE_WETH = 1 ether;

    HairtriggerReactive private r;
    ReactiveHandler private handler;

    function setUp() public {
        vm.etch(SYSTEM_ADDR, hex"00");

        HairtriggerToken weth = new HairtriggerToken(address(this));
        HairtriggerToken htrg = new HairtriggerToken(address(this));

        MockPool poolA = _seed(weth, htrg);
        MockPool poolB = _seed(weth, htrg);

        uint160 sp0 = poolA.sqrtPriceX96();
        uint128 liq = uint128(Math.sqrt(SEED_WETH * SEED_HTRG));

        uint256[] memory chains = new uint256[](2);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        address[] memory pools = new address[](2);
        pools[0] = address(poolA);
        pools[1] = address(poolB);

        // cooldown 0 so the invariant run isolates the in-flight lock and timeout, not the cooldown.
        r = new HairtriggerReactive(chains, pools, sp0, liq, 150, MIN_TRADE_WETH, MAX_TRADE_WETH, 300, 0);
        r.setExecutor(CHAIN_A, EXEC_A);
        r.setExecutor(CHAIN_B, EXEC_B);

        handler = new ReactiveHandler(r, poolA, poolB, address(this), CHAIN_A, CHAIN_B, sp0, liq, EXEC_A, EXEC_B);
        targetContract(address(handler));
    }

    function _seed(HairtriggerToken weth, HairtriggerToken htrg) private returns (MockPool pool) {
        pool = new MockPool(address(weth), address(htrg));
        weth.mint(address(this), SEED_WETH);
        htrg.mint(address(this), SEED_HTRG);
        weth.approve(address(pool), SEED_WETH);
        htrg.approve(address(pool), SEED_HTRG);
        pool.seed(SEED_WETH, SEED_HTRG);
    }

    /// @notice An open in-flight window always references the latest fired round, and was opened at
    ///         the last fire's timestamp (no path sets one without the other).
    function invariant_inFlightReferencesLatestRound() public view {
        if (r.inFlight()) {
            assertEq(r.inFlightRoundId(), r.roundCounter(), "open window must reference the latest round");
            assertEq(r.inFlightSince(), r.lastFireAt(), "window opens at the last fire timestamp");
        }
    }

    /// @notice A round and a fire timestamp come and go together: no rounds implies no fire time.
    function invariant_roundsAndFireTimestampAgree() public view {
        assertTrue(
            (r.roundCounter() == 0) == (r.lastFireAt() == 0), "roundCounter and lastFireAt must move together"
        );
    }

    /// @notice There is never an in-flight window without a round that opened it.
    function invariant_inFlightImpliesARound() public view {
        if (r.inFlight()) assertGt(r.roundCounter(), 0, "in-flight requires a round to exist");
    }

    /// @notice A round id never exceeds its ordinal: the window id is drawn from the same counter.
    function invariant_inFlightRoundAtMostCounter() public view {
        assertLe(r.inFlightRoundId(), r.roundCounter(), "in-flight id is drawn from roundCounter");
    }

    /// @notice Malformed/zero logs must never zero a venue's recovered reserves (gap math divides).
    function invariant_reservesStayNonZero() public view {
        (uint256 a0, uint256 a1) = r.venueReserves(CHAIN_A);
        (uint256 b0, uint256 b1) = r.venueReserves(CHAIN_B);
        assertGt(a0, 0, "chain A WETH reserve");
        assertGt(a1, 0, "chain A HTRG reserve");
        assertGt(b0, 0, "chain B WETH reserve");
        assertGt(b1, 0, "chain B HTRG reserve");
    }
}
