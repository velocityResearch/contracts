// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolGuard
/// @notice The read side of the protocol's pause registry, which is all any guarded contract
///         needs. Kept separate from the implementation so a market contract does not carry
///         the registry's own code, and so the registry can be upgraded without touching the
///         hundreds of contracts that read it.
interface IProtocolGuard {
    /// @notice Whether `target` is currently halted, whether by the global switch or its own.
    function isPaused(address target) external view returns (bool);

    /// @notice Revert if `target` is halted. The form guarded contracts actually call, so the
    ///         revert carries the registry's own error rather than a bare `false`.
    function requireNotPaused(address target) external view;

    /// @notice The address that may halt the protocol without waiting out the timelock.
    function guardian() external view returns (address);

    /// @notice The global switch. `isPaused` is this OR the target's own flag.
    function paused() external view returns (bool);
}
