// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IV4Quoter} from "../../src/interfaces/IV4Quoter.sol";

/// @dev **A stand-in for Uniswap's `V4Quoter`, not the real one.** The real contract cannot be
///      compiled into this repo — `lib/v4-periphery` vendors its own v4-core — so the offline
///      suite talks to this, and the deployed quoter is exercised on a fork. What this keeps
///      faithful is the part `MarketLens` depends on: the quote is the pool's real `swap`,
///      hook deltas included, unwound by a revert; a pool that cannot fill the whole specified
///      amount is `NotEnoughLiquidity`, never a partial number; and neither function is `view`.
///
///      What it omits is the real quoter's `Locker`/`IMsgSender` plumbing, which exists so a
///      hook can learn who asked. Immaterial here by construction: `ProtocolFeeHook.beforeSwap`
///      and `afterSwap` both ignore their `sender` argument, so no quote against these pools
///      can depend on it.
contract StandInV4Quoter is IV4Quoter, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;

    error QuoteSwap(uint256 amount);
    error NotEnoughLiquidity(PoolId poolId);
    error UnexpectedCallSuccess();
    error OnlyPoolManager();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        return _quote(params, -int256(uint256(params.exactAmount)));
    }

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        return _quote(params, int256(uint256(params.exactAmount)));
    }

    function _quote(QuoteExactSingleParams memory params, int256 amountSpecified)
        private
        returns (uint256 amount, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(params, amountSpecified)) {
            revert UnexpectedCallSuccess();
        } catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            if (reason.length == 36 && bytes4(reason) == QuoteSwap.selector) {
                assembly ("memory-safe") {
                    amount := mload(add(reason, 36))
                }
            } else {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (QuoteExactSingleParams memory params, int256 amountSpecified) =
            abi.decode(data, (QuoteExactSingleParams, int256));

        BalanceDelta delta = poolManager.swap(
            params.poolKey,
            SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: params.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            params.hookData
        );

        // Same check as `BaseV4Quoter._swap`: the specified side must have been filled whole.
        bool specifiedIsZero = params.zeroForOne == (amountSpecified < 0);
        int128 specifiedActual = specifiedIsZero ? delta.amount0() : delta.amount1();
        if (specifiedActual != amountSpecified) revert NotEnoughLiquidity(params.poolKey.toId());

        int128 unspecified = specifiedIsZero ? delta.amount1() : delta.amount0();
        // Exact-in reports the positive output; exact-out reports the (negated) input.
        uint256 quoted =
            amountSpecified < 0 ? uint256(uint128(unspecified)) : uint256(uint128(-unspecified));
        revert QuoteSwap(quoted);
    }
}
