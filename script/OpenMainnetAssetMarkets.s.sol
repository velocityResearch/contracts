// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title OpenMainnetAssetMarkets
/// @notice Lists and opens the venue's first three markets — NVDA, SPCX and AI — on Robinhood
///         Chain mainnet.
///
///         Two calls per asset, answering to two different authorities. `approveAsset` is the
///         factory owner's decision and carries every economic parameter the market will ever
///         have: fee tier, opening price, oracle depth, and the name and symbol of the unit the
///         factory mints. `createMarket` afterwards is permissionless and carries none. The
///         owner is both parties here, which is the only reason this fits in one broadcast.
///
///         **The opening price is read off the chain at broadcast time, never hardcoded.** A
///         market is initialised at exactly the price its listing names, so a number typed into
///         a runbook days earlier opens the pool away from fair value and hands the first LP to
///         an arbitrageur. Each asset therefore gets its price from the live v3 pool it already
///         trades in, and each price is cross-checked against a second, independent source
///         before anything is signed:
///
///         - NVDA and SPCX trade in deep USDG pools with real oracle rings, so the price is the
///           30-minute TWAP and the spot must agree with it inside `MAX_DEVIATION_BPS`.
///         - AI's USDG pool has a ring of one and cannot serve a TWAP at all. Its price is spot,
///           cross-checked against AI/WETH × WETH/USDG — two routes an attacker would have to
///           move together, in the same block, to mislead this script.
///
///         Nothing is seeded. A fresh market's pool is empty until someone adds liquidity, and
///         seeding needs the asset itself rather than the owner's USDG, so it is a separate
///         step through `MarketRouter.seedLiquidity` or the application's liquidity screen.
///
///         Re-runnable. An asset that already has a market in the target reserve is skipped
///         rather than re-created, because uniqueness is per (reserve, asset) and a second
///         `createMarket` would revert `AssetAlreadyHasMarket` and take the whole batch with it.
///
///         Usage — simulate first, and read the prices it prints:
///           DEPLOYER=<owner> FACTORY=<factory> RESERVE=<reserve> forge script \
///             script/OpenMainnetAssetMarkets.s.sol --rpc-url robinhood
///         Then broadcast with the owner key:
///           DEPLOYER=<owner> FACTORY=<factory> RESERVE=<reserve> forge script \
///             script/OpenMainnetAssetMarkets.s.sol --rpc-url robinhood --broadcast \
///             --private-key $PRIVATE_KEY
///
///         `RESERVE` is optional: unset or zero selects the factory's default reserve, anything
///         else must be an `approvedReservePool`. The reserve decides what the market's unit is
///         backed by and which yield its float earns, so it is an explicit input rather than a
///         constant.
contract OpenMainnetAssetMarkets is Script {
    /// @notice 0.50%, the tier this product launches on: `ProtocolFeeHook` skims the other half
    ///         of the 1% headline fee off the input before the pool ever sees it.
    uint24 constant FEE = 5000;

    /// @notice Oracle ring each market is grown to. A ring of one is overwritten by the very
    ///         next swap, which leaves a market with a price history reaching back to its last
    ///         trade and no further — useless to anything that wants to price against a TWAP.
    uint16 constant CARDINALITY = 128;

    /// @notice The TWAP window read from a price source that has an oracle, and the tolerance
    ///         between a price and its cross-check. 5% is wide enough for a genuine intraday
    ///         move between two venues of different depth, and far narrower than the move an
    ///         attacker would need to make opening the pool profitable.
    uint32 constant TWAP_WINDOW = 1800;
    uint256 constant MAX_DEVIATION_BPS = 500;

    uint256 constant Q96 = 1 << 96;

    /// @param asset      The ERC20 being traded. The unit side is minted by the factory.
    /// @param quotePool  Live v3 pool pairing `asset` with USDG: the price source.
    /// @param crossPool  Pool pairing `asset` with WETH, read only when `quotePool` has no
    ///                   usable oracle. Zero means "this asset has a TWAP, don't need it".
    struct Plan {
        address asset;
        address quotePool;
        address crossPool;
        string unitName;
        string unitSymbol;
    }

    /// @dev Unit names follow the brands already in these reserves — "Stables AI USD", "Stables
    ///      Launch Dollar" — and every symbol here is checked against them. `AIUSD` is
    ///      deliberately NOT reused for the Artificial Inu market: a brand with that symbol is
    ///      already registered in the sUSDai reserve, and two identically-labelled dollars in
    ///      one reserve is a trap for whoever is reading the app rather than the chain.
    function _plans() private pure returns (Plan[] memory plans) {
        plans = new Plan[](3);
        plans[0] = Plan({
            asset: MainnetAddresses.NVDA,
            quotePool: MainnetAddresses.NVDA_USDG_POOL,
            crossPool: address(0),
            unitName: "NVIDIA Market Dollar",
            unitSymbol: "nvdaUSD"
        });
        plans[1] = Plan({
            asset: MainnetAddresses.SPCX,
            quotePool: MainnetAddresses.SPCX_USDG_POOL,
            crossPool: address(0),
            unitName: "SpaceX Market Dollar",
            unitSymbol: "spcxUSD"
        });
        plans[2] = Plan({
            asset: MainnetAddresses.AI,
            quotePool: MainnetAddresses.AI_USDG_POOL,
            crossPool: MainnetAddresses.AI_WETH_POOL,
            unitName: "Artificial Inu Market Dollar",
            unitSymbol: "inuUSD"
        });
    }

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        address owner = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        address requested = vm.envOr("RESERVE", address(0));

        require(factory.owner() == owner, "DEPLOYER does not own the factory");
        address defaultReserve = address(factory.reservePool());
        address reserve = requested == address(0) ? defaultReserve : requested;
        require(
            reserve == defaultReserve || factory.approvedReservePool(reserve),
            "RESERVE is not approved by the factory"
        );

        Plan[] memory plans = _plans();
        uint256[] memory prices = new uint256[](plans.length);

        console.log("=== Opening the first three markets ===");
        console.log("Factory:", address(factory));
        console.log("Reserve:", reserve);
        console.log("Reserve is the factory default:", reserve == defaultReserve);
        console.log("");

        // Read every price first, and read them all before anything is signed. A price that
        // fails its cross-check should stop the batch while it is still free to stop.
        for (uint256 i = 0; i < plans.length; i++) {
            prices[i] = _priceE18(plans[i]);
        }
        console.log("");

        vm.startBroadcast(owner);
        for (uint256 i = 0; i < plans.length; i++) {
            _open(factory, reserve, plans[i], prices[i]);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Factory market count:", factory.marketCount());
        console.log("Listed assets:", factory.listedAssetsLength());
        console.log("");
        console.log("Each pool is EMPTY until someone adds liquidity. Seeding needs the asset");
        console.log("itself, not USDG, so it is a separate step: mint the unit 1:1 at the");
        console.log("reserve, then MarketRouter.seedLiquidity, or use the liquidity screen.");
    }

    /// @dev One asset: list it on the owner's terms, then open its market. Re-approving is
    ///      allowed and moves later creations only, so an asset that already trades in this
    ///      reserve is left completely alone — re-listing it would be a no-op at best and a
    ///      changed listing for some future market at worst.
    function _open(AssetMarketFactory factory, address reserve, Plan memory plan, uint256 priceE18)
        private
    {
        string memory symbol = IERC20Metadata(plan.asset).symbol();

        uint256 existing = factory.marketOfAsset(reserve, plan.asset);
        if (existing != 0) {
            console.log(
                string.concat(symbol, ": already has market #"),
                existing,
                "in this reserve, skipping"
            );
            return;
        }

        factory.approveAsset(
            plan.asset,
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: FEE,
                assetPriceE18: priceE18,
                observationCardinality: CARDINALITY,
                unitName: plan.unitName,
                unitSymbol: plan.unitSymbol
            })
        );

        (uint256 marketId, address unit,, address lpDistributor,) =
            factory.createMarket(plan.asset, reserve);

        console.log(string.concat(symbol, " -> market #"), marketId);
        console.log(string.concat("    unit ", plan.unitSymbol, ":"), unit);
        console.log("    reward distributor:", lpDistributor);
        console.log("    verified equity:", factory.isCanonicalEquity(plan.asset));
    }

    /// @dev The price of one whole `asset` in whole reserve units, scaled by 1e18 — which is
    ///      what `AssetListing.assetPriceE18` means and what the factory turns into the pool's
    ///      opening `sqrtPriceX96`. Every reserve here is USDG-denominated, so a USDG price IS
    ///      a unit price: the unit is minted 1:1 against USDG.
    function _priceE18(Plan memory plan) private view returns (uint256 priceE18) {
        string memory symbol = IERC20Metadata(plan.asset).symbol();
        require(
            IUniswapV3PoolLike(plan.quotePool).liquidity() > 0,
            string.concat(symbol, ": price source pool has no liquidity")
        );
        _requirePair(plan.quotePool, plan.asset, MainnetAddresses.USDG, symbol);

        uint256 spot = _spotE18(plan.quotePool, plan.asset);
        uint256 check;
        string memory source;

        if (plan.crossPool == address(0)) {
            // The pool's own history is the second opinion, and the better one: a TWAP costs an
            // attacker the whole window rather than one block.
            check = _twapE18(plan.quotePool, plan.asset);
            priceE18 = check;
            source = "30-minute TWAP, spot agrees";
        } else {
            _requirePair(plan.crossPool, plan.asset, MainnetAddresses.WETH9, symbol);
            _requirePair(
                MainnetAddresses.WETH_USDG_POOL,
                MainnetAddresses.WETH9,
                MainnetAddresses.USDG,
                symbol
            );
            uint256 inWeth = _spotE18(plan.crossPool, plan.asset);
            uint256 wethInUsdg = _spotE18(MainnetAddresses.WETH_USDG_POOL, MainnetAddresses.WETH9);
            check = Math.mulDiv(inWeth, wethInUsdg, 1e18);
            priceE18 = spot;
            source = "spot, WETH route agrees";
        }

        _requireAgreement(spot, check, symbol);
        console.log(string.concat(symbol, " price (e18):"), priceE18);
        console.log(string.concat("    source: ", source));
        console.log("    spot (e18):", spot);
        console.log("    cross-check (e18):", check);
    }

    /// @dev Spot price of one whole `asset` in whole units of the pool's other token, e18.
    function _spotE18(address pool, address asset) private view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(pool).slot0();
        return _priceFromSqrt(pool, asset, sqrtPriceX96);
    }

    /// @dev The same, from the pool's `TWAP_WINDOW` arithmetic-mean tick. Reverts `OLD` inside
    ///      the pool when its ring cannot reach back that far, which is the honest failure: an
    ///      asset whose only price source has no history should not be listed silently.
    function _twapE18(address pool, address asset) private view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3PoolLike(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 window = int56(uint56(TWAP_WINDOW));

        int24 meanTick = int24(delta / window);
        // Solidity truncates toward zero; Uniswap's own TWAP rounds down. One tick is 0.01% and
        // would not change a decision, but matching the reference implementation costs nothing.
        if (delta < 0 && delta % window != 0) meanTick--;

        return _priceFromSqrt(pool, asset, TickMath.getSqrtPriceAtTick(meanTick));
    }

    /// @dev `sqrtPriceX96` is always "token1 per token0" in RAW units. Which side the asset is
    ///      on decides whether that ratio is inverted, and the two decimal scales decide the
    ///      rest, so both are read off the pool rather than assumed.
    function _priceFromSqrt(address pool, address asset, uint160 sqrtPriceX96)
        private
        view
        returns (uint256)
    {
        address token0 = IUniswapV3PoolLike(pool).token0();
        address token1 = IUniswapV3PoolLike(pool).token1();
        uint256 unit0 = 10 ** IERC20Metadata(token0).decimals();
        uint256 unit1 = 10 ** IERC20Metadata(token1).decimals();

        // P * 2^96, where P is raw token1 per raw token0. Split this way because sqrt^2 alone
        // overflows uint256 for a high-priced pair.
        uint256 scaled = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        require(scaled > 0, "pool price underflowed to zero");

        if (asset == token0) return Math.mulDiv(scaled, unit0 * 1e18, Q96 * unit1);

        // Invert through 2^96 as well, so the denominator never carries a decimal scale into
        // overflow territory for a cheap token against an expensive one.
        uint256 inverted = Math.mulDiv(Q96, Q96, scaled);
        return Math.mulDiv(inverted, unit1 * 1e18, Q96 * unit0);
    }

    function _requirePair(address pool, address tokenA, address tokenB, string memory label)
        private
        view
    {
        address token0 = IUniswapV3PoolLike(pool).token0();
        address token1 = IUniswapV3PoolLike(pool).token1();
        bool matches =
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA);
        require(matches, string.concat(label, ": price source pool holds the wrong pair"));
    }

    function _requireAgreement(uint256 a, uint256 b, string memory label) private pure {
        require(a > 0 && b > 0, string.concat(label, ": a price source returned zero"));
        uint256 high = a > b ? a : b;
        uint256 low = a > b ? b : a;
        require(
            (high - low) * 10_000 <= high * MAX_DEVIATION_BPS,
            string.concat(label, ": price sources disagree by more than 5%, refusing to list")
        );
    }
}
