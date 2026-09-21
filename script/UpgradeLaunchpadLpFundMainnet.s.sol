// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchGraduation} from "../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../src/launchpad/LaunchLocker.sol";
import {
    GraduationPhase,
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../src/launchpad/interfaces/ILaunchpad.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";

/// @notice Adds a third recipient to launchpad revenue. Every leg becomes 40% creator,
///         30% protocol, 30% LP fund, replacing today's 30/70 curve split and the
///         100%-creator / 0%-creator post-graduation pair.
///
/// @dev    **The float-yield leg this script split three ways is retired.** A locked position
///         now renounces its reward stream the moment it is recorded, so a graduated launch
///         earns no float yield and there is no second leg to divide;
///         `graduatedCreatorYieldShareBps` was deleted from `LaunchFactory` rather than set to
///         zero, because a rate nobody reads is a rate that gets switched back on by accident.
///         The step that wrote it is gone from here; the rest is kept as the record of what
///         was sent. `UpgradeGraduateIntoLaunchDollarMainnet` is the change that retired it.
///
///         **Where the fund's share comes from is the whole design.** On the curve the three
///         shares are peers: the protocol's and the fund's are stored rates, the creator is
///         paid the remainder, and all three are snapshotted into the curve at launch. After
///         graduation they are not peers. The creator's LP-fee share stays frozen per
///         position and the fund's cut is subtracted from the PROTOCOL's remainder, so the
///         fund's rate can be read live and moved later without ever repricing a term a
///         creator was sold. That asymmetry is what makes a live rate safe here, and it is
///         why there is one fund knob rather than three.
///
///         **Four steps. The first two are the whole change for new launches.**
///
///         1. Upgrade the `LaunchFactory` proxy. `lpFundRecipient`, `lpFundShareBps` and
///            `graduatedLpFundShareBps` are an address and two `uint16`s appended into the
///            slot `graduatedCreatorShareBps`, `launchEnabled` and the graduated-yield rate
///            (since retired) already share: 2 + 1 + 2 bytes leave 27 free and
///            the three new fields take 24 of them. Nothing below the slot moves, no mapping
///            or array shifts, and `upgradeToAndCall` carries empty calldata deliberately —
///            the new fields read the zero default, which is the fund leg switched off.
///         2. The rates, in an order that is load-bearing twice over. `setLpFundRecipient`
///            must come first, because every share setter refuses a nonzero rate while the
///            recipient is unset — that is what stops a half-applied run from crediting the
///            escrow to address zero and wedging every later sweep. Then
///            `setGraduatedCreatorShareBps` must come DOWN to 4,000 before
///            `setGraduatedLpFundShareBps` goes UP to 3,000: the live proxy still holds
///            10,000 for the creator's LP-fee share, so asking for the fund's share first
///            sums to 13,000 and is refused `InvalidBasisPoints`. Both constraints are
///            asserted against live state in
///            `test_fork_theSharesCannotBeAppliedOutOfOrder`, which is how the second one was
///            found — reading the setters was not enough.
///         3. Deploy a new `LaunchLocker` and a new `LaunchGraduation`. The locker is
///            deliberately not upgradeable — that is what makes "the liquidity is locked
///            forever" a property of the bytecode rather than a promise — so a three-way
///            `collect` can only arrive as a new deployment, and the graduation module holds
///            its locker as an immutable, so it is redeployed with it.
///         4. Point both factories at the new module: `LaunchFactory.setGraduation` and
///            `AssetMarketFactory.setLaunchpad`. Without the second, phase two of every
///            graduation reverts `OnlyLaunchpad`.
///
///         **This script does NOT refuse to run once a launch has graduated, and the
///         difference from `UpgradeLaunchpadFeeSplitMainnet` is deliberate.** That script
///         refused because the change it made was only expressible in the locker, so a
///         position left on the old one got nothing. Here the change is mostly in the factory,
///         and the old locker reads the factory's live rates. A position staked under the old
///         locker therefore keeps working: its LP fees keep paying the 100% its record was
///         snapshotted with. What it cannot have is a fund leg, because the old bytecode has
///         no third recipient. No value is lost and
///
///         The three launches in that position as of writing are markets 16, 17 and 18. The
///         script enumerates them and prints them, because an operator who does not know
///         which positions keep the old split will misreport the change rather than misapply
///         it.
///
///         **`_economicsDigest` changes.** `lpFundShareBps` joins it, because it is
///         snapshotted into the curve and therefore fixes the creator's remainder for the life
///         of the launch, which is exactly what the digest exists to let a creator pin.
///         `graduatedLpFundShareBps` stays out of it because it is read live and cannot move
///         what the creator is owed.
///
///         **`web-stable` needs no redeploy for this.** It reads the pin from the chain inside
///         the submit handler (`previewLaunchEconomics`, `launch-wizard.tsx`) rather than
///         computing the preimage itself, so a new field is transparent to it. The warning
///         still stands for any future client that reconstructs the digest locally: it would
///         produce a stale pin and every launch would revert `LaunchEconomicsMismatch`.
///         Passing zero waives the pin, so that would be a client bug, not a chain one.
///
///         Rehearsed against real chain state in
///         `test/launchpad/LaunchpadLpFundUpgradeMainnetFork.t.sol`.
///
///         The proxy is owned by the deployer EOA with no timelock, so every step here takes
///         effect the moment it is mined.
///
///         Usage:
///           DEPLOYER=0x… LAUNCH_LP_FUND_RECIPIENT=0x… PRIVATE_KEY=0x… \
///             forge script script/UpgradeLaunchpadLpFundMainnet.s.sol:UpgradeLaunchpadLpFundMainnet \
///             --rpc-url robinhood --broadcast --slow
contract UpgradeLaunchpadLpFundMainnet is Script {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The protocol's share of the curve fee. Unchanged from the live value; set again
    ///         so a run configures the whole split rather than half of it.
    uint16 constant PROTOCOL_FEE_SHARE_BPS = 3_000;
    /// @notice The LP fund's share, of the curve fee and of both post-graduation legs.
    uint16 constant LP_FUND_SHARE_BPS = 3_000;
    /// @notice The creator's share of a graduated position's LP fees, snapshotted per launch.
    uint16 constant CREATOR_FEE_SHARE_BPS = 4_000;

    /// @dev Everything read off the live proxies before the upgrade, so the post-checks compare
    ///      against what was actually there rather than against a constant in this file.
    struct Before {
        address implementation;
        address marketFactory;
        address feeEscrow;
        address launchDeployer;
        address positionManager;
        address launchForwarder;
        address protocolFeeRecipient;
        address permit2;
        address graduation;
        address locker;
        bool launchEnabled;
        uint256 launchCount;
        uint256 protocolFeeShareBps;
        uint16 graduatedCreatorShareBps;
    }

    function run() external returns (address locker, address graduation) {
        require(block.chainid == 4663, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");
        address lpFund = vm.envAddress("LAUNCH_LP_FUND_RECIPIENT");
        require(lpFund != address(0), "LAUNCH_LP_FUND_RECIPIENT is zero");

        LaunchFactory factory = LaunchFactory(LAUNCH_FACTORY);
        Before memory was = _read(factory);
        AssetMarketFactory marketFactory = AssetMarketFactory(was.marketFactory);

        require(factory.owner() == deployer, "signer does not own the launch factory");
        // The one call that cannot be made from the launchpad side. Checked before anything is
        // deployed, because a graduation module the market factory does not know is a module
        // every graduation reverts against.
        require(marketFactory.owner() == deployer, "signer does not own the market factory");
        // Not a refusal. See the contract note: these positions keep two-way terms and an
        // operator has to be told which they are.
        _reportPositionsStayingOnTheOldLocker(factory, was.launchCount, was.locker);
        // Refused, unlike a graduated launch: a launch mid-graduation has had its reserves
        // swept into the factory and its retry would be executed by whichever module is wired
        // when someone calls it. Swapping the module underneath that is a change of executor
        // in the middle of a two-phase operation, and there is no reason to accept the risk
        // when waiting for the retry costs nothing.
        _requireNothingMidGraduation(factory, was.launchCount);

        vm.startBroadcast(deployer);

        // 1. The implementation. No initializer: the three new fields share an existing slot
        //    and their defaults are zero.
        LaunchFactory freshImplementation = new LaunchFactory();
        factory.upgradeToAndCall(address(freshImplementation), "");

        // 2. The recipient BEFORE any rate. Every share setter refuses a nonzero rate while
        //    the recipient is unset, so this order is load-bearing rather than tidy.
        factory.setLpFundRecipient(lpFund);
        factory.setProtocolFeeShareBps(PROTOCOL_FEE_SHARE_BPS);
        factory.setLpFundShareBps(LP_FUND_SHARE_BPS);
        factory.setGraduatedCreatorShareBps(CREATOR_FEE_SHARE_BPS);
        factory.setGraduatedLpFundShareBps(LP_FUND_SHARE_BPS);

        // 3. The locker that knows a third recipient, and the module that holds it.
        //    `setGraduation` on the locker is one-shot and has to be the signer's call: the
        //    locker's owner is the only address that may make it.
        LaunchLocker freshLocker = new LaunchLocker(deployer, LAUNCH_FACTORY);
        LaunchGraduation freshGraduation = new LaunchGraduation(
            LAUNCH_FACTORY,
            marketFactory,
            IPositionManagerV4(was.positionManager),
            IPermit2(was.permit2),
            ILaunchLocker(address(freshLocker)),
            ILaunchFeeEscrow(was.feeEscrow)
        );
        freshLocker.setGraduation(address(freshGraduation));

        // 4. Both sides of the link.
        factory.setGraduation(ILaunchGraduation(address(freshGraduation)));
        marketFactory.setLaunchpad(address(freshGraduation));

        vm.stopBroadcast();

        _verify(factory, marketFactory, freshLocker, freshGraduation, was, lpFund);
        _report(
            was,
            address(freshImplementation),
            address(freshLocker),
            address(freshGraduation),
            lpFund
        );

        return (address(freshLocker), address(freshGraduation));
    }

    function _read(LaunchFactory factory) internal view returns (Before memory was) {
        was.implementation = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        was.marketFactory = address(factory.marketFactory());
        was.feeEscrow = address(factory.feeEscrow());
        was.launchDeployer = address(factory.launchDeployer());
        was.positionManager = address(factory.positionManager());
        was.launchForwarder = factory.launchForwarder();
        was.protocolFeeRecipient = factory.protocolFeeRecipient();
        was.graduation = address(factory.graduation());
        // Read off the module rather than hardcoded, so the new one is built from whatever the
        // live one actually uses.
        was.permit2 = address(LaunchGraduation(was.graduation).permit2());
        was.locker = address(LaunchGraduation(was.graduation).locker());
        was.launchEnabled = factory.launchEnabled();
        was.launchCount = factory.launchCount();
        was.protocolFeeShareBps = factory.protocolFeeShareBps();
        was.graduatedCreatorShareBps = factory.graduatedCreatorShareBps();
    }

    /// @dev Enumerated and printed rather than refused. A graduated position is staked under
    ///      the old locker, no function moves it between lockers, and the old locker has no
    ///      third recipient — so these keep paying their snapshotted LP-fee share to the
    ///      creator with the protocol taking the rest. Nothing is stranded and nothing breaks;
    ///      the terms simply stay two-way, and whoever reports this change needs the list.
    function _reportPositionsStayingOnTheOldLocker(
        LaunchFactory factory,
        uint256 count,
        address oldLocker
    ) internal view {
        console.log("Positions that stay on the old locker", oldLocker);
        uint256 found;
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            LaunchFactory.LaunchedToken memory rec = factory.getLaunchedToken(token);
            if (rec.phase == GraduationPhase.Graduated) {
                ++found;
                console.log("  token", token);
                console.log("    market", rec.marketId);
                console.log("    LP-fee share frozen at (bps)", rec.creatorShareBps);
            }
        }
        if (found == 0) console.log("  none");
        console.log("  total:", found);
        console.log("  These keep two-way terms: creator LP fees plus protocol, no fund leg.");
        console.log("");
    }

    /// @dev A launch in `Swept` has had its reserves taken into the factory and is waiting for
    ///      a permissionless `graduateToMarket` retry. Changing the executor between the two
    ///      phases buys nothing, so it is refused; the retry is permissionless, so clearing
    ///      this costs a single call from anyone.
    function _requireNothingMidGraduation(LaunchFactory factory, uint256 count) internal view {
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            if (factory.getLaunchedToken(token).phase == GraduationPhase.Swept) {
                console.log("Mid-graduation, seed it before upgrading:", token);
                revert("a launch is swept but not seeded; call graduateToMarket first");
            }
        }
    }

    function _verify(
        LaunchFactory factory,
        AssetMarketFactory marketFactory,
        LaunchLocker locker,
        LaunchGraduation graduation,
        Before memory was,
        address lpFund
    ) internal view {
        address implementation = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        require(implementation != was.implementation, "the proxy did not move");

        // Read back through the proxy, not from this script's memory: the point is that the
        // storage behind it still answers, which is what a layout mistake would break. The
        // three new fields pack into an occupied slot, so the neighbours are the real test.
        require(address(factory.marketFactory()) == was.marketFactory, "market factory moved");
        require(address(factory.feeEscrow()) == was.feeEscrow, "fee escrow moved");
        require(address(factory.launchDeployer()) == was.launchDeployer, "launch deployer moved");
        require(address(factory.positionManager()) == was.positionManager, "posm moved");
        require(factory.launchForwarder() == was.launchForwarder, "forwarder moved");
        require(factory.protocolFeeRecipient() == was.protocolFeeRecipient, "recipient moved");
        require(factory.launchEnabled() == was.launchEnabled, "launchEnabled moved");
        require(factory.launchCount() == was.launchCount, "launch count moved");

        require(factory.lpFundRecipient() == lpFund, "LP fund recipient not applied");
        require(factory.lpFundShareBps() == LP_FUND_SHARE_BPS, "curve fund share not applied");
        require(
            factory.protocolFeeShareBps() == PROTOCOL_FEE_SHARE_BPS, "protocol share not applied"
        );
        require(
            factory.graduatedCreatorShareBps() == CREATOR_FEE_SHARE_BPS, "fee share not applied"
        );
        require(
            factory.graduatedLpFundShareBps() == LP_FUND_SHARE_BPS,
            "graduated fund share not applied"
        );
        // The invariant the curve defends at initialize, asserted here so a bad pair is caught
        // by this script rather than by the first launch after it.
        require(
            factory.protocolFeeShareBps() + factory.lpFundShareBps() <= 10_000,
            "curve fee split exceeds the whole fee"
        );
        require(
            uint256(factory.graduatedCreatorShareBps()) + factory.graduatedLpFundShareBps()
                <= 10_000,
            "graduated split exceeds a whole leg"
        );

        require(address(factory.graduation()) == address(graduation), "factory not repointed");
        require(marketFactory.launchpad() == address(graduation), "market factory not repointed");
        require(locker.graduation() == address(graduation), "locker not wired");
        require(locker.factory() == LAUNCH_FACTORY, "locker names another factory");
        require(address(graduation.locker()) == address(locker), "module names another locker");
        require(address(graduation.factory()) == LAUNCH_FACTORY, "module names another factory");
    }

    function _report(
        Before memory was,
        address implementation,
        address locker,
        address graduation,
        address lpFund
    ) internal view {
        console.log("LaunchFactory proxy:   ", LAUNCH_FACTORY);
        console.log("  implementation before:", was.implementation);
        console.log("  implementation after: ", implementation);
        console.log("");
        console.log("Curve fee, per 10,000:");
        console.log("  protocol:", PROTOCOL_FEE_SHARE_BPS);
        console.log("  LP fund: ", LP_FUND_SHARE_BPS);
        console.log("  creator (remainder):", 10_000 - PROTOCOL_FEE_SHARE_BPS - LP_FUND_SHARE_BPS);
        console.log("Graduated LP fees, per 10,000:");
        console.log("  creator (was", was.graduatedCreatorShareBps, "):", CREATOR_FEE_SHARE_BPS);
        console.log("  LP fund: ", LP_FUND_SHARE_BPS);
        console.log("LP fund recipient:", lpFund);
        console.log("");
        console.log("LaunchLocker before:    ", was.locker);
        console.log("LaunchLocker after:     ", locker);
        console.log("LaunchGraduation before:", was.graduation);
        console.log("LaunchGraduation after: ", graduation);
        console.log("");
        console.log("The frontend must be redeployed pointing at the new locker:");
        console.log("  deployments/asset-markets-mainnet-v6.json -> launchpad.locker");
        console.log("  deployments/app-networks.json -> chain 4663 -> launchpad.locker");
        console.log("  NEXT_PUBLIC_LAUNCH_LOCKER");
        console.log("");
        console.log("Any client that precomputes expectedEconomics must be redeployed too:");
        console.log("  lpFundShareBps joined the digest preimage.");
        console.log("");
        console.log("Launches already on a curve keep the split they were sold. Snapshotted:");
        console.log("  launchCount:", was.launchCount);
    }
}
