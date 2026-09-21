// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev Morpho's `market()` is a plain storage read, so warping alone compounds nothing.
///      `accrueInterest` forces what the next real supply would have done.
interface IMorphoAccrue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function accrueInterest(MarketParams memory marketParams) external;
}

/// @dev The ERC-721 half of the deployed PositionManager, which `IPositionManagerV4` does not
///      declare because the router never needs it.
interface IPositionsNftLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
}

/// @title LaunchJourneyV4ForkTest
/// @notice **The product, start to finish, against the live chain.**
///
///         The other two v4 fork suites each answer one narrow question. `AssetMarketV4Fork`
///         asks whether our contracts agree with the deployed `PoolManager`'s ABI, and reaches
///         the pool through v4-core's own reference routers rather than through ours.
///         `MarketRouterV4Fork` asks whether a seeder gets a real, withdrawable Uniswap LP NFT.
///         Both deliberately isolate a mechanism, and both fund things directly to keep the
///         mechanism in view.
///
///         Nothing asked the question a user would: **does the whole thing work, in order, with
///         one market's state carried from each step into the next?** A launch is a sequence —
///         issue, seed, trade, earn, reward, redeem — and every step consumes what the
///         previous one produced. Bugs that live in the joins between steps are invisible to a
///         suite that funds each step by hand. The `sweep` that moved money out of the vault
///         and never credited it at the other end survived every unit test in this repo for
///         exactly that reason.
///
///         So this suite runs one market through its whole life, through the shipping path at
///         every step:
///
///         1. **Issue.** One `createMarket` call. No separate stablecoin deployment, no second
///            transaction to attach a market — the thing the simplification was for.
///         2. **Seed.** Through `MarketRouter.seedLiquidity` into Uniswap's real
///            `PositionManager`, so the operator ends up holding a position they can exit
///            without this repo's help.
///         3. **Trade.** Real swaps against the deployed singleton, in both directions, each
///            paying the hook's skim out of the leg it did not name.
///         4. **Earn.** Real Morpho interest on the float behind the branded stablecoin,
///            harvested and split with the protocol treasury.
///         5. **Reward.** The market's share of that interest streamed to the LP who staked
///            the position step 2 produced, and claimed in the market's own dollar.
///         6. **Redeem.** A holder takes brandUSD back to USDG at par.
///
///         **Real:** the PoolManager, the PositionManager, Permit2, USDG, Morpho Blue, SPCX,
///         and the live V3 SPCX/USDG pool (read for a starting price, pranked as a source of
///         SPCX). **Ours, deployed into the fork:** the reserve stack, the hook, the factory
///         and the router. Nothing is mocked.
///
///         Unlike its sibling suites this one runs with a **non-zero protocol share of yield**
///         (`PROTOCOL_BPS = 1_000`). The shipping default is zero — the protocol's revenue is
///         the trading skim, not the yield — so a suite on the default would never execute the
///         protocol branch of `BrandFeeVault.sweep` at all. Whatever the protocol does not take
///         is the liquidity providers', so every sweep here divides in two.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state older than roughly a few thousand blocks comes back as
///         `-32000: metadata is not found` and every test fails in `setUp` with a confusing
///         account-fetch error rather than anything about our contracts. Take the block from
///         the chain rather than from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-path "test/markets/LaunchJourneyV4Fork.t.sol" --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract LaunchJourneyV4ForkTest is Test, StackFixture {
    using StateLibrary for IPoolManager;

    // ─── The live chain ──────────────────────────────────────────────────

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 constant POSM = IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;
    address constant SPCX = MainnetAddresses.REFERENCE_EQUITY;
    bytes32 constant USDE_MARKET_ID = MainnetAddresses.USDE_MARKET_ID;

    /// @notice The live SPCX/USDG 0.05% V3 pool. Read for a starting price and pranked as a
    ///         source of SPCX — never traded against.
    address constant LIVE_SPCX_USDG_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;

    // ─── Market configuration ────────────────────────────────────────────

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    /// @dev 0.30% to the protocol, taken out of every swap's unspecified leg after the pool
    ///      has charged its own LP fee. Higher than anything that would ship, so the
    ///      arithmetic is legible in the logs.
    uint24 constant PROTOCOL_FEE_PIPS = 3_000;

    /// @dev 10% of harvested yield to the protocol treasury. See the contract note above.
    uint16 constant PROTOCOL_BPS = 1_000;

    /// @dev What the operator brings to the launch. USDG becomes brandUSD 1:1 inside the
    ///      router, so this is also the market's starting float.
    uint256 constant SEED_USDG = 60_000e6;
    uint256 constant SEED_SPCX = 300e18;

    // ─── Our stack ───────────────────────────────────────────────────────

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;
    PoolSwapTest swapRouter;

    // ─── The cast ────────────────────────────────────────────────────────

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);

    /// @dev The person launching the token. Issues the brand, seeds the market, and is the
    ///      only address that may open further markets for it.
    address operator = address(0x0FE);

    /// @dev Two ordinary users. `buyer` trades the market; `holder` only ever wants a
    ///      stablecoin and never touches the pool, which is what makes the redemption leg a
    ///      claim about the reserve rather than about the market.
    address buyer = address(0x7AAD);
    address holder = address(0x40D);

    // ─── The market under test ───────────────────────────────────────────

    uint256 marketId;
    address brandToken;
    PoolKey poolKey;
    PoolId poolId;
    BrandFeeVault feeVault;
    LpRewardDistributor distributor;

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, so the early return is what stops the body from
        // reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reservePool = _deployReservePool(USDG, address(yieldSource), owner);

        feeHook = _deployHook();

        factory = _deployFactory(
            reservePool, MANAGER, feeHook, POSM, protocolTreasury, SPCX, PROTOCOL_BPS, owner
        );

        vm.startPrank(owner);
        feeHook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        router = _deployRouter(reservePool, factory, POSM, PERMIT2, owner);
        swapRouter = new PoolSwapTest(MANAGER);

        _fundUsdg(operator, 500_000e6);
        _fundSpcx(operator, 1_000e18);
        _fundUsdg(buyer, 500_000e6);
        _fundSpcx(buyer, 500e18);
        _fundUsdg(holder, 100_000e6);
        _fundUsdg(address(this), 500_000e6);
    }

    // ══ Step 1 ══ Issue ═══════════════════════════════════════════════════

    /// @notice One transaction produces a stablecoin, its treasury, its fee vault, its LP
    ///         reward distributor and a live Uniswap v4 pool.
    ///
    ///         This is the simplification the redesign was for. There is no separate "deploy a
    ///         stablecoin" step and no second transaction to attach a market to it, so there is
    ///         no window in which a brand exists with nowhere to trade.
    function test_fork_step1_oneCallProducesAWholeLiveMarket() public {
        uint256 gasBefore = gasleft();
        _issue();
        console.log("gas for the entire launch, one transaction:", gasBefore - gasleft());

        AssetMarketFactory.Market memory m = factory.market(marketId);

        // Every piece exists and is distinct.
        assertEq(m.asset, SPCX, "the market trades the asset that was asked for");
        assertEq(m.brandToken, brandToken);
        assertTrue(m.treasury != address(0), "the brand has a treasury");
        assertTrue(m.feeVault != address(0), "which has a fee vault");
        assertTrue(m.lpDistributor != address(0), "which pays an LP reward distributor");
        assertEq(m.creator, operator, "and the launch is attributed to whoever sent it");
        assertEq(m.reservePool, address(reservePool), "against the default reserve");

        // The stablecoin is real and 6-decimal, matching USDG so the reserve is 1:1 in units
        // as well as in value.
        assertEq(IERC20Metadata(brandToken).symbol(), "starUSD");
        assertEq(IERC20Metadata(brandToken).decimals(), 6);

        // The pool is live inside Uniswap's singleton at the price the issuer asked for. A
        // non-zero `sqrtPriceX96` read back through `extsload` is the round trip that proves
        // both the key hashing and the storage layout.
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "initialised inside the real PoolManager");
        assertEq(
            sqrtPriceX96,
            factory.quoteSqrtPriceX96(brandToken, SPCX, _livePriceE18()),
            "at exactly the price the approval asked for"
        );

        // The hook is bound to this pool, and the pool is bound to the hook.
        assertEq(address(poolKey.hooks), address(feeHook), "the fee hook is in the pool key");
        // The trading skim is the protocol's, not the market's, so it is the treasury the hook
        // pays. The market earns from float yield, which its vault divides.
        assertEq(feeHook.feeRecipientOf(poolId), protocolTreasury, "and it pays the treasury");
        assertEq(feeHook.feePipsFor(poolId), PROTOCOL_FEE_PIPS);

        // The chain of custody the money will travel: treasury → vault → distributor → LPs.
        assertEq(address(feeVault.distributor()), m.lpDistributor, "vault knows its distributor");
        assertEq(distributor.vault(), m.feeVault, "and the distributor knows its vault");
        assertEq(address(distributor.rewardToken()), brandToken, "rewards are paid in the unit");
        // The distributor admits positions of this market's pool and of no other, so the key
        // it recorded has to be the one the factory initialised.
        assertEq(
            PoolId.unwrap(distributor.poolKey().toId()),
            PoolId.unwrap(poolId),
            "and guards this market's own pool"
        );
    }

    /// @notice The image and description an indexer needs live on the token itself, and belong
    ///         to whoever launched the market.
    ///
    ///         The owner's approval of an asset carries the unit's name and symbol and nothing
    ///         else, so a market's dollar arrives without a picture and its creator is the one
    ///         who gives it one. The getter names are not ours: `description()`, `logo()` and
    ///         `socials()` are what the incumbent launchpads on this chain expose, so an
    ///         indexer that already reads those tokens reads ours with no change. That is the
    ///         whole reason the metadata is on chain rather than in our database.
    function test_fork_step1_theTokenCarriesItsOwnImageForIndexers() public {
        _issue();

        PooledBrandToken token = PooledBrandToken(brandToken);

        // The factory held the metadata pen only long enough to register the brand, and handed
        // it to the creator before `createMarket` returned.
        assertEq(token.metadataAdmin(), operator, "the operator owns its metadata");

        vm.prank(operator);
        token.setMetadata(
            PooledBrandToken.Metadata({
                description: "The dollar of the Starbase economy.",
                logo: "ipfs://bafkreistarbaselogo",
                socials: "https://x.com/starbase"
            })
        );
        assertEq(token.logo(), "ipfs://bafkreistarbaselogo", "the image is readable on chain");
        assertEq(token.description(), "The dollar of the Starbase economy.");
        assertEq(token.socials(), "https://x.com/starbase");

        // Nobody else can. An image is the first thing a user recognises a token by, so a
        // stranger being able to rewrite it is a phishing surface, not a cosmetic bug.
        vm.prank(buyer);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        token.setMetadata(
            PooledBrandToken.Metadata({description: "hijacked", logo: "evil", socials: ""})
        );
    }

    // ══ Step 2 ══ Seed ════════════════════════════════════════════════════

    /// @notice The operator brings USDG and the asset, and walks away holding a genuine
    ///         Uniswap LP NFT that they can exit without this repo's help.
    ///
    ///         The USDG→brandUSD mint happens inside the router, so the operator never has to
    ///         acquire the stablecoin as a separate step. That mint is also what puts the
    ///         market's float into the reserve, which is where every later step's yield
    ///         comes from — so this one call is both the depth and the income.
    function test_fork_step2_theOperatorSeedsAndOwnsARealPosition() public {
        _issue();

        uint256 expectedId = POSM.nextTokenId();
        (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed) = _seed();

        assertEq(tokenId, expectedId, "the id the router reported is the id minted");
        assertGt(liquidity, 0, "the position carries liquidity");
        assertGt(MANAGER.getLiquidity(poolId), 0, "and the market has depth");

        // Uniswap's NFT, in the operator's own wallet. Not a receipt of our invention, and not
        // held by the router on their behalf.
        assertEq(IPositionsNftLike(address(POSM)).name(), "Uniswap v4 Positions NFT");
        assertEq(IPositionsNftLike(address(POSM)).ownerOf(tokenId), operator, "operator owns it");

        // Both sides really went in, and the unused remainder came back rather than being
        // stranded in the router.
        assertGt(brandUsed, 0, "the stable side was used");
        assertGt(assetUsed, 0, "and so was the asset side");
        assertEq(IERC20(brandToken).balanceOf(address(router)), 0, "no stablecoin stranded");
        assertEq(IERC20(SPCX).balanceOf(address(router)), 0, "no asset stranded");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "no USDG stranded");

        // The float behind the seeded stablecoin is in the reserve, earning. A full-range mint
        // at a fixed price takes the two sides in the ratio the price implies, so the operator
        // minted more brandUSD than the position could consume and the router handed the
        // remainder back in the token it was given. Every minted dollar is therefore either in
        // the pool or in the operator's hands, and none of it was converted behind their back.
        uint256 operatorBrand = IERC20(brandToken).balanceOf(operator);
        assertEq(
            IERC20(brandToken).totalSupply(),
            brandUsed + operatorBrand,
            "every minted dollar is either in the position or back with the operator"
        );
        assertEq(
            IERC20(USDG).balanceOf(operator),
            500_000e6 - SEED_USDG,
            "and only the USDG the operator chose to mint against ever left their wallet"
        );

        // The remainder is spendable: redeeming it is 1:1, permissionless, and needs no router.
        vm.prank(operator);
        uint256 back = reservePool.redeem(brandToken, operatorBrand, operator);
        assertEq(back, operatorBrand, "the leftover redeems at par");
        console.log("market float now earning in Morpho (USDG, 6dp):", brandUsed);
    }

    // ══ Step 3 ══ Trade ═══════════════════════════════════════════════════

    /// @notice Both sides of the market pay the protocol's skim, and the money lands with the
    ///         protocol treasury.
    ///
    ///         Two directions in one test on purpose: they run through opposite currencies of
    ///         the `PoolKey`, so an ordering bug would show on exactly one of them. WHICH
    ///         currency each pays in is the part that moved when the skim moved into
    ///         `afterSwap`: the cut comes off the leg the caller did not name, both swaps
    ///         here are exact-input, and the unnamed leg of an exact-input swap is its
    ///         output. So the buy pays in SPCX and the sell pays in starUSD, each in the
    ///         token it receives rather than the one it hands over.
    function test_fork_step3_bothSidesPayTheSkimAndItReachesTheTreasury() public {
        _issue();
        _seed();

        bool brandFirst = _brandIsCurrency0();
        Currency brandCurrency = brandFirst ? poolKey.currency0 : poolKey.currency1;
        Currency assetCurrency = brandFirst ? poolKey.currency1 : poolKey.currency0;

        // A buy: stablecoin in, asset out, and the cut comes off the asset. The skim is pips
        // of what the pool actually paid out, so each expectation is quoted off the same swap
        // run with the hook's rate at zero rather than written as a constant.
        uint256 buyIn = 20_000e6;
        _mintBrandTo(buyer, buyIn);
        uint256 grossAsset = _grossOutWithoutTheSkim(brandFirst, buyIn, SPCX);
        uint256 expectedAsset = grossAsset * PROTOCOL_FEE_PIPS / 1_000_000;

        uint256 spcxBefore = IERC20(SPCX).balanceOf(buyer);
        _swap(brandFirst, buyIn);
        assertEq(
            IERC20(SPCX).balanceOf(buyer) - spcxBefore,
            grossAsset - expectedAsset,
            "the buyer received the pool's output less the skim, and nothing else was taken"
        );

        // A sell: asset in, stablecoin out, and the cut comes off the stablecoin. Quoted
        // after the buy, because the buy moved the price the sell fills at.
        uint256 sellIn = 20e18;
        uint256 grossBrand = _grossOutWithoutTheSkim(!brandFirst, sellIn, brandToken);
        uint256 expectedBrand = grossBrand * PROTOCOL_FEE_PIPS / 1_000_000;

        uint256 brandBefore = IERC20(brandToken).balanceOf(buyer);
        _swap(!brandFirst, sellIn);
        assertEq(
            IERC20(brandToken).balanceOf(buyer) - brandBefore,
            grossBrand - expectedBrand,
            "and the seller got starUSD back, less its own skim"
        );

        assertGt(expectedAsset, 0, "the buy owed something");
        assertGt(expectedBrand, 0, "and so did the sell");
        assertEq(feeHook.pendingFees(poolId, assetCurrency), expectedAsset, "buy side skimmed");
        assertEq(feeHook.pendingFees(poolId, brandCurrency), expectedBrand, "sell side skimmed");

        console.log("SPCX taken from the buy side:", expectedAsset);
        console.log("starUSD taken from the sell side:", expectedBrand);

        // Held as ERC-6909 claims inside the singleton until someone collects.
        assertEq(MANAGER.balanceOf(address(feeHook), assetCurrency.toId()), expectedAsset);
        assertEq(MANAGER.balanceOf(address(feeHook), brandCurrency.toId()), expectedBrand);

        // Permissionless: a stranger pays the gas and the protocol treasury gets the money.
        // Both sides of the skim, each in whichever currency its swap paid out.
        vm.prank(holder);
        feeHook.collect(poolKey);

        assertEq(
            IERC20(brandToken).balanceOf(protocolTreasury), expectedBrand, "stable to treasury"
        );
        assertEq(IERC20(SPCX).balanceOf(protocolTreasury), expectedAsset, "asset to treasury");
        assertEq(IERC20(brandToken).balanceOf(address(feeVault)), 0, "and none to the vault");
        assertEq(IERC20(SPCX).balanceOf(address(feeVault)), 0);
        assertEq(feeHook.pendingFees(poolId, brandCurrency), 0, "claims cleared");
        assertEq(feeHook.pendingFees(poolId, assetCurrency), 0);
    }

    /// @notice Asset that reaches the vault leaves as asset, to the protocol treasury.
    ///
    ///         Nothing routes SPCX to the vault — the buy-side skim is the protocol's and
    ///         goes to the treasury directly — so this leg catches donations and mistaken
    ///         transfers, which is exactly what it is fed here. It pays the protocol rather
    ///         than the market's LPs because the distributor pays in one token by design:
    ///         handing LPs a position in an arbitrary market token would be a reward they
    ///         never asked for, and the alternative to this call is asset stranded forever in
    ///         a contract with no other way to move it.
    function test_fork_step3_assetHeldByTheVaultIsRecoveredToTheProtocol() public {
        _issue();
        _seed();

        // The BUY is the leg that pays in SPCX: an exact-input swap is charged on the leg it
        // did not name, which is its output, and a buy outputs the asset.
        _mintBrandTo(buyer, 20_000e6);
        _swap(_brandIsCurrency0(), 20_000e6);
        feeHook.collect(poolKey);
        assertEq(IERC20(SPCX).balanceOf(address(feeVault)), 0, "the skim went to the treasury");

        // A donation, from the treasury that actually received the skim. The balance is read
        // into a local first: `vm.prank` arms the very next call, and an inline `balanceOf` in
        // the argument list would be the call it caught, leaving the transfer to run as this
        // test contract — which holds no SPCX.
        uint256 skimmed = IERC20(SPCX).balanceOf(protocolTreasury);
        vm.prank(protocolTreasury);
        IERC20(SPCX).transfer(address(feeVault), skimmed);

        uint256 held = IERC20(SPCX).balanceOf(address(feeVault));
        assertGt(held, 0, "the vault is holding SPCX");

        vm.prank(holder);
        uint256 recovered = feeVault.sweepStrayAsset();

        assertEq(recovered, held, "all of it moved");
        assertEq(IERC20(SPCX).balanceOf(protocolTreasury), skimmed, "and went back to the protocol");
        assertEq(feeVault.totalStrayAssetRecovered(), held, "counted as recovery, not income");
        assertEq(IERC20(SPCX).balanceOf(address(feeVault)), 0, "nothing left in the vault");
        assertEq(IERC20(SPCX).balanceOf(address(distributor)), 0, "and none reached the LPs");
    }

    // ══ Step 4 ══ Earn ════════════════════════════════════════════════════

    /// @notice The float behind the seeded stablecoin earns real Morpho interest, and the
    ///         harvest splits in two at the market's fixed rate: the protocol's cut, and
    ///         everything else to the market's liquidity providers.
    ///
    ///         This is the leg that makes the launch free to the operator: the market's income
    ///         is interest on money that had to sit somewhere anyway, not a cut of their raise.
    function test_fork_step4_floatYieldIsHarvestedAndSplit() public {
        _issue();
        _seed();

        assertEq(feeVault.pendingYield(), 0, "nothing has accrued yet");

        _accrueMorpho(180 days);

        uint256 pending = feeVault.pendingYield();
        assertGt(pending, 0, "real Morpho interest accrued to this brand");
        console.log("interest on the float over 180 days (USDG, 6dp):", pending);

        vm.prank(holder);
        uint256 claimed = feeVault.harvest();
        assertApproxEqAbs(claimed, pending, 1, "harvest pulls what was pending");
        assertEq(feeVault.balance(), claimed, "and it is sitting in the vault");

        uint256 treasuryBefore = IERC20(USDG).balanceOf(protocolTreasury)
            + IERC20(brandToken).balanceOf(protocolTreasury);

        assertGt(feeVault.lpBps(), 0, "this market keeps a share for its LPs");

        vm.prank(holder);
        (uint256 toProtocol, uint256 toLps) = feeVault.sweep();

        assertEq(toProtocol, claimed * PROTOCOL_BPS / 10_000, "the protocol's fixed share");
        assertEq(toLps, claimed - toProtocol, "and the rounding dust favours the LPs");
        assertEq(
            IERC20(USDG).balanceOf(protocolTreasury)
                + IERC20(brandToken).balanceOf(protocolTreasury) - treasuryBefore,
            toProtocol,
            "the treasury really received it"
        );

        // The distributor holds the LPs' share AND is streaming it. The notify is not
        // decoration: a vault that moved money without telling the distributor would leave the
        // reward sitting there unattributable, and no LP would ever be able to claim it. That
        // bug shipped once, against the contract that used to stand in the distributor's place.
        assertEq(
            IERC20(brandToken).balanceOf(address(distributor)), toLps, "the LPs' share arrived"
        );
        assertEq(distributor.periodFinish(), vm.getBlockTimestamp() + FIXTURE_REWARDS_DURATION);
        assertGt(distributor.rewardRate(), 0, "and is streaming");
        assertEq(feeVault.balance(), 0, "the vault kept nothing");
    }

    // ══ Step 5 ══ Reward ══════════════════════════════════════════════════

    /// @notice The float the market earned reaches the people who put up the liquidity, and
    ///         they take it in the market's own dollar.
    ///
    ///         This is the market's whole offer to an LP: the depth is paid for out of interest
    ///         on the float rather than out of a token emission. The position doing the earning
    ///         is the one step 2 minted — staking is what an LP does with it, and a position
    ///         left in the wallet earns none of this.
    function test_fork_step5_theSweptFloatIsStreamedToTheStakedLp() public {
        _issue();
        (uint256 tokenId,,,) = _seed();
        _stake(tokenId);

        // Income exactly as the earlier steps produce it, plus a top-up so the round is large
        // enough to read in the logs: interest on a 60,000 float over half a year is real but
        // small, and this leg is about where it goes rather than how much of it there is.
        _accrueMorpho(180 days);
        feeVault.harvest();
        _mintBrandTo(address(feeVault), 5_000e6);

        vm.prank(holder);
        (, uint256 toLps) = feeVault.sweep();
        assertGt(toLps, 0, "the LPs' share of the harvest");
        assertEq(
            IERC20(brandToken).balanceOf(address(distributor)), toLps, "handed to the distributor"
        );

        // Nothing is claimable the instant it arrives. The reward is a stream over the market's
        // reward period, so liquidity that stays is what gets paid, and a position flashed in
        // for one block earns a block's worth.
        assertEq(distributor.earned(operator), 0, "nothing has streamed yet");

        vm.warp(vm.getBlockTimestamp() + FIXTURE_REWARDS_DURATION);
        assertApproxEqAbs(
            distributor.earned(operator), toLps, 10, "a whole period pays the sole staker in full"
        );

        uint256 brandBefore = IERC20(brandToken).balanceOf(operator);
        vm.prank(operator);
        uint256 paid = distributor.claim(brandToken);
        console.log("starUSD paid to the market's only LP:", paid);

        assertApproxEqAbs(paid, toLps, 10, "the LP was paid the float");
        assertEq(
            IERC20(brandToken).balanceOf(operator) - brandBefore, paid, "in the market's dollar"
        );

        // And earning never cost them the position: it comes back on request, through a
        // withdrawal that no pause can block.
        vm.prank(operator);
        distributor.unstake(tokenId);
        assertEq(IPositionsNftLike(address(POSM)).ownerOf(tokenId), operator, "position returned");
    }

    // ══ Step 6 ══ Redeem ══════════════════════════════════════════════════

    /// @notice Someone who only ever wanted a stablecoin gets their USDG back at par, and the
    ///         market's fee machinery never touched their principal.
    ///
    ///         This is the claim that makes the branded stablecoin a stablecoin rather than a
    ///         launch token. The yield is the protocol's business model; the principal is not.
    function test_fork_step6_aHolderRedeemsBackToUsdgAtPar() public {
        _issue();
        _seed();

        uint256 amount = 25_000e6;
        vm.startPrank(holder);
        IERC20(USDG).approve(address(reservePool), amount);
        reservePool.mint(brandToken, amount, holder);
        vm.stopPrank();

        assertEq(IERC20(brandToken).balanceOf(holder), amount, "minted 1:1");

        // Trading, interest and a protocol harvest all happen around them.
        _tradeBothWays();
        feeHook.collect(poolKey);
        _accrueMorpho(180 days);
        feeVault.harvest();
        feeVault.sweep();

        uint256 usdgBefore = IERC20(USDG).balanceOf(holder);
        vm.prank(holder);
        // The 4-argument form: revert rather than pay out less than asked. A holder should
        // never discover a shortfall by receiving one.
        uint256 out = reservePool.redeem(brandToken, amount, holder, amount);

        assertEq(out, amount, "paid in full");
        assertEq(IERC20(USDG).balanceOf(holder) - usdgBefore, amount, "and the USDG arrived");
        assertEq(IERC20(brandToken).balanceOf(holder), 0, "the stablecoin was burned");
    }

    // ══ The whole thing ═══════════════════════════════════════════════════

    /// @notice Every step in order, on one market, with nothing funded by hand except the
    ///         starting balances a real operator and trader would already hold.
    ///
    ///         The steps above each isolate one leg. This one exists because the joins between
    ///         them are where the money actually goes, and a suite of isolated legs cannot see
    ///         a leg that fails to hand off. It ends by accounting for the whole journey:
    ///         what was skimmed, what was earned, what the protocol took, what the LPs were paid.
    function test_fork_theWholeJourneyEndToEnd() public {
        // 1. Issue.
        _issue();
        assertEq(IERC20(brandToken).totalSupply(), 0, "a brand new stablecoin has no supply");

        // 2. Seed, and put the position to work. The reward leg pays staked liquidity, so a
        //    position left in the wallet would carry the market's depth and none of its income.
        (uint256 tokenId,,,) = _seed();
        assertEq(IPositionsNftLike(address(POSM)).ownerOf(tokenId), operator);
        uint128 depth = MANAGER.getLiquidity(poolId);
        assertGt(depth, 0);

        _stake(tokenId);
        // Weight is the seeded capital, valued in `currency1`, rather than the raw depth.
        assertGt(distributor.stakedWeightOfPosition(tokenId), 0, "the seed carries weight");
        assertEq(
            distributor.totalStaked(),
            distributor.stakedWeightOfPosition(tokenId),
            "and the whole book is that one stake"
        );

        // 3. Trade, repeatedly, over a stretch of time long enough for the pool's oracle to
        //    have something to say.
        _buildOracleHistory();
        _tradeBothWays();

        bool brandFirst = _brandIsCurrency0();
        uint256 skimmedStable =
            feeHook.pendingFees(poolId, brandFirst ? poolKey.currency0 : poolKey.currency1);
        uint256 skimmedAsset =
            feeHook.pendingFees(poolId, brandFirst ? poolKey.currency1 : poolKey.currency0);
        // Exact-input swaps are charged on the leg they did not name, so the starUSD came
        // out of the sells' payout and the SPCX out of the buys'.
        assertGt(skimmedStable, 0, "the sells paid");
        assertGt(skimmedAsset, 0, "the buys paid");

        feeHook.collect(poolKey);

        // Both sides of the trading skim are the protocol's revenue and left for the treasury
        // when `collect` ran. Neither reaches the market.
        assertEq(IERC20(brandToken).balanceOf(protocolTreasury), skimmedStable);
        assertEq(IERC20(SPCX).balanceOf(protocolTreasury), skimmedAsset);

        // 4. Earn. The market's own income is the interest on its float, and that alone.
        _accrueMorpho(180 days);
        uint256 interest = feeVault.harvest();
        assertGt(interest, 0, "the float earned");

        // 5. Reward. The protocol takes its fixed share of what step 4 produced, the rest
        //    streams to the LP from step 2, and a whole period later they take it home.
        (uint256 toProtocol, uint256 toLps) = feeVault.sweep();
        assertEq(toProtocol + toLps, interest, "everything earned was distributed");
        assertEq(toProtocol, interest * PROTOCOL_BPS / 10_000, "at the fixed rate");

        vm.warp(vm.getBlockTimestamp() + FIXTURE_REWARDS_DURATION);
        vm.prank(operator);
        uint256 paidToLp = distributor.claim(brandToken);

        // 6. Redeem: an unrelated holder is unaffected by any of it.
        vm.startPrank(holder);
        IERC20(USDG).approve(address(reservePool), 10_000e6);
        reservePool.mint(brandToken, 10_000e6, holder);
        uint256 back = reservePool.redeem(brandToken, 10_000e6, holder, 10_000e6);
        vm.stopPrank();
        assertEq(back, 10_000e6, "par, throughout");

        // The accounts of one market's whole life.
        console.log("--- journey ---");
        console.log("starUSD skimmed from trades, to the protocol:", skimmedStable);
        console.log("SPCX skimmed from trades, to the protocol:", skimmedAsset);
        console.log("interest earned on the float:", interest);
        console.log("paid to the protocol treasury from yield:", toProtocol);
        console.log("streamed to the market's LPs:", toLps);
        console.log("claimed by the LP who seeded it:", paidToLp);

        assertApproxEqAbs(paidToLp, toLps, 10, "the LPs' share reached an actual LP");
        assertEq(feeVault.balance(), 0, "the vault holds nothing at rest");
        assertEq(IERC20(SPCX).balanceOf(address(feeVault)), 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address. `deployCodeTo`
    ///      puts the contract where we want it and still runs the constructor, so
    ///      `Hooks.validateHookPermissions` still executes. The `0x00EE` prefix keeps this
    ///      suite's hook clear of the addresses the sibling fork suites use.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x00EE << 144)
        );
        require(flags.code.length == 0, "hook address is occupied on the live chain");
        return _deployHookAt(flags, MANAGER, owner);
    }

    /// @dev Morpho Blue custodies tens of millions of USDG on this chain.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    /// @dev SPCX is an issuer-controlled beacon proxy, so `deal` cannot be trusted to find the
    ///      balance slot. The live V3 pool is a real holder, so real tokens are moved instead.
    function _fundSpcx(address to, uint256 amount) internal {
        vm.prank(LIVE_SPCX_USDG_POOL);
        IERC20(SPCX).transfer(to, amount);
    }

    /// @dev The live mid price of one whole SPCX in whole USDG, read off the real V3 pool so
    ///      this suite does not rot as the price moves.
    function _livePriceE18() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(LIVE_SPCX_USDG_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return Math.mulDiv(ratioX192, 1e18 * 1e12, 1 << 192);
    }

    /// @dev Step 1, in the two transactions a real launch takes: the owner lists SPCX with the
    ///      parameters every market of it is created under, and then anyone may open the market.
    ///      The operator sends the second one here so the journey has a named creator.
    function _issue() internal {
        _approveAsset(factory, SPCX, FEE, _livePriceE18(), 62, "Starbase Dollar", "starUSD");

        bytes32 rawPoolId;
        address vaultAddr;
        address distributorAddr;

        vm.prank(operator);
        (marketId, brandToken, vaultAddr, distributorAddr, rawPoolId) =
            factory.createMarket(SPCX, address(0));

        poolKey = factory.poolKeyOf(marketId);
        poolId = PoolId.wrap(rawPoolId);
        feeVault = BrandFeeVault(vaultAddr);
        distributor = LpRewardDistributor(distributorAddr);
    }

    /// @dev Step 2, as the operator would send it: USDG and the asset in, LP NFT out.
    function _seed()
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed)
    {
        vm.startPrank(operator);
        // The stable side the router takes is the market's own brandUSD. Minting it from USDG
        // is the seeder's own 1:1 call at the reserve, made before the approval below.
        IERC20(USDG).approve(address(reservePool), SEED_USDG);
        reservePool.mint(brandToken, SEED_USDG, operator);
        IERC20(brandToken).approve(address(router), SEED_USDG);
        IERC20(SPCX).approve(address(router), SEED_SPCX);
        (tokenId, liquidity, brandUsed, assetUsed) = router.seedLiquidity(
            marketId, SEED_USDG, SEED_SPCX, 0, 0, vm.getBlockTimestamp() + 1 hours
        );
        vm.stopPrank();
    }

    /// @dev What an LP does with the position step 2 handed them. The distributor pulls the
    ///      NFT out of their wallet, so it has to be approved to move it first.
    function _stake(uint256 tokenId) internal {
        vm.startPrank(operator);
        IPositionsNftLike(address(POSM)).approve(address(distributor), tokenId);
        distributor.stake(tokenId, operator);
        vm.stopPrank();
    }

    function _brandIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == brandToken;
    }

    /// @dev Mint brandUSD to someone out of this contract's own USDG.
    function _mintBrandTo(address to, uint256 amount) internal {
        IERC20(USDG).approve(address(reservePool), amount);
        reservePool.mint(brandToken, amount, to);
    }

    /// @dev An exact-input swap by `buyer`, through v4-core's reference router into the real
    ///      singleton. A real trader would arrive via an aggregator; what matters here is that
    ///      the caller is not ours, so the hook is exercised by a stranger's calldata.
    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.startPrank(buyer);
        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev The output the same swap produces with the hook's cut switched off, measured by
    ///      running it on a state snapshot and rolling the chain back.
    ///
    ///      A fee DECREASE applies immediately, so what is quoted is the identical pool at
    ///      identical depth paying the identical LP fee, with only the skim missing. That is
    ///      this suite's stand-in for a hookless twin pool, and it is why the step-3
    ///      expectations are an independently measured number rather than a restatement of
    ///      the hook's own arithmetic.
    function _grossOutWithoutTheSkim(bool zeroForOne, uint256 amountIn, address tokenOut)
        internal
        returns (uint256 gross)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        feeHook.setPoolFeePips(poolId, 0);
        uint256 before = IERC20(tokenOut).balanceOf(buyer);
        _swap(zeroForOne, amountIn);
        gross = IERC20(tokenOut).balanceOf(buyer) - before;
        vm.revertToState(snap);
    }

    /// @dev One buy and one sell, the ordinary two-sided traffic a market sees.
    function _tradeBothWays() internal {
        bool brandFirst = _brandIsCurrency0();
        _mintBrandTo(buyer, 20_000e6);
        _swap(brandFirst, 20_000e6);
        _swap(!brandFirst, 20e18);
    }

    /// @dev Give the pool's oracle a history to be read across: the market's price chart, and
    ///      anything that consults a tick, needs observations, and an observation is written by
    ///      a swap, so time alone is not enough.
    function _buildOracleHistory() internal {
        _mintBrandTo(buyer, 2_000e6);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 15 minutes);
            vm.roll(block.number + 1);
            _swap(_brandIsCurrency0(), 500e6);
        }
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vm.roll(block.number + 1);
    }

    /// @dev Real Morpho interest. See `IMorphoAccrue`.
    function _accrueMorpho(uint256 elapsed) internal {
        vm.warp(vm.getBlockTimestamp() + elapsed);
        IMorphoAccrue m = IMorphoAccrue(MORPHO_BLUE);
        m.accrueInterest(m.idToMarketParams(USDE_MARKET_ID));
    }
}
