// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketDeployer} from "../src/markets/MarketDeployer.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";
import {LaunchpadDefaults} from "./DeployLaunchpad.s.sol";

/// @title HookSaltMiner
/// @notice Finds the CREATE2 salt that lands a v4 hook on an address carrying exactly the
///         permission bits it declares.
///
///         **Why this is not optional.** V4 reads a hook's permissions out of the low 14 bits of
///         its own address and calls only the callbacks those bits announce. A hook deployed to
///         an arbitrary address is not merely mislabelled — `Hooks.validateHookPermissions` in
///         `ProtocolFeeHook`'s constructor reverts, so the deployment fails outright.
///
///         **The salt is bound to the constructor arguments.** The candidate address is a hash of
///         (deployer, salt, initcode), and the initcode ends with the ABI-encoded constructor
///         arguments — so changing the PoolManager, the owner or the default fee changes the
///         address. Mining and deploying must therefore happen in the SAME script run, against
///         the same arguments; a salt recorded from a previous run is worthless the moment any
///         of the three moves.
///
///         Shared with `DeployAssetMarketsTestnet.s.sol` so both chains mine the same way. It
///         mirrors the standard v4 hook-mining loop, against forge's deterministic
///         CREATE2 factory rather than against the test contract.
library HookSaltMiner {
    /// @notice `beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta`.
    ///         The two return-delta bits are what let the hook actually claim the skim; without
    ///         them it could observe a swap but not take anything out of it.
    uint160 internal constant PROTOCOL_FEE_HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev forge's deterministic CREATE2 factory. `new X{salt: s}(...)` inside a broadcast is
    ///      routed through this address, so it — not the script — is the CREATE2 deployer the
    ///      candidate addresses have to be derived from.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Search for a salt whose CREATE2 address carries exactly `flags`.
    /// @param flags        The permission bits the hook must land on.
    /// @param initCode     Creation code WITH the constructor arguments already appended.
    /// @return hookAddress The address the deployment must produce.
    /// @return salt        The salt that produces it.
    function mine(uint160 flags, bytes memory initCode)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        // One in 2^14 salts qualifies, so a few tens of thousands of tries is generous. The
        // bound exists so a mistake fails in a minute rather than never returning.
        for (uint256 i = 0; i < 500_000; i++) {
            address candidate = vm.computeCreate2Address(bytes32(i), initCodeHash, CREATE2_DEPLOYER);
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == flags) {
                return (candidate, bytes32(i));
            }
        }
        revert("HookSaltMiner: no salt found");
    }
}

/// @title DeployAssetMarkets
/// @notice Step 2 of 2. Deploys the Phase 1 asset-market layer on Robinhood Chain mainnet
///         (chain ID 4663). See ASSET_MARKETS.md.
///
///         **This script uses the Uniswap v4 `PoolManager` already deployed on this chain.**
///         An earlier revision deployed its own, on the mistaken belief that v4 was not here.
///         It is: at `MainnetAddresses.POOL_MANAGER`, non-canonical in the same way this
///         chain's v3 factory is, and busy enough that a 9,000-block window exceeds the RPC's
///         10,000-log cap on `Swap` alone. That file records how it was found.
///
///         The distinction matters and is not recoverable later: a pool's `PoolKey` names a
///         singleton, so every market ever created names whichever one this script passed in.
///         Deploying our own would have produced markets that no aggregator, router or
///         interface on this chain could see. Using the live one means anything already
///         routing v4 here can route to them.
///
///         **Depends on a deployed `SharedReservePool`.** Run
///         `script/DeploySharedReservePool.s.sol` first and pass its pool address in as
///         `SHARED_RESERVE_POOL`. This script refuses to guess, and checks that what it is
///         given is a real pool holding USDG rather than any contract at all.
///
///         **Deployment order, and why it is this order:**
///
///         0. `MarketDeployer` — the external library holding the vault's and the LP reward
///            distributor's creation code, without which `AssetMarketFactory` exceeds EIP-170.
///            A Solidity library cannot be `new`ed and linking happens at compile time, so
///            forge deploys and links it as part of this broadcast; the script asserts and
///            PRINTS its address for the deployment manifest rather than pretending to deploy
///            it. Deploy with `--libraries src/markets/MarketDeployer.sol:MarketDeployer:<addr>`
///            to pin an existing one.
///         1. `PoolManager` — the v4 singleton, ours (see above).
///         2. `ProtocolFeeHook` — at a MINED CREATE2 address, because v4 encodes a hook's
///            permissions in the low 14 bits of its address. Mining and deploying happen in the
///            same run: the salt is bound to the constructor arguments.
///         3. `AssetMarketFactory` — needs both of the above as immutables, and re-checks that
///            the hook answers to the same singleton.
///         4. `feeHook.setRegistrar(factory)` — WITHOUT THIS EVERY `createMarket` REVERTS. The
///            hook only lets its registrar bind a pool's fee destination, and the factory does
///            that on every market. The two contracts each need the other's address, so this
///            link cannot be a constructor argument on either side.
///         5. `MarketRouter` — reads the singleton off the factory, so it is told nothing about
///            the venue it trades in. It IS told where Uniswap's v4 `PositionManager` and
///            Permit2 live, because there is no factory to derive those from: `seedLiquidity`
///            mints the LP position through the periphery and hands the NFT to the seeder, so
///            liquidity is withdrawable by whoever put it in. The constructor refuses a
///            PositionManager bound to a different PoolManager, which is the only way that pair
///            of addresses can be wrong without failing loudly.
///
///         Nothing here approves an asset or creates a market. An approval fixes the price a
///         pool opens at, so it belongs to the launch it precedes rather than to the shared
///         infrastructure; this stands the stack up and prints the follow-up commands.
///
///         Usage:
///         SHARED_RESERVE_POOL=0x... forge script script/DeployAssetMarkets.s.sol --rpc-url robinhood --broadcast --slow
///
///         Environment variables:
///         - PRIVATE_KEY          deployer key (required)
///         - SHARED_RESERVE_POOL  a deployed SharedReservePool (required)
///         - PROTOCOL_TREASURY    protocol fee recipient (defaults to the deployer)
///         - PROTOCOL_BPS         protocol cut of YIELD in bps (defaults to 0)
///         - PROTOCOL_FEE_PIPS    trading skim in hundredths of a bp (defaults to 5_000 — 0.50%)
///         - REWARDS_DURATION     LP reward period in seconds (defaults to 7 days)
///         - MIN_OBSERVATION_CARDINALITY
///                                oracle buffer floor in slots (defaults to 62)
///         - DEPLOY_LAUNCHPAD     set true to add the launchpad to this run (defaults to
///                                false, which leaves the deployment exactly as it was). The
///                                launchpad can also be added to an existing stack later with
///                                script/DeployLaunchpad.s.sol.
contract DeployAssetMarkets is Script {
    // ─── Launch parameters ───────────────────────────────────────────────

    /// @notice Protocol cut of float YIELD, stamped into markets created from here on.
    ///         **Zero, and deliberately so.** The protocol's revenue is the trading skim below.
    ///         A market's float yield is what pays the LPs who make it usable, and the protocol
    ///         takes none of it.
    ///
    ///         Overridable per deployment through `PROTOCOL_BPS`, and settable afterwards with
    ///         `setProtocolParams` for markets created from that point on. A market already
    ///         deployed holds its own split in an immutable and never moves.
    uint16 constant DEFAULT_PROTOCOL_BPS = 0;

    /// @notice The protocol's cut of TRADING, in hundredths of a basis point, stamped into each
    ///         new market's pool when the factory registers it with the hook. A separate stream
    ///         from `DEFAULT_PROTOCOL_BPS`, which is the cut of float YIELD.
    ///
    ///         **0.50%, which is half of a market's 1% headline fee.** The hook takes it off
    ///         every swap's input before the pool sees it, and the pool's own 0.50% LP fee is
    ///         charged on what is left — so a trader pays about 1% and it is split down the
    ///         middle. See `AssetMarketFactory.tickSpacingForFee`, which is where the other
    ///         half is chosen, and `PRESET_FEE_TIER` below.
    uint24 constant DEFAULT_PROTOCOL_FEE_PIPS = 5_000;

    /// @notice The LP fee tier a market should be launched at to make the split above come out
    ///         at 1% total. Not enforced here — the tier is a field of the owner's asset
    ///         approval — but printed with the summary so whoever approves the first asset is
    ///         told the number rather than left to derive it.
    uint24 constant PRESET_FEE_TIER = 5_000;

    // ─── LP reward schedule and oracle depth ─────────────────────────────
    //
    // Stamped into each market as it is created: the period its distributor streams a sweep
    // over, and the depth its pool's oracle buffer is grown to. Both are settable afterwards
    // and move FUTURE markets only — a live market keeps what it was created with.

    /// @notice How long each swept reward is paid out over. A week is long enough that
    ///         "liquidity × time" stays a meaningful weight, and short enough that an LP joining
    ///         today earns at the market's current rate rather than last quarter's.
    uint32 constant DEFAULT_REWARDS_DURATION = 7 days;

    /// @notice Oracle slots each new pool's buffer is grown to. At the hook's 15-second
    ///         observation interval 62 slots hold a quarter of an hour of history, which is the
    ///         longest window anything reading these pools asks for.
    uint16 constant DEFAULT_MIN_OBSERVATION_CARDINALITY = 62;

    function run() external returns (AssetMarketFactory, MarketRouter) {
        // Mainnet is 4663, testnet is 46630. See the identical guard in step 1.
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address reservePoolAddr = vm.envAddress("SHARED_RESERVE_POOL");
        require(reservePoolAddr != address(0), "SHARED_RESERVE_POOL not set");
        require(reservePoolAddr.code.length > 0, "SHARED_RESERVE_POOL has no code");

        address protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
        uint16 protocolBps = uint16(vm.envOr("PROTOCOL_BPS", uint256(DEFAULT_PROTOCOL_BPS)));
        uint24 protocolFeePips =
            uint24(vm.envOr("PROTOCOL_FEE_PIPS", uint256(DEFAULT_PROTOCOL_FEE_PIPS)));
        uint32 rewardsDuration =
            uint32(vm.envOr("REWARDS_DURATION", uint256(DEFAULT_REWARDS_DURATION)));
        uint16 minCardinality = uint16(
            vm.envOr("MIN_OBSERVATION_CARDINALITY", uint256(DEFAULT_MIN_OBSERVATION_CARDINALITY))
        );
        // Optional, and off unless asked for: the launchpad is a layer ON TOP of this stack,
        // deployable at any time afterwards against the factory this run produces. Deploying
        // it here saves one run and one hand-pasted factory address, which is the only
        // difference between the two paths.
        bool withLaunchpad = vm.envOr("DEPLOY_LAUNCHPAD", false);

        SharedReservePool reservePool = SharedReservePool(reservePoolAddr);
        _checkReservePool(reservePool);

        console.log("=== Deploying AssetMarkets to Robinhood Chain mainnet ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Chain ID:", block.chainid);
        console.log("SharedReservePool:", reservePoolAddr);
        console.log("Reserve asset:", address(reservePool.asset()));
        console.log("Protocol treasury:", protocolTreasury);
        // 1. The v4 singleton already deployed on this chain. Checked rather than trusted:
        //    a wrong or empty address here would not fail until the first `createMarket`, and
        //    the markets would be unreachable rather than broken, which is worse.
        IPoolManager poolManager = IPoolManager(MainnetAddresses.POOL_MANAGER);
        require(MainnetAddresses.POOL_MANAGER.code.length > 0, "no PoolManager at that address");
        console.log("PoolManager (live, shared with the rest of the chain):", address(poolManager));

        // Uniswap's own v4 periphery, also already deployed here — which is what makes seeded
        // liquidity withdrawable at all. Same reasoning as the singleton above: an empty
        // address would not fail until the first `seedLiquidity`, long after the deployment
        // looked finished.
        require(MainnetAddresses.V4_POSITION_MANAGER.code.length > 0, "no v4 PositionManager there");
        require(MainnetAddresses.PERMIT2.code.length > 0, "no Permit2 there");
        console.log("v4 PositionManager (live):", MainnetAddresses.V4_POSITION_MANAGER);
        console.log("Permit2 (canonical):", MainnetAddresses.PERMIT2);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 2a. The two per-market beacons. Owned by the same timelock that owns the reserve,
        //     read off the reserve rather than re-derived, so step 2 cannot install beacons
        //     under a different authority than step 1 used.
        address timelock = Ownable(address(reservePool)).owner();
        ProtocolGuard guard = ProtocolGuard(address(reservePool.guard()));
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(timelock);
        console.log("BrandFeeVault beacon:", address(beacons.vault));
        console.log("LpRewardDistributor beacon:", address(beacons.distributor));
        console.log("ProtocolGuard (from the reserve):", address(guard));

        // 2b. The hook. **The mined address is the PROXY's, not the implementation's.**
        //     A v4 hook's permissions are the low 14 bits of the address the `PoolManager`
        //     calls, and behind a proxy that is the proxy. So the implementation is deployed
        //     first at whatever address it lands on, and the salt is mined over the PROXY's
        //     init code — which embeds the implementation address and the initialiser calldata,
        //     and therefore changes if either does.
        //
        //     The payoff is that upgrading the hook later does not move this address, so every
        //     pool ever created against it stays valid. What an upgrade must never do is change
        //     `getHookPermissions`; see the note on `ProtocolFeeHook.initialize`.
        address hookImpl = ProtocolStack.deployHookImplementation();
        bytes memory hookInitCode =
            ProtocolStack.hookProxyInitCode(hookImpl, poolManager, deployer, address(guard));
        (address minedHook, bytes32 hookSalt) =
            HookSaltMiner.mine(HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS, hookInitCode);
        ProtocolFeeHook feeHook = ProtocolFeeHook(
            address(
                new ERC1967Proxy{salt: hookSalt}(
                    hookImpl,
                    abi.encodeCall(
                        ProtocolFeeHook.initialize, (poolManager, deployer, address(guard))
                    )
                )
            )
        );
        require(address(feeHook) == minedHook, "hook did not land on its mined address");
        console.log("ProtocolFeeHook implementation:", hookImpl);
        console.log("ProtocolFeeHook (proxy, mined):", address(feeHook));
        console.log("    salt:", uint256(hookSalt));

        // 3. The factory. `MarketDeployer` must already be linked into this bytecode; the
        //    assertion below is what turns an unlinked build into a readable failure instead of
        //    a factory whose every `createMarket` hits a delegatecall to nothing.
        AssetMarketFactory factory = ProtocolStack.deployFactory(
            reservePool,
            poolManager,
            feeHook,
            IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER),
            protocolTreasury,
            MainnetAddresses.REFERENCE_EQUITY,
            protocolBps,
            rewardsDuration,
            minCardinality,
            deployer,
            beacons,
            address(guard)
        );
        console.log("AssetMarketFactory:", address(factory));

        // 4. The link the factory cannot make for itself. Without it the hook rejects
        //    `registerPool` and every market creation reverts `OnlyRegistrar`.
        feeHook.setRegistrar(address(factory));

        if (protocolFeePips != 0) factory.setProtocolFeePips(protocolFeePips);

        // 5. The router. It still reads the singleton off the factory rather than being told,
        //    but it now also mints LP positions through Uniswap's deployed v4 periphery, and
        //    there is no factory to derive *those* two addresses from — so they are passed, and
        //    the constructor checks the PositionManager belongs to the factory's PoolManager.
        MarketRouter router = ProtocolStack.deployRouter(
            reservePool,
            factory,
            IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER),
            IPermit2(MainnetAddresses.PERMIT2),
            deployer,
            address(guard)
        );
        console.log("MarketRouter:", address(router));

        // 6. The launchpad, if this run was asked for one. Everything structural is wired
        //    inside `deployLaunchpad`; what is left here is the pair of owner calls that cross
        //    into the market stack — registering the graduation module as the factory's
        //    launchpad, and the launch terms themselves.
        ProtocolStack.Launchpad memory launchpad;
        if (withLaunchpad) {
            launchpad = ProtocolStack.deployLaunchpad(
                deployer,
                address(guard),
                factory,
                IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER),
                IPermit2(MainnetAddresses.PERMIT2)
            );
            factory.setLaunchpad(address(launchpad.graduation));
            uint256 launchConfigId = LaunchpadDefaults.applyPolicy(
                launchpad.factory,
                protocolTreasury,
                vm.envOr("LAUNCH_LP_FUND_RECIPIENT", protocolTreasury)
            );

            require(
                factory.launchpad() == address(launchpad.graduation), "launchpad not registered"
            );
            require(
                launchpad.factory.launchForwarder() == address(launchpad.router),
                "launch forwarder is not the router"
            );
            require(launchConfigId == 0, "launch config id is not the first");
            console.log("LaunchFeeEscrow:", address(launchpad.feeEscrow));
            console.log("LaunchFactory (proxy):", address(launchpad.factory));
            console.log("LaunchLocker:", address(launchpad.locker));
            console.log("LaunchGraduation:", address(launchpad.graduation));
            console.log("LaunchRouter:", address(launchpad.router));
        }

        vm.stopBroadcast();

        _assertWiring(
            factory,
            router,
            reservePool,
            protocolTreasury,
            protocolBps,
            rewardsDuration,
            minCardinality
        );
        _assertVenue(factory, router, poolManager, feeHook);

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("RECORD THESE IN THE DEPLOYMENT MANIFEST:");
        console.log("  MarketDeployer (library, linked):", address(MarketDeployer));
        console.log("  PoolManager (ours):", address(poolManager));
        console.log("  ProtocolFeeHook:", address(feeHook));
        console.log("  AssetMarketFactory:", address(factory));
        console.log("  MarketRouter:", address(router));
        if (withLaunchpad) {
            console.log("  launchpad.feeEscrow:", address(launchpad.feeEscrow));
            console.log("  launchpad.factoryImplementation:", launchpad.factoryImplementation);
            console.log("  launchpad.factory:", address(launchpad.factory));
            console.log("  launchpad.graduationGuard:", address(launchpad.graduationGuard));
            console.log("  launchpad.locker:", address(launchpad.locker));
            console.log("  launchpad.deployer:", address(launchpad.launchDeployer));
            console.log("  launchpad.graduation:", address(launchpad.graduation));
            console.log("  launchpad.router:", address(launchpad.router));
            console.log("");
            console.log("The launchpad is deployed and its terms are applied, but LAUNCHING IS");
            console.log("DISABLED: no brand exists yet to quote a curve in. Register the quote");
            console.log("brand on the reserve, then open it and switch launching on:");
            console.log(
                "    cast send <launchFactory> 'setPairTokenEconomics(address,(address,uint256,uint256,uint256,uint8,bool))' <brand> '(<reserve>,3236000000,8090000000,1000000,6,false)'"
            );
            console.log(
                "    cast send <launchFactory> 'setPairTokenApproved(address,bool)' <brand> true"
            );
            console.log("    cast send <launchFactory> 'setLaunchEnabled(bool)' true");
        }
        console.log("");
        console.log("Factory runtime size (bytes):", address(factory).code.length);
        console.log("    EIP-170 limit is 24576. The vault's and the distributor's creation");
        console.log("    code live in MarketDeployer, which keeps this number where it is.");
        console.log("Equity verification: ACTIVE");
        console.log("Protocol fee on yield (bps):", protocolBps);
        console.log("Paid to LPs from yield (bps):", uint256(10_000) - protocolBps);
        console.log("Protocol fee on trading (pips of 1e6):", protocolFeePips);
        console.log("Approve assets at this LP fee tier:", PRESET_FEE_TIER);
        console.log("LP reward period (s):", rewardsDuration);
        console.log("Oracle buffer floor (slots):", minCardinality);
        console.log("");
        console.log("Verify the whole stack, reading nothing back by hand:");
        console.log("    SHARED_RESERVE_POOL=<pool> ASSET_MARKET_FACTORY=<factory> \\");
        console.log("      MARKET_ROUTER=<router> forge script \\");
        console.log("      script/VerifyAssetMarketsMainnet.s.sol --rpc-url robinhood");
        console.log("");
        console.log("--- Launching a market: an approval, then anybody may create it ---");
        console.log("The owner approves the asset once, and that approval carries everything");
        console.log("economic: the fee tier, the starting price, the oracle depth and the market");
        console.log("unit's name and symbol. Creation afterwards is permissionless and takes no");
        console.log("parameters at all, so whoever calls it cannot price the pool they open.");
        console.log("assetPriceE18 is ONE WHOLE asset unit priced in WHOLE unit-token units,");
        console.log("scaled 1e18 - e.g. 154e18 for $154. REFRESH IT BEFORE A LAUNCH: an approval");
        console.log("that has sat for months prices the pool at a stale number and the first");
        console.log("liquidity in is arbitraged to the real price. approveAsset may be called");
        console.log("again at any time and moves later creations only.");
        console.log(
            "    cast send <factory> 'approveAsset(address,(bool,uint24,uint256,uint16,string,string))' <asset> '(true,5000,154000000000000000000,62,<unitName>,<unitSymbol>)'"
        );
        console.log(
            "    cast send <factory> 'createMarket(address,address)' <asset> 0x0000000000000000000000000000000000000000"
        );
        console.log("The zero reserve selects the factory's default; anything else must be an");
        console.log("approvedReservePool. Read (marketId, brandToken, feeVault, lpDistributor,");
        console.log("poolId) from MarketCreated. A v4 pool has no address - `poolId` is a key");
        console.log("hash, and `poolKeyOf(marketId)` rebuilds the key every v4 call needs.");
        console.log("Market ids begin at 1, and one reserve holds at most ONE market per asset.");
        console.log("");
        console.log("createMarket registers the market unit itself, from the approval's name and");
        console.log("symbol, so registerBrand is only for a brand that will never have a market.");
        console.log("Its caller becomes the metadata admin AND the brand treasury's admin, which");
        console.log("is what lets such a brand claim its own float:");
        console.log("    cast send <factory> 'registerBrand(string,string)' '<name>' '<symbol>'");
        console.log("The metadata strings may all be empty. The logo is the one that matters: it");
        console.log("is what an indexer reads off PooledBrandToken.logo(), and the admin can");
        console.log("change it later through setMetadata. Left empty, the factory writes a URL");
        console.log("derived from logoBaseURI - see setLogoTemplate.");
        console.log("");
        console.log("Read a live market's pool price back. Takes the unit token, which only");
        console.log("exists once the market does - which is why an approval carries a plain");
        console.log("human price and not a sqrtPriceX96 nobody could compute in advance:");
        console.log(
            "    cast call <factory> 'quoteSqrtPriceX96(address,address,uint256)(uint160)' <brand> <asset> <priceE18>"
        );
        console.log("");
        console.log("Seed liquidity (approve the router for BOTH sides first). USDG is minted");
        console.log("into the brand stablecoin inside the call, so the seeder needs only USDG");
        console.log("and the asset. The position is a REAL Uniswap v4 LP NFT minted to the");
        console.log("caller, who exits it through Uniswap's own PositionManager with no help");
        console.log("from this repo. minBrandUsed/minAssetUsed are NOT optional - zero is an");
        console.log("open invitation to an add-liquidity sandwich:");
        console.log(
            "    cast send <router> 'seedLiquidity(uint256,uint256,uint256,uint256,uint256,uint256)' <marketId> <usdg> <asset> <minBrandUsed> <minAssetUsed> <deadline>"
        );
        console.log("");
        console.log("Buy and sell (every call takes a short Unix-seconds deadline):");
        console.log(
            "    cast send <router> 'buyWithUsdg(uint256,uint256,uint256,address,uint256)' <marketId> <usdgIn> <minAssetOut> <receiver> <deadline>"
        );
        console.log(
            "    cast send <router> 'sellForBrand(uint256,uint256,uint256,address,uint256)' <marketId> <assetIn> <minBrandOut> <receiver> <deadline>"
        );
        console.log("");
        console.log("Harvest and pay out the market's income (both permissionless):");
        console.log("    cast send <feeVault> 'harvest()' && cast send <feeVault> 'sweep()'");
        console.log("sweep() splits the harvested float yield two ways: protocolBps to the");
        console.log("protocol treasury, and the WHOLE remainder - rounding dust included - minted");
        console.log("into the market unit and handed to the LP reward distributor, which streams");
        console.log("it over the reward period above. Under one whole reserve unit it reverts");
        console.log("BelowMinSweep rather than burn gas paying out nothing.");
        console.log("The pool's trading skim accrues inside the hook and is pulled to the");
        console.log("PROTOCOL TREASURY, not to the market's vault - the trading fee is the");
        console.log("protocol's, and the vault lives on float yield alone. Permissionless,");
        console.log("passing the key from poolKeyOf(marketId):");
        console.log("    cast send <feeHook> 'collect((address,address,uint24,int24,address))' ...");
        console.log("sweepStrayAsset() pays the PROTOCOL TREASURY and exists only because anyone");
        console.log("can transfer the asset to a vault; nothing in the stack routes it there:");
        console.log("    cast send <feeVault> 'sweepStrayAsset()'");
        console.log("");
        console.log("An LP earns those rewards by staking a FULL-RANGE position of the market's");
        console.log("own pool. The distributor pulls the NFT with transferFrom, so approve it");
        console.log("first; unstake returns the NFT and is deliberately never pausable:");
        console.log(
            "    cast send <positionManager> 'approve(address,uint256)' <lpDistributor> <tokenId>"
        );
        console.log(
            "    cast send <lpDistributor> 'stake(uint256,address)' <tokenId> <beneficiary>"
        );
        console.log("    cast send <lpDistributor> 'claim(address)' <brandOut>");
        console.log("    cast send <lpDistributor> 'unstake(uint256)' <tokenId>");
        console.log("claim pays in any brand registered in this market's reserve, and");
        console.log("collectFees(tokenId) sweeps the position's own trading fees to its staker.");
        console.log("");
        console.log("Deploy idle reserve into the yield source:");
        console.log("    cast send <reservePool> 'deployIdle()'");
        console.log("    NOTE: mint() supplies inline, so the adapter is live from the FIRST");
        console.log("    mint. deployIdle() no longer gates any exposure.");

        return (factory, router);
    }

    /// @dev `SHARED_RESERVE_POOL` is an address from a previous run pasted by hand, which is
    ///      exactly the kind of thing that gets pasted wrong. Prove it is the pool this stack
    ///      expects before wiring an immutable to it — `AssetMarketFactory.reservePool` cannot
    ///      be changed afterwards.
    function _checkReservePool(SharedReservePool pool) private view {
        require(address(pool.asset()) == MainnetAddresses.USDG, "reserve pool does not hold USDG");
        require(
            pool.assetDecimals() == MainnetAddresses.USDG_DECIMALS, "reserve pool decimals mismatch"
        );
        require(address(pool.yieldSource()) != address(0), "reserve pool has no yield source");

        // The pool's owner should be the timelock step 1 deployed, not an EOA. An EOA owner can
        // swap the yield source in one transaction and the reserve moves with it. Reported
        // rather than enforced: the owner is legitimately an EOA during a rehearsal, and this
        // script is not the place to decide that a given governance posture is final.
        address owner = Ownable(address(pool)).owner();
        console.log("Reserve pool owner:", owner);
        if (owner.code.length == 0) {
            console.log("");
            console.log("############################################################");
            console.log("## WARNING: the reserve pool is owned by an EOA, not a     ##");
            console.log("## timelock. That key can redirect the pool's entire       ##");
            console.log("## reserve to a new yield source in one transaction.       ##");
            console.log("## ASSET_MARKETS.md section 11, Phase 0. Proceeding.       ##");
            console.log("############################################################");
            console.log("");
        }
    }

    /// @dev Everything a mis-ordered constructor argument would get wrong, checked against the
    ///      deployed contracts rather than against the values passed in.
    function _assertWiring(
        AssetMarketFactory factory,
        MarketRouter router,
        SharedReservePool reservePool,
        address protocolTreasury,
        uint16 protocolBps,
        uint32 rewardsDuration,
        uint16 minCardinality
    ) private view {
        require(address(factory.reservePool()) == address(reservePool), "factory reserve mismatch");
        require(factory.protocolTreasury() == protocolTreasury, "factory treasury mismatch");
        require(factory.protocolBps() == protocolBps, "factory protocol bps mismatch");
        require(factory.marketCount() == 0, "fresh factory already has markets");

        // The canonicality test must be live, or every market would be created unverified and
        // nobody would notice until a user asked why.
        require(factory.equityCodehash() != bytes32(0), "reference equity has no code");
        require(
            factory.isCanonicalEquity(MainnetAddresses.REFERENCE_EQUITY),
            "canonicality test is not working"
        );

        require(factory.rewardsDuration() == rewardsDuration, "factory reward period mismatch");
        require(
            factory.minObservationCardinality() == minCardinality,
            "factory oracle buffer floor mismatch"
        );

        // The periphery every market's LP reward distributor is initialised with. Wrong here
        // and staking a position reverts on an NFT the distributor cannot read — which nobody
        // discovers until the first LP tries to earn.
        require(
            address(factory.positionManager()) == MainnetAddresses.V4_POSITION_MANAGER,
            "factory PositionManager mismatch"
        );

        require(address(router.factory()) == address(factory), "router factory mismatch");
        require(address(router.reservePool()) == address(reservePool), "router reserve mismatch");

        console.log("");
        console.log("Wiring assertions: PASSED");
    }

    /// @dev The v4-specific half, which is where a silent failure would actually live. Every
    ///      one of these is a state a deployment can reach and still look finished: a linked
    ///      library that is not there, a hook on the wrong address bits, a hook answering to a
    ///      different singleton, or — the one that costs a whole launch — a hook whose
    ///      registrar was never set, so the first `createMarket` reverts in production.
    function _assertVenue(
        AssetMarketFactory factory,
        MarketRouter router,
        IPoolManager poolManager,
        ProtocolFeeHook feeHook
    ) private view {
        require(address(MarketDeployer).code.length > 0, "MarketDeployer library is not linked");

        require(
            address(factory.poolManager()) == address(poolManager), "factory singleton mismatch"
        );
        require(address(factory.feeHook()) == address(feeHook), "factory hook mismatch");
        require(address(router.poolManager()) == address(poolManager), "router singleton mismatch");
        require(
            address(feeHook.poolManager()) == address(poolManager),
            "hook answers to a different singleton"
        );
        require(
            uint160(address(feeHook)) & Hooks.ALL_HOOK_MASK
                == HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS,
            "hook address does not carry its permission bits"
        );
        require(feeHook.registrar() == address(factory), "hook registrar is not the factory");

        // The fee tiers a market may be opened at, pinned to v3's spacings so every chart and
        // mental model built against the old pools still reads correctly.
        require(factory.tickSpacingForFee(500) == 10, "fee tier table is wrong");
        require(factory.tickSpacingForFee(3_000) == 60, "fee tier table is wrong");
        require(factory.tickSpacingForFee(5_000) == 50, "fee tier table is wrong");

        console.log("Venue assertions: PASSED");
        console.log("    MarketDeployer library:", address(MarketDeployer));
        console.log("    hook permission bits:", uint256(uint160(address(feeHook)) & 0x3FFF));
    }
}
