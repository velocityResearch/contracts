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

/// @notice Split a graduated launch's income into two rates: the pool's own LP fees, which
///         become entirely the creator's, and the float yield, which stays the protocol's
///         under a knob that can be moved later.
///
/// @dev    **Four steps, and the last two are why this is a script rather than two `cast`
///         calls.** The knob lives on an upgradeable proxy and is read by a contract that is
///         not upgradeable, so the state change and the code change cannot be made in the same
///         place:
///
///         1. Upgrade the `LaunchFactory` proxy. `graduatedCreatorYieldShareBps` is a new
///            `uint16` packed into the slot `graduatedCreatorShareBps` and `launchEnabled`
///            already share, so nothing below it moves and the upgrade carries no initializer
///            call — `upgradeToAndCall` is given empty calldata deliberately, and the new
///            variable reads its shipped default of zero from storage that was never written.
///         2. `setGraduatedCreatorShareBps(10_000)`. The live proxy's storage still holds the
///            7_000 the old implementation's `initialize` wrote; a fresh deployment would ship
///            10_000, an upgraded one has to be told. **This moves future launches only** — the
///            rate is snapshotted into each launch record at launch time, so anything already
///            on a curve keeps the split it was sold.
///         3. Deploy a new `LaunchLocker` and a new `LaunchGraduation`. The locker is
///            deliberately not upgradeable — that is what makes "the liquidity is locked
///            forever" a property of the bytecode rather than a promise — so the two-rate
///            `collect` can only arrive as a new deployment, and the graduation module holds
///            its locker as an immutable, so it has to be redeployed with it.
///         4. Point both factories at the new module: `LaunchFactory.setGraduation` and
///            `AssetMarketFactory.setLaunchpad`. Without the second, phase two of every
///            graduation reverts `OnlyLaunchpad`.
///
///         **The window this runs in is not open forever.** Swapping the locker strands any
///         position already staked under the old one: the old locker's `collect` keeps working
///         and keeps paying on one rate, and no function moves a position between lockers. So
///         this refuses to run once any launch has reached `Graduated`, and that check is the
///         reason to send it before the live curve fills rather than after.
///
///         Rehearsed against real chain state in
///         `test/launchpad/LaunchpadFeeSplitUpgradeMainnetFork.t.sol`.
///
///         The proxy is owned by the deployer EOA with no timelock, which is CRITICAL-1 in the
///         audit and the reason every step here takes effect the moment it is mined.
contract UpgradeLaunchpadFeeSplitMainnet is Script {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The creator's share of a graduated position's LP fees, after this runs.
    uint16 constant CREATOR_FEE_SHARE_BPS = 10_000;
    /// @notice The creator's share of its float yield. Zero: the yield is what the reserve's
    ///         collateral earns, not what the launch earns. Read live, so it is the one figure
    ///         here that can be moved again later without stranding a launch.
    uint16 constant CREATOR_YIELD_SHARE_BPS = 0;

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
    }

    function run() external returns (address locker, address graduation) {
        require(block.chainid == 4663, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");

        LaunchFactory factory = LaunchFactory(LAUNCH_FACTORY);
        Before memory was = _read(factory);
        AssetMarketFactory marketFactory = AssetMarketFactory(was.marketFactory);

        require(factory.owner() == deployer, "signer does not own the launch factory");
        // The one call that cannot be made from the launchpad side. Checked before anything is
        // deployed, because a graduation module the market factory does not know is a module
        // every graduation reverts against.
        require(marketFactory.owner() == deployer, "signer does not own the market factory");
        _requireNothingGraduated(factory, was.launchCount);

        vm.startBroadcast(deployer);

        // 1. The implementation. No initializer: the new variable shares an existing slot and
        //    its default is zero.
        LaunchFactory freshImplementation = new LaunchFactory();
        factory.upgradeToAndCall(address(freshImplementation), "");

        // 2. The rates. `initialize` already ran on this proxy, so both are owner calls.
        factory.setGraduatedCreatorShareBps(CREATOR_FEE_SHARE_BPS);
        factory.setGraduatedCreatorYieldShareBps(CREATOR_YIELD_SHARE_BPS);

        // 3. The locker that can tell the two legs apart, and the graduation module that holds
        //    it. `setGraduation` on the locker is one-shot and has to be the signer's call:
        //    the locker's owner is the only address that may make it.
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

        // 4. Both sides of the link. `setGraduation` is rotatable in this build; `setLaunchpad`
        //    always was.
        factory.setGraduation(ILaunchGraduation(address(freshGraduation)));
        marketFactory.setLaunchpad(address(freshGraduation));

        vm.stopBroadcast();

        _verify(factory, marketFactory, freshLocker, freshGraduation, was);
        _report(was, address(freshImplementation), address(freshLocker), address(freshGraduation));

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
    }

    /// @dev A graduated launch's position is staked under the old locker and no function moves
    ///      it, so replacing the locker would leave its income on the single-rate path forever.
    ///      Refused rather than warned: it is not recoverable after the fact.
    function _requireNothingGraduated(LaunchFactory factory, uint256 count) internal view {
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            GraduationPhase phase = factory.getLaunchedToken(token).phase;
            if (phase == GraduationPhase.Graduated) {
                console.log("Already graduated, position locked under the old locker:", token);
                revert(
                    "a launch has already graduated; replacing the locker would strand its position"
                );
            }
        }
    }

    function _verify(
        LaunchFactory factory,
        AssetMarketFactory marketFactory,
        LaunchLocker locker,
        LaunchGraduation graduation,
        Before memory was
    ) internal view {
        address implementation = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        require(implementation != was.implementation, "the proxy did not move");

        // Read back through the proxy, not from this script's memory: the point is that the
        // storage behind it still answers, which is what a layout mistake would break.
        require(address(factory.marketFactory()) == was.marketFactory, "market factory moved");
        require(address(factory.feeEscrow()) == was.feeEscrow, "fee escrow moved");
        require(address(factory.launchDeployer()) == was.launchDeployer, "launch deployer moved");
        require(address(factory.positionManager()) == was.positionManager, "posm moved");
        require(factory.launchForwarder() == was.launchForwarder, "forwarder moved");
        require(factory.protocolFeeRecipient() == was.protocolFeeRecipient, "recipient moved");
        require(factory.launchEnabled() == was.launchEnabled, "launchEnabled moved");
        require(factory.launchCount() == was.launchCount, "launch count moved");

        require(
            factory.graduatedCreatorShareBps() == CREATOR_FEE_SHARE_BPS, "fee share not applied"
        );
        require(
            factory.graduatedCreatorYieldShareBps() == CREATOR_YIELD_SHARE_BPS,
            "yield share not applied"
        );

        require(address(factory.graduation()) == address(graduation), "factory not repointed");
        require(marketFactory.launchpad() == address(graduation), "market factory not repointed");
        require(locker.graduation() == address(graduation), "locker not wired");
        require(locker.factory() == LAUNCH_FACTORY, "locker names another factory");
        require(address(graduation.locker()) == address(locker), "module names another locker");
        require(address(graduation.factory()) == LAUNCH_FACTORY, "module names another factory");
    }

    function _report(Before memory was, address implementation, address locker, address graduation)
        internal
        view
    {
        console.log("LaunchFactory proxy:   ", LAUNCH_FACTORY);
        console.log("  implementation before:", was.implementation);
        console.log("  implementation after: ", implementation);
        console.log("  creator share of LP fees (bps):", CREATOR_FEE_SHARE_BPS);
        console.log("  creator share of float yield (bps):", CREATOR_YIELD_SHARE_BPS);
        console.log("LaunchLocker before:   ", was.locker);
        console.log("LaunchLocker after:    ", locker);
        console.log("LaunchGraduation before:", was.graduation);
        console.log("LaunchGraduation after: ", graduation);
        console.log("");
        console.log("The frontend must be redeployed pointing at the new locker:");
        console.log("  deployments/app-networks.json -> chain 4663 -> launchpad.locker");
        console.log("  NEXT_PUBLIC_LAUNCH_LOCKER");
        console.log("");
        console.log("Launches already on a curve keep the share they were sold. Snapshotted:");
        console.log("  launchCount:", was.launchCount);
    }
}
