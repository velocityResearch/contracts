// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2LaunchAndBuy.sol), MIT.

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {LaunchCurve} from "./LaunchCurve.sol";
import {LaunchFactory} from "./LaunchFactory.sol";
import {ILaunchFactory} from "./interfaces/ILaunchpad.sol";

/// @title LaunchRouter
/// @notice The user-facing entry point to a launch: create one and take the first position on
///         its curve in a single transaction, and trade that curve afterwards holding the
///         reserve asset (USDG), any brand of the same reserve, or the curve's own quote brand.
///
/// ## Why the launch and the first buy must be one transaction
///
///         `LaunchFactory` cannot fold a creator's buy into `launchToken`, so on its own the
///         first buy is a second transaction against a curve that is already live and already
///         public. The gap between them is measured in blocks for a bot and in seconds for a
///         human holding a wallet prompt, and it is long enough to lose the whole sellable
///         allocation — that is exactly what happened on the upstream factory this is forked
///         from. Routing both legs through here closes the gap rather than narrowing it: the
///         buy settles in the transaction that created the curve, so there is no intermediate
///         state to trade against, and a failed buy reverts the launch with it instead of
///         stranding a token its creator never wanted.
///
///         This contract is therefore the factory's trusted `launchForwarder`. It passes its
///         own caller to `launchTokenFor`, so CREATE2 addresses stay namespaced by the
///         initiating account and the launch record attributes that account rather than this
///         router. The factory rejects that entry point from every other address, and the
///         owner may rotate the forwarder when this periphery is replaced.
///
/// ## Why the reserve legs live here and not on the curve
///
///         A curve is quoted in one brand, because its float has to belong to one brand's
///         treasury to earn for it. But a `PooledBrandToken` is a costless wrapper of the
///         reserve asset — minting and redeeming are exactly 1:1, and any two brands of one
///         reserve swap 1:1 — so a trader holding USDG, or some market's brand, can reach a
///         curve through a conversion that costs nothing but gas:
///
/// ```
/// buy   USDG   --mint 1:1-->  pairToken --curve-->  launch token
/// buy   brandY --swap 1:1-->  pairToken --curve-->  launch token
/// sell  token  --curve-->     pairToken --redeem/swap 1:1-->  USDG or brandY
/// ```
///
///         That is the same conversion `MarketRouter` performs for a graduated market, written
///         once per venue rather than pushed into the curve, which stays a two-asset AMM that
///         knows nothing about reserves.
///
/// ## Deliberately not owned, not upgradeable, not pausable
///
///         It holds no funds between calls, keeps no user state, and has no parameter to tune:
///         the launch terms, the fee split and the snipe tax all live on the factory, and the
///         reserve is read per call from the launch's own record, so even the conversion venue
///         is not a setting here. An admin key over this contract would be a liability with
///         nothing to guard, and an upgrade hook would be a way to change a contract whose
///         source should keep matching its deployed bytecode. Replacing it means deploying
///         another one and pointing `setLaunchForwarder` at it.
///
///         **Pausing still reaches every path, through the legs that matter.**
///         `LaunchFactory.launchTokenFor`, `SharedReservePool.mint` and `SharedReservePool.swap`
///         are all `whenNotPaused`, so a paused protocol stops launches and every conversion
///         leg without a second switch that could disagree with the first. Selling a curve
///         back to its own quote brand deliberately keeps working, exactly as redeeming does.
///
/// ## What it never does
///
///         It never holds a balance between calls, never takes a fee, and never keeps a
///         remainder. Every entry point is `nonReentrant`, takes a `deadline` and a min-out,
///         buys and sells for `msg.sender` rather than for itself, and returns whatever the
///         curve handed back before it finishes. Approvals are for the exact amount of the leg
///         that follows and are dropped again in the same call — unlike `MarketRouter`, which
///         must keep standing Permit2 allowances alive for `PositionManager`, nothing here is
///         ever pulled by a contract that cannot be paid inline.
///
///         **Amounts are measured, never assumed.** Every pull reads a balance before and
///         after, every conversion propagates what the reserve returned, and the remainder of
///         a partially filled buy is computed as a balance delta against what this router
///         already held. A curve clamps the last buy of a launch to the allocation that is
///         left and refunds the difference to its caller — which is this router — so without
///         that accounting the excess would settle here instead of going home.
///
///         **A remainder goes home as the quote brand, not as what was paid in.** The
///         reasoning is `MarketRouter._refund`'s: a partial fill is the curve declining to
///         trade, not the holder deciding to leave the reserve, and redeeming their remainder
///         would hand them `redemptionFeeBps` less than they put in for a decision they never
///         made. A brand is a 1:1 claim they can redeem whenever they choose.
contract LaunchRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error InsufficientOutput(uint256 received, uint256 minimum);
    /// @notice The token is not one this factory launched, so it has no curve to trade.
    error UnknownLaunchToken(address token);
    /// @notice The brand offered or asked for is not registered in the launch's own reserve —
    ///         either no brand at all, or a brand of another reserve. Both are one rejection
    ///         because they are one question: the 1:1 swap only exists inside one reserve, and
    ///         crossing reserves is a redemption and a mint, priced by the reserve being left,
    ///         which is the holder's decision to make rather than a leg buried in a trade.
    error BrandNotInLaunchReserve(address token, address reserve);
    /// @notice The quote brand is not approved for launching, so it carries no economics to
    ///         read the launch fee and the reserve from. Checked before anything is pulled.
    error PairTokenNotApproved(address pairToken);
    /// @notice The funding leg delivered less than the launch fee alone, so there is nothing
    ///         to launch with. Only reachable through a quote brand that taxes transfers.
    error LaunchFeeNotCovered(uint256 funded, uint256 launchFee);

    // ─── Events ──────────────────────────────────────────────────────────

    /// @notice One atomic launch. `payToken` is what the launcher actually handed over, which
    ///         the factory's own `TokenLaunched` cannot say: it only ever sees the quote brand.
    event Launched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address payToken,
        uint256 quoteSpent,
        uint256 tokensOut
    );

    // ─── Wiring ──────────────────────────────────────────────────────────

    /// @notice The launch factory this router creates tokens through and reads every launch's
    ///         quote brand, reserve and curve from.
    /// @dev The reserve is not an immutable here on purpose. It is a property of the launch's
    ///      quote brand, not of this contract, and the factory may approve brands of a second
    ///      reserve later; pinning one would quietly route those launches through the wrong
    ///      pool or lock them out of the reserve legs entirely.
    LaunchFactory public immutable factory;

    constructor(LaunchFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    // ─── Launch ──────────────────────────────────────────────────────────

    /// @notice Launch a token paying in its own quote brand, and open the position with
    ///         `quoteIn` of the same brand.
    ///
    /// @param p Launch parameters, forwarded to the factory untouched. `creatorFeeRecipient`
    ///        is the wallet that earns this launch's fees; `expectedEconomics` pins the terms
    ///        exactly as it would on a direct launch.
    /// @param launchConfigId Factory launch config to launch against.
    /// @param pairToken The quote brand, which also fixes the reserve the launch graduates
    ///        into and the launch fee that is charged.
    /// @param exemptions Extra wallets to exempt from the launch-window snipe tax, for a team
    ///        bundling its opening buys across several addresses. `msg.sender` and the creator
    ///        fee recipient are exempted by the factory already, so the buy below always
    ///        clears untaxed; pass an empty array when there is no bundle.
    /// @param quoteIn Quote brand to spend on the opening buy, on top of the launch fee. Zero
    ///        launches without buying. An amount past what the curve can sell is clamped by
    ///        the curve and the remainder comes back.
    /// @param minTokensOut Slippage bound on the opening buy. The curve prices a clamped fill
    ///        against this too, so a buy sized to take the whole allocation can still set a
    ///        meaningful floor. Must be zero when `quoteIn` is, since nothing is bought.
    function launchAndBuy(
        LaunchFactory.TokenParams calldata p,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata exemptions,
        uint256 quoteIn,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        nonReentrant
        notExpired(deadline)
        returns (address token, address curve, uint256 tokensOut)
    {
        (, uint256 launchFee) = _launchEconomics(pairToken);
        (uint256 held, uint256 funded) = _pullMeasured(pairToken, launchFee + quoteIn);
        return _launchAndBuy(
            p, launchConfigId, pairToken, exemptions, launchFee, funded, minTokensOut, held
        );
    }

    /// @notice Launch a token holding nothing but the reserve asset (USDG). The launch fee and
    ///         the opening buy are both minted into the quote brand 1:1 on the way through, so
    ///         the amounts mean exactly what they mean on `launchAndBuy`.
    function launchAndBuyWithReserveAsset(
        LaunchFactory.TokenParams calldata p,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata exemptions,
        uint256 quoteIn,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        nonReentrant
        notExpired(deadline)
        returns (address token, address curve, uint256 tokensOut)
    {
        (SharedReservePool reserve, uint256 launchFee) = _launchEconomics(pairToken);
        (uint256 held, uint256 funded) =
            _fundFromReserveAsset(reserve, pairToken, launchFee + quoteIn);
        return _launchAndBuy(
            p, launchConfigId, pairToken, exemptions, launchFee, funded, minTokensOut, held
        );
    }

    /// @notice Launch a token holding any brand of the launch's reserve — including another
    ///         market's, or the quote brand itself. The brand is swapped into the quote brand
    ///         1:1, so again the amounts mean what they mean on `launchAndBuy`.
    function launchAndBuyWithBrand(
        address brandIn,
        LaunchFactory.TokenParams calldata p,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata exemptions,
        uint256 quoteIn,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        nonReentrant
        notExpired(deadline)
        returns (address token, address curve, uint256 tokensOut)
    {
        (SharedReservePool reserve, uint256 launchFee) = _launchEconomics(pairToken);
        (uint256 held, uint256 funded) =
            _fundFromBrand(reserve, brandIn, pairToken, launchFee + quoteIn);
        return _launchAndBuy(
            p, launchConfigId, pairToken, exemptions, launchFee, funded, minTokensOut, held
        );
    }

    // ─── Buy ─────────────────────────────────────────────────────────────

    /// @notice Buy a live launch with its own quote brand.
    function buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        (address curve, address pairToken,) = _launched(token);
        (uint256 held, uint256 funded) = _pullMeasured(pairToken, quoteIn);
        tokensOut = _buyOnCurve(curve, pairToken, funded, minTokensOut);
        _refundRemainder(pairToken, held);
    }

    /// @notice Buy a live launch with the reserve asset (USDG), minted into the launch's quote
    ///         brand 1:1 on the way in — which is the moment it becomes float earning for that
    ///         brand's treasury.
    function buyWithReserveAsset(
        address token,
        uint256 assetIn,
        uint256 minTokensOut,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) returns (uint256 tokensOut) {
        if (assetIn == 0) revert ZeroAmount();
        (address curve, address pairToken, SharedReservePool reserve) = _launched(token);
        (uint256 held, uint256 funded) = _fundFromReserveAsset(reserve, pairToken, assetIn);
        tokensOut = _buyOnCurve(curve, pairToken, funded, minTokensOut);
        _refundRemainder(pairToken, held);
    }

    /// @notice Buy a live launch with any brand of its reserve, swapped into the quote brand
    ///         1:1. No approval of the reserve is needed; only this router must be approved
    ///         for `amountIn`.
    function buyWithBrand(
        address brandIn,
        address token,
        uint256 amountIn,
        uint256 minTokensOut,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) returns (uint256 tokensOut) {
        if (amountIn == 0) revert ZeroAmount();
        (address curve, address pairToken, SharedReservePool reserve) = _launched(token);
        (uint256 held, uint256 funded) = _fundFromBrand(reserve, brandIn, pairToken, amountIn);
        tokensOut = _buyOnCurve(curve, pairToken, funded, minTokensOut);
        _refundRemainder(pairToken, held);
    }

    // ─── Sell ────────────────────────────────────────────────────────────

    /// @notice Sell back to the curve and keep the launch's quote brand.
    /// @dev The curve pays the seller directly here, so `minQuoteOut` is the curve's own
    ///      `SlippageExceeded` bound rather than a second check on a balance this router never
    ///      sees. The two reserve-leg variants below cannot do that — their payout is produced
    ///      by a call made after the curve has already settled — so they bound the end result
    ///      instead, which is the amount the seller actually receives either way.
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
        returns (uint256 quoteOut)
    {
        (address curve,,) = _launched(token);
        quoteOut = _sellOnCurve(curve, token, tokensIn, minQuoteOut, msg.sender);
    }

    /// @notice Sell back to the curve and leave holding the reserve asset (USDG).
    /// @return assetOut What the reserve actually paid out, not what was burned. A redemption
    ///         can settle a wei short of par — the reserve truncates to its idle balance
    ///         rather than reverting on an adapter's rounding — and `minAssetOut` is how the
    ///         seller says how short is acceptable.
    function sellForReserveAsset(
        address token,
        uint256 tokensIn,
        uint256 minAssetOut,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) returns (uint256 assetOut) {
        (address curve, address pairToken, SharedReservePool reserve) = _launched(token);
        uint256 quoteOut = _sellOnCurveToSelf(curve, token, pairToken, tokensIn);
        // `redeem` burns from its own caller, so there is no allowance to grant here — and
        // none to leave behind either.
        assetOut = reserve.redeem(pairToken, quoteOut, msg.sender, minAssetOut);
    }

    /// @notice Sell back to the curve and leave holding any brand of the launch's reserve.
    function sellForBrand(
        address brandOut,
        address token,
        uint256 tokensIn,
        uint256 minBrandOut,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) returns (uint256 amountOut) {
        (address curve, address pairToken, SharedReservePool reserve) = _launched(token);
        if (brandOut == pairToken) {
            return _sellOnCurve(curve, token, tokensIn, minBrandOut, msg.sender);
        }
        if (!reserve.isRegistered(brandOut)) {
            revert BrandNotInLaunchReserve(brandOut, address(reserve));
        }

        uint256 quoteOut = _sellOnCurveToSelf(curve, token, pairToken, tokensIn);
        amountOut = reserve.swap(pairToken, brandOut, quoteOut, msg.sender);
        if (amountOut < minBrandOut) revert InsufficientOutput(amountOut, minBrandOut);
    }

    // ─── Previews ────────────────────────────────────────────────────────

    /// @notice What `buy(token, quoteIn, _, _)` would return for `recipient` right now, with
    ///         the curve's own math and the curve's own rejections. `fee` includes any snipe
    ///         tax `recipient` would pay; `tax` is the creator's.
    /// @dev The reserve legs need no preview of their own: minting, swapping and redeeming are
    ///      1:1, so a quote figure from here is the figure for all three doors, less the
    ///      reserve's redemption fee on the way out of `sellForReserveAsset`.
    function previewBuy(address token, uint256 quoteIn, address recipient)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 tax)
    {
        (address curve,,) = _launched(token);
        return LaunchCurve(curve).quoteBuy(quoteIn, recipient);
    }

    /// @notice What `sell(token, tokensIn, _, _)` would return right now.
    function previewSell(address token, uint256 tokensIn)
        external
        view
        returns (uint256 quoteOut, uint256 fee, uint256 tax)
    {
        (address curve,,) = _launched(token);
        return LaunchCurve(curve).quoteSell(tokensIn);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev The launch fee is approved to the factory and pulled inside `launchTokenFor`,
    ///      which is why the approval is exact and needs no reset: the factory takes the whole
    ///      allowance or the launch reverts and takes this call with it.
    /// @param funded Quote brand this call has actually delivered to itself, launch fee
    ///        included. What is left after the fee is what the opening buy spends, so a quote
    ///        brand that taxed the funding leg buys less rather than reverting on a shortfall
    ///        the caller cannot see.
    /// @param held Quote brand this router held before the call funded itself. The remainder
    ///        is measured against it, so dust left here by some earlier accident is never paid
    ///        out to this caller.
    function _launchAndBuy(
        LaunchFactory.TokenParams calldata p,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata exemptions,
        uint256 launchFee,
        uint256 funded,
        uint256 minTokensOut,
        uint256 held
    ) private returns (address token, address curve, uint256 tokensOut) {
        if (funded < launchFee) revert LaunchFeeNotCovered(funded, launchFee);
        if (launchFee != 0) IERC20(pairToken).forceApprove(address(factory), launchFee);

        (token, curve) =
            factory.launchTokenFor(p, launchConfigId, pairToken, exemptions, msg.sender);

        uint256 quoteIn = funded - launchFee;
        if (quoteIn != 0) {
            tokensOut = _buyOnCurve(curve, pairToken, quoteIn, minTokensOut);
        } else if (minTokensOut != 0) {
            // A launch-only call cannot honour a bound on tokens it was never asked to buy,
            // and silently ignoring one would turn a caller's slippage guard into a no-op.
            revert InsufficientOutput(0, minTokensOut);
        }

        _refundRemainder(pairToken, held);
        emit Launched(token, curve, msg.sender, pairToken, quoteIn, tokensOut);
    }

    /// @dev One buy on a curve, for `msg.sender`, with the allowance opened and closed inside
    ///      the call. The curve clamps a buy that would cross its reserved allocation and
    ///      refunds the difference to this router, leaving part of the allowance standing;
    ///      dropping it here is what keeps this router's balance free of standing claims.
    function _buyOnCurve(address curve, address pairToken, uint256 quoteIn, uint256 minTokensOut)
        private
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        IERC20(pairToken).forceApprove(curve, quoteIn);
        tokensOut = LaunchCurve(curve).buy(quoteIn, minTokensOut, msg.sender);
        IERC20(pairToken).forceApprove(curve, 0);
    }

    /// @dev One sell on a curve, paying `recipient`. The curve consumes the whole approval —
    ///      a sell is never clamped — so there is no allowance left to drop.
    function _sellOnCurve(
        address curve,
        address token,
        uint256 tokensIn,
        uint256 minQuoteOut,
        address recipient
    ) private returns (uint256 quoteOut) {
        if (tokensIn == 0) revert ZeroAmount();
        (, uint256 received) = _pullMeasured(token, tokensIn);
        if (received == 0) revert ZeroAmount();
        IERC20(token).forceApprove(curve, received);
        quoteOut = LaunchCurve(curve).sell(received, minQuoteOut, recipient);
    }

    /// @dev A sell whose quote leg has to be converted before it can go home, so this router
    ///      is the curve's payee for the length of one call. The payout is the measured
    ///      balance delta rather than the curve's return value: the conversion that follows
    ///      must move exactly what arrived, or this router would keep the difference.
    function _sellOnCurveToSelf(address curve, address token, address pairToken, uint256 tokensIn)
        private
        returns (uint256 quoteOut)
    {
        uint256 held = IERC20(pairToken).balanceOf(address(this));
        _sellOnCurve(curve, token, tokensIn, 0, address(this));
        quoteOut = IERC20(pairToken).balanceOf(address(this)) - held;
        if (quoteOut == 0) revert ZeroAmount();
    }

    /// @dev Mint `amount` of the reserve asset into `pairToken` 1:1. The reserve pulls the
    ///      asset, so it is approved for exactly what arrived.
    function _fundFromReserveAsset(SharedReservePool reserve, address pairToken, uint256 amount)
        private
        returns (uint256 held, uint256 funded)
    {
        held = IERC20(pairToken).balanceOf(address(this));
        if (amount == 0) return (held, 0);

        IERC20 reserveAsset = reserve.asset();
        (, uint256 received) = _pullMeasured(address(reserveAsset), amount);
        if (received == 0) revert ZeroAmount();
        reserveAsset.forceApprove(address(reserve), received);
        funded = reserve.mint(pairToken, received, address(this));
    }

    /// @dev Cross `amount` of `brandIn` into `pairToken` 1:1. `brandIn == pairToken` is
    ///      accepted and skips the swap, so one front-end path can offer every brand of the
    ///      reserve including the curve's own without branching on which it is.
    function _fundFromBrand(
        SharedReservePool reserve,
        address brandIn,
        address pairToken,
        uint256 amount
    ) private returns (uint256 held, uint256 funded) {
        if (brandIn != pairToken && !reserve.isRegistered(brandIn)) {
            revert BrandNotInLaunchReserve(brandIn, address(reserve));
        }
        held = IERC20(pairToken).balanceOf(address(this));
        if (amount == 0) return (held, 0);

        (, uint256 received) = _pullMeasured(brandIn, amount);
        if (received == 0) revert ZeroAmount();
        // `swap` burns from its own caller: no allowance to grant, and none to leave behind.
        funded = brandIn == pairToken
            ? received
            : reserve.swap(brandIn, pairToken, received, address(this));
    }

    /// @dev Pull `amount` of a token and report what actually arrived, alongside the balance
    ///      this router already held. A launch's quote brand is chosen by the protocol owner
    ///      and is always a 1:1 pooled brand, but the launch token itself is deployed per
    ///      launch and reaches here through `sell`, so no leg trusts a transfer's argument.
    function _pullMeasured(address token, uint256 amount)
        private
        returns (uint256 held, uint256 received)
    {
        held = IERC20(token).balanceOf(address(this));
        if (amount == 0) return (held, 0);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - held;
    }

    /// @dev Send back whatever the curve did not spend, measured against the balance this
    ///      router held before the call funded itself.
    function _refundRemainder(address pairToken, uint256 held) private {
        uint256 balance = IERC20(pairToken).balanceOf(address(this));
        if (balance > held) IERC20(pairToken).safeTransfer(msg.sender, balance - held);
    }

    /// @dev The curve, quote brand and reserve of a launched token. Rejects anything this
    ///      factory did not launch before a pull is attempted against it.
    function _launched(address token)
        private
        view
        returns (address curve, address pairToken, SharedReservePool reserve)
    {
        ILaunchFactory.LaunchedToken memory record = factory.getLaunchedToken(token);
        if (!record.exists) revert UnknownLaunchToken(token);
        return (record.curve, record.pairToken, SharedReservePool(record.reserve));
    }

    /// @dev The reserve and launch fee of an approved quote brand. Read before anything moves,
    ///      so an unapproved brand fails here rather than after the caller's funds have been
    ///      pulled and converted into something the factory will refuse.
    function _launchEconomics(address pairToken)
        private
        view
        returns (SharedReservePool reserve, uint256 launchFee)
    {
        (address reserveAddress,,, uint256 fee,, bool approved) =
            factory.pairTokenEconomics(pairToken);
        if (!approved) revert PairTokenNotApproved(pairToken);
        return (SharedReservePool(reserveAddress), fee);
    }
}
