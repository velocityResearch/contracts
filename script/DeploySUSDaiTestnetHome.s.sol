// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";
import {SUSDaiTestnetSpokePool} from "../src/testnet/SUSDaiTestnetMocks.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";

/// @notice Adds the sUSDai group and discovery registry beside the existing Robinhood testnet
///         market group. The backing token is the existing public faucet tUSDG, so both groups
///         share one unit of account while retaining separate reserve accounting.
contract DeploySUSDaiTestnetHome is Script {
    uint256 internal constant REMOTE_CHAIN_ID = 421614;
    uint256 internal constant DEFAULT_LIABILITY_CAP = 100_000e6;
    uint256 internal constant DEFAULT_BRIDGE_CAP = 5_000e6;
    uint16 internal constant DEFAULT_REDEMPTION_FEE_BPS = 14;
    bytes32 public constant MARKET_GROUP_ID = keccak256("market-usdg");
    bytes32 public constant SUSDAI_GROUP_ID = keccak256("susdai-usdg");

    function run()
        external
        returns (
            SharedReservePool reserve,
            SUSDaiYieldSource adapter,
            StrategyGroupRegistry registry,
            SUSDaiTestnetSpokePool spokePool,
            address sampleBrand
        )
    {
        require(block.chainid == 46630 || block.chainid == 31337, "Robinhood testnet/local only");
        address deployer = vm.envAddress("SUSDAI_DEPLOYER");
        address keeper = vm.envOr("SUSDAI_KEEPER", deployer);
        address homeUsdg = vm.envAddress("HOME_USDG");
        address remoteHub = vm.envAddress("REMOTE_HUB");
        address remoteUsdc = vm.envAddress("REMOTE_USDC");
        address primaryReserve = vm.envAddress("PRIMARY_RESERVE");
        address primaryFactory = vm.envAddress("PRIMARY_FACTORY");
        address primaryRouter = vm.envAddress("PRIMARY_ROUTER");
        address primaryZapper = vm.envOr("PRIMARY_ZAPPER", address(0));
        uint256 liabilityCap = vm.envOr("TESTNET_LIABILITY_CAP", DEFAULT_LIABILITY_CAP);
        uint256 bridgeCap = vm.envOr("TESTNET_BRIDGE_CAP", DEFAULT_BRIDGE_CAP);
        uint16 feeBps =
            SafeCast.toUint16(vm.envOr("REDEMPTION_FEE_BPS", uint256(DEFAULT_REDEMPTION_FEE_BPS)));

        require(deployer != address(0) && keeper != address(0), "authority is zero");
        require(homeUsdg.code.length > 0, "HOME_USDG has no code");
        require(remoteHub != address(0) && remoteUsdc != address(0), "remote wiring is zero");
        require(primaryReserve.code.length > 0, "PRIMARY_RESERVE has no code");
        require(
            primaryFactory.code.length > 0 && primaryRouter.code.length > 0, "market stack missing"
        );
        require(
            address(SharedReservePool(primaryReserve).asset()) == homeUsdg, "primary asset mismatch"
        );
        require(liabilityCap > 0 && bridgeCap > 0, "testnet caps must be nonzero");
        require(feeBps <= 100, "redemption fee above pool maximum");

        vm.startBroadcast(deployer);
        ProtocolGuard guard = ProtocolStack.deployGuard(deployer, deployer);
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(deployer);
        spokePool = new SUSDaiTestnetSpokePool(deployer, keeper);
        adapter = SUSDaiYieldSource(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiYieldSource()),
                    abi.encodeCall(
                        SUSDaiYieldSource.initialize,
                        (
                            homeUsdg,
                            address(spokePool),
                            REMOTE_CHAIN_ID,
                            remoteHub,
                            remoteUsdc,
                            address(guard),
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        reserve = ProtocolStack.deployReservePool(
            homeUsdg, address(adapter), deployer, beacons, address(guard)
        );
        adapter.bindController(address(reserve));
        adapter.setMaxBridgeAmount(bridgeCap);
        reserve.setLiabilityCap(liabilityCap);
        reserve.setRedemptionFee(feeBps);

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
                reservePool: primaryReserve,
                yieldSource: address(SharedReservePool(primaryReserve).yieldSource()),
                factory: primaryFactory,
                router: primaryRouter,
                zapper: primaryZapper,
                policyId: MARKET_GROUP_ID,
                active: true,
                name: "USDG market reserve",
                strategy: "Simulated market yield - testnet"
            })
        );
        registry.setGroup(
            SUSDAI_GROUP_ID,
            StrategyGroupRegistry.GroupInput({
                reservePool: address(reserve),
                yieldSource: address(adapter),
                factory: address(0),
                router: address(0),
                zapper: address(0),
                policyId: SUSDAI_GROUP_ID,
                active: true,
                name: "sUSDai reserve",
                strategy: "Mock sUSDai - Arbitrum Sepolia"
            })
        );
        (sampleBrand,) = reserve.registerBrand(
            "Test sUSDai Dollar",
            "tsUSDa",
            deployer,
            PooledBrandToken.Metadata({
                description: "Public testnet brand backed by the mock cross-chain sUSDai strategy.",
                logo: "",
                socials: ""
            }),
            deployer
        );
        vm.stopBroadcast();

        require(adapter.controller() == address(reserve), "adapter controller mismatch");
        require(adapter.maxBridgeAmount() == bridgeCap, "adapter bridge cap mismatch");
        require(reserve.liabilityCap() == liabilityCap, "pool liability cap mismatch");
        // NOT `redemptionFeeBps == feeBps`. `setRedemptionFee` announces an increase and
        // `SharedReservePool.FEE_INCREASE_DELAY` must elapse before anyone can commit it, so
        // the live fee is still zero here. Asserting what was announced, plus that it has a
        // future effective time, is what keeps a half-configured reserve from passing.
        if (feeBps > 0) {
            require(reserve.pendingRedemptionFeeBps() == feeBps, "redemption fee not announced");
            require(
                reserve.redemptionFeeEffectiveAt() > block.timestamp,
                "announced fee has no future effective time"
            );
        } else {
            require(reserve.redemptionFeeBps() == 0, "reserve is not fee-free");
        }
        require(registry.groupCount() == 2, "registry group count mismatch");
        require(reserve.isRegistered(sampleBrand), "sample brand missing");

        console.log("Robinhood testnet mock SpokePool:", address(spokePool));
        console.log("Robinhood testnet sUSDai adapter:", address(adapter));
        console.log("Robinhood testnet sUSDai reserve:", address(reserve));
        console.log("Robinhood testnet strategy registry:", address(registry));
        console.log("Robinhood testnet sample standalone brand:", sampleBrand);
        console.log("NEXT: configure the remote hub with ConfigureSUSDaiTestnetRemote.");
        if (feeBps > 0) {
            console.log("");
            console.log("ACTION REQUIRED: this reserve is FEE-FREE until the fee is committed.");
            console.log("  announced redemption fee (bps):", reserve.pendingRedemptionFeeBps());
            console.log("  live redemption fee (bps):     ", reserve.redemptionFeeBps());
            console.log("  committable from (unix):       ", reserve.redemptionFeeEffectiveAt());
            console.log("Every redemption pays par until then, so the group recovers nothing.");
            console.log("Anyone may finalise it; the value and the time are already on chain:");
            console.log(
                "  cast send <reserve> 'commitRedemptionFee()' --rpc-url <rpc> --private-key <key>"
            );
            console.log("  reserve:", address(reserve));
            console.log(
                "Confirm with: cast call <reserve> 'redemptionFeeBps()(uint16)' --rpc-url <rpc>"
            );
        }
    }
}
