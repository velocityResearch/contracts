// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {LaunchDeployer} from "../src/launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";

/// @title RotateLaunchDeployerMainnet
/// @notice Points `LaunchFactory` at a `LaunchDeployer` built from current source, so newly
///         created curves are the current `LaunchCurve` rather than whatever one the old
///         deployer has baked into it.
///
/// @dev    **This is the step `UpgradeLaunchpadLpFundMainnet` should have included, and the
///         reason it is easy to miss is worth writing down.** `LaunchDeployer` CREATE2-deploys
///         `LaunchCurve` and `LaunchToken`, which means both of their CREATION BYTECODES are
///         embedded in the deployer's own bytecode. Changing `LaunchCurve` therefore changes
///         `LaunchDeployer`, even though `LaunchDeployer.sol` itself is untouched, and the
///         deployer is not upgradeable.
///
///         So after the LP fund upgrade the factory read `lpFundShareBps = 3000` and happily
///         reported a three-way policy, while the deployer it was still pointed at produced
///         curves compiled before the fund existed. A launch created in that window would have
///         split its curve fee two ways and paid the LP fund nothing, with nothing reverting
///         and nothing looking wrong.
///
///         It was caught by source verification, not by a test: Sourcify matched every other
///         contract and returned NO MATCH for the live deployer, because its on-chain bytecode
///         no longer corresponds to any compilation of current source. That is a useful thing
///         to know about verification — it is a bytecode-drift detector, not just paperwork.
///
///         Confirmed directly before writing this: the live deployer at
///         `0xe079DEbb1dbcBD197B73f985549711D7eFA7a287` is 35,584 hex chars and does NOT
///         contain the `lpFundShareBps()` selector `0x11407835`; a freshly compiled one is
///         36,296 and does.
///
///         **Nothing already launched is affected.** A curve and its token are immutable once
///         deployed, and `setLaunchDeployer` governs only launches created after it. The
///         factory's own docstring says so, and `setLaunchDeployer` is deliberately rotatable
///         rather than one-shot for exactly this case.
///
///         **The staleness check is on the embedded selector, not on a version number.** A
///         deployer either carries a curve that knows the fund leg or it does not, and that is
///         readable straight off its bytecode. Comparing whole bytecode against a fresh
///         compile would also work but would rotate on any unrelated recompilation, including
///         a comment change in `LaunchCurve`.
///
///         Usage:
///           DEPLOYER=0x… forge script script/RotateLaunchDeployerMainnet.s.sol:RotateLaunchDeployerMainnet --rpc-url robinhood
///           DEPLOYER=0x… forge script script/RotateLaunchDeployerMainnet.s.sol:RotateLaunchDeployerMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract RotateLaunchDeployerMainnet is Script {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;

    /// @dev `LaunchCurve.lpFundShareBps()`. Present in a curve that knows the LP fund leg, and
    ///      therefore present in the creation code a current `LaunchDeployer` embeds.
    bytes4 constant LP_FUND_SHARE_SELECTOR = 0x11407835;

    function run() external returns (address deployerAddress) {
        require(block.chainid == 4663, "mainnet only");
        address signer = vm.envAddress("DEPLOYER");

        LaunchFactory factory = LaunchFactory(LAUNCH_FACTORY);
        require(factory.owner() == signer, "signer does not own the launch factory");

        address live = address(factory.launchDeployer());
        console.log("LaunchFactory:       ", LAUNCH_FACTORY);
        console.log("live LaunchDeployer: ", live);

        bool stale = !_embedsFundAwareCurve(live);
        console.log("live deployer embeds a fund-aware curve:", !stale);
        if (!stale) {
            console.log("Already current. Nothing broadcast.");
            return live;
        }

        vm.startBroadcast(signer);
        LaunchDeployer fresh = new LaunchDeployer(LAUNCH_FACTORY);
        factory.setLaunchDeployer(fresh);
        vm.stopBroadcast();

        // Post-checks. Both directions of the link, and the property that motivated the change.
        require(address(factory.launchDeployer()) == address(fresh), "factory not repointed");
        require(fresh.factory() == LAUNCH_FACTORY, "deployer names another factory");
        require(
            _embedsFundAwareCurve(address(fresh)),
            "the fresh deployer still does not embed a fund-aware curve"
        );
        // The policy the new curves will snapshot has to be the three-way one, or rotating the
        // deployer has fixed the plumbing and left the economics wrong.
        require(factory.lpFundRecipient() != address(0), "no LP fund recipient set");
        require(
            factory.protocolFeeShareBps() + factory.lpFundShareBps() <= 10_000,
            "curve fee split exceeds the whole fee"
        );

        console.log("new LaunchDeployer:  ", address(fresh));
        console.log("");
        console.log("Launches created from now on snapshot the three-way curve fee:");
        console.log("  protocol (bps):", factory.protocolFeeShareBps());
        console.log("  LP fund (bps): ", factory.lpFundShareBps());
        console.log("  creator takes the remainder.");
        console.log("Curves already deployed are immutable and keep the split they launched on.");

        return address(fresh);
    }

    /// @dev Scans a deployer's runtime bytecode for the curve selector. The curve's creation
    ///      code sits inside it verbatim, so a plain substring search over the 4 bytes is
    ///      sufficient and needs no ABI.
    function _embedsFundAwareCurve(address deployer) private view returns (bool) {
        bytes memory code = deployer.code;
        if (code.length < 4) return false;
        bytes4 needle = LP_FUND_SHARE_SELECTOR;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == needle[0] && code[i + 1] == needle[1] && code[i + 2] == needle[2]
                    && code[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }
}
