// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IProtocolGuard} from "../upgrade/IProtocolGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

import {IPoolOracle} from "./IPoolOracle.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {PoolObservations} from "./PoolObservations.sol";

/// @title ProtocolFeeHook
/// @notice A Uniswap v4 hook that skims a fixed share of every swap and routes it to the
///         pool's own destination — in this repo, that market's `BrandFeeVault`, which is the
///         same place the market's float yield lands and the same place the buyback is funded
///         from.
///
///         **The cut always comes off the UNSPECIFIED currency, and always in `afterSwap`.** A
///         v4 swap names exactly one side: `amountSpecified` is the input on an exact-input
///         swap and the output on an exact-output one. Whichever side it did NOT name is the
///         unspecified one, and that is the side this hook charges — the output of an
///         exact-input swap, the input of an exact-output swap. One rule covering both
///         directions, so there is no swap type to flip into to escape the fee.
///
///         **Why `afterSwap`, when the exact-input skim used to live in `beforeSwap`.**
///         `beforeSwap` runs before `pool.swap`, so the only number available to it is the
///         amount the caller ASKED for. A v4 swap is under no obligation to fill that: a caller
///         who passes a `sqrtPriceLimitX96` short of where the pool would have to travel gets a
///         partial fill, with the remainder silently unfilled. Charging in `beforeSwap`
///         therefore billed the trader on notional that never traded, up to the full
///         `MAX_FEE_PIPS` of the unfilled remainder. Our own `MarketRouter` never reached that
///         case because it passes the extreme price limits and so fills or reverts, but an
///         aggregator quoting these pools straight against the `PoolManager` sets its own limit
///         and is precisely the caller that does. `afterSwap` is handed the `BalanceDelta` the
///         pool actually produced, so a partial fill is charged on what filled — that is all a
///         delta can report.
///
///         **This moved the exact-input fee from the input leg to the output leg, which is a
///         real economic change and not a refactor.** Under the old ordering the skim came out
///         ahead of `pool.swap`, so the LP fee was charged only on the remainder. It no longer
///         is: the pool now sees the whole input, the LPs earn their fee on all of it, and the
///         protocol takes its pips out of the output the swap produced. That output is already
///         net of the LP fee and of price impact, so the protocol's take on an exact-input swap
///         is slightly SMALLER than it used to be, and it accrues in the output currency rather
///         than the input one.
///
///         Worked, at the live 5,000 pips (0.50%) through a 0.30% pool, ignoring impact on a
///         round 1,000 units in. Before: 5.000 units of the INPUT were skimmed, the pool swapped
///         995, the LPs earned 2.985, and the trader received about 992.015 of the output.
///         After: nothing is skimmed up front, the pool swaps the full 1,000, the LPs earn
///         3.000, the output is about 997.000, and the protocol takes 0.50% of that — 4.985
///         units of the OUTPUT — leaving the trader about 992.015. The trader pays materially
///         the same all-in rate; what moved is which currency the protocol is paid in, and the
///         fact that the LPs are no longer diluted by the skim. `pendingFees` is keyed per pool
///         per currency and `collect` sweeps both sides of the `PoolKey`, so nothing downstream
///         needed to change to follow the fee onto the other leg.
///
///         **Fees accrue as ERC-6909 claims, not ERC-20 transfers.** `poolManager.mint` moves
///         no tokens; it just credits this contract inside the PoolManager. That keeps the
///         per-swap cost to a storage write instead of a transfer, and — more importantly —
///         it works no matter how the calling router orders its settlement. A hook that
///         called `poolManager.take` mid-swap would require the PoolManager to already hold
///         the trader's input, which is only true for routers that prepay. `collect` converts
///         the claims to real tokens later, in its own `unlock`.
///
///         **Nothing here is immutable that a parameter change would touch.** A v4 hook's
///         permissions are encoded in the low 14 bits of its own address, so the address is
///         mined against the exact creation code *and constructor arguments*. Making the fee
///         or the treasury an immutable constructor argument would mean that changing either
///         one produces a different address, and since `PoolKey.hooks` is part of a pool's
///         identity, every pool ever launched would be orphaned. So they are storage behind
///         an owner, and this contract is a singleton mined once per chain.
///
///         **This hook is also the pools' oracle.** V4 core deleted observations: a v4 pool has
///         no `observe()` and keeps no history, because Uniswap decided oracles belong in hooks.
///         `BuybackEngine` prices its manipulation-resistant band off a TWAP, so somebody has to
///         keep one, and the only contract already invoked on every swap of these pools is this
///         one. `PoolObservations` is V3's ring buffer; this contract owns one per registered
///         pool and writes to it in `beforeSwap`, from the pre-swap tick, exactly as V3 does.
///         The buffer costs nothing to pools we did not
///         register — it is opened in `registerPool` and skipped entirely when absent — and,
///         critically, adding it changed no permission flag, so every hook address already mined
///         against `0x00CC` stays valid.
contract ProtocolFeeHook is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    IHooks,
    IUnlockCallback,
    IPoolOracle
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Limits ──────────────────────────────────────────────────────────

    /// @notice Fee denominator, in hundredths of a basis point. 1_000_000 == 100%.
    ///         Matches Uniswap's own fee units so a `feePips` reads the same way `key.fee`
    ///         does — 3_000 is 0.30% in both.
    uint24 public constant PIPS_DENOMINATOR = 1_000_000;

    /// @notice Hard ceiling on what any pool's protocol fee may be set to, ever. 1%.
    ///         A bound in the bytecode rather than a bound in a policy document: the owner
    ///         can move the fee, but cannot move it somewhere confiscatory.
    ///
    ///         **Lowered from 5% once aggregators began quoting these pools.** Every live
    ///         market is registered at 5,000 pips, and an aggregator's quote is only as good
    ///         as the rate that holds when it settles. At a 5% ceiling the owner — one EOA,
    ///         with no timelock — could multiply the skim tenfold in a single transaction and
    ///         invalidate every quote in flight. A 1% ceiling still leaves twice the live rate
    ///         in headroom while making the worst case an integrator must price a bounded and
    ///         unembarrassing number. The constant lives in bytecode, so raising it again
    ///         means shipping an implementation, which is a visible act rather than a setter
    ///         call.
    ///
    ///         Lowering this cannot strand a pool. `feePipsOf` has two writers — `registerPool`
    ///         and `setPoolFeePips` — and both check the ceiling on the way in, so a rate
    ///         stored under an older, higher ceiling stays readable and stays chargeable until
    ///         the owner moves it down. No live pool is above it today.
    uint24 public constant MAX_FEE_PIPS = 10_000;

    /// @notice How long a fee INCREASE is announced before it can be charged.
    ///
    ///         One hour, chosen against what it has to cover: the gap between an aggregator
    ///         publishing a quote and a taker filling it, which is seconds. An hour is orders
    ///         of magnitude more than that and still short enough to reprice within a trading
    ///         day. It is NOT a governance timelock and should not be read as one — see
    ///         `setPoolFeePips` for why an upgradeable contract cannot offer that with a
    ///         constant like this.
    ///
    /// @dev    A constant, not a parameter. A settable delay is a delay the owner can set to
    ///         zero the transaction before raising the fee, which is no delay at all.
    uint64 public constant FEE_INCREASE_DELAY = 1 hours;

    // ─── Wiring ──────────────────────────────────────────────────────────

    /// @notice The v4 PoolManager this hook is bound to.
    IPoolManager public poolManager;

    /// @notice The protocol pause registry. Read on the swap path, so it is read defensively —
    ///         see `feePipsFor`.
    IProtocolGuard public guard;

    /// @notice The only address allowed to register a pool's fee destination. In practice the
    ///         `AssetMarketFactory`, set once after both are deployed because each needs the
    ///         other's address.
    address public registrar;

    // There is deliberately NO hook-wide default rate here. One used to exist, and
    // `feePipsFor` read a stored zero as "follow it" — which meant every market created at the
    // default rate (all of them, since the factory ships `protocolFeePips = 0`) tracked a
    // mutable global, and one `setDefaultFeePips` raised the skim on all of them at once, up to
    // `MAX_FEE_PIPS`. That is the opposite of what `AssetMarketFactory.protocolFeePips`
    // promises, and there was no way to pin a pool at exactly zero. The rate policy belongs to
    // the factory, which always passes an explicit value; here zero is simply zero.

    /// @notice Where a pool's skimmed fees go when `collect` is called. Zero means this pool
    ///         is not ours and is charged nothing.
    mapping(PoolId => address) public feeRecipientOf;

    /// @notice A registered pool's rate, and the whole of it. Zero is a real rate meaning
    ///         "charge this pool nothing", not a sentinel for a hook-wide default — there is no
    ///         longer one to fall back to. An unregistered pool never reaches this map at all.
    mapping(PoolId => uint24) public feePipsOf;

    /// @notice Claims accrued but not yet converted to real tokens, per pool per currency.
    mapping(PoolId => mapping(Currency => uint256)) public pendingFees;

    // ─── Oracle state ────────────────────────────────────────────────────

    /// @notice Where a pool's ring buffer sits, in V3's exact three-field shape.
    /// @dev Packed into one slot so the per-swap write touches a single word beyond the
    ///      observation itself. `cardinality == 0` is the "this pool has no oracle" sentinel,
    ///      which is what lets an unregistered pool skip the whole mechanism.
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The ring buffer itself, per pool. Fixed 65535 entries exactly as in V3 — storage
    ///         is sparse, so an unused tail costs nothing until `grow` prepays it.
    mapping(PoolId => PoolObservations.Observation[65535]) internal observations;

    /// @notice Ring cursor and lengths, per pool.
    mapping(PoolId => ObservationState) internal observationStates;

    /// @notice A scheduled INCREASE to a pool's rate, not yet in force. Zero here is not a
    ///         sentinel — read `feePipsEffectiveAt` to tell "nothing pending" from "pending a
    ///         move to zero", though the latter cannot arise because a decrease applies
    ///         immediately and never schedules.
    mapping(PoolId => uint24) public pendingFeePipsOf;

    /// @notice When a scheduled increase may be committed. Zero means nothing is pending.
    ///
    /// @dev    Appended at the end of storage, after every field this contract already had.
    ///         `ProtocolFeeHook` carries no `__gap` because it is a leaf — nothing inherits it
    ///         — so appending is the safe direction and no existing slot moves. Deliberately
    ///         NOT packed alongside anything: these two mappings are read only by governance
    ///         paths, never by `feePipsFor`, so there is no gas argument for packing and a
    ///         separate slot keeps the layout obvious to the next upgrade.
    mapping(PoolId => uint64) public feePipsEffectiveAt;

    event PoolRegistered(PoolId indexed poolId, address indexed recipient, uint24 feePips);
    event ObservationCardinalityNextIncreased(
        PoolId indexed poolId, uint16 cardinalityNextOld, uint16 cardinalityNextNew
    );
    event PoolFeeUpdated(PoolId indexed poolId, uint24 feePips);
    event PoolFeeIncreaseScheduled(
        PoolId indexed poolId, uint24 currentFeePips, uint24 pendingFeePips, uint64 effectiveAt
    );
    event PoolFeeIncreaseCommitted(PoolId indexed poolId, uint24 previousFeePips, uint24 feePips);
    event PoolFeeIncreaseCancelled(PoolId indexed poolId, uint24 abandonedFeePips);
    event PoolFeeRecipientUpdated(
        PoolId indexed poolId, address indexed previous, address indexed current
    );
    event RegistrarUpdated(address indexed registrar);
    event FeeAccrued(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeeCollected(
        PoolId indexed poolId, Currency indexed currency, address indexed to, uint256 amount
    );

    error OnlyPoolManager();
    error OnlyRegistrar();
    error FeeTooLarge();
    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error NoPendingFeeIncrease();
    error FeeIncreaseNotReady(uint64 effectiveAt, uint64 nowTs);
    error HookMismatch();
    error ZeroWindow();
    error OwnershipCannotBeRenounced();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @dev **The permission check runs against the PROXY's address, not the implementation's.**
    ///      An initialiser executes by `delegatecall`, so `address(this)` here is the proxy that
    ///      the `PoolManager` will actually call — which is the address whose low bits have to
    ///      carry the flags, and therefore the one the deploy script mines a salt for.
    ///
    ///      **An upgrade must never change `getHookPermissions`.** The flags live in an address
    ///      that upgrading cannot move. Ship an implementation declaring a different set and the
    ///      manager keeps calling exactly the callbacks the old bits named, while the new code
    ///      expects others — silently, with no revert. Any new callback needs a new hook at a
    ///      newly mined address, and pools must be re-created against it.
    function initialize(IPoolManager _poolManager, address _owner, address _guard)
        external
        initializer
    {
        if (address(_poolManager) == address(0) || _guard == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(_owner);
        __Ownable2Step_init();

        poolManager = _poolManager;
        guard = IProtocolGuard(_guard);

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Always reverts. This hook's address carries its permission bits, so it can
    ///         never be replaced without re-creating every pool against a newly mined
    ///         address. Renouncing would therefore freeze the fee rate, the registrar and the
    ///         oracle depth of every market ever created here, permanently and with no
    ///         migration path. `transferOwnership` is the handover path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice `beforeSwap` and `afterSwap`, both with return deltas — flag bits `0x00CC`.
    ///         `beforeSwap` is still permitted because it writes the oracle on every swap;
    ///         `afterSwap` is where the whole fee now lives, in both directions, and
    ///         `afterSwapReturnDelta` is what lets it actually claim anything.
    ///
    ///         **`beforeSwapReturnDelta` is declared here and deliberately never exercised. Do
    ///         not remove it.** It was load-bearing while the exact-input skim ran in
    ///         `beforeSwap`; moving that skim to `afterSwap` left it unused. Deleting it looks
    ///         like tidying and is not: these fourteen bits ARE this contract's address, mined
    ///         once against `0x00CC`, and a UUPS upgrade cannot move an address. An
    ///         implementation declaring `beforeSwapReturnDelta: false` would fail
    ///         `Hooks.validateHookPermissions` if it were ever re-initialised, and in the
    ///         meantime would make this function disagree with the flags the `PoolManager`
    ///         actually reads out of the address — the two would drift silently, with no
    ///         revert. Declaring a permission the code does not use is safe in exactly this
    ///         direction: the manager calls the callback, the callback returns a zero delta,
    ///         and nothing is claimed. The reverse is not. `PoolKey.hooks` is part of a pool's
    ///         identity, so a new address means re-creating all 18 live markets.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Administration ──────────────────────────────────────────────────

    function setRegistrar(address _registrar) external onlyOwner {
        registrar = _registrar;
        emit RegistrarUpdated(_registrar);
    }

    /// @notice Point a pool's skimmed fees at a destination, and fix that pool's rate.
    ///
    ///         One-shot: a pool may only be registered once. The DESTINATION is no longer
    ///         permanent though - see `setFeeRecipient`.
    /// @param key      The pool. Its `hooks` field must be this contract.
    /// @param recipient Where `collect` sends this pool's fees.
    /// @param feePips  This pool's rate, fixed here. Zero means this pool is charged nothing,
    ///                 permanently unless the owner moves this one pool with `setPoolFeePips`.
    function registerPool(PoolKey calldata key, address recipient, uint24 feePips) external {
        if (msg.sender != registrar) revert OnlyRegistrar();
        if (recipient == address(0)) revert ZeroAddress();
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (feePips > MAX_FEE_PIPS) revert FeeTooLarge();

        PoolId id = key.toId();
        if (feeRecipientOf[id] != address(0)) revert AlreadyRegistered();

        feeRecipientOf[id] = recipient;
        feePipsOf[id] = feePips;

        // Open the pool's oracle here rather than in an `afterInitialize` hook, for two reasons.
        // First, `afterInitialize` is not one of our permissions and turning it on would change
        // the flag bits in this contract's address, orphaning every pool already launched
        // against the mined one. Second, `registerPool` is already the factory-gated, one-shot
        // entry point, so tying the buffer to it means only pools we actually launched pay for
        // an oracle — a stranger who points a `PoolKey` at this hook gets no fee *and* no
        // observations, and `_writeObservation` costs their swaps a single cold SLOAD.
        (uint16 cardinality, uint16 cardinalityNext) =
            PoolObservations.initialize(observations[id], uint32(block.timestamp));
        observationStates[id] = ObservationState({
            index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext
        });

        emit PoolRegistered(id, recipient, feePips);
    }

    /// @notice Move a registered pool's rate. A DECREASE applies immediately; an INCREASE is
    ///         scheduled and takes `FEE_INCREASE_DELAY` to come into force.
    ///
    ///         **Why the asymmetry, and what it is actually for.** An aggregator quotes a
    ///         route and fills it some seconds later. If the rate could rise in between, the
    ///         quote it published was wrong through no fault of its own. A slippage bound
    ///         already stops that costing the trader money — the fill reverts — but a route
    ///         that reverts is still a broken quote, and an aggregator's complaint is about
    ///         reliability rather than theft. Announcing increases an hour ahead makes a
    ///         published rate good for an hour, which is the property a quoter needs.
    ///
    ///         Decreases need no delay because no quote is invalidated in a direction anyone
    ///         minds, and being able to cut a fee in the same block is worth keeping for an
    ///         incident or a competitive response.
    ///
    /// @dev    **This is a reliability guarantee, not a security one, and the difference
    ///         matters.** This contract is a UUPS proxy whose `_authorizeUpgrade` is
    ///         `onlyOwner` with no timelock, so an owner who wanted to raise a rate instantly
    ///         could ship an implementation without this delay in a single transaction. What
    ///         the delay defends against is a mistake, and an honest operator's ordinary
    ///         repricing surprising an integrator. It does not bind a compromised key, and no
    ///         one should be told otherwise.
    ///
    ///         The hot path is untouched: `feePipsFor` still reads one mapping and never looks
    ///         at the pending fields, so a scheduled increase costs a swap nothing.
    function setPoolFeePips(PoolId id, uint24 feePips) external onlyOwner {
        if (feeRecipientOf[id] == address(0)) revert NotRegistered();
        if (feePips > MAX_FEE_PIPS) revert FeeTooLarge();

        uint24 current = feePipsOf[id];
        if (feePips <= current) {
            // A decrease, or a no-op restatement of the current rate. Applies now, and
            // abandons any increase that was in flight: the owner has just said what they
            // want the rate to be, and leaving a higher one primed to land later would make
            // "I lowered the fee" quietly untrue.
            uint24 abandoned = pendingFeePipsOf[id];
            if (feePipsEffectiveAt[id] != 0) {
                delete pendingFeePipsOf[id];
                delete feePipsEffectiveAt[id];
                emit PoolFeeIncreaseCancelled(id, abandoned);
            }
            feePipsOf[id] = feePips;
            emit PoolFeeUpdated(id, feePips);
            return;
        }

        // An increase. Recorded, announced, and not yet charged. Calling again before the
        // window elapses replaces the pending value and RESTARTS the clock, so an operator
        // cannot stage a small increase and swap it for a large one at the last second.
        uint64 effectiveAt = uint64(block.timestamp) + FEE_INCREASE_DELAY;
        pendingFeePipsOf[id] = feePips;
        feePipsEffectiveAt[id] = effectiveAt;
        emit PoolFeeIncreaseScheduled(id, current, feePips, effectiveAt);
    }

    /// @notice Bring a scheduled increase into force. Permissionless by design: the change was
    ///         already announced by the owner, and letting anyone finalise it removes the
    ///         possibility of a rate that appears raised on chain but is quietly never
    ///         applied. It still cannot land early.
    function commitPoolFeePips(PoolId id) external {
        uint64 effectiveAt = feePipsEffectiveAt[id];
        if (effectiveAt == 0) revert NoPendingFeeIncrease();
        if (block.timestamp < effectiveAt) {
            revert FeeIncreaseNotReady(effectiveAt, uint64(block.timestamp));
        }

        uint24 feePips = pendingFeePipsOf[id];
        // Re-checked at commit as well as at schedule. `MAX_FEE_PIPS` is a constant today, but
        // it has already been lowered once (5% to 1%), and a pending value authorised under an
        // older, higher ceiling must not be able to land under the new one.
        if (feePips > MAX_FEE_PIPS) revert FeeTooLarge();

        uint24 previous = feePipsOf[id];
        delete pendingFeePipsOf[id];
        delete feePipsEffectiveAt[id];

        feePipsOf[id] = feePips;
        // Both events, deliberately. `PoolFeeIncreaseCommitted` is the governance story; the
        // existing `PoolFeeUpdated` is what an indexer already watches for the live value, and
        // dropping it would silently break every consumer of the live rate.
        emit PoolFeeIncreaseCommitted(id, previous, feePips);
        emit PoolFeeUpdated(id, feePips);
    }

    /// @notice Abandon a scheduled increase before it lands.
    function cancelPendingPoolFeePips(PoolId id) external onlyOwner {
        if (feePipsEffectiveAt[id] == 0) revert NoPendingFeeIncrease();

        uint24 abandoned = pendingFeePipsOf[id];
        delete pendingFeePipsOf[id];
        delete feePipsEffectiveAt[id];
        emit PoolFeeIncreaseCancelled(id, abandoned);
    }

    /// @notice Repoint a registered pool's fee destination.
    ///
    ///         **This used to be impossible, deliberately, and the reason it no longer is.**
    ///         `registerPool` bound the destination one-shot so that "this market's trading
    ///         fees buy this market's asset" could not be revoked by the owner. That promise
    ///         was enforced for `BuybackEngine` reading a market's `BrandFeeVault`, and both
    ///         of those contracts have since been deleted. The destination registered for
    ///         every live pool today is the protocol treasury, not a per-market vault, so the
    ///         immutability was protecting a property the system no longer has.
    ///
    ///         It was also never a real constraint on this owner. The hook is a UUPS proxy
    ///         whose `_authorizeUpgrade` is `onlyOwner`, so an owner who wanted to repoint a
    ///         destination could always ship an implementation that does. A one-shot mapping
    ///         only stopped the honest operator, and it stopped them from the one thing they
    ///         actually need: moving revenue off a key that has been compromised.
    ///
    ///         **Applies to pools already registered as well as future ones.** Restricting it
    ///         to new pools would need a marker in storage recording which era a pool belongs
    ///         to, and would leave the 18 markets that exist paying a key nobody can rotate —
    ///         which is the situation this exists to end.
    ///
    ///         What is NOT repointable is the rate's ceiling or the pool's registration
    ///         itself: `MAX_FEE_PIPS` still binds, and a pool still cannot be re-registered.
    /// @param id        A registered pool.
    /// @param recipient Where `collect` sends this pool's fees from now on. Fees ALREADY
    ///                  accrued are unaffected: they sit in `pendingFees` and are paid to
    ///                  whoever is named at the moment `collect` runs, so call `collect`
    ///                  before repointing if the old destination is owed them.
    function setFeeRecipient(PoolId id, address recipient) external onlyOwner {
        address previous = feeRecipientOf[id];
        if (previous == address(0)) revert NotRegistered();
        if (recipient == address(0)) revert ZeroAddress();

        feeRecipientOf[id] = recipient;
        emit PoolFeeRecipientUpdated(id, previous, recipient);
    }

    /// @notice The rate a pool is actually charged. An unregistered pool is charged nothing,
    ///         so a stranger who points a `PoolKey` at this hook gets a hook that does nothing
    ///         rather than one that quietly confiscates their traders' input into a balance
    ///         nobody can withdraw.
    ///
    ///         A registered pool is charged exactly what it was registered with, until the owner
    ///         moves that one pool with `setPoolFeePips`. There is no hook-wide fallback: a
    ///         market registered at zero stays at zero, which is what makes "every basis point
    ///         buys the token back" a property of that market rather than of whatever the hook's
    ///         owner most recently set for everyone.
    ///         **Pausing zeroes this rather than reverting, and that is deliberate.** Every
    ///         other guarded function in the protocol reverts when halted. This one cannot: it
    ///         is reached from `beforeSwap` and `afterSwap`, and a hook that reverts makes the
    ///         `PoolManager` reject the swap outright — so a revert here would not pause our
    ///         skim, it would brick a public Uniswap pool for every trader and integrator using
    ///         it, ours or not. Returning zero stops the protocol taking anything while trading
    ///         continues untouched, which is the actual thing a pause should achieve. The
    ///         observation `beforeSwap` writes is still recorded, so the oracle keeps its
    ///         history across a halt.
    ///
    ///         Liquidity is unaffected either way: this hook declares no liquidity callbacks, so
    ///         an LP can withdraw whether or not the protocol is halted.
    function feePipsFor(PoolId id) public view returns (uint24) {
        if (feeRecipientOf[id] == address(0)) return 0;
        if (_haltedSafely()) return 0;
        return feePipsOf[id];
    }

    /// @dev The pause read, made incapable of bricking a pool.
    ///
    ///      A plain `guard.isPaused(...)` would propagate a revert from the registry into
    ///      `beforeSwap`, which is the one place in this system where a revert is unacceptable:
    ///      it would take every pool carrying this hook offline, and no upgrade of the registry
    ///      could be applied fast enough to matter. A raw `staticcall` that treats any failure —
    ///      a reverting registry, a self-destructed one, an address with no code — as "not
    ///      halted" fails in the only safe direction: the protocol keeps charging its fee, which
    ///      is a problem someone can fix, rather than the venue going dark, which is not.
    function _haltedSafely() private view returns (bool) {
        (bool ok, bytes memory ret) =
            address(guard).staticcall(abi.encodeCall(IProtocolGuard.isPaused, (address(this))));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    // ─── The skim ────────────────────────────────────────────────────────

    /// @dev One job: the oracle.
    ///
    ///      **The observation, unconditionally.** V3 writes its
    ///      observation inside `swap`, from `slot0Start.tick` — the tick as it stood *before*
    ///      the swap. That is not an implementation detail, it is the correctness argument: the
    ///      accumulator credits `tick * elapsed` for the interval that just ended, and the tick
    ///      that actually held over that interval is the one the pool is sitting at right now,
    ///      not the one this swap is about to move it to. `beforeSwap` is therefore the only
    ///      place in a v4 hook where V3's semantics are available at all.
    ///
    ///      Recording the *post*-swap tick instead — the obvious-looking `afterSwap` version —
    ///      is a real manipulation vector, not a rounding quibble. It would credit the tick a
    ///      swap creates to the whole interval before that swap, so an attacker who simply waits
    ///      before spiking buys the entire quiet interval as weight for one block of
    ///      manipulation. Under the V3 ordering below, a spike-and-revert inside a single block
    ///      contributes to the accumulator exactly nothing: the write that precedes the spike
    ///      records the pre-spike tick, and the write that precedes the revert is suppressed
    ///      because an observation for that block already exists.
    ///
    ///      It is unconditional, above every early return, because a pool's history must not
    ///      depend on which swap type or which size happened to come through.
    ///
    ///      **No fee is taken here, and none can be.** `beforeSwap` precedes `pool.swap`, so
    ///      the only quantity it can see is the amount the caller asked for, which a swap with
    ///      a binding `sqrtPriceLimitX96` need not fill. The whole fee therefore lives in
    ///      `afterSwap`, which is given the delta the pool actually produced. `ZERO_DELTA`
    ///      unconditionally: this callback never charges anything, in either direction.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _writeObservation(key.toId());

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev The entire fee, both swap directions, measured from what the pool actually moved.
    ///
    ///      **Which leg is the unspecified one.** Core decides that with
    ///      `params.amountSpecified < 0 == params.zeroForOne`: when that holds the SPECIFIED
    ///      currency is `currency0`, otherwise it is `currency1` (`Hooks.afterSwap`, where the
    ///      returned `int128` is folded into `hookDeltaUnspecified` and then ordered into a
    ///      `BalanceDelta` by exactly this test). The expression below is that same test, so
    ///      the currency this function accrues and the currency core settles the return value
    ///      against cannot disagree — they are derived from one predicate.
    ///
    ///      **The sign, which differs between the two directions and is asserted, not assumed.**
    ///      `Hooks.afterSwap` computes `swapDelta = swapDelta - hookDelta`, and `hookDelta` is
    ///      then credited to this contract by `PoolManager._accountPoolBalanceDelta`. A POSITIVE
    ///      return therefore always means "credit the hook, charge the swapper", whichever leg
    ///      the unspecified currency happens to be. What flips is the delta we read:
    ///
    ///        - exact-input  (`amountSpecified < 0`): unspecified is the OUTPUT, so the pool
    ///          credited the swapper and `unspecifiedAmount` is POSITIVE.
    ///        - exact-output (`amountSpecified > 0`): unspecified is the INPUT, so the swapper
    ///          owes it and `unspecifiedAmount` is NEGATIVE.
    ///
    ///      `base` normalises those to a positive magnitude and the guard below rejects
    ///      anything that does not carry the sign this reasoning depends on, rather than
    ///      casting through it. `base <= 0` also covers the honest degenerate case: a swap that
    ///      filled nothing at all because the price limit was already reached, which must cost
    ///      the caller nothing rather than revert.
    ///
    ///      **A partial fill is charged on the fill.** `delta` is `pool.swap`'s own return
    ///      value, so an unfilled remainder is simply absent from it. There is no separate
    ///      partial-fill branch here because there is nothing for one to do.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();

        bool exactInput = params.amountSpecified < 0;

        (Currency unspecified, int128 unspecifiedAmount) = exactInput == params.zeroForOne
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // Widened to `int256` before negating: `-type(int128).min` does not fit in an `int128`.
        int256 base = exactInput ? int256(unspecifiedAmount) : -int256(unspecifiedAmount);
        if (base <= 0) return (IHooks.afterSwap.selector, 0);

        uint256 feeAmount = FullMath.mulDiv(uint256(base), feePipsFor(id), PIPS_DENOMINATOR);
        if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);

        _accrue(id, unspecified, feeAmount);

        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    // ─── The oracle ──────────────────────────────────────────────────────

    /// @dev Record the tick as it stands *now*, which — because this is only ever reached from
    ///      `beforeSwap` — is the tick that prevailed over the whole interval since the last
    ///      observation. This is exactly V3's `slot0Start.tick`.
    ///
    ///      A pool we never registered has `cardinality == 0` and is skipped, so the cost to a
    ///      stranger's pool is one cold SLOAD and nothing else.
    ///
    ///      `write` itself is a no-op when an observation already exists for this block. Paired
    ///      with the pre-swap tick, that is what makes a same-block spike-and-revert invisible
    ///      to the accumulator: the first swap of the block records the honest pre-spike tick,
    ///      and every later swap in that block — the spike's own reversal included — writes
    ///      nothing at all.
    function _writeObservation(PoolId id) internal {
        ObservationState memory state = observationStates[id];
        if (state.cardinality == 0) return;

        (, int24 tick,,) = poolManager.getSlot0(id);

        (uint16 indexUpdated, uint16 cardinalityUpdated) = PoolObservations.write(
            observations[id],
            state.index,
            uint32(block.timestamp),
            tick,
            state.cardinality,
            state.cardinalityNext
        );

        if (indexUpdated != state.index || cardinalityUpdated != state.cardinality) {
            observationStates[id].index = indexUpdated;
            observationStates[id].cardinality = cardinalityUpdated;
        }
    }

    /// @notice Deepen a pool's observation buffer so it can answer longer windows.
    ///
    ///         Permissionless, exactly as in V3. The only thing a caller decides is to pay for
    ///         storage that everyone reading this market's TWAP then benefits from, and the
    ///         buffer can only grow: `PoolObservations.grow` returns the current length
    ///         unchanged for any `next` that is not an increase, so nobody can shrink a market's
    ///         history out from under a contract that is relying on it.
    /// @param key  The pool, which must have been registered.
    /// @param next The desired buffer length.
    function increaseObservationCardinalityNext(PoolKey calldata key, uint16 next)
        external
        override
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        ObservationState storage state = observationStates[id];

        cardinalityNextOld = state.cardinalityNext;
        if (cardinalityNextOld == 0) revert PoolObservations.NotInitialized();

        cardinalityNextNew = PoolObservations.grow(observations[id], cardinalityNextOld, next);

        if (cardinalityNextNew != cardinalityNextOld) {
            state.cardinalityNext = cardinalityNextNew;
            emit ObservationCardinalityNextIncreased(id, cardinalityNextOld, cardinalityNextNew);
        }
    }

    /// @notice V3's `IUniswapV3PoolDerivedState.observe`, minus the liquidity series.
    /// @dev Reverts `PoolObservations.NotInitialized` for a pool that has no oracle, and
    ///      `PoolObservations.TargetPredatesOldestObservation` when the buffer does not reach
    ///      back far enough. Never returns a zero for either case — a caller that reads a
    ///      fabricated zero cumulative gets a fabricated price, which is exactly the failure the
    ///      TWAP band exists to prevent.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives)
    {
        return _observe(key.toId(), secondsAgos);
    }

    /// @notice The arithmetic mean tick over the last `window` seconds, ending NOW.
    ///
    ///         **Do not derive a price band from this.** The window ends at the current block,
    ///         and `observeSingle(0)` extends the newest stored observation forward at the
    ///         pool's *live* tick — so up to `PoolObservations.MIN_INTERVAL` seconds of a price
    ///         somebody is manipulating in this very transaction lands in the average, at no
    ///         cost and no risk to them. Measured: a spike fourteen seconds after an honest
    ///         write moves this read 186 ticks, about 1.9% on price, inside one block.
    ///
    ///         `BuybackEngine.twapSqrtPriceX96` therefore does NOT call this. It reads
    ///         `observe` over a window ending `MIN_INTERVAL` ago, so both endpoints resolve to
    ///         stored observations and a same-block spike is worth exactly zero. See that
    ///         function for the full account of what the lag does and does not buy.
    ///
    ///         This remains for surfaces that want a cheap, current reading and are not
    ///         deciding how to spend money on it — a chart, a quote preview, a status panel.
    /// @dev Mirrors Uniswap's `OracleLibrary.consult`, including its flooring convention:
    ///      Solidity's integer division truncates toward zero, so a negative mean would round
    ///      *up* and place the price band one tick higher than the history justifies. The
    ///      correction below floors toward negative infinity instead.
    function consultTick(PoolKey calldata key, uint32 window)
        external
        view
        override
        returns (int24 arithmeticMeanTick)
    {
        if (window == 0) revert ZeroWindow();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        int56[] memory tickCumulatives = _observe(key.toId(), secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 windowSeconds = int56(uint56(window));

        arithmeticMeanTick = int24(delta / windowSeconds);
        if (delta < 0 && delta % windowSeconds != 0) arithmeticMeanTick--;
    }

    /// @notice Where a pool's ring buffer currently stands.
    /// @return index           Index of the most recent observation.
    /// @return cardinality     Number of populated entries.
    /// @return cardinalityNext Target set by `increaseObservationCardinalityNext`.
    function observationState(PoolId id)
        external
        view
        override
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext)
    {
        ObservationState memory state = observationStates[id];
        return (state.index, state.cardinality, state.cardinalityNext);
    }

    /// @notice A single raw entry, for inspection and for tests.
    function getObservation(PoolId id, uint256 index)
        external
        view
        returns (uint32 blockTimestamp, int56 tickCumulative, bool initialized)
    {
        PoolObservations.Observation memory o = observations[id][index];
        return (o.blockTimestamp, o.tickCumulative, o.initialized);
    }

    function _observe(PoolId id, uint32[] memory secondsAgos)
        internal
        view
        returns (int56[] memory)
    {
        ObservationState memory state = observationStates[id];
        if (state.cardinality == 0) revert PoolObservations.NotInitialized();

        (, int24 tick,,) = poolManager.getSlot0(id);

        return PoolObservations.observe(
            observations[id],
            uint32(block.timestamp),
            secondsAgos,
            tick,
            state.index,
            state.cardinality
        );
    }

    /// @dev Book the fee and mint the matching ERC-6909 claim. The mint debits this hook by
    ///      `amount` inside the PoolManager; the delta returned by the caller credits it by
    ///      the same amount, so the pair nets to zero by the end of the unlock.
    function _accrue(PoolId id, Currency currency, uint256 amount) internal {
        poolManager.mint(address(this), currency.toId(), amount);
        pendingFees[id][currency] += amount;

        emit FeeAccrued(id, currency, amount);
    }

    // ─── Collection ──────────────────────────────────────────────────────

    /// @notice Turn a pool's accrued claims into real tokens and send them to that pool's
    ///         registered recipient.
    ///
    ///         Permissionless: the destination is fixed at registration and this function
    ///         takes no address, so the only thing a caller decides is when to pay the gas.
    function collect(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        // Unlike the skim, this one reverts. It moves money and is not on the swap path, so
        // halting it costs a caller a retry rather than taking a pool offline.
        guard.requireNotPaused(address(this));
        PoolId id = key.toId();
        address recipient = feeRecipientOf[id];
        if (recipient == address(0)) revert NotRegistered();

        amount0 = pendingFees[id][key.currency0];
        amount1 = pendingFees[id][key.currency1];
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        pendingFees[id][key.currency0] = 0;
        pendingFees[id][key.currency1] = 0;

        poolManager.unlock(
            abi.encode(id, key.currency0, key.currency1, amount0, amount1, recipient)
        );
    }

    /// @dev Burn the claims (a credit) and take the real tokens (a debit) so the unlock ends
    ///      with a zero delta count. Reached only through `collect`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (
            PoolId id,
            Currency currency0,
            Currency currency1,
            uint256 amount0,
            uint256 amount1,
            address recipient
        ) = abi.decode(data, (PoolId, Currency, Currency, uint256, uint256, address));

        _settleOne(id, currency0, amount0, recipient);
        _settleOne(id, currency1, amount1, recipient);

        return "";
    }

    function _settleOne(PoolId id, Currency currency, uint256 amount, address recipient) internal {
        if (amount == 0) return;

        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, recipient, amount);

        emit FeeCollected(id, currency, recipient, amount);
    }

    // ─── Unused IHooks callbacks ─────────────────────────────────────────
    // Every permission for these is false in `getHookPermissions()`, and
    // `Hooks.validateHookPermissions` enforces at construction that this contract's own
    // address agrees. The PoolManager therefore never calls them; they exist only to satisfy
    // the interface.

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
