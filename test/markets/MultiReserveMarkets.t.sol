// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {ShortingYieldSource, StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";

/// @notice One factory, one router, two reserve groups.
///
///         The second group here is the real thing rather than a stand-in: a
///         `SUSDaiYieldSource` whose backing lives behind Across on another chain, charging a
///         redemption fee for the round trip and bounded by a liability cap. What is being
///         proved is that a market on that group is an ordinary market — same factory, same
///         router, same pool manager, same market id space — and that every leg touches the
///         group's own reserve rather than the factory's default.
contract MultiReserveMarketsTest is Test, StackFixture {
    uint24 constant FEE = 3000;
    uint24 constant PROTOCOL_FEE_PIPS = 1000; // 0.10%
    uint256 constant PRICE_E18 = 1e18;
    uint256 constant SEED_USDG = 100_000e6;
    uint256 constant SEED_ASSET = 100_000e18;
    uint16 constant REDEMPTION_FEE_BPS = 14;
    uint256 constant LIABILITY_CAP = 1_000_000e6;
    uint256 constant HUB_CHAIN_ID = 42161;
    address constant HUB = address(0x4B0B);
    address constant HUB_USDC = address(0x05DC);

    PoolManager manager;
    ProtocolFeeHook hook;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    SharedReservePool morphoReserve;
    SharedReservePool susdaiReserve;
    SUSDaiYieldSource adapter;
    MockAcrossSpokePool spokePool;

    AssetMarketFactory factory;
    MarketRouter router;

    MockAsset morphoAsset;
    MockAsset susdaiAsset;
    MockAsset secondSusdaiAsset;

    uint256 morphoMarketId;
    uint256 susdaiMarketId;
    uint256 secondSusdaiMarketId;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address operator = address(0x0FE);
    address trader = address(0x7AAD);
    address keeper = address(0xC0FFEE);

    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        hook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x5151 << 144)
            ),
            IPoolManager(address(manager)),
            owner
        );

        usdg = new MockUSDC();
        morphoReserve = _deployReservePool(address(usdg), address(new ShortingYieldSource()), owner);

        // The periphery pair is built first: the factory takes the `PositionManager` it hands
        // to every market's reward distributor, so it cannot be deployed before one exists.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        factory = _deployFactory(
            morphoReserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            0,
            owner
        );

        router = _deployRouter(
            morphoReserve,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            owner
        );

        // The second group: USDG in, bridged out to a hub on another chain, redemptions paid
        // from the local buffer less a fee. Exactly the shape the Base Sepolia deployment runs.
        spokePool = new MockAcrossSpokePool();
        adapter = _deploySUSDaiAdapter(
            address(usdg),
            address(spokePool),
            HUB_CHAIN_ID,
            HUB,
            HUB_USDC,
            address(protocolGuard),
            owner,
            keeper
        );
        susdaiReserve = _deployReservePool(address(usdg), address(adapter), owner);
        adapter.bindController(address(susdaiReserve));

        vm.startPrank(owner);
        hook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        factory.setApprovedReservePool(address(susdaiReserve), true);
        adapter.setMaxBridgeAmount(100_000e6);
        susdaiReserve.setRedemptionFee(REDEMPTION_FEE_BPS);
        susdaiReserve.setLiabilityCap(LIABILITY_CAP);
        vm.stopPrank();
        // The sUSDai reserve's fee is announced by the setter and live only once
        // `FEE_INCREASE_DELAY` has been served; do that before any market is created.
        vm.warp(susdaiReserve.redemptionFeeEffectiveAt());
        susdaiReserve.commitRedemptionFee();

        morphoAsset = new MockAsset();
        susdaiAsset = new MockAsset();
        secondSusdaiAsset = new MockAsset();

        morphoMarketId = _createMarket("Morpho Dollar", "morUSD", address(morphoAsset), address(0));
        susdaiMarketId =
            _createMarket("AI Dollar", "aiUSD", address(susdaiAsset), address(susdaiReserve));
        secondSusdaiMarketId = _createMarket(
            "Solar Dollar", "solUSD", address(secondSusdaiAsset), address(susdaiReserve)
        );

        _seed(morphoMarketId);
        _seed(susdaiMarketId);
        _seed(secondSusdaiMarketId);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev Listing an asset is the owner's call and opening its market is anyone's; the
    ///      `operator` prank only fixes who the market records as its creator.
    function _createMarket(
        string memory name,
        string memory symbol,
        address assetToken,
        address reservePool
    ) internal returns (uint256 id) {
        _approveAsset(
            factory, assetToken, FEE, PRICE_E18, FIXTURE_MIN_OBSERVATION_CARDINALITY, name, symbol
        );
        vm.prank(operator);
        (id,,,,) = factory.createMarket(assetToken, reservePool);
    }

    function _seed(uint256 id) internal {
        AssetMarketFactory.Market memory m = factory.market(id);
        SharedReservePool reserve = _reserveOf(m);

        usdg.mint(address(this), SEED_USDG);
        usdg.approve(address(reserve), SEED_USDG);
        uint256 brandAmount = reserve.mint(m.brandToken, SEED_USDG, address(this));
        MockAsset(m.asset).mint(address(this), SEED_ASSET);

        IERC20(m.brandToken).approve(address(router), brandAmount);
        IERC20(m.asset).approve(address(router), SEED_ASSET);
        router.seedLiquidity(id, brandAmount, SEED_ASSET, 0, 0, _deadline());
    }

    function _reserveOf(AssetMarketFactory.Market memory m)
        internal
        view
        returns (SharedReservePool)
    {
        return m.reservePool == address(0) ? morphoReserve : SharedReservePool(m.reservePool);
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _fundTraderUsdg(uint256 amount) internal {
        usdg.mint(trader, amount);
        vm.prank(trader);
        usdg.approve(address(router), amount);
    }

    // ─── Creation ────────────────────────────────────────────────────────

    function test_createMarket_poolsTheBrandInTheNamedReserve() public {
        AssetMarketFactory.Market memory m = factory.market(susdaiMarketId);

        assertEq(m.reservePool, address(susdaiReserve), "the market records its own reserve");
        assertTrue(susdaiReserve.isRegistered(m.brandToken), "the brand lives in that reserve");
        assertFalse(
            morphoReserve.isRegistered(m.brandToken), "and not in the factory's default one"
        );
        assertEq(
            address(factory.reserveOf(m.brandToken)),
            address(susdaiReserve),
            "the brand's reserve is readable without the market"
        );
        assertEq(
            address(BrandFeeVault(m.feeVault).reservePool()),
            address(susdaiReserve),
            "the vault harvests from the market's own reserve"
        );
        assertEq(
            address(LpRewardDistributor(m.lpDistributor).reservePool()),
            address(susdaiReserve),
            "and the distributor pays its claims out of it"
        );
    }

    function test_createMarket_keepsTheDefaultReserveForAMarketThatNamesNone() public view {
        AssetMarketFactory.Market memory m = factory.market(morphoMarketId);

        assertEq(m.reservePool, address(morphoReserve), "an unnamed reserve is the default");
        assertTrue(morphoReserve.isRegistered(m.brandToken));
        assertFalse(susdaiReserve.isRegistered(m.brandToken));
    }

    function test_createMarket_marketsFromBothGroupsShareOneIdSpace() public view {
        assertEq(morphoMarketId, 1);
        assertEq(susdaiMarketId, 2);
        assertEq(secondSusdaiMarketId, 3);
        assertEq(factory.marketCount(), 3, "one registry, whatever the backing");
    }

    function test_createMarket_rejectsAnUnapprovedReserve() public {
        SharedReservePool stranger =
            _deployReservePool(address(usdg), address(new ShortingYieldSource()), owner);
        address strayAsset = address(new MockAsset());

        // Listed first, deliberately: creation checks the asset before it resolves the
        // reserve, so an unlisted asset would fail on the wrong error and prove nothing.
        _approveAsset(
            factory,
            strayAsset,
            FEE,
            PRICE_E18,
            FIXTURE_MIN_OBSERVATION_CARDINALITY,
            "Stray Dollar",
            "strUSD"
        );

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.ReserveNotApproved.selector, address(stranger)
            )
        );
        factory.createMarket(strayAsset, address(stranger));
    }

    function test_setApprovedReservePool_refusesADifferentUnderlying() public {
        MockUSDC otherAsset = new MockUSDC();
        SharedReservePool foreign =
            _deployReservePool(address(otherAsset), address(new ShortingYieldSource()), owner);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.ReserveAssetMismatch.selector, address(otherAsset), address(usdg)
            )
        );
        factory.setApprovedReservePool(address(foreign), true);
    }

    function test_setApprovedReservePool_isOwnerOnly() public {
        SharedReservePool stranger =
            _deployReservePool(address(usdg), address(new ShortingYieldSource()), owner);

        vm.prank(operator);
        vm.expectRevert();
        factory.setApprovedReservePool(address(stranger), true);
    }

    // ─── Trading ─────────────────────────────────────────────────────────

    function test_buyWithUsdg_mintsIntoTheMarketsOwnReserve() public {
        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        uint256 susdaiSupplyBefore = susdaiReserve.totalPooledSupply();
        uint256 morphoSupplyBefore = morphoReserve.totalPooledSupply();
        uint256 bufferBefore = adapter.availableLiquidity();

        vm.prank(trader);
        uint256 assetOut = router.buyWithUsdg(susdaiMarketId, usdgIn, 0, trader, _deadline());

        assertGt(assetOut, 0, "the trade filled against the seeded depth");
        assertEq(
            susdaiReserve.totalPooledSupply() - susdaiSupplyBefore,
            usdgIn,
            "the float was minted in the bridged reserve"
        );
        assertEq(
            morphoReserve.totalPooledSupply(),
            morphoSupplyBefore,
            "the default reserve was never touched"
        );
        assertEq(
            adapter.availableLiquidity() - bufferBefore,
            usdgIn,
            "and the backing landed in that group's own adapter"
        );
    }

    function test_buyWithBrand_crossesBrandsInsideTheSameReserve() public {
        address otherBrand = factory.market(secondSusdaiMarketId).brandToken;
        uint256 amountIn = 500e6;

        usdg.mint(trader, amountIn);
        vm.startPrank(trader);
        usdg.approve(address(susdaiReserve), amountIn);
        susdaiReserve.mint(otherBrand, amountIn, trader);
        IERC20(otherBrand).approve(address(router), amountIn);
        uint256 assetOut =
            router.buyWithBrand(susdaiMarketId, otherBrand, amountIn, 0, trader, _deadline());
        vm.stopPrank();

        assertGt(assetOut, 0, "a sibling brand in the same group is still a free 1:1 hop");
    }

    function test_buyWithBrand_rejectsABrandFromAnotherReserve() public {
        address morphoBrand = factory.market(morphoMarketId).brandToken;
        uint256 amountIn = 500e6;

        usdg.mint(trader, amountIn);
        vm.startPrank(trader);
        usdg.approve(address(morphoReserve), amountIn);
        morphoReserve.mint(morphoBrand, amountIn, trader);
        IERC20(morphoBrand).approve(address(router), amountIn);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.BrandNotInMarketReserve.selector, morphoBrand, address(susdaiReserve)
            )
        );
        router.buyWithBrand(susdaiMarketId, morphoBrand, amountIn, 0, trader, _deadline());
        vm.stopPrank();
    }

    function test_sellForBrand_leavesTheHolderInTheBridgedReservesOwnBrand() public {
        AssetMarketFactory.Market memory m = factory.market(susdaiMarketId);
        uint256 assetIn = 100e18;
        MockAsset(m.asset).mint(trader, assetIn);

        vm.startPrank(trader);
        IERC20(m.asset).approve(address(router), assetIn);
        uint256 brandOut = router.sellForBrand(susdaiMarketId, assetIn, 0, trader, _deadline());

        // Redemption is the holder's own second step, and on this group it costs the round
        // trip the reserve is about to make. Nothing in the market stack hides that.
        IERC20(m.brandToken).approve(address(susdaiReserve), brandOut);
        uint256 usdgBefore = usdg.balanceOf(trader);
        uint256 payout = susdaiReserve.redeem(m.brandToken, brandOut, trader);
        vm.stopPrank();

        assertGt(brandOut, 0, "the sale paid out in the market's own dollar");
        assertEq(usdg.balanceOf(trader) - usdgBefore, payout, "payout arrived");
        assertEq(
            payout,
            brandOut - (brandOut * REDEMPTION_FEE_BPS) / 10_000,
            "less the bridged reserve's redemption fee"
        );
    }

    function test_buyWithUsdg_stopsAtTheGroupsLiabilityCap() public {
        uint256 headroom = 100e6;
        uint256 supply = susdaiReserve.totalPooledSupply();
        uint256 cap = supply + headroom;
        vm.prank(owner);
        susdaiReserve.setLiabilityCap(cap);

        uint256 usdgIn = headroom + 1;
        _fundTraderUsdg(usdgIn);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.LiabilityCapExceeded.selector, supply, usdgIn, cap
            )
        );
        router.buyWithUsdg(susdaiMarketId, usdgIn, 0, trader, _deadline());
    }

    function test_theDefaultGroupKeepsTradingWhileTheBridgedOneIsCapped() public {
        uint256 cap = susdaiReserve.totalPooledSupply();
        vm.prank(owner);
        susdaiReserve.setLiabilityCap(cap);

        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        vm.prank(trader);
        uint256 assetOut = router.buyWithUsdg(morphoMarketId, usdgIn, 0, trader, _deadline());

        assertGt(assetOut, 0, "one group's cap is not the other group's problem");
    }
}
