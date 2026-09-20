// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/governance/TimelockController.sol";

interface IOwnableLike {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/// @title MainnetInstantUpgrades
/// @notice Moves the Robinhood Chain mainnet stack off its 48h `TimelockController` so every
///         upgrade is a single immediate transaction, matching the Base Sepolia deployment.
///
///         **The one wait you cannot skip is the first one.** The timelock at
///         `0x5f43E1e732c7aBdbbC73F9d1367320D9040C872a` owns the guard, the reserve pool, the
///         Morpho adapter and the beacons, and its `getMinDelay()` is 172800. Anything it owns
///         can only be changed by an operation that has sat for the delay then in force — that
///         is the entire content of a timelock, and handing ownership away is itself such an
///         operation. So: `schedule()` today, wait 48h, `execute()`. From then on, upgrades are
///         one `upgradeToAndCall` from the deployer with no scheduling at all.
///
///         Ownership goes to the deployer EOA rather than to a zero-delay timelock. A zero-delay
///         timelock is the same key wearing a costume: it schedules and executes in the same
///         block while presenting a governance surface that does not constrain anybody.
///
///         **What this gives up.** The timelock is the only thing that currently stands between
///         a leaked deployer key and an instant rewrite of every brand token, brand treasury,
///         fee vault and LP reward distributor implementation. After this runs, that key is the
///         whole of the protocol's upgrade authority. Note the stack already leans that way —
///         the hook, factory and router proxies were never timelocked and the EOA is the
///         timelock's sole proposer, executor and canceller, so it is already the only party
///         that can move anything.
///
///         **Alternative, if the stack is still empty.** The v4 deployment has zero markets and
///         an empty reserve (`deployments/asset-markets-mainnet-v4.json`). Redeploying it with
///         `TIMELOCK_MIN_DELAY=0` through `DeploySharedReservePool.s.sol` reaches the same end
///         state today rather than in two days, at the cost of new addresses and a fresh
///         verification pass. Choose that if nothing yet quotes these addresses.
///
///         Usage:
///         TARGETS=<comma-separated> forge script script/MainnetInstantUpgrades.s.sol \
///           --sig 'schedule()' --rpc-url robinhood --broadcast
///         ... 48h later, same TARGETS and same SALT ...
///         TARGETS=<same> forge script script/MainnetInstantUpgrades.s.sol \
///           --sig 'execute()' --rpc-url robinhood --broadcast
///         TARGETS=<same> forge script script/MainnetInstantUpgrades.s.sol \
///           --sig 'accept()' --rpc-url robinhood --broadcast
///
///         Environment variables:
///         - PRIVATE_KEY  deployer key, the timelock's sole proposer and executor (required)
///         - TIMELOCK     defaults to the v4 timelock
///         - TARGETS      every timelock-owned contract to hand over: the guard, the reserve
///                        pool, the Morpho adapter and each live beacon. Required, and
///                        explicit, because a beacon left behind stays frozen behind a delay
///                        that nothing else in the stack still respects.
///         - SALT         operation salt, so a re-run does not collide with a live proposal
contract MainnetInstantUpgrades is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    address constant DEFAULT_TIMELOCK = 0x5f43E1e732c7aBdbbC73F9d1367320D9040C872a;

    function schedule() external {
        (uint256 key, address deployer, TimelockController timelock, address[] memory targets) =
            _setUp();
        uint256 delay = timelock.getMinDelay();

        (address[] memory to, uint256[] memory values, bytes[] memory payloads) =
            _batch(targets, deployer);
        bytes32 salt = _salt();

        console.log("Scheduling ownership transfer of %d contracts", targets.length);
        console.log("Executable after (s):", delay);
        console.log("Salt:");
        console.logBytes32(salt);

        vm.startBroadcast(key);
        timelock.scheduleBatch(to, values, payloads, bytes32(0), salt, delay);
        vm.stopBroadcast();

        bytes32 id = timelock.hashOperationBatch(to, values, payloads, bytes32(0), salt);
        console.log("Operation id:");
        console.logBytes32(id);
        console.log("Ready at (unix):", timelock.getTimestamp(id));
        console.log("Re-run with --sig 'execute()' and the SAME TARGETS and SALT after that.");
    }

    function execute() external {
        (uint256 key, address deployer, TimelockController timelock, address[] memory targets) =
            _setUp();

        (address[] memory to, uint256[] memory values, bytes[] memory payloads) =
            _batch(targets, deployer);
        bytes32 salt = _salt();
        bytes32 id = timelock.hashOperationBatch(to, values, payloads, bytes32(0), salt);
        require(timelock.isOperationReady(id), "operation is not ready (or salt/targets differ)");

        vm.startBroadcast(key);
        timelock.executeBatch(to, values, payloads, bytes32(0), salt);
        vm.stopBroadcast();

        console.log("Executed. Ownable2Step targets now need accept().");
    }

    /// @notice Claim every pending `Ownable2Step` handover. Targets that are plain `Ownable`
    ///         — the beacons — transferred outright in `execute` and are skipped here.
    /// @dev    Uses `_load` rather than `_setUp`: by the time this runs the beacons are already
    ///         owned by the deployer, so `_setUp`'s "every target is owned by the timelock"
    ///         precondition is guaranteed false and would dead-end the runbook at step three —
    ///         with a revert an operator naturally misreads as "execute failed", leaving the
    ///         Ownable2Step half of the stack behind the 48h delay.
    function accept() external {
        (uint256 key, address deployer,, address[] memory targets) = _load();

        vm.startBroadcast(key);
        for (uint256 i = 0; i < targets.length; i++) {
            if (IOwnableLike(targets[i]).owner() == deployer) continue;
            try IOwnableLike(targets[i]).acceptOwnership() {
                console.log("accepted:", targets[i]);
            } catch {
                console.log("NOT pending for us (check manually):", targets[i]);
            }
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < targets.length; i++) {
            require(IOwnableLike(targets[i]).owner() == deployer, "a target is still not ours");
        }
        console.log("");
        console.log("Every target is owned by the deployer. Upgrades are now one transaction:");
        console.log("    cast send <proxy> 'upgradeToAndCall(address,bytes)' <impl> 0x");
    }

    /// @dev Preconditions for `schedule` and `execute`: the batch they build is a no-op unless
    ///      the timelock still owns every target, so refusing to run is the right answer there.
    function _setUp()
        private
        view
        returns (uint256 key, address deployer, TimelockController timelock, address[] memory)
    {
        address[] memory targets;
        (key, deployer, timelock, targets) = _load();
        for (uint256 i = 0; i < targets.length; i++) {
            require(
                IOwnableLike(targets[i]).owner() == address(timelock),
                "a target is not owned by the timelock"
            );
        }
        return (key, deployer, timelock, targets);
    }

    /// @dev The part of the setup every step can assert: right chain, a key, a timelock handle
    ///      and a non-empty target list that is all contracts. Deliberately says nothing about
    ///      who owns those targets, because that is different at each step of the runbook.
    function _load()
        private
        view
        returns (uint256 key, address deployer, TimelockController timelock, address[] memory)
    {
        require(block.chainid == ROBINHOOD_MAINNET, "not Robinhood Chain mainnet (4663)");
        key = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(key);
        timelock = TimelockController(payable(vm.envOr("TIMELOCK", DEFAULT_TIMELOCK)));

        address[] memory targets = vm.envAddress("TARGETS", ",");
        require(targets.length > 0, "TARGETS is empty");
        for (uint256 i = 0; i < targets.length; i++) {
            require(targets[i].code.length > 0, "a target has no code");
        }
        return (key, deployer, timelock, targets);
    }

    function _batch(address[] memory targets, address newOwner)
        private
        pure
        returns (address[] memory to, uint256[] memory values, bytes[] memory payloads)
    {
        to = targets;
        values = new uint256[](targets.length);
        payloads = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            payloads[i] = abi.encodeCall(IOwnableLike.transferOwnership, (newOwner));
        }
    }

    /// @dev Defaulted rather than random: `execute` has to reproduce the exact salt `schedule`
    ///      used, two days later, from a different shell.
    function _salt() private view returns (bytes32) {
        return vm.envOr("SALT", bytes32(keccak256("instant-upgrades-v1")));
    }
}
