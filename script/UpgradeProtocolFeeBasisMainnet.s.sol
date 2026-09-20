// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title UpgradeProtocolFeeBasisMainnet
/// @notice Move `ProtocolFeeHook`'s skim off the requested input and onto the unspecified
///         currency of what the pool actually filled: no fee in `beforeSwap` at all, the whole
///         fee in `afterSwap`, both swap directions, measured from the `BalanceDelta`.
///
/// @dev    **The bug.** `beforeSwap` runs before `pool.swap`, so the only quantity available to
///         it is `params.amountSpecified` — the amount the caller ASKED for. A v4 swap is not
///         obliged to fill that. A caller passing a `sqrtPriceLimitX96` short of where the pool
///         would have to travel gets a partial fill and the remainder is silently abandoned.
///         The old implementation charged `feePips` of the full request regardless, so a
///         partially filled swap was billed on notional that never traded, up to the entire
///         `MAX_FEE_PIPS` (1%) of the unfilled part.
///
///         **Why it was invisible until now.** `MarketRouter.unlockCallback` passes
///         `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`, so every swap this protocol originates
///         either fills completely or reverts on the caller's own `minOut`. The exposure opens
///         the moment somebody else routes to these pools directly — which is exactly what
///         handing the surface to an aggregator means.
///
///         **What changes economically, and it is not nothing.** Exact-output is untouched: its
///         unspecified leg is already the input and `afterSwap` already charged it from the
///         delta. Exact-input moves from the input leg to the OUTPUT leg. The pool now sees the
///         whole input, so the LPs earn their fee on all of it, and the protocol takes its pips
///         out of proceeds that are already net of the LP fee and of price impact. At the live
///         5,000 pips through a 0.30% pool, on a round 1,000 units in and ignoring impact:
///         before, 5.000 units of the input were skimmed, the pool swapped 995, the LPs earned
///         2.985 and the trader received about 992.015; after, nothing is skimmed up front, the
///         pool swaps 1,000, the LPs earn 3.000, the output is about 997.000 and the protocol
///         takes 4.985 of it, leaving the trader about 992.015. The trader pays materially the
///         same all-in rate. What moved is the currency the protocol is paid in — and on a
///         partial fill, the size of the bill.
///
///         Every one of the 18 live markets therefore starts accruing fees in its ASSET token
///         instead of its brandUSD. `pendingFees` is keyed per pool per currency and `collect`
///         sweeps both sides of the `PoolKey`, so no downstream contract changes; the vaults
///         simply start receiving the other leg. Balances already accrued on the brand side
///         remain claimable and are swept by the same `collect`.
///
///         **`upgradeToAndCall` carries empty calldata because no storage moved.** The change is
///         confined to two function bodies. No state variable was added, removed, reordered or
///         retyped: `poolManager`, `guard`, `registrar`, `feeRecipientOf`, `feePipsOf`,
///         `pendingFees`, `observations` and `observationStates` occupy exactly the slots they
///         occupied before, in the same order, after the same OpenZeppelin base contracts.
///         There is nothing to initialise, so an initializer call would only be a re-entry
///         point nobody needs.
///
///         **`getHookPermissions()` is byte-identical, and that is a hard requirement rather
///         than a nicety.** A v4 hook's permission flags live in the low 14 bits of its own
///         address, mined once, and a UUPS upgrade cannot move an address. `beforeSwapReturnDelta`
///         stays declared even though nothing returns a non-zero `BeforeSwapDelta` any more:
///         permissions may be a superset of what is exercised (the manager calls the callback,
///         the callback returns zero, nothing is claimed), but they may never be a subset.
///         Dropping the flag would desynchronise this contract from the bits the `PoolManager`
///         reads out of `0xc9932584…40Cc`, silently and with no revert. The pre/post hash
///         comparison below is what enforces it.
///
///         **Detecting whether the chain already carries the fix, honestly.** No selector
///         changes, so `UpgradeAggregatorSurfaceMainnet`'s "does the proxy route this function"
///         trick does not apply here. Two independent checks are used instead, and both must
///         agree before anything is broadcast or skipped.
///
///         1. A BEHAVIOURAL probe, which is the primary one because it trusts no manifest.
///            `beforeSwap` is called under `vm.prank(poolManager)` with a real registered
///            `PoolKey` and an exact-input swap large enough that the old implementation's fee
///            rounds above zero. The fixed implementation only writes an observation and
///            returns `ZERO_DELTA`, which needs no open unlock, so the call SUCCEEDS. The old
///            implementation reaches `poolManager.mint`, which is `onlyWhenUnlocked`, and there
///            is no unlock open in a script, so it REVERTS. Success with a zero delta therefore
///            means the fee has left `beforeSwap`; a revert means it has not.
///
///            Its limits, stated rather than papered over. It mutates the simulated fork by
///            writing an observation, so it runs inside a state snapshot that is rolled back.
///            It is blind while the protocol is halted, because `feePipsFor` returns zero then
///            and both implementations take the same early exit — so the script REQUIRES a
///            non-zero live rate on the probe pool and refuses to guess otherwise. And it
///            cannot distinguish this fix from some other implementation that also declines to
///            charge in `beforeSwap`, which is what the second check is for.
///
///         2. The recorded implementation address, from `deployments/mainnet-state.json` at
///            block 67,371,130: `0x579F64aeFa201D1607AeE8C5a3A3b0B01F435928`, the build that
///            lowered `MAX_FEE_PIPS` to 10,000 and still skims in `beforeSwap`. If the probe
///            says "not yet fixed" the live implementation must be that exact address, or this
///            script refuses rather than upgrading a build it was not written against. The
///            tradeoff is that a legitimate intervening upgrade turns into a manual step: that
///            is the correct direction to fail for a contract whose owner is one EOA with no
///            timelock.
///
///         Addresses come from the environment with no fallback constant, for the reason
///         `UpgradeProtocolFeeCapMainnet` gives: three abandoned generations of this stack live
///         on this chain, each with its own mined hook, and a constant pasted from the wrong
///         manifest upgrades the wrong proxy.
///
///         DEPLOYER=0x... PROTOCOL_FEE_HOOK=0x... ASSET_MARKET_FACTORY=0x... \
///           forge script script/UpgradeProtocolFeeBasisMainnet.s.sol --rpc-url robinhood \
///           --sender $DEPLOYER --private-key 0x... --broadcast --slow
///
///         `DEPLOYER` is the address ownership is checked against and the account the broadcast
///         is attributed to; `--private-key` (or a keystore, or `--ledger`) is how forge signs
///         for it, and the two must be the same account. Drop `--broadcast` for the audit and
///         the verdict with nothing sent.
///
///         The hook proxy is owned by the deployer EOA with no timelock, which is CRITICAL-1 in
///         the audit and the reason this takes effect the moment it is mined.
contract UpgradeProtocolFeeBasisMainnet is Script {
    using PoolIdLibrary for PoolKey;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev The implementation this script replaces, as recorded in
    ///      `deployments/mainnet-state.json` at block 67,371,130. Any other live implementation
    ///      paired with a "still charges in beforeSwap" probe result means the chain is carrying
    ///      a build this script was not written against, and it refuses.
    address constant PRE_FIX_IMPLEMENTATION = 0x579F64aeFa201D1607AeE8C5a3A3b0B01F435928;

    /// @dev Probe size. Large enough that the old implementation's
    ///      `mulDiv(1e18, feePips, 1_000_000)` is comfortably above zero at any rate a live
    ///      pool carries, so it always reaches `poolManager.mint` and always reverts.
    int256 constant PROBE_AMOUNT_IN = -1e18;
    /// @dev Stand-in for the `sender` argument of the `beforeSwap` probe. The hook declares
    ///      that parameter unnamed and never reads it, so any non-zero address does; a literal
    ///      keeps the script from depending on its own ephemeral address, which forge rejects.
    address constant PROBE_SENDER = 0x000000000000000000000000000000000000dEaD;

    function run() external returns (address implementation) {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        ProtocolFeeHook hook = ProtocolFeeHook(vm.envAddress("PROTOCOL_FEE_HOOK"));
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));

        // ── Identity, before anything else ────────────────────────────────
        //
        // A hook is the one contract here whose address is evidence: the low 14 bits are mined
        // to carry its permission flags, so an address without 0xcc cannot be a
        // ProtocolFeeHook of this shape whatever its code says. Then the factory has to name
        // this hook, this hook has to name the factory as its registrar, and both have to
        // answer to the same PoolManager. Together those pin the pair to one generation, which
        // is what an address pasted from the wrong manifest would fail.
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

        uint256 marketCount = factory.marketCount();
        require(marketCount > 0, "this factory has opened no markets: nothing to protect");

        implementation = _impl(address(hook));

        console.log("ProtocolFeeHook proxy   ", address(hook));
        console.log("  implementation now    ", implementation);
        console.log("  registrar (factory)   ", hook.registrar());
        console.log("  guard                 ", address(hook.guard()));
        console.log("  owner                 ", hook.owner());
        console.log("  markets               ", marketCount);

        // ── Is the fix already live? ──────────────────────────────────────
        bool chargesInBeforeSwap = _chargesInBeforeSwap(hook, factory);
        console.log("  charges in beforeSwap ", chargesInBeforeSwap);

        if (!chargesInBeforeSwap) {
            _auditRegisteredPools(factory, hook);
            console.log("");
            console.log("The unspecified-currency fee basis is ALREADY live.");
            console.log("Nothing to upgrade, nothing broadcast.");
            return implementation;
        }

        require(
            implementation == PRE_FIX_IMPLEMENTATION,
            "live implementation still charges in beforeSwap but is not the one recorded in "
            "deployments/mainnet-state.json: unrecognised build, refusing to upgrade it"
        );

        // ── PRE-conditions ────────────────────────────────────────────────
        //
        // Everything that must be identical afterwards, read through the proxy first so the
        // post-checks have something real to compare against. "This upgrade moves no storage"
        // is a claim to test, not to assume.
        bytes32 permissionsBefore = keccak256(abi.encode(hook.getHookPermissions()));
        address poolManagerBefore = address(hook.poolManager());
        address registrarBefore = hook.registrar();
        address guardBefore = address(hook.guard());
        address ownerBefore = hook.owner();
        uint24 maxFeePipsBefore = hook.MAX_FEE_PIPS();
        uint24[] memory ratesBefore = _auditRegisteredPools(factory, hook);

        // The fix must actually be in what `src/` compiles to, or this run is theatre. Deployed
        // here, OUTSIDE the broadcast window, so it exists only in forge's simulation and no
        // transaction is sent for it; the implementation that gets installed below is created
        // inside `startBroadcast`. Its `getHookPermissions()` is checked against the live
        // proxy's before a single byte is signed, because a mismatch there orphans every pool.
        ProtocolFeeHook candidate = new ProtocolFeeHook();
        require(
            keccak256(abi.encode(candidate.getHookPermissions())) == permissionsBefore,
            "src declares different hook permissions: this address cannot carry them"
        );
        require(
            candidate.MAX_FEE_PIPS() == maxFeePipsBefore,
            "src moved MAX_FEE_PIPS: that is a different change, ship it separately"
        );

        // ── The upgrade ───────────────────────────────────────────────────
        //
        // Empty calldata. The change is two function bodies; no state variable was added,
        // removed, reordered or retyped, so nothing beneath anything moved and there is nothing
        // to initialise.
        vm.startBroadcast(deployer);
        ProtocolFeeHook fresh = new ProtocolFeeHook();
        hook.upgradeToAndCall(address(fresh), "");
        vm.stopBroadcast();

        // ── POST-conditions, all read back through the proxy ──────────────
        implementation = _impl(address(hook));
        require(implementation == address(fresh), "the proxy did not move");

        // The one check that has nothing to do with the fee, and the one that would be
        // catastrophic to skip: the flags live in an address upgrading cannot move.
        require(
            keccak256(abi.encode(hook.getHookPermissions())) == permissionsBefore,
            "hook permissions moved: every pool mined against 0xcc is now orphaned"
        );
        require(address(hook.poolManager()) == poolManagerBefore, "PoolManager moved");
        require(hook.registrar() == registrarBefore, "registrar moved");
        require(address(hook.guard()) == guardBefore, "guard moved");
        require(hook.owner() == ownerBefore, "owner moved");
        require(hook.MAX_FEE_PIPS() == maxFeePipsBefore, "the fee ceiling moved");

        // Every registered pool's stored rate is exactly where it was. This is the storage
        // check with teeth: `feePipsOf` sits behind three mappings and after the two
        // Ownable/UUPS bases, so a layout mistake anywhere above it shows up here as a rate
        // that changed or a recipient that vanished.
        uint24[] memory ratesAfter = _auditRegisteredPools(factory, hook);
        require(ratesAfter.length == ratesBefore.length, "the pool list changed length");
        for (uint256 i = 0; i < ratesAfter.length; i++) {
            require(ratesAfter[i] == ratesBefore[i], "a registered pool's rate moved");
        }

        // And the behaviour this whole script exists for, re-probed rather than assumed.
        require(
            !_chargesInBeforeSwap(hook, factory),
            "the proxy still charges in beforeSwap after the upgrade"
        );

        console.log("");
        console.log("  implementation after  ", implementation);
        console.log("Fee basis moved to the unspecified currency, charged in afterSwap.");
        console.log("Markets now accrue in their ASSET token on buys; collect() sweeps both.");
        console.log("Record the tx hash in the deployment manifest, then re-run");
        console.log("  ./script/verify-mainnet-sourcify.sh");
    }

    /// @dev Whether the live implementation still takes its cut in `beforeSwap`.
    ///
    ///      Probes behaviour rather than an address or a selector, because this change alters
    ///      neither. Called as the `PoolManager` on a real registered pool: the fixed build only
    ///      writes an observation and returns `ZERO_DELTA`, which needs no open unlock and so
    ///      succeeds; the old build reaches `poolManager.mint`, which is `onlyWhenUnlocked`, and
    ///      reverts because a script holds no unlock.
    ///
    ///      The pool's live rate must be non-zero or the probe is blind: at zero pips both
    ///      builds take the same early exit and return a zero delta, which includes the case
    ///      where `ProtocolGuard` has the protocol halted. `feePipsFor` (not `feePipsOf`) is the
    ///      right read for that check precisely because it folds the halt in.
    ///
    ///      Runs inside a state snapshot. The observation write is harmless — it only lands in
    ///      forge's simulated fork, never on chain — but leaving it there would perturb the
    ///      oracle reads of anything else in the same run.
    function _chargesInBeforeSwap(ProtocolFeeHook hook, AssetMarketFactory factory)
        private
        returns (bool)
    {
        PoolKey memory key = factory.poolKeyOf(1);
        require(
            hook.feePipsFor(key.toId()) > 0,
            "probe pool charges nothing (zero rate, or the protocol is halted): "
            "the beforeSwap probe cannot tell the two implementations apart"
        );

        uint256 snap = vm.snapshotState();

        vm.prank(address(hook.poolManager()));
        try hook.beforeSwap(
            // The `sender` argument, which `beforeSwap` declares unnamed and never reads. A
            // literal rather than `address(this)`: forge refuses a script that leans on its own
            // ephemeral address, and rightly so, even where the value is discarded.
            PROBE_SENDER,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: PROBE_AMOUNT_IN,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        ) returns (
            bytes4, BeforeSwapDelta delta, uint24
        ) {
            vm.revertToState(snap);
            // Succeeded, so it never reached `mint`. A non-zero delta would mean it charged
            // without minting, which no build of this contract does; treat it as unrecognised.
            require(
                BeforeSwapDelta.unwrap(delta) == 0,
                "beforeSwap returned a non-zero delta without minting: unrecognised build"
            );
            return false;
        } catch {
            vm.revertToState(snap);
            return true;
        }
    }

    /// @dev Every registered pool's STORED rate, in market-id order, with the recipient checked
    ///      to be present so a pool the factory lists but the hook never registered cannot pass
    ///      silently as a zero.
    ///
    ///      `feePipsOf` rather than `feePipsFor`: the latter returns zero while the protocol is
    ///      halted, so a before/after comparison built on it would compare two zeroes and prove
    ///      nothing.
    ///
    ///      Pools are enumerated through the factory because the hook keeps no list.
    ///      `registerPool` is `registrar`-only and the factory calls it once per market, so
    ///      `marketCount()` covers every pool this hook charges — given the registrar has never
    ///      rotated, which the identity check above pins.
    function _auditRegisteredPools(AssetMarketFactory factory, ProtocolFeeHook hook)
        private
        view
        returns (uint24[] memory rates)
    {
        uint256 count = factory.marketCount();
        rates = new uint24[](count);

        uint24 highest;
        for (uint256 id = 1; id <= count; id++) {
            PoolId poolId = factory.poolKeyOf(id).toId();
            require(hook.feeRecipientOf(poolId) != address(0), "a market's pool is unregistered");

            rates[id - 1] = hook.feePipsOf(poolId);
            if (rates[id - 1] > highest) highest = rates[id - 1];
        }

        console.log("  pools audited         ", count);
        console.log("  highest stored rate   ", highest);
    }

    function _impl(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
