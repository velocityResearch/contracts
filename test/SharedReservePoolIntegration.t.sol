// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";
import {StackFixture} from "./helpers/StackFixture.sol";

/// @title SharedReservePoolIntegrationTest
/// @notice A single, extended lifecycle across many brands and actors — registrations
///         staggered over time, uneven mints, cross-brand swaps, partial redemptions, and
///         multiple yield rounds — checking system-wide invariants after every step rather
///         than one behavior in isolation. Complements `SharedReservePool.t.sol`, which
///         covers each function's direct behavior.
contract SharedReservePoolIntegrationTest is Test, StackFixture {
    SharedReservePool pool;
    MockUSDC usdc;
    MockYieldSource yieldSource;

    address owner = address(0x0AD01);
    address adminA = address(0xA1);
    address adminB = address(0xB1);
    address adminC = address(0xC1);
    address adminD = address(0xD1);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    address tokenA;
    address treasuryA;
    address tokenB;
    address treasuryB;
    address tokenC;
    address treasuryC;

    uint256 constant STARTING_BALANCE = 10_000_000e6;

    function setUp() public {
        _deployUpgradeBase();
        usdc = new MockUSDC();
        yieldSource = new MockYieldSource();
        pool = _deployReservePool(address(usdc), address(yieldSource), owner);

        (tokenA, treasuryA) = pool.registerBrand("Alpha USD", "aUSD", adminA);
        (tokenB, treasuryB) = pool.registerBrand("Beta USD", "bUSD", adminB);
        (tokenC, treasuryC) = pool.registerBrand("Gamma USD", "gUSD", adminC);

        usdc.mint(alice, STARTING_BALANCE);
        usdc.mint(bob, STARTING_BALANCE);
        usdc.mint(carol, STARTING_BALANCE);
    }

    function _mint(address caller, address token, uint256 amount) internal {
        vm.startPrank(caller);
        usdc.approve(address(pool), amount);
        pool.mint(token, amount, caller);
        vm.stopPrank();
    }

    function _simulateYield(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdc), amount);
    }

    /// @dev Solvency: every pooled token must always be redeemable 1:1, and every brand's
    ///      unclaimed yield entitlement must be real surplus, not a claim on other brands'
    ///      principal. Checked after every phase of the lifecycle below.
    function _assertSolvent() internal view {
        assertGe(
            pool.totalAssets(),
            pool.totalPooledSupply(),
            "every pooled token must stay 1:1 redeemable"
        );

        uint256 totalAccrued =
            pool.pendingYield(tokenA) + pool.pendingYield(tokenB) + pool.pendingYield(tokenC);
        uint256 surplus = pool.totalAssets() - pool.totalPooledSupply();
        assertLe(
            totalAccrued,
            surplus + 3,
            "accrued yield across brands must not exceed real surplus (dust-tolerant)"
        );
    }

    function test_fullLifecycle_manyBrandsManyActorsManyYieldRounds() public {
        // ─── Phase 1: uneven mints across three brands ────────────────────
        _mint(alice, tokenA, 1_000e6);
        _mint(bob, tokenB, 2_000e6);
        _mint(carol, tokenC, 500e6);
        _assertSolvent();

        assertEq(pool.totalPooledSupply(), 3_500e6);
        assertEq(pool.totalAssets(), 3_500e6);

        // ─── Phase 2: deploy to yield source, first yield round ───────────
        pool.deployIdle();
        _simulateYield(350e6); // exactly 10% of 3_500e6 pooled supply
        _assertSolvent();

        // Yield splits proportional to outstanding supply: A=1000/3500, B=2000/3500, C=500/3500.
        assertApproxEqAbs(pool.pendingYield(tokenA), 100e6, 1);
        assertApproxEqAbs(pool.pendingYield(tokenB), 200e6, 1);
        assertApproxEqAbs(pool.pendingYield(tokenC), 50e6, 1);

        // ─── Phase 3: a late brand joins after yield has already accrued ──
        // It must start clean — no retroactive share of yield it wasn't part of.
        (address tokenD, address treasuryD) = pool.registerBrand("Delta USD", "dUSD", adminD);
        assertEq(
            pool.pendingYield(tokenD),
            0,
            "a brand joining late must not retroactively earn past yield"
        );

        address dave = address(0xDA5E);
        usdc.mint(dave, STARTING_BALANCE);
        _mint(dave, tokenD, 4_000e6);
        _assertSolvent();

        // ─── Phase 4: cross-brand swaps ────────────────────────────────────
        // Alice moves her entire A position into C, sent to a fresh recipient.
        address aliceAlt = address(0xA11CE2);
        vm.prank(alice);
        pool.swap(tokenA, tokenC, 1_000e6, aliceAlt);

        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 0);
        assertEq(PooledBrandToken(tokenC).balanceOf(aliceAlt), 1_000e6);
        // The swap itself must not have moved or created yield.
        assertApproxEqAbs(
            pool.pendingYield(tokenA), 100e6, 1, "A's earned yield survives its supply leaving"
        );
        assertApproxEqAbs(
            pool.pendingYield(tokenC), 50e6, 1, "swap must not itself grant C new yield"
        );
        _assertSolvent();

        // ─── Phase 5: brand A claims its yield, then goes to zero supply ──
        vm.prank(adminA);
        uint256 claimedA = PoolBrandTreasury(treasuryA).claim(adminA);
        assertApproxEqAbs(claimedA, 100e6, 1);
        assertEq(usdc.balanceOf(adminA), claimedA);
        assertEq(PoolBrandTreasury(treasuryA).pendingYield(), 0);
        _assertSolvent();

        // Admin routes the claimed funds through the treasury and on to a payout address —
        // exercising `distribute`, the admin-gated path `claim` deliberately doesn't take.
        address brandAPayout = address(0x9A1E);
        vm.startPrank(adminA);
        usdc.transfer(address(treasuryA), claimedA);
        PoolBrandTreasury(treasuryA).distribute(address(usdc), brandAPayout, claimedA);
        vm.stopPrank();
        assertEq(usdc.balanceOf(brandAPayout), claimedA);

        // ─── Phase 6: second yield round — brand A has zero supply now ────
        _simulateYield(700e6);
        _assertSolvent();

        // Brand A must earn nothing further: it holds no outstanding supply.
        assertApproxEqAbs(
            pool.pendingYield(tokenA), 0, 1, "brand with zero outstanding earns no new yield"
        );

        // Remaining pooled supply after A emptied out: B=2000, C=1500 (500+1000 swapped in), D=4000 => 7500.
        uint256 remainingSupply = 7_500e6;
        assertEq(pool.totalPooledSupply(), remainingSupply);
        uint256 secondRoundYield = 700e6;
        assertApproxEqAbs(
            pool.pendingYield(tokenB), 200e6 + secondRoundYield * 2_000e6 / remainingSupply, 1e3
        );
        assertApproxEqAbs(
            pool.pendingYield(tokenC), 50e6 + secondRoundYield * 1_500e6 / remainingSupply, 1e3
        );
        assertApproxEqAbs(
            pool.pendingYield(tokenD), secondRoundYield * 4_000e6 / remainingSupply, 1e3
        );

        // ─── Phase 7: partial redemption stays exactly 1:1 regardless of yield history ──
        vm.prank(bob);
        uint256 redeemed = pool.redeem(tokenB, 500e6, bob);
        assertEq(redeemed, 500e6);
        assertEq(usdc.balanceOf(bob), STARTING_BALANCE - 2_000e6 + 500e6);
        _assertSolvent();

        // ─── Phase 8: every remaining brand can claim exactly its own ledger ──
        vm.prank(adminB);
        uint256 claimedB = PoolBrandTreasury(treasuryB).claim(adminB);
        vm.prank(adminC);
        uint256 claimedC = PoolBrandTreasury(treasuryC).claim(adminC);
        vm.prank(adminD);
        uint256 claimedD = PoolBrandTreasury(treasuryD).claim(adminD);

        assertGt(claimedB, 0);
        assertGt(claimedC, 0);
        assertGt(claimedD, 0);
        _assertSolvent();

        // Once every accrued claim is paid out, remaining assets should be back down to
        // (approximately) exactly the outstanding pooled supply — no leftover phantom surplus,
        // no shortfall.
        assertApproxEqAbs(pool.totalAssets(), pool.totalPooledSupply(), 1e3);
    }
}
