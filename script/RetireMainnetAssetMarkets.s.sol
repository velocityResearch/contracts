// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title RetireMainnetAssetMarkets
/// @notice Retires every market the factory currently holds — the three opened by
///         `OpenMainnetAssetMarkets` (NVDA, SPCX and AI in the sUSDai reserve) — so their
///         (reserve, asset) slots free and the markets can be opened again from the application.
///
///         **Retirement clears only the uniqueness slot.** The old pools keep trading, the old
///         units keep their holders and their reserve redemption; nothing here can strand anyone,
///         which is why the factory made it a one-line owner action. This script still refuses to
///         retire a market whose unit has any supply: this deployment's three pools were verified
///         empty, and a non-empty one would mean someone traded while this was being written.
contract RetireMainnetAssetMarkets is Script {
    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        address owner = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        require(factory.owner() == owner, "DEPLOYER does not own the factory");

        uint256 count = factory.marketCount();
        console.log("=== Retiring markets ===");
        console.log("Count:", count);
        console.log("Factory:", address(factory));

        // Check every market before signing anything: a pair that no longer holds its own slot,
        // or a unit somebody has crossed into, stops the batch while it is still free to stop.
        for (uint256 id = 1; id <= count; id++) {
            AssetMarketFactory.Market memory m = factory.market(id);
            require(factory.marketOfAsset(m.reservePool, m.asset) == id, "market lost its slot");
            require(IERC20Metadata(m.brandToken).totalSupply() == 0, "market unit has supply");
        }

        vm.startBroadcast(owner);
        for (uint256 id = 1; id <= count; id++) {
            AssetMarketFactory.Market memory m = factory.market(id);
            factory.retireMarket(id);
            console.log("  retired id:", id);
            console.log("    asset:", m.asset);
            console.log("    unit:", m.brandToken);
        }
        vm.stopBroadcast();

        for (uint256 id = 1; id <= count; id++) {
            AssetMarketFactory.Market memory m = factory.market(id);
            console.log("  slot for id:", id);
            console.log("    now holds market:", factory.marketOfAsset(m.reservePool, m.asset));
        }
        console.log("Each freed pair can now be opened again from the application.");
    }
}
