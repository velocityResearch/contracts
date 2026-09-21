// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../pool/PoolBrandTreasury.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {LpRewardDistributor} from "./LpRewardDistributor.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";

/// @notice The read this vault needs off `ProtocolGuard`: who governs it. `IProtocolGuard` is
///         deliberately the pause registry's read side only, and the vault needs one more —
///         see `BrandFeeVault.splitAdmin`.
interface IGuardOwner {
    function owner() external view returns (address);
}

/// @title BrandFeeVault
/// @notice A market's float yield lands here and goes to the people who provide its liquidity.
///         One per market.
///
///         **One income stream arrives: float yield.** The USDG backing the brand's outstanding
///         supply earns in the reserve's yield source. This vault is the brand's
///         `PoolBrandTreasury` admin, so `harvest()` pulls it. Outstanding supply counts tokens
///         wherever they sit — including in the market's own pool — so the AMM's stable-side
///         reserves are part of the float that funds this.
///
///         **Trading fees do not come here.** The pool's `ProtocolFeeHook` takes half of a
///         market's 1% headline fee in `afterSwap`, off the swap's unspecified leg, and pays
///         it to the protocol treasury directly; the other half is the pool's own LP fee on
///         the input and never leaves Uniswap's accounting. Neither touches this contract.
///         See `AssetMarketFactory._openMarket`.
///
/// ## The split: the protocol's share, the configured recipients', then all of the rest to LPs
///
///         `sweep` divides everything held three ways: `protocolBps` to the protocol treasury,
///         each configured split recipient's `bps` to a balance that recipient claims for
///         itself, and every remaining wei — the rounding dust included — to the market's
///         `LpRewardDistributor`. `protocolBps` is zero and the recipient list is empty by
///         default, so in an ordinary market the whole float is the liquidity providers'.
///
///         **This replaces a three-way split whose third leg bought the market's asset and
///         locked it forever.** That buyback is gone: `BuybackEngine` and `AssetLockbox` no
///         longer exist, and a market's yield is now an LP subsidy rather than a permanent bid
///         under its own token. The reason is a product one — liquidity is what a market needs
///         first, and paying for it directly beats paying for it through a price — and the
///         consequence should be stated plainly: nothing here buys the asset any more.
///
///         **The LP leg is a transfer to the distributor, not a donation to the pool.** The
///         earlier revision paid LPs with `PoolManager.donate`, which credits `feeGrowthGlobal`
///         exactly as a swap fee does and needs no ledger at all. That is the better mechanism
///         while the LP share is a *slice* of the yield, and the wrong one once it is all of
///         it: `sweep` is permissionless, so anyone could add a large full-range position,
///         sweep, and remove it in the same transaction, taking almost the whole harvest for a
///         position that carried risk for no time whatsoever. Donation weights by liquidity at
///         an instant, and the instant is exactly what an attacker picks. The distributor
///         weights by liquidity × time instead. See `LpRewardDistributor`.
///
///         One property is lost with the donation and worth naming: an LP who does not stake
///         earns the pool's swap fees and no float. Staking is a second step, and a deliberate
///         one.
///
///         **The payout is in brandUSD**, because that is what the distributor pays out and
///         what the pool holds. USDG held here is minted into it 1:1 on the way through;
///         existing brandUSD is spent first, so a vault holding enough of it never touches the
///         reserve — which matters because minting is what couples this call to the yield
///         source, per `SharedReservePool.mint`.
///
///         **`minSweep` is one whole unit of the reserve asset** — one USDG. It is a floor
///         against sweeping dust, not a rate limiter: the distributor's `notifyReward` never
///         moves a running period's end date, so the caller of `sweep` chooses the moment and
///         gains nothing by it. That is what lets the floor be this low.
///
///         The market's asset can also arrive here, as a donation or a mistaken transfer.
///         `sweepStrayAsset` sends it to the protocol treasury — see the note there.
///
///         **The split is configurable, by the protocol timelock, and only forwards.** The
///         protocol's own leg — `protocolBps` — is still fixed at initialisation and still has
///         no setter. What can be added is a short list of further recipients (`setSplits`),
///         each with a share and a role label, for the cases the protocol's own leg cannot
///         express: a market's creator, a launch partner, a referrer. The list is bounded at
///         `MAX_SPLIT_RECIPIENTS` so a sweep can never iterate unboundedly, and the total of
///         every configured leg must still leave the liquidity providers something — the
///         invariant `initialize` checks for `protocolBps` alone, extended to the whole list.
///
///         **Changing it cannot move money that has already been earned.** A recipient's share
///         is credited to `claimableSplit` at the moment of the sweep that earned it and sits
///         in this vault, held back from the next sweep by `reservedForSplits`, until that
///         recipient calls `claimSplit`. Reconfiguring the list rewrites who earns from the
///         *next* sweep and touches no balance already credited — a recipient removed from the
///         list entirely can still claim everything it was owed.
///
///         **Halted by `ProtocolGuard`.** `harvest`, `sweep` and `sweepStrayAsset` all stop
///         while the protocol is paused. None of them is a holder's exit — that is
///         `SharedReservePool.redeem`, which never pauses — nor an LP's, which is
///         `LpRewardDistributor.unstake`, which never pauses either.
contract BrandFeeVault is Initializable, GuardedUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The most recipients the configurable split may carry. `sweep` walks this list,
    ///         and a sweep that can be made to run out of gas is a sweep that can be stopped.
    uint256 public constant MAX_SPLIT_RECIPIENTS = 8;

    // ─── Wiring ──────────────────────────────────────────────────────────
    //
    // Storage rather than `immutable` throughout. An immutable lives in the implementation's
    // own bytecode, and every market's vault delegates into the SAME implementation behind the
    // beacon — so an immutable set for one market would be read by all of them. These are set
    // once in `initialize` and never written again, which is the same guarantee in practice.

    /// @notice The reserve this brand is pooled in.
    SharedReservePool public reservePool;

    /// @notice This brand's treasury. This vault is its admin, which is the whole of the
    ///         integration with the reserve — one address, set at market creation.
    PoolBrandTreasury public treasury;

    /// @notice The reserve's underlying (USDG).
    IERC20 public usdg;

    /// @notice The market's branded stablecoin: the unit its pool is quoted in, and the token
    ///         the LP reward is paid in.
    IERC20 public brandToken;

    /// @notice The token this market trades. Never paid out by this contract — see
    ///         `sweepStrayAsset`.
    IERC20 public asset;

    /// @notice Where the protocol's share of YIELD goes. Zero-rated by default — the protocol's
    ///         revenue is the trading skim, which never passes through here.
    address public protocolTreasury;

    /// @notice The protocol's share of everything harvested, in basis points. Fixed forever.
    ///         Whatever is left is the liquidity providers'.
    uint16 public protocolBps;

    /// @notice The market's LP reward distributor. Set once by the factory, for the same
    ///         ordering reason the buyback engine was: the distributor needs this vault's
    ///         address at its own initialisation, so one of the two has to exist first.
    LpRewardDistributor public distributor;

    /// @notice The factory that created this vault; the only address that may bind the
    ///         distributor.
    address public factory;

    /// @notice The smallest balance `sweep` will act on: one whole unit of the reserve asset.
    uint256 public minSweep;

    // ─── Running totals ──────────────────────────────────────────────────

    uint256 public totalHarvested;
    uint256 public totalToProtocol;
    uint256 public totalToLps;
    uint256 public totalStrayAssetRecovered;

    // ─── The configurable split ──────────────────────────────────────────

    /// @notice One leg of the configurable split.
    /// @param recipient Who is credited. Never the zero address, never this vault, never the
    ///                  distributor — the distributor is already the residual destination.
    /// @param bps       This leg's share of every sweep, in basis points.
    /// @param role      A label for what this leg is: "protocol", "creator", "partner",
    ///                  "referral". Carried for the indexer's benefit; this contract only
    ///                  emits it.
    struct SplitEntry {
        address recipient;
        uint16 bps;
        bytes32 role;
    }

    /// @dev The ordered list. Private because the getter Solidity generates for an array of
    ///      structs returns the members flattened one index at a time; `splits()` returns the
    ///      whole list in one call instead.
    SplitEntry[] private _splits;

    /// @notice What a split recipient has earned and not yet taken, in reserve-asset units.
    ///         Survives that recipient being removed from the list.
    mapping(address recipient => uint256 amount) public claimableSplit;

    /// @notice The sum of every unclaimed `claimableSplit`. Held back from `sweep`, which is
    ///         the whole of how a credited balance is kept out of a later distribution.
    uint256 public reservedForSplits;

    /// @notice Running total credited to split recipients, claimed or not.
    uint256 public totalToSplits;

    /// @dev Room for later versions to add state without disturbing a live market's layout.
    ///      Reduced from forty: four slots are spent on the configurable split — the list's
    ///      length, the claim ledger, `reservedForSplits` and `totalToSplits`. New state is
    ///      appended below the split's, never inserted above it.
    uint256[36] private __gap;

    event Initialized(address indexed distributor);
    event Harvested(uint256 claimed);
    event Swept(uint256 toProtocol, uint256 toLps);
    event StrayAssetRecovered(uint256 amount);
    event SplitsConfigured(address indexed by, uint256 entries, uint16 configuredBps);
    event SplitAccrued(address indexed recipient, bytes32 indexed role, uint256 amount);
    event SplitClaimed(address indexed recipient, uint256 usdgAmount, uint256 brandAmount);

    error OnlyFactory();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error FeeLeavesLpsNothing();
    error NothingToSweep();
    error BelowMinSweep(uint256 held, uint256 minimum);
    error NotSplitAdmin();
    error TooManySplitRecipients();
    error DuplicateSplitRecipient(address recipient);
    error InvalidSplitRecipient(address recipient);
    error ZeroSplitBps();
    error NothingToClaim();

    constructor() {
        _disableInitializers();
    }

    /// @param _factory The address allowed to call `setDistributor`. Passed explicitly rather
    ///                 than taken from `msg.sender`, because behind a beacon proxy the
    ///                 initialising caller is the proxy's own constructor, not the factory.
    function initialize(
        SharedReservePool _reservePool,
        address _treasury,
        address _brandToken,
        address _asset,
        address _protocolTreasury,
        uint16 _protocolBps,
        address _factory,
        address _guard
    ) external initializer {
        if (
            address(_reservePool) == address(0) || _treasury == address(0)
                || _brandToken == address(0) || _asset == address(0)
                || _protocolTreasury == address(0) || _factory == address(0)
        ) revert ZeroAddress();

        __Guarded_init(_guard);

        // A market whose entire yield is a protocol fee is not the product this contract
        // implements: the LP subsidy is the reason the market exists and keeps a share whatever
        // the fee is set to. The factory's own ceiling sits far below this. Checked here
        // anyway, so the invariant lives with the contract that depends on it.
        if (_protocolBps >= BPS_DENOMINATOR) revert FeeLeavesLpsNothing();

        reservePool = _reservePool;
        treasury = PoolBrandTreasury(_treasury);
        address underlying = address(_reservePool.asset());
        usdg = IERC20(underlying);
        brandToken = IERC20(_brandToken);
        asset = IERC20(_asset);
        protocolTreasury = _protocolTreasury;
        protocolBps = _protocolBps;
        factory = _factory;

        // One whole unit of the reserve asset, read off the token rather than hardcoded: the
        // same "1 USDG" is 1e6 here and would be 1e18 against an 18-decimal reserve.
        minSweep = 10 ** IERC20Metadata(underlying).decimals();
    }

    /// @notice Bind the distributor. Callable once, by the factory, during market creation.
    function setDistributor(LpRewardDistributor _distributor) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (address(distributor) != address(0)) revert AlreadyInitialized();
        if (address(_distributor) == address(0)) revert ZeroAddress();

        distributor = _distributor;
        emit Initialized(address(_distributor));
    }

    // ─── Income ──────────────────────────────────────────────────────────

    /// @notice Pull this market's float yield out of the reserve and into this vault.
    ///
    ///         Permissionless, and deliberately separate from `sweep`: harvesting is cheap and
    ///         idempotent, sweeping moves money. Spamming this moves nothing to anyone — the
    ///         reserve pays what has accrued and no more.
    ///
    ///         **Two routes, decided by who owns the dollar.** A market that minted its own
    ///         unit is that treasury's admin and takes the whole of the brand's yield. A market
    ///         quoted in a dollar it does not own — every launchpad graduate — takes only the
    ///         share of that dollar's yield its own pool's float earns, through
    ///         `claimFloatShare`. Branching on the live admin rather than on a stored flag
    ///         means a treasury whose admin is ever rotated does not strand this vault.
    function harvest() external whenNotPaused returns (uint256 claimed) {
        claimed = treasury.admin() == address(this)
            ? treasury.claim(address(this))
            : treasury.claimFloatShare();
        totalHarvested += claimed;

        emit Harvested(claimed);
    }

    /// @notice Everything this vault currently holds, in reserve-asset units. brandUSD and
    ///         USDG are 1:1 claims on the same reserve, so the two simply add.
    function balance() public view returns (uint256) {
        return usdg.balanceOf(address(this)) + brandToken.balanceOf(address(this));
    }

    /// @notice What `sweep` would actually divide: everything held, less what split recipients
    ///         have already earned and not yet claimed.
    ///
    ///         The subtraction is what keeps a credited balance out of a later distribution —
    ///         without it, a recipient's unclaimed share would be swept a second time and paid
    ///         to everyone including itself. Saturating rather than checked, so a view can
    ///         never revert on a vault whose tokens have somehow moved beneath it.
    function distributableBalance() public view returns (uint256) {
        uint256 held = balance();
        uint256 reserved = reservedForSplits;
        return held > reserved ? held - reserved : 0;
    }

    /// @notice This brand's yield that has accrued but not yet been harvested.
    function pendingYield() external view returns (uint256) {
        return treasury.pendingYield();
    }

    /// @notice The liquidity providers' share of everything harvested, in basis points: what
    ///         the protocol's leg and every configured leg leave behind. Always at least one.
    function lpBps() external view returns (uint16) {
        return BPS_DENOMINATOR - protocolBps - totalSplitBps();
    }

    // ─── The configurable split ──────────────────────────────────────────

    /// @notice Who may configure this vault's split: the protocol timelock, read live off the
    ///         shared guard rather than stored here.
    ///
    ///         This vault has no owner of its own, and adding one would mean either an
    ///         initialiser parameter — which every live market has already passed through — or
    ///         a bootstrap write that nobody is authorised to make. The guard is already in
    ///         every vault's storage, is already the contract that can halt this one, and its
    ///         owner is already the timelock that owns the beacon this vault's implementation
    ///         comes from. Reading it is the same authority by a shorter route.
    function splitAdmin() public view returns (address) {
        return IGuardOwner(address(guard())).owner();
    }

    modifier onlySplitAdmin() {
        if (msg.sender != splitAdmin()) revert NotSplitAdmin();
        _;
    }

    /// @notice The configured split, in order.
    function splits() external view returns (SplitEntry[] memory) {
        return _splits;
    }

    /// @notice How many legs the configured split has.
    function splitCount() external view returns (uint256) {
        return _splits.length;
    }

    /// @notice The sum of every configured leg, in basis points. Excludes `protocolBps`.
    function totalSplitBps() public view returns (uint16) {
        uint256 total;
        uint256 n = _splits.length;
        for (uint256 i; i < n; ++i) {
            total += _splits[i].bps;
        }
        // Bounded below `BPS_DENOMINATOR` by `setSplits`, which is the only writer.
        return uint16(total);
    }

    /// @notice Replace the configured split wholesale.
    ///
    ///         Wholesale rather than per-entry because the invariant being defended is a
    ///         property of the whole list — its total, and the absence of duplicates within it
    ///         — and a list edited a row at a time has to hold that invariant in states nobody
    ///         intended. Passing the list one wants is also the only form in which what one is
    ///         signing is legible.
    ///
    ///         Not paused-guarded: it moves nothing. `sweep` and `claimSplit` are where the
    ///         money is, and both stop with the protocol.
    ///
    /// @param entries The new list. Empty clears the split back to protocol-and-LPs.
    function setSplits(SplitEntry[] calldata entries) external onlySplitAdmin {
        uint256 n = entries.length;
        if (n > MAX_SPLIT_RECIPIENTS) revert TooManySplitRecipients();

        uint256 totalBps = protocolBps;
        for (uint256 i; i < n; ++i) {
            SplitEntry calldata e = entries[i];
            if (e.recipient == address(0)) revert ZeroAddress();
            if (e.recipient == address(this) || e.recipient == address(distributor)) {
                revert InvalidSplitRecipient(e.recipient);
            }
            if (e.bps == 0) revert ZeroSplitBps();

            // Quadratic in a list bounded at eight, which is cheaper than the mapping the
            // general case would need and leaves no index to keep in step with the array.
            for (uint256 j; j < i; ++j) {
                if (entries[j].recipient == e.recipient) {
                    revert DuplicateSplitRecipient(e.recipient);
                }
            }

            totalBps += e.bps;
        }

        // The same invariant `initialize` holds for the protocol's leg alone: the liquidity
        // providers keep a share of this market's float whatever else is configured.
        if (totalBps >= BPS_DENOMINATOR) revert FeeLeavesLpsNothing();

        delete _splits;
        for (uint256 i; i < n; ++i) {
            _splits.push(entries[i]);
        }

        emit SplitsConfigured(msg.sender, n, uint16(totalBps - protocolBps));
    }

    /// @notice Pay a split recipient everything credited to it.
    ///
    ///         Permissionless in who calls it and not in who is paid: the funds go to
    ///         `recipient` whoever pushes the button, which lets a keeper settle a recipient
    ///         that cannot transact for itself without being able to redirect anything.
    ///
    ///         Paid in USDG as far as the USDG balance goes and in brandUSD for the remainder,
    ///         exactly as the protocol's leg is: both are 1:1 claims on the same reserve.
    function claimSplit(address recipient) external whenNotPaused returns (uint256 amount) {
        amount = claimableSplit[recipient];
        if (amount == 0) revert NothingToClaim();

        claimableSplit[recipient] = 0;
        reservedForSplits -= amount;

        uint256 usdgHeld = usdg.balanceOf(address(this));
        uint256 fromUsdg = Math.min(amount, usdgHeld);
        uint256 fromBrand = amount - fromUsdg;

        if (fromUsdg > 0) usdg.safeTransfer(recipient, fromUsdg);
        if (fromBrand > 0) brandToken.safeTransfer(recipient, fromBrand);

        emit SplitClaimed(recipient, fromUsdg, fromBrand);
    }

    // ─── Payout ──────────────────────────────────────────────────────────

    /// @notice Send the protocol its share, credit each configured split recipient its own,
    ///         and stream everything left to the market's LPs.
    ///
    ///         Permissionless. The protocol's destination and the LPs' are written once at
    ///         initialisation and never again; the configured legs are the timelock's and are
    ///         credited rather than sent, so no destination here is chosen by the caller. The
    ///         caller decides only when — and, because the distributor's period never moves,
    ///         not even that is worth anything to them.
    ///
    /// @return toProtocol The protocol treasury's share, in reserve-asset units
    /// @return toLps      What was handed to the distributor, in brandUSD
    function sweep() external whenNotPaused returns (uint256 toProtocol, uint256 toLps) {
        if (address(distributor) == address(0)) revert NotInitialized();

        uint256 total = distributableBalance();
        if (total == 0) revert NothingToSweep();
        if (total < minSweep) revert BelowMinSweep(total, minSweep);

        toProtocol = total.mulDiv(protocolBps, BPS_DENOMINATOR);

        // Every configured leg is floored and credited rather than sent. The tokens stay here
        // until the recipient claims them, and `reservedForSplits` is what keeps this sweep's
        // credits out of the next sweep's `total`.
        uint256 toSplits;
        uint256 n = _splits.length;
        for (uint256 i; i < n; ++i) {
            SplitEntry storage e = _splits[i];
            uint256 share = total.mulDiv(e.bps, BPS_DENOMINATOR);
            if (share == 0) continue;

            toSplits += share;
            claimableSplit[e.recipient] += share;
            emit SplitAccrued(e.recipient, e.role, share);
        }
        if (toSplits > 0) {
            reservedForSplits += toSplits;
            totalToSplits += toSplits;
        }

        // The LPs take the remainder rather than their own rounded share, so the rounding dust
        // goes to them rather than to the protocol or to a split recipient. Every leg is a
        // floor of a share of `total` and the shares sum below one whole, so this is positive.
        toLps = total - toProtocol - toSplits;

        // The protocol's cut is paid in USDG as far as the USDG balance goes and in brandUSD
        // for any remainder. Both are 1:1 claims on the same reserve, so which one the protocol
        // receives is a wrapper detail, not a difference in value.
        if (toProtocol > 0) {
            uint256 usdgHeld = usdg.balanceOf(address(this));
            uint256 protocolFromUsdg = Math.min(toProtocol, usdgHeld);
            uint256 protocolFromBrand = toProtocol - protocolFromUsdg;

            if (protocolFromUsdg > 0) usdg.safeTransfer(protocolTreasury, protocolFromUsdg);
            if (protocolFromBrand > 0) {
                brandToken.safeTransfer(protocolTreasury, protocolFromBrand);
            }
        }

        // The reward is paid in brandUSD, so whatever is still held as USDG is minted into it
        // 1:1. Existing brandUSD is spent first, which keeps a vault that already holds enough
        // of it clear of the yield source entirely. What the split recipients are owed is left
        // behind in whichever wrapper it happens to sit in; `claimSplit` spends either.
        uint256 brandHeld = brandToken.balanceOf(address(this));
        if (brandHeld < toLps) {
            uint256 toMint = toLps - brandHeld;
            usdg.forceApprove(address(reservePool), toMint);
            reservePool.mint(address(brandToken), toMint, address(this));
        }

        totalToProtocol += toProtocol;
        totalToLps += toLps;

        brandToken.safeTransfer(address(distributor), toLps);
        // Told after the transfer, and checked there: `notifyReward` refuses to promise more
        // than the distributor actually holds.
        distributor.notifyReward(toLps);

        emit Swept(toProtocol, toLps);
    }

    /// @notice Send the market's asset held here to the protocol treasury.
    ///
    ///         Nothing routes the market's asset to this contract — the trading skim is paid to
    ///         the protocol treasury directly — so in practice this recovers donations and
    ///         mistaken transfers. It is kept because the alternative is asset stranded in a
    ///         contract with no other way to move it.
    ///
    ///         It goes to the protocol treasury rather than to the LPs because paying an LP
    ///         reward in an arbitrary market token — which may be an issuer-upgradeable proxy,
    ///         per ASSET_MARKETS.md §3.1 — would hand them a position they never asked for, and
    ///         the distributor pays in one token by design. Recorded separately from
    ///         `totalToProtocol`, because it is recovery rather than income: it was never part
    ///         of a split.
    function sweepStrayAsset() external whenNotPaused returns (uint256 amount) {
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();

        totalStrayAssetRecovered += amount;
        asset.safeTransfer(protocolTreasury, amount);

        emit StrayAssetRecovered(amount);
    }
}
