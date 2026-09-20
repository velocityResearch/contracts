// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {
    FeePolicySnapshot,
    ILaunchFeeEscrow,
    ILaunchFeePolicy,
    ILaunchSnipeTax
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev The factory as the curve sees it: a fee policy, a snipe-tax policy, and the
///      `graduate(token)` the crossing buy calls back into. Its policy is mutable so the test
///      can prove the curve froze its own copy.
contract MockLaunchFactory is ILaunchFeePolicy, ILaunchSnipeTax {
    address public protocolFeeRecipient;
    uint256 public protocolFeeShareBps;
    address public lpFundRecipient;
    uint16 public lpFundShareBps;
    ILaunchFeeEscrow public feeEscrow;
    uint256 public snipeTaxStartBps = 9_900;
    uint256 public snipeTaxSeconds = 15;

    bool public failGraduation;
    uint256 public graduations;
    uint256 public lastQuoteOut;
    uint256 public lastTokenOut;
    mapping(address token => LaunchCurve curve) public curveOf;

    error GraduationRefused();

    constructor(address protocolFeeRecipient_, uint256 shareBps, ILaunchFeeEscrow escrow) {
        protocolFeeRecipient = protocolFeeRecipient_;
        protocolFeeShareBps = shareBps;
        feeEscrow = escrow;
    }

    function currentFeePolicy() external view returns (FeePolicySnapshot memory) {
        return FeePolicySnapshot({
            protocolFeeRecipient: protocolFeeRecipient,
            protocolFeeShareBps: uint16(protocolFeeShareBps),
            lpFundRecipient: lpFundRecipient,
            lpFundShareBps: lpFundShareBps
        });
    }

    function setPolicy(address recipient, uint256 shareBps) external {
        protocolFeeRecipient = recipient;
        protocolFeeShareBps = shareBps;
    }

    function setLpFund(address recipient, uint16 shareBps) external {
        lpFundRecipient = recipient;
        lpFundShareBps = shareBps;
    }

    function setFailGraduation(bool fail) external {
        failGraduation = fail;
    }

    function initialize(LaunchCurve curve, address token) external {
        curveOf[token] = curve;
        curve.initialize(token);
    }

    function exempt(LaunchCurve curve, address who) external {
        curve.exemptFromSnipeTax(who);
    }

    function setCreatorFeeRecipient(LaunchCurve curve, address who) external {
        curve.setCreatorFeeRecipient(who);
    }

    /// @dev Phase 1 as `LaunchFactory.graduate` performs it, minus the record keeping.
    function graduate(address token) external {
        if (failGraduation) revert GraduationRefused();
        (lastQuoteOut, lastTokenOut) = curveOf[token].graduate(address(this));
        ++graduations;
    }
}

/// @dev A quote asset that hands control to an attacker on the first transfer after it is
///      armed, bubbling up whatever that call reverts with.
contract ReentrantQuote is ERC20 {
    address private _target;
    bytes private _payload;
    bool private _armed;

    constructor() ERC20("Reentrant Dollar", "REENT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata payload) external {
        _target = target;
        _payload = payload;
        _armed = true;
    }

    /// @dev A reverted attack rolls the disarm back too, so a test that expects the revert
    ///      stands the trap down explicitly before trading on.
    function disarm() external {
        _armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (_armed) {
            _armed = false;
            (bool ok, bytes memory ret) = _target.call(_payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @title LaunchCurveTest
/// @notice The bonding curve on its own, against a stand-in factory. Everything about fees,
///         the threshold, the snipe window and the hand-over at graduation is decided here,
///         so this is where those numbers are pinned.
contract LaunchCurveTest is Test {
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
    LaunchCurve curve;
    LaunchToken token;

    address creator = address(0xC12EA);
    address protocol = address(0xF33);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 launchedAt;

    function setUp() public {
        quote = new MockUSDC();
        escrow = new LaunchFeeEscrow();
        factory = new MockLaunchFactory(protocol, PROTOCOL_SHARE_BPS, escrow);
        (curve, token) = _deployLaunch(address(quote));
        launchedAt = block.timestamp;

        quote.mint(alice, 1_000_000e6);
        quote.mint(bob, 1_000_000e6);
        vm.prank(alice);
        quote.approve(address(curve), type(uint256).max);
        vm.prank(bob);
        quote.approve(address(curve), type(uint256).max);
        vm.prank(alice);
        token.approve(address(curve), type(uint256).max);
        vm.prank(bob);
        token.approve(address(curve), type(uint256).max);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev Curve first, then the token that mints to it, then the wiring — the order the
    ///      deployer uses.
    function _deployLaunch(address pairToken) internal returns (LaunchCurve c, LaunchToken t) {
        c = new LaunchCurve(
            pairToken, creator, address(factory), PHANTOM, FEE_BPS, TAX_BPS, THRESHOLD
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
        factory.initialize(c, address(t));
        factory.exempt(c, creator);
    }

    /// @dev Past the snipe window, so ordinary buyers pay the ordinary fee.
    function _afterSnipeWindow() internal {
        vm.warp(launchedAt + 16);
    }

    function _buy(address who, uint256 quoteIn) internal returns (uint256 out) {
        vm.prank(who);
        out = curve.buy(quoteIn, 0, who);
    }

    function _sell(address who, uint256 tokensIn) internal returns (uint256 out) {
        vm.prank(who);
        out = curve.sell(tokensIn, 0, who);
    }

    /// @dev The curve's accounting identity: what it tracks is the tradeable reserve plus the
    ///      two fee buckets, and it never tracks more than it holds.
    function _assertReconciled() internal view {
        assertEq(
            curve.trackedQuote(),
            curve.realQuoteReserve() + curve.quoteFeeBalance() + curve.creatorTaxBalance(),
            "tracked quote = real reserve + fee buckets"
        );
        assertLe(curve.trackedQuote(), quote.balanceOf(address(curve)), "never tracks phantom");
        assertEq(curve.trackedTokens(), token.balanceOf(address(curve)), "token side tracked");
    }

    // ─── Initialisation ──────────────────────────────────────────────────

    function test_initializeReservesTheGraduationAllocationAndFreezesPolicy() public view {
        uint256 reserved = (SUPPLY * PHANTOM) / (PHANTOM + THRESHOLD);
        assertEq(curve.reservedTokens(), reserved);
        assertEq(curve.sellableTokens(), SUPPLY - reserved);
        assertEq(curve.launchSupply(), SUPPLY);
        assertEq(curve.trackedTokens(), SUPPLY);
        assertEq(curve.protocolFeeRecipient(), protocol);
        assertEq(curve.protocolFeeShareBps(), PROTOCOL_SHARE_BPS);
        assertEq(address(curve.feeEscrow()), address(escrow));
        assertEq(curve.snipeTaxStartBps(), 9_900);
        assertEq(curve.snipeTaxSeconds(), 15);
        assertFalse(curve.readyToGraduate());
    }

    function test_initializeIsFactoryOnlyAndOnce() public {
        vm.expectRevert(LaunchCurve.NotFactory.selector);
        curve.initialize(address(token));

        vm.expectRevert(LaunchCurve.AlreadyInitialized.selector);
        factory.initialize(curve, address(token));
    }

    function test_constructorRefusesACombinedFeeAboveTheCeiling() public {
        vm.expectRevert(LaunchCurve.InvalidFeePolicy.selector);
        new LaunchCurve(address(quote), creator, address(factory), PHANTOM, 1_000, 1_001, THRESHOLD);
    }

    // ─── Buying and selling ──────────────────────────────────────────────

    function test_buyChargesFeeAndTaxOnTheQuoteLegAndPricesTheRest() public {
        _afterSnipeWindow();
        uint256 quoteIn = 1_000e6;
        (uint256 quotedOut, uint256 quotedFee, uint256 quotedTax) = curve.quoteBuy(quoteIn, alice);

        vm.expectEmit(true, true, false, true);
        emit LaunchCurve.CurveBuy(alice, alice, quoteIn, quotedOut, quotedFee, quotedTax);
        uint256 out = _buy(alice, quoteIn);

        assertEq(out, quotedOut, "preview equals the trade");
        assertEq(quotedFee, (quoteIn * FEE_BPS) / BPS, "1% base fee");
        assertEq(quotedTax, (quoteIn * TAX_BPS) / BPS, "2% creator tax");
        assertEq(token.balanceOf(alice), out);
        assertEq(curve.quoteFeeBalance(), quotedFee);
        assertEq(curve.creatorTaxBalance(), quotedTax);
        assertEq(curve.realQuoteReserve(), quoteIn - quotedFee - quotedTax);
        // The whole spend is priced against phantom + real: x·y = k on the net amount.
        uint256 net = quoteIn - quotedFee - quotedTax;
        assertEq(out, (net * SUPPLY) / (PHANTOM + net), "constant product on the net input");
        _assertReconciled();
    }

    function test_roundTripLosesExactlyFeePlusTax() public {
        _afterSnipeWindow();
        uint256 quoteIn = 5_000e6;
        uint256 before = quote.balanceOf(alice);

        uint256 out = _buy(alice, quoteIn);
        (uint256 quotedBack, uint256 sellFee, uint256 sellTax) = curve.quoteSell(out);
        uint256 back = _sell(alice, out);

        assertEq(back, quotedBack, "sell preview equals the trade");
        uint256 buyFee = (quoteIn * FEE_BPS) / BPS;
        uint256 buyTax = (quoteIn * TAX_BPS) / BPS;
        uint256 lost = before - quote.balanceOf(alice);
        // The curve is symmetric, so selling back the exact tokens returns the exact net
        // input less the sell-side fee legs, up to the integer rounding of the two quotes.
        uint256 grossBack = back + sellFee + sellTax;
        assertApproxEqAbs(grossBack, quoteIn - buyFee - buyTax, 2, "net in comes back gross");
        assertApproxEqAbs(lost, buyFee + buyTax + sellFee + sellTax, 2, "loss is the fee legs");
        assertEq(curve.quoteFeeBalance(), buyFee + sellFee);
        assertEq(curve.creatorTaxBalance(), buyTax + sellTax);
        assertEq(token.balanceOf(alice), 0);
        _assertReconciled();
    }

    function test_priceRisesWithEveryBuy() public {
        _afterSnipeWindow();
        uint256 previous = type(uint256).max;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 out = _buy(alice, 500e6);
            assertLt(out, previous, "same spend buys fewer tokens each time");
            previous = out;
        }
        _assertReconciled();
    }

    function test_sellCannotDrawMoreThanTheRealReserve() public {
        _afterSnipeWindow();
        uint256 aliceOut = _buy(alice, 2_000e6);
        uint256 bobOut = _buy(bob, 3_000e6);

        uint256 realBefore = curve.realQuoteReserve();
        uint256 bobBack = _sell(bob, bobOut);
        assertLt(bobBack, realBefore, "a sell is bounded by what the curve really holds");

        uint256 aliceBack = _sell(alice, aliceOut);
        // Every token is back on the curve; the only quote left is fees and rounding dust.
        assertEq(curve.trackedTokens(), SUPPLY);
        assertLe(curve.realQuoteReserve(), 10, "reserve returns to (near) zero, never below");
        assertLt(aliceBack + bobBack, 5_000e6);
        _assertReconciled();
    }

    function test_minOutIsEnforcedOnBothSides() public {
        _afterSnipeWindow();
        (uint256 out,,) = curve.quoteBuy(1_000e6, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchCurve.SlippageExceeded.selector, out, out + 1));
        curve.buy(1_000e6, out + 1, alice);

        uint256 got = _buy(alice, 1_000e6);
        (uint256 back,,) = curve.quoteSell(got);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchCurve.SlippageExceeded.selector, back, back + 1)
        );
        curve.sell(got, back + 1, alice);
    }

    function test_zeroAndDonatedQuoteDoNotMoveTheCurve() public {
        _afterSnipeWindow();
        vm.prank(alice);
        vm.expectRevert(LaunchCurve.ZeroAmount.selector);
        curve.buy(0, 0, alice);

        // A donation lands on the balance but not on the price.
        (uint256 outBefore,,) = curve.quoteBuy(1_000e6, alice);
        quote.mint(address(curve), 100_000e6);
        (uint256 outAfter,,) = curve.quoteBuy(1_000e6, alice);
        assertEq(outAfter, outBefore, "price reads tracked reserves, not balances");
        assertEq(curve.realQuoteReserve(), 0);
    }

    // ─── Threshold ───────────────────────────────────────────────────────

    function test_crossingBuyIsClampedAndRefundedAndGraduates() public {
        _afterSnipeWindow();
        uint256 sellable = curve.sellableTokens();
        uint256 offered = 50_000e6;
        (uint256 quotedOut, uint256 quotedFee, uint256 quotedTax) = curve.quoteBuy(offered, alice);
        assertEq(quotedOut, sellable, "preview is clamped to the allocation");

        uint256 before = quote.balanceOf(alice);
        uint256 out = _buy(alice, offered);
        uint256 spent = before - quote.balanceOf(alice);

        assertEq(out, sellable, "the last buy takes exactly the allocation");
        assertLt(spent, offered, "the excess was refunded");
        assertEq(quotedFee, (spent * FEE_BPS) / BPS, "fee charged on the clamped spend");
        assertEq(quotedTax, (spent * TAX_BPS) / BPS);
        // The real reserve lands on the threshold: the allocation was derived from it.
        assertApproxEqRel(factory.lastQuoteOut(), THRESHOLD, 1e15, "reserve ~ threshold");
        assertEq(factory.graduations(), 1, "graduated inside the crossing buy");
        assertTrue(curve.graduated());
        assertEq(factory.lastTokenOut(), curve.reservedTokens(), "pool gets the reserved side");
        assertEq(curve.trackedQuote(), 0);
        assertEq(curve.trackedTokens(), 0);
        assertEq(curve.quoteFeeBalance(), 0, "fees swept during graduation");
        assertEq(curve.creatorTaxBalance(), 0);
        assertEq(
            quote.balanceOf(address(factory)) + quote.balanceOf(address(escrow)),
            spent,
            "spend went to the factory and the escrow, nothing left on the curve"
        );
    }

    function test_partialFillHonoursThePriceNotTheQuantity() public {
        _afterSnipeWindow();
        uint256 sellable = curve.sellableTokens();
        // A quantity the full offer would never reach, but which the clamped fill's price does
        // satisfy: asking for the allocation at the price of the whole offer.
        vm.prank(alice);
        curve.buy(50_000e6, sellable, alice);
        assertEq(token.balanceOf(alice), sellable);
    }

    function test_partialFillStillRejectsAPriceBetterThanTheCurveGives() public {
        _afterSnipeWindow();
        uint256 sellable = curve.sellableTokens();
        // The clamped fill spends ~8,340 of the 50,000 offered. Asking for the allocation
        // at the price 8,000 would buy it for demands a better price than the curve gives.
        uint256 minOut = (sellable * 50_000e6) / 8_000e6;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchCurve.SlippageExceeded.selector, sellable, minOut)
        );
        curve.buy(50_000e6, minOut, alice);
    }

    function test_readyButUngraduatedCurveIsClosedOnBothSides() public {
        _afterSnipeWindow();
        factory.setFailGraduation(true);

        vm.expectEmit(true, false, false, false);
        emit LaunchCurve.AutoGraduationFailed(address(token), 0);
        uint256 out = _buy(alice, 50_000e6);

        assertTrue(curve.readyToGraduate(), "ready");
        assertFalse(curve.graduated(), "but the flag is not set");
        assertGt(out, 0, "the crossing buy still succeeded");

        vm.prank(alice);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.sell(out, 0, alice);
        vm.prank(bob);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.buy(1e6, 0, bob);

        // Retryable once the factory recovers.
        factory.setFailGraduation(false);
        factory.graduate(address(token));
        assertTrue(curve.graduated());
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    function test_graduateIsFactoryOnlyAndOnlyWhenReady() public {
        vm.expectRevert(LaunchCurve.NotFactory.selector);
        curve.graduate(address(this));

        vm.expectRevert(LaunchCurve.NotReadyToGraduate.selector);
        factory.graduate(address(token));
    }

    function test_tradingAndSweepingAreClosedAfterGraduation() public {
        _afterSnipeWindow();
        _buy(alice, 50_000e6);
        assertTrue(curve.graduated());

        vm.prank(bob);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.buy(1e6, 0, bob);
        vm.prank(alice);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.sell(1, 0, alice);
        vm.expectRevert(LaunchCurve.AlreadyGraduated.selector);
        curve.sweepFees();
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.quoteBuy(1e6, bob);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        curve.quoteSell(1);
        vm.expectRevert(LaunchCurve.AlreadyGraduated.selector);
        factory.graduate(address(token));
        assertFalse(curve.readyToGraduate(), "graduated is not ready");
    }

    // ─── Fees ────────────────────────────────────────────────────────────

    function test_sweepCreditsEscrowWithTheSnapshottedSplit() public {
        _afterSnipeWindow();
        _buy(alice, 5_000e6);
        uint256 pending = curve.quoteFeeBalance();
        uint256 tax = curve.creatorTaxBalance();
        uint256 real = curve.realQuoteReserve();
        assertGt(pending, 0);

        // The factory retunes its policy after launch; the curve must not notice.
        factory.setPolicy(address(0xBAD), 9_000);

        uint256 protocolAmount = (pending * PROTOCOL_SHARE_BPS) / BPS;
        uint256 creatorAmount = pending - protocolAmount + tax;
        vm.expectEmit(false, false, false, true);
        emit LaunchCurve.FeesSwept(protocolAmount, creatorAmount, 0);
        vm.prank(bob); // anyone
        curve.sweepFees();

        assertEq(escrow.balanceOfToken(protocol, address(quote)), protocolAmount, "30%");
        assertEq(escrow.balanceOfToken(creator, address(quote)), creatorAmount, "70% + tax");
        assertEq(escrow.balanceOfToken(address(0xBAD), address(quote)), 0, "retune ignored");
        assertEq(curve.quoteFeeBalance(), 0);
        assertEq(curve.creatorTaxBalance(), 0);
        assertEq(curve.realQuoteReserve(), real, "the tradeable reserve is untouched");
        assertEq(curve.trackedQuote(), real);
        _assertReconciled();

        // A second sweep with nothing pending is a quiet no-op, not a revert.
        curve.sweepFees();
        assertEq(escrow.balanceOfToken(protocol, address(quote)), protocolAmount);
    }

    /// @dev The three-way split, on a curve launched while the LP fund leg was on. Asserts
    ///      the shape the split is specified as — 40% creator, 30% protocol, 30% fund — and
    ///      that the three legs add up to exactly the fee, which is what stops value being
    ///      stranded in a curve that can never be upgraded.
    function test_sweepSplitsTheFeeThreeWays() public {
        address lpFund = address(0x11FD);
        factory.setLpFund(lpFund, 3_000);
        (LaunchCurve c, LaunchToken t) = _deployLaunch(address(quote));
        vm.prank(alice);
        quote.approve(address(c), type(uint256).max);
        vm.warp(block.timestamp + 16);

        vm.prank(alice);
        c.buy(5_000e6, 0, alice);
        uint256 pending = c.quoteFeeBalance();
        uint256 tax = c.creatorTaxBalance();
        assertGt(pending, 0, "a fee accrued");

        c.sweepFees();

        uint256 toProtocol = escrow.balanceOfToken(protocol, address(quote));
        uint256 toLpFund = escrow.balanceOfToken(lpFund, address(quote));
        uint256 toCreator = escrow.balanceOfToken(creator, address(quote));

        assertEq(toProtocol, pending * 3_000 / BPS, "protocol takes 30% of the fee");
        assertEq(toLpFund, pending * 3_000 / BPS, "the fund takes 30% of the fee");
        // The creator's 40% plus their tax, which never enters the split.
        assertEq(toCreator, pending - toProtocol - toLpFund + tax, "creator takes the remainder");
        assertEq(toCreator - tax, pending * 4_000 / BPS, "which is 40% of the fee");
        assertEq(toProtocol + toLpFund + toCreator, pending + tax, "and nothing is stranded");
        assertEq(t.balanceOf(address(c)), c.trackedTokens(), "token ledger still matches");
    }

    /// @dev The fund's terms freeze at launch exactly as the protocol's do. A curve launched
    ///      before the fund existed keeps splitting two ways forever, and one launched under
    ///      one fund address never pays a later one.
    function test_theCurveFreezesTheFundTermsItLaunchedUnder() public {
        // This curve launched with the leg off, in `setUp`.
        assertEq(curve.lpFundShareBps(), 0, "no fund share frozen");
        assertEq(curve.lpFundRecipient(), address(0), "no fund recipient frozen");

        address lpFund = address(0x11FD);
        factory.setLpFund(lpFund, 3_000);

        _afterSnipeWindow();
        _buy(alice, 5_000e6);
        uint256 pending = curve.quoteFeeBalance();
        curve.sweepFees();

        assertEq(escrow.balanceOfToken(lpFund, address(quote)), 0, "the fund gets nothing");
        assertEq(
            escrow.balanceOfToken(protocol, address(quote)),
            pending * PROTOCOL_SHARE_BPS / BPS,
            "and the protocol's share is undiluted"
        );
    }

    /// @dev A policy whose two floored shares exceed the whole fee would underflow the
    ///      creator's remainder on the first sweep of an immutable curve, so the curve
    ///      refuses it at initialize rather than trusting the proxy that served it.
    function test_initializeRejectsASplitThatExceedsTheWholeFee() public {
        factory.setPolicy(protocol, 6_000);
        factory.setLpFund(address(0x11FD), 5_000);

        LaunchCurve c = new LaunchCurve(
            address(quote), creator, address(factory), PHANTOM, FEE_BPS, TAX_BPS, THRESHOLD
        );
        LaunchToken t = new LaunchToken(
            "Over",
            "OVER",
            "",
            "",
            LaunchToken.Socials("", "", "", "", ""),
            creator,
            address(c),
            address(factory),
            SUPPLY
        );
        vm.expectRevert(LaunchCurve.InvalidFeePolicy.selector);
        factory.initialize(c, address(t));
    }

    /// @dev A nonzero fund share with no recipient would credit the escrow to address zero
    ///      and wedge every later sweep on a curve that cannot be fixed.
    function test_initializeRejectsAFundShareWithNoRecipient() public {
        factory.setLpFund(address(0), 3_000);

        LaunchCurve c = new LaunchCurve(
            address(quote), creator, address(factory), PHANTOM, FEE_BPS, TAX_BPS, THRESHOLD
        );
        LaunchToken t = new LaunchToken(
            "NoFund",
            "NOFD",
            "",
            "",
            LaunchToken.Socials("", "", "", "", ""),
            creator,
            address(c),
            address(factory),
            SUPPLY
        );
        vm.expectRevert(LaunchCurve.InvalidFeePolicy.selector);
        factory.initialize(c, address(t));
    }

    function test_creatorFeesFollowTheRecipientTheFactorySets() public {
        _afterSnipeWindow();
        _buy(alice, 1_000e6);
        address heir = address(0x4E12);

        vm.expectRevert(LaunchCurve.NotFactory.selector);
        curve.setCreatorFeeRecipient(heir);
        factory.setCreatorFeeRecipient(curve, heir);
        curve.sweepFees();

        assertEq(escrow.balanceOfToken(creator, address(quote)), 0);
        assertGt(escrow.balanceOfToken(heir, address(quote)), 0);
    }

    // ─── Snipe tax ───────────────────────────────────────────────────────

    function test_snipeTaxDecaysToZeroAcrossTheWindow() public view {
        assertEq(curve.currentSnipeTaxBps(alice), 9_900, "launch second: the full tax");
        assertEq(curve.currentSnipeTaxBps(creator), 0, "exempt reads zero");
    }

    function test_snipeTaxHalvesFourteenTimesThenVanishes() public {
        uint256 previous = 9_900;
        for (uint256 s = 1; s < 15; ++s) {
            vm.warp(launchedAt + s);
            uint256 now_ = curve.currentSnipeTaxBps(alice);
            assertEq(now_, 9_900 >> ((s * 14) / 15), "right-shift decay");
            assertLe(now_, previous);
            previous = now_;
        }
        vm.warp(launchedAt + 15);
        assertEq(curve.currentSnipeTaxBps(alice), 0, "gone at the end of the window");
        vm.warp(launchedAt + 1 days);
        assertEq(curve.currentSnipeTaxBps(alice), 0);
    }

    function test_launchSecondBuyPaysTheClampedSnipeTaxIntoTheFeeBucket() public {
        // 99% is clamped so fee + tax + snipe leaves the buyer 1%: 10000-100-200-100 = 9600.
        uint256 quoteIn = 1_000e6;
        uint256 snipe = (quoteIn * 9_600) / BPS;
        uint256 fee = (quoteIn * FEE_BPS) / BPS;
        uint256 tax = (quoteIn * TAX_BPS) / BPS;
        (uint256 quotedOut, uint256 quotedFee, uint256 quotedTax) = curve.quoteBuy(quoteIn, alice);
        assertEq(quotedFee, fee + snipe, "preview folds the snipe tax into the fee");
        assertEq(quotedTax, tax);

        vm.expectEmit(true, false, false, true);
        emit LaunchCurve.SnipeTaxCharged(alice, snipe);
        uint256 out = _buy(alice, quoteIn);

        assertEq(out, quotedOut);
        assertEq(curve.quoteFeeBalance(), fee + snipe, "snipe tax splits like the base fee");
        assertEq(curve.creatorTaxBalance(), tax);
        // Only 1% of the spend actually bought tokens.
        uint256 net = quoteIn - fee - tax - snipe;
        assertEq(out, (net * SUPPLY) / (PHANTOM + net));

        // The same spend a second later, by an exempt wallet, buys at the untaxed price.
        (uint256 exemptOut, uint256 exemptFee,) = curve.quoteBuy(quoteIn, creator);
        assertEq(exemptFee, fee);
        assertGt(exemptOut, out * 50, "the sniper got a fraction of the exempt fill");
    }

    function test_exemptionsAreFactoryOnly() public {
        vm.expectRevert(LaunchCurve.NotFactory.selector);
        curve.exemptFromSnipeTax(alice);
        factory.exempt(curve, alice);
        assertEq(curve.currentSnipeTaxBps(alice), 0);
    }

    // ─── Reentrancy ──────────────────────────────────────────────────────

    function test_reentrantQuoteCannotReenterBuyOrSell() public {
        ReentrantQuote evil = new ReentrantQuote();
        (LaunchCurve c, LaunchToken t) = _deployLaunch(address(evil));
        vm.warp(block.timestamp + 16);
        evil.mint(alice, 100_000e6);
        vm.startPrank(alice);
        evil.approve(address(c), type(uint256).max);
        t.approve(address(c), type(uint256).max);

        // Reenter buy from inside the buy's own pull.
        evil.arm(address(c), abi.encodeCall(LaunchCurve.buy, (1e6, 0, alice)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        c.buy(1_000e6, 0, alice);
        evil.disarm();

        // Nothing was booked by the failed attempt.
        assertEq(c.trackedQuote(), 0);
        assertEq(c.quoteFeeBalance(), 0);

        uint256 out = c.buy(1_000e6, 0, alice);

        // Reenter sell from inside the sell's own payout.
        evil.arm(address(c), abi.encodeCall(LaunchCurve.sell, (1, 0, alice)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        c.sell(out, 0, alice);
        evil.disarm();

        // And buy from inside a sell's payout.
        evil.arm(address(c), abi.encodeCall(LaunchCurve.buy, (1e6, 0, alice)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        c.sell(out, 0, alice);
        evil.disarm();
        vm.stopPrank();

        assertEq(t.balanceOf(alice), out, "the holder keeps their tokens");
        assertEq(c.trackedTokens(), t.balanceOf(address(c)));
    }

    function test_graduationSweepCallbackCannotReopenTrading() public {
        ReentrantQuote evil = new ReentrantQuote();
        (LaunchCurve c, LaunchToken t) = _deployLaunch(address(evil));
        vm.warp(block.timestamp + 16);
        evil.mint(alice, 100_000e6);
        vm.startPrank(alice);
        evil.approve(address(c), type(uint256).max);
        c.buy(1_000e6, 0, alice);
        vm.stopPrank();

        // A direct sweep pays the escrow; the escrow's pull is where control leaks. The
        // sweep is guarded, so a buy from inside it fails on the guard.
        evil.arm(address(c), abi.encodeCall(LaunchCurve.buy, (1e6, 0, alice)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        c.sweepFees();
        evil.disarm();

        // Fill the curve so the factory can graduate it, from a wallet that is not armed.
        evil.mint(bob, 100_000e6);
        vm.startPrank(bob);
        evil.approve(address(c), type(uint256).max);
        factory.setFailGraduation(true);
        c.buy(50_000e6, 0, bob);
        vm.stopPrank();
        factory.setFailGraduation(false);
        assertTrue(c.readyToGraduate());

        // `graduate` is not guarded, so the sweep inside it is the one place a callback runs
        // outside the guard. The flag is already set, so the buy is refused on that instead.
        evil.arm(address(c), abi.encodeCall(LaunchCurve.buy, (1e6, 0, alice)));
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        factory.graduate(address(t));
    }

    // ─── Invariant sweep ─────────────────────────────────────────────────

    function testFuzz_accountingReconcilesAcrossRandomTrades(uint256 seed) public {
        _afterSnipeWindow();
        for (uint256 i = 0; i < 12 && !curve.graduated(); ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = r % 2 == 0 ? alice : bob;
            uint256 held = token.balanceOf(who);
            if (r % 3 == 0 && held != 0) {
                _sell(who, (held * ((r >> 8) % 100 + 1)) / 100);
            } else {
                _buy(who, ((r >> 16) % 2_000 + 1) * 1e6);
            }
            _assertReconciled();
        }
    }
}
