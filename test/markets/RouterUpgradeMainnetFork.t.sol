// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";

/// @notice Rehearsal for the live upgrade of the mainnet `MarketRouter` proxy — and, since the
///         multi-reserve work, of the `AssetMarketFactory` implementation it must ride with.
///
/// @dev    Three breaking changes ride on this upgrade, and all are rehearsed here against real
///         mainnet state:
///
///         - `Market` gained a twelfth field (`reservePool`). The old implementation answers
///           `market()` with eleven words and the new decoder reverts on the length mismatch,
///           so upgrading ONLY the router would brick every router path — it reads markets
///           through the factory on each call. The factory implementation must be upgraded
///           first (or in the same transaction); that is the order
///           `UpgradeBaseSepoliaMultiReserve` uses and the order rehearsed here.
///         - `seedLiquidity` changed shape without changing selector: it takes the market's own
///           brandUSD where it took USDG, so a frontend built against the new source and pointed
///           at the old implementation approves one token and has the other pulled.
///         - `sellForUsdg` is replaced by `sellForBrand`, which stops at the market's own dollar
///           instead of redeeming to USDG inside the trade. The old selector stops answering the
///           moment this is mined.
///
///         So this proves the pair lands, that nothing else on the proxies moves, that seeding
///         pulls the brand, and that a real holder of a real market's asset can sell it on the
///         upgraded router and redeem the proceeds at par.
///
///         Defaults to the chain head because this RPC's historical window is short; pin with
///         `ROUTER_UPGRADE_FORK_BLOCK`/`ROUTER_UPGRADE_FORK_URL` for a reproducible run.
contract RouterUpgradeMainnetForkTest is Test {
    address constant PROXY = 0xcCDe2EcDE7072Efe61822551152663F204CF73ce;
    /// @dev The two proxies this rehearsal upgrades do NOT share an owner any more. The
    ///      gen-4 factory was swept into the 2-of-3 Safe with the rest of the protocol, but
    ///      the gen-4 router below was left behind by that handover and is still held by the
    ///      otherwise-retired deployer EOA (`pendingOwner()` is zero, so it is not a
    ///      half-finished `Ownable2Step` either). Each `upgradeToAndCall` therefore has to be
    ///      sent from its own owner, and the assertions record who that is rather than
    ///      assuming the sweep reached both.
    address constant SAFE = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;
    address constant ROUTER_OWNER = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;
    address constant FACTORY = 0xbE2fb491C37F19E723F86A8cAcA625B4Ba75a5E7;
    /// @dev The factory implementation live at the time this rehearsal was written had an
    ///      11-field `Market`; the new router cannot decode that, which is why they upgrade
    ///      together. Recorded only as a comment so a rerun after the pair is mined does not
    ///      fail a pinned check against a value that legitimately moved.
    address constant RESERVE = 0x076e361b535B236471BEA7f444D5E70971172338;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @dev This chain's public RPC keeps only a short window of historical state, so a block
    ///      hardcoded here goes stale within days and the fork fails to open at all. Default to
    ///      the chain head and let `ROUTER_UPGRADE_FORK_BLOCK` pin it when a run needs to be
    ///      reproducible. `ROUTER_UPGRADE_FORK_URL` points at a local anvil fork, which is the
    ///      only way to keep state still for the length of a slow suite.
    string constant DEFAULT_FORK_URL = "https://rpc.mainnet.chain.robinhood.com";

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MarketRouter router;
    AssetMarketFactory factory;

    function setUp() public {
        string memory url = vm.envOr("ROUTER_UPGRADE_FORK_URL", DEFAULT_FORK_URL);
        uint256 pinned = vm.envOr("ROUTER_UPGRADE_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        router = MarketRouter(PROXY);
        factory = AssetMarketFactory(FACTORY);
    }

    /// @dev The pair in production order: factory implementation first — its `Market` gained the
    ///      `reservePool` field, and the new router decodes markets through it — then the router.
    ///      Returns the fresh router implementation for the caller's own assertions.
    function _upgradePair() internal returns (address freshRouter) {
        address factoryBefore = address(uint160(uint256(vm.load(FACTORY, IMPL_SLOT))));
        console.log("factory impl before:", factoryBefore);
        address freshFactory = address(new AssetMarketFactory());
        freshRouter = address(new MarketRouter());
        vm.prank(SAFE);
        factory.upgradeToAndCall(freshFactory, "");
        vm.prank(ROUTER_OWNER);
        router.upgradeToAndCall(freshRouter, "");
        assertTrue(freshFactory != factoryBefore, "the factory implementation moved");
    }

    function test_theUpgradeLandsAndLeavesEveryOtherAnswerWhereItWas() public {
        address routerBefore = address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));
        console.log("router implementation before:", routerBefore);

        address freshRouter = _upgradePair();

        address now_ = address(uint160(uint256(vm.load(PROXY, IMPL_SLOT))));
        console.log("router implementation after: ", now_);
        assertEq(now_, freshRouter, "the proxy points at the new implementation");
        assertTrue(now_ != routerBefore, "and it actually moved");

        // Storage is untouched on both proxies: no variable was reordered, so every wired
        // address and the owner must read back exactly as they did before. A mismatch here is a
        // layout error, which is the failure this rehearsal exists to catch before it is
        // irreversible.
        assertEq(router.owner(), ROUTER_OWNER, "owner");
        assertEq(address(router.factory()), FACTORY, "factory");
        assertEq(address(router.reservePool()), RESERVE, "reserve pool");
        assertEq(address(router.positionManager()), POSM, "position manager");
        assertEq(address(router.permit2()), PERMIT2, "permit2");
        assertEq(address(router.poolManager()), POOL_MANAGER, "pool manager");
        assertEq(factory.owner(), SAFE, "factory owner");
        assertEq(address(factory.reservePool()), RESERVE, "factory default reserve");
    }

    /// @notice The point of the upgrade: the stable side is pulled as brandUSD, not as USDG.
    function test_seedLiquidityPullsTheBrandAndNotTheReserveAsset() public {
        _upgradePair();

        uint256 count = factory.marketCount();
        console.log("markets on mainnet:", count);
        if (count == 0) {
            // Nothing to seed into. The upgrade itself is still proven above; say so rather than
            // pass silently on a check that never ran.
            console.log("no market to seed; skipping the pull check");
            return;
        }

        AssetMarketFactory.Market memory m = factory.market(1);
        address seeder = address(0xBEEF);

        // Brand straight into the seeder's hands, so the only approval in this test is the brand
        // one. If the implementation still pulled USDG the call would revert for want of an
        // allowance, which is exactly the production failure being ruled out.
        deal(m.brandToken, seeder, 1_000e6, true);
        deal(m.asset, seeder, 1_000e18, true);

        vm.startPrank(seeder);
        IERC20(m.brandToken).approve(PROXY, 1_000e6);
        IERC20(m.asset).approve(PROXY, 1_000e18);
        (, uint128 liquidityAdded, uint256 brandUsed,) =
            router.seedLiquidity(1, 1_000e6, 1_000e18, 0, 0, block.timestamp + 600);
        vm.stopPrank();

        assertGt(liquidityAdded, 0, "the position was minted");
        assertGt(brandUsed, 0, "and the brand side is what paid for it");
    }

    /// @notice The sell path after the upgrade, end to end on a live market: the trade pays out
    ///         the market's own dollar, and the seller reaches USDG by redeeming it themselves.
    function test_sellForBrandPaysTheBrandAndTheSellerRedeemsItAtPar() public {
        _upgradePair();

        if (factory.marketCount() == 0) {
            console.log("no market to trade; skipping the sell check");
            return;
        }

        AssetMarketFactory.Market memory m = factory.market(1);
        SharedReservePool reserve = SharedReservePool(RESERVE);
        address seller = address(0xF00D);
        address usdg = address(reserve.asset());

        // Seed the market first, so there is depth on both sides to sell into. The market may or
        // may not already carry liquidity on chain; adding our own makes the assertion about the
        // router rather than about whatever a stranger happened to leave in the pool.
        deal(m.brandToken, seller, 10_000e6, true);
        deal(m.asset, seller, 10_000e18, true);
        vm.startPrank(seller);
        IERC20(m.brandToken).approve(PROXY, 10_000e6);
        IERC20(m.asset).approve(PROXY, 10_000e18);
        router.seedLiquidity(1, 5_000e6, 5_000e18, 0, 0, block.timestamp + 600);

        uint256 assetIn = 100e18;
        IERC20(m.asset).approve(PROXY, assetIn);
        uint256 usdgBefore = IERC20(usdg).balanceOf(seller);
        uint256 brandOut = router.sellForBrand(1, assetIn, 1, seller, block.timestamp + 600);

        assertGt(brandOut, 0, "the sale filled");
        assertEq(IERC20(usdg).balanceOf(seller), usdgBefore, "and paid no USDG doing it");

        // The half that moved out of the router. Permissionless, at par, and the seller's call.
        uint256 usdgOut = reserve.redeem(m.brandToken, brandOut, seller);
        vm.stopPrank();

        assertEq(usdgOut, brandOut, "the redeem is 1:1");
        assertEq(IERC20(usdg).balanceOf(seller) - usdgBefore, usdgOut, "and it landed");
    }

    /// @notice The old selector is gone, not merely renamed. A frontend that was not redeployed
    ///         alongside this upgrade fails loudly on its next sell rather than trading wrongly.
    function test_theOldSellForUsdgSelectorNoLongerAnswers() public {
        _upgradePair();

        bytes memory oldCall = abi.encodeWithSignature(
            "sellForUsdg(uint256,uint256,uint256,address,uint256)",
            uint256(1),
            uint256(1e18),
            uint256(0),
            address(0xF00D),
            block.timestamp + 600
        );
        (bool ok,) = PROXY.call(oldCall);
        assertFalse(ok, "the replaced selector must not still be callable");
    }
}
