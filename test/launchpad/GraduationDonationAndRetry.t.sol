// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";

import {MockAsset} from "../markets/AssetMarketFactory.t.sol";
import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title GraduationDonationAndRetryTest
/// @notice The two things that stop being true once a graduated market is quoted in a dollar
///         somebody else already holds.
///
///         **A balance is not a measurement.** The quote leg used to be a `<SYM>.d` minted
///         inside the graduation transaction, so this module's balance of it could only be
///         what the mint left behind. It is now a live AIUSD/FASTUSD anyone can transfer to a
///         fixed, public address, and the dust ceiling — 10 bps, and a revert above it — turned
///         that into a permanent denial of service on every graduation in the brand for the
///         price of one transfer. So the residue is computed (`quoteAmount - unitSeeded`)
///         instead of read, a donation is inert, and `sweepStray` is what reaches it.
///
///         **Bookkeeping must not veto a market.** The float leg ends in a third-party
///         issuer's treasury, behind its revocable opt-in and a reserve that can be paused.
///         Graduation now defers it instead of reverting, records the measured figure, and
///         anyone can land it afterwards with exactly that figure and no other.
contract GraduationDonationAndRetryTest is LaunchpadFixture {
    /// @dev Comfortably above `MAX_DUST_BPS` of the ~8,090-unit raise this fixture graduates:
    ///      10 bps of it is ~8.09, so this is two orders of magnitude past the old ceiling.
    uint256 internal constant DONATION = 1_000e6;

    address internal token;
    address internal curve;

    function setUp() public {
        _deployLaunchpadStack();
        (token, curve) = _launch("Cashcat", "CAT");
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _quoteTreasury() internal view returns (PoolBrandTreasury) {
        return PoolBrandTreasury(marketFactory.treasuryOfBrand(quoteBrand));
    }

    /// @dev Transfer quote brand to the graduation module, the way an attacker would: the
    ///      module's address is public and holds nothing between transactions.
    function _donateToGraduationModule(uint256 amount) internal {
        _fundQuote(stranger, amount);
        vm.prank(stranger);
        IERC20(quoteBrand).transfer(address(graduation), amount);
    }

    function _runToMarket(address t, address c) internal returns (uint256 marketId) {
        _buyToThreshold(c, trader);
        launchFactory.graduateToMarket(t);
        marketId = launchFactory.getLaunchedToken(t).marketId;
    }

    function _vaultOf(uint256 marketId) internal view returns (address) {
        return marketFactory.market(marketId).feeVault;
    }

    /// @dev True when `LaunchFloatDeferred(marketId, amount)` was emitted by the module.
    function _sawDeferral(Vm.Log[] memory logs, uint256 marketId, uint256 amount)
        internal
        view
        returns (bool)
    {
        bytes32 sig = keccak256("LaunchFloatDeferred(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(graduation) || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != marketId) continue;
            if (abi.decode(logs[i].data, (uint256)) == amount) return true;
        }
        return false;
    }

    /// @dev A market that owns its unit: the shape `recordLaunchFloat` must refuse, because it
    ///      is already that brand's treasury admin and draws the whole of its yield.
    function _openMarketThatOwnsItsBrand() internal returns (uint256 marketId) {
        MockAsset listed = new MockAsset();
        _approveAsset(
            marketFactory,
            address(listed),
            POOL_FEE,
            1e18,
            FIXTURE_MIN_OBSERVATION_CARDINALITY,
            "Mock Market Dollar",
            "MOCK.d"
        );
        (marketId,,,,) = marketFactory.createMarket(address(listed), address(0));
    }

    // ─── A donation is not dust ──────────────────────────────────────────

    /// @notice The attack the dust ceiling used to enable: transfer more than 10 bps of a
    ///         raise to the module, and every graduation quoted in that brand reverts forever
    ///         because the revert undoes the credit that would have consumed it.
    ///
    ///         Two launches graduate here with the donation sitting there the whole time, so
    ///         the "permanent, and self-reinforcing" half of the finding is what fails if this
    ///         regresses — not just the first graduation.
    function test_donationAboveTheDustCeilingDoesNotBlockGraduation() public {
        _donateToGraduationModule(DONATION);

        uint256 firstMarket = _runToMarket(token, curve);
        assertGt(firstMarket, 0, "the first launch graduated with a donation sitting here");

        assertEq(
            IERC20(quoteBrand).balanceOf(address(graduation)),
            DONATION,
            "the donation was neither consumed nor credited: it is simply ignored"
        );

        (address second, address secondCurve) = _launch("Riverdog", "DOG");
        uint256 secondMarket = _runToMarket(second, secondCurve);
        assertGt(secondMarket, 0, "and so did the next one, in the same brand");
        assertTrue(firstMarket != secondMarket, "two markets");
        assertEq(
            IERC20(quoteBrand).balanceOf(address(graduation)),
            DONATION,
            "still exactly the donation after a second graduation"
        );
    }

    /// @notice The donation is not folded into what the protocol keeps, which is exactly what
    ///         reading a balance did. Proved by difference: two identically sized launches in
    ///         the same brand, one graduating with a donation parked in the module and one
    ///         without, credit the escrow the same amount. Anything the module reads off its
    ///         own balance would show up as a gap here.
    function test_onlyTheMintsResidueIsCreditedToTheProtocol() public {
        // A clean graduation first: what a launch of this size legitimately credits.
        _buyToThreshold(curve, trader);
        uint256 beforeClean = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand);
        launchFactory.graduateToMarket(token);
        uint256 clean = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand) - beforeClean;

        // The same launch again, with the module holding a donation two orders of magnitude
        // past the old ceiling throughout.
        (address second, address secondCurve) = _launch("Riverdog", "DOG");
        _donateToGraduationModule(DONATION);
        _buyToThreshold(secondCurve, trader);
        uint256 beforeDonated = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand);
        launchFactory.graduateToMarket(second);
        uint256 donated = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand) - beforeDonated;

        assertEq(donated, clean, "the donation changed nothing about what the protocol keeps");
        assertLt(clean, DONATION, "and what it keeps is a rounding remainder, not a donation");
        assertEq(
            IERC20(quoteBrand).balanceOf(address(graduation)),
            DONATION,
            "the donation is still sitting there, untouched, waiting for the sweep"
        );
    }

    /// @notice A donated token is inert but not unreachable: the sweep is permissionless,
    ///         credits the protocol's fee recipient through the escrow, and has nothing to do
    ///         a second time. The module has no owner and no upgrade path, so this is the only
    ///         way anything that lands here ever moves again.
    function test_sweepStray_isPermissionlessAndCreditsTheProtocol() public {
        _donateToGraduationModule(DONATION);
        _runToMarket(token, curve);

        uint256 before = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand);

        vm.prank(stranger);
        vm.expectEmit(true, false, false, true, address(graduation));
        emit LaunchGraduation.StraySwept(quoteBrand, DONATION);
        uint256 swept = graduation.sweepStray(quoteBrand);

        assertEq(swept, DONATION, "the whole stray balance");
        assertEq(IERC20(quoteBrand).balanceOf(address(graduation)), 0, "the module holds nothing");
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand) - before,
            DONATION,
            "credited to the protocol's recipient through the escrow"
        );

        vm.prank(stranger);
        vm.expectRevert(LaunchGraduation.NothingToSweep.selector);
        graduation.sweepStray(quoteBrand);
    }

    // ─── What a float figure may assert ──────────────────────────────────

    /// @notice A float larger than the brand's entire outstanding supply is refused. It is not
    ///         merely unfair: once `totalFloat` is large enough that the treasury's index
    ///         credit floors to zero while `marketReserve` still grows, that underlying is
    ///         unreachable by the issuer and by every vault, permanently.
    function test_recordLaunchFloat_refusesMoreThanTheBrandsOutstandingSupply() public {
        uint256 marketId = _runToMarket(token, curve);
        uint256 outstanding = reserve.outstandingOf(quoteBrand);
        uint256 totalBefore = _quoteTreasury().totalFloat();

        vm.prank(address(graduation));
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.FloatExceedsSupply.selector, outstanding + 1, outstanding
            )
        );
        marketFactory.recordLaunchFloat(marketId, outstanding + 1);

        assertEq(_quoteTreasury().totalFloat(), totalBefore, "nothing was registered");
    }

    /// @notice A market that owns its unit already takes the whole of that brand's yield
    ///         through its treasury, so float on top would be double-counting.
    function test_recordLaunchFloat_refusesAMarketThatOwnsItsBrand() public {
        uint256 ownedMarket = _openMarketThatOwnsItsBrand();
        AssetMarketFactory.Market memory m = marketFactory.market(ownedMarket);
        assertEq(marketFactory.marketOfBrand(m.brandToken), ownedMarket, "it owns its unit");

        vm.prank(address(graduation));
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.NotSharedQuote.selector, ownedMarket)
        );
        marketFactory.recordLaunchFloat(ownedMarket, 1);

        assertEq(marketFactory.launchFloatOf(ownedMarket), 0, "and nothing was recorded");
    }

    /// @notice A market's seed is measured once, by its graduation. Re-recording is what a
    ///         replaced launchpad would need to move a market's share of a brand's yield.
    function test_recordLaunchFloat_refusesASecondRegistration() public {
        uint256 marketId = _runToMarket(token, curve);
        uint256 recorded = marketFactory.launchFloatOf(marketId);
        assertGt(recorded, 0, "the graduation recorded its seed");

        vm.prank(address(graduation));
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.FloatAlreadyRecorded.selector, marketId)
        );
        marketFactory.recordLaunchFloat(marketId, 1);

        assertEq(marketFactory.launchFloatOf(marketId), recorded, "the figure is unchanged");
        assertEq(
            _quoteTreasury().floatOf(_vaultOf(marketId)), recorded, "and so is the registration"
        );
    }

    // ─── The issuer cannot veto the market ───────────────────────────────

    /// @notice The freeze this removes: a brand's issuer revoking its opt-in used to turn
    ///         every in-flight graduation in that brand into a total revert, leaving whole
    ///         raises in `Swept` behind a 7-day owner-only rescue.
    ///
    ///         Now the market opens, the module says so, the measured figure is kept, and the
    ///         float lands — from anyone's transaction — the moment the brand is reachable
    ///         again. The retry is pinned to what the graduation measured, so being
    ///         permissionless gives its caller nothing to choose.
    function test_aRevokedIssuerDefersTheFloatInsteadOfVetoingTheMarket() public {
        PoolBrandTreasury treasury = _quoteTreasury();
        assertEq(treasury.admin(), address(this), "this test contract is the brand's issuer");

        // The issuer withdraws consent while a launch is on its way to graduating.
        treasury.setFactory(address(0));

        _buyToThreshold(curve, trader);
        vm.recordLogs();
        launchFactory.graduateToMarket(token);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        assertGt(marketId, 0, "the market opened anyway");
        assertEq(
            marketFactory.marketOfPool(marketFactory.market(marketId).poolId),
            marketId,
            "with a live pool registered to it"
        );

        address vault = _vaultOf(marketId);
        uint256 measured = marketFactory.launchFloatOf(marketId);
        assertGt(measured, 0, "the seed was measured and recorded");
        assertEq(treasury.floatOf(vault), 0, "but it did not reach the treasury");
        assertTrue(_sawDeferral(logs, marketId, measured), "and the module said so");

        // While the opt-in is still revoked the retry surfaces the treasury's own reason
        // rather than pretending to have worked.
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        marketFactory.retryLaunchFloat(marketId);

        // The issuer re-opts in; anybody may finish the bookkeeping.
        treasury.setFactory(address(marketFactory));
        vm.prank(stranger);
        marketFactory.retryLaunchFloat(marketId);

        assertEq(treasury.floatOf(vault), measured, "the float landed, at the measured figure");
        assertEq(marketFactory.launchFloatOf(marketId), measured, "the record is unchanged");

        // And it is not a second bite: the figure is already registered.
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.LaunchFloatAlreadyRegistered.selector, marketId
            )
        );
        marketFactory.retryLaunchFloat(marketId);
    }

    /// @notice The non-malicious half of the same finding: the brand's treasury pulls yield
    ///         through a reserve that `ProtocolGuard` can halt, and a reserve may be paused
    ///         for reasons that have nothing to do with a launch. It used to be the one thing
    ///         in phase two that touched the reserve at all, so pausing it turned every
    ///         graduation in the brand into a revert. Now the market opens, the pool trades,
    ///         and the float waits for the pause to lift.
    function test_aPausedReserveDefersTheFloatInsteadOfVetoingTheMarket() public {
        // After the curve has filled: minting the brand a buyer trades with goes through the
        // reserve too, and what is under test is phase two, not the raise.
        _buyToThreshold(curve, trader);

        vm.prank(stackGuardian);
        protocolGuard.pauseTarget(address(reserve));

        launchFactory.graduateToMarket(token);
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        assertGt(marketId, 0, "the market opened with the reserve halted");

        address vault = _vaultOf(marketId);
        uint256 measured = marketFactory.launchFloatOf(marketId);
        assertGt(measured, 0, "the seed was measured");
        assertEq(_quoteTreasury().floatOf(vault), 0, "the treasury could not be pulled");

        vm.prank(stackOwner);
        protocolGuard.unpauseTarget(address(reserve));

        vm.prank(stranger);
        marketFactory.retryLaunchFloat(marketId);
        assertEq(_quoteTreasury().floatOf(vault), measured, "and lands once the pause lifts");
    }

    /// @notice A market that never deferred anything has nothing to retry, and a retired
    ///         market has been dropped from the brand's float on purpose — the retry must not
    ///         undo an owner action.
    function test_retryLaunchFloat_refusesNothingToDoAndRetiredMarkets() public {
        uint256 marketId = _runToMarket(token, curve);

        uint256 unseeded = _openMarketThatOwnsItsBrand();
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.NoLaunchFloatRecorded.selector, unseeded)
        );
        marketFactory.retryLaunchFloat(unseeded);

        vm.prank(owner);
        marketFactory.retireMarket(marketId);
        assertEq(_quoteTreasury().floatOf(_vaultOf(marketId)), 0, "retirement dropped the float");

        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.MarketIsRetired.selector, marketId)
        );
        marketFactory.retryLaunchFloat(marketId);
    }
}
