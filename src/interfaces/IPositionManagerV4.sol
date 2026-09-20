// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IPositionManagerV4
/// @notice The slice of Uniswap's canonical v4 `PositionManager` that `MarketRouter` actually
///         uses, written out by hand rather than imported.
///
///         `lib/v4-periphery` vendors its own checkout of v4-core under `lib/v4-periphery/lib/`
///         and resolves it through a remapping of its own, while everything in `src/` compiles
///         against `lib/v4-core` through the `v4-core/` remapping. The two trees are
///         byte-identical today, but they are still *different types* to the compiler: a
///         `PoolKey` from one is not assignable to a `PoolKey` from the other, and importing
///         `PositionManager.sol` into production code would drag that second type tree into
///         every file that touches it. A hand-written interface keeps `src/` on exactly one copy
///         of v4-core and pays for it with a handful of function signatures — the same trade
///         this repo already made for Uniswap V3 in `src/interfaces/IUniswapV3.sol`.
///
///         Because most parameters are ABI-encoded blobs (`modifyLiquidities` takes actions and
///         their operands as `bytes`), the only v4 type that appears here is `PoolKey`, and it
///         is this repo's single copy of it.
interface IPositionManagerV4 {
    /// @notice Execute a batch of position actions, ABI-encoded as `(bytes actions, bytes[]
    ///         params)`, where `actions` is a `bytes` of one-byte action ids and `params[i]`
    ///         carries the operands of `actions[i]`.
    /// @dev    Tokens are pulled from `msg.sender` through Permit2, never through a plain
    ///         ERC-20 allowance on this contract — see `MarketRouter._approveThroughPermit2`.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    /// @notice The id the next minted position will receive.
    /// @dev    Read immediately before a mint to learn the id that mint will produce.
    ///         `modifyLiquidities` returns nothing, and the `Transfer` event is not reachable
    ///         from inside the call, so this is the only way to name the token we just created.
    function nextTokenId() external view returns (uint256);

    /// @notice The pool a position was minted into, and its packed range.
    /// @dev    The second return is v4-periphery's `PositionInfo`, a `uint256` whose layout is
    ///         `200 bits truncated poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits
    ///         hasSubscriber`. Taken as a plain `uint256` because the named type lives in the
    ///         periphery's own checkout; the ticks are read out with the shifts the periphery's
    ///         own library uses.
    ///
    ///         **The `PoolKey` is the thing to identify a pool by, not the packed id.** That id
    ///         is truncated to 25 bytes and is only the periphery's lookup key into its own
    ///         `poolKeys` mapping — it never equals a v4-core `PoolId`.
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);

    /// @notice The liquidity a position currently holds.
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);

    /// @notice ERC-721 transfer of a position.
    /// @dev    The real `PositionManager` reverts unless the caller owns or is approved for the
    ///         id, and silently unsubscribes any subscriber on the way through.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice ERC-721 ownership of a position.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice The v4 singleton this PositionManager was deployed against.
    /// @dev    Not needed to mint; needed to *check*. A PositionManager wired to a different
    ///         PoolManager would mint positions in pools this router's markets know nothing
    ///         about, so the constructor refuses that pairing outright.
    function poolManager() external view returns (address);
}

/// @title IPermit2
/// @notice Just the allowance-setting call of the canonical Permit2
///         (`0x000000000022D473030F116dDEE9F6B43aC78BA3`).
/// @dev    Permit2 is the only way `PositionManager` moves ERC-20s, so a contract that wants it
///         to pull tokens must approve twice: the token to Permit2, then Permit2 to the
///         PositionManager. This is the second of those.
interface IPermit2 {
    /// @param amount     Permit2 stores allowances as `uint160`; `type(uint160).max` is the
    ///                   "unlimited" sentinel that is never decremented.
    /// @param expiration `uint48` unix seconds; `type(uint48).max` never expires.
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
