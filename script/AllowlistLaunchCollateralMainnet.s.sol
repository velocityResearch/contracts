// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Open a dollar for launches: its curve economics, then its approval.
///
/// @dev    A launch is priced in a quote brand the owner has approved, and `createLaunch` reverts
///         `PairTokenNotApproved` for anything else. The application offers every representation
///         brand in a reserve as a choice, so a dollar the owner has not opened here is a choice
///         that cannot be launched against — which is why this exists as its own script rather
///         than as a step inside a deploy.
///
///         **The economics are copied from a dollar that already works, never invented.** Only
///         `graduationThreshold / (graduationThreshold + phantomQuote)` decides what fraction of
///         supply reaches the graduated pool, so copying both figures from an approved dollar of
///         the same decimals gives the new one an identical curve. `TEMPLATE` names that dollar;
///         `TARGET` is the one being opened. Both must be brands of the same reserve, because the
///         reserve recorded here is where the launch graduates.
contract AllowlistLaunchCollateralMainnet is Script {
    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        LaunchFactory launches = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        AssetMarketFactory markets = AssetMarketFactory(vm.envAddress("FACTORY"));
        address target = vm.envAddress("TARGET");
        address template = vm.envAddress("TEMPLATE");

        require(launches.owner() == deployer, "signer does not own the launch factory");

        LaunchFactory.PairTokenEconomics memory from = _economics(launches, template);
        require(from.approved, "TEMPLATE is not an approved quote brand");

        // The reserve a launch graduates into has to be the one that can mint and redeem the
        // dollar it was funded in, or graduation would seed a pool against a dollar its reserve
        // never issued.
        address reserve = markets.reserveOfBrand(target);
        require(reserve != address(0), "TARGET was not registered by the market factory");
        require(reserve == from.reserve, "TARGET and TEMPLATE belong to different reserves");

        uint8 decimals = IERC20Metadata(target).decimals();
        require(decimals == from.decimals, "TARGET and TEMPLATE are scaled differently");

        LaunchFactory.PairTokenEconomics memory to = LaunchFactory.PairTokenEconomics({
            reserve: reserve,
            phantomQuote: from.phantomQuote,
            graduationThreshold: from.graduationThreshold,
            launchFee: from.launchFee,
            decimals: decimals,
            approved: true
        });

        console.log("=== Opening a dollar for launches ===");
        console.log("Launch factory:", address(launches));
        console.log("Target:", IERC20Metadata(target).symbol(), target);
        console.log("Copied from:", IERC20Metadata(template).symbol(), template);
        console.log("Reserve:", reserve);
        console.log("Phantom quote:", to.phantomQuote);
        console.log("Graduation threshold:", to.graduationThreshold);
        console.log("Launch fee:", to.launchFee);

        vm.startBroadcast(deployer);
        launches.setPairTokenEconomics(target, to);
        // Economics first, approval second: `setPairTokenApproved` refuses a brand with no
        // `phantomQuote`, which is the same ordering this enforces by doing them in one run.
        launches.setPairTokenApproved(target, true);
        vm.stopBroadcast();

        LaunchFactory.PairTokenEconomics memory written = _economics(launches, target);
        require(written.approved, "TARGET did not end up approved");
        require(written.reserve == reserve, "reserve did not take");
        require(written.phantomQuote == from.phantomQuote, "phantom quote did not take");
        require(written.graduationThreshold == from.graduationThreshold, "threshold did not take");

        console.log("");
        console.log("Approved. Launches may now be funded in this dollar.");
    }

    function _economics(LaunchFactory launches, address pairToken)
        private
        view
        returns (LaunchFactory.PairTokenEconomics memory e)
    {
        (
            address reserve,
            uint256 phantomQuote,
            uint256 graduationThreshold,
            uint256 launchFee,
            uint8 decimals,
            bool approved
        ) = launches.pairTokenEconomics(pairToken);
        e = LaunchFactory.PairTokenEconomics({
            reserve: reserve,
            phantomQuote: phantomQuote,
            graduationThreshold: graduationThreshold,
            launchFee: launchFee,
            decimals: decimals,
            approved: approved
        });
    }
}
