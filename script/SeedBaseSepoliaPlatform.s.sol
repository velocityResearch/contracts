// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";

/// @notice Creates and seeds one Base Sepolia market so the deployed application has an
///         immediately usable catalog without consuming most of the deployer's faucet USDC.
contract SeedBaseSepoliaPlatform is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (uint256 marketId) {
        require(block.chainid == BASE_SEPOLIA, "Base Sepolia only");
        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("ROUTER"));
        IERC20 asset = IERC20(vm.envAddress("ASSET"));
        uint256 assetWhole = vm.envOr("ASSET_SEED_WHOLE", uint256(1));
        uint256 assetIn = assetWhole * 1e18;
        uint256 usdcIn = assetWhole * 1e6;

        require(deployer != address(0), "DEPLOYER is zero");
        require(assetWhole > 0, "ASSET_SEED_WHOLE is zero");
        require(factory.marketCount() == 0, "stack already seeded");
        require(address(router.factory()) == address(factory), "router factory mismatch");
        require(address(router.asset()) == BASE_USDC, "router reserve asset mismatch");
        require(IERC20(BASE_USDC).balanceOf(deployer) >= usdcIn, "deployer lacks Base USDC");
        require(asset.balanceOf(deployer) >= assetIn, "deployer lacks market asset");

        vm.startBroadcast(deployer);
        SharedReservePool reserve = factory.reservePool();
        // Approving the asset is the factory owner's call and carries everything economic;
        // creating the market afterwards is permissionless and carries nothing. The deployer is
        // both parties on a testnet stack, so both fit in this broadcast.
        require(factory.owner() == deployer, "DEPLOYER does not own the factory");
        factory.approveAsset(
            address(asset),
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: 5000,
                assetPriceE18: 1e18,
                observationCardinality: 62,
                unitName: "Base Test Dollar",
                unitSymbol: "baseUSD"
            })
        );
        (marketId,,,,) = factory.createMarket(address(asset), address(0));
        address brandToken = factory.market(marketId).brandToken;
        IERC20(BASE_USDC).forceApprove(address(reserve), usdcIn);
        reserve.mint(brandToken, usdcIn, deployer);
        IERC20(brandToken).forceApprove(address(router), usdcIn);
        asset.forceApprove(address(router), assetIn);
        (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed) = router.seedLiquidity(
            marketId,
            usdcIn,
            assetIn,
            usdcIn * 99 / 100,
            assetIn * 99 / 100,
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        require(liquidity > 0, "no liquidity minted");
        console.log("Seeded Base Sepolia market id:", marketId);
        console.log("Brand token:", factory.market(marketId).brandToken);
        console.log("Liquidity:", uint256(liquidity));
        console.log("Brand used:", brandUsed);
        console.log("Asset used:", assetUsed);
        console.log("LP position NFT:", tokenId);
    }
}
