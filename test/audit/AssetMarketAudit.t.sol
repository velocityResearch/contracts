// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {StandInPermit2, StandInPositionManager} from "../markets/MarketRouter.t.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

contract A18 is IERC20Metadata {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function name() external pure returns (string memory) {
        return "A";
    }

    function symbol() external pure returns (string memory) {
        return "A";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function transfer(address t, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[t] += v;
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

/// @title AssetMarketAudit
/// @notice Regression tests for the findings of the 2026-09-09 AssetMarkets audit. Each one
///         began as a passing exploit against the pre-fix contracts; the assertions here are
///         the inverted form, so a regression re-opens the hole and fails the suite.
///         See `docs/audit-history.md`, which carries these findings as the A1 series.
///
///         **The squat is still cheap to mount and no longer buys anything.** In v3 a squatter
///         had to pay for a `CREATE2` pool deployment before they could price a market they had
///         front-run. A v4 pool is not a contract at all — it is a `PoolKey` hashed into an id
///         inside the singleton — so `PoolManager.initialize` on somebody else's key is a single
///         cheap call with no deployment behind it, and the market unit's address is still
///         predictable from `SharedReservePool`'s nonce. What changed is what the factory does
///         when it finds the key already live: it reverts `PoolAlreadyInitialised` rather than
///         adopting the pool at whatever price it was given. The unit is minted by
///         `createMarket` itself, in the same transaction, so a key that already exists is a
///         bug in the derivation rather than a race to tolerate — which is why the price band
///         (`maxSqrtDeviationBps`, `PoolPriceOutOfBand`) that used to stand between a squatter
///         and a mispriced launch is gone along with the adoption it guarded.
contract AssetMarketAudit is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockUSDC usdg;
    MockYieldSource ys;
    SharedReservePool pool;
    PoolManager manager;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;
    StandInPermit2 permit2;
    StandInPositionManager posm;
    A18 asset;

    address owner = address(0x0AD01);
    address ptreas = address(0xF33);
    address operator = address(0x0FE);
    address attacker = address(0xBAD);

    uint16 constant PROTOCOL_BPS = 500;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint256 constant PRICE = 154e18;
    uint16 constant CARDINALITY = 60;

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        ys = new MockYieldSource();
        pool = _deployReservePool(address(usdg), address(ys), owner);
        asset = new A18();

        manager = new PoolManager(address(this));
        feeHook = _deployHook();

        // Stand-ins for Uniswap's periphery, because the real `PositionManager` cannot be
        // compiled into this repo (see the note on `StandInPositionManager`). They mint into
        // the real `manager` above, so everything this suite checks about the router — its
        // bounds, its refunds, and the fact that its factory and singleton are immutable — is
        // checked against genuine v4 accounting. The deployed periphery is exercised on a fork,
        // in `test/markets/MarketRouterV4Fork.t.sol`.
        //
        // Deployed before the factory because the factory holds the position manager too: every
        // market's `LpRewardDistributor` takes custody of staked LP positions, so it is
        // initialised with the contract that minted them.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        factory = _deployFactory(
            pool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            ptreas,
            address(asset),
            PROTOCOL_BPS,
            owner
        );

        vm.prank(owner);
        feeHook.setRegistrar(address(factory));

        router = _newRouter(factory);
    }

    /// @dev Every router in this suite shares the one PositionManager, since they all trade in
    ///      the same singleton — which is exactly what the constructor's own check requires.
    function _newRouter(AssetMarketFactory f) internal returns (MarketRouter) {
        return _deployRouter(
            pool, f, IPositionManagerV4(address(posm)), IPermit2(address(permit2)), owner
        );
    }

    /// @dev A v4 hook's permissions are the low 14 bits of its address. `deployCodeTo` still
    ///      runs the constructor, so `Hooks.validateHookPermissions` still executes.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x1111 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    /// @dev The owner's half of opening this suite's market. Every economic parameter now
    ///      travels with the asset's approval rather than with the caller, which is what makes
    ///      creation itself safe to leave open to anyone.
    function _approveTheAsset() internal {
        _approveAsset(factory, address(asset), FEE, PRICE, CARDINALITY, "Cat Dollar", "catUSD");
    }

    /// @dev And the creator's half, which takes no parameters at all. The prank is not a
    ///      permission — creation is permissionless — it is only so the tests that care can
    ///      assert who got recorded as `creator`.
    function _createMarket()
        internal
        returns (uint256 id, address brand, address feeVault, address lpDistributor, bytes32 poolId)
    {
        _approveTheAsset();
        vm.prank(operator);
        return factory.createMarket(address(asset), address(0));
    }

    /// @dev The brand token the reserve is about to deploy, predictable from its public nonce
    ///      by anyone watching the mempool. This is the whole basis of the squat.
    function _predictBrand() internal view returns (address) {
        return vm.computeCreateAddress(address(pool), vm.getNonce(address(pool)));
    }

    function _keyFor(address brand) internal view returns (PoolKey memory) {
        (address c0, address c1) =
            brand < address(asset) ? (brand, address(asset)) : (address(asset), brand);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(feeHook))
        });
    }

    /// @dev Reproduces the squat: predict the brand address off the reserve pool's nonce,
    ///      initialise the market's v4 pool key first and price it. In v4 this costs one call
    ///      and no deployment at all.
    function _squatTheNextPool(uint160 hostile) internal returns (bytes32 squattedId) {
        PoolKey memory key = _keyFor(_predictBrand());
        vm.prank(attacker);
        manager.initialize(key, hostile);
        return PoolId.unwrap(key.toId());
    }

    function _livePrice(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(poolId));
    }

    // ─── HIGH-1: a front-runner cannot price a market's pool ─────────────

    /// @notice The finding's fix used to be a price band with an opt-in to adopt inside it.
    ///         There is no adoption left to bound: a live key means the unit this transaction
    ///         just minted collided with a pool somebody else made, and the factory refuses
    ///         outright. A squatter can still burn a creator's gas; they can no longer choose
    ///         the price the first liquidity goes in at, which is what the finding was about.
    function test_fix_preInitialisedPoolIsRejectedOutright() public {
        address predicted = _predictBrand();
        _squatTheNextPool(uint160(1) << 96); // a price of 1 for a $154 asset

        _approveTheAsset();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.PoolAlreadyInitialised.selector, address(asset), predicted
            )
        );
        factory.createMarket(address(asset), address(0));
    }

    /// @dev The v4-specific half of the same finding. A squatter no longer merely picks the
    ///      price — they also pick the pool's `PoolKey`, and an adopted key that named a
    ///      different hook would leave the market with no fee route and no oracle. The factory
    ///      builds the key itself and only ever looks at that one, so a stranger's pool at the
    ///      same pair under a different hook is a pool this factory cannot be pointed at.
    function test_fix_aSquatUnderADifferentHookIsNotTheMarketsPoolAtAll() public {
        address predicted = _predictBrand();
        (address c0, address c1) =
            predicted < address(asset) ? (predicted, address(asset)) : (address(asset), predicted);
        PoolKey memory hookless = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        vm.prank(attacker);
        manager.initialize(hookless, uint160(1) << 96);

        // The market is created at the approval's price regardless: the attacker initialised a
        // different pool, because the hook is part of a v4 pool's identity.
        (uint256 id, address brand,,, bytes32 poolId) = _createMarket();
        assertEq(id, 1);
        assertTrue(poolId != PoolId.unwrap(hookless.toId()), "not the pool the squatter made");
        assertEq(
            _livePrice(poolId),
            factory.quoteSqrtPriceX96(brand, address(asset), PRICE),
            "priced by this call, not by the squatter"
        );
        assertEq(factory.marketOfPool(poolId), id);
    }

    // ─── HIGH-2: seedLiquidity has real bounds ───────────────────────────
    //
    // Fixed independently on main (commit cbc4495), which went further than this audit asked
    // and put a deadline on EVERY router entry point, not just `seedLiquidity`. The coverage
    // lives with that work in `AssetMarketsSecurity.t.sol` —
    // `test_ExpiredEntrypointsRevertBeforePullingFunds` and the seeding tests beside it — so it
    // is deliberately not duplicated here.

    // ─── MEDIUM-4: the router cannot be wired to foreign periphery ────────

    /// @notice The original finding was that `MarketRouter` took its Uniswap periphery as
    ///         constructor arguments and had to prove they belonged to the same V3 deployment —
    ///         on this chain the canonical `SwapRouter` address holds an unrelated contract, so
    ///         a copy-pasted constant would have approved a stranger on every trade. That fix
    ///         was `PeripheryFactoryMismatch`.
    ///
    ///         Under v4 there is no periphery to get wrong: a swap is `unlock`/`swap`/settle
    ///         against the singleton, nothing is ever approved to it, and the router reads the
    ///         singleton off the factory that initialised the pools rather than being told
    ///         which one to use. The mismatch is structurally unrepresentable, so the check is
    ///         gone with the mechanism it guarded, and this asserts the property that made the
    ///         finding matter in the first place: **a router built against one factory cannot be
    ///         pointed at another factory's market.** A regression that re-introduced a settable
    ///         venue, or that let a router resolve a market id through anything but its own
    ///         factory, would have to delete this test to pass.
    function test_fix_aRouterCannotBePointedAtAnotherFactorysMarket() public {
        assertEq(
            address(router.poolManager()),
            address(factory.poolManager()),
            "the router's singleton is the factory's, by construction"
        );
        assertEq(address(router.factory()), address(factory));
        assertEq(address(router.reservePool()), address(pool));

        // A second, entirely separate factory on the same reserve and the same singleton.
        AssetMarketFactory other = _deployFactory(
            pool,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            ptreas,
            address(asset),
            PROTOCOL_BPS,
            owner
        );
        MarketRouter otherRouter = _newRouter(other);

        (uint256 id,,,,) = _createMarket();

        // Our router serves it; the other one has never heard of it, because a market id is
        // only ever resolved through the factory the router was built against.
        assertGe(router.marketLiquidity(id), 0);
        vm.expectRevert(AssetMarketFactory.UnknownMarket.selector);
        otherRouter.marketLiquidity(id);

        // And nothing on either router can be repointed: both hold their factory and their
        // singleton in immutables, with no setter anywhere.
        assertEq(address(otherRouter.factory()), address(other));
        assertTrue(address(otherRouter.factory()) != address(router.factory()));
    }

    /// @dev And the factory itself will not accept a hook that answers to a different
    ///      singleton, which is the one remaining way to point a market's swaps at a venue
    ///      nobody intended. Without this the hook would simply never be called: no protocol
    ///      fee on any swap, and — because v4 core keeps no observations of its own — no oracle
    ///      at all, leaving `consultTick` and every surface that charts a price with nothing.
    function test_fix_theFactoryRefusesAHookBoundToAnotherSingleton() public {
        PoolManager stranger = new PoolManager(address(this));
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x2222 << 144)
        );
        // A real hook PROXY on the stranger's singleton. Writing the implementation straight to
        // `flags` instead would leave `poolManager` unset — its constructor only disables the
        // initialiser — and the factory would then reject it for being bound to address zero,
        // which is a different bug from the one this test is about.
        _deployHookAt(flags, IPoolManager(address(stranger)), owner);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.HookManagerMismatch.selector, address(stranger), address(manager)
            )
        );
        _deployFactory(
            pool,
            IPoolManager(address(manager)),
            ProtocolFeeHook(flags),
            IPositionManagerV4(address(posm)),
            ptreas,
            address(asset),
            PROTOCOL_BPS,
            owner
        );
    }

    // ─── MEDIUM-1 and MEDIUM-2: retired by construction ──────────────────

    /// @notice Both findings were about the operator-configurable split. MEDIUM-1: `setSplit`
    ///         applied new weights to yield that had already accrued, so an operator could
    ///         advertise a generous share, let float earn under it, then drop it in the
    ///         transaction before a harvest. MEDIUM-2: `setOperator` moved control without
    ///         moving the payout, so a sold market kept paying its previous owner.
    ///
    ///         Neither is reachable any more, because the thing they exploited is gone: a
    ///         market's income goes to the `LpRewardDistributor` the factory deployed in the
    ///         same transaction and the vault holds in storage it can write exactly once, with
    ///         a protocol fee fixed at the same moment. There is no split to set, no operator
    ///         to pay, and no setter for either.
    ///
    ///         What follows tests that property rather than the old fixes, so re-introducing a
    ///         redirect fails the suite.
    function test_fix_thereIsNoWayToRedirectAMarketsYield() public {
        (uint256 id,,, address lpDistributor,) = _createMarket();
        BrandFeeVault vault = BrandFeeVault(factory.market(id).feeVault);

        LpRewardDistributor bound = vault.distributor();
        assertEq(address(bound), lpDistributor, "the vault pays this market's own distributor");
        assertEq(vault.lpBps(), 10_000 - PROTOCOL_BPS, "and everything but the fee is the LPs'");

        // Nothing an operator, the protocol, or a stranger can call moves that address.
        _accrue(vault, 5_000e6);
        vm.prank(operator);
        vault.harvest();
        vm.prank(attacker);
        vault.sweep();

        assertEq(
            address(vault.distributor()),
            lpDistributor,
            "the distributor is written once and never again"
        );
        assertEq(usdg.balanceOf(operator), 0, "the operator is not a recipient");

        // And the one write the vault ever allows is not reachable from out here at all: it
        // is the factory's, it happened inside `createMarket`, and it happens once.
        vm.expectRevert(BrandFeeVault.OnlyFactory.selector);
        vault.setDistributor(bound);
    }

    /// @dev The same property for the market's OTHER income stream, which is new in v4: the
    ///      pool's trading skim is bound to a recipient inside the hook, once, and the hook
    ///      refuses to rebind it — so where a market's trading fees go is as unrevokable as
    ///      where its float yield goes.
    function test_fix_aMarketsTradingSkimCannotBeRepointedEither() public {
        (uint256 id,, address feeVault,, bytes32 poolId) = _createMarket();
        // The skim is the protocol's revenue, so it is registered to the treasury rather than
        // to the market's own vault. What this test is about is that it cannot be MOVED.
        assertEq(feeHook.feeRecipientOf(PoolId.wrap(poolId)), ptreas);
        assertTrue(feeVault != ptreas);

        PoolKey memory key = factory.poolKeyOf(id);

        vm.prank(attacker);
        vm.expectRevert(ProtocolFeeHook.OnlyRegistrar.selector);
        feeHook.registerPool(key, attacker, 0);

        // Not even the registrar can, because the binding is one-shot.
        vm.prank(address(factory));
        vm.expectRevert(ProtocolFeeHook.AlreadyRegistered.selector);
        feeHook.registerPool(key, attacker, 0);

        assertEq(feeHook.feeRecipientOf(PoolId.wrap(poolId)), ptreas, "still where it was set");
    }

    /// @dev Whoever opened the market survives only in the registry, as a label. It buys no
    ///      authority over the market's economics, which is what made MEDIUM-2 possible in the
    ///      first place.
    function test_fix_theCreatorIsALabelNotAnAuthority() public {
        (uint256 id,,, address lpDistributor,) = _createMarket();
        AssetMarketFactory.Market memory m = factory.market(id);
        BrandFeeVault vault = BrandFeeVault(m.feeVault);

        assertEq(m.creator, operator);

        _accrue(vault, 5_000e6);
        uint256 claimed = vault.harvest();
        (uint256 toProtocol, uint256 toLps) = vault.sweep();

        assertEq(toProtocol + toLps, claimed, "the claim has exactly two destinations");
        assertEq(usdg.balanceOf(ptreas), toProtocol);
        assertEq(
            vault.brandToken().balanceOf(lpDistributor),
            toLps,
            "and the LPs' share is at their distributor, in the unit it pays out"
        );
        assertEq(usdg.balanceOf(m.creator), 0, "the creator is neither of them");
    }

    // ─── LOW-1: retired with the split it depended on ────────────────────

    /// @notice The accepted low was that every slice floored and the remainder fell to the LP
    ///         escrow, so a griefer harvesting at 1-wei granularity could route a small market's
    ///         whole yield to LPs. There is no third recipient to leak to any more, and the LPs
    ///         take the remainder rather than their own `mulDiv`, so a floored fee leaves its
    ///         wei exactly where the market was sending it anyway.
    ///
    ///         What a griefer can still do is call `harvest` two hundred times. It claims what
    ///         has accrued and nothing else, credits it to the same vault either way, and bills
    ///         them for the gas.
    function test_known_harvestSpamMovesNothingToAnyone() public {
        (uint256 id,,,,) = _createMarket();
        AssetMarketFactory.Market memory m = factory.market(id);
        BrandFeeVault vault = BrandFeeVault(m.feeVault);

        _accrue(vault, 2_000e6);
        uint256 genuine = vault.harvest();
        assertGt(genuine, 0, "a real harvest does credit");

        usdg.mint(address(this), 10_000e6);
        usdg.approve(address(ys), type(uint256).max);

        for (uint256 i; i < 200; ++i) {
            ys.simulateYield(address(usdg), 1);
            vm.prank(attacker);
            vault.harvest();
        }

        // Every wei of those 200 accruals is in the vault, addressed to the same two places it
        // would have reached in one harvest. Nothing is stranded and nothing is misrouted.
        assertEq(vault.totalHarvested(), vault.balance(), "all of it is still here");
        assertGe(vault.totalHarvested(), genuine);
        assertLe(vault.totalHarvested(), genuine + 200);

        (uint256 toProtocol, uint256 toLps) = vault.sweep();
        assertEq(toProtocol + toLps, vault.totalHarvested(), "and nothing at all is lost");
        assertEq(usdg.balanceOf(operator), 0, "the creator is not a recipient at all");
        assertEq(vault.balance(), 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev A market earns on the brand supply outstanding against it, so the float has to
    ///      exist and be deployed before there is anything to claim. Where that float sits does
    ///      not matter — the reserve attributes by outstanding supply, not by holder.
    function _accrue(BrandFeeVault vault, uint256 amount) internal {
        address brand = address(vault.brandToken());
        usdg.mint(address(this), amount);
        usdg.approve(address(pool), amount);
        pool.mint(brand, amount, address(this));
        pool.deployIdle();

        usdg.mint(address(this), amount);
        usdg.approve(address(ys), amount);
        ys.simulateYield(address(usdg), amount);
    }
}
