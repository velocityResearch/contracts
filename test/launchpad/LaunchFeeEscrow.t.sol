// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev A quote asset that keeps a slice of every transfer, which is the one behaviour the
///      escrow's balance-delta accounting exists to survive.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @title LaunchFeeEscrowTest
/// @notice The pull ledger every launchpad payout lands in. What matters is that a recipient
///         can only ever draw what was credited to them, that credits are measured by what
///         arrived, and that a claim can be sized to work around a token's own limits.
contract LaunchFeeEscrowTest is Test {
    LaunchFeeEscrow escrow;
    MockUSDC usdg;
    FeeOnTransferToken taxed;

    address creator = address(0xC12EA);
    address protocol = address(0xF33);
    address depositor = address(0xDE9);

    function setUp() public {
        escrow = new LaunchFeeEscrow();
        usdg = new MockUSDC();
        taxed = new FeeOnTransferToken();
    }

    function _credit(address who, address token, address recipient, uint256 amount) internal {
        vm.startPrank(who);
        ERC20(token).approve(address(escrow), amount);
        escrow.creditToken(recipient, token, amount);
        vm.stopPrank();
    }

    // ─── Credit ──────────────────────────────────────────────────────────

    function test_creditPullsFromTheCallerAndCreditsTheRecipient() public {
        usdg.mint(depositor, 1_000e6);
        _credit(depositor, address(usdg), creator, 400e6);

        assertEq(usdg.balanceOf(depositor), 600e6, "pulled from the caller");
        assertEq(usdg.balanceOf(address(escrow)), 400e6, "held by the escrow");
        assertEq(escrow.balanceOfToken(creator, address(usdg)), 400e6, "credited to recipient");
        assertEq(escrow.balanceOfToken(depositor, address(usdg)), 0, "not to the caller");
    }

    function test_creditIsPermissionlessAndAccumulatesAcrossDepositors() public {
        usdg.mint(depositor, 100e6);
        usdg.mint(protocol, 50e6);
        _credit(depositor, address(usdg), creator, 100e6);
        _credit(protocol, address(usdg), creator, 50e6);

        assertEq(escrow.balanceOfToken(creator, address(usdg)), 150e6);
    }

    function test_creditRecordsWhatArrivedNotWhatWasAsked() public {
        taxed.mint(depositor, 1_000e18);
        _credit(depositor, address(taxed), creator, 1_000e18);

        uint256 arrived = taxed.balanceOf(address(escrow));
        assertEq(arrived, 990e18, "the token kept 1%");
        assertEq(
            escrow.balanceOfToken(creator, address(taxed)),
            arrived,
            "liability equals what the escrow actually holds"
        );

        // The full credited balance is therefore always payable.
        vm.prank(creator);
        escrow.claimToken(address(taxed));
        assertEq(taxed.balanceOf(address(escrow)), 0);
    }

    function test_creditRejectsZeroRecipientAndZeroToken() public {
        vm.expectRevert(LaunchFeeEscrow.ZeroAddress.selector);
        escrow.creditToken(address(0), address(usdg), 1);
        vm.expectRevert(LaunchFeeEscrow.ZeroAddress.selector);
        escrow.creditToken(creator, address(0), 1);
    }

    function test_creditOfZeroIsANoOp() public {
        escrow.creditToken(creator, address(usdg), 0);
        assertEq(escrow.balanceOfToken(creator, address(usdg)), 0);
    }

    // ─── Claim ───────────────────────────────────────────────────────────

    function test_fullClaimPaysEverythingAndZeroesTheBalance() public {
        usdg.mint(depositor, 300e6);
        _credit(depositor, address(usdg), creator, 300e6);

        vm.prank(creator);
        uint256 paid = escrow.claimToken(address(usdg));

        assertEq(paid, 300e6);
        assertEq(usdg.balanceOf(creator), 300e6);
        assertEq(escrow.balanceOfToken(creator, address(usdg)), 0);
    }

    function test_partialClaimsDrawDownTheBalanceExactly() public {
        usdg.mint(depositor, 300e6);
        _credit(depositor, address(usdg), creator, 300e6);

        vm.startPrank(creator);
        escrow.claimToken(address(usdg), 100e6);
        assertEq(escrow.balanceOfToken(creator, address(usdg)), 200e6);
        escrow.claimToken(address(usdg), 200e6);
        assertEq(escrow.balanceOfToken(creator, address(usdg)), 0);
        vm.stopPrank();

        assertEq(usdg.balanceOf(creator), 300e6);
    }

    function test_claimCannotExceedTheCallersOwnBalance() public {
        usdg.mint(depositor, 300e6);
        _credit(depositor, address(usdg), creator, 200e6);
        _credit(depositor, address(usdg), protocol, 100e6);

        // The escrow holds 300 but the creator was only credited 200.
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFeeEscrow.InsufficientBalance.selector, 201e6, 200e6)
        );
        escrow.claimToken(address(usdg), 201e6);
    }

    function test_claimWithNothingCreditedReverts() public {
        vm.prank(creator);
        vm.expectRevert(LaunchFeeEscrow.NoBalance.selector);
        escrow.claimToken(address(usdg));

        vm.prank(creator);
        vm.expectRevert(LaunchFeeEscrow.NoBalance.selector);
        escrow.claimToken(address(usdg), 0);
    }

    function test_balancesAreKeyedPerTokenAndPerRecipient() public {
        usdg.mint(depositor, 100e6);
        taxed.mint(depositor, 100e18);
        _credit(depositor, address(usdg), creator, 100e6);
        _credit(depositor, address(taxed), protocol, 100e18);

        assertEq(escrow.balanceOfToken(creator, address(taxed)), 0);
        assertEq(escrow.balanceOfToken(protocol, address(usdg)), 0);

        vm.prank(creator);
        vm.expectRevert(LaunchFeeEscrow.NoBalance.selector);
        escrow.claimToken(address(taxed));
    }

    function testFuzz_sumOfClaimsNeverExceedsCredits(uint96 credited, uint96 first) public {
        credited = uint96(bound(credited, 1, type(uint96).max));
        first = uint96(bound(first, 1, credited));
        usdg.mint(depositor, credited);
        _credit(depositor, address(usdg), creator, credited);

        vm.startPrank(creator);
        escrow.claimToken(address(usdg), first);
        uint256 remaining = escrow.balanceOfToken(creator, address(usdg));
        assertEq(remaining, uint256(credited) - first);
        if (remaining != 0) escrow.claimToken(address(usdg));
        vm.stopPrank();

        assertEq(usdg.balanceOf(creator), credited);
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }
}
