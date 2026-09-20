// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice The sUSDai group end to end on Robinhood Chain, with the bridge and the hub stood
///         in for: a user mints 1:1, the keeper bridges the backing out and reports the hub's
///         value back, the user redeems at par less the round-trip fee from the local buffer,
///         and the reserve's ledger nets the fee against the costs the keeper reported.
contract SUSDaiGroupTest is Test, StackFixture {
    uint256 constant HUB_CHAIN_ID = 42161;
    address constant HUB = address(0x4B0B);
    address constant HUB_USDC = address(0x05DC);
    uint16 constant FEE_BPS = 14;

    SharedReservePool pool;
    SUSDaiYieldSource adapter;
    MockUSDC usdg;
    MockAcrossSpokePool spokePool;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address brandAdmin = address(0xA1);
    address alice = address(0xA11CE);

    address token;
    address treasury;

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        spokePool = new MockAcrossSpokePool();
        adapter = _deploySUSDaiAdapter(
            address(usdg),
            address(spokePool),
            HUB_CHAIN_ID,
            HUB,
            HUB_USDC,
            address(protocolGuard),
            owner,
            keeper
        );
        pool = _deployReservePool(address(usdg), address(adapter), owner);
        adapter.bindController(address(pool));
        vm.prank(owner);
        adapter.setMaxBridgeAmount(100_000e6);
        vm.prank(owner);
        pool.setRedemptionFee(FEE_BPS);

        (token, treasury) = pool.registerBrand("AI Dollar", "aiUSD", brandAdmin);
        usdg.mint(alice, 1_000_000e6);
        vm.warp(1_800_000_000);
        // `setRedemptionFee` only ANNOUNCES an increase; it is live once `FEE_INCREASE_DELAY`
        // has been served. Every test below is about a group already running at `FEE_BPS`, so
        // the hour is served here (the warp above is far past it) rather than in each test.
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), FEE_BPS, "the group starts with its fee live");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _mint(uint256 amount) internal {
        vm.startPrank(alice);
        usdg.approve(address(pool), amount);
        pool.mint(token, amount, alice);
        vm.stopPrank();
    }

    function _quote(uint256 outputAmount) internal view returns (AcrossBridger.AcrossQuote memory) {
        return AcrossBridger.AcrossQuote({
            outputAmount: outputAmount,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityDeadline: 0
        });
    }

    function _bridgeOut(uint256 amount, uint256 outputAmount) internal returns (uint32) {
        AcrossBridger.AcrossQuote memory q = _quote(outputAmount);
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

    /// @dev What the real bridge does when a relayer fills the hub's deposit: USDG appears in
    ///      the adapter's balance with no call to the adapter at all.
    function _landInbound(uint256 usdgAmount) internal {
        usdg.mint(address(adapter), usdgAmount);
    }

    // ─── Mint ────────────────────────────────────────────────────────────

    function test_mint_isOneToOneAndParksBackingInTheAdapter() public {
        _mint(10_000e6);

        assertEq(PooledBrandToken(token).balanceOf(alice), 10_000e6, "1:1 brand tokens");
        assertEq(usdg.balanceOf(address(pool)), 0, "pool deploys inline");
        assertEq(adapter.availableLiquidity(), 10_000e6, "adapter holds it locally");
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);
        assertEq(pool.totalAssets(), 10_000e6);
        assertEq(pool.totalPooledSupply(), 10_000e6);
        assertEq(spokePool.numberOfDeposits(), 0, "mint never touches the bridge");
    }

    // ─── Bridge out ──────────────────────────────────────────────────────

    function test_bridgeOut_escrowsWithAcrossAndMarksTheLegAtWhatWillArrive() public {
        _mint(10_000e6);

        uint32 depositId = _bridgeOut(8_000e6, 7_995_200_000); // 6 bps quote

        assertEq(depositId, 0);
        assertEq(usdg.balanceOf(address(spokePool)), 8_000e6, "escrowed");
        assertEq(adapter.availableLiquidity(), 2_000e6, "buffer stays");
        assertEq(adapter.outboundInFlight(), 8_000e6);
        assertEq(adapter.outboundExpected(), 7_995_200_000, "marked at the quote's output");
        assertEq(
            adapter.balanceOf(address(usdg)),
            9_995_200_000,
            "in flight still counts, less the fee the bridge has already committed to taking"
        );
        assertEq(pool.totalAssets(), 9_995_200_000, "and the pool sees the cost when incurred");

        MockAcrossSpokePool.Deposit memory d = spokePool.lastDeposit();
        assertEq(d.depositor, address(adapter), "refunds come back to the adapter");
        assertEq(d.recipient, HUB, "only the hub receives");
        assertEq(d.inputToken, address(usdg));
        assertEq(d.outputToken, HUB_USDC, "only USDC is delivered");
        assertEq(d.destinationChainId, HUB_CHAIN_ID);
        assertEq(d.outputAmount, 7_995_200_000);
        assertEq(d.message.length, 0);
    }

    function test_bridgeOut_rejectsAQuoteBelowTheFeeFloor() public {
        _mint(10_000e6);
        // Default cap is 20 bps: 8,000 less 20 bps is 7,984.
        AcrossBridger.AcrossQuote memory q = _quote(7_983_999_999);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                AcrossBridger.BridgeOutputBelowFloor.selector, 7_983_999_999, 7_984e6
            )
        );
        adapter.bridgeOut(8_000e6, q);
    }

    function test_bridgeOut_mustLeaveTheLocalBuffer() public {
        _mint(10_000e6);
        // Default buffer is 10% of the position: 1,000 must stay.
        AcrossBridger.AcrossQuote memory q = _quote(9_100e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.LocalBufferBreached.selector, 900e6, 1_000e6)
        );
        adapter.bridgeOut(9_100e6, q);

        _bridgeOut(9_000e6, 8_994_600_000);
        assertEq(adapter.availableLiquidity(), 1_000e6);
    }

    function test_bridgeOut_onlyKeeperOrOwner_andHaltsUnderPause() public {
        _mint(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(1_000e6);

        vm.prank(alice);
        vm.expectRevert(SUSDaiYieldSource.NotKeeper.selector);
        adapter.bridgeOut(1_000e6, q);

        _pauseProtocol();
        vm.prank(keeper);
        vm.expectRevert();
        adapter.bridgeOut(1_000e6, q);

        // A pause stops new exposure, not exits.
        uint256 want = pool.previewRedeem(100e6);
        vm.prank(alice);
        pool.redeem(token, 100e6, alice, want);

        _unpauseProtocol();
        vm.prank(owner);
        adapter.bridgeOut(1_000e6, q);
        assertEq(adapter.outboundInFlight(), 1_000e6);
    }

    // ─── Sync ────────────────────────────────────────────────────────────

    function test_sync_booksBridgeAndSwapCostsAsALoss() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);

        // The hub received 7,995.2 USDC and bought shares now worth 7,990 at conservative NAV.
        _sync(7_990e6, 8_000e6, 0, 0);

        assertEq(adapter.outboundInFlight(), 0);
        assertEq(adapter.remoteValue(), 7_990e6);
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6);
        assertEq(pool.totalAssets(), 9_990e6);

        // The pool learns of it lazily, at the next accrual.
        assertEq(pool.lossCarryforward(), 0);
        _mint(1e6);
        assertEq(pool.lossCarryforward(), 10e6, "costs are a loss to recover from yield");
        assertEq(pool.pendingYield(token), 0, "not yet yield for anyone");
    }

    function test_sync_cannotAcknowledgeWhatWasNeverSent() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        vm.prank(keeper);
        vm.expectRevert(); // arithmetic underflow
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: 8_000e6,
                outboundAcked: 8_000e6 + 1,
                outboundRefunded: 0,
                inboundStarted: 0,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
    }

    function test_sync_capsHowFastRemoteValueMayGrow() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        _sync(7_990e6, 8_000e6, 0, 0);

        // Nothing bridged, no time passed: no growth allowed at all.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.RemoteValueAboveCap.selector, 7_990e6 + 1, 7_990e6
            )
        );
        adapter.sync(_report(7_990e6 + 1));

        // One day at the default 50 bps/day: 7,990 * 0.005 = 39.95 of headroom.
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.RemoteValueAboveCap.selector, 8_029_950_001, 8_029_950_000
            )
        );
        adapter.sync(_report(8_029_950_001));

        _sync(8_029_950_000, 0, 0, 0);
        assertEq(adapter.remoteValue(), 8_029_950_000);

        // Lowering is never capped.
        _sync(1e6, 0, 0, 0);
        assertEq(adapter.remoteValue(), 1e6);
    }

    function test_sync_growthCapCountsWhatMovesIntoInbound() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        _sync(7_990e6, 8_000e6, 0, 0);

        // Moving 1,000 out of remote and into inbound is not growth ...
        _sync(6_990e6, 0, 1_000e6, 0);
        assertEq(adapter.inboundInFlight(), 1_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6);

        // ... but claiming remote did not shrink while also starting inbound is.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.RemoteValueAboveCap.selector, 7_990e6, 6_990e6)
        );
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: 6_990e6,
                outboundAcked: 0,
                outboundRefunded: 0,
                inboundStarted: 1_000e6,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
    }

    function _report(uint256 remoteValue)
        internal
        pure
        returns (SUSDaiYieldSource.SyncReport memory)
    {
        return SUSDaiYieldSource.SyncReport({
            remoteValue: remoteValue,
            outboundAcked: 0,
            outboundRefunded: 0,
            inboundStarted: 0,
            inboundLanded: 0,
            inboundRefunded: 0
        });
    }

    // ─── Redeem ──────────────────────────────────────────────────────────

    function test_redeem_paysParLessTheFeeFromTheLocalBuffer() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        _sync(7_990e6, 8_000e6, 0, 0);

        uint256 expected = 1_000e6 - 1_000e6 * uint256(FEE_BPS) / 10_000; // 998.6
        assertEq(pool.previewRedeem(1_000e6), expected);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pool.redeem(token, 1_000e6, alice, expected);

        assertEq(paid, expected);
        assertEq(usdg.balanceOf(alice) - before, expected);
        assertEq(PooledBrandToken(token).balanceOf(alice), 9_000e6);
        // The pool recalls `shortfall + 1` and keeps the spare wei idle: buffer + idle is exact.
        assertEq(
            adapter.availableLiquidity() + usdg.balanceOf(address(pool)),
            2_000e6 - expected,
            "paid from the buffer"
        );
        assertEq(pool.totalAssets(), 9_990e6 - expected, "the fee stayed in the reserve");
    }

    function test_redeem_feeRepaysBookedCostsBeforeItBecomesYield() public {
        _mint(10_000e6);
        _bridgeOut(1_000e6, 999_400_000);
        _sync(990e6, 1_000e6, 0, 0); // 10 of costs, not yet observed by the pool

        uint256 want = pool.previewRedeem(1_000e6);
        vm.prank(alice);
        pool.redeem(token, 1_000e6, alice, want); // fee 1.4

        assertEq(pool.lossCarryforward(), 10e6, "observed on the way in");
        assertEq(pool.pendingYield(token), 0, "the fee repays the loss first");
        _mint(1e6); // any accrual
        assertEq(pool.lossCarryforward(), 8.6e6, "1.4 of the 10 repaid by the fee");

        // Enough redemptions and the fee turns into yield for the brands.
        for (uint256 i = 0; i < 6; i++) {
            vm.prank(alice);
            pool.redeem(token, 1_000e6, alice, 0);
        }
        // Six more fees of 1.4: 8.4 against the remaining 8.6 leaves 0.2 of loss ...
        _mint(1e6);
        assertEq(pool.lossCarryforward(), 0.2e6);
        assertEq(pool.pendingYield(token), 0);
        // ... and the next one clears it and credits the other 1.2 to the only brand.
        vm.prank(alice);
        pool.redeem(token, 1_000e6, alice, 0);
        assertApproxEqAbs(pool.pendingYield(token), 1.2e6, 1, "index rounding dust");
    }

    function test_redeem_revertsRatherThanShortPayingWhenTheBufferIsThin() public {
        _mint(10_000e6);
        _bridgeOut(9_000e6, 8_994_600_000); // buffer: 1,000
        _sync(8_990e6, 9_000e6, 0, 0);

        uint256 want = pool.previewRedeem(2_000e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, 1_000e6, want)
        );
        pool.redeem(token, 2_000e6, alice, want);

        // Opting into the haircut takes what is there; the shortfall is a haircut, not a fee.
        // It has to be opted into now: the three-argument overload demands par less the fee and
        // would refuse this too, which is the point of that change.
        vm.prank(alice);
        uint256 paid = pool.redeem(token, 2_000e6, alice, 0);
        assertEq(paid, 1_000e6);
        assertEq(adapter.availableLiquidity(), 0);
        assertEq(pool.totalPooledSupply(), 8_000e6);
    }

    function test_redeem_afterTheKeeperBringsCashHome() public {
        _mint(10_000e6);
        _bridgeOut(9_000e6, 8_994_600_000);
        _sync(8_990e6, 9_000e6, 0, 0);

        // Keeper sells shares and hands 3,000 USDC to Across on Arbitrum.
        _sync(5_990e6, 0, 3_000e6, 0);
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6, "still whole while in flight");

        // The relayer fills: 3,000 less 6 bps lands here as USDG.
        _landInbound(2_998_200_000);
        assertEq(
            adapter.balanceOf(address(usdg)),
            9_990e6,
            "the fill is the leg arriving, not new value: no phantom to claim"
        );
        _sync(5_990e6, 0, 0, 3_000e6);
        assertEq(adapter.inboundInFlight(), 0);
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6 - 1_800_000, "bridge fee is a cost");
        assertEq(adapter.availableLiquidity(), 3_998_200_000);

        uint256 want = pool.previewRedeem(3_500e6);
        vm.prank(alice);
        uint256 paid = pool.redeem(token, 3_500e6, alice, want);
        assertEq(paid, want);
    }

    function test_sync_outboundRefundReturnsToTheBufferWithoutGrowth() public {
        _mint(10_000e6);
        uint32 id = _bridgeOut(8_000e6, 7_995_200_000);

        // Nobody filled it; Across refunds the depositor on this chain.
        spokePool.refund(id);
        assertEq(adapter.availableLiquidity(), 10_000e6);
        assertEq(
            adapter.balanceOf(address(usdg)),
            10_000e6,
            "the refunded USDG is the leg coming back, so the counter is netted against it"
        );

        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: 0,
                outboundAcked: 0,
                outboundRefunded: 8_000e6,
                inboundStarted: 0,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
        assertEq(adapter.outboundInFlight(), 0);
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);

        // And a refund never buys the keeper any remote-value headroom.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.RemoteValueAboveCap.selector, 1, 0)
        );
        adapter.sync(_report(1));
    }

    // ─── Yield ───────────────────────────────────────────────────────────

    function test_yield_hubGrowthReachesTheBrandTreasuryThroughTheBuffer() public {
        _mint(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        // The hub received exactly the quote's output and bought shares worth exactly that, so
        // this report books no swap cost — the bridge fee was already taken at `bridgeOut`.
        _sync(7_995_200_000, 8_000e6, 0, 0);

        vm.warp(block.timestamp + 30 days);
        _sync(8_040e6, 0, 0, 0); // +0.5% over the month, inside 50 bps/day

        assertEq(pool.pendingYield(token), 40e6);
        vm.prank(brandAdmin);
        uint256 claimed = PoolBrandTreasury(treasury).claim(brandAdmin);
        assertEq(claimed, 40e6, "paid out of the local buffer");
        assertEq(usdg.balanceOf(brandAdmin), 40e6);
        assertEq(adapter.availableLiquidity() + usdg.balanceOf(address(pool)), 2_000e6 - 40e6);
        assertEq(pool.totalAssets(), 10_000e6, "and the reserve is back to par");
    }

    // ─── Binding and roles ───────────────────────────────────────────────

    function test_onlyThePoolMayDepositOrWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(SUSDaiYieldSource.NotController.selector);
        adapter.deposit(address(usdg), 1);

        vm.prank(keeper);
        vm.expectRevert(SUSDaiYieldSource.NotController.selector);
        adapter.withdraw(address(usdg), 1, keeper);
    }

    function test_bindController_isOneShotAndDeployerOnly() public {
        SUSDaiYieldSource fresh = _deploySUSDaiAdapter(
            address(usdg),
            address(spokePool),
            HUB_CHAIN_ID,
            HUB,
            HUB_USDC,
            address(protocolGuard),
            owner,
            keeper
        );
        vm.prank(alice);
        vm.expectRevert(SUSDaiYieldSource.NotDeployer.selector);
        fresh.bindController(alice);

        fresh.bindController(address(pool));
        vm.expectRevert(SUSDaiYieldSource.AlreadyBound.selector);
        fresh.bindController(alice);
    }

    function test_setRedemptionFee_isOwnerOnlyAndCapped() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.setRedemptionFee(1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SharedReservePool.FeeTooHigh.selector, 101, 100));
        pool.setRedemptionFee(101);

        // Raising the group's fee is announced, not applied: the sUSDai round trip getting
        // dearer is exactly the case where an aggregator must not be repriced mid-route.
        vm.prank(owner);
        pool.setRedemptionFee(100);
        assertEq(pool.previewRedeem(1_000e6), 998_600_000, "still quoting the live 14 bps");

        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();
        assertEq(pool.previewRedeem(1_000e6), 990e6);
    }
}
