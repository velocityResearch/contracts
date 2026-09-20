// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {SUSDaiHub} from "../../src/susdai/SUSDaiHub.sol";
import {AcrossBridger} from "../../src/susdai/AcrossBridger.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockStakedUSDai} from "../mocks/MockStakedUSDai.sol";
import {MockCurveStableSwapNG} from "../mocks/MockCurveStableSwapNG.sol";
import {MockAcrossSpokePool} from "../mocks/MockAcrossSpokePool.sol";

/// @dev An 18-decimal stand-in for a token the hub expects to be 6 decimals.
contract Token18 is ERC20 {
    constructor() ERC20("Eighteen", "E18") {}
}

/// @dev Just enough of a Curve pool for the constructor's coin-order discovery: the mock pool
///      hardcodes coin 0 = shares, so a reversed order or a third coin needs its own stub.
contract CoinsOnlyPool {
    address[] private _coins;
    uint256 private immutable _n;

    constructor(address[] memory coins_, uint256 n_) {
        _coins = coins_;
        _n = n_;
    }

    function coins(uint256 i) external view returns (address) {
        return _coins[i];
    }

    function N_COINS() external view returns (uint256) {
        return _n;
    }
}

/// @dev A `SUSDaiHub` with one added function and one added storage variable, used to prove an
///      upgrade both preserves the collateral position and can extend the layout.
contract SUSDaiHubV2 is SUSDaiHub {
    /// @dev Appended after the parent's `__gap`, which is what makes this safe.
    string public upgradeNote;

    function setUpgradeNote(string calldata note) external {
        upgradeNote = note;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice `SUSDaiHub` against mocks: what the keeper may and may not do with the USDC that
///         lands on Arbitrum, and what the adapter reads back.
contract SUSDaiHubTest is Test {
    uint256 constant HOME_CHAIN_ID = 4663;
    address constant HOME_USDG = address(0x05D6);
    address constant ADAPTER = address(0xADA0);
    address constant USDAI = address(0x05DA1);

    MockUSDC usdc;
    MockStakedUSDai susdai;
    MockCurveStableSwapNG curve;
    MockAcrossSpokePool spoke;
    SUSDaiHub hub;
    /// @dev Deployed once and reused: `_newHub` must perform exactly ONE contract creation, so
    ///      that a `vm.expectRevert` written immediately before it binds to the proxy whose
    ///      initializer is under test and not to a fresh implementation that succeeds.
    address hubImpl;

    address owner = address(0x0AD01);
    address keeper = address(0xC0FFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        hubImpl = address(new SUSDaiHub());
        usdc = new MockUSDC();
        susdai = new MockStakedUSDai(USDAI);
        // Rate = the deposit NAV the mock sUSDai reports, so the pool trades at NAV less 1 bp.
        curve = new MockCurveStableSwapNG(address(susdai), address(usdc), 1.1e18, 1);
        usdc.mint(address(curve), 10_000_000e6);
        susdai.mint(address(curve), 10_000_000e18);
        spoke = new MockAcrossSpokePool();
        hub = _newHub(address(usdc), address(susdai), address(curve));
        vm.prank(owner);
        hub.setHomeReceiver(ADAPTER);
        vm.prank(owner);
        hub.setMaxBridgeAmount(100_000e6);
        vm.warp(1_800_000_000);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _newHub(address usdc_, address susdai_, address curve_) internal returns (SUSDaiHub) {
        return _newHub(usdc_, susdai_, curve_, address(spoke), HOME_USDG, keeper);
    }

    /// @dev A `SUSDaiHub` proxy. Arguments are `initialize`'s, so a caller reads the same
    ///      wiring it used to pass to the constructor.
    function _newHub(
        address usdc_,
        address susdai_,
        address curve_,
        address spokePool_,
        address homeUsdg_,
        address keeper_
    ) internal returns (SUSDaiHub) {
        return SUSDaiHub(
            address(
                new ERC1967Proxy(
                    hubImpl,
                    abi.encodeCall(
                        SUSDaiHub.initialize,
                        (
                            usdc_,
                            susdai_,
                            curve_,
                            spokePool_,
                            HOME_CHAIN_ID,
                            homeUsdg_,
                            owner,
                            keeper_
                        )
                    )
                )
            )
        );
    }

    function _quote(uint256 outputAmount) internal view returns (AcrossBridger.AcrossQuote memory) {
        return AcrossBridger.AcrossQuote({
            outputAmount: outputAmount,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityDeadline: 0
        });
    }

    function _notOwner(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
    }

    // ─── Initialisation ──────────────────────────────────────────────────

    function test_initialize_rejectsZeroAddresses() public {
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(address(0), address(susdai), address(curve));
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(address(usdc), address(0), address(curve));
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(address(usdc), address(susdai), address(0));
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(address(usdc), address(susdai), address(curve), address(0), HOME_USDG, keeper);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(address(usdc), address(susdai), address(curve), address(spoke), address(0), keeper);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        _newHub(
            address(usdc), address(susdai), address(curve), address(spoke), HOME_USDG, address(0)
        );
    }

    function test_initialize_rejectsAPoolThatDoesNotTradeSusdaiForUsdc() public {
        MockUSDC other = new MockUSDC();
        MockCurveStableSwapNG wrongPair =
            new MockCurveStableSwapNG(address(other), address(usdc), 1e18, 1);
        vm.expectRevert(SUSDaiHub.WrongCurveCoins.selector);
        _newHub(address(usdc), address(susdai), address(wrongPair));

        address[] memory three = new address[](3);
        three[0] = address(susdai);
        three[1] = address(usdc);
        three[2] = address(other);
        CoinsOnlyPool threeCoins = new CoinsOnlyPool(three, 3);
        vm.expectRevert(SUSDaiHub.WrongCurveCoins.selector);
        _newHub(address(usdc), address(susdai), address(threeCoins));
    }

    function test_initialize_discoversCoinOrderEitherWay() public {
        assertEq(hub.sharesIndex(), 0, "shares first");
        assertEq(hub.usdcIndex(), 1);

        address[] memory reversed = new address[](2);
        reversed[0] = address(usdc);
        reversed[1] = address(susdai);
        CoinsOnlyPool pool = new CoinsOnlyPool(reversed, 2);
        SUSDaiHub flipped = _newHub(address(usdc), address(susdai), address(pool));
        assertEq(flipped.sharesIndex(), 1, "usdc first");
        assertEq(flipped.usdcIndex(), 0);
    }

    function test_initialize_rejectsUnexpectedDecimals() public {
        Token18 usdc18 = new Token18();
        MockCurveStableSwapNG pool18 =
            new MockCurveStableSwapNG(address(susdai), address(usdc18), 1.1e18, 1);
        vm.expectRevert(SUSDaiHub.UnexpectedDecimals.selector);
        _newHub(address(usdc18), address(susdai), address(pool18));

        MockUSDC shares6 = new MockUSDC();
        MockCurveStableSwapNG pool6 =
            new MockCurveStableSwapNG(address(shares6), address(usdc), 1.1e18, 1);
        vm.expectRevert(SUSDaiHub.UnexpectedDecimals.selector);
        _newHub(address(usdc), address(shares6), address(pool6));
    }

    // ─── buyShares ───────────────────────────────────────────────────────

    function test_buyShares_floorIsNavLessSlippageAndIsInclusive() public {
        usdc.mint(address(hub), 1_000e6);
        // 1_000 USDC at 1.1 = 909.0909... shares, less 15 bps.
        uint256 floor = hub.buyFloor(1_000e6);
        assertEq(floor, 907_727_272_727_272_727_273);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.MinOutBelowFloor.selector, floor - 1, floor)
        );
        hub.buyShares(1_000e6, floor - 1);

        vm.prank(keeper);
        uint256 out = hub.buyShares(1_000e6, floor);
        assertEq(out, 909e18, "NAV less the pool's 1 bp");
    }

    function test_buyShares_executesAtThePoolRateAndEmits() public {
        usdc.mint(address(hub), 1_000e6);
        assertEq(hub.quoteBuy(1_000e6), 909e18);

        vm.prank(keeper);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.SharesBought(1_000e6, 909e18);
        uint256 out = hub.buyShares(1_000e6, 909e18);

        assertEq(out, 909e18);
        assertEq(hub.sharesHeld(), 909e18);
        assertEq(hub.usdcHeld(), 0);
        assertEq(usdc.balanceOf(address(curve)), 10_000_000e6 + 1_000e6);
    }

    function test_buyShares_rejectsZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(AcrossBridger.ZeroAmount.selector);
        hub.buyShares(0, 0);
    }

    function test_buyShares_poolSlippageRevertPropagates() public {
        usdc.mint(address(hub), 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(bytes("slippage"));
        hub.buyShares(1_000e6, 909e18 + 1);
    }

    // ─── sellShares ──────────────────────────────────────────────────────

    function test_sellShares_floorIsNavLessSlippageAndIsInclusive() public {
        susdai.mint(address(hub), 1_000e18);
        uint256 floor = hub.sellFloor(1_000e18);
        assertEq(floor, 1_098_350_000, "1_100 USDC less 15 bps");

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.MinOutBelowFloor.selector, floor - 1, floor)
        );
        hub.sellShares(1_000e18, floor - 1);

        vm.prank(keeper);
        uint256 out = hub.sellShares(1_000e18, floor);
        assertEq(out, 1_099_890_000, "1_100 USDC less the pool's 1 bp");
    }

    function test_sellShares_executesAtThePoolRateAndEmits() public {
        susdai.mint(address(hub), 1_000e18);
        assertEq(hub.quoteSell(1_000e18), 1_099_890_000);

        vm.prank(keeper);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.SharesSold(1_000e18, 1_099_890_000);
        uint256 out = hub.sellShares(1_000e18, 1_099_890_000);

        assertEq(out, 1_099_890_000);
        assertEq(hub.sharesHeld(), 0);
        assertEq(hub.usdcHeld(), 1_099_890_000);
    }

    function test_sellShares_rejectsZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(AcrossBridger.ZeroAmount.selector);
        hub.sellShares(0, 0);
    }

    function test_sellShares_poolSlippageRevertPropagates() public {
        susdai.mint(address(hub), 1_000e18);
        vm.prank(keeper);
        vm.expectRevert(bytes("slippage"));
        hub.sellShares(1_000e18, 1_099_890_000 + 1);
    }

    function test_sellShares_aPoolDiscountBeyondTheLimitIsRefusedUntilTheOwnerWidensIt() public {
        susdai.mint(address(hub), 1_000e18);
        curve.setRate(1.089e18); // 1% under the 1.1 NAV
        uint256 quoted = hub.quoteSell(1_000e18);
        assertEq(quoted, 1_088_891_100);

        // The keeper's min-out matches what the pool would pay, but it is under the floor.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.MinOutBelowFloor.selector, quoted, 1_098_350_000)
        );
        hub.sellShares(1_000e18, quoted);

        vm.prank(owner);
        hub.setLimits(200, 20);
        assertEq(hub.sellFloor(1_000e18), 1_078e6);

        vm.prank(keeper);
        assertEq(hub.sellShares(1_000e18, quoted), quoted);
    }

    // ─── setLimits ───────────────────────────────────────────────────────

    function test_setLimits_ownerOnlyAndBounded() public {
        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        hub.setLimits(10, 10);

        vm.prank(owner);
        vm.expectRevert(SUSDaiHub.LimitOutOfRange.selector);
        hub.setLimits(501, 20);

        vm.prank(owner);
        vm.expectRevert(SUSDaiHub.LimitOutOfRange.selector);
        hub.setLimits(50, 101);

        vm.prank(owner);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.LimitsUpdated(500, 100);
        hub.setLimits(500, 100);
        assertEq(hub.maxSwapSlippageBps(), 500);
        assertEq(hub.maxBridgeFeeBps(), 100);
    }

    function test_setMaxBridgeAmount_defaultsClosed_isOwnerOnly_andCapsEachDeposit() public {
        SUSDaiHub fresh = _newHub(address(usdc), address(susdai), address(curve));
        vm.prank(owner);
        fresh.setHomeReceiver(ADAPTER);
        usdc.mint(address(fresh), 2_000e6);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SUSDaiHub.BridgeAmountAboveCap.selector, 1_000e6, 0));
        fresh.bridgeHome(1_000e6, _quote(999e6));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setMaxBridgeAmount(1_000e6);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit SUSDaiHub.MaxBridgeAmountUpdated(0, 1_000e6);
        fresh.setMaxBridgeAmount(1_000e6);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SUSDaiHub.BridgeAmountAboveCap.selector, 1_000e6 + 1, 1_000e6)
        );
        fresh.bridgeHome(1_000e6 + 1, _quote(999e6));

        vm.prank(keeper);
        fresh.bridgeHome(1_000e6, _quote(999e6));
        assertEq(spoke.lastDeposit().inputAmount, 1_000e6);
    }

    // ─── bridgeHome ──────────────────────────────────────────────────────

    function test_bridgeHome_refusesUntilAReceiverIsSet() public {
        SUSDaiHub fresh = _newHub(address(usdc), address(susdai), address(curve));
        vm.prank(owner);
        fresh.setMaxBridgeAmount(1_000e6);
        usdc.mint(address(fresh), 1_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(999e6);
        vm.prank(keeper);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        fresh.bridgeHome(1_000e6, q);
    }

    function test_bridgeHome_depositsExactlyWhatTheAdapterExpects() public {
        usdc.mint(address(hub), 5_000e6);
        AcrossBridger.AcrossQuote memory q = _quote(4_997e6); // 6 bps
        q.exclusiveRelayer = address(0xE0);
        q.exclusivityDeadline = 30;

        vm.prank(keeper);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.BridgedHome(0, 5_000e6, 4_997e6);
        uint32 depositId = hub.bridgeHome(5_000e6, q);

        assertEq(depositId, 0);
        assertEq(hub.usdcHeld(), 0);
        assertEq(usdc.balanceOf(address(spoke)), 5_000e6, "escrowed");

        MockAcrossSpokePool.Deposit memory d = spoke.lastDeposit();
        assertEq(d.depositor, address(hub), "refunds return to the hub");
        assertEq(d.recipient, ADAPTER, "only the adapter receives");
        assertEq(d.inputToken, address(usdc));
        assertEq(d.outputToken, HOME_USDG, "only USDG is delivered");
        assertEq(d.inputAmount, 5_000e6);
        assertEq(d.outputAmount, 4_997e6);
        assertEq(d.destinationChainId, HOME_CHAIN_ID);
        assertEq(d.exclusiveRelayer, address(0xE0));
        assertEq(d.quoteTimestamp, uint32(block.timestamp));
        assertEq(d.fillDeadline, uint32(block.timestamp + 1 hours));
        assertEq(d.exclusivityDeadline, 30);
        assertEq(d.message.length, 0);

        usdc.mint(address(hub), 1e6);
        vm.prank(keeper);
        assertEq(hub.bridgeHome(1e6, _quote(1e6)), 1, "ids follow the pool's counter");
    }

    function test_bridgeHome_feeFloorIsInclusive() public {
        usdc.mint(address(hub), 10_000e6);
        // Default 20 bps: floor on 5_000 USDC is 4_990 USDC.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                AcrossBridger.BridgeOutputBelowFloor.selector, 4_989_999_999, 4_990e6
            )
        );
        hub.bridgeHome(5_000e6, _quote(4_989_999_999));

        vm.prank(keeper);
        hub.bridgeHome(5_000e6, _quote(4_990e6));
        assertEq(spoke.lastDeposit().outputAmount, 4_990e6);

        vm.prank(keeper);
        vm.expectRevert(AcrossBridger.ZeroAmount.selector);
        hub.bridgeHome(0, _quote(0));
    }

    // ─── Pause ───────────────────────────────────────────────────────────

    function test_pause_haltsTheKeeperButNotTheReporting() public {
        usdc.mint(address(hub), 1_000e6);
        susdai.mint(address(hub), 1_000e18);

        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        hub.pause();

        vm.prank(owner);
        hub.pause();

        AcrossBridger.AcrossQuote memory q = _quote(999e6);
        vm.startPrank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hub.buyShares(1_000e6, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hub.sellShares(1_000e18, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hub.bridgeHome(1_000e6, q);
        vm.stopPrank();

        // 1_000 shares at the 1.095 redemption NAV + 1_000 USDC.
        assertEq(hub.conservativeValue(), 2_095e6, "the adapter can still sync");
        assertEq(hub.quoteBuy(1_000e6), 909e18);

        vm.prank(owner);
        hub.unpause();
        vm.prank(keeper);
        assertEq(hub.buyShares(1_000e6, 909e18), 909e18);
    }

    // ─── Access ──────────────────────────────────────────────────────────

    function test_keeperFunctions_rejectStrangersAndAdmitTheOwner() public {
        usdc.mint(address(hub), 2_000e6);
        susdai.mint(address(hub), 1_000e18);
        AcrossBridger.AcrossQuote memory q = _quote(999e6);

        vm.startPrank(alice);
        vm.expectRevert(SUSDaiHub.NotKeeper.selector);
        hub.buyShares(1_000e6, 909e18);
        vm.expectRevert(SUSDaiHub.NotKeeper.selector);
        hub.sellShares(1_000e18, 1_099_890_000);
        vm.expectRevert(SUSDaiHub.NotKeeper.selector);
        hub.bridgeHome(1_000e6, q);
        vm.stopPrank();

        vm.startPrank(owner);
        assertEq(hub.buyShares(1_000e6, 909e18), 909e18);
        assertEq(hub.sellShares(1_000e18, 1_099_890_000), 1_099_890_000);
        assertEq(hub.bridgeHome(1_000e6, q), 0);
        vm.stopPrank();
    }

    function test_setKeeper_ownerOnlyNonZeroAndRotatesAuthority() public {
        address next = address(0xBEEF);
        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        hub.setKeeper(next);

        vm.prank(owner);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        hub.setKeeper(address(0));

        vm.prank(owner);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.KeeperUpdated(keeper, next);
        hub.setKeeper(next);
        assertEq(hub.keeper(), next);

        usdc.mint(address(hub), 2_000e6);
        vm.prank(keeper);
        vm.expectRevert(SUSDaiHub.NotKeeper.selector);
        hub.buyShares(1_000e6, 909e18);
        vm.prank(next);
        assertEq(hub.buyShares(1_000e6, 909e18), 909e18);
    }

    function test_setHomeReceiver_ownerOnlyNonZeroAndRedirectsTheBridge() public {
        address next = address(0xADA1);
        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        hub.setHomeReceiver(next);

        vm.prank(owner);
        vm.expectRevert(AcrossBridger.ZeroAddress.selector);
        hub.setHomeReceiver(address(0));

        vm.prank(owner);
        vm.expectEmit(address(hub));
        emit SUSDaiHub.HomeReceiverUpdated(ADAPTER, next);
        hub.setHomeReceiver(next);
        assertEq(hub.homeReceiver(), next);

        usdc.mint(address(hub), 1_000e6);
        vm.prank(keeper);
        hub.bridgeHome(1_000e6, _quote(999e6));
        assertEq(spoke.lastDeposit().recipient, next);
    }

    // ─── Views ───────────────────────────────────────────────────────────

    function test_values_markSharesAtTheRightNavAndRoundDown() public {
        // The live prices on 2026-09-13 and an awkward share count, so nothing divides evenly:
        // 1234.567890123456789012 shares at 1.10721 = 1366.9259136..., at 1.11217 = 1373.0493703...
        susdai.setSharePrices(1.11217e18, 1.10721e18);
        susdai.mint(address(hub), 1_234_567_890_123_456_789_012);
        usdc.mint(address(hub), 500e6);

        assertEq(hub.conservativeValue(), 1_366_925_913 + 500e6, "redemption NAV, rounded down");
        assertEq(hub.optimisticValue(), 1_373_049_370 + 500e6, "deposit NAV, rounded down");
        assertLt(hub.conservativeValue(), hub.optimisticValue());
    }

    function test_conversions_roundTripLosesAtMostOneUnitOfUsdc() public view {
        // One wei of USDC at 1.1 is 0.909... shares of 1e-6 precision; back again rounds to 0.
        assertEq(hub.usdcToShares(1, 1.1e18), 909_090_909_090);
        assertEq(hub.sharesToUsdc(909_090_909_090, 1.1e18), 0);
        // At par, one wei survives the round trip exactly.
        assertEq(hub.usdcToShares(1, 1e18), 1e12);
        assertEq(hub.sharesToUsdc(1e12, 1e18), 1);
        assertEq(hub.sharesToUsdc(1e12 - 1, 1e18), 0, "sub-unit share value is dropped");
        // A whole USDC comes back one unit short.
        uint256 shares = hub.usdcToShares(1e6, 1.1e18);
        assertEq(shares, 909_090_909_090_909_090);
        assertEq(hub.sharesToUsdc(shares, 1.1e18), 999_999);
        // One share at the live redemption NAV.
        assertEq(hub.sharesToUsdc(1e18, 1.10721e18), 1_107_210);
    }

    function test_floors_trackTheDepositNavNotThePool() public {
        // Move the pool's rate: the floors do not move, they are NAV-derived.
        uint256 buyBefore = hub.buyFloor(1_000e6);
        uint256 sellBefore = hub.sellFloor(1_000e18);
        curve.setRate(1.05e18);
        assertEq(hub.buyFloor(1_000e6), buyBefore);
        assertEq(hub.sellFloor(1_000e18), sellBefore);
        assertLt(hub.quoteSell(1_000e18), sellBefore, "the pool now quotes under the floor");

        // Move the NAV: the floors follow it.
        susdai.setSharePrices(1.2e18, 1.19e18);
        assertEq(hub.buyFloor(1_200e6), 1_000e18 - 1.5e18);
        assertEq(hub.sellFloor(1_000e18), 1_200e6 - 1.8e6);
    }

    function test_quotes_areThePoolsOwnAfterFee() public view {
        assertEq(hub.quoteBuy(1_000e6), 909e18);
        assertEq(hub.quoteSell(1_000e18), 1_099_890_000);
    }

    // ─── Upgrading ───────────────────────────────────────────────────────

    /// @notice The property the conversion to UUPS exists to provide: a bug in the hub can be
    ///         fixed in ONE transaction, with no delay, while it is holding the reserve's whole
    ///         collateral position. The sUSDai shares, the USDC and the route home all have to
    ///         come through unchanged, and nobody but the owner may move the code.
    function test_ownerUpgradesInOneTransactionAndTheCollateralSurvives() public {
        usdc.mint(address(hub), 10_000e6);
        uint256 buyFloor = hub.buyFloor(6_000e6);
        vm.prank(keeper);
        hub.buyShares(6_000e6, buyFloor);

        uint256 sharesBefore = hub.sharesHeld();
        uint256 usdcBefore = hub.usdcHeld();
        uint256 valueBefore = hub.conservativeValue();
        assertGt(sharesBefore, 0, "precondition: the hub holds collateral");
        assertGt(usdcBefore, 0, "precondition: the hub holds undeployed USDC");

        address v2 = address(new SUSDaiHubV2());
        uint256 blockBefore = block.number;
        vm.prank(owner);
        hub.upgradeToAndCall(v2, "");

        assertEq(block.number, blockBefore, "no delay: the new code is live in the same block");
        assertEq(SUSDaiHubV2(address(hub)).version(), 2, "new code is live");

        assertEq(hub.sharesHeld(), sharesBefore, "the sUSDai position survived");
        assertEq(hub.usdcHeld(), usdcBefore, "the USDC survived");
        assertEq(hub.conservativeValue(), valueBefore, "what the keeper reports home is the same");
        assertEq(address(hub.usdc()), address(usdc), "wiring survived");
        assertEq(address(hub.susdai()), address(susdai));
        assertEq(address(hub.curve()), address(curve));
        assertEq(address(hub.spokePool()), address(spoke), "the bridge survived");
        assertEq(hub.sharesIndex(), 0, "the discovered coin order survived");
        assertEq(hub.usdcIndex(), 1);
        assertEq(hub.homeChainId(), HOME_CHAIN_ID);
        assertEq(hub.homeUsdg(), HOME_USDG);
        assertEq(hub.homeReceiver(), ADAPTER, "the route home survived");
        assertEq(hub.keeper(), keeper);
        assertEq(hub.maxBridgeAmount(), 100_000e6, "owner-set limits survived");
        assertEq(hub.maxSwapSlippageBps(), 15);

        // Appended state is usable and did not land on anything already there.
        SUSDaiHubV2(address(hub)).setUpgradeNote("v2");
        assertEq(SUSDaiHubV2(address(hub)).upgradeNote(), "v2");
        assertEq(hub.sharesHeld(), sharesBefore, "and still survived");

        // And the keeper can still trade it: the position is not just readable, it works.
        uint256 sellFloor = hub.sellFloor(sharesBefore);
        vm.prank(keeper);
        hub.sellShares(sharesBefore, sellFloor);
        assertEq(hub.sharesHeld(), 0, "the upgraded hub still exits through Curve");
    }

    /// @notice Upgrading is the most consequential call on this contract; the keeper is a hot
    ///         key and a stranger to it.
    function test_nobodyButTheOwnerCanUpgradeTheHub() public {
        address v2 = address(new SUSDaiHubV2());

        vm.prank(keeper);
        vm.expectRevert(_notOwner(keeper));
        hub.upgradeToAndCall(v2, "");

        vm.prank(alice);
        vm.expectRevert(_notOwner(alice));
        hub.upgradeToAndCall(v2, "");
    }
}
