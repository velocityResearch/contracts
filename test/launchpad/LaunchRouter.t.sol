// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchRouter} from "../../src/launchpad/LaunchRouter.sol";
import {GraduationPhase, ILaunchFactory} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchRouterTest
/// @notice What the router has to be true for: the three doors into a curve — its own quote
///         brand, the reserve asset behind that brand, and any other brand of the same
///         reserve — are the same trade, and the conversion between them costs the trader
///         nothing. Every test that compares doors compares launches that are identical
///         except for the currency held on the way in, so any difference in the result is a
///         difference the router introduced.
///
///         The other half is what a periphery contract must never do: keep a balance, keep an
///         allowance, buy for itself, ignore a slippage bound, or let a stale transaction
///         land. Those are checked on every path rather than once.
contract LaunchRouterTest is LaunchpadFixture {
    LaunchRouter internal launchRouter;

    /// @dev A second brand on the same reserve, standing in for "some other market's brand".
    address internal altBrand;

    address internal payer = address(0x9A1);
    address internal usdgPayer = address(0x9A2);
    address internal brandPayer = address(0x9A3);

    uint256 internal constant QUOTE_IN = 250e6;

    function setUp() public {
        _deployLaunchpadStack();

        launchRouter = new LaunchRouter(launchFactory);
        vm.prank(owner);
        launchFactory.setLaunchForwarder(address(launchRouter));

        (altBrand,) = marketFactory.registerBrand("Alt Dollar", "altUSD");
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1;
    }

    /// @dev Past the launch window, so a buyer who was never exempted still trades untaxed.
    function _warpPastSnipeWindow() internal {
        vm.warp(vm.getBlockTimestamp() + launchFactory.snipeTaxSeconds() + 1);
    }

    function _fundBrand(address who, address brand, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(brand, amount, who);
        vm.stopPrank();
    }

    function _params(string memory symbol)
        internal
        view
        returns (LaunchFactory.TokenParams memory)
    {
        return _tokenParams(symbol, symbol, keccak256(bytes(symbol)));
    }

    function _launchPayingQuote(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut
    ) internal returns (address token, address curve, uint256 tokensOut) {
        return _launchPayingQuote(who, symbol, quoteIn, minTokensOut, new address[](0));
    }

    function _launchPayingQuote(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut,
        address[] memory exemptions
    ) internal returns (address token, address curve, uint256 tokensOut) {
        uint256 total = LAUNCH_FEE + quoteIn;
        _fundBrand(who, quoteBrand, total);
        vm.startPrank(who);
        IERC20(quoteBrand).approve(address(launchRouter), total);
        (token, curve, tokensOut) = launchRouter.launchAndBuy(
            _params(symbol),
            launchConfigId,
            quoteBrand,
            exemptions,
            quoteIn,
            minTokensOut,
            _deadline()
        );
        vm.stopPrank();
    }

    function _launchPayingUsdg(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut
    ) internal returns (address token, address curve, uint256 tokensOut) {
        uint256 total = LAUNCH_FEE + quoteIn;
        usdg.mint(who, total);
        vm.startPrank(who);
        usdg.approve(address(launchRouter), total);
        (token, curve, tokensOut) = launchRouter.launchAndBuyWithReserveAsset(
            _params(symbol),
            launchConfigId,
            quoteBrand,
            new address[](0),
            quoteIn,
            minTokensOut,
            _deadline()
        );
        vm.stopPrank();
    }

    function _launchPayingAltBrand(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut
    ) internal returns (address token, address curve, uint256 tokensOut) {
        uint256 total = LAUNCH_FEE + quoteIn;
        _fundBrand(who, altBrand, total);
        vm.startPrank(who);
        IERC20(altBrand).approve(address(launchRouter), total);
        (token, curve, tokensOut) = launchRouter.launchAndBuyWithBrand(
            altBrand,
            _params(symbol),
            launchConfigId,
            quoteBrand,
            new address[](0),
            quoteIn,
            minTokensOut,
            _deadline()
        );
        vm.stopPrank();
    }

    function _buyWithQuote(address who, address token, uint256 quoteIn, uint256 minTokensOut)
        internal
        returns (uint256)
    {
        _fundBrand(who, quoteBrand, quoteIn);
        vm.startPrank(who);
        IERC20(quoteBrand).approve(address(launchRouter), quoteIn);
        uint256 out = launchRouter.buy(token, quoteIn, minTokensOut, _deadline());
        vm.stopPrank();
        return out;
    }

    function _buyWithUsdg(address who, address token, uint256 assetIn, uint256 minTokensOut)
        internal
        returns (uint256)
    {
        usdg.mint(who, assetIn);
        vm.startPrank(who);
        usdg.approve(address(launchRouter), assetIn);
        uint256 out = launchRouter.buyWithReserveAsset(token, assetIn, minTokensOut, _deadline());
        vm.stopPrank();
        return out;
    }

    function _buyWithAltBrand(address who, address token, uint256 amountIn, uint256 minTokensOut)
        internal
        returns (uint256)
    {
        _fundBrand(who, altBrand, amountIn);
        vm.startPrank(who);
        IERC20(altBrand).approve(address(launchRouter), amountIn);
        uint256 out =
            launchRouter.buyWithBrand(altBrand, token, amountIn, minTokensOut, _deadline());
        vm.stopPrank();
        return out;
    }

    function _approveToken(address who, address token, uint256 amount) internal {
        vm.prank(who);
        IERC20(token).approve(address(launchRouter), amount);
    }

    /// @dev A launch with nothing bought on it yet, plus `who` holding a position bought
    ///      through the quote door and the launch window closed behind it.
    function _launchWithPosition(string memory symbol, address who, uint256 quoteIn)
        internal
        returns (address token, address curve, uint256 held)
    {
        (token, curve,) = _launchPayingQuote(payer, symbol, 0, 0);
        _warpPastSnipeWindow();
        held = _buyWithQuote(who, token, quoteIn, 0);
    }

    /// @dev The invariant every path shares: nothing of anyone's is left here, and nothing
    ///      here is left spendable by anyone else.
    function _assertRouterEmpty(address token, address curve) internal view {
        address r = address(launchRouter);
        assertEq(usdg.balanceOf(r), 0, "router holds no reserve asset");
        assertEq(IERC20(quoteBrand).balanceOf(r), 0, "router holds no quote brand");
        assertEq(IERC20(altBrand).balanceOf(r), 0, "router holds no other brand");
        assertEq(IERC20(token).balanceOf(r), 0, "router holds no launch token");
        assertEq(IERC20(quoteBrand).allowance(r, curve), 0, "no standing quote allowance");
        assertEq(IERC20(token).allowance(r, curve), 0, "no standing token allowance");
        assertEq(
            IERC20(quoteBrand).allowance(r, address(launchFactory)),
            0,
            "no standing launch-fee allowance"
        );
        assertEq(usdg.allowance(r, address(reserve)), 0, "no standing mint allowance");
    }

    // ─── The three doors, on the way in ──────────────────────────────────

    function test_everyLaunchDoorBuysTheSameTokensForTheSameQuote() public {
        (address t1, address c1, uint256 out1) = _launchPayingQuote(payer, "AAA", QUOTE_IN, 0);
        (address t2, address c2, uint256 out2) = _launchPayingUsdg(usdgPayer, "BBB", QUOTE_IN, 0);
        (address t3, address c3, uint256 out3) =
            _launchPayingAltBrand(brandPayer, "CCC", QUOTE_IN, 0);

        assertGt(out1, 0, "the opening buy bought something");
        assertEq(out2, out1, "the reserve asset is the same trade");
        assertEq(out3, out1, "another brand of the reserve is the same trade");

        assertEq(IERC20(t1).balanceOf(payer), out1, "the launcher holds the tokens");
        assertEq(IERC20(t2).balanceOf(usdgPayer), out2);
        assertEq(IERC20(t3).balanceOf(brandPayer), out3);

        // Every input was consumed: the fee to the protocol, the rest onto the curve.
        assertEq(IERC20(quoteBrand).balanceOf(payer), 0, "nothing came back unspent");
        assertEq(usdg.balanceOf(usdgPayer), 0);
        assertEq(IERC20(altBrand).balanceOf(brandPayer), 0);
        assertEq(IERC20(quoteBrand).balanceOf(c1), QUOTE_IN, "the curve holds the quote");
        assertEq(IERC20(quoteBrand).balanceOf(c2), QUOTE_IN);
        assertEq(IERC20(quoteBrand).balanceOf(c3), QUOTE_IN);
        assertEq(
            IERC20(quoteBrand).balanceOf(protocolFeeRecipient),
            3 * LAUNCH_FEE,
            "three launch fees, paid in the quote brand whatever was handed in"
        );

        _assertRouterEmpty(t1, c1);
        _assertRouterEmpty(t2, c2);
        _assertRouterEmpty(t3, c3);
    }

    function test_launchAndBuy_attributesTheLaunchToTheCallerNotTheRouter() public {
        (address token, address curve,) = _launchPayingQuote(payer, "DDD", QUOTE_IN, 0);

        ILaunchFactory.LaunchedToken memory rec = launchFactory.getLaunchedToken(token);
        assertEq(rec.deployer, payer, "the launcher, not the forwarder");
        assertEq(rec.curve, curve);
        assertEq(rec.pairToken, quoteBrand);
        assertEq(rec.reserve, address(reserve));

        // The CREATE2 pair is namespaced by the initiating account, so the address the caller
        // was quoted before sending is the address they get through the router.
        (address predictedToken, address predictedCurve) =
            launchFactory.predictLaunchAddresses(_params("DDD"), launchConfigId, quoteBrand, payer);
        assertEq(predictedToken, token, "predicted token address");
        assertEq(predictedCurve, curve, "predicted curve address");
    }

    function test_launchOnly_takesTheFeeAndBuysNothing() public {
        (address token, address curve, uint256 out) = _launchPayingQuote(payer, "EEE", 0, 0);

        assertEq(out, 0, "nothing was bought");
        assertEq(IERC20(token).balanceOf(payer), 0, "and nothing was delivered");
        assertEq(IERC20(token).balanceOf(curve), LAUNCH_SUPPLY, "the whole supply is on sale");
        assertEq(IERC20(quoteBrand).balanceOf(curve), 0, "no quote on the curve yet");
        assertEq(IERC20(quoteBrand).balanceOf(protocolFeeRecipient), LAUNCH_FEE);
        assertTrue(launchFactory.getLaunchedToken(token).exists, "the launch was recorded");
        _assertRouterEmpty(token, curve);

        // The same through the reserve door: the fee alone is minted into the quote brand.
        (address token2, address curve2, uint256 out2) = _launchPayingUsdg(usdgPayer, "FFF", 0, 0);
        assertEq(out2, 0);
        assertEq(usdg.balanceOf(usdgPayer), 0, "the fee was taken in USDG");
        assertEq(IERC20(quoteBrand).balanceOf(protocolFeeRecipient), 2 * LAUNCH_FEE);
        _assertRouterEmpty(token2, curve2);
    }

    function test_launchOnly_refusesAMinOutItCannotHonour() public {
        _fundBrand(payer, quoteBrand, LAUNCH_FEE);
        vm.startPrank(payer);
        IERC20(quoteBrand).approve(address(launchRouter), LAUNCH_FEE);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.InsufficientOutput.selector, 0, 1));
        launchRouter.launchAndBuy(
            _params("GGG"), launchConfigId, quoteBrand, new address[](0), 0, 1, _deadline()
        );
        vm.stopPrank();
    }

    function test_launchAndBuy_forwardsTheSnipeTaxExemptions() public {
        address[] memory exemptions = new address[](1);
        exemptions[0] = stranger;

        (, address curve,) = _launchPayingQuote(payer, "HHH", QUOTE_IN, 0, exemptions);

        assertEq(
            LaunchCurve(curve).currentSnipeTaxBps(stranger), 0, "the bundled address is exempt"
        );
        assertGt(
            LaunchCurve(curve).currentSnipeTaxBps(trader), 0, "an undeclared sniper still pays"
        );
    }

    // ─── The three doors, trading a live curve ───────────────────────────

    function test_everyBuyDoorPaysTheSameForTheSameQuote() public {
        (address t1, address c1,) = _launchPayingQuote(payer, "AAA", 0, 0);
        (address t2, address c2,) = _launchPayingQuote(payer, "BBB", 0, 0);
        (address t3, address c3,) = _launchPayingQuote(payer, "CCC", 0, 0);
        _warpPastSnipeWindow();

        uint256 out1 = _buyWithQuote(trader, t1, QUOTE_IN, 0);
        uint256 out2 = _buyWithUsdg(trader, t2, QUOTE_IN, 0);
        uint256 out3 = _buyWithAltBrand(trader, t3, QUOTE_IN, 0);

        assertGt(out1, 0);
        assertEq(out2, out1, "the reserve asset door is the same buy");
        assertEq(out3, out1, "the other brand's door is the same buy");
        assertEq(IERC20(t1).balanceOf(trader), out1, "the buyer is paid, not the router");
        assertEq(IERC20(t2).balanceOf(trader), out2);
        assertEq(IERC20(t3).balanceOf(trader), out3);
        assertEq(IERC20(quoteBrand).balanceOf(c1), QUOTE_IN, "the whole input reached the curve");
        assertEq(IERC20(quoteBrand).balanceOf(c2), QUOTE_IN);
        assertEq(IERC20(quoteBrand).balanceOf(c3), QUOTE_IN);

        _assertRouterEmpty(t1, c1);
        _assertRouterEmpty(t2, c2);
        _assertRouterEmpty(t3, c3);
    }

    function test_everySellDoorPaysTheSameForTheSameTokens() public {
        (address t1, address c1, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        (address t2, address c2,) = _launchWithPosition("BBB", trader, QUOTE_IN);
        (address t3, address c3,) = _launchWithPosition("CCC", trader, QUOTE_IN);

        uint256 tokensIn = held / 2;
        _approveToken(trader, t1, tokensIn);
        _approveToken(trader, t2, tokensIn);
        _approveToken(trader, t3, tokensIn);

        vm.startPrank(trader);
        uint256 quoteOut = launchRouter.sell(t1, tokensIn, 0, _deadline());
        uint256 assetOut = launchRouter.sellForReserveAsset(t2, tokensIn, 0, _deadline());
        uint256 brandOut = launchRouter.sellForBrand(altBrand, t3, tokensIn, 0, _deadline());
        vm.stopPrank();

        assertGt(quoteOut, 0);
        assertEq(assetOut, quoteOut, "redeeming out is 1:1 with keeping the brand");
        assertEq(brandOut, quoteOut, "so is crossing into another brand");

        // Each door landed in its own currency, in the seller's own wallet.
        assertEq(IERC20(quoteBrand).balanceOf(trader), quoteOut, "quote brand door");
        assertEq(usdg.balanceOf(trader), assetOut, "reserve asset door");
        assertEq(IERC20(altBrand).balanceOf(trader), brandOut, "other brand door");

        _assertRouterEmpty(t1, c1);
        _assertRouterEmpty(t2, c2);
        _assertRouterEmpty(t3, c3);
    }

    /// @dev `sellForBrand` is also the door back into the curve's own brand, and must not
    ///      route a 1:1 swap into itself to get there.
    function test_sellForBrand_acceptsTheCurvesOwnBrand() public {
        (address token, address curve, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);

        _approveToken(trader, token, held);
        vm.prank(trader);
        uint256 out = launchRouter.sellForBrand(quoteBrand, token, held, 0, _deadline());

        assertGt(out, 0);
        assertEq(IERC20(quoteBrand).balanceOf(trader), out);
        _assertRouterEmpty(token, curve);
    }

    /// @dev The reserve may charge for an exit, and it truncates rather than reverting, so the
    ///      number this returns has to be the reserve's payout and not the quote it burned.
    function test_sellForReserveAsset_propagatesTheReservesPayout() public {
        vm.prank(owner);
        reserve.setRedemptionFee(50); // 0.50%, announced
        vm.warp(reserve.redemptionFeeEffectiveAt()); // and live once its hour is served
        reserve.commitRedemptionFee();

        (address token, address curve, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        (uint256 quoteOut,,) = launchRouter.previewSell(token, held);

        _approveToken(trader, token, held);
        vm.prank(trader);
        uint256 assetOut = launchRouter.sellForReserveAsset(token, held, 0, _deadline());

        assertEq(assetOut, quoteOut - quoteOut * 50 / 10_000, "the payout, less the exit fee");
        assertLt(assetOut, quoteOut, "and strictly less than what was burned");
        assertEq(usdg.balanceOf(trader), assetOut, "what the caller was told is what arrived");
        _assertRouterEmpty(token, curve);
    }

    // ─── Slippage bounds ─────────────────────────────────────────────────

    function test_previewsAreExactEnoughToBeTheMinOut() public {
        (address token, address curve,) = _launchPayingQuote(payer, "AAA", 0, 0);
        _warpPastSnipeWindow();

        (uint256 expectedTokens,,) = launchRouter.previewBuy(token, QUOTE_IN, trader);
        assertGt(expectedTokens, 0);
        uint256 tokensOut = _buyWithUsdg(trader, token, QUOTE_IN, expectedTokens);
        assertEq(tokensOut, expectedTokens, "the preview was the trade");

        (uint256 expectedQuote,,) = launchRouter.previewSell(token, tokensOut);
        _approveToken(trader, token, tokensOut);
        vm.prank(trader);
        uint256 quoteOut = launchRouter.sell(token, tokensOut, expectedQuote, _deadline());
        assertEq(quoteOut, expectedQuote);
        _assertRouterEmpty(token, curve);
    }

    function test_buyDoorsHonourMinTokensOut() public {
        (address t1,,) = _launchPayingQuote(payer, "AAA", 0, 0);
        (address t2,,) = _launchPayingQuote(payer, "BBB", 0, 0);
        (address t3,,) = _launchPayingQuote(payer, "CCC", 0, 0);
        _warpPastSnipeWindow();

        (uint256 expected,,) = launchRouter.previewBuy(t1, QUOTE_IN, trader);
        uint256 tooMuch = expected + 1;

        _fundBrand(trader, quoteBrand, QUOTE_IN);
        _fundBrand(trader, altBrand, QUOTE_IN);
        usdg.mint(trader, QUOTE_IN);

        vm.startPrank(trader);
        IERC20(quoteBrand).approve(address(launchRouter), QUOTE_IN);
        IERC20(altBrand).approve(address(launchRouter), QUOTE_IN);
        usdg.approve(address(launchRouter), QUOTE_IN);

        // The bound is reported against the fill the curve would actually have given, which
        // is the preview above — identical on all three doors, because they are one trade.
        bytes memory slipped =
            abi.encodeWithSelector(LaunchCurve.SlippageExceeded.selector, expected, tooMuch);

        vm.expectRevert(slipped);
        launchRouter.buy(t1, QUOTE_IN, tooMuch, _deadline());
        vm.expectRevert(slipped);
        launchRouter.buyWithReserveAsset(t2, QUOTE_IN, tooMuch, _deadline());
        vm.expectRevert(slipped);
        launchRouter.buyWithBrand(altBrand, t3, QUOTE_IN, tooMuch, _deadline());
        vm.stopPrank();
    }

    function test_launchAndBuy_honoursMinTokensOut() public {
        // More than the curve holds, let alone sells: a bound it can never clear.
        uint256 tooMuch = LAUNCH_SUPPLY;
        _fundBrand(payer, quoteBrand, LAUNCH_FEE + QUOTE_IN);
        vm.startPrank(payer);
        IERC20(quoteBrand).approve(address(launchRouter), LAUNCH_FEE + QUOTE_IN);
        // The curve does not exist until this call, so the fill it would have given cannot be
        // quoted in advance; the selector is what identifies the rejection.
        vm.expectPartialRevert(LaunchCurve.SlippageExceeded.selector);
        launchRouter.launchAndBuy(
            _params("AAA"),
            launchConfigId,
            quoteBrand,
            new address[](0),
            QUOTE_IN,
            tooMuch,
            _deadline()
        );
        vm.stopPrank();
    }

    function test_sellDoorsHonourTheirMinOut() public {
        (address t1,, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        (address t2,,) = _launchWithPosition("BBB", trader, QUOTE_IN);
        (address t3,,) = _launchWithPosition("CCC", trader, QUOTE_IN);

        uint256 tokensIn = held / 2;
        (uint256 expected,,) = launchRouter.previewSell(t1, tokensIn);
        _approveToken(trader, t1, tokensIn);
        _approveToken(trader, t2, tokensIn);
        _approveToken(trader, t3, tokensIn);

        vm.startPrank(trader);
        // The curve pays the seller directly, so its own bound is the one that binds.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchCurve.SlippageExceeded.selector, expected, expected + 1)
        );
        launchRouter.sell(t1, tokensIn, expected + 1, _deadline());
        // The reserve legs settle after the curve, so the bound is on what finally arrives.
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.InsufficientPayout.selector, expected, expected + 1
            )
        );
        launchRouter.sellForReserveAsset(t2, tokensIn, expected + 1, _deadline());
        vm.expectRevert(
            abi.encodeWithSelector(LaunchRouter.InsufficientOutput.selector, expected, expected + 1)
        );
        launchRouter.sellForBrand(altBrand, t3, tokensIn, expected + 1, _deadline());
        vm.stopPrank();
    }

    // ─── Deadlines ───────────────────────────────────────────────────────

    function test_everyEntryPointRefusesAStaleTransaction() public {
        (address token,, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        uint256 stale = vm.getBlockTimestamp() - 1;
        LaunchFactory.TokenParams memory p = _params("BBB");
        address[] memory none = new address[](0);

        vm.startPrank(trader);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.launchAndBuy(p, launchConfigId, quoteBrand, none, QUOTE_IN, 0, stale);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.launchAndBuyWithReserveAsset(
            p, launchConfigId, quoteBrand, none, QUOTE_IN, 0, stale
        );
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.launchAndBuyWithBrand(
            altBrand, p, launchConfigId, quoteBrand, none, QUOTE_IN, 0, stale
        );

        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.buy(token, QUOTE_IN, 0, stale);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.buyWithReserveAsset(token, QUOTE_IN, 0, stale);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.buyWithBrand(altBrand, token, QUOTE_IN, 0, stale);

        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.sell(token, held, 0, stale);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.sellForReserveAsset(token, held, 0, stale);
        vm.expectRevert(LaunchRouter.DeadlineExpired.selector);
        launchRouter.sellForBrand(altBrand, token, held, 0, stale);
        vm.stopPrank();
    }

    // ─── Graduation from inside a routed buy ─────────────────────────────

    function test_routedBuyThatCrossesTheThresholdGraduatesAndRefunds() public {
        (address token, address curve,) = _launchPayingQuote(payer, "AAA", 0, 0);
        _warpPastSnipeWindow();

        uint256 offered = GRADUATION_THRESHOLD * 2;
        uint256 tokensOut = _buyWithUsdg(trader, token, offered, 0);

        assertGt(tokensOut, 0, "the crossing buy still filled");
        assertTrue(LaunchCurve(curve).graduated(), "and graduated the curve on the way through");

        ILaunchFactory.LaunchedToken memory rec = launchFactory.getLaunchedToken(token);
        assertEq(uint8(rec.phase), uint8(GraduationPhase.Swept), "phase one ran inside the buy");
        assertEq(IERC20(quoteBrand).balanceOf(curve), 0, "the curve handed everything over");

        // The curve clamps the fill to the allocation that is left and refunds the rest to its
        // caller — this router — which sends it on as the quote brand rather than redeeming a
        // position the buyer never chose to close.
        uint256 refund = IERC20(quoteBrand).balanceOf(trader);
        assertGt(refund, 0, "the unspent offer came home");
        assertEq(usdg.balanceOf(trader), 0, "and came home as the brand, not as USDG");
        assertEq(
            refund + rec.sweptQuote + IERC20(quoteBrand).balanceOf(address(feeEscrow)),
            offered,
            "every unit minted for this buy is accounted for"
        );
        _assertRouterEmpty(token, curve);
    }

    // ─── The forwarder gate ──────────────────────────────────────────────

    function test_launchTokenFor_isOnlyReachableThroughThisRouter() public {
        assertEq(launchFactory.launchForwarder(), address(launchRouter), "the router is the gate");

        _fundBrand(stranger, quoteBrand, LAUNCH_FEE);
        vm.startPrank(stranger);
        IERC20(quoteBrand).approve(address(launchFactory), LAUNCH_FEE);
        vm.expectRevert(LaunchFactory.NotLaunchForwarder.selector);
        launchFactory.launchTokenFor(
            _params("AAA"), launchConfigId, quoteBrand, new address[](0), stranger
        );
        vm.stopPrank();
    }

    // ─── What it refuses to route ────────────────────────────────────────

    function test_refusesTokensAndBrandsItCannotRoute() public {
        address notALaunch = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchRouter.UnknownLaunchToken.selector, notALaunch)
        );
        launchRouter.buy(notALaunch, QUOTE_IN, 0, _deadline());

        vm.expectRevert(
            abi.encodeWithSelector(LaunchRouter.UnknownLaunchToken.selector, notALaunch)
        );
        launchRouter.previewSell(notALaunch, 1);

        // A brand whose issuer never opted into sharing its float yield could never be
        // launched in, and the factory says so before the router pulls anything.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.PairTokenFloatShareUnavailable.selector, altBrand)
        );
        launchRouter.launchAndBuy(
            _params("AAA"), launchConfigId, altBrand, new address[](0), QUOTE_IN, 0, _deadline()
        );

        // And a brand of a reserve the owner has closed to new launches: launchable in
        // principle, refused today, again before anything is pulled.
        vm.prank(owner);
        launchFactory.setReserveApproved(address(reserve), false);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchRouter.PairTokenNotApproved.selector, quoteBrand)
        );
        launchRouter.launchAndBuy(
            _params("AAA"), launchConfigId, quoteBrand, new address[](0), QUOTE_IN, 0, _deadline()
        );
        vm.prank(owner);
        launchFactory.setReserveApproved(address(reserve), true);

        (address token,,) = _launchPayingQuote(payer, "BBB", 0, 0);
        _warpPastSnipeWindow();
        // The reserve asset is not a brand of the reserve, so it has no 1:1 swap into one.
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchRouter.BrandNotInLaunchReserve.selector, address(usdg), address(reserve)
            )
        );
        launchRouter.buyWithBrand(address(usdg), token, QUOTE_IN, 0, _deadline());
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchRouter.BrandNotInLaunchReserve.selector, address(usdg), address(reserve)
            )
        );
        launchRouter.sellForBrand(address(usdg), token, 1, 0, _deadline());
    }

    function test_refusesZeroAmountTrades() public {
        (address token,,) = _launchPayingQuote(payer, "AAA", 0, 0);
        _warpPastSnipeWindow();

        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.buy(token, 0, 0, _deadline());
        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.buyWithReserveAsset(token, 0, 0, _deadline());
        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.buyWithBrand(altBrand, token, 0, 0, _deadline());
        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.sell(token, 0, 0, _deadline());
        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.sellForReserveAsset(token, 0, 0, _deadline());
        vm.expectRevert(LaunchRouter.ZeroAmount.selector);
        launchRouter.sellForBrand(altBrand, token, 0, 0, _deadline());
    }

    function test_constructorRefusesAZeroFactory() public {
        vm.expectRevert(LaunchRouter.ZeroAddress.selector);
        new LaunchRouter(LaunchFactory(address(0)));
    }
}
