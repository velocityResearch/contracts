// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @title SharedQuoteMainnetForkTest
/// @notice Verification of the SHIPPED `createMarketForBrand` migration against the LIVE
///         Robinhood Chain deployment. NVDA, SPCX and AI are relisted and quoted in AIUSD, a
///         dollar none of them owns; this suite asserts that end state on chain rather than
///         rehearsing the steps that produced it.
///
/// @dev    Four things can only be proven here and not in the mock suites:
///
///         - **The migration actually landed the shape it was designed for.** All three assets
///           resolve to markets in `RESERVE` whose `brandToken` is the same AIUSD, each with
///           its own pool and fee vault, and each reporting `isSharedQuote`. One dollar across
///           three assets is the entire feature; a mock suite can only show it is possible.
///         - **This source is still storage-compatible with real state.** A fresh
///           `AssetMarketFactory` deployed into a fresh test has no history to disagree with.
///           The live proxy has eighteen markets, several approvals, a brand registry and a
///           second reserve; if a variable were reordered or inserted, the NVDA market would
///           read back a different brand, pool or vault after an upgrade. That read is the
///           assertion the upgrade test exists for, and it keeps guarding the next upgrade.
///         - **The shared-quote path is routable against the live venue.** The pool lives in
///           Uniswap's own singleton at `MainnetAddresses.POOL_MANAGER`, is registered with the
///           live `ProtocolFeeHook`, and is seeded and traded through the live `MarketRouter`
///           proxy — none of which is stood in for here.
///         - **The dollar's issuer kept their dollar.** AIUSD is a representation brand: it is
///           held in wallets, its treasury admin is its issuer, and `marketOfBrand` is zero.
///           Quoting three markets in it left all three of those facts exactly as they were,
///           which is the whole difference between this path and `createMarket`.
///
///         Every address below was read off chain 4663. Market ids are resolved from
///         `marketOfAsset` in `setUp` and never pinned: retiring and relisting a pair mints a
///         new id, so a hard-coded id turns an unrelated relisting into a suite-wide failure.
///
///         Run with:
///         forge test --match-contract SharedQuoteMainnetFork -vvv --fork-url https://rpc.mainnet.chain.robinhood.com
contract SharedQuoteMainnetForkTest is Test {
    using StateLibrary for IPoolManager;

    // ─── The live deployment ─────────────────────────────────────────────

    /// @notice The `AssetMarketFactory` UUPS proxy carrying the shipped shared-quote path.
    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;

    /// @notice Its owner, which is also AIUSD's recorded `brandOperatorOf` — so the same key
    ///         signed the upgrade, the retirements and the three creations.
    /// @dev The protocol owner since the custody migration. Every `onlyOwner` entry point on
    ///      the factory answers to this 2-of-3 Safe, not to the deployer EOA any more.
    address constant OWNER = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;

    /// @dev The deploying EOA, which is NOT the owner any more but is still AIUSD's stored
    ///      `brandOperatorOf`. That is a per-brand role held as data rather than access
    ///      control on the factory, so the ownership handover did not move it, and asserting
    ///      it is unchanged is part of proving the upgrade touched nothing it should not have.
    ///
    ///      **The treasury admin is a different story and is no longer this address.** It was
    ///      rotated to the Safe on chain; see `AIUSD_TREASURY_ADMIN`. The two roles are
    ///      separable by design — `PoolBrandTreasury.setAdmin` and
    ///      `PooledBrandToken.handOverMetadataAdmin` are independent — and only the treasury
    ///      admin can move money or opt the brand into sharing its float yield.
    address constant AIUSD_ISSUER = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;

    /// @notice The live `MarketRouter` proxy bound to that factory. It was never upgraded for
    ///         this feature: it already decodes the `Market` struct and mints through the
    ///         market's reserve, so a borrowed dollar is just another brand token to it.
    address constant ROUTER = 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4;

    /// @notice The sUSDai-backed reserve. Not the factory's default — an `approvedReservePool`,
    ///         which is the case `createMarketForBrand` re-checks rather than assuming.
    address constant RESERVE = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;

    /// @notice AIUSD, a representation brand registered through the factory in that reserve,
    ///         and the single quote unit all three markets below borrow.
    address constant AIUSD = 0xE7BB388959d89f809BE24da16A1DaBa0dC58E596;

    /// @notice AIUSD's `PoolBrandTreasury`.
    address constant AIUSD_TREASURY = 0xE2d144F8b18d4743fdC4D74e4AE621307e443e38;

    /// @notice Who administers that treasury on chain today: the Safe, not the deployer EOA.
    ///
    /// @dev    This assertion used to name `AIUSD_ISSUER` and had drifted — the admin was
    ///         rotated with the rest of custody while the metadata operator stayed behind.
    ///         Pinned separately rather than folded into `OWNER` because the two being the
    ///         same address is a fact about today's deployment, not a property: a brand whose
    ///         issuer is a third party would have a different admin here, and that is the
    ///         case `PoolBrandTreasury.setFactory` exists for.
    ///
    ///         Operationally this is the address that must call `setFactory(marketFactory)`
    ///         before a launch may be quoted in AIUSD.
    address constant AIUSD_TREASURY_ADMIN = OWNER;

    address constant USDG = MainnetAddresses.USDG;
    address constant NVDA = MainnetAddresses.NVDA;
    address constant SPCX = MainnetAddresses.SPCX;
    address constant AI = MainnetAddresses.AI;

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);

    /// @notice The live shared-quote markets for the three assets in `RESERVE`.
    ///
    ///         Resolved from the factory in `setUp`, never hard-coded. These were 10, 11 and 12
    ///         before the migration and NVDA is 13 today, because retiring and relisting a pair
    ///         mints a new id. Pinning them made the whole suite fail on an unrelated
    ///         relisting, which is noise an audit reviewer has to chase rather than signal.
    uint256 nvdaMarket;
    uint256 spcxMarket;
    uint256 aiMarket;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ─── Trade sizing ────────────────────────────────────────────────────

    /// @dev The reserve's `liabilityCap` is 10,000,000 USDG against a few thousand outstanding,
    ///      so the seed and the buy together stay well inside it and the mint cannot be refused
    ///      for a reason that has nothing to do with the shared quote.
    uint256 constant SEED_QUOTE = 20_000e6;
    /// @dev Deliberately more NVDA than a 20,000-dollar full-range position can absorb at the
    ///      live price, so the quote side binds and the remainder comes back — which is also
    ///      what makes `assetUsed` a number worth asserting on.
    uint256 constant SEED_ASSET = 1_000e18;
    uint256 constant BUY_USDG = 1_000e6;

    AssetMarketFactory factory;
    MarketRouter router;

    /// @dev What a future implementation swap would pay, reported by the upgrade test; see
    ///      `_upgradeFactory`.
    uint256 deployGas;
    uint256 upgradeGas;

    function setUp() public {
        // A URL in the environment pins the fork (a local anvil is the only way to hold this
        // chain's state still for a slow run); otherwise the fork comes from `--fork-url`.
        string memory url = vm.envOr("SHARED_QUOTE_FORK_URL", string(""));
        if (bytes(url).length > 0) {
            uint256 pinned = vm.envOr("SHARED_QUOTE_FORK_BLOCK", uint256(0));
            if (pinned == 0) vm.createSelectFork(url);
            else vm.createSelectFork(url, pinned);
        }

        // Skip cleanly when run without a fork, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, so the early return is what stops the body from
        // reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        factory = AssetMarketFactory(FACTORY);
        router = MarketRouter(ROUTER);

        // Read the ids off the chain rather than pinning them. See the declarations above.
        nvdaMarket = factory.marketOfAsset(RESERVE, NVDA);
        spcxMarket = factory.marketOfAsset(RESERVE, SPCX);
        aiMarket = factory.marketOfAsset(RESERVE, AI);
        assertTrue(nvdaMarket != 0 && spcxMarket != 0 && aiMarket != 0, "all three are listed");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    /// @dev Deploy this source's implementation and point the live proxy at it, as the owner
    ///      would. Records both halves of what such a broadcast pays: deploying the
    ///      implementation, then the one-word write that adopts it.
    function _upgradeFactory() internal returns (address fresh) {
        address stale = _impl(FACTORY);

        uint256 gasBefore = gasleft();
        fresh = address(new AssetMarketFactory());
        deployGas = gasBefore - gasleft();

        vm.prank(OWNER);
        gasBefore = gasleft();
        factory.upgradeToAndCall(fresh, "");
        upgradeGas = gasBefore - gasleft();

        assertTrue(fresh != stale, "the implementation actually moved");
        assertEq(_impl(FACTORY), fresh, "the proxy points at the new implementation");
    }

    function _sqrtPrice(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = MANAGER.getSlot0(PoolId.wrap(poolId));
    }

    /// @dev Everything one live shared quote owes, regardless of which asset it is for: it is
    ///      the pair's market, it is quoted in AIUSD out of AIUSD's own treasury, it sits in
    ///      the reserve the dollar is pooled in, it reports itself shared, and the registry
    ///      routes its pool back to it.
    function _assertLiveSharedQuote(address asset, uint256 marketId)
        internal
        view
        returns (AssetMarketFactory.Market memory m)
    {
        assertTrue(marketId != 0, "the asset has a live market");
        m = factory.market(marketId);
        assertEq(m.asset, asset, "the asset it is open for");
        assertEq(m.brandToken, AIUSD, "quoted in the dollar that already existed");
        assertEq(m.treasury, AIUSD_TREASURY, "and in that dollar's own treasury");
        assertEq(m.reservePool, RESERVE, "in the reserve the dollar is pooled in");
        assertTrue(factory.isSharedQuote(marketId), "and it reports itself as a shared quote");
        assertEq(factory.marketOfPool(m.poolId), marketId, "its pool routes back to it");

        // Its own income plumbing, exactly like any other market: the vault and the distributor
        // are the market's, only the dollar is not.
        assertTrue(m.feeVault != address(0), "the market has its own fee vault");
        assertTrue(m.lpDistributor != address(0), "and its own LP distributor");

        // The pool is real inside Uniswap's singleton, not just a registry row.
        assertGt(_sqrtPrice(m.poolId), 0, "the pool is initialised in the singleton");
    }

    // ─── 1. This source against real state ───────────────────────────────

    /// @notice An upgrade to this source lands on the live proxy and every market already in
    ///         its storage still reads back identically. A reordered or inserted variable would
    ///         surface here as a market pointing at the wrong brand, pool or vault — silently,
    ///         and irreversibly if it were found after a broadcast rather than before.
    function test_fork_theUpgradeLeavesLiveMarketStorageWhereItWas() public {
        AssetMarketFactory.Market memory before = factory.market(nvdaMarket);
        uint256 countBefore = factory.marketCount();
        address defaultReserve = address(factory.reservePool());

        console.log("factory implementation before:", _impl(FACTORY));
        address fresh = _upgradeFactory();
        console.log("factory implementation after: ", fresh);
        console.log("implementation deployment gas:", deployGas);
        console.log("upgradeToAndCall gas:", upgradeGas);

        AssetMarketFactory.Market memory now_ = factory.market(nvdaMarket);
        assertEq(now_.brandToken, before.brandToken, "the NVDA market brand token");
        assertEq(now_.poolId, before.poolId, "the NVDA market pool id");
        assertEq(now_.feeVault, before.feeVault, "the NVDA market fee vault");
        assertEq(now_.asset, before.asset, "the NVDA market asset");
        assertEq(now_.treasury, before.treasury, "the NVDA market treasury");
        assertEq(now_.lpDistributor, before.lpDistributor, "the NVDA market distributor");
        assertEq(now_.reservePool, before.reservePool, "the NVDA market reserve");
        assertEq(now_.fee, before.fee, "the NVDA market fee");
        assertEq(now_.tickSpacing, before.tickSpacing, "the NVDA market tick spacing");
        assertEq(now_.createdAt, before.createdAt, "the NVDA market creation time");

        // The registry indexes that point at it, and the roots the shared-quote path reads.
        assertEq(factory.marketCount(), countBefore, "no market appeared or vanished");
        assertEq(factory.marketOfAsset(RESERVE, NVDA), nvdaMarket, "still its own market");
        assertEq(factory.marketOfPool(before.poolId), nvdaMarket, "still owns its pool");

        // `marketOfBrand` is the record of which market MINTED a unit, and nothing else can
        // claim it. This market borrows AIUSD, a brand registered before it existed, so the
        // entry is zero by construction — asserting it survived as zero is what proves the slot
        // was neither repurposed by the upgrade nor quietly written by the shared-quote path.
        assertEq(factory.marketOfBrand(before.brandToken), 0, "a shared quote owns no unit");
        assertEq(factory.owner(), OWNER, "owner");
        assertEq(address(factory.reservePool()), defaultReserve, "default reserve");
        assertTrue(factory.approvedReservePool(RESERVE), "sUSDai still approved");

        // The view answering off that storage: a market whose brand is not its own is a shared
        // quote, and the only way to know that is for `marketOfBrand` to have survived at the
        // slot the code reads.
        assertTrue(factory.isSharedQuote(nvdaMarket), "a borrowed dollar is a shared quote");

        // AIUSD's side of the registry, which every one of the three markets hangs off.
        assertEq(factory.reserveOfBrand(AIUSD), RESERVE, "AIUSD reserve");
        assertEq(factory.brandOperatorOf(AIUSD), AIUSD_ISSUER, "AIUSD operator");
        assertEq(factory.treasuryOfBrand(AIUSD), AIUSD_TREASURY, "AIUSD treasury");
    }

    // ─── 2 & 3. Three markets live in a dollar that already existed ──────

    /// @notice The shipped end state: all three assets are open and quoted in AIUSD, sharing
    ///         one unit between three pools. The dollar came out of the migration unchanged —
    ///         same treasury admin, no `marketOfBrand`, no `feeVaultOfBrand` — which is what
    ///         distinguishes a dollar a market borrows from a unit a market owns.
    function test_fork_theThreeAssetsReopenQuotedInAiusd() public view {
        AssetMarketFactory.Market memory nvda = _assertLiveSharedQuote(NVDA, nvdaMarket);
        AssetMarketFactory.Market memory spcx = _assertLiveSharedQuote(SPCX, spcxMarket);
        AssetMarketFactory.Market memory ai = _assertLiveSharedQuote(AI, aiMarket);

        // One dollar across three assets is the feature. Three markets each quoted in a brand
        // that merely happens to be AIUSD-shaped would satisfy the per-market checks above.
        assertEq(nvda.brandToken, spcx.brandToken, "NVDA and SPCX share one unit");
        assertEq(nvda.brandToken, ai.brandToken, "NVDA and AI share one unit");

        // Three markets, three distinct pools. The pair is what makes a pool, so quoting three
        // assets in one dollar must not collapse them onto one key.
        assertTrue(nvda.poolId != spcx.poolId, "NVDA and SPCX are different pools");
        assertTrue(nvda.poolId != ai.poolId, "NVDA and AI are different pools");
        assertTrue(spcx.poolId != ai.poolId, "SPCX and AI are different pools");

        // Three fee vaults, one per market. A shared dollar does not mean a shared income
        // stream: each pool's LPs are paid by their own vault and distributor.
        assertTrue(nvda.feeVault != spcx.feeVault, "NVDA and SPCX have their own vaults");
        assertTrue(nvda.feeVault != ai.feeVault, "NVDA and AI have their own vaults");
        assertTrue(spcx.feeVault != ai.feeVault, "SPCX and AI have their own vaults");

        // What the dollar did NOT give up. `marketOfBrand` staying zero is also what keeps
        // `isSharedQuote` true for all three: no market can claim to own AIUSD.
        assertEq(factory.marketOfBrand(AIUSD), 0, "AIUSD still belongs to no market");
        assertEq(factory.feeVaultOfBrand(AIUSD), address(0), "and has no vault of its own");
        // Opening three markets in AIUSD took neither of the dollar's two authorities. They
        // sit with different parties, and the test names both so a change to either is loud:
        // the treasury admin — the only address that can move AIUSD's yield, or opt it into
        // sharing that yield with the markets quoting it — is the Safe, while the metadata
        // operator is still the deployer EOA that registered the brand.
        assertEq(
            PoolBrandTreasury(AIUSD_TREASURY).admin(),
            AIUSD_TREASURY_ADMIN,
            "the Safe still administers AIUSD's treasury"
        );
        assertEq(factory.brandOperatorOf(AIUSD), AIUSD_ISSUER, "and the issuer holds metadata");
    }

    // ─── 4. The live pool is real and tradeable ──────────────────────────

    /// @notice A live shared-quote pool is an ordinary v4 pool on Uniswap's own singleton: it
    ///         takes liquidity through the live `MarketRouter`, fills a buy, pays out the asset
    ///         and moves its price. The borrowed dollar becoming float in the singleton is the
    ///         same mechanism a unit-quoted market runs on — the difference is only whose float
    ///         it is, and this proves the trading side does not notice.
    function test_fork_aSharedQuoteMarketTradesThroughTheLiveRouter() public {
        // The market the migration left behind, not one this test opens: the pair slot is
        // taken, so the only shared quote available to trade is the live one.
        AssetMarketFactory.Market memory m = factory.market(nvdaMarket);
        assertTrue(factory.isSharedQuote(nvdaMarket), "trading the live shared quote");
        bytes32 poolId = m.poolId;

        address lp = makeAddr("lp");
        address taker = makeAddr("taker");

        // The AIUSD is minted at the reserve out of real USDG rather than conjured onto the
        // balance, so the quote side of this pool is backed float exactly as in production.
        deal(USDG, lp, SEED_QUOTE);
        deal(NVDA, lp, SEED_ASSET);

        // A v4 pool holds no tokens of its own; the singleton holds every pool's reserves. So
        // the dollar the pool took is the singleton's balance, which is where the issuer's
        // float ends up when a market borrows their dollar.
        uint256 floatBefore = IERC20(AIUSD).balanceOf(address(MANAGER));

        vm.startPrank(lp);
        IERC20(USDG).approve(RESERVE, SEED_QUOTE);
        SharedReservePool(RESERVE).mint(AIUSD, SEED_QUOTE, lp);
        IERC20(AIUSD).approve(ROUTER, SEED_QUOTE);
        IERC20(NVDA).approve(ROUTER, SEED_ASSET);
        (, uint128 liquidity, uint256 quoteUsed, uint256 assetUsed) =
            router.seedLiquidity(nvdaMarket, SEED_QUOTE, SEED_ASSET, 1, 1, block.timestamp + 600);
        vm.stopPrank();

        assertGt(liquidity, 0, "the position was minted");
        assertGt(quoteUsed, 0, "the pool took the borrowed dollar");
        assertGt(assetUsed, 0, "and the asset");
        assertEq(
            IERC20(AIUSD).balanceOf(address(MANAGER)) - floatBefore,
            quoteUsed,
            "the borrowed dollar is float in the singleton"
        );
        assertEq(IERC20(AIUSD).balanceOf(lp), SEED_QUOTE - quoteUsed, "the rest came home");

        uint160 priceBefore = _sqrtPrice(poolId);
        assertGt(priceBefore, 0, "the pool is live inside the singleton");

        uint256 takerAssetBefore = IERC20(NVDA).balanceOf(taker);
        deal(USDG, taker, BUY_USDG);
        vm.startPrank(taker);
        IERC20(USDG).approve(ROUTER, BUY_USDG);
        uint256 bought = router.buyWithUsdg(nvdaMarket, BUY_USDG, 1, taker, block.timestamp + 600);
        vm.stopPrank();

        assertGt(bought, 0, "the buy filled");
        assertEq(
            IERC20(NVDA).balanceOf(taker) - takerAssetBefore,
            bought,
            "the taker holds exactly what the router reported"
        );
        assertEq(IERC20(USDG).balanceOf(taker), 0, "and paid exactly what it offered");

        // Quote in, asset out. Which way `sqrtPriceX96` moves is decided by the token ordering
        // in the key, so the direction is derived rather than guessed.
        uint160 priceAfter = _sqrtPrice(poolId);
        if (AIUSD < NVDA) {
            assertLt(priceAfter, priceBefore, "quote is currency0: a buy moves price down");
        } else {
            assertGt(priceAfter, priceBefore, "quote is currency1: a buy moves price up");
        }

        console.log("seeded liquidity:", liquidity);
        console.log("quote used, 6dp:", quoteUsed);
        console.log("asset used, 18dp:", assetUsed);
        console.log("bought with 1,000 USDG, 18dp:", bought);
    }

    // ─── 5. The uniqueness rule still holds ──────────────────────────────

    /// @notice The shared-quote path inherits one market per (reserve, asset), and the live
    ///         registry still enforces it. Without it, every dollar that wanted to quote NVDA
    ///         would open its own thin NVDA pool against the same reserve — the exact
    ///         fragmentation the representation model exists to avoid.
    ///
    ///         The pair is live, so the registry check is the one that fires. The deeper guard
    ///         `PoolAlreadyInitialised` sits behind it, reachable only if the pair slot were
    ///         freed by a retirement while the v4 pool for (asset, brand) stayed initialised.
    function test_fork_aSecondSharedQuoteForTheSamePairIsRefused() public {
        // Hoisted: an inline getter inside the call after `vm.prank` would consume the prank.
        uint256 incumbent = nvdaMarket;

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetAlreadyHasMarket.selector, RESERVE, NVDA, incumbent
            )
        );
        vm.prank(OWNER);
        factory.createMarketForBrand(NVDA, AIUSD);
    }
}
