// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {IPrelaunchBuyer, PrelaunchVault} from "../../src/launchpad/PrelaunchVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev The asset the protected buy delivers. Minted by the venue mock at fill time, the way
///      a real launch hands tokens to whoever paid for them.
contract MintableToken is ERC20 {
    constructor() ERC20("Launch", "LAUNCH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A launch venue the test drives directly: it pulls exactly `spendAmount` of quote and
///      delivers exactly `mintAmount` of the launch token, regardless of what it was asked
///      for. Both legs are deliberately detachable from each other so the vault's own
///      balance-delta accounting — not the venue's honesty — is what the tests exercise.
contract MockPrelaunchBuyer is IPrelaunchBuyer {
    IERC20 public immutable quote;
    MintableToken public immutable token;

    uint256 public spendAmount;
    uint256 public mintAmount;
    uint256 public calls;

    constructor(IERC20 quote_, MintableToken token_) {
        quote = quote_;
        token = token_;
    }

    function setFill(uint256 spendAmount_, uint256 mintAmount_) external {
        spendAmount = spendAmount_;
        mintAmount = mintAmount_;
    }

    function buyForVault(uint256 quoteAmount, uint256, address recipient)
        external
        returns (uint256)
    {
        ++calls;
        uint256 spend = spendAmount > quoteAmount ? quoteAmount : spendAmount;
        if (spend != 0) quote.transferFrom(msg.sender, address(this), spend);
        if (mintAmount != 0) token.mint(recipient, mintAmount);
        return mintAmount;
    }
}

/// @title PrelaunchVaultTest
/// @notice What a cohort that pooled its money before a launch is owed. The three deposits
///         here are deliberately coprime with the fill, so every pro-rata leg has a real
///         floor remainder and the conservation assertions are load-bearing rather than
///         arithmetic coincidence.
contract PrelaunchVaultTest is Test {
    uint256 constant T0 = 1_700_000_000;
    uint64 constant DEPOSIT_START = uint64(T0 + 1 days);
    uint64 constant DEPOSIT_END = uint64(T0 + 4 days);
    uint64 constant EXPIRY = uint64(T0 + 6 days);
    uint64 constant CLIFF = uint64(1 days);
    uint64 constant VESTING = uint64(7 days);

    uint256 constant HARD_CAP = 10_000e6;
    uint256 constant ACCOUNT_CAP = 4_000e6;
    uint256 constant MIN_DEPOSIT = 100e6;

    uint256 constant ALICE_IN = 3_000e6;
    uint256 constant BOB_IN = 1_000e6;
    uint256 constant CAROL_IN = 333e6;
    uint256 constant TOTAL_IN = ALICE_IN + BOB_IN + CAROL_IN; // 4_333e6

    uint256 constant SPEND = 3_900e6;
    uint256 constant UNSPENT = TOTAL_IN - SPEND; // 433e6
    uint256 constant ACQUIRED = 7_777_777_777_777_777_777;

    // floor(ACQUIRED * deposit / TOTAL_IN), summing to ACQUIRED - 1.
    uint256 constant ALICE_TOKENS = 5_385_029_617_662_897_145;
    uint256 constant BOB_TOKENS = 1_795_009_872_554_299_048;
    uint256 constant CAROL_TOKENS = 597_738_287_560_581_583;
    uint256 constant TOKEN_DUST = 1;

    // floor(UNSPENT * deposit / TOTAL_IN), summing to UNSPENT - 2.
    uint256 constant ALICE_REFUND = 299_792_291;
    uint256 constant BOB_REFUND = 99_930_763;
    uint256 constant CAROL_REFUND = 33_276_944;
    uint256 constant QUOTE_DUST = 2;

    PrelaunchVault vault;
    MockUSDC quote;
    MintableToken token;
    MockPrelaunchBuyer venue;

    address owner = address(0x0F1);
    address executor = address(0xEEC);
    address dust = address(0xD057);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address dave = address(0xDA7E);
    address stranger = address(0x57A);

    function setUp() public {
        vm.warp(T0);
        quote = new MockUSDC();
        token = new MintableToken();
        vault = new PrelaunchVault(owner, IERC20(address(quote)), executor, dust, _terms());
        venue = new MockPrelaunchBuyer(IERC20(address(quote)), token);

        address[] memory cohort = new address[](4);
        cohort[0] = alice;
        cohort[1] = bob;
        cohort[2] = carol;
        cohort[3] = dave;

        vm.startPrank(owner);
        vault.setAllowlist(cohort, true);
        vault.setBuyTarget(venue, IERC20(address(token)));
        vm.stopPrank();

        venue.setFill(SPEND, ACQUIRED);
    }

    function _terms() internal pure returns (PrelaunchVault.VaultTerms memory) {
        return PrelaunchVault.VaultTerms({
            depositStart: DEPOSIT_START,
            depositEnd: DEPOSIT_END,
            expiry: EXPIRY,
            claimCliff: CLIFF,
            vestingDuration: VESTING,
            hardCap: HARD_CAP,
            perAccountCap: ACCOUNT_CAP,
            minDeposit: MIN_DEPOSIT,
            allowlistEnabled: true
        });
    }

    function _deposit(address who, uint256 amount) internal {
        quote.mint(who, amount);
        vm.startPrank(who);
        quote.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    /// @dev The cohort of record: three deposits inside the window, nothing executed yet.
    function _fundCohort() internal {
        vm.warp(DEPOSIT_START);
        _deposit(alice, ALICE_IN);
        _deposit(bob, BOB_IN);
        _deposit(carol, CAROL_IN);
    }

    function _fundAndExecute() internal {
        _fundCohort();
        vm.warp(DEPOSIT_END);
        vm.prank(executor);
        vault.execute(type(uint256).max, ACQUIRED);
    }

    // ─── Deposits ────────────────────────────────────────────────────────

    function test_deposit_enforcesWindowAllowlistAndCaps() public {
        quote.mint(alice, 20_000e6);
        vm.prank(alice);
        quote.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(PrelaunchVault.DepositsNotOpen.selector);
        vault.deposit(ALICE_IN);

        vm.warp(DEPOSIT_START);

        quote.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        quote.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PrelaunchVault.NotAllowlisted.selector, stranger));
        vault.deposit(1_000e6);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PrelaunchVault.BelowMinimum.selector, 50e6, MIN_DEPOSIT)
        );
        vault.deposit(50e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PrelaunchVault.AccountCapExceeded.selector, 4_500e6, ACCOUNT_CAP)
        );
        vault.deposit(4_500e6);

        vm.prank(alice);
        vault.deposit(ALICE_IN);
        _deposit(bob, BOB_IN);
        _deposit(carol, CAROL_IN);
        assertEq(vault.totalDeposited(), TOTAL_IN, "credited exactly what arrived");
        assertEq(vault.contributorCount(), 3, "three contributors, counted once each");

        // 6_000e6 would put the vault past its hard cap with 5_667e6 of room left.
        quote.mint(dave, 6_000e6);
        vm.startPrank(dave);
        quote.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrelaunchVault.HardCapExceeded.selector, 6_000e6, HARD_CAP - TOTAL_IN
            )
        );
        vault.deposit(6_000e6);
        vm.stopPrank();

        vm.warp(DEPOSIT_END);
        vm.prank(alice);
        vm.expectRevert(PrelaunchVault.DepositsClosed.selector);
        vault.deposit(100e6);
    }

    function test_terms_freezeWhenTheWindowOpens() public {
        PrelaunchVault.VaultTerms memory t = _terms();
        t.hardCap = 20_000e6;

        vm.prank(owner);
        vault.setTerms(t);
        (,,,,, uint256 hardCap,,,) = vault.terms();
        assertEq(hardCap, 20_000e6, "draft terms are writable before the window");

        vm.warp(DEPOSIT_START);

        vm.prank(owner);
        vm.expectRevert(PrelaunchVault.ParametersFrozen.selector);
        vault.setTerms(t);

        vm.prank(owner);
        vm.expectRevert(PrelaunchVault.ParametersFrozen.selector);
        vault.setExecutor(stranger);

        address[] memory late = new address[](1);
        late[0] = stranger;
        vm.prank(owner);
        vm.expectRevert(PrelaunchVault.ParametersFrozen.selector);
        vault.setAllowlist(late, true);
    }

    // ─── The buy ─────────────────────────────────────────────────────────

    function test_execute_isExecutorOnlyWindowGatedAndOneShot() public {
        _fundCohort();

        vm.prank(stranger);
        vm.expectRevert(PrelaunchVault.NotExecutor.selector);
        vault.execute(type(uint256).max, ACQUIRED);

        vm.prank(executor);
        vm.expectRevert(PrelaunchVault.DepositWindowOpen.selector);
        vault.execute(type(uint256).max, ACQUIRED);

        vm.warp(DEPOSIT_END);
        vm.prank(executor);
        vault.execute(type(uint256).max, ACQUIRED);
        assertEq(venue.calls(), 1, "the venue is called exactly once");

        venue.setFill(0, 1);
        vm.prank(executor);
        vm.expectRevert(PrelaunchVault.AlreadyExecuted.selector);
        vault.execute(type(uint256).max, 1);
        assertEq(venue.calls(), 1, "and never a second time");

        vm.warp(EXPIRY);
        assertEq(vault.tokensAcquired(), ACQUIRED, "the first fill stands");
    }

    function test_execute_belowMinimumRevertsAndLeavesDepositsIntact() public {
        _fundCohort();
        vm.warp(DEPOSIT_END);

        // The venue takes the money but under-delivers by a wei.
        venue.setFill(SPEND, ACQUIRED - 1);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrelaunchVault.InsufficientTokensAcquired.selector, ACQUIRED - 1, ACQUIRED
            )
        );
        vault.execute(type(uint256).max, ACQUIRED);

        assertFalse(vault.executed(), "no fill was recorded");
        assertEq(vault.totalDeposited(), TOTAL_IN, "the ledger is untouched");
        assertEq(quote.balanceOf(address(vault)), TOTAL_IN, "and so is the money");
        assertEq(quote.balanceOf(address(venue)), 0, "the venue kept nothing");
        assertEq(
            quote.allowance(address(vault), address(venue)), 0, "no approval survives the revert"
        );

        // The cohort is not stuck: a fill that clears the floor still works afterwards.
        venue.setFill(SPEND, ACQUIRED);
        vm.prank(executor);
        vault.execute(type(uint256).max, ACQUIRED);
        assertEq(vault.tokensAcquired(), ACQUIRED, "the good fill lands");
    }

    function test_execute_neverSpendsPastWhatTheCohortDeposited() public {
        _fundCohort();
        vm.warp(DEPOSIT_END);

        // A donation to the vault plus a venue greedy enough to take everything it is
        // offered: the ceiling is the cohort's deposits, so the donation cannot be spent.
        quote.mint(address(vault), 5_000e6);
        venue.setFill(type(uint256).max, ACQUIRED);

        vm.prank(executor);
        vault.execute(type(uint256).max, ACQUIRED);

        assertEq(vault.quoteSpent(), TOTAL_IN, "capped at the deposits, not the balance");
        assertEq(quote.balanceOf(address(venue)), TOTAL_IN, "the venue got no more than that");
        assertEq(vault.unspentQuote(), 0, "nothing left to refund");
    }

    // ─── Distribution ────────────────────────────────────────────────────

    function test_execute_distributesProRataWithTheRemainderAccountedFor() public {
        _fundAndExecute();

        assertEq(vault.quoteSpent(), SPEND, "spent what the venue pulled");
        assertEq(vault.tokensAcquired(), ACQUIRED, "acquired what it delivered");
        assertEq(vault.unspentQuote(), UNSPENT, "the change is owed back");

        // The dust is only knowable once every contributor's floored share is counted.
        vm.expectRevert(abi.encodeWithSelector(PrelaunchVault.NotFullyMaterialized.selector, 0, 3));
        vault.sweepDust();

        vm.warp(vault.unlockEnd());

        vm.prank(alice);
        assertEq(vault.claimTokens(), ALICE_TOKENS, "alice's whole share");
        vm.prank(bob);
        assertEq(vault.claimTokens(), BOB_TOKENS, "bob's whole share");

        vm.expectRevert(abi.encodeWithSelector(PrelaunchVault.NotFullyMaterialized.selector, 2, 3));
        vault.sweepDust();

        vm.prank(carol);
        assertEq(vault.claimTokens(), CAROL_TOKENS, "carol's whole share");

        // Anyone may push the refunds; they are paid to the contributor, not the caller.
        vm.startPrank(stranger);
        assertEq(vault.claimQuote(alice), ALICE_REFUND, "alice's change");
        assertEq(vault.claimQuote(bob), BOB_REFUND, "bob's change");
        assertEq(vault.claimQuote(carol), CAROL_REFUND, "carol's change");
        vm.stopPrank();
        assertEq(quote.balanceOf(alice), ALICE_REFUND, "paid to the contributor");
        assertEq(quote.balanceOf(stranger), 0, "never to whoever pushed the button");

        (uint256 tokenDust, uint256 quoteDust) = vault.sweepDust();
        assertEq(tokenDust, TOKEN_DUST, "the token remainder is one wei");
        assertEq(quoteDust, QUOTE_DUST, "the quote remainder is two");
        assertEq(token.balanceOf(dust), TOKEN_DUST, "and it is assigned, not lost");
        assertEq(quote.balanceOf(dust), QUOTE_DUST, "on both legs");

        assertEq(
            ALICE_TOKENS + BOB_TOKENS + CAROL_TOKENS + tokenDust,
            ACQUIRED,
            "claims plus dust are exactly what was bought"
        );
        assertEq(
            ALICE_REFUND + BOB_REFUND + CAROL_REFUND + quoteDust,
            UNSPENT,
            "and exactly what was not spent"
        );
        assertEq(token.balanceOf(address(vault)), 0, "the vault keeps no tokens");
        assertEq(quote.balanceOf(address(vault)), 0, "and no quote");

        vm.prank(alice);
        vm.expectRevert(PrelaunchVault.NothingToClaim.selector);
        vault.claimTokens();

        vm.expectRevert(PrelaunchVault.DustAlreadySwept.selector);
        vault.sweepDust();
    }

    function test_claim_isLockedUntilTheCliffThenVestsLinearly() public {
        _fundAndExecute();

        uint256 start = vault.unlockStart();
        assertEq(start, DEPOSIT_END + CLIFF, "the cliff runs from the buy");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PrelaunchVault.ClaimLocked.selector, start));
        vault.claimTokens();

        vm.warp(start - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PrelaunchVault.ClaimLocked.selector, start));
        vault.claimTokens();

        // Half way through the linear unlock, half the allocation and not a wei more.
        vm.warp(start + VESTING / 2);
        uint256 half = ALICE_TOKENS * (VESTING / 2) / VESTING;
        vm.prank(alice);
        assertEq(vault.claimTokens(), half, "half vested");
        assertEq(token.balanceOf(alice), half, "half delivered");

        vm.prank(alice);
        vm.expectRevert(PrelaunchVault.NothingToClaim.selector);
        vault.claimTokens();

        vm.warp(start + VESTING);
        vm.prank(alice);
        assertEq(vault.claimTokens(), ALICE_TOKENS - half, "the rest at the end");
        assertEq(token.balanceOf(alice), ALICE_TOKENS, "never more than the entitlement");

        // The unspent quote is not subject to the unlock: it was never the launch's money.
        assertEq(vault.claimableQuote(bob), BOB_REFUND, "change is claimable immediately");
    }

    // ─── Expiry ──────────────────────────────────────────────────────────

    function test_expiry_refundsEveryContributorInFullPermissionlessly() public {
        _fundCohort();
        vm.warp(DEPOSIT_END);

        vm.expectRevert(PrelaunchVault.RefundNotAvailable.selector);
        vault.claimQuote(alice);

        vm.warp(EXPIRY);

        // The executor is gone; nobody privileged is needed to unwind the vault.
        vm.startPrank(stranger);
        assertEq(vault.claimQuote(alice), ALICE_IN, "alice gets everything back");
        assertEq(vault.claimQuote(bob), BOB_IN, "bob too");
        assertEq(vault.claimQuote(carol), CAROL_IN, "and carol");
        vm.stopPrank();

        assertEq(quote.balanceOf(alice), ALICE_IN, "paid in full, no haircut");
        assertEq(quote.balanceOf(address(vault)), 0, "the vault is empty");

        vm.expectRevert(PrelaunchVault.NothingToClaim.selector);
        vault.claimQuote(alice);

        // And the window for a late fill is closed for good.
        vm.prank(executor);
        vm.expectRevert(PrelaunchVault.VaultExpired.selector);
        vault.execute(type(uint256).max, ACQUIRED);
    }

    // ─── Configuration ───────────────────────────────────────────────────

    function test_setBuyTarget_isWriteOnceAndOwnerOnly() public {
        MockPrelaunchBuyer other = new MockPrelaunchBuyer(IERC20(address(quote)), token);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vault.setBuyTarget(other, IERC20(address(token)));

        vm.prank(owner);
        vm.expectRevert(PrelaunchVault.BuyTargetAlreadySet.selector);
        vault.setBuyTarget(other, IERC20(address(token)));
    }

    function test_execute_revertsWhileTheBuyTargetIsUnset() public {
        PrelaunchVault bare =
            new PrelaunchVault(owner, IERC20(address(quote)), executor, dust, _terms());

        address[] memory cohort = new address[](1);
        cohort[0] = alice;
        vm.prank(owner);
        bare.setAllowlist(cohort, true);

        vm.warp(DEPOSIT_START);
        quote.mint(alice, ALICE_IN);
        vm.startPrank(alice);
        quote.approve(address(bare), ALICE_IN);
        bare.deposit(ALICE_IN);
        vm.stopPrank();

        vm.warp(DEPOSIT_END);
        vm.prank(executor);
        vm.expectRevert(PrelaunchVault.BuyTargetNotSet.selector);
        bare.execute(type(uint256).max, 1);
    }

    function test_openVault_skipsTheAllowlistEntirely() public {
        PrelaunchVault.VaultTerms memory t = _terms();
        t.allowlistEnabled = false;
        vm.prank(owner);
        vault.setTerms(t);

        vm.warp(DEPOSIT_START);
        quote.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        quote.approve(address(vault), 1_000e6);
        assertEq(vault.deposit(1_000e6), 1_000e6, "anyone can join an open vault");
        vm.stopPrank();
        assertEq(vault.deposits(stranger), 1_000e6, "credited like any contributor");
    }
}
