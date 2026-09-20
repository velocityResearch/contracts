// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchRouter} from "../src/launchpad/LaunchRouter.sol";
import {LaunchCurve} from "../src/launchpad/LaunchCurve.sol";
import {LaunchToken} from "../src/launchpad/LaunchToken.sol";
import {LaunchLocker} from "../src/launchpad/LaunchLocker.sol";
import {
    GraduationPhase,
    ILaunchFactory,
    ILaunchLocker
} from "../src/launchpad/interfaces/ILaunchpad.sol";

/// @notice Drives one launch from creation to graduation against a launchpad that is already
///         deployed, and asserts each step rather than only printing it.
///
/// @dev    Written for a forked Base Sepolia, where the launchpad has to be stood up by hand
///         first — the deployed `AssetMarketFactory` predates `createLaunchMarket`, so it needs a
///         UUPS upgrade and a `setLaunchpad` before anything can graduate. That preparation is
///         deliberately *not* here: this script assumes a wired launchpad and checks the journey
///         through it, so the same script runs unchanged against a real deployment once one
///         exists.
///
///         LAUNCH_FACTORY=0x… LAUNCH_ROUTER=0x… LAUNCH_LOCKER=0x… QUOTE_BRAND=0x… \
///           PRIVATE_KEY=0x… forge script script/LaunchJourneyBaseSepolia.s.sol \
///           --rpc-url http://127.0.0.1:8545 --broadcast --slow
contract LaunchJourneyBaseSepolia is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        LaunchFactory factory = LaunchFactory(vm.envAddress("LAUNCH_FACTORY"));
        LaunchRouter router = LaunchRouter(vm.envAddress("LAUNCH_ROUTER"));
        LaunchLocker locker = LaunchLocker(vm.envAddress("LAUNCH_LOCKER"));
        IERC20 brand = IERC20(vm.envAddress("QUOTE_BRAND"));

        require(factory.launchEnabled(), "launchEnabled() is false");
        (, uint256 phantom, uint256 threshold, uint256 launchFee, uint8 decimals, bool approved) =
            factory.pairTokenEconomics(address(brand));
        require(approved, "quote brand is not approved");
        console.log("threshold (brand units):", threshold);
        console.log("phantom quote:", phantom);
        console.log("launch fee:", launchFee);
        console.log("brand decimals:", decimals);

        uint256 firstBuy = 1_000 * 10 ** decimals;
        require(brand.balanceOf(me) >= launchFee + firstBuy, "not enough quote brand");

        vm.startBroadcast(key);
        brand.approve(address(router), type(uint256).max);

        LaunchFactory.TokenParams memory params = LaunchFactory.TokenParams({
            name: "Arc Pepe",
            symbol: "APEPE",
            logo: "",
            description: "The first frog on Robinhood.",
            socials: LaunchToken.Socials({
                twitter: "@arcpepe", telegram: "", discord: "", website: "", farcaster: ""
            }),
            creatorFeeRecipient: me,
            creatorTaxBps: 100,
            expectedEconomics: factory.previewLaunchEconomics(0, address(brand)),
            salt: keccak256("stables.fast launch journey")
        });

        // ── 1. Launch, buying in the same transaction ────────────────────────────────────
        (address token, address curve, uint256 bought) = router.launchAndBuy(
            params, 0, address(brand), new address[](0), firstBuy, 0, block.timestamp + 1200
        );
        require(token != address(0) && curve != address(0), "launch returned no addresses");
        require(bought > 0, "first buy bought nothing");
        require(IERC20(token).balanceOf(me) == bought, "first buy did not land in the wallet");
        console.log("launched token:", token);
        console.log("curve:", curve);
        console.log("first buy tokens:", bought);

        // ── 2. Sell a slice back, to prove the curve is two-way ──────────────────────────
        IERC20(token).approve(address(router), type(uint256).max);
        uint256 brandBefore = brand.balanceOf(me);
        uint256 out = router.sell(token, bought / 4, 0, block.timestamp + 1200);
        require(out > 0, "sell returned nothing");
        require(brand.balanceOf(me) == brandBefore + out, "sell proceeds did not arrive");
        console.log("sold a quarter back for:", out);

        // ── 3. Buy until it graduates ────────────────────────────────────────────────────
        LaunchCurve c = LaunchCurve(curve);
        uint256 rounds;
        while (!c.graduated() && c.sellableTokens() > 0 && rounds < 40) {
            uint256 remaining = threshold - c.realQuoteReserve();
            uint256 step = remaining < 2_000 * 10 ** decimals
                ? remaining + 10 ** decimals
                : 2_000 * 10 ** decimals;
            if (brand.balanceOf(me) < step) break;
            router.buy(token, step, 0, block.timestamp + 1200);
            rounds++;
        }
        console.log("buy rounds to fill the curve:", rounds);
        require(c.sellableTokens() == 0 || c.graduated(), "curve did not fill");

        // ── 4. Graduate into a real v4 market ────────────────────────────────────────────
        ILaunchFactory.LaunchedToken memory before = factory.getLaunchedToken(token);
        if (before.phase == GraduationPhase.NotGraduated) factory.graduate(token);
        ILaunchFactory.LaunchedToken memory swept = factory.getLaunchedToken(token);
        require(swept.phase == GraduationPhase.Swept, "phase is not Swept");
        console.log("swept quote:", swept.sweptQuote);

        factory.graduateToMarket(token);
        ILaunchFactory.LaunchedToken memory done = factory.getLaunchedToken(token);
        require(done.phase == GraduationPhase.Graduated, "phase is not Graduated");
        require(done.marketId != 0, "graduation recorded no market");
        console.log("graduated into market:", done.marketId);

        // ── 5. The seed position is locked, permanently ──────────────────────────────────
        ILaunchLocker.LockedPosition memory position = locker.lockedPosition(token);
        require(position.exists && position.tokenId != 0, "no locked position recorded");
        console.log("locked position id:", position.tokenId);
        console.log("staked in distributor:", position.distributor);
        console.log("locked supply:", locker.lockedSupply(token));

        vm.stopBroadcast();
        console.log("--- the whole journey held on forked Base Sepolia ---");
    }
}
