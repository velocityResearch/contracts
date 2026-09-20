// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IProtocolGuard} from "./IProtocolGuard.sol";

/// @title ProtocolGuard
/// @notice The protocol's single pause switch, and the only contract that knows who may throw
///         it. Every guarded contract in the system reads this one address.
///
///         **Why one registry rather than a `Pausable` on each contract.** A brand's market is
///         five contracts, and there is no bound on how many markets exist. Pausing an incident
///         by sending one transaction per contract is not a response, it is a scheduling
///         problem — by the time the five hundredth lands the money is gone. Here a single
///         `pause()` halts every guarded contract at once, including markets that had not been
///         created when the guard was written.
///
///         **Two authorities, deliberately asymmetric.**
///
///         - `guardian` may halt, immediately, with no delay. Stopping an active exploit is
///           worth nothing if it has to wait out a timelock, so this key is fast. It is also
///           narrow: halting is the only thing it can do. It cannot resume, cannot upgrade,
///           cannot move a token, and cannot change who the guardian is.
///         - `owner` — the protocol timelock — may halt, resume, replace the guardian, and
///           authorise upgrades. Resuming is deliberately the slow path: a compromised guardian
///           key can cost the protocol its uptime, and that is recoverable. A key that could
///           resume could also un-halt an exploit mid-drain, and that is not.
///
///         So the worst a stolen guardian key achieves is a denial of service that the timelock
///         then unwinds. That asymmetry is the whole design.
///
///         **What pausing does NOT reach.** `SharedReservePool.redeem` is not guarded and must
///         never become guarded. A branded stablecoin is a 1:1 claim on the reserve, redeemable
///         with no fee and no slippage; a pause that could hold a redemption would turn that
///         claim into a promise conditional on the protocol's goodwill, which is a different and
///         much worse product. Holders can always leave, including while everything else is
///         halted — especially then. See ASSET_MARKETS.md.
contract ProtocolGuard is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IProtocolGuard {
    /// @notice Halts every guarded contract at once.
    bool public paused;

    /// @notice Halts one contract. Read together with `paused`, never instead of it, so a
    ///         global halt cannot be escaped by clearing a single target's flag.
    mapping(address => bool) public pausedTarget;

    /// @notice May halt, and may do nothing else. See the contract note.
    address public guardian;

    /// @dev Reserved so later versions can add state without disturbing anything that follows
    ///      in a child contract's layout. Nothing inherits this today; the gap costs nothing
    ///      and removes the question.
    uint256[47] private __gap;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event TargetPaused(address indexed target, address indexed by);
    event TargetUnpaused(address indexed target, address indexed by);
    event GuardianUpdated(address indexed previous, address indexed current);

    error ProtocolPaused();
    error OnlyGuardianOrOwner();
    error ZeroAddress();
    error OwnershipCannotBeRenounced();

    /// @dev The implementation is never itself initialised. Left initialisable, its `initialize`
    ///      could be called by anyone, who would then own an implementation that a UUPS proxy
    ///      delegates into — the classic route to `selfdestruct`-by-upgrade on the logic
    ///      contract.
    constructor() {
        _disableInitializers();
    }

    /// @param _owner    The protocol timelock. Not an EOA in any real deployment.
    /// @param _guardian The fast halt key. May equal `_owner`, which simply means there is no
    ///                  fast path and every halt waits out the timelock.
    function initialize(address _owner, address _guardian) external initializer {
        if (_owner == address(0) || _guardian == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();

        guardian = _guardian;
        emit GuardianUpdated(address(0), _guardian);
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert OnlyGuardianOrOwner();
        _;
    }

    // ─── Halting ─────────────────────────────────────────────────────────

    /// @notice Halt everything. Guardian or owner, no delay.
    function pause() external onlyGuardianOrOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Halt one contract, leaving the rest running. For an incident confined to a
    ///         single market, where halting the protocol would be a heavier response than the
    ///         problem deserves.
    function pauseTarget(address target) external onlyGuardianOrOwner {
        if (target == address(0)) revert ZeroAddress();
        pausedTarget[target] = true;
        emit TargetPaused(target, msg.sender);
    }

    // ─── Resuming: owner only, and therefore timelocked ──────────────────

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function unpauseTarget(address target) external onlyOwner {
        pausedTarget[target] = false;
        emit TargetUnpaused(target, msg.sender);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ─── Reads ───────────────────────────────────────────────────────────

    function isPaused(address target) public view returns (bool) {
        return paused || pausedTarget[target];
    }

    function requireNotPaused(address target) external view {
        if (isPaused(target)) revert ProtocolPaused();
    }

    /// @notice Always reverts, for the same reason the reserve pool and the sUSDai adapter
    ///         refuse it — except the consequence here is worse. This contract owns `unpause`,
    ///         `unpauseTarget`, `setGuardian` and `_authorizeUpgrade`, and `GuardedUpgradeable`
    ///         has no setter for the guard address it read at initialisation. So renouncing
    ///         would leave every guarded contract in the protocol pointed at a registry whose
    ///         resume path is permanently unreachable and whose implementation can never be
    ///         upgraded: one call from the owner, and the guardian key alone decides whether
    ///         the protocol ever runs again. `transferOwnership` is the handover path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
