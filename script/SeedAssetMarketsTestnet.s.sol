// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @notice TESTNET ONLY. Opens the market for the faucet asset on a freshly deployed stack and
///         seeds it with full-range liquidity, so the frontend has a discoverable market to
///         read. ONE market: a reserve holds at most one market per asset, so a second one here
///         would need a second faucet token rather than a second name.
/// @dev No private key environment variable is read. Use --account with an encrypted keystore.
///      Run after DeployAssetMarketsTestnet, passing that run's printed addresses.
///
///      **There are no tick arguments — the range is always the whole curve — but there IS an
///      LP NFT.** The router mints each seed through Uniswap's v4 `PositionManager` and sends
///      the resulting `UNI-V4-POSM` token to whoever sent the transaction, so the seed is a
///      position this deployer owns and can close through the PositionManager directly. The
///      token id is printed below because it is the only handle to it; the router itself has no
///      withdrawal function and needs none.
contract SeedAssetMarketsTestnet is Script {
    /// @dev Balanced full-range seed of 10,000 whole assets. The brand side must match the
    ///      market's own price, not a fixed amount: a full-range position consumes the two
    ///      sides in the pool's price ratio, so seeding equal amounts into a market priced
    ///      away from 1.0 leaves one side unused and trips the minimum-used check.
    uint256 constant ASSET_WHOLE = 10_000;
    uint256 constant ASSET_IN = ASSET_WHOLE * 1e18;

    function run() external {
        require(block.chainid == 46630 || block.chainid == 31337, "testnet/local only");
        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("ROUTER"));
        IERC20 usdg = IERC20(vm.envAddress("USDG"));
        IERC20 asset = IERC20(vm.envAddress("ASSET"));
        SharedReservePool reserve = SharedReservePool(address(router.reservePool()));

        vm.startBroadcast(deployer);

        usdg.approve(address(router), type(uint256).max);
        asset.approve(address(router), type(uint256).max);
        usdg.approve(address(reserve), type(uint256).max);

        uint256 price = 1e18;
        uint256 id =
            _create(factory, deployer, address(asset), "Test Market Dollar", "tmUSD", price);

        _seed(factory, router, reserve, id, price, deployer);

        vm.stopBroadcast();

        console.log("Seeded market id:", id);
        console.log("Factory market count:", factory.marketCount());
    }

    /// @dev Two calls, because they answer to different authorities. Approving the asset is the
    ///      factory owner's decision and carries every economic parameter the market will ever
    ///      have — fee tier, starting price, oracle depth, the unit's name and symbol. Creating
    ///      it afterwards is permissionless and carries none. On a testnet stack the deployer is
    ///      both parties, which is the only reason this fits in one broadcast.
    function _create(
        AssetMarketFactory factory,
        address owner,
        address asset,
        string memory name,
        string memory symbol,
        uint256 priceE18
    ) internal returns (uint256 marketId) {
        require(factory.owner() == owner, "DEPLOYER does not own the factory");
        factory.approveAsset(
            asset,
            AssetMarketFactory.AssetListing({
                approved: true,
                // 0.50%, the tier this product launches on: the hook skims the other half of
                // the 1% headline fee off the input before the pool ever sees it.
                fee: 5000,
                assetPriceE18: priceE18,
                observationCardinality: 62,
                unitName: name,
                unitSymbol: symbol
            })
        );
        (marketId,,,,) = factory.createMarket(asset, address(0));
    }

    function _seed(
        AssetMarketFactory factory,
        MarketRouter router,
        SharedReservePool reserve,
        uint256 marketId,
        uint256 priceE18,
        address actor
    ) internal returns (uint256 liquidity) {
        // 10,000 whole assets are worth `10_000 * priceE18 / 1e18` whole brand units, and the
        // brand token carries USDG's 6 decimals. The 1e12 divisor folds both conversions.
        uint256 brandIn = (ASSET_WHOLE * priceE18) / 1e12;
        AssetMarketFactory.Market memory m = factory.market(marketId);

        // The stable side of a seed is the market's own brandUSD, minted at the reserve 1:1,
        // exactly as a provider does it before opening the liquidity form — not the reserve
        // asset itself. Approving USDG here instead is the pre-multi-reserve shape and reverts
        // `ERC20InsufficientAllowance` on the brand pull.
        reserve.mint(m.brandToken, brandIn, actor);
        IERC20(m.brandToken).approve(address(router), type(uint256).max);

        // `tokenId` is the LP NFT the position now lives in, minted to whoever sent this
        // transaction. It is logged because it is the handle they will need to manage or close
        // the position through Uniswap's `PositionManager` — the router has no way to do it.
        uint256 minBrand = (brandIn * 99) / 100;
        uint256 minAsset = (ASSET_IN * 99) / 100;
        uint256 deadline = block.timestamp + 1 hours;

        (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed) =
            router.seedLiquidity(marketId, brandIn, ASSET_IN, minBrand, minAsset, deadline);
        liquidity = liquidityAdded;
        require(liquidityAdded > 0, "no liquidity minted");
        console.log("  market", marketId, "liquidity", uint256(liquidityAdded));
        console.log("    brand used:", brandUsed, "asset used:", assetUsed);
        console.log("    LP position NFT (UNI-V4-POSM) token id:", tokenId);
    }
}
