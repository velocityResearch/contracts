// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2LaunchFactory.sol), MIT.

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {ReentrancyGuardSlot} from "../upgrade/ReentrancyGuardSlot.sol";
import {AssetMarketFactory} from "../markets/AssetMarketFactory.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../pool/PoolBrandTreasury.sol";
import {IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";

import {LaunchToken} from "./LaunchToken.sol";
import {LaunchCurve} from "./LaunchCurve.sol";
import {LaunchDeployment, LaunchDeployer} from "./LaunchDeployer.sol";
import {LaunchGraduationGuard} from "./LaunchGraduationGuard.sol";
import {LaunchCurveMath} from "./libraries/LaunchCurveMath.sol";
import {CurveSegmentConfig, LaunchCurveSegments} from "./libraries/LaunchCurveSegments.sol";
import {LaunchGuardDeployer} from "./libraries/LaunchGuardDeployer.sol";
import {
    FeePolicySnapshot,
    GraduationPhase,
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchFeePolicy,
    ILaunchGraduation,
    ILaunchSnipeTax
} from "./interfaces/ILaunchpad.sol";

/// @dev The one thing the factory needs to know about its graduation module beyond
///      `ILaunchGraduation`: that it was built for this factory. Checked once at wiring, since
///      the wiring is one-shot and a module pointing elsewhere would refuse every phase two.
interface ILaunchGraduationWiring {
    function factory() external view returns (address);
}

/// @title LaunchFactory
/// @notice Deploys a bonding curve and its launch token for every launch, then graduates the
///         curve into an asset market opened by `AssetMarketFactory`: a real Uniswap v4 pool
///         between the token and a fresh market unit, seeded with the curve's reserves and
///         locked forever.
///
///         Every curve trades in a branded stablecoin — a brand the market factory registered
///         on one of its reserves — so the float a launch collects earns yield for that
///         brand's treasury while the curve trades, and graduation converts it into the new
///         market's unit 1:1 with no router and no price oracle. The owner opens reserves, not
///         brands: once a reserve carries `ReserveEconomics`, any dollar issued on it whose
///         issuer has opted into float sharing may quote a launch, with no approval step.
///
///         Graduation stays split into two permissionless phases so a failed market creation
///         cannot strand a curve's reserves:
///         - `graduate`: drains the curve's own reserves into this factory. Purely internal
///           bookkeeping, so it is safe to call automatically from within the crossing buy.
///         - `graduateToMarket`: hands those reserves to `LaunchGraduation`, which creates the
///           market and locks the seed. Retryable until it succeeds.
///
///         The factory is a UUPS proxy behind `ProtocolGuard` like every other singleton
///         here; curves and tokens stay immutable.
contract LaunchFactory is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    GuardedUpgradeable,
    ReentrancyGuardSlot,
    ILaunchFactory,
    ILaunchFeePolicy,
    ILaunchSnipeTax
{
    using SafeERC20 for IERC20;

    // ─── Limits ──────────────────────────────────────────────────────────

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_CURVE_FEE_BPS = 1_000; // 10%
    uint256 public constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // 10%
    uint256 public constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%
    uint256 public constant MAX_PROTOCOL_FEE_SHARE_BPS = 5_000; // 50%
    // Ceiling on the LP fund's share, of the curve fee and of both post-graduation legs. Held
    // at the same 50% as the protocol's own share, and separately bounded against it: the two
    // together may never exceed the whole fee, or the creator's remainder would underflow.
    uint256 public constant MAX_LP_FUND_SHARE_BPS = 5_000; // 50%
    // Ceiling on the launch-second snipe tax. Held below 100% so a taxed buy always nets the
    // buyer something even before the curve applies its own combined-fee bound.
    uint256 private constant MAX_SNIPE_TAX_START_BPS = 9_900; // 99%
    // Ceiling on the snipe tax decay window. Long enough to cover several blocks of sniper
    // activity on any chain this deploys to, short enough that a misconfiguration cannot
    // leave a launch effectively closed to the public for minutes.
    uint256 private constant MAX_SNIPE_TAX_SECONDS = 60;
    // Bound on the creator-declared exemption list, so a launch cannot be made unaffordable
    // to itself by an unbounded loop of exemption writes.
    uint256 private constant MAX_SNIPE_TAX_EXEMPTIONS = 32;
    // Coarsest quote asset a launch may be priced in, and the reason two rounding leaks in
    // the curve are theoretical rather than real: a fee floors, so a trade below
    // `BASIS_POINTS / curveFeeBps` base units pays nothing, and `sweepFees` is permissionless,
    // so a creator may sweep whenever the protocol's floored share is zero. Both are bounded
    // to one base unit per event, and at six decimals a base unit is $0.000001 — avoiding a
    // cent of fee costs ten thousand transactions. **That argument is the whole reason this
    // floor exists, so lowering it is not a cosmetic change**: at two decimals the same leaks
    // are worth a cent each and the curve's fee becomes optional.
    uint256 public constant MIN_PAIR_TOKEN_DECIMALS = 6;
    // Smallest supply a launch may declare, and the reference supply the quotability check
    // assumes when it runs before any config is known.
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    // The quotability check prices a buy of one millionth of the phantom reserve. Expressing
    // the reference trade as a fraction of the reserve rather than a fixed amount keeps it
    // meaningful across quote assets of different decimals.
    uint256 private constant REFERENCE_BUY_DIVISOR = 1e6;
    // Largest amount either side of a seed may carry. V4 settles pool balance changes through
    // a BalanceDelta of two int128 halves, so the signed maximum binds even though the
    // PositionManager's ABI accepts a uint128. Mirrors LaunchGraduationGuard's own ceiling.
    uint256 private constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));
    // Floor on the `assetPriceE18` a launch's graduated pool may open at. See
    // `_requireSeedPriceResolvable` for the arithmetic; `LaunchGraduation.MAX_DUST_BPS` is the
    // same bound enforced on the other side of graduation.
    uint256 private constant MIN_SEED_PRICE_E18 = 1e4;
    // How long a launch must sit in Swept before its reserves may be released manually.
    // Seeding is permissionless and retryable, so this window is what separates a genuinely
    // unseedable launch from one that merely hit a transient failure, and it denies the
    // owner a same-block escape hatch.
    uint256 public constant GRADUATION_RESCUE_DELAY = 7 days;

    // ─── Types ───────────────────────────────────────────────────────────

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        LaunchToken.Socials socials;
        address creatorFeeRecipient;
        // Additional trade tax the creator charges on top of the launch config's base
        // curveFeeBps, capped by maxCreatorTaxBps at launch time. Paid entirely to the
        // creator, never split with the protocol.
        uint16 creatorTaxBps;
        // Optional guard on the economics this launch will lock in. Zero waives the check.
        // Set it to the terms quoted at signing time so an owner re-peg can never land
        // underneath an in-flight launch. Obtain it from
        // previewLaunchEconomics(launchConfigId, pairToken); see `_economicsDigest` for the
        // preimage.
        bytes32 expectedEconomics;
        // CREATE2 salt for the launch's curve and token. The pair's addresses are derived
        // from this together with every constructor argument, so they can be computed before
        // the launch is sent and cannot be taken by a launch that lands first. Namespaced per
        // factory-authenticated initiating account, so this only has to be unique among that
        // account's own launches; mining it is how a creator chooses a vanity address.
        // Reusing a value on otherwise identical terms reverts, since the pair already exists
        // at that address. Call `predictLaunchAddresses` to check in advance.
        bytes32 salt;
    }

    /// @notice The shape of a launch that is independent of its quote asset: how much supply
    ///         it mints, what the curve charges, and which LP tier its market opens with.
    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint24 poolFee;
        bool enabled;
    }

    /// @notice Curve economics for every brand of one reserve, in the reserve asset's own
    ///         decimals. Keyed by reserve rather than by brand because a brand is a costless
    ///         1:1 wrapper of its reserve's asset, minted at the asset's own scale: every brand
    ///         of a reserve is worth the same and counts the same, so figures sized for one are
    ///         sized for all, and a dollar issued tomorrow launches on the same terms with no
    ///         approval step. The reserve is the unit of approval for the same reason. What
    ///         stays per brand is checked live at launch instead: that the market factory
    ///         registered it, and that its issuer opted into sharing float yield.
    ///
    ///         Only `graduationThreshold / (graduationThreshold + phantomQuote)` determines the
    ///         fraction of supply that reaches the graduated pool, so scaling the pair together
    ///         leaves the curve's shape untouched.
    struct ReserveEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint256 launchFee;
        uint8 decimals;
        bool approved;
    }

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error InvalidBasisPoints();
    error InvalidSnipeTaxWindow();
    error CurveFeeTooHigh();
    error CreatorTaxTooHigh();
    error CombinedFeeTooHigh();
    error SupplyTooLow();
    error SupplyTooHigh();
    error InvalidLaunchConfigId();
    error LaunchConfigDisabled();
    error LaunchDisabled();
    error LaunchDependenciesNotWired();
    error NotLaunchForwarder();
    error InvalidTokenParams();
    error ExemptionListTooLong();
    /// @notice The brand's reserve has no economics written, or the owner has closed it to new
    ///         launches.
    error ReserveClosed(address reserve);
    error ReserveEconomicsInvalid();
    error PairTokenNotRegistered(address pairToken, address reserve);
    /// @notice The brand's treasury has not named the market factory, so a market quoted in
    ///         it would earn nothing on the float it locks. The issuer opts in with
    ///         `PoolBrandTreasury.setFactory`.
    error PairTokenFloatShareUnavailable(address pairToken);
    error ReserveNotApproved(address reserve);
    error SeedPriceTooCoarse(uint256 assetPriceE18, uint256 minimum);
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error CurveNotQuotable();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    error GraduationSeedNotViable();
    error TokenNotFound();
    error WrongGraduationPhase();
    error NothingToGraduate();
    error GraduationRescueTooEarly(uint256 availableAt);
    error NotCreatorFeeRecipient();
    error NotProposedCreatorFeeRecipient();
    /// @notice The launch's current tier still has a free rung on `nextFreeTickSpacing`'s
    ///         ladder, so graduation can open the market with no help, and the owner may not
    ///         move the tier. See `setSweptLaunchPoolFee`.
    error LaunchPoolLadderNotExhausted(address token);

    // ─── Events ──────────────────────────────────────────────────────────

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        address reserve,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );
    event LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut);
    event PoolGraduated(
        address indexed token,
        uint256 indexed marketId,
        address unit,
        bytes32 poolId,
        uint256 positionId,
        uint256 unitSeeded,
        uint256 tokensSeeded,
        uint256 tokensLocked
    );
    event GraduationRescued(
        address indexed token, address indexed to, uint256 quote, uint256 tokens
    );
    event LaunchPoolFeeRetiered(address indexed token, uint24 previousFee, uint24 newFee);
    event CreatorFeeRecipientProposed(
        address indexed token, address indexed current, address indexed proposed
    );
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previous, address indexed current
    );
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchEnabledUpdated(bool enabled);
    event ReserveEconomicsUpdated(
        address indexed reserve,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint256 launchFee,
        uint8 decimals,
        bool approved
    );
    event ReserveApprovalUpdated(address indexed reserve, bool approved);
    event ProtocolFeeRecipientUpdated(address recipient);
    event ProtocolFeeShareUpdated(uint16 bps);
    event MaxCreatorTaxUpdated(uint16 bps);
    event SnipeTaxUpdated(uint256 startBps, uint256 secondsWindow);
    event GraduatedCreatorShareUpdated(uint16 bps);
    event LpFundRecipientUpdated(address recipient);
    event LpFundShareUpdated(uint16 bps);
    event GraduatedLpFundShareUpdated(uint16 bps);
    event LaunchDeployerSet(address deployer);
    event GraduationSet(address graduation);
    event FeeEscrowSet(address feeEscrow);
    event LaunchForwarderSet(address forwarder);

    // ─── Wiring ──────────────────────────────────────────────────────────

    /// @notice The market factory every launch graduates into. Also the authority on which
    ///         reserves, fee tiers and tick spacings a launch may be configured with.
    AssetMarketFactory public marketFactory;

    /// @notice Uniswap's canonical v4 `PositionManager`, identity-checked against the market
    ///         factory's so the graduation module and the markets agree on what an LP NFT is.
    IPositionManagerV4 public positionManager;

    /// @inheritdoc ILaunchFeePolicy
    ILaunchFeeEscrow public feeEscrow;

    /// @notice Stateless seed preflight, deployed at initialisation.
    ///
    /// @dev    Deployed through `LaunchGuardDeployer` rather than with `new` here. That is an
    ///         EIP-170 measure and nothing else: an inline `new` would carry the guard's
    ///         2,970 bytes of creation code in this contract's own runtime, which is the whole
    ///         of why the factory was over the limit. The library call is a `DELEGATECALL`, so
    ///         the `CREATE` still runs from this proxy's nonce and the guard lands exactly
    ///         where it always did.
    LaunchGraduationGuard public graduationGuard;

    // Not immutable: each helper's constructor needs this factory's already-deployed address,
    // so they are deployed afterward and wired once.
    LaunchDeployer public launchDeployer;
    ILaunchGraduation public graduation;
    /// @notice The router allowed to name the initiating user of an atomic launch-and-buy.
    address public launchForwarder;

    // ─── Policy ──────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchFeePolicy
    address public protocolFeeRecipient;
    /// @inheritdoc ILaunchFeePolicy
    uint256 public protocolFeeShareBps;
    /// @notice Ceiling on the creator-chosen trade tax, validated at launch time.
    uint256 public maxCreatorTaxBps;
    /// @inheritdoc ILaunchSnipeTax
    uint256 public snipeTaxStartBps;
    /// @inheritdoc ILaunchSnipeTax
    uint256 public snipeTaxSeconds;
    /// @notice The creator's share of what a graduated launch's locked position earns in LP
    ///         FEES, snapshotted into the launch record at launch time. A trader on a
    ///         graduated market pays `ProtocolFeeHook`'s skim plus the pool's own LP tier;
    ///         this figure splits the second of those, and on a freshly graduated market the
    ///         locked position is the only liquidity, so it is the whole tier.
    uint16 public graduatedCreatorShareBps;
    bool public launchEnabled;
    /// @notice The creator's share of a locked position's FLOAT YIELD, in bps. Read by
    ///         exactly one caller: the `LaunchLocker` deployed BEFORE this change, which
    ///         custodies the positions locked before this change (markets 16, 17 and 18) and
    ///         calls this getter unconditionally inside `collect()`. That locker is not
    ///         upgradeable and holds its factory address immutably, so removing this getter
    ///         would revert every `collect()` it can ever make and strand those three
    ///         creators' fees, the LP fund's fees, the protocol's fees and the accrued float
    ///         yield permanently — there is no function on it that moves a position or its
    ///         income elsewhere.
    ///
    /// @dev    **Deliberately not settable.** The live slot holds 4_000, written by the
    ///         original `initialize`, and that is exactly the term those three creators were
    ///         sold; no setter exists so no owner can reprice a leg that is already running.
    ///         A fresh deployment reads 0, which is correct: a fresh deployment's locker
    ///         renounces its reward stream at `recordPosition`, so no float yield ever
    ///         reaches it, the current locker never reads this value, and there is nothing
    ///         to split.
    ///
    ///         The slot also cannot be moved. These 2 bytes sit between `launchEnabled` and
    ///         `lpFundRecipient` inside one packed slot, so removing them would slide a live
    ///         proxy's `lpFundRecipient` two bytes down and hand the LP fund's address to
    ///         whatever the shift produced.
    uint16 public graduatedCreatorYieldShareBps;
    /// @inheritdoc ILaunchFeePolicy
    ///
    /// @dev    Packs into the same slot as the three values above: 2 + 1 + 2 bytes leave 27
    ///         free, and an address takes 20 of them. Appending here rather than below the
    ///         mappings is what lets the LP fund ship as a plain upgrade with empty
    ///         `upgradeToAndCall` calldata — nothing already written moves, and both new
    ///         share knobs read their zero default, which is the leg disabled.
    address public lpFundRecipient;
    /// @inheritdoc ILaunchFeePolicy
    ///
    /// @dev    2 more bytes of the same slot, 25 used of 32.
    uint16 public lpFundShareBps;
    /// @inheritdoc ILaunchFactory
    ///
    /// @dev    2 more bytes of the same slot, 27 used of 32. One knob serves both
    ///         post-graduation legs: the fund's claim on a graduated launch is a single
    ///         policy, and splitting it into a fee rate and a yield rate would create two
    ///         numbers that have to be moved together and a state where they disagree.
    uint16 public graduatedLpFundShareBps;

    /// @dev The slot the per-brand `pairTokenEconomics` mapping occupied before economics
    ///      were keyed by reserve. Retired rather than reused: the live proxy still holds the
    ///      old entries under brand keys, and a mapping of a different value type at this slot
    ///      would decode them as garbage for anyone who queried a brand — with `approved`
    ///      reading true off a byte of the old launch fee. Nothing reads this. Kept so nothing
    ///      below it moves.
    uint256 private __retiredPairTokenEconomics;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    /// @notice The recipient a launch's current creator fee recipient has offered to hand
    ///         over to. Zero when nothing is pending.
    mapping(address token => address proposed) public pendingCreatorFeeRecipient;
    LaunchConfig[] private _launchConfigs;
    address[] private _launches;
    /// @notice Curve economics and the launch switch for every brand of a reserve, keyed by
    ///         the reserve. See `ReserveEconomics` for why the brand is not the key.
    /// @dev    Appended below everything already written and taken out of the gap, so the
    ///         upgrade that introduced it carried empty calldata: every reserve reads zero,
    ///         which is closed, until the owner writes its figures.
    mapping(address reserve => ReserveEconomics economics) public reserveEconomics;
    /// @dev Declared curve shape per launch config, kept beside `_launchConfigs` rather than
    ///      inside it: the struct is the one this proxy has already written entries of, and
    ///      growing it would move every field of every existing entry. An id with no entry
    ///      here is the unsegmented curve, which is every config written before segments
    ///      existed. Also out of the gap, below `reserveEconomics`.
    mapping(uint256 launchConfigId => CurveSegmentConfig[] segments) private _launchConfigSegments;

    /// @dev Room for later versions to add state.
    uint256[38] private __gap;

    // ─── Construction ────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address guard_,
        AssetMarketFactory marketFactory_,
        IPositionManagerV4 positionManager_,
        ILaunchFeeEscrow feeEscrow_
    ) external initializer {
        if (
            address(marketFactory_) == address(0) || address(positionManager_) == address(0)
                || address(feeEscrow_) == address(0)
        ) revert ZeroAddress();
        // The graduation module mints through `positionManager_` into pools the market
        // factory created, and stakes the result in distributors the market factory
        // initialised with its own position manager. One check at initialisation covers
        // every launch.
        if (address(marketFactory_.positionManager()) != address(positionManager_)) {
            revert LaunchDependenciesNotWired();
        }

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Guarded_init(guard_);

        marketFactory = marketFactory_;
        positionManager = positionManager_;
        feeEscrow = feeEscrow_;
        graduationGuard = LaunchGuardDeployer.deploy();

        protocolFeeShareBps = 3_000;
        maxCreatorTaxBps = 1_000;
        snipeTaxStartBps = 9_900;
        snipeTaxSeconds = 15;
        graduatedCreatorShareBps = 4_000;
        // The fund's recipient is deliberately NOT defaulted to the protocol treasury here.
        // A fresh deployment starts with the leg off, and `setLpFundRecipient` is what turns
        // it on, so the fund's address is always something an operator chose rather than
        // something a constructor guessed. Both share knobs stay zero until then.
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Permanently disabled. An ownerless factory could never approve a pair token or
    ///         adjust fee ceilings, and every launch already live would keep depending on
    ///         those powers. Ownership can still be handed on via the two-step transfer.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    /// @inheritdoc ILaunchFactory
    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    /// @inheritdoc ILaunchFactory
    function creatorFeeRecipientOf(address token) external view returns (address) {
        return _launchedTokens[token].creatorFeeRecipient;
    }

    /// @inheritdoc ILaunchFactory
    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    /// @inheritdoc ILaunchFactory
    function launchAt(uint256 index) external view returns (address) {
        return _launches[index];
    }

    /// @inheritdoc ILaunchFeePolicy
    function currentFeePolicy() public view returns (FeePolicySnapshot memory) {
        // Bounded by MAX_PROTOCOL_FEE_SHARE_BPS in the setter, so the narrowing is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 shareBps = uint16(protocolFeeShareBps);
        return FeePolicySnapshot({
            protocolFeeRecipient: protocolFeeRecipient,
            protocolFeeShareBps: shareBps,
            lpFundRecipient: lpFundRecipient,
            lpFundShareBps: lpFundShareBps
        });
    }

    /// @notice The reserve `pairToken` is a brand of, and the terms a launch quoted in it takes
    ///         right now. Every brand of a reserve answers the same figures; `approved` is
    ///         false while the reserve is closed or has no figures written.
    /// @dev Reverts rather than answering for anything that could never launch whatever the
    ///      figures said: a token the market factory did not register as a brand, a brand of a
    ///      reserve the factory no longer serves, or a brand whose issuer has not opted into
    ///      sharing float yield. Those are the launch's own refusals, made once here so a
    ///      router can meet them before it pulls anything.
    function launchEconomics(address pairToken)
        public
        view
        returns (address reserve, ReserveEconomics memory economics)
    {
        reserve = _quoteReserve(pairToken);
        economics = reserveEconomics[reserve];
    }

    /// @notice Returns the economics digest a launch of `launchConfigId` in `pairToken` would
    ///         produce right now, for a creator to pass back as `TokenParams.expectedEconomics`.
    /// @dev Reading the digest and launching in separate transactions still leaves the terms
    ///      free to move in between; the pin is what makes that movement revert instead of
    ///      silently repricing the launch.
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken)
        external
        view
        returns (bytes32)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        (address reserve, ReserveEconomics memory economics) = launchEconomics(pairToken);
        return _economicsDigest(_launchConfigs[launchConfigId], reserve, economics, launchConfigId);
    }

    /// @notice The curve and token addresses `launchToken` would deploy for these terms, or
    ///         `launchTokenFor` would on behalf of `originalDeployer`.
    function predictLaunchAddresses(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer
    ) external view returns (address token, address curve) {
        if (launchConfigId >= _launchConfigs.length) {
            revert InvalidLaunchConfigId();
        }
        (, ReserveEconomics memory economics) = launchEconomics(pairToken);
        return launchDeployer.predictLaunchAddresses(
            _deployment(
                params, _launchConfigs[launchConfigId], pairToken, economics, originalDeployer
            )
        );
    }

    /// @dev Covers every owner-controlled term that fixes what a creator is buying: the curve's
    ///      shape and cost, the reserve its float earns for, the anti-snipe terms its opening
    ///      window is priced under, the pool the launch graduates into, the fee split during
    ///      and after the curve, and the launch fee itself. The rule is that anything the owner
    ///      can move which is then *frozen into the launch* belongs here, because the creator
    ///      cannot react to it once the curve is live.
    ///
    ///      `maxCreatorTaxBps` is intentionally absent: it bounds a figure the creator supplies
    ///      rather than one the protocol sets, so a change makes the launch revert on its own
    ///      rather than silently reprice.
    ///
    ///      `lpFundShareBps` IS here and `graduatedLpFundShareBps` is NOT, and the difference
    ///      is the same one that puts the curve's protocol share here and the graduated yield
    ///      share outside. The curve-fee LP fund share is snapshotted into the curve at
    ///      launch, so it fixes the creator's remainder for the life of the curve and the
    ///      creator must be able to pin it. The post-graduation fund share is read live and
    ///      is carved out of the protocol's own remainder, so it can never move what the
    ///      creator is owed and there is nothing for them to pin.
    function _economicsDigest(
        LaunchConfig memory config,
        address reserve,
        ReserveEconomics memory economics,
        uint256 launchConfigId
    ) private view returns (bytes32) {
        bytes32 digest = keccak256(
            abi.encode(
                economics.phantomQuote,
                economics.graduationThreshold,
                config.supply,
                config.curveFeeBps,
                config.poolFee,
                protocolFeeShareBps,
                lpFundShareBps,
                economics.launchFee,
                graduatedCreatorShareBps,
                snipeTaxStartBps,
                snipeTaxSeconds,
                reserve
            )
        );
        // The declared curve shape is exactly the kind of term this digest exists to pin: the
        // owner can change it and the creator cannot react once the curve is live. Mixed in
        // only when there is a shape to pin, so a config that has never been segmented keeps
        // the digest its creators were already quoted.
        CurveSegmentConfig[] memory segments = _launchConfigSegments[launchConfigId];
        if (segments.length == 0) return digest;
        return keccak256(abi.encode(digest, segments));
    }

    // ─── Owner configuration ─────────────────────────────────────────────

    /// @notice Points the factory at the launch deployer. Set after both are deployed, since
    ///         the deployer's constructor needs this factory's already-known address.
    ///
    /// @dev **Rotatable, not one-shot.** It used to revert `AlreadySet` on a second call. That
    ///      bought nothing: this contract is a UUPS proxy whose `_authorizeUpgrade` is
    ///      `onlyOwner`, so an owner who wanted to repoint the deployer could already do it by
    ///      shipping an implementation that does — the lock only stopped the honest operator,
    ///      and it stopped them from replacing a deployer that turned out to be defective
    ///      without redeploying the whole factory and abandoning every launch record in it.
    ///
    ///      Rotation only governs launches created after it. A curve and its token are
    ///      CREATE2-deployed by whichever deployer was set at the time and are immutable
    ///      afterwards, so nothing already launched moves or breaks.
    function setLaunchDeployer(LaunchDeployer deployer) external onlyOwner {
        if (address(deployer) == address(0)) revert ZeroAddress();
        if (deployer.factory() != address(this)) revert LaunchDependenciesNotWired();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    /// @notice Points the factory at the graduation module. Set after both are deployed, since
    ///         the module's constructor needs this factory's already-known address.
    ///
    /// @dev **Rotatable, for the reason the module exists at all.** `LaunchGraduation`'s own
    ///      documentation says it was split out because "graduation is the one step that has
    ///      broken on mainnet before", so that it "can be reasoned about, and replaced,
    ///      independently". A one-shot setter contradicted that outright: the module could be
    ///      reasoned about but never replaced.
    ///
    ///      Safe to rotate because the module holds nothing between transactions — phase two
    ///      is all-or-nothing, and a launch whose graduation reverts stays in `Swept` and
    ///      retryable. So pointing at a fixed module is exactly how a stuck launch gets
    ///      un-stuck, and the retry then runs against the new code.
    ///
    ///      The new module must still name this factory, and the market factory's own
    ///      `setLaunchpad` has to be pointed at it too — that link lives on the other
    ///      contract and this cannot reach it.
    function setGraduation(ILaunchGraduation graduation_) external onlyOwner {
        if (address(graduation_) == address(0)) revert ZeroAddress();
        if (ILaunchGraduationWiring(address(graduation_)).factory() != address(this)) {
            revert LaunchDependenciesNotWired();
        }
        graduation = graduation_;
        emit GraduationSet(address(graduation_));
    }

    /// @notice Points the factory at the escrow that future curves credit and that
    ///         `LaunchLocker` reads live when it collects.
    ///
    /// @dev **Swapping this does not strand anything.** `LaunchFeeEscrow` is standalone: its
    ///      `claimToken` is gated on nothing but the caller's own recorded balance, so every
    ///      balance credited to the old escrow stays claimable from the old escrow forever.
    ///      What moves is where *new* revenue lands.
    ///
    ///      Existing curves are unaffected either way — each holds its escrow as a
    ///      constructor immutable — so this governs launches created after it plus the
    ///      locker's next collection.
    function setFeeEscrow(ILaunchFeeEscrow escrow) external onlyOwner {
        if (address(escrow) == address(0)) revert ZeroAddress();
        feeEscrow = escrow;
        emit FeeEscrowSet(address(escrow));
    }

    /// @notice Sets the router allowed to preserve the initiating user across an atomic
    ///         launch-and-buy call. Zero closes that path; the router may be rotated when it
    ///         is upgraded without replacing the rest of the launch stack.
    function setLaunchForwarder(address forwarder) external onlyOwner {
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    /// @notice Adds a launch configuration new tokens can be deployed against.
    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    /// @notice Replaces an existing launch configuration. Already-launched tokens are
    ///         unaffected since their terms were snapshotted.
    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    /// @notice Adds a launch configuration whose curve is split into ordered segments, each
    ///         taking a share of the sellable allocation at its own steepness. See
    ///         `CurveSegmentConfig`: the declaration is relative on both axes, so one config
    ///         still describes the same curve against every approved quote brand.
    /// @dev An empty `segments` is the unsegmented curve and is identical to the
    ///      single-argument overload.
    function addLaunchConfig(LaunchConfig calldata config, CurveSegmentConfig[] calldata segments)
        external
        onlyOwner
        returns (uint256 id)
    {
        _validateLaunchConfig(config);
        LaunchCurveSegments.validateShape(segments);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        _writeLaunchConfigSegments(id, segments);
        emit LaunchConfigAdded(id);
    }

    /// @notice Replaces an existing launch configuration and its declared curve shape. Pass
    ///         an empty `segments` to return the config to an unsegmented curve.
    /// @dev The single-argument `updateLaunchConfig` leaves an existing shape in place. The
    ///      shares are fractions of the sellable allocation and the steepnesses are relative
    ///      to the curve's own opening product, so a shape stays meaningful across a change
    ///      of supply or fee; dropping it silently would be the surprising behaviour.
    function updateLaunchConfig(
        uint256 id,
        LaunchConfig calldata config,
        CurveSegmentConfig[] calldata segments
    ) external onlyOwner {
        if (id >= _launchConfigs.length) {
            revert InvalidLaunchConfigId();
        }
        _validateLaunchConfig(config);
        LaunchCurveSegments.validateShape(segments);
        _launchConfigs[id] = config;
        _writeLaunchConfigSegments(id, segments);
        emit LaunchConfigUpdated(id);
    }

    /// @notice The curve shape configuration `id` declares. Empty for an unsegmented curve.
    function getLaunchConfigSegments(uint256 id)
        external
        view
        returns (CurveSegmentConfig[] memory)
    {
        if (id >= _launchConfigs.length) {
            revert InvalidLaunchConfigId();
        }
        return _launchConfigSegments[id];
    }

    /// @dev Overwrites a config's declared shape, shrinking first so a shorter declaration
    ///      cannot leave the tail of a longer one behind it.
    function _writeLaunchConfigSegments(uint256 id, CurveSegmentConfig[] calldata segments)
        private
    {
        CurveSegmentConfig[] storage stored = _launchConfigSegments[id];
        while (stored.length > segments.length) {
            stored.pop();
        }
        for (uint256 i = 0; i < segments.length; ++i) {
            if (i < stored.length) stored[i] = segments[i];
            else stored.push(segments[i]);
        }
    }

    /// @notice Sets the curve economics every brand of `reserve` launches on, in the reserve
    ///         asset's own decimals. Existing launches are unaffected: each curve receives its
    ///         figures as constructor immutables, so this only governs launches created after
    ///         it.
    /// @dev The reserve must be one the market factory opens markets in, because graduation
    ///      opens the market quoted in the launch's brand inside that reserve. Which brands of
    ///      it may quote a launch is not decided here: every brand the market factory
    ///      registered on it qualifies, and the two per-brand conditions — that registration,
    ///      and the issuer's float-share opt-in — are checked live at launch by
    ///      `_quoteReserve`, so a dollar issued after this call needs no owner action.
    ///
    ///      `e.decimals` is pinned to the reserve's `assetDecimals` because that is the scale
    ///      every brand of it is minted at, and the figures here are sized for that scale. A
    ///      launch re-reads the brand's own `decimals()` against it, since a brand
    ///      implementation is upgradeable and the curve prices against the stored figure for
    ///      its whole life.
    function setReserveEconomics(address reserve, ReserveEconomics calldata e) external onlyOwner {
        if (reserve == address(0)) revert ZeroAddress();
        if (e.phantomQuote == 0 || e.graduationThreshold == 0) revert ReserveEconomicsInvalid();
        // Curve fees are integer basis points of the quote leg, so on a coarse asset every
        // trade below BASIS_POINTS / feeBps base units rounds its fee to zero and a trader can
        // split an order into fee-free pieces. Six decimals is the floor at which that band
        // is dust, and matches the least granular asset worth quoting in.
        if (e.decimals < MIN_PAIR_TOKEN_DECIMALS) revert ReserveEconomicsInvalid();
        if (
            reserve != address(marketFactory.reservePool())
                && !marketFactory.approvedReservePool(reserve)
        ) revert ReserveNotApproved(reserve);
        if (SharedReservePool(reserve).assetDecimals() != e.decimals) {
            revert ReserveEconomicsInvalid();
        }
        // A launch on this reserve takes its phantom reserve from here but its supply from
        // whichever config it selects, so the strictest case is the smallest supply any
        // config may declare paired with the highest fee any of them may charge.
        _requireQuotable(e.phantomQuote, MIN_LAUNCH_SUPPLY, MAX_CURVE_FEE_BPS);

        reserveEconomics[reserve] = e;
        emit ReserveEconomicsUpdated(
            reserve, e.phantomQuote, e.graduationThreshold, e.launchFee, e.decimals, e.approved
        );
    }

    /// @notice Opens or closes every brand of a reserve for new launches without touching the
    ///         reserve's economics.
    function setReserveApproved(address reserve, bool approved) external onlyOwner {
        ReserveEconomics storage economics = reserveEconomics[reserve];
        if (approved && economics.phantomQuote == 0) revert ReserveEconomicsInvalid();
        economics.approved = approved;
        emit ReserveApprovalUpdated(reserve, approved);
    }

    /// @notice Where launch fees and the protocol's share of curve fees are credited. Curves
    ///         snapshot it at launch; this moves future launches only.
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    /// @notice The protocol's share of the curve fee, snapshotted into future launches.
    ///
    /// @dev    Bounded against the LP fund's share as well as against its own ceiling. The
    ///         creator is paid the remainder, so a pair summing past the whole fee would make
    ///         `_sweepFees` underflow on every curve launched afterwards. Checking both
    ///         setters against the same invariant means neither ordering of two calls can
    ///         leave the pair invalid even transiently.
    function setProtocolFeeShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_FEE_SHARE_BPS) revert InvalidBasisPoints();
        if (uint256(bps) + lpFundShareBps > BASIS_POINTS) revert InvalidBasisPoints();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    /// @notice Where the LP fund's share of launchpad revenue is credited, for the curve-fee
    ///         leg and both post-graduation legs at once.
    ///
    /// @dev    Repointing reaches the curve-fee leg of FUTURE launches only, because a curve
    ///         snapshots the recipient alongside the share at initialize, the same way it
    ///         snapshots the protocol's. It reaches both post-graduation legs of EVERY locked
    ///         position immediately, because the locker reads this live. That asymmetry is
    ///         the same one the protocol recipient already has and is deliberate: a live
    ///         curve's terms are fixed, a locked position's payer is not.
    ///
    ///         Refuses zero. Turning the leg off is done by zeroing the two share knobs,
    ///         which is checked here in reverse: a nonzero share with a zero recipient would
    ///         credit the escrow to address zero and revert every sweep, so the recipient can
    ///         only be cleared once nothing is routed to it.
    function setLpFundRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        lpFundRecipient = recipient;
        emit LpFundRecipientUpdated(recipient);
    }

    /// @notice The LP fund's share of the curve fee, snapshotted into future launches.
    ///
    /// @dev    Requires a recipient to already be set when nonzero. See
    ///         `setProtocolFeeShareBps` for why the pair is bounded jointly.
    function setLpFundShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_LP_FUND_SHARE_BPS) revert InvalidBasisPoints();
        if (protocolFeeShareBps + uint256(bps) > BASIS_POINTS) revert InvalidBasisPoints();
        if (bps != 0 && lpFundRecipient == address(0)) revert ZeroAddress();
        lpFundShareBps = bps;
        emit LpFundShareUpdated(bps);
    }

    /// @notice Adjusts the ceiling a creator's chosen trade tax is validated against at
    ///         launch time. Already-launched tokens keep the immutable tax rate they launched
    ///         with regardless of later ceiling changes.
    function setMaxCreatorTaxBps(uint16 bps) external onlyOwner {
        if (bps > MAX_CREATOR_TAX_CEILING_BPS) revert InvalidBasisPoints();
        maxCreatorTaxBps = bps;
        emit MaxCreatorTaxUpdated(bps);
    }

    /// @notice Sets the launch-second snipe tax and its decay window, which new launches
    ///         snapshot at creation. Curves already trading keep the figures they launched
    ///         under. A zero starting tax disables the mechanism for launches created while
    ///         it is zero; a nonzero figure must exceed the 20% combined base fee ceiling, so
    ///         the launch-window tax always dominates the ordinary fee take, and stays below
    ///         100% so a taxed buy always nets the buyer something. The window is capped at
    ///         one minute so a misconfiguration cannot leave a launch effectively closed to
    ///         the public for minutes, and a zero window is refused rather than overloaded to
    ///         mean off.
    function setSnipeTax(uint256 startBps, uint256 seconds_) external onlyOwner {
        if (
            startBps != 0
                && (startBps <= MAX_TOTAL_TRADE_FEE_BPS || startBps > MAX_SNIPE_TAX_START_BPS)
        ) revert InvalidBasisPoints();
        if (seconds_ == 0 || seconds_ > MAX_SNIPE_TAX_SECONDS) revert InvalidSnipeTaxWindow();
        snipeTaxStartBps = startBps;
        snipeTaxSeconds = seconds_;
        emit SnipeTaxUpdated(startBps, seconds_);
    }

    /// @notice The creator's share of a graduated launch's locked-position LP FEES,
    ///         snapshotted into future launches. Launches already live keep the rate they
    ///         were sold, which is why this figure is part of `_economicsDigest`.
    ///
    /// @dev    Bounded against `graduatedLpFundShareBps` so that a position recorded under
    ///         this rate can always be split: the locker pays the creator this share, the
    ///         fund its own, and the protocol the remainder.
    function setGraduatedCreatorShareBps(uint16 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBasisPoints();
        if (uint256(bps) + graduatedLpFundShareBps > BASIS_POINTS) revert InvalidBasisPoints();
        graduatedCreatorShareBps = bps;
        emit GraduatedCreatorShareUpdated(bps);
    }

    /// @notice The LP fund's share of a locked position's LP FEES, effective on the next
    ///         `collect` of every locked position.
    ///
    /// @dev    Bounded against the creator rate, because it is subtracted alongside it. The
    ///         fund's cut comes out of the protocol's remainder, never the creator's share,
    ///         so raising this dilutes the protocol alone — which is what makes it safe to
    ///         apply retroactively to positions that graduated before the fund existed.
    ///
    ///         The current locker has no yield leg for it to split. A position it records
    ///         renounces its reward stream at `recordPosition`, so a market's float yield
    ///         goes entirely to its liquidity providers and never passes through it.
    ///
    ///         Bounded against `graduatedCreatorYieldShareBps` anyway, because the locker
    ///         deployed before this change DOES split a yield leg and reverts `ShareTooHigh`
    ///         when `graduatedCreatorYieldShareBps() + graduatedLpFundShareBps() > 10_000`.
    ///         Without this line an owner raising the fund's share would brick `collect()`
    ///         on markets 16, 17 and 18 for good.
    ///
    ///         Retroactive only within a locker. Positions staked through an earlier locker
    ///         are split by that contract's code, on the rates they were recorded with.
    function setGraduatedLpFundShareBps(uint16 bps) external onlyOwner {
        if (bps > MAX_LP_FUND_SHARE_BPS) revert InvalidBasisPoints();
        if (graduatedCreatorShareBps + bps > BASIS_POINTS) revert InvalidBasisPoints();
        if (graduatedCreatorYieldShareBps + bps > BASIS_POINTS) revert InvalidBasisPoints();
        if (bps != 0 && lpFundRecipient == address(0)) revert ZeroAddress();
        graduatedLpFundShareBps = bps;
        emit GraduatedLpFundShareUpdated(bps);
    }

    // ─── Launch ──────────────────────────────────────────────────────────

    /// @notice Deploys a bonding curve and its launch token, wires them together, and records
    ///         the launch. Trading starts immediately on the curve; the brand the curve is
    ///         quoted in, and the reserve it graduates into, are fixed here by the caller's
    ///         choice of `pairToken`. The caller, their creator fee recipient and every
    ///         address in `snipeTaxExemptions` clear the launch window at the untaxed price;
    ///         undeclared snipers pay the decaying tax.
    ///
    ///         The launch fee, if the brand carries one, is pulled from the caller last.
    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external nonReentrant whenNotPaused returns (address token, address curve) {
        (token, curve) = _launchToken(params, launchConfigId, pairToken, msg.sender);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    /// @notice Launches for the initiating user of the trusted atomic launch-and-buy router.
    /// @dev Only the configured `launchForwarder` may supply `originalDeployer`. This
    ///      preserves the real caller without `tx.origin`, which breaks through
    ///      account-abstraction relayers and must never be used for authorization. The launch
    ///      fee is still pulled from the router, which holds the user's brand for the call.
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions,
        address originalDeployer
    ) external nonReentrant whenNotPaused returns (address token, address curve) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        if (originalDeployer == address(0)) revert ZeroAddress();
        (token, curve) = _launchToken(params, launchConfigId, pairToken, originalDeployer);
        _exemptFromSnipeTax(curve, snipeTaxExemptions);
    }

    /// @dev Applies the bounded opening-buy exemption list shared by direct and forwarded
    ///      launches.
    function _exemptFromSnipeTax(address curve, address[] calldata snipeTaxExemptions) private {
        if (snipeTaxExemptions.length > MAX_SNIPE_TAX_EXEMPTIONS) revert ExemptionListTooLong();
        for (uint256 i = 0; i < snipeTaxExemptions.length; ++i) {
            LaunchCurve(curve).exemptFromSnipeTax(snipeTaxExemptions[i]);
        }
    }

    /// @dev Shared body of the direct and trusted-forwarder entrypoints. Validates the launch
    ///      terms, deploys and records the pair, exempts the creator's own addresses from the
    ///      snipe tax, and takes the launch fee last.
    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer
    ) private returns (address token, address curve) {
        (LaunchConfig memory config, address reserve, ReserveEconomics memory economics) =
            _validateLaunch(params, launchConfigId, pairToken);

        LaunchDeployment memory deployment =
            _deployment(params, config, pairToken, economics, originalDeployer);
        (token, curve) = launchDeployer.deployLaunch(deployment);
        // An empty shape is the unsegmented curve, which is what every config written before
        // segments existed declares.
        CurveSegmentConfig[] memory segments = _launchConfigSegments[launchConfigId];
        LaunchCurve(curve).initialize(token, segments);

        // The creator's own addresses never count as snipers on their own launch: an atomic
        // dev buy lands in the launch second, exactly when the tax peaks, and would otherwise
        // be consumed by it.
        LaunchCurve(curve).exemptFromSnipeTax(originalDeployer);
        if (deployment.creatorFeeRecipient != originalDeployer) {
            LaunchCurve(curve).exemptFromSnipeTax(deployment.creatorFeeRecipient);
        }

        _recordLaunch(token, curve, deployment, config, reserve, economics, launchConfigId);

        // Last, after the launch is fully recorded, so a failed launch never takes a fee and
        // the pull cannot observe a half-written record through a callback.
        if (economics.launchFee != 0) {
            IERC20(pairToken)
                .safeTransferFrom(msg.sender, protocolFeeRecipient, economics.launchFee);
        }
    }

    /// @dev Every rejection a launch can meet before anything is deployed, in the order that
    ///      gives the cheapest failure first.
    function _validateLaunch(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        private
        view
        returns (LaunchConfig memory config, address reserve, ReserveEconomics memory economics)
    {
        if (
            address(launchDeployer) == address(0) || address(graduation) == address(0)
                || protocolFeeRecipient == address(0)
        ) revert LaunchDependenciesNotWired();
        if (!launchEnabled) revert LaunchDisabled();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) {
            revert InvalidTokenParams();
        }
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();

        (reserve, economics) = launchEconomics(pairToken);
        if (!economics.approved) revert ReserveClosed(reserve);
        // The scale was pinned to the reserve's when the economics were set, but an
        // upgradeable brand can change it afterwards, and this curve prices against the
        // stored figure for its entire life. Re-reading here keeps a silent mispricing out of
        // the launch.
        _requireDecimals(pairToken, economics.decimals);

        config = _launchConfigs[launchConfigId];
        // Every term below is owner-updatable, so a creator may pin the whole set they were
        // quoted rather than accept whatever is current when their transaction lands.
        bytes32 digest = _economicsDigest(config, reserve, economics, launchConfigId);
        if (params.expectedEconomics != bytes32(0) && params.expectedEconomics != digest) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, digest);
        }
        if (!config.enabled) revert LaunchConfigDisabled();
        // Unreachable while the individual ceilings stay where they are, since each leg caps
        // at 1000 bps against a 2000 bps combined limit. Kept as the check that would
        // actually bind if either ceiling were raised.
        if (config.curveFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) {
            revert CombinedFeeTooHigh();
        }
        // A config and a quote brand are validated separately but graduate as a pair, and it
        // is the pair that fixes the seed. Terms that imply a position V4 will not mint are
        // refused here, while the creator still has their fee and nothing has been deployed.
        (uint256 quoteAtGraduation, uint256 seedPhantomQuote) =
            _graduationTerms(config, economics, launchConfigId);
        _requireSeedableTerms(
            config.supply,
            economics.phantomQuote,
            economics.graduationThreshold,
            marketFactory.tickSpacingForFee(config.poolFee),
            quoteAtGraduation,
            seedPhantomQuote
        );
        _requireSeedPriceResolvable(config, economics, quoteAtGraduation, seedPhantomQuote);
    }

    /// @dev Writes the launch record and announces it.
    function _recordLaunch(
        address token,
        address curve,
        LaunchDeployment memory deployment,
        LaunchConfig memory config,
        address reserve,
        ReserveEconomics memory economics,
        uint256 launchConfigId
    ) private {
        LaunchedToken storage launch = _launchedTokens[token];
        launch.token = token;
        launch.curve = curve;
        launch.deployer = deployment.originalDeployer;
        launch.creatorFeeRecipient = deployment.creatorFeeRecipient;
        launch.pairToken = deployment.pairToken;
        launch.reserve = reserve;
        launch.graduationThreshold = economics.graduationThreshold;
        launch.poolFee = config.poolFee;
        launch.creatorTaxBps = uint16(deployment.creatorTaxBps);
        launch.creatorShareBps = graduatedCreatorShareBps;
        launch.exists = true;
        _launches.push(token);

        emit TokenLaunched(
            token,
            curve,
            deployment.originalDeployer,
            deployment.pairToken,
            reserve,
            launchConfigId,
            economics.graduationThreshold
        );
    }

    /// @dev The deployer's input for a launch on these terms. Shared by the launch and predict
    ///      paths so the two can never derive different addresses.
    function _deployment(
        TokenParams calldata params,
        LaunchConfig memory config,
        address pairToken,
        ReserveEconomics memory economics,
        address originalDeployer
    ) private pure returns (LaunchDeployment memory d) {
        d.pairToken = pairToken;
        d.creatorFeeRecipient = params.creatorFeeRecipient == address(0)
            ? originalDeployer
            : params.creatorFeeRecipient;
        d.originalDeployer = originalDeployer;
        d.phantomQuote = economics.phantomQuote;
        d.curveFeeBps = config.curveFeeBps;
        d.creatorTaxBps = params.creatorTaxBps;
        d.graduationThreshold = economics.graduationThreshold;
        d.supply = config.supply;
        d.salt = params.salt;
        d.name = params.name;
        d.symbol = params.symbol;
        d.logo = params.logo;
        d.description = params.description;
        d.socials = params.socials;
    }

    // ─── Creator fee recipient ───────────────────────────────────────────

    /// @notice Offers future creator fees for `token` to `newRecipient`. Only the current
    ///         recipient may offer, and nothing changes until `newRecipient` accepts, so a
    ///         typo cannot send a launch's revenue to an address nobody controls. Offering
    ///         again replaces the pending offer.
    function proposeCreatorFeeRecipient(address token, address newRecipient) external {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (msg.sender != launch.creatorFeeRecipient) revert NotCreatorFeeRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        pendingCreatorFeeRecipient[token] = newRecipient;
        emit CreatorFeeRecipientProposed(token, msg.sender, newRecipient);
    }

    /// @notice Takes over creator fees for `token`, as the recipient the current one offered
    ///         them to. Updates this record — which the locker reads at every collect — and,
    ///         while the launch still trades on its curve, the curve's own recipient.
    function acceptCreatorFeeRecipient(address token) external {
        address proposed = pendingCreatorFeeRecipient[token];
        if (proposed == address(0) || msg.sender != proposed) {
            revert NotProposedCreatorFeeRecipient();
        }
        delete pendingCreatorFeeRecipient[token];

        LaunchedToken storage launch = _launchedTokens[token];
        address previous = launch.creatorFeeRecipient;
        launch.creatorFeeRecipient = proposed;
        if (launch.phase == GraduationPhase.NotGraduated) {
            LaunchCurve(launch.curve).setCreatorFeeRecipient(proposed);
        }
        emit CreatorFeeRecipientUpdated(token, previous, proposed);
    }

    // ─── Graduation, phase 1: drain the curve ────────────────────────────

    /// @notice Sweeps the curve's pending fees into the escrow and its remaining quote and
    ///         token reserves into this factory, halting curve trading. Purely internal to the
    ///         curve's own balances, so it is safe for the curve to call this automatically
    ///         the instant a buy crosses the graduation threshold.
    /// @dev The fee sweep happens inside `LaunchCurve.graduate` rather than through a separate
    ///      `sweepFees` call: that entry point is `nonReentrant`, and this function runs inside
    ///      the crossing buy's guarded scope when the curve triggers it.
    function graduate(address token) external nonReentrant {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.NotGraduated) revert WrongGraduationPhase();
        LaunchCurve curve = LaunchCurve(launch.curve);
        if (!curve.readyToGraduate()) revert LaunchCurve.NotReadyToGraduate();

        // Record what this factory actually received rather than what the curve reported
        // sending. A quote asset that does not deliver its full nominal amount would
        // otherwise leave the launch claiming a balance it never got, and the shortfall would
        // be drawn from whatever other launches are holding the same asset here.
        uint256 quoteBefore = IERC20(launch.pairToken).balanceOf(address(this));
        (, uint256 tokenOut) = curve.graduate(address(this));
        uint256 quoteOut = IERC20(launch.pairToken).balanceOf(address(this)) - quoteBefore;
        if (quoteOut == 0) revert NothingToGraduate();

        launch.sweptQuote = quoteOut;
        launch.sweptTokens = tokenOut;
        launch.sweptAt = block.timestamp;
        launch.phase = GraduationPhase.Swept;

        emit LaunchSwept(token, quoteOut, tokenOut);
    }

    // ─── Graduation, phase 2: open the market ────────────────────────────

    /// @notice Hands a swept launch's reserves to `LaunchGraduation`, which opens the asset
    ///         market and locks the seed. Permissionless and retryable: a launch stays in
    ///         Swept until the module succeeds, and the module reverts as one transaction, so
    ///         a transient failure can never strand reserves.
    /// @dev The seed is preflighted with `LaunchGraduationGuard` before any funds move. The
    ///      unit does not exist until the module creates it, so both currency orderings are
    ///      checked; the seed's unit side equals its quote side because the reserve swaps
    ///      brand for unit 1:1 and the two share decimals.
    function graduateToMarket(address token) external nonReentrant whenNotPaused {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.Swept) revert WrongGraduationPhase();
        ILaunchGraduation module = graduation;
        if (address(module) == address(0)) revert LaunchDependenciesNotWired();

        uint256 quoteAmount = launch.sweptQuote;
        uint256 tokenAmount = launch.sweptTokens;
        uint256 phantomQuote = _graduationPhantomQuote(launch.curve);
        // Only the token amount that preserves the terminal curve price against the
        // physically held quote reaches the pool; the module locks the remainder.
        uint256 tokensSeeded = FullMath.mulDiv(tokenAmount, quoteAmount, quoteAmount + phantomQuote);
        if (tokensSeeded == 0) revert NothingToGraduate();
        graduationGuard.assertSeedableEitherOrdering(
            marketFactory.tickSpacingForFee(launch.poolFee), quoteAmount, tokensSeeded
        );

        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;
        launch.phase = GraduationPhase.Graduated;

        // Plain transfers, not upstream's `_transferExact`. That guard asserted the
        // module's balance moved by exactly the nominal amount, which cannot fail here and
        // cannot be tested here: the only brands this factory will quote are
        // `PooledBrandToken`s, whose transfer is OZ's with no fee and no hook, and the launch
        // token is this repo's own. An assertion no reachable state can trip is a branch
        // nobody can exercise, which is the same reason the graduation guard's unreachable
        // overload was deleted rather than kept "for safety".
        IERC20(launch.pairToken).safeTransfer(address(module), quoteAmount);
        IERC20(token).safeTransfer(address(module), tokenAmount);

        ILaunchGraduation.Result memory result =
            module.graduate(_seed(token, launch, quoteAmount, tokenAmount, phantomQuote));
        launch.marketId = result.marketId;

        emit PoolGraduated(
            token,
            result.marketId,
            result.unit,
            result.poolId,
            result.positionId,
            result.unitSeeded,
            result.tokensSeeded,
            result.tokensLocked
        );
    }

    /// @dev The graduation module's input for a swept launch. No unit is named: the market
    ///      opens quoted in the brand the curve was quoted in, so there is nothing to mint.
    function _seed(
        address token,
        LaunchedToken storage launch,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 phantomQuote
    ) private view returns (ILaunchGraduation.Seed memory seed) {
        seed.token = token;
        seed.pairToken = launch.pairToken;
        seed.reserve = launch.reserve;
        seed.creator = launch.deployer;
        seed.creatorFeeRecipient = launch.creatorFeeRecipient;
        seed.creatorShareBps = launch.creatorShareBps;
        seed.poolFee = launch.poolFee;
        seed.quoteAmount = quoteAmount;
        seed.tokenAmount = tokenAmount;
        seed.phantomQuote = phantomQuote;
    }

    /// @notice Re-points an ungraduated launch at a different LP fee tier, so a launch whose
    ///         graduated pool key has been squatted can still graduate.
    ///
    /// @dev    **The attack this exists for.** A graduated market is quoted in the launch's
    ///         own brand, so both currencies of its v4 pool exist from the moment the launch
    ///         is created and its `PoolKey` — `(quoteBrand, launchToken, launch.poolFee,
    ///         tickSpacingForFee(fee), ProtocolFeeHook)` — is fully predictable. The hook
    ///         declares `beforeInitialize: false`, so `PoolManager.initialize` on that key is
    ///         permissionless.
    ///
    ///         **This is now the second line, not the first.**
    ///         `AssetMarketFactory.createLaunchMarket` walks a tick-spacing ladder and opens
    ///         the market on the first free rung, so a squatted canonical key no longer stops
    ///         a graduation at all and this setter is not needed for the ordinary attack.
    ///         What it still covers is the case the ladder cannot: an attacker who has taken
    ///         every one of `nextFreeTickSpacing`'s rungs at the launch's current tier. Moving
    ///         the tier hands graduation a whole fresh ladder for one owner transaction,
    ///         instead of a 7-day `rescueSweptGraduation` and an off-chain distribution.
    ///
    ///         **Only for an exhausted ladder, because the tier is a term the creator was
    ///         quoted.** It is part of `_economicsDigest` and it fixes what a trader pays on
    ///         the graduated market, so an owner who could move it at will could change a
    ///         quoted term after the fact and call it maintenance. A squat on the launch's
    ///         canonical key is not enough to unlock it: `createLaunchMarket` walks past that
    ///         one without any owner involvement, so gating on it would let any third party
    ///         hand the owner a re-tiering power for a single ~60k-gas `initialize` — a 100x
    ///         swing on a term nobody asked to have moved. The gate is the ladder itself
    ///         being gone: `nextFreeTickSpacing` returns `0` exactly then, and returning `0`
    ///         rather than reverting was designed for this caller. A tier with any rung left
    ///         is `LaunchPoolLadderNotExhausted`. Owner-only on top of that, because letting
    ///         anyone move it would hand the squatter a second lever.
    ///
    ///         **Unreachable after graduation.** A `Graduated` launch's pool is open and
    ///         holds the locked seed; re-pointing its tier would leave the market's stored
    ///         key describing a pool nothing was minted into. Only `NotGraduated` and
    ///         `Swept` are accepted, and a `Rescued` launch has nothing left to seed.
    ///
    ///         The new tier is run through the same two rejections graduation applies:
    ///         `tickSpacingForFee` for the tier itself, and `LaunchGraduationGuard` for the
    ///         seed at the spacing that tier implies, so the owner cannot swap a squatted
    ///         tier for one the mint would then refuse. A swept launch is preflighted on its
    ///         actual swept amounts, exactly as `graduateToMarket` will; one still on its
    ///         curve is preflighted on the terms its record fixes, exactly as `createLaunch`
    ///         did — which, as there, narrows the failure rather than removing it, because
    ///         fees and the creator tax move the realised quote slightly off the threshold.
    ///
    ///         The preflight is run on the NEW tier's canonical spacing. A ladder rung is one
    ///         to thirty-one ticks wider, and `LaunchGraduation._mintFullRange` re-asserts on
    ///         the spacing the pool actually opened with, so the check here stays the
    ///         conservative one whichever rung graduation ends up taking.
    function setSweptLaunchPoolFee(address token, uint24 fee) external onlyOwner {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        GraduationPhase phase = launch.phase;
        if (phase != GraduationPhase.NotGraduated && phase != GraduationPhase.Swept) {
            revert WrongGraduationPhase();
        }
        // Reverts `UnsupportedFeeTier` for a tier the market factory would refuse.
        int24 tickSpacing = marketFactory.tickSpacingForFee(fee);

        uint24 previousFee = launch.poolFee;
        if (marketFactory.nextFreeTickSpacing(launch.pairToken, token, previousFee) != 0) {
            revert LaunchPoolLadderNotExhausted(token);
        }

        uint256 quoteAmount;
        uint256 tokenAmount;
        if (phase == GraduationPhase.Swept) {
            quoteAmount = launch.sweptQuote;
            tokenAmount = launch.sweptTokens;
        } else {
            quoteAmount = launch.graduationThreshold;
            tokenAmount = LaunchCurve(launch.curve).reservedTokens();
        }
        uint256 phantomQuote = LaunchCurve(launch.curve).phantomQuote();
        uint256 tokensSeeded = FullMath.mulDiv(tokenAmount, quoteAmount, quoteAmount + phantomQuote);
        if (tokensSeeded == 0) revert GraduationSeedNotViable();
        graduationGuard.assertSeedableEitherOrdering(tickSpacing, quoteAmount, tokensSeeded);

        launch.poolFee = fee;
        emit LaunchPoolFeeRetiered(token, previousFee, fee);
    }

    /// @notice Releases a swept launch's reserves to `recipient` when phase two can no longer
    ///         succeed: a brand that stopped delivering, a seed the market refuses, or a
    ///         reserve retired underneath the launch. The reserves are moved whole to a single
    ///         recipient for off-chain distribution rather than split on chain.
    /// @dev The owner is trusted here, bounded by `GRADUATION_RESCUE_DELAY`. What makes that
    ///      bound meaningful is that `graduateToMarket` stays permissionless throughout the
    ///      wait: any holder can end the window early, and permanently, with one call.
    ///      Reserves only stay reachable by this path if nobody could seed them.
    ///
    ///      **Which is why this is `whenNotPaused`.** The retry is what legitimises the
    ///      window, so the rescue has to be unavailable on exactly the condition that takes
    ///      the retry away. Without that, a guardian — whose only power is supposed to be
    ///      halting — could pause this contract, let phase one keep sweeping crossed curves
    ///      into it for a week with no holder able to seed any of them, and hand the owner a
    ///      guaranteed harvest. `ProtocolGuard` promises a stolen guardian key achieves "a
    ///      denial of service that the timelock then unwinds"; this keeps that true.
    ///
    ///      What it does not prevent is the owner unpausing for one block and rescuing in the
    ///      next. That is deliberate and not worth closing: this contract is UUPS with an
    ///      `onlyOwner` `_authorizeUpgrade`, so an owner who wants the reserves can already
    ///      take them by upgrading. The property being defended is that the *guardian* cannot
    ///      be the trigger, not that the owner is constrained.
    function rescueSweptGraduation(address token, address recipient)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (launch.phase != GraduationPhase.Swept) revert WrongGraduationPhase();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 availableAt = launch.sweptAt + GRADUATION_RESCUE_DELAY;
        if (block.timestamp < availableAt) revert GraduationRescueTooEarly(availableAt);

        uint256 quoteAmount = launch.sweptQuote;
        uint256 tokenAmount = launch.sweptTokens;

        launch.sweptQuote = 0;
        launch.sweptTokens = 0;
        launch.sweptAt = 0;
        launch.phase = GraduationPhase.Rescued;

        if (quoteAmount != 0) IERC20(launch.pairToken).safeTransfer(recipient, quoteAmount);
        if (tokenAmount != 0) IERC20(token).safeTransfer(recipient, tokenAmount);

        emit GraduationRescued(token, recipient, quoteAmount, tokenAmount);
    }

    // ─── Validation ──────────────────────────────────────────────────────

    function _validateLaunchConfig(LaunchConfig calldata config) private view {
        if (config.curveFeeBps > MAX_CURVE_FEE_BPS) revert CurveFeeTooHigh();
        if (config.supply < MIN_LAUNCH_SUPPLY) revert SupplyTooLow();
        // A supply above the seed ceiling would deploy a curve and token that trade normally,
        // then revert forever at graduation with the reserves already swept out of the curve.
        if (config.supply > MAX_SEED_AMOUNT) revert SupplyTooHigh();
        // Reverts `UnsupportedFeeTier` for a tier the market factory would refuse at
        // graduation, which is the one moment a launch cannot afford to learn about it.
        marketFactory.tickSpacingForFee(config.poolFee);
    }

    /// @dev Refuses terms whose graduated pool price would be too coarse to express.
    ///
    ///      `LaunchGraduation` lists the token at `AssetListing.assetPriceE18`, one whole
    ///      token in whole units scaled by 1e18, and the pool opens at whatever that
    ///      truncates to. The relative error of that truncation is `1 / assetPriceE18`, and
    ///      the quote it strands is that fraction of the seed — so `MAX_DUST_BPS` of 10
    ///      already requires the price to be at least 1,000. This asks for 1e4, an order of
    ///      magnitude of headroom, which bounds the stranded quote at 1 bp rather than 10.
    ///
    ///      The shipped configuration is nowhere near it: 1e27 supply against an 8,090-unit
    ///      threshold on a 6-decimal brand seeds ~7.14e26 tokens and prices at ~1.13e13, nine
    ///      orders of magnitude clear. What this rejects is a launch whose supply was raised,
    ///      or whose threshold lowered, to the point where the pool would open visibly off the
    ///      curve's terminal price and the difference would be swept to the protocol. Checked
    ///      here, where both halves are known and the creator still has their fee, rather than
    ///      at graduation where the only exit is `SeedPriceTooCoarse` and a retry.
    function _requireSeedPriceResolvable(
        LaunchConfig memory config,
        ReserveEconomics memory economics,
        uint256 quoteAtGraduation,
        uint256 seedPhantomQuote
    ) private pure {
        uint256 tokensSeeded = FullMath.mulDiv(
            config.supply, quoteAtGraduation, quoteAtGraduation + seedPhantomQuote
        );
        if (tokensSeeded == 0) revert SeedPriceTooCoarse(0, MIN_SEED_PRICE_E18);

        // Mirrors `LaunchGraduation._createMarket` exactly, with the launch token's fixed
        // 18 decimals substituted for the read it does there.
        uint256 assetPriceE18 = FullMath.mulDiv(
            quoteAtGraduation * 1e18, 1e18, tokensSeeded * 10 ** uint256(economics.decimals)
        );
        if (assetPriceE18 < MIN_SEED_PRICE_E18) {
            revert SeedPriceTooCoarse(assetPriceE18, MIN_SEED_PRICE_E18);
        }
    }

    /// @dev The quote a launch on these terms ends its curve holding, and the virtual reserve
    ///      that reproduces the price it ends at. An unsegmented config returns the reserve's
    ///      own threshold and phantom reserve unchanged, so nothing about an existing config
    ///      moves; a segmented one is resolved through the same code the curve itself will
    ///      run at initialize, because a steepened curve ends above its threshold and seeds
    ///      its pool deeper and higher than the threshold alone implies.
    function _graduationTerms(
        LaunchConfig memory config,
        ReserveEconomics memory economics,
        uint256 launchConfigId
    ) private view returns (uint256 quoteAtGraduation, uint256 seedPhantomQuote) {
        CurveSegmentConfig[] memory segments = _launchConfigSegments[launchConfigId];
        if (segments.length == 0) {
            return (economics.graduationThreshold, economics.phantomQuote);
        }
        uint256 reserved = FullMath.mulDiv(
            config.supply,
            economics.phantomQuote,
            economics.phantomQuote + economics.graduationThreshold
        );
        // The same rejection `LaunchCurve.initialize` makes, brought forward to where the
        // creator still has their fee.
        if (reserved == 0 || reserved >= config.supply) revert GraduationSeedNotViable();
        (, quoteAtGraduation, seedPhantomQuote) =
            LaunchCurveSegments.build(segments, config.supply, reserved, economics.phantomQuote);
    }

    /// @dev The virtual quote reserve graduation splits a curve's reserved allocation with.
    ///      Read from the curve rather than recomputed here because the curve is the one
    ///      contract that knows the shape it actually resolved.
    ///
    ///      Curves deployed before segmented curves existed have no such view, and their
    ///      whole allocation is the single base segment, so their immutable phantom reserve
    ///      is the answer. Probing rather than assuming keeps a launch that is already mid
    ///      curve when this factory is upgraded graduating exactly as it would have.
    function _graduationPhantomQuote(address curve) private view returns (uint256) {
        (bool ok, bytes memory returned) =
            curve.staticcall(abi.encodeWithSignature("graduationPhantomQuote()"));
        if (ok && returned.length == 32) return abi.decode(returned, (uint256));
        return LaunchCurve(curve).phantomQuote();
    }

    /// @dev The reserve `pairToken` is a brand of, and every per-brand condition a launch
    ///      quoted in it has to meet, checked live on each read. Trust flows outward from the
    ///      market factory: `reserveOfBrand` is the factory's own record, so a token it did
    ///      not register is refused before anything the token says about itself is believed,
    ///      and the reserve that record names must still be one the factory serves.
    ///
    ///      Registered THROUGH the market factory, not merely on the reserve, because
    ///      graduation opens the market quoted in this very brand. A brand registered straight
    ///      on the reserve leaves `reserveOfBrand` zero, and `AssetMarketFactory._record`
    ///      would then stamp the factory's DEFAULT reserve into the market record — after
    ///      which `MarketLens` quotes mints and redemptions against a reserve the brand is not
    ///      pooled in.
    ///
    ///      The reserve is re-checked here, rather than only when its economics were written,
    ///      because the owner may retire one afterwards with `setApprovedReservePool(pool,
    ///      false)`. A launch created against a retired reserve trades normally, sweeps
    ///      normally, and then fails `_resolveReserve` on every single `graduateToMarket`
    ///      attempt — permanently pinned in Swept, with the owner's rescue as the only exit
    ///      for money that belongs to its traders. Refused while the only thing at stake is
    ///      the creator's unspent launch fee.
    ///
    ///      And the issuer must have agreed to share the float yield of the markets this
    ///      brand quotes, by having their treasury name the market factory. Without it a
    ///      graduated market would seed liquidity and earn nothing on it.
    function _quoteReserve(address pairToken) private view returns (address reserve) {
        reserve = marketFactory.reserveOfBrand(pairToken);
        if (reserve == address(0)) revert PairTokenNotRegistered(pairToken, reserve);
        if (
            reserve != address(marketFactory.reservePool())
                && !marketFactory.approvedReservePool(reserve)
        ) revert ReserveNotApproved(reserve);
        if (
            PoolBrandTreasury(marketFactory.treasuryOfBrand(pairToken)).factory()
                != address(marketFactory)
        ) revert PairTokenFloatShareUnavailable(pairToken);
    }

    /// @dev Requires the brand to report `expectedDecimals`. Every brand here is a live
    ///      contract, so an unreadable scale is a hard failure rather than a claim to accept.
    function _requireDecimals(address pairToken, uint8 expectedDecimals) private view {
        uint8 actual = IERC20Metadata(pairToken).decimals();
        if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
    }

    /// @dev Reverts unless a small reference buy against a fresh curve with these terms would
    ///      return a non-zero amount of tokens. A phantom reserve set far too large against
    ///      the supply prices every realistic trade to zero, and the curve reverts on all of
    ///      them. That launch is dead on arrival but still deployable, and its creator has
    ///      already paid the launch fee, so the terms are rejected before any contract exists
    ///      rather than after.
    function _requireQuotable(uint256 phantomQuote, uint256 supply, uint256 curveFeeBps)
        private
        pure
    {
        uint256 referenceBuy = phantomQuote / REFERENCE_BUY_DIVISOR;
        if (LaunchCurveMath.quoteAmountOut(referenceBuy, phantomQuote, supply, curveFeeBps) == 0) {
            revert CurveNotQuotable();
        }
    }

    /// @dev Reverts unless the seed these launch terms imply is one Uniswap V4 would mint.
    ///      Graduation drains a fixed share of supply against a quote reserve the threshold
    ///      fixes, so the seed is determined by the terms rather than by how the curve is
    ///      traded. Rejecting unmintable proportions at launch keeps a curve from taking
    ///      deposits it could never graduate. Fees and the creator tax move the realised quote
    ///      slightly off the threshold, so this narrows the failure rather than removing it,
    ///      and the delayed rescue remains the backstop for whatever it does not catch.
    function _requireSeedableTerms(
        uint256 supply,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        int24 tickSpacing,
        uint256 quoteAtGraduation,
        uint256 seedPhantomQuote
    ) private view {
        uint256 reserved = FullMath.mulDiv(supply, phantomQuote, phantomQuote + graduationThreshold);
        uint256 poolTokenAmount =
            FullMath.mulDiv(reserved, quoteAtGraduation, quoteAtGraduation + seedPhantomQuote);
        // Terms whose token side rounds away have nothing to seed with, and the price the
        // guard derives from a zero amount is undefined.
        if (poolTokenAmount == 0) revert GraduationSeedNotViable();
        graduationGuard.assertSeedableEitherOrdering(
            tickSpacing, quoteAtGraduation, poolTokenAmount
        );
    }
}
