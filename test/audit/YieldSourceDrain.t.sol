// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title YieldSourceDrainForkTest
/// @notice PoC for two related, attacker-exploitable flaws, proven against a fork of live
///         Robinhood Chain (chain id 4663). Run with:
///           forge test --match-contract YieldSourceDrainFork -vvv \
///             --fork-url https://rpc.mainnet.chain.robinhood.com
contract YieldSourceDrainForkTest is Test, StackFixture {
    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;
    address attacker = address(0xBAD);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address consumer = address(0xDEAD11); // stands in for a reserve pool calling the adapter

    function setUp() public {
        _deployUpgradeBase();
        vm.skip(block.chainid != 4663);
        // Fund actors from Morpho Blue, which custodies USDG on this chain.
        vm.startPrank(MORPHO_BLUE);
        IERC20(USDG).transfer(alice, 5_000_000e6);
        IERC20(USDG).transfer(attacker, 10e6);
        vm.stopPrank();
    }

    /// FIX 1 (regression) — MorphoBlueYieldSource now attributes Morpho supply shares to the
    /// depositing caller, so an unrelated caller owns nothing and `withdraw(asset, amount,
    /// attacker)` moves zero. The deployed backing stays put.
    function test_outsiderCannotDrainDeployedBacking() public {
        MorphoBlueYieldSource adapter = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, stackOwner);

        // A consumer deploys its backing, exactly as SharedReservePool.mint() does inline.
        uint256 backing = 100_000e6;
        vm.prank(alice);
        IERC20(USDG).transfer(consumer, backing);
        vm.startPrank(consumer);
        IERC20(USDG).approve(address(adapter), backing);
        adapter.deposit(USDG, backing);
        // The depositing consumer sees its own balance.
        assertApproxEqAbs(adapter.balanceOf(USDG), backing, 2, "consumer holds the backing");
        vm.stopPrank();

        uint256 attackerBefore = IERC20(USDG).balanceOf(attacker);

        // Attacker tries to drain to themselves — now a no-op (they own zero shares).
        vm.prank(attacker);
        uint256 got = adapter.withdraw(USDG, type(uint256).max, attacker);
        assertEq(got, 0, "attacker withdrew nothing");
        assertEq(IERC20(USDG).balanceOf(attacker) - attackerBefore, 0, "attacker balance unchanged");

        // The consumer's backing is intact and fully withdrawable by the consumer.
        vm.prank(consumer);
        assertApproxEqAbs(adapter.balanceOf(USDG), backing, 2, "backing untouched by the attacker");
        vm.prank(consumer);
        uint256 out = adapter.withdraw(USDG, type(uint256).max, consumer);
        assertApproxEqAbs(out, backing, 3, "consumer can still withdraw its own backing");
    }

    /// FIX 2 (regression) — even when two reserve pools share ONE adapter instance, per-consumer
    /// share accounting keeps them isolated: each reads only its own deposits, and one pool's
    /// redemption cannot touch the other's principal.
    ///
    /// The deployment rule is one adapter instance per consumer, so this configuration should
    /// never ship. The point of the test is that it is survivable if it ever does: the isolation
    /// is a property of the adapter, not of the deployment discipline around it.
    function test_twoReservePoolsSharingOneAdapterStayIsolated() public {
        MorphoBlueYieldSource sharedAdapter =
            _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, stackOwner);

        SharedReservePool poolA = _deployReservePool(USDG, address(sharedAdapter), address(this));
        SharedReservePool poolB = _deployReservePool(USDG, address(sharedAdapter), address(this));
        (address brandA,) = poolA.registerBrand("Brand A USD", "aUSD", address(this));
        (address brandB,) = poolB.registerBrand("Brand B USD", "bUSD", address(this));

        // Give bob some USDG to be the second pool's depositor.
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(bob, 100_000e6);

        // Pool A: alice mints $100k. `mint` supplies to the adapter inline.
        vm.startPrank(alice);
        IERC20(USDG).approve(address(poolA), 100_000e6);
        poolA.mint(brandA, 100_000e6, alice);
        vm.stopPrank();

        // Pool B: an unrelated pool mints $60k against the same adapter instance.
        vm.startPrank(bob);
        IERC20(USDG).approve(address(poolB), 60_000e6);
        poolB.mint(brandB, 60_000e6, bob);
        vm.stopPrank();

        // Each pool reports ONLY its own deposits, despite sharing the adapter instance.
        assertApproxEqAbs(poolA.totalAssets(), 100_000e6, 5, "A sees only its own $100k");
        assertApproxEqAbs(poolB.totalAssets(), 60_000e6, 5, "B sees only its own $60k");

        // Alice redeems from pool A. She gets back ~her own deposit — no more.
        uint256 aliceBefore = IERC20(USDG).balanceOf(alice);
        vm.prank(alice);
        poolA.redeem(brandA, 100_000e6, alice);
        uint256 aliceOut = IERC20(USDG).balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(aliceOut, 100_000e6, 50, "alice withdrew only her own deposit");

        // Pool B is fully solvent: its principal was never touched.
        assertApproxEqAbs(poolB.totalAssets(), 60_000e6, 5, "pool B's backing intact");
        vm.prank(bob);
        uint256 bobOut = poolB.redeem(brandB, 60_000e6, bob);
        assertApproxEqAbs(bobOut, 60_000e6, 50, "bob can still redeem his deposit");
    }
}
