// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";

/// @title UpgradeHookFeeDelayMainnet
/// @notice Makes a protocol fee INCREASE announce itself an hour before it can be charged.
///         A decrease stays immediate.
///
/// @dev    **What this buys, stated honestly.** An aggregator routing through these pools
///         publishes a quote computed from `feePipsFor(poolId)`. Before this change the owner
///         could raise that rate in one transaction, between the quote and the fill, and the
///         fill would settle at the new rate. After it, an increase writes
///         `pendingFeePipsOf` and `feePipsEffectiveAt = block.timestamp + FEE_INCREASE_DELAY`
///         and charges nothing; a separate, permissionless `commitPoolFeePips` applies it at
///         or after that time. Every quote is therefore good for at least an hour.
///
///         **It is a reliability guarantee, not a security one.** The hook is a UUPS proxy
///         with an `onlyOwner` `_authorizeUpgrade` and there is no timelock on upgrades, so an
///         owner can ship an implementation without the delay in a single transaction. This
///         binds mistakes and ordinary repricing. It does not bind a compromised key, and the
///         aggregator documentation says so rather than implying otherwise. What does bind a
///         compromised key is `MAX_FEE_PIPS`, and only until it is upgraded too.
///
///         **Why the commit is permissionless.** A change only the owner can finalise is a
///         change the owner can appear to have made without making it: announce, let the
///         window pass, then sit on the commit and keep the option. Letting anyone finalise an
///         already-announced increase removes that option and costs nothing, because the
///         announcement is the authorisation and the value is already bounded and public.
///
///         **Why the ceiling is re-checked at commit.** `MAX_FEE_PIPS` has already been
///         lowered once, from 50,000 to 10,000. A value authorised under an older ceiling must
///         not be able to land under a newer one, so the bound is enforced on the way in and
///         again on the way out.
///
///         **A decrease cancels a pending increase outright.** It is not paused or deferred.
///         An increase to 9,000 announced against a 5,000 baseline was authorised against that
///         baseline; letting it commit after a cut to 1,000 would be a nine-fold rise with no
///         fresh warning, which is the exact surprise this exists to prevent. Reaching the
///         higher rate after a cut means announcing again and serving a new hour.
///
///         **Storage is appended, not inserted.** `pendingFeePipsOf` and `feePipsEffectiveAt`
///         are two new mappings declared after every existing variable, so no live slot moves.
///         Mappings occupy their declaration slot and hash their contents elsewhere, so the
///         only cost is two fresh slots at the end. Verified below by re-reading every pool's
///         recipient and rate after the upgrade. `upgradeToAndCall` therefore carries empty
///         calldata: there is nothing to initialise, and a zeroed `feePipsEffectiveAt` already
///         means "nothing pending" for every existing pool.
///
///         **The swap path is untouched.** `feePipsFor` still reads one mapping and never
///         looks at the pending fields, so a scheduled increase costs a swap no extra gas.
///
///         **The mined address is unchanged**, and must be: `getHookPermissions()` is
///         untouched, `PoolKey.hooks` is part of pool identity, and a hook at a new address
///         would orphan all 18 markets. Asserted before broadcasting.
///
///         Usage:
///           DEPLOYER=0x… PROTOCOL_FEE_HOOK=0x… ASSET_MARKET_FACTORY=0x… \
///             forge script script/UpgradeHookFeeDelayMainnet.s.sol:UpgradeHookFeeDelayMainnet \
///             --rpc-url robinhood --private-key 0x… --broadcast --slow
contract UpgradeHookFeeDelayMainnet is Script {
    uint256 constant CHAIN_ID = 4663;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (address implementation) {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address deployer = vm.envAddress("DEPLOYER");
        ProtocolFeeHook hook = ProtocolFeeHook(vm.envAddress("PROTOCOL_FEE_HOOK"));
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));

        // ─── Identity, before anything ────────────────────────────────────
        require(hook.owner() == deployer, "signer does not own the hook");
        require(address(factory.feeHook()) == address(hook), "factory names another hook");
        require(hook.registrar() == address(factory), "hook's registrar is not this factory");

        address implBefore = address(uint160(uint256(vm.load(address(hook), IMPL_SLOT))));
        bytes32 permsBefore = keccak256(abi.encode(hook.getHookPermissions()));
        address guardBefore = address(hook.guard());
        address managerBefore = address(hook.poolManager());
        uint24 capBefore = hook.MAX_FEE_PIPS();

        // Every pool's destination and rate, so the upgrade can be shown to have moved neither.
        // This is the storage-layout check that matters: two mappings were appended, and if
        // either had been inserted instead, these reads would come back wrong.
        uint256 count = factory.marketCount();
        address[] memory recipients = new address[](count + 1);
        uint24[] memory rates = new uint24[](count + 1);
        for (uint256 id = 1; id <= count; ++id) {
            PoolId pid = factory.poolKeyOf(id).toId();
            recipients[id] = hook.feeRecipientOf(pid);
            rates[id] = hook.feePipsOf(pid);
        }

        // ─── Idempotency ──────────────────────────────────────────────────
        // Probed by behaviour, not by a recorded address. A build carrying the delay answers a
        // staticcall to `commitPoolFeePips` with the `NoPendingFeeIncrease` selector, because
        // nothing is scheduled for a zero pool id and that check precedes every write. A build
        // without it returns empty returndata, since a UUPS proxy has no fallback. The test is
        // whether the revert carries a selector at all.
        (bool ok, bytes memory ret) = address(hook)
            .staticcall(abi.encodeWithSignature("commitPoolFeePips(bytes32)", bytes32(0)));
        if (ok || ret.length >= 4) {
            console.log("The fee-increase delay is already live on this implementation.");
            console.log("Nothing broadcast. Implementation:", implBefore);
            return implBefore;
        }

        vm.startBroadcast(deployer);
        ProtocolFeeHook fresh = new ProtocolFeeHook();
        // The candidate must declare the same permissions as the live proxy, or the mined
        // address stops matching its own flag bits and every swap reverts in `Hooks`.
        require(
            keccak256(abi.encode(fresh.getHookPermissions())) == permsBefore,
            "candidate changes the hook permission bits"
        );
        hook.upgradeToAndCall(address(fresh), "");
        vm.stopBroadcast();

        // ─── Post ─────────────────────────────────────────────────────────
        implementation = address(uint160(uint256(vm.load(address(hook), IMPL_SLOT))));
        require(implementation == address(fresh), "the proxy did not move");
        require(
            keccak256(abi.encode(hook.getHookPermissions())) == permsBefore, "permissions moved"
        );
        require(address(hook.guard()) == guardBefore, "guard moved");
        require(address(hook.poolManager()) == managerBefore, "pool manager moved");
        require(hook.registrar() == address(factory), "registrar moved");
        require(hook.owner() == deployer, "owner moved");
        require(hook.MAX_FEE_PIPS() == capBefore, "fee ceiling moved");
        require(hook.FEE_INCREASE_DELAY() == 1 hours, "the delay is not the intended hour");

        for (uint256 id = 1; id <= count; ++id) {
            PoolId pid = factory.poolKeyOf(id).toId();
            require(hook.feeRecipientOf(pid) == recipients[id], "a pool's destination moved");
            require(hook.feePipsOf(pid) == rates[id], "a pool's rate moved");
            // Nothing may arrive mid-flight. Every live pool must read as "nothing pending",
            // or a quote would be exposed to an increase nobody announced.
            require(hook.pendingFeePipsOf(pid) == 0, "a pool came up with a pending rate");
            require(hook.feePipsEffectiveAt(pid) == 0, "a pool came up with an effective time");
        }

        // And the new surface is reachable.
        (ok, ret) = address(hook)
            .staticcall(abi.encodeWithSignature("commitPoolFeePips(bytes32)", bytes32(0)));
        require(!ok && ret.length >= 4, "commitPoolFeePips is not reachable after the upgrade");

        console.log("ProtocolFeeHook proxy:   ", address(hook));
        console.log("  implementation before: ", implBefore);
        console.log("  implementation after:  ", implementation);
        console.log("  pools checked, unmoved:", count);
        console.log("");
        console.log("Fee INCREASES now take two transactions an hour apart:");
        console.log("  1. setPoolFeePips(poolId, pips)   - owner, announces only");
        console.log("  2. commitPoolFeePips(poolId)      - anyone, at or after effectiveAt");
        console.log("Decreases still apply immediately and cancel any pending increase.");
    }
}
