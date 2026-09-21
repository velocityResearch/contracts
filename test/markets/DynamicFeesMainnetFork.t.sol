// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {MarketLens} from "../../src/markets/MarketLens.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

interface IDynamicPositionsNft {
    function name() external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
    function permit2() external view returns (address);
}

/// @title Stored dynamic LP fees against Robinhood mainnet's deployed Uniswap v4 venue
/// @notice Supply a pinned fork externally, or set FABLES_FORK_BLOCK to select the configured
///         Robinhood RPC inside setUp. The latter also works when a Foundry release cannot
///         initialize a CLI fork for chain 4663. Other chains skip without an explicit block.
///         PoolManager, PositionManager, Permit2, USDG, Morpho and equity tokens are live.
///         Only this protocol stack is new; no transaction is broadcast.
contract DynamicFeesMainnetForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 internal constant POSM =
        IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 internal constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    address internal constant USDG = MainnetAddresses.USDG;
    address internal constant MORPHO = MainnetAddresses.MORPHO_BLUE;
    address internal constant SPCX = MainnetAddresses.SPCX;
    address internal constant NVDA = MainnetAddresses.NVDA;
    address internal constant SPCX_POOL = MainnetAddresses.SPCX_USDG_POOL;
    address internal constant NVDA_POOL = MainnetAddresses.NVDA_USDG_POOL;
    bytes32 internal constant MORPHO_MARKET = MainnetAddresses.USDE_MARKET_ID;

    // `MarketLens` replays the swap itself through `V4SwapSimulator`, reading the stored
    // `slot0.lpFee` the way `Pool.swap` does. Its quotes are checked here against real
    // executions on the live PoolManager, so a keeper-set rate that the simulator mispriced
    // would fail this suite rather than an aggregator's integration.

    uint24 internal constant PROTOCOL_FEE_PIPS = 1_000;
    uint256 internal constant SEED_USDG = 50_000e6;
    uint256 internal constant SEED_SPCX = 250e18;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant TAKE_PAIR = 0x11;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    SharedReservePool internal reserve;
    MorphoBlueYieldSource internal yieldSource;
    ProtocolFeeHook internal hook;
    AssetMarketFactory internal factory;
    MarketRouter internal router;
    MarketLens internal lens;
    PoolSwapTest internal swapRouter;

    address internal owner = address(0xD1A0);
    address internal operator = address(0x0FE);
    address internal feeKeeper = address(0xB0B);
    address internal trader = address(0x7AAD);
    address internal protocolTreasury = address(0xF33);

    uint256 internal marketId;
    address internal brandToken;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FABLES_FORK_BLOCK", uint256(0));
        if (forkBlock != 0) vm.createSelectFork("robinhood", forkBlock);
        _deployUpgradeBase();
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        require(address(MANAGER).code.length != 0, "live PoolManager unavailable at fork block");
        require(address(POSM).code.length != 0, "live PositionManager unavailable at fork block");
        require(address(PERMIT2).code.length != 0, "live Permit2 unavailable at fork block");

        yieldSource = _deployYieldSource(MORPHO, MORPHO_MARKET, owner);
        reserve = _deployReservePool(USDG, address(yieldSource), owner);
        hook = _deployHook();
        factory = _deployFactory(reserve, MANAGER, hook, POSM, protocolTreasury, SPCX, 0, owner);
        vm.startPrank(owner);
        hook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();
        router = _deployRouter(reserve, factory, POSM, PERMIT2, owner);
        swapRouter = new PoolSwapTest(MANAGER);
        lens = new MarketLens(factory);

        _fundUsdg(operator, 500_000e6);
        _fundSpcx(operator, 2_000e18);
        _fundUsdg(trader, 500_000e6);
        _fundSpcx(trader, 1_000e18);
        _fundUsdg(address(this), 500_000e6);

        _createDynamicMarket();
        vm.prank(owner);
        hook.setFeeKeeper(feeKeeper);
    }

    function test_fork_factoryCreatesDynamicPoolAndRouterMintsRealPosition() public {
        AssetMarketFactory.Market memory market = factory.market(marketId);
        assertEq(market.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "factory recorded dynamic identity");
        assertEq(market.tickSpacing, 50, "dynamic markets use the specified spacing");
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(poolKey.tickSpacing, 50);
        assertEq(address(poolKey.hooks), address(hook));
        (uint160 sqrtPriceX96,,, uint24 storedFee) = MANAGER.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool exists in live singleton");
        assertEq(storedFee, 5_000, "registration seeded Uniswap's native dynamic fee");

        uint256 expectedTokenId = POSM.nextTokenId();
        (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed) = _seedDynamic();
        assertEq(tokenId, expectedTokenId, "router returned the live PositionManager id");
        assertEq(POSM.ownerOf(tokenId), operator, "operator owns the real NFT");
        assertEq(IDynamicPositionsNft(address(POSM)).name(), "Uniswap v4 Positions NFT");
        assertEq(POSM.poolManager(), address(MANAGER), "NFT venue is the live singleton");
        assertEq(IDynamicPositionsNft(address(POSM)).permit2(), address(PERMIT2));
        assertGt(liquidity, 0);
        assertGt(brandUsed, 0);
        assertGt(assetUsed, 0);
        assertEq(POSM.getPositionLiquidity(tokenId), liquidity);
        assertGt(MANAGER.getLiquidity(poolId), 0, "live singleton holds the depth");
    }

    function test_fork_authoritativeLensQuotesMatchNativeBuyAndSellExecutionAndEvents() public {
        vm.prank(feeKeeper);
        hook.setPoolLpFee(poolKey, 12_000);
        assertEq(_storedFee(poolKey), 12_000, "keeper updated the native slot before quoting");
        _seedDynamic();
        uint256 buyIn = 5_000e6;
        (uint256 quotedBuy,) = lens.quoteBuy(marketId, buyIn);

        uint256 assetBefore = IERC20(SPCX).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), buyIn);
        vm.recordLogs();
        uint256 bought =
            router.buyWithUsdg(marketId, buyIn, 0, trader, vm.getBlockTimestamp() + 1 hours);
        Vm.Log[] memory buyLogs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(bought, quotedBuy, "MarketLens/V4Quoter buy quote settled exactly");
        assertEq(IERC20(SPCX).balanceOf(trader) - assetBefore, bought, "real SPCX arrived");
        uint24 buyFee = _swapFee(buyLogs, poolId);
        assertEq(buyFee, 12_000, "PoolManager event reports the stored buy fee");

        uint256 sellIn = 5e18;
        (uint256 quotedSell,,) = lens.quoteSell(marketId, sellIn);
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);
        vm.startPrank(trader);
        IERC20(SPCX).approve(address(router), sellIn);
        vm.recordLogs();
        uint256 soldFor =
            router.sellForUsdg(marketId, sellIn, 0, trader, vm.getBlockTimestamp() + 1 hours);
        Vm.Log[] memory sellLogs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(soldFor, quotedSell, "MarketLens/V4Quoter sell quote settled exactly");
        assertEq(IERC20(USDG).balanceOf(trader) - usdgBefore, soldFor, "real USDG arrived");
        uint24 sellFee = _swapFee(sellLogs, poolId);
        assertEq(sellFee, 12_000, "PoolManager event reports the stored sell fee");
        assertEq(buyFee, sellFee, "one native fee applies symmetrically");

        Currency brandCurrency = _brandIsCurrency0() ? poolKey.currency0 : poolKey.currency1;
        Currency assetCurrency = _brandIsCurrency0() ? poolKey.currency1 : poolKey.currency0;
        uint256 brandSkim = hook.pendingFees(poolId, brandCurrency);
        uint256 assetSkim = hook.pendingFees(poolId, assetCurrency);
        assertGt(brandSkim, 0, "buy accrued protocol skim in brand");
        assertGt(assetSkim, 0, "sell accrued protocol skim in SPCX");
        uint256 treasuryBrandBefore = IERC20(brandToken).balanceOf(protocolTreasury);
        uint256 treasuryAssetBefore = IERC20(SPCX).balanceOf(protocolTreasury);
        hook.collect(poolKey);
        assertEq(
            IERC20(brandToken).balanceOf(protocolTreasury) - treasuryBrandBefore,
            brandSkim,
            "collected brand skim reached treasury"
        );
        assertEq(
            IERC20(SPCX).balanceOf(protocolTreasury) - treasuryAssetBefore,
            assetSkim,
            "collected SPCX skim reached treasury"
        );
        assertEq(hook.pendingFees(poolId, brandCurrency), 0, "brand skim claim was cleared");
        assertEq(hook.pendingFees(poolId, assetCurrency), 0, "asset skim claim was cleared");
    }

    function test_fork_storedFeePersistsAcrossTimeWithoutFallbackOrExpiry() public {
        _seedDynamic();
        _mintBrandTo(trader, 2_000e6, brandToken);
        vm.prank(feeKeeper);
        hook.setPoolLpFee(poolKey, 50_000);

        bool buyDirection = _brandIsCurrency0();
        Vm.Log[] memory firstLogs = _directSwap(buyDirection, 1_000e6);
        assertEq(_swapFee(firstLogs, poolId), 50_000, "maximum stored fee reached execution");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(_storedFee(poolKey), 50_000, "time cannot expire or recompute the fee");
        Vm.Log[] memory laterLogs = _directSwap(buyDirection, 1_000e6);
        assertEq(_swapFee(laterLogs, poolId), 50_000, "last successful write persists");
    }

    function test_fork_lpFeesAccrueAndPositionWithdrawsCollectsAndRedeems() public {
        (uint256 tokenId,, uint256 brandUsed, uint256 assetUsed) = _seedDynamic();
        reserve.deployIdle();
        (uint256 growth0Before, uint256 growth1Before) = MANAGER.getFeeGrowthGlobals(poolId);

        _mintBrandTo(trader, 5_000e6, brandToken);
        _directSwap(_brandIsCurrency0(), 5_000e6);
        _directSwap(!_brandIsCurrency0(), 10e18);
        (uint256 growth0After, uint256 growth1After) = MANAGER.getFeeGrowthGlobals(poolId);
        assertTrue(
            growth0After > growth0Before && growth1After > growth1Before,
            "two-sided trading accrued LP fees in both currencies"
        );

        uint256 brandBefore = IERC20(brandToken).balanceOf(operator);
        uint256 assetBefore = IERC20(SPCX).balanceOf(operator);
        _burnPosition(operator, tokenId, poolKey);
        uint256 brandBack = IERC20(brandToken).balanceOf(operator) - brandBefore;
        uint256 assetBack = IERC20(SPCX).balanceOf(operator) - assetBefore;
        assertGt(brandBack, 0, "position collection returned brand principal and fees");
        assertGt(assetBack, 0, "position collection returned asset principal and fees");
        assertTrue(
            brandBack != brandUsed || assetBack != assetUsed, "trades changed the collected amounts"
        );
        assertEq(MANAGER.getLiquidity(poolId), 0, "position fully withdrew from live singleton");
        vm.expectRevert();
        POSM.ownerOf(tokenId);

        uint256 usdgBefore = IERC20(USDG).balanceOf(operator);
        vm.prank(operator);
        uint256 redeemed = reserve.redeem(brandToken, brandBack, operator, 0);
        assertEq(
            IERC20(USDG).balanceOf(operator) - usdgBefore, redeemed, "withdrawn brand redeemed"
        );
        assertApproxEqAbs(redeemed, brandBack, 1, "reserve round trip is par up to one unit");
    }

    function test_fork_dynamicChangesLeaveAStaticFactoryPoolAtItsOwnFee() public {
        _fundNvda(operator, 200e18);
        _approveAsset(
            factory, NVDA, 5_000, _livePriceE18(NVDA_POOL), 62, "Nvidia Market Dollar", "NVDA.d"
        );
        uint256 staticMarketId;
        address staticBrand;
        bytes32 staticRawId;
        (staticMarketId, staticBrand,,, staticRawId) = factory.createMarket(NVDA, address(0));
        PoolKey memory staticKey = factory.poolKeyOf(staticMarketId);
        PoolId staticId = PoolId.wrap(staticRawId);

        vm.startPrank(operator);
        IERC20(USDG).approve(address(reserve), 20_000e6);
        reserve.mint(staticBrand, 20_000e6, operator);
        IERC20(staticBrand).approve(address(router), 20_000e6);
        IERC20(NVDA).approve(address(router), 100e18);
        router.seedLiquidity(
            staticMarketId, 20_000e6, 100e18, 0, 0, vm.getBlockTimestamp() + 1 hours
        );
        vm.stopPrank();

        vm.prank(feeKeeper);
        hook.setPoolLpFee(poolKey, 9_000);
        assertEq(_storedFee(poolKey), 9_000, "dynamic pool changed");
        assertEq(_storedFee(staticKey), 5_000, "static native fee remained unchanged");

        _mintBrandTo(trader, 1_000e6, staticBrand);
        bool zeroForOne = Currency.unwrap(staticKey.currency0) == staticBrand;
        vm.startPrank(trader);
        IERC20(Currency.unwrap(staticKey.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(staticKey.currency1)).approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        swapRouter.swap(
            staticKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1_000e6),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(_swapFee(logs, staticId), 5_000, "static fee remained authoritative in execution");
    }

    function _createDynamicMarket() internal {
        _approveAsset(
            factory,
            SPCX,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            _livePriceE18(SPCX_POOL),
            62,
            "Starbase Dynamic Dollar",
            "dSPCX"
        );
        bytes32 rawId;
        (marketId, brandToken,,, rawId) = factory.createMarket(SPCX, address(0));
        poolKey = factory.poolKeyOf(marketId);
        poolId = PoolId.wrap(rawId);
    }

    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0xD2F0 << 144)
        );
        require(flags.code.length == 0, "hook address occupied at fork block");
        return _deployHookAt(flags, MANAGER, owner);
    }

    function _seedDynamic()
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed)
    {
        vm.startPrank(operator);
        IERC20(USDG).approve(address(reserve), SEED_USDG);
        reserve.mint(brandToken, SEED_USDG, operator);
        IERC20(brandToken).approve(address(router), SEED_USDG);
        IERC20(SPCX).approve(address(router), SEED_SPCX);
        (tokenId, liquidity, brandUsed, assetUsed) = router.seedLiquidity(
            marketId, SEED_USDG, SEED_SPCX, 0, 0, vm.getBlockTimestamp() + 1 hours
        );
        vm.stopPrank();
    }

    function _directSwap(bool zeroForOne, uint256 amountIn)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.startPrank(trader);
        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(swapRouter), type(uint256).max);
        vm.recordLogs();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        logs = vm.getRecordedLogs();
        vm.stopPrank();
    }

    function _burnPosition(address who, uint256 tokenId, PoolKey memory key) internal {
        bytes memory actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, who);
        vm.prank(who);
        POSM.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp() + 1 hours);
    }

    function _storedFee(PoolKey memory key) internal view returns (uint24 lpFee) {
        (,,, lpFee) = MANAGER.getSlot0(key.toId());
    }

    function _swapFee(Vm.Log[] memory logs, PoolId expectedId) internal pure returns (uint24 fee) {
        bytes32 rawId = PoolId.unwrap(expectedId);
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (
                entry.emitter == MainnetAddresses.POOL_MANAGER && entry.topics.length == 3
                    && entry.topics[0] == SWAP_TOPIC && entry.topics[1] == rawId
            ) {
                (,,,,, fee) = abi.decode(
                    entry.data, (int128, int128, uint160, uint128, int24, uint24)
                );
                return fee;
            }
        }
        revert("live Swap event not found");
    }

    function _brandIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == brandToken;
    }

    function _mintBrandTo(address to, uint256 amount, address brand) internal {
        IERC20(USDG).approve(address(reserve), amount);
        reserve.mint(brand, amount, to);
    }

    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO);
        IERC20(USDG).transfer(to, amount);
    }

    function _fundSpcx(address to, uint256 amount) internal {
        vm.prank(SPCX_POOL);
        IERC20(SPCX).transfer(to, amount);
    }

    function _fundNvda(address to, uint256 amount) internal {
        vm.prank(NVDA_POOL);
        IERC20(NVDA).transfer(to, amount);
    }

    function _livePriceE18(address v3Pool) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(v3Pool).slot0();
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return Math.mulDiv(ratioX192, 1e18 * 1e12, 1 << 192);
    }
}
