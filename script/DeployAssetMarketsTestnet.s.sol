// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketDeployer} from "../src/markets/MarketDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolGuard} from "../src/upgrade/ProtocolGuard.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {HookSaltMiner} from "./DeployAssetMarkets.s.sol";

/// @notice TESTNET ONLY. Faucet money and explicitly simulated yield, on the live Uniswap v4
///         `PoolManager` that Robinhood Chain testnet already carries.
///
/// @dev    **The v4 singleton is the chain's, not ours, and it sits at the same address on
///         testnet as on mainnet** — `0x8366a39CC670B4001A1121B8F6A443A643e40951` on both
///         4663 and 46630, which is what a deterministic deployment looks like. So testnet
///         exercises the same venue mainnet will, rather than a local copy that could differ
///         from it in ways only production would discover.
///
///         An earlier revision deployed its own PoolManager here, on the mistaken belief that
///         Uniswap had not shipped v4 to this chain. It had; the check that missed it only
///         looked at the canonical Ethereum and Base addresses, which are empty here in the
///         same way the canonical v3 addresses are.
///
///         This script needs no filesystem permissions, no `UNISWAP_NODE_MODULES` and no
///         profile — which is why the suites that drive it now run unconditionally. It used to
///         read pinned official Uniswap V3 artifacts off disk under the
///         `asset_markets_testnet` profile.
///
///         No private key environment variable is read. Use --account with an encrypted
///         keystore. See docs/ASSET_MARKETS_TESTNET.md.
contract DeployAssetMarketsTestnet is Script {
    /// @notice Uniswap v4 `PoolManager`. Same address on Robinhood Chain mainnet (4663) and
    ///         testnet (46630); see `script/MainnetAddresses.sol` for how it was found.
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Uniswap's v4 `PositionManager` and the canonical Permit2, which between them are
    ///         what makes liquidity seeded through `MarketRouter` withdrawable: the router mints
    ///         the LP position through the periphery and the NFT goes to the seeder. Same
    ///         addresses as mainnet; see `script/MainnetAddresses.sol`.
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice The LP reward period and oracle depth stamped into markets created here — the
    ///         same numbers `DeployAssetMarkets` defaults to, so testnet streams rewards over
    ///         the same week mainnet will rather than a shortened test schedule.
    uint32 internal constant REWARDS_DURATION = 7 days;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 62;

    function run() external returns (AssetMarketFactory, MarketRouter, AssetMarketTestYieldSource) {
        require(block.chainid == 46630 || block.chainid == 31337, "testnet/local only");
        address deployer = vm.envAddress("DEPLOYER");
        require(deployer != address(0), "DEPLOYER required");

        vm.startBroadcast(deployer);

        // Deployed first, and in this order, because tests and the seeding script address them
        // by the deployer's nonce: faucet USDG is nonce 0, the faucet asset is nonce 1.
        AssetMarketFaucetToken usdg = new AssetMarketFaucetToken("Test USDG (faucet)", "tUSDG", 6);
        AssetMarketFaucetToken asset = new AssetMarketFaucetToken("Test Market Asset", "tASSET", 18);
        AssetMarketTestYieldSource yieldSource = new AssetMarketTestYieldSource();

        // The chain's own v4 singleton, identical in address to mainnet's. Checked rather
        // than assumed: a wrong address here would not fail until the first `createMarket`.
        IPoolManager poolManager = IPoolManager(V4_POOL_MANAGER);
        require(V4_POOL_MANAGER.code.length > 0, "no PoolManager on this testnet");

        // A v4 hook's permissions are the low 14 bits of its address, and the salt that lands it
        // there is bound to these exact constructor arguments — so mining and deploying have to
        // happen in the same run. See `HookSaltMiner`.
        // The testnet stack answers to the deployer rather than a timelock: it exists to be
        // torn down and rebuilt, and a two-day delay on every fix would defeat that. Mainnet
        // uses the timelock — see `DeploySharedReservePool`.
        ProtocolGuard guard = ProtocolStack.deployGuard(deployer, deployer);
        ProtocolStack.Beacons memory beacons = ProtocolStack.deployBeacons(deployer);

        // The mined address is the PROXY's; see the long note in `DeployAssetMarkets`.
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

        SharedReservePool reserve = ProtocolStack.deployReservePool(
            address(usdg), address(yieldSource), deployer, beacons, address(guard)
        );

        // Zero protocol fee, so the whole float yield is paid to the market's LPs — the same
        // economics the mainnet script deploys, exercised end to end on testnet.
        // `address(0)` as the reference equity disables canonicality verification: there is no
        // Robinhood equity on a test chain, and a zero codehash must never read as a match.
        //
        // Nothing here approves an asset, so no market can be created yet: an approval fixes
        // the price a pool opens at and belongs to whoever is launching, not to this fixture.
        AssetMarketFactory factory = ProtocolStack.deployFactory(
            reserve,
            poolManager,
            feeHook,
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

        // Without this the hook refuses `registerPool` and every `createMarket` reverts. The
        // two contracts each need the other's address, so it cannot be a constructor argument.
        feeHook.setRegistrar(address(factory));

        // The router still takes its singleton off the factory; the periphery pair has no
        // factory to come from, so it is passed. The constructor rejects a PositionManager
        // bound to a different PoolManager, so a stale address cannot survive this line.
        MarketRouter router = ProtocolStack.deployRouter(
            reserve,
            factory,
            IPositionManagerV4(V4_POSITION_MANAGER),
            IPermit2(PERMIT2),
            deployer,
            address(guard)
        );

        usdg.mint(deployer, 1_000_000e6);
        asset.mint(deployer, 1_000_000e18);
        vm.stopBroadcast();

        require(address(MarketDeployer).code.length > 0, "MarketDeployer library is not linked");
        require(feeHook.registrar() == address(factory), "hook registrar is not the factory");
        require(address(router.poolManager()) == address(poolManager), "router venue mismatch");
        require(address(router.positionManager()) == V4_POSITION_MANAGER, "router posm mismatch");

        console.log("TESTNET fixture USDG:", address(usdg));
        console.log("TESTNET fixture asset:", address(asset));
        console.log("TESTNET simulated yield source:", address(yieldSource));
        console.log("MarketDeployer (library, linked):", address(MarketDeployer));
        console.log("Robinhood Chain Uniswap v4 PoolManager:", address(poolManager));
        console.log("ProtocolFeeHook (mined, also the pools' oracle):", address(feeHook));
        console.log("SharedReservePool:", address(reserve));
        console.log("AssetMarketFactory:", address(factory));
        console.log("MarketRouter:", address(router));
        return (factory, router, yieldSource);
    }
}

/// @notice Unrestricted public faucet; never use as real collateral or equity provenance.
contract AssetMarketFaucetToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        require(block.chainid == 46630 || block.chainid == 31337, "testnet/local only");
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/// @notice Controlled test yield injection, backed by actual token transfers, per consumer.
///         This is not Morpho and cannot validate lending utilization or interest accrual.
contract AssetMarketTestYieldSource {
    using SafeERC20 for IERC20;

    mapping(address asset => mapping(address consumer => uint256)) public balances;
    mapping(address asset => uint256) public totalAssets;

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        balances[asset][msg.sender] += amount;
        totalAssets[asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // Reserve recall adds one raw unit to cover rounding. Match production adapters:
        // return at most this consumer's position, never underflow or spend another's funds.
        uint256 available = balances[asset][msg.sender];
        if (amount > available) amount = available;
        balances[asset][msg.sender] -= amount;
        totalAssets[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function balanceOf(address asset) external view returns (uint256) {
        return balances[asset][msg.sender];
    }

    function simulateYield(address asset, address consumer, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        balances[asset][consumer] += amount;
        totalAssets[asset] += amount;
    }
}
