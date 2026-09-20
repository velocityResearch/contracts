// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @title UpgradeReserveStrictRedeemMainnet
/// @notice Makes `SharedReservePool.redeem(token, amount, receiver)` demand par less the fee
///         instead of accepting any payout including zero.
///
/// @dev    **The defect.** The three-argument overload passed `minAssetsOut = 0`. It burned the
///         caller's brand tokens and then paid whatever the reserve could raise, retiring the
///         difference against `lossCarryforward`. Because the burn happened first there was
///         nothing left to retry with, so a short reserve converted a redemption into a
///         realised loss with no revert and no event that distinguished it from a good one.
///         `docs/AGGREGATOR_INTEGRATION.md` names this exact selector (`0x5c833bfd`) as the one
///         an aggregator calls, which made it the most dangerous default in the system and the
///         reason this is being fixed before the 0x handoff rather than after.
///
///         **Why tightening it is safe.** Every in-protocol caller already passes an explicit
///         minimum: `MarketRouter:452`, `LaunchRouter:325`, `BrandPsm:207`. The old NatSpec
///         claimed the laxity existed for refunds inside `MarketRouter`, but `_refund` was
///         changed to return the brand leg in kind rather than redeem it, so that caller has
///         not existed for some time and the comment outlived its reason. Verified by grepping
///         `\.redeem\(` across `src/` before writing this: there are no three-argument call
///         sites in the protocol at all.
///
///         **Nothing is taken away from a holder.** A haircut is still reachable through the
///         four-argument overload with a lower bound, which is what a holder who would rather
///         exit at a loss than not exit should call. What changed is which behaviour you get by
///         not choosing one. That matters for the reserve's central promise — a brand is a 1:1
///         claim its holder can always leave — because "always" has to mean "at a price they
///         can see", not "at whatever price happens to obtain".
///
///         **No storage moved.** The change is entirely inside a function body: the default
///         handed to the private `_redeem` goes from a literal zero to
///         `amount - amount * redemptionFeeBps / BPS`. No variable was added, removed or
///         reordered, which is why `upgradeToAndCall` carries empty calldata.
///
///         **Both reserves.** There are two live `SharedReservePool` proxies and they share an
///         implementation lineage but not an implementation address. Both are upgraded here,
///         because leaving one on the old semantics would mean the same selector behaving
///         differently depending on which brand an integrator happened to route through, which
///         is worse than either behaviour on its own.
///
///         Regression covered by `test_redeemHonoursAMinimumPayout` in
///         `test/audit/AssetMarketsSecurity.t.sol`, whose final assertions fail against the old
///         implementation.
///
///         Usage:
///           DEPLOYER=0x… forge script script/UpgradeReserveStrictRedeemMainnet.s.sol:UpgradeReserveStrictRedeemMainnet --rpc-url robinhood
///           DEPLOYER=0x… forge script script/UpgradeReserveStrictRedeemMainnet.s.sol:UpgradeReserveStrictRedeemMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract UpgradeReserveStrictRedeemMainnet is Script {
    uint256 constant CHAIN_ID = 4663;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The USDG/Morpho reserve. The market factory's default, currently backing no
    ///         market and holding about 1 USDG.
    address constant RESERVE_USDG = 0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3;
    /// @notice The sUSDai reserve. Every one of the 18 live markets draws on this one, so it is
    ///         the reserve an aggregator's redemption actually reaches.
    address constant RESERVE_SUSDAI = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;

    /// @dev Everything the upgrade must not disturb, read per reserve before it runs.
    struct Before {
        address implementation;
        address asset;
        address yieldSource;
        address owner;
        uint256 totalAssets;
        uint256 totalPooledSupply;
        uint256 liabilityCap;
        uint16 redemptionFeeBps;
    }

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address deployer = vm.envAddress("DEPLOYER");

        address[2] memory reserves = [RESERVE_USDG, RESERVE_SUSDAI];
        Before[2] memory was;
        for (uint256 i; i < reserves.length; ++i) {
            was[i] = _read(reserves[i]);
            require(was[i].owner == deployer, "signer does not own a reserve");
        }

        // One implementation, deployed once and pointed at both proxies. They run identical
        // logic, and giving them separate implementations would only create a pair of addresses
        // that have to be kept in step by hand.
        vm.startBroadcast(deployer);
        SharedReservePool fresh = new SharedReservePool();
        for (uint256 i; i < reserves.length; ++i) {
            SharedReservePool(reserves[i]).upgradeToAndCall(address(fresh), "");
        }
        vm.stopBroadcast();

        for (uint256 i; i < reserves.length; ++i) {
            _verify(reserves[i], address(fresh), was[i]);
        }

        console.log("SharedReservePool implementation:", address(fresh));
        console.log("  USDG/Morpho reserve: ", RESERVE_USDG);
        console.log("  sUSDai reserve:      ", RESERVE_SUSDAI);
        console.log("");
        console.log("redeem(token,amount,receiver) now demands previewRedeem(amount).");
        console.log("A haircut is the 4-argument overload with a lower bound.");
        console.log("");
        console.log("Tell 0x: the 3-arg selector 0x5c833bfd now REVERTS on a short reserve");
        console.log("instead of paying less than quoted. docs/AGGREGATOR_INTEGRATION.md");
        console.log("must say so before the integration ships.");
    }

    function _read(address reserve) internal view returns (Before memory b) {
        SharedReservePool pool = SharedReservePool(reserve);
        b.implementation = address(uint160(uint256(vm.load(reserve, IMPL_SLOT))));
        b.asset = address(pool.asset());
        b.yieldSource = address(pool.yieldSource());
        b.owner = pool.owner();
        b.totalAssets = pool.totalAssets();
        b.totalPooledSupply = pool.totalPooledSupply();
        b.liabilityCap = pool.liabilityCap();
        b.redemptionFeeBps = pool.redemptionFeeBps();
    }

    function _verify(address reserve, address fresh, Before memory was) internal view {
        SharedReservePool pool = SharedReservePool(reserve);

        require(
            address(uint160(uint256(vm.load(reserve, IMPL_SLOT)))) == fresh, "proxy did not move"
        );

        // Read back through the proxy: the point is that the storage behind it still answers the
        // same way, which is what a layout mistake would break. The accounting figures are the
        // sharp end — a shifted slot shows up as a nonsense supply or a zeroed cap long before
        // it shows up as a failed call.
        require(address(pool.asset()) == was.asset, "asset moved");
        require(address(pool.yieldSource()) == was.yieldSource, "yield source moved");
        require(pool.owner() == was.owner, "owner moved");
        require(pool.totalPooledSupply() == was.totalPooledSupply, "pooled supply moved");
        require(pool.liabilityCap() == was.liabilityCap, "liability cap moved");
        require(pool.redemptionFeeBps() == was.redemptionFeeBps, "redemption fee moved");
        // Assets can legitimately tick between the two reads if the yield source accrues inside
        // the same block, so this is a floor rather than an equality.
        require(pool.totalAssets() >= was.totalAssets, "total assets fell across the upgrade");

        // The reserve must still be solvent against its own liabilities. Asserted here rather
        // than assumed because it is the one invariant the whole contract exists to hold, and an
        // upgrade is exactly when a reader wants it restated.
        require(
            pool.totalAssets() >= pool.totalPooledSupply(),
            "reserve is not fully backed after the upgrade"
        );

        // And the new default is live: `previewRedeem` is what the three-argument overload now
        // demands, so a nonzero supply must quote a nonzero payout for the change to mean
        // anything. Cheap, but it is the difference between upgrading and believing you did.
        if (was.totalPooledSupply > 0) {
            require(pool.previewRedeem(1e6) > 0, "previewRedeem does not answer");
        }
    }
}
