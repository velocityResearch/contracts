// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BitMath} from "v4-core/libraries/BitMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @title V4SwapSimulator
/// @notice A `view` reimplementation of one `PoolManager.swap` against a `ProtocolFeeHook`
///         pool, so a quote can be taken with `STATICCALL`.
///
///         **Why this exists.** Uniswap's `V4Quoter` runs the real swap inside
///         `PoolManager.unlock` and reverts to unwind it, which makes it state-mutating: it
///         cannot be reached from a `view` function, from another contract's `STATICCALL`, or
///         from inside an unlock someone else already opened. Every aggregator that samples
///         venues in one batched call does exactly that, so a quoter that only answers a
///         top-level `eth_call` is a venue that cannot be sampled. This library reads the pool
///         through `StateLibrary` — `extsload`, a plain view — and replays the swap in memory.
///
///         **It is a copy, and that is the point.** The loop below is
///         `Pool.swap` (`lib/v4-core/src/libraries/Pool.sol:279-463`) with the storage writes
///         and the fee-growth accounting removed, because neither changes an amount. Every
///         arithmetic step is v4-core's own library code — `SwapMath.computeSwapStep`,
///         `TickMath`, `LiquidityMath` — called with the same arguments in the same order, so
///         the rounding is core's rounding rather than a restatement of it. The price limit is
///         `V4Quoter`'s (`MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`), and the shortfall check
///         is `BaseV4Quoter._swap`'s, reverting the same `NotEnoughLiquidity(PoolId)` rather
///         than returning a partial fill.
///
///         The one thing a copy cannot inherit is a later upgrade to core. `PoolManager` is
///         immutable and unowned on this chain, so there is no upgrade to track; a *new*
///         manager would mean new pools and a new `PoolKey`, which this contract's caller
///         reads from the factory anyway. What would silently break it is a change to the
///         HOOK's fee rule, which is why `hookFeePips` is a parameter and why the fee is
///         applied here exactly as `ProtocolFeeHook.afterSwap` applies it — one rule, on the
///         unspecified leg, floored.
///
///         **Not modelled, because these pools cannot express it.** A `beforeSwap` LP-fee
///         override (`ProtocolFeeHook` returns 0 unconditionally), a `beforeSwapReturnDelta`
///         that moves the specified amount (it returns `ZERO_DELTA` unconditionally), and
///         dynamic fees (no market pool is created with `DYNAMIC_FEE_FLAG`). A hook that did
///         any of those would need this library changed alongside it.
library V4SwapSimulator {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @dev `ProtocolFeeHook.PIPS_DENOMINATOR`.
    uint256 private constant PIPS = 1_000_000;

    /// @notice The pool cannot fill the whole specified amount. Same name, same argument and
    ///         therefore the same selector as `BaseV4Quoter.NotEnoughLiquidity`, so an
    ///         integrator's existing handler decodes it unchanged.
    error NotEnoughLiquidity(PoolId poolId);
    /// @notice No pool exists at this key, or it was never initialised.
    error PoolNotInitialized(PoolId poolId);

    /// @notice What an exact-input swap of `amountIn` would pay out, hook skim included.
    /// @param hookFeePips The hook's live rate — `ProtocolFeeHook.feePipsFor(poolId)`, never
    ///        the raw mapping, which ignores registration and the pause.
    /// @return amountOut     What the swapper receives, after the LP fee and the hook's skim
    /// @return ticksCrossed  Initialised ticks the fill walked through
    function quoteExactInputSingle(
        IPoolManager manager,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint24 hookFeePips
    ) internal view returns (uint256 amountOut, uint256 ticksCrossed) {
        (int256 amount0, int256 amount1, uint256 crossed) =
            _swap(manager, key, zeroForOne, -int256(amountIn), hookFeePips);

        // The specified leg is the input. A short fill is `NotEnoughLiquidity`, never a number.
        int256 specified = zeroForOne ? amount0 : amount1;
        if (specified != -int256(amountIn)) revert NotEnoughLiquidity(key.toId());

        return (uint256(zeroForOne ? amount1 : amount0), crossed);
    }

    /// @notice What an exact-output swap for `amountOut` would cost, hook skim included.
    /// @return amountIn      What the swapper pays, LP fee and hook skim included
    /// @return ticksCrossed  Initialised ticks the fill walked through
    function quoteExactOutputSingle(
        IPoolManager manager,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountOut,
        uint24 hookFeePips
    ) internal view returns (uint256 amountIn, uint256 ticksCrossed) {
        (int256 amount0, int256 amount1, uint256 crossed) =
            _swap(manager, key, zeroForOne, int256(amountOut), hookFeePips);

        // The specified leg is the output.
        int256 specified = zeroForOne ? amount1 : amount0;
        if (specified != int256(amountOut)) revert NotEnoughLiquidity(key.toId());

        return (uint256(-(zeroForOne ? amount0 : amount1)), crossed);
    }

    /// @dev `Pool.swap` without the writes, then `ProtocolFeeHook.afterSwap` on the result.
    ///      Returns the delta the SWAPPER sees, which is what `PoolManager.swap` returns to
    ///      its caller: core credits the hook's share to the hook and hands back
    ///      `swapDelta - hookDelta` (`Hooks.afterSwap`), so the skim is already inside these
    ///      numbers and a caller must not subtract it again.
    function _swap(
        IPoolManager manager,
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 hookFeePips
    ) private view returns (int256 amount0, int256 amount1, uint256 ticksCrossed) {
        PoolId id = key.toId();

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFeeBoth, uint24 lpFee) =
            manager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);

        uint256 protocolFee =
            zeroForOne ? protocolFeeBoth.getZeroForOneFee() : protocolFeeBoth.getOneForZeroFee();

        (amount0, amount1, ticksCrossed) = _fill(
            manager,
            id,
            key.tickSpacing,
            zeroForOne,
            amountSpecified,
            sqrtPriceX96,
            tick,
            protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee)
        );

        (amount0, amount1) =
            _applyHookFee(amount0, amount1, zeroForOne, amountSpecified, hookFeePips);
    }

    /// @dev The swap loop itself, lifted from `Pool.swap`. Split out only because the whole
    ///      thing in one frame does not fit in the stack.
    function _fill(
        IPoolManager manager,
        PoolId id,
        int24 tickSpacing,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 swapFee
    ) private view returns (int256 amount0, int256 amount1, uint256 ticksCrossed) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        uint128 liquidity = manager.getLiquidity(id);
        int256 remaining = amountSpecified;
        int256 calculated;

        while (!(remaining == 0 || sqrtPriceX96 == limit)) {
            uint160 startX96 = sqrtPriceX96;

            (int24 tickNext, bool initialized) =
                _nextInitializedTickWithinOneWord(manager, id, tick, tickSpacing, zeroForOne);
            if (tickNext <= TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
            if (tickNext >= TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

            uint160 nextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            uint256 amountIn;
            uint256 amountOut;
            uint256 feeAmount;
            (sqrtPriceX96, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(
                sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, nextX96, limit),
                liquidity,
                remaining,
                swapFee
            );

            unchecked {
                if (amountSpecified > 0) {
                    remaining -= int256(amountOut);
                    calculated -= int256(amountIn + feeAmount);
                } else {
                    remaining += int256(amountIn + feeAmount);
                    calculated += int256(amountOut);
                }
            }

            if (sqrtPriceX96 == nextX96) {
                if (initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(id, tickNext);
                    // Safe: `liquidityNet` cannot be `type(int128).min`, per `Pool.swap`.
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }
                    liquidity = LiquidityMath.addDelta(liquidity, liquidityNet);
                    ++ticksCrossed;
                }
                unchecked {
                    tick = zeroForOne ? tickNext - 1 : tickNext;
                }
            } else if (sqrtPriceX96 != startX96) {
                tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            }
        }

        // `Pool.swap`'s own ordering: "if currency1 is specified".
        if (zeroForOne != (amountSpecified < 0)) {
            amount0 = calculated;
            amount1 = amountSpecified - remaining;
        } else {
            amount0 = amountSpecified - remaining;
            amount1 = calculated;
        }
    }

    /// @dev `ProtocolFeeHook.afterSwap`, restated on the delta the pool produced.
    ///
    ///      Core decides which leg is unspecified with `amountSpecified < 0 == zeroForOne`,
    ///      and the hook returns a POSITIVE amount to mean "credit me, charge the swapper" in
    ///      both directions. `Hooks.afterSwap` then computes `swapDelta - hookDelta`, so the
    ///      swapper's figure for that one currency drops by the fee: an exact-input swap
    ///      receives less output, an exact-output swap owes more input.
    function _applyHookFee(
        int256 amount0,
        int256 amount1,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 hookFeePips
    ) private pure returns (int256, int256) {
        if (hookFeePips == 0) return (amount0, amount1);

        bool exactInput = amountSpecified < 0;
        bool unspecifiedIsCurrency1 = exactInput == zeroForOne;

        int256 unspecified = unspecifiedIsCurrency1 ? amount1 : amount0;
        int256 base = exactInput ? unspecified : -unspecified;
        // A fill of nothing costs nothing, which is the hook's own degenerate case.
        if (base <= 0) return (amount0, amount1);

        uint256 feeAmount = FullMath.mulDiv(uint256(base), hookFeePips, PIPS);
        if (feeAmount == 0) return (amount0, amount1);

        if (unspecifiedIsCurrency1) {
            amount1 -= int256(feeAmount);
        } else {
            amount0 -= int256(feeAmount);
        }
        return (amount0, amount1);
    }

    /// @dev `TickBitmap.nextInitializedTickWithinOneWord`, reading the word through
    ///      `StateLibrary` instead of a storage mapping. Identical arithmetic; the only change
    ///      is where the word comes from.
    function _nextInitializedTickWithinOneWord(
        IPoolManager manager,
        PoolId id,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) private view returns (int24 next, bool initialized) {
        unchecked {
            int24 compressed = _compress(tick, tickSpacing);

            if (lte) {
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = manager.getTickBitmap(id, wordPos) & mask;

                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked))))
                        * tickSpacing
                    : (compressed - int24(uint24(bitPos))) * tickSpacing;
            } else {
                (int16 wordPos, uint8 bitPos) = _position(++compressed);
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = manager.getTickBitmap(id, wordPos) & mask;

                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos)))
                        * tickSpacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
            }
        }
    }

    /// @dev `TickBitmap.compress`.
    function _compress(int24 tick, int24 tickSpacing) private pure returns (int24 compressed) {
        assembly ("memory-safe") {
            tick := signextend(2, tick)
            tickSpacing := signextend(2, tickSpacing)
            compressed := sub(sdiv(tick, tickSpacing), slt(smod(tick, tickSpacing), 0))
        }
    }

    /// @dev `TickBitmap.position`.
    function _position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            wordPos := sar(8, signextend(2, tick))
            bitPos := and(tick, 0xff)
        }
    }
}
