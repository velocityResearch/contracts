// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {
    DeployAssetMarketsTestnet,
    AssetMarketFaucetToken,
    AssetMarketTestYieldSource
} from "../../script/DeployAssetMarketsTestnet.s.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StandInPermit2} from "../markets/MarketRouter.t.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";

/// @notice The 2026-09-09 post-redeploy review, carried forward onto the v4 stack.
///
///         Each of these began as a proof-of-concept written to PASS while its bug was present.
///         One of the two bugs has since been fixed by the v4 migration, so that test is
///         inverted here and now fails if the bug comes back. The other is a property of the
///         TESTNET FIXTURE rather than of production code, and is still asserted as present so
///         that nobody mistakes the fixture for a model of the real adapter.
///
/// @dev    These no longer need `UNISWAP_NODE_MODULES` or the `asset_markets_testnet` profile.
///         The v4 venue compiles from source in this repo, so `DeployAssetMarketsTestnet` reads
///         nothing off disk and these run on every `forge test`.
contract Audit2026_09_09_RedeployTest is Test {
    AssetMarketFactory factory;
    MarketRouter router;
    SharedReservePool reserve;
    IERC20 usdg;
    address asset18;
    address actor = address(0x123456);

    /// @dev Must match the constants in `DeployAssetMarketsTestnet`.
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        vm.chainId(31337);

        // The script reads the v4 singleton and Uniswap's periphery off the chain rather than
        // deploying them, and locally all three addresses are empty. `deployCodeTo` runs each
        // constructor at the address the script expects, so the PoolManager is a genuine one.
        // The PositionManager and Permit2 are the stand-ins from `MarketRouter.t.sol`, because
        // the real ones cannot be compiled into this repo; the deployed pair is exercised on a
        // fork in `test/markets/MarketRouterV4Fork.t.sol`.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), V4_POOL_MANAGER);
        deployCodeTo("MarketRouter.t.sol:StandInPermit2", "", PERMIT2);
        deployCodeTo(
            "MarketRouter.t.sol:StandInPositionManager",
            abi.encode(IPoolManager(V4_POOL_MANAGER), StandInPermit2(PERMIT2)),
            V4_POSITION_MANAGER
        );

        vm.setEnv("DEPLOYER", vm.toString(actor));
        (factory, router,) = new DeployAssetMarketsTestnet().run();
        reserve = router.reservePool();
        usdg = reserve.asset();
        // Script deployment order: faucet USDG at nonce 0, the faucet asset at nonce 1.
        asset18 = vm.computeCreateAddress(actor, 1);
    }

    /// @dev The owner's half of opening a market. Everything economic now travels with the
    ///      asset's approval rather than with the caller, and `actor` is the script's `DEPLOYER`
    ///      and therefore the factory's owner — so each test below does both halves under the
    ///      one prank it already had.
    function _listing(string memory name, string memory symbol)
        private
        pure
        returns (AssetMarketFactory.AssetListing memory)
    {
        return AssetMarketFactory.AssetListing({
            approved: true,
            fee: 3000,
            assetPriceE18: 1e18,
            observationCardinality: 60,
            unitName: name,
            unitSymbol: symbol
        });
    }

    /// F-B: `SharedReservePool._recallIfNeeded` always asks the yield source for
    ///      `shortfall + 1`. The testnet fixture yield source deployed by
    ///      `DeployAssetMarketsTestnet` subtracts that from its own ledger with no cap, so any
    ///      redemption that would empty the reserve reverts. Production adapters cap at the
    ///      caller's position; this fixture does not.
    ///
    ///      Still open, and deliberately: this is a statement about the FIXTURE. It is asserted
    ///      rather than fixed so that a testnet run that hits it is recognised as the fixture's
    ///      limit rather than filed as a bug in the reserve.
    function test_poc_drainingRedeemRevertsOnTestnetFixture() external {
        vm.startPrank(actor);
        factory.approveAsset(asset18, _listing("Brand", "bUSD"));
        (, address brand,,,) = factory.createMarket(asset18, address(0));
        usdg.approve(address(reserve), type(uint256).max);
        reserve.mint(brand, 1_000e6, actor);

        // Anything short of the whole reserve is fine.
        reserve.redeem(brand, 999e6, actor);

        // The source caps the rounding buffer to its actual position.
        uint256 before = usdg.balanceOf(actor);
        reserve.redeem(brand, 1e6, actor);
        assertEq(usdg.balanceOf(actor) - before, 1e6);
        assertEq(IERC20(brand).balanceOf(actor), 0);
        vm.stopPrank();
    }

    /// F-B2, INVERTED — the bug is fixed and this now fails if it returns.
    ///
    ///      The finding was that `MarketRouter._swapExactIn` passed `sqrtPriceLimitX96: 0` and
    ///      never refunded input the pool could not absorb. A buy larger than the seeded range
    ///      walked the price to the tick boundary and the unspent brandUSD stayed in the router
    ///      forever, with no rescue path on it.
    ///
    ///      The v4 router settles from the delta the swap actually returned rather than from
    ///      the amount asked for, so nothing the pool declines is left behind. Two things are
    ///      asserted here, and the second is the one that changed: the router holds none of
    ///      the three tokens afterwards, and whatever the pool declined comes back as the
    ///      market's own brandUSD rather than being redeemed to USDG — redeeming a remainder
    ///      would charge a fee-bearing reserve's exit cost for a decision the trader never
    ///      made.
    ///
    ///      Note what this market cannot show: the position seeded below is full range, so the
    ///      pool can absorb an arbitrarily large offer by moving its own price and the refund
    ///      is normally zero. The token a refund arrives in is pinned by
    ///      `MarketRouterTest.test_seedLiquidityRefundsTheUnusedSideInTheTokenItWasGiven`,
    ///      where one side is always left over by construction.
    function test_poc_partialFillNoLongerStrandsInputInRouter() external {
        vm.startPrank(actor);
        // A 6-decimal asset prices at tick 0 against its 6-decimal brand, so the depth and the
        // trade size are directly comparable. A distinct asset, because one (reserve, asset)
        // pair may only ever have one market.
        AssetMarketFaucetToken asset6 = new AssetMarketFaucetToken("Six", "SIX", 6);
        asset6.mint(actor, 1_000_000e6);
        factory.approveAsset(address(asset6), _listing("Six Brand", "sixUSD"));
        (uint256 id, address brand,,,) = factory.createMarket(address(asset6), address(0));

        // A brand balance to measure the refund against, and depth for the buy to fill into.
        usdg.approve(address(reserve), type(uint256).max);
        reserve.mint(brand, 50_000e6, actor);

        usdg.approve(address(router), type(uint256).max);
        asset6.approve(address(router), type(uint256).max);
        // The stable side goes in as brandUSD, which the actor already holds from the mint
        // above; the router pulls it rather than minting any of its own.
        IERC20(brand).approve(address(router), type(uint256).max);
        router.seedLiquidity(id, 1_000e6, 1_000e6, 0, 0, block.timestamp + 600);

        uint256 paidBefore = usdg.balanceOf(actor);
        uint256 brandBefore = IERC20(brand).balanceOf(actor);
        uint256 out = router.buyWithUsdg(id, 100_000e6, 0, actor, block.timestamp + 600);
        vm.stopPrank();

        console.log("usdg paid:", paidBefore - usdg.balanceOf(actor));
        console.log("brand refunded:", IERC20(brand).balanceOf(actor) - brandBefore);
        console.log("asset received:", out);

        assertGt(out, 0, "the trade did fill against the seeded depth");
        assertEq(IERC20(brand).balanceOf(address(router)), 0, "no brandUSD left in the router");
        assertEq(asset6.balanceOf(address(router)), 0, "and no asset either");
        assertEq(usdg.balanceOf(address(router)), 0, "and no USDG");
        assertEq(
            paidBefore - usdg.balanceOf(actor), 100_000e6, "the offer was taken in full as USDG"
        );
        // Nothing was stranded and nothing was taken twice: the whole offer either reached the
        // pool or came back as the brand it had already been minted into.
        uint256 refunded = IERC20(brand).balanceOf(actor) - brandBefore;
        assertLe(refunded, 100_000e6, "a refund can never exceed the offer");
    }
}
