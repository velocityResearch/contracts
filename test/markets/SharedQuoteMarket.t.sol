// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./AssetMarketFactory.t.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title SharedQuoteMarketTest
/// @notice `createMarketForBrand`: a market for a listed asset **quoted in a dollar that
///         already exists** instead of in a unit minted for that market.
///
///         **The one thing this suite is really about is what the market does NOT take.** A
///         market that mints its own unit owns it outright — `marketOfBrand` names it, its
///         vault becomes the unit's treasury admin, and every cent of that dollar's float pays
///         that market's LPs. A dollar that already exists cannot be owned that way: it sits in
///         wallets, it may quote other pools, and its float is the issuer's. So the three writes
///         that would claim it are skipped, and the tests below pin each of them against a
///         `createMarket` market in the same file where all three DO land. Getting that wrong
///         is not a cosmetic regression — it would hand one pool's vault the admin key to a
///         dollar it did not issue, and take away the issuer's only route to their own float.
///
///         **The gate is the issuer, not the world.** Creation through `createMarket` is
///         permissionless because the unit it pairs with did not exist a moment earlier.
///         Quoting a market in someone's dollar makes that dollar the settlement currency of a
///         market they did not open, so only its operator — or this factory's owner — may do it.
///
///         **And the income path still works, funded differently.** `harvest` claims a treasury
///         this vault does not administer and therefore reverts; `sweep` splits whatever the
///         vault was *sent*, which is how an issuer pays one of the pools quoting their dollar.
contract SharedQuoteMarketTest is Test, StackFixture {
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
    MockAsset otherAsset;

    /// @dev The dollar that already exists, and its treasury. Registered through the factory by
    ///      `issuer` in `setUp`, which is what makes it eligible as a shared quote at all.
    address brand;
    address brandTreasury;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    /// @dev The dollar's operator, and deliberately NOT the factory owner: the authorisation
    ///      test needs the two permitted callers to be distinguishable.
    address issuer = address(0x1550E);
    address stranger = address(0x57121);
    address keeper = address(0x33333);

    /// @dev Non-zero so the protocol's share of a sweep is exercised rather than assumed away.
    uint16 constant PROTOCOL_BPS = 500;
    uint16 constant BPS_DENOMINATOR = 10_000;
    uint24 constant FEE = 3000;
    uint16 constant CARDINALITY = 200;

    /// @dev $154, the same reference price the factory suite lists at.
    uint256 constant PRICE = 154e18;

    string constant UNIT_NAME = "Mock Market Dollar";
    string constant UNIT_SYMBOL = "MOCK.d";

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reservePool = _deployReservePool(address(usdg), address(yieldSource), owner);
        secondReserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        manager = new PoolManager(address(this));
        feeHook = _deployHook(0x6661);
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        // Verification disabled: `verified` is a statement about an asset's bytecode and has
        // nothing to do with which dollar a market is quoted in.
        factory = _deployFactory(
            reservePool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            PROTOCOL_BPS,
            owner
        );

        // Without this the hook refuses `registerPool` and every creation reverts.
        vm.prank(owner);
        feeHook.setRegistrar(address(factory));

        vm.prank(owner);
        factory.setApprovedReservePool(address(secondReserve), true);

        asset = new MockAsset();
        otherAsset = new MockAsset();

        // The dollar, registered the way any community registers theirs: permissionless, and
        // holding its own treasury from the first block.
        vm.prank(issuer);
        (brand, brandTreasury) = factory.registerBrand("Stables Dollar", "spUSD");
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address, so the address
    ///      is not a free choice. `deployCodeTo` writes the proxy where we want it and still
    ///      runs its constructor, so `Hooks.validateHookPermissions` still executes.
    function _deployHook(uint16 discriminator) internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (uint160(discriminator) << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    function _approve(address a) internal {
        _approveAsset(factory, a, FEE, PRICE, CARDINALITY, UNIT_NAME, UNIT_SYMBOL);
    }

    /// @dev The whole shared-quote flow: the owner lists the asset, the dollar's operator hands
    ///      the dollar to the market as its currency.
    function _openShared(address a, address caller)
        internal
        returns (uint256 marketId, address feeVault, address lpDistributor, bytes32 poolId)
    {
        _approve(a);
        vm.prank(caller);
        return factory.createMarketForBrand(a, brand);
    }

    /// @dev Uniswap's own ordering for a pair, which is the ordering the factory must use.
    function _expectedKey(address quote, address a) internal view returns (PoolKey memory) {
        (address c0, address c1) = quote < a ? (quote, a) : (a, quote);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: factory.tickSpacingForFee(FEE),
            hooks: IHooks(address(feeHook))
        });
    }

    /// @dev Mint `amount` of the shared dollar straight to `to`. This is the only way a
    ///      shared-quote vault is ever funded — see `test_harvest_…` for why.
    function _sendBrand(address to, uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(reservePool), amount);
        reservePool.mint(brand, amount, to);
    }

    /// @dev Grow the reserve's yield the way the mock source models it: real USDG handed over,
    ///      raising the index for every brand deployed in it.
    function _accrueInTheReserve(uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdg), amount);
    }

    // ─── The market is quoted in the dollar ──────────────────────────────

    /// @notice The pool's currency is the dollar itself, priced by the owner's listing, and the
    ///         market is marked as one that does not own its quote.
    function test_createMarketForBrand_quotesTheMarketInADollarThatAlreadyExists() public {
        (uint256 id,,, bytes32 poolId) = _openShared(address(asset), issuer);

        AssetMarketFactory.Market memory m = factory.market(id);
        assertEq(m.brandToken, brand, "quoted in the dollar, not in a unit minted for this market");
        assertEq(m.asset, address(asset), "against the listed asset");
        assertEq(m.treasury, brandTreasury, "and the dollar's own treasury is recorded");
        assertEq(m.reservePool, address(reservePool), "in the reserve the dollar is pooled in");

        PoolKey memory expected = _expectedKey(brand, address(asset));
        PoolKey memory key = factory.poolKeyOf(id);
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(expected.currency0), "currency0");
        assertEq(Currency.unwrap(key.currency1), Currency.unwrap(expected.currency1), "currency1");
        assertEq(key.fee, FEE, "the listing's fee tier");
        assertEq(PoolId.unwrap(key.toId()), poolId, "and the returned id is that key's");

        assertTrue(factory.isSharedQuote(id), "a market quoted in a dollar it does not own");
        assertEq(
            factory.marketOfAsset(address(reservePool), address(asset)),
            id,
            "and it is the one market for the pair"
        );

        // The rest of the wiring is `createMarket`'s, unchanged: the pool opens at the
        // approval's price, its skim points at the protocol treasury, and the oracle is grown
        // past the ring of one a fresh v4 pool is born with.
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(poolId));
        assertEq(
            sqrtPriceX96,
            factory.quoteSqrtPriceX96(brand, address(asset), PRICE),
            "priced at the listing, not at whatever the pair happened to trade at"
        );
        assertEq(
            feeHook.feeRecipientOf(PoolId.wrap(poolId)),
            protocolTreasury,
            "the pool's trading skim is registered"
        );
        (,, uint16 cardinalityNext) = feeHook.observationState(PoolId.wrap(poolId));
        assertEq(cardinalityNext, CARDINALITY, "and the oracle was grown to the listing's depth");
    }

    // ─── The dollar is not claimed ───────────────────────────────────────

    /// @notice The three writes that would make the dollar this market's property are skipped,
    ///         and the same three land for a market that minted its own unit.
    ///
    ///         The treasury admin is the load-bearing one. `PoolBrandTreasury.claim` is
    ///         admin-only and `setAdmin` is callable only by the current admin, so handing it to
    ///         one pool's vault would permanently take the issuer's float away from them.
    function test_createMarketForBrand_leavesTheDollarWithItsIssuer() public {
        (uint256 shared, address sharedVault,,) = _openShared(address(asset), issuer);
        assertTrue(factory.isSharedQuote(shared), "the market under test is a shared quote");

        assertEq(factory.marketOfBrand(brand), 0, "the dollar belongs to no market");
        assertEq(factory.feeVaultOfBrand(brand), address(0), "and has no single vault");
        assertEq(
            PoolBrandTreasury(brandTreasury).admin(),
            issuer,
            "its float stays claimable by the issuer, not by this market's vault"
        );
        assertTrue(sharedVault != PoolBrandTreasury(brandTreasury).admin(), "which is the point");

        // The contrast, in the same reserve and at the same listing terms: a market that minted
        // its unit takes all three.
        _approve(address(otherAsset));
        vm.prank(stranger);
        (uint256 owned, address unit, address ownedVault,,) =
            factory.createMarket(address(otherAsset), address(0));

        assertFalse(factory.isSharedQuote(owned), "a market that minted its unit owns it");
        assertEq(factory.marketOfBrand(unit), owned, "the unit points back at its market");
        assertEq(factory.feeVaultOfBrand(unit), ownedVault, "the unit has that market's vault");
        assertEq(
            PoolBrandTreasury(factory.treasuryOfBrand(unit)).admin(),
            ownedVault,
            "and its whole float is that market's income"
        );
    }

    // ─── Several markets, one dollar ─────────────────────────────────────

    /// @notice A dollar can quote more than one market, because no market owns it. Each gets its
    ///         own pool, its own vault and its own LP stream, and the second creation is not
    ///         allowed to disturb the first market's record.
    function test_createMarketForBrand_letsTwoMarketsQuoteTheSameDollar() public {
        (uint256 first, address firstVault, address firstDistributor, bytes32 firstPool) =
            _openShared(address(asset), issuer);
        AssetMarketFactory.Market memory before = factory.market(first);

        (uint256 second, address secondVault, address secondDistributor, bytes32 secondPool) =
            _openShared(address(otherAsset), issuer);

        assertTrue(first != second, "two markets");
        assertEq(factory.market(second).brandToken, brand, "both quoted in the same dollar");
        assertTrue(factory.isSharedQuote(first), "and neither owns it: the first");
        assertTrue(factory.isSharedQuote(second), "nor the second");
        assertEq(factory.marketOfBrand(brand), 0, "so the dollar is still unclaimed");

        assertTrue(firstPool != secondPool, "different pairs are different pools");
        assertTrue(firstVault != secondVault, "each market's income is its own");
        assertTrue(firstDistributor != secondDistributor, "and each streams to its own liquidity");

        AssetMarketFactory.Market memory after_ = factory.market(first);
        assertEq(after_.poolId, before.poolId, "the first market's pool is untouched");
        assertEq(after_.feeVault, before.feeVault, "and its vault");
        assertEq(after_.lpDistributor, before.lpDistributor, "and its distributor");
        assertEq(
            factory.marketOfAsset(address(reservePool), address(asset)),
            first,
            "and it is still the market for its pair"
        );
        assertEq(
            factory.marketOfAsset(address(reservePool), address(otherAsset)),
            second,
            "while the new pair points at the new market"
        );
    }

    // ─── Authorisation ───────────────────────────────────────────────────

    /// @notice Only the dollar's operator, or the factory owner, may make someone's dollar the
    ///         settlement currency of a market.
    function test_createMarketForBrand_isTheIssuersCallOrTheOwners() public {
        assertTrue(issuer != owner, "the two permitted callers must be distinguishable");
        assertEq(factory.brandOperatorOf(brand), issuer, "and the operator is not the owner");

        _approve(address(asset));
        _approve(address(otherAsset));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AssetMarketFactory.NotBrandOperator.selector, brand));
        factory.createMarketForBrand(address(asset), brand);

        vm.prank(issuer);
        (uint256 byIssuer,,,) = factory.createMarketForBrand(address(asset), brand);
        assertEq(factory.market(byIssuer).creator, issuer, "the operator may quote their dollar");

        vm.prank(owner);
        (uint256 byOwner,,,) = factory.createMarketForBrand(address(otherAsset), brand);
        assertEq(factory.market(byOwner).creator, owner, "and so may the factory owner");
    }

    // ─── Refusals ────────────────────────────────────────────────────────

    /// @notice A brand this factory never registered has no recorded reserve and no operator to
    ///         ask, so there is nobody who could authorise the call. That is true of a plain
    ///         ERC-20 and — the case that actually turns up — of a real brand registered
    ///         straight on the reserve, bypassing this factory.
    function test_createMarketForBrand_refusesADollarThisFactoryNeverRegistered() public {
        _approve(address(asset));

        MockAsset notADollar = new MockAsset();
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.BrandNotRegistered.selector, address(notADollar)
            )
        );
        factory.createMarketForBrand(address(asset), address(notADollar));

        (address reserveNative,) = reservePool.registerBrand("Outside Dollar", "outUSD", issuer);
        assertTrue(reservePool.isRegistered(reserveNative), "a genuine brand of the same reserve");
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.BrandNotRegistered.selector, reserveNative)
        );
        factory.createMarketForBrand(address(asset), reserveNative);
    }

    /// @notice The owner's asset list gates this path exactly as it gates `createMarket` — the
    ///         dollar's operator does not get to list an asset by quoting it.
    function test_createMarketForBrand_refusesAnAssetTheOwnerHasNotListed() public {
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.AssetNotApproved.selector, address(asset))
        );
        factory.createMarketForBrand(address(asset), brand);

        // And a revoked listing closes it again.
        _approve(address(asset));
        vm.prank(owner);
        factory.revokeAsset(address(asset));

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.AssetNotApproved.selector, address(asset))
        );
        factory.createMarketForBrand(address(asset), brand);
    }

    /// @notice One market per (reserve, asset), whatever the quote. A second dollar must not be
    ///         able to open a competing pool for a pair that already trades — that is the rule
    ///         the representation model exists to enforce.
    function test_createMarketForBrand_refusesAPairThatAlreadyHasAMarket() public {
        (uint256 id,,,) = _openShared(address(asset), issuer);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetAlreadyHasMarket.selector,
                address(reservePool),
                address(asset),
                id
            )
        );
        factory.createMarketForBrand(address(asset), brand);

        vm.prank(issuer);
        (address otherDollar,) = factory.registerBrand("Second Dollar", "secUSD");
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.AssetAlreadyHasMarket.selector,
                address(reservePool),
                address(asset),
                id
            )
        );
        factory.createMarketForBrand(address(asset), otherDollar);
    }

    /// @notice A dollar cannot be the asset of a market quoted in itself: the pool key would
    ///         name the same currency twice.
    function test_createMarketForBrand_refusesADollarQuotedInItself() public {
        _approve(brand);

        vm.prank(issuer);
        vm.expectRevert(AssetMarketFactory.AssetIsBrandToken.selector);
        factory.createMarketForBrand(brand, brand);
    }

    /// @notice A pool already initialised on the market's key is refused, never adopted.
    ///
    ///         This case is unreachable for `createMarket` — the unit is created in the same
    ///         transaction, so nobody could have keyed a pool on it — and reachable here, since
    ///         anyone can initialise a key on an existing dollar at any price they like.
    ///         Adopting it would open the market at a stranger's number instead of the owner's
    ///         listing, and the first liquidity in would be arbitraged to whichever is wrong.
    function test_createMarketForBrand_refusesAPoolSomebodyElseAlreadyPriced() public {
        _approve(address(asset));

        manager.initialize(_expectedKey(brand, address(asset)), TickMath.getSqrtPriceAtTick(0));

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.PoolAlreadyInitialised.selector, address(asset), brand
            )
        );
        factory.createMarketForBrand(address(asset), brand);
    }

    /// @notice A dollar registered in a reserve the owner has since retired is not a way back
    ///         into that reserve.
    function test_createMarketForBrand_refusesAReserveTheOwnerHasRetired() public {
        vm.prank(issuer);
        (address altBrand,) = factory.registerBrand(
            "Alt Dollar",
            "altUSD",
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            address(secondReserve)
        );
        _approve(address(asset));

        vm.prank(owner);
        factory.setApprovedReservePool(address(secondReserve), false);

        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.ReserveNotApproved.selector, address(secondReserve)
            )
        );
        factory.createMarketForBrand(address(asset), altBrand);
    }

    // ─── The LP stream ───────────────────────────────────────────────────

    /// @notice A shared-quote vault splits whatever it is sent exactly as any other market's
    ///         does: the protocol's `protocolBps` off the top, the remainder — rounding dust
    ///         included — streamed to this market's own LPs.
    ///
    ///         The funding is a transfer because it has to be: `harvest` cannot reach the
    ///         dollar's treasury (see the test below), so the stream is funded by whoever holds
    ///         the dollar's float choosing to fund this pool.
    function test_sweep_splitsWhatASharedQuoteVaultIsSentAndStreamsTheRest() public {
        (, address vaultAddress, address distributorAddress,) = _openShared(address(asset), issuer);
        BrandFeeVault vault = BrandFeeVault(vaultAddress);
        LpRewardDistributor distributor = LpRewardDistributor(distributorAddress);

        uint256 funded = 10_000e6;
        _sendBrand(vaultAddress, funded);
        assertEq(vault.balance(), funded, "the vault counts the dollar it was sent");

        vm.prank(keeper);
        (uint256 toProtocol, uint256 toLps) = vault.sweep();

        assertEq(
            toProtocol,
            funded * PROTOCOL_BPS / BPS_DENOMINATOR,
            "the protocol took the share the market was created with"
        );
        assertEq(toLps, funded - toProtocol, "and the LPs the whole remainder");
        assertEq(
            PooledBrandToken(brand).balanceOf(protocolTreasury),
            toProtocol,
            "the protocol's cut was paid, not merely accounted"
        );
        assertEq(
            PooledBrandToken(brand).balanceOf(distributorAddress),
            toLps,
            "and the LP share reached this market's distributor"
        );
        assertEq(distributor.totalNotified(), toLps, "which was told about it");
        assertGt(distributor.rewardRate(), 0, "so a reward period is running");
        assertEq(vault.balance(), 0, "nothing stranded in the vault");
    }

    /// @notice `harvest` reverts for a shared-quote vault, and that is the design.
    ///
    ///         The vault does not administer the dollar's treasury — the issuer does, because
    ///         the dollar's float is not this pool's income — and `PoolBrandTreasury.claim` is
    ///         `onlyAdmin`. Splitting one dollar's float across the pools quoting it would need
    ///         each pool's share of it, and a v4 pool's balances live in the singleton where
    ///         nobody can read them per pool, so the factory must not invent that policy.
    function test_harvest_revertsForASharedQuoteVaultThatDoesNotAdministerTheDollar() public {
        (, address vaultAddress,,) = _openShared(address(asset), issuer);

        // A float worth arguing over: a million of the dollar outstanding, earning in the
        // reserve. Without this the claim below would be a no-op and prove nothing.
        _sendBrand(stranger, 1_000_000e6);
        _accrueInTheReserve(10_000e6);

        uint256 pending = BrandFeeVault(vaultAddress).pendingYield();
        assertGt(pending, 0, "the dollar's float has earned");

        vm.prank(keeper);
        vm.expectRevert(PoolBrandTreasury.OnlyAdmin.selector);
        BrandFeeVault(vaultAddress).harvest();

        // Not a lockout: the yield the market's vault could not take is the issuer's, and it
        // reaches them. `setAdmin` is callable only by the current admin, so had creation
        // handed the admin to this pool's vault there would be no way back.
        vm.prank(issuer);
        uint256 claimed = PoolBrandTreasury(brandTreasury).claim(issuer);
        assertApproxEqAbs(claimed, pending, 1, "the issuer claims their dollar's float");
        assertEq(usdg.balanceOf(issuer), claimed, "and is paid it");
    }
}
