// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {ProtocolStack} from "../../src/upgrade/ProtocolStack.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchDeployer} from "../../src/launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {
    GraduationPhase,
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {HookSaltMiner} from "../../script/DeployAssetMarkets.s.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
// The ERC-721 half of the deployed `PositionManager` and Morpho's interest forcing, both
// already written out for the market suite's fork test. Imported rather than re-declared so
// there is one description of each live contract in the test tree.
import {IMorphoAccrue, IPositionsNftLike} from "../markets/LaunchJourneyV4Fork.t.sol";

/// @title LaunchpadJourneyV4ForkTest
/// @notice **A launch, start to finish, against the live chain.**
///
///         `test/launchpad/LaunchGraduation.t.sol` already runs the whole launch lifecycle,
///         but it runs it against a `PositionManager` written inside `MarketRouter.t.sol`. That
///         stand-in can only ever confirm that the graduation module encodes what *we* believe
///         `MINT_POSITION` + `SETTLE_PAIR` mean. Whether Uniswap's own deployed periphery
///         agrees — and whether the pool that comes out is a pool the rest of the world can
///         see — is only answerable here.
///
///         **Real:** the v4 `PoolManager` singleton, Uniswap's `PositionManager`, canonical
///         Permit2, USDG, Morpho Blue (the reserve's yield source, and the chain's USDG whale).
///         **Ours, deployed into the fork:** the reserve stack, the fee hook at a *mined*
///         CREATE2 address through the chain's deterministic deployment proxy — the same path
///         `script/DeployAssetMarkets.s.sol` takes — the market factory, the market router and
///         the whole launchpad, wired as `ProtocolStack.deployLaunchpad` wires it. Nothing is
///         mocked, and the economics are the shipped defaults of plan §10.
///
///         The journey: register a quote brand → launch a token → four wallets trade the curve
///         → the crossing buy fills partially and graduates the launch inside its own
///         transaction → `graduateToMarket` opens a real v4 pool at the curve's terminal price,
///         mints a real Uniswap position, stakes it under `LaunchLocker` forever → a stranger
///         buys the graduated token with USDG through `MarketRouter` → the position's real swap
///         fees and the market's real Morpho float yield are collected and split into
///         `LaunchFeeEscrow`.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state older than a few thousand blocks comes back as
///         `-32000: metadata is not found`, and every test then fails inside `setUp` with an
///         account-fetch error that says nothing about our contracts. Take the block from the
///         chain rather than from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-path "test/launchpad/LaunchJourneyV4Fork.t.sol" --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract LaunchpadJourneyV4ForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The live chain ──────────────────────────────────────────────────

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 constant POSM = IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;
    bytes32 constant USDE_MARKET_ID = MainnetAddresses.USDE_MARKET_ID;

    /// @dev The deterministic deployment proxy, which really is deployed on this chain (checked
    ///      2026-09-15). `HookSaltMiner` mines against it, so the hook has to be created
    ///      through it for the mined address to be the address that appears.
    address constant CREATE2_DEPLOYER = HookSaltMiner.CREATE2_DEPLOYER;

    // ─── Shipped configuration (plan §10) ────────────────────────────────

    uint24 constant PROTOCOL_FEE_PIPS = 1_000; // 0.10% of every swap's unspecified leg
    uint256 constant LAUNCH_SUPPLY = 1e27;
    uint256 constant CURVE_FEE_BPS = 100;
    uint24 constant POOL_FEE = 5_000;
    int24 constant POOL_TICK_SPACING = 50;
    uint256 constant PHANTOM_QUOTE = 3_236e6;
    uint256 constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 constant LAUNCH_FEE = 1e6;

    // ─── Our stack, deployed into the fork ───────────────────────────────

    MorphoBlueYieldSource yieldSource;
    SharedReservePool reserve;
    ProtocolFeeHook feeHook;
    AssetMarketFactory marketFactory;
    MarketRouter router;
    PoolSwapTest poolSwap;

    LaunchFeeEscrow feeEscrow;
    LaunchLocker locker;
    LaunchGraduation graduation;
    LaunchDeployer launchDeployer;
    LaunchFactory launchFactory;

    address quoteBrand;
    uint256 launchConfigId;

    // ─── The cast ────────────────────────────────────────────────────────

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address protocolFeeRecipient = address(0xFEE);
    address creator = address(0x0FE);
    address creatorFeeRecipient = address(0xC0FE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address whale = address(0x7AAD);
    address stranger = address(0x57A);

    // ─── The launch under test ───────────────────────────────────────────

    address token;
    address curve;

    /// @dev What phase one handed the factory, snapshotted by `_graduate` before phase two
    ///      clears it off the launch record. Every reconciliation below is against these.
    uint256 sweptQuote;
    uint256 sweptTokens;

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, so the early return is what stops the body from
        // reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reserve = _deployReservePool(USDG, address(yieldSource), owner);

        feeHook = _deployMinedHook();

        marketFactory = _deployFactory(
            reserve,
            MANAGER,
            feeHook,
            POSM,
            protocolTreasury,
            address(0), // no canonical-equity reference: a launched token is never verified
            0, // the whole protocol cut of float yield stays with the market's LPs
            owner
        );

        vm.startPrank(owner);
        feeHook.setRegistrar(address(marketFactory));
        marketFactory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        router = _deployRouter(reserve, marketFactory, POSM, PERMIT2, owner);
        poolSwap = new PoolSwapTest(MANAGER);

        _deployLaunchpad();

        // The brand every launch here is quoted in, registered on the default reserve the way
        // any community registers theirs. Registering through the market factory leaves this
        // contract as the treasury's admin, which is the party that opts the brand into
        // sharing the float yield of the markets it quotes — a launch re-reads that opt-in
        // for its quote brand every time, so it is still required here.
        address quoteTreasury;
        (quoteBrand, quoteTreasury) = marketFactory.registerBrand("Launch Dollar", "launchUSD");
        PoolBrandTreasury(quoteTreasury).setFactory(address(marketFactory));
        // Terms are written once against the RESERVE and serve every brand of it.
        vm.prank(owner);
        launchFactory.setReserveEconomics(
            address(reserve),
            LaunchFactory.ReserveEconomics({
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                launchFee: LAUNCH_FEE,
                decimals: 6,
                approved: true
            })
        );

        (token, curve) = _launch();
    }

    // ══ Step 1 ══ The curve ═══════════════════════════════════════════════

    /// @notice Four wallets fill one curve, and the buy that exhausts its allocation graduates
    ///         the launch inside its own transaction.
    ///
    ///         The crossing buy is the step this whole suite exists around: it is partially
    ///         filled, refunded, and then calls back into the factory to sweep the curve — all
    ///         while the live chain's own state sits underneath.
    function test_fork_step1_fourWalletsFillTheCurveAndTheCrossingBuyGraduatesIt() public {
        uint256 aliceOut = _buy(alice, 1_500e6);
        uint256 bobOut = _buy(bob, 2_000e6);
        assertGt(aliceOut, 0, "alice bought");
        assertGt(bobOut, 0, "bob bought");
        // Each buy costs the next one more: the constant product is the price.
        assertLt(bobOut * 1_500e6 / 2_000e6, aliceOut, "the second buyer paid more per token");

        // A seller gets out at the curve's price, less the fee on the way back.
        uint256 sold = aliceOut / 2;
        vm.startPrank(alice);
        IERC20(token).approve(curve, sold);
        uint256 quoteBack = LaunchCurve(curve).sell(sold, 0, alice);
        vm.stopPrank();
        assertGt(quoteBack, 0, "and sold back for real quote");

        _buy(carol, 500e6);
        assertFalse(LaunchCurve(curve).readyToGraduate(), "still short of the threshold");

        // The crossing buy: deliberately twice the threshold, so it is clamped to the
        // remaining allocation and refunded the rest.
        uint256 offered = GRADUATION_THRESHOLD * 2;
        uint256 quoteBefore = _fundQuote(whale, offered);
        vm.startPrank(whale);
        IERC20(quoteBrand).approve(curve, offered);
        uint256 whaleOut = LaunchCurve(curve).buy(offered, 0, whale);
        vm.stopPrank();

        assertGt(whaleOut, 0, "the crossing buy filled");
        assertGt(
            IERC20(quoteBrand).balanceOf(whale),
            quoteBefore - offered,
            "and the unspent offer came back"
        );

        assertEq(LaunchCurve(curve).sellableTokens(), 0, "the allocation is exhausted");
        assertTrue(LaunchCurve(curve).graduated(), "the curve closed itself");

        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(GraduationPhase.Swept), "phase one ran in the buy");
        assertGe(launch.sweptQuote, GRADUATION_THRESHOLD, "the threshold was reached");
        assertApproxEqAbs(launch.sweptQuote, GRADUATION_THRESHOLD, 10, "and only just");
        assertEq(IERC20(quoteBrand).balanceOf(address(launchFactory)), launch.sweptQuote);
        assertEq(IERC20(token).balanceOf(address(launchFactory)), launch.sweptTokens);

        // Trading really is over, on both sides, against the real chain.
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        LaunchCurve(curve).buy(1e6, 0, whale);
        vm.expectRevert(LaunchCurve.CurveGraduated.selector);
        LaunchCurve(curve).sell(1e18, 0, whale);

        console.log("swept quote (brand, 6dp):", launch.sweptQuote);
        console.log("swept supply (token, 18dp):", launch.sweptTokens);
    }

    // ══ Step 2 ══ The pool ════════════════════════════════════════════════

    /// @notice Graduation opens a pool inside the deployed v4 singleton, with the key this
    ///         product's configuration implies and at the price the curve ended on.
    ///
    ///         Every field of the key is asserted because the key *is* the pool's identity in
    ///         v4: a wrong fee, a wrong spacing or a hook address off by one bit is a different
    ///         pool, and nothing downstream would notice until liquidity failed to appear where
    ///         a chart looked for it.
    function test_fork_step2_theLiveSingletonHoldsThePoolTheLaunchImplies() public {
        uint256 brandsBefore = reserve.allBrandTokensLength();
        Graduated memory g = _graduate();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;

        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        (address expected0, address expected1) = g.unit < token ? (g.unit, token) : (token, g.unit);
        assertEq(Currency.unwrap(key.currency0), expected0, "currency0");
        assertEq(Currency.unwrap(key.currency1), expected1, "currency1");
        assertEq(key.fee, POOL_FEE, "the launch config's 0.50% tier");
        assertEq(key.tickSpacing, POOL_TICK_SPACING, "and the spacing that tier pins");
        assertEq(address(key.hooks), address(feeHook), "our fee hook is in the key");
        assertEq(PoolId.unwrap(key.toId()), g.poolId, "the id the event announced");

        // Live in Uniswap's own storage, at the curve's terminal price.
        (uint160 sqrtPriceX96, int24 tick,,) = MANAGER.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "initialised inside the real PoolManager");
        assertApproxEqRel(
            sqrtPriceX96, _terminalSqrtPrice(g.unit), 1e9, "the pool opens where the curve ended"
        );
        assertGt(MANAGER.getLiquidity(key.toId()), 0, "and it has depth");

        // The hook is bound to this pool and pays the protocol treasury.
        assertEq(feeHook.feeRecipientOf(key.toId()), protocolTreasury);
        assertEq(feeHook.feePipsFor(key.toId()), PROTOCOL_FEE_PIPS);

        // The market is quoted in the dollar the curve was quoted in. Graduation registers no
        // brand of its own, and makes no claim on the one it uses.
        assertEq(g.unit, quoteBrand, "the launch's own dollar, not a fresh <SYM>.d");
        assertEq(reserve.allBrandTokensLength(), brandsBefore, "and no new brand was minted");
        assertTrue(marketFactory.isSharedQuote(marketId), "a shared-quote market");
        assertEq(marketFactory.marketOfBrand(quoteBrand), 0, "the brand belongs to no market");

        console.log("pool id:");
        console.logBytes32(g.poolId);
        console.log("sqrtPriceX96 in the live singleton:", sqrtPriceX96);
        console.log("opening tick:", tick);
    }

    /// @notice A stranger who only saw the `PoolGraduated` event can find the pool.
    ///
    ///         This is the claim that makes the graduated market a public venue rather than a
    ///         private one: the event carries the unit, and the launch record carries the token
    ///         and the LP tier, which is everything needed to rebuild the `PoolKey` and read
    ///         v4's own storage with v4's own library. No call into our factory is involved in
    ///         the read.
    function test_fork_step2_theGraduatedPoolIsVisibleToAGenericV4Reader() public {
        Graduated memory g = _graduate();

        // Built from the event and the public launch record only.
        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        (address c0, address c1) =
            g.unit < launch.token ? (g.unit, launch.token) : (launch.token, g.unit);
        PoolKey memory rebuilt = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: launch.poolFee,
            tickSpacing: marketFactory.tickSpacingForFee(launch.poolFee),
            hooks: IHooks(address(feeHook))
        });

        assertEq(PoolId.unwrap(rebuilt.toId()), g.poolId, "the rebuilt key hashes to the pool");

        // `StateLibrary` is v4-core's own reader, over `extsload` on the singleton: this is
        // exactly what an indexer or an aggregator does, with no help from us.
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) =
            MANAGER.getSlot0(PoolId.wrap(g.poolId));
        assertGt(sqrtPriceX96, 0, "a third party reads a live pool");
        assertEq(lpFee, POOL_FEE, "at the tier the launch configured");
        assertEq(protocolFee, 0, "with no v4 protocol fee set on it");
        assertEq(
            MANAGER.getLiquidity(PoolId.wrap(g.poolId)),
            POSM.getPositionLiquidity(g.positionId),
            "and the locked seed is the whole of its depth"
        );
    }

    // ══ Step 3 ══ The locked position ═════════════════════════════════════

    /// @notice What the launch leaves behind is a genuine Uniswap LP NFT, held by the market's
    ///         distributor, staked on the locker's behalf, and unreachable by anyone.
    function test_fork_step3_thePositionIsARealUniswapNftLockedUnderTheLocker() public {
        Graduated memory g = _graduate();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        LpRewardDistributor dist = LpRewardDistributor(marketFactory.market(marketId).lpDistributor);

        // Uniswap's NFT, not a receipt of our own invention.
        assertEq(IPositionsNftLike(address(POSM)).name(), "Uniswap v4 Positions NFT");
        assertEq(IPositionsNftLike(address(POSM)).symbol(), "UNI-V4-POSM");
        assertEq(
            IPositionsNftLike(address(POSM)).ownerOf(g.positionId),
            address(dist),
            "the distributor custodies it"
        );
        assertEq(dist.stakerOf(g.positionId), address(locker), "and the locker is the staker");
        // Weighed as capital and the only stake in the book, but weightless in the stream:
        // recording the lock renounced the reward stream that rides alongside the position.
        assertEq(dist.positionCountOf(address(locker)), 1, "the one position is the locker's");
        assertGt(dist.stakedWeightOfPosition(g.positionId), 0, "the position carries weight");
        assertEq(dist.totalStaked(), 0, "and it draws nothing from the stream");

        // The position really is in this market's pool, over the whole range.
        (PoolKey memory key, uint256 info) = POSM.getPoolAndPositionInfo(g.positionId);
        assertEq(PoolId.unwrap(key.toId()), g.poolId, "minted into the graduated pool");
        (int24 tickLower, int24 tickUpper) = dist.fullRange();
        assertEq(int24(uint24(info >> 8)), tickLower, "full range, lower");
        assertEq(int24(uint24(info >> 32)), tickUpper, "full range, upper");

        ILaunchLocker.LockedPosition memory p = locker.lockedPosition(token);
        assertEq(p.tokenId, g.positionId);
        assertEq(p.unit, g.unit);
        assertEq(p.creatorShareBps, launchFactory.graduatedCreatorShareBps());

        // Nobody can take it out. The locker has no exit, and the distributor only unstakes
        // for the staker — which is the locker, not its owner.
        vm.prank(owner);
        (bool ok,) = address(locker).call(abi.encodeWithSignature("unstake(uint256)", g.positionId));
        assertFalse(ok, "the locker has no unstake");
        vm.prank(owner);
        vm.expectRevert(LpRewardDistributor.OnlyStaker.selector);
        dist.unstake(g.positionId);

        console.log("position id:", g.positionId);
        console.log("position liquidity:", POSM.getPositionLiquidity(g.positionId));
        console.log("supply locked forever (18dp):", locker.lockedSupply(token));
    }

    // ══ Step 4 ══ Trading the graduated market ════════════════════════════

    /// @notice A stranger buys the graduated token with USDG through the shipping router, and
    ///         the live pool moves and pays the hook's skim for it.
    ///
    ///         The router sends an exact-input swap, so the leg it does not name is the
    ///         OUTPUT, and the output of a buy is the launch token. The protocol is therefore
    ///         paid in the launched token here, not in the unit the router minted from the
    ///         stranger's USDG.
    function test_fork_step4_aRealRouterSwapMovesThePriceAndPaysTheSkim() public {
        Graduated memory g = _graduate();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        bool unitIsCurrency0 = Currency.unwrap(key.currency0) == g.unit;
        Currency unitCurrency = unitIsCurrency0 ? key.currency0 : key.currency1;
        Currency tokenCurrency = unitIsCurrency0 ? key.currency1 : key.currency0;

        (uint160 before,,,) = MANAGER.getSlot0(key.toId());

        // The skim is pips of what the pool actually pays out, so the expectation is quoted
        // off the same buy run with the hook's rate at zero rather than written as a
        // constant. A fee decrease applies immediately, and the quote is rolled back, so what
        // is measured is this pool at this depth with only the skim missing.
        uint256 usdgIn = 100e6;
        uint256 gross = _grossBuyWithoutTheSkim(marketId, usdgIn);
        uint256 expectedSkim = gross * PROTOCOL_FEE_PIPS / 1_000_000;
        assertGt(expectedSkim, 0, "a hundred dollars is large enough to owe something");

        uint256 bought = _buyWithUsdg(marketId, usdgIn);

        assertGt(bought, 0, "the stranger holds the launched token");
        assertEq(IERC20(token).balanceOf(stranger), bought);
        assertEq(bought, gross - expectedSkim, "short by the skim, and by nothing else");

        // What the curve's terminal price implies for this size, less what the trade really
        // costs: the pool's 0.50% LP fee, the hook's 0.10% of the output, and the price
        // impact of taking a hundred dollars out of a pool seeded with eight thousand.
        // Bounded on both sides, because "cheaper than the curve" would pass on a pool that
        // charged nothing and "close to the curve" would pass on a pool that charged twice.
        uint256 atTerminalPrice = usdgIn * sweptTokens / (sweptQuote + PHANTOM_QUOTE);
        assertLt(bought, atTerminalPrice, "the trade paid the fees and the impact");
        assertApproxEqRel(bought, atTerminalPrice, 0.03e18, "priced off the curve's end");

        // The price moved in the direction a buy moves it.
        (uint160 afterBuy,,,) = MANAGER.getSlot0(key.toId());
        if (unitIsCurrency0) assertLt(afterBuy, before, "unit in, token out: price down");
        else assertGt(afterBuy, before, "unit in, token out: price up");

        assertEq(feeHook.pendingFees(key.toId(), tokenCurrency), expectedSkim, "skimmed");
        assertEq(feeHook.pendingFees(key.toId(), unitCurrency), 0, "and not off the unit it paid");
        assertEq(MANAGER.balanceOf(address(feeHook), tokenCurrency.toId()), expectedSkim);

        // Permissionless collection, into the protocol treasury.
        vm.prank(stranger);
        feeHook.collect(key);
        assertEq(IERC20(token).balanceOf(protocolTreasury), expectedSkim, "to the treasury");
        assertEq(feeHook.pendingFees(key.toId(), tokenCurrency), 0, "claims cleared");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router holds nothing");
        assertEq(IERC20(g.unit).balanceOf(address(router)), 0);

        console.log("USDG in:", usdgIn);
        console.log("launch tokens out:", bought);
        console.log("hook skim, launch-token base units:", expectedSkim);
    }

    // ══ Step 5 ══ What the lock earns ═════════════════════════════════════

    /// @notice The locked position earns like any other LP, and `LaunchLocker.collect` turns
    ///         that into claimable balances for the creator and the protocol.
    ///
    ///         The fees are real: Uniswap's own arithmetic, collected out of the deployed
    ///         `PositionManager` by `LpRewardDistributor.collectFees`. There is no second leg.
    ///         The lock renounced its reward stream when it was recorded, so the float yield
    ///         behind the quote brand stays with the market's other liquidity providers and
    ///         never passes through here.
    function test_fork_step5_realFeesReachTheEscrow() public {
        Graduated memory g = _graduate();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        AssetMarketFactory.Market memory m = marketFactory.market(marketId);
        LpRewardDistributor dist = LpRewardDistributor(m.lpDistributor);

        // Trade both ways, so the position accrues fees in the unit and in the token.
        _tradeBothWays(marketId, g.unit, 400e6);

        uint256 lockedBefore = locker.lockedSupply(token);
        // Graduation may already have parked the mint's unit dust in the escrow, so every
        // escrow claim below is asserted as a delta rather than as a total.
        uint256 creatorUnitBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, g.unit);
        uint256 protocolUnitBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, g.unit);
        uint256 creatorTokenBefore = feeEscrow.balanceOfToken(creatorFeeRecipient, token);
        uint256 protocolTokenBefore = feeEscrow.balanceOfToken(protocolFeeRecipient, token);
        (uint256 unitOut, uint256 tokenOut) = locker.collect(token);

        assertGt(unitOut, 0, "unit-side swap fees");
        assertGt(tokenOut, 0, "token-side swap fees");

        // Three recipients on one rate each: the creator takes the share the launch was sold
        // on and snapshotted into the lock, the LP fund its live share out of the protocol's
        // remainder, and the protocol keeps what is left. The rates are read back off the
        // factory and the locked position rather than restated here, so retuning one moves
        // the expectation instead of breaking the test.
        uint16 creatorBps = locker.lockedPosition(token).creatorShareBps;
        uint16 fundBps = launchFactory.graduatedLpFundShareBps();

        uint256 creatorUnit = unitOut * creatorBps / 10_000;
        uint256 fundUnit = unitOut * fundBps / 10_000;
        uint256 creatorToken = tokenOut * creatorBps / 10_000;
        uint256 fundToken = tokenOut * fundBps / 10_000;

        assertGt(creatorUnit, 0, "the creator earned on the unit leg");
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, g.unit) - creatorUnitBefore, creatorUnit
        );
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, g.unit) - protocolUnitBefore,
            unitOut - creatorUnit - fundUnit,
            "the protocol keeps the remainder of the unit leg"
        );
        assertEq(
            feeEscrow.balanceOfToken(creatorFeeRecipient, token) - creatorTokenBefore, creatorToken
        );
        assertEq(
            feeEscrow.balanceOfToken(protocolFeeRecipient, token) - protocolTokenBefore,
            tokenOut - creatorToken - fundToken
        );

        // The escrow is a pull ledger, and it really pays.
        uint256 creatorUnitTotal = creatorUnitBefore + creatorUnit;
        vm.prank(creatorFeeRecipient);
        assertEq(feeEscrow.claimToken(g.unit), creatorUnitTotal, "the creator claims the unit");
        assertEq(IERC20(g.unit).balanceOf(creatorFeeRecipient), creatorUnitTotal);

        // Collecting moved neither the position nor the locked supply.
        assertEq(dist.stakerOf(g.positionId), address(locker));
        assertEq(locker.lockedSupply(token), lockedBefore, "the lock is untouched");
        assertEq(IERC20(token).balanceOf(address(locker)), lockedBefore, "and fully backed");

        console.log("collected in the unit (6dp):", unitOut);
        console.log("collected in the launch token (18dp):", tokenOut);
    }

    // ══ The whole thing ═══════════════════════════════════════════════════

    /// @notice Every step in order, on one launch, with nothing funded by hand beyond the
    ///         starting balances real traders would already hold.
    ///
    ///         It ends on the accounting: every base unit of the quote brand the curve
    ///         collected is either liquidity in the pool, the protocol's dust in the escrow or
    ///         already claimed, and every base unit of supply is in the pool, in the lock or in
    ///         a holder's wallet.
    function test_fork_theWholeJourneyEndToEnd() public {
        // 1. The curve, from four wallets.
        uint256 aliceOut = _buy(alice, 1_000e6);
        uint256 bobOut = _buy(bob, 2_500e6);
        uint256 carolOut = _buy(carol, 1_000e6);
        uint256 whaleOut = _buy(whale, GRADUATION_THRESHOLD * 2);
        uint256 circulating = aliceOut + bobOut + carolOut + whaleOut;

        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        assertEq(uint8(launch.phase), uint8(GraduationPhase.Swept), "the crossing buy swept");

        // The curve's fees were swept into the escrow as part of phase one, under the policy
        // snapshotted at launch.
        uint256 protocolFees = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand);
        uint256 creatorFees = feeEscrow.balanceOfToken(creatorFeeRecipient, quoteBrand);
        assertGt(protocolFees, 0, "the protocol earned on the curve");
        assertGt(creatorFees, protocolFees, "and the creator earned the larger share");

        // 2. The market.
        Graduated memory g = _graduate();
        uint256 marketId = launchFactory.getLaunchedToken(token).marketId;
        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        (uint160 openedAt,,,) = MANAGER.getSlot0(key.toId());
        assertGt(openedAt, 0, "the pool is live on the singleton");

        // Quote side: the raise stays in the brand it was raised in, and what the mint could
        // not take is the protocol's dust in the escrow. The curve's own fees were credited
        // to the same recipient in the same brand before the sweep, so they are netted out
        // rather than counted against the seed twice. The quote brand is now shared across
        // all three income sources, so this has to stay a delta: `protocolFees` is the
        // snapshot taken right after the sweep, and the only escrow credit between it and
        // this read is the mint's dust (`LaunchGraduation._parkDust`). The locked position's
        // fees are not collected until step 4, and the hook's skim goes to the market
        // treasury rather than the escrow, so neither lands inside this window.
        uint256 unitDust = feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand) - protocolFees;
        assertEq(g.unitSeeded + unitDust, launch.sweptQuote, "every unit accounted for");
        // Supply side: the pool, the lock, and the wallets that bought on the curve.
        assertEq(g.tokensSeeded + g.tokensLocked, launch.sweptTokens, "every token accounted for");
        assertEq(
            IERC20(token).totalSupply(),
            circulating + g.tokensSeeded + g.tokensLocked,
            "supply is the pool, the lock and the holders"
        );

        // 3. Trading, through the shipping router.
        _fundUsdg(stranger, 500e6);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(router), 500e6);
        uint256 bought =
            router.buyWithUsdg(marketId, 500e6, 0, stranger, vm.getBlockTimestamp() + 1 hours);
        IERC20(token).approve(address(router), bought);
        uint256 backInUnits =
            router.sellForBrand(marketId, bought, 0, stranger, vm.getBlockTimestamp() + 1 hours);
        vm.stopPrank();
        assertGt(bought, 0, "bought");
        assertLt(backInUnits, 500e6, "and paid the round trip's fees");

        (uint160 afterTrading,,,) = MANAGER.getSlot0(key.toId());
        assertTrue(afterTrading != openedAt, "the live pool moved");

        // 4. Income: the hook's skim to the protocol, and the locked position's swap fees.
        (uint256 skim0, uint256 skim1) = feeHook.collect(key);
        assertGt(skim0 + skim1, 0, "both legs of the round trip paid the skim");

        (uint256 unitOut, uint256 tokenOut) = locker.collect(token);
        assertGt(unitOut, 0, "the lock earned in the unit");
        assertGt(tokenOut, 0, "and in the token");

        // 5. Everyone takes their money home, from one ledger. The curve's fees and the
        //    position's unit-side fees are the same brand now, so one claim settles both.
        //
        //    The quote brand is now shared across all three income sources — the curve's
        //    fees, the graduation dust and the locked position's unit leg — and the protocol
        //    additionally holds the launch fee, which `launchToken` pays it directly rather
        //    than through the escrow. An absolute balance therefore no longer isolates the
        //    claim, so both claims are measured as a delta across the claim itself.
        uint256 creatorBrandBefore = IERC20(quoteBrand).balanceOf(creatorFeeRecipient);
        uint256 protocolBrandBefore = IERC20(quoteBrand).balanceOf(protocolFeeRecipient);
        assertEq(creatorBrandBefore, 0, "the creator is paid only through the escrow");
        assertEq(
            protocolBrandBefore,
            LAUNCH_FEE,
            "the only brand the protocol holds outside the escrow is the launch fee"
        );

        vm.prank(creatorFeeRecipient);
        uint256 creatorBrand = feeEscrow.claimToken(quoteBrand);
        vm.prank(creatorFeeRecipient);
        uint256 creatorToken = feeEscrow.claimToken(token);
        vm.prank(protocolFeeRecipient);
        uint256 protocolBrand = feeEscrow.claimToken(quoteBrand);
        assertGt(creatorBrand, creatorFees, "the curve fees plus the position's unit leg");
        assertGt(creatorToken, 0, "and the position's token leg");
        // The escrow paid out exactly what it credited, and the recipient now holds it. The
        // quote brand is shared across all three income sources, so an absolute balance can
        // no longer isolate this one claim.
        assertEq(
            IERC20(quoteBrand).balanceOf(creatorFeeRecipient) - creatorBrandBefore, creatorBrand
        );
        assertEq(
            IERC20(quoteBrand).balanceOf(protocolFeeRecipient) - protocolBrandBefore, protocolBrand
        );

        // The launch's own contracts end holding nothing but the lock.
        assertEq(IERC20(quoteBrand).balanceOf(address(launchFactory)), 0);
        assertEq(IERC20(token).balanceOf(address(launchFactory)), 0);
        assertEq(IERC20(token).balanceOf(address(graduation)), 0);
        assertEq(IERC20(g.unit).balanceOf(address(graduation)), 0);
        assertEq(IERC20(token).balanceOf(address(locker)), locker.lockedSupply(token));

        console.log("--- the journey ---");
        console.log("curve fees to the protocol (brand, 6dp):", protocolFees);
        console.log("curve fees to the creator (brand, 6dp):", creatorFees);
        console.log("unit seeded into the live pool:", g.unitSeeded);
        console.log("tokens seeded into the live pool:", g.tokensSeeded);
        console.log("tokens locked forever:", g.tokensLocked);
        console.log("hook skim collected, currency0:", skim0);
        console.log("hook skim collected, currency1:", skim1);
        console.log("locked position income, unit:", unitOut);
        console.log("locked position income, token:", tokenOut);
    }

    // ─── Deployment helpers ──────────────────────────────────────────────

    /// @dev The launchpad, in the order the addresses require and with the same one-shot wiring
    ///      `ProtocolStack.deployLaunchpad` performs: the factory proxy first, because the
    ///      locker, the graduation module and the deployer all take its address in their
    ///      constructors, then the wiring in both directions.
    function _deployLaunchpad() internal {
        feeEscrow = new LaunchFeeEscrow();
        launchFactory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(new LaunchFactory()),
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            address(protocolGuard),
                            marketFactory,
                            POSM,
                            ILaunchFeeEscrow(address(feeEscrow))
                        )
                    )
                )
            )
        );
        locker = new LaunchLocker(owner, address(launchFactory));
        graduation = new LaunchGraduation(
            address(launchFactory),
            marketFactory,
            POSM,
            PERMIT2,
            ILaunchLocker(address(locker)),
            ILaunchFeeEscrow(address(feeEscrow))
        );
        launchDeployer = new LaunchDeployer(address(launchFactory));

        vm.startPrank(owner);
        locker.setGraduation(address(graduation));
        launchFactory.setLaunchDeployer(launchDeployer);
        launchFactory.setGraduation(ILaunchGraduation(address(graduation)));
        launchFactory.setProtocolFeeRecipient(protocolFeeRecipient);
        launchFactory.setLaunchEnabled(true);
        launchConfigId = launchFactory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: LAUNCH_SUPPLY, curveFeeBps: CURVE_FEE_BPS, poolFee: POOL_FEE, enabled: true
            })
        );
        vm.stopPrank();

        // The graduation module is the address the market factory lets through
        // `createLaunchMarket`, exactly as the deploy script registers it.
        _setLaunchpad(marketFactory, address(graduation));
    }

    /// @dev The hook, at a mined address, through the chain's deterministic deployment proxy.
    ///
    ///      The sibling fork suites place their hook with `deployCodeTo`, which is enough to
    ///      exercise `Hooks.validateHookPermissions` but says nothing about the deployment the
    ///      product actually performs. Here the salt is mined by the same library the deploy
    ///      script uses and the proxy is created by the same CREATE2 factory, so what runs is
    ///      the shipping path against the live chain's own deployer — including the check that
    ///      the mined address is not already occupied on mainnet.
    function _deployMinedHook() internal returns (ProtocolFeeHook) {
        address impl = ProtocolStack.deployHookImplementation();
        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(
                impl,
                abi.encodeCall(ProtocolFeeHook.initialize, (MANAGER, owner, address(protocolGuard)))
            )
        );
        (address mined, bytes32 salt) =
            HookSaltMiner.mine(HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS, initCode);
        require(mined.code.length == 0, "mined hook address is occupied on the live chain");

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20, "CREATE2 deployment of the hook failed");
        address deployed = address(bytes20(ret));
        require(deployed == mined, "the hook did not land on its mined address");
        assertEq(
            uint160(deployed) & Hooks.ALL_HOOK_MASK,
            HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS,
            "the hook carries its own permission bits"
        );
        return ProtocolFeeHook(deployed);
    }

    // ─── Money ───────────────────────────────────────────────────────────

    /// @dev Morpho Blue custodies tens of millions of USDG on this chain.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    /// @dev Put `amount` of the quote brand in `who`'s wallet, minted 1:1 from real USDG at the
    ///      reserve the way a person would. Returns their resulting balance.
    function _fundQuote(address who, uint256 amount) internal returns (uint256) {
        _fundUsdg(who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(reserve), amount);
        reserve.mint(quoteBrand, amount, who);
        vm.stopPrank();
        return IERC20(quoteBrand).balanceOf(who);
    }

    /// @dev Real Morpho interest. Its `market()` is a plain storage read, so warping alone
    ///      compounds nothing; `accrueInterest` forces what the next real supply would have done.
    function _accrueMorpho(uint256 elapsed) internal {
        vm.warp(vm.getBlockTimestamp() + elapsed);
        IMorphoAccrue m = IMorphoAccrue(MORPHO_BLUE);
        m.accrueInterest(m.idToMarketParams(USDE_MARKET_ID));
    }

    // ─── The launch ──────────────────────────────────────────────────────

    /// @dev A launch as the creator sends it, paying the launch fee in the quote brand, then
    ///      past the snipe-tax window so the buys that follow trade at the untaxed price.
    function _launch() internal returns (address token_, address curve_) {
        _fundQuote(creator, LAUNCH_FEE);
        LaunchFactory.TokenParams memory params = LaunchFactory.TokenParams({
            name: "Cashcat",
            symbol: "CAT",
            logo: "ipfs://bafkreicashcat",
            description: "The cat that pays for itself.",
            socials: LaunchToken.Socials({
                twitter: "https://x.com/cashcat",
                telegram: "",
                discord: "",
                website: "",
                farcaster: ""
            }),
            creatorFeeRecipient: creatorFeeRecipient,
            creatorTaxBps: 100,
            expectedEconomics: launchFactory.previewLaunchEconomics(launchConfigId, quoteBrand),
            salt: keccak256("cashcat")
        });

        (address predictedToken, address predictedCurve) =
            launchFactory.predictLaunchAddresses(params, launchConfigId, quoteBrand, creator);

        vm.startPrank(creator);
        IERC20(quoteBrand).approve(address(launchFactory), LAUNCH_FEE);
        (token_, curve_) =
            launchFactory.launchToken(params, launchConfigId, quoteBrand, new address[](0));
        vm.stopPrank();

        assertEq(token_, predictedToken, "the token landed where it was predicted to");
        assertEq(curve_, predictedCurve, "and so did its curve");
        assertEq(IERC20(token_).totalSupply(), LAUNCH_SUPPLY, "the configured supply");
        assertEq(IERC20(token_).balanceOf(curve_), LAUNCH_SUPPLY, "all of it on the curve");

        vm.warp(vm.getBlockTimestamp() + launchFactory.snipeTaxSeconds() + 1);
    }

    /// @dev A curve buy by `who` with freshly minted quote. What a threshold-crossing buy does
    ///      not spend comes back to them.
    function _buy(address who, uint256 quoteIn) internal returns (uint256 tokensOut) {
        _fundQuote(who, quoteIn);
        vm.startPrank(who);
        IERC20(quoteBrand).approve(curve, quoteIn);
        tokensOut = LaunchCurve(curve).buy(quoteIn, 0, who);
        vm.stopPrank();
    }

    /// @dev `Result` as the `PoolGraduated` event carries it, minus the indexed market id.
    struct Graduated {
        address unit;
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked;
    }

    /// @dev Fill the curve if it is not already full, then phase two, with the event captured:
    ///      `graduateToMarket` returns nothing and the seed figures exist only here.
    ///
    ///      The swept totals are snapshotted first because phase two zeroes them on the launch
    ///      record — it has handed them over, and a record that still claimed them would be a
    ///      second claim on the same money. Everything downstream that reconciles against them
    ///      reads `sweptQuote`/`sweptTokens` here.
    function _graduate() internal returns (Graduated memory g) {
        if (!LaunchCurve(curve).graduated()) _buy(whale, GRADUATION_THRESHOLD * 2);
        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        sweptQuote = launch.sweptQuote;
        sweptTokens = launch.sweptTokens;

        vm.recordLogs();
        launchFactory.graduateToMarket(token);

        bytes32 sig = keccak256(
            "PoolGraduated(address,uint256,address,bytes32,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(launchFactory) || logs[i].topics[0] != sig) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "event token");
            (g.unit, g.poolId, g.positionId, g.unitSeeded, g.tokensSeeded, g.tokensLocked) =
                abi.decode(logs[i].data, (address, bytes32, uint256, uint256, uint256, uint256));
            return g;
        }
        revert("PoolGraduated not emitted");
    }

    /// @dev The price the pool should open at, derived from the curve's terminal reserves
    ///      rather than from the graduation module's own arithmetic: `(quote + phantom)` of the
    ///      brand against the whole swept supply, expressed as one whole token in whole units
    ///      × 1e18.
    function _terminalSqrtPrice(address unit) internal view returns (uint160) {
        uint256 priceE18 = (sweptQuote + PHANTOM_QUOTE) * 1e18 * 1e18 / (sweptTokens * 1e6);
        return marketFactory.quoteSqrtPriceX96(unit, token, priceE18);
    }

    /// @dev A stranger's buy through the shipping router, funded with real USDG.
    function _buyWithUsdg(uint256 marketId, uint256 usdgIn) internal returns (uint256 bought) {
        _fundUsdg(stranger, usdgIn);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(router), usdgIn);
        bought = router.buyWithUsdg(marketId, usdgIn, 0, stranger, vm.getBlockTimestamp() + 1 hours);
        vm.stopPrank();
    }

    /// @dev What that buy yields with the hook's cut switched off, measured on a state
    ///      snapshot and rolled back.
    ///
    ///      A fee DECREASE applies immediately, so the quote comes off the identical pool at
    ///      identical depth paying the identical LP fee, with only the skim missing: this
    ///      suite's stand-in for a hookless twin pool, and the reason step 4's expectation is
    ///      an independently measured number rather than a restatement of the hook's own
    ///      arithmetic.
    function _grossBuyWithoutTheSkim(uint256 marketId, uint256 usdgIn)
        internal
        returns (uint256 gross)
    {
        // Hoisted: `vm.prank` arms the very next call, and an inline `poolKeyOf` would be the
        // call it caught.
        PoolId id = marketFactory.poolKeyOf(marketId).toId();
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        feeHook.setPoolFeePips(id, 0);
        gross = _buyWithUsdg(marketId, usdgIn);
        vm.revertToState(snap);
    }

    /// @dev A round trip through the graduated pool with v4-core's own reference router, so the
    ///      fees the locked position earns are Uniswap's arithmetic and the caller is not ours.
    function _tradeBothWays(uint256 marketId, address unit, uint256 unitIn) internal {
        _fundUsdg(stranger, unitIn);
        vm.startPrank(stranger);
        IERC20(USDG).approve(address(reserve), unitIn);
        reserve.mint(unit, unitIn, stranger);
        vm.stopPrank();

        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        uint256 tokenBefore = IERC20(token).balanceOf(stranger);
        _swap(key, unit, unitIn);
        _swap(key, token, IERC20(token).balanceOf(stranger) - tokenBefore);
    }

    function _swap(PoolKey memory key, address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);
        vm.startPrank(stranger);
        IERC20(tokenIn).approve(address(poolSwap), amountIn);
        poolSwap.swap(
            key,
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
}
