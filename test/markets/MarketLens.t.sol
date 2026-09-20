// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {MarketLens} from "../../src/markets/MarketLens.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev A yield source whose backing can be moved off-chain, which is `SUSDaiYieldSource`'s
///      shape: `balanceOf` books the whole position, `withdraw` pays only what is local, and
///      `withdrawable` says how much that is.
contract BufferedYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public booked;
    address public away = address(0xA3A7);

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        booked[msg.sender] += amount;
    }

    /// @dev Move `amount` out of reach, as a bridge leg would, without changing what is owed.
    function strand(address asset, uint256 amount) external {
        IERC20(asset).safeTransfer(away, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 local = IERC20(asset).balanceOf(address(this));
        uint256 paid = amount < local ? amount : local;
        if (paid > booked[msg.sender]) paid = booked[msg.sender];
        booked[msg.sender] -= paid;
        IERC20(asset).safeTransfer(to, paid);
        return paid;
    }

    function balanceOf(address) external view returns (uint256) {
        return booked[msg.sender];
    }

    function totalAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + IERC20(asset).balanceOf(away);
    }

    function withdrawable(address asset, address consumer) external view returns (uint256) {
        uint256 local = IERC20(asset).balanceOf(address(this));
        return local < booked[consumer] ? local : booked[consumer];
    }
}

/// @dev The other adapter shape, and the one that makes the lens's `-1` load-bearing: a
///      lending market that REVERTS rather than clamping when asked for more than it can
///      release. `MorphoBlueYieldSource` behaves this way, because
///      the venue underneath them does.
contract RevertingYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    error InsufficientLiquidity(uint256 requested, uint256 available);

    mapping(address => uint256) public booked;
    /// @notice The share of the position that is lent out and cannot be recalled this block.
    uint256 public lent;

    function setLent(uint256 amount) external {
        lent = amount;
    }

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        booked[msg.sender] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 free = _free(asset, msg.sender);
        if (amount > free) revert InsufficientLiquidity(amount, free);
        booked[msg.sender] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function balanceOf(address) external view returns (uint256) {
        return booked[msg.sender];
    }

    function totalAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdrawable(address asset, address consumer) external view returns (uint256) {
        return _free(asset, consumer);
    }

    function _free(address asset, address consumer) private view returns (uint256) {
        uint256 owed = booked[consumer];
        uint256 unlent = IERC20(asset).balanceOf(address(this));
        unlent = unlent > lent ? unlent - lent : 0;
        return owed < unlent ? owed : unlent;
    }
}

/// @dev The factory identity-checks its PositionManager's `poolManager()` at construction and
///      never calls it again on the paths this suite exercises.
contract InertPositionManager {
    address public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = _poolManager;
    }
}

/// @title MarketLensTest
/// @notice The lens is judged against what actually settles: every quote here is compared to
///         the router's real fill of the same trade, on the same block, so a lens that drifted
///         from the hook's skim, the pool's LP fee, the reserve's redemption fee or the
///         reserve's liquidity would fail against the number a trader receives.
contract MarketLensTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 5_000;
    int24 constant TICK_SPACING = 50;
    uint24 constant PROTOCOL_FEE_PIPS = 5_000; // 0.50%, the shipped default
    uint16 constant REDEMPTION_FEE_BPS = 20;

    PoolManager manager;
    ProtocolFeeHook hook;
    PoolModifyLiquidityTest lpRouter;

    MockUSDC usdg;
    BufferedYieldSource yieldSource;
    SharedReservePool reserve;
    AssetMarketFactory factory;
    MarketRouter router;
    MarketLens lens;

    MockAsset asset;
    uint256 marketId;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address trader = address(0x7AAD);

    uint256 constant SEED_USDG = 500_000e6;
    uint256 constant SEED_ASSET = 500_000e18;

    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x1E45 << 144)
            ),
            IPoolManager(address(manager)),
            owner
        );

        usdg = new MockUSDC();
        yieldSource = new BufferedYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        // The lens never touches the periphery, so the factory and router get inert stand-ins.
        address posm = address(new InertPositionManager(address(manager)));
        factory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(posm),
            protocolTreasury,
            address(0),
            0,
            owner
        );
        vm.startPrank(owner);
        hook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        reserve.setRedemptionFee(REDEMPTION_FEE_BPS);
        vm.stopPrank();
        // The reserve fee above is an increase, so it is announced rather than applied. Serve
        // its hour here, before anything is quoted: every lens test below asserts against a
        // fee that is already live.
        vm.warp(reserve.redemptionFeeEffectiveAt());
        reserve.commitRedemptionFee();

        router = _deployRouter(
            reserve, factory, IPositionManagerV4(posm), IPermit2(address(0xBEEF)), owner
        );
        lens = new MarketLens(factory);

        asset = new MockAsset();
        _approveAsset(
            factory,
            address(asset),
            FEE,
            1e18,
            FIXTURE_MIN_OBSERVATION_CARDINALITY,
            "Cashcat Dollar",
            "catUSD"
        );
        (marketId,,,,) = factory.createMarket(address(asset), address(0));
        _seedDirect(marketId, SEED_USDG, SEED_ASSET);
    }

    // ─── Quotes agree with fills ─────────────────────────────────────────

    function test_quoteBuyIsExactlyWhatBuyWithUsdgDelivers() public {
        uint256 usdgIn = 1_000e6;
        (uint256 quoted,) = lens.quoteBuy(marketId, usdgIn);

        _fundTraderUsdg(usdgIn);
        vm.prank(trader);
        uint256 filled = router.buyWithUsdg(marketId, usdgIn, quoted, trader, _deadline());

        assertEq(filled, quoted, "the quote is the fill, skim and LP fee included");
        // The skim is in the number: a quote off the bare curve would sit above this.
        uint256 curveOnly = 1_000e18 - 1_000e18 * uint256(PROTOCOL_FEE_PIPS) / 1e6;
        assertLt(quoted, curveOnly, "hook skim is priced");
    }

    function test_quoteSellIsExactlyWhatSellForUsdgDelivers() public {
        uint256 assetIn = 1_000e18;
        (uint256 usdgQuoted, uint256 brandQuoted,) = lens.quoteSell(marketId, assetIn);

        _fundTraderAsset(assetIn);
        vm.prank(trader);
        uint256 filled = router.sellForUsdg(marketId, assetIn, usdgQuoted, trader, _deadline());

        assertEq(filled, usdgQuoted, "the quote is the fill, redemption fee included");
        assertEq(
            usdgQuoted,
            brandQuoted - brandQuoted * REDEMPTION_FEE_BPS / 10_000,
            "the reserve leg is par less the fee"
        );
    }

    /// @notice The reason this lens simulates the swap instead of calling `V4Quoter`: an
    ///         aggregator samples venues from inside its own call, which is a `STATICCALL`.
    ///         A quoter that unlocks the `PoolManager` cannot answer one. Asked through a
    ///         low-level static call so the EVM enforces it rather than solc's `view`.
    function test_quotesAnswerInsideAStaticcall() public view {
        (bool buyOk, bytes memory buyData) =
            address(lens).staticcall(abi.encodeCall(MarketLens.quoteBuy, (marketId, 1_000e6)));
        assertTrue(buyOk, "quoteBuy must survive STATICCALL");
        (uint256 assetOut,) = abi.decode(buyData, (uint256, uint256));
        assertGt(assetOut, 0, "and answer with a number");

        (bool sellOk, bytes memory sellData) =
            address(lens).staticcall(abi.encodeCall(MarketLens.quoteSell, (marketId, 1_000e18)));
        assertTrue(sellOk, "quoteSell must survive STATICCALL");
        (uint256 usdgOut,,) = abi.decode(sellData, (uint256, uint256, uint256));
        assertGt(usdgOut, 0, "and answer with a number");

        (bool outOk,) = address(lens)
            .staticcall(abi.encodeCall(MarketLens.quoteBuyExactOut, (marketId, 100e18)));
        assertTrue(outOk, "quoteBuyExactOut must survive STATICCALL");
    }

    /// @notice The simulated swap must walk the tick bitmap the way the pool does, not assume
    ///         one full-range position. Today's markets are single-range, so a closed-form
    ///         constant-product quote would pass every other test in this file and then be
    ///         silently wrong the day someone adds a concentrated position. This seeds one and
    ///         buys through it.
    function test_quoteIsTheFillWhenTheSwapCrossesInitialisedTicks() public {
        _seedNarrowBand(marketId, 20_000e6, 20_000e18);

        uint256 usdgIn = 30_000e6;
        (uint256 quoted, uint256 gasEstimate) = lens.quoteBuy(marketId, usdgIn);

        _fundTraderUsdg(usdgIn);
        vm.prank(trader);
        uint256 filled = router.buyWithUsdg(marketId, usdgIn, quoted, trader, _deadline());

        assertEq(filled, quoted, "the quote is the fill across a tick boundary");
        assertGt(gasEstimate, 130_000, "a crossed tick shows up in the gas estimate");
    }

    /// @notice The exact-out inversion has to survive tick crossing too: it quotes in the
    ///         opposite mode from the one it settles in, so a boundary the two modes reach at
    ///         different points is exactly where it would break.
    function test_quoteBuyExactOutSurvivesATickBoundary() public {
        _seedNarrowBand(marketId, 20_000e6, 20_000e18);

        uint256 want = 25_000e18;
        (uint256 usdgIn,) = lens.quoteBuyExactOut(marketId, want);

        _fundTraderUsdg(usdgIn);
        vm.prank(trader);
        uint256 filled = router.buyWithUsdg(marketId, usdgIn, want, trader, _deadline());

        assertGe(filled, want, "the least input still clears the target");
    }

    /// @notice A reserve that cannot pay the redemption is a refusal, not a discount. The
    ///         brand leg is burned whole either way, so quoting the reduced figure would have
    ///         a caller set it as their minimum and lose the difference permanently.
    function test_quoteSellRefusesASizeTheReserveCannotPayInFull() public {
        uint256 assetIn = 1_000e18;
        (uint256 whole, uint256 brandOut,) = lens.quoteSell(marketId, assetIn);

        // Bridge almost everything away: fully backed on paper, half of it reachable.
        uint256 keep = whole / 2;
        yieldSource.strand(address(usdg), usdg.balanceOf(address(yieldSource)) - keep);

        uint256 available = lens.redeemableAssets(reserve);
        assertEq(available, keep - 1, "idle plus the adapter, less the pool's recall pad");
        vm.expectRevert(
            abi.encodeWithSelector(MarketLens.RedeemCapacityExceeded.selector, whole, available)
        );
        lens.quoteSell(marketId, assetIn);

        // And the router refuses it too rather than burning brand it cannot be paid for: the
        // reserve's own guard reverts, so the seller keeps the asset and the brand is not lost.
        _fundTraderAsset(assetIn);
        vm.prank(trader);
        vm.expectPartialRevert(SharedReservePool.InsufficientPayout.selector);
        router.sellForUsdg(marketId, assetIn, whole, trader, _deadline());

        // A size that does fit settles, through the same path.
        (uint256 fits, uint256 brandNeeded,) = lens.quoteSellExactOut(marketId, available);
        assertLt(brandNeeded, brandOut, "a smaller brand leg, sized to what the reserve holds");
        _fundTraderAsset(fits);
        vm.prank(trader);
        assertGe(
            router.sellForUsdg(marketId, fits, available, trader, _deadline()),
            available,
            "the fitted size clears"
        );
    }

    /// @notice `sellForUsdg` passes its minimum down to the reserve, so a short payout unwinds
    ///         the burn with the transaction instead of retiring brand nobody was paid for.
    function test_sellForUsdgNeverBurnsBrandTheReserveCannotPayFor() public {
        uint256 assetIn = 1_000e18;
        (uint256 quoted,,) = lens.quoteSell(marketId, assetIn);

        // One unit short of the quote: enough to prove the reserve, not the router, refuses.
        yieldSource.strand(address(usdg), usdg.balanceOf(address(yieldSource)) - (quoted - 1));

        _fundTraderAsset(assetIn);
        uint256 brandSupplyBefore = IERC20(_brandOf()).totalSupply();
        vm.prank(trader);
        vm.expectPartialRevert(SharedReservePool.InsufficientPayout.selector);
        router.sellForUsdg(marketId, assetIn, quoted, trader, _deadline());

        assertEq(IERC20(_brandOf()).totalSupply(), brandSupplyBefore, "no brand was retired");
        assertEq(asset.balanceOf(trader), assetIn, "and the seller still holds their asset");
    }

    // ─── The reserve's two caps ──────────────────────────────────────────

    function test_maxMintIsTheLiabilityCapHeadroomAndZeroWhilePaused() public {
        assertEq(lens.maxMint(reserve), type(uint256).max, "no cap means no bound");

        uint256 supply = reserve.totalPooledSupply();
        vm.prank(owner);
        reserve.setLiabilityCap(supply + 250e6);
        assertEq(lens.maxMint(reserve), 250e6, "headroom under the cap");

        vm.expectRevert(
            abi.encodeWithSelector(MarketLens.MintCapacityExceeded.selector, 251e6, 250e6)
        );
        lens.quoteBuy(marketId, 251e6);
        (uint256 inside,) = lens.quoteBuy(marketId, 250e6);
        assertGt(inside, 0, "a buy inside the headroom quotes");

        _pauseProtocol();
        assertEq(lens.maxMint(reserve), 0, "a paused reserve mints nothing");
        assertGt(lens.redeemableAssets(reserve), 0, "but still redeems");
    }

    /// @notice The reason `redeemableAssets` reports one unit below the arithmetic sum.
    ///         `SharedReservePool._recallIfNeeded` asks the adapter for `shortfall + 1` to
    ///         absorb share rounding, and a lending adapter reverts on the over-request rather
    ///         than clamping — so the exact ceiling is the one size that cannot settle.
    function test_redeemableAssetsLeavesRoomForThePoolsRecallPad() public {
        RevertingYieldSource lender = new RevertingYieldSource();
        SharedReservePool pool = _deployReservePool(address(usdg), address(lender), owner);
        (address brand,) = pool.registerBrand("Lent Dollar", "lentUSD", owner);

        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(pool), 1_000e6);
        pool.mint(brand, 1_000e6, address(this));
        lender.setLent(400e6); // 600 reachable, 400 lent out

        uint256 quoted = lens.redeemableAssets(pool);
        assertEq(quoted, 600e6 - 1, "the pad is held back");
        uint256 brandForQuoted = lens.brandForRedeem(pool, quoted);

        uint256 snap = vm.snapshotState();
        assertEq(
            pool.redeem(brand, brandForQuoted, address(this), quoted),
            quoted,
            "the quoted size settles"
        );
        vm.revertToState(snap);

        // Two units more asks the adapter for one more than it has, and it takes the whole
        // redemption down rather than paying short.
        vm.expectPartialRevert(RevertingYieldSource.InsufficientLiquidity.selector);
        pool.redeem(brand, brandForQuoted + 2, address(this));
    }

    // ─── Exact-output ────────────────────────────────────────────────────

    /// @notice The exact-out figure is sized for the exact-input path every settlement here
    ///         uses, so it is judged by the router's real fill — and by minimality, since one
    ///         unit less must fall short.
    function test_quoteBuyExactOutIsTheLeastInputThatBuysThatMuch() public {
        uint256 want = 1_000e18;
        (uint256 usdgIn,) = lens.quoteBuyExactOut(marketId, want);

        _fundTraderUsdg(usdgIn);
        vm.prank(trader);
        uint256 got = router.buyWithUsdg(marketId, usdgIn, want, trader, _deadline());
        assertGe(got, want, "the input clears the target through the real router");

        (uint256 oneLess,) = lens.quoteBuy(marketId, usdgIn - 1);
        assertLt(oneLess, want, "and one unit less would not");
    }

    function test_quoteSellExactOutIsEnoughToReceiveThatMuch() public {
        uint256 want = 1_000e6;
        (uint256 assetIn, uint256 brandNeeded,) = lens.quoteSellExactOut(marketId, want);

        _fundTraderAsset(assetIn);
        vm.prank(trader);
        uint256 got = router.sellForUsdg(marketId, assetIn, want, trader, _deadline());
        assertGe(got, want, "the input clears the target through the real router");
        assertGe(reserve.previewRedeem(brandNeeded), want, "the brand leg was sized to clear");
        // Minimality is asserted on the buy side, where one input unit is a whole USDG cent
        // and unambiguous; one wei of an 18-decimal asset does not move a 6-decimal output.
    }

    function test_quoteSellExactOutRefusesWhatTheReserveCannotPay() public {
        yieldSource.strand(address(usdg), usdg.balanceOf(address(yieldSource)) - 100e6);
        uint256 available = lens.redeemableAssets(reserve);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketLens.RedeemCapacityExceeded.selector, available + 1, available
            )
        );
        lens.quoteSellExactOut(marketId, available + 1);
    }

    /// @notice The inversion of `previewRedeem` must clear the target at every fee the reserve
    ///         may charge — a one-unit shortfall fails a settler's minimum — and must not burn
    ///         more brand than that takes.
    function testFuzz_brandForRedeemIsTheLeastThatClearsTheTarget(uint16 feeBps, uint96 target)
        public
    {
        feeBps = uint16(bound(feeBps, 0, 100));
        target = uint96(bound(target, 1, 1_000_000_000e6));
        vm.prank(owner);
        reserve.setRedemptionFee(feeBps);
        // Whichever direction the fuzzer moved it: a cut is live at once, a rise has to serve
        // `FEE_INCREASE_DELAY` first. The subject here is the inversion arithmetic at a LIVE
        // fee, so take whichever route lands on one.
        if (reserve.redemptionFeeEffectiveAt() != 0) {
            vm.warp(reserve.redemptionFeeEffectiveAt());
            reserve.commitRedemptionFee();
        }
        assertEq(reserve.redemptionFeeBps(), feeBps);
        // Liquidity is not what this test is about.
        usdg.mint(address(reserve), target);

        uint256 brand = lens.brandForRedeem(reserve, target);
        assertGe(reserve.previewRedeem(brand), target, "payout clears the target");
        assertLt(reserve.previewRedeem(brand - 1), target, "and is the least that does");
    }

    // ─── Discovery ───────────────────────────────────────────────────────

    function test_routeDescribesTheMarketAsTheChainSeesIt() public view {
        MarketLens.Route memory r = lens.route(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        assertEq(r.reservePool, address(reserve));
        assertEq(r.reserveAsset, address(usdg));
        assertEq(r.asset, address(asset));
        assertEq(r.brandToken, factory.market(marketId).brandToken);
        assertEq(PoolId.unwrap(r.poolKey.toId()), PoolId.unwrap(key.toId()));
        assertEq(r.protocolFeePips, PROTOCOL_FEE_PIPS);
        assertEq(r.redemptionFeeBps, REDEMPTION_FEE_BPS);
    }

    /// @dev `route` is the single read an aggregator builds a quote from, so it must report
    ///      the fee redemptions actually charge and never one the owner has merely announced.
    ///      If it reported the pending value the router would quote a worse price than the
    ///      chain would honour for the next hour; if the lens read the pending value only
    ///      after the commit, it would quote a better one. Both are wrong in the same place.
    function test_routeReportsTheLiveFeeWhileAnIncreaseIsPending() public {
        vm.prank(owner);
        reserve.setRedemptionFee(REDEMPTION_FEE_BPS + 50);
        uint64 effectiveAt = reserve.redemptionFeeEffectiveAt();

        assertEq(
            lens.route(marketId).redemptionFeeBps,
            REDEMPTION_FEE_BPS,
            "an announcement is not a fee"
        );

        vm.warp(effectiveAt);
        reserve.commitRedemptionFee();
        assertEq(lens.route(marketId).redemptionFeeBps, REDEMPTION_FEE_BPS + 50);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _seedDirect(uint256 id, uint256 usdgAmount, uint256 assetAmount) internal {
        AssetMarketFactory.Market memory m = factory.market(id);
        PoolKey memory key = factory.poolKeyOf(id);

        usdg.mint(address(this), usdgAmount);
        usdg.approve(address(reserve), usdgAmount);
        reserve.mint(m.brandToken, usdgAmount, address(this));
        asset.mint(address(this), assetAmount);

        IERC20(m.brandToken).approve(address(lpRouter), type(uint256).max);
        IERC20(m.asset).approve(address(lpRouter), type(uint256).max);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint256 amount0, uint256 amount1) =
            m.brandToken < m.asset ? (usdgAmount, assetAmount) : (assetAmount, usdgAmount);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev A second, concentrated position a few tick-spacings wide around the current
    ///      price, so a fill has initialised ticks to cross on its way out of the band.
    function _seedNarrowBand(uint256 id, uint256 usdgAmount, uint256 assetAmount) internal {
        AssetMarketFactory.Market memory m = factory.market(id);
        PoolKey memory key = factory.poolKeyOf(id);

        usdg.mint(address(this), usdgAmount);
        usdg.approve(address(reserve), usdgAmount);
        reserve.mint(m.brandToken, usdgAmount, address(this));
        asset.mint(address(this), assetAmount);

        IERC20(m.brandToken).approve(address(lpRouter), type(uint256).max);
        IERC20(m.asset).approve(address(lpRouter), type(uint256).max);

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        int24 centre = (tick / TICK_SPACING) * TICK_SPACING;
        int24 tickLower = centre - TICK_SPACING * 4;
        int24 tickUpper = centre + TICK_SPACING * 4;

        (uint256 amount0, uint256 amount1) =
            m.brandToken < m.asset ? (usdgAmount, assetAmount) : (assetAmount, usdgAmount);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _fundTraderUsdg(uint256 amount) internal {
        usdg.mint(trader, amount);
        vm.prank(trader);
        usdg.approve(address(router), amount);
    }

    function _fundTraderAsset(uint256 amount) internal {
        asset.mint(trader, amount);
        vm.prank(trader);
        asset.approve(address(router), amount);
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _brandOf() internal view returns (address) {
        return factory.market(marketId).brandToken;
    }
}
