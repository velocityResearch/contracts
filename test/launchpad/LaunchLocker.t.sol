// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {ILaunchFactory, ILaunchLocker} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchLockerTest
/// @notice What the locked position earns and where it goes, and what the locker can never
///         do. A launch is taken all the way to a market in `setUp`, so the position under
///         test is the real graduation seed staked in a real distributor and every figure
///         here is the pool's own fee arithmetic. There is no reward leg: recording the
///         position renounces the stream that rides alongside it.
contract LaunchLockerTest is LaunchpadFixture {
    address token;
    address unit;
    uint256 marketId;
    uint256 positionId;
    LpRewardDistributor dist;
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

        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        positionId = p.tokenId;
        creatorShareBps = p.creatorShareBps;
        assertEq(creatorShareBps, 4_000, "the shipped fee split: 40% of the fee leg is theirs");
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

    // ─── Collecting ──────────────────────────────────────────────────────
    //
    // The unit IS the launch's own quote brand, so the escrow already holds the curve's fees
    // in it before the market has traded once. Every unit-side figure below is therefore a
    // delta across the collect rather than a total.

    function test_collect_splitsTheFeeLegOnTheSnapshottedRate() public {
        _tradeBothWays(1_000e6);

        uint256 creatorUnitBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, unit);
        uint256 protocolUnitBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, unit);
        (uint256 unitOut, uint256 tokenOut) = locker.collect(token);
        assertGt(unitOut, 0, "fees on the unit side");
        assertGt(tokenOut, 0, "fees on the token side");

        // Both currencies split on the rate the launch was sold, with the protocol taking
        // the remainder because the LP fund leg is off.
        uint256 unitToCreator = unitOut * 4_000 / 10_000;
        uint256 tokenToCreator = tokenOut * 4_000 / 10_000;
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit) - creatorUnitBefore, unitToCreator
        );
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenToCreator);
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, unit) - protocolUnitBefore,
            unitOut - unitToCreator
        );
        assertEq(feeEscrow.balanceOfToken(protocolFeeRecipient, token), tokenOut - tokenToCreator);

        // The escrow is a pull ledger: the creator can take it from there.
        vm.prank(creatorFeeRecipient);
        assertEq(feeEscrow.claimToken(unit), creatorUnitBefore + unitToCreator);
        assertEq(IERC20(unit).balanceOf(creatorFeeRecipient), creatorUnitBefore + unitToCreator);
    }

    /// @notice The LP fund's cut comes out of the PROTOCOL's remainder, never the creator's.
    ///         That is the property that makes the rate safe to read live and to apply to a
    ///         position that graduated before the fund existed: turning it on cannot reprice
    ///         a term the creator was sold. Asserted by comparing the creator's take against
    ///         the same trade with the leg off, which the test above pins.
    function test_collect_paysTheLpFundOutOfTheProtocolsShare() public {
        address lpFund = address(0x11FD);
        vm.startPrank(owner);
        launchFactory.setLpFundRecipient(lpFund);
        launchFactory.setGraduatedLpFundShareBps(3_000);
        vm.stopPrank();

        _tradeBothWays(2_000e6);
        uint256 creatorUnitBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, unit);
        uint256 protocolUnitBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, unit);
        (uint256 unitOut, uint256 tokenOut) = locker.collect(token);
        assertGt(unitOut, 0, "unit-side swap fees");
        assertGt(tokenOut, 0, "token-side swap fees");

        // 40% of each leg, exactly what the leg-off test pays.
        uint256 unitToCreator = unitOut * 4_000 / 10_000;
        uint256 tokenToCreator = tokenOut * 4_000 / 10_000;
        // 30% of each leg.
        uint256 unitToLpFund = unitOut * 3_000 / 10_000;
        uint256 tokenToLpFund = tokenOut * 3_000 / 10_000;

        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit) - creatorUnitBefore,
            unitToCreator,
            "the creator is untouched by the fund"
        );
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenToCreator);
        assertEq(
            feeEscrow.balanceOfToken(lpFund, unit), unitToLpFund, "the fund takes 30% of the unit"
        );
        assertEq(feeEscrow.balanceOfToken(lpFund, token), tokenToLpFund, "and of the token leg");

        // The protocol is diluted by exactly the fund's take, and every asset still adds up.
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit) - creatorUnitBefore
                + feeEscrow.balanceOfToken(lpFund, unit)
                + feeEscrow.balanceOfToken(protocolFeeRecipient, unit) - protocolUnitBefore,
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

    /// @notice Everything collected is credited out in the same call: the locker ends holding
    ///         nothing but the locked supply, grants no standing allowance over it, and a
    ///         second collect with no trade in between finds nothing.
    function test_collect_keepsNothingAndASecondCollectFindsNothing() public {
        _tradeBothWays(2_000e6);

        uint256 unitBefore = IERC20(unit).balanceOf(address(locker));
        uint256 tokenBefore = IERC20(token).balanceOf(address(locker));
        uint256 creatorUnitBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, unit);
        uint256 protocolUnitBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, unit);
        (uint256 unitOut, uint256 tokenOut) = locker.collect(token);
        assertGt(unitOut, 0, "unit-side swap fees");
        assertGt(tokenOut, 0, "token-side swap fees");

        uint256 unitToCreator = unitOut * 4_000 / 10_000;
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit) - creatorUnitBefore, unitToCreator
        );
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, unit) - protocolUnitBefore,
            unitOut - unitToCreator,
            "the protocol takes the remainder"
        );
        assertEq(feeEscrow.balanceOfToken(creatorFeeRecipient, token), tokenOut * 4_000 / 10_000);

        assertEq(IERC20(unit).balanceOf(address(locker)), unitBefore, "holds no unit");
        assertEq(IERC20(token).balanceOf(address(locker)), tokenBefore, "holds the lock only");
        assertEq(IERC20(unit).allowance(address(locker), address(feeEscrow)), 0);
        assertEq(IERC20(token).allowance(address(locker), address(feeEscrow)), 0);

        // A second collect finds nothing new and credits nothing.
        (unitOut, tokenOut) = locker.collect(token);
        assertEq(unitOut, 0);
        assertEq(tokenOut, 0);
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
        uint256 oldRecipientBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, unit);
        (uint256 unitOut,) = locker.collect(token);

        assertEq(
            feeEscrow.balanceOfToken(heir, unit),
            unitOut * 4_000 / 10_000,
            "the creator's 40% of the fee leg"
        );
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, unit),
            oldRecipientBefore,
            "the old one got nothing new"
        );
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

        _tradeBothWays(1_000e6);
        uint256 oldRecipientBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, unit);
        (uint256 unitOut,) = locker.collect(token);
        assertGt(unitOut, 0, "the position earned");

        assertEq(feeEscrow.balanceOfToken(treasury2, unit), unitOut - unitOut * 4_000 / 10_000);
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, unit),
            oldRecipientBefore,
            "the old one got nothing new"
        );
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

    /// @dev The sizes here are a hundredth of the seed rather than the token-round figures
    ///      this used to mint. Recording the seed renounces its stream, and a renunciation
    ///      sets `LpRewardDistributor.minStakeWeight` to one basis point of the weight it
    ///      gave up — so a stake from anybody else has to be a real position in this market
    ///      before it can reach the locker check this test is actually about. The old figure
    ///      minted a fixed 1e9 of liquidity against a seed of ~1.3e18, which is about a
    ///      billionth of the market and is precisely what that floor exists to refuse.
    function test_recordPosition_refusesAPositionTheLockerIsNotTheStakerOf() public {
        // A second full-range position in the same pool, staked by someone else.
        uint256 other = _mintFullRangeAs(stranger);
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
        uint256 loose = _mintFullRangeAs(stranger);
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
    ///
    ///      Sized off the seed rather than off a literal: a hundredth of the locked
    ///      position's liquidity, which is a hundred times the admission floor the seed's
    ///      renunciation set, so a stake of it is admitted on its merits and the test that
    ///      uses it reaches the locker check it exists for. Funded generously — a full-range
    ///      position carries equal value on both sides, so a hundredth of the seed costs a
    ///      hundredth of the raise, far less than either balance below.
    function _mintFullRangeAs(address who) internal returns (uint256 tokenId) {
        uint256 liquidity = dist.stakedLiquidityOf(address(locker)) / 100;

        // Read before the prank: `balanceOf` is a call and would consume it.
        uint256 share = IERC20(token).balanceOf(trader) / 2;
        vm.prank(trader);
        IERC20(token).transfer(who, share);

        uint256 unitAmount = GRADUATION_THRESHOLD;
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
        params[0] = abi.encode(
            key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, who, ""
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        tokenId = posm.nextTokenId();
        posm.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp());
        vm.stopPrank();
    }
}
