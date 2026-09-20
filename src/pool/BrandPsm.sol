// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {SharedReservePool} from "./SharedReservePool.sol";

/// @title BrandPsm
/// @notice One brand token's 1:1 window onto its `SharedReservePool`, wearing MakerDAO's
///         `DssLitePsm` interface so that an aggregator which already integrates a PSM can
///         quote and settle this reserve without writing a new venue.
///
///         **This contract holds nothing and can do nothing.** It has no owner, no
///         initializer, no upgrade path and no privileged caller. `sellGem` mints through
///         `SharedReservePool.mint`, which anybody may call; `buyGem` redeems through
///         `SharedReservePool.redeem`, which burns from *its own caller* and therefore burns
///         this facade's transient balance, never a user's. Deploying one of these grants no
///         authority that the caller did not already have by calling the reserve directly.
///         Its only purpose is to make an existing, permissionless capability legible to code
///         that was written against Maker.
///
///         **Why the shape is worth copying.** The reserve leg of every Stables trade is a
///         fixed-rate mint/redeem with a fee on the way out and a cap on each direction —
///         structurally the same object as a PSM's `tin`/`tout` and debt ceiling. Kyber's
///         `lite-psm` liquidity source already models a *minting* PSM (its `IsMint` mode skips
///         reading a dai inventory the contract does not keep), so matching this interface
///         turns their integration into configuration. 0x's `MakerPSM` action is pinned to
///         mainnet addresses and cannot be reused, but matching the interface still reduces
///         their work to re-pointing a known pattern.
///
///         **Naming.** `gem` is the reserve asset (USDG); `dai` is the brand token. One
///         instance serves exactly one brand, because both aggregators key a venue by contract
///         address and a multi-brand contract cannot answer `dai()` with one address.
///
/// @dev    Three deliberate departures from `DssLitePsm`, each of which an integrator must read
///         before trusting a copy-pasted formula:
///
///         1. **`dai` is 6-decimal, not 18.** A brand token mirrors the reserve asset's
///            decimals so that the 1:1 peg is exact in integer units. `to18ConversionFactor`
///            is therefore 1, and it is the gem→dai unit factor rather than a scale to WAD.
///            Any integrator carrying a hardcoded `WAD / GEM_basis` ratio must drop it.
///
///         2. **`tout` is quoted in the fee-inclusive direction.** `SharedReservePool.redeem`
///            takes its fee *out of* the amount burned (`out = in − in·bps/10000`), whereas a
///            PSM adds its fee *on top* (`in = out·(1 + tout)`). Reporting the raw fee would
///            make an integrator computing `gemOut = daiIn / (1 + tout)` ask this contract for
///            marginally more gem than `daiIn` can actually buy, and `buyGem` would revert on
///            a sell amount the integrator had already committed to. `tout` is therefore
///            `bps / (10000 − bps)`, the fee-on-top rate equivalent to our fee-inclusive one,
///            which makes both conventions land at or below what the reserve will pay. See
///            `tout` for the arithmetic.
///
///         3. **A pause halts `tin` only.** `SharedReservePool.mint` is guarded and `redeem` is
///            not, on purpose: a holder must be able to leave during an incident. That maps
///            exactly onto Maker's per-direction `HALTED` sentinel, so a paused reserve reports
///            `tin() == HALTED` while `tout()` keeps quoting.
contract BrandPsm {
    using SafeERC20 for IERC20;

    /// @notice Fee sentinel meaning "this direction is closed", as in `DssLitePsm`.
    uint256 public constant HALTED = type(uint256).max;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;

    /// @notice The reserve this window opens onto. Named `pocket` because that is where the
    ///         gem actually sits, which is the address an indexer must read a gem balance from.
    address public immutable pocket;

    /// @notice The reserve asset — USDG. `gem` in Maker's vocabulary.
    IERC20 public immutable gem;

    /// @notice The brand token this window mints and redeems. `dai` in Maker's vocabulary.
    IERC20 public immutable dai;

    /// @notice Gem units per dai unit. Both sides are 6-decimal here, so this is 1 — it is the
    ///         conversion factor between the two tokens, not a scale to 18 decimals.
    uint256 public immutable to18ConversionFactor;

    /// @notice `gem`'s decimals, as `DssLitePsm.dec()` reports them.
    uint256 public immutable dec;

    event SellGem(address indexed owner, uint256 value, uint256 fee);
    event BuyGem(address indexed owner, uint256 value, uint256 fee);

    error ZeroAddress();
    error UnknownBrand(address brand);
    error DecimalMismatch(uint8 gemDecimals, uint8 daiDecimals);
    error SellGemHalted();
    error ZeroAmount();

    /// @param reserve The `SharedReservePool` holding the backing.
    /// @param brand   A brand token already registered in `reserve`.
    constructor(SharedReservePool reserve, address brand) {
        if (address(reserve) == address(0) || brand == address(0)) revert ZeroAddress();
        if (!reserve.isRegistered(brand)) revert UnknownBrand(brand);

        IERC20 asset = reserve.asset();
        uint8 gemDecimals = IERC20Metadata(address(asset)).decimals();
        uint8 daiDecimals = IERC20Metadata(brand).decimals();
        // A brand token is minted 1:1 against the reserve asset, so its decimals must match or
        // the peg is not expressible in integer units and no single conversion factor exists.
        if (gemDecimals != daiDecimals) revert DecimalMismatch(gemDecimals, daiDecimals);

        pocket = address(reserve);
        gem = asset;
        dai = IERC20(brand);
        to18ConversionFactor = 1;
        dec = gemDecimals;

        // The reserve pulls the gem itself during `mint`. Standing and unbounded because this
        // contract never holds a balance between calls: every entry point ends with its own
        // balance back at zero, so the allowance is a standing claim on nothing.
        asset.forceApprove(address(reserve), type(uint256).max);
    }

    // ─── Quoting surface ─────────────────────────────────────────────────

    /// @notice Fee on `sellGem`, as a WAD fraction. Minting a brand token is free, so this is
    ///         zero — or `HALTED` while the reserve is paused, because `mint` is guarded.
    function tin() external view returns (uint256) {
        return SharedReservePool(pocket).paused() ? HALTED : 0;
    }

    /// @notice Fee on `buyGem`, as a WAD fraction added on top of the gem bought.
    ///
    /// @dev    The reserve charges `bps` of the amount *burned*: `out = in − in·bps/10000`.
    ///         A PSM charges `tout` of the gem *bought*: `in = out·(1 + tout)`. Equating the
    ///         two gives `1 + tout = 10000/(10000 − bps)`, so `tout = bps/(10000 − bps)`,
    ///         rounded up. At 20 bps that is 2.004008…e15 rather than the raw 2e15.
    ///
    ///         Rounding up is what makes the difference safe in both directions. An integrator
    ///         inverting `1 + tout` buys slightly less gem than the reserve would have paid, and
    ///         one subtracting `tout` — Kyber's form — buys less still. Both under-fill by a
    ///         fraction of a basis point; neither can ask for gem the reserve cannot deliver,
    ///         which is the failure that would revert a settled route.
    ///
    ///         Never `HALTED`: redemption is not pausable, by design.
    function tout() public view returns (uint256) {
        uint256 bps = SharedReservePool(pocket).redemptionFeeBps();
        if (bps == 0) return 0;
        uint256 keep = BPS - bps;
        return (bps * WAD + keep - 1) / keep;
    }

    /// @notice This contract is its own join, as `DssLitePsm` is. Present so an indexer that
    ///         reads `gemJoin()` to find the approval target gets this address and not zero.
    function gemJoin() external view returns (address) {
        return address(this);
    }

    /// @notice Maker's liveness flag: 1 unless the reserve is paused. Minting is what a pause
    ///         stops; `buyGem` keeps working either way, so prefer `tin`/`tout` over this.
    function live() external view returns (uint256) {
        return SharedReservePool(pocket).paused() ? 0 : 1;
    }

    // ─── Swapping ────────────────────────────────────────────────────────

    /// @notice Sell `gemAmt` of the reserve asset for the brand token, 1:1 and free.
    ///
    ///         Reverts `LiabilityCapExceeded` from the reserve when the mint would cross the
    ///         cap, and reverts while the reserve is paused. Both are quoted by
    ///         `MarketLens.maxMint`.
    ///
    /// @param usr    Recipient of the brand token.
    /// @param gemAmt Reserve asset to sell, in gem units.
    /// @return daiOutWad Brand tokens minted — equal to `gemAmt`, in dai units.
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 daiOutWad) {
        if (gemAmt == 0) revert ZeroAmount();
        if (SharedReservePool(pocket).paused()) revert SellGemHalted();

        gem.safeTransferFrom(msg.sender, address(this), gemAmt);
        daiOutWad = SharedReservePool(pocket).mint(address(dai), gemAmt, usr);

        emit SellGem(usr, gemAmt, 0);
    }

    /// @notice Buy exactly `gemAmt` of the reserve asset with the brand token, paying the
    ///         reserve's redemption fee.
    ///
    ///         **Exact-output, like Maker's.** The caller states the gem they want and this
    ///         contract pulls the brand needed to cover it, so an integrator must size its
    ///         allowance and balance from `tout` before calling. A caller who would rather
    ///         spend an exact amount of brand should call `SharedReservePool.redeem` directly —
    ///         it is exact-input, needs no approval, and is the cheaper path.
    ///
    ///         **Never pays short.** The reserve's own `redeem` truncates its payout to what it
    ///         can deliver this block rather than reverting, which is right for a holder
    ///         choosing to exit and wrong for a router that has already promised an amount.
    ///         This passes `gemAmt` as the reserve's `minAssetsOut`, so an under-delivery
    ///         reverts here instead of settling short. `MarketLens.redeemableAssets` quotes the
    ///         bound.
    ///
    /// @param usr    Recipient of the reserve asset.
    /// @param gemAmt Reserve asset to buy, in gem units.
    /// @return daiInWad Brand tokens taken from `msg.sender` and burned.
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 daiInWad) {
        if (gemAmt == 0) revert ZeroAmount();

        daiInWad = daiForGem(gemAmt);
        dai.safeTransferFrom(msg.sender, address(this), daiInWad);
        // Burns this contract's own brand — no approval to the reserve is needed — and pays
        // `usr` directly, reverting unless the full `gemAmt` arrives.
        SharedReservePool(pocket).redeem(address(dai), daiInWad, usr, gemAmt);

        emit BuyGem(usr, gemAmt, daiInWad - gemAmt);
    }

    /// @notice The least brand that must be burned for `redeem` to pay at least `gemAmt`.
    ///         Mirrors `MarketLens.brandForRedeem`, and is what `buyGem` pulls.
    /// @dev Inverts `in − ⌊in·bps/10000⌋` upwards, then steps back to the least amount that
    ///      still clears — the reserve floors its fee in the redeemer's favour, so the ceiling
    ///      can land a unit or two high.
    function daiForGem(uint256 gemAmt) public view returns (uint256 daiInWad) {
        uint256 bps = SharedReservePool(pocket).redemptionFeeBps();
        if (bps == 0) return gemAmt;

        uint256 keep = BPS - bps;
        daiInWad = (gemAmt * BPS + keep - 1) / keep;
        while (daiInWad > 1 && _payout(daiInWad - 1, bps) >= gemAmt) {
            daiInWad--;
        }
    }

    function _payout(uint256 amount, uint256 bps) private pure returns (uint256) {
        return amount - amount * bps / BPS;
    }
}
