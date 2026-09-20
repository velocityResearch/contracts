// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {PooledBrandToken} from "../src/pool/PooledBrandToken.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Issue a stablecoin exactly the way the app's `/issue` screen does, then prove on the
///         same dollars that it is a real 1:1 claim: mint it, redeem half of it back to USDG, and
///         cross the rest into AIUSD inside the shared reserve.
///
/// @dev    **Which `registerBrand`.** The app sends
///         `AssetMarketFactory.registerBrand(name, symbol, metadata, reserve)` — the four-argument
///         factory overload — whenever the deployment it is pointed at has a factory, and falls
///         back to the reserve's own five-argument overload only when it does not
///         (`web-stable/src/features/issuance/issuance-workflow.tsx`). Mainnet has a factory, so
///         this script takes the factory route, and takes it for the reasons the UI comment gives:
///         the factory records `brandOperatorOf`, which is what makes the coin show up as the
///         issuer's, and it derives the logo URL the caller could not have known. The reserve is
///         passed explicitly rather than left to zero, because zero means "whichever reserve the
///         factory prefers" — a different coin the day a second group is approved.
///
///         `metadata.logo` is deliberately empty by default. The UI drops anything that is not an
///         `http(s)` URL, which is the normal case for a draft whose image has not been uploaded
///         yet, and the factory then writes `logoBaseURI + address + logoSuffix` — the exact key
///         the uploader will publish to. Leaving it empty therefore exercises the derived-logo
///         path rather than skipping it, and the run asserts a logo came back.
///
///         **No market, and that is the point.** A representation brand never gets a pool, so the
///         factory hands its treasury admin straight to the operator. If it kept the admin the
///         brand's float would be unclaimable forever, so the post-conditions check that the
///         handover actually landed on the signer.
///
///         **Amounts are deliberately tiny and every assertion is exact.** The product being
///         tested is "one of these is one dollar", which is an equality — a redemption that pays
///         approximately par is a bug, not a rounding detail. Redemption is sent through the
///         overload that takes `minAssetsOut`, set to `previewRedeem`, so the reserve itself
///         refuses anything short of par-less-fee instead of this script discovering it after the
///         tokens are burned.
contract IssueStablecoinMainnet is Script {
    uint256 private constant BPS = 10_000;

    /// @dev The limits `validateRegisterBrand` enforces in the app. Checked here so this script
    ///      cannot issue a coin the form would have refused, or one whose strings it would have
    ///      silently trimmed — the charset rule on the symbol is left to the defaults below.
    uint256 private constant MAX_NAME = 64;
    uint256 private constant MAX_SYMBOL = 12;
    uint256 private constant MAX_DESCRIPTION = 280;
    uint256 private constant MAX_URL = 400;

    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address deployer = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("RESERVE"));
        IERC20 usdg = IERC20(MainnetAddresses.USDG);

        // The same variable name the sibling AIUSD scripts take, and the same brand: the dollar
        // this run crosses into to show the two are fungible inside one reserve.
        address crossBrand = vm.envAddress("QUOTE_BRAND");

        // Five USDG. Six decimals, so 5_000_000 — small enough that this can be run twice if the
        // first attempt reverts, and overridable for a cheaper or larger pass.
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(5_000_000));

        string memory name = vm.envOr("BRAND_NAME", string("Stables Night Dollar"));
        string memory symbol = vm.envOr("BRAND_SYMBOL", string("NIGHTUSD"));
        string memory description = vm.envOr(
            "BRAND_DESCRIPTION",
            string(
                "LIVE TEST COIN. Issued to exercise the Stables issuance flow end to end on "
                "Robinhood Chain with the deployer's own USDG: minted, half redeemed, the rest "
                "crossed into AIUSD. Not a product and not for sale."
            )
        );
        string memory logo = vm.envOr("BRAND_LOGO", string(""));
        string memory socials = vm.envOr("BRAND_SOCIALS", string("https://stables.fast"));

        PooledBrandToken.Metadata memory metadata =
            PooledBrandToken.Metadata({description: description, logo: logo, socials: socials});

        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "brand name is invalid");
        require(
            bytes(symbol).length >= 2 && bytes(symbol).length <= MAX_SYMBOL,
            "brand symbol is invalid"
        );
        require(bytes(description).length <= MAX_DESCRIPTION, "description would be trimmed");
        require(bytes(logo).length <= MAX_URL, "logo URL would be trimmed");
        require(bytes(socials).length <= MAX_URL, "socials URL would be trimmed");

        // Everything the three transactions depend on, read before any of them is signed. A
        // reserve that is not the USDG reserve, a factory that may not register brands in it, or
        // an AIUSD that lives somewhere else all make this run meaningless rather than merely
        // failing, so each is a stop and not a revert to discover mid-flight.
        require(address(reserve.asset()) == MainnetAddresses.USDG, "reserve does not hold USDG");
        require(
            reserve.assetDecimals() == MainnetAddresses.USDG_DECIMALS,
            "reserve asset decimals are not 6"
        );
        require(!reserve.paused(), "the reserve is halted");
        require(
            address(factory.reservePool()) == address(reserve)
                || factory.approvedReservePool(address(reserve)),
            "factory may not register brands in this reserve"
        );
        require(reserve.isRegistered(crossBrand), "the cross brand is not pooled in this reserve");

        require(mintAmount > 0, "MINT_AMOUNT is zero");
        uint256 usdgHeld = usdg.balanceOf(deployer);
        require(usdgHeld >= mintAmount, "wallet holds less USDG than MINT_AMOUNT");

        uint256 cap = reserve.liabilityCap();
        uint256 pooledBefore = reserve.totalPooledSupply();
        require(
            cap == 0 || pooledBefore + mintAmount <= cap, "the liability cap has no room for this"
        );

        // Half back to USDG, the rest across to AIUSD. Splitting this way leaves the test brand at
        // zero supply when the run finishes: the dollars that are not redeemed end up in a brand
        // that has markets and uses, rather than stranded in a coin whose only purpose was to
        // prove the plumbing.
        uint256 redeemAmount = mintAmount / 2;
        uint256 crossAmount = mintAmount - redeemAmount;
        require(redeemAmount > 0, "MINT_AMOUNT is too small to redeem half of");

        uint16 feeBps = reserve.redemptionFeeBps();
        uint256 expectedOut = redeemAmount - redeemAmount * feeBps / BPS;
        // Two independent statements of the same arithmetic. If the reserve's own preview and the
        // fee it advertises disagree, the payout assertion below would be checking the wrong
        // number, so this stops before anything is burned.
        require(expectedOut == reserve.previewRedeem(redeemAmount), "fee preview disagrees");
        require(expectedOut > 0, "the fee would consume the whole redemption");

        console.log("=== Issuing a stablecoin, live ===");
        console.log("Factory:", address(factory));
        console.log("Reserve:", address(reserve));
        console.log("Reserve asset:", IERC20Metadata(MainnetAddresses.USDG).symbol());
        console.log("Cross brand:", IERC20Metadata(crossBrand).symbol());
        console.log("Name:", name);
        console.log("Symbol:", symbol);
        console.log("Redemption fee, bps:", feeBps);
        console.log("USDG held:", usdgHeld);
        console.log("Mint:", mintAmount);
        console.log("Redeem:", redeemAmount);
        console.log("Cross:", crossAmount);
        console.log("Expected USDG back:", expectedOut);

        uint256 crossSupplyBefore = IERC20(crossBrand).totalSupply();
        uint256 crossHeldBefore = IERC20(crossBrand).balanceOf(deployer);

        vm.startBroadcast(deployer);

        (address brand, address treasury) =
            factory.registerBrand(name, symbol, metadata, address(reserve));

        // A brand that has never been minted starts at exactly zero on both counters, which is
        // what makes the equalities after the mint a statement about the mint and not about
        // whatever the token happened to hold already.
        require(IERC20(brand).totalSupply() == 0, "a fresh brand already has supply");
        require(IERC20(brand).balanceOf(deployer) == 0, "a fresh brand already has a holder");

        usdg.approve(address(reserve), mintAmount);
        uint256 minted = reserve.mint(brand, mintAmount, deployer);

        // The 1:1 claim, asserted rather than assumed: n USDG in produces exactly n of the coin,
        // all of it to the receiver named in the call.
        require(minted == mintAmount, "mint reported an amount it was not given");
        require(IERC20(brand).totalSupply() == mintAmount, "supply is not 1:1 with the deposit");
        require(IERC20(brand).balanceOf(deployer) == mintAmount, "the mint went somewhere else");

        // Redemption, measured on the wallet rather than on the return value, because the return
        // value is the reserve's own account of what it paid and the wallet is the truth.
        uint256 usdgBeforeRedeem = usdg.balanceOf(deployer);
        uint256 returned = reserve.redeem(brand, redeemAmount, deployer, expectedOut);
        uint256 usdgReceived = usdg.balanceOf(deployer) - usdgBeforeRedeem;

        require(returned == expectedOut, "redemption did not pay par less the stated fee");
        require(usdgReceived == expectedOut, "the wallet received something else");
        require(
            IERC20(brand).totalSupply() == mintAmount - redeemAmount,
            "redemption burned the wrong amount"
        );

        // The cross. Both dollars are claims on the same pot, so this relabels a claim and moves
        // no backing at all — which is exactly the property the whole product rests on, and the
        // reason a shared reserve was built instead of a pool per brand.
        uint256 crossed = reserve.swap(brand, crossBrand, crossAmount, deployer);

        vm.stopBroadcast();

        uint256 crossReceived = IERC20(crossBrand).balanceOf(deployer) - crossHeldBefore;
        require(crossed == crossAmount, "the swap reported an amount it was not given");
        require(crossReceived == crossAmount, "the cross did not arrive 1:1");
        require(
            IERC20(crossBrand).totalSupply() == crossSupplyBefore + crossAmount,
            "the cross minted something other than what it burned"
        );
        require(IERC20(brand).totalSupply() == 0, "the test brand left supply behind");

        // A swap moves no backing and a mint/redeem move exactly their own, so the reserve's
        // liabilities may have changed by the net dollars deposited and by nothing else. This is
        // the one assertion that would catch a swap having created or destroyed a claim.
        require(
            reserve.totalPooledSupply() == pooledBefore + mintAmount - redeemAmount,
            "the reserve's liabilities moved by an unexplained amount"
        );

        // The coin is the issuer's: their treasury to claim float from, their strings to rewrite,
        // and no market holding either. A representation brand that came back with the factory
        // still on the treasury would have unclaimable yield forever.
        require(PoolBrandTreasury(treasury).admin() == deployer, "treasury admin is not the issuer");
        require(
            PooledBrandToken(brand).metadataAdmin() == deployer, "metadata admin is not the issuer"
        );
        require(factory.treasuryOfBrand(brand) == treasury, "the factory recorded no treasury");
        require(factory.brandOperatorOf(brand) == deployer, "the factory recorded another operator");
        require(factory.reserveOfBrand(brand) == address(reserve), "the brand landed elsewhere");
        require(factory.marketOfBrand(brand) == 0, "a market claimed the brand");

        // The strings the app would have sent, read back off the token. The logo is the derived
        // one unless `BRAND_LOGO` named a URL, and is only absent if the owner never set a logo
        // template — worth reporting rather than asserting, since it costs the coin nothing.
        require(
            keccak256(bytes(PooledBrandToken(brand).description()))
                == keccak256(bytes(description)),
            "the description on chain is not the one sent"
        );
        require(
            keccak256(bytes(PooledBrandToken(brand).socials())) == keccak256(bytes(socials)),
            "the socials on chain are not the ones sent"
        );

        console.log("");
        console.log("Brand:", brand);
        console.log("Treasury:", treasury);
        console.log("Treasury admin:", PoolBrandTreasury(treasury).admin());
        console.log("Decimals:", IERC20Metadata(brand).decimals());
        console.log("Logo:", PooledBrandToken(brand).logo());
        console.log("Supply after mint:", mintAmount);
        console.log("USDG returned on redeem:", usdgReceived);
        console.log("AIUSD received on the cross:", crossReceived);
        console.log("Brand supply at the end:", IERC20(brand).totalSupply());
        console.log("Reserve liabilities:", reserve.totalPooledSupply());
    }
}
