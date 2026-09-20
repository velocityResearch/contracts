// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {IAcrossSpokePool} from "../../src/interfaces/IAcrossSpokePool.sol";

/// @notice Dry run of the live gen-6 sUSDai bridge against the deployed contracts, not fresh
///         ones: would a bridge succeed today if the keeper were started?
///
///         Both halves fork the head of a public RPC and assert on deltas, because neither
///         endpoint is an archive node and the live position moves.
///
///         Reproduce:
///         forge test --match-path 'test/susdai/LiveSUSDaiBridgeDryRunFork.t.sol' -vv
contract LiveSUSDaiBridgeOutForkTest is Test {
    address constant ADAPTER = 0x460f319E43428387bff58ec262C992Ec7DA22fDc;
    address constant RESERVE = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address constant HUB = 0x740ddd200D9Ee605F25239Ba701bdd89161034b1;
    uint256 constant ARBITRUM = 42161;

    SUSDaiYieldSource adapter = SUSDaiYieldSource(ADAPTER);
    IERC20 usdg = IERC20(USDG);
    address keeper;
    /// @dev Cached in `setUp`: a `vm.prank` applies to the NEXT call, so a helper that reads
    ///      the adapter while building a quote would spend the prank on that read.
    uint16 feeBps;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"))
        );
        keeper = adapter.keeper();
        feeBps = adapter.maxBridgeFeeBps();
    }

    /// @dev The floor `AcrossBridger` enforces: input less `maxBridgeFeeBps`. A real quote pays
    ///      better (~6 bps observed); quoting exactly at the floor is the worst fill that clears.
    function _quoteAtFloor(uint256 amount)
        internal
        view
        returns (AcrossBridger.AcrossQuote memory)
    {
        uint256 output = amount - amount * feeBps / 10_000;
        return AcrossBridger.AcrossQuote({
            outputAmount: output,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 2 hours),
            exclusivityDeadline: 0
        });
    }

    function test_theWiringIsWhatTheManifestClaims() public view {
        assertEq(adapter.controller(), RESERVE, "bound to the live reserve");
        assertEq(adapter.hub(), HUB, "delivers to the hub");
        assertEq(adapter.hubChainId(), ARBITRUM, "on Arbitrum");
        assertEq(address(adapter.spokePool()), SPOKE_POOL, "through the live SpokePool");
        assertGt(adapter.maxBridgeAmount(), 0, "outbound is not fail-closed");
        assertGt(adapter.bridgeBudgetRemaining(), 0, "the daily budget has room");
    }

    /// @dev The USDG `bridgeOut` insists on leaving here for redeemers: the greater of the bps
    ///      share of the position and the absolute floor, exactly as the adapter computes it.
    function _bufferFloor() internal view returns (uint256) {
        return Math.max(
            adapter.balanceOf(USDG) * adapter.minLocalBufferBps() / 10_000,
            adapter.minLocalBufferAbsolute()
        );
    }

    /// @dev The largest leg every live limit allows right now. With `maxBridgeAmount` and the
    ///      rolling budget both raised far above the position, the binding constraint is the
    ///      buffer floor — so the test sizes itself off the chain instead of a constant.
    function _largestAllowedLeg() internal view returns (uint256) {
        uint256 local = adapter.availableLiquidity();
        uint256 required = _bufferFloor();
        uint256 spendable = local > required ? local - required : 0;
        return
            Math.min(
                Math.min(adapter.maxBridgeAmount(), adapter.bridgeBudgetRemaining()), spendable
            );
    }

    /// One keeper-signed leg against the live Across SpokePool.
    function test_liveKeeperCanBridgeOutOneLeg() public {
        uint256 amount = 5_000e6;
        uint256 localBefore = adapter.availableLiquidity();
        uint256 escrowedBefore = usdg.balanceOf(SPOKE_POOL);
        uint256 positionBefore = adapter.balanceOf(USDG);
        assertGe(_largestAllowedLeg(), amount, "every live limit admits this leg");

        AcrossBridger.AcrossQuote memory q = _quoteAtFloor(amount);
        vm.prank(keeper);
        adapter.bridgeOut(amount, q);

        assertEq(adapter.availableLiquidity(), localBefore - amount, "USDG left the adapter");
        assertEq(usdg.balanceOf(SPOKE_POOL), escrowedBefore + amount, "SpokePool escrowed it");
        assertEq(adapter.outboundInFlight(), amount, "counted as in flight");
        assertEq(adapter.outboundExpected(), q.outputAmount, "marked at the quote's output");
        // The leg is marked down by the bridge fee and by nothing else.
        assertEq(
            adapter.balanceOf(USDG), positionBefore - (amount - q.outputAmount), "position holds"
        );
        emit log_named_decimal_uint("bridged (USDG)", amount, 6);
        emit log_named_decimal_uint("position after", adapter.balanceOf(USDG), 6);
    }

    /// Neither the per-deposit cap nor the rolling budget is binding any more: the whole
    /// deployable position crosses in ONE deposit, stopped only by the redemption buffer.
    function test_theWholeDeployablePositionCrossesInOneLeg() public {
        uint256 local = adapter.availableLiquidity();
        assertGt(adapter.maxBridgeAmount(), local, "the per-deposit cap is no longer binding");
        assertGt(adapter.bridgeBudgetRemaining(), local, "the daily budget is no longer binding");

        uint256 leg = _largestAllowedLeg();
        uint256 required = _bufferFloor();
        assertEq(leg, local - required, "the buffer floor is the only limit left");

        vm.prank(keeper);
        adapter.bridgeOut(leg, _quoteAtFloor(leg));

        assertEq(adapter.outboundInFlight(), leg, "escrowed in one deposit");
        assertEq(adapter.availableLiquidity(), required, "stopped exactly at the buffer");
        assertGt(adapter.bridgeBudgetRemaining(), 0, "the day's budget is barely touched");

        // Whatever headroom the bridge fee just opened up (the position fell, so the bps floor
        // did too), one USDG past it still cuts into the redemption buffer.
        uint256 tooMuch = _largestAllowedLeg() + 1;
        uint256 localNow = adapter.availableLiquidity();
        uint256 floorNow = _bufferFloor();
        AcrossBridger.AcrossQuote memory q = _quoteAtFloor(tooMuch);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.LocalBufferBreached.selector, localNow - tooMuch, floorNow
            )
        );
        adapter.bridgeOut(tooMuch, q);

        emit log_named_decimal_uint("crossed in one leg (USDG)", leg, 6);
        emit log_named_decimal_uint("left for redeemers (USDG)", adapter.availableLiquidity(), 6);
    }

    /// Redemption liquidity is what the buffer floor exists to protect, so it is asserted
    /// rather than assumed: with everything deployable bridged, the adapter still pays the pool.
    function test_redemptionsStillPayAfterEverythingDeployableIsBridged() public {
        uint256 leg = _largestAllowedLeg();
        vm.prank(keeper);
        adapter.bridgeOut(leg, _quoteAtFloor(leg));

        uint256 ask = 1_000e6;
        uint256 liquidityBefore = adapter.availableLiquidity();
        assertGe(liquidityBefore, ask, "buffer still covers a redemption");

        vm.prank(RESERVE);
        uint256 paid = adapter.withdraw(USDG, ask, RESERVE);
        assertEq(paid, ask, "paid in full");
        assertEq(adapter.availableLiquidity(), liquidityBefore - ask, "out of the local buffer");
    }

    /// The bps buffer floor binds before the balance does: bridging is not able to drain the
    /// adapter even with a budget large enough to try.
    function test_theBufferFloorStopsAnOversizedBridge() public {
        vm.startPrank(adapter.owner());
        adapter.setMaxBridgeAmount(type(uint128).max);
        adapter.setBridgeBudget(type(uint128).max, adapter.bridgeWindow());
        vm.stopPrank();

        uint256 local = adapter.availableLiquidity();
        uint256 required = adapter.balanceOf(USDG) * adapter.minLocalBufferBps() / 10_000;
        uint256 tooMuch = local - required + 1;

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.LocalBufferBreached.selector, local - tooMuch, required
            )
        );
        adapter.bridgeOut(tooMuch, _quoteAtFloor(tooMuch));
    }
}

/// @notice The Arbitrum half, against the live hub: can it take the fill, buy sUSDai on the real
///         Curve pool, sell it back, and bridge the proceeds home?
contract LiveSUSDaiHubForkTest is Test {
    address constant HUB = 0x740ddd200D9Ee605F25239Ba701bdd89161034b1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;
    address constant SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address constant ADAPTER = 0x460f319E43428387bff58ec262C992Ec7DA22fDc;
    uint256 constant ROBINHOOD = 4663;

    /// What a 5,000e6 outbound leg delivers at the 20 bps fee floor the adapter enforces.
    uint256 constant FILL = 4_990e6;

    SUSDaiHub hub = SUSDaiHub(HUB);
    IERC20 usdc = IERC20(USDC);
    IERC20 shares = IERC20(SUSDAI);
    address keeper;
    address owner;
    /// @dev Cached in `setUp` for the same reason as the home-side suite: a read inside an
    ///      argument list would spend the `vm.prank` meant for the call itself.
    uint16 feeBps;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        keeper = hub.keeper();
        owner = hub.owner();
        feeBps = hub.maxBridgeFeeBps();
        // The relayer's fill, which is an ordinary ERC-20 transfer in to the hub.
        deal(USDC, HUB, usdc.balanceOf(HUB) + FILL);
    }

    function _quoteAtFloor(uint256 amount)
        internal
        view
        returns (AcrossBridger.AcrossQuote memory)
    {
        uint256 output = amount - amount * feeBps / 10_000;
        return AcrossBridger.AcrossQuote({
            outputAmount: output,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 2 hours),
            exclusivityDeadline: 0
        });
    }

    function test_theWiringIsWhatTheManifestClaims() public view {
        assertEq(hub.homeReceiver(), ADAPTER, "returns to the live adapter");
        assertEq(hub.homeChainId(), ROBINHOOD, "on Robinhood Chain");
        assertEq(address(hub.spokePool()), SPOKE_POOL, "through the live SpokePool");
        assertFalse(hub.paused(), "not paused");
    }

    /// The outbound leg's landing: USDC in, sUSDai out, at a price that clears the NAV floor.
    function test_hubBuysSUSDaiWithADeliveredFill() public {
        uint256 quoted = hub.quoteBuy(FILL);
        uint256 floor = hub.buyFloor(FILL);
        assertGe(quoted, floor, "Curve prices above the NAV floor, so the swap is possible");

        vm.prank(keeper);
        uint256 bought = hub.buyShares(FILL, floor);

        assertGe(bought, floor, "filled at or above the floor");
        assertEq(shares.balanceOf(HUB), bought, "the hub holds the shares");
        emit log_named_decimal_uint("usdc in", FILL, 6);
        emit log_named_decimal_uint("susdai out", bought, 18);
        emit log_named_decimal_uint("conservative value", hub.conservativeValue(), 6);
        // The round trip's cost, which the reserve's 20 bps redemption fee is sized against.
        assertLt(FILL - hub.conservativeValue(), FILL * 100 / 10_000, "marked within 1% of par");
    }

    /// The return leg, end to end, with no owner intervention: the hub's `maxBridgeAmount` is
    /// now set, so buy, sell and bridge home all clear as the keeper.
    function test_theHubRoundTripsAndBridgesHomeUnaided() public {
        assertGe(hub.maxBridgeAmount(), FILL, "the homeward leg is no longer fail-closed");

        uint256 buyFloor = hub.buyFloor(FILL);
        vm.prank(keeper);
        hub.buyShares(FILL, buyFloor);
        uint256 held = shares.balanceOf(HUB);

        uint256 sellFloor = hub.sellFloor(held);
        vm.prank(keeper);
        uint256 usdcOut = hub.sellShares(held, sellFloor);
        assertGt(usdcOut, 0, "shares sold back to USDC");

        uint256 escrowedBefore = usdc.balanceOf(SPOKE_POOL);
        vm.prank(keeper);
        hub.bridgeHome(usdcOut, _quoteAtFloor(usdcOut));
        assertEq(usdc.balanceOf(SPOKE_POOL), escrowedBefore + usdcOut, "SpokePool escrowed it");
        emit log_named_decimal_uint("round-tripped home (USDC)", usdcOut, 6);
        emit log_named_decimal_uint("round-trip cost (USDC)", FILL - usdcOut, 6);
    }

    /// Size, not our limits, is what bounds the hub now. A quarter-million round trips inside a
    /// single day's budget, which is more than the whole live reserve.
    function test_theHubMovesAQuarterMillionInOneDay() public {
        uint256 size = 250_000e6;
        assertGe(hub.maxBridgeAmount(), size, "per-deposit cap admits it");
        assertGe(hub.swapBudgetRemaining(), size * 3, "the day's budget admits buy, sell, bridge");
        deal(USDC, HUB, size);

        uint256 buyFloor = hub.buyFloor(size);
        vm.prank(keeper);
        uint256 bought = hub.buyShares(size, buyFloor);
        assertGe(bought, buyFloor, "filled at or above the NAV floor at size");

        uint256 sellFloor = hub.sellFloor(bought);
        vm.prank(keeper);
        uint256 usdcOut = hub.sellShares(bought, sellFloor);

        uint256 escrowedBefore = usdc.balanceOf(SPOKE_POOL);
        AcrossBridger.AcrossQuote memory q = _quoteAtFloor(usdcOut);
        vm.prank(keeper);
        hub.bridgeHome(usdcOut, q);

        assertEq(usdc.balanceOf(SPOKE_POOL), escrowedBefore + usdcOut, "SpokePool escrowed it");
        assertGt(hub.swapBudgetRemaining(), 0, "still inside one day's budget");
        emit log_named_decimal_uint("round-tripped at size (USDC)", usdcOut, 6);
        emit log_named_decimal_uint("cost at 250k (USDC)", size - usdcOut, 6);
        emit log_named_decimal_uint("budget left (USDC)", hub.swapBudgetRemaining(), 6);
    }

    /// The real ceiling on one swap, and it is not a parameter we can raise: the Curve pool's
    /// depth. Past roughly a quarter-million the quote falls under the NAV floor and the swap is
    /// refused — by design, because that floor is what stops the collateral being sold cheap.
    function test_curveDepthNotOurLimitsCapsASingleSwap() public {
        assertGe(hub.quoteBuy(250_000e6), hub.buyFloor(250_000e6), "250k clears the NAV floor");
        assertLt(hub.quoteBuy(500_000e6), hub.buyFloor(500_000e6), "500k does not");

        uint256 size = 1_000_000e6;
        deal(USDC, HUB, size);
        uint256 floor = hub.buyFloor(size);
        emit log_named_decimal_uint("quote at 1m (sUSDai)", hub.quoteBuy(size), 18);
        emit log_named_decimal_uint("floor at 1m (sUSDai)", floor, 18);

        // Curve refuses the min-out the floor forces the keeper to pass.
        vm.prank(keeper);
        vm.expectRevert();
        hub.buyShares(size, floor);
    }
}
