// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @notice The single call a `PrelaunchVault` makes into whatever venue opens the launch.
///         Modelled as an interface rather than a hard reference to `LaunchCurve` so the
///         same vault can front a curve, a pool router, or a test double, and so this
///         contract can be deployed and funded before the venue it will buy from exists.
/// @dev    The implementation is expected to pull `quoteAmount` from the caller with
///         `transferFrom`, so the vault approves exactly the amount for exactly the length
///         of the call. The return value is advisory: the vault prices the fill from its
///         own measured balance deltas, never from what the venue claims.
interface IPrelaunchBuyer {
    function buyForVault(uint256 quoteAmount, uint256 minTokensOut, address recipient)
        external
        returns (uint256 tokensOut);
}

/// @title PrelaunchVault
/// @notice Protected pre-launch buying for one launch: contributors deposit the quote asset
///         before the launch is tradeable, an authorised executor performs one buy on
///         everyone's behalf at the open, and contributors then claim their pro-rata slice
///         of what that single buy acquired.
///
///         **The point is that there is exactly one buy.** A launch's first block is the
///         block where a retail order is worth the least: it competes with every bot in the
///         mempool, and every one of those orders moves the price against the next. Pooling
///         the demand into a single executor-driven fill means the cohort pays one price
///         instead of a ladder of increasingly bad ones, and the executor can be given an
///         explicit ceiling on spend and floor on fill that no individual order could
///         enforce for the group. `execute` is therefore one-shot and irreversible: there is
///         no second attempt to average into, and nothing the owner can do afterwards.
///
///         **Every number the cohort is judged by is frozen before the money arrives.** Caps,
///         window, unlock schedule, expiry and the allowlist are all writable only while
///         `block.timestamp < terms.depositStart`; the first second of the deposit window
///         seals them. The one thing the owner may still set afterwards is the buy target
///         (`setBuyTarget`), because the venue this vault buys from generally does not exist
///         yet when deposits open — and even that is write-once, and is public before any
///         money moves through it.
///
///         **Conservation is tracked, not assumed.** `totalDeposited` is the sum of what
///         actually arrived (balance-delta measured, so a fee-on-transfer quote credits what
///         landed, not what was sent). The buy is bounded by that number, never by the live
///         balance, so a donation cannot be spent. Acquired tokens and unspent quote are
///         split by exact floor division of each contributor's deposit over the total; the
///         floor remainders — at most one wei per contributor per asset — are not left
///         stranded but swept to an explicit `dustRecipient` once every contributor's share
///         has been materialised. Sum of claims plus dust equals what was acquired, exactly.
///
///         **The cohort is never trapped.** If the executor has not bought by `terms.expiry`,
///         anyone may return any contributor's full deposit, and nothing about that path is
///         owner-gated or executor-gated.
///
///         Trust boundary, stated plainly: the owner picks the venue and the executor picks
///         the fill, so a hostile operator can buy a bad launch at a bad price. What they
///         cannot do is spend more than the cohort deposited, buy twice, keep the change,
///         change the terms after deposits open, hand the cohort an instant-dumpable
///         position, or keep the money if they never buy at all.
contract PrelaunchVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Ceiling on `claimCliff + vestingDuration`. An unlock schedule is anti-dump
    ///      protection for the launch, not a lockup product; two years is already far past
    ///      any honest use and rejecting more stops a fat-fingered constant from burying a
    ///      cohort's tokens for a century.
    uint256 private constant MAX_UNLOCK_WINDOW = 730 days;

    /// @notice Everything about this vault's economics, fixed before the first deposit.
    /// @param depositStart    First second deposits are accepted, and the second the terms
    ///                        below stop being writable.
    /// @param depositEnd      First second deposits are refused; also the earliest `execute`.
    /// @param expiry          First second an unexecuted vault is permissionlessly
    ///                        refundable, and the first second `execute` is refused.
    /// @param claimCliff      Seconds after the buy before any token claim unlocks.
    /// @param vestingDuration Seconds of linear unlock after the cliff; zero unlocks the
    ///                        whole allocation at the cliff.
    /// @param hardCap         Maximum total quote the vault will hold.
    /// @param perAccountCap   Maximum quote one account may deposit; zero means no per
    ///                        account limit.
    /// @param minDeposit      Minimum resulting balance for a depositing account; zero means
    ///                        no minimum. Also the lever that keeps the contributor set from
    ///                        being padded with dust accounts.
    /// @param allowlistEnabled Whether `allowlisted` is consulted at deposit time. False is a
    ///                        fully open vault.
    struct VaultTerms {
        uint64 depositStart;
        uint64 depositEnd;
        uint64 expiry;
        uint64 claimCliff;
        uint64 vestingDuration;
        uint256 hardCap;
        uint256 perAccountCap;
        uint256 minDeposit;
        bool allowlistEnabled;
    }

    /// @notice The asset contributors deposit and the asset the buy is paid in.
    IERC20 public immutable quoteToken;

    /// @notice The address allowed to call `execute`. Frozen when the deposit window opens.
    address public executor;

    /// @notice Where floor-division remainders go. Frozen when the deposit window opens.
    address public dustRecipient;

    /// @notice The venue the single buy is routed through. Write-once, see `setBuyTarget`.
    IPrelaunchBuyer public buyer;

    /// @notice The token the buy is expected to deliver. Write-once alongside `buyer`.
    IERC20 public launchToken;

    /// @notice The economic terms of this vault, sealed at `terms.depositStart`.
    VaultTerms public terms;

    /// @notice Accounts cleared to deposit while `terms.allowlistEnabled`. Frozen with the
    ///         rest of the terms when the window opens, so the list must be final by then.
    mapping(address account => bool cleared) public allowlisted;

    /// @notice Quote credited to each contributor, measured on arrival.
    mapping(address account => uint256 amount) public deposits;

    /// @notice Tokens each contributor has already taken, which is also their vested high
    ///         water mark: a claim always settles the whole vested amount.
    mapping(address account => uint256 amount) public tokensClaimed;

    /// @notice Quote each contributor has already taken, on either the refund or the expiry
    ///         path. The two paths are mutually exclusive, so one counter covers both.
    mapping(address account => uint256 amount) public quoteWithdrawn;

    /// @notice Whether a contributor's floor-divided shares have been added to the assigned
    ///         totals. Materialising is what makes the remainder computable without the
    ///         vault ever iterating the whole cohort in one call.
    mapping(address account => bool done) public materialized;

    /// @dev Every address that has ever held a non-zero deposit, in first-deposit order.
    ///      Kept on-chain so `materializeRange` is permissionless and needs no off-chain
    ///      index to finish the dust accounting.
    address[] private _contributors;

    /// @notice Sum of all credited deposits. The buy is bounded by this, never by balance.
    uint256 public totalDeposited;

    /// @notice Quote actually spent by the buy, measured as a balance delta.
    uint256 public quoteSpent;

    /// @notice Tokens actually delivered by the buy, measured as a balance delta.
    uint256 public tokensAcquired;

    /// @notice Sum of the token entitlements of every materialised contributor.
    uint256 public tokensAssigned;

    /// @notice Sum of the quote refund entitlements of every materialised contributor.
    uint256 public refundAssigned;

    /// @notice Tokens and quote that have actually left the vault to contributors.
    uint256 public tokensPaid;
    uint256 public quotePaid;

    /// @notice How many contributors have been materialised.
    uint256 public materializedCount;

    /// @notice When the buy happened; zero until it does. Anchors the unlock schedule.
    uint64 public executedAt;

    /// @notice Whether the one buy has happened.
    bool public executed;

    /// @notice Whether the floor remainders have been swept.
    bool public dustSwept;

    event TermsUpdated(VaultTerms terms);
    event ExecutorUpdated(address indexed executor);
    event DustRecipientUpdated(address indexed dustRecipient);
    event AllowlistUpdated(address indexed account, bool cleared);
    event BuyTargetSet(address indexed buyer, address indexed launchToken);
    event Deposited(
        address indexed account, uint256 amount, uint256 accountTotal, uint256 vaultTotal
    );
    event Executed(
        address indexed executor,
        address indexed buyer,
        uint256 quoteSpent,
        uint256 tokensAcquired,
        uint256 unspentQuote
    );
    event TokensClaimed(address indexed account, uint256 amount, uint256 totalClaimed);
    event QuoteRefunded(address indexed account, uint256 amount);
    event Reclaimed(address indexed account, uint256 amount);
    event DustSwept(address indexed recipient, uint256 tokenDust, uint256 quoteDust);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTerms();
    error ParametersFrozen();
    error NotExecutor();
    error DepositsNotOpen();
    error DepositsClosed();
    error NotAllowlisted(address account);
    error BelowMinimum(uint256 accountTotal, uint256 minimum);
    error HardCapExceeded(uint256 amount, uint256 remaining);
    error AccountCapExceeded(uint256 accountTotal, uint256 cap);
    error NothingDeposited();
    error AlreadyExecuted();
    error NotExecuted();
    error DepositWindowOpen();
    error VaultExpired();
    error BuyTargetNotSet();
    error BuyTargetAlreadySet();
    error QuoteCannotBeLaunchToken();
    error InsufficientTokensAcquired(uint256 acquired, uint256 minimum);
    error OverSpent(uint256 spent, uint256 allowed);
    error ClaimLocked(uint256 unlockAt);
    error RefundNotAvailable();
    error NothingToClaim();
    error DustAlreadySwept();
    error NotFullyMaterialized(uint256 done, uint256 total);
    error RangeOutOfBounds();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    /// @dev Every owner-settable economic parameter carries this. The deposit window opening
    ///      is the line: before it, nobody's money is at stake and the terms are a draft;
    ///      after it, the terms are the deal the cohort agreed to.
    modifier whileUnopened() {
        if (block.timestamp >= terms.depositStart) revert ParametersFrozen();
        _;
    }

    /// @param initialOwner   Configures the vault before the window opens; can never move
    ///                       contributor funds.
    /// @param quoteToken_    The deposit and spend asset.
    /// @param executor_      The only address that may call `execute`.
    /// @param dustRecipient_ Where floor remainders land.
    /// @param terms_         The economic terms, validated here and frozen at window open.
    constructor(
        address initialOwner,
        IERC20 quoteToken_,
        address executor_,
        address dustRecipient_,
        VaultTerms memory terms_
    ) Ownable(initialOwner) {
        if (address(quoteToken_) == address(0)) revert ZeroAddress();
        if (executor_ == address(0) || dustRecipient_ == address(0)) revert ZeroAddress();
        _validateTerms(terms_);

        quoteToken = quoteToken_;
        executor = executor_;
        dustRecipient = dustRecipient_;
        terms = terms_;

        emit ExecutorUpdated(executor_);
        emit DustRecipientUpdated(dustRecipient_);
        emit TermsUpdated(terms_);
    }

    // ─── Configuration ───────────────────────────────────────────────────

    /// @notice Replaces the economic terms wholesale, only before the window opens.
    function setTerms(VaultTerms memory terms_) external onlyOwner whileUnopened {
        _validateTerms(terms_);
        terms = terms_;
        emit TermsUpdated(terms_);
    }

    /// @notice Rotates the executor, only before the window opens.
    function setExecutor(address executor_) external onlyOwner whileUnopened {
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    /// @notice Rotates the dust recipient, only before the window opens.
    function setDustRecipient(address dustRecipient_) external onlyOwner whileUnopened {
        if (dustRecipient_ == address(0)) revert ZeroAddress();
        dustRecipient = dustRecipient_;
        emit DustRecipientUpdated(dustRecipient_);
    }

    /// @notice Clears or revokes accounts for a whitelisted vault, only before the window
    ///         opens.
    /// @dev    An explicit allowlist rather than a merkle root: the cohort for a protected
    ///         pre-launch buy is small and known, the owner already has to send a
    ///         configuration transaction, and an on-chain list is readable by anyone
    ///         deciding whether to deposit without a distribution channel for proofs.
    function setAllowlist(address[] calldata accounts, bool cleared)
        external
        onlyOwner
        whileUnopened
    {
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();
            allowlisted[account] = cleared;
            emit AllowlistUpdated(account, cleared);
        }
    }

    /// @notice Names the venue the single buy is routed through and the token it delivers.
    /// @dev    The one setter that outlives the window opening, because a pre-launch vault
    ///         exists precisely to collect money before the thing it buys from is deployed.
    ///         It is write-once and public, so a contributor can always see the target
    ///         before `execute`, and `execute` reverts while it is unset.
    function setBuyTarget(IPrelaunchBuyer buyer_, IERC20 launchToken_) external onlyOwner {
        if (address(buyer) != address(0)) revert BuyTargetAlreadySet();
        if (address(buyer_) == address(0) || address(launchToken_) == address(0)) {
            revert ZeroAddress();
        }
        // Both sides of the buy are measured as balance deltas on this contract; one asset
        // playing both roles would make those deltas meaningless.
        if (address(launchToken_) == address(quoteToken)) revert QuoteCannotBeLaunchToken();

        buyer = buyer_;
        launchToken = launchToken_;
        emit BuyTargetSet(address(buyer_), address(launchToken_));
    }

    function _validateTerms(VaultTerms memory t) private view {
        // A window that is already open would be frozen on arrival, and one that opens in the
        // past cannot be reasoned about by anyone deciding whether to join.
        if (t.depositStart < block.timestamp) revert InvalidTerms();
        if (t.depositEnd <= t.depositStart) revert InvalidTerms();
        // Expiry has to leave the executor a real window between close and refund, otherwise
        // the buy and the permissionless reclaim race each other.
        if (t.expiry <= t.depositEnd) revert InvalidTerms();
        if (t.hardCap == 0) revert InvalidTerms();
        if (t.perAccountCap != 0 && t.perAccountCap > t.hardCap) revert InvalidTerms();
        if (t.minDeposit > t.hardCap) revert InvalidTerms();
        if (t.perAccountCap != 0 && t.minDeposit > t.perAccountCap) revert InvalidTerms();
        if (uint256(t.claimCliff) + uint256(t.vestingDuration) > MAX_UNLOCK_WINDOW) {
            revert InvalidTerms();
        }
    }

    // ─── Deposits ────────────────────────────────────────────────────────

    /// @notice Joins the cohort with `amount` of the quote asset.
    /// @dev    Credited by balance delta, so a fee-on-transfer quote credits what arrived and
    ///         the caps, the buy ceiling and every later pro-rata all agree with the vault's
    ///         real holdings. Caps are checked against the credited amount for the same
    ///         reason.
    function deposit(uint256 amount) external nonReentrant returns (uint256 credited) {
        VaultTerms memory t = terms;
        if (block.timestamp < t.depositStart) revert DepositsNotOpen();
        if (block.timestamp >= t.depositEnd) revert DepositsClosed();
        if (t.allowlistEnabled && !allowlisted[msg.sender]) revert NotAllowlisted(msg.sender);
        if (amount == 0) revert ZeroAmount();

        uint256 before = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        credited = quoteToken.balanceOf(address(this)) - before;
        if (credited == 0) revert ZeroAmount();

        uint256 priorTotal = totalDeposited;
        uint256 newTotal = priorTotal + credited;
        if (newTotal > t.hardCap) revert HardCapExceeded(credited, t.hardCap - priorTotal);

        uint256 priorBalance = deposits[msg.sender];
        uint256 newBalance = priorBalance + credited;
        if (newBalance < t.minDeposit) revert BelowMinimum(newBalance, t.minDeposit);
        if (t.perAccountCap != 0 && newBalance > t.perAccountCap) {
            revert AccountCapExceeded(newBalance, t.perAccountCap);
        }

        if (priorBalance == 0) _contributors.push(msg.sender);
        deposits[msg.sender] = newBalance;
        totalDeposited = newTotal;

        emit Deposited(msg.sender, credited, newBalance, newTotal);
    }

    // ─── The buy ─────────────────────────────────────────────────────────

    /// @notice The one protected buy, on behalf of the whole cohort.
    /// @param maxQuoteSpend Ceiling on quote to commit; the vault spends the lesser of this
    ///        and everything deposited, and never a wei of anything donated to it.
    /// @param minTokensOut Floor on tokens the vault must end up holding for the fill to
    ///        stand. Zero is rejected: a buy that is allowed to acquire nothing is not a buy,
    ///        and it would leave a cohort with an executed vault and no allocation.
    /// @dev   Both legs are measured as balance deltas across the venue call rather than
    ///        taken from its return value, so a venue that under-delivers, over-charges or
    ///        lies about either is caught here and the whole call reverts with deposits
    ///        untouched. The approval is opened for exactly the ceiling and closed
    ///        immediately, leaving nothing standing over contributor funds.
    function execute(uint256 maxQuoteSpend, uint256 minTokensOut)
        external
        onlyExecutor
        nonReentrant
        returns (uint256 spent, uint256 acquired)
    {
        if (executed) revert AlreadyExecuted();
        VaultTerms memory t = terms;
        if (block.timestamp < t.depositEnd) revert DepositWindowOpen();
        if (block.timestamp >= t.expiry) revert VaultExpired();
        IPrelaunchBuyer venue = buyer;
        if (address(venue) == address(0)) revert BuyTargetNotSet();

        uint256 deposited = totalDeposited;
        if (deposited == 0) revert NothingDeposited();
        if (minTokensOut == 0) revert ZeroAmount();

        uint256 ceiling = maxQuoteSpend < deposited ? maxQuoteSpend : deposited;
        if (ceiling == 0) revert ZeroAmount();

        IERC20 token = launchToken;
        uint256 quoteBefore = quoteToken.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));

        quoteToken.forceApprove(address(venue), ceiling);
        venue.buyForVault(ceiling, minTokensOut, address(this));
        quoteToken.forceApprove(address(venue), 0);

        uint256 quoteAfter = quoteToken.balanceOf(address(this));
        // Saturating: a venue that hands quote back beyond what it took leaves the surplus
        // stranded rather than inflating anyone's refund past what they put in.
        spent = quoteAfter >= quoteBefore ? 0 : quoteBefore - quoteAfter;
        if (spent > ceiling) revert OverSpent(spent, ceiling);

        acquired = token.balanceOf(address(this)) - tokenBefore;
        if (acquired < minTokensOut) revert InsufficientTokensAcquired(acquired, minTokensOut);

        executed = true;
        executedAt = uint64(block.timestamp);
        quoteSpent = spent;
        tokensAcquired = acquired;

        emit Executed(msg.sender, address(venue), spent, acquired, deposited - spent);
    }

    // ─── Claims ──────────────────────────────────────────────────────────

    /// @notice Takes everything of the caller's allocation that has unlocked so far.
    function claimTokens() external nonReentrant returns (uint256 amount) {
        if (!executed) revert NotExecuted();
        uint256 unlockAt = unlockStart();
        if (block.timestamp < unlockAt) revert ClaimLocked(unlockAt);

        _materialize(msg.sender);

        uint256 vested = vestedTokens(msg.sender);
        uint256 alreadyTaken = tokensClaimed[msg.sender];
        amount = vested - alreadyTaken;
        if (amount == 0) revert NothingToClaim();

        tokensClaimed[msg.sender] = vested;
        tokensPaid += amount;
        launchToken.safeTransfer(msg.sender, amount);

        emit TokensClaimed(msg.sender, amount, vested);
    }

    /// @notice Returns `account`'s quote: their pro-rata share of what the buy did not spend
    ///         once it has happened, or their entire deposit once an unexecuted vault has
    ///         expired.
    /// @dev    Permissionless and paid to `account`, never to the caller. A cohort whose
    ///         executor walked away does not need that executor, the owner, or even its own
    ///         members online to get its money back.
    function claimQuote(address account) external nonReentrant returns (uint256 amount) {
        uint256 entitled;
        bool expired;
        if (executed) {
            _materialize(account);
            entitled = quoteRefundEntitlement(account);
        } else if (block.timestamp >= terms.expiry) {
            entitled = deposits[account];
            expired = true;
        } else {
            revert RefundNotAvailable();
        }

        amount = entitled - quoteWithdrawn[account];
        if (amount == 0) revert NothingToClaim();

        quoteWithdrawn[account] = entitled;
        quotePaid += amount;
        quoteToken.safeTransfer(account, amount);

        if (expired) emit Reclaimed(account, amount);
        else emit QuoteRefunded(account, amount);
    }

    /// @notice Records the floor-divided shares of a slice of the contributor list.
    /// @dev    Claiming materialises the claimant, so this exists only for contributors who
    ///         have not moved yet and only so the remainder becomes computable. It is
    ///         permissionless, idempotent and batched, and it moves no funds.
    function materializeRange(uint256 start, uint256 count) external {
        if (!executed) revert NotExecuted();
        uint256 length = _contributors.length;
        if (start >= length) revert RangeOutOfBounds();
        uint256 end = start + count;
        if (end > length) end = length;
        for (uint256 i = start; i < end; ++i) {
            _materialize(_contributors[i]);
        }
    }

    /// @notice Sends the floor-division remainders of both assets to the dust recipient.
    /// @dev    The remainder is only knowable once every contributor's floored share has been
    ///         added up, which is what the materialisation requirement enforces. Until then
    ///         this reverts rather than guessing, and once it runs, claims plus dust account
    ///         for every wei the buy produced.
    function sweepDust() external nonReentrant returns (uint256 tokenDust, uint256 quoteDust) {
        if (!executed) revert NotExecuted();
        if (dustSwept) revert DustAlreadySwept();
        uint256 total = _contributors.length;
        if (materializedCount != total) revert NotFullyMaterialized(materializedCount, total);

        dustSwept = true;
        tokenDust = tokensAcquired - tokensAssigned;
        quoteDust = unspentQuote() - refundAssigned;

        address recipient = dustRecipient;
        if (tokenDust != 0) launchToken.safeTransfer(recipient, tokenDust);
        if (quoteDust != 0) quoteToken.safeTransfer(recipient, quoteDust);

        emit DustSwept(recipient, tokenDust, quoteDust);
    }

    function _materialize(address account) private {
        if (materialized[account]) return;
        if (deposits[account] == 0) return;
        materialized[account] = true;
        unchecked {
            ++materializedCount;
        }
        tokensAssigned += tokenEntitlement(account);
        refundAssigned += quoteRefundEntitlement(account);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Quote the buy left behind, which is what the refund leg pays out.
    function unspentQuote() public view returns (uint256) {
        return totalDeposited - quoteSpent;
    }

    /// @notice The second the first token claim becomes possible.
    function unlockStart() public view returns (uint256) {
        if (!executed) return 0;
        return uint256(executedAt) + uint256(terms.claimCliff);
    }

    /// @notice The second the whole allocation is unlocked.
    function unlockEnd() public view returns (uint256) {
        if (!executed) return 0;
        return unlockStart() + uint256(terms.vestingDuration);
    }

    /// @notice `account`'s whole share of the buy, floored.
    function tokenEntitlement(address account) public view returns (uint256) {
        uint256 deposited = totalDeposited;
        if (deposited == 0 || !executed) return 0;
        return Math.mulDiv(tokensAcquired, deposits[account], deposited);
    }

    /// @notice `account`'s whole share of the unspent quote, floored.
    function quoteRefundEntitlement(address account) public view returns (uint256) {
        uint256 deposited = totalDeposited;
        if (deposited == 0 || !executed) return 0;
        return Math.mulDiv(unspentQuote(), deposits[account], deposited);
    }

    /// @notice How much of `account`'s entitlement has unlocked as of now.
    function vestedTokens(address account) public view returns (uint256) {
        if (!executed) return 0;
        uint256 start = unlockStart();
        if (block.timestamp < start) return 0;

        uint256 entitlement = tokenEntitlement(account);
        uint256 duration = uint256(terms.vestingDuration);
        if (duration == 0) return entitlement;

        uint256 elapsed = block.timestamp - start;
        if (elapsed >= duration) return entitlement;
        return Math.mulDiv(entitlement, elapsed, duration);
    }

    /// @notice What `account` could take right now on the token leg.
    function claimableTokens(address account) external view returns (uint256) {
        uint256 vested = vestedTokens(account);
        uint256 taken = tokensClaimed[account];
        return vested > taken ? vested - taken : 0;
    }

    /// @notice What `account` could take right now on the quote leg, on either path.
    function claimableQuote(address account) external view returns (uint256) {
        uint256 entitled;
        if (executed) entitled = quoteRefundEntitlement(account);
        else if (block.timestamp >= terms.expiry) entitled = deposits[account];
        else return 0;

        uint256 taken = quoteWithdrawn[account];
        return entitled > taken ? entitled - taken : 0;
    }

    /// @notice How many addresses have ever deposited.
    function contributorCount() external view returns (uint256) {
        return _contributors.length;
    }

    /// @notice The contributor at `index`, in first-deposit order.
    function contributorAt(uint256 index) external view returns (address) {
        if (index >= _contributors.length) revert RangeOutOfBounds();
        return _contributors[index];
    }
}
