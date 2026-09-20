// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AssetMarketForkTest, IMorphoBlueAccrue} from "./AssetMarketFork.t.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Fork characterization of a yield-attribution limitation that has since been CLOSED.
/// @dev This test used to assert the limitation was present: a brand minting after interest had
///      accrued was credited a share of history it was not there for. `SharedReservePool.mint`
///      now supplies to the yield source inline, and Morpho accrues interest on `supply`, so the
///      late mint settles every existing brand against the realised backlog BEFORE the newcomer
///      takes a position. The assertion is inverted accordingly, on 2026-09-09.
///
///      Verified separately that the backlog is not merely swallowed into the accrual baseline:
///      `MainnetLaunchForkTest.test_fork_lateMintDoesNotTakeOrDestroyEarlierInterest` shows the
///      earlier brand keeps its full pending yield across a late mint.
contract MorphoAttributionForkTest is AssetMarketForkTest {
    function test_fork_lateBrandIsNotCreditedInterestThatPredatesIt() public {
        _createSpcxMarket();
        _seed();
        reservePool.deployIdle();
        vm.warp(block.timestamp + 180 days);

        // The late brand is a market unit like any other: the owner lists the asset, then
        // anyone opens its market. Nothing about the listing matters here beyond the market
        // existing, so the price and oracle depth are the parent suite's own for AAPL.
        _approveAsset(factory, AAPL, FEE, 200e18, 0, "Late Dollar", "lateUSD");
        (, address lateBrand,,,) = factory.createMarket(AAPL, address(0));
        vm.startPrank(alice);
        IERC20(USDG).approve(address(reservePool), 100_000e6);
        reservePool.mint(lateBrand, 100_000e6, alice);
        vm.stopPrank();
        assertEq(reservePool.pendingYield(lateBrand), 0, "no time since late mint");

        // No additional time elapses. The underlying market now records old interest.
        IMorphoBlueAccrue morpho = IMorphoBlueAccrue(MORPHO_BLUE);
        morpho.accrueInterest(morpho.idToMarketParams(USDE_MARKET_ID));
        uint256 lateCredit = reservePool.pendingYield(lateBrand);
        emit log_named_uint("historical interest credited to late brand (raw USDG)", lateCredit);
        // Zero, up to a base unit of settlement dust. A late brand earns from its own mint on.
        assertLe(lateCredit, 1, "late brand is not credited interest that predates it");
    }
}
