// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title MockMorphoVault
/// @notice Simulates a Morpho Vault V2 (ERC-4626) for testing.
///         Wraps USDC. Share price appreciates when `simulateYield()` is called.
///         Mirrors how real Morpho Vaults allocate across lending markets.
contract MockMorphoVault is ERC4626 {
    constructor(IERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {}

    /// @notice Simulate yield accrual — anyone can deposit USDC to "add yield"
    ///         This increases the share price without minting new shares to anyone,
    ///         exactly how interest accrues in real Morpho markets.
    function simulateYield(uint256 amount) external {
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
        // The USDC sits in the vault, increasing totalAssets() without increasing totalSupply()
        // This makes each share worth more — same as interest accrual.
    }
}
