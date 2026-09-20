// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The subset of Uniswap `SwapRouter02` this repo calls.
///
///         The **02** flavour, not the original `SwapRouter`: `exactInputSingle` takes no
///         `deadline` field. Passing the older struct shape encodes the wrong calldata and the
///         call reverts with no reason string, so the distinction is load-bearing.
///
///         On Robinhood Chain mainnet this is deployed at the NON-canonical address
///         `0xCaf681a66D020601342297493863E78C959E5cb2`. The canonical SwapRouter address
///         holds an unrelated funds-forwarding contract on this chain — approving it would be
///         a real loss — which is why `factory()` is declared here: so a deployment can
///         identity-check the router against the V3 factory rather than trust a config file.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function factory() external view returns (address);

    /// @notice The wrapper this router accepts as the ETH side of a pool.
    ///
    ///         Declared so a contract taking ETH can derive its WETH address from the router it
    ///         swaps through rather than from a constant. The two must agree — a swap routed
    ///         through this router against some other wrapper is a swap in a pool that does not
    ///         exist — and deriving is the only way to be sure they do.
    function WETH9() external view returns (address);
}
