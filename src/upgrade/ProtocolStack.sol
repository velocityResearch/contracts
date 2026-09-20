// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SharedReservePool} from "../pool/SharedReservePool.sol";
import {PooledBrandToken} from "../pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../pool/PoolBrandTreasury.sol";
import {AssetMarketFactory} from "../markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../markets/LpRewardDistributor.sol";
import {MarketRouter} from "../markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../markets/ProtocolFeeHook.sol";
import {LaunchDeployer} from "../launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../launchpad/LaunchFactory.sol";
import {LaunchFeeEscrow} from "../launchpad/LaunchFeeEscrow.sol";
import {LaunchGraduation} from "../launchpad/LaunchGraduation.sol";
import {LaunchGraduationGuard} from "../launchpad/LaunchGraduationGuard.sol";
import {LaunchLocker} from "../launchpad/LaunchLocker.sol";
import {LaunchRouter} from "../launchpad/LaunchRouter.sol";
import {
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../launchpad/interfaces/ILaunchpad.sol";
import {MorphoBlueYieldSource} from "../yield/MorphoBlueYieldSource.sol";
import {IPermit2, IPositionManagerV4} from "../interfaces/IPositionManagerV4.sol";
import {LiquidityZapper} from "../markets/LiquidityZapper.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {ProtocolGuard} from "./ProtocolGuard.sol";

/// @title ProtocolStack
/// @notice Stands up the whole upgradeable deployment, in the one order that works.
///
///         **Why this is a library and not a runbook.** The stack is ten proxies with a
///         dependency order that is not obvious and not forgiving: the reserve needs its two
///         beacons before it can register a brand, the factory needs the hook and three more
///         beacons, the router needs the factory, and the hook needs to be told about the
///         factory afterwards because neither can be the other's argument. Written out by hand
///         in each script and each test suite, that ordering gets copied slightly wrong exactly
///         once and the mistake surfaces as a market whose vault points at nothing.
///
///         Every function here is `internal`, so it inlines into the caller and needs no link
///         step. That is deliberate: `MarketDeployer` already has to be linked, and one linked
///         library per deployment is enough.
///
///         **The beacon/UUPS split.** Contracts there is exactly one of — the reserve, the
///         factory, the router, the hook, the yield adapter — are UUPS proxies, upgraded one at
///         a time. Contracts there are many of, one set per market, sit behind beacons: a single
///         `upgradeTo` on a beacon moves every market at once, which is the only version of
///         "fix the vault" that finishes in a bounded number of transactions.
library ProtocolStack {
    struct Beacons {
        UpgradeableBeacon brandToken;
        UpgradeableBeacon treasury;
        UpgradeableBeacon vault;
        UpgradeableBeacon distributor;
    }

    struct Core {
        ProtocolGuard guard;
        Beacons beacons;
        MorphoBlueYieldSource yieldSource;
        SharedReservePool reservePool;
        ProtocolFeeHook feeHook;
        AssetMarketFactory factory;
        MarketRouter router;
    }

    /// @notice Every address the launchpad deployment produces, in the order it produces them.
    /// @dev    `graduationGuard` is deployed by `LaunchFactory.initialize` rather than passed
    ///         in, and is read back here because a manifest that omits it cannot tell whether
    ///         a later factory upgrade moved the seed preflight.
    struct Launchpad {
        LaunchFeeEscrow feeEscrow;
        address factoryImplementation;
        LaunchFactory factory;
        LaunchGraduationGuard graduationGuard;
        LaunchLocker locker;
        LaunchDeployer launchDeployer;
        LaunchGraduation graduation;
        LaunchRouter router;
    }

    /// @notice The pause registry. Deployed first, because everything else is initialised with
    ///         its address.
    function deployGuard(address owner, address guardian) internal returns (ProtocolGuard) {
        address impl = address(new ProtocolGuard());
        return ProtocolGuard(
            address(
                new ERC1967Proxy(impl, abi.encodeCall(ProtocolGuard.initialize, (owner, guardian)))
            )
        );
    }

    /// @notice The four beacons backing the per-brand and per-market contracts.
    /// @dev    Each beacon is `Ownable` and is handed straight to `owner` — the timelock — so
    ///         there is no window in which the deploying key can upgrade a live market.
    function deployBeacons(address owner) internal returns (Beacons memory b) {
        b.brandToken = new UpgradeableBeacon(address(new PooledBrandToken()), owner);
        b.treasury = new UpgradeableBeacon(address(new PoolBrandTreasury()), owner);
        b.vault = new UpgradeableBeacon(address(new BrandFeeVault()), owner);
        b.distributor = new UpgradeableBeacon(address(new LpRewardDistributor()), owner);
    }

    function deployYieldSource(address morphoBlue, bytes32 marketId, address owner)
        internal
        returns (MorphoBlueYieldSource)
    {
        address impl = address(new MorphoBlueYieldSource());
        return MorphoBlueYieldSource(
            address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(MorphoBlueYieldSource.initialize, (morphoBlue, marketId, owner))
                )
            )
        );
    }

    function deployReservePool(
        address asset,
        address yieldSource,
        address owner,
        Beacons memory b,
        address guard
    ) internal returns (SharedReservePool) {
        address impl = address(new SharedReservePool());
        return SharedReservePool(
            address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        SharedReservePool.initialize,
                        (
                            asset,
                            yieldSource,
                            owner,
                            address(b.brandToken),
                            address(b.treasury),
                            guard
                        )
                    )
                )
            )
        );
    }

    /// @notice The calldata a `ProtocolFeeHook` proxy must be constructed with.
    /// @dev    Split out because the hook's proxy address has to be MINED before it can be
    ///         deployed — a v4 hook's permissions are the low bits of its own address, and it is
    ///         the proxy the `PoolManager` calls. The caller mines a salt over
    ///         `hookProxyInitCode`, deploys with it, and passes the result back to
    ///         `deployFactory`. An upgrade later replaces the implementation without moving that
    ///         address, which is what keeps every existing pool valid.
    function hookProxyInitCode(
        address implementation,
        IPoolManager poolManager,
        address owner,
        address guard
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(
                implementation,
                abi.encodeCall(ProtocolFeeHook.initialize, (poolManager, owner, guard))
            )
        );
    }

    function deployHookImplementation() internal returns (address) {
        return address(new ProtocolFeeHook());
    }

    /// @param positionManager Uniswap's canonical v4 `PositionManager`. Held by the factory so
    ///                        every market's LP reward distributor is initialised with it.
    /// @param minObservationCardinality The oracle buffer floor stamped into new markets.
    function deployFactory(
        SharedReservePool reservePool,
        IPoolManager poolManager,
        ProtocolFeeHook feeHook,
        IPositionManagerV4 positionManager,
        address protocolTreasury,
        address referenceEquity,
        uint16 protocolBps,
        uint32 rewardsDuration,
        uint16 minObservationCardinality,
        address owner,
        Beacons memory b,
        address guard
    ) internal returns (AssetMarketFactory) {
        address impl = address(new AssetMarketFactory());
        return AssetMarketFactory(
            address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        AssetMarketFactory.initialize,
                        (
                            reservePool,
                            poolManager,
                            feeHook,
                            positionManager,
                            protocolTreasury,
                            referenceEquity,
                            protocolBps,
                            rewardsDuration,
                            minObservationCardinality,
                            owner,
                            AssetMarketFactory.MarketBeacons({
                                vault: address(b.vault), distributor: address(b.distributor)
                            }),
                            guard
                        )
                    )
                )
            )
        );
    }

    function deployRouter(
        SharedReservePool reservePool,
        AssetMarketFactory factory,
        IPositionManagerV4 positionManager,
        IPermit2 permit2,
        address owner,
        address guard
    ) internal returns (MarketRouter) {
        address impl = address(new MarketRouter());
        return MarketRouter(
            address(
                new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        MarketRouter.initialize,
                        (reservePool, factory, positionManager, permit2, owner, guard)
                    )
                )
            )
        );
    }

    /// @notice The zapper, which is a proxy of its own rather than part of the router's.
    ///
    /// @dev    Deployed here for the same reason the router is: the wiring it has to be given
    ///         is the wiring the router was given, and two places to write it down is one place
    ///         for them to disagree. Nothing else in the stack depends on it, so it may be
    ///         deployed at any point after the factory exists — including long afterwards,
    ///         which is what a replacement deployment is.
    ///
    /// @param swapRouter Uniswap v3 `SwapRouter02`, for the ETH door. Zero is a complete
    ///                   deployment that takes USDG only; see `LiquidityZapper.initialize`.
    function deployZapper(
        SharedReservePool reservePool,
        AssetMarketFactory factory,
        IPositionManagerV4 positionManager,
        IPermit2 permit2,
        ISwapRouter02 swapRouter,
        address owner,
        address guard
    ) internal returns (LiquidityZapper) {
        address impl = address(new LiquidityZapper());
        // `payable` because the zapper has a `receive()` — the WETH unwrap of an ETH refund
        // lands on it, and Solidity will not narrow a plain address to a type that can be paid.
        return LiquidityZapper(
            payable(new ERC1967Proxy(
                    impl,
                    abi.encodeCall(
                        LiquidityZapper.initialize,
                        (reservePool, factory, positionManager, permit2, swapRouter, owner, guard)
                    )
                ))
        );
    }

    /// @notice The launchpad, on top of an already-deployed market stack.
    ///
    ///         **The order is forced by a circle.** The locker, the launch deployer, the
    ///         graduation module and the router each take the launch factory's address as a
    ///         constructor argument, and the factory takes none of theirs — so the factory
    ///         proxy has to exist first and be told about the rest afterwards, through
    ///         one-shot setters. Anything deployed before the proxy can only be something the
    ///         factory itself is initialised with, which is the fee escrow and nothing else.
    ///
    ///         **What this does NOT do, and why.** Two of the launchpad's links cross into the
    ///         market stack: `AssetMarketFactory.setLaunchpad(graduation)`, which is what lets
    ///         a graduation list an asset without an owner approval, and the launch parameters
    ///         (`addLaunchConfig`, `setPairTokenEconomics`, the fee recipient). Both are owner
    ///         calls on contracts this function did not deploy, and both are economic rather
    ///         than structural — the brand a launch is quoted in and the threshold it
    ///         graduates at belong to the launch they precede. The caller makes them; see
    ///         `script/DeployLaunchpad.s.sol`.
    ///
    ///         Launching stays disabled until the caller enables it: a launchpad with no
    ///         config and no approved brand would revert on every launch anyway, and the flag
    ///         is what makes that state explicit rather than accidental.
    /// @param  owner MUST be the address whose transaction runs this function. The four
    ///         one-shots below are `onlyOwner` on the contracts deployed here, and they are
    ///         performed here — a different `owner` would leave the launchpad unwireable, since
    ///         `setGraduation` and `setLaunchDeployer` cannot be retried against a new value.
    /// @param  marketFactory The live `AssetMarketFactory`. Its `positionManager` is checked
    ///         against `positionManager` by `LaunchFactory.initialize` and its `poolManager` by
    ///         `LaunchGraduation`'s constructor, so a mismatched periphery fails here rather
    ///         than on the first graduation.
    function deployLaunchpad(
        address owner,
        address guard,
        AssetMarketFactory marketFactory,
        IPositionManagerV4 positionManager,
        IPermit2 permit2
    ) internal returns (Launchpad memory lp) {
        lp.feeEscrow = new LaunchFeeEscrow();

        lp.factoryImplementation = address(new LaunchFactory());
        lp.factory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    lp.factoryImplementation,
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            guard,
                            marketFactory,
                            positionManager,
                            ILaunchFeeEscrow(address(lp.feeEscrow))
                        )
                    )
                )
            )
        );
        lp.graduationGuard = lp.factory.graduationGuard();

        lp.locker = new LaunchLocker(owner, address(lp.factory));
        lp.launchDeployer = new LaunchDeployer(address(lp.factory));
        lp.graduation = new LaunchGraduation(
            address(lp.factory),
            marketFactory,
            positionManager,
            permit2,
            ILaunchLocker(address(lp.locker)),
            ILaunchFeeEscrow(address(lp.feeEscrow))
        );
        lp.router = new LaunchRouter(lp.factory);

        // The one-shots, in the direction each contract cannot be constructed with. Every one
        // of these reverts on a second call, so a half-finished deployment is not recoverable
        // by re-running this function — it is recoverable only by deploying a new factory.
        lp.locker.setGraduation(address(lp.graduation));
        lp.factory.setLaunchDeployer(lp.launchDeployer);
        lp.factory.setGraduation(ILaunchGraduation(address(lp.graduation)));
        lp.factory.setLaunchForwarder(address(lp.router));
    }
}
