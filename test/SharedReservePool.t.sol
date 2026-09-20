// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockYieldSource} from "./mocks/MockYieldSource.sol";
import {StackFixture} from "./helpers/StackFixture.sol";

contract SharedReservePoolTest is Test, StackFixture {
    SharedReservePool pool;
    MockUSDC usdc;
    MockYieldSource yieldSource;

    address owner = address(0x0AD01);
    address adminA = address(0xA1);
    address adminB = address(0xB1);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    address tokenA;
    address treasuryA;
    address tokenB;
    address treasuryB;

    uint256 constant INITIAL_BALANCE = 1_000_000e6;

    function setUp() public {
        _deployUpgradeBase();
        usdc = new MockUSDC();
        yieldSource = new MockYieldSource();
        pool = _deployReservePool(address(usdc), address(yieldSource), owner);

        (tokenA, treasuryA) = pool.registerBrand("Alpha USD", "aUSD", adminA);
        (tokenB, treasuryB) = pool.registerBrand("Beta USD", "bUSD", adminB);

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
    }

    function _mint(address caller, address token, uint256 amount) internal {
        vm.startPrank(caller);
        usdc.approve(address(pool), amount);
        pool.mint(token, amount, caller);
        vm.stopPrank();
    }

    // ─── Registration ────────────────────────────────────────────────────

    function test_registerBrand_deploysTokenAndTreasury() public view {
        assertTrue(pool.isRegistered(tokenA));
        assertEq(PooledBrandToken(tokenA).name(), "Alpha USD");
        assertEq(PooledBrandToken(tokenA).symbol(), "aUSD");
        assertEq(PooledBrandToken(tokenA).decimals(), usdc.decimals());
        assertEq(PoolBrandTreasury(treasuryA).admin(), adminA);
        assertEq(address(PoolBrandTreasury(treasuryA).pool()), address(pool));
        assertEq(pool.allBrandTokensLength(), 2);
    }

    // ─── Mint / redeem ───────────────────────────────────────────────────

    function _registerWithLogo(string memory logo, address admin)
        private
        returns (address token, address treasury)
    {
        return pool.registerBrand(
            "Icon Dollar",
            "ICO",
            admin,
            PooledBrandToken.Metadata({description: "A dollar.", logo: logo, socials: ""}),
            admin
        );
    }

    function test_registerBrand_recordsMetadataAndPreservesMintRedeem() public {
        string memory url = "https://static.stables.fi/coin-icons/example.png";
        (address token, address treasury) = _registerWithLogo(url, adminA);
        PooledBrandToken brand = PooledBrandToken(token);

        assertEq(brand.logo(), url);
        assertEq(brand.description(), "A dollar.");
        assertEq(brand.name(), "Icon Dollar");
        assertEq(brand.symbol(), "ICO");
        assertEq(brand.decimals(), 6);
        assertEq(PoolBrandTreasury(treasury).admin(), adminA);
        assertEq(brand.metadataAdmin(), adminA);
        assertTrue(pool.isRegistered(token));

        url = "https://static.stables.fi/coin-icons/updated.png";
        vm.prank(adminA);
        brand.setMetadata(
            PooledBrandToken.Metadata({description: "A dollar.", logo: url, socials: ""})
        );

        // Metadata is not supply: rewriting it changes nothing about the peg.
        _mint(alice, token, 100e6);
        vm.prank(alice);
        pool.redeem(token, 40e6, alice);
        assertEq(brand.balanceOf(alice), 60e6);
        assertEq(pool.outstandingOf(token), 60e6);
        assertEq(brand.logo(), url);

        // And the pool, which is the only contract that may move this token's supply, has no
        // authority at all over what it says about itself.
        vm.prank(address(pool));
        (bool changed,) = token.call(
            abi.encodeWithSignature("setMetadata((string,string,string))", "", "replacement", "")
        );
        assertFalse(changed, "even the pool cannot rewrite the metadata");
        assertEq(brand.logo(), url);
    }

    function test_metadata_onlyTheAdminCanRewriteIt() public {
        (address token,) = _registerWithLogo("ipfs://original", adminA);
        PooledBrandToken brand = PooledBrandToken(token);

        PooledBrandToken.Metadata memory attacker =
            PooledBrandToken.Metadata({description: "", logo: "ipfs://attacker", socials: ""});
        vm.prank(alice);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        brand.setMetadata(attacker);
        assertEq(brand.logo(), "ipfs://original");

        PooledBrandToken.Metadata memory updated =
            PooledBrandToken.Metadata({description: "", logo: "ipfs://updated", socials: ""});
        vm.prank(adminA);
        vm.expectEmit(false, false, false, true, token);
        emit PooledBrandToken.MetadataUpdated("", "ipfs://updated", "");
        brand.setMetadata(updated);
        assertEq(brand.logo(), "ipfs://updated");

        // The authority reaches the three strings and stops there.
        vm.prank(adminA);
        vm.expectRevert(PooledBrandToken.OnlyPool.selector);
        brand.mint(adminA, 1e6);
    }

    /// @dev The half of main's icon design that survived the merge, and the reason it did. A
    ///      handover that completes on the sender's word alone fails silently: the token keeps
    ///      its peg and keeps trading, and only the image can never be corrected again.
    function test_metadataAdminTransfer_requiresNominationAndAcceptance() public {
        (address token,) = _registerWithLogo("ipfs://original", adminA);
        PooledBrandToken brand = PooledBrandToken(token);

        vm.prank(alice);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        brand.transferMetadataAdmin(alice);

        vm.prank(adminA);
        brand.transferMetadataAdmin(adminB);
        assertEq(brand.metadataAdmin(), adminA, "nothing moves until it is accepted");
        assertEq(brand.pendingMetadataAdmin(), adminB);

        vm.prank(alice);
        vm.expectRevert(PooledBrandToken.OnlyPendingMetadataAdmin.selector);
        brand.acceptMetadataAdmin();

        PooledBrandToken.Metadata memory premature =
            PooledBrandToken.Metadata({description: "", logo: "ipfs://premature", socials: ""});
        vm.prank(adminB);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        brand.setMetadata(premature);

        vm.prank(adminB);
        brand.acceptMetadataAdmin();
        assertEq(brand.metadataAdmin(), adminB);
        assertEq(brand.pendingMetadataAdmin(), address(0));

        PooledBrandToken.Metadata memory former =
            PooledBrandToken.Metadata({description: "", logo: "ipfs://former", socials: ""});
        vm.prank(adminA);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        brand.setMetadata(former);
    }

    /// @dev Freezing has to stay one-sided: there is nobody to accept.
    function test_renounceMetadataAdmin_freezesTheStringsForGood() public {
        (address token,) = _registerWithLogo("ipfs://final", adminA);
        PooledBrandToken brand = PooledBrandToken(token);

        vm.prank(adminA);
        brand.renounceMetadataAdmin();
        assertEq(brand.metadataAdmin(), address(0));

        PooledBrandToken.Metadata memory attempt =
            PooledBrandToken.Metadata({description: "", logo: "ipfs://after", socials: ""});
        vm.prank(adminA);
        vm.expectRevert(PooledBrandToken.OnlyMetadataAdmin.selector);
        brand.setMetadata(attempt);
        assertEq(brand.logo(), "ipfs://final", "frozen at the last value it held");
    }

    function test_mint_depositsAndMints1to1() public {
        _mint(alice, tokenA, 1000e6);

        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 1000e6);
        assertEq(pool.totalAssets(), 1000e6);
        assertEq(pool.outstandingOf(tokenA), 1000e6);
    }

    function test_redeem_burnsAndWithdraws1to1() public {
        _mint(alice, tokenA, 1000e6);

        vm.prank(alice);
        uint256 out = pool.redeem(tokenA, 400e6, alice);

        assertEq(out, 400e6);
        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 600e6);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 600e6);
        assertEq(pool.outstandingOf(tokenA), 600e6);
    }

    function test_redeem_pullsFromYieldSourceWhenIdleInsufficient() public {
        _mint(alice, tokenA, 1000e6);
        pool.deployIdle();
        assertEq(usdc.balanceOf(address(pool)), 0);

        vm.prank(alice);
        uint256 out = pool.redeem(tokenA, 1000e6, alice);

        assertEq(out, 1000e6);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_mint_revertsOnUnknownToken() public {
        vm.expectRevert(SharedReservePool.UnknownBrand.selector);
        pool.mint(address(0xDEAD), 1e6, alice);
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.expectRevert(SharedReservePool.ZeroAmount.selector);
        pool.mint(tokenA, 0, alice);
    }

    function test_liabilityCap_defaultsUnlimitedThenBoundsAggregateMinting() public {
        assertEq(pool.liabilityCap(), 0);
        _mint(alice, tokenA, 600e6);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.LiabilityCapUpdated(0, 1_000e6);
        pool.setLiabilityCap(1_000e6);

        _mint(bob, tokenB, 400e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.LiabilityCapExceeded.selector, 1_000e6, 1, 1_000e6
            )
        );
        pool.mint(tokenA, 1, alice);
        vm.stopPrank();
        assertEq(pool.totalPooledSupply(), 1_000e6);
    }

    function test_liabilityCap_ownerMayLowerBelowSupplyWithoutBlockingRedemption() public {
        _mint(alice, tokenA, 1_000e6);
        vm.prank(owner);
        pool.setLiabilityCap(500e6);

        vm.prank(alice);
        assertEq(pool.redeem(tokenA, 600e6, alice), 600e6);
        assertEq(pool.totalPooledSupply(), 400e6);
    }

    function test_setLiabilityCap_isOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setLiabilityCap(1_000e6);
    }

    // ─── Swap ────────────────────────────────────────────────────────────

    function test_swap_isExact1to1_noAssetMovement() public {
        _mint(alice, tokenA, 1000e6);
        uint256 assetsBefore = pool.totalAssets();

        vm.prank(alice);
        pool.swap(tokenA, tokenB, 300e6, alice);

        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 700e6);
        assertEq(PooledBrandToken(tokenB).balanceOf(alice), 300e6);
        assertEq(pool.outstandingOf(tokenA), 700e6);
        assertEq(pool.outstandingOf(tokenB), 300e6);
        assertEq(pool.totalAssets(), assetsBefore, "swap must never move underlying");
        assertEq(pool.totalPooledSupply(), 1000e6, "swap must never change total pooled supply");
    }

    function test_swap_revertsOnSameToken() public {
        _mint(alice, tokenA, 1000e6);
        vm.prank(alice);
        vm.expectRevert(SharedReservePool.SameToken.selector);
        pool.swap(tokenA, tokenA, 100e6, alice);
    }

    function test_swap_revertsOnUnknownToken() public {
        _mint(alice, tokenA, 1000e6);
        vm.prank(alice);
        vm.expectRevert(SharedReservePool.UnknownBrand.selector);
        pool.swap(tokenA, address(0xDEAD), 100e6, alice);
    }

    // ─── Yield accrual — the point of this whole design ─────────────────

    /// @dev Two brands with equal outstanding supply must split pool yield equally,
    ///      regardless of which brand's tokens anyone happens to be holding.
    function test_yield_splitsProportionalToOutstandingSupply() public {
        _mint(alice, tokenA, 1000e6);
        _mint(bob, tokenB, 1000e6);

        pool.deployIdle();
        usdc.mint(address(this), 200e6);
        usdc.approve(address(yieldSource), 200e6);
        yieldSource.simulateYield(address(usdc), 200e6);

        assertEq(pool.pendingYield(tokenA), 100e6);
        assertEq(pool.pendingYield(tokenB), 100e6);
    }

    /// @dev The core regression this pool exists to prevent: swapping tokens between brands
    ///      must never move yield entitlement between them. A brand's accrued yield is fixed
    ///      the moment it is settled and only ever grows against that brand's OWN future
    ///      outstanding supply — moving the tokens themselves must not touch it.
    function test_swap_doesNotTransferYieldEntitlementBetweenBrands() public {
        _mint(alice, tokenA, 1000e6);
        _mint(bob, tokenB, 1000e6);

        pool.deployIdle();
        usdc.mint(address(this), 200e6);
        usdc.approve(address(yieldSource), 200e6);
        yieldSource.simulateYield(address(usdc), 200e6);

        assertEq(pool.pendingYield(tokenA), 100e6);
        assertEq(pool.pendingYield(tokenB), 100e6);

        // Alice swaps her entire A balance into B.
        vm.prank(alice);
        pool.swap(tokenA, tokenB, 1000e6, alice);

        // Brand A's already-earned yield is untouched by losing all its outstanding supply.
        assertEq(
            pool.pendingYield(tokenA), 100e6, "A's earned yield must survive its supply leaving"
        );
        // Brand B's yield at this instant is also untouched — the swap itself earns nothing.
        assertEq(pool.pendingYield(tokenB), 100e6, "swap must not itself create or move yield");

        // Total entitlement is exactly conserved: nothing created, nothing destroyed.
        assertEq(pool.pendingYield(tokenA) + pool.pendingYield(tokenB), 200e6);

        // Alice's swapped-in B is still worth exactly 1:1 — no hidden discount or premium.
        vm.prank(alice);
        uint256 out = pool.redeem(tokenB, 1000e6, alice);
        assertEq(out, 1000e6);

        // From here on, brand A has zero outstanding supply, so ALL further yield accrues
        // to brand B alone — it must not keep splitting 50/50 by some stale assumption.
        usdc.mint(address(this), 100e6);
        usdc.approve(address(yieldSource), 100e6);
        yieldSource.simulateYield(address(usdc), 100e6);

        // Tolerate 1-wei dust from MockYieldSource's own share/index floor-division, not
        // slippage introduced by this pool.
        assertApproxEqAbs(
            pool.pendingYield(tokenA), 100e6, 1, "brand with 0 outstanding earns no further yield"
        );
        assertApproxEqAbs(
            pool.pendingYield(tokenB), 200e6, 1, "sole remaining brand captures all new yield"
        );
    }

    function test_claimYield_onlyBrandTreasuryCanClaim() public {
        _mint(alice, tokenA, 1000e6);
        pool.deployIdle();
        usdc.mint(address(this), 100e6);
        usdc.approve(address(yieldSource), 100e6);
        yieldSource.simulateYield(address(usdc), 100e6);

        vm.expectRevert(SharedReservePool.OnlyBrandTreasury.selector);
        pool.claimYield(tokenA, alice);
    }

    function test_claim_paysOutAndResetsAccrual() public {
        _mint(alice, tokenA, 1000e6);
        pool.deployIdle();
        usdc.mint(address(this), 100e6);
        usdc.approve(address(yieldSource), 100e6);
        yieldSource.simulateYield(address(usdc), 100e6);

        assertEq(PoolBrandTreasury(treasuryA).pendingYield(), 100e6);

        vm.prank(adminA);
        uint256 claimed = PoolBrandTreasury(treasuryA).claim(adminA);

        assertEq(claimed, 100e6);
        assertEq(usdc.balanceOf(adminA), 100e6);
        assertEq(PoolBrandTreasury(treasuryA).pendingYield(), 0);
        assertEq(PoolBrandTreasury(treasuryA).totalYieldClaimed(), 100e6);
    }

    function test_treasury_claim_revertsForNonAdmin() public {
        vm.expectRevert(PoolBrandTreasury.OnlyAdmin.selector);
        PoolBrandTreasury(treasuryA).claim(alice);
    }

    function test_treasury_distribute_revertsForNonAdmin() public {
        vm.expectRevert(PoolBrandTreasury.OnlyAdmin.selector);
        PoolBrandTreasury(treasuryA).distribute(address(usdc), alice, 1e6);
    }

    // ─── Yield source management ─────────────────────────────────────────

    function test_setYieldSource_onlyOwner() public {
        MockYieldSource newSource = new MockYieldSource();
        vm.expectRevert();
        pool.setYieldSource(address(newSource));

        vm.prank(owner);
        pool.setYieldSource(address(newSource));
        assertEq(address(pool.yieldSource()), address(newSource));
    }

    function test_setYieldSource_recallsExistingDeposits() public {
        _mint(alice, tokenA, 1000e6);
        pool.deployIdle();

        MockYieldSource newSource = new MockYieldSource();
        vm.prank(owner);
        pool.setYieldSource(address(newSource));

        assertEq(usdc.balanceOf(address(pool)), 1000e6, "recalled funds should sit idle");
        assertEq(pool.totalAssets(), 1000e6);
    }

    // ─── Redemption fee ──────────────────────────────────────────────────

    /// @dev Put `bps` in force NOW, in whichever direction it moves. An increase is only
    ///      announced by `setRedemptionFee` and has to serve `FEE_INCREASE_DELAY` before
    ///      anyone can commit it, so every test below whose subject is what a LIVE fee does —
    ///      the arithmetic, the income path, the payout — takes the whole route through this
    ///      helper instead of restating the delay at each call site. The delay itself is the
    ///      subject of its own tests further down, which deliberately do not use this.
    function _setFee(uint16 bps) internal {
        vm.prank(owner);
        pool.setRedemptionFee(bps);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();
        if (effectiveAt != 0) {
            vm.warp(effectiveAt);
            pool.commitRedemptionFee();
        }
        assertEq(pool.redemptionFeeBps(), bps, "helper left the fee somewhere else");
    }

    /// @dev A second pool over a source whose index can be pushed down, so a fee can be
    ///      tested against a loss the pool has not yet observed.
    function _deployLossyPool()
        internal
        returns (SharedReservePool lossy, IndexedLossSource source, address token)
    {
        source = new IndexedLossSource();
        lossy = _deployReservePool(address(usdc), address(source), owner);
        (token,) = lossy.registerBrand("Lossy USD", "lUSD", adminA);
        vm.prank(owner);
        lossy.setRedemptionFee(100);
        vm.warp(lossy.redemptionFeeEffectiveAt());
        lossy.commitRedemptionFee();
    }

    function _mintInto(SharedReservePool p, address token, uint256 amount) internal {
        vm.startPrank(alice);
        usdc.approve(address(p), amount);
        p.mint(token, amount, alice);
        vm.stopPrank();
    }

    function _countRecorded(bytes32 topic) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) n++;
        }
    }

    function test_redemptionFee_defaultIsZeroAndRedeemPaysPar() public {
        assertEq(pool.redemptionFeeBps(), 0);
        assertEq(pool.previewRedeem(1000e6), 1000e6);
        _mint(alice, tokenA, 1000e6);

        vm.recordLogs();
        vm.prank(alice);
        uint256 paid = pool.redeem(tokenA, 400e6, alice, 400e6);

        assertEq(paid, 400e6);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 600e6);
        assertEq(
            _countRecorded(SharedReservePool.RedemptionFeeRetained.selector),
            0,
            "no fee event at a zero fee"
        );
        assertEq(pool.totalAssets(), 600e6, "nothing retained");
    }

    function test_setRedemptionFee_isOwnerOnlyCappedAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setRedemptionFee(14);

        // The ceiling binds at announcement, not only at commit, so an over-cap value can
        // never sit in the pending slot where an integrator would read it as coming.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SharedReservePool.FeeTooHigh.selector, 101, 100));
        pool.setRedemptionFee(101);
        assertEq(pool.redemptionFeeBps(), 0, "a rejected fee leaves nothing behind");
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "and nothing scheduled either");

        uint64 effectiveAt = uint64(block.timestamp) + pool.FEE_INCREASE_DELAY();
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeIncreaseScheduled(0, 14, effectiveAt);
        pool.setRedemptionFee(14);
        assertEq(pool.redemptionFeeBps(), 0, "announcing an increase does not apply it");

        vm.warp(effectiveAt);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeIncreaseCommitted(0, 14, effectiveAt);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeUpdated(0, 14);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 14);

        _setFee(100);
        assertEq(pool.previewRedeem(1000e6), 990e6, "the cap itself is allowed");
    }

    function test_redemptionFee_previewMatchesThePayoutAndTheRedeemedEvent() public {
        _setFee(14);
        _mint(alice, tokenA, 1000e6);
        uint256 preview = pool.previewRedeem(1000e6);
        assertEq(preview, 998_600_000);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeRetained(tokenA, 1_400_000);
        vm.expectEmit(true, true, true, true, address(pool));
        emit SharedReservePool.Redeemed(tokenA, alice, alice, preview);
        uint256 paid = pool.redeem(tokenA, 1000e6, alice, preview);

        assertEq(paid, preview);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 1_400_000);
        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 0, "the whole amount is burned");
        assertEq(pool.totalAssets(), 1_400_000, "the fee stays in the reserve");
    }

    /// @dev With no loss to repay the fee is pool income, and pool income is split by the
    ///      outstanding supply at the accrual, which is after the redeemer's burn.
    function test_redemptionFee_withNoLossIsYieldSplitByOutstanding() public {
        _setFee(14);
        _mint(alice, tokenA, 4000e6);
        _mint(bob, tokenB, 1000e6);

        vm.prank(alice);
        pool.redeem(tokenA, 1000e6, alice, 998_600_000); // fee 1.4; A:B is now 3,000:1,000

        assertEq(pool.lossCarryforward(), 0);
        assertApproxEqAbs(pool.pendingYield(tokenA), 1_050_000, 1, "three quarters of the fee");
        assertApproxEqAbs(pool.pendingYield(tokenB), 350_000, 1, "one quarter of the fee");
        assertLe(pool.pendingYield(tokenA) + pool.pendingYield(tokenB), 1_400_000);

        vm.prank(adminA);
        uint256 claimed = PoolBrandTreasury(treasuryA).claim(adminA);
        assertApproxEqAbs(claimed, 1_050_000, 1);
        assertEq(usdc.balanceOf(adminA), claimed, "paid in the underlying");
        assertEq(pool.pendingYield(tokenA), 0);
        assertApproxEqAbs(pool.pendingYield(tokenB), 350_000, 1, "B is untouched by A's claim");
    }

    function test_redemptionFee_repaysLossCarryforwardBeforeItBecomesYield() public {
        (SharedReservePool lossy, IndexedLossSource source, address token) = _deployLossyPool();
        _mintInto(lossy, token, 1000e6);

        // The source loses 2. The pool has not looked yet.
        source.simulateIndex(0.998e18);
        assertEq(lossy.lossCarryforward(), 0);

        uint256 want = lossy.previewRedeem(500e6); // 495: fee 5 at 100 bps
        vm.prank(alice);
        uint256 paid = lossy.redeem(token, 500e6, alice, want);
        assertEq(paid, 495e6);

        assertEq(lossy.lossCarryforward(), 2e6, "the loss is observed on the way in");
        // Of the 5 retained, 2 repays the loss and only 3 reaches the brand.
        assertEq(lossy.pendingYield(token), 3e6);
        _mintInto(lossy, token, 1e6); // any accrual
        assertEq(lossy.lossCarryforward(), 0);
        assertEq(lossy.pendingYield(token), 3e6);
    }

    function test_redemptionFee_threeArgOverloadAlsoCharges() public {
        _setFee(14);
        _mint(alice, tokenA, 1000e6);

        vm.prank(alice);
        uint256 paid = pool.redeem(tokenA, 1000e6, alice);

        assertEq(paid, 998_600_000);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 1_400_000);
        assertEq(pool.totalAssets(), 1_400_000);
    }

    function test_redemptionFee_parAsMinOutRevertsOnceAFeeIsSet() public {
        _mint(alice, tokenA, 1000e6);
        _setFee(14);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.InsufficientPayout.selector, 998_600_000, 1000e6
            )
        );
        pool.redeem(tokenA, 1000e6, alice, 1000e6);
        assertEq(PooledBrandToken(tokenA).balanceOf(alice), 1000e6, "nothing burned");
    }

    function test_redemptionFee_changedMidLifeAppliesOnlyToLaterRedemptions() public {
        _mint(alice, tokenA, 2000e6);

        vm.prank(alice);
        uint256 before = pool.redeem(tokenA, 500e6, alice);
        _setFee(14);
        vm.prank(alice);
        uint256 during = pool.redeem(tokenA, 500e6, alice);
        _setFee(0);
        vm.prank(alice);
        uint256 after_ = pool.redeem(tokenA, 500e6, alice);

        assertEq(before, 500e6, "par before the fee");
        assertEq(during, 499_300_000, "less the fee while set");
        assertEq(after_, 500e6, "par again once cleared");
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - 500e6 - 700_000);
        assertEq(pool.totalAssets(), 500e6 + 700_000, "only the middle redemption left a fee");
    }

    /// @dev `lastAccrualAssets -= fee` is clamped: a fee the reserve cannot cover must not turn
    ///      the last redemption out of a wrecked reserve into a revert.
    ///
    ///      Uses the four-argument overload with a zero bound, because the three-argument one
    ///      now demands par less the fee and would refuse this redemption outright. The subject
    ///      here is the baseline arithmetic under a payout the reserve cannot cover in full, not
    ///      which overload permits that payout, so opting into the haircut explicitly is the
    ///      faithful way to reach the state under test.
    function test_redemptionFee_neverUnderflowsTheBaselineOnANearlyEmptyReserve() public {
        (SharedReservePool lossy, IndexedLossSource source, address token) = _deployLossyPool();
        _mintInto(lossy, token, 1000e6);

        // 1,000 of brand backed by 0.5 of underlying; redeeming it all owes a fee of 10.
        source.simulateIndex(0.0005e18);
        assertEq(lossy.totalAssets(), 500_000);

        vm.prank(alice);
        uint256 paid = lossy.redeem(token, 1000e6, alice, 0);

        assertEq(paid, 500_000, "everything there was");
        assertEq(lossy.totalPooledSupply(), 0);
        assertEq(lossy.totalAssets(), 0);
        assertEq(lossy.lastAccrualAssets(), 0, "clamped at zero, not reverted");
    }

    // ─── The announced fee-increase delay ────────────────────────────────

    /// @dev The property an aggregator is actually buying: a quote it reads now is still the
    ///      price it fills at for the whole delay window, even though the owner has already
    ///      announced a rise. Covers `previewRedeem` and BOTH `redeem` overloads, because the
    ///      three-argument one now demands `previewRedeem(amount)` internally and would revert
    ///      the instant those two arithmetic paths disagreed.
    function test_feeIncrease_isInvisibleToEveryPayoutPathUntilCommitted() public {
        _setFee(20);
        _mint(alice, tokenA, 3000e6);

        uint256 quoted = pool.previewRedeem(1000e6);
        assertEq(quoted, 998e6);

        vm.prank(owner);
        pool.setRedemptionFee(80);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();
        assertEq(pool.pendingRedemptionFeeBps(), 80, "announced");
        assertEq(effectiveAt, uint64(block.timestamp) + pool.FEE_INCREASE_DELAY());
        assertEq(pool.redemptionFeeBps(), 20, "and not yet live");
        assertEq(pool.previewRedeem(1000e6), quoted, "the quote did not move");

        // One second before it can be committed, both overloads still settle at 20 bps, and
        // the three-argument one still satisfies its own `previewRedeem` demand.
        vm.warp(effectiveAt - 1);
        assertEq(pool.previewRedeem(1000e6), quoted);
        vm.prank(alice);
        assertEq(pool.redeem(tokenA, 1000e6, alice), quoted, "3-arg settles at the old fee");
        vm.prank(alice);
        assertEq(pool.redeem(tokenA, 1000e6, alice, quoted), quoted, "4-arg honours the old quote");

        vm.warp(effectiveAt);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 80);
        assertEq(pool.pendingRedemptionFeeBps(), 0, "pending is cleared on commit");
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "and so is the effective time");
        assertEq(pool.previewRedeem(1000e6), 992e6, "only now does the quote move");

        vm.prank(alice);
        assertEq(pool.redeem(tokenA, 1000e6, alice), 992e6);
    }

    function test_commitRedemptionFee_revertsBeforeTheHourAndWithNothingPending() public {
        vm.expectRevert(SharedReservePool.NoPendingFeeIncrease.selector);
        pool.commitRedemptionFee();

        vm.prank(owner);
        pool.setRedemptionFee(30);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();

        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SharedReservePool.FeeIncreaseNotReady.selector, effectiveAt, effectiveAt - 1
            )
        );
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 0, "a refused commit changes nothing");

        // Exactly at the effective time, not merely after it.
        vm.warp(effectiveAt);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 30);

        vm.expectRevert(SharedReservePool.NoPendingFeeIncrease.selector);
        pool.commitRedemptionFee();
    }

    /// @dev Permissionless on purpose: the value and its earliest time were both fixed by the
    ///      owner an hour ago, so gating the second transaction would only create a window in
    ///      which the fee looks raised to anyone reading the schedule while redemptions still
    ///      charge the old one.
    function test_commitRedemptionFee_isPermissionless() public {
        vm.prank(owner);
        pool.setRedemptionFee(25);
        vm.warp(pool.redemptionFeeEffectiveAt());

        vm.prank(bob);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 25);
    }

    /// @dev A decrease needs no warning: it cannot make a quoted redemption settle worse than
    ///      quoted, and in an incident cutting the fee in one transaction is the point.
    function test_feeDecrease_appliesImmediatelyAndCancelsAPendingIncrease() public {
        _setFee(20);
        _mint(alice, tokenA, 1000e6);

        vm.prank(owner);
        pool.setRedemptionFee(80);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();

        vm.warp(block.timestamp + 40 minutes);
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeIncreaseCancelled(10, 80, effectiveAt);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeUpdated(20, 10);
        pool.setRedemptionFee(10);

        assertEq(pool.redemptionFeeBps(), 10, "a cut lands in the same transaction");
        assertEq(pool.pendingRedemptionFeeBps(), 0);
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "the announced rise is gone, not paused");
        assertEq(pool.previewRedeem(1000e6), 999e6);

        // The stale 80 cannot be resurrected: it was authorised against a 20 bps baseline, and
        // committing it now would move a 10 bps fee to 80 with no fresh hour of warning.
        vm.warp(effectiveAt + 1);
        vm.expectRevert(SharedReservePool.NoPendingFeeIncrease.selector);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 10);

        // Reaching 80 after the cut means announcing it again and serving a whole new hour.
        vm.prank(owner);
        pool.setRedemptionFee(80);
        uint64 reannounced = pool.redemptionFeeEffectiveAt();
        assertEq(reannounced, uint64(block.timestamp) + pool.FEE_INCREASE_DELAY());
        vm.warp(reannounced);
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 80);
    }

    /// @dev Re-announcing restarts the clock rather than inheriting the first announcement's
    ///      remaining time, which would otherwise let the owner announce a token rise, wait out
    ///      the hour, and then raise the pending value with a minute's notice.
    function test_secondAnnouncementReplacesTheFirstAndRestartsTheClock() public {
        vm.prank(owner);
        pool.setRedemptionFee(30);
        uint64 first = pool.redemptionFeeEffectiveAt();

        vm.warp(block.timestamp + 59 minutes);
        vm.prank(owner);
        pool.setRedemptionFee(100);
        uint64 second = pool.redemptionFeeEffectiveAt();

        assertEq(pool.pendingRedemptionFeeBps(), 100);
        assertEq(second, uint64(block.timestamp) + pool.FEE_INCREASE_DELAY());
        assertGt(second, first + 58 minutes, "the clock restarted");

        vm.warp(first);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.FeeIncreaseNotReady.selector, second, first)
        );
        pool.commitRedemptionFee();
        assertEq(pool.redemptionFeeBps(), 0);
    }

    function test_cancelPendingRedemptionFee_isOwnerOnlyAndLeavesTheLiveFeeAlone() public {
        _setFee(20);
        vm.prank(owner);
        pool.setRedemptionFee(90);
        uint64 effectiveAt = pool.redemptionFeeEffectiveAt();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.cancelPendingRedemptionFee();
        assertEq(pool.pendingRedemptionFeeBps(), 90, "a stranger cannot drop it either");

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(pool));
        emit SharedReservePool.RedemptionFeeIncreaseCancelled(20, 90, effectiveAt);
        pool.cancelPendingRedemptionFee();

        assertEq(pool.redemptionFeeBps(), 20, "the live fee never moved");
        assertEq(pool.redemptionFeeEffectiveAt(), 0);

        vm.warp(effectiveAt);
        vm.expectRevert(SharedReservePool.NoPendingFeeIncrease.selector);
        pool.commitRedemptionFee();

        vm.prank(owner);
        vm.expectRevert(SharedReservePool.NoPendingFeeIncrease.selector);
        pool.cancelPendingRedemptionFee();
    }

    /// @dev A non-owner cannot announce one either, which is the half that matters: a schedule
    ///      anyone could write would be a way to make an integrator quote defensively against a
    ///      rise the owner never intended.
    function test_onlyTheOwnerCanAnnounceAnIncrease() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setRedemptionFee(50);
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "nothing was announced");
    }

    /// @dev Setting the fee to the value it already holds is not an increase, so it takes the
    ///      immediate path — and clears anything pending, the same as a cut.
    function test_reassertingTheCurrentFeeClearsAPendingIncrease() public {
        _setFee(20);
        vm.prank(owner);
        pool.setRedemptionFee(60);
        assertEq(pool.pendingRedemptionFeeBps(), 60);

        vm.prank(owner);
        pool.setRedemptionFee(20);
        assertEq(pool.redemptionFeeBps(), 20);
        assertEq(pool.redemptionFeeEffectiveAt(), 0, "the announcement was withdrawn");
    }
}

/// @dev `MockYieldSource` whose index can be set directly, to book a loss without a transfer.
contract IndexedLossSource is MockYieldSource {
    function simulateIndex(uint256 newIndex) external {
        index = newIndex;
    }
}
