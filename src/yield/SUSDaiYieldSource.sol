// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {AcrossBridger} from "../susdai/AcrossBridger.sol";

/// @title SUSDaiYieldSource
/// @notice The Robinhood Chain half of an sUSDai-backed reserve. Plugs into `SharedReservePool`
///         as its `IYieldSource`, but the "yield source" is on another chain: USDG minted into
///         the pool is bridged to Arbitrum by Across, swapped into USD.AI's sUSDai on Curve
///         and held by `SUSDaiHub`; redemptions are paid from a USDG buffer this adapter keeps
///         here, which the keeper refills by selling shares and bridging USDC back.
///
///         **What the pool sees.** `balanceOf(USDG)` is the whole position in USDG units:
///
///             USDG held here + what the bridge will deliver to the hub + value held by the hub
///                            + USDC in flight back from the hub
///
///         Only the first term is a balance this chain can read. The other three are counters
///         the keeper maintains through `bridgeOut` and `sync`, and the pool's yield ledger
///         reacts to their sum exactly as it would to a Morpho position: a rising hub value is
///         yield, the bridge and swap costs booked by a sync are a loss recovered from later
///         yield, and the pool's redemption fee is what nets those costs out. An outbound leg
///         is marked at the quote's output rather than at what was escrowed, and an increase in
///         the local balance that no deposit or report accounts for is read as a leg arriving
///         rather than as new value — see `_position` for why both of those matter.
///
///         **Mint never touches the bridge.** `deposit` takes custody of USDG and stops; the
///         keeper batches it out later. So a mint can never fail on Across, Curve or Arbitrum,
///         and the pool's redemptions are paid from the local balance — synchronously, up to
///         whatever the buffer holds. `withdraw` returns what it can and never reverts on an
///         over-request, which is the `IYieldSource` contract the pool relies on; a redeemer
///         who insists on par-less-fee passes `minAssetsOut` and the pool reverts for them.
///
///         **What the keeper can and cannot do.** The keeper is a hot key, so it is boxed in:
///         `bridgeOut` can only send USDG to the hub, on the hub's chain, as USDC, at an Across
///         quote that clears `maxBridgeFeeBps`, and it must leave `minLocalBufferBps` of the
///         position here for redemptions. `sync` reports what the hub holds, and a report can
///         only raise `remoteValue` by what was bridged over plus `maxRemoteGrowthBpsPerDay`
///         since the last report — a stolen key cannot invent backing faster than that, and
///         inventing backing is the only lever a report has (it lets brand treasuries claim
///         yield that does not exist). Lowering the value is never restricted. Rotating the
///         key is the owner's, and the owner is the same timelock that owns the pool.
///
///         **Single consumer.** Bound to one pool with `bindController`, same one-shot pattern
///         as a single-consumer lending adapter would, because the position is one undivided USDG
///         balance here and
///         one undivided sUSDai balance there — there is no per-consumer share to attribute.
///
///         **Migration caveat.** `SharedReservePool.setYieldSource` recalls `balanceOf`, which
///         here includes value that is not on this chain; the adapter returns the local
///         balance and the rest stays owed. Migrate only after the keeper has sold and bridged
///         everything home (`outboundInFlight`, `inboundInFlight` and `remoteValue` all zero).
contract SUSDaiYieldSource is
    IYieldSource,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    GuardedUpgradeable,
    AcrossBridger
{
    using SafeERC20 for IERC20;

    /// @notice The hub's report of itself, applied atomically. Every field is one real-world
    ///         event so a partial picture can never be written:
    ///         - `remoteValue`     what the hub holds now (shares at conservative NAV + USDC),
    ///                             in USDG units, EXCLUDING anything it has bridged home.
    ///         - `outboundAcked`   USDG bridged out whose fill the hub has received.
    ///         - `outboundRefunded` USDG bridged out that Across refunded to this adapter.
    ///         - `inboundStarted`  USDC the hub just handed to Across for delivery here.
    ///         - `inboundLanded`   USDC previously started that has arrived here as USDG.
    ///         - `inboundRefunded` USDC previously started that Across refunded to the hub.
    struct SyncReport {
        uint256 remoteValue;
        uint256 outboundAcked;
        uint256 outboundRefunded;
        uint256 inboundStarted;
        uint256 inboundLanded;
        uint256 inboundRefunded;
    }

    // ─── Storage layout ──────────────────────────────────────────────────
    //
    // This adapter is upgraded in place, so the order below IS part of its interface: later
    // versions append, never reorder or remove. `AcrossBridger` sits in front of it and owns
    // the first ten slots; `Ownable2StepUpgradeable` and `GuardedUpgradeable` occupy none of
    // their own — both keep their fields at ERC-7201 namespaced slots.

    // ─── Wiring ──────────────────────────────────────────────────────────
    //
    // Written once by `initialize` and never by any other function. What stops a keeper or a
    // stranger from repointing the bridge is not immutability — it is that nothing but an
    // upgrade writes these, and only the owner can authorize an upgrade.

    IERC20 public usdg;
    /// @notice `SUSDaiHub` on `hubChainId`. The only address `bridgeOut` may deliver to.
    address public hub;
    /// @notice USDC on `hubChainId`. The only token `bridgeOut` may deliver.
    address public hubUsdc;
    uint256 public hubChainId;
    /// @notice The address that initialized this proxy, and the only one that may bind it.
    address public deployer;

    // ─── Roles ───────────────────────────────────────────────────────────

    /// @notice The sole consumer allowed to deposit/withdraw. Bound once; after that only an
    ///         upgrade can move it, which is the owner's call and nobody else's.
    address public controller;
    address public keeper;

    // ─── Position ────────────────────────────────────────────────────────

    /// @notice USDG handed to Across for the hub, not yet acknowledged received or refunded.
    uint256 public outboundInFlight;
    /// @notice USDC the hub handed to Across for this adapter, not yet landed or refunded.
    uint256 public inboundInFlight;
    /// @notice Keeper-reported value held by the hub, in USDG units.
    uint256 public remoteValue;
    uint64 public remoteValueUpdatedAt;

    // ─── Keeper limits (owner-set) ───────────────────────────────────────
    //
    // Defaults are applied by `initialize`, not by a declaration initializer: a value assigned
    // at the declaration is written by the implementation's constructor, which for a proxy runs
    // against the implementation's own storage and leaves the proxy on zero.

    /// @dev Packed with `remoteValueUpdatedAt` above; keep the three adjacent.
    uint16 public maxBridgeFeeBps;
    uint16 public minLocalBufferBps;
    uint16 public maxRemoteGrowthBpsPerDay;
    /// @notice Largest single outbound bridge. Zero disables new outbound deposits.
    uint256 public maxBridgeAmount;

    /// @notice Absolute USDG floor `bridgeOut` must leave here, applied alongside the bps one.
    ///         RSV-007: the bps floor is a share of `_position()`, which includes the
    ///         keeper-written `remoteValue`, so a keeper that reports a low value shrinks its
    ///         own floor and can then bridge out almost the whole redemption buffer. A token
    ///         figure cannot be moved by any report, and tokens are the units redemption demand
    ///         is denominated in. Zero leaves the bps floor alone; size this to real flow.
    uint256 public minLocalBufferAbsolute;

    /// @notice Floor under the per-day growth allowance in `sync`, in USDG.
    ///         RSV-003: the bps allowance is proportional to the PREVIOUS `remoteValue`, which
    ///         makes zero an absorbing state — once a report lands the value at zero, nothing
    ///         can ever raise it again and everything the hub holds is written off for good.
    ///         An absolute floor means there is always a way back out.
    uint256 public maxRemoteGrowthAbsolutePerDay;

    /// @notice Sum of `q.outputAmount` over outbound deposits not yet acknowledged or refunded.
    ///         RSV-008: `outboundInFlight` counts what was ESCROWED, and the hub only ever
    ///         receives the quote's output. Valuing the leg at its input overstates the position
    ///         by the bridge fee for the whole flight and hands a keeper exactly enough
    ///         allowance to report a value that never accounts for the fee — which defeats the
    ///         one thing `lossCarryforward` exists to do. The fee is a cost when it is incurred.
    uint256 public outboundExpected;

    /// @notice The local USDG balance this contract can account for: moved by `deposit`,
    ///         `withdraw`, `bridgeOut` and by the arrivals a `sync` reports. Anything above it
    ///         is an increase nobody has explained yet. See `_position`.
    uint256 public localAtLastSettlement;

    /// @notice Outbound notional `bridgeOut` may escrow per `bridgeWindow`.
    ///         RSV-004: `maxBridgeAmount` bounds ONE deposit and nothing bounded N of them, so
    ///         a stolen keeper key could push the entire buffer across in a single block. Zero
    ///         is the fail-closed default, exactly as for `maxBridgeAmount` — including for a
    ///         proxy upgraded from a version that predates this slot, which reads zero and
    ///         stops bridging loudly until the owner sets a budget.
    uint256 public bridgeBudgetPerWindow;
    /// @dev Packed with the two counters below; keep the three adjacent.
    uint64 public bridgeWindow;
    uint64 private _bridgeWindowStart;
    uint128 private _bridgedInWindow;

    /// @dev Room for later versions to add state without disturbing anything above. Shrunk
    ///      from 40 by the six slots appended above, so the total this contract occupies is
    ///      unchanged and nothing underneath a live proxy moved.
    uint256[34] private __gap;

    uint16 public constant MAX_BRIDGE_FEE_BPS = 100;
    /// @notice Longest `elapsed` one growth allowance may integrate over.
    ///         RSV-009: the allowance is linear in time since the last report and had no
    ///         ceiling, so a dormant deployment — the normal state of a testnet — accumulates
    ///         enough headroom to double `remoteValue` in one report. Real yield earned during
    ///         a longer outage is recognised over successive reports instead, which is the
    ///         whole point of a rate cap: value appears gradually and visibly.
    uint256 public constant MAX_GROWTH_WINDOW = 7 days;

    event ControllerBound(address indexed controller);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event LimitsUpdated(
        uint16 maxBridgeFeeBps, uint16 minLocalBufferBps, uint16 maxRemoteGrowthBpsPerDay
    );
    event MaxBridgeAmountUpdated(uint256 oldMaximum, uint256 newMaximum);
    event MinLocalBufferAbsoluteUpdated(uint256 oldFloor, uint256 newFloor);
    event RemoteGrowthAbsolutePerDayUpdated(uint256 oldFloor, uint256 newFloor);
    event BridgeBudgetUpdated(uint256 budget, uint64 window);
    event RemoteValueOverridden(uint256 oldValue, uint256 newValue);
    event InFlightReset(
        uint256 oldOutbound, uint256 newOutbound, uint256 oldInbound, uint256 newInbound
    );
    event LocalBaselineSeeded(uint256 oldBaseline, uint256 newBaseline);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 requested, uint256 paid);
    event BridgedOut(uint32 indexed depositId, uint256 amount, uint256 outputAmount);
    event Synced(
        uint256 remoteValue,
        uint256 outboundInFlight,
        uint256 inboundInFlight,
        uint256 outboundAcked,
        uint256 outboundRefunded,
        uint256 inboundStarted,
        uint256 inboundLanded,
        uint256 inboundRefunded
    );

    error NotController();
    error NotKeeper();
    error NotDeployer();
    error AlreadyBound();
    error UnsupportedAsset(address asset);
    error InsufficientLocalBalance(uint256 requested, uint256 available);
    error LocalBufferBreached(uint256 remaining, uint256 required);
    error RemoteValueAboveCap(uint256 reported, uint256 allowed);
    error LimitOutOfRange();
    error BridgeAmountAboveCap(uint256 amount, uint256 maximum);
    error BridgeBudgetExhausted(uint256 amount, uint256 remaining);
    error UnexpectedDecimals();
    error OwnershipCannotBeRenounced();

    constructor() {
        _disableInitializers();
    }

    /// @param _guard The protocol pause registry. See `ProtocolGuard`.
    /// @param _owner Owns the keeper rotation, the limits, and upgrades of this proxy.
    function initialize(
        address _usdg,
        address _spokePool,
        uint256 _hubChainId,
        address _hub,
        address _hubUsdc,
        address _guard,
        address _owner,
        address _keeper
    ) external initializer {
        if (
            _usdg == address(0) || _hub == address(0) || _hubUsdc == address(0)
                || _guard == address(0) || _keeper == address(0)
        ) revert ZeroAddress();
        // RSV-010: `AcrossBridger`'s fee floor is a plain subtraction on the input amount
        // compared against an output amount denominated in the destination token, so it is only
        // a bound at all while both sides share decimals. Asserted here, where the pair is
        // bound, mirroring the check `SUSDaiHub.initialize` already performs on its own pair.
        if (IERC20Metadata(_usdg).decimals() != 6) revert UnexpectedDecimals();

        __AcrossBridger_init(_spokePool);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Guarded_init(_guard);

        usdg = IERC20(_usdg);
        hubChainId = _hubChainId;
        hub = _hub;
        hubUsdc = _hubUsdc;
        // The caller of `initialize`, not of the implementation's constructor: behind a proxy
        // those are different transactions and only this one knows the deployment it belongs to.
        deployer = msg.sender;
        keeper = _keeper;
        maxBridgeFeeBps = 20;
        minLocalBufferBps = 1_000;
        maxRemoteGrowthBpsPerDay = 50;
        // RSV-003's floor: immaterial next to any real position, but enough that a value
        // reported at zero is not permanently unrecognisable.
        maxRemoteGrowthAbsolutePerDay = 10e6;
        // RSV-004's budget. Half the reserve's configured liability cap per day sits far above
        // the keeper's real duty cycle — a few hundred USDG of buffer rebalancing — and far
        // below "the whole position in one block", which is what it exists to prevent.
        bridgeBudgetPerWindow = 50_000e6;
        bridgeWindow = 1 days;
        emit KeeperUpdated(address(0), _keeper);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Roles ───────────────────────────────────────────────────────────

    /// @notice Bind this adapter to its single consumer. Callable once, by the deployer or by
    ///         the owner, so a fresh adapter cannot be claimed by a stranger watching the
    ///         mempool.
    /// @dev UUPS-002: `deployer` is the initializer's caller, which behind a proxy is whoever
    ///      executed `new ERC1967Proxy(...)`. If that is ever a contract which does not bind in
    ///      the same transaction — a factory, a Safe module, a script run without broadcast —
    ///      a deployer-only check leaves the adapter permanently inert with nothing but an
    ///      upgrade to rescue it. Admitting the owner widens who can COMPLETE the binding, not
    ///      what it can become: it is still one-shot, and the owner already controls the code.
    function bindController(address _controller) external {
        if (msg.sender != deployer && msg.sender != owner()) revert NotDeployer();
        if (controller != address(0)) revert AlreadyBound();
        if (_controller == address(0)) revert ZeroAddress();
        controller = _controller;
        emit ControllerBound(_controller);
    }

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, _keeper);
        keeper = _keeper;
    }

    /// @param _maxBridgeFeeBps         Floor on an Across quote's output, as a fee. <= 1%.
    /// @param _minLocalBufferBps       Share of the position `bridgeOut` must leave here.
    /// @param _maxRemoteGrowthBpsPerDay Most a `sync` may raise `remoteValue` per day, beyond
    ///                                  what was bridged over. Size it to the collateral's
    ///                                  yield with headroom, not to zero: a cap the honest
    ///                                  keeper trips is a cap the owner will loosen blindly.
    function setLimits(
        uint16 _maxBridgeFeeBps,
        uint16 _minLocalBufferBps,
        uint16 _maxRemoteGrowthBpsPerDay
    ) external onlyOwner {
        if (
            _maxBridgeFeeBps > MAX_BRIDGE_FEE_BPS || _minLocalBufferBps > BPS
                || _maxRemoteGrowthBpsPerDay > BPS
        ) revert LimitOutOfRange();
        maxBridgeFeeBps = _maxBridgeFeeBps;
        minLocalBufferBps = _minLocalBufferBps;
        maxRemoteGrowthBpsPerDay = _maxRemoteGrowthBpsPerDay;
        emit LimitsUpdated(_maxBridgeFeeBps, _minLocalBufferBps, _maxRemoteGrowthBpsPerDay);
    }

    /// @notice Set the absolute single-deposit ceiling. Zero is the fail-closed default.
    function setMaxBridgeAmount(uint256 newMaximum) external onlyOwner {
        emit MaxBridgeAmountUpdated(maxBridgeAmount, newMaximum);
        maxBridgeAmount = newMaximum;
    }

    /// @notice Set the absolute local-buffer floor. See `minLocalBufferAbsolute`.
    function setMinLocalBufferAbsolute(uint256 newFloor) external onlyOwner {
        emit MinLocalBufferAbsoluteUpdated(minLocalBufferAbsolute, newFloor);
        minLocalBufferAbsolute = newFloor;
    }

    /// @notice Set the absolute floor under the per-day growth allowance. See
    ///         `maxRemoteGrowthAbsolutePerDay`.
    function setMaxRemoteGrowthAbsolutePerDay(uint256 newFloor) external onlyOwner {
        emit RemoteGrowthAbsolutePerDayUpdated(maxRemoteGrowthAbsolutePerDay, newFloor);
        maxRemoteGrowthAbsolutePerDay = newFloor;
    }

    /// @notice Set the rolling outbound budget and the window it resets over.
    function setBridgeBudget(uint256 budget, uint64 window) external onlyOwner {
        // The spent counter is packed into 16 bytes, so a budget it cannot hold is rejected
        // rather than silently truncated on the first deposit.
        if (budget > type(uint128).max) revert LimitOutOfRange();
        bridgeBudgetPerWindow = budget;
        bridgeWindow = window;
        emit BridgeBudgetUpdated(budget, window);
    }

    /// @notice Overwrite the hub's reported value. Break glass, not an operation.
    /// @dev RSV-003: `sync` can only raise `remoteValue` from what it already is, so a value
    ///      reported at zero — by a stolen keeper key, or by an honest keeper reading a
    ///      collapsed oracle — writes the hub's holdings off with no way back. This grants the
    ///      owner nothing it does not already have: `_authorizeUpgrade` lets it rewrite this
    ///      slot, and every other slot, in one transaction. What it changes is that recovering
    ///      from that incident is one transaction instead of shipping an implementation, which
    ///      is the difference between a remedy that exists at 3am and one that does not.
    function setRemoteValue(uint256 newValue) external onlyOwner {
        emit RemoteValueOverridden(remoteValue, newValue);
        remoteValue = newValue;
        remoteValueUpdatedAt = uint64(block.timestamp);
    }

    /// @notice Overwrite the in-flight counters. Break glass, for the same reason.
    /// @dev RSV-005: both counters are written only by the keeper and only through `sync`, and
    ///      a settlement the keeper observes but cannot report — a leg whose start never
    ///      reached this contract — leaves a counter permanently too high, which permanently
    ///      overstates the position. Same authority argument as `setRemoteValue`.
    ///      `outboundExpected` follows the corrected figure down: what will arrive can never
    ///      exceed what is in flight, and understating it is the safe direction.
    function resetInFlight(uint256 outbound, uint256 inbound) external onlyOwner {
        emit InFlightReset(outboundInFlight, outbound, inboundInFlight, inbound);
        outboundInFlight = outbound;
        outboundExpected = Math.min(outboundExpected, outbound);
        inboundInFlight = inbound;
    }

    /// @notice Declare the whole local balance accounted for. Break glass, and the migration
    ///         path onto this implementation.
    /// @dev `localAtLastSettlement` is what makes `_position()` refuse to count an arrived leg
    ///      twice (RSV-002), and it starts at zero — which is correct for a fresh proxy, whose
    ///      balance is also zero, and wrong for a proxy upgraded onto this implementation with
    ///      a live buffer. Left at zero, the entire buffer reads as an unexplained arrival and
    ///      is netted off the in-flight counters, so the adapter would under-report its
    ///      position by up to the in-flight total for as long as any leg is outstanding.
    ///      Understating is the safe direction — it suppresses yield rather than paying it out
    ///      of principal — but it is still wrong, and no ordinary call converges on the right
    ///      value: `deposit` adds, `withdraw` and `bridgeOut` subtract, and `sync` only credits
    ///      what a report accounts for. Hence an explicit seed, owner-only, callable once per
    ///      upgrade and idempotent.
    function seedLocalBaseline() external onlyOwner {
        uint256 local = usdg.balanceOf(address(this));
        emit LocalBaselineSeeded(localAtLastSettlement, local);
        localAtLastSettlement = local;
    }

    /// @notice Always reverts. UUPS-003: behind a UUPS proxy the owner is the sole upgrade
    ///         authority, so renouncing it does not decentralize this adapter — it freezes the
    ///         implementation permanently and takes the keeper rotation, the limits and every
    ///         break-glass above with it, leaving a hot key as the only operator of a bridge
    ///         that can no longer be re-limited. The two-step `transferOwnership` is the
    ///         handover path, and nothing legitimate needs this one.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ─── IYieldSource ────────────────────────────────────────────────────

    /// @inheritdoc IYieldSource
    /// @dev Takes custody and stops. The bridge leg is the keeper's, later and in batches.
    function deposit(address asset, uint256 amount) external onlyController {
        _onlyUsdg(asset);
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        // An accounted-for increase, so `_position` must not mistake it for a leg arriving.
        localAtLastSettlement += amount;
        emit Deposited(amount);
    }

    /// @inheritdoc IYieldSource
    /// @dev Pays from the local balance and returns what it paid. Never reverts for asking too
    ///      much: the pool asks for `shortfall + 1` routinely and caps its payout at what came
    ///      back, and a redeemer's `minAssetsOut` is where "not enough" becomes a revert.
    function withdraw(address asset, uint256 amount, address to)
        external
        onlyController
        returns (uint256 paid)
    {
        _onlyUsdg(asset);
        uint256 local = usdg.balanceOf(address(this));
        paid = amount < local ? amount : local;
        if (paid > 0) usdg.safeTransfer(to, paid);
        // Saturating: `paid` can include an increase nothing has explained yet, and that part
        // has to stay unexplained rather than push this below zero.
        localAtLastSettlement -= Math.min(localAtLastSettlement, paid);
        emit Withdrawn(amount, paid);
    }

    /// @inheritdoc IYieldSource
    function balanceOf(address asset) external view returns (uint256) {
        return asset == address(usdg) ? _position() : 0;
    }

    /// @inheritdoc IYieldSource
    function totalAssets(address asset) external view returns (uint256) {
        return asset == address(usdg) ? _position() : 0;
    }

    /// @inheritdoc IYieldSource
    /// @dev Exactly what `withdraw` pays: the USDG on this chain. The remote leg is book value
    ///      until the keeper brings it home, so it is deliberately not counted here — this is
    ///      the liquidity question, and `balanceOf` is the accounting one.
    function withdrawable(address asset, address consumer) external view returns (uint256) {
        if (asset != address(usdg) || consumer != controller) return 0;
        return availableLiquidity();
    }

    /// @notice USDG that can be paid to redeemers right now, before any keeper action.
    /// @dev Predates `withdrawable` and is kept because the keeper and the runbook read it by
    ///      name; the two are the same number by construction.
    function availableLiquidity() public view returns (uint256) {
        return usdg.balanceOf(address(this));
    }

    /// @notice Outbound notional still available in the current budget window.
    function bridgeBudgetRemaining() external view returns (uint256) {
        uint256 budget = bridgeBudgetPerWindow;
        if (block.timestamp - _bridgeWindowStart >= bridgeWindow) return budget;
        return budget - Math.min(uint256(_bridgedInWindow), budget);
    }

    // ─── Keeper ──────────────────────────────────────────────────────────

    /// @notice Hand `amount` of the local USDG to Across for delivery to the hub as USDC.
    ///         Halted by the protocol guard; a pause stops new exposure, not redemptions.
    /// @param q The Across quote for exactly this deposit, fetched just before calling.
    function bridgeOut(uint256 amount, AcrossQuote calldata q)
        external
        onlyKeeper
        whenNotPaused
        returns (uint32 depositId)
    {
        if (maxBridgeAmount == 0 || amount > maxBridgeAmount) {
            revert BridgeAmountAboveCap(amount, maxBridgeAmount);
        }
        uint256 local = usdg.balanceOf(address(this));
        if (amount > local) revert InsufficientLocalBalance(amount, local);
        // Two floors, because the bps one is a share of a figure the keeper writes.
        uint256 required = Math.max(_position() * minLocalBufferBps / BPS, minLocalBufferAbsolute);
        if (local - amount < required) revert LocalBufferBreached(local - amount, required);
        _spendBridgeBudget(amount);

        depositId = _bridge(usdg, amount, hubUsdc, hubChainId, hub, maxBridgeFeeBps, q);
        outboundInFlight += amount;
        outboundExpected += q.outputAmount;
        localAtLastSettlement -= Math.min(localAtLastSettlement, amount);
        emit BridgedOut(depositId, amount, q.outputAmount);
    }

    /// @notice Apply the hub's report. See `SyncReport` for what each field asserts.
    ///
    ///         The growth cap: `remoteValue` plus whatever this report moves out of it into
    ///         `inboundInFlight` may not exceed the previous value, plus what the bridge will
    ///         actually deliver of the USDG the hub acknowledges receiving, plus USDC Across
    ///         refunded to the hub, plus the per-day allowance pro rata since the last report
    ///         and for at most `MAX_GROWTH_WINDOW`. Refunds of outbound USDG add nothing: that
    ///         USDG is back in the local balance.
    function sync(SyncReport calldata r) external onlyKeeper {
        uint256 prev = remoteValue;
        uint256 outbound = outboundInFlight;
        uint256 expected = outboundExpected;
        uint256 settled = r.outboundAcked + r.outboundRefunded;

        // Credit what the hub can have received, which is the quote's output, not the input.
        uint256 ackedValue = outbound == 0 ? 0 : Math.mulDiv(r.outboundAcked, expected, outbound);
        uint256 allowed = prev + ackedValue + r.inboundRefunded;
        if (remoteValueUpdatedAt != 0) {
            uint256 elapsed = Math.min(block.timestamp - remoteValueUpdatedAt, MAX_GROWTH_WINDOW);
            uint256 perDay =
                Math.max(prev * maxRemoteGrowthBpsPerDay / BPS, maxRemoteGrowthAbsolutePerDay);
            allowed += perDay * elapsed / 1 days;
        }
        if (r.remoteValue + r.inboundStarted > allowed) {
            revert RemoteValueAboveCap(r.remoteValue + r.inboundStarted, allowed);
        }

        // Underflow here is the check: nothing can be acknowledged that was never sent.
        outboundInFlight = outbound - settled;
        if (settled > 0) outboundExpected = expected - Math.mulDiv(settled, expected, outbound);
        inboundInFlight = inboundInFlight + r.inboundStarted - r.inboundLanded - r.inboundRefunded;
        remoteValue = r.remoteValue;
        remoteValueUpdatedAt = uint64(block.timestamp);
        // The arrivals this report accounts for: an inbound fill lands as USDG here, and an
        // outbound refund returns the exact input. Clamped to the balance because a fill
        // delivers the quote's output rather than the `inboundLanded` input being reported, and
        // because an increase this report does not account for must stay unexplained.
        localAtLastSettlement = Math.min(
            localAtLastSettlement + r.inboundLanded + r.outboundRefunded,
            usdg.balanceOf(address(this))
        );

        emit Synced(
            r.remoteValue,
            outboundInFlight,
            inboundInFlight,
            r.outboundAcked,
            r.outboundRefunded,
            r.inboundStarted,
            r.inboundLanded,
            r.inboundRefunded
        );
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Charge `amount` against the rolling budget. See `bridgeBudgetPerWindow`.
    function _spendBridgeBudget(uint256 amount) internal {
        uint256 spent = _bridgedInWindow;
        if (block.timestamp - _bridgeWindowStart >= bridgeWindow) {
            _bridgeWindowStart = uint64(block.timestamp);
            spent = 0;
        }
        uint256 budget = bridgeBudgetPerWindow;
        if (spent + amount > budget) {
            revert BridgeBudgetExhausted(amount, budget - Math.min(spent, budget));
        }
        _bridgedInWindow = uint128(spent + amount);
    }

    /// @notice USDG held here, plus what is still in flight either way, plus the hub's value.
    /// @dev RSV-002: an Across fill credits the local balance the instant a relayer fills it,
    ///      but the matching counter is only cleared by a later `sync` — so a plain sum of the
    ///      legs double-counts that leg for a whole keeper tick. `SharedReservePool` credits
    ///      the overstatement to its monotonic yield index and `claimYield` pays it out, and
    ///      neither is ever clawed back, which makes a public Across fill free money for anyone
    ///      watching for it. So an increase nothing has accounted for is read as a leg arriving
    ///      — which is what it is for every real cause, a fill or a refund — and netted off the
    ///      in-flight counters before they are added. A genuine donation is therefore
    ///      recognised one settlement late, and that is the right way round: this figure is the
    ///      reserve's asset side, where understating costs a brand some yield and overstating
    ///      pays yield out of somebody else's principal.
    function _position() internal view returns (uint256) {
        uint256 localNow = usdg.balanceOf(address(this));
        uint256 arrived = localNow > localAtLastSettlement ? localNow - localAtLastSettlement : 0;
        uint256 inFlight = outboundExpected + inboundInFlight;
        inFlight -= Math.min(inFlight, arrived);
        return localNow + inFlight + remoteValue;
    }

    function _onlyUsdg(address asset) internal view {
        if (asset != address(usdg)) revert UnsupportedAsset(asset);
    }
}
