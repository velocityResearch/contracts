// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {ReentrancyGuardSlot} from "../../src/upgrade/ReentrancyGuardSlot.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev An adapter that books more than it can hand back, which is exactly the shape
///      `SUSDaiYieldSource` has whenever any of the position is on the far side of the bridge:
///      `balanceOf` counts the remote leg, `withdraw` can only pay what is on this chain, and
///      it returns the short amount rather than reverting.
contract UnderDeliveringYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    /// @notice Book value this adapter reports but cannot deliver locally.
    uint256 public stranded;

    function setStranded(uint256 amount) external {
        stranded = amount;
    }

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 local = IERC20(asset).balanceOf(address(this));
        uint256 paid = amount < local ? amount : local;
        IERC20(asset).safeTransfer(to, paid);
        return paid;
    }

    function balanceOf(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + stranded;
    }

    function totalAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + stranded;
    }

    /// @dev The local leg only — the honest answer `SUSDaiYieldSource` gives too.
    function withdrawable(address asset, address) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}

/// @dev An asset with a transfer hook, standing in for any ERC-777-style or callback-bearing
///      token the reserve might one day be pointed at. Two modes: observe the pool's books
///      mid-transfer, or call straight back into it.
contract HookedAsset is MockUSDC {
    SharedReservePool public pool;
    bool public reenter;

    /// @notice `totalPooledSupply` as seen from inside a transfer INTO the pool.
    uint256 public supplyDuringInboundTransfer;

    bool private inHook;

    function watch(SharedReservePool _pool, bool _reenter) external {
        pool = _pool;
        reenter = _reenter;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(pool) == address(0) || to != address(pool) || inHook) return;

        inHook = true;
        if (reenter) {
            pool.deployIdle();
        } else {
            supplyDuringInboundTransfer = pool.totalPooledSupply();
        }
        inHook = false;
    }
}

/// @title SharedReservePoolMigrationTest
/// @notice Regression cover for the two reserve-accounting hazards the audit found in the pool:
///         a yield-source migration that silently strands value the outgoing adapter cannot
///         return, and the missing reentrancy guard plus the inverted ordering in `mint`.
contract SharedReservePoolMigrationTest is Test, StackFixture {
    SharedReservePool pool;
    MockUSDC usdc;
    UnderDeliveringYieldSource stranding;

    address owner = address(0x0AD01);
    address adminA = address(0xA1);
    address alice = address(0xA11CE);

    address tokenA;
    address treasuryA;

    function setUp() public {
        _deployUpgradeBase();
        usdc = new MockUSDC();
        stranding = new UnderDeliveringYieldSource();
        pool = _deployReservePool(address(usdc), address(stranding), owner);
        (tokenA, treasuryA) = pool.registerBrand("Alpha USD", "aUSD", adminA);
        usdc.mint(alice, 1_000_000e6);
    }

    /// @dev 1000 of local backing plus `remote` of book value the adapter cannot return.
    function _seed(uint256 remote) internal {
        stranding.setStranded(remote);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.mint(tokenA, 1000e6, alice);
        vm.stopPrank();
    }

    // ─── Migration (RSV-006 / SCRIPT-001) ────────────────────────────────

    function test_setYieldSource_refusesAMigrationThatWouldStrandTheRemotePosition() public {
        _seed(400e6);
        assertEq(pool.totalAssets(), 1400e6, "book includes the remote leg");

        MockYieldSource replacement = new MockYieldSource();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.MigrationWouldStrand.selector, 1400e6, 1000e6)
        );
        pool.setYieldSource(address(replacement));

        assertEq(address(pool.yieldSource()), address(stranding), "migration rolled back");
        assertEq(pool.totalAssets(), 1400e6, "nothing left the books");
    }

    function test_setYieldSource_acceptStrandingBooksTheShortfallAsALoss() public {
        _seed(400e6);
        MockYieldSource replacement = new MockYieldSource();

        vm.expectEmit(true, false, false, true, address(pool));
        emit SharedReservePool.MigrationStranded(address(stranding), 400e6);
        vm.prank(owner);
        pool.setYieldSource(address(replacement), true);

        assertEq(address(pool.yieldSource()), address(replacement));
        assertEq(pool.totalAssets(), 1000e6, "only the local balance came back");
        assertEq(pool.lossCarryforward(), 400e6, "the shortfall was booked, not dropped");

        // What booking it actually buys: the next 400 of real yield repays the write-off
        // instead of reaching the brand's ledger. Without the fix `lossCarryforward` would
        // still be 0 here and the brand would be credited yield against backing that left.
        pool.deployIdle();
        _simulateYield(replacement, 400e6);
        assertEq(pool.pendingYield(tokenA), 0, "yield diverted to repay the stranded amount");
        _simulateYield(replacement, 100e6);
        assertEq(pool.pendingYield(tokenA), 100e6, "only the excess reaches the brand");
    }

    function test_setYieldSource_toleratesShareRoundingDust() public {
        _seed(pool.MAX_MIGRATION_DUST());
        MockYieldSource replacement = new MockYieldSource();

        vm.prank(owner);
        pool.setYieldSource(address(replacement));

        assertEq(address(pool.yieldSource()), address(replacement), "dust does not block");
        assertEq(pool.lossCarryforward(), 0, "dust is absorbed by the baseline, not booked");
    }

    function _simulateYield(MockYieldSource source, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(source), amount);
        source.simulateYield(address(usdc), amount);
    }

    // ─── Reentrancy and check-effects-interactions (RSV-011) ─────────────

    /// @dev Re-entry has to be tested against a hooked asset, because the deployed USDG has no
    ///      hooks — which is why the audit rates this defence in depth rather than a live hole.
    function _hookedPool(bool reenter) internal returns (SharedReservePool p, HookedAsset asset) {
        asset = new HookedAsset();
        MockYieldSource source = new MockYieldSource();
        p = _deployReservePool(address(asset), address(source), owner);
        asset.watch(p, reenter);
        asset.mint(alice, 1000e6);
    }

    function test_mint_rejectsReentryThroughTheAssetTransfer() public {
        (SharedReservePool p, HookedAsset asset) = _hookedPool(true);
        (address token,) = p.registerBrand("Hooked USD", "hUSD", adminA);

        vm.startPrank(alice);
        asset.approve(address(p), 500e6);
        vm.expectRevert(ReentrancyGuardSlot.ReentrantCall.selector);
        p.mint(token, 500e6, alice);
        vm.stopPrank();
    }

    function test_mint_recordsTheLiabilityBeforeTheAssetArrives() public {
        (SharedReservePool p, HookedAsset asset) = _hookedPool(false);
        (address token,) = p.registerBrand("Hooked USD", "hUSD", adminA);

        vm.startPrank(alice);
        asset.approve(address(p), 500e6);
        p.mint(token, 500e6, alice);
        vm.stopPrank();

        // The window RSV-011 describes: with the transfer first, an observer inside it sees
        // assets already up and supply still down, which is what `claimYield` reads as surplus.
        assertEq(asset.supplyDuringInboundTransfer(), 500e6, "supply must already include the mint");
    }

    // ─── Ownership (UUPS-003) ────────────────────────────────────────────

    /// @notice Renouncing would freeze the implementation of the contract holding the whole
    ///         reserve, in one non-two-step call from the owner EOA. So it must not be
    ///         reachable at all, and the owner's real levers must still work afterwards.
    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(SharedReservePool.OwnershipCannotBeRenounced.selector);
        pool.renounceOwnership();

        assertEq(pool.owner(), owner, "owner unchanged");
        // Still a working lever, just an announced one: raising the fee schedules it and the
        // hour makes it live. Both halves are asserted, because "the owner can still act" is
        // the claim and a schedule nobody can commit would not be acting.
        vm.prank(owner);
        pool.setRedemptionFee(10);
        assertEq(pool.pendingRedemptionFeeBps(), 10, "the owner's levers still work");
        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 10, "and still reach the live fee");
    }
}
