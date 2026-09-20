// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SUSDaiHub} from "../src/susdai/SUSDaiHub.sol";
import {
    SUSDaiTestnetCurve,
    SUSDaiTestnetShares,
    SUSDaiTestnetToken
} from "../src/testnet/SUSDaiTestnetMocks.sol";

/// @notice Deploys mocked USDai, sUSDai, and Curve on Arbitrum Sepolia while retaining the real
///         Circle USDC and Across SpokePool legs used by the cross-chain application.
contract DeployArbitrumSepoliaSUSDaiMock is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant HOME_CHAIN_ID = 84532;
    address internal constant HOME_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant ARBITRUM_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address internal constant ARBITRUM_SPOKE_POOL = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;

    uint256 internal constant DEFAULT_BRIDGE_CAP = 5_000e6;
    uint256 internal constant DEFAULT_CURVE_USDC_SEED = 5e6;

    function run()
        external
        returns (
            SUSDaiHub hub,
            SUSDaiTestnetToken usdai,
            SUSDaiTestnetShares shares,
            SUSDaiTestnetCurve curve
        )
    {
        require(block.chainid == ARBITRUM_SEPOLIA, "Arbitrum Sepolia only");
        address deployer = vm.envAddress("SUSDAI_DEPLOYER");
        address keeper = vm.envOr("SUSDAI_KEEPER", deployer);
        uint256 bridgeCap = vm.envOr("TESTNET_BRIDGE_CAP", DEFAULT_BRIDGE_CAP);
        uint256 curveUsdcSeed = vm.envOr("CURVE_USDC_SEED", DEFAULT_CURVE_USDC_SEED);

        require(deployer != address(0) && keeper != address(0), "authority is zero");
        require(bridgeCap > 0 && curveUsdcSeed > 0, "testnet amount is zero");
        require(IERC20Metadata(ARBITRUM_USDC).decimals() == 6, "Arbitrum USDC mismatch");
        require(ARBITRUM_SPOKE_POOL.code.length > 0, "Arbitrum SpokePool missing");
        require(
            IERC20(ARBITRUM_USDC).balanceOf(deployer) >= curveUsdcSeed,
            "deployer lacks Curve seed USDC"
        );

        vm.startBroadcast(deployer);
        usdai = new SUSDaiTestnetToken("Test USDai", "tUSDai", 18);
        shares = new SUSDaiTestnetShares(address(usdai));
        curve = new SUSDaiTestnetCurve(address(shares), ARBITRUM_USDC, 1.1e18, 1);
        hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiHub()),
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            ARBITRUM_USDC,
                            address(shares),
                            address(curve),
                            ARBITRUM_SPOKE_POOL,
                            HOME_CHAIN_ID,
                            HOME_USDC,
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        hub.setMaxBridgeAmount(bridgeCap);
        IERC20(ARBITRUM_USDC).safeTransfer(address(curve), curveUsdcSeed);
        shares.mint(address(curve), 5_000_000e18);
        vm.stopBroadcast();

        require(hub.owner() == deployer && hub.keeper() == keeper, "hub authority mismatch");
        require(hub.homeReceiver() == address(0), "home receiver unexpectedly set");
        require(hub.homeChainId() == HOME_CHAIN_ID, "home chain mismatch");
        require(hub.homeUsdg() == HOME_USDC, "home token mismatch");
        require(address(hub.usdc()) == ARBITRUM_USDC, "hub USDC mismatch");
        require(address(hub.spokePool()) == ARBITRUM_SPOKE_POOL, "hub SpokePool mismatch");
        require(hub.maxBridgeAmount() == bridgeCap, "hub bridge cap mismatch");
        require(
            curve.coins(0) == address(shares) && curve.coins(1) == ARBITRUM_USDC,
            "curve wiring mismatch"
        );

        console.log("Arbitrum Sepolia Circle USDC:", ARBITRUM_USDC);
        console.log("Arbitrum Sepolia test USDai:", address(usdai));
        console.log("Arbitrum Sepolia test sUSDai:", address(shares));
        console.log("Arbitrum Sepolia test Curve:", address(curve));
        console.log("Arbitrum Sepolia Across SpokePool:", ARBITRUM_SPOKE_POOL);
        console.log("Arbitrum Sepolia SUSDaiHub:", address(hub));
        console.log("NEXT: deploy DeployBaseSepoliaPlatform with REMOTE_HUB above.");
    }
}
