// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IYieldSource} from "../src/interfaces/IYieldSource.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketLens} from "../src/markets/MarketLens.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @title DeployMarketLens
/// @notice Deploy the read-only quoting lens aggregators integrate against.
///
///         **This changes nothing that is already deployed.** One `CREATE`; no proxy, no owner,
///         no transaction to any existing contract. Every market the factory knows is covered
///         the moment it lands, and so is every market created afterwards.
///
///         Usage, against the recorded stack:
///
///         PRIVATE_KEY=0x... ASSET_MARKET_FACTORY=0x... \
///           forge script script/DeployMarketLens.s.sol --rpc-url robinhood --broadcast
///
///         There is no quoter argument. The lens replays the v4 swap itself from state read
///         through `extsload` (`V4SwapSimulator`), which is what makes every quote a `view`
///         and therefore reachable by an aggregator's batched `STATICCALL`. It reads the
///         `PoolManager` off the factory, so it cannot be bound to the wrong one.
///
///         The readback at the end reports market 1's reserve caps and then takes a real
///         quote through a `STATICCALL`, which is the property this deployment exists for:
///         if that call reverts, the lens is not samplable and the deploy is wrong.
///         `test/markets/MarketLens.t.sol` is where the quotes are checked against the
///         router's real fills, and `MarketLensSimulatorFork` against the deployed
///         `V4Quoter` on mainnet.
contract DeployMarketLens is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));

        // Every reserve this lens will be asked about must answer `withdrawable`, because
        // `redeemableAssets` calls it unguarded and on purpose: a lens that swallowed a
        // missing selector would answer every sell quote with the pool's idle balance — a
        // number that looks like a drained venue rather than a misconfiguration. Checking it
        // here means the mistake is a refused deploy instead of a silently delisted market.
        // Run `UpgradeAggregatorSurfaceMainnet.s.sol` first if this fails.
        _requireWithdrawable(factory.reservePool());
        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            address recorded = factory.market(id).reservePool;
            if (recorded != address(0)) _requireWithdrawable(SharedReservePool(recorded));
        }

        vm.startBroadcast(deployerKey);
        MarketLens lens = new MarketLens(factory);
        vm.stopBroadcast();

        require(address(lens.factory()) == address(factory), "factory mismatch");

        console.log("");
        console.log("MarketLens           ", address(lens));
        console.log("  factory            ", address(factory));
        console.log("  poolManager        ", address(lens.poolManager()));
        console.log("  markets covered    ", factory.marketCount());

        if (factory.marketCount() > 0) {
            SharedReservePool reserve = lens.reserveOf(1);
            console.log("  market 1 reserve   ", address(reserve));
            console.log("    maxMint          ", lens.maxMint(reserve));
            console.log("    redeemableAssets ", lens.redeemableAssets(reserve));

            // The whole point of this deployment: a quote a STATICCALL can reach. Asked
            // through a low-level static call rather than a typed one so the EVM enforces
            // it, instead of solc trusting the `view` in the ABI.
            (bool quotable, bytes memory quote) = address(lens)
                .staticcall(
                    abi.encodeCall(MarketLens.quoteBuy, (_firstLiveMarket(lens, factory), 1e6))
                );
            require(quotable && quote.length == 64, "lens quote is not STATICCALL-able");
            (uint256 out, uint256 gasEstimate) = abi.decode(quote, (uint256, uint256));
            console.log("    quoteBuy(1 unit) ", out);
            console.log("    gasEstimate      ", gasEstimate);
        }
        console.log("");
        console.log("Nothing already deployed was modified. Record the address under");
        console.log("core.marketLens in the chain's deployments manifest.");
    }

    /// @dev The lowest market id with liquidity, for the readback quote. A stack whose early
    ///      ids are drained leftovers — gen-6's are — would otherwise prove nothing but that
    ///      an empty pool reverts.
    function _firstLiveMarket(MarketLens lens, AssetMarketFactory factory)
        private
        view
        returns (uint256)
    {
        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            (bool ok,) = address(lens).staticcall(abi.encodeCall(MarketLens.quoteBuy, (id, 1e6)));
            if (ok) return id;
        }
        revert("no market answers a quote");
    }

    /// @dev A reserve whose adapter predates `IYieldSource.withdrawable`. Named in the revert
    ///      so a failed run says which one to upgrade rather than just that something is old.
    function _requireWithdrawable(SharedReservePool pool) private view {
        IYieldSource source = pool.yieldSource();
        if (address(source) == address(0)) return;

        (bool answers,) = address(source)
            .staticcall(
                abi.encodeCall(IYieldSource.withdrawable, (address(pool.asset()), address(pool)))
            );
        require(
            answers,
            string.concat(
                "yield source ",
                vm.toString(address(source)),
                " of reserve ",
                vm.toString(address(pool)),
                " has no withdrawable(); upgrade it first"
            )
        );
    }
}
