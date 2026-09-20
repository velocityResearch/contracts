// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IV4Quoter
/// @notice The single-pool half of Uniswap's `V4Quoter`, written out against this repo's
///         `v4-core`.
///
///         **This is test material, not production material.** `MarketLens` used to call the
///         deployed quoter; it now replays the swap itself (`V4SwapSimulator`) so that a
///         quote is a `view` an aggregator can `STATICCALL`. What the deployed quoter is still
///         good for is telling us whether that simulation is right, which is what
///         `test/markets/MarketLensSimulatorFork.t.sol` uses it for: Uniswap's unmodified
///         contract is the reference, and any disagreement is our bug.
///
///         Hand-written for the reason `IPositionManagerV4` is: `lib/v4-periphery` vendors
///         its own v4-core and its own OpenZeppelin, and importing anything from it breaks the
///         build for the whole project. The quoter itself is deployed from that checkout by
///         `script/deploy-v4-lens.sh`, unmodified, and this is only its ABI. The struct below
///         is field-for-field `IV4Quoter.QuoteExactSingleParams`; the multi-hop
///         `PathKey` variants are left out because no market here is more than one pool deep.
///
///         **These are not `view`.** The quoter runs the real swap inside `PoolManager.unlock`
///         and reverts to unwind it, catching its own revert to read the delta out. Call them
///         with `eth_call`; never from a transaction that expects state to survive.
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    /// @notice What an exact-input swap of `exactAmount` through one pool would return.
    /// @return amountOut   Output after the hook's skim and the pool's LP fee
    /// @return gasEstimate Gas the swap itself consumed inside the quote
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice What an exact-output swap for `exactAmount` through one pool would cost.
    /// @return amountIn    Input required, hook skim included
    /// @return gasEstimate Gas the swap itself consumed inside the quote
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}
