// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "oz-upgradeable/utils/PausableUpgradeable.sol";

import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";
import {IStakedUSDai} from "../interfaces/IStakedUSDai.sol";
import {AcrossBridger} from "./AcrossBridger.sol";

/// @title SUSDaiHub
/// @notice The Arbitrum half of an sUSDai-backed reserve. Receives the USDC that Across
///         delivers for `SUSDaiYieldSource`'s bridge-outs, turns it into sUSDai on Curve, holds
///         the shares, and on the way back sells shares for USDC and bridges it home to the
///         adapter. A keeper drives it; the owner boxes the keeper in.
///
///         **Why Curve, in both directions.** sUSDai's own exit is an ERC-7540 queue: a request
///         burns the shares now and is serviced at some later epoch at a conservative NAV, with
///         no cancellation. The Curve sUSDai/USDC pool prices sUSDai at its deposit NAV through
///         an oracle rate, so a round trip through it cost ~2 bps at $10k–$100k when measured
///         (2026-09-13), same block, with a min-out. That is the "shortcut" the reserve's
///         redemption fee pays for. The native queue is the fallback for sizes Curve cannot
///         absorb; it is deliberately not wired here yet (see `IStakedUSDai`).
///
///         **What the keeper cannot do.** Every swap must clear a floor derived on chain from
///         sUSDai's own `depositSharePrice()` less `maxSwapSlippageBps`, so a stolen key cannot
///         sell the collateral into a manipulated pool or buy at a fantasy price — it can at
///         worst churn at Curve's fee. `bridgeHome` delivers only USDG, only to `homeReceiver`,
///         only on `homeChainId`, at a quote clearing `maxBridgeFeeBps`. Nothing here can send
///         a token to an arbitrary address.
///
///         **Valuation.** `conservativeValue()` marks shares at `redemptionSharePrice()` — what
///         a native redemption would be serviced at, ~44 bps under the Curve price at the time
///         of writing — plus USDC. It is what the keeper reports to the adapter as
///         `remoteValue`, in USDC units, which the reserve treats as USDG at parity. USDai,
///         USDC and USDG are all taken at par; that basis is a disclosed assumption, not a
///         measured one. Every price read here must clear `minSharePriceWad`/`maxSharePriceWad`
///         first, so an oracle that has been dusted or has run away stops the hub rather than
///         repricing the collateral.
contract SUSDaiHub is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    AcrossBridger
{
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;
    /// @dev sUSDai and USDai are 18 decimals; USDC is 6. Checked in `initialize`.
    uint256 private constant USDAI_TO_USDC = 1e12;

    // ─── Storage layout ──────────────────────────────────────────────────
    //
    // This hub is upgraded in place, so the order below IS part of its interface: later
    // versions append, never reorder or remove. `AcrossBridger` sits in front of it and owns
    // the first ten slots; `Ownable2StepUpgradeable` and `PausableUpgradeable` occupy none of
    // their own — both keep their fields at ERC-7201 namespaced slots. `sharesIndex`/`usdcIndex`
    // share a slot, and so do `keeper`/`maxSwapSlippageBps`/`maxBridgeFeeBps`; keep each group
    // adjacent or an upgrade repacks live state.

    // ─── Venue and route ─────────────────────────────────────────────────
    //
    // Written once by `initialize` and by nothing else. A stolen keeper key therefore cannot
    // repoint the pool, the collateral or the homeward route; only an upgrade can, and only the
    // owner can authorize one.

    IERC20 public usdc;
    IStakedUSDai public susdai;
    ICurveStableSwapNG public curve;
    int128 public sharesIndex;
    int128 public usdcIndex;
    /// @notice Robinhood Chain, where the reserve lives.
    uint256 public homeChainId;
    /// @notice USDG on `homeChainId`. The only token `bridgeHome` may deliver.
    address public homeUsdg;

    /// @notice The `SUSDaiYieldSource` on `homeChainId`. The only address `bridgeHome` may
    ///         deliver to. Settable because the adapter is deployed after the hub, since it
    ///         needs this address; changing it later is a governance act, not an operation.
    address public homeReceiver;
    address public keeper;

    // Limit defaults are applied by `initialize`, not by a declaration initializer: a value
    // assigned at the declaration is written by the implementation's constructor, which for a
    // proxy runs against the implementation's own storage and leaves the proxy on zero.
    uint16 public maxSwapSlippageBps;
    uint16 public maxBridgeFeeBps;
    /// @notice Largest single homeward bridge. Zero disables new deposits.
    uint256 public maxBridgeAmount;

    /// @notice The band every sUSDai price read must fall inside, in WAD.
    ///         RSV-001: `buyFloor`, `sellFloor` and `conservativeValue` are all derived from
    ///         sUSDai's own share prices, so whoever can write those prices owns this hub's
    ///         idea of what its collateral is worth — and on the testnet deployment the price
    ///         source is a fixture with no access control at all, making the entire remote
    ///         position sellable for dust through the HONEST keeper. A band fails the read
    ///         closed instead of clamping it: a genuinely collapsed NAV must stop the keeper
    ///         trading, not make it trade against a stale mark. It also covers a real sUSDai
    ///         oracle going wrong, which is the durable half of the same problem.
    /// @dev Packed into one slot and always read together.
    uint128 public minSharePriceWad;
    uint128 public maxSharePriceWad;

    /// @notice Swap and bridge notional the keeper may move per `swapWindow`, in USDC.
    ///         RSV-004: `maxSwapSlippageBps` bounds ONE leg and `maxBridgeAmount` bounds one
    ///         deposit; nothing bounded how many of either fit in a block. `buyShares` and
    ///         `sellShares` form a closed loop that needs no bridge and no outside capital, so
    ///         a stolen keeper key could round-trip the whole position repeatedly and keep the
    ///         slippage band each time. Zero is the fail-closed default, as for
    ///         `maxBridgeAmount` — including for a proxy upgraded from a version that predates
    ///         this slot, which reads zero and halts loudly until the owner sets a budget.
    uint256 public swapBudgetPerWindow;
    /// @dev Packed with the two counters below; keep the three adjacent.
    uint64 public swapWindow;
    uint64 private _swapWindowStart;
    uint128 private _spentInWindow;

    /// @dev Room for later versions to add state without disturbing anything above. Shrunk
    ///      from 40 by the three slots appended above, so the total this contract occupies is
    ///      unchanged and nothing underneath a live proxy moved.
    uint256[37] private __gap;

    uint16 public constant MAX_SWAP_SLIPPAGE_BPS = 500;
    uint16 public constant MAX_BRIDGE_FEE_BPS = 100;

    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event HomeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event LimitsUpdated(uint16 maxSwapSlippageBps, uint16 maxBridgeFeeBps);
    event MaxBridgeAmountUpdated(uint256 oldMaximum, uint256 newMaximum);
    event SharePriceBandUpdated(uint128 minWad, uint128 maxWad);
    event SwapBudgetUpdated(uint256 budget, uint64 window);
    event SharesBought(uint256 usdcIn, uint256 sharesOut);
    event SharesSold(uint256 sharesIn, uint256 usdcOut);
    event BridgedHome(uint32 indexed depositId, uint256 usdcIn, uint256 outputAmount);

    error NotKeeper();
    error MinOutBelowFloor(uint256 minOut, uint256 floor);
    error LimitOutOfRange();
    error BridgeAmountAboveCap(uint256 amount, uint256 maximum);
    error WrongCurveCoins();
    error UnexpectedDecimals();
    error SharePriceOutOfBand(uint256 price, uint256 minWad, uint256 maxWad);
    error SwapBudgetExhausted(uint256 notional, uint256 remaining);
    error OwnershipCannotBeRenounced();

    constructor() {
        _disableInitializers();
    }

    /// @param _owner Owns the keeper rotation, the limits, the pause, and upgrades of this proxy.
    function initialize(
        address _usdc,
        address _susdai,
        address _curve,
        address _spokePool,
        uint256 _homeChainId,
        address _homeUsdg,
        address _owner,
        address _keeper
    ) external initializer {
        if (
            _usdc == address(0) || _susdai == address(0) || _curve == address(0)
                || _homeUsdg == address(0) || _keeper == address(0)
        ) revert ZeroAddress();

        __AcrossBridger_init(_spokePool);
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();

        usdc = IERC20(_usdc);
        susdai = IStakedUSDai(_susdai);
        curve = ICurveStableSwapNG(_curve);
        homeChainId = _homeChainId;
        homeUsdg = _homeUsdg;
        keeper = _keeper;
        // Measured Curve round-trip cost was ~2 bps at $10k-$100k, so 50 bps was 25x the
        // observed need and every basis point of it is extractable by a keeper that pre-trades
        // the pool. 15 bps leaves room for a genuinely thin book without funding the sandwich.
        maxSwapSlippageBps = 15;
        maxBridgeFeeBps = 20;
        // sUSDai's NAV starts near par and only climbs as USDai yield accrues; it was 1.112
        // (deposit) / 1.107 (redemption) when measured, and the testnet fixture reports
        // 1.1 / 1.095. A floor of 0.9 admits a real 10% credit drawdown and refuses the dust
        // an attacker needs; a ceiling of 10 admits decades of accrual and refuses a decimal
        // slip or a garbage read. Both are owner-set, because only the owner knows the
        // collateral's real history.
        minSharePriceWad = 0.9e18;
        maxSharePriceWad = 10e18;
        // Half the reserve's configured liability cap per day: far above the keeper's real duty
        // cycle of rebalancing a 12.5% buffer, far below "the whole position in one block".
        swapBudgetPerWindow = 50_000e6;
        swapWindow = 1 days;

        // Discover the coin order rather than assume it: a wrong index does not revert, it
        // trades the wrong way.
        if (curve.N_COINS() != 2) revert WrongCurveCoins();
        address coin0 = curve.coins(0);
        address coin1 = curve.coins(1);
        if (coin0 == _susdai && coin1 == _usdc) {
            sharesIndex = 0;
            usdcIndex = 1;
        } else if (coin0 == _usdc && coin1 == _susdai) {
            sharesIndex = 1;
            usdcIndex = 0;
        } else {
            revert WrongCurveCoins();
        }
        if (IERC20Metadata(_usdc).decimals() != 6 || IERC20Metadata(_susdai).decimals() != 18) {
            revert UnexpectedDecimals();
        }
        emit KeeperUpdated(address(0), _keeper);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Admin ───────────────────────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(keeper, _keeper);
        keeper = _keeper;
    }

    function setHomeReceiver(address _homeReceiver) external onlyOwner {
        if (_homeReceiver == address(0)) revert ZeroAddress();
        emit HomeReceiverUpdated(homeReceiver, _homeReceiver);
        homeReceiver = _homeReceiver;
    }

    /// @param _maxSwapSlippageBps How far below sUSDai's deposit NAV a swap may execute. <= 5%.
    /// @param _maxBridgeFeeBps    Floor on an Across quote's output, as a fee. <= 1%.
    function setLimits(uint16 _maxSwapSlippageBps, uint16 _maxBridgeFeeBps) external onlyOwner {
        if (_maxSwapSlippageBps > MAX_SWAP_SLIPPAGE_BPS || _maxBridgeFeeBps > MAX_BRIDGE_FEE_BPS) {
            revert LimitOutOfRange();
        }
        maxSwapSlippageBps = _maxSwapSlippageBps;
        maxBridgeFeeBps = _maxBridgeFeeBps;
        emit LimitsUpdated(_maxSwapSlippageBps, _maxBridgeFeeBps);
    }

    /// @notice Set the absolute single-deposit ceiling. Zero is the fail-closed default.
    function setMaxBridgeAmount(uint256 newMaximum) external onlyOwner {
        emit MaxBridgeAmountUpdated(maxBridgeAmount, newMaximum);
        maxBridgeAmount = newMaximum;
    }

    /// @notice Set the band every sUSDai price read must fall inside. See `minSharePriceWad`.
    function setSharePriceBand(uint128 minWad, uint128 maxWad) external onlyOwner {
        if (minWad == 0 || minWad > maxWad) revert LimitOutOfRange();
        minSharePriceWad = minWad;
        maxSharePriceWad = maxWad;
        emit SharePriceBandUpdated(minWad, maxWad);
    }

    /// @notice Set the rolling swap/bridge budget and the window it resets over.
    function setSwapBudget(uint256 budget, uint64 window) external onlyOwner {
        // The spent counter is packed into 16 bytes, so a budget it cannot hold is rejected
        // rather than silently truncated on the first swap.
        if (budget > type(uint128).max) revert LimitOutOfRange();
        swapBudgetPerWindow = budget;
        swapWindow = window;
        emit SwapBudgetUpdated(budget, window);
    }

    /// @notice Always reverts. UUPS-003: behind a UUPS proxy the owner is the sole upgrade
    ///         authority, so renouncing it does not decentralize this hub — it freezes the
    ///         implementation permanently and takes the keeper rotation, the limits, the price
    ///         band and the pause with it, leaving a hot key as the only actor able to trade
    ///         the collateral. The two-step `transferOwnership` is the handover path.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Halt swaps and bridging. Reporting continues: the adapter's `sync` reads this
    ///         contract's views, and a pause must not blind the reserve.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ─── Keeper ──────────────────────────────────────────────────────────

    /// @notice Swap `usdcIn` of the USDC held here into sUSDai on Curve.
    /// @param minSharesOut The keeper's min-out, normally Curve's `get_dy` less a tolerance.
    ///                     Must itself clear the NAV floor: see `buyFloor`.
    function buyShares(uint256 usdcIn, uint256 minSharesOut)
        external
        onlyKeeper
        whenNotPaused
        returns (uint256 sharesOut)
    {
        if (usdcIn == 0) revert ZeroAmount();
        uint256 floor = buyFloor(usdcIn);
        if (minSharesOut < floor) revert MinOutBelowFloor(minSharesOut, floor);
        _spendSwapBudget(usdcIn);

        usdc.forceApprove(address(curve), usdcIn);
        sharesOut = curve.exchange(usdcIndex, sharesIndex, usdcIn, minSharesOut);
        emit SharesBought(usdcIn, sharesOut);
    }

    /// @notice Swap `sharesIn` of the sUSDai held here into USDC on Curve.
    /// @param minUsdcOut Must clear the NAV floor: see `sellFloor`.
    function sellShares(uint256 sharesIn, uint256 minUsdcOut)
        external
        onlyKeeper
        whenNotPaused
        returns (uint256 usdcOut)
    {
        if (sharesIn == 0) revert ZeroAmount();
        uint256 floor = sellFloor(sharesIn);
        if (minUsdcOut < floor) revert MinOutBelowFloor(minUsdcOut, floor);
        // Charged at the conservative mark, which is the value actually leaving the position.
        _spendSwapBudget(sharesToUsdc(sharesIn, _redemptionPrice()));

        IERC20(address(susdai)).forceApprove(address(curve), sharesIn);
        usdcOut = curve.exchange(sharesIndex, usdcIndex, sharesIn, minUsdcOut);
        emit SharesSold(sharesIn, usdcOut);
    }

    /// @notice Hand `usdcIn` of the USDC held here to Across for delivery to the adapter on
    ///         Robinhood Chain as USDG.
    function bridgeHome(uint256 usdcIn, AcrossQuote calldata q)
        external
        onlyKeeper
        whenNotPaused
        returns (uint32 depositId)
    {
        if (maxBridgeAmount == 0 || usdcIn > maxBridgeAmount) {
            revert BridgeAmountAboveCap(usdcIn, maxBridgeAmount);
        }
        _spendSwapBudget(usdcIn);
        depositId = _bridge(usdc, usdcIn, homeUsdg, homeChainId, homeReceiver, maxBridgeFeeBps, q);
        emit BridgedHome(depositId, usdcIn, q.outputAmount);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function sharesHeld() public view returns (uint256) {
        return susdai.balanceOf(address(this));
    }

    function usdcHeld() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Shares at the conservative (redemption) NAV plus USDC, in USDC units. The
    ///         number the keeper reports to the adapter as `remoteValue`. Reverts rather than
    ///         returning dust if the NAV is out of band, so a collapsed oracle cannot make an
    ///         honest keeper write the position off — which `SUSDaiYieldSource.sync` cannot
    ///         undo, since its growth allowance is proportional to what it was told last.
    function conservativeValue() external view returns (uint256) {
        return sharesToUsdc(sharesHeld(), _redemptionPrice()) + usdcHeld();
    }

    /// @notice Shares at the optimistic (deposit) NAV plus USDC, in USDC units. Monitoring only.
    function optimisticValue() external view returns (uint256) {
        return sharesToUsdc(sharesHeld(), _sharePrice()) + usdcHeld();
    }

    /// @notice Swap and bridge notional still available in the current budget window.
    function swapBudgetRemaining() external view returns (uint256) {
        uint256 budget = swapBudgetPerWindow;
        if (block.timestamp - _swapWindowStart >= swapWindow) return budget;
        return budget - Math.min(uint256(_spentInWindow), budget);
    }

    /// @notice Fewest shares `buyShares(usdcIn, ...)` will accept as a min-out: `usdcIn` at the
    ///         deposit NAV, less `maxSwapSlippageBps`.
    function buyFloor(uint256 usdcIn) public view returns (uint256) {
        uint256 atNav = usdcToShares(usdcIn, _sharePrice());
        return atNav - atNav * maxSwapSlippageBps / BPS;
    }

    /// @notice Least USDC `sellShares(sharesIn, ...)` will accept as a min-out.
    function sellFloor(uint256 sharesIn) public view returns (uint256) {
        uint256 atNav = sharesToUsdc(sharesIn, _sharePrice());
        return atNav - atNav * maxSwapSlippageBps / BPS;
    }

    function quoteBuy(uint256 usdcIn) external view returns (uint256 sharesOut) {
        return curve.get_dy(usdcIndex, sharesIndex, usdcIn);
    }

    function quoteSell(uint256 sharesIn) external view returns (uint256 usdcOut) {
        return curve.get_dy(sharesIndex, usdcIndex, sharesIn);
    }

    /// @dev `shares` (18 dec) at `sharePriceWad` USDai per share, as USDC (6 dec), rounded down.
    function sharesToUsdc(uint256 shares, uint256 sharePriceWad) public pure returns (uint256) {
        return Math.mulDiv(shares, sharePriceWad, WAD * USDAI_TO_USDC);
    }

    /// @dev `usdcAmount` (6 dec) at `sharePriceWad` USDai per share, as shares (18 dec).
    function usdcToShares(uint256 usdcAmount, uint256 sharePriceWad) public pure returns (uint256) {
        return Math.mulDiv(usdcAmount * USDAI_TO_USDC, WAD, sharePriceWad);
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev sUSDai's deposit NAV, refused if it is outside the band. See `minSharePriceWad`.
    function _sharePrice() internal view returns (uint256 price) {
        price = susdai.depositSharePrice();
        _requireInBand(price);
    }

    /// @dev sUSDai's redemption NAV, refused if it is outside the band.
    function _redemptionPrice() internal view returns (uint256 price) {
        price = susdai.redemptionSharePrice();
        _requireInBand(price);
    }

    function _requireInBand(uint256 price) private view {
        uint256 minWad = minSharePriceWad;
        uint256 maxWad = maxSharePriceWad;
        if (price < minWad || price > maxWad) revert SharePriceOutOfBand(price, minWad, maxWad);
    }

    /// @dev Charge `notional` against the rolling budget. See `swapBudgetPerWindow`.
    function _spendSwapBudget(uint256 notional) internal {
        uint256 spent = _spentInWindow;
        if (block.timestamp - _swapWindowStart >= swapWindow) {
            _swapWindowStart = uint64(block.timestamp);
            spent = 0;
        }
        uint256 budget = swapBudgetPerWindow;
        if (spent + notional > budget) {
            revert SwapBudgetExhausted(notional, budget - Math.min(spent, budget));
        }
        _spentInWindow = uint128(spent + notional);
    }
}
