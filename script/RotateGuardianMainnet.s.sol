// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IProtocolGuard {
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function setGuardian(address newGuardian) external;
    function paused() external view returns (bool);
}

/// @title RotateGuardianMainnet
/// @notice Plans the rotation of `ProtocolGuard.guardian` off the retired deployer EOA and
///         onto a fresh hot key. Validates the candidate and writes an importable Safe
///         Transaction Builder batch. Broadcasts nothing.
///
/// @dev    **Why this cannot broadcast.** `setGuardian` is `onlyOwner`, and since the custody
///         migration the owner is the 2-of-3 Safe. A `forge script` cannot produce a Safe
///         signature, so an earlier version of this file that called `vm.startBroadcast` and
///         required `owner == signer` could no longer run at all. Rather than leave a script
///         that always reverts, it now does the half a script is still good at: check the
///         candidate hard, then hand the multisig an exact transaction to sign.
///
///         **Why the guardian is not the Safe, and must never be.** The guardian is the
///         address that can halt the protocol immediately. Halting is incident response: it
///         is wanted in the minute an exploit starts, not after two signers have been woken
///         up and agreed on a transaction. Routing `pause` through a 2-of-3 converts the one
///         control that has to be instant into the slowest one. The powers are asymmetric
///         precisely so this is safe: the guardian can only halt. It cannot resume, move a
///         token, upgrade anything, or change who the guardian is. The worst a stolen
///         guardian key achieves is a denial of service that the owner reverses.
///
///         **Why it still needs rotating.** The deployer EOA is retired from every other
///         role. Leaving it as guardian keeps a key alive as a live control surface on an
///         address whose whole purpose was to stop mattering.
///
///         **What is checked, and why each one.** The zero address and the current guardian
///         are rejected as no-ops or worse. The owner is rejected because `initialize`
///         permits `guardian == owner` to mean "no separate fast key", which is a legitimate
///         configuration but not a legitimate OUTCOME of a script whose entire purpose is to
///         produce a separate fast key.
///
///         **A contract is rejected, but an EIP-7702 delegated account is not.** The point of
///         the code check is that halting must not depend on anyone else's signers, so a Safe
///         or any other smart wallet is refused. A 7702 account is not that: it is an ordinary
///         EOA whose key still signs its own transactions, and the delegated code only runs
///         when something CALLS INTO the address. A transaction sent BY the account is still
///         a plain EOA transaction, so `pauseTarget` behaves exactly as it would from a bare
///         key and `msg.sender` still matches. A flat `code.length == 0` would ban every
///         modern wallet for a risk that does not apply, so the rule below describes what
///         actually matters: exactly the 23-byte delegation marker is allowed, anything else
///         with code is not.
///
///         The residual difference, stated rather than hidden: a delegation can be changed or
///         revoked later by the account's key. That cannot take away the ability to pause,
///         since that needs only the key, but it is a moving part a bare EOA does not have.
///
///         Usage:
///           GUARDIAN=0x… forge script script/RotateGuardianMainnet.s.sol:RotateGuardianMainnet --rpc-url robinhood
///         Then paste the printed target and calldata into the Safe as a raw transaction and
///         sign it 2-of-3. Nothing is written to disk: the default Foundry profile holds no
///         filesystem permissions on purpose, and a convenience file is not worth widening
///         what a script is allowed to touch.
contract RotateGuardianMainnet is Script {
    uint256 constant CHAIN_ID = 4663;
    address constant GUARD = 0x013D1974F8215a12280e6b9a33F9732277F38C0e;

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address newGuardian = vm.envAddress("GUARDIAN");

        IProtocolGuard guard = IProtocolGuard(GUARD);
        address owner = guard.owner();
        address current = guard.guardian();

        require(newGuardian != address(0), "GUARDIAN is the zero address");
        require(newGuardian != current, "GUARDIAN is already the guardian");
        require(newGuardian != owner, "GUARDIAN must not be the owner: that is no fast key");
        // EIP-7702: a delegated EOA's code is exactly `0xef0100` followed by the 20-byte
        // delegate address. Accept precisely that shape and nothing else, so a real contract
        // wallet is still refused.
        bytes memory code = newGuardian.code;
        bool bare = code.length == 0;
        bool delegated = code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
        require(bare || delegated, "GUARDIAN is a contract: a pause must not need other signers");

        if (delegated) {
            address delegate;
            assembly {
                delegate := shr(96, mload(add(code, 35)))
            }
            console.log("GUARDIAN is an EIP-7702 account delegating to:", delegate);
            console.log("  Its key still signs its own transactions, so pausing is unaffected.");
        }

        bytes memory data = abi.encodeCall(IProtocolGuard.setGuardian, (newGuardian));

        console.log("ProtocolGuard:      ", GUARD);
        console.log("  owner (the Safe): ", owner);
        console.log("  guardian before:  ", current);
        console.log("  guardian after:   ", newGuardian);
        console.log("  protocol halted:  ", guard.paused());

        console.log("");
        console.log("Sign this from the Safe as a raw transaction:");
        console.log("  to:    %s", GUARD);
        console.log("  value: 0");
        console.log("  data:  %s", vm.toString(data));
        console.log("");
        console.log("Reversible: the owner may call setGuardian again at any time.");
    }
}
