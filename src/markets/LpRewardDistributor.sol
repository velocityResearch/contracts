// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {IPoolOracle} from "./IPoolOracle.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";

/// @dev The one thing `configAdmin` needs from the shared guard that `IProtocolGuard` does not
///      declare. `ProtocolGuard` is `Ownable2Step` and its owner is the protocol timelock, so
///      this is a read of an address that already exists rather than a new power. Declared
///      here, and as narrowly as possible, for the reason `IProtocolGuard` itself gives: a
///      market contract should not carry the registry's code to ask it one question.
interface IGuardOwner {
    function owner() external view returns (address);
}

/// @title LpRewardDistributor
/// @notice A market's float yield, streamed to the people who actually provide its liquidity,
///         weighted by the capital they committed and for how long. One per market.
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
///         **Any range may stake, weighted by the capital it holds.** The float being
///         distributed is earned on the pool's stable balance, so what a position is paid for
///         is the money it actually has in the pool, not the `liquidity` number attached to
///         it — a narrow band buys an enormous `liquidity` cheaply, and the two figures are
///         only comparable between positions of the same width.
///
///         A stake's weight is therefore everything the position holds, valued in
///         `currency1`: the `amount1` its range holds below the price, plus the `amount0` it
///         holds above, converted at that same price. Equal money is equal weight whatever
///         the shape of the range, which is the property the float is owed to.
///
///         **The price behind that is the hook's thirty-minute mean, not spot.** A weight is
///         money, and spot is one swap away from whatever a staker would like it to be.
///         `ProtocolFeeHook` keeps the observations v4 core deleted, and this reads them
///         through `IPoolOracle`; a market whose hook keeps no history, or whose buffer does
///         not reach back far enough yet, falls back to the pool's spot price and records
///         which it used in the stake event rather than hiding it.
///
///         The weight is settled once, at stake time, and cached. The bounds of a position
///         this contract holds cannot change, and pricing it once means no later price move
///         can be traded against the reward ledger. The cost is the other side of that coin:
///         a stake's weight does not follow the market afterwards. It is a snapshot of what
///         the position was worth when it was committed.
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
    using StateLibrary for IPoolManager;

    /// @dev v4-periphery action ids, copied from `lib/v4-periphery/src/libraries/Actions.sol`
    ///      for the reason `IPositionManagerV4` is hand-written: that file lives in a checkout
    ///      with its own copy of v4-core. They are part of `PositionManager`'s ABI.
    uint8 private constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 private constant ACTION_TAKE_PAIR = 0x11;

    /// @dev Bit offsets of the two ticks inside v4-periphery's packed `PositionInfo`. Same
    ///      constants its own library uses.
    uint8 private constant TICK_LOWER_OFFSET = 8;
    uint8 private constant TICK_UPPER_OFFSET = 32;

    /// @dev Fixed-point scale for the reward accumulator, and the scale the full-range-only
    ///      version of this contract used before it.
    ///
    ///      The reward token is the market's brand — six decimals against weights that are
    ///      `currency1` amounts, which in an eighteen-decimal pair run past 1e22 — so the
    ///      per-weight rate is a very small number and needs more headroom than 1e18 leaves.
    ///      `PRECISION_SHIFT` is what the scale grew by, and the one-time conversion in
    ///      `_activateWeights` moves `rewardRate` by exactly the same factor, so tokens per
    ///      second (`rewardRate / PRECISION`) is the same integer on both sides of an upgrade
    ///      and an in-flight period keeps paying what it promised. Reward earned before that
    ///      conversion is settled against `LEGACY_PRECISION` by `earned`, which never mixes
    ///      the two scales inside one subtraction.
    uint256 private constant LEGACY_PRECISION = 1e18;
    uint8 private constant PRECISION_SHIFT = 64;
    uint256 private constant PRECISION = LEGACY_PRECISION << PRECISION_SHIFT;

    /// @dev The fixed-point one a `sqrtPriceX96` is quoted against.
    uint256 private constant Q96 = 2 ** 96;

    /// @dev How far back a stake is priced. Long enough that moving the mean costs half an
    ///      hour of holding the pool away from its market, short enough that an honest staker
    ///      is weighed at something close to today's price.
    uint32 private constant TWAP_WINDOW = 1800;

    /// @notice What fraction of a renounced stream's weight becomes this market's admission
    ///         floor, as a divisor: one basis point.
    ///
    ///         Small enough that it is noise against any stake worth making, and large enough
    ///         that a position cannot hold a rounding error's worth of capital and command the
    ///         whole of a stream the renounced capital is earning.
    ///
    ///         A constant rather than a setting, so that the number a renunciation measures is
    ///         never anybody's choice. `setMinStakeWeight` can move the result afterwards, for
    ///         the reason stated there.
    uint256 public constant RENOUNCED_FLOOR_DIVISOR = 10_000;

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

    /// @notice The stream's divisor: the exact sum of the per-position weights `stake`
    ///         credited to every account that has not renounced. Not a record of what this
    ///         contract holds — a renounced account's positions are still custodied, still
    ///         weighed in `stakedWeightOf` and still counted in `totalStakedLiquidity`, they
    ///         simply do not divide the stream. See `renounceRewards`.
    uint256 public totalStaked;

    /// @notice Raw liquidity staked per account. Liquidity rather than weight because it is
    ///         what an application shows an LP about their own position; the figure the reward
    ///         stream divides by is `stakedWeightOf`.
    mapping(address account => uint256 liquidity) public stakedLiquidityOf;
    mapping(address account => uint256 checkpoint) public rewardPerTokenPaid;
    mapping(address account => uint256 amount) public rewards;

    /// @notice Who a staked position belongs to. Zero means "not staked here".
    mapping(uint256 tokenId => address account) public stakerOf;

    /// @dev The raw liquidity credited for one position, so an exit removes exactly what the
    ///      stake added even if the position's own liquidity has changed in between — which it
    ///      cannot while this contract holds it, but the accounting should not depend on that
    ///      being true forever.
    mapping(uint256 tokenId => uint128 liquidity) public stakedLiquidityOfPosition;

    /// @dev Positions per account, with each id's index, so a withdrawal is O(1).
    mapping(address account => uint256[] tokenIds) private _positionsOf;
    mapping(uint256 tokenId => uint256 index) private _positionIndex;

    // ─── Appended by the renounced stream and its admission floor ────────
    //
    // Three slots, appended after everything above. Nothing a live market already wrote has
    // moved.

    /// @notice Accounts that have permanently given up their share of the reward stream.
    ///
    ///         There is one: a graduated launch's locked position. It has to stay staked,
    ///         because the distributor custodies the NFT and `collectFees` is how the launch's
    ///         creator is paid, but nobody owns it and nobody withdrew capital to fund it —
    ///         so paying it float yield would take that yield away from the liquidity
    ///         providers who did. See `renounceRewards`.
    mapping(address account => bool renounced) public rewardsRenounced;

    /// @notice The smallest stake `stake` admits from an account that has not renounced, in
    ///         the capital-weight units the stream is divided by (`weightForPosition`).
    ///
    ///         Weight rather than raw liquidity, because liquidity is the one figure a staker
    ///         can inflate for free: a band one spacing wide buys an enormous `liquidity` for
    ///         almost no capital, and a floor measured in it would admit exactly the dust
    ///         stake it exists to refuse. Weight is money, and money is what the seed gave up.
    ///
    ///         **Zero until the market's seed renounces, which is every market that never
    ///         graduated.** An ordinary market admits what it always did — any position
    ///         carrying weight at all — so an honest small LP is never locked out of one
    ///         market by a rule that exists for a different one.
    ///
    ///         Written in exactly two places: once and only once by `renounceRewards`, under
    ///         the conditions documented there, and by `setMinStakeWeight` in either
    ///         direction. See `renounceRewards` for where the number comes from and why the
    ///         one-shot is what makes it unforgeable.
    uint256 public minStakeWeight;

    /// @dev Whether a renunciation has already measured this market's floor. An explicit flag
    ///      rather than `minStakeWeight != 0`, because a market that never graduated has a
    ///      zero floor forever and would otherwise stay open to one free measurement by
    ///      anybody — and because `setMinStakeWeight(0)` must not re-arm the ratchet.
    bool private _floorSet;

    // ─── Appended by the weighted-stake version ──────────────────────────
    //
    // Five slots, appended below the three above, with `__gap` cut from 40 to 32 in total.
    // Nothing a live market already wrote has moved.

    /// @dev Staked weight, per account and per position. Zero against a live stake means the
    ///      stake predates weighting and is still recorded as raw liquidity; `stakedWeightOf`
    ///      and `stakedWeightOfPosition` convert that case rather than reporting nothing.
    mapping(address account => uint256 weight) private _stakedWeight;
    mapping(uint256 tokenId => uint256 weight) private _stakedWeightOfPosition;

    /// @notice When this distributor started measuring stakes as capital, and the price it
    ///         converted the stakes it was already holding at. Both are set in `initialize`
    ///         on a market deployed with this version, which has nothing to convert, and on
    ///         the first state change after an upgrade on one that has.
    uint64 public weightsActivatedAt;
    uint160 public legacySqrtPriceX96;

    /// @notice The accumulator reading at that conversion: the boundary between reward earned
    ///         on raw liquidity and reward earned on capital weight.
    uint256 public weightEpoch;

    /// @notice Raw liquidity staked across every position held here, renounced or not.
    ///         Exact — liquidity adds and subtracts without rounding, which weight cannot
    ///         promise across the one-time conversion — so it is what says whether the book
    ///         is empty, and an empty book carries no weight at all.
    uint256 public totalStakedLiquidity;

    /// @dev Room for later versions to add state without disturbing a live market's layout.
    uint256[32] private __gap;

    // ─── Events ──────────────────────────────────────────────────────────

    event Staked(address indexed account, uint256 indexed tokenId, uint128 liquidity);
    event Unstaked(address indexed account, uint256 indexed tokenId, uint128 liquidity);

    /// @notice What `stake` weighed a position at, everything it weighed it from, and whether
    ///         the price behind it was the hook's mean or the pool's spot.
    event StakeWeighted(
        address indexed account,
        uint256 indexed tokenId,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint256 weight,
        uint160 sqrtPriceX96,
        bool fromTwap
    );

    /// @notice A distributor holding stakes from the full-range-only version converted them:
    ///         the liquidity it held, the weight that became, and the price it used.
    event WeightsActivated(
        uint256 rawLiquidity, uint256 totalWeight, uint160 sqrtPriceX96, bool fromTwap
    );

    /// @notice An account gave up its share of the stream, and the staked weight it took out
    ///         of the divisor with it.
    event RewardsRenounced(address indexed account, uint256 weightGivenUp);

    /// @notice The market's seed renounced and measured this market's admission floor. At most
    ///         once per market, and only when the measurement actually raises the floor.
    event MinStakeWeightRaised(uint256 minStakeWeight);

    /// @notice `configAdmin` moved the admission floor, in either direction.
    event MinStakeWeightSet(uint256 minStakeWeight);
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
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error ZeroWeight(uint256 tokenId);
    error WeightOverflow();
    error PriceUnavailable();
    error NoLiquidity();
    error PositionNotReceived();
    error RewardTokenNotBrand(address token);
    error BrandNotInReserve(address token);
    error InsufficientRewardBalance(uint256 held, uint256 owed);
    error PositionsAreStaked();
    error ZeroDuration();
    error NotConfigAdmin();
    error StakeBelowFloor(uint256 weight, uint256 minStakeWeight);

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

        // A market deployed with this version starts weighted; only a proxy upgraded from the
        // full-range-only version has raw-liquidity stakes left to convert.
        weightsActivatedAt = uint64(block.timestamp);
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

    /// @notice The widest range this pool's spacing admits. No longer an admission rule — any
    ///         range may stake — but it is the range the routers seed a market with.
    function fullRange() public view returns (int24 tickLower, int24 tickUpper) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @notice The reward positions staked here have earned that has not been claimed.
    ///
    ///         Two segments on a distributor that was upgraded in place: whatever accrued
    ///         under the full-range-only version, measured in raw liquidity against the 1e18
    ///         scale that version used, and everything since, measured in capital weight
    ///         against `PRECISION`. `weightEpoch` is the accumulator reading where one ends
    ///         and the other begins, so neither segment is ever recomputed on the other's
    ///         basis and nothing is counted twice.
    function earned(address account) public view returns (uint256) {
        // A renounced account keeps what it had already earned and accrues nothing more. It
        // has to be out of the numerator because `renounceRewards` took it out of the
        // divisor: leaving it here would pay it a share of a stream it no longer counts
        // towards, and `notifyReward` would promise more than the contract holds.
        if (rewardsRenounced[account]) return rewards[account];

        uint256 accumulator = _rewardPerToken();
        uint256 paid = rewardPerTokenPaid[account];
        uint256 total = rewards[account];

        if (weightsActivatedAt == 0) {
            // Upgraded and not yet touched: what this contract holds is still raw liquidity,
            // and this reads it the way the version that wrote it did.
            return total + stakedLiquidityOf[account] * (accumulator - paid) / LEGACY_PRECISION;
        }

        uint256 epoch = weightEpoch;
        if (paid < epoch) {
            total += stakedLiquidityOf[account] * (epoch - paid) / LEGACY_PRECISION;
            paid = epoch;
        }

        return total + _weightOf(account) * (accumulator - paid) / PRECISION;
    }

    /// @notice The staked weight credited to `account`: what the reward stream divides by.
    function stakedWeightOf(address account) public view returns (uint256) {
        return _weightOf(account);
    }

    /// @notice The staked weight credited for one position.
    function stakedWeightOfPosition(uint256 tokenId) public view returns (uint256) {
        return _positionWeight(tokenId);
    }

    /// @notice The price a stake is weighed at: the hook's mean tick over `TWAP_WINDOW` if it
    ///         keeps one, and the pool's spot price if it cannot.
    ///
    ///         Moving the mean costs an attacker the whole window of holding the pool away
    ///         from its market; moving spot costs them one swap, which is why spot is only the
    ///         fallback. Without it a young market — a hook with an empty observation buffer —
    ///         would be unstakeable, which is worse than a stake priced at a spot somebody
    ///         paid to move: the flag in `StakeWeighted` says which happened.
    function stakeSqrtPrice() public view returns (uint160 sqrtPriceX96, bool fromTwap) {
        address hook = address(poolHooks);
        if (hook != address(0) && hook.code.length != 0) {
            try IPoolOracle(hook).consultTick(poolKey(), TWAP_WINDOW) returns (int24 meanTick) {
                // Range-checked rather than trusted: a hook answering with a tick v4 cannot
                // price would revert `TickMath` outside this `try`, where nothing catches it,
                // and take staking down with it.
                if (meanTick >= TickMath.MIN_TICK && meanTick <= TickMath.MAX_TICK) {
                    return (TickMath.getSqrtPriceAtTick(meanTick), true);
                }
            } catch {
                // No oracle, or not enough history for the window. Fall through to spot.
            }
        }

        (sqrtPriceX96,,,) = IPoolManager(positionManager.poolManager()).getSlot0(poolKey().toId());
        if (sqrtPriceX96 == 0) revert PriceUnavailable();
    }

    /// @notice What a position of this size and range would stake with, at today's price.
    function stakeWeightFor(uint128 liquidity, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,) = stakeSqrtPrice();
        return weightForPosition(liquidity, tickLower, tickUpper, sqrtPriceX96);
    }

    /// @notice The weight a position stakes with: everything it holds at `sqrtPriceX96`,
    ///         valued in `currency1`.
    ///
    ///         `amount1` is the part of the range below the price, `amount0` the part above,
    ///         and the second is converted at the same price rather than left in its own
    ///         token. Two positions holding the same money weigh the same however wide they
    ///         are, which raw `liquidity` cannot express.
    ///
    ///         Exact integer arithmetic throughout: v4's own `SqrtPriceMath` for the two
    ///         amounts, then two 512-bit `mulDiv`s for the conversion, because the square of a
    ///         `sqrtPriceX96` does not fit in a word. Every division floors, so a position is
    ///         never credited capital it does not hold.
    function weightForPosition(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96
    ) public pure returns (uint256) {
        if (tickUpper <= tickLower) revert InvalidTickRange(tickLower, tickUpper);
        if (sqrtPriceX96 == 0) revert PriceUnavailable();

        // Reverts on a tick outside v4's usable band, so a malformed range never reaches the
        // arithmetic below.
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint160 belowTop = sqrtPriceX96 < sqrtUpper ? sqrtPriceX96 : sqrtUpper;
        uint256 amount1 = belowTop > sqrtLower
            ? SqrtPriceMath.getAmount1Delta(sqrtLower, belowTop, liquidity, false)
            : 0;

        uint160 aboveFloor = sqrtPriceX96 > sqrtLower ? sqrtPriceX96 : sqrtLower;
        uint256 amount0 = sqrtUpper > aboveFloor
            ? SqrtPriceMath.getAmount0Delta(aboveFloor, sqrtUpper, liquidity, false)
            : 0;

        uint256 value0 = amount0 == 0
            ? 0
            : FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96);

        return amount1 + value0;
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

    /// @notice Stake a position of this market's pool and start earning the float.
    ///
    ///         The NFT is pulled from the caller, so `PositionManager.approve` (or
    ///         `setApprovalForAll`) must name this contract first. Anyone may stake on anyone's
    ///         behalf — the position comes out of the caller's own wallet either way — which is
    ///         what lets `MarketRouter.seedLiquidity` mint and stake in one transaction while
    ///         crediting the seeder.
    ///
    ///         Any range is admitted, and what it is worth is settled here, once: the capital
    ///         the position holds, at the hook's mean price rather than at a spot the staker
    ///         could have moved in the same block. That figure is cached against the token id,
    ///         and the position's bounds cannot change while this contract holds it.
    ///
    ///         **How small a stake is too small depends on what the market gave up.** The
    ///         position must weigh at least `minStakeWeight`, which is zero — the original
    ///         rule, any weight at all — in every market where nothing has renounced, and one
    ///         basis point of the weight the market's seed gave up where something has.
    ///         `renounceRewards` writes that number once and only from the holder of the
    ///         whole book; `setMinStakeWeight` can move it afterwards. A renounced account is
    ///         exempt: it takes no share of the stream whatever it stakes, so it can capture
    ///         nothing, and the locked position of a second graduation has to be admitted for
    ///         `collectFees` to reach it.
    ///
    /// @param beneficiary Who the stake, and the right to unstake it, belongs to.
    function stake(uint256 tokenId, address beneficiary) external whenNotPaused {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (stakerOf[tokenId] != address(0)) revert AlreadyStaked();

        int24 tickLower;
        int24 tickUpper;
        {
            (PoolKey memory key, uint256 info) = positionManager.getPoolAndPositionInfo(tokenId);

            // Compared as a `PoolKey`, never as the packed id inside `info`: that one is
            // truncated to 25 bytes and is only the periphery's own lookup key — see
            // `IPositionManagerV4`.
            if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey().toId())) revert WrongPool();

            tickLower = int24(uint24(info >> TICK_LOWER_OFFSET));
            tickUpper = int24(uint24(info >> TICK_UPPER_OFFSET));
        }

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert NoLiquidity();

        (uint160 sqrtPriceX96, bool fromTwap) = stakeSqrtPrice();
        uint256 weight = weightForPosition(liquidity, tickLower, tickUpper, sqrtPriceX96);
        // A position holding less than one whole unit of `currency1` would take custody and a
        // slot in the ledger for a stake the stream can never pay anything to.
        if (weight == 0) revert ZeroWeight(tokenId);

        // Skipped for a renounced account because the floor exists to stop a stake taking a
        // share of the stream out of proportion to the capital behind it, and a renounced
        // stake takes no share of it at all. Read once here and used again below, so a
        // position is admitted and booked under the same answer.
        bool renounced = rewardsRenounced[beneficiary];
        uint256 floor = minStakeWeight;
        if (!renounced && weight < floor) revert StakeBelowFloor(weight, floor);

        // Advance the accumulator before `totalStaked` grows, or this stake would dilute
        // rewards the existing stakers have already earned. It also settles and converts a
        // stake made before weighting, so the `+=` below lands on a converted figure.
        _updateReward(beneficiary);

        stakerOf[tokenId] = beneficiary;
        stakedLiquidityOfPosition[tokenId] = liquidity;
        _stakedWeightOfPosition[tokenId] = weight;
        _positionIndex[tokenId] = _positionsOf[beneficiary].length;
        _positionsOf[beneficiary].push(tokenId);

        // A renounced account is a staker in every respect but entitlement: its liquidity is
        // recorded, its position custodied and listed, and only the stream's divisor is left
        // alone. `unstake` reads the same flag, so liquidity that never entered `totalStaked`
        // is never taken back out of it.
        stakedLiquidityOf[beneficiary] += liquidity;
        totalStakedLiquidity += liquidity;
        _stakedWeight[beneficiary] += weight;
        if (!renounced) totalStaked += weight;

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        // Measured rather than assumed: the position side of a market is Uniswap's contract on
        // mainnet and a stand-in in the offline suite, and a "transfer" that moved nothing
        // would otherwise credit a stake this contract does not hold.
        if (positionManager.ownerOf(tokenId) != address(this)) revert PositionNotReceived();

        emit Staked(beneficiary, tokenId, liquidity);
        emit StakeWeighted(
            beneficiary, tokenId, liquidity, tickLower, tickUpper, weight, sqrtPriceX96, fromTwap
        );
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
        // Exactly what the stake added — the cached weight — or, for a position staked before
        // weighting, the same conversion `_updateReward` has just applied to the account's own
        // total. That conversion floors each figure separately, so the two subtractions
        // saturate rather than revert on a unit of rounding nobody earned.
        uint256 weight = _positionWeight(tokenId);

        stakedLiquidityOf[account] -= liquidity;
        totalStakedLiquidity -= liquidity;
        _stakedWeight[account] = _sub(_stakedWeight[account], weight);
        // The other half of the pairing `stake` sets up. A renounced account's weight is not
        // in `totalStaked` — `renounceRewards` removed whatever it held at that moment, and
        // nothing it staked afterwards was ever added — so subtracting here would under-count
        // the book and over-pay everyone still earning.
        if (!rewardsRenounced[account]) totalStaked = _sub(totalStaked, weight);

        delete stakerOf[tokenId];
        delete stakedLiquidityOfPosition[tokenId];
        delete _stakedWeightOfPosition[tokenId];
        _removePosition(account, tokenId);

        // An account with nothing staked holds no weight, and neither does an empty book.
        // The one-time conversion floors the total and each part separately, so a unit or two
        // can survive the last exit — and weight nobody holds would divide a stream nobody
        // could ever claim. Raw liquidity is exact, so it is what says the book is empty.
        if (_positionsOf[account].length == 0) _stakedWeight[account] = 0;
        if (totalStakedLiquidity == 0) totalStaked = 0;

        positionManager.transferFrom(address(this), account, tokenId);

        emit Unstaked(account, tokenId, liquidity);
    }

    /// @notice Permanently give up the caller's share of the reward stream.
    ///
    ///         **Self-service, because only the holder of a stream can give it away.** Routing
    ///         this through an admin would put a governance transaction in the middle of every
    ///         graduation, and would let governance switch off an LP's rewards, which is a
    ///         power nothing here should have.
    ///
    ///         What the caller keeps: custody of its positions, `unstake`, `collectFees`, and
    ///         its recorded `stakedLiquidityOf`. Those are gated on `stakerOf`, never on
    ///         entitlement — `collectFees` is how a graduated launch's creator is paid, so an
    ///         entitlement test there would strand the fees of the one account this exists
    ///         for. What it loses: its place in `totalStaked`, now and for every future
    ///         stake, so the stream divides among everyone else. Rewards already accrued are
    ///         settled first and stay claimable.
    ///
    ///         One-way on purpose. The locked position this exists for can never be unlocked,
    ///         so a way back would only be a way to quietly re-point a market's subsidy.
    ///
    ///         **The liquidity itself does not move, only the divisor.** `stake` adds nothing
    ///         to `totalStaked` for a renounced account and `unstake` takes nothing back out,
    ///         so what was never added is never subtracted twice — which is what keeps
    ///         `totalStaked` equal to the summed liquidity of exactly the accounts that have
    ///         not renounced, after any sequence of stakes and unstakes by either kind.
    ///
    ///         **A renunciation also sets this market's admission floor,** because it is the
    ///         one moment the market's own scale is measured rather than supplied. Taking a
    ///         large stake out of the divisor while its liquidity stays in the pool is exactly
    ///         the condition the liquidity × time rule was built to avoid: the float is still
    ///         earned on the balance the pool holds, but the stream now divides among whoever
    ///         else is staked — and at graduation that is nobody. Without a floor the first
    ///         account to stake one unit of liquidity would take the whole yield on the whole
    ///         raise, plus everything banked in `undistributed` while the book was empty,
    ///         until a real LP arrived to dilute them. Time cannot protect the split when
    ///         there is nothing to compete against; a floor under the numerator can.
    ///
    ///         One basis point of the liquidity given up, and **once per market**, under one
    ///         further condition: the renouncer must hold the whole of this distributor's
    ///         book. Both are what make the number unforgeable, and neither is optional.
    ///
    ///         Measuring it is not enough. `given` is real liquidity, but it is liquidity the
    ///         renouncer gets straight back: a renounced account's `unstake` is unconditional
    ///         and touches no divisor, so the position comes home in the same transaction.
    ///         `mint -> stake -> renounceRewards -> unstake -> burn` therefore costs an
    ///         attacker nothing but gas, and an open-ended ratchet would let them pin the
    ///         floor at one basis point of a briefly-posted balance ten thousand times the
    ///         market's real size — closing admission to every future LP, permanently, with
    ///         the float and the fee stream banking into `undistributed` and nobody able to
    ///         claim it.
    ///
    ///         The two conditions describe exactly one situation, which is the only one this
    ///         floor was ever for: `LaunchGraduation.graduate` creates the distributor, stakes
    ///         the seed to the locker, and has `LaunchLocker.recordPosition` call this in the
    ///         same transaction. The seed is therefore the whole book when it renounces —
    ///         nothing else can have staked yet — and no attacker can get to a distributor
    ///         that does not exist to spend the one shot first. In any market that already has
    ///         a liquidity provider the sole-staker test simply fails, so a live market cannot
    ///         be attacked at all, and a market that never graduates keeps a zero floor
    ///         forever.
    ///
    ///         `setMinStakeWeight` is the way back from a floor that is wrong; see there.
    function renounceRewards() external {
        if (rewardsRenounced[msg.sender]) return;

        // Settle first: whatever the caller earned while its weight still divided the
        // stream is credited to `rewards` and stays claimable. Only the future is given up.
        // This is also what makes the drop below invisible to everybody else — the interval
        // that ran at the old divisor is closed out at the old divisor. It also converts a
        // stake that predates weighting, so `given` below is in the divisor's own units.
        _updateReward(msg.sender);

        uint256 given = _weightOf(msg.sender);

        // Read before the subtraction, which takes the caller out of the very book it is
        // being compared against. `totalStaked` is the non-renounced book, so this asks
        // whether anyone still earning is staked here besides the caller.
        bool soleStaker = totalStaked == given;

        rewardsRenounced[msg.sender] = true;
        totalStaked = _sub(totalStaked, given);

        // The measurement, under all three guards at once:
        //
        //   - from capital that was actually held, so an account with nothing staked
        //     renounces an empty entitlement and moves nothing;
        //   - once per market, on an explicit flag rather than on `minStakeWeight == 0`,
        //     because a market that never graduated has a zero floor forever and would
        //     otherwise still owe anybody one free measurement;
        //   - and only from an account that holds the whole book, which is true of a
        //     graduation's seed by construction and false of every market that has an LP.
        //
        // The one shot is spent on the measurement, not on the write, so a caller who clears
        // all three cannot come back with a larger position afterwards. Still only upwards,
        // so it cannot undercut a floor `setMinStakeWeight` deliberately set higher.
        uint256 floor = given / RENOUNCED_FLOOR_DIVISOR;
        if (floor != 0 && !_floorSet && soleStaker) {
            _floorSet = true;
            if (floor > minStakeWeight) {
                minStakeWeight = floor;
                emit MinStakeWeightRaised(floor);
            }
        }

        emit RewardsRenounced(msg.sender, given);
    }

    /// @notice Who may move this market's admission floor: the protocol timelock, read live
    ///         off the shared guard.
    ///
    ///         A distributor has no admin of its own and should not gain one — a second
    ///         privileged address per market is a second key to lose, and there is no
    ///         per-market judgement to exercise here. The guard's owner already owns the
    ///         beacon every market's distributor is served from, so it could rewrite this
    ///         implementation wholesale; reading it is the same authority by a shorter route.
    function configAdmin() public view returns (address) {
        return IGuardOwner(address(guard())).owner();
    }

    /// @notice Move this market's admission floor, in either direction.
    ///
    ///         **Defence in depth over the one thing `renounceRewards` measures.** The floor
    ///         is written once, by the seed's own renunciation, off liquidity the renouncer
    ///         had already committed — so in the ordinary course nothing needs to move it.
    ///         This exists because the failure a missing setter leaves behind has no floor of
    ///         its own: a floor set too high, by a measurement mistake or by an abuse of the
    ///         one-shot in a market with no other staker to block it, closes admission
    ///         permanently and can otherwise only be undone by upgrading the shared beacon,
    ///         which moves every live market at once.
    ///
    ///         The objection this answers is that a floor an admin can move is a floor an
    ///         admin can use to choose a market's liquidity providers. That is true, and it is
    ///         a strictly weaker property than "anyone can close the market permanently for
    ///         the price of gas": the admin here is the protocol timelock that already owns
    ///         the beacon this implementation is served from, so it could already rewrite the
    ///         rule wholesale. A setter takes nothing from an LP that the beacon did not
    ///         already have, and it takes the permanent case away from everybody else.
    ///
    ///         **Admission only, so nothing staked is disturbed.** `stake` is the one place
    ///         the floor is read, so raising it cannot evict a position already in and
    ///         lowering it cannot dilute one; no settlement is needed for the same reason.
    ///
    /// @param newMinStakeWeight The new floor, in the liquidity units `stake` measures a
    ///                          position in. Zero restores the original rule, which admits
    ///                          any position carrying liquidity at all.
    function setMinStakeWeight(uint256 newMinStakeWeight) external {
        if (msg.sender != configAdmin()) revert NotConfigAdmin();

        minStakeWeight = newMinStakeWeight;

        emit MinStakeWeightSet(newMinStakeWeight);
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
                undistributed += (applicable - lastUpdateTime) * rewardRate / _precision();
            }
        } else {
            rewardPerTokenStored = _rewardPerToken();
        }

        lastUpdateTime = applicable;

        // After the accumulator has been advanced on the basis that wrote it, and before any
        // account is settled against it.
        _activateWeights();

        if (account != address(0)) {
            // Write down the converted weight of a stake that predates weighting, before
            // anything adds to or subtracts from it.
            uint256 weight = _weightOf(account);
            if (weight != _stakedWeight[account]) _stakedWeight[account] = weight;

            rewards[account] = earned(account);
            rewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /// @dev The one-time move off the full-range-only version's accounting.
    ///
    ///      That version weighted a stake by raw liquidity against a 1e18 rate scale. Two
    ///      things change here and nothing else:
    ///
    ///      - `rewardRate` is scaled by exactly the factor `PRECISION` grew by, so tokens per
    ///        second — `rewardRate / PRECISION` — is the same integer it was, and a period
    ///        already running finishes paying the amount it was notified with.
    ///      - `totalStaked` is re-measured as capital. Everything the previous version could
    ///        hold was full range, so one price and one call converts the whole book; the same
    ///        price is stored and converts each account and each position lazily, so no two
    ///        figures in the ledger are ever weighed differently.
    ///
    ///      Reward already earned is not touched. `weightEpoch` records the accumulator here,
    ///      and `earned` settles everything below it in raw liquidity against
    ///      `LEGACY_PRECISION` — the arithmetic the old version would have done — and
    ///      everything above it in capital against `PRECISION`.
    ///
    ///      `initialize` sets the flag, so a market deployed with this version never runs it.
    function _activateWeights() private {
        if (weightsActivatedAt != 0) return;

        weightEpoch = rewardPerTokenStored;

        uint256 rate = rewardRate;
        if (rate != 0) {
            if (rate > type(uint256).max >> PRECISION_SHIFT) revert WeightOverflow();
            rewardRate = rate << PRECISION_SHIFT;
        }

        uint256 rawLiquidity = totalStaked;
        uint160 sqrtPriceX96;
        bool fromTwap;
        if (rawLiquidity != 0) {
            if (rawLiquidity > type(uint128).max) revert WeightOverflow();
            (sqrtPriceX96, fromTwap) = stakeSqrtPrice();
            (int24 lower, int24 upper) = fullRange();
            legacySqrtPriceX96 = sqrtPriceX96;
            totalStaked = weightForPosition(uint128(rawLiquidity), lower, upper, sqrtPriceX96);
            // What the previous version called `totalStaked` was exactly this.
            totalStakedLiquidity = rawLiquidity;
        }

        weightsActivatedAt = uint64(block.timestamp);

        emit WeightsActivated(rawLiquidity, totalStaked, sqrtPriceX96, fromTwap);
    }

    /// @notice Reward-token base units streamed per second, unscaled.
    /// @dev `rewardRate` is carried at the accumulator's scale, which changed with weighting,
    ///      so a reader that formats the raw figure as money is wrong by that factor. This is
    ///      the figure to display. It is not available on a distributor that has not taken this
    ///      upgrade, so a reader must keep tolerating its absence until the upgrade is live.
    function rewardTokensPerSecond() external view returns (uint256) {
        return rewardRate / _precision();
    }

    /// @dev The accumulator scale in force: the old one until the conversion has run, so a
    ///      distributor upgraded mid-period banks an idle interval at the rate it holds.
    function _precision() private view returns (uint256) {
        return weightsActivatedAt == 0 ? LEGACY_PRECISION : PRECISION;
    }

    /// @dev An account's staked weight: the stored figure, or the raw liquidity a pre-weighting
    ///      version credited, converted. The two cannot be confused — a live stake always
    ///      carries a non-zero weight, so a zero here against staked liquidity is the old
    ///      shape and nothing else.
    function _weightOf(address account) private view returns (uint256) {
        uint256 stored = _stakedWeight[account];
        if (stored != 0) return stored;

        uint256 liquidity = stakedLiquidityOf[account];
        return liquidity == 0 ? 0 : _legacyWeight(liquidity);
    }

    function _positionWeight(uint256 tokenId) private view returns (uint256) {
        uint256 stored = _stakedWeightOfPosition[tokenId];
        if (stored != 0) return stored;

        uint256 liquidity = stakedLiquidityOfPosition[tokenId];
        return liquidity == 0 ? 0 : _legacyWeight(liquidity);
    }

    /// @dev Raw liquidity from the full-range-only version, weighed the only way those
    ///      positions can be: full range, at the price recorded when this distributor
    ///      converted. Frozen, so one stake never converts to two different numbers.
    function _legacyWeight(uint256 liquidity) private view returns (uint256) {
        if (liquidity > type(uint128).max) revert WeightOverflow();
        (int24 lower, int24 upper) = fullRange();
        return weightForPosition(uint128(liquidity), lower, upper, legacySqrtPriceX96);
    }

    /// @dev Subtraction that floors at zero. Only the one-time conversion can make a part
    ///      exceed the whole, by the unit each separately floored figure loses, and refusing
    ///      an exit over that unit would be the wrong answer to it.
    function _sub(uint256 from, uint256 amount) private pure returns (uint256) {
        return from > amount ? from - amount : 0;
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
