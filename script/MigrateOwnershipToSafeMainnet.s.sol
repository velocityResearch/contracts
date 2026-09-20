// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @dev Enough of a Safe to prove the destination is one.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function VERSION() external view returns (string memory);
}

/// @title MigrateOwnershipToSafeMainnet
/// @notice Moves every ownership handle off the deployer EOA
///         `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` and onto a multisig.
///
/// @dev    **Why this is the single highest-value pre-audit change.** Sixteen contracts,
///         including both reserves holding real deposits, the factory, the router and the fee
///         hook, answer to one hot key. Every other hardening in this repo is downstream of
///         that key staying secret. No fee cap, delay or pause survives an owner who can
///         upgrade the implementation that enforces it.
///
///         **Two phases, in this order, and the order is the safety property.**
///
///         `PHASE=1` transfers the twelve `Ownable2Step` handles. A two-step transfer is
///         reversible right up until the new owner calls `acceptOwnership()`: the old owner
///         keeps full control, and a wrong destination is undone by transferring again. This
///         phase is therefore safe to run first and to verify at leisure.
///
///         `PHASE=2` transfers the four beacons. These are plain `Ownable`: one step, no
///         acceptance, IRREVERSIBLE. A beacon controls the implementation behind every brand
///         token and treasury clone, so a mistake here is unrecoverable and total. It runs
///         last, only after phase 1 has been accepted and proven, because by then the
///         destination has demonstrated it can actually transact.
///
///         **The destination is proven to be a live multisig before anything moves.** The
///         failure this prevents is the only one that matters: a typo, or an address whose
///         keys nobody holds. `_requireUsableSafe` insists the destination has code, answers
///         `getThreshold()` with at least 2, and lists at least as many owners as its
///         threshold. An EOA, an empty address and a 1-of-1 all fail. For phase 2 it
///         additionally requires that the Safe has already ACCEPTED at least one phase-1
///         handle, which is the only real proof that its signers can sign.
///
///         **The guardian is deliberately NOT moved.** `ProtocolGuard.guardian` is the address
///         that can `pause`. Pausing is an incident response and must not need two signatures
///         and a coordination call. It stays a separate hot EOA, rotated to a fresh key by
///         `RotateGuardianMainnet`, and the Safe retains the power to replace it. Moving the
///         guardian to the Safe would make the pause useless exactly when it is needed.
///
///         **Sweep revenue BEFORE running this.** `ProtocolFeeHook.collect` pays whoever is
///         named when it runs, and `LaunchFeeEscrow.claimToken` is `msg.sender`-scoped, so
///         accrued balances do not follow an ownership change. See
///         `CollectStrandedValueMainnet`.
///
///         Usage:
///           SAFE=0x… DEPLOYER=0x… PHASE=1 forge script script/MigrateOwnershipToSafeMainnet.s.sol:MigrateOwnershipToSafeMainnet --rpc-url robinhood
///           SAFE=0x… DEPLOYER=0x… PHASE=1 forge script script/MigrateOwnershipToSafeMainnet.s.sol:MigrateOwnershipToSafeMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract MigrateOwnershipToSafeMainnet is Script {
    uint256 constant CHAIN_ID = 4663;

    /// @notice The twelve two-step handles, in ascending order of blast radius so that a run
    ///         which stops early has moved the least dangerous things first.
    ///
    ///         `StrategyGroupRegistry` leads deliberately: it is read-only metadata that
    ///         nothing settles against, so it is the live rehearsal for the rest.
    function _twoStep()
        internal
        pure
        returns (address[13] memory handles, string[13] memory names)
    {
        handles = [
            0xBd02B0f3253F31dD02A752582e7b8974589333f7, // read-only metadata
            0xbE2fb491C37F19E723F86A8cAcA625B4Ba75a5E7, // abandoned gen-4 factory
            0xcCDe2EcDE7072Efe61822551152663F204CF73ce, // abandoned gen-4 router
            0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C, // holds graduated LP positions
            0x013D1974F8215a12280e6b9a33F9732277F38C0e, // pause registry
            0x8e4E5e5EE25DF4721D845600F82bf2Bca48Fa358,
            0x460f319E43428387bff58ec262C992Ec7DA22fDc,
            0x95fe000285DA7797cC01394cCc410628B26e898d, // launchpad
            0x7553919210B172438853C3694Fd88fAfD4bE3Eb4, // router
            0xc9932584c5154e4F58313a2e5423522E74e540Cc, // every pool's fee rate
            0x22AA61c589B90731752236c07d1455D0065bfc79, // market factory
            0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3, // reserve, ~1 USDG
            0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2 // reserve, backs all 18 markets
        ];
        names = [
            "StrategyGroupRegistry",
            "AssetMarketFactory (gen-4, abandoned)",
            "MarketRouter (gen-4, abandoned)",
            "LaunchLocker",
            "ProtocolGuard",
            "MorphoBlueYieldSource",
            "SUSDaiYieldSource",
            "LaunchFactory",
            "MarketRouter",
            "ProtocolFeeHook",
            "AssetMarketFactory",
            "SharedReservePool (USDG/Morpho)",
            "SharedReservePool (sUSDai)"
        ];
    }

    /// @notice The four beacons. One step, irreversible, maximum blast radius.
    function _beacons() internal pure returns (address[4] memory handles, string[4] memory names) {
        handles = [
            0x65876276feE875e1A120F63575150593E6AEa0d3,
            0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6,
            0x1964b405C09CF252d835A80556536C86dcbE105F,
            0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E
        ];
        names = [
            "brandFeeVault beacon",
            "lpRewardDistributor beacon",
            "pooledBrandToken beacon",
            "poolBrandTreasury beacon"
        ];
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address safe = vm.envAddress("SAFE");
        address deployer = vm.envAddress("DEPLOYER");
        uint256 phase = vm.envUint("PHASE");
        require(phase == 1 || phase == 2, "PHASE must be 1 (two-step) or 2 (beacons)");

        _requireUsableSafe(safe);
        require(safe != deployer, "SAFE is the deployer");

        if (phase == 1) _phaseOne(safe, deployer);
        else _phaseTwo(safe, deployer);
    }

    // ─── Phase 1: the reversible twelve ──────────────────────────────────

    function _phaseOne(address safe, address deployer) internal {
        (address[13] memory handles, string[13] memory names) = _twoStep();

        uint256 toMove;
        for (uint256 i; i < handles.length; ++i) {
            IOwnable2Step h = IOwnable2Step(handles[i]);
            address owner = h.owner();
            require(owner == deployer || owner == safe, "a handle is owned by a third party");
            if (owner == deployer) ++toMove;
        }
        if (toMove == 0) {
            console.log("Every two-step handle already names the Safe as owner. Nothing to do.");
            _report(safe);
            return;
        }

        vm.startBroadcast(deployer);
        for (uint256 i; i < handles.length; ++i) {
            IOwnable2Step h = IOwnable2Step(handles[i]);
            if (h.owner() != deployer) continue;
            h.transferOwnership(safe);
            // Nothing has actually moved yet, and that is the point of this phase.
            require(h.pendingOwner() == safe, "transfer did not register the Safe as pending");
            require(h.owner() == deployer, "a two-step handle moved without acceptance");
        }
        vm.stopBroadcast();

        console.log("Phase 1 complete. %s handle(s) now await acceptance by the Safe.", toMove);
        console.log("NOTHING HAS MOVED YET. The deployer still owns all of them.");
        console.log("");
        console.log("From the Safe, call acceptOwnership() on each address below. Until then");
        console.log("this is fully reversible: transferOwnership again to change destination.");
        for (uint256 i; i < handles.length; ++i) {
            console.log("  %s  %s", handles[i], names[i]);
        }
        console.log("");
        console.log("Do NOT run PHASE=2 until at least one of these is accepted.");
        console.log("Phase 2 is irreversible and needs proof the Safe can transact.");
    }

    // ─── Phase 2: the irreversible four ──────────────────────────────────

    function _phaseTwo(address safe, address deployer) internal {
        // The gate. A beacon transfer cannot be undone, so the Safe must first have
        // demonstrated, on this chain, that its signers can actually produce a transaction.
        (address[13] memory twoStep,) = _twoStep();
        uint256 accepted;
        for (uint256 i; i < twoStep.length; ++i) {
            if (IOwnable2Step(twoStep[i]).owner() == safe) ++accepted;
        }
        require(accepted > 0, "run PHASE=1 and accept at least one handle from the Safe first");
        console.log("Safe has accepted %s of 13 two-step handles. Proceeding.", accepted);

        (address[4] memory handles, string[4] memory names) = _beacons();
        uint256 toMove;
        for (uint256 i; i < handles.length; ++i) {
            address owner = IOwnable(handles[i]).owner();
            require(owner == deployer || owner == safe, "a beacon is owned by a third party");
            if (owner == deployer) ++toMove;
        }
        if (toMove == 0) {
            console.log("Every beacon already names the Safe as owner. Nothing to do.");
            _report(safe);
            return;
        }

        vm.startBroadcast(deployer);
        for (uint256 i; i < handles.length; ++i) {
            IOwnable b = IOwnable(handles[i]);
            if (b.owner() != deployer) continue;
            b.transferOwnership(safe);
            require(b.owner() == safe, "a beacon transfer did not land");
        }
        vm.stopBroadcast();

        console.log("Phase 2 complete. %s beacon(s) moved. This cannot be undone.", toMove);
        for (uint256 i; i < handles.length; ++i) {
            console.log("  %s  %s", handles[i], names[i]);
        }
        _report(safe);
    }

    // ─── Checks and reporting ────────────────────────────────────────────

    /// @dev The destination must be a live multisig, not an address that merely looks like one.
    ///      Transferring sixteen handles to a typo is the one mistake with no remedy.
    function _requireUsableSafe(address safe) internal view {
        require(safe != address(0), "SAFE is the zero address");
        require(safe.code.length > 0, "SAFE has no code: it is an EOA or does not exist");

        uint256 threshold = ISafe(safe).getThreshold();
        address[] memory owners = ISafe(safe).getOwners();
        require(threshold >= 2, "SAFE threshold is below 2: a 1-of-n is one key again");
        require(owners.length >= threshold, "SAFE has fewer owners than its own threshold");

        console.log("Destination Safe: %s", safe);
        console.log("  threshold: %s of %s", threshold, owners.length);
        for (uint256 i; i < owners.length; ++i) {
            console.log("    signer:", owners[i]);
        }
    }

    function _report(address safe) internal view {
        (address[13] memory twoStep, string[13] memory twoStepNames) = _twoStep();
        (address[4] memory beacons, string[4] memory beaconNames) = _beacons();

        console.log("");
        console.log("Ownership, as the chain reads it now:");
        for (uint256 i; i < twoStep.length; ++i) {
            IOwnable2Step h = IOwnable2Step(twoStep[i]);
            console.log("  %s owner=%s pending=%s", twoStepNames[i], h.owner(), h.pendingOwner());
        }
        for (uint256 i; i < beacons.length; ++i) {
            console.log("  %s owner=%s", beaconNames[i], IOwnable(beacons[i]).owner());
        }
        console.log("");
        console.log("Still NOT migrated, deliberately: ProtocolGuard.guardian, which must stay");
        console.log("a hot EOA so a pause never waits on a second signature. Rotate it to a");
        console.log("fresh key separately; the Safe (%s) can replace it at will.", safe);
    }
}
