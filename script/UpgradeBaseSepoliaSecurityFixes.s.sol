// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";
import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";

/// @notice Ships the 2026-09-15 audit fixes to the live Base Sepolia / Arbitrum Sepolia
///         deployment, in place, through the UUPS proxies.
///
///         **Why the setters are not optional.** Every new tunable is defaulted inside
///         `initialize`, which a proxy already past initialization never runs again. On a
///         live proxy each one therefore reads zero after the upgrade, and zero is the
///         fail-closed value for all of them: a zero swap or bridge budget refuses every
///         keeper action, and a zero `minSharePriceWad` makes every price read revert. So the
///         upgrade and the configuration are one script — an upgrade without the setters
///         leaves a halted deployment, which is safe but dead.
///
///         Run `remote()` on Arbitrum Sepolia and `home()` on Base Sepolia. Order does not
///         matter: the keeper is expected to be stopped while this runs, and each side is
///         self-consistent when its own leg completes.
contract UpgradeBaseSepoliaSecurityFixes is Script {
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant ARBITRUM_SEPOLIA = 421614;

    address constant ADAPTER = 0xbBBe0C698Ea2F81c7433680df7a24e9a262854d5;
    address constant MARKET_RESERVE = 0x70F1e355c7e6501471C824194899E6Be79ABc959;
    address constant SUSDAI_RESERVE = 0xecF46dC819Ef7523b842852B1026a5622889FB11;
    address constant REGISTRY = 0x8E3135321A4bA61D9280FfFAf2dd7553e1099C29;
    address constant HUB = 0x9050dF2f672dEb3Cf4900349005ecd11b2497654;

    /// @dev The band sUSDai's NAV must stay inside. Measured live at 1.112/1.107; the fixture
    ///      sits at 1.100/1.095. The floor admits a genuine credit drawdown and refuses the
    ///      dust an attacker needs to make an honest keeper sell the position for nothing.
    uint128 constant MIN_SHARE_PRICE_WAD = 0.9e18;
    uint128 constant MAX_SHARE_PRICE_WAD = 10e18;

    /// @dev Half the pool's liability cap per day: orders of magnitude above the keeper's real
    ///      duty cycle (a few hundred USDC of buffer rebalancing) and far below "the whole
    ///      position in one block", which is what the unbudgeted contracts allowed.
    uint256 constant BUDGET_PER_WINDOW = 50_000e6;
    uint64 constant BUDGET_WINDOW = 1 days;

    /// @dev A floor in tokens, not in a percentage of a figure the keeper writes. Sized to the
    ///      current position's 10% bps floor so it binds rather than decorates.
    uint256 constant MIN_LOCAL_BUFFER_ABSOLUTE = 1_000_000;

    /// @dev Headroom the growth cap keeps even when `remoteValue` is zero, so a zeroed value
    ///      is no longer an absorbing state the owner can only leave by upgrading.
    uint256 constant REMOTE_GROWTH_ABSOLUTE_PER_DAY = 10e6;

    function remote() external {
        require(block.chainid == ARBITRUM_SEPOLIA, "not Arbitrum Sepolia (421614)");
        uint256 key = vm.envUint("PRIVATE_KEY");

        SUSDaiHub hub = SUSDaiHub(HUB);
        uint256 sharesBefore = hub.sharesHeld();
        address receiverBefore = hub.homeReceiver();
        address keeperBefore = hub.keeper();

        vm.startBroadcast(key);
        SUSDaiHub implementation = new SUSDaiHub();
        hub.upgradeToAndCall(address(implementation), "");
        hub.setSharePriceBand(MIN_SHARE_PRICE_WAD, MAX_SHARE_PRICE_WAD);
        hub.setSwapBudget(BUDGET_PER_WINDOW, BUDGET_WINDOW);
        // The audited slippage default was 50 bps against a measured ~2 bps round trip; every
        // unused basis point is extractable by a keeper that pre-trades the Curve pool.
        hub.setLimits(15, hub.maxBridgeFeeBps());
        vm.stopBroadcast();

        require(hub.sharesHeld() == sharesBefore, "hub shares moved during the upgrade");
        require(hub.homeReceiver() == receiverBefore, "hub homeReceiver moved");
        require(hub.keeper() == keeperBefore, "hub keeper moved");
        require(hub.minSharePriceWad() == MIN_SHARE_PRICE_WAD, "share price band not set");
        require(hub.swapBudgetRemaining() > 0, "swap budget still fails closed");
        require(hub.maxSwapSlippageBps() == 15, "slippage bound not tightened");

        console.log("SUSDaiHub implementation:", address(implementation));
        console.log("    shares preserved:", hub.sharesHeld());
        console.log("    swap budget remaining:", hub.swapBudgetRemaining());
    }

    function home() external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia (84532)");
        uint256 key = vm.envUint("PRIVATE_KEY");

        SUSDaiYieldSource adapter = SUSDaiYieldSource(ADAPTER);
        uint256 bufferBefore = adapter.availableLiquidity();
        uint256 remoteBefore = adapter.remoteValue();
        address controllerBefore = adapter.controller();
        uint256 susdaiAssetsBefore = SharedReservePool(SUSDAI_RESERVE).totalAssets();
        uint256 susdaiSupplyBefore = SharedReservePool(SUSDAI_RESERVE).totalPooledSupply();
        uint256 marketAssetsBefore = SharedReservePool(MARKET_RESERVE).totalAssets();
        uint256 groupsBefore = StrategyGroupRegistry(REGISTRY).groupCount();

        vm.startBroadcast(key);
        SUSDaiYieldSource adapterImpl = new SUSDaiYieldSource();
        adapter.upgradeToAndCall(address(adapterImpl), "");
        adapter.setBridgeBudget(BUDGET_PER_WINDOW, BUDGET_WINDOW);
        adapter.setMinLocalBufferAbsolute(MIN_LOCAL_BUFFER_ABSOLUTE);
        adapter.setMaxRemoteGrowthAbsolutePerDay(REMOTE_GROWTH_ABSOLUTE_PER_DAY);

        SharedReservePool poolImpl = new SharedReservePool();
        SharedReservePool(SUSDAI_RESERVE).upgradeToAndCall(address(poolImpl), "");
        SharedReservePool(MARKET_RESERVE).upgradeToAndCall(address(poolImpl), "");

        StrategyGroupRegistry registryImpl = new StrategyGroupRegistry();
        StrategyGroupRegistry(REGISTRY).upgradeToAndCall(address(registryImpl), "");
        vm.stopBroadcast();

        // `localAtLastSettlement` is a new slot and reads zero on this proxy, so `_position()`
        // would treat the entire buffer as an unexplained arrival and net it off the in-flight
        // counters. Both counters are zero here, so nothing can be netted and the position is
        // unaffected — asserted rather than assumed, because it is the one place this upgrade
        // could silently move the reserve's reported size.
        require(adapter.outboundInFlight() == 0, "an outbound leg is in flight");
        require(adapter.inboundInFlight() == 0, "an inbound leg is in flight");
        require(adapter.availableLiquidity() == bufferBefore, "buffer moved during the upgrade");
        require(adapter.remoteValue() == remoteBefore, "remoteValue moved during the upgrade");
        require(adapter.controller() == controllerBefore, "controller binding moved");
        require(adapter.bridgeBudgetRemaining() > 0, "bridge budget still fails closed");
        require(
            SharedReservePool(SUSDAI_RESERVE).totalAssets() == susdaiAssetsBefore
                && SharedReservePool(SUSDAI_RESERVE).totalPooledSupply() == susdaiSupplyBefore,
            "sUSDai reserve moved during the upgrade"
        );
        require(
            SharedReservePool(MARKET_RESERVE).totalAssets() == marketAssetsBefore,
            "market reserve moved during the upgrade"
        );
        require(StrategyGroupRegistry(REGISTRY).groupCount() == groupsBefore, "groups lost");

        console.log("SUSDaiYieldSource implementation:", address(adapterImpl));
        console.log("SharedReservePool implementation (both pools):", address(poolImpl));
        console.log("StrategyGroupRegistry implementation:", address(registryImpl));
        console.log("    buffer preserved:", adapter.availableLiquidity());
        console.log("    remoteValue preserved:", adapter.remoteValue());
        console.log("    bridge budget remaining:", adapter.bridgeBudgetRemaining());
    }
}
