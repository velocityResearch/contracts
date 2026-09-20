// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAcrossSpokePool
/// @notice The slice of an Across V3 `SpokePool` this repo calls. Robinhood Chain (4663) and
///         Arbitrum (42161) both run one:
///
///         - Robinhood: `0xD29C85F15DF544bA632C9E25829fd29d767d7978`
///         - Arbitrum:  `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A`
///
///         Read back from chain on 2026-09-13: both report `depositQuoteTimeBuffer() == 3600`
///         and `fillDeadlineBuffer() == 21600`, and `app.across.to/api/swap/approval` returns a
///         direct SpokePool deposit against these addresses for USDG(4663) <-> USDC(42161) with
///         the cross-currency leg priced by the relayer ("bridgeableToBridgeable", ~6 bps). No
///         periphery contract sits in the path, which is why our contracts can call the
///         SpokePool directly with quote parameters the keeper fetched off chain.
///
///         The API's calldata is the newer `deposit(bytes32 ...)` (selector `0xad5425c6`); this
///         interface uses the address-typed `depositV3` (`0x7b939232`), which both SpokePools
///         still expose with the same twelve parameters and forward to it. Verified by calling
///         it on forks of both chains.
interface IAcrossSpokePool {
    /// @notice Escrow `inputAmount` of `inputToken` here; a relayer delivers `outputAmount` of
    ///         `outputToken` to `recipient` on `destinationChainId`. If nobody fills by
    ///         `fillDeadline`, `depositor` is refunded `inputToken` on this chain by the next
    ///         root bundle — which is why our contracts always pass themselves as `depositor`.
    /// @param quoteTimestamp       Must be within `depositQuoteTimeBuffer()` of `getCurrentTime()`.
    /// @param fillDeadline         Must not exceed `getCurrentTime() + fillDeadlineBuffer()`.
    /// @param exclusivityDeadline  Below one year it is an offset in seconds from now, else an
    ///                             absolute timestamp; zero disables relayer exclusivity.
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    /// @notice Monotonic deposit counter. The next `depositV3` takes this value as its
    ///         `depositId`, which is how a keeper matches a fill on the other chain.
    function numberOfDeposits() external view returns (uint32);

    function depositQuoteTimeBuffer() external view returns (uint32);

    function fillDeadlineBuffer() external view returns (uint32);

    function getCurrentTime() external view returns (uint256);
}
