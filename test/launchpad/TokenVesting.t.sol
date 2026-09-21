// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {TokenVesting} from "../../src/launchpad/TokenVesting.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title TokenVestingTest
/// @notice The escrow protected allocations sit in. What matters is that nothing releases before
///         the cliff, that the linear release is exact integer math whose last claim carries the
///         whole rounding remainder, that a schedule can never promise more than the escrow
///         holds, and that a revocation reaches the unvested part and nothing else.
contract TokenVestingTest is Test {
    TokenVesting vesting;
    MockUSDC token;

    address owner = address(0x0117E2);
    address funder = address(0xF0DE2);
    address beneficiary = address(0xBEEF);
    address stranger = address(0x57A);

    uint64 constant START = 1_700_000_000;
    uint64 constant CLIFF = START + 100;
    uint64 constant DURATION = 1000;
    /// @dev Deliberately coprime with every sample point below, so each partial release floors
    ///      and the remainder only comes out at the end.
    uint256 constant TOTAL = 999;

    function setUp() public {
        vm.warp(START);
        vesting = new TokenVesting(owner);
        token = new MockUSDC();
    }

    function _fund(uint256 amount) internal {
        token.mint(funder, amount);
        vm.startPrank(funder);
        token.approve(address(vesting), amount);
        vesting.fund(address(token), amount);
        vm.stopPrank();
    }

    function _create(uint256 total, bool revocable) internal returns (uint256 id) {
        vm.prank(owner);
        id = vesting.createSchedule(
            beneficiary, address(token), total, START, CLIFF, DURATION, revocable
        );
    }

    function _fundAndCreate(uint256 total, bool revocable) internal returns (uint256 id) {
        _fund(total);
        id = _create(total, revocable);
    }

    // ─── Cliff ───────────────────────────────────────────────────────────

    function test_nothingIsClaimableBeforeTheCliff() public {
        uint256 id = _fundAndCreate(TOTAL, false);

        vm.warp(CLIFF - 1);
        assertEq(vesting.vestedAmount(id), 0, "nothing vested a second before the cliff");
        assertEq(vesting.releasableAmount(id), 0, "nothing releasable either");

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NothingToClaim.selector, id));
        vesting.claim(id);
        assertEq(token.balanceOf(beneficiary), 0, "no tokens left the escrow");

        // The cliff unlocks the accrual since `start` in one step, not the whole schedule.
        vm.warp(CLIFF);
        assertEq(vesting.vestedAmount(id), 99, "999 * 100 / 1000, floored");
    }

    // ─── Linear release ──────────────────────────────────────────────────

    function test_midwayClaimReleasesTheExactFlooredAmount() public {
        uint256 id = _fundAndCreate(TOTAL, false);

        vm.warp(START + 500);
        assertEq(vesting.releasableAmount(id), 499, "999 * 500 / 1000 floors to 499");

        vm.prank(beneficiary);
        uint256 claimed = vesting.claim(id);

        assertEq(claimed, 499, "paid the floored figure, never ahead of the curve");
        assertEq(token.balanceOf(beneficiary), 499, "and it arrived");
        assertEq(vesting.getSchedule(id).released, 499, "booked against the schedule");
        assertEq(vesting.committedBalance(address(token)), TOTAL - 499, "committed drops with it");
        assertEq(vesting.fundedBalance(address(token)), TOTAL - 499, "so does funded");
        assertEq(vesting.unallocatedBalance(address(token)), 0, "nothing freed for the owner");
    }

    function test_finalClaimReleasesTheExactRemainder() public {
        uint256 id = _fundAndCreate(TOTAL, false);

        vm.warp(START + 500);
        vm.prank(beneficiary);
        uint256 first = vesting.claim(id);

        vm.warp(START + 999);
        vm.prank(beneficiary);
        uint256 second = vesting.claim(id);
        assertEq(first + second, 998, "999 * 999 / 1000 floors to 998 in total");

        vm.warp(START + uint256(DURATION));
        assertEq(vesting.vestedAmount(id), TOTAL, "fully vested at the end, not the sum of floors");

        vm.prank(beneficiary);
        uint256 last = vesting.claim(id);

        assertEq(last, 1, "the last claim carries the accumulated rounding remainder");
        assertEq(first + second + last, TOTAL, "every unit reaches the beneficiary");
        assertEq(token.balanceOf(beneficiary), TOTAL, "and none is stranded in the escrow");
        assertEq(token.balanceOf(address(vesting)), 0, "escrow is empty");
        assertEq(vesting.committedBalance(address(token)), 0, "nothing left committed");
        assertEq(vesting.fundedBalance(address(token)), 0, "nothing left funded");
    }

    function test_aSecondClaimOfTheSameVestedAmountRevertsAndMovesNothing() public {
        uint256 id = _fundAndCreate(TOTAL, false);

        vm.warp(START + 500);
        vm.prank(beneficiary);
        vesting.claim(id);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NothingToClaim.selector, id));
        vesting.claim(id);

        assertEq(token.balanceOf(beneficiary), 499, "the balance did not move");
        assertEq(vesting.getSchedule(id).released, 499, "nor did the ledger");
    }

    function test_onlyTheBeneficiaryCanClaim() public {
        uint256 id = _fundAndCreate(TOTAL, false);
        vm.warp(START + 500);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotBeneficiary.selector, id));
        vesting.claim(id);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotBeneficiary.selector, id));
        vesting.claim(id);
    }

    // ─── Funding discipline ──────────────────────────────────────────────

    function test_aScheduleBeyondTheFundedBalanceReverts() public {
        _fund(1000);
        _create(600, false);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenVesting.InsufficientUnallocated.selector, address(token), 500, 400
            )
        );
        vesting.createSchedule(beneficiary, address(token), 500, START, CLIFF, DURATION, false);

        // An unfunded token cannot be promised at all.
        MockUSDC other = new MockUSDC();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenVesting.InsufficientUnallocated.selector, address(other), 1, 0
            )
        );
        vesting.createSchedule(beneficiary, address(other), 1, START, CLIFF, DURATION, false);

        // What is left over is the owner's, and only what is left over.
        assertEq(vesting.unallocatedBalance(address(token)), 400, "400 uncommitted");
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenVesting.InsufficientUnallocated.selector, address(token), 401, 400
            )
        );
        vesting.withdrawUnallocated(address(token), owner, 401);

        vm.prank(owner);
        vesting.withdrawUnallocated(address(token), owner, 400);
        assertEq(token.balanceOf(owner), 400, "the owner took the slack");
        assertEq(token.balanceOf(address(vesting)), 600, "the promise stays backed");
    }

    // ─── Revocation ──────────────────────────────────────────────────────

    function test_revocationReturnsOnlyTheUnvestedPortion() public {
        uint256 id = _fundAndCreate(TOTAL, true);
        uint256 untouched = _fundAndCreate(500, false);

        vm.warp(START + 500);
        vm.prank(owner);
        uint256 returned = vesting.revoke(id);

        assertEq(returned, TOTAL - 499, "only the unvested remainder went back");
        assertEq(token.balanceOf(owner), TOTAL - 499, "and it reached the owner");
        assertEq(vesting.releasableAmount(id), 499, "the vested part is still the beneficiary's");

        // Vesting is frozen: time no longer adds to it.
        vm.warp(START + uint256(DURATION) * 2);
        assertEq(vesting.vestedAmount(id), 499, "frozen at the revocation timestamp");

        vm.prank(beneficiary);
        assertEq(vesting.claim(id), 499, "and it is still claimable afterwards");
        assertEq(token.balanceOf(beneficiary), 499, "the vested part, nothing more");

        // The other schedule was never touched by any of it.
        assertEq(vesting.getSchedule(untouched).total, 500, "second schedule intact");
        vm.prank(beneficiary);
        assertEq(vesting.claim(untouched), 500, "it pays out in full");
        assertEq(token.balanceOf(beneficiary), 499 + 500, "both schedules settled");
        assertEq(vesting.committedBalance(address(token)), 0, "books settle to zero");
        assertEq(vesting.fundedBalance(address(token)), 0, "and so does the funding");
        assertEq(token.balanceOf(address(vesting)), 0, "escrow is empty");
    }

    function test_revocationIsOwnerOnlyAndOnlyOnRevocableSchedules() public {
        uint256 locked = _fundAndCreate(TOTAL, false);
        uint256 revocable = _fundAndCreate(TOTAL, true);
        vm.warp(START + 500);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotRevocable.selector, locked));
        vesting.revoke(locked);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vesting.revoke(revocable);

        vm.startPrank(owner);
        vesting.revoke(revocable);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.AlreadyRevoked.selector, revocable));
        vesting.revoke(revocable);
        vm.stopPrank();
    }

    // ─── Beneficiary handover ────────────────────────────────────────────

    function test_beneficiaryTransferTakesTwoSteps() public {
        uint256 id = _fundAndCreate(TOTAL, false);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotBeneficiary.selector, id));
        vesting.proposeBeneficiary(id, stranger);

        vm.prank(beneficiary);
        vesting.proposeBeneficiary(id, stranger);
        assertEq(vesting.getSchedule(id).beneficiary, beneficiary, "unchanged until accepted");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotProposedBeneficiary.selector, id));
        vesting.acceptBeneficiary(id);

        vm.prank(stranger);
        vesting.acceptBeneficiary(id);
        assertEq(vesting.getSchedule(id).beneficiary, stranger, "handed over");
        assertEq(vesting.pendingBeneficiary(id), address(0), "offer consumed");
        assertEq(vesting.schedulesOf(beneficiary).length, 0, "dropped from the old holder");
        assertEq(vesting.schedulesOf(stranger)[0], id, "and indexed under the new one");

        vm.warp(START + uint256(DURATION));
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NotBeneficiary.selector, id));
        vesting.claim(id);

        vm.prank(stranger);
        assertEq(vesting.claim(id), TOTAL, "the new beneficiary is paid the whole schedule");
    }

    // ─── Validation ──────────────────────────────────────────────────────

    function test_scheduleInputsAreValidated() public {
        _fund(TOTAL);

        vm.startPrank(owner);
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        vesting.createSchedule(address(0), address(token), 1, START, CLIFF, DURATION, false);
        vm.expectRevert(TokenVesting.ZeroAmount.selector);
        vesting.createSchedule(beneficiary, address(token), 0, START, CLIFF, DURATION, false);
        vm.expectRevert(TokenVesting.ZeroDuration.selector);
        vesting.createSchedule(beneficiary, address(token), 1, START, START, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenVesting.InvalidCliff.selector, START, START + DURATION + 1, DURATION
            )
        );
        vesting.createSchedule(
            beneficiary, address(token), 1, START, START + DURATION + 1, DURATION, false
        );
        vm.expectRevert(TokenVesting.OwnershipCannotBeRenounced.selector);
        vesting.renounceOwnership();
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(TokenVesting.UnknownSchedule.selector, 7));
        vesting.vestedAmount(7);
    }
}
