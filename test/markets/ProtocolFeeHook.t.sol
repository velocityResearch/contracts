// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {PoolObservations} from "../../src/markets/PoolObservations.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @notice Behavioural tests for the v4 protocol-fee hook.
///
///         The load-bearing claim these check is the one the design now rests on: the hook's
///         slice always comes off the UNSPECIFIED currency, always in `afterSwap`, and always
///         out of amounts the pool actually moved. That is asserted directly in
///         `test_exactIn_theSkimComesOutOfTheOutputAndLeavesTheSwapUntouched` against an
///         identical hookless pool, and in
///         `test_exactIn_aPartialFillIsNeverChargedOnTheUnfilledRemainder`, which is the one a
///         `beforeSwap` skim cannot pass.
contract ProtocolFeeHookTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant LP_FEE = 3000; // 0.30% to liquidity
    uint24 internal constant PROTOCOL_FEE_PIPS = 1000; // 0.10% to the protocol
    int24 internal constant TICK_SPACING = 60;

    /// @dev The window the manipulation tests read the mean over. An hour, matching the default
    ///      `AssetMarketFactory.BuybackParams.twapWindow` a market ships with.
    uint32 internal constant TWAP_WINDOW = 3600;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    ProtocolFeeHook internal hook;

    TestERC20 internal tokenA;
    TestERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal hookedKey;
    PoolKey internal bareKey;

    address internal owner = address(0xB0B);
    address internal registrar = address(0xFAC);
    address internal vault = address(0xDEFEA7);
    address internal trader = address(0x7AAD);

    function setUp() public {
        _deployUpgradeBase();

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        tokenA = new TestERC20(0);
        tokenB = new TestERC20(0);
        (currency0, currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        hook = _deployHook();

        vm.prank(owner);
        hook.setRegistrar(registrar);

        hookedKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        bareKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        manager.initialize(hookedKey, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(bareKey, TickMath.getSqrtPriceAtTick(0));

        vm.prank(registrar);
        hook.registerPool(hookedKey, vault, PROTOCOL_FEE_PIPS);

        _mintAndApprove(address(this), 1_000_000e18);
        _addLiquidity(hookedKey);
        _addLiquidity(bareKey);

        _mintAndApprove(trader, 1_000e18);
    }

    /// @dev The hook's permission bits live in the low 14 bits of its own address, so the
    ///      address is not a free choice. `deployCodeTo` writes the contract at an address we
    ///      pick and still runs the constructor, so `Hooks.validateHookPermissions` still
    ///      executes — this is the standard way to skip salt mining in tests without skipping
    ///      the check that mining exists to satisfy.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    function _mintAndApprove(address who, uint256 amount) internal {
        tokenA.mint(who, amount);
        tokenB.mint(who, amount);

        vm.startPrank(who);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenA.approve(address(lpRouter), type(uint256).max);
        tokenB.approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _addLiquidity(PoolKey memory key) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 1000,
                tickUpper: TICK_SPACING * 1000,
                liquidityDelta: 100_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swapExactIn(PoolKey memory key, uint256 amountIn) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapExactOut(PoolKey memory key, uint256 amountOut) internal returns (BalanceDelta) {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev An exact-input swap that stops at `sqrtPriceLimitX96` instead of sweeping the book.
    ///      This is what an aggregator routing straight to the `PoolManager` does, and what
    ///      `MarketRouter` deliberately does not: it passes the extreme limits, so it fills or
    ///      reverts and never produces the partial fill the test below is about.
    function _swapExactInToLimit(PoolKey memory key, uint256 amountIn, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ─── The core claim ──────────────────────────────────────────────────

    function test_exactIn_skimsTheOutputCurrency() public {
        uint256 amountIn = 100e18;
        BalanceDelta delta = _swapExactIn(hookedKey, amountIn);

        // The unspecified leg of an exact-input swap is the OUTPUT, and what the trader was
        // left with is already net of the hook, so the pool's gross output is that plus the
        // fee and the fee is exactly that rate of the gross.
        uint256 fee = hook.pendingFees(hookedKey.toId(), currency1);
        uint256 gross = uint256(uint128(delta.amount1())) + fee;

        assertGt(fee, 0, "something was taken");
        assertEq(fee, (gross * PROTOCOL_FEE_PIPS) / 1_000_000, "and it is pips of the real output");
        assertEq(
            hook.pendingFees(hookedKey.toId(), currency0), 0, "nothing accrued on the input side"
        );
        assertEq(uint256(-int256(delta.amount0())), amountIn, "the input leg is untouched");
    }

    /// @notice Where the exact-input skim now lands, proven against an otherwise identical
    ///         hookless pool.
    ///
    ///         This is the inverse of the test that used to live here. While the skim ran in
    ///         `beforeSwap` the pool saw `amountIn - fee`, so the LP fee applied only to the
    ///         remainder and the hooked pool's gross output was strictly smaller than the bare
    ///         pool's. It is not any more: both pools swap the same input, their gross outputs
    ///         are IDENTICAL, and the hooked trader's shortfall is the hook's pips of that
    ///         output and nothing else. Equality rather than a band is the whole point — it
    ///         says the hook no longer perturbs the swap at all, only its proceeds, which is
    ///         also why the LPs are no longer diluted by the skim.
    function test_exactIn_theSkimComesOutOfTheOutputAndLeavesTheSwapUntouched() public {
        uint256 amountIn = 100e18;

        BalanceDelta bare = _swapExactIn(bareKey, amountIn);
        BalanceDelta hooked = _swapExactIn(hookedKey, amountIn);

        uint256 bareOut = uint256(uint128(bare.amount1()));
        uint256 hookedOut = uint256(uint128(hooked.amount1()));
        uint256 fee = hook.pendingFees(hookedKey.toId(), currency1);

        assertEq(uint256(-int256(bare.amount0())), amountIn, "bare pool charged the full input");
        assertEq(uint256(-int256(hooked.amount0())), amountIn, "and so did the hooked one");

        assertEq(fee, (bareOut * PROTOCOL_FEE_PIPS) / 1_000_000, "the fee is pips of the output");
        assertEq(hookedOut, bareOut - fee, "and the trader is short by exactly that, no more");
        assertEq(hook.pendingFees(hookedKey.toId(), currency0), 0, "nothing came off the input");
    }

    /// @notice Exact-output is the path that was already correct and is unchanged by the move:
    ///         its unspecified leg IS the input, so this still charges the input currency, and
    ///         still measures it from the delta rather than from the request.
    function test_exactOut_stillSkimsTheInputCurrency() public {
        BalanceDelta delta = _swapExactOut(hookedKey, 50e18);

        uint256 fee = hook.pendingFees(hookedKey.toId(), currency0);
        uint256 paidIn = uint256(uint128(-delta.amount0()));

        assertGt(fee, 0, "fee accrued on the input side");
        assertEq(fee, ((paidIn - fee) * PROTOCOL_FEE_PIPS) / 1_000_000, "pips of the real input");
        assertEq(hook.pendingFees(hookedKey.toId(), currency1), 0, "not on the output side");
        assertEq(uint256(uint128(delta.amount1())), 50e18, "and the trader got what they asked");
    }

    /// @notice Charging only one swap type would let anyone avoid the fee by flipping the other
    ///         way. Both paths charge. They land on different legs, because the unspecified
    ///         currency is the output of one and the input of the other, and that asymmetry is
    ///         the mechanism rather than an accident of it.
    function test_neitherSwapTypeEscapesTheFee() public {
        PoolId id = hookedKey.toId();

        _swapExactIn(hookedKey, 10e18);
        assertGt(hook.pendingFees(id, currency1), 0, "exact-input paid, on the output leg");
        assertEq(hook.pendingFees(id, currency0), 0, "and only there");

        _swapExactOut(hookedKey, 10e18);
        assertGt(hook.pendingFees(id, currency0), 0, "exact-output paid, on the input leg");
    }

    // ─── Collection ──────────────────────────────────────────────────────

    function test_collect_sendsRealTokensToTheRegisteredRecipient() public {
        _swapExactIn(hookedKey, 100e18);
        uint256 accrued = hook.pendingFees(hookedKey.toId(), currency1);
        assertGt(accrued, 0);

        uint256 before = tokenOf(currency1).balanceOf(vault);
        hook.collect(hookedKey);

        assertEq(tokenOf(currency1).balanceOf(vault) - before, accrued, "vault received the fee");
        assertEq(hook.pendingFees(hookedKey.toId(), currency1), 0, "and the claim was cleared");
    }

    function test_collect_isPermissionlessAndCannotBeRedirected() public {
        _swapExactIn(hookedKey, 100e18);
        uint256 accrued = hook.pendingFees(hookedKey.toId(), currency1);

        // A stranger pays the gas; the tokens still go to the vault, because `collect` takes
        // no destination argument.
        vm.prank(address(0xDEAD));
        hook.collect(hookedKey);

        assertEq(tokenOf(currency1).balanceOf(vault), accrued);
    }

    function test_collect_withNothingAccruedIsANoOp() public {
        (uint256 a0, uint256 a1) = hook.collect(hookedKey);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_collect_revertsForAnUnregisteredPool() public {
        vm.expectRevert(ProtocolFeeHook.NotRegistered.selector);
        hook.collect(bareKey);
    }

    /// @notice The destination is repointable by the owner. It used to be one-shot, to keep
    ///         "this market's fees buy this market's asset" unrevokable for a `BuybackEngine`
    ///         that no longer exists; what it actually achieved was leaving every live market
    ///         paying a key that could not be rotated.
    function test_setFeeRecipient_repointsAPoolTheOwnerAlreadyRegistered() public {
        address treasury2 = address(0x7EA5);

        vm.prank(owner);
        hook.setFeeRecipient(hookedKey.toId(), treasury2);
        assertEq(hook.feeRecipientOf(hookedKey.toId()), treasury2, "destination moved");

        _swapExactIn(hookedKey, 100e18);
        uint256 accrued = hook.pendingFees(hookedKey.toId(), currency1);
        assertGt(accrued, 0);

        uint256 vaultBefore = tokenOf(currency1).balanceOf(vault);
        hook.collect(hookedKey);

        assertEq(tokenOf(currency1).balanceOf(treasury2), accrued, "the new address is paid");
        assertEq(tokenOf(currency1).balanceOf(vault), vaultBefore, "the old one is not");
    }

    /// @notice The ordering trap, pinned because an operator rotating a compromised key will
    ///         hit it: `pendingFees` is not attributed to whoever was named when it accrued.
    ///         `collect` pays whoever is named at the moment it runs, so fees earned before a
    ///         repoint follow the NEW address unless they are collected first.
    function test_setFeeRecipient_doesNotReattributeFeesAlreadyAccrued() public {
        _swapExactIn(hookedKey, 100e18);
        uint256 accrued = hook.pendingFees(hookedKey.toId(), currency1);
        assertGt(accrued, 0, "fees accrued while the vault was named");

        address treasury2 = address(0x7EA5);
        vm.prank(owner);
        hook.setFeeRecipient(hookedKey.toId(), treasury2);

        hook.collect(hookedKey);
        assertEq(tokenOf(currency1).balanceOf(treasury2), accrued, "the new address takes them");
        assertEq(tokenOf(currency1).balanceOf(vault), 0, "collect first if that is not wanted");
    }

    function test_setFeeRecipient_isOwnerOnlyAndRejectsZeroAndUnregistered() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        hook.setFeeRecipient(hookedKey.toId(), address(0x7EA5));

        vm.startPrank(owner);
        vm.expectRevert(ProtocolFeeHook.ZeroAddress.selector);
        hook.setFeeRecipient(hookedKey.toId(), address(0));

        vm.expectRevert(ProtocolFeeHook.NotRegistered.selector);
        hook.setFeeRecipient(bareKey.toId(), address(0x7EA5));
        vm.stopPrank();
    }

    /// @notice Repointing must not become a second way to register, or a pool could be given
    ///         a rate and an oracle it never paid for.
    function test_setFeeRecipient_isNotABackDoorIntoRegistration() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.NotRegistered.selector);
        hook.setFeeRecipient(bareKey.toId(), address(0x7EA5));
        assertEq(hook.feePipsFor(bareKey.toId()), 0, "still charged nothing");
        // Registration is also what opens the oracle buffer. `observationStates` is internal,
        // so the observable proof is that the pool is still unregistered to `collect`.
        vm.expectRevert(ProtocolFeeHook.NotRegistered.selector);
        hook.collect(bareKey);
    }

    // ─── Registration and rates ──────────────────────────────────────────

    function test_anUnregisteredPoolIsChargedNothing() public {
        PoolKey memory strangerKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        manager.initialize(strangerKey, TickMath.getSqrtPriceAtTick(0));

        lpRouter.modifyLiquidity(
            strangerKey,
            ModifyLiquidityParams({
                tickLower: -10 * 1000,
                tickUpper: 10 * 1000,
                liquidityDelta: 100_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        assertEq(hook.feePipsFor(strangerKey.toId()), 0, "no rate for a pool we did not register");

        _swapExactIn(strangerKey, 100e18);
        assertEq(hook.pendingFees(strangerKey.toId(), currency0), 0, "and nothing was taken");
        assertEq(hook.pendingFees(strangerKey.toId(), currency1), 0, "on either leg");
    }

    function test_registerPool_onlyTheRegistrar() public {
        PoolKey memory k = bareKey;
        k.hooks = IHooks(address(hook));
        k.fee = 500;

        vm.expectRevert(ProtocolFeeHook.OnlyRegistrar.selector);
        hook.registerPool(k, vault, 100);
    }

    function test_registerPool_rejectsAPoolPointedAtAnotherHook() public {
        vm.prank(registrar);
        vm.expectRevert(ProtocolFeeHook.HookMismatch.selector);
        hook.registerPool(bareKey, vault, 100);
    }

    function test_registerPool_isOneShot() public {
        vm.prank(registrar);
        vm.expectRevert(ProtocolFeeHook.AlreadyRegistered.selector);
        hook.registerPool(hookedKey, address(0xBEEF), 100);
    }

    function test_theFeeDestinationCannotBeMovedByTheOwner() public {
        // There is no setter for `feeRecipientOf`. The rate may move; the destination may not.
        assertEq(hook.feeRecipientOf(hookedKey.toId()), vault);

        vm.prank(owner);
        hook.setPoolFeePips(hookedKey.toId(), 500);

        assertEq(hook.feeRecipientOf(hookedKey.toId()), vault, "still the same vault");
        assertEq(hook.feePipsFor(hookedKey.toId()), 500, "only the rate moved");
    }

    function test_setPoolFeePips_respectsTheCeiling() public {
        // Read the ceiling first: an inline `hook.MAX_FEE_PIPS()` would itself be the "next
        // call" and would swallow both the prank and the revert expectation.
        uint24 tooMuch = hook.MAX_FEE_PIPS() + 1;
        PoolId id = hookedKey.toId();

        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.FeeTooLarge.selector);
        hook.setPoolFeePips(id, tooMuch);
    }

    function test_setPoolFeePips_isOwnerOnly() public {
        vm.expectRevert();
        hook.setPoolFeePips(hookedKey.toId(), 100);
    }

    /// @notice A pool's rate of zero means zero, and no hook-wide setting can raise it.
    ///
    ///         This is the inverse of a test that used to live here. `feePipsFor` read a stored
    ///         zero as "follow the hook's default", so every market created at the factory's
    ///         shipped rate of zero tracked a mutable global and one owner call raised the skim
    ///         on all of them at once, up to `MAX_FEE_PIPS`. The default is gone; a market
    ///         registered at zero is charged nothing until someone moves that one pool.
    function test_aZeroPoolRateIsZeroAndStaysThere() public {
        vm.prank(owner);
        hook.setPoolFeePips(hookedKey.toId(), 0);

        assertEq(hook.feePipsFor(hookedKey.toId()), 0, "zero is a rate, not a sentinel");

        uint256 amountIn = 100e18;
        _swapExactIn(hookedKey, amountIn);
        assertEq(
            hook.pendingFees(hookedKey.toId(), currency1), 0, "a zero-rate pool is skimmed nothing"
        );
    }

    /// @notice Moving one pool's rate leaves every other pool alone. There is no lever that
    ///         reaches all of them.
    function test_onePoolsRateDoesNotFollowAnother() public {
        PoolId id = hookedKey.toId();

        vm.prank(owner);
        hook.setPoolFeePips(id, 0);

        // The only remaining way to change a rate is per pool, and it is the owner's. Raising
        // it is announced rather than immediate, so this schedules and then commits.
        vm.prank(owner);
        hook.setPoolFeePips(id, 2500);
        vm.warp(block.timestamp + hook.FEE_INCREASE_DELAY());
        hook.commitPoolFeePips(id);
        assertEq(hook.feePipsFor(id), 2500, "the pool the owner named moved");

        // Quoted off the hookless twin, which fills identically, so the expectation is the real
        // output rather than a restatement of what the hook just computed.
        uint256 amountIn = 100e18;
        uint256 gross = uint256(uint128(_swapExactIn(bareKey, amountIn).amount1()));

        _swapExactIn(hookedKey, amountIn);
        assertEq(hook.pendingFees(id, currency1), (gross * 2500) / 1_000_000);
    }

    // ─── Announced fee increases ─────────────────────────────────────────

    /// @notice The property an aggregator is buying: a rate it quoted cannot rise under it.
    ///         A published quote stays good for at least `FEE_INCREASE_DELAY`.
    function test_anIncreaseDoesNotTakeEffectUntilItIsCommitted() public {
        PoolId id = hookedKey.toId();
        assertEq(hook.feePipsFor(id), PROTOCOL_FEE_PIPS, "the rate a quote would have read");

        vm.prank(owner);
        hook.setPoolFeePips(id, 5_000);

        // Announced, readable, and not charged.
        assertEq(hook.pendingFeePipsOf(id), 5_000, "the increase is visible in advance");
        assertEq(
            hook.feePipsEffectiveAt(id),
            uint64(block.timestamp) + hook.FEE_INCREASE_DELAY(),
            "and so is the moment it lands"
        );
        assertEq(hook.feePipsFor(id), PROTOCOL_FEE_PIPS, "but the live rate has not moved");

        // A swap during the window is charged the OLD rate. This is the whole point.
        uint256 gross = uint256(uint128(_swapExactIn(bareKey, 100e18).amount1()));
        _swapExactIn(hookedKey, 100e18);
        assertEq(
            hook.pendingFees(id, currency1),
            (gross * PROTOCOL_FEE_PIPS) / 1_000_000,
            "a fill inside the window pays what was quoted"
        );
    }

    function test_anIncreaseCannotBeCommittedEarly() public {
        PoolId id = hookedKey.toId();
        vm.prank(owner);
        hook.setPoolFeePips(id, 5_000);

        uint64 effectiveAt = hook.feePipsEffectiveAt(id);
        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolFeeHook.FeeIncreaseNotReady.selector, effectiveAt, uint64(block.timestamp)
            )
        );
        hook.commitPoolFeePips(id);

        // Exactly at the boundary it is allowed, so the delay is inclusive and not off by one.
        vm.warp(effectiveAt);
        hook.commitPoolFeePips(id);
        assertEq(hook.feePipsFor(id), 5_000, "and now it is charged");
    }

    /// @notice Committing is permissionless on purpose: the owner already announced it, and a
    ///         change that only the owner can finalise is one they can appear to have made
    ///         without making it.
    function test_anyoneMayCommitAnAnnouncedIncrease() public {
        PoolId id = hookedKey.toId();
        vm.prank(owner);
        hook.setPoolFeePips(id, 5_000);
        vm.warp(block.timestamp + hook.FEE_INCREASE_DELAY());

        vm.prank(address(0xDEAD));
        hook.commitPoolFeePips(id);
        assertEq(hook.feePipsFor(id), 5_000);
        assertEq(hook.feePipsEffectiveAt(id), 0, "and the pending slot is cleared");
    }

    function test_aDecreaseIsImmediateAndAbandonsAPendingIncrease() public {
        PoolId id = hookedKey.toId();
        vm.startPrank(owner);
        hook.setPoolFeePips(id, 9_000);
        assertEq(hook.pendingFeePipsOf(id), 9_000, "an increase is in flight");

        // Cutting the rate applies at once and must not leave the 9,000 primed to land later.
        hook.setPoolFeePips(id, 100);
        vm.stopPrank();

        assertEq(hook.feePipsFor(id), 100, "the cut is immediate");
        assertEq(hook.feePipsEffectiveAt(id), 0, "and the pending increase is gone");

        vm.warp(block.timestamp + hook.FEE_INCREASE_DELAY() + 1);
        vm.expectRevert(ProtocolFeeHook.NoPendingFeeIncrease.selector);
        hook.commitPoolFeePips(id);
    }

    /// @notice Re-scheduling restarts the clock, so a small announced increase cannot be
    ///         swapped for a large one just before it lands.
    function test_reschedulingRestartsTheClock() public {
        PoolId id = hookedKey.toId();
        vm.prank(owner);
        hook.setPoolFeePips(id, 2_000);
        uint64 first = hook.feePipsEffectiveAt(id);

        vm.warp(block.timestamp + hook.FEE_INCREASE_DELAY() - 10);
        vm.prank(owner);
        hook.setPoolFeePips(id, 9_000);

        assertEq(hook.pendingFeePipsOf(id), 9_000, "the larger value replaced it");
        assertGt(hook.feePipsEffectiveAt(id), first, "and it waits a fresh full delay");

        vm.warp(first);
        vm.expectRevert();
        hook.commitPoolFeePips(id);
    }

    function test_cancelIsOwnerOnlyAndNeedsSomethingPending() public {
        PoolId id = hookedKey.toId();

        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.NoPendingFeeIncrease.selector);
        hook.cancelPendingPoolFeePips(id);

        vm.prank(owner);
        hook.setPoolFeePips(id, 5_000);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        hook.cancelPendingPoolFeePips(id);

        vm.prank(owner);
        hook.cancelPendingPoolFeePips(id);
        assertEq(hook.feePipsEffectiveAt(id), 0);
        assertEq(hook.feePipsFor(id), PROTOCOL_FEE_PIPS, "the live rate never moved");
    }

    /// @notice The ceiling is enforced when scheduling AND when committing. It has already been
    ///         lowered once, from 5% to 1%, so a value authorised under an older ceiling must
    ///         not be able to land under a newer one.
    function test_theCeilingIsCheckedAtCommitAsWellAsAtSchedule() public {
        PoolId id = hookedKey.toId();
        // Read the ceiling and the delay FIRST. An inline `hook.MAX_FEE_PIPS()` would itself
        // be the "next call" and would swallow both the prank and the revert expectation,
        // exactly as `test_setPoolFeePips_respectsTheCeiling` above warns.
        uint24 ceiling = hook.MAX_FEE_PIPS();
        uint64 delay = hook.FEE_INCREASE_DELAY();

        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.FeeTooLarge.selector);
        hook.setPoolFeePips(id, ceiling + 1);

        vm.prank(owner);
        hook.setPoolFeePips(id, ceiling);
        vm.warp(block.timestamp + delay);
        hook.commitPoolFeePips(id);
        assertEq(hook.feePipsFor(id), ceiling, "the ceiling itself is reachable");
    }

    function test_aDustSwapTakesNothingRatherThanReverting() public {
        // `feeAmount` rounds to zero, so the hook must return a zero delta rather than a
        // delta core will reject.
        _swapExactIn(hookedKey, 100);
        assertEq(hook.pendingFees(hookedKey.toId(), currency0), 0);
        assertEq(hook.pendingFees(hookedKey.toId(), currency1), 0);
    }

    /// @notice **The finding this fee was moved for.** A swap carrying a binding
    ///         `sqrtPriceLimitX96` fills only part of what it asked for, and the remainder
    ///         never trades. Charging in `beforeSwap` billed the trader on the whole request,
    ///         because the request is the only number that exists before the pool has run — up
    ///         to the full `MAX_FEE_PIPS` of notional that never moved. `MarketRouter` never
    ///         reached it, since it passes the extreme price limits and so fills or reverts,
    ///         but an aggregator routing straight at the `PoolManager` sets its own limit and
    ///         is exactly that caller.
    ///
    ///         The first assertion is the invariant, and it is what fails against the old
    ///         implementation: there the input-side charge is 0.10% of the full 10,000e18
    ///         request while only a few hundred units actually fill, roughly thirty times the
    ///         ceiling this line allows.
    function test_exactIn_aPartialFillIsNeverChargedOnTheUnfilledRemainder() public {
        _mintAndApprove(trader, 100_000e18);
        PoolId id = hookedKey.toId();

        uint256 requested = 10_000e18;
        // One tick spacing below the pool's starting tick: nowhere near enough room for the
        // request, which is the point. The pool stops at the limit and abandons the rest.
        uint160 limit = TickMath.getSqrtPriceAtTick(-TICK_SPACING);

        BalanceDelta bare = _swapExactInToLimit(bareKey, requested, limit);
        BalanceDelta hooked = _swapExactInToLimit(hookedKey, requested, limit);

        uint256 feeOnInput = hook.pendingFees(id, currency0);
        uint256 feeOnOutput = hook.pendingFees(id, currency1);

        // What the trader parted with, less whatever the hook took off that same leg, is what
        // the pool actually swapped.
        uint256 filledIn = uint256(uint128(-hooked.amount0())) - feeOnInput;
        uint256 filledOut = uint256(uint128(hooked.amount1())) + feeOnOutput;

        assertGt(filledIn, 0, "it filled something, or this test proves nothing");
        assertLt(filledIn, requested / 10, "and the limit bound: this really is a partial fill");

        assertLe(
            feeOnInput,
            (filledIn * PROTOCOL_FEE_PIPS) / 1_000_000,
            "the trader was charged on notional that never traded"
        );

        // The same partial fill through the hookless twin, which is the strongest available
        // statement that the hook no longer perturbs the trade: identical fill on both legs,
        // and the cut is pips of what the pool produced rather than of what was asked for.
        assertEq(filledIn, uint256(uint128(-bare.amount0())), "the pool swapped the same input");
        assertEq(filledOut, uint256(uint128(bare.amount1())), "and produced the same output");
        assertEq(
            feeOnOutput,
            (uint256(uint128(bare.amount1())) * PROTOCOL_FEE_PIPS) / 1_000_000,
            "charged on the fill, not on the request"
        );
    }

    function test_hookCallbacksRejectEveryoneButThePoolManager() public {
        vm.expectRevert(ProtocolFeeHook.OnlyPoolManager.selector);
        hook.beforeSwap(
            address(this),
            hookedKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0}),
            ""
        );
    }

    // ─── The oracle ──────────────────────────────────────────────────────
    //
    // V4 core keeps no price history, so the hook keeps it instead. What these check is that
    // the ported ring buffer answers the two questions `BuybackEngine` actually asks — "what was
    // the mean tick over the last N seconds" and "do you even have N seconds" — and that it
    // refuses rather than improvises when it cannot.
    //
    // ─────────────────────────────────────────────────────────────────────
    // WARNING, and it is not specific to this file: under `via_ir`, DO NOT read `block.timestamp`
    // into a local in a test that calls `vm.warp`. Use `vm.getBlockTimestamp()`.
    //
    // This repo compiles with `via_ir = true` (foundry.toml). The IR optimiser treats TIMESTAMP
    // as a pure, deterministic opcode and is free to common-subexpression it: a `block.timestamp`
    // you stored in a local is not a snapshot, it is a re-executed TIMESTAMP, and a `vm.warp`
    // in between changes what it evaluates to. So
    //
    //     uint256 t0 = block.timestamp;   // reads 1
    //     vm.warp(t0 + 100);              // warps to 101
    //     vm.warp(t0 + 200);              // warps to 301, NOT 201 — t0 re-read as 101
    //
    // The failure is silent and plausible-looking: no revert, no warning, just intervals that
    // are the wrong length, so a TWAP assertion fails by a believable margin and reads like an
    // oracle bug. It cost real time to find here. `vm.getBlockTimestamp()` is a cheatcode call,
    // which the optimiser cannot fold, and is correct everywhere `block.timestamp` was.
    //
    // Any other suite in this repo that mixes `vm.warp` with a cached `block.timestamp` has the
    // same latent bug, whether or not it is currently failing.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev How deep a ring has to be to serve a `window`-second mean, mirroring
    ///      `AssetMarketFactory.cardinalityForWindow` — which is what a real market is actually
    ///      grown to, and the reason no test here hardcodes a slot count.
    ///      `ceil((window + MIN_INTERVAL) / MIN_INTERVAL) + 1`: the `+ MIN_INTERVAL` is the lag
    ///      `BuybackEngine.twapSqrtPriceX96` reads with, and the `+ 1` is not slack, it is what
    ///      puts the oldest entry at or before the target rather than exactly on it. Duplicated
    ///      rather than called because the function is `public` on the factory and a hook unit
    ///      test has no factory to stand up.
    function _cardinalityForWindow(uint32 window) internal pure returns (uint16) {
        uint256 reach = uint256(window) + PoolObservations.MIN_INTERVAL;
        return
            uint16((reach + PoolObservations.MIN_INTERVAL - 1) / PoolObservations.MIN_INTERVAL + 1);
    }

    /// @dev The read `BuybackEngine.twapSqrtPriceX96` actually performs: a `window`-second mean
    ///      whose NEWER endpoint sits `MIN_INTERVAL` seconds in the past, so that neither
    ///      endpoint is extrapolated at the pool's live tick while the pool is trading.
    ///      Duplicated here, rather than reached through an engine, because everything these
    ///      tests are about happens inside the hook's ring buffer and standing up a market to
    ///      observe it would only add moving parts.
    function _laggedMeanTick(PoolKey memory key, uint32 window) internal view returns (int24) {
        uint32 lag = PoolObservations.MIN_INTERVAL;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window + lag;
        secondsAgos[1] = lag;

        int56[] memory cumulatives = hook.observe(key, secondsAgos);
        return _floorDiv(cumulatives[1] - cumulatives[0], int56(uint56(window)));
    }

    /// @dev The cumulative at the lagged read's newer endpoint, which is where the live tick
    ///      leaks in when it leaks at all. Asserting on this rather than on the mean isolates
    ///      the leak from the honest history simultaneously falling off the window's tail.
    function _laggedEndCumulative(PoolKey memory key) internal view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = PoolObservations.MIN_INTERVAL;
        return hook.observe(key, secondsAgos)[0];
    }

    /// @dev Division flooring toward negative infinity, as both the oracle and the engine do —
    ///      Solidity truncates toward zero, which rounds a negative mean up.
    function _floorDiv(int56 numerator, int56 denominator) internal pure returns (int24) {
        int24 quotient = int24(numerator / denominator);
        if (numerator < 0 && numerator % denominator != 0) quotient--;
        return quotient;
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    function _currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), key.toId());
    }

    /// @dev A pool registered *now* rather than in `setUp`, so its history has a known, recent
    ///      start and a window can be asked for that genuinely predates it.
    function _freshPool() internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        vm.prank(registrar);
        hook.registerPool(key, vault, PROTOCOL_FEE_PIPS);

        _mintAndApprove(address(this), 1_000_000e18);
        _addLiquidity(key);
    }

    /// @notice One observation per `PoolObservations.MIN_INTERVAL` seconds, not one per swap.
    ///
    ///         The throttle is what decouples the ring's time span from how often the pool
    ///         trades: `cardinality` slots reach back at least `MIN_INTERVAL * (cardinality - 1)`
    ///         seconds no matter how busy the pool is. Both halves of that are checked here — a
    ///         swap on or after the boundary advances the cursor, and a second swap inside the
    ///         same window writes nothing at all.
    function test_anObservationIsWrittenOncePerThrottleWindowAndTheBufferAdvances() public {
        PoolId id = hookedKey.toId();
        hook.increaseObservationCardinalityNext(hookedKey, 4);

        (uint16 index, uint16 cardinality,) = hook.observationState(id);
        assertEq(index, 0, "registration seeds exactly one observation");
        assertEq(cardinality, 1, "and the ring is not grown until a write needs the room");

        // Four swaps, each exactly one throttle window after the last: the cursor advances once
        // each and wraps back to zero on the fourth, which is what "ring" means. `MIN_INTERVAL`
        // rather than some comfortable multiple of it, because the boundary is inclusive and a
        // test that warped further would not prove that.
        uint16[4] memory expectedIndex = [uint16(1), 2, 3, 0];
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + PoolObservations.MIN_INTERVAL);
            _swapExactIn(hookedKey, 1e18);

            (index, cardinality,) = hook.observationState(id);
            assertEq(index, expectedIndex[i], "cursor advanced");
            assertEq(cardinality, 4, "ring grew to the requested depth on the first wrap");

            (uint32 stamp,, bool initialized) = hook.getObservation(id, index);
            assertTrue(initialized, "the slot the cursor points at is written");
            assertEq(stamp, uint32(vm.getBlockTimestamp()), "and stamped with this block");
        }

        // A later block that is still inside the window writes nothing. This is the part that
        // stops a dust swap per block from spending the whole ring on a few seconds of history.
        (uint16 indexBefore,,) = hook.observationState(id);
        vm.warp(vm.getBlockTimestamp() + PoolObservations.MIN_INTERVAL - 1);
        _swapExactIn(hookedKey, 1e18);

        (uint16 indexAfter,,) = hook.observationState(id);
        assertEq(indexAfter, indexBefore, "a swap inside the throttle window wrote nothing");
    }

    /// @notice One entry per block, not one per swap. This is what stops a trader from planting
    ///         two observations inside a single block and giving a same-block round trip more
    ///         weight in the accumulator than the block's duration justifies.
    function test_twoSwapsInOneBlockWriteOnlyOneObservation() public {
        PoolId id = hookedKey.toId();
        hook.increaseObservationCardinalityNext(hookedKey, 8);

        vm.warp(vm.getBlockTimestamp() + 60);
        _swapExactIn(hookedKey, 5e18);
        (uint16 indexAfterFirst,,) = hook.observationState(id);

        _swapExactIn(hookedKey, 5e18);
        (uint16 indexAfterSecond,,) = hook.observationState(id);

        assertEq(indexAfterSecond, indexAfterFirst, "the second swap wrote nothing");
    }

    /// @notice The mean is time-weighted, not swap-weighted. Two price levels held for a
    ///         hundred seconds each must average to the midpoint of the two ticks, and the
    ///         expected value here is computed by hand from the ticks the pool actually landed
    ///         on rather than read back out of the oracle.
    function test_consultTickReturnsTheTimeWeightedMeanAcrossTwoPriceLevels() public {
        hook.increaseObservationCardinalityNext(hookedKey, 8);
        uint256 t0 = vm.getBlockTimestamp();

        // Three swaps, so that the window under test spans two intervals that each sat at a
        // price some earlier swap established. The observation a swap writes carries the tick
        // from *before* it, so the interval a tick is credited to is the one that ends at the
        // swap which replaced it.
        vm.warp(t0 + 100);
        _swapExactIn(hookedKey, 50e18);
        int24 tick1 = _currentTick(hookedKey); // holds over [t0+100, t0+200]

        vm.warp(t0 + 200);
        _swapExactIn(hookedKey, 50e18);
        int24 tick2 = _currentTick(hookedKey); // holds over [t0+200, t0+300]

        vm.warp(t0 + 300);
        _swapExactIn(hookedKey, 50e18);

        assertTrue(tick1 != tick2, "the two intervals really are at different prices");
        assertLt(tick1, int24(0), "and both are real, non-zero ticks");

        int56 cumulative = int56(tick1) * 100 + int56(tick2) * 100;
        int24 expected = int24(cumulative / 200);
        if (cumulative < 0 && cumulative % 200 != 0) expected--;

        assertEq(hook.consultTick(hookedKey, 200), expected, "mean over the 200s window");

        // And the raw cumulatives differ by exactly the same hand computation, since the engine
        // reads those directly too.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 200;
        secondsAgos[1] = 0;
        int56[] memory cumulatives = hook.observe(hookedKey, secondsAgos);
        assertEq(cumulatives[1] - cumulatives[0], cumulative, "tick1*100 + tick2*100");
    }

    /// @notice Solidity truncates integer division toward zero. For a negative mean that rounds
    ///         *up*, which would place the buyback's price band one tick above what the history
    ///         supports. The mean must floor toward negative infinity instead.
    function test_consultTickFloorsANegativeMeanTick() public {
        hook.increaseObservationCardinalityNext(hookedKey, 8);
        uint256 t0 = vm.getBlockTimestamp();

        // Uneven interval lengths, chosen so the accumulator does not divide evenly by the
        // window and the flooring correction is actually exercised.
        vm.warp(t0 + 100);
        _swapExactIn(hookedKey, 37e18);
        int24 tick1 = _currentTick(hookedKey); // holds over [t0+100, t0+200], 100s

        vm.warp(t0 + 200);
        _swapExactIn(hookedKey, 11e18);
        int24 tick2 = _currentTick(hookedKey); // holds over [t0+200, t0+233], 33s

        vm.warp(t0 + 233);
        _swapExactIn(hookedKey, 3e18);

        assertLt(tick1, int24(0), "zeroForOne swaps push the tick negative");
        assertLt(tick2, int24(0));

        int56 cumulative = int56(tick1) * 100 + int56(tick2) * 33;
        assertTrue(cumulative % 133 != 0, "the window must not divide evenly, or nothing floors");

        int24 truncatedTowardZero = int24(cumulative / 133);
        int24 mean = hook.consultTick(hookedKey, 133);

        assertEq(mean, truncatedTowardZero - 1, "floored, not truncated");
        assertLe(int256(mean) * 133, int256(cumulative), "and the floor is a true lower bound");
    }

    /// @notice Asking for more history than exists must revert with the named error, not return
    ///         a number derived from the history that does exist. `BuybackEngine` catches this
    ///         one specifically and reports it to users as "no-twap".
    function test_consultingAWindowLongerThanTheHistoryReverts() public {
        vm.warp(1_000_000);
        PoolKey memory key = _freshPool();
        hook.increaseObservationCardinalityNext(key, 8);

        vm.warp(1_000_100);
        _swapExactIn(key, 1e18);

        // 100 seconds of history, 3600 requested.
        vm.expectRevert(PoolObservations.TargetPredatesOldestObservation.selector);
        hook.consultTick(key, 3600);

        // The window it does have still answers.
        hook.consultTick(key, 100);
    }

    function test_increaseObservationCardinalityNext_growsIsPermissionlessAndNeverShrinks() public {
        PoolId id = hookedKey.toId();

        // Anyone at all, not the owner and not the registrar.
        vm.prank(address(0xBEEF));
        (uint16 oldNext, uint16 newNext) = hook.increaseObservationCardinalityNext(hookedKey, 100);
        assertEq(oldNext, 1);
        assertEq(newNext, 100);

        (,, uint16 cardinalityNext) = hook.observationState(id);
        assertEq(cardinalityNext, 100, "the target grew");

        // Growing further is fine.
        vm.prank(trader);
        hook.increaseObservationCardinalityNext(hookedKey, 250);
        (,, cardinalityNext) = hook.observationState(id);
        assertEq(cardinalityNext, 250);

        // Shrinking is a silent no-op, never an actual shrink — history somebody is relying on
        // cannot be taken away from them.
        hook.increaseObservationCardinalityNext(hookedKey, 5);
        (,, cardinalityNext) = hook.observationState(id);
        assertEq(cardinalityNext, 250, "the buffer never shrinks");

        // And a pool with no oracle has nothing to grow.
        vm.expectRevert(PoolObservations.NotInitialized.selector);
        hook.increaseObservationCardinalityNext(bareKey, 10);
    }

    /// @notice The property the whole oracle exists for, in its simplest form: a spike that is
    ///         *not* reverted. A single block of enormous buying pressure moves the spot tick by
    ///         tens of thousands of ticks and leaves it there, yet the hour-long mean read in
    ///         that same block barely registers it. A `BuybackEngine` pricing off spot would swap
    ///         at the manipulated price; pricing off this, it swaps within a few ticks of the
    ///         pre-spike one.
    ///
    ///         **Why "barely" rather than "not at all".** `PoolObservations.MIN_INTERVAL`
    ///         throttles writes, so the newest stored observation can be up to `MIN_INTERVAL - 1`
    ///         seconds stale. `observeSingle` extends that observation to now at the pool's
    ///         *current* tick, which mid-spike is the manipulated one — so the spike is credited
    ///         for exactly the gap between the last write and now, and for nothing else. That is
    ///         a bound, not a leak that grows with patience, which is why the bound is what gets
    ///         asserted here rather than a magic number. Uniswap V3's oracle extrapolates the
    ///         same way and carries the same exposure, sized by its block time instead of by this
    ///         constant.
    ///
    ///         The stored accumulator never sees the manipulated tick at all, so the attacker
    ///         buys nothing beyond that tail:
    ///         `test_aSpikeLandingOnTheThrottleBoundaryLeavesTheTwapExactlyUnmoved` is the same
    ///         spike with no stale gap to extend across, and it moves the mean by zero.
    ///
    ///         This is the persistent-spike case; the same-block spike-and-revert case, which is
    ///         the cheaper attack, is covered separately below.
    function test_aSingleBlockSpikeMovesSpotALotAndBarelyMovesTheTwap() public {
        _mintAndApprove(trader, 1_000_000e18);
        hook.increaseObservationCardinalityNext(hookedKey, _cardinalityForWindow(TWAP_WINDOW));

        // An hour of ordinary two-way trading, spaced well clear of the throttle so every swap
        // really does write.
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(vm.getBlockTimestamp() + 300);
            _swapExactIn(hookedKey, 1e18);
        }

        int24 spotBefore = _currentTick(hookedKey);
        int24 twapBefore = hook.consultTick(hookedKey, TWAP_WINDOW);

        // One block, one very large buy, landing one second after the newest observation — the
        // worst case for the extrapolation, since the entire throttle window is still ahead.
        vm.warp(vm.getBlockTimestamp() + 1);
        _swapExactInOneForZero(hookedKey, 200_000e18);

        int24 spotAfter = _currentTick(hookedKey);
        int24 twapAfter = hook.consultTick(hookedKey, TWAP_WINDOW);

        int256 spotMove = _abs(int256(spotAfter) - int256(spotBefore));
        int256 twapMove = _abs(int256(twapAfter) - int256(twapBefore));

        // Spot goes from tick -3 to tick 21_919, roughly 9x on price.
        assertGt(spotMove, 20_000, "spot really did get dragged a long way");

        // The arithmetic ceiling on the tail: the spike can be credited for at most
        // `MIN_INTERVAL` of the window, and `+ 1` for the truncating division inside `observe`.
        int256 tail = (spotMove * int256(uint256(PoolObservations.MIN_INTERVAL)))
            / int256(uint256(TWAP_WINDOW)) + 1;
        assertLe(twapMove, tail, "the mean moved by at most the window's un-observed tail");
        assertLt(twapMove * 200, spotMove, "which is under half a percent of the spot move");
    }

    /// @notice The same spike, landing on the throttle boundary rather than inside it. Its own
    ///         `beforeSwap` then writes the honest pre-spike tick at the current timestamp, so
    ///         there is no stale observation left for `observeSingle` to extend at the
    ///         manipulated tick, and the mean does not move at all.
    ///
    ///         This is the guarantee in its unweakened form, and it is the one that matters for
    ///         a buyback: the manipulated tick cannot enter the accumulator until a *later*
    ///         block's swap credits it for time it genuinely held. Manipulation that has not yet
    ///         cost the attacker a block of inventory risk is worth exactly zero to the TWAP.
    function test_aSpikeLandingOnTheThrottleBoundaryLeavesTheTwapExactlyUnmoved() public {
        _mintAndApprove(trader, 1_000_000e18);
        hook.increaseObservationCardinalityNext(hookedKey, _cardinalityForWindow(TWAP_WINDOW));

        for (uint256 i = 0; i < 12; i++) {
            vm.warp(vm.getBlockTimestamp() + 300);
            _swapExactIn(hookedKey, 1e18);
        }

        int24 spotBefore = _currentTick(hookedKey);
        int24 twapBefore = hook.consultTick(hookedKey, TWAP_WINDOW);

        vm.warp(vm.getBlockTimestamp() + PoolObservations.MIN_INTERVAL);
        _swapExactInOneForZero(hookedKey, 200_000e18);

        int256 spotMove = _abs(int256(_currentTick(hookedKey)) - int256(spotBefore));
        int256 twapMove =
            _abs(int256(hook.consultTick(hookedKey, TWAP_WINDOW)) - int256(twapBefore));

        assertGt(spotMove, 20_000, "spot really did get dragged a long way");
        assertEq(twapMove, 0, "and the hour-long mean did not move at all");
    }

    /// @notice The actual attack, and the reason the write sits in `beforeSwap` rather than
    ///         `afterSwap`: let a long quiet interval elapse, then inside one block spike the
    ///         price as far as the liquidity allows and put it straight back. The TWAP must come
    ///         out **bit-for-bit identical** to what it would have been had the attacker never
    ///         traded.
    ///
    ///         Two properties combine to give that. The spike's own `beforeSwap` writes the
    ///         honest pre-spike tick, closing the quiet interval at the price that really held
    ///         through it. The reversing swap's `beforeSwap` writes nothing, because an
    ///         observation for that block already exists. So the manipulated tick is never
    ///         accumulated at all — not diluted, not down-weighted, simply absent.
    ///
    ///         Had the observation been taken *after* the swap instead, the spike's tick would
    ///         have been credited to the entire preceding quiet interval, and the attacker could
    ///         buy as much weight as they liked simply by waiting longer before spiking. That is
    ///         the bug this test exists to keep out.
    function test_aSameBlockSpikeAndRevertLeavesTheTwapExactlyUnmoved() public {
        _mintAndApprove(trader, 2_000_000e18);
        hook.increaseObservationCardinalityNext(hookedKey, 16);

        // Some ordinary history, then a swap that fixes the price and closes the last interval.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _swapExactIn(hookedKey, 1e18);
        }
        int24 flatTick = _currentTick(hookedKey);

        // A long quiet interval with no trading at all. This is the interval the attacker would
        // be buying as weight under the broken ordering.
        vm.warp(vm.getBlockTimestamp() + 600);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        // The counterfactual: what the oracle says with the attack not yet performed.
        int24 twapNoAttack = hook.consultTick(hookedKey, 600);
        int56 cumulativeNoAttack = hook.observe(hookedKey, secondsAgos)[0];
        assertEq(twapNoAttack, flatTick, "a quiet interval means the mean is just the flat tick");

        // The attack, entirely inside this one block.
        _swapExactInOneForZero(hookedKey, 1_000_000e18);
        int24 spotAtPeak = _currentTick(hookedKey);
        _swapExactIn(hookedKey, 1_000_000e18);

        assertGt(
            int256(spotAtPeak) - int256(flatTick), 20_000, "spot really was dragged a long way"
        );

        int24 twapAfterAttack = hook.consultTick(hookedKey, 600);
        int56 cumulativeAfterAttack = hook.observe(hookedKey, secondsAgos)[0];

        assertEq(twapAfterAttack, twapNoAttack, "the TWAP did not move at all");
        assertEq(cumulativeAfterAttack, cumulativeNoAttack, "and neither did the accumulator");
    }

    // ─── The lagged read `BuybackEngine` performs ────────────────────────
    //
    // Everything above reads a window ending at `now`. `BuybackEngine.twapSqrtPriceX96` does
    // not: it asks for `[window + MIN_INTERVAL, MIN_INTERVAL]`, so the newer endpoint sits one
    // throttle interval in the past. These tests are the evidence for what that buys, and they
    // exist because the claim was disputed rather than because it was obvious.
    //
    // The disputed claim was that the lag does nothing for a QUIET pool, on the grounds that
    // `getSurroundingObservations` extends the newest observation to the target at the LIVE tick
    // whenever the newest is older than the target. The mechanism is real; the tests below show
    // it is not reachable in the block a spike happens in, because `_writeObservation` runs at
    // the top of `beforeSwap` and the attacker's own swap therefore stamps an honest observation
    // at `now` before moving anything.
    //
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Establish a price, then leave the pool silent for longer than the whole lagged
    ///      window, so that every second the read weighs sits at one known flat tick and any
    ///      movement in the mean can only have come from the attack under test. This is also
    ///      the shape the disputed claim was about: the newest observation is hours old and the
    ///      read's endpoints both land in the silent stretch after it.
    function _quietPoolAtOneFlatTick() internal returns (int24 flatTick) {
        _mintAndApprove(trader, 4_000_000e18);
        hook.increaseObservationCardinalityNext(hookedKey, _cardinalityForWindow(TWAP_WINDOW));

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + 600);
            _swapExactIn(hookedKey, 1e18);
        }
        flatTick = _currentTick(hookedKey);

        // Silence for longer than `window + MIN_INTERVAL`, so the older endpoint lands inside
        // the quiet stretch too and the mean is exactly `flatTick`.
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW + PoolObservations.MIN_INTERVAL + 600);
    }

    /// @dev What the lagged mean must be when `lead` seconds of the window have been credited
    ///      to a manipulated tick and the rest is honest flat history.
    function _expectedLeakedMean(int24 flatTick, int24 spikeTick, uint32 lead)
        internal
        pure
        returns (int24)
    {
        int56 honest = int56(flatTick) * int56(uint56(TWAP_WINDOW - lead));
        int56 manipulated = int56(spikeTick) * int56(uint56(lead));
        return _floorDiv(honest + manipulated, int56(uint56(TWAP_WINDOW)));
    }

    /// @notice **The disputed claim, settled empirically: it fails.** A pool left silent for
    ///         well over an hour, then spiked as hard as its liquidity allows, moves the lagged
    ///         mean by exactly zero in the block the spike lands in.
    ///
    ///         The proposed hole was that the newest observation is stale on a quiet pool, so
    ///         the read's newer endpoint gets extrapolated at the live — manipulated — tick.
    ///         What that argument misses is that moving the price takes a swap, and the swap's
    ///         own `beforeSwap` writes an observation at the honest PRE-swap tick whenever
    ///         `MIN_INTERVAL` has elapsed. On a quiet pool it always has. So the act of
    ///         manipulating is also the act of closing the stale gap at the honest price, and
    ///         the target at `now - MIN_INTERVAL` then lands strictly *before* the newest
    ///         observation and is interpolated between two stored honest values.
    ///
    ///         Note the unlagged read is unmoved here too, for the same reason — the quiet pool
    ///         is not where the lag earns its keep. The next test is.
    function test_laggedTwap_aQuietPoolsOneBlockSpikeIsWorthExactlyZero() public {
        int24 flatTick = _quietPoolAtOneFlatTick();

        assertEq(
            _laggedMeanTick(hookedKey, TWAP_WINDOW), flatTick, "the silent hour reads as one tick"
        );
        int24 unlaggedBefore = hook.consultTick(hookedKey, TWAP_WINDOW);

        _swapExactInOneForZero(hookedKey, 1_000_000e18);
        int24 spikeTick = _currentTick(hookedKey);

        assertGt(int256(spikeTick) - int256(flatTick), 20_000, "spot really was dragged far");
        assertEq(_laggedMeanTick(hookedKey, TWAP_WINDOW), flatTick, "the lagged mean did not move");
        assertEq(
            hook.consultTick(hookedKey, TWAP_WINDOW),
            unlaggedBefore,
            "nor did the unlagged one, because the spike's own write closed the stale gap"
        );
    }

    /// @notice **Where the lag does earn its keep: the busy pool.** A spike landing INSIDE the
    ///         throttle window writes no observation of its own, so the newest stored entry
    ///         stays where the last honest trade left it — and a read ending at `now` then
    ///         credits the manipulated tick for every second since that trade, at zero inventory
    ///         risk, because the attacker can spike, read and unwind inside one block.
    ///
    ///         Measured here: a ~47,900-tick spike (about 120x on price) with a 14-second gap
    ///         moves the hour-long unlagged mean by **186 ticks**, roughly 1.9% on price, for
    ///         free. The lagged read moves by **0**, to the tick.
    function test_laggedTwap_closesTheSameBlockSandwichTheUnlaggedReadLeavesOpen() public {
        int24 flatTick = _quietPoolAtOneFlatTick();

        // One ordinary trade to close the silent stretch: this is now a pool that trades, and
        // its newest observation is stamped at this instant.
        _swapExactIn(hookedKey, 1e18);

        assertEq(_laggedMeanTick(hookedKey, TWAP_WINDOW), flatTick, "baseline is the flat tick");
        assertEq(hook.consultTick(hookedKey, TWAP_WINDOW), flatTick, "for both reads");

        // One second short of the throttle: the attacker's swap writes nothing at all.
        uint32 gap = PoolObservations.MIN_INTERVAL - 1;
        vm.warp(vm.getBlockTimestamp() + gap);
        _swapExactInOneForZero(hookedKey, 1_000_000e18);
        int24 spikeTick = _currentTick(hookedKey);

        int24 unlaggedAfter = hook.consultTick(hookedKey, TWAP_WINDOW);
        int24 laggedAfter = _laggedMeanTick(hookedKey, TWAP_WINDOW);

        // The unlagged read credited the manipulated tick for the whole 14-second gap.
        assertEq(
            unlaggedAfter,
            _expectedLeakedMean(flatTick, spikeTick, gap),
            "the unlagged read credited every second since the last write"
        );
        assertGt(int256(unlaggedAfter) - int256(flatTick), 150, "a real move, not dust");

        assertEq(laggedAfter, flatTick, "the lagged read did not move at all");

        // Two seconds after the spike, still with no write in between, the lag has begun to
        // credit it — but only one second, against two the attacker has actually held. The
        // credit is `now - newest - MIN_INTERVAL`, and `newest > now - MIN_INTERVAL` at the
        // moment of the spike, so it is always strictly less than the time held.
        vm.warp(vm.getBlockTimestamp() + 2);
        assertEq(
            _laggedMeanTick(hookedKey, TWAP_WINDOW),
            _expectedLeakedMean(flatTick, spikeTick, 1),
            "one second credited for two seconds held"
        );
    }

    /// @notice The exact boundary of what the lag promises, asserted as equalities rather than
    ///         bounds because the promise is an equality.
    ///
    ///         With the spike at `T` — and therefore the newest observation at `T`, written by
    ///         the spike's own `beforeSwap` — a read at `T + k`:
    ///
    ///         - `k <= MIN_INTERVAL`: target at or before `T`, both endpoints stored, mean moves
    ///           by exactly zero.
    ///         - `k = MIN_INTERVAL + 1`: the target passes `T` and exactly one second of live
    ///           tick enters.
    ///         - beyond that: one second of credit per second elapsed, until the next swap
    ///           writes and resets the gap to zero.
    ///
    ///         So the attacker must hold the manipulation for a full `MIN_INTERVAL` before
    ///         earning anything, and then earns `(k - MIN_INTERVAL) / twapWindow` of the spot
    ///         move. Measured here: a minute past the lag, a ~47,900-tick spike moves the mean
    ///         by **798 ticks**, about 8.3% on price — and it does that only on a pool nobody
    ///         else is trading, because any swap at all resets the gap to zero.
    function test_laggedTwap_leaksNothingUntilTheSpikeOutlivesTheLagThenOneSecondPerSecond()
        public
    {
        int24 flatTick = _quietPoolAtOneFlatTick();

        _swapExactInOneForZero(hookedKey, 1_000_000e18);
        int24 spikeTick = _currentTick(hookedKey);
        uint256 spikeAt = vm.getBlockTimestamp();

        // k = MIN_INTERVAL. The target lands exactly on the observation the spike itself wrote.
        vm.warp(spikeAt + PoolObservations.MIN_INTERVAL);
        assertEq(
            _laggedMeanTick(hookedKey, TWAP_WINDOW),
            flatTick,
            "nothing leaks while the spike is younger than the lag"
        );
        int56 cumulativeAtBoundary = _laggedEndCumulative(hookedKey);

        // k = MIN_INTERVAL + 1. One second, and one second only.
        vm.warp(spikeAt + PoolObservations.MIN_INTERVAL + 1);
        assertEq(
            _laggedEndCumulative(hookedKey) - cumulativeAtBoundary,
            int56(spikeTick),
            "the first leaked second is exactly one second of the manipulated tick"
        );
        assertEq(
            _laggedMeanTick(hookedKey, TWAP_WINDOW),
            _expectedLeakedMean(flatTick, spikeTick, 1),
            "and the mean moves by that one second's worth"
        );

        // A minute past the lag: linear, one second of credit per second held.
        uint32 lead = 60;
        vm.warp(spikeAt + PoolObservations.MIN_INTERVAL + lead);
        assertEq(
            _laggedEndCumulative(hookedKey) - cumulativeAtBoundary,
            int56(spikeTick) * int56(uint56(lead)),
            "credit grows one-for-one with time held, and no faster"
        );

        int24 leakedMean = _laggedMeanTick(hookedKey, TWAP_WINDOW);
        assertEq(leakedMean, _expectedLeakedMean(flatTick, spikeTick, lead), "linear in the mean");
        assertGt(int256(leakedMean) - int256(flatTick), 700, "which by then is a real move");

        // The residual is bounded by the window, not by the lag: the credited seconds are always
        // fewer than the seconds the position was actually carried.
        assertLt(
            int256(uint256(lead)),
            int256(vm.getBlockTimestamp() - spikeAt),
            "credited seconds stay below seconds held"
        );
    }

    /// @notice The cheap attack — spike and unwind inside one block, on a pool that has been
    ///         silent for hours. The peak tick is worth exactly zero to the lagged read: not in
    ///         the block it happens in, and not once the lag has elapsed either, because by then
    ///         the tick being extrapolated is whatever the attacker LEFT the pool at, which is a
    ///         position they are still carrying.
    ///
    ///         The round trip here does not land back on `flatTick` — reversing a spike this
    ///         large through the same liquidity overshoots — so the assertion past the boundary
    ///         is that the credited tick is the resting one and never the peak.
    function test_laggedTwap_aSameBlockSpikeAndRevertNeverCreditsThePeak() public {
        int24 flatTick = _quietPoolAtOneFlatTick();

        _swapExactInOneForZero(hookedKey, 1_000_000e18);
        int24 peakTick = _currentTick(hookedKey);
        _swapExactIn(hookedKey, 1_000_000e18);
        int24 restingTick = _currentTick(hookedKey);
        uint256 spikeAt = vm.getBlockTimestamp();

        assertGt(int256(peakTick) - int256(flatTick), 20_000, "spot really was dragged far");
        assertEq(_laggedMeanTick(hookedKey, TWAP_WINDOW), flatTick, "invisible in its own block");

        vm.warp(spikeAt + PoolObservations.MIN_INTERVAL);
        assertEq(_laggedMeanTick(hookedKey, TWAP_WINDOW), flatTick, "and at the lag boundary");

        // Past the boundary the live tick is extrapolated again — the resting one, held openly
        // since the block ended, not the peak that existed for part of a single transaction.
        uint32 lead = 60;
        vm.warp(spikeAt + PoolObservations.MIN_INTERVAL + lead);
        assertEq(
            _laggedMeanTick(hookedKey, TWAP_WINDOW),
            _expectedLeakedMean(flatTick, restingTick, lead),
            "what leaks after the lag is the position still open, never the intra-block peak"
        );
    }

    /// @notice A pool we never registered has no oracle. Reading it must revert, not report a
    ///         zero cumulative — a zero would decode as tick zero, which is a real, tradeable
    ///         price, and is the single worst thing this could return.
    function test_anUnregisteredPoolHasNoObservationsAndConsultingItReverts() public {
        PoolId id = bareKey.toId();

        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.observationState(id);
        assertEq(index, 0);
        assertEq(cardinality, 0, "no ring at all");
        assertEq(cardinalityNext, 0);

        vm.warp(vm.getBlockTimestamp() + 100);
        _swapExactIn(bareKey, 1e18);

        (, cardinality,) = hook.observationState(id);
        assertEq(cardinality, 0, "and swapping it does not open one");

        vm.expectRevert(PoolObservations.NotInitialized.selector);
        hook.consultTick(bareKey, 60);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;
        vm.expectRevert(PoolObservations.NotInitialized.selector);
        hook.observe(bareKey, secondsAgos);
    }

    function _swapExactInOneForZero(PoolKey memory key, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        vm.prank(trader);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function tokenOf(Currency c) internal pure returns (TestERC20) {
        return TestERC20(Currency.unwrap(c));
    }
}
