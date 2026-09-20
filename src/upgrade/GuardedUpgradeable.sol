// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {IProtocolGuard} from "./IProtocolGuard.sol";

/// @title GuardedUpgradeable
/// @notice Gives a contract a `whenNotPaused` modifier backed by the protocol's shared
///         `ProtocolGuard`, rather than by a pause flag of its own.
///
///         **Namespaced storage, on purpose.** This is a base contract, and base contracts are
///         where upgrade accidents live: add a variable to one, and every child's storage
///         shifts underneath a proxy that is still holding the old layout. Keeping the single
///         field at a fixed ERC-7201 slot means this contract occupies no space in any child's
///         layout at all, so a child can be rearranged, and this can gain fields, without the
///         two ever colliding.
abstract contract GuardedUpgradeable is Initializable {
    /// @custom:storage-location erc7201:stables.storage.Guarded
    struct GuardedStorage {
        IProtocolGuard guard;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("stables.storage.Guarded")) - 1)) & ~0xff
    bytes32 private constant GUARDED_STORAGE =
        0x0d34567d45f6e039f93370f198968e007742b6f7410357ce5e01cd730385a400;

    error ZeroGuard();

    function _guardedStorage() private pure returns (GuardedStorage storage $) {
        assembly ("memory-safe") {
            $.slot := GUARDED_STORAGE
        }
    }

    function __Guarded_init(address _guard) internal onlyInitializing {
        if (_guard == address(0)) revert ZeroGuard();
        _guardedStorage().guard = IProtocolGuard(_guard);
    }

    /// @notice The pause registry this contract obeys.
    function guard() public view returns (IProtocolGuard) {
        return _guardedStorage().guard;
    }

    /// @notice Whether this specific contract is currently halted.
    function paused() public view returns (bool) {
        return _guardedStorage().guard.isPaused(address(this));
    }

    /// @dev Reverts with `ProtocolGuard.ProtocolPaused` rather than an error of this contract's
    ///      own, so every halted call in the system fails the same identifiable way.
    modifier whenNotPaused() {
        _guardedStorage().guard.requireNotPaused(address(this));
        _;
    }
}
