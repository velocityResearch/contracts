// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Canonical WETH9: an ERC-20 plus the two functions that make it one.
///
///         `deposit` and `withdraw` are not part of any ERC-20, so they need declaring, and
///         `withdraw` sends raw ETH with a bare `transfer` — 2300 gas, no calldata — which is why
///         a contract that calls it has to carry a `receive()` able to run in that budget.
///
///         On Robinhood Chain mainnet WETH9 is at `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`.
///         Nothing here hardcodes it: it is read off `SwapRouter02.WETH9()` at construction, so
///         the wrapper a zap uses is by definition the one the router it swaps through accepts.
interface IWETH9 is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
