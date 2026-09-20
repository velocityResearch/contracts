// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {LiquidityZapper} from "../src/markets/LiquidityZapper.sol";
import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";

/// @notice Turns the live Base Sepolia deployment into a multi-reserve one, in place.
///
///         Nothing here moves a brand, a pool or a position. The factory and the router are
///         UUPS proxies, so they keep their addresses and their storage and only gain the
///         ability to serve a second reserve group; the zapper and the registry are redeployed,
///         which is why both addresses change and the app's configuration has to be updated
///         with them. The zapper is a proxy of its own from this deployment on, so the next
///         change to it will be an upgrade in place rather than another new address.
///
///         The one state change is `setApprovedReservePool`, which is what lets the factory
///         register brands in the sUSDai reserve. The sample brand already registered directly
///         on that reserve is untouched and keeps its own treasury — a brand the factory did
///         not register can never be given a market, by design.
contract UpgradeBaseSepoliaMultiReserve is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal constant V4_POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 public constant MARKET_GROUP_ID = keccak256("market-usdg");
    bytes32 public constant SUSDAI_GROUP_ID = keccak256("susdai-usdg");

    function run() external returns (LiquidityZapper zapper, StrategyGroupRegistry registry) {
        require(block.chainid == BASE_SEPOLIA, "Base Sepolia only");

        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("MARKET_ROUTER"));
        SharedReservePool marketReserve = SharedReservePool(vm.envAddress("MARKET_RESERVE"));
        SharedReservePool susdaiReserve = SharedReservePool(vm.envAddress("SUSDAI_RESERVE"));
        address marketYieldSource = vm.envAddress("MARKET_YIELD_SOURCE");
        address susdaiAdapter = vm.envAddress("SUSDAI_ADAPTER");

        require(factory.owner() == deployer, "factory owner is not the deployer");
        require(router.owner() == deployer, "router owner is not the deployer");
        require(address(factory.reservePool()) == address(marketReserve), "default reserve differs");
        require(address(router.factory()) == address(factory), "router is not this factory's");
        require(
            address(susdaiReserve.asset()) == address(marketReserve.asset()),
            "the two reserves must share one underlying"
        );

        vm.startBroadcast(deployer);

        // Implementations first, then the one state change they make meaningful. Upgrading the
        // router before the factory would leave it resolving a `Market.reservePool` field the
        // factory's live implementation does not write yet — harmless, since the field reads
        // zero and zero means the default, but the order below never has that window at all.
        address factoryImplementation = address(new AssetMarketFactory());
        factory.upgradeToAndCall(factoryImplementation, "");
        address routerImplementation = address(new MarketRouter());
        router.upgradeToAndCall(routerImplementation, "");

        factory.setApprovedReservePool(address(susdaiReserve), true);

        // Redeployed rather than upgraded, because the live one is the ownerless, un-upgradeable
        // first generation and has no upgrade path to take. The replacement is a UUPS proxy
        // owned by the deployer and guarded by the same `ProtocolGuard` the router obeys, read
        // off the router rather than passed in so the two cannot name different registries.
        zapper = ProtocolStack.deployZapper(
            marketReserve,
            factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            ISwapRouter02(address(0)),
            deployer,
            address(router.guard())
        );

        // The old registry validated a group by demanding the factory's own reserve match it,
        // which is exactly what a shared factory cannot satisfy. A registry is a directory with
        // no funds and no dependents, so it is replaced rather than migrated.
        registry = StrategyGroupRegistry(
            address(
                new ERC1967Proxy(
                    address(new StrategyGroupRegistry()),
                    abi.encodeCall(StrategyGroupRegistry.initialize, (deployer))
                )
            )
        );
        registry.setGroup(
            MARKET_GROUP_ID,
            StrategyGroupRegistry.GroupInput({
                reservePool: address(marketReserve),
                yieldSource: marketYieldSource,
                factory: address(factory),
                router: address(router),
                zapper: address(zapper),
                policyId: MARKET_GROUP_ID,
                active: true,
                name: "USDC market reserve",
                strategy: "Simulated market yield - Base Sepolia"
            })
        );
        registry.setGroup(
            SUSDAI_GROUP_ID,
            StrategyGroupRegistry.GroupInput({
                reservePool: address(susdaiReserve),
                yieldSource: susdaiAdapter,
                factory: address(factory),
                router: address(router),
                zapper: address(zapper),
                policyId: SUSDAI_GROUP_ID,
                active: true,
                name: "sUSDai reserve",
                strategy: "Mock sUSDai via Across - Arbitrum Sepolia"
            })
        );

        vm.stopBroadcast();

        require(
            factory.approvedReservePool(address(susdaiReserve)), "sUSDai reserve is not approved"
        );
        require(address(zapper.factory()) == address(factory), "zapper factory mismatch");
        require(registry.groupCount() == 2, "registry group count mismatch");
        require(
            registry.group(SUSDAI_GROUP_ID).factory == address(factory),
            "sUSDai group has no market stack"
        );

        console.log("AssetMarketFactory implementation:", factoryImplementation);
        console.log("MarketRouter implementation:", routerImplementation);
        console.log("LiquidityZapper:", address(zapper));
        console.log("StrategyGroupRegistry:", address(registry));
        console.log("NEXT: point NEXT_PUBLIC_LIQUIDITY_ZAPPER and");
        console.log("      NEXT_PUBLIC_STRATEGY_GROUP_REGISTRY at the two addresses above.");
    }
}
