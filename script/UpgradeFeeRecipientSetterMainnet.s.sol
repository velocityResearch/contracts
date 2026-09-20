// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";

/// @title UpgradeFeeRecipientSetterMainnet
/// @notice Gives `ProtocolFeeHook` an owner-only `setFeeRecipient`, so a pool's fee destination
///         can be moved off a compromised key instead of being fixed for the pool's life.
///
/// @dev    **The problem this ends.** `registerPool` bound `feeRecipientOf[id]` one-shot and
///         there was no setter, so every one of the 18 live markets paid its trading fees to
///         whatever address was named when it was created. That address is the deployer EOA.
///         Rotating ownership to a hardware wallet therefore did NOT rotate revenue: the old
///         key would have kept collecting from every existing market forever, and the only
///         remedies were retiring 18 markets or leaving a key alive that nobody wanted alive.
///
///         **Why removing the immutability is correct rather than a weakening.** The original
///         NatSpec justified it as keeping "this market's trading fees buy this market's asset"
///         unrevokable, a promise enforced for `BuybackEngine` reading a market's
///         `BrandFeeVault`. Both of those contracts have been deleted, and the destination
///         actually registered for every live pool is the protocol treasury, not a per-market
///         vault, so the guarantee had no subject left. It was also never a constraint on THIS
///         owner: the hook is a UUPS proxy with an `onlyOwner` `_authorizeUpgrade`, so an owner
///         who wanted to repoint could always ship an implementation that does - which is
///         precisely what this script is. The one-shot only bound the honest operator.
///
///         **It applies to existing pools too, deliberately.** Restricting the setter to pools
///         registered after the upgrade would need a marker in storage recording a pool's era,
///         and would leave the 18 markets that exist in exactly the trap the change exists to
///         escape. The audit finding is about key rotation, and a fix that cannot rotate the
///         keys currently in use is not a fix.
///
///         **No storage moved.** `setFeeRecipient` writes an existing mapping and adds one
///         event. No state variable was added, removed, reordered or retyped, which is why
///         `upgradeToAndCall` carries empty calldata.
///
///         **The mined address is unchanged**, and must be: `getHookPermissions()` is
///         untouched, `PoolKey.hooks` is part of pool identity, and a hook at a new address
///         would orphan all 18 markets. Asserted before broadcasting.
///
///         **Ordering note for whoever repoints afterwards.** `pendingFees` is not attributed
///         to whoever was named when it accrued; `collect` pays whoever is named at the moment
///         it runs. So `collect` first if the OLD destination is owed what is already there,
///         then `setFeeRecipient`. Pinned by
///         `test_setFeeRecipient_doesNotReattributeFeesAlreadyAccrued`.
///
///         Usage:
///           DEPLOYER=0x… PROTOCOL_FEE_HOOK=0x… ASSET_MARKET_FACTORY=0x… \
///             forge script script/UpgradeFeeRecipientSetterMainnet.s.sol:UpgradeFeeRecipientSetterMainnet \
///             --rpc-url robinhood --private-key 0x… --broadcast --slow
contract UpgradeFeeRecipientSetterMainnet is Script {
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
        uint256 count = factory.marketCount();
        address[] memory recipients = new address[](count + 1);
        uint24[] memory rates = new uint24[](count + 1);
        for (uint256 id = 1; id <= count; ++id) {
            PoolId pid = factory.poolKeyOf(id).toId();
            recipients[id] = hook.feeRecipientOf(pid);
            rates[id] = hook.feePipsOf(pid);
        }

        // ─── Idempotency ──────────────────────────────────────────────────
        // Probed by behaviour rather than by a recorded address: a build that already has the
        // setter answers a staticcall to it, and one that does not returns empty returndata
        // because a UUPS proxy has no fallback. `address(0)` as the argument means the call
        // reverts on either build if the function exists at all, so the test is whether the
        // revert carries a selector, not whether it succeeds.
        (bool ok, bytes memory ret) = address(hook)
            .staticcall(
                abi.encodeWithSignature("setFeeRecipient(bytes32,address)", bytes32(0), address(0))
            );
        if (ok || ret.length >= 4) {
            console.log("setFeeRecipient already exists on the live implementation.");
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

        for (uint256 id = 1; id <= count; ++id) {
            PoolId pid = factory.poolKeyOf(id).toId();
            require(hook.feeRecipientOf(pid) == recipients[id], "a pool's destination moved");
            require(hook.feePipsOf(pid) == rates[id], "a pool's rate moved");
        }

        // And the new power exists and is owner-gated. Probed with an unregistered pool id, so
        // a build carrying the setter answers `NotRegistered` rather than changing anything.
        (ok, ret) = address(hook)
            .staticcall(
                abi.encodeWithSignature("setFeeRecipient(bytes32,address)", bytes32(0), address(0))
            );
        require(!ok && ret.length >= 4, "setFeeRecipient is not reachable after the upgrade");

        console.log("ProtocolFeeHook proxy:   ", address(hook));
        console.log("  implementation before: ", implBefore);
        console.log("  implementation after:  ", implementation);
        console.log("  pools checked, unmoved:", count);
        console.log("");
        console.log("Destinations are now repointable by the owner, existing pools included.");
        console.log("Collect BEFORE repointing if the old address is owed what has accrued:");
        console.log("  pendingFees pays whoever is named when collect runs, not when it accrued.");
    }
}
