// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {ProtocolStack} from "../../src/upgrade/ProtocolStack.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchDeployer} from "../../src/launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {LaunchRouter} from "../../src/launchpad/LaunchRouter.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {
    GraduationPhase,
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {HookSaltMiner} from "../../script/DeployAssetMarkets.s.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
// The ERC-721 half of the deployed `PositionManager`, already written out for the market
// suite's fork test. Imported rather than re-declared so there is one description of each
// live contract in the test tree.
import {IPositionsNftLike} from "../markets/LaunchJourneyV4Fork.t.sol";

/// @title LaunchRouterV4ForkTest
/// @notice **The nine doors, against the live chain.**
///
///         `test/launchpad/LaunchRouter.t.sol` already drives all nine of this router's entry
///         points, but it drives them against a `StandInPermit2` and a `StandInPositionManager`
///         written inside `MarketRouter.t.sol`, and against a mock USDG this suite's fixture
///         mints at will. That can only ever confirm that the router's arithmetic agrees with
///         our own model of a reserve. Whether the three doors still price identically when the
///         1:1 legs run through a `SharedReservePool` whose float is parked in real Morpho
///         Blue, whether `redeem` really hands back what it says it handed back when the payout
///         has to be recalled out of a live lending market, and whether a routed buy that
///         crosses the threshold can open a pool Uniswap's own deployed periphery accepts — all
///         three are only answerable here. The launchpad's own journey fork test deliberately
///         bypasses this router and calls `launchFactory.launchToken` directly, so before this
///         file nothing in the tree had ever executed `LaunchRouter` against a real chain.
///
///         **Real:** the v4 `PoolManager` singleton, Uniswap's `PositionManager`, canonical
///         Permit2, USDG, Morpho Blue (the reserve's yield source, and the chain's USDG whale).
///         **Ours, deployed into the fork:** the reserve stack, the fee hook at a *mined*
///         CREATE2 address through the chain's deterministic deployment proxy, the market
///         factory, the market router, the whole launchpad, and a `LaunchRouter` registered as
///         the factory's `launchForwarder` — without which every `launchAndBuy*` reverts
///         `NotLaunchForwarder`.
///
///         What it proves, in order: the three launch doors are one trade; a launch-only call
///         buys nothing and refuses a bound it cannot honour; the three buy doors and the three
///         sell doors round-trip and move the curve's real reserve by exactly the gross;
///         `sellForReserveAsset` returns the reserve's payout rather than the brand it burned;
///         `minTokensOut`, `minQuoteOut` and `deadline` all bind; a routed buy graduates into a
///         genuine Uniswap market that `MarketRouter` can then trade. Every path ends on the
///         same invariant: this router holds nothing and leaves no allowance standing.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state older than a few thousand blocks comes back as
///         `-32000: metadata is not found`, and every test then fails inside `setUp` with an
///         account-fetch error that says nothing about our contracts. Take the block from the
///         chain rather than from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-path "test/launchpad/LaunchRouterV4Fork.t.sol" --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract LaunchRouterV4ForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The live chain ──────────────────────────────────────────────────

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 constant POSM = IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;
    bytes32 constant USDE_MARKET_ID = MainnetAddresses.USDE_MARKET_ID;

    /// @dev The deterministic deployment proxy, which really is deployed on this chain.
    ///      `HookSaltMiner` mines against it, so the hook has to be created through it for the
    ///      mined address to be the address that appears.
    address constant CREATE2_DEPLOYER = HookSaltMiner.CREATE2_DEPLOYER;

    // ─── Shipped configuration (plan §10) ────────────────────────────────

    uint24 constant PROTOCOL_FEE_PIPS = 1_000; // 0.10% of every swap's input
    uint256 constant LAUNCH_SUPPLY = 1e27;
    uint256 constant CURVE_FEE_BPS = 100;
    uint24 constant POOL_FEE = 5_000;
    int24 constant POOL_TICK_SPACING = 50;
    uint256 constant PHANTOM_QUOTE = 3_236e6;
    uint256 constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 constant LAUNCH_FEE = 1e6;

    /// @dev The creator tax every launch here carries, so the fee legs the reserve doors have
    ///      to survive are nonzero on both sides of a trade.
    uint16 constant CREATOR_TAX_BPS = 100;

    /// @dev One trade size, used by every door comparison. Small against the threshold, so no
    ///      comparison test is ever clamped by the reserved allocation.
    uint256 constant QUOTE_IN = 250e6;

    // ─── Our stack, deployed into the fork ───────────────────────────────

    MorphoBlueYieldSource yieldSource;
    SharedReservePool reserve;
    ProtocolFeeHook feeHook;
    AssetMarketFactory marketFactory;
    MarketRouter marketRouter;

    LaunchFeeEscrow feeEscrow;
    LaunchLocker locker;
    LaunchGraduation graduation;
    LaunchDeployer launchDeployer;
    LaunchFactory launchFactory;
    LaunchRouter launchRouter;

    /// @dev The brand every launch here is quoted in.
    address quoteBrand;
    /// @dev A second brand of the same reserve, standing in for "some other market's brand" —
    ///      the currency `launchAndBuyWithBrand`, `buyWithBrand` and `sellForBrand` exist for.
    address altBrand;
    uint256 launchConfigId;

    // ─── The cast ────────────────────────────────────────────────────────

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address protocolFeeRecipient = address(0xFEE);
    address creatorFeeRecipient = address(0xC0FE);
    address quotePayer = address(0x9A1);
    address usdgPayer = address(0x9A2);
    address brandPayer = address(0x9A3);
    address trader = address(0x7AAD);
    address stranger = address(0x57A);

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, so the early return is what stops the body from
        // reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reserve = _deployReservePool(USDG, address(yieldSource), owner);

        feeHook = _deployMinedHook();

        marketFactory = _deployFactory(
            reserve,
            MANAGER,
            feeHook,
            POSM,
            protocolTreasury,
            address(0), // no canonical-equity reference: a launched token is never verified
            0, // the whole protocol cut of float yield stays with the market's LPs
            owner
        );

        vm.startPrank(owner);
        feeHook.setRegistrar(address(marketFactory));
        marketFactory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        marketRouter = _deployRouter(reserve, marketFactory, POSM, PERMIT2, owner);

        _deployLaunchpad();

        // The two brands of one reserve this suite trades between, registered the way any
        // community registers theirs. Only the quote brand carries launch economics.
        (quoteBrand,) = marketFactory.registerBrand("Launch Dollar", "launchUSD");
        (altBrand,) = marketFactory.registerBrand("Alt Dollar", "altUSD");
        vm.prank(owner);
        launchFactory.setPairTokenEconomics(
            quoteBrand,
            LaunchFactory.PairTokenEconomics({
                reserve: address(reserve),
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                launchFee: LAUNCH_FEE,
                decimals: 6,
                approved: true
            })
        );
    }

    // ══ 1 ══ The three launch doors are one trade ═════════════════════════

    /// @notice Three launches on identical terms, differing only in the currency the launcher
    ///         held, deliver the launcher exactly the same number of tokens.
    ///
    ///         This is the property that makes the three doors one trade rather than three
    ///         prices, and it is the whole reason they exist: a front end can offer "pay with
    ///         USDG" without quoting a different number from "pay with the brand you already
    ///         hold". Offline it is a statement about our mock reserve's arithmetic. Here the
    ///         middle door mints against real USDG into a real `SharedReservePool` that
    ///         immediately parks the float in real Morpho Blue, and the third door crosses two
    ///         brands of that reserve — so an equality that survives is a statement about the
    ///         reserve legs as they will actually run.
    function test_fork_theThreeLaunchDoorsBuyTheSameTokensForTheSameQuote() public {
        (address t1, address c1, uint256 out1) = _launchPayingQuote(quotePayer, "AAA", QUOTE_IN, 0);
        (address t2, address c2, uint256 out2) = _launchPayingUsdg(usdgPayer, "BBB", QUOTE_IN, 0);
        (address t3, address c3, uint256 out3) =
            _launchPayingAltBrand(brandPayer, "CCC", QUOTE_IN, 0);

        assertGt(out1, 0, "the opening buy bought something");
        assertEq(out2, out1, "minting real USDG into the quote brand is the same trade");
        assertEq(out3, out1, "crossing another brand of the reserve is the same trade");

        assertEq(IERC20(t1).balanceOf(quotePayer), out1, "the launcher holds the tokens");
        assertEq(IERC20(t2).balanceOf(usdgPayer), out2);
        assertEq(IERC20(t3).balanceOf(brandPayer), out3);

        // Every input was consumed: the fee to the protocol, the rest onto the curve.
        assertEq(IERC20(quoteBrand).balanceOf(quotePayer), 0, "nothing came back unspent");
        assertEq(IERC20(USDG).balanceOf(usdgPayer), 0);
        assertEq(IERC20(altBrand).balanceOf(brandPayer), 0);
        assertEq(IERC20(quoteBrand).balanceOf(c1), QUOTE_IN, "the curve holds the quote");
        assertEq(IERC20(quoteBrand).balanceOf(c2), QUOTE_IN);
        assertEq(IERC20(quoteBrand).balanceOf(c3), QUOTE_IN);
        assertEq(
            IERC20(quoteBrand).balanceOf(protocolFeeRecipient),
            3 * LAUNCH_FEE,
            "three launch fees, paid in the quote brand whatever was handed in"
        );

        // The launch is attributed to the account that sent the transaction, not to the
        // forwarder, so the CREATE2 pair a caller was quoted is the pair they get.
        ILaunchFactory.LaunchedToken memory rec = launchFactory.getLaunchedToken(t2);
        assertEq(rec.deployer, usdgPayer, "the launcher, not the forwarder");
        assertEq(rec.reserve, address(reserve), "and the real reserve is on the record");
        (address predicted,) = launchFactory.predictLaunchAddresses(
            _params("BBB"), launchConfigId, quoteBrand, usdgPayer
        );
        assertEq(predicted, t2, "the address the caller was quoted");

        _assertRouterEmpty(t1, c1);
        _assertRouterEmpty(t2, c2);
        _assertRouterEmpty(t3, c3);

        console.log("launch door 1 (quote brand)  tokens out, 18dp:", out1);
        console.log("launch door 2 (real USDG)    tokens out, 18dp:", out2);
        console.log("launch door 3 (other brand)  tokens out, 18dp:", out3);
    }

    // ══ 2 ══ Launch-only ══════════════════════════════════════════════════

    /// @notice `quoteIn == 0` launches and buys nothing, through either funding door — and a
    ///         nonzero `minTokensOut` on such a call is refused rather than ignored.
    ///
    ///         Silently ignoring the bound would turn a caller's slippage guard into a no-op on
    ///         exactly the call where they cannot see the fill, which is why it is an error and
    ///         not a tolerated no-op.
    function test_fork_launchOnlyBuysNothingAndRefusesAMinOutItCannotHonour() public {
        (address token, address curve, uint256 out) = _launchPayingQuote(quotePayer, "AAA", 0, 0);

        assertEq(out, 0, "nothing was bought");
        assertEq(IERC20(token).balanceOf(quotePayer), 0, "and nothing was delivered");
        assertEq(IERC20(token).balanceOf(curve), LAUNCH_SUPPLY, "the whole supply is on sale");
        assertEq(IERC20(quoteBrand).balanceOf(curve), 0, "no quote on the curve yet");
        assertEq(LaunchCurve(curve).realQuoteReserve(), 0, "so the real reserve is empty");
        assertEq(IERC20(quoteBrand).balanceOf(protocolFeeRecipient), LAUNCH_FEE);
        assertTrue(launchFactory.getLaunchedToken(token).exists, "the launch was recorded");
        _assertRouterEmpty(token, curve);

        // The same through the reserve door: the fee alone is minted out of real USDG.
        (address token2, address curve2, uint256 out2) = _launchPayingUsdg(usdgPayer, "BBB", 0, 0);
        assertEq(out2, 0);
        assertEq(IERC20(USDG).balanceOf(usdgPayer), 0, "the fee was taken in USDG");
        assertEq(IERC20(quoteBrand).balanceOf(protocolFeeRecipient), 2 * LAUNCH_FEE);
        _assertRouterEmpty(token2, curve2);

        // And a bound on a buy that was never asked for is an error. The parameters are built
        // before the expectation is armed: `_params` reads `previewLaunchEconomics` off the
        // factory, and an external call made while `expectRevert` is standing is the call the
        // expectation binds to.
        LaunchFactory.TokenParams memory p = _params("CCC");
        uint256 deadline = _deadline();
        address[] memory none = new address[](0);

        _fundBrand(stranger, quoteBrand, LAUNCH_FEE);
        vm.startPrank(stranger);
        IERC20(quoteBrand).approve(address(launchRouter), LAUNCH_FEE);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.InsufficientOutput.selector, 0, 1));
        launchRouter.launchAndBuy(p, launchConfigId, quoteBrand, none, 0, 1, deadline);
        vm.stopPrank();
    }

    // ══ 3 ══ Six trading doors, one round trip ════════════════════════════

    /// @notice Buy the same curve with each of the three currencies and sell back into each of
    ///         the three, and every door prices identically — with the curve's own real reserve
    ///         moving by exactly the net on the way in and the gross on the way out.
    ///
    ///         `realQuoteReserve` is the assertion that ties the router's return value to the
    ///         curve's books: it is `trackedQuote` less the fee and tax buckets, so a buy lifts
    ///         it by the spend net of both legs, and a sell drops it by the *gross* — the
    ///         seller's proceeds plus the fee and tax the curve kept back. A door that quietly
    ///         lost or gained a base unit somewhere in the 1:1 conversions would show up here
    ///         even where the seller's own balance happened to look right.
    function test_fork_theThreeBuyDoorsAndTheThreeSellDoorsRoundTrip() public {
        (address t1, address c1,) = _launchPayingQuote(quotePayer, "AAA", 0, 0);
        (address t2, address c2,) = _launchPayingQuote(quotePayer, "BBB", 0, 0);
        (address t3, address c3,) = _launchPayingQuote(quotePayer, "CCC", 0, 0);
        _warpPastSnipeWindow();

        // ── In. Three currencies, one price.
        (uint256 quoted, uint256 buyFee, uint256 buyTax) =
            launchRouter.previewBuy(t1, QUOTE_IN, trader);
        uint256 out1 = _buyWithQuote(trader, t1, QUOTE_IN, 0);
        uint256 out2 = _buyWithUsdg(trader, t2, QUOTE_IN, 0);
        uint256 out3 = _buyWithAltBrand(trader, t3, QUOTE_IN, 0);

        assertEq(out1, quoted, "the preview was the trade");
        assertEq(out2, out1, "the reserve-asset door is the same buy");
        assertEq(out3, out1, "the other brand's door is the same buy");
        assertEq(IERC20(t1).balanceOf(trader), out1, "the buyer is paid, not the router");
        assertEq(IERC20(t2).balanceOf(trader), out2);
        assertEq(IERC20(t3).balanceOf(trader), out3);

        // The whole input reached the curve, and its real reserve grew by the spend net of the
        // two fee legs the curve held back.
        uint256 netIn = QUOTE_IN - buyFee - buyTax;
        assertEq(IERC20(quoteBrand).balanceOf(c1), QUOTE_IN, "the whole input reached the curve");
        assertEq(LaunchCurve(c1).realQuoteReserve(), netIn, "quote door: real reserve is the net");
        assertEq(LaunchCurve(c2).realQuoteReserve(), netIn, "USDG door: identically");
        assertEq(LaunchCurve(c3).realQuoteReserve(), netIn, "brand door: identically");

        // ── Out. The same tokens, three currencies, one price.
        uint256 tokensIn = out1 / 2;
        (uint256 expected, uint256 sellFee, uint256 sellTax) =
            launchRouter.previewSell(t1, tokensIn);
        uint256 gross = expected + sellFee + sellTax;

        _approveToken(trader, t1, tokensIn);
        _approveToken(trader, t2, tokensIn);
        _approveToken(trader, t3, tokensIn);

        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        vm.startPrank(trader);
        uint256 quoteOut = launchRouter.sell(t1, tokensIn, 0, _deadline());
        uint256 assetOut = launchRouter.sellForReserveAsset(t2, tokensIn, 0, _deadline());
        uint256 brandOut = launchRouter.sellForBrand(altBrand, t3, tokensIn, 0, _deadline());
        vm.stopPrank();

        assertEq(quoteOut, expected, "the sell preview was the trade");
        assertEq(assetOut, quoteOut, "redeeming into real USDG is 1:1 with keeping the brand");
        assertEq(brandOut, quoteOut, "so is crossing into another brand of the reserve");

        // Each door landed in its own currency, in the seller's own wallet.
        assertEq(IERC20(quoteBrand).balanceOf(trader), quoteOut, "quote brand door");
        assertEq(IERC20(USDG).balanceOf(trader) - usdgBefore, assetOut, "reserve asset door");
        assertEq(IERC20(altBrand).balanceOf(trader), brandOut, "other brand door");

        // And every curve gave up the gross, not the net: proceeds plus both fee legs.
        assertEq(LaunchCurve(c1).realQuoteReserve(), netIn - gross, "quote door: gross came off");
        assertEq(LaunchCurve(c2).realQuoteReserve(), netIn - gross, "USDG door: identically");
        assertEq(LaunchCurve(c3).realQuoteReserve(), netIn - gross, "brand door: identically");

        _assertRouterEmpty(t1, c1);
        _assertRouterEmpty(t2, c2);
        _assertRouterEmpty(t3, c3);

        console.log("buy  doors: tokens out, 18dp:", out1);
        console.log("sell doors: quote out, 6dp:", quoteOut);
        console.log("sell doors: gross off the curve's real reserve, 6dp:", gross);
    }

    /// @notice `sellForReserveAsset` returns what the reserve actually paid out, not the brand
    ///         it burned to get it.
    ///
    ///         The distinction is invisible until a redemption settles short of par, which a
    ///         real reserve does for two separate reasons: a redemption fee the owner set, and
    ///         `_cappedByIdle` truncating to the idle balance when Morpho's own share-to-asset
    ///         floor division comes back a wei light of the recall. A router that returned the
    ///         amount burned would be over-reporting a seller's proceeds by exactly that
    ///         difference, and every integrator downstream would inherit the error. Proven the
    ///         only way it can be proven: against the wallet.
    function test_fork_sellForReserveAssetReturnsWhatTheReserveActuallyPaid() public {
        // A real exit charge, so par and payout are far enough apart to see. An increase is
        // announced first and live only once `FEE_INCREASE_DELAY` is served.
        vm.prank(owner);
        reserve.setRedemptionFee(50); // 0.50%
        vm.warp(reserve.redemptionFeeEffectiveAt());
        reserve.commitRedemptionFee();

        (address token, address curve, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        (uint256 burned,,) = launchRouter.previewSell(token, held);
        uint256 atPar = reserve.previewRedeem(burned);

        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        _approveToken(trader, token, held);
        vm.prank(trader);
        uint256 assetOut = launchRouter.sellForReserveAsset(token, held, 0, _deadline());

        assertEq(
            IERC20(USDG).balanceOf(trader) - usdgBefore,
            assetOut,
            "the returned value is the USDG that arrived"
        );
        assertLt(assetOut, burned, "and strictly less than the brand that was burned");
        // Par less the fee, allowing for the single wei a live lending market's rounding can
        // shave off a recall — which is the tolerance `_cappedByIdle` exists to express.
        assertLe(assetOut, atPar, "never more than par less the fee");
        assertApproxEqAbs(assetOut, atPar, 1, "and never more than a wei short of it");
        assertEq(
            burned - assetOut,
            burned * 50 / 10_000 + (atPar - assetOut),
            "the whole difference is the exit fee plus any recall dust"
        );

        _assertRouterEmpty(token, curve);

        console.log("brand burned, 6dp:", burned);
        console.log("USDG paid out by the real reserve, 6dp:", assetOut);
        console.log("recall dust below par-less-fee, 6dp:", atPar - assetOut);
    }

    // ══ 4 ══ Bounds bind ══════════════════════════════════════════════════

    /// @notice A bound one base unit past what the curve would give reverts on every buy door
    ///         and every sell door, with the rejection coming from whichever contract is in a
    ///         position to make it.
    ///
    ///         Three different errors, on purpose: `sell` is bounded by the curve, which pays
    ///         the seller directly; `sellForReserveAsset` is bounded by the reserve, whose
    ///         payout is produced after the curve has already settled; `sellForBrand` is
    ///         bounded by the router, because a 1:1 swap cannot fail its own bound. All three
    ///         are the amount the seller actually receives.
    function test_fork_everyBoundBindsOnARealChain() public {
        (address t1,, uint256 held) = _launchWithPosition("AAA", trader, QUOTE_IN);
        (address t2,,) = _launchWithPosition("BBB", trader, QUOTE_IN);
        (address t3,,) = _launchWithPosition("CCC", trader, QUOTE_IN);

        // ── Buying: the curve's own price bound, reported against the fill it would have
        //    given — which is identical on all three doors, because they are one trade.
        (uint256 expectedTokens,,) = launchRouter.previewBuy(t1, QUOTE_IN, trader);
        uint256 tooManyTokens = expectedTokens + 1;
        bytes memory slipped = abi.encodeWithSelector(
            LaunchCurve.SlippageExceeded.selector, expectedTokens, tooManyTokens
        );

        _fundBrand(trader, quoteBrand, QUOTE_IN);
        _fundBrand(trader, altBrand, QUOTE_IN);
        _fundUsdg(trader, QUOTE_IN);

        vm.startPrank(trader);
        IERC20(quoteBrand).approve(address(launchRouter), QUOTE_IN);
        IERC20(altBrand).approve(address(launchRouter), QUOTE_IN);
        IERC20(USDG).approve(address(launchRouter), QUOTE_IN);
        vm.expectRevert(slipped);
        launchRouter.buy(t1, QUOTE_IN, tooManyTokens, _deadline());
        vm.expectRevert(slipped);
        launchRouter.buyWithReserveAsset(t2, QUOTE_IN, tooManyTokens, _deadline());
        vm.expectRevert(slipped);
        launchRouter.buyWithBrand(altBrand, t3, QUOTE_IN, tooManyTokens, _deadline());
        vm.stopPrank();

        // ── Selling: one base unit more than the curve would pay.
        uint256 tokensIn = held / 2;
        (uint256 expectedQuote,,) = launchRouter.previewSell(t1, tokensIn);
        uint256 tooMuchQuote = expectedQuote + 1;
        _approveToken(trader, t1, tokensIn);
        _approveToken(trader, t2, tokensIn);
        _approveToken(trader, t3, tokensIn);

        vm.startPrank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchCurve.SlippageExceeded.selector, expectedQuote, tooMuchQuote
            )
        );
        launchRouter.sell(t1, tokensIn, tooMuchQuote, _deadline());
        // The reserve's own bound. Partial, because the payout it reports is the live idle
        // balance after a real recall out of Morpho — par, or a wei under it, and the test
        // has no business caring which.
        vm.expectPartialRevert(SharedReservePool.InsufficientPayout.selector);
        launchRouter.sellForReserveAsset(t2, tokensIn, tooMuchQuote, _deadline());
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchRouter.InsufficientOutput.selector, expectedQuote, tooMuchQuote
            )
        );
        launchRouter.sellForBrand(altBrand, t3, tokensIn, tooMuchQuote, _deadline());
        vm.stopPrank();
    }

    /// @notice A stale transaction is refused by all nine entry points.
    function test_fork_everyEntryPointRefusesAStaleTransaction() public {
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

    // ══ 5 ══ A routed buy that graduates into a real market ═══════════════

    /// @notice One routed buy crosses the threshold, graduates the launch inside its own
    ///         transaction, and what comes out the other side is a genuine Uniswap v4 market
    ///         that the shipping `MarketRouter` can trade.
    ///
    ///         This is the path with the most ways to be wrong and the fewest places to notice.
    ///         The buy is clamped by the curve to the allocation that is left, so the refund
    ///         lands on *this router* rather than on the buyer and has to be forwarded on —
    ///         as the quote brand, because a partial fill is the curve declining to trade and
    ///         not the holder choosing to leave the reserve. The curve then calls back into the
    ///         factory from inside the buy to sweep itself. Phase two mints a real position
    ///         through Uniswap's own deployed `PositionManager` over canonical Permit2 and
    ///         stakes it under the locker forever. Every one of those steps runs here against
    ///         the live singleton, with the buy initiated through the router rather than by
    ///         hand.
    function test_fork_aRoutedBuyGraduatesIntoARealUniswapMarket() public {
        (address token, address curve,) = _launchPayingQuote(quotePayer, "AAA", 0, 0);
        _warpPastSnipeWindow();

        uint256 offered = GRADUATION_THRESHOLD * 2;
        uint256 tokensOut = _buyWithUsdg(trader, token, offered, 0);

        assertGt(tokensOut, 0, "the crossing buy still filled");
        assertTrue(LaunchCurve(curve).graduated(), "and closed the curve on the way through");
        assertEq(LaunchCurve(curve).sellableTokens(), 0, "the allocation is exhausted");

        ILaunchFactory.LaunchedToken memory rec = launchFactory.getLaunchedToken(token);
        assertEq(uint8(rec.phase), uint8(GraduationPhase.Swept), "phase one ran inside the buy");
        assertGe(rec.sweptQuote, GRADUATION_THRESHOLD, "the threshold was reached");
        assertEq(IERC20(quoteBrand).balanceOf(curve), 0, "the curve handed everything over");

        // The clamped remainder came home as the brand, not as the USDG it was minted from,
        // and every base unit minted for this buy is accounted for.
        uint256 refund = IERC20(quoteBrand).balanceOf(trader);
        assertGt(refund, 0, "the unspent offer came home");
        assertEq(IERC20(USDG).balanceOf(trader), 0, "as the brand, not redeemed behind their back");
        assertEq(
            refund + rec.sweptQuote + IERC20(quoteBrand).balanceOf(address(feeEscrow)),
            offered,
            "every unit minted for this buy is accounted for"
        );
        _assertRouterEmpty(token, curve);

        // ── Phase two: the real pool, the real position.
        Graduated memory g = _graduateToMarket(token);
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        PoolKey memory key = marketFactory.poolKeyOf(marketId);

        (address expected0, address expected1) = g.unit < token ? (g.unit, token) : (token, g.unit);
        assertEq(Currency.unwrap(key.currency0), expected0, "currency0");
        assertEq(Currency.unwrap(key.currency1), expected1, "currency1");
        assertEq(key.fee, POOL_FEE, "the launch config's 0.50% tier");
        assertEq(key.tickSpacing, POOL_TICK_SPACING, "and the spacing that tier pins");
        assertEq(address(key.hooks), address(feeHook), "our mined fee hook is in the key");
        assertEq(PoolId.unwrap(key.toId()), g.poolId, "the id the event announced");

        (uint160 sqrtPriceX96,,, uint24 lpFee) = MANAGER.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "initialised inside the real PoolManager");
        assertEq(lpFee, POOL_FEE, "at the tier the launch configured");
        assertGt(MANAGER.getLiquidity(key.toId()), 0, "and it has depth");

        LpRewardDistributor dist = LpRewardDistributor(marketFactory.market(marketId).lpDistributor);
        assertEq(IPositionsNftLike(address(POSM)).name(), "Uniswap v4 Positions NFT");
        assertEq(
            IPositionsNftLike(address(POSM)).ownerOf(g.positionId),
            address(dist),
            "the distributor custodies Uniswap's own NFT"
        );
        assertEq(dist.stakerOf(g.positionId), address(locker), "and the locker is the staker");
        assertEq(
            MANAGER.getLiquidity(key.toId()),
            POSM.getPositionLiquidity(g.positionId),
            "the locked seed is the whole of the pool's depth"
        );
        assertEq(locker.lockedPosition(token).tokenId, g.positionId, "the lock names it");

        // ── And the market trades, through the router that ships with it.
        uint256 usdgIn = 100e6;
        _fundUsdg(stranger, usdgIn);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(marketRouter), usdgIn);
        uint256 bought = marketRouter.buyWithUsdg(
            marketId, usdgIn, 0, stranger, vm.getBlockTimestamp() + 1 hours
        );
        vm.stopPrank();

        assertGt(bought, 0, "a stranger bought the graduated token on the live pool");
        assertEq(IERC20(token).balanceOf(stranger), bought);
        (uint160 afterBuy,,,) = MANAGER.getSlot0(key.toId());
        assertTrue(afterBuy != sqrtPriceX96, "and the live pool moved for it");

        console.log("offered through the router, USDG 6dp:", offered);
        console.log("filled, tokens 18dp:", tokensOut);
        console.log("refunded as the quote brand, 6dp:", refund);
        console.log("pool id:");
        console.logBytes32(g.poolId);
        console.log("position id:", g.positionId);
        console.log("position liquidity:", POSM.getPositionLiquidity(g.positionId));
        console.log("MarketRouter buy: 100 USDG bought, tokens 18dp:", bought);
    }

    // ─── Deployment helpers ──────────────────────────────────────────────

    /// @dev The launchpad, in the order the addresses require and with the same one-shot wiring
    ///      `ProtocolStack.deployLaunchpad` performs, plus the one piece that file's fork test
    ///      never needed: a `LaunchRouter` named as the factory's `launchForwarder`. Without
    ///      that registration every `launchAndBuy*` here would revert `NotLaunchForwarder`.
    function _deployLaunchpad() internal {
        feeEscrow = new LaunchFeeEscrow();
        launchFactory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(new LaunchFactory()),
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            address(protocolGuard),
                            marketFactory,
                            POSM,
                            ILaunchFeeEscrow(address(feeEscrow))
                        )
                    )
                )
            )
        );
        locker = new LaunchLocker(owner, address(launchFactory));
        graduation = new LaunchGraduation(
            address(launchFactory),
            marketFactory,
            POSM,
            PERMIT2,
            ILaunchLocker(address(locker)),
            ILaunchFeeEscrow(address(feeEscrow))
        );
        launchDeployer = new LaunchDeployer(address(launchFactory));
        launchRouter = new LaunchRouter(launchFactory);

        vm.startPrank(owner);
        locker.setGraduation(address(graduation));
        launchFactory.setLaunchDeployer(launchDeployer);
        launchFactory.setGraduation(ILaunchGraduation(address(graduation)));
        launchFactory.setProtocolFeeRecipient(protocolFeeRecipient);
        launchFactory.setLaunchForwarder(address(launchRouter));
        launchFactory.setLaunchEnabled(true);
        launchConfigId = launchFactory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: LAUNCH_SUPPLY, curveFeeBps: CURVE_FEE_BPS, poolFee: POOL_FEE, enabled: true
            })
        );
        vm.stopPrank();

        assertEq(launchFactory.launchForwarder(), address(launchRouter), "the router is the gate");

        // The graduation module is the address the market factory lets through
        // `createLaunchMarket`, exactly as the deploy script registers it.
        _setLaunchpad(marketFactory, address(graduation));
    }

    /// @dev The hook, at a mined address, through the chain's deterministic deployment proxy —
    ///      the shipping path, run against the live chain's own deployer.
    function _deployMinedHook() internal returns (ProtocolFeeHook) {
        address impl = ProtocolStack.deployHookImplementation();
        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(
                impl,
                abi.encodeCall(ProtocolFeeHook.initialize, (MANAGER, owner, address(protocolGuard)))
            )
        );
        (address mined, bytes32 salt) =
            HookSaltMiner.mine(HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS, initCode);
        require(mined.code.length == 0, "mined hook address is occupied on the live chain");

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20, "CREATE2 deployment of the hook failed");
        address deployed = address(bytes20(ret));
        require(deployed == mined, "the hook did not land on its mined address");
        assertEq(
            uint160(deployed) & Hooks.ALL_HOOK_MASK,
            HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS,
            "the hook carries its own permission bits"
        );
        return ProtocolFeeHook(deployed);
    }

    // ─── Money ───────────────────────────────────────────────────────────

    /// @dev Morpho Blue custodies tens of millions of USDG on this chain, so a real transfer
    ///      out of it is a cheaper and more faithful funding route than writing balance slots.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    /// @dev Put `amount` of a brand in `who`'s wallet, minted 1:1 from real USDG at the reserve
    ///      the way a person would.
    function _fundBrand(address who, address brand, uint256 amount) internal {
        _fundUsdg(who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(reserve), amount);
        reserve.mint(brand, amount, who);
        vm.stopPrank();
    }

    // ─── Calling the router ──────────────────────────────────────────────

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1;
    }

    /// @dev Past the launch window, so a buyer who was never exempted still trades untaxed and
    ///      the door comparisons are not measuring a decaying snipe tax.
    function _warpPastSnipeWindow() internal {
        vm.warp(vm.getBlockTimestamp() + launchFactory.snipeTaxSeconds() + 1);
    }

    /// @dev Identical launch terms for every door: same config, same quote brand, same creator
    ///      tax, same pinned economics. Only the symbol, and so the salt, differs.
    function _params(string memory symbol)
        internal
        view
        returns (LaunchFactory.TokenParams memory)
    {
        return LaunchFactory.TokenParams({
            name: string.concat(symbol, " Coin"),
            symbol: symbol,
            logo: "ipfs://bafkreilaunchrouter",
            description: "One curve, three doors.",
            socials: LaunchToken.Socials({
                twitter: "https://x.com/launchrouter",
                telegram: "",
                discord: "",
                website: "",
                farcaster: ""
            }),
            creatorFeeRecipient: creatorFeeRecipient,
            creatorTaxBps: CREATOR_TAX_BPS,
            expectedEconomics: launchFactory.previewLaunchEconomics(launchConfigId, quoteBrand),
            salt: keccak256(bytes(symbol))
        });
    }

    function _launchPayingQuote(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut
    ) internal returns (address token, address curve, uint256 tokensOut) {
        uint256 total = LAUNCH_FEE + quoteIn;
        _fundBrand(who, quoteBrand, total);
        vm.startPrank(who);
        IERC20(quoteBrand).approve(address(launchRouter), total);
        (token, curve, tokensOut) = launchRouter.launchAndBuy(
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

    function _launchPayingUsdg(
        address who,
        string memory symbol,
        uint256 quoteIn,
        uint256 minTokensOut
    ) internal returns (address token, address curve, uint256 tokensOut) {
        uint256 total = LAUNCH_FEE + quoteIn;
        _fundUsdg(who, total);
        vm.startPrank(who);
        IERC20(USDG).approve(address(launchRouter), total);
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
        _fundUsdg(who, assetIn);
        vm.startPrank(who);
        IERC20(USDG).approve(address(launchRouter), assetIn);
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

    /// @dev A launch with `who` holding a position bought through the quote door, and the
    ///      launch window closed behind it.
    function _launchWithPosition(string memory symbol, address who, uint256 quoteIn)
        internal
        returns (address token, address curve, uint256 held)
    {
        (token, curve,) = _launchPayingQuote(quotePayer, symbol, 0, 0);
        _warpPastSnipeWindow();
        held = _buyWithQuote(who, token, quoteIn, 0);
    }

    /// @dev The invariant every path shares: nothing of anyone's is left here, and nothing here
    ///      is left spendable by anyone else. Both brands and real USDG are checked, not just
    ///      the currency the path happened to use, because a conversion leg that stranded the
    ///      wrong asset is exactly the failure this is looking for.
    function _assertRouterEmpty(address token, address curve) internal view {
        address r = address(launchRouter);
        assertEq(IERC20(USDG).balanceOf(r), 0, "router holds no reserve asset");
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
        assertEq(IERC20(USDG).allowance(r, address(reserve)), 0, "no standing mint allowance");
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    /// @dev `Result` as the `PoolGraduated` event carries it, minus the indexed market id.
    struct Graduated {
        address unit;
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked;
    }

    /// @dev Phase two, with the event captured: `graduateToMarket` returns nothing and the pool
    ///      id, position id and seed figures exist only in the log.
    function _graduateToMarket(address token) internal returns (Graduated memory g) {
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
}
