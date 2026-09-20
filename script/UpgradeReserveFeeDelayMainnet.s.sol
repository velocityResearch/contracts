// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @title UpgradeReserveFeeDelayMainnet
/// @notice Puts a one-hour announced delay in front of every INCREASE to
///         `SharedReservePool.redemptionFeeBps`, so a quote an aggregator has already given
///         cannot be repriced under it before the fill lands.
///
/// @dev    **The exposure.** `previewRedeem` is what an aggregator routes on, and
///         `redeem(token, amount, receiver)` now demands exactly that number. Between the
///         quote and the fill the owner could call `setRedemptionFee` and the fill would
///         settle at the new fee, or revert against a minimum computed at the old one. A
///         router has no way to tell either outcome apart from ordinary slippage, and no way
///         to price the risk, because the move needed no warning.
///
///         **What changes.** An increase is now announced: `setRedemptionFee(higher)` writes
///         `pendingRedemptionFeeBps` and `redemptionFeeEffectiveAt = now + 1 hour` and leaves
///         the live fee alone. `commitRedemptionFee()` applies it at or after that time and is
///         permissionless, so "the hour has elapsed" and "the fee is live" are the same
///         observable fact rather than two facts separated by whether the owner sent a second
///         transaction. `cancelPendingRedemptionFee()` is owner-only.
///
///         **Decreases still land in one transaction, and cancel anything pending.** A cut
///         cannot make a quoted redemption settle worse than quoted, so there is nobody to
///         protect by delaying it, and in an incident cutting the fee immediately is the whole
///         point. Cancelling on a cut is the conservative half: a value announced against a 20
///         bps baseline must not be committable after the baseline has moved to 10, because
///         that would be a jump to the announced value with no fresh hour of warning. An
///         operator who still wants the increase after a cut announces it again and serves a
///         new full hour.
///
///         **No timelock on upgrades.** This is deliberately narrower than governance. The one
///         thing that can invalidate a live quote is a fee move, so that is the one thing that
///         is delayed; putting a delay on `_authorizeUpgrade` as well would slow every fix
///         without closing anything this does not already close.
///
///         **Storage.** `pendingRedemptionFeeBps` (uint16) and `redemptionFeeEffectiveAt`
///         (uint64) were appended immediately before `__gap`, which shrank from 40 to 39. They
///         pack into one slot — slot 12, previously `__gap[0]` — so every existing field keeps
///         its slot and offset and the gap still ends at slot 51. Verified with
///         `forge inspect SharedReservePool storage` before and after. That is why
///         `upgradeToAndCall` carries empty calldata: there is no initialiser to run, and the
///         new slot reads zero, which is exactly "nothing is pending".
///
///         **Both reserves, one implementation.** The two live proxies share an implementation
///         lineage. Leaving one behind would mean the same selector honouring an announced
///         delay or not depending on which brand an integrator routed through, which is worse
///         than either rule on its own.
///
///         Behaviour covered by the delay tests in `test/SharedReservePool.t.sol`, in
///         particular `test_feeIncrease_isInvisibleToEveryPayoutPathUntilCommitted`, which
///         fails against the old implementation because the increase applies immediately.
///
///         Usage:
///           DEPLOYER=0x… forge script script/UpgradeReserveFeeDelayMainnet.s.sol:UpgradeReserveFeeDelayMainnet --rpc-url robinhood
///           DEPLOYER=0x… forge script script/UpgradeReserveFeeDelayMainnet.s.sol:UpgradeReserveFeeDelayMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract UpgradeReserveFeeDelayMainnet is Script {
    uint256 constant CHAIN_ID = 4663;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The USDG/Morpho reserve. The market factory's default, currently backing no
    ///         market and holding about 1 USDG.
    address constant RESERVE_USDG = 0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3;
    /// @notice The sUSDai reserve. Every one of the 18 live markets draws on this one, so it is
    ///         the reserve an aggregator's redemption actually reaches, and the one whose 20
    ///         bps fee is worth announcing before it moves.
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

        if (_alreadyDelayed(reserves)) {
            console.log("Both reserves already enforce the announced fee-increase delay.");
            console.log("Nothing was deployed and nothing was broadcast.");
            _describe(reserves);
            return;
        }

        // One implementation, deployed once and pointed at both proxies. They run identical
        // logic, and giving them separate implementations would only create a pair of
        // addresses that have to be kept in step by hand.
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
        _describe(reserves);
        console.log("");
        console.log("Tell 0x: a redemption fee INCREASE is announced an hour ahead and is not");
        console.log("live until commitRedemptionFee() is called, so previewRedeem is good for");
        console.log("at least that long. Read redemptionFeeEffectiveAt() to see one coming;");
        console.log("zero means nothing is pending. A DECREASE still applies immediately.");
        console.log("docs/AGGREGATOR_INTEGRATION.md must say so before the integration ships.");
    }

    /// @dev Idempotency. Detected by calling `FEE_INCREASE_DELAY()` through each proxy with a
    ///      raw `staticcall`: the getter exists only on the new implementation, so a successful
    ///      call returning the expected one hour proves the proxy is already running it, and a
    ///      revert proves it is not. This is preferred over comparing implementation addresses
    ///      against a hardcoded constant, which would go stale the moment anything else is
    ///      upgraded, and over reading `redemptionFeeEffectiveAt()`, which reads zero both on
    ///      the old implementation (no such slot exposed) and on the new one with nothing
    ///      scheduled, so it cannot tell the two apart.
    ///
    ///      Both proxies must already have it. A partial state is not "already done" — it is
    ///      the split-behaviour case this script exists to avoid — so the upgrade proceeds and
    ///      re-pointing the already-upgraded proxy at the fresh implementation is harmless.
    function _alreadyDelayed(address[2] memory reserves) internal view returns (bool) {
        for (uint256 i; i < reserves.length; ++i) {
            // `abi.encodeWithSignature` rather than `abi.encodeCall`: a public CONSTANT has a
            // getter in the ABI but no member on the contract type to point `encodeCall` at.
            (bool ok, bytes memory data) =
                reserves[i].staticcall(abi.encodeWithSignature("FEE_INCREASE_DELAY()"));
            if (!ok || data.length != 32 || abi.decode(data, (uint64)) != 1 hours) return false;
        }
        return true;
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

        // Read back through the proxy: the point is that the storage behind it still answers
        // the same way, which is what a layout mistake would break. The accounting figures are
        // the sharp end — a shifted slot shows up as a nonsense supply or a zeroed cap long
        // before it shows up as a failed call.
        require(address(pool.asset()) == was.asset, "asset moved");
        require(address(pool.yieldSource()) == was.yieldSource, "yield source moved");
        require(pool.owner() == was.owner, "owner moved");
        require(pool.totalPooledSupply() == was.totalPooledSupply, "pooled supply moved");
        require(pool.liabilityCap() == was.liabilityCap, "liability cap moved");
        // The LIVE fee, specifically. An upgrade that quietly rebased what redemptions charge
        // would be the exact harm the delay exists to prevent, delivered by the fix for it.
        require(pool.redemptionFeeBps() == was.redemptionFeeBps, "live redemption fee moved");
        // Assets can legitimately tick between the two reads if the yield source accrues
        // inside the same block, so this is a floor rather than an equality.
        require(pool.totalAssets() >= was.totalAssets, "total assets fell across the upgrade");

        // The reserve must still be solvent against its own liabilities. Asserted here rather
        // than assumed because it is the one invariant the whole contract exists to hold, and
        // an upgrade is exactly when a reader wants it restated.
        require(
            pool.totalAssets() >= pool.totalPooledSupply(),
            "reserve is not fully backed after the upgrade"
        );

        // Nothing may be pending the instant the new code lands. The appended slot was part of
        // `__gap` and has never been written, so it must read zero; anything else means the
        // new fields landed on top of something that was already in use, which is the one
        // storage mistake that would not show up in the checks above.
        require(pool.redemptionFeeEffectiveAt() == 0, "an increase is already scheduled");
        require(pool.pendingRedemptionFeeBps() == 0, "a pending fee value is already set");
        require(pool.FEE_INCREASE_DELAY() == 1 hours, "delay constant is not one hour");

        // And the live quote is unmoved by all of the above.
        require(
            pool.previewRedeem(1e6) == 1e6 - 1e6 * uint256(was.redemptionFeeBps) / 10_000,
            "previewRedeem does not match the fee it had before"
        );
    }

    function _describe(address[2] memory reserves) internal view {
        for (uint256 i; i < reserves.length; ++i) {
            SharedReservePool pool = SharedReservePool(reserves[i]);
            console.log("");
            console.log("reserve:", reserves[i]);
            console.log("  live redemption fee (bps):  ", pool.redemptionFeeBps());
            console.log("  pending fee (bps):          ", pool.pendingRedemptionFeeBps());
            console.log("  committable from (unix):    ", pool.redemptionFeeEffectiveAt());
            console.log("  announcement delay (s):     ", pool.FEE_INCREASE_DELAY());
        }
    }
}
