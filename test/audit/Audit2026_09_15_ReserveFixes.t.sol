// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {
    SUSDaiTestnetCurve,
    SUSDaiTestnetShares,
    SUSDaiTestnetToken
} from "../../src/testnet/SUSDaiTestnetMocks.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";
import {MockCurveStableSwapNG} from "../mocks/MockCurveStableSwapNG.sol";
import {MockStakedUSDai} from "../mocks/MockStakedUSDai.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice The 2026-09-15 reserve review, as tests. Each one was written to FAIL against the
///         code as audited and to pass against the fix, so reverting a fix reopens a red test
///         rather than a silent hole. Findings are cited by id; the narrative lives in the
///         audit, the arithmetic lives here.
contract Audit2026_09_15_AdapterFixesTest is Test, StackFixture {
    uint256 constant HUB_CHAIN_ID = 42161;
    address constant HUB = address(0x4B0B);
    address constant HUB_USDC = address(0x05DC);

    SharedReservePool pool;
    SUSDaiYieldSource adapter;
    MockUSDC usdg;
    MockAcrossSpokePool spokePool;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address stranger = address(0x5713);
    address honestBrandAdmin = address(0xA1);
    address attacker = address(0xBAD);
    address depositor = address(0xA11CE);

    address honestToken;
    address attackerToken;
    address attackerTreasury;

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
        vm.startPrank(owner);
        adapter.setMaxBridgeAmount(100_000e6);
        pool.setRedemptionFee(14);
        vm.stopPrank();

        (honestToken,) = pool.registerBrand("Honest", "HON", honestBrandAdmin);
        usdg.mint(depositor, 1_000_000e6);
        usdg.mint(attacker, 1_000_000e6);
        vm.warp(1_800_000_000);
        // The 14 bps above was only ANNOUNCED: an increase serves `FEE_INCREASE_DELAY` before
        // it can be committed. The warp is far past that, so put it in force here — these
        // tests are about a reserve already charging the fee, not about the announcement.
        pool.commitRedemptionFee();
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

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
        vm.prank(keeper);
        return adapter.bridgeOut(amount, _quote(outputAmount));
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

    function _mint(address who, address token, uint256 amount) internal {
        vm.startPrank(who);
        usdg.approve(address(pool), amount);
        pool.mint(token, amount, who);
        vm.stopPrank();
    }

    function _notOwner(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
    }

    // ─── RSV-002 ─────────────────────────────────────────────────────────

    /// @notice The audit's worked example, which was exploitable on the live testnet by anyone.
    ///         An Across fill credits the adapter's balance the moment a relayer fills, with no
    ///         call to the adapter; the in-flight counter only clears on the keeper's NEXT sync.
    ///         Summing both terms showed the leg twice, the pool credited the difference to its
    ///         monotonic yield index, and `claimYield` paid it out of principal that was never
    ///         clawed back. Registering a brand and minting are permissionless and USDG is a
    ///         faucet, so the whole attack was: watch for a public fill, then claim.
    function test_RSV002_aFillThatHasLandedCannotBeClaimedAsYield() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        // The keeper sells at the hub and hands 1,000 to Across for the trip home.
        _sync(_report(7_000e6, 0, 0, 1_000e6, 0, 0));
        assertEq(adapter.inboundInFlight(), 1_000e6);

        // The attacker registers its own brand and mints against the reserve. Both are
        // permissionless by design, and the mint re-syncs the pool's accrual baseline, which is
        // what makes the phantom that follows land entirely on the attacker's ledger.
        vm.prank(attacker);
        (attackerToken, attackerTreasury) = pool.registerBrand("Phantom", "PHAN", attacker);
        _mint(attacker, attackerToken, 5_000e6);
        uint256 assetsBefore = pool.totalAssets();
        assertEq(assetsBefore, 15_000e6);
        assertEq(pool.totalPooledSupply(), 15_000e6);

        // A relayer fills the inbound leg: 1,000 less 6 bps appears in the adapter's balance.
        usdg.mint(address(adapter), 999_400_000);

        assertEq(
            pool.totalAssets(),
            assetsBefore,
            "the fill is the leg arriving, not 999.4 of new assets"
        );
        assertEq(pool.pendingYield(attackerToken), 0, "so there is no phantom to be entitled to");
        assertEq(pool.pendingYield(honestToken), 0);

        vm.prank(attacker);
        uint256 claimed = PoolBrandTreasury(attackerTreasury).claim(attacker);
        assertEq(claimed, 0, "and nothing to withdraw");
        assertEq(
            usdg.balanceOf(attacker), 1_000_000e6 - 5_000e6, "the attacker is only out its deposit"
        );

        // The keeper's report settles the leg and the only change is the bridge fee, as a loss.
        _sync(_report(7_000e6, 0, 0, 0, 1_000e6, 0));
        assertEq(pool.totalAssets(), assetsBefore - 600_000, "6 bps of bridge fee, nothing else");
        assertEq(pool.pendingYield(attackerToken), 0);
        vm.prank(attacker);
        assertEq(PoolBrandTreasury(attackerTreasury).claim(attacker), 0);
    }

    /// @notice The conservative half of the same rule, stated so its cost is on the record: an
    ///         adapter cannot tell a donation from a fill that landed early, so while a leg is
    ///         outstanding it assumes the fill. The donation is recognised at the settlement
    ///         that accounts for the leg — one sync late, never lost.
    function test_RSV002_aDonationIsRecognisedOneSettlementLate() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        uint256 before = adapter.balanceOf(address(usdg));
        assertEq(before, 10_000e6);

        vm.prank(stranger);
        usdg.mint(address(adapter), 500e6);
        assertEq(adapter.balanceOf(address(usdg)), before, "assumed to be the leg arriving");

        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));
        assertEq(adapter.balanceOf(address(usdg)), before + 500e6, "and released once accounted");
    }

    // ─── RSV-003, RSV-005, RSV-009 ───────────────────────────────────────

    /// @notice `sync` may only raise `remoteValue` from what it was last told, so zero was an
    ///         absorbing state: one report — from a stolen keeper key, or from an honest keeper
    ///         reading a collapsed oracle — wrote the hub's holdings off with no way back short
    ///         of an upgrade. The absolute per-day floor gives the allowance a way out, and
    ///         `setRemoteValue` turns the incident into one transaction.
    function test_RSV003_aWrittenOffPositionIsRecoverableWithoutAnUpgrade() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        // One report writes off 80% of the reserve. Lowering is deliberately never capped.
        _sync(_report(0, 0, 0, 0, 0, 0));
        assertEq(adapter.balanceOf(address(usdg)), 2_000e6, "the hub still holds 8,000 of it");

        // Nothing bridged and no time elapsed: the allowance is zero, as it always was.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.RemoteValueAboveCap.selector, 1, 0)
        );
        adapter.sync(_report(1, 0, 0, 0, 0, 0));

        // A day later the absolute floor is the entire allowance, so zero is no longer
        // absorbing — but climbing back at 10/day is a crawl, which is why the break-glass
        // exists. It grants the owner nothing `_authorizeUpgrade` does not already grant.
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.RemoteValueAboveCap.selector, 10e6 + 1, 10e6)
        );
        adapter.sync(_report(10e6 + 1, 0, 0, 0, 0, 0));
        _sync(_report(10e6, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 10e6);

        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        adapter.setRemoteValue(8_000e6);
        vm.prank(stranger);
        vm.expectRevert(_notOwner(stranger));
        adapter.setRemoteValue(8_000e6);

        vm.prank(owner);
        vm.expectEmit(address(adapter));
        emit SUSDaiYieldSource.RemoteValueOverridden(10e6, 8_000e6);
        adapter.setRemoteValue(8_000e6);
        assertEq(adapter.remoteValue(), 8_000e6);
        assertEq(adapter.remoteValueUpdatedAt(), block.timestamp, "and the growth clock restarts");
        assertEq(adapter.balanceOf(address(usdg)), 10_000e6, "one transaction, not an upgrade");
    }

    /// @notice The growth allowance is linear in the time since the last report, and nothing
    ///         bounded that time. A dormant deployment — the normal state of a testnet — used
    ///         to accumulate enough headroom to invent the whole position back.
    function test_RSV009_aYearOfSilenceBuysSevenDaysOfAllowance() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));

        // 50 bps/day of 8,000 is 40/day. Seven days of it is 280; a year of it would be 14,600.
        vm.warp(block.timestamp + 365 days);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.RemoteValueAboveCap.selector, 8_280e6 + 1, 8_280e6
            )
        );
        adapter.sync(_report(8_280e6 + 1, 0, 0, 0, 0, 0));

        _sync(_report(8_280e6, 0, 0, 0, 0, 0));
        assertEq(adapter.remoteValue(), 8_280e6, "real yield is recognised over later reports");
    }

    /// @notice Every counter on this adapter is written only by the keeper and only through
    ///         `sync`, so a settlement the keeper observes but cannot report left a counter
    ///         permanently too high — and an in-flight counter that is too high overstates the
    ///         position forever, which is RSV-002 made permanent.
    function test_RSV005_resetInFlight_isOwnerOnlyAndCorrectsAnInflatedCounter() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 7_995_200_000);
        assertEq(adapter.outboundInFlight(), 8_000e6);
        assertEq(adapter.outboundExpected(), 7_995_200_000);

        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        adapter.resetInFlight(0, 0);
        vm.prank(stranger);
        vm.expectRevert(_notOwner(stranger));
        adapter.resetInFlight(0, 0);

        vm.prank(owner);
        vm.expectEmit(address(adapter));
        emit SUSDaiYieldSource.InFlightReset(8_000e6, 4_000e6, 0, 1_000e6);
        adapter.resetInFlight(4_000e6, 1_000e6);
        assertEq(adapter.outboundInFlight(), 4_000e6);
        assertEq(
            adapter.outboundExpected(), 4_000e6, "what will arrive cannot exceed what is in flight"
        );
        assertEq(adapter.inboundInFlight(), 1_000e6);
        assertEq(adapter.balanceOf(address(usdg)), 2_000e6 + 4_000e6 + 1_000e6);

        vm.prank(owner);
        adapter.resetInFlight(0, 0);
        assertEq(adapter.outboundExpected(), 0);
        assertEq(adapter.balanceOf(address(usdg)), 2_000e6, "back to what is provably here");
    }

    // ─── RSV-004 ─────────────────────────────────────────────────────────

    /// @notice `maxBridgeAmount` bounds one deposit and nothing bounded a sequence of them, so
    ///         a stolen keeper key could push the entire buffer across in a single block.
    function test_RSV004_theBridgeBudgetBoundsALoopedDrain() public {
        _mint(depositor, honestToken, 100_000e6);
        vm.prank(owner);
        adapter.setBridgeBudget(15_000e6, 1 days);
        assertEq(adapter.bridgeBudgetRemaining(), 15_000e6);

        _bridgeOut(10_000e6, 10_000e6);
        assertEq(adapter.bridgeBudgetRemaining(), 5_000e6);

        // Same block, same call, well inside the per-deposit cap and the buffer floor.
        AcrossBridger.AcrossQuote memory q = _quote(10_000e6);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.BridgeBudgetExhausted.selector, 10_000e6, 5_000e6
            )
        );
        adapter.bridgeOut(10_000e6, q);

        vm.warp(block.timestamp + 1 days);
        assertEq(adapter.bridgeBudgetRemaining(), 15_000e6, "the window rolls, it does not top up");
        _bridgeOut(10_000e6, 10_000e6);

        // Zero is the fail-closed default, which is what a proxy upgraded onto this state reads.
        vm.prank(owner);
        adapter.setBridgeBudget(0, 1 days);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiYieldSource.BridgeBudgetExhausted.selector, 1, 0)
        );
        adapter.bridgeOut(1, _quote(1));
    }

    // ─── RSV-007 ─────────────────────────────────────────────────────────

    /// @notice The bps buffer floor is a share of `_position()`, which includes the value the
    ///         keeper itself reports — so a keeper that wrote the remote value down shrank its
    ///         own floor and could then bridge out almost the whole redemption buffer. A token
    ///         floor cannot be moved by any report.
    function test_RSV007_theAbsoluteBufferFloorSurvivesADeflatedRemoteValue() public {
        _mint(depositor, honestToken, 10_000e6);
        _bridgeOut(8_000e6, 8_000e6);
        _sync(_report(8_000e6, 8_000e6, 0, 0, 0, 0));
        vm.prank(owner);
        vm.expectEmit(address(adapter));
        emit SUSDaiYieldSource.MinLocalBufferAbsoluteUpdated(0, 1_500e6);
        adapter.setMinLocalBufferAbsolute(1_500e6);

        // The keeper reports the hub as worth nothing, collapsing the bps floor from 1,000 to
        // 200. Before the absolute floor, 1,800 of the 2,000 buffer could then be bridged away.
        _sync(_report(0, 0, 0, 0, 0, 0));
        assertEq(adapter.balanceOf(address(usdg)) * adapter.minLocalBufferBps() / 10_000, 200e6);

        AcrossBridger.AcrossQuote memory q = _quote(500e6 + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiYieldSource.LocalBufferBreached.selector, 1_499_999_999, 1_500e6
            )
        );
        adapter.bridgeOut(500e6 + 1, q);

        _bridgeOut(500e6, 500e6);
        assertEq(adapter.availableLiquidity(), 1_500e6, "the floor is inclusive and unspoofable");
    }

    // ─── RSV-010, UUPS-002, UUPS-003 ─────────────────────────────────────

    /// @notice `AcrossBridger`'s fee floor subtracts basis points of the INPUT and compares the
    ///         result against an output denominated in the destination token, so it is only a
    ///         bound while both sides share decimals. An 18-decimal input would make it vacuous.
    function test_RSV010_initializeRejectsAUsdgThatIsNotSixDecimals() public {
        MockStakedUSDai eighteen = new MockStakedUSDai(address(usdg));
        assertEq(eighteen.decimals(), 18);
        vm.expectRevert(SUSDaiYieldSource.UnexpectedDecimals.selector);
        _deploySUSDaiAdapter(
            address(eighteen),
            address(spokePool),
            HUB_CHAIN_ID,
            HUB,
            HUB_USDC,
            address(protocolGuard),
            owner,
            keeper
        );
    }

    /// @notice `deployer` is the initializer's caller, which behind a proxy is whoever ran the
    ///         CREATE. A deployer-only bind bricks any adapter created by a contract that does
    ///         not bind in the same transaction; the owner is admitted so the binding can
    ///         always be completed, and it is still one-shot.
    function test_UUPS002_bindControllerAdmitsTheOwnerAndIsStillOneShot() public {
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

        vm.prank(stranger);
        vm.expectRevert(SUSDaiYieldSource.NotDeployer.selector);
        fresh.bindController(stranger);

        vm.prank(owner);
        fresh.bindController(address(pool));
        assertEq(fresh.controller(), address(pool));

        vm.prank(owner);
        vm.expectRevert(SUSDaiYieldSource.AlreadyBound.selector);
        fresh.bindController(stranger);
        // Not even the deployer, which is this test contract, may rebind.
        vm.expectRevert(SUSDaiYieldSource.AlreadyBound.selector);
        fresh.bindController(stranger);
    }

    /// @notice On a UUPS proxy the owner is the only upgrade authority, so renouncing does not
    ///         decentralize anything — it freezes the implementation and every lever with it.
    function test_UUPS003_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(SUSDaiYieldSource.OwnershipCannotBeRenounced.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), owner);

        // The intentional handover path is untouched, and it is still two-step.
        vm.prank(owner);
        adapter.transferOwnership(stranger);
        assertEq(adapter.owner(), owner);
        assertEq(adapter.pendingOwner(), stranger);
    }

    /// @notice The state an in-place upgrade actually lands in, which a fresh deployment never
    ///         sees: `localAtLastSettlement` reads zero against a live buffer, so `_position()`
    ///         reads the whole buffer as an unexplained arrival and nets it off the in-flight
    ///         counters. Understating is the safe direction, but it suppresses real yield and
    ///         makes the reserve look short, and no ordinary call converges on the right value.
    function test_RSV002_upgradedProxyUnderreportsUntilTheBaselineIsSeeded() public {
        // A fresh proxy with a balance it never received through `deposit` IS the upgraded-proxy
        // state: balance real, baseline zero. Reached here by minting straight to the address,
        // which is also the donation case the netting rule deliberately defers.
        SUSDaiYieldSource upgraded = _deploySUSDaiAdapter(
            address(usdg),
            address(spokePool),
            HUB_CHAIN_ID,
            HUB,
            HUB_USDC,
            address(protocolGuard),
            owner,
            keeper
        );
        upgraded.bindController(address(this));
        vm.prank(owner);
        upgraded.setMaxBridgeAmount(100_000e6);
        usdg.mint(address(upgraded), 10_000e6);
        assertEq(upgraded.localAtLastSettlement(), 0);

        vm.prank(keeper);
        upgraded.bridgeOut(2_000e6, _quote(1_999e6));

        // The outbound leg is real and outstanding, but the unaccounted balance cancels it out.
        uint256 understated = upgraded.totalAssets(address(usdg));
        assertEq(understated, usdg.balanceOf(address(upgraded)));
        assertGt(upgraded.outboundExpected(), 0);

        vm.prank(owner);
        upgraded.seedLocalBaseline();
        assertEq(upgraded.localAtLastSettlement(), usdg.balanceOf(address(upgraded)));

        // Seeded, the position is the honest sum again: what is here plus what is in flight.
        assertEq(
            upgraded.totalAssets(address(usdg)),
            usdg.balanceOf(address(upgraded)) + upgraded.outboundExpected() + upgraded.remoteValue()
        );
        assertEq(upgraded.totalAssets(address(usdg)), understated + upgraded.outboundExpected());

        vm.prank(stranger);
        vm.expectRevert();
        upgraded.seedLocalBaseline();
    }
}

/// @notice The hub half: what a rewritten share price and a looping keeper can and cannot do.
contract Audit2026_09_15_HubFixesTest is Test {
    uint256 constant HOME_CHAIN_ID = 4663;
    address constant HOME_USDG = address(0x05D6);
    address constant ADAPTER = address(0xADA0);
    address constant USDAI = address(0x05DA1);

    MockUSDC usdc;
    MockStakedUSDai susdai;
    MockCurveStableSwapNG curve;
    MockAcrossSpokePool spoke;
    SUSDaiHub hub;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address stranger = address(0x5713);

    function setUp() public {
        usdc = new MockUSDC();
        susdai = new MockStakedUSDai(USDAI);
        curve = new MockCurveStableSwapNG(address(susdai), address(usdc), 1.1e18, 1);
        usdc.mint(address(curve), 10_000_000e6);
        susdai.mint(address(curve), 10_000_000e18);
        spoke = new MockAcrossSpokePool();
        hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiHub()),
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            address(usdc),
                            address(susdai),
                            address(curve),
                            address(spoke),
                            HOME_CHAIN_ID,
                            HOME_USDG,
                            owner,
                            keeper
                        )
                    )
                )
            )
        );
        vm.startPrank(owner);
        hub.setHomeReceiver(ADAPTER);
        hub.setMaxBridgeAmount(100_000e6);
        vm.stopPrank();
        vm.warp(1_800_000_000);
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

    function _outOfBand(uint256 price) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            SUSDaiHub.SharePriceOutOfBand.selector, price, uint256(0.9e18), uint256(10e18)
        );
    }

    // ─── RSV-001 ─────────────────────────────────────────────────────────

    /// @notice The critical finding. Every floor and every valuation here comes from sUSDai's
    ///         own share prices, and on the live testnet the price source is a fixture whose
    ///         setter had no access control — so any address could mark the collateral at dust
    ///         and let the HONEST keeper sell all of it for nothing. The band refuses the read
    ///         rather than clamping it: a collapsed NAV must stop the keeper trading, not make
    ///         it trade against a stale mark.
    function test_RSV001_aDustedSharePriceStopsTheSwapInsteadOfPricingIt() public {
        susdai.mint(address(hub), 1_000e18);
        assertEq(hub.sellFloor(1_000e18), 1_098_350_000, "1,100 at NAV less 15 bps");

        // What the unauthenticated fixture setter allowed anyone to do.
        vm.prank(stranger);
        susdai.setSharePrices(1, 1);

        vm.expectRevert(_outOfBand(1));
        hub.sellFloor(1_000e18);
        vm.expectRevert(_outOfBand(1));
        hub.buyFloor(1_000e6);
        vm.expectRevert(_outOfBand(1));
        hub.conservativeValue();
        vm.expectRevert(_outOfBand(1));
        hub.optimisticValue();

        // The attack itself: a zero floor used to accept a zero min-out and the Curve pool
        // would have handed over 1,099.89 of USDC for shares now marked at nothing.
        vm.prank(keeper);
        vm.expectRevert(_outOfBand(1));
        hub.sellShares(1_000e18, 0);
        assertEq(hub.sharesHeld(), 1_000e18, "the collateral never left");

        // A price above the band is refused the same way: a decimal slip is not a windfall.
        vm.prank(stranger);
        susdai.setSharePrices(11e18, 11e18);
        vm.prank(keeper);
        vm.expectRevert(_outOfBand(11e18));
        hub.buyShares(1_000e6, 0);
    }

    function test_RSV001_theBandIsOwnerSetAndOrdered() public {
        susdai.mint(address(hub), 1_000e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        hub.setSharePriceBand(1e18, 2e18);

        vm.startPrank(owner);
        vm.expectRevert(SUSDaiHub.LimitOutOfRange.selector);
        hub.setSharePriceBand(0, 2e18);
        vm.expectRevert(SUSDaiHub.LimitOutOfRange.selector);
        hub.setSharePriceBand(2e18, 2e18 - 1);

        vm.expectEmit(address(hub));
        emit SUSDaiHub.SharePriceBandUpdated(1e18, 1.5e18);
        hub.setSharePriceBand(1e18, 1.5e18);
        vm.stopPrank();
        assertEq(hub.minSharePriceWad(), 1e18);
        assertEq(hub.maxSharePriceWad(), 1.5e18);

        // The default band admits today's fixture and the measured live NAV; the tightened one
        // refuses a price that would have passed it.
        assertGt(hub.conservativeValue(), 0);
        vm.prank(stranger);
        susdai.setSharePrices(0.95e18, 0.95e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                SUSDaiHub.SharePriceOutOfBand.selector, 0.95e18, uint256(1e18), uint256(1.5e18)
            )
        );
        hub.conservativeValue();
    }

    // ─── RSV-004 ─────────────────────────────────────────────────────────

    /// @notice `buyShares` and `sellShares` form a closed loop that needs no bridge and no
    ///         outside capital, and each leg may execute up to `maxSwapSlippageBps` under NAV.
    ///         Per-leg limits bound one iteration; only a cumulative budget bounds the loop.
    function test_RSV004_theSwapBudgetBoundsALoopedDrain() public {
        usdc.mint(address(hub), 2_000e6);
        vm.prank(owner);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.SwapBudgetUpdated(2_500e6, 1 days);
        hub.setSwapBudget(2_500e6, 1 days);

        uint256 buyFloor = hub.buyFloor(2_000e6);
        vm.prank(keeper);
        uint256 shares = hub.buyShares(2_000e6, buyFloor);
        assertEq(hub.swapBudgetRemaining(), 500e6);

        // The other half of the round trip, in the same block, is refused.
        uint256 notional = hub.sharesToUsdc(shares, susdai.redemptionSharePrice());
        uint256 sellFloor = hub.sellFloor(shares);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.SwapBudgetExhausted.selector, notional, 500e6)
        );
        hub.sellShares(shares, sellFloor);

        // And the bridge draws on the same budget, so there is no route around it.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.SwapBudgetExhausted.selector, 600e6, 500e6)
        );
        hub.bridgeHome(600e6, _quote(599e6));

        vm.warp(block.timestamp + 1 days);
        assertEq(hub.swapBudgetRemaining(), 2_500e6, "the window rolls, it does not top up");
        vm.prank(keeper);
        hub.sellShares(shares, sellFloor);
        assertEq(hub.sharesHeld(), 0);

        // Zero is the fail-closed default, which is what a proxy upgraded onto this state reads.
        vm.prank(owner);
        hub.setSwapBudget(0, 1 days);
        buyFloor = hub.buyFloor(1e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SUSDaiHub.SwapBudgetExhausted.selector, 1e6, 0));
        hub.buyShares(1e6, buyFloor);
    }

    function test_UUPS003_hubOwnershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(SUSDaiHub.OwnershipCannotBeRenounced.selector);
        hub.renounceOwnership();
        assertEq(hub.owner(), owner);

        vm.prank(owner);
        hub.transferOwnership(stranger);
        assertEq(hub.owner(), owner, "the handover is still two-step");
        assertEq(hub.pendingOwner(), stranger);
    }
}

/// @notice The fixture half of RSV-001: the faucet stays open, the oracle does not.
contract Audit2026_09_15_TestnetFixtureTest is Test {
    SUSDaiTestnetToken usdai;
    SUSDaiTestnetToken usdc;
    SUSDaiTestnetShares shares;
    SUSDaiTestnetCurve curve;

    address stranger = address(0x5713);

    function setUp() public {
        vm.chainId(31337);
        usdai = new SUSDaiTestnetToken("Test USDai", "tUSDai", 18);
        usdc = new SUSDaiTestnetToken("Test USDC", "tUSDC", 6);
        shares = new SUSDaiTestnetShares(address(usdai));
        curve = new SUSDaiTestnetCurve(address(shares), address(usdc), 1.1e18, 1);
    }

    function test_RSV001_thePricesAreOwnerOnlyAndTheFaucetsStayOpen() public {
        assertEq(shares.owner(), address(this), "whoever deployed the fixture");
        assertEq(curve.owner(), address(this));

        bytes memory notOwner =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.prank(stranger);
        vm.expectRevert(notOwner);
        shares.setSharePrices(1, 1);
        vm.prank(stranger);
        vm.expectRevert(notOwner);
        curve.setRate(1);
        assertEq(shares.depositSharePrice(), 1.1e18);
        assertEq(shares.redemptionSharePrice(), 1.095e18);
        assertEq(curve.rate(), 1.1e18);

        // Being a faucet is the point of the fixture, and that is unchanged.
        vm.startPrank(stranger);
        shares.mint(stranger, 1e18);
        usdai.mint(stranger, 1e18);
        usdc.mint(stranger, 1e6);
        vm.stopPrank();
        assertEq(shares.balanceOf(stranger), 1e18);
        assertEq(usdai.balanceOf(stranger), 1e18);
        assertEq(usdc.balanceOf(stranger), 1e6);

        // The owner still drives an exercise.
        shares.setSharePrices(1.2e18, 1.19e18);
        curve.setRate(1.2e18);
        assertEq(shares.depositSharePrice(), 1.2e18);
        assertEq(curve.rate(), 1.2e18);
    }
}
