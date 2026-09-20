// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {
    GraduationPhase,
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";

/// @title LaunchpadLpFundUpgradeMainnetForkTest
/// @notice Proves `UpgradeLaunchpadLpFundMainnet` against live Robinhood Chain state, from the
///         account that owns it.
///
/// @dev    The economics of the three-way split are proved offline on a stack built from
///         scratch (`LaunchCurveTest`, `LaunchLockerTest`). What only live state can answer is
///         whether the upgrade lands on the deployed proxy without disturbing it, and this
///         upgrade has two properties that make that question sharper than usual:
///
///         - `lpFundRecipient`, `lpFundShareBps` and `graduatedLpFundShareBps` are an address
///           and two `uint16`s appended into a slot the live proxy has ALREADY written three
///           values into. If the packing is wrong the damage is a moved mapping, not a compile
///           error, so the test reads the neighbours back through the proxy afterwards and
///           also reads a launch record, which lives below the packed slot in a mapping.
///         - three launches have already graduated and their positions are staked under the
///           current locker, which has no third recipient. They must keep collecting. That is
///           asserted directly, because it is the one outcome that cannot be undone after the
///           fact and the reason this script does not refuse to run the way its predecessor
///           did.
///
///         Defaults to the chain head because this RPC's historical window is short; pin with
///         `LP_FUND_UPGRADE_FORK_BLOCK`/`LP_FUND_UPGRADE_FORK_URL` for a reproducible run.
///
///         Reproduce:
///         forge test --match-contract LaunchpadLpFundUpgradeMainnetFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com
contract LaunchpadLpFundUpgradeMainnetForkTest is Test {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    /// @dev Ownership of every launchpad handle was handed over to the 2-of-3 Safe, so the
    ///      owner-only calls below have to come from it. The deployer EOA that signed the
    ///      original deployment is retired and owns nothing on this chain any more.
    address constant SAFE = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;
    address constant MARKET_FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    address constant FEE_ESCROW = 0xb1BeEbb3c077705273bcC4F80f560F43941205b6;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @dev Stands in for the fund until it has an address of its own. The script takes it
    ///      from `LAUNCH_LP_FUND_RECIPIENT`; what matters here is only that it is not zero and
    ///      not the protocol's own recipient, so the two legs are distinguishable.
    address constant LP_FUND = address(0x11FD);

    /// @dev The locker in use before this upgrade landed on 2026-09-19. The three launches that
    ///      had already graduated by then (markets 16, 17, 18) keep their positions staked here
    ///      forever, because nothing moves a staked position between lockers.
    address constant PRE_LP_FUND_LOCKER = 0xACf51B066b90596e8536A1423Df4A6b94D5815c9;

    uint16 constant PROTOCOL_FEE_SHARE_BPS = 3_000;
    uint16 constant LP_FUND_SHARE_BPS = 3_000;
    uint16 constant CREATOR_FEE_SHARE_BPS = 4_000;
    uint16 constant CREATOR_YIELD_SHARE_BPS = 4_000;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string constant DEFAULT_FORK_URL = "https://rpc.mainnet.chain.robinhood.com";

    LaunchFactory factory;
    AssetMarketFactory marketFactory;

    function setUp() public {
        string memory url = vm.envOr("LP_FUND_UPGRADE_FORK_URL", DEFAULT_FORK_URL);
        uint256 pinned = vm.envOr("LP_FUND_UPGRADE_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        factory = LaunchFactory(LAUNCH_FACTORY);
        marketFactory = AssetMarketFactory(MARKET_FACTORY);
    }

    /// @dev The script's four steps in the script's order, including the ordering constraint
    ///      that the recipient is set before any share. Kept here rather than imported because
    ///      a `Script` and a `Test` cannot be inherited together.
    function _upgrade() internal returns (LaunchLocker locker, LaunchGraduation graduation) {
        LaunchFactory freshImplementation = new LaunchFactory();

        vm.startPrank(SAFE);
        factory.upgradeToAndCall(address(freshImplementation), "");
        factory.setLpFundRecipient(LP_FUND);
        factory.setProtocolFeeShareBps(PROTOCOL_FEE_SHARE_BPS);
        factory.setLpFundShareBps(LP_FUND_SHARE_BPS);
        factory.setGraduatedCreatorShareBps(CREATOR_FEE_SHARE_BPS);
        factory.setGraduatedCreatorYieldShareBps(CREATOR_YIELD_SHARE_BPS);
        factory.setGraduatedLpFundShareBps(LP_FUND_SHARE_BPS);
        vm.stopPrank();

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
        address escrowBefore = address(factory.feeEscrow());
        address posmBefore = address(factory.positionManager());
        uint256 launchCountBefore = factory.launchCount();
        bool enabledBefore = factory.launchEnabled();
        uint256 configCountBefore = factory.launchConfigCount();

        // A record from the mapping that sits BELOW the packed slot. If the three appended
        // fields had consumed a fresh slot instead of the free bytes of an occupied one, every
        // mapping and array after it would shift and this read would come back wrong.
        address sampleToken = factory.launchAt(0);
        LaunchFactory.LaunchedToken memory recordBefore = factory.getLaunchedToken(sampleToken);

        (LaunchLocker locker, LaunchGraduation graduation) = _upgrade();

        assertTrue(
            address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT)))) != implementationBefore,
            "the proxy moved"
        );

        // The slot the three new fields pack into is the one holding graduatedCreatorShareBps,
        // launchEnabled and graduatedCreatorYieldShareBps. A bad layout shows up here.
        assertEq(factory.graduatedCreatorShareBps(), CREATOR_FEE_SHARE_BPS, "LP-fee share");
        assertEq(factory.launchEnabled(), enabledBefore, "launchEnabled is untouched");
        assertEq(factory.graduatedCreatorYieldShareBps(), CREATOR_YIELD_SHARE_BPS, "yield share");
        assertEq(factory.lpFundRecipient(), LP_FUND, "fund recipient");
        assertEq(factory.lpFundShareBps(), LP_FUND_SHARE_BPS, "fund share of the curve fee");
        assertEq(factory.graduatedLpFundShareBps(), LP_FUND_SHARE_BPS, "fund share after");

        // Everything else the proxy answers, read back through the proxy.
        assertEq(address(factory.launchDeployer()), launchDeployerBefore, "launch deployer");
        assertEq(factory.launchForwarder(), forwarderBefore, "forwarder");
        assertEq(factory.protocolFeeRecipient(), recipientBefore, "protocol fee recipient");
        assertEq(address(factory.feeEscrow()), escrowBefore, "fee escrow");
        assertEq(address(factory.positionManager()), posmBefore, "position manager");
        assertEq(factory.launchCount(), launchCountBefore, "launch count");
        assertEq(factory.launchConfigCount(), configCountBefore, "config count");
        assertEq(factory.protocolFeeShareBps(), PROTOCOL_FEE_SHARE_BPS, "protocol curve share");

        LaunchFactory.LaunchedToken memory recordAfter = factory.getLaunchedToken(sampleToken);
        assertEq(recordAfter.curve, recordBefore.curve, "the launch mapping did not shift");
        assertEq(recordAfter.pairToken, recordBefore.pairToken, "nor its brand");
        assertEq(recordAfter.reserve, recordBefore.reserve, "nor its reserve");
        assertEq(
            recordAfter.creatorShareBps,
            recordBefore.creatorShareBps,
            "and an existing launch keeps the LP-fee share it was sold"
        );

        // Both sides of the link.
        assertEq(address(factory.graduation()), address(graduation), "factory repointed");
        assertEq(marketFactory.launchpad(), address(graduation), "market factory repointed");
        assertEq(locker.graduation(), address(graduation), "locker wired");
        assertEq(address(graduation.locker()), address(locker), "module names the locker");
    }

    /// @notice The three launches that have already graduated keep their terms and keep
    ///         collecting. This is the property that makes it safe to rotate the locker with
    ///         positions already staked under the old one, and the reason this upgrade does
    ///         not refuse to run when a launch has graduated.
    function test_fork_alreadyGraduatedLaunchesKeepTheirTermsAndStayCollectable() public {
        // The locker those three positions are actually staked in. Pinned, not derived: this
        // upgrade has now LANDED on mainnet, so `factory.graduation().locker()` returns the NEW
        // locker and deriving it would look in the wrong place and find nothing. The positions
        // do not move between lockers, so this address is permanent history.
        address oldLocker = PRE_LP_FUND_LOCKER;
        uint256 count = factory.launchCount();

        address[] memory graduated = new address[](count);
        uint16[] memory sharesBefore = new uint16[](count);
        uint256 found;
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            LaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(token);
            if (rec.phase != GraduationPhase.Graduated) continue;
            graduated[found] = token;
            sharesBefore[found] = rec.creatorShareBps;
            ++found;
        }
        // Recorded rather than required: if the live chain ever has none, the assertions below
        // are vacuous and saying so is better than a green tick that proved nothing.
        console.log("already-graduated launches on the fork:", found);
        assertGt(found, 0, "the fork has at least one graduated launch to protect");

        _upgrade();

        for (uint256 i; i < found; ++i) {
            LaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(graduated[i]);
            assertEq(
                rec.creatorShareBps,
                sharesBefore[i],
                "a graduated launch's snapshotted LP-fee share is untouched by the upgrade"
            );
            // Its position is still held by the OLD locker, and the old locker still names a
            // graduation module and this factory, so its `collect` path is intact. Nothing
            // moves a position between lockers and nothing here tried to.
            assertGt(
                ILaunchLocker(oldLocker).lockedPosition(graduated[i]).tokenId,
                0,
                "the old locker still names its staked NFT"
            );
            assertTrue(
                ILaunchLocker(oldLocker).lockedPosition(graduated[i]).exists,
                "the old locker still holds this position"
            );
        }
    }

    /// @notice The guards that made the script's call order load-bearing, asserted against
    ///         whatever the live proxy holds now.
    ///
    ///         Two constraints existed and both were found by running this test rather than by
    ///         reading the setters: a share could not be set before a recipient, and
    ///         `graduatedCreatorShareBps` had to come DOWN from 10,000 before
    ///         `graduatedLpFundShareBps` could go UP to 3,000, because 13,000 exceeds a whole
    ///         leg.
    ///
    ///         Both of those were about the PRE-UPGRADE state, and the upgrade has since
    ///         landed: the recipient is set and the creator share is 4,000, so neither
    ///         precondition is reproducible on a fork of the chain as it is. Re-asserting them
    ///         would be asserting history. What is worth keeping is that the guards are still
    ///         armed, because they are what stops a future retune from wedging every sweep,
    ///         and those are reachable from any state.
    function test_fork_theShareGuardsAreStillArmed() public {
        vm.startPrank(SAFE);

        // The individual ceilings bind first at the live rates, so assert them as themselves.
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setLpFundShareBps(5_001);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedLpFundShareBps(5_001);

        // The PAIR bound is a separate guard and at the live rates it is unreachable, because
        // MAX_LP_FUND_SHARE_BPS (5,000) is tighter than the room the creator's 4,000 leaves.
        // Reaching it therefore requires raising a creator rate first, which is exactly the
        // ordering hazard this pair of guards exists to catch: neither setter can be moved
        // into a state the other would reject.
        factory.setGraduatedCreatorShareBps(6_000);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setGraduatedLpFundShareBps(5_000); // 6,000 + 5,000 exceeds a whole leg
        factory.setGraduatedCreatorShareBps(4_000); // put it back

        factory.setProtocolFeeShareBps(5_000);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        factory.setLpFundShareBps(5_001); // ceiling again; the pair bound allows 5,000 exactly
        factory.setLpFundShareBps(5_000); // 5,000 + 5,000 is exactly the whole, and allowed
        assertEq(factory.lpFundShareBps(), 5_000, "an exactly-whole split is permitted");
        factory.setProtocolFeeShareBps(3_000); // restore
        factory.setLpFundShareBps(3_000);

        // The recipient cannot be cleared while anything routes to it, which is the guard that
        // stops a nonzero rate ever pointing at address zero.
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.setLpFundRecipient(address(0));

        vm.stopPrank();

        // And the live configuration satisfies the invariant those guards defend.
        assertLe(
            factory.protocolFeeShareBps() + uint256(factory.lpFundShareBps()),
            10_000,
            "curve fee splits to at most the whole"
        );
        assertLe(
            uint256(factory.graduatedCreatorShareBps()) + factory.graduatedLpFundShareBps(),
            10_000,
            "LP-fee leg splits to at most the whole"
        );
        assertTrue(factory.lpFundRecipient() != address(0), "a funded leg has an address");
    }

    /// @notice A launch still on its curve keeps the split it was sold. The curve snapshotted
    ///         the two-way policy at initialize and is immutable, so the fund leg cannot reach
    ///         it. The proof is that the getter is absent from the deployed curve's bytecode
    ///         entirely, not merely zero.
    function test_fork_launchesAlreadyOnACurveAreNotRepriced() public {
        uint256 count = factory.launchCount();
        address curve;
        for (uint256 i; i < count; ++i) {
            LaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(factory.launchAt(i));
            if (rec.phase == GraduationPhase.NotGraduated) {
                curve = rec.curve;
                break;
            }
        }
        assertTrue(curve != address(0), "the fork has a launch still trading on its curve");

        _upgrade();

        assertEq(factory.lpFundShareBps(), LP_FUND_SHARE_BPS, "the factory has a fund share");
        // The curve predates the fund, so it does not merely hold a zero share: the getter is
        // not in its bytecode at all. Asserting the call fails is the stronger statement, and
        // it is why an old curve can never pay a fund leg no matter what the factory says.
        // A curve is immutable, so this is permanent rather than pending.
        (bool hasShare,) = curve.staticcall(abi.encodeWithSignature("lpFundShareBps()"));
        assertFalse(hasShare, "the live curve has no fund share to read");
        (bool hasRecipient,) = curve.staticcall(abi.encodeWithSignature("lpFundRecipient()"));
        assertFalse(hasRecipient, "nor a fund recipient");
    }
}

