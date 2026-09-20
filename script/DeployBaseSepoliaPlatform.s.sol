// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {StrategyGroupRegistry} from "../src/registry/StrategyGroupRegistry.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketDeployer} from "../src/markets/MarketDeployer.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {LiquidityZapper} from "../src/markets/LiquidityZapper.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";
import {SUSDaiYieldSource} from "../src/yield/SUSDaiYieldSource.sol";
import {AssetMarketTestYieldSource} from "./DeployAssetMarketsTestnet.s.sol";
import {HookSaltMiner} from "./DeployAssetMarkets.s.sol";

/// @notice Deploys the complete Base Sepolia application stack against Circle USDC, Uniswap v4,
///         and Across. The remote hub must already exist on Arbitrum Sepolia.
contract DeployBaseSepoliaPlatform is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    address internal constant BASE_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant ARBITRUM_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address internal constant BASE_SPOKE_POOL = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;
    address internal constant V4_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant V4_POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant DEFAULT_LIABILITY_CAP = 100_000e6;
    uint256 internal constant DEFAULT_BRIDGE_CAP = 5_000e6;
    uint16 internal constant DEFAULT_REDEMPTION_FEE_BPS = 14;

    /// @notice The LP reward period and oracle depth stamped into markets created here, kept
    ///         equal to the mainnet script's defaults so a Base Sepolia rehearsal streams
    ///         rewards on the same schedule production will.
    uint32 internal constant REWARDS_DURATION = 7 days;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 62;

    bytes32 public constant MARKET_GROUP_ID = keccak256("market-usdg");
    bytes32 public constant SUSDAI_GROUP_ID = keccak256("susdai-usdg");

    struct MarketDeployment {
        BaseSepoliaFaucetAsset asset;
        AssetMarketTestYieldSource yieldSource;
        ProtocolFeeHook feeHook;
        SharedReservePool reserve;
        AssetMarketFactory factory;
        MarketRouter router;
        LiquidityZapper zapper;
    }

    struct CrossChainDeployment {
        SUSDaiYieldSource adapter;
        SharedReservePool reserve;
        StrategyGroupRegistry registry;
        address sampleBrand;
    }

    function run()
        external
        returns (MarketDeployment memory market, CrossChainDeployment memory crossChain)
    {
        require(block.chainid == BASE_SEPOLIA, "Base Sepolia only");
        address deployer = vm.envAddress("DEPLOYER");
        address keeper = vm.envOr("SUSDAI_KEEPER", deployer);
        address remoteHub = vm.envAddress("REMOTE_HUB");
        uint256 liabilityCap = vm.envOr("TESTNET_LIABILITY_CAP", DEFAULT_LIABILITY_CAP);
        uint256 bridgeCap = vm.envOr("TESTNET_BRIDGE_CAP", DEFAULT_BRIDGE_CAP);
        uint16 redemptionFeeBps =
            SafeCast.toUint16(vm.envOr("REDEMPTION_FEE_BPS", uint256(DEFAULT_REDEMPTION_FEE_BPS)));

        require(deployer != address(0) && keeper != address(0), "authority is zero");
        require(remoteHub != address(0), "REMOTE_HUB is zero");
        require(liabilityCap > 0 && bridgeCap > 0, "testnet caps must be nonzero");
        require(redemptionFeeBps <= 100, "redemption fee above pool maximum");
        require(IERC20Metadata(BASE_USDC).decimals() == 6, "Base USDC decimals mismatch");
        require(V4_POOL_MANAGER.code.length > 0, "Base PoolManager missing");
        require(V4_POSITION_MANAGER.code.length > 0, "Base PositionManager missing");
        require(PERMIT2.code.length > 0, "Base Permit2 missing");
        require(BASE_SPOKE_POOL.code.length > 0, "Base SpokePool missing");

        vm.startBroadcast(deployer);
        market = _deployMarketStack(deployer, liabilityCap);
        crossChain = _deployCrossChainStack(
            deployer, keeper, remoteHub, liabilityCap, bridgeCap, redemptionFeeBps, market
        );
        vm.stopBroadcast();

        require(address(MarketDeployer).code.length > 0, "MarketDeployer library is not linked");
        require(market.feeHook.registrar() == address(market.factory), "hook registrar mismatch");
        require(address(market.router.poolManager()) == V4_POOL_MANAGER, "router venue mismatch");
        require(
            address(market.router.positionManager()) == V4_POSITION_MANAGER,
            "router PositionManager mismatch"
        );
        require(!market.zapper.supportsEthZaps(), "ETH zaps unexpectedly enabled");
        require(
            crossChain.adapter.controller() == address(crossChain.reserve), "controller mismatch"
        );
        require(crossChain.adapter.hub() == remoteHub, "remote hub mismatch");
        require(crossChain.adapter.maxBridgeAmount() == bridgeCap, "adapter cap mismatch");
        require(crossChain.reserve.liabilityCap() == liabilityCap, "sUSDai cap mismatch");
        require(crossChain.registry.groupCount() == 2, "registry group count mismatch");
        require(crossChain.reserve.isRegistered(crossChain.sampleBrand), "sample brand missing");

        // The reserve is NOT charging this fee yet. `setRedemptionFee` announces an increase
        // and `SharedReservePool.FEE_INCREASE_DELAY` has to elapse before anyone can commit
        // it, so the post-condition is on what was ANNOUNCED, not on the live value — a
        // deployment that asserted the live fee here would fail, and one that asserted
        // nothing would look configured while redemptions ran free.
        if (redemptionFeeBps > 0) {
            require(
                crossChain.reserve.pendingRedemptionFeeBps() == redemptionFeeBps,
                "sUSDai redemption fee was not announced"
            );
            require(
                crossChain.reserve.redemptionFeeEffectiveAt() > block.timestamp,
                "announced fee has no future effective time"
            );
        } else {
            require(crossChain.reserve.redemptionFeeBps() == 0, "sUSDai reserve is not fee-free");
        }

        _log(market, crossChain);
        _logPendingFee(crossChain.reserve, redemptionFeeBps);
    }

    function _deployMarketStack(address deployer, uint256 liabilityCap)
        internal
        returns (MarketDeployment memory result)
    {
        result.asset = new BaseSepoliaFaucetAsset();
        result.yieldSource = new AssetMarketTestYieldSource();

        IPoolManager poolManager = IPoolManager(V4_POOL_MANAGER);
        ProtocolGuard guard = ProtocolStack.deployGuard(deployer, deployer);
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(deployer);

        address hookImplementation = ProtocolStack.deployHookImplementation();
        bytes memory hookInitCode = ProtocolStack.hookProxyInitCode(
            hookImplementation, poolManager, deployer, address(guard)
        );
        (address minedHook, bytes32 hookSalt) =
            HookSaltMiner.mine(HookSaltMiner.PROTOCOL_FEE_HOOK_FLAGS, hookInitCode);
        result.feeHook = ProtocolFeeHook(
            address(
                new ERC1967Proxy{salt: hookSalt}(
                    hookImplementation,
                    abi.encodeCall(
                        ProtocolFeeHook.initialize, (poolManager, deployer, address(guard))
                    )
                )
            )
        );
        require(address(result.feeHook) == minedHook, "hook address mismatch");

        result.reserve = ProtocolStack.deployReservePool(
            BASE_USDC, address(result.yieldSource), deployer, beacons, address(guard)
        );
        result.reserve.setLiabilityCap(liabilityCap);
        result.factory = ProtocolStack.deployFactory(
            result.reserve,
            poolManager,
            result.feeHook,
            IPositionManagerV4(V4_POSITION_MANAGER),
            deployer,
            address(0),
            0,
            REWARDS_DURATION,
            MIN_OBSERVATION_CARDINALITY,
            deployer,
            beacons,
            address(guard)
        );
        result.feeHook.setRegistrar(address(result.factory));
        result.router = ProtocolStack.deployRouter(
            result.reserve,
            result.factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            deployer,
            address(guard)
        );
        result.zapper = ProtocolStack.deployZapper(
            result.reserve,
            result.factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            ISwapRouter02(address(0)),
            deployer,
            address(guard)
        );
        result.asset.mint(deployer, 1_000_000e18);
    }

    function _deployCrossChainStack(
        address deployer,
        address keeper,
        address remoteHub,
        uint256 liabilityCap,
        uint256 bridgeCap,
        uint16 redemptionFeeBps,
        MarketDeployment memory market
    ) internal returns (CrossChainDeployment memory result) {
        ProtocolGuard guard = ProtocolStack.deployGuard(deployer, deployer);
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(deployer);
        result.adapter = SUSDaiYieldSource(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiYieldSource()),
                    abi.encodeCall(
                        SUSDaiYieldSource.initialize,
                        (
                            BASE_USDC,
                            BASE_SPOKE_POOL,
                            ARBITRUM_SEPOLIA,
                            remoteHub,
                            ARBITRUM_USDC,
                            address(guard),
                            deployer,
                            keeper
                        )
                    )
                )
            )
        );
        result.reserve = ProtocolStack.deployReservePool(
            BASE_USDC, address(result.adapter), deployer, beacons, address(guard)
        );
        result.adapter.bindController(address(result.reserve));
        result.adapter.setMaxBridgeAmount(bridgeCap);
        result.reserve.setLiabilityCap(liabilityCap);
        result.reserve.setRedemptionFee(redemptionFeeBps);

        result.registry = StrategyGroupRegistry(
            address(
                new ERC1967Proxy(
                    address(new StrategyGroupRegistry()),
                    abi.encodeCall(StrategyGroupRegistry.initialize, (deployer))
                )
            )
        );
        result.registry
            .setGroup(
                MARKET_GROUP_ID,
                StrategyGroupRegistry.GroupInput({
                    reservePool: address(market.reserve),
                    yieldSource: address(market.yieldSource),
                    factory: address(market.factory),
                    router: address(market.router),
                    zapper: address(market.zapper),
                    policyId: MARKET_GROUP_ID,
                    active: true,
                    name: "USDC market reserve",
                    strategy: "Simulated market yield - Base Sepolia"
                })
            );
        result.registry
            .setGroup(
                SUSDAI_GROUP_ID,
                StrategyGroupRegistry.GroupInput({
                    reservePool: address(result.reserve),
                    yieldSource: address(result.adapter),
                    factory: address(0),
                    router: address(0),
                    zapper: address(0),
                    policyId: SUSDAI_GROUP_ID,
                    active: true,
                    name: "sUSDai reserve",
                    strategy: "Mock sUSDai via Across - Arbitrum Sepolia"
                })
            );
        (result.sampleBrand,) = result.reserve
            .registerBrand(
                "Base sUSDai Dollar",
                "bsUSD",
                deployer,
                PooledBrandToken.Metadata({
                    description: "Base Sepolia test brand backed by mock sUSDai on Arbitrum Sepolia through Across.",
                    logo: "",
                    socials: ""
                }),
                deployer
            );
    }

    function _log(MarketDeployment memory market, CrossChainDeployment memory crossChain)
        internal
        view
    {
        console.log("Base Sepolia Circle USDC:", BASE_USDC);
        console.log("Base Sepolia faucet market asset:", address(market.asset));
        console.log("Base Sepolia simulated market yield source:", address(market.yieldSource));
        console.log("Base Sepolia ProtocolFeeHook:", address(market.feeHook));
        console.log("Base Sepolia primary reserve:", address(market.reserve));
        console.log("Base Sepolia AssetMarketFactory:", address(market.factory));
        console.log("Base Sepolia MarketRouter:", address(market.router));
        console.log("Base Sepolia LiquidityZapper (USDC only):", address(market.zapper));
        console.log("Base Sepolia sUSDai adapter:", address(crossChain.adapter));
        console.log("Base Sepolia sUSDai reserve:", address(crossChain.reserve));
        console.log("Base Sepolia strategy registry:", address(crossChain.registry));
        console.log("Base Sepolia sample sUSDai brand:", crossChain.sampleBrand);
        console.log("NEXT: configure the Arbitrum Sepolia hub with this adapter address.");
    }

    /// @dev Says out loud that the deployment is not finished. The reserve reads as configured
    ///      in every other respect while its redemption fee is still zero, and the only thing
    ///      standing between that and a silent misconfiguration is this notice plus the exact
    ///      command that closes it.
    function _logPendingFee(SharedReservePool reserve, uint16 feeBps) internal view {
        if (feeBps == 0) {
            console.log("sUSDai reserve redemption fee: 0 bps, live now (nothing announced).");
            return;
        }
        console.log("");
        console.log("ACTION REQUIRED: the sUSDai reserve is FEE-FREE until the fee is committed.");
        console.log("  announced redemption fee (bps):", reserve.pendingRedemptionFeeBps());
        console.log("  live redemption fee (bps):     ", reserve.redemptionFeeBps());
        console.log("  committable from (unix):       ", reserve.redemptionFeeEffectiveAt());
        console.log("Until then every redemption pays par and the reserve recovers nothing.");
        console.log("Anyone may finalise it, the value and time are already fixed on chain:");
        console.log(
            "  cast send <reserve> 'commitRedemptionFee()' --rpc-url <rpc> --private-key <key>"
        );
        console.log("  reserve:", address(reserve));
        console.log(
            "Then confirm: cast call <reserve> 'redemptionFeeBps()(uint16)' --rpc-url <rpc>"
        );
    }
}

/// @notice Faucet equity used only to make the Base Sepolia market path executable.
contract BaseSepoliaFaucetAsset is ERC20 {
    constructor() ERC20("Base Sepolia Market Asset", "bASSET") {
        require(block.chainid == 84532, "Base Sepolia only");
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}
