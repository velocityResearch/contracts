// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2LaunchLocker.sol), MIT.

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {LpRewardDistributor} from "../markets/LpRewardDistributor.sol";
import {
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchFeePolicy,
    ILaunchLocker
} from "./interfaces/ILaunchpad.sol";

/// @title LaunchLocker
/// @notice Where a graduated launch's liquidity lives forever, and where its income is split.
///
///         Every graduation seeds a full-range position in the new market's pool and stakes it
///         in that market's `LpRewardDistributor` with this contract as the staker. The
///         distributor custodies the NFT; this contract is the only address that could ever
///         ask for it back, and it has no function that does. The share of supply that could
///         not enter the pool without lowering its opening price is pulled here too, and
///         there is no function that moves it out. Neither an owner nor an upgrade can change
///         that: the contract is not upgradeable, and ownership exists only to wire the
///         graduation module once.
///
///         **What the position earns is not locked — but it earns one stream, not two.** Pons
///         paid the creator out of a hook fee on every swap; here the locked position is just
///         the market's largest LP, so it earns what an LP earns from the pool itself: the
///         swap fees, in the quote brand and in the launch token. `collect` pulls those and
///         splits them on the position's snapshotted `creatorShareBps`.
///
///         **It earns no float yield, deliberately.** `recordPosition` calls
///         `LpRewardDistributor.renounceRewards`, so the market's float stream divides among
///         the liquidity providers who actually put capital at risk. Nobody owns this
///         position and nobody funded it out of pocket; paying it a subsidy meant for
///         liquidity would be taking that subsidy from the people providing it. The position
///         stays staked regardless, because the distributor custodies the NFT and
///         `collectFees` is what pays the creator.
///
///         **Three recipients, one rate to reason about.** The fees also pay the LP fund the
///         factory's live `graduatedLpFundShareBps`, and the protocol keeps whatever is left.
///         The fund's share is deliberately subtracted from the protocol's remainder and never
///         from the creator's share, and that is what makes it safe for the rate to be live:
///         raising it dilutes the protocol alone, so it can be applied to positions that
///         graduated before the fund existed without repricing a term any creator was sold.
///         All three legs credit `LaunchFeeEscrow`, where each party claims as they do for
///         curve fees.
///
///         **Recipients are read live from `LaunchFactory`, never stored here.** A creator who
///         hands their fee recipient over after graduation (`acceptCreatorFeeRecipient`) must
///         see the next `collect` pay the new address, and a protocol or fund recipient
///         rotation must reach every locked position at once.
///         `LockedPosition.creatorFeeRecipient` is the recipient at the moment of graduation,
///         kept for the record; the amount paid goes to whatever the factory says now.
contract LaunchLocker is Ownable2Step, ReentrancyGuard, ILaunchLocker {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice The `LaunchFactory` proxy: the source of the creator and protocol recipients
    ///         and of the escrow every collection is credited to.
    address public immutable factory;

    /// @notice The `LaunchGraduation` module, the only caller of `recordPosition` and
    ///         `lockTokenSupply`. Set once.
    address public graduation;

    mapping(address token => LockedPosition position) private _positions;

    /// @inheritdoc ILaunchLocker
    mapping(address token => uint256 amount) public lockedSupply;

    event GraduationSet(address graduation);
    event PositionLocked(address indexed token, uint256 indexed tokenId, address distributor);
    event SupplyLocked(address indexed token, uint256 amount);
    /// @param unitFeesToCreator   The creator's share of the position's swap fees in the brand
    /// @param unitFeesToProtocol  The protocol's share of the same
    /// @param unitToLpFund        The LP fund's share of the same
    /// @param tokenToLpFund       The LP fund's share of the swap fees in the launch token
    event Collected(
        address indexed token,
        uint256 unitFeesToCreator,
        uint256 unitFeesToProtocol,
        uint256 tokenToCreator,
        uint256 tokenToProtocol,
        uint256 unitToLpFund,
        uint256 tokenToLpFund
    );

    error OnlyGraduation();
    error AlreadyInitialized();
    error ZeroAddress();
    error PositionAlreadyLocked(address token);
    error PositionNotStaked(uint256 tokenId);
    error NotLocked(address token);
    error ShareTooHigh(uint16 bps);
    error OwnershipCannotBeRenounced();

    modifier onlyGraduation() {
        if (msg.sender != graduation) revert OnlyGraduation();
        _;
    }

    /// @param initialOwner Wires `graduation` once; nothing else is owner-gated.
    /// @param factory_     The `LaunchFactory` proxy.
    constructor(address initialOwner, address factory_) Ownable(initialOwner) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @notice One-time wiring of the graduation module, set after both are deployed.
    function setGraduation(address graduation_) external onlyOwner {
        if (graduation != address(0)) revert AlreadyInitialized();
        if (graduation_ == address(0)) revert ZeroAddress();
        graduation = graduation_;
        emit GraduationSet(graduation_);
    }

    /// @notice Permanently disabled. Ownership here exists only to perform the one-time
    ///         graduation wiring, and renouncing before that wiring would leave the locker
    ///         unable to ever accept a graduated position.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    /// @inheritdoc ILaunchLocker
    /// @dev The custody check is on the distributor's own ledger rather than on `ownerOf`:
    ///      the NFT is meant to be held by the distributor, and what makes it this locker's
    ///      is that the distributor names this contract as its staker.
    function recordPosition(address token, LockedPosition calldata position)
        external
        onlyGraduation
    {
        if (
            token == address(0) || position.distributor == address(0) || position.unit == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_positions[token].exists) revert PositionAlreadyLocked(token);
        if (position.creatorShareBps > BPS_DENOMINATOR) {
            revert ShareTooHigh(position.creatorShareBps);
        }
        if (LpRewardDistributor(position.distributor).stakerOf(position.tokenId) != address(this)) {
            revert PositionNotStaked(position.tokenId);
        }

        // The position stays staked — the distributor holds the NFT, and `collectFees` is how
        // the creator is paid — but it gives up the reward stream that rides alongside it.
        // Idempotent, and one-way: a second graduation into the same market finds this locker
        // already renounced. See `LpRewardDistributor.renounceRewards`.
        LpRewardDistributor(position.distributor).renounceRewards();

        _positions[token] = LockedPosition({
            tokenId: position.tokenId,
            distributor: position.distributor,
            unit: position.unit,
            creatorFeeRecipient: position.creatorFeeRecipient,
            creatorShareBps: position.creatorShareBps,
            exists: true
        });
        emit PositionLocked(token, position.tokenId, position.distributor);
    }

    /// @inheritdoc ILaunchLocker
    /// @dev Measured on arrival, so the ledger never claims more than the balance backs.
    function lockTokenSupply(address token, uint256 amount) external onlyGraduation {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;

        lockedSupply[token] += received;
        emit SupplyLocked(token, received);
    }

    // ─── Income ──────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchLocker
    /// @dev Both legs are measured as balance deltas rather than taken from return values:
    ///      `collectFees` returns nothing, and the token side of a market is whatever the
    ///      launch minted. The token delta is separated from the locked supply by the same
    ///      measurement — what is paid out is only what arrived in this call, so the balance
    ///      never drops below `lockedSupply`.
    ///
    ///      There is no second read between two pulls any more, because there is only one
    ///      pull. The reward stream this position used to claim was renounced when it was
    ///      recorded, so everything that arrives here is swap fees and the two streams no
    ///      longer have to be told apart. The distributor's own guard still applies: a paused
    ///      protocol pauses `collect` too.
    function collect(address token)
        external
        nonReentrant
        returns (uint256 unitOut, uint256 tokenOut)
    {
        LockedPosition memory p = _positions[token];
        if (!p.exists) revert NotLocked(token);

        uint256 unitBefore = IERC20(p.unit).balanceOf(address(this));
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));

        LpRewardDistributor(p.distributor).collectFees(p.tokenId);

        unitOut = IERC20(p.unit).balanceOf(address(this)) - unitBefore;
        tokenOut = IERC20(token).balanceOf(address(this)) - tokenBefore;

        address creator = ILaunchFactory(factory).creatorFeeRecipientOf(token);
        address protocol = ILaunchFeePolicy(factory).protocolFeeRecipient();
        if (creator == address(0) || protocol == address(0)) revert ZeroAddress();
        ILaunchFeeEscrow escrow = ILaunchFeePolicy(factory).feeEscrow();

        // Bounded by the factory's setters. Checked anyway, because the factory is a proxy and
        // an out-of-range rate here would pay one recipient out of another's leg.
        uint16 lpFundShareBps = ILaunchFactory(factory).graduatedLpFundShareBps();
        if (uint256(p.creatorShareBps) + lpFundShareBps > BPS_DENOMINATOR) {
            revert ShareTooHigh(lpFundShareBps);
        }
        // Only resolved when it is actually owed something, so a position whose launch
        // predates the fund keeps collecting while the leg is switched off.
        address lpFund;
        if (lpFundShareBps != 0) {
            lpFund = ILaunchFeePolicy(factory).lpFundRecipient();
            if (lpFund == address(0)) revert ZeroAddress();
        }

        // The creator's share is the rate their launch was sold on; the fund's is live and is
        // subtracted from what would otherwise all be the protocol's, so moving it can never
        // reprice the creator.
        uint256 unitToCreator = unitOut * p.creatorShareBps / BPS_DENOMINATOR;
        uint256 unitToLpFund = unitOut * lpFundShareBps / BPS_DENOMINATOR;
        uint256 tokenToCreator = tokenOut * p.creatorShareBps / BPS_DENOMINATOR;
        uint256 tokenToLpFund = tokenOut * lpFundShareBps / BPS_DENOMINATOR;

        // The protocol takes the remainder on every asset, so each asset's credits sum to
        // exactly what arrived and the rounding dust is never stranded here.
        _credit(escrow, creator, p.unit, unitToCreator);
        _credit(escrow, lpFund, p.unit, unitToLpFund);
        _credit(escrow, protocol, p.unit, unitOut - unitToCreator - unitToLpFund);
        _credit(escrow, creator, token, tokenToCreator);
        _credit(escrow, lpFund, token, tokenToLpFund);
        _credit(escrow, protocol, token, tokenOut - tokenToCreator - tokenToLpFund);

        emit Collected(
            token,
            unitToCreator,
            unitOut - unitToCreator - unitToLpFund,
            tokenToCreator,
            tokenOut - tokenToCreator - tokenToLpFund,
            unitToLpFund,
            tokenToLpFund
        );
    }

    /// @dev `creditToken` pulls from its caller, so the allowance is exactly the amount and
    ///      lives exactly as long as the call. Nothing standing is ever granted over a balance
    ///      that also holds locked supply.
    function _credit(ILaunchFeeEscrow escrow, address recipient, address asset, uint256 amount)
        private
    {
        if (amount == 0) return;
        IERC20(asset).forceApprove(address(escrow), amount);
        escrow.creditToken(recipient, asset, amount);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchLocker
    function lockedPosition(address token) external view returns (LockedPosition memory) {
        return _positions[token];
    }
}
