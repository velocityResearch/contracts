// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {BrandFeeVault} from "./BrandFeeVault.sol";
import {LpRewardDistributor} from "./LpRewardDistributor.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";

/// @title MarketDeployer
/// @notice Holds the creation code for a market's `BrandFeeVault` and `LpRewardDistributor` so
///         that `AssetMarketFactory` does not have to.
///
///         **This exists for one reason: EIP-170.** A contract that writes `new X(...)` carries
///         X's entire creation code in its own bytecode, and the factory creates both of a
///         market's contracts — enough to push it past the 24,576-byte limit on its own. This
///         is the same shape of problem, and the same fix, that `SplitterDeployer` was written
///         for before the splitter was deleted; see the note in `foundry.toml`.
///
///         **It is an external library, not a deployer contract, and that distinction matters.**
///         A library call is a `DELEGATECALL`, so the `CREATE`s below execute in the factory's
///         own context: the addresses come from the factory's nonce, and `msg.sender` inside
///         `BrandFeeVault.setDistributor` is the factory, which is what makes its `onlyFactory`
///         guard mean what it says. A separate deployer *contract* would deploy from its own
///         nonce and would itself have to be the vault's `factory`, which is a different and
///         worse contract.
///
///         The cost is a link step: this must be deployed before the factory and its address
///         supplied at link time. `script/DeployAssetMarkets.s.sol` does that, and the address
///         is recorded in the deployment manifest.
library MarketDeployer {
    /// @dev Carried as a struct because the two initialisers between them take fourteen
    ///      arguments, and passing them positionally through a library boundary is how a
    ///      market ends up wired to the wrong pool with no compiler complaint.
    struct Params {
        SharedReservePool reservePool;
        address treasury;
        address brandToken;
        address asset;
        address protocolTreasury;
        uint16 protocolBps;
        /// @dev Uniswap's canonical v4 `PositionManager`. The distributor holds staked LP
        ///      positions, so it needs the contract that minted them.
        IPositionManagerV4 positionManager;
        /// @dev How long one LP reward period runs for.
        uint32 rewardsDuration;
        /// @dev Beacons backing the two per-market contracts. Upgrading one lifts that contract
        ///      for every market at once, which is the point of using beacons here rather than
        ///      a proxy per instance.
        address vaultBeacon;
        address distributorBeacon;
        /// @dev The factory itself. The vault records it as the only address that may bind a
        ///      distributor, and behind a proxy `msg.sender` at initialisation is the proxy's
        ///      own constructor, so it has to be passed rather than observed.
        address factory;
        /// @dev The protocol pause registry both contracts obey.
        address guard;
    }

    /// @notice Deploy a market's vault and its LP reward distributor, and bind them together.
    ///
    ///         The order is load-bearing. The vault exists first because the distributor records
    ///         its address at initialisation, and the vault's own distributor reference is
    ///         written once afterwards — neither can be the other's initialiser argument, so one
    ///         of the two links has to be a write.
    ///
    ///         Both are `BeaconProxy` instances. Their initialisers run inside each proxy's own
    ///         constructor, so no half-built market contract is ever reachable.
    function deploy(Params memory p, PoolKey memory key)
        external
        returns (BrandFeeVault vault, LpRewardDistributor distributor)
    {
        vault = BrandFeeVault(
            address(
                new BeaconProxy(
                    p.vaultBeacon,
                    abi.encodeCall(
                        BrandFeeVault.initialize,
                        (
                            p.reservePool,
                            p.treasury,
                            p.brandToken,
                            p.asset,
                            p.protocolTreasury,
                            p.protocolBps,
                            p.factory,
                            p.guard
                        )
                    )
                )
            )
        );

        distributor = LpRewardDistributor(
            address(
                new BeaconProxy(
                    p.distributorBeacon,
                    abi.encodeCall(
                        LpRewardDistributor.initialize,
                        (
                            p.positionManager,
                            p.reservePool,
                            key,
                            p.brandToken,
                            address(vault),
                            p.rewardsDuration,
                            p.guard
                        )
                    )
                )
            )
        );

        vault.setDistributor(distributor);
    }
}
