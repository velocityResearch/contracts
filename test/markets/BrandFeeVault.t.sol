// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title BrandFeeVaultTest
/// @notice One market's whole income path: claim the float, take the protocol's cut, stream the
///         rest to the people who provide the market's liquidity.
///
///         Three properties this suite exists for.
///
///         **All of it, less the protocol's share, reaches the LPs.** The LP leg takes the
///         entire remainder including the rounding dust, so with the protocol fee at zero the
///         whole float is the liquidity providers' — which is the claim the product surface
///         makes.
///
///         **The LP share leaves as brandUSD and lands as a stream.** The vault holds whichever
///         wrapper the reserve paid it in, mints what it must, transfers to the market's
///         `LpRewardDistributor` and tells it. It does not donate into the pool: with the whole
///         float on the line, a donation weighted by liquidity at one instant would be taken by
///         whoever adds liquidity for that instant and removes it in the same transaction, and
///         `sweep` is permissionless by design.
///
///         **Nothing downstream can strand income.** `harvest` never touches the distributor,
///         and the only thing `sweep` can fail on is the reserve's own mint — the same coupling
///         `SharedReservePool.mint` documents — which a later call retries.
///
/// @dev    Time is always moved with `vm.getBlockTimestamp()`, never a cached `block.timestamp`.
///         This project builds with `via_ir`, which treats TIMESTAMP as pure and re-reads it, so
///         a local captured before a `vm.warp` is not a snapshot and a second warp computed from
///         it lands somewhere else entirely.
contract BrandFeeVaultTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;

    // ─── Venue ───────────────────────────────────────────────────────────

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint24 constant PROTOCOL_FEE_PIPS = 1000; // 0.10%

    PoolManager manager;
    ProtocolFeeHook hook;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    // ─── The market under test ───────────────────────────────────────────

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;

    address brandToken;
    address treasury;
    MockAsset asset;
    PoolKey key;

    BrandFeeVault vault;
    LpRewardDistributor distributor;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address alice = address(0xA11CE);
    address keeper = address(0x33333);

    /// @dev Zero for most of the suite: the protocol's revenue is the trading skim, and the
    ///      float belongs to the liquidity that gave the market its depth. The tests under
    ///      "The split" are the ones that exercise a non-zero fee.
    uint16 constant PROTOCOL_BPS = 0;
    uint32 constant REWARDS_DURATION = 7 days;

    uint256 constant MINTED = 1_000_000e6;

    /// @dev A market is three contracts that only make sense together, so tests that need one
    ///      take the whole thing rather than three locals.
    struct Market {
        address brand;
        address treasury;
        BrandFeeVault vault;
        LpRewardDistributor distributor;
        PoolKey key;
    }

    /// @dev This contract stands in for `AssetMarketFactory`, which is the only caller
    ///      `setDistributor` accepts and the only address that ever deploys a vault and a
    ///      distributor as a pair. Everything else here is reached the way anyone would.
    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        hook = _deployHook();
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        vm.prank(owner);
        hook.setRegistrar(address(this));

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);
        asset = new MockAsset();

        Market memory m = _createMarket("Cashcat Dollar", "catUSD", address(asset), PROTOCOL_BPS);
        brandToken = m.brand;
        treasury = m.treasury;
        vault = m.vault;
        distributor = m.distributor;
        key = m.key;

        // A million brand tokens outstanding, all of it float earning in the reserve.
        usdg.mint(alice, MINTED);
        vm.startPrank(alice);
        usdg.approve(address(reserve), MINTED);
        reserve.mint(brandToken, MINTED, alice);
        vm.stopPrank();

        reserve.deployIdle();
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits live in the low 14 bits of its own address, so the
    ///      address is not a free choice. `deployCodeTo` writes the contract where we want it
    ///      and still runs the constructor, so `Hooks.validateHookPermissions` still executes.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    function _poolKey(address brand, address assetToken) internal view returns (PoolKey memory) {
        (address c0, address c1) = brand < assetToken ? (brand, assetToken) : (assetToken, brand);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The factory's `_openMarket` ordering, reproduced: pool, then vault, then
    ///      distributor — each written once into the one above it — then the one-shot
    ///      `setDistributor` that closes the loop the two initialisers cannot, then the hook
    ///      registration that points the market's trading skim at the protocol treasury.
    function _createMarket(
        string memory name,
        string memory symbol,
        address assetToken,
        uint16 protocolBps
    ) internal returns (Market memory m) {
        (m.brand, m.treasury) = reserve.registerBrand(name, symbol, address(this));
        m.key = _poolKey(m.brand, assetToken);
        manager.initialize(m.key, TickMath.getSqrtPriceAtTick(0));

        m.vault = _newVault(m.treasury, m.brand, assetToken, protocolBps);
        PoolBrandTreasury(m.treasury).setAdmin(address(m.vault));
        m.distributor = _newDistributor(m.brand, m.key, address(m.vault));
        m.vault.setDistributor(m.distributor);

        hook.registerPool(m.key, protocolTreasury, PROTOCOL_FEE_PIPS);
        hook.increaseObservationCardinalityNext(m.key, 64);
    }

    /// @dev A beacon proxy, exactly as `MarketDeployer` builds one on chain: same beacon, same
    ///      initialiser, so this suite exercises the deployed shape rather than a bare contract
    ///      that no longer exists anywhere in production.
    function _newVault(
        address brandTreasury_,
        address brand,
        address assetToken,
        uint16 protocolBps
    ) internal returns (BrandFeeVault) {
        return BrandFeeVault(
            address(
                new BeaconProxy(
                    address(beacons.vault),
                    abi.encodeCall(
                        BrandFeeVault.initialize,
                        (
                            reserve,
                            brandTreasury_,
                            brand,
                            assetToken,
                            protocolTreasury,
                            protocolBps,
                            address(this),
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    function _newDistributor(address brand, PoolKey memory k, address feeVault)
        internal
        returns (LpRewardDistributor)
    {
        return LpRewardDistributor(
            address(
                new BeaconProxy(
                    address(beacons.distributor),
                    abi.encodeCall(
                        LpRewardDistributor.initialize,
                        (
                            IPositionManagerV4(address(posm)),
                            reserve,
                            k,
                            brand,
                            feeVault,
                            REWARDS_DURATION,
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    /// @dev Grow the reserve's yield so `pendingYield` becomes claimable. `amount` is what the
    ///      market's own brand should end up entitled to, which with one brand outstanding is
    ///      the whole of the growth.
    function _accrue(uint256 amount) internal {
        uint256 supply = reserve.totalPooledSupply();
        require(supply > 0, "nothing outstanding to accrue against");

        usdg.mint(address(this), amount);
        usdg.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdg), amount);
    }

    // ─── Income ──────────────────────────────────────────────────────────

    function test_harvest_pullsTheFloatAndIsIdempotent() public {
        _accrue(10_000e6);

        uint256 pending = vault.pendingYield();
        assertGt(pending, 0, "the float accrued");

        vm.prank(keeper);
        uint256 claimed = vault.harvest();
        assertApproxEqAbs(claimed, pending, 1, "the vault claimed what had accrued");
        assertEq(vault.balance(), claimed, "and holds it");
        assertEq(vault.totalHarvested(), claimed);

        // Spamming it moves nothing: the reserve pays what has accrued and no more.
        vm.prank(keeper);
        assertEq(vault.harvest(), 0, "nothing left to claim");
        assertEq(vault.balance(), claimed, "and the balance is unchanged");
    }

    function test_balance_addsBothWrappersBecauseTheyAreTheSameClaim() public {
        usdg.mint(address(vault), 100e6);
        assertEq(vault.balance(), 100e6, "USDG counts");

        vm.startPrank(alice);
        IERC20(brandToken).transfer(address(vault), 50e6);
        vm.stopPrank();
        assertEq(vault.balance(), 150e6, "and brandUSD adds to it, 1:1");
    }

    // ─── The split ───────────────────────────────────────────────────────

    /// @notice With the protocol fee at zero — the shipped default — the entire float reaches
    ///         the market's LPs.
    function test_sweep_sendsTheWholeFloatToTheDistributorWhenTheFeeIsZero() public {
        _accrue(10_000e6);
        vm.prank(keeper);
        uint256 claimed = vault.harvest();

        vm.prank(keeper);
        (uint256 toProtocol, uint256 toLps) = vault.sweep();

        assertEq(toProtocol, 0, "nothing to the protocol");
        assertEq(toLps, claimed, "all of it to the LPs");
        assertEq(IERC20(brandToken).balanceOf(address(distributor)), claimed, "and it is there now");
        assertEq(vault.balance(), 0, "the vault keeps nothing");
        assertEq(vault.totalToLps(), claimed);
        assertEq(distributor.totalNotified(), claimed, "the distributor was told");
        assertEq(distributor.periodFinish(), vm.getBlockTimestamp() + REWARDS_DURATION);
    }

    function test_sweep_takesTheProtocolsShareAndGivesTheLpsEverythingElse() public {
        Market memory m = _createMarket("Fee Dollar", "feeUSD", address(asset), 2_000);

        // This market's own float: mint into its brand so the yield is attributable to it.
        usdg.mint(alice, 500_000e6);
        vm.startPrank(alice);
        usdg.approve(address(reserve), 500_000e6);
        reserve.mint(m.brand, 500_000e6, alice);
        vm.stopPrank();
        reserve.deployIdle();

        _accrue(10_000e6);
        vm.prank(keeper);
        uint256 claimed = m.vault.harvest();
        assertGt(claimed, 0);

        vm.prank(keeper);
        (uint256 toProtocol, uint256 toLps) = m.vault.sweep();

        assertEq(toProtocol, claimed * 2_000 / 10_000, "the protocol's fixed share");
        assertEq(toLps, claimed - toProtocol, "and the LPs take every remaining wei");
        assertEq(toProtocol + toLps, claimed, "nothing is held back");
        assertEq(usdg.balanceOf(protocolTreasury), toProtocol, "paid in USDG as far as it goes");
        assertEq(IERC20(m.brand).balanceOf(address(m.distributor)), toLps);
    }

    /// @notice The dust goes to the LPs, not to the protocol. A three-way split used to leave
    ///         it with the buyback; there are two legs now and the remainder is the LPs'.
    function test_sweep_roundingDustFavoursTheLps() public {
        Market memory m = _createMarket("Odd Dollar", "oddUSD", address(asset), 3_333);

        // Above `minSweep` and not divisible by 3,333 bps. Held in locals because a literal
        // division here is rational, not integer, and would not compile.
        uint256 funding = 1_000_001;
        usdg.mint(address(m.vault), funding);

        vm.prank(keeper);
        (uint256 toProtocol, uint256 toLps) = m.vault.sweep();

        assertEq(toProtocol, funding * 3_333 / 10_000, "floor division for the protocol");
        assertEq(toLps, funding - toProtocol, "the remainder, dust included");
    }

    function test_sweep_mintsOnlyTheUsdgRemainderIntoBrandUsd() public {
        // Half the balance already in brandUSD: only the other half should be minted.
        vm.startPrank(alice);
        IERC20(brandToken).transfer(address(vault), 400e6);
        vm.stopPrank();
        usdg.mint(address(vault), 600e6);

        uint256 supplyBefore = IERC20(brandToken).totalSupply();

        vm.prank(keeper);
        (, uint256 toLps) = vault.sweep();

        assertEq(toLps, 1_000e6);
        assertEq(
            IERC20(brandToken).totalSupply() - supplyBefore, 600e6, "only the USDG leg was minted"
        );
        assertEq(IERC20(brandToken).balanceOf(address(distributor)), 1_000e6);
    }

    function test_sweep_refusesDustBelowOneWholeReserveUnit() public {
        assertEq(vault.minSweep(), 1e6, "one USDG at the reserve asset's decimals");

        usdg.mint(address(vault), 1e6 - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BrandFeeVault.BelowMinSweep.selector, 1e6 - 1, 1e6));
        vault.sweep();

        usdg.mint(address(vault), 1);
        vm.prank(keeper);
        (, uint256 toLps) = vault.sweep();
        assertEq(toLps, 1e6, "exactly at the floor is enough");
    }

    function test_sweep_onAnEmptyVaultReverts() public {
        vm.prank(keeper);
        vm.expectRevert(BrandFeeVault.NothingToSweep.selector);
        vault.sweep();
    }

    /// @notice Permissionless, and worth nothing to the caller: the destinations are fixed at
    ///         initialisation, and the distributor's period never moves for a notify inside it,
    ///         so picking the moment buys nobody anything.
    function test_sweep_isPermissionlessAndItsTimingIsWorthless() public {
        _accrue(10_000e6);
        vm.prank(keeper);
        vault.harvest();

        vm.prank(alice);
        (, uint256 first) = vault.sweep();
        uint256 finish = distributor.periodFinish();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _accrue(10_000e6);
        vm.prank(address(0xBEEF));
        vault.harvest();
        vm.prank(address(0xBEEF));
        (, uint256 second) = vault.sweep();

        assertGt(first, 0);
        assertGt(second, 0);
        assertEq(distributor.periodFinish(), finish, "a second sweep does not move the end date");
    }

    function test_lpBps_isWhateverTheProtocolDoesNotTake() public {
        assertEq(vault.lpBps(), 10_000, "the shipped default");

        Market memory m = _createMarket("Fee Dollar", "feeUSD", address(asset), 1_500);
        assertEq(m.vault.lpBps(), 8_500);
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_setDistributor_isTheFactorysAndHappensOnce() public {
        vm.prank(alice);
        vm.expectRevert(BrandFeeVault.OnlyFactory.selector);
        vault.setDistributor(distributor);

        // The factory is this contract, and its one write is already spent.
        vm.expectRevert(BrandFeeVault.AlreadyInitialized.selector);
        vault.setDistributor(distributor);
    }

    function test_sweep_beforeTheDistributorIsBoundReverts() public {
        (address brand, address brandTreasury) =
            reserve.registerBrand("Loose Dollar", "looseUSD", address(this));
        BrandFeeVault loose = _newVault(brandTreasury, brand, address(asset), 0);

        usdg.mint(address(loose), 10e6);
        vm.expectRevert(BrandFeeVault.NotInitialized.selector);
        loose.sweep();
    }

    function test_initialize_rejectsAFeeThatWouldLeaveTheLpsNothing() public {
        (address brand, address brandTreasury) =
            reserve.registerBrand("Greedy Dollar", "grdUSD", address(this));

        vm.expectRevert(BrandFeeVault.FeeLeavesLpsNothing.selector);
        new BeaconProxy(
            address(beacons.vault),
            abi.encodeCall(
                BrandFeeVault.initialize,
                (
                    reserve,
                    brandTreasury,
                    brand,
                    address(asset),
                    protocolTreasury,
                    10_000,
                    address(this),
                    address(protocolGuard)
                )
            )
        );
    }

    function test_initialize_rejectsZeroWiring() public {
        (address brand, address brandTreasury) =
            reserve.registerBrand("Zero Dollar", "zeroUSD", address(this));

        vm.expectRevert(BrandFeeVault.ZeroAddress.selector);
        new BeaconProxy(
            address(beacons.vault),
            abi.encodeCall(
                BrandFeeVault.initialize,
                (
                    reserve,
                    brandTreasury,
                    brand,
                    address(asset),
                    address(0),
                    0,
                    address(this),
                    address(protocolGuard)
                )
            )
        );
    }

    // ─── Stray asset ─────────────────────────────────────────────────────

    /// @notice Nothing routes the market's asset here any more, so this recovers donations and
    ///         mistakes. It goes to the protocol treasury rather than to the LPs, because the
    ///         distributor pays one token and handing LPs an arbitrary market token would give
    ///         them a position they never asked for.
    function test_sweepStrayAsset_sendsItToTheProtocolTreasury() public {
        asset.mint(address(vault), 5e18);

        vm.prank(keeper);
        uint256 recovered = vault.sweepStrayAsset();

        assertEq(recovered, 5e18);
        assertEq(asset.balanceOf(protocolTreasury), 5e18);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalStrayAssetRecovered(), 5e18);
        assertEq(vault.totalToLps(), 0, "and it is not counted as income");
    }

    function test_sweepStrayAsset_withNothingHeldReverts() public {
        vm.prank(keeper);
        vm.expectRevert(BrandFeeVault.NothingToSweep.selector);
        vault.sweepStrayAsset();
    }

    // ─── Pausing ─────────────────────────────────────────────────────────

    /// @notice None of these is anyone's exit — a holder's is `SharedReservePool.redeem` and an
    ///         LP's is `LpRewardDistributor.unstake`, neither of which pauses — so halting them
    ///         delays a payout and costs nobody their capital.
    function test_pauseStopsEveryIncomePath() public {
        _accrue(10_000e6);
        vm.prank(keeper);
        vault.harvest();
        asset.mint(address(vault), 1e18);

        _pauseProtocol();

        vm.prank(keeper);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        vault.harvest();

        vm.prank(keeper);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        vault.sweep();

        vm.prank(keeper);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        vault.sweepStrayAsset();

        // And the holder's exit is untouched while all of that is halted.
        vm.prank(alice);
        assertGt(reserve.redeem(brandToken, 1_000e6, alice), 0, "redemption never pauses");

        _unpauseProtocol();
        vm.prank(keeper);
        (, uint256 toLps) = vault.sweep();
        assertGt(toLps, 0, "and the delayed payout still lands afterwards");
    }
}
