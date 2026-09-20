// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {BrandPsm} from "../../src/pool/BrandPsm.sol";
import {BrandPsmFactory} from "../../src/pool/BrandPsmFactory.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev A source that takes deposits and refuses to give all of it back, which is what a
///      lending market at full utilisation looks like from the reserve's side.
contract IlliquidYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    uint256 public releasable;

    function setReleasable(uint256 amount) external {
        releasable = amount;
    }

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 paid = amount > releasable ? releasable : amount;
        releasable -= paid;
        IERC20(asset).safeTransfer(to, paid);
        return paid;
    }

    function balanceOf(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function totalAssets(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdrawable(address, address) external view returns (uint256) {
        return releasable;
    }
}

contract BrandPsmTest is Test, StackFixture {
    using SafeERC20 for IERC20;

    SharedReservePool pool;
    MockUSDC usdg;
    MockYieldSource yieldSource;
    BrandPsmFactory factory;

    address owner = address(0x0AD01);
    address admin = address(0xA1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    address brand;
    BrandPsm psm;

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;
    uint256 constant FUNDING = 5_000_000e6;

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        pool = _deployReservePool(address(usdg), address(yieldSource), owner);

        (brand,) = pool.registerBrand("Alpha USD", "aUSD", admin);

        factory = new BrandPsmFactory();
        psm = BrandPsm(factory.deploy(pool, brand));

        // An increase is announced and lands only after `FEE_INCREASE_DELAY`. `tout` and
        // `daiForGem` read the LIVE fee, so serve the hour here and every test below is
        // written against a PSM whose exit charge is already 20 bps.
        vm.prank(owner);
        pool.setRedemptionFee(20);
        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();

        usdg.mint(alice, FUNDING);
        usdg.mint(bob, FUNDING);
    }

    function _sellGem(address who, uint256 gemAmt) internal returns (uint256) {
        vm.startPrank(who);
        usdg.approve(address(psm), gemAmt);
        uint256 out = psm.sellGem(who, gemAmt);
        vm.stopPrank();
        return out;
    }

    /// @dev Put `feeBps` in force now, whichever way it moves. A cut lands in the same
    ///      transaction; a rise is only announced and has to serve `FEE_INCREASE_DELAY`. The
    ///      quoting convention these tests pin is a function of the LIVE fee, so they are
    ///      written against one rather than against an announcement.
    function _setLiveFee(uint16 feeBps) internal {
        vm.prank(owner);
        pool.setRedemptionFee(feeBps);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();
        if (effectiveAt != 0) {
            vm.warp(effectiveAt);
            pool.commitRedemptionFee();
        }
        assertEq(pool.redemptionFeeBps(), feeBps);
    }

    // ─── The mint direction ──────────────────────────────────────────────

    function test_sellGem_mintsOneForOneAndKeepsNothing() public {
        uint256 amount = 10_000e6;
        uint256 out = _sellGem(alice, amount);

        assertEq(out, amount, "brand minted must equal gem sold");
        assertEq(IERC20(brand).balanceOf(alice), amount);
        assertEq(usdg.balanceOf(alice), FUNDING - amount);
        assertEq(usdg.balanceOf(address(psm)), 0, "facade must hold no gem between calls");
        assertEq(IERC20(brand).balanceOf(address(psm)), 0, "facade must hold no dai");
    }

    function test_sellGem_creditsRecipientNotCaller() public {
        uint256 amount = 1_000e6;
        vm.startPrank(alice);
        usdg.approve(address(psm), amount);
        psm.sellGem(bob, amount);
        vm.stopPrank();

        assertEq(IERC20(brand).balanceOf(bob), amount);
        assertEq(IERC20(brand).balanceOf(alice), 0);
    }

    function test_sellGem_propagatesLiabilityCap() public {
        vm.prank(owner);
        pool.setLiabilityCap(1_000e6);

        vm.startPrank(alice);
        usdg.approve(address(psm), 1_001e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.LiabilityCapExceeded.selector, 0, 1_001e6, 1_000e6
            )
        );
        psm.sellGem(alice, 1_001e6);
        vm.stopPrank();
    }

    // ─── The redeem direction ────────────────────────────────────────────

    function test_buyGem_deliversExactGemAndChargesTheFee() public {
        _sellGem(alice, 100_000e6);

        uint256 want = 10_000e6;
        uint256 expectedIn = psm.daiForGem(want);
        assertGt(expectedIn, want, "a 20 bps fee must cost more brand than gem bought");

        uint256 gemBefore = usdg.balanceOf(bob);
        uint256 daiBefore = IERC20(brand).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(brand).approve(address(psm), expectedIn);
        uint256 spent = psm.buyGem(bob, want);
        vm.stopPrank();

        assertEq(spent, expectedIn);
        assertEq(usdg.balanceOf(bob) - gemBefore, want, "exact-output must be exact");
        assertEq(daiBefore - IERC20(brand).balanceOf(alice), expectedIn);
        assertEq(usdg.balanceOf(address(psm)), 0);
        assertEq(IERC20(brand).balanceOf(address(psm)), 0);
    }

    function test_buyGem_revertsRatherThanPayingShort() public {
        // Re-point the reserve at a source that will not release what it holds, so the
        // reserve's own `redeem` would truncate its payout instead of reverting. The
        // migration recalls everything to idle, so the funds have to be pushed back out
        // before the reserve is actually short.
        IlliquidYieldSource illiquid = new IlliquidYieldSource();
        _sellGem(alice, 100_000e6);
        vm.prank(owner);
        pool.setYieldSource(address(illiquid), true);
        pool.deployIdle();
        illiquid.setReleasable(1_000e6);

        uint256 want = 50_000e6;
        uint256 needed = psm.daiForGem(want);

        vm.startPrank(alice);
        IERC20(brand).approve(address(psm), needed);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, 1_000e6, want)
        );
        psm.buyGem(alice, want);
        vm.stopPrank();
    }

    function test_daiForGem_isTheLeastAmountThatClears() public view {
        uint256 want = 7_777e6;
        uint256 needed = psm.daiForGem(want);
        uint256 bps = pool.redemptionFeeBps();

        assertGe(needed - needed * bps / BPS, want, "must cover the target");
        uint256 oneLess = needed - 1;
        assertLt(oneLess - oneLess * bps / BPS, want, "must not overshoot by a whole unit");
    }

    // ─── The quoting convention ──────────────────────────────────────────

    /// @dev The invariant the whole `tout` convention exists for. An integrator holding
    ///      `daiIn` computes the gem it can buy as `daiIn / (1 + tout)` — this is 0x Settler's
    ///      `sellToMakerPsm` — and then calls `buyGem` for that amount. If our reported `tout`
    ///      were the raw fee, that division would ask for marginally more gem than `daiIn` can
    ///      actually buy and the settled route would revert on the last leg.
    function testFuzz_toutInversionNeverAsksForMoreThanTheCallerHolds(uint256 daiIn, uint16 feeBps)
        public
    {
        feeBps = uint16(bound(feeBps, 0, pool.MAX_REDEMPTION_FEE_BPS()));
        daiIn = bound(daiIn, 1e6, 1_000_000e6);
        _setLiveFee(feeBps);

        uint256 gemOut = daiIn * WAD / (WAD + psm.tout());
        vm.assume(gemOut > 0);

        assertLe(psm.daiForGem(gemOut), daiIn, "inverting tout must not exceed the sell amount");
    }

    /// @dev Kyber's `lite-psm` simulator subtracts the fee instead of inverting it
    ///      (`gemOut = daiIn - daiIn*tout/WAD`). That form must also stay inside what the
    ///      caller holds, or their quote would settle short.
    function testFuzz_toutSubtractionNeverAsksForMoreThanTheCallerHolds(
        uint256 daiIn,
        uint16 feeBps
    ) public {
        feeBps = uint16(bound(feeBps, 0, pool.MAX_REDEMPTION_FEE_BPS()));
        daiIn = bound(daiIn, 1e6, 1_000_000e6);
        _setLiveFee(feeBps);

        uint256 gemOut = daiIn - daiIn * psm.tout() / WAD;
        vm.assume(gemOut > 0);

        assertLe(psm.daiForGem(gemOut), daiIn, "subtracting tout must not exceed the sell amount");
    }

    function test_toutIsZeroForAFreeReserve() public {
        vm.prank(owner);
        pool.setRedemptionFee(0);
        assertEq(psm.tout(), 0);
        assertEq(psm.daiForGem(1_234e6), 1_234e6, "no fee means par in both directions");
    }

    /// @dev The quote an aggregator holds must survive the announcement of a rise. 0x Settler
    ///      reads `tout` and settles against it some blocks later; if `tout` moved the moment
    ///      the owner announced an increase, the delay would protect `previewRedeem` and leave
    ///      the PSM face of the same reserve exposed.
    function test_toutIgnoresAnAnnouncedIncreaseUntilItIsCommitted() public {
        uint256 quotedTout = psm.tout();
        uint256 quotedDai = psm.daiForGem(100_000e6);

        vm.prank(owner);
        pool.setRedemptionFee(100);
        assertEq(pool.pendingRedemptionFeeBps(), 100, "announced");
        assertEq(psm.tout(), quotedTout, "tout still quotes the live 20 bps");
        assertEq(psm.daiForGem(100_000e6), quotedDai);

        vm.warp(pool.redemptionFeeEffectiveAt() - 1);
        assertEq(psm.tout(), quotedTout, "and right up to the last second before it lands");

        vm.warp(pool.redemptionFeeEffectiveAt());
        pool.commitRedemptionFee();
        assertGt(psm.tout(), quotedTout, "only the commit moves it");
        assertGt(psm.daiForGem(100_000e6), quotedDai);
    }

    function test_tinIsFreeWhileOpen() public view {
        assertEq(psm.tin(), 0, "minting a brand token costs nothing");
    }

    // ─── Pausing is per-direction ────────────────────────────────────────

    function test_pause_haltsSellGemAndLeavesBuyGemOpen() public {
        _sellGem(alice, 100_000e6);
        _pauseProtocol();

        assertEq(psm.tin(), psm.HALTED(), "a halted mint must be advertised as HALTED");
        assertEq(psm.live(), 0);
        assertLt(psm.tout(), psm.HALTED(), "redemption is never halted");

        vm.startPrank(alice);
        usdg.approve(address(psm), 1e6);
        vm.expectRevert(BrandPsm.SellGemHalted.selector);
        psm.sellGem(alice, 1e6);
        vm.stopPrank();

        // A holder must still be able to leave during an incident.
        uint256 want = 1_000e6;
        vm.startPrank(alice);
        IERC20(brand).approve(address(psm), psm.daiForGem(want));
        psm.buyGem(alice, want);
        vm.stopPrank();
    }

    // ─── The discovery surface aggregators actually read ─────────────────

    function test_discoverySurface() public view {
        assertEq(address(psm.dai()), brand, "dai() must be the brand token");
        assertEq(address(psm.gem()), address(usdg), "gem() must be the reserve asset");
        assertEq(psm.pocket(), address(pool), "pocket() must be where the gem sits");
        assertEq(psm.gemJoin(), address(psm), "the facade is its own join");
        assertEq(psm.dec(), usdg.decimals());
        assertEq(psm.to18ConversionFactor(), 1, "both sides are 6-decimal");
        assertEq(usdg.balanceOf(psm.pocket()), usdg.balanceOf(address(pool)));
    }

    /// @dev Kyber's pool-list updater treats a PSM that answers `psm()` as a wrapper around an
    ///      inner PSM and reads fees off that inner address instead. Answering it would send
    ///      their indexer to the wrong contract, so the absence of the selector is a contract.
    function test_noInnerPsmSelector() public {
        (bool ok,) = address(psm).staticcall(abi.encodeWithSignature("psm()"));
        assertFalse(ok, "psm() must not resolve");
    }

    function test_constructor_rejectsBrandTheReserveDoesNotHold() public {
        address stranger = address(new MockUSDC());
        vm.expectRevert(abi.encodeWithSelector(BrandPsm.UnknownBrand.selector, stranger));
        new BrandPsm(pool, stranger);
    }

    // ─── Factory ─────────────────────────────────────────────────────────

    function test_factory_indexesAndPredictsTheSameAddress() public {
        (address second,) = pool.registerBrand("Beta USD", "bUSD", admin);
        address predicted = factory.predict(pool, second);
        address deployed = factory.deploy(pool, second);

        assertEq(deployed, predicted, "predict must match deploy");
        assertEq(factory.psmOf(address(pool), second), deployed);
        assertEq(factory.psmCount(), 2);
    }

    function test_factory_refusesASecondWindowForTheSameBrand() public {
        vm.expectRevert(abi.encodeWithSelector(BrandPsmFactory.AlreadyDeployed.selector, psm));
        factory.deploy(pool, brand);
    }

    // ─── Round trip ──────────────────────────────────────────────────────

    function testFuzz_roundTripCostsExactlyTheRedemptionFee(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        uint256 before = usdg.balanceOf(alice);

        _sellGem(alice, amount);
        uint256 held = IERC20(brand).balanceOf(alice);
        uint256 recoverable = held - held * pool.redemptionFeeBps() / BPS;
        vm.assume(recoverable > 0);

        vm.startPrank(alice);
        IERC20(brand).approve(address(psm), held);
        psm.buyGem(alice, recoverable);
        vm.stopPrank();

        assertEq(before - usdg.balanceOf(alice), amount - recoverable, "only the fee is lost");
    }
}
