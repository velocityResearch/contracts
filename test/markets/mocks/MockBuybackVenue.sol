// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {ISwapRouter02} from "../../../src/interfaces/ISwapRouter02.sol";

/// @notice A `SwapRouter02` stand-in: the address `AssetMarketFactory` identity-checks, plus a
///         swap that can consume **less than `amountIn`** and leave the remainder with the
///         caller, as real Uniswap does when a `sqrtPriceLimitX96` is reached mid-swap.
///
///         `fillBps` is that partial fill as a knob. It is not a curve: no price impact, no
///         reserves. `BuybackEngine` no longer goes through here at all — it swaps against a
///         real v4 `PoolManager` in `BrandFeeVault.t.sol`, where the fill is Uniswap's own
///         arithmetic rather than a number this mock was told to return.
contract MockSwapRouter02 is ISwapRouter02 {
    address private immutable _factory;

    /// @dev The wrapper this router names as its ETH side. Settable rather than constructed
    ///      because most suites here never touch ETH and should not have to build a WETH to
    ///      deploy a router; `LiquidityZapper`'s does, and sets it.
    address public WETH9;

    /// @notice Share of `amountIn` the next swap consumes. 10_000 fills completely, 0 fills
    ///         nothing — the "pool is already outside the band" case.
    uint16 public fillBps = 10_000;

    /// @notice Raw `tokenOut` per raw `tokenIn`, scaled by 1e18.
    uint256 public rateE18 = 1e18;

    uint160 public lastSqrtPriceLimitX96;
    uint256 public lastAmountIn;
    uint256 public calls;

    constructor(address factory_) {
        _factory = factory_;
    }

    function factory() external view returns (address) {
        return _factory;
    }

    function setWETH9(address wrapper) external {
        WETH9 = wrapper;
    }

    function setFillBps(uint16 bps) external {
        fillBps = bps;
    }

    function setRateE18(uint256 rate) external {
        rateE18 = rate;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        calls += 1;
        lastSqrtPriceLimitX96 = p.sqrtPriceLimitX96;
        lastAmountIn = p.amountIn;

        uint256 consumed = p.amountIn * fillBps / 10_000;
        if (consumed > 0) {
            IERC20(p.tokenIn).transferFrom(msg.sender, address(this), consumed);
        }

        amountOut = consumed * rateE18 / 1e18;
        if (amountOut > 0) IERC20(p.tokenOut).transfer(p.recipient, amountOut);

        require(amountOut >= p.amountOutMinimum, "MockSwapRouter02: insufficient output");
    }
}

/// @notice An 18-decimal traded asset with a public mint, standing in for a memecoin or a
///         tokenized equity. `MockUSDC` covers the 6-decimal reserve side.
contract MockAsset is ERC20 {
    constructor() ERC20("Mock Market Asset", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice An asset whose transfers can be switched off, standing in for the issuer power that
///         drives the whole fail-soft design: `pause()` and `isBlocked(address)` on a Robinhood
///         tokenized equity. See ASSET_MARKETS.md §3.1.
contract PausableAsset is ERC20 {
    bool public paused;

    constructor() ERC20("Pausable Asset", "PAUSE") {}

    function setPaused(bool p) external {
        paused = p;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "asset paused");
        super._update(from, to, value);
    }
}
