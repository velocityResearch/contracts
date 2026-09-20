// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @notice Canonical WETH9's behaviour, in the two places it differs from a plain ERC-20.
///
///         `withdraw` pays out with a bare `transfer` — 2300 gas and no calldata — exactly as the
///         real WETH9 does. That is deliberate and load-bearing: a refund path that only works
///         because a mock was generous with gas is a path that reverts on chain, and this is
///         where `LiquidityZapper.receive` is proved able to run in the real budget.
contract MockWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}
