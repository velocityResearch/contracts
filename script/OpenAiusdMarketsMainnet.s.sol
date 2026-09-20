// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Reopen the NVDA, SPCX and AI markets quoted in `AIUSD` itself — the dollar registered
///         in the sUSDai reserve and held by its issuer — instead of in a unit minted per market.
///
/// @dev    Requires the factory upgrade that adds `createMarketForBrand`; the run reverts
///         otherwise, because the selector does not exist on the old implementation.
///
///         Per asset, in one transaction each, so a failure leaves the remaining assets exactly
///         as they were. Each asset's existing market is retired first: the pair's slot is what
///         `createMarketForBrand` needs free, and retiring leaves the old pool and its unit
///         standing for anyone holding either.
///
///         The listing is untouched. `unitName`/`unitSymbol` still describe the unit a plain
///         `createMarket` would mint for this asset, and are simply unused on this path — the
///         pool's currency is `AIUSD`, whose name and symbol belong to its issuer.
contract OpenAiusdMarketsMainnet is Script {
    function _assets() private pure returns (address[] memory assets) {
        assets = new address[](3);
        assets[0] = MainnetAddresses.NVDA;
        assets[1] = MainnetAddresses.SPCX;
        assets[2] = MainnetAddresses.AI;
    }

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        address brand = vm.envAddress("QUOTE_BRAND");
        address reserve = factory.reserveOfBrand(brand);

        require(reserve != address(0), "quote brand was not registered by this factory");
        require(
            factory.brandOperatorOf(brand) == deployer || factory.owner() == deployer,
            "signer may not quote markets in this brand"
        );

        address treasury = factory.treasuryOfBrand(brand);
        address treasuryAdminBefore = PoolBrandTreasury(treasury).admin();

        address[] memory assets = _assets();

        console.log("=== Opening markets quoted in an existing dollar ===");
        console.log("Factory:", address(factory));
        console.log("Reserve:", reserve);
        console.log("Quote brand:", brand);
        console.log("Quote symbol:", IERC20Metadata(brand).symbol());

        // Read every market before signing anything, so a unit somebody holds stops the batch
        // while it is still free to stop. Retiring strands no one, but replacing the market that
        // prices their dollar is not something to do behind their back.
        for (uint256 i = 0; i < assets.length; i++) {
            require(factory.assetListing(assets[i]).approved, "asset is not approved");
            uint256 id = factory.marketOfAsset(reserve, assets[i]);
            if (id == 0) continue;
            address unit = factory.market(id).brandToken;
            require(unit != brand, "this pair is already quoted in the brand");
            require(IERC20Metadata(unit).totalSupply() == 0, "market unit has supply");
        }

        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < assets.length; i++) {
            _reopen(factory, reserve, brand, assets[i]);
        }
        vm.stopBroadcast();

        // The dollar is quoted by these markets, not owned by them: nothing in the run may have
        // taken its float or its brand-to-market record.
        require(
            PoolBrandTreasury(treasury).admin() == treasuryAdminBefore,
            "the brand's treasury admin moved"
        );
        require(factory.marketOfBrand(brand) == 0, "the brand was claimed by a market");

        console.log("");
        console.log("Market count:", factory.marketCount());
        console.log("Each pool is EMPTY until someone adds liquidity.");
    }

    /// @dev Free the pair's slot, then open its market on the shared dollar.
    function _reopen(AssetMarketFactory factory, address reserve, address brand, address asset)
        private
    {
        uint256 existing = factory.marketOfAsset(reserve, asset);
        if (existing != 0) factory.retireMarket(existing);

        (uint256 marketId,, address lpDistributor,) = factory.createMarketForBrand(asset, brand);

        require(factory.market(marketId).brandToken == brand, "market is not quoted in the brand");
        require(factory.isSharedQuote(marketId), "market claimed the brand as its own unit");

        console.log("  asset:", asset);
        console.log("    retired market:", existing);
        console.log("    new market:", marketId);
        console.log("    lp distributor:", lpDistributor);
    }
}
