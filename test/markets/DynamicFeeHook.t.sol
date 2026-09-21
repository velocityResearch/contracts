// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

import {IProtocolGuard} from "../../src/upgrade/IProtocolGuard.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {PoolObservations} from "../../src/markets/PoolObservations.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev The exact state declaration of the deployed implementation (`0xd4AC6b17…`, upgraded
///      2026-09-19), used to prove that `feeKeeper` is appended below its last slot and that
///      an in-flight scheduled increase survives the upgrade untouched.
contract LegacyProtocolFeeHookLayout is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    IPoolManager public poolManager;
    IProtocolGuard public guard;
    address public registrar;
    mapping(PoolId => address) public feeRecipientOf;
    mapping(PoolId => uint24) public feePipsOf;
    mapping(PoolId => mapping(Currency => uint256)) public pendingFees;

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    mapping(PoolId => PoolObservations.Observation[65535]) internal observations;
    mapping(PoolId => ObservationState) internal observationStates;
    mapping(PoolId => uint24) public pendingFeePipsOf;
    mapping(PoolId => uint64) public feePipsEffectiveAt;

    constructor() {
        _disableInitializers();
    }

    function initialize(IPoolManager manager, address initialOwner, address protocolGuard)
        external
        initializer
    {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        poolManager = manager;
        guard = IProtocolGuard(protocolGuard);
    }

    function seedOriginalState(PoolId id, Currency currency, address recipient, uint24 skim)
        external
        onlyOwner
    {
        registrar = address(0xFAC7);
        feeRecipientOf[id] = recipient;
        feePipsOf[id] = skim;
        pendingFees[id][currency] = 123_456;
        observationStates[id] = ObservationState({index: 7, cardinality: 8, cardinalityNext: 16});
        observations[id][7] = PoolObservations.Observation({
            blockTimestamp: 42, tickCumulative: -321, initialized: true
        });
        pendingFeePipsOf[id] = 9_000;
        feePipsEffectiveAt[id] = 4_000_000_000;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

/// @title Stored dynamic LP fee integration against a genuine local Uniswap v4 PoolManager
contract DynamicFeeHookTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint24 internal constant PROTOCOL_FEE_PIPS = 1_000;
    int24 internal constant TICK_SPACING = 50;
    int128 internal constant LIQUIDITY = 100_000e18;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    ProtocolFeeHook internal hook;

    TestERC20 internal tokenA;
    TestERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal dynamicKey;
    PoolKey internal staticKey;
    /// @dev The pool's gross delta from the most recent `_swap`, before the hook's cut.
    BalanceDelta internal lastPoolDelta;

    address internal owner = address(0xD1A0);
    address internal registrar = address(0xFAC7);
    address internal recipient = address(0xFEE);
    address internal keeper = address(0xB0B);
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

        dynamicKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 5_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(dynamicKey, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(staticKey, TickMath.getSqrtPriceAtTick(0));
        vm.startPrank(registrar);
        hook.registerPool(dynamicKey, recipient, PROTOCOL_FEE_PIPS);
        hook.registerPool(staticKey, recipient, PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        _mintAndApprove(address(this), 2_000_000e18);
        _addLiquidity(dynamicKey);
        _addLiquidity(staticKey);
        _mintAndApprove(trader, 2_000_000e18);
    }

    function test_registrationSeedsNativeDynamicFeeAndLeavesStaticTierUnchanged() public view {
        assertEq(_storedFee(dynamicKey), 5_000, "dynamic pool seeded in native slot0");
        assertEq(_storedFee(staticKey), 5_000, "static pool retained its PoolKey fee");
        assertEq(hook.feeRecipientOf(dynamicKey.toId()), recipient);
        assertEq(hook.feePipsOf(dynamicKey.toId()), PROTOCOL_FEE_PIPS);
    }

    function test_ownerAuthorizesKeeperOwnerCanUpdateAndZeroRevokes() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit ProtocolFeeHook.FeeKeeperUpdated(keeper);
        vm.prank(owner);
        hook.setFeeKeeper(keeper);
        assertEq(hook.feeKeeper(), keeper);

        vm.expectEmit(true, false, false, true, address(hook));
        emit ProtocolFeeHook.PoolLpFeeUpdated(dynamicKey.toId(), 12_345);
        vm.prank(keeper);
        hook.setPoolLpFee(dynamicKey, 12_345);
        assertEq(_storedFee(dynamicKey), 12_345, "keeper writes PoolManager slot0");

        vm.prank(owner);
        hook.setPoolLpFee(dynamicKey, 23_456);
        assertEq(_storedFee(dynamicKey), 23_456, "owner retains direct fee control");

        vm.prank(owner);
        hook.setFeeKeeper(address(0));
        assertEq(hook.feeKeeper(), address(0), "zero revokes keeper");

        vm.prank(keeper);
        vm.expectRevert(ProtocolFeeHook.OnlyFeeSetter.selector);
        hook.setPoolLpFee(dynamicKey, 10_000);
        assertEq(_storedFee(dynamicKey), 23_456, "revoked keeper cannot mutate fee");
    }

    function test_lpFeeBoundsAreInclusiveThroughFiftyThousand() public {
        vm.startPrank(owner);
        hook.setPoolLpFee(dynamicKey, 100);
        assertEq(_storedFee(dynamicKey), 100, "minimum is accepted");
        hook.setPoolLpFee(dynamicKey, 50_000);
        assertEq(_storedFee(dynamicKey), 50_000, "maximum is accepted");

        vm.expectRevert(ProtocolFeeHook.InvalidLpFee.selector);
        hook.setPoolLpFee(dynamicKey, 99);
        vm.expectRevert(ProtocolFeeHook.InvalidLpFee.selector);
        hook.setPoolLpFee(dynamicKey, 50_001);
        vm.stopPrank();

        assertEq(_storedFee(dynamicKey), 50_000, "invalid updates leave last fee intact");
    }

    function test_feeSetterRejectsWrongHookStaticAndUnregisteredExactKey() public {
        PoolKey memory wrongHook = dynamicKey;
        wrongHook.hooks = IHooks(address(0x1234));
        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.HookMismatch.selector);
        hook.setPoolLpFee(wrongHook, 5_000);

        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.NotDynamicPool.selector);
        hook.setPoolLpFee(staticKey, 5_000);

        PoolKey memory unregistered = dynamicKey;
        unregistered.tickSpacing = 100;
        vm.prank(owner);
        vm.expectRevert(ProtocolFeeHook.NotRegistered.selector);
        hook.setPoolLpFee(unregistered, 5_000);
    }

    function test_keeperCannotChangeSkimRegistrarOwnershipKeeperOrImplementation() public {
        vm.prank(owner);
        hook.setFeeKeeper(keeper);

        vm.prank(keeper);
        vm.expectRevert();
        hook.setPoolFeePips(dynamicKey.toId(), 0);

        vm.prank(keeper);
        vm.expectRevert();
        hook.setRegistrar(keeper);

        vm.prank(keeper);
        vm.expectRevert();
        hook.setFeeKeeper(address(0));

        vm.prank(keeper);
        vm.expectRevert();
        hook.transferOwnership(keeper);

        ProtocolFeeHook freshImplementation = new ProtocolFeeHook();
        vm.prank(keeper);
        vm.expectRevert();
        hook.upgradeToAndCall(address(freshImplementation), "");

        vm.prank(keeper);
        hook.setPoolLpFee(dynamicKey, 7_500);
        assertEq(_storedFee(dynamicKey), 7_500, "keeper authority is limited to LP fee writes");
        assertEq(hook.registrar(), registrar);
        assertEq(hook.owner(), owner);
        assertEq(hook.feePipsOf(dynamicKey.toId()), PROTOCOL_FEE_PIPS);
    }

    function test_exactInputAndOutputUseOneStoredFeeAndKeepProtocolSkimSeparate() public {
        vm.prank(owner);
        hook.setPoolLpFee(dynamicKey, 12_000);
        (uint256 growth0Before, uint256 growth1Before) =
            IPoolManager(address(manager)).getFeeGrowthGlobals(dynamicKey.toId());

        // The skim is charged on the UNSPECIFIED leg of what the pool moved: the output of an
        // exact-input swap, the input of an exact-output one. Expected from the pool's own
        // Swap event, which is the gross amount before the hook's cut.
        _assertSwap(dynamicKey, true, -int256(100e18), 12_000);
        uint256 expected1 = _skimOf(uint256(int256(lastPoolDelta.amount1())));
        _assertSwap(dynamicKey, false, -int256(100e18), 12_000);
        uint256 expected0 = _skimOf(uint256(int256(lastPoolDelta.amount0())));
        assertEq(hook.pendingFees(dynamicKey.toId(), currency0), expected0);
        assertEq(hook.pendingFees(dynamicKey.toId(), currency1), expected1);

        _assertSwap(dynamicKey, true, int256(10e18), 12_000);
        expected0 += _skimOf(uint256(-int256(lastPoolDelta.amount0())));
        _assertSwap(dynamicKey, false, int256(10e18), 12_000);
        expected1 += _skimOf(uint256(-int256(lastPoolDelta.amount1())));

        uint256 claim0 = hook.pendingFees(dynamicKey.toId(), currency0);
        uint256 claim1 = hook.pendingFees(dynamicKey.toId(), currency1);
        assertEq(claim0, expected0, "exact output skims the currency0 input");
        assertEq(claim1, expected1, "exact output skims the currency1 input");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), claim0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), claim1);

        (uint256 growth0After, uint256 growth1After) =
            IPoolManager(address(manager)).getFeeGrowthGlobals(dynamicKey.toId());
        assertGt(growth0After, growth0Before, "LPs accrue currency0 independently");
        assertGt(growth1After, growth1Before, "LPs accrue currency1 independently");

        uint256 recipient0Before = tokenOf(currency0).balanceOf(recipient);
        uint256 recipient1Before = tokenOf(currency1).balanceOf(recipient);
        hook.collect(dynamicKey);
        assertEq(tokenOf(currency0).balanceOf(recipient) - recipient0Before, claim0);
        assertEq(tokenOf(currency1).balanceOf(recipient) - recipient1Before, claim1);
        assertEq(hook.pendingFees(dynamicKey.toId(), currency0), 0);
        assertEq(hook.pendingFees(dynamicKey.toId(), currency1), 0);
    }

    function test_storedFeePersistsAcrossTimeAndStaticExecutionNeverChanges() public {
        vm.prank(owner);
        hook.setPoolLpFee(dynamicKey, 33_333);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        assertEq(_storedFee(dynamicKey), 33_333, "no expiry or time fallback exists");
        assertEq(_storedFee(staticKey), 5_000, "dynamic update cannot touch static pool");
        (, uint24 dynamic0) = _swap(dynamicKey, true, -int256(10e18));
        (, uint24 dynamic1) = _swap(dynamicKey, false, -int256(10e18));
        (, uint24 static0) = _swap(staticKey, true, -int256(10e18));
        (, uint24 static1) = _swap(staticKey, false, -int256(10e18));
        assertEq(dynamic0, 33_333);
        assertEq(dynamic1, 33_333);
        assertEq(static0, 5_000);
        assertEq(static1, 5_000);
    }

    function test_oracleContinuesAndAllLiquidityCanExitAfterFeeUpdates() public {
        hook.increaseObservationCardinalityNext(dynamicKey, 8);
        vm.prank(owner);
        hook.setPoolLpFee(dynamicKey, 50_000);

        vm.warp(vm.getBlockTimestamp() + PoolObservations.MIN_INTERVAL);
        _swap(dynamicKey, true, -int256(10e18));
        (uint16 indexBefore, uint16 cardinalityBefore,) = hook.observationState(dynamicKey.toId());
        vm.warp(vm.getBlockTimestamp() + PoolObservations.MIN_INTERVAL);
        _swap(dynamicKey, false, -int256(10e18));
        (uint16 indexAfter, uint16 cardinalityAfter,) = hook.observationState(dynamicKey.toId());
        assertTrue(indexAfter != indexBefore, "oracle cursor advances normally");
        assertGe(cardinalityAfter, cardinalityBefore, "fee writes do not reset history");

        uint256 balance0Before = tokenOf(currency0).balanceOf(address(this));
        uint256 balance1Before = tokenOf(currency1).balanceOf(address(this));
        lpRouter.modifyLiquidity(
            dynamicKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 1_000,
                tickUpper: TICK_SPACING * 1_000,
                liquidityDelta: -LIQUIDITY,
                salt: bytes32(0)
            }),
            ""
        );
        assertEq(
            IPoolManager(address(manager)).getLiquidity(dynamicKey.toId()),
            0,
            "all dynamic liquidity remains withdrawable"
        );
        assertTrue(
            tokenOf(currency0).balanceOf(address(this)) > balance0Before
                || tokenOf(currency1).balanceOf(address(this)) > balance1Before,
            "withdrawal returned real tokens"
        );
        (,, uint16 cardinalityNext) = hook.observationState(dynamicKey.toId());
        assertEq(cardinalityNext, 8, "withdrawal leaves oracle storage intact");
    }

    function test_upgradeFromExactDeployedLayoutPreservesEveryOriginalSlot() public {
        address legacyProxy = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0xD3F0 << 144)
        );
        LegacyProtocolFeeHookLayout legacyImplementation = new LegacyProtocolFeeHookLayout();
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(legacyImplementation),
                abi.encodeCall(
                    LegacyProtocolFeeHookLayout.initialize,
                    (IPoolManager(address(manager)), owner, address(protocolGuard))
                )
            ),
            legacyProxy
        );

        LegacyProtocolFeeHookLayout legacy = LegacyProtocolFeeHookLayout(legacyProxy);
        PoolId id = dynamicKey.toId();
        vm.prank(owner);
        legacy.seedOriginalState(id, currency0, recipient, PROTOCOL_FEE_PIPS);

        ProtocolFeeHook freshImplementation = new ProtocolFeeHook();
        vm.prank(owner);
        legacy.upgradeToAndCall(address(freshImplementation), "");
        ProtocolFeeHook upgraded = ProtocolFeeHook(legacyProxy);

        assertEq(address(upgraded.poolManager()), address(manager));
        assertEq(address(upgraded.guard()), address(protocolGuard));
        assertEq(upgraded.registrar(), registrar);
        assertEq(upgraded.feeRecipientOf(id), recipient);
        assertEq(upgraded.feePipsOf(id), PROTOCOL_FEE_PIPS);
        assertEq(upgraded.pendingFees(id, currency0), 123_456);
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = upgraded.observationState(id);
        assertEq(index, 7);
        assertEq(cardinality, 8);
        assertEq(cardinalityNext, 16);
        (uint32 timestamp, int56 cumulative, bool initialized) = upgraded.getObservation(id, 7);
        assertEq(timestamp, 42);
        assertEq(cumulative, -321);
        assertTrue(initialized);
        assertEq(upgraded.pendingFeePipsOf(id), 9_000, "scheduled increase preserved");
        assertEq(upgraded.feePipsEffectiveAt(id), 4_000_000_000, "its effective time preserved");
        assertEq(upgraded.feeKeeper(), address(0), "new appended slot starts empty");

        vm.prank(owner);
        upgraded.setFeeKeeper(keeper);
        assertEq(upgraded.feeKeeper(), keeper);
        assertEq(upgraded.pendingFees(id, currency0), 123_456, "append does not overlap claims");
        assertEq(upgraded.feePipsEffectiveAt(id), 4_000_000_000, "append does not overlap schedule");
        (index, cardinality, cardinalityNext) = upgraded.observationState(id);
        assertEq(index, 7);
        assertEq(cardinality, 8);
        assertEq(cardinalityNext, 16, "append does not overlap oracle cursor");
    }

    function test_proxyUpgradePreservesLiveStateKeeperAndNativePoolFee() public {
        vm.prank(owner);
        hook.setFeeKeeper(keeper);
        vm.prank(keeper);
        hook.setPoolLpFee(dynamicKey, 17_500);
        _swap(dynamicKey, true, -int256(100e18));
        hook.increaseObservationCardinalityNext(dynamicKey, 16);

        PoolId id = dynamicKey.toId();
        uint256 accrued = hook.pendingFees(id, currency0);
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.observationState(id);
        address poolManagerBefore = address(hook.poolManager());
        address guardBefore = address(hook.guard());

        ProtocolFeeHook freshImplementation = new ProtocolFeeHook();
        vm.prank(owner);
        hook.upgradeToAndCall(address(freshImplementation), "");

        assertEq(address(hook.poolManager()), poolManagerBefore, "manager slot preserved");
        assertEq(address(hook.guard()), guardBefore, "guard slot preserved");
        assertEq(hook.registrar(), registrar, "registrar slot preserved");
        assertEq(hook.feeRecipientOf(id), recipient, "recipient map preserved");
        assertEq(hook.feePipsOf(id), PROTOCOL_FEE_PIPS, "skim map preserved");
        assertEq(hook.pendingFees(id, currency0), accrued, "claims map preserved");
        (uint16 nextIndex, uint16 nextCardinality, uint16 nextCardinalityNext) =
            hook.observationState(id);
        assertEq(nextIndex, index, "oracle cursor preserved");
        assertEq(nextCardinality, cardinality, "oracle population preserved");
        assertEq(nextCardinalityNext, cardinalityNext, "oracle target preserved");
        assertEq(hook.feeKeeper(), keeper, "appended keeper slot preserved");
        assertEq(_storedFee(dynamicKey), 17_500, "PoolManager-owned fee persists across upgrade");

        (, uint24 executedFee) = _swap(dynamicKey, true, -int256(10e18));
        assertEq(executedFee, 17_500, "pool remains executable after upgrade");
    }

    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0xD1F0 << 144)
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
                tickLower: -TICK_SPACING * 1_000,
                tickUpper: TICK_SPACING * 1_000,
                liquidityDelta: LIQUIDITY,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, uint24 eventFee)
    {
        vm.recordLogs();
        vm.prank(trader);
        delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (int128 pool0, int128 pool1, uint24 fee) = _poolSwap(vm.getRecordedLogs(), key.toId());
        lastPoolDelta = toBalanceDelta(pool0, pool1);
        eventFee = fee;
    }

    function _assertSwap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint24 expectedFee
    ) internal {
        (BalanceDelta delta, uint24 eventFee) = _swap(key, zeroForOne, amountSpecified);
        assertEq(eventFee, expectedFee);
        _assertDirection(delta, zeroForOne);
    }

    function _storedFee(PoolKey memory key) internal view returns (uint24 lpFee) {
        (,,, lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function _skimOf(uint256 gross) internal view returns (uint256) {
        return gross * PROTOCOL_FEE_PIPS / hook.PIPS_DENOMINATOR();
    }

    /// @dev The pool's Swap event: the gross amounts before the hook's afterSwap cut, and the
    ///      LP fee the pool charged.
    function _poolSwap(Vm.Log[] memory logs, PoolId expectedId)
        internal
        view
        returns (int128 amount0, int128 amount1, uint24 fee)
    {
        bytes32 rawId = PoolId.unwrap(expectedId);
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (
                entry.emitter == address(manager) && entry.topics.length == 3
                    && entry.topics[0] == SWAP_TOPIC && entry.topics[1] == rawId
            ) {
                (amount0, amount1,,,, fee) = abi.decode(
                    entry.data, (int128, int128, uint160, uint128, int24, uint24)
                );
                return (amount0, amount1, fee);
            }
        }
        revert("Swap event not found");
    }

    function _assertDirection(BalanceDelta delta, bool zeroForOne) internal pure {
        if (zeroForOne) {
            assertLt(delta.amount0(), 0, "currency0 is input");
            assertGt(delta.amount1(), 0, "currency1 is output");
        } else {
            assertLt(delta.amount1(), 0, "currency1 is input");
            assertGt(delta.amount0(), 0, "currency0 is output");
        }
    }

    function tokenOf(Currency currency) internal pure returns (TestERC20) {
        return TestERC20(Currency.unwrap(currency));
    }
}
