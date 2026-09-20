// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IV4Quoter} from "../src/interfaces/IV4Quoter.sol";
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
///         PRIVATE_KEY=0x... ASSET_MARKET_FACTORY=0x... V4_QUOTER=0x... \
///           forge script script/DeployMarketLens.s.sol --rpc-url robinhood --broadcast
///
///         `V4_QUOTER` is Uniswap's stock quoter for this chain's `PoolManager`, deployed by
///         `script/deploy-v4-lens.sh`. It is identity-checked here: a quoter bound to another
///         PoolManager would answer every market with `NotEnoughLiquidity`.
///
///         The readback at the end reports market 1's reserve caps. Those are plain views, so
///         what they prove is that the lens reaches the factory, the market record and the
///         reserve's yield source — not that a quote is right; `test/markets/MarketLens.t.sol`
///         is where the quotes are checked against the router's real fills. The quoter itself
///         is proved by the identity check above, and is not exercised here because a quote
///         costs a full pool simulation inside a broadcast run that has no need of one.
contract DeployMarketLens is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));
        address quoter = vm.envAddress("V4_QUOTER");

        require(quoter.code.length > 0, "V4_QUOTER has no code");
        (bool ok, bytes memory ret) = quoter.staticcall(abi.encodeWithSignature("poolManager()"));
        require(ok && ret.length == 32, "V4_QUOTER does not name a poolManager");
        require(
            abi.decode(ret, (address)) == address(factory.poolManager()),
            "V4_QUOTER is bound to a different PoolManager than the factory"
        );

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
        MarketLens lens = new MarketLens(factory, IV4Quoter(quoter));
        vm.stopBroadcast();

        require(address(lens.factory()) == address(factory), "factory mismatch");
        require(address(lens.quoter()) == quoter, "quoter mismatch");

        console.log("");
        console.log("MarketLens           ", address(lens));
        console.log("  factory            ", address(factory));
        console.log("  quoter             ", quoter);
        console.log("  markets covered    ", factory.marketCount());

        if (factory.marketCount() > 0) {
            SharedReservePool reserve = lens.reserveOf(1);
            console.log("  market 1 reserve   ", address(reserve));
            console.log("    maxMint          ", lens.maxMint(reserve));
            console.log("    redeemableAssets ", lens.redeemableAssets(reserve));
        }
        console.log("");
        console.log("Nothing already deployed was modified. Record the address under");
        console.log("core.marketLens in the chain's deployments manifest.");
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
