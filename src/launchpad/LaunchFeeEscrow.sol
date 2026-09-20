// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2FeeEscrow.sol), MIT.

import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ILaunchFeeEscrow} from "./interfaces/ILaunchpad.sol";

/// @title LaunchFeeEscrow
/// @notice Holds every launchpad recipient's claimable balance in one place, so the protocol
///         and creators claim revenue from across all of their launches in a single transaction
///         instead of collecting per curve or per locked position. Revenue arrives in whatever
///         ERC-20 the launch trades against: the brand the curve is quoted in before
///         graduation, and the market unit (plus the launch token itself) afterwards. Both the
///         bonding curve and `LaunchLocker` credit the same way, so a recipient's balance is
///         denominated identically before and after graduation.
///
///         Every quote asset here is an ERC-20; there is no native-ETH ledger.
contract LaunchFeeEscrow is ReentrancyGuard, ILaunchFeeEscrow {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NoBalance();
    error InsufficientBalance(uint256 requested, uint256 available);

    event CreditedToken(
        address indexed recipient, address indexed token, address indexed depositor, uint256 amount
    );
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;

    /// @notice Pulls `amount` of `token` from the caller and credits it to `recipient`.
    /// @dev Permissionless by design: the caller can only credit tokens they already hold and
    ///      approve, so there is no privilege to gate. Credits the actual balance delta rather
    ///      than the nominal `amount`, so a fee-on-transfer or deflationary pairToken can never
    ///      make this contract record more credited liability than it actually holds, which
    ///      would otherwise starve whichever recipient claims that token last.
    function creditToken(address recipient, address token, uint256 amount) external nonReentrant {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) return;
        _tokenBalances[recipient][token] += received;
        emit CreditedToken(recipient, token, msg.sender, received);
    }

    /// @notice Pays out the caller's entire claimable balance of `token`.
    function claimToken(address token) external nonReentrant returns (uint256 amount) {
        amount = _claimToken(token, _tokenBalances[msg.sender][token]);
    }

    /// @notice Pays out `amount` of the caller's claimable balance of `token`.
    /// @dev A recipient's balance aggregates credits from every launch, curve and locked
    ///      position, and `creditToken` is permissionless, so a third party can enlarge that
    ///      figure at will. Against a token with a fixed maximum per transfer, a single
    ///      full-balance claim would then revert and leave the recipient unable to draw any of
    ///      it. Choosing the amount keeps the aggregate from being a single point of failure,
    ///      and lets a recipient work around any per-transfer limit its quote asset imposes.
    function claimToken(address token, uint256 amount) external nonReentrant returns (uint256) {
        return _claimToken(token, amount);
    }

    /// @dev Shared debit path for both claim entry points.
    function _claimToken(address token, uint256 amount) private returns (uint256) {
        if (amount == 0) revert NoBalance();
        uint256 balance = _tokenBalances[msg.sender][token];
        if (amount > balance) revert InsufficientBalance(amount, balance);

        _tokenBalances[msg.sender][token] = balance - amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit ClaimedToken(msg.sender, token, amount);
        return amount;
    }

    /// @notice Returns the claimable balance of `token` for `recipient`.
    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokenBalances[recipient][token];
    }
}
