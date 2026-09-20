// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Open Fast Dollar ($FASTUSD) for launches: its curve economics, then its approval.
///
/// @dev    This is the owner action behind showing $FASTUSD as the second quote dollar on the
///         launch form, beside $AIUSD. The form offers only brands the factory has approved as
///         collateral (`pairTokenEconomics(...).approved`), so until this runs $FASTUSD sits in
///         the picker's "Coming soon" row and a launch funded in it reverts `PairTokenNotApproved`.
///
///         **Why not `AllowlistLaunchCollateralMainnet`.** That script copies a dollar's economics
///         from an approved template *of the same reserve*, and asserts the two reserves match.
///         Every approved dollar today — $AIUSD and $slUSD — sits in the sUSDai reserve, while
///         $FASTUSD is registered on the factory's own default USDG reserve, whose strategy is the
///         Morpho Blue USDG/USDe market. The same-reserve rule would refuse it. This script keeps
///         the half of that rule that matters — copy the curve figures from a dollar that already
///         works, never invent them — and replaces the half that does not: the reserve a launch
///         graduates into is read from the TARGET, not borrowed from the template, then checked to
///         be one the market factory serves. The default reserve is always served, so $FASTUSD
///         graduates cleanly and a launch funded in it needs no sUSDai bridge at all.
///
///         The curve figures are copied from $AIUSD (`TEMPLATE`): identical `phantomQuote`,
///         `graduationThreshold` and `launchFee`, so $FASTUSD opens with the same curve shape and
///         the same fraction of supply reaching the graduated pool as the flagship dollar.
contract AllowlistFastUsdMainnet is Script {
    /// @notice Fast Dollar, registered on the default USDG reserve `0xdB48…d9F3`. Verified
    ///         registered there and `marketId == 0` — a dollar, not a market's own unit.
    address internal constant FASTUSD = 0x53b20867df5e2CFeBB5B324A39A7640F3Bf4f6a2;
    /// @notice Stables AI USD, the approved dollar whose curve figures are copied. It sits on the
    ///         sUSDai reserve; only its economics are borrowed, never its reserve.
    address internal constant AIUSD = 0xE7BB388959d89f809BE24da16A1DaBa0dC58E596;

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        LaunchFactory launches = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        AssetMarketFactory markets = AssetMarketFactory(vm.envAddress("FACTORY"));

        address target = vm.envOr("TARGET", FASTUSD);
        address template = vm.envOr("TEMPLATE", AIUSD);

        require(launches.owner() == deployer, "signer does not own the launch factory");

        // The curve is copied from a dollar that already works. The figures are the whole curve
        // shape, so they are taken verbatim rather than retyped.
        LaunchFactory.PairTokenEconomics memory from = _economics(launches, template);
        require(from.approved, "TEMPLATE is not an approved quote brand");
        require(from.phantomQuote > 0 && from.graduationThreshold > 0, "TEMPLATE has no curve");

        // The reserve a launch graduates into is the TARGET's own, read rather than assumed. It
        // must be one the market factory will open a market against, or graduation reverts long
        // after the launch succeeded. The default reserve always qualifies.
        address reserve = markets.reserveOfBrand(target);
        require(reserve != address(0), "TARGET was not registered by the market factory");
        require(
            reserve == address(markets.reservePool()) || markets.approvedReservePool(reserve),
            "TARGET's reserve is not served by the market factory"
        );

        uint8 decimals = IERC20Metadata(target).decimals();
        require(decimals == from.decimals, "TARGET and TEMPLATE are scaled differently");
        require(decimals >= 6, "quote brand is too coarse for integer-basis-point curve fees");

        // Re-running after a successful broadcast is a no-op guard rather than a rewrite: the
        // economics are already there, so only an unapproved target is opened here.
        LaunchFactory.PairTokenEconomics memory existing = _economics(launches, target);
        require(!existing.approved, "TARGET is already approved; nothing to do");

        LaunchFactory.PairTokenEconomics memory to = LaunchFactory.PairTokenEconomics({
            reserve: reserve,
            phantomQuote: from.phantomQuote,
            graduationThreshold: from.graduationThreshold,
            launchFee: from.launchFee,
            decimals: decimals,
            approved: true
        });

        console.log("=== Opening Fast Dollar for launches ===");
        console.log("Launch factory:", address(launches));
        console.log("Target:", IERC20Metadata(target).symbol(), target);
        console.log("Curve copied from:", IERC20Metadata(template).symbol(), template);
        console.log("Reserve (the target's own):", reserve);
        console.log("  is the factory default:", reserve == address(markets.reservePool()));
        console.log("Phantom quote:", to.phantomQuote);
        console.log("Graduation threshold:", to.graduationThreshold);
        console.log("Launch fee:", to.launchFee);

        vm.startBroadcast(deployerKey);
        launches.setPairTokenEconomics(target, to);
        // Economics first, approval second: `setPairTokenApproved` refuses a brand with no
        // `phantomQuote`, which is the same ordering this enforces by doing them in one run.
        launches.setPairTokenApproved(target, true);
        vm.stopBroadcast();

        LaunchFactory.PairTokenEconomics memory written = _economics(launches, target);
        require(written.approved, "TARGET did not end up approved");
        require(written.reserve == reserve, "reserve did not take");
        require(written.phantomQuote == from.phantomQuote, "phantom quote did not take");
        require(written.graduationThreshold == from.graduationThreshold, "threshold did not take");
        require(written.launchFee == from.launchFee, "launch fee did not take");

        console.log("");
        console.log("Approved. Launches may now be funded in Fast Dollar.");
    }

    function _economics(LaunchFactory launches, address pairToken)
        private
        view
        returns (LaunchFactory.PairTokenEconomics memory e)
    {
        (
            address reserve,
            uint256 phantomQuote,
            uint256 graduationThreshold,
            uint256 launchFee,
            uint8 decimals,
            bool approved
        ) = launches.pairTokenEconomics(pairToken);
        e = LaunchFactory.PairTokenEconomics({
            reserve: reserve,
            phantomQuote: phantomQuote,
            graduationThreshold: graduationThreshold,
            launchFee: launchFee,
            decimals: decimals,
            approved: approved
        });
    }
}
