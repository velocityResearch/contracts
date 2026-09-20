// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";
import {IAcrossSpokePool} from "../src/interfaces/IAcrossSpokePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {SUSDaiAddresses} from "./SUSDaiAddresses.sol";

/// @title DeploySUSDaiGroup
/// @notice Step 2 of 2 for the sUSDai-backed reserve. Deploys, on Robinhood Chain mainnet
///         (chain ID 4663), a second `SharedReservePool` — "the sUSDai group" — whose yield
///         source is `SUSDaiYieldSource`, the Robinhood half of a position that lives on
///         Arbitrum. `script/DeploySUSDaiHub.s.sol` is step 1 and produces `SUSDAI_HUB`.
///
///         Deployed contracts:
///         1. SUSDaiYieldSource — the adapter. Holds the USDG buffer redemptions are paid from,
///            escrows batches with Across for the hub, and carries the keeper's reports of what
///            the hub holds. A fresh implementation behind a fresh ERC1967 proxy, owned by the
///            timelock, driven by `SUSDAI_KEEPER`.
///         2. SharedReservePool — a fresh implementation and a fresh ERC1967 proxy, initialised
///            against the adapter and owned by the timelock from birth. It REUSES the live
///            brand-token and treasury beacons from the v4 deployment, so a brand registered
///            here is the same `PooledBrandToken`/`PoolBrandTreasury` code as a brand in the
///            live USDG group and upgrades with it. Nothing about the beacons is redeployed.
///         3. `adapter.bindController(pool)` — the adapter's one-shot, deployer-only bind.
///
///         NOT done here, and cannot be: `setRedemptionFee`. The pool is owned by the timelock
///         from its first block, so the fee is a scheduled governance call with the timelock's
///         full delay in front of it. This script prints the exact `schedule` and `execute`
///         recipes. Until the fee reads 14 bps the group is fee-free, and every mint/redeem
///         round trip is a bridge-and-swap cost the group eats — so the keeper must not bridge
///         anything out before the fee lands. The script says so in capitals.
///
///         NOT done here, deliberately: registering any brand. Same caveat as
///         `DeploySharedReservePool`: a brand registered directly on the reserve can never be
///         given a market by `AssetMarketFactory`, because the factory has to be the one that
///         registered it. That is a statement about this script, not about the group — the
///         factory now serves several reserves, so once the owner calls
///         `setApprovedReservePool` for this pool a coin launched through `createMarket` with
///         `reservePool` set to it gets its market in the same transaction, exactly as a
///         USDG-group coin does.
///
///         Live values for the required env vars (deployments/asset-markets-mainnet-v4.json):
///         - TIMELOCK           0x5f43E1e732c7aBdbbC73F9d1367320D9040C872a  (delay 172800 s)
///         - PROTOCOL_GUARD     0x88eeA21D246DF8aa4Ca071532cB06d4f66D45f65
///         - BRAND_TOKEN_BEACON 0xc7433cD04Ce4B5b326602EFeD3bBA68d29aC4Bde
///         - TREASURY_BEACON    0x8AB0789D62a06546bfF51Be28ecaC696eb817897
///
///         Usage (dry run, then broadcast):
///         SUSDAI_HUB=<hub> TIMELOCK=0x5f43E1e732c7aBdbbC73F9d1367320D9040C872a PROTOCOL_GUARD=0x88eeA21D246DF8aa4Ca071532cB06d4f66D45f65 BRAND_TOKEN_BEACON=0xc7433cD04Ce4B5b326602EFeD3bBA68d29aC4Bde TREASURY_BEACON=0x8AB0789D62a06546bfF51Be28ecaC696eb817897 forge script script/DeploySUSDaiGroup.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
///         (same, plus) --broadcast --slow
///
///         Environment variables:
///         - PRIVATE_KEY          deployer key (required). Also the only key that can call
///                                `bindController`, which is why this script does it.
///         - SUSDAI_HUB           `SUSDaiHub` on Arbitrum (required). CANNOT be code-checked
///                                from this chain; copy it from step 1's output and read it
///                                back with `cast code <hub> --rpc-url <arbitrum>` yourself.
///         - SUSDAI_KEEPER        keeper key for `bridgeOut`/`sync` (default: the deployer).
///                                Must match the hub's keeper or the service needs two keys.
///         - TIMELOCK             owner of the pool and the adapter (required).
///         - PROTOCOL_GUARD       pause registry the pool and adapter consult (required).
///         - BRAND_TOKEN_BEACON   live `PooledBrandToken` beacon (required).
///         - TREASURY_BEACON      live `PoolBrandTreasury` beacon (required).
///         - REDEMPTION_FEE_BPS   the fee the printed timelock recipe schedules (default 14).
///         - LIABILITY_CAP        aggregate pool mint ceiling in 6-decimal USDG (required).
///         - MAX_BRIDGE_AMOUNT    per-deposit adapter ceiling in 6-decimal USDG (required).
contract DeploySUSDaiGroup is Script {
    struct Env {
        uint256 deployerKey;
        address deployer;
        address hub;
        address keeper;
        address timelock;
        address guard;
        address brandTokenBeacon;
        address treasuryBeacon;
        uint256 feeBps;
        uint256 liabilityCap;
        uint256 bridgeCap;
    }

    function run() external returns (SUSDaiYieldSource, SharedReservePool) {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        Env memory e;
        e.deployerKey = vm.envUint("PRIVATE_KEY");
        e.deployer = vm.addr(e.deployerKey);
        e.hub = vm.envAddress("SUSDAI_HUB");
        e.keeper = vm.envOr("SUSDAI_KEEPER", e.deployer);
        e.timelock = vm.envAddress("TIMELOCK");
        e.guard = vm.envAddress("PROTOCOL_GUARD");
        e.brandTokenBeacon = vm.envAddress("BRAND_TOKEN_BEACON");
        e.treasuryBeacon = vm.envAddress("TREASURY_BEACON");
        e.feeBps = vm.envOr("REDEMPTION_FEE_BPS", uint256(14));
        e.liabilityCap = vm.envUint("LIABILITY_CAP");
        e.bridgeCap = vm.envUint("MAX_BRIDGE_AMOUNT");

        console.log("=== Deploying the sUSDai group to Robinhood Chain mainnet ===");
        console.log("Deployer:", e.deployer);
        console.log("Deployer balance (wei):", e.deployer.balance);
        console.log("Chain ID:", block.chainid);
        console.log("Hub (Arbitrum, NOT verifiable from here):", e.hub);
        console.log("Keeper:", e.keeper);
        console.log("Timelock (owner of pool and adapter):", e.timelock);
        console.log("");

        _preflight(e);

        vm.startBroadcast(e.deployerKey);

        // 1. The adapter: fresh implementation, fresh proxy. `deployer` is stamped as the
        //    caller of `initialize`, which the proxy's constructor runs with the broadcaster
        //    still as msg.sender — that is what lets step 3 below bind it.
        address adapterImpl = address(new SUSDaiYieldSource());
        SUSDaiYieldSource adapter = SUSDaiYieldSource(
            address(
                new ERC1967Proxy(
                    adapterImpl,
                    abi.encodeCall(
                        SUSDaiYieldSource.initialize,
                        (
                            MainnetAddresses.USDG,
                            SUSDaiAddresses.ROBINHOOD_SPOKE_POOL,
                            SUSDaiAddresses.ARBITRUM_CHAIN_ID,
                            e.hub,
                            SUSDaiAddresses.ARB_USDC,
                            e.guard,
                            e.timelock,
                            e.keeper
                        )
                    )
                )
            )
        );
        console.log("SUSDaiYieldSource implementation:", adapterImpl);
        console.log("SUSDaiYieldSource (adapter):", address(adapter));

        // 2. The pool: fresh implementation, fresh proxy, live beacons. Built inline rather
        //    than through `ProtocolStack.deployReservePool`, which takes a five-beacon struct
        //    and reads two fields of it: filling the other three with zero to satisfy a helper
        //    that then forwards the same six arguments is less honest than the six arguments.
        //    It also keeps the market stack (factory, router, hook, v4-core) out of this
        //    script's compile, which has no use for any of it.
        address poolImpl = address(new SharedReservePool());
        SharedReservePool pool = SharedReservePool(
            address(
                new ERC1967Proxy(
                    poolImpl,
                    abi.encodeCall(
                        SharedReservePool.initialize,
                        (
                            MainnetAddresses.USDG,
                            address(adapter),
                            e.timelock,
                            e.brandTokenBeacon,
                            e.treasuryBeacon,
                            e.guard
                        )
                    )
                )
            )
        );
        console.log("SharedReservePool implementation:", poolImpl);
        console.log("SharedReservePool (sUSDai group) proxy:", address(pool));

        // 3. Bind. One shot, deployer only; after this nothing but the pool may deposit or
        //    withdraw, and nothing can ever rebind.
        adapter.bindController(address(pool));

        vm.stopBroadcast();

        _assertWiring(adapter, pool, e);
        _printNext(adapter, pool, e);

        return (adapter, pool);
    }

    /// @dev Everything the two initializers will trust, re-read live. The
    ///      hub is the one input this cannot check: it is on Arbitrum.
    function _preflight(Env memory e) private view {
        require(e.hub != address(0), "SUSDAI_HUB is zero");
        require(e.keeper != address(0), "SUSDAI_KEEPER is zero");
        require(e.liabilityCap > 0, "LIABILITY_CAP is zero");
        require(e.bridgeCap > 0, "MAX_BRIDGE_AMOUNT is zero");

        require(MainnetAddresses.USDG.code.length > 0, "USDG has no code");
        require(
            IERC20Metadata(MainnetAddresses.USDG).decimals() == MainnetAddresses.USDG_DECIMALS,
            "USDG decimals changed"
        );

        require(SUSDaiAddresses.ROBINHOOD_SPOKE_POOL.code.length > 0, "SpokePool has no code");
        IAcrossSpokePool spoke = IAcrossSpokePool(SUSDaiAddresses.ROBINHOOD_SPOKE_POOL);
        require(
            spoke.depositQuoteTimeBuffer() == SUSDaiAddresses.SPOKE_QUOTE_TIME_BUFFER,
            "SpokePool depositQuoteTimeBuffer changed"
        );
        require(
            spoke.fillDeadlineBuffer() == SUSDaiAddresses.SPOKE_FILL_DEADLINE_BUFFER,
            "SpokePool fillDeadlineBuffer changed"
        );

        require(e.guard.code.length > 0, "PROTOCOL_GUARD has no code");
        require(e.timelock != address(0), "TIMELOCK is zero");
        // An EOA owner is permitted, and is what `DeploySharedReservePool` produces when it is
        // run with `TIMELOCK_MIN_DELAY=0`. This used to require code here, which made the two
        // scripts disagree: step 1 would happily stand up an EOA-owned stack and then this one
        // refused to extend it, leaving the sUSDai group undeployable on exactly the
        // configuration step 1 offers. The owner is reported loudly instead, because it is a
        // real reduction in safety rather than a detail — whoever holds this key can re-point
        // the adapter and the reserve in one transaction, with nobody able to react.
        if (e.timelock.code.length == 0) {
            console.log("############################################################");
            console.log("## WARNING: the owner is an EOA, not a timelock. Every    ##");
            console.log("## owner call on this group - the liability cap, the       ##");
            console.log("## redemption fee, the bridge caps, the implementations -  ##");
            console.log("## lands instantly and irreversibly from one key.          ##");
            console.log("############################################################");
        }

        _requireBeacon(e.brandTokenBeacon, e.timelock, "BRAND_TOKEN_BEACON");
        _requireBeacon(e.treasuryBeacon, e.timelock, "TREASURY_BEACON");

        console.log("Preflight: USDG, the SpokePool, the guard, the timelock and both beacons");
        console.log("           check out. The hub address is taken on trust.");
        console.log("");
    }

    /// @dev A beacon with no implementation, or one whose implementation has no code, makes
    ///      every brand registration deploy a proxy to nothing. Ownership is reported, not
    ///      required: whoever owns the beacon owns every brand token, and the operator should
    ///      see that name before broadcasting.
    function _requireBeacon(address beacon, address timelock, string memory label) private view {
        require(beacon.code.length > 0, string.concat(label, " has no code"));
        address impl = UpgradeableBeacon(beacon).implementation();
        require(impl.code.length > 0, string.concat(label, " implementation has no code"));
        address owner = UpgradeableBeacon(beacon).owner();
        console.log(string.concat(label, " implementation:"), impl);
        console.log(string.concat(label, " owner:"), owner);
        if (owner != timelock) {
            console.log(
                string.concat("    WARNING: ", label, " is not owned by TIMELOCK. Proceeding.")
            );
        }
    }

    /// @dev Post-broadcast wiring assertions. Every field here is either immutable or owned by
    ///      the timelock, so a wrong one is a redeploy, not a fix.
    function _assertWiring(SUSDaiYieldSource adapter, SharedReservePool pool, Env memory e)
        private
        view
    {
        require(address(pool.asset()) == MainnetAddresses.USDG, "pool asset is not USDG");
        require(address(pool.yieldSource()) == address(adapter), "pool yield source mismatch");
        require(pool.owner() == e.timelock, "pool owner is not the timelock");
        require(pool.brandTokenBeacon() == e.brandTokenBeacon, "pool brand-token beacon mismatch");
        require(pool.treasuryBeacon() == e.treasuryBeacon, "pool treasury beacon mismatch");
        require(pool.totalPooledSupply() == 0, "fresh pool already has supply");
        require(pool.redemptionFeeBps() == 0, "fresh pool already has a fee (impossible)");

        require(pool.liabilityCap() == 0, "fresh pool liability cap is not zero");
        require(adapter.controller() == address(pool), "adapter controller is not the pool");
        require(address(adapter.usdg()) == MainnetAddresses.USDG, "adapter usdg is not USDG");
        require(adapter.hub() == e.hub, "adapter hub mismatch");
        require(
            adapter.hubChainId() == SUSDaiAddresses.ARBITRUM_CHAIN_ID, "adapter hubChainId mismatch"
        );
        require(adapter.hubUsdc() == SUSDaiAddresses.ARB_USDC, "adapter hubUsdc mismatch");
        require(
            address(adapter.spokePool()) == SUSDaiAddresses.ROBINHOOD_SPOKE_POOL,
            "adapter spokePool mismatch"
        );
        require(address(adapter.guard()) == e.guard, "adapter guard mismatch");
        require(adapter.owner() == e.timelock, "adapter owner is not the timelock");
        require(adapter.keeper() == e.keeper, "adapter keeper mismatch");
        require(adapter.maxBridgeAmount() == 0, "fresh adapter bridge cap is not zero");
        require(adapter.balanceOf(MainnetAddresses.USDG) == 0, "fresh adapter reports a position");

        console.log("");
        console.log("Wiring assertions: PASSED");
    }

    function _printNext(SUSDaiYieldSource adapter, SharedReservePool pool, Env memory e)
        private
        view
    {
        string memory feeCalldata = string.concat(
            "$(cast calldata 'setRedemptionFee(uint16)' ", vm.toString(e.feeBps), ")"
        );
        string memory liabilityCalldata = string.concat(
            "$(cast calldata 'setLiabilityCap(uint256)' ", vm.toString(e.liabilityCap), ")"
        );
        string memory bridgeCalldata = string.concat(
            "$(cast calldata 'setMaxBridgeAmount(uint256)' ", vm.toString(e.bridgeCap), ")"
        );
        string memory zero32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Pool asset:", address(pool.asset()));
        console.log("Pool total assets (should be 0):", pool.totalAssets());
        console.log(
            "Pool redemptionFeeBps (0 until the timelock call executes):", pool.redemptionFeeBps()
        );
        console.log("Adapter minLocalBufferBps (default):", adapter.minLocalBufferBps());
        console.log(
            "Adapter maxRemoteGrowthBpsPerDay (default):", adapter.maxRemoteGrowthBpsPerDay()
        );
        console.log("Adapter maxBridgeFeeBps (default):", adapter.maxBridgeFeeBps());
        console.log("Pool liabilityCap (0 until the timelock call executes):", pool.liabilityCap());
        console.log(
            "Adapter maxBridgeAmount (0 until the timelock call executes):",
            adapter.maxBridgeAmount()
        );
        console.log("");
        console.log("############################################################");
        console.log("## THE KEEPER MUST NOT CALL bridgeOut UNTIL THE FEE AND    ##");
        console.log("## BOTH NONZERO SAFETY CAPS HAVE EXECUTED THROUGH TIMELOCK.##");
        console.log("## A FEE-FREE WINDOW MAKES EVERY MINT/REDEEM ROUND TRIP    ##");
        console.log("## A BRIDGE-AND-SWAP COST THE GROUP EATS.                  ##");
        console.log("############################################################");
        console.log("");
        console.log("NEXT 1: point the hub at this adapter (hub owner key, on Arbitrum):");
        console.log(
            string.concat(
                "    cast send ",
                vm.toString(e.hub),
                " 'setHomeReceiver(address)' ",
                vm.toString(address(adapter)),
                " --rpc-url https://arb1.arbitrum.io/rpc --private-key $PRIVATE_KEY"
            )
        );
        console.log("");
        console.log("NEXT 2: schedule and execute all three safety controls through timelock:");
        _printTimelockCall(
            e.timelock, address(pool), feeCalldata, "redemption fee", "susdai-group-fee-1", zero32
        );
        _printTimelockCall(
            e.timelock,
            address(pool),
            liabilityCalldata,
            "liability cap",
            "susdai-group-liability-cap-1",
            zero32
        );
        _printTimelockCall(
            e.timelock,
            address(adapter),
            bridgeCalldata,
            "adapter bridge cap",
            "susdai-group-bridge-cap-1",
            zero32
        );
        console.log(
            "Confirm redemptionFeeBps, liabilityCap and maxBridgeAmount are all nonzero before starting the keeper."
        );
        console.log("");
        console.log("NEXT 3: keeper service env (services/susdai-keeper/.env.example):");
        console.log("    ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com");
        console.log("    ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc");
        console.log(string.concat("    ADAPTER_ADDRESS=", vm.toString(address(adapter))));
        console.log(string.concat("    HUB_ADDRESS=", vm.toString(e.hub)));
        console.log("    KEEPER_PRIVATE_KEY=<the SUSDAI_KEEPER key>   DRY_RUN=true first");
        console.log("");
        console.log("Brands: `registerBrand` is permissionless, but a brand registered directly");
        console.log("on this pool gets no market - only the factory can give one, and only to a");
        console.log("brand it registered. Approve this reserve on the factory and launch through");
        console.log("createMarket(reservePool: this pool) to get a coin and its market together.");
        console.log("");
        console.log("Record every address above in deployments/ and docs/SUSDAI_COLLATERAL.md.");
    }

    function _printTimelockCall(
        address timelock,
        address target,
        string memory calldata_,
        string memory label,
        string memory saltLabel,
        string memory zero32
    ) private pure {
        string memory salt = string.concat("$(cast keccak '", saltLabel, "')");
        console.log(string.concat("    ", label, " schedule:"));
        console.log(
            string.concat(
                "    cast send ",
                vm.toString(timelock),
                " 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' ",
                vm.toString(target),
                " 0 ",
                calldata_,
                " ",
                zero32,
                " ",
                salt,
                " 172800 --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY"
            )
        );
        console.log(string.concat("    ", label, " execute after 172800 seconds:"));
        console.log(
            string.concat(
                "    cast send ",
                vm.toString(timelock),
                " 'execute(address,uint256,bytes,bytes32,bytes32)' ",
                vm.toString(target),
                " 0 ",
                calldata_,
                " ",
                zero32,
                " ",
                salt,
                " --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY"
            )
        );
    }
}
