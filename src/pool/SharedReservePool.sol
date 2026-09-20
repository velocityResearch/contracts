// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {PooledBrandToken} from "./PooledBrandToken.sol";
import {PoolBrandTreasury} from "./PoolBrandTreasury.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";
import {ReentrancyGuardSlot} from "../upgrade/ReentrancyGuardSlot.sol";

/// @title SharedReservePool
/// @notice A single shared reserve of one underlying asset (e.g. USDG), earning yield through
///         one yield source, that backs many `PooledBrandToken`s at a permanent 1:1 rate.
///         Because every pooled brand token is a flat, non-appreciating claim on the SAME
///         pot of backing, any two of them can be swapped for each other — burn X of one,
///         mint X of the other — without ever moving value: neither side's redemption value
///         changes, so there is nothing for a swap to arbitrage.
///
///         That is the fix for the problem a naive burn/mint-1:1 swap has across independent
///         `BrandedVault`s: those each carry their own appreciating share price, so swapping
///         their shares token-for-token silently transfers value from whichever vault's price
///         has drifted higher. Pooling the backing removes the price drift between brands
///         entirely — but the yield the pool earns still has to end up somewhere, so it is
///         tracked per-brand instead of showing up as share-price appreciation:
///
///         Yield ledger: `totalAssets()` grows as the yield source earns interest while
///         `totalPooledSupply` (the sum of every brand's outstanding tokens, which only
///         changes 1:1 against real backing moving in or out) does not. That growing surplus
///         is distributed across brands with a cumulative index — `cumulativeYieldPerToken`
///         — exactly like `BrandedVault._harvestFees` distributes yield by share-price delta,
///         except the "share price" here is a single pool-wide rate and the thing it is
///         multiplied by is a brand's outstanding supply instead of one vault's whole supply.
///         A brand's accrued entitlement is only ever settled against ITS OWN outstanding
///         supply at each checkpoint, so moving tokens between brands via `swap()` cannot
///         shift yield entitlement between them — it only relabels which brand's ledger a
///         claim sits under.
///
///         The brand's treasury (`PoolBrandTreasury`) receives 100% of the yield attributed
///         to its own outstanding supply — there is no separate holder-facing share price to
///         split it with, since holders get a permanent 1:1 peg and free swaps instead.
///
///         Scope: this pool is for pooled brands only. It does not touch `BrandedVault` or
///         any vault already deployed — a brand that wants floating-NAV yield-bearing shares
///         instead of a flat interoperable peg still uses `BrandedVaultFactory`.
contract SharedReservePool is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    GuardedUpgradeable,
    ReentrancyGuardSlot
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Configuration ───────────────────────────────────────────────────

    /// @notice The shared underlying asset backing every pooled brand token (e.g. USDG).
    /// @dev Storage rather than `immutable` so the whole of this contract's configuration
    ///      lives in the proxy, not split between the proxy and whichever implementation
    ///      happens to be installed. An upgrade then changes code and nothing else.
    IERC20 public asset;

    /// @dev Cached so `PooledBrandToken`s line up 1:1 with the asset without an extra call.
    uint8 public assetDecimals;

    /// @notice Beacon backing every `PooledBrandToken` this pool has deployed. Upgrading it
    ///         upgrades every brand stablecoin in the pool at once.
    address public brandTokenBeacon;

    /// @notice Beacon backing every `PoolBrandTreasury` this pool has deployed.
    address public treasuryBeacon;

    /// @notice The yield source adapter (Aave, Morpho, etc.) — swappable, see setYieldSource.
    IYieldSource public yieldSource;

    /// @dev Fixed-point scale for `cumulativeYieldPerToken`.
    uint256 private constant WAD = 1e18;

    // ─── Per-brand state ─────────────────────────────────────────────────

    struct Brand {
        bool registered;
        address treasury;
        /// @dev This brand's live outstanding supply — kept in lockstep with the token's own
        ///      totalSupply() by every mint/redeem/swap, so it never needs to be re-derived.
        uint256 outstanding;
        /// @dev `cumulativeYieldPerToken` as of this brand's last settle.
        uint256 indexCheckpoint;
        /// @notice Unclaimed yield (in asset units) owed to this brand's treasury.
        uint256 accruedYield;
    }

    mapping(address token => Brand) public brands;
    address[] public allBrandTokens;

    // ─── Global yield accrual ────────────────────────────────────────────

    /// @notice Sum of every registered brand's outstanding pooled tokens.
    uint256 public totalPooledSupply;

    /// @dev `totalAssets()` as of the last accrual sync. Growth beyond this, with supply
    ///      unchanged, is yield; growth caused by a mint/redeem moving supply and assets
    ///      together is not, which is why every supply-changing function re-syncs this
    ///      immediately afterwards (mirrors `BrandedVault._syncHarvestBaseline`).
    uint256 public lastAccrualAssets;

    /// @notice Cumulative yield earned per unit of pooled supply, WAD-scaled and
    ///         monotonically non-decreasing. See the contract-level docs for the model.
    uint256 public cumulativeYieldPerToken;

    /// @notice Previously observed reserve losses that must be recovered before new yield
    ///         can be credited. Capital deposits do not erase this deficit.
    uint256 public lossCarryforward;

    /// @notice Fee retained by the reserve on every redemption, in basis points of the amount
    ///         burned. Zero for a native-USDG reserve. A reserve whose backing lives behind a
    ///         bridge and a swap (see `SUSDaiYieldSource`) charges the redeemer the round trip
    ///         it triggers, instead of letting every holder pay for one holder's exit.
    ///
    ///         The fee is not sent anywhere: it stays in the reserve and is recognised as pool
    ///         income at the next accrual, exactly like yield. That is what nets it against the
    ///         bridge and swap costs, which the keeper's valuation reports book as losses:
    ///         costs land in `lossCarryforward`, fees repay it, and only the remainder either
    ///         way reaches the brands' ledgers.
    ///
    ///         **This is the live fee and the only one any payout path reads.** An increase the
    ///         owner has announced but not yet committed sits in `pendingRedemptionFeeBps` and
    ///         is invisible here, to `previewRedeem`, to both `redeem` overloads and to every
    ///         downstream quoter (`MarketLens`, `BrandPsm.tout`) until `commitRedemptionFee`
    ///         moves it across. See `setRedemptionFee`.
    uint16 public redemptionFeeBps;

    /// @notice Maximum aggregate brand-token principal. Zero preserves legacy unlimited pools.
    uint256 public liabilityCap;

    /// @notice An increase to `redemptionFeeBps` that has been announced but is not yet live.
    ///         Meaningless on its own: read `redemptionFeeEffectiveAt` to know whether anything
    ///         is actually scheduled, because a committed or cancelled increase leaves this
    ///         zeroed alongside it and a zero here is also a legitimate fee.
    uint16 public pendingRedemptionFeeBps;

    /// @notice Unix time from which `pendingRedemptionFeeBps` may be committed. **Zero means
    ///         nothing is pending**, which is the single check an integrator needs: a quoter
    ///         that reads zero here knows the fee it just quoted cannot move for at least
    ///         `FEE_INCREASE_DELAY`, because the only way to raise it is to announce it first.
    ///
    /// @dev    `uint64` rather than `uint256` so it packs into one slot with
    ///         `pendingRedemptionFeeBps`: the pair costs a single SSTORE to schedule and a
    ///         single one to clear, and the whole feature consumes one storage slot.
    uint64 public redemptionFeeEffectiveAt;

    /// @dev Room for later versions to add state. This contract holds the whole reserve, so it
    ///      is the one whose layout most needs room to move without a migration. Shrunk from 40
    ///      to 39 when the pending-fee pair above was appended, so every slot below this point
    ///      is exactly where it was for the two live proxies.
    uint256[39] private __gap;

    /// @notice Hard ceiling on `redemptionFeeBps`: 1%. The round trip this exists to recover is
    ///         measured in tens of basis points; anything near the ceiling is a mis-set fee, not
    ///         a cost, and the ceiling is what keeps a mis-set fee from being a confiscation.
    uint16 public constant MAX_REDEMPTION_FEE_BPS = 100;

    /// @notice How long an announced increase to `redemptionFeeBps` must wait before it can be
    ///         committed: one hour.
    ///
    ///         This exists for the quote-then-fill gap. An aggregator reads `previewRedeem`,
    ///         routes on it, and the fill lands blocks later; without a delay the owner could
    ///         move the fee in between and the trade settles at a price nobody agreed to. One
    ///         hour is far longer than any routing pipeline and short enough that a genuine
    ///         cost increase is recovered the same day.
    ///
    /// @dev    A constant, deliberately, and not a settable parameter: a settable delay is a
    ///         delay the owner can set to zero, at which point it protects nobody and only
    ///         looks like it does. Decreases are not delayed at all — see `setRedemptionFee`.
    uint64 public constant FEE_INCREASE_DELAY = 1 hours;

    /// @notice Recall shortfall `setYieldSource` treats as rounding rather than as stranded
    ///         value. A real adapter's share<->asset floor division (Morpho Blue) can hand back
    ///         a wei or two less than book, and refusing a migration over that dust would be a
    ///         footgun of its own; anything larger is value the adapter cannot deliver.
    uint256 public constant MAX_MIGRATION_DUST = 2;

    uint256 private constant BPS = 10_000;

    // ─── Events ──────────────────────────────────────────────────────────

    event BrandRegistered(
        address indexed token,
        address indexed treasury,
        address indexed admin,
        string name,
        string symbol
    );
    event BrandMetadataSet(address indexed token, string description, string logo, string socials);
    event Minted(
        address indexed token, address indexed payer, address indexed receiver, uint256 amount
    );
    event Redeemed(
        address indexed token, address indexed caller, address indexed receiver, uint256 amount
    );
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        address indexed caller,
        address receiver,
        uint256 amount
    );
    event YieldClaimed(address indexed token, address indexed receiver, uint256 amount);
    event Deployed(uint256 amount);
    event Recalled(uint256 amount);
    event YieldSourceUpdated(address indexed oldYieldSource, address indexed newYieldSource);
    /// @notice The LIVE redemption fee changed. Emitted by a decrease, which applies at once,
    ///         and by `commitRedemptionFee`, never by scheduling an increase — so an indexer
    ///         that tracks this one event still sees exactly the value every payout uses, with
    ///         no change on its side.
    event RedemptionFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    /// @notice An increase was announced. Nothing has changed yet: `oldFeeBps` is still live
    ///         and stays live until `effectiveAt`, and only then if someone commits it.
    event RedemptionFeeIncreaseScheduled(uint16 oldFeeBps, uint16 newFeeBps, uint64 effectiveAt);
    /// @notice An announced increase went live. `effectiveAt` is the time it became committable,
    ///         which is in the past by definition, so an indexer can prove the hour was served.
    event RedemptionFeeIncreaseCommitted(uint16 oldFeeBps, uint16 newFeeBps, uint64 effectiveAt);
    /// @notice An announced increase was dropped before it went live, either by the owner or by
    ///         a decrease landing first. `oldFeeBps` is the fee still in force after the drop.
    event RedemptionFeeIncreaseCancelled(uint16 oldFeeBps, uint16 newFeeBps, uint64 effectiveAt);
    event LiabilityCapUpdated(uint256 oldCap, uint256 newCap);
    /// @notice `fee` of the burned amount stayed in the reserve. Emitted alongside `Redeemed`,
    ///         whose amount is the payout, so an indexer can reconstruct the amount burned.
    event RedemptionFeeRetained(address indexed token, uint256 fee);
    /// @notice A migration deliberately abandoned `amount` that the outgoing source could not
    ///         return. Charged to `lossCarryforward`, so future yield repays it first.
    event MigrationStranded(address indexed oldYieldSource, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error UnknownBrand();
    error SameToken();
    error OnlyBrandTreasury();

    /// @notice A redemption would have paid less than the caller was willing to accept. Raised
    ///         before any asset moves, so the burn is rolled back with it.
    error InsufficientPayout(uint256 payout, uint256 minimum);
    error FeeTooHigh(uint16 feeBps, uint16 maximum);
    error LiabilityCapExceeded(uint256 currentSupply, uint256 mintAmount, uint256 cap);

    /// @notice `commitRedemptionFee` or `cancelPendingRedemptionFee` was called with no
    ///         announced increase outstanding. Reverting rather than returning quietly is what
    ///         stops an owner believing they cancelled something they never scheduled.
    error NoPendingFeeIncrease();

    /// @notice An announced increase was committed before its hour was served.
    error FeeIncreaseNotReady(uint64 effectiveAt, uint64 timestamp);

    /// @notice The outgoing adapter returned less than it booked, so the migration would have
    ///         dropped the difference off the pool's books without recording a loss. Use the
    ///         `acceptStranding` overload to write it off deliberately.
    error MigrationWouldStrand(uint256 deployed, uint256 recalled);
    error OwnershipCannotBeRenounced();

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @param _brandTokenBeacon Beacon backing every `PooledBrandToken` this pool deploys.
    /// @param _treasuryBeacon   Beacon backing every `PoolBrandTreasury` this pool deploys.
    /// @param _guard            The protocol pause registry. See `ProtocolGuard`.
    function initialize(
        address _asset,
        address _yieldSource,
        address _owner,
        address _brandTokenBeacon,
        address _treasuryBeacon,
        address _guard
    ) external initializer {
        if (
            _asset == address(0) || _yieldSource == address(0) || _brandTokenBeacon == address(0)
                || _treasuryBeacon == address(0)
        ) revert ZeroAddress();

        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Guarded_init(_guard);

        asset = IERC20(_asset);
        assetDecimals = IERC20Metadata(_asset).decimals();
        yieldSource = IYieldSource(_yieldSource);
        brandTokenBeacon = _brandTokenBeacon;
        treasuryBeacon = _treasuryBeacon;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Always reverts. Upgrade authority here is `_authorizeUpgrade`'s `onlyOwner`, so
    ///         renouncing would permanently freeze the implementation of the contract holding
    ///         the entire reserve, along with `setYieldSource`, `setRedemptionFee` and
    ///         `setLiabilityCap`. Unlike `transferOwnership` it is not two-step, so one
    ///         mistaken call from the owner EOA would be unrecoverable.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ─── Brand registration ──────────────────────────────────────────────

    /// @notice Register a new brand in the pool: deploys its `PooledBrandToken` and paired
    ///         `PoolBrandTreasury`. Permissionless, same rationale as
    ///         `BrandedVaultFactory.createVault` — a brand with no minted supply cannot earn
    ///         yield or affect anyone else's accounting, so there is nothing to gate.
    ///
    ///         This overload leaves the token's on-chain metadata empty and frozen. Prefer
    ///         the six-argument overload: a brand registered through this one has no `logo()`
    ///         for an indexer to read and no way to ever gain one.
    /// @param name    Token name (e.g. "Stables USD")
    /// @param symbol  Token symbol (e.g. "sphUSD")
    /// @param admin   The treasury admin for this brand (controls yield claim destination)
    /// @return token    The new PooledBrandToken (the pooled stablecoin itself)
    /// @return treasury The new PoolBrandTreasury for this brand
    function registerBrand(string calldata name, string calldata symbol, address admin)
        external
        returns (address token, address treasury)
    {
        return _registerBrand(
            name,
            symbol,
            admin,
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            address(0)
        );
    }

    /// @notice Register a new brand and stamp its description, logo URL and socials onto the
    ///         token itself.
    ///
    ///         The logo is the point. Without it the only record of a brand's image is an
    ///         off-chain object keyed by token address, which anyone indexing this chain has
    ///         no way to discover. `PooledBrandToken.logo()` is the same getter the Pons
    ///         tokens on this chain already expose, so existing tooling reads it without being
    ///         taught anything new.
    /// @param name          Token name (e.g. "Stables USD")
    /// @param symbol        Token symbol (e.g. "sphUSD")
    /// @param admin         The treasury admin for this brand (controls yield claim
    ///                      destination)
    /// @param metadata      Description, logo URL and socials. Every field may be empty.
    /// @param metadataAdmin Who may rewrite the metadata later. Zero freezes it forever, and
    ///                      is deliberately NOT defaulted to `admin` — the treasury admin is
    ///                      frequently a contract with no interest in strings.
    /// @return token    The new PooledBrandToken (the pooled stablecoin itself)
    /// @return treasury The new PoolBrandTreasury for this brand
    function registerBrand(
        string calldata name,
        string calldata symbol,
        address admin,
        PooledBrandToken.Metadata calldata metadata,
        address metadataAdmin
    ) external returns (address token, address treasury) {
        return _registerBrand(name, symbol, admin, metadata, metadataAdmin);
    }

    function _registerBrand(
        string calldata name,
        string calldata symbol,
        address admin,
        PooledBrandToken.Metadata memory metadata,
        address metadataAdmin
    ) internal returns (address token, address treasury) {
        if (admin == address(0)) revert ZeroAddress();

        // Beacon proxies rather than fresh contracts: every brand in the pool shares one
        // implementation, so a fix reaches all of them at once instead of only the brands
        // registered after it. Each initialiser runs inside its proxy's own constructor, so
        // there is no window in which an uninitialised token or treasury is reachable.
        token = address(
            new BeaconProxy(
                brandTokenBeacon,
                abi.encodeCall(
                    PooledBrandToken.initialize,
                    (name, symbol, address(this), assetDecimals, metadata, metadataAdmin)
                )
            )
        );
        treasury = address(
            new BeaconProxy(
                treasuryBeacon,
                abi.encodeCall(
                    PoolBrandTreasury.initialize,
                    (SharedReservePool(address(this)), token, admin, address(guard()))
                )
            )
        );

        Brand storage b = brands[token];
        b.registered = true;
        b.treasury = treasury;
        b.indexCheckpoint = cumulativeYieldPerToken;

        allBrandTokens.push(token);

        emit BrandRegistered(token, treasury, admin, name, symbol);
        emit BrandMetadataSet(token, metadata.description, metadata.logo, metadata.socials);
    }

    // ─── Mint / redeem ───────────────────────────────────────────────────

    /// @notice Deposit `amount` of the underlying asset and mint `amount` of `token` 1:1.
    ///
    ///         **The backing is put to work in this same transaction.** New reserves never sit
    ///         idle waiting for a keeper: the deposit into the yield source happens inline, so
    ///         a brand starts earning the moment it is minted and there is no window in which
    ///         a market's float is dead money nobody noticed. `deployIdle()` survives as the
    ///         way to sweep whatever arrives by another route — a direct transfer, dust, or
    ///         capital sitting idle after a `setYieldSource` migration.
    ///
    ///         The cost of that simplicity is stated plainly: **this couples minting to the
    ///         yield source.** A paused Morpho market, a supply cap, or a broken adapter makes
    ///         `mint` revert, and because `MarketRouter.buyWithUsdg` mints, buying stops with
    ///         it. Redemption is unaffected — it only ever pulls the other way — so the peg
    ///         still holds for anyone already holding a brand token. This was a deliberate
    ///         trade of liveness for one less moving part.
    ///
    /// @param token    A registered PooledBrandToken
    /// @param amount   Amount of underlying to deposit (and of `token` to mint)
    /// @param receiver Address to receive the minted `token`
    function mint(address token, uint256 amount, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        Brand storage b = _brand(token);
        if (
            liabilityCap != 0
                && (totalPooledSupply > liabilityCap || amount > liabilityCap - totalPooledSupply)
        ) {
            revert LiabilityCapExceeded(totalPooledSupply, amount, liabilityCap);
        }
        _settleBrand(b);

        b.outstanding += amount;
        totalPooledSupply += amount;
        // Transfer after the liability is recorded, never before. In between the two,
        // `totalAssets()` would read high while `totalPooledSupply` still read low, and
        // `claimYield`'s surplus gate reads exactly that difference as distributable yield.
        asset.safeTransferFrom(msg.sender, address(this), amount);
        PooledBrandToken(token).mint(receiver, amount);

        // Deploy before the baseline is re-synced, never after. A yield source's own
        // share<->asset floor division can hand back a wei less than it was given, and
        // `_accrueGlobal` reads any drop in `totalAssets()` as a loss to be repaid out of
        // future yield. Syncing afterwards absorbs that dust into the baseline instead, so
        // routine deposit rounding never accumulates in `lossCarryforward`.
        _deployIdle();

        _syncAccrualBaseline();
        emit Minted(token, msg.sender, receiver, amount);
        return amount;
    }

    /// @notice Burn `amount` of `token` and withdraw the underlying at 1:1 less the reserve's
    ///         redemption fee, reverting unless the reserve can pay that in full.
    ///
    ///         **This overload used to accept ANY payout, including zero, and that was the
    ///         wrong default.** It passed `minAssetsOut = 0`, so it burned the caller's tokens
    ///         and then paid whatever the reserve happened to be able to raise, booking the
    ///         shortfall against `lossCarryforward`. The tokens were already gone, so there was
    ///         nothing left to retry with: a short reserve turned a redemption into a realised
    ///         loss, silently, with no revert and no event distinguishing it from a good one.
    ///         `docs/AGGREGATOR_INTEGRATION.md` names this selector as the one an aggregator
    ///         calls, which made it the most dangerous default in the system.
    ///
    ///         It now demands par less the fee, exactly what `previewRedeem` quotes. A caller
    ///         who genuinely prefers a haircut to not redeeming keeps that choice — it is the
    ///         four-argument overload with a lower bound — so nothing a holder could do before
    ///         has been taken away. What changed is which behaviour you get by NOT choosing.
    ///
    /// @dev    **Safe to tighten because nothing internal relies on the old behaviour.** Every
    ///         in-protocol caller already passes an explicit minimum: `MarketRouter:452`,
    ///         `LaunchRouter:325` and `BrandPsm:207`. The NatSpec here previously claimed that
    ///         refunds inside `MarketRouter` were the caller this laxity existed for; that
    ///         stopped being true when `_refund` was changed to return the brand leg in kind
    ///         rather than redeem it (see `MarketRouter._refund`), and the comment outlived the
    ///         reason.
    ///
    ///         The dust tolerance that motivated the original zero still exists and still
    ///         matters — `_cappedByIdle` truncates rather than reverting because an adapter's
    ///         share-to-asset floor division can land a wei short. That tolerance now lives
    ///         where it belongs, in the caller's chosen bound, instead of being an unbounded
    ///         promise attached to the simplest entrypoint.
    /// @param token    A registered PooledBrandToken
    /// @param amount   Amount of `token` to burn
    /// @param receiver Address to receive the withdrawn underlying
    function redeem(address token, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        // Computed inline rather than through `previewRedeem` so this stays one SLOAD of
        // `redemptionFeeBps` and cannot drift from the external view's arithmetic.
        return _redeem(token, amount, receiver, amount - amount * redemptionFeeBps / BPS);
    }

    /// @notice Burn `amount` of `token` and withdraw the underlying, reverting unless at least
    ///         `minAssetsOut` actually arrives.
    ///
    ///         **Why a redemption can pay less than it burns.** The reserve pays from idle
    ///         balance after recalling from the yield source, and `_cappedByIdle` truncates
    ///         rather than reverting, because a real adapter's share-to-asset floor division can
    ///         come back a wei short and a hard revert on that dust would brick redemptions
    ///         entirely. That tolerance is correct for dust and wrong as an unbounded promise: if
    ///         the yield source cannot deliver — a lending market at 100% utilisation, an adapter
    ///         holding no shares, a realised loss — the tokens are already burned and the caller
    ///         takes whatever was there, silently. This overload lets the caller say how much
    ///         short is acceptable, which is a decision only they can make.
    /// @param minAssetsOut Smallest payout the caller will accept. `previewRedeem(amount)`
    ///                     demands exactly par less the fee.
    function redeem(address token, uint256 amount, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256)
    {
        return _redeem(token, amount, receiver, minAssetsOut);
    }

    function _redeem(address token, uint256 amount, address receiver, uint256 minAssetsOut)
        private
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        Brand storage b = _brand(token);
        _settleBrand(b);

        PooledBrandToken(token).burn(msg.sender, amount);
        b.outstanding -= amount;
        totalPooledSupply -= amount;

        uint256 fee = amount * redemptionFeeBps / BPS;
        uint256 owed = amount - fee;
        _recallIfNeeded(owed);
        // Capped at idle: a real yield source's own share<->asset floor-division rounding
        // (see `_recallIfNeeded`) can occasionally come back a wei or two short even with the
        // buffer, and a hard revert on that dust would brick redemptions entirely — see the
        // SharedReservePoolFork test this guards against.
        uint256 payout = _cappedByIdle(owed);
        if (payout < minAssetsOut) revert InsufficientPayout(payout, minAssetsOut);
        // A redemption shortfall retires liabilities without removing the same amount of
        // assets, absorbing this part of the existing loss rather than future yield.
        uint256 shortfall = owed - payout;
        lossCarryforward -= Math.min(lossCarryforward, shortfall);
        asset.safeTransfer(receiver, payout);

        _syncAccrualBaseline();
        if (fee > 0) {
            // The fee stayed in the reserve. Holding it out of the baseline is what makes the
            // next accrual recognise it as income: it repays `lossCarryforward` first and only
            // then reaches the brands' ledgers, the same path yield takes.
            lastAccrualAssets -= Math.min(lastAccrualAssets, fee);
            emit RedemptionFeeRetained(token, fee);
        }
        emit Redeemed(token, msg.sender, receiver, payout);
        return payout;
    }

    // ─── The 1:1 swap ────────────────────────────────────────────────────

    /// @notice Swap `amount` of `tokenIn` for `amount` of `tokenOut`, always exactly 1:1.
    ///         No underlying asset moves — both tokens are already fully backed by the same
    ///         shared reserve, so this only relabels which brand's ledger the claim sits
    ///         under. Safe regardless of how much yield either brand has separately accrued,
    ///         because each brand's accrued yield is settled against its OWN outstanding
    ///         supply before that supply changes (see `_settleBrand`).
    /// @param tokenIn  The PooledBrandToken the caller is giving up
    /// @param tokenOut The PooledBrandToken the caller wants
    /// @param amount   Amount to swap (same units in and out)
    /// @param receiver Address to receive `tokenOut`
    function swap(address tokenIn, address tokenOut, uint256 amount, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        if (tokenIn == tokenOut) revert SameToken();

        Brand storage bIn = _brand(tokenIn);
        Brand storage bOut = _brand(tokenOut);
        _settleBrand(bIn);
        _settleBrand(bOut);

        PooledBrandToken(tokenIn).burn(msg.sender, amount);
        bIn.outstanding -= amount;

        bOut.outstanding += amount;
        PooledBrandToken(tokenOut).mint(receiver, amount);

        // totalPooledSupply and totalAssets() are both unchanged by a swap, so the accrual
        // baseline set by _settleBrand's _accrueGlobal() above is still correct — no re-sync.
        emit Swapped(tokenIn, tokenOut, msg.sender, receiver, amount);
        return amount;
    }

    // ─── Yield claim ─────────────────────────────────────────────────────

    /// @notice Pay out `token`'s accrued yield entitlement to `receiver`. Only that brand's
    ///         own treasury may call this — see `PoolBrandTreasury.claim`.
    function claimYield(address token, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        if (receiver == address(0)) revert ZeroAddress();
        Brand storage b = _brand(token);
        if (msg.sender != b.treasury) revert OnlyBrandTreasury();

        _settleBrand(b);
        uint256 owed = b.accruedYield;
        if (owed == 0) return 0;

        // Yield claims may never consume branded-token principal, including entitlement
        // credited before a subsequent adapter loss. Unpaid entitlement stays owed.
        uint256 assets = totalAssets();
        uint256 surplus = assets > totalPooledSupply ? assets - totalPooledSupply : 0;
        uint256 payableYield = Math.min(owed, surplus);
        if (payableYield == 0) return 0;
        _recallIfNeeded(payableYield);
        // Capped at idle, same as `redeem` — any dust the yield source came back short on
        // stays owed (not forgiven) so it is simply paid out on the next successful claim.
        amount = _cappedByIdle(payableYield);
        b.accruedYield = owed - amount;
        asset.safeTransfer(receiver, amount);

        _syncAccrualBaseline();
        emit YieldClaimed(token, receiver, amount);
    }

    // ─── Yield source management ─────────────────────────────────────────

    /// @notice Deploy all idle underlying into the yield source. Anyone can call.
    ///
    ///         `mint` already does this inline, so on a healthy pool this is usually a no-op.
    ///         It stays because reserves can still arrive by other routes: a direct transfer
    ///         to this contract, rounding dust, or the whole position sitting idle after
    ///         `setYieldSource` recalls it and deliberately does not re-commit it.
    function deployIdle() external whenNotPaused nonReentrant {
        _deployIdle();
    }

    /// @dev Move every idle unit of the underlying into the yield source. Callers that change
    ///      supply in the same transaction must re-sync the accrual baseline afterwards — see
    ///      the note in `mint`.
    function _deployIdle() internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle == 0) return;
        asset.forceApprove(address(yieldSource), idle);
        yieldSource.deposit(address(asset), idle);
        emit Deployed(idle);
    }

    /// @notice Migrate the pool to a different yield source adapter (owner only). Recalls
    ///         everything deployed back to idle first — funds sit idle under the new adapter
    ///         until `deployIdle()` is called again. See `BrandedVault.setYieldSource` for
    ///         why this never auto-commits capital to a freshly-set adapter in the same call.
    ///
    ///         **Strict: reverts unless the outgoing adapter delivers its whole book.**
    ///         `IYieldSource.withdraw` pays what it can and never reverts, and a cross-chain
    ///         adapter's `balanceOf` counts value that is not on this chain at all (see
    ///         `SUSDaiYieldSource`), so an unchecked migration walks the difference straight
    ///         off the pool's books: the short recall lands, `_syncAccrualBaseline` writes the
    ///         post-recall figure into `lastAccrualAssets`, and the drop therefore never
    ///         reaches `_accrueGlobal`'s loss branch. Every holder's backing falls with no
    ///         revert, no loss booked, and no event an operator could tell apart from a clean
    ///         migration. Use the two-argument overload to migrate anyway and record it.
    function setYieldSource(address newYieldSource) external onlyOwner {
        _setYieldSource(newYieldSource, false);
    }

    /// @notice Migrate the pool to a different yield source adapter, deliberately abandoning
    ///         whatever the outgoing adapter cannot return.
    ///
    ///         The escape hatch for an adapter that is genuinely stuck — a bridge leg that will
    ///         never land, a venue that has frozen withdrawals — where writing the value off
    ///         beats being unable to move the reserve at all. The shortfall is charged to
    ///         `lossCarryforward`, so future yield repays it before any brand ledger sees a
    ///         wei, and `MigrationStranded` records it.
    /// @param acceptStranding Pass `false` for an ordinary migration; that is the strict path.
    function setYieldSource(address newYieldSource, bool acceptStranding) external onlyOwner {
        _setYieldSource(newYieldSource, acceptStranding);
    }

    function _setYieldSource(address newYieldSource, bool acceptStranding) private {
        if (newYieldSource == address(0)) revert ZeroAddress();

        // Preserve growth earned by the old source before replacing the accrual baseline.
        _accrueGlobal();
        address old = address(yieldSource);
        uint256 deployed = yieldSource.balanceOf(address(asset));
        if (deployed > 0) {
            uint256 recalled = yieldSource.withdraw(address(asset), deployed, address(this));
            emit Recalled(recalled);

            uint256 stranded = deployed - Math.min(deployed, recalled);
            if (stranded > MAX_MIGRATION_DUST) {
                if (!acceptStranding) revert MigrationWouldStrand(deployed, recalled);
                // Booked before `_syncAccrualBaseline` below, which is the only ordering that
                // records it at all: after the re-sync the baseline has absorbed the drop and
                // `_accrueGlobal` can no longer see it.
                lossCarryforward += stranded;
                emit MigrationStranded(old, stranded);
            }
        }

        yieldSource = IYieldSource(newYieldSource);
        _syncAccrualBaseline();

        emit YieldSourceUpdated(old, newYieldSource);
    }

    /// @notice Set the redemption fee (owner only). Capped at `MAX_REDEMPTION_FEE_BPS`.
    ///
    ///         **An increase is announced, not applied.** It records `feeBps` as pending and
    ///         sets `redemptionFeeEffectiveAt` to one `FEE_INCREASE_DELAY` from now, and the
    ///         live fee does not move. Someone must then call `commitRedemptionFee` at or
    ///         after that time. Until they do, every payout path — `previewRedeem`, both
    ///         `redeem` overloads, and every downstream quoter reading `redemptionFeeBps` —
    ///         answers with the old fee, unchanged.
    ///
    ///         The reason is the gap between a quote and a fill. An aggregator reads
    ///         `previewRedeem`, routes on it, and the fill lands blocks later. If the owner
    ///         could raise the fee in that window the trade settles worse than quoted, and the
    ///         aggregator has no way to tell that from ordinary slippage. Announcing the
    ///         increase an hour ahead means a quote is good for as long as any router needs,
    ///         and a quoter that wants to see the change coming reads
    ///         `redemptionFeeEffectiveAt`.
    ///
    ///         **A decrease applies immediately and cancels any pending increase.** Lowering a
    ///         fee cannot make a quoted redemption settle worse than quoted, so there is
    ///         nobody to protect by delaying it, and in an incident the ability to cut the fee
    ///         in one transaction is worth having. A call setting the fee to the value it
    ///         already holds counts as a decrease for this purpose: it changes nothing live
    ///         and clears anything pending.
    ///
    ///         **What cancelling on a decrease means for an operator.** Say the fee is 20, an
    ///         increase to 80 is announced, and forty minutes later the owner drops it to 10.
    ///         The pending 80 is gone, not merely paused. It was authorised against a 20 bps
    ///         baseline and the world it was announced into no longer exists, so resurrecting
    ///         it later would let a 10 bps fee jump to 80 with no fresh hour of warning — the
    ///         exact surprise this delay exists to prevent. To still reach 80, call
    ///         `setRedemptionFee(80)` again after the decrease and serve a new full hour.
    ///         There is no way to shorten that, which is the point.
    /// @param feeBps The new fee in basis points. Checked against `MAX_REDEMPTION_FEE_BPS`
    ///               HERE, at announcement, as well as at commit, so an out-of-range value can
    ///               never sit pending and be seen by an integrator reading the pending slot.
    function setRedemptionFee(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_REDEMPTION_FEE_BPS) revert FeeTooHigh(feeBps, MAX_REDEMPTION_FEE_BPS);

        uint16 live = redemptionFeeBps;
        if (feeBps > live) {
            // Overwrites any increase already pending, and restarts the clock with it. A
            // second announcement is a new announcement; inheriting the first one's remaining
            // time would let an owner announce 21 bps, wait 59 minutes, and then raise the
            // pending value to 100 with a minute's notice.
            uint64 effectiveAt = uint64(block.timestamp) + FEE_INCREASE_DELAY;
            pendingRedemptionFeeBps = feeBps;
            redemptionFeeEffectiveAt = effectiveAt;
            emit RedemptionFeeIncreaseScheduled(live, feeBps, effectiveAt);
            return;
        }

        _clearPendingRedemptionFee(feeBps);
        emit RedemptionFeeUpdated(live, feeBps);
        redemptionFeeBps = feeBps;
    }

    /// @notice Apply an increase whose announced delay has elapsed. **Permissionless.**
    ///
    ///         Anyone may call it because there is nothing here to abuse: the value and the
    ///         earliest time it can land were both fixed by the owner an hour ago and are
    ///         public. Gating it on the owner would only add a way for the fee to appear
    ///         raised — announced, elapsed, quoted against by a cautious integrator — while
    ///         the live fee sits at the old value because nobody sent the second transaction.
    ///         Permissionless makes "the hour has passed" and "the fee is live" the same
    ///         observable fact for anyone willing to pay the gas.
    function commitRedemptionFee() external {
        uint64 effectiveAt = redemptionFeeEffectiveAt;
        if (effectiveAt == 0) revert NoPendingFeeIncrease();
        if (block.timestamp < effectiveAt) {
            revert FeeIncreaseNotReady(effectiveAt, uint64(block.timestamp));
        }

        uint16 feeBps = pendingRedemptionFeeBps;
        // Re-checked even though scheduling checked it. The ceiling is a constant today, but
        // this contract is upgradeable and an upgrade that lowers it must not be undone by a
        // value announced against the old one, which would be the one path into a fee above
        // the cap.
        if (feeBps > MAX_REDEMPTION_FEE_BPS) revert FeeTooHigh(feeBps, MAX_REDEMPTION_FEE_BPS);

        uint16 live = redemptionFeeBps;
        pendingRedemptionFeeBps = 0;
        redemptionFeeEffectiveAt = 0;
        redemptionFeeBps = feeBps;

        emit RedemptionFeeIncreaseCommitted(live, feeBps, effectiveAt);
        // Also emitted so that every change to the LIVE fee, from either direction, carries
        // exactly one `RedemptionFeeUpdated`. An indexer that already watches it needs no
        // change to keep reporting the fee redemptions actually charge.
        emit RedemptionFeeUpdated(live, feeBps);
    }

    /// @notice Drop an announced increase before it goes live (owner only). The live fee is
    ///         untouched — it was never raised in the first place.
    function cancelPendingRedemptionFee() external onlyOwner {
        if (redemptionFeeEffectiveAt == 0) revert NoPendingFeeIncrease();
        _clearPendingRedemptionFee(redemptionFeeBps);
    }

    /// @dev Clear any announced increase, emitting the cancellation with `remainingFee` as the
    ///      fee left in force. Silent when nothing is pending, because both callers reach it on
    ///      paths that are legitimate with or without a pending value.
    function _clearPendingRedemptionFee(uint16 remainingFee) private {
        uint64 effectiveAt = redemptionFeeEffectiveAt;
        if (effectiveAt == 0) return;
        uint16 dropped = pendingRedemptionFeeBps;
        pendingRedemptionFeeBps = 0;
        redemptionFeeEffectiveAt = 0;
        emit RedemptionFeeIncreaseCancelled(remainingFee, dropped, effectiveAt);
    }

    /// @notice Set an aggregate principal ceiling. Lowering it never blocks redemptions.
    ///         Zero means unlimited for backwards-compatible upgrades; new pools should set a
    ///         measured nonzero canary cap before accepting public minting.
    function setLiabilityCap(uint256 newCap) external onlyOwner {
        emit LiabilityCapUpdated(liabilityCap, newCap);
        liabilityCap = newCap;
    }

    // ─── View helpers ────────────────────────────────────────────────────

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + yieldSource.balanceOf(address(asset));
    }

    /// @notice The payout `redeem(token, amount, ...)` makes when the reserve can deliver in
    ///         full: `amount` less the redemption fee. What a caller should pass as
    ///         `minAssetsOut` to insist on that.
    ///
    ///         Quotes the LIVE fee and never a pending increase, which is what makes this
    ///         quote good for at least `FEE_INCREASE_DELAY`: an increase has to be announced
    ///         before it can be committed, so a fill routed against this number cannot be
    ///         overtaken by a fee move the caller could not see. A caller that wants to know
    ///         whether a change is coming reads `redemptionFeeEffectiveAt`, which is zero when
    ///         nothing is pending.
    function previewRedeem(uint256 amount) external view returns (uint256) {
        return amount - amount * redemptionFeeBps / BPS;
    }

    function isRegistered(address token) external view returns (bool) {
        return brands[token].registered;
    }

    function outstandingOf(address token) external view returns (uint256) {
        return brands[token].outstanding;
    }

    function allBrandTokensLength() external view returns (uint256) {
        return allBrandTokens.length;
    }

    /// @notice This brand's total accrued (unclaimed) yield entitlement, including yield
    ///         earned since its last on-chain settle. Read-only preview of `claimYield`.
    function pendingYield(address token) external view returns (uint256) {
        Brand storage b = brands[token];
        if (!b.registered) revert UnknownBrand();

        uint256 cyt = cumulativeYieldPerToken;
        uint256 assets = totalAssets();
        uint256 supply = totalPooledSupply;
        if (supply > 0 && assets > lastAccrualAssets) {
            uint256 growth = assets - lastAccrualAssets;
            uint256 recovered = Math.min(growth, lossCarryforward);
            cyt += (growth - recovered).mulDiv(WAD, supply);
        }

        uint256 delta = cyt - b.indexCheckpoint;
        return b.accruedYield + b.outstanding.mulDiv(delta, WAD);
    }

    // ─── Internal ────────────────────────────────────────────────────────

    function _brand(address token) internal view returns (Brand storage b) {
        b = brands[token];
        if (!b.registered) revert UnknownBrand();
    }

    /// @dev Roll any pool-wide yield earned since the last accrual into
    ///      `cumulativeYieldPerToken`, then settle `token`'s brand against it. Must run
    ///      before any change to `b.outstanding` so the entitlement already earned on the
    ///      OLD outstanding amount is credited before that amount moves.
    function _settleBrand(Brand storage b) internal {
        _accrueGlobal();
        uint256 delta = cumulativeYieldPerToken - b.indexCheckpoint;
        if (delta > 0 && b.outstanding > 0) {
            b.accruedYield += b.outstanding.mulDiv(delta, WAD);
        }
        b.indexCheckpoint = cumulativeYieldPerToken;
    }

    /// @dev Attribute pool-wide asset growth since the last sync to `cumulativeYieldPerToken`.
    ///      Growth is only ever yield here because every supply-changing call re-syncs
    ///      `lastAccrualAssets` in the same transaction (see `_syncAccrualBaseline`), so by
    ///      the next call any further growth can only have come from the yield source.
    function _accrueGlobal() internal {
        uint256 assets = totalAssets();
        uint256 supply = totalPooledSupply;
        if (assets < lastAccrualAssets) {
            lossCarryforward += lastAccrualAssets - assets;
        } else if (assets > lastAccrualAssets) {
            uint256 growth = assets - lastAccrualAssets;
            uint256 recovered = Math.min(growth, lossCarryforward);
            lossCarryforward -= recovered;
            if (supply > 0) {
                cumulativeYieldPerToken += (growth - recovered).mulDiv(WAD, supply);
            }
        }
        lastAccrualAssets = assets;
    }

    function _syncAccrualBaseline() internal {
        lastAccrualAssets = totalAssets();
    }

    /// @dev Pull `amount` from the yield source if idle balance is insufficient.
    function _recallIfNeeded(uint256 amount) internal {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= amount) return;

        uint256 shortfall = amount - idle;
        // +1 buffer: yield sources (e.g. Morpho Blue) may return up to 1 unit less than
        // requested due to share<->asset floor-division rounding — see BrandedVault._recallIfNeeded.
        uint256 recalled = yieldSource.withdraw(address(asset), shortfall + 1, address(this));
        emit Recalled(recalled);
    }

    /// @dev Caps a payout at the pool's actual idle balance. The `+1` buffer in
    ///      `_recallIfNeeded` covers ordinary withdrawal-side rounding, but a real yield
    ///      source's principal can itself be a wei or two short of book value from
    ///      deposit-side share<->asset rounding in a non-empty market — in which case even
    ///      a full-position recall cannot manufacture the missing wei. Capping here means
    ///      that dust comes back as a payout slightly smaller than requested instead of a
    ///      reverted transaction.
    function _cappedByIdle(uint256 amount) internal view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        return amount < idle ? amount : idle;
    }
}
