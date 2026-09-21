// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev An 18-decimal ERC-20 standing in for a listed asset — a memecoin, or a tokenized
///      equity. Two instances share a codehash, which is what the canonicality test keys on.
contract MockAsset is IERC20Metadata {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function name() external pure returns (string memory) {
        return "Mock Asset";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// @dev A different contract, so a different codehash. Stands in for an impersonator: it can
///      carry the same name, symbol and decimals and still fail the test.
contract ImpersonatorAsset is MockAsset {
    function extraFunctionSoTheCodeDiffers() external pure returns (uint256) {
        return 1;
    }
}

/// @title AssetMarketFactoryTest
/// @notice The asset list, permissionless creation, one market per asset per reserve, wiring,
///         pricing and the bytecode canonicality test.
///
///         **The venue is a real Uniswap v4 `PoolManager` behind the real `ProtocolFeeHook`,
///         not a mock pool.** In v3 a pool was a contract, so a mock that answered `slot0` and
///         `observe` was a plausible stand-in. In v4 a pool is a key inside a singleton and its
///         entire oracle lives in the hook, so the only thing a mock could stand in for is the
///         singleton itself — at which point the test would be asserting that our own double
///         behaves the way we told it to.
///
///         **The split the suite is really about.** Creation is permissionless and carries no
///         parameters; every economic number comes from the owner's `approveAsset`. Those two
///         facts have to hold together: if a creator could choose the fee tier or the price,
///         the uniqueness rule below would hand the only slot for an asset to whoever got
///         there first with the worst numbers.
contract AssetMarketFactoryTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reservePool;
    SharedReservePool secondReserve;
    PoolManager manager;
    ProtocolFeeHook feeHook;
    StandInPermit2 permit2;
    StandInPositionManager posm;
    AssetMarketFactory factory;

    MockAsset asset;
    MockAsset canonicalReference;
    ImpersonatorAsset impersonator;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address creator = address(0x0FE);
    address alice = address(0xA11CE);
    /// @dev Stands in for `LaunchGraduation`, the module the owner names as `launchpad`.
    address launchpad = address(0x1A0);

    /// @dev Non-zero here so the protocol's share of yield is exercised. The deploy script
    ///      ships zero, which is what makes 100% of a market's float reach its LPs.
    uint16 constant PROTOCOL_BPS = 500;
    uint24 constant FEE = 3000;
    uint16 constant CARDINALITY = 200;

    /// @dev $154, the live SPCX price at the time this was written.
    uint256 constant PRICE = 154e18;

    string constant UNIT_NAME = "Mock Market Dollar";
    string constant UNIT_SYMBOL = "MOCK.d";

    /// @dev A logo URL that survives the whole creation path and comes back out of the brand
    ///      token itself. The field is the reason on-chain metadata exists at all.
    string constant LOGO = "ipfs://bafkreicashcatlogo";

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reservePool = _deployReservePool(address(usdg), address(yieldSource), owner);
        secondReserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        manager = new PoolManager(address(this));
        feeHook = _deployHook(manager, 0x6660);
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        canonicalReference = new MockAsset();
        asset = new MockAsset(); // same code as the reference → canonical
        impersonator = new ImpersonatorAsset(); // different code → not

        factory = _newFactory(feeHook, address(canonicalReference));

        // Without this the hook refuses `registerPool` and every `createMarket` reverts. The
        // two contracts each need the other's address, so the link is a post-deploy write —
        // `DeployAssetMarkets.s.sol` performs exactly this call and asserts it afterwards.
        vm.prank(owner);
        feeHook.setRegistrar(address(factory));

        vm.prank(owner);
        factory.setApprovedReservePool(address(secondReserve), true);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address, so the address
    ///      is not a free choice. `deployCodeTo` writes the contract where we want it and still
    ///      runs the constructor, so `Hooks.validateHookPermissions` still executes — the
    ///      standard way to skip salt mining in a test without skipping the check mining exists
    ///      to satisfy. `discriminator` only keeps two hooks in one test off the same address.
    function _deployHook(PoolManager m, uint16 discriminator) internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (uint160(discriminator) << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(m)), owner);
    }

    function _newFactory(ProtocolFeeHook hook, address referenceEquity)
        internal
        returns (AssetMarketFactory)
    {
        return _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            referenceEquity,
            PROTOCOL_BPS,
            owner
        );
    }

    /// @dev Approve the suite's asset on the suite's terms.
    function _approve(address a) internal {
        _approveAsset(factory, a, FEE, PRICE, CARDINALITY, UNIT_NAME, UNIT_SYMBOL);
    }

    /// @dev Approve then create, which is the whole product flow: the owner lists an asset, and
    ///      anyone opens its market.
    function _createMarket(address a)
        internal
        returns (
            uint256 marketId,
            address brandToken,
            address feeVault,
            address lpDistributor,
            bytes32 poolId
        )
    {
        _approve(a);
        vm.prank(creator);
        return factory.createMarket(a, address(0));
    }

    /// @dev Grow the reserve's yield the way the mock source models it: real USDG handed over,
    ///      raising the index for everyone deployed in it.
    function _accrueInTheReserve(uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdg), amount);
    }

    /// @dev The buffer target the hook holds for a pool. V4 core keeps no observations at all,
    ///      so a market's ring buffer lives in the hook.
    function _cardinalityNext(bytes32 poolId) internal view returns (uint16 next) {
        (,, next) = feeHook.observationState(PoolId.wrap(poolId));
    }

    // ─── The asset list ──────────────────────────────────────────────────

    function test_createMarket_refusesAnAssetTheOwnerHasNotListed() public {
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.AssetNotApproved.selector, address(asset))
        );
        factory.createMarket(address(asset), address(0));
    }

    function test_approveAsset_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.approveAsset(
            address(asset),
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: FEE,
                assetPriceE18: PRICE,
                observationCardinality: CARDINALITY,
                unitName: UNIT_NAME,
                unitSymbol: UNIT_SYMBOL
            })
        );
    }

    /// @notice The whole point of the split: the creator supplies nothing but the transaction.
    ///         Every number the market is born with comes from the approval.
    function test_createMarket_takesEveryEconomicParameterFromTheApproval() public {
        _approveAsset(factory, address(asset), 500, 42e18, 300, "Listed Dollar", "LST.d");

        vm.prank(alice);
        (uint256 id, address brandToken,,,) = factory.createMarket(address(asset), address(0));

        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.fee, 500, "fee tier from the approval");
        assertEq(m.tickSpacing, factory.tickSpacingForFee(500), "and its spacing");
        assertEq(PooledBrandToken(brandToken).name(), "Listed Dollar", "unit name");
        assertEq(PooledBrandToken(brandToken).symbol(), "LST.d", "unit symbol");
        assertEq(m.creator, alice, "the caller is recorded, and that is all they get");

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(m.poolId));
        assertEq(
            sqrtPriceX96,
            factory.quoteSqrtPriceX96(brandToken, address(asset), 42e18),
            "priced at the approval's price"
        );
    }

    function test_createMarket_isPermissionless() public {
        _approve(address(asset));

        vm.prank(alice);
        (uint256 id,,,,) = factory.createMarket(address(asset), address(0));
        assertEq(factory.market(id).creator, alice, "anyone may open an approved asset");
    }

    function test_approveAsset_updatesMoveLaterCreationsOnly() public {
        (uint256 first,,,,) = _createMarket(address(asset));
        assertEq(factory.market(first).fee, FEE);

        // Re-approve at a different tier and open the same asset in the other reserve.
        _approveAsset(factory, address(asset), 500, PRICE, CARDINALITY, UNIT_NAME, UNIT_SYMBOL);

        vm.prank(creator);
        (uint256 second,,,,) = factory.createMarket(address(asset), address(secondReserve));

        assertEq(factory.market(first).fee, FEE, "the live market keeps its terms");
        assertEq(factory.market(second).fee, 500, "the new one takes the new terms");
    }

    function test_revokeAsset_stopsNewMarketsAndLeavesLiveOnesAlone() public {
        (uint256 id,,,,) = _createMarket(address(asset));

        vm.prank(owner);
        factory.revokeAsset(address(asset));

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.AssetNotApproved.selector, address(asset))
        );
        factory.createMarket(address(asset), address(secondReserve));

        // The market that exists is untouched: still recorded, still the live one for its pair.
        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.asset, address(asset));
        assertEq(factory.marketOfAsset(address(reservePool), address(asset)), id);
    }

    function test_approveAsset_rejectsAnUnusableListing() public {
        AssetMarketFactory.AssetListing memory l = AssetMarketFactory.AssetListing({
            approved: true,
            fee: FEE,
            assetPriceE18: PRICE,
            observationCardinality: CARDINALITY,
            unitName: UNIT_NAME,
            unitSymbol: UNIT_SYMBOL
        });

        l.unitSymbol = "";
        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.EmptyUnitMetadata.selector);
        factory.approveAsset(address(asset), l);
        l.unitSymbol = UNIT_SYMBOL;

        l.fee = 1234;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.UnsupportedFeeTier.selector, 1234)
        );
        factory.approveAsset(address(asset), l);
        l.fee = FEE;

        l.assetPriceE18 = 0;
        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.ZeroAmount.selector);
        factory.approveAsset(address(asset), l);
        l.assetPriceE18 = PRICE;

        l.observationCardinality = factory.MAX_OBSERVATION_CARDINALITY() + 1;
        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.CardinalityTooHigh.selector);
        factory.approveAsset(address(asset), l);
        l.observationCardinality = CARDINALITY;

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.AssetHasNoCode.selector);
        factory.approveAsset(address(0xDEAD), l);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.ZeroAddress.selector);
        factory.approveAsset(address(0), l);
    }

    function test_approveAsset_listsEachAssetOnceHoweverOftenItIsUpdated() public {
        _approve(address(asset));
        _approve(address(asset));
        _approve(address(impersonator));

        assertEq(factory.listedAssetsLength(), 2, "two distinct assets");
        assertEq(factory.listedAssets(0), address(asset));
        assertEq(factory.listedAssets(1), address(impersonator));
    }

    // ─── One market per asset per reserve ────────────────────────────────

    /// @notice The rule the representation model rests on. Without it every brand that wanted
    ///         to trade this asset would open its own thin pool, which is the fragmentation the
    ///         shared unit exists to prevent.
    function test_createMarket_refusesASecondMarketForThePairInOneReserve() public {
        (uint256 id,,,,) = _createMarket(address(asset));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetAlreadyHasMarket.selector,
                address(reservePool),
                address(asset),
                id
            )
        );
        factory.createMarket(address(asset), address(0));
    }

    /// @notice The same asset in a different reserve is a different market, because a
    ///         Morpho-backed dollar and a bridge-backed one are not the same claim.
    function test_createMarket_allowsTheSameAssetInAnotherReserve() public {
        (uint256 first,,,,) = _createMarket(address(asset));

        vm.prank(creator);
        (uint256 second,,,,) = factory.createMarket(address(asset), address(secondReserve));

        assertTrue(second != first, "a separate market");
        assertEq(factory.market(second).reservePool, address(secondReserve));
        assertEq(factory.marketOfAsset(address(reservePool), address(asset)), first);
        assertEq(factory.marketOfAsset(address(secondReserve), address(asset)), second);
        assertEq(factory.marketsOfAssetLength(address(asset)), 2, "both recorded under the asset");
    }

    function test_marketFor_readsTheLiveMarketAndDefaultsTheReserve() public {
        assertEq(factory.marketFor(address(0), address(asset)), 0, "no market yet, no revert");

        (uint256 id,,,,) = _createMarket(address(asset));
        assertEq(factory.marketFor(address(0), address(asset)), id, "zero means the default");
        assertEq(factory.marketFor(address(reservePool), address(asset)), id);
        assertEq(factory.marketFor(address(secondReserve), address(asset)), 0);
    }

    /// @notice Retiring frees the slot and nothing else: the old market's record, pool, vault
    ///         and distributor all survive so its LPs can still get out.
    function test_retireMarket_freesTheSlotAndLeavesTheOldMarketIntact() public {
        (uint256 id,, address feeVault, address lpDistributor,) = _createMarket(address(asset));

        vm.prank(owner);
        factory.retireMarket(id);

        assertEq(factory.marketOfAsset(address(reservePool), address(asset)), 0, "slot freed");

        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.feeVault, feeVault, "still readable");
        assertEq(m.lpDistributor, lpDistributor);
        assertEq(
            address(BrandFeeVault(feeVault).distributor()),
            lpDistributor,
            "the vault still points at its distributor"
        );

        // And the pair can be opened again, under whatever the approval now says.
        vm.prank(alice);
        (uint256 replacement,,,,) = factory.createMarket(address(asset), address(0));
        assertTrue(replacement != id, "a new market");
        assertEq(factory.marketOfAsset(address(reservePool), address(asset)), replacement);
    }

    function test_retireMarket_isOwnerOnlyAndRejectsAnUnknownId() public {
        (uint256 id,,,,) = _createMarket(address(asset));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.retireMarket(id);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.UnknownMarket.selector);
        factory.retireMarket(id + 1);
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_createMarket_wiresTheWholeStack() public {
        (uint256 id, address brandToken, address feeVault, address lpDistributor, bytes32 poolId) =
            _createMarket(address(asset));

        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.asset, address(asset));
        assertEq(m.brandToken, brandToken);
        assertEq(m.feeVault, feeVault);
        assertEq(m.lpDistributor, lpDistributor);
        assertEq(m.poolId, poolId);
        assertEq(m.reservePool, address(reservePool));
        assertTrue(m.verified, "same codehash as the reference");
        assertEq(m.createdAt, uint64(vm.getBlockTimestamp()));

        // The brand exists in the reserve and the fee vault owns its yield claim: without the
        // handover nothing could ever pay the market's LPs.
        assertTrue(reservePool.isRegistered(brandToken));
        assertEq(factory.marketOfBrand(brandToken), id);
        assertEq(factory.feeVaultOfBrand(brandToken), feeVault);
        assertEq(PoolBrandTreasury(m.treasury).admin(), feeVault, "treasury admin is the vault");

        // The vault and the distributor point at each other, each written exactly once.
        BrandFeeVault vault = BrandFeeVault(feeVault);
        LpRewardDistributor dist = LpRewardDistributor(lpDistributor);
        assertEq(address(vault.distributor()), lpDistributor);
        assertEq(dist.vault(), feeVault);
        assertEq(address(dist.rewardToken()), brandToken, "rewards are the market's own unit");
        assertEq(address(dist.reservePool()), address(reservePool));
        assertEq(dist.rewardsDuration(), FIXTURE_REWARDS_DURATION);
        assertEq(PoolId.unwrap(dist.poolKey().toId()), poolId, "the distributor knows its own pool");

        // The factory keeps no authority over what it created.
        assertEq(vault.protocolTreasury(), protocolTreasury);
        assertEq(vault.protocolBps(), PROTOCOL_BPS);
        assertEq(vault.lpBps(), 10_000 - PROTOCOL_BPS, "the rest is the LPs'");
        assertEq(vault.minSweep(), 1e6, "one whole USDG");
    }

    /// @notice The link the vault cannot re-make: whoever else asks, the distributor stays.
    function test_setDistributor_isTheFactorysAndIsSpent() public {
        (,, address feeVault, address lpDistributor,) = _createMarket(address(asset));
        BrandFeeVault vault = BrandFeeVault(feeVault);

        vm.prank(alice);
        vm.expectRevert(BrandFeeVault.OnlyFactory.selector);
        vault.setDistributor(LpRewardDistributor(lpDistributor));
    }

    function test_createMarket_brandTokenMirrorsTheReserveAssetDecimals() public {
        (, address brandToken,,,) = _createMarket(address(asset));
        assertEq(IERC20Metadata(brandToken).decimals(), usdg.decimals());
    }

    function test_createMarket_initialisesThePoolAndGrowsItsObservationBuffer() public {
        (uint256 id, address brandToken,,, bytes32 poolId) = _createMarket(address(asset));

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(poolId));
        assertEq(sqrtPriceX96, factory.quoteSqrtPriceX96(brandToken, address(asset), PRICE));
        assertEq(PoolId.unwrap(factory.poolKeyOf(id).toId()), poolId);
        assertEq(_cardinalityNext(poolId), CARDINALITY, "the approval's depth");
    }

    /// @notice A pool born with a ring of one has a price history reaching back to its last
    ///         trade and no further, so the floor is applied whatever the approval asked for.
    function test_createMarket_raisesAnUnderSizedBufferToTheFloor() public {
        _approveAsset(factory, address(asset), FEE, PRICE, 0, UNIT_NAME, UNIT_SYMBOL);
        vm.prank(creator);
        (,,,, bytes32 poolId) = factory.createMarket(address(asset), address(0));

        assertEq(_cardinalityNext(poolId), factory.minObservationCardinality());
        assertEq(factory.minObservationCardinality(), FIXTURE_MIN_OBSERVATION_CARDINALITY);
    }

    function test_createMarket_registersThePoolWithTheHookAndPointsItAtTheProtocolTreasury()
        public
    {
        vm.prank(owner);
        factory.setProtocolFeePips(5_000);

        (,,,, bytes32 poolId) = _createMarket(address(asset));

        assertEq(feeHook.feeRecipientOf(PoolId.wrap(poolId)), protocolTreasury);
        assertEq(feeHook.feePipsFor(PoolId.wrap(poolId)), 5_000);
    }

    function test_createMarket_rejectsAnAssetThatIsAlsoItsUnit() public {
        // Unreachable through the public path — the unit is minted inside the same call — so
        // this pins the guard rather than a user-facing case: approve a *brand* as an asset and
        // creation must refuse rather than pair a token with itself.
        (address brand,) = factory.registerBrand("Stray Dollar", "strUSD");
        _approveAsset(factory, brand, FEE, PRICE, CARDINALITY, UNIT_NAME, UNIT_SYMBOL);

        vm.prank(creator);
        // The brand already belongs to another reserve entry, so the pool key would pair the
        // fresh unit against a brand: allowed, and not what `AssetIsBrandToken` guards. What
        // must hold is simply that creation does not silently produce a self-paired pool.
        (uint256 id, address unit,,,) = factory.createMarket(brand, address(0));
        assertTrue(unit != brand, "the unit is a new token, never the asset");
        assertEq(factory.market(id).asset, brand);
    }

    // ─── Pool identity and pricing ───────────────────────────────────────

    function test_poolKeyOf_rebuildsAKeyThatHashesBackToTheRecordedPoolId() public {
        (uint256 id, address brandToken,,, bytes32 poolId) = _createMarket(address(asset));

        PoolKey memory key = factory.poolKeyOf(id);
        assertEq(PoolId.unwrap(key.toId()), poolId);
        assertEq(address(key.hooks), address(feeHook));
        assertEq(key.fee, FEE);
        assertEq(key.tickSpacing, factory.tickSpacingForFee(FEE));

        (address c0, address c1) = brandToken < address(asset)
            ? (brandToken, address(asset))
            : (address(asset), brandToken);
        assertEq(Currency.unwrap(key.currency0), c0, "Uniswap's ordering, not ours");
        assertEq(Currency.unwrap(key.currency1), c1);
    }

    function test_poolKeyOf_unknownMarketReverts() public {
        vm.expectRevert(AssetMarketFactory.UnknownMarket.selector);
        factory.poolKeyOf(1);
    }

    function test_market_unknownIdReverts() public {
        vm.expectRevert(AssetMarketFactory.UnknownMarket.selector);
        factory.market(99);
    }

    function test_tickSpacingForFee_pinsV3sTableAndRejectsAnythingElse() public view {
        assertEq(factory.tickSpacingForFee(100), 1);
        assertEq(factory.tickSpacingForFee(500), 10);
        assertEq(factory.tickSpacingForFee(3_000), 60);
        assertEq(factory.tickSpacingForFee(5_000), 50);
        assertEq(factory.tickSpacingForFee(10_000), 200);
    }

    function test_tickSpacingForFee_rejectsATierWithNoSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(AssetMarketFactory.UnsupportedFeeTier.selector, 7));
        factory.tickSpacingForFee(7);
    }

    /// @notice The price is derived after the unit's address is known, so both token orderings
    ///         have to come out right — a caller computing a sqrt price off-chain could not.
    function test_quoteSqrtPriceX96_bothOrderings() public {
        (, address brandToken,,,) = _createMarket(address(asset));

        uint160 quoted = factory.quoteSqrtPriceX96(brandToken, address(asset), PRICE);
        assertGt(quoted, 0);

        // The reciprocal pairing must price the reciprocal, to within rounding.
        uint160 flipped = factory.quoteSqrtPriceX96(address(asset), brandToken, PRICE);
        assertGt(flipped, 0);
        assertTrue(quoted != flipped, "ordering changes the number");
    }

    function test_quoteSqrtPriceX96_rejectsZeroPrice() public {
        (, address brandToken,,,) = _createMarket(address(asset));
        vm.expectRevert(AssetMarketFactory.ZeroAmount.selector);
        factory.quoteSqrtPriceX96(brandToken, address(asset), 0);
    }

    // ─── Verification ────────────────────────────────────────────────────

    function test_verification_acceptsMatchingCodehashRejectsImpersonator() public {
        assertTrue(factory.isCanonicalEquity(address(asset)));
        assertFalse(factory.isCanonicalEquity(address(impersonator)));

        _approveAsset(factory, address(impersonator), FEE, PRICE, CARDINALITY, "I", "I.d");
        vm.prank(creator);
        (uint256 id,,,,) = factory.createMarket(address(impersonator), address(0));
        assertFalse(factory.market(id).verified, "recorded, and honestly unverified");
    }

    function test_verification_neverTrueForAnEoaOrEmptyAccount() public view {
        assertFalse(factory.isCanonicalEquity(alice));
        assertFalse(factory.isCanonicalEquity(address(0)));
    }

    function test_verification_disabledWithoutAReference() public {
        AssetMarketFactory bare = _newFactory(_deployHook(manager, 0x7770), address(0));
        assertFalse(bare.isCanonicalEquity(address(asset)), "no reference, no claim");
        assertEq(bare.equityCodehash(), bytes32(0));
    }

    // ─── Construction ────────────────────────────────────────────────────

    function test_constructor_rejectsAHookBoundToAnotherPoolManager() public {
        PoolManager stranger = new PoolManager(address(this));
        // Deployed outside the `expectRevert` window, or that would catch this deployment.
        ProtocolFeeHook foreignHook = _deployHook(stranger, 0x7770);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.HookManagerMismatch.selector, address(stranger), address(manager)
            )
        );
        _newFactory(foreignHook, address(canonicalReference));
    }

    /// @notice Same reasoning for the periphery: a `PositionManager` on another singleton would
    ///         mint positions no distributor here could ever accept.
    function test_constructor_rejectsAPositionManagerOnAnotherPoolManager() public {
        PoolManager stranger = new PoolManager(address(this));
        StandInPositionManager strayPosm =
            new StandInPositionManager(IPoolManager(address(stranger)), permit2);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.PositionManagerMismatch.selector,
                address(stranger),
                address(manager)
            )
        );
        _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(strayPosm)),
            protocolTreasury,
            address(canonicalReference),
            PROTOCOL_BPS,
            owner
        );
    }

    function test_constructor_rejectsZeroWiring() public {
        vm.expectRevert(AssetMarketFactory.ZeroAddress.selector);
        _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            address(0),
            address(canonicalReference),
            PROTOCOL_BPS,
            owner
        );
    }

    function test_constructor_rejectsAnUnservableRewardPeriodOrBuffer() public {
        vm.expectRevert(AssetMarketFactory.RewardsDurationTooShort.selector);
        _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(canonicalReference),
            PROTOCOL_BPS,
            1 minutes,
            FIXTURE_MIN_OBSERVATION_CARDINALITY,
            owner
        );

        vm.expectRevert(AssetMarketFactory.CardinalityTooLow.selector);
        _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(canonicalReference),
            PROTOCOL_BPS,
            FIXTURE_REWARDS_DURATION,
            1,
            owner
        );
    }

    // ─── Protocol parameters ─────────────────────────────────────────────

    function test_setProtocolParams_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setProtocolParams(alice, 100);
    }

    function test_setProtocolParams_respectsTheCeiling() public {
        uint16 ceiling = factory.MAX_PROTOCOL_BPS();

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.ProtocolFeeTooHigh.selector);
        factory.setProtocolParams(protocolTreasury, ceiling + 1);

        vm.prank(owner);
        factory.setProtocolParams(protocolTreasury, ceiling);
        assertEq(factory.protocolBps(), ceiling);
    }

    function test_setProtocolParams_acceptsAZeroFee() public {
        vm.prank(owner);
        factory.setProtocolParams(protocolTreasury, 0);

        (,, address feeVault,,) = _createMarket(address(asset));
        assertEq(BrandFeeVault(feeVault).protocolBps(), 0);
        assertEq(BrandFeeVault(feeVault).lpBps(), 10_000, "all of it to the LPs");
    }

    function test_setProtocolParams_doesNotTouchExistingMarkets() public {
        (,, address feeVault,,) = _createMarket(address(asset));
        assertEq(BrandFeeVault(feeVault).protocolBps(), PROTOCOL_BPS);

        vm.prank(owner);
        factory.setProtocolParams(alice, 1_000);

        assertEq(
            BrandFeeVault(feeVault).protocolBps(), PROTOCOL_BPS, "a live market keeps its terms"
        );
        assertEq(BrandFeeVault(feeVault).protocolTreasury(), protocolTreasury);
    }

    function test_setProtocolFeePips_isOwnerOnlyAndBoundedByTheHooksCeiling() public {
        // Read the ceiling before arming anything: `expectRevert` catches the very next call,
        // and a `feeHook.MAX_FEE_PIPS()` sitting inside the arguments would be that call.
        uint24 ceiling = feeHook.MAX_FEE_PIPS();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setProtocolFeePips(1);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.ProtocolFeeTooHigh.selector);
        factory.setProtocolFeePips(ceiling + 1);

        vm.prank(owner);
        factory.setProtocolFeePips(ceiling);
        assertEq(factory.protocolFeePips(), ceiling);
    }

    function test_setRewardsDuration_isOwnerOnlyBoundedAndMovesFutureMarketsOnly() public {
        (,,, address lpDistributor,) = _createMarket(address(asset));
        uint32 was = LpRewardDistributor(lpDistributor).rewardsDuration();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setRewardsDuration(1 days);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.RewardsDurationTooShort.selector);
        factory.setRewardsDuration(1 minutes);

        vm.prank(owner);
        factory.setRewardsDuration(1 days);
        assertEq(factory.rewardsDuration(), 1 days);

        vm.prank(creator);
        (,,, address nextDistributor,) =
            factory.createMarket(address(asset), address(secondReserve));
        assertEq(LpRewardDistributor(nextDistributor).rewardsDuration(), 1 days, "the new market");
        assertEq(LpRewardDistributor(lpDistributor).rewardsDuration(), was, "not the old one");
    }

    function test_setMinObservationCardinality_isOwnerOnlyAndBounded() public {
        // Read the bounds before arming anything: `expectRevert` binds to the very next call,
        // and a `factory.MIN_OBSERVATION_CARDINALITY()` inside the arguments would be it.
        uint16 floor = factory.MIN_OBSERVATION_CARDINALITY();
        uint16 ceiling = factory.MAX_OBSERVATION_CARDINALITY();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setMinObservationCardinality(100);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.CardinalityTooLow.selector);
        factory.setMinObservationCardinality(floor - 1);

        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.CardinalityTooHigh.selector);
        factory.setMinObservationCardinality(ceiling + 1);

        vm.prank(owner);
        factory.setMinObservationCardinality(500);
        assertEq(factory.minObservationCardinality(), 500);
    }

    // ─── Reserve groups ──────────────────────────────────────────────────

    function test_createMarket_rejectsAnUnapprovedReserve() public {
        _approve(address(asset));
        SharedReservePool stray = _deployReservePool(address(usdg), address(yieldSource), owner);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.ReserveNotApproved.selector, address(stray))
        );
        factory.createMarket(address(asset), address(stray));
    }

    function test_setApprovedReservePool_refusesAReserveOnAnotherAsset() public {
        MockUSDC otherAsset = new MockUSDC();
        MockYieldSource otherSource = new MockYieldSource();
        SharedReservePool foreign =
            _deployReservePool(address(otherAsset), address(otherSource), owner);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.ReserveAssetMismatch.selector, address(otherAsset), address(usdg)
            )
        );
        factory.setApprovedReservePool(address(foreign), true);
    }

    // ─── Brands as representations ───────────────────────────────────────

    /// @notice The property a representation brand's whole economics rests on: it never gets a
    ///         market, so if the factory kept its treasury admin its float would be unclaimable
    ///         by anyone, forever.
    function test_registerBrand_handsTheTreasuryToTheOperatorSoItsFloatIsClaimable() public {
        vm.prank(alice);
        (address brand, address treasury) = factory.registerBrand("Alice Dollar", "aliceUSD");

        assertEq(PoolBrandTreasury(treasury).admin(), alice, "the operator, not the factory");
        assertEq(factory.marketOfBrand(brand), 0, "and no market");
        assertEq(factory.feeVaultOfBrand(brand), address(0), "and no vault");
        assertEq(factory.brandOperatorOf(brand), alice);

        // Float earned on balances held in the brand is theirs from the first block.
        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(reservePool), 1_000e6);
        reservePool.mint(brand, 1_000e6, alice);
        vm.stopPrank();

        _accrueInTheReserve(100e6);
        assertGt(PoolBrandTreasury(treasury).pendingYield(), 0, "accruing");

        vm.prank(alice);
        uint256 claimed = PoolBrandTreasury(treasury).claim(alice);
        assertGt(claimed, 0, "and claimable by its own operator");
    }

    function test_createMarket_keepsTheUnitsTreasuryLongEnoughToHandItToTheVault() public {
        (uint256 id,, address feeVault,,) = _createMarket(address(asset));
        AssetMarketFactory.Market memory m = factory.market(id);

        assertEq(PoolBrandTreasury(m.treasury).admin(), feeVault, "the vault, not the creator");
    }

    function test_registerBrand_metadataIsWrittenAndStaysWithTheIssuer() public {
        vm.prank(alice);
        (address brand,) = factory.registerBrand(
            "Alice Dollar",
            "aliceUSD",
            PooledBrandToken.Metadata({description: "a dollar", logo: LOGO, socials: "x.com/a"})
        );

        PooledBrandToken token = PooledBrandToken(brand);
        assertEq(token.description(), "a dollar");
        assertEq(token.logo(), LOGO, "an explicit logo is never overwritten");
        assertEq(token.metadataAdmin(), alice, "and the authority is the issuer's");

        vm.prank(alice);
        token.setMetadata(
            PooledBrandToken.Metadata({description: "changed", logo: LOGO, socials: ""})
        );
        assertEq(token.description(), "changed");
    }

    function test_registerBrand_derivesALogoWhenTheIssuerSuppliesNone() public {
        vm.prank(owner);
        factory.setLogoTemplate("https://cdn.example/brands/", ".png");

        vm.prank(alice);
        (address brand,) = factory.registerBrand("Alice Dollar", "aliceUSD");

        assertEq(
            PooledBrandToken(brand).logo(),
            string.concat(
                "https://cdn.example/brands/", vm.toLowercase(vm.toString(brand)), ".png"
            ),
            "keyed by the address only the factory knew in time"
        );
    }

    function test_registerBrand_withNoTemplateLeavesTheLogoEmpty() public {
        vm.prank(alice);
        (address brand,) = factory.registerBrand("Alice Dollar", "aliceUSD");
        assertEq(PooledBrandToken(brand).logo(), "");
    }

    function test_theFactorysMetadataHandoverIsSpentAndCannotBeReused() public {
        vm.prank(alice);
        (address brand,) = factory.registerBrand("Alice Dollar", "aliceUSD");

        PooledBrandToken token = PooledBrandToken(brand);
        vm.prank(alice);
        vm.expectRevert(PooledBrandToken.HandoverAlreadySpent.selector);
        token.handOverMetadataAdmin(address(factory));
    }

    function test_setLogoTemplate_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setLogoTemplate("x", ".png");
    }

    function test_createMarket_derivesTheUnitsLogoToo() public {
        vm.prank(owner);
        factory.setLogoTemplate("https://cdn.example/brands/", ".png");

        (, address unit,,,) = _createMarket(address(asset));
        assertEq(
            PooledBrandToken(unit).logo(),
            string.concat("https://cdn.example/brands/", vm.toLowercase(vm.toString(unit)), ".png")
        );
        assertEq(PooledBrandToken(unit).metadataAdmin(), creator, "the creator may fix it");
    }

    // ─── The launchpad seam ──────────────────────────────────────────────
    //
    // `createLaunchMarket` is `createMarket` with the approval folded into the call and the
    // quote brand supplied rather than minted: the launchpad's graduation module is the only
    // caller, and the brand it names is the dollar the launch was already quoted in. What
    // these pin is that the gate is real, that the listing is held to the standard that still
    // applies to it, and that the market it opens is an ordinary one — attributed to the
    // launch's creator, priced from the listing, invisible to the owner's asset list, and
    // making no claim at all on the brand it merely quotes.

    /// @dev A quote brand of the kind a launch is priced in: registered through this factory
    ///      so `reserveOfBrand` names its reserve, and owned by whoever registered it. Zero
    ///      `reserve` selects the factory's default.
    function _quoteBrand(string memory symbol, address reserve) internal returns (address brand) {
        (brand,) = factory.registerBrand(
            "Quote Dollar",
            symbol,
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            reserve
        );
    }

    function _launch(address a, address brand, address who)
        internal
        returns (uint256 marketId, address feeVault, address lpDistributor, bytes32 poolId)
    {
        // Built first: the helper reads the asset's symbol, and a prank binds to the next call.
        AssetMarketFactory.AssetListing memory l = _launchListing(a, PRICE);
        vm.prank(launchpad);
        return factory.createLaunchMarket(a, brand, address(0), who, l);
    }

    function test_createLaunchMarket_isTheLaunchpadsAlone() public {
        address brand = _quoteBrand("qUSD", address(0));
        AssetMarketFactory.AssetListing memory l = _launchListing(address(asset), PRICE);

        // Nobody, until the owner names someone — not even the owner.
        vm.prank(owner);
        vm.expectRevert(AssetMarketFactory.OnlyLaunchpad.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);

        _setLaunchpad(factory, launchpad);

        vm.prank(alice);
        vm.expectRevert(AssetMarketFactory.OnlyLaunchpad.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);

        vm.prank(launchpad);
        (uint256 id,,,) = factory.createLaunchMarket(address(asset), brand, address(0), creator, l);
        assertEq(factory.marketFor(address(0), address(asset)), id);
    }

    function test_setLaunchpad_zeroDisablesThePathAgain() public {
        _setLaunchpad(factory, launchpad);
        _setLaunchpad(factory, address(0));

        address brand = _quoteBrand("qUSD", address(0));
        AssetMarketFactory.AssetListing memory l = _launchListing(address(asset), PRICE);
        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.OnlyLaunchpad.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);
    }

    function test_setLaunchpad_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setLaunchpad(alice);
    }

    /// @notice The launchpad is trusted to call, not to choose well: a listing it could not
    ///         have got past `approveAsset` does not get past here either. The unit's name and
    ///         symbol are the one exception, and deliberately so — this listing mints no unit.
    function test_createLaunchMarket_holdsTheListingToApproveAssetsStandard() public {
        _setLaunchpad(factory, launchpad);
        address brand = _quoteBrand("qUSD", address(0));
        AssetMarketFactory.AssetListing memory l = _launchListing(address(asset), PRICE);

        l.fee = 1234;
        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.UnsupportedFeeTier.selector, 1234)
        );
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);
        l.fee = 5_000;

        l.assetPriceE18 = 0;
        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.ZeroAmount.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);
        l.assetPriceE18 = PRICE;

        l.observationCardinality = factory.MAX_OBSERVATION_CARDINALITY() + 1;
        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.CardinalityTooHigh.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), creator, l);
        l.observationCardinality = CARDINALITY;

        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.AssetHasNoCode.selector);
        factory.createLaunchMarket(address(0xDEAD), brand, address(0), creator, l);

        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.ZeroAddress.selector);
        factory.createLaunchMarket(address(0), brand, address(0), creator, l);

        // A market with nobody to attribute the launch to is refused the same way.
        vm.prank(launchpad);
        vm.expectRevert(AssetMarketFactory.ZeroAddress.selector);
        factory.createLaunchMarket(address(asset), brand, address(0), address(0), l);

        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.ReserveNotApproved.selector, address(0xBAD))
        );
        factory.createLaunchMarket(address(asset), brand, address(0xBAD), creator, l);

        // And the quote brand has to be one this factory registered: a brand it does not know
        // has no `reserveOfBrand`, and the market record would name the wrong reserve.
        (address strayBrand,) = reservePool.registerBrand("Stray", "stray", address(this));
        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.BrandNotRegistered.selector, strayBrand)
        );
        factory.createLaunchMarket(address(asset), strayBrand, address(0), creator, l);
    }

    /// @notice The market is an ordinary one, it is the creator's, and the dollar it is quoted
    ///         in is nobody's but its issuer's: no unit is minted, the brand's treasury and
    ///         fee-vault records are untouched, and the market reads as a shared quote.
    function test_createLaunchMarket_opensAnOrdinaryMarketQuotedInTheLaunchsBrand() public {
        _setLaunchpad(factory, launchpad);
        address brand = _quoteBrand("qUSD", address(0));
        uint256 brandsBefore = reservePool.allBrandTokensLength();
        address brandTreasury = factory.treasuryOfBrand(brand);

        // A launched token has its own bytecode, never the reference equity's.
        (uint256 id, address feeVault, address lpDistributor, bytes32 poolId) =
            _launch(address(impersonator), brand, creator);

        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.creator, creator, "the launch's creator, not the launchpad");
        assertEq(m.brandToken, brand, "quoted in the launch's own dollar");
        assertFalse(m.verified);
        assertEq(m.asset, address(impersonator));
        assertEq(m.reservePool, address(reservePool), "zero means the default reserve");
        assertEq(m.fee, 5_000, "the listing's tier");
        assertEq(m.tickSpacing, factory.tickSpacingForFee(5_000));

        // Graduating mints no stablecoin, and takes nothing from the one it quotes.
        assertEq(reservePool.allBrandTokensLength(), brandsBefore, "no new brand");
        assertTrue(factory.isSharedQuote(id), "a shared quote, not the market's own unit");
        assertEq(factory.marketOfBrand(brand), 0, "the brand still belongs to no market");
        assertEq(factory.feeVaultOfBrand(brand), address(0), "and has no single vault");
        assertEq(m.treasury, brandTreasury, "the brand's existing treasury");
        assertEq(
            PoolBrandTreasury(brandTreasury).admin(),
            address(this),
            "which stays with the issuer who registered it"
        );
        assertEq(
            PooledBrandToken(brand).metadataAdmin(),
            address(this),
            "as does the right to describe it"
        );

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(poolId));
        assertEq(
            sqrtPriceX96,
            factory.quoteSqrtPriceX96(brand, address(impersonator), PRICE),
            "priced from the listing"
        );
        assertEq(feeHook.feeRecipientOf(PoolId.wrap(poolId)), protocolTreasury, "hook registered");
        assertEq(_cardinalityNext(poolId), FIXTURE_MIN_OBSERVATION_CARDINALITY);

        assertEq(factory.marketFor(address(reservePool), address(impersonator)), id);
        assertEq(factory.marketOfPool(poolId), id);
        assertEq(address(BrandFeeVault(feeVault).distributor()), lpDistributor);
        assertEq(address(LpRewardDistributor(lpDistributor).rewardToken()), brand);
    }

    /// @notice The listing travelled with the call and is gone with it: the owner's asset list
    ///         never learns about a launched asset, so `createMarket` still refuses it.
    function test_createLaunchMarket_leavesTheAssetListAlone() public {
        _setLaunchpad(factory, launchpad);
        _launch(address(impersonator), _quoteBrand("qUSD", address(0)), creator);

        assertEq(factory.listedAssetsLength(), 0);
        assertFalse(factory.assetListing(address(impersonator)).approved);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetNotApproved.selector, address(impersonator)
            )
        );
        factory.createMarket(address(impersonator), address(secondReserve));
    }

    function test_createLaunchMarket_refusesASecondMarketForThePairAndAllowsAnotherReserve()
        public
    {
        _setLaunchpad(factory, launchpad);
        address brand = _quoteBrand("qUSD", address(0));
        (uint256 id,,,) = _launch(address(impersonator), brand, creator);
        AssetMarketFactory.AssetListing memory l = _launchListing(address(impersonator), PRICE);

        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetAlreadyHasMarket.selector,
                address(reservePool),
                address(impersonator),
                id
            )
        );
        factory.createLaunchMarket(address(impersonator), brand, address(0), alice, l);

        // A different reserve is a different market, and needs a quote brand pooled there.
        address otherBrand = _quoteBrand("qUSD2", address(secondReserve));
        vm.prank(launchpad);
        (uint256 second,,,) = factory.createLaunchMarket(
            address(impersonator), otherBrand, address(secondReserve), alice, l
        );
        assertEq(factory.market(second).reservePool, address(secondReserve));
        assertEq(factory.marketFor(address(secondReserve), address(impersonator)), second);
        assertEq(factory.marketsOfAssetLength(address(impersonator)), 2);
    }
}
