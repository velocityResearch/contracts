// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract SUSDaiInvariantHandler is Test {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ACTION = 100_000e6;

    SharedReservePool public immutable pool;
    SUSDaiYieldSource public immutable adapter;
    MockUSDC public immutable usdg;
    address public immutable tokenA;
    address public immutable tokenB;
    address public immutable treasuryA;
    address public immutable treasuryB;
    address public immutable keeper;
    address public immutable user;
    address public immutable treasuryAdmin;

    constructor(
        SharedReservePool pool_,
        SUSDaiYieldSource adapter_,
        MockUSDC usdg_,
        address tokenA_,
        address tokenB_,
        address treasuryA_,
        address treasuryB_,
        address keeper_,
        address user_,
        address treasuryAdmin_
    ) {
        pool = pool_;
        adapter = adapter_;
        usdg = usdg_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        treasuryA = treasuryA_;
        treasuryB = treasuryB_;
        keeper = keeper_;
        user = user_;
        treasuryAdmin = treasuryAdmin_;
    }

    function mint(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 cap = pool.liabilityCap();
        uint256 supply = pool.totalPooledSupply();
        if (supply >= cap) return;
        uint256 amount = bound(amountSeed, 1, Math.min(cap - supply, MAX_ACTION));
        address token = tokenSeed % 2 == 0 ? tokenA : tokenB;

        usdg.mint(user, amount);
        vm.startPrank(user);
        usdg.approve(address(pool), amount);
        pool.mint(token, amount, user);
        vm.stopPrank();
    }

    function redeem(uint256 tokenSeed, uint256 amountSeed) external {
        address token = tokenSeed % 2 == 0 ? tokenA : tokenB;
        uint256 balance = PooledBrandToken(token).balanceOf(user);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(user);
        pool.redeem(token, amount, user);
    }

    function swap(uint256 directionSeed, uint256 amountSeed) external {
        (address tokenIn, address tokenOut) =
            directionSeed % 2 == 0 ? (tokenA, tokenB) : (tokenB, tokenA);
        uint256 balance = PooledBrandToken(tokenIn).balanceOf(user);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(user);
        pool.swap(tokenIn, tokenOut, amount, user);
    }

    function bridgeOut(uint256 amountSeed) external {
        if (block.timestamp > type(uint32).max - 1 hours) return;
        uint256 local = adapter.availableLiquidity();
        uint256 required = adapter.balanceOf(address(usdg)) * adapter.minLocalBufferBps() / BPS;
        if (local <= required) return;
        uint256 maximum = Math.min(
            Math.min(local - required, adapter.maxBridgeAmount()), adapter.bridgeBudgetRemaining()
        );
        if (maximum == 0) return;
        uint256 amount = bound(amountSeed, 1, maximum);
        // The modelled bridge is lossless, so that the invariants below assert properties of
        // the accounting machine rather than of a modelled fee. A bridge fee is a LOSS, and
        // `invariant_principalRemainsFullyBacked` is only true of a reserve that has not taken
        // one yet; that the fee is booked the moment the deposit is made is pinned by
        // `SUSDaiYieldSource.t.sol` and `SUSDaiGroup.t.sol` instead.
        uint256 output = amount;
        AcrossBridger.AcrossQuote memory quote = AcrossBridger.AcrossQuote({
            outputAmount: output,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityDeadline: 0
        });
        vm.prank(keeper);
        adapter.bridgeOut(amount, quote);
    }

    function acknowledgeOutbound(uint256 amountSeed) external {
        uint256 outbound = adapter.outboundInFlight();
        uint256 remote = adapter.remoteValue();
        if (outbound == 0 || outbound > type(uint256).max - remote) return;
        uint256 amount = bound(amountSeed, 1, outbound);
        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: remote + amount,
                outboundAcked: amount,
                outboundRefunded: 0,
                inboundStarted: 0,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
    }

    function returnHome(uint256 amountSeed) external {
        uint256 remote = adapter.remoteValue();
        if (remote == 0) return;
        uint256 amount = bound(amountSeed, 1, remote);
        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: remote - amount,
                outboundAcked: 0,
                outboundRefunded: 0,
                inboundStarted: amount,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
        usdg.mint(address(adapter), amount);
        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: remote - amount,
                outboundAcked: 0,
                outboundRefunded: 0,
                inboundStarted: 0,
                inboundLanded: amount,
                inboundRefunded: 0
            })
        );
    }

    function accrueRemoteYield(uint256 elapsedSeed) external {
        uint256 remote = adapter.remoteValue();
        if (remote == 0 || remote >= 100_000_000e6 || block.timestamp > 4_000_000_000 - 1 hours) {
            return;
        }
        uint256 elapsed =
            bound(elapsedSeed, 1 hours, Math.min(7 days, 4_000_000_000 - block.timestamp));
        vm.warp(block.timestamp + elapsed);
        uint256 growth = remote.mulDiv(adapter.maxRemoteGrowthBpsPerDay() * elapsed, BPS * 1 days);
        if (growth == 0) return;
        vm.prank(keeper);
        adapter.sync(
            SUSDaiYieldSource.SyncReport({
                remoteValue: remote + growth,
                outboundAcked: 0,
                outboundRefunded: 0,
                inboundStarted: 0,
                inboundLanded: 0,
                inboundRefunded: 0
            })
        );
    }

    /// @dev Unexpected USDG appearing on this chain, delivered to the pool's idle balance
    ///      rather than to the adapter. A donation straight into the adapter is deliberately
    ///      NOT recognised until the next settlement — the adapter cannot tell a donation from
    ///      an Across fill that has landed early, and it must assume the fill, or a public
    ///      transfer becomes claimable yield. So while a leg is in flight such a donation makes
    ///      the position understate, which is safe but is a modelled LOSS and not something
    ///      `invariant_principalRemainsFullyBacked` can hold across. That path is pinned
    ///      directly in `test/audit/Audit2026_09_15_ReserveFixes.t.sol`.
    function donateToReserve(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, MAX_ACTION);
        usdg.mint(address(pool), amount);
    }

    function claimYield(uint256 tokenSeed) external {
        address treasury = tokenSeed % 2 == 0 ? treasuryA : treasuryB;
        vm.prank(treasuryAdmin);
        PoolBrandTreasury(treasury).claim(treasuryAdmin);
    }
}

contract SUSDaiInvariantTest is StdInvariant, Test, StackFixture {
    uint256 internal constant LIABILITY_CAP = 1_000_000e6;

    SharedReservePool pool;
    SUSDaiYieldSource adapter;
    MockUSDC usdg;
    SUSDaiInvariantHandler handler;
    address tokenA;
    address tokenB;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address user = address(0xA11CE);
    address treasuryAdmin = address(0xB0B);

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        MockAcrossSpokePool spokePool = new MockAcrossSpokePool();
        adapter = _deploySUSDaiAdapter(
            address(usdg),
            address(spokePool),
            42161,
            address(0x4B0B),
            address(0x05DC),
            address(protocolGuard),
            owner,
            keeper
        );
        pool = _deployReservePool(address(usdg), address(adapter), owner);
        adapter.bindController(address(pool));

        vm.startPrank(owner);
        adapter.setMaxBridgeAmount(100_000e6);
        pool.setLiabilityCap(LIABILITY_CAP);
        pool.setRedemptionFee(14);
        vm.stopPrank();
        // The 14 bps is announced by the setter; the invariants below are meant to run against
        // a reserve that actually charges it, so serve `FEE_INCREASE_DELAY` before the handler
        // starts. The handler never touches the fee, so it stays live for the whole run.
        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();

        address treasuryA;
        address treasuryB;
        (tokenA, treasuryA) = pool.registerBrand("Invariant A", "invA", treasuryAdmin);
        (tokenB, treasuryB) = pool.registerBrand("Invariant B", "invB", treasuryAdmin);

        handler = new SUSDaiInvariantHandler(
            pool, adapter, usdg, tokenA, tokenB, treasuryA, treasuryB, keeper, user, treasuryAdmin
        );
        targetContract(address(handler));
    }

    function invariant_brandLedgersEqualTokenSupplies() public view {
        assertEq(pool.outstandingOf(tokenA), PooledBrandToken(tokenA).totalSupply());
        assertEq(pool.outstandingOf(tokenB), PooledBrandToken(tokenB).totalSupply());
    }

    function invariant_aggregateSupplyEqualsAllBrandSupplies() public view {
        assertEq(
            pool.totalPooledSupply(),
            PooledBrandToken(tokenA).totalSupply() + PooledBrandToken(tokenB).totalSupply()
        );
    }

    function invariant_liabilitiesNeverExceedConfiguredCap() public view {
        assertLe(pool.totalPooledSupply(), pool.liabilityCap());
        assertEq(pool.liabilityCap(), LIABILITY_CAP);
    }

    /// @dev Not an equality. The position is bounded above by the sum of its legs, which is
    ///      what stops a leg that has already arrived — an Across fill credits the balance with
    ///      no call to the adapter — from being counted a second time and paid out as yield.
    ///      It is bounded below by what is settled here and at the hub, so nothing real is
    ///      dropped. `addLocalYield` drives the gap: an increase the adapter cannot account for
    ///      is treated as a leg arriving until a report says otherwise.
    function invariant_adapterPositionIsBoundedByItsAccountingLegs() public view {
        uint256 local = usdg.balanceOf(address(adapter));
        uint256 ceiling =
            local + adapter.outboundExpected() + adapter.inboundInFlight() + adapter.remoteValue();
        uint256 position = adapter.balanceOf(address(usdg));
        assertLe(position, ceiling);
        assertGe(position, local + adapter.remoteValue());
        assertEq(adapter.totalAssets(address(usdg)), position);
    }

    function invariant_poolAssetsEqualIdlePlusAdapterPosition() public view {
        assertEq(
            pool.totalAssets(), usdg.balanceOf(address(pool)) + adapter.balanceOf(address(usdg))
        );
    }

    function invariant_principalRemainsFullyBacked() public view {
        assertGe(pool.totalAssets(), pool.totalPooledSupply());
    }

    function invariant_claimableYieldCannotConsumePrincipal() public view {
        uint256 surplus = pool.totalAssets() - pool.totalPooledSupply();
        assertLe(pool.pendingYield(tokenA) + pool.pendingYield(tokenB), surplus);
    }
}
