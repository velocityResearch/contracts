// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Minimal Morpho Blue interface (only what we need for supply/withdraw)
interface IMorphoBlue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesReceived);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesBurned);

    function position(bytes32 id, address user) external view returns (Position memory);

    function market(bytes32 id) external view returns (Market memory);

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @title MorphoBlueYieldSource
/// @notice Adapter that supplies USDG directly to a Morpho Blue lending market
///         on Robinhood Chain. This is permissionless — no vault whitelist needed.
///
///         Flow: SharedReservePool supplies USDG → MorphoBlueYieldSource → Morpho Blue market
///         Interest from borrowers accrues to supply shares, increasing their asset value.
///
///         The market is set at construction time. For a different market, deploy a new adapter.
///
///         SECURITY — per-consumer accounting. Morpho Blue keys the whole supply position by
///         THIS adapter's address (`onBehalf = address(this)`), so on its own the position is a
///         single shared pot. That is dangerous for two reasons if left unguarded: (1) anyone
///         could call `withdraw(asset, amount, attacker)` and drain it, since the adapter, not
///         the caller, is Morpho's authorized owner; and (2) if two vaults share one adapter
///         instance (as every vault the factory creates once did, via a single
///         `defaultYieldSource`), each would read the OTHER's principal as its own and the
///         first to redeem would drain the rest. Both are closed here by attributing Morpho
///         supply shares to the depositing caller in `sharesOf` and letting each caller only
///         ever see, move, or withdraw its OWN shares. An attacker with no deposits has zero
///         shares and withdraws zero; two consumers sharing an instance are fully isolated.
/// @dev **Upgradeable, and separately replaceable.** This adapter custodies the reserve's whole
///      Morpho position, so it is a UUPS proxy owned by the protocol timelock like the rest of
///      the fund-holding contracts. That is not the only route to changing it: the reserve's own
///      `setYieldSource` swaps the adapter out entirely, recalling everything to idle first, and
///      that remains the right tool for moving to a different lending venue. Upgrading is for
///      fixing this adapter; `setYieldSource` is for leaving it.
contract MorphoBlueYieldSource is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    IYieldSource
{
    /// @dev Morpho Blue's share-math virtual offsets — must match SharesMathLib exactly.
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    using SafeERC20 for IERC20;

    /// @notice The Morpho Blue singleton contract
    IMorphoBlue public morphoBlue;

    /// @notice The market ID (keccak256 hash of MarketParams)
    bytes32 public marketId;

    /// @notice Cached market params (read from Morpho Blue at construction)
    IMorphoBlue.MarketParams public marketParams;

    /// @notice The loan token (USDG on Robinhood Chain)
    address public loanToken;

    /// @notice Morpho supply shares attributed to each consumer (the vault/pool that deposited).
    ///         Keyed by `msg.sender`, so a caller can only ever move the shares it funded — no
    ///         caller can touch another's principal, and a caller that never deposited owns
    ///         nothing. This is what makes the adapter safe to share and safe against an
    ///         unauthorized `withdraw`.
    mapping(address consumer => uint256 shares) public sharesOf;

    /// @dev Room for later versions to add state.
    uint256[45] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(address _morphoBlue, bytes32 _marketId, address _owner)
        external
        initializer
    {
        __Ownable_init(_owner);
        __Ownable2Step_init();

        morphoBlue = IMorphoBlue(_morphoBlue);
        marketId = _marketId;

        // Cache the market params from Morpho Blue
        IMorphoBlue.MarketParams memory params =
            IMorphoBlue(_morphoBlue).idToMarketParams(_marketId);
        marketParams = params;
        loanToken = params.loanToken;
    }

    error OwnershipCannotBeRenounced();

    /// @notice Always reverts. This adapter is where the reserve's entire Morpho position is
    ///         custodied, and it is a UUPS proxy whose `_authorizeUpgrade` is `onlyOwner`.
    ///         Renouncing would freeze the implementation over live supply shares with no way
    ///         to fix a defect in the withdrawal path. `transferOwnership` is the handover
    ///         path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc IYieldSource
    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(morphoBlue), amount);
        // Supply assets to the market. Pass shares=0 to let Morpho compute shares from assets.
        // Credit the freshly-minted supply shares to THIS caller only.
        (, uint256 sharesReceived) = morphoBlue.supply(marketParams, amount, 0, address(this), "");
        sharesOf[msg.sender] += sharesReceived;
    }

    /// @inheritdoc IYieldSource
    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        // Always withdraw by shares to avoid Morpho Blue's mulDivUp rounding issues. Only ever
        // burn shares this caller owns — an unrelated caller owns zero and gets zero, which is
        // what defeats a drain via an arbitrary `to`.
        uint256 callerShares = sharesOf[msg.sender];
        if (callerShares == 0) return 0;

        IMorphoBlue.Market memory mkt = morphoBlue.market(marketId);

        uint256 sharesToBurn = callerShares; // default: withdraw everything this caller owns

        if (amount > 0 && mkt.totalSupplyAssets > 0) {
            // Compute the caller's current asset balance on the same basis as `balanceOf`.
            uint256 callerBalance =
                _toAssetsDown(callerShares, mkt.totalSupplyAssets, mkt.totalSupplyShares);

            if (amount < callerBalance) {
                // Partial withdrawal: compute proportional shares (floor division)
                sharesToBurn = amount * callerShares / callerBalance;
            }
            // else: full withdrawal, burn all of the caller's shares
        }

        if (sharesToBurn == 0) return 0;

        // Effects before interaction: debit the caller's shares first.
        sharesOf[msg.sender] = callerShares - sharesToBurn;

        (uint256 withdrawn,) = morphoBlue.withdraw(marketParams, 0, sharesToBurn, address(this), to);
        return withdrawn;
    }

    /// @inheritdoc IYieldSource
    /// @dev Mirrors Morpho Blue's own `SharesMathLib.toAssetsDown` EXACTLY, virtual offsets
    ///      included. A naive `supplyShares * totalSupplyAssets / totalSupplyShares` drifts
    ///      from it by a unit, and always in the dangerous direction: it reports a balance
    ///      Morpho will not actually pay out. The vault sizes redemptions off this number,
    ///      so one unit of over-reporting makes a full-position `redeem` revert when the
    ///      recall comes back short. Matching Morpho's arithmetic is what makes
    ///      `balanceOf()` and `withdraw(balanceOf())` agree.
    ///
    ///      Reports the CALLER's balance (`msg.sender`), not the whole adapter position, so a
    ///      vault reading `yieldSource.balanceOf(asset)` sees only its own deployed principal
    ///      even when the adapter instance is shared with other vaults.
    function balanceOf(address) external view returns (uint256) {
        uint256 callerShares = sharesOf[msg.sender];
        if (callerShares == 0) return 0;
        IMorphoBlue.Market memory mkt = morphoBlue.market(marketId);

        return _toAssetsDown(callerShares, mkt.totalSupplyAssets, mkt.totalSupplyShares);
    }

    /// @dev Morpho Blue SharesMathLib: VIRTUAL_SHARES = 1e6, VIRTUAL_ASSETS = 1. The
    ///      denominator can never be zero, so no empty-market special case is needed.
    function _toAssetsDown(uint256 shares, uint256 totalAssets_, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return shares * (totalAssets_ + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES);
    }

    /// @inheritdoc IYieldSource
    /// @dev `consumer`'s balance on the same basis as `balanceOf`, capped at what the market
    ///      has not lent out. Morpho's `withdraw` reverts, rather than paying short, when a
    ///      request exceeds `totalSupplyAssets - totalBorrowAssets`; this is the number that
    ///      predicts that revert.
    function withdrawable(address, address consumer) external view returns (uint256) {
        uint256 shares = sharesOf[consumer];
        if (shares == 0) return 0;
        IMorphoBlue.Market memory mkt = morphoBlue.market(marketId);

        uint256 owed = _toAssetsDown(shares, mkt.totalSupplyAssets, mkt.totalSupplyShares);
        uint256 unlent = mkt.totalSupplyAssets > mkt.totalBorrowAssets
            ? mkt.totalSupplyAssets - mkt.totalBorrowAssets
            : 0;
        return owed < unlent ? owed : unlent;
    }

    /// @inheritdoc IYieldSource
    function totalAssets(
        address /* asset */
    )
        external
        view
        returns (uint256)
    {
        IMorphoBlue.Market memory mkt = morphoBlue.market(marketId);
        return mkt.totalSupplyAssets;
    }
}
