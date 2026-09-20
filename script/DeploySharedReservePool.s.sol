// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/governance/TimelockController.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {MorphoBlueYieldSource, IMorphoBlue} from "../src/yield/MorphoBlueYieldSource.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";

/// @title DeploySharedReservePool
/// @notice Step 1 of 2. Deploys the shared reserve on Robinhood Chain mainnet (chain ID 4663).
///         `script/DeployAssetMarkets.s.sol` is step 2 and takes this script's pool address.
///
///         Deployed contracts:
///         1. MorphoBlueYieldSource — a FRESH adapter dedicated to this pool, targeting the
///            top USDG/USDe Morpho Blue market. Must not be either adapter already live on
///            mainnet: both predate the per-consumer share accounting and have an unguarded
///            `withdraw(asset, amount, to)`. Deploying from current source is what closes that
///            blocker, and it is why this script never accepts an existing adapter address.
///            It also must not be shared with DeployMainnet.s.sol's flagship vault stack — the
///            adapter attributes Morpho shares per calling consumer, but two consumers sharing
///            one instance still share one Morpho position's liquidity.
///         2. TimelockController — upgrade authority for the pool's yield source. The deployer
///            EOA is sole proposer and executor; admin is `address(0)` so only the timelock
///            itself can change its own roles later.
///         3. SharedReservePool — the shared reserve itself, owned by that timelock.
///
///         This is deliberately independent of DeployMainnet.s.sol's vault/beacon/factory
///         stack: `SharedReservePool` is the reserve the market layer is built on, and
///         nothing else in this repo depends on it.
///
///         NOT done here, deliberately: registering any brand. `registerBrand` is
///         permissionless and brand-specific (name, symbol, admin), and no pre-existing brand
///         can ever be attached to a market — `AssetMarketFactory.createMarket` deploys the
///         market's own unit from the owner's asset approval. Register brands through the
///         factory, after step 2, and only for brands that will never have a market.
///
///         Usage:
///         forge script script/PreflightMainnet.s.sol --rpc-url robinhood
///         TIMELOCK_MIN_DELAY=172800 forge script \
///           script/DeploySharedReservePool.s.sol --rpc-url robinhood --broadcast --slow
///
///         Environment variables:
///         - PRIVATE_KEY         deployer key (required)
///         - TIMELOCK_MIN_DELAY  required. Seconds between scheduling and executing an owner
///                               action such as `setYieldSource`. ZERO deploys no timelock at
///                               all and leaves the deployer EOA owning the stack, so every
///                               upgrade is a single immediate transaction.
contract DeploySharedReservePool is Script {
    /// @notice The delay the script suggests when a timelock is requested. Nothing enforces
    ///         it — `TIMELOCK_MIN_DELAY` is taken as given. See `run`.
    uint256 constant SUGGESTED_MIN_DELAY = 48 hours;

    function run() external returns (MorphoBlueYieldSource, TimelockController, SharedReservePool) {
        // The testnet is 46630 and mainnet is 4663. Without this guard a mistyped `--rpc-url`
        // deploys a stack that looks right, holds the mainnet constants, and is on the wrong
        // chain. The testnet scripts have always had this guard; the mainnet ones did not.
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        // The fast halt key. Defaults to the deployer, which is fine for a rehearsal and is the
        // first thing to change for a real launch — see `ProtocolGuard`.
        address guardian = vm.envOr("PROTOCOL_GUARDIAN", vm.addr(deployerKey));
        address deployer = vm.addr(deployerKey);

        // Deliberately NOT defaulted: the number is chosen, not inherited. Zero is a real
        // choice and means what it says — NO timelock is deployed at all, and the deployer
        // EOA owns the guard, the beacons, the adapter and the pool directly, so an upgrade
        // is one transaction with no waiting. A zero-delay TimelockController would be the
        // same authority wearing a costume: the same key schedules and executes in the same
        // block, while everything reading the chain sees governance that does not exist.
        // Anything non-zero deploys the timelock and gives it everything, as before.
        uint256 timelockMinDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        bool useTimelock = timelockMinDelay > 0;

        console.log("=== Deploying SharedReservePool to Robinhood Chain mainnet ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Chain ID:", block.chainid);
        console.log("");

        _preflight();

        console.log("Timelock delay (s):", timelockMinDelay);
        if (!useTimelock) {
            console.log("");
            console.log("############################################################");
            console.log("## WARNING: NO timelock. The deployer EOA owns the guard,  ##");
            console.log("## the beacons, the adapter and the pool, and can upgrade  ##");
            console.log("## or re-point any of them in a single transaction. That   ##");
            console.log("## is the point of this mode - upgrades are instant - but  ##");
            console.log("## it also means a leaked key rewrites every brand token,  ##");
            console.log("## treasury, fee vault and reward distributor with nobody  ##");
            console.log("## able to react.                                          ##");
            console.log("## This is the Phase 0 blocker in ASSET_MARKETS.md sec 11. ##");
            console.log("############################################################");
            console.log("");
        } else if (timelockMinDelay < SUGGESTED_MIN_DELAY) {
            console.log("");
            console.log("############################################################");
            console.log("## WARNING: timelock delay is below the suggested 172800s  ##");
            console.log("## (48h). The pool's owner can swap its yield source, and  ##");
            console.log("## the reserve moves with it. Below a real delay nobody    ##");
            console.log("## watching the chain has time to react. Proceeding as     ##");
            console.log("## instructed.                                             ##");
            console.log("############################################################");
            console.log("");
        }

        vm.startBroadcast(deployerKey);

        // 1. The timelock, if one was asked for. Everything below is owned by whatever comes
        //    out of this step, so it has to exist first. At zero delay nothing is deployed and
        //    the deployer owns the stack directly.
        TimelockController timelock;
        if (useTimelock) {
            address[] memory proposers = new address[](1);
            proposers[0] = deployer;
            address[] memory executors = new address[](1);
            executors[0] = deployer;
            timelock = new TimelockController(timelockMinDelay, proposers, executors, address(0));
            console.log("TimelockController (owns every proxy and beacon):", address(timelock));
        } else {
            console.log("TimelockController: none - the deployer owns every proxy and beacon");
        }
        address authority = useTimelock ? address(timelock) : deployer;

        // 2. The pause registry. Deployed here rather than in step 2 because the reserve is
        //    initialised with its address, and step 2 reads it back off the reserve.
        ProtocolGuard guard = ProtocolStack.deployGuard(authority, guardian);
        console.log("ProtocolGuard:", address(guard));
        console.log("    guardian (may halt, nothing else):", guardian);

        // 3. The four beacons the reserve and the market layer deploy from. Owned by the
        //    upgrade authority from the moment they exist, so where a timelock is in use the
        //    deploying key never holds upgrade authority over a live brand even briefly.
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(authority);
        console.log("PooledBrandToken beacon:", address(beacons.brandToken));
        console.log("PoolBrandTreasury beacon:", address(beacons.treasury));
        console.log("BrandFeeVault beacon:", address(beacons.vault));
        console.log("LpRewardDistributor beacon:", address(beacons.distributor));

        // 4. The yield adapter, behind its own proxy.
        MorphoBlueYieldSource yieldSource = ProtocolStack.deployYieldSource(
            MainnetAddresses.MORPHO_BLUE, MainnetAddresses.USDE_MARKET_ID, authority
        );
        console.log("MorphoBlueYieldSource (USDe, dedicated to the pool):", address(yieldSource));

        // 5. The pool itself, owned by the upgrade authority.
        SharedReservePool pool = ProtocolStack.deployReservePool(
            MainnetAddresses.USDG, address(yieldSource), authority, beacons, address(guard)
        );
        console.log("SharedReservePool:", address(pool));

        vm.stopBroadcast();

        _assertWiring(yieldSource, authority, timelockMinDelay, pool, guard, beacons);

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Pool asset:", address(pool.asset()));
        console.log("Pool asset decimals:", pool.assetDecimals());
        console.log("Pool total assets (should be 0 - nothing minted yet):", pool.totalAssets());
        console.log("Pool owner (upgrade authority):", pool.owner());
        console.log("Effective timelock delay (s):", useTimelock ? timelock.getMinDelay() : 0);
        console.log("");
        console.log("NEXT: step 2 takes this pool address.");
        console.log("    SHARED_RESERVE_POOL=<pool> forge script \\");
        console.log("      script/DeployAssetMarkets.s.sol --rpc-url robinhood --broadcast");
        console.log("");
        console.log("Record the addresses in deployments/asset-markets-mainnet.json before");
        console.log("anything reads them. See docs/ASSET_MARKETS_MAINNET.md.");
        console.log("");
        if (useTimelock) {
            console.log("Raising the timelock delay later (schedule, wait out the CURRENT delay,");
            console.log("then execute against the timelock itself):");
            console.log(
                "    cast send <timelock> 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \\"
            );
            console.log(
                "      <timelock> 0 $(cast calldata 'updateDelay(uint256)' 172800) 0x0 <salt> <currentDelay>"
            );
        } else {
            console.log("Upgrades are one transaction from the deployer, e.g.");
            console.log("    cast send <proxy> 'upgradeToAndCall(address,bytes)' <impl> 0x");
            console.log("Adopting a timelock later costs nothing but the transfers: deploy one,");
            console.log("then transferOwnership on the pool, adapter, guard and every beacon.");
        }

        return (yieldSource, timelock, pool);
    }

    /// @dev The same constant checks `PreflightMainnet` makes, repeated in the broadcasting
    ///      script so the deployment cannot proceed on stale constants even if nobody ran the
    ///      preflight. These are pure reads and cost nothing but simulation time.
    function _preflight() private view {
        require(MainnetAddresses.USDG.code.length > 0, "USDG has no code");
        require(MainnetAddresses.MORPHO_BLUE.code.length > 0, "Morpho Blue has no code");
        require(
            IERC20Metadata(MainnetAddresses.USDG).decimals() == MainnetAddresses.USDG_DECIMALS,
            "USDG decimals changed"
        );

        IMorphoBlue.MarketParams memory p = IMorphoBlue(MainnetAddresses.MORPHO_BLUE)
            .idToMarketParams(MainnetAddresses.USDE_MARKET_ID);
        require(p.loanToken == MainnetAddresses.USDG, "Morpho market's loan token is not USDG");
        require(p.irm != address(0), "Morpho market id was never created");

        console.log("Preflight: USDG and the Morpho USDG/USDe market check out.");
    }

    /// @dev Post-broadcast wiring assertions. A constructor argument in the wrong position
    ///      produces a stack that deploys cleanly and is wrong, and ownership is the one field
    ///      nobody can fix afterwards without already holding the authority it should be.
    function _assertWiring(
        MorphoBlueYieldSource yieldSource,
        address authority,
        uint256 expectedDelay,
        SharedReservePool pool,
        ProtocolGuard guard,
        ProtocolStack.Beacons memory beacons
    ) private view {
        require(address(pool.asset()) == MainnetAddresses.USDG, "pool asset is not USDG");
        require(address(pool.yieldSource()) == address(yieldSource), "pool yield source mismatch");

        // Every owner, not just the pool's. The pool being correctly owned says nothing about
        // the beacons, and a beacon whose owner is the deploying key rather than the timelock is
        // an instant rewrite of every brand token or market contract deployed from it — the one
        // thing this branch's timelock exists to prevent, and undetectable from the pool alone.
        require(pool.owner() == authority, "pool owner is not the upgrade authority");
        require(guard.owner() == authority, "guard owner is not the upgrade authority");
        require(yieldSource.owner() == authority, "adapter owner is not the upgrade authority");
        require(
            beacons.brandToken.owner() == authority, "brand token beacon owner is not the authority"
        );
        require(beacons.treasury.owner() == authority, "treasury beacon owner is not the authority");
        require(beacons.vault.owner() == authority, "vault beacon owner is not the authority");
        require(
            beacons.distributor.owner() == authority,
            "distributor beacon owner is not the authority"
        );

        require(pool.totalPooledSupply() == 0, "fresh pool already has supply");
        if (expectedDelay > 0) {
            require(
                TimelockController(payable(authority)).getMinDelay() == expectedDelay,
                "timelock delay mismatch"
            );
        } else {
            require(authority.code.length == 0, "zero delay should leave an EOA in charge");
        }

        require(
            address(yieldSource.morphoBlue()) == MainnetAddresses.MORPHO_BLUE,
            "adapter points at the wrong Morpho"
        );
        require(
            yieldSource.marketId() == MainnetAddresses.USDE_MARKET_ID, "adapter market id mismatch"
        );
        require(yieldSource.loanToken() == MainnetAddresses.USDG, "adapter loan token is not USDG");
        // The fix that makes this adapter safe to use at all: per-consumer share accounting.
        // A fresh adapter must credit nobody.
        require(yieldSource.sharesOf(address(pool)) == 0, "fresh adapter already credits the pool");

        console.log("");
        console.log("Wiring assertions: PASSED");
    }
}
