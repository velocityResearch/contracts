// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {LiquidityZapper} from "../../src/markets/LiquidityZapper.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAsset, MockSwapRouter02} from "./mocks/MockBuybackVenue.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";
import {StackFixture} from "../helpers/StackFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "oz-upgradeable/access/OwnableUpgradeable.sol";

// The venue stand-ins are declared in the router's suite and shared rather than copied: what they
// model — a yield source that can come back a wei short, a Permit2 that records approvals, a
// PositionManager that mints against the real PoolManager — is the same for both contracts, and
// two drifting copies would be two different claims about the same chain.
import {ShortingYieldSource, StandInPermit2, StandInPositionManager} from "./MarketRouter.t.sol";

/// @notice `LiquidityZapper` against a full local stack.
///
///         Three things are being proved here. The first is the zap itself: USDG in, an LP NFT
///         out, both sides paid for, nothing kept. The second is that it needs no cooperation
///         from anything already deployed — no registration, no role, no upgrade, no change to
///         a market that was created before this contract's address existed, asserted directly
///         in `test_worksOnAMarketCreatedBeforeTheZapperExisted`.
///
///         The third is new, and is why this generation of the contract exists: **neither door
///         can be entered without a slippage bound**, and the contract can now be paused,
///         upgraded and handed over. The first deployment could do none of that, which is how
///         it came to be live, sandwichable and unfixable at the same time.
contract LiquidityZapperTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    uint24 constant PROTOCOL_FEE_PIPS = 1000; // 0.10%
    uint256 constant PRICE_E18 = 1e18;
    uint256 constant SEED_USDG = 500_000e6;
    uint256 constant SEED_ASSET = 500_000e18;

    /// @dev A token bound, for the tests whose subject is not slippage. Both doors reject zero
    ///      now, so every call has to name something; one liquidity unit and one base unit of
    ///      USDG are the smallest numbers that are still a bound.
    uint128 constant ANY_LIQUIDITY = 1;
    uint256 constant ANY_SALE = 1;

    PoolManager manager;
    ProtocolFeeHook hook;
    StandInPermit2 permit2;
    StandInPositionManager posm;

    MockUSDC usdg;
    ShortingYieldSource yieldSource;
    SharedReservePool reserve;
    AssetMarketFactory factory;
    MarketRouter router;
    LiquidityZapper zapper;

    /// @dev Deployed once and reused by every proxy below, for the reason `StackFixture` gives:
    ///      a test that writes `vm.expectRevert` before a bad initialisation needs the very next
    ///      creation to be the one that reverts, and a fresh implementation in that position
    ///      would succeed and consume the expectation.
    address zapperImpl;

    /// @dev The ETH door's venue: a wrapper and a v3 router that sells it for USDG. Separate from
    ///      the market's own v4 pool, exactly as on chain — WETH/USDG is a Uniswap v3 pair and
    ///      the market is v4.
    MockWETH9 weth;
    MockSwapRouter02 v3Router;

    /// @dev What `v3Router` pays per wei of WETH, in USDG base units. 3000e6 USDG per 1e18 wei is
    ///      $3,000/ETH, which makes the arithmetic in the ETH tests readable.
    uint256 constant ETH_PRICE_E18 = 3_000e6;
    uint24 constant V3_FEE = 500;

    MockAsset asset;
    uint256 marketId;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address operator = address(0x0FE);
    address lp = address(0x11B0);
    /// @dev The wallet under test: it holds USDG and has never held the market's asset.
    address provider = address(0xB0B);

    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        hook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x7777 << 144)
            ),
            IPoolManager(address(manager)),
            owner
        );

        usdg = new MockUSDC();
        yieldSource = new ShortingYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        // The periphery pair is built first now: the factory takes the `PositionManager` it
        // hands to every market's reward distributor, so it cannot be deployed before one
        // exists.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        factory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            0,
            owner
        );

        vm.startPrank(owner);
        hook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        router = _deployRouter(
            reserve, factory, IPositionManagerV4(address(posm)), IPermit2(address(permit2)), owner
        );

        asset = new MockAsset();
        marketId = _createMarket("Cashcat Dollar", "catUSD", address(asset));
        _seedThroughRouter(marketId, SEED_USDG, SEED_ASSET);

        weth = new MockWETH9();
        v3Router = new MockSwapRouter02(address(0xF00D));
        v3Router.setWETH9(address(weth));
        v3Router.setRateE18(ETH_PRICE_E18);
        // The venue's own inventory. A real v3 pool holds the USDG it pays out; this one is
        // handed enough to answer every sale in this suite.
        usdg.mint(address(v3Router), 10_000_000e6);

        // Deployed LAST, on purpose. The market above already exists, is already seeded and has
        // never heard of this address. Every test below runs against it.
        zapperImpl = address(new LiquidityZapper());
        zapper = _newZapper(
            reserve,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(v3Router))
        );
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev The owner lists the asset, then anyone opens its market. The `operator` prank is
    ///      kept only so the market has a `creator` this suite can name.
    function _createMarket(string memory name, string memory symbol, address assetToken)
        internal
        returns (uint256 id)
    {
        _approveAsset(
            factory, assetToken, FEE, PRICE_E18, FIXTURE_MIN_OBSERVATION_CARDINALITY, name, symbol
        );
        vm.prank(operator);
        (id,,,,) = factory.createMarket(assetToken, address(0));
    }

    /// @dev A zapper proxy over the shared implementation, initialised with the wiring a test
    ///      wants to vary. Exactly one contract is created here, so `vm.expectRevert` placed
    ///      immediately before a call binds to the initialisation and not to something else.
    function _newZapper(
        SharedReservePool reservePool_,
        IPositionManagerV4 posm_,
        IPermit2 permit2_,
        ISwapRouter02 swapRouter_
    ) internal returns (LiquidityZapper) {
        return LiquidityZapper(
            payable(address(
                    new ERC1967Proxy(
                        zapperImpl,
                        abi.encodeCall(
                            LiquidityZapper.initialize,
                            (
                                reservePool_,
                                factory,
                                posm_,
                                permit2_,
                                swapRouter_,
                                owner,
                                address(protocolGuard)
                            )
                        )
                    )
                ))
        );
    }

    function _seedThroughRouter(uint256 id, uint256 usdgAmount, uint256 assetAmount) internal {
        AssetMarketFactory.Market memory m = factory.market(id);
        usdg.mint(lp, usdgAmount);
        MockAsset(m.asset).mint(lp, assetAmount);

        vm.startPrank(lp);
        usdg.approve(address(reserve), usdgAmount);
        uint256 brandAmount = reserve.mint(m.brandToken, usdgAmount, lp);
        IERC20(m.brandToken).approve(address(router), brandAmount);
        IERC20(m.asset).approve(address(router), assetAmount);
        router.seedLiquidity(id, brandAmount, assetAmount, 0, 0, block.timestamp + 600);
        vm.stopPrank();
    }

    function _zap(uint256 id, uint256 usdgIn, uint128 minLiquidity)
        internal
        returns (uint256 tokenId, uint128 added, uint256 brandUsed, uint256 assetUsed)
    {
        usdg.mint(provider, usdgIn);
        vm.startPrank(provider);
        usdg.approve(address(zapper), usdgIn);
        (tokenId, added, brandUsed, assetUsed) =
            zapper.zapLiquidity(id, usdgIn, 5_000, minLiquidity, block.timestamp + 600);
        vm.stopPrank();
    }

    function _zapWithEth(uint256 id, uint256 ethIn, uint256 minUsdgOut, uint128 minLiquidity)
        internal
        returns (uint256 tokenId, uint128 added, uint256 brandUsed, uint256 assetUsed)
    {
        vm.deal(provider, provider.balance + ethIn);
        vm.prank(provider);
        (tokenId, added, brandUsed, assetUsed) = zapper.zapLiquidityWithEth{value: ethIn}(
            id, V3_FEE, minUsdgOut, 5_000, minLiquidity, block.timestamp + 600
        );
    }

    // ─── The claim the contract exists for ───────────────────────────────

    /// @notice No redeploy, no registration, no opt-in. The market under test was created and
    ///         seeded before this zapper was constructed, and the brand token, the pool, the
    ///         factory record and the router are all untouched by its arrival.
    function test_worksOnAMarketCreatedBeforeTheZapperExisted() public {
        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertLt(m.createdAt, block.timestamp + 1, "the market predates this call");

        uint128 depthBefore = router.marketLiquidity(marketId);
        (uint256 tokenId, uint128 added,,) = _zap(marketId, 1_000e6, ANY_LIQUIDITY);

        assertGt(added, 0, "a position was minted into the existing pool");
        assertEq(posm.ownerOf(tokenId), provider, "and the provider owns it");
        assertEq(
            router.marketLiquidity(marketId),
            depthBefore + added,
            "the same pool the router reports is the one that got deeper"
        );
    }

    /// @notice The zapper is not privileged anywhere, which is what let it be a separate contract.
    ///         It holds no role on the reserve, is not the market's creator, and the market's
    ///         wiring names it nowhere.
    function test_theZapperHoldsNoPrivilegeAnywhereInTheStack() public view {
        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertTrue(m.creator != address(zapper), "not the market's creator");
        assertTrue(m.treasury != address(zapper), "not its treasury");
        assertTrue(m.feeVault != address(zapper), "not its fee vault");
        assertTrue(m.lpDistributor != address(zapper), "nor its LP reward distributor");
        assertTrue(reserve.owner() != address(zapper), "no ownership of the reserve");
        assertTrue(factory.owner() != address(zapper), "nor of the factory");
    }

    /// @notice A second zapper deployed alongside the first works just as well. Nothing binds a
    ///         market to one of these, which is what makes replacing it a deployment rather than
    ///         a migration.
    function test_aSecondZapperWorksWithoutRetiringTheFirst() public {
        _zap(marketId, 500e6, ANY_LIQUIDITY);

        LiquidityZapper other = _newZapper(
            reserve,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(v3Router))
        );
        usdg.mint(provider, 500e6);
        vm.startPrank(provider);
        usdg.approve(address(other), 500e6);
        (, uint128 added,,) =
            other.zapLiquidity(marketId, 500e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();

        assertGt(added, 0, "the second one needed no blessing from the first");
    }

    // ─── The zap ─────────────────────────────────────────────────────────

    function test_zapTurnsUsdgAloneIntoATwoSidedPosition() public {
        assertEq(asset.balanceOf(provider), 0, "the provider holds none of the asset");

        uint256 usdgIn = 1_000e6;
        uint256 expectedId = posm.nextTokenId();
        (uint256 tokenId, uint128 added, uint256 brandUsed, uint256 assetUsed) =
            _zap(marketId, usdgIn, ANY_LIQUIDITY);

        assertEq(tokenId, expectedId, "the id returned is the id that was minted");
        assertEq(posm.ownerOf(tokenId), provider, "the provider owns it, not the zapper");
        assertGt(added, 0, "the position carries liquidity");
        assertGt(brandUsed, 0, "paid for on the stable side");
        assertGt(assetUsed, 0, "and on the asset side, bought inside the call");

        // Roughly half the dollar went each way. The asset side is always a little short of half
        // because the swap pays the LP fee and the hook's skim and moves the price against
        // itself, which is why the remainder is refunded rather than forced in.
        assertApproxEqRel(brandUsed, usdgIn / 2, 0.1e18, "about half stayed stable");
    }

    function test_theZapperKeepsNothingAndRefundsInThePoolsOwnDollar() public {
        AssetMarketFactory.Market memory m = factory.market(marketId);
        uint256 usdgIn = 1_000e6;
        (,, uint256 brandUsed, uint256 assetUsed) = _zap(marketId, usdgIn, ANY_LIQUIDITY);

        // Every dollar accounted for: half bought the asset, most of the rest became the stable
        // side, and the sliver the price could not use came home as the market's own dollar.
        assertEq(
            IERC20(m.brandToken).balanceOf(provider) + brandUsed + usdgIn / 2,
            usdgIn,
            "the unspent stable side came home as brandUSD"
        );
        assertGt(IERC20(m.brandToken).balanceOf(provider), 0, "there was a remainder to return");
        // Not redeemed on the provider's behalf. A reserve may charge for an exit, and a
        // remainder the pool declined is not the provider asking to leave it.
        assertEq(usdg.balanceOf(provider), 0, "and never as USDG");
        assertGt(assetUsed, 0, "the asset side reached the pool");

        assertEq(usdg.balanceOf(address(zapper)), 0, "the zapper keeps no USDG");
        assertEq(IERC20(m.brandToken).balanceOf(address(zapper)), 0, "no brandUSD");
        assertEq(asset.balanceOf(address(zapper)), 0, "and none of the asset");
        assertEq(posm.balanceOf(address(zapper)), 0, "and no position");
    }

    /// @notice `minLiquidity` is the caller's slippage bound, and it is on the position rather
    ///         than on the swap: what a zapper is exposed to is the price the pool moved to while
    ///         they were buying into it, and only the minted liquidity measures that.
    function test_zapHonoursItsLiquidityMinimum() public {
        (, uint128 added,,) = _zap(marketId, 1_000e6, ANY_LIQUIDITY);

        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);
        vm.expectPartialRevert(LiquidityZapper.InsufficientLiquidityMinted.selector);
        zapper.zapLiquidity(marketId, 1_000e6, 5_000, added * 2, block.timestamp + 600);
        vm.stopPrank();
    }

    /// @notice An empty pool cannot be zapped into. The swap fills nothing, so there is no asset
    ///         side to deposit, and saying so beats minting a position out of half the money.
    function test_zapRefusesAMarketWithNoDepthToBuyFrom() public {
        uint256 fresh = _createMarket("Hollow Dollar", "hlwUSD", address(new MockAsset()));

        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);
        vm.expectRevert(LiquidityZapper.NoLiquidity.selector);
        zapper.zapLiquidity(fresh, 1_000e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();
    }

    function test_zapRejectsASwapShareOutsideItsRange() public {
        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(LiquidityZapper.InvalidSwapShare.selector, uint256(0))
        );
        zapper.zapLiquidity(marketId, 1_000e6, 0, ANY_LIQUIDITY, block.timestamp + 600);

        vm.expectRevert(
            abi.encodeWithSelector(LiquidityZapper.InvalidSwapShare.selector, uint256(10_000))
        );
        zapper.zapLiquidity(marketId, 1_000e6, 10_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();
    }

    function test_zapRejectsAnExpiredDeadlineAndAZeroAmount() public {
        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);

        vm.expectRevert(LiquidityZapper.DeadlineExpired.selector);
        zapper.zapLiquidity(marketId, 1_000e6, 5_000, ANY_LIQUIDITY, block.timestamp - 1);

        vm.expectRevert(LiquidityZapper.ZeroAmount.selector);
        zapper.zapLiquidity(marketId, 0, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();
    }

    /// @notice A global halt stops the zap. It reaches it twice over now — the entry point is
    ///         `whenNotPaused` and `SharedReservePool.mint` still is too — and the outer one is
    ///         what makes the failure cheap: nothing is transferred, approved or minted first.
    function test_aPausedProtocolStopsTheZap() public {
        _pauseProtocol();

        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);
        vm.expectRevert();
        zapper.zapLiquidity(marketId, 1_000e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();

        _unpauseProtocol();
        (, uint128 added,,) = _zap(marketId, 1_000e6, ANY_LIQUIDITY);
        assertGt(added, 0, "and it works again once the protocol does");
    }

    /// @notice The lever the first, ownerless deployment did not have: halting the zapper alone.
    ///         A defect in this contract used to be stoppable only by pausing the reserve, which
    ///         stops every mint in the protocol — so in practice it was not stoppable at all.
    function test_theGuardianCanHaltTheZapperWithoutHaltingTheProtocol() public {
        vm.prank(stackGuardian);
        protocolGuard.pauseTarget(address(zapper));

        assertTrue(zapper.paused(), "the zapper is halted");
        assertFalse(protocolGuard.paused(), "and the protocol is not");

        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(zapper), 1_000e6);
        vm.expectRevert();
        zapper.zapLiquidity(marketId, 1_000e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();

        // The rest of the protocol is untouched by that halt: the reserve still mints, which is
        // the whole difference between this switch and the blunt one.
        usdg.mint(provider, 100e6);
        vm.startPrank(provider);
        usdg.approve(address(reserve), 100e6);
        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertGt(reserve.mint(m.brandToken, 100e6, provider), 0, "the reserve still works");
        vm.stopPrank();
    }

    /// @notice Only the PoolManager may call back into an unlock this contract opened. Anyone
    ///         else reaching `unlockCallback` would be settling deltas that are not theirs.
    function test_unlockCallbackRejectsEveryCallerButThePoolManager() public {
        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.OnlyPoolManager.selector);
        zapper.unlockCallback("");
    }

    // ─── Slippage: the finding this generation exists to fix ─────────────

    /// @notice The USDG door refuses a caller who names no bound. The first deployment accepted
    ///         it, which is what made that contract sandwichable: the whole deposit was minted
    ///         at whatever price the pool had been pushed to.
    ///
    ///         Asserted with no approval in place, which is the stronger claim: the refusal
    ///         happens before the `transferFrom`, so an unbounded call never takes custody of
    ///         anything on its way to reverting. An allowance error here would mean the check
    ///         had drifted below the transfer.
    function test_theUsdgDoorRefusesAZeroLiquidityBound() public {
        usdg.mint(provider, 1_000e6);
        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.ZeroLiquidityBound.selector);
        zapper.zapLiquidity(marketId, 1_000e6, 5_000, 0, block.timestamp + 600);

        assertEq(usdg.balanceOf(provider), 1_000e6, "the caller still holds every dollar");
        assertEq(usdg.balanceOf(address(zapper)), 0, "and the zapper took none of it");
    }

    /// @notice The ETH door refuses both of its zeroes, and refuses them before the sale. The
    ///         caller's ether is still theirs when the call comes back.
    function test_theEthDoorRefusesEitherZeroBoundBeforeSpendingAnything() public {
        vm.deal(provider, 1 ether);

        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.ZeroSaleBound.selector);
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, 0, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.ZeroLiquidityBound.selector);
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, ANY_SALE, 5_000, 0, block.timestamp + 600
        );

        assertEq(provider.balance, 1 ether, "neither refusal cost the caller anything but gas");
        assertEq(weth.balanceOf(address(zapper)), 0, "and nothing was wrapped on the way");
    }

    /// @notice The sale bound now binds at the venue, not only afterwards. `SwapRouter02` is
    ///         told `amountOutMinimum`, so a bad fill is refused by the router itself rather
    ///         than completed and then rejected — which is what the first deployment did.
    function test_theSaleBoundIsDeclaredToTheV3Router() public {
        // Half the quoted rate: $1,500 for an ether against a bound of $2,900.
        v3Router.setRateE18(ETH_PRICE_E18 / 2);

        vm.deal(provider, 1 ether);
        vm.prank(provider);
        vm.expectRevert(bytes("MockSwapRouter02: insufficient output"));
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, 2_900e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        assertEq(provider.balance, 1 ether, "and the ether never left");
    }

    // ─── Initialisation and the admin surface ────────────────────────────

    /// @notice Wiring it against a `PositionManager` bound to a different PoolManager is not a
    ///         runtime failure to handle, it is a deployment that cannot be made. The check
    ///         moved from the constructor to the initialiser with the proxy, and still holds.
    function test_initialisationRejectsAPositionManagerOnADifferentPoolManager() public {
        PoolManager stranger = new PoolManager(address(this));
        StandInPositionManager elsewhere =
            new StandInPositionManager(IPoolManager(address(stranger)), permit2);

        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityZapper.PoolManagerMismatch.selector, address(stranger), address(manager)
            )
        );
        _newZapper(
            reserve,
            IPositionManagerV4(address(elsewhere)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(v3Router))
        );
    }

    function test_initialisationRejectsZeroWiring() public {
        vm.expectRevert(LiquidityZapper.ZeroAddress.selector);
        _newZapper(
            SharedReservePool(address(0)),
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(v3Router))
        );
        vm.expectRevert(LiquidityZapper.ZeroAddress.selector);
        _newZapper(
            reserve,
            IPositionManagerV4(address(posm)),
            IPermit2(address(0)),
            ISwapRouter02(address(v3Router))
        );
    }

    /// @notice The wiring is written once. A second `initialize` would otherwise let anyone
    ///         repoint the reserve, the factory and the v3 router of a live zapper.
    function test_theInitialiserCannotBeRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        zapper.initialize(
            reserve,
            factory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(v3Router)),
            provider,
            address(protocolGuard)
        );

        assertEq(zapper.owner(), owner, "the owner is still the one it was deployed with");
    }

    /// @notice The implementation itself is not a usable zapper. Initialisers are disabled in
    ///         its constructor, so nobody can claim it and run a second zapper out of the same
    ///         bytecode with its own Permit2 allowances.
    function test_theImplementationCannotBeInitialisedDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LiquidityZapper(payable(zapperImpl))
            .initialize(
                reserve,
                factory,
                IPositionManagerV4(address(posm)),
                IPermit2(address(permit2)),
                ISwapRouter02(address(v3Router)),
                provider,
                address(protocolGuard)
            );
    }

    function test_onlyTheOwnerCanUpgrade() public {
        address nextImpl = address(new LiquidityZapper());

        vm.prank(provider);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, provider)
        );
        zapper.upgradeToAndCall(nextImpl, "");

        vm.prank(owner);
        zapper.upgradeToAndCall(nextImpl, "");

        // The upgrade is the point of this generation, so prove the proxy still works after one
        // rather than only that the call was permitted.
        (, uint128 added,,) = _zap(marketId, 1_000e6, ANY_LIQUIDITY);
        assertGt(added, 0, "the zapper still zaps across an upgrade");
    }

    /// @notice Ownership cannot be dropped. Renouncing would freeze the implementation with
    ///         whatever is in it, which is exactly the state the first deployment was stuck in.
    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(LiquidityZapper.OwnershipCannotBeRenounced.selector);
        zapper.renounceOwnership();

        assertEq(zapper.owner(), owner, "still owned");
    }

    // ─── The ETH door ────────────────────────────────────────────────────

    /// @notice The case most wallets are actually in: ETH and nothing else. One call leaves them
    ///         holding an LP NFT in a pool of two tokens they never had to acquire.
    function test_ethAloneBecomesATwoSidedPosition() public {
        assertEq(usdg.balanceOf(provider), 0, "no USDG");
        assertEq(asset.balanceOf(provider), 0, "and none of the asset");

        uint256 expectedId = posm.nextTokenId();
        uint128 depthBefore = router.marketLiquidity(marketId);

        (uint256 tokenId, uint128 added, uint256 brandUsed, uint256 assetUsed) =
            _zapWithEth(marketId, 1 ether, ANY_SALE, ANY_LIQUIDITY);

        assertEq(tokenId, expectedId, "the id the PositionManager was about to mint");
        assertEq(posm.ownerOf(tokenId), provider, "owned by the provider, not the zapper");
        assertGt(added, 0, "liquidity was added");
        assertGt(brandUsed, 0, "the stable side was paid");
        assertGt(assetUsed, 0, "and so was the asset side");
        assertEq(
            router.marketLiquidity(marketId), depthBefore + added, "into the market's own pool"
        );
    }

    /// @notice Both doors lead to the same place. Against the same pool state, 1 ETH sold at
    ///         $3,000 mints the same position as 3,000 USDG handed over directly — because the
    ///         ETH door's only extra step is the sale that produces that USDG.
    function test_theEthDoorAndTheUsdgDoorAgree() public {
        uint256 pristine = vm.snapshotState();

        (, uint128 viaEth,,) = _zapWithEth(marketId, 1 ether, ANY_SALE, ANY_LIQUIDITY);

        // Back to the pool the ETH zap met, so the two are measured against the same depth and
        // the same price rather than one after the other.
        vm.revertToState(pristine);

        (, uint128 viaUsdg,,) = _zap(marketId, 3_000e6, ANY_LIQUIDITY);

        assertGt(viaEth, 0, "the ETH door minted a position");
        assertEq(viaEth, viaUsdg, "and it is the position the USDG door would have minted");
    }

    /// @notice What the router declines to spend comes home as ETH, not as WETH stranded in a
    ///         contract that keeps nothing.
    function test_ethZapRefundsWhatTheRouterWouldNotSpend() public {
        v3Router.setFillBps(6_000);

        vm.deal(provider, 1 ether);
        uint256 before = provider.balance;

        vm.prank(provider);
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, ANY_SALE, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        assertEq(provider.balance, before - 0.6 ether, "the unsold 0.4 ETH came back as ETH");
        assertEq(weth.balanceOf(address(zapper)), 0, "and none was left wrapped here");
        assertEq(address(zapper).balance, 0, "nor unwrapped");
    }

    /// @notice The zapper keeps nothing from an ETH zap either. The stable remainder comes back
    ///         as the market's own dollar rather than being redeemed or sold back into ETH: it
    ///         is dust by construction, and both round trips cost more than the dust is worth.
    function test_ethZapKeepsNothingAndReturnsTheRemainderAsBrand() public {
        (,, uint256 brandUsed,) = _zapWithEth(marketId, 1 ether, ANY_SALE, ANY_LIQUIDITY);

        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertEq(IERC20(m.brandToken).balanceOf(address(zapper)), 0, "no brand kept");
        assertEq(asset.balanceOf(address(zapper)), 0, "no asset kept");
        assertEq(usdg.balanceOf(address(zapper)), 0, "no USDG kept");
        assertEq(weth.balanceOf(address(zapper)), 0, "no WETH kept");
        assertEq(address(zapper).balance, 0, "no ETH kept");

        assertGt(brandUsed, 0, "the position was funded");
        // 1 ETH bought 3,000 USDG, `swapBps` of 5,000 spent half of it on the asset, and what
        // the mint declined out of the remaining half is what comes back.
        assertEq(
            IERC20(m.brandToken).balanceOf(provider),
            1_500e6 - brandUsed,
            "and what the pool declined came back as brandUSD"
        );
        assertEq(usdg.balanceOf(provider), 0, "never redeemed to USDG on the way out");
    }

    /// @notice A zapper deployed with no v3 router is a complete zapper for USDG and says so
    ///         plainly about ETH, rather than reverting somewhere deep with a router's own error.
    function test_aZapperWithoutARouterRefusesEthAndStillTakesUsdg() public {
        LiquidityZapper usdgOnly = _newZapper(
            reserve,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(0))
        );

        assertFalse(usdgOnly.supportsEthZaps(), "it says so before anyone signs");
        assertEq(address(usdgOnly.weth()), address(0), "and names no wrapper");

        vm.deal(provider, 1 ether);
        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.EthZapUnavailable.selector);
        usdgOnly.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, ANY_SALE, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        usdg.mint(provider, 1_000e6);
        vm.startPrank(provider);
        usdg.approve(address(usdgOnly), 1_000e6);
        (, uint128 added,,) =
            usdgOnly.zapLiquidity(marketId, 1_000e6, 5_000, ANY_LIQUIDITY, block.timestamp + 600);
        vm.stopPrank();
        assertGt(added, 0, "the USDG door is untouched by the ETH door's absence");
    }

    /// @notice WETH is read off the router, never configured beside it. The two agreeing is what
    ///         makes the wrap and the sale describe the same token.
    function test_theWrapperIsTheOneTheRouterNames() public view {
        assertEq(address(zapper.weth()), v3Router.WETH9(), "derived, not declared");
        assertTrue(zapper.supportsEthZaps(), "and the door is open");
    }

    /// @notice A router that names no wrapper cannot be swapped through, so it is refused at
    ///         initialisation rather than at a user's first ETH zap.
    function test_initialisationRejectsARouterWithNoWrapper() public {
        MockSwapRouter02 wrapperless = new MockSwapRouter02(address(0xF00D));

        vm.expectRevert(LiquidityZapper.ZeroAddress.selector);
        _newZapper(
            reserve,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ISwapRouter02(address(wrapperless))
        );
    }

    /// @notice ETH sent here outside a zap has no way back out, so it is refused. The wrapper is
    ///         the one exception, because an unwrapped refund arrives from it.
    function test_plainEthTransfersAreRefused() public {
        vm.deal(provider, 1 ether);
        vm.prank(provider);
        (bool sent,) = address(zapper).call{value: 1 ether}("");
        assertFalse(sent, "a donation with no way back out is not accepted");
        assertEq(address(zapper).balance, 0, "and nothing stuck");
    }

    function test_ethZapRejectsAnExpiredDeadlineAndAZeroValue() public {
        vm.deal(provider, 1 ether);

        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.DeadlineExpired.selector);
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, ANY_SALE, 5_000, ANY_LIQUIDITY, block.timestamp - 1
        );

        vm.prank(provider);
        vm.expectRevert(LiquidityZapper.ZeroAmount.selector);
        zapper.zapLiquidityWithEth{value: 0}(
            marketId, V3_FEE, ANY_SALE, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        assertEq(provider.balance, 1 ether, "a refused zap costs the caller nothing but gas");
    }

    /// @notice A halt reaches the ETH door BEFORE the sale now, because the entry point itself
    ///         is `whenNotPaused`. It used to reach it only through `SharedReservePool.mint`,
    ///         which reverted the whole transaction and so was correct but late: the wrap and
    ///         the v3 sale had already been paid for in gas by the time it bit.
    function test_aPausedProtocolStopsAnEthZapWithTheSaleUndone() public {
        _pauseProtocol();

        vm.deal(provider, 1 ether);
        vm.prank(provider);
        vm.expectRevert();
        zapper.zapLiquidityWithEth{value: 1 ether}(
            marketId, V3_FEE, ANY_SALE, 5_000, ANY_LIQUIDITY, block.timestamp + 600
        );

        assertEq(provider.balance, 1 ether, "the ETH never left");
        assertEq(usdg.balanceOf(provider), 0, "and no half-finished USDG position was created");

        _unpauseProtocol();
        (, uint128 added,,) = _zapWithEth(marketId, 1 ether, ANY_SALE, ANY_LIQUIDITY);
        assertGt(added, 0, "and it works again once the protocol does");
    }
}
