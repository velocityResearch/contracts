// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @title KyberAdapterParityMainnetForkTest
/// @notice Proves the KyberSwap dex-lib adapter's fee model against the LIVE `ProtocolFeeHook`,
///         swap by swap, on a fork of Robinhood Chain.
///
/// @dev    **Why this suite exists.** The adapter at
///         `kyberswap-dex-lib`, `pkg/liquidity-source/uniswap/v4/hooks/stables` reimplements
///         this hook's arithmetic in Go, inside Kyber's router, where it cannot see this repo.
///         Its whole contract with us is three claims, and each one is an assertion below:
///
///         1. `beforeSwap` charges NOTHING, in either direction. The Go adapter returns a zero
///            `DeltaSpecified` and a zero `DeltaUnspecified` unconditionally. If the contract
///            ever charged there again, every Kyber quote would be short by one fee.
///         2. The fee lands on the UNSPECIFIED leg — the OUTPUT of an exact-input swap, the
///            realised INPUT of an exact-output one — and equals `floor(base·pips/1e6)` on the
///            pool's own raw amount. This is `AfterSwapResult.HookFee`, whose dex-lib contract
///            is "CalcOut: out -= hook fee; CalcIn: in += hook fee".
///         3. A partial fill is charged on the FILL. This is the property that moving the skim
///            out of `beforeSwap` bought, and an aggregator passing its own
///            `sqrtPriceLimitX96` is exactly the caller that reaches it.
///
///         An adapter that got any of these wrong would still compile, still pass its own Go
///         unit tests, and quietly misprice every route through these pools. Only a real swap
///         against the real hook can tell the difference, which is why this is a fork test and
///         not another mock.
///
///         **Read the fee from `pendingFees`, not from the delta.** The hook's cut is folded
///         into the `BalanceDelta` that `PoolManager.swap` returns, so the delta reports the
///         NET amount and cannot show the fee on its own. `pendingFees[poolId][currency]` is
///         the hook's own ledger and moves by exactly the amount charged.
///
///         **Not pinned to a block, deliberately.** This chain's public RPC prunes state to
///         minutes of history, so a pinned block stops answering almost immediately. The suite
///         resolves everything — market id, pool key, live rate — from chain at head, and skips
///         rather than fails when a market has no liquidity to swap against.
///
///         Run with:
///         forge test --match-contract KyberAdapterParityMainnetFork -vvv --fork-url https://rpc.mainnet.chain.robinhood.com
contract KyberAdapterParityMainnetForkTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice `PIPS_DENOMINATOR` on the hook: 1e6 = 100%.
    uint256 constant PIPS = 1_000_000;

    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    address constant HOOK = 0xc9932584c5154e4F58313a2e5423522E74e540Cc;

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    AssetMarketFactory constant MARKETS = AssetMarketFactory(FACTORY);
    ProtocolFeeHook constant FEE_HOOK = ProtocolFeeHook(HOOK);

    /// @notice A live market with liquidity, resolved in `setUp`. Never hard-coded: retiring
    ///         and relisting a pair mints a new id.
    uint256 marketId;
    PoolKey key;
    PoolId poolId;
    uint24 feePips;

    function setUp() public {
        // The hook's address carries its permissions in the low 14 bits, so this also
        // confirms the fork is pointed at a chain where the stack actually exists.
        require(HOOK.code.length > 0, "no hook on this fork");

        uint256 count = MARKETS.marketCount();
        for (uint256 id = count; id >= 1; id--) {
            PoolKey memory candidate = MARKETS.poolKeyOf(id);
            PoolId candidateId = candidate.toId();
            if (address(candidate.hooks) != HOOK) continue;
            if (MANAGER.getLiquidity(candidateId) == 0) continue;
            if (FEE_HOOK.feePipsFor(candidateId) == 0) continue;

            marketId = id;
            key = candidate;
            poolId = candidateId;
            feePips = FEE_HOOK.feePipsFor(candidateId);
            break;
        }

        vm.skip(marketId == 0);
        console.log("market", marketId, "feePips", feePips);
    }

    // ─── Claim 1: beforeSwap charges nothing ─────────────────────────────

    /// @notice The adapter returns a zero `BeforeSwapResult` in both directions. Prove the
    ///         contract does too, by showing the ONLY currency whose fee ledger moves is the
    ///         unspecified one — an input-side skim would move the other.
    function test_beforeSwapChargesNothing_soOnlyTheUnspecifiedLegAccrues() public {
        // Exact-IN, selling currency0. Specified leg is currency0 (the input); an old-style
        // beforeSwap skim would have accrued there.
        uint256 in0Before = FEE_HOOK.pendingFees(poolId, key.currency0);
        uint256 in1Before = FEE_HOOK.pendingFees(poolId, key.currency1);

        _swap(true, -int256(_probe(key.currency0)), false);

        assertEq(
            FEE_HOOK.pendingFees(poolId, key.currency0),
            in0Before,
            "exact-in accrued on the INPUT leg: beforeSwap is charging again"
        );
        assertGt(
            FEE_HOOK.pendingFees(poolId, key.currency1),
            in1Before,
            "exact-in did not accrue on the OUTPUT leg"
        );
    }

    // ─── Claim 2: the fee is floor(base*pips/1e6) on the unspecified leg ──

    /// @notice Exact-input. The adapter computes `HookFee` from `params.AmountOut` — the
    ///         pool's raw output — and subtracts it. Assert the identity that makes that
    ///         correct: `fee == floor((received + fee) * pips / 1e6)`.
    function test_exactIn_feeIsFlooredPipsOfTheRawOutput() public {
        uint256 accruedBefore = FEE_HOOK.pendingFees(poolId, key.currency1);

        (, int128 out) = _swap(true, -int256(_probe(key.currency0)), false);
        uint256 received = uint256(uint128(out));

        uint256 fee = FEE_HOOK.pendingFees(poolId, key.currency1) - accruedBefore;
        uint256 gross = received + fee;

        assertEq(fee, (gross * feePips) / PIPS, "not floor(grossOut * pips / 1e6)");
        console.log("exact-in  gross", gross, "fee", fee);
    }

    /// @notice Exact-output. The adapter computes `HookFee` from `params.AmountIn` and ADDS
    ///         it. Assert the same flooring on the realised input.
    function test_exactOut_feeIsFlooredPipsOfTheRealisedInput() public {
        uint256 accruedBefore = FEE_HOOK.pendingFees(poolId, key.currency0);

        // Ask for a fixed amount of currency1 out, paying currency0 in.
        (int128 spent,) = _swap(true, int256(_probe(key.currency1) / 100), false);
        uint256 paid = uint256(uint128(-spent));

        uint256 fee = FEE_HOOK.pendingFees(poolId, key.currency0) - accruedBefore;
        uint256 net = paid - fee;

        assertEq(fee, (net * feePips) / PIPS, "not floor(netIn * pips / 1e6)");

        // And it is FLAT, not a gross-up. An inverted path would have charged
        // net*pips/(1e6-pips), which is strictly larger for any non-zero rate.
        uint256 grossedUp = (net * feePips) / (PIPS - feePips);
        assertLt(fee, grossedUp, "exact-out was grossed up; the adapter models it flat");
        console.log("exact-out net", net, "fee", fee);
        console.log("gross-up would have been", grossedUp);
    }

    // ─── Claim 3: a partial fill is charged on the fill ──────────────────

    /// @notice Bind `sqrtPriceLimitX96` so the swap cannot fill what it asked for. The fee
    ///         must follow what actually moved. Under the pre-2026-09-19 `beforeSwap` skim
    ///         this charged the full request, which is the bug the adapter must not re-import.
    function test_partialFill_isChargedOnTheFillNotTheRequest() public {
        uint256 accruedBefore = FEE_HOOK.pendingFees(poolId, key.currency1);

        uint256 requested = _probe(key.currency0) * 50;
        (int128 spent, int128 out) = _swap(true, -int256(requested), true);

        uint256 filled = uint256(uint128(-spent));
        uint256 received = uint256(uint128(out));
        uint256 fee = FEE_HOOK.pendingFees(poolId, key.currency1) - accruedBefore;

        assertLt(filled, requested, "the price limit did not bind; nothing was proven");
        assertEq(fee, ((received + fee) * feePips) / PIPS, "fee is not on the realised output");

        // The decisive comparison: what an input-side skim on the REQUEST would have taken.
        assertLt(
            fee, (requested * feePips) / PIPS, "fee is as large as a skim on the unfilled request"
        );
        console.log("requested", requested, "filled", filled);
        console.log("fee on the fill", fee);
    }

    // ─── Harness ─────────────────────────────────────────────────────────

    /// @dev A swap size small enough to fill against live depth: one ten-thousandth of the
    ///      pool's balance of that currency, floored at one unit.
    function _probe(Currency currency) internal view returns (uint256) {
        uint256 held = IERC20(Currency.unwrap(currency)).balanceOf(address(MANAGER));
        uint256 size = held / 10_000;
        return size == 0 ? 1 : size;
    }

    bool private bindLimit;

    function _swap(bool zeroForOne, int256 amountSpecified, bool binding)
        internal
        returns (int128 amount0, int128 amount1)
    {
        bindLimit = binding;

        // Fund both legs: an exact-output swap discovers its input only as it runs.
        deal(Currency.unwrap(key.currency0), address(this), type(uint128).max);
        deal(Currency.unwrap(key.currency1), address(this), type(uint128).max);

        bytes memory result = MANAGER.unlock(abi.encode(zeroForOne, amountSpecified));
        return abi.decode(result, (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "only the manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));

        uint160 limit;
        if (bindLimit) {
            // A limit a short distance from spot, so the swap fills part of the request and
            // stops. `getSlot0` is the live price at head.
            (uint160 spot,,,) = MANAGER.getSlot0(poolId);
            limit = zeroForOne ? spot - (spot / 1000) : spot + (spot / 1000);
        } else {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        BalanceDelta delta = MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta.amount0(), delta.amount1());
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency))
                .safeTransfer(address(MANAGER), uint256(uint128(-amount)));
            MANAGER.settle();
        } else if (amount > 0) {
            MANAGER.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
