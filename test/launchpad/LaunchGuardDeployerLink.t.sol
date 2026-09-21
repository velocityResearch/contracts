// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {LaunchGraduationGuard} from "../../src/launchpad/LaunchGraduationGuard.sol";
import {LaunchGuardDeployer} from "../../src/launchpad/libraries/LaunchGuardDeployer.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchGuardDeployerLinkTest
/// @notice Pins the one property that moving `new LaunchGraduationGuard()` out of
///         `LaunchFactory.initialize` and into an external library could have broken.
///
///         The extraction is an EIP-170 measure: the guard's 2,970 bytes of creation code were
///         what put the factory over the 24,576-byte limit, and a library holds them now. What
///         makes that safe is that an external library call is a `DELEGATECALL`, so the
///         `CREATE` still runs from the factory proxy's own account — the guard lands at the
///         same address it always did, from the same nonce. That is an EVM guarantee rather
///         than a choice, which is precisely why it is worth a test rather than a runtime
///         `require`: a `require` would have to hardcode the proxy's nonce, and a hardcoded
///         nonce is a revert condition that the deployment shape, not the invariant, decides.
///
///         A guard deployed from the library's own account would still *work* — it is
///         stateless and `pure` — so nothing else in the suite would notice. It would simply
///         sit at an address nobody predicted, and every future factory would share one
///         instance rather than owning theirs. These assertions are what make that visible.
contract LaunchGuardDeployerLinkTest is LaunchpadFixture {
    function setUp() public {
        _deployLaunchpadStack();
    }

    /// @notice The library is linked, and the factory really delegatecalled into it: the guard
    ///         exists, holds code, and sits at the address `CREATE` gives the factory proxy on
    ///         its first nonce — which is where the inline `new` put it before the extraction.
    function test_guardDeploysFromTheFactoryProxysOwnNonce() public view {
        assertGt(
            address(LaunchGuardDeployer).code.length, 0, "LaunchGuardDeployer library is not linked"
        );

        address guard = address(launchFactory.graduationGuard());
        assertGt(guard.code.length, 0, "guard has no code");
        // A contract account's nonce starts at 1, and `initialize` runs inside the proxy's
        // constructor before the proxy has created anything else.
        assertEq(guard, vm.computeCreateAddress(address(launchFactory), 1), "guard moved");
    }

    /// @notice And NOT from the library's account, which is the failure the delegatecall
    ///         semantics rule out. Checked across the library's first few nonces rather than
    ///         just one, because the interesting claim is "the library never created it", not
    ///         "it missed one particular slot".
    function test_guardIsNotDeployedFromTheLibrarysOwnNonce() public view {
        address guard = address(launchFactory.graduationGuard());
        for (uint64 nonce = 0; nonce < 4; ++nonce) {
            assertTrue(
                guard != vm.computeCreateAddress(address(LaunchGuardDeployer), nonce),
                "guard was created by the library, not by the factory"
            );
        }
        // The library is a pure code blob: it deploys nothing of its own and keeps no nonce.
        assertEq(address(LaunchGuardDeployer).balance, 0);
    }

    /// @notice The factory calls the guard it recorded. Without this the two assertions above
    ///         would only prove that some contract exists at a predictable address.
    function test_factoryPreflightsLaunchTermsThroughTheDeployedGuard() public {
        address guard = address(launchFactory.graduationGuard());
        vm.expectCall(
            guard,
            abi.encodeWithSelector(LaunchGraduationGuard.assertSeedableEitherOrdering.selector)
        );
        _launch("Guarded", "GUARD");
    }

    /// @notice And it is the guard's own revert that a launch on unseedable terms surfaces, so
    ///         the call above is load-bearing rather than incidental. Mocked at the recorded
    ///         address: if the factory were holding a different guard, nothing would change
    ///         and the launch would succeed.
    function test_launchFailsWhenTheRecordedGuardRefusesTheSeed() public {
        address guard = address(launchFactory.graduationGuard());
        vm.mockCallRevert(
            guard,
            abi.encodeWithSelector(LaunchGraduationGuard.assertSeedableEitherOrdering.selector),
            abi.encodeWithSelector(LaunchGraduationGuard.GraduationSeedNotViable.selector)
        );

        _fundQuote(creator, LAUNCH_FEE);
        vm.startPrank(creator);
        IERC20(quoteBrand).approve(address(launchFactory), LAUNCH_FEE);
        vm.expectRevert(LaunchGraduationGuard.GraduationSeedNotViable.selector);
        launchFactory.launchToken(
            _tokenParams("Refused", "NOPE", keccak256("NOPE")),
            launchConfigId,
            quoteBrand,
            new address[](0)
        );
        vm.stopPrank();
    }
}
