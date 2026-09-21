// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {Errors} from "@openzeppelin/utils/Errors.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchDeployer} from "../../src/launchpad/LaunchDeployer.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {
    GraduationPhase,
    ILaunchFactory,
    ILaunchFeeEscrow,
    ILaunchGraduation
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StandInPermit2, StandInPositionManager} from "../markets/MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev The graduation module as the factory sees it: records the seed it was handed, what
///      arrived with it, and returns a result. Can be told to refuse, which is how phase two's
///      all-or-nothing contract is exercised without a real market.
contract MockLaunchGraduation is ILaunchGraduation {
    address public immutable factory;
    bool public refuse;
    uint256 public calls;
    uint256 public quoteReceived;
    uint256 public tokensReceived;
    Seed private _seed;

    error Refused();
    error NotFactory();

    constructor(address factory_) {
        factory = factory_;
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function seed() external view returns (Seed memory) {
        return _seed;
    }

    function graduate(Seed calldata s) external returns (Result memory) {
        if (msg.sender != factory) revert NotFactory();
        if (refuse) revert Refused();
        ++calls;
        _seed = s;
        quoteReceived = IERC20(s.pairToken).balanceOf(address(this));
        tokensReceived = IERC20(s.token).balanceOf(address(this));
        uint256 seeded = (s.tokenAmount * s.quoteAmount) / (s.quoteAmount + s.phantomQuote);
        return Result({
            marketId: 42,
            unit: address(0x0421),
            poolId: keccak256("pool"),
            positionId: 7,
            unitSeeded: s.quoteAmount,
            tokensSeeded: seeded,
            tokensLocked: s.tokenAmount - seeded
        });
    }
}

/// @title LaunchFactoryTest
/// @notice The launch orchestrator against a real reserve and a real market factory, with the
///         graduation module mocked: everything the factory decides — what terms are legal,
///         when the fee is taken, who may hand over creator fees, and how the two graduation
///         phases move funds — is decided here.
contract LaunchFactoryTest is StackFixture {
    uint256 constant SUPPLY = 1e27;
    uint256 constant PHANTOM = 3_236e6;
    uint256 constant THRESHOLD = 8_090e6;
    uint256 constant LAUNCH_FEE = 1e6;
    uint256 constant CURVE_FEE_BPS = 100;
    uint24 constant POOL_FEE = 5_000;

    MockUSDC usdg;
    MockYieldSource yieldSource;
    SharedReservePool reserve;
    SharedReservePool otherReserve;
    PoolManager manager;
    ProtocolFeeHook feeHook;
    StandInPermit2 permit2;
    StandInPositionManager posm;
    AssetMarketFactory marketFactory;

    LaunchFeeEscrow escrow;
    LaunchFactory factory;
    LaunchDeployer deployer;
    MockLaunchGraduation graduation;

    address brand;
    address otherBrand;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address feeRecipient = address(0xFEE);
    address creator = address(0xC12EA);
    address alice = address(0xA11CE);
    address router = address(0x2007E2);

    uint256 configId;

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);
        otherReserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        manager = new PoolManager(address(this));
        feeHook = _deployHookAt(
            address(
                uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (uint160(0x1A00) << 144)
            ),
            IPoolManager(address(manager)),
            owner
        );
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);
        marketFactory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            0,
            owner
        );

        // Both brands go through the MARKET factory, not straight onto the reserve: that is
        // what gives them a `reserveOfBrand`, which a launch now insists on at launch time
        // because graduation opens the market quoted in the brand itself. Registering leaves
        // this contract as each treasury's admin, so it is also what opts them into sharing
        // their float yield — the other thing a launch now insists on.
        //
        // `otherReserve` is approved only long enough to register a brand in it, because the
        // rejection tests below need it unapproved again.
        address brandTreasury;
        address otherBrandTreasury;
        (brand, brandTreasury) = marketFactory.registerBrand("Brand Dollar", "bUSD");
        vm.prank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), true);
        (otherBrand, otherBrandTreasury) = marketFactory.registerBrand(
            "Other Dollar",
            "oUSD",
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            address(otherReserve)
        );
        vm.prank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), false);
        PoolBrandTreasury(brandTreasury).setFactory(address(marketFactory));
        PoolBrandTreasury(otherBrandTreasury).setFactory(address(marketFactory));

        escrow = new LaunchFeeEscrow();
        factory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(new LaunchFactory()),
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            address(protocolGuard),
                            marketFactory,
                            IPositionManagerV4(address(posm)),
                            ILaunchFeeEscrow(address(escrow))
                        )
                    )
                )
            )
        );
        deployer = new LaunchDeployer(address(factory));
        graduation = new MockLaunchGraduation(address(factory));

        vm.startPrank(owner);
        factory.setLaunchDeployer(deployer);
        factory.setGraduation(graduation);
        factory.setProtocolFeeRecipient(feeRecipient);
        factory.setLaunchForwarder(router);
        factory.setLaunchEnabled(true);
        configId = factory.addLaunchConfig(_config());
        factory.setReserveEconomics(address(reserve), _economics(6, true));
        vm.stopPrank();

        _fund(creator, 100_000e6);
        _fund(alice, 100_000e6);
        _fund(router, 100e6);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _config() internal pure returns (LaunchFactory.LaunchConfig memory) {
        return LaunchFactory.LaunchConfig({
            supply: SUPPLY, curveFeeBps: CURVE_FEE_BPS, poolFee: POOL_FEE, enabled: true
        });
    }

    function _economics(uint8 decimals, bool approved)
        internal
        pure
        returns (LaunchFactory.ReserveEconomics memory)
    {
        return LaunchFactory.ReserveEconomics({
            phantomQuote: PHANTOM,
            graduationThreshold: THRESHOLD,
            launchFee: LAUNCH_FEE,
            decimals: decimals,
            approved: approved
        });
    }

    function _params(bytes32 salt) internal pure returns (LaunchFactory.TokenParams memory) {
        return LaunchFactory.TokenParams({
            name: "Launch",
            symbol: "LNCH",
            logo: "ipfs://logo",
            description: "a launch",
            socials: LaunchToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 200,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    /// @dev Brand tokens, minted 1:1 from USDG through the reserve, approved to the factory.
    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(brand, amount, who);
        IERC20(brand).approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function _launch(address who, bytes32 salt) internal returns (address token, address curve) {
        vm.prank(who);
        (token, curve) = factory.launchToken(_params(salt), configId, brand, new address[](0));
    }

    /// @dev Buys the whole allocation in one crossing buy, which auto-graduates (phase 1).
    function _fill(address token) internal {
        LaunchCurve curve = LaunchCurve(factory.getLaunchedToken(token).curve);
        vm.warp(block.timestamp + 16);
        vm.startPrank(alice);
        IERC20(brand).approve(address(curve), type(uint256).max);
        curve.buy(50_000e6, 0, alice);
        vm.stopPrank();
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_initializeRejectsAPositionManagerTheMarketFactoryDoesNotUse() public {
        StandInPositionManager stray =
            new StandInPositionManager(IPoolManager(address(manager)), permit2);
        address impl = address(new LaunchFactory());
        vm.expectRevert(LaunchFactory.LaunchDependenciesNotWired.selector);
        new ERC1967Proxy(
            impl,
            abi.encodeCall(
                LaunchFactory.initialize,
                (
                    owner,
                    address(protocolGuard),
                    marketFactory,
                    IPositionManagerV4(address(stray)),
                    ILaunchFeeEscrow(address(escrow))
                )
            )
        );
    }

    /// @notice Re-pointing the deployer and the graduation module at helpers already built for
    ///         this factory is allowed: both are replaceable so a defective one can be fixed
    ///         without redeploying the factory and abandoning its launch records. What is not
    ///         allowed is a helper wired to somebody else's factory, which is the check below.
    function test_wiringRotatesToHelpersBuiltForThisFactory() public {
        vm.startPrank(owner);
        factory.setLaunchDeployer(deployer);
        assertEq(address(factory.launchDeployer()), address(deployer), "deployer re-set");
        factory.setGraduation(graduation);
        assertEq(address(factory.graduation()), address(graduation), "graduation re-set");
        vm.stopPrank();

        LaunchFactory fresh = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(new LaunchFactory()),
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            address(protocolGuard),
                            marketFactory,
                            IPositionManagerV4(address(posm)),
                            ILaunchFeeEscrow(address(escrow))
                        )
                    )
                )
            )
        );
        vm.startPrank(owner);
        vm.expectRevert(LaunchFactory.LaunchDependenciesNotWired.selector);
        fresh.setLaunchDeployer(deployer); // built for the other factory
        vm.expectRevert(LaunchFactory.LaunchDependenciesNotWired.selector);
        fresh.setGraduation(graduation);
        vm.stopPrank();
    }

    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.OwnershipCannotBeRenounced.selector);
        factory.renounceOwnership();
    }

    // ─── Configuration validation ────────────────────────────────────────

    function test_launchConfigRejectsFeeSupplyAndTierOutOfBounds() public {
        LaunchFactory.LaunchConfig memory c = _config();
        vm.startPrank(owner);

        c.curveFeeBps = 1_001;
        vm.expectRevert(LaunchFactory.CurveFeeTooHigh.selector);
        factory.addLaunchConfig(c);

        c = _config();
        c.supply = 1 ether - 1;
        vm.expectRevert(LaunchFactory.SupplyTooLow.selector);
        factory.addLaunchConfig(c);

        c = _config();
        c.supply = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(LaunchFactory.SupplyTooHigh.selector);
        factory.addLaunchConfig(c);

        c = _config();
        c.poolFee = 4_000;
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.UnsupportedFeeTier.selector, uint24(4_000))
        );
        factory.addLaunchConfig(c);

        vm.expectRevert(LaunchFactory.InvalidLaunchConfigId.selector);
        factory.updateLaunchConfig(7, _config());
        vm.stopPrank();
    }

    /// @notice What the owner may write against a reserve. Nothing here names a brand: the
    ///         unit of approval is the reserve, so the only questions are whether the figures
    ///         make a quotable curve and whether the market factory actually opens markets in
    ///         that reserve at the scale claimed.
    function test_setReserveEconomicsRejectsBadTermsAndReservesTheFactoryDoesNotServe() public {
        vm.startPrank(owner);

        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setReserveEconomics(address(0), _economics(6, true));

        LaunchFactory.ReserveEconomics memory e = _economics(6, true);
        e.phantomQuote = 0;
        vm.expectRevert(LaunchFactory.ReserveEconomicsInvalid.selector);
        factory.setReserveEconomics(address(reserve), e);

        e = _economics(6, true);
        e.graduationThreshold = 0;
        vm.expectRevert(LaunchFactory.ReserveEconomicsInvalid.selector);
        factory.setReserveEconomics(address(reserve), e);

        // Below the decimal floor, where integer curve fees round to zero on real trades.
        vm.expectRevert(LaunchFactory.ReserveEconomicsInvalid.selector);
        factory.setReserveEconomics(address(reserve), _economics(5, true));

        // Above the floor but not the scale this reserve actually mints its brands at.
        vm.expectRevert(LaunchFactory.ReserveEconomicsInvalid.selector);
        factory.setReserveEconomics(address(reserve), _economics(18, true));

        // A reserve the market factory does not open markets in. Graduation would have
        // nowhere to put the raise.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveNotApproved.selector, address(otherReserve))
        );
        factory.setReserveEconomics(address(otherReserve), _economics(6, true));

        // Opening a reserve is not a way to skip writing its figures.
        vm.expectRevert(LaunchFactory.ReserveEconomicsInvalid.selector);
        factory.setReserveApproved(address(otherReserve), true);

        // Once the market factory serves the reserve, its figures are welcome.
        marketFactory.setApprovedReservePool(address(otherReserve), true);
        factory.setReserveEconomics(address(otherReserve), _economics(6, true));
        (uint256 phantom, uint256 threshold,, uint8 decimals, bool approved) =
            factory.reserveEconomics(address(otherReserve));
        assertEq(phantom, PHANTOM, "phantom quote written");
        assertEq(threshold, THRESHOLD, "graduation threshold written");
        assertEq(decimals, 6, "scale pinned to the reserve's asset");
        assertTrue(approved, "and the reserve is open");
        vm.stopPrank();
    }

    /// @notice The per-brand conditions, which are no longer the owner's to satisfy in
    ///         advance: they are read live off the market factory and the brand's treasury
    ///         every time a launch is quoted in that brand.
    function test_launchEconomicsRefusesBrandsThatCouldNeverLaunch() public {
        // USDG is the reserve's asset, not one of its brands, so there is no reserve to
        // resolve at all.
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.PairTokenNotRegistered.selector, address(usdg), address(0)
            )
        );
        factory.launchEconomics(address(usdg));

        // A brand whose issuer has not agreed to share the float yield of the markets it
        // quotes. A graduate seeds its whole raise in this dollar and would earn nothing.
        (address closedBrand,) = marketFactory.registerBrand("Closed Dollar", "cUSD");
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.PairTokenFloatShareUnavailable.selector, closedBrand
            )
        );
        factory.launchEconomics(closedBrand);

        // A brand of a reserve the market factory serves but whose figures were never
        // written: readable, and refused the moment it is launched in.
        vm.startPrank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), true);
        vm.stopPrank();
        (address resolved, LaunchFactory.ReserveEconomics memory blank) =
            factory.launchEconomics(otherBrand);
        assertEq(resolved, address(otherReserve), "the reserve still resolves");
        assertFalse(blank.approved, "but it is closed to launches");
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveClosed.selector, address(otherReserve))
        );
        factory.launchToken(_params("s1"), configId, otherBrand, new address[](0));

        // A reserve with figures the owner has since closed refuses the same way.
        vm.prank(owner);
        factory.setReserveApproved(address(reserve), false);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveClosed.selector, address(reserve))
        );
        factory.launchToken(_params("s2"), configId, brand, new address[](0));

        // And a brand of a reserve the market factory has since retired: the figures are
        // still written, but the reserve no longer resolves.
        vm.prank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), false);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveNotApproved.selector, address(otherReserve))
        );
        factory.launchEconomics(otherBrand);
    }

    /// @notice The point of keying economics by reserve. A dollar issued long after the owner
    ///         opened its reserve is launchable on the spot, with no owner transaction in
    ///         between — under per-brand approval this launch was impossible.
    function test_aBrandIssuedAfterItsReserveWasOpenedLaunchesWithNoOwnerCall() public {
        // Everything the owner will ever do for this reserve has already happened in setUp.
        (address lateBrand, address lateTreasury) =
            marketFactory.registerBrand("Late Dollar", "lateUSD");
        PoolBrandTreasury(lateTreasury).setFactory(address(marketFactory));

        (address resolved, LaunchFactory.ReserveEconomics memory economics) =
            factory.launchEconomics(lateBrand);
        assertEq(resolved, address(reserve), "the new brand inherits its reserve's terms");
        assertTrue(economics.approved, "which are already open");

        usdg.mint(creator, 100_000e6);
        vm.startPrank(creator);
        usdg.approve(address(reserve), 100_000e6);
        reserve.mint(lateBrand, 100_000e6, creator);
        IERC20(lateBrand).approve(address(factory), type(uint256).max);
        (address token,) =
            factory.launchToken(_params("late"), configId, lateBrand, new address[](0));
        vm.stopPrank();

        ILaunchFactory.LaunchedToken memory record = factory.getLaunchedToken(token);
        assertEq(record.pairToken, lateBrand, "quoted in the brand that did not exist yet");
        assertEq(record.reserve, address(reserve), "against the reserve the owner opened");
        assertEq(record.graduationThreshold, THRESHOLD, "on that reserve's terms");
        assertEq(IERC20(lateBrand).balanceOf(feeRecipient), LAUNCH_FEE, "and paid its fee");
    }

    function test_ownerSettersEnforceTheirCaps() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setProtocolFeeShareBps(5_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setMaxCreatorTaxBps(1_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedCreatorShareBps(10_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setLpFundShareBps(5_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedLpFundShareBps(5_001);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setLpFundRecipient(address(0));
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setSnipeTax(2_000, 15); // must dominate the fee ceiling
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setSnipeTax(9_901, 15);
        vm.expectRevert(LaunchFactory.InvalidSnipeTaxWindow.selector);
        factory.setSnipeTax(9_900, 61);
        vm.expectRevert(LaunchFactory.InvalidSnipeTaxWindow.selector);
        factory.setSnipeTax(9_900, 0);
        factory.setSnipeTax(0, 15); // off
        assertEq(factory.snipeTaxStartBps(), 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setLaunchEnabled(false);
    }

    /// @notice The creator is paid the remainder of the curve fee, so a protocol share and an
    ///         LP fund share that together exceed the whole fee would underflow the sweep of
    ///         every curve launched afterwards — and a curve is immutable, so it would be
    ///         unfixable. Both setters check the pair, so neither ordering of two calls can
    ///         leave it invalid even transiently.
    function test_theCurveFeeSharesAreBoundedAgainstEachOther() public {
        vm.startPrank(owner);
        factory.setLpFundRecipient(address(0x11FD));

        // 50% + 50% is exactly the whole fee and is allowed: the creator's remainder is zero,
        // not negative.
        factory.setProtocolFeeShareBps(5_000);
        factory.setLpFundShareBps(5_000);
        assertEq(factory.protocolFeeShareBps(), 5_000);
        assertEq(factory.lpFundShareBps(), 5_000);

        // Neither can then be raised, and the individual ceilings are what binds first.
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setProtocolFeeShareBps(5_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setLpFundShareBps(5_001);
        vm.stopPrank();
    }

    /// @notice A nonzero fund share with no recipient would credit the escrow to address zero.
    ///         The curve refuses such a policy at initialize; the factory refuses to create it
    ///         in the first place.
    function test_aFundShareRequiresARecipient() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setLpFundShareBps(3_000);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setGraduatedLpFundShareBps(3_000);

        factory.setLpFundRecipient(address(0x11FD));
        factory.setLpFundShareBps(3_000);
        factory.setGraduatedLpFundShareBps(3_000);
        assertEq(factory.lpFundShareBps(), 3_000);
        assertEq(factory.graduatedLpFundShareBps(), 3_000);
        vm.stopPrank();
    }

    /// @notice The post-graduation fund share is bounded against the creator's fee share,
    ///         because the two are subtracted from the same leg.
    function test_theGraduatedFundShareIsBoundedAgainstTheCreatorRate() public {
        vm.startPrank(owner);
        factory.setLpFundRecipient(address(0x11FD));
        factory.setGraduatedLpFundShareBps(5_000);

        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedCreatorShareBps(5_001);

        // And in the other direction. The fund has to come down before the creator can go up,
        // which is the same invariant seen from the other side.
        factory.setGraduatedLpFundShareBps(2_000);
        factory.setGraduatedCreatorShareBps(8_000);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedLpFundShareBps(3_000);
        vm.stopPrank();
    }

    // ─── Launch ──────────────────────────────────────────────────────────

    function test_launchDeploysWiresRecordsAndTakesTheFeeLast() public {
        uint256 creatorBefore = IERC20(brand).balanceOf(creator);
        (address predictedToken, address predictedCurve) =
            factory.predictLaunchAddresses(_params("s1"), configId, brand, creator);

        vm.expectEmit(true, true, true, true);
        emit LaunchFactory.TokenLaunched(
            predictedToken, predictedCurve, creator, brand, address(reserve), configId, THRESHOLD
        );
        (address token, address curve) = _launch(creator, "s1");

        assertEq(token, predictedToken, "CREATE2 prediction: token");
        assertEq(curve, predictedCurve, "CREATE2 prediction: curve");
        assertEq(IERC20(brand).balanceOf(creator), creatorBefore - LAUNCH_FEE, "fee pulled");
        assertEq(IERC20(brand).balanceOf(feeRecipient), LAUNCH_FEE, "fee to the recipient");

        ILaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(token);
        assertTrue(rec.exists);
        assertEq(rec.curve, curve);
        assertEq(rec.deployer, creator);
        assertEq(rec.creatorFeeRecipient, creator, "defaults to the deployer");
        assertEq(rec.pairToken, brand);
        assertEq(rec.reserve, address(reserve));
        assertEq(rec.graduationThreshold, THRESHOLD);
        assertEq(rec.poolFee, POOL_FEE);
        assertEq(rec.creatorTaxBps, 200);
        assertEq(rec.creatorShareBps, 4_000, "the default graduated creator fee share");
        assertEq(uint8(rec.phase), uint8(GraduationPhase.NotGraduated));
        assertEq(factory.launchCount(), 1);
        assertEq(factory.launchAt(0), token);
        assertEq(factory.creatorFeeRecipientOf(token), creator);

        LaunchCurve c = LaunchCurve(curve);
        assertEq(c.token(), token);
        assertEq(c.factory(), address(factory));
        assertEq(c.protocolFeeRecipient(), feeRecipient);
        assertEq(c.protocolFeeShareBps(), 3_000);
        assertEq(address(c.feeEscrow()), address(escrow));
        assertEq(c.creatorTaxBps(), 200);
        assertEq(c.feeBps(), CURVE_FEE_BPS);
        assertEq(c.currentSnipeTaxBps(creator), 0, "the creator is exempt");
        assertEq(c.currentSnipeTaxBps(alice), 9_900, "everyone else is not");
        assertEq(IERC20(token).balanceOf(curve), SUPPLY, "the whole supply sits on the curve");
        assertEq(LaunchToken(token).launchFactory(), address(factory));
        assertEq(LaunchToken(token).deployer(), creator);
    }

    function test_failedLaunchTakesNoFee() public {
        uint256 before = IERC20(brand).balanceOf(creator);
        LaunchFactory.TokenParams memory p = _params("s1");
        p.expectedEconomics = keccak256("stale");
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.LaunchEconomicsMismatch.selector,
                keccak256("stale"),
                factory.previewLaunchEconomics(configId, brand)
            )
        );
        factory.launchToken(p, configId, brand, new address[](0));
        assertEq(IERC20(brand).balanceOf(creator), before);
        assertEq(IERC20(brand).balanceOf(feeRecipient), 0);
    }

    function test_launchWithoutFeeAllowanceRevertsAfterNothingElseIsLeftBehind() public {
        vm.prank(creator);
        IERC20(brand).approve(address(factory), 0);
        vm.prank(creator);
        vm.expectRevert();
        factory.launchToken(_params("s1"), configId, brand, new address[](0));
        assertEq(factory.launchCount(), 0);
    }

    function test_zeroLaunchFeePullsNothing() public {
        LaunchFactory.ReserveEconomics memory e = _economics(6, true);
        e.launchFee = 0;
        vm.prank(owner);
        factory.setReserveEconomics(address(reserve), e);
        vm.prank(creator);
        IERC20(brand).approve(address(factory), 0);
        _launch(creator, "s1");
        assertEq(IERC20(brand).balanceOf(feeRecipient), 0);
    }

    function test_economicsPinRevertsWhenTheOwnerMovesAnyTerm() public {
        bytes32 quoted = factory.previewLaunchEconomics(configId, brand);
        LaunchFactory.TokenParams memory p = _params("s1");
        p.expectedEconomics = quoted;

        vm.prank(owner);
        factory.setProtocolFeeShareBps(2_500);
        bytes32 moved = factory.previewLaunchEconomics(configId, brand);
        assertTrue(moved != quoted);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.LaunchEconomicsMismatch.selector, quoted, moved)
        );
        factory.launchToken(p, configId, brand, new address[](0));

        // The refreshed pin, or no pin at all, goes through.
        p.expectedEconomics = moved;
        vm.prank(creator);
        factory.launchToken(p, configId, brand, new address[](0));
        _launch(creator, "s2");
        assertEq(factory.launchCount(), 2);
    }

    /// @dev Every term in the digest's preimage, moved one at a time. The rule the digest
    ///      encodes is that anything the owner can change which is then frozen into the launch
    ///      must be pinnable, because the creator cannot react to it once the curve is live —
    ///      so a term missing here is a term an owner can silently reprice between a creator
    ///      reading a quote and their transaction landing.
    function test_economicsDigestCoversEveryOwnerTerm() public {
        bytes32 last = factory.previewLaunchEconomics(configId, brand);
        vm.startPrank(owner);

        factory.setGraduatedCreatorShareBps(6_000);
        last = _assertDigestMoved(last, "graduated creator share");

        factory.setProtocolFeeShareBps(4_000);
        last = _assertDigestMoved(last, "protocol fee share");

        factory.setLpFundRecipient(address(0x11FD));
        factory.setLpFundShareBps(3_000);
        last = _assertDigestMoved(last, "LP fund share of the curve fee");

        factory.setSnipeTax(5_000, 15);
        last = _assertDigestMoved(last, "snipe tax start");

        factory.setSnipeTax(5_000, 30);
        last = _assertDigestMoved(last, "snipe tax window");

        LaunchFactory.ReserveEconomics memory e = _economics(6, true);
        e.launchFee = 2e6;
        factory.setReserveEconomics(address(reserve), e);
        last = _assertDigestMoved(last, "launch fee");

        e.phantomQuote = PHANTOM + 1e6;
        factory.setReserveEconomics(address(reserve), e);
        last = _assertDigestMoved(last, "phantom quote");

        e.graduationThreshold = THRESHOLD + 1e6;
        factory.setReserveEconomics(address(reserve), e);
        last = _assertDigestMoved(last, "graduation threshold");

        LaunchFactory.LaunchConfig memory c = _config();
        c.poolFee = 3_000;
        factory.updateLaunchConfig(configId, c);
        last = _assertDigestMoved(last, "pool fee tier");

        c.curveFeeBps = 250;
        factory.updateLaunchConfig(configId, c);
        last = _assertDigestMoved(last, "curve fee");

        c.supply = SUPPLY * 2;
        factory.updateLaunchConfig(configId, c);
        last = _assertDigestMoved(last, "supply");

        // The reserve, last. A brand belongs to exactly one reserve, so this leg is two
        // brands on different reserves carrying identical figures: if the digest covers the
        // reserve the two differ, and if it does not they collide.
        marketFactory.setApprovedReservePool(address(otherReserve), true);
        factory.setReserveEconomics(address(reserve), _economics(6, true));
        factory.setReserveEconomics(address(otherReserve), _economics(6, true));
        assertTrue(
            factory.previewLaunchEconomics(configId, otherBrand)
                != factory.previewLaunchEconomics(configId, brand),
            "reserve"
        );
        vm.stopPrank();
    }

    function _assertDigestMoved(bytes32 previous, string memory what)
        private
        view
        returns (bytes32 current)
    {
        current = factory.previewLaunchEconomics(configId, brand);
        assertTrue(current != previous, what);
    }

    /// @dev The digest is worthless unless a term moving underneath a pinned launch actually
    ///      stops it. `setSnipeTax` is the one that was silently missing: a creator who pinned
    ///      terms quoting a live anti-snipe window could have their launch deploy with it off.
    function test_aPinnedLaunchIsRefusedWhenTheSnipeTaxMovesUnderneathIt() public {
        LaunchFactory.TokenParams memory p = _params("pinned");
        p.expectedEconomics = factory.previewLaunchEconomics(configId, brand);

        vm.prank(owner);
        factory.setSnipeTax(0, 15);

        bytes32 current = factory.previewLaunchEconomics(configId, brand);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.LaunchEconomicsMismatch.selector, p.expectedEconomics, current
            )
        );
        factory.launchToken(p, configId, brand, new address[](0));
    }

    function test_launchRejectsBadTermsBeforeDeployingAnything() public {
        LaunchFactory.TokenParams memory p = _params("s1");
        vm.startPrank(creator);

        vm.expectRevert(LaunchFactory.InvalidLaunchConfigId.selector);
        factory.launchToken(p, 9, brand, new address[](0));

        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveNotApproved.selector, address(otherReserve))
        );
        factory.launchToken(p, configId, otherBrand, new address[](0));

        p.creatorTaxBps = 1_001;
        vm.expectRevert(LaunchFactory.CreatorTaxTooHigh.selector);
        factory.launchToken(p, configId, brand, new address[](0));

        p = _params("s1");
        p.name = "";
        vm.expectRevert(LaunchFactory.InvalidTokenParams.selector);
        factory.launchToken(p, configId, brand, new address[](0));

        p = _params("s1");
        address[] memory tooMany = new address[](33);
        vm.expectRevert(LaunchFactory.ExemptionListTooLong.selector);
        factory.launchToken(p, configId, brand, tooMany);
        vm.stopPrank();

        vm.prank(owner);
        factory.setLaunchEnabled(false);
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.LaunchDisabled.selector);
        factory.launchToken(p, configId, brand, new address[](0));

        vm.prank(owner);
        factory.setLaunchEnabled(true);
        LaunchFactory.LaunchConfig memory c = _config();
        c.enabled = false;
        vm.prank(owner);
        factory.updateLaunchConfig(configId, c);
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.LaunchConfigDisabled.selector);
        factory.launchToken(p, configId, brand, new address[](0));

        assertEq(factory.launchCount(), 0);
    }

    function test_launchIsHaltedByTheProtocolGuard() public {
        _pauseProtocol();
        vm.prank(creator);
        vm.expectRevert();
        factory.launchToken(_params("s1"), configId, brand, new address[](0));
        _unpauseProtocol();
        _launch(creator, "s1");
    }

    function test_saltsAreNamespacedPerDeployerAndCannotBeReused() public {
        (address tokenA,) = _launch(creator, "same");
        (address tokenB,) = _launch(alice, "same");
        assertTrue(tokenA != tokenB, "same salt, different deployers, different addresses");

        vm.prank(creator);
        vm.expectRevert(Errors.FailedDeployment.selector);
        factory.launchToken(_params("same"), configId, brand, new address[](0));
    }

    function test_creatorFeeRecipientAndExemptionsAreApplied() public {
        address[] memory bundle = new address[](2);
        bundle[0] = address(0xB1);
        bundle[1] = address(0xB2);
        LaunchFactory.TokenParams memory p = _params("s1");
        p.creatorFeeRecipient = address(0x4E12);

        vm.prank(creator);
        (address token, address curve) = factory.launchToken(p, configId, brand, bundle);

        assertEq(factory.creatorFeeRecipientOf(token), address(0x4E12));
        assertEq(LaunchCurve(curve).creatorFeeRecipient(), address(0x4E12));
        assertEq(LaunchCurve(curve).currentSnipeTaxBps(address(0x4E12)), 0);
        assertEq(LaunchCurve(curve).currentSnipeTaxBps(address(0xB1)), 0);
        assertEq(LaunchCurve(curve).currentSnipeTaxBps(address(0xB2)), 0);
        assertEq(LaunchCurve(curve).currentSnipeTaxBps(creator), 0);
        assertEq(LaunchCurve(curve).currentSnipeTaxBps(alice), 9_900);
    }

    // ─── Forwarder ───────────────────────────────────────────────────────

    function test_onlyTheForwarderMayNameTheDeployer() public {
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.NotLaunchForwarder.selector);
        factory.launchTokenFor(_params("s1"), configId, brand, new address[](0), alice);

        (address predictedToken,) =
            factory.predictLaunchAddresses(_params("s1"), configId, brand, alice);
        vm.prank(router);
        IERC20(brand).approve(address(factory), LAUNCH_FEE);
        vm.prank(router);
        (address token,) =
            factory.launchTokenFor(_params("s1"), configId, brand, new address[](0), alice);

        assertEq(token, predictedToken, "namespaced by the named deployer, not the router");
        assertEq(factory.getLaunchedToken(token).deployer, alice);
        assertEq(IERC20(brand).balanceOf(router), 100e6 - LAUNCH_FEE, "fee from the router");

        vm.prank(owner);
        factory.setLaunchForwarder(address(0));
        vm.prank(router);
        vm.expectRevert(LaunchFactory.NotLaunchForwarder.selector);
        factory.launchTokenFor(_params("s2"), configId, brand, new address[](0), alice);
    }

    // ─── Creator fee recipient ───────────────────────────────────────────

    function test_creatorRecipientHandoverIsTwoStepAndUpdatesTheCurve() public {
        (address token, address curve) = _launch(creator, "s1");
        address heir = address(0x4E12);

        vm.prank(alice);
        vm.expectRevert(LaunchFactory.NotCreatorFeeRecipient.selector);
        factory.proposeCreatorFeeRecipient(token, heir);
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.proposeCreatorFeeRecipient(token, address(0));
        vm.expectRevert(LaunchFactory.TokenNotFound.selector);
        factory.proposeCreatorFeeRecipient(address(0xdead), heir);

        vm.prank(creator);
        factory.proposeCreatorFeeRecipient(token, heir);
        assertEq(factory.creatorFeeRecipientOf(token), creator, "nothing moves on propose");
        assertEq(factory.pendingCreatorFeeRecipient(token), heir);

        vm.prank(alice);
        vm.expectRevert(LaunchFactory.NotProposedCreatorFeeRecipient.selector);
        factory.acceptCreatorFeeRecipient(token);
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.NotProposedCreatorFeeRecipient.selector);
        factory.acceptCreatorFeeRecipient(token);

        vm.expectEmit(true, true, true, true);
        emit LaunchFactory.CreatorFeeRecipientUpdated(token, creator, heir);
        vm.prank(heir);
        factory.acceptCreatorFeeRecipient(token);

        assertEq(factory.creatorFeeRecipientOf(token), heir);
        assertEq(LaunchCurve(curve).creatorFeeRecipient(), heir, "the curve follows");
        assertEq(factory.pendingCreatorFeeRecipient(token), address(0));

        // The old recipient has no say any more.
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.NotCreatorFeeRecipient.selector);
        factory.proposeCreatorFeeRecipient(token, creator);
    }

    function test_creatorRecipientHandoverAfterGraduationOnlyTouchesTheRecord() public {
        (address token, address curve) = _launch(creator, "s1");
        _fill(token);
        factory.graduateToMarket(token);
        address heir = address(0x4E12);

        vm.prank(creator);
        factory.proposeCreatorFeeRecipient(token, heir);
        vm.prank(heir);
        factory.acceptCreatorFeeRecipient(token);

        assertEq(factory.creatorFeeRecipientOf(token), heir, "what the locker reads");
        assertEq(LaunchCurve(curve).creatorFeeRecipient(), creator, "the dead curve is left");
    }

    // ─── Graduation, phase 1 ─────────────────────────────────────────────

    function test_crossingBuyAutoGraduatesIntoTheFactory() public {
        (address token, address curve) = _launch(creator, "s1");
        vm.warp(block.timestamp + 16);
        vm.startPrank(alice);
        IERC20(brand).approve(curve, type(uint256).max);
        vm.expectEmit(true, false, false, false);
        emit LaunchFactory.LaunchSwept(token, 0, 0);
        LaunchCurve(curve).buy(50_000e6, 0, alice);
        vm.stopPrank();

        ILaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(token);
        assertEq(uint8(rec.phase), uint8(GraduationPhase.Swept));
        assertEq(rec.sweptAt, block.timestamp);
        assertApproxEqRel(rec.sweptQuote, THRESHOLD, 1e15, "the real reserve at the threshold");
        assertEq(rec.sweptTokens, LaunchCurve(curve).reservedTokens());
        assertEq(IERC20(brand).balanceOf(address(factory)), rec.sweptQuote, "held here");
        assertEq(IERC20(token).balanceOf(address(factory)), rec.sweptTokens);
        assertTrue(LaunchCurve(curve).graduated());
        assertGt(escrow.balanceOfToken(feeRecipient, brand), 0, "fees swept to the escrow");
        assertGt(escrow.balanceOfToken(creator, brand), 0);
    }

    function test_graduateIsOncePerLaunchAndOnlyWhenReady() public {
        (address token,) = _launch(creator, "s1");
        vm.expectRevert(LaunchCurve.NotReadyToGraduate.selector);
        factory.graduate(token);
        vm.expectRevert(LaunchFactory.TokenNotFound.selector);
        factory.graduate(address(0xdead));

        _fill(token);
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.graduate(token);
    }

    // ─── Graduation, phase 2 ─────────────────────────────────────────────

    function test_graduateToMarketHandsTheSeedToTheModuleAndRecordsTheMarket() public {
        (address token, address curve) = _launch(creator, "s1");
        _fill(token);
        ILaunchFactory.LaunchedToken memory swept = factory.getLaunchedToken(token);
        uint256 expectedSeeded =
            (swept.sweptTokens * swept.sweptQuote) / (swept.sweptQuote + PHANTOM);

        vm.expectEmit(true, true, false, true);
        emit LaunchFactory.PoolGraduated(
            token,
            42,
            address(0x0421),
            keccak256("pool"),
            7,
            swept.sweptQuote,
            expectedSeeded,
            swept.sweptTokens - expectedSeeded
        );
        vm.prank(alice); // permissionless
        factory.graduateToMarket(token);

        ILaunchGraduation.Seed memory s = graduation.seed();
        assertEq(s.token, token);
        assertEq(s.pairToken, brand);
        assertEq(s.reserve, address(reserve));
        assertEq(s.creator, creator);
        assertEq(s.creatorFeeRecipient, creator);
        assertEq(s.creatorShareBps, 4_000);
        assertEq(s.poolFee, POOL_FEE);
        assertEq(s.quoteAmount, swept.sweptQuote);
        assertEq(s.tokenAmount, swept.sweptTokens);
        assertEq(s.phantomQuote, PHANTOM);
        assertEq(graduation.quoteReceived(), swept.sweptQuote, "funds arrive before the call");
        assertEq(graduation.tokensReceived(), swept.sweptTokens);
        assertEq(IERC20(brand).balanceOf(address(factory)), 0, "nothing stays behind");
        assertEq(IERC20(token).balanceOf(address(factory)), 0);

        ILaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(token);
        assertEq(uint8(rec.phase), uint8(GraduationPhase.Graduated));
        assertEq(rec.marketId, 42);
        assertEq(rec.sweptQuote, 0);
        assertEq(rec.sweptTokens, 0);
        assertEq(rec.sweptAt, 0);
        assertTrue(LaunchCurve(curve).graduated());

        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.graduateToMarket(token);
    }

    function test_graduateToMarketRequiresTheSweptPhase() public {
        (address token,) = _launch(creator, "s1");
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.graduateToMarket(token);
        vm.expectRevert(LaunchFactory.TokenNotFound.selector);
        factory.graduateToMarket(address(0xdead));
    }

    function test_aRefusedModuleLeavesTheLaunchSweptWithItsFundsIntact() public {
        (address token,) = _launch(creator, "s1");
        _fill(token);
        ILaunchFactory.LaunchedToken memory before = factory.getLaunchedToken(token);
        graduation.setRefuse(true);

        vm.expectRevert(MockLaunchGraduation.Refused.selector);
        factory.graduateToMarket(token);

        ILaunchFactory.LaunchedToken memory after_ = factory.getLaunchedToken(token);
        assertEq(uint8(after_.phase), uint8(GraduationPhase.Swept));
        assertEq(after_.sweptQuote, before.sweptQuote);
        assertEq(after_.sweptTokens, before.sweptTokens);
        assertEq(after_.sweptAt, before.sweptAt);
        assertEq(IERC20(brand).balanceOf(address(factory)), before.sweptQuote);
        assertEq(IERC20(token).balanceOf(address(factory)), before.sweptTokens);
        assertEq(IERC20(brand).balanceOf(address(graduation)), 0);

        // And it is retryable.
        graduation.setRefuse(false);
        factory.graduateToMarket(token);
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Graduated));
    }

    function test_graduateToMarketIsHaltedByTheProtocolGuard() public {
        (address token,) = _launch(creator, "s1");
        _fill(token);
        _pauseProtocol();
        vm.expectRevert();
        factory.graduateToMarket(token);
        _unpauseProtocol();
        factory.graduateToMarket(token);
    }

    // ─── Rescue ──────────────────────────────────────────────────────────

    function test_rescueIsOwnerOnlyAfterSevenDaysAndOnlyWhileSwept() public {
        (address token,) = _launch(creator, "s1");
        address to = address(0x5AFE);

        vm.prank(owner);
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.rescueSweptGraduation(token, to);

        _fill(token);
        ILaunchFactory.LaunchedToken memory swept = factory.getLaunchedToken(token);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.rescueSweptGraduation(token, to);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.GraduationRescueTooEarly.selector, swept.sweptAt + 7 days
            )
        );
        factory.rescueSweptGraduation(token, to);

        vm.warp(swept.sweptAt + 7 days - 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactory.GraduationRescueTooEarly.selector, swept.sweptAt + 7 days
            )
        );
        factory.rescueSweptGraduation(token, to);

        vm.warp(swept.sweptAt + 7 days);
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.rescueSweptGraduation(token, address(0));

        vm.expectEmit(true, true, false, true);
        emit LaunchFactory.GraduationRescued(token, to, swept.sweptQuote, swept.sweptTokens);
        vm.prank(owner);
        factory.rescueSweptGraduation(token, to);

        assertEq(IERC20(brand).balanceOf(to), swept.sweptQuote);
        assertEq(IERC20(token).balanceOf(to), swept.sweptTokens);
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Rescued));

        // Neither phase two nor a second rescue can follow.
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.graduateToMarket(token);
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.rescueSweptGraduation(token, to);
    }

    function test_anyoneCanEndTheRescueWindowEarlyByGraduating() public {
        (address token,) = _launch(creator, "s1");
        _fill(token);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        factory.graduateToMarket(token);
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        factory.rescueSweptGraduation(token, alice);
    }

    /// @dev The rescue window's legitimacy rests entirely on the permissionless retry staying
    ///      available throughout it. A guardian can take that retry away instantly and with no
    ///      timelock, while phase one keeps sweeping crossed curves into the factory — so if
    ///      the rescue were reachable under a pause, the guardian's halt would be the trigger
    ///      for an owner-only transfer of other people's money, which is exactly what
    ///      `ProtocolGuard` promises a stolen guardian key cannot do.
    function test_rescueIsUnreachableWhileTheRetryPathIsHalted() public {
        (address token,) = _launch(creator, "s1");
        _fill(token);
        ILaunchFactory.LaunchedToken memory swept = factory.getLaunchedToken(token);
        vm.warp(swept.sweptAt + 7 days);

        _pauseProtocol();

        // The retry is gone, so nobody can end the window.
        vm.prank(alice);
        vm.expectRevert();
        factory.graduateToMarket(token);

        vm.prank(owner);
        vm.expectRevert();
        factory.rescueSweptGraduation(token, address(0x5AFE));

        // Unpausing restores both together, and the holder gets there first.
        _unpauseProtocol();
        vm.prank(alice);
        factory.graduateToMarket(token);
        assertEq(uint8(factory.getLaunchedToken(token).phase), uint8(GraduationPhase.Graduated));
    }

    // ─── Terms that cannot graduate are refused at launch ────────────────

    /// @dev A launch resolves its brand's reserve and refuses one the market factory no longer
    ///      serves, because the owner may retire a reserve at any time and nothing in the
    ///      launchpad notices. Such a launch trades and sweeps normally, then fails
    ///      `_resolveReserve` on every `graduateToMarket` forever — its traders' money
    ///      reachable only by the owner's rescue. Refuse it while the only thing at stake is
    ///      the creator's unspent fee.
    function test_launchIsRefusedOnceItsBrandsReserveIsRetired() public {
        // A brand on a second reserve the market factory accepts, with the reserve's figures
        // written while that acceptance holds.
        vm.startPrank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), true);
        factory.setReserveEconomics(address(otherReserve), _economics(6, true));
        vm.stopPrank();

        usdg.mint(creator, 10e6);
        vm.startPrank(creator);
        usdg.approve(address(otherReserve), 10e6);
        otherReserve.mint(otherBrand, 10e6, creator);
        IERC20(otherBrand).approve(address(factory), type(uint256).max);
        vm.stopPrank();

        // It launches happily today.
        vm.prank(creator);
        factory.launchToken(_params("live"), configId, otherBrand, new address[](0));

        // The owner retires the reserve and forgets the brand.
        vm.prank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), false);

        uint256 feeBefore = IERC20(otherBrand).balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.ReserveNotApproved.selector, address(otherReserve))
        );
        factory.launchToken(_params("dead"), configId, otherBrand, new address[](0));

        assertEq(IERC20(otherBrand).balanceOf(creator), feeBefore, "fee moved on a dead launch");
    }

    /// @dev `assetPriceE18` is what the graduated pool opens at, and its truncation strands
    ///      that fraction of the seed. Terms coarse enough to strand a visible share of the
    ///      raise are refused rather than silently paid to the protocol as "dust".
    function test_launchIsRefusedWhenTheGraduatedPriceWouldBeTooCoarse() public {
        // Shipped terms clear the floor by nine orders of magnitude.
        (address ok,) = _launch(creator, "fine");
        assertTrue(ok != address(0));

        // Raising the supply against the same threshold drives the price down one-for-one:
        // 1e27 seeds at ~1.13e13, so 1e38 seeds at ~1.13e2 — below the 1e4 floor.
        vm.prank(owner);
        uint256 coarse = factory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: 1e38, curveFeeBps: 100, poolFee: 5_000, enabled: true
            })
        );

        vm.startPrank(creator);
        IERC20(brand).approve(address(factory), LAUNCH_FEE);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.SeedPriceTooCoarse.selector, 113, 1e4));
        factory.launchToken(_params("s8"), coarse, brand, new address[](0));
        vm.stopPrank();
    }
}
