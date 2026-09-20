// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IV4Quoter} from "../interfaces/IV4Quoter.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {AssetMarketFactory} from "./AssetMarketFactory.sol";

/// @title MarketLens
/// @notice Read-only answers to the two questions an aggregator asks of a market: *how much
///         do I get*, and *how much can this venue actually fill*. Nothing here moves a token
///         or holds one; it is deployable by anyone with gas and owned by nobody.
///
///         **Why this exists.** A market's stable side is a brand token, not the reserve asset,
///         so every trade that starts or ends in USDG has two legs — a 1:1 `SharedReservePool`
///         mint or redeem, and a Uniswap v4 swap. The v4 leg is quotable with Uniswap's own
///         `V4Quoter` (our hook's skim is a hook delta, so a stock quote is exact). The reserve
///         leg is arithmetic, but it is *capped* arithmetic: `mint` stops at `liabilityCap`, and
///         `redeem` pays only what the reserve holds idle plus what its yield source can hand
///         back this block. Neither cap is exposed as a view by the pool, and an integrator
///         who does not know the adapter internals cannot size a fill. This contract composes
///         the two legs and exposes both caps.
///
///         **`quoteBuy` / `quoteSell` are not `view`.** They call the `V4Quoter`, which runs the
///         swap for real inside `PoolManager.unlock` and reverts to unwind it. Use `eth_call`,
///         and never from inside an unlock somebody else already opened — the manager permits
///         one at a time. `maxMint`, `redeemableAssets`, `brandForRedeem` and `route` are plain
///         views.
///
///         **A quote is a size this venue can settle, or it is a revert.** Neither leg returns
///         a haircut: `quoteBuy` reverts `MintCapacityExceeded` rather than quote a mint the
///         reserve would refuse, and `quoteSell` reverts `RedeemCapacityExceeded` rather than
///         quote a redemption the reserve cannot pay for in full. An earlier revision capped
///         the sell figure at what the reserve could pay, which read as "you get less" when the
///         truth is "this size does not fit" — and a caller who set that capped figure as their
///         minimum would have burned brand worth more than it paid out. Size a partial fill
///         from `redeemableAssets` and `brandForRedeem`, or split the order.
///
///         **The reserve leg is quoted as the pool will settle it, not as it is documented.**
///         `redeemableAssets` asks the yield source what it can actually release rather than
///         what the reserve is owed, so a market whose backing is mid-bridge quotes the
///         buffer, not the book. An adapter predating `IYieldSource.withdrawable` therefore
///         makes this contract undeployable rather than quietly wrong —
///         `DeployMarketLens.s.sol` checks for it before broadcasting.
///
///         **Two things this deliberately does not model**, both of which would make a quote
///         optimistic rather than conservative and neither of which it can see: an asset that
///         taxes `transferFrom` (`MarketRouter._pullMeasured` swaps what arrived, not what was
///         asked for), and a yield source that refuses a deposit, which makes `mint` revert
///         inside `maxMint`'s headroom.
contract MarketLens {
    using PoolIdLibrary for PoolKey;

    /// @dev `SharedReservePool.BPS`: basis points, the redemption fee's denominator.
    uint256 private constant BPS = 10_000;
    /// @dev `ProtocolFeeHook.PIPS_DENOMINATOR`: hundredths of a bip.
    uint256 private constant PIPS = 1_000_000;

    AssetMarketFactory public immutable factory;
    IV4Quoter public immutable quoter;

    /// @notice Everything an integrator needs to index one market and settle against it.
    struct Route {
        /// @dev The reserve the market's brand is pooled in; `mint`/`redeem` go here.
        address reservePool;
        /// @dev The reserve's asset (USDG on Robinhood Chain) — what mint takes and redeem pays.
        address reserveAsset;
        /// @dev The market's stable side. Always one of `poolKey.currency0/1`.
        address brandToken;
        /// @dev The market's other side.
        address asset;
        /// @dev The v4 pool, hook address included — pass to `PoolManager.swap` verbatim.
        PoolKey poolKey;
        /// @dev `ProtocolFeeHook`'s skim, in hundredths of a bip. Charged on the swap's
        ///      UNSPECIFIED currency in `afterSwap` — the output of an exact-input swap, the
        ///      input of an exact-output one — and always on the amount that actually filled.
        ///      An integrator quoting exact-input therefore applies this rate to the OUTPUT.
        ///      Live value; the owner may move it, so re-read rather than cache.
        uint24 protocolFeePips;
        /// @dev Fee `SharedReservePool.redeem` keeps, in bips of the amount burned.
        uint16 redemptionFeeBps;
    }

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);
    /// @notice Minting `requested` into this market's reserve would breach its liability cap,
    ///         or the reserve is paused. `available` is what `mint` will accept right now.
    error MintCapacityExceeded(uint256 requested, uint256 available);
    /// @notice The reserve cannot pay `requested` of its asset this block. `available` is what
    ///         it can — idle balance plus what the yield source will release.
    error RedeemCapacityExceeded(uint256 requested, uint256 available);
    /// @notice Two rounds of the exact-output inversion still came up short of `amountOut`,
    ///         which means the pool disagreed with itself by more than one unit of rounding.
    error QuoteUnavailable(uint256 amountOut);

    constructor(AssetMarketFactory _factory, IV4Quoter _quoter) {
        if (address(_factory) == address(0) || address(_quoter) == address(0)) {
            revert ZeroAddress();
        }
        factory = _factory;
        quoter = _quoter;
    }

    // ─── Discovery ───────────────────────────────────────────────────────

    /// @notice The reserve a market's brand is pooled in.
    /// @dev Mirrors `MarketRouter._reserveOf`, and duplicating it is the lesser evil: the
    ///      convention is that a record written before the factory served more than one
    ///      reserve carries zero and belongs to the factory's default, and a lens that read
    ///      it through the router would bind this contract to a router upgrade it has no
    ///      other reason to care about.
    function reserveOf(uint256 marketId) public view returns (SharedReservePool) {
        (, SharedReservePool pool) = _marketAndReserve(marketId);
        return pool;
    }

    /// @notice One call per market for an indexer.
    function route(uint256 marketId) external view returns (Route memory r) {
        (AssetMarketFactory.Market memory m, SharedReservePool pool) = _marketAndReserve(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        r.reservePool = address(pool);
        r.reserveAsset = address(pool.asset());
        r.brandToken = m.brandToken;
        r.asset = m.asset;
        r.poolKey = key;
        r.protocolFeePips = factory.feeHook().feePipsFor(key.toId());
        r.redemptionFeeBps = pool.redemptionFeeBps();
    }

    /// @dev Both in one read. Every entry point needs the pair, and `market()` is a
    ///      struct-returning external call worth making once.
    function _marketAndReserve(uint256 marketId)
        private
        view
        returns (AssetMarketFactory.Market memory m, SharedReservePool pool)
    {
        m = factory.market(marketId);
        pool =
            m.reservePool == address(0) ? factory.reservePool() : SharedReservePool(m.reservePool);
    }

    // ─── The reserve leg ─────────────────────────────────────────────────

    /// @notice How much of the reserve asset `SharedReservePool.mint` will accept right now.
    ///         Zero while the reserve is paused; unbounded (`type(uint256).max`) for a reserve
    ///         with no liability cap.
    /// @dev Does not model the yield source's own deposit limits — a Morpho supply cap, say —
    ///      because `IYieldSource` has no view for them. A mint inside this bound can still
    ///      revert there; a mint outside it always reverts here.
    function maxMint(SharedReservePool pool) public view returns (uint256) {
        if (pool.paused()) return 0;
        uint256 cap = pool.liabilityCap();
        if (cap == 0) return type(uint256).max;
        uint256 supply = pool.totalPooledSupply();
        return supply >= cap ? 0 : cap - supply;
    }

    /// @notice How much of the reserve asset the pool can pay out this block: its idle balance
    ///         plus whatever its yield source will release. `redeem` is never paused, so this
    ///         is the only bound on it.
    /// @dev One unit short of the arithmetic sum, and deliberately. `_recallIfNeeded` asks the
    ///      adapter for `shortfall + 1` to absorb share↔asset rounding
    ///      (`SharedReservePool._recallIfNeeded`), and an adapter that reverts on an
    ///      over-request rather than clamping — Morpho Blue past its unlent supply, Aave past
    ///      the aToken's balance — takes the whole redemption down with it. Quoting the exact
    ///      ceiling would therefore quote the one size that cannot settle. The pad only bites
    ///      when the source is tapped at all, hence the zero case.
    function redeemableAssets(SharedReservePool pool) public view returns (uint256) {
        IERC20 asset = pool.asset();
        uint256 idle = asset.balanceOf(address(pool));

        IYieldSource source = pool.yieldSource();
        if (address(source) == address(0)) return idle;

        uint256 fromSource = source.withdrawable(address(asset), address(pool));
        return fromSource == 0 ? idle : idle + fromSource - 1;
    }

    /// @notice The least brand that must be burned so that `redeem` pays at least `assetsOut`.
    ///         Reverts `RedeemCapacityExceeded` if the reserve cannot pay that much this block.
    function brandForRedeem(SharedReservePool pool, uint256 assetsOut)
        public
        view
        returns (uint256 brandAmount)
    {
        uint256 available = redeemableAssets(pool);
        if (assetsOut > available) revert RedeemCapacityExceeded(assetsOut, available);

        return _grossFor(assetsOut, BPS, pool.redemptionFeeBps());
    }

    // ─── Inverting a floored cut ─────────────────────────────────────────
    //
    // Both fees in this system take a floored share of a gross amount: the reserve's
    // `redemptionFeeBps` out of `BPS`, and the hook's `feePips` out of `PIPS`. Neither is
    // invertible by division — flooring makes the survivor climb by 1 or 0 per unit of gross,
    // so several gross amounts can leave the same net — and both directions are needed:
    // `_grossFor` when the cut is subtracted, `_netFor` when it was added on top.

    /// @dev Least `gross` whose net, after a floored `cut`-in-`scale` share is taken out,
    ///      still reaches `net`. The exact-ratio ceiling is always feasible and overshoots by
    ///      at most one unit, so one step down is the whole search.
    function _grossFor(uint256 net, uint256 scale, uint256 cut) private pure returns (uint256) {
        uint256 keep = scale - cut;
        uint256 gross = (net * scale + keep - 1) / keep;
        while (gross > 1 && _netOf(gross - 1, scale, cut) >= net) {
            gross--;
        }
        return gross;
    }

    /// @dev What survives a floored cut. The subject `_grossFor` inverts.
    function _netOf(uint256 gross, uint256 scale, uint256 cut) private pure returns (uint256) {
        return gross - gross * cut / scale;
    }

    /// @dev Least `net` such that `net` plus a floored `cut`-in-`scale` share OF `net` reaches
    ///      `total`. This is the exact-output shape: the hook charges its skim on what the
    ///      pool consumed and bills the sum, so the pool's own figure has to be recovered from
    ///      it. The sum climbs by 1 or 2 per unit, so the exact-ratio floor is within a unit.
    function _netFor(uint256 total, uint256 scale, uint256 cut) private pure returns (uint256) {
        uint256 net = total * scale / (scale + cut);
        while (net + net * cut / scale < total) {
            net++;
        }
        return net;
    }

    // ─── Whole-route quotes (eth_call only) ───────────────────────────────

    /// @notice Reserve asset in, market asset out: `mint` 1:1, then the v4 swap.
    /// @dev Reverts `MintCapacityExceeded` when the reserve would refuse the mint, and the
    ///      quoter's own `NotEnoughLiquidity` when the pool cannot fill — so a number that
    ///      comes back is a number that settles.
    function quoteBuy(uint256 marketId, uint256 reserveAssetIn)
        external
        returns (uint256 assetOut, uint256 gasEstimate)
    {
        if (reserveAssetIn == 0) revert ZeroAmount();
        (AssetMarketFactory.Market memory m, SharedReservePool pool) = _marketAndReserve(marketId);

        uint256 capacity = maxMint(pool);
        if (reserveAssetIn > capacity) revert MintCapacityExceeded(reserveAssetIn, capacity);

        // The brand leg is exactly 1:1, so the pool sees `reserveAssetIn` of brand.
        return _quoteExactIn(factory.poolKeyOf(marketId), m.brandToken, reserveAssetIn);
    }

    /// @notice Market asset in, reserve asset out: the v4 swap, then `redeem`.
    /// @dev Reverts `RedeemCapacityExceeded` when the reserve cannot pay the redemption in
    ///      full. It does NOT return a reduced figure: the brand leg would be burned whole
    ///      either way, so a short reserve does not make this trade worse, it makes it a
    ///      different trade. `redeemableAssets` and `quoteSellExactOut` size one that fits.
    /// @return reserveAssetOut What the seller ends with: par on the brand, less the fee
    /// @return brandOut        What the swap alone produces — the amount `redeem` burns
    function quoteSell(uint256 marketId, uint256 assetIn)
        external
        returns (uint256 reserveAssetOut, uint256 brandOut, uint256 gasEstimate)
    {
        if (assetIn == 0) revert ZeroAmount();
        (AssetMarketFactory.Market memory m, SharedReservePool pool) = _marketAndReserve(marketId);

        (brandOut, gasEstimate) = _quoteExactIn(factory.poolKeyOf(marketId), m.asset, assetIn);

        reserveAssetOut = pool.previewRedeem(brandOut);
        uint256 available = redeemableAssets(pool);
        if (reserveAssetOut > available) {
            revert RedeemCapacityExceeded(reserveAssetOut, available);
        }
    }

    /// @notice Least reserve asset that, sold through `buyWithUsdg` (or any exact-input
    ///         settlement), delivers at least `assetOut` of the market asset.
    /// @dev Not a v4 exact-output quote, on purpose. Every settlement path here — the router,
    ///      an aggregator's swap action — is exact-input, and `ProtocolFeeHook` charges its
    ///      skim on a different LEG in the two modes: it always takes the unspecified currency,
    ///      which is the output of an exact-input swap and the input of an exact-output one. A
    ///      v4 exact-output figure settled exact-input therefore lands short, because the skim
    ///      the quote billed on the input is never charged and the skim on the output never
    ///      was. `_grossInputFor` inverts the exact-input path instead.
    function quoteBuyExactOut(uint256 marketId, uint256 assetOut)
        external
        returns (uint256 reserveAssetIn, uint256 gasEstimate)
    {
        if (assetOut == 0) revert ZeroAmount();
        (AssetMarketFactory.Market memory m, SharedReservePool pool) = _marketAndReserve(marketId);

        (reserveAssetIn, gasEstimate) =
            _grossInputFor(factory.poolKeyOf(marketId), m.brandToken, m.asset, assetOut);

        uint256 capacity = maxMint(pool);
        if (reserveAssetIn > capacity) revert MintCapacityExceeded(reserveAssetIn, capacity);
    }

    /// @notice Least market asset that, sold through `sellForUsdg` (or any exact-input
    ///         settlement plus `redeem`), delivers at least `reserveAssetOut` of the reserve
    ///         asset. See `quoteBuyExactOut` for why this is not a v4 exact-output quote.
    function quoteSellExactOut(uint256 marketId, uint256 reserveAssetOut)
        external
        returns (uint256 assetIn, uint256 brandNeeded, uint256 gasEstimate)
    {
        if (reserveAssetOut == 0) revert ZeroAmount();
        (AssetMarketFactory.Market memory m, SharedReservePool pool) = _marketAndReserve(marketId);

        brandNeeded = brandForRedeem(pool, reserveAssetOut);
        (assetIn, gasEstimate) =
            _grossInputFor(factory.poolKeyOf(marketId), m.asset, m.brandToken, brandNeeded);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev The least exact-input amount of `tokenIn` whose swap yields at least `amountOut`.
    ///
    ///      **Three steps, and the third is the one that earns its keep.** Exact-input
    ///      settlement pays the hook out of the OUTPUT, so the pool has to produce
    ///      `_grossFor(amountOut)` for `amountOut` to survive the skim. A v4 exact-output quote
    ///      for that gross figure reports what the pool needs PLUS the skim the hook charges in
    ///      exact-output mode — where the unspecified currency is the input, so the quoter
    ///      bills for it. That addition does not exist on the settlement path, so `_netFor`
    ///      strips it back out and leaves the pool's own input. That figure is then put through
    ///      a real exact-input quote, because v4's swap math rounds in the pool's favour in
    ///      both directions and the two modes can disagree by a unit. A retry raises the pool's
    ///      input by that unit; two rounds is the bound, because the disagreement is one unit
    ///      of pool rounding and not an open-ended search.
    ///
    ///      **Why two corrections survive, when the hook now has exactly one rule.** They are
    ///      not two cases. There is no branch here on swap direction, on `zeroForOne`, or on
    ///      which token is which — one straight line of arithmetic runs for every market and
    ///      every direction, which is the property that made the old asymmetry collapse.
    ///
    ///      What forces two terms instead of one is that this function QUOTES in the opposite
    ///      mode from the one it settles in, and "the unspecified currency" names a different
    ///      leg in each. That is v4's definition, not the hook's: `amountSpecified` is the
    ///      input of an exact-input swap and the output of an exact-output one, so a single
    ///      rule — always charge the unspecified leg — lands on the output when we settle and
    ///      on the input when we quote. `_grossFor` translates the target across that
    ///      boundary, `_netFor` translates the answer back. Collapsing them would require a
    ///      quote taken in the settlement mode, which is precisely what is unavailable: an
    ///      exact-input quoter answers "how much out for this in", and the caller is asking
    ///      the other question.
    ///
    ///      The corollary, for whoever changes the hook next: if the hook ever stops charging
    ///      the unspecified currency uniformly, BOTH terms here are wrong at once and the
    ///      symptom is not a few mis-quoted pips. The candidate input misses by the fee, the
    ///      output comes back short by the fee squared, the one-unit retry cannot close a gap
    ///      that size, and every exact-out quote reverts `QuoteUnavailable`. That is how this
    ///      was found; the lens test suite is the tripwire.
    function _grossInputFor(
        PoolKey memory key,
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) private returns (uint256 amountIn, uint256 gasEstimate) {
        uint256 fee = factory.feeHook().feePipsFor(key.toId());

        // What the pool must produce for `amountOut` to survive the skim on the way out.
        uint256 grossOut = _grossFor(amountOut, PIPS, fee);

        (uint256 total,) = _quoteExactOut(key, tokenOut, grossOut);
        uint256 net = _netFor(total, PIPS, fee);

        for (uint256 attempt; attempt < 2; ++attempt) {
            amountIn = net;

            uint256 got;
            (got, gasEstimate) = _quoteExactIn(key, tokenIn, amountIn);
            if (got >= amountOut) return (amountIn, gasEstimate);
            net++;
        }
        revert QuoteUnavailable(amountOut);
    }

    function _quoteExactIn(PoolKey memory key, address tokenIn, uint256 amountIn)
        private
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        return quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: tokenIn == Currency.unwrap(key.currency0),
                exactAmount: _toUint128(amountIn),
                hookData: ""
            })
        );
    }

    function _quoteExactOut(PoolKey memory key, address tokenOut, uint256 amountOut)
        private
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        return quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                // Selling currency0 buys currency1: zeroForOne iff the OUTPUT is currency1.
                zeroForOne: tokenOut == Currency.unwrap(key.currency1),
                exactAmount: _toUint128(amountOut),
                hookData: ""
            })
        );
    }

    function _toUint128(uint256 amount) private pure returns (uint128) {
        if (amount > type(uint128).max) revert AmountTooLarge(amount);
        return uint128(amount);
    }
}
