// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchDeployer} from "../../src/launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {ProtocolStack} from "../../src/upgrade/ProtocolStack.sol";

import {DeployLaunchpad, LaunchpadDefaults} from "../../script/DeployLaunchpad.s.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StandInPermit2, StandInPositionManager} from "../markets/MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title LaunchpadDeploymentTest
/// @notice A rehearsal of `script/DeployLaunchpad.s.sol`, not a tour of its getters.
///
///         The launchpad's wiring is four calls that can each be made exactly once —
///         `LaunchLocker.setGraduation`, `LaunchFactory.setLaunchDeployer`,
///         `LaunchFactory.setGraduation` and, on the market factory, `setLaunchpad`. A
///         deployment that gets one of them wrong is not repairable by re-running anything:
///         the factory proxy has to be replaced. So this suite runs the real
///         `ProtocolStack.deployLaunchpad` and the real `LaunchpadDefaults` against a live
///         market stack, checks the wiring it produced from the deployed contracts, proves
///         each one-shot is spent, and then launches a token and buys on its curve — because
///         the only assertion that actually covers the deployment is one that uses it.
///
///         The test contract is the deploying key: `deployLaunchpad` performs owner-gated
///         wiring as its caller, which is exactly the constraint the script runs under.
contract LaunchpadDeploymentTest is StackFixture, DeployLaunchpad {
    uint24 internal constant PROTOCOL_FEE_PIPS = 1_000; // 0.10%

    PoolManager internal manager;
    ProtocolFeeHook internal hook;
    StandInPermit2 internal permit2;
    StandInPositionManager internal posm;

    MockUSDC internal usdg;
    MockYieldSource internal yieldSource;
    SharedReservePool internal reserve;
    AssetMarketFactory internal marketFactory;

    ProtocolStack.Launchpad internal lp;
    address internal quoteBrand;
    uint256 internal launchConfigId;

    address internal protocolTreasury = address(0xF33);
    address internal protocolFeeRecipient = address(0xFEE);
    address internal lpFundRecipient = address(0x11FD);
    address internal creator = address(0x0FE);
    address internal creatorFeeRecipient = address(0xC0FE);
    address internal trader = address(0x7AAD);

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
            address(this)
        );

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), address(this));

        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        marketFactory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0),
            0,
            address(this)
        );
        hook.setRegistrar(address(marketFactory));
        marketFactory.setProtocolFeePips(PROTOCOL_FEE_PIPS);

        // ─── The deployment under test, in the script's order ────────────
        lp = ProtocolStack.deployLaunchpad(
            address(this),
            address(protocolGuard),
            marketFactory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2))
        );
        marketFactory.setLaunchpad(address(lp.graduation));
        launchConfigId =
            LaunchpadDefaults.applyPolicy(lp.factory, protocolFeeRecipient, lpFundRecipient);

        (quoteBrand,) = marketFactory.registerBrand("Launch Dollar", "launchUSD");
        LaunchpadDefaults.approveQuoteBrand(
            lp.factory,
            quoteBrand,
            address(reserve),
            LaunchpadDefaults.PHANTOM_QUOTE,
            LaunchpadDefaults.GRADUATION_THRESHOLD,
            LaunchpadDefaults.LAUNCH_FEE,
            LaunchpadDefaults.QUOTE_DECIMALS
        );
        lp.factory.setLaunchEnabled(true);
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    /// @notice Both directions of every link, read off the deployed contracts. A launchpad
    ///         missing any one of these deploys, verifies by eye and then fails on a launch or
    ///         on a graduation.
    function test_deploymentWiresEveryLinkInBothDirections() public view {
        // The launch factory's view of its helpers.
        assertEq(
            address(lp.factory.launchDeployer()), address(lp.launchDeployer), "launch deployer"
        );
        assertEq(address(lp.factory.graduation()), address(lp.graduation), "graduation");
        assertEq(lp.factory.launchForwarder(), address(lp.router), "launch forwarder");
        assertEq(address(lp.factory.feeEscrow()), address(lp.feeEscrow), "fee escrow");
        assertEq(address(lp.factory.marketFactory()), address(marketFactory), "market factory");
        assertEq(address(lp.factory.positionManager()), address(posm), "position manager");
        assertEq(address(lp.factory.guard()), address(protocolGuard), "guard");
        assertEq(lp.factory.owner(), address(this), "launch factory owner");
        assertEq(
            address(lp.factory.graduationGuard()),
            address(lp.graduationGuard),
            "graduation guard recorded"
        );
        assertTrue(address(lp.graduationGuard).code.length > 0, "graduation guard has code");

        // Each helper's view of the factory, which is what their onlyFactory gates read.
        assertEq(lp.launchDeployer.factory(), address(lp.factory), "deployer -> factory");
        assertEq(lp.graduation.factory(), address(lp.factory), "graduation -> factory");
        assertEq(lp.locker.factory(), address(lp.factory), "locker -> factory");
        assertEq(address(lp.router.factory()), address(lp.factory), "router -> factory");

        // The locker and the graduation module, which is the pair that has to agree for a
        // graduated position to be recorded at all.
        assertEq(lp.locker.graduation(), address(lp.graduation), "locker -> graduation");
        assertEq(address(lp.graduation.locker()), address(lp.locker), "graduation -> locker");
        assertEq(lp.locker.owner(), address(this), "locker owner");

        // The venue, which the graduation module derives rather than accepts.
        assertEq(address(lp.graduation.marketFactory()), address(marketFactory), "market factory");
        assertEq(address(lp.graduation.poolManager()), address(manager), "pool manager");
        assertEq(address(lp.graduation.positionManager()), address(posm), "position manager");
        assertEq(address(lp.graduation.permit2()), address(permit2), "permit2");
        assertEq(address(lp.graduation.feeEscrow()), address(lp.feeEscrow), "graduation escrow");

        // The one link on the market factory. Without it phase two reverts OnlyLaunchpad.
        assertEq(marketFactory.launchpad(), address(lp.graduation), "market factory launchpad");
    }

    /// @notice **The factory's wiring rotates; the locker's does not.** The asymmetry is the
    ///         point, and it follows from what each one holds.
    ///
    ///         The factory's deployer and graduation module are replaceable because neither
    ///         holds anything between transactions and because the factory is a UUPS proxy
    ///         whose owner could repoint them by upgrading anyway — a one-shot setter only
    ///         stopped the honest operator from fixing a defective module without abandoning
    ///         every launch record. `LaunchGraduation`'s own documentation says it was split
    ///         out so it could be "replaced independently"; this is what makes that true.
    ///
    ///         The locker's graduation link stays one-shot because the locker holds the
    ///         permanently locked LP positions. Repointing it would let a second module record
    ///         positions against custody the first one established.
    function test_theFactorysWiringRotatesButTheLockersDoesNot() public {
        // A replacement module, wired to this same factory.
        LaunchGraduation replacement = new LaunchGraduation(
            address(lp.factory),
            marketFactory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ILaunchLocker(address(lp.locker)),
            ILaunchFeeEscrow(address(lp.feeEscrow))
        );

        lp.factory.setGraduation(ILaunchGraduation(address(replacement)));
        assertEq(
            address(lp.factory.graduation()), address(replacement), "graduation module rotated"
        );

        LaunchDeployer newDeployer = new LaunchDeployer(address(lp.factory));
        lp.factory.setLaunchDeployer(newDeployer);
        assertEq(
            address(lp.factory.launchDeployer()), address(newDeployer), "launch deployer rotated"
        );

        // Rotation still refuses a module that answers to a different factory, which is the
        // check that makes the setter safe to leave open.
        LaunchGraduation foreign = new LaunchGraduation(
            address(0xBEEF),
            marketFactory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ILaunchLocker(address(lp.locker)),
            ILaunchFeeEscrow(address(lp.feeEscrow))
        );
        vm.expectRevert(LaunchFactory.LaunchDependenciesNotWired.selector);
        lp.factory.setGraduation(ILaunchGraduation(address(foreign)));

        // And it refuses zero, so the path cannot be closed by accident.
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        lp.factory.setGraduation(ILaunchGraduation(address(0)));

        // The locker, by contrast, is spent for good.
        vm.expectRevert(LaunchLocker.AlreadyInitialized.selector);
        lp.locker.setGraduation(address(replacement));
    }

    /// @notice The escrow can be repointed for future revenue without stranding past revenue,
    ///         because a `LaunchFeeEscrow` balance is claimable from the escrow that recorded
    ///         it, gated on nothing but the claimant's own ledger entry.
    function test_theFeeEscrowCanBeRepointedWithoutStrandingCreditedBalances() public {
        LaunchFeeEscrow successor = new LaunchFeeEscrow();

        lp.factory.setFeeEscrow(ILaunchFeeEscrow(address(successor)));
        assertEq(address(lp.factory.feeEscrow()), address(successor), "escrow rotated");

        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        lp.factory.setFeeEscrow(ILaunchFeeEscrow(address(0)));
    }

    /// @notice The launch terms the deployment applies are the shipped ones. Each of these is
    ///         snapshotted into every curve and every launch record, so a wrong figure here is
    ///         permanent for the launches created under it.
    function test_deploymentAppliesTheShippedTerms() public view {
        assertEq(lp.factory.protocolFeeRecipient(), protocolFeeRecipient, "fee recipient");
        assertEq(lp.factory.protocolFeeShareBps(), 3_000, "protocol fee share");
        assertEq(lp.factory.maxCreatorTaxBps(), 1_000, "max creator tax");
        assertEq(lp.factory.snipeTaxStartBps(), 9_900, "snipe tax start");
        assertEq(lp.factory.snipeTaxSeconds(), 15, "snipe tax window");
        assertEq(lp.factory.graduatedCreatorShareBps(), 4_000, "graduated creator fee share");
        assertEq(lp.factory.graduatedCreatorYieldShareBps(), 4_000, "graduated creator yield share");
        assertEq(lp.factory.lpFundRecipient(), lpFundRecipient, "LP fund recipient");
        assertEq(lp.factory.lpFundShareBps(), 3_000, "LP fund share of the curve fee");
        assertEq(lp.factory.graduatedLpFundShareBps(), 3_000, "LP fund share after graduation");
        assertTrue(lp.factory.launchEnabled(), "launching enabled");

        LaunchFactory.LaunchConfig memory config = lp.factory.getLaunchConfig(launchConfigId);
        assertEq(config.supply, 1e27, "supply");
        assertEq(config.curveFeeBps, 100, "curve fee");
        assertEq(config.poolFee, 5_000, "pool fee");
        assertTrue(config.enabled, "config enabled");

        (
            address brandReserve,
            uint256 phantom,
            uint256 threshold,
            uint256 fee,
            uint8 dec,
            bool ok
        ) = lp.factory.pairTokenEconomics(quoteBrand);
        assertEq(brandReserve, address(reserve), "brand reserve");
        assertEq(phantom, 3_236e6, "phantom quote");
        assertEq(threshold, 8_090e6, "graduation threshold");
        assertEq(fee, 1e6, "launch fee");
        assertEq(dec, 6, "brand decimals");
        assertTrue(ok, "brand approved");
    }

    // ─── Rehearsal ───────────────────────────────────────────────────────

    /// @notice The deployment actually launches: a token off the configured config and brand,
    ///         then a buy on its curve. Everything the wiring assertions above can only imply
    ///         — the deployer's CREATE2 pair, the curve's snapshotted policy, the launch fee
    ///         path, the escrow credit — is exercised once here.
    function test_deployedLaunchpadLaunchesAndTrades() public {
        _fundQuote(creator, LaunchpadDefaults.LAUNCH_FEE);

        vm.startPrank(creator);
        IERC20(quoteBrand).approve(address(lp.factory), LaunchpadDefaults.LAUNCH_FEE);
        (address token, address curve) = lp.factory
            .launchToken(
                _tokenParams("Rehearsal", "REH", keccak256("REH")),
                launchConfigId,
                quoteBrand,
                new address[](0)
            );
        vm.stopPrank();

        // The launch fee went to the configured recipient, and the whole supply to the curve.
        assertEq(
            IERC20(quoteBrand).balanceOf(protocolFeeRecipient),
            LaunchpadDefaults.LAUNCH_FEE,
            "launch fee paid to the configured recipient"
        );
        assertEq(IERC20(token).balanceOf(curve), 1e27, "whole supply minted to the curve");
        assertEq(LaunchCurve(curve).pairToken(), quoteBrand, "curve quotes the approved brand");
        assertEq(
            LaunchCurve(curve).graduationThreshold(), 8_090e6, "curve took the brand's threshold"
        );

        LaunchFactory.LaunchedToken memory record = lp.factory.getLaunchedToken(token);
        assertEq(record.curve, curve, "launch record names the curve");
        assertEq(record.reserve, address(reserve), "launch record names the reserve");
        assertEq(record.creatorShareBps, 4_000, "launch record snapshotted the fee share");

        // One buy, past the snipe-tax window so the price is the curve's own.
        vm.warp(vm.getBlockTimestamp() + lp.factory.snipeTaxSeconds() + 1);
        uint256 quoteIn = 1_000e6;
        (uint256 expectedOut,,) = LaunchCurve(curve).quoteBuy(quoteIn, trader);
        _fundQuote(trader, quoteIn);

        vm.startPrank(trader);
        IERC20(quoteBrand).approve(curve, quoteIn);
        uint256 tokensOut = LaunchCurve(curve).buy(quoteIn, expectedOut, trader);
        vm.stopPrank();

        assertEq(tokensOut, expectedOut, "buy filled at the quoted amount");
        assertEq(IERC20(token).balanceOf(trader), tokensOut, "trader holds the tokens");
        assertEq(LaunchCurve(curve).realQuoteReserve(), quoteIn - quoteIn / 100, "float net of fee");

        // The curve's fee split is the deployed policy, paid through the deployed escrow.
        LaunchCurve(curve).sweepFees();
        uint256 curveFee = quoteIn / 100;
        assertEq(
            lp.feeEscrow.balanceOfToken(protocolFeeRecipient, quoteBrand),
            curveFee * 3_000 / 10_000,
            "protocol share credited to the deployed escrow"
        );
        assertEq(
            lp.feeEscrow.balanceOfToken(lpFundRecipient, quoteBrand),
            curveFee * 3_000 / 10_000,
            "LP fund share credited to the same escrow"
        );
        assertEq(
            lp.feeEscrow.balanceOfToken(creatorFeeRecipient, quoteBrand),
            curveFee - 2 * (curveFee * 3_000 / 10_000),
            "creator share credited to the deployed escrow"
        );
    }

    // ─── The script's own preflight ───────────────────────────────────────

    /// @notice A market factory that already has a launchpad is not retargeted by accident.
    ///         Moving it orphans whatever launches are mid-graduation on the old module, which
    ///         is why the escape hatch is a variable the operator has to type.
    function test_preflightRefusesToRetargetALiveLaunchpad() public {
        Env memory e = _scriptEnv();
        e.replaceLaunchpad = false;
        vm.expectRevert(
            bytes("market factory already has a launchpad; set REPLACE_LAUNCHPAD=true to move it")
        );
        this.checkEnv(e);
    }

    /// @notice A `PositionManager` from another venue is refused before anything is deployed.
    ///         It would mint the locked position into a pool of a singleton the market's
    ///         distributor has never heard of, and the failure would surface on the first
    ///         graduation — after the one-shot wiring had been spent.
    function test_preflightRefusesAPositionManagerFromAnotherVenue() public {
        PoolManager otherManager = new PoolManager(address(this));
        Env memory e = _scriptEnv();
        e.positionManager = IPositionManagerV4(
            address(new StandInPositionManager(IPoolManager(address(otherManager)), permit2))
        );
        vm.expectRevert(bytes("PositionManager answers to a different PoolManager"));
        this.checkEnv(e);
    }

    /// @notice A reserve the market factory does not register units in is refused: graduation
    ///         swaps the curve's float into the new market's unit inside that reserve, so a
    ///         brand from anywhere else has no 1:1 path and every graduation would revert.
    function test_preflightRefusesAnUnknownReserve() public {
        Env memory e = _scriptEnv();
        e.reservePool = _deployReservePool(address(usdg), address(yieldSource), address(this));
        vm.expectRevert(bytes("SHARED_RESERVE_POOL is not the factory's default nor approved"));
        this.checkEnv(e);
    }

    /// @notice A quote brand that is not registered in the reserve is refused here rather than
    ///         by `setPairTokenEconomics` halfway through the configuration.
    function test_preflightRefusesABrandTheReserveDoesNotHold() public {
        Env memory e = _scriptEnv();
        e.quoteBrand = address(usdg);
        vm.expectRevert(bytes("LAUNCH_QUOTE_BRAND is not registered in SHARED_RESERVE_POOL"));
        this.checkEnv(e);
    }

    /// @notice A guard other than the market stack's is refused. The launchpad would pause
    ///         independently of the markets it graduates into.
    function test_preflightRefusesAForeignGuard() public {
        Env memory e = _scriptEnv();
        e.guard = address(0xBEEF);
        vm.expectRevert(bytes("PROTOCOL_GUARD is not the factory's"));
        this.checkEnv(e);
    }

    /// @dev An external wrapper, because `vm.expectRevert` binds to a CALL and the preflight is
    ///      an internal function of the script this contract inherits.
    function checkEnv(Env memory e) external view {
        _checkEnv(e);
    }

    /// @dev The inputs the script would have resolved for this stack, all valid. Each test
    ///      corrupts exactly one field.
    function _scriptEnv() private view returns (Env memory e) {
        e.deployer = address(this);
        e.marketFactory = marketFactory;
        e.reservePool = reserve;
        e.guard = address(protocolGuard);
        e.positionManager = IPositionManagerV4(address(posm));
        e.permit2 = IPermit2(address(permit2));
        e.protocolFeeRecipient = protocolFeeRecipient;
        e.lpFundRecipient = lpFundRecipient;
        e.quoteBrand = quoteBrand;
        e.quoteDecimals = LaunchpadDefaults.QUOTE_DECIMALS;
        e.phantomQuote = LaunchpadDefaults.PHANTOM_QUOTE;
        e.graduationThreshold = LaunchpadDefaults.GRADUATION_THRESHOLD;
        e.launchFee = LaunchpadDefaults.LAUNCH_FEE;
        // setUp already registered the graduation module with the market factory, which is the
        // state a re-run would find.
        e.replaceLaunchpad = true;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _fundQuote(address who, uint256 amount) private {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(quoteBrand, amount, who);
        vm.stopPrank();
    }

    function _tokenParams(string memory name, string memory symbol, bytes32 salt)
        private
        view
        returns (LaunchFactory.TokenParams memory)
    {
        return LaunchFactory.TokenParams({
            name: name,
            symbol: symbol,
            logo: "",
            description: "",
            socials: LaunchToken.Socials({
                twitter: "", telegram: "", discord: "", website: "", farcaster: ""
            }),
            creatorFeeRecipient: creatorFeeRecipient,
            creatorTaxBps: 0,
            expectedEconomics: lp.factory.previewLaunchEconomics(launchConfigId, quoteBrand),
            salt: salt
        });
    }
}
