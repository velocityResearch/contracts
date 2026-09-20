// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";

interface ILaunchFactory {
    function launchCount() external view returns (uint256);
    function launchAt(uint256 index) external view returns (address);
}

interface ILaunchCurve {
    function graduated() external view returns (bool);
    function quoteFeeBalance() external view returns (uint256);
    function creatorTaxBalance() external view returns (uint256);
    function pairToken() external view returns (address);
    function sweepFees() external;
}

interface ILaunchFeeEscrow {
    function balanceOfToken(address recipient, address token) external view returns (uint256);
    function claimToken(address token) external returns (uint256);
}

/// @title SweepFeesToSafeMainnet
/// @notice Steps 1 and 2 of moving protocol revenue onto the multisig: realise everything
///         accrued to the retiring deployer EOA, then forward exactly that to the Safe.
///
/// @dev    **Why this must run BEFORE any recipient is repointed.** None of these balances are
///         attributed to whoever was named when the fee accrued. `ProtocolFeeHook.collect`
///         pays `feeRecipientOf` as it reads at the moment the call executes, and
///         `BrandFeeVault.sweep` pays `protocolTreasury` the same way. Repointing first would
///         hand the already-earned balance to the new address, which is harmless here only
///         because the new address is ours; the habit is not harmless, so the order is fixed
///         and stated. `LaunchFeeEscrow.claimToken` is different again: it is
///         `msg.sender`-scoped, so the escrow balance can ONLY ever be taken by the deployer
///         and repointing would strand it permanently.
///
///         **Why it forwards a measured delta rather than a balance.** The deployer holds
///         things that are not protocol revenue: gas, memecoin bags bought with its own
///         money, equity dust. Sending `balanceOf` would sweep those too. So every token is
///         measured before and after the claims, and only the difference moves. A token whose
///         balance did not grow is not touched at all.
///
///         **Vault float yield is deliberately NOT touched.** Every live `BrandFeeVault`
///         has `protocolBps` of 0 and no setter for it, so LPs take 100% of float yield and
///         a sweep moves nothing to the protocol. Sweeping is permissionless and anyone may
///         do it to pay the LPs, but it has no place in a script about protocol revenue,
///         and including it only risked recording a reverting call.
///
///         **Nothing here is `onlyOwner`.** `collect` and `sweep` are permissionless by
///         design, and the claim is the deployer's own. Repointing the recipients IS
///         owner-gated and therefore a Safe transaction, which is step 3 and deliberately not
///         in this script.
///
///         Usage:
///           DEPLOYER=0x… SAFE=0x… forge script script/SweepFeesToSafeMainnet.s.sol:SweepFeesToSafeMainnet --rpc-url robinhood
///           DEPLOYER=0x… SAFE=0x… forge script script/SweepFeesToSafeMainnet.s.sol:SweepFeesToSafeMainnet --rpc-url robinhood --private-key 0x… --broadcast --slow
contract SweepFeesToSafeMainnet is Script {
    using SafeERC20 for IERC20;

    uint256 constant CHAIN_ID = 4663;

    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    address constant FEE_HOOK = 0xc9932584c5154e4F58313a2e5423522E74e540Cc;
    address constant ESCROW = 0xb1BeEbb3c077705273bcC4F80f560F43941205b6;
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    /// @dev The reserve asset every vault sweeps in. NOT AIUSD, which is a brand dollar
    ///      and is picked up from the market list like any other.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    AssetMarketFactory factory = AssetMarketFactory(FACTORY);
    ProtocolFeeHook hook = ProtocolFeeHook(FEE_HOOK);

    /// @dev Every token any of the claims can pay out, deduplicated as it is built.
    address[] tokens;
    mapping(address => bool) seen;

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");
        address deployer = vm.envAddress("DEPLOYER");
        address safe = vm.envAddress("SAFE");
        require(safe != address(0) && safe.code.length > 0, "SAFE is not a contract");
        require(safe != deployer, "SAFE is the deployer");

        uint256 count = factory.marketCount();
        _collectTokens(count);

        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = IERC20(tokens[i]).balanceOf(deployer);
        }

        vm.startBroadcast(deployer);
        _collectHookFees(count);
        _sweepCurves();
        _claimEscrow(deployer);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Forwarding the measured delta to %s ===", safe);
        vm.startBroadcast(deployer);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 gained = IERC20(tokens[i]).balanceOf(deployer) - before[i];
            if (gained == 0) continue;
            // safeTransfer, not transfer: these are third-party equity and memecoin
            // tokens and a non-standard one that returns false instead of
            // reverting would otherwise be logged as a silent success.
            IERC20(tokens[i]).safeTransfer(safe, gained);
            console.log("  %s  %s", tokens[i], gained);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Steps 1 and 2 done. The deployer keeps everything it already held.");
        console.log("Step 3, repointing recipients, is onlyOwner and must be signed by the Safe.");
        console.log("");
        console.log("No BrandFeeVault change is needed. Every live vault has protocolBps 0");
        console.log("with no setter, so LPs take 100% of float yield and the vault's");
        console.log("immutable protocolTreasury can never pay anyone. Set the treasury for");
        console.log("FUTURE markets with AssetMarketFactory.setProtocolParams instead.");
    }

    /// @dev The curve address lives in the launch record. Read through a minimal ABI rather
    ///      than importing LaunchFactory, whose struct has changed shape across upgrades.
    function _curveOf(address token) internal view returns (address curve) {
        (bool ok, bytes memory ret) =
            LAUNCH_FACTORY.staticcall(abi.encodeWithSignature("getLaunchedToken(address)", token));
        if (!ok || ret.length < 64) return address(0);
        assembly {
            curve := mload(add(ret, 64))
        }
    }

    // ─── Discovery ───────────────────────────────────────────────────────

    function _collectTokens(uint256 count) internal {
        _add(USDG);
        for (uint256 id = 1; id <= count; ++id) {
            AssetMarketFactory.Market memory m = factory.market(id);
            if (m.brandToken == address(0)) continue;
            _add(m.asset);
            _add(m.brandToken);
        }
    }

    function _add(address token) internal {
        if (token == address(0) || seen[token]) return;
        seen[token] = true;
        tokens.push(token);
    }

    // ─── The three claims ────────────────────────────────────────────────

    function _collectHookFees(uint256 count) internal {
        console.log("=== Hook trading fees ===");
        for (uint256 id = 1; id <= count; ++id) {
            AssetMarketFactory.Market memory m = factory.market(id);
            if (m.brandToken == address(0)) continue;

            PoolKey memory key = factory.poolKeyOf(id);
            // Checked before calling, never with try/catch. Under `--broadcast` forge RECORDS
            // each call made inside a broadcast and replays it against the chain, so a call
            // that reverted harmlessly inside a catch still gets submitted and fails the run.
            // The guard has to keep the reverting call from happening at all.
            if (hook.feeRecipientOf(key.toId()) == address(0)) continue;
            uint256 owed0 = hook.pendingFees(key.toId(), key.currency0);
            uint256 owed1 = hook.pendingFees(key.toId(), key.currency1);
            if (owed0 == 0 && owed1 == 0) continue;

            hook.collect(key);
            console.log("  market %s: %s / %s", id, owed0, owed1);
        }
    }

    /// @dev Bonding-curve fees sit inside each curve until someone sweeps them, and a sweep
    ///      credits the escrow rather than paying out directly.
    ///
    ///      Each curve SNAPSHOTS its own `protocolFeeRecipient` at launch and there is no
    ///      setter for it, so repointing `LaunchFactory` moves the recipient for FUTURE
    ///      launches only. Every curve that exists today names the deployer, which is exactly
    ///      why this has to happen while that key is still in use: sweep, claim, forward.
    ///
    ///      The creator's share is credited to the creator's own escrow balance and is
    ///      `msg.sender`-scoped, so sweeping cannot take anyone else's money. It only makes
    ///      each party's share claimable by that party.
    function _sweepCurves() internal {
        console.log("=== Bonding-curve fees ===");
        ILaunchFactory launches = ILaunchFactory(LAUNCH_FACTORY);
        uint256 n = launches.launchCount();
        for (uint256 i; i < n; ++i) {
            address token = launches.launchAt(i);
            ILaunchCurve curve = ILaunchCurve(_curveOf(token));
            if (address(curve) == address(0)) continue;

            // Guarded, never try/catch: under `--broadcast` forge records every call made
            // inside a broadcast and replays it, so a reverting call would fail the run.
            if (curve.graduated()) continue;
            uint256 pending = curve.quoteFeeBalance();
            uint256 tax = curve.creatorTaxBalance();
            if (pending == 0 && tax == 0) continue;

            curve.sweepFees();
            console.log("  curve %s: swept %s (+%s creator tax)", address(curve), pending, tax);
        }
    }

    function _claimEscrow(address deployer) internal {
        console.log("=== Launchpad escrow (msg.sender-scoped, cannot be repointed) ===");
        for (uint256 i; i < tokens.length; ++i) {
            uint256 owed = ILaunchFeeEscrow(ESCROW).balanceOfToken(deployer, tokens[i]);
            if (owed == 0) continue;
            ILaunchFeeEscrow(ESCROW).claimToken(tokens[i]);
            console.log("  %s  %s", tokens[i], owed);
        }
    }
}
