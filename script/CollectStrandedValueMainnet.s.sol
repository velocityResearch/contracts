// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";

/// @dev The gen-4 reserve as its deployed ABI exposes it, declared locally rather than
///      imported: gen-4's `SharedReservePool` source was deleted from `src/` two generations
///      ago, so the current type does not describe it. The three selectors used here were
///      confirmed present in the deployed implementation.
interface IGen4Reserve {
    function asset() external view returns (IERC20);
    function isRegistered(address token) external view returns (bool);
    function redeem(address brandToken, uint256 amount, address receiver) external returns (uint256);
    function totalPooledSupply() external view returns (uint256);
}

/// @title CollectStrandedValueMainnet
/// @notice Collects the two kinds of value sitting uncollected on chain 4663: protocol
///         trading fees the fee hook is holding as ERC-6909 claims, and brand tokens the
///         deployer still holds against a retired reserve.
///
/// @dev    **Neither of these is "stuck", and the distinction matters before spending gas.**
///
///         `ProtocolFeeHook.collect` is permissionless and takes no address: the recipient was
///         bound one-shot at `registerPool` and cannot be redirected, so the only thing a
///         caller decides is when to pay the gas. The claims are therefore safe where they
///         are indefinitely. They are collected here because uncollected revenue held as an
///         ERC-6909 claim inside the PoolManager is revenue that does not appear in any
///         balance an operator looks at, and because an auditor reading `pendingFees` will ask
///         why it was never drained.
///
///         The gen-4 brand tokens are a 1:1 claim on a reserve whose `redeem` carries no
///         `whenNotPaused` by design, so they too are redeemable forever. They are redeemed
///         here so the retired generation's `totalPooledSupply` trends to what third parties
///         hold and nothing else, which is what makes the remaining figure mean something.
///
///         **What is deliberately NOT touched.** Most of gen-4's outstanding brand supply is
///         held by addresses that are not the deployer, including one EIP-7702 delegated
///         wallet. Those are other people's 1:1 claims. This script only ever redeems the
///         signer's own balance, and the reserve's `redeem` stays reachable for everyone else
///         forever. A retired generation is not the same thing as an abandoned one.
///
///         **Economics, stated plainly.** At the time of writing the gen-4 side is worth
///         roughly 0.83 USDG and the gen-6 fee claims roughly 817 USDG-equivalent across four
///         brands. The gen-4 leg very likely costs more in gas than it recovers. It is
///         included because leaving a nonzero balance against a retired deployment is a
///         question every auditor asks, and answering it with a transaction is cheaper than
///         answering it in prose. Set `SKIP_GEN4=true` to run only the leg that pays for
///         itself.
///
///         Read-only by default. Nothing is sent unless `BROADCAST=true`, so the normal way to
///         run this is to look at the report first.
///
///         Usage:
///           # report only, sends nothing, needs no key
///           forge script script/CollectStrandedValueMainnet.s.sol:CollectStrandedValueMainnet --rpc-url robinhood
///
///           # collect for real
///           BROADCAST=true DEPLOYER=0x… PRIVATE_KEY=0x… forge script script/CollectStrandedValueMainnet.s.sol:CollectStrandedValueMainnet --rpc-url robinhood --broadcast --slow
contract CollectStrandedValueMainnet is Script {
    uint256 constant CHAIN_ID = 4663;

    /// @notice Gen-6, the live generation. Its hook holds the fee claims worth collecting.
    address constant GEN6_FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;

    /// @notice Gen-4, retired. Its hook holds a little, and its reserve still has outstanding
    ///         supply, most of it third-party.
    address constant GEN4_FACTORY = 0xbE2fb491C37F19E723F86A8cAcA625B4Ba75a5E7;
    address constant GEN4_RESERVE = 0x076e361b535B236471BEA7f444D5E70971172338;

    /// @dev The brands the deployer still holds against the gen-4 reserve. Enumerating every
    ///      brand the reserve ever registered would mean 11 `balanceOf` calls to find the one
    ///      that is nonzero; the list is short and checked at runtime, so a stale entry is a
    ///      skipped iteration rather than a failure.
    address[1] GEN4_DEPLOYER_BRANDS = [
        0x5CdC1E27044074A002FcE58dF14B809BC13ca764 // BRO
    ];

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        bool broadcast = vm.envOr("BROADCAST", false);
        bool skipGen4 = vm.envOr("SKIP_GEN4", false);
        address me = broadcast ? vm.envAddress("DEPLOYER") : vm.envOr("DEPLOYER", address(0));

        console.log("=== Uncollected value on chain 4663 ===");
        console.log(broadcast ? "MODE: broadcasting" : "MODE: report only, nothing will be sent");
        console.log("");

        _collectHookFees(GEN6_FACTORY, "gen-6 (live)", broadcast);
        if (!skipGen4) {
            _collectHookFees(GEN4_FACTORY, "gen-4 (retired)", broadcast);
            _redeemGen4Brands(me, broadcast);
        }
    }

    /// @dev Walks every market the factory knows and collects whatever its pool has accrued.
    ///      Reads the pool key off the factory rather than reconstructing it, because a key
    ///      assembled by hand hashes to a different pool id on one wrong field and would
    ///      silently collect nothing.
    function _collectHookFees(address factoryAddress, string memory label, bool broadcast)
        internal
    {
        AssetMarketFactory factory = AssetMarketFactory(factoryAddress);
        ProtocolFeeHook hook = ProtocolFeeHook(address(factory.feeHook()));
        uint256 count = factory.marketCount();

        console.log("--- Protocol fee claims,", label);
        console.log("  factory:", factoryAddress);
        console.log("  hook:   ", address(hook));
        console.log("  markets:", count);

        // Counted, not summed. A market's two currencies are a 6-decimal brand and an
        // 18-decimal launch token or equity, so adding the two pending figures together
        // produces a number that looks like a total and means nothing — an 18-decimal leg
        // swamps every 6-decimal one and the result is neither a token count nor a dollar
        // figure. The per-currency lines below are the readable output; anyone wanting a
        // dollar total has to price each currency, which is not this script's job.
        uint256 marketsWithFees;
        uint256 reserveSideTotal; // the 6-decimal brand leg only, which IS comparable
        for (uint256 id = 1; id <= count; ++id) {
            PoolKey memory key = factory.poolKeyOf(id);

            // Preview before touching anything: `collect` zeroes the ledger and returns the
            // amounts, so a report-only run has to read them separately.
            uint256 pending0 = hook.pendingFees(key.toId(), key.currency0);
            uint256 pending1 = hook.pendingFees(key.toId(), key.currency1);
            if (pending0 == 0 && pending1 == 0) continue;
            ++marketsWithFees;

            console.log("  market", id);
            console.log("    currency0", Currency.unwrap(key.currency0));
            console.log("      pending", pending0);
            console.log("    currency1", Currency.unwrap(key.currency1));
            console.log("      pending", pending1);

            // Every pooled brand is a 6-decimal 1:1 claim on its reserve, so brand legs ARE
            // comparable across markets and add up to a USDG figure. The other side is an
            // 18-decimal launch token or tokenized equity and is worth whatever its market
            // says. Discriminating on decimals rather than on the factory's market struct
            // keeps this working against gen-4, whose ABI no longer matches `src/`.
            if (_isBrandLeg(Currency.unwrap(key.currency0))) reserveSideTotal += pending0;
            if (_isBrandLeg(Currency.unwrap(key.currency1))) reserveSideTotal += pending1;

            if (broadcast) {
                vm.broadcast();
                (uint256 got0, uint256 got1) = hook.collect(key);
                require(got0 == pending0 && got1 == pending1, "collected less than was pending");
            }
        }

        console.log("  markets carrying fees:", marketsWithFees);
        console.log("  brand-side legs, summed (6dp, = USDG at par):", reserveSideTotal);
        console.log("  asset-side legs are per-market above; 18dp, so no meaningful total.");
        console.log("");
    }

    /// @dev Whether `token` is a pooled brand rather than the market's asset, decided on
    ///      decimals. Every brand this protocol mints is 6-decimal; the assets it lists are
    ///      18-decimal launch tokens and tokenized equities. A token that does not answer
    ///      `decimals()` at all is treated as not a brand, which is the conservative answer:
    ///      it is excluded from the one total this script claims is meaningful.
    function _isBrandLeg(address token) private view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint8)) == 6;
    }

    /// @dev Redeems only the signer's own balance, 1:1, into the reserve's asset. Never
    ///      touches anybody else's claim.
    function _redeemGen4Brands(address me, bool broadcast) internal {
        IGen4Reserve reserve = IGen4Reserve(GEN4_RESERVE);
        IERC20 asset = reserve.asset();

        console.log("--- Gen-4 brand tokens held by the signer");
        console.log("  reserve:", GEN4_RESERVE);
        console.log("  reserve asset:", address(asset));
        console.log("  totalPooledSupply before:", reserve.totalPooledSupply());

        if (me == address(0)) {
            console.log("  DEPLOYER not set, skipping the per-holder read");
            console.log("");
            return;
        }
        console.log("  signer:", me);

        uint256 assetBefore = asset.balanceOf(me);
        for (uint256 i; i < GEN4_DEPLOYER_BRANDS.length; ++i) {
            address brand = GEN4_DEPLOYER_BRANDS[i];
            if (!reserve.isRegistered(brand)) {
                console.log("  not a brand of this reserve, skipped:", brand);
                continue;
            }
            uint256 held = IERC20(brand).balanceOf(me);
            console.log("  brand", brand);
            console.log("    held:", held);
            if (held == 0 || !broadcast) continue;

            vm.broadcast();
            reserve.redeem(brand, held, me);
        }

        if (broadcast) {
            console.log("  asset gained:", asset.balanceOf(me) - assetBefore);
            console.log("  totalPooledSupply after:", reserve.totalPooledSupply());
            console.log("  What remains outstanding is third-party, and stays redeemable 1:1.");
        }
        console.log("");
    }
}
