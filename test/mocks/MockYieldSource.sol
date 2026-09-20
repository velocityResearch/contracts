// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";

/// @title MockYieldSource
/// @notice Simulates a yield source (like Aave) with controllable yield for testing.
///         Uses an index that grows with yield so balances appreciate automatically.
///         This mirrors how aTokens work: 1 aUSDC becomes worth >1 USDC over time.
contract MockYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    /// @notice The index: how much 1 unit of principal is worth now (scaled by 1e18)
    ///         Starts at 1e18 (= 1:1). Grows when yield is simulated.
    uint256 public index = 1e18;

    /// @notice Principal deposited by each user for each asset (in "index units")
    mapping(address asset => mapping(address user => uint256 principal)) public principalOf;

    /// @notice Total principal across all users for each asset
    mapping(address asset => uint256 totalPrincipal) public totalPrincipalOf;

    /// @dev Simulate yield accrual — adds `amount` of yield, increasing the index proportionally
    function simulateYield(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 total = totalPrincipalOf[asset];
        if (total > 0) {
            // index_new = index_old + amount * 1e18 / totalPrincipal
            index += amount * 1e18 / total;
        }
    }

    /// @inheritdoc IYieldSource
    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // Convert deposit amount to principal units
        uint256 principal = amount * 1e18 / index;
        principalOf[asset][msg.sender] += principal;
        totalPrincipalOf[asset] += principal;
    }

    /// @inheritdoc IYieldSource
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // Convert withdrawal amount to principal units
        uint256 principalNeeded = amount * 1e18 / index;
        uint256 userPrincipal = principalOf[asset][msg.sender];

        // Cap at user's balance
        if (principalNeeded > userPrincipal) {
            principalNeeded = userPrincipal;
            // Recalculate actual amount from capped principal
            amount = principalNeeded * index / 1e18;
        }

        principalOf[asset][msg.sender] -= principalNeeded;
        totalPrincipalOf[asset] -= principalNeeded;

        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    /// @inheritdoc IYieldSource
    function balanceOf(address asset) external view returns (uint256) {
        return principalOf[asset][msg.sender] * index / 1e18;
    }

    /// @inheritdoc IYieldSource
    function totalAssets(address asset) external view returns (uint256) {
        return totalPrincipalOf[asset] * index / 1e18;
    }

    /// @inheritdoc IYieldSource
    /// @dev Fully liquid: everything owed is on hand.
    function withdrawable(address asset, address consumer) external view returns (uint256) {
        return principalOf[asset][consumer] * index / 1e18;
    }
}
