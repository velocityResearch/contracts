// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @dev The slice of OpenZeppelin's `TimelockController` this script drives. Declared here
///      rather than imported so the script keeps compiling if the OZ remapping moves: a
///      governance script that cannot run is worse than a verbose one.
interface ITimelockController {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function PROPOSER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);
    function isOperationPending(bytes32 id) external view returns (bool);
    function isOperationReady(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
    function getTimestamp(bytes32 id) external view returns (uint256);
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;
}

interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title HandOverMainnetOwnership
/// @notice Moves the three mainnet proxies the deployer EOA still owns outright — the
///         `AssetMarketFactory`, the `MarketRouter` and the `ProtocolFeeHook` — behind the
///         48-hour `TimelockController` that already owns everything else.
///
///         This is CRITICAL-1 from `ASSET_MARKETS_AUDIT_UPGRADEABLE.md`. The manifest argued
///         it was tolerable because no market existed and the reserve held nothing. That is no
///         longer true: as of 2026-09-16 the factory reports 11 markets and the reserve holds
///         ~$362 of real USDG, ~$356 of it belonging to addresses other than the deployer. Any
///         one of those three proxies can be rewritten today by a single hot key with no delay
///         and no notice, and the router and factory are what every market's trading and
///         issuance path runs through.
///
///         **Why this takes two runs and 48 hours.** All three are `Ownable2Step`, so a
///         transfer only nominates: the new owner has to call `acceptOwnership` itself. The new
///         owner here is the timelock, which cannot call anything except through a scheduled
///         operation. So run 1 nominates the timelock on all three AND schedules the three
///         `acceptOwnership` calls as one batch; run 2, after the delay, executes that batch.
///         Between the two runs the EOA is still the owner — nothing is handed over and nothing
///         is lost if run 2 never happens, because a nomination the timelock never accepts
///         expires into nothing.
///
///         **The batch is one operation on purpose.** Scheduling three separate operations
///         would let them be executed piecemeal, leaving the protocol split across two owners
///         for as long as anyone liked. As a batch, either all three move or none do.
///
///         **The salt is derived, not random.** Run 2 has to reproduce the exact operation id
///         run 1 scheduled, and a random salt would mean carrying a value between two
///         invocations 48 hours apart. Deriving it from the purpose keeps the two runs
///         independent — but it also means this script can only ever schedule this operation
///         once. If it needs re-scheduling after a cancellation, bump `SALT_VERSION`.
///
///         Usage:
///           # run 1: nominate + schedule
///           PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership \
///               --sig 'nominateAndSchedule()' --rpc-url robinhood --broadcast --slow
///
///           # ...48 hours later, run 2: execute
///           PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership \
///               --sig 'executeHandover()' --rpc-url robinhood --broadcast --slow
///
///           # read-only status at any point
///           forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership \
///               --sig 'status()' --rpc-url robinhood
///
///         Both broadcasting entry points refuse to run unless every precondition they depend
///         on still holds on chain, so a half-applied handover cannot be made worse by a
///         re-run.
contract HandOverMainnetOwnership is Script {
    /// @notice Bump to re-schedule after a cancellation, or when this script is retargeted at
    ///         a new set of proxies. Version 1 targeted the gen-4 stack; version 2 targets the
    ///         gen-5 stack deployed 2026-09-16.
    uint256 internal constant SALT_VERSION = 2;

    /// @notice The 48-hour timelock deployed with the gen-5 reserve. It already owns the
    ///         reserve, the sUSDai group, both yield adapters, the guard and every beacon —
    ///         the five proxies below are the only ones the deploying key kept, and it kept
    ///         them because the deployment had to make owner calls on them immediately after
    ///         creating them (`setRegistrar`, `setProtocolFeePips`, `setLaunchpad`, and the
    ///         launchpad's own wiring). This script is what finishes the job.
    address internal constant TIMELOCK = 0x0f0595f1923928CB919B086E8A73A6B54889d22E;

    address internal constant FACTORY = 0xeba2e7A24D6f9DD95f2219eb088CF56266A41B95;
    address internal constant ROUTER = 0xeEb48DF599ca8d8C22e5f6a0da51955E42c7DD09;
    address internal constant FEE_HOOK = 0x92e45Ee89161ce9D803e236cF99C4d358488c0CC;

    /// @notice The launchpad proxies the same deployment left on the deploying key. Folded
    ///         into the same batch as the market stack: they are the same defect with the same
    ///         fix, and splitting them would leave a window where half the protocol answers to
    ///         the timelock and half to a hot key.
    address internal constant LAUNCH_FACTORY = 0x9Df6BD77AB383Ae111AED18e693ea4F75871dE65;
    address internal constant LAUNCH_LOCKER = 0x10487B2e5e288dA0445A85CdC3f3b963b1F74661;

    uint256 internal constant PROXY_COUNT = 5;

    function _targets() private pure returns (address[] memory t) {
        t = new address[](PROXY_COUNT);
        t[0] = FACTORY;
        t[1] = ROUTER;
        t[2] = FEE_HOOK;
        t[3] = LAUNCH_FACTORY;
        t[4] = LAUNCH_LOCKER;
    }

    function _labels() private pure returns (string[] memory l) {
        l = new string[](PROXY_COUNT);
        l[0] = "AssetMarketFactory";
        l[1] = "MarketRouter";
        l[2] = "ProtocolFeeHook";
        l[3] = "LaunchFactory";
        l[4] = "LaunchLocker";
    }

    /// @dev The batch every run derives identically: three `acceptOwnership()` calls, no value.
    function _batch()
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = _targets();
        values = new uint256[](PROXY_COUNT);
        payloads = new bytes[](PROXY_COUNT);
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            payloads[i] = abi.encodeCall(IOwnable2Step.acceptOwnership, ());
        }
    }

    function _salt() private pure returns (bytes32) {
        return keccak256(abi.encode("stables.ownership-handover.critical-1", SALT_VERSION));
    }

    function _operationId() private view returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();
        return ITimelockController(TIMELOCK)
            .hashOperationBatch(targets, values, payloads, bytes32(0), _salt());
    }

    // ─── Run 1 ───────────────────────────────────────────────────────────

    /// @notice Nominates the timelock on all three proxies and schedules the batch that accepts.
    function nominateAndSchedule() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);

        ITimelockController timelock = ITimelockController(TIMELOCK);
        require(TIMELOCK.code.length > 0, "timelock has no code");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "deployer cannot propose");

        address[] memory targets = _targets();
        string[] memory labels = _labels();

        // Every proxy must still be owned by this key, and must not already be mid-handover to
        // something else. Checked before anything is sent so a partially applied run is
        // diagnosed rather than compounded.
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            IOwnable2Step p = IOwnable2Step(targets[i]);
            require(p.owner() == deployer, string.concat(labels[i], ": not owned by this key"));
            address pending = p.pendingOwner();
            require(
                pending == address(0) || pending == TIMELOCK,
                string.concat(labels[i], ": already nominated elsewhere")
            );
        }

        bytes32 id = _operationId();
        require(!timelock.isOperationDone(id), "handover already executed");
        bool alreadyScheduled = timelock.isOperationPending(id);

        uint256 delay = timelock.getMinDelay();
        console.log("=== CRITICAL-1 ownership handover: nominate + schedule ===");
        console.log("Deployer:", deployer);
        console.log("Timelock:", TIMELOCK);
        console.log("Min delay (s):", delay);

        vm.startBroadcast(key);

        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            IOwnable2Step p = IOwnable2Step(targets[i]);
            if (p.pendingOwner() != TIMELOCK) {
                p.transferOwnership(TIMELOCK);
                console.log(string.concat("Nominated timelock on ", labels[i]));
            } else {
                console.log(string.concat("Already nominated: ", labels[i]));
            }
        }

        if (!alreadyScheduled) {
            (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch();
            timelock.scheduleBatch(t, v, p, bytes32(0), _salt(), delay);
            console.log("Scheduled the acceptOwnership batch.");
        } else {
            console.log("Batch was already scheduled; left as is.");
        }

        vm.stopBroadcast();

        // Read back rather than trust the calls above.
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            require(
                IOwnable2Step(targets[i]).pendingOwner() == TIMELOCK,
                string.concat(labels[i], ": nomination did not stick")
            );
        }
        require(timelock.isOperationPending(id), "batch is not pending");

        console.log("");
        console.log("Operation id:");
        console.logBytes32(id);
        console.log("Executable at (unix):", timelock.getTimestamp(id));
        console.log("");
        console.log("OWNERSHIP HAS NOT MOVED YET. The EOA is still the owner of all three.");
        console.log("After the delay, run:");
        console.log(
            "  forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'executeHandover()' --rpc-url robinhood --broadcast --slow"
        );
    }

    // ─── Run 2 ───────────────────────────────────────────────────────────

    /// @notice Executes the scheduled batch once the delay has elapsed, moving all three.
    function executeHandover() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);

        ITimelockController timelock = ITimelockController(TIMELOCK);
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer), "deployer cannot execute");

        bytes32 id = _operationId();
        require(!timelock.isOperationDone(id), "handover already executed");
        require(timelock.isOperationPending(id), "nothing scheduled for this salt");
        require(timelock.isOperationReady(id), "delay has not elapsed yet");

        console.log("=== CRITICAL-1 ownership handover: execute ===");
        console.log("Operation id:");
        console.logBytes32(id);

        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch();

        vm.startBroadcast(key);
        timelock.executeBatch(t, v, p, bytes32(0), _salt());
        vm.stopBroadcast();

        // The whole point of the exercise, read back off chain.
        address[] memory targets = _targets();
        string[] memory labels = _labels();
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            IOwnable2Step proxy = IOwnable2Step(targets[i]);
            require(proxy.owner() == TIMELOCK, string.concat(labels[i], ": owner did not move"));
            require(
                proxy.pendingOwner() == address(0),
                string.concat(labels[i], ": nomination not cleared")
            );
            console.log(string.concat(labels[i], " -> timelock"));
        }
        require(timelock.isOperationDone(id), "operation not marked done");

        console.log("");
        console.log("=== CRITICAL-1 RESOLVED ===");
        console.log("All three proxies now answer to the 48h timelock.");
        console.log("The deployer EOA can no longer upgrade them without the delay.");
        console.log("");
        console.log("STILL TRUE, and not what this script fixes: the same EOA is the only");
        console.log("timelock proposer, the guardian, and the protocol treasury. Splitting");
        console.log("those is a separate decision (see docs/MAINNET_READINESS_2026-09-16.md).");
    }

    // ─── Read-only ───────────────────────────────────────────────────────

    /// @notice Prints where the handover stands. Broadcasts nothing, needs no key.
    function status() external view {
        ITimelockController timelock = ITimelockController(TIMELOCK);
        address[] memory targets = _targets();
        string[] memory labels = _labels();

        console.log("=== Ownership status, chain", block.chainid, "===");
        for (uint256 i = 0; i < PROXY_COUNT; i++) {
            IOwnable2Step proxy = IOwnable2Step(targets[i]);
            console.log(labels[i]);
            console.log("  owner:        ", proxy.owner());
            console.log("  pendingOwner: ", proxy.pendingOwner());
            console.log("  at timelock:  ", proxy.owner() == TIMELOCK);
        }

        bytes32 id = _operationId();
        console.log("");
        console.log("Batch operation id:");
        console.logBytes32(id);
        console.log("  pending:", timelock.isOperationPending(id));
        console.log("  ready:  ", timelock.isOperationReady(id));
        console.log("  done:   ", timelock.isOperationDone(id));
        uint256 ts = timelock.getTimestamp(id);
        if (ts > 1) {
            console.log("  executable at (unix):", ts);
            console.log("  now (unix):          ", block.timestamp);
        }
    }
}
