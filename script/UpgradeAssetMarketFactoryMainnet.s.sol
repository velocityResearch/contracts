// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Point the live mainnet `AssetMarketFactory` proxy at a fresh implementation.
///
/// @dev    What this upgrade adds is `createMarketForBrand`: a market quoted in a dollar that
///         already exists, rather than in a unit minted for it. Nothing existing changes shape —
///         `createMarket` and `createLaunchMarket` take the same arguments, return the same
///         values and write the same records, and the three writes a shared quote skips are
///         behind a flag that only the new path sets. So no frontend has to move with this.
///
///         **No storage variable was added or moved**, which is why `upgradeToAndCall` carries
///         empty calldata: the new path needs no state of its own, and `isSharedQuote` is read
///         from the `marketOfBrand` record that was always there.
///
///         Rehearsed against real chain state in `test/markets/SharedQuoteMainnetFork.t.sol`,
///         which upgrades this same proxy on a fork and reads an existing market back through it
///         before opening anything new. The proxy is owned by the deployer EOA with no timelock,
///         so this takes effect the moment it is mined.
contract UpgradeAssetMarketFactoryMainnet is Script {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (address implementation) {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory proxy = AssetMarketFactory(vm.envAddress("FACTORY"));
        require(proxy.owner() == deployer, "signer does not own this proxy");

        address proxyAddress = address(proxy);
        address before = address(uint160(uint256(vm.load(proxyAddress, IMPL_SLOT))));

        // Read the state that must survive, through the proxy, before touching it. A layout
        // mistake is only visible as a comparison, so the "after" reads below need a "before".
        uint256 marketCount = proxy.marketCount();
        AssetMarketFactory.Market memory sample = proxy.market(marketCount);

        vm.startBroadcast(deployer);
        AssetMarketFactory fresh = new AssetMarketFactory();
        proxy.upgradeToAndCall(address(fresh), "");
        vm.stopBroadcast();

        implementation = address(uint160(uint256(vm.load(proxyAddress, IMPL_SLOT))));
        require(implementation == address(fresh), "the proxy did not move");

        // Every one of these is read back through the proxy: the point is that the storage behind
        // it still answers the same way, which is exactly what a shifted slot would break.
        require(proxy.owner() == deployer, "owner moved");
        require(proxy.marketCount() == marketCount, "market count moved");
        AssetMarketFactory.Market memory after_ = proxy.market(marketCount);
        require(after_.brandToken == sample.brandToken, "market unit moved");
        require(after_.poolId == sample.poolId, "market pool moved");
        require(after_.feeVault == sample.feeVault, "market vault moved");
        require(after_.reservePool == sample.reservePool, "market reserve moved");
        require(
            proxy.marketOfAsset(sample.reservePool, sample.asset) == marketCount, "pair slot moved"
        );
        require(!proxy.isSharedQuote(marketCount), "a unit-quoted market read as shared");

        console.log("AssetMarketFactory proxy:", proxyAddress);
        console.log("implementation before:  ", before);
        console.log("implementation after:   ", implementation);
        console.log("markets still recorded: ", marketCount);
    }
}
