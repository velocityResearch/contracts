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
/// ## The split: the protocol's share, then all of the rest to the LPs
///
///         `sweep` divides everything held two ways: `protocolBps` to the protocol treasury,
///         and every remaining wei — the rounding dust included — to the market's
///         `LpRewardDistributor`. `protocolBps` is zero by default, so in an ordinary market
///         the whole float is the liquidity providers'.
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
///         **The split is fixed at initialisation and has no setter**, but "fixed" means fixed
///         for the life of this implementation rather than of the bytecode: every market's
///         vault shares one beacon, so a timelocked upgrade could change how these numbers are
///         read. See `AssetLockbox`'s successor note in `ASSET_MARKETS.md` for the same
///         qualification at length.
///
///         **Halted by `ProtocolGuard`.** `harvest`, `sweep` and `sweepStrayAsset` all stop
///         while the protocol is paused. None of them is a holder's exit — that is
///         `SharedReservePool.redeem`, which never pauses — nor an LP's, which is
///         `LpRewardDistributor.unstake`, which never pauses either.
contract BrandFeeVault is Initializable, GuardedUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint16 public constant BPS_DENOMINATOR = 10_000;

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

    /// @dev Room for later versions to add state without disturbing a live market's layout.
    uint256[40] private __gap;

    event Initialized(address indexed distributor);
    event Harvested(uint256 claimed);
    event Swept(uint256 toProtocol, uint256 toLps);
    event StrayAssetRecovered(uint256 amount);

    error OnlyFactory();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error FeeLeavesLpsNothing();
    error NothingToSweep();
    error BelowMinSweep(uint256 held, uint256 minimum);

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

    /// @notice Pull this brand's accrued float yield out of the reserve and into this vault.
    ///
    ///         Permissionless, and deliberately separate from `sweep`: harvesting is cheap and
    ///         idempotent, sweeping moves money. Spamming this moves nothing to anyone — the
    ///         reserve pays what has accrued and no more.
    function harvest() external whenNotPaused returns (uint256 claimed) {
        claimed = treasury.claim(address(this));
        totalHarvested += claimed;

        emit Harvested(claimed);
    }

    /// @notice Everything this vault currently holds, in reserve-asset units. brandUSD and
    ///         USDG are 1:1 claims on the same reserve, so the two simply add.
    function balance() public view returns (uint256) {
        return usdg.balanceOf(address(this)) + brandToken.balanceOf(address(this));
    }

    /// @notice This brand's yield that has accrued but not yet been harvested.
    function pendingYield() external view returns (uint256) {
        return treasury.pendingYield();
    }

    /// @notice The liquidity providers' share of everything harvested, in basis points.
    function lpBps() external view returns (uint16) {
        return BPS_DENOMINATOR - protocolBps;
    }

    // ─── Payout ──────────────────────────────────────────────────────────

    /// @notice Send the protocol its share and stream the rest to the market's LPs.
    ///
    ///         Permissionless. Both destinations are written once at initialisation and never
    ///         again, so the caller decides only when — and, because the distributor's period
    ///         never moves, not even that is worth anything to them.
    ///
    /// @return toProtocol The protocol treasury's share, in reserve-asset units
    /// @return toLps      What was handed to the distributor, in brandUSD
    function sweep() external whenNotPaused returns (uint256 toProtocol, uint256 toLps) {
        if (address(distributor) == address(0)) revert NotInitialized();

        uint256 total = balance();
        if (total == 0) revert NothingToSweep();
        if (total < minSweep) revert BelowMinSweep(total, minSweep);

        toProtocol = total.mulDiv(protocolBps, BPS_DENOMINATOR);

        // The LPs take the remainder rather than their own rounded share, so the rounding dust
        // goes to them rather than to the protocol.
        toLps = total - toProtocol;

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
        // of it clear of the yield source entirely.
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
