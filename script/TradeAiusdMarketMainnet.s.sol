// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Buy an asset with `AIUSD` and sell it back, against a live AIUSD-quoted market.
///
/// @dev    The point is the leg the shared quote made possible: `buyWithBrand` is handed the
///         dollar the holder actually owns, and because that dollar *is* this pool's currency
///         there is no cross on the way in — the market settles in AIUSD directly.
///
///         Both legs are deliberately tiny against the seeded depth, and both minimums are
///         derived from the owner's listing price rather than passed as zero: a zero minimum
///         would make this a sandwich waiting to happen, and would also fill happily against a
///         pool priced at the reciprocal instead of failing.
contract TradeAiusdMarketMainnet is Script {
    uint256 constant BPS = 10_000;

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address trader = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("ROUTER"));
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 quoteIn = vm.envOr("QUOTE_IN", uint256(1_000_000));
        // Wide enough to survive this trade's own impact on a freshly seeded pool, tight enough
        // that a pool priced upside down fails rather than fills.
        uint256 toleranceBps = vm.envOr("TOLERANCE_BPS", uint256(2_000));

        AssetMarketFactory.Market memory m = factory.market(marketId);
        require(factory.isSharedQuote(marketId), "not a shared-quote market");

        IERC20 quote = IERC20(m.brandToken);
        IERC20 asset = IERC20(m.asset);
        uint256 priceE18 = factory.assetListing(m.asset).assetPriceE18;
        uint8 assetDecimals = IERC20Metadata(m.asset).decimals();

        uint256 quoteBefore = quote.balanceOf(trader);
        uint256 assetBefore = asset.balanceOf(trader);
        require(quoteBefore >= quoteIn, "not enough of the quote dollar");

        // One whole asset costs `priceE18 / 1e18` of a six-decimal dollar, so this is what
        // `quoteIn` buys at the listing price, before impact and fee.
        uint256 fairAsset = quoteIn * 1e12 * (10 ** assetDecimals) / priceE18;
        uint256 minAsset = fairAsset * (BPS - toleranceBps) / BPS;

        console.log("=== Trading a market quoted in AIUSD ===");
        console.log("Market:", marketId);
        console.log("Quote dollar:", m.brandToken);
        console.log("Spending, quote units:", quoteIn);
        console.log("Minimum asset out:", minAsset);

        vm.startBroadcast(trader);
        quote.approve(address(router), quoteIn);
        uint256 assetOut = router.buyWithBrand(
            marketId, m.brandToken, quoteIn, minAsset, trader, block.timestamp + 600
        );

        // Sell half of what the buy delivered, so the round trip is proven in both directions
        // against the same pool.
        uint256 assetIn = assetOut / 2;
        uint256 fairQuote = assetIn * priceE18 / (10 ** assetDecimals) / 1e12;
        uint256 minQuote = fairQuote * (BPS - toleranceBps) / BPS;
        asset.approve(address(router), assetIn);
        uint256 quoteOut =
            router.sellForBrand(marketId, assetIn, minQuote, trader, block.timestamp + 600);
        vm.stopBroadcast();

        console.log("");
        console.log("Asset bought:", assetOut);
        console.log("Asset sold back:", assetIn);
        console.log("Quote returned:", quoteOut);
        console.log("Quote balance before:", quoteBefore);
        console.log("Quote balance after:", quote.balanceOf(trader));
        console.log("Asset balance before:", assetBefore);
        console.log("Asset balance after:", asset.balanceOf(trader));

        require(assetOut >= minAsset, "buy delivered less than the floor");
        require(quoteOut >= minQuote, "sell delivered less than the floor");
        require(asset.balanceOf(trader) == assetBefore + assetOut - assetIn, "asset did not move");
    }
}
