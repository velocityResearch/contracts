// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {LiquidityZapper} from "../src/markets/LiquidityZapper.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";

/// @title DeployLiquidityZapperV2
/// @notice Deploy the second-generation `LiquidityZapper`: owned, guarded, upgradeable, and with
///         both slippage doors closed.
///
/// ## Read this first: the old zapper stays deployed and stays broken
///
///         **0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd remains live, ownerless and defective,
///         and nothing in this script changes that.** It accepts `minLiquidity = 0` and
///         `minUsdgOut = 0` and tells Uniswap v3 `amountOutMinimum: 0`, so both of its doors can
///         be sandwiched. It has no owner, no pause hook of its own and no proxy, so there is no
///         transaction anyone can send that fixes it, pauses it or retires it. It will answer
///         zaps for as long as somebody calls it.
///
///         That makes de-referencing it part of the deployment, not a follow-up. Whoever runs
///         this MUST, in the same sitting:
///
///         1. Replace the zapper address in `deployments/app-networks.json` with the PROXY
///            printed below (not the implementation).
///         2. Replace `NEXT_PUBLIC_LIQUIDITY_ZAPPER` wherever it is set — the deployment
///            environment and any local `.env` — with that same proxy address.
///         3. Redeploy the frontend, so no served bundle still names the old address.
///         4. Have the frontend send a non-zero `minLiquidity` and a non-zero `minUsdgOut` on
///            every zap. The new contract REVERTS on zero (`ZeroLiquidityBound`,
///            `ZeroSaleBound`), so a client that hardcoded zero will fail outright rather than
///            silently lose money. That is the intended failure and it is why step 3 is not
///            optional.
///         5. Record the new proxy and implementation in `deployments/mainnet-state.json` and
///            fill in the two blank addresses in `script/verify-mainnet-sourcify.sh`, then run
///            that script to publish source for both.
///
///         Until step 3 lands, the app is still pointing users at the sandwichable contract.
///
/// ## What this script does and does not touch
///
///         One implementation, one ERC1967 proxy, one initialisation. No existing proxy is
///         upgraded, no beacon is moved, no market is touched, and no transaction is sent to any
///         contract that already exists. The reserve pool, the factory, the router, the pool
///         manager and all 18 markets are read-only inputs here.
///
///         That is possible because the zap is unprivileged: it needs no role, no allowlist and
///         no registration. Every market that exists today works with the new address the
///         moment it is deployed, and so will every market created after it.
///
/// ## Usage
///
///         PRIVATE_KEY=0x... SHARED_RESERVE_POOL=0x... ASSET_MARKET_FACTORY=0x... MARKET_ROUTER=0x... SWAP_ROUTER_02=0x... forge script script/DeployLiquidityZapperV2.s.sol --rpc-url robinhood
///
///         Add `--broadcast` only when the addresses above have been checked against
///         `deployments/mainnet-state.json`. Without it this is a dry run that still performs
///         every post-condition assertion below, which is the cheapest way to catch bad wiring.
///
///         `MARKET_ROUTER` is not wiring — the zapper never calls the router. It is read so that
///         `PositionManager`, `Permit2`, the owner and the `ProtocolGuard` all come from the
///         contract already using them on this chain rather than from constants pasted here. On
///         a chain where the canonical periphery address has already been found to hold an
///         unrelated contract, deriving beats declaring. `OWNER` and `PROTOCOL_GUARD` override
///         it only for a deployment with no router to read from.
///
///         `SWAP_ROUTER_02` is the Uniswap **v3** router the ETH door sells through and is the
///         one address that cannot be derived from the rest of the stack, because the asset
///         markets are v4 and never touch v3. Leave it unset to deploy a zapper that takes USDG
///         only; `zapLiquidityWithEth` then reverts `EthZapUnavailable` instead of half-working.
///         On Robinhood Chain mainnet it is 0xCaf681a66D020601342297493863E78C959E5cb2 — the
///         CANONICAL SwapRouter address holds an unrelated funds-forwarding contract on this
///         chain, so it is identity-checked against the v3 factory below rather than trusted.
///
///         WETH is never passed in. `initialize` reads it off the router, so the wrapper the
///         zapper wraps into is by construction the one the router will accept.
contract DeployLiquidityZapperV2 is Script {
    /// @dev Robinhood Chain. Guarded because every address below is chain-specific and a stack
    ///      deployed against the wrong chain would look successful and serve nobody.
    uint256 internal constant ROBINHOOD_CHAIN = 4663;

    /// @notice The first-generation zapper. Recorded here so the log can name what is being
    ///         replaced, and never called: it has no function this script could usefully invoke.
    address internal constant OLD_ZAPPER = 0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd;

    function run() external returns (LiquidityZapper zapper, address implementation) {
        require(block.chainid == ROBINHOOD_CHAIN, "Robinhood Chain only");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        SharedReservePool reservePool = SharedReservePool(vm.envAddress("SHARED_RESERVE_POOL"));
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));

        // Taken from the live router unless overridden, so the new zapper mints through the same
        // PositionManager the rest of the stack settles against, obeys the same pause registry,
        // and answers to the same owner. Four addresses that must agree, read from the one
        // contract that already has them right.
        address routerAddr = vm.envOr("MARKET_ROUTER", address(0));
        address positionManager = vm.envOr("POSITION_MANAGER", address(0));
        address permit2 = vm.envOr("PERMIT2", address(0));
        address owner = vm.envOr("OWNER", address(0));
        address guard = vm.envOr("PROTOCOL_GUARD", address(0));
        if (routerAddr != address(0)) {
            MarketRouter router = MarketRouter(routerAddr);
            if (positionManager == address(0)) positionManager = address(router.positionManager());
            if (permit2 == address(0)) permit2 = address(router.permit2());
            if (guard == address(0)) guard = address(router.guard());
            require(
                address(router.factory()) == address(factory),
                "MARKET_ROUTER serves a different factory"
            );
            require(
                address(router.reservePool()) == address(reservePool),
                "MARKET_ROUTER serves a different reserve pool"
            );
        }
        require(positionManager != address(0), "set MARKET_ROUTER or POSITION_MANAGER");
        require(permit2 != address(0), "set MARKET_ROUTER or PERMIT2");
        require(guard != address(0), "set MARKET_ROUTER or PROTOCOL_GUARD");

        // The signer owns it on delivery, and a handover to the timelock is a separate,
        // deliberate `transferOwnership` + `acceptOwnership` pair — see
        // `HandOverMainnetOwnership`. Initialising straight to the timelock would be tidier and
        // is wrong: the post-conditions below would then be unverifiable by the only key that
        // can act, and a bad initialisation would be discovered with nobody able to fix it.
        if (owner == address(0)) owner = deployer;

        // The ETH door. Optional, and checked hard when present: an approval to the wrong router
        // is a real loss on this chain, so the address proves what it is before any contract is
        // built around it.
        address swapRouter = vm.envOr("SWAP_ROUTER_02", address(0));
        address weth;
        if (swapRouter != address(0)) {
            weth = ISwapRouter02(swapRouter).WETH9();
            require(weth != address(0), "SWAP_ROUTER_02 names no WETH9");
            address expectedV3Factory = vm.envOr("UNISWAP_V3_FACTORY", address(0));
            if (expectedV3Factory != address(0)) {
                require(
                    ISwapRouter02(swapRouter).factory() == expectedV3Factory,
                    "SWAP_ROUTER_02 serves a different v3 factory"
                );
            }
        }

        vm.startBroadcast(deployerKey);
        zapper = ProtocolStack.deployZapper(
            reservePool,
            factory,
            IPositionManagerV4(positionManager),
            IPermit2(permit2),
            ISwapRouter02(swapRouter),
            owner,
            guard
        );
        vm.stopBroadcast();

        // Read out of the proxy's ERC-1967 implementation slot rather than remembered from the
        // deployment, because the address that has to be verified and recorded is the one the
        // proxy will actually delegate to.
        implementation = address(
            uint160(
                uint256(
                    vm.load(
                        address(zapper),
                        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
                    )
                )
            )
        );

        _assertWiring(zapper, reservePool, factory, positionManager, permit2, swapRouter, weth);
        _assertAdmin(zapper, owner, guard);
        _assertSlippageDoorsAreClosed(zapper, swapRouter != address(0));

        _report(zapper, implementation, deployer, factory);
    }

    /// @dev Asserted in the same process that deployed it, which is a weak check — see
    ///      `VerifyAssetMarketsMainnet` for why. It is still worth failing here rather than
    ///      discovering a mismatch from a user's reverted transaction.
    function _assertWiring(
        LiquidityZapper zapper,
        SharedReservePool reservePool,
        AssetMarketFactory factory,
        address positionManager,
        address permit2,
        address swapRouter,
        address weth
    ) private view {
        require(address(zapper.reservePool()) == address(reservePool), "reserve pool mismatch");
        require(address(zapper.factory()) == address(factory), "factory mismatch");
        require(address(zapper.positionManager()) == positionManager, "position manager mismatch");
        require(address(zapper.permit2()) == permit2, "permit2 mismatch");
        require(address(zapper.asset()) == address(reservePool.asset()), "reserve asset mismatch");
        require(address(zapper.swapRouter()) == swapRouter, "swap router mismatch");
        require(address(zapper.weth()) == weth, "weth mismatch");

        // The identity check `initialize` performs, re-asserted from outside. `initialize` would
        // have reverted on a mismatch, so this cannot fail here — which is the point: it proves
        // the deployed proxy is bound to the PoolManager the factory initialised these pools
        // with, and therefore that a mint cannot land in a pool that is not the market's.
        require(
            address(zapper.poolManager()) == address(factory.poolManager()), "pool manager mismatch"
        );
        require(
            IPositionManagerV4(positionManager).poolManager() == address(zapper.poolManager()),
            "position manager is bound to a different pool manager"
        );
    }

    function _assertAdmin(LiquidityZapper zapper, address owner, address guard) private {
        require(zapper.owner() == owner, "owner mismatch");
        require(address(zapper.guard()) == guard, "guard mismatch");
        require(!zapper.paused(), "deployed into a paused protocol");

        // The two things the first generation could not do, proved rather than assumed.
        // `renounceOwnership` reverting is what keeps the implementation from being frozen with
        // a defect in it, and a second `initialize` failing is what keeps the wiring from being
        // rewritten by whoever front-runs the first call.
        (bool ok,) = address(zapper).call(abi.encodeWithSelector(zapper.renounceOwnership.selector));
        require(!ok, "renounceOwnership did not revert");

        (ok,) = address(zapper)
            .call(
                abi.encodeCall(
                    LiquidityZapper.initialize,
                    (
                        SharedReservePool(address(0)),
                        AssetMarketFactory(address(0)),
                        IPositionManagerV4(address(0)),
                        IPermit2(address(0)),
                        ISwapRouter02(address(0)),
                        address(0),
                        address(0)
                    )
                )
            );
        require(!ok, "the initialiser can be run a second time");
    }

    /// @dev The finding this deployment exists for, asserted against the deployed proxy: neither
    ///      door may be entered without a slippage bound. Checked with `call` rather than
    ///      `vm.expectRevert` because this is a script and not a test — and checked at all
    ///      because "we fixed the slippage gap" is exactly the claim that should not be taken
    ///      on trust from a diff.
    ///
    ///      **These calls have to get far enough to be refused for the right reason.** Both
    ///      doors validate cheaply before they take anything, so an unbounded call reverts on
    ///      the bound and not on an allowance or a balance — which is itself the property being
    ///      asserted. The ETH door additionally rejects a zero `msg.value` first, so one wei is
    ///      sent: without it every probe below would come back `ZeroAmount` and prove nothing.
    ///      Nothing is at risk in doing so, because every one of these calls must revert.
    ///
    /// @param ethDoorOpen False on a deployment with no v3 router, where `zapLiquidityWithEth`
    ///                    reverts `EthZapUnavailable` before any bound is read and there is
    ///                    consequently nothing to assert about it.
    function _assertSlippageDoorsAreClosed(LiquidityZapper zapper, bool ethDoorOpen) private {
        (bool ok, bytes memory err) = address(zapper)
            .call(abi.encodeCall(zapper.zapLiquidity, (0, 1e6, 5_000, 0, block.timestamp + 600)));
        require(!ok, "the USDG door accepted a zero liquidity bound");
        require(
            bytes4(err) == LiquidityZapper.ZeroLiquidityBound.selector,
            "the USDG door rejected a zero bound for the wrong reason"
        );

        if (!ethDoorOpen) return;

        // The ETH door reads `msg.value` before it reads its bounds, so these probes have to
        // carry a wei or they come back `ZeroAmount` and prove nothing. The value is sent by a
        // throwaway `ZapperDoorProber` funded with `vm.deal`, NOT by this script: forge
        // refuses a script that relies on `address(this)`, because a script contract is
        // ephemeral and neither its identity nor its balance should be depended on. The prober
        // is a simulation-only artifact; it is created inside the broadcast window's shadow
        // and nothing it does can succeed, since every call below must revert.
        ZapperDoorProber prober = new ZapperDoorProber();
        vm.deal(address(prober), 4);

        (ok, err) = prober.probe(
            address(zapper),
            abi.encodeCall(zapper.zapLiquidityWithEth, (0, 500, 0, 5_000, 1, block.timestamp + 600))
        );
        require(!ok, "the ETH door accepted a zero sale bound");
        require(
            bytes4(err) == LiquidityZapper.ZeroSaleBound.selector,
            "the ETH door rejected a zero sale bound for the wrong reason"
        );

        (ok, err) = prober.probe(
            address(zapper),
            abi.encodeCall(
                zapper.zapLiquidityWithEth, (0, 500, 1e6, 5_000, 0, block.timestamp + 600)
            )
        );
        require(!ok, "the ETH door accepted a zero liquidity bound");
        require(
            bytes4(err) == LiquidityZapper.ZeroLiquidityBound.selector,
            "the ETH door rejected a zero liquidity bound for the wrong reason"
        );
    }

    function _report(
        LiquidityZapper zapper,
        address implementation,
        address deployer,
        AssetMarketFactory factory
    ) private view {
        console.log("");
        console.log("LiquidityZapper (proxy) ", address(zapper));
        console.log("  implementation       ", implementation);
        console.log("  deployer             ", deployer);
        console.log("  owner                ", zapper.owner());
        console.log("  guard                ", address(zapper.guard()));
        console.log("  reservePool          ", address(zapper.reservePool()));
        console.log("  factory              ", address(zapper.factory()));
        console.log("  poolManager          ", address(zapper.poolManager()));
        console.log("  positionManager      ", address(zapper.positionManager()));
        console.log("  permit2              ", address(zapper.permit2()));
        console.log("  asset (reserve)      ", address(zapper.asset()));
        console.log("  swapRouter (v3)      ", address(zapper.swapRouter()));
        console.log("  weth                 ", address(zapper.weth()));
        console.log("  ETH zaps             ", zapper.supportsEthZaps() ? "enabled" : "DISABLED");
        console.log("  markets covered      ", factory.marketCount());
        console.log("");
        console.log("Nothing already deployed was modified. Still to do, in this order:");
        console.log("  1. deployments/app-networks.json  -> the PROXY above");
        console.log("  2. NEXT_PUBLIC_LIQUIDITY_ZAPPER=", address(zapper));
        console.log("  3. redeploy the frontend, sending non-zero minLiquidity/minUsdgOut");
        console.log("  4. record both addresses in deployments/mainnet-state.json");
        console.log("  5. fill both blanks in script/verify-mainnet-sourcify.sh and run it");
        console.log("");
        console.log("The OLD zapper is still live and still sandwichable, and cannot be fixed:");
        console.log("  ", OLD_ZAPPER);
        console.log("It has no owner and no upgrade path. De-referencing it is the only remedy.");
    }
}

/// @dev Sends the ETH-door probes so the script does not have to. A script contract's address
///      and balance are ephemeral and forge refuses to let one be relied on, but the ETH door
///      checks `msg.value` before it checks its bounds, so the probes must carry a wei from
///      somewhere. This is that somewhere: funded with `vm.deal`, used only in simulation, and
///      incapable of doing harm because every call it makes is required to revert.
contract ZapperDoorProber {
    function probe(address target, bytes calldata data)
        external
        returns (bool ok, bytes memory err)
    {
        (ok, err) = target.call{value: 1}(data);
    }

    receive() external payable {}
}
