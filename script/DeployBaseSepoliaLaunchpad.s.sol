// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {LiquidityZapper} from "../src/markets/LiquidityZapper.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchRouter} from "../src/launchpad/LaunchRouter.sol";
import {LaunchpadDefaults} from "./DeployLaunchpad.s.sol";
import {HookSaltMiner} from "./DeployAssetMarkets.s.sol";
import {AssetMarketTestYieldSource} from "./DeployAssetMarketsTestnet.s.sol";

/// @notice A faucet equity used only to make the Base Sepolia market path executable.
///         Six decimals to match the reserve asset.
contract FaucetAsset is ERC20 {
    constructor() ERC20("Base Sepolia Faucet USDC", "faucetUSDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Deploys a complete Base Sepolia stack — market factory, router, reserve, hook,
///         zapper, and the full launchpad — from the current branch in one broadcast.
///
///         This is a clean deploy: every address is new, because the current branch's
///         `AssetMarketFactory` adds a `positionManager` storage field at slot 3, which
///         collides with the deployed factory's `beacons`. Upgrading in place would read the
///         old beacons value as `positionManager`, so a fresh proxy is the only safe path on
///         testnet.
///
///         Usage:
///         PRIVATE_KEY=0x... DEPLOYER=0x... forge script script/DeployBaseSepoliaLaunchpad.s.sol \
///             --rpc-url https://sepolia.base.org --broadcast --slow
contract DeployBaseSepoliaLaunchpad is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant V4_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant V4_POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant DEFAULT_LIABILITY_CAP = 100_000e6;
    uint32 internal constant REWARDS_DURATION = 7 days;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 62;

    struct Deployment {
        FaucetAsset asset;
        AssetMarketTestYieldSource yieldSource;
        ProtocolGuard guard;
        ProtocolStack.Beacons beacons;
        ProtocolFeeHook feeHook;
        SharedReservePool reserve;
        AssetMarketFactory factory;
        MarketRouter router;
        LiquidityZapper zapper;
        address quoteBrand;
        LaunchFactory launchFactory;
        LaunchRouter launchRouter;
        address launchFeeEscrow;
        address launchLocker;
        address launchDeployer;
        address launchGraduation;
        address launchGraduationGuard;
    }

    function run() external returns (Deployment memory d) {
        require(block.chainid == BASE_SEPOLIA, "Base Sepolia only");
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "DEPLOYER is zero");

        require(IERC20Metadata(BASE_USDC).decimals() == 6, "Base USDC decimals mismatch");
        require(V4_POOL_MANAGER.code.length > 0, "Base PoolManager missing");
        require(V4_POSITION_MANAGER.code.length > 0, "Base PositionManager missing");
        require(PERMIT2.code.length > 0, "Base Permit2 missing");

        console.log("=== Deploying fresh Base Sepolia stack with launchpad ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);

        vm.startBroadcast(deployer);

        // ─── Market stack ───────────────────────────────────────────────
        d.asset = new FaucetAsset();
        d.yieldSource = new AssetMarketTestYieldSource();

        IPoolManager poolManager = IPoolManager(V4_POOL_MANAGER);
        d.guard = ProtocolStack.deployGuard(deployer, deployer);
        d.beacons = ProtocolStack.deployBeacons(deployer);

        address hookImpl = ProtocolStack.deployHookImplementation();
        bytes memory hookInitCode =
            ProtocolStack.hookProxyInitCode(hookImpl, poolManager, deployer, address(d.guard));
        (address minedHook, bytes32 hookSalt) =
            HookSaltMiner.mine(HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS, hookInitCode);
        d.feeHook = ProtocolFeeHook(
            address(
                new ERC1967Proxy{salt: hookSalt}(
                    hookImpl,
                    abi.encodeCall(
                        ProtocolFeeHook.initialize, (poolManager, deployer, address(d.guard))
                    )
                )
            )
        );
        require(address(d.feeHook) == minedHook, "hook address mismatch");

        d.reserve = ProtocolStack.deployReservePool(
            BASE_USDC, address(d.yieldSource), deployer, d.beacons, address(d.guard)
        );
        d.reserve.setLiabilityCap(DEFAULT_LIABILITY_CAP);

        d.factory = ProtocolStack.deployFactory(
            d.reserve,
            poolManager,
            d.feeHook,
            IPositionManagerV4(V4_POSITION_MANAGER),
            deployer, // protocolTreasury
            address(0), // referenceEquity — disabled on testnet
            0, // protocolBps
            REWARDS_DURATION,
            MIN_OBSERVATION_CARDINALITY,
            deployer,
            d.beacons,
            address(d.guard)
        );
        d.feeHook.setRegistrar(address(d.factory));

        d.router = ProtocolStack.deployRouter(
            d.reserve,
            d.factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            deployer,
            address(d.guard)
        );

        d.zapper = ProtocolStack.deployZapper(
            d.reserve,
            d.factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            ISwapRouter02(address(0)),
            deployer,
            address(d.guard)
        );

        // ─── Launchpad ──────────────────────────────────────────────────
        ProtocolStack.Launchpad memory lp = ProtocolStack.deployLaunchpad(
            deployer,
            address(d.guard),
            d.factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2)
        );
        d.launchFactory = lp.factory;
        d.launchRouter = lp.router;
        d.launchFeeEscrow = address(lp.feeEscrow);
        d.launchLocker = address(lp.locker);
        d.launchDeployer = address(lp.launchDeployer);
        d.launchGraduation = address(lp.graduation);
        d.launchGraduationGuard = address(lp.graduationGuard);

        // Register the launchpad module with the market factory.
        d.factory.setLaunchpad(address(lp.graduation));

        // Apply the launchpad policy + default config.
        uint256 launchConfigId = LaunchpadDefaults.applyPolicy(
            d.launchFactory,
            d.factory.protocolTreasury(),
            vm.envOr("LAUNCH_LP_FUND_RECIPIENT", d.factory.protocolTreasury())
        );
        console.log("Launch config id:", launchConfigId);

        // ─── Quote brand ────────────────────────────────────────────────
        // Register a brand on the fresh reserve to use as the launchpad's quote brand.
        (d.quoteBrand,) = d.reserve
            .registerBrand(
                "Launch Dollar",
                "launchUSD",
                deployer,
                PooledBrandToken.Metadata({
                    description: "Launchpad quote brand", logo: "", socials: ""
                }),
                address(0)
            );

        // Open the reserve for launches. Every brand on it -- the one just registered, and
        // any issued later -- is quotable from here with no further owner action.
        LaunchpadDefaults.approveQuoteReserve(
            d.launchFactory,
            address(d.reserve),
            LaunchpadDefaults.PHANTOM_QUOTE,
            LaunchpadDefaults.GRADUATION_THRESHOLD,
            LaunchpadDefaults.LAUNCH_FEE,
            LaunchpadDefaults.QUOTE_DECIMALS
        );
        d.launchFactory.setLaunchEnabled(true);

        vm.stopBroadcast();

        // ─── Assertions ─────────────────────────────────────────────────
        require(d.factory.owner() == deployer, "factory owner mismatch");
        require(
            address(d.factory.positionManager()) == V4_POSITION_MANAGER, "positionManager mismatch"
        );
        require(
            address(d.factory.launchpad()) == address(lp.graduation), "launchpad not registered"
        );
        require(d.launchFactory.owner() == deployer, "launch factory owner mismatch");
        require(d.launchFactory.launchEnabled(), "launching not enabled");

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Faucet asset:", address(d.asset));
        console.log("Yield source:", address(d.yieldSource));
        console.log("ProtocolGuard:", address(d.guard));
        console.log("ProtocolFeeHook:", address(d.feeHook));
        console.log("SharedReservePool:", address(d.reserve));
        console.log("AssetMarketFactory:", address(d.factory));
        console.log("MarketRouter:", address(d.router));
        console.log("LiquidityZapper:", address(d.zapper));
        console.log("Quote brand:", d.quoteBrand);
        console.log("");
        console.log("LaunchFeeEscrow:", d.launchFeeEscrow);
        console.log("LaunchFactory (proxy):", address(d.launchFactory));
        console.log("LaunchGraduation:", d.launchGraduation);
        console.log("LaunchGraduationGuard:", d.launchGraduationGuard);
        console.log("LaunchLocker:", d.launchLocker);
        console.log("LaunchDeployer:", d.launchDeployer);
        console.log("LaunchRouter:", address(d.launchRouter));
        console.log("");
        console.log("Wiring assertions: PASSED");
    }
}
