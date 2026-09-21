// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice A hook that is nothing but the oracle half of `ProtocolFeeHook`: enough of
///         `IPoolOracle` for a distributor to price a stake against, and a switch for the
///         case every young market starts in, where the buffer cannot reach back far enough
///         and `consultTick` reverts.
contract StandInOracleHook {
    int24 public meanTick;
    bool public broken;

    error NoHistory();

    function setMean(int24 tick) external {
        meanTick = tick;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function consultTick(PoolKey calldata, uint32) external view returns (int24) {
        if (broken) revert NoHistory();
        return meanTick;
    }
}

/// @title ConcentratedLpRewardsTest
/// @notice What changes when the distributor stops refusing concentrated positions.
///
///         A stake's weight is the capital the position holds, valued in `currency1` at the
///         hook's mean price — not its `liquidity`, which a narrow band buys cheaply and which
///         is not comparable across widths. These cases pin the four things that has to mean:
///         equal money earns equally however wide the range, a band with more liquidity and
///         less money earns less, the price behind a weight is the oracle's rather than a spot
///         anyone can move, and a distributor that already holds full-range stakes keeps
///         paying them across the upgrade.
contract ConcentratedLpRewardsTest is StackFixture {
    PoolManager manager;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;
    MockAsset asset;

    address unit;
    LpRewardDistributor dist;
    PoolKey key;

    address owner = address(0x0AD01);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint32 constant DURATION = 7 days;

    uint256 constant FLOAT = 1_000_000e6;
    uint256 constant REWARD = 7_000e6;

    /// @dev Only `BEFORE_DONATE` is set, which this pool never does, so the stand-in oracle is
    ///      a valid hook address that the `PoolManager` never actually calls into.
    address constant ORACLE_HOOK = address(uint160(0x1111_0020));

    // The distributor's own layout, as a live market's storage holds it. The rewind test
    // asserts each of these is the slot it thinks it is before writing to it, so a layout
    // change fails loudly rather than quietly testing nothing.
    uint256 constant SLOT_REWARD_RATE = 8;
    uint256 constant SLOT_TOTAL_STAKED = 14;
    uint256 constant SLOT_STAKED_WEIGHT = 25;
    uint256 constant SLOT_POSITION_WEIGHT = 26;
    uint256 constant SLOT_ACTIVATED_AND_PRICE = 27;
    uint256 constant SLOT_WEIGHT_EPOCH = 28;

    function setUp() public {
        _deployUpgradeBase();

        manager = new PoolManager(address(this));
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);
        asset = new MockAsset();

        (unit,) = reserve.registerBrand("NVDA Market Dollar", "NVDA.d", address(this));

        key = _poolKey(address(0));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        dist = _deployDistributor(key);

        _fund(alice);
        _fund(bob);
        _fund(address(this));
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _poolKey(address hooks) internal view returns (PoolKey memory) {
        (address c0, address c1) =
            unit < address(asset) ? (unit, address(asset)) : (address(asset), unit);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
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

    /// @dev Mint an exact liquidity over an exact range, which amounts alone cannot do — and
    ///      holding the liquidity is how a test holds the capital constant across two widths.
    function _mintIn(PoolKey memory k, address who, int24 tickLower, int24 tickUpper, uint128 liq)
        internal
        returns (uint256 tokenId)
    {
        vm.startPrank(who);
        IERC20(Currency.unwrap(k.currency0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(k.currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(k.currency0), address(posm), type(uint160).max, type(uint48).max
        );
        permit2.approve(
            Currency.unwrap(k.currency1), address(posm), type(uint160).max, type(uint48).max
        );

        bytes memory actions = abi.encodePacked(uint8(0x02), uint8(0x0d));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            k,
            tickLower,
            tickUpper,
            uint256(liq),
            type(uint128).max,
            type(uint128).max,
            who,
            bytes("")
        );
        params[1] = abi.encode(k.currency0, k.currency1);

        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();
    }

    function _stakeIn(
        PoolKey memory k,
        LpRewardDistributor d,
        address who,
        int24 tickLower,
        int24 tickUpper,
        uint128 liq
    ) internal returns (uint256 tokenId) {
        tokenId = _mintIn(k, who, tickLower, tickUpper, liq);
        vm.startPrank(who);
        posm.approve(address(d), tokenId);
        d.stake(tokenId, who);
        vm.stopPrank();
    }

    function _stake(address who, int24 tickLower, int24 tickUpper, uint128 liq)
        internal
        returns (uint256 tokenId)
    {
        return _stakeIn(key, dist, who, tickLower, tickUpper, liq);
    }

    function _notify(uint256 amount) internal {
        IERC20(unit).transfer(address(dist), amount);
        dist.notifyReward(amount);
    }

    /// @dev The liquidity a range of this width needs to hold `targetWeight` of capital.
    ///      Weight is linear in liquidity for a fixed range and price, so one measurement
    ///      scales.
    function _liquidityForWeight(uint256 targetWeight, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128)
    {
        uint256 perUnit = dist.stakeWeightFor(1e18, tickLower, tickUpper);
        return uint128(FullMath.mulDiv(targetWeight, 1e18, perUnit));
    }

    // ─── Capital, not liquidity ──────────────────────────────────────────

    /// @dev The property the whole change exists for. Both positions hold the same money; one
    ///      spreads it over every tick and the other over a 6% band, which buys it more than
    ///      thirty times the liquidity. Weighting by liquidity would have paid the band thirty
    ///      times as much for the same capital.
    function test_equalCapitalDifferentWidthsEarnTheSame() public {
        (int24 lower, int24 upper) = dist.fullRange();

        uint128 fullLiquidity = 2e10;
        uint256 target = dist.stakeWeightFor(fullLiquidity, lower, upper);
        uint128 bandLiquidity = _liquidityForWeight(target, -600, 600);
        assertGt(bandLiquidity, uint256(fullLiquidity) * 10, "the band buys far more liquidity");

        _stake(alice, lower, upper, fullLiquidity);
        _stake(bob, -600, 600, bandLiquidity);

        assertApproxEqRel(
            dist.stakedWeightOf(alice), dist.stakedWeightOf(bob), 1e12, "the same capital"
        );
        assertEq(
            dist.totalStaked(),
            dist.stakedWeightOf(alice) + dist.stakedWeightOf(bob),
            "the total is the exact sum of the two"
        );

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);

        assertApproxEqRel(dist.earned(alice), dist.earned(bob), 1e12, "so the same reward");
        assertApproxEqAbs(dist.earned(alice) + dist.earned(bob), REWARD, 3, "and nothing more");
    }

    /// @dev The other direction: more liquidity, less money, less reward.
    function test_moreLiquidityWithLessCapitalEarnsLess() public {
        uint128 narrowLiquidity = 6e11;
        uint256 narrowWeight = dist.stakeWeightFor(narrowLiquidity, -600, 600);

        // A wider band holding twice the money on a fraction of the liquidity.
        uint128 wideLiquidity = _liquidityForWeight(narrowWeight * 2, -6000, 6000);
        assertLt(wideLiquidity, narrowLiquidity, "less liquidity");

        uint256 narrowId = _stake(alice, -600, 600, narrowLiquidity);
        _stake(bob, -6000, 6000, wideLiquidity);

        assertEq(dist.stakerOf(narrowId), alice, "a band is no longer refused");
        assertApproxEqRel(
            dist.stakedWeightOf(bob), 2 * dist.stakedWeightOf(alice), 1e12, "twice the capital"
        );

        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);

        assertGt(dist.earned(alice), 0, "the band earns");
        assertApproxEqRel(dist.earned(bob), 2 * dist.earned(alice), 1e12, "twice the reward");
        assertApproxEqAbs(dist.earned(alice) + dist.earned(bob), REWARD, 3, "and no more");
    }

    /// @dev A market whose LPs are all full range splits its float exactly as it did before,
    ///      because one width makes capital and liquidity the same ranking.
    function test_fullRangeStakesStillSplitByLiquidity() public {
        (int24 lower, int24 upper) = dist.fullRange();

        _stake(alice, lower, upper, 1e10);
        _stake(bob, lower, upper, 3e10);
        _notify(REWARD);

        vm.warp(vm.getBlockTimestamp() + DURATION);

        assertApproxEqAbs(dist.earned(alice), REWARD / 4, 2, "a quarter");
        assertApproxEqAbs(dist.earned(bob), 3 * REWARD / 4, 2, "three quarters");
    }

    function test_aRangeHoldingNothingIsRefused() public {
        // One unit of liquidity over one tick spacing: a real position, holding less than one
        // whole unit of `currency1` in total.
        uint256 tokenId = _mintIn(key, alice, 0, TICK_SPACING, 1);
        assertEq(dist.stakeWeightFor(1, 0, TICK_SPACING), 0, "nothing to weigh");

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        vm.expectRevert(abi.encodeWithSelector(LpRewardDistributor.ZeroWeight.selector, tokenId));
        dist.stake(tokenId, alice);
        vm.stopPrank();
    }

    // ─── The price behind a weight ───────────────────────────────────────

    /// @dev A weight is money, so the price it is struck at must not be one the staker can set
    ///      in the same block. The hook's mean is preferred; the pool's spot is the fallback
    ///      for a market whose oracle cannot answer yet, and the two are distinguishable.
    function test_stakeIsPricedOnTheHookMeanAndFallsBackToSpot() public {
        vm.etch(ORACLE_HOOK, address(new StandInOracleHook()).code);
        StandInOracleHook oracle = StandInOracleHook(ORACLE_HOOK);

        PoolKey memory oracleKey = _poolKey(ORACLE_HOOK);
        manager.initialize(oracleKey, TickMath.getSqrtPriceAtTick(0));
        LpRewardDistributor oracleDist = _deployDistributor(oracleKey);

        // The mean says one thing, the pool says another — as it would mid-manipulation.
        oracle.setMean(2000);
        (uint160 priceUsed, bool fromTwap) = oracleDist.stakeSqrtPrice();
        assertTrue(fromTwap, "the mean is preferred");
        assertEq(priceUsed, TickMath.getSqrtPriceAtTick(2000), "and it is the mean");

        uint128 liquidity = 2e10;
        uint256 twapId = _stakeIn(oracleKey, oracleDist, alice, -6000, 6000, liquidity);
        assertEq(
            oracleDist.stakedWeightOfPosition(twapId),
            oracleDist.weightForPosition(liquidity, -6000, 6000, TickMath.getSqrtPriceAtTick(2000)),
            "weighed at the mean, not at spot"
        );

        // A market whose buffer cannot reach back the window is not unstakeable: it is priced
        // at spot, and the stake event says so.
        oracle.setBroken(true);
        (uint160 spotPrice, bool stillTwap) = oracleDist.stakeSqrtPrice();
        assertFalse(stillTwap, "no mean available");
        assertEq(spotPrice, TickMath.getSqrtPriceAtTick(0), "the pool's own price");

        uint256 spotId = _stakeIn(oracleKey, oracleDist, bob, -6000, 6000, liquidity);
        assertEq(
            oracleDist.stakedWeightOfPosition(spotId),
            oracleDist.weightForPosition(liquidity, -6000, 6000, spotPrice),
            "weighed at spot when there is nothing better"
        );
    }

    // ─── Solvency and the exit ───────────────────────────────────────────

    function test_claimsNeverExceedWhatWasNotified() public {
        _stake(alice, -600, 600, 6e11);
        _stake(bob, -6000, 6000, 1e11);
        _notify(REWARD);

        // Well past the end of the period: there is nothing left to stream, and the two
        // stakers between them cannot take more than the one amount that was funded.
        vm.warp(vm.getBlockTimestamp() + DURATION * 3);

        vm.prank(alice);
        dist.claim(unit);
        vm.prank(bob);
        dist.claim(unit);

        assertLe(dist.totalClaimed(), dist.totalNotified(), "never more than was funded");
        assertApproxEqAbs(dist.totalClaimed(), REWARD, 3, "and effectively all of it");
        assertEq(
            IERC20(unit).balanceOf(address(dist)),
            dist.outstandingRewards(),
            "what is left is exactly what is still owed"
        );
    }

    function test_aPausedProtocolStillLetsAConcentratedPositionOut() public {
        uint256 tokenId = _stake(alice, -600, 600, 6e11);
        _notify(REWARD);
        vm.warp(vm.getBlockTimestamp() + DURATION);

        uint256 owed = dist.earned(alice);
        assertGt(owed, 0, "there is something to keep");

        _pauseProtocol();

        vm.startPrank(alice);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        dist.claim(unit);

        dist.unstake(tokenId);
        vm.stopPrank();

        assertEq(posm.ownerOf(tokenId), alice, "the position came home while halted");
        assertEq(dist.totalStaked(), 0, "and took its whole weight with it");
        assertEq(dist.earned(alice), owed, "the accrual is still there to claim later");
    }

    // ─── Upgrading a distributor that already holds stakes ───────────────

    /// @dev Rewinds a live distributor to the shape the full-range-only version left behind —
    ///      stakes measured in raw liquidity, a rate on the old 1e18 scale, nothing written in
    ///      any appended slot — with a period already running, and checks the conversion on
    ///      the next state change is invisible. Half the reward is earned under the old
    ///      accounting and half under the new, and the two have to add up to the split the
    ///      old version promised, on a market whose LPs never did anything.
    function test_stakesFromTheFullRangeOnlyVersionSurviveTheUpgrade() public {
        (int24 lower, int24 upper) = dist.fullRange();
        uint128 aliceLiquidity = 1e10;
        uint128 bobLiquidity = 3e10;

        uint256 aliceId = _stake(alice, lower, upper, aliceLiquidity);
        uint256 bobId = _stake(bob, lower, upper, bobLiquidity);
        _notify(REWARD);

        // Exactly the state the previous version would hold one block after its vault swept:
        // two full-range stakes counted as liquidity, a rate on the 1e18 scale, an accumulator
        // that has not moved yet.
        uint256 legacyRate = dist.rewardRate() >> 64;
        _rewindToRawLiquidity(aliceId, bobId, uint256(aliceLiquidity) + bobLiquidity);
        assertEq(dist.weightsActivatedAt(), 0, "and no weighting");

        // The first half of the period runs entirely under that old accounting.
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        vm.prank(alice);
        uint256 aliceFirstHalf = dist.claim(unit);
        assertApproxEqAbs(aliceFirstHalf, REWARD / 8, 3, "a quarter of half the period");

        // That same claim was the first state change after the upgrade, so it converted.
        assertGt(dist.weightsActivatedAt(), 0, "converted");
        assertGt(dist.legacySqrtPriceX96(), 0, "at a recorded price");
        assertEq(
            dist.rewardRate(),
            legacyRate << 64,
            "the rate moved by exactly the factor the scale did"
        );
        assertEq(
            dist.totalStaked(),
            dist.stakeWeightFor(aliceLiquidity + bobLiquidity, lower, upper),
            "the old book, re-measured as capital"
        );
        assertApproxEqRel(
            dist.stakedWeightOf(bob), 3 * dist.stakedWeightOf(alice), 1e12, "and each stake with it"
        );

        // Bob was never touched, so his half-period of old accrual is still owed, on the old
        // basis, and the rest of the period accrues to him on the new one.
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        assertApproxEqAbs(dist.earned(alice), REWARD / 8, 3, "alice's second half");
        assertApproxEqAbs(dist.earned(bob), 3 * REWARD / 4, 4, "bob's whole three quarters");
        assertApproxEqAbs(
            aliceFirstHalf + dist.earned(alice) + dist.earned(bob),
            REWARD,
            6,
            "and the two halves are the whole reward, not more"
        );

        vm.prank(bob);
        dist.claim(unit);
        assertLe(dist.totalClaimed(), dist.totalNotified(), "never more than was funded");

        // And the exit still subtracts exactly what the stake added, on both sides of it.
        vm.prank(alice);
        dist.unstake(aliceId);
        vm.prank(bob);
        dist.unstake(bobId);
        assertEq(dist.totalStaked(), 0, "nothing stranded in the total");
    }

    /// @dev Put the distributor back into the pre-weighting shape: raw-liquidity stakes, a
    ///      rate at the old 1e18 scale, and nothing written in any of the appended slots.
    function _rewindToRawLiquidity(uint256 aliceId, uint256 bobId, uint256 rawTotal) internal {
        assertEq(
            uint256(vm.load(address(dist), bytes32(SLOT_TOTAL_STAKED))),
            dist.totalStaked(),
            "totalStaked slot"
        );
        assertEq(
            uint256(vm.load(address(dist), bytes32(SLOT_REWARD_RATE))),
            dist.rewardRate(),
            "rewardRate slot"
        );
        assertEq(
            uint256(vm.load(address(dist), bytes32(SLOT_ACTIVATED_AND_PRICE))) & type(uint64).max,
            uint256(dist.weightsActivatedAt()),
            "activation slot"
        );

        bytes32 aliceWeightSlot = keccak256(abi.encode(alice, SLOT_STAKED_WEIGHT));
        assertEq(
            uint256(vm.load(address(dist), aliceWeightSlot)),
            dist.stakedWeightOf(alice),
            "account weight slot"
        );
        bytes32 alicePositionSlot = keccak256(abi.encode(aliceId, SLOT_POSITION_WEIGHT));
        assertEq(
            uint256(vm.load(address(dist), alicePositionSlot)),
            dist.stakedWeightOfPosition(aliceId),
            "position weight slot"
        );

        vm.store(address(dist), bytes32(SLOT_TOTAL_STAKED), bytes32(rawTotal));
        vm.store(address(dist), bytes32(SLOT_REWARD_RATE), bytes32(dist.rewardRate() >> 64));
        vm.store(address(dist), bytes32(SLOT_ACTIVATED_AND_PRICE), bytes32(uint256(0)));
        vm.store(address(dist), bytes32(SLOT_WEIGHT_EPOCH), bytes32(uint256(0)));
        vm.store(address(dist), aliceWeightSlot, bytes32(uint256(0)));
        vm.store(address(dist), keccak256(abi.encode(bob, SLOT_STAKED_WEIGHT)), bytes32(uint256(0)));
        vm.store(address(dist), alicePositionSlot, bytes32(uint256(0)));
        vm.store(
            address(dist), keccak256(abi.encode(bobId, SLOT_POSITION_WEIGHT)), bytes32(uint256(0))
        );
    }
}
