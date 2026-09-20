// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ReentrancyGuardSlot
/// @notice OpenZeppelin's reentrancy guard, moved onto a fixed ERC-7201 slot.
///
///         **Why not use theirs.** `ReentrancyGuard` keeps its flag in a plain state variable,
///         which lands at whatever slot the inheritance order puts it at. Behind a proxy that
///         makes the guard part of the storage layout, so reordering a base contract silently
///         moves it onto something else. `ReentrancyGuardTransient` fixes that with `TSTORE`,
///         but that opcode needs an EVM at Cancun or later and this deploys to a chain whose
///         level is not something to assume. This is the same logic on a fixed slot, so it
///         costs nothing in layout and requires nothing of the EVM.
abstract contract ReentrancyGuardSlot {
    /// @dev keccak256(abi.encode(uint256(keccak256("stables.storage.ReentrancyGuard")) - 1)) & ~0xff
    bytes32 private constant REENTRANCY_STORAGE =
        0xf5000d51528b996486d13ce983cec6e13a4e69daca6fa910e12cccf451d33e00;

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    error ReentrantCall();

    function _status() private pure returns (uint256 slot) {
        slot = uint256(REENTRANCY_STORAGE);
    }

    modifier nonReentrant() {
        uint256 slot = _status();
        uint256 current;
        assembly ("memory-safe") {
            current := sload(slot)
        }
        // Zero is the uninitialised state, which a proxy's storage starts in and which means
        // "not entered" just as surely as the explicit value does. Treating it as entered would
        // brick every guarded function on a freshly deployed instance.
        if (current == ENTERED) revert ReentrantCall();
        assembly ("memory-safe") {
            sstore(slot, ENTERED)
        }
        _;
        assembly ("memory-safe") {
            sstore(slot, NOT_ENTERED)
        }
    }
}
