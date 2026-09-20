// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2GraduationGuard.sol), MIT.

import {Pool} from "v4-core/libraries/Pool.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {LaunchGraduationMath} from "./libraries/LaunchGraduationMath.sol";

/// @title LaunchGraduationGuard
/// @notice Stateless preflight for a graduation's Uniswap V4 seed. It keeps the tick and
///         liquidity math outside `LaunchFactory`'s runtime bytecode while modelling the
///         rejections of the real mint, so a launch can never drain its curve into a seed the
///         PositionManager or V4 core would reject.
///
///         The preflight has to mirror the whole downstream call graph rather than the
///         PositionManager's ABI field widths alone. Phase one is irreversible: it marks the
///         curve graduated and moves its reserves to the factory, so a seed that passes here
///         and reverts in V4 leaves the launch permanently unseedable and recoverable only
///         through the owner's delayed rescue path.
contract LaunchGraduationGuard {
    int24 private constant MIN_USABLE_TICK = -887272;
    int24 private constant MAX_USABLE_TICK = 887272;

    /// @dev V4 carries pool balance changes in a `BalanceDelta` whose halves are `int128`, and
    ///      `Pool.modifyLiquidity` narrows each side with `SafeCast.toInt128`. The
    ///      PositionManager's `MINT_POSITION` ABI accepts `uint128`, so an amount in between
    ///      passes every field-width check and still reverts inside V4 core. The signed bound
    ///      is the real one.
    uint256 private constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));

    error SqrtPriceOutOfBounds();
    error GraduationSeedNotViable();

    /// @notice Verifies a seed of these proportions mints under either currency ordering.
    /// @dev Launch terms are checked before the launch token exists, and the graduated pool's
    ///      unit does not exist until phase two creates it, so the ordering the PoolKey will
    ///      use is not known at either point. Requiring both is the conservative reading, and
    ///      the two agree in practice: the sqrt price range is symmetric about 1 and the
    ///      liquidity formula is invariant under inverting the price and swapping the amounts
    ///      with it.
    /// @param tickSpacing Pool tick spacing the position spans.
    /// @param quoteAmount Quote side of the seed.
    /// @param tokenAmount Launch-token side of the seed.
    function assertSeedableEitherOrdering(
        int24 tickSpacing,
        uint256 quoteAmount,
        uint256 tokenAmount
    ) external pure {
        if (quoteAmount > MAX_SEED_AMOUNT || tokenAmount > MAX_SEED_AMOUNT) {
            revert GraduationSeedNotViable();
        }
        _assertSeedable(tickSpacing, quoteAmount, tokenAmount);
        _assertSeedable(tickSpacing, tokenAmount, quoteAmount);
    }

    /// @notice Verifies a full-range mint of `amount0`/`amount1` into a pool already priced at
    ///         `sqrtPriceX96` produces liquidity V4 will accept.
    /// @dev For the executor, which mints against the price the market factory initialised the
    ///      pool at rather than one derived from the amounts.
    function assertSeedableAtPrice(
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) external pure {
        if (amount0 > MAX_SEED_AMOUNT || amount1 > MAX_SEED_AMOUNT) {
            revert GraduationSeedNotViable();
        }
        _assertLiquidity(tickSpacing, sqrtPriceX96, amount0, amount1);
    }

    /// @dev Models the price and liquidity rejections of the real mint for one currency
    ///      ordering. Amount bounds are the caller's to enforce.
    function _assertSeedable(int24 tickSpacing, uint256 amount0, uint256 amount1) private pure {
        uint160 sqrtPriceX96 = LaunchGraduationMath.sqrtPriceX96FromAmounts(amount0, amount1);
        _assertLiquidity(tickSpacing, sqrtPriceX96, amount0, amount1);
    }

    function _assertLiquidity(
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) private pure {
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfBounds();
        }

        (int24 tickLower, int24 tickUpper) = _fullRangeTicks(tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        // This mint initializes both boundary ticks, so the position's own liquidity is the
        // entire `liquidityGross` at each of them. V4 reverts with TickLiquidityOverflow once
        // a tick's gross liquidity passes the cap its spacing implies, which is an independent
        // rejection from the amount bounds above.
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)) {
            revert GraduationSeedNotViable();
        }
    }

    /// @dev Derives V4's usable full-range ticks for the configured spacing.
    function _fullRangeTicks(int24 tickSpacing)
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Truncation toward zero is required to derive V4's usable boundary ticks.
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (MIN_USABLE_TICK / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (MAX_USABLE_TICK / tickSpacing) * tickSpacing;
    }
}
