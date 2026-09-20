// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title UpgradeProtocolFeeCapMainnet
/// @notice Lower `ProtocolFeeHook.MAX_FEE_PIPS` from 50,000 to 10,000: the hard ceiling on any
///         one pool's protocol skim, from 5% to 1%.
///
/// @dev    **This script is retroactive, and that is the whole reason it exists.** The change it
///         performs already landed on mainnet at 2026-09-19T15:20:38Z, in tx
///         `0x17d4f4864d0fab07f7c9d0fc33f9a279c008ae59ce83f700c986df2941e49a0d`, which moved the
///         hook proxy from implementation `0x25481313442a01e4c4c32fab1c097205a856c402` to
///         `0x579F64aeFa201D1607AeE8C5a3A3b0B01F435928`. Both of those, and the timestamp, are
///         from the proxy's own ERC-1967 `Upgraded(address)` logs rather than from the
///         manifest. That transaction was sent by hand. No script produced it and no broadcast
///         artifact records it, so the only account of what it did was a sentence in
///         `deployments/asset-markets-mainnet-v6.json`. Prose is not something an auditor can
///         re-run. This file is the committed, executable definition of that change: point it
///         at the live chain and it either agrees with what is deployed or says exactly where
///         the chain and this repo diverge.
///
///         **Why that mattered more than the fee cap itself.** Once the log history was read
///         back, hand-sent upgrades turned out to have gone wrong twice in ways prose had
///         hidden. `AssetMarketFactory` carries a second upgrade the manifest never recorded,
///         to `0x45ce2f93ad46d1393eff5da56ffc4537740022c0` on 2026-09-17 (tx
///         `0x4b423d6d61a50a5a54236d330d981fcf09270043b4eb32c65e567a848a99af4d`). And the
///         2026-09-19 aggregator-surface upgrade, documented as covering three proxies, landed
///         on two: both yield adapters carry `withdrawable`, `MarketRouter` was never upgraded
///         at all, and `sellForUsdg` therefore exists in `src/` and not on chain while the docs
///         offer it to aggregators. A partially applied upgrade is the worst version of this
///         failure, because every address still looks right. That is what the new checks in
///         `script/VerifyAssetMarketsMainnet.s.sol` are aimed at, not just the fee ceiling.
///
///         **The expected outcome of the first real run is the no-op branch.** The cap is
///         already 10,000 on chain, so `run()` proves the proxy's identity, audits every
///         registered pool against the ceiling, logs that the tightening has already landed,
///         and returns without broadcasting anything. That is the documented normal result, not
///         a failure. The broadcasting branch is reachable only from a chain still carrying the
///         50,000 implementation, which is what a fork rehearsal or a replacement deployment
///         would be.
///
///         **What changed, and why `upgradeToAndCall` carries empty calldata.** `MAX_FEE_PIPS`
///         is declared `constant`, so it is inlined into the implementation's bytecode and
///         occupies no storage slot at all. Lowering it therefore moves no variable, shifts
///         nothing beneath it and leaves nothing to initialise, which is why the upgrade needs
///         no initializer call. It also means the value cannot be changed by a setter: raising
///         it again requires shipping an implementation, which is a visible act with a
///         bytecode diff behind it rather than one owner transaction.
///
///         **On "a tightening cannot strand a pool", which is true here but is NOT an
///         invariant.** `feePipsOf` has exactly two writers: `registerPool`
///         (`ProtocolFeeHook.sol:292`, gated on `msg.sender == registrar`) and `setPoolFeePips`
///         (`:316`, `onlyOwner`). Both compare against `MAX_FEE_PIPS` as it stands at write
///         time, and `feePipsFor` (`:342`) returns the stored value without re-clamping it. So a
///         pool written at, say, 30,000 while the ceiling was 50,000 would have survived this
///         upgrade still charging 3%, above the new cap, readable and chargeable, with
///         `setPoolFeePips` the only way down. The NatSpec on the constant calls
///         `setPoolFeePips` "the only writer"; that is inaccurate, `registerPool` writes the
///         same map, though it applies the same bound so the conclusion still holds.
///
///         What makes the claim true for this deployment is narrower and worth stating as such:
///         the only writer that has ever run is `registerPool`, called once per market by
///         `AssetMarketFactory` with its own `protocolFeePips` (`AssetMarketFactory.sol:916`),
///         which `setProtocolFeePips` bounds by the hook's live cap and which the v6 manifest
///         records as 5,000 for every market. No `setPoolFeePips` call is recorded. That is a
///         fact about history, not a property of the code, so this script checks it rather than
///         asserting it: `_auditRegisteredPools` reads every pool's stored rate and reverts
///         before broadcasting if any one of them exceeds the new ceiling. Reverting is the
///         right response because the upgrade itself cannot fix such a pool. It would ship a
///         cap the chain already violates, and the only repair is a per-pool owner call, which
///         has to happen first or the hook's central promise (no pool is above the ceiling) is
///         false the moment the implementation lands.
///
///         **Pools are enumerated through the factory, because the hook keeps no list.**
///         `registerPool` is callable only by `registrar`, and the factory calls it exactly once
///         per market it opens, so `marketCount()` covers every pool this hook charges. The one
///         gap is `setRegistrar`: an earlier registrar could have registered pools the current
///         factory's list does not contain. The manifest records no rotation on this hook, and
///         the pre-check asserts the registrar is the factory being enumerated, so a rotated
///         registrar shows up as a failed pre-condition rather than as a silently short audit.
///
///         Addresses come from the environment rather than from constants, for the reason
///         `UpgradeAggregatorSurfaceMainnet` gives: three abandoned generations of this stack
///         live on this chain, each with its own mined hook, and a constant pasted from the
///         wrong manifest upgrades the wrong proxy. There is no silent fallback. Both variables
///         are required, and the hook is cross-checked against the factory before anything is
///         signed.
///
///         DEPLOYER=0x... PROTOCOL_FEE_HOOK=0x... ASSET_MARKET_FACTORY=0x... \
///           forge script script/UpgradeProtocolFeeCapMainnet.s.sol --rpc-url robinhood \
///           --sender $DEPLOYER --private-key 0x... --broadcast --slow
///
///         `DEPLOYER` is the address ownership is checked against and the account the broadcast
///         is attributed to; `--private-key` (or a keystore, or `--ledger`) is how forge signs
///         for it, and the two must be the same account. Drop `--broadcast` to get the audit
///         and the verdict without sending anything, which is the useful way to run this now
///         that the change has landed.
///
///         The hook proxy is owned by the deployer EOA with no timelock, which is CRITICAL-1 in
///         the audit and the reason this takes effect the moment it is mined.
contract UpgradeProtocolFeeCapMainnet is Script {
    using PoolIdLibrary for PoolKey;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev The ceiling this script replaces, 5%. Any other live value means the proxy is
    ///      carrying an implementation this script was not written against, and it refuses to
    ///      guess what that one is.
    uint24 constant OLD_MAX_FEE_PIPS = 50_000;

    function run() external returns (address implementation) {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        ProtocolFeeHook hook = ProtocolFeeHook(vm.envAddress("PROTOCOL_FEE_HOOK"));
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));

        // ── Identity, before anything else ────────────────────────────────
        //
        // A hook is the one contract in this stack whose address is evidence: the low 14 bits
        // are mined to carry its permission flags, so an address without 0xcc cannot be a
        // ProtocolFeeHook of this shape whatever its code says. Then the factory has to name
        // this hook, this hook has to name the factory as its registrar, and both have to
        // answer to the same PoolManager. Together those pin the pair to one generation, which
        // is what a pasted address from the wrong manifest would fail.
        require(address(hook).code.length > 0, "no code at PROTOCOL_FEE_HOOK");
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK
                == uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ),
            "this address does not carry the hook's mined permission bits"
        );
        require(address(factory.feeHook()) == address(hook), "the factory names a different hook");
        require(
            hook.registrar() == address(factory),
            "hook registrar is not this factory: its pool list would be incomplete"
        );
        require(
            address(hook.poolManager()) == address(factory.poolManager()),
            "hook and factory answer to different PoolManagers"
        );
        require(hook.owner() == deployer, "signer does not own this hook");

        // What `src/` compiles to today. Solidity will not let a contract-level `constant` be
        // read off the type (`ProtocolFeeHook.MAX_FEE_PIPS` does not compile), and reading it
        // off the live proxy would be circular: the proxy is the thing under test. So an
        // implementation is deployed here from freshly compiled bytecode and asked. This
        // happens OUTSIDE the broadcast window, so it exists only in forge's simulation and no
        // transaction is sent for it; the implementation that actually gets installed below is
        // created inside `startBroadcast`.
        uint24 target = new ProtocolFeeHook().MAX_FEE_PIPS();
        require(
            target == 10_000,
            "src no longer compiles to a 10,000 pip ceiling: this script is the 5% to 1% step"
        );

        uint24 liveCap = hook.MAX_FEE_PIPS();
        implementation = _impl(address(hook));

        console.log("ProtocolFeeHook proxy   ", address(hook));
        console.log("  implementation now    ", implementation);
        console.log("  live MAX_FEE_PIPS     ", liveCap);
        console.log("  MAX_FEE_PIPS in src   ", target);
        console.log("  registrar (factory)   ", hook.registrar());
        console.log("  owner                 ", hook.owner());

        // ── The already-landed path, which is the normal one ──────────────
        //
        // The audit still runs. "The cap is already where we want it" is not the same claim as
        // "no pool is above it", and only the second one is worth anything to an integrator.
        if (liveCap == target) {
            uint24 highest = _auditRegisteredPools(factory, hook, target);
            console.log("");
            console.log("The 1% ceiling is ALREADY live. Nothing to upgrade, nothing broadcast.");
            console.log("  highest stored pool rate", highest);
            console.log("  landed 2026-09-19T15:20:38Z by tx");
            console.log("  0x17d4f4864d0fab07f7c9d0fc33f9a279c008ae59ce83f700c986df2941e49a0d");
            return implementation;
        }

        require(
            liveCap == OLD_MAX_FEE_PIPS,
            "live ceiling is neither 50,000 nor 10,000: unrecognised implementation"
        );

        // PRE-condition: no pool may already be above the ceiling we are about to impose.
        uint24 highestBefore = _auditRegisteredPools(factory, hook, target);

        // The wiring and the permissions that must survive, read through the proxy first so the
        // checks afterwards have something to compare against. `MAX_FEE_PIPS` is a constant and
        // moves no slot, but "should not move storage" is a claim to test, not to assume.
        address guardBefore = address(hook.guard());
        address poolManagerBefore = address(hook.poolManager());
        address registrarBefore = hook.registrar();
        bytes32 permissionsBefore = keccak256(abi.encode(hook.getHookPermissions()));

        vm.startBroadcast(deployer);
        ProtocolFeeHook fresh = new ProtocolFeeHook();
        hook.upgradeToAndCall(address(fresh), "");
        vm.stopBroadcast();

        // ── Post-conditions, all read back through the proxy ──────────────
        implementation = _impl(address(hook));
        require(implementation == address(fresh), "the proxy did not move");
        require(hook.MAX_FEE_PIPS() == target, "the ceiling did not come down to 10,000 pips");
        // The flags live in an address that upgrading cannot move, so an implementation
        // declaring a different set desynchronises the hook from the PoolManager silently, with
        // no revert to notice. This is the one post-check that has nothing to do with the fee.
        require(
            keccak256(abi.encode(hook.getHookPermissions())) == permissionsBefore,
            "hook permissions moved: every pool mined against 0xcc is now orphaned"
        );
        require(address(hook.guard()) == guardBefore, "guard moved");
        require(address(hook.poolManager()) == poolManagerBefore, "PoolManager moved");
        require(hook.registrar() == registrarBefore, "registrar moved");
        require(hook.owner() == deployer, "owner moved");

        // POST-condition: and every pool is still under it afterwards, read again rather than
        // inferred from the pre-check, because that is the statement the new bytecode makes.
        uint24 highestAfter = _auditRegisteredPools(factory, hook, target);
        require(highestAfter == highestBefore, "a pool's stored rate moved during the upgrade");

        console.log("");
        console.log("  implementation after  ", implementation);
        console.log("  MAX_FEE_PIPS after    ", hook.MAX_FEE_PIPS());
        console.log("  highest stored rate   ", highestAfter);
        console.log("Ceiling tightened to 1%. Record the tx hash in the deployment manifest.");
    }

    /// @dev Reads every registered pool's STORED rate and reverts if one exceeds `ceiling`.
    ///
    ///      `feePipsOf` is deliberate here rather than `feePipsFor`: the latter returns zero
    ///      while the protocol is halted, so an audit built on it would report a clean sweep on
    ///      a paused stack and miss the pool it exists to find.
    function _auditRegisteredPools(AssetMarketFactory factory, ProtocolFeeHook hook, uint24 ceiling)
        private
        view
        returns (uint24 highest)
    {
        uint256 count = factory.marketCount();
        for (uint256 id = 1; id <= count; id++) {
            PoolId poolId = factory.poolKeyOf(id).toId();
            uint24 pips = hook.feePipsOf(poolId);
            if (pips > highest) highest = pips;
            // Reverting, rather than upgrading and reporting. The upgrade cannot repair such a
            // pool: the new bytecode would ship a ceiling the chain already violates, and only
            // a per-pool `setPoolFeePips` can bring the rate down. That call has to come first,
            // or the hook's central promise to an integrator is false from the moment the
            // implementation lands.
            require(pips <= ceiling, "a registered pool's rate is above the new ceiling");
        }
        console.log("  pools audited         ", count);
    }

    function _impl(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
