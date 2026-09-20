// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ProtocolStack} from "../src/upgrade/ProtocolStack.sol";

/// @title LaunchpadDefaults
/// @notice The launchpad's shipped economics, in one place, applied the same way from the
///         standalone script and from the full-stack deploy.
///
///         **Why these are constants and not script-local literals.** Every figure here is
///         snapshotted into each curve at launch and into each launch record, so a deployment
///         that applies a different number does not merely configure the launchpad
///         differently — it produces launches whose terms cannot be brought back into line
///         later. Two scripts stand this layer up; one copy of the numbers keeps them from
///         drifting apart. See `docs/LAUNCHPAD_PLAN.md` section 10.
///
///         `LaunchFactory.initialize` already writes the four policy defaults below. They are
///         written again here on purpose: the deployment, not the implementation's
///         initialiser, is what these launches are governed by, and a factory upgrade that
///         changes an initialiser default must not silently change what a re-run configures.
library LaunchpadDefaults {
    /// @notice Whole tokens minted per launch, all of them to the curve.
    uint256 internal constant LAUNCH_SUPPLY = 1e27;

    /// @notice The curve's trade fee, split protocol/creator by `PROTOCOL_FEE_SHARE_BPS`.
    uint256 internal constant CURVE_FEE_BPS = 100; // 1%

    /// @notice LP tier a graduated launch's pool opens at — the market stack's 0.50%, which
    ///         pairs with the hook's 0.50% skim to make the 1% headline fee.
    uint24 internal constant POOL_FEE = 5_000;

    /// @notice The protocol's share of the curve fee. With `LP_FUND_SHARE_BPS` also at 3,000
    ///         the creator takes the 4,000 remainder, so a 1% curve fee lands 0.40% creator,
    ///         0.30% protocol, 0.30% LP fund.
    uint16 internal constant PROTOCOL_FEE_SHARE_BPS = 3_000;

    /// @notice The LP fund's share of the curve fee, and of both post-graduation legs. One
    ///         figure serves all three because the fund's claim on a launch is a single
    ///         policy rather than three that have to be moved together.
    uint16 internal constant LP_FUND_SHARE_BPS = 3_000;

    /// @notice Ceiling on the extra trade tax a creator may charge, checked at launch time.
    uint16 internal constant MAX_CREATOR_TAX_BPS = 1_000;

    /// @notice The launch-second tax and the window it decays to zero over, which is what
    ///         makes a first-block snipe unprofitable without closing the launch to anyone.
    uint256 internal constant SNIPE_TAX_START_BPS = 9_900;
    uint256 internal constant SNIPE_TAX_SECONDS = 15;

    /// @notice The creator's share of the LP FEES a graduated launch's locked position earns,
    ///         and of the FLOAT YIELD it earns. 40% of each, with the LP fund taking 30% and
    ///         the protocol keeping the 30% remainder.
    ///
    ///         The two are separate knobs despite carrying the same number today, because
    ///         they are different promises: the fee share is snapshotted into each launch and
    ///         is a term the creator is sold, while the yield share is read live because the
    ///         yield is what the reserve's collateral earns rather than what the launch
    ///         earns. Setting them equal is a policy choice, not a simplification.
    uint16 internal constant GRADUATED_CREATOR_SHARE_BPS = 4_000;
    uint16 internal constant GRADUATED_CREATOR_YIELD_SHARE_BPS = 4_000;

    // The quote-side economics, in the brand's own units. Sized for a 6-decimal brand: a
    // 3,236 phantom reserve against an 8,090 threshold puts 71.4% of supply into the
    // graduated pool and keeps the rest locked.
    uint256 internal constant PHANTOM_QUOTE = 3_236e6;
    uint256 internal constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 internal constant LAUNCH_FEE = 1e6;
    uint8 internal constant QUOTE_DECIMALS = 6;

    /// @notice Applies the policy every launch is created under, and adds the one launch
    ///         config the product ships with. Caller must be the factory's owner.
    /// @dev    Launching is NOT enabled here. A launchpad with a config but no approved quote
    ///         brand reverts on every launch, so the flag is flipped by the caller once the
    ///         brand it is meant to trade against exists.
    /// @param lpFundRecipient Where the LP fund's share accrues. Passed rather than defaulted
    ///        so a deployment cannot silently route it to the protocol treasury; the escrow
    ///        credits it as an ordinary claimable balance, so repointing later strands nothing.
    function applyPolicy(
        LaunchFactory factory,
        address protocolFeeRecipient,
        address lpFundRecipient
    ) internal returns (uint256 launchConfigId) {
        factory.setProtocolFeeRecipient(protocolFeeRecipient);
        // The recipient before the shares, in both places: every share setter refuses a
        // nonzero rate while the recipient is unset.
        factory.setLpFundRecipient(lpFundRecipient);
        factory.setProtocolFeeShareBps(PROTOCOL_FEE_SHARE_BPS);
        factory.setLpFundShareBps(LP_FUND_SHARE_BPS);
        factory.setMaxCreatorTaxBps(MAX_CREATOR_TAX_BPS);
        factory.setSnipeTax(SNIPE_TAX_START_BPS, SNIPE_TAX_SECONDS);
        factory.setGraduatedCreatorShareBps(GRADUATED_CREATOR_SHARE_BPS);
        factory.setGraduatedCreatorYieldShareBps(GRADUATED_CREATOR_YIELD_SHARE_BPS);
        factory.setGraduatedLpFundShareBps(LP_FUND_SHARE_BPS);

        launchConfigId = factory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: LAUNCH_SUPPLY, curveFeeBps: CURVE_FEE_BPS, poolFee: POOL_FEE, enabled: true
            })
        );
    }

    /// @notice Writes a quote brand's economics and then opens it for launches.
    /// @dev    Two calls rather than one `approved: true` write: `setPairTokenEconomics` is
    ///         where every validation lives (brand registered in the reserve, reserve known to
    ///         the market factory, decimals matching the token's own), and `setPairTokenApproved`
    ///         is the switch. Written that way, the figures exist and are readable before
    ///         anything may launch against them, and closing the brand later does not require
    ///         re-supplying them.
    function approveQuoteBrand(
        LaunchFactory factory,
        address brand,
        address reserve,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint256 launchFee,
        uint8 decimals
    ) internal {
        factory.setPairTokenEconomics(
            brand,
            LaunchFactory.PairTokenEconomics({
                reserve: reserve,
                phantomQuote: phantomQuote,
                graduationThreshold: graduationThreshold,
                launchFee: launchFee,
                decimals: decimals,
                approved: false
            })
        );
        factory.setPairTokenApproved(brand, true);
    }
}

/// @title DeployLaunchpad
/// @notice Stands the launchpad up on top of a market stack that is already deployed, and
///         configures it to the terms in `docs/LAUNCHPAD_PLAN.md` section 10.
///
///         **Everything structural is read off the market factory, not off this file.** The
///         launchpad has to agree with the market stack about three addresses — the v4
///         singleton, Uniswap's `PositionManager` and the pause guard — and each of them is
///         already recorded in the deployed `AssetMarketFactory`. So the factory address is
///         the one thing this script cannot derive, and the rest is checked against it:
///         `POSITION_MANAGER` and `PROTOCOL_GUARD` may be supplied, and are then required to
///         match what the factory says rather than being trusted. A wrong-chain or
///         wrong-address run therefore fails on the first read instead of producing a
///         launchpad that graduates into pools nothing else can see. That is also why there is
///         no chain-id guard here: the same script runs on testnet (46630) and on Base
///         Sepolia, and the factory it is pointed at is what pins the venue.
///
///         **What the deploying key must own.** It becomes the launch factory's and the
///         locker's owner, and it performs their one-shot wiring (`setLaunchDeployer`,
///         `setGraduation`, `setLaunchForwarder`) inside `ProtocolStack.deployLaunchpad` — see
///         the note there on why `owner` must be the sender. It must ALSO own the market
///         factory to register the graduation module with `setLaunchpad`, which is the one
///         call that cannot be made from the launchpad side. If it does not, everything else
///         is still deployed and configured and the exact `setLaunchpad` command the owner has
///         to send is printed; until that call lands, phase two of every graduation reverts
///         `OnlyLaunchpad` and the launch stays in `Swept`, retryable.
///
///         Usage:
///         ASSET_MARKET_FACTORY=0x... SHARED_RESERVE_POOL=0x... PROTOCOL_GUARD=0x... forge script script/DeployLaunchpad.s.sol --rpc-url robinhood --broadcast --slow
///
///         Environment variables:
///         - PRIVATE_KEY          deployer key (required)
///         - ASSET_MARKET_FACTORY the deployed AssetMarketFactory proxy (required)
///         - SHARED_RESERVE_POOL  the reserve the quote brand belongs to (required); must be
///                                the factory's default reserve or an approvedReservePool
///         - PROTOCOL_GUARD       the pause registry (required); must be the factory's
///         - POSITION_MANAGER     Uniswap v4 PositionManager (defaults to the factory's; when
///                                supplied it must equal the factory's)
///         - PERMIT2              canonical Permit2 (defaults to the canonical address)
///         - LAUNCH_PROTOCOL_FEE_RECIPIENT
///                                where launch fees and the protocol's share of curve fees are
///                                credited (defaults to the factory's protocolTreasury)
///         - LAUNCH_LP_FUND_RECIPIENT
///                                where the LP fund's 30% of launchpad revenue accrues. It
///                                defaults to LAUNCH_PROTOCOL_FEE_RECIPIENT, which parks the
///                                fund's share with the protocol rather than losing it, and
///                                the escrow holds it as an ordinary claimable balance so
///                                `setLpFundRecipient` can redirect it later with nothing
///                                stranded. Set it explicitly once the fund has an address.
///         - LAUNCH_QUOTE_BRAND   a brand registered in SHARED_RESERVE_POOL to open launches
///                                against (optional; without it no brand is approved and
///                                launching is left disabled)
///         - LAUNCH_PHANTOM_QUOTE, LAUNCH_GRADUATION_THRESHOLD, LAUNCH_FEE
///                                override the shipped quote economics, in the brand's own
///                                units (required together if the brand is not 6-decimal)
///         - REPLACE_LAUNCHPAD    set true to point a market factory that already has a
///                                launchpad at this new one (refused by default)
contract DeployLaunchpad is Script {
    /// @dev Everything the run needs, resolved and checked before a single contract is
    ///      deployed. Grouped because Solidity's stack cannot hold this many locals under
    ///      `via_ir` in one frame, and because the checks read better as one pass.
    struct Env {
        uint256 deployerKey;
        address deployer;
        AssetMarketFactory marketFactory;
        SharedReservePool reservePool;
        address guard;
        IPositionManagerV4 positionManager;
        IPermit2 permit2;
        address protocolFeeRecipient;
        address lpFundRecipient;
        address quoteBrand;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint256 launchFee;
        uint8 quoteDecimals;
        bool replaceLaunchpad;
    }

    function run() external returns (ProtocolStack.Launchpad memory lp) {
        Env memory e = _readEnv();
        _checkEnv(e);

        console.log("=== Deploying the launchpad ===");
        console.log("Deployer:", e.deployer);
        console.log("Deployer balance (wei):", e.deployer.balance);
        console.log("Chain ID:", block.chainid);
        console.log("AssetMarketFactory:", address(e.marketFactory));
        console.log("SharedReservePool:", address(e.reservePool));
        console.log("ProtocolGuard:", e.guard);
        console.log(
            "PoolManager (from the market factory):", address(e.marketFactory.poolManager())
        );
        console.log("v4 PositionManager:", address(e.positionManager));
        console.log("Permit2:", address(e.permit2));
        console.log("Protocol fee recipient:", e.protocolFeeRecipient);
        console.log("LP fund recipient:", e.lpFundRecipient);
        console.log("");

        vm.startBroadcast(e.deployerKey);

        lp = ProtocolStack.deployLaunchpad(
            e.deployer, e.guard, e.marketFactory, e.positionManager, e.permit2
        );
        console.log("LaunchFeeEscrow:", address(lp.feeEscrow));
        console.log("LaunchFactory implementation:", lp.factoryImplementation);
        console.log("LaunchFactory (proxy):", address(lp.factory));
        console.log("LaunchGraduationGuard:", address(lp.graduationGuard));
        console.log("LaunchLocker:", address(lp.locker));
        console.log("LaunchDeployer:", address(lp.launchDeployer));
        console.log("LaunchGraduation:", address(lp.graduation));
        console.log("LaunchRouter:", address(lp.router));

        uint256 launchConfigId =
            LaunchpadDefaults.applyPolicy(lp.factory, e.protocolFeeRecipient, e.lpFundRecipient);
        console.log("Launch config id:", launchConfigId);

        if (e.quoteBrand != address(0)) {
            LaunchpadDefaults.approveQuoteBrand(
                lp.factory,
                e.quoteBrand,
                address(e.reservePool),
                e.phantomQuote,
                e.graduationThreshold,
                e.launchFee,
                e.quoteDecimals
            );
            lp.factory.setLaunchEnabled(true);
        }

        // The one link that lives on the market factory. Without it `graduateToMarket` reverts
        // `OnlyLaunchpad` — the launch still sweeps, so nothing is stranded, but no launch can
        // reach a market until this lands.
        bool launchpadRegistered = e.marketFactory.owner() == e.deployer;
        if (launchpadRegistered) e.marketFactory.setLaunchpad(address(lp.graduation));

        vm.stopBroadcast();

        _assertWiring(lp, e, launchConfigId, launchpadRegistered);

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("RECORD THESE IN THE DEPLOYMENT MANIFEST, UNDER `launchpad`:");
        console.log("  feeEscrow:", address(lp.feeEscrow));
        console.log("  factoryImplementation:", lp.factoryImplementation);
        console.log("  factory:", address(lp.factory));
        console.log("  graduationGuard:", address(lp.graduationGuard));
        console.log("  locker:", address(lp.locker));
        console.log("  deployer:", address(lp.launchDeployer));
        console.log("  graduation:", address(lp.graduation));
        console.log("  router:", address(lp.router));
        console.log("  launchConfigId:", launchConfigId);
        console.log("  quoteBrand:", e.quoteBrand);
        console.log("");
        console.log("LaunchFactory runtime size (bytes):", address(lp.factory).code.length);
        console.log("Curve fee (bps):", LaunchpadDefaults.CURVE_FEE_BPS);
        console.log(
            "    of which the protocol keeps (bps):", LaunchpadDefaults.PROTOCOL_FEE_SHARE_BPS
        );
        console.log("Max creator tax (bps):", LaunchpadDefaults.MAX_CREATOR_TAX_BPS);
        console.log("Snipe tax (bps, decaying over s):", LaunchpadDefaults.SNIPE_TAX_START_BPS);
        console.log("    window (s):", LaunchpadDefaults.SNIPE_TAX_SECONDS);
        console.log("Creator share of locked-position LP fees (bps):");
        console.log("   ", LaunchpadDefaults.GRADUATED_CREATOR_SHARE_BPS);
        console.log("Creator share of locked-position float yield (bps):");
        console.log("   ", LaunchpadDefaults.GRADUATED_CREATOR_YIELD_SHARE_BPS);
        console.log("Launch supply (whole tokens x 1e18):", LaunchpadDefaults.LAUNCH_SUPPLY);
        console.log("Graduated pool LP tier:", LaunchpadDefaults.POOL_FEE);
        console.log("");

        if (!launchpadRegistered) {
            console.log("############################################################");
            console.log("## THE MARKET FACTORY IS NOT OWNED BY THE DEPLOYING KEY.  ##");
            console.log("## Nothing can graduate until its owner sends:            ##");
            console.log("############################################################");
            console.log(
                "    cast send <assetMarketFactory> 'setLaunchpad(address)' <launchGraduation>"
            );
            console.log("");
        }

        if (e.quoteBrand == address(0)) {
            console.log("No LAUNCH_QUOTE_BRAND was supplied, so no brand is approved and");
            console.log("launching is still DISABLED. Register the brand on the reserve, then:");
            console.log(
                "    cast send <launchFactory> 'setPairTokenEconomics(address,(address,uint256,uint256,uint256,uint8,bool))' <brand> '(<reserve>,3236000000,8090000000,1000000,6,false)'"
            );
            console.log(
                "    cast send <launchFactory> 'setPairTokenApproved(address,bool)' <brand> true"
            );
            console.log("    cast send <launchFactory> 'setLaunchEnabled(bool)' true");
            console.log("");
        }

        console.log("--- Launching a token ---");
        console.log("Permissionless. The launch fee is pulled from the caller in the quote");
        console.log("brand, last, so a launch that reverts never takes one. Approve it first.");
        console.log("Pin the terms you were quoted with expectedEconomics, or pass 0 to waive:");
        console.log(
            "    cast call <launchFactory> 'previewLaunchEconomics(uint256,address)(bytes32)' <configId> <brand>"
        );
        console.log(
            "    cast send <launchFactory> 'launchToken((string,string,string,string,(string,string,string,string,string),address,uint16,bytes32,bytes32),uint256,address,address[])' ..."
        );
        console.log("One call does the same with a first buy attached, so the launcher is not");
        console.log("sniped by the block they launched in:");
        console.log("    cast send <launchRouter> 'launchAndBuy(...)' ...");
        console.log("");
        console.log("Trade on the curve (quoteIn is in the brand; approve the curve first):");
        console.log(
            "    cast send <curve> 'buy(uint256,uint256,address)' <quoteIn> <minTokensOut> <recipient>"
        );
        console.log(
            "    cast send <curve> 'sell(uint256,uint256,address)' <tokensIn> <minQuoteOut> <recipient>"
        );
        console.log("");
        console.log("Graduation is permissionless and two-phase. Phase one is attempted inside");
        console.log("the buy that crosses the threshold; both are retryable by anyone:");
        console.log("    cast send <launchFactory> 'graduate(address)' <token>");
        console.log("    cast send <launchFactory> 'graduateToMarket(address)' <token>");
        console.log("");
        console.log("Revenue is a pull ledger, before and after graduation. The locked");
        console.log("position's income is collected permissionlessly and split creator/protocol:");
        console.log("    cast send <curve> 'sweepFees()'");
        console.log("    cast send <launchLocker> 'collect(address)' <token>");
        console.log("    cast send <launchFeeEscrow> 'claimToken(address)' <token>");

        return lp;
    }

    /// @dev Reads every input, defaulting the three that the market factory can answer for
    ///      itself. `vm.envAddress` reverts on an unset variable, which is the behaviour these
    ///      three want: a launchpad wired to a guessed market factory is worse than no
    ///      launchpad.
    function _readEnv() private view returns (Env memory e) {
        e.deployerKey = vm.envUint("PRIVATE_KEY");
        e.deployer = vm.addr(e.deployerKey);

        e.marketFactory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));
        e.reservePool = SharedReservePool(vm.envAddress("SHARED_RESERVE_POOL"));
        e.guard = vm.envAddress("PROTOCOL_GUARD");
        require(address(e.marketFactory).code.length > 0, "ASSET_MARKET_FACTORY has no code");
        require(address(e.reservePool).code.length > 0, "SHARED_RESERVE_POOL has no code");
        require(e.guard.code.length > 0, "PROTOCOL_GUARD has no code");

        // Supplying these is optional; supplying them WRONG is not. Defaulting to the market
        // factory's own record is what makes a mismatch a failed require rather than a
        // launchpad that mints positions the market's distributors refuse to stake.
        address factoryPosm = address(e.marketFactory.positionManager());
        e.positionManager = IPositionManagerV4(vm.envOr("POSITION_MANAGER", factoryPosm));
        require(
            address(e.positionManager) == factoryPosm,
            "POSITION_MANAGER is not the market factory's"
        );
        e.permit2 = IPermit2(vm.envOr("PERMIT2", MainnetAddresses.PERMIT2));

        e.protocolFeeRecipient =
            vm.envOr("LAUNCH_PROTOCOL_FEE_RECIPIENT", e.marketFactory.protocolTreasury());
        e.lpFundRecipient = vm.envOr("LAUNCH_LP_FUND_RECIPIENT", e.protocolFeeRecipient);
        e.replaceLaunchpad = vm.envOr("REPLACE_LAUNCHPAD", false);

        e.quoteBrand = vm.envOr("LAUNCH_QUOTE_BRAND", address(0));
        if (e.quoteBrand == address(0)) return e;

        e.quoteDecimals = IERC20Metadata(e.quoteBrand).decimals();
        e.phantomQuote = vm.envOr("LAUNCH_PHANTOM_QUOTE", LaunchpadDefaults.PHANTOM_QUOTE);
        e.graduationThreshold =
            vm.envOr("LAUNCH_GRADUATION_THRESHOLD", LaunchpadDefaults.GRADUATION_THRESHOLD);
        e.launchFee = vm.envOr("LAUNCH_FEE", LaunchpadDefaults.LAUNCH_FEE);
    }

    /// @dev Everything that would otherwise surface as a broken launch rather than a failed
    ///      deployment. The venue checks duplicate what `LaunchFactory.initialize` and
    ///      `LaunchGraduation`'s constructor assert, on purpose: failing before the first
    ///      contract creation costs nothing, and a half-deployed launchpad cannot be re-wired.
    function _checkEnv(Env memory e) internal view {
        require(address(e.marketFactory.guard()) == e.guard, "PROTOCOL_GUARD is not the factory's");
        require(
            e.positionManager.poolManager() == address(e.marketFactory.poolManager()),
            "PositionManager answers to a different PoolManager"
        );
        require(address(e.permit2).code.length > 0, "PERMIT2 has no code");
        require(e.protocolFeeRecipient != address(0), "protocol fee recipient is zero");
        require(e.lpFundRecipient != address(0), "LP fund recipient is zero");

        // The reserve a graduation swaps the curve's float into. It must be one the market
        // factory registers units in, or the brand the curve holds has no 1:1 path to the
        // market's unit and every graduation reverts.
        require(
            address(e.reservePool) == address(e.marketFactory.reservePool())
                || e.marketFactory.approvedReservePool(address(e.reservePool)),
            "SHARED_RESERVE_POOL is not the factory's default nor approved"
        );

        address existing = e.marketFactory.launchpad();
        require(
            existing == address(0) || e.replaceLaunchpad,
            "market factory already has a launchpad; set REPLACE_LAUNCHPAD=true to move it"
        );

        if (e.quoteBrand == address(0)) return;
        require(
            e.reservePool.isRegistered(e.quoteBrand),
            "LAUNCH_QUOTE_BRAND is not registered in SHARED_RESERVE_POOL"
        );
        // The shipped phantom/threshold pair is denominated in 6 decimals. Applied unscaled to
        // a coarser or finer brand it misprices the curve by orders of magnitude, so a brand
        // that is not 6-decimal has to say what its figures are.
        require(
            e.quoteDecimals == LaunchpadDefaults.QUOTE_DECIMALS
                || (e.phantomQuote != LaunchpadDefaults.PHANTOM_QUOTE
                    && e.graduationThreshold != LaunchpadDefaults.GRADUATION_THRESHOLD),
            "brand is not 6-decimal: pass LAUNCH_PHANTOM_QUOTE and LAUNCH_GRADUATION_THRESHOLD"
        );
    }

    /// @dev Read back from the deployed contracts, not from the values passed in. Every one of
    ///      these is a state the deployment can reach and still look finished — and each of the
    ///      one-shots is unrepeatable, so the check has to happen while the run is still the
    ///      thing that can be re-done.
    function _assertWiring(
        ProtocolStack.Launchpad memory lp,
        Env memory e,
        uint256 launchConfigId,
        bool launchpadRegistered
    ) private view {
        require(lp.factory.owner() == e.deployer, "launch factory owner is not the deployer");
        require(
            address(lp.factory.marketFactory()) == address(e.marketFactory),
            "launch factory market factory mismatch"
        );
        require(
            address(lp.factory.feeEscrow()) == address(lp.feeEscrow),
            "launch factory escrow mismatch"
        );
        require(
            address(lp.factory.positionManager()) == address(e.positionManager),
            "launch factory PositionManager mismatch"
        );
        require(address(lp.factory.guard()) == e.guard, "launch factory guard mismatch");

        require(
            address(lp.factory.launchDeployer()) == address(lp.launchDeployer),
            "launch deployer not wired"
        );
        require(address(lp.factory.graduation()) == address(lp.graduation), "graduation not wired");
        require(
            lp.factory.launchForwarder() == address(lp.router), "launch forwarder is not the router"
        );
        require(lp.locker.graduation() == address(lp.graduation), "locker graduation not wired");
        require(lp.locker.factory() == address(lp.factory), "locker factory mismatch");
        require(lp.locker.owner() == e.deployer, "locker owner is not the deployer");
        require(lp.launchDeployer.factory() == address(lp.factory), "deployer factory mismatch");
        require(lp.graduation.factory() == address(lp.factory), "graduation factory mismatch");
        require(address(lp.graduation.locker()) == address(lp.locker), "graduation locker mismatch");
        require(
            address(lp.graduation.feeEscrow()) == address(lp.feeEscrow),
            "graduation escrow mismatch"
        );
        require(
            address(lp.graduation.marketFactory()) == address(e.marketFactory),
            "graduation market factory mismatch"
        );
        require(address(lp.router.factory()) == address(lp.factory), "router factory mismatch");

        require(
            lp.factory.protocolFeeRecipient() == e.protocolFeeRecipient,
            "protocol fee recipient not applied"
        );
        require(
            lp.factory.protocolFeeShareBps() == LaunchpadDefaults.PROTOCOL_FEE_SHARE_BPS,
            "protocol fee share not applied"
        );
        require(lp.factory.lpFundRecipient() == e.lpFundRecipient, "LP fund recipient not applied");
        require(
            lp.factory.lpFundShareBps() == LaunchpadDefaults.LP_FUND_SHARE_BPS,
            "LP fund share of the curve fee not applied"
        );
        require(
            lp.factory.graduatedLpFundShareBps() == LaunchpadDefaults.LP_FUND_SHARE_BPS,
            "LP fund share of the graduated legs not applied"
        );
        // The split has to add up, or the curve's own guard would reject every launch.
        require(
            uint256(LaunchpadDefaults.PROTOCOL_FEE_SHARE_BPS) + LaunchpadDefaults.LP_FUND_SHARE_BPS
                <= 10_000,
            "curve fee split exceeds the whole fee"
        );
        require(
            lp.factory.maxCreatorTaxBps() == LaunchpadDefaults.MAX_CREATOR_TAX_BPS,
            "max creator tax not applied"
        );
        require(
            lp.factory.snipeTaxStartBps() == LaunchpadDefaults.SNIPE_TAX_START_BPS
                && lp.factory.snipeTaxSeconds() == LaunchpadDefaults.SNIPE_TAX_SECONDS,
            "snipe tax not applied"
        );
        require(
            lp.factory.graduatedCreatorShareBps() == LaunchpadDefaults.GRADUATED_CREATOR_SHARE_BPS,
            "graduated creator fee share not applied"
        );
        require(
            lp.factory.graduatedCreatorYieldShareBps()
                == LaunchpadDefaults.GRADUATED_CREATOR_YIELD_SHARE_BPS,
            "graduated creator yield share not applied"
        );

        LaunchFactory.LaunchConfig memory config = lp.factory.getLaunchConfig(launchConfigId);
        require(config.supply == LaunchpadDefaults.LAUNCH_SUPPLY, "launch supply mismatch");
        require(config.curveFeeBps == LaunchpadDefaults.CURVE_FEE_BPS, "curve fee mismatch");
        require(config.poolFee == LaunchpadDefaults.POOL_FEE, "pool fee mismatch");
        require(config.enabled, "launch config is disabled");

        if (e.quoteBrand != address(0)) {
            (address reserve, uint256 phantom, uint256 threshold, uint256 fee, uint8 dec, bool ok) =
                lp.factory.pairTokenEconomics(e.quoteBrand);
            require(reserve == address(e.reservePool), "brand reserve mismatch");
            require(phantom == e.phantomQuote, "brand phantom quote mismatch");
            require(threshold == e.graduationThreshold, "brand threshold mismatch");
            require(fee == e.launchFee, "brand launch fee mismatch");
            require(dec == e.quoteDecimals, "brand decimals mismatch");
            require(ok, "brand is not approved");
            require(lp.factory.launchEnabled(), "launching is not enabled");
        } else {
            require(!lp.factory.launchEnabled(), "launching enabled with no approved brand");
        }

        if (launchpadRegistered) {
            require(
                e.marketFactory.launchpad() == address(lp.graduation),
                "market factory launchpad mismatch"
            );
        }

        console.log("");
        console.log("Wiring assertions: PASSED");
    }
}
