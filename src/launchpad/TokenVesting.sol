// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

/// @title TokenVesting
/// @notice Where a launch's protected allocations — team, treasury, advisors, anything promised
///         rather than sold — sit until time releases them. It is a standalone escrow: nothing
///         in the launchpad calls it yet, and wiring it into a launch flow is a later slice.
///         Until then the owner is the one authorized executor, and it is the address every
///         privileged action here is gated on.
///
///         **A promise can only be made against tokens the contract already holds.** Funding and
///         scheduling are two separate steps: `fund` pulls tokens in and credits a per-token
///         funded balance measured by the actual balance delta, and `createSchedule` may only
///         commit against what is funded and not already committed to some other schedule. There
///         is no path that writes a schedule the escrow cannot pay, so a beneficiary never has to
///         trust that somebody will top the contract up before their cliff. The mirror of that
///         rule is `withdrawUnallocated`: the owner can retrieve funded tokens that no schedule
///         has claimed, and nothing else.
///
///         **Vesting is exact integer math with no stranded dust.** Before the cliff nothing is
///         vested. Between the cliff and `start + duration` the vested figure is
///         `total * (now - start) / duration`, floored, so the escrow never pays ahead of the
///         curve. At `start + duration` the vested figure is the schedule's `total` itself rather
///         than the sum of the floors, so the final claim releases the exact remainder and the
///         rounding loss of every earlier claim comes back to the beneficiary.
///
///         **Revocation is a freeze, not a clawback.** It is available only on schedules created
///         `revocable`, only to the owner, and it settles the schedule at the moment it happens:
///         whatever had vested by then stays the beneficiary's to claim on their own schedule,
///         and only the unvested remainder goes back to the owner. It cannot reach an already
///         vested entitlement, and because every movement is debited from this schedule's own
///         committed balance it cannot reach another schedule's tokens either.
contract TokenVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @param beneficiary The only address that can claim, and the only one that can hand the
    ///                    schedule over (`proposeBeneficiary`)
    /// @param start       When linear accrual begins; may be in the past at creation
    /// @param revocable   Whether the owner may ever freeze this schedule
    /// @param revoked     Set once `revoke` has frozen it
    /// @param token       The ERC-20 this schedule pays in
    /// @param cliff       An absolute timestamp in `[start, start + duration]`; nothing is
    ///                    claimable before it, and the whole accrual since `start` unlocks at once
    /// @param duration    The length of the linear accrual, in seconds; never zero
    /// @param revokedAt   The timestamp vesting was frozen at; meaningless unless `revoked`
    /// @param total       What the schedule promises in full
    /// @param released    What has already been paid out against it
    struct Schedule {
        address beneficiary;
        uint64 start;
        bool revocable;
        bool revoked;
        address token;
        uint64 cliff;
        uint64 duration;
        uint64 revokedAt;
        uint256 total;
        uint256 released;
    }

    /// @notice What this contract holds for `token` on its own books: every funded amount, less
    ///         everything claimed, returned by a revocation or withdrawn as unallocated.
    /// @dev Measured on arrival rather than taken from the caller's word, so a fee-on-transfer
    ///      token can never make the ledger promise more than the balance backs.
    mapping(address token => uint256 amount) public fundedBalance;

    /// @notice How much of `fundedBalance` is spoken for by live schedules: the sum of
    ///         `total - released` across every schedule in `token` that has not been revoked or
    ///         fully paid. `fundedBalance >= committedBalance` is the contract's core invariant.
    mapping(address token => uint256 amount) public committedBalance;

    /// @notice The address `beneficiary` has offered a schedule to, pending their acceptance.
    ///         Zero when nothing is pending.
    mapping(uint256 scheduleId => address proposed) public pendingBeneficiary;

    /// @notice How many schedules have ever been created. Ids are assigned from zero upwards.
    uint256 public scheduleCount;

    mapping(uint256 scheduleId => Schedule schedule) private _schedules;
    mapping(address beneficiary => uint256[] scheduleIds) private _beneficiarySchedules;
    mapping(uint256 scheduleId => uint256 index) private _beneficiaryScheduleIndex;

    event Funded(address indexed token, address indexed depositor, uint256 amount);
    event UnallocatedWithdrawn(address indexed token, address indexed to, uint256 amount);
    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    );
    event Claimed(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 amount
    );
    /// @param vested   What stays claimable by the beneficiary
    /// @param returned What went back to the owner
    event Revoked(uint256 indexed scheduleId, uint256 vested, uint256 returned);
    event BeneficiaryProposed(
        uint256 indexed scheduleId, address indexed current, address indexed proposed
    );
    event BeneficiaryTransferred(
        uint256 indexed scheduleId, address indexed previous, address indexed current
    );

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error InvalidCliff(uint64 start, uint64 cliff, uint64 duration);
    error UnknownSchedule(uint256 scheduleId);
    error NotBeneficiary(uint256 scheduleId);
    error NotProposedBeneficiary(uint256 scheduleId);
    error NotRevocable(uint256 scheduleId);
    error AlreadyRevoked(uint256 scheduleId);
    error NothingToClaim(uint256 scheduleId);
    error InsufficientUnallocated(address token, uint256 requested, uint256 available);
    error OwnershipCannotBeRenounced();

    /// @param initialOwner The authorized executor: it funds, schedules, revokes and withdraws
    ///                     what is unallocated. It can never touch a vested entitlement.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Permanently disabled. Ownership is what creates schedules and what retrieves
    ///         unallocated funding; renouncing it would strand both. Claims never depend on it,
    ///         so nothing is gained by giving it up.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ─── Funding ─────────────────────────────────────────────────────────

    /// @notice Pulls `amount` of `token` from the caller into the escrow's funded balance.
    /// @dev Permissionless: the caller can only move tokens they hold and approve, and funding
    ///      never entitles them to anything — only the owner turns funding into a schedule, and
    ///      only the owner can take unallocated funding back out.
    /// @return received The balance delta actually credited, which is what a fee-on-transfer
    ///                  token leaves behind rather than the nominal `amount`.
    function fund(address token, uint256 amount) external nonReentrant returns (uint256 received) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroAmount();

        fundedBalance[token] += received;
        emit Funded(token, msg.sender, received);
    }

    /// @notice Returns funded `token` that no schedule has committed — over-funding, or what a
    ///         revocation handed back — to `to`.
    /// @dev The only owner path that moves tokens out. It is bounded by `unallocatedBalance`, so
    ///      it can never dip into what a beneficiary is owed.
    function withdrawUnallocated(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 available = fundedBalance[token] - committedBalance[token];
        if (amount > available) revert InsufficientUnallocated(token, amount, available);

        fundedBalance[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit UnallocatedWithdrawn(token, to, amount);
    }

    // ─── Schedules ───────────────────────────────────────────────────────

    /// @notice Promises `total` of `token` to `beneficiary`, vesting linearly from `start` over
    ///         `duration` seconds with nothing claimable before `cliff`.
    /// @dev Reverts unless the tokens are already here and uncommitted, which is what makes
    ///      over-promising impossible: the escrow can always pay every schedule it holds.
    ///      `start` may be backdated, in which case part of the schedule is vested on arrival.
    /// @param cliff An absolute timestamp, not an offset, and it must lie within the accrual
    ///              window — a cliff past the end would make the schedule claimable only as a
    ///              lump sum and a cliff before the start would be a no-op.
    /// @return scheduleId The new schedule's id.
    function createSchedule(
        address beneficiary,
        address token,
        uint256 total,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner returns (uint256 scheduleId) {
        if (beneficiary == address(0) || token == address(0)) revert ZeroAddress();
        if (total == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();
        if (cliff < start || uint256(cliff) > uint256(start) + uint256(duration)) {
            revert InvalidCliff(start, cliff, duration);
        }

        uint256 available = fundedBalance[token] - committedBalance[token];
        if (total > available) revert InsufficientUnallocated(token, total, available);
        committedBalance[token] += total;

        scheduleId = scheduleCount;
        scheduleCount = scheduleId + 1;
        _schedules[scheduleId] = Schedule({
            beneficiary: beneficiary,
            start: start,
            revocable: revocable,
            revoked: false,
            token: token,
            cliff: cliff,
            duration: duration,
            revokedAt: 0,
            total: total,
            released: 0
        });
        _beneficiaryScheduleIndex[scheduleId] = _beneficiarySchedules[beneficiary].length;
        _beneficiarySchedules[beneficiary].push(scheduleId);

        emit ScheduleCreated(
            scheduleId, beneficiary, token, total, start, cliff, duration, revocable
        );
    }

    /// @notice Pays the caller everything schedule `scheduleId` has vested and not yet released.
    /// @dev Pull-based and beneficiary-only. The amount is recomputed from the schedule rather
    ///      than accumulated, so a second claim in the same block finds nothing releasable and
    ///      reverts instead of paying twice.
    /// @return amount What was transferred.
    function claim(uint256 scheduleId) external nonReentrant returns (uint256 amount) {
        Schedule storage schedule = _requireSchedule(scheduleId);
        if (msg.sender != schedule.beneficiary) revert NotBeneficiary(scheduleId);

        amount = _vestedAt(schedule, block.timestamp) - schedule.released;
        if (amount == 0) revert NothingToClaim(scheduleId);

        address token = schedule.token;
        schedule.released += amount;
        committedBalance[token] -= amount;
        fundedBalance[token] -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(scheduleId, msg.sender, token, amount);
    }

    /// @notice Freezes schedule `scheduleId` at the current timestamp and returns the part that
    ///         had not vested yet to the owner.
    /// @dev What had already vested stays committed and stays the beneficiary's to claim whenever
    ///      they like; only the remainder is uncommitted and sent back. Every debit is against
    ///      this schedule's own committed balance, so no other schedule's backing can be moved.
    /// @return returned The unvested amount sent to the owner.
    function revoke(uint256 scheduleId) external onlyOwner nonReentrant returns (uint256 returned) {
        Schedule storage schedule = _requireSchedule(scheduleId);
        if (!schedule.revocable) revert NotRevocable(scheduleId);
        if (schedule.revoked) revert AlreadyRevoked(scheduleId);

        uint256 vested = _vestedAt(schedule, block.timestamp);
        schedule.revoked = true;
        schedule.revokedAt = uint64(block.timestamp);

        returned = schedule.total - vested;
        if (returned != 0) {
            address token = schedule.token;
            committedBalance[token] -= returned;
            fundedBalance[token] -= returned;
            IERC20(token).safeTransfer(owner(), returned);
        }

        emit Revoked(scheduleId, vested - schedule.released, returned);
    }

    // ─── Beneficiary handover ────────────────────────────────────────────

    /// @notice Offers schedule `scheduleId` to `newBeneficiary`, who must accept it.
    /// @dev Two-step, like the launchpad's creator fee recipient: a single-step transfer to a
    ///      mistyped address would destroy the entitlement outright. Proposing again replaces the
    ///      pending offer, and the schedule keeps paying the current beneficiary until acceptance.
    function proposeBeneficiary(uint256 scheduleId, address newBeneficiary) external {
        Schedule storage schedule = _requireSchedule(scheduleId);
        if (msg.sender != schedule.beneficiary) revert NotBeneficiary(scheduleId);
        if (newBeneficiary == address(0)) revert ZeroAddress();

        pendingBeneficiary[scheduleId] = newBeneficiary;
        emit BeneficiaryProposed(scheduleId, msg.sender, newBeneficiary);
    }

    /// @notice Takes over schedule `scheduleId`, as the address its beneficiary offered it to.
    ///         Vesting itself is untouched: the same tokens release on the same timetable.
    function acceptBeneficiary(uint256 scheduleId) external {
        address proposed = pendingBeneficiary[scheduleId];
        if (proposed == address(0) || msg.sender != proposed) {
            revert NotProposedBeneficiary(scheduleId);
        }
        delete pendingBeneficiary[scheduleId];

        Schedule storage schedule = _schedules[scheduleId];
        address previous = schedule.beneficiary;
        schedule.beneficiary = msg.sender;

        _unindexSchedule(previous, scheduleId);
        _beneficiaryScheduleIndex[scheduleId] = _beneficiarySchedules[msg.sender].length;
        _beneficiarySchedules[msg.sender].push(scheduleId);

        emit BeneficiaryTransferred(scheduleId, previous, msg.sender);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice Funded `token` no schedule has committed: what `withdrawUnallocated` can move and
    ///         what the next `createSchedule` can promise.
    function unallocatedBalance(address token) external view returns (uint256) {
        return fundedBalance[token] - committedBalance[token];
    }

    /// @notice The full record of schedule `scheduleId`.
    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        return _requireSchedule(scheduleId);
    }

    /// @notice The ids of every schedule `beneficiary` currently holds, including handed-over
    ///         ones and excluding ones they have handed away.
    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _beneficiarySchedules[beneficiary];
    }

    /// @notice What schedule `scheduleId` has vested as of now, claimed or not. Frozen at the
    ///         revocation timestamp once revoked.
    function vestedAmount(uint256 scheduleId) external view returns (uint256) {
        return _vestedAt(_requireSchedule(scheduleId), block.timestamp);
    }

    /// @notice What the beneficiary of schedule `scheduleId` could claim right now.
    function releasableAmount(uint256 scheduleId) external view returns (uint256) {
        Schedule storage schedule = _requireSchedule(scheduleId);
        return _vestedAt(schedule, block.timestamp) - schedule.released;
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev Vested at `timestamp`: zero before the cliff, `total * elapsed / duration` floored
    ///      inside the window, and the exact `total` at or after the end — which is what leaves
    ///      the final claim carrying the whole accumulated rounding remainder instead of
    ///      stranding it. A revoked schedule is evaluated at the instant it was frozen.
    function _vestedAt(Schedule storage schedule, uint256 timestamp)
        private
        view
        returns (uint256)
    {
        uint256 at = timestamp;
        if (schedule.revoked && at > schedule.revokedAt) at = schedule.revokedAt;
        if (at < schedule.cliff) return 0;

        uint256 duration = schedule.duration;
        if (at >= uint256(schedule.start) + duration) return schedule.total;
        return Math.mulDiv(schedule.total, at - schedule.start, duration);
    }

    /// @dev Schedules always have a non-zero duration, so a zero one means the id was never
    ///      issued. Cheaper than a parallel existence flag and just as total.
    function _requireSchedule(uint256 scheduleId) private view returns (Schedule storage schedule) {
        schedule = _schedules[scheduleId];
        if (schedule.duration == 0) revert UnknownSchedule(scheduleId);
    }

    /// @dev Swap-and-pop the schedule out of its previous holder's list, keeping the moved id's
    ///      index in step.
    function _unindexSchedule(address beneficiary, uint256 scheduleId) private {
        uint256[] storage ids = _beneficiarySchedules[beneficiary];
        uint256 index = _beneficiaryScheduleIndex[scheduleId];
        uint256 lastIndex = ids.length - 1;
        if (index != lastIndex) {
            uint256 movedId = ids[lastIndex];
            ids[index] = movedId;
            _beneficiaryScheduleIndex[movedId] = index;
        }
        ids.pop();
    }
}
