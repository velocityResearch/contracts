// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {SUSDaiYieldSource} from "../../src/yield/SUSDaiYieldSource.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {ProtocolGuard} from "../../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../../src/upgrade/ProtocolStack.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/// @title StackFixture
/// @notice Deploys the upgradeable stack the way a test wants it: same proxies and same wiring
///         as `ProtocolStack` puts on chain, but with the hook placed at a chosen address
///         instead of a mined one.
///
///         **Why the hook is special.** A v4 hook's permissions are the low 14 bits of its
///         address, and behind a proxy it is the PROXY that the `PoolManager` calls — so the
///         proxy is what has to land on a flagged address. On chain that means mining a CREATE2
///         salt over the proxy's init code, which takes long enough to be unwelcome in a test
///         `setUp`. `deployCodeTo` writes the proxy where the test asks and still runs its
///         constructor, so the implementation's initialiser still executes and
///         `Hooks.validateHookPermissions` still checks the address it lands on. The check that
///         mining exists to satisfy is therefore not skipped, only the search for the salt.
abstract contract StackFixture is Test {
    ProtocolGuard internal protocolGuard;
    ProtocolStack.Beacons internal beacons;

    /// @dev The timelock in a real deployment. A plain address here; what matters to the tests
    ///      is that it is not the guardian and not an arbitrary caller.
    address internal stackOwner = address(0xB0A2D);
    address internal stackGuardian = address(0x60A2D);

    // Implementations, deployed once by `_deployUpgradeBase` and reused for every proxy after.
    //
    // Caching them is not an optimisation. Each `_deployX` below must perform exactly ONE
    // contract creation, because a test asserting that bad wiring is rejected writes
    // `vm.expectRevert` immediately before it — and `expectRevert` binds to the very next
    // creation. Deploying a fresh implementation inside the helper would put a call that
    // SUCCEEDS in that position, and the assertion would fail against a contract that was
    // never even reached. It also mirrors production, where implementations are deployed once
    // and proxies many times.
    address internal reservePoolImpl;
    address internal factoryImpl;
    address internal routerImpl;
    address internal yieldSourceImpl;
    address internal susdaiAdapterImpl;

    /// @notice Guard plus the five beacons. Call before anything else in a `setUp`.
    function _deployUpgradeBase() internal {
        protocolGuard = ProtocolStack.deployGuard(stackOwner, stackGuardian);
        beacons = ProtocolStack.deployBeacons(stackOwner);

        reservePoolImpl = address(new SharedReservePool());
        factoryImpl = address(new AssetMarketFactory());
        routerImpl = address(new MarketRouter());
        yieldSourceImpl = address(new MorphoBlueYieldSource());
        susdaiAdapterImpl = address(new SUSDaiYieldSource());
    }

    function _deployReservePool(address asset, address yieldSource, address owner)
        internal
        returns (SharedReservePool)
    {
        return SharedReservePool(
            address(
                new ERC1967Proxy(
                    reservePoolImpl,
                    abi.encodeCall(
                        SharedReservePool.initialize,
                        (
                            asset,
                            yieldSource,
                            owner,
                            address(beacons.brandToken),
                            address(beacons.treasury),
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    /// @notice A `ProtocolFeeHook` proxy at `flags`, which must carry the hook's permission bits.
    function _deployHookAt(address flags, IPoolManager poolManager, address owner)
        internal
        returns (ProtocolFeeHook)
    {
        require(flags.code.length == 0, "hook address is occupied");

        address impl = ProtocolStack.deployHookImplementation();
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                impl,
                abi.encodeCall(
                    ProtocolFeeHook.initialize, (poolManager, owner, address(protocolGuard))
                )
            ),
            flags
        );
        return ProtocolFeeHook(flags);
    }

    /// @notice Default market parameters for a suite that does not care about them: a weekly
    ///         reward period and the oracle depth the product ships with.
    uint32 internal constant FIXTURE_REWARDS_DURATION = 7 days;
    uint16 internal constant FIXTURE_MIN_OBSERVATION_CARDINALITY = 62;

    function _deployFactory(
        SharedReservePool reservePool,
        IPoolManager poolManager,
        ProtocolFeeHook feeHook,
        IPositionManagerV4 positionManager,
        address protocolTreasury,
        address referenceEquity,
        uint16 protocolBps,
        address owner
    ) internal returns (AssetMarketFactory) {
        return _deployFactory(
            reservePool,
            poolManager,
            feeHook,
            positionManager,
            protocolTreasury,
            referenceEquity,
            protocolBps,
            FIXTURE_REWARDS_DURATION,
            FIXTURE_MIN_OBSERVATION_CARDINALITY,
            owner
        );
    }

    function _deployFactory(
        SharedReservePool reservePool,
        IPoolManager poolManager,
        ProtocolFeeHook feeHook,
        IPositionManagerV4 positionManager,
        address protocolTreasury,
        address referenceEquity,
        uint16 protocolBps,
        uint32 rewardsDuration,
        uint16 minObservationCardinality,
        address owner
    ) internal returns (AssetMarketFactory) {
        return AssetMarketFactory(
            address(
                new ERC1967Proxy(
                    factoryImpl,
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
                                vault: address(beacons.vault),
                                distributor: address(beacons.distributor)
                            }),
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    /// @notice Approve an asset for trading with the parameters a suite's market wants, the
    ///         way the owner does on chain. Creation itself is permissionless.
    function _approveAsset(
        AssetMarketFactory factory,
        address asset,
        uint24 fee,
        uint256 assetPriceE18,
        uint16 observationCardinality,
        string memory unitName,
        string memory unitSymbol
    ) internal {
        vm.prank(factory.owner());
        factory.approveAsset(
            asset,
            AssetMarketFactory.AssetListing({
                approved: true,
                fee: fee,
                assetPriceE18: assetPriceE18,
                observationCardinality: observationCardinality,
                unitName: unitName,
                unitSymbol: unitSymbol
            })
        );
    }

    /// @notice Name the launchpad module the factory lets through `createLaunchMarket`, the
    ///         way the owner does on chain after `ProtocolStack.deployLaunchpad`.
    function _setLaunchpad(AssetMarketFactory factory, address launchpad) internal {
        vm.prank(factory.owner());
        factory.setLaunchpad(launchpad);
    }

    /// @notice The listing a launchpad passes to `createLaunchMarket` for an 18-decimal asset:
    ///         the product's 0.50% tier and the oracle depth it ships with. `assetPriceE18` is
    ///         the price of ONE WHOLE asset in WHOLE quote units, scaled by 1e18. `approved`
    ///         is ignored by the factory, and so are the unit strings — a graduate is quoted
    ///         in the launch's own brand and mints no unit for them to name. They are filled
    ///         in anyway so a caller can tell a validated field from an inert one.
    function _launchListing(address asset, uint256 assetPriceE18)
        internal
        view
        returns (AssetMarketFactory.AssetListing memory)
    {
        string memory symbol = IERC20Metadata(asset).symbol();
        return AssetMarketFactory.AssetListing({
            approved: false,
            fee: 5_000,
            assetPriceE18: assetPriceE18,
            observationCardinality: FIXTURE_MIN_OBSERVATION_CARDINALITY,
            unitName: string.concat(symbol, " Market Dollar"),
            unitSymbol: string.concat(symbol, ".d")
        });
    }

    function _deployRouter(
        SharedReservePool reservePool,
        AssetMarketFactory factory,
        IPositionManagerV4 positionManager,
        IPermit2 permit2,
        address owner
    ) internal returns (MarketRouter) {
        return MarketRouter(
            address(
                new ERC1967Proxy(
                    routerImpl,
                    abi.encodeCall(
                        MarketRouter.initialize,
                        (
                            reservePool,
                            factory,
                            positionManager,
                            permit2,
                            owner,
                            address(protocolGuard)
                        )
                    )
                )
            )
        );
    }

    function _deployYieldSource(address morphoBlue, bytes32 marketId, address owner)
        internal
        returns (MorphoBlueYieldSource)
    {
        return MorphoBlueYieldSource(
            address(
                new ERC1967Proxy(
                    yieldSourceImpl,
                    abi.encodeCall(MorphoBlueYieldSource.initialize, (morphoBlue, marketId, owner))
                )
            )
        );
    }

    /// @notice A `SUSDaiYieldSource` proxy. Arguments are `initialize`'s, in its order, so a
    ///         caller reads the same wiring it used to pass to the constructor.
    /// @dev The caller of this helper becomes the adapter's `deployer` — the initializer runs
    ///      in the proxy's constructor, which preserves `msg.sender` — so the test contract can
    ///      still `bindController` afterwards.
    function _deploySUSDaiAdapter(
        address usdg,
        address spokePool,
        uint256 hubChainId,
        address hub,
        address hubUsdc,
        address guard,
        address owner,
        address keeper
    ) internal returns (SUSDaiYieldSource) {
        return SUSDaiYieldSource(
            address(
                new ERC1967Proxy(
                    susdaiAdapterImpl,
                    abi.encodeCall(
                        SUSDaiYieldSource.initialize,
                        (usdg, spokePool, hubChainId, hub, hubUsdc, guard, owner, keeper)
                    )
                )
            )
        );
    }

    /// @notice Halt the protocol as the guardian would.
    function _pauseProtocol() internal {
        vm.prank(stackGuardian);
        protocolGuard.pause();
    }

    function _unpauseProtocol() internal {
        vm.prank(stackOwner);
        protocolGuard.unpause();
    }
}
