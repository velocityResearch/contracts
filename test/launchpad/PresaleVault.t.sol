// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {PresaleVault} from "../../src/launchpad/PresaleVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev The asset the sale hands out. Eighteen decimals against a six-decimal quote, which is
///      the pairing the launchpad actually uses.
contract MockSaleToken is ERC20 {
    constructor() ERC20("Sale Token", "SALE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title PresaleVaultTest
/// @notice Money conservation, mostly. Every path is checked by adding up what went in and
///         what came out and insisting the vault is left holding exactly zero — the rounding
///         residue included, because a residue nobody can name is a residue somebody keeps.
contract PresaleVaultTest is Test {
    MockUSDC quote;
    MockSaleToken sale;
    PresaleVault vault;

    address owner = makeAddr("owner");
    address executor = makeAddr("executor");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    uint256 constant SOFT_CAP = 1_000e6;
    uint256 constant ALLOCATION_TARGET = 10_000e6;
    uint256 constant HARD_CAP = 30_000e6;
    uint256 constant PER_ACCOUNT_CAP = 20_000e6;
    uint256 constant SALE_TOKENS = 1_000_000e18;
    uint64 constant SETTLEMENT_WINDOW = 3 days;

    uint64 startAt;
    uint64 endAt;

    function setUp() public {
        vm.warp(1_700_000_000);
        quote = new MockUSDC();
        sale = new MockSaleToken();

        startAt = uint64(block.timestamp + 1 hours);
        endAt = uint64(block.timestamp + 1 days);
        vault = new PresaleVault(owner, _terms());
    }

    function _terms() internal view returns (PresaleVault.SaleTerms memory) {
        return PresaleVault.SaleTerms({
            quoteToken: address(quote),
            saleToken: address(sale),
            executor: executor,
            softCap: SOFT_CAP,
            allocationTarget: ALLOCATION_TARGET,
            hardCap: HARD_CAP,
            perAccountCap: PER_ACCOUNT_CAP,
            startAt: startAt,
            endAt: endAt,
            settlementWindow: SETTLEMENT_WINDOW,
            saleTokenAmount: SALE_TOKENS
        });
    }

    function _fund(uint256 amount) internal {
        sale.mint(executor, amount);
        vm.startPrank(executor);
        sale.approve(address(vault), amount);
        vault.fundSaleTokens(amount);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal {
        quote.mint(who, amount);
        vm.startPrank(who);
        quote.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _open() internal {
        vm.warp(startAt);
    }

    function _close() internal {
        vm.warp(endAt);
    }

    // ─── The ordinary sale ───────────────────────────────────────────────

    /// @notice A raise that lands exactly on its allocation target hands out exactly the
    ///         tokens that were funded, and leaves the vault empty on both sides.
    function test_settle_fullySubscribedDistributesExactlyTheFundedTokens() public {
        _fund(SALE_TOKENS);
        _open();
        _deposit(alice, 6_000e6);
        _deposit(bob, 4_000e6);
        _close();

        vm.prank(executor);
        vault.settle();

        assertEq(uint8(vault.phase()), uint8(PresaleVault.Phase.Settled), "settled");
        assertEq(vault.acceptedQuote(), ALLOCATION_TARGET, "the whole target was consumed");
        assertEq(vault.refundPool(), 0, "nothing to refund");
        assertEq(vault.tokensSold(), SALE_TOKENS, "and the whole allocation was sold");

        vm.prank(alice);
        (uint256 aliceTokens, uint256 aliceRefund) = vault.claim();
        vm.prank(bob);
        (uint256 bobTokens, uint256 bobRefund) = vault.claim();

        assertEq(aliceTokens, 600_000e18, "six tenths of the raise, six tenths of the tokens");
        assertEq(bobTokens, 400_000e18, "and four tenths of it");
        assertEq(aliceRefund + bobRefund, 0, "a sale at target refunds nothing");
        assertEq(aliceTokens + bobTokens, SALE_TOKENS, "exactly the funded tokens, to the wei");
        assertEq(sale.balanceOf(address(vault)), 0, "nothing left over");

        vm.prank(executor);
        assertEq(vault.withdrawProceeds(treasury), ALLOCATION_TARGET, "the proceeds");
        assertEq(quote.balanceOf(address(vault)), 0, "and the quote side is empty too");
    }

    // ─── Oversubscription ────────────────────────────────────────────────

    /// @notice Demand past the target is refunded pro-rata, and the flooring residue is
    ///         accounted rather than kept: every wei that entered the vault leaves it, to a
    ///         named party, and nothing is stranded.
    function test_settle_oversubscribedAllocatesProRataAndConservesEveryWei() public {
        _fund(SALE_TOKENS);
        _open();
        // Deliberately indivisible amounts, so the pro-rata split cannot come out even.
        uint256 aliceIn = 7_000_000_001;
        uint256 bobIn = 3_333_000_000;
        uint256 carolIn = 4_444_000_002;
        _deposit(alice, aliceIn);
        _deposit(bob, bobIn);
        _deposit(carol, carolIn);
        uint256 raised = aliceIn + bobIn + carolIn;
        assertEq(vault.totalContributed(), raised, "the raise as deposited");
        _close();

        vm.prank(executor);
        vault.settle();

        assertEq(vault.acceptedQuote(), ALLOCATION_TARGET, "only the target is bought");
        assertEq(vault.refundPool(), raised - ALLOCATION_TARGET, "the rest is owed back");
        assertEq(vault.tokensSold(), SALE_TOKENS, "the target was met, so all tokens sell");

        vm.prank(alice);
        (uint256 aliceTokens, uint256 aliceRefund) = vault.claim();
        vm.prank(bob);
        (uint256 bobTokens, uint256 bobRefund) = vault.claim();
        vm.prank(carol);
        (uint256 carolTokens, uint256 carolRefund) = vault.claim();

        // Fixed reference values for the pro-rata split: floor(c * pool / raised) on the
        // refund leg and floor(c * sold / raised) on the token leg.
        assertEq(aliceRefund, 2_262_908_575, "alice's unused contribution");
        assertEq(bobRefund, 1_077_467_754, "bob's");
        assertEq(carolRefund, 1_436_623_673, "carol's");
        assertEq(aliceTokens, 473_709_142_557_953_073_853_024, "alice's allocation");

        // The invariant the whole design exists for: allocation plus refund is the
        // contribution, exactly, for every account and therefore in aggregate.
        assertEq(quote.balanceOf(alice), aliceRefund, "alice was paid her refund");
        assertEq(quote.balanceOf(bob), bobRefund);
        assertEq(quote.balanceOf(carol), carolRefund);
        uint256 refunded = aliceRefund + bobRefund + carolRefund;
        uint256 accepted = (aliceIn - aliceRefund) + (bobIn - bobRefund) + (carolIn - carolRefund);
        assertEq(accepted + refunded, raised, "nothing created, nothing destroyed");

        // Flooring the refund leg is what keeps the vault solvent: refunds sum to at most the
        // pool, never past it.
        assertLe(refunded, vault.refundPool(), "refunds never exceed the pool");
        assertEq(vault.refundPool() - refunded, 1, "one wei of refund residue");
        assertLe(aliceTokens + bobTokens + carolTokens, SALE_TOKENS, "and tokens never exceed");
        assertEq(SALE_TOKENS - (aliceTokens + bobTokens + carolTokens), 2, "two wei of token dust");

        // Both residues are reachable only once every contributor is out, and then they go to
        // the executor rather than sitting in the vault forever.
        vm.startPrank(executor);
        assertEq(vault.withdrawProceeds(treasury), ALLOCATION_TARGET, "exactly the target");
        assertEq(vault.sweepResidualQuote(treasury), 1, "the quote residue");
        assertEq(vault.sweepSaleTokens(treasury), 2, "the token residue");
        vm.stopPrank();

        assertEq(quote.balanceOf(address(vault)), 0, "the vault keeps nothing");
        assertEq(sale.balanceOf(address(vault)), 0);
        assertEq(quote.balanceOf(treasury), ALLOCATION_TARGET + 1, "proceeds plus residue");
    }

    /// @notice The executor's reach stops at the accepted quote: before settlement it has
    ///         none, and after settlement the overflow pool is untouchable until the last
    ///         contributor has been paid.
    function test_withdrawProceeds_cannotReachTheRefundPool() public {
        _fund(SALE_TOKENS);
        _open();
        _deposit(alice, 12_000e6);
        _deposit(bob, 8_000e6);

        vm.prank(executor);
        vm.expectRevert(PresaleVault.NotSettled.selector);
        vault.withdrawProceeds(treasury);

        _close();
        vm.startPrank(executor);
        vault.settle();
        vault.withdrawProceeds(treasury);

        vm.expectRevert(PresaleVault.ProceedsAlreadyWithdrawn.selector);
        vault.withdrawProceeds(treasury);

        vm.expectRevert(
            abi.encodeWithSelector(PresaleVault.ClaimsOutstanding.selector, uint256(0), uint256(2))
        );
        vault.sweepResidualQuote(treasury);
        vm.stopPrank();

        assertEq(quote.balanceOf(treasury), ALLOCATION_TARGET, "only what the sale consumed");
        assertEq(
            quote.balanceOf(address(vault)), 20_000e6 - ALLOCATION_TARGET, "the pool is intact"
        );
    }

    // ─── Failure ─────────────────────────────────────────────────────────

    /// @notice A soft-cap miss is a full unwind: anyone can declare it, every contributor is
    ///         made whole, and no sale token is ever distributable.
    function test_fail_softCapMissRefundsEveryoneAndBlocksTokenClaims() public {
        _fund(SALE_TOKENS);
        _open();
        _deposit(alice, 400e6);
        _deposit(bob, 300e6);
        _close();

        // Permissionless: the deadline passed and the soft cap was missed, both public facts.
        vm.prank(stranger);
        vault.fail();
        assertEq(uint8(vault.phase()), uint8(PresaleVault.Phase.Failed), "failed");

        vm.prank(executor);
        vm.expectRevert(PresaleVault.SaleConcluded.selector);
        vault.settle();

        vm.prank(alice);
        vm.expectRevert(PresaleVault.NotSettled.selector);
        vault.claim();

        vm.prank(alice);
        assertEq(vault.claimRefund(), 400e6, "alice's money back, in full");
        vm.prank(bob);
        assertEq(vault.claimRefund(), 300e6, "and bob's");
        assertEq(quote.balanceOf(alice), 400e6);
        assertEq(quote.balanceOf(bob), 300e6);
        assertEq(quote.balanceOf(address(vault)), 0, "the refund pool is exhausted exactly");

        vm.prank(alice);
        vm.expectRevert(PresaleVault.AlreadyClaimed.selector);
        vault.claimRefund();

        // The failure pool was never the executor's, but the tokens it funded still are.
        vm.startPrank(executor);
        vm.expectRevert(PresaleVault.NotSettled.selector);
        vault.withdrawProceeds(treasury);
        vm.expectRevert(PresaleVault.NotSettled.selector);
        vault.sweepResidualQuote(treasury);
        assertEq(vault.sweepSaleTokens(treasury), SALE_TOKENS, "its own tokens back");
        vm.stopPrank();
    }

    /// @notice An executor that never settles cannot hold the raise hostage: once the
    ///         settlement window lapses, failure is permissionless even though the soft cap
    ///         was met.
    function test_fail_permissionlessOnceTheSettlementWindowLapses() public {
        _fund(SALE_TOKENS);
        _open();
        _deposit(alice, 5_000e6);
        _close();

        vm.expectRevert(
            abi.encodeWithSelector(PresaleVault.SoftCapMet.selector, uint256(5_000e6), SOFT_CAP)
        );
        vault.fail();

        vm.warp(uint256(endAt) + SETTLEMENT_WINDOW);
        vm.prank(stranger);
        vault.fail();

        vm.prank(alice);
        assertEq(vault.claimRefund(), 5_000e6, "paid back in full despite the soft cap");
    }

    // ─── Guards ──────────────────────────────────────────────────────────

    function test_claim_revertsOnTheSecondClaim() public {
        _fund(SALE_TOKENS);
        _open();
        _deposit(alice, 10_000e6);
        _close();
        vm.prank(executor);
        vault.settle();

        vm.startPrank(alice);
        vault.claim();
        vm.expectRevert(PresaleVault.AlreadyClaimed.selector);
        vault.claim();
        vm.stopPrank();
    }

    /// @notice Settlement is a promise the vault must already be able to keep: underfunded,
    ///         it refuses rather than leaving the last claimants short.
    function test_settle_revertsWhenSaleTokensAreNotFunded() public {
        _open();
        _deposit(alice, 10_000e6);
        _close();

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                PresaleVault.SaleTokensNotFunded.selector, SALE_TOKENS, uint256(0)
            )
        );
        vault.settle();

        // Short by a single wei is still short.
        _fund(SALE_TOKENS - 1);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                PresaleVault.SaleTokensNotFunded.selector, SALE_TOKENS, SALE_TOKENS - 1
            )
        );
        vault.settle();

        _fund(1);
        vm.prank(executor);
        vault.settle();
        assertEq(vault.tokensSold(), SALE_TOKENS, "funded, so settleable");
    }

    function test_deposit_revertsOutsideTheWindow() public {
        quote.mint(alice, 2_000e6);
        vm.startPrank(alice);
        quote.approve(address(vault), type(uint256).max);

        vm.expectRevert(PresaleVault.SaleNotOpen.selector);
        vault.deposit(1_000e6);

        vm.warp(startAt);
        vault.deposit(1_000e6);

        vm.warp(endAt);
        vm.expectRevert(PresaleVault.SaleNotOpen.selector);
        vault.deposit(1_000e6);
        vm.stopPrank();

        assertEq(vault.totalContributed(), 1_000e6, "only the in-window deposit stuck");
    }

    function test_deposit_respectsBothCaps() public {
        _open();
        _deposit(alice, PER_ACCOUNT_CAP);

        quote.mint(alice, 1);
        vm.startPrank(alice);
        quote.approve(address(vault), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PresaleVault.AccountCapExceeded.selector, PER_ACCOUNT_CAP + 1, PER_ACCOUNT_CAP
            )
        );
        vault.deposit(1);
        vm.stopPrank();

        // The hard cap binds across accounts, and filling it closes the window early.
        _deposit(bob, HARD_CAP - PER_ACCOUNT_CAP);
        assertEq(uint8(vault.phase()), uint8(PresaleVault.Phase.Closed), "hard cap closes it");

        quote.mint(carol, 1);
        vm.startPrank(carol);
        quote.approve(address(vault), 1);
        vm.expectRevert(PresaleVault.SaleNotOpen.selector);
        vault.deposit(1);
        vm.stopPrank();
    }

    /// @notice Terms are the owner's up to the second the window opens, and nobody's after.
    function test_configure_isFrozenOnceTheSaleOpens() public {
        PresaleVault.SaleTerms memory t = _terms();
        t.softCap = 2_000e6;
        vm.prank(owner);
        vault.configure(t);
        (,,, uint256 softCap,,,,,,,) = vault.terms();
        assertEq(softCap, 2_000e6, "retuned before it opened");

        _open();
        vm.prank(owner);
        vm.expectRevert(PresaleVault.SaleNotConfigurable.selector);
        vault.configure(t);
    }
}
