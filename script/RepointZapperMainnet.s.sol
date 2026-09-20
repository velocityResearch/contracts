// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";

/// @title RepointZapperMainnet
/// @notice Stops the registry publishing the ownerless, sandwichable `LiquidityZapper`.
///
/// @dev    **What is wrong with the incumbent.** `0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd`
///         accepts `minLiquidity = 0` and `minUsdgOut = 0` from a caller and then passes
///         `amountOutMinimum: 0` to SwapRouter02, so both of its doors execute a swap with no
///         slippage bound at all. It is ownerless, which was a deliberate design choice, and
///         that choice is exactly why the defect cannot be patched: there is nobody who can
///         upgrade it. It can only be de-referenced.
///
///         **The replacement.** `0x57FA92648c722Bb28A0d011f020685B952110a2D` is a UUPS proxy,
///         owned and guarded, which refuses a zero bound on both doors before taking custody
///         and forwards the caller's bound to SwapRouter02 rather than discarding it. Making
///         it upgradeable reverses the ownerless design on purpose: the tradeoff accepted is
///         that the owner can now rewrite a contract holding standing Permit2 allowances,
///         judged cheaper than a live slippage defect nobody can fix.
///
///         **Only the zapper changes.** Each group is read back from the registry and written
///         out field for field with a single substitution, so a field this script does not
///         know about cannot be silently zeroed. `setGroup` overwrites the whole record, which
///         is precisely the hazard being designed around here.
///
///         **Reversible.** `setGroup` may be called again with the old address. Nothing in
///         this script is one-way.
///
///         **The old contract stays live and reachable.** De-referencing is not deletion. Any
///         client holding the address hard-coded keeps using it, which is why the frontend
///         template must be updated in the same change.
///
///         Usage:
///           DEPLOYER=0x… forge script script/RepointZapperMainnet.s.sol:RepointZapperMainnet --rpc-url robinhood
///           DEPLOYER=0x… forge script script/RepointZapperMainnet.s.sol:RepointZapperMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract RepointZapperMainnet is Script {
    uint256 constant CHAIN_ID = 4663;
    address constant REGISTRY = 0xBd02B0f3253F31dD02A752582e7b8974589333f7;

    address constant OLD_ZAPPER = 0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd;
    address constant NEW_ZAPPER = 0x57FA92648c722Bb28A0d011f020685B952110a2D;

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address signer = vm.envAddress("DEPLOYER");

        StrategyGroupRegistry registry = StrategyGroupRegistry(REGISTRY);
        require(registry.owner() == signer, "signer does not own the registry");
        require(NEW_ZAPPER.code.length > 0, "the replacement zapper has no code");

        uint256 count = registry.groupCount();
        uint256 stale;
        for (uint256 i; i < count; ++i) {
            if (registry.group(registry.groupIdAt(i)).zapper == OLD_ZAPPER) ++stale;
        }
        if (stale == 0) {
            console.log("No group publishes the old zapper. Nothing to do.");
            return;
        }

        vm.startBroadcast(signer);
        for (uint256 i; i < count; ++i) {
            bytes32 id = registry.groupIdAt(i);
            StrategyGroupRegistry.Group memory g = registry.group(id);
            if (g.zapper != OLD_ZAPPER) continue;

            registry.setGroup(
                id,
                StrategyGroupRegistry.GroupInput({
                    reservePool: g.reservePool,
                    yieldSource: g.yieldSource,
                    factory: g.factory,
                    router: g.router,
                    zapper: NEW_ZAPPER,
                    policyId: g.policyId,
                    active: g.active,
                    name: g.name,
                    strategy: g.strategy
                })
            );

            // Everything except the zapper must read back identically. `setGroup` replaces the
            // whole record, so this is the check that the rewrite carried the record forward
            // rather than reconstructing a lossy version of it.
            StrategyGroupRegistry.Group memory after_ = registry.group(id);
            require(after_.zapper == NEW_ZAPPER, "the zapper did not move");
            require(after_.reservePool == g.reservePool, "reservePool moved");
            require(after_.asset == g.asset, "asset moved");
            require(after_.yieldSource == g.yieldSource, "yieldSource moved");
            require(after_.factory == g.factory, "factory moved");
            require(after_.router == g.router, "router moved");
            require(after_.policyId == g.policyId, "policyId moved");
            require(after_.active == g.active, "active moved");
            require(keccak256(bytes(after_.name)) == keccak256(bytes(g.name)), "name moved");
            require(
                keccak256(bytes(after_.strategy)) == keccak256(bytes(g.strategy)), "strategy moved"
            );

            console.log("  repointed group:", after_.name);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("%s group(s) now publish %s", stale, NEW_ZAPPER);
        console.log("The old %s is STILL LIVE and still sandwichable.", OLD_ZAPPER);
        console.log("Update every client that hard-codes it, then redeploy the frontend.");
    }
}
