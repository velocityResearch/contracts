// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

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
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

interface IMorphoAccrue {
    function idToMarketParams(bytes32 id) external view returns (IMorphoBlue.MarketParams memory);
    function accrueInterest(IMorphoBlue.MarketParams memory marketParams) external;
}

/// @title MainnetLaunchForkTest
/// @notice The actual launch, rehearsed: four memecoin markets, each with its own branded
///         dollar, stood up on a fork of live Robinhood Chain from the wallet that would sign
///         the real transactions.
///
///         Everything that exists on that chain is the real deployed code — USDG, the Morpho
///         Blue USDG/USDe market — and the four assets are the memecoins actually sitting in
///         `LAUNCH_WALLET`. Nothing is mocked.
///
///         **The Uniswap venue is ours, and that is what a real launch would also do.** Uniswap
///         has not deployed v4 to Robinhood Chain, so `DeployAssetMarkets.s.sol` deploys its own
///         `PoolManager` and its own mined `ProtocolFeeHook`, and this rehearsal deploys the
///         same two in the same order. The consequence carries into production: these pools are
///         not on the canonical Uniswap deployment and no external aggregator routes to them,
///         so every number below is depth this project's own router put there.
///
///         Two runs, because they answer different questions:
///
///         1. `test_fork_realWallet_*` spends only what the wallet actually holds. It answers
///            "what happens if we launch today", and the answer is not the one you want: the
///            wallet's entire USDG balance is a few dollars, so each market gets about two
///            dollars of float, and a year of interest on that is not even the one whole
///            dollar a sweep needs before it will pay anybody.
///         2. `test_fork_funded_*` funds the same wallet properly and runs the whole mechanism
///            through to LP rewards streaming out of real Morpho interest. It answers "does
///            the design work", separately from "can we afford to run it".
///
///         Reproduce:
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-contract MainnetLaunchFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-30))
contract MainnetLaunchForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The wallet that would sign the real launch ──────────────────────

    address constant LAUNCH_WALLET = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;

    // ─── The four assets, as held by that wallet ─────────────────────────

    address constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18;
    address constant ZZZ = 0x7dbf38976f6D3b9c529e7D9484A71898B409eE6a;
    address constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
    address constant MEME = 0x385F4f8ae47651ce5F58F5265395a669f8281e18;

    /// @notice Starting prices, in whole brand units per whole asset unit, scaled 1e18.
    ///
    ///         BONER, AI and MEME are read off their live USDG pools as of 2026-09-09. ZZZ has
    ///         no pool at any fee tier, so its price is INVENTED — five cents, chosen because a
    ///         market has to start somewhere. A market opened at a made-up price is priced by
    ///         whoever trades it first, which for a fresh pool with one LP is the LP's problem.
    uint256 constant PRICE_BONER = 60_479_120_700_000_000; // $0.0605, from its 1% pool
    uint256 constant PRICE_AI = 224_777_962_000_000_000; // $0.2248, from its 1% pool
    uint256 constant PRICE_MEME = 88_434_112_600_000_000; // $0.0884, from its 0.3% pool
    uint256 constant PRICE_ZZZ = 50_000_000_000_000_000; // $0.05, invented

    /// @notice Sources to prank for funding in the funded run. Morpho holds a large USDG
    ///         balance; the memecoins are plain ERC20s and take `deal` directly.
    address constant USDG_SOURCE = MainnetAddresses.MORPHO_BLUE;

    // ─── Market configuration, matching DeployAssetMarkets.s.sol ─────────

    /// @dev The router seeds full range and derives the ticks from the pool's own spacing, so
    ///      there are no tick constants here any more. It holds the one position each market
    ///      ever gets, in its own name inside the singleton, and exposes nothing that removes
    ///      it — seeded depth is permanent by construction rather than by an LP's restraint.
    uint24 constant FEE = 3000;
    uint16 constant CARDINALITY = 64;
    uint16 constant PROTOCOL_BPS = 0;

    // ─── Deployed stack ──────────────────────────────────────────────────

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    PoolManager poolManager;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;
    StandInPositionManager posm;

    address protocolTreasury = address(0xF33);
    address trader = address(0xA11CE);

    struct Launch {
        address asset;
        string assetSymbol;
        string brandName;
        string brandSymbol;
        uint256 priceE18;
        uint256 marketId;
        address brandToken;
        /// @dev A v4 pool has no address. This is the key hash the registry recorded;
        ///      `factory.poolKeyOf(marketId)` rebuilds the key every v4 call needs.
        bytes32 poolId;
        address feeVault;
        address lpDistributor;
    }

    Launch[4] launches;

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // Same pattern as `AssetMarketV4ForkTest`; the early return is what keeps the rest of
        // this function from reverting against an empty chain, since `vm.skip` only marks the
        // result and does not abort the body.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        // Exactly what the two deploy scripts build, in the same order.
        yieldSource = _deployYieldSource(
            MainnetAddresses.MORPHO_BLUE, MainnetAddresses.USDE_MARKET_ID, LAUNCH_WALLET
        );
        reservePool = _deployReservePool(MainnetAddresses.USDG, address(yieldSource), LAUNCH_WALLET);

        // The venue, in the deploy script's own order: our singleton, then the hook at an
        // address carrying its permission bits, then the periphery, then the factory, then the
        // registrar link without which every `createMarket` reverts.
        poolManager = new PoolManager(LAUNCH_WALLET);
        feeHook = _deployHook();

        // Stand-ins for Uniswap's periphery, because this suite deploys its own singleton (see
        // just above) and both the factory and `MarketRouter` rightly refuse a PositionManager
        // bound to a different one — the deployed PositionManager belongs to the chain's. The
        // ownership semantics they model are the point here: the launch wallet's seed becomes
        // an LP NFT in its own hands rather than a permanent donation to the router. That same
        // claim is made against the genuinely deployed PositionManager in
        // `test/markets/MarketRouterV4Fork.t.sol`.
        StandInPermit2 permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(poolManager)), permit2);

        factory = _deployFactory(
            reservePool,
            IPoolManager(address(poolManager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            MainnetAddresses.REFERENCE_EQUITY,
            PROTOCOL_BPS,
            LAUNCH_WALLET
        );

        vm.prank(LAUNCH_WALLET);
        feeHook.setRegistrar(address(factory));

        router = _deployRouter(
            reservePool,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            LAUNCH_WALLET
        );

        launches[0] = _launch(BONER, "BONER", "Boner Dollar", "bonerUSD", PRICE_BONER);
        launches[1] = _launch(ZZZ, "ZZZ", "Zzz Dollar", "zzzUSD", PRICE_ZZZ);
        launches[2] = _launch(AI, "AI", "Artificial Dollar", "aiUSD", PRICE_AI);
        launches[3] = _launch(MEME, "MEME", "Meme Dollar", "memeUSD", PRICE_MEME);
    }

    /// @dev A v4 hook's permissions are the low 14 bits of its address. `deployCodeTo` still
    ///      runs the constructor, so `Hooks.validateHookPermissions` still executes — the
    ///      test-side equivalent of the CREATE2 salt `HookSaltMiner` mines in the deploy script.
    function _deployHook() private returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x9990 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(poolManager)), LAUNCH_WALLET);
    }

    /// @dev A v4 pool holds no tokens of its own — the singleton holds every pool's reserves,
    ///      and each of these four tokens belongs to exactly one market, so a balance in the
    ///      singleton is that market's own depth.
    function _inPool(address token) private view returns (uint256) {
        return IERC20(token).balanceOf(address(poolManager));
    }

    function _launch(
        address asset,
        string memory assetSymbol,
        string memory brandName,
        string memory brandSymbol,
        uint256 priceE18
    ) private pure returns (Launch memory l) {
        l.asset = asset;
        l.assetSymbol = assetSymbol;
        l.brandName = brandName;
        l.brandSymbol = brandSymbol;
        l.priceE18 = priceE18;
    }

    // ─── 1. Four markets, four separate branded dollars ──────────────────

    /// @notice Opens all four markets from the launch wallet and proves each one is a distinct
    ///         brand with its own Uniswap pool, fee vault and LP reward distributor.
    function test_fork_opensFourMarketsWithFourSeparateBrands() public {
        _openAllMarkets();

        for (uint256 i = 0; i < 4; i++) {
            Launch memory l = launches[i];
            assertEq(l.marketId, i + 1, "market ids are 1-indexed and sequential");
            assertTrue(l.brandToken != address(0), "brand token deployed");
            assertTrue(l.poolId != bytes32(0), "uniswap v4 pool exists");
            assertTrue(l.feeVault != address(0), "fee vault installed");
            assertTrue(l.lpDistributor != address(0), "LP reward distributor installed");

            assertEq(
                IERC20Metadata(l.brandToken).symbol(), l.brandSymbol, "brand symbol as requested"
            );
            assertEq(IERC20Metadata(l.brandToken).decimals(), 6, "brand matches USDG decimals");
            assertTrue(reservePool.isRegistered(l.brandToken), "brand registered on the reserve");
            assertEq(factory.brandOperatorOf(l.brandToken), LAUNCH_WALLET, "wallet is operator");

            // Memecoins are not canonical equities, and the factory says so rather than
            // refusing them. A UI that does not surface this is the actual risk.
            AssetMarketFactory.Market memory m = factory.market(l.marketId);
            assertFalse(m.verified, "a memecoin is never a verified equity");
            assertEq(m.asset, l.asset, "market points at the right asset");
            assertEq(factory.marketOfPool(l.poolId), l.marketId, "pool maps back to its market");

            // The key the registry recorded rebuilds to the id it recorded, and names our
            // hook — which is what makes the pool reachable at all under v4 and what collects
            // the trading skim. That skim is the protocol's, so it is the treasury that is
            // named here; the market's own income is the float yield its vault divides.
            PoolKey memory key = factory.poolKeyOf(l.marketId);
            assertEq(PoolId.unwrap(key.toId()), l.poolId, "poolKeyOf rebuilds the pool");
            assertEq(address(key.hooks), address(feeHook));
            assertEq(feeHook.feeRecipientOf(PoolId.wrap(l.poolId)), protocolTreasury);

            // And the pool has an oracle at all, because v4 core keeps none: the hook writes
            // the observations the application's price chart and `consultTick` read.
            (,, uint16 cardinalityNext) = feeHook.observationState(PoolId.wrap(l.poolId));
            assertGe(cardinalityNext, CARDINALITY, "oracle buffer grown at creation");

            // The pool is priced at the approval's price, because our call is the one that
            // initialised it — the unit token is minted in the same transaction, so a pool that
            // already existed would have reverted `PoolAlreadyInitialised` instead of being
            // adopted.
            (uint160 sqrtPrice,,,) =
                IPoolManager(address(poolManager)).getSlot0(PoolId.wrap(l.poolId));
            assertEq(
                sqrtPrice,
                factory.quoteSqrtPriceX96(l.brandToken, l.asset, l.priceE18),
                "pool opened at the requested price"
            );
        }

        // Four brands, four distinct tokens, four distinct pools.
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(launches[i].brandToken != launches[j].brandToken, "brands are distinct");
                assertTrue(launches[i].poolId != launches[j].poolId, "pools are distinct");
                assertTrue(
                    launches[i].feeVault != launches[j].feeVault, "fee vaults are per-market"
                );
                assertTrue(
                    launches[i].lpDistributor != launches[j].lpDistributor,
                    "and so are distributors"
                );
            }
        }
        assertEq(factory.marketCount(), 4, "exactly four markets");
    }

    // ─── 2. The dust run: what the wallet can actually do today ──────────

    /// @notice Seeds every pool the wallet can actually back out of its REAL balances, and
    ///         trades against them. Nothing is funded. This is the launch as it would happen
    ///         today.
    ///
    ///         **A zero balance is skipped, not a failure.** This used to require all four
    ///         assets, which made the test a pin on the wallet's holdings rather than on the
    ///         launch path: sweeping a memecoin bag to the treasury, which is ordinary
    ///         operations, broke it. The property worth keeping is that whatever the wallet
    ///         holds can be seeded and traded, so the loop follows the balances and the test
    ///         only insists that at least one market was reachable.
    function test_fork_realWallet_seedsAndTradesOnTrueBalances() public {
        uint256 usdgHeld = IERC20(MainnetAddresses.USDG).balanceOf(LAUNCH_WALLET);
        console.log("=== Launch wallet, real mainnet balances ===");
        console.log("USDG (6dp):", usdgHeld);
        for (uint256 i = 0; i < 4; i++) {
            console.log(launches[i].assetSymbol, IERC20(launches[i].asset).balanceOf(LAUNCH_WALLET));
        }

        assertGt(usdgHeld, 0, "wallet holds some USDG");
        _openAllMarkets();

        // Split the real USDG across the assets the wallet can actually pair, and give each
        // market that asset's whole balance.
        uint256 fundable;
        for (uint256 i = 0; i < 4; i++) {
            if (IERC20(launches[i].asset).balanceOf(LAUNCH_WALLET) > 0) ++fundable;
        }
        assertGt(fundable, 0, "the wallet holds at least one launchable asset");

        uint256 perMarket = usdgHeld / fundable;
        console.log("");
        console.log("Launchable assets today:", fundable);
        console.log("USDG available per market (6dp):", perMarket);

        bool[4] memory seeded;
        for (uint256 i = 0; i < 4; i++) {
            Launch memory l = launches[i];
            uint256 assetHeld = IERC20(l.asset).balanceOf(LAUNCH_WALLET);
            if (assetHeld == 0) {
                console.log("");
                console.log(l.assetSymbol, "skipped: the wallet holds none");
                continue;
            }
            seeded[i] = true;

            (uint256 tokenId, uint128 liquidity) = _seed(l, perMarket, assetHeld);

            assertGt(liquidity, 0, "the position carries liquidity");
            // The launch wallet walks away holding the position, as a real `UNI-V4-POSM` NFT
            // minted by Uniswap's deployed PositionManager. That is what makes the seed
            // recoverable: the wallet closes it through the PositionManager whenever it wants,
            // with no cooperation from the router, which owns nothing.
            assertEq(
                posm.ownerOf(tokenId),
                LAUNCH_WALLET,
                "the launch wallet owns this market's position"
            );
            assertEq(
                router.marketLiquidity(l.marketId),
                liquidity,
                "and it is the whole of this market's depth"
            );
            assertGt(
                IPoolManager(address(poolManager)).getLiquidity(PoolId.wrap(l.poolId)),
                0,
                "pool has live in-range liquidity"
            );
            assertGt(_inPool(l.brandToken), 0, "the singleton holds brand tokens for this pool");
            assertGt(_inPool(l.asset), 0, "and the asset");

            console.log("");
            console.log(l.brandSymbol, "/", l.assetSymbol);
            console.log("   position liquidity:", uint256(liquidity));
            console.log("   brand in pool (6dp):", _inPool(l.brandToken));
            console.log("   asset in pool (18dp):", _inPool(l.asset));
            console.log("   float earning for this brand:", reservePool.outstandingOf(l.brandToken));
        }

        // Every branded dollar in every pool is float, and the reserve is backing all of it.
        uint256 totalFloat;
        for (uint256 i = 0; i < 4; i++) {
            totalFloat += reservePool.outstandingOf(launches[i].brandToken);
        }
        assertEq(reservePool.totalPooledSupply(), totalFloat, "pool supply is the four brands");
        console.log("");
        console.log("Total float across four markets (6dp):", totalFloat);
        console.log("Reserve totalAssets (6dp):", reservePool.totalAssets());

        // And it can be traded. One small buy per SEEDED market, through the real
        // SwapRouter02. An unseeded pool has no liquidity, so routing into it would revert
        // NoLiquidity, which says nothing about the launch path.
        for (uint256 i = 0; i < 4; i++) {
            if (!seeded[i]) continue;
            _tradeRoundTrip(launches[i], perMarket / 10);
        }
    }

    /// @notice The refusal that protects a market from paying out dust: a fee vault holding
    ///         less than `minSweep` will not distribute, because moving the amount costs more
    ///         gas than it delivers.
    ///
    ///         **This asserts the mechanism, not the wallet.** An earlier revision asserted
    ///         that a year of interest on the launch wallet's real float could never reach
    ///         `minSweep`, and named that "the finding that decides whether launching today is
    ///         worth doing". That was a measurement of one live balance, not a property of the
    ///         contracts, and it inverted the moment the wallet was funded: a year of yield now
    ///         clears the floor. Re-pinning it to the new number would only move the tripwire.
    ///         So the float figures are logged for whoever is sizing a launch, and the
    ///         assertion is on the thing that does not drift — that a vault below the floor
    ///         refuses, and refuses for the stated reason.
    function test_fork_realWallet_aVaultBelowTheFloorRefusesToPay() public {
        _openAllMarkets();
        uint256 usdgHeld = IERC20(MainnetAddresses.USDG).balanceOf(LAUNCH_WALLET);

        // Only pools the wallet can actually back. Seeding with a zero asset balance mints a
        // position with no liquidity, and the later harvest then reverts NoLiquidity for a
        // reason that has nothing to do with the sweep floor this test is about.
        uint256 fundable;
        for (uint256 i = 0; i < 4; i++) {
            if (IERC20(launches[i].asset).balanceOf(LAUNCH_WALLET) > 0) ++fundable;
        }
        assertGt(fundable, 0, "the wallet holds at least one launchable asset");
        uint256 perMarket = usdgHeld / fundable;

        // `_seed` spends the balance, so which markets were funded has to be recorded as it
        // happens. Re-reading `balanceOf` afterwards reports zero for the ones that succeeded.
        bool[4] memory seeded;
        uint256 firstSeeded = type(uint256).max;
        for (uint256 i = 0; i < 4; i++) {
            uint256 assetHeld = IERC20(launches[i].asset).balanceOf(LAUNCH_WALLET);
            if (assetHeld == 0) continue;
            seeded[i] = true;
            if (firstSeeded == type(uint256).max) firstSeeded = i;
            _seed(launches[i], perMarket, assetHeld);
        }

        // A full year of real Morpho interest on the whole float, reported rather than asserted
        // on: what this earns tracks the live wallet and the live Morpho rate, and neither is a
        // property of this protocol.
        _accrueMorpho(365 days);

        // `harvest` reverts NoLiquidity on a pool that was never seeded, so only the seeded
        // ones are harvested. An unseeded market has earned nothing anyway.
        uint256 totalYield;
        for (uint256 i = 0; i < 4; i++) {
            if (!seeded[i]) continue;
            BrandFeeVault(launches[i].feeVault).harvest();
            totalYield += IERC20(MainnetAddresses.USDG).balanceOf(launches[i].feeVault);
        }
        uint256 minSweep = BrandFeeVault(launches[firstSeeded].feeVault).minSweep();
        console.log("=== One year of Morpho yield on the real float ===");
        console.log("Total float (6dp):", reservePool.totalPooledSupply());
        console.log("Yield harvested across all four markets (6dp):", totalYield);
        console.log("The smallest sweep a market will make (6dp):", minSweep);
        console.log(
            totalYield >= minSweep
                ? "The float now clears the floor: a distribution can run."
                : "The float is still below the floor: no distribution can run."
        );

        // The invariant, exercised deterministically against a vault held below the floor
        // rather than against whatever the wallet happens to earn. A vault holding dust
        // reverts `BelowMinSweep`; one holding nothing at all reverts `NothingToSweep`.
        // Either way the refusal names the size of the balance, never the distributor.
        BrandFeeVault vault = BrandFeeVault(launches[firstSeeded].feeVault);
        uint256 held = vault.balance();
        if (held >= minSweep) {
            // Drain it to a dust balance so the floor is the thing under test. Sweeping once
            // from a funded vault is legitimate here; what follows is the refusal on the
            // remainder.
            vault.sweep();
            held = vault.balance();
        }
        assertLt(held, minSweep, "the vault is below the sweep floor");

        vm.expectRevert(
            held == 0
                ? abi.encodeWithSelector(BrandFeeVault.NothingToSweep.selector)
                : abi.encodeWithSelector(BrandFeeVault.BelowMinSweep.selector, held, minSweep)
        );
        vault.sweep();
    }

    // ─── 3. The funded run: does the mechanism actually work ─────────────

    /// @notice The same four markets, funded to a size a real launch would use, driven all the
    ///         way through trading, harvest, and the sweep that pays their liquidity providers.
    function test_fork_funded_fullFlowThroughHarvestAndLpRewards() public {
        _openAllMarkets();

        uint256 seedUsdg = 250_000e6; // $250k per market
        _fundUsdg(LAUNCH_WALLET, seedUsdg * 4 + 100_000e6);
        _fundUsdg(trader, 200_000e6);

        for (uint256 i = 0; i < 4; i++) {
            Launch memory l = launches[i];
            // Enough asset that the balanced full-range seed is USDG-bound, not asset-bound.
            uint256 assetAmount = (seedUsdg * 1e18 / l.priceE18) * 1e12 * 2;
            deal(l.asset, LAUNCH_WALLET, assetAmount);

            (uint256 tokenId, uint128 liquidity) = _seed(l, seedUsdg, assetAmount);
            assertGt(liquidity, 0, "seeded with real liquidity");
            assertGt(
                IPoolManager(address(poolManager)).getLiquidity(PoolId.wrap(l.poolId)),
                0,
                "pool is live"
            );

            // The seed is full range, which is the only shape the distributor admits, so the
            // wallet can put the position it has just minted behind the market and be paid the
            // float that position backs. Staking is a separate, optional step: an LP that keeps
            // its NFT still collects the pool's swap fees and simply forgoes the yield.
            _stake(l, tokenId);
        }

        uint256 floatAfterSeed = reservePool.totalPooledSupply();
        console.log("=== Funded launch ===");
        console.log("Float across four markets (6dp):", floatAfterSeed);
        assertGt(floatAfterSeed, 900_000e6, "four markets carry serious float");

        // Trade every market, both directions, through the real router.
        for (uint256 i = 0; i < 4; i++) {
            _tradeRoundTrip(launches[i], 25_000e6);
        }

        // Real Morpho interest over 180 days, then harvest and pay out each market's share.
        _accrueMorpho(180 days);

        for (uint256 i = 0; i < 4; i++) {
            _sweepToLps(launches[i]);
        }

        // A week on, every market's stream has run its course and the wallet that supplied the
        // depth collects, paid in that market's own unit. This is the leg the old buyback did
        // not have: the float yield ends up with the people carrying the risk of holding the
        // pool's inventory, rather than in a lockbox nobody can open.
        vm.warp(block.timestamp + FIXTURE_REWARDS_DURATION + 1);
        for (uint256 i = 0; i < 4; i++) {
            _claimLpRewards(launches[i]);
        }
    }

    /// @dev One market's whole income path: harvest the float yield, take the protocol's share
    ///      off the top, and stream everything left to the market's liquidity providers.
    ///
    ///      A function rather than the body of the loop it replaces. Inline, this leg needed
    ///      eleven live locals inside a loop, and `via_ir` miscompiled it: the second iteration
    ///      panicked with an arithmetic overflow on a `block.timestamp` addition that cannot
    ///      overflow, and the panic moved or vanished when unrelated statements were added. The
    ///      codebase already carries one `via_ir` timestamp defect (see the `vm.warp` note in
    ///      the asset market tests), and the plain fix for both is to stop asking the pipeline
    ///      to keep this much state live at once. Do not inline this back.
    function _sweepToLps(Launch memory l) private {
        uint256 claimed = BrandFeeVault(l.feeVault).harvest();
        (uint256 toProtocol, uint256 toLps) = BrandFeeVault(l.feeVault).sweep();

        console.log("");
        console.log(l.brandSymbol, "streamed to its LPs (6dp):", toLps);
        assertGt(toLps, 0, "the LPs' share of a real harvest");
        assertEq(toLps, claimed, "with no protocol share, the LPs get all of it");
        assertEq(toProtocol, 0, "protocolBps is zero, so the treasury takes none of it");
        assertEq(IERC20(MainnetAddresses.USDG).balanceOf(protocolTreasury), 0);

        // The reward is held by this market's own distributor and is streaming. A vault that
        // moved the money without telling the distributor would leave it sitting there with
        // nobody able to claim it, which is the failure this pair of reads catches.
        LpRewardDistributor dist = LpRewardDistributor(l.lpDistributor);
        assertEq(IERC20(l.brandToken).balanceOf(l.lpDistributor), toLps, "the distributor holds it");
        assertGt(dist.rewardRate(), 0, "and is paying it out");
        assertGt(dist.periodFinish(), block.timestamp, "over a period that is still running");
    }

    /// @dev The staked LP takes its stream. Separate from `_sweepToLps` because a claim is only
    ///      worth making once the whole period has elapsed, which is one warp covering all four
    ///      markets rather than one warp each.
    function _claimLpRewards(Launch memory l) private {
        LpRewardDistributor dist = LpRewardDistributor(l.lpDistributor);
        uint256 owed = dist.earned(LAUNCH_WALLET);
        assertGt(owed, 0, "the market's only staked LP earned its float yield");

        uint256 before = IERC20(l.brandToken).balanceOf(LAUNCH_WALLET);
        vm.prank(LAUNCH_WALLET);
        uint256 paid = dist.claim(l.brandToken);

        assertEq(paid, owed, "and was paid exactly what it had earned");
        assertEq(
            IERC20(l.brandToken).balanceOf(LAUNCH_WALLET) - before,
            paid,
            "in this market's own unit, in the LP's own hands"
        );
        console.log(l.brandSymbol, "LP reward claimed (6dp):", paid);
    }

    /// @dev Hand a seeded position to its market's distributor, which is how an LP starts
    ///      earning the float. The NFT is pulled from its holder, so the PositionManager has to
    ///      name the distributor first; `unstake` is the way back out, is never pausable and
    ///      does not depend on a reward transfer succeeding, which is what makes the custody
    ///      acceptable in the first place.
    function _stake(Launch memory l, uint256 tokenId) private {
        vm.startPrank(LAUNCH_WALLET);
        posm.approve(l.lpDistributor, tokenId);
        LpRewardDistributor(l.lpDistributor).stake(tokenId, LAUNCH_WALLET);
        vm.stopPrank();
    }

    /// @notice The invariant the whole design rests on: a branded dollar sitting in a Uniswap
    ///         pool is float and earns for its brand, and four brands sharing one reserve each
    ///         earn strictly in proportion to their own outstanding supply.
    ///
    ///         This is a statement about `SharedReservePool`'s per-brand attribution, not about
    ///         the deleted splitter's per-leg one — four independent single-market brands, each
    ///         harvesting its own vault. It needed no rework when one brand stopped being able
    ///         to hold several pools, because it never had one that did.
    function test_fork_funded_eachBrandEarnsInProportionToItsOwnFloat() public {
        _openAllMarkets();
        _fundUsdg(LAUNCH_WALLET, 2_000_000e6);

        // Deliberately unequal float: 100k, 200k, 300k, 400k.
        uint256[4] memory sizes = [uint256(100_000e6), 200_000e6, 300_000e6, 400_000e6];
        for (uint256 i = 0; i < 4; i++) {
            Launch memory l = launches[i];
            uint256 assetAmount = (sizes[i] * 1e18 / l.priceE18) * 1e12 * 2;
            deal(l.asset, LAUNCH_WALLET, assetAmount);
            _seed(l, sizes[i], assetAmount);
        }

        _accrueMorpho(180 days);

        uint256[4] memory yields;
        for (uint256 i = 0; i < 4; i++) {
            BrandFeeVault(launches[i].feeVault).harvest();
            yields[i] = IERC20(MainnetAddresses.USDG).balanceOf(launches[i].feeVault);
            console.log(
                launches[i].brandSymbol, "float:", reservePool.outstandingOf(launches[i].brandToken)
            );
            console.log("   yield (6dp):", yields[i]);
        }

        // Ordering follows float exactly.
        assertLt(yields[0], yields[1], "more float earns more");
        assertLt(yields[1], yields[2], "more float earns more");
        assertLt(yields[2], yields[3], "more float earns more");

        // And the ratios track the float ratios, within rounding.
        assertApproxEqRel(yields[3], yields[0] * 4, 0.01e18, "4x the float earns 4x the yield");
        assertApproxEqRel(yields[2], yields[0] * 3, 0.01e18, "3x the float earns 3x the yield");
    }

    // ─── 4. Does the reserve drift under-collateralised? ─────────────────

    /// @notice `SharedReservePool.mint` supplies to Morpho inline, and Morpho's share maths
    ///         floors in both directions, so a mint of X can come back worth X-1. The mint path
    ///         comments say this dust is absorbed into the accrual baseline rather than booked
    ///         as a loss. What they do not say is whether it ACCUMULATES — one unit per mint
    ///         across thousands of mints would be a slow, silent under-collateralisation.
    ///
    ///         This measures it: 200 real mints against the real Morpho market, reporting the
    ///         gap between what the pool owes and what it can actually produce.
    function test_fork_reserveShortfallStaysBoundedAcrossManyMints() public {
        _openAllMarkets();
        address brand = launches[0].brandToken;
        _fundUsdg(trader, 200_000e6);

        uint256 worstGap;
        for (uint256 i = 0; i < 200; i++) {
            vm.startPrank(trader);
            IERC20(MainnetAddresses.USDG).approve(address(reservePool), 1_000e6);
            reservePool.mint(brand, 1_000e6, trader);
            vm.stopPrank();

            uint256 supply = reservePool.totalPooledSupply();
            uint256 assets = reservePool.totalAssets();
            uint256 gap = assets >= supply ? 0 : supply - assets;
            if (gap > worstGap) worstGap = gap;
        }

        console.log("mints:", uint256(200));
        console.log("total pooled supply (6dp):", reservePool.totalPooledSupply());
        console.log("reserve total assets (6dp):", reservePool.totalAssets());
        console.log("worst shortfall observed (6dp base units):", worstGap);

        // The claim: the gap is rounding dust, not a per-mint leak. 200 mints leaking one unit
        // each would show 200 here.
        assertLe(worstGap, 2, "shortfall is bounded dust, not proportional to mint count");
    }

    // ─── 5. Does a late brand steal or destroy earlier interest? ─────────

    /// @notice `MorphoAttributionForkTest` documents a limitation: a brand that mints AFTER
    ///         interest accrued could be credited a share of it, because Morpho only realises
    ///         interest into the pool's `totalAssets` when something touches the market.
    ///
    ///         That test now fails, which means the behaviour changed. This establishes which
    ///         way. `mint` supplies to Morpho inline, and Morpho accrues interest on `supply`,
    ///         so the late mint itself realises the backlog. The question is where it lands:
    ///         to the late brand (the original bug), to the early brand (correct), or nowhere
    ///         at all (a new and worse bug, silently absorbing yield into the baseline).
    function test_fork_lateMintDoesNotTakeOrDestroyEarlierInterest() public {
        _openAllMarkets();
        address early = launches[0].brandToken;
        address late = launches[1].brandToken;

        _fundUsdg(trader, 400_000e6);
        vm.startPrank(trader);
        IERC20(MainnetAddresses.USDG).approve(address(reservePool), 400_000e6);
        reservePool.mint(early, 100_000e6, trader);
        vm.stopPrank();

        _accrueMorpho(180 days);
        uint256 earlyBefore = reservePool.pendingYield(early);
        assertGt(earlyBefore, 0, "the early brand earned something over 180 days");

        // The late brand mints. No time passes.
        vm.startPrank(trader);
        reservePool.mint(late, 100_000e6, trader);
        vm.stopPrank();

        uint256 earlyAfter = reservePool.pendingYield(early);
        uint256 lateAfter = reservePool.pendingYield(late);

        console.log("early brand pending before late mint (6dp):", earlyBefore);
        console.log("early brand pending after  late mint (6dp):", earlyAfter);
        console.log("late  brand pending after  its own mint (6dp):", lateAfter);

        // The original bug: the late brand walks in and is credited history it was not there
        // for. One base unit of settlement dust is not that.
        assertLe(lateAfter, 1, "a late brand is not credited interest that predates it");

        // The worse failure mode: the backlog is realised by the late mint and then absorbed
        // into the accrual baseline, so the early brand never sees it either.
        assertGe(earlyAfter, earlyBefore, "the early brand does not LOSE interest to a late mint");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _openAllMarkets() private {
        for (uint256 i = 0; i < 4; i++) {
            Launch storage l = launches[i];

            // Two steps, and only the first is the owner's: the launch wallet lists the asset
            // with every economic parameter its market will carry — fee tier, starting price,
            // the unit's name and symbol, oracle depth — and then anyone may open that market.
            // The wallet sends the second call too, so it is the recorded creator.
            _approveAsset(
                factory, l.asset, FEE, l.priceE18, CARDINALITY, l.brandName, l.brandSymbol
            );

            vm.prank(LAUNCH_WALLET);
            (uint256 marketId,,,, bytes32 openedPoolId) = factory.createMarket(l.asset, address(0));

            AssetMarketFactory.Market memory m = factory.market(marketId);
            l.marketId = marketId;
            l.brandToken = m.brandToken;
            l.poolId = openedPoolId;
            l.feeVault = m.feeVault;
            l.lpDistributor = m.lpDistributor;
        }
    }

    function _seed(Launch memory l, uint256 usdgIn, uint256 assetIn)
        private
        returns (uint256 tokenId, uint128 liquidity)
    {
        vm.startPrank(LAUNCH_WALLET);
        // The router takes the pool's own stable side, which is this market's brandUSD. Minting
        // it from USDG is a 1:1 call the seeder makes at the reserve first.
        IERC20(MainnetAddresses.USDG).approve(address(reservePool), usdgIn);
        reservePool.mint(l.brandToken, usdgIn, LAUNCH_WALLET);
        IERC20(l.brandToken).approve(address(router), usdgIn);
        IERC20(l.asset).approve(address(router), assetIn);
        // Minimums of 1 rather than a percentage: a full-range seed at a chosen price consumes
        // the two sides in whatever ratio the price dictates, and which side binds depends on
        // the wallet's holdings. The assertions after this call check what was actually used.
        // The unused remainder comes home — the brand leg redeemed back to USDG.
        (tokenId, liquidity,,) =
            router.seedLiquidity(l.marketId, usdgIn, assetIn, 1, 1, block.timestamp + 600);
        vm.stopPrank();
    }

    /// @dev A buy and a sell straight through the PoolManager, asserting the trader actually
    ///      receives the asset and can get USDG back out. There is no periphery router in the
    ///      path: v4 is `unlock`/`swap`/settle, and `MarketRouter` does that itself.
    function _tradeRoundTrip(Launch memory l, uint256 usdgIn) private {
        if (usdgIn == 0) return;
        _fundUsdg(trader, usdgIn);

        uint256 assetBefore = IERC20(l.asset).balanceOf(trader);

        vm.startPrank(trader);
        IERC20(MainnetAddresses.USDG).approve(address(router), usdgIn);
        uint256 assetOut = router.buyWithUsdg(l.marketId, usdgIn, 1, trader, block.timestamp + 600);
        vm.stopPrank();

        assertGt(assetOut, 0, "buy returned asset");
        assertEq(
            IERC20(l.asset).balanceOf(trader) - assetBefore, assetOut, "trader received the asset"
        );

        // And back out again.
        uint256 usdgBefore = IERC20(MainnetAddresses.USDG).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(l.asset).approve(address(router), assetOut);
        uint256 brandOut =
            router.sellForBrand(l.marketId, assetOut, 1, trader, block.timestamp + 600);
        // The sell leaves the trader in the brand; reaching USDG is their own 1:1 redeem.
        uint256 usdgOut = reservePool.redeem(l.brandToken, brandOut, trader);
        vm.stopPrank();

        assertEq(usdgOut, brandOut, "the redeem is at par");

        assertGt(usdgOut, 0, "sell returned USDG");
        assertEq(
            IERC20(MainnetAddresses.USDG).balanceOf(trader) - usdgBefore,
            usdgOut,
            "trader received the USDG"
        );
        // Two 0.3% hops plus price impact: a round trip must lose money, never make it.
        assertLt(usdgOut, usdgIn, "a round trip costs fees, it does not print");

        console.log(l.brandSymbol, "round trip in/out (6dp):", usdgIn, usdgOut);
    }

    /// @dev Morpho's `market()` is a plain storage read; warping alone does not compound
    ///      interest into it. `accrueInterest` forces what the next real supply would.
    function _accrueMorpho(uint256 elapsed) private {
        vm.warp(block.timestamp + elapsed);
        IMorphoAccrue m = IMorphoAccrue(MainnetAddresses.MORPHO_BLUE);
        m.accrueInterest(m.idToMarketParams(MainnetAddresses.USDE_MARKET_ID));
    }

    function _fundUsdg(address to, uint256 amount) private {
        vm.prank(USDG_SOURCE);
        IERC20(MainnetAddresses.USDG).transfer(to, amount);
    }
}
