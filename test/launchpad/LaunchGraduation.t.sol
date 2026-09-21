// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchGraduationGuard} from "../../src/launchpad/LaunchGraduationGuard.sol";
import {
    GraduationPhase,
    ILaunchFactory,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchGraduationTest
/// @notice The whole journey from launch to a market someone can trade in: the curve fills to
///         its threshold, phase one sweeps its reserves into the factory, phase two hands them
///         to `LaunchGraduation`, and what comes out is an ordinary asset market whose only
///         LP is a position nobody can ever withdraw.
///
///         What is proved here is the reconciliation — every raw unit of swept quote and
///         swept supply ends up in the pool, the locker or the protocol's escrow — the price
///         the market opens at, who holds what afterwards, and that a failed phase two leaves
///         the launch exactly where it was.
contract LaunchGraduationTest is LaunchpadFixture {
    using StateLibrary for IPoolManager;

    /// @dev The `PoolGraduated` event, decoded. `Result` minus the market id, which is
    ///      indexed and read off the launch record instead.
    struct Graduated {
        address unit;
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked;
    }

    address token;
    address curve;
    uint256 sweptQuote;
    uint256 sweptTokens;

    function setUp() public {
        _deployLaunchpadStack();
        (token, curve) = _launch("Cashcat", "CAT");
        _buyToThreshold(curve, trader);

        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        sweptQuote = launch.sweptQuote;
        sweptTokens = launch.sweptTokens;
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev Phase two with the event captured, since `graduateToMarket` returns nothing and
    ///      the seed figures only exist in the module's return value and this event.
    function _graduateToMarket() internal returns (Graduated memory g) {
        vm.recordLogs();
        launchFactory.graduateToMarket(token);

        bytes32 sig = keccak256(
            "PoolGraduated(address,uint256,address,bytes32,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(launchFactory) || logs[i].topics[0] != sig) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "event token");
            (g.unit, g.poolId, g.positionId, g.unitSeeded, g.tokensSeeded, g.tokensLocked) =
                abi.decode(logs[i].data, (address, bytes32, uint256, uint256, uint256, uint256));
            return g;
        }
        revert("PoolGraduated not emitted");
    }

    /// @dev The price the pool opened at, as the market factory would quote it for the price
    ///      the curve ended on: `(quote + phantom) / tokens` raw, expressed as one whole
    ///      token in whole units × 1e18.
    function _terminalSqrtPrice(address unit) internal view returns (uint160) {
        uint256 priceE18 = (sweptQuote + PHANTOM_QUOTE) * 1e18 * 1e18 / (sweptTokens * 1e6);
        return marketFactory.quoteSqrtPriceX96(unit, token, priceE18);
    }

    // ─── The journey ─────────────────────────────────────────────────────

    function test_thresholdBuySweepsTheCurveIntoTheFactory() public view {
        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(GraduationPhase.Swept), "phase one ran in the buy");
        assertTrue(LaunchCurve(curve).graduated(), "curve closed");
        // The crossing buy sells exactly the remaining allocation and rounds the quote it
        // charges up, so the real reserve lands on the threshold plus a few base units.
        assertGe(sweptQuote, GRADUATION_THRESHOLD, "the real reserve reached the threshold");
        assertApproxEqAbs(sweptQuote, GRADUATION_THRESHOLD, 10, "and no more than rounding");
        assertGt(sweptTokens, 0, "the remaining supply came along");

        assertEq(IERC20(quoteBrand).balanceOf(address(launchFactory)), sweptQuote);
        assertEq(IERC20(token).balanceOf(address(launchFactory)), sweptTokens);
    }

    function test_graduateToMarket_opensAMarketAtTheCurvesTerminalPrice() public {
        Graduated memory g = _graduateToMarket();

        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(GraduationPhase.Graduated));
        assertGt(launch.marketId, 0, "market id recorded");

        AssetMarketFactory.Market memory m = marketFactory.market(launch.marketId);
        assertEq(m.asset, token, "the launch token is the market's asset");
        assertEq(m.brandToken, g.unit, "the unit the event names");
        assertEq(m.poolId, g.poolId, "the pool the event names");
        assertEq(m.creator, creator, "the launch's creator is the market's creator");
        assertEq(m.reservePool, address(reserve));
        assertFalse(m.verified, "a launched token is never a canonical equity");
        assertEq(m.fee, POOL_FEE, "the launch config's LP tier");
        // Quoted in the dollar the curve was quoted in, and nothing was minted for it. The
        // brand keeps belonging to its issuer: no `marketOfBrand`, no vault of its own.
        assertEq(g.unit, quoteBrand, "the launch's own dollar, not a fresh <SYM>.d");
        assertTrue(marketFactory.isSharedQuote(launch.marketId), "a shared-quote market");
        assertEq(marketFactory.marketOfBrand(quoteBrand), 0, "the brand belongs to no market");
        assertEq(marketFactory.feeVaultOfBrand(quoteBrand), address(0), "and has no one vault");

        // The hook skims this pool at the factory's rate, into the protocol treasury.
        assertEq(hook.feeRecipientOf(PoolId.wrap(g.poolId)), protocolTreasury);
        assertEq(hook.feePipsOf(PoolId.wrap(g.poolId)), PROTOCOL_FEE_PIPS);

        // The pool opened where the curve ended, not at some listing price of its own.
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(g.poolId));
        assertApproxEqRel(sqrtPriceX96, _terminalSqrtPrice(g.unit), 1e9, "terminal price");
    }

    function test_graduateToMarket_reconcilesEveryUnitAndEveryToken() public {
        // The curve's fees were credited in the same brand the raise is denominated in, and
        // before this call, so they are netted out rather than counted against the seed.
        uint256 curveFees = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand);
        Graduated memory g = _graduateToMarket();

        // Quote side: the raise stays in its own brand, and what the mint did not consume is
        // the protocol's, in the escrow, so the two add back to the swept quote exactly.
        uint256 unitDust = feeEscrow.balanceOfToken(protocolFeeRecipient, g.unit) - curveFees;
        assertEq(g.unitSeeded + unitDust, sweptQuote, "unit seeded + dust == swept quote");
        assertGt(g.unitSeeded, 0);

        // Token side: the pool got the price-preserving share, the locker got the rest,
        // rounding dust included.
        assertEq(g.tokensSeeded + g.tokensLocked, sweptTokens, "seeded + locked == swept");
        assertEq(locker.lockedSupply(token), g.tokensLocked, "locker ledger");
        assertEq(IERC20(token).balanceOf(address(locker)), g.tokensLocked, "locker balance");
        uint256 expectedSeed = sweptTokens * sweptQuote / (sweptQuote + PHANTOM_QUOTE);
        assertApproxEqAbs(g.tokensSeeded, expectedSeed, 1e12, "the plan's split, to rounding");

        // Nobody in the path holds anything afterwards.
        assertEq(IERC20(g.unit).balanceOf(address(graduation)), 0, "module holds no unit");
        assertEq(IERC20(token).balanceOf(address(graduation)), 0, "module holds no token");
        assertEq(IERC20(quoteBrand).balanceOf(address(graduation)), 0, "module holds no brand");
        assertEq(IERC20(quoteBrand).balanceOf(address(launchFactory)), 0, "factory paid out");
        assertEq(IERC20(token).balanceOf(address(launchFactory)), 0, "factory paid out");

        // And the position is the pool's whole depth.
        assertEq(
            IPoolManager(address(manager)).getLiquidity(PoolId.wrap(g.poolId)),
            posm.getPositionLiquidity(g.positionId),
            "the seed is the only liquidity"
        );
    }

    function test_graduateToMarket_locksThePositionUnderTheLocker() public {
        Graduated memory g = _graduateToMarket();
        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        LpRewardDistributor dist =
            LpRewardDistributor(marketFactory.market(launch.marketId).lpDistributor);

        assertEq(dist.stakerOf(g.positionId), address(locker), "the locker is the staker");
        assertEq(posm.ownerOf(g.positionId), address(dist), "the distributor custodies it");
        // The position is weighed as capital and is the only stake in the book, but it draws
        // nothing from the stream: recording it renounced, and the floor it measured is one
        // basis point of that weight.
        assertEq(dist.positionCountOf(address(locker)), 1, "the one position is the locker's");
        assertGt(dist.stakedWeightOfPosition(g.positionId), 0, "the position carries weight");
        assertEq(dist.totalStaked(), 0, "and it draws nothing from the stream");
        assertEq(
            dist.minStakeWeight(),
            dist.stakedWeightOfPosition(g.positionId) / dist.RENOUNCED_FLOOR_DIVISOR(),
            "the floor is a basis point of the seed's weight"
        );

        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        assertTrue(p.exists);
        assertEq(p.tokenId, g.positionId);
        assertEq(p.distributor, address(dist));
        assertEq(p.unit, g.unit);
        assertEq(p.creatorFeeRecipient, creatorFeeRecipient);
        assertEq(p.creatorShareBps, launchFactory.graduatedCreatorShareBps());
    }

    function test_graduateToMarket_aSecondTimeReverts() public {
        _graduateToMarket();
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        launchFactory.graduateToMarket(token);
    }

    /// @notice A phase two that fails anywhere — here the market factory refuses to open the
    ///         market at all — is one reverted transaction: the launch stays swept, the
    ///         factory keeps the reserves, and the same call succeeds once the cause is gone.
    ///         Nothing needs rescuing.
    function test_graduateToMarket_failureLeavesTheLaunchSweptAndRetryable() public {
        // The trigger used to be halting the reserve, which no longer stops a graduation: the
        // float registration was the only step of phase two that touched the reserve, and it
        // is deliberately best-effort now, because a share of a third party's yield must not
        // be able to veto the market's creation. Un-naming the launchpad fails the step that
        // actually is load-bearing — the market itself — and is just as reversible.
        vm.prank(marketFactory.owner());
        marketFactory.setLaunchpad(address(0));

        vm.expectRevert(AssetMarketFactory.OnlyLaunchpad.selector);
        launchFactory.graduateToMarket(token);

        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(GraduationPhase.Swept), "still swept");
        assertEq(launch.sweptQuote, sweptQuote, "swept quote intact");
        assertEq(launch.sweptTokens, sweptTokens, "swept tokens intact");
        assertEq(launch.marketId, 0, "no market");
        assertEq(IERC20(quoteBrand).balanceOf(address(launchFactory)), sweptQuote);
        assertEq(IERC20(token).balanceOf(address(launchFactory)), sweptTokens);
        assertEq(marketFactory.marketFor(address(reserve), token), 0, "no market was opened");
        assertFalse(locker.lockedPosition(token).exists, "nothing locked");
        assertEq(locker.lockedSupply(token), 0, "nothing locked");

        _setLaunchpad(marketFactory, address(graduation));

        Graduated memory g = _graduateToMarket();
        assertEq(g.tokensSeeded + g.tokensLocked, sweptTokens, "the retry seeded everything");
    }

    function test_graduate_isOnlyCallableByTheFactory() public {
        ILaunchGraduation.Seed memory seed;
        seed.token = token;
        seed.pairToken = quoteBrand;
        seed.reserve = address(reserve);
        seed.quoteAmount = 1;
        seed.tokenAmount = 1;

        vm.prank(stranger);
        vm.expectRevert(LaunchGraduation.OnlyFactory.selector);
        graduation.graduate(seed);
    }

    /// @notice After graduation the token is an ordinary market: the router's USDG path
    ///         reaches it with no launchpad in the loop.
    function test_marketRouterCanBuyTheGraduatedTokenWithUsdg() public {
        _graduateToMarket();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;

        uint256 usdgIn = 100e6;
        usdg.mint(stranger, usdgIn);
        vm.startPrank(stranger);
        usdg.approve(address(router), usdgIn);
        uint256 out =
            router.buyWithUsdg(marketId, usdgIn, 0, stranger, vm.getBlockTimestamp() + 1 hours);
        vm.stopPrank();

        assertGt(out, 0, "bought");
        assertEq(IERC20(token).balanceOf(stranger), out, "and holds it");

        // Roughly a hundred dollars' worth at the opening price: the pool is deep against a
        // trade this size, so the fill is close to the terminal price less the 1% of fees.
        uint256 atTerminalPrice = usdgIn * sweptTokens / (sweptQuote + PHANTOM_QUOTE);
        assertApproxEqRel(out, atTerminalPrice, 0.03e18, "priced off the curve's end");
    }

    /// @dev The factory preflights the seed at a price derived from the two amounts; V4 mints
    ///      at the price the market factory actually initialised the pool with, which came
    ///      through a truncated `assetPriceE18`. Only the second price decides whether
    ///      `modifyLiquidities` reverts, so the module has to assert against it — failing in
    ///      the guard with a named error leaves the launch retryable in `Swept` instead of
    ///      reverting somewhere inside the position manager.
    function test_mintPreflightsAtThePriceThePoolWasActuallyInitialisedAt() public {
        LaunchGraduationGuard guard = launchFactory.graduationGuard();
        int24 spacing = marketFactory.tickSpacingForFee(POOL_FEE);

        // A sane price and amounts pass.
        guard.assertSeedableAtPrice(spacing, TickMath.getSqrtPriceAtTick(0), 1e18, 1e18);

        // A price at the edge of V4's range does not, and the amounts alone never reveal it.
        vm.expectRevert(LaunchGraduationGuard.SqrtPriceOutOfBounds.selector);
        guard.assertSeedableAtPrice(spacing, TickMath.MIN_SQRT_PRICE, 1e18, 1e18);

        // Neither does liquidity past what one tick of this spacing may hold, which is V4's
        // own independent `TickLiquidityOverflow` rejection.
        vm.expectRevert(LaunchGraduationGuard.GraduationSeedNotViable.selector);
        guard.assertSeedableAtPrice(
            spacing, TickMath.getSqrtPriceAtTick(0), type(uint128).max, type(uint128).max
        );

        // And the live path routes through it, so a real graduation still lands.
        (address token,) = _launch("Preflight", "PRE");
        _buyToThreshold(launchFactory.getLaunchedToken(token).curve, trader);
        launchFactory.graduateToMarket(token);
        assertEq(
            uint8(launchFactory.getLaunchedToken(token).phase), uint8(GraduationPhase.Graduated)
        );
    }
}
