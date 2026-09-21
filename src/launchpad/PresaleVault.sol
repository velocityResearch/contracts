// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @title PresaleVault
/// @notice A standalone, fixed-price presale escrow for one launch: contributors deposit the
///         quote asset during an open window, and either the raise settles and they pull their
///         tokens, or it fails and they pull their money back. Nothing in between, and nothing
///         the operator can do about it once the window opens.
///
///         **Two ceilings, not one.** `hardCap` is the most quote the vault will ever hold;
///         `allocationTarget` is the quote the sale actually consumes at its fixed price of
///         `saleTokenAmount / allocationTarget`. Setting them equal makes an ordinary capped
///         sale that can never oversubscribe. Setting `hardCap` above `allocationTarget` makes
///         an overflow sale: everything above the target is pro-rata refunded rather than
///         sold, so the price a contributor was quoted is the price they get, whatever the
///         demand turns out to be.
///
///         **The rounding is on the refund side on purpose.** A contributor's refund is
///         `floor(contribution * refundPool / totalContributed)` and their accepted quote is
///         the exact remainder `contribution - refund`. Flooring the refund makes the refunds
///         sum to *at most* the refund pool, so the vault is always solvent for the next
///         claimant; flooring the acceptance instead would make them sum to at least the pool
///         and leave the last claimant short by the dust. What the flooring leaves behind is
///         tracked in `trackedQuote` and only reachable by the executor once every contributor
///         has claimed — it is accounted, never silently kept.
///
///         **Token shares are taken against gross contribution**, not against accepted quote:
///         `floor(contribution * tokensSold / totalContributed)`. Two chained floors (accept,
///         then price) could sum above `tokensSold`, because accepted quote rounds *up* in
///         aggregate. One floor against the same denominator every contributor shares cannot.
///
///         **The executor is not a custodian.** It can fund sale tokens and, after a
///         successful settlement, take exactly `acceptedQuote`. It can never touch the refund
///         pool, it can never take anything at all from a failed raise, and if it never
///         settles, `fail()` becomes permissionless once the settlement window lapses and
///         every contributor is made whole.
contract PresaleVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Configured before `startAt`, Open during the window, Closed once the window ends or
    /// the hard cap fills, then terminally Settled or Failed.
    enum Phase {
        Configured,
        Open,
        Closed,
        Settled,
        Failed
    }

    /// Everything about this sale that a contributor is entitled to rely on. Frozen the
    /// moment the window opens.
    struct SaleTerms {
        // Asset contributors deposit and are refunded in.
        address quoteToken;
        // Asset distributed on a successful settlement.
        address saleToken;
        // The only address that may fund, settle and take proceeds.
        address executor;
        // Minimum total contributions for the raise to be settleable.
        uint256 softCap;
        // Quote actually consumed by the sale: the denominator of the sale's fixed price.
        uint256 allocationTarget;
        // Maximum total contributions the vault will accept.
        uint256 hardCap;
        // Maximum a single account may contribute in total.
        uint256 perAccountCap;
        // First second deposits are accepted.
        uint64 startAt;
        // First second deposits are refused.
        uint64 endAt;
        // Seconds after `endAt` the executor has to settle a successful raise. Once it
        // lapses, `fail()` is permissionless and every contributor is refunded in full:
        // contributor money is never hostage to an executor that went away.
        uint64 settlementWindow;
        // Sale tokens distributed when the allocation target is fully raised. A short raise
        // sells proportionally fewer at the same price; the rest is the executor's to sweep.
        uint256 saleTokenAmount;
    }

    /// @notice The frozen-at-open terms of this sale.
    SaleTerms public terms;

    /// @notice Quote each account has deposited, measured on arrival.
    mapping(address account => uint256 amount) public contributionOf;
    /// @notice Whether an account has taken its settlement or its refund. Once, either way.
    mapping(address account => bool done) public claimed;

    /// @notice Sum of every contribution. Never above `terms.hardCap`.
    uint256 public totalContributed;
    /// @notice Accounts with a non-zero contribution, and how many of them have claimed. The
    ///         pair is what makes "everyone is out" an on-chain fact rather than a guess, and
    ///         it is the gate on sweeping the rounding residue.
    uint256 public contributorCount;
    uint256 public claimedCount;

    /// @notice Quote this vault is accountable for: deposits in, payouts out. Tracked rather
    ///         than read from `balanceOf` so a donation or a forced transfer can neither
    ///         inflate the refund pool nor be mistaken for a contribution.
    uint256 public trackedQuote;
    /// @notice Sale tokens funded into the vault, measured on arrival for the same reason.
    uint256 public trackedSaleTokens;

    /// @notice Set at settlement: the quote the sale consumed, the quote owed back to
    ///         contributors as oversubscription overflow, and the tokens the sale sold.
    uint256 public acceptedQuote;
    uint256 public refundPool;
    uint256 public tokensSold;
    /// @notice Settled allocations not yet claimed. Falls to the flooring residue, which the
    ///         executor may sweep only after the last contributor has claimed.
    uint256 public tokensUnclaimed;

    /// @notice Terminal timestamps. Exactly one of these can ever be non-zero.
    uint256 public settledAt;
    uint256 public failedAt;
    bool public proceedsWithdrawn;

    event SaleConfigured(SaleTerms saleTerms);
    event SaleTokensFunded(address indexed from, uint256 amount);
    event Deposited(address indexed account, uint256 amount, uint256 totalContribution);
    event SaleSettled(uint256 quoteAccepted, uint256 quoteRefundable, uint256 tokensDistributed);
    event SaleFailed(uint256 raised, bool settlementLapsed);
    event Claimed(address indexed account, uint256 tokensOut, uint256 refundOut);
    event Refunded(address indexed account, uint256 amount);
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    event ResidualQuoteSwept(address indexed to, uint256 amount);
    event SaleTokensSwept(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTerms();
    error NotExecutor();
    error SaleNotConfigurable();
    error SaleNotOpen();
    error SaleNotClosed();
    error SaleConcluded();
    error NotSettled();
    error NotFailed();
    error SoftCapNotMet(uint256 raised, uint256 softCap);
    error SoftCapMet(uint256 raised, uint256 softCap);
    error HardCapExceeded(uint256 attempted, uint256 hardCap);
    error AccountCapExceeded(uint256 attempted, uint256 perAccountCap);
    error SaleTokensNotFunded(uint256 required, uint256 funded);
    error NothingToClaim();
    error AlreadyClaimed();
    error ProceedsAlreadyWithdrawn();
    error ProceedsNotWithdrawn();
    error ClaimsOutstanding(uint256 claimedSoFar, uint256 contributors);
    error OwnershipCannotBeRenounced();

    modifier onlyExecutor() {
        if (msg.sender != terms.executor) revert NotExecutor();
        _;
    }

    /// @param initialOwner Can re-configure the sale, but only before it opens.
    /// @param terms_       Opening terms, validated here exactly as a re-configuration is.
    constructor(address initialOwner, SaleTerms memory terms_) Ownable(initialOwner) {
        _configure(terms_);
    }

    // ─── Configuration ───────────────────────────────────────────────────

    /// @notice Replace the sale's terms wholesale. Only while the sale is still in
    ///         `Configured`: from the first second of the window, the terms a contributor
    ///         deposited against are the terms that settle them.
    function configure(SaleTerms calldata terms_) external onlyOwner {
        if (phase() != Phase.Configured) revert SaleNotConfigurable();
        _configure(terms_);
    }

    function _configure(SaleTerms memory terms_) private {
        if (
            terms_.quoteToken == address(0) || terms_.saleToken == address(0)
                || terms_.executor == address(0)
        ) {
            revert ZeroAddress();
        }
        // The two ledgers are kept apart by construction; one token playing both roles would
        // let a refund be paid out of the sale allocation.
        if (terms_.quoteToken == terms_.saleToken) revert InvalidTerms();
        if (terms_.softCap == 0 || terms_.saleTokenAmount == 0) revert ZeroAmount();
        if (terms_.softCap > terms_.allocationTarget) revert InvalidTerms();
        if (terms_.allocationTarget > terms_.hardCap) revert InvalidTerms();
        if (terms_.perAccountCap == 0 || terms_.perAccountCap > terms_.hardCap) {
            revert InvalidTerms();
        }
        if (terms_.startAt < block.timestamp || terms_.endAt <= terms_.startAt) {
            revert InvalidTerms();
        }
        if (terms_.settlementWindow == 0) revert InvalidTerms();

        terms = terms_;
        emit SaleConfigured(terms_);
    }

    /// @notice Permanently disabled: ownership is the only way to fix terms before the window
    ///         opens, and an ownerless mis-configured vault could never be corrected.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ─── Funding ─────────────────────────────────────────────────────────

    /// @notice Move sale tokens into the vault ahead of settlement. Measured on arrival, so a
    ///         fee-on-transfer token credits what actually landed and settlement is checked
    ///         against tokens the vault really holds.
    function fundSaleTokens(uint256 amount) external nonReentrant onlyExecutor {
        if (amount == 0) revert ZeroAmount();
        if (settledAt != 0 || failedAt != 0) revert SaleConcluded();

        IERC20 saleToken = IERC20(terms.saleToken);
        uint256 before = saleToken.balanceOf(address(this));
        saleToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = saleToken.balanceOf(address(this)) - before;

        trackedSaleTokens += received;
        emit SaleTokensFunded(msg.sender, received);
    }

    // ─── Contributing ────────────────────────────────────────────────────

    /// @notice Deposit quote during the open window. Caps are enforced on the amount that
    ///         actually arrived, and an over-cap deposit reverts rather than partially filling:
    ///         a contributor should never be surprised by how much of their transfer stuck.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (phase() != Phase.Open) revert SaleNotOpen();

        IERC20 quoteToken = IERC20(terms.quoteToken);
        uint256 before = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = quoteToken.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        uint256 nextContribution = contributionOf[msg.sender] + received;
        if (nextContribution > terms.perAccountCap) {
            revert AccountCapExceeded(nextContribution, terms.perAccountCap);
        }
        uint256 nextTotal = totalContributed + received;
        if (nextTotal > terms.hardCap) revert HardCapExceeded(nextTotal, terms.hardCap);

        if (contributionOf[msg.sender] == 0) ++contributorCount;
        contributionOf[msg.sender] = nextContribution;
        totalContributed = nextTotal;
        trackedQuote += received;

        emit Deposited(msg.sender, received, nextContribution);
    }

    // ─── Conclusion ──────────────────────────────────────────────────────

    /// @notice Close the raise successfully. Once only, and only against tokens already in the
    ///         vault: a settlement that promises more than was funded reverts instead of
    ///         leaving the last claimants to discover the shortfall.
    function settle() external onlyExecutor {
        if (settledAt != 0 || failedAt != 0) revert SaleConcluded();
        if (phase() != Phase.Closed) revert SaleNotClosed();

        uint256 raised = totalContributed;
        if (raised < terms.softCap) revert SoftCapNotMet(raised, terms.softCap);

        uint256 accepted = Math.min(raised, terms.allocationTarget);
        uint256 sold = Math.mulDiv(accepted, terms.saleTokenAmount, terms.allocationTarget);
        if (sold > trackedSaleTokens) revert SaleTokensNotFunded(sold, trackedSaleTokens);

        acceptedQuote = accepted;
        refundPool = raised - accepted;
        tokensSold = sold;
        tokensUnclaimed = sold;
        settledAt = block.timestamp;

        emit SaleSettled(accepted, raised - accepted, sold);
    }

    /// @notice Fail the raise. Permissionless, because the two reasons a raise fails are both
    ///         facts anyone can read: the soft cap was missed by the deadline, or the executor
    ///         let the settlement window lapse without settling.
    function fail() external {
        if (settledAt != 0 || failedAt != 0) revert SaleConcluded();
        if (block.timestamp < terms.endAt) revert SaleNotClosed();

        uint256 raised = totalContributed;
        bool settlementLapsed =
            block.timestamp >= uint256(terms.endAt) + uint256(terms.settlementWindow);
        if (raised >= terms.softCap && !settlementLapsed) {
            revert SoftCapMet(raised, terms.softCap);
        }

        failedAt = block.timestamp;
        emit SaleFailed(raised, settlementLapsed);
    }

    // ─── Claiming ────────────────────────────────────────────────────────

    /// @notice Pull a settled allocation and, on an oversubscribed raise, the unused part of
    ///         the contribution. Both legs at once, because they are one accounting step:
    ///         `refund + acceptedPortion == contribution`, exactly.
    function claim() external nonReentrant returns (uint256 tokensOut, uint256 refundOut) {
        if (settledAt == 0) revert NotSettled();

        uint256 contribution = contributionOf[msg.sender];
        if (contribution == 0) revert NothingToClaim();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        (tokensOut, refundOut) = previewClaim(msg.sender);

        claimed[msg.sender] = true;
        ++claimedCount;
        tokensUnclaimed -= tokensOut;
        trackedSaleTokens -= tokensOut;
        trackedQuote -= refundOut;

        if (tokensOut != 0) IERC20(terms.saleToken).safeTransfer(msg.sender, tokensOut);
        if (refundOut != 0) IERC20(terms.quoteToken).safeTransfer(msg.sender, refundOut);

        emit Claimed(msg.sender, tokensOut, refundOut);
    }

    /// @notice Pull the whole contribution back from a failed raise. No sale token ever moves
    ///         on this path.
    function claimRefund() external nonReentrant returns (uint256 amount) {
        if (failedAt == 0) revert NotFailed();

        amount = contributionOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        claimed[msg.sender] = true;
        ++claimedCount;
        trackedQuote -= amount;

        IERC20(terms.quoteToken).safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    // ─── Executor withdrawals ────────────────────────────────────────────

    /// @notice Take the quote the sale actually consumed. Available only after a successful
    ///         settlement, once, and never a wei of the overflow refund pool.
    function withdrawProceeds(address to) external nonReentrant onlyExecutor returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        if (settledAt == 0) revert NotSettled();
        if (proceedsWithdrawn) revert ProceedsAlreadyWithdrawn();

        uint256 amount = acceptedQuote;
        proceedsWithdrawn = true;
        trackedQuote -= amount;

        IERC20(terms.quoteToken).safeTransfer(to, amount);
        emit ProceedsWithdrawn(to, amount);
        return amount;
    }

    /// @notice Sweep what the refund flooring left behind. Gated on every contributor having
    ///         claimed, so the residue is provably nobody's: until then the dust is
    ///         indistinguishable from an unclaimed refund.
    function sweepResidualQuote(address to) external nonReentrant onlyExecutor returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        if (settledAt == 0) revert NotSettled();
        if (!proceedsWithdrawn) revert ProceedsNotWithdrawn();
        if (claimedCount != contributorCount) {
            revert ClaimsOutstanding(claimedCount, contributorCount);
        }

        uint256 amount = trackedQuote;
        if (amount == 0) revert ZeroAmount();
        trackedQuote = 0;

        IERC20(terms.quoteToken).safeTransfer(to, amount);
        emit ResidualQuoteSwept(to, amount);
        return amount;
    }

    /// @notice Sweep sale tokens the sale did not sell: everything on a failed raise, and on a
    ///         settled one whatever was funded above `tokensSold` — plus, once every
    ///         contributor has claimed, the allocation flooring residue.
    function sweepSaleTokens(address to) external nonReentrant onlyExecutor returns (uint256) {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount;
        if (failedAt != 0) {
            amount = trackedSaleTokens;
        } else if (settledAt != 0) {
            amount = trackedSaleTokens - tokensUnclaimed;
            if (claimedCount == contributorCount) {
                amount = trackedSaleTokens;
                tokensUnclaimed = 0;
            }
        } else {
            revert NotSettled();
        }
        if (amount == 0) revert ZeroAmount();
        trackedSaleTokens -= amount;

        IERC20(terms.saleToken).safeTransfer(to, amount);
        emit SaleTokensSwept(to, amount);
        return amount;
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Where the sale stands right now. Timestamps decide everything up to the close;
    ///         only `settle()` and `fail()` decide what happens after it.
    function phase() public view returns (Phase) {
        if (settledAt != 0) return Phase.Settled;
        if (failedAt != 0) return Phase.Failed;
        if (block.timestamp < terms.startAt) return Phase.Configured;
        if (block.timestamp < terms.endAt && totalContributed < terms.hardCap) return Phase.Open;
        return Phase.Closed;
    }

    /// @notice What `claim()` would pay `account` right now. Zero for both legs before
    ///         settlement and after the account has claimed.
    function previewClaim(address account)
        public
        view
        returns (uint256 tokensOut, uint256 refundOut)
    {
        if (settledAt == 0 || claimed[account]) return (0, 0);

        uint256 contribution = contributionOf[account];
        if (contribution == 0) return (0, 0);

        uint256 raised = totalContributed;
        tokensOut = Math.mulDiv(contribution, tokensSold, raised);
        if (refundPool != 0) refundOut = Math.mulDiv(contribution, refundPool, raised);
    }

    /// @notice Quote `account` gets back from a failed raise: their contribution, in full.
    function previewRefund(address account) external view returns (uint256) {
        if (failedAt == 0 || claimed[account]) return 0;
        return contributionOf[account];
    }
}
