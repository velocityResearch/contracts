// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

// Not reachable through the `v4-core/` remapping, which points at `lib/v4-core/src/`. Same
// checkout, one directory up — the same convention `MarketRouter` documents.
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev The two getters that prove the `PositionManager` at `V4_POSITION_MANAGER` is bound to
///      the `PoolManager` at `POOL_MANAGER`. Declared locally because nothing in this repo
///      talks to the periphery — the stack under test speaks to the singleton directly.
interface IV4PositionManagerLike {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @title AssetMarketV4ForkTest
/// @notice The asset-market stack run against **Uniswap's own deployed v4 singleton** on
///         Robinhood Chain, rather than against a `PoolManager` this test deployed itself.
///
///         Every other suite in this repo — `ProtocolFeeHook.t.sol`, `BrandFeeVault.t.sol`,
///         even the fork suites — does `new PoolManager(...)` from `lib/v4-core`. That proves
///         our contracts agree with *our copy* of v4 and nothing more. v4 is in fact deployed
///         on chain 4663 at a non-canonical address (see `MainnetAddresses`), and this suite
///         exists to answer the one question those suites structurally cannot: **does our
///         v4-core (1.0.2) agree with the bytecode that is actually there?**
///
///         Everything a version skew could break is exercised against the live singleton:
///
///         - `PoolKey` encoding and `PoolId` derivation (`initialize` then `getSlot0` round
///           trip — if the key hashed differently, the read comes back zero);
///         - `extsload` slot layout (`StateLibrary.getSlot0` reads raw storage; a moved slot
///           returns garbage rather than reverting, so the price is compared to the exact
///           value the factory asked for);
///         - the hook address-flag convention (`Hooks.validateHookPermissions` in our
///           constructor versus the manager's own check inside `initialize`);
///         - the hook callback ABI (`beforeSwap`/`afterSwap` selectors, `BeforeSwapDelta`
///           packing and the returned-delta accounting);
///         - the `unlock`/`sync`/`settle`/`take` flow and ERC-6909 `mint`/`burn`, which is how
///           the hook's skim moves the protocol's money out of the singleton.
///
///         **Real:** the PoolManager, the PositionManager, USDG, Morpho Blue, SPCX and the live
///         V3 SPCX/USDG pool (read for a starting price, and pranked as a source of SPCX).
///         **Ours, deployed into the fork:** the reserve stack, the hook, the factory, and
///         v4-core's own `PoolSwapTest`/`PoolModifyLiquidityTest` routers. Nothing is mocked.
///
///         `MarketRouter` is deliberately absent. Its `seedLiquidity` is being reworked, and
///         the venue is what is under test here — so liquidity and swaps go through v4-core's
///         reference routers, which is also a stronger check: they are Uniswap's own callers,
///         not ours.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state older than roughly a few thousand blocks comes back as
///         `-32000: metadata is not found` and every test fails in `setUp` with a confusing
///         account-fetch error rather than anything about our contracts. A block from an hour
///         ago is already too old. Passing 58,890,000 on 2026-09-10 failed exactly that way;
///         58,899,100 — about 80 blocks behind the head at the time — worked. So take the
///         block from the chain rather than from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-path "test/markets/AssetMarketV4Fork.t.sol" --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract AssetMarketV4ForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The live venue ──────────────────────────────────────────────────

    /// @dev The deployed singleton. Held as `IPoolManager` rather than as `PoolManager`
    ///      precisely so nothing here can accidentally read our own bytecode: every call in
    ///      this file goes through the interface and lands on Uniswap's deployment.
    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;
    address constant SPCX = MainnetAddresses.REFERENCE_EQUITY;

    bytes32 constant USDE_MARKET_ID = MainnetAddresses.USDE_MARKET_ID;

    /// @notice The live SPCX/USDG 0.05% V3 pool. Read for the starting price and pranked as a
    ///         source of SPCX — never traded against.
    address constant LIVE_SPCX_USDG_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;

    // ─── Market configuration ────────────────────────────────────────────

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    /// @dev Non-zero on purpose, unlike the shipped default: a zero skim would make the fee
    ///      leg of this test vacuous, and the fee leg is the part that exercises the hook's
    ///      returned-delta ABI against the real manager. 0.10%.
    uint24 constant PROTOCOL_FEE_PIPS = 1_000;

    uint16 constant PROTOCOL_BPS = 0;

    /// @dev The window the oracle test consults over. Long enough that a single block's worth
    ///      of trading cannot dominate the mean.
    uint32 constant TWAP_WINDOW = 30 minutes;

    uint256 constant SEED_BRAND = 50_000e6;
    uint256 constant SEED_SPCX = 300e18;

    // ─── Our stack, deployed into the fork ───────────────────────────────

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    address owner = address(0x0AD01);
    address operator = address(0x0FE);
    address protocolTreasury = address(0xF33);
    address trader = address(0x7AAD);

    uint256 marketId;
    address brandToken;
    PoolKey poolKey;
    PoolId poolId;
    BrandFeeVault feeVault;
    LpRewardDistributor distributor;

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // Same pattern as `GraduationForkTest`; the early return is what keeps the rest of
        // this function from reverting against an empty chain, since `vm.skip` only marks the
        // result and does not abort the body.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reservePool = _deployReservePool(USDG, address(yieldSource), owner);

        feeHook = _deployHook();

        factory = _deployFactory(
            reservePool,
            MANAGER,
            feeHook,
            IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER),
            protocolTreasury,
            SPCX,
            PROTOCOL_BPS,
            owner
        );

        vm.startPrank(owner);
        feeHook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        // Uniswap's own reference callers, pointed at Uniswap's own deployed singleton.
        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);

        _fundUsdg(address(this), 1_000_000e6);
        _fundSpcx(address(this), 1_000e18);
        _fundUsdg(trader, 200_000e6);
        _fundSpcx(trader, 200e18);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address. `deployCodeTo`
    ///      writes the contract where we want it and still runs the constructor, so
    ///      `Hooks.validateHookPermissions` still executes — the standard way to skip salt
    ///      mining in a test without skipping the check mining exists to satisfy.
    ///
    ///      The `0x00CC` prefix keeps this suite's hook at an address no other suite uses, and
    ///      well clear of anything already deployed on the live chain; `_assertHookAddressIs-
    ///      Vacant` checks the second half of that rather than assuming it.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x00CC << 144)
        );
        require(flags.code.length == 0, "hook address is occupied on the live chain");
        return _deployHookAt(flags, MANAGER, owner);
    }

    /// @dev Morpho Blue custodies tens of millions of USDG on this chain.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    /// @dev SPCX is an issuer-controlled beacon proxy, so `deal` cannot be trusted to find the
    ///      balance slot. The live V3 pool is a real holder, so we move real tokens instead.
    function _fundSpcx(address to, uint256 amount) internal {
        vm.prank(LIVE_SPCX_USDG_POOL);
        IERC20(SPCX).transfer(to, amount);
    }

    /// @dev The live mid price of one whole SPCX in whole USDG, read off the real V3 pool so
    ///      this suite does not rot as the price moves.
    function _livePriceE18() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(LIVE_SPCX_USDG_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // Full-width: the intermediate genuinely does not fit in 256 bits.
        return Math.mulDiv(ratioX192, 1e18 * 1e12, 1 << 192);
    }

    function _createMarket() internal returns (uint160 askedFor) {
        uint256 priceE18 = _livePriceE18();
        _approveAsset(factory, SPCX, FEE, priceE18, 64, "Starbase Dollar", "starUSD");

        address vaultAddr;
        address distributorAddr;
        bytes32 rawPoolId;
        // Permissionless; the prank only decides who is recorded as the market's `creator`.
        vm.prank(operator);
        (marketId, brandToken, vaultAddr, distributorAddr, rawPoolId) =
            factory.createMarket(SPCX, address(0));

        poolKey = factory.poolKeyOf(marketId);
        poolId = PoolId.wrap(rawPoolId);
        feeVault = BrandFeeVault(vaultAddr);
        distributor = LpRewardDistributor(distributorAddr);

        // Recomputed AFTER creation because the brand token's address — and therefore the
        // currency ordering, and therefore the sqrt price — is only known once it exists.
        askedFor = factory.quoteSqrtPriceX96(brandToken, SPCX, priceE18);
    }

    function _brandIsCurrency0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == brandToken;
    }

    function _mintBrand(address to, uint256 amount) internal {
        IERC20(USDG).approve(address(reservePool), amount);
        reservePool.mint(brandToken, amount, to);
    }

    /// @dev Full-range liquidity, added through v4-core's own reference LP router so the path
    ///      into the real singleton is Uniswap's rather than ours.
    function _addLiquidity() internal returns (uint128 liquidity) {
        _mintBrand(address(this), SEED_BRAND);

        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        (uint160 current,,,) = MANAGER.getSlot0(poolId);

        (uint256 amount0, uint256 amount1) =
            _brandIsCurrency0() ? (SEED_BRAND, SEED_SPCX) : (SEED_SPCX, SEED_BRAND);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            current,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0,
            amount1
        );

        IERC20(brandToken).approve(address(lpRouter), type(uint256).max);
        IERC20(SPCX).approve(address(lpRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev An exact-input swap by `trader`, through v4-core's reference swap router.
    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.startPrank(trader);
        IERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev The output the same swap produces with the hook's cut switched off, measured by
    ///      running it on a state snapshot and rolling the chain back.
    ///
    ///      A fee DECREASE applies immediately, so what is quoted is the identical pool at
    ///      identical depth paying the identical LP fee, with only the skim missing. That is
    ///      this suite's stand-in for the hookless twin pool the unit suite quotes against,
    ///      and it is why the expectations below are an independently measured number rather
    ///      than a restatement of the hook's own arithmetic.
    function _grossOutWithoutTheSkim(bool zeroForOne, uint256 amountIn, address tokenOut)
        internal
        returns (uint256 gross)
    {
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        feeHook.setPoolFeePips(poolId, 0);
        uint256 before = IERC20(tokenOut).balanceOf(trader);
        _swap(zeroForOne, amountIn);
        gross = IERC20(tokenOut).balanceOf(trader) - before;
        vm.revertToState(snap);
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = MANAGER.getSlot0(poolId);
    }

    /// @dev Build a history the 30-minute TWAP can actually reach across. An observation is
    ///      only written by a swap, so time alone is not enough.
    function _buildOracleHistory() internal {
        uint256 brandIn = 500e6;
        _mintBrand(trader, brandIn * 4);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 15 minutes);
            vm.roll(block.number + 1);
            _swap(_brandIsCurrency0(), brandIn);
        }
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vm.roll(block.number + 1);
    }

    // ─── 1. The venue is what we think it is ─────────────────────────────

    /// @notice Before anything else: the address in `MainnetAddresses` really is a v4
    ///         `PoolManager`, and the `PositionManager` alongside it agrees.
    ///
    ///         Measured at fork block 58,890,000: the PoolManager's runtime code is
    ///         **24,009 bytes** — a hair under EIP-170's 24,576, which is what a real v4
    ///         singleton looks like. `MainnetAddresses` records the same figure; this asserts
    ///         it rather than trusting the comment.
    function test_fork_theDeployedPoolManagerIsTheOneTheAddressesFileNames() public view {
        uint256 codeSize = address(MANAGER).code.length;
        console.log("PoolManager runtime code size (bytes):", codeSize);

        assertGt(codeSize, 0, "the PoolManager address has code");
        assertEq(codeSize, 24_009, "and it is the 24,009-byte singleton recorded on 2026-09-10");
        assertLt(codeSize, 24_576, "which is inside EIP-170, as a deployed contract must be");

        IV4PositionManagerLike posm = IV4PositionManagerLike(MainnetAddresses.V4_POSITION_MANAGER);
        assertGt(address(posm).code.length, 0, "the PositionManager address has code");
        assertEq(
            posm.poolManager(),
            address(MANAGER),
            "the real PositionManager is bound to this exact singleton"
        );
        assertEq(posm.permit2(), MainnetAddresses.PERMIT2, "and pulls tokens through Permit2");
    }

    // ─── 2. Our hook validates against the real manager ──────────────────

    /// @notice The hook's permission bits, its own address, and what the *deployed* manager
    ///         expects of a hook all have to agree. Our constructor runs
    ///         `Hooks.validateHookPermissions` from `lib/v4-core` — that it did not revert is
    ///         asserted here, and the manager's own opinion is proved by
    ///         `test_fork_createMarket_initialisesAPoolInsideTheRealSingleton`, which cannot
    ///         initialise a pool whose hook the manager rejects.
    function test_fork_theHookValidatesAtItsFlaggedAddressAgainstTheRealManager() public view {
        assertGt(address(feeHook).code.length, 0, "the hook deployed at its flagged address");
        assertEq(address(feeHook.poolManager()), address(MANAGER), "bound to the real singleton");

        // Our library's own view of the address, re-checked outside the constructor.
        assertTrue(
            Hooks.isValidHookAddress(IHooks(address(feeHook)), FEE),
            "our v4-core accepts this address as a hook for a static-fee pool"
        );

        // And the four bits it claims are exactly the four it implements.
        Hooks.Permissions memory perms = feeHook.getHookPermissions();
        assertTrue(perms.beforeSwap, "beforeSwap");
        assertTrue(perms.afterSwap, "afterSwap");
        assertTrue(perms.beforeSwapReturnDelta, "beforeSwap returns a delta");
        assertTrue(perms.afterSwapReturnDelta, "afterSwap returns a delta");
        assertFalse(perms.beforeInitialize, "and nothing else");
        assertFalse(perms.afterInitialize, "and nothing else");
        assertFalse(perms.beforeAddLiquidity, "and nothing else");
        assertFalse(perms.afterAddLiquidity, "and nothing else");
        assertFalse(perms.beforeDonate, "and nothing else");
        assertFalse(perms.afterDonate, "and nothing else");
    }

    // ─── 3. A full market launch on the real singleton ───────────────────

    /// @notice The interface-mismatch test, and the reason this file exists.
    ///
    ///         `createMarket` builds a `PoolKey`, hands it to the deployed manager's
    ///         `initialize`, and the assertions read the result back out through
    ///         `StateLibrary.getSlot0`, which is a raw `extsload` of the manager's storage.
    ///         Three independent things have to line up for that to return the asked-for
    ///         price: our `PoolKey` must ABI-encode and hash to the same `PoolId` the deployed
    ///         manager derives, `Pool.State.slot0` must sit at the offset our `StateLibrary`
    ///         expects, and `Slot0` must pack sqrtPriceX96/tick/fees the same way. A skew in
    ///         any of them yields zero or garbage here rather than a revert, which is exactly
    ///         the failure mode a local `new PoolManager()` can never surface.
    function test_fork_createMarket_initialisesAPoolInsideTheRealSingleton() public {
        uint160 askedFor = _createMarket();

        (uint160 sqrtPriceX96, int24 tick,,) = MANAGER.getSlot0(poolId);
        console.log("pool sqrtPriceX96 read back off the deployed manager:", sqrtPriceX96);
        console.logInt(tick);

        assertGt(sqrtPriceX96, 0, "the deployed manager holds an initialised pool for this id");
        assertEq(sqrtPriceX96, askedFor, "at exactly the price the factory asked for");
        assertEq(
            tick,
            TickMath.getTickAtSqrtPrice(askedFor),
            "and the tick the manager derived matches our TickMath"
        );

        // The key rebuilds the id the factory recorded — our PoolId derivation and the
        // manager's agree, or the read above would have come back empty.
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(poolId), "key rebuilds the id");
        assertEq(address(poolKey.hooks), address(feeHook), "and names our hook");
        assertEq(poolKey.tickSpacing, TICK_SPACING);
        assertEq(poolKey.fee, FEE);

        // The market itself is wired: verified asset, oracle opened, skim pointed at the vault.
        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertTrue(m.verified, "a market on the real SPCX is verified");
        assertEq(m.asset, SPCX);
        assertEq(IERC20Metadata(brandToken).decimals(), 6, "the brand mirrors USDG");

        (,, uint16 cardinalityNext) = feeHook.observationState(poolId);
        assertGe(cardinalityNext, 64, "TWAP buffer grown at creation");
        // The swap skim is the protocol's trading fee, so the hook pays the treasury. The
        // market's own income is the float yield, which is what its vault divides.
        assertEq(feeHook.feeRecipientOf(poolId), protocolTreasury, "skim points at the treasury");
        assertEq(feeHook.feePipsFor(poolId), PROTOCOL_FEE_PIPS, "at the configured rate");
    }

    // ─── 4. A real swap through the real manager, and the skim ───────────

    /// @notice The end-to-end proof that fee capture works on the live venue.
    ///
    ///         The skim is not a transfer — it is an `int128` returned from `afterSwap`,
    ///         folded by the manager into the `BalanceDelta` the swap settles against, plus
    ///         an ERC-6909 `mint` for the same amount; `collect` unwinds that with
    ///         `burn`/`take` inside an `unlock`. Every one of those is a call into deployed
    ///         bytecode whose ABI our copy of v4-core only assumes. If any of it disagreed,
    ///         the swap reverts inside the manager rather than merely accruing the wrong
    ///         number.
    ///
    ///         The cut lands on the leg the caller did not name, which for an exact-input buy
    ///         is the OUTPUT: the protocol is paid in SPCX here, not in the brandUSD the
    ///         trader handed over.
    function test_fork_aRealSwapPaysTheSkimAndCollectDeliversItToTheVault() public {
        _createMarket();
        uint128 liquidity = _addLiquidity();
        assertGt(liquidity, 0, "liquidity added to the real singleton");
        assertGt(MANAGER.getLiquidity(poolId), 0, "and the manager reports it");

        bool brandFirst = _brandIsCurrency0();
        Currency brandCurrency = brandFirst ? poolKey.currency0 : poolKey.currency1;
        Currency assetCurrency = brandFirst ? poolKey.currency1 : poolKey.currency0;

        uint256 amountIn = 10_000e6;
        _mintBrand(trader, amountIn);

        // What the pool pays out when the hook takes nothing. The skim is pips of THAT, so
        // the expectation depends on the curve and cannot be written as a constant.
        uint256 gross = _grossOutWithoutTheSkim(brandFirst, amountIn, SPCX);
        uint256 expected = gross * PROTOCOL_FEE_PIPS / 1_000_000;
        assertGt(expected, 0, "a 10,000 brandUSD buy is large enough to owe something");

        uint256 spcxBefore = IERC20(SPCX).balanceOf(trader);
        _swap(brandFirst, amountIn);
        uint256 received = IERC20(SPCX).balanceOf(trader) - spcxBefore;

        assertGt(received, 0, "the trader really received SPCX");
        assertEq(received, gross - expected, "short by the skim, and by nothing else");

        uint256 pending = feeHook.pendingFees(poolId, assetCurrency);
        console.log("SPCX skimmed by the hook on a 10,000 brandUSD buy:", pending);
        assertEq(pending, expected, "the hook accrued the protocol's cut, to the wei");
        assertEq(feeHook.pendingFees(poolId, brandCurrency), 0, "and none off the input leg");

        // The claim is held as ERC-6909 inside the manager until collected.
        assertEq(
            MANAGER.balanceOf(address(feeHook), assetCurrency.toId()),
            pending,
            "held as an ERC-6909 claim against the real singleton"
        );

        uint256 treasuryBefore = IERC20(SPCX).balanceOf(protocolTreasury);
        (uint256 amount0, uint256 amount1) = feeHook.collect(poolKey);

        assertEq(brandFirst ? amount1 : amount0, expected, "collect moved the whole balance");
        assertEq(brandFirst ? amount0 : amount1, 0, "and nothing on the other side");
        assertEq(
            IERC20(SPCX).balanceOf(protocolTreasury) - treasuryBefore,
            expected,
            "delivered to the protocol treasury"
        );
        assertEq(feeHook.pendingFees(poolId, assetCurrency), 0, "the claim is cleared");
        assertEq(
            MANAGER.balanceOf(address(feeHook), assetCurrency.toId()), 0, "and the 6909 burned"
        );
    }

    /// @notice The sell side pays its skim in the BRAND, which is the branch that runs through
    ///         the *other* currency of the key. Worth its own case: an ordering bug in the
    ///         `PoolKey` would show up on exactly one of the two directions.
    ///
    ///         Which currency that is moved when the skim moved into `afterSwap`. Both
    ///         directions this suite trades are exact-input, so the leg the caller did not
    ///         name is the output on both, and a sale of SPCX outputs brandUSD. The asset is
    ///         what the seller hands over, which is now precisely the leg the hook leaves
    ///         alone, so the two directions still land on opposite currencies of the key,
    ///         just the other way round.
    function test_fork_theSellSidePaysItsSkimInTheBrandItReceives() public {
        _createMarket();
        _addLiquidity();

        bool brandFirst = _brandIsCurrency0();
        Currency brandCurrency = brandFirst ? poolKey.currency0 : poolKey.currency1;
        Currency assetCurrency = brandFirst ? poolKey.currency1 : poolKey.currency0;
        assertEq(Currency.unwrap(assetCurrency), SPCX, "the asset side of the key");

        uint256 amountIn = 10e18;
        uint256 gross = _grossOutWithoutTheSkim(!brandFirst, amountIn, brandToken);
        uint256 expected = gross * PROTOCOL_FEE_PIPS / 1_000_000;
        assertGt(expected, 0, "a ten-SPCX sale is large enough to owe something");

        uint256 brandBefore = IERC20(brandToken).balanceOf(trader);
        _swap(!brandFirst, amountIn);

        assertEq(
            IERC20(brandToken).balanceOf(trader) - brandBefore,
            gross - expected,
            "the seller keeps the payout less the skim, and nothing else was taken"
        );
        assertEq(feeHook.pendingFees(poolId, brandCurrency), expected, "pips of what it paid out");
        assertEq(feeHook.pendingFees(poolId, assetCurrency), 0, "the SPCX it sold is untouched");

        feeHook.collect(poolKey);
        assertEq(
            IERC20(brandToken).balanceOf(protocolTreasury),
            expected,
            "brandUSD delivered to the treasury"
        );
    }

    // ─── 5. The oracle records against the real manager ──────────────────

    /// @notice v4 core keeps no observations, so the market's TWAP is the hook reading
    ///         `getSlot0` off the deployed manager in `beforeSwap` and accumulating it itself.
    ///         This asserts the accumulator tracks the real pool, and that the V3 write
    ///         ordering the hook copied still makes a same-block spike-and-revert free.
    function test_fork_theHookOracleTracksTheRealPoolAndIgnoresASameBlockSpike() public {
        _createMarket();
        _addLiquidity();
        _buildOracleHistory();

        int24 spot = _currentTick();
        int24 twap = feeHook.consultTick(poolKey, TWAP_WINDOW);
        console.logInt(spot);
        console.logInt(twap);

        // A time-weighted mean of a lightly-traded pool sits near spot but not on it. The
        // band is generous on purpose: the claim is "sane and derived from this pool", not a
        // reproduction of the accumulator's arithmetic, which the unit suite already pins.
        int24 drift = twap > spot ? twap - spot : spot - twap;
        assertGt(twap, TickMath.MIN_TICK, "a real tick, not a fabricated zero");
        assertLt(drift, 2 * TICK_SPACING * 100, "and within sight of the live tick");

        // Now the manipulation: a large buy and an equal-sized sell, inside one block.
        int24 before = feeHook.consultTick(poolKey, TWAP_WINDOW);
        uint256 spikeIn = 40_000e6;
        _mintBrand(trader, spikeIn);

        bool brandFirst = _brandIsCurrency0();
        uint256 spcxBefore = IERC20(SPCX).balanceOf(trader);
        _swap(brandFirst, spikeIn);
        int24 spiked = _currentTick();
        _swap(!brandFirst, IERC20(SPCX).balanceOf(trader) - spcxBefore);

        assertTrue(spiked != spot, "the spike genuinely moved the pool");
        assertEq(
            feeHook.consultTick(poolKey, TWAP_WINDOW),
            before,
            "and contributed exactly nothing to the TWAP: no time passed, and the first write "
            "of the block had already recorded the honest pre-spike tick"
        );
    }

    // ─── 6. The yield split, against the live market ─────────────────────

    /// @notice A market whose depth is real liquidity on the deployed singleton divides its
    ///         float yield the only way it can: the protocol's basis points, and then
    ///         everything left — rounding dust included — streamed to the LPs who supplied
    ///         that depth, through the market's own distributor.
    ///
    ///         The vault is funded directly rather than by warping Morpho forward: this suite
    ///         is about the venue, and `AssetMarketForkTest` already proves real Morpho
    ///         interest reaches the vault.
    function test_fork_theVaultSplitsItsYieldToTheLpsOfTheRealPool() public {
        _createMarket();
        uint128 liquidity = _addLiquidity();
        assertGt(liquidity, 0, "there are LPs on the live singleton to pay");

        uint256 funding = 5_000e6;
        _mintBrand(address(feeVault), funding);

        (uint256 toProtocol, uint256 toLps) = feeVault.sweep();
        assertEq(toProtocol, 0, "zero protocol fee on yield, as shipped");
        assertEq(toLps, funding * feeVault.lpBps() / 10_000, "the LPs take the configured cut");
        assertEq(toProtocol + toLps, funding, "and the two shares are the whole of it");

        // The LP share is brandUSD, and it is the market's own distributor that holds it and
        // is streaming it out.
        assertEq(address(feeVault.distributor()), address(distributor), "the market's own");
        assertEq(IERC20(brandToken).balanceOf(address(distributor)), toLps, "the LP share landed");
        assertGt(distributor.periodFinish(), vm.getBlockTimestamp(), "and is streaming");
        assertEq(feeVault.balance(), 0, "the vault kept nothing");

        // And nobody outside the factory can point that yield anywhere else.
        vm.prank(operator);
        vm.expectRevert(BrandFeeVault.OnlyFactory.selector);
        feeVault.setDistributor(distributor);
    }
}
