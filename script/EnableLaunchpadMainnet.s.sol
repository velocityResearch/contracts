// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

interface IMarketFactory {
    function reservePool() external view returns (address);
    function approvedReservePool(address pool) external view returns (bool);
    function launchpad() external view returns (address);
}

/// @title EnableLaunchpadMainnet
/// @notice Opens launching on an already-deployed launchpad by registering the quote brand every
///         launch trades against, writing its economics, and flipping the switch.
///
///         **This is the irreversible step.** Everything before it deployed code that nobody
///         could reach: `launchEnabled` was false and no quote brand existed, so the launchpad
///         reverted on every call. After this script anyone with the quote brand can create a
///         token, and a token that reaches its graduation threshold opens a real Uniswap v4
///         market whose skim recipient and fee pips are bound once and for all.
///
///         **The quote brand may sit on a non-default reserve.** `QUOTE_RESERVE` defaults to the
///         sUSDai group rather than the market factory's own `reservePool()`. That works because
///         the factory approves several reserves and a launch carries its reserve through to the
///         market it opens -- proven against the deployed addresses by
///         `test_live_anSusdaiBackedBrandLaunchesAndGraduatesOffTheDefaultReserve`, which
///         launches, buys the allocation out, graduates, and asserts the resulting market records
///         the sUSDai reserve and not the default.
///
///         **What an sUSDai-backed brand is worth while the keeper is stopped.** Deposits are
///         held as local USDG in the adapter and are not bridged, because bridging is the
///         keeper's job. The brand is fully backed and redeemable throughout -- `maxBridgeAmount`
///         gates `bridgeOut` and never `deposit` -- but it earns no sUSDai yield until the keeper
///         runs, and redemption still costs `redemptionFeeBps`. Minting into it is safe; calling
///         it yield-bearing is not yet true.
///
///         This script does NOT launch a token. It leaves the platform open so a human can make
///         the first one deliberately.
///
///         Usage:
///
///         PRIVATE_KEY=0x... LAUNCH_FACTORY=0x... ASSET_MARKET_FACTORY=0x... QUOTE_RESERVE=0x... \
///           forge script script/EnableLaunchpadMainnet.s.sol --rpc-url robinhood --broadcast
///
///         Environment:
///         - PRIVATE_KEY      required. Must own both the reserve and the launch factory.
///         - LAUNCH_FACTORY   required.
///         - ASSET_MARKET_FACTORY required, read only, to check the reserve is one it serves.
///         - QUOTE_RESERVE    required. The reserve the quote brand is registered on.
///         - QUOTE_NAME       optional, default "Stables Launch Dollar".
///         - QUOTE_SYMBOL     optional, default "slUSD".
///         - BRAND_ADMIN      optional, default the deployer. Controls the brand's treasury.
///         - LAUNCH_PHANTOM_QUOTE / LAUNCH_GRADUATION_THRESHOLD / LAUNCH_FEE: optional overrides
///           of the shipped 3_236e6 / 8_090e6 / 1e6.
contract EnableLaunchpadMainnet is Script {
    uint256 internal constant PHANTOM_QUOTE = 3_236e6;
    uint256 internal constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 internal constant LAUNCH_FEE = 1e6;
    uint8 internal constant QUOTE_DECIMALS = 6;

    function run() external returns (address quoteBrand) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        LaunchFactory launch = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        IMarketFactory marketFactory = IMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("QUOTE_RESERVE"));

        string memory name = vm.envOr("QUOTE_NAME", string("Stables Launch Dollar"));
        string memory symbol = vm.envOr("QUOTE_SYMBOL", string("slUSD"));
        address admin = vm.envOr("BRAND_ADMIN", deployer);

        uint256 phantomQuote = vm.envOr("LAUNCH_PHANTOM_QUOTE", PHANTOM_QUOTE);
        uint256 graduationThreshold = vm.envOr("LAUNCH_GRADUATION_THRESHOLD", GRADUATION_THRESHOLD);
        uint256 launchFee = vm.envOr("LAUNCH_FEE", LAUNCH_FEE);

        _preflight(launch, marketFactory, reserve, deployer);

        vm.startBroadcast(deployerKey);

        (quoteBrand,) = reserve.registerBrand(name, symbol, admin);

        // Economics first, switch second. `setPairTokenEconomics` is where every validation
        // lives -- brand registered on the reserve, reserve known to the market factory,
        // decimals matching the token's own -- so the figures are readable and checked before
        // anything is allowed to launch against them.
        launch.setPairTokenEconomics(
            quoteBrand,
            LaunchFactory.PairTokenEconomics({
                reserve: address(reserve),
                phantomQuote: phantomQuote,
                graduationThreshold: graduationThreshold,
                launchFee: launchFee,
                decimals: QUOTE_DECIMALS,
                approved: false
            })
        );
        launch.setPairTokenApproved(quoteBrand, true);
        launch.setLaunchEnabled(true);

        vm.stopBroadcast();

        _report(launch, reserve, quoteBrand, name, symbol, graduationThreshold);
    }

    function _preflight(
        LaunchFactory launch,
        IMarketFactory marketFactory,
        SharedReservePool reserve,
        address deployer
    ) private view {
        require(address(launch).code.length > 0, "LAUNCH_FACTORY has no code");
        require(address(reserve).code.length > 0, "QUOTE_RESERVE has no code");
        require(launch.owner() == deployer, "deployer does not own the launch factory");
        require(reserve.owner() == deployer, "deployer does not own the quote reserve");

        // Without this the launch still sweeps but no launch can ever reach a market, and the
        // failure surfaces only at the graduation of the first token that sells out.
        require(marketFactory.launchpad() != address(0), "market factory has no launchpad set");

        // The reserve must be one the market factory will open markets against, or graduation
        // reverts long after the launch succeeded.
        require(
            marketFactory.reservePool() == address(reserve)
                || marketFactory.approvedReservePool(address(reserve)),
            "QUOTE_RESERVE is not served by the market factory: call setApprovedReservePool"
        );

        require(!launch.launchEnabled(), "launching is already enabled");
    }

    function _report(
        LaunchFactory launch,
        SharedReservePool reserve,
        address quoteBrand,
        string memory name,
        string memory symbol,
        uint256 graduationThreshold
    ) private view {
        console.log("");
        console.log("=== The platform is OPEN ===");
        console.log("Quote brand:", quoteBrand);
        console.log("  name/symbol:", name, symbol);
        console.log("  reserve:", address(reserve));
        console.log("  registered on the reserve:", reserve.isRegistered(quoteBrand));
        console.log("  liability cap (0 = unlimited):", reserve.liabilityCap());
        console.log("  redemption fee (bps):", reserve.redemptionFeeBps());
        console.log("launchEnabled:", launch.launchEnabled());
        console.log("launchCount:", launch.launchCount());
        console.log("graduation threshold:", graduationThreshold);
        console.log("");
        console.log("To create the first token a human needs quote brand, which is minted");
        console.log("1:1 from USDG:");
        console.log("  1. approve USDG to the reserve");
        console.log("  2. reserve.mint(quoteBrand, amount, recipient)");
        console.log("  3. approve the quote brand to the launch factory");
        console.log("  4. launchToken(...) with expectedEconomics from previewLaunchEconomics");
        console.log("");
        console.log("No token has been launched by this script. launchCount is still zero.");
    }
}
