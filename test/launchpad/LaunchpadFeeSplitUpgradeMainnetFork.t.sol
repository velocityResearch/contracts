// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {
    ILaunchFeeEscrow,
    ILaunchFactory,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";

/// @title LaunchpadFeeSplitUpgradeMainnetForkTest
/// @notice Proves `UpgradeLaunchpadFeeSplitMainnet` against live Robinhood Chain state, from the
///         account that owns it. The upgrade has landed; this re-sends it on a fork.
///
/// @dev    The economics of the two-rate split are proved offline, on a stack this suite builds
///         from scratch (`LaunchLockerTest`, `LaunchJourneyV4Fork`). What only live state can
///         answer is whether the upgrade lands on the deployed proxy without disturbing it, and
///         that is this file's job:
///
///         - the new `graduatedCreatorYieldShareBps` shares a slot with two variables the live
///           proxy has already written, so if the packing is wrong the damage shows up as a
///           moved mapping rather than as a compile error;
///         - the rate has to be *set* after the upgrade, because the live proxy's `initialize`
///           ran under the old default and will never run again;
///         - the locker is not upgradeable, so the link has to be rotated across three
///           contracts, one of which is owned by a different factory;
///         - and the link has to survive the rotation with the old locker left holding nothing,
///           because a stranded position is the one failure the approach cannot undo.
///
///         Defaults to the chain head because this RPC's historical window is short; pin with
///         `LAUNCHPAD_UPGRADE_FORK_BLOCK`/`LAUNCHPAD_UPGRADE_FORK_URL` for a reproducible run.
///
///         Reproduce:
///         forge test --match-contract LaunchpadFeeSplitUpgradeMainnetFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com
contract LaunchpadFeeSplitUpgradeMainnetForkTest is Test {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    /// @dev Ownership of every launchpad handle was handed over to the 2-of-3 Safe, so the
    ///      owner-only calls below have to come from it. The deployer EOA that signed the
    ///      original deployment is retired and owns nothing on this chain any more.
    address constant SAFE = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;
    address constant MARKET_FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    address constant FEE_ESCROW = 0xb1BeEbb3c077705273bcC4F80f560F43941205b6;
    address constant OLD_LOCKER = 0xEDdCe1d6ea0bFa375D03114b46ac552a4463398b;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string constant DEFAULT_FORK_URL = "https://rpc.mainnet.chain.robinhood.com";

    LaunchFactory factory;
    AssetMarketFactory marketFactory;

    function setUp() public {
        string memory url = vm.envOr("LAUNCHPAD_UPGRADE_FORK_URL", DEFAULT_FORK_URL);
        uint256 pinned = vm.envOr("LAUNCHPAD_UPGRADE_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        factory = LaunchFactory(LAUNCH_FACTORY);
        marketFactory = AssetMarketFactory(MARKET_FACTORY);
    }

    /// @dev The script's steps in the script's order. Kept here rather than imported because a
    ///      `Script` and a `Test` cannot be inherited together; the script's own `_verify`
    ///      re-checks everything asserted below at broadcast time.
    ///
    ///      This no longer sets the graduated shares. They are LIVE on chain at 40/30/30 since
    ///      the split shipped, and re-setting them here would both be a no-op and a lie about
    ///      what the upgrade does. `setGraduatedCreatorShareBps(10_000)` does not merely fail
    ///      to be current, it now REVERTS: the creator share and `graduatedLpFundShareBps`
    ///      must sum to at most 10,000, and the LP fund holds 3,000 of it.
    function _upgrade() internal returns (LaunchLocker locker, LaunchGraduation graduation) {
        LaunchFactory freshImplementation = new LaunchFactory();

        vm.prank(SAFE);
        factory.upgradeToAndCall(address(freshImplementation), "");

        locker = new LaunchLocker(SAFE, LAUNCH_FACTORY);
        graduation = new LaunchGraduation(
            LAUNCH_FACTORY,
            marketFactory,
            IPositionManagerV4(POSM),
            IPermit2(PERMIT2),
            ILaunchLocker(address(locker)),
            ILaunchFeeEscrow(FEE_ESCROW)
        );

        vm.startPrank(SAFE);
        locker.setGraduation(address(graduation));
        factory.setGraduation(ILaunchGraduation(address(graduation)));
        marketFactory.setLaunchpad(address(graduation));
        vm.stopPrank();
    }

    function test_fork_theUpgradeLandsAndLeavesEveryOtherAnswerWhereItWas() public {
        address implementationBefore = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        address launchDeployerBefore = address(factory.launchDeployer());
        address forwarderBefore = factory.launchForwarder();
        address recipientBefore = factory.protocolFeeRecipient();
        uint256 protocolFeeShareBefore = factory.protocolFeeShareBps();
        uint256 launchCountBefore = factory.launchCount();
        bool enabledBefore = factory.launchEnabled();

        (LaunchLocker locker, LaunchGraduation graduation) = _upgrade();

        address implementationAfter = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        assertTrue(implementationAfter != implementationBefore, "the implementation moved");
        console.log("implementation before:", implementationBefore);
        console.log("implementation after: ", implementationAfter);

        // The slot the new variables pack into also holds `launchEnabled`. A bad layout shows
        // up here, or in the mapping reads below. These are the live 40/30/30 split: the
        // creator takes 40% of graduated fees, the LP fund 30%, the protocol the rest.
        assertEq(factory.graduatedCreatorShareBps(), 4_000, "creator keeps 40%");
        assertEq(factory.graduatedLpFundShareBps(), 3_000, "the LP fund takes 30%");
        assertEq(factory.graduatedCreatorYieldShareBps(), 4_000, "and 40% of the yield");
        assertEq(factory.lpFundShareBps(), 3_000, "the curve-fee LP fund share matches");
        assertEq(factory.launchEnabled(), enabledBefore, "and launchEnabled is untouched");

        // Everything else on the proxy reads back exactly as it did.
        assertEq(factory.owner(), SAFE, "owner");
        assertEq(address(factory.marketFactory()), MARKET_FACTORY, "market factory");
        assertEq(address(factory.feeEscrow()), FEE_ESCROW, "fee escrow");
        assertEq(address(factory.launchDeployer()), launchDeployerBefore, "launch deployer");
        assertEq(address(factory.positionManager()), POSM, "position manager");
        assertEq(factory.launchForwarder(), forwarderBefore, "launch forwarder");
        assertEq(factory.protocolFeeRecipient(), recipientBefore, "protocol fee recipient");
        assertEq(factory.protocolFeeShareBps(), protocolFeeShareBefore, "curve fee share");
        assertEq(factory.launchCount(), launchCountBefore, "launch count");

        // Both sides of the link, and the module's own immutables.
        assertEq(address(factory.graduation()), address(graduation), "factory repointed");
        assertEq(marketFactory.launchpad(), address(graduation), "market factory repointed");
        assertEq(locker.graduation(), address(graduation), "locker wired");
        assertEq(locker.factory(), LAUNCH_FACTORY, "locker names this factory");
        assertEq(address(graduation.locker()), address(locker), "module names this locker");
        assertEq(address(graduation.feeEscrow()), FEE_ESCROW, "module names the live escrow");
        assertEq(address(graduation.permit2()), PERMIT2, "module names canonical permit2");
    }

    /// @notice The mapping that lives immediately below the repacked slot, and the records the
    ///         creators were sold. A launch already on a curve must read back byte for byte:
    ///         raising the default does not and must not reprice it.
    function test_fork_everyLiveLaunchRecordSurvivesAndKeepsItsOwnRate() public {
        uint256 count = factory.launchCount();
        ILaunchFactory.LaunchedToken[] memory before = new ILaunchFactory.LaunchedToken[](count);
        for (uint256 i; i < count; ++i) {
            before[i] = factory.getLaunchedToken(factory.launchAt(i));
        }

        _upgrade();

        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            ILaunchFactory.LaunchedToken memory now_ = factory.getLaunchedToken(token);
            ILaunchFactory.LaunchedToken memory was = before[i];

            assertEq(now_.token, was.token, "token");
            assertEq(now_.curve, was.curve, "curve");
            assertEq(now_.deployer, was.deployer, "deployer");
            assertEq(now_.creatorFeeRecipient, was.creatorFeeRecipient, "creator recipient");
            assertEq(now_.pairToken, was.pairToken, "quote brand");
            assertEq(now_.reserve, was.reserve, "reserve");
            assertEq(now_.graduationThreshold, was.graduationThreshold, "threshold");
            assertEq(now_.poolFee, was.poolFee, "pool fee tier");
            assertEq(now_.creatorTaxBps, was.creatorTaxBps, "creator tax");
            assertEq(now_.creatorShareBps, was.creatorShareBps, "the rate it was sold");
            assertEq(uint8(now_.phase), uint8(was.phase), "phase");
            assertEq(now_.marketId, was.marketId, "market id");
            assertTrue(now_.exists, "record still exists");

            // The record is what graduation reads, so a launch already trading graduates on
            // its own snapshot and not on the new default.
            assertEq(
                factory.getLaunchedToken(token).creatorShareBps,
                was.creatorShareBps,
                "the new default did not reach a launch already on a curve"
            );
        }
    }

    /// @notice The knob the whole change exists for: settable after the upgrade, bounded, and
    ///         effective on every position rather than snapshotted like the fee share.
    ///
    ///         The ceiling is not a flat 10,000. The creator's yield share and the LP fund's
    ///         graduated share are drawn from the same 10,000, so with the fund on 3,000 the
    ///         creator can reach 7,000 and no further. That coupling is the thing worth
    ///         pinning: it is what stops the two knobs from together over-committing the pot.
    function test_fork_theYieldKnobIsLiveAndBounded() public {
        _upgrade();

        uint256 lpFund = factory.graduatedLpFundShareBps();
        uint16 ceiling = uint16(10_000 - lpFund);

        vm.prank(SAFE);
        factory.setGraduatedCreatorYieldShareBps(5_000);
        assertEq(factory.graduatedCreatorYieldShareBps(), 5_000, "moved");

        vm.prank(SAFE);
        factory.setGraduatedCreatorYieldShareBps(ceiling);
        assertEq(factory.graduatedCreatorYieldShareBps(), ceiling, "the ceiling is reachable");

        vm.prank(SAFE);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedCreatorYieldShareBps(ceiling + 1);

        address stranger = address(0xBEEF);
        vm.prank(stranger);
        vm.expectRevert();
        factory.setGraduatedCreatorYieldShareBps(0);

        vm.prank(SAFE);
        factory.setGraduatedCreatorYieldShareBps(4_000);
        assertEq(factory.graduatedCreatorYieldShareBps(), 4_000, "and back to the live value");
    }

    /// @notice The old locker keeps whatever it holds. Nothing in this upgrade migrates a
    ///         position, which is exactly why the script refuses to run once one exists.
    function test_fork_theOldLockerIsLeftHoldingNothing() public {
        (LaunchLocker locker,) = _upgrade();

        uint256 count = factory.launchCount();
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            assertFalse(
                LaunchLocker(OLD_LOCKER).lockedPosition(token).exists,
                "the old locker holds no position for a live launch"
            );
            assertEq(LaunchLocker(OLD_LOCKER).lockedSupply(token), 0, "and no locked supply");
            assertFalse(locker.lockedPosition(token).exists, "the new one holds nothing yet");
        }
    }
}
