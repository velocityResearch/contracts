// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";

/// @title LpRewardDistributor
/// @notice A market's float yield, streamed to the people who actually provide its liquidity,
///         weighted by how much liquidity they held and for how long. One per market.
///
///         **Why a distributor exists at all, when `PoolManager.donate` is right there.** The
///         vault used to pay its LP share by donating to the pool, which credits
///         `feeGrowthGlobal` exactly as a swap fee does — no ledger, no claim surface, nothing
///         new to trust. That works while the LP share is a slice of the yield. It stops
///         working the moment the LP share is *all* of it: `sweep` is permissionless, so
///         anyone may add a large full-range position, sweep, and remove it in the same
///         transaction, taking almost the whole harvest for a position that carried risk for
///         zero seconds. Donation weights by liquidity at an instant, and an instant is exactly
///         what an attacker controls. This contract weights by liquidity × time, which they
///         cannot.
///
///         **The cost is custody.** A staked position's NFT is transferred here and held, and
///         that is a real trust surface — this contract can only be as safe as the beacon key
///         above it. Two properties bound the damage: `unstake` is not pausable and does not
///         depend on a reward transfer succeeding, so a halted protocol or a broken reward
///         leg never traps a position; and staking is optional, since an LP who wants nothing
///         to do with this keeps their NFT and still earns the pool's own swap fees.
///
///         The non-custodial alternative is v4-periphery's subscriber mechanism, which
///         notifies a subscriber of every liquidity change without moving the token. It is not
///         usable here yet: `subscribe` is `onlyIfApproved`, so a router cannot subscribe on a
///         seeder's behalf in the same transaction that mints their position without a separate
///         `setApprovalForAll`, and `transferFrom` silently unsubscribes — which would end a
///         stake with no notification this contract could see.
///
///         **Only full-range positions may stake.** A market's pool is seeded full-range by
///         `MarketRouter.seedLiquidity` and `LiquidityZapper`, and the float being distributed
///         is earned on the pool's whole stable-side balance rather than on any tick. Admitting
///         concentrated positions would mean paying a position that stops backing the market
///         the moment the price leaves its band, and paying it in proportion to a liquidity
///         number that is not comparable with a full-range one. A concentrated LP still earns
///         the pool's swap fees; they just do not share the float.
///
/// ## The stream
///
///         `notifyReward` takes what `BrandFeeVault.sweep` just sent and pays it out evenly
///         over `rewardsDuration`. Two departures from the usual Synthetix shape, both
///         deliberate:
///
///         - **A notify during a running period never moves `periodFinish`.** The reference
///           implementation restarts the clock on every notify, which lets anyone stretch the
///           tail indefinitely by donating dust to the vault and sweeping — and `sweep` is
///           permissionless by design, with a floor of one whole reserve unit. Here a notify
///           inside a live period folds the new amount into the remaining time at a higher
///           rate, so the caller's timing is worth nothing.
///         - **Time that passes with nothing staked accrues to nobody.** The reference
///           implementation would hand that interval's rewards to whoever stakes first, in the
///           block they stake, which is the same instant-weighted capture donation had. Those
///           rewards go to `undistributed` instead and are folded into the next notify.
///
/// ## Upgradeability and pausing
///
///         Upgradeable behind a beacon shared by every market's distributor, like the fee
///         vault, so a fix reaches all of them at once. `stake`, `claim` and `collectFees` stop
///         while the protocol is paused; `unstake` never does. `notifyReward` is not pausable
///         either, because its only caller is the vault's `sweep`, which is already guarded —
///         a second gate there could only make a harvest that already landed unpayable.
contract LpRewardDistributor is Initializable, GuardedUpgradeable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @dev v4-periphery action ids, copied from `lib/v4-periphery/src/libraries/Actions.sol`
    ///      for the reason `IPositionManagerV4` is hand-written: that file lives in a checkout
    ///      with its own copy of v4-core. They are part of `PositionManager`'s ABI.
    uint8 private constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 private constant ACTION_TAKE_PAIR = 0x11;

    /// @dev Bit offsets of the two ticks inside v4-periphery's packed `PositionInfo`. Same
    ///      constants its own library uses.
    uint8 private constant TICK_LOWER_OFFSET = 8;
    uint8 private constant TICK_UPPER_OFFSET = 32;

    /// @dev Fixed-point scale for the reward accumulator. The reward token is the market's
    ///      brand — six decimals against liquidity units that are routinely 1e12 and up — so
    ///      the per-liquidity rate is a very small number and needs the headroom.
    uint256 private constant PRECISION = 1e18;

    // ─── Wiring ──────────────────────────────────────────────────────────
    //
    // Storage rather than `immutable` throughout, for the reason `BrandFeeVault` gives: an
    // immutable lives in the implementation's bytecode, and every market's distributor
    // delegates into the same implementation behind the beacon. These are written once in
    // `initialize` and never again.

    /// @notice Uniswap's canonical v4 `PositionManager` — the contract that minted the staked
    ///         positions and the contract they are returned through.
    IPositionManagerV4 public positionManager;

    /// @notice The reserve this market's brands are pooled in. Used only to pay a claim in a
    ///         brand other than the reward token, 1:1 and free.
    SharedReservePool public reservePool;

    /// @notice The market unit: the brand token the pool holds, and what rewards are paid in.
    IERC20 public rewardToken;

    /// @notice The market's `BrandFeeVault`, the only address that may notify a reward.
    address public vault;

    // The market's `PoolKey`, field by field — the shape `BrandFeeVault` stores it in, and for
    // the same reason: the two `uint24`/`int24` members pack, which a struct in its own slot
    // would not.
    Currency public currency0;
    Currency public currency1;
    uint24 public poolFee;
    int24 public tickSpacing;
    IHooks public poolHooks;

    /// @notice How long one reward period runs for.
    uint32 public rewardsDuration;

    // ─── Stream ──────────────────────────────────────────────────────────

    /// @notice When the current reward period ends.
    uint256 public periodFinish;

    /// @notice Reward token per second, scaled by `PRECISION`.
    uint256 public rewardRate;

    /// @notice When the accumulator was last advanced.
    uint256 public lastUpdateTime;

    /// @notice Accumulated reward per unit of staked liquidity, scaled by `PRECISION`.
    uint256 public rewardPerTokenStored;

    /// @notice Reward that streamed while nothing was staked, waiting for the next notify.
    uint256 public undistributed;

    /// @notice Everything ever notified, and everything ever claimed. Their difference is what
    ///         this contract owes, and `notifyReward` refuses to promise more than it holds.
    uint256 public totalNotified;
    uint256 public totalClaimed;

    // ─── Stakes ──────────────────────────────────────────────────────────

    /// @notice Total staked liquidity across every position held here.
    uint256 public totalStaked;

    mapping(address account => uint256 liquidity) public stakedLiquidityOf;
    mapping(address account => uint256 checkpoint) public rewardPerTokenPaid;
    mapping(address account => uint256 amount) public rewards;

    /// @notice Who a staked position belongs to. Zero means "not staked here".
    mapping(uint256 tokenId => address account) public stakerOf;

    /// @dev The staked liquidity credited for one position, so `unstake` removes exactly what
    ///      `stake` added even if the position's own liquidity has changed in between — which
    ///      it cannot while this contract holds it, but the accounting should not depend on
    ///      that being true forever.
    mapping(uint256 tokenId => uint128 liquidity) public stakedLiquidityOfPosition;

    /// @dev Positions per account, with each id's index, so a withdrawal is O(1).
    mapping(address account => uint256[] tokenIds) private _positionsOf;
    mapping(uint256 tokenId => uint256 index) private _positionIndex;

    /// @dev Room for later versions to add state without disturbing a live market's layout.
    uint256[40] private __gap;

    // ─── Events ──────────────────────────────────────────────────────────

    event Staked(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event Unstaked(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event Claimed(address indexed account, address indexed paidIn, uint256 amount);
    event FeesCollected(address indexed account, uint256 indexed tokenId);
    event RewardNotified(uint256 amount, uint256 rate, uint256 periodFinish);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error OnlyVault();
    error OnlyStaker();
    error AlreadyStaked();
    error NotStaked();
    error WrongPool();
    error NotFullRange(int24 tickLower, int24 tickUpper);
    error NoLiquidity();
    error PositionNotReceived();
    error RewardTokenNotBrand(address token);
    error BrandNotInReserve(address token);
    error InsufficientRewardBalance(uint256 held, uint256 owed);
    error PositionsAreStaked();
    error ZeroDuration();

    constructor() {
        _disableInitializers();
    }

    /// @param _key      The market's pool. Positions from any other pool are refused.
    /// @param _vault    The market's `BrandFeeVault`.
    /// @param _duration How long one reward period runs for, in seconds.
    function initialize(
        IPositionManagerV4 _positionManager,
        SharedReservePool _reservePool,
        PoolKey memory _key,
        address _rewardToken,
        address _vault,
        uint32 _duration,
        address _guard
    ) external initializer {
        if (
            address(_positionManager) == address(0) || address(_reservePool) == address(0)
                || _rewardToken == address(0) || _vault == address(0)
        ) revert ZeroAddress();
        if (_duration == 0) revert ZeroDuration();

        __Guarded_init(_guard);

        // The reward token has to be a brand of this reserve, or `claim` could neither pay it
        // out in another brand nor be trusted to be a dollar at all.
        if (!_reservePool.isRegistered(_rewardToken)) revert RewardTokenNotBrand(_rewardToken);

        positionManager = _positionManager;
        reservePool = _reservePool;
        rewardToken = IERC20(_rewardToken);
        vault = _vault;
        rewardsDuration = _duration;

        currency0 = _key.currency0;
        currency1 = _key.currency1;
        poolFee = _key.fee;
        tickSpacing = _key.tickSpacing;
        poolHooks = _key.hooks;
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice The market's `PoolKey`, rebuilt from the five fields above.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: poolHooks
        });
    }

    /// @notice The only range this contract accepts: the widest the pool's spacing admits.
    function fullRange() public view returns (int24 tickLower, int24 tickUpper) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @notice The reward positions staked here have earned that has not been claimed.
    function earned(address account) public view returns (uint256) {
        uint256 delta = _rewardPerToken() - rewardPerTokenPaid[account];
        return rewards[account] + stakedLiquidityOf[account] * delta / PRECISION;
    }

    /// @notice The token ids `account` has staked.
    function positionsOf(address account) external view returns (uint256[] memory) {
        return _positionsOf[account];
    }

    function positionCountOf(address account) external view returns (uint256) {
        return _positionsOf[account].length;
    }

    /// @notice What this contract still owes: notified less claimed.
    function outstandingRewards() public view returns (uint256) {
        return totalNotified - totalClaimed;
    }

    // ─── Staking ─────────────────────────────────────────────────────────

    /// @notice Stake a full-range position of this market's pool and start earning the float.
    ///
    ///         The NFT is pulled from the caller, so `PositionManager.approve` (or
    ///         `setApprovalForAll`) must name this contract first. Anyone may stake on anyone's
    ///         behalf — the position comes out of the caller's own wallet either way — which is
    ///         what lets `MarketRouter.seedLiquidity` mint and stake in one transaction while
    ///         crediting the seeder.
    ///
    /// @param beneficiary Who the stake, and the right to unstake it, belongs to.
    function stake(uint256 tokenId, address beneficiary) external whenNotPaused {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (stakerOf[tokenId] != address(0)) revert AlreadyStaked();

        (PoolKey memory key, uint256 info) = positionManager.getPoolAndPositionInfo(tokenId);

        // Compared as a `PoolKey`, never as the packed id inside `info`: that one is truncated
        // to 25 bytes and is only the periphery's own lookup key — see `IPositionManagerV4`.
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey().toId())) revert WrongPool();

        int24 tickLower = int24(uint24(info >> TICK_LOWER_OFFSET));
        int24 tickUpper = int24(uint24(info >> TICK_UPPER_OFFSET));
        (int24 lowerWanted, int24 upperWanted) = fullRange();
        if (tickLower != lowerWanted || tickUpper != upperWanted) {
            revert NotFullRange(tickLower, tickUpper);
        }

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert NoLiquidity();

        // Advance the accumulator before `totalStaked` grows, or this stake would dilute
        // rewards the existing stakers have already earned.
        _updateReward(beneficiary);

        stakerOf[tokenId] = beneficiary;
        stakedLiquidityOfPosition[tokenId] = liquidity;
        _positionIndex[tokenId] = _positionsOf[beneficiary].length;
        _positionsOf[beneficiary].push(tokenId);

        stakedLiquidityOf[beneficiary] += liquidity;
        totalStaked += liquidity;

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        // Measured rather than assumed: the position side of a market is Uniswap's contract on
        // mainnet and a stand-in in the offline suite, and a "transfer" that moved nothing
        // would otherwise credit a stake this contract does not hold.
        if (positionManager.ownerOf(tokenId) != address(this)) revert PositionNotReceived();

        emit Staked(beneficiary, tokenId, liquidity);
    }

    /// @notice Take a staked position back.
    ///
    ///         **Never pausable, and never dependent on a reward being payable.** Accrued
    ///         rewards stay accrued and are collected separately with `claim`, so a paused
    ///         protocol, an empty reward balance or a paused reserve cannot keep an LP from
    ///         their own position.
    function unstake(uint256 tokenId) external {
        address account = stakerOf[tokenId];
        if (account == address(0)) revert NotStaked();
        if (msg.sender != account) revert OnlyStaker();

        _updateReward(account);

        uint128 liquidity = stakedLiquidityOfPosition[tokenId];
        stakedLiquidityOf[account] -= liquidity;
        totalStaked -= liquidity;

        delete stakerOf[tokenId];
        delete stakedLiquidityOfPosition[tokenId];
        _removePosition(account, tokenId);

        positionManager.transferFrom(address(this), account, tokenId);

        emit Unstaked(account, tokenId, liquidity);
    }

    /// @notice Collect a staked position's own swap fees without unstaking it.
    ///
    ///         `DECREASE_LIQUIDITY` by zero is how v4 says "settle what this position is owed":
    ///         it takes the position's accrued fees and touches its liquidity not at all, so
    ///         the stake weight is unchanged and the reward stream does not need a checkpoint.
    ///         `TAKE_PAIR` sends both currencies to the staker.
    ///
    ///         Fees arrive in the pool's own two tokens — the market unit and the market's
    ///         asset — not in the reward token. The unit is a 1:1 claim on the reserve like any
    ///         other brand, so converting it is `SharedReservePool.swap`, taken when the staker
    ///         chooses.
    function collectFees(uint256 tokenId) external whenNotPaused {
        address account = stakerOf[tokenId];
        if (account == address(0)) revert NotStaked();
        if (msg.sender != account) revert OnlyStaker();

        bytes memory actions =
            abi.encodePacked(uint8(ACTION_DECREASE_LIQUIDITY), uint8(ACTION_TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        // No minimum on either side: this decreases nothing, so there is no amount to be
        // short-changed on. The fees are whatever the pool owes the position.
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, account);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        emit FeesCollected(account, tokenId);
    }

    // ─── Rewards ─────────────────────────────────────────────────────────

    /// @notice Collect accrued rewards, paid in any brand of this market's reserve.
    ///
    ///         One transaction and one signature: the reward is the market unit, and a caller
    ///         who wants their own community's brand instead gets it through the reserve's
    ///         exact 1:1 swap on the way out. `brandOut` may be the unit itself, which skips
    ///         the swap — and is the only path that still works while the reserve is paused.
    ///
    /// @param brandOut The brand to be paid in. Must be registered in this market's reserve.
    function claim(address brandOut) external whenNotPaused returns (uint256 amount) {
        _updateReward(msg.sender);

        amount = rewards[msg.sender];
        if (amount == 0) revert ZeroAmount();

        rewards[msg.sender] = 0;
        totalClaimed += amount;

        if (brandOut == address(rewardToken)) {
            rewardToken.safeTransfer(msg.sender, amount);
        } else {
            // Rejected here rather than inside the reserve so the revert names the token. A
            // brand of another reserve group is not a 1:1 claim on this one — crossing groups
            // is a redemption and a mint, which is the holder's own decision to make and pay
            // for, exactly as `MarketRouter` treats it.
            if (!reservePool.isRegistered(brandOut)) revert BrandNotInReserve(brandOut);
            // Burns from this contract and mints to the claimant. No allowance is involved:
            // the reserve burns `msg.sender`'s own balance.
            reservePool.swap(address(rewardToken), brandOut, amount, msg.sender);
        }

        emit Claimed(msg.sender, brandOut, amount);
    }

    /// @notice Start streaming `amount` of reward token that the vault has just sent here.
    ///
    ///         Called by `BrandFeeVault.sweep` after the transfer, so the tokens are already
    ///         held when this runs. The solvency check is on the whole obligation rather than
    ///         on this amount: everything that arrives arrives through a notify and everything
    ///         that leaves leaves through a claim, so `totalNotified - totalClaimed` is exactly
    ///         what is owed, and this contract refuses to promise more than it holds.
    function notifyReward(uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        if (amount == 0) revert ZeroAmount();

        _updateReward(address(0));

        // Whatever streamed into an empty pool joins this round rather than being handed to
        // whoever stakes next — see the contract note on the stream.
        uint256 total = amount + undistributed;
        undistributed = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = total * PRECISION / rewardsDuration;
            periodFinish = block.timestamp + rewardsDuration;
        } else {
            // A notify inside a live period raises the rate for the time that is left and
            // leaves the end date alone, so nobody can stretch the tail by sweeping dust.
            uint256 remaining = periodFinish - block.timestamp;
            rewardRate = (total * PRECISION + rewardRate * remaining) / remaining;
        }

        lastUpdateTime = block.timestamp;
        totalNotified += amount;

        uint256 held = rewardToken.balanceOf(address(this));
        uint256 owed = outstandingRewards();
        if (held < owed) revert InsufficientRewardBalance(held, owed);

        emit RewardNotified(amount, rewardRate, periodFinish);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev The accumulator as of now, without writing it.
    function _rewardPerToken() private view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 elapsed = _lastApplicableTime() - lastUpdateTime;
        return rewardPerTokenStored + elapsed * rewardRate / totalStaked;
    }

    function _lastApplicableTime() private view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @dev Advance the global accumulator, then settle one account against it. Runs before
    ///      every change to `totalStaked`, to an account's stake, or to the rate.
    ///
    ///      `account` may be zero, which advances the global side only — what `notifyReward`
    ///      wants, since it belongs to no account.
    function _updateReward(address account) private {
        uint256 applicable = _lastApplicableTime();

        if (totalStaked == 0) {
            // Nothing to divide the stream between. Bank the interval instead of accumulating
            // it, so the first staker after an idle stretch cannot take it in one block.
            if (applicable > lastUpdateTime) {
                undistributed += (applicable - lastUpdateTime) * rewardRate / PRECISION;
            }
        } else {
            rewardPerTokenStored = _rewardPerToken();
        }

        lastUpdateTime = applicable;

        if (account != address(0)) {
            rewards[account] = earned(account);
            rewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _removePosition(address account, uint256 tokenId) private {
        uint256[] storage ids = _positionsOf[account];
        uint256 index = _positionIndex[tokenId];
        uint256 last = ids.length - 1;

        if (index != last) {
            uint256 moved = ids[last];
            ids[index] = moved;
            _positionIndex[moved] = index;
        }

        ids.pop();
        delete _positionIndex[tokenId];
    }

    /// @dev A position sent here with `safeTransferFrom` instead of `stake` would be held with
    ///      no owner recorded and no way out, so the transfer is refused outright. Staking is
    ///      `stake`, which pulls the token itself.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotStaked();
    }
}
