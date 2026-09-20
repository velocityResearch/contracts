// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {MorphoBlueYieldSource} from "../src/yield/MorphoBlueYieldSource.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";

/// @notice Give the live gen-6 stack the surface an aggregator settles against: one router
///         call per direction, and a liquidity view on every yield source.
///
/// @dev    **This release is PARTIALLY APPLIED on mainnet and re-running it is the fix.** The
///         original run landed on both adapters and not on `MarketRouter`: the adapters answer
///         `withdrawable(address,address)` on chain, and `sellForUsdg` is absent from the live
///         router implementation `0x3c09784b3e771f57fe0f6651292bbb470e7bacbe`, which has never
///         been upgraded (one `Upgraded` event, at deploy). `run()` now decides each leg
///         independently by whether that leg's new selector already answers, so re-running
///         upgrades only the router and leaves the two adapters alone. With nothing stale it
///         broadcasts nothing and doubles as a verifier.
///
///         Up to three proxies move, none of them holding a new storage variable, so no upgrade
///         carries an initializer call — `upgradeToAndCall` is given empty calldata on each:
///
///         1. `MarketRouter` gains `sellForUsdg`, the mirror of `buyWithUsdg`. Nothing existing
///            changes shape or selector; `sellForBrand` stays.
///         2. `SUSDaiYieldSource` gains `withdrawable`: the local USDG buffer, which is exactly
///            what `withdraw` pays.
///         3. `MorphoBlueYieldSource` gains `withdrawable`: the consumer's balance capped at
///            the market's unlent supply, which is exactly where Morpho's `withdraw` reverts.
///
///         The adapters go first, and that order is a hard requirement rather than a
///         preference. `MarketLens.redeemableAssets` calls `withdrawable` as a plain typed
///         call, so against an adapter that predates it every sell quote REVERTS rather than
///         degrading — which is why `DeployMarketLens.s.sol` refuses to deploy the lens until
///         every reserve the factory serves answers it.
///
///         Addresses come from the environment rather than constants, because two generations
///         of this stack have been abandoned on this chain and a constant pasted from the wrong
///         manifest upgrades the wrong proxy:
///
///         DEPLOYER=0x... MARKET_ROUTER=0x... SUSDAI_ADAPTER=0x... MORPHO_ADAPTER=0x... \
///           forge script script/UpgradeAggregatorSurfaceMainnet.s.sol --rpc-url robinhood \
///           --sender $DEPLOYER --private-key 0x... --broadcast --slow
///
///         `DEPLOYER` is the address every ownership check is made against and the account the
///         broadcast is attributed to; `--private-key` (or a keystore, or `--ledger`) is how
///         forge actually signs for it, and the two must be the same account.
///         `MORPHO_ADAPTER` may be omitted on a deployment that has none. Each proxy is checked
///         to be owned by the signer, and each is read back through the proxy afterwards: the
///         wiring that a layout mistake would break still answers, and the new selector does.
///
///         The proxies are owned by the deployer EOA with no timelock, which is CRITICAL-1 in
///         the audit and the reason this takes effect the moment it is mined.
contract UpgradeAggregatorSurfaceMainnet is Script {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(block.chainid == 4663, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");

        MarketRouter router = MarketRouter(vm.envAddress("MARKET_ROUTER"));
        SUSDaiYieldSource susdai = SUSDaiYieldSource(vm.envAddress("SUSDAI_ADAPTER"));
        address morphoAddr = vm.envOr("MORPHO_ADAPTER", address(0));

        require(router.owner() == deployer, "signer does not own the router");
        require(susdai.owner() == deployer, "signer does not own the sUSDai adapter");
        if (morphoAddr != address(0)) {
            require(
                MorphoBlueYieldSource(morphoAddr).owner() == deployer,
                "signer does not own the Morpho adapter"
            );
        }

        // Read before, so the checks after compare against what was actually there.
        address routerFactory = address(router.factory());
        address routerPosm = address(router.positionManager());
        address susdaiController = susdai.controller();
        uint256 susdaiLocal = susdai.usdg().balanceOf(address(susdai));

        // **Per-proxy, because this release landed on two of its three proxies.** The original
        // run upgraded both adapters and left `MarketRouter` untouched: the adapters answer
        // `withdrawable(address,address)` on chain, and `sellForUsdg` is absent from the live
        // router implementation. Re-running the whole batch to fix the router would move both
        // adapters onto fresh implementations for no reason, which is churn on the two
        // contracts that custody the reserve's position and another pair of unexplained
        // `Upgraded` events for whoever reads the history next.
        //
        // So each leg is decided by whether the SELECTOR IT ADDS already answers, rather than
        // by a flag or a recorded implementation address. That is the only test that cannot
        // drift: a proxy either routes the function or it does not.
        bool routerStale = !_answers(
            address(router),
            abi.encodeCall(MarketRouter.sellForUsdg, (1, 0, 0, deployer, block.timestamp))
        );
        bool susdaiStale = !_answers(
            address(susdai),
            abi.encodeCall(SUSDaiYieldSource.withdrawable, (address(0), address(0)))
        );
        bool morphoStale = morphoAddr != address(0)
            && !_answers(
                morphoAddr,
                abi.encodeCall(MorphoBlueYieldSource.withdrawable, (address(0), address(0)))
            );

        console.log("router needs the upgrade:", routerStale);
        console.log("sUSDai adapter needs the upgrade:", susdaiStale);
        console.log("Morpho adapter needs the upgrade:", morphoStale);
        if (!routerStale && !susdaiStale && !morphoStale) {
            console.log("Every proxy already answers its new selector. Nothing broadcast.");
            return;
        }

        vm.startBroadcast(deployer);

        SUSDaiYieldSource freshSusdai;
        if (susdaiStale) {
            freshSusdai = new SUSDaiYieldSource();
            susdai.upgradeToAndCall(address(freshSusdai), "");
        }

        MorphoBlueYieldSource freshMorpho;
        if (morphoStale) {
            freshMorpho = new MorphoBlueYieldSource();
            MorphoBlueYieldSource(morphoAddr).upgradeToAndCall(address(freshMorpho), "");
        }

        MarketRouter freshRouter;
        if (routerStale) {
            freshRouter = new MarketRouter();
            router.upgradeToAndCall(address(freshRouter), "");
        }

        vm.stopBroadcast();

        // ── Post-checks, through the proxies ──────────────────────────────
        //
        // The "did it move" check is asserted only for a leg this run actually upgraded. The
        // selector and wiring checks are asserted for EVERY leg regardless, because the point
        // of them is that the proxy is correct now, not that this particular run changed it.
        // That is what makes the script usable as a verifier after a partial release.
        if (routerStale) {
            require(_impl(address(router)) == address(freshRouter), "router did not move");
        }
        require(address(router.factory()) == routerFactory, "router wiring moved");
        require(address(router.positionManager()) == routerPosm, "router wiring moved");
        require(router.owner() == deployer, "router owner moved");
        require(
            _answers(
                address(router),
                abi.encodeCall(MarketRouter.sellForUsdg, (1, 0, 0, deployer, block.timestamp))
            ),
            "sellForUsdg is not implemented behind the proxy"
        );

        if (susdaiStale) {
            require(_impl(address(susdai)) == address(freshSusdai), "sUSDai adapter did not move");
        }
        require(susdai.controller() == susdaiController, "sUSDai wiring moved");
        require(
            susdai.withdrawable(address(susdai.usdg()), susdaiController) == susdaiLocal,
            "sUSDai withdrawable disagrees with its buffer"
        );

        if (morphoAddr != address(0)) {
            MorphoBlueYieldSource morpho = MorphoBlueYieldSource(morphoAddr);
            if (morphoStale) {
                require(_impl(morphoAddr) == address(freshMorpho), "Morpho adapter did not move");
            }
            // The new selector answers, and sizes a stranger — who holds no shares — at zero.
            require(morpho.withdrawable(morpho.loanToken(), deployer) == 0, "withdrawable not live");
        }

        console.log("MarketRouter proxy        ", address(router));
        console.log("  implementation          ", _impl(address(router)));
        console.log("SUSDaiYieldSource proxy   ", address(susdai));
        console.log("  implementation          ", _impl(address(susdai)));
        console.log("  withdrawable (USDG)     ", susdaiLocal);
        if (morphoAddr != address(0)) {
            console.log("MorphoBlueYieldSource proxy", morphoAddr);
            console.log("  implementation          ", _impl(morphoAddr));
        }
        console.log("");
        console.log("Next: script/deploy-v4-lens.sh --broadcast, then DeployMarketLens.s.sol.");
    }

    function _impl(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    /// @dev Whether `proxy` routes `data` to code at all. A UUPS proxy has no fallback, so a
    ///      call to a function its implementation does not declare returns EMPTY returndata
    ///      and fails. Anything else means code behind the proxy handled it: a view that
    ///      answers succeeds outright, and a state-changing call that gets as far as a
    ///      `require` comes back with at least a 4-byte error selector.
    ///
    ///      Both cases have to count, and only one of them did in the first version of this
    ///      helper. `withdrawable` is a view that returns zero for a consumer holding no
    ///      shares, so it SUCCEEDS, and testing only for a selector-bearing revert reported
    ///      both adapters as missing a function they have — which the dry run caught by
    ///      proposing to upgrade all three proxies instead of only the router.
    ///
    ///      Deliberately does not match a specific error: `whenNotPaused` runs before the
    ///      argument checks on several of these, so a halted protocol would otherwise read as
    ///      a missing function.
    function _answers(address proxy, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = proxy.call(data);
        return ok || ret.length >= 4;
    }
}
