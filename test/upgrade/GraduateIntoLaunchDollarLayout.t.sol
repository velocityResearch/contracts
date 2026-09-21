// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {ILaunchFactory} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {LaunchpadFixture} from "../launchpad/LaunchpadFixture.sol";

/// @dev A treasury implementation that appends one variable BELOW the parent's `__gap`, which
///      is where a later version's state is supposed to go. Where that variable lands is the
///      whole of the gap arithmetic: the parent's footprint is forty-nine slots, so an
///      appended field can only be at slot forty-nine if the six float fields and
///      `namedFactory` were taken OUT of the gap rather than added on top of it.
contract PoolBrandTreasuryV2 is PoolBrandTreasury {
    uint256 public appendedAfterTheGap;

    function setAppended(uint256 value) external {
        appendedAfterTheGap = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev The same, for the distributor: its footprint is sixty-two slots, unchanged by
///      `rewardsRenounced`, `minStakeWeight` and `_floorSet` eating three of them.
contract LpRewardDistributorV2 is LpRewardDistributor {
    uint256 public appendedAfterTheGap;

    function setAppended(uint256 value) external {
        appendedAfterTheGap = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev The same, for the launch factory: its footprint is fifty-eight slots, because
///      `reserveEconomics` came OUT of its gap rather than on top of it, so an appended field
///      still lands exactly where it would have before the mapping existed.
contract LaunchFactoryV2 is LaunchFactory {
    uint256 public appendedAfterTheGap;

    function setAppended(uint256 value) external {
        appendedAfterTheGap = value;
    }
}

/// @title GraduateIntoLaunchDollarLayoutTest
/// @notice The storage half of "graduate into the launch's own dollar". The change appends six
///         fields to `PoolBrandTreasury`, three to `LpRewardDistributor`, keeps — rather than
///         deletes — two bytes inside one of `LaunchFactory`'s packed slots that nothing in
///         this repository writes any more, and retires the whole slot the factory's per-brand
///         economics mapping occupied, appending the reserve-keyed replacement below
///         everything already written. All three are live behind proxies, so a layout mistake
///         is not a compile error: it is a brand's float ledger reinterpreted as somebody
///         else's numbers.
///
///         `LaunchpadFeeSplitUpgradeMainnetFork` proves the `LaunchFactory` half against the
///         deployed proxy. This is the offline twin and covers what that one cannot, because
///         the treasury and the distributor this change touches do not exist on that chain in
///         their post-change form: the before-state is built here, on a real graduated market.
///
///         Slot numbers are written out as constants rather than derived, deliberately. The
///         test is supposed to STATE the layout — a future author who appends a field above
///         `rewardsRenounced` should have to come here and change a number that says, in
///         words, what a live market already wrote there.
contract GraduateIntoLaunchDollarLayoutTest is LaunchpadFixture {
    // ─── The layout, as a live proxy holds it ────────────────────────────

    /// @dev `LaunchFactory`: `graduatedCreatorShareBps` (2 bytes), `launchEnabled` (1),
    ///      `graduatedCreatorYieldShareBps` (2), `lpFundRecipient` (20), `lpFundShareBps` (2),
    ///      `graduatedLpFundShareBps` (2) — 29 bytes of one slot.
    ///
    ///      The third field is the one worth naming. Nothing here writes it and a fresh
    ///      deployment reads zero out of it, but it is public and it holds bytes 3-4 because
    ///      the DEPLOYED, non-upgradeable `LaunchLocker` that serves markets 16/17/18 calls
    ///      its getter unconditionally inside `collect()`. Delete it and two things break at
    ///      once: that getter, and `lpFundRecipient`, which slides down to byte 3 of a live
    ///      proxy's slot. That is what this test exists to catch.
    uint256 constant FACTORY_PACKED_SLOT = 12;
    /// @dev Slot 13 held the per-brand `pairTokenEconomics` mapping. Economics are keyed by
    ///      RESERVE now, and the slot is a private `uint256` placeholder rather than the new
    ///      mapping: the live proxy still holds the old entries under brand keys, and a
    ///      mapping of a different value type here would decode them as garbage. Nothing
    ///      reads it, nothing below it may move, and no test asserts its contents.
    uint256 constant FACTORY_RETIRED_ECONOMICS_SLOT = 13;
    uint256 constant FACTORY_LAUNCHED_TOKENS_SLOT = 14;
    uint256 constant FACTORY_PENDING_RECIPIENT_SLOT = 15;
    uint256 constant FACTORY_LAUNCH_CONFIGS_SLOT = 16;
    uint256 constant FACTORY_LAUNCHES_SLOT = 17;
    /// @dev Appended below everything already written and taken out of the gap, which shrank
    ///      from `uint256[40]` to `uint256[38]`: `reserveEconomics` first, then the segmented
    ///      curves' `_launchConfigSegments`. 18 + 2 + 38 is the 18 + 40 the contract occupied
    ///      before either mapping existed, so the footprint is still 58 slots and a later
    ///      version's appended state still starts at 58.
    uint256 constant FACTORY_RESERVE_ECONOMICS_SLOT = 18;
    uint256 constant FACTORY_LAUNCH_CONFIG_SEGMENTS_SLOT = 19;
    uint256 constant FACTORY_GAP_START_SLOT = 20;
    uint256 constant FACTORY_GAP_SLOTS = 38;

    /// @dev `PoolBrandTreasury`, in declaration order. Slots 0-3 predate this change; 4-9 are
    ///      the six the float share added and 10 is `namedFactory`, which the one-way
    ///      `setFactory` fix appended. The gap starts at 11 and is 38 long, so the whole
    ///      contract still occupies 49 slots — exactly what it occupied when the gap was 45
    ///      and started at 4.
    uint256 constant TREASURY_POOL_SLOT = 0;
    uint256 constant TREASURY_BRAND_TOKEN_SLOT = 1;
    uint256 constant TREASURY_ADMIN_SLOT = 2;
    uint256 constant TREASURY_TOTAL_YIELD_CLAIMED_SLOT = 3;
    uint256 constant TREASURY_FACTORY_SLOT = 4;
    uint256 constant TREASURY_FLOAT_OF_SLOT = 5;
    uint256 constant TREASURY_TOTAL_FLOAT_SLOT = 6;
    uint256 constant TREASURY_CUMULATIVE_PER_FLOAT_SLOT = 7;
    uint256 constant TREASURY_CHECKPOINT_OF_SLOT = 8;
    uint256 constant TREASURY_MARKET_RESERVE_SLOT = 9;
    uint256 constant TREASURY_NAMED_FACTORY_SLOT = 10;
    uint256 constant TREASURY_FOOTPRINT_SLOTS = 49; // gap 11..48

    /// @dev `LpRewardDistributor`: eight slots came out of a gap that was 40 long and started
    ///      at 22 — `rewardsRenounced`, then `minStakeWeight` (the dust-capture floor), then
    ///      `_floorSet` (the one-shot flag that makes the floor unforgeable), then the
    ///      weighted-stake version's five (`_stakedWeight`, `_stakedWeightOfPosition`, the
    ///      packed `weightsActivatedAt`/`legacySqrtPriceX96`, `weightEpoch`,
    ///      `totalStakedLiquidity`). 22 + 40 and 30 + 32 are the same 62 slots.
    ///
    ///      The two private position books directly above them are named as well, because
    ///      they are what a mis-ordered append collides with first: `_positionsOf` holds an
    ///      account's staked ids, `_positionIndex` each id's place in that array.
    ///
    ///      `_floorSet` is `bool private`, so there is no getter to read it with: slot 24 is
    ///      asserted directly, which is the only way to prove it is not sharing a word with
    ///      the floor above it.
    uint256 constant DISTRIBUTOR_POSITIONS_OF_SLOT = 20;
    uint256 constant DISTRIBUTOR_POSITION_INDEX_SLOT = 21;
    uint256 constant DISTRIBUTOR_REWARDS_RENOUNCED_SLOT = 22;
    uint256 constant DISTRIBUTOR_MIN_STAKE_WEIGHT_SLOT = 23;
    uint256 constant DISTRIBUTOR_FLOOR_SET_SLOT = 24;
    uint256 constant DISTRIBUTOR_FOOTPRINT_SLOTS = 62; // gap 30..61

    // ─── The live state every test reads ─────────────────────────────────

    address token;
    address curve;
    uint256 marketId;

    PoolBrandTreasury quoteTreasury;
    BrandFeeVault vault;
    LpRewardDistributor dist;

    address alice = address(0xA11CE);
    uint256 aliceTokenId;

    function setUp() public {
        _deployLaunchpadStack();

        (token, curve) = _launch("Cashcat", "CAT");
        _buyToThreshold(curve, trader);
        launchFactory.graduateToMarket(token);

        marketId = launchFactory.getLaunchedToken(token).marketId;
        AssetMarketFactory.Market memory m = marketFactory.market(marketId);
        quoteTreasury = PoolBrandTreasury(m.treasury);
        vault = BrandFeeVault(m.feeVault);
        dist = LpRewardDistributor(m.lpDistributor);

        // A real liquidity provider alongside the locked position, because the locked one
        // renounced its stream and an accrued reward has to belong to somebody.
        aliceTokenId = _seedAndStake(alice);

        // Float yield, harvested into the vault and streamed to the LPs: this is what writes
        // `cumulativePerFloat` and the vault's checkpoint.
        _accrueYield(50_000e6);
        vault.harvest();
        vault.sweep();
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // A second accrual pulled by the ISSUER rather than the vault, so `marketReserve` is
        // holding the markets' unpaid share when the tests read the slot.
        _accrueYield(50_000e6);
        quoteTreasury.claim(address(this));
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev Grow the reserve's yield. This contract registered the quote brand, so it is also
    ///      the treasury's admin — the issuer, in the split's language.
    function _accrueYield(uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(yieldSource), amount);
        yieldSource.simulateYield(address(usdg), amount);
    }

    /// @dev A full-range position in the graduated market, minted through the router the way
    ///      any LP would, then staked for the reward stream.
    function _seedAndStake(address who) internal returns (uint256 tokenId) {
        uint256 quoteIn = 2_000e6;
        uint256 assetIn = IERC20(token).balanceOf(trader) / 10;
        require(assetIn > 0, "the trader holds no launch token to seed with");

        _fundQuote(who, quoteIn);
        vm.prank(trader);
        IERC20(token).transfer(who, assetIn);

        vm.startPrank(who);
        IERC20(quoteBrand).approve(address(router), quoteIn);
        IERC20(token).approve(address(router), assetIn);
        (tokenId,,,) = router.seedLiquidity(
            marketId, quoteIn, assetIn, 0, 0, vm.getBlockTimestamp() + 1 hours
        );
        posm.approve(address(dist), tokenId);
        dist.stake(tokenId, who);
        vm.stopPrank();
    }

    /// @dev The packed slot, composed from the outside. Every shift here is a byte offset the
    ///      compiler chose and a live proxy has already written to.
    function _packFactorySlot(
        uint16 graduatedCreatorShareBps,
        bool launchEnabled,
        uint16 yieldShareBps,
        address lpFundRecipient,
        uint16 lpFundShareBps,
        uint16 graduatedLpFundShareBps
    ) internal pure returns (bytes32) {
        return bytes32(
            uint256(graduatedCreatorShareBps) // bytes 0-1
                | (launchEnabled ? uint256(1) << 16 : 0) // byte 2
                | uint256(yieldShareBps) << 24 // bytes 3-4, read by the deployed locker
                | uint256(uint160(lpFundRecipient)) << 40 // bytes 5-24
                | uint256(lpFundShareBps) << 200 // bytes 25-26
                | uint256(graduatedLpFundShareBps) << 216 // bytes 27-28
        );
    }

    function _slot(address target, uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(target, bytes32(slot)));
    }

    function _mappingSlot(address target, address key, uint256 slot)
        internal
        view
        returns (uint256)
    {
        return uint256(vm.load(target, keccak256(abi.encode(key, slot))));
    }

    function _mappingSlotUint(address target, uint256 key, uint256 slot)
        internal
        view
        returns (uint256)
    {
        return uint256(vm.load(target, keccak256(abi.encode(key, slot))));
    }

    // ─── LaunchFactory: the retired two bytes ────────────────────────────

    /// @notice Every field of the repacked slot is where the compiler put it before the LP
    ///         fund was appended into it, to the byte. Written through the owner's setters and
    ///         read back out of the raw word: if `graduatedCreatorYieldShareBps` had been
    ///         deleted rather than kept, `lpFundRecipient` would start at byte 3 and this
    ///         composition would not match.
    function test_launchFactory_everyFieldOfTheRepackedSlotKeepsItsByteOffset() public {
        address fund = address(0xF00DFEED);

        vm.startPrank(owner);
        launchFactory.setLpFundRecipient(fund);
        launchFactory.setLpFundShareBps(1_234);
        launchFactory.setGraduatedLpFundShareBps(2_345);
        launchFactory.setGraduatedCreatorShareBps(4_321);
        launchFactory.setLaunchEnabled(false);
        vm.stopPrank();

        assertEq(
            vm.load(address(launchFactory), bytes32(FACTORY_PACKED_SLOT)),
            _packFactorySlot(4_321, false, 0, fund, 1_234, 2_345),
            "the packed slot is laid out creator|enabled|yield|fund|fundBps|gradFundBps"
        );
        // The getter the deployed locker calls is still here and still reads those two bytes.
        // A fresh deployment leaves them zero, which is that leg disabled — the point is that
        // the call does not revert and the bytes are nobody else's.
        assertEq(
            launchFactory.graduatedCreatorYieldShareBps(),
            0,
            "the yield-share getter survives and reads bytes 3-4"
        );
    }

    /// @notice **The live-proxy case.** A word written under the OLD code — with the retired
    ///         yield share holding a real value — must still decode field for field under the
    ///         new code, and must survive an upgrade byte for byte. Everything BELOW the slot
    ///         comes along, because a slid field would take all of it with it.
    ///
    /// @dev What is deliberately NOT asserted: the per-brand economics the live proxy holds
    ///      at `FACTORY_RETIRED_ECONOMICS_SLOT`. That mapping is abandoned, no function reads
    ///      it, and pinning its contents would pin state the change exists to walk away from.
    ///      The slot is kept only so the five below it do not move, which is what this proves.
    function test_launchFactory_everythingBelowTheRetiredSlotSurvivesTheUpgrade() public {
        address fund = address(0xF00DFEED);
        bytes32 written = _packFactorySlot(4_000, true, 3_000, fund, 3_000, 3_000);
        vm.store(address(launchFactory), bytes32(FACTORY_PACKED_SLOT), written);

        // Decoded by the new code, before anything is upgraded.
        assertEq(launchFactory.graduatedCreatorShareBps(), 4_000, "creator share decoded");
        assertTrue(launchFactory.launchEnabled(), "launchEnabled decoded");
        assertEq(
            launchFactory.graduatedCreatorYieldShareBps(),
            3_000,
            "the two bytes the deployed locker reads decoded"
        );
        assertEq(launchFactory.lpFundRecipient(), fund, "the LP fund did not slide");
        assertEq(launchFactory.lpFundShareBps(), 3_000, "curve-fee LP fund share decoded");
        assertEq(launchFactory.graduatedLpFundShareBps(), 3_000, "graduated LP fund share");

        // Every field below the retired slot, given a value a slide would visibly corrupt.
        (uint256 appendedConfigId, address heir) = _populateEverythingBelowTheRetiredSlot();

        ILaunchFactory.LaunchedToken memory recordBefore = launchFactory.getLaunchedToken(token);
        uint256 configCountBefore = launchFactory.launchConfigCount();
        uint256 launchCountBefore = launchFactory.launchCount();
        address firstLaunchBefore = launchFactory.launchAt(0);
        (uint256 phantomBefore,,,, bool openBefore) =
            launchFactory.reserveEconomics(address(reserve));

        // Deployed before the prank: a `new` is a call from this contract and would consume it.
        address freshImplementation = address(new LaunchFactory());
        vm.prank(owner);
        launchFactory.upgradeToAndCall(freshImplementation, "");

        assertEq(
            vm.load(address(launchFactory), bytes32(FACTORY_PACKED_SLOT)),
            written,
            "the upgrade rewrote none of the packed word"
        );
        assertEq(launchFactory.graduatedCreatorShareBps(), 4_000, "creator share survived");
        assertTrue(launchFactory.launchEnabled(), "launchEnabled survived");
        assertEq(
            launchFactory.graduatedCreatorYieldShareBps(),
            3_000,
            "and so did the two bytes the deployed locker reads"
        );
        assertEq(launchFactory.lpFundRecipient(), fund, "the LP fund address survived");
        assertEq(launchFactory.lpFundShareBps(), 3_000, "curve-fee LP fund share survived");
        assertEq(launchFactory.graduatedLpFundShareBps(), 3_000, "graduated share survived");

        // A live launch record, field for field: this is the ledger a slid slot would ruin.
        ILaunchFactory.LaunchedToken memory recordAfter = launchFactory.getLaunchedToken(token);
        assertEq(recordAfter.token, recordBefore.token, "the launch's token");
        assertEq(recordAfter.curve, recordBefore.curve, "the launch's curve");
        assertEq(recordAfter.deployer, recordBefore.deployer, "the launch's creator");
        assertEq(recordAfter.pairToken, recordBefore.pairToken, "the launch's quote brand");
        assertEq(recordAfter.reserve, recordBefore.reserve, "the launch's reserve");
        assertEq(
            recordAfter.graduationThreshold,
            recordBefore.graduationThreshold,
            "the threshold it was sold under"
        );
        assertEq(recordAfter.marketId, recordBefore.marketId, "the launch's market id");
        assertEq(uint8(recordAfter.phase), uint8(recordBefore.phase), "its graduation phase");
        assertEq(
            recordAfter.creatorShareBps,
            recordBefore.creatorShareBps,
            "and the rate the launch was sold at"
        );

        assertEq(
            launchFactory.pendingCreatorFeeRecipient(token), heir, "the pending offer survived"
        );
        assertEq(launchFactory.launchConfigCount(), configCountBefore, "the config array");
        assertEq(launchFactory.launchCount(), launchCountBefore, "the launch array");
        assertEq(launchFactory.launchAt(0), firstLaunchBefore, "and its first entry");
        LaunchFactory.LaunchConfig memory appendedConfig =
            launchFactory.getLaunchConfig(appendedConfigId);
        assertEq(appendedConfig.supply, LAUNCH_SUPPLY / 2, "the appended config's supply survived");
        assertEq(appendedConfig.curveFeeBps, 250, "with its curve fee");
        assertEq(appendedConfig.poolFee, 3_000, "and its pool tier");

        (uint256 phantomAfter,,,, bool openAfter) = launchFactory.reserveEconomics(address(reserve));
        assertEq(phantomAfter, phantomBefore, "the appended reserve economics survived");
        assertEq(openAfter, openBefore, "including the reserve's launch switch");
    }

    /// @notice **Where each of them actually lives.** The constants above are the claim; this
    ///         is the proof, read straight off the proxy's slots. A field appended above the
    ///         retired slot instead of below the launch array fails here first.
    function test_launchFactory_theStateBelowTheRetiredSlotIsWhereItIsDeclared() public {
        (uint256 appendedConfigId, address heir) = _populateEverythingBelowTheRetiredSlot();

        // The retired slot itself: a plain word nothing writes. Its value is not a property.
        assertEq(
            _slot(address(launchFactory), FACTORY_RETIRED_ECONOMICS_SLOT),
            0,
            "nothing on this proxy ever wrote the retired slot"
        );

        // `_launchedTokens[token].token` is the struct's first field, so the mapping's own
        // slot holds it.
        assertEq(
            _mappingSlot(address(launchFactory), token, FACTORY_LAUNCHED_TOKENS_SLOT),
            uint256(uint160(token)),
            "slot 14 is the launched-token mapping"
        );
        assertEq(
            _mappingSlot(address(launchFactory), token, FACTORY_PENDING_RECIPIENT_SLOT),
            uint256(uint160(heir)),
            "slot 15 is pendingCreatorFeeRecipient"
        );
        assertEq(
            _slot(address(launchFactory), FACTORY_LAUNCH_CONFIGS_SLOT),
            launchFactory.launchConfigCount(),
            "slot 16 is the launch config array's length"
        );
        // Its elements hash from that slot, three words each — `supply`, `curveFeeBps`, then
        // `poolFee` and `enabled` packed — so the appended config's supply is the first word
        // of its own index.
        assertEq(
            uint256(
                vm.load(
                    address(launchFactory),
                    bytes32(
                        uint256(keccak256(abi.encode(FACTORY_LAUNCH_CONFIGS_SLOT)))
                            + appendedConfigId * 3
                    )
                )
            ),
            LAUNCH_SUPPLY / 2,
            "with the appended config's supply at its own index"
        );
        assertEq(
            _slot(address(launchFactory), FACTORY_LAUNCHES_SLOT),
            launchFactory.launchCount(),
            "slot 17 is the launch array's length"
        );
        // `ReserveEconomics.phantomQuote` is the struct's first field, so the mapping's own
        // slot holds it.
        (uint256 phantomQuote,,,,) = launchFactory.reserveEconomics(address(reserve));
        assertEq(
            _mappingSlot(address(launchFactory), address(reserve), FACTORY_RESERVE_ECONOMICS_SLOT),
            phantomQuote,
            "slot 18 is the appended reserve-economics mapping"
        );
        assertGt(phantomQuote, 0, "precondition: the reserve carries real figures");
    }

    /// @notice **The gap arithmetic.** `reserveEconomics` was cut out of `__gap`, not stacked
    ///         on top of it, so the contract still reserves the same slots and a later
    ///         version's appended state still starts where it always did. An author who
    ///         appends a field without shortening the gap lands somewhere else.
    function test_launchFactory_aLaterVersionsStateStillStartsAfterTheSameFootprint() public {
        address implementation = address(new LaunchFactoryV2());
        vm.prank(owner);
        launchFactory.upgradeToAndCall(implementation, "");

        LaunchFactoryV2 upgraded = LaunchFactoryV2(address(launchFactory));
        upgraded.setAppended(0xC0FFEE);

        assertEq(
            _slot(address(launchFactory), FACTORY_GAP_START_SLOT + FACTORY_GAP_SLOTS),
            0xC0FFEE,
            "an appended field lands directly after the gap the shrink preserved"
        );
        // And the mapping the gap gave a slot to is still readable underneath it.
        (uint256 phantomQuote,,,, bool approved) = launchFactory.reserveEconomics(address(reserve));
        assertEq(phantomQuote, PHANTOM_QUOTE, "reserve economics untouched by the append");
        assertTrue(approved, "and the reserve is still open");
    }

    /// @dev Gives every field below the retired slot a value a slide would visibly corrupt:
    ///      a pending creator-fee offer, a second launch config whose every field differs from
    ///      the fixture's, and the launch record and reserve economics the fixture already
    ///      wrote.
    function _populateEverythingBelowTheRetiredSlot()
        internal
        returns (uint256 appendedConfigId, address heir)
    {
        heir = address(0x4E1E);
        vm.prank(launchFactory.getLaunchedToken(token).creatorFeeRecipient);
        launchFactory.proposeCreatorFeeRecipient(token, heir);

        vm.prank(owner);
        appendedConfigId = launchFactory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: LAUNCH_SUPPLY / 2, curveFeeBps: 250, poolFee: 3_000, enabled: true
            })
        );
    }

    // ─── PoolBrandTreasury: where the six new fields live ────────────────

    /// @notice The six float fields occupy the six slots between `totalYieldClaimed` and the
    ///         gap, and nothing else sits below the gap. Read off a brand that has really
    ///         registered float and really been pulled, so every slot asserted holds a value
    ///         a misplacement would visibly corrupt.
    function test_poolBrandTreasury_theSixFloatFieldsSitBetweenTotalYieldClaimedAndTheGap()
        public
        view
    {
        address vaultAddr = address(vault);

        // Preconditions: this is a populated ledger, not an empty one.
        assertGt(quoteTreasury.floatOf(vaultAddr), 0, "the market registered float");
        assertGt(quoteTreasury.cumulativePerFloat(), 0, "and yield has been divided");
        assertGt(quoteTreasury.checkpointOf(vaultAddr), 0, "and the vault has settled once");
        assertGt(quoteTreasury.marketReserve(), 0, "and the markets are owed something now");

        // Slots 0-3: what the contract held before this change.
        assertEq(
            _slot(address(quoteTreasury), TREASURY_POOL_SLOT),
            uint256(uint160(address(reserve))),
            "slot 0 is pool"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_BRAND_TOKEN_SLOT),
            uint256(uint160(quoteBrand)),
            "slot 1 is brandToken"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_ADMIN_SLOT),
            uint256(uint160(quoteTreasury.admin())),
            "slot 2 is admin"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_TOTAL_YIELD_CLAIMED_SLOT),
            quoteTreasury.totalYieldClaimed(),
            "slot 3 is totalYieldClaimed"
        );

        // Slots 4-9: the six the float share appended, in order.
        assertEq(
            _slot(address(quoteTreasury), TREASURY_FACTORY_SLOT),
            uint256(uint160(address(marketFactory))),
            "slot 4 is factory"
        );
        assertEq(
            _mappingSlot(address(quoteTreasury), vaultAddr, TREASURY_FLOAT_OF_SLOT),
            quoteTreasury.floatOf(vaultAddr),
            "slot 5 is the floatOf mapping"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_TOTAL_FLOAT_SLOT),
            quoteTreasury.totalFloat(),
            "slot 6 is totalFloat"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_CUMULATIVE_PER_FLOAT_SLOT),
            quoteTreasury.cumulativePerFloat(),
            "slot 7 is cumulativePerFloat"
        );
        assertEq(
            _mappingSlot(address(quoteTreasury), vaultAddr, TREASURY_CHECKPOINT_OF_SLOT),
            quoteTreasury.checkpointOf(vaultAddr),
            "slot 8 is the checkpointOf mapping"
        );
        assertEq(
            _slot(address(quoteTreasury), TREASURY_MARKET_RESERVE_SLOT),
            quoteTreasury.marketReserve(),
            "slot 9 is marketReserve"
        );
    }

    /// @notice **The gap arithmetic.** The six fields were cut out of `__gap`, not stacked on
    ///         top of it, so the contract still reserves forty-nine slots and a later version's
    ///         appended state still starts at forty-nine. If a future author appends a field
    ///         above them without shortening the gap, this lands somewhere else.
    function test_poolBrandTreasury_aLaterVersionsStateStillStartsAfterFortyNineSlots() public {
        uint256 floatBefore = quoteTreasury.floatOf(address(vault));
        uint256 indexBefore = quoteTreasury.cumulativePerFloat();
        uint256 reserveBefore = quoteTreasury.marketReserve();

        address treasuryV2 = address(new PoolBrandTreasuryV2());
        vm.prank(stackOwner);
        beacons.treasury.upgradeTo(treasuryV2);

        PoolBrandTreasuryV2 upgraded = PoolBrandTreasuryV2(address(quoteTreasury));
        upgraded.setAppended(0xC0FFEE);

        assertEq(
            _slot(address(quoteTreasury), TREASURY_FOOTPRINT_SLOTS),
            0xC0FFEE,
            "an appended field lands directly after the 49 slots this contract reserves"
        );
        assertEq(quoteTreasury.floatOf(address(vault)), floatBefore, "float untouched");
        assertEq(quoteTreasury.cumulativePerFloat(), indexBefore, "the index untouched");
        assertEq(quoteTreasury.marketReserve(), reserveBefore, "the markets' reserve untouched");
    }

    /// @notice A beacon upgrade reaches a live brand's treasury without disturbing the ledger
    ///         it is holding, and the treasury still pays afterwards. This is the failure the
    ///         whole layout discipline exists to prevent: a shifted `marketReserve` would let
    ///         the issuer take money the markets are owed.
    function test_poolBrandTreasury_aBeaconUpgradePreservesALiveFloatLedger() public {
        address vaultAddr = address(vault);
        uint256 floatBefore = quoteTreasury.floatOf(vaultAddr);
        uint256 totalFloatBefore = quoteTreasury.totalFloat();
        uint256 indexBefore = quoteTreasury.cumulativePerFloat();
        uint256 checkpointBefore = quoteTreasury.checkpointOf(vaultAddr);
        uint256 reserveBefore = quoteTreasury.marketReserve();
        uint256 claimedBefore = quoteTreasury.totalYieldClaimed();
        uint256 pendingBefore = quoteTreasury.pendingFloatShare(vaultAddr);
        assertGt(pendingBefore, 0, "precondition: the vault is owed something");

        address treasuryV2 = address(new PoolBrandTreasuryV2());
        vm.prank(stackOwner);
        beacons.treasury.upgradeTo(treasuryV2);

        assertEq(PoolBrandTreasuryV2(address(quoteTreasury)).version(), 2, "new code is live");
        assertEq(address(quoteTreasury.pool()), address(reserve), "wiring survived");
        assertEq(quoteTreasury.brandToken(), quoteBrand, "the brand survived");
        assertEq(quoteTreasury.factory(), address(marketFactory), "the factory survived");
        assertEq(quoteTreasury.floatOf(vaultAddr), floatBefore, "the vault's float survived");
        assertEq(quoteTreasury.totalFloat(), totalFloatBefore, "total float survived");
        assertEq(quoteTreasury.cumulativePerFloat(), indexBefore, "the index survived");
        assertEq(quoteTreasury.checkpointOf(vaultAddr), checkpointBefore, "checkpoint survived");
        assertEq(quoteTreasury.marketReserve(), reserveBefore, "the markets' reserve survived");
        assertEq(quoteTreasury.totalYieldClaimed(), claimedBefore, "the claim total survived");
        assertEq(
            quoteTreasury.pendingFloatShare(vaultAddr), pendingBefore, "and so did what is owed"
        );

        // And it still works: the vault collects exactly what it was owed across the upgrade.
        uint256 held = IERC20(address(usdg)).balanceOf(vaultAddr);
        vault.harvest();
        assertEq(
            IERC20(address(usdg)).balanceOf(vaultAddr) - held,
            pendingBefore,
            "the vault was paid what the pre-upgrade ledger said it was owed"
        );
        assertEq(
            quoteTreasury.marketReserve(),
            reserveBefore - pendingBefore,
            "and the reserve fell by exactly that"
        );
    }

    // ─── LpRewardDistributor: where rewardsRenounced lives ───────────────

    /// @notice `rewardsRenounced` occupies the slot immediately after `_positionIndex`, the
    ///         last of the two private position books and the last slot the contract held
    ///         before this change. A live market proves it: the locker renounced at
    ///         `recordPosition`, an ordinary staker did not, and the three mappings must not
    ///         be reading each other's words.
    function test_lpRewardDistributor_rewardsRenouncedSitsDirectlyAfterThePositionBooks() public {
        address lockerAddr = address(locker);
        assertTrue(dist.rewardsRenounced(lockerAddr), "precondition: the locker renounced");
        assertFalse(dist.rewardsRenounced(alice), "precondition: the staker did not");

        assertEq(
            _mappingSlot(address(dist), lockerAddr, DISTRIBUTOR_REWARDS_RENOUNCED_SLOT),
            1,
            "slot 22 is the rewardsRenounced mapping"
        );
        assertEq(
            _mappingSlot(address(dist), alice, DISTRIBUTOR_REWARDS_RENOUNCED_SLOT),
            0,
            "and a staker who never renounced reads zero out of it"
        );

        // The two books above it, given a second stake so both hold a number a collision
        // would visibly change: an appended mapping that landed on slot 21 would make a
        // staker's second position read as a renunciation, and one that landed on slot 20
        // would make their position count do the same.
        uint256 secondTokenId = _seedAndStake(alice);
        assertEq(
            _mappingSlot(address(dist), alice, DISTRIBUTOR_POSITIONS_OF_SLOT),
            2,
            "slot 20 is _positionsOf, holding the account's staked-position count"
        );
        assertEq(
            _mappingSlotUint(address(dist), secondTokenId, DISTRIBUTOR_POSITION_INDEX_SLOT),
            1,
            "slot 21 is _positionIndex, holding that position's place in the account's array"
        );
        assertEq(
            _mappingSlot(address(dist), alice, DISTRIBUTOR_REWARDS_RENOUNCED_SLOT),
            0,
            "and neither write reached the renunciation mapping below them"
        );
    }

    /// @notice The admission floor and its one-shot flag occupy the two slots after
    ///         `rewardsRenounced`, one each, in that order. A live graduated market proves it:
    ///         the locker renounced as the sole staker of a distributor created in the same
    ///         transaction, which is the one condition that writes both.
    ///
    ///         `_floorSet` is private and has no getter, so the flag is read out of the word
    ///         directly. That is also the point of asserting it: a `bool` the compiler had
    ///         packed alongside `minStakeWeight` would leave the floor reading as an
    ///         astronomical number the first time the flag was set, and no getter would say so.
    function test_lpRewardDistributor_theAdmissionFloorAndItsOneShotFlagEachHoldTheirOwnSlot()
        public
        view
    {
        uint256 floor = dist.minStakeWeight();
        assertGt(floor, 0, "precondition: the graduation's seed measured this market");

        assertEq(
            _slot(address(dist), DISTRIBUTOR_MIN_STAKE_WEIGHT_SLOT),
            floor,
            "slot 23 is minStakeWeight, whole and by itself"
        );
        assertEq(
            _slot(address(dist), DISTRIBUTOR_FLOOR_SET_SLOT),
            1,
            "slot 24 is the _floorSet one-shot, set by that same renunciation"
        );

        // And the mapping above them is untouched by either: a field that slid up would read
        // the locker's renunciation out of the floor's word.
        assertEq(
            _mappingSlot(address(dist), address(locker), DISTRIBUTOR_REWARDS_RENOUNCED_SLOT),
            1,
            "slot 22 is still the rewardsRenounced mapping"
        );
    }

    /// @notice The distributor's gap arithmetic: eight slots out of the gap, none added to the
    ///         footprint, so a later version's state still begins at sixty-two.
    function test_lpRewardDistributor_aLaterVersionsStateStillStartsAfterSixtyTwoSlots() public {
        uint256 totalStakedBefore = dist.totalStaked();

        address distributorV2 = address(new LpRewardDistributorV2());
        vm.prank(stackOwner);
        beacons.distributor.upgradeTo(distributorV2);

        LpRewardDistributorV2(address(dist)).setAppended(0xBEEF);

        assertEq(
            _slot(address(dist), DISTRIBUTOR_FOOTPRINT_SLOTS),
            0xBEEF,
            "an appended field lands directly after the 62 slots this contract reserves"
        );
        assertEq(dist.totalStaked(), totalStakedBefore, "staked liquidity untouched");
        assertTrue(dist.rewardsRenounced(address(locker)), "the renunciation untouched");
        assertEq(dist.stakerOf(aliceTokenId), alice, "and custody untouched");
    }

    /// @notice A beacon upgrade reaches a live market's distributor without disturbing a stake
    ///         or the reward it has accrued, and the staker can still be paid and still get
    ///         their position back.
    function test_lpRewardDistributor_aBeaconUpgradePreservesALiveStakeAndItsAccruedReward()
        public
    {
        uint256 earnedBefore = dist.earned(alice);
        uint256 stakedBefore = dist.stakedLiquidityOf(alice);
        uint256 totalStakedBefore = dist.totalStaked();
        uint256 notifiedBefore = dist.totalNotified();
        assertGt(earnedBefore, 0, "precondition: the stake accrued a reward");
        assertGt(stakedBefore, 0, "precondition: the stake carries liquidity");

        address distributorV2 = address(new LpRewardDistributorV2());
        vm.prank(stackOwner);
        beacons.distributor.upgradeTo(distributorV2);

        assertEq(LpRewardDistributorV2(address(dist)).version(), 2, "new code is live");
        assertEq(dist.earned(alice), earnedBefore, "the accrued reward survived");
        assertEq(dist.stakedLiquidityOf(alice), stakedBefore, "the stake's liquidity survived");
        assertEq(dist.totalStaked(), totalStakedBefore, "the stream's divisor survived");
        assertEq(dist.totalNotified(), notifiedBefore, "the stream's ledger survived");
        assertEq(dist.stakerOf(aliceTokenId), alice, "custody and credit survived");
        assertTrue(dist.rewardsRenounced(address(locker)), "the locker is still renounced");

        // And it still functions: the reward pays out, and the position comes home.
        uint256 balanceBefore = IERC20(quoteBrand).balanceOf(alice);
        vm.startPrank(alice);
        uint256 paid = dist.claim(quoteBrand);
        assertEq(paid, earnedBefore, "paid exactly what was accrued before the upgrade");
        assertEq(
            IERC20(quoteBrand).balanceOf(alice) - balanceBefore, paid, "and the tokens arrived"
        );

        dist.unstake(aliceTokenId);
        vm.stopPrank();
        assertEq(posm.ownerOf(aliceTokenId), alice, "the position came back");
        assertEq(dist.stakerOf(aliceTokenId), address(0), "and the stake was cleared");
    }
}
