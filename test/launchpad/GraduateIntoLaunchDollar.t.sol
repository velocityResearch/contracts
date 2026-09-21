// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {Vm} from "forge-std/Vm.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {ILaunchFactory} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title GraduateIntoLaunchDollarTest
/// @notice A graduation now opens a market quoted in the dollar the launch was raised in.
///
///         The design this replaces minted a `<SYM>.d` per graduation and swapped the whole
///         raise into it at the reserve, which meant every launch put a stablecoin nobody
///         asked for into the reserve's registry and left buyers trading against a unit that
///         existed in exactly one pool. What is proved here is the shape that replaced it:
///         the pool's two currencies are the two tokens that already existed, the reserve's
///         brand registry does not grow, the market is a shared quote that takes neither the
///         issuer's treasury nor `marketOfBrand`, the raise lands in the v4 singleton rather
///         than being converted on the way, and the float the seed locked is registered with
///         the dollar's own treasury so the market's LPs earn on it.
///
///         And the case the old design could not express at all: two launches on one dollar,
///         each a market of its own, each with its own float recorded against the same
///         treasury.
contract GraduateIntoLaunchDollarTest is LaunchpadFixture {
    /// @dev The `PoolGraduated` event, decoded — the only place the measured seed figures
    ///      appear, since `graduateToMarket` returns nothing.
    struct Graduated {
        address unit;
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked;
    }

    address token;
    address curve;

    function setUp() public {
        _deployLaunchpadStack();
        (token, curve) = _launch("Cashcat", "CAT");
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    function _quoteTreasury(address brand) internal view returns (PoolBrandTreasury) {
        return PoolBrandTreasury(marketFactory.treasuryOfBrand(brand));
    }

    /// @dev Phase two of `t`, with `PoolGraduated` captured.
    function _graduate(address t) internal returns (Graduated memory g) {
        vm.recordLogs();
        launchFactory.graduateToMarket(t);

        bytes32 sig = keccak256(
            "PoolGraduated(address,uint256,address,bytes32,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(launchFactory) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != t) continue;
            (g.unit, g.poolId, g.positionId, g.unitSeeded, g.tokensSeeded, g.tokensLocked) =
                abi.decode(logs[i].data, (address, bytes32, uint256, uint256, uint256, uint256));
            return g;
        }
        revert("PoolGraduated not emitted");
    }

    /// @dev Fill the default launch's curve and graduate it, returning the event and the id.
    function _runToMarket() internal returns (Graduated memory g, uint256 marketId) {
        _buyToThreshold(curve, trader);
        g = _graduate(token);
        marketId = launchFactory.getLaunchedToken(token).marketId;
    }

    /// @dev `_fundQuote`, for a brand in some other reserve.
    function _fundBrand(SharedReservePool pool, address brand, address who, uint256 amount)
        internal
    {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(pool), amount);
        pool.mint(brand, amount, who);
        vm.stopPrank();
    }

    /// @dev `_launch`, against a quote brand other than the fixture's.
    function _launchOn(
        SharedReservePool pool,
        address pairToken,
        string memory name,
        string memory symbol
    ) internal returns (address t, address c) {
        _fundBrand(pool, pairToken, creator, LAUNCH_FEE);
        vm.startPrank(creator);
        IERC20(pairToken).approve(address(launchFactory), LAUNCH_FEE);
        (t, c) = launchFactory.launchToken(
            _tokenParams(name, symbol, keccak256(bytes(symbol))),
            launchConfigId,
            pairToken,
            new address[](0)
        );
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + launchFactory.snipeTaxSeconds() + 1);
    }

    /// @dev `_buyToThreshold`, against a quote brand other than the fixture's.
    function _buyToThresholdOn(SharedReservePool pool, address pairToken, address c, address who)
        internal
    {
        uint256 amountIn = GRADUATION_THRESHOLD * 2;
        _fundBrand(pool, pairToken, who, amountIn);
        vm.startPrank(who);
        IERC20(pairToken).approve(c, amountIn);
        LaunchCurve(c).buy(amountIn, 0, who);
        vm.stopPrank();
    }

    // ─── The pool's two currencies ───────────────────────────────────────

    /// @notice The graduated pool is `launchToken / launchUSD`: the two tokens that already
    ///         existed, address-ordered, and nothing else.
    function test_graduate_quotesThePoolInTheLaunchsOwnDollar() public {
        (Graduated memory g, uint256 marketId) = _runToMarket();

        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        (address expected0, address expected1) =
            quoteBrand < token ? (quoteBrand, token) : (token, quoteBrand);
        assertEq(Currency.unwrap(key.currency0), expected0, "currency0 is one of the two");
        assertEq(Currency.unwrap(key.currency1), expected1, "currency1 is the other");

        AssetMarketFactory.Market memory m = marketFactory.market(marketId);
        assertEq(m.brandToken, quoteBrand, "the market's unit is the launch's own dollar");
        assertEq(m.asset, token, "traded against the launch token itself");
        assertEq(g.unit, quoteBrand, "and the event says the same");
    }

    /// @notice No `<SYM>.d` was minted: the reserve's brand registry is the same length it
    ///         was, the dollar still belongs to no market, and the pool's currencies carry
    ///         the two symbols that existed before the call.
    function test_graduate_mintsNoDollarForTheLaunch() public {
        uint256 brandsBefore = reserve.allBrandTokensLength();
        uint256 marketOfBrandBefore = marketFactory.marketOfBrand(quoteBrand);

        (, uint256 marketId) = _runToMarket();

        assertEq(reserve.allBrandTokensLength(), brandsBefore, "graduation registered no new brand");
        assertEq(
            marketFactory.marketOfBrand(quoteBrand),
            marketOfBrandBefore,
            "the dollar still belongs to no market"
        );

        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        string memory symbol0 = IERC20Metadata(Currency.unwrap(key.currency0)).symbol();
        string memory symbol1 = IERC20Metadata(Currency.unwrap(key.currency1)).symbol();
        (string memory quoteSymbol, string memory assetSymbol) =
            quoteBrand < token ? (symbol0, symbol1) : (symbol1, symbol0);
        assertEq(quoteSymbol, "launchUSD", "the pool is quoted in the launch's dollar");
        assertEq(assetSymbol, "CAT", "against the launch token, not a CAT.d");
    }

    // ─── A shared quote, not a seizure ───────────────────────────────────

    /// @notice The market is a shared quote, so it takes none of the three things a market
    ///         that owns its unit takes: `marketOfBrand`, `feeVaultOfBrand`, or the brand
    ///         treasury's admin.
    function test_graduate_leavesTheIssuersBrandAndTreasuryAlone() public {
        PoolBrandTreasury treasury = _quoteTreasury(quoteBrand);
        address adminBefore = treasury.admin();
        assertEq(adminBefore, address(this), "the issuer registered this brand");

        (, uint256 marketId) = _runToMarket();

        assertTrue(marketFactory.isSharedQuote(marketId), "a shared-quote market");
        assertEq(marketFactory.feeVaultOfBrand(quoteBrand), address(0), "no vault of its own");
        assertEq(marketFactory.marketOfBrand(quoteBrand), 0, "the brand belongs to no market");
        assertEq(treasury.admin(), adminBefore, "the market did not take the issuer's treasury");
        assertEq(
            marketFactory.market(marketId).treasury,
            address(treasury),
            "the market points at the issuer's treasury rather than one of its own"
        );
    }

    // ─── The reserve is the launch's ─────────────────────────────────────

    /// @notice The market is opened in the reserve the LAUNCH was configured for, not in the
    ///         market factory's default. A second approved reserve makes the two differ, so
    ///         a graduation that fell back to the default would fail here.
    function test_graduate_opensTheMarketInTheLaunchsOwnReserve() public {
        SharedReservePool otherReserve =
            _deployReservePool(address(usdg), address(yieldSource), owner);
        vm.prank(owner);
        marketFactory.setApprovedReservePool(address(otherReserve), true);

        (address otherBrand, address otherTreasury) = marketFactory.registerBrand(
            "Second Launch Dollar",
            "secondUSD",
            PooledBrandToken.Metadata({description: "", logo: "", socials: ""}),
            address(otherReserve)
        );
        PoolBrandTreasury(otherTreasury).setFactory(address(marketFactory));
        vm.prank(owner);
        launchFactory.setReserveEconomics(
            address(otherReserve),
            LaunchFactory.ReserveEconomics({
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                launchFee: LAUNCH_FEE,
                decimals: QUOTE_DECIMALS,
                approved: true
            })
        );
        assertTrue(
            address(otherReserve) != address(reserve),
            "the two reserves differ, so the assertion below can fail"
        );

        (address otherToken, address otherCurve) =
            _launchOn(otherReserve, otherBrand, "Riverdog", "DOG");
        _buyToThresholdOn(otherReserve, otherBrand, otherCurve, trader);
        _graduate(otherToken);

        AssetMarketFactory.Market memory m =
            marketFactory.market(launchFactory.getLaunchedToken(otherToken).marketId);
        assertEq(m.reservePool, address(otherReserve), "the launch's reserve, not the default");
        assertEq(m.brandToken, otherBrand, "quoted in that reserve's dollar");

        // And the fixture's own launch, whose reserve IS the default, still records the
        // default — the field tracks the launch rather than being pinned either way.
        (, uint256 defaultMarketId) = _runToMarket();
        assertEq(
            marketFactory.market(defaultMarketId).reservePool,
            address(reserve),
            "a launch on the default reserve still opens there"
        );
    }

    // ─── The raise reached the pool ──────────────────────────────────────

    /// @notice The quote the curve raised is pool liquidity in the launch's own dollar: it
    ///         arrives in the v4 singleton as `pairToken`, not converted into something else
    ///         on the way, and no part of it is left sitting in the graduation module.
    function test_graduate_movesTheRaiseIntoThePoolInTheLaunchsDollar() public {
        uint256 sweptQuote = launchFactory.getLaunchedToken(token).sweptQuote;
        assertEq(sweptQuote, 0, "nothing swept before the threshold");

        _buyToThreshold(curve, trader);
        sweptQuote = launchFactory.getLaunchedToken(token).sweptQuote;
        uint256 managerBefore = IERC20(quoteBrand).balanceOf(address(manager));

        Graduated memory g = _graduate(token);

        uint256 managerGain = IERC20(quoteBrand).balanceOf(address(manager)) - managerBefore;
        assertEq(managerGain, g.unitSeeded, "every seeded unit reached the v4 singleton");
        assertApproxEqRel(
            managerGain, sweptQuote, 0.001e18, "and that is the raise, less rounding dust"
        );
        assertEq(
            IERC20(quoteBrand).balanceOf(address(graduation)),
            0,
            "the module kept none of the raise"
        );
        assertEq(
            IERC20(quoteBrand).balanceOf(address(launchFactory)), 0, "and the factory paid it all"
        );
    }

    // ─── Float ───────────────────────────────────────────────────────────

    /// @notice What a graduate gets instead of owning a dollar: the brand's treasury records
    ///         the market's fee vault as holding exactly the float the seed locked.
    function test_graduate_registersTheSeededFloatWithTheQuotesTreasury() public {
        PoolBrandTreasury treasury = _quoteTreasury(quoteBrand);
        uint256 totalBefore = treasury.totalFloat();

        (Graduated memory g, uint256 marketId) = _runToMarket();
        address feeVault = marketFactory.market(marketId).feeVault;

        assertGt(g.unitSeeded, 0, "something was seeded");
        assertEq(treasury.floatOf(feeVault), g.unitSeeded, "the vault's float is the seed");
        assertEq(
            treasury.totalFloat() - totalBefore, g.unitSeeded, "and the total grew by the same"
        );
    }

    /// @notice Two launches quoted in ONE dollar — the case the previous design could not
    ///         produce, because each graduation minted a unit of its own. Both are markets,
    ///         both are shared quotes, and the one treasury carries both floats.
    function test_twoLaunchesOnTheSameDollarBothRegisterFloatAgainstIt() public {
        PoolBrandTreasury treasury = _quoteTreasury(quoteBrand);
        uint256 totalBefore = treasury.totalFloat();

        (Graduated memory first, uint256 firstMarket) = _runToMarket();

        (address second, address secondCurve) = _launch("Riverdog", "DOG");
        _buyToThreshold(secondCurve, trader);
        Graduated memory g2 = _graduate(second);
        uint256 secondMarket = launchFactory.getLaunchedToken(second).marketId;

        assertTrue(firstMarket != secondMarket, "two markets, not one");
        assertEq(marketFactory.market(firstMarket).brandToken, quoteBrand, "both quoted in it");
        assertEq(marketFactory.market(secondMarket).brandToken, quoteBrand, "both quoted in it");
        assertTrue(marketFactory.isSharedQuote(firstMarket), "the first is a shared quote");
        assertTrue(marketFactory.isSharedQuote(secondMarket), "so is the second");

        address firstVault = marketFactory.market(firstMarket).feeVault;
        address secondVault = marketFactory.market(secondMarket).feeVault;
        assertTrue(firstVault != secondVault, "each market has its own fee vault");
        assertEq(treasury.floatOf(firstVault), first.unitSeeded, "the first launch's float");
        assertEq(treasury.floatOf(secondVault), g2.unitSeeded, "the second launch's float");
        assertEq(
            treasury.totalFloat() - totalBefore,
            first.unitSeeded + g2.unitSeeded,
            "the dollar's total float is the sum of the two pools it quotes"
        );
    }

    /// @notice Only the launchpad may tell a brand's treasury that a pool holds its float.
    ///         Anyone else could otherwise dilute every real market's share of the yield.
    function test_recordLaunchFloat_isOnlyCallableByTheLaunchpad() public {
        (, uint256 marketId) = _runToMarket();
        PoolBrandTreasury treasury = _quoteTreasury(quoteBrand);
        uint256 floatBefore = treasury.totalFloat();

        vm.prank(stranger);
        vm.expectRevert(AssetMarketFactory.OnlyLaunchpad.selector);
        marketFactory.recordLaunchFloat(marketId, 1_000_000e6);

        assertEq(treasury.totalFloat(), floatBefore, "and nothing was recorded");
    }

    // ─── The guard that keeps a graduation from getting stuck ────────────

    /// @notice A quote brand whose issuer has not named the market factory on its treasury is
    ///         refused at launch time. Accepting it would let a launch raise real money and
    ///         then graduate into a market that can never be credited any float — and the
    ///         refusal has to land before anything is deployed, not on a graduation.
    /// @dev Reserve-keyed economics are what makes this a launch-time check: the owner opens
    ///      a reserve once and never sees the brands issued on it afterwards, so the opt-in is
    ///      re-read for every brand every time it is quoted.
    function test_launch_refusesABrandWhoseTreasuryHasNotOptedIn() public {
        (address shyBrand, address shyTreasury) =
            marketFactory.registerBrand("Shy Dollar", "shyUSD");
        assertEq(
            PoolBrandTreasury(shyTreasury).factory(),
            address(0),
            "the issuer has not opted into sharing its float"
        );

        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.PairTokenFloatShareUnavailable.selector, shyBrand)
        );
        launchFactory.launchEconomics(shyBrand);

        _fundBrand(reserve, shyBrand, creator, LAUNCH_FEE);
        vm.startPrank(creator);
        IERC20(shyBrand).approve(address(launchFactory), LAUNCH_FEE);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.PairTokenFloatShareUnavailable.selector, shyBrand)
        );
        launchFactory.launchToken(
            _tokenParams("Shy Launch", "SHY", keccak256("SHY")),
            launchConfigId,
            shyBrand,
            new address[](0)
        );
        vm.stopPrank();

        // Opting in is the whole of what was missing — and no owner call follows it, because
        // the reserve's terms were already open.
        PoolBrandTreasury(shyTreasury).setFactory(address(marketFactory));

        (address r, LaunchFactory.ReserveEconomics memory e) =
            launchFactory.launchEconomics(shyBrand);
        assertEq(r, address(reserve), "the brand resolves to the open reserve");
        assertEq(e.graduationThreshold, GRADUATION_THRESHOLD, "on that reserve's terms");
        assertTrue(e.approved, "and the brand is launchable");

        (address launched,) = _launchOn(reserve, shyBrand, "Shy Launch", "SHY");
        assertEq(
            launchFactory.getLaunchedToken(launched).pairToken, shyBrand, "the launch went through"
        );
    }
}
