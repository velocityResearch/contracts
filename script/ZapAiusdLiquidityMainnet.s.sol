// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {LiquidityZapper} from "../src/markets/LiquidityZapper.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice One-transaction USDG liquidity into a market quoted in a dollar the zapper was not
///         built against.
///
/// @dev    Written to settle a question rather than to ship a feature: the application hid the
///         one-transaction deposit for these markets, on the grounds that the deployed zapper's
///         own `reservePool` is the USDG reserve while the markets sit in the sUSDai one.
///
///         That reasoning was wrong, and this proves it. `LiquidityZapper._mintBrand` resolves
///         the reserve from the market's own record and only falls back to its constructor's when
///         that record carries none, so one zapper serves every reserve on its factory. The
///         market's dollar is minted where the market says it lives.
contract ZapAiusdLiquidityMainnet is Script {
    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address funder = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        LiquidityZapper zapper = LiquidityZapper(payable(vm.envAddress("ZAPPER")));
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 usdgIn = vm.envOr("USDG_IN", uint256(3_000_000));
        // Half the deposit buys the asset, which is what a full-range position at spot consumes.
        uint256 swapBps = vm.envOr("SWAP_BPS", uint256(5_000));

        AssetMarketFactory.Market memory m = factory.market(marketId);
        IERC20 usdg = IERC20(MainnetAddresses.USDG);

        require(address(zapper.factory()) == address(factory), "zapper serves another factory");
        require(usdg.balanceOf(funder) >= usdgIn, "not enough USDG");

        console.log("=== One-transaction liquidity, across reserves ===");
        console.log("Market:", marketId);
        console.log("Market's reserve:", m.reservePool);
        console.log("Zapper's own reserve:", address(zapper.reservePool()));
        console.log("Quote dollar:", m.brandToken);
        console.log("USDG in:", usdgIn);

        uint256 usdgBefore = usdg.balanceOf(funder);

        vm.startBroadcast(funder);
        usdg.approve(address(zapper), usdgIn);
        (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed) =
            zapper.zapLiquidity(marketId, usdgIn, swapBps, 0, block.timestamp + 600);
        vm.stopBroadcast();

        console.log("");
        console.log("Position token id:", tokenId);
        console.log("Liquidity added:", liquidityAdded);
        console.log("Quote used:", brandUsed);
        console.log("Asset used:", assetUsed);
        console.log("USDG spent:", usdgBefore - usdg.balanceOf(funder));

        require(liquidityAdded > 0, "the position took nothing");
        require(brandUsed > 0 && assetUsed > 0, "a full-range seed uses both sides");
        require(
            address(zapper.reservePool()) != m.reservePool,
            "this run proves nothing unless the two reserves differ"
        );
    }
}
