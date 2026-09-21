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
import {Currency} from "v4-core/types/Currency.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title BrandFeeVaultSplitsTest
/// @notice The configurable revenue split: who may set it, what it may sum to, and — the two
///         properties the whole design exists for — that a distribution creates and loses
///         nothing, and that reconfiguring it cannot touch money already earned.
///
///         **Amounts are funded directly rather than harvested.** The split's arithmetic is
///         what is under test, and a harvest hands the vault whatever the yield source happens
///         to have rounded to. Minting a chosen number of USDG into the vault makes every
///         expected share an exact integer this test can state.
contract BrandFeeVaultSplitsTest is Test, StackFixture {
    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint24 constant PROTOCOL_FEE_PIPS = 1000;
    uint32 constant REWARDS_DURATION = 7 days;

    /// @dev Deliberately not a round number: floor division has to leave a remainder for the
    ///      residual leg to be seen taking it.
    uint256 constant FUNDED = 1_000_000_007;

    bytes32 constant ROLE_CREATOR = "creator";
    bytes32 constant ROLE_PARTNER = "partner";
    bytes32 constant ROLE_REFERRAL = "referral";

    PoolManager manager;
    ProtocolFeeHook hook;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;
    MockAsset asset;

    address brandToken;
    BrandFeeVault vault;
    LpRewardDistributor distributor;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address alice = address(0xA11CE);
    address creator = address(0xC12A704);
    address partner = address(0x9A27);
    address referral = address(0x8EF);

    struct Market {
        address brand;
        address treasury;
        BrandFeeVault vault;
        LpRewardDistributor distributor;
        PoolKey key;
    }

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

        Market memory m = _createMarket("Cashcat Dollar", "catUSD", 0);
        brandToken = m.brand;
        vault = m.vault;
        distributor = m.distributor;

        // Something outstanding, so the reserve can mint the LP leg's brandUSD.
        usdg.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdg.approve(address(reserve), 1_000_000e6);
        reserve.mint(brandToken, 1_000_000e6, alice);
        vm.stopPrank();
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    function _poolKey(address brand) internal view returns (PoolKey memory) {
        address assetToken = address(asset);
        (address c0, address c1) = brand < assetToken ? (brand, assetToken) : (assetToken, brand);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The factory's `_openMarket` ordering, reproduced: this contract stands in for the
    ///      factory, which is the only caller `setDistributor` accepts.
    function _createMarket(string memory name, string memory symbol, uint16 protocolBps)
        internal
        returns (Market memory m)
    {
        (m.brand, m.treasury) = reserve.registerBrand(name, symbol, address(this));
        m.key = _poolKey(m.brand);
        manager.initialize(m.key, TickMath.getSqrtPriceAtTick(0));

        m.vault = BrandFeeVault(
            address(
                new BeaconProxy(
                    address(beacons.vault),
                    abi.encodeCall(
                        BrandFeeVault.initialize,
                        (
                            reserve,
                            m.treasury,
                            m.brand,
                            address(asset),
                            protocolTreasury,
                            protocolBps,
                            address(this),
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
        PoolBrandTreasury(m.treasury).setAdmin(address(m.vault));

        m.distributor = LpRewardDistributor(
            address(
                new BeaconProxy(
                    address(beacons.distributor),
                    abi.encodeCall(
                        LpRewardDistributor.initialize,
                        (
                            IPositionManagerV4(address(posm)),
                            reserve,
                            m.key,
                            m.brand,
                            address(m.vault),
                            REWARDS_DURATION,
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
        m.vault.setDistributor(m.distributor);

        hook.registerPool(m.key, protocolTreasury, PROTOCOL_FEE_PIPS);
    }

    function _entry(address recipient, uint16 bps, bytes32 role)
        internal
        pure
        returns (BrandFeeVault.SplitEntry memory)
    {
        return BrandFeeVault.SplitEntry({recipient: recipient, bps: bps, role: role});
    }

    function _threeWay() internal view returns (BrandFeeVault.SplitEntry[] memory e) {
        e = new BrandFeeVault.SplitEntry[](3);
        e[0] = _entry(creator, 2500, ROLE_CREATOR);
        e[1] = _entry(partner, 1000, ROLE_PARTNER);
        e[2] = _entry(referral, 33, ROLE_REFERRAL);
    }

    function _one(address recipient, uint16 bps)
        internal
        pure
        returns (BrandFeeVault.SplitEntry[] memory e)
    {
        e = new BrandFeeVault.SplitEntry[](1);
        e[0] = _entry(recipient, bps, ROLE_PARTNER);
    }

    function _setSplits(BrandFeeVault.SplitEntry[] memory entries) internal {
        vm.prank(stackOwner);
        vault.setSplits(entries);
    }

    // ─── The default: nothing configured, nothing changed ────────────────

    /// @notice A vault with no configured recipients behaves exactly as it did before the
    ///         registry existed: the protocol's leg, then all of the rest — dust included — to
    ///         the market's LPs.
    function test_sweep_withNoConfiguredSplitIsUnchanged() public {
        usdg.mint(address(vault), FUNDED);

        assertEq(vault.splitCount(), 0, "nothing configured");
        assertEq(vault.totalSplitBps(), 0);
        assertEq(vault.lpBps(), 10_000, "the whole float is the LPs'");
        assertEq(vault.distributableBalance(), FUNDED, "and all of it is distributable");

        (uint256 toProtocol, uint256 toLps) = vault.sweep();

        assertEq(toProtocol, 0, "protocolBps is zero in this market");
        assertEq(toLps, FUNDED, "so the LPs take everything");
        assertEq(IERC20(brandToken).balanceOf(address(distributor)), FUNDED, "and hold it");
        assertEq(vault.balance(), 0, "the vault kept nothing");
        assertEq(vault.reservedForSplits(), 0);
        assertEq(vault.totalToSplits(), 0);
    }

    // ─── Exact integer distribution ──────────────────────────────────────

    /// @notice Three configured legs plus the residual: every share is a floor, the residual
    ///         takes the whole remainder, and the four sum to the input exactly.
    function test_sweep_threeWaySplitIsExactAndGivesTheDustToTheResidual() public {
        _setSplits(_threeWay());
        usdg.mint(address(vault), FUNDED);

        assertEq(vault.totalSplitBps(), 3533);
        assertEq(vault.lpBps(), 10_000 - 3533);

        (uint256 toProtocol, uint256 toLps) = vault.sweep();

        uint256 expectedCreator = FUNDED * 2500 / 10_000;
        uint256 expectedPartner = FUNDED * 1000 / 10_000;
        uint256 expectedReferral = FUNDED * 33 / 10_000;

        assertEq(vault.claimableSplit(creator), expectedCreator, "creator's floored share");
        assertEq(vault.claimableSplit(partner), expectedPartner, "partner's floored share");
        assertEq(vault.claimableSplit(referral), expectedReferral, "referral's floored share");

        uint256 credited = expectedCreator + expectedPartner + expectedReferral;
        assertEq(toProtocol, 0, "no protocol leg in this market");
        assertEq(toProtocol + credited + toLps, FUNDED, "nothing created and nothing lost");

        // The residual takes strictly more than its own floored share: the dust is its.
        assertGt(toLps, FUNDED * (10_000 - 3533) / 10_000, "the rounding dust went to the LPs");

        assertEq(IERC20(brandToken).balanceOf(address(distributor)), toLps, "LPs paid in full");
        assertEq(vault.reservedForSplits(), credited, "and the credits are still held here");
        assertEq(vault.balance(), credited, "exactly, in whichever wrapper");
        assertEq(vault.totalToSplits(), credited);
    }

    /// @notice A credited balance is held back from the next sweep, and paying it out frees
    ///         exactly what it reserved.
    function test_claimSplit_isHeldBackFromTheNextSweepAndThenPaid() public {
        _setSplits(_threeWay());
        usdg.mint(address(vault), FUNDED);
        vault.sweep();

        uint256 reserved = vault.reservedForSplits();
        assertGt(reserved, 0);
        assertEq(vault.distributableBalance(), 0, "the vault holds only what it owes");

        // The reserved money is not income a second time.
        vm.expectRevert(BrandFeeVault.NothingToSweep.selector);
        vault.sweep();

        uint256 owed = vault.claimableSplit(creator);
        uint256 paid = vault.claimSplit(creator);

        assertEq(paid, owed, "paid what was credited");
        assertEq(
            usdg.balanceOf(creator) + IERC20(brandToken).balanceOf(creator),
            owed,
            "and the recipient holds it, in either wrapper"
        );
        assertEq(vault.claimableSplit(creator), 0, "ledger cleared");
        assertEq(vault.reservedForSplits(), reserved - owed, "reserve freed by exactly that");

        vm.expectRevert(BrandFeeVault.NothingToClaim.selector);
        vault.claimSplit(creator);
    }

    // ─── Reconfiguration cannot move earned money ────────────────────────

    /// @notice The property the pull-based ledger exists for: a recipient dropped from the
    ///         split keeps everything it had already earned, and the new list earns only from
    ///         the sweep that follows it.
    function test_setSplits_doesNotMoveAlreadyAccruedBalances() public {
        _setSplits(_one(creator, 2000));
        usdg.mint(address(vault), FUNDED);
        vault.sweep();

        uint256 earned = vault.claimableSplit(creator);
        assertEq(earned, FUNDED * 2000 / 10_000, "earned under the old split");

        // Creator removed entirely; partner takes its place.
        _setSplits(_one(partner, 2000));

        assertEq(vault.claimableSplit(creator), earned, "the old credit is untouched");
        assertEq(vault.claimableSplit(partner), 0, "and the new leg starts at nothing");

        usdg.mint(address(vault), FUNDED);
        vault.sweep();

        assertEq(vault.claimableSplit(creator), earned, "still untouched by the second sweep");
        assertEq(vault.claimableSplit(partner), FUNDED * 2000 / 10_000, "partner earned once");

        // And a recipient nobody's list mentions any more can still take its money out.
        assertEq(vault.claimSplit(creator), earned, "a removed recipient can still claim");
    }

    // ─── Configuration is bounded and owned ──────────────────────────────

    function test_setSplits_onlyTheSplitAdminMayConfigure() public {
        assertEq(vault.splitAdmin(), stackOwner, "the guard's owner: the protocol timelock");

        BrandFeeVault.SplitEntry[] memory e = _one(creator, 2000);

        vm.prank(alice);
        vm.expectRevert(BrandFeeVault.NotSplitAdmin.selector);
        vault.setSplits(e);

        // Not the factory either, which is this contract in this fixture.
        vm.expectRevert(BrandFeeVault.NotSplitAdmin.selector);
        vault.setSplits(e);

        vm.prank(stackOwner);
        vault.setSplits(e);
        assertEq(vault.splitCount(), 1);
    }

    /// @notice The total of every configured leg, plus the protocol's own, must leave the
    ///         liquidity providers something — the invariant `initialize` holds for
    ///         `protocolBps` alone, extended to the whole list.
    function test_setSplits_rejectsATotalThatLeavesTheLpsNothing() public {
        BrandFeeVault.SplitEntry[] memory whole = new BrandFeeVault.SplitEntry[](2);
        whole[0] = _entry(creator, 6000, ROLE_CREATOR);
        whole[1] = _entry(partner, 4000, ROLE_PARTNER);

        vm.prank(stackOwner);
        vm.expectRevert(BrandFeeVault.FeeLeavesLpsNothing.selector);
        vault.setSplits(whole);

        // Over the whole is refused the same way.
        whole[1] = _entry(partner, 9000, ROLE_PARTNER);
        vm.prank(stackOwner);
        vm.expectRevert(BrandFeeVault.FeeLeavesLpsNothing.selector);
        vault.setSplits(whole);

        // One basis point short of the whole is fine.
        whole[0] = _entry(creator, 6000, ROLE_CREATOR);
        whole[1] = _entry(partner, 3999, ROLE_PARTNER);
        vm.prank(stackOwner);
        vault.setSplits(whole);
        assertEq(vault.totalSplitBps(), 9999);
        assertEq(vault.lpBps(), 1);
    }

    /// @notice The protocol's own leg is part of the total: a market that already gives the
    ///         protocol 20% may configure at most 79.99% more.
    function test_setSplits_countsTheProtocolLegAgainstTheTotal() public {
        Market memory m = _createMarket("Feed Dollar", "feedUSD", 2_000);

        vm.prank(stackOwner);
        vm.expectRevert(BrandFeeVault.FeeLeavesLpsNothing.selector);
        m.vault.setSplits(_one(creator, 8_000));

        vm.prank(stackOwner);
        m.vault.setSplits(_one(creator, 7_999));
        assertEq(m.vault.lpBps(), 1, "the LPs keep the last basis point");
    }

    function test_setSplits_rejectsBadEntries() public {
        vm.startPrank(stackOwner);

        BrandFeeVault.SplitEntry[] memory dup = new BrandFeeVault.SplitEntry[](2);
        dup[0] = _entry(creator, 1000, ROLE_CREATOR);
        dup[1] = _entry(creator, 1000, ROLE_PARTNER);
        vm.expectRevert(
            abi.encodeWithSelector(BrandFeeVault.DuplicateSplitRecipient.selector, creator)
        );
        vault.setSplits(dup);

        vm.expectRevert(BrandFeeVault.ZeroAddress.selector);
        vault.setSplits(_one(address(0), 1000));

        vm.expectRevert(BrandFeeVault.ZeroSplitBps.selector);
        vault.setSplits(_one(creator, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                BrandFeeVault.InvalidSplitRecipient.selector, address(distributor)
            )
        );
        vault.setSplits(_one(address(distributor), 1000));

        BrandFeeVault.SplitEntry[] memory tooMany = new BrandFeeVault.SplitEntry[](9);
        for (uint256 i; i < 9; ++i) {
            tooMany[i] = _entry(address(uint160(0x1000 + i)), 100, ROLE_PARTNER);
        }
        vm.expectRevert(BrandFeeVault.TooManySplitRecipients.selector);
        vault.setSplits(tooMany);

        vm.stopPrank();
    }
}
