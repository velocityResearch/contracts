// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";

interface IPool {
    function asset() external view returns (address);
    function yieldSource() external view returns (address);
}

interface IFactory {
    function reservePool() external view returns (address);
    function approvedReservePool(address pool) external view returns (bool);
}

/// @title DeployStrategyGroupRegistry
/// @notice Deploy the strategy-group directory on Robinhood Chain mainnet and publish the groups
///         that already exist there.
///
///         **Why this is not part of the main deployment.** The registry publishes nothing the
///         chain does not already hold: each reserve pool remains authoritative for its own
///         accounting and brand membership, and `AssetMarketFactory` remains authoritative for
///         which reserves it will register brands into. This contract is a discovery directory
///         for applications and indexers. Without it the front end takes a documented fallback -
///         `market-core/src/strategy-groups.ts` reads a null registry as "the existing
///         single-group deployment" - and shows only the reserve named in its own configuration.
///         That is why the mainnet stack works today with no registry at all, and why deploying
///         one is additive rather than a repair.
///
///         **What it changes.** Nothing that is already deployed. No proxy is upgraded, no beacon
///         moves, no market is touched. Two `CREATE`s and one `setGroup` per group, all against a
///         contract that does not exist yet. The groups it publishes are read back out of the
///         live stack rather than pasted in, so a typo in the environment fails the registry's
///         own cross-validation instead of publishing a directory that points somewhere wrong.
///
///         **On both groups sharing one factory.** They do, and that is expected.
///         `_validateMarketStack` accepts a stack that serves a reserve either by defaulting to
///         it or by having approved it, which is exactly the multi-reserve shape gen-6 deploys:
///         one `AssetMarketFactory` whose default is the Morpho-backed USDG reserve and which
///         has `setApprovedReservePool(sUSDaiReserve, true)`. Passing the same factory and
///         router for both groups is correct, not a copy-paste error.
///
///         Usage:
///
///         PRIVATE_KEY=0x... SHARED_RESERVE_POOL=0x... ASSET_MARKET_FACTORY=0x... \
///           MARKET_ROUTER=0x... SUSDAI_RESERVE_POOL=0x... LIQUIDITY_ZAPPER=0x... \
///           forge script script/DeployStrategyGroupRegistry.s.sol --rpc-url robinhood --broadcast
///
///         Environment:
///         - PRIVATE_KEY          required. Also the registry's owner unless REGISTRY_OWNER is set.
///         - SHARED_RESERVE_POOL  required. The Morpho-backed USDG reserve.
///         - ASSET_MARKET_FACTORY required.
///         - MARKET_ROUTER        required.
///         - SUSDAI_RESERVE_POOL  optional. Omit to publish only the USDG group.
///         - LIQUIDITY_ZAPPER     optional. Omit until the zapper is deployed; `setGroup` may be
///                                re-called later to add it, since a group's identity is its
///                                reserve and only the reserve is immutable.
///         - REGISTRY_OWNER       optional. Defaults to the deployer.
///         - SUSDAI_ACTIVE        optional, default false. See the note at its use below.
contract DeployStrategyGroupRegistry is Script {
    bytes32 public constant MARKET_GROUP_ID = keccak256("market-usdg");
    bytes32 public constant SUSDAI_GROUP_ID = keccak256("susdai-usdg");

    function run() external returns (StrategyGroupRegistry registry) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("REGISTRY_OWNER", deployer);

        address reserve = vm.envAddress("SHARED_RESERVE_POOL");
        address factory = vm.envAddress("ASSET_MARKET_FACTORY");
        address router = vm.envAddress("MARKET_ROUTER");
        address susdaiReserve = vm.envOr("SUSDAI_RESERVE_POOL", address(0));
        address zapper = vm.envOr("LIQUIDITY_ZAPPER", address(0));

        // The sUSDai group is published inactive by default. Its reserve is deployed, funded to
        // zero, and served by a keeper that is not running: nothing is bridged and no remote
        // value is reported. Publishing it active would put a group in front of users that
        // cannot complete the round trip it advertises. Flip SUSDAI_ACTIVE=true once the keeper
        // is live, or call setGroup again later - reactivation deliberately re-validates the
        // whole stack rather than flipping a bool.
        bool susdaiActive = vm.envOr("SUSDAI_ACTIVE", false);

        _preflight(reserve, factory, router, susdaiReserve);

        vm.startBroadcast(deployerKey);

        registry = StrategyGroupRegistry(
            address(
                new ERC1967Proxy(
                    address(new StrategyGroupRegistry()),
                    abi.encodeCall(StrategyGroupRegistry.initialize, (owner))
                )
            )
        );

        // Read the yield source off the pool rather than taking it from the environment. The
        // registry checks the two against each other anyway; deriving means there is no second
        // place for them to disagree.
        registry.setGroup(
            MARKET_GROUP_ID,
            StrategyGroupRegistry.GroupInput({
                reservePool: reserve,
                yieldSource: IPool(reserve).yieldSource(),
                factory: factory,
                router: router,
                zapper: zapper,
                policyId: MARKET_GROUP_ID,
                active: true,
                name: "USDG market reserve",
                strategy: "Morpho Blue USDG/USDe - Robinhood Chain"
            })
        );

        if (susdaiReserve != address(0)) {
            registry.setGroup(
                SUSDAI_GROUP_ID,
                StrategyGroupRegistry.GroupInput({
                    reservePool: susdaiReserve,
                    yieldSource: IPool(susdaiReserve).yieldSource(),
                    factory: factory,
                    router: router,
                    zapper: zapper,
                    policyId: SUSDAI_GROUP_ID,
                    active: susdaiActive,
                    name: "sUSDai reserve",
                    strategy: "sUSDai on Arbitrum via Across - keeper managed"
                })
            );
        }

        vm.stopBroadcast();

        _report(registry, owner, susdaiReserve, zapper, susdaiActive);
    }

    /// @dev Fail before broadcasting rather than after. The registry validates its own inputs,
    ///      but it reverts with addresses and no explanation of which environment variable
    ///      produced them, and a failed broadcast still costs the deploying transactions that
    ///      preceded it.
    function _preflight(address reserve, address factory, address router, address susdaiReserve)
        private
        view
    {
        require(reserve.code.length > 0, "SHARED_RESERVE_POOL has no code");
        require(factory.code.length > 0, "ASSET_MARKET_FACTORY has no code");
        require(router.code.length > 0, "MARKET_ROUTER has no code");
        require(IPool(reserve).yieldSource() != address(0), "reserve has no yield source");

        if (susdaiReserve != address(0)) {
            require(susdaiReserve.code.length > 0, "SUSDAI_RESERVE_POOL has no code");
            require(susdaiReserve != reserve, "SUSDAI_RESERVE_POOL is the USDG reserve");
            require(
                IPool(susdaiReserve).yieldSource() != address(0),
                "sUSDai reserve has no yield source"
            );
            // The one condition that is not local to this script: a second group only validates
            // because the factory approved its reserve. Say so here, where the fix is one owner
            // call, rather than letting FactoryReserveMismatch surface mid-broadcast.
            require(
                IFactory(factory).reservePool() == susdaiReserve
                    || IFactory(factory).approvedReservePool(susdaiReserve),
                "factory has not approved SUSDAI_RESERVE_POOL: call setApprovedReservePool first"
            );
        }
    }

    function _report(
        StrategyGroupRegistry registry,
        address owner,
        address susdaiReserve,
        address zapper,
        bool susdaiActive
    ) private view {
        console.log("");
        console.log("StrategyGroupRegistry (proxy):", address(registry));
        console.log("Owner:", owner);
        console.log("Groups published:", registry.groupCount());
        if (zapper == address(0)) {
            console.log("Zapper: none - groups publish address(0) until one is deployed.");
            console.log("  Re-run setGroup with LIQUIDITY_ZAPPER set to add it; a group's");
            console.log("  identity is its reserve, so this is an update and not a new id.");
        }
        if (susdaiReserve != address(0) && !susdaiActive) {
            console.log("");
            console.log("sUSDai group is published INACTIVE. The front end will not offer it");
            console.log("until its keeper runs: nothing is bridged and no remote value is");
            console.log("reported, so the round trip it advertises cannot complete.");
        }
        console.log("");
        console.log("Point the app at it - deployments/app-networks.json, chain 4663:");
        console.log('  "registry": "%s"', address(registry));
    }
}
