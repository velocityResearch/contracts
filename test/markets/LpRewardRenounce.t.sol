// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title LpRewardRenounceTest
/// @notice `renounceRewards`: an account permanently giving up its share of a market's float,
///         which is what a graduated launch's locked position does the moment the locker
///         records it.
///
///         The locked position has to stay staked — the distributor custodies the NFT and
///         `collectFees` is how the launch's creator is paid — while owning none of the
///         stream, because nobody withdrew capital to fund it. So these cases pin both
///         halves: that the renounced liquidity really does leave the stream's divisor and
///         reach the liquidity providers who did put capital at risk, and that everything a
///         staker keeps — custody, `unstake`, `collectFees`, and reward already accrued — is
///         untouched by giving up the stream.
///
///         **The venue is a real `PoolManager`,** with positions minted through the stand-in
///         `PositionManager` the rest of this suite uses, so the liquidity numbers the stream
///         is divided by are Uniswap's arithmetic and the fees `collectFees` moves are real
///         swap fees. The pool is hookless, like every other market pool in this suite: the
///         distributor divides by staked liquidity and never asks a hook anything. This
///         contract stands in for the market's vault, which is what lets a reward period be
///         notified directly.
contract LpRewardRenounceTest is StackFixture {
    PoolManager manager;
    PoolSwapTest poolSwap;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;
    MockAsset asset;

    address unit; // the market unit: the brand the pool holds and rewards are paid in
    LpRewardDistributor dist;
    PoolKey key;

    address owner = address(0x0AD01);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint32 constant DURATION = 7 days;

    uint256 constant FLOAT = 1_000_000e6;
    uint256 constant REWARD = 7_000e6; // a round 1,000 USDG a day over the period

    /// @dev Declared here rather than reached for on the distributor so `expectEmit` compares
    ///      the topics and data a consumer would decode.
    event RewardsRenounced(address indexed account, uint256 weightGivenUp);

    function setUp() public {
        _deployUpgradeBase();

        manager = new PoolManager(address(this));
        poolSwap = new PoolSwapTest(IPoolManager(address(manager)));
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);
        asset = new MockAsset();

        (unit,) = reserve.registerBrand("NVDA Market Dollar", "NVDA.d", address(this));

        key = _poolKey();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        dist = _deployDistributor(key);

        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(address(this));
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _poolKey() internal view returns (PoolKey memory) {
        (address c0, address c1) =
            unit < address(asset) ? (unit, address(asset)) : (address(asset), unit);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Behind a beacon, exactly as a market's distributor is deployed in production.
    function _deployDistributor(PoolKey memory k) internal returns (LpRewardDistributor) {
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(address(new LpRewardDistributor()), stackOwner);
        return LpRewardDistributor(
            address(
                new BeaconProxy(
                    address(beacon),
                    abi.encodeCall(
                        LpRewardDistributor.initialize,
                        (
                            IPositionManagerV4(address(posm)),
                            reserve,
                            k,
                            unit,
                            address(this),
                            DURATION,
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    function _fund(address who) internal {
        usdg.mint(who, FLOAT);
        vm.startPrank(who);
        usdg.approve(address(reserve), FLOAT);
        reserve.mint(unit, FLOAT, who);
        vm.stopPrank();
        asset.mint(who, 1_000_000e18);
    }

    /// @dev Mint an exact liquidity over an exact range. Two stakes of the same liquidity are
    ///      then identical to the wei in the only number this contract divides by, which is
    ///      what lets "half the stream" and "the whole stream" be told apart exactly.
    function _mintIn(address who, int24 tickLower, int24 tickUpper, uint128 liq)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(who);
        IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(key.currency0), address(posm), type(uint160).max, type(uint48).max
        );
        permit2.approve(
            Currency.unwrap(key.currency1), address(posm), type(uint160).max, type(uint48).max
        );

        bytes memory actions = abi.encodePacked(uint8(0x02), uint8(0x0d));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liq),
            type(uint128).max,
            type(uint128).max,
            who,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();
    }

    /// @dev A full-range mint: the only shape this distributor admits, and the shape a market
    ///      is seeded with.
    function _mintWide(address who, uint128 liq) internal returns (uint256 tokenId) {
        (int24 lower, int24 upper) = dist.fullRange();
        return _mintIn(who, lower, upper, liq);
    }

    function _stakeWide(address who, uint128 liq) internal returns (uint256 tokenId) {
        tokenId = _mintWide(who, liq);
        vm.startPrank(who);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, who);
        vm.stopPrank();
    }

    /// @dev What a full-range position of `liq` weighs at the pool's current price: the unit
    ///      `totalStaked`, a renunciation and the admission floor are all measured in. Zero
    ///      when the price has been pushed so far that the position holds no whole unit of
    ///      the quote — `stake` refuses that as `ZeroWeight` before it ever reaches the floor.
    function _w(uint128 liq) internal view returns (uint256) {
        (int24 lower, int24 upper) = dist.fullRange();
        return dist.stakeWeightFor(liq, lower, upper);
    }

    /// @dev The revert `stake` gives a full-range `liq` under `floor`.
    function _refusal(uint256 tokenId, uint128 liq, uint256 floor)
        internal
        view
        returns (bytes memory)
    {
        uint256 weight = _w(liq);
        if (weight == 0) {
            return abi.encodeWithSelector(LpRewardDistributor.ZeroWeight.selector, tokenId);
        }
        return abi.encodeWithSelector(LpRewardDistributor.StakeBelowFloor.selector, weight, floor);
    }

    /// @dev What the vault does: send the reward, then say so.
    function _notify(uint256 amount) internal {
        IERC20(unit).transfer(address(dist), amount);
        dist.notifyReward(amount);
    }

    function _renounce(address who) internal {
        vm.prank(who);
        dist.renounceRewards();
    }

    function _swap(uint256 amountIn, bool unitForAsset) internal {
        bool brandIsCurrency0 = Currency.unwrap(key.currency0) == unit;
        bool zeroForOne = unitForAsset == brandIsCurrency0;

        address tokenIn =
            zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        vm.startPrank(carol);
        IERC20(tokenIn).approve(address(poolSwap), amountIn);
        poolSwap.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ─── The stream redirects ────────────────────────────────────────────

    /// @dev The property the whole mechanism exists for. Two equal stakes, one of them
    ///      renounced: the period pays the other one *everything*, not half. A renunciation
    ///      that only stopped paying the renouncer — without taking its liquidity out of the
    ///      divisor — would strand the other half in the contract forever.
    function test_renounce_redirectsTheWholeStreamToTheRemainingStaker() public {
        _stakeWide(alice, 2e10);
        _stakeWide(bob, 2e10);
        assertEq(dist.stakedLiquidityOf(alice), dist.stakedLiquidityOf(bob), "equal stakes");

        _renounce(alice);

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);

        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "the whole period, not half of it");
        assertEq(dist.earned(alice), 0, "and nothing to the renounced stake");

        // Not just the view: the money moves.
        uint256 owed = dist.earned(bob);
        uint256 before = IERC20(unit).balanceOf(bob);
        vm.prank(bob);
        uint256 paid = dist.claim(unit);
        assertEq(paid, owed, "claimed what was earned");
        assertEq(IERC20(unit).balanceOf(bob) - before, owed, "paid in the market unit");

        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.ZeroAmount.selector);
        dist.claim(unit);
    }

    /// @dev A renunciation gives up the future, never the past: whatever the account earned
    ///      while its liquidity still divided the stream is settled into `rewards` and stays
    ///      claimable.
    function test_renounce_keepsRewardAccruedBeforeItAndEarnsNothingAfter() public {
        _stakeWide(alice, 2e10);
        _stakeWide(bob, 2e10);
        _notify(REWARD);

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 accrued = dist.earned(alice);
        assertApproxEqAbs(accrued, REWARD / 4, 2, "half the period at half the book");

        _renounce(alice);
        assertEq(dist.earned(alice), accrued, "settled at the moment of renouncing");

        vm.warp(dist.periodFinish());
        assertEq(dist.earned(alice), accrued, "and not a wei more afterwards");

        uint256 before = IERC20(unit).balanceOf(alice);
        vm.prank(alice);
        uint256 paid = dist.claim(unit);
        assertEq(paid, accrued, "exactly what it had earned when it renounced");
        assertEq(IERC20(unit).balanceOf(alice) - before, accrued, "and it was paid out");

        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.ZeroAmount.selector);
        dist.claim(unit);

        assertApproxEqAbs(
            dist.earned(bob), REWARD - accrued, 3, "the rest of the stream went to the LP"
        );
    }

    /// @dev The renounced liquidity leaves the divisor exactly once, and the transition is
    ///      invisible to everyone else: the other staker's accrual neither reverts nor moves in
    ///      the instant it is removed. Custody and the liquidity book are not entitlement, so
    ///      neither of them moves at all — including the per-position cache, which stays at
    ///      what was staked and is exactly why `unstake` has to read the renounced flag.
    function test_renounce_dropsTotalStakedByExactlyTheRenouncedLiquidityAndLeavesTheOtherWhole()
        public
    {
        uint256 aliceId = _stakeWide(alice, 3e10);
        _stakeWide(bob, 1e10);

        uint256 aliceLiquidity = dist.stakedLiquidityOf(alice);
        uint256 bobLiquidity = dist.stakedLiquidityOf(bob);
        uint256 totalBefore = dist.totalStaked();
        assertEq(
            totalBefore,
            dist.stakedWeightOf(alice) + dist.stakedWeightOf(bob),
            "the book is the sum of the two"
        );

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION / 4);
        uint256 bobEarnedBefore = dist.earned(bob);
        assertGt(bobEarnedBefore, 0, "bob has been earning");

        vm.expectEmit(true, false, false, true, address(dist));
        emit RewardsRenounced(alice, dist.stakedWeightOf(alice));
        _renounce(alice);

        assertEq(
            dist.totalStaked(),
            totalBefore - dist.stakedWeightOf(alice),
            "exactly the renounced weight"
        );
        assertEq(
            dist.totalStaked(), dist.stakedWeightOf(bob), "which leaves the book at bob's alone"
        );
        assertEq(dist.earned(bob), bobEarnedBefore, "no jump at the transition");

        // Nothing about the position itself changed: it is still staked, still custodied, and
        // its liquidity is still recorded against the account and against the position.
        assertEq(dist.stakerOf(aliceId), alice, "still staked");
        assertEq(posm.ownerOf(aliceId), address(dist), "still custodied");
        assertEq(dist.stakedLiquidityOf(alice), aliceLiquidity, "liquidity is not entitlement");
        assertEq(
            dist.stakedLiquidityOfPosition(aliceId),
            aliceLiquidity,
            "nor is the position's own cache"
        );

        vm.warp(dist.periodFinish());
        assertGt(dist.earned(bob), bobEarnedBefore, "and bob keeps earning after it");
    }

    // ─── Future stakes divide nothing ────────────────────────────────────

    /// @dev A renounced account may still stake, and the position is custodied and addressable
    ///      exactly as any other — it just never enters the divisor. That is the shape the
    ///      locker needs: the NFT has to be held here for `collectFees` to reach it.
    function test_stake_afterRenouncingAddsNothingToTheBookButIsStillCustodied() public {
        _stakeWide(alice, 2e10);
        _renounce(alice);
        _stakeWide(bob, 2e10);

        uint256 totalBefore = dist.totalStaked();
        uint256 aliceLiquidityBefore = dist.stakedLiquidityOf(alice);

        uint256 second = _stakeWide(alice, 2e10);

        assertEq(dist.totalStaked(), totalBefore, "the divisor does not move");
        assertEq(dist.totalStaked(), dist.stakedWeightOf(bob), "it is still bob's alone");

        // Custody and the ledger are untouched by the renunciation.
        assertEq(dist.stakerOf(second), alice, "credited to the staker");
        assertEq(posm.ownerOf(second), address(dist), "and held here");
        assertEq(dist.positionsOf(alice).length, 2, "listed against the account");
        assertEq(dist.stakedLiquidityOfPosition(second), 2e10, "booked at what it carries");
        assertEq(
            dist.stakedLiquidityOf(alice),
            aliceLiquidityBefore + 2e10,
            "and the account's liquidity grew with it"
        );

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "the whole stream is still bob's");
        assertEq(dist.earned(alice), 0, "two staked positions, no stream");
    }

    /// @dev The renounced account's exemption is from the *floor* and from nothing else. Every
    ///      other admission rule still runs first, so a husk with no liquidity left in it is
    ///      refused whoever stakes it — custody and a ledger slot for it buy nobody anything.
    function test_stake_afterRenouncingStillRefusesAPositionHoldingNothing() public {
        _renounce(alice);
        assertTrue(dist.rewardsRenounced(alice), "exempt from the floor");

        uint256 tokenId = _mintWide(alice, 2e10);
        vm.prank(alice);
        posm.burn(tokenId, alice);

        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.NoLiquidity.selector);
        dist.stake(tokenId, alice);
    }

    // ─── What a renounced staker keeps ───────────────────────────────────

    /// @dev `unstake` is gated on `stakerOf`, not on entitlement, so a renounced account keeps
    ///      its exit — and the exit must not take liquidity out of a divisor that no longer
    ///      holds it. `unstake` subtracts `stakedLiquidityOfPosition(tokenId)` from
    ///      `totalStaked`, and `renounceRewards` already removed the whole of this account's
    ///      liquidity; without the `!rewardsRenounced` guard on that subtraction the same
    ///      liquidity would leave the book twice, under-counting the divisor and over-paying
    ///      every other staker for the rest of the period.
    function test_unstake_byARenouncedAccountLeavesTheBookIntact() public {
        uint256 counted = _stakeWide(alice, 2e10); // in the divisor when it was staked
        _renounce(alice);
        uint256 uncounted = _stakeWide(alice, 2e10); // staked while renounced: never in it
        _stakeWide(bob, 2e10);

        uint256 bobLiquidity = dist.stakedLiquidityOf(bob);
        uint256 totalBefore = dist.totalStaked();
        assertEq(totalBefore, dist.stakedWeightOf(bob), "the book is bob's alone");

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 bobEarnedBefore = dist.earned(bob);
        assertGt(bobEarnedBefore, 0, "bob has been earning");

        vm.startPrank(alice);
        dist.unstake(counted);
        assertEq(
            dist.totalStaked(), totalBefore, "the exit removes liquidity the book no longer holds"
        );
        assertEq(dist.earned(bob), bobEarnedBefore, "bob's accrual is unaffected");

        dist.unstake(uncounted);
        vm.stopPrank();

        assertEq(dist.totalStaked(), totalBefore, "and neither does the never-counted one");
        assertEq(
            dist.totalStaked(), dist.stakedWeightOf(bob), "the book is still exactly bob's weight"
        );
        assertEq(dist.earned(bob), bobEarnedBefore, "still no jump");

        assertEq(posm.ownerOf(counted), alice, "the position came home");
        assertEq(posm.ownerOf(uncounted), alice, "and so did the second");
        assertEq(dist.stakerOf(counted), address(0), "no longer staked");
        assertEq(dist.stakedLiquidityOf(alice), 0, "its liquidity left the ledger");
        assertEq(dist.positionCountOf(alice), 0, "and the list is empty");

        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "the whole period is still his");
        assertEq(dist.earned(alice), 0, "nothing for the renounced stakes");
    }

    /// @dev The reason the locked position stays staked at all. If this broke, a graduated
    ///      launch's creator would never be paid: `collectFees` is the only route from the
    ///      pool's swap fees to them, and it is gated on `stakerOf`, which a renunciation does
    ///      not touch.
    function test_collectFees_stillPaysARenouncedStaker() public {
        uint256 aliceId = _stakeWide(alice, 1e11);
        _renounce(alice);
        _stakeWide(bob, 1e11);

        uint128 liquidityBefore = posm.getPositionLiquidity(aliceId);
        uint256 totalBefore = dist.totalStaked();

        _swap(20_000e6, true);
        _swap(20_000e18, false);

        uint256 unitBefore = IERC20(unit).balanceOf(alice);
        uint256 assetBefore = asset.balanceOf(alice);

        vm.prank(alice);
        dist.collectFees(aliceId);

        assertGt(IERC20(unit).balanceOf(alice), unitBefore, "unit-side swap fees were paid out");
        assertGt(asset.balanceOf(alice), assetBefore, "and asset-side fees with them");
        assertEq(posm.getPositionLiquidity(aliceId), liquidityBefore, "liquidity untouched");
        assertEq(posm.ownerOf(aliceId), address(dist), "still custodied");
        assertEq(dist.totalStaked(), totalBefore, "and no share of the stream came back with it");

        // Swap fees, yes. Float yield, no.
        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertEq(dist.earned(alice), 0, "fees are not the float");
        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "which is entirely the LP's");
    }

    // ─── Idempotent, one-way, self-service ───────────────────────────────

    /// @dev A second renunciation is a no-op. It matters because `LaunchLocker.recordPosition`
    ///      calls it on every graduation into the same market, and a second subtraction from
    ///      `totalStaked` would understate the divisor and over-promise the remaining stakers
    ///      more than the period was notified with.
    function test_renounce_isIdempotentAcrossRepeatedCalls() public {
        _stakeWide(alice, 2e10);
        _stakeWide(bob, 2e10);
        uint256 bobLiquidity = dist.stakedLiquidityOf(bob);

        _renounce(alice);
        uint256 afterFirst = dist.totalStaked();
        assertEq(afterFirst, dist.stakedWeightOf(bob), "one subtraction");

        _renounce(alice);
        _renounce(alice);

        assertEq(dist.totalStaked(), afterFirst, "and no more, however often it is called");
        assertEq(
            dist.totalStaked(), dist.stakedWeightOf(bob), "the divisor still matches the live book"
        );
        assertTrue(dist.rewardsRenounced(alice), "and it stays renounced");

        // The over-promise a double subtraction would cause, measured where it would show:
        // the period cannot pay out more than it was notified with.
        _notify(REWARD);
        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "exactly the notified amount, no more");
    }

    /// @dev Self-service only. `renounceRewards` takes no argument and reads no authority, so
    ///      the only entitlement any caller can give up is their own — including the
    ///      `configAdmin`, which is the account that could otherwise switch off an LP's
    ///      rewards. It renounces its own empty entitlement and moves nothing.
    function test_renounce_onlyEverAffectsTheCaller() public {
        _stakeWide(alice, 2e10);
        _stakeWide(bob, 2e10);

        uint256 aliceLiquidity = dist.stakedLiquidityOf(alice);
        uint256 totalBefore = dist.totalStaked();

        address admin = dist.configAdmin();
        assertEq(admin, stackOwner, "the guard's owner is the market's config admin");

        vm.prank(admin);
        dist.renounceRewards();

        assertTrue(dist.rewardsRenounced(admin), "the admin renounced its own share");
        assertFalse(dist.rewardsRenounced(alice), "and nobody else's");
        assertFalse(dist.rewardsRenounced(bob), "nor bob's");
        assertEq(dist.totalStaked(), totalBefore, "no liquidity moved");

        // A peer cannot do it either: bob's renunciation is bob's alone.
        _renounce(bob);
        assertFalse(dist.rewardsRenounced(alice), "still not alice's to give away");
        assertEq(dist.stakedLiquidityOf(alice), aliceLiquidity, "and her stake is intact");

        _notify(REWARD);
        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(alice), REWARD, 2, "so the stream is hers");
    }

    // ─── The admission floor a renunciation sets ─────────────────────────
    //
    // A renunciation takes the market's dominant stake out of the divisor while its liquidity
    // stays in the pool, which is the one state the liquidity × time rule cannot defend on its
    // own: at graduation `totalStaked` is zero while the seed's liquidity is the whole raise,
    // so the first account to stake anything at all divides the whole float stream — the yield
    // on that entire raise — by itself. `renounceRewards` therefore sets a floor under
    // admission, measured off the liquidity it is giving up.

    /// @dev The seed the graduation locker stakes and then renounces. Big enough that one
    ///      basis point of it is comfortably more than one unit of liquidity, which is what
    ///      the floor has to clear to mean anything.
    uint128 constant SEED_LIQ = 2e10;

    /// @dev The shape of a graduated market the instant `LaunchLocker.recordPosition`
    ///      returns: one full-range position, staked and renounced, and an empty book.
    function _graduate() internal returns (uint256 floor) {
        _stakeWide(alice, SEED_LIQ);
        _renounce(alice);

        assertEq(dist.totalStaked(), 0, "the book is empty: the condition the floor defends");
        assertEq(dist.stakedLiquidityOf(alice), SEED_LIQ, "while the seed's liquidity is all in");

        floor = dist.minStakeWeight();
    }

    function _mintAndTryStake(address who, uint128 liq) internal returns (uint256 tokenId) {
        tokenId = _mintWide(who, liq);
        vm.startPrank(who);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, who);
        vm.stopPrank();
    }

    /// @dev The finding, as money. The seed renounces, the book empties, and the smallest
    ///      thing the old rule admitted — a position carrying any liquidity at all — is now
    ///      refused, because admitting it would hand it the whole stream.
    ///
    ///      The floor is stated exactly: one basis point of the liquidity that was given up,
    ///      which is a number this contract measured off a position it already held rather
    ///      than one any caller supplied.
    function test_stake_refusesADustStakeInAMarketWhoseSeedRenounced() public {
        assertEq(dist.minStakeWeight(), 0, "no floor before anything renounces");

        uint256 floor = _graduate();
        assertEq(
            floor,
            dist.stakedWeightOf(alice) / dist.RENOUNCED_FLOOR_DIVISOR(),
            "one bp of what was given up"
        );
        assertGt(floor, 1, "and it is a real number, not the old any-liquidity-at-all rule");

        uint128 dust = SEED_LIQ / 100_000;
        assertGt(uint256(dust), 0, "the old rule would have admitted this");
        assertLt(_w(dust), floor, "and the new one will not");

        uint256 tokenId = _mintWide(bob, dust);
        vm.startPrank(bob);
        posm.approve(address(dist), tokenId);
        vm.expectRevert(_refusal(tokenId, dust, floor));
        dist.stake(tokenId, bob);
        vm.stopPrank();

        // Refused means refused: nothing was custodied, nothing was credited, and the stream
        // has no claimant, so the period banks rather than paying the dust.
        assertEq(dist.stakerOf(tokenId), address(0), "not staked");
        assertEq(posm.ownerOf(tokenId), bob, "and the position never left its owner");
        assertEq(dist.totalStaked(), 0, "the book is still empty");

        _notify(REWARD);
        vm.warp(dist.periodFinish());
        assertEq(dist.earned(bob), 0, "the whole raise's yield did not go to a dust stake");
    }

    /// @dev The other half: the floor is a floor, not a wall. A stake proportionate to the
    ///      market is admitted on exactly the terms it always was, and earns the stream the
    ///      renounced position gave up.
    function test_stake_admitsAProportionateStakeInTheSameMarket() public {
        uint256 floor = _graduate();

        uint128 real = SEED_LIQ / 100; // one percent of the seed: a hundred times the floor
        assertGt(_w(real), floor, "comfortably over");

        uint256 tokenId = _mintAndTryStake(bob, real);

        assertEq(dist.stakerOf(tokenId), bob, "admitted");
        assertEq(posm.ownerOf(tokenId), address(dist), "and custodied");
        assertEq(dist.stakedLiquidityOf(bob), real, "booked at what it carries, floor or no floor");
        assertEq(
            dist.totalStaked(), dist.stakedWeightOf(bob), "and it is the whole of the live book"
        );

        _notify(REWARD);
        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(bob), REWARD, 2, "the stream the seed gave up reaches an LP");
    }

    /// @dev The property that keeps this fix from being a tax on every ordinary market. The
    ///      floor is written by exactly one thing — a renunciation that had liquidity to give
    ///      and held the whole book — so a market where nothing renounced admits what it
    ///      always did, down to the smallest position anyone cares to mint.
    ///
    ///      Including the case that looks like a renunciation and is not: an account with
    ///      nothing staked renouncing an empty entitlement, which must move no floor.
    function test_stake_floorIsZeroAndNothingIsRefusedWithoutARenunciation() public {
        _stakeWide(alice, SEED_LIQ);
        assertEq(dist.minStakeWeight(), 0, "an ordinary market has no floor");

        // A renunciation with no liquidity behind it is not a measurement of anything.
        _renounce(carol);
        assertTrue(dist.rewardsRenounced(carol), "it took effect");
        assertEq(dist.minStakeWeight(), 0, "and still moved no floor");

        uint128 dust = SEED_LIQ / 100_000;
        uint256 tokenId = _mintAndTryStake(bob, dust);
        assertEq(dist.stakerOf(tokenId), bob, "the small LP is admitted");
        assertEq(dist.stakedLiquidityOf(bob), dust, "at what it carries");

        // And it earns its share: a hundred-thousandth of the book, not none of it and not
        // all of it. The floor changed nothing here.
        _notify(REWARD);
        vm.warp(dist.periodFinish());
        uint256 expected = REWARD * dist.stakedWeightOf(bob) / dist.totalStaked();
        assertApproxEqAbs(dist.earned(bob), expected, 2, "paid strictly in proportion");
        assertGt(dist.earned(bob), 0, "and paid something");
    }

    /// @dev The two exits are gated on `stakerOf`, never on the floor, and the floor is an
    ///      admission rule — so neither reads it. Pinned together because a floor wired into
    ///      the wrong helper would strand a position this contract custodies.
    function test_unstakeAndCollectFees_areUnaffectedByTheFloor() public {
        uint256 floor = _graduate();
        assertGt(floor, 0, "there is a floor to be unaffected by");

        uint256 tokenId = _mintAndTryStake(bob, SEED_LIQ / 100);
        uint128 liquidityBefore = posm.getPositionLiquidity(tokenId);

        _swap(20_000e6, true);
        _swap(20_000e18, false);

        uint256 unitBefore = IERC20(unit).balanceOf(bob);
        uint256 assetBefore = asset.balanceOf(bob);

        vm.prank(bob);
        dist.collectFees(tokenId);

        assertGt(IERC20(unit).balanceOf(bob), unitBefore, "unit-side fees were paid out");
        assertGt(asset.balanceOf(bob), assetBefore, "and asset-side fees with them");
        assertEq(posm.getPositionLiquidity(tokenId), liquidityBefore, "liquidity untouched");
        assertEq(dist.minStakeWeight(), floor, "and the floor did not move");

        uint256 staked = dist.stakedWeightOf(bob);
        vm.prank(bob);
        dist.unstake(tokenId);

        assertEq(posm.ownerOf(tokenId), bob, "the exit is open");
        assertEq(dist.stakerOf(tokenId), address(0), "no longer staked");
        assertEq(dist.stakedLiquidityOf(bob), 0, "and the liquidity left with it");
        assertEq(dist.totalStaked(), 0, "the book is empty again");
        assertGt(staked, floor, "the stake really had been above the floor");
        assertEq(dist.minStakeWeight(), floor, "which the exit does not change");

        // And an exit does not lower the bar for the next arrival either.
        uint128 dust = SEED_LIQ / 100_000;
        uint256 dustId = _mintWide(carol, dust);
        vm.startPrank(carol);
        posm.approve(address(dist), dustId);
        vm.expectRevert(_refusal(dustId, dust, floor));
        dist.stake(dustId, carol);
        vm.stopPrank();
    }

    /// @dev The economics, stated directly rather than through the guard that produces them.
    ///      Whatever the floor admits, it admits into a divisor — so once a real liquidity
    ///      provider is present the smallest admissible stake takes its proportion of the
    ///      period and nothing more. One basis point of the seed earns about one basis point
    ///      of the stream, against the ~100% the same position took before this rule existed.
    function test_smallestAdmissibleStakeTakesOnlyItsProportionOfAPeriod() public {
        uint256 floor = _graduate();

        // A real LP, the size of the seed the market was graduated with.
        _stakeWide(bob, SEED_LIQ);
        uint256 bobWeight = dist.stakedWeightOf(bob);

        // The smallest stake this market will now take: one basis point of the seed, which is
        // the floor itself to within the rounding of one division. Weighed, not counted: the
        // floor is one basis point of the seed's weight, so a basis point of its liquidity
        // in the same shape clears it by the rounding of one division.
        uint128 smallest = SEED_LIQ / uint128(dist.RENOUNCED_FLOOR_DIVISOR()) + 1;
        assertGe(_w(smallest), floor, "admissible");
        assertLt(_w(smallest), floor * 2, "and barely so: this is the floor, not a stake");

        uint256 tokenId = _mintAndTryStake(carol, smallest);
        assertEq(dist.stakedLiquidityOfPosition(tokenId), smallest, "booked at what it carries");

        _notify(REWARD);
        vm.warp(dist.periodFinish());

        uint256 carolWeight = dist.stakedWeightOf(carol);
        uint256 total = bobWeight + carolWeight;
        assertApproxEqAbs(dist.earned(carol), REWARD * carolWeight / total, 2, "its share, exactly");
        assertApproxEqAbs(dist.earned(bob), REWARD * bobWeight / total, 2, "and bob's is his");

        // The bound that matters, free of the model above: two basis points of the period is
        // an upper bound on what a one-basis-point stake can take. Before the floor the same
        // account, staking a hundred-thousandth of the seed, took all of it.
        assertLt(dist.earned(carol), REWARD * 2 / 10_000, "cannot capture the stream");
        assertGt(dist.earned(bob), REWARD * 9_990 / 10_000, "which stays with the real LP");
    }

    // ─── The ratchet cannot be forged ────────────────────────────────────
    //
    // The floor is a measurement, and a measurement is only worth anything if the thing
    // measured cannot be staged. `renounceRewards` gives the capital straight back — a
    // renounced account's `unstake` is unconditional and takes nothing out of a divisor it is
    // no longer in, so the position comes home in the same transaction — so an open-ended
    // ratchet would let anybody rent a balance for one block and pin the market's admission
    // floor above its real liquidity forever, with no setter to undo it and a shared beacon as
    // the only recovery. Three conditions close that: the measurement happens once per market,
    // only from an account holding the whole staked book, and `configAdmin` can move the
    // result.

    /// @dev How much bigger than the market the attacker's rented position is. One basis point
    ///      of it — what the ratchet would take as the floor — is then the market's whole
    ///      liquidity, which is what makes the attack terminal rather than annoying.
    uint128 constant ATTACK_MULTIPLE = 10_000;

    /// @dev Mint-then-burn over the same range at the same price is not exactly round-trip: v4
    ///      rounds the amounts owed up on the way in and the amounts owed out down on the way
    ///      out. One base unit of the brand on this path — out of the four hundred million the
    ///      attacker posts — and it is the attacker who pays it.
    uint256 constant ROUND_TRIP_DUST = 2;

    event MinStakeWeightSet(uint256 minStakeWeight);

    /// @dev Enough of the market's quote brand to post `ATTACK_MULTIPLE` times its liquidity,
    ///      minted 1:1 from the reserve exactly as anybody could.
    function _mintBrand(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(unit, amount, who);
        vm.stopPrank();
        asset.mint(who, amount * 1e12);
    }

    /// @dev **The attack, end to end, as a regression.** `mint -> stake -> renounceRewards ->
    ///      unstake -> burn`, in one transaction, in a market that already has a liquidity
    ///      provider — the shape of every market now live. The attacker posts ten thousand
    ///      times the market's liquidity, gives up a stream it holds for one call, takes the
    ///      whole position back, and walks away with its capital.
    ///
    ///      What it must not walk away with is the market. Before the sole-staker condition
    ///      this left `minStakeWeight` at one basis point of the rented balance — the market's
    ///      entire real liquidity — so no LP could ever `stake` again, the float and the fee
    ///      stream banked into `undistributed` with nobody able to claim them, and only a
    ///      beacon upgrade moving every live market at once could undo it.
    function test_renounce_mintStakeRenounceUnstakeBurnCannotRatchetALiveMarketsFloor() public {
        // A market shaped like the live ones: an LP is already in.
        _stakeWide(alice, SEED_LIQ);
        assertEq(dist.minStakeWeight(), 0, "an ordinary market has no floor");

        uint128 attackLiq = SEED_LIQ * ATTACK_MULTIPLE;
        _mintBrand(bob, uint256(attackLiq) * 2);

        // What the open-ended ratchet would have written, and what it would have cost the
        // market: a floor at the whole of its real liquidity.
        uint256 wouldBeFloor = _w(attackLiq) / dist.RENOUNCED_FLOOR_DIVISOR();
        // One basis point of ten thousand times the market is the market itself, so every
        // stake smaller than the whole of its existing capital would be refused.
        assertApproxEqAbs(
            wouldBeFloor,
            dist.stakedWeightOf(alice),
            1,
            "precondition: the attack's floor would be the market's entire weight"
        );

        uint256 unitBefore = IERC20(unit).balanceOf(bob);
        uint256 assetBefore = asset.balanceOf(bob);

        uint256 tokenId = _mintWide(bob, attackLiq);
        vm.startPrank(bob);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, bob);
        assertEq(dist.stakedLiquidityOf(bob), attackLiq, "the rented capital is really staked");
        dist.renounceRewards();
        dist.unstake(tokenId);
        posm.burn(tokenId, bob);
        vm.stopPrank();

        // The capital came back, which is what makes the attack free — and therefore what
        // makes a permanent floor measured off it indefensible.
        assertApproxEqAbs(
            IERC20(unit).balanceOf(bob), unitBefore, ROUND_TRIP_DUST, "the brand side came back"
        );
        assertApproxEqAbs(
            asset.balanceOf(bob), assetBefore, ROUND_TRIP_DUST, "and the asset side with it"
        );
        assertEq(posm.ownerOf(tokenId), address(0), "the position is burnt");

        // And the market is exactly where it was.
        assertEq(dist.minStakeWeight(), 0, "the floor did not move: the renouncer was not alone");
        assertEq(dist.stakedLiquidityOf(alice), SEED_LIQ, "the incumbent LP is untouched");
        assertEq(
            dist.totalStaked(),
            dist.stakedWeightOf(alice),
            "and the divisor is the incumbent's alone"
        );

        // The property that matters to an LP: the door is still open, at the market's own size.
        uint256 freshId = _mintAndTryStake(carol, SEED_LIQ);
        assertEq(dist.stakerOf(freshId), carol, "a normal stake is still admitted");
        assertEq(dist.stakedLiquidityOf(carol), SEED_LIQ, "at what it carries");

        // Including the smallest thing this market ever admitted, since there is no floor.
        uint256 dustId = _mintAndTryStake(carol, SEED_LIQ / 100_000);
        assertEq(dist.stakerOf(dustId), carol, "and so is a small one");
    }

    /// @dev The floor still does its job where the job exists. A graduation's seed is the whole
    ///      of a fresh distributor's book when `LaunchLocker.recordPosition` renounces inside
    ///      the same transaction, so the sole-staker condition holds exactly there: dust is
    ///      refused, a proportionate stake is admitted.
    function test_renounce_bySoleStakerStillSetsTheFloorThatDefendsAGraduation() public {
        uint256 floor = _graduate();
        assertEq(
            floor, dist.stakedWeightOf(alice) / dist.RENOUNCED_FLOOR_DIVISOR(), "one bp of the seed"
        );
        assertGt(floor, 1, "and a real number");

        uint128 dust = SEED_LIQ / 100_000;
        uint256 dustId = _mintWide(bob, dust);
        vm.startPrank(bob);
        posm.approve(address(dist), dustId);
        vm.expectRevert(_refusal(dustId, dust, floor));
        dist.stake(dustId, bob);
        vm.stopPrank();

        uint256 realId = _mintAndTryStake(bob, SEED_LIQ / 100);
        assertEq(dist.stakerOf(realId), bob, "and a proportionate stake is admitted");
        assertGt(dist.stakedLiquidityOf(bob), floor, "over the floor it had to clear");
    }

    /// @dev The one shot is spent on the measurement, not on the write. Even a renouncer who
    ///      clears the sole-staker condition — here by waiting for the seed to leave — cannot
    ///      come back with a rented position and raise a floor the market already measured.
    function test_renounce_aSecondRenunciationNeverRaisesTheFloorAgain() public {
        uint256 seedId = _stakeWide(alice, SEED_LIQ);
        _renounce(alice);
        uint256 floor = dist.minStakeWeight();
        assertGt(floor, 0, "the market measured itself once");

        // The book empties, so the next renouncer genuinely is the only staker in it.
        vm.prank(alice);
        dist.unstake(seedId);
        assertEq(dist.stakedLiquidityOf(alice), 0, "nothing is staked");
        assertEq(dist.totalStaked(), 0, "and the divisor is empty");

        uint128 attackLiq = SEED_LIQ * ATTACK_MULTIPLE;
        _mintBrand(bob, uint256(attackLiq) * 2);
        uint256 wouldBeFloor = _w(attackLiq) / dist.RENOUNCED_FLOOR_DIVISOR();
        assertGt(wouldBeFloor, floor, "precondition: it would be a raise if it were allowed");

        uint256 tokenId = _mintWide(bob, attackLiq);
        vm.startPrank(bob);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, bob);
        dist.renounceRewards();
        dist.unstake(tokenId);
        vm.stopPrank();

        assertTrue(dist.rewardsRenounced(bob), "the renunciation itself still took effect");
        assertEq(dist.minStakeWeight(), floor, "but the floor is where the first one left it");

        // Which means the market a graduation sized is still the market anyone can join.
        uint256 realId = _mintAndTryStake(carol, SEED_LIQ / 100);
        assertEq(dist.stakerOf(realId), carol, "a proportionate stake is admitted");
    }

    /// @dev The condition that protects every market already live: a renunciation by an account
    ///      that is not the whole book sets no floor at all, however large it is. And it does
    ///      not spend the one shot either — a measurement that was never taken is still owed.
    function test_renounce_byANonSoleStakerSetsNoFloorAndSpendsNoShot() public {
        uint256 aliceId = _stakeWide(alice, SEED_LIQ);

        uint128 bigLiq = SEED_LIQ * ATTACK_MULTIPLE;
        _mintBrand(bob, uint256(bigLiq) * 2);
        uint256 bigId = _mintWide(bob, bigLiq);
        vm.startPrank(bob);
        posm.approve(address(dist), bigId);
        dist.stake(bigId, bob);
        dist.renounceRewards();
        vm.stopPrank();

        assertEq(dist.minStakeWeight(), 0, "a co-staker's renunciation measures nothing");

        // The stream still redirects — the floor is the only thing the condition gates.
        _notify(REWARD);
        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(alice), REWARD, 2, "the whole stream reaches the real LP");
        assertEq(dist.earned(bob), 0, "and none of it the renouncer");

        // Nothing was spent: both positions leave, and a real seed can still measure the
        // market it seeds.
        vm.prank(bob);
        dist.unstake(bigId);
        vm.prank(alice);
        dist.unstake(aliceId);
        assertEq(dist.totalStaked(), 0, "the book is empty");

        _stakeWide(carol, SEED_LIQ);
        _renounce(carol);
        assertEq(
            dist.minStakeWeight(),
            dist.stakedWeightOf(carol) / dist.RENOUNCED_FLOOR_DIVISOR(),
            "a sole staker's renunciation still measures the market"
        );
    }

    /// @dev The way back from a floor that is wrong, which is the whole reason a setter exists:
    ///      without one, a floor above the market's liquidity can only be undone by upgrading
    ///      the beacon every live market shares. It is `configAdmin` — the protocol timelock
    ///      that already owns that beacon — and it moves admission only, so nothing staked
    ///      shifts by a wei in either direction.
    function test_setMinStakeWeight_isConfigAdminOnlyAndLowersWithoutTouchingAStake() public {
        uint256 floor = _graduate();
        uint256 tokenId = _mintAndTryStake(bob, SEED_LIQ / 100);
        uint256 staked = dist.stakedLiquidityOf(bob);
        uint256 totalBefore = dist.totalStaked();

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 earnedBefore = dist.earned(bob);
        assertGt(earnedBefore, 0, "precondition: the stake is earning");

        // Not anyone's to move, including the staker whose door it is.
        vm.prank(bob);
        vm.expectRevert(LpRewardDistributor.NotConfigAdmin.selector);
        dist.setMinStakeWeight(1);
        vm.prank(carol);
        vm.expectRevert(LpRewardDistributor.NotConfigAdmin.selector);
        dist.setMinStakeWeight(0);
        assertEq(dist.minStakeWeight(), floor, "and nothing moved");

        address admin = dist.configAdmin();
        assertEq(admin, stackOwner, "the guard's owner, as everywhere else in this contract");

        uint256 lowered = floor / 100;
        vm.expectEmit(true, true, true, true, address(dist));
        emit MinStakeWeightSet(lowered);
        vm.prank(admin);
        dist.setMinStakeWeight(lowered);
        assertEq(dist.minStakeWeight(), lowered, "the floor came down");

        // The stake that was admitted over the old floor is exactly as it was.
        assertEq(dist.stakerOf(tokenId), bob, "still staked");
        assertEq(dist.stakedLiquidityOf(bob), staked, "at the same liquidity");
        assertEq(dist.totalStaked(), totalBefore, "and the book is unchanged");
        assertEq(dist.earned(bob), earnedBefore, "with its accrual untouched");

        // What the old floor refused is now admitted, at what it carries.
        uint128 dust = SEED_LIQ / 100_000;
        assertLt(_w(dust), floor, "it would have been refused before");
        assertGt(_w(dust), lowered, "and clears the lowered bar");
        uint256 dustId = _mintAndTryStake(carol, dust);
        assertEq(dist.stakerOf(dustId), carol, "admitted");

        // All the way to zero restores the original rule: any liquidity at all.
        vm.prank(admin);
        dist.setMinStakeWeight(0);
        assertEq(dist.minStakeWeight(), 0, "the floor is gone");

        uint128 belowLowered = SEED_LIQ / 10_000_000;
        assertLt(_w(belowLowered), lowered, "smaller than the lowered floor admitted");
        uint256 smallestId = _mintAndTryStake(carol, belowLowered);
        assertEq(dist.stakerOf(smallestId), carol, "and it goes in now that there is no floor");
    }
}
