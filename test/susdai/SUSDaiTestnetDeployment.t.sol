// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ConfigureSUSDaiTestnetRemote} from "../../script/ConfigureSUSDaiTestnetRemote.s.sol";
import {DeploySUSDaiTestnetHome} from "../../script/DeploySUSDaiTestnetHome.s.sol";
import {DeploySUSDaiTestnetRemote} from "../../script/DeploySUSDaiTestnetRemote.s.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {StrategyGroupRegistry} from "../../src/registry/StrategyGroupRegistry.sol";
import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {
    SUSDaiTestnetCurve,
    SUSDaiTestnetShares,
    SUSDaiTestnetSpokePool,
    SUSDaiTestnetToken
} from "../../src/testnet/SUSDaiTestnetMocks.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

contract RegistryFactoryStub {
    address public immutable reservePool;

    constructor(address reservePool_) {
        reservePool = reservePool_;
    }
}

contract RegistryRouterStub {
    address public immutable factory;
    address public immutable reservePool;

    constructor(address factory_, address reservePool_) {
        factory = factory_;
        reservePool = reservePool_;
    }
}

contract SUSDaiTestnetDeploymentTest is Test, StackFixture {
    address deployer = address(0xD3F10);

    function test_scriptsDeployAndWireBothStrategyGroups() public {
        _deployUpgradeBase();
        MockUSDC homeUsdg = new MockUSDC();
        MockYieldSource primaryYield = new MockYieldSource();
        SharedReservePool primaryReserve =
            _deployReservePool(address(homeUsdg), address(primaryYield), deployer);
        RegistryFactoryStub primaryFactory = new RegistryFactoryStub(address(primaryReserve));
        RegistryRouterStub primaryRouter =
            new RegistryRouterStub(address(primaryFactory), address(primaryReserve));

        vm.deal(deployer, 100 ether);
        vm.setEnv("SUSDAI_DEPLOYER", vm.toString(deployer));
        vm.setEnv("SUSDAI_KEEPER", vm.toString(deployer));
        vm.setEnv("HOME_USDG", vm.toString(address(homeUsdg)));

        DeploySUSDaiTestnetRemote remoteScript = new DeploySUSDaiTestnetRemote();
        (
            SUSDaiHub hub,
            SUSDaiTestnetSpokePool remoteSpoke,
            SUSDaiTestnetToken remoteUsdc,
            SUSDaiTestnetShares shares,
            SUSDaiTestnetCurve curve
        ) = remoteScript.run();

        vm.setEnv("REMOTE_HUB", vm.toString(address(hub)));
        vm.setEnv("REMOTE_USDC", vm.toString(address(remoteUsdc)));
        vm.setEnv("PRIMARY_RESERVE", vm.toString(address(primaryReserve)));
        vm.setEnv("PRIMARY_FACTORY", vm.toString(address(primaryFactory)));
        vm.setEnv("PRIMARY_ROUTER", vm.toString(address(primaryRouter)));

        DeploySUSDaiTestnetHome homeScript = new DeploySUSDaiTestnetHome();
        (
            SharedReservePool reserve,
            SUSDaiYieldSource adapter,
            StrategyGroupRegistry registry,
            SUSDaiTestnetSpokePool homeSpoke,
            address sampleBrand
        ) = homeScript.run();

        vm.setEnv("HOME_ADAPTER", vm.toString(address(adapter)));
        ConfigureSUSDaiTestnetRemote configureScript = new ConfigureSUSDaiTestnetRemote();
        configureScript.run();

        assertEq(hub.homeReceiver(), address(adapter));
        assertEq(address(adapter.spokePool()), address(homeSpoke));
        assertEq(address(hub.spokePool()), address(remoteSpoke));
        assertEq(address(hub.usdc()), address(remoteUsdc));
        assertEq(address(hub.susdai()), address(shares));
        assertEq(address(hub.curve()), address(curve));
        assertEq(registry.groupCount(), 2);
        assertEq(reserve.liabilityCap(), 100_000e6);
        assertEq(adapter.maxBridgeAmount(), 5_000e6);
        assertEq(hub.maxBridgeAmount(), 5_000e6);
        // The script ANNOUNCES the 14 bps rather than setting it. `setRedemptionFee` only
        // schedules an increase, so a freshly deployed reserve is fee-free until someone
        // commits, and asserting the live value here would have hidden that.
        assertEq(reserve.redemptionFeeBps(), 0, "a fresh reserve is fee-free until the commit");
        assertEq(reserve.pendingRedemptionFeeBps(), 14, "but the 14 bps is announced");
        assertGt(reserve.redemptionFeeEffectiveAt(), block.timestamp);

        // And the deployment really does reach the intended rate, which is the part a
        // pending-only assertion would leave unproven.
        vm.warp(block.timestamp + reserve.FEE_INCREASE_DELAY());
        reserve.commitRedemptionFee();
        assertEq(reserve.redemptionFeeBps(), 14, "and lands once the delay elapses");
        assertTrue(reserve.isRegistered(sampleBrand));

        StrategyGroupRegistry.Group memory market = registry.group(registry.groupIdAt(0));
        StrategyGroupRegistry.Group memory susdai = registry.group(registry.groupIdAt(1));
        assertEq(market.reservePool, address(primaryReserve));
        assertEq(market.factory, address(primaryFactory));
        assertEq(susdai.reservePool, address(reserve));
        assertEq(susdai.factory, address(0));
        assertEq(market.asset, susdai.asset);
    }
}
