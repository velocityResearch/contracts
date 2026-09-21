// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @dev The ERC-721 half of the deployed `PositionManager`, which `IPositionManagerV4` does not
///      declare because nothing in `src/` needs it.
interface IPositionsNftLike {
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev The one call this suite makes into our own deployed factory. Declared by hand rather
///      than imported so the suite is pinned to the live contract's ABI and not to whatever
///      `src/markets/AssetMarketFactory.sol` happens to say today: the market being exercised
///      exists on chain, and its `PoolKey` must come from there.
interface IAssetMarketFactoryLike {
    function poolKeyOf(uint256 marketId) external view returns (PoolKey memory);
}

/// @dev A brand token names the `SharedReservePool` that mints and redeems it 1:1, which is how
///      this suite funds the quote side of a live market without a funded key.
interface IBrandTokenLike {
    function pool() external view returns (address);
}

interface ISharedReserveLike {
    function mint(address token, uint256 amount, address receiver) external returns (uint256);
}

/// @title ConcentratedWorkbenchV4ForkTest
/// @notice The "Custom range" workbench's calldata, run against **Uniswap's own deployed v4
///         periphery on Robinhood Chain and a real live market pool**: the real
///         `PositionManager`, the canonical Permit2, the real `PoolManager` singleton, and the
///         `PoolKey` of market 13 as our deployed `AssetMarketFactory` reports it.
///
///         `MarketRouterV4Fork.t.sol` proves the *router's* seed path works on the real
///         periphery. This suite proves the other half of the market page: the concentrated
///         workbench, which does not go through any contract in this repo at all. It builds
///         `modifyLiquidities` calldata in the browser and sends it straight to Uniswap, so the
///         only thing standing between a provider and a lost transaction is that the encoder in
///         `web-stable/src/features/asset-markets/liquidity-actions.ts` agrees with the deployed
///         contract about every opcode and operand. That agreement cannot be tested in the
///         frontend — a passing unit test there only proves the encoder matches itself — and it
///         cannot be tested offline here, because the periphery is not compilable into this repo
///         (`permit2` pins `solc =0.8.17`). It can only be tested here, on a fork.
///
///         Every byte this suite sends is built the way `encodeLiquidityPlan` builds it: an
///         `abi.encodePacked` string of one-byte opcodes, a `bytes[]` of `abi.encode`d operand
///         tuples, and `abi.encode(actions, params)` as the unlock data. A mint is N x
///         `MINT_POSITION` then one `SETTLE_PAIR`; a partial exit is `DECREASE_LIQUIDITY` then
///         `TAKE_PAIR`. Leg sizing mirrors the workbench: liquidity fitted to a budget at the
///         live price, then `amountMax = amount * (10_000 + toleranceBps) / 10_000`. The exit's
///         floors mirror `planPartialExit`: the removed liquidity's worth at the live price,
///         times `(10_000 - toleranceBps) / 10_000`.
///
///         **Real:** the PoolManager, the PositionManager, Permit2, the deployed
///         `AssetMarketFactory`, the deployed `ProtocolFeeHook` on market 13's pool, its live
///         depth and price, NVDA, AIUSD, USDG, and the `SharedReservePool` the quote side is
///         minted from. **Ours, deployed into the fork:** nothing at all. Nothing is mocked.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state more than a few hundred blocks back comes back as
///         `-32000: metadata is not found`, and every test then fails inside `setUp` with an
///         account-fetch error that says nothing about liquidity. Take the block from the chain,
///         not from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-contract ConcentratedWorkbenchV4Fork --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract ConcentratedWorkbenchV4ForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The live venue ──────────────────────────────────────────────────

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 constant POSM = IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    /// @notice The live `AssetMarketFactory`, as `deployments/asset-markets-mainnet-v6.json`
    ///         records it. Not in `MainnetAddresses` because it is a per-deployment output.
    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;

    /// @notice Market 13: NVDA quoted in AIUSD, the first of the six live liquidity-carrying
    ///         markets (13-18) and the one the lens deploy read back. Its `PoolKey` is resolved
    ///         through the factory rather than written down, so a renumbered market fails the
    ///         `setUp` guard instead of silently testing a different pool.
    uint256 constant MARKET_ID = 13;

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;

    /// @dev NVDA is an issuer-controlled beacon proxy, so `deal` cannot be trusted to find its
    ///      balance slot. The live NVDA/USDG v3 pool is a real holder (13,056 NVDA at the time
    ///      of writing), so real tokens are moved instead. Read for nothing, traded against
    ///      never.
    address constant LIVE_NVDA_USDG_POOL = MainnetAddresses.NVDA_USDG_POOL;

    // ─── v4-periphery action ids ─────────────────────────────────────────
    //
    // The same four opcodes `liquidity-actions.ts` exports. Written out rather than imported
    // for the reason in the header; they index into `BaseActionsRouter._handleAction`, so a
    // wrong byte is a different action and not a revert.

    uint8 constant MINT_POSITION = 0x02;
    uint8 constant DECREASE_LIQUIDITY = 0x01;
    uint8 constant SETTLE_PAIR = 0x0d;
    uint8 constant TAKE_PAIR = 0x11;

    /// @dev `DEFAULT_TOLERANCE_BPS` in `liquidity-deposit.ts`: the 3% both the mint's ceilings
    ///      and the exit's floors are derived from.
    uint256 constant TOLERANCE_BPS = 300;

    // ─── The provider ────────────────────────────────────────────────────

    address provider = address(0xC0DE1);

    PoolKey poolKey;
    PoolId poolId;
    address token0;
    address token1;
    int24 spacing;

    /// @dev The aligned tick at or just below spot. Every range in this file is expressed in
    ///      spacings from here, so the suite does not rot as the live price moves.
    int24 anchor;

    function setUp() public {
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, it does not abort the body, so the early return is
        // what keeps the rest of this from reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        poolKey = IAssetMarketFactoryLike(FACTORY).poolKeyOf(MARKET_ID);
        poolId = poolKey.toId();
        token0 = Currency.unwrap(poolKey.currency0);
        token1 = Currency.unwrap(poolKey.currency1);
        spacing = poolKey.tickSpacing;

        // The funding routes below are specific to this market's two currencies: the asset side
        // is moved from a real holder, the quote side is minted from its reserve. Assert the
        // market still is what those routes assume rather than mis-funding a renumbered one.
        assertEq(token0, MainnetAddresses.NVDA, "market 13's asset side is still NVDA");
        address reserve = IBrandTokenLike(token1).pool();
        assertTrue(reserve != address(0), "and its quote side is still a pooled brand token");

        (uint160 sqrtPriceX96, int24 currentTick,,) = MANAGER.getSlot0(poolId);
        assertTrue(sqrtPriceX96 > 0, "the live pool is initialised");
        assertGt(MANAGER.getLiquidity(poolId), 0, "and carries depth at spot");
        anchor = _alignDown(currentTick);

        // 200 NVDA and 100,000 AIUSD: far more than any plan below spends, so a leg that
        // overspends fails a ceiling assertion rather than running out of money.
        vm.prank(LIVE_NVDA_USDG_POOL);
        IERC20(token0).transfer(provider, 200e18);
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(provider, 100_000e6);
        vm.startPrank(provider);
        IERC20(USDG).approve(reserve, 100_000e6);
        ISharedReserveLike(reserve).mint(token1, 100_000e6, provider);

        // The two Permit2 legs, exactly as `approveThroughPermit2` sets them: the ERC-20
        // allowance to Permit2, then Permit2's own allowance to the PositionManager at the
        // never-decremented / never-expiring sentinels. `PositionManager` pulls tokens through
        // Permit2 only, so a mint with just the first leg settles nothing.
        IERC20(token0).approve(MainnetAddresses.PERMIT2, type(uint256).max);
        IERC20(token1).approve(MainnetAddresses.PERMIT2, type(uint256).max);
        PERMIT2.approve(token0, address(POSM), type(uint160).max, type(uint48).max);
        PERMIT2.approve(token1, address(POSM), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ─── 1. One concentrated leg ─────────────────────────────────────────

    /// @notice A single non-full-range leg straddling spot: Uniswap mints a real LP NFT to the
    ///         provider over exactly the aligned range that was asked for, and the depth the
    ///         pool trades against grows by exactly that leg's liquidity.
    ///
    ///         This test also prints the golden `unlockData` for a fixed plan (see
    ///         `_logGoldenUnlockData`) so the TypeScript encoder can be diffed against bytes the
    ///         deployed contract accepted.
    function test_oneConcentratedLegMintsAnLpNftOverTheRequestedRange() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _fit(anchor - 10 * spacing, anchor + 10 * spacing, 1e18, 400e6);

        uint256 expectedId = POSM.nextTokenId();
        uint256 heldBefore = IPositionsNftLike(address(POSM)).balanceOf(provider);
        uint128 depthBefore = MANAGER.getLiquidity(poolId);

        Spend memory spend = _mint(legs);

        assertEq(spend.tokenIds[0], expectedId, "the id the encoder can predict is the id minted");
        assertEq(POSM.ownerOf(expectedId), provider, "the provider owns the position");
        assertEq(
            IPositionsNftLike(address(POSM)).balanceOf(provider),
            heldBefore + 1,
            "as an ERC-721 in their own wallet"
        );

        (PoolKey memory minted,) = POSM.getPoolAndPositionInfo(expectedId);
        assertEq(Currency.unwrap(minted.currency0), token0, "in the market's own pool");
        assertEq(Currency.unwrap(minted.currency1), token1);
        assertEq(minted.fee, poolKey.fee);
        assertEq(minted.tickSpacing, spacing);
        assertEq(address(minted.hooks), address(poolKey.hooks), "behind the market's own hook");

        (int24 lower, int24 upper) = _rangeOf(expectedId);
        assertEq(lower, legs[0].tickLower, "over the requested aligned lower tick");
        assertEq(upper, legs[0].tickUpper, "and the requested aligned upper tick");
        assertEq(POSM.getPositionLiquidity(expectedId), legs[0].liquidity, "at the sized depth");

        // The range straddles spot, so this liquidity is live: it is what the next swap trades
        // against, which is the only sense in which a concentrated position is "in" the pool.
        assertEq(
            MANAGER.getLiquidity(poolId),
            depthBefore + legs[0].liquidity,
            "and the pool's depth at spot grew by exactly it"
        );

        assertGt(spend.amount0, 0, "both sides were paid for, as a straddling range must be");
        assertGt(spend.amount1, 0);
        assertLe(spend.amount0, legs[0].amount0Max, "within the ceiling the provider agreed to");
        assertLe(spend.amount1, legs[0].amount1Max);

        _logGoldenUnlockData();
    }

    // ─── 2. Three legs, one transaction ──────────────────────────────────

    /// @notice The shape the planner produces for a multi-leg plan: three contiguous legs minted
    ///         in a single `modifyLiquidities`, settled once. Each leg is its own position with
    ///         its own range, and the whole transaction stays inside the summed ceilings — which
    ///         is the property that makes one settle for many legs safe.
    function test_threeContiguousLegsMintThreeDistinctPositionsInOneTransaction() public {
        Leg[] memory legs = new Leg[](3);
        // Spot sits in the middle leg: the lower leg is entirely below it and the upper leg
        // entirely above it, so the plan exercises all three funding cases at once.
        legs[0] = _fit(anchor - 6 * spacing, anchor - 2 * spacing, 0, 400e6);
        legs[1] = _fit(anchor - 2 * spacing, anchor + 2 * spacing, 1e18, 400e6);
        legs[2] = _fit(anchor + 2 * spacing, anchor + 6 * spacing, 1e18, 0);

        uint256 expectedFirst = POSM.nextTokenId();
        uint256 heldBefore = IPositionsNftLike(address(POSM)).balanceOf(provider);

        Spend memory spend = _mint(legs);

        assertEq(
            IPositionsNftLike(address(POSM)).balanceOf(provider),
            heldBefore + 3,
            "one NFT per leg, not one NFT for the plan"
        );

        uint256 ceiling0;
        uint256 ceiling1;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 tokenId = spend.tokenIds[i];
            assertEq(tokenId, expectedFirst + i, "ids are consecutive in leg order");
            assertEq(POSM.ownerOf(tokenId), provider, "every leg owned by the provider");
            assertEq(POSM.getPositionLiquidity(tokenId), legs[i].liquidity, "at its own depth");

            (int24 lower, int24 upper) = _rangeOf(tokenId);
            assertEq(lower, legs[i].tickLower, "over its own lower tick");
            assertEq(upper, legs[i].tickUpper, "and its own upper tick");
            if (i > 0) {
                (, int24 previousUpper) = _rangeOf(spend.tokenIds[i - 1]);
                assertEq(lower, previousUpper, "contiguous with the leg below it");
            }

            ceiling0 += legs[i].amount0Max;
            ceiling1 += legs[i].amount1Max;
        }

        assertGt(spend.amount0, 0, "the plan spent real money");
        assertGt(spend.amount1, 0);
        assertLe(spend.amount0, ceiling0, "never past the summed amount0Max");
        assertLe(spend.amount1, ceiling1, "never past the summed amount1Max");
    }

    // ─── 3. Partial exit ─────────────────────────────────────────────────

    /// @notice `planPartialExit` at 50%: the position keeps exactly the liquidity that was not
    ///         removed, the provider is paid at least both floors, and the NFT survives — the
    ///         three things that distinguish a partial exit from a burn.
    function test_partialExitLeavesTheRemainderAndPaysAtLeastBothFloors() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _fit(anchor - 10 * spacing, anchor + 10 * spacing, 1e18, 400e6);
        uint256 tokenId = _mint(legs).tokenIds[0];

        uint128 held = POSM.getPositionLiquidity(tokenId);
        uint128 removed = uint128((uint256(held) * 5_000) / 10_000);
        assertGt(removed, 0, "half of this position is a nonzero amount of liquidity");

        (uint128 min0, uint128 min1) = _floors(legs[0].tickLower, legs[0].tickUpper, removed);
        assertGt(min0, 0, "a straddling range owes both sides, so both floors bite");
        assertGt(min1, 0);

        uint256 before0 = IERC20(token0).balanceOf(provider);
        uint256 before1 = IERC20(token1).balanceOf(provider);

        _decrease(tokenId, removed, min0, min1);

        assertEq(
            POSM.getPositionLiquidity(tokenId),
            held - removed,
            "the position holds exactly the un-removed remainder"
        );
        assertEq(POSM.ownerOf(tokenId), provider, "and the NFT still exists, still theirs");

        assertGe(
            IERC20(token0).balanceOf(provider) - before0, min0, "paid at least the token0 floor"
        );
        assertGe(
            IERC20(token1).balanceOf(provider) - before1, min1, "and at least the token1 floor"
        );
    }

    // ─── 4. A floor that cannot be met ───────────────────────────────────

    /// @notice A decrease whose floors are above what the liquidity is worth reverts rather than
    ///         settling short. This is the whole purpose of the floors: without this the
    ///         workbench's tolerance control would be decoration.
    function test_anExitAskingMoreThanThePositionCanPayReverts() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _fit(anchor - 10 * spacing, anchor + 10 * spacing, 1e18, 400e6);
        uint256 tokenId = _mint(legs).tokenIds[0];

        uint128 held = POSM.getPositionLiquidity(tokenId);
        uint128 removed = uint128((uint256(held) * 5_000) / 10_000);
        (uint128 min0, uint128 min1) = _floors(legs[0].tickLower, legs[0].tickUpper, removed);

        // Twice what this liquidity is worth at the live price. Nothing in the pool can pay it.
        vm.expectPartialRevert(bytes4(keccak256("MinimumAmountInsufficient(uint128,uint128)")));
        _decrease(tokenId, removed, min0 * 2, min1 * 2);

        assertEq(POSM.getPositionLiquidity(tokenId), held, "nothing was removed");
    }

    // ─── 5. An expired deadline ──────────────────────────────────────────

    /// @notice The deadline is the window a signed plan may sit in the mempool. Past it, the
    ///         mint is refused before any operand is read, so a plan sized at a stale price
    ///         cannot land at a new one.
    function test_aMintPastItsDeadlineReverts() public {
        Leg[] memory legs = new Leg[](1);
        legs[0] = _fit(anchor - 10 * spacing, anchor + 10 * spacing, 1e18, 400e6);

        uint256 expired = vm.getBlockTimestamp() - 1;
        bytes memory unlockData = _mintUnlockData(legs, provider);

        uint256 nextId = POSM.nextTokenId();
        vm.expectPartialRevert(bytes4(keccak256("DeadlinePassed(uint256)")));
        vm.prank(provider);
        POSM.modifyLiquidities(unlockData, expired);

        assertEq(POSM.nextTokenId(), nextId, "and nothing was minted");
    }

    // ─── 6. One-sided ranges ─────────────────────────────────────────────

    /// @notice A range that does not contain spot is funded from exactly one side, and adds no
    ///         depth at spot. Above spot every unit of liquidity is token0; below it, token1.
    ///         This is the assertion that a provider's "sell wall" plan does not silently pull
    ///         the other token out of their wallet.
    function test_aRangeOffSpotIsFundedFromExactlyOneSideAndAddsNoDepthAtSpot() public {
        uint128 depthBefore = MANAGER.getLiquidity(poolId);

        Leg[] memory above = new Leg[](1);
        above[0] = _fit(anchor + 4 * spacing, anchor + 12 * spacing, 1e18, 400e6);
        Spend memory aboveSpend = _mint(above);

        assertGt(aboveSpend.amount0, 0, "a range above spot is paid for in token0");
        assertEq(aboveSpend.amount1, 0, "and costs not a wei of token1");

        Leg[] memory below = new Leg[](1);
        below[0] = _fit(anchor - 12 * spacing, anchor - 4 * spacing, 1e18, 400e6);
        Spend memory belowSpend = _mint(below);

        assertGt(belowSpend.amount1, 0, "a range below spot is paid for in token1");
        assertEq(belowSpend.amount0, 0, "and costs not a wei of token0");

        assertEq(
            MANAGER.getLiquidity(poolId),
            depthBefore,
            "neither leg is what the next swap trades against"
        );
    }

    // ─── The golden encoding ─────────────────────────────────────────────

    /// @dev One fixed plan, printed as the exact bytes the deployed `PositionManager` accepts, so
    ///      `encodeLiquidityPlan` can be diffed against it byte for byte. Every operand is a
    ///      literal and the `PoolKey` is market 13's, which is immutable on chain, so these
    ///      bytes do not depend on the fork block or the live price. Sent as well as printed:
    ///      bytes nothing has executed are a claim, not a golden.
    function _logGoldenUnlockData() internal {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            tickLower: -221_000,
            tickUpper: -220_500,
            liquidity: 1e12,
            amount0Max: 2e15,
            amount1Max: 1e6
        });
        address goldenOwner = address(0xbEEF);

        bytes memory unlockData = _mintUnlockData(legs, goldenOwner);
        console.log("golden plan: market", MARKET_ID);
        console.log("golden plan: tickLower -221000 tickUpper -220500 liquidity 1e12");
        console.log("golden plan: amount0Max 2e15 amount1Max 1e6 owner 0xbEEF hookData 0x");
        console.log("golden unlockData:");
        console.logBytes(unlockData);

        uint256 goldenId = POSM.nextTokenId();
        vm.prank(provider);
        POSM.modifyLiquidities(unlockData, vm.getBlockTimestamp() + 1 hours);
        assertEq(POSM.ownerOf(goldenId), goldenOwner, "the golden bytes really do mint");
    }

    // ─── Encoding, exactly as the frontend does it ───────────────────────

    struct Leg {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct Spend {
        uint256[] tokenIds;
        uint256 amount0;
        uint256 amount1;
    }

    /// @dev `encodeLiquidityPlan({kind: "mint"})`: one `MINT_POSITION` per leg then a single
    ///      `SETTLE_PAIR`, `abi.encode(actions, params)`.
    function _mintUnlockData(Leg[] memory legs, address owner)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actions;
        bytes[] memory params = new bytes[](legs.length + 1);
        for (uint256 i = 0; i < legs.length; ++i) {
            actions = abi.encodePacked(actions, MINT_POSITION);
            params[i] = abi.encode(
                poolKey,
                legs[i].tickLower,
                legs[i].tickUpper,
                uint256(legs[i].liquidity),
                legs[i].amount0Max,
                legs[i].amount1Max,
                owner,
                bytes("")
            );
        }
        actions = abi.encodePacked(actions, SETTLE_PAIR);
        params[legs.length] = abi.encode(poolKey.currency0, poolKey.currency1);
        return abi.encode(actions, params);
    }

    /// @dev Send a mint plan and report what it cost the provider and which ids it produced.
    function _mint(Leg[] memory legs) internal returns (Spend memory spend) {
        spend.tokenIds = new uint256[](legs.length);
        uint256 firstId = POSM.nextTokenId();
        for (uint256 i = 0; i < legs.length; ++i) {
            spend.tokenIds[i] = firstId + i;
        }

        uint256 before0 = IERC20(token0).balanceOf(provider);
        uint256 before1 = IERC20(token1).balanceOf(provider);

        vm.prank(provider);
        POSM.modifyLiquidities(_mintUnlockData(legs, provider), vm.getBlockTimestamp() + 1 hours);

        spend.amount0 = before0 - IERC20(token0).balanceOf(provider);
        spend.amount1 = before1 - IERC20(token1).balanceOf(provider);
    }

    /// @dev `encodeLiquidityPlan({kind: "decrease"})`: `DECREASE_LIQUIDITY` then `TAKE_PAIR` to
    ///      the provider.
    function _decrease(uint256 tokenId, uint128 liquidity, uint128 amount0Min, uint128 amount1Min)
        internal
    {
        bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, provider);

        vm.prank(provider);
        POSM.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp() + 1 hours);
    }

    // ─── Sizing, exactly as the workbench does it ────────────────────────

    /// @dev One leg sized the way `planRange` sizes it and capped the way `mintAction` caps it:
    ///      liquidity fitted to the budget at the live price, the amounts that liquidity is
    ///      actually worth, then `amount * (10_000 + toleranceBps) / 10_000` as the ceiling.
    function _fit(int24 tickLower, int24 tickUpper, uint256 budget0, uint256 budget1)
        internal
        view
        returns (Leg memory leg)
    {
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, budget0, budget1
        );
        require(liquidity > 0, "budget buys no liquidity on this leg");

        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);

        leg = Leg({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0Max: uint128((amount0 * (10_000 + TOLERANCE_BPS)) / 10_000),
            amount1Max: uint128((amount1 * (10_000 + TOLERANCE_BPS)) / 10_000)
        });
    }

    /// @dev `planPartialExit`'s floors: what the removed liquidity is worth at the price now,
    ///      floored by the tolerance. Floored and never rounded up, because a floor that rounds
    ///      up is a floor the transaction can fail on for a rounding error alone.
    function _floors(int24 tickLower, int24 tickUpper, uint128 removed)
        internal
        view
        returns (uint128 amount0Min, uint128 amount1Min)
    {
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(poolId);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            removed
        );
        uint256 kept = 10_000 - TOLERANCE_BPS;
        amount0Min = uint128((amount0 * kept) / 10_000);
        amount1Min = uint128((amount1 * kept) / 10_000);
    }

    // ─── Reading the live state ──────────────────────────────────────────

    /// @dev `alignRange`'s lower edge: the largest multiple of the spacing at or below `tick`.
    ///      Solidity truncates toward zero, which rounds the wrong way for the negative ticks
    ///      every stable-quoted market sits at.
    function _alignDown(int24 tick) internal view returns (int24) {
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }

    /// @dev v4-periphery packs a position's range into `PositionInfo` as
    ///      `200 bits poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits hasSubscriber`.
    function _rangeOf(uint256 tokenId) internal view returns (int24 tickLower, int24 tickUpper) {
        (, uint256 info) = POSM.getPoolAndPositionInfo(tokenId);
        tickLower = int24(uint24(info >> 8));
        tickUpper = int24(uint24(info >> 32));
    }
}
