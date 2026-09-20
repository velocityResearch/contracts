// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/governance/TimelockController.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {MarketDeployer} from "../src/markets/MarketDeployer.sol";
import {MarketRouter} from "../src/markets/MarketRouter.sol";
import {BrandFeeVault} from "../src/markets/BrandFeeVault.sol";
import {ProtocolFeeHook} from "../src/markets/ProtocolFeeHook.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title VerifyAssetMarketsMainnet
/// @notice Read-only. Broadcasts nothing and needs no key.
///
///         Reads a deployed mainnet stack back out of the chain and asserts it is wired the way
///         the two deploy scripts intended. This exists because the deploy scripts assert their
///         own work in the same process that did it — a useful check, but not an independent
///         one, and useless days later when the question is whether anything has since changed.
///         Run this against the recorded addresses before pointing a frontend at them, and
///         again whenever the stack is supposed to have been left alone.
///
///         It also reports the two governance blockers from ASSET_MARKETS.md §11 as a verdict
///         rather than a warning, because by the time this runs they are facts about a live
///         deployment rather than choices still being made.
///
///         Usage:
///         SHARED_RESERVE_POOL=0x... ASSET_MARKET_FACTORY=0x... MARKET_ROUTER=0x... \
///           forge script script/VerifyAssetMarketsMainnet.s.sol --rpc-url robinhood
///
///         Optional:
///         - EXPECT_MIN_DELAY  fail unless the pool's timelock delay is at least this many
///                             seconds. Unset means report the delay without judging it.
///
///         It also checks two things that would have CAUGHT the drift of 2026-09-19, when
///         three mainnet implementations were replaced with no script and no broadcast
///         artifact: the live `MAX_FEE_PIPS` against what this repo compiles, and every
///         proxy's implementation against what the deployment manifest records. Both are
///         reported as BLOCKER verdicts rather than reverts, for the same reason the
///         governance posture is - a verifier that dies on the first mismatch hides the rest
///         of the drift, and drift is exactly the thing you want reported in full.
contract VerifyAssetMarketsMainnet is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev ERC-1967's implementation slot, the one UUPS writes. Read with `vm.load` rather
    ///      than through a getter because a proxy does not have to expose one.
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev What `src/markets/ProtocolFeeHook.sol:120` compiles to today, mirrored by hand.
    ///      Solidity cannot read a contract-level `constant` off the type, and this whole call
    ///      tree is `view`, so it cannot deploy an implementation and ask one either.
    ///      `script/UpgradeProtocolFeeCapMainnet.s.sol` does exactly that and is therefore the
    ///      source-derived authority; keep this number equal to it. The mirror earns its keep
    ///      anyway: a live ceiling that disagrees with it means either the chain carries an
    ///      implementation nobody committed, or `src/` carries a tightening nobody shipped,
    ///      and the first of those went unnoticed for as long as nothing compared the two.
    uint24 constant EXPECTED_MAX_FEE_PIPS = 10_000;

    function run() external view {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        SharedReservePool pool = SharedReservePool(vm.envAddress("SHARED_RESERVE_POOL"));
        AssetMarketFactory factory = AssetMarketFactory(vm.envAddress("ASSET_MARKET_FACTORY"));
        MarketRouter router = MarketRouter(vm.envAddress("MARKET_ROUTER"));

        console.log("=== Verifying the AssetMarkets mainnet stack ===");
        console.log("Chain ID:", block.chainid);
        console.log("");

        _verifyReserve(pool);
        _verifyFactory(factory, pool);
        _verifyRouter(router, factory, pool);
        _verifyMarkets(factory);
        _verifyFeeCeiling(factory);
        _verifyRecordedImplementations(pool, factory, router);

        console.log("");
        console.log("=== Verification PASSED ===");
    }

    function _verifyReserve(SharedReservePool pool) private view {
        require(address(pool).code.length > 0, "reserve pool has no code");
        require(address(pool.asset()) == MainnetAddresses.USDG, "reserve asset is not USDG");
        require(pool.assetDecimals() == MainnetAddresses.USDG_DECIMALS, "reserve decimals mismatch");

        address yieldSourceAddr = address(pool.yieldSource());
        require(yieldSourceAddr != address(0), "reserve has no yield source");
        require(yieldSourceAddr.code.length > 0, "reserve yield source has no code");

        console.log("SharedReservePool:", address(pool));
        console.log("    asset:", address(pool.asset()));
        console.log("    total assets:", pool.totalAssets());
        console.log("    total pooled supply:", pool.totalPooledSupply());
        console.log("    loss carryforward:", pool.lossCarryforward());
        console.log("    yield source:", yieldSourceAddr);

        // The Phase 0 adapter blocker. The pre-fix build has no `sharesOf`, so a successful
        // call is itself the evidence that this is the post-fix adapter. A staticcall is used
        // rather than a typed call so the failure is a readable verdict, not a decode revert.
        (bool ok,) =
            yieldSourceAddr.staticcall(abi.encodeWithSignature("sharesOf(address)", address(pool)));
        require(ok, "yield source has no sharesOf(): this is the PRE-FIX adapter, unsafe to use");
        MorphoBlueYieldSource adapter = MorphoBlueYieldSource(yieldSourceAddr);
        require(adapter.loanToken() == MainnetAddresses.USDG, "adapter loan token is not USDG");
        require(
            address(adapter.morphoBlue()) == MainnetAddresses.MORPHO_BLUE,
            "adapter points at the wrong Morpho"
        );
        require(adapter.marketId() == MainnetAddresses.USDE_MARKET_ID, "adapter market id mismatch");
        console.log("    adapter has per-consumer sharesOf(): POST-FIX build");
        console.log("    adapter shares held for this pool:", adapter.sharesOf(address(pool)));

        // Governance posture, reported as a verdict. Both shapes are legitimate deployments:
        // `DeploySharedReservePool` builds a timelock when `TIMELOCK_MIN_DELAY > 0` and hands
        // the EOA every owner slot when it is zero. Reverting on the second made this script
        // unable to verify a stack its own sibling had just produced, which is the worst
        // failure mode for a verifier — it says "broken" where the truthful answer is
        // "deliberately unprotected". Report it at full volume and keep checking everything
        // else, and let EXPECT_MIN_DELAY be the knob that turns the posture into a hard gate.
        address owner = Ownable(address(pool)).owner();
        console.log("    owner:", owner);

        uint256 delay;
        bool ownedByTimelock = owner.code.length > 0;
        if (ownedByTimelock) {
            delay = TimelockController(payable(owner)).getMinDelay();
            console.log("    timelock delay (s):", delay);
            if (delay == 0) {
                console.log("    ## BLOCKER: delay is ZERO. The timelock is decoration and a  ##");
                console.log("    ## leaked key redirects the whole reserve in one transaction. ##");
            }
        } else {
            console.log("    ## BLOCKER: owner is an EOA. There is no timelock at all, so   ##");
            console.log("    ## every upgrade and every owner setter - caps, fees, bridge    ##");
            console.log("    ## limits, implementations - lands instantly from one key with  ##");
            console.log("    ## nobody able to react. Acceptable only before real deposits.  ##");
        }

        uint256 expectMinDelay = vm.envOr("EXPECT_MIN_DELAY", uint256(0));
        if (expectMinDelay > 0) {
            require(ownedByTimelock, "EXPECT_MIN_DELAY was set but the owner is an EOA");
            require(delay >= expectMinDelay, "timelock delay is below EXPECT_MIN_DELAY");
            console.log("    delay meets EXPECT_MIN_DELAY:", expectMinDelay);
        }
    }

    function _verifyFactory(AssetMarketFactory factory, SharedReservePool pool) private view {
        require(address(factory).code.length > 0, "factory has no code");
        require(address(factory.reservePool()) == address(pool), "factory points at another pool");
        require(factory.protocolTreasury() != address(0), "factory has no protocol treasury");

        // The v4 venue. None of this can be checked against a canonical Uniswap deployment,
        // because there is not one on this chain — the singleton below is the one our own
        // deploy script created, and every market ever opened names it inside its `PoolKey`.
        ProtocolFeeHook feeHook = factory.feeHook();
        address poolManager = address(factory.poolManager());
        require(poolManager.code.length > 0, "factory's PoolManager has no code");
        require(address(feeHook).code.length > 0, "factory's fee hook has no code");
        require(
            address(feeHook.poolManager()) == poolManager,
            "hook answers to a DIFFERENT singleton: markets would have no fee and no oracle"
        );
        require(
            uint160(address(feeHook)) & Hooks.ALL_HOOK_MASK
                == uint160(
                    Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ),
            "hook address does not carry its permission bits"
        );
        // The single most expensive thing a deployment can get wrong while still looking
        // finished: an unset registrar means the hook refuses `registerPool`, so EVERY
        // createMarket reverts — discovered by the first operator who tries to launch.
        require(
            feeHook.registrar() == address(factory),
            "hook registrar is not the factory: every createMarket would revert"
        );
        require(
            address(MarketDeployer).code.length > 0,
            "MarketDeployer library is not linked into this verifier's own build"
        );
        require(factory.equityCodehash() != bytes32(0), "equity verification is DISABLED");
        require(
            factory.isCanonicalEquity(MainnetAddresses.REFERENCE_EQUITY),
            "canonicality test rejects the reference equity"
        );

        // The periphery every market's LP reward distributor is initialised with. A wrong one
        // is invisible until an LP stakes a position the distributor cannot read.
        require(
            address(factory.positionManager()) == MainnetAddresses.V4_POSITION_MANAGER,
            "factory is not on Uniswap's deployed PositionManager"
        );

        console.log("");
        console.log("AssetMarketFactory:", address(factory));
        console.log("    runtime size (bytes):", address(factory).code.length);
        console.log("    owner:", Ownable(address(factory)).owner());
        console.log("    protocol treasury:", factory.protocolTreasury());
        console.log("    protocol bps (yield):", factory.protocolBps());
        console.log("    paid to LPs (bps):", uint256(10_000) - factory.protocolBps());
        console.log("    equity verification: ACTIVE");
        console.log("    PoolManager (Uniswap's own, live on this chain):", poolManager);
        console.log("    ProtocolFeeHook (also the pools' oracle):", address(feeHook));
        console.log("    hook registrar is the factory: YES");
        console.log("    protocol fee on trading (pips of 1e6):", factory.protocolFeePips());
        console.log("    LP reward period (s):", factory.rewardsDuration());
        console.log("    oracle buffer floor (slots):", factory.minObservationCardinality());
        console.log(
            "    PositionManager (markets' distributors):", address(factory.positionManager())
        );
        console.log("    approved assets:", factory.listedAssetsLength());
        console.log("    market count:", factory.marketCount());
    }

    function _verifyRouter(MarketRouter router, AssetMarketFactory factory, SharedReservePool pool)
        private
        view
    {
        require(address(router).code.length > 0, "router has no code");
        require(address(router.factory()) == address(factory), "router points at another factory");
        require(address(router.reservePool()) == address(pool), "router points at another pool");
        // There is no periphery left to mismatch: the router reads the singleton off the
        // factory it serves rather than being handed one, so this asserts it actually did.
        require(
            address(router.poolManager()) == address(factory.poolManager()),
            "router singleton is not the factory's"
        );
        require(address(router.asset()) == MainnetAddresses.USDG, "router asset is not USDG");

        // The periphery IS handed to the router, because there is no factory to derive it
        // from, so it is the one pair of addresses here that a paste could get wrong without
        // anything failing until the first seed.
        require(
            address(router.positionManager()) == MainnetAddresses.V4_POSITION_MANAGER,
            "router is not on Uniswap's deployed PositionManager"
        );
        require(address(router.permit2()) == MainnetAddresses.PERMIT2, "router permit2 mismatch");
        require(
            router.positionManager().poolManager() == address(factory.poolManager()),
            "the PositionManager belongs to a different singleton"
        );

        console.log("");
        console.log("MarketRouter:", address(router));
        console.log("    factory, reserve, PoolManager and reserve asset all MATCH");
        console.log("    PositionManager (Uniswap's own):", address(router.positionManager()));
        console.log("    Permit2:", address(router.permit2()));
        console.log("    seeding mints a real Uniswap v4 LP NFT to the SEEDER, who exits it");
        console.log("    through Uniswap's PositionManager without touching this stack.");
    }

    /// @dev Walks whatever markets exist. On a fresh stack this prints nothing and passes,
    ///      which is the expected state right after step 2.
    function _verifyMarkets(AssetMarketFactory factory) private view {
        uint256 count = factory.marketCount();
        if (count == 0) {
            console.log("");
            console.log("No markets yet. This is the expected state after deployment.");
            return;
        }

        console.log("");
        console.log("--- Markets ---");
        for (uint256 id = 1; id <= count; id++) {
            AssetMarketFactory.Market memory m = factory.market(id);
            require(m.brandToken != address(0), "market has no brand token");
            require(m.poolId != bytes32(0), "market has no pool");
            require(m.lpDistributor != address(0), "market has no LP reward distributor");
            require(factory.marketOfPool(m.poolId) == id, "pool does not map back to its market");

            // The uniqueness slot for this pair. Zero means the owner RETIRED the market: it
            // keeps trading and keeps paying its LPs, but the reserve/asset pair is free for a
            // replacement. Reported rather than asserted, because retirement is a deliberate
            // state and a verifier that read it as damage would block every later run.
            uint256 pairSlot = factory.marketFor(m.reservePool, m.asset);
            require(
                pairSlot == id || pairSlot == 0, "the pair's uniqueness slot names another market"
            );

            // Where the market's float yield ends up. The vault mints the LPs' share and hands
            // it to this address, and only the factory may ever set it — so a vault pointing at
            // another market's distributor would quietly pay the wrong pool's LPs.
            require(
                address(BrandFeeVault(m.feeVault).distributor()) == m.lpDistributor,
                "market's vault pays a distributor that is not its own"
            );

            // A v4 pool has no address, so the identity to verify is the key's: `poolKeyOf`
            // must rebuild a key that hashes back to the id the registry recorded, or every
            // downstream v4 call would be aimed at a pool that is not this market's.
            PoolKey memory key = factory.poolKeyOf(id);
            require(PoolId.unwrap(key.toId()) == m.poolId, "poolKeyOf does not rebuild the pool");
            require(
                address(key.hooks) == address(factory.feeHook()), "market's pool has the wrong hook"
            );
            // And that pool's trading skim is bound, one-shot inside the hook. It goes to the
            // PROTOCOL TREASURY, not to the market's own vault: the trading fee is the
            // protocol's, and it never passes through `BrandFeeVault`, whose only revenue is
            // the float yield. See the comment on the factory's `registerPool` call.
            //
            // Deliberately NOT asserted equal to `factory.protocolTreasury()`. `registerPool`
            // binds the recipient once, at market creation, while `setProtocolParams` may move
            // the treasury afterwards - so equality would fail for every market opened before
            // such a change, a false alarm on an otherwise healthy deployment. Both addresses
            // are printed instead and their divergence is an operator's judgement, not a
            // revert nobody can act on. What IS asserted is that the skim reaches somebody:
            // an unbound pool sends the protocol's trading fee nowhere, silently.
            address skimRecipient = factory.feeHook().feeRecipientOf(key.toId());
            require(skimRecipient != address(0), "market's trading skim is bound to nobody");

            console.log("Market", id);
            console.log("    brand:", IERC20Metadata(m.brandToken).symbol(), m.brandToken);
            console.log("    asset:", IERC20Metadata(m.asset).symbol(), m.asset);
            console.log("    verified asset:", m.verified);
            console.log("    pool id:", vm.toString(m.poolId));
            console.log("    fee:", m.fee);
            console.log("    tick spacing:", int256(m.tickSpacing));
            console.log("    trading skim (pips of 1e6):", factory.feeHook().feePipsFor(key.toId()));
            console.log("    trading skim bound to:", skimRecipient);
            console.log("    protocol treasury now:", factory.protocolTreasury());
            console.log("    fee vault (float yield only):", m.feeVault);
            console.log("    LP reward distributor (gets the LPs' share):", m.lpDistributor);
            console.log("    reserve backing the unit:", m.reservePool);
            console.log("    retired (pair free for a replacement):", pairSlot == 0);
            // The creator is attribution and nothing else: creation is permissionless and
            // parameterless, so there is no authority over a market to hold. The metadata
            // admin on the unit token is the same address, and reaches the three strings only.
            console.log("    creator (attribution, no authority):", m.creator);
        }
    }

    /// @dev The check that was missing when `MAX_FEE_PIPS` was lowered from 50,000 to 10,000 on
    ///      mainnet with no script behind it. Nothing in this repo compared the deployed
    ///      ceiling to the committed one, so the only record of the change was a sentence in a
    ///      manifest, and a sentence is not something an integrator can check.
    ///
    ///      Both directions of a mismatch are a BLOCKER, and they mean different things. A
    ///      live ceiling ABOVE this repo's is the dangerous one: the chain permits a larger
    ///      skim than the audited source says is possible, so every quote an aggregator makes
    ///      is priced against the wrong worst case. A live ceiling BELOW it means a tightening
    ///      landed on chain that `src/` does not carry, which is drift in the other direction
    ///      and makes the repo an unreliable description of what is deployed.
    function _verifyFeeCeiling(AssetMarketFactory factory) private view {
        ProtocolFeeHook feeHook = factory.feeHook();
        uint24 liveCap = feeHook.MAX_FEE_PIPS();

        console.log("");
        console.log("--- Protocol fee ceiling ---");
        console.log("ProtocolFeeHook:", address(feeHook));
        console.log("    live MAX_FEE_PIPS (pips of 1e6):", liveCap);
        console.log("    this repo compiles to:", EXPECTED_MAX_FEE_PIPS);
        if (liveCap != EXPECTED_MAX_FEE_PIPS) {
            console.log("    ## BLOCKER: the deployed skim ceiling is NOT the one this repo  ##");
            console.log("    ## compiles. An implementation was shipped that no script in    ##");
            console.log("    ## this tree produces, or a change here was never deployed.     ##");
            console.log("    ## Reconcile before quoting these pools to anybody. The         ##");
            console.log("    ## reproducible path is UpgradeProtocolFeeCapMainnet.s.sol.     ##");
        } else {
            console.log("    deployed ceiling MATCHES this repo");
        }

        // And no pool is above the live ceiling. Lowering `MAX_FEE_PIPS` does not re-clamp
        // anything: both writers of `feePipsOf` bound their input against the ceiling as it
        // stood at write time, and `feePipsFor` returns the stored value untouched, so a rate
        // written under a looser ceiling stays chargeable above the current one.
        //
        // `feePipsOf` is read here rather than `feePipsFor`, which the market listing above
        // uses: `feePipsFor` returns zero while the protocol is halted, so this check built on
        // it would report a clean sweep on a paused stack and miss the one pool it exists to
        // find.
        uint256 count = factory.marketCount();
        for (uint256 id = 1; id <= count; id++) {
            uint24 pips = feeHook.feePipsOf(factory.poolKeyOf(id).toId());
            if (pips > liveCap) {
                console.log("    ## BLOCKER: a pool is charging above the hook's own ceiling. ##");
                console.log("    ## Only setPoolFeePips can bring it down. Market:", id);
                console.log("    ## stored rate (pips of 1e6):", pips);
            }
        }
        console.log("    pools checked against the ceiling:", count);
    }

    /// @dev Every proxy this script resolves, against the implementation the deployment
    ///      manifest records for it. This is the other half of the 2026-09-19 lesson: three
    ///      implementations moved that day and the only evidence was prose, so an
    ///      implementation that moves again with nobody recording it should be findable by
    ///      running something rather than by reading something.
    function _verifyRecordedImplementations(
        SharedReservePool pool,
        AssetMarketFactory factory,
        MarketRouter router
    ) private view {
        console.log("");
        console.log("--- Implementations against the deployment manifest ---");
        _checkRecordedImplementation("SharedReservePool", address(pool));
        _checkRecordedImplementation("yield source", address(pool.yieldSource()));
        _checkRecordedImplementation("ProtocolFeeHook", address(factory.feeHook()));
        _checkRecordedImplementation("AssetMarketFactory", address(factory));
        _checkRecordedImplementation("MarketRouter", address(router));
        _checkAggregatorSurface(router);
    }

    /// @dev An implementation address matching the manifest proves only that nobody upgraded
    ///      behind the manifest's back. It does not prove the upgrade the manifest CLAIMS was
    ///      ever applied, and on this deployment that distinction is a live defect: the
    ///      2026-09-19 "aggregator surface" work was documented as covering three proxies and
    ///      landed on two. Both yield adapters carry `withdrawable`; `MarketRouter` was never
    ///      upgraded at all, so `sellForUsdg` exists in `src/` and does not exist on chain,
    ///      while `docs/` offers it to aggregators as an entrypoint.
    ///
    ///      So the selector is looked for in the deployed runtime code rather than inferred
    ///      from an address. It is read off the type, `MarketRouter.sellForUsdg.selector`, so
    ///      this check cannot outlive the function it is checking for: delete `sellForUsdg`
    ///      from the router and this script stops compiling instead of quietly passing.
    ///
    ///      Not done as a `staticcall` probe, which is how `_verifyReserve` tests the adapter's
    ///      `sharesOf`. That works only for a `view` function. `sellForUsdg` writes, so under a
    ///      static context it reverts with empty returndata whether or not it is present, which
    ///      is exactly the signal a missing function gives, and the probe could not tell the
    ///      two apart.
    function _checkAggregatorSurface(MarketRouter router) private view {
        address impl = address(uint160(uint256(vm.load(address(router), IMPL_SLOT))));
        if (impl == address(0)) return;

        console.log("aggregator surface on the live router implementation:", impl);
        if (_implementsSelector(impl.code, MarketRouter.sellForUsdg.selector)) {
            console.log("    sellForUsdg IS deployed");
        } else {
            console.log("    ## BLOCKER: sellForUsdg is in src/ but NOT in the deployed      ##");
            console.log("    ## implementation, so every call to it reverts with empty       ##");
            console.log("    ## returndata. An aggregator handed this as a sell entrypoint   ##");
            console.log("    ## would quote routes it can never settle. Either ship          ##");
            console.log("    ## UpgradeAggregatorSurfaceMainnet.s.sol for the router, or     ##");
            console.log("    ## stop documenting the selector as available.                  ##");
        }
    }

    /// @dev Whether `code` dispatches `selector`. Solidity's dispatcher compares the incoming
    ///      selector against a `PUSH4` immediate, so the four bytes appear in the runtime code
    ///      directly behind opcode 0x63. Scanning for that pair rather than for the bare four
    ///      bytes is what keeps a selector-shaped run of constant data from reading as a
    ///      function.
    function _implementsSelector(bytes memory code, bytes4 selector) private pure returns (bool) {
        uint256 len = code.length;
        for (uint256 i = 0; i + 5 <= len; i++) {
            if (code[i] != 0x63) continue;
            bytes4 immediate;
            // The four bytes at `i + 1`, taken as a left-aligned word: `bytes4` keeps the high
            // four of the 32 `mload` returns, which are exactly the PUSH4 operand.
            assembly {
                immediate := mload(add(add(code, 0x21), i))
            }
            if (immediate == selector) return true;
        }
        return false;
    }

    function _checkRecordedImplementation(string memory label, address proxy) private view {
        address recorded = _recordedImplementation(proxy);
        address live = address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));

        console.log(string.concat(label, ":"), proxy);
        if (recorded == address(0)) {
            console.log("    ## BLOCKER: no manifest entry for this proxy. Either it belongs ##");
            console.log("    ## to one of the superseded generations still sitting on this   ##");
            console.log("    ## chain, or a deployment was recorded in the manifest and not  ##");
            console.log("    ## in the table below.                                          ##");
            console.log("    live implementation:", live);
            return;
        }
        if (live == address(0)) {
            console.log("    ## BLOCKER: the ERC-1967 implementation slot is empty, so this  ##");
            console.log("    ## address is not the UUPS proxy the manifest describes.        ##");
            return;
        }
        if (live != recorded) {
            console.log("    ## BLOCKER: implementation DRIFT. Something upgraded this proxy ##");
            console.log("    ## and it is not what the manifest records. Find the            ##");
            console.log("    ## transaction and the source it was built from before          ##");
            console.log("    ## trusting any behaviour this stack is documented to have.     ##");
            console.log("    ## Regenerate the live picture first:                           ##");
            console.log("    ##   node script/sync-mainnet-state.mjs                         ##");
            console.log("    live:    ", live);
            console.log("    manifest:", recorded);
            return;
        }
        console.log("    implementation matches the manifest:", live);
    }

    /// @dev What `deployments/asset-markets-mainnet-v6.json` records behind each gen-6 proxy,
    ///      keyed by proxy so that an address from a superseded generation resolves to nothing
    ///      and says so.
    ///
    ///      Held as code rather than parsed out of the JSON on purpose. `fs_permissions` is
    ///      deliberately empty in `foundry.toml` and widening it so a verifier can read a file
    ///      is a poor trade; more to the point, a committed table is the better provenance
    ///      artifact, because moving an implementation then shows up as a reviewable diff,
    ///      which is precisely what the un-scripted upgrades of 2026-09-19 never did. Update
    ///      it whenever the manifest changes: a stale entry produces a loud false BLOCKER, and
    ///      never a silent pass.
    ///
    ///      **This table is what a human CLAIMED, deliberately.** It mirrors the hand-written
    ///      `deployments/asset-markets-mainnet-v6.json`, not the chain and not
    ///      `deployments/mainnet-state.json`, which `node script/sync-mainnet-state.mjs`
    ///      generates from live getters and which is authoritative for what is actually behind
    ///      every proxy. Mirroring the generated file here would make this check compare the
    ///      chain against itself and pass forever. The disagreement between a claim and a
    ///      getter is the entire signal.
    ///
    ///      Every value below was also cross-checked against the proxy's own ERC-1967
    ///      `Upgraded(address)` log history on chain 4663, which is the only account of these
    ///      upgrades that does not depend on somebody having written one down. The v4 and v5
    ///      manifests are authoritative for the superseded generations still sitting on this
    ///      chain and for nothing that is in use, which is why an address from one of them
    ///      resolves here to zero and reports itself.
    function _recordedImplementation(address proxy) private pure returns (address) {
        // core.sharedReservePool, the USDG group's reserve. One Upgraded event, at deploy.
        if (proxy == 0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3) {
            return 0xE8Ff05B14704eC9A3fb39959Fc40FDa482Ffe4b7;
        }
        // susdaiGroup.reserve, the sUSDai group's reserve. Either may be the one under test:
        // SHARED_RESERVE_POOL names whichever group is being verified. One Upgraded event, at
        // deploy.
        if (proxy == 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2) {
            return 0xC1C9839a9Ced09Fa089a389D8E490800943c6cee;
        }
        // core.morphoBlueYieldSource. UPGRADED 2026-09-19, tx
        // 0xf570920553ea80bd75999f2c7808b2e3a2e544015475deb4ed1d4f29e620cad8, to add
        // `withdrawable()`.
        if (proxy == 0x8e4E5e5EE25DF4721D845600F82bf2Bca48Fa358) {
            return 0x0C23b7628E1bfED0b082447c0746C9760C386DAe;
        }
        // susdaiGroup.adapter. Taken from discovery.groups.1.yieldSourceImplementation, which
        // records the 2026-09-19 `withdrawable()` upgrade (tx
        // 0xca6adaa47740e749fb6a471a6e48bf5dea59502a07dc58f5d08846e1a931c0a9).
        // susdaiGroup.adapterImplementation in the same manifest still names the pre-upgrade
        // 0xef77e979..., which is stale; the two disagree and this is the newer of them.
        if (proxy == 0x460f319E43428387bff58ec262C992Ec7DA22fDc) {
            return 0x15456BA172184DB87333022BF01a7c529C6ED159;
        }
        // core.protocolFeeHook. UPGRADED 2026-09-19, tx
        // 0x17d4f4864d0fab07f7c9d0fc33f9a279c008ae59ce83f700c986df2941e49a0d, from
        // 0x25481313442a01e4c4c32fab1c097205a856c402. That is the fee-ceiling change, and it is
        // the one upgrade of the three that had no script at all until
        // UpgradeProtocolFeeCapMainnet.s.sol.
        if (proxy == 0xc9932584c5154e4F58313a2e5423522E74e540Cc) {
            return 0x579F64aeFa201D1607AeE8C5a3A3b0B01F435928;
        }
        // core.assetMarketFactory. THE MANIFEST IS STALE HERE, so this entry is expected to
        // report drift until it is reconciled, and the drift is a records failure rather than
        // an intrusion. The proxy's log history carries TWO upgrades: 0xdf04e3cb on
        // 2026-09-16T18:58:56Z (tx
        // 0xc5b896dd8bd7bbf62bbe7ff56e4c7457cdcf509edb1d19bb6c5c21106b8e1523), which is the
        // value recorded below, and then 0x45ce2f93ad46d1393eff5da56ffc4537740022c0 on
        // 2026-09-17T09:03:20Z (tx
        // 0x4b423d6d61a50a5a54236d330d981fcf09270043b4eb32c65e567a848a99af4d), which the
        // manifest never recorded and which is what is live. Keeping the manifest's value here
        // rather than the chain's is deliberate: this function's contract is to state what the
        // manifest claims, so that the two can be compared at all.
        if (proxy == 0x22AA61c589B90731752236c07d1455D0065bfc79) {
            return 0xdf04E3cbCcdE64027eb35963F6817540BE4F96d7;
        }
        // core.marketRouter. One Upgraded event, at deploy: this proxy has NEVER been
        // upgraded on gen-6, which is why `sellForUsdg` is missing from it. See
        // `_checkAggregatorSurface`.
        if (proxy == 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4) {
            return 0x3c09784b3e771f57FE0f6651292bbb470e7bACbE;
        }
        return address(0);
    }
}
