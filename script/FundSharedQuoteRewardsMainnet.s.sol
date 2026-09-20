// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../src/markets/LpRewardDistributor.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Start an LP reward stream on a market quoted in a dollar it does not own.
///
/// @dev    This is the other half of `createMarketForBrand`, and the reason that path leaves the
///         dollar's treasury alone. A market that mints its own unit takes that unit's treasury,
///         so its float pays its LPs automatically and forever. A market quoted in AIUSD cannot:
///         the float behind AIUSD belongs to AIUSD — to coins held in wallets and to the other
///         pools quoting it — and no contract can divide it between them without knowing each
///         pool's share of a Uniswap v4 singleton, which nobody can read.
///
///         So the stream is funded deliberately, by whoever holds the dollar's float, and this
///         is the transaction that does it: put the dollar in the market's own fee vault, then
///         `sweep`. The vault splits it exactly as it splits harvested float — the protocol's
///         basis points out, the remainder streamed to this pool's LPs over the reward period —
///         because to the vault a balance is a balance, whatever put it there.
contract FundSharedQuoteRewardsMainnet is Script {
    function run() external {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "mainnet only");

        address funder = vm.envAddress("DEPLOYER");
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("FACTORY"));
        SharedReservePool reserve = SharedReservePool(vm.envAddress("RESERVE"));
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 amount = vm.envOr("AMOUNT", uint256(2_000_000));

        AssetMarketFactory.Market memory m = factory.market(marketId);
        require(factory.isSharedQuote(marketId), "this market owns its unit and harvests its own");

        BrandFeeVault vault = BrandFeeVault(m.feeVault);
        LpRewardDistributor distributor = LpRewardDistributor(m.lpDistributor);
        IERC20 quote = IERC20(m.brandToken);
        IERC20 usdg = IERC20(MainnetAddresses.USDG);

        require(amount >= vault.minSweep(), "below the vault's minimum sweep");
        require(usdg.balanceOf(funder) >= amount, "not enough USDG to mint the reward with");

        uint256 notifiedBefore = distributor.totalNotified();
        uint256 lpsBefore = vault.totalToLps();
        uint256 protocolBefore = vault.totalToProtocol();

        console.log("=== Funding a shared-quote market's LP stream ===");
        console.log("Market:", marketId);
        console.log("Quote dollar:", m.brandToken);
        console.log("Fee vault:", m.feeVault);
        console.log("Distributor:", m.lpDistributor);
        console.log("Amount:", amount);
        console.log("Protocol share, bps:", vault.protocolBps());

        vm.startBroadcast(funder);
        // Minted rather than transferred out of the wallet's own holdings so the reward is backed
        // float like every other dollar in this reserve, not a balance moved around.
        usdg.approve(address(reserve), amount);
        reserve.mint(m.brandToken, amount, address(vault));
        (uint256 toProtocol, uint256 toLps) = vault.sweep();
        vm.stopBroadcast();

        console.log("");
        console.log("To protocol:", toProtocol);
        console.log("To LPs:", toLps);
        console.log("Reward rate, per second:", distributor.rewardRate());
        console.log("Period finishes at:", distributor.periodFinish());

        require(toProtocol + toLps == amount, "the sweep did not account for the whole balance");
        require(
            distributor.totalNotified() == notifiedBefore + toLps, "the LP stream was not notified"
        );
        require(vault.totalToLps() == lpsBefore + toLps, "vault ledger did not record the LPs");
        require(
            vault.totalToProtocol() == protocolBefore + toProtocol,
            "vault ledger did not record the protocol"
        );
        require(quote.balanceOf(address(vault)) == 0, "the vault kept something back");
        require(distributor.periodFinish() > block.timestamp, "the stream is not open");
    }
}
