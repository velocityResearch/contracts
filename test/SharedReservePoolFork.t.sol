// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {MorphoBlueYieldSource, IMorphoBlue} from "../src/yield/MorphoBlueYieldSource.sol";
import {StackFixture} from "./helpers/StackFixture.sol";
import {MainnetAddresses} from "../script/MainnetAddresses.sol";

/// @dev Morpho Blue's real ABI includes a permissionless `accrueInterest`, used below to force
///      real interest into `market()`'s stored totals after warping — `IMorphoBlue` in
///      `MorphoBlueYieldSource` only declares the subset the adapter itself needs, which
///      doesn't include this, and `market()`/`position()` are plain storage reads that do NOT
///      reflect time passing until some call actually accrues it.
interface IMorphoBlueAccrue {
    function accrueInterest(IMorphoBlue.MarketParams memory marketParams) external;
}

/// @title SharedReservePoolForkTest
/// @notice `SharedReservePool` against live Morpho Blue on a forked Robinhood Chain mainnet:
///         real USDG, a real lending market accruing real interest, real withdrawals. The
///         mock-based suites (`SharedReservePool.t.sol`, `SharedReservePoolIntegration.t.sol`)
///         prove the yield-ledger math is correct in isolation; this proves the same pool
///         behaves correctly wired to the actual market it would deploy against — decimals
///         line up, `deployIdle`/`redeem`/`claimYield` round-trip through real Morpho Blue
///         share accounting, and proportional yield attribution holds against real,
///         non-deterministic interest accrual rather than a controlled `simulateYield` call.
///
///         Run with:
///         forge test --match-contract SharedReservePoolFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com
contract SharedReservePoolForkTest is Test, StackFixture {
    // ─── Robinhood Chain mainnet (verified on-chain, chain id 4663) ──────

    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @notice Top USDG market: USDG supplied, USDe collateral, ~$311M supply, 3.8% APY.
    bytes32 constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;

    // ─── Test state ──────────────────────────────────────────────────────

    SharedReservePool pool;
    MorphoBlueYieldSource yieldSource;

    address owner = address(0x0AD01);
    address adminA = address(0xA1);
    address adminB = address(0xB1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    address tokenA;
    address treasuryA;
    address tokenB;
    address treasuryB;

    uint256 constant DEPOSIT_A = 100_000e6; // 100k USDG
    uint256 constant DEPOSIT_B = 50_000e6; // 50k USDG — 2:1 ratio against A

    function setUp() public {
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // Same pattern as `AssetMarketV4ForkTest`; the early return is what keeps the rest of
        // this function from reverting against an empty chain, since `vm.skip` only marks the
        // result and does not abort the body.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        _deployUpgradeBase();
        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        pool = _deployReservePool(USDG, address(yieldSource), owner);

        (tokenA, treasuryA) = pool.registerBrand("Alpha USDG", "aUSDG", adminA);
        (tokenB, treasuryB) = pool.registerBrand("Beta USDG", "bUSDG", adminB);

        // Fund alice + bob from Morpho Blue, which custodies tens of millions of USDG.
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(alice, 1_000_000e6);
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(bob, 1_000_000e6);
    }

    function _mint(address caller, address token, uint256 amount) internal {
        vm.startPrank(caller);
        IERC20(USDG).approve(address(pool), amount);
        pool.mint(token, amount, caller);
        vm.stopPrank();
    }

    /// @dev Morpho Blue's `market()`/`position()` are plain storage reads — interest is only
    ///      compounded into them by an actual call, so warping time alone leaves `totalAssets()`
    ///      unchanged. Force it explicitly via the permissionless `accrueInterest`, the same
    ///      way any real integrator (or the next `supply`/`withdraw` against this market) would
    ///      trigger it.
    function _warpAndAccrueRealInterest(uint256 secondsElapsed) internal {
        vm.warp(block.timestamp + secondsElapsed);
        vm.roll(block.number + 1);

        (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) =
            yieldSource.marketParams();
        IMorphoBlueAccrue(MORPHO_BLUE)
            .accrueInterest(
                IMorphoBlue.MarketParams({
                    loanToken: loanToken,
                    collateralToken: collateralToken,
                    oracle: oracle,
                    irm: irm,
                    lltv: lltv
                })
            );
    }

    // ─── Basic flow against real USDG ─────────────────────────────────────

    function test_fork_pooledTokenMatchesUsdgDecimals() public view {
        assertEq(PooledBrandToken(tokenA).decimals(), 6);
    }

    /// @dev `mint` supplies to the yield source inline rather than leaving the USDG idle for a
    ///      later `deployIdle()`, so the pool's own USDG balance is zero straight after a mint
    ///      and `totalAssets` reads through Morpho. Morpho's share maths floors, which costs a
    ///      single base unit — bounded dust, not a per-mint leak, measured over 200 mints in
    ///      `MainnetLaunchForkTest.test_fork_reserveShortfallStaysBoundedAcrossManyMints`.
    function test_fork_mint_depositsRealUsdg1to1() public {
        _mint(alice, tokenA, DEPOSIT_A);

        assertEq(PooledBrandToken(tokenA).balanceOf(alice), DEPOSIT_A, "brand minted 1:1");
        assertApproxEqAbs(pool.totalAssets(), DEPOSIT_A, 1, "backed 1:1 up to Morpho dust");
        assertEq(IERC20(USDG).balanceOf(address(pool)), 0, "mint supplies inline, nothing idle");

        vm.prank(address(pool));
        assertApproxEqAbs(
            yieldSource.balanceOf(USDG), DEPOSIT_A, 1, "the deposit went straight to Morpho"
        );
    }

    function test_fork_deployIdle_suppliesToRealMorphoMarket() public {
        _mint(alice, tokenA, DEPOSIT_A);

        pool.deployIdle();

        assertEq(IERC20(USDG).balanceOf(address(pool)), 0);
        vm.prank(address(pool));
        uint256 deployed = yieldSource.balanceOf(USDG);
        assertGt(deployed, 0, "should have supplied to the real Morpho market");
        assertApproxEqAbs(pool.totalAssets(), DEPOSIT_A, 1);
    }

    /// @dev Two properties, and the second is why the first needs an explicit bound. A recall
    ///      from a live, non-empty Morpho market comes back short of book: the deposit-side
    ///      share<->asset floor division means the position never converts back into the round
    ///      number that went in. `redeem` without a bound demands par less the fee to the unit,
    ///      so it refuses that dust and leaves the holder's tokens where they were; accepting a
    ///      haircut is a choice the caller makes by naming a lower bound.
    function test_fork_redeem_recallsFromRealMorphoMarket() public {
        _mint(alice, tokenA, DEPOSIT_A);
        pool.deployIdle();

        // Read through the adapter, whose `balanceOf` mirrors Morpho's own `toAssetsDown`
        // exactly, so this is what the market will actually pay rather than what the pool
        // booked when it supplied.
        uint256 recoverable = pool.totalAssets();
        assertLt(recoverable, DEPOSIT_A, "a real round trip through Morpho floors below par");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.InsufficientPayout.selector, recoverable, DEPOSIT_A
            )
        );
        pool.redeem(tokenA, DEPOSIT_A, alice);
        assertEq(PooledBrandToken(tokenA).balanceOf(alice), DEPOSIT_A, "nothing burned");

        vm.prank(alice);
        uint256 out = pool.redeem(tokenA, DEPOSIT_A, alice, recoverable);

        assertEq(out, recoverable, "the whole position, the market's dust included");
        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 0, "burned in full");
        assertEq(IERC20(USDG).balanceOf(alice), 1_000_000e6 - (DEPOSIT_A - recoverable));
    }

    // ─── Real yield accrual ────────────────────────────────────────────────

    function test_fork_totalAssetsGrows_fromRealInterest() public {
        _mint(alice, tokenA, DEPOSIT_A);
        pool.deployIdle();

        uint256 before = pool.totalAssets();

        _warpAndAccrueRealInterest(90 days);

        assertGt(pool.totalAssets(), before, "real Morpho interest should accrue over 90 days");
    }

    /// @dev Whatever real interest Morpho actually pays, it must split across brands in
    ///      exactly the DEPOSIT_A : DEPOSIT_B ratio (2:1) — the same invariant
    ///      `SharedReservePoolIntegration.t.sol` checks against a controlled `simulateYield`
    ///      call, checked here against genuine, non-deterministic on-chain interest.
    function test_fork_yield_splitsProportionally_withRealInterest() public {
        _mint(alice, tokenA, DEPOSIT_A);
        _mint(bob, tokenB, DEPOSIT_B);
        pool.deployIdle();

        uint256 assetsBefore = pool.totalAssets();

        _warpAndAccrueRealInterest(180 days);

        uint256 assetsAfter = pool.totalAssets();
        uint256 realYield = assetsAfter - assetsBefore;
        assertGt(
            realYield,
            0,
            "180 days on a live, borrowed-against market should accrue measurable interest"
        );

        uint256 pendingA = pool.pendingYield(tokenA);
        uint256 pendingB = pool.pendingYield(tokenB);

        // All of the real yield must land on one brand or the other, and split 2:1.
        assertApproxEqAbs(pendingA + pendingB, realYield, 2);
        assertApproxEqAbs(pendingA, realYield * DEPOSIT_A / (DEPOSIT_A + DEPOSIT_B), 1e3);
        assertApproxEqAbs(pendingB, realYield * DEPOSIT_B / (DEPOSIT_A + DEPOSIT_B), 1e3);
    }

    function test_fork_swap_movesNoRealUsdgAndPreservesYieldEntitlement() public {
        _mint(alice, tokenA, DEPOSIT_A);
        _mint(bob, tokenB, DEPOSIT_B);
        pool.deployIdle();

        _warpAndAccrueRealInterest(90 days);

        uint256 pendingABefore = pool.pendingYield(tokenA);
        uint256 assetsBefore = pool.totalAssets();

        // Alice swaps her entire A position into B — real Morpho position must not move.
        vm.prank(alice);
        pool.swap(tokenA, tokenB, DEPOSIT_A, alice);

        assertEq(pool.totalAssets(), assetsBefore, "swap must not touch the real Morpho position");
        vm.prank(address(pool));
        uint256 deployedAfterSwap = yieldSource.balanceOf(USDG);
        assertApproxEqAbs(deployedAfterSwap, assetsBefore, 1);
        assertEq(PooledBrandToken(tokenB).balanceOf(alice), DEPOSIT_A);
        assertApproxEqAbs(
            pool.pendingYield(tokenA), pendingABefore, 1, "A's earned yield must survive the swap"
        );
    }

    function test_fork_claimYield_paysRealUsdgToTreasuryAdmin() public {
        _mint(alice, tokenA, DEPOSIT_A);
        _mint(bob, tokenB, DEPOSIT_B);
        pool.deployIdle();

        _warpAndAccrueRealInterest(180 days);

        uint256 pending = PoolBrandTreasury(treasuryA).pendingYield();
        assertGt(pending, 0, "180 days of real interest should have accrued something claimable");

        vm.prank(adminA);
        uint256 claimed = PoolBrandTreasury(treasuryA).claim(adminA);

        assertApproxEqAbs(claimed, pending, 1);
        assertEq(IERC20(USDG).balanceOf(adminA), claimed);
        assertEq(PoolBrandTreasury(treasuryA).pendingYield(), 0);

        // Brand B's independently-tracked entitlement must be completely unaffected.
        assertGt(PoolBrandTreasury(treasuryB).pendingYield(), 0);
    }

    // ─── Redemption fee timelock ──────────────────────────────────────────

    /// @dev The promise an aggregator routes on: a `previewRedeem` it read cannot be overtaken
    ///      by a fee increase it could not see. An announced increase is invisible to the quote
    ///      and to the payout for the whole delay, and a redemption landing at the very last
    ///      second of that window still settles at the fee that was quoted.
    function test_fork_scheduledFeeIncreaseMovesNoQuoteUntilCommitted() public {
        // From zero even the first fee is an increase, so establish the baseline through the
        // full schedule-wait-commit cycle.
        vm.prank(owner);
        pool.setRedemptionFee(10);
        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();

        _mint(alice, tokenA, DEPOSIT_A);
        pool.deployIdle();

        uint256 quoted = pool.previewRedeem(10_000e6);
        assertEq(quoted, 9_990e6, "10 bps of the amount burned");

        vm.prank(owner);
        pool.setRedemptionFee(100);
        assertEq(pool.redemptionFeeBps(), 10, "announced, not applied");
        assertEq(pool.pendingRedemptionFeeBps(), 100);
        assertEq(pool.previewRedeem(10_000e6), quoted, "the quote does not move");

        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();
        assertEq(effectiveAt, block.timestamp + pool.FEE_INCREASE_DELAY());

        // One second short of the hour: the increase cannot be forced through, and a payout
        // at that instant is still the one that was quoted before it was announced.
        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.FeeIncreaseNotReady.selector, effectiveAt, uint64(effectiveAt - 1)
            )
        );
        pool.commitRedemptionFee();

        uint256 before = IERC20(USDG).balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.redeem(tokenA, 10_000e6, alice);
        assertEq(paid, quoted, "settled at the old fee, an hour after it was quoted");
        assertEq(IERC20(USDG).balanceOf(alice) - before, quoted);

        vm.warp(effectiveAt);
        pool.commitRedemptionFee(); // permissionless: no prank
        assertEq(pool.redemptionFeeBps(), 100, "live only once the hour is served");
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "and nothing is pending any more");
        assertEq(pool.previewRedeem(10_000e6), 9_900e6);
    }
}
