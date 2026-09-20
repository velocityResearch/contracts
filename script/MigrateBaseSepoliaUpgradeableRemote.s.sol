// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";

/// @notice Step 1 of moving the public Base Sepolia integration onto upgradeable sUSDai
///         contracts: a `SUSDaiHub` behind an ERC-1967 proxy on Arbitrum Sepolia, replacing
///         the plain hub at `0x86E826045AA384014e75f55157b775D6636149E4`.
///
///         The old hub is drained before this runs — zero shares, zero USDC — so nothing moves
///         here and there is nothing to migrate but the wiring. It keeps the same mock USDai,
///         sUSDai, Curve pool and Across SpokePool, because those are the environment, not the
///         thing being replaced.
///
///         `homeReceiver` is deliberately left unset. It has to be the NEW adapter, which does
///         not exist until step 2 (it needs this hub's address), so step 3 closes the loop.
///
///         Usage:
///         forge script script/MigrateBaseSepoliaUpgradeableRemote.s.sol \
///           --rpc-url https://sepolia-rollup.arbitrum.io/rpc --broadcast
contract MigrateBaseSepoliaUpgradeableRemote is Script {
    uint256 constant ARBITRUM_SEPOLIA = 421614;
    uint256 constant BASE_SEPOLIA = 84532;

    address constant ARBITRUM_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant MOCK_SUSDAI = 0xA9a921450e5D4c093F264f37F39D3fA039EC41d5;
    address constant MOCK_CURVE = 0x4dD0D344207Bec56af07be05f3e0c31ab6942142;
    address constant ARBITRUM_SPOKE_POOL = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
    address constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant OLD_HUB = 0x86E826045AA384014e75f55157b775D6636149E4;

    /// @dev Matches the old hub exactly. Re-stated rather than read off chain so a migration
    ///      cannot silently inherit a limit somebody widened by hand.
    uint256 constant MAX_BRIDGE_AMOUNT = 5_000_000_000;

    function run() external returns (SUSDaiHub hub) {
        require(block.chainid == ARBITRUM_SEPOLIA, "not Arbitrum Sepolia (421614)");

        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);

        require(SUSDaiHub(OLD_HUB).sharesHeld() == 0, "old hub still holds sUSDai shares");
        require(SUSDaiHub(OLD_HUB).usdcHeld() == 0, "old hub still holds USDC");

        vm.startBroadcast(key);
        SUSDaiHub implementation = new SUSDaiHub();
        hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            ARBITRUM_USDC,
                            MOCK_SUSDAI,
                            MOCK_CURVE,
                            ARBITRUM_SPOKE_POOL,
                            BASE_SEPOLIA,
                            BASE_USDC,
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        hub.setMaxBridgeAmount(MAX_BRIDGE_AMOUNT);
        vm.stopBroadcast();

        require(hub.owner() == deployer, "hub owner is not the deployer");
        require(address(hub.susdai()) == MOCK_SUSDAI, "hub sUSDai mismatch");
        require(hub.homeChainId() == BASE_SEPOLIA, "hub home chain mismatch");
        require(hub.homeReceiver() == address(0), "homeReceiver is set before the adapter exists");

        console.log("SUSDaiHub implementation:", address(implementation));
        console.log("SUSDaiHub proxy:", address(hub));
        console.log("");
        console.log("NEXT: step 2 on Base Sepolia takes this proxy address as HUB_ADDRESS.");
    }
}
