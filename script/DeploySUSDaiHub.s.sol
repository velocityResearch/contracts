// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";
import {IAcrossSpokePool} from "../src/interfaces/IAcrossSpokePool.sol";
import {ICurveStableSwapNG} from "../src/interfaces/ICurveStableSwapNG.sol";
import {IStakedUSDai} from "../src/interfaces/IStakedUSDai.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {SUSDaiAddresses} from "./SUSDaiAddresses.sol";

/// @title DeploySUSDaiHub
/// @notice Step 1 of 2 for the sUSDai-backed reserve. Deploys `SUSDaiHub` on Arbitrum One
///         (chain ID 42161). `script/DeploySUSDaiGroup.s.sol` is step 2, runs on Robinhood
///         Chain, and takes this script's hub address as `SUSDAI_HUB`.
///
///         The hub goes first because the adapter's constructor needs the hub address (it is
///         the only recipient `bridgeOut` may name) while the hub's `homeReceiver` is settable
///         after the fact. So: deploy the hub, deploy the adapter against it, then point the
///         hub back at the adapter with `setHomeReceiver`. Until that last call `bridgeHome`
///         would deliver to `address(0)`, and Across would refund it — nothing can be lost, but
///         nothing can come home either.
///
///         The hub is a plain contract, not a proxy: it holds sUSDai and USDC, nothing else, and
///         a replacement is "sell, bridge home, deploy another, point the adapter at it".
///
///         Usage:
///         PRIVATE_KEY=0x... forge script script/DeploySUSDaiHub.s.sol --rpc-url https://arb1.arbitrum.io/rpc
///         PRIVATE_KEY=0x... forge script script/DeploySUSDaiHub.s.sol --rpc-url https://arb1.arbitrum.io/rpc --broadcast --slow
///
///         Environment variables:
///         - PRIVATE_KEY    deployer key (required). Pays for the deploy in Arbitrum ETH.
///         - HUB_OWNER      `Ownable2Step` owner: sets keeper, limits, homeReceiver, pause
///                          (default: the deployer). The Robinhood timelock cannot own this —
///                          it is on another chain — so this is a hot key or a multisig.
///         - SUSDAI_KEEPER  the key that drives buyShares/sellShares/bridgeHome (default: the
///                          deployer). Must be the SAME key `DeploySUSDaiGroup` is given, or
///                          the keeper service needs two keys.
///         - HUB_MAX_BRIDGE_AMOUNT measured per-deposit USDC cap to set after deploy (required).
contract DeploySUSDaiHub is Script {
    function run() external returns (SUSDaiHub) {
        // Arbitrum One is 42161; Arbitrum Nova is 42170, Sepolia is 421614. A wrong `--rpc-url`
        // here would deploy a hub whose Curve and sUSDai constants point at nothing.
        require(block.chainid == SUSDaiAddresses.ARBITRUM_CHAIN_ID, "not Arbitrum One (42161)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("HUB_OWNER", deployer);
        address keeper = vm.envOr("SUSDAI_KEEPER", deployer);
        uint256 bridgeCap = vm.envUint("HUB_MAX_BRIDGE_AMOUNT");
        require(bridgeCap > 0, "HUB_MAX_BRIDGE_AMOUNT is zero");

        console.log("=== Deploying SUSDaiHub to Arbitrum One ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Chain ID:", block.chainid);
        console.log("Owner:", owner);
        console.log("Keeper:", keeper);
        console.log("");

        _preflight();

        vm.startBroadcast(deployerKey);
        // Implementation plus its own ERC1967 proxy. The hub custodies the reserve's collateral
        // on this chain, so it is upgradeable like the rest of the fund-holding contracts: the
        // owner below is what authorizes an upgrade, and `initialize` runs inside the proxy's
        // constructor so the hub is wired in the same transaction it is created in.
        address hubImpl = address(new SUSDaiHub());
        SUSDaiHub hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    hubImpl,
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            SUSDaiAddresses.ARB_USDC,
                            SUSDaiAddresses.SUSDAI,
                            SUSDaiAddresses.CURVE_SUSDAI_USDC,
                            SUSDaiAddresses.ARB_SPOKE_POOL,
                            MainnetAddresses.CHAIN_ID,
                            MainnetAddresses.USDG,
                            owner,
                            keeper
                        )
                    )
                )
            )
        );
        vm.stopBroadcast();
        console.log("SUSDaiHub implementation:", hubImpl);
        console.log("SUSDaiHub:", address(hub));

        _assertWiring(hub, owner, keeper);

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("maxSwapSlippageBps (default):", hub.maxSwapSlippageBps());
        console.log("maxBridgeFeeBps (default):", hub.maxBridgeFeeBps());
        console.log("maxBridgeAmount (fail-closed default):", hub.maxBridgeAmount());
        console.log("homeReceiver (unset until step 2 reports the adapter):", hub.homeReceiver());
        console.log("");
        console.log(
            "NEXT: step 2 deploys the adapter and pool on Robinhood Chain against this hub."
        );
        console.log(
            "    SUSDAI_HUB=<hub> SUSDAI_KEEPER=<keeper> TIMELOCK=0x5f43E1e732c7aBdbbC73F9d1367320D9040C872a PROTOCOL_GUARD=0x88eeA21D246DF8aa4Ca071532cB06d4f66D45f65 BRAND_TOKEN_BEACON=0xc7433cD04Ce4B5b326602EFeD3bBA68d29aC4Bde TREASURY_BEACON=0x8AB0789D62a06546bfF51Be28ecaC696eb817897 forge script script/DeploySUSDaiGroup.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast --slow"
        );
        console.log("");
        console.log("THEN point this hub at the adapter step 2 prints (owner key, on Arbitrum):");
        console.log(
            "    cast send <hub> 'setHomeReceiver(address)' <adapter> --rpc-url https://arb1.arbitrum.io/rpc --private-key $PRIVATE_KEY"
        );
        console.log("THEN set the measured nonzero bridge cap with the hub owner:");
        console.log(
            string.concat(
                "    cast send ",
                vm.toString(address(hub)),
                " 'setMaxBridgeAmount(uint256)' ",
                vm.toString(bridgeCap),
                " --rpc-url https://arb1.arbitrum.io/rpc --private-key $PRIVATE_KEY"
            )
        );
        console.log("");
        console.log("");
        console.log("Keeper service env (services/susdai-keeper/.env.example):");
        console.log("    ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc");
        console.log("    ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com");
        console.log(string.concat("    HUB_ADDRESS=", vm.toString(address(hub))));
        console.log("    ADAPTER_ADDRESS=<adapter from step 2>");
        console.log("    KEEPER_PRIVATE_KEY=<the SUSDAI_KEEPER key>   DRY_RUN=true first");
        console.log("");
        console.log("Record the hub in deployments/ and docs/SUSDAI_COLLATERAL.md before step 2.");

        return hub;
    }

    /// @dev Re-reads every Arbitrum constant `initialize` will write into the proxy. The hub
    ///      checks the Curve coin order and decimals, but a check that fails inside a deploy
    ///      transaction costs gas and leaves a revert to decode; these are free `eth_call`s.
    function _preflight() private view {
        require(SUSDaiAddresses.ARB_USDC.code.length > 0, "USDC has no code");
        require(SUSDaiAddresses.SUSDAI.code.length > 0, "sUSDai has no code");
        require(SUSDaiAddresses.CURVE_SUSDAI_USDC.code.length > 0, "Curve pool has no code");
        require(SUSDaiAddresses.ARB_SPOKE_POOL.code.length > 0, "SpokePool has no code");

        ICurveStableSwapNG curve = ICurveStableSwapNG(SUSDaiAddresses.CURVE_SUSDAI_USDC);
        require(curve.N_COINS() == 2, "Curve pool is not a 2-coin pool");
        require(curve.coins(0) == SUSDaiAddresses.SUSDAI, "Curve coins(0) is not sUSDai");
        require(curve.coins(1) == SUSDaiAddresses.ARB_USDC, "Curve coins(1) is not USDC");

        // `IAcrossSpokePool` carries no `chainId()`; the buffers are what the keeper's quotes
        // are validated against, so they are the values worth pinning.
        IAcrossSpokePool spoke = IAcrossSpokePool(SUSDaiAddresses.ARB_SPOKE_POOL);
        require(
            spoke.depositQuoteTimeBuffer() == SUSDaiAddresses.SPOKE_QUOTE_TIME_BUFFER,
            "SpokePool depositQuoteTimeBuffer changed"
        );
        require(
            spoke.fillDeadlineBuffer() == SUSDaiAddresses.SPOKE_FILL_DEADLINE_BUFFER,
            "SpokePool fillDeadlineBuffer changed"
        );

        require(
            IStakedUSDai(SUSDaiAddresses.SUSDAI).asset() == SUSDaiAddresses.USDAI,
            "sUSDai asset is not USDai"
        );

        console.log("Preflight: USDC, sUSDai, Curve sUSDai/USDC and the SpokePool check out.");
        console.log(
            "    sUSDai depositSharePrice:",
            IStakedUSDai(SUSDaiAddresses.SUSDAI).depositSharePrice()
        );
        console.log(
            "    sUSDai redemptionSharePrice:",
            IStakedUSDai(SUSDaiAddresses.SUSDAI).redemptionSharePrice()
        );
        console.log("    Curve get_dy(USDC->sUSDai, 10_000e6):", curve.get_dy(1, 0, 10_000e6));
        console.log("");
    }

    /// @dev An `initialize` argument in the wrong slot deploys cleanly and trades the wrong way.
    function _assertWiring(SUSDaiHub hub, address owner, address keeper) private view {
        require(address(hub.usdc()) == SUSDaiAddresses.ARB_USDC, "hub usdc mismatch");
        require(address(hub.susdai()) == SUSDaiAddresses.SUSDAI, "hub susdai mismatch");
        require(address(hub.curve()) == SUSDaiAddresses.CURVE_SUSDAI_USDC, "hub curve mismatch");
        require(
            address(hub.spokePool()) == SUSDaiAddresses.ARB_SPOKE_POOL, "hub spokePool mismatch"
        );
        require(hub.sharesIndex() == 0, "hub sharesIndex is not 0");
        require(hub.usdcIndex() == 1, "hub usdcIndex is not 1");
        require(hub.homeChainId() == MainnetAddresses.CHAIN_ID, "hub homeChainId is not 4663");
        require(hub.homeUsdg() == MainnetAddresses.USDG, "hub homeUsdg is not USDG");
        require(hub.keeper() == keeper, "hub keeper mismatch");
        require(hub.owner() == owner, "hub owner mismatch");
        require(hub.homeReceiver() == address(0), "fresh hub already has a homeReceiver");
        require(hub.maxBridgeAmount() == 0, "fresh hub bridge cap is not zero");
        require(hub.sharesHeld() == 0 && hub.usdcHeld() == 0, "fresh hub already holds funds");

        console.log("");
        console.log("Wiring assertions: PASSED");
    }
}
