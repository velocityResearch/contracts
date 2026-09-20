// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3Factory, IUniswapV3PoolLike} from "../../../src/interfaces/IUniswapV3.sol";

/// @notice A Uniswap V3 pool mock that actually remembers its price and its observation
///         buffer. A mock that returns `sqrtPriceX96 = 0` from `slot0` forever cannot
///         distinguish an uninitialised pool from an initialised one, which is exactly the
///         branch `AssetMarketFactory._ensurePool` turns on.
///
///         Still no curve and no token custody: anything needing real swap behaviour belongs
///         in a fork test against the live deployment, the same rule the existing mock states.
contract MockPricedPool is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96;
    uint16 public cardinalityNext = 1;
    address public immutable t0;
    address public immutable t1;
    uint24 public immutable fee;

    error AlreadyInitialised();

    constructor(address _t0, address _t1, uint24 _fee) {
        t0 = _t0;
        t1 = _t1;
        fee = _fee;
    }

    function initialize(uint160 _sqrtPriceX96) external {
        if (sqrtPriceX96 != 0) revert AlreadyInitialised();
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, int24(0), 0, 1, cardinalityNext, 0, true);
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > cardinalityNext) cardinalityNext = next;
    }

    function token0() external view returns (address) {
        return t0;
    }

    function token1() external view returns (address) {
        return t1;
    }

    /// @dev In-range liquidity and the `secondsPerLiquidityCumulativeX128` it drives, so a
    ///      a caller reading liquidity-seconds off this pool sees them move. Advanced by
    ///      `elapsed << 128 / L` with
    ///      zero treated as one, the way `Oracle.observeSingle` does it.
    uint128 public activeLiquidity;
    uint160 private _accX128;
    uint256 private _accAt = block.timestamp;

    function setLiquidity(uint128 next) external {
        _accX128 = _accumulatorNow();
        _accAt = block.timestamp;
        activeLiquidity = next;
    }

    function _accumulatorNow() private view returns (uint160) {
        uint256 dt = block.timestamp - _accAt;
        if (dt == 0) return _accX128;
        uint256 l = activeLiquidity == 0 ? 1 : activeLiquidity;
        unchecked {
            return _accX128 + uint160((dt << 128) / l);
        }
    }

    function liquidity() external view returns (uint128) {
        return activeLiquidity;
    }

    function swap(address, bool, int256, uint160, bytes calldata)
        external
        pure
        returns (int256, int256)
    {
        revert("MockPricedPool: use a fork test for swaps");
    }

    /// @dev A pool with a cardinality of one: the current value is always available, any
    ///      window into the past is not. That is the real behaviour, and it is the distinction
    ///      a liquidity-seconds reader relies on — offset zero only, while `BuybackEngine`
    ///      asks for a window and is expected to be refused here.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            if (secondsAgos[i] != 0) revert("MockPricedPool: use a fork test for TWAP");
            secondsPerLiquidityX128s[i] = _accumulatorNow();
        }
    }
}

contract MockPricedV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) private _pools;

    function _key(address a, address b, uint24 fee) private pure returns (bytes32) {
        (address x, address y) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(x, y, fee));
    }

    function createPool(address tokenA, address tokenB, uint24 fee)
        external
        returns (address pool)
    {
        bytes32 k = _key(tokenA, tokenB, fee);
        require(_pools[k] == address(0), "pool exists");
        (address x, address y) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = address(new MockPricedPool(x, y, fee));
        _pools[k] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[_key(tokenA, tokenB, fee)];
    }

    /// @dev The tiers actually enabled on Robinhood Chain, verified on-chain.
    function feeAmountTickSpacing(uint24 fee) external pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        return 0;
    }
}

/// @notice Stand-ins for the two sides of a market, with fixed decimals so `vm.etch` can place
///         them at chosen addresses and pin Uniswap's `token0 < token1` ordering in a test.
contract Decimals18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract Decimals6 {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}
