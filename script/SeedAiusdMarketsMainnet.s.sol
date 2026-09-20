// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Put the first liquidity into the three AIUSD-quoted markets, from the deployer's own
///         USDG and its own holdings of each asset.
///
/// @dev    Two legs per market, and the first is what makes the quote side exist: USDG is minted
///         1:1 into AIUSD at the reserve, so the dollars in the pool are backed float rather
///         than something conjured for a test. Then the router seeds the pair.
///
///         **Sized off the wallet, not off a round number.** The asset side is the scarce one
///         here — a few hundred dollars of each — so each market gets `ASSET_BPS` basis points of
///         whatever the wallet holds, and the AIUSD side is derived from the pool's own live
///         price so the two arrive in proportion. Seeding full range at spot consumes both sides
///         evenly; whatever the position does not take is refunded by the router in the same
///         call, which is why the quote side is deliberately over-supplied by `QUOTE_SLACK_BPS`.
contract SeedAiusdMarketsMainnet is Script {
    uint256 constant BPS = 10_000;

    function _markets() private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = 13;
        ids[1] = 14;
        ids[2] = 15;
    }

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("ROUTER"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("RESERVE"));
        IERC20 usdg = IERC20(MainnetAddresses.USDG);

        // A fraction of the wallet, so this is a real test of the flow rather than a commitment
        // of everything the wallet holds.
        uint256 assetBps = vm.envOr("ASSET_BPS", uint256(1500));
        uint256 quoteSlackBps = vm.envOr("QUOTE_SLACK_BPS", uint256(1000));

        uint256[] memory ids = _markets();

        console.log("=== Seeding the AIUSD-quoted markets ===");
        console.log("Asset share, bps:", assetBps);
        console.log("USDG held:", usdg.balanceOf(deployer));

        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < ids.length; i++) {
            _seed(factory, router, reserve, usdg, deployer, ids[i], assetBps, quoteSlackBps);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("USDG left:", usdg.balanceOf(deployer));
    }

    function _seed(
        AssetMarketFactory factory,
        MarketRouter router,
        SharedReservePool reserve,
        IERC20 usdg,
        address deployer,
        uint256 marketId,
        uint256 assetBps,
        uint256 quoteSlackBps
    ) private {
        AssetMarketFactory.Market memory m = factory.market(marketId);

        uint256 assetIn = IERC20(m.asset).balanceOf(deployer) * assetBps / BPS;
        require(assetIn > 0, "wallet holds none of this asset");

        // The owner's listing price, which is what these pools were opened at and — until
        // somebody trades one — is still exactly their spot, so the two sides arrive in the
        // ratio a full-range position at spot consumes. One whole asset in whole quote units
        // scaled by 1e18, against a six-decimal quote: hence the 1e12.
        uint256 priceE18 = factory.assetListing(m.asset).assetPriceE18;
        uint8 assetDecimals = IERC20Metadata(m.asset).decimals();
        uint256 quoteIn =
            assetIn * priceE18 / (10 ** assetDecimals) * (BPS + quoteSlackBps) / BPS / 1e12;
        require(quoteIn > 0, "asset share is too small to price");

        // Mint the quote side into existence as backed float: USDG in, AIUSD out, 1:1.
        usdg.approve(address(reserve), quoteIn);
        reserve.mint(m.brandToken, quoteIn, deployer);

        IERC20(m.brandToken).approve(address(router), quoteIn);
        IERC20(m.asset).approve(address(router), assetIn);

        (, uint128 liquidity, uint256 quoteUsed, uint256 assetUsed) =
            router.seedLiquidity(marketId, quoteIn, assetIn, 0, 0, block.timestamp + 600);
        require(liquidity > 0, "the position took nothing");

        console.log("  market:", marketId);
        console.log("    asset offered:", assetIn);
        console.log("    asset used:", assetUsed);
        console.log("    quote offered:", quoteIn);
        console.log("    quote used:", quoteUsed);
        console.log("    liquidity:", liquidity);
    }
}
