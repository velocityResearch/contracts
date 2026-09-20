// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";

/// @notice Completes the cross-chain cycle after the Robinhood testnet adapter address exists.
contract ConfigureSUSDaiTestnetRemote is Script {
    function run() external {
        require(block.chainid == 421614 || block.chainid == 31337, "Arbitrum Sepolia/local only");
        address deployer = vm.envAddress("SUSDAI_DEPLOYER");
        SUSDaiHub hub = SUSDaiHub(vm.envAddress("REMOTE_HUB"));
        address adapter = vm.envAddress("HOME_ADAPTER");
        require(deployer != address(0) && adapter != address(0), "wiring is zero");
        require(address(hub).code.length > 0, "REMOTE_HUB has no code");
        require(hub.owner() == deployer, "SUSDAI_DEPLOYER is not hub owner");

        vm.startBroadcast(deployer);
        hub.setHomeReceiver(adapter);
        vm.stopBroadcast();

        require(hub.homeReceiver() == adapter, "home receiver mismatch");
        console.log("Arbitrum Sepolia hub configured for adapter:", adapter);
    }
}
