// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IPoolOracle
/// @notice The price history a v4 pool does not keep for itself.
///
///         Uniswap V3 pools carried their own observation ring buffer and exposed `observe`.
///         **V4 deleted it.** Observations are gone from core on purpose — Uniswap decided an
///         oracle is a hook's concern, so a v4 pool has a spot price and nothing else.
///
///         That is a problem for anything that needs a manipulation-resistant reference, which
///         here means `BuybackEngine`: its whole defence is that it prices a round against a
///         TWAP rather than spot, so a manipulated pool costs it a partial fill instead of a
///         bad price. This interface is what replaces `IUniswapV3PoolLike.observe` for that
///         purpose, and `ProtocolFeeHook` implements it — the hook already runs on every swap,
///         so it is the natural place and the marginal cost is one storage write.
///
///         Consumers depend on this interface rather than on the hook directly, so that the
///         oracle and the fee skim can be separated later without touching them.
interface IPoolOracle {
    /// @notice Cumulative ticks at each of `secondsAgos` seconds before now, newest last.
    ///         Same shape and same conventions as Uniswap V3's `observe`.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives);

    /// @notice The arithmetic mean tick over the last `window` seconds.
    /// @dev    Floors toward negative infinity, matching `OracleLibrary.consult`. Reverts if
    ///         the buffer does not reach back `window` seconds, which is the case a caller
    ///         must distinguish from a genuine price rather than treat as zero.
    function consultTick(PoolKey calldata key, uint32 window)
        external
        view
        returns (int24 arithmeticMeanTick);

    /// @notice Where a pool's ring buffer currently stands.
    function observationState(PoolId id)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

    /// @notice Grow a pool's buffer so it can reach further back. Permissionless, as in V3:
    ///         anyone who needs a longer window on a market should be able to pay for it.
    function increaseObservationCardinalityNext(PoolKey calldata key, uint16 next)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);
}
