// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketLens} from "../../src/markets/MarketLens.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {IV4Quoter} from "../helpers/IV4Quoter.sol";

/// @title MarketLensSimulatorForkTest
/// @notice Uniswap's deployed, unmodified `V4Quoter` is the reference; `MarketLens`'s `view`
///         simulation is the thing under test. Every number below is asked of both against
///         the SAME live pool at the SAME block, and any disagreement is our bug.
///
/// @dev    **Why this cannot be proven offline.** `test/markets/MarketLens.t.sol` already
///         asserts the stronger property — that a quote equals the fill the router actually
///         delivers — but it does so against a pool this repo built, seeded and shaped. What
///         it cannot show is that the simulation tracks *these six pools*: their live tick
///         layout, their live `slot0` (protocol fee included), the hook implementation that is
///         actually behind the proxy today, and whatever liquidity strangers have added. A
///         copy of `Pool.swap` is only as good as the state it reads, and the state is here.
///
///         **What a failure means.** Three candidates, in order of likelihood: someone added
///         a concentrated position and the bitmap walk is wrong; core's `Pool.swap` changed
///         under a new `PoolManager` and the copy in `V4SwapSimulator` drifted; or the hook's
///         fee rule moved off the unspecified leg. All three are silent in the offline suite.
///
///         The lens is deployed fresh from local source rather than read from the manifest,
///         on purpose: the point is to test THIS source against the live chain, and the
///         currently deployed lens predates the simulator.
///
///         Run with:
///         forge test --match-contract MarketLensSimulatorFork -vvv --fork-url https://rpc.mainnet.chain.robinhood.com
contract MarketLensSimulatorForkTest is Test {
    /// @notice The live gen-6 `AssetMarketFactory` proxy.
    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    /// @notice The live `MarketRouter` proxy, for `marketLiquidity`.
    address constant ROUTER = 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4;
    /// @notice Uniswap's `V4Quoter`, deployed unmodified from `lib/v4-periphery` by
    ///         `script/deploy-v4-lens.sh`. The reference this suite measures against.
    address constant V4_QUOTER = 0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F;

    AssetMarketFactory factory;
    MarketRouter router;
    IV4Quoter quoter;
    MarketLens lens;

    /// @dev Reserve-asset sizes, 6-decimal USDG: 1, 10, 100, 1,000. The top of the ladder is
    ///      past the point where these pools fill well — which is the interesting case, not a
    ///      problem: a quote that disagrees with the reference only at depth is exactly the
    ///      bug an easy ladder would miss.
    uint256[4] LADDER = [uint256(1e6), 10e6, 100e6, 1_000e6];

    function setUp() public {
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        factory = AssetMarketFactory(FACTORY);
        router = MarketRouter(payable(ROUTER));
        quoter = IV4Quoter(V4_QUOTER);
        lens = new MarketLens(factory);

        assertEq(
            address(lens.poolManager()),
            MainnetAddresses.POOL_MANAGER,
            "the lens must read the canonical singleton off the factory"
        );
    }

    /// @notice Buy side: the lens's whole-route figure is the v4 leg exactly, because the mint
    ///         leg is 1:1. So it must equal the stock quoter's `amountOut` to the base unit.
    function test_fork_buyQuotesMatchTheDeployedV4Quoter() public {
        uint256 compared;

        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            if (router.marketLiquidity(id) == 0) continue;

            AssetMarketFactory.Market memory m = factory.market(id);
            PoolKey memory key = factory.poolKeyOf(id);

            for (uint256 i; i < LADDER.length; ++i) {
                uint256 amountIn = LADDER[i];

                (uint256 expected,) = quoter.quoteExactInputSingle(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: m.brandToken == Currency.unwrap(key.currency0),
                        exactAmount: uint128(amountIn),
                        hookData: ""
                    })
                );

                (uint256 simulated,) = lens.quoteBuy(id, amountIn);

                assertEq(simulated, expected, "buy quote must equal Uniswap's own");
                ++compared;
            }
        }

        assertGt(compared, 0, "no live market answered; the fork or the stack is wrong");
        console.log("buy quotes compared", compared);
    }

    /// @notice Sell side: `quoteSell` reports the swap's brand output separately, and that is
    ///         the figure the quoter produces. The USDG figure is that number less the
    ///         reserve's redemption fee, which this also checks so a lens that quoted the v4
    ///         leg correctly and then mispriced the reserve leg still fails.
    function test_fork_sellQuotesMatchTheDeployedV4Quoter() public {
        uint256 compared;

        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            if (router.marketLiquidity(id) == 0) continue;

            AssetMarketFactory.Market memory m = factory.market(id);
            PoolKey memory key = factory.poolKeyOf(id);
            uint16 redemptionFeeBps = lens.reserveOf(id).redemptionFeeBps();

            for (uint256 i; i < LADDER.length; ++i) {
                // Size the sell off a buy of the same notional, so every rung is a real
                // round trip rather than an arbitrary asset amount on an 18-decimal token
                // whose price we do not know here.
                (uint256 assetIn,) = lens.quoteBuy(id, LADDER[i]);
                if (assetIn == 0) continue;

                (uint256 expected,) = quoter.quoteExactInputSingle(
                    IV4Quoter.QuoteExactSingleParams({
                        poolKey: key,
                        zeroForOne: m.asset == Currency.unwrap(key.currency0),
                        exactAmount: uint128(assetIn),
                        hookData: ""
                    })
                );

                (uint256 usdgOut, uint256 brandOut,) = lens.quoteSell(id, assetIn);

                assertEq(brandOut, expected, "sell quote must equal Uniswap's own");
                assertEq(
                    usdgOut,
                    brandOut - brandOut * redemptionFeeBps / 10_000,
                    "the reserve leg is par less the redemption fee"
                );
                ++compared;
            }
        }

        assertGt(compared, 0, "no live market answered; the fork or the stack is wrong");
        console.log("sell quotes compared", compared);
    }

    /// @notice The exact-out inversion, checked against the property it claims rather than
    ///         against the quoter: the input it names must, put back through an exact-input
    ///         quote, clear the target — and one unit less must not.
    function test_fork_exactOutIsTheLeastInputThatClearsTheTarget() public view {
        uint256 checked;

        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            if (router.marketLiquidity(id) == 0) continue;

            // A target the pool can actually fill: what 10 USDG buys today.
            (uint256 target,) = lens.quoteBuy(id, 10e6);
            if (target == 0) continue;

            (uint256 needed,) = lens.quoteBuyExactOut(id, target);
            (uint256 got,) = lens.quoteBuy(id, needed);
            assertGe(got, target, "exact-out input must clear the target");

            if (needed > 1) {
                (uint256 gotLess,) = lens.quoteBuy(id, needed - 1);
                assertLt(gotLess, target + 1, "and must be the least such input, near enough");
            }
            ++checked;
        }

        assertGt(checked, 0, "no live market answered");
        console.log("exact-out checks", checked);
    }

    /// @notice The property the whole change exists for, against live state: an aggregator
    ///         sampling this venue from inside its own call must get an answer. Asked through
    ///         a low-level static call so the EVM enforces it, not solc.
    function test_fork_quotesAnswerInsideAStaticcall() public view {
        uint256 answered;

        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            if (router.marketLiquidity(id) == 0) continue;

            (bool ok, bytes memory data) =
                address(lens).staticcall(abi.encodeCall(MarketLens.quoteBuy, (id, 1e6)));
            assertTrue(ok, "quoteBuy must survive STATICCALL against live state");

            (uint256 out, uint256 gasEstimate) = abi.decode(data, (uint256, uint256));
            assertGt(out, 0, "and answer with a number");
            console.log("market", id, "quoteBuy(1 USDG)", out);
            console.log("  gasEstimate", gasEstimate);
            ++answered;
        }

        assertGt(answered, 0, "no live market answered");
    }

    /// @notice The dead ids are dead in the simulator too. `NotEnoughLiquidity` is the answer
    ///         a router must see for an empty pool — never a zero that reads as a real price.
    function test_fork_drainedMarketsRefuseRatherThanQuoteZero() public view {
        uint256 refused;

        for (uint256 id = 1; id <= factory.marketCount(); ++id) {
            if (router.marketLiquidity(id) != 0) continue;

            (bool ok, bytes memory data) =
                address(lens).staticcall(abi.encodeCall(MarketLens.quoteBuy, (id, 1e6)));
            assertFalse(ok, "a drained pool must not answer with a number");
            assertGt(data.length, 0, "and must say why");
            ++refused;
        }

        console.log("drained markets that refused", refused);
    }
}
