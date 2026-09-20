// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource, IMorphoBlue} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @dev Morpho Blue's `market()`/`position()` are plain storage reads: warping time alone does
///      not compound interest into them. The permissionless `accrueInterest` forces it, exactly
///      as the next real `supply`/`withdraw` against the market would.
interface IMorphoBlueAccrue {
    function idToMarketParams(bytes32 id) external view returns (IMorphoBlue.MarketParams memory);
    function accrueInterest(IMorphoBlue.MarketParams memory marketParams) external;
}

/// @title AssetMarketForkTest
/// @notice A native (Mode B) asset market end to end against a fork of live Robinhood Chain.
///
///         Everything that exists on that chain is the real deployed code here: USDG, the
///         Morpho Blue USDG/USDe market, and SPCX — Robinhood's tokenized SpaceX, an
///         issuer-controlled upgradeable beacon proxy. The mock suites prove the wiring in
///         isolation; this proves the same contracts work against the tokens and the lending
///         market they would actually be deployed into.
///
///         **The Uniswap venue is the one thing that is ours rather than theirs, and it has to
///         be.** Uniswap has not deployed v4 to this chain — `eth_getCode` on the canonical
///         PoolManager addresses returns nothing — so `DeployAssetMarkets.s.sol` deploys its
///         own singleton and its own mined `ProtocolFeeHook`, and so does this fixture. That is
///         not a test shortcut standing in for a real deployment; it IS the real deployment
///         shape, and the consequence carries into production unchanged: no external
///         aggregator routes to these pools. The live V3 SPCX/USDG pool below is still read,
///         but only as a price oracle for the starting price — never traded against.
///
///         The claim under test is the mechanism the whole design rests on: **the branded
///         stablecoin sitting in the market's own Uniswap pool is float, and it earns for the
///         brand.** `SharedReservePool` attributes yield by a brand's `outstanding` supply and
///         does not care who holds the tokens, so an AMM reserve is float exactly like a
///         wallet balance. If that were not true there would be no product.
///
///         Run with:
///         forge test --match-contract AssetMarketFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com
contract AssetMarketForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Robinhood Chain mainnet (verified on-chain, chain id 4663) ──────

    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;

    // ─── The assets ──────────────────────────────────────────────────────

    /// @notice Robinhood's tokenized SpaceX. The market this design was conceived for.
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// @notice The live SPCX/USDG 0.05% V3 pool. Used only as a source of SPCX to fund actors
    ///         and as a price reference — never traded against; our market has its own v4 pool
    ///         on our own singleton.
    address constant LIVE_SPCX_USDG_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;

    // ─── Market configuration ────────────────────────────────────────────

    /// @notice 0.3% tier, tick spacing 60. A long-tail asset is not a stable pair.
    uint24 constant FEE = 3000;

    /// @dev Zero, as shipped: every basis point of float yield is the LPs'.
    uint16 constant PROTOCOL_BPS = 0;

    uint256 constant SEED_USDG = 50_000e6;
    uint256 constant SEED_SPCX = 300e18;

    // ─── Actors and state ────────────────────────────────────────────────

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    PoolManager poolManager;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;

    address owner = address(0x0AD01);
    address operator = address(0x0FE);
    address protocolTreasury = address(0xF33);
    address alice = address(0xA11CE);

    uint256 marketId;
    address brandToken;
    bytes32 poolId;
    PoolKey poolKey;
    BrandFeeVault feeVault;
    LpRewardDistributor distributor;

    function setUp() public {
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // Same pattern as `AssetMarketV4ForkTest`; the early return is what keeps the rest of
        // this function from reverting against an empty chain, since `vm.skip` only marks the
        // result and does not abort the body.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        _deployUpgradeBase();
        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reservePool = _deployReservePool(USDG, address(yieldSource), owner);

        poolManager = new PoolManager(address(this));
        feeHook = _deployHook();

        // Stand-ins for Uniswap's periphery, and they have to be: this suite runs its markets
        // on a `PoolManager` it deploys itself, and both the factory and `MarketRouter` rightly
        // refuse a PositionManager bound to a different singleton — the deployed one belongs to
        // the chain's. That is the check working, not a limitation to route around, and it
        // costs nothing here because the periphery is not what this suite is about. The live
        // PositionManager, on the live singleton, is exercised end to end in
        // `test/markets/MarketRouterV4Fork.t.sol`.
        StandInPermit2 permit2 = new StandInPermit2();
        StandInPositionManager posm =
            new StandInPositionManager(IPoolManager(address(poolManager)), permit2);

        factory = _deployFactory(
            reservePool,
            IPoolManager(address(poolManager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            SPCX, // the canonicality reference, read live off the chain
            PROTOCOL_BPS,
            owner
        );

        // Without this the hook refuses `registerPool` and every market creation reverts.
        vm.prank(owner);
        feeHook.setRegistrar(address(factory));

        router = _deployRouter(
            reservePool,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            owner
        );

        // Morpho Blue custodies tens of millions of USDG; the live SPCX pool holds ~3,065 SPCX.
        _fundUsdg(operator, 500_000e6);
        _fundUsdg(alice, 500_000e6);
        _fundSpcx(operator, 500e18);
        _fundSpcx(alice, 50e18);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address. `deployCodeTo`
    ///      writes the contract where we want it and still runs the constructor, so
    ///      `Hooks.validateHookPermissions` still executes — the standard way to skip salt
    ///      mining in a test without skipping the check mining exists to satisfy. The deploy
    ///      script mines a real salt; see `HookSaltMiner`.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x8880 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(poolManager)), owner);
    }

    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    function _fundSpcx(address to, uint256 amount) internal {
        vm.prank(LIVE_SPCX_USDG_POOL);
        IERC20(SPCX).transfer(to, amount);
    }

    /// @dev The live mid price of SPCX in whole USDG, read from the real V3 pool rather than
    ///      hardcoded, so this suite does not rot as the price moves.
    function _livePriceE18() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(LIVE_SPCX_USDG_POOL).slot0();
        // SPCX is token0 in that pool, so P = raw USDG per raw SPCX, and one whole SPCX in
        // whole USDG is P * 1e18 / 1e6 * ... — expanded here to stay in integers:
        // price_e18 = (sqrtP^2 / 2^192) * (1e18 / 1e6) * 1e18
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // Full-width mulDiv: the intermediate here genuinely does not fit in 256 bits.
        return Math.mulDiv(ratioX192, 1e18 * 1e12, 1 << 192);
    }

    /// @dev A v4 pool holds no tokens of its own — the singleton holds every pool's reserves.
    ///      A brand token is unique to exactly one market, so its balance in the singleton IS
    ///      that market's quote-side depth.
    function _brandInPool() internal view returns (uint256) {
        return IERC20(brandToken).balanceOf(address(poolManager));
    }

    function _sqrtPrice(bytes32 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(id));
    }

    function _createSpcxMarket() internal {
        _approveAsset(factory, SPCX, FEE, _livePriceE18(), 60, "Starbase Dollar", "starUSD");

        address vaultAddr;
        address distributorAddr;
        // Creation is permissionless, so the prank decides nothing but who is recorded as the
        // market's `creator` — which the yield assertions below rest on, since a creator is
        // paid nothing by the market they opened.
        vm.prank(operator);
        (marketId, brandToken, vaultAddr, distributorAddr, poolId) =
            factory.createMarket(SPCX, address(0));

        poolKey = factory.poolKeyOf(marketId);
        feeVault = BrandFeeVault(vaultAddr);
        distributor = LpRewardDistributor(distributorAddr);
    }

    /// @dev Seeding is full range, and the position is a real `UNI-V4-POSM` NFT minted to the
    ///      seeder — here, the operator. The router is not the LP and holds nothing; closing
    ///      the position is done through Uniswap's `PositionManager` directly, which
    ///      `test/markets/MarketRouterV4Fork.t.sol` exercises end to end.
    function _seed() internal returns (uint128 liquidity) {
        vm.startPrank(operator);
        // The stable side of the pool is the market's own brandUSD, and that is what the router
        // takes. Minting it from USDG is the seeder's own 1:1 call at the reserve, made here
        // rather than inside the router so the deposit and the withdrawal are the same token.
        IERC20(USDG).approve(address(reservePool), SEED_USDG);
        reservePool.mint(brandToken, SEED_USDG, operator);
        IERC20(brandToken).approve(address(router), SEED_USDG);
        IERC20(SPCX).approve(address(router), SEED_SPCX);
        (, liquidity,,) =
            router.seedLiquidity(marketId, SEED_USDG, SEED_SPCX, 0, 0, block.timestamp);

        // A full-range add at a chosen price never consumes both sides evenly, and the router
        // hands the short side back as brandUSD rather than converting it. A seeder who is done
        // seeding redeems that remainder, so the helper does too — otherwise every float
        // assertion below would be measuring the leftover as well as the pool.
        uint256 left = IERC20(brandToken).balanceOf(operator);
        if (left > 0) reservePool.redeem(brandToken, left, operator);
        vm.stopPrank();
    }

    function _warpAndAccrueRealInterest(uint256 secondsElapsed) internal {
        vm.warp(vm.getBlockTimestamp() + secondsElapsed);
        vm.roll(block.number + 1);
        IMorphoBlueAccrue(MORPHO_BLUE)
            .accrueInterest(IMorphoBlueAccrue(MORPHO_BLUE).idToMarketParams(USDE_MARKET_ID));
    }

    // ─── 1. Canonicality, against the real tokens ────────────────────────

    /// @dev The strongest available test of the verification rule: run it on the actual
    ///      Robinhood tokens rather than on two copies of a mock.
    function test_fork_verification_acceptsRealEquitiesRejectsEverythingElse() public view {
        assertTrue(factory.isCanonicalEquity(SPCX), "SPCX is canonical");
        assertTrue(factory.isCanonicalEquity(AAPL), "AAPL shares the proxy code");
        assertTrue(factory.isCanonicalEquity(NVDA), "NVDA too");

        // Real contracts, with code and decimals, that are not Robinhood equity proxies.
        assertFalse(factory.isCanonicalEquity(USDG), "USDG is not an equity");
        assertFalse(factory.isCanonicalEquity(MORPHO_BLUE), "nor is Morpho Blue");
        assertFalse(factory.isCanonicalEquity(LIVE_SPCX_USDG_POOL), "nor a Uniswap pool");
    }

    function test_fork_createMarket_onSpcxIsVerified() public {
        _createSpcxMarket();

        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertTrue(m.verified, "a market on the real SPCX is verified");
        assertEq(m.asset, SPCX);
        assertEq(m.creator, operator, "whoever called it is recorded, and gets nothing more");

        // In V3 this asserted the pool was registered in the real Uniswap factory. There is no
        // registry to consult in v4 and no pool contract to find: a pool is a key hashed into
        // an id inside the singleton, so the equivalent claim is that the key the factory
        // recorded is the key the singleton actually holds a priced pool for.
        assertEq(PoolId.unwrap(poolKey.toId()), poolId, "the key rebuilds the recorded id");
        assertEq(address(poolKey.hooks), address(feeHook), "and it names our hook");
        assertGt(_sqrtPrice(poolId), 0, "priced at creation");

        // The oracle lives in the hook now, so that is where the buffer has to have been grown.
        (,, uint16 cardinalityNext) = feeHook.observationState(PoolId.wrap(poolId));
        assertGe(cardinalityNext, 60, "TWAP buffer grown at creation");
        // The skim is the protocol's trading fee, not the market's income, so the hook pays it
        // to the treasury. The vault divides the float yield, which is a different pot.
        assertEq(feeHook.feeRecipientOf(PoolId.wrap(poolId)), protocolTreasury);
    }

    /// @dev The derivation must agree with a pool a professional market maker is running.
    function test_fork_pricing_matchesTheLivePool() public {
        _createSpcxMarket();

        (uint160 live,,,,,,) = IUniswapV3PoolLike(LIVE_SPCX_USDG_POOL).slot0();
        uint256 ours = factory.quoteSqrtPriceX96(brandToken, SPCX, _livePriceE18());

        // Same ordering (brand and USDG are both 6dp, and both pools put SPCX opposite a
        // 6-decimal stable), so the two sqrt prices are directly comparable.
        if (brandToken > SPCX) {
            assertApproxEqRel(ours, live, 0.001e18, "within 10 bps of the live pool");
        }
    }

    // ─── 2. The float claim ──────────────────────────────────────────────

    /// @notice The mechanism the product rests on: brand tokens parked in the market's own
    ///         Uniswap pool count as outstanding supply, so the AMM reserve is float.
    function test_fork_theAmmReserveIsFloat() public {
        _createSpcxMarket();
        _seed();

        uint256 brandInPool = _brandInPool();
        assertGt(brandInPool, 0, "the singleton holds the brand token for this pool");
        assertEq(
            reservePool.outstandingOf(brandToken),
            IERC20(brandToken).totalSupply(),
            "outstanding tracks total supply"
        );
        assertApproxEqAbs(
            reservePool.outstandingOf(brandToken),
            brandInPool,
            1,
            "and essentially all of it is the pool's own reserve"
        );

        // Which means the reserve pool is holding real USDG backing it 1:1.
        _assertSolvent("solvent");
    }

    /// @dev The reserve is backed 1:1 up to one base unit of Morpho dust.
    ///
    ///      `SharedReservePool.mint` supplies to the yield source inline, and Morpho's share
    ///      maths floors in both directions, so a deposit of X can be worth X-1 the instant it
    ///      lands. `mint` deploys before re-syncing the accrual baseline precisely so this dust
    ///      is absorbed there rather than booked into `lossCarryforward` — see the comment on
    ///      that call. A strict `>=` therefore cannot hold against a live Morpho market whose
    ///      share price is not exactly 1:1, and asserting one only hides real regressions behind
    ///      a permanently red suite.
    ///
    ///      The dust is bounded, not per-mint: 200 consecutive mints leave the same single unit
    ///      short, measured in `MainnetLaunchForkTest.test_fork_reserveShortfallStaysBounded-
    ///      AcrossManyMints`. One unit of 6-decimal USDG is $0.000001.
    function _assertSolvent(string memory label) internal view {
        assertGe(reservePool.totalAssets() + 1, reservePool.totalPooledSupply(), label);
    }

    // ─── 3. Trading through the router ───────────────────────────────────

    function test_fork_buyAndSellThroughTheRouter() public {
        _createSpcxMarket();
        _seed();

        uint256 floatBefore = reservePool.outstandingOf(brandToken);
        uint256 spcxBefore = IERC20(SPCX).balanceOf(alice);

        // Buy: USDG in, SPCX out, with the brand minted and parked in the pool on the way.
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        uint256 bought = router.buyWithUsdg(marketId, 1_000e6, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(bought, 0, "received SPCX");
        assertEq(IERC20(SPCX).balanceOf(alice) - spcxBefore, bought);
        assertEq(
            reservePool.outstandingOf(brandToken) - floatBefore,
            1_000e6,
            "the whole purchase became float"
        );
        assertEq(IERC20(brandToken).balanceOf(address(router)), 0, "router holds nothing");

        // Sell it straight back. A round trip pays the fee twice and crosses the spread, so
        // the seller must come out behind — assert that rather than pretending otherwise.
        uint256 usdgBefore = IERC20(USDG).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(SPCX).approve(address(router), bought);
        uint256 brandOut = router.sellForBrand(marketId, bought, 0, alice, block.timestamp);
        // The sell stops at the brand; the trip back to USDG is the seller's own 1:1 redeem.
        uint256 usdgOut = reservePool.redeem(brandToken, brandOut, alice);
        vm.stopPrank();

        assertEq(usdgOut, brandOut, "the redeem is at par");

        assertEq(IERC20(USDG).balanceOf(alice) - usdgBefore, usdgOut);
        assertLt(usdgOut, 1_000e6, "a round trip costs the fee and the spread");
        assertGt(usdgOut, 985e6, "but only that much: two 0.3% fees plus impact");
        assertEq(IERC20(SPCX).balanceOf(address(router)), 0, "router holds nothing");
    }

    function test_fork_buy_enforcesItsSlippageBound() public {
        _createSpcxMarket();
        _seed();

        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        // Ask for far more SPCX than 1,000 USDG can buy.
        vm.expectRevert();
        router.buyWithUsdg(marketId, 1_000e6, 100e18, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice Entering one market with another market's brand. The crossing is the reserve
    ///         pool's 1:1 swap, so it must transfer exactly zero value — this is why many
    ///         brands do not fragment the quote layer.
    function test_fork_buyWithAnotherBrandCrossesAtPar() public {
        _createSpcxMarket();
        _seed();

        // A second, unrelated market — its brand is what alice will arrive holding. Its oracle
        // depth is left at zero: this market is never traded, so it takes the factory's floor.
        _approveAsset(factory, AAPL, FEE, 200e18, 0, "Orchard Dollar", "aplUSD");
        (, address otherBrand,,,) = factory.createMarket(AAPL, address(0));

        vm.startPrank(alice);
        IERC20(USDG).approve(address(reservePool), 1_000e6);
        reservePool.mint(otherBrand, 1_000e6, alice);

        uint256 spcxOutstandingBefore = reservePool.outstandingOf(brandToken);
        uint256 otherOutstandingBefore = reservePool.outstandingOf(otherBrand);

        IERC20(otherBrand).approve(address(router), 1_000e6);
        uint256 bought =
            router.buyWithBrand(marketId, otherBrand, 1_000e6, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(bought, 0, "bought SPCX with a different market's brand");
        assertEq(
            otherOutstandingBefore - reservePool.outstandingOf(otherBrand),
            1_000e6,
            "exactly what was given up left the other brand"
        );
        assertEq(
            reservePool.outstandingOf(brandToken) - spcxOutstandingBefore,
            1_000e6,
            "and exactly that much arrived in this one: 1:1, no value moved"
        );
        _assertSolvent("still solvent");
    }

    // ─── 4. Real yield, harvested and swept ──────────────────────────────

    function test_fork_realMorphoYieldIsHarvestedAndSwept() public {
        _createSpcxMarket();
        _seed();

        uint256 operatorBefore = IERC20(USDG).balanceOf(operator);

        // Put the float to work in the live USDG/USDe market and let real interest accrue.
        reservePool.deployIdle();
        // Measured from the pool's perspective on purpose: `MorphoBlueYieldSource.balanceOf`
        // reports the CALLER's own position (`sharesOf[msg.sender]`), which is the fix that
        // stopped one consumer reading another's principal. Asking it from this test would
        // correctly return zero.
        uint256 deployed = reservePool.totalAssets() - IERC20(USDG).balanceOf(address(reservePool));
        assertGt(deployed, 0, "float supplied to Morpho Blue");

        _warpAndAccrueRealInterest(180 days);

        uint256 pending = feeVault.pendingYield();
        assertGt(pending, 0, "real interest accrued to the brand");
        console.log("float supplied to Morpho (USDG):", deployed);
        console.log("yield accrued over 180 days   :", pending);

        uint256 claimed = feeVault.harvest();
        assertApproxEqAbs(claimed, pending, 2, "harvest claims what was pending");

        (uint256 toProtocol, uint256 toLps) = feeVault.sweep();

        // Real Morpho interest is the pool's liquidity providers' income, and the operator —
        // who created this market — is paid nothing at all by it.
        assertEq(IERC20(USDG).balanceOf(operator), operatorBefore, "operator takes no cut");
        assertEq(toProtocol, 0, "zero fee on yield, as shipped");
        assertEq(IERC20(USDG).balanceOf(protocolTreasury), 0);
        assertEq(toProtocol + toLps, claimed, "everything claimed was distributed");
        assertEq(feeVault.totalToLps(), toLps);
        assertEq(feeVault.balance(), 0, "everything delivered");

        // And it arrived where the market's LPs can reach it: the market's own distributor,
        // as brandUSD, streaming over a period that is now running. The destination was
        // written once at creation and nobody outside the factory can move it.
        assertEq(address(feeVault.distributor()), address(distributor), "the market's own");
        assertEq(IERC20(brandToken).balanceOf(address(distributor)), toLps, "the LP share landed");
        assertGt(distributor.periodFinish(), vm.getBlockTimestamp(), "and is streaming");
        vm.prank(operator);
        vm.expectRevert(BrandFeeVault.OnlyFactory.selector);
        feeVault.setDistributor(distributor);

        // The reserve is still fully backed after paying yield out.
        _assertSolvent("solvent after harvest");
    }

    /// @notice Trading grows the float, which grows the yield. The flywheel, measured.
    function test_fork_tradingGrowsTheFloatAndTheYield() public {
        _createSpcxMarket();
        _seed();
        reservePool.deployIdle();
        _warpAndAccrueRealInterest(30 days);
        uint256 baseline = feeVault.pendingYield();

        uint256 floatBefore = reservePool.outstandingOf(brandToken);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 100_000e6);
        router.buyWithUsdg(marketId, 100_000e6, 0, alice, block.timestamp);
        vm.stopPrank();
        uint256 floatAfter = reservePool.outstandingOf(brandToken);

        assertEq(floatAfter - floatBefore, 100_000e6, "the buy added float");

        reservePool.deployIdle();
        _warpAndAccrueRealInterest(30 days);

        uint256 second = feeVault.pendingYield() - baseline;
        assertGt(second, baseline, "a bigger float earns more over the same window");
    }
}
