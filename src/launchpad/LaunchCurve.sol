// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2BondingCurve.sol), MIT.

import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {LaunchCurveMath} from "./libraries/LaunchCurveMath.sol";
import {
    CurveSegment,
    CurveSegmentConfig,
    LaunchCurveSegments
} from "./libraries/LaunchCurveSegments.sol";
import {
    FeePolicySnapshot,
    ILaunchCurve,
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchFeePolicy,
    ILaunchSnipeTax
} from "./interfaces/ILaunchpad.sol";

/// @title LaunchCurve
/// @notice Constant-product bonding curve for one launch, adapted from BootstrapPool.sol
///         (code-423n4/2025-01-iq-ai). The curve trades against a branded stablecoin — the
///         `pairToken` — which is the same asset its graduated market is seeded from, so
///         graduation never converts between assets and needs no price oracle anywhere in the
///         system.
///
///         Every trade fee is charged against the quote leg regardless of trade direction, so
///         the curve never accrues fees denominated in the launch token: protocol and creator
///         revenue is quote-denominated from the first trade, before graduation ever happens.
///         Fees are split protocol/creator under the policy snapshotted from `LaunchFactory`
///         at initialize and paid into `LaunchFeeEscrow` on sweep.
contract LaunchCurve is ReentrancyGuard, ILaunchCurve {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%

    error CurveGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error NotFactory();
    error AlreadyGraduated();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidLaunchEconomics();
    error NotReadyToGraduate();
    error InvalidFeePolicy();

    // `fee` and `tax` are reported separately because they fund different parties: the fee
    // splits across protocol and creator, while the tax is paid to the creator in full.
    event CurveBuy(
        address indexed buyer,
        address indexed recipient,
        uint256 quoteIn,
        uint256 tokensOut,
        uint256 fee,
        uint256 tax
    );
    event CurveBuyRefunded(address indexed buyer, uint256 refund);
    event CurveSell(
        address indexed seller,
        address indexed recipient,
        uint256 tokensIn,
        uint256 quoteOut,
        uint256 fee,
        uint256 tax
    );
    event FeesSwept(uint256 protocolAmount, uint256 creatorAmount, uint256 lpFundAmount);
    event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
    event Initialized(address token);
    event CreatorFeeRecipientUpdated(
        address indexed previousRecipient, address indexed newRecipient
    );
    event AutoGraduationFailed(address indexed token, uint256 gasRemaining);
    event SnipeTaxExempted(address indexed account);
    // Separate from CurveBuy so indexers can tell an ordinary fee from a launch-window
    // penalty and surface which wallets sniped the launch.
    event SnipeTaxCharged(address indexed recipient, uint256 amount);

    // Not immutable: the token's constructor needs this curve's real address, so the factory
    // deploys the curve first, then the token, then wires the token here via `initialize()`.
    // Set exactly once, guarded by onlyFactory.
    address public token;
    // Quote asset for both curve trading and the graduated market's seed.
    address public immutable pairToken;
    // Not immutable: the creator can hand off future fee sweeps to a new address via the
    // factory's two-step handover, forwarded here through `setCreatorFeeRecipient`.
    address public creatorFeeRecipient;
    address public immutable factory;
    // Economic terms frozen at initialize from the factory's policy at that moment. Global
    // policy updates affect future launches but cannot redirect an active curve's protocol
    // or LP fund share.
    ILaunchFeeEscrow public feeEscrow;
    address public protocolFeeRecipient;
    uint16 public protocolFeeShareBps;
    // The LP fund's cut of the same fee bucket, frozen the same way. Zero, with a zero
    // recipient, on any curve launched while the fund leg was switched off; such a curve
    // splits two ways exactly as it did before the fund existed.
    address public lpFundRecipient;
    uint16 public lpFundShareBps;
    // Virtual quote reserve seeded at deploy, denominated in the quote asset's own decimals.
    uint256 public immutable phantomQuote;
    uint256 public immutable feeBps;
    // Creator-chosen at launch, capped by the protocol at launch time. Kept entirely separate
    // from feeBps: it is layered on top of the base trade fee, not part of the
    // protocol/creator split, and is paid to the creator in full.
    uint256 public immutable creatorTaxBps;
    uint256 public immutable graduationThreshold;

    uint256 public quoteFeeBalance;
    uint256 public creatorTaxBalance;
    // Net real quote asset held from curve trading: buys add their value, sell payouts and
    // swept protocol/creator fees subtract theirs. Tracked explicitly instead of reading a
    // live balance, so a forced transfer in can neither inflate curve pricing nor push a
    // launch past its graduation threshold with no tokens actually sold.
    uint256 public trackedQuote;
    // Launch tokens this curve holds as tradeable reserve: set to the minted allocation at
    // initialize, reduced by buys, increased by sells. The token side needs the same treatment
    // as the quote side because both feed the constant-product price. Reading a live balance
    // would let any holder transfer tokens straight in to move the curve's pricing, delay
    // graduation past the point the launch's economics were quoted at, and shift what the
    // graduated pool opens at.
    uint256 public trackedTokens;
    bool public graduated;
    // Token balance the curve will never sell below, set once at initialize and handed to the
    // graduated pool intact. Everything above it is the sellable allocation, and graduation
    // is exactly its exhaustion.
    uint256 public reservedTokens;
    // Total supply this launch was created with, snapshotted at initialize and exposed for
    // off-chain consumers. Held here rather than read live from the token because the token
    // is burnable, so its own totalSupply stops describing the supply the launch was
    // configured around.
    uint256 public launchSupply;
    // Timestamp trading opened, anchoring the snipe tax decay. Set once at initialize, which
    // the factory calls in the launch transaction itself, so second zero of the decay is the
    // launch second.
    uint256 public launchedAt;
    // Anti-snipe tax terms, snapshotted from the factory at initialize like the rest of this
    // launch's economics. Frozen rather than read live so a factory retune can never change
    // the terms of a launch whose window is already open. A zero starting tax disables the
    // mechanism for this curve permanently.
    uint256 public snipeTaxStartBps;
    uint256 public snipeTaxSeconds;
    // Wallets the creator declared at launch, exempt from the snipe tax so a team's own
    // bundled buys are not eaten by the launch window's anti-bot pricing. Written only by the
    // factory during the launch transaction.
    mapping(address account => bool exempt) public snipeTaxExempt;
    /// @notice Virtual quote reserve that reproduces this curve's terminal price against the
    ///         real quote it holds at graduation. Equal to `phantomQuote` for an unsegmented
    ///         curve; above it for a segmented one, because a steepened curve closes at a
    ///         higher price than its opening reserves imply. `LaunchFactory` splits the
    ///         reserved allocation between pool and locker with this, which is what keeps a
    ///         graduated market opening at the price its curve closed at.
    uint256 public graduationPhantomQuote;
    // Resolved curve segments, written once at initialize and never afterwards. Always at
    // least one: an unsegmented launch resolves to the single segment that reproduces the
    // constant product this curve has always priced with.
    CurveSegment[] private _segments;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyInitialized() {
        if (token == address(0)) revert NotInitialized();
        _;
    }

    /// @param pairToken_ Quote asset for curve trading and the graduated market's seed.
    /// @param creatorFeeRecipient_ Address credited with creator fees.
    /// @param factory_ LaunchFactory address, the only caller allowed through `onlyFactory`.
    /// @param phantomQuote_ Virtual quote reserve seeded at deploy, never physically held.
    /// @param feeBps_ Trade fee in basis points, always charged on the quote leg.
    /// @param creatorTaxBps_ Additional creator-chosen trade tax in basis points, layered on
    ///        top of feeBps_.
    /// @param graduationThreshold_ Real quote reserve required before graduation unlocks.
    constructor(
        address pairToken_,
        address creatorFeeRecipient_,
        address factory_,
        uint256 phantomQuote_,
        uint256 feeBps_,
        uint256 creatorTaxBps_,
        uint256 graduationThreshold_
    ) {
        if (pairToken_ == address(0) || creatorFeeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (factory_ == address(0)) revert ZeroAddress();
        // The factory applies the same ceiling before deploying, but the curve defends its
        // own invariant rather than inheriting it: a combined fee at or above the whole trade
        // would break the quote accounting.
        if (feeBps_ + creatorTaxBps_ > MAX_TOTAL_TRADE_FEE_BPS) revert InvalidFeePolicy();

        pairToken = pairToken_;
        creatorFeeRecipient = creatorFeeRecipient_;
        // Passed explicitly rather than read from msg.sender: LaunchFactory deploys this curve
        // indirectly through LaunchDeployer to keep its own bytecode under EIP-170's size
        // limit, so msg.sender at construction time would otherwise resolve to that deployer
        // helper, not the factory.
        factory = factory_;
        phantomQuote = phantomQuote_;
        feeBps = feeBps_;
        creatorTaxBps = creatorTaxBps_;
        graduationThreshold = graduationThreshold_;
    }

    /// @notice Wires the launch token this curve dispenses and snapshots the factory's fee and
    ///         snipe-tax policy. Called once by the factory immediately after deploying the
    ///         token with this curve's (now known) address, before either contract is
    ///         reachable by anyone else.
    /// @dev Also fixes the pool's token allocation, which is why this cannot happen in the
    ///      constructor: the supply is only known once the token exists. Holding
    ///      `phantomQuote * supply` constant, the curve reaches a real quote reserve of
    ///      `graduationThreshold` exactly when its token balance falls to
    ///      `supply * phantomQuote / (phantomQuote + threshold)`. Reserving that balance
    ///      therefore does not change where a launch graduates, it only stops the curve
    ///      selling through it: the quote threshold and the token allocation are the same
    ///      point, so whichever one is used as the trigger, the graduated pool is seeded with
    ///      the same amounts at the same price on every launch.
    function initialize(address token_) external onlyFactory {
        _initialize(token_, new CurveSegmentConfig[](0));
    }

    /// @notice Same, for a launch whose config declares a segmented curve. The declaration is
    ///         relative — shares of the sellable allocation, and constant products relative to
    ///         this curve's own — so the factory can carry one shape across every quote brand
    ///         and this curve resolves it against the supply it actually minted.
    /// @dev A separate overload rather than a widened signature: the single-argument form is
    ///      what every launch deployed so far was wired with, and it stays the exact call the
    ///      factory makes for an unsegmented config.
    function initialize(address token_, CurveSegmentConfig[] calldata segments_)
        external
        onlyFactory
    {
        _initialize(token_, segments_);
    }

    /// @dev Shared body of both entrypoints. `segments_` empty is the unsegmented curve.
    function _initialize(address token_, CurveSegmentConfig[] memory segments_) private {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;

        FeePolicySnapshot memory policy = ILaunchFeePolicy(factory).currentFeePolicy();
        ILaunchFeeEscrow escrow = ILaunchFeePolicy(factory).feeEscrow();
        // The curve defends the split invariant itself rather than trusting the factory to
        // have held it: the factory is a proxy, and a combined share above the whole fee
        // would underflow the creator's remainder on the first sweep of a curve that is by
        // then immutable. A nonzero fund share with no recipient is refused for the same
        // reason — it would credit the escrow to address zero and wedge every later sweep.
        if (
            policy.protocolFeeRecipient == address(0)
                || uint256(policy.protocolFeeShareBps) + policy.lpFundShareBps > BASIS_POINTS
                || (policy.lpFundShareBps != 0 && policy.lpFundRecipient == address(0))
                || address(escrow) == address(0)
        ) revert InvalidFeePolicy();
        feeEscrow = escrow;
        protocolFeeRecipient = policy.protocolFeeRecipient;
        protocolFeeShareBps = policy.protocolFeeShareBps;
        lpFundRecipient = policy.lpFundRecipient;
        lpFundShareBps = policy.lpFundShareBps;

        uint256 supply = IERC20(token_).totalSupply();
        uint256 reserved = Math.mulDiv(supply, phantomQuote, phantomQuote + graduationThreshold);
        // A launch whose allocation rounds away has nothing to seed its pool with, and its
        // final buy would revert against an empty token side. Rejecting the config here
        // fails at launch rather than at graduation.
        if (reserved == 0 || reserved >= supply) revert InvalidLaunchEconomics();
        reservedTokens = reserved;
        launchSupply = supply;
        launchedAt = block.timestamp;
        snipeTaxStartBps = ILaunchSnipeTax(factory).snipeTaxStartBps();
        snipeTaxSeconds = ILaunchSnipeTax(factory).snipeTaxSeconds();
        // The allocation the curve actually received, which is the whole supply: the token
        // mints to this curve in its own constructor.
        trackedTokens = IERC20(token_).balanceOf(address(this));

        // Resolved here rather than taken as a constructor argument for the same reason the
        // reserved allocation is: the shape is declared in shares of a supply that does not
        // exist until the token does. `build` re-validates the declaration rather than
        // trusting the factory's own check, on the principle this contract already applies to
        // the combined fee cap — the curve defends the invariants its pricing depends on.
        (CurveSegment[] memory table,, uint256 terminalPhantomQuote) =
            LaunchCurveSegments.build(segments_, supply, reserved, phantomQuote);
        for (uint256 i = 0; i < table.length; ++i) {
            _segments.push(table[i]);
        }
        graduationPhantomQuote = terminalPhantomQuote;

        emit Initialized(token_);
    }

    /// @notice Tokens still available to buy before the curve graduates.
    function sellableTokens() public view returns (uint256) {
        uint256 tracked = trackedTokens;
        return tracked > reservedTokens ? tracked - reservedTokens : 0;
    }

    /// @notice Snipe tax `recipient` would pay on a buy landing right now, in basis points of
    ///         the quote leg. Starts at this launch's frozen `snipeTaxStartBps` in the launch
    ///         second and decays exponentially to zero across `snipeTaxSeconds`, both
    ///         snapshotted from the factory when the curve initialized. Exempt wallets and a
    ///         disabled tax both read as zero.
    /// @dev The decay is fourteen successive halvings spread evenly across the window, done
    ///      with right shifts so it stays in integer arithmetic. Fourteen because 2^14 exceeds
    ///      the maximum 9,900 starting tax, so the tax always reaches zero inside the window
    ///      rather than cutting off at a still-meaningful rate. The decay anchors to
    ///      `launchedAt`, set in the launch transaction itself, so second zero is the first
    ///      second the token is publicly buyable.
    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (snipeTaxExempt[recipient]) return 0;
        uint256 startBps = snipeTaxStartBps;
        if (startBps == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        uint256 window = snipeTaxSeconds;
        if (elapsed >= window) return 0;
        return startBps >> ((elapsed * 14) / window);
    }

    /// @notice Marks `account` as exempt from the snipe tax. Called by the factory during the
    ///         launch transaction for the creator, their fee recipient, and any bundle wallets
    ///         the creator declared, so a team's own opening buys clear at the untaxed price
    ///         while sniper bots in the same window do not.
    function exemptFromSnipeTax(address account) external onlyFactory {
        snipeTaxExempt[account] = true;
        emit SnipeTaxExempted(account);
    }

    /// @notice Updates who receives creator fees from future sweeps. Restricted to the
    ///         factory, which gates the creator's two-step handover before forwarding here,
    ///         so this contract only needs to trust one caller.
    function setCreatorFeeRecipient(address newRecipient) external onlyFactory {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit CreatorFeeRecipientUpdated(creatorFeeRecipient, newRecipient);
        creatorFeeRecipient = newRecipient;
    }

    /// @notice Returns the curve's current tradeable reserves, excluding fees pending sweep.
    ///         The quote side is the reserve the *next buy* prices against, which on a
    ///         segmented curve is the active segment's virtual reserve plus the real quote
    ///         raised since that segment opened. An unsegmented curve has one segment whose
    ///         virtual reserve is `phantomQuote` and whose mark is zero, so this is exactly
    ///         `phantomQuote + realQuoteReserve()` as it has always been.
    function getReserves() public view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        tokenReserve_ = trackedTokens;
        uint256 netQuote = trackedQuote - quoteFeeBalance - creatorTaxBalance;
        // Before `initialize` there is no resolved table yet and no supply to price against;
        // report the opening reserves rather than reverting a view.
        quoteReserve_ = _segments.length == 0
            ? phantomQuote + netQuote
            : _segmentQuoteReserve(_segmentFor(tokenReserve_, false), netQuote);
    }

    /// @notice Number of segments this curve's sellable allocation is split into. One for an
    ///         unsegmented launch.
    function segmentCount() external view returns (uint256) {
        return _segments.length;
    }

    /// @notice The resolved segment at `index`, in the order the curve sells through them.
    function getSegment(uint256 index) external view returns (CurveSegment memory) {
        return _segments[index];
    }

    /// @notice Tradeable quote reserve only, phantom included.
    function quoteReserve() external view returns (uint256 quoteReserve_) {
        (quoteReserve_,) = getReserves();
    }

    /// @notice Returns physically held tradeable quote asset, excluding virtual liquidity and
    ///         balances already earmarked as fees or creator tax.
    function realQuoteReserve() public view returns (uint256) {
        return trackedQuote - quoteFeeBalance - creatorTaxBalance;
    }

    /// @notice Tradeable token reserve only.
    function tokenReserve() external view returns (uint256 tokenReserve_) {
        (, tokenReserve_) = getReserves();
    }

    /// @notice True once the curve's sellable allocation has been bought out.
    /// @dev Equivalent to the real quote reserve reaching `graduationThreshold`, since the
    ///      reserved balance is derived from that same point. Expressed against the token side
    ///      because that is the one a buy cannot overshoot: the quote side is a floor that a
    ///      large trade could sail past, while the token side is a hard stop the curve refuses
    ///      to cross.
    function readyToGraduate() public view returns (bool) {
        if (graduated) return false;
        return sellableTokens() == 0;
    }

    // ─── Previews ────────────────────────────────────────────────────────

    /// @notice What `buy(quoteIn, _, recipient)` would return right now, with the same math
    ///         and the same rejections. `fee` is the base fee plus any snipe tax `recipient`
    ///         would pay, as `CurveBuy` reports it; `tax` is the creator tax. A buy that would
    ///         cross the reserved allocation is quoted at its clamped fill, charged on what it
    ///         would actually spend.
    function quoteBuy(uint256 quoteIn, address recipient)
        external
        view
        onlyInitialized
        returns (uint256 tokensOut, uint256 fee, uint256 tax)
    {
        if (graduated) revert CurveGraduated();
        if (quoteIn == 0) revert ZeroAmount();
        uint256 snipeTax;
        (, tokensOut, fee, tax, snipeTax) = _previewBuy(quoteIn, recipient);
        fee += snipeTax;
    }

    /// @notice What `sell(tokensIn, _, _)` would return right now, with the same math and the
    ///         same rejections.
    function quoteSell(uint256 tokensIn)
        external
        view
        onlyInitialized
        returns (uint256 quoteOut, uint256 fee, uint256 tax)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        return _previewSell(tokensIn);
    }

    /// @dev Prices a buy of `received` quote for `recipient` against the current reserves.
    ///      Shared by `buy` and `quoteBuy` so a preview can never disagree with the trade.
    function _previewBuy(uint256 received, address recipient)
        private
        view
        returns (uint256 spent, uint256 tokensOut, uint256 fee, uint256 tax, uint256 snipeTax)
    {
        uint256 tokenReserveBefore = trackedTokens;
        uint256 netQuote = trackedQuote - quoteFeeBalance - creatorTaxBalance;
        uint256 sellable =
            tokenReserveBefore > reservedTokens ? tokenReserveBefore - reservedTokens : 0;
        if (sellable == 0) revert CurveGraduated();

        // The snipe tax rides the quote leg like the base fee and creator tax, but is bounded
        // so the combined take always nets the buyer at least 1% of their spend and the
        // gross-up below never divides by zero. It deliberately ignores
        // MAX_TOTAL_TRADE_FEE_BPS: a 99% take in the launch second is the entire point. The
        // bound only matters to a nonzero tax, so the common untaxed buy skips it.
        uint256 snipeTaxBps = currentSnipeTaxBps(recipient);
        if (snipeTaxBps != 0) {
            uint256 maxSnipeTaxBps = BASIS_POINTS - feeBps - creatorTaxBps - 100;
            if (snipeTaxBps > maxSnipeTaxBps) snipeTaxBps = maxSnipeTaxBps;
        }

        spent = received;
        fee = (spent * feeBps) / BASIS_POINTS;
        tax = (spent * creatorTaxBps) / BASIS_POINTS;
        snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        bool clamped;
        (tokensOut, clamped) =
            _buyAmountOut(spent - fee - tax - snipeTax, tokenReserveBefore, netQuote);

        if (clamped) {
            // `tokensOut` is the whole sellable allocation here: the walk stops at the
            // reserved floor and reports that it had input left over.
            //
            // Price the clamped fill from the token side, then gross the result back up so
            // the fee legs still come out of the input.
            uint256 net = _buyAmountIn(tokensOut, tokenReserveBefore, netQuote);
            spent = Math.min(
                Math.mulDiv(
                    net,
                    BASIS_POINTS,
                    BASIS_POINTS - feeBps - creatorTaxBps - snipeTaxBps,
                    Math.Rounding.Ceil
                ),
                received
            );
            fee = (spent * feeBps) / BASIS_POINTS;
            tax = (spent * creatorTaxBps) / BASIS_POINTS;
            snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        }
    }

    /// @dev Prices a sell of `tokensIn` against the current reserves. Shared by `sell` and
    ///      `quoteSell`.
    function _previewSell(uint256 tokensIn)
        private
        view
        returns (uint256 quoteOut, uint256 fee, uint256 tax)
    {
        uint256 grossQuoteOut = _sellAmountOut(
            tokensIn, trackedTokens, trackedQuote - quoteFeeBalance - creatorTaxBalance
        );
        fee = (grossQuoteOut * feeBps) / BASIS_POINTS;
        tax = (grossQuoteOut * creatorTaxBps) / BASIS_POINTS;
        quoteOut = grossQuoteOut - fee - tax;
    }

    // ─── Segment walks ───────────────────────────────────────────────────
    //
    // Only the quote side of the curve is segmented. The token reserve is one continuous
    // axis, and a segment is the band of it running from the previous segment's floor down
    // to its own; within a band the curve is the same constant product it has always been,
    // priced against that band's virtual reserve plus the real quote taken in since the band
    // opened. A trade that runs out of band continues into the next one with what is left,
    // in the same call, so a quote and its fill are the same walk.
    //
    // Buys and sells cross a boundary at the same token reserve and in opposite directions
    // over the same bands, which is what makes a round trip exactly reversible: everything a
    // buy pays on the way down, a sell gives back on the way up, minus the rounding each leg
    // leaves behind in the curve's favour. That symmetry, not the shape of the price step, is
    // what stops a boundary from being arbitrageable.

    /// @dev The segment the token reserve `tokenReserveNow` trades in. A boundary belongs to
    ///      the band the trade is moving into: a buy at exactly a floor opens the next
    ///      (steeper) band, a sell at exactly a floor re-enters the previous (cheaper) one.
    ///      Both readings price the trade against the side of the boundary that favours the
    ///      curve.
    function _segmentFor(uint256 tokenReserveNow, bool selling)
        private
        view
        returns (uint256 index)
    {
        uint256 last = _segments.length - 1;
        for (index = 0; index < last; ++index) {
            uint256 floor_ = _segments[index].tokenFloor;
            if (selling ? floor_ <= tokenReserveNow : floor_ < tokenReserveNow) return index;
        }
    }

    /// @dev Quote reserve segment `index` prices against, given the curve's net real quote.
    function _segmentQuoteReserve(uint256 index, uint256 netQuote) private view returns (uint256) {
        CurveSegment storage segment = _segments[index];
        return segment.phantomQuote + netQuote - segment.quoteMark;
    }

    /// @dev Tokens `amountIn` of net quote buys, walking as many segments as it reaches.
    /// @return tokensOut Tokens the walk dispensed, never more than the sellable allocation.
    /// @return clamped True when the input was more than the whole remaining allocation could
    ///         absorb, which is the caller's signal to reprice the fill from the token side
    ///         and refund the difference.
    function _buyAmountOut(uint256 amountIn, uint256 tokenReserveNow, uint256 netQuote)
        private
        view
        returns (uint256 tokensOut, bool clamped)
    {
        uint256 index = _segmentFor(tokenReserveNow, false);
        uint256 last = _segments.length - 1;
        uint256 remaining = amountIn;

        while (true) {
            CurveSegment memory segment = _segments[index];
            uint256 quote = segment.phantomQuote + netQuote - segment.quoteMark;
            uint256 capacity = tokenReserveNow - segment.tokenFloor;
            // The first leg keeps the unsegmented rejections — an empty input, or one priced
            // so small it buys nothing, is still an error rather than a zero-token fill. A
            // later leg's leftovers are dust by construction, so they are absorbed instead of
            // taking the whole trade down.
            uint256 out = tokensOut == 0
                ? LaunchCurveMath.getAmountOut(remaining, quote, tokenReserveNow, 0)
                : LaunchCurveMath.quoteAmountOut(remaining, quote, tokenReserveNow, 0);
            if (out <= capacity) return (tokensOut + out, false);

            tokensOut += capacity;
            if (index == last) return (tokensOut, true);

            // `out > capacity` is exactly the statement that `remaining` exceeds the input
            // this band needs to be bought out whole, so the subtraction cannot underflow.
            uint256 consumed = LaunchCurveMath.getAmountIn(capacity, quote, tokenReserveNow, 0);
            remaining -= consumed;
            netQuote += consumed;
            tokenReserveNow = segment.tokenFloor;
            ++index;
            if (remaining == 0) return (tokensOut, false);
        }
    }

    /// @dev Net quote required to buy exactly `tokensOut` tokens, walking the same boundaries
    ///      `_buyAmountOut` would.
    function _buyAmountIn(uint256 tokensOut, uint256 tokenReserveNow, uint256 netQuote)
        private
        view
        returns (uint256 amountIn)
    {
        uint256 index = _segmentFor(tokenReserveNow, false);
        uint256 remaining = tokensOut;

        while (remaining != 0) {
            CurveSegment memory segment = _segments[index];
            uint256 quote = segment.phantomQuote + netQuote - segment.quoteMark;
            uint256 capacity = tokenReserveNow - segment.tokenFloor;
            uint256 take = remaining < capacity ? remaining : capacity;
            uint256 needed = LaunchCurveMath.getAmountIn(take, quote, tokenReserveNow, 0);
            amountIn += needed;
            netQuote += needed;
            remaining -= take;
            tokenReserveNow -= take;
            ++index;
        }
    }

    /// @dev Gross quote `tokensIn` sells for, walking back up through as many segments as it
    ///      reaches. The token reserve can never rise above the launch supply — the only
    ///      tokens anyone can sell are the ones the curve dispensed — so the first segment
    ///      always has room for whatever is left when the walk gets there.
    function _sellAmountOut(uint256 tokensIn, uint256 tokenReserveNow, uint256 netQuote)
        private
        view
        returns (uint256 quoteOut)
    {
        uint256 index = _segmentFor(tokenReserveNow, true);
        uint256 remaining = tokensIn;

        while (true) {
            CurveSegment memory segment = _segments[index];
            uint256 quote = segment.phantomQuote + netQuote - segment.quoteMark;
            uint256 ceiling = index == 0 ? launchSupply : _segments[index - 1].tokenFloor;
            uint256 headroom = ceiling - tokenReserveNow;

            if (index == 0 || remaining <= headroom) {
                uint256 out = quoteOut == 0
                    ? LaunchCurveMath.getAmountOut(remaining, tokenReserveNow, quote, 0)
                    : LaunchCurveMath.quoteAmountOut(remaining, tokenReserveNow, quote, 0);
                return quoteOut + out;
            }

            // Filling a band's headroom can never take out more quote than the band's own
            // virtual reserve, so the running net quote stays at or above this band's mark
            // and the next iteration's subtraction is safe.
            uint256 bandOut = quoteOut == 0
                ? LaunchCurveMath.getAmountOut(headroom, tokenReserveNow, quote, 0)
                : LaunchCurveMath.quoteAmountOut(headroom, tokenReserveNow, quote, 0);
            quoteOut += bandOut;
            netQuote -= bandOut;
            remaining -= headroom;
            tokenReserveNow = ceiling;
            --index;
        }
    }

    // ─── Trading ─────────────────────────────────────────────────────────

    /// @notice Buys the launch token with this launch's quote asset. The fee is always taken
    ///         from the quote leg, so this curve never holds a token-denominated fee.
    /// @dev The credited amount is the observed balance delta rather than the requested
    ///      amount, so a fee-on-transfer quote asset cannot make the curve promise reserves it
    ///      never received.
    ///
    ///      A buy that would take the curve past its reserved allocation is filled only up to
    ///      that allocation, charged for what it actually received, and refunded the
    ///      difference. It is deliberately not rejected: the last buy of a launch is the one
    ///      most likely to be sized against a state someone else has already moved, and
    ///      reverting would let anyone grief it by slipping a small buy in ahead.
    ///
    ///      Buys landing in the opening seconds of a launch additionally pay the decaying
    ///      snipe tax (see `currentSnipeTaxBps`) unless the recipient was exempted at launch.
    ///      The tax comes off the quote leg before pricing, so a sniper's spend mostly accrues
    ///      as fees instead of buying tokens, and it decays to nothing within seconds for
    ///      ordinary buyers.
    ///
    ///      Partial fills reinterpret `minTokensOut` as a bound on price rather than on
    ///      quantity, since a caller who spends less than they offered cannot expect the whole
    ///      quantity they asked for. The requirement is that the price paid is no worse than
    ///      the price implied by the caller's own arguments, and when nothing is clamped it
    ///      reduces exactly to `tokensOut >= minTokensOut`.
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 tokensOut)
    {
        if (graduated) revert CurveGraduated();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 received = _receiveQuote(quoteIn);
        if (received == 0) revert ZeroAmount();
        // graduate() is deliberately not nonReentrant and the factory's trigger is
        // permissionless, so a quote asset that yields control during transferFrom can drain
        // this curve between the check above and the reserve reads below. Re-checking here
        // rather than relying on the downstream arithmetic to happen to revert.
        if (graduated) revert CurveGraduated();

        (uint256 spent, uint256 out, uint256 fee, uint256 tax, uint256 snipeTax) =
            _previewBuy(received, recipient);
        tokensOut = out;

        // Price bound rather than quantity bound, so a partial fill honours the caller's
        // terms instead of failing them. Identical to `tokensOut >= minTokensOut` whenever
        // `spent == received`.
        if (spent * minTokensOut > received * tokensOut) {
            revert SlippageExceeded(tokensOut, minTokensOut);
        }

        // The snipe tax joins the base fee bucket, so it splits between protocol and creator
        // under the launch's frozen policy through the ordinary sweep path instead of needing
        // accounting of its own.
        _accrueFees(fee + snipeTax, tax);
        trackedQuote += spent;
        trackedTokens -= tokensOut;
        IERC20(token).safeTransfer(recipient, tokensOut);

        uint256 refund = received - spent;
        if (refund != 0) {
            emit CurveBuyRefunded(msg.sender, refund);
            IERC20(pairToken).safeTransfer(msg.sender, refund);
        }

        if (snipeTax != 0) emit SnipeTaxCharged(recipient, snipeTax);
        emit CurveBuy(msg.sender, recipient, spent, tokensOut, fee + snipeTax, tax);
        _tryAutoGraduate();
    }

    /// @notice Sells the launch token back to the curve for the quote asset. The fee is taken
    ///         from the quote output, so it is always quote-denominated here too.
    /// @dev Closed once the sellable allocation is exhausted, not merely once `graduated` is
    ///      set. `_tryAutoGraduate` swallows a failed graduation so a problem there cannot
    ///      take the crossing buy down with it, which leaves a window where the curve is ready
    ///      but the flag is still false. `buy` already refuses that state through its own
    ///      `sellable == 0` check, and `sell` has to match: `graduate` hands the pool whatever
    ///      `trackedTokens` holds, so a sell landing in the window would put tokens back on
    ///      the curve and take quote off it, and the pool would then be seeded deeper and
    ///      cheaper than the reserved allocation fixes it at. The deterministic graduation
    ///      price only holds if the window is closed on both sides.
    ///
    ///      This cannot strand a holder. `graduate` is permissionless, so anyone blocked here
    ///      can settle the launch themselves in the same transaction and trade the market
    ///      instead.
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 quoteOut)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        (uint256 out, uint256 fee, uint256 tax) = _previewSell(tokensIn);
        quoteOut = out;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        _accrueFees(fee, tax);
        trackedQuote -= quoteOut;
        trackedTokens += tokensIn;
        IERC20(pairToken).safeTransfer(recipient, quoteOut);

        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    /// @notice Distributes pending quote fees across protocol and creator using this launch's
    ///         frozen policy. Permissionless: the split is fixed and the payout goes to the
    ///         escrow, so there is nothing a caller can steer.
    /// @dev Reverts once graduated rather than silently no-op'ing. `graduate()` already drains
    ///      `quoteFeeBalance`/`creatorTaxBalance` to zero before setting the flag, and trading
    ///      is halted afterward so they can never refill, but making the guard explicit here
    ///      keeps that invariant self-evident instead of depending on reasoning across two
    ///      functions.
    function sweepFees() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        _sweepFees();
    }

    /// @notice Sweeps fees, halts trading, and hands the remaining tradeable reserves to the
    ///         factory so it can seed the graduated market. Because the curve already holds
    ///         the market's quote asset, the factory receives exactly what it needs to seed
    ///         with, and no conversion step sits between the two. Restricted to the factory;
    ///         deliberately not `nonReentrant` since it may be invoked from within `buy()`'s
    ///         own reentrancy-guarded scope.
    function graduate(address recipient)
        external
        onlyFactory
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (!readyToGraduate()) revert NotReadyToGraduate();

        // Halt trading before the sweep, not after. The sweep pays the escrow, and a quote
        // asset with a transfer callback can re-enter buy() or sell() from inside that
        // payment. This function is deliberately not nonReentrant so it stays callable from
        // within buy()'s own guarded scope, so the flag is the only thing closing that window.
        // Reentering while it was still false repopulated the fee buckets after they had been
        // zeroed, leaving balances with no quote behind them once the reserve was handed over,
        // and no way to ever sweep them.
        //
        // Safe to set here: readyToGraduate() is already evaluated above, and the private
        // _sweepFees never reads the flag.
        graduated = true;

        _sweepFees();

        // Hand over only the tracked trading reserves. Any quote asset or launch token
        // force-sent to this curve is deliberately left stranded here rather than folded into
        // the graduated pool's seed, so a donation cannot move the price the pool opens at.
        //
        // **And stranded means lost.** Unlike upstream there is no owner path to a curve at
        // all, so nobody — not the creator, not the protocol — can retrieve a mistaken
        // transfer. That is the right trade for a contract whose whole job is to price a
        // supply deterministically, but it is a real consequence and surfaces should say so:
        // send to the curve only through `buy`.
        quoteOut = trackedQuote;
        trackedQuote = 0;
        tokenOut = trackedTokens;
        trackedTokens = 0;

        if (quoteOut != 0) IERC20(pairToken).safeTransfer(recipient, quoteOut);
        if (tokenOut != 0) IERC20(token).safeTransfer(recipient, tokenOut);

        emit CurveCompleted(recipient, quoteOut, tokenOut);
    }

    /// @dev Pulls `amount` of the quote asset from the caller and returns the amount actually
    ///      received, measured as the balance delta so a fee-on-transfer quote asset is
    ///      credited for what arrived, not what was asked for.
    function _receiveQuote(uint256 amount) private returns (uint256) {
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        return quote.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Credits `amount` of the quote asset to `recipient`'s claimable escrow balance.
    function _creditQuote(address recipient, uint256 amount) private {
        IERC20(pairToken).forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, pairToken, amount);
    }

    /// @dev Attempts to graduate the instant a buy crosses the threshold, so the crossing
    ///      trade itself triggers the migration atomically. Wrapped in try/catch: if graduation
    ///      reverts for any reason, the underlying buy must still succeed, and graduation stays
    ///      permissionlessly retryable via the factory.
    ///
    ///      A failure is announced rather than swallowed silently. The crossing buyer sets
    ///      their own gas limit and can starve this call under the 63/64 rule, pushing
    ///      graduation's cost onto whoever calls next, so the event is what lets a keeper
    ///      notice a launch sitting ready but ungraduated.
    function _tryAutoGraduate() private {
        if (readyToGraduate()) {
            try ILaunchFactory(factory).graduate(token) {}
            catch {
                emit AutoGraduationFailed(token, gasleft());
            }
        }
    }

    /// @dev Books a trade's base fee and creator tax. The tax never enters the split.
    function _accrueFees(uint256 fee, uint256 tax) private {
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
    }

    /// @dev Splits pending quote fees three ways — protocol, LP fund, creator — using the
    ///      launch's frozen policy, and credits each into the escrow.
    ///
    ///      Both the protocol's and the fund's shares floor, and the creator takes what is
    ///      left rather than a computed share of their own. That keeps two properties the
    ///      two-way split had: the three legs always add up to exactly `pending`, so nothing
    ///      is stranded in the curve, and the rounding dust falls to the creator rather than
    ///      to the protocol. `initialize` bounds the two floored shares to the whole fee, so
    ///      the subtraction cannot underflow.
    function _sweepFees() private {
        uint256 pending = quoteFeeBalance;
        uint256 tax = creatorTaxBalance;
        if (pending == 0 && tax == 0) return;

        uint256 protocolAmount = (pending * protocolFeeShareBps) / BASIS_POINTS;
        uint256 lpFundAmount = (pending * lpFundShareBps) / BASIS_POINTS;
        // The creator tax bypasses the three-way split entirely: it is charged on top of the
        // base fee and paid to the creator in full.
        uint256 creatorAmount = pending - protocolAmount - lpFundAmount + tax;

        quoteFeeBalance = 0;
        creatorTaxBalance = 0;
        trackedQuote -= protocolAmount + lpFundAmount + creatorAmount;

        if (protocolAmount != 0) _creditQuote(protocolFeeRecipient, protocolAmount);
        if (lpFundAmount != 0) _creditQuote(lpFundRecipient, lpFundAmount);
        if (creatorAmount != 0) _creditQuote(creatorFeeRecipient, creatorAmount);

        emit FeesSwept(protocolAmount, creatorAmount, lpFundAmount);
    }
}
