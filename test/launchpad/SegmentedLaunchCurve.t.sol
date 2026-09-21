// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {
    CurveSegment,
    CurveSegmentConfig,
    LaunchCurveSegments
} from "../../src/launchpad/libraries/LaunchCurveSegments.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockLaunchFactory} from "./LaunchCurve.t.sol";

/// @title SegmentedLaunchCurveTest
/// @notice The segmented bonding curve, against the same stand-in factory `LaunchCurveTest`
///         uses. Three things are pinned here: that one segment is the curve this repo has
///         always shipped, that a trade crossing a boundary is priced as one walk, and that
///         the boundary itself is not a place value can be extracted from.
contract SegmentedLaunchCurveTest is Test {
    uint256 constant SUPPLY = 1e27;
    uint256 constant PHANTOM = 3_236e6;
    uint256 constant THRESHOLD = 8_090e6;
    uint256 constant FEE_BPS = 100;
    uint256 constant TAX_BPS = 200;
    uint256 constant PROTOCOL_SHARE_BPS = 3_000;
    uint256 constant BPS = 10_000;

    MockUSDC quote;
    LaunchFeeEscrow escrow;
    MockLaunchFactory factory;

    address creator = address(0xC12EA);
    address protocol = address(0xF33);
    address alice = address(0xA11CE);

    function setUp() public {
        quote = new MockUSDC();
        escrow = new LaunchFeeEscrow();
        factory = new MockLaunchFactory(protocol, PROTOCOL_SHARE_BPS, escrow);
        quote.mint(alice, 100_000_000e6);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev Curve first, then the token that mints to it — the order the deployer uses. Left
    ///      unwired so a test can assert on what `initialize` refuses.
    function _deployPair() internal returns (LaunchCurve c, LaunchToken t) {
        c = new LaunchCurve(
            address(quote), creator, address(factory), PHANTOM, FEE_BPS, TAX_BPS, THRESHOLD
        );
        t = new LaunchToken(
            "Launch",
            "LNCH",
            "",
            "",
            LaunchToken.Socials("", "", "", "", ""),
            creator,
            address(c),
            address(factory),
            SUPPLY
        );
    }

    /// @dev A wired, tradeable launch on `segments`; empty declares the unsegmented curve.
    ///      Warped past the snipe window so every price here is the ordinary one.
    function _launch(CurveSegmentConfig[] memory segments)
        internal
        returns (LaunchCurve c, LaunchToken t)
    {
        (c, t) = _deployPair();
        if (segments.length == 0) {
            factory.initialize(c, address(t));
        } else {
            factory.initializeSegmented(c, address(t), segments);
        }
        vm.warp(block.timestamp + 16);

        vm.startPrank(alice);
        quote.approve(address(c), type(uint256).max);
        t.approve(address(c), type(uint256).max);
        vm.stopPrank();
    }

    function _none() internal pure returns (CurveSegmentConfig[] memory) {
        return new CurveSegmentConfig[](0);
    }

    function _shape(uint16 share0, uint32 k0)
        internal
        pure
        returns (CurveSegmentConfig[] memory s)
    {
        s = new CurveSegmentConfig[](1);
        s[0] = CurveSegmentConfig({supplyShareBps: share0, kMultiplierBps: k0});
    }

    function _shape(uint16 share0, uint32 k0, uint16 share1, uint32 k1)
        internal
        pure
        returns (CurveSegmentConfig[] memory s)
    {
        s = new CurveSegmentConfig[](2);
        s[0] = CurveSegmentConfig({supplyShareBps: share0, kMultiplierBps: k0});
        s[1] = CurveSegmentConfig({supplyShareBps: share1, kMultiplierBps: k1});
    }

    /// @dev Half the allocation at the curve's own steepness, half at twice the constant
    ///      product: a visible price step at a boundary in the middle of the launch.
    function _twoSegments() internal pure returns (CurveSegmentConfig[] memory) {
        return _shape(5_000, 10_000, 5_000, 20_000);
    }

    function _buy(LaunchCurve c, uint256 quoteIn) internal returns (uint256 out) {
        vm.prank(alice);
        out = c.buy(quoteIn, 0, alice);
    }

    function _sell(LaunchCurve c, uint256 tokensIn) internal returns (uint256 out) {
        vm.prank(alice);
        out = c.sell(tokensIn, 0, alice);
    }

    // ─── One segment is the curve this repo already shipped ──────────────

    function test_singleSegmentPricesIdenticallyToTheUnsegmentedCurve() public {
        (LaunchCurve plain,) = _launch(_none());
        (LaunchCurve segmented, LaunchToken segmentedToken) = _launch(_shape(10_000, 10_000));

        // Both resolve to the same one-band table: the brand's own phantom reserve, no mark,
        // and a floor at the reserved allocation.
        assertEq(plain.segmentCount(), 1, "an unsegmented launch resolves to one segment");
        assertEq(segmented.segmentCount(), 1);
        CurveSegment memory band = segmented.getSegment(0);
        assertEq(band.phantomQuote, PHANTOM, "the band prices against the brand's reserve");
        assertEq(band.quoteMark, 0, "and against the whole raise");
        assertEq(band.tokenFloor, segmented.reservedTokens(), "down to the reserved allocation");
        assertEq(segmented.getSegment(0).tokenFloor, plain.getSegment(0).tokenFloor);
        assertEq(segmented.graduationPhantomQuote(), PHANTOM, "graduation splits as it always did");
        assertEq(plain.graduationPhantomQuote(), PHANTOM);

        uint256[3] memory amounts = [uint256(1e6), 250e6, 3_000e6];
        for (uint256 i = 0; i < amounts.length; ++i) {
            (uint256 quotedPlain, uint256 feePlain, uint256 taxPlain) =
                plain.quoteBuy(amounts[i], alice);
            (uint256 quotedSeg, uint256 feeSeg, uint256 taxSeg) =
                segmented.quoteBuy(amounts[i], alice);
            assertEq(quotedSeg, quotedPlain, "one segment quotes the unsegmented amount");
            assertEq(feeSeg, feePlain);
            assertEq(taxSeg, taxPlain);
            assertEq(_buy(segmented, amounts[i]), _buy(plain, amounts[i]), "and fills it");
            assertEq(segmented.trackedTokens(), plain.trackedTokens(), "state stays in step");
            assertEq(segmented.trackedQuote(), plain.trackedQuote());
        }

        uint256 half = segmentedToken.balanceOf(alice) / 2;
        (uint256 sellPlain,,) = plain.quoteSell(half);
        (uint256 sellSeg,,) = segmented.quoteSell(half);
        assertEq(sellSeg, sellPlain, "and sells identically too");
        assertEq(_sell(segmented, half), _sell(plain, half));

        // Including the clamped last fill, which is priced from the token side.
        (uint256 lastPlain,,) = plain.quoteBuy(500_000e6, alice);
        (uint256 lastSeg,,) = segmented.quoteBuy(500_000e6, alice);
        assertEq(lastSeg, lastPlain, "and the buy that empties the allocation");
        assertEq(_buy(segmented, 500_000e6), _buy(plain, 500_000e6));
        assertEq(factory.graduations(), 2, "both launches graduated on that buy");
    }

    // ─── Crossing a boundary ─────────────────────────────────────────────

    function test_buyAcrossASegmentBoundaryFillsAsOneWalkAndMatchesItsQuote() public {
        (LaunchCurve c, LaunchToken t) = _launch(_twoSegments());

        uint256 sellable = c.sellableTokens();
        CurveSegment memory first = c.getSegment(0);
        CurveSegment memory second = c.getSegment(1);
        assertEq(first.tokenFloor, SUPPLY - sellable / 2, "the first band takes half the float");
        assertEq(second.tokenFloor, c.reservedTokens(), "the last band ends on the reserve");
        assertEq(second.quoteMark, PHANTOM * (SUPPLY - first.tokenFloor) / first.tokenFloor);

        // Enough to buy out the first band several times over.
        uint256 crossing = 4_000e6;
        (uint256 quoted, uint256 fee, uint256 tax) = c.quoteBuy(crossing, alice);
        uint256 filled = _buy(c, crossing);

        assertEq(filled, quoted, "the quote is the fill, boundary or not");
        assertEq(c.quoteFeeBalance(), fee, "and so are both fee legs");
        assertEq(c.creatorTaxBalance(), tax);
        assertLt(c.trackedTokens(), first.tokenFloor, "the fill really left the first band");
        assertGt(c.trackedTokens(), c.reservedTokens(), "without reaching the reserve");
        assertGt(filled, sellable / 2, "so more than one band's worth came out");
        assertEq(t.balanceOf(alice), filled);

        // And the sell back over the same boundary is quoted as it settles.
        (uint256 quotedOut,,) = c.quoteSell(filled);
        assertEq(_sell(c, filled), quotedOut, "the sell walk agrees with its own quote");
        assertEq(c.trackedTokens(), SUPPLY, "every token came back");
    }

    function test_priceNeverFallsAcrossASegmentBoundary() public {
        (LaunchCurve c,) = _launch(_twoSegments());
        CurveSegment memory first = c.getSegment(0);
        CurveSegment memory second = c.getSegment(1);

        // The token reserve is continuous at a boundary, so the price there is `k / reserve²`
        // and steps up exactly when `k` does. Stated as the integer comparison rather than as
        // a sampled price so it is exact.
        assertGe(
            second.phantomQuote * first.tokenFloor,
            first.phantomQuote * SUPPLY,
            "the constant product never shrinks at a boundary"
        );

        uint256 previous = type(uint256).max;
        bool crossed;
        for (uint256 i = 0; i < 12; ++i) {
            (uint256 perUnit,,) = c.quoteBuy(1e6, alice);
            assertLe(perUnit, previous, "a fixed spend never buys more than it did before");
            previous = perUnit;
            _buy(c, 300e6);
            if (c.trackedTokens() < first.tokenFloor) crossed = true;
        }
        assertTrue(crossed, "the sweep crossed the boundary");
    }

    function test_aRoundTripAcrossTheBoundaryCannotReturnMoreQuoteThanItPaid() public {
        (LaunchCurve c, LaunchToken t) = _launch(_twoSegments());
        CurveSegment memory first = c.getSegment(0);

        uint256 spend = 4_000e6;
        uint256 balanceBefore = quote.balanceOf(alice);
        uint256 bought = _buy(c, spend);
        assertLt(c.trackedTokens(), first.tokenFloor, "the buy crossed");

        uint256 returned = _sell(c, bought);
        assertLe(returned, spend, "a round trip can never return more quote than it paid");
        assertLt(quote.balanceOf(alice), balanceBefore, "fees make the boundary strictly lossy");
        assertEq(quote.balanceOf(alice), balanceBefore - spend + returned);
        assertEq(t.balanceOf(alice), 0);
        assertEq(c.trackedTokens(), SUPPLY, "and the curve is whole again");

        // The books still reconcile: what the curve tracks is the tradeable reserve plus the
        // two fee buckets, and it never tracks more than it holds.
        assertEq(
            c.trackedQuote(),
            c.realQuoteReserve() + c.quoteFeeBalance() + c.creatorTaxBalance(),
            "tracked quote = real reserve + fee buckets"
        );
        assertLe(c.trackedQuote(), quote.balanceOf(address(c)), "never tracks phantom");
    }

    function test_theSellableAllocationBoundsEveryFillAcrossEverySegment() public {
        (LaunchCurve c, LaunchToken t) = _launch(_twoSegments());
        uint256 sellable = c.sellableTokens();
        uint256 reserved = c.reservedTokens();

        uint256 balanceBefore = quote.balanceOf(alice);
        (uint256 quoted,,) = c.quoteBuy(500_000e6, alice);
        assertEq(quoted, sellable, "the quote clamps at the sellable allocation");

        uint256 filled = _buy(c, 500_000e6);
        assertEq(filled, quoted, "and the fill is the quote");
        assertEq(t.balanceOf(alice), sellable, "never a token more than the float");
        assertLt(balanceBefore - quote.balanceOf(alice), 500_000e6, "the overshoot was refunded");
        assertEq(factory.graduations(), 1, "the crossing buy graduated the launch");
        assertEq(factory.lastTokenOut(), reserved, "handing over exactly the reserved balance");

        // A steepened curve raises more than the threshold by construction: the threshold is
        // the token-side point the curve stops at, and the extra quote seeds the pool deeper
        // at the price the curve actually closed at.
        assertGt(factory.lastQuoteOut(), THRESHOLD, "the steeper tail raised more");
        assertGt(c.graduationPhantomQuote(), PHANTOM, "and graduation splits at that price");
    }

    // ─── Configuration ───────────────────────────────────────────────────

    function test_invalidSegmentConfigurationIsRefused() public {
        (LaunchCurve c, LaunchToken t) = _deployPair();

        CurveSegmentConfig[] memory tooMany = new CurveSegmentConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tooMany[i] = CurveSegmentConfig({supplyShareBps: 2_000, kMultiplierBps: 10_000});
        }
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentCount.selector);
        factory.initializeSegmented(c, address(t), tooMany);

        // Shares that do not cover the float exactly.
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentShare.selector);
        factory.initializeSegmented(c, address(t), _shape(4_000, 10_000, 5_000, 20_000));

        // A band that dispenses nothing.
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentShare.selector);
        factory.initializeSegmented(c, address(t), _shape(10_000, 10_000, 0, 20_000));

        // An opening band priced off the brand's own economics.
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentSteepness.selector);
        factory.initializeSegmented(c, address(t), _shape(5_000, 12_000, 5_000, 20_000));

        // A tail that gets cheaper than the band before it, which is the shape a buyer could
        // round-trip against.
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentSteepness.selector);
        factory.initializeSegmented(c, address(t), _shape(5_000, 10_000, 5_000, 9_000));

        // A tail steeper than the ceiling.
        vm.expectRevert(LaunchCurveSegments.InvalidSegmentSteepness.selector);
        factory.initializeSegmented(c, address(t), _shape(5_000, 10_000, 5_000, 1_000_001));

        // And the shape that is valid still wires.
        factory.initializeSegmented(c, address(t), _twoSegments());
        assertEq(c.segmentCount(), 2);
    }

    function test_fourSegmentsResolveInOrderAndCoverTheWholeFloat() public {
        CurveSegmentConfig[] memory shape = new CurveSegmentConfig[](4);
        shape[0] = CurveSegmentConfig({supplyShareBps: 2_500, kMultiplierBps: 10_000});
        shape[1] = CurveSegmentConfig({supplyShareBps: 2_500, kMultiplierBps: 12_000});
        shape[2] = CurveSegmentConfig({supplyShareBps: 2_500, kMultiplierBps: 12_000});
        shape[3] = CurveSegmentConfig({supplyShareBps: 2_500, kMultiplierBps: 30_000});
        (LaunchCurve c,) = _launch(shape);

        assertEq(c.segmentCount(), 4);
        uint256 ceiling = SUPPLY;
        uint256 sold;
        for (uint256 i = 0; i < 4; ++i) {
            CurveSegment memory band = c.getSegment(i);
            assertLt(band.tokenFloor, ceiling, "bands run strictly downward");
            sold += ceiling - band.tokenFloor;
            ceiling = band.tokenFloor;
        }
        assertEq(ceiling, c.reservedTokens(), "the last band ends on the reserve");
        assertEq(sold, c.sellableTokens(), "and the bands cover the float exactly");

        // One buy through all four bands is still quoted as it fills.
        (uint256 quoted,,) = c.quoteBuy(500_000e6, alice);
        assertEq(_buy(c, 500_000e6), quoted, "a four-band walk quotes what it fills");
        assertEq(quoted, sold, "and stops on the reserve");
    }
}
