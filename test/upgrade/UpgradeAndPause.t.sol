// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";

/// @dev A `SharedReservePool` with one added function and one added storage variable, used to
///      prove an upgrade both preserves existing state and can extend the layout.
contract SharedReservePoolV2 is SharedReservePool {
    /// @dev Appended after the parent's `__gap`, which is what makes this safe.
    string public upgradeNote;

    function setUpgradeNote(string calldata note) external {
        upgradeNote = note;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A brand token whose implementation reports a version, to prove one beacon upgrade
///      reaches every brand at once.
contract PooledBrandTokenV2 is PooledBrandToken {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @title UpgradeAndPauseTest
/// @notice The two properties the upgradeable rewrite exists to provide, asserted directly:
///         every fund-holding contract can be fixed after deployment, and the whole protocol
///         can be halted in one transaction without ever trapping a holder's money.
contract UpgradeAndPauseTest is Test, StackFixture {
    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;

    address alice = address(0xA11CE);
    address brand;
    address treasury;

    function setUp() public {
        _deployUpgradeBase();

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), stackOwner);

        (brand, treasury) = reserve.registerBrand("Alpha USD", "aUSD", address(this));

        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(reserve), type(uint256).max);
        reserve.mint(brand, 500e6, alice);
        vm.stopPrank();
    }

    // ─── Upgrading ───────────────────────────────────────────────────────

    /// @notice The reserve can be upgraded, keeps every balance it held, and can gain new state.
    function test_reserveUpgradePreservesStateAndCanAddStorage() public {
        uint256 outstandingBefore = reserve.outstandingOf(brand);
        uint256 assetsBefore = reserve.totalAssets();
        assertEq(outstandingBefore, 500e6, "precondition: the brand has supply");

        address v2 = address(new SharedReservePoolV2());
        vm.prank(stackOwner);
        SharedReservePool(address(reserve)).upgradeToAndCall(v2, "");

        assertEq(SharedReservePoolV2(address(reserve)).version(), 2, "new code is live");
        assertEq(reserve.outstandingOf(brand), outstandingBefore, "supply survived");
        assertEq(reserve.totalAssets(), assetsBefore, "reserve survived");
        assertEq(IERC20(brand).balanceOf(alice), 500e6, "the holder's balance survived");
        assertEq(address(reserve.asset()), address(usdg), "wiring survived");

        // The appended variable is usable and did not land on anything already there.
        SharedReservePoolV2(address(reserve)).setUpgradeNote("v2");
        assertEq(SharedReservePoolV2(address(reserve)).upgradeNote(), "v2");
        assertEq(reserve.outstandingOf(brand), outstandingBefore, "and still survived");
    }

    /// @notice Only the timelock may upgrade. This is the whole of the access control on the
    ///         most consequential function in the system.
    function test_nobodyButTheOwnerCanUpgradeTheReserve() public {
        address v2 = address(new SharedReservePoolV2());

        vm.prank(alice);
        vm.expectRevert();
        SharedReservePool(address(reserve)).upgradeToAndCall(v2, "");

        // Not even the guardian, whose only power is halting.
        vm.prank(stackGuardian);
        vm.expectRevert();
        SharedReservePool(address(reserve)).upgradeToAndCall(v2, "");
    }

    /// @notice **The reason the per-market contracts sit behind beacons.** One upgrade reaches
    ///         every brand that already exists, not only the ones registered afterwards.
    function test_oneBeaconUpgradeMovesEveryBrandAtOnce() public {
        (address second,) = reserve.registerBrand("Beta USD", "bUSD", address(this));
        (address third,) = reserve.registerBrand("Gamma USD", "cUSD", address(this));

        address v2 = address(new PooledBrandTokenV2());
        vm.prank(stackOwner);
        UpgradeableBeacon(address(beacons.brandToken)).upgradeTo(v2);

        assertEq(PooledBrandTokenV2(brand).version(), 2, "the first brand moved");
        assertEq(PooledBrandTokenV2(second).version(), 2, "so did the second");
        assertEq(PooledBrandTokenV2(third).version(), 2, "and the third");

        // Each kept its own identity and supply: a shared implementation must not mean shared
        // state, which is exactly what an `immutable` in the implementation would have caused.
        assertEq(PooledBrandToken(brand).symbol(), "aUSD");
        assertEq(PooledBrandToken(second).symbol(), "bUSD");
        assertEq(IERC20(brand).balanceOf(alice), 500e6);
        assertEq(IERC20(second).totalSupply(), 0);
    }

    /// @notice A brand registered after an upgrade gets the new implementation too.
    function test_brandsRegisteredAfterAnUpgradeUseTheNewImplementation() public {
        address v2 = address(new PooledBrandTokenV2());
        vm.prank(stackOwner);
        UpgradeableBeacon(address(beacons.brandToken)).upgradeTo(v2);

        (address later,) = reserve.registerBrand("Delta USD", "dUSD", address(this));
        assertEq(PooledBrandTokenV2(later).version(), 2);
    }

    /// @notice Every beacon is owned by the timelock from the moment it exists, so the deploying
    ///         key never holds upgrade authority over a live market, even briefly.
    function test_everyBeaconIsOwnedByTheTimelock() public view {
        assertEq(UpgradeableBeacon(address(beacons.brandToken)).owner(), stackOwner);
        assertEq(UpgradeableBeacon(address(beacons.treasury)).owner(), stackOwner);
        assertEq(UpgradeableBeacon(address(beacons.vault)).owner(), stackOwner);
        assertEq(UpgradeableBeacon(address(beacons.distributor)).owner(), stackOwner);
    }

    /// @notice **Ownership can always be handed to another address, and can never be dropped.**
    ///         Both halves matter to an operator. The transfer is two-step on every contract,
    ///         so a typo cannot hand the protocol to an address nobody controls — nomination
    ///         alone changes no authority. And renouncing is refused everywhere, because on a
    ///         UUPS proxy `_authorizeUpgrade` is `onlyOwner`: dropping the owner would freeze
    ///         that implementation permanently, over live funds, with no way to fix a defect.
    function test_ownershipTransfersInTwoStepsAndCannotBeDropped() public {
        address successor = address(0xC0FFEE);

        vm.prank(stackOwner);
        reserve.transferOwnership(successor);
        // Nominated, not handed over: the incumbent still owns it.
        assertEq(reserve.owner(), stackOwner, "nomination alone must not move ownership");
        assertEq(reserve.pendingOwner(), successor, "successor is nominated");

        vm.prank(successor);
        reserve.acceptOwnership();
        assertEq(reserve.owner(), successor, "successor now owns the reserve");
        assertEq(reserve.pendingOwner(), address(0), "nomination cleared");

        // And the new owner really does hold upgrade authority, which is the point of moving it.
        address v2 = address(new SharedReservePoolV2());
        vm.prank(successor);
        reserve.upgradeToAndCall(v2, "");
        assertEq(SharedReservePoolV2(address(reserve)).version(), 2);

        vm.prank(successor);
        vm.expectRevert(SharedReservePool.OwnershipCannotBeRenounced.selector);
        reserve.renounceOwnership();
        assertEq(reserve.owner(), successor, "renounce left ownership untouched");
    }

    /// @notice The same refusal on the guard, where the consequence is worst: it owns every
    ///         `unpause`, and `GuardedUpgradeable` has no setter for the guard address its
    ///         dependents read at initialisation. An ownerless guard means the guardian key
    ///         alone decides whether the protocol ever runs again.
    function test_guardOwnershipCannotBeRenounced() public {
        vm.prank(stackOwner);
        vm.expectRevert(ProtocolGuard.OwnershipCannotBeRenounced.selector);
        protocolGuard.renounceOwnership();

        assertEq(protocolGuard.owner(), stackOwner);
    }

    /// @notice An implementation left initialisable is a live hazard: whoever calls `initialize`
    ///         on it owns a contract that a UUPS proxy delegates into. Every one of ours is
    ///         locked at construction.
    function test_implementationsCannotBeInitialised() public {
        SharedReservePool impl = new SharedReservePool();
        vm.expectRevert();
        impl.initialize(
            address(usdg),
            address(yieldSource),
            address(this),
            address(beacons.brandToken),
            address(beacons.treasury),
            address(protocolGuard)
        );

        // The two per-market contracts, read off the beacons the stack actually ships rather
        // than off a fresh construction: a beacon pointed at an initialisable implementation
        // would hand every market's proxy to whoever called `initialize` on it first.
        BrandFeeVault vault =
            BrandFeeVault(UpgradeableBeacon(address(beacons.vault)).implementation());
        vm.expectRevert();
        vault.initialize(
            reserve,
            treasury,
            brand,
            address(usdg),
            address(this),
            0,
            address(this),
            address(protocolGuard)
        );

        // The pool key is left zeroed — a locked initialiser reverts before reading it.
        PoolKey memory key;
        LpRewardDistributor distributor =
            LpRewardDistributor(UpgradeableBeacon(address(beacons.distributor)).implementation());
        vm.expectRevert();
        distributor.initialize(
            IPositionManagerV4(address(this)),
            reserve,
            key,
            brand,
            address(this),
            7 days,
            address(protocolGuard)
        );
    }

    // ─── Pausing ─────────────────────────────────────────────────────────

    /// @notice The guardian halts the protocol in one transaction, with no delay.
    function test_guardianHaltsMintingImmediately() public {
        assertFalse(reserve.paused());

        _pauseProtocol();
        assertTrue(reserve.paused(), "the reserve reads the shared registry");

        vm.startPrank(alice);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        reserve.mint(brand, 1e6, alice);
        vm.stopPrank();
    }

    /// @notice **The property that makes pausing acceptable at all.** A holder can always leave
    ///         at par, including — especially — while everything else is halted.
    function test_redemptionSurvivesAPause() public {
        _pauseProtocol();

        uint256 balanceBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 out = reserve.redeem(brand, 500e6, alice);

        assertEq(out, 500e6, "paid in full");
        assertEq(usdg.balanceOf(alice) - balanceBefore, 500e6, "and the USDG arrived");
        assertEq(IERC20(brand).balanceOf(alice), 0, "the whole position exited");
    }

    /// @notice Transfers of a brand token are never pausable either, for the same reason: a
    ///         holder has to be able to move the token to wherever they redeem or sell it.
    function test_brandTransfersSurviveAPause() public {
        _pauseProtocol();

        vm.prank(alice);
        IERC20(brand).transfer(address(0xB0B), 100e6);
        assertEq(IERC20(brand).balanceOf(address(0xB0B)), 100e6);
    }

    /// @notice The guardian can stop the protocol and cannot start it again. Resuming belongs to
    ///         the owner, so a stolen guardian key costs uptime and nothing else.
    function test_theGuardianCannotUnpause() public {
        _pauseProtocol();

        vm.prank(stackGuardian);
        vm.expectRevert();
        protocolGuard.unpause();

        assertTrue(reserve.paused(), "still halted");

        _unpauseProtocol();
        assertFalse(reserve.paused(), "the owner resumed it");

        vm.prank(alice);
        reserve.mint(brand, 1e6, alice);
    }

    /// @notice A stranger can neither halt nor resume.
    function test_onlyTheGuardianOrOwnerMayHalt() public {
        vm.prank(alice);
        vm.expectRevert(ProtocolGuard.OnlyGuardianOrOwner.selector);
        protocolGuard.pause();

        vm.prank(stackOwner);
        protocolGuard.pause();
        assertTrue(reserve.paused(), "the owner may halt as well as the guardian");
    }

    /// @notice One contract can be halted without taking the protocol down with it.
    function test_aSingleTargetCanBeHaltedAlone() public {
        vm.prank(stackGuardian);
        protocolGuard.pauseTarget(address(reserve));

        assertTrue(reserve.paused());
        assertFalse(protocolGuard.paused(), "the global switch was not thrown");

        // Redemption is still open, because it never consults the registry at all.
        vm.prank(alice);
        assertEq(reserve.redeem(brand, 100e6, alice), 100e6);
    }

    /// @notice The guardian is replaceable by the owner, and only by the owner.
    function test_theOwnerCanReplaceTheGuardian() public {
        address newGuardian = address(0x9E00);

        vm.prank(alice);
        vm.expectRevert();
        protocolGuard.setGuardian(newGuardian);

        vm.prank(stackOwner);
        protocolGuard.setGuardian(newGuardian);
        assertEq(protocolGuard.guardian(), newGuardian);

        vm.prank(newGuardian);
        protocolGuard.pause();
        assertTrue(reserve.paused());
    }
}
