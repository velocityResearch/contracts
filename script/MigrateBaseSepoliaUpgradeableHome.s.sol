// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";

/// @notice Step 2 of moving the public Base Sepolia integration onto upgradeable contracts.
///         Replaces the two remaining non-upgradeable stateful contracts on the home chain:
///         the sUSDai adapter `0x8658354fd7CFa74Ee12a82B47FCAb3Ce7967709c` and the strategy
///         group registry `0x5a6ab3bab70f9741fFEAF370925Fdfa152b0384F`, each with a UUPS proxy
///         the deployer can upgrade in one transaction.
///
///         **Why the position has to be home first.** `SharedReservePool.setYieldSource` calls
///         `oldSource.balanceOf(asset)` and then withdraws exactly that much. For this adapter
///         that number includes anything sitting on Arbitrum, which `withdraw` cannot return —
///         so a migration attempted with a live remote position recalls less than it books and
///         strands the difference. The keeper is run to a 100% local target before this script,
///         and the assertions below refuse to proceed otherwise. Those assertions execute in
///         forge's simulation EVM, not on chain, so two things make them binding: the FIRST
///         broadcast call is `setMaxBridgeAmount(0)` on the old adapter, which fail-closes its
///         `bridgeOut` before anything is read, and the cutover passes `acceptStranding: false`,
///         so a leg that slipped in ahead of the freeze reverts instead of being stranded.
///
///         The registry cannot be migrated in place: it holds the group table, so the new proxy
///         is re-registered from the old one's records, group id for group id, with the sUSDai
///         group repointed at the new adapter. Group ids are preserved, so anything quoting an
///         id keeps resolving.
///
///         Usage:
///         HUB_ADDRESS=<step 1 proxy> forge script \
///           script/MigrateBaseSepoliaUpgradeableHome.s.sol \
///           --rpc-url https://sepolia.base.org --broadcast --slow
contract MigrateBaseSepoliaUpgradeableHome is Script {
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant ARBITRUM_SEPOLIA = 421614;

    address constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant BASE_SPOKE_POOL = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;
    address constant ARBITRUM_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant GUARD = 0x5183E734D7fbFe74dD057A742C4c15989B75F4cB;

    address constant SUSDAI_RESERVE = 0xecF46dC819Ef7523b842852B1026a5622889FB11;
    address constant OLD_ADAPTER = 0x8658354fd7CFa74Ee12a82B47FCAb3Ce7967709c;
    address constant OLD_REGISTRY = 0x5a6ab3bab70f9741fFEAF370925Fdfa152b0384F;

    uint256 constant MAX_BRIDGE_AMOUNT = 5_000_000_000;

    function run() external returns (SUSDaiYieldSource adapter, StrategyGroupRegistry registry) {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia (84532)");

        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address keeper = vm.envOr("KEEPER_ADDRESS", deployer);
        address hub = vm.envAddress("HUB_ADDRESS");
        // No code check: the hub lives on Arbitrum Sepolia, so it has no bytecode at this
        // address on this chain. Step 3 is what proves the pair agrees, by setting the hub's
        // `homeReceiver` to the adapter this script deploys and asserting from that side.
        require(hub != address(0), "HUB_ADDRESS is unset");

        SUSDaiYieldSource old = SUSDaiYieldSource(OLD_ADAPTER);
        SharedReservePool pool = SharedReservePool(SUSDAI_RESERVE);
        // Freezing OLD_ADAPTER is only an interlock if OLD_ADAPTER is what the pool is about to
        // be recalled from. Without this the script would fail-close a contract nobody reads and
        // then recall from whatever live, still-bridging adapter the pool actually holds.
        require(
            address(pool.yieldSource()) == OLD_ADAPTER, "pool is not on the adapter this replaces"
        );
        uint256 assetsBefore = pool.totalAssets();
        uint256 supplyBefore = pool.totalPooledSupply();

        vm.startBroadcast(key);

        // 1. Stop the old adapter from opening another outbound leg, as the first thing that
        //    lands on chain. The keeper polls every 60s and owns `bridgeOut`, so a remote
        //    position asserted zero at simulation time says nothing about inclusion time —
        //    especially under `--slow`, which widens that window on purpose. Zero
        //    `maxBridgeAmount` is the adapter's own fail-closed state (`bridgeOut` reverts
        //    `BridgeAmountAboveCap`), it is owner-only, and it takes effect in the same
        //    transaction, so from here on no new leg can appear behind the assertions' back.
        old.setMaxBridgeAmount(0);

        // 2. The zero-remote preconditions, read after the freeze rather than before it.
        //    `setYieldSource` recalls `balanceOf`, which for this adapter includes the Arbitrum
        //    leg and both in-flight counters, while `withdraw` can only ever pay the local
        //    balance — so any of these three being non-zero is a short recall, not a migration.
        require(old.remoteValue() == 0, "old adapter still reports a remote position");
        require(old.outboundInFlight() == 0, "old adapter has an outbound leg in flight");
        require(old.inboundInFlight() == 0, "old adapter has an inbound leg in flight");
        // With those three at zero the book reduces to the ERC-20 balance, so the old
        // book-vs-balance check compared a value to itself; the post-conditions below are what
        // prove the balance actually moved.
        uint256 carried = old.balanceOf(BASE_USDC);

        // 3. The adapter, behind a proxy, wired to the new hub.
        SUSDaiYieldSource adapterImpl = new SUSDaiYieldSource();
        adapter = SUSDaiYieldSource(
            address(
                new ERC1967Proxy(
                    address(adapterImpl),
                    abi.encodeCall(
                        SUSDaiYieldSource.initialize,
                        (
                            BASE_USDC,
                            BASE_SPOKE_POOL,
                            ARBITRUM_SEPOLIA,
                            hub,
                            ARBITRUM_USDC,
                            GUARD,
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        adapter.bindController(SUSDAI_RESERVE);
        adapter.setMaxBridgeAmount(MAX_BRIDGE_AMOUNT);

        // 4. The cutover. Recalls every unit from the old adapter into the pool, then points
        //    the pool at the new one. Funds land idle in the pool and `deployIdle` pushes them
        //    into the new adapter — deliberately two steps, so a mis-wired adapter cannot be
        //    handed the reserve in the same call that names it. `acceptStranding: false` is the
        //    one value-safety check that runs on chain: if the old adapter cannot deliver the
        //    whole book the pool is about to stop counting, this reverts `MigrationWouldStrand`
        //    rather than silently writing every holder's NAV down by the difference.
        pool.setYieldSource(address(adapter), false);
        pool.deployIdle();

        // 5. The registry, re-registered group for group from the old one.
        StrategyGroupRegistry registryImpl = new StrategyGroupRegistry();
        registry = StrategyGroupRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl),
                    abi.encodeCall(StrategyGroupRegistry.initialize, (deployer))
                )
            )
        );
        _copyGroups(registry, address(adapter));

        vm.stopBroadcast();

        require(address(pool.yieldSource()) == address(adapter), "pool did not take the adapter");
        require(adapter.controller() == SUSDAI_RESERVE, "adapter is not bound to the reserve");
        require(adapter.availableLiquidity() == carried, "the position did not arrive intact");
        require(IERC20(BASE_USDC).balanceOf(OLD_ADAPTER) == 0, "the old adapter kept something");
        require(pool.totalAssets() == assetsBefore, "pool assets moved during the migration");
        require(pool.totalPooledSupply() == supplyBefore, "pool supply moved during migration");
        require(
            registry.groupCount() == StrategyGroupRegistry(OLD_REGISTRY).groupCount(), "groups lost"
        );

        console.log("SUSDaiYieldSource implementation:", address(adapterImpl));
        console.log("SUSDaiYieldSource proxy:", address(adapter));
        console.log("    carried across (USDC):", carried);
        console.log("StrategyGroupRegistry implementation:", address(registryImpl));
        console.log("StrategyGroupRegistry proxy:", address(registry));
        console.log("");
        console.log("NEXT: step 3 sets the hub's homeReceiver to the adapter proxy above.");
    }

    /// @dev Copies each registered group, substituting the new adapter wherever the old one
    ///      was named. Reads the old registry rather than re-stating the records, so a group
    ///      added since the last deployment cannot be silently dropped. Each record is then
    ///      round-tripped and the source group deactivated: the old registry keeps answering at
    ///      its published address, so a group left active there is a live-looking pointer at a
    ///      drained adapter for every consumer that has not yet learned the new address.
    function _copyGroups(StrategyGroupRegistry registry, address newAdapter) private {
        StrategyGroupRegistry source = StrategyGroupRegistry(OLD_REGISTRY);
        uint256 count = source.groupCount();
        // An empty source is never a legitimate migration of THIS registry — it means
        // OLD_REGISTRY is the wrong address or the wrong chain. Without this the script
        // publishes an empty directory, deactivates nothing, and still satisfies the
        // groupCount equality in `run`, because zero equals zero.
        require(count > 0, "old registry has no groups to copy");
        for (uint256 i = 0; i < count; i++) {
            bytes32 groupId = source.groupIdAt(i);
            StrategyGroupRegistry.Group memory g = source.group(groupId);
            // The one substitution. Every other field, including the `asset` the registry
            // re-derives from the pool, has to survive the round trip untouched.
            if (g.reservePool == SUSDAI_RESERVE) g.yieldSource = newAdapter;
            registry.setGroup(
                groupId,
                StrategyGroupRegistry.GroupInput({
                    reservePool: g.reservePool,
                    yieldSource: g.yieldSource,
                    factory: g.factory,
                    router: g.router,
                    zapper: g.zapper,
                    policyId: g.policyId,
                    active: g.active,
                    name: g.name,
                    strategy: g.strategy
                })
            );
            // Replaces a spot check on group 0 that reverted out of bounds on an empty source
            // and asserted nothing whenever exactly one group existed. Hashing the whole record
            // covers the metadata strings too, which a field-by-field address check would miss.
            require(
                keccak256(abi.encode(registry.group(groupId))) == keccak256(abi.encode(g)),
                "copied group does not match the source record"
            );
            // Only once the copy is proven: one bool, no call into any dependency, so it cannot
            // revert on wiring the cutover has already made stale.
            source.deactivateGroup(groupId);
        }
    }
}
