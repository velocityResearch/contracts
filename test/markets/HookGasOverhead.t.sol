// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {PoolObservations} from "../../src/markets/PoolObservations.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice What `ProtocolFeeHook` adds to a v4 swap, measured by running the same swap
///         against two pools that differ only in whether the hook is attached.
///
///         **This exists because an off-chain consumer hard-codes these numbers.** The
///         KyberSwap aggregator adapter for this hook
///         (`kyberswap-dex-lib`, `pkg/liquidity-source/uniswap/v4/hooks/stables`) prices a
///         route partly on the hook's gas, and it cannot see this repo. Adding a storage
///         write to `beforeSwap` or `_accrue` would silently make its routing costs wrong,
///         so the bounds below are a tripwire on that, not a performance budget. Widen them
///         only together with the adapter's constants.
contract HookGasOverheadTest is Test, StackFixture, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint24 constant FEE = 5_000;
    int24 constant TICK_SPACING = 50;
    uint24 constant FEE_PIPS = 5_000; // the shipped 0.50% skim

    PoolManager manager;
    ProtocolFeeHook hook;
    PoolModifyLiquidityTest lpRouter;
    MockUSDC dollar;
    MockAsset asset;

    PoolKey hooked;
    PoolKey bare;

    address owner = address(0x0AD01);

    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x2C71 << 144)
            ),
            IPoolManager(address(manager)),
            owner
        );
        vm.prank(owner);
        hook.setRegistrar(address(this));

        dollar = new MockUSDC();
        asset = new MockAsset();

        hooked = _key(IHooks(address(hook)));
        bare = _key(IHooks(address(0)));

        manager.initialize(hooked, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(bare, TickMath.getSqrtPriceAtTick(0));
        // Registration is what opens the pool's oracle buffer and fixes its rate, so the
        // hooked pool is measured doing everything a live market's pool does.
        hook.registerPool(hooked, address(0xFEE), FEE_PIPS);

        _seed(hooked);
        _seed(bare);
    }

    function test_hookGasOverheadMatchesTheAggregatorAdapter() public {
        // A fresh block, far enough ahead that the hooked swap actually pays for an
        // observation. `PoolObservations.MIN_INTERVAL` is 15 seconds, and `write` returns early
        // without touching the ring when less than that has elapsed
        // (`PoolObservations.sol:182`). This warp used to be 12 seconds, which is BELOW the
        // throttle, so the "observation + accrue" band below was measuring an accrual against a
        // cold slot and no observation at all. The throttle replaced V3's once-per-block rule,
        // and the warp was never updated to follow it.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + PoolObservations.MIN_INTERVAL);

        uint256 bareCold = _swap(bare, -1_000e6);
        uint256 hookedCold = _swap(hooked, -1_000e6);

        // Same block again: the oracle write is suppressed, only the skim remains.
        uint256 bareWarm = _swap(bare, -1_000e6);
        uint256 hookedWarm = _swap(hooked, -1_000e6);

        // Exact-out takes the skim in afterSwap too, but on the OTHER currency.
        //
        // Since the fee moved to the unspecified leg, an exact-in swap accrues on the OUTPUT
        // and an exact-out swap accrues on the INPUT, so the two directions now write two
        // different `pendingFees` slots and two different ERC-6909 balances. The first swap in
        // each direction therefore pays cold-SSTORE prices for its currency, once, and that
        // one-time cost is not the steady-state overhead an integrator budgets for. Measured
        // rather than asserted, because it is worth seeing: it ran about 44k when this was
        // written.
        uint256 bareOutCold = _swap(bare, 1_000e6); // the probe pool is raw 1:1, not decimal-adjusted
        uint256 hookedOutCold = _swap(hooked, 1_000e6);
        console.log("exact-out first touch of its currency:", hookedOutCold - bareOutCold);

        // Now the steady state, with both currencies warm. This is the number that matters.
        uint256 bareOut = _swap(bare, 1_000e6);
        uint256 hookedOut = _swap(hooked, 1_000e6);

        console.log("exact-in  first swap of block:", hookedCold - bareCold);
        console.log("exact-in  later in same block:", hookedWarm - bareWarm);
        console.log("exact-out later in same block:", hookedOut - bareOut);

        // The adapter's `gasObservation` (60k) + `gasAccrue` (20k). Bands are wide enough to
        // absorb solc and v4-core churn and tight enough that a new SSTORE trips them.
        assertApproxEqAbs(hookedCold - bareCold, 80_000, 15_000, "observation + accrue");
        assertApproxEqAbs(hookedWarm - bareWarm, 20_000, 8_000, "accrue only, exact-in");
        assertApproxEqAbs(hookedOut - bareOut, 20_000, 8_000, "accrue only, exact-out");
        // And the one-time cost is bounded: a cold slot pair, not something unbounded.
        assertLt(
            hookedOutCold - bareOutCold,
            70_000,
            "first-touch overhead is a cold slot pair, not a new code path"
        );
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _key(IHooks hooks) internal view returns (PoolKey memory) {
        (address c0, address c1) = address(dollar) < address(asset)
            ? (address(dollar), address(asset))
            : (address(asset), address(dollar));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function _seed(PoolKey memory key) internal {
        dollar.mint(address(this), 500_000e6);
        asset.mint(address(this), 500_000e18);
        IERC20(Currency.unwrap(key.currency0)).forceApprove(address(lpRouter), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).forceApprove(address(lpRouter), type(uint256).max);

        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        bool dollarIsZero = Currency.unwrap(key.currency0) == address(dollar);
        (uint256 a0, uint256 a1) =
            dollarIsZero ? (uint256(500_000e6), uint256(500_000e18)) : (500_000e18, 500_000e6);

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(
                    uint256(
                        LiquidityAmounts.getLiquidityForAmounts(
                            sqrtPriceX96,
                            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING)),
                            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING)),
                            a0,
                            a1
                        )
                    )
                ),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Gas for one `unlock`-wrapped swap, dollar in.
    function _swap(PoolKey memory key, int256 amountSpecified) internal returns (uint256) {
        dollar.mint(address(this), 10_000e6);
        asset.mint(address(this), 10_000e18);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(dollar);

        uint256 g = gasleft();
        manager.unlock(abi.encode(key, zeroForOne, amountSpecified));
        return g - gasleft();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) =
            abi.decode(data, (PoolKey, bool, int256));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency))
                .safeTransfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
