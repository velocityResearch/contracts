// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";

/// @notice Launches a stablecoin backed by the bridged sUSDai reserve together with its market,
///         through the same factory and router the USDC-backed market already uses.
///
///         This is the path the application's issuance flow now drives, exercised from a script
///         so the deployed catalogue has a live example: one `createMarket` naming the sUSDai
///         reserve, one mint against that reserve, one seeded v4 position. The same asset
///         already has a market in the USDC reserve, and that is fine — uniqueness is per
///         (reserve, asset) pair, so a second reserve is a second market.
contract SeedBaseSepoliaSUSDaiMarket is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (uint256 marketId, address brandToken) {
        require(block.chainid == BASE_SEPOLIA, "Base Sepolia only");
        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("ROUTER"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("SUSDAI_RESERVE"));
        IERC20 asset = IERC20(vm.envAddress("ASSET"));
        uint256 usdcIn = vm.envOr("USDC_SEED", uint256(1e6));
        uint256 assetIn = vm.envOr("ASSET_SEED", uint256(1e18));

        require(factory.approvedReservePool(address(reserve)), "reserve is not approved");
        require(address(router.factory()) == address(factory), "router factory mismatch");
        require(address(reserve.asset()) == BASE_USDC, "reserve asset mismatch");
        require(IERC20(BASE_USDC).balanceOf(deployer) >= usdcIn, "deployer lacks Base USDC");
        require(asset.balanceOf(deployer) >= assetIn, "deployer lacks market asset");

        vm.startBroadcast(deployer);
        // The asset is already listed if the USDC market was seeded first, and re-approving is
        // allowed: a listing moves later creations only and this one asks for the same terms.
        require(factory.owner() == deployer, "DEPLOYER does not own the factory");
        factory.approveAsset(
            address(asset),
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: 5000,
                assetPriceE18: 1e18,
                observationCardinality: 62,
                unitName: "Base Solar Dollar",
                unitSymbol: "solUSD"
            })
        );
        (marketId, brandToken,,,) = factory.createMarket(address(asset), address(reserve));

        IERC20(BASE_USDC).forceApprove(address(reserve), usdcIn);
        reserve.mint(brandToken, usdcIn, deployer);
        IERC20(brandToken).forceApprove(address(router), usdcIn);
        asset.forceApprove(address(router), assetIn);
        (uint256 tokenId, uint128 liquidity,,) = router.seedLiquidity(
            marketId,
            usdcIn,
            assetIn,
            usdcIn * 99 / 100,
            assetIn * 99 / 100,
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        require(liquidity > 0, "no liquidity minted");
        require(
            factory.market(marketId).reservePool == address(reserve), "market records wrong reserve"
        );
        require(reserve.isRegistered(brandToken), "brand is not in the sUSDai reserve");

        console.log("sUSDai-backed market id:", marketId);
        console.log("Brand token:", brandToken);
        console.log("Liquidity:", uint256(liquidity));
        console.log("LP position NFT:", tokenId);
    }
}
