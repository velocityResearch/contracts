// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {ICurveStableSwapNG} from "../../src/interfaces/ICurveStableSwapNG.sol";

/// @notice A two-coin Curve pool reduced to what matters for the hub's tests: coin 0 is an
///         18-decimal share priced at `rate` USDC per share (WAD), coin 1 is 6-decimal USDC,
///         and every swap executes at that rate less `feeBps`. No curvature: a test that wants
///         a discount sets `rate` below the share's NAV. Liquidity is whatever it holds.
contract MockCurveStableSwapNG is ICurveStableSwapNG {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE = 1e12;

    address public immutable shares;
    address public immutable usdc;
    uint256 public rate;
    uint256 public feeBps;

    constructor(address _shares, address _usdc, uint256 _rate, uint256 _feeBps) {
        shares = _shares;
        usdc = _usdc;
        rate = _rate;
        feeBps = _feeBps;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function coins(uint256 i) external view returns (address) {
        require(i < 2, "index");
        return i == 0 ? shares : usdc;
    }

    function N_COINS() external pure returns (uint256) {
        return 2;
    }

    function get_dy(int128 i, int128 j, uint256 dx) public view returns (uint256) {
        require((i == 0 && j == 1) || (i == 1 && j == 0), "pair");
        uint256 gross = i == 0 ? dx * rate / WAD / SCALE : dx * SCALE * WAD / rate;
        return gross - gross * feeBps / 10_000;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256) {
        uint256 dy = get_dy(i, j, dx);
        require(dy >= minDy, "slippage");
        (address tokenIn, address tokenOut) = i == 0 ? (shares, usdc) : (usdc, shares);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), dx);
        IERC20(tokenOut).safeTransfer(msg.sender, dy);
        return dy;
    }

    function stored_rates() external view returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = rate;
        r[1] = 1e30;
    }

    function balances(uint256 i) external view returns (uint256) {
        return IERC20(i == 0 ? shares : usdc).balanceOf(address(this));
    }

    function fee() external view returns (uint256) {
        return feeBps * 1e6;
    }
}
