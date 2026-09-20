// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @notice Open the gen-6 launchpad for public launches.
///
/// The launchpad is deployed, wired and `launchEnabled`, but no quote brand carries economics, so
/// every launch reverts. `setPairTokenApproved` also reverts `PairTokenEconomicsInvalid` unless
/// economics are set first, so the order below is forced rather than stylistic.
///
/// The quote brand must be a brand registered on the reserve, not the reserve asset itself:
/// launches quote in a pooled brand, and the reserve mints it 1:1 on the way through.
///
/// Read the state first, from anywhere, with no key:
///   forge script script/EnableMainnetLaunchpad.s.sol:EnableMainnetLaunchpad --sig 'status()' --rpc-url robinhood
///
/// Register a quote brand (permissionless, anyone can do this):
///   PRIVATE_KEY=0x… forge script script/EnableMainnetLaunchpad.s.sol:EnableMainnetLaunchpad \
///     --sig 'registerQuoteBrand(string,string)' "Stables Dollar" "SPUSD" --rpc-url robinhood --broadcast --slow
///
/// Then open it, from the LaunchFactory owner:
///   PRIVATE_KEY=0x… QUOTE_BRAND=0x… forge script script/EnableMainnetLaunchpad.s.sol:EnableMainnetLaunchpad \
///     --sig 'enable()' --rpc-url robinhood --broadcast --slow
contract EnableMainnetLaunchpad is Script {
    // deployments/asset-markets-mainnet-v6.json
    LaunchFactory constant LAUNCH_FACTORY =
        LaunchFactory(0x95fe000285DA7797cC01394cCc410628B26e898d);
    SharedReservePool constant RESERVE =
        SharedReservePool(0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3);

    /// Economics carried over from the Base Sepolia launchpad, which is the only set of these
    /// values that has been exercised end to end. They are a product decision, not a constant:
    /// `phantomQuote` sets the curve's opening price and `graduationThreshold` the quote balance
    /// at which it graduates into an asset market. Override before broadcasting if the intended
    /// mainnet economics differ.
    uint256 constant PHANTOM_QUOTE = 3_236_000_000;
    uint256 constant GRADUATION_THRESHOLD = 8_090_000_000;
    uint256 constant LAUNCH_FEE = 1_000_000;
    uint8 constant QUOTE_DECIMALS = 6;

    function status() external view {
        console.log("LaunchFactory       ", address(LAUNCH_FACTORY));
        console.log("owner               ", LAUNCH_FACTORY.owner());
        console.log("launchEnabled       ", LAUNCH_FACTORY.launchEnabled());
        console.log("registered brands   ", RESERVE.allBrandTokensLength());
        address quote = vm.envOr("QUOTE_BRAND", address(0));
        if (quote == address(0)) {
            console.log("QUOTE_BRAND unset; pass it to inspect a brand's economics.");
            return;
        }
        (
            address reserve,
            uint256 phantomQuote,
            uint256 graduationThreshold,
            uint256 launchFee,
            uint8 decimals,
            bool approved
        ) = LAUNCH_FACTORY.pairTokenEconomics(quote);
        console.log("quote brand         ", quote);
        console.log("  reserve           ", reserve);
        console.log("  phantomQuote      ", phantomQuote);
        console.log("  graduationThreshold", graduationThreshold);
        console.log("  launchFee         ", launchFee);
        console.log("  decimals          ", decimals);
        console.log("  approved          ", approved);
        console.log(
            approved && phantomQuote != 0
                ? "LAUNCHPAD OPEN: this brand can be quoted against."
                : "LAUNCHPAD CLOSED: no approved quote brand, every launch reverts."
        );
    }

    /// Permissionless. Returns the brand token to pass as QUOTE_BRAND.
    function registerQuoteBrand(string calldata name, string calldata symbol)
        external
        returns (address token)
    {
        uint256 key = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(key);
        (token,) = RESERVE.registerBrand(name, symbol, vm.addr(key));
        vm.stopBroadcast();
        console.log("quote brand registered", token);
    }

    /// Owner only. Sets economics then approval, in that order.
    function enable() external {
        address quote = vm.envAddress("QUOTE_BRAND");
        require(quote != address(0), "QUOTE_BRAND required");
        require(RESERVE.isRegistered(quote), "QUOTE_BRAND is not a registered brand");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LAUNCH_FACTORY.setPairTokenEconomics(
            quote,
            LaunchFactory.PairTokenEconomics({
                reserve: address(RESERVE),
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                launchFee: LAUNCH_FEE,
                decimals: QUOTE_DECIMALS,
                approved: false
            })
        );
        LAUNCH_FACTORY.setPairTokenApproved(quote, true);
        if (!LAUNCH_FACTORY.launchEnabled()) LAUNCH_FACTORY.setLaunchEnabled(true);
        vm.stopBroadcast();
        (,,,,, bool approved) = LAUNCH_FACTORY.pairTokenEconomics(quote);
        require(approved, "approval did not take");
        console.log("launchpad open for", quote);
    }
}
