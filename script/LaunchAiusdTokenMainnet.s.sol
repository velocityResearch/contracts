// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {LaunchCurve} from "../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchToken} from "../src/launchpad/LaunchToken.sol";
import {GraduationPhase, ILaunchFactory} from "../src/launchpad/interfaces/ILaunchpad.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Launch one memecoin on the live launchpad funded in `AIUSD`, then take the opening
///         buy on its curve — the two steps the application's launch wizard performs, in the
///         order and with the approvals a real creator would use.
///
/// @dev    **This is not a graduation test and must not be read as one.** The curve graduates at
///         `graduationThreshold` of real quote; the opening buy here is a few dollars against a
///         threshold in the thousands, so the launch ends a rounding error along its curve. The
///         final log states the remaining distance in whole quote units for exactly that reason.
///
///         The quote side is funded the way it is funded everywhere else in this repo: USDG is
///         minted 1:1 into the brand at its reserve, so the dollars the curve receives are
///         backed float rather than something conjured for a test. Only the shortfall is minted,
///         because the wallet already holds some of the brand and minting more would strand it.
///
///         **The launch fee is a transfer to `protocolFeeRecipient`, which on this deployment is
///         the deployer itself.** So the fee nets to zero in the wallet while still being a real
///         `safeTransferFrom` the balance has to cover at the moment it runs. The funding target
///         keeps both legs anyway, so this script stays correct if the recipient is ever moved.
///
///         Two transactions, not one: the curve's address is only known once the launch has
///         landed, and `LaunchCurve.buy` pulls the quote through an allowance that therefore
///         cannot be granted in advance. The deployer is exempted from the snipe tax by
///         `_launchToken` itself, so the second transaction pays the untaxed price even though it
///         lands inside the 15-second window.
contract LaunchAiusdTokenMainnet is Script {
    /// @dev Named so nobody finds this on a block explorer and mistakes it for a real project.
    string constant TOKEN_NAME = "Stables Night Test";
    string constant TOKEN_SYMBOL = "NIGHT";

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        LaunchFactory launches = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("RESERVE"));
        IERC20Metadata brand = IERC20Metadata(vm.envAddress("QUOTE_BRAND"));
        IERC20 usdg = IERC20(MainnetAddresses.USDG);

        // Dollars, not base units, and small: the whole point is to exercise the flow, not to
        // move the curve. Five is enough to price a buy that clears the curve's 1% fee floor by
        // four orders of magnitude.
        uint256 buyAmount = vm.envOr("BUY_AMOUNT", uint256(5_000_000));
        // A bound on price, not a target. The launch and the buy are separate transactions, so
        // a sniper can land between them; five percent is wide enough to survive a few dollars
        // of front-running and tight enough that a large one fails the buy instead of filling it.
        uint256 buySlippageBps = vm.envOr("BUY_SLIPPAGE_BPS", uint256(500));

        // Default to the newest config rather than to zero. Configs are append-only and
        // `updateLaunchConfig` edits in place, so the last index is the terms the operator most
        // recently decided on — and with a single config on chain today the two coincide, which
        // means this default is only meaningful once a second one is added.
        uint256 configCount = launches.launchConfigCount();
        require(configCount > 0, "launch factory has no launch configs");
        uint256 configId = vm.envOr("LAUNCH_CONFIG_ID", configCount - 1);
        require(configId < configCount, "LAUNCH_CONFIG_ID is out of range");

        // Everything that can refuse the launch, read before a single transaction is signed.
        // `_validateLaunch` checks all of this too, but it does so after the creator has paid
        // for the attempt, and a failure there is a revert string instead of a sentence.
        require(!launches.paused(), "the launch factory is paused by its guard");
        require(launches.launchEnabled(), "launchEnabled() is false");
        require(address(launches.launchDeployer()) != address(0), "launchDeployer is unwired");
        require(address(launches.graduation()) != address(0), "graduation is unwired");
        require(address(launches.feeEscrow()) != address(0), "feeEscrow is unwired");
        require(launches.protocolFeeRecipient() != address(0), "protocolFeeRecipient is unset");

        LaunchFactory.LaunchConfig memory config = launches.getLaunchConfig(configId);
        require(config.enabled, "the selected launch config is disabled");

        // Economics are keyed by reserve, so this resolves QUOTE_BRAND's reserve and reverts
        // outright if the brand is unregistered, sits on a reserve the market factory does not
        // serve, or has not opted into sharing its float -- the conditions a launch checks live.
        (address economicsReserve, LaunchFactory.ReserveEconomics memory economics) =
            launches.launchEconomics(address(brand));
        require(economics.approved, "QUOTE_BRAND is not approved launch collateral");
        require(economicsReserve == address(reserve), "QUOTE_BRAND belongs to another reserve");
        require(economics.decimals == brand.decimals(), "QUOTE_BRAND was rescaled under its terms");
        require(reserve.isRegistered(address(brand)), "the reserve does not issue QUOTE_BRAND");
        require(!reserve.paused(), "the reserve is paused, so the shortfall cannot be minted");

        uint256 needed = economics.launchFee + buyAmount;
        uint256 held = brand.balanceOf(deployer);
        uint256 shortfall = needed > held ? needed - held : 0;
        require(usdg.balanceOf(deployer) >= shortfall, "not enough USDG to top up the quote side");

        // The terms quoted here, pinned into the launch, so an owner re-peg landing between this
        // read and the broadcast reverts the launch instead of silently repricing its curve.
        bytes32 expectedEconomics = launches.previewLaunchEconomics(configId, address(brand));

        console.log("=== Launching a token on the live launchpad ===");
        console.log("Launch factory:", address(launches));
        console.log("Quote brand:", brand.symbol(), address(brand));
        console.log("Launch config id:", configId);
        console.log("  supply:", config.supply);
        console.log("  curve fee, bps:", config.curveFeeBps);
        console.log("  graduated pool fee:", config.poolFee);
        console.log("Launch fee:", economics.launchFee);
        console.log("Graduation threshold:", economics.graduationThreshold);
        console.log("Opening buy:", buyAmount);
        console.log("Brand held:", held);
        console.log("Shortfall to mint from USDG:", shortfall);

        LaunchFactory.TokenParams memory params = LaunchFactory.TokenParams({
            name: TOKEN_NAME,
            symbol: TOKEN_SYMBOL,
            logo: "",
            description: "A live end-to-end test of the Stables launchpad. Not a project.",
            socials: LaunchToken.Socials({
                twitter: "", telegram: "", discord: "", website: "", farcaster: ""
            }),
            creatorFeeRecipient: deployer,
            creatorTaxBps: 0,
            expectedEconomics: expectedEconomics,
            // Curve and token addresses are CREATE2-derived from this, so a rerun on identical
            // terms would collide with the pair already standing at that address. Keyed on the
            // block timestamp, which no two runs of this script can share.
            salt: keccak256(abi.encode("stables.night.test", block.timestamp))
        });

        vm.startBroadcast(deployer);

        if (shortfall != 0) {
            usdg.approve(address(reserve), shortfall);
            reserve.mint(address(brand), shortfall, deployer);
        }

        // Exactly the fee, not an open allowance: the factory pulls once and never again.
        brand.approve(address(launches), economics.launchFee);
        (address token, address curveAddress) =
            launches.launchToken(params, configId, address(brand), new address[](0));

        LaunchCurve curve = LaunchCurve(curveAddress);
        (uint256 quoteReserveBefore, uint256 tokenReserveBefore) = curve.getReserves();
        uint256 realQuoteBefore = curve.realQuoteReserve();

        // Priced against the curve that now exists, so the bound below is a real slippage
        // tolerance rather than a guess at the shape of a curve this script never saw.
        (uint256 expectedTokens,,) = curve.quoteBuy(buyAmount, deployer);
        uint256 minTokensOut = expectedTokens * (10_000 - buySlippageBps) / 10_000;

        uint256 brandBeforeBuy = brand.balanceOf(deployer);
        uint256 tokensBeforeBuy = IERC20(token).balanceOf(deployer);

        brand.approve(curveAddress, buyAmount);
        uint256 tokensOut = curve.buy(buyAmount, minTokensOut, deployer);

        vm.stopBroadcast();

        uint256 quoteSpent = brandBeforeBuy - brand.balanceOf(deployer);
        (uint256 quoteReserveAfter, uint256 tokenReserveAfter) = curve.getReserves();
        uint256 realQuoteAfter = curve.realQuoteReserve();

        // The launch is recorded, in the factory's map and in its append-only list, and the
        // money the buy paid is sitting on the curve rather than anywhere else.
        ILaunchFactory.LaunchedToken memory launched = launches.getLaunchedToken(token);
        require(launched.exists, "the factory did not record the launch");
        require(launched.token == token, "the record names a different token");
        require(launched.curve == curveAddress, "the record names a different curve");
        require(launched.deployer == deployer, "the record credits a different creator");
        require(launched.pairToken == address(brand), "the launch was quoted in another brand");
        require(launched.phase == GraduationPhase.NotGraduated, "the curve already graduated");
        require(launches.launchAt(launches.launchCount() - 1) == token, "not the newest launch");
        require(tokensOut > 0, "the opening buy bought nothing");
        require(
            IERC20(token).balanceOf(deployer) == tokensBeforeBuy + tokensOut,
            "the tokens bought did not land in the wallet"
        );
        require(brand.balanceOf(curveAddress) == quoteSpent, "the curve does not hold the quote");
        require(curve.trackedQuote() == quoteSpent, "the curve did not book the quote it holds");
        // `realQuoteReserve` — the figure graduation is measured against — deliberately excludes
        // fees awaiting sweep, so it lands short of the spend by exactly the curve's own cut.
        // Adding the two fee buckets back is what makes this an accounting identity rather than
        // a restatement of the line above.
        require(
            realQuoteAfter + curve.quoteFeeBalance() + curve.creatorTaxBalance()
                == realQuoteBefore + quoteSpent,
            "the curve mispriced its own float"
        );

        // Whole quote units, so the gap reads as dollars and not as a nine-digit integer nobody
        // can scale by eye.
        uint256 unit = 10 ** economics.decimals;
        uint256 remaining = economics.graduationThreshold - realQuoteAfter;

        console.log("");
        console.log("Token:", token);
        console.log("Curve:", curveAddress);
        console.log("Launch fee paid:", economics.launchFee);
        console.log("  paid to:", launches.protocolFeeRecipient());
        console.log("Quote spent on the opening buy:", quoteSpent);
        console.log("Tokens bought:", tokensOut);
        console.log("Curve fee held, pending sweep:", curve.quoteFeeBalance());
        console.log("Curve quote reserve before (phantom included):", quoteReserveBefore);
        console.log("Curve quote reserve after  (phantom included):", quoteReserveAfter);
        console.log("Curve real quote before:", realQuoteBefore);
        console.log("Curve real quote after:", realQuoteAfter);
        console.log("Curve token reserve before:", tokenReserveBefore);
        console.log("Curve token reserve after:", tokenReserveAfter);
        console.log("");
        console.log("NOT GRADUATED, and nowhere near it. Graduation needs a real quote reserve of");
        console.log("  threshold, whole units:", economics.graduationThreshold / unit);
        console.log("  reached, whole units:", realQuoteAfter / unit);
        console.log("  still needed, whole units:", remaining / unit);
        console.log(
            "  progress, bps of threshold:", realQuoteAfter * 10_000 / economics.graduationThreshold
        );
        console.log("Graduation was NOT exercised by this run.");
    }
}
