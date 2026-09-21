// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title PoolBrandTreasuryFloatShare
/// @notice The float-share ledger on `PoolBrandTreasury`: a shared quote dollar backing float
///         that sits in markets it does not own divides its reserve yield with those markets.
///
///         Deliberately a one-brand fixture rather than the whole launchpad stack. The pool's
///         accrual index is pool-wide (`cumulativeYieldPerToken` divides growth by
///         `totalPooledSupply`), so a single registered brand makes the brand's entitlement
///         equal to the whole accrual and every split below exact arithmetic instead of a
///         tolerance stack. The market fee vaults are plain addresses: the treasury only ever
///         `safeTransfer`s to a vault and reads `msg.sender`, so nothing about a real
///         `BrandFeeVault` is load-bearing here.
///
///         **The dust bound.** Every assertion on a vault's payout allows 1 wei. The split is
///         three floor divisions: `toMarkets = floor(got * float / outstanding)`, then
///         `cumulativePerFloat += floor(toMarkets * WAD / float)`, then
///         `paid = floor(float * indexDelta / WAD)`. The first is the split itself and its
///         remainder is the issuer's. The other two are a round trip through the index, and
///         lose under `float / WAD + 1` wei — at most 1 wei for any float this reserve can
///         hold, since a 6-decimal float is ~1e9 against a WAD of 1e18. What the index rounds
///         off is not lost, it stays in `marketReserve`, which is why the conservation
///         assertions check `balanceOf(treasury) == marketReserve` rather than zero.
contract PoolBrandTreasuryFloatShareTest is Test, StackFixture {
    SharedReservePool pool;
    MockUSDC usdc;
    MockYieldSource yieldSource;

    address brandToken;
    PoolBrandTreasury treasury;

    address poolOwner = address(0x0AD01);
    address issuer = address(0x1551E);
    address marketFactory = address(0xFAC70);
    address holder = address(0xA11CE);
    address issuerPayout = address(0x9A10);
    address attacker = address(0xBAD);

    address vaultOne = address(0x0A1);
    address vaultTwo = address(0x0A2);
    address vaultNoFloat = address(0x0A3);

    /// @dev Round figures on purpose: 1e9 outstanding against a 1e18 index makes every split
    ///      below exact, so a failure is a real arithmetic error and not accumulated dust.
    uint256 constant OUTSTANDING = 1_000e6;
    uint256 constant YIELD = 100e6;
    uint256 constant FLOAT = 250e6;

    function setUp() public {
        _deployUpgradeBase();
        usdc = new MockUSDC();
        yieldSource = new MockYieldSource();
        pool = _deployReservePool(address(usdc), address(yieldSource), poolOwner);

        address treasuryAddr;
        (brandToken, treasuryAddr) = pool.registerBrand("Shared USD", "shUSD", issuer);
        treasury = PoolBrandTreasury(treasuryAddr);

        _mintBrand(OUTSTANDING);

        vm.prank(issuer);
        treasury.setFactory(marketFactory);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _mintBrand(uint256 amount) internal {
        usdc.mint(holder, amount);
        vm.startPrank(holder);
        usdc.approve(address(pool), amount);
        pool.mint(brandToken, amount, holder);
        vm.stopPrank();
    }

    /// @dev The repo idiom for reserve yield: hand the source the interest and let its index
    ///      grow, exactly as `SharedReservePool.t.sol` does.
    function _accrue(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdc), amount);
    }

    function _registerFloat(address vault, uint256 amount) internal {
        vm.prank(marketFactory);
        treasury.registerFloat(vault, amount);
    }

    function _claimFloat(address vault) internal returns (uint256) {
        vm.prank(vault);
        return treasury.claimFloatShare();
    }

    function _issuerClaim() internal returns (uint256) {
        vm.prank(issuer);
        return treasury.claim(issuerPayout);
    }

    function _marketsShareOf(uint256 got, uint256 float) internal pure returns (uint256) {
        return Math.mulDiv(got, float, OUTSTANDING);
    }

    // ─── Proportional split ──────────────────────────────────────────────

    function test_claimFloatShare_paysTheMarketsFloatOverOutstandingAndTheIssuerTheRest() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);

        uint256 toVault = _claimFloat(vaultOne);
        uint256 claimed = treasury.totalYieldClaimed();

        assertEq(usdc.balanceOf(vaultOne), toVault, "the return value is what the vault holds");
        assertApproxEqAbs(
            toVault,
            _marketsShareOf(claimed, FLOAT),
            1,
            "the market's share is float/outstanding of the brand's claim"
        );

        uint256 toIssuer = _issuerClaim();
        assertEq(usdc.balanceOf(issuerPayout), toIssuer, "the issuer is paid its return value");
        assertApproxEqAbs(
            toVault + toIssuer, claimed, 1, "market plus issuer is the whole claim, less dust"
        );
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.marketReserve(),
            "whatever stays behind is exactly the markets' unpaid reserve"
        );
    }

    function testFuzz_claimFloatShare_conservesTheClaimForAnyFloat(uint256 float, uint256 yield)
        public
    {
        float = bound(float, 1, OUTSTANDING);
        yield = bound(yield, 1e6, 1_000_000e6);

        _registerFloat(vaultOne, float);
        _accrue(yield);

        uint256 toVault = _claimFloat(vaultOne);
        uint256 claimed = treasury.totalYieldClaimed();
        uint256 toIssuer = _issuerClaim();

        assertApproxEqAbs(
            toVault, _marketsShareOf(claimed, float), 1, "the market's share is proportional"
        );
        assertApproxEqAbs(toVault + toIssuer, claimed, 1, "nothing is created or destroyed");
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.marketReserve(),
            "any residue is still owed to the markets"
        );
    }

    // ─── No float, no change ─────────────────────────────────────────────

    function test_claim_paysTheIssuerEverythingWhenNoFloatIsRegistered() public {
        _accrue(YIELD);
        uint256 entitlement = pool.pendingYield(brandToken);
        assertGt(entitlement, 0, "the brand has accrued something to claim");

        uint256 paid = _issuerClaim();

        assertEq(paid, entitlement, "the issuer receives the brand's whole entitlement");
        assertEq(usdc.balanceOf(issuerPayout), entitlement, "and it lands on the receiver");
        assertEq(treasury.totalFloat(), 0, "no float was registered");
        assertEq(treasury.marketReserve(), 0, "so nothing is withheld");
        assertEq(treasury.cumulativePerFloat(), 0, "and the index never moved");
        assertEq(usdc.balanceOf(address(treasury)), 0, "the treasury keeps nothing back");
    }

    // ─── Many vaults ─────────────────────────────────────────────────────

    function test_claimFloatShare_splitsProRataAndPaysAnUnseededVaultNothing() public {
        uint256 floatOne = 300e6;
        uint256 floatTwo = 100e6;
        _registerFloat(vaultOne, floatOne);
        _registerFloat(vaultTwo, floatTwo);
        _accrue(YIELD);

        uint256 entitlementBefore = pool.pendingYield(brandToken);
        assertEq(_claimFloat(vaultNoFloat), 0, "a vault with no registered float is paid zero");
        assertEq(usdc.balanceOf(vaultNoFloat), 0, "and receives nothing");
        assertEq(
            treasury.totalYieldClaimed(),
            0,
            "an unseeded vault does not pull the brand's yield out of the reserve"
        );
        assertEq(pool.pendingYield(brandToken), entitlementBefore, "the entitlement is untouched");

        uint256 gotOne = _claimFloat(vaultOne);
        uint256 gotTwo = _claimFloat(vaultTwo);
        uint256 claimed = treasury.totalYieldClaimed();

        assertApproxEqAbs(gotOne, _marketsShareOf(claimed, floatOne), 1, "first vault pro rata");
        assertApproxEqAbs(gotTwo, _marketsShareOf(claimed, floatTwo), 1, "second vault pro rata");
        assertApproxEqAbs(gotOne, gotTwo * 3, 1, "three times the float is three times the pay");

        uint256 toIssuer = _issuerClaim();
        assertApproxEqAbs(
            gotOne + gotTwo + toIssuer, claimed, 1, "both markets plus the issuer is the claim"
        );
        assertApproxEqAbs(
            toIssuer,
            claimed - _marketsShareOf(claimed, floatOne + floatTwo),
            1,
            "the issuer keeps the supply that is not sitting in a market"
        );
    }

    // ─── The cap ─────────────────────────────────────────────────────────

    function test_pull_capsTheMarketsShareAtOutstandingWhenTheBrandIsRedeemedDown() public {
        _registerFloat(vaultOne, OUTSTANDING);

        // Holders exit until the registered float is larger than the whole brand supply, which
        // is the case that would otherwise owe the markets more than there is to pay.
        vm.prank(holder);
        pool.redeem(brandToken, 800e6, holder);
        assertGt(
            treasury.totalFloat(), pool.outstandingOf(brandToken), "float now exceeds outstanding"
        );

        _accrue(YIELD);
        uint256 toVault = _claimFloat(vaultOne);
        uint256 claimed = treasury.totalYieldClaimed();
        assertGt(claimed, 0, "the brand still earned something on its remaining supply");

        assertApproxEqAbs(toVault, claimed, 1, "the markets take the whole claim, never more");
        assertEq(_issuerClaim(), 0, "and the issuer is paid nothing");
        assertEq(usdc.balanceOf(issuerPayout), 0, "nothing reached the issuer's receiver");
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.marketReserve(),
            "the treasury holds exactly the markets' residue"
        );
    }

    // ─── registerFloat settles before it reweighs ────────────────────────

    function test_registerFloat_settlesTheOldWeightBeforeApplyingTheNewOne() public {
        uint256 floatBefore = 100e6;
        uint256 floatAfter = 500e6;

        _registerFloat(vaultOne, floatBefore);
        _accrue(YIELD);

        // Reweighing must pay out the first tranche at the OLD float on the way through.
        _registerFloat(vaultOne, floatAfter);
        uint256 firstClaim = treasury.totalYieldClaimed();
        uint256 firstTranche = usdc.balanceOf(vaultOne);
        assertApproxEqAbs(
            firstTranche,
            _marketsShareOf(firstClaim, floatBefore),
            1,
            "yield earned under the old float is paid at the old float"
        );

        _accrue(YIELD);
        uint256 secondTranche = _claimFloat(vaultOne);
        uint256 secondClaim = treasury.totalYieldClaimed() - firstClaim;
        assertGt(secondClaim, 0, "the second tranche of yield was really claimed");
        assertApproxEqAbs(
            secondTranche,
            _marketsShareOf(secondClaim, floatAfter),
            1,
            "yield earned under the new float is paid at the new float"
        );

        uint256 total = usdc.balanceOf(vaultOne);
        assertApproxEqAbs(
            total,
            _marketsShareOf(firstClaim, floatBefore) + _marketsShareOf(secondClaim, floatAfter),
            2,
            "the vault's total is the sum of each tranche at the rate it was earned"
        );
        // The two ways to get the ordering wrong, named explicitly.
        assertLt(
            total,
            _marketsShareOf(firstClaim + secondClaim, floatAfter),
            "the new float must not reprice yield the old float earned"
        );
        assertGt(
            total,
            _marketsShareOf(firstClaim + secondClaim, floatBefore),
            "the old float must not hold down yield the new float earned"
        );
    }

    // ─── Deregistration ──────────────────────────────────────────────────

    function test_registerFloat_zeroPaysTheTailAndStopsTheVaultEarning() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);

        _registerFloat(vaultOne, 0);
        uint256 firstClaim = treasury.totalYieldClaimed();
        uint256 tail = usdc.balanceOf(vaultOne);
        assertApproxEqAbs(
            tail,
            _marketsShareOf(firstClaim, FLOAT),
            1,
            "deregistering pays out what the float had already earned"
        );
        assertEq(treasury.floatOf(vaultOne), 0, "the vault's float is gone");
        assertEq(treasury.totalFloat(), 0, "and it left totalFloat");

        _accrue(YIELD);
        assertEq(_claimFloat(vaultOne), 0, "a deregistered vault earns nothing afterwards");
        assertEq(usdc.balanceOf(vaultOne), tail, "its balance is unchanged");
        assertEq(treasury.pendingFloatShare(vaultOne), 0, "and it is owed nothing");

        uint256 toIssuer = _issuerClaim();
        uint256 secondClaim = treasury.totalYieldClaimed() - firstClaim;
        assertGt(secondClaim, 0, "the brand earned a second tranche");
        assertApproxEqAbs(
            toIssuer,
            firstClaim + secondClaim - tail,
            1,
            "the issuer takes the whole second tranche once no float remains"
        );
    }

    // ─── The issuer cannot take the markets' money ───────────────────────

    function test_distribute_cannotReachTheMarketReserveAndClaimNeverPaysIt() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);

        // The issuer's own claim is what pulls and withholds the markets' share.
        _issuerClaim();
        uint256 reserved = treasury.marketReserve();
        assertEq(
            reserved,
            _marketsShareOf(treasury.totalYieldClaimed(), FLOAT),
            "the markets' share is withheld from the issuer's claim"
        );
        assertEq(usdc.balanceOf(address(treasury)), reserved, "and it is all that is left in here");

        vm.prank(issuer);
        assertEq(treasury.claim(issuerPayout), 0, "a second claim finds nothing claimable");

        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.ZeroAmount.selector);
        treasury.distribute(address(usdc), attacker, 1);

        // A donation makes the boundary observable: spare is payable, spare + 1 is not.
        uint256 spare = 7e6;
        usdc.mint(address(treasury), spare);
        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.ZeroAmount.selector);
        treasury.distribute(address(usdc), attacker, spare + 1);

        vm.prank(issuer);
        treasury.distribute(address(usdc), attacker, spare);
        assertEq(usdc.balanceOf(attacker), spare, "the issuer may take everything above reserve");
        assertEq(usdc.balanceOf(address(treasury)), reserved, "the reserve itself never moved");

        assertEq(_claimFloat(vaultOne), reserved, "and the market can still be paid in full");
        assertEq(usdc.balanceOf(address(treasury)), 0, "which empties the treasury");
    }

    // ─── Authorisation ───────────────────────────────────────────────────

    function test_registerFloat_onlyTheNamedFactoryMayCallIt() public {
        vm.prank(attacker);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(vaultOne, FLOAT);

        // Not even the admin: registering float is the factory's statement about what a market
        // locked, and an issuer able to forge it could divert its own yield to an address it
        // controls.
        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(vaultOne, FLOAT);

        assertEq(treasury.totalFloat(), 0, "no float was recorded");
    }

    function test_setFactory_onlyTheAdminMayNameTheFactory() public {
        vm.prank(attacker);
        vm.expectRevert(PoolBrandTreasury.OnlyAdmin.selector);
        treasury.setFactory(attacker);

        assertEq(treasury.factory(), marketFactory, "the factory is unchanged");
    }

    function test_setFactory_zeroStopsNewFloatWithoutConfiscatingTheOld() public {
        _registerFloat(vaultOne, FLOAT);

        vm.prank(issuer);
        treasury.setFactory(address(0));
        assertEq(treasury.factory(), address(0), "the factory is revoked");

        vm.prank(marketFactory);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(vaultTwo, FLOAT);
        assertEq(treasury.floatOf(vaultTwo), 0, "no new market can be added");

        // Already-registered float keeps earning and stays claimable.
        assertEq(treasury.floatOf(vaultOne), FLOAT, "the existing float is untouched");
        assertEq(treasury.totalFloat(), FLOAT, "and still counts");

        _accrue(YIELD);
        uint256 toVault = _claimFloat(vaultOne);
        assertApproxEqAbs(
            toVault,
            _marketsShareOf(treasury.totalYieldClaimed(), FLOAT),
            1,
            "revoking the factory does not confiscate what was already registered"
        );
    }

    // ─── The preview ─────────────────────────────────────────────────────

    function test_pendingFloatShare_matchesWhatClaimFloatSharePays() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);
        assertEq(
            treasury.pendingFloatShare(vaultOne),
            0,
            "yield the treasury has not pulled yet is not previewed"
        );

        _issuerClaim(); // pulls, which is what moves the index
        uint256 previewed = treasury.pendingFloatShare(vaultOne);
        assertGt(previewed, 0, "the pull credited the vault");

        uint256 paid = _claimFloat(vaultOne);
        assertEq(paid, previewed, "the preview is exactly what the vault is paid");
        assertEq(usdc.balanceOf(vaultOne), previewed, "and what it receives");
        assertEq(treasury.pendingFloatShare(vaultOne), 0, "nothing is owed once it is paid");
        assertEq(
            treasury.checkpointOf(vaultOne),
            treasury.cumulativePerFloat(),
            "the vault is checkpointed at the index it was paid against"
        );
    }

    // ─── Naming a factory is one-way ─────────────────────────────────────

    function test_setFactory_cannotBeRePointedAtASecondFactory() public {
        assertEq(treasury.namedFactory(), marketFactory, "the first naming is remembered");

        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.FactoryAlreadyNamed.selector);
        treasury.setFactory(attacker);

        // Nor by going through zero first: the memory is never cleared.
        vm.prank(issuer);
        treasury.setFactory(address(0));
        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.FactoryAlreadyNamed.selector);
        treasury.setFactory(attacker);

        assertEq(treasury.factory(), address(0), "the revocation stands");
        assertEq(treasury.namedFactory(), marketFactory, "and the named factory is unchanged");
    }

    /// @notice `namedFactory` is new state on a live beacon implementation, so where it landed
    ///         is load-bearing: the first slot of the old `__gap`, directly below
    ///         `marketReserve`, with the gap shortened by exactly one.
    function test_namedFactory_isAppendedBelowMarketReserveInTheOldGap() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);
        _issuerClaim();
        assertGt(treasury.marketReserve(), 0, "slot 9 holds something worth checking");

        assertEq(
            uint256(vm.load(address(treasury), bytes32(uint256(9)))),
            treasury.marketReserve(),
            "marketReserve did not move off slot 9"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(treasury), bytes32(uint256(10)))))),
            treasury.namedFactory(),
            "namedFactory took slot 10, the first slot the gap used to cover"
        );
    }

    function test_setFactory_revocationIsReversibleButOnlyBackToTheNamedFactory() public {
        _registerFloat(vaultOne, FLOAT);

        vm.prank(issuer);
        treasury.setFactory(address(0));
        vm.prank(marketFactory);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(vaultTwo, FLOAT);

        // Re-opting in costs the issuer one call and needs nobody's permission, which is what
        // keeps a graduation deferred behind a revocation recoverable.
        vm.prank(issuer);
        treasury.setFactory(marketFactory);
        assertEq(treasury.factory(), marketFactory, "consent is restored");

        _registerFloat(vaultTwo, FLOAT);
        assertEq(treasury.floatOf(vaultTwo), FLOAT, "and the factory may register again");
        assertEq(treasury.totalFloat(), FLOAT * 2, "both markets now count");
    }

    /// @notice The confiscation PBT-REVOKE described: name a factory the admin controls, then
    ///         zero a graduated market's float. Both halves are now impossible, and the float
    ///         goes on earning across the attempt.
    function test_setFactory_aHostileFactoryCannotEndAGraduatedMarketsShare() public {
        _registerFloat(vaultOne, FLOAT);

        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.FactoryAlreadyNamed.selector);
        treasury.setFactory(issuer);

        // The strongest position the admin can reach is a revoked factory, which is exactly
        // the position the NatSpec describes: no new registrations, nothing taken away.
        vm.prank(issuer);
        treasury.setFactory(address(0));
        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(vaultOne, 0);

        assertEq(treasury.floatOf(vaultOne), FLOAT, "the market's float survives the attempt");
        assertEq(treasury.totalFloat(), FLOAT, "and still weighs on every later pull");

        _accrue(YIELD);
        uint256 toVault = _claimFloat(vaultOne);
        assertApproxEqAbs(
            toVault,
            _marketsShareOf(treasury.totalYieldClaimed(), FLOAT),
            1,
            "and it is paid its whole share of yield earned after the attempt"
        );
    }

    /// @notice The other route to the same place: rather than zeroing the victim, register a
    ///         vault of your own with a float large enough to take the whole split.
    function test_setFactory_aHostileFactoryCannotDiluteTheSplitWithItsOwnFloat() public {
        _registerFloat(vaultOne, FLOAT);
        address issuerVault = address(0xDEF1);

        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.FactoryAlreadyNamed.selector);
        treasury.setFactory(issuer);

        // Without the factory role the registration itself is unreachable, from the admin and
        // from anyone else.
        vm.prank(issuer);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(issuerVault, type(uint128).max);
        vm.prank(attacker);
        vm.expectRevert(PoolBrandTreasury.OnlyFactory.selector);
        treasury.registerFloat(issuerVault, type(uint128).max);

        assertEq(treasury.floatOf(issuerVault), 0, "no float was planted");
        assertEq(treasury.totalFloat(), FLOAT, "the weight is still only the real market's");

        _accrue(YIELD);
        uint256 toVault = _claimFloat(vaultOne);
        uint256 claimed = treasury.totalYieldClaimed();
        assertApproxEqAbs(
            toVault,
            _marketsShareOf(claimed, FLOAT),
            1,
            "the market keeps the undiluted float/outstanding split"
        );
        assertGt(_issuerClaim(), 0, "and the issuer is still paid its own side, not everything");
        assertEq(usdc.balanceOf(issuerVault), 0, "the planted vault was never paid");
    }

    // ─── Rounding: what the index promises is what is withheld ───────────

    /// @dev What the OLD `_pull` added to `marketReserve` and no vault could ever be paid:
    ///      it credited the unrounded `share` while the index could only ever express
    ///      `floor(share * WAD / float)`. Reproduced here so the assertions below can state
    ///      the size of the bound that was tightened rather than assert it in the abstract.
    function _strandedUnderOldBooking(uint256 got, uint256 float) internal pure returns (uint256) {
        uint256 share = Math.mulDiv(got, float, OUTSTANDING);
        uint256 delta = Math.mulDiv(share, 1e18, float);
        return share - Math.mulDiv(delta, float, 1e18);
    }

    /// @notice A float that does not divide `WAD` is the case that used to strand a wei on
    ///         every pull. The treasury must now end completely empty: the reserve is credited
    ///         with `floor(delta * float / WAD)`, which for a single vault is the identical
    ///         floor `_settleAndPay` pays out.
    function test_pull_booksOnlyWhatTheIndexPromisedSoNothingIsStranded() public {
        uint256 awkward = 333_333_333; // 1e18 % awkward != 0, so the index round trip loses
        _registerFloat(vaultOne, awkward);
        _accrue(YIELD);

        uint256 toVault = _claimFloat(vaultOne);
        uint256 claimed = treasury.totalYieldClaimed();

        uint256 strandedBefore = _strandedUnderOldBooking(claimed, awkward);
        assertEq(strandedBefore, 1, "the old booking stranded exactly one wei on this pull");

        uint256 toIssuer = _issuerClaim();

        assertEq(treasury.marketReserve(), 0, "the markets' book is settled to the wei");
        assertEq(usdc.balanceOf(address(treasury)), 0, "and the treasury holds nothing back");
        assertEq(
            toVault + toIssuer, claimed, "every wei of the claim reached the vault or the issuer"
        );
        assertApproxEqAbs(
            toVault, _marketsShareOf(claimed, awkward), 1, "the split itself is unchanged"
        );
    }

    /// @notice With several vaults the residual is the per-vault flooring and nothing else:
    ///         strictly under one wei per registered vault, where before it was that plus the
    ///         index remainder `_strandedUnderOldBooking` measures.
    function test_pull_residualAfterEveryoneClaimsIsOnlyThePerVaultFlooring() public {
        uint256 floatOne = 333_333_333;
        uint256 floatTwo = 111_111_111;
        _registerFloat(vaultOne, floatOne);
        _registerFloat(vaultTwo, floatTwo);
        _accrue(YIELD);

        uint256 gotOne = _claimFloat(vaultOne); // the only pull; nothing accrues after it
        uint256 claimed = treasury.totalYieldClaimed();
        uint256 gotTwo = _claimFloat(vaultTwo);
        uint256 toIssuer = _issuerClaim();

        uint256 residual = usdc.balanceOf(address(treasury));
        assertEq(residual, treasury.marketReserve(), "the residue is still booked to markets");
        assertLt(residual, 2, "under one wei per vault, for two vaults and one pull");
        assertEq(gotOne + gotTwo + toIssuer + residual, claimed, "the claim is fully accounted for");

        uint256 strandedBefore = _strandedUnderOldBooking(claimed, floatOne + floatTwo);
        assertGt(strandedBefore, 0, "the old booking stranded the index remainder as well");
        // The per-vault flooring is unchanged by this fix, so the same run under the old
        // booking would have left that same `residual` PLUS the whole index remainder.
        uint256 residualBefore = residual + strandedBefore;
        assertLt(residual, residualBefore, "the conservation bound tightened by the remainder");
    }

    function testFuzz_pull_marketReserveNeverExceedsWhatTheIndexCanPayOut(
        uint256 float,
        uint256 yield
    ) public {
        float = bound(float, 1, OUTSTANDING);
        yield = bound(yield, 1e6, 1_000_000e6);

        _registerFloat(vaultOne, float);
        _accrue(yield);
        _issuerClaim(); // pulls without settling any vault

        assertEq(
            treasury.marketReserve(),
            treasury.pendingFloatShare(vaultOne),
            "everything withheld from the issuer is promised to the vault to the wei"
        );
        uint256 owed = treasury.pendingFloatShare(vaultOne);
        assertEq(_claimFloat(vaultOne), owed, "and the vault can draw all of it");
        assertEq(treasury.marketReserve(), 0, "leaving nothing stranded");
        assertEq(usdc.balanceOf(address(treasury)), 0, "and an empty treasury");
    }

    // ─── The claim event distinguishes its two numbers ───────────────────

    function test_claim_eventReportsThePoolClaimAndTheForwardedAmountSeparately() public {
        _registerFloat(vaultOne, FLOAT);
        _accrue(YIELD);

        // A stray balance is the clearest case: the forwarded amount is neither the pool claim
        // nor the issuer's share of it.
        uint256 donation = 5e6;
        usdc.mint(address(treasury), donation);

        uint256 entitlement = pool.pendingYield(brandToken);
        uint256 toMarkets = _marketsShareOf(entitlement, FLOAT);
        uint256 forwarded = entitlement - toMarkets + donation;

        vm.expectEmit(true, true, true, true, address(treasury));
        emit PoolBrandTreasury.Claimed(entitlement, forwarded, issuerPayout);
        uint256 paid = _issuerClaim();

        assertEq(paid, forwarded, "the return value is the forwarded amount");
        assertEq(
            treasury.totalYieldClaimed(),
            entitlement,
            "while totalYieldClaimed tracks the pool claim, which the event now also carries"
        );
        assertTrue(forwarded != entitlement, "the two numbers really are distinguishable here");
    }
}
