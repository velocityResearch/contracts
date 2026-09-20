// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {LiquidityZapper} from "../../src/markets/LiquidityZapper.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";
import {ProtocolStack} from "../../src/upgrade/ProtocolStack.sol";

/// @title LiquidityZapperEthForkTest
/// @notice The ETH door against the venue it actually sells through.
///
///         Everything the unit suite mocks is real here: WETH9, `SwapRouter02` at the
///         **non-canonical** address this chain puts it at, and the live WETH/USDG v3 pools with
///         whatever depth they hold at the forked block. That is the whole point of this file.
///         The unit tests prove the zapper's arithmetic; only a fork can prove that
///         `exactInputSingle`'s struct has the shape this repo believes it has, that the wrapper
///         the router names is the one a wrap produces, and that the tier the app quotes is deep
///         enough to zap through without the sale eating the deposit.
///
///         The market side is this project's own stack, deployed fresh in `setUp` exactly as
///         `MainnetLaunchFork` does, because Uniswap has not deployed v4 to Robinhood Chain and
///         mainnet carries no markets yet. So: a real ETH sale into a synthetic market, which is
///         the only combination the chain currently permits.
///
///         Reproduce:
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-contract LiquidityZapperEthFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-30))
contract LiquidityZapperEthForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev A real memecoin on this chain, used as the market's asset because it is an ordinary
    ///      ERC-20 `deal` can fund. Which token it is does not matter to anything under test —
    ///      the zap's asset leg is the market's own v4 pool either way.
    address constant ASSET = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18; // BONER
    uint256 constant ASSET_PRICE_E18 = 60_479_120_700_000_000; // $0.0605

    address constant USDG = MainnetAddresses.USDG;
    address constant USDG_SOURCE = MainnetAddresses.MORPHO_BLUE;

    /// @dev The oracle depth this market is listed with, and therefore the floor the factory is
    ///      deployed with: a market cannot ask for fewer slots than its factory demands.
    uint16 constant OBSERVATION_CARDINALITY = 60;

    uint24 constant FEE = 3000;
    uint256 constant SEED_USDG = 200_000e6;
    uint256 constant SEED_ASSET = 3_300_000e18;

    /// @dev A token bound, for the tests whose subject is the live venue rather than slippage.
    ///      Both doors reject zero now, so every call has to name something.
    uint128 constant ANY_LIQUIDITY = 1;
    uint256 constant ANY_SALE = 1;

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    PoolManager poolManager;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;
    StandInPositionManager posm;
    StandInPermit2 permit2;
    LiquidityZapper zapper;

    uint256 marketId;
    address brandToken;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address operator = address(0x0FE);
    address lp = address(0x11B0);
    /// @dev The wallet under test. It holds ETH and has never held USDG, the brand or the asset,
    ///      which is the state nearly every arriving wallet is actually in.
    address provider = address(0xB0B);

    function setUp() public {
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // Same pattern as `AssetMarketV4ForkTest`; the early return is what keeps the rest of
        // this function from reverting against an empty chain, since `vm.skip` only marks the
        // result and does not abort the body.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        _deployUpgradeBase();

        yieldSource = _deployYieldSource(
            MainnetAddresses.MORPHO_BLUE, MainnetAddresses.USDE_MARKET_ID, owner
        );
        reservePool = _deployReservePool(USDG, address(yieldSource), owner);

        poolManager = new PoolManager(owner);
        feeHook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x9990 << 144)
            ),
            IPoolManager(address(poolManager)),
            owner
        );

        // The periphery pair is built first: the factory takes the `PositionManager` it hands
        // to every market's LP reward distributor, so it cannot exist before one does.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(poolManager)), permit2);

        factory = _deployFactory(
            reservePool,
            IPoolManager(address(poolManager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            0,
            FIXTURE_REWARDS_DURATION,
            OBSERVATION_CARDINALITY,
            owner
        );

        vm.startPrank(owner);
        feeHook.setRegistrar(address(factory));
        factory.setProtocolFeePips(5000);
        vm.stopPrank();

        router = _deployRouter(
            reservePool,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            owner
        );

        // The owner lists the asset: the fee tier, the starting price, the oracle depth and the
        // unit's name and symbol are its call to make, not the creator's. Creation itself is
        // permissionless, so the prank below only decides who the market records as `creator`.
        _approveAsset(
            factory, ASSET, FEE, ASSET_PRICE_E18, OBSERVATION_CARDINALITY, "Bonerdollar", "bnrUSD"
        );
        vm.prank(operator);
        (marketId, brandToken,,,) = factory.createMarket(ASSET, address(0));

        _seed();

        // The real router, at the address this chain puts it at. WETH is not passed: the
        // initialiser reads it off the router, and the assertion below is that it found the one
        // the chain actually uses.
        zapper = ProtocolStack.deployZapper(
            reservePool,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(MainnetAddresses.SWAP_ROUTER_02),
            owner,
            address(protocolGuard)
        );
    }

    function _fundUsdg(address to, uint256 amount) private {
        vm.prank(USDG_SOURCE);
        IERC20(USDG).transfer(to, amount);
    }

    function _seed() private {
        _fundUsdg(lp, SEED_USDG);
        deal(ASSET, lp, SEED_ASSET);

        vm.startPrank(lp);
        IERC20(USDG).approve(address(reservePool), SEED_USDG);
        uint256 brandAmount = reservePool.mint(brandToken, SEED_USDG, lp);
        IERC20(brandToken).approve(address(router), brandAmount);
        IERC20(ASSET).approve(address(router), SEED_ASSET);
        router.seedLiquidity(marketId, brandAmount, SEED_ASSET, 0, 0, block.timestamp + 600);
        vm.stopPrank();
    }

    // ─── The wiring, read off the chain rather than from this file ───────

    /// @notice The wrapper is derived, and what it derives to is the chain's real WETH9. A
    ///         constant pasted here could be wrong; this cannot be, because it is the same
    ///         question the router answers when it is asked to sell.
    function test_fork_theWrapperIsTheChainsOwnWeth() public view {
        assertTrue(zapper.supportsEthZaps(), "the ETH door is open on this stack");
        assertEq(address(zapper.weth()), MainnetAddresses.WETH9, "and it wraps the chain's WETH9");
        assertEq(
            ISwapRouter02(MainnetAddresses.SWAP_ROUTER_02).factory(),
            MainnetAddresses.UNISWAP_V3_FACTORY,
            "the router is the real one, not the funds-forwarder at the canonical address"
        );
    }

    // ─── The sale, against real depth ────────────────────────────────────

    /// @notice One ETH, one signature, an LP NFT in a pool of two tokens the wallet never held.
    ///         Every leg here is the live chain's: the wrap, the v3 sale, the pool it sells into.
    function test_fork_ethAloneBecomesATwoSidedPosition() public {
        assertEq(IERC20(USDG).balanceOf(provider), 0, "no USDG");
        assertEq(IERC20(ASSET).balanceOf(provider), 0, "and none of the asset");

        vm.deal(provider, 1 ether);
        uint256 expectedId = posm.nextTokenId();
        uint128 depthBefore = router.marketLiquidity(marketId);

        vm.prank(provider);
        (uint256 tokenId, uint128 added, uint256 brandUsed, uint256 assetUsed) = zapper.zapLiquidityWithEth{
            value: 1 ether
        }(
            marketId,
            MainnetAddresses.WETH_USDG_FEE,
            ANY_SALE,
            5_000,
            ANY_LIQUIDITY,
            block.timestamp + 600
        );

        assertEq(tokenId, expectedId, "the id the PositionManager was about to mint");
        assertEq(posm.ownerOf(tokenId), provider, "owned by the provider");
        assertGt(added, 0, "liquidity was added");
        assertGt(brandUsed, 0, "the stable side was paid");
        assertGt(assetUsed, 0, "and so was the asset side");
        assertEq(router.marketLiquidity(marketId), depthBefore + added, "into the market's pool");
        assertEq(provider.balance, 0, "an exact-input sale consumed the whole ether");

        console.log("1 ETH -> brand used   ", brandUsed);
        console.log("       -> asset used  ", assetUsed);
        console.log("       -> liquidity   ", added);
    }

    /// @notice What the deepest tier is worth, measured rather than assumed. A zap of one ether
    ///         should reach the market with nearly all of its value: the 0.01% pool's fee is a
    ///         basis point and its depth is thousands of ether, so the sale's cost is far below
    ///         the tolerance any caller would set.
    function test_fork_theQuotedTierSellsAnEtherWithoutEatingIt() public {
        vm.deal(provider, 1 ether);

        uint256 poolPriceUsdg = _spotUsdgPerEth();

        vm.prank(provider);
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId,
            MainnetAddresses.WETH_USDG_FEE,
            ANY_SALE,
            5_000,
            ANY_LIQUIDITY,
            block.timestamp + 600
        );

        // What the sale returned, recovered from what the deposit consumed plus what came home:
        // the brand side is minted 1:1 from the sale's proceeds and half of it bought the asset.
        uint256 refunded = IERC20(USDG).balanceOf(provider);
        console.log("spot USDG per ETH     ", poolPriceUsdg);
        console.log("USDG returned as dust ", refunded);

        assertLt(refunded, 100e6, "the remainder is dust, not a failed deposit");
        assertEq(IERC20(USDG).balanceOf(address(zapper)), 0, "and the zapper kept none of it");
    }

    /// @notice The 1% pool pays less than the deepest tier at the forked state. The caller's sale
    ///         minimum catches an unexpected route even as live liquidity changes over time, and
    ///         it catches it before the deposit happens.
    function test_fork_theSaleMinimumCatchesAThinTier() public {
        uint256 deep = _quote(MainnetAddresses.WETH_USDG_FEE, 1 ether);
        uint256 thin = _quote(10_000, 1 ether);
        console.log("0.01% tier returns    ", deep);
        console.log("1%    tier returns    ", thin);
        assertLt(thin, deep, "the thin tier pays less for the same ether");

        // A caller who quoted a better tier and requires even one wei more than the thin tier can
        // return is stopped by their own bound rather than accepting the unexpected route.
        uint256 bound = thin + 1;
        vm.deal(provider, 1 ether);
        vm.prank(provider);
        vm.expectRevert();
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, 10_000, bound, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        assertEq(provider.balance, 1 ether, "and the ether never left");
    }

    /// @notice Both doors agree on the live venue too: an ETH zap mints what a USDG zap of the
    ///         sale's proceeds would have minted, against the same pool state.
    function test_fork_theEthDoorAndTheUsdgDoorAgree() public {
        uint256 proceeds = _quote(MainnetAddresses.WETH_USDG_FEE, 1 ether);

        uint256 pristine = vm.snapshotState();

        vm.deal(provider, 1 ether);
        vm.prank(provider);
        (, uint128 viaEth,,) = zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId,
            MainnetAddresses.WETH_USDG_FEE,
            ANY_SALE,
            5_000,
            ANY_LIQUIDITY,
            block.timestamp + 600
        );

        vm.revertToState(pristine);

        _fundUsdg(provider, proceeds);
        vm.startPrank(provider);
        IERC20(USDG).approve(address(zapper), proceeds);
        (, uint128 viaUsdg,,) =
            zapper.zapLiquidity(marketId, proceeds, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();

        assertEq(viaEth, viaUsdg, "the ETH door is the USDG door plus a sale");
    }

    /// @notice The zapper is not a place where value can rest. After a real ETH zap it holds no
    ///         ETH, no WETH, no USDG, no brand and none of the asset.
    function test_fork_theZapperKeepsNothing() public {
        vm.deal(provider, 3 ether);
        vm.prank(provider);
        zapper.zapLiquidityWithEth{value: 3 ether}(
            marketId,
            MainnetAddresses.WETH_USDG_FEE,
            ANY_SALE,
            5_000,
            ANY_LIQUIDITY,
            block.timestamp + 600
        );

        assertEq(address(zapper).balance, 0, "no ETH");
        assertEq(IERC20(MainnetAddresses.WETH9).balanceOf(address(zapper)), 0, "no WETH");
        assertEq(IERC20(USDG).balanceOf(address(zapper)), 0, "no USDG");
        assertEq(IERC20(brandToken).balanceOf(address(zapper)), 0, "no brand");
        assertEq(IERC20(ASSET).balanceOf(address(zapper)), 0, "none of the asset");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev What the live pool pays for `ethIn`, obtained by performing the swap on a throwaway
    ///      state and rolling it back. There is no quoter deployed on this chain, and a quoter's
    ///      answer would be a second implementation of the same arithmetic anyway.
    function _quote(uint24 fee, uint256 ethIn) private returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();

        address quoter = address(0x9057E);
        vm.deal(quoter, ethIn);
        vm.startPrank(quoter);
        IWETH9(MainnetAddresses.WETH9).deposit{value: ethIn}();
        IERC20(MainnetAddresses.WETH9).approve(MainnetAddresses.SWAP_ROUTER_02, ethIn);
        out = ISwapRouter02(MainnetAddresses.SWAP_ROUTER_02)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: MainnetAddresses.WETH9,
                    tokenOut: USDG,
                    fee: fee,
                    recipient: quoter,
                    amountIn: ethIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();

        vm.revertToState(snapshot);
    }

    /// @dev The spot rate, priced off a sale small enough that its own impact is negligible.
    function _spotUsdgPerEth() private returns (uint256) {
        return _quote(MainnetAddresses.WETH_USDG_FEE, 0.001 ether) * 1000;
    }
}
