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
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {AssetMarketFactory} from "./AssetMarketFactory.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {ReentrancyGuardSlot} from "../upgrade/ReentrancyGuardSlot.sol";

/// @title MarketRouter
/// @notice The user-facing entry point to an asset market, and the reason many branded
///         stablecoins do not fragment liquidity the way many stablecoins normally would.
///
///         A `PooledBrandToken` is a **costless wrapper of the reserve asset**: minting and
///         redeeming are exactly 1:1 with no slippage, no price, and no fee, and any two
///         brands in the same pool swap 1:1 with each other. So a trade that starts in USDG,
///         or in some *other* market's brand, can reach this market's pool by way of a
///         conversion that costs nothing but gas:
///
/// ```
/// buy   USDG   --mint 1:1-->  brandUSD  --v4 swap-->  asset
/// buy   brandY --swap 1:1-->  brandUSD  --v4 swap-->  asset
/// sell  asset  --v4 swap-->   brandUSD  (redeem 1:1 to USDG separately, if wanted)
/// ```
///
///         Crossing between quote assets here is free, unlike crossing between USDC and USDT.
///         That is what lets a market quote in its own brand — and capture the float yield on
///         the stable side of its own pool — without asking a trader to hold something
///         inconvenient.
///
///         **The AMM leg goes through the PoolManager directly, not through a router.** V4 has
///         no `exactInputSingle` to call: a swap is `unlock` → `swap` → settle the delta you
///         owe and take the delta you are owed. Doing that here rather than through a periphery
///         router removes an approval and an address that would have to be trusted for the life
///         of every market, and — as in `BuybackEngine` — it is the only way to settle from the
///         delta rather than from the amount asked for, which is the difference that decides a
///         partial fill. Nothing is ever approved to the PoolManager: v4 is paid by
///         transferring between `sync` and `settle`, so no standing permission exists over this
///         router's balance.
///
///         **The pool's hook skims the protocol fee off each swap's UNSPECIFIED leg, in
///         `afterSwap`.** Every swap this router builds is exact-input, so in practice the
///         skim comes out of the OUTPUT token: a trader's output is slightly smaller than the
///         pure curve would give. That is not netted out anywhere here and must not be:
///         `minAssetOut` / `minBrandOut` are computed against what the trader actually
///         receives, and the slippage bound is what protects them.
///
///         Off-chain quoting does NOT need to subtract the skim by hand. Because the hook
///         returns it as a delta, it is already inside the `BalanceDelta` the `PoolManager`
///         hands back, so a stock `V4Quoter` is exact and subtracting again double-counts.
///
///         **Approvals.** Approve this router for the incoming token: USDG, a brand, or the
///         traded asset. Only the mint leg needs a USDG approval of the reserve pool. Direct
///         `SharedReservePool.redeem` and `swap` calls need no approval; they burn from their
///         own caller, which is this router on a routed path.
///
///         **Amounts are measured, not assumed.** The asset is arbitrary, brought by whoever
///         created the market, and on this chain a tokenized equity is an issuer-upgradeable
///         proxy. Every asset leg reads a balance before and after rather than trusting a
///         return value, and every entry point is `nonReentrant`: a quote token with
///         transfer hooks is not a hypothetical here, it is the normal case.
///
///         **Liquidity added through this router belongs to the seeder, as a Uniswap LP NFT,
///         and this router has no withdrawal function because it does not need one.**
///         `seedLiquidity` mints the position through the canonical v4 `PositionManager` with
///         the NFT going straight to `msg.sender`, so the LP is the caller and never the
///         router. Increasing, decreasing, collecting or burning that position is then
///         Uniswap's own business, done by calling `PositionManager` directly — the same
///         contract every other v4 LP on this chain already uses. Adding a withdrawal path here
///         would only re-wrap calls the owner can already make, while giving this router a
///         reason to be trusted with positions it does not hold.
///
///         That is a change of ownership model, not just of plumbing. The earlier design called
///         `poolManager.modifyLiquidity` directly, which made the *router* the position owner —
///         one shared full-range position per market, with no way to tell the operator's float
///         from a stranger's donation and therefore no safe way to let anyone take anything
///         out. It was chosen in the belief that this chain had no v4 periphery. It does: the
///         canonical `PositionManager` and Permit2 are both live, so both are constructor
///         arguments here, and seeded liquidity is withdrawable by the person who seeded it.
///
///         **Seeding still costs an approval this router keeps forever.** `PositionManager`
///         only ever pulls ERC-20s through Permit2, so each token that reaches a pool is
///         approved once — token → Permit2, then Permit2 → PositionManager — and those
///         approvals stand for the life of the router. They are harmless because this router
///         never holds a balance between calls: every entry point refunds its remainder before
///         it returns, so a standing allowance is a standing claim on zero.
contract MarketRouter is
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

    // ─── Immutable wiring ────────────────────────────────────────────────

    /// @notice The reserve a market uses when its record names none — every market created
    ///         before `AssetMarketFactory` could serve more than one reserve.
    ///
    ///         **A market's reserve is a property of the market, not of this router.** One
    ///         factory registers brands in several reserve groups, and all of them share this
    ///         router because they share `asset`, the pool manager and the position manager.
    ///         Every leg below therefore resolves the reserve from the market record and
    ///         never from here; this is only the fallback for a record written before the
    ///         field existed.
    SharedReservePool public reservePool;
    AssetMarketFactory public factory;

    /// @notice Uniswap's canonical v4 `PositionManager`: the contract that mints the LP NFT a
    ///         seeder walks away with, and the contract they later go back to in order to
    ///         withdraw. Passed in rather than hardcoded — there is no factory to derive it
    ///         from, and a constant would be a second address to keep in sync per chain.
    IPositionManagerV4 public positionManager;

    /// @notice Canonical Permit2, the only route by which `positionManager` moves ERC-20s.
    IPermit2 public permit2;

    /// @dev Which tokens have already been approved token → Permit2 → PositionManager. The pair
    ///      of approvals is unlimited and never expires, so it is done once per token on first
    ///      use rather than on every seed: two SSTOREs a market instead of four per call.
    mapping(address token => bool) public approvedThroughPermit2;

    /// @notice The v4 singleton every swap, every position and every settlement goes through.
    /// @dev    Read off the factory rather than passed in. The old V3 router took its periphery
    ///         addresses as constructor arguments and then had to prove they belonged to the
    ///         same Uniswap deployment, because on this chain the canonical `SwapRouter` address
    ///         holds an unrelated contract and a copy-pasted constant would have `forceApprove`d
    ///         a stranger on every trade. Deriving the singleton from the factory that
    ///         initialised the pools makes that whole class of mismatch unrepresentable.
    IPoolManager public poolManager;

    /// @notice The reserve's underlying — what a market is ultimately quoted in (e.g. USDG).
    IERC20 public asset;

    // ─── Events ──────────────────────────────────────────────────────────

    event Bought(
        uint256 indexed marketId,
        address indexed buyer,
        address indexed receiver,
        address tokenIn,
        uint256 amountIn,
        uint256 assetOut
    );
    event Sold(
        uint256 indexed marketId,
        address indexed seller,
        address indexed receiver,
        uint256 assetIn,
        uint256 brandOut
    );
    event SoldForUsdg(
        uint256 indexed marketId,
        address indexed seller,
        address indexed receiver,
        uint256 assetIn,
        uint256 brandBurned,
        uint256 usdgOut
    );
    event LiquiditySeeded(
        uint256 indexed marketId,
        address indexed provider,
        uint256 indexed tokenId,
        uint128 liquidityAdded,
        uint256 brandUsed,
        uint256 assetUsed
    );

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error OwnershipCannotBeRenounced();
    error ZeroAmount();
    error InsufficientOutput(uint256 received, uint256 minimum);
    error InsufficientAmountUsed(uint256 used, uint256 minimum);
    /// @notice The token offered is not one of this market's reserve group's brands — either a
    ///         token that is no brand at all, or a brand belonging to another reserve. The two
    ///         are one rejection because they are one question: a 1:1 `SharedReservePool.swap`
    ///         only exists inside one reserve, and crossing groups means redeeming one brand
    ///         and minting the other, which is the holder's decision to make and pay for
    ///         rather than a leg to bury inside a trade.
    error BrandNotInMarketReserve(address token, address reservePool);
    error DeadlineExpired();
    error OnlyPoolManager();
    error PoolNotInitialized();
    error NoLiquidity();
    error PoolManagerMismatch(address posmPoolManager, address factoryPoolManager);
    error AmountTooLarge();

    // ─── Construction ────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @notice Always reverts. This router holds no funds between calls, but it is a UUPS
    ///         proxy and `_authorizeUpgrade` is `onlyOwner`, so renouncing would freeze its
    ///         implementation permanently — including the standing Permit2 allowances it keeps
    ///         alive for `PositionManager`, which no later deployment could withdraw or
    ///         re-scope. `transferOwnership` is the handover path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @param _positionManager Uniswap's canonical v4 `PositionManager` for this chain.
    /// @param _permit2         Canonical Permit2. Only ever handed allowances, never trusted to
    ///                         name a token or an amount, so a wrong address here fails loudly
    ///                         on the first seed rather than quietly.
    function initialize(
        SharedReservePool _reservePool,
        AssetMarketFactory _factory,
        IPositionManagerV4 _positionManager,
        IPermit2 _permit2,
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

        // Same spirit as deriving the singleton from the factory: a `PositionManager` bound to
        // some other PoolManager would happily accept a mint and put it in a pool that is not
        // this market's, on a chain where a copy-pasted periphery address has already been
        // found to hold an unrelated contract. Cheaper to be unable to deploy the mismatch.
        address posmPoolManager = _positionManager.poolManager();
        if (posmPoolManager != address(poolManager)) {
            revert PoolManagerMismatch(posmPoolManager, address(poolManager));
        }
    }

    // ─── Buy ─────────────────────────────────────────────────────────────

    /// @notice Buy the market's asset with the reserve asset (USDG).
    /// @dev    The USDG is minted into the market's brand 1:1, so it becomes float the moment
    ///         the swap parks it in the pool — which is the mechanism the whole market runs on.
    function buyWithUsdg(
        uint256 marketId,
        uint256 usdgIn,
        uint256 minAssetOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 assetOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (usdgIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        AssetMarketFactory.Market memory m = factory.market(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        asset.safeTransferFrom(msg.sender, address(this), usdgIn);
        SharedReservePool reserve = _reserveOf(m);
        asset.forceApprove(address(reserve), usdgIn);
        uint256 brandIn = reserve.mint(m.brandToken, usdgIn, address(this));

        uint256 spent;
        (assetOut, spent) = _swapExactIn(key, m.brandToken, m.asset, brandIn, minAssetOut, receiver);

        // A full-range v4 pool that ran out of liquidity mid-swap stops early and charges only
        // what it consumed. Whatever the pool declined to take is sent home rather than left
        // sitting in the router as somebody's brandUSD.
        _refund(m.brandToken, brandIn - spent, m.asset, 0);

        emit Bought(marketId, msg.sender, receiver, address(asset), usdgIn, assetOut);
    }

    /// @notice Buy the market's asset with any pooled brand token from the same reserve group —
    ///         including another market's. No approval of the reserve pool is needed; only this
    ///         router must be approved for `brandIn`.
    ///
    ///         A token this market's reserve does not know — including another group's brand —
    ///         reverts `BrandNotInMarketReserve`. Crossing
    ///         reserves is a redemption and a mint, priced by the reserve that is being left,
    ///         and folding that into a trade would hide a fee the holder never agreed to.
    function buyWithBrand(
        uint256 marketId,
        address brandIn,
        uint256 amountIn,
        uint256 minAssetOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 assetOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        AssetMarketFactory.Market memory m = factory.market(marketId);
        SharedReservePool reserve = _reserveOf(m);
        if (!reserve.isRegistered(brandIn)) {
            revert BrandNotInMarketReserve(brandIn, address(reserve));
        }

        PoolKey memory key = factory.poolKeyOf(marketId);

        IERC20(brandIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Cross to this market's brand if the caller arrived in a different one. Exactly 1:1,
        // no slippage, no price — both are flat claims on the same reserve.
        if (brandIn != m.brandToken) {
            reserve.swap(brandIn, m.brandToken, amountIn, address(this));
        }

        uint256 spent;
        (assetOut, spent) =
            _swapExactIn(key, m.brandToken, m.asset, amountIn, minAssetOut, receiver);
        _refund(m.brandToken, amountIn - spent, m.asset, 0);

        emit Bought(marketId, msg.sender, receiver, brandIn, amountIn, assetOut);
    }

    // ─── Sell ────────────────────────────────────────────────────────────

    /// @notice Sell the market's asset back to the market's own brandUSD.
    ///
    ///         **The seller is left holding brandUSD, not USDG, and that is deliberate.** It
    ///         keeps the sell side symmetric with `buyWithBrand` — a trader who arrived in a
    ///         brand can leave in it — and it never unwinds a position in the brand that a
    ///         holder may have wanted to keep, or charges them a reserve's redemption fee for a
    ///         decision they did not make. A seller who does want the reserve asset has two
    ///         doors: `SharedReservePool.redeem` themselves, at a moment they can price, or
    ///         `sellForUsdg` below, which does both legs in one transaction for a caller — an
    ///         aggregator, typically — who has already priced the exit.
    ///
    /// @return brandOut What the receiver ended up holding, measured on their own balance after
    ///         the LP fee, the curve and the hook's skim off the output — never the amount
    ///         asked for.
    function sellForBrand(
        uint256 marketId,
        uint256 assetIn,
        uint256 minBrandOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 brandOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (assetIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        AssetMarketFactory.Market memory m = factory.market(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        uint256 received = _pullMeasured(m.asset, assetIn);
        uint256 spent;
        // `minBrandOut` is enforced inside, on the receiver's measured balance, so no second
        // check is needed here — unlike the redeeming version this replaces, where the payout
        // was produced by a call made after the swap had already been bounded.
        (brandOut, spent) =
            _swapExactIn(key, m.asset, m.brandToken, received, minBrandOut, receiver);

        // The unspent side of a partial fill is the caller's own asset, so it goes back as
        // asset — there is nothing to convert it into.
        _refund(m.brandToken, 0, m.asset, received - spent);

        emit Sold(marketId, msg.sender, receiver, received, brandOut);
    }

    /// @notice Sell the market's asset and redeem the proceeds to the reserve asset in the
    ///         same transaction: the v4 swap, then `SharedReservePool.redeem`.
    ///
    ///         **Built for routers that hold the input and want one call per direction.** It
    ///         answers `buyWithUsdg` — with the difference that it takes the reserve asset
    ///         from the market's own reserve rather than this router's default, so a market
    ///         on a second reserve round-trips correctly. It exists because an aggregator
    ///         settling a USDG-denominated trade has no use for an intermediate brand
    ///         balance. The redemption fee the market's reserve charges is paid here,
    ///         knowingly: a caller who would rather keep the brand calls `sellForBrand`.
    ///
    ///         **`minUsdgOut` is handed to the reserve as well as checked here, and that is
    ///         the difference between a bad fill and a loss.** `SharedReservePool._redeem`
    ///         burns the whole amount and then pays `min(owed, what it can raise)`, retiring
    ///         the shortfall against `lossCarryforward` rather than reverting. Left to a
    ///         balance check alone, a caller whose minimum a short reserve happened to clear
    ///         would have burned brand worth more than the USDG they received, with nothing
    ///         to re-try. Passing the bound down makes an underpaying reserve revert
    ///         `InsufficientPayout`, which unwinds the burn with the transaction; a caller
    ///         who passes zero is accepting whatever the reserve can raise, knowingly.
    ///
    ///         Quote with `MarketLens.quoteSell`, which refuses exactly the sizes this does,
    ///         and size one that fits with `MarketLens.quoteSellExactOut`.
    ///
    /// @param minUsdgOut Least reserve asset the receiver must end up holding
    /// @return usdgOut   What the receiver's balance actually grew by
    function sellForUsdg(
        uint256 marketId,
        uint256 assetIn,
        uint256 minUsdgOut,
        address receiver,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 usdgOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (assetIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        AssetMarketFactory.Market memory m = factory.market(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);
        SharedReservePool reserve = _reserveOf(m);
        IERC20 reserveAsset = reserve.asset();

        uint256 received = _pullMeasured(m.asset, assetIn);
        // The brand leg lands here unbounded: the only minimum that means anything to this
        // caller is on the reserve asset, after the fee and the reserve's liquidity.
        (uint256 brandOut, uint256 spent) =
            _swapExactIn(key, m.asset, m.brandToken, received, 0, address(this));
        if (brandOut == 0) revert InsufficientOutput(0, minUsdgOut);

        uint256 receiverBefore = reserveAsset.balanceOf(receiver);
        // Burns this router's brand — no approval — and pays `receiver` directly. The bound
        // goes down with it so an underpaying reserve reverts before the burn is committed;
        // see the note on this function.
        reserve.redeem(m.brandToken, brandOut, receiver, minUsdgOut);
        // Re-checked on the receiver's own balance, because the reserve's guard runs before
        // the transfer and cannot see a reserve asset that taxes it.
        usdgOut = reserveAsset.balanceOf(receiver) - receiverBefore;
        if (usdgOut < minUsdgOut) revert InsufficientOutput(usdgOut, minUsdgOut);

        _refund(m.brandToken, 0, m.asset, received - spent);

        emit SoldForUsdg(marketId, msg.sender, receiver, received, brandOut, usdgOut);
    }

    // ─── Liquidity ───────────────────────────────────────────────────────

    /// @notice Add full-range liquidity to a market with brandUSD and the asset, and hand the
    ///         caller the Uniswap LP NFT that owns it.
    ///
    ///         **Both sides are the pool's own tokens, taken as they are.** The stable side is
    ///         the market's brandUSD, which is what the pool actually holds, so this function
    ///         deposits what it is given and mints nothing. An earlier revision took USDG and
    ///         converted it 1:1 through the reserve on the way in; that made the deposit and the
    ///         withdrawal asymmetric, since closing the position through `PositionManager`
    ///         always returns brandUSD whatever went in. Taking brandUSD directly makes the two
    ///         ends the same token.
    ///
    ///         A caller holding USDG mints brandUSD at `SharedReservePool.mint` first, 1:1 and
    ///         without a fee, and redeems it back the same way. That step is deliberately not
    ///         folded in here: it is the reserve's job, it is free, and burying it made this
    ///         function refund a token the caller never handed over.
    ///
    ///         The range is the whole curve — `minUsableTick` to `maxUsableTick` for the pool's
    ///         spacing. A market's price is discovered by the market, and a seeder is not
    ///         expected to come back and rebalance; a concentrated range would eventually fall
    ///         out of range and stop being liquidity at all.
    ///
    ///         **Anyone may call this,** and now they get something for it. The NFT goes to
    ///         `msg.sender`, so seeding someone else's market is a real position rather than a
    ///         donation, and the router keeps nothing.
    ///
    ///         **Withdrawal is not here, because it is not ours.** The caller holds an ordinary
    ///         `UNI-V4-POSM` token; `DECREASE_LIQUIDITY` and `BURN_POSITION` on
    ///         `PositionManager` are theirs to call, with the slippage bounds and the recipient
    ///         they choose. See the contract-level note.
    ///
    /// @param brandIn       brandUSD to deposit. The caller must hold it; nothing is minted.
    /// @param minBrandUsed  Revert unless at least this much brandUSD went into the pool.
    /// @param minAssetUsed  Revert unless at least this much asset went into the pool.
    /// @return tokenId        The LP NFT minted to `msg.sender`.
    /// @return liquidityAdded The liquidity units the position was minted with.
    /// @return brandUsed      brandUSD actually deposited, measured.
    /// @return assetUsed      Asset actually deposited, measured.
    function seedLiquidity(
        uint256 marketId,
        uint256 brandIn,
        uint256 assetIn,
        uint256 minBrandUsed,
        uint256 minAssetUsed,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (brandIn == 0 && assetIn == 0) revert ZeroAmount();

        AssetMarketFactory.Market memory m = factory.market(marketId);
        PoolKey memory key = factory.poolKeyOf(marketId);

        uint256 brandAmount;
        if (brandIn > 0) brandAmount = _pullMeasured(m.brandToken, brandIn);

        uint256 assetAmount;
        if (assetIn > 0) assetAmount = _pullMeasured(m.asset, assetIn);

        // Measured across the mint, not taken from what we asked `PositionManager` for. The
        // amounts it pulls through Permit2 are what the requested liquidity is worth at the
        // live price; the balances are what actually left this contract, and for an asset with
        // a transfer tax those are different numbers — the same discipline every other leg uses.
        uint256 brandBefore = IERC20(m.brandToken).balanceOf(address(this));
        uint256 assetBefore = IERC20(m.asset).balanceOf(address(this));

        (tokenId, liquidityAdded) =
            _mintPosition(key, m.brandToken < m.asset, brandAmount, assetAmount, deadline);

        brandUsed = brandBefore - IERC20(m.brandToken).balanceOf(address(this));
        assetUsed = assetBefore - IERC20(m.asset).balanceOf(address(this));

        if (brandUsed < minBrandUsed) revert InsufficientAmountUsed(brandUsed, minBrandUsed);
        if (assetUsed < minAssetUsed) revert InsufficientAmountUsed(assetUsed, minAssetUsed);

        // One side of a full-range add is always short of what the price ratio wanted; that
        // remainder is dust to the pool but real money to the caller, so it goes home — each
        // side in the token it arrived as.
        _refund(m.brandToken, brandAmount - brandUsed, m.asset, assetAmount - assetUsed);

        emit LiquiditySeeded(marketId, msg.sender, tokenId, liquidityAdded, brandUsed, assetUsed);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    /// @notice How deep a market is: the pool's liquidity at its current tick.
    /// @dev    This used to report the router's own position, back when the router was the sole
    ///         LP of every market and every seed compounded into one shared position. It is not
    ///         the LP any more — seeders hold their own NFTs, and there are as many positions in
    ///         a pool as there have been seeders — so "the router's position" no longer names
    ///         anything. What a caller wanted from it was depth, and depth is a property of the
    ///         pool, so that is what is reported now.
    ///
    ///         Every position this router mints is full range and therefore always in range, so
    ///         for a market seeded only through `seedLiquidity` this is the sum of every seed.
    ///         Liquidity added to the same pool out-of-range by some other route would not be
    ///         counted here until the price reached it, which is the correct reading of "how
    ///         deep is this market right now".
    function marketLiquidity(uint256 marketId) external view returns (uint128) {
        return poolManager.getLiquidity(factory.poolKeyOf(marketId).toId());
    }

    // ─── PoolManager callback ────────────────────────────────────────────

    /// @notice The PoolManager calling back into an unlock this router opened.
    ///
    /// @dev    Swaps only. Liquidity no longer travels this way — it goes through
    ///         `PositionManager`, which opens its own unlock and calls back into itself — so
    ///         `modifyLiquidity` is not reachable from this contract at all any more, by anyone.
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
                // Negative is exact-input. The trader's protection is `minAssetOut` /
                // `minBrandOut`, checked on what actually reaches them; a price limit here
                // would turn slippage into a silent partial fill instead of a revert.
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

    /// @dev Pull `amount` of an arbitrary token and report what actually arrived. The asset
    ///      side of a market is chosen by its operator and may not be a well-behaved ERC-20.
    function _pullMeasured(address token, uint256 amount) private returns (uint256) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        return IERC20(token).balanceOf(address(this)) - before;
    }

    /// @dev One exact-input hop straight through the PoolManager, with both legs measured on
    ///      this contract's balances rather than taken from a return value.
    /// @return out   What the receiver ended up holding, after the LP fee, the curve, the
    ///               hook's skim off the output, and any tax the output token charges on the
    ///               way out.
    /// @return spent How much of `amountIn` the pool actually consumed.
    function _swapExactIn(
        PoolKey memory key,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
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
        // Protect what the receiver actually gets, including a tax on the final transfer.
        if (out < minOut) revert InsufficientOutput(out, minOut);
    }

    /// @dev Size a full-range position against the pool's live price and mint it to `msg.sender`
    ///      through `PositionManager`. The pool has to already exist — a market's pool is
    ///      initialised by the factory at creation, so an uninitialised one means the wrong
    ///      market id, not a missing step.
    ///
    ///      Two actions, in order: `MINT_POSITION` opens the position and leaves this router
    ///      owing both currencies to the PoolManager, `SETTLE_PAIR` pays both of those debts out
    ///      of the router's balance. `SETTLE_PAIR` pays from `msg.sender` *of the
    ///      `modifyLiquidities` call*, which is this router, through Permit2 — hence the
    ///      standing approvals set just below.
    ///
    ///      `amount0Max`/`amount1Max` are `PositionManager`'s own slippage bound and are set to
    ///      exactly what this router brought, so the mint can never pull more than the caller
    ///      handed over. It is a ceiling, not the real protection: `minBrandUsed` /
    ///      `minAssetUsed` in the caller's own units are, and they are checked upstream.
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
        // Below one liquidity unit nothing would be deposited and every input would come
        // straight back, which is a silent no-op rather than a seeded market.
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
            msg.sender, // the LP NFT's owner: the seeder, never this router
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
    ///      asks Permit2 to do it — so a contract that wants to be charged has to approve the
    ///      token to Permit2 *and* tell Permit2 the PositionManager may spend it. Both are set
    ///      unlimited and non-expiring, and both are set once per token: the pair costs two
    ///      external calls and a storage write, which is worth paying on a market's first seed
    ///      rather than on every seed forever.
    ///
    ///      Standing unlimited allowances on a router are usually a smell. They are not here,
    ///      because this router is never a wallet: every entry point refunds what it did not
    ///      spend before it returns, so an allowance over its balance is an allowance over zero.
    function _approveThroughPermit2(address token) private {
        if (approvedThroughPermit2[token]) return;
        approvedThroughPermit2[token] = true;

        IERC20(token).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    /// @dev Pay what a v4 operation left us owing and claim what it left us owed. Written as
    ///      two independent conditionals because an operation can leave either side at zero —
    ///      a swap that filled nothing leaves both — and neither leg should then move a wei.
    function _settleDelta(PoolKey memory key, BalanceDelta delta) private {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        if (delta0 < 0) _settle(key.currency0, uint256(uint128(-delta0)));
        if (delta1 < 0) _settle(key.currency1, uint256(uint128(-delta1)));
        if (delta0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(delta0)));
        if (delta1 > 0) poolManager.take(key.currency1, address(this), uint256(uint128(delta1)));
    }

    /// @dev The v4 ERC20 payment idiom: `sync` snapshots the manager's balance, the transfer
    ///      moves the tokens, `settle` credits the difference. An asset that taxes transfers
    ///      therefore under-delivers and `settle` reverts the whole trade rather than leaving
    ///      the pool short — which is the correct failure, not a case to work around.
    function _settle(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev The widest range this pool's spacing admits.
    function _fullRange(int24 tickSpacing) private pure returns (int24, int24) {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @dev Return anything a leg left behind, each side in the token this router is holding.
    ///
    ///      **The brand leg is not redeemed.** It used to be, on the reading that a caller who
    ///      arrived with USDG should leave with USDG. That reading breaks once a market's
    ///      reserve can charge for an exit: a partial fill is the pool declining to trade, not
    ///      the holder deciding to leave, and redeeming their remainder would hand them
    ///      `redemptionFeeBps` less than they put in — or fail outright against a reserve whose
    ///      buffer is empty — for a decision they never made. A brand is a 1:1 claim they can
    ///      redeem whenever they choose, at a moment they can price.
    function _refund(address brandToken, uint256 brandLeft, address token, uint256 assetLeft)
        private
    {
        if (brandLeft > 0) IERC20(brandToken).safeTransfer(msg.sender, brandLeft);
        if (assetLeft > 0) IERC20(token).safeTransfer(msg.sender, assetLeft);
    }

    /// @dev The reserve a market's brand is pooled in. A record written before the factory
    ///      served more than one reserve carries zero and belongs to this router's default.
    function _reserveOf(AssetMarketFactory.Market memory m)
        private
        view
        returns (SharedReservePool)
    {
        return m.reservePool == address(0) ? reservePool : SharedReservePool(m.reservePool);
    }
}
