// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {
    DeployAssetMarketsTestnet,
    AssetMarketFaucetToken,
    AssetMarketTestYieldSource
} from "../../script/DeployAssetMarketsTestnet.s.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";

/// @notice Deployment smoke test: drives `DeployAssetMarketsTestnet` and then uses what it
///         built, so a script that compiles but produces an unusable stack fails here.
///
/// @dev    The default local run places a real PoolManager plus narrow periphery stand-ins at
///         the production addresses, keeping the deployment order covered without a network.
///         With `--fork-url https://rpc.testnet.chain.robinhood.com`, the same test leaves those
///         addresses untouched and exercises Robinhood testnet's deployed Uniswap v4 singleton,
///         PositionManager and Permit2.
///
///         What it covers that the unit suites do not: the deploy script's order and the complete
///         market lifecycle. A hook mined after the factory, a missing registrar link, broken
///         periphery wiring, an unusable oracle, or a fee vault that cannot reach its LP
///         distributor all fail this journey.
contract AssetMarketsTestnetTest is Test {
    /// @dev Must match `DeployAssetMarketsTestnet.V4_POOL_MANAGER`.
    address internal constant V4_POOL_MANAGER_ADDRESS = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @dev Must match `DeployAssetMarketsTestnet.V4_POSITION_MANAGER` and `.PERMIT2`.
    address internal constant V4_POSITION_MANAGER_ADDRESS =
        0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function test_theTestnetScriptProducesAUsableStack() external {
        bool liveTestnetFork = block.chainid == 46630;
        if (!liveTestnetFork) {
            vm.chainId(31337);

            // The script points at the v4 singleton the chain already carries. Without a
            // testnet fork that address is empty, so put a real PoolManager there.
            deployCodeTo(
                "PoolManager.sol:PoolManager", abi.encode(address(this)), V4_POOL_MANAGER_ADDRESS
            );

            // The real PositionManager cannot be compiled into this repo because v4-periphery
            // vendors incompatible dependency versions. Local runs therefore use stand-ins for
            // its Permit2 pull and liquidity mint; a 46630 fork uses Robinhood testnet's actual
            // deployed periphery instead.
            deployCodeTo("MarketRouter.t.sol:StandInPermit2", "", PERMIT2_ADDRESS);
            deployCodeTo(
                "MarketRouter.t.sol:StandInPositionManager",
                abi.encode(IPoolManager(V4_POOL_MANAGER_ADDRESS), StandInPermit2(PERMIT2_ADDRESS)),
                V4_POSITION_MANAGER_ADDRESS
            );
        }

        address actor = address(0x123456);
        vm.setEnv("DEPLOYER", vm.toString(actor));
        (AssetMarketFactory factory, MarketRouter router, AssetMarketTestYieldSource yieldSource) =
            new DeployAssetMarketsTestnet().run();
        SharedReservePool reserve = router.reservePool();
        IERC20 usdg = reserve.asset();
        // Script deployment order: faucet USDG at nonce 0, the faucet asset at nonce 1.
        address asset = vm.computeCreateAddress(actor, 1);

        // The link the script exists to make. Without it every market creation reverts.
        assertEq(factory.feeHook().registrar(), address(factory), "hook registrar is the factory");
        assertEq(
            address(router.poolManager()),
            address(factory.poolManager()),
            "the router serves the factory's own singleton"
        );
        // The factory hands this address to every market's distributor, which pulls staked LP
        // NFTs through it. A factory pointing at different periphery than the router mints
        // through would leave every position unstakeable.
        assertEq(
            address(factory.positionManager()),
            address(router.positionManager()),
            "and the same periphery the router mints through"
        );

        // The second market's asset. Deployed here rather than by the script, which stands up
        // infrastructure and lists nothing: the cross-brand hops below need two dollars in the
        // one reserve, and an asset now gets exactly one market per reserve.
        AssetMarketFaucetToken otherAsset =
            new AssetMarketFaucetToken("Test Market Asset B", "tASSETB", 18);

        // Listing is the owner's call and carries every economic term a market on that asset
        // will have; opening the market is then permissionless. Both are `actor` here because
        // the testnet stack answers to its deployer.
        vm.startPrank(actor);
        factory.approveAsset(
            asset,
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: 3000,
                assetPriceE18: 1e18,
                observationCardinality: 62,
                unitName: "Test Dollar A",
                unitSymbol: "tA"
            })
        );
        factory.approveAsset(
            address(otherAsset),
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: 3000,
                assetPriceE18: 1e18,
                observationCardinality: 62,
                unitName: "Test Dollar B",
                unitSymbol: "tB"
            })
        );
        (uint256 id, address brand,,,) = factory.createMarket(asset, address(0));
        (, address otherBrand,,,) = factory.createMarket(address(otherAsset), address(0));

        usdg.approve(address(router), type(uint256).max);
        IERC20(asset).approve(address(router), type(uint256).max);

        // The stable side of a seed is the market's own brandUSD, minted at the reserve 1:1
        // and free, exactly as a provider would do it before opening the liquidity form.
        usdg.approve(address(reserve), type(uint256).max);
        reserve.mint(brand, 10_000e6, actor);
        IERC20(brand).approve(address(router), type(uint256).max);

        // Full range, and the position is minted to the caller as an LP NFT rather than kept
        // in the router's own name. There is still no tick argument — the range is the whole
        // curve — but there is now something to own, and `tokenId` names it.
        (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed) =
            router.seedLiquidity(id, 10_000e6, 10_000e18, 9_900e6, 9_900e18, block.timestamp + 600);
        assertGt(liquidity, 0);
        assertEq(
            StandInPositionManager(V4_POSITION_MANAGER_ADDRESS).ownerOf(tokenId),
            actor,
            "the seeder holds the position, not the router"
        );
        assertEq(router.marketLiquidity(id), liquidity, "and it is the market's whole depth");
        assertGe(brandUsed, 9_900e6);
        assertGe(assetUsed, 9_900e18);

        uint256 before = usdg.balanceOf(actor);
        uint256 bought = router.buyWithUsdg(id, 10e6, 9e18, actor, block.timestamp + 600);
        uint256 brandBack = router.sellForBrand(id, bought, 9e6, actor, block.timestamp + 600);
        uint256 received = reserve.redeem(brand, brandBack, actor);
        assertLt(received, 10e6);
        assertEq(usdg.balanceOf(actor), before - 10e6 + received);

        usdg.approve(address(reserve), type(uint256).max);
        reserve.mint(otherBrand, 100e6, actor);
        reserve.swap(otherBrand, brand, 20e6, actor);
        assertEq(IERC20(brand).balanceOf(actor), 20e6);
        uint256 balanceBeforeRedeem = usdg.balanceOf(actor);
        reserve.redeem(brand, 10e6, actor);
        assertEq(usdg.balanceOf(actor) - balanceBeforeRedeem, 10e6);
        IERC20(otherBrand).approve(address(router), 10e6);
        assertGt(router.buyWithBrand(id, otherBrand, 10e6, 9e18, actor, block.timestamp + 600), 0);
        IERC20(brand).approve(address(router), 10e6);
        assertGt(router.buyWithBrand(id, brand, 10e6, 9e18, actor, block.timestamp + 600), 0);

        // Yield attribution needs elapsed time, and so does the pool's oracle: the first trade
        // after this warp writes a live observation 15 minutes plus one write interval after
        // the pool's initial one, and the round-trip leaves spot close to where it started.
        //
        // `vm.getBlockTimestamp()`, not `block.timestamp`: this project builds with `via_ir`,
        // which treats TIMESTAMP as pure and may hoist one read across the warp — which is
        // exactly what happened here, and the deadline arrived 915 seconds in the past.
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 15 seconds);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        uint256 oracleAsset = router.buyWithUsdg(id, 1e6, 9e17, actor, deadline);
        router.sellForBrand(id, oracleAsset, 9e5, actor, deadline);

        reserve.deployIdle();
        usdg.approve(address(yieldSource), 100e6);
        yieldSource.simulateYield(address(usdg), address(reserve), 100e6);
        BrandFeeVault vault = BrandFeeVault(factory.market(id).feeVault);
        assertGt(vault.pendingYield(), 0);
        uint256 harvested = vault.harvest();
        assertGt(harvested, 0);

        (uint256 toProtocol, uint256 toLps) = vault.sweep();
        // Zero protocol fee on this fixture, so the whole harvest is the liquidity providers',
        // rounding dust included.
        assertEq(toProtocol, 0);
        assertEq(toProtocol + toLps, harvested, "the split accounts for the whole harvest");
        assertEq(vault.balance(), 0, "and the vault kept none of it");

        // The LP share has to land somewhere it can actually be streamed from, in the market's
        // own dollar. A deployment that mis-wired the vault to its distributor would strand
        // every reward the market ever earns, which is exactly what this journey exists to
        // catch.
        LpRewardDistributor distributor = LpRewardDistributor(factory.market(id).lpDistributor);
        assertEq(address(vault.distributor()), address(distributor), "the market's own sink");
        assertEq(address(distributor.rewardToken()), brand, "paid in the market's dollar");
        assertEq(IERC20(brand).balanceOf(address(distributor)), toLps, "the LP share arrived");
        assertGt(distributor.periodFinish(), vm.getBlockTimestamp(), "a reward period is running");

        // The terms the script fixes for every market this stack will carry.
        assertEq(factory.rewardsDuration(), 7 days, "a weekly reward period");
        assertEq(factory.minObservationCardinality(), 62, "and the oracle depth to match");

        assertGe(reserve.totalAssets(), reserve.totalPooledSupply());
    }
}
