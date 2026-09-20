// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {PoolBrandTreasury} from "../../src/pool/PoolBrandTreasury.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {PooledBrandToken} from "../../src/pool/PooledBrandToken.sol";
import {IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {StandInPermit2, StandInPositionManager} from "../markets/MarketRouter.t.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

contract AuditTaxedAsset is ERC20 {
    constructor() ERC20("Taxed asset", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = amount / 10;
            super._update(from, address(0), tax);
            amount -= tax;
        }
        super._update(from, to, amount);
    }
}

/// @title AssetMarketsSecurityTest
/// @notice What survives of the router-boundary audit work at the FACTORY level, after the
///         market stack moved from Uniswap V3 to V4.
///
///         **Five tests moved rather than died, and here is where each one went.** They were
///         written against `ISwapRouter02` and `INonfungiblePositionManager` doubles — a
///         `AuditSwapBoundary` that minted an arbitrary output and a `AuditPositionBoundary`
///         that recorded `amount0Min`/`amount1Min`. Neither contract has a v4 counterpart: v4
///         has no periphery at all, so a swap is `unlock`/`swap`/settle against the singleton
///         and there is no address left to stub. Re-creating those boundaries would have meant
///         inventing a fake PoolManager and then asserting that our own fake behaved as told.
///
///         Every one of them is now covered against a real `PoolManager` with real liquidity in
///         `test/markets/MarketRouter.t.sol`, which is where the router's own suite lives:
///
///         - `test_BuyRevertsWhenFinalTransferTaxViolatesMinimum`
///           → `test_buySlippageIsCheckedAgainstWhatTheReceiverActuallyHolds`
///         - `test_BuyReturnsActualReceiverAmount`
///           → `test_buySlippageIsCheckedAgainstWhatTheReceiverActuallyHolds` (same test: the
///             reported output is asserted to equal the trader's own balance)
///         - `test_ExpiredEntrypointsRevertBeforePullingFunds`
///           → `test_everyEntryPointRejectsAnExpiredDeadline`
///         - `test_SeedPassesOrderedMinimumsAndRefunds`
///           → `test_seedLiquidityHonoursItsMinimums` and
///             `test_seedLiquidityRefundsTheUnusedSideAndRefundsBrandAsUsdg`
///         - `test_SeedRejectsWorseThanMinimum`
///           → `test_seedLiquidityHonoursItsMinimums`
///
///         The one finding below has no router in it at all and stays where it was written.
contract AssetMarketsSecurityTest is Test, StackFixture {
    MockUSDC usdg;
    SharedReservePool reserve;
    PoolManager manager;
    ProtocolFeeHook feeHook;
    StandInPermit2 permit2;
    StandInPositionManager posm;
    AssetMarketFactory factory;
    AuditTaxedAsset traded;
    uint256 marketId;
    address brand;

    address owner = address(this);

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        reserve = _deployReservePool(address(usdg), address(new MockYieldSource()), address(this));
        traded = new AuditTaxedAsset();

        manager = new PoolManager(address(this));
        feeHook = _deployHook();

        // The factory holds the position manager because every market's `LpRewardDistributor`
        // is initialised with it, so it has to exist before the factory does.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        factory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            feeHook,
            IPositionManagerV4(address(posm)),
            address(0xfee),
            address(traded),
            500,
            address(this)
        );
        feeHook.setRegistrar(address(factory));

        _approveAsset(factory, address(traded), 3000, 1e18, 0, "Brand", "BRAND");
        (marketId, brand,,,) = factory.createMarket(address(traded), address(0));
    }

    /// @dev The hook's permission bits are the low 14 bits of its address; `deployCodeTo` still
    ///      runs the constructor, so the validation mining exists to satisfy still executes.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x3333 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    // Documents a remaining limitation: copying code is sufficient for the flag, regardless
    // of who deployed the instance or controls its independent storage.
    function test_PoC_UnrelatedSameCodeTokenPassesVerification() public {
        AuditTaxedAsset unrelated = new AuditTaxedAsset();
        assertTrue(factory.isCanonicalEquity(address(unrelated)));
    }

    /// @dev The market that `setUp` created still has to be a real, coherent market — otherwise
    ///      the PoC above would be passing against a factory that never got as far as opening
    ///      one. Cheap, and it keeps the fixture honest.
    function test_theFixtureMarketIsReal() public view {
        AssetMarketFactory.Market memory m = factory.market(marketId);
        assertEq(m.brandToken, brand);
        assertEq(m.asset, address(traded));
        assertEq(factory.marketOfPool(m.poolId), marketId);
        assertTrue(m.verified, "the traded token IS the reference here, so it verifies");
    }
}

contract AuditLossSource is MockYieldSource {
    function simulateIndex(uint256 newIndex) external {
        index = newIndex;
    }
}

contract AssetMarketsReserveAuditTest is Test, StackFixture {
    MockUSDC usdg;
    MockYieldSource source;
    SharedReservePool reserve;
    address brand;
    PoolBrandTreasury treasury;

    function setUp() public {
        _deployUpgradeBase();
        usdg = new MockUSDC();
        source = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(source), address(this));
        address treasuryAddress;
        (brand, treasuryAddress) = reserve.registerBrand("Brand", "BRAND", address(this));
        treasury = PoolBrandTreasury(treasuryAddress);
        usdg.mint(address(this), 1100e6);
        usdg.approve(address(reserve), 1000e6);
        reserve.mint(brand, 1000e6, address(this));
        reserve.deployIdle();
        usdg.approve(address(source), 100e6);
        source.simulateYield(address(usdg), 100e6);
    }

    function test_MigrationPreservesUncheckpointedYield() public {
        assertEq(reserve.pendingYield(brand), 100e6);
        reserve.setYieldSource(address(new MockYieldSource()));
        assertEq(reserve.totalAssets(), 1100e6);
        assertEq(reserve.pendingYield(brand), 100e6);
        assertEq(treasury.claim(address(this)), 100e6);
        assertEq(reserve.totalAssets(), 1000e6);
    }

    /// @notice A redemption that cannot be paid in full is a haircut the caller never asked for,
    ///         and the four-argument `redeem` is how they refuse it.
    ///
    ///         The reserve pays from idle after recalling, and `_cappedByIdle` truncates instead
    ///         of reverting so that an adapter's floor-division dust cannot brick redemptions.
    ///         Under a real loss that same tolerance silently pays out less than was burned. Both
    ///         halves are asserted here: the bare overload still absorbs it, the guarded one does
    ///         not, and a reverted redemption leaves the caller's tokens untouched.
    ///
    ///         **What a 10% loss actually does to a single redemption.** It does not make every
    ///         redemption pay 90c. The reserve keeps paying par out of whatever the yield source
    ///         can still deliver, and the loss lands entirely on whoever redeems once that
    ///         capacity runs out — so the guard only has anything to guard when the redemption
    ///         is larger than the position is still worth. That is exactly the shape of the
    ///         failure the guard exists for, and the amounts below are sized to reach it: after
    ///         a 10% loss the source can deliver 900e6 against 1000e6 of outstanding brand.
    function test_redeemHonoursAMinimumPayout() public {
        AuditLossSource lossSource = new AuditLossSource();
        SharedReservePool lossReserve =
            _deployReservePool(address(usdg), address(lossSource), address(this));
        (address token,) = lossReserve.registerBrand("Haircut", "CUT", address(this));

        usdg.mint(address(this), 1000e6);
        usdg.approve(address(lossReserve), 1000e6);
        lossReserve.mint(token, 1000e6, address(this));
        lossReserve.deployIdle();

        // A 10% loss in the yield source: 1000e6 of brand is now backed by 900e6 of underlying.
        lossSource.simulateIndex(0.9e18);

        uint256 balanceBefore = PooledBrandToken(token).balanceOf(address(this));

        // Asking for par on the whole position reverts, and nothing moves.
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, 900e6, 1000e6)
        );
        lossReserve.redeem(token, 1000e6, address(this), 1000e6);
        assertEq(
            PooledBrandToken(token).balanceOf(address(this)),
            balanceBefore,
            "a refused redemption must not burn"
        );

        // Naming the haircut explicitly goes through, and burns the full amount asked for
        // rather than the amount actually paid.
        uint256 paid = lossReserve.redeem(token, 950e6, address(this), 900e6);
        assertEq(paid, 900e6, "pays what the reserve can actually cover");
        assertEq(
            PooledBrandToken(token).balanceOf(address(this)),
            balanceBefore - 950e6,
            "and burns the full amount asked for"
        );

        // The bare overload NO LONGER absorbs silently. It used to: with the reserve drained it
        // would burn the last 50e6 of brand, pay nothing, and return normally, which is a
        // realised loss with no revert and nothing left to retry with. It now demands par less
        // the fee, so the same call reverts and the tokens survive.
        //
        // This assertion is the regression test for that change: it fails against the old
        // implementation, which returned 0 here.
        uint256 beforeLast = PooledBrandToken(token).balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, 0, 50e6)
        );
        lossReserve.redeem(token, 50e6, address(this));
        assertEq(
            PooledBrandToken(token).balanceOf(address(this)),
            beforeLast,
            "a refused bare redemption must not burn either"
        );

        // The haircut is still reachable, deliberately, for a holder who would rather exit at a
        // loss than not exit. That is the four-argument overload, and it is now the only way to
        // ask for one. Nothing a holder could do before has been removed.
        assertEq(lossReserve.redeem(token, 50e6, address(this), 0), 0, "opting in still works");
        assertEq(PooledBrandToken(token).balanceOf(address(this)), 0, "and burns on request");
    }

    function test_LossRecoveryDoesNotCreateYield() public {
        AuditLossSource lossSource = new AuditLossSource();
        SharedReservePool lossReserve =
            _deployReservePool(address(usdg), address(lossSource), address(this));
        (address first, address firstTreasury) =
            lossReserve.registerBrand("First", "FIRST", address(this));
        (address second,) = lossReserve.registerBrand("Second", "SECOND", address(this));
        usdg.mint(address(this), 1000e6);
        usdg.approve(address(lossReserve), 1000e6);
        lossReserve.mint(first, 1000e6, address(this));
        lossReserve.deployIdle();
        lossSource.simulateIndex(0.9e18);
        // An ordinary permissionless swap checkpoints a temporary reserve loss.
        lossReserve.swap(first, second, 1, address(this));
        lossReserve.swap(second, first, 1, address(this));
        lossSource.simulateIndex(1e18);
        assertEq(lossReserve.totalAssets(), lossReserve.totalPooledSupply());
        assertEq(lossReserve.pendingYield(first), 0);
        assertEq(PoolBrandTreasury(firstTreasury).claim(address(this)), 0);
        assertEq(lossReserve.totalAssets(), lossReserve.totalPooledSupply());
    }

    function test_AccruedYieldCannotConsumePrincipalAfterLoss() public {
        // Crystallize the existing 100 USDG yield without paying it out.
        (address second,) = reserve.registerBrand("Second", "SECOND", address(this));
        reserve.swap(brand, second, 1, address(this));
        reserve.swap(second, brand, 1, address(this));
        // A source migration preserves the claim; the replacement's falling balance models
        // loss of previously accrued assets, with the backing now exactly equal to supply.
        reserve.setYieldSource(address(new AuditLossSource()));
        reserve.deployIdle();
        AuditLossSource replacement = AuditLossSource(address(reserve.yieldSource()));
        replacement.simulateIndex(0.9e18);
        assertEq(reserve.pendingYield(brand), 100e6);
        assertEq(treasury.claim(address(this)), 0);
        assertEq(reserve.pendingYield(brand), 100e6);
        replacement.simulateIndex(1e18);
        assertEq(treasury.claim(address(this)), 100e6);
        assertGe(reserve.totalAssets(), reserve.totalPooledSupply());
    }

    function testFuzz_RecoveryAcrossCapitalFlowsDoesNotCreateYield(
        uint96 lossInput,
        uint96 depositInput
    ) public {
        uint256 loss = bound(uint256(lossInput), 1e6, 400e6);
        uint256 deposit = bound(uint256(depositInput), 1e6, 1000e6);
        AuditLossSource lossSource = new AuditLossSource();
        SharedReservePool lossReserve =
            _deployReservePool(address(usdg), address(lossSource), address(this));
        (address first,) = lossReserve.registerBrand("First", "FIRST", address(this));
        usdg.mint(address(this), 1000e6 + deposit);
        usdg.approve(address(lossReserve), type(uint256).max);
        lossReserve.mint(first, 1000e6, address(this));
        lossReserve.deployIdle();
        lossSource.simulateIndex(1e18 - loss * 1e18 / 1000e6);
        // The new brand must not earn yield from capital inflows or repair of old losses.
        (address second,) = lossReserve.registerBrand("Second", "SECOND", address(this));
        lossReserve.mint(second, deposit, address(this));
        assertEq(lossReserve.lossCarryforward(), loss);
        lossReserve.redeem(second, deposit, address(this));
        lossSource.simulateIndex(1e18);
        assertEq(lossReserve.pendingYield(first), 0);
        assertEq(lossReserve.pendingYield(second), 0);
        // Backing must never EXCEED supply — that would be yield conjured out of repairing a
        // loss, which is the thing this test exists to rule out. This direction stays exact.
        assertLe(lossReserve.totalAssets(), lossReserve.totalPooledSupply());
        // It may fall short by dust. `mint` supplies to the yield source inline, and a
        // share-based source floors in both directions, so a mint/redeem round trip at a
        // non-unit share price retires up to a wei of backing that no longer exists to be
        // recovered. Two conversions happen here, so two wei is the bound. The shortfall is
        // not forgiven: `claimYield` refuses to pay yield while `totalAssets()` is under
        // `totalPooledSupply()`, so it is repaid out of the next yield earned.
        assertGe(lossReserve.totalAssets() + 2, lossReserve.totalPooledSupply());
    }
}
