// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICurveStableSwapNG
/// @notice The slice of a Curve StableSwap-NG plain pool this repo trades against. The
///         sUSDai/USDC pool on Arbitrum is `0xa7CF5543a27BaDC3a74d51EA0A02E84799140E4E`:
///         `coins(0)` = sUSDai (18 decimals), `coins(1)` = native USDC (6 decimals), `A` = 500,
///         `fee` = 1e6 (0.01%), and `stored_rates()` = [sUSDai deposit share price, 1e30] — the
///         pool prices sUSDai at its optimistic NAV through an oracle rate, so swaps in either
///         direction cost the pool fee plus curvature, not a NAV discount. Read back from chain
///         on 2026-09-13.
interface ICurveStableSwapNG {
    function coins(uint256 i) external view returns (address);

    function N_COINS() external view returns (uint256);

    /// @notice Output of swapping `dx` of coin `i` for coin `j`, after the pool fee.
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Swap `dx` of coin `i` for at least `minDy` of coin `j`, paid to the caller.
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);

    function stored_rates() external view returns (uint256[] memory);

    function balances(uint256 i) external view returns (uint256);

    function fee() external view returns (uint256);
}
