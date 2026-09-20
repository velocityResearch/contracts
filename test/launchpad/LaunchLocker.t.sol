// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {ILaunchFactory, ILaunchLocker} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchLockerTest
/// @notice What the locked position earns and where it goes, and what the locker can never
///         do. A launch is taken all the way to a market in `setUp`, so the position under
///         test is the real graduation seed staked in a real distributor: the swap fees are
///         the pool's own arithmetic and the reward is a real `BrandFeeVault.sweep`.
contract LaunchLockerTest is LaunchpadFixture {
    address token;
    address unit;
    uint256 marketId;
    uint256 positionId;
    LpRewardDistributor dist;
    BrandFeeVault vault;
    uint256 creatorShareBps;

    function setUp() public {
        _deployLaunchpadStack();
        (token,) = _launch("Cashcat", "CAT");
        _buyToThreshold(_launchedCurve(), trader);
        launchFactory.graduateToMarket(token);

        marketId = launchFactory.getLaunchedToken(token).marketId;
        AssetMarketFactory.Market memory m = marketFactory.market(marketId);
        unit = m.brandToken;
        dist = LpRewardDistributor(m.lpDistributor);
        vault = BrandFeeVault(m.feeVault);

        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        positionId = p.tokenId;
        creatorShareBps = p.creatorShareBps;
        assertEq(creatorShareBps, 4_000, "the shipped fee split: 40% of the fee leg is theirs");
        assertEq(launchFactory.graduatedCreatorYieldShareBps(), 4_000, "and 40% of the yield");
        assertEq(launchFactory.graduatedLpFundShareBps(), 0, "the LP fund leg ships off");
    }

    function _launchedCurve() internal view returns (address) {
        return launchFactory.getLaunchedToken(token).curve;
    }

    /// @dev A round trip through the pool so the position earns fees on both sides: the
    ///      trader buys with the unit, then sells what they got back.
    function _tradeBothWays(uint256 unitIn) internal {
        usdg.mint(trader, unitIn);
        vm.startPrank(trader);
        usdg.approve(address(reserve), unitIn);
        reserve.mint(unit, unitIn, trader);
        vm.stopPrank();

        uint256 tokenBefore = IERC20(token).balanceOf(trader);
        _swapInMarket(marketId, trader, unit, unitIn);
        uint256 bought = IERC20(token).balanceOf(trader) - tokenBefore;
        _swapInMarket(marketId, trader, token, bought);
    }

    /// @dev Stream a reward to the position: fund the market's vault as harvested float
    ///      would, sweep it into the distributor, and let the whole period elapse.
    function _streamReward(uint256 amount) internal {
        usdg.mint(address(vault), amount);
        vault.sweep();
        vm.warp(dist.periodFinish());
    }

    // ─── Collecting ──────────────────────────────────────────────────────

    function test_collect_splitsTheFeeLegOnTheSnapshottedRate() public {
        _tradeBothWays(1_000e6);

        // No reward has been streamed, so the reward leg has nothing and must not get in
        // the way of the fee leg.
        assertEq(dist.earned(address(locker)), 0, "no float yet");

        (uint256 unitOut, uint256 tokenOut, uint256 yieldOut) = locker.collect(token);
        assertGt(unitOut, 0, "fees on the unit side");
        assertGt(tokenOut, 0, "fees on the token side");
        assertEq(yieldOut, 0, "and nothing from the float stream");

        // Both currencies split on the rate the launch was sold, with the protocol taking
        // the remainder because the LP fund leg is off.
        uint256 unitToCreator = unitOut * 4_000 / 10_000;
        uint256 tokenToCreator = tokenOut * 4_000 / 10_000;
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, unit), unitToCreator);
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenToCreator);
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, unit), unitOut - unitToCreator);
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, token), tokenOut - tokenToCreator);

        // The escrow is a pull ledger: the creator can take it from there.
        vm.prank(creatorFeeRecipient);
        assertEq(feeEscrow.claimToken(unit), unitToCreator);
        assertEq(IERC20(unit).balanceOf(creatorFeeRecipient), unitToCreator);
    }

    /// @notice The float yield is the reserve's earning rather than the launch's, so it is
    ///         split on its own rate rather than on the position's snapshotted one.
    function test_collect_splitsTheFloatYieldOnItsOwnRate() public {
        uint256 reward = 10_000e6;
        _streamReward(reward);

        (uint256 unitOut, uint256 tokenOut, uint256 yieldOut) = locker.collect(token);
        assertEq(tokenOut, 0, "no trades, no token-side fees");
        // The locked position is the pool's only stake, so the whole stream is its, less
        // the accumulator's rounding.
        assertApproxEqAbs(unitOut, reward, 1e3, "the whole reward");
        assertEq(yieldOut, unitOut, "all of which came from the stream, not from fees");

        uint256 toCreator = yieldOut * 4_000 / 10_000;
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, unit), toCreator);
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, unit), yieldOut - toCreator);
    }

    /// @notice The yield rate is read live at every collect, so a change reaches a position
    ///         that graduated before it — the property the snapshotted fee share
    ///         deliberately does not have.
    function test_collect_paysTheFloatYieldByTheRateSetAfterGraduation() public {
        vm.prank(owner);
        launchFactory.setGraduatedCreatorYieldShareBps(6_000);

        _streamReward(10_000e6);
        (,, uint256 yieldOut) = locker.collect(token);
        assertGt(yieldOut, 0, "the stream paid");

        uint256 toCreator = yieldOut * 6_000 / 10_000;
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, unit), toCreator);
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, unit), yieldOut - toCreator);
    }

    /// @notice The LP fund's cut comes out of the PROTOCOL's remainder, never the creator's.
    ///         That is the property that makes the rate safe to read live and to apply to a
    ///         position that graduated before the fund existed: turning it on cannot reprice
    ///         a term the creator was sold. Asserted by comparing the creator's take against
    ///         the same trade with the leg off, which the two tests above pin.
    function test_collect_paysTheLpFundOutOfTheProtocolsShare() public {
        address lpFund = address(0x11FD);
        vm.startPrank(owner);
        launchFactory.setLpFundRecipient(lpFund);
        launchFactory.setGraduatedLpFundShareBps(3_000);
        vm.stopPrank();

        _tradeBothWays(2_000e6);
        _streamReward(5_000e6);
        (uint256 unitOut, uint256 tokenOut, uint256 yieldOut) = locker.collect(token);
        uint256 feeUnit = unitOut - yieldOut;
        assertGt(feeUnit, 0, "unit-side swap fees");
        assertGt(tokenOut, 0, "token-side swap fees");
        assertGt(yieldOut, 0, "and a streamed reward");

        // 40% of each leg, exactly what the leg-off tests pay.
        uint256 unitFeesToCreator = feeUnit * 4_000 / 10_000;
        uint256 yieldToCreator = yieldOut * 4_000 / 10_000;
        uint256 tokenToCreator = tokenOut * 4_000 / 10_000;
        // 30% of each leg.
        uint256 unitFeesToLpFund = feeUnit * 3_000 / 10_000;
        uint256 yieldToLpFund = yieldOut * 3_000 / 10_000;
        uint256 tokenToLpFund = tokenOut * 3_000 / 10_000;

        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit),
            unitFeesToCreator + yieldToCreator,
            "the creator is untouched by the fund"
        );
        assertEq(
            feeEscrow.balanceOfToken(lpFund, unit),
            unitFeesToLpFund + yieldToLpFund,
            "the fund takes 30% of both unit legs"
        );
        assertEq(feeEscrow.balanceOfToken(lpFund, token), tokenToLpFund, "and of the token leg");
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenToCreator);

        // The protocol is diluted by exactly the fund's take, and every asset still adds up.
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit)
                + feeEscrow.balanceOfToken(lpFund, unit)
                + feeEscrow.balanceOfToken(protocolFeeRecipient, unit),
            unitOut,
            "the unit legs sum to what arrived"
        );
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, token)
                + feeEscrow.balanceOfToken(lpFund, token)
                + feeEscrow.balanceOfToken(protocolFeeRecipient, token),
            tokenOut,
            "and so do the token legs"
        );
    }

    function test_collect_splitsFeesAndYieldOnTheirOwnRatesAndKeepsNothing() public {
        vm.prank(owner);
        launchFactory.setGraduatedCreatorYieldShareBps(2_500);

        _tradeBothWays(2_000e6);
        _streamReward(5_000e6);

        uint256 unitBefore = IERC20(unit).balanceOf(address(locker));
        uint256 tokenBefore = IERC20(token).balanceOf(address(locker));
        (uint256 unitOut, uint256 tokenOut, uint256 yieldOut) = locker.collect(token);

        // Both legs arrive in the unit in the same call; what makes them two is that they
        // are paid on two rates.
        uint256 feeUnit = unitOut - yieldOut;
        assertGt(feeUnit, 0, "unit-side swap fees");
        assertGt(yieldOut, 5_000e6 - 1e3, "and the whole streamed reward");
        assertGt(tokenOut, 0);

        uint256 unitFeesToCreator = feeUnit * 4_000 / 10_000;
        uint256 yieldToCreator = yieldOut * 2_500 / 10_000;
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit),
            unitFeesToCreator + yieldToCreator,
            "40% of the fee leg plus a quarter of the yield"
        );
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, unit),
            unitOut - unitFeesToCreator - yieldToCreator,
            "and the protocol takes the remainder of both"
        );
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenOut * 4_000 / 10_000);

        assertEq(IERC20(unit).balanceOf(address(locker)), unitBefore, "holds no unit");
        assertEq(IERC20(token).balanceOf(address(locker)), tokenBefore, "holds the lock only");
        assertEq(IERC20(unit).allowance(address(locker), address(feeEscrow)), 0);
        assertEq(IERC20(token).allowance(address(locker), address(feeEscrow)), 0);

        // A second collect finds nothing new and credits nothing.
        (unitOut, tokenOut, yieldOut) = locker.collect(token);
        assertEq(unitOut, 0);
        assertEq(tokenOut, 0);
        assertEq(yieldOut, 0);
    }

    /// @notice The creator recipient is whatever the factory says at collect time. A
    ///         handover after graduation redirects the very next collection, with nothing
    ///         written to the locker.
    function test_collect_paysTheCreatorRecipientTheFactoryNamesNow() public {
        address heir = address(0x4E1A);
        vm.prank(creatorFeeRecipient);
        launchFactory.proposeCreatorFeeRecipient(token, heir);
        vm.prank(heir);
        launchFactory.acceptCreatorFeeRecipient(token);
        assertEq(launchFactory.creatorFeeRecipientOf(token), heir);

        _tradeBothWays(1_000e6);
        (uint256 unitOut,,) = locker.collect(token);

        assertEq(
            feeEscrow.balanceOfToken(heir, unit),
            unitOut * 4_000 / 10_000,
            "the creator's 40% of the fee leg"
        );
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, unit), 0, "the old one got nothing");
        assertEq(
            locker.lockedPosition(token).creatorFeeRecipient,
            creatorFeeRecipient,
            "the record is the recipient at graduation"
        );
    }

    function test_collect_paysTheProtocolRecipientTheFactoryNamesNow() public {
        address treasury2 = address(0x7EA5);
        vm.prank(owner);
        launchFactory.setProtocolFeeRecipient(treasury2);

        // The protocol's leg of a default market is the yield, so stream one.
        _streamReward(1_000e6);
        (,, uint256 yieldOut) = locker.collect(token);
        assertGt(yieldOut, 0, "the stream paid");

        assertEq(feeEscrow.balanceOfToken(treasury2, unit), yieldOut - yieldOut * 4_000 / 10_000);
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, unit), 0);
    }

    function test_collect_onATokenThatNeverGraduatedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchLocker.NotLocked.selector, stranger));
        locker.collect(stranger);
    }

    // ─── Nothing leaves ──────────────────────────────────────────────────

    /// @notice The two things the locker exists to hold stay held through everything the
    ///         locker can be asked to do.
    function test_collectMovesNeitherThePositionNorTheLockedSupply() public {
        uint256 locked = locker.lockedSupply(token);
        assertGt(locked, 0, "supply was locked at graduation");
        uint128 liquidity = posm.getPositionLiquidity(positionId);

        _tradeBothWays(3_000e6);
        _streamReward(1_000e6);
        locker.collect(token);
        _tradeBothWays(500e6);
        locker.collect(token);

        assertEq(dist.stakerOf(positionId), address(locker), "still staked under the locker");
        assertEq(posm.ownerOf(positionId), address(dist), "still custodied by the distributor");
        assertEq(posm.getPositionLiquidity(positionId), liquidity, "liquidity untouched");
        assertEq(locker.lockedSupply(token), locked, "ledger untouched");
        assertEq(IERC20(token).balanceOf(address(locker)), locked, "balance backs the ledger");
    }

    /// @notice There is no function that would move them: the locker exposes nothing that
    ///         unstakes, transfers a position, or sends a token to a chosen address, and it
    ///         accepts no unknown calls to be found later.
    function test_lockerHasNoExitForTheOwner() public {
        vm.startPrank(owner);
        (bool ok,) = address(locker).call(abi.encodeWithSignature("unstake(uint256)", positionId));
        assertFalse(ok, "no unstake");
        (ok,) = address(locker)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", token, owner, 1));
        assertFalse(ok, "no withdraw");
        (ok,) = address(locker).call("");
        assertFalse(ok, "no fallback");
        vm.stopPrank();

        assertEq(dist.stakerOf(positionId), address(locker));
        assertEq(IERC20(token).balanceOf(address(locker)), locker.lockedSupply(token));
    }

    // ─── Gates ───────────────────────────────────────────────────────────

    function test_onlyTheGraduationModuleMayRecordOrLock() public {
        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);

        vm.startPrank(stranger);
        vm.expectRevert(LaunchLocker.OnlyGraduation.selector);
        locker.recordPosition(stranger, p);
        vm.expectRevert(LaunchLocker.OnlyGraduation.selector);
        locker.lockTokenSupply(token, 1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(LaunchLocker.OnlyGraduation.selector);
        locker.recordPosition(stranger, p);
        vm.expectRevert(LaunchLocker.OnlyGraduation.selector);
        locker.lockTokenSupply(token, 1);
        vm.stopPrank();
    }

    function test_recordPosition_refusesAPositionTheLockerIsNotTheStakerOf() public {
        // A second full-range position in the same pool, staked by someone else.
        uint256 other = _mintFullRangeAs(stranger, 100e6, 100e18);
        vm.startPrank(stranger);
        posm.approve(address(dist), other);
        dist.stake(other, stranger);
        vm.stopPrank();

        ILaunchLocker.LockedPosition memory p = ILaunchLocker.LockedPosition({
            tokenId: other,
            distributor: address(dist),
            unit: unit,
            creatorFeeRecipient: creatorFeeRecipient,
            creatorShareBps: 7_000,
            exists: true
        });
        vm.prank(address(graduation));
        vm.expectRevert(abi.encodeWithSelector(LaunchLocker.PositionNotStaked.selector, other));
        locker.recordPosition(address(0xBEEF), p);

        // And one that is not staked anywhere.
        uint256 loose = _mintFullRangeAs(stranger, 100e6, 100e18);
        p.tokenId = loose;
        vm.prank(address(graduation));
        vm.expectRevert(abi.encodeWithSelector(LaunchLocker.PositionNotStaked.selector, loose));
        locker.recordPosition(address(0xBEEF), p);
    }

    function test_recordPosition_isOncePerToken() public {
        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        vm.prank(address(graduation));
        vm.expectRevert(abi.encodeWithSelector(LaunchLocker.PositionAlreadyLocked.selector, token));
        locker.recordPosition(token, p);
    }

    function test_recordPosition_rejectsAShareAboveOneHundredPercent() public {
        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        p.creatorShareBps = 10_001;
        vm.prank(address(graduation));
        vm.expectRevert(abi.encodeWithSelector(LaunchLocker.ShareTooHigh.selector, 10_001));
        locker.recordPosition(address(0xBEEF), p);
    }

    function test_lockTokenSupply_ledgersWhatArrives() public {
        uint256 before = locker.lockedSupply(token);
        uint256 held = IERC20(token).balanceOf(address(locker));

        // The trader, who bought the curve out, lends the module some supply to lock; the
        // locker pulls it.
        uint256 amount = 1_000e18;
        vm.prank(trader);
        IERC20(token).transfer(address(graduation), amount);

        vm.startPrank(address(graduation));
        IERC20(token).approve(address(locker), amount);
        locker.lockTokenSupply(token, amount);
        vm.stopPrank();

        assertEq(locker.lockedSupply(token), before + amount);
        assertEq(IERC20(token).balanceOf(address(locker)), held + amount);
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_setGraduation_isOneShotAndOwnershipCannotBeRenounced() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchLocker.AlreadyInitialized.selector);
        locker.setGraduation(stranger);
        vm.expectRevert(LaunchLocker.OwnershipCannotBeRenounced.selector);
        locker.renounceOwnership();
        vm.stopPrank();

        LaunchLocker fresh = new LaunchLocker(owner, address(launchFactory));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        fresh.setGraduation(stranger);
        vm.prank(owner);
        vm.expectRevert(LaunchLocker.ZeroAddress.selector);
        fresh.setGraduation(address(0));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev Mint a full-range position in the market's pool through the stand-in, owned by
    ///      `who`, paid for out of the trader's curve tokens and fresh unit.
    function _mintFullRangeAs(address who, uint256 unitAmount, uint256 tokenAmount)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(trader);
        IERC20(token).transfer(who, tokenAmount);

        usdg.mint(who, unitAmount);
        vm.startPrank(who);
        usdg.approve(address(reserve), unitAmount);
        reserve.mint(unit, unitAmount, who);

        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        (int24 tickLower, int24 tickUpper) = dist.fullRange();
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
        // A liquidity figure small enough that both sides fit in what `who` holds at any
        // price the pool can be at after a few trades.
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(1e9), type(uint128).max, type(uint128).max, who, ""
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp());
        vm.stopPrank();
    }
}
