// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchGraduationGuard} from "../LaunchGraduationGuard.sol";

/// @title LaunchGuardDeployer
/// @notice Holds the creation code for `LaunchGraduationGuard` so that `LaunchFactory` does not
///         have to.
///
///         **This exists for one reason: EIP-170.** A contract that writes `new X(...)` carries
///         X's entire creation code in its own bytecode, and the guard's is 2,970 bytes — more
///         than the whole overrun that put `LaunchFactory` at 25,285 bytes against the
///         24,576-byte limit. Deleting nothing and moving that one constant out is what brings
///         the factory back under, with room to spare. Same shape of problem, and same fix, as
///         `MarketDeployer` for `AssetMarketFactory`; see the note in `foundry.toml`.
///
///         **It is an external library, not a deployer contract, and that distinction matters
///         even for a stateless guard.** A library call is a `DELEGATECALL`, so the `CREATE`
///         below executes in the factory's own context: the guard's address comes from the
///         factory proxy's nonce, exactly as it did when `initialize` wrote `new` inline, and
///         `msg.sender` and storage inside the call are still the proxy's. A separate deployer
///         *contract* would deploy from its own nonce, which would move the guard's address for
///         no gain.
///
///         **It costs nothing at runtime.** The one call site is `LaunchFactory.initialize`,
///         which runs once per proxy, so no user-facing path pays for the extra `DELEGATECALL`.
///         That is why this was extracted rather than the launch-time validation helpers, which
///         are larger in source but sit on the hot path.
///
///         The cost is a link step: this must be deployed before any `LaunchFactory`
///         implementation and its address supplied at link time. `script/DeployLaunchpad.s.sol`
///         and `script/UpgradeGraduateIntoLaunchDollarMainnet.s.sol` do that, and the address is
///         recorded in the deployment manifest. An unlinked build is not a silent failure: the
///         placeholder delegatecalls into empty code and `initialize` reverts.
library LaunchGuardDeployer {
    /// @notice Deploy the stateless seed preflight this factory hands every graduation to.
    /// @dev Returned rather than assigned, because a library has no storage of its own and the
    ///      factory's `graduationGuard` slot is the caller's to write.
    function deploy() external returns (LaunchGraduationGuard guard) {
        guard = new LaunchGraduationGuard();
    }
}
