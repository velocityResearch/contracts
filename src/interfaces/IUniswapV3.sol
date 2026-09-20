// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal subset of the Uniswap V3 Factory surface area this repo uses.
interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

/// @notice Minimal surface for pool initialization and price reads.
interface IUniswapV3PoolLike {
    function initialize(uint160 sqrtPriceX96) external;

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Grow the pool's observation ring buffer so a TWAP of meaningful length can be
    ///         read from it. A pool starts life with cardinality 1, which is enough for spot
    ///         and useless for `observe` — anything that intends to price against a TWAP later
    ///         has to pay to grow the buffer first, ideally at pool creation.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    /// @notice Cumulative tick and per-liquidity values at each of `secondsAgos`, for TWAP.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    /// @notice Raw pool swap. The caller MUST implement `uniswapV3SwapCallback` and pay the
    ///         input token there — this is why a plain `approve` + `swap` router does not work
    ///         against a real Uniswap V3 pool.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Minimal surface of the Uniswap V3 NonfungiblePositionManager used for seeding a position.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice The V3 factory this position manager was deployed against. Declared so a
    ///         deployment can identity-check the periphery instead of trusting a constant —
    ///         on Robinhood Chain the whole Uniswap deployment sits at non-canonical
    ///         addresses, and the canonical ones hold unrelated contracts.
    function factory() external view returns (address);
}
