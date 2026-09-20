// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Forked from Pons V2 (vendor/pons-v2/PonsV2GraduationExecutor.sol), MIT.

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

// Same note as in `MarketRouter`: this library sits outside the `v4-core/` remapping's root.
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IPermit2, IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../markets/AssetMarketFactory.sol";
import {LpRewardDistributor} from "../markets/LpRewardDistributor.sol";
import {LaunchFactory} from "./LaunchFactory.sol";
import {
    ILaunchFeeEscrow,
    ILaunchFeePolicy,
    ILaunchGraduation,
    ILaunchLocker
} from "./interfaces/ILaunchpad.sol";

/// @title LaunchGraduation
/// @notice Phase two of a launch: turn the curve's swept reserves into a live asset market.
///
///         `LaunchFactory` transfers exactly the swept quote and the swept token supply here
///         and calls `graduate`. In one transaction this contract opens the market through
///         `AssetMarketFactory.createLaunchMarket` — which mints the market unit, initialises
///         the v4 pool at the curve's terminal price, registers the hook skim and deploys the
///         vault and distributor — converts the brand float into the unit 1:1 at the reserve,
///         mints one full-range position, stakes it in the market's distributor with
///         `LaunchLocker` as the staker, and hands the locker the supply that could not enter
///         the pool. Nothing is held between transactions: what the mint does not consume is
///         disposed of before this returns.
///
///         **Split out of the factory for the reason Pons split it out.** The Permit2
///         approvals, the `PositionManager` action encoding, the liquidity math and the dust
///         accounting are a large share of bytecode the factory has no room for under
///         EIP-170, and graduation is the one step that has broken on mainnet before — keeping
///         it in its own module means the factory's retry loop and the executor's mechanics
///         can be reasoned about, and replaced, independently.
///
///         **All-or-nothing.** Every step reverts the whole call, and the factory catches
///         nothing: a failed phase two leaves the swept reserves in the factory and the launch
///         in `Swept`, retryable by anyone. That is the same property Pons's two-phase
///         graduation had, and it is why this contract never emits a "dust retained" event —
///         a token whose transfer fails does not graduate, it retries.
contract LaunchGraduation is ILaunchGraduation, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev v4-periphery action ids, copied from `lib/v4-periphery/src/libraries/Actions.sol`
    ///      for the reason `IPositionManagerV4` is hand-written: that file lives in a checkout
    ///      with its own copy of v4-core. They are part of `PositionManager`'s ABI.
    uint8 private constant ACTION_MINT_POSITION = 0x02;
    uint8 private constant ACTION_SETTLE_PAIR = 0x0d;

    /// @notice Ceiling on the quote the mint may leave behind, in basis points of the seed.
    /// @dev Ten is generous against the few base units a sane configuration produces, and
    ///      tight enough that a coarse one cannot route a percent of the raise to the
    ///      protocol as "rounding". See `_creditUnitDust`.
    uint256 public constant MAX_DUST_BPS = 10;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ─── Immutable wiring ────────────────────────────────────────────────

    /// @notice The `LaunchFactory` proxy, the only caller of `graduate`.
    address public immutable factory;

    /// @notice The market factory graduated launches are listed on.
    AssetMarketFactory public immutable marketFactory;

    /// @notice The v4 singleton, read off `marketFactory` so the two cannot disagree.
    IPoolManager public immutable poolManager;

    /// @notice Uniswap's canonical v4 `PositionManager`, which mints the locked position.
    IPositionManagerV4 public immutable positionManager;

    /// @notice Canonical Permit2, the only route by which `positionManager` moves ERC-20s.
    IPermit2 public immutable permit2;

    /// @notice Where the position is staked from and where the excess supply is held.
    ILaunchLocker public immutable locker;

    /// @notice Where the protocol's rounding dust is credited.
    ILaunchFeeEscrow public immutable feeEscrow;

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyFactory();
    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error PoolNotInitialized();
    error SeedPriceTooCoarse(uint256 dust, uint256 maxDust);
    error PositionManagerMismatch(address positionManagerPool, address poolManager);

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        address factory_,
        AssetMarketFactory marketFactory_,
        IPositionManagerV4 positionManager_,
        IPermit2 permit2_,
        ILaunchLocker locker_,
        ILaunchFeeEscrow feeEscrow_
    ) {
        if (
            factory_ == address(0) || address(marketFactory_) == address(0)
                || address(positionManager_) == address(0) || address(permit2_) == address(0)
                || address(locker_) == address(0) || address(feeEscrow_) == address(0)
        ) revert ZeroAddress();

        // The same check the market factory and the router make: a `PositionManager` bound to
        // another singleton would mint a position in a pool the distributor refuses.
        IPoolManager manager = marketFactory_.poolManager();
        address posmManager = positionManager_.poolManager();
        if (posmManager != address(manager)) {
            revert PositionManagerMismatch(posmManager, address(manager));
        }

        factory = factory_;
        marketFactory = marketFactory_;
        poolManager = manager;
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        feeEscrow = feeEscrow_;
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    /// @inheritdoc ILaunchGraduation
    /// @dev The seed amounts preserve the curve's terminal price. The curve prices against a
    ///      virtual quote reserve of `quote + phantom` over the whole remaining supply, so the
    ///      real quote can only buy the same price against `tokenAmount · quote / (quote +
    ///      phantom)` of it; the rest is the "phantom" side of the supply and goes to the
    ///      locker rather than into circulation.
    function graduate(Seed calldata seed)
        external
        onlyFactory
        nonReentrant
        returns (Result memory r)
    {
        if (seed.quoteAmount == 0 || seed.tokenAmount == 0) revert ZeroAmount();

        // 1. Split the supply between the pool and the locker.
        r.tokensSeeded =
            Math.mulDiv(seed.tokenAmount, seed.quoteAmount, seed.quoteAmount + seed.phantomQuote);
        if (r.tokensSeeded == 0) revert ZeroAmount();
        r.tokensLocked = seed.tokenAmount - r.tokensSeeded;
        _lockSupply(seed.token, r.tokensLocked);

        // 2–3. The market: unit, pool at the curve's terminal price, hook registration,
        //      vault, distributor.
        address distributor;
        (r.marketId, r.unit, distributor, r.poolId) = _createMarket(seed, r.tokensSeeded);

        // 4. The curve's brand float becomes the market's unit, 1:1 and free.
        SharedReservePool(seed.reserve)
            .swap(seed.pairToken, r.unit, seed.quoteAmount, address(this));

        // 5–6. Mint the position to this contract, then stake it with the locker as the
        //      beneficiary. The distributor pulls the NFT and holds it from here. Measured
        //      across the mint, not taken from what was asked for: what `SETTLE_PAIR` pulls is
        //      what the liquidity is worth at the live price, rounded, and the difference is
        //      the dust step 8 disposes of.
        uint256 unitBefore = IERC20(r.unit).balanceOf(address(this));
        uint256 tokenBefore = IERC20(seed.token).balanceOf(address(this));
        r.positionId = _mintFullRange(
            marketFactory.poolKeyOf(r.marketId), distributor, r.unit, seed.quoteAmount, tokenBefore
        );
        r.unitSeeded = unitBefore - IERC20(r.unit).balanceOf(address(this));
        r.tokensSeeded = tokenBefore - IERC20(seed.token).balanceOf(address(this));

        IERC721(address(positionManager)).approve(distributor, r.positionId);
        LpRewardDistributor(distributor).stake(r.positionId, address(locker));

        // 7. Record the split against the staked position.
        locker.recordPosition(
            seed.token,
            ILaunchLocker.LockedPosition({
                tokenId: r.positionId,
                distributor: distributor,
                unit: r.unit,
                creatorFeeRecipient: seed.creatorFeeRecipient,
                creatorShareBps: seed.creatorShareBps,
                exists: true
            })
        );

        // 8. Whatever the mint left behind. One side of a full-range add is always a little
        //    short of the ratio the price wanted: unit dust is the protocol's, token dust joins
        //    the locked supply so that supply which did not reach the pool never circulates.
        //    `tokensLocked` counts it, so `tokensSeeded + tokensLocked` is the whole swept
        //    supply; the unit side reconciles against the escrow's balance instead.
        _creditUnitDust(r.unit, seed.quoteAmount);
        uint256 tokenDust = IERC20(seed.token).balanceOf(address(this));
        r.tokensLocked += tokenDust;
        _lockSupply(seed.token, tokenDust);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev List the token on the market factory at the price `tokensSeeded` of it is worth
    ///      against the swept quote: one whole token in whole units, scaled by 1e18, which is
    ///      the shape `AssetListing.assetPriceE18` documents. Units share the reserve asset's
    ///      decimals, which is what the pair token has.
    function _createMarket(Seed calldata seed, uint256 tokensSeeded)
        private
        returns (uint256 marketId, address unit, address distributor, bytes32 poolId)
    {
        uint256 assetPriceE18 = Math.mulDiv(
            seed.quoteAmount * 1e18,
            10 ** IERC20Metadata(seed.token).decimals(),
            tokensSeeded * 10 ** IERC20Metadata(seed.pairToken).decimals()
        );
        if (assetPriceE18 == 0) revert ZeroAmount();

        (marketId, unit,, distributor, poolId) = marketFactory.createLaunchMarket(
            seed.token,
            seed.reserve,
            seed.creator,
            AssetMarketFactory.AssetListing({
                approved: false,
                fee: seed.poolFee,
                assetPriceE18: assetPriceE18,
                observationCardinality: 0,
                unitName: seed.unitName,
                unitSymbol: seed.unitSymbol
            })
        );
    }

    /// @dev Whatever unit the mint did not consume is the protocol's, credited through the
    ///      escrow like every other protocol fee so this contract holds nothing afterwards.
    ///
    ///      **And it has a ceiling, because "dust" is a claim about magnitude.** What is left
    ///      over is governed by the truncation in `assetPriceE18`, and that truncation is only
    ///      negligible while the price has decimals to spare: the shipped configuration prices
    ///      ~1e26 tokens against ~1e10 of a 6-decimal brand, so `assetPriceE18` lands around
    ///      1e13 and the residual is a few base units. A far coarser configuration would open
    ///      the pool measurably off the curve's terminal price and route a real fraction of the
    ///      raise here, which is not a rounding policy anyone agreed to. `MAX_DUST_BPS` of the
    ///      seeded quote is the line: above it the graduation reverts, the launch stays in
    ///      `Swept` and retryable, and the operator has to fix the configuration rather than
    ///      the protocol quietly keeping the difference. `LaunchFactory._validateLaunchConfig`
    ///      enforces the same bound at configuration time, so reaching this revert means a
    ///      brand's economics were retuned after the config was accepted.
    function _creditUnitDust(address unit, uint256 quoteAmount) private {
        uint256 dust = IERC20(unit).balanceOf(address(this));
        if (dust == 0) return;

        uint256 maxDust = (quoteAmount * MAX_DUST_BPS) / BPS_DENOMINATOR;
        if (dust > maxDust) revert SeedPriceTooCoarse(dust, maxDust);

        IERC20(unit).forceApprove(address(feeEscrow), dust);
        feeEscrow.creditToken(ILaunchFeePolicy(factory).protocolFeeRecipient(), unit, dust);
    }

    /// @dev Size a full-range position against the price the factory just initialised the
    ///      pool at and mint it to this contract through `PositionManager`, exactly as
    ///      `MarketRouter._mintPosition` does: `MINT_POSITION` leaves this contract owing both
    ///      currencies, `SETTLE_PAIR` pays them through Permit2. `amount0Max`/`amount1Max` are
    ///      set to exactly what this contract holds, so the mint can never pull more than the
    ///      factory sent.
    ///
    ///      **The preflight runs again here, and not redundantly.** The factory checked the
    ///      seed at a price derived from the two amounts; V4 is about to mint at the price the
    ///      market factory actually initialised the pool with, which came through a truncated
    ///      `assetPriceE18` and is therefore a slightly different number. Only the second one
    ///      decides whether `modifyLiquidities` reverts, so it is the one worth asserting
    ///      against V4's own rejections — a zero-liquidity seed, a price outside the tick
    ///      range, or liquidity past the cap this spacing allows per tick. Failing in the
    ///      guard leaves the launch retryable in `Swept` with a named error instead of
    ///      reverting several contracts deep inside the position manager.
    function _mintFullRange(
        PoolKey memory key,
        address distributor,
        address unit,
        uint256 unitAmount,
        uint256 tokenAmount
    ) private returns (uint256 tokenId) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = LpRewardDistributor(distributor).fullRange();
        (uint256 amount0, uint256 amount1) = Currency.unwrap(key.currency0) == unit
            ? (unitAmount, tokenAmount)
            : (tokenAmount, unitAmount);
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountTooLarge();

        LaunchFactory(factory).graduationGuard()
            .assertSeedableAtPrice(key.tickSpacing, sqrtPriceX96, amount0, amount1);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        _approveThroughPermit2(Currency.unwrap(key.currency0), amount0);
        _approveThroughPermit2(Currency.unwrap(key.currency1), amount1);

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
            address(this), // the NFT's first owner; `stake` moves it to the distributor
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        // Read immediately before the mint. `modifyLiquidities` returns nothing, so this is the
        // only way to learn the id it is about to create; `nonReentrant` plus the fact that this
        // is one external call means nothing can slip a mint in between the two.
        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev `PositionManager` never pulls an ERC-20 with `transferFrom` on its own account — it
    ///      asks Permit2 to do it — so this contract approves the token to Permit2 and tells
    ///      Permit2 the PositionManager may spend it. Unlike the router, which approves once
    ///      and without limit because it is never a wallet, this approves exactly the amount
    ///      of this graduation and lets it expire with the block: every unit and every token
    ///      the market factory ever sees passes through here once, and none of them should
    ///      leave a standing claim behind.
    function _approveThroughPermit2(address token, uint256 amount) private {
        if (amount > type(uint160).max) revert AmountTooLarge();
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp));
    }

    /// @dev Approve, then let the locker pull: its ledger is measured on arrival.
    function _lockSupply(address token, uint256 amount) private {
        if (amount == 0) return;
        IERC20(token).forceApprove(address(locker), amount);
        locker.lockTokenSupply(token, amount);
    }
}
