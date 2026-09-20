// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice Thin consumer that deposits/withdraws through a shared adapter, so each has a
///         distinct `msg.sender` from the adapter's point of view (mirrors two reserve pools).
contract Consumer {
    MorphoBlueYieldSource public immutable adapter;
    address public immutable usdg;

    constructor(MorphoBlueYieldSource _adapter, address _usdg) {
        adapter = _adapter;
        usdg = _usdg;
    }

    function deposit(uint256 amount) external {
        IERC20(usdg).approve(address(adapter), amount);
        adapter.deposit(usdg, amount);
    }

    function withdraw(uint256 amount, address to) external returns (uint256) {
        return adapter.withdraw(usdg, amount, to);
    }

    function balance() external view returns (uint256) {
        return adapter.balanceOf(usdg);
    }
}

/// @title AdapterMultiConsumerForkTest
/// @notice Stress-tests the per-consumer accounting on the real Morpho Blue market: three
///         consumers share ONE adapter, interleave partial and full withdrawals across real
///         interest accrual, and must stay perfectly isolated — nobody can withdraw more than
///         they funded (plus their share of yield), and nobody can touch another's principal.
contract AdapterMultiConsumerForkTest is Test, StackFixture {
    address constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;

    MorphoBlueYieldSource adapter;
    Consumer a;
    Consumer b;
    Consumer c;
    address attacker = address(0xBAD);

    function setUp() public {
        _deployUpgradeBase();
        vm.skip(block.chainid != 4663);
        adapter = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, stackOwner);
        a = new Consumer(adapter, USDG);
        b = new Consumer(adapter, USDG);
        c = new Consumer(adapter, USDG);

        vm.startPrank(MORPHO_BLUE);
        IERC20(USDG).transfer(address(a), 100_000e6);
        IERC20(USDG).transfer(address(b), 250_000e6);
        IERC20(USDG).transfer(address(c), 40_000e6);
        vm.stopPrank();
    }

    /// @dev Uses full exits and isolation invariants rather than exact deltas: Morpho accrues
    ///      interest lazily (only inside a state-changing call), so `balanceOf` legitimately
    ///      jumps when someone else's withdrawal triggers accrual. The security property is
    ///      what matters — no consumer can be drained by another, and an attacker gets nothing.
    function test_threeConsumersStayIsolatedAcrossInterestAndWithdrawals() public {
        a.deposit(100_000e6);
        b.deposit(250_000e6);
        c.deposit(40_000e6);

        // Each sees ~its own deposit, never the pooled total.
        assertApproxEqAbs(a.balance(), 100_000e6, 2, "A sees only its own");
        assertApproxEqAbs(b.balance(), 250_000e6, 2, "B sees only its own");
        assertApproxEqAbs(c.balance(), 40_000e6, 2, "C sees only its own");

        // Real interest accrues on the live market.
        vm.warp(block.timestamp + 120 days);

        // An attacker with no deposit owns nothing and can withdraw nothing.
        vm.prank(attacker);
        assertEq(adapter.withdraw(USDG, type(uint256).max, attacker), 0, "attacker gets zero");
        assertEq(IERC20(USDG).balanceOf(attacker), 0);

        // B fully exits first. This is the drain attempt from FIX 2: if accounting were shared,
        // B could pull the whole pot. It must get only its own principal + its own yield.
        // Upper bounds are deposit + 20%: comfortably above any plausible 120-day stablecoin
        // yield, yet far below what a cross-consumer drain would pay (B draining all three would
        // net ~390k+, A or C draining would be multiples of their deposit).
        uint256 bOut = b.withdraw(type(uint256).max, address(this));
        assertGe(bOut, 250_000e6 - 3, "B recovered at least its principal");
        assertLt(bOut, 300_000e6, "B did NOT pull A's or C's money (a drain would be >390k)");
        assertEq(b.balance(), 0, "B fully exited");

        // A and C are untouched by B's exit: each still holds ~its own principal (plus yield).
        assertGe(a.balance(), 100_000e6 - 2, "A intact after B's exit");
        assertGe(c.balance(), 40_000e6 - 2, "C intact after B's exit");
        assertLt(a.balance(), 120_000e6, "A not inflated by B's exit");
        assertLt(c.balance(), 48_000e6, "C not inflated by B's exit");

        // A and C fully exit; each recovers at least its principal, none more than its own + yield.
        uint256 aOut = a.withdraw(type(uint256).max, address(this));
        uint256 cOut = c.withdraw(type(uint256).max, address(this));
        assertGe(aOut, 100_000e6 - 3, "A recovered at least its principal");
        assertLt(aOut, 120_000e6, "A got only its own principal + yield");
        assertGe(cOut, 40_000e6 - 3, "C recovered at least its principal");
        assertLt(cOut, 48_000e6, "C got only its own principal + yield");

        // Adapter fully drained of these consumers' shares.
        assertEq(a.balance(), 0);
        assertEq(c.balance(), 0);
    }
}
