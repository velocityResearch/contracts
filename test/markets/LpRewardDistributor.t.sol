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
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title LpRewardDistributorTest
/// @notice The reward stream, the stake's admission rules, and the two properties the whole
///         contract exists for: that liquidity held for zero seconds earns zero, and that a
///         staker can always get their position back.
///
///         **The venue is a real `PoolManager`.** Positions are minted through the stand-in
///         `PositionManager` the router's suite already uses, which adds the liquidity to the
///         real singleton — so the liquidity numbers this contract weights by are Uniswap's
///         arithmetic, and the fees `collectFees` moves are real swap fees.
///
///         **The reward token is a real pooled brand,** so `claim(brandOut)`'s 1:1 conversion
///         goes through the real `SharedReservePool`, not a mock of it. The vault is this test
///         contract: `notifyReward` takes one caller, and standing in for it is what lets every
///         reward case be driven directly.
contract LpRewardDistributorTest is StackFixture {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    PoolSwapTest poolSwap;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;
    MockAsset asset;

    address unit; // the market unit: the brand the pool holds and rewards are paid in
    address otherBrand; // a representation brand of the same reserve
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
        (otherBrand,) = reserve.registerBrand("Alice Dollar", "aliceUSD", address(this));

        key = _poolKey(unit, address(asset));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        dist = _deployDistributor(key, unit, address(this));

        // Everyone gets brand tokens and asset to seed positions with, and the test contract
        // gets a reward float to notify from.
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(address(this));
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _poolKey(address brand, address assetToken) internal pure returns (PoolKey memory) {
        (address c0, address c1) = brand < assetToken ? (brand, assetToken) : (assetToken, brand);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev Behind a beacon, exactly as a market's distributor is deployed in production.
    function _deployDistributor(PoolKey memory k, address rewardToken, address vault)
        internal
        returns (LpRewardDistributor)
    {
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
                            rewardToken,
                            vault,
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

    /// @dev Mint a position through the stand-in and hand it back, unstaked.
    function _mintPosition(address who, uint256 brandAmount, uint256 assetAmount, bool fullRange)
        internal
        returns (uint256 tokenId)
    {
        (int24 tickLower, int24 tickUpper) = fullRange
            ? (TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING))
            : (int24(-6000), int24(6000));
        return _mintPositionIn(key, who, brandAmount, assetAmount, tickLower, tickUpper);
    }

    function _mintPositionIn(
        PoolKey memory k,
        address who,
        uint256 brandAmount,
        uint256 assetAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256 tokenId) {
        bool brandIsCurrency0 = Currency.unwrap(k.currency0) == unit;
        (uint256 amount0, uint256 amount1) =
            brandIsCurrency0 ? (brandAmount, assetAmount) : (assetAmount, brandAmount);

        (uint160 sqrtPriceX96,,,) = _slot0(k);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        require(liquidity > 0, "no liquidity");

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
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            who,
            bytes("")
        );
        params[1] = abi.encode(k.currency0, k.currency1);

        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();
    }

    function _slot0(PoolKey memory k)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(k.toId()), uint256(6)));
        bytes32 data = vm.load(address(manager), slot);
        sqrtPriceX96 = uint160(uint256(data));
        tick = int24(uint24(uint256(data) >> 160));
        protocolFee = uint24(uint256(data) >> 184);
        lpFee = uint24(uint256(data) >> 208);
    }

    /// @dev Mint a full-range position and stake it, in the caller's own name.
    function _stakeNew(address who, uint256 brandAmount, uint256 assetAmount)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mintPosition(who, brandAmount, assetAmount, true);
        vm.startPrank(who);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, who);
        vm.stopPrank();
    }

    /// @dev What the vault does: send the reward, then say so.
    function _notify(uint256 amount) internal {
        IERC20(unit).transfer(address(dist), amount);
        dist.notifyReward(amount);
    }

    // ─── Staking admission ───────────────────────────────────────────────

    function test_stakeCreditsLiquidityAndTakesCustody() public {
        uint256 tokenId = _mintPosition(alice, 10_000e6, 10_000e18, true);
        uint128 liquidity = posm.getPositionLiquidity(tokenId);

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, alice);
        vm.stopPrank();

        assertEq(posm.ownerOf(tokenId), address(dist), "custody");
        assertEq(dist.stakerOf(tokenId), alice, "credited");
        assertEq(dist.stakedLiquidityOf(alice), liquidity, "weight");
        assertEq(dist.totalStaked(), liquidity, "total");
        assertEq(dist.positionsOf(alice).length, 1, "listed");
    }

    function test_stakeRejectsAPositionFromAnotherPool() public {
        MockAsset other = new MockAsset();
        other.mint(alice, 1_000_000e18);
        PoolKey memory otherKey = _poolKey(unit, address(other));
        manager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        uint256 tokenId = _mintPositionIn(
            otherKey,
            alice,
            10_000e6,
            10_000e18,
            TickMath.minUsableTick(TICK_SPACING),
            TickMath.maxUsableTick(TICK_SPACING)
        );

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        vm.expectRevert(LpRewardDistributor.WrongPool.selector);
        dist.stake(tokenId, alice);
        vm.stopPrank();
    }

    /// @dev The packed `PositionInfo` id is truncated to 25 bytes, so a contract that compared
    ///      it against a v4-core `PoolId` would reject its own pool. This asserts the pool the
    ///      distributor accepts is the one whose *full* id matches — the comparison the naive
    ///      version gets wrong.
    function test_packedPoolIdIsTruncatedButTheRightPoolStillStakes() public {
        uint256 tokenId = _mintPosition(alice, 10_000e6, 10_000e18, true);
        (PoolKey memory reported, uint256 info) = posm.getPoolAndPositionInfo(tokenId);

        bytes32 fullId = PoolId.unwrap(key.toId());
        assertEq(PoolId.unwrap(reported.toId()), fullId, "key round-trips");
        assertTrue(bytes32(info) != fullId, "packed id is not the pool id");
        assertEq(
            bytes32(info) & bytes32(type(uint256).max << 56),
            fullId & bytes32(type(uint256).max << 56),
            "only the top 200 bits survive"
        );

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, alice);
        vm.stopPrank();
        assertEq(dist.stakerOf(tokenId), alice, "accepted on the full key");
    }

    function test_stakeRejectsAConcentratedPosition() public {
        uint256 tokenId = _mintPosition(alice, 10_000e6, 10_000e18, false);

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(LpRewardDistributor.NotFullRange.selector, -6000, 6000)
        );
        dist.stake(tokenId, alice);
        vm.stopPrank();
    }

    function test_stakeRejectsAZeroBeneficiary() public {
        uint256 tokenId = _mintPosition(alice, 10_000e6, 10_000e18, true);

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        vm.expectRevert(LpRewardDistributor.ZeroAddress.selector);
        dist.stake(tokenId, address(0));
        vm.stopPrank();
    }

    function test_stakeRejectsAnEmptyPosition() public {
        uint256 tokenId = _stakeNew(alice, 10_000e6, 10_000e18);
        vm.prank(alice);
        dist.unstake(tokenId);

        // Drain it through the periphery, then try to stake the husk.
        vm.prank(alice);
        posm.burn(tokenId, alice);

        // No approval needed: the liquidity check comes before the transfer, which is the
        // point — a husk is refused without anyone having to hand it over first.
        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.NoLiquidity.selector);
        dist.stake(tokenId, alice);
        vm.stopPrank();
    }

    function test_stakeCanCreditSomeoneOtherThanTheCaller() public {
        uint256 tokenId = _mintPosition(alice, 10_000e6, 10_000e18, true);
        uint128 liquidity = posm.getPositionLiquidity(tokenId);

        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, bob);
        vm.stopPrank();

        assertEq(dist.stakerOf(tokenId), bob, "credited to the beneficiary");
        assertEq(dist.stakedLiquidityOf(alice), 0, "not to the caller");
        assertEq(dist.stakedLiquidityOf(bob), liquidity, "weight");

        // And the beneficiary is who may take it out.
        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.OnlyStaker.selector);
        dist.unstake(tokenId);

        vm.prank(bob);
        dist.unstake(tokenId);
        assertEq(posm.ownerOf(tokenId), bob, "returned to the beneficiary");
    }

    function test_directTransferIsRefused() public {
        vm.expectRevert(LpRewardDistributor.NotStaked.selector);
        dist.onERC721Received(alice, alice, 1, "");
    }

    // ─── The property the contract exists for ────────────────────────────

    /// @dev Stake, sweep, unstake, all in one block. The old donation path would have paid this
    ///      position almost the entire harvest.
    function test_justInTimeLiquidityEarnsNothing() public {
        // Someone else has been providing liquidity for a week.
        _stakeNew(bob, 50_000e6, 50_000e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 tokenId = _mintPosition(alice, 500_000e6, 500_000e18, true);
        vm.startPrank(alice);
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, alice);
        vm.stopPrank();

        _notify(REWARD);

        assertEq(dist.earned(alice), 0, "nothing for zero seconds");

        vm.prank(alice);
        dist.unstake(tokenId);
        assertEq(dist.earned(alice), 0, "still nothing after unstaking");

        // And the reward is intact for the LP who was actually there.
        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertApproxEqAbs(dist.earned(bob), REWARD, 1, "the whole period to the real LP");
    }

    function test_rewardsSplitByLiquidityAndTime() public {
        uint256 aliceToken = _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);

        // Half the period with Alice alone.
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 aliceHalf = dist.earned(alice);
        assertApproxEqAbs(aliceHalf, REWARD / 2, 2, "alone for half the period");

        // Bob joins with the same liquidity for the rest.
        uint256 bobToken = _stakeNew(bob, 10_000e6, 10_000e18);
        assertEq(
            posm.getPositionLiquidity(aliceToken),
            posm.getPositionLiquidity(bobToken),
            "equal weights"
        );
        assertEq(dist.earned(bob), 0, "bob starts at zero");
        assertApproxEqAbs(dist.earned(alice), aliceHalf, 2, "bob's arrival takes nothing back");

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        assertApproxEqAbs(dist.earned(bob), REWARD / 4, 2, "a quarter of the period, halved");
        assertApproxEqAbs(dist.earned(alice), REWARD / 2 + REWARD / 4, 2, "half plus a quarter");
    }

    // ─── The stream ──────────────────────────────────────────────────────

    function test_notifyDuringAPeriodRaisesTheRateAndKeepsTheEndDate() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);

        uint256 finish = dist.periodFinish();
        uint256 rate = dist.rewardRate();

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        _notify(REWARD);

        assertEq(dist.periodFinish(), finish, "end date is fixed");
        // Half of the first reward plus all of the second, over the remaining half period.
        assertApproxEqRel(dist.rewardRate(), rate * 3, 1e12, "rate carries the whole tail");

        vm.warp(finish);
        assertApproxEqAbs(dist.earned(alice), 2 * REWARD, 4, "both rewards paid in full");
    }

    function test_aFinishedPeriodStartsAFreshOne() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);

        vm.warp(dist.periodFinish() + 1 days);
        _notify(REWARD);

        assertEq(dist.periodFinish(), vm.getBlockTimestamp() + DURATION, "new period");
    }

    /// @dev The A5/B2 case: a reward streams while nothing is staked. It must not be handed to
    ///      whoever stakes next, and it must not be lost either.
    function test_rewardStreamedWithNothingStakedIsBankedNotGiftedToTheNextStaker() public {
        _notify(REWARD);

        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        assertEq(dist.totalStaked(), 0, "nobody staked");

        _stakeNew(alice, 10_000e6, 10_000e18);
        assertEq(dist.earned(alice), 0, "the backlog is not a windfall");
        assertApproxEqAbs(dist.undistributed(), REWARD, 1, "it is banked");

        // The next sweep restreams it alongside its own amount.
        _notify(REWARD);
        assertEq(dist.undistributed(), 0, "folded in");

        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertApproxEqAbs(dist.earned(alice), 2 * REWARD, 2, "both rewards, earned over time");
    }

    function test_partialIdleTimeIsSplitBetweenBankAndStream() public {
        _notify(REWARD);

        // A quarter of the period with nobody staked, then Alice for the rest.
        vm.warp(vm.getBlockTimestamp() + DURATION / 4);
        _stakeNew(alice, 10_000e6, 10_000e18);
        assertApproxEqAbs(dist.undistributed(), REWARD / 4, 2, "the idle quarter is banked");

        vm.warp(dist.periodFinish());
        assertApproxEqAbs(dist.earned(alice), REWARD * 3 / 4, 2, "the rest streamed to Alice");
    }

    function test_notifyRefusesToPromiseMoreThanItHolds() public {
        _stakeNew(alice, 10_000e6, 10_000e18);

        // The vault says it sent a reward it did not send.
        vm.expectRevert(
            abi.encodeWithSelector(
                LpRewardDistributor.InsufficientRewardBalance.selector, 0, REWARD
            )
        );
        dist.notifyReward(REWARD);
    }

    function test_onlyTheVaultMayNotify() public {
        IERC20(unit).transfer(address(dist), REWARD);

        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.OnlyVault.selector);
        dist.notifyReward(REWARD);
    }

    // ─── Claiming ────────────────────────────────────────────────────────

    function test_claimPaysTheMarketUnit() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        uint256 owed = dist.earned(alice);
        uint256 before = IERC20(unit).balanceOf(alice);

        vm.prank(alice);
        uint256 paid = dist.claim(unit);

        assertEq(paid, owed, "paid what was earned");
        assertEq(IERC20(unit).balanceOf(alice) - before, owed, "in the unit");
        assertEq(dist.earned(alice), 0, "nothing left");
        assertEq(dist.totalClaimed(), owed, "accounted");
    }

    /// @dev One transaction, and the LP walks away holding their own community's brand.
    function test_claimPaysAnyBrandOfTheSameReserveOneToOne() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        uint256 owed = dist.earned(alice);
        uint256 beforeOther = IERC20(otherBrand).balanceOf(alice);
        uint256 beforeUnit = IERC20(unit).balanceOf(alice);

        vm.prank(alice);
        dist.claim(otherBrand);

        assertEq(IERC20(otherBrand).balanceOf(alice) - beforeOther, owed, "1:1 into the brand");
        assertEq(IERC20(unit).balanceOf(alice), beforeUnit, "no unit touched the wallet");
        // At most the accumulator's rounding dust stays behind: `earned` divides by staked
        // liquidity, so the last wei of a period is not always attributable to anyone.
        assertLe(IERC20(unit).balanceOf(address(dist)), 1, "the unit was burned, not held");
    }

    function test_claimRejectsATokenThatIsNotABrandOfThisReserve() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LpRewardDistributor.BrandNotInReserve.selector, address(asset))
        );
        dist.claim(address(asset));
    }

    function test_claimWithNothingEarnedReverts() public {
        vm.prank(alice);
        vm.expectRevert(LpRewardDistributor.ZeroAmount.selector);
        dist.claim(unit);
    }

    function test_unstakingKeepsAccruedRewardsClaimable() public {
        uint256 tokenId = _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        uint256 owed = dist.earned(alice);
        vm.startPrank(alice);
        dist.unstake(tokenId);
        assertEq(dist.earned(alice), owed, "accrual survives the exit");
        uint256 paid = dist.claim(unit);
        vm.stopPrank();

        assertEq(paid, owed, "and is payable afterwards");
    }

    // ─── Fees on a staked position ───────────────────────────────────────

    function test_collectFeesPaysTheStakerAndLeavesTheStakeAlone() public {
        uint256 tokenId = _stakeNew(alice, 100_000e6, 100_000e18);
        uint128 liquidityBefore = posm.getPositionLiquidity(tokenId);
        uint256 stakedBefore = dist.totalStaked();

        _swap(20_000e6, true);
        _swap(20_000e18, false);

        uint256 unitBefore = IERC20(unit).balanceOf(alice);
        uint256 assetBefore = asset.balanceOf(alice);

        vm.prank(alice);
        dist.collectFees(tokenId);

        assertGt(IERC20(unit).balanceOf(alice), unitBefore, "unit-side fees");
        assertGt(asset.balanceOf(alice), assetBefore, "asset-side fees");
        assertEq(posm.getPositionLiquidity(tokenId), liquidityBefore, "liquidity untouched");
        assertEq(dist.totalStaked(), stakedBefore, "stake weight untouched");
        assertEq(posm.ownerOf(tokenId), address(dist), "still custodied");
    }

    function test_onlyTheStakerMayCollectFees() public {
        uint256 tokenId = _stakeNew(alice, 100_000e6, 100_000e18);
        _swap(20_000e6, true);

        vm.prank(bob);
        vm.expectRevert(LpRewardDistributor.OnlyStaker.selector);
        dist.collectFees(tokenId);
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

    // ─── Pausing ─────────────────────────────────────────────────────────

    /// @dev The exit is the one thing a halted protocol must never hold, so it is the one
    ///      entry point that ignores the guard.
    function test_pauseStopsStakeClaimAndFeesButNeverUnstake() public {
        uint256 tokenId = _stakeNew(alice, 10_000e6, 10_000e18);
        uint256 spare = _mintPosition(alice, 10_000e6, 10_000e18, true);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        _pauseProtocol();

        vm.startPrank(alice);
        posm.approve(address(dist), spare);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        dist.stake(spare, alice);

        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        dist.claim(unit);

        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        dist.collectFees(tokenId);

        dist.unstake(tokenId);
        vm.stopPrank();

        assertEq(posm.ownerOf(tokenId), alice, "the position came home while halted");
    }

    /// @dev A paused reserve blocks the 1:1 conversion, so the unit path is the fallback the
    ///      application has to offer.
    function test_aPausedReserveLeavesTheUnitClaimWorking() public {
        _stakeNew(alice, 10_000e6, 10_000e18);
        _notify(REWARD);
        vm.warp(dist.periodFinish());

        vm.prank(stackGuardian);
        protocolGuard.pauseTarget(address(reserve));

        vm.prank(alice);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        dist.claim(otherBrand);

        vm.prank(alice);
        assertGt(dist.claim(unit), 0, "the unit still pays");
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_initializeRejectsARewardTokenThatIsNotABrandOfTheReserve() public {
        // The beacon is deployed first and separately: `expectRevert` binds to the very next
        // creation, and the helper's own `new LpRewardDistributor()` would take that slot.
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(address(new LpRewardDistributor()), stackOwner);

        vm.expectRevert(
            abi.encodeWithSelector(LpRewardDistributor.RewardTokenNotBrand.selector, address(asset))
        );
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                LpRewardDistributor.initialize,
                (
                    IPositionManagerV4(address(posm)),
                    reserve,
                    key,
                    address(asset),
                    address(this),
                    DURATION,
                    address(protocolGuard)
                )
            )
        );
    }

    function test_initializeRejectsZeroWiringAndZeroDuration() public {
        UpgradeableBeacon beacon =
            new UpgradeableBeacon(address(new LpRewardDistributor()), stackOwner);

        vm.expectRevert(LpRewardDistributor.ZeroAddress.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                LpRewardDistributor.initialize,
                (
                    IPositionManagerV4(address(posm)),
                    reserve,
                    key,
                    unit,
                    address(0),
                    DURATION,
                    address(protocolGuard)
                )
            )
        );

        vm.expectRevert(LpRewardDistributor.ZeroDuration.selector);
        new BeaconProxy(
            address(beacon),
            abi.encodeCall(
                LpRewardDistributor.initialize,
                (
                    IPositionManagerV4(address(posm)),
                    reserve,
                    key,
                    unit,
                    address(this),
                    0,
                    address(protocolGuard)
                )
            )
        );
    }

    function test_fullRangeIsThePoolSpacingsWidest() public view {
        (int24 lower, int24 upper) = dist.fullRange();
        assertEq(lower, TickMath.minUsableTick(TICK_SPACING), "lower");
        assertEq(upper, TickMath.maxUsableTick(TICK_SPACING), "upper");
    }

    function test_positionListStaysConsistentAcrossManyStakes() public {
        uint256 a = _stakeNew(alice, 10_000e6, 10_000e18);
        uint256 b = _stakeNew(alice, 10_000e6, 10_000e18);
        uint256 c = _stakeNew(alice, 10_000e6, 10_000e18);
        assertEq(dist.positionCountOf(alice), 3, "three staked");

        // Remove the middle one: the swap-and-pop must keep the other two addressable.
        vm.prank(alice);
        dist.unstake(b);

        uint256[] memory left = dist.positionsOf(alice);
        assertEq(left.length, 2, "two left");
        assertTrue((left[0] == a && left[1] == c) || (left[0] == c && left[1] == a), "both survive");

        vm.startPrank(alice);
        dist.unstake(a);
        dist.unstake(c);
        vm.stopPrank();

        assertEq(dist.positionCountOf(alice), 0, "empty");
        assertEq(dist.totalStaked(), 0, "and no weight left");
    }
}
