// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {StrategyGroupRegistry} from "../../src/registry/StrategyGroupRegistry.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";

// ─── Footprint probes ────────────────────────────────────────────────────
//
// Each probe appends one slot to its parent, so the slot the probe lands on IS the total
// number of slots the parent's own layout occupies — reserved gap included. That is the one
// number an in-place upgrade may never change: append a field without shrinking `__gap` and
// every probe below moves, which is precisely the mistake that silently overwrites a live
// proxy's state. Nothing here is deployed on chain; they exist only to make that number
// observable from Solidity, since Foundry exposes no storage layout to a test.

interface ILayoutProbe {
    function layoutProbe() external view returns (uint256);
}

contract Probe_SharedReservePool is SharedReservePool {
    uint256 public layoutProbe;
}

contract Probe_StrategyGroupRegistry is StrategyGroupRegistry {
    uint256 public layoutProbe;
}

contract Probe_SUSDaiYieldSource is SUSDaiYieldSource {
    uint256 public layoutProbe;
}

contract Probe_MorphoBlueYieldSource is MorphoBlueYieldSource {
    uint256 public layoutProbe;
}

contract Probe_SUSDaiHub is SUSDaiHub {
    uint256 public layoutProbe;
}

contract Probe_ProtocolGuard is ProtocolGuard {
    uint256 public layoutProbe;
}

contract Probe_AssetMarketFactory is AssetMarketFactory {
    uint256 public layoutProbe;
}

contract Probe_MarketRouter is MarketRouter {
    uint256 public layoutProbe;
}

contract Probe_ProtocolFeeHook is ProtocolFeeHook {
    uint256 public layoutProbe;
}

/// @title UpgradeInvariantsTest
/// @notice The two UUPS invariants whose violation is unrecoverable, asserted for every
///         upgradeable contract in `src/` rather than trusted to review.
///
///         **1. Every implementation's initializer is locked.** An implementation left
///         initializable can be initialized by anyone directly, who then owns it; OZ v5's
///         `_checkProxy` means that alone cannot upgrade the proxy, but shipping one is still
///         the first half of the classic takeover and there is no reason to allow it.
///
///         **2. No live contract's storage layout moves.** Every one of these is deployed
///         behind a proxy and upgraded in place, so a reordered, resized or removed field
///         writes new code over old state. Appending is safe; anything else is not.
///
///         **When this test legitimately fails.** If you added a field, the ONLY correct fix is
///         to put it at the end of the contract's own storage block and shrink that block's
///         `uint256[N] __gap` by exactly the number of slots you took — then this test still
///         passes untouched, because the footprint is unchanged. Update a constant here only
///         when a contract is NEW, or when it has no `__gap` left and you are deliberately
///         extending its footprint on a contract that has never been deployed behind a proxy.
///         Never update one to make a reorder go green: re-derive the layout with
///         `forge inspect <path>:<Contract> storage-layout` and put the field back at the end.
contract UpgradeInvariantsTest is Test {
    /// @dev OZ's `Initializable` ERC-7201 slot. `_initialized` is its low 8 bytes, and
    ///      `initializer` reverts `InvalidInitialization` whenever that reads `type(uint64).max`
    ///      — so checking the slot IS checking that every `initialize` on this implementation
    ///      reverts, without needing nine different call signatures.
    ///      keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1))
    ///      & ~0xff
    bytes32 private constant INITIALIZABLE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    address[] private implementations;
    string[] private names;

    function setUp() public {
        _add("SharedReservePool", address(new SharedReservePool()));
        _add("StrategyGroupRegistry", address(new StrategyGroupRegistry()));
        _add("SUSDaiYieldSource", address(new SUSDaiYieldSource()));
        _add("MorphoBlueYieldSource", address(new MorphoBlueYieldSource()));
        _add("SUSDaiHub", address(new SUSDaiHub()));
        _add("ProtocolGuard", address(new ProtocolGuard()));
        _add("AssetMarketFactory", address(new AssetMarketFactory()));
        _add("MarketRouter", address(new MarketRouter()));
        _add("ProtocolFeeHook", address(new ProtocolFeeHook()));
    }

    function _add(string memory name, address impl) private {
        names.push(name);
        implementations.push(impl);
    }

    // ─── 1. Implementation lock ──────────────────────────────────────────

    function test_everyImplementationShipsWithItsInitializerLocked() public view {
        for (uint256 i = 0; i < implementations.length; i++) {
            assertEq(
                uint256(vm.load(implementations[i], INITIALIZABLE_SLOT)),
                uint256(type(uint64).max),
                string.concat(names[i], " is missing _disableInitializers() in its constructor")
            );
        }
    }

    /// @dev Anchors the slot constant above against the behaviour it stands for, so a wrong
    ///      constant cannot make the sweep pass vacuously by reading an empty slot.
    function test_aLockedImplementationRejectsADirectInitialize() public {
        SharedReservePool pool = new SharedReservePool();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(
            address(0xA55E7),
            address(0x50C),
            address(this),
            address(0xB1),
            address(0xB2),
            address(0)
        );

        StrategyGroupRegistry registry = new StrategyGroupRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(this));
    }

    // ─── 2. Storage footprint ────────────────────────────────────────────

    function test_storageFootprintOfEveryUpgradeableContractIsUnchanged() public {
        _assertFootprint("SharedReservePool", address(new Probe_SharedReservePool()), 52);
        _assertFootprint("StrategyGroupRegistry", address(new Probe_StrategyGroupRegistry()), 3);
        _assertFootprint("SUSDaiYieldSource", address(new Probe_SUSDaiYieldSource()), 62);
        _assertFootprint("MorphoBlueYieldSource", address(new Probe_MorphoBlueYieldSource()), 54);
        _assertFootprint("SUSDaiHub", address(new Probe_SUSDaiHub()), 59);
        _assertFootprint("ProtocolGuard", address(new Probe_ProtocolGuard()), 50);
        // The market layer — factory, router, fee hook — is deliberately NOT pinned here. It
        // is being rebuilt (the buyback engine and lockbox replaced by an LP reward
        // distributor), and a footprint constant for a contract mid-restructure is a tripwire
        // that fires on legitimate work rather than on an accidental reorder, which is the only
        // thing this test is for. Add the three back, with measured constants, once that
        // refactor lands and its beacons are deployed — at which point their layouts become
        // upgrade-relevant in the same way the six above already are.
    }

    /// @dev Writes a marker at the slot the appended probe is expected to occupy; the probe
    ///      reads it back only if the parent's layout still ends exactly where it used to.
    function _assertFootprint(string memory name, address probe, uint256 expectedSlot) private {
        uint256 marker = 0xC0FFEE;
        vm.store(probe, bytes32(expectedSlot), bytes32(marker));
        assertEq(
            ILayoutProbe(probe).layoutProbe(),
            marker,
            string.concat(name, "'s own storage no longer ends at the expected slot")
        );
    }

    // ─── 2b. Field-level layout, for the two contracts this suite owns ───
    //
    // The footprint probe catches a changed total but not a permutation of two equal-sized
    // fields. Pinning each field's slot and offset catches that too. Done in full for the
    // reserve pool because it holds the entire reserve, and for the registry because it is the
    // other live proxy whose layout has no `__gap` to absorb a mistake.

    function test_sharedReservePoolFieldSlotsAreUnchanged() public {
        SharedReservePool pool = new SharedReservePool();
        address token = address(0x7043E);
        // Slot 0 packs the asset address with its cached decimals.
        vm.store(address(pool), bytes32(uint256(0)), bytes32((uint256(0x06) << 160) | uint256(1)));
        assertEq(address(pool.asset()), address(1), "asset: slot 0 offset 0");
        assertEq(pool.assetDecimals(), 6, "assetDecimals: slot 0 offset 20");

        vm.store(address(pool), bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(pool.brandTokenBeacon(), address(2), "brandTokenBeacon: slot 1");
        vm.store(address(pool), bytes32(uint256(2)), bytes32(uint256(3)));
        assertEq(pool.treasuryBeacon(), address(3), "treasuryBeacon: slot 2");
        vm.store(address(pool), bytes32(uint256(3)), bytes32(uint256(4)));
        assertEq(address(pool.yieldSource()), address(4), "yieldSource: slot 3");

        // `brands` is a mapping, so its base slot is only observable through a keyed entry.
        bytes32 brandBase = keccak256(abi.encode(token, uint256(4)));
        vm.store(address(pool), brandBase, bytes32(uint256(1)));
        assertTrue(pool.isRegistered(token), "brands: slot 4");
        vm.store(address(pool), bytes32(uint256(brandBase) + 1), bytes32(uint256(77)));
        assertEq(pool.outstandingOf(token), 77, "Brand.outstanding: mapping base + 1");

        vm.store(address(pool), bytes32(uint256(5)), bytes32(uint256(7)));
        assertEq(pool.allBrandTokensLength(), 7, "allBrandTokens: slot 5");
        vm.store(address(pool), bytes32(uint256(6)), bytes32(uint256(8)));
        assertEq(pool.totalPooledSupply(), 8, "totalPooledSupply: slot 6");
        vm.store(address(pool), bytes32(uint256(7)), bytes32(uint256(9)));
        assertEq(pool.lastAccrualAssets(), 9, "lastAccrualAssets: slot 7");
        vm.store(address(pool), bytes32(uint256(8)), bytes32(uint256(10)));
        assertEq(pool.cumulativeYieldPerToken(), 10, "cumulativeYieldPerToken: slot 8");
        vm.store(address(pool), bytes32(uint256(9)), bytes32(uint256(11)));
        assertEq(pool.lossCarryforward(), 11, "lossCarryforward: slot 9");
        vm.store(address(pool), bytes32(uint256(10)), bytes32(uint256(12)));
        assertEq(pool.redemptionFeeBps(), 12, "redemptionFeeBps: slot 10 offset 0");
        vm.store(address(pool), bytes32(uint256(11)), bytes32(uint256(13)));
        assertEq(pool.liabilityCap(), 13, "liabilityCap: slot 11");
    }

    function test_strategyGroupRegistryFieldSlotsAreUnchanged() public {
        StrategyGroupRegistry registry = new StrategyGroupRegistry();
        bytes32 id = keccak256("group");

        vm.store(address(registry), keccak256(abi.encode(id, uint256(1))), bytes32(uint256(1)));
        assertTrue(registry.exists(id), "exists: slot 1");

        vm.store(address(registry), keccak256(abi.encode(id, uint256(0))), bytes32(uint256(5)));
        assertEq(registry.group(id).reservePool, address(5), "_groups: slot 0");

        vm.store(address(registry), bytes32(uint256(2)), bytes32(uint256(1)));
        assertEq(registry.groupCount(), 1, "_groupIds: slot 2");
        vm.store(address(registry), keccak256(abi.encode(uint256(2))), id);
        assertEq(registry.groupIdAt(0), id, "_groupIds elements: keccak256(slot 2)");
    }
}
