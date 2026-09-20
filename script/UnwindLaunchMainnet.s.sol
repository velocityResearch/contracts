// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {LaunchCurve} from "../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Sell a launch's tokens back to its curve and bank the fees it accrued.
///
/// @dev    **This does not remove the launch, because nothing can.** There is no cancel, abandon
///         or delist anywhere on `LaunchFactory` or `LaunchCurve`: the record stays in
///         `launchAt`, the token keeps its supply, and the curve stays open for anyone who wants
///         to buy. That is deliberate — a launch a creator could erase after selling into it is
///         a rug with an undo button — and it means the most that can be done to a test launch is
///         to take the quote back out and leave it empty.
///
///         Selling the whole balance returns the curve to where it opened: every token back on
///         the curve, its real quote reserve at zero. `sweepFees` then pays the accrued curve fee
///         to the escrow, where the protocol's and the creator's shares are claimable, so nothing
///         is left stranded in the curve itself.
contract UnwindLaunchMainnet is Script {
    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address holder = vm.envAddress("DEPLOYER");
        LaunchFactory launches = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        address token = vm.envAddress("TOKEN");
        // Wide by default: this is an exit from a curve whose whole quote reserve is the seller's
        // own buy, so the only price it can come back at is the one that buy paid.
        uint256 toleranceBps = vm.envOr("TOLERANCE_BPS", uint256(2_000));

        LaunchFactory.LaunchedToken memory record = launches.getLaunchedToken(token);
        require(record.curve != address(0), "this factory did not launch that token");

        LaunchCurve curve = LaunchCurve(record.curve);
        IERC20 sold = IERC20(token);
        IERC20 quote = IERC20(record.pairToken);

        uint256 tokensIn = sold.balanceOf(holder);
        require(tokensIn > 0, "nothing of this launch is held");
        require(!curve.graduated(), "the curve has graduated; trade its market instead");
        (uint256 expected,,) = curve.quoteSell(tokensIn);
        uint256 minQuoteOut = expected * (10_000 - toleranceBps) / 10_000;

        uint256 quoteBefore = quote.balanceOf(holder);

        console.log("=== Unwinding a launch ===");
        console.log("Token:", IERC20Metadata(token).symbol(), token);
        console.log("Curve:", record.curve);
        console.log("Quote dollar:", IERC20Metadata(record.pairToken).symbol());
        console.log("Tokens held:", tokensIn);
        console.log("Curve real quote before:", curve.trackedQuote());
        console.log("Expected quote out:", expected);

        vm.startBroadcast(holder);
        sold.approve(record.curve, tokensIn);
        uint256 quoteOut = curve.sell(tokensIn, minQuoteOut, holder);
        // Permissionless, and it empties the curve's fee buckets into the escrow so the only
        // thing left behind is the token supply itself.
        curve.sweepFees();
        vm.stopBroadcast();

        console.log("");
        console.log("Quote recovered:", quoteOut);
        console.log("Quote balance delta:", quote.balanceOf(holder) - quoteBefore);
        console.log("Curve real quote after:", curve.trackedQuote());
        console.log("Tokens still held:", sold.balanceOf(holder));

        require(quoteOut >= minQuoteOut, "the sell came back under its floor");
        require(sold.balanceOf(holder) == 0, "the position is not fully unwound");
        console.log("");
        console.log("The launch record and its token remain: neither can be deleted.");
    }
}
