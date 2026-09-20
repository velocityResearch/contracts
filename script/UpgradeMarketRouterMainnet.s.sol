// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MarketRouter} from "../src/markets/MarketRouter.sol";

/// @notice Point the live mainnet `MarketRouter` proxy at a fresh implementation.
///
/// @dev    Two breaking changes ride along, and both mean the frontend and the implementation
///         have to move together:
///
///         - `seedLiquidity` changed shape without changing selector: it takes the market's own
///           brandUSD where it took USDG. A frontend built against the new source and pointed at
///           the old implementation approves one token and has the other pulled.
///         - `sellForUsdg` is gone, replaced by `sellForBrand`, which stops at the market's own
///           dollar instead of redeeming to USDG in the same transaction. The old selector stops
///           answering the moment this is mined, so every sell from a frontend still built
///           against it reverts. Redeeming is unchanged and unconditional at
///           `SharedReservePool.redeem`, so a seller reaches USDG in one more call of their own.
///
///         Rehearsed first in `test/markets/RouterUpgradeMainnetFork.t.sol` against real chain
///         state.
///
///         No storage variable was added or moved, so the upgrade carries no initializer call —
///         `upgradeToAndCall` is given empty calldata deliberately. The proxy is owned by the
///         deployer EOA with no timelock, which is CRITICAL-1 in the audit and the reason this
///         takes effect the moment it is mined.
contract UpgradeMarketRouterMainnet is Script {
    address constant PROXY = 0xcCDe2EcDE7072Efe61822551152663F204CF73ce;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (address implementation) {
        require(block.chainid == 4663, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");
        MarketRouter proxy = MarketRouter(PROXY);
        require(proxy.owner() == deployer, "signer does not own this proxy");

        address before = address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));

        vm.startBroadcast(deployer);
        MarketRouter fresh = new MarketRouter();
        proxy.upgradeToAndCall(address(fresh), "");
        vm.stopBroadcast();

        implementation = address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));
        require(implementation == address(fresh), "the proxy did not move");

        // Read back through the proxy, not from the script's own memory: the point is that the
        // storage behind it still answers, which is what a layout mistake would break.
        require(proxy.owner() == deployer, "owner moved");
        require(address(proxy.positionManager()) != address(0), "wiring moved");

        console.log("MarketRouter proxy:   ", PROXY);
        console.log("implementation before:", before);
        console.log("implementation after: ", implementation);
    }
}
