// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

// Not reachable through the `v4-core/` remapping, which points at `lib/v4-core/src/`. The
// library lives one directory up in the same checkout and imports the same `FullMath` and
// `FixedPoint96` every other v4 type here does, so this is the same v4-core, not a second copy.
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IPermit2, IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {AssetMarketFactory} from "./AssetMarketFactory.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {ReentrancyGuardSlot} from "../upgrade/ReentrancyGuardSlot.sol";

/// @title LiquidityZapper
/// @notice Provide liquidity to any asset market holding nothing but USDG — or nothing but ETH —
///         in one transaction.
///
///         `MarketRouter.seedLiquidity` needs both sides of the pool, and the asset side is the
///         problem: this market may be the only place that token trades, so "go and buy some
///         first" is an errand with its own slippage, its own approvals, and its own chance to be
///         abandoned halfway. That errand is what this contract does, inside the deposit — mint
///         the USDG into the market's brand, swap part of it for the asset through the market's
///         own pool, and mint a full-range position out of both sides.
///
/// ## The ETH door, and why it is the same contract
///
///         Most wallets arriving here hold the chain's native ETH and no USDG at all, so "zap
///         with USDG alone" still asks for an errand first. `zapLiquidityWithEth` removes it:
///         wrap `msg.value`, sell the WETH for the reserve asset through Uniswap **v3**, and join
///         the USDG path at the point it already starts from. Nothing downstream of that sale
///         knows which door was used.
///
///         It is a second entry point rather than a second contract because the whole of the zap
///         is downstream of it. A separate `EthZapper` would have to hold the USDG it bought, pass
///         it on, and forward the LP NFT's recipient — three seams that exist only to keep two
///         deployments apart, when one entry point and one shared internal path keeps them
///         together.
///
///         The v3 leg is bounded on its own terms, with `minUsdgOut`, because it is priced
///         somewhere this contract cannot see, and that bound is declared to `SwapRouter02` as
///         well as re-checked here. The v4 leg inside the market is bounded by `minLiquidity`
///         instead, for the reason `zapLiquidity` gives: the finished position is the only thing
///         that measures what the caller actually got. Neither bound may be zero.
///
/// ## Why this is a separate contract and not a function on `MarketRouter`
///
///         Because it can be, and a deployed contract that does not have to change should not.
///         The zap is **entirely unprivileged**: `SharedReservePool.mint` takes USDG from whoever
///         calls it, `PoolManager.unlock` is open to anyone, and `ProtocolFeeHook` declares every
///         liquidity permission false — it hooks swaps only — so any address may add to these
///         pools through Uniswap's canonical `PositionManager`. Nothing here needs a role, an
///         allowlist, or a line of storage in the router.
///
///         Keeping it separate still buys something now that it is a proxy of its own: the
///         router carries the whole trading surface, and a zapper defect should be fixable
///         without re-verifying, re-auditing or re-pointing anything that trades.
///
/// ## Why it works on markets that already exist
///
///         There is no registration step and no per-market state. Every call reads
///         `factory.market(marketId)` and `factory.poolKeyOf(marketId)` fresh, which is the same
///         source `MarketRouter` reads and the same source the factory itself writes. So this
///         contract works on every market that exists today, every market created after it, and
///         markets whose brand token was deployed long before it — without redeploying any of
///         them and without anyone opting in.
///
/// ## Owned and upgradeable, reversing an earlier decision
///
///         The first deployment of this contract (0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd) was
///         deliberately ownerless and un-upgradeable, on the argument that it holds no funds
///         between calls, keeps no user state and has no privileged action to protect, so an
///         admin key over it would be a liability with nothing to guard. That argument was
///         sound about custody and wrong about maintenance, and the cost came due: it shipped
///         accepting `minLiquidity = 0` and `minUsdgOut = 0` while telling Uniswap v3
///         `amountOutMinimum: 0`, so both doors could be sandwiched, and with no owner and no
///         proxy there was nothing to turn, nothing to upgrade and nothing to halt. The only
///         available remedy for a one-line defect was a redeployment and a frontend cutover.
///         An admin key is a risk that can be managed; an un-fixable live contract is not.
///
///         **What that costs, stated plainly.** This contract keeps standing Permit2 allowances
///         so `PositionManager` can charge it (see below), and an upgradeable implementation
///         means the owner can replace the code those allowances sit behind. The allowances are
///         claims on zero — every path ends holding nothing — so the exposure is not a balance
///         but a window: an upgrade could add code that pulls a token a caller approved to this
///         address in the same transaction it is spent. That is the trade taken knowingly, and
///         it is bounded by the owner being the protocol timelock, by `Ownable2Step` making a
///         handover a two-sided act, and by `renounceOwnership` reverting so the
///         implementation can never be frozen with a defect in it again.
///
///         **Pausing now reaches this contract directly, and that is the point.** Every entry
///         point is `whenNotPaused` against the shared `ProtocolGuard`, so `pauseTarget` can
///         halt the zap alone. The old design relied on `SharedReservePool.mint` being
///         `whenNotPaused` to stop a zap at its first step, which is true but far too blunt:
///         stopping a zapper meant stopping every mint in the protocol. The inherited stop still
///         applies; this one is the scalpel that was missing.
///
/// ## What it never does
///
///         It never holds a position, never takes a fee, and never keeps a remainder. The LP NFT
///         is minted with `msg.sender` as recipient, and whatever the pool could not use goes home
///         in the same transaction — the stable side redeemed back to USDG, the asset side as
///         asset. Withdrawal is Uniswap's own flow against the NFT, exactly as for a position
///         seeded through `MarketRouter`; this contract is not on the exit path at all.
///
/// ## Why an ineffective bound is refused rather than replaced by a protocol-set one
///
///         Both doors reject a zero bound outright: `minLiquidity == 0` on either door and
///         `minUsdgOut == 0` on the ETH door are `ZeroLiquidityBound` and `ZeroSaleBound`, not
///         defaults. A caller who declines to say what they will accept is not opting out of
///         slippage protection, they are handing a searcher the whole deposit, and the first
///         deployment let them.
///
///         The alternative considered was an owner-settable maximum slippage in bps, checked
///         against the pool's own spot price. It was rejected, and not on gas. **The pool's spot
///         price cannot price this deposit**: a zap deliberately buys the asset side out of the
///         pool it is about to join, so the position is minted at a price the caller themselves
///         just moved, net of the LP fee and the hook's cut of the output. A bound derived from
///         spot would therefore have to model the caller's own impact to be correct, and the
///         two failures of not doing so are both bad: set tight, it rejects an honest large zap
///         into a thin pool, which is the ordinary case for a young market; set loose enough
///         not to, it permits exactly the sandwich it was added to prevent. It also puts a
///         governance dial on a path that holds no protocol funds, which is the one criticism
///         the original ownerless design was right about.
///
///         The caller, by contrast, has the number already. They quoted the swap to choose
///         `swapBps`; `minLiquidity` is that quote minus their tolerance. Requiring them to
///         state it is the whole fix, and it costs one comparison.
///
///         `minUsdgOut` is additionally passed to `SwapRouter02` as `amountOutMinimum` rather
///         than only re-checked afterwards, so a bad v3 fill reverts inside the venue before any
///         of this contract's state or the reserve's is touched. The local check stays as well:
///         the router bounds what it believes it sent, and the local one bounds what actually
///         arrived, which are different numbers for a token that taxes transfers, and only the
///         latter is what the deposit is built from.
contract LiquidityZapper is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    GuardedUpgradeable,
    ReentrancyGuardSlot,
    IUnlockCallback
{
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev v4-periphery action ids, copied from `lib/v4-periphery/src/libraries/Actions.sol`
    ///      rather than imported, for the same reason `IPositionManagerV4` is hand-written: that
    ///      file lives in a checkout with its own copy of v4-core. They are part of
    ///      `PositionManager`'s ABI, so they are as stable as the function selector itself.
    uint8 private constant ACTION_MINT_POSITION = 0x02;
    uint8 private constant ACTION_SETTLE_PAIR = 0x0d;

    // ─── Wiring ──────────────────────────────────────────────────────────
    //
    // Storage rather than `immutable`, because this is a proxy: an `immutable` lives in the
    // implementation's bytecode and would have to be re-supplied, identically, by every future
    // implementation — a silent way for an upgrade to repoint the whole contract. Written once
    // in `initialize` and never again.
    //
    // Everything derivable is still derived, for the reason `MarketRouter` gives: on this chain
    // a copy-pasted periphery address has already been found to hold an unrelated contract, and
    // an initialiser argument is a second place for an address to be wrong.
    //
    // LAYOUT. Base contracts contribute nothing here: `Initializable`, `Ownable2StepUpgradeable`
    // and `GuardedUpgradeable` all keep their state at ERC-7201 slots, `ReentrancyGuardSlot`
    // keeps its flag at a fixed one, and `UUPSUpgradeable` has no state at all. So these fields
    // begin at slot 0 and occupy slots 0 through 8 in the order written below. Nothing may be
    // inserted among them; a new field goes in `__gap`'s place at slot 9 and the gap shrinks by
    // exactly as much, which is why the gap is declared last and sized with room to spare.

    /// @notice The reserve a market uses when its record names none. One factory serves
    ///         several reserve groups and they all share one underlying, so a zap resolves
    ///         the reserve per market and only falls back to this one for a market recorded
    ///         before the factory could hold more than one.
    SharedReservePool public reservePool; // slot 0
    AssetMarketFactory public factory; // slot 1
    IPositionManagerV4 public positionManager; // slot 2
    IPermit2 public permit2; // slot 3

    /// @notice The v4 singleton, read off the factory that initialised these pools.
    IPoolManager public poolManager; // slot 4

    /// @notice The reserve's underlying — what a zap is paid in (e.g. USDG).
    IERC20 public asset; // slot 5

    /// @notice Uniswap v3's `SwapRouter02`, where ETH is sold for the reserve asset. Zero on a
    ///         deployment with no v3 venue, which disables the ETH door and nothing else.
    ISwapRouter02 public swapRouter; // slot 6

    /// @notice The wrapper `swapRouter` accepts, read off it rather than configured. Zero exactly
    ///         when `swapRouter` is.
    IWETH9 public weth; // slot 7

    /// @dev Which tokens have already been approved token → Permit2 → PositionManager. Both
    ///      allowances are unlimited and never expire, so they are set once per token rather than
    ///      on every zap. Standing permissions over nothing: this contract never holds a balance
    ///      between calls, so an allowance over its balance is an allowance over zero. What an
    ///      upgrade could do with them is argued in the contract note.
    mapping(address token => bool) public approvedThroughPermit2; // slot 8

    // ─── Events ──────────────────────────────────────────────────────────

    /// @param usdgIn      What the provider handed over.
    /// @param assetBought What the internal swap returned, before the mint took its share.
    ///                    `assetUsed` is what reached the pool; the difference went back.
    event LiquidityZapped(
        uint256 indexed marketId,
        address indexed provider,
        uint256 indexed tokenId,
        uint256 usdgIn,
        uint256 assetBought,
        uint128 liquidityAdded,
        uint256 brandUsed,
        uint256 assetUsed
    );

    /// @notice The ETH door's first leg, emitted before the `LiquidityZapped` it feeds.
    ///
    ///         Kept separate rather than folded into `LiquidityZapped` so that event keeps meaning
    ///         one thing — what the market received — whichever door the deposit came through.
    ///         `usdgOut` here is the `usdgIn` there.
    /// @param ethRefunded What the v3 router declined to spend, returned as ETH. Zero in every
    ///                    ordinary fill; an exact-input swap consumes all of its input.
    event EthSwappedForReserveAsset(
        address indexed provider, uint256 ethIn, uint256 usdgOut, uint24 fee, uint256 ethRefunded
    );

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error OnlyPoolManager();
    error PoolNotInitialized();
    error NoLiquidity();
    error PoolManagerMismatch(address posmPoolManager, address factoryPoolManager);
    error AmountTooLarge();
    error InvalidSwapShare(uint256 swapBps);
    error InsufficientLiquidityMinted(uint128 minted, uint128 minimum);
    error EthZapUnavailable();
    error EthNotAccepted();
    error EthRefundFailed();
    error InsufficientAssetFromEth(uint256 bought, uint256 minimum);
    error OwnershipCannotBeRenounced();
    /// @notice `minLiquidity` was zero, which is not a slippage bound but the absence of one.
    error ZeroLiquidityBound();
    /// @notice `minUsdgOut` was zero on the ETH door, leaving the v3 sale unbounded.
    error ZeroSaleBound();

    // ─── Construction ────────────────────────────────────────────────────

    /// @dev No `immutable` to set and no state to write: everything this contract knows lives
    ///      behind the proxy and is written by `initialize`. Locking the implementation's own
    ///      initialiser keeps it from being initialised and then used directly, which for this
    ///      contract would mean a second zapper sharing the implementation's bytecode and
    ///      holding its own Permit2 allowances outside the proxy the app points at.
    constructor() {
        _disableInitializers();
    }

    /// @notice Always reverts. This is a UUPS proxy and `_authorizeUpgrade` is `onlyOwner`, so
    ///         renouncing would freeze the implementation permanently — which is exactly the
    ///         condition the first, ownerless deployment was stuck in and the reason this one
    ///         exists. Ownership is handed over with `transferOwnership`, never dropped.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @param _swapRouter Uniswap v3 `SwapRouter02`, the venue for the ETH leg. **Optional.**
    ///                    Pass the zero address on a chain with no v3 deployment: every USDG zap
    ///                    works unchanged and `zapLiquidityWithEth` reverts `EthZapUnavailable`
    ///                    rather than half-working. WETH is read off it, never passed in.
    /// @param _owner      The protocol timelock. Holds the upgrade key and nothing else: there is
    ///                    no fee to set, no parameter to tune and no balance to sweep here.
    /// @param _guard      The shared `ProtocolGuard`, which is what makes `pauseTarget` able to
    ///                    stop this contract alone.
    function initialize(
        SharedReservePool _reservePool,
        AssetMarketFactory _factory,
        IPositionManagerV4 _positionManager,
        IPermit2 _permit2,
        ISwapRouter02 _swapRouter,
        address _owner,
        address _guard
    ) external initializer {
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Guarded_init(_guard);

        if (
            address(_reservePool) == address(0) || address(_factory) == address(0)
                || address(_positionManager) == address(0) || address(_permit2) == address(0)
        ) {
            revert ZeroAddress();
        }

        reservePool = _reservePool;
        factory = _factory;
        positionManager = _positionManager;
        permit2 = _permit2;
        poolManager = IPoolManager(address(_factory.poolManager()));
        asset = IERC20(address(_reservePool.asset()));

        if (address(poolManager) == address(0)) revert ZeroAddress();

        // A `PositionManager` bound to some other PoolManager would happily accept a mint and put
        // it in a pool that is not this market's. Cheaper to be unable to initialise the
        // mismatch than to detect it from a user's reverted zap. Checked here rather than in the
        // constructor because the constructor no longer sees any of this: behind a proxy the
        // initialiser is the only place a wiring mistake can still be refused.
        address posmPoolManager = _positionManager.poolManager();
        if (posmPoolManager != address(poolManager)) {
            revert PoolManagerMismatch(posmPoolManager, address(poolManager));
        }

        // Derived, not declared: the wrapper this contract wraps into has to be the one the router
        // it sells through will accept, and asking the router is the only way to know that. A
        // router answering with the zero address is a router this cannot swap through, so it is
        // refused here rather than at a user's first ETH zap.
        swapRouter = _swapRouter;
        if (address(_swapRouter) != address(0)) {
            address wrapper = _swapRouter.WETH9();
            if (wrapper == address(0)) revert ZeroAddress();
            weth = IWETH9(wrapper);
        }
    }

    /// @notice Accept ETH from the wrapper alone.
    /// @dev    `WETH9.withdraw` pays out with a bare `transfer`, so this has to exist for a
    ///         refund to land. Nothing else has a reason to send ETH here: a zap's ETH arrives as
    ///         `msg.value` on the payable entry point, and this contract holds no balance between
    ///         calls, so a plain transfer in would be a donation with no way back out. Refusing it
    ///         is the honest answer.
    receive() external payable {
        if (msg.sender != address(weth)) revert EthNotAccepted();
    }

    // ─── Zap ─────────────────────────────────────────────────────────────

    /// @notice Whether this deployment can take ETH.
    /// @dev    One read for an interface deciding whether to offer the ETH field at all, so the
    ///         answer comes from the contract rather than from a second environment variable that
    ///         can disagree with it.
    function supportsEthZaps() external view returns (bool) {
        return address(swapRouter) != address(0);
    }

    /// @notice Add full-range liquidity to a market holding nothing but USDG, buying the asset
    ///         side on the way in, and hand the caller the Uniswap LP NFT.
    ///
    /// @dev    **The caller pays the price impact of their own swap, and that is the point.**
    ///         Buying the asset moves the pool, and the position is then minted at the moved
    ///         price — so the two sides are in the ratio the pool asks for at the moment of the
    ///         mint rather than at the moment the transaction was signed. A thin pool therefore
    ///         makes an expensive zap, and `minLiquidity` is where the caller says how much of
    ///         that they will accept. It is the only protection here worth having — bounding the
    ///         swap's output alone would not bound what the position is finally worth — which is
    ///         why it is required rather than defaulted: zero reverts `ZeroLiquidityBound`.
    ///
    ///         **A full-range position is 50/50 by value at any price**, because its bounds sit
    ///         at zero and infinity, so half is the split that leaves the least behind and
    ///         `swapBps` defaults to that if the caller has nothing better. It is a parameter
    ///         rather than a constant because the fee and the impact both bite the asset side,
    ///         so the balancing split is always a little under half and a caller who has quoted
    ///         the swap can say so. Whatever the mint declines is refunded either way — the brand
    ///         side redeemed back to USDG, the asset side as asset.
    ///
    ///         An empty pool cannot be zapped into: the swap fills nothing, there is no asset
    ///         side, and that is `NoLiquidity` rather than a silent single-sided add. Seed such a
    ///         market with `MarketRouter.seedLiquidity` instead, which is what a market's first
    ///         liquidity always is.
    ///
    /// @param swapBps      Basis points of the minted brand to spend on the asset, 1–9999.
    ///                     Pass 5000 for a straight half.
    /// @param minLiquidity Revert unless the position is minted with at least this many
    ///                     liquidity units. The caller's slippage bound, and mandatory: zero is
    ///                     the absence of a bound, not a request to skip it.
    function zapLiquidity(
        uint256 marketId,
        uint256 usdgIn,
        uint256 swapBps,
        uint128 minLiquidity,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed)
    {
        if (usdgIn == 0) revert ZeroAmount();
        // Before the transfer, not only in `_zap`, so an unbounded call never takes custody of
        // the caller's USDG on its way to reverting. Same reasoning as the ETH door, which
        // checks both bounds before it wraps a wei.
        if (minLiquidity == 0) revert ZeroLiquidityBound();
        asset.safeTransferFrom(msg.sender, address(this), usdgIn);
        return _zap(marketId, usdgIn, swapBps, minLiquidity, deadline);
    }

    /// @notice The same deposit, paid for in the chain's native ETH.
    ///
    /// @dev    The ETH is wrapped and sold for the reserve asset through Uniswap v3, and the
    ///         proceeds go straight into the path `zapLiquidity` takes. So a caller needs neither
    ///         the market's asset nor USDG nor the brand — only ETH and one signature.
    ///
    ///         **This leg has its own bound and needs one.** The v3 pool is priced outside
    ///         anything this contract can read, so `minUsdgOut` is where the caller says what the
    ///         sale must return; `minLiquidity` downstream cannot cover it, because a bad sale
    ///         produces less of *everything* and a proportionally smaller position still satisfies
    ///         a bound set in liquidity units. Quote the sale, then bound it — and it is required,
    ///         not defaulted: zero reverts `ZeroSaleBound` before a wei is wrapped.
    ///
    ///         `fee` picks the v3 pool. It is a parameter because tiers differ by orders of
    ///         magnitude in depth and only the caller knows which they quoted — on Robinhood Chain
    ///         mainnet the 0.01% WETH/USDG pool is by far the deepest, and a zap that silently
    ///         used the 1% pool would pay for the difference.
    ///
    ///         What the router declines to spend comes back as ETH in the same transaction, and
    ///         what the *market* declines comes back as USDG and asset, exactly as for the USDG
    ///         door. The stable remainder is deliberately not sold back into ETH: it is dust by
    ///         construction, and round-tripping it through two pools would cost more in fees and
    ///         gas than the dust is worth.
    ///
    /// @param fee        The v3 fee tier of the WETH/asset pool to sell through, in hundredths of
    ///                   a bip — 100, 500, 3000 or 10000.
    /// @param minUsdgOut Revert unless the sale returns at least this much of the reserve asset.
    ///                   Mandatory. It is declared to `SwapRouter02` as `amountOutMinimum` too,
    ///                   so a bad fill fails inside the venue rather than being discovered after.
    function zapLiquidityWithEth(
        uint256 marketId,
        uint24 fee,
        uint256 minUsdgOut,
        uint256 swapBps,
        uint128 minLiquidity,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed)
    {
        if (address(swapRouter) == address(0)) revert EthZapUnavailable();
        if (msg.value == 0) revert ZeroAmount();
        // Both bounds are checked before the sale, not only in `_zap`, because everything
        // between here and there spends the caller's ETH: an unbounded zap should cost them
        // nothing but gas, exactly as an expired deadline does.
        if (minUsdgOut == 0) revert ZeroSaleBound();
        if (minLiquidity == 0) revert ZeroLiquidityBound();
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 usdgIn = _sellEthForAsset(fee, minUsdgOut);
        return _zap(marketId, usdgIn, swapBps, minLiquidity, deadline);
    }

    /// @dev The zap proper, from the point the reserve asset is already held by this contract.
    ///      Both doors meet here, so there is one description of what a zap does rather than two
    ///      that can drift.
    function _zap(
        uint256 marketId,
        uint256 usdgIn,
        uint256 swapBps,
        uint128 minLiquidity,
        uint256 deadline
    )
        private
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (usdgIn == 0) revert ZeroAmount();
        // Where both doors are held to the bound, so neither can reach a mint without one.
        if (minLiquidity == 0) revert ZeroLiquidityBound();
        if (swapBps == 0 || swapBps >= 10_000) revert InvalidSwapShare(swapBps);

        // Read fresh, every call. This is what makes the contract work on markets that existed
        // before it did: the factory is the record, and nothing is cached here.
        AssetMarketFactory.Market memory m = factory.market(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        SharedReservePool reserve =
            m.reservePool == address(0) ? reservePool : SharedReservePool(m.reservePool);
        asset.forceApprove(address(reserve), usdgIn);
        uint256 brandAmount = reserve.mint(m.brandToken, usdgIn, address(this));

        uint256 swapIn = (brandAmount * swapBps) / 10_000;
        if (swapIn == 0) revert ZeroAmount();

        // Held here rather than sent to the caller and pulled back: the position is minted out of
        // this contract's balance in the same call. No bound is declared on this hop because the
        // one that matters is on the position — `minLiquidity`, checked below — and a bound here
        // would only turn a moved price into a revert after the mint had already been paid for.
        // It is not an unbounded leg: nothing between this swap and that check can be observed
        // or interrupted by anyone else, so a sandwich has to beat the position bound to profit.
        (uint256 assetBought, uint256 swapSpent) =
            _swapExactIn(key, m.brandToken, m.asset, swapIn, address(this));
        if (assetBought == 0) revert NoLiquidity();

        uint256 brandLeft = brandAmount - swapSpent;

        // Measured across the mint, not taken from what `PositionManager` was asked for. The
        // amounts it pulls through Permit2 are what the requested liquidity is worth at the live
        // price; the balances are what actually left this contract, and for an asset with a
        // transfer tax those are different numbers.
        uint256 brandBefore = IERC20(m.brandToken).balanceOf(address(this));
        uint256 assetBefore = IERC20(m.asset).balanceOf(address(this));

        (tokenId, liquidityAdded) =
            _mintPosition(key, m.brandToken < m.asset, brandLeft, assetBought, deadline);

        brandUsed = brandBefore - IERC20(m.brandToken).balanceOf(address(this));
        assetUsed = assetBefore - IERC20(m.asset).balanceOf(address(this));

        if (liquidityAdded < minLiquidity) {
            revert InsufficientLiquidityMinted(liquidityAdded, minLiquidity);
        }

        _refund(m.brandToken, brandLeft - brandUsed, m.asset, assetBought - assetUsed);

        emit LiquidityZapped(
            marketId, msg.sender, tokenId, usdgIn, assetBought, liquidityAdded, brandUsed, assetUsed
        );
    }

    // ─── PoolManager callback ────────────────────────────────────────────

    /// @notice The PoolManager calling back into an unlock this contract opened.
    /// @dev    Swaps only. Liquidity goes through `PositionManager`, which opens its own unlock.
    ///
    ///         The swap settles from the **delta the operation returned**, never from the amount
    ///         that was asked for; the two coincide only when the pool filled completely.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (PoolKey, bool, uint256));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                // Negative is exact-input. There is no price limit: the caller's protection is
                // `minLiquidity` on the finished position, and a limit here would turn slippage
                // into a silent partial fill instead of a bound that is actually checked.
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        _settleDelta(key, delta);
        return "";
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev Wrap `msg.value` and sell it for the reserve asset on Uniswap v3.
    ///
    ///      Both sides are measured on this contract's balances rather than taken from the
    ///      router's return value, for the reason every other leg here is: the number a venue
    ///      reports is what it believes it sent, and what arrived is what can be spent. They
    ///      differ for a token that taxes transfers, and the deposit is built out of the latter.
    ///
    ///      An exact-input swap consumes all of its input, so the refund path is normally dead
    ///      code. It exists because "normally" is not "always" — a router that fills partially
    ///      would otherwise leave the caller's ETH stranded in a contract that keeps nothing.
    function _sellEthForAsset(uint24 fee, uint256 minUsdgOut) private returns (uint256 bought) {
        uint256 ethIn = msg.value;

        // Read before the wrap, so `unspent` below is what this swap left behind rather than
        // anything that was already sitting here.
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 assetBefore = asset.balanceOf(address(this));

        weth.deposit{value: ethIn}();

        IERC20(address(weth)).forceApprove(address(swapRouter), ethIn);
        swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(asset),
                fee: fee,
                recipient: address(this),
                amountIn: ethIn,
                // The caller's real bound, declared to the venue. It used to be zero, with
                // `minUsdgOut` checked only below, on the reasoning that this contract's error
                // names both numbers where the router's names neither. That traded a better
                // revert message for a worse failure mode: the sale completed at any price and
                // was only rejected afterwards. Now the router refuses the fill itself, and the
                // check below still runs — see the note on it.
                amountOutMinimum: minUsdgOut,
                sqrtPriceLimitX96: 0
            })
        );
        // Never leave a standing allowance over a router: this contract holds no balance between
        // calls, but a partial fill means the approval outlives the swap that needed it.
        IERC20(address(weth)).forceApprove(address(swapRouter), 0);

        // Still checked after the fact, and not redundantly. `amountOutMinimum` bounds what the
        // router believes it sent; this bounds what actually arrived, and the two differ for a
        // reserve asset that taxes transfers. The deposit is built out of the latter, so the
        // latter is what has to clear the caller's bound.
        bought = asset.balanceOf(address(this)) - assetBefore;
        if (bought < minUsdgOut) revert InsufficientAssetFromEth(bought, minUsdgOut);

        uint256 unspent = weth.balanceOf(address(this)) - wethBefore;
        if (unspent > 0) {
            weth.withdraw(unspent);
            (bool sent,) = msg.sender.call{value: unspent}("");
            if (!sent) revert EthRefundFailed();
        }

        emit EthSwappedForReserveAsset(msg.sender, ethIn, bought, fee, unspent);
    }

    /// @dev One exact-input hop straight through the PoolManager, with both legs measured on this
    ///      contract's balances rather than taken from a return value.
    /// @return out   What this contract ended up holding, after the LP fee, the hook's cut of
    ///               the output and any tax the output token charges on the way out.
    /// @return spent How much of `amountIn` the pool actually consumed.
    function _swapExactIn(
        PoolKey memory key,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address receiver
    ) private returns (uint256 out, uint256 spent) {
        if (amountIn == 0) revert ZeroAmount();

        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        poolManager.unlock(abi.encode(key, zeroForOne, amountIn));

        spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        out = IERC20(tokenOut).balanceOf(address(this)) - outBefore;

        if (receiver != address(this)) {
            uint256 receiverBefore = IERC20(tokenOut).balanceOf(receiver);
            IERC20(tokenOut).safeTransfer(receiver, out);
            out = IERC20(tokenOut).balanceOf(receiver) - receiverBefore;
        }
    }

    /// @dev Size a full-range position against the pool's live price and mint it to `msg.sender`
    ///      through `PositionManager`. The pool has to already exist — a market's pool is
    ///      initialised by the factory at creation, so an uninitialised one means the wrong
    ///      market id, not a missing step.
    ///
    ///      `amount0Max`/`amount1Max` are `PositionManager`'s own bound and are set to exactly
    ///      what this contract brought, so the mint can never pull more than the caller handed
    ///      over. It is a ceiling, not the real protection: `minLiquidity` is, and it is checked
    ///      upstream.
    function _mintPosition(
        PoolKey memory key,
        bool brandIsCurrency0,
        uint256 brandAmount,
        uint256 assetAmount,
        uint256 deadline
    ) private returns (uint256 tokenId, uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _fullRange(key.tickSpacing);
        (uint256 amount0, uint256 amount1) =
            brandIsCurrency0 ? (brandAmount, assetAmount) : (assetAmount, brandAmount);
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountTooLarge();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        // Below one liquidity unit nothing would be deposited and every input would come straight
        // back, which is a silent no-op rather than a funded pool.
        if (liquidity == 0) revert NoLiquidity();

        _approveThroughPermit2(Currency.unwrap(key.currency0));
        _approveThroughPermit2(Currency.unwrap(key.currency1));

        bytes memory actions =
            abi.encodePacked(uint8(ACTION_MINT_POSITION), uint8(ACTION_SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            msg.sender, // the LP NFT's owner: the provider, never this contract
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        // Read immediately before the mint. `modifyLiquidities` returns nothing, so this is the
        // only way to learn the id it is about to create; `nonReentrant` plus the fact that this
        // is one external call means nothing can slip a mint in between the two.
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @dev `PositionManager` never pulls an ERC-20 with `transferFrom` on its own account — it
    ///      asks Permit2 to — so a contract that wants to be charged has to approve the token to
    ///      Permit2 *and* tell Permit2 the PositionManager may spend it.
    function _approveThroughPermit2(address token) private {
        if (approvedThroughPermit2[token]) return;
        approvedThroughPermit2[token] = true;

        IERC20(token).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    /// @dev Pay what a v4 operation left us owing and claim what it left us owed. Written as two
    ///      independent conditionals because an operation can leave either side at zero — a swap
    ///      that filled nothing leaves both — and neither leg should then move a wei.
    function _settleDelta(PoolKey memory key, BalanceDelta delta) private {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) _settle(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settle(key.currency1, uint256(uint128(-delta1)));
        if (delta0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(delta0)));
        if (delta1 > 0) poolManager.take(key.currency1, address(this), uint256(uint128(delta1)));
    }

    /// @dev The v4 ERC20 payment idiom: `sync` snapshots the manager's balance, the transfer moves
    ///      the tokens, `settle` credits the difference. An asset that taxes transfers therefore
    ///      under-delivers and `settle` reverts the whole trade rather than leaving the pool
    ///      short — which is the correct failure, not a case to work around.
    function _settle(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev The widest range this pool's spacing admits.
    function _fullRange(int24 tickSpacing) private pure returns (int24, int24) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @dev Return anything a leg left behind, each side in the token this contract is holding.
    ///
    ///      **The brand leg is not redeemed**, for the reason `MarketRouter._refund` gives: a
    ///      remainder the pool declined to take is not the provider asking to leave the
    ///      reserve, and a reserve that charges for an exit would bill them for a decision
    ///      they never made.
    function _refund(address brandToken, uint256 brandLeft, address token, uint256 assetLeft)
        private
    {
        if (brandLeft > 0) IERC20(brandToken).safeTransfer(msg.sender, brandLeft);
        if (assetLeft > 0) IERC20(token).safeTransfer(msg.sender, assetLeft);
    }

    /// @dev Reserved storage, so a later implementation can add a field without moving anything
    ///      the proxy already holds. The wiring above ends at slot 8, so this covers slots 9
    ///      through 49 and the declared footprint is a round 50.
    ///
    ///      41 is not arbitrary. There is no field this contract is expected to grow — it takes
    ///      no fee, tunes no parameter and holds no per-market state — so the gap is sized for
    ///      the cases that would be unwelcome surprises rather than for a roadmap: a second
    ///      venue's router and wrapper, a per-market override or two, a cached quote. Reserving
    ///      more costs nothing at all (a gap of zeroed slots is never written, so it is not in
    ///      the deployed state and never touched by a call), and reserving too little cannot be
    ///      fixed once a field lands past it.
    ///
    ///      **How to add a field.** Declare it immediately above this and reduce 41 by exactly
    ///      one slot's worth. Never below, never among the wiring, and never by changing a
    ///      field's type to one that packs differently.
    uint256[41] private __gap;
}
