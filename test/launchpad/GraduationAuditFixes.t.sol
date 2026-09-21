// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {LpRewardDistributor} from "../../src/markets/LpRewardDistributor.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {GraduationPhase, ILaunchFactory} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @dev The `LaunchFactory` view surface the **deployed, non-upgradeable** `LaunchLocker`
///      was compiled against. Declared here rather than imported from `ILaunchpad.sol` on
///      purpose: the locker on chain carries its own copy of this ABI, frozen at its
///      deployment, and cannot be recompiled. Importing the repo's current interface would
///      make this test agree with whatever the repo currently believes, which is precisely
///      the thing under test.
interface IPreChangeLaunchFactory {
    function creatorFeeRecipientOf(address token) external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function lpFundRecipient() external view returns (address);
    function graduatedCreatorYieldShareBps() external view returns (uint16);
    function graduatedLpFundShareBps() external view returns (uint16);
}

/// @notice The factory-facing prologue of the `collect()` that is DEPLOYED on mainnet,
///         transcribed line for line from the pre-change source
///         (`LaunchLocker.sol:223-245` of the float-yield checkout): the five factory reads
///         it makes, in order, and the three `ShareTooHigh` bounds it applies to them.
///
///         Everything below the prologue — the distributor pull and the escrow credits — is
///         locker-local and a `LaunchFactory` upgrade cannot reach it, so it is left out.
///         What an upgrade CAN do is delete a selector out from under these reads, and that
///         is what a call to this contract exercises.
contract PreChangeLockerCollectProbe {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    error ShareTooHigh(uint16 bps);
    error ZeroAddress();

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    /// @param creatorShareBps The rate snapshotted into the locked position's record, which
    ///        on the live locker comes out of storage rather than from the factory.
    /// @dev `view` because the transcribed prologue is exactly the read-only part; the
    ///      writes the real `collect` does are all locker-local and below it.
    function collect(address token, uint16 creatorShareBps)
        external
        view
        returns (uint16 yieldShareBps, uint16 lpFundShareBps, address lpFund)
    {
        address creator = IPreChangeLaunchFactory(factory).creatorFeeRecipientOf(token);
        address protocol = IPreChangeLaunchFactory(factory).protocolFeeRecipient();
        if (creator == address(0) || protocol == address(0)) revert ZeroAddress();

        yieldShareBps = IPreChangeLaunchFactory(factory).graduatedCreatorYieldShareBps();
        lpFundShareBps = IPreChangeLaunchFactory(factory).graduatedLpFundShareBps();
        if (yieldShareBps > BPS_DENOMINATOR) revert ShareTooHigh(yieldShareBps);
        if (uint256(creatorShareBps) + lpFundShareBps > BPS_DENOMINATOR) {
            revert ShareTooHigh(lpFundShareBps);
        }
        if (uint256(yieldShareBps) + lpFundShareBps > BPS_DENOMINATOR) {
            revert ShareTooHigh(lpFundShareBps);
        }
        if (lpFundShareBps != 0) {
            lpFund = IPreChangeLaunchFactory(factory).lpFundRecipient();
            if (lpFund == address(0)) revert ZeroAddress();
        }
    }
}

/// @title GraduationAuditFixesTest
/// @notice The two `LaunchFactory` findings of the graduate-into-launch-dollar audit.
///
///         **LF-ABI-BREAK.** Retiring `graduatedCreatorYieldShareBps` to a `private` slot
///         deleted its selector. The locker that custodies markets 16, 17 and 18 is not
///         upgradeable, holds its factory immutably, and reads that selector unconditionally
///         inside `collect()` — so the deletion would have stranded those three graduates'
///         fees and float yield with no function anywhere able to move them.
///
///         **AMF-POOLSQUAT.** A graduated market is quoted in the launch's own brand, so its
///         v4 pool key exists in full the moment the launch does, and `PoolManager.initialize`
///         on it is permissionless. One transaction pinned `graduateToMarket` in a permanent
///         revert.
///
///         The first remedy was `setSweptLaunchPoolFee`, which moved the launch to another
///         fee tier. There are five tiers, so that priced the attack at five transactions
///         rather than closing it. What closes it is the tick-spacing ladder: `tickSpacing`
///         is an independent field of `PoolKey`, so `AssetMarketFactory` walks
///         `nextFreeTickSpacing` on the launch path and opens on the first free rung. The
///         setter stays as the escape hatch for a ladder that is itself exhausted, and is
///         now refused unless that tier's ladder really is gone.
contract GraduationAuditFixesTest is LaunchpadFixture {
    using StateLibrary for IPoolManager;

    /// @dev `graduatedCreatorShareBps` (2 bytes), `launchEnabled` (1),
    ///      `graduatedCreatorYieldShareBps` (2), `lpFundRecipient` (20), `lpFundShareBps` (2),
    ///      `graduatedLpFundShareBps` (2). Pinned by `GraduateIntoLaunchDollarLayout`; stated
    ///      again here because both fixes read it.
    uint256 private constant FACTORY_PACKED_SLOT = 12;

    /// @dev Mirrors `AssetMarketFactory.LAUNCH_SPACING_RUNGS`, which is private. A test that
    ///      exhausts the ladder has to know how long it is; if the contract's depth changes
    ///      and this does not, `test_anExhaustedLadderIsNamedAndTheLaunchStaysRetryable`
    ///      fails rather than silently stopping short.
    uint256 private constant LADDER_RUNGS = 32;

    address private constant FUND = address(0xF00DFEED);

    function setUp() public {
        _deployLaunchpadStack();
    }

    /// @dev The packed word composed from the outside, byte offset by byte offset.
    function _packFactorySlot(
        uint16 graduatedCreatorShareBps,
        bool launchEnabled,
        uint16 yieldShareBps,
        address lpFundRecipient,
        uint16 lpFundShareBps,
        uint16 graduatedLpFundShareBps
    ) private pure returns (bytes32) {
        return bytes32(
            uint256(graduatedCreatorShareBps) // bytes 0-1
                | (launchEnabled ? uint256(1) << 16 : 0) // byte 2
                | uint256(yieldShareBps) << 24 // bytes 3-4
                | uint256(uint160(lpFundRecipient)) << 40 // bytes 5-24
                | uint256(lpFundShareBps) << 200 // bytes 25-26
                | uint256(graduatedLpFundShareBps) << 216 // bytes 27-28
        );
    }

    /// @dev A pool key for the pair, rebuilt exactly as `AssetMarketFactory` does: the two
    ///      currencies sorted, the fee, a tick spacing, and the protocol hook. Every field is
    ///      public before a launch has sold a single token, which is the whole of
    ///      AMF-POOLSQUAT.
    function _keyAt(address brand, address token, uint24 fee, int24 spacing)
        private
        view
        returns (PoolKey memory)
    {
        (address c0, address c1) = brand < token ? (brand, token) : (token, brand);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The canonical key a graduated market would open on.
    function _graduatedPoolKey(address token, uint24 fee) private view returns (PoolKey memory) {
        return _keyAt(quoteBrand, token, fee, marketFactory.tickSpacingForFee(fee));
    }

    /// @dev The attack, in full: one `initialize` from somebody with no stake in the launch,
    ///      no liquidity and no tokens.
    function _squat(address brand, address token, uint24 fee, int24 spacing) private {
        vm.prank(stranger);
        manager.initialize(_keyAt(brand, token, fee, spacing), TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev `rungs` consecutive rungs of the ladder, starting at the tier's canonical spacing.
    function _squatRungs(address token, uint24 fee, uint256 rungs) private {
        int24 canonical = marketFactory.tickSpacingForFee(fee);
        for (uint256 i; i < rungs; ++i) {
            _squat(quoteBrand, token, fee, canonical + int24(uint24(i)));
        }
    }

    function _liquidityAt(PoolKey memory key) private view returns (uint128) {
        return IPoolManager(address(manager)).getLiquidity(key.toId());
    }

    /// @dev An asset the owner has listed at the launch tier, for the two owner-facing
    ///      creation paths. Its unit metadata is non-empty because `approveAsset` insists.
    function _approveAsset() private returns (address asset) {
        asset = address(new MockUSDC());
        vm.prank(owner);
        marketFactory.approveAsset(
            asset,
            AssetMarketFactory.AssetListing({
                approved: false,
                fee: POOL_FEE,
                assetPriceE18: 1e18,
                observationCardinality: 0,
                unitName: "Squat Unit",
                unitSymbol: "sqUSD"
            })
        );
    }

    // ─── LF-ABI-BREAK ────────────────────────────────────────────────────

    /// @notice A proxy whose slot already holds 4_000 — which every live `LaunchFactory`
    ///         proxy does, written by the original `initialize` — still answers the getter
    ///         after the upgrade, and nothing beside it in the packed word moved.
    function test_theYieldShareGetterSurvivesTheUpgrade() public {
        bytes32 written = _packFactorySlot(4_000, true, 4_000, FUND, 3_000, 3_000);
        vm.store(address(launchFactory), bytes32(FACTORY_PACKED_SLOT), written);

        address freshImplementation = address(new LaunchFactory());
        vm.prank(owner);
        launchFactory.upgradeToAndCall(freshImplementation, "");

        assertEq(
            launchFactory.graduatedCreatorYieldShareBps(),
            4_000,
            "the terms markets 16/17/18 were sold"
        );
        assertEq(launchFactory.lpFundRecipient(), FUND, "the LP fund address did not slide");
        assertEq(launchFactory.graduatedCreatorShareBps(), 4_000, "creator fee share");
        assertTrue(launchFactory.launchEnabled(), "launchEnabled");
        assertEq(launchFactory.lpFundShareBps(), 3_000, "curve-fee LP fund share");
        assertEq(launchFactory.graduatedLpFundShareBps(), 3_000, "graduated LP fund share");
        assertEq(
            vm.load(address(launchFactory), bytes32(FACTORY_PACKED_SLOT)),
            written,
            "the upgrade rewrote none of the packed word"
        );
    }

    /// @notice The selector is not merely present, it is callable the way the deployed locker
    ///         calls it. A locker holding the old ABI runs its whole `collect()` prologue
    ///         against the upgraded proxy and comes out with the rates it expects.
    function test_aPreChangeLockerStillCollects() public {
        (address token,) = _launch("Legacy Graduate", "LEG");

        vm.store(
            address(launchFactory),
            bytes32(FACTORY_PACKED_SLOT),
            _packFactorySlot(4_000, true, 4_000, FUND, 0, 2_500)
        );
        address freshImplementation = address(new LaunchFactory());
        vm.prank(owner);
        launchFactory.upgradeToAndCall(freshImplementation, "");

        PreChangeLockerCollectProbe probe = new PreChangeLockerCollectProbe(address(launchFactory));
        (uint16 yieldShareBps, uint16 lpFundShareBps, address lpFund) = probe.collect(token, 4_000);

        assertEq(yieldShareBps, 4_000, "the yield leg the old locker splits");
        assertEq(lpFundShareBps, 2_500, "the fund leg it reads live");
        assertEq(lpFund, FUND, "and the fund it pays");
    }

    /// @notice The bound the old locker enforces is enforced here too, so no owner can push
    ///         the pair over 10_000 and brick `collect()` on the positions it holds.
    function test_theLpFundShareCannotBrickThePreChangeLocker() public {
        // Creator FEE share zeroed so the other bound cannot be what trips: this isolates the
        // yield-share bound.
        vm.store(
            address(launchFactory),
            bytes32(FACTORY_PACKED_SLOT),
            _packFactorySlot(0, true, 8_000, FUND, 0, 0)
        );

        vm.prank(owner);
        vm.expectRevert(LaunchFactory.InvalidBasisPoints.selector);
        launchFactory.setGraduatedLpFundShareBps(2_001);

        // Exactly 10_000 is the boundary the locker allows, so it is allowed here.
        vm.prank(owner);
        launchFactory.setGraduatedLpFundShareBps(2_000);
        assertEq(launchFactory.graduatedLpFundShareBps(), 2_000, "the boundary is admissible");

        PreChangeLockerCollectProbe probe = new PreChangeLockerCollectProbe(address(launchFactory));
        (address token,) = _launch("Boundary", "BND");
        (uint16 yieldShareBps, uint16 lpFundShareBps,) = probe.collect(token, 0);
        assertEq(uint256(yieldShareBps) + lpFundShareBps, 10_000, "and still collectable");
    }

    // ─── AMF-POOLSQUAT: the ladder ───────────────────────────────────────

    /// @notice The attack, and the fix that makes it stop mattering. A stranger initialises
    ///         the launch's predictable pool key before it graduates; the graduation happens
    ///         anyway, one rung over, with nobody's intervention and no owner transaction.
    ///
    ///         Every consumer of the key has to agree, so all four are checked: the market
    ///         record, the distributor that was initialised from the key, the pool the seed
    ///         actually landed in, and the pool the squatter took.
    function test_aSquattedLaunchGraduatesOnTheNextRung() public {
        (address token, address curve) = _launch("Squatted", "SQT");

        // One transaction, from anybody, with no liquidity and no stake in the launch.
        _squat(quoteBrand, token, POOL_FEE, 50);

        _buyToThreshold(curve, trader);
        assertEq(
            uint8(launchFactory.getLaunchedToken(token).phase),
            uint8(GraduationPhase.Swept),
            "the raise is swept into the factory"
        );

        vm.expectEmit(true, true, false, true, address(marketFactory));
        emit AssetMarketFactory.LaunchPoolSpacingShifted(token, quoteBrand, POOL_FEE, 50, 51);
        launchFactory.graduateToMarket(token);

        ILaunchFactory.LaunchedToken memory record = launchFactory.getLaunchedToken(token);
        assertEq(uint8(record.phase), uint8(GraduationPhase.Graduated), "graduated");
        assertEq(record.poolFee, POOL_FEE, "on the tier the creator was quoted");

        PoolKey memory opened = marketFactory.poolKeyOf(record.marketId);
        assertEq(opened.fee, POOL_FEE, "the fee is untouched");
        assertEq(opened.tickSpacing, int24(51), "the market opened one rung over");

        AssetMarketFactory.Market memory m = marketFactory.market(record.marketId);
        LpRewardDistributor distributor = LpRewardDistributor(m.lpDistributor);
        assertEq(distributor.tickSpacing(), int24(51), "the distributor took the same spacing");
        assertEq(
            PoolId.unwrap(distributor.poolKey().toId()),
            PoolId.unwrap(opened.toId()),
            "and therefore the same pool"
        );

        assertGt(_liquidityAt(opened), 0, "the seed went into the market's pool");
        assertEq(
            _liquidityAt(_keyAt(quoteBrand, token, POOL_FEE, 50)),
            0,
            "and nothing went into the squatter's"
        );
    }

    /// @notice A squatter who takes several rungs buys several rungs and nothing else.
    function test_severalSquattedRungsAreWalkedPast() public {
        (address token, address curve) = _launch("Deep", "DEP");

        _squatRungs(token, POOL_FEE, 5); // spacings 50 through 54

        _buyToThreshold(curve, trader);
        launchFactory.graduateToMarket(token);

        PoolKey memory opened =
            marketFactory.poolKeyOf(launchFactory.getLaunchedToken(token).marketId);
        assertEq(opened.tickSpacing, int24(55), "the first free rung above the squat");
        assertGt(_liquidityAt(opened), 0, "and it is the pool that holds the seed");
    }

    /// @notice The ladder is finite, so the failure at the end of it has to be a named one
    ///         that leaves the raise recoverable — not a bare revert with the launch stuck.
    ///         The re-tier is the escape hatch, and here is the one case it is for.
    function test_anExhaustedLadderIsNamedAndTheLaunchStaysRetryable() public {
        (address token, address curve) = _launch("Exhausted", "EXH");

        _squatRungs(token, POOL_FEE, LADDER_RUNGS);
        assertEq(
            marketFactory.nextFreeTickSpacing(quoteBrand, token, POOL_FEE),
            int24(0),
            "every rung of the 0.50% ladder is taken"
        );

        _buyToThreshold(curve, trader);

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.LaunchPoolLadderExhausted.selector, token, quoteBrand, POOL_FEE
            )
        );
        launchFactory.graduateToMarket(token);

        assertEq(
            uint8(launchFactory.getLaunchedToken(token).phase),
            uint8(GraduationPhase.Swept),
            "the launch is still swept, not stuck in a half-graduated state"
        );

        // A whole fresh ladder for one owner transaction, instead of a seven-day rescue.
        vm.prank(owner);
        launchFactory.setSweptLaunchPoolFee(token, 3_000);
        launchFactory.graduateToMarket(token);

        ILaunchFactory.LaunchedToken memory record = launchFactory.getLaunchedToken(token);
        assertEq(uint8(record.phase), uint8(GraduationPhase.Graduated), "and it graduates");
        PoolKey memory opened = marketFactory.poolKeyOf(record.marketId);
        assertEq(opened.fee, uint24(3_000), "on the new tier");
        assertEq(opened.tickSpacing, int24(60), "at that tier's canonical spacing");
        assertGt(_liquidityAt(opened), 0, "holding the seed");
    }

    // ─── The ladder is the launch path's, and only the launch path's ─────

    /// @notice An owner listing quoted in a dollar that already exists still refuses an
    ///         occupied key. The ladder exists underneath it — the rung above is free and the
    ///         factory says so — and is deliberately not taken: the owner picked this tier
    ///         and gets told, rather than silently opening a market on terms nobody chose.
    function test_createMarketForBrandStillRefusesAnOccupiedKey() public {
        address asset = _approveAsset();
        _squat(quoteBrand, asset, POOL_FEE, 50);

        assertEq(
            marketFactory.nextFreeTickSpacing(quoteBrand, asset, POOL_FEE),
            int24(51),
            "a rung is free, and the owner path still will not use it"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                AssetMarketFactory.PoolAlreadyInitialised.selector, asset, quoteBrand
            )
        );
        marketFactory.createMarketForBrand(asset, quoteBrand);
    }

    /// @notice Same for the path that mints the market its own unit. The unit's address is
    ///         learned by running the creation and rolling it back, rather than predicted
    ///         from a nonce, so the squat lands on the key the factory would really build.
    function test_createMarketStillRefusesAnOccupiedKey() public {
        address asset = _approveAsset();

        uint256 snap = vm.snapshotState();
        (, address brand,,,) = marketFactory.createMarket(asset, address(0));
        vm.revertToState(snap);

        _squat(brand, asset, POOL_FEE, 50);

        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.PoolAlreadyInitialised.selector, asset, brand)
        );
        marketFactory.createMarket(asset, address(0));
    }

    // ─── LF-RETIER-GATE-SCOPE: the setter is the last resort and nothing else ──

    /// @notice The power the setter used to carry. A launch whose key nobody has touched is
    ///         a launch whose fee tier is a term its creator was quoted, and the owner may
    ///         not move it "for maintenance".
    function test_retieringIsRefusedWhenTheKeyIsFree() public {
        (address token,) = _launch("Untouched", "UNT");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.LaunchPoolLadderNotExhausted.selector, token)
        );
        launchFactory.setSweptLaunchPoolFee(token, 3_000);
    }

    /// @notice A squat on the canonical key alone does NOT unlock the tier. That case is the
    ///         ladder's, and the ladder settles it with no owner transaction at all — so
    ///         admitting it here would price the owner's re-tiering power at one ~60k-gas
    ///         `initialize` by any third party, on a term the creator was quoted.
    function test_retieringIsRefusedWhileTheLadderStillHasARung() public {
        (address token, address curve) = _launch("OneRung", "ONE");

        _squat(quoteBrand, token, POOL_FEE, 50);
        assertEq(
            marketFactory.nextFreeTickSpacing(quoteBrand, token, POOL_FEE),
            int24(51),
            "the canonical key is taken and the rung above it is not"
        );

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.LaunchPoolLadderNotExhausted.selector, token)
        );
        launchFactory.setSweptLaunchPoolFee(token, 3_000);

        // And nothing was needed from the owner: the launch graduates on its own, on the
        // tier its creator was quoted, which is why the hatch stays shut for this case.
        _buyToThreshold(curve, trader);
        launchFactory.graduateToMarket(token);

        ILaunchFactory.LaunchedToken memory record = launchFactory.getLaunchedToken(token);
        assertEq(uint8(record.phase), uint8(GraduationPhase.Graduated), "graduated unaided");
        assertEq(record.poolFee, POOL_FEE, "on the tier the creator was quoted");
        PoolKey memory opened = marketFactory.poolKeyOf(record.marketId);
        assertEq(opened.tickSpacing, int24(51), "one rung over the squat");
        assertGt(_liquidityAt(opened), 0, "holding the seed");
    }

    /// @notice The one case the setter exists for, and its boundary: one rung short of
    ///         exhaustion the tier is still immovable, and the rung that closes the ladder
    ///         is what opens the hatch. Then graduation takes a whole fresh ladder.
    function test_retieringIsAllowedOnceTheLadderIsExhausted() public {
        (address token, address curve) = _launch("Gone", "GON");

        int24 lastRung = marketFactory.tickSpacingForFee(POOL_FEE) + int24(uint24(LADDER_RUNGS - 1));

        _squatRungs(token, POOL_FEE, LADDER_RUNGS - 1);
        assertEq(
            marketFactory.nextFreeTickSpacing(quoteBrand, token, POOL_FEE),
            lastRung,
            "one rung short: graduation can still place itself"
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchFactory.LaunchPoolLadderNotExhausted.selector, token)
        );
        launchFactory.setSweptLaunchPoolFee(token, 10_000);

        _squat(quoteBrand, token, POOL_FEE, lastRung);
        assertEq(
            marketFactory.nextFreeTickSpacing(quoteBrand, token, POOL_FEE),
            int24(0),
            "and now the whole ladder is gone"
        );

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(launchFactory));
        emit LaunchFactory.LaunchPoolFeeRetiered(token, POOL_FEE, 10_000);
        launchFactory.setSweptLaunchPoolFee(token, 10_000);
        assertEq(launchFactory.getLaunchedToken(token).poolFee, uint24(10_000), "re-tiered");

        _buyToThreshold(curve, trader);
        launchFactory.graduateToMarket(token);

        PoolKey memory opened =
            marketFactory.poolKeyOf(launchFactory.getLaunchedToken(token).marketId);
        assertEq(opened.fee, uint24(10_000), "graduation used the new tier");
        assertEq(opened.tickSpacing, int24(200), "at its canonical spacing: a fresh ladder");
        assertGt(_liquidityAt(opened), 0, "holding the seed");
    }

    /// @notice Unreachable once the pool is open and the seed is locked in it.
    function test_retieringIsRefusedAfterGraduation() public {
        (address token, address curve) = _launch("Open", "OPN");
        _buyToThreshold(curve, trader);
        launchFactory.graduateToMarket(token);

        vm.prank(owner);
        vm.expectRevert(LaunchFactory.WrongGraduationPhase.selector);
        launchFactory.setSweptLaunchPoolFee(token, 3_000);
    }

    /// @notice Owner-only, because the tier is a term the creator was quoted.
    function test_retieringIsOwnerOnly() public {
        (address token,) = _launch("Guarded", "GRD");
        _squat(quoteBrand, token, POOL_FEE, 50);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        launchFactory.setSweptLaunchPoolFee(token, 3_000);
    }

    /// @notice A tier the market factory would refuse at graduation is refused here, so the
    ///         remedy cannot itself brick the launch.
    function test_retieringRefusesAnUnsupportedTier() public {
        (address token,) = _launch("Tier", "TIR");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AssetMarketFactory.UnsupportedFeeTier.selector, uint24(777))
        );
        launchFactory.setSweptLaunchPoolFee(token, 777);
    }

    /// @notice And an unknown token is not silently re-tiered into existence.
    function test_retieringRefusesAnUnknownToken() public {
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.TokenNotFound.selector);
        launchFactory.setSweptLaunchPoolFee(address(0xDEAD), 3_000);
    }

    /// @notice The seed preflight runs against the NEW tier's spacing, using the launch's
    ///         actual swept amounts — the same check `graduateToMarket` is about to make.
    function test_retieringPreflightsTheSeedOnTheNewSpacing() public {
        (address token, address curve) = _launch("Preflight", "PRF");
        _buyToThreshold(curve, trader);
        // The gate is ladder exhaustion, so the whole tier has to be gone to reach the
        // preflight at all.
        _squatRungs(token, POOL_FEE, LADDER_RUNGS);

        ILaunchFactory.LaunchedToken memory swept = launchFactory.getLaunchedToken(token);
        assertGt(swept.sweptQuote, 0, "the swept quote is what the preflight measures");

        // Spacing 1 is the tightest v4 offers, which is the spacing that maximises the
        // liquidity a fixed pair of amounts implies and therefore the one most likely to
        // trip the guard's per-tick cap. Passing here and then graduating is the proof that
        // the setter's preflight and `graduateToMarket`'s are the same check.
        vm.prank(owner);
        launchFactory.setSweptLaunchPoolFee(token, 100);
        assertEq(
            launchFactory.getLaunchedToken(token).poolFee,
            uint24(100),
            "the tightest spacing still seeds this launch"
        );
        launchFactory.graduateToMarket(token);
        assertEq(
            marketFactory.poolKeyOf(launchFactory.getLaunchedToken(token).marketId).tickSpacing,
            int24(1),
            "and graduation agreed with the preflight"
        );
        assertEq(LaunchCurve(curve).graduated(), true, "the curve is closed");
    }
}
