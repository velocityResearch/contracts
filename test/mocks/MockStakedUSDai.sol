// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @notice The read side of sUSDai that `SUSDaiHub` depends on: an 18-decimal share with two
///         settable NAVs. `mint` stands in for staking; the ERC-7540 queue is not modelled
///         because the hub does not call it.
contract MockStakedUSDai is ERC20 {
    address public immutable asset;
    uint256 public depositSharePrice = 1.1e18;
    uint256 public redemptionSharePrice = 1.095e18;
    bool public paused;

    constructor(address _asset) ERC20("Staked USDai", "sUSDai") {
        asset = _asset;
    }

    function mint(address to, uint256 shares) external {
        _mint(to, shares);
    }

    function setSharePrices(uint256 deposit_, uint256 redemption_) external {
        depositSharePrice = deposit_;
        redemptionSharePrice = redemption_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * depositSharePrice / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * 1e18 / depositSharePrice;
    }

    function totalShares() external view returns (uint256) {
        return totalSupply();
    }
}
