// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {IAcrossSpokePool} from "../../src/interfaces/IAcrossSpokePool.sol";
import {IStakedUSDai} from "../../src/interfaces/IStakedUSDai.sol";

/// @notice `SUSDaiHub` against the live Arbitrum state it will run on: the real sUSDai, the
///         real Curve sUSDai/USDC pool and the real Across SpokePool. Nothing is mocked; only
///         the hub is deployed, and the USDC it trades is `deal`ed in. What this proves that
///         the unit tests cannot: the coin order `initialize` discovers, what a round trip
///         through Curve actually costs, that the NAV floors sit under the real quotes, and
///         that the SpokePool accepts the exact `depositV3` the hub emits.
///
///         Reproduce:
///         forge test --match-contract SUSDaiHubArbitrumFork -vv
///         Set `ARBITRUM_RPC_URL` to use a private endpoint; otherwise the public one is used.
///         The public RPC is not an archive node, so no block is pinned and the exact numbers
///         drift with the pool; the assertions are on bounds, the numbers are logged.
contract SUSDaiHubArbitrumForkTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;
    address constant CURVE = 0xa7CF5543a27BaDC3a74d51EA0A02E84799140E4E;
    address constant SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    uint256 constant HOME_CHAIN_ID = 4663;
    address constant HOME_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ADAPTER = address(0xADA0);

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);

    SUSDaiHub hub;
    IStakedUSDai susdai = IStakedUSDai(SUSDAI);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        hub = SUSDaiHub(
            address(
                new ERC1967Proxy(
                    address(new SUSDaiHub()),
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (USDC, SUSDAI, CURVE, SPOKE_POOL, HOME_CHAIN_ID, HOME_USDG, owner, keeper)
                    )
                )
            )
        );
        vm.prank(owner);
        hub.setHomeReceiver(ADAPTER);
        vm.prank(owner);
        hub.setMaxBridgeAmount(100_000e6);
        // These measure the live venue, not the rate limit, so the rolling budget is sized out
        // of the way; it is exercised in `test/audit/Audit2026_09_15_ReserveFixes.t.sol`.
        vm.prank(owner);
        hub.setSwapBudget(1_000_000e6, 1 days);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _lessBps(uint256 x, uint256 bps) internal pure returns (uint256) {
        return x - x * bps / 10_000;
    }

    /// @dev Buy with `usdcIn` at the pool's own quote less 5 bps, as the keeper would.
    function _buy(uint256 usdcIn) internal returns (uint256 sharesOut) {
        uint256 quoted = hub.quoteBuy(usdcIn);
        uint256 minOut = _lessBps(quoted, 5);
        vm.prank(keeper);
        sharesOut = hub.buyShares(usdcIn, minOut);
    }

    function _quote(uint256 outputAmount, uint32 quoteTimestamp)
        internal
        view
        returns (AcrossBridger.AcrossQuote memory)
    {
        return AcrossBridger.AcrossQuote({
            outputAmount: outputAmount,
            exclusiveRelayer: address(0),
            quoteTimestamp: quoteTimestamp,
            fillDeadline: uint32(block.timestamp + 2 hours),
            exclusivityDeadline: 0
        });
    }

    // ─── Tests ───────────────────────────────────────────────────────────

    function test_fork_constructor_discoversCoinOrderFromTheRealPool() public view {
        assertEq(hub.sharesIndex(), 0, "sUSDai is coin 0");
        assertEq(hub.usdcIndex(), 1, "USDC is coin 1");
    }

    function test_fork_buyThenSell_roundTripCostsAboutTwoBps() public {
        deal(USDC, address(hub), 10_000e6);
        uint256 quotedShares = hub.quoteBuy(10_000e6);

        uint256 sharesOut = _buy(10_000e6);
        assertEq(sharesOut, quotedShares, "same block: the quote is the fill");
        assertEq(hub.sharesHeld(), sharesOut);
        assertEq(hub.usdcHeld(), 0);

        uint256 quotedUsdc = hub.quoteSell(sharesOut);
        uint256 minUsdc = _lessBps(quotedUsdc, 5);
        vm.prank(keeper);
        uint256 usdcOut = hub.sellShares(sharesOut, minUsdc);

        assertEq(usdcOut, quotedUsdc, "same block: the quote is the fill");
        assertEq(hub.sharesHeld(), 0);
        assertEq(hub.usdcHeld(), usdcOut);
        uint256 cost = 10_000e6 - usdcOut;
        console.log("deposit NAV (wad)       :", susdai.depositSharePrice());
        console.log("buy 10_000 USDC -> shares:", sharesOut);
        console.log("sell all -> USDC         :", usdcOut);
        console.log("round trip cost (USDC)   :", cost);
        console.log("round trip cost (bps/100):", cost * 1_000_000 / 10_000e6);
        assertGe(cost, 1e6, "the pool fee alone is 1 bp each way");
        assertLe(cost, 5e6, "more than 5 bps means the pool is off NAV");
    }

    function test_fork_buyFloor_tracksRealDepositNav() public view {
        uint256 nav = susdai.depositSharePrice();
        uint256 atNav = hub.usdcToShares(10_000e6, nav);
        uint256 floor = hub.buyFloor(10_000e6);
        assertEq(floor, _lessBps(atNav, 15));

        uint256 quoted = hub.quoteBuy(10_000e6);
        assertGt(quoted, floor, "the live pool quotes above the floor");
        // Not `assertLt(quoted, atNav)`: the pool prices sUSDai through its own oracle rate,
        // which can sit marginally ABOVE sUSDai's `depositSharePrice` between NAV updates.
        // Measured 2026-09-15 at +0.19 bps on 10,000 USDC. What matters to the hub is that the
        // venue tracks NAV closely enough to clear the floor, which is asserted above and
        // bounded here from the other side.
        assertLt(quoted, atNav + atNav * 15 / 10_000, "the pool tracks NAV, it does not lead it");
        console.log("shares at NAV :", atNav);
        console.log("buy floor     :", floor);
        console.log("quoteBuy      :", quoted);
    }

    function test_fork_conservativeValue_marksSharesAtRedemptionNav() public {
        deal(USDC, address(hub), 10_000e6);
        uint256 shares = _buy(10_000e6);

        uint256 conservative = hub.conservativeValue();
        uint256 optimistic = hub.optimisticValue();
        console.log("redemption NAV (wad):", susdai.redemptionSharePrice());
        console.log("conservativeValue   :", conservative);
        console.log("optimisticValue     :", optimistic);

        assertEq(
            conservative,
            hub.sharesToUsdc(shares, susdai.redemptionSharePrice()) + hub.usdcHeld(),
            "shares at the redemption NAV plus USDC"
        );
        assertLt(conservative, optimistic, "the redemption NAV is the lower mark");
        assertGt(conservative, 9_900e6, "within 1% of what went in");
        assertLt(optimistic, 10_100e6, "within 1% of what went in");
        assertGt(optimistic, 9_900e6);
    }

    function test_fork_sellShares_refusesADeepDiscountMinOut() public {
        deal(USDC, address(hub), 10_000e6);
        uint256 shares = _buy(10_000e6);
        uint256 floor = hub.sellFloor(shares);
        assertGt(hub.quoteSell(shares), floor, "the live pool clears the floor");

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.MinOutBelowFloor.selector, floor - 1, floor)
        );
        hub.sellShares(shares, floor - 1);
    }

    function test_fork_bridgeHome_depositsOnTheRealSpokePool() public {
        deal(USDC, address(hub), 10_000e6);
        IAcrossSpokePool spoke = IAcrossSpokePool(SPOKE_POOL);
        uint32 before = spoke.numberOfDeposits();
        uint256 escrowBefore = IERC20(USDC).balanceOf(SPOKE_POOL);
        uint256 outputAmount = _lessBps(10_000e6, 6);
        AcrossBridger.AcrossQuote memory q = _quote(outputAmount, uint32(block.timestamp));

        vm.prank(keeper);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.BridgedHome(before, 10_000e6, outputAmount);
        uint32 depositId = hub.bridgeHome(10_000e6, q);

        assertEq(depositId, before, "the id is the counter before the deposit");
        assertEq(spoke.numberOfDeposits(), before + 1);
        assertEq(hub.usdcHeld(), 0, "all of it left");
        assertEq(IERC20(USDC).balanceOf(SPOKE_POOL), escrowBefore + 10_000e6, "escrowed");
        console.log("depositId:", depositId);
    }

    function test_fork_bridgeHome_realPoolRejectsAStaleQuoteTimestamp() public {
        deal(USDC, address(hub), 10_000e6);
        uint32 stale =
            uint32(block.timestamp) - IAcrossSpokePool(SPOKE_POOL).depositQuoteTimeBuffer() - 1;
        AcrossBridger.AcrossQuote memory q = _quote(_lessBps(10_000e6, 6), stale);

        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("InvalidQuoteTimestamp()")));
        hub.bridgeHome(10_000e6, q);
        assertEq(hub.usdcHeld(), 10_000e6, "nothing left");
    }

    function test_fork_largeSell_showsCurveCurvature() public {
        deal(USDC, address(hub), 100_000e6);
        uint256 shares = _buy(100_000e6);

        uint256 wholeQuote = hub.quoteSell(shares);
        uint256 tenthQuote = hub.quoteSell(shares / 10);
        uint256 linear = tenthQuote * 10;
        console.log("shares held              :", shares);
        console.log("quoteSell(all)           :", wholeQuote);
        console.log("10 x quoteSell(tenth)    :", linear);
        console.log("curvature (bps of linear):", (linear - wholeQuote) * 10_000 / linear);
        assertLt(wholeQuote, linear, "a big sell pays more than ten small ones");
    }
}
