// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";
import {
    SUSDaiTestnetCurve,
    SUSDaiTestnetShares,
    SUSDaiTestnetSpokePool,
    SUSDaiTestnetToken
} from "../src/testnet/SUSDaiTestnetMocks.sol";

/// @notice Deploys the remote half of the deterministic mock route to Arbitrum Sepolia.
///         No contract in this script can be deployed on a production chain.
contract DeploySUSDaiTestnetRemote is Script {
    uint256 internal constant HOME_CHAIN_ID = 46630;
    uint256 internal constant DEFAULT_BRIDGE_CAP = 5_000e6;

    function run()
        external
        returns (
            SUSDaiHub hub,
            SUSDaiTestnetSpokePool spokePool,
            SUSDaiTestnetToken usdc,
            SUSDaiTestnetShares shares,
            SUSDaiTestnetCurve curve
        )
    {
        require(block.chainid == 421614 || block.chainid == 31337, "Arbitrum Sepolia/local only");
        address deployer = vm.envAddress("SUSDAI_DEPLOYER");
        address keeper = vm.envOr("SUSDAI_KEEPER", deployer);
        address homeUsdg = vm.envAddress("HOME_USDG");
        uint256 bridgeCap = vm.envOr("TESTNET_BRIDGE_CAP", DEFAULT_BRIDGE_CAP);
        require(deployer != address(0) && keeper != address(0), "authority is zero");
        require(homeUsdg != address(0), "HOME_USDG is zero");
        require(bridgeCap > 0, "TESTNET_BRIDGE_CAP is zero");

        vm.startBroadcast(deployer);
        SUSDaiTestnetToken usdai = new SUSDaiTestnetToken("Test USDai", "tUSDai", 18);
        usdc = new SUSDaiTestnetToken("Test USDC", "tUSDC", 6);
        shares = new SUSDaiTestnetShares(address(usdai));
        curve = new SUSDaiTestnetCurve(address(shares), address(usdc), 1.1e18, 1);
        spokePool = new SUSDaiTestnetSpokePool(deployer, keeper);
        hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiHub()),
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            address(usdc),
                            address(shares),
                            address(curve),
                            address(spokePool),
                            HOME_CHAIN_ID,
                            homeUsdg,
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        hub.setMaxBridgeAmount(bridgeCap);

        usdc.mint(address(curve), 5_000_000e6);
        shares.mint(address(curve), 5_000_000e18);
        usdc.mint(deployer, 1_000_000e6);
        vm.stopBroadcast();

        require(hub.owner() == deployer && hub.keeper() == keeper, "hub authority mismatch");
        require(hub.homeReceiver() == address(0), "home receiver unexpectedly set");
        require(hub.maxBridgeAmount() == bridgeCap, "hub bridge cap mismatch");
        require(spokePool.relayer() == keeper, "spoke relayer mismatch");
        require(
            curve.coins(0) == address(shares) && curve.coins(1) == address(usdc), "curve mismatch"
        );

        console.log("Arbitrum Sepolia test USDai:", address(usdai));
        console.log("Arbitrum Sepolia test USDC:", address(usdc));
        console.log("Arbitrum Sepolia test sUSDai:", address(shares));
        console.log("Arbitrum Sepolia test Curve:", address(curve));
        console.log("Arbitrum Sepolia test SpokePool:", address(spokePool));
        console.log("Arbitrum Sepolia SUSDaiHub:", address(hub));
        console.log("NEXT: deploy DeploySUSDaiTestnetHome with REMOTE_HUB and REMOTE_USDC above.");
    }
}
