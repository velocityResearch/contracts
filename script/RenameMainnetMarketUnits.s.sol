// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title RenameMainnetMarketUnits
/// @notice Reopens the NVDA, SPCX and AI markets with a chosen identity for their unit.
///
///         **A market's unit cannot be an existing brand.** `createMarket` always mints a new
///         `PooledBrandToken` from the owner's asset listing, so the only lever over what a
///         market is quoted in is `AssetListing.unitName`/`unitSymbol`, and it moves later
///         creations only. Renaming therefore means: retire the pair's market to free its slot,
///         re-list the asset with the new unit identity, and open the market again.
///
///         Per asset, in one transaction each, so a failure leaves the remaining assets exactly
///         as they were rather than half-renamed across a batch.
///
///         Each listing is read from the factory and only its two unit strings are replaced.
///         The fee tier, opening price and observation buffer stay byte-identical, which is what
///         keeps the new pool opening at the same price the current one shows.
///
///         The defaults below are each market's own unit — `nvdaUSD` for NVDA, and so on — which
///         is the identity a market unit should carry: it names the market it prices, and it
///         cannot be mistaken in a wallet for a dollar somebody issued. Borrowing an existing
///         brand's symbol for all three is what `UNIT_SYMBOL` does, and what it reads as on
///         chain is three more tokens wearing that symbol, not the brand itself.
///
///         `UNIT_SYMBOL` overrides the symbol for every asset; `UNIT_NAME` overrides the name.
contract RenameMainnetMarketUnits is Script {
    struct Plan {
        address asset;
        string unitName;
        string unitSymbol;
    }

    function _plans() private pure returns (Plan[] memory plans) {
        plans = new Plan[](3);
        plans[0] = Plan({
            asset: MainnetAddresses.NVDA, unitName: "NVIDIA Market Dollar", unitSymbol: "nvdaUSD"
        });
        plans[1] = Plan({
            asset: MainnetAddresses.SPCX, unitName: "SpaceX Market Dollar", unitSymbol: "spcxUSD"
        });
        plans[2] = Plan({
            asset: MainnetAddresses.AI,
            unitName: "Artificial Inu Market Dollar",
            unitSymbol: "inuUSD"
        });
    }

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        address owner = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        require(factory.owner() == owner, "DEPLOYER does not own the factory");

        address reserve = vm.envAddress("RESERVE");
        require(
            reserve == address(factory.reservePool()) || factory.approvedReservePool(reserve),
            "RESERVE is not approved by the factory"
        );
        string memory unitSymbol = vm.envOr("UNIT_SYMBOL", string(""));
        string memory unitName = vm.envOr("UNIT_NAME", string(""));

        Plan[] memory plans = _plans();

        console.log("=== Reopening markets with a renamed unit ===");
        console.log("Factory:", address(factory));
        console.log("Reserve:", reserve);
        console.log("Symbol override:", unitSymbol);
        console.log("Name override:", unitName);

        // Read every market before signing anything. A unit somebody holds must stop the batch
        // while it is still free to stop: retiring is harmless, but replacing the market that
        // prices their dollar is not something to do behind their back.
        for (uint256 i = 0; i < plans.length; i++) {
            require(factory.assetListing(plans[i].asset).approved, "asset is not approved");
            uint256 id = factory.marketOfAsset(reserve, plans[i].asset);
            if (id == 0) continue;
            require(
                IERC20Metadata(factory.market(id).brandToken).totalSupply() == 0,
                "market unit has supply"
            );
        }

        vm.startBroadcast(owner);
        for (uint256 i = 0; i < plans.length; i++) {
            _rename(factory, reserve, plans[i], unitName, unitSymbol);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Market count:", factory.marketCount());
        console.log("Each pool is EMPTY until someone adds liquidity.");
    }

    /// @dev Free the pair's slot, re-list the asset with the new unit identity, open it again.
    function _rename(
        AssetMarketFactory factory,
        address reserve,
        Plan memory plan,
        string memory unitName,
        string memory unitSymbol
    ) private {
        uint256 existing = factory.marketOfAsset(reserve, plan.asset);
        if (existing != 0) factory.retireMarket(existing);

        AssetMarketFactory.AssetListing memory listing = factory.assetListing(plan.asset);
        listing.unitName = bytes(unitName).length == 0 ? plan.unitName : unitName;
        listing.unitSymbol = bytes(unitSymbol).length == 0 ? plan.unitSymbol : unitSymbol;
        factory.approveAsset(plan.asset, listing);

        (uint256 marketId, address brandToken,,,) = factory.createMarket(plan.asset, reserve);

        console.log("  asset:", plan.asset);
        console.log("    retired market:", existing);
        console.log("    new market:", marketId);
        console.log("    new unit:", brandToken);
        console.log("    unit name:", listing.unitName);
        console.log("    unit symbol:", listing.unitSymbol);
        console.log("    opening price e18:", listing.assetPriceE18);
    }
}
