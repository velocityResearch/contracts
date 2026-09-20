// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {IAcrossSpokePool} from "../interfaces/IAcrossSpokePool.sol";

/// @title AcrossBridger
/// @notice The one way this repo moves stablecoins between Robinhood Chain and Arbitrum: an
///         Across V3 `depositV3` with a quote the keeper fetched off chain and a fee bound the
///         owner set on chain.
///
///         **What the keeper supplies and what it cannot decide.** Across prices a deposit off
///         chain — `outputAmount`, `quoteTimestamp`, `fillDeadline` and the exclusive relayer
///         come from `app.across.to/api/swap/approval` — so those are arguments. Everything a
///         compromised keeper could profit from is fixed by the inheriting contract instead:
///         the input token, the output token, the destination chain and the recipient are the
///         inheritor's own configuration — not keeper arguments — and `outputAmount` must clear
///         a floor of `inputAmount` less `maxFeeBps`. The only remaining freedom is *when* and
///         *how much* to bridge, and both ends of the bridge belong to this protocol.
///
///         **Refunds.** `depositor` is always `address(this)`. A deposit no relayer fills by
///         `fillDeadline` is refunded in `inputToken` to the depositor on the origin chain, so
///         a stuck bridge returns funds to the contract that sent them — never to the keeper.
///
///         Input and output are assumed to share decimals (USDG, USDC: both 6), which is what
///         makes the fee floor a plain subtraction.
///
/// @dev **Upgradeable base.** Inheritors live behind UUPS proxies, so this holds `spokePool` in
///      plain storage rather than as an `immutable`: an immutable lives in the implementation's
///      code, and a contract whose configuration is split between proxy and implementation has
///      to be re-supplied — correctly — on every upgrade. Storage keeps it in one place.
///
///      Being a base, its fields sit at the FRONT of every inheritor's layout, so a field added
///      here would shift every child's state underneath a live proxy. `__gap` below is the room
///      for that; adding a field without consuming a gap slot is an upgrade bug, not a tweak.
abstract contract AcrossBridger is Initializable {
    using SafeERC20 for IERC20;

    /// @notice The parts of an Across quote that vary per deposit. Fetched by the keeper from
    ///         the Across API immediately before calling; the SpokePool rejects stale ones.
    struct AcrossQuote {
        /// @dev What the relayer delivers on the destination chain. Same decimals as the input.
        uint256 outputAmount;
        /// @dev Relayer with a head start, or zero for open competition.
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
    }

    uint256 internal constant BPS = 10_000;

    /// @notice The Across V3 SpokePool this contract escrows deposits with. Slot 0 of every
    ///         inheritor. Changing it requires an upgrade, which only the owner can authorize.
    IAcrossSpokePool public spokePool;

    /// @dev Reserved for later versions of this base. See the layout note in the contract docs.
    uint256[9] private __gap;

    event Bridged(
        uint32 indexed depositId,
        address indexed recipient,
        uint256 indexed destinationChainId,
        address inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 outputAmount
    );

    error BridgeOutputBelowFloor(uint256 outputAmount, uint256 floor);
    error ZeroAddress();
    error ZeroAmount();

    /// @dev Same zero-address rejection the constructor performed, moved to the initializer.
    function __AcrossBridger_init(address _spokePool) internal onlyInitializing {
        if (_spokePool == address(0)) revert ZeroAddress();
        spokePool = IAcrossSpokePool(_spokePool);
    }

    /// @dev Escrow `inputAmount` of `inputToken` with the SpokePool for delivery of
    ///      `q.outputAmount` of `outputToken` to `recipient` on `destinationChainId`.
    /// @return depositId The SpokePool's id for this deposit, for matching the fill.
    function _bridge(
        IERC20 inputToken,
        uint256 inputAmount,
        address outputToken,
        uint256 destinationChainId,
        address recipient,
        uint16 maxFeeBps,
        AcrossQuote calldata q
    ) internal returns (uint32 depositId) {
        if (inputAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 floor = inputAmount - inputAmount * maxFeeBps / BPS;
        if (q.outputAmount < floor) revert BridgeOutputBelowFloor(q.outputAmount, floor);

        depositId = spokePool.numberOfDeposits();
        inputToken.forceApprove(address(spokePool), inputAmount);
        spokePool.depositV3(
            address(this),
            recipient,
            address(inputToken),
            outputToken,
            inputAmount,
            q.outputAmount,
            destinationChainId,
            q.exclusiveRelayer,
            q.quoteTimestamp,
            q.fillDeadline,
            q.exclusivityDeadline,
            ""
        );

        emit Bridged(
            depositId,
            recipient,
            destinationChainId,
            address(inputToken),
            inputAmount,
            outputToken,
            q.outputAmount
        );
    }
}
