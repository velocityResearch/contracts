// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../pool/PoolBrandTreasury.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {ProtocolFeeHook} from "./ProtocolFeeHook.sol";
import {PooledBrandToken} from "../pool/PooledBrandToken.sol";
import {BrandFeeVault} from "./BrandFeeVault.sol";
import {LpRewardDistributor} from "./LpRewardDistributor.sol";
import {MarketDeployer} from "./MarketDeployer.sol";

/// @title AssetMarketFactory
/// @notice Registry and one-transaction creation of **asset markets**: a trading venue for an
///         asset that already exists on chain, quoted in a stablecoin whose float yield pays
///         that market's liquidity providers.
///
///         Nothing about the asset is minted here. A tokenized equity, or a memecoin that
///         graduated on someone else's launchpad, is brought by whoever approved it and this
///         contract never touches its supply. What gets created is the quote side and the
///         plumbing: a brand on `SharedReservePool` — the market's **unit** — a real Uniswap v4
///         pool for the pair, a `BrandFeeVault` that becomes that brand's treasury admin, and
///         the `LpRewardDistributor` the vault pays.
///
/// ## One market per asset per reserve, and brands that are representations
///
///         **A market's quote token is the market's own, not a creator's.** Every market opened
///         here creates a fresh `PooledBrandToken` and pairs the pool with that. Creator brands
///         registered through `registerBrand` never get a pool of their own: they are
///         *representations*, 1:1 claims on the same reserve that convert into a market's unit
///         for free through `SharedReservePool.swap` at the router boundary. So a hundred
///         communities can quote, hold and settle in their own dollar while trading against one
///         pool.
///
///         **`marketOfAsset` enforces one market per (reserve, asset).** Without it, every
///         brand that wanted to trade NVDA would open its own thin NVDA pool and the liquidity
///         that is supposed to be shared would be split a hundred ways — which is the exact
///         problem the representation model exists to solve. A second market for the same pair
///         in the same reserve reverts. The *same* asset in a different reserve is allowed and
///         is a different market: a Morpho-backed dollar and a bridge-backed one are not the
///         same claim, and pretending otherwise would hide a redemption cost inside a trade.
///
/// ## Creation is permissionless; the asset list is not
///
///         **Anyone may open a market for an approved asset, and nobody may list an asset.**
///         `approveAsset` is the owner's call and carries every economic parameter — the fee
///         tier, the starting price, the unit's name and symbol, the oracle depth — so a
///         creator chooses nothing but the moment. That split is what makes permissionless
///         creation safe under the uniqueness rule above: if the parameters travelled with the
///         caller, the first caller could take the only NVDA slot with a nonsense fee tier or a
///         nonsense price and there would be nothing to do but retire it.
///
///         It also bounds what the venue lists. A launchpad graduate can be approved
///         deliberately; a token minted five minutes ago to be dumped into a shared pool
///         cannot list itself.
///
///         `revokeAsset` stops new markets and touches nothing that already trades.
///         `retireMarket` clears the uniqueness slot so a replacement can be created after a
///         bad approval — the old pool keeps trading so its LPs can leave.
///
/// ## Where a market's income goes
///
///         **All of the float, less the protocol's share, goes to the market's liquidity
///         providers.** The brand's reserves earn in the reserve's yield source, the vault
///         harvests that, takes `protocolBps` (zero by default) off the top and streams the
///         rest through `LpRewardDistributor`, weighted by liquidity × time. A market's
///         trading skim is separate and is the protocol's: `ProtocolFeeHook` takes it in
///         `afterSwap`, off the swap's unspecified leg, and pays the protocol treasury
///         directly.
///
///         **The buyback is gone.** Earlier markets spent their float buying the traded asset
///         and locking it forever, through a `BuybackEngine` and an `AssetLockbox` that no
///         longer exist. Liquidity is what a market needs first, and paying for it directly
///         beats paying for it through a price.
contract AssetMarketFactory is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    GuardedUpgradeable
{
    using Math for uint256;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ─── Limits ──────────────────────────────────────────────────────────

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Ceiling on what the protocol may take from any market's float, ever. A market's
    ///         own share is fixed in its vault at creation, so this bounds what a future owner
    ///         can set for future markets — existing markets are untouchable either way.
    uint16 public constant MAX_PROTOCOL_BPS = 2_000;

    /// @dev Growing a pool's observation buffer costs gas linear in the target. Capped so a
    ///      mistyped parameter fails cheaply instead of burning a block's worth of gas.
    uint16 public constant MAX_OBSERVATION_CARDINALITY = 4_000;

    /// @notice Absolute floor on the observation buffer, regardless of what an approval asks
    ///         for.
    ///
    ///         A v4 pool's oracle is born holding one seeded entry — enough for spot, useless
    ///         for `observe`. Growing the buffer is not optional, so an approval's cardinality
    ///         is raised to at least `minObservationCardinality` rather than honoured as given.
    ///         `increaseObservationCardinalityNext` on the hook is permissionless and not bound
    ///         by anything here, so a market can always be deepened further without coming
    ///         through this factory.
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 32;

    /// @notice Floor on how long one LP reward period may run for. A period shorter than this
    ///         pays out fast enough that "liquidity × time" stops being a meaningful weight.
    uint32 public constant MIN_REWARDS_DURATION = 1 hours;

    /// @dev Uniswap V3's price bounds. A starting price outside them cannot be initialised.
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    // ─── Wiring ──────────────────────────────────────────────────────────

    /// @notice The reserve a brand is pooled in when the caller names none.
    ///
    ///         **A factory serves several reserves, not one.** Each reserve is a separate
    ///         strategy — Morpho on this chain, or sUSDai behind a bridge — and a market is a
    ///         pool between one asset and a unit drawn from one of them. What must be shared is
    ///         the underlying: `setApprovedReservePool` refuses a reserve denominated in
    ///         anything but this one's asset, because the router, the zapper, every vault and
    ///         every quote treat "the reserve asset" as one token per deployment.
    SharedReservePool public reservePool;

    /// @notice The Uniswap v4 `PoolManager` every market's pool lives in.
    ///
    ///         On Robinhood Chain this is the live singleton at a **non-canonical address**,
    ///         the same way the v3 factory is non-canonical here. It is Uniswap's own
    ///         deployment and is heavily used, so a market created by this factory sits in the
    ///         same pool manager as everything else on the chain and is reachable by anything
    ///         that already routes v4 here.
    IPoolManager public poolManager;

    /// @notice The singleton `ProtocolFeeHook` every market's pool is created with.
    ///
    ///         It does two jobs, and both are why a market's `PoolKey` names it. It skims the
    ///         protocol's share off each swap's input before the pool sees it, and it is the
    ///         pool's oracle — v4 core keeps no observations, so without a hook a market has a
    ///         spot price and nothing else, and every surface that charts one would have
    ///         nothing but the last trade.
    ///
    ///         A hook's permissions are encoded in the low bits of its address, so this is a
    ///         mined address and cannot be changed after markets exist: `PoolKey.hooks` is part
    ///         of a pool's identity, so repointing it would orphan every pool ever created.
    ProtocolFeeHook public feeHook;

    /// @notice Uniswap's canonical v4 `PositionManager`.
    /// @dev    Held here because every market's `LpRewardDistributor` is initialised with it —
    ///         the distributor takes custody of staked LP positions, so it needs the contract
    ///         that mints them. Identity-checked against `poolManager` at initialisation, the
    ///         same check `MarketRouter` makes, because a `PositionManager` bound to a different
    ///         singleton would mint positions in pools these markets know nothing about.
    IPositionManagerV4 public positionManager;

    /// @notice The beacons backing each market's two per-market contracts.
    struct MarketBeacons {
        address vault;
        address distributor;
    }

    /// @notice Fixed at initialisation and deliberately without a setter. Every market this
    ///         factory has ever opened points at these, so repointing them would move the
    ///         implementation behind live markets from here rather than through the beacon's
    ///         own timelocked owner — two routes to the same power, one of them unaudited.
    ///         Upgrading a market contract is done at the beacon.
    MarketBeacons public beacons;

    /// @notice `EXTCODEHASH` of a known-canonical tokenized equity, captured at deployment
    ///         from a live reference token rather than hardcoded.
    ///
    ///         **Why this is a sufficient test.** Every genuine Robinhood token is a 283-byte
    ///         beacon proxy, and all of them share byte-identical runtime code carrying the
    ///         beacon address (`PUSH32 0x…e10b6f6b275de231345c20d14ab812db62151b00`). Equal code
    ///         therefore implies the same beacon, and the beacon decides the implementation. An
    ///         impersonator can copy the name, the symbol, the holder count and the explorer
    ///         reputation — all of which the discovery script found in the wild — but it cannot
    ///         copy this hash without also pointing at Robinhood's beacon, at which point it is
    ///         not an impersonator.
    ///
    ///         Zero disables verification (a chain with no reference token, e.g. testnet), in
    ///         which case every market is created `verified = false`.
    bytes32 public equityCodehash;

    // ─── Protocol parameters (apply to FUTURE markets only) ──────────────

    /// @notice Prefix used to derive a brand's `logo()` when the caller supplies none.
    ///
    ///         **This exists because of an ordering problem that has no other clean fix.** The
    ///         app uploads a brand's picture to an object keyed by the token's own address, and
    ///         the upload is authorised by a signature bound to that address — but the address
    ///         does not exist until the transaction that creates the brand has been mined. A
    ///         caller therefore cannot know the URL at the moment they need to pass it, and
    ///         every brand's first launch would go on chain with an empty `logo()`.
    ///
    ///         The factory does not have that problem: by the time it has registered the brand
    ///         it holds the address. So it derives
    ///         `logoBaseURI + lowercaseHexAddress + logoSuffix` and writes that, which is
    ///         exactly the key the uploader will publish to. No second transaction, no second
    ///         signature.
    ///
    ///         Empty disables derivation. An explicit logo always wins, and a brand's operator
    ///         can overwrite either afterwards — the factory hands the metadata authority over
    ///         before it returns.
    string public logoBaseURI;

    /// @notice Extension appended to a derived logo URL. Typically ".png".
    string public logoSuffix;

    /// @notice Fee recipient stamped into new markets' fee vaults.
    address public protocolTreasury;

    /// @notice Protocol fee stamped into new markets, as a share of float YIELD. Zero by
    ///         default: the protocol's revenue is the trading skim, and the yield belongs to
    ///         the liquidity that earned the market its depth.
    uint16 public protocolBps;

    /// @notice The trading-fee skim, in hundredths of a basis point, stamped into a new
    ///         market's pool when it is registered with `feeHook`. 1_000_000 is 100%, so
    ///         1_000 is 0.10% — the same units Uniswap uses for `PoolKey.fee`, deliberately,
    ///         so the two read on the same scale.
    ///
    ///         This is the protocol's cut of TRADING, and it is separate from `protocolBps`,
    ///         which is the protocol's cut of a market's float YIELD.
    ///
    ///         Changing it moves future markets only. The hook's owner can move a live
    ///         market's rate afterwards, within the hook's own ceiling; it can never move
    ///         where that market's fees go.
    uint24 public protocolFeePips;

    /// @notice How long one LP reward period runs for in new markets, in seconds. Fixed in
    ///         that market's distributor at creation.
    uint32 public rewardsDuration;

    /// @notice The oracle buffer floor stamped into new markets, in slots.
    ///
    ///         **This is a number the product chose, not one a mechanism demands.** It used to
    ///         be derived from the buyback's TWAP window, because a buffer too shallow for that
    ///         window made the buyback unrunnable. The buyback is gone and nothing on chain
    ///         needs the history any more — the consumers are the application's price chart and
    ///         `ProtocolFeeHook.consultTick` — so the depth is set here rather than computed,
    ///         and set high enough that deleting the buyback does not quietly shorten every
    ///         market's chart.
    uint16 public minObservationCardinality;

    // ─── The asset list ──────────────────────────────────────────────────

    /// @notice Everything about a market except which reserve it is in, fixed by the owner
    ///         before anyone can create it.
    struct AssetListing {
        /// @notice False blocks new markets for this asset. Existing ones keep trading.
        bool approved;
        /// @notice Uniswap fee tier. Determines tick spacing through `tickSpacingForFee`.
        uint24 fee;
        /// @notice Starting price of ONE WHOLE asset unit, in WHOLE unit-token units, scaled
        ///         by 1e18. An equity at $154 is `154e18`.
        ///
        ///         Deliberately NOT a `sqrtPriceX96`. That value depends on which of the two
        ///         tokens is `token0`, which depends on the unit token's address — and the unit
        ///         does not exist until the transaction that creates the market deploys it, so
        ///         anyone computing the sqrt price off-chain would be guessing at an ordering
        ///         they cannot know, and guessing wrong prices the pool at the reciprocal. The
        ///         factory knows the ordering by the time it prices the pool, so it takes a
        ///         plain human price and derives the rest.
        ///
        ///         **Refresh it before a launch.** An approval that has sat for months prices
        ///         the pool at a stale number, and the first liquidity in is arbitraged to the
        ///         real price. `approveAsset` may be called again at any time; it moves later
        ///         creations only.
        uint256 assetPriceE18;
        /// @notice Observation buffer to grow the pool to. Raised to
        ///         `minObservationCardinality` when lower, including when zero.
        uint16 observationCardinality;
        /// @notice The market unit's ERC-20 name, e.g. "NVDA Market Dollar".
        string unitName;
        /// @notice The market unit's ERC-20 symbol, e.g. "NVDA.d".
        ///
        ///         **It should read as a system token.** Sellers who take payout in the unit,
        ///         and LPs who claim rewards in it, end up holding this in their wallet; a
        ///         symbol that looks like a community's own coin would misrepresent what it is.
        string unitSymbol;
    }

    mapping(address asset => AssetListing listing) private _listings;

    /// @notice Every asset ever approved, in approval order. Includes assets later revoked —
    ///         read `assetListing(asset).approved` for the live answer.
    address[] public listedAssets;
    mapping(address asset => bool seen) private _everListed;

    // ─── Registry ────────────────────────────────────────────────────────

    struct Market {
        /// @notice The pre-existing asset being traded. Never minted or controlled by us.
        address asset;
        /// @notice The market's unit: the `PooledBrandToken` its pool is quoted in.
        address brandToken;
        /// @notice That unit's `PoolBrandTreasury`. Its admin is `feeVault`.
        address treasury;
        /// @notice The market's `BrandFeeVault`: where its float yield lands.
        address feeVault;
        /// @notice The market's `LpRewardDistributor`: where the vault sends the LP share, and
        ///         where a staked LP position lives.
        address lpDistributor;
        /// @notice The market's Uniswap v4 pool. A v4 pool has no address — it is a key
        ///         hashed into an id inside the singleton `PoolManager` — so this is the id,
        ///         and `poolKeyOf` rebuilds the key that produced it.
        bytes32 poolId;
        uint24 fee;
        /// @notice Tick spacing, part of the pool's identity in v4. Derived from `fee` by
        ///         `tickSpacingForFee`, keeping v3's mapping so nothing has to relearn it.
        int24 tickSpacing;
        /// @notice Whoever called `createMarket`. Attribution only: it carries no authority
        ///         over the market, because there is nothing about a market to steer.
        address creator;
        /// @notice The asset passed `isCanonicalEquity`. False for memecoins and for anything
        ///         that failed — it is a statement about bytecode provenance, nothing more,
        ///         and is never a judgement about whether a market is worth trading.
        bool verified;
        uint64 createdAt;
        /// @notice The reserve this market's unit is pooled in.
        address reservePool;
    }

    /// @dev 1-indexed. Id 0 means "no market".
    mapping(uint256 => Market) private _markets;
    uint256 public marketCount;

    /// @notice The one market for a (reserve, asset) pair. Zero means none, which is what
    ///         `createMarket` requires and what `retireMarket` restores.
    mapping(address reservePool => mapping(address asset => uint256 marketId)) public marketOfAsset;

    /// @notice The market a unit belongs to. Zero for every representation brand, which is the
    ///         check a surface listing creator brands wants: a brand with no market is a
    ///         wallet-facing dollar, not a venue.
    mapping(address brandToken => uint256 marketId) public marketOfBrand;

    /// @notice A unit's `BrandFeeVault`. Zero for representation brands.
    mapping(address brandToken => address feeVault) public feeVaultOfBrand;

    /// @notice The operator recorded for a brand this factory registered: the address that
    ///         holds its metadata authority and, for a representation brand, its treasury.
    ///
    ///         Zero means this factory never registered the brand. A brand registered directly
    ///         on `SharedReservePool` is in exactly that state.
    mapping(address brandToken => address operator) public brandOperatorOf;

    /// @notice A brand's `PoolBrandTreasury`, recorded when this factory registers it.
    mapping(address brandToken => address treasury) public treasuryOfBrand;

    mapping(bytes32 poolId => uint256 marketId) public marketOfPool;

    /// @notice Every market ever created for an asset, across reserves and including retired
    ///         ones. At most one per reserve is live; see `marketOfAsset`.
    mapping(address asset => uint256[] marketIds) private _marketsOfAsset;

    /// @notice Reserves this factory may register brands in, besides `reservePool`.
    ///
    ///         Owner-managed rather than permissionless: a reserve decides where a brand's
    ///         backing actually sits and how quickly a holder can leave it, so listing one is
    ///         a governance statement about a strategy, not a convenience. The default reserve
    ///         is always usable and is deliberately not in here.
    mapping(address reservePool => bool) public approvedReservePool;

    /// @notice The reserve each brand this factory registered was pooled in.
    mapping(address brandToken => address reservePool) public reserveOfBrand;

    /// @notice The launchpad's graduation module: the one address that may open a market for
    ///         an asset without an owner approval, because the asset was minted by the
    ///         launchpad itself and its listing terms are the launchpad's to set.
    ///
    ///         Zero disables the path, which is also the state every proxy deployed before
    ///         this field existed wakes up in. Appended before `__gap` so no earlier slot moves.
    address public launchpad;

    /// @dev Room for later versions to add state.
    uint256[39] private __gap;

    // ─── Events ──────────────────────────────────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed asset,
        address indexed creator,
        address brandToken,
        address treasury,
        address feeVault,
        address lpDistributor,
        bytes32 poolId,
        uint24 fee,
        bool verified,
        uint160 sqrtPriceX96
    );
    event BrandRegistered(
        address indexed brandToken, address indexed treasury, address indexed operator
    );
    /// @notice The reserve a market's unit draws on. Emitted beside `MarketCreated` rather
    ///         than folded into it: that event's signature is what every indexer filters on,
    ///         and a market's reserve is readable from `market(id)` regardless.
    event MarketReserve(uint256 indexed marketId, address indexed reservePool);
    event MarketRetired(uint256 indexed marketId, address indexed asset, address reservePool);
    event AssetApproved(
        address indexed asset, uint24 fee, uint256 assetPriceE18, string unitName, string symbol
    );
    event AssetRevoked(address indexed asset);
    event ReserveApprovalUpdated(address indexed reservePool, bool approved);
    event ProtocolParamsUpdated(address protocolTreasury, uint16 protocolBps);
    event ProtocolFeePipsUpdated(uint24 pips);
    event RewardsDurationUpdated(uint32 seconds_);
    event MinObservationCardinalityUpdated(uint16 slots);
    event LogoTemplateUpdated(string baseURI, string suffix);
    event BrandLogoDerived(address indexed brandToken, string logo);
    event LaunchpadUpdated(address launchpad);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error AssetHasNoCode();
    error AssetIsBrandToken();
    error AssetNotApproved(address asset);
    error AssetAlreadyHasMarket(address reservePool, address asset, uint256 marketId);
    error PoolAlreadyRegistered();
    error PoolAlreadyInitialised(address asset, address brandToken);
    error UnknownMarket();
    error UnknownBrand();
    error ProtocolFeeTooHigh();
    error OwnershipCannotBeRenounced();
    error ProtocolShareLeavesLpsNothing();
    error CardinalityTooHigh();
    error CardinalityTooLow();
    error RewardsDurationTooShort();
    error HookManagerMismatch(address reported, address expected);
    error PositionManagerMismatch(address reported, address expected);
    error UnsupportedFeeTier(uint24 fee);
    error ZeroAmount();
    error PriceOutOfRange();
    error ReserveNotApproved(address reservePool);
    error ReserveAssetMismatch(address reserveAsset, address expected);
    error EmptyUnitMetadata();
    error OnlyLaunchpad();
    /// @notice A brand this factory never registered, so it has no recorded reserve and no
    ///         operator to ask.
    error BrandNotRegistered(address brand);
    /// @notice Only a dollar's operator may hand it to a market as that market's currency.
    error NotBrandOperator(address brand);

    // ─── Construction ────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @param _referenceEquity A live canonical tokenized equity whose codehash becomes the
    ///                         verification target. Pass `address(0)` to disable verification.
    /// @param _beacons The two per-market beacons: vault and distributor. Held here rather than
    ///                 passed per call so a market cannot be created against a beacon of the
    ///                 caller's choosing.
    function initialize(
        SharedReservePool _reservePool,
        IPoolManager _poolManager,
        ProtocolFeeHook _feeHook,
        IPositionManagerV4 _positionManager,
        address _protocolTreasury,
        address _referenceEquity,
        uint16 _protocolBps,
        uint32 _rewardsDuration,
        uint16 _minObservationCardinality,
        address _owner,
        MarketBeacons memory _beacons,
        address _guard
    ) external initializer {
        if (
            address(_reservePool) == address(0) || address(_poolManager) == address(0)
                || address(_feeHook) == address(0) || address(_positionManager) == address(0)
                || _protocolTreasury == address(0)
        ) revert ZeroAddress();

        // Identity-check the hook against the pool manager rather than trusting the address
        // handed to the initialiser. A hook bound to a different manager would be accepted by
        // `PoolKey` and then never called, leaving every market with no fee and no oracle.
        if (address(_feeHook.poolManager()) != address(_poolManager)) {
            revert HookManagerMismatch(address(_feeHook.poolManager()), address(_poolManager));
        }

        // Same reasoning for the periphery: a `PositionManager` on another singleton would mint
        // positions no market here could recognise, and every distributor would refuse them.
        address posmManager = _positionManager.poolManager();
        if (posmManager != address(_poolManager)) {
            revert PositionManagerMismatch(posmManager, address(_poolManager));
        }

        if (_beacons.vault == address(0) || _beacons.distributor == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Guarded_init(_guard);

        reservePool = _reservePool;
        poolManager = _poolManager;
        feeHook = _feeHook;
        positionManager = _positionManager;
        protocolTreasury = _protocolTreasury;
        beacons = _beacons;

        _setProtocolBps(_protocolBps);
        _setRewardsDuration(_rewardsDuration);
        _setMinObservationCardinality(_minObservationCardinality);

        // A reference with no code yields 0, which `isCanonicalEquity` reads as "disabled".
        equityCodehash = _referenceEquity == address(0) ? bytes32(0) : _referenceEquity.codehash;
    }

    /// @notice Always reverts. This contract is the only thing that can approve an asset,
    ///         register the launchpad, approve a second reserve, or move the protocol's
    ///         parameters — and it is a UUPS proxy whose `_authorizeUpgrade` is `onlyOwner`.
    ///         Renouncing would freeze the implementation permanently and close the venue to
    ///         every new listing, while leaving existing markets trading with no way to fix a
    ///         defect in them. `transferOwnership` is the handover path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── The asset list ──────────────────────────────────────────────────

    /// @notice Approve an asset for trading, with the parameters every market of it will be
    ///         created under. Call again to change them; later creations only.
    function approveAsset(address asset, AssetListing calldata listing) external onlyOwner {
        _validateListing(asset, listing);

        AssetListing memory l = listing;
        l.approved = true;
        _listings[asset] = l;

        if (!_everListed[asset]) {
            _everListed[asset] = true;
            listedAssets.push(asset);
        }

        emit AssetApproved(asset, l.fee, l.assetPriceE18, l.unitName, l.unitSymbol);
    }

    /// @dev The terms a market may be created under, checked wherever they enter: the owner's
    ///      `approveAsset`, and the launchpad's `createLaunchMarket`. Reverts `UnsupportedFeeTier`
    ///      on a tier with no spacing, and `ZeroAmount` on a price of zero — at the listing,
    ///      where whoever supplied the terms can fix them, rather than at creation time.
    function _validateListing(address asset, AssetListing calldata listing) private view {
        if (asset == address(0)) revert ZeroAddress();
        if (asset.code.length == 0) revert AssetHasNoCode();
        if (bytes(listing.unitName).length == 0 || bytes(listing.unitSymbol).length == 0) {
            revert EmptyUnitMetadata();
        }
        if (listing.observationCardinality > MAX_OBSERVATION_CARDINALITY) {
            revert CardinalityTooHigh();
        }
        tickSpacingForFee(listing.fee);
        if (listing.assetPriceE18 == 0) revert ZeroAmount();
    }

    /// @notice Stop new markets for an asset. Markets that already exist keep trading, keep
    ///         earning and keep paying their LPs — delisting an asset out from under live
    ///         liquidity would be a rug with extra steps.
    function revokeAsset(address asset) external onlyOwner {
        _listings[asset].approved = false;
        emit AssetRevoked(asset);
    }

    function assetListing(address asset) external view returns (AssetListing memory) {
        return _listings[asset];
    }

    function listedAssetsLength() external view returns (uint256) {
        return listedAssets.length;
    }

    // ─── Brands ──────────────────────────────────────────────────────────

    /// @notice Register a branded stablecoin: a 1:1 representation of the reserve that its
    ///         holder can pay with, be paid in, and hold.
    ///
    ///         **A representation brand never gets a pool.** It reaches every market through
    ///         the reserve's exact 1:1 swap, which is what keeps one asset's liquidity in one
    ///         place. Nothing here opens a market; `createMarket` always mints the unit itself.
    ///
    ///         Permissionless, like the `SharedReservePool.registerBrand` it wraps. The brand's
    ///         treasury admin is handed to the operator before this returns, so the float
    ///         earned on balances held in the brand is theirs to claim from the first block.
    ///
    ///         This overload writes no description or socials. It does NOT leave the token
    ///         without a picture: `logoBaseURI` still derives one, and the operator keeps the
    ///         right to rewrite all three strings afterwards.
    function registerBrand(string calldata name, string calldata symbol)
        external
        returns (address brandToken, address treasury)
    {
        return _registerBrand(
            name,
            symbol,
            msg.sender,
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            reservePool,
            false
        );
    }

    /// @notice Register a branded stablecoin and stamp its description, logo URL and socials
    ///         onto the token itself. The caller keeps the right to rewrite them.
    function registerBrand(
        string calldata name,
        string calldata symbol,
        PooledBrandToken.Metadata calldata metadata
    ) external returns (address brandToken, address treasury) {
        return _registerBrand(name, symbol, msg.sender, metadata, reservePool, false);
    }

    /// @notice Register a branded stablecoin in a named reserve group.
    ///
    ///         Same call as the overload above, with the strategy made explicit: the brand is
    ///         pooled in `reserve` and redeems under that reserve's rules. `reserve` must be
    ///         the default or an `approvedReservePool`.
    function registerBrand(
        string calldata name,
        string calldata symbol,
        PooledBrandToken.Metadata calldata metadata,
        address reserve
    ) external returns (address brandToken, address treasury) {
        return _registerBrand(name, symbol, msg.sender, metadata, _resolveReserve(reserve), false);
    }

    /// @param retainTreasuryAdmin Keep this factory as the brand's treasury admin, which only
    ///                            `createMarket` does — it hands the admin to the market's
    ///                            vault a few lines later, in the same transaction.
    function _registerBrand(
        string memory name,
        string memory symbol,
        address operator,
        PooledBrandToken.Metadata memory metadata,
        SharedReservePool reserve,
        bool retainTreasuryAdmin
    ) private returns (address brandToken, address treasury) {
        if (operator == address(0)) revert ZeroAddress();

        // Registered with THIS factory as the metadata admin, not the operator, purely so the
        // next few lines can write a derived logo. The authority is handed to the operator
        // before this function returns, and the factory never holds it again.
        (brandToken, treasury) =
            reserve.registerBrand(name, symbol, address(this), metadata, address(this));

        // Fill in the logo the caller could not have known. See `logoBaseURI`.
        if (bytes(metadata.logo).length == 0 && bytes(logoBaseURI).length != 0) {
            metadata.logo = string.concat(logoBaseURI, Strings.toHexString(brandToken), logoSuffix);
            PooledBrandToken(brandToken).setMetadata(metadata);
            emit BrandLogoDerived(brandToken, metadata.logo);
        }

        // The operator keeps the metadata authority from here: a logo is hosted content that
        // rots, and an issuer who must redeploy their stablecoin to repoint an image URL will
        // not bother. That authority reaches the three strings and nothing else — it cannot
        // mint, burn, touch the treasury, or move the peg.
        PooledBrandToken(brandToken).handOverMetadataAdmin(operator);

        // **And the treasury, unless a market is about to take it.** A representation brand
        // never opens a market, so if the factory kept the admin its float would be
        // unclaimable by anyone, forever: `PoolBrandTreasury.claim` is admin-only and
        // `setAdmin` is callable only by the current admin.
        if (!retainTreasuryAdmin) PoolBrandTreasury(treasury).setAdmin(operator);

        brandOperatorOf[brandToken] = operator;
        treasuryOfBrand[brandToken] = treasury;
        reserveOfBrand[brandToken] = address(reserve);
        emit BrandRegistered(brandToken, treasury, operator);
    }

    // ─── Creation ────────────────────────────────────────────────────────

    /// @notice Open the market for an approved asset in a reserve: a fresh market unit, a real
    ///         Uniswap v4 pool for the pair, its fee vault and its LP reward distributor.
    ///
    ///         **Permissionless, and parameterless.** Everything economic comes from the
    ///         owner's approval of `asset` — fee tier, starting price, the unit's name and
    ///         symbol, the oracle depth — so the caller decides only that this market should
    ///         exist now. They are recorded as `creator` for attribution and get no authority
    ///         over the market, because there is none to give.
    ///
    ///         Reverts `AssetNotApproved` for an asset the owner has not listed, and
    ///         `AssetAlreadyHasMarket` for a pair that already has one. The same asset in a
    ///         different approved reserve is a different market and is allowed.
    ///
    /// @param reserve The reserve to draw the unit from. Zero selects the factory's default;
    ///                anything else must be an `approvedReservePool`.
    function createMarket(address asset, address reserve)
        external
        returns (
            uint256 marketId,
            address brandToken,
            address feeVault,
            address lpDistributor,
            bytes32 poolId
        )
    {
        AssetListing memory l = _listings[asset];
        if (!l.approved) revert AssetNotApproved(asset);

        SharedReservePool resolved = _resolveReserve(reserve);

        uint256 existing = marketOfAsset[address(resolved)][asset];
        if (existing != 0) {
            revert AssetAlreadyHasMarket(address(resolved), asset, existing);
        }

        (brandToken,) = _registerBrand(
            l.unitName,
            l.unitSymbol,
            msg.sender,
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            resolved,
            true
        );

        (marketId, feeVault, lpDistributor, poolId) =
            _openMarket(brandToken, msg.sender, asset, l, false);
    }

    /// @notice Open the market for an approved asset **quoted in a dollar that already exists**:
    ///         the pool's own currency is `brand`, not a unit minted for this market.
    ///
    ///         **Why this is a second entry point rather than an argument to the first.** A unit
    ///         minted for one market belongs to it: the market takes the brand's treasury, so
    ///         every cent of float behind that dollar pays that market's LPs, and
    ///         `marketOfBrand` is the one-to-one record of it. A dollar that already exists
    ///         cannot be owned that way. It is held in wallets, it may quote other markets, and
    ///         its float is the dollar's, not this pool's. So a shared quote leaves both alone:
    ///         the treasury keeps its admin, and `marketOfBrand` keeps pointing wherever it
    ///         already did — which is what `isSharedQuote` reads to tell the two apart.
    ///
    ///         The market still gets its own fee vault and its own LP reward distributor, and
    ///         they work exactly as they do anywhere else: `sweep` pays the protocol its share
    ///         and streams the rest to this pool's LPs. What differs is where the vault's income
    ///         comes from. `harvest` cannot claim a treasury this vault does not administer, so
    ///         the stream is funded by whoever holds the dollar's float deciding to fund it —
    ///         the issuer, market by market. That is a policy this contract must not invent:
    ///         splitting one dollar's float across the pools quoting it needs each pool's share
    ///         of that dollar, and a Uniswap v4 pool's balances live in the singleton where no
    ///         one can read them per pool.
    ///
    ///         **The dollar's issuer is the gate.** Quoting a market in someone's dollar makes
    ///         that dollar the settlement currency of a market they did not open, so only its
    ///         operator — or this factory's owner — may do it. Everything else is exactly
    ///         `createMarket`: the owner's listing fixes the fee, the price and the oracle
    ///         depth, and one pair in one reserve still has at most one market.
    ///
    ///         Reverts `AssetNotApproved`, `AssetAlreadyHasMarket`, `BrandNotRegistered` for a
    ///         brand this factory never registered, `NotBrandOperator` for anyone else's dollar,
    ///         and `AssetIsBrandToken` for an asset quoted in itself.
    function createMarketForBrand(address asset, address brand)
        external
        returns (uint256 marketId, address feeVault, address lpDistributor, bytes32 poolId)
    {
        AssetListing memory l = _listings[asset];
        if (!l.approved) revert AssetNotApproved(asset);

        // Registered through this factory, which is what makes the operator below meaningful and
        // the reserve below knowable. A brand registered straight on a reserve has neither.
        address reserve = reserveOfBrand[brand];
        if (reserve == address(0)) revert BrandNotRegistered(brand);
        if (msg.sender != brandOperatorOf[brand] && msg.sender != owner()) {
            revert NotBrandOperator(brand);
        }
        // The reserve has to still be one this factory opens markets in. A brand registered
        // before a reserve was retired must not become a way back into it.
        if (reserve != address(reservePool) && !approvedReservePool[reserve]) {
            revert ReserveNotApproved(reserve);
        }

        uint256 existing = marketOfAsset[reserve][asset];
        if (existing != 0) revert AssetAlreadyHasMarket(reserve, asset, existing);

        (marketId, feeVault, lpDistributor, poolId) = _openMarket(brand, msg.sender, asset, l, true);
    }

    /// @notice Whether this market is quoted in a dollar it does not own: a brand that existed
    ///         before it, whose float and metadata authority stay with its issuer.
    ///
    ///         Read from the registry rather than stored: a market that owns its unit is the one
    ///         `marketOfBrand` points at, and nothing else can be.
    function isSharedQuote(uint256 marketId) external view returns (bool) {
        return marketOfBrand[market(marketId).brandToken] != marketId;
    }

    /// @notice Open the market for an asset the launchpad created, in one transaction and
    ///         without an owner approval.
    ///
    ///         **The caller is the gate.** A launch graduates by handing its swept reserves
    ///         over to be seeded as liquidity, and the market has to exist in the same
    ///         transaction for that to be atomic — an owner approval in between would be a
    ///         governance step in the middle of a permissionless graduation. So `listing`
    ///         travels with the call and is checked exactly as `approveAsset` checks it, and
    ///         only `launchpad` may make the call. The asset never enters the asset list:
    ///         `assetListing(asset)` stays unapproved and `createMarket` still refuses it.
    ///
    ///         `creator` is recorded as the market's creator and receives the unit's metadata
    ///         authority, the way `msg.sender` does in `createMarket`: the launchpad is a
    ///         module, not a person, and the person is the launch's deployer.
    ///
    ///         Reverts `OnlyLaunchpad`, `AssetAlreadyHasMarket` and `ReserveNotApproved` as
    ///         named, and whatever `approveAsset` would have on the listing.
    function createLaunchMarket(
        address asset,
        address reserve,
        address creator,
        AssetListing calldata listing
    )
        external
        returns (
            uint256 marketId,
            address brandToken,
            address feeVault,
            address lpDistributor,
            bytes32 poolId
        )
    {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _validateListing(asset, listing);

        SharedReservePool resolved = _resolveReserve(reserve);

        uint256 existing = marketOfAsset[address(resolved)][asset];
        if (existing != 0) {
            revert AssetAlreadyHasMarket(address(resolved), asset, existing);
        }

        // `_registerBrand` refuses a zero operator, which is the `creator != 0` check.
        (brandToken,) = _registerBrand(
            listing.unitName,
            listing.unitSymbol,
            creator,
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            resolved,
            true
        );

        (marketId, feeVault, lpDistributor, poolId) =
            _openMarket(brandToken, creator, asset, listing, false);
    }

    /// @dev The one path that opens a market.
    ///
    ///      Ordering is load-bearing. The pool comes first, because the distributor records its
    ///      key. Then the vault and the distributor together, because each needs the other's
    ///      address and only one of the two links can be an initialiser argument.
    ///
    ///      `shared` says the brand existed before this market and is not its property: see
    ///      `createMarketForBrand`. It gates exactly the three writes that would claim it.
    function _openMarket(
        address brandToken,
        address creator,
        address asset,
        AssetListing memory l,
        bool shared
    ) private returns (uint256 marketId, address feeVault, address lpDistributor, bytes32 poolId) {
        if (asset == brandToken) {
            revert AssetIsBrandToken();
        }

        (PoolKey memory key, uint160 sqrtPriceX96) = _ensurePool(brandToken, asset, l);
        poolId = PoolId.unwrap(key.toId());
        if (marketOfPool[poolId] != 0) revert PoolAlreadyRegistered();

        address treasury = treasuryOfBrand[brandToken];
        SharedReservePool reserve = reserveOf(brandToken);

        // Through the library so neither contract's creation code is embedded here; see
        // `MarketDeployer` for why an external library rather than a deployer contract.
        (BrandFeeVault vault, LpRewardDistributor distributor) =
            MarketDeployer.deploy(_deployParams(reserve, treasury, brandToken, asset), key);
        feeVault = address(vault);
        lpDistributor = address(distributor);
        // The brand's single vault, for a brand that has one. A shared quote deliberately has
        // none: several markets may quote it, and no one of their vaults speaks for the dollar.
        if (!shared) feeVaultOfBrand[brandToken] = feeVault;

        // Hand the unit's yield claim over and step out of the way. From here this factory has
        // no authority over the brand at all.
        //
        // Never for a shared quote. The float behind a dollar held in wallets and quoting other
        // markets is not this pool's income, and taking the treasury would also take the
        // issuer's only way to reach it.
        if (!shared) PoolBrandTreasury(treasury).setAdmin(feeVault);

        // Point the pool's skim at the protocol treasury. The rate is per pool and the
        // recipient is re-pointable by the hook's owner through `setFeeRecipient`, so a
        // market's trading economics are governed rather than frozen at creation.
        //
        // **This is the trading fee, and it is the protocol's, not the market's.** The skim is
        // taken in `afterSwap`, off whichever leg the swap did NOT name: the OUTPUT of an
        // exact-input swap, the INPUT of an exact-output one. So on an ordinary exact-input
        // buy it arrives as the market's own asset, and on an exact-input sell as the unit.
        // That is the reverse of the old `beforeSwap` input-skim, and it is deliberate: only
        // `afterSwap` sees the delta the pool actually produced, so a partial fill is charged
        // on the fill rather than on notional that never traded. Both currencies accrue as
        // ERC-6909 claims and are swept to the treasury by `collect`.
        feeHook.registerPool(key, protocolTreasury, protocolFeePips);

        // Then, and only then, grow the oracle. The buffer belongs to the hook, and
        // `registerPool` is what opens it — growing an unregistered pool reverts
        // `NotInitialized`, so this call cannot be hoisted up next to pool creation where it
        // would read more naturally.
        //
        // A ring of one is overwritten by the very next swap, so an ungrown market has a price
        // history reaching back to its last trade and no further.
        uint16 floor = minObservationCardinality;
        uint16 target = l.observationCardinality < floor ? floor : l.observationCardinality;
        feeHook.increaseObservationCardinalityNext(key, target);

        marketId = _record(
            brandToken, feeVault, lpDistributor, treasury, asset, key, creator, sqrtPriceX96
        );

        // The brand-to-market record, which only a market that owns its unit may claim. Written
        // here rather than in `_record` because `shared` cannot travel there: that function is
        // already at the stack limit this contract keeps splitting functions to stay under, and
        // `isSharedQuote` reads exactly this write to tell the two kinds of market apart.
        if (!shared) marketOfBrand[brandToken] = marketId;
    }

    /// @dev Assembles the market deployer's arguments. Split out purely to keep `_openMarket`
    ///      under the stack limit — every field here is read straight from storage.
    function _deployParams(
        SharedReservePool reserve,
        address treasury,
        address brandToken,
        address asset
    ) private view returns (MarketDeployer.Params memory p) {
        MarketBeacons memory b = beacons;

        p = MarketDeployer.Params({
            reservePool: reserve,
            treasury: treasury,
            brandToken: brandToken,
            asset: asset,
            protocolTreasury: protocolTreasury,
            protocolBps: protocolBps,
            positionManager: positionManager,
            rewardsDuration: rewardsDuration,
            vaultBeacon: b.vault,
            distributorBeacon: b.distributor,
            factory: address(this),
            guard: address(guard())
        });
    }

    /// @dev Write the registry entry and announce it.
    function _record(
        address brandToken,
        address feeVault,
        address lpDistributor,
        address treasury,
        address asset,
        PoolKey memory key,
        address creator,
        uint160 sqrtPriceX96
    ) private returns (uint256 marketId) {
        bytes32 poolId = PoolId.unwrap(key.toId());
        address reserve = address(reserveOf(brandToken));

        marketId = ++marketCount;
        _markets[marketId] = Market({
            asset: asset,
            brandToken: brandToken,
            treasury: treasury,
            feeVault: feeVault,
            lpDistributor: lpDistributor,
            poolId: poolId,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            creator: creator,
            verified: isCanonicalEquity(asset),
            createdAt: uint64(block.timestamp),
            reservePool: reserve
        });
        marketOfAsset[reserve][asset] = marketId;
        // `marketOfBrand` is written by `_openMarket`: see the note there.
        marketOfPool[poolId] = marketId;
        _marketsOfAsset[asset].push(marketId);

        emit MarketCreated(
            marketId,
            asset,
            creator,
            brandToken,
            treasury,
            feeVault,
            lpDistributor,
            poolId,
            key.fee,
            _markets[marketId].verified,
            sqrtPriceX96
        );
        emit MarketReserve(marketId, reserve);
    }

    /// @dev Initialise the market's v4 pool at the approval's price.
    ///
    ///      **A pool that already exists is refused, never adopted.** For a market that mints
    ///      its own unit the case is impossible: the unit was created in this very transaction
    ///      by `SharedReservePool`, so nobody could have keyed a pool on it — there is no
    ///      front-run to tolerate and no price band to check, which is why both are gone.
    ///
    ///      For a market quoted in a dollar that already exists the case is reachable: anyone
    ///      can initialise that key first, at any price they like. Refusing is still the answer.
    ///      Adopting a pool someone else priced would open the market at their number instead of
    ///      the owner's listing, and the first liquidity in would be arbitraged to whichever is
    ///      wrong. The cost is that such a key can be squatted to block a market; the remedy is
    ///      another fee tier, which is a different key.
    function _ensurePool(address brandToken, address asset, AssetListing memory l)
        private
        returns (PoolKey memory key, uint160 sqrtPriceX96)
    {
        key = _poolKey(brandToken, asset, l.fee, tickSpacingForFee(l.fee));

        (uint160 existing,,,) = poolManager.getSlot0(key.toId());
        if (existing != 0) revert PoolAlreadyInitialised(asset, brandToken);

        sqrtPriceX96 = quoteSqrtPriceX96(brandToken, asset, l.assetPriceE18);
        poolManager.initialize(key, sqrtPriceX96);
    }

    /// @notice Free the uniqueness slot a market holds, so a replacement can be created after a
    ///         corrected approval.
    ///
    ///         **The old pool keeps trading.** Nothing here touches the market's record, its
    ///         pool, its vault or its distributor: its LPs can still collect, unstake and
    ///         withdraw, and its holders can still sell. What changes is that it is no longer
    ///         *the* market for that pair, so the application delists it and the next
    ///         `createMarket` succeeds. Retiring a market cannot strand anyone, which is why it
    ///         is a one-line owner action rather than a migration.
    function retireMarket(uint256 marketId) external onlyOwner {
        Market memory m = market(marketId);
        if (marketOfAsset[m.reservePool][m.asset] == marketId) {
            delete marketOfAsset[m.reservePool][m.asset];
        }
        emit MarketRetired(marketId, m.asset, m.reservePool);
    }

    // ─── Pool identity ───────────────────────────────────────────────────

    /// @notice The tick spacing a fee tier gets.
    ///
    ///         In v3 this was the factory's business and a pool could not be created with any
    ///         other pairing. In v4 tick spacing is just a field in the `PoolKey`, so the same
    ///         two tokens at the same fee can exist many times over at different spacings. That
    ///         freedom is not useful here and would fragment a market's liquidity across pools
    ///         that look identical to a user, so this factory pins one spacing per tier — and
    ///         pins v3's, so that every tool, chart and mental model built against the old
    ///         pools still reads correctly.
    ///
    ///         **0.50% is the one tier v3 never had, and it is this product's default.** A
    ///         market's headline fee is 1%: this tier charges 0.50% of the input, and
    ///         `ProtocolFeeHook` then takes 0.50% of the output the pool produced. There
    ///         is no v3 spacing to inherit, so it gets 50 — between 0.30%'s 60 and 0.05%'s 10,
    ///         and a divisor of 10 like every other entry here.
    function tickSpacingForFee(uint24 fee) public pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3_000) return 60;
        if (fee == 5_000) return 50;
        if (fee == 10_000) return 200;
        revert UnsupportedFeeTier(fee);
    }

    /// @notice Rebuild the `PoolKey` for a market, which is what every v4 call needs.
    function poolKeyOf(uint256 marketId) public view returns (PoolKey memory) {
        Market memory m = _markets[marketId];
        if (m.brandToken == address(0)) revert UnknownMarket();
        return _poolKey(m.brandToken, m.asset, m.fee, m.tickSpacing);
    }

    function _poolKey(address brandToken, address asset, uint24 fee, int24 tickSpacing)
        private
        view
        returns (PoolKey memory)
    {
        (address currency0, address currency1) =
            brandToken < asset ? (brandToken, asset) : (asset, brandToken);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(feeHook))
        });
    }

    // ─── Pricing ─────────────────────────────────────────────────────────

    /// @notice The `sqrtPriceX96` that prices one whole `asset` at `assetPriceE18` whole unit
    ///         units, for the (brandToken, asset) pair in Uniswap's own token ordering.
    ///
    ///         Exposed so a UI can preview the starting price of a market before creating it,
    ///         and so the derivation is testable on its own rather than only through a pool.
    ///
    /// @dev    `sqrtPriceX96 = sqrt(P) * 2^96` where `P` is raw token1 per raw token0. Written
    ///         as `sqrt(P * 2^192)` so the ratio and the scaling are squared together and the
    ///         square root is taken exactly once, at full width — halving it into
    ///         `sqrt(P) * 2^96` would throw away every bit below 1 in `P`, and for a
    ///         6-decimal stable against an 18-decimal asset `P` is on the order of 1e-10.
    function quoteSqrtPriceX96(address brandToken, address asset, uint256 assetPriceE18)
        public
        view
        returns (uint160)
    {
        if (assetPriceE18 == 0) revert ZeroAmount();

        uint256 brandUnit = 10 ** IERC20Metadata(brandToken).decimals();
        uint256 assetUnit = 10 ** IERC20Metadata(asset).decimals();

        // One whole asset (assetUnit raw) is worth assetPriceE18/1e18 whole unit tokens,
        // i.e. assetPriceE18 * brandUnit / 1e18 raw unit.
        uint256 numerator;
        uint256 denominator;
        if (brandToken < asset) {
            // token0 = unit, token1 = asset: P = raw asset per raw unit.
            numerator = assetUnit * 1e18;
            denominator = assetPriceE18 * brandUnit;
        } else {
            // token0 = asset, token1 = unit: P = raw unit per raw asset.
            numerator = assetPriceE18 * brandUnit;
            denominator = assetUnit * 1e18;
        }

        uint256 ratioX192 = numerator.mulDiv(1 << 192, denominator);
        uint256 sqrtPrice = Math.sqrt(ratioX192);

        if (sqrtPrice < MIN_SQRT_RATIO || sqrtPrice >= MAX_SQRT_RATIO) revert PriceOutOfRange();
        return uint160(sqrtPrice);
    }

    // ─── Verification ────────────────────────────────────────────────────

    /// @notice Whether `token` is a canonical Robinhood tokenized equity, by bytecode identity.
    ///         See `equityCodehash` for why this test is sufficient and what it does not claim.
    function isCanonicalEquity(address token) public view returns (bool) {
        bytes32 target = equityCodehash;
        if (target == bytes32(0)) return false;
        if (token.code.length == 0) return false;
        return token.codehash == target;
    }

    // ─── Reserve groups ──────────────────────────────────────────────────

    /// @notice The reserve a brand this factory registered is pooled in.
    function reserveOf(address brandToken) public view returns (SharedReservePool) {
        address recorded = reserveOfBrand[brandToken];
        return recorded == address(0) ? reservePool : SharedReservePool(recorded);
    }

    /// @notice List or delist a reserve this factory may register brands in.
    ///
    ///         **The asset check is the invariant the rest of the stack rests on.** The router,
    ///         the zapper and every market's vault hold one reserve asset address and quote
    ///         every market in it. A reserve denominated in anything else would make
    ///         `MarketRouter.asset` wrong for half the markets and is refused here, where the
    ///         mistake is cheap, rather than discovered by a trade that pulls the wrong token.
    ///
    ///         Delisting stops new brands and new markets. It does not touch markets already
    ///         created against the reserve.
    function setApprovedReservePool(address pool, bool approved) external onlyOwner {
        if (pool == address(0)) revert ZeroAddress();
        if (approved) {
            address reserveAsset = address(SharedReservePool(pool).asset());
            address expected = address(reservePool.asset());
            if (reserveAsset != expected) revert ReserveAssetMismatch(reserveAsset, expected);
        }
        approvedReservePool[pool] = approved;
        emit ReserveApprovalUpdated(pool, approved);
    }

    /// @dev The reserve a creation call names, or the default when it names none.
    function _resolveReserve(address requested) private view returns (SharedReservePool) {
        if (requested == address(0) || requested == address(reservePool)) return reservePool;
        if (!approvedReservePool[requested]) revert ReserveNotApproved(requested);
        return SharedReservePool(requested);
    }

    // ─── Protocol parameters ─────────────────────────────────────────────

    /// @notice Name the launchpad module that may call `createLaunchMarket`. Zero disables the
    ///         path; markets it already opened are ordinary markets and are untouched.
    function setLaunchpad(address launchpad_) external onlyOwner {
        launchpad = launchpad_;
        emit LaunchpadUpdated(launchpad_);
    }

    /// @notice Set the template used to derive a brand's `logo()` when its creator supplies
    ///         none. Pass empty strings to stop deriving logos entirely.
    ///
    ///         Existing brands are untouched: a logo is written once, at registration, into
    ///         the token's own storage. Changing this moves future brands only.
    function setLogoTemplate(string calldata baseURI, string calldata suffix) external onlyOwner {
        logoBaseURI = baseURI;
        logoSuffix = suffix;
        emit LogoTemplateUpdated(baseURI, suffix);
    }

    /// @notice Set the trading-fee skim stamped into future markets. Existing markets keep
    ///         the rate they were created with unless the hook's own owner changes it.
    function setProtocolFeePips(uint24 pips) external onlyOwner {
        if (pips > feeHook.MAX_FEE_PIPS()) revert ProtocolFeeTooHigh();
        protocolFeePips = pips;
        emit ProtocolFeePipsUpdated(pips);
    }

    /// @notice Update the protocol's treasury and its share of float yield, for FUTURE markets.
    ///         A live market holds its split in its own vault and is unaffected — an operator's
    ///         economics cannot be changed underneath them after they have committed capital.
    function setProtocolParams(address _protocolTreasury, uint16 _protocolBps) external onlyOwner {
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        protocolTreasury = _protocolTreasury;
        _setProtocolBps(_protocolBps);
    }

    /// @notice Set the LP reward period length stamped into FUTURE markets.
    function setRewardsDuration(uint32 seconds_) external onlyOwner {
        _setRewardsDuration(seconds_);
    }

    /// @notice Set the oracle buffer floor stamped into FUTURE markets.
    function setMinObservationCardinality(uint16 slots) external onlyOwner {
        _setMinObservationCardinality(slots);
    }

    function _setProtocolBps(uint16 _protocolBps) private {
        if (_protocolBps > MAX_PROTOCOL_BPS) revert ProtocolFeeTooHigh();
        // The LP subsidy is the reason a market exists, so it keeps a share whatever the
        // protocol's fee is set to. `BrandFeeVault` enforces the same bound on its own storage;
        // this is the copy that stops a bad parameter before a market is born holding it.
        if (_protocolBps >= BPS_DENOMINATOR) revert ProtocolShareLeavesLpsNothing();
        protocolBps = _protocolBps;
        emit ProtocolParamsUpdated(protocolTreasury, _protocolBps);
    }

    function _setRewardsDuration(uint32 seconds_) private {
        if (seconds_ < MIN_REWARDS_DURATION) revert RewardsDurationTooShort();
        rewardsDuration = seconds_;
        emit RewardsDurationUpdated(seconds_);
    }

    function _setMinObservationCardinality(uint16 slots) private {
        if (slots < MIN_OBSERVATION_CARDINALITY) revert CardinalityTooLow();
        if (slots > MAX_OBSERVATION_CARDINALITY) revert CardinalityTooHigh();
        minObservationCardinality = slots;
        emit MinObservationCardinalityUpdated(slots);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function market(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.brandToken == address(0)) revert UnknownMarket();
    }

    /// @notice The live market for a (reserve, asset) pair, or zero. Reverts nothing: a caller
    ///         asking whether a pair is taken wants an answer, not an exception.
    function marketFor(address reserve, address asset) external view returns (uint256) {
        address resolved = reserve == address(0) ? address(reservePool) : reserve;
        return marketOfAsset[resolved][asset];
    }

    /// @notice Every market ever created for `asset`, across reserves, retired ones included.
    function marketsOfAsset(address asset) external view returns (uint256[] memory) {
        return _marketsOfAsset[asset];
    }

    function marketsOfAssetLength(address asset) external view returns (uint256) {
        return _marketsOfAsset[asset].length;
    }
}
