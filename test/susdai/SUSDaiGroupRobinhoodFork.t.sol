// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {IAcrossSpokePool} from "../../src/interfaces/IAcrossSpokePool.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice The sUSDai group's Robinhood Chain half against the live chain: real USDG, the real
///         Across SpokePool, a fresh reserve pool and adapter. The hub is a placeholder address
///         on Arbitrum, so its reports are scripted; everything USDG does is not.
///
///         The public RPC keeps only a few hundred recent blocks, so this forks the head and
///         asserts on deltas, never on absolute chain state.
///
///         Reproduce:
///         forge test --match-contract SUSDaiGroupRobinhoodFork -vv
contract SUSDaiGroupRobinhoodForkTest is Test, StackFixture {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// @dev Largest USDG holder on the chain; the test's faucet.
    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    uint256 constant ARBITRUM = 42161;
    address constant HUB = address(0x4B0B);
    uint16 constant FEE_BPS = 14;
    /// @dev What Across quoted for USDG -> USDC on 2026-09-13, each way.
    uint256 constant BRIDGE_FEE_BPS = 6;

    IERC20 usdg = IERC20(USDG);
    IAcrossSpokePool spoke = IAcrossSpokePool(SPOKE_POOL);
    SharedReservePool pool;
    SUSDaiYieldSource adapter;

    address keeper = address(0xC0FFEE);
    address brandAdmin = address(0xA1);
    address alice = address(0xA11CE);

    address token;
    address treasury;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"))
        );
        _deployUpgradeBase();
        adapter = _deploySUSDaiAdapter(
            USDG,
            SPOKE_POOL,
            ARBITRUM,
            HUB,
            ARBITRUM_USDC,
            address(protocolGuard),
            stackOwner,
            keeper
        );
        pool = _deployReservePool(USDG, address(adapter), stackOwner);
        adapter.bindController(address(pool));
        vm.prank(stackOwner);
        adapter.setMaxBridgeAmount(100_000e6);
        // Announced only; an increase serves `FEE_INCREASE_DELAY` before it is live. Warping a
        // forked chain forward an hour is harmless here because nothing in this suite prices
        // off the fork's clock.
        vm.prank(stackOwner);
        pool.setRedemptionFee(FEE_BPS);
        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();

        (token, treasury) = pool.registerBrand("AI Dollar", "aiUSD", brandAdmin);
        vm.prank(MORPHO_BLUE);
        usdg.transfer(alice, 100_000e6);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _mint(uint256 amount) internal {
        vm.startPrank(alice);
        usdg.approve(address(pool), amount);
        pool.mint(token, amount, alice);
        vm.stopPrank();
    }

    function _lessBridgeFee(uint256 amount) internal pure returns (uint256) {
        return amount - amount * BRIDGE_FEE_BPS / 10_000;
    }

    function _quote(uint256 outputAmount) internal view returns (AcrossBridger.AcrossQuote memory) {
        return AcrossBridger.AcrossQuote({
            outputAmount: outputAmount,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 2 hours),
            exclusivityDeadline: 0
        });
    }

    function _bridgeOut(uint256 amount) internal returns (uint32) {
        AcrossBridger.AcrossQuote memory q = _quote(_lessBridgeFee(amount));
        vm.prank(keeper);
        return adapter.bridgeOut(amount, q);
    }

    function _sync(
        uint256 remoteValue,
        uint256 outboundAcked,
        uint256 inboundStarted,
        uint256 inboundLanded
    ) internal {
        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: remoteValue,
                outboundAcked: outboundAcked,
                outboundRefunded: 0,
                inboundStarted: inboundStarted,
                inboundLanded: inboundLanded,
                inboundRefunded: 0
            })
        );
    }

    /// @dev The buffer plus the wei the pool keeps idle after a recall (`shortfall + 1`).
    function _reserveCash() internal view returns (uint256) {
        return adapter.availableLiquidity() + usdg.balanceOf(address(pool));
    }

    // ─── Mint ────────────────────────────────────────────────────────────

    function test_fork_mint_isOneToOneAndNeverTouchesTheBridge() public {
        uint32 depositsBefore = spoke.numberOfDeposits();
        uint256 escrowBefore = usdg.balanceOf(SPOKE_POOL);
        uint256 aliceBefore = usdg.balanceOf(alice);

        _mint(10_000e6);

        assertEq(PooledBrandToken(token).balanceOf(alice), 10_000e6, "1:1");
        assertEq(aliceBefore - usdg.balanceOf(alice), 10_000e6);
        assertEq(usdg.balanceOf(address(pool)), 0, "deployed inline");
        assertEq(adapter.availableLiquidity(), 10_000e6, "and held, not bridged");
        assertEq(pool.totalAssets(), 10_000e6);
        assertEq(spoke.numberOfDeposits(), depositsBefore, "the real SpokePool saw nothing");
        assertEq(usdg.balanceOf(SPOKE_POOL), escrowBefore);
    }

    // ─── Bridge out ──────────────────────────────────────────────────────

    function test_fork_bridgeOut_depositsOnTheRealSpokePool() public {
        _mint(10_000e6);
        uint32 counter = spoke.numberOfDeposits();
        uint256 escrowBefore = usdg.balanceOf(SPOKE_POOL);
        uint256 output = _lessBridgeFee(8_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(output);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit AcrossBridger.Bridged(counter, HUB, ARBITRUM, USDG, 8_000e6, ARBITRUM_USDC, output);
        uint32 depositId = adapter.bridgeOut(8_000e6, q);

        assertEq(depositId, counter, "the id is the counter before the deposit");
        assertEq(spoke.numberOfDeposits(), counter + 1);
        assertEq(usdg.balanceOf(SPOKE_POOL) - escrowBefore, 8_000e6, "escrowed with Across");
        assertEq(adapter.availableLiquidity(), 2_000e6);
        assertEq(adapter.outboundInFlight(), 8_000e6);
        assertEq(
            pool.totalAssets(),
            9_995_200_000,
            "the leg is marked at what Across will deliver, so its fee is a cost already"
        );
    }

    function test_fork_bridgeOut_realPoolRejectsAFillDeadlineBeyondItsBuffer() public {
        _mint(10_000e6);
        uint32 buffer = spoke.fillDeadlineBuffer();
        AcrossBridger.AcrossQuote memory q = _quote(_lessBridgeFee(8_000e6));

        q.fillDeadline = uint32(block.timestamp + buffer + 1);
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("InvalidFillDeadline()")));
        adapter.bridgeOut(8_000e6, q);
        assertEq(adapter.outboundInFlight(), 0);

        q.fillDeadline = uint32(block.timestamp + buffer);
        vm.prank(keeper);
        adapter.bridgeOut(8_000e6, q);
        assertEq(adapter.outboundInFlight(), 8_000e6, "the buffer itself is allowed");
    }

    // ─── Redeem ──────────────────────────────────────────────────────────

    function test_fork_redeem_paysParLessFeeFromRealUsdg() public {
        _mint(10_000e6);
        uint256 want = pool.previewRedeem(1_000e6);
        assertEq(want, 998_600_000);
        uint256 before = usdg.balanceOf(alice);

        vm.prank(alice);
        uint256 paid = pool.redeem(token, 1_000e6, alice, want);

        assertEq(paid, want);
        assertEq(usdg.balanceOf(alice) - before, want, "real USDG, exact");
        assertEq(PooledBrandToken(token).balanceOf(alice), 9_000e6);
        assertEq(PooledBrandToken(token).totalSupply(), 9_000e6);
        assertEq(pool.totalPooledSupply(), 9_000e6);
        assertEq(_reserveCash(), 10_000e6 - want, "paid from the buffer");
        assertEq(pool.totalAssets(), 10_000e6 - want, "the fee stayed");
    }

    /// @dev With nine tenths of the reserve on the far side of the bridge, a 2,000 redemption
    ///      cannot be paid in full. Neither overload settles it short on its own: the bare one
    ///      derives the same bound from the live fee that `previewRedeem` quotes, so a caller
    ///      who never chose a haircut does not silently get one. Taking 1,000 for 2,000 of
    ///      brand tokens is reachable, but only by asking for it.
    function test_fork_redeem_thinBufferRevertsByDefault_andHaircutsOnlyWhenAsked() public {
        _mint(10_000e6);
        _bridgeOut(9_000e6); // buffer: 1,000
        _sync(8_990e6, 9_000e6, 0, 0);

        uint256 want = pool.previewRedeem(2_000e6);
        uint256 buffer = adapter.availableLiquidity();
        assertEq(buffer, 1_000e6, "only the tenth that stayed on this chain is reachable");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, buffer, want)
        );
        pool.redeem(token, 2_000e6, alice, want);
        assertEq(PooledBrandToken(token).balanceOf(alice), 10_000e6, "nothing burned");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, buffer, want)
        );
        pool.redeem(token, 2_000e6, alice);
        assertEq(PooledBrandToken(token).balanceOf(alice), 10_000e6, "still nothing burned");

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.redeem(token, 2_000e6, alice, buffer);
        assertEq(paid, 1_000e6, "what the buffer held");
        assertEq(usdg.balanceOf(alice) - before, 1_000e6);
        assertEq(adapter.availableLiquidity(), 0);
        assertEq(PooledBrandToken(token).balanceOf(alice), 8_000e6, "burned in full");
        assertEq(pool.totalPooledSupply(), 8_000e6);
    }

    // ─── Inbound ─────────────────────────────────────────────────────────

    function test_fork_inboundFill_landsAsPlainUsdgAndSyncReconciles() public {
        _mint(10_000e6);
        _bridgeOut(9_000e6);
        _sync(8_990e6, 9_000e6, 0, 0);

        // The keeper sold shares and handed 3,000 USDC to Across on Arbitrum.
        _sync(5_990e6, 0, 3_000e6, 0);
        assertEq(adapter.balanceOf(USDG), 9_990e6, "whole while in flight");

        // A relayer fills: USDG arrives by plain transfer, no call to anything of ours.
        uint256 landed = _lessBridgeFee(3_000e6);
        vm.prank(MORPHO_BLUE);
        usdg.transfer(address(adapter), landed);
        assertEq(
            adapter.balanceOf(USDG),
            9_990e6,
            "the fill is the leg arriving, not new value: nothing to claim as yield"
        );

        _sync(5_990e6, 0, 0, 3_000e6);
        assertEq(adapter.inboundInFlight(), 0);
        assertEq(adapter.balanceOf(USDG), 9_990e6 - 1_800_000, "down by exactly the bridge fee");
        assertEq(adapter.availableLiquidity(), 1_000e6 + landed);

        uint256 want = pool.previewRedeem(3_500e6);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.redeem(token, 3_500e6, alice, want);
        assertEq(paid, want);
        assertEq(usdg.balanceOf(alice) - before, want);
    }

    // ─── Yield ───────────────────────────────────────────────────────────

    function test_fork_yield_reportedHubGrowthIsClaimableByTheBrandTreasury() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6);
        // The hub received exactly what Across delivered and bought shares worth exactly that,
        // so this report books no swap cost; the bridge fee was taken at `bridgeOut`.
        _sync(7_995_200_000, 8_000e6, 0, 0);

        vm.warp(block.timestamp + 30 days);
        _sync(8_040e6, 0, 0, 0); // +0.5% over the month, inside 50 bps/day
        assertEq(pool.pendingYield(token), 40e6);

        vm.prank(brandAdmin);
        uint256 claimed = PoolBrandTreasury(treasury).claim(brandAdmin);
        assertEq(claimed, 40e6);
        assertEq(usdg.balanceOf(brandAdmin), 40e6, "real USDG out of the buffer");
        assertEq(_reserveCash(), 2_000e6 - 40e6);
        assertEq(pool.totalAssets(), 10_000e6, "back to par");
        assertEq(pool.pendingYield(token), 0);
    }

    // ─── Migration ───────────────────────────────────────────────────────

    /// @dev The caveat in the adapter's natspec, made concrete: `setYieldSource` recalls what
    ///      is on this chain and no more. The strict overload refuses to leave the 7,990 the
    ///      hub holds behind; the explicit one migrates anyway and books it as the loss it is.
    function test_fork_setYieldSource_refusesToStrandTheHubAndBooksItWhenForced() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6);
        _sync(7_990e6, 8_000e6, 0, 0);
        MockYieldSource replacement = new MockYieldSource();

        vm.prank(stackOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.MigrationWouldStrand.selector, 9_990e6, 2_000e6
            )
        );
        pool.setYieldSource(address(replacement));
        assertEq(address(pool.yieldSource()), address(adapter), "the migration did not happen");

        vm.prank(stackOwner);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.Recalled(2_000e6);
        vm.expectEmit(true, false, false, true, address(pool));
        emit SharedReservePool.MigrationStranded(address(adapter), 7_990e6);
        pool.setYieldSource(address(replacement), true);

        assertEq(usdg.balanceOf(address(pool)), 2_000e6, "only the local balance came back");
        assertEq(adapter.availableLiquidity(), 0);
        assertEq(adapter.balanceOf(USDG), 7_990e6, "the old adapter still reports the rest");
        assertEq(pool.totalAssets(), 2_000e6, "which the pool can no longer see");
        assertEq(
            pool.lossCarryforward(),
            8_000e6,
            "10 of costs booked before, plus the 7,990 written off by this migration"
        );
        assertEq(pool.totalPooledSupply(), 10_000e6, "against liabilities that did not move");
    }
}
