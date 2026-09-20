// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IAcrossSpokePool} from "../../src/interfaces/IAcrossSpokePool.sol";

/// @notice An Across SpokePool that escrows the input token, keeps the real pool's two timing
///         checks, and records every deposit so a test can read back exactly what was asked
///         of it. `refund` hands an escrowed deposit back to its depositor, which is what the
///         real pool's root bundle does for a deposit nobody filled.
contract MockAcrossSpokePool is IAcrossSpokePool {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    uint32 public numberOfDeposits;
    uint32 public constant depositQuoteTimeBuffer = 3600;
    uint32 public constant fillDeadlineBuffer = 21600;

    mapping(uint32 depositId => Deposit) public deposits;

    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();

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
    ) external payable {
        uint256 now_ = getCurrentTime();
        if (now_ < quoteTimestamp || now_ - quoteTimestamp > depositQuoteTimeBuffer) {
            revert InvalidQuoteTimestamp();
        }
        if (fillDeadline < now_ || fillDeadline > now_ + fillDeadlineBuffer) {
            revert InvalidFillDeadline();
        }
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        deposits[numberOfDeposits] = Deposit({
            depositor: depositor,
            recipient: recipient,
            inputToken: inputToken,
            outputToken: outputToken,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            destinationChainId: destinationChainId,
            exclusiveRelayer: exclusiveRelayer,
            quoteTimestamp: quoteTimestamp,
            fillDeadline: fillDeadline,
            exclusivityDeadline: exclusivityDeadline,
            message: message
        });
        numberOfDeposits += 1;
    }

    /// @notice Return an unfilled deposit's input to its depositor, as the real bridge does
    ///         after `fillDeadline` passes without a fill.
    function refund(uint32 depositId) external {
        Deposit memory d = deposits[depositId];
        require(d.depositor != address(0), "unknown deposit");
        delete deposits[depositId];
        IERC20(d.inputToken).safeTransfer(d.depositor, d.inputAmount);
    }

    function getCurrentTime() public view returns (uint256) {
        return block.timestamp;
    }

    function lastDeposit() external view returns (Deposit memory) {
        return deposits[numberOfDeposits - 1];
    }
}
