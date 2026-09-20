// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev A `SUSDaiYieldSource` with one added function and one added storage variable, used to
///      prove an upgrade both preserves the position and can extend the layout.
contract SUSDaiYieldSourceV2 is SUSDaiYieldSource {
    /// @dev Appended after the parent's `__gap`, which is what makes this safe.
    string public upgradeNote;

    function setUpgradeNote(string calldata note) external {
        upgradeNote = note;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice `SUSDaiYieldSource` on its own: the controller is a plain address, the bridge is the
///         recording mock, and every test pins one rule the adapter enforces on the pool's
///         behalf or on the keeper's. The pool-facing story is in `SUSDaiGroup.t.sol`.
contract SUSDaiYieldSourceTest is Test, StackFixture {
    uint256 constant HUB_CHAIN_ID = 42161;
    address constant HUB = address(0x4B0B);
    address constant HUB_USDC = address(0x05DC);

    SUSDaiYieldSource adapter;
    MockUSDC usdg;
    MockAcrossSpokePool spokePool;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address controller = address(0xC0117);
    address stranger = address(0x5713);
    address other = address(0x07E2);

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        spokePool = new MockAcrossSpokePool();
        adapter = _newAdapter(
            address(usdg), address(spokePool), HUB, HUB_USDC, address(protocolGuard), keeper
        );
        adapter.bindController(controller);
        vm.prank(owner);
        adapter.setMaxBridgeAmount(100_000e6);
        vm.warp(1_800_000_000);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _newAdapter(
        address _usdg,
        address _spokePool,
        address _hub,
        address _hubUsdc,
        address _guard,
        address _keeper
    ) internal returns (SUSDaiYieldSource) {
        return _deploySUSDaiAdapter(
            _usdg, _spokePool, HUB_CHAIN_ID, _hub, _hubUsdc, _guard, owner, _keeper
        );
    }

    /// @dev What the pool does on a mint: hand USDG to the adapter and stop.
    function _fund(uint256 amount) internal {
        usdg.mint(controller, amount);
        vm.startPrank(controller);
        usdg.approve(address(adapter), amount);
        adapter.deposit(address(usdg), amount);
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

    function _report(
        uint256 remoteValue,
        uint256 outboundAcked,
        uint256 outboundRefunded,
        uint256 inboundStarted,
        uint256 inboundLanded,
        uint256 inboundRefunded
    ) internal pure returns (SUSDaiYieldSource.SyncReport memory) {
        return SUSDaiYieldSource.SyncReport({
            remoteValue: remoteValue,
            outboundAcked: outboundAcked,
            outboundRefunded: outboundRefunded,
            inboundStarted: inboundStarted,
            inboundLanded: inboundLanded,
            inboundRefunded: inboundRefunded
        });
    }

    function _sync(SUSDaiYieldSource.SyncReport memory r) internal {
        vm.prank(keeper);
        adapter.sync(r);
    }

    function _expectCap(uint256 reported, uint256 allowed) internal {
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.RemoteValueAboveCap.selector, reported, allowed
            )
        );
    }

    /// @dev The two properties the pool relies on. The position never exceeds the sum of the
    ///      four legs — which is what stops a leg that has already arrived from being counted
    ///      twice — and never falls below what is settled here and at the hub, so nothing real
    ///      is dropped. The exact figure at each step is asserted by the caller.
    function _assertPosition(string memory step) internal view {
        uint256 position = adapter.balanceOf(address(usdg));
        uint256 local = usdg.balanceOf(address(adapter));
        assertLe(
            position,
            local + adapter.outboundExpected() + adapter.inboundInFlight() + adapter.remoteValue(),
            step
        );
        assertGe(position, local + adapter.remoteValue(), step);
    }

    // ─── Construction ────────────────────────────────────────────────────

    function test_initialize_rejectsEachZeroAddress() public {
        address u = address(usdg);
        address s = address(spokePool);
        address g = address(protocolGuard);
        bytes memory zero = abi.encodeWithSelector(AcrossBridger.ZeroAddress.selector);

        vm.expectRevert(zero);
        _newAdapter(address(0), s, HUB, HUB_USDC, g, keeper);
        vm.expectRevert(zero);
        _newAdapter(u, address(0), HUB, HUB_USDC, g, keeper);
        vm.expectRevert(zero);
        _newAdapter(u, s, address(0), HUB_USDC, g, keeper);
        vm.expectRevert(zero);
        _newAdapter(u, s, HUB, address(0), g, keeper);
        vm.expectRevert(zero);
        _newAdapter(u, s, HUB, HUB_USDC, address(0), keeper);
        vm.expectRevert(zero);
        _newAdapter(u, s, HUB, HUB_USDC, g, address(0));

        SUSDaiYieldSource ok = _newAdapter(u, s, HUB, HUB_USDC, g, keeper);
        assertEq(ok.keeper(), keeper);
        assertEq(ok.owner(), owner);
        assertEq(ok.hub(), HUB);
        assertEq(ok.hubChainId(), HUB_CHAIN_ID);
    }

    // ─── IYieldSource surface ────────────────────────────────────────────

    function test_depositAndWithdraw_rejectAnyAssetButUsdg() public {
        MockUSDC wrong = new MockUSDC();
        wrong.mint(controller, 1e6);
        vm.startPrank(controller);
        wrong.approve(address(adapter), 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.UnsupportedAsset.selector, address(wrong))
        );
        adapter.deposit(address(wrong), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.UnsupportedAsset.selector, address(wrong))
        );
        adapter.withdraw(address(wrong), 1e6, controller);
        vm.stopPrank();

        assertEq(wrong.balanceOf(controller), 1e6, "nothing moved");
    }

    function test_balanceOfAndTotalAssets_areZeroForAnyAssetButUsdg() public {
        _fund(100e6);
        assertEq(adapter.balanceOf(other), 0);
        assertEq(adapter.totalAssets(other), 0);
        assertEq(adapter.balanceOf(address(usdg)), 100e6);
        assertEq(adapter.totalAssets(address(usdg)), 100e6);
    }

    function test_withdraw_paysWhatIsRequestedUpToTheLocalBalance() public {
        _fund(100e6);

        vm.prank(controller);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SUSDaiYieldSource.Withdrawn(40e6, 40e6);
        uint256 paid = adapter.withdraw(address(usdg), 40e6, controller);
        assertEq(paid, 40e6);
        assertEq(usdg.balanceOf(controller), 40e6);

        // Over-request: pays the balance, reports both numbers, never reverts.
        vm.prank(controller);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SUSDaiYieldSource.Withdrawn(150e6, 60e6);
        paid = adapter.withdraw(address(usdg), 150e6, controller);
        assertEq(paid, 60e6, "exactly the local balance");
        assertEq(usdg.balanceOf(controller), 100e6);
        assertEq(adapter.availableLiquidity(), 0);

        vm.prank(controller);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SUSDaiYieldSource.Withdrawn(0, 0);
        paid = adapter.withdraw(address(usdg), 0, controller);
        assertEq(paid, 0);
        assertEq(usdg.balanceOf(controller), 100e6);
    }

    /// @notice `withdrawable` is the number a quoter reads to size a redemption, so it has to
    ///         be the payout `withdraw` then makes: the local buffer, whatever the book says.
    function test_withdrawable_isExactlyWhatWithdrawWouldPay() public {
        _fund(100e6);
        // Thin the buffer without going through the bridge; what matters here is only that the
        // local balance and the position disagree.
        vm.prank(address(adapter));
        usdg.transfer(address(0xB41D6E), 70e6);

        assertEq(adapter.withdrawable(address(usdg), controller), 30e6, "only the buffer pays");
        assertEq(adapter.withdrawable(address(usdg), stranger), 0, "and only to the controller");

        vm.prank(controller);
        uint256 paid = adapter.withdraw(address(usdg), 100e6, controller);
        assertEq(paid, 30e6, "the prediction was the payout");
    }

    // ─── Roles ───────────────────────────────────────────────────────────

    function test_setKeeper_isOwnerOnlyRejectsZeroAndRotatesTheKey() public {
        address next = address(0xBEEF);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        adapter.setKeeper(next);

        vm.prank(owner);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        adapter.setKeeper(address(0));
        assertEq(adapter.keeper(), keeper, "a rejected rotation changes nothing");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(adapter));
        emit SUSDaiYieldSource.KeeperUpdated(keeper, next);
        adapter.setKeeper(next);
        assertEq(adapter.keeper(), next);

        // The old key is out, the new one is in.
        _fund(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(1_000e6);
        vm.prank(keeper);
        vm.expectRevert(SUSDaiYieldSource.NotKeeper.selector);
        adapter.bridgeOut(1_000e6, q);
        vm.prank(next);
        adapter.bridgeOut(1_000e6, q);
        assertEq(adapter.outboundInFlight(), 1_000e6);
    }

    function test_ownerMayActAsKeeper() public {
        _fund(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(999_400_000);

        vm.prank(stranger);
        vm.expectRevert(SUSDaiYieldSource.NotKeeper.selector);
        adapter.sync(_report(0, 0, 0, 0, 0, 0));

        vm.prank(owner);
        adapter.bridgeOut(1_000e6, q);
        assertEq(adapter.outboundInFlight(), 1_000e6);

        vm.prank(owner);
        adapter.sync(_report(999e6, 1_000e6, 0, 0, 0, 0));
        assertEq(adapter.outboundInFlight(), 0);
        assertEq(adapter.remoteValue(), 999e6);
    }

    // ─── Limits ──────────────────────────────────────────────────────────

    function test_setMaxBridgeAmount_defaultsClosed_isOwnerOnly_andCapsEachDeposit() public {
        SUSDaiYieldSource fresh = _newAdapter(
            address(usdg), address(spokePool), HUB, HUB_USDC, address(protocolGuard), keeper
        );
        fresh.bindController(controller);
        usdg.mint(address(fresh), 2_000e6);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.BridgeAmountAboveCap.selector, 1_000e6, 0)
        );
        fresh.bridgeOut(1_000e6, _quote(999e6));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        fresh.setMaxBridgeAmount(1_000e6);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit SUSDaiYieldSource.MaxBridgeAmountUpdated(0, 1_000e6);
        fresh.setMaxBridgeAmount(1_000e6);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.BridgeAmountAboveCap.selector, 1_000e6 + 1, 1_000e6
            )
        );
        fresh.bridgeOut(1_000e6 + 1, _quote(999e6));

        vm.prank(keeper);
        fresh.bridgeOut(1_000e6, _quote(999e6));
        assertEq(spokePool.lastDeposit().inputAmount, 1_000e6);
    }

    function test_setLimits_isOwnerOnlyAndRangeBound() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        adapter.setLimits(10, 500, 25);

        vm.startPrank(owner);
        vm.expectRevert(SUSDaiYieldSource.LimitOutOfRange.selector);
        adapter.setLimits(101, 500, 25);
        vm.expectRevert(SUSDaiYieldSource.LimitOutOfRange.selector);
        adapter.setLimits(10, 10_001, 25);
        vm.expectRevert(SUSDaiYieldSource.LimitOutOfRange.selector);
        adapter.setLimits(10, 500, 10_001);
        assertEq(adapter.maxBridgeFeeBps(), 20, "defaults survive a rejected update");
        assertEq(adapter.minLocalBufferBps(), 1_000);
        assertEq(adapter.maxRemoteGrowthBpsPerDay(), 50);

        vm.expectEmit(false, false, false, true, address(adapter));
        emit SUSDaiYieldSource.LimitsUpdated(100, 10_000, 10_000);
        adapter.setLimits(100, 10_000, 10_000);
        vm.stopPrank();
        assertEq(adapter.maxBridgeFeeBps(), 100, "each bound is inclusive");
        assertEq(adapter.minLocalBufferBps(), 10_000);
        assertEq(adapter.maxRemoteGrowthBpsPerDay(), 10_000);
    }

    function test_setLimits_feeFloorFollowsMaxBridgeFeeBps() public {
        vm.prank(owner);
        adapter.setLimits(6, 1_000, 50);
        _fund(10_000e6);

        // 8,000 less 6 bps is 7,995.2.
        AcrossBridger.AcrossQuote memory q = _quote(7_995_199_999);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                AcrossBridger.BridgeOutputBelowFloor.selector, 7_995_199_999, 7_995_200_000
            )
        );
        adapter.bridgeOut(8_000e6, q);

        _bridgeOut(8_000e6, 7_995_200_000);
        assertEq(spokePool.lastDeposit().outputAmount, 7_995_200_000);
    }

    function test_setLimits_bufferAtZeroLetsTheWholeBalanceGo() public {
        vm.prank(owner);
        adapter.setLimits(20, 0, 50);
        _fund(10_000e6);

        // A lossless quote, so the buffer rule is the only thing under test here.
        _bridgeOut(10_000e6, 10_000e6);
        assertEq(adapter.availableLiquidity(), 0);
        assertEq(adapter.outboundInFlight(), 10_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);

        // With nothing left, the balance check is what stops the next one.
        AcrossBridger.AcrossQuote memory q = _quote(1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.InsufficientLocalBalance.selector, 1, 0)
        );
        adapter.bridgeOut(1, q);
    }

    function test_setLimits_growthCapAtZeroAllowsNoTimeGrowthAtAll() public {
        vm.startPrank(owner);
        adapter.setLimits(20, 1_000, 0);
        // Both floors under the allowance have to be zero for "no growth at all": the absolute
        // one exists precisely so that a proportional cap of zero is not absorbing.
        adapter.setMaxRemoteGrowthAbsolutePerDay(0);
        vm.stopPrank();
        _fund(10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        vm.warp(block.timestamp + 365 days);
        _expectCap(8_000e6 + 1, 8_000e6);
        adapter.sync(_report(8_000e6 + 1, 0, 0, 0, 0, 0));

        // Only what is bridged over may ever raise it.
        _bridgeOut(1_000e6, 1_000e6);
        _sync(_report(9_000e6, 1_000e6, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 9_000e6);
    }

    function test_setLimits_growthCapAtFullDoublesInADay() public {
        vm.prank(owner);
        adapter.setLimits(20, 1_000, 10_000);
        _fund(10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        vm.warp(block.timestamp + 1 days);
        _expectCap(16_000e6 + 1, 16_000e6);
        adapter.sync(_report(16_000e6 + 1, 0, 0, 0, 0, 0));

        _sync(_report(16_000e6, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 16_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 18_000e6);
    }

    // ─── bridgeOut ───────────────────────────────────────────────────────

    function test_bridgeOut_feeFloorIsInclusive() public {
        _fund(10_000e6);
        // Default 20 bps: 8,000 less 20 bps is 7,984.
        AcrossBridger.AcrossQuote memory q = _quote(7_983_999_999);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                AcrossBridger.BridgeOutputBelowFloor.selector, 7_983_999_999, 7_984e6
            )
        );
        adapter.bridgeOut(8_000e6, q);

        _bridgeOut(8_000e6, 7_984e6);
        assertEq(spokePool.lastDeposit().outputAmount, 7_984e6);
        assertEq(usdg.balanceOf(address(spokePool)), 8_000e6);
    }

    function test_bridgeOut_bufferIsInclusiveAndCountsWhatIsAlreadyInFlight() public {
        _fund(10_000e6);
        // Default 10% of the position: 1,000 must stay.
        AcrossBridger.AcrossQuote memory q = _quote(9_000e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.LocalBufferBreached.selector, 999_999_999, 1_000e6
            )
        );
        adapter.bridgeOut(9_000e6 + 1, q);

        _bridgeOut(9_000e6, 9_000e6);
        assertEq(adapter.availableLiquidity(), 1_000e6);

        // The position is still 10,000 with 9,000 in flight, so the buffer is still 1,000.
        q = _quote(1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.LocalBufferBreached.selector, 999_999_999, 1_000e6
            )
        );
        adapter.bridgeOut(1, q);

        // And more than the balance is its own error, checked before the buffer.
        q = _quote(1_000e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.InsufficientLocalBalance.selector, 1_000e6 + 1, 1_000e6
            )
        );
        adapter.bridgeOut(1_000e6 + 1, q);
    }

    function test_bridgeOut_emitsBridgedAndBridgedOutWithTheSpokePoolsId() public {
        _fund(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(7_995_200_000);
        q.exclusiveRelayer = address(0xE1);
        q.exclusivityDeadline = 60;
        q.fillDeadline = uint32(block.timestamp + 2 hours);

        vm.prank(keeper);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit AcrossBridger.Bridged(
            0, HUB, HUB_CHAIN_ID, address(usdg), 8_000e6, HUB_USDC, 7_995_200_000
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SUSDaiYieldSource.BridgedOut(0, 8_000e6, 7_995_200_000);
        uint32 id = adapter.bridgeOut(8_000e6, q);
        assertEq(id, 0);

        MockAcrossSpokePool.Deposit memory d = spokePool.lastDeposit();
        assertEq(d.depositor, address(adapter), "refunds come back here");
        assertEq(d.recipient, HUB);
        assertEq(d.inputToken, address(usdg));
        assertEq(d.outputToken, HUB_USDC);
        assertEq(d.inputAmount, 8_000e6);
        assertEq(d.outputAmount, 7_995_200_000);
        assertEq(d.destinationChainId, HUB_CHAIN_ID);
        assertEq(d.exclusiveRelayer, address(0xE1), "the quote passes through untouched");
        assertEq(d.quoteTimestamp, uint32(block.timestamp));
        assertEq(d.fillDeadline, uint32(block.timestamp + 2 hours));
        assertEq(d.exclusivityDeadline, 60);
        assertEq(d.message.length, 0);

        // The id is the SpokePool's counter, read before the deposit.
        vm.prank(keeper);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SUSDaiYieldSource.BridgedOut(1, 500e6, 499_700_000);
        assertEq(adapter.bridgeOut(500e6, _quote(499_700_000)), 1);
        assertEq(spokePool.numberOfDeposits(), 2);
    }

    function test_bridgeOut_staleQuoteIsRejectedByTheSpokePool() public {
        _fund(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(7_995_200_000);
        q.quoteTimestamp = uint32(block.timestamp - 3601);
        vm.prank(keeper);
        vm.expectRevert(MockAcrossSpokePool.InvalidQuoteTimestamp.selector);
        adapter.bridgeOut(8_000e6, q);

        q.quoteTimestamp = uint32(block.timestamp - 3600);
        vm.prank(keeper);
        adapter.bridgeOut(8_000e6, q);
        assertEq(adapter.outboundInFlight(), 8_000e6);
    }

    function test_bridgeOut_zeroAmountAndPauseAreRefused() public {
        _fund(10_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(0);
        vm.prank(keeper);
        vm.expectRevert(AcrossBridger.ZeroAmount.selector);
        adapter.bridgeOut(0, q);

        _pauseProtocol();
        q = _quote(999_400_000);
        vm.prank(keeper);
        vm.expectRevert(ProtocolGuard.ProtocolPaused.selector);
        adapter.bridgeOut(1_000e6, q);
        assertEq(adapter.outboundInFlight(), 0);
    }

    // ─── sync ────────────────────────────────────────────────────────────

    function test_sync_growthCapIsProRataByElapsedTime() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        // Half a day at 50 bps/day is 25 bps: 8,000 * 0.0025 = 20 of headroom.
        vm.warp(block.timestamp + 12 hours);
        _expectCap(8_020e6 + 1, 8_020e6);
        adapter.sync(_report(8_020e6 + 1, 0, 0, 0, 0, 0));

        _sync(_report(8_020e6, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 8_020e6);
        assertEq(adapter.remoteValueUpdatedAt(), block.timestamp);

        // The clock restarts at every report: no time, no headroom.
        _expectCap(8_020e6 + 1, 8_020e6);
        adapter.sync(_report(8_020e6 + 1, 0, 0, 0, 0, 0));
    }

    function test_sync_inboundRefundExtendsTheCapAndLeavesFlight() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        // The hub sold and handed 3,000 to Across.
        _sync(_report(5_000e6, 0, 0, 3_000e6, 0, 0));
        assertEq(adapter.inboundInFlight(), 3_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);

        // Nobody filled it; Across refunded the hub. The refund is not growth ...
        _expectCap(8_000e6 + 1, 8_000e6);
        adapter.sync(_report(8_000e6 + 1, 0, 0, 0, 0, 3_000e6));

        // ... but exactly the refund is allowed back into the remote value.
        _sync(_report(8_000e6, 0, 0, 0, 0, 3_000e6));
        assertEq(adapter.inboundInFlight(), 0);
        assertEq(adapter.remoteValue(), 8_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);
    }

    function test_sync_cannotLandOrRefundMoreThanWasStarted() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));
        _sync(_report(5_000e6, 0, 0, 3_000e6, 0, 0));

        vm.prank(keeper);
        vm.expectRevert(stdError.arithmeticError);
        adapter.sync(_report(5_000e6, 0, 0, 0, 3_000e6 + 1, 0));

        vm.prank(keeper);
        vm.expectRevert(stdError.arithmeticError);
        adapter.sync(_report(5_000e6, 0, 0, 0, 1_500e6, 1_500e6 + 1));

        // Nor refund outbound that was never sent.
        vm.prank(keeper);
        vm.expectRevert(stdError.arithmeticError);
        adapter.sync(_report(5_000e6, 0, 1, 0, 0, 0));

        _sync(_report(5_000e6, 0, 0, 0, 1_500e6, 1_500e6));
        assertEq(adapter.inboundInFlight(), 0);
    }

    function test_sync_worksWhileTheProtocolIsPaused() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);

        _pauseProtocol();
        _sync(_report(7_990e6, 8_000e6, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 7_990e6);
        assertEq(adapter.outboundInFlight(), 0);
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6, "the valuation keeps moving");
    }

    function test_sync_stampsRemoteValueUpdatedAtOnEveryReport() public {
        assertEq(adapter.remoteValueUpdatedAt(), 0);

        _sync(_report(0, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValueUpdatedAt(), block.timestamp, "even a report of nothing");

        vm.warp(block.timestamp + 3 days);
        _sync(_report(0, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValueUpdatedAt(), block.timestamp);
    }

    function test_sync_emitsTheStateAfterTheReport() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        _bridgeOut(500e6, 499_700_000);

        // Acks the first deposit only, and moves 500 of the remote value into a bridge home.
        vm.prank(keeper);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit SUSDaiYieldSource.Synced(7_490e6, 500e6, 500e6, 8_000e6, 0, 500e6, 0, 0);
        adapter.sync(_report(7_490e6, 8_000e6, 0, 500e6, 0, 0));

        assertEq(adapter.outboundInFlight(), 500e6);
        assertEq(adapter.inboundInFlight(), 500e6);
        assertEq(adapter.remoteValue(), 7_490e6);
    }

    // ─── The position identity ───────────────────────────────────────────

    /// @notice An Across fill credits the local balance with no call to this contract, and the
    ///         matching counter only clears on a later `sync`. Anything that treats both as
    ///         separate money mints yield the reserve does not have, so the walk below lands a
    ///         fill and a refund and pins the position across each one.
    function test_position_neverCountsALegThatHasAlreadyArrivedTwice() public {
        _fund(10_000e6);
        _assertPosition("after deposit");
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6);

        uint32 first = _bridgeOut(8_000e6, 7_995_200_000);
        _assertPosition("after bridgeOut");
        assertEq(
            adapter.balanceOf(address(usdg)),
            9_995_200_000,
            "the leg is marked at what the bridge will deliver, so its fee is a cost already"
        );

        _sync(_report(7_990e6, 8_000e6, 0, 0, 0, 0)); // ack, 5.2 more of swap costs
        _assertPosition("after ack");
        assertEq(adapter.balanceOf(address(usdg)), 9_990e6);

        vm.prank(controller);
        adapter.withdraw(address(usdg), 1_000e6, controller);
        _assertPosition("after withdraw");
        assertEq(adapter.balanceOf(address(usdg)), 8_990e6);

        _sync(_report(4_990e6, 0, 0, 3_000e6, 0, 0)); // hub sold 3,000 and bridged it
        _assertPosition("after inbound started");
        assertEq(adapter.balanceOf(address(usdg)), 8_990e6, "moving a leg home changes nothing");

        // The fill: 3,000 less 6 bps appears in the balance with no call to the adapter. This
        // is the step where summing the legs would show 2,998.2 of yield that does not exist.
        usdg.mint(address(adapter), 2_998_200_000);
        _assertPosition("after the fill, before the keeper notices");
        assertEq(
            adapter.balanceOf(address(usdg)),
            8_990e6,
            "an arrival nobody has reported yet is not new value"
        );

        _sync(_report(4_990e6, 0, 0, 0, 3_000e6, 0));
        _assertPosition("after landing");
        assertEq(adapter.balanceOf(address(usdg)), 8_988_200_000, "the bridge fee is the cost");

        uint32 second = _bridgeOut(2_000e6, 1_998_800_000);
        assertEq(second, first + 1);
        _assertPosition("after a second bridgeOut");

        // A refund returns the exact input, again with no call here.
        spokePool.refund(second);
        _assertPosition("after the refund, before the keeper notices");
        assertEq(
            adapter.balanceOf(address(usdg)),
            8_988_200_000,
            "the same USDG is back and the fee it never paid is released; neither is yield"
        );

        _sync(_report(4_990e6, 0, 2_000e6, 0, 0, 0));
        _assertPosition("after the refund is booked");

        assertEq(adapter.availableLiquidity(), 3_998_200_000);
        assertEq(adapter.outboundInFlight(), 0);
        assertEq(adapter.outboundExpected(), 0);
        assertEq(adapter.inboundInFlight(), 0);
        assertEq(adapter.remoteValue(), 4_990e6);
        assertEq(adapter.balanceOf(address(usdg)), 8_988_200_000);
    }

    // ─── Upgrading ───────────────────────────────────────────────────────

    /// @notice The property the conversion to UUPS exists to provide: a bug in this adapter can
    ///         be fixed in ONE transaction, with no delay, while it is custodying the reserve's
    ///         buffer and carrying in-flight counters that cannot be recomputed from anywhere
    ///         else. The counters, the buffer and the wiring all have to come through unchanged,
    ///         and nobody but the owner may move the code.
    function test_ownerUpgradesInOneTransactionAndTheWholePositionSurvives() public {
        _fund(10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        // 6,000 of the 8,000 acknowledged by the hub, 4,000 of it held there and 1,500 already
        // sold and bridged back: every counter nonzero, which is the state worth carrying.
        _sync(_report(4_000e6, 6_000e6, 0, 1_500e6, 0, 0));

        uint256 localBefore = usdg.balanceOf(address(adapter));
        uint256 outboundBefore = adapter.outboundInFlight();
        uint256 inboundBefore = adapter.inboundInFlight();
        uint256 remoteBefore = adapter.remoteValue();
        uint64 updatedAtBefore = adapter.remoteValueUpdatedAt();
        uint256 positionBefore = adapter.balanceOf(address(usdg));
        assertGt(outboundBefore, 0, "precondition: USDG is in flight to the hub");
        assertGt(inboundBefore, 0, "precondition: USDC is in flight home");
        assertGt(remoteBefore, 0, "precondition: the hub holds value");

        address v2 = address(new SUSDaiYieldSourceV2());
        uint256 blockBefore = block.number;
        vm.prank(owner);
        adapter.upgradeToAndCall(v2, "");

        assertEq(block.number, blockBefore, "no delay: the new code is live in the same block");
        assertEq(SUSDaiYieldSourceV2(address(adapter)).version(), 2, "new code is live");

        assertEq(usdg.balanceOf(address(adapter)), localBefore, "the redemption buffer survived");
        assertEq(adapter.outboundInFlight(), outboundBefore, "outbound counter survived");
        assertEq(adapter.inboundInFlight(), inboundBefore, "inbound counter survived");
        assertEq(adapter.remoteValue(), remoteBefore, "the hub's reported value survived");
        assertEq(adapter.remoteValueUpdatedAt(), updatedAtBefore, "the report's age survived");
        assertEq(adapter.balanceOf(address(usdg)), positionBefore, "the pool sees the same size");
        assertEq(adapter.controller(), controller, "the binding survived");
        assertEq(adapter.keeper(), keeper);
        assertEq(address(adapter.usdg()), address(usdg), "wiring survived");
        assertEq(address(adapter.spokePool()), address(spokePool), "the bridge survived");
        assertEq(adapter.hub(), HUB);
        assertEq(adapter.maxBridgeAmount(), 100_000e6, "owner-set limits survived");
        assertEq(adapter.minLocalBufferBps(), 1_000);
        assertEq(address(adapter.guard()), address(protocolGuard), "the pause registry survived");

        // Appended state is usable and did not land on anything already there.
        SUSDaiYieldSourceV2(address(adapter)).setUpgradeNote("v2");
        assertEq(SUSDaiYieldSourceV2(address(adapter)).upgradeNote(), "v2");
        assertEq(adapter.remoteValue(), remoteBefore, "and still survived");

        // And the keeper can still drive it: the position is not just readable, it works.
        _sync(_report(remoteBefore, 0, 0, 0, inboundBefore, 0));
        assertEq(adapter.inboundInFlight(), 0, "the upgraded adapter still settles reports");
    }

    /// @notice Upgrading is the most consequential call on this contract; the keeper, the
    ///         controller and the guardian are all strangers to it.
    function test_nobodyButTheOwnerCanUpgradeTheAdapter() public {
        address v2 = address(new SUSDaiYieldSourceV2());

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        adapter.upgradeToAndCall(v2, "");

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, controller)
        );
        adapter.upgradeToAndCall(v2, "");

        vm.prank(stackGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stackGuardian)
        );
        adapter.upgradeToAndCall(v2, "");
    }
}
