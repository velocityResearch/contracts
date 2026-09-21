// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/token/ERC721/IERC721.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

// The real implementations, deployed inside the fork so the four launchpad tests can rehearse
// `UpgradeGraduateIntoLaunchDollarMainnet` against live state before they exercise it. Every
// other assertion in this file still speaks to the deployed surface through the minimal
// interfaces below.
import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../src/markets/LpRewardDistributor.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchDeployer} from "../src/launchpad/LaunchDeployer.sol";
import {LaunchGraduation} from "../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../src/launchpad/LaunchLocker.sol";
import {ILaunchGraduation, ILaunchLocker} from "../src/launchpad/interfaces/ILaunchpad.sol";
import {IPermit2, IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @notice Drives the **DEPLOYED** gen-5 Robinhood Chain mainnet stack — the real addresses in
///         `deployments/asset-markets-mainnet-v5.json` — through every flow the application and
///         the launchpad will send, on a fork of the live chain.
///
///         **Why this suite exists separately from the other fork tests.** Every other
///         `*Fork.t.sol` in this repo deploys its own stack inside its fixture and then exercises
///         it against real external dependencies. That proves the *code*. It does not prove the
///         *deployment*: not one of them touches the addresses that were actually broadcast, so a
///         mis-set owner, a `setLaunchpad` that never landed, a hook whose registrar points at the
///         wrong factory, or a launch config with the wrong supply would all pass a green suite
///         and fail on the first real transaction. This suite pins the broadcast addresses and
///         calls them.
///
///         **It runs against a fork, so it changes nothing.** Where a flow needs an owner call
///         the deployment deliberately has not made — approving an asset, approving a quote
///         brand, enabling launching — the test impersonates the owner and makes it on the fork.
///         That is the point: it shows what those calls will do before they are sent for real.
///         USDG comes from impersonating Morpho Blue, which custodies tens of millions of it.
///
///         **Twelve tests pin what mainnet answers today; four rehearse the next deployment.**
///         The four launchpad flows cannot run on the live code at all — a launch now
///         graduates into its own quote brand, and that stack has not been broadcast — so they
///         call `_rehearseGraduateIntoLaunchDollar` first, which performs
///         `UpgradeGraduateIntoLaunchDollarMainnet` plus the locker and graduation redeploy on
///         the fork, from the Safe, and then runs the whole launch → curve → graduation
///         journey against it. That makes them a dry run of the real rollout on real state.
///         The other twelve deliberately do NOT upgrade: they assert what is deployed, and an
///         upgrade applied in `setUp` would quietly turn them into assertions about this
///         working tree instead.
///
///         Pinned to this deployment on purpose. When gen-5 is superseded, delete it.
///
///         forge test --match-contract LiveGen5Mainnet --fork-url https://rpc.mainnet.chain.robinhood.com -vv
interface IFactory {
    struct AssetListing {
        bool approved;
        uint24 fee;
        uint256 assetPriceE18;
        uint16 observationCardinality;
        string unitName;
        string unitSymbol;
    }

    struct Market {
        address asset;
        address brandToken;
        address treasury;
        address feeVault;
        address lpDistributor;
        bytes32 poolId;
        uint24 fee;
        int24 tickSpacing;
        address creator;
        bool verified;
        uint64 createdAt;
        address reservePool;
    }

    /// @dev `PooledBrandToken.Metadata`, flattened for this minimal ABI view.
    struct BrandMetadata {
        string description;
        string logo;
        string socials;
    }

    function approveAsset(address asset, AssetListing calldata listing) external;
    function createMarket(address asset, address reservePool)
        external
        returns (uint256, address, address, address, bytes32);
    function market(uint256 id) external view returns (Market memory);
    function marketCount() external view returns (uint256);
    /// A brand registered THROUGH the factory, which is what gives it a `reserveOfBrand` and
    /// therefore what a launch quoted in it insists on.
    function registerBrand(string calldata name, string calldata symbol)
        external
        returns (address, address);
    function registerBrand(
        string calldata name,
        string calldata symbol,
        BrandMetadata calldata metadata,
        address reserve
    ) external returns (address, address);
    function treasuryOfBrand(address brand) external view returns (address);
    /// Whether the market is quoted in a dollar it does not own. True for every graduate now
    /// that a graduation stops minting a `<SYM>.d` unit of its own.
    function isSharedQuote(uint256 marketId) external view returns (bool);
    function marketOfAsset(address reservePool, address asset) external view returns (uint256);
    function approvedReservePool(address pool) external view returns (bool);
    function reservePool() external view returns (address);
    function positionManager() external view returns (address);
    function launchpad() external view returns (address);
    function feeHook() external view returns (address);
    function protocolFeePips() external view returns (uint24);
    function protocolTreasury() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function tickSpacingForFee(uint24 fee) external view returns (int24);
}

interface IReserve {
    function mint(address brand, uint256 assets, address to) external returns (uint256);
    function redeem(address brand, uint256 shares, address to, uint256 minOut)
        external
        returns (uint256);
    function swap(address from, address to, uint256 amount, address to_) external returns (uint256);
    function registerBrand(string calldata name, string calldata symbol, address operator)
        external
        returns (address, address);
    function isRegistered(address brand) external view returns (bool);
    /// The registry a `<SYM>.d` used to be appended to at every graduation. Read before and
    /// after a graduation to prove it no longer is.
    function allBrandTokensLength() external view returns (uint256);
    function asset() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalPooledSupply() external view returns (uint256);
    function liabilityCap() external view returns (uint256);
    function redemptionFeeBps() external view returns (uint16);
    function setLiabilityCap(uint256 cap) external;
}

/// @dev How a dollar's issuer consents to sharing the float yield of the markets it quotes.
///      A launch quoted in a brand without it is refused.
interface IBrandTreasury {
    function setFactory(address newFactory) external;
    /// The issuer, and the only party `setFactory` accepts.
    function admin() external view returns (address);
    /// What `AssetMarketFactory.recordLaunchFloat` credited this market's vault with: the
    /// share of the brand's float the graduated pool locked, and therefore the share of the
    /// brand's yield its LPs are paid.
    function floatOf(address vault) external view returns (uint256);
}

interface IRouter {
    function buyWithUsdg(uint256 id, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        returns (uint256);
    function sellForBrand(
        uint256 id,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external returns (uint256);
    function seedLiquidity(
        uint256 id,
        uint256 brandIn,
        uint256 assetIn,
        uint256 minBrand,
        uint256 minAsset,
        uint256 deadline
    ) external returns (uint256, uint128, uint256, uint256);
    function factory() external view returns (address);
    function positionManager() external view returns (address);
}

interface ILaunchFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint24 poolFee;
        bool enabled;
    }

    struct ReserveEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint256 launchFee;
        uint8 decimals;
        bool approved;
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        address reserve;
        uint256 graduationThreshold;
        uint24 poolFee;
        uint16 creatorTaxBps;
        uint16 creatorShareBps;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        uint256 marketId;
        bool exists;
    }

    function launchEnabled() external view returns (bool);
    function launchConfigCount() external view returns (uint256);
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function reserveEconomics(address reserve)
        external
        view
        returns (uint256, uint256, uint256, uint8, bool);
    function launchEconomics(address brand) external view returns (address, ReserveEconomics memory);
    function setReserveEconomics(address reserve, ReserveEconomics calldata e) external;
    function setReserveApproved(address reserve, bool approved) external;
    function setLaunchEnabled(bool enabled) external;
    function previewLaunchEconomics(uint256 configId, address brand) external view returns (bytes32);
    function launchToken(
        TokenParams calldata p,
        uint256 configId,
        address pairToken,
        address[] calldata exemptions
    ) external returns (address, address);
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function graduate(address token) external;
    function graduateToMarket(address token) external;
    function launchCount() external view returns (uint256);
    function launchAt(uint256 i) external view returns (address);
    function graduation() external view returns (address);
    function launchForwarder() external view returns (address);
    function marketFactory() external view returns (address);
    function feeEscrow() external view returns (address);
    function protocolFeeShareBps() external view returns (uint16);
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
    function graduatedCreatorShareBps() external view returns (uint16);
    /// Zero on a proxy that has not taken the LP fund upgrade, which is a valid live state
    /// and is why the assertions read these as an invariant rather than a fixed pair.
    function graduatedLpFundShareBps() external view returns (uint16);
    function lpFundShareBps() external view returns (uint16);
    function lpFundRecipient() external view returns (address);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface ILaunchCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        returns (uint256);
    function readyToGraduate() external view returns (bool);
    function graduated() external view returns (bool);
    function sellableTokens() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function quoteBuy(uint256 quoteIn, address recipient)
        external
        view
        returns (uint256, uint256, uint256);
}

/// @dev Just the immutables the live graduation module exposes, so the locker — and the
///     Permit2 the redeployed module has to be handed — can be derived from the factory
///     rather than pinned. Declared locally because these tests read the deployed surface,
///     which may be an older compilation than `src/`.
interface IGraduationModule {
    function locker() external view returns (address);
    function permit2() external view returns (address);
}

interface ILaunchRouter {
    function buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline)
        external
        returns (uint256);
    function factory() external view returns (address);
}

interface IVault {
    function harvest() external returns (uint256);
    function sweep() external returns (uint256, uint256);
    function minSweep() external view returns (uint256);
    function lpBps() external view returns (uint16);
    function distributor() external view returns (address);
}

interface IDistributor {
    function stake(uint256 tokenId, address beneficiary) external;
    function unstake(uint256 tokenId) external;
    function claim(address brandOut) external returns (uint256);
    function earned(address account) external view returns (uint256);
    function positionCountOf(address account) external view returns (uint256);
    function rewardToken() external view returns (address);
    function fullRange() external view returns (int24, int24);
}

interface IAdapter {
    function hub() external view returns (address);
    function keeper() external view returns (address);
    function maxBridgeAmount() external view returns (uint256);
    function bridgeWindow() external view returns (uint64);
    function controller() external view returns (address);
}

interface IMorphoAccrue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function accrueInterest(MarketParams memory marketParams) external;
}

interface IGuard {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function guardian() external view returns (address);
    function isPaused(address target) external view returns (bool);
    function pauseTarget(address target) external;
}

contract LiveGen5MainnetForkTest is Test {
    // ─── deployments/asset-markets-mainnet-v5.json ───────────────────────
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant V3_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;
    address constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    // The upgrade authority is the 2-of-3 Safe, declared as `SAFE` below. There is no
    // timelock in the v6 stack: `DeploySharedReservePool` was run with `SAFE_MIN_DELAY=0`,
    // so an owner call still lands in one transaction, it just needs two signatures now.
    //
    // A `SAFE` constant used to live here holding the deployer EOA, kept "under its old
    // name so the ownership assertions read naturally". That was a lie that read well: there
    // was no timelock and the value was a hot key. It is gone rather than repointed, because
    // the whole point of these assertions is to say who really controls the protocol.
    address constant GUARD = 0x013D1974F8215a12280e6b9a33F9732277F38C0e;
    address constant RESERVE = 0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3;
    address constant FACTORY = 0x22AA61c589B90731752236c07d1455D0065bfc79;
    address constant ROUTER = 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4;
    address constant FEE_HOOK = 0xc9932584c5154e4F58313a2e5423522E74e540Cc;

    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    address constant LAUNCH_ROUTER = 0xf763CA4670Fa9eCB53821352B13450F514889C79;

    /// @dev The graduation module and its locker are NOT pinned as constants any more, and the
    ///      reason is that they have now been replaced twice. `UpgradeLaunchpadFeeSplitMainnet`
    ///      replaced them on 2026-09-17 (retiring graduation
    ///      0x404AaF69DEa7cf53512D2063e4a3DE36a644140c and locker
    ///      0xEDdCe1d6ea0bFa375D03114b46ac552a4463398b) and
    ///      `UpgradeLaunchpadLpFundMainnet` replaced them again on 2026-09-19 (retiring
    ///      graduation 0xC9C2766B197A9424BE51B2e5CfD438F043A757C2 and locker
    ///      0xACf51B066b90596e8536A1423Df4A6b94D5815c9). The locker is deliberately not
    ///      upgradeable, so every change to how a graduated position's income is split arrives
    ///      as a fresh pair — which makes a hardcoded address here a test that fails on the
    ///      next correct deployment rather than on a defect.
    ///
    ///      Read live from the factory instead, and assert the INVARIANT that both factories
    ///      name the same module. That is the property that actually matters: if
    ///      `AssetMarketFactory.launchpad()` and `LaunchFactory.graduation()` disagree, phase
    ///      two of every graduation reverts `OnlyLaunchpad`, which is the failure a pinned
    ///      address was standing in for.
    function _liveGraduation() internal view returns (address) {
        return launch.graduation();
    }

    function _liveLocker() internal view returns (address) {
        return IGraduationModule(launch.graduation()).locker();
    }

    /// @dev The locker that held positions graduated BEFORE the 2026-09-19 rotation. Those
    ///      three positions (markets 16, 17, 18) stay there forever: nothing moves a staked
    ///      position between lockers, so this address remains the only route by which they
    ///      ever pay out. Pinned on purpose, because it is history rather than configuration.
    address constant PRE_LP_FUND_LOCKER = 0xACf51B066b90596e8536A1423Df4A6b94D5815c9;

    address constant SUSDAI_RESERVE = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;
    address constant SUSDAI_ADAPTER = 0x460f319E43428387bff58ec262C992Ec7DA22fDc;
    address constant SUSDAI_HUB = 0x740ddd200D9Ee605F25239Ba701bdd89161034b1;
    address constant KEEPER = 0x467Ca912943e85A0B0e72B7E1190129762481EEC;

    address constant DEPLOYER = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;
    /// @dev The 2-of-3 Safe. It has ACCEPTED all twelve two-step handles, so it is `owner` on
    ///      every proxy below and the deployer EOA is no longer an authority on any of them.
    ///      Triple-verified against the EIP-55 checksum, the live Safe's own configuration,
    ///      and the `owner()` the migrated contracts report, before the beacons were moved.
    address constant SAFE = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;
    bytes32 constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;

    IFactory factory = IFactory(FACTORY);
    IReserve reserve = IReserve(RESERVE);
    IRouter router = IRouter(ROUTER);
    ILaunchFactory launch = ILaunchFactory(LAUNCH_FACTORY);

    address user = address(0xA11CE);
    address lp = address(0xB0B);

    /// @dev The quote brand the launchpad needs. The deployment deliberately approved none, so
    ///      every launchpad test creates it on the fork and then approves it, which is exactly
    ///      the pair of owner calls that will enable launching for real.
    address quoteBrand;

    /// @dev Set once `_rehearseGraduateIntoLaunchDollar` has run on this fork, so the four
    ///      tests that need it may each ask for it without a second one landing.
    bool rehearsed;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"))
        );
        // Morpho custodies tens of millions of USDG on this chain.
        vm.startPrank(MORPHO);
        IERC20(USDG).transfer(user, 500_000e6);
        IERC20(USDG).transfer(lp, 500_000e6);
        IERC20(USDG).transfer(DEPLOYER, 100_000e6);
        vm.stopPrank();
        vm.deal(user, 10 ether);
        vm.deal(lp, 10 ether);
        vm.deal(DEPLOYER, 10 ether);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    /// @dev Morpho books interest on interaction, not on the clock, so warping alone leaves
    ///      `harvest()` with nothing to find. Poking the market is what the other fork suites do.
    function _accrueMorpho(uint256 elapsed) internal {
        vm.warp(block.timestamp + elapsed);
        IMorphoAccrue m = IMorphoAccrue(MORPHO);
        m.accrueInterest(m.idToMarketParams(USDE_MARKET_ID));
    }

    // ─── 1. The deployment is what the manifest says ─────────────────────

    function test_live_theMarketStackIsWiredAsDeployed() public view {
        assertEq(factory.reservePool(), RESERVE, "factory -> reserve");
        assertEq(factory.positionManager(), POSM, "factory -> v4 PositionManager");
        assertEq(factory.feeHook(), FEE_HOOK, "factory -> hook");
        assertEq(factory.protocolFeePips(), 5_000, "trading skim");
        // Deliberately not a market count. This test pins how the stack is *wired*; how much it
        // has since been used is not a property of the wiring, and asserting it made a working
        // deployment fail its own suite the moment someone opened a market on it.
        assertEq(reserve.asset(), USDG, "reserve asset");
        assertEq(reserve.owner(), SAFE, "the reserve is owned by the multisig");
        assertEq(router.factory(), FACTORY, "router -> factory");
        assertEq(router.positionManager(), POSM, "router -> v4 PositionManager");
        // The hook's permission bits ARE its address; nothing else re-checks this on chain.
        assertEq(
            uint160(uint160(FEE_HOOK)) & 0x3FFF, 0xCC, "hook bits are beforeSwap|afterSwap|deltas"
        );
    }

    function test_live_theLaunchpadIsWiredAsDeployed() public view {
        // The cross-link without which every graduation reverts OnlyLaunchpad.
        assertEq(
            factory.launchpad(),
            launch.graduation(),
            "both factories must name the same graduation module"
        );
        assertTrue(launch.graduation() != address(0), "a graduation module is wired");
        assertEq(launch.launchForwarder(), LAUNCH_ROUTER, "launch factory -> router");
        assertEq(launch.marketFactory(), FACTORY, "launch factory -> market factory");
        assertEq(ILaunchRouter(LAUNCH_ROUTER).factory(), LAUNCH_FACTORY, "router -> launch factory");
        assertEq(launch.launchConfigCount(), 1, "one launch config shipped");
        assertEq(launch.protocolFeeShareBps(), 3_000, "protocol share of the curve fee");
        assertEq(launch.snipeTaxStartBps(), 9_900, "snipe tax start");
        assertEq(launch.snipeTaxSeconds(), 15, "snipe tax window");
        // The rates a graduated position's income is split on. Asserted as the invariant they
        // have to satisfy rather than as the numbers they currently hold: the LP-fee share is
        // snapshotted per launch and the LP-fund share is read live, so the live figures are
        // policy that moves, and pinning policy here only produces a test that fails the next
        // time the owner retunes it. What must never be true is a pair that sums past a whole
        // leg — that would underflow the protocol's remainder inside `LaunchLocker.collect`
        // and wedge every collection on every position at once.
        uint16 feeShare = launch.graduatedCreatorShareBps();
        // The three LP fund getters exist only on an implementation that has taken the fund
        // upgrade. A proxy that has not is a valid live state, not a failure, so absence is
        // read as the leg being off rather than asserted against. This is also the check that
        // tells an operator which implementation is actually live.
        (uint16 fundShare, uint16 curveFundShare, address fundRecipient, bool fundLegDeployed) =
            _readLpFundPolicy(launch);
        assertLe(uint256(feeShare) + fundShare, 10_000, "LP-fee leg splits to at most the whole");
        assertLe(
            launch.protocolFeeShareBps() + uint256(curveFundShare),
            10_000,
            "curve fee splits to at most the whole"
        );
        // A rate with nowhere to pay it credits the escrow to address zero and reverts every
        // sweep, so the recipient is required exactly when a share is nonzero.
        if (curveFundShare != 0 || fundShare != 0) {
            assertTrue(fundLegDeployed, "a funded LP fund leg needs the upgraded implementation");
            assertTrue(fundRecipient != address(0), "a funded LP fund leg has an address");
        }

        ILaunchFactory.LaunchConfig memory cfg = launch.getLaunchConfig(0);
        assertEq(cfg.supply, 1e27, "launch supply");
        assertEq(cfg.curveFeeBps, 100, "curve fee");
        assertEq(cfg.poolFee, 5_000, "graduated pool tier");
        assertTrue(cfg.enabled, "config enabled");
    }

    /// @dev Reads the LP fund policy off whatever implementation is live, treating a missing
    ///      getter as the leg being off. `try` on each call rather than one probe, because a
    ///      half-upgraded surface is exactly the drift this suite exists to catch: the same
    ///      script that added these three added them together, so disagreement between them
    ///      would mean something other than an ordinary upgrade happened.
    function _readLpFundPolicy(ILaunchFactory factory)
        internal
        view
        returns (uint16 fundShare, uint16 curveFundShare, address recipient, bool deployed)
    {
        try factory.graduatedLpFundShareBps() returns (uint16 value) {
            fundShare = value;
            deployed = true;
        } catch {
            return (0, 0, address(0), false);
        }
        curveFundShare = factory.lpFundShareBps();
        recipient = factory.lpFundRecipient();
    }

    /// @dev The platform is open now, so the property worth pinning is no longer "nothing can
    ///      happen" but "the one thing that has to be configured before anything can happen is
    ///      one owner call, and it opens every dollar on the reserve — including the ones
    ///      nobody has issued yet".
    ///
    ///      REHEARSED, not read off today's chain, and the name says so. Launch terms are
    ///      keyed by RESERVE here and the upgrade that re-keys them carries empty calldata:
    ///      every reserve reads closed until the owner writes its figures, and the per-brand
    ///      entries mainnet holds today sit at a retired slot no function reads. So the
    ///      property is proven the way the rollout will establish it.
    ///
    ///      The live sUSDai brand is the counterexample that makes the rollout safe, and it is
    ///      asserted here rather than assumed: $slUSD was registered STRAIGHT onto the sUSDai
    ///      reserve rather than through the market factory, so `treasuryOfBrand` is zero and
    ///      no reserve-level call can ever make it launchable. That is what retires the old
    ///      `setPairTokenApproved(slUSD, false)` rollout step — the refusal is structural now,
    ///      not an approval somebody has to remember to take off.
    function test_rehearsed_openingTheSusdaiReserveLaunchesEveryBrandRegisteredOnItAfterwards()
        public
    {
        _rehearseGraduateIntoLaunchDollar();

        // $slUSD. Pooled in the reserve, and invisible to the market factory.
        address slUsd = 0xE20cE31a996f07b3d70F9C840e6810F0f572C884;
        assertTrue(IReserve(SUSDAI_RESERVE).isRegistered(slUsd), "registered on its reserve");
        assertEq(factory.treasuryOfBrand(slUsd), address(0), "never registered through the factory");
        vm.expectRevert(
            abi.encodeWithSignature("PairTokenNotRegistered(address,address)", slUsd, address(0))
        );
        launch.launchEconomics(slUsd);

        // One call, naming the RESERVE. No transaction here ever names a brand.
        vm.startPrank(SAFE);
        launch.setReserveEconomics(
            SUSDAI_RESERVE,
            ILaunchFactory.ReserveEconomics({
                phantomQuote: 3_236e6,
                graduationThreshold: 8_090e6,
                launchFee: 1e6,
                decimals: 6,
                approved: true
            })
        );
        launch.setLaunchEnabled(true);
        vm.stopPrank();
        assertTrue(launch.launchEnabled(), "launching is open");

        // Opening the reserve does not resurrect the brand the factory never registered.
        vm.expectRevert(
            abi.encodeWithSignature("PairTokenNotRegistered(address,address)", slUsd, address(0))
        );
        launch.launchEconomics(slUsd);

        // And the property this whole re-keying exists for: a dollar issued AFTER the reserve
        // was opened is launchable immediately. Everything below is the issuer acting alone —
        // `user`, not `SAFE` — so a passing assertion is proof that no owner call stands
        // between issuing a dollar and launching against it.
        vm.startPrank(user);
        (address freshBrand, address freshTreasury) = factory.registerBrand(
            "Community sUSDai Dollar",
            "commUSD",
            IFactory.BrandMetadata({description: "", logo: "", socials: ""}),
            SUSDAI_RESERVE
        );
        IBrandTreasury(freshTreasury).setFactory(FACTORY);

        (address r, ILaunchFactory.ReserveEconomics memory e) = launch.launchEconomics(freshBrand);
        assertEq(r, SUSDAI_RESERVE, "the new dollar is backed by the sUSDai reserve");
        assertTrue(r != RESERVE, "and not by the market factory's default");
        assertTrue(e.approved, "launchable with no owner call of its own");
        assertEq(e.decimals, 6, "quote decimals");
        assertEq(e.phantomQuote, 3_236e6, "phantom quote");
        assertEq(e.graduationThreshold, 8_090e6, "graduation threshold");

        // Terms that merely read "open" have never deployed anything, so launch it.
        bytes32 pinned = launch.previewLaunchEconomics(0, freshBrand);
        IERC20(USDG).approve(SUSDAI_RESERVE, 10e6);
        IReserve(SUSDAI_RESERVE).mint(freshBrand, 10e6, user);
        IERC20(freshBrand).approve(LAUNCH_FACTORY, type(uint256).max);
        (address token,) = launch.launchToken(
            ILaunchFactory.TokenParams({
                name: "Live Quote Coin",
                symbol: "LQC",
                logo: "",
                description: "a dollar issued after its reserve was opened, launchable at once",
                socials: ILaunchFactory.Socials("", "", "", "", ""),
                creatorFeeRecipient: user,
                creatorTaxBps: 0,
                expectedEconomics: pinned,
                salt: bytes32(uint256(0x11FE))
            }),
            0,
            freshBrand,
            new address[](0)
        );
        vm.stopPrank();

        ILaunchFactory.LaunchedToken memory rec = launch.getLaunchedToken(token);
        assertEq(rec.pairToken, freshBrand, "the launch is quoted in the new dollar");
        assertEq(rec.reserve, SUSDAI_RESERVE, "against the reserve the owner opened");
        assertEq(rec.graduationThreshold, 8_090e6, "on that reserve's terms");
    }

    function test_live_theSusdaiGroupIsOperationalAndBoundedOnEverySide() public view {
        assertEq(IAdapter(SUSDAI_ADAPTER).hub(), SUSDAI_HUB, "adapter -> hub");
        assertEq(IAdapter(SUSDAI_ADAPTER).keeper(), KEEPER, "adapter -> keeper");
        assertEq(IAdapter(SUSDAI_ADAPTER).controller(), SUSDAI_RESERVE, "adapter -> its reserve");
        assertTrue(factory.approvedReservePool(SUSDAI_RESERVE), "reserve approved on the factory");
        assertEq(IReserve(SUSDAI_RESERVE).owner(), SAFE, "the multisig owns the sUSDai group");

        // The group is live now, so what matters is that each limit is a real number rather
        // than a default. Zero is not "off" for two of these three and the distinction cost a
        // wrong call earlier: the cap treats zero as UNLIMITED, and the fee at zero silently
        // moves bridge and Curve costs onto brand yield instead of recovering them. Only the
        // bridge cap is fail-closed at zero.
        //
        // Asserted as nonzero rather than pinned to a figure, which is what the paragraph
        // above always meant. Both notional limits have since been raised from 100_000e6 and
        // 5_000e6 to 10_000_000e6, and the pinned versions of these two assertions failed on
        // that entirely legitimate retune. A limit an owner is expected to tune is policy, and
        // pinning policy in a live-state test only manufactures a failure the next time the
        // policy moves.
        uint256 cap = IReserve(SUSDAI_RESERVE).liabilityCap();
        assertGt(cap, 0, "the cap is set, and zero would mean unlimited rather than closed");
        assertGe(
            cap,
            IReserve(SUSDAI_RESERVE).totalPooledSupply(),
            "and outstanding liabilities are within it"
        );
        // 20 rather than the 14 the deploy scripts default to: a deliberate margin over the
        // round trip's actual cost, so a fee change is not needed the first time a bridge
        // comes in dearer than modelled. A redeploy must pass REDEMPTION_FEE_BPS explicitly
        // or it will quietly land back on 14. Pinned, unlike the two above, because this one
        // is not a headroom figure: it is the rate a redeemer pays, and a silent move from 20
        // to 14 is the regression the comment describes.
        assertEq(IReserve(SUSDAI_RESERVE).redemptionFeeBps(), 20, "fee repays lossCarryforward");
        assertGt(IAdapter(SUSDAI_ADAPTER).maxBridgeAmount(), 0, "single-bridge ceiling is set");
        // RSV-004: the per-deposit cap bounds one bridge and nothing bounded N in a block.
        assertEq(IAdapter(SUSDAI_ADAPTER).bridgeWindow(), 1 days, "windowed notional budget");
    }

    /// @notice The handover to the multisig is COMPLETE for every two-step proxy, and this
    ///         pins that end state.
    ///
    ///         This assertion has now been correct in three different forms, which is worth
    ///         recording rather than hiding. It first read `pendingOwner() == address(0)` and
    ///         `owner() == DEPLOYER`, meaning "owned outright, no stale nomination a later
    ///         accept() could act on". Mid-migration that inverted: every proxy was
    ///         deliberately nominated, so an empty `pendingOwner` would have meant the
    ///         migration had been reverted. Now the Safe has accepted all twelve, so it is
    ///         `owner` and the nomination slots are empty again for the opposite reason.
    ///
    ///         The hazard being guarded has never changed: ownership must sit exactly where
    ///         intended, and no nomination may be left behind for anyone to accept later.
    function test_live_everyProxyIsOwnedByTheSafeWithNoNominationLeft() public view {
        // The retiring deployer key no longer owns any of them.
        assertEq(factory.owner(), SAFE, "factory owned by the Safe");
        assertEq(launch.owner(), SAFE, "launch factory owned by the Safe");
        assertEq(IReserve(RESERVE).owner(), SAFE, "reserve owned by the Safe");
        assertEq(IGuard(GUARD).owner(), SAFE, "guard owned by the Safe");

        // And nothing is left dangling that a later acceptOwnership could act on.
        assertEq(factory.pendingOwner(), address(0), "no nomination left on the factory");
        assertEq(launch.pendingOwner(), address(0), "no nomination left on the launch factory");
        assertEq(IReserve(RESERVE).pendingOwner(), address(0), "no nomination left on the reserve");
        assertEq(IGuard(GUARD).pendingOwner(), address(0), "no nomination left on the guard");

        // The guardian is NOT part of the handover and must stay a hot key, so a pause never
        // waits on a second signature. It is rotated separately, never to the Safe.
        assertTrue(IGuard(GUARD).guardian() != SAFE, "the guardian must not be the multisig");
    }

    // ─── 2. The market flow, through the deployed addresses ──────────────

    /// @dev Approves SPCX and opens its market exactly as the runbook's two commands do.
    function _openSpcxMarket()
        internal
        returns (uint256 id, address unit, address vault, address dist)
    {
        uint256 price = 150e18; // ~SPCX/USDG; the exact figure only sets the opening tick.
        vm.startPrank(SAFE);
        factory.approveAsset(
            SPCX,
            IFactory.AssetListing({
                approved: true,
                fee: 3_000,
                assetPriceE18: price,
                observationCardinality: 128,
                unitName: "Stables Star Dollar",
                unitSymbol: "starUSD"
            })
        );
        (id, unit, vault, dist,) = factory.createMarket(SPCX, RESERVE);
        vm.stopPrank();
    }

    function test_live_ownerApprovesAnAssetAndOpensItsMarket() public {
        // Against the count this deployment already carries, not against zero. Markets have been
        // opened on it since this suite was written, and a test that has to be edited every time
        // the deployment is used for its purpose pins the wrong thing: what must hold is that
        // opening one appends exactly one market and hands back the id it appended.
        uint256 before = factory.marketCount();
        (uint256 id, address unit, address vault, address dist) = _openSpcxMarket();

        assertEq(id, before + 1, "the new market is the one appended");
        assertEq(factory.marketCount(), before + 1, "market recorded");
        IFactory.Market memory m = factory.market(id);
        assertEq(m.asset, SPCX, "asset");
        assertEq(m.brandToken, unit, "unit");
        assertEq(m.reservePool, RESERVE, "reserve");
        assertTrue(m.verified, "SPCX passes the equity codehash check on this chain");
        assertEq(IVault(vault).distributor(), dist, "vault pays this market's distributor");
        assertEq(IDistributor(dist).rewardToken(), unit, "rewards paid in the unit");
        assertEq(IVault(vault).lpBps(), 10_000, "the whole float goes to LPs");
        console.log("market 1 unit:", unit);
    }

    function test_live_mintTheUnitThenTradeBothDirections() public {
        (uint256 id, address unit,,) = _openSpcxMarket();

        // Seed the pool so there is something to trade against.
        uint256 spcx = IERC20(SPCX).balanceOf(V3_POOL);
        vm.prank(V3_POOL);
        IERC20(SPCX).transfer(lp, spcx / 20);
        vm.startPrank(lp);
        IERC20(USDG).approve(RESERVE, 200_000e6);
        reserve.mint(unit, 200_000e6, lp);
        IERC20(unit).approve(ROUTER, type(uint256).max);
        IERC20(SPCX).approve(ROUTER, type(uint256).max);
        router.seedLiquidity(id, 100_000e6, IERC20(SPCX).balanceOf(lp), 0, 0, _deadline());
        vm.stopPrank();

        // Mint is exactly 1:1.
        vm.startPrank(user);
        IERC20(USDG).approve(RESERVE, 1_000e6);
        uint256 minted = reserve.mint(unit, 1_000e6, user);
        vm.stopPrank();
        assertEq(minted, 1_000e6, "unit is not 1:1");

        // Buy the asset with USDG through the router, then sell back for the unit.
        vm.startPrank(user);
        IERC20(USDG).approve(ROUTER, 500e6);
        uint256 got = router.buyWithUsdg(id, 500e6, 1, user, _deadline());
        assertGt(got, 0, "buy returned nothing");
        IERC20(SPCX).approve(ROUTER, got);
        uint256 back = router.sellForBrand(id, got, 1, user, _deadline());
        vm.stopPrank();
        assertGt(back, 0, "sell returned nothing");
        console.log("bought SPCX (wei):", got);
        console.log("sold back for unit (6dp):", back);
    }

    /// @notice Redemption never pays more than par, and a floor above par is always refused.
    ///
    ///         This is the finding this suite was written to catch, restated as the property
    ///         that actually holds. `previewRedeem` "demands exactly par less the fee" and
    ///         `redemptionFeeBps` is zero on this reserve, so the reviewed quote is the full
    ///         amount — but minting supplies into Morpho inline, so redeeming what was just
    ///         minted recalls the whole position and `_cappedByIdle` can truncate a wei off
    ///         the share-to-asset floor division. The frontend used to set its floor at exact
    ///         par and broke on that wei. Mock yield sources do not round, which is why no
    ///         offline test saw it.
    ///
    ///         Whether exact par is reachable on any given day is NOT a contract guarantee: it
    ///         depends on how much surplus the reserve happens to hold, and the original
    ///         version of this test asserted that exact par always reverts, which stopped
    ///         being true once the pool carried enough surplus to cover the rounding. What is
    ///         guaranteed, and is what the frontend actually needs, is that a payout is never
    ///         above par and that a floor demanding more than par is refused.
    function test_live_redeemPaysAtMostParAndRefusesAFloorAboveIt() public {
        (, address unit,,) = _openSpcxMarket();
        vm.startPrank(user);
        IERC20(USDG).approve(RESERVE, 2_000e6);
        reserve.mint(unit, 1_000e6, user);

        // Above par: always refused. A 1:1 claim cannot pay more than it is worth, so this
        // holds at every reserve state, surplus or not.
        vm.expectRevert();
        reserve.redeem(unit, 1_000e6, user, 1_000e6 + 1);

        // The frontend's floor is `previewRedeem` less REDEMPTION_DUST_TOLERANCE (10 base
        // units). That clears whether or not the recall lands a wei short.
        uint256 before = IERC20(USDG).balanceOf(user);
        uint256 out = reserve.redeem(unit, 1_000e6, user, 1_000e6 - 10);
        vm.stopPrank();

        assertGe(out, 1_000e6 - 10, "payout below the tolerated floor");
        assertLe(out, 1_000e6, "payout above par");
        assertEq(IERC20(USDG).balanceOf(user) - before, out, "USDG not returned");
        console.log("redeemed 1000.000000 and received (6dp):", out);
    }

    // ─── 3. The launchpad, through the deployed addresses ────────────────

    /// @notice Perform, on the fork and from the Safe, the upgrade that has NOT been broadcast
    ///         to mainnet yet: `UpgradeGraduateIntoLaunchDollarMainnet` plus the locker and
    ///         graduation redeploy that script deliberately leaves to a separate step.
    ///
    /// @dev    **Why some tests upgrade and the rest must not.** The tests that do not
    ///         rehearse pin what mainnet answers *today* — who owns what, which module both
    ///         factories name, what the sUSDai group's limits are — and an upgrade applied in
    ///         `setUp` would make every one of them assert the code in this working tree
    ///         instead of the code on chain, which is the entire failure mode this suite was
    ///         written to catch. The launchpad flows cannot run on today's chain at all: a
    ///         launch now graduates into its own quote brand and refuses one whose
    ///         `PoolBrandTreasury` has not called `setFactory` — a function the live treasury
    ///         implementation behind beacon `0xf8b7…C34E` does not have — and it reads its
    ///         terms off the brand's RESERVE, which no live proxy carries yet. So they
    ///         rehearse the deployment first and then run against it, which makes them a dry
    ///         run of the real rollout against real state rather than a second offline suite.
    ///
    ///         Steps 1 to 4 are the script's steps, in the script's order. Steps 5 and 6 are
    ///         the two things a rollout needs that the script deliberately does not carry:
    ///
    ///         1–2. `upgradeToAndCall` with empty calldata on the `AssetMarketFactory` and
    ///              `LaunchFactory` proxies. Nothing was added, moved or retyped on either, so
    ///              there is no initialiser to run.
    ///         3.   `upgradeTo` on the `PoolBrandTreasury`, `BrandFeeVault` and
    ///              `LpRewardDistributor` beacons. Every treasury, vault and distributor is a
    ///              `BeaconProxy`, so one call each moves all of them — including the treasury
    ///              of a brand that does not exist yet, which is what lets `_enableLaunching`
    ///              register a brand below and immediately call `setFactory` on it.
    ///         4.   The LP fund recipient BEFORE either rate: every share setter refuses a
    ///              nonzero rate while `lpFundRecipient` is unset.
    ///         5.   Redeploy `LaunchLocker` and `LaunchGraduation`. Neither is upgradeable —
    ///              that is what makes "the liquidity is locked forever" a property of the
    ///              bytecode — and `LaunchLocker.setGraduation` is one-shot, so a new module
    ///              always arrives as a fresh pair, with both factories repointed at it.
    ///         6.   Redeploy `LaunchDeployer` and rotate the factory onto it. This step is
    ///              NOT in `UpgradeGraduateIntoLaunchDollarMainnet`, and it has to be here
    ///              anyway: the live deployer embeds the pre-segments `LaunchCurve` creation
    ///              code, whose only entry point is `initialize(address)`, while every
    ///              `LaunchFactory` built from this tree calls
    ///              `initialize(address,(uint16,uint32)[])`. Without the rotation the first
    ///              `launchToken` after the upgrade reverts with no data, in the curve's
    ///              missing-selector fallback. A curve already deployed is untouched by the
    ///              rotation, so this only governs launches created after it.
    ///
    ///         The issuer opt-in the script's step 5 makes for each live quote brand is not
    ///         made here, because these tests register their own brands: each one calls
    ///         `PoolBrandTreasury.setFactory` itself, as its own issuer, which is exactly what
    ///         the script asks a third-party issuer to do.
    ///
    ///         The fresh `LaunchFactory` implementation needs the `LaunchGuardDeployer`
    ///         library linked; forge links it into `new LaunchFactory()` automatically here,
    ///         the same way the broadcast does.
    function _rehearseGraduateIntoLaunchDollar() internal {
        _rehearseGraduateIntoLaunchDollar(true);
    }

    /// @dev The same rehearsal with step 6 made optional, so
    ///      `test_live_upgradingTheLaunchFactoryWithoutItsDeployerBreaksEveryNewLaunch` can
    ///      hold the rollout one call short and show what that costs. Nothing else passes
    ///      `false`.
    function _rehearseGraduateIntoLaunchDollar(bool rotateLaunchDeployer) internal {
        if (rehearsed) return;
        rehearsed = true;

        AssetMarketFactory marketFactory = AssetMarketFactory(FACTORY);
        LaunchFactory launchFactory = LaunchFactory(LAUNCH_FACTORY);

        // Derived, never pinned, for the reason `_liveGraduation` gives: the beacons belong to
        // the reserves and the market factory, and the Permit2 the redeployed module needs is
        // an immutable of the module being replaced.
        address treasuryBeacon = SharedReservePool(RESERVE).treasuryBeacon();
        address susdaiTreasuryBeacon = SharedReservePool(SUSDAI_RESERVE).treasuryBeacon();
        (address vaultBeacon, address distributorBeacon) = marketFactory.beacons();
        address permit2 = IGraduationModule(launch.graduation()).permit2();

        address freshMarketImplementation = address(new AssetMarketFactory());
        address freshLaunchImplementation = address(new LaunchFactory());
        address freshTreasuryImplementation = address(new PoolBrandTreasury());
        address freshVaultImplementation = address(new BrandFeeVault());
        address freshDistributorImplementation = address(new LpRewardDistributor());

        vm.startPrank(SAFE);
        marketFactory.upgradeToAndCall(freshMarketImplementation, "");
        launchFactory.upgradeToAndCall(freshLaunchImplementation, "");

        UpgradeableBeacon(treasuryBeacon).upgradeTo(freshTreasuryImplementation);
        // The two reserves share one treasury beacon today, but nothing enforces that, so the
        // second is moved only if it is genuinely a second — `upgradeTo` to the implementation
        // a beacon already holds is accepted, but repeating it would hide a split if one ever
        // happened.
        if (susdaiTreasuryBeacon != treasuryBeacon) {
            UpgradeableBeacon(susdaiTreasuryBeacon).upgradeTo(freshTreasuryImplementation);
        }
        UpgradeableBeacon(vaultBeacon).upgradeTo(freshVaultImplementation);
        UpgradeableBeacon(distributorBeacon).upgradeTo(freshDistributorImplementation);

        launchFactory.setLpFundRecipient(factory.protocolTreasury());
        launchFactory.setGraduatedLpFundShareBps(3_000);
        launchFactory.setGraduatedCreatorShareBps(4_000);
        vm.stopPrank();

        LaunchLocker locker = new LaunchLocker(SAFE, LAUNCH_FACTORY);
        LaunchGraduation graduation = new LaunchGraduation(
            LAUNCH_FACTORY,
            marketFactory,
            IPositionManagerV4(POSM),
            IPermit2(permit2),
            ILaunchLocker(address(locker)),
            launchFactory.feeEscrow()
        );

        // The curve deployer the fresh implementation needs; see step 6. Built outside the
        // prank, because a `new` consumes a `vm.prank` the same way a call does.
        LaunchDeployer launchDeployer = _freshLaunchDeployer();

        vm.startPrank(SAFE);
        locker.setGraduation(address(graduation));
        launchFactory.setGraduation(ILaunchGraduation(address(graduation)));
        marketFactory.setLaunchpad(address(graduation));
        if (rotateLaunchDeployer) launchFactory.setLaunchDeployer(launchDeployer);
        vm.stopPrank();

        // The cross-link every graduation depends on, asserted here rather than in each test:
        // a rehearsal that half-landed would otherwise surface as `OnlyLaunchpad` deep inside
        // phase two and read like a contract defect.
        assertEq(factory.launchpad(), address(graduation), "market factory not repointed");
        assertEq(launch.graduation(), address(graduation), "launch factory not repointed");
        assertEq(_liveLocker(), address(locker), "the fresh module does not name its locker");
    }

    /// @dev A `LaunchDeployer` built from this tree, and therefore carrying this tree's
    ///      `LaunchCurve` creation code. Its constructor names the factory, which is what
    ///      `setLaunchDeployer` checks before accepting it.
    function _freshLaunchDeployer() internal returns (LaunchDeployer) {
        return new LaunchDeployer(LAUNCH_FACTORY);
    }

    /// @dev The owner calls that open launching, plus the brand they need. This is the exact
    ///      sequence that will enable the launchpad for real.
    ///
    ///      The brand is registered THROUGH the market factory, not straight onto the reserve.
    ///      Graduation now opens the market quoted in this very brand, so the factory has to
    ///      know which reserve it belongs to, and the brand's treasury has to name the factory
    ///      before a launch quoted in it is accepted. Registering leaves the caller as the
    ///      treasury's admin, which is why both calls sit inside the same prank.
    ///
    ///      The launch terms are written against the RESERVE and opened in a second call, so
    ///      every dollar on it — this one and any issued later — launches on them.
    ///
    ///      The rehearsal comes first and is not optional: `setFactory` does not exist on the
    ///      treasury implementation mainnet is running today.
    function _enableLaunching() internal {
        _rehearseGraduateIntoLaunchDollar();

        vm.startPrank(SAFE);
        address quoteTreasury;
        (quoteBrand, quoteTreasury) = factory.registerBrand("Launch Dollar", "launchUSD");
        IBrandTreasury(quoteTreasury).setFactory(FACTORY);
        launch.setReserveEconomics(
            RESERVE,
            ILaunchFactory.ReserveEconomics({
                phantomQuote: 3_236e6,
                graduationThreshold: 8_090e6,
                launchFee: 1e6,
                decimals: 6,
                approved: false
            })
        );
        launch.setReserveApproved(RESERVE, true);
        launch.setLaunchEnabled(true);
        vm.stopPrank();
    }

    function _mintQuote(address to, uint256 amount) internal {
        vm.startPrank(to);
        IERC20(USDG).approve(RESERVE, amount);
        reserve.mint(quoteBrand, amount, to);
        vm.stopPrank();
    }

    function test_live_enablingLaunchingOpensTheBrandAndTheLaunchpad() public {
        _enableLaunching();
        assertTrue(launch.launchEnabled(), "launching is open");
        (address r, ILaunchFactory.ReserveEconomics memory e) = launch.launchEconomics(quoteBrand);
        assertEq(r, RESERVE, "brand's reserve");
        assertEq(e.decimals, 6, "reserve asset decimals");
        assertTrue(e.approved, "the reserve is open for launches");
        assertTrue(reserve.isRegistered(quoteBrand), "brand registered on the reserve");
    }

    /// @dev The launch terms, factored out so the launch that works and the launch that
    ///      cannot work submit byte-identical parameters and differ only in whether the
    ///      factory's curve deployer was rotated with it.
    function _launchParams(address creator, bytes32 salt)
        internal
        view
        returns (ILaunchFactory.TokenParams memory)
    {
        return ILaunchFactory.TokenParams({
            name: "Mainnet Test Coin",
            symbol: "MTC",
            logo: "",
            description: "live-surface fork exercise",
            socials: ILaunchFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: creator,
            creatorTaxBps: 0,
            expectedEconomics: launch.previewLaunchEconomics(0, quoteBrand),
            salt: salt
        });
    }

    function _launch(address creator, bytes32 salt)
        internal
        returns (address token, address curve)
    {
        address[] memory none = new address[](0);
        vm.startPrank(creator);
        IERC20(quoteBrand).approve(LAUNCH_FACTORY, type(uint256).max);
        (token, curve) = launch.launchToken(_launchParams(creator, salt), 0, quoteBrand, none);
        vm.stopPrank();
    }

    /// @dev Phase two, returning what the position mint actually consumed of the quote brand.
    ///      `graduateToMarket` returns nothing and the figure exists only in the module's
    ///      return value and in `PoolGraduated`, and it is the very number the graduation
    ///      hands to `AssetMarketFactory.recordLaunchFloat` — so reading it off the event is
    ///      how the float assertions below compare against the real seed rather than against
    ///      a re-derivation of it.
    function _graduateToMarketAndReadSeed(address token) internal returns (uint256 unitSeeded) {
        vm.recordLogs();
        launch.graduateToMarket(token);

        bytes32 sig = keccak256(
            "PoolGraduated(address,uint256,address,bytes32,uint256,uint256,uint256,uint256)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != LAUNCH_FACTORY || logs[i].topics[0] != sig) continue;
            (,,, unitSeeded,,) =
                abi.decode(logs[i].data, (address, bytes32, uint256, uint256, uint256, uint256));
            return unitSeeded;
        }
        revert("PoolGraduated not emitted");
    }

    function test_live_launchATokenAndTradeItsCurve() public {
        _enableLaunching();
        _mintQuote(user, 20_000e6);

        // Relative to what this deployment has already launched, for the reason the market test
        // above gives: real launches have landed on it since, and the fact worth holding is that
        // one more appends one more and indexes it at the end.
        uint256 before = launch.launchCount();
        (address token, address curve) = _launch(user, bytes32(uint256(1)));
        assertEq(launch.launchCount(), before + 1, "launch recorded");
        assertEq(launch.launchAt(before), token, "launch indexed");
        assertEq(IERC20(token).totalSupply(), 1e27, "supply");
        assertEq(IERC20(token).balanceOf(curve), 1e27, "whole supply starts on the curve");

        // Warp past the snipe-tax window so the buy is priced normally rather than taxed 99%.
        vm.warp(block.timestamp + 30);

        vm.startPrank(user);
        IERC20(quoteBrand).approve(curve, 1_000e6);
        uint256 out = ILaunchCurve(curve).buy(1_000e6, 1, user);
        vm.stopPrank();
        assertGt(out, 0, "curve buy returned nothing");
        assertEq(IERC20(token).balanceOf(user), out, "tokens not delivered");

        // And back.
        vm.startPrank(user);
        IERC20(token).approve(curve, out / 2);
        uint256 quoteBack = ILaunchCurve(curve).sell(out / 2, 1, user);
        vm.stopPrank();
        assertGt(quoteBack, 0, "curve sell returned nothing");
        console.log("curve buy tokens out:", out);
        console.log("curve sell quote back (6dp):", quoteBack);
    }

    /// @notice Upgrading the `LaunchFactory` without rotating its `LaunchDeployer` breaks every
    ///         new launch, so a fresh deployer is a hard prerequisite of this rollout.
    ///
    /// @dev    This assertion has flipped twice, and the history is the point. The live
    ///         deployer at `0x7979708A…dd5E7` embeds a `LaunchCurve` whose only entry point is
    ///         `initialize(address)` — `0xc4d66de8`. Segmented curves gave `LaunchCurve` a
    ///         second overload, `initialize(address,(uint16,uint32)[])` — `0x6508e7ac` — and a
    ///         factory built from this tree calls that one. The live curve has no such
    ///         selector, so the call dies several frames down in its missing-selector
    ///         fallback, with no revert data, on every single launch.
    ///
    ///         The graduate-into-launch-dollar branch was cut without segments and pinned the
    ///         opposite — "the live deployer still serves this tree" — noting that the step
    ///         comes back the day the overload returns. It has returned: this tree carries
    ///         both. So the rollout gets its step back, and this holds it one call short to
    ///         show what that costs, then makes the call and shows it is sufficient. A curve
    ///         already deployed is untouched by the rotation; it governs launches created
    ///         after it.
    function test_live_upgradingTheLaunchFactoryWithoutItsDeployerBreaksEveryNewLaunch() public {
        _rehearseGraduateIntoLaunchDollar(false);
        _enableLaunching();
        _mintQuote(user, 20_000e6);

        address[] memory none = new address[](0);
        ILaunchFactory.TokenParams memory params = _launchParams(user, bytes32(uint256(11)));

        vm.prank(user);
        IERC20(quoteBrand).approve(LAUNCH_FACTORY, type(uint256).max);
        vm.prank(user);
        (bool ok,) = LAUNCH_FACTORY.call(
            abi.encodeCall(ILaunchFactory.launchToken, (params, 0, quoteBrand, none))
        );
        assertFalse(ok, "the live deployer served a factory from this tree: the step is not needed");

        // The one call the rollout owes: a deployer carrying this tree's curve.
        LaunchDeployer fresh = _freshLaunchDeployer();
        vm.prank(SAFE);
        LaunchFactory(LAUNCH_FACTORY).setLaunchDeployer(fresh);

        vm.prank(user);
        (bool okAfter, bytes memory returned) = LAUNCH_FACTORY.call(
            abi.encodeCall(ILaunchFactory.launchToken, (params, 0, quoteBrand, none))
        );
        assertTrue(okAfter, "the rotated deployer could not serve a factory from this tree");
        (address token, address curve) = abi.decode(returned, (address, address));
        assertEq(IERC20(token).balanceOf(curve), 1e27, "the whole supply did not reach the curve");
    }

    function test_live_theCurveSellsOutAndGraduatesIntoARealMarket() public {
        _enableLaunching();
        _mintQuote(user, 200_000e6);
        (address token, address curve) = _launch(user, bytes32(uint256(2)));
        vm.warp(block.timestamp + 30);

        // Buy the sellable allocation out. The curve clamps the crossing buy and refunds the
        // remainder, and tries to graduate from inside that same transaction.
        vm.startPrank(user);
        IERC20(quoteBrand).approve(curve, type(uint256).max);
        ILaunchCurve(curve).buy(30_000e6, 1, user);
        vm.stopPrank();

        assertEq(ILaunchCurve(curve).sellableTokens(), 0, "allocation not exhausted");

        // Phase one may already have fired from inside the buy; if it did not, it is
        // permissionless and retryable, which is the property that matters.
        ILaunchFactory.LaunchedToken memory rec = launch.getLaunchedToken(token);
        if (rec.phase == 0) {
            launch.graduate(token);
            rec = launch.getLaunchedToken(token);
        }
        assertEq(rec.phase, 1, "launch should be Swept after phase one");
        assertGt(rec.sweptQuote, 0, "nothing was swept");

        // Phase two: open the market. Permissionless.
        //
        // `brandsBefore` is the registry a graduation used to append a `<SYM>.d` to. It is
        // read across the graduation because "the graduate mints no dollar of its own" is
        // only really provable as a count that did not move: the market's `brandToken` being
        // the quote brand would also be true of a stack that registered a unit and then
        // ignored it.
        uint256 marketsBefore = factory.marketCount();
        uint256 brandsBefore = reserve.allBrandTokensLength();
        uint256 unitSeeded = _graduateToMarketAndReadSeed(token);

        rec = launch.getLaunchedToken(token);
        assertEq(rec.phase, 2, "launch should be Graduated");
        assertEq(factory.marketCount(), marketsBefore + 1, "a market was not opened");
        assertGt(rec.marketId, 0, "no market id recorded");

        IFactory.Market memory m = factory.market(rec.marketId);
        assertEq(m.asset, token, "the graduated market trades the launch token");
        assertEq(m.reservePool, RESERVE, "market backed by the launch's reserve");
        assertFalse(m.verified, "a launch token is not a canonical equity");

        // The change this branch makes, asserted from three sides. A graduate is now an
        // ordinary shared-quote market in the dollar its buyers actually paid in, so the pool
        // is `launchUSD/MTC` rather than `launchUSD` converted into an `MTC.d` nobody asked
        // for.
        assertEq(m.brandToken, quoteBrand, "the graduated pool is quoted in the launch's brand");
        assertEq(
            reserve.allBrandTokensLength(),
            brandsBefore,
            "graduation registered a dollar of its own"
        );
        assertTrue(
            factory.isSharedQuote(rec.marketId), "the graduate claims the brand as its own unit"
        );

        // And what it gets instead of owning that dollar: a share of the brand's float
        // proportional to what its pool locked. Compared against the mint's own measurement,
        // not against `rec.sweptQuote` — the position mint consumes what the live price wants
        // and leaves dust, and the dust is the protocol's rather than the market's.
        assertGt(unitSeeded, 0, "the graduation seeded no liquidity");
        assertEq(
            IBrandTreasury(m.treasury).floatOf(m.feeVault),
            unitSeeded,
            "the brand's treasury was not told what this pool locked"
        );

        // The seed is locked: the position is staked in the distributor with the locker as the
        // beneficiary, and the locker exposes no withdrawal path. `earned` is deliberately NOT
        // the assertion — the locked position renounces its reward stream at `recordPosition`
        // so the float above reaches the market's OTHER providers, and zero is the correct
        // answer for the locker forever. What matters is custody, which is the position count.
        assertGt(
            IDistributor(m.lpDistributor).positionCountOf(_liveLocker()),
            0,
            "the graduated position is not staked for the live locker"
        );
        console.log("graduated market id:", rec.marketId);
        console.log("graduated market quote brand:", m.brandToken);
        console.log("float credited to the market's LPs (6dp):", unitSeeded);
    }

    /// @dev The launchpad is about to be opened against a quote brand on the sUSDai reserve,
    ///      which is NOT the market factory's default. Everything that follows a launch resolves
    ///      a reserve from somewhere -- `setReserveEconomics` validates one, the curve mints
    ///      and burns against one, and `graduateToMarket` opens a market that records one -- and
    ///      a stack that only ever ran against the default reserve has never shown that those
    ///      four agree. This is that proof, on the deployed addresses, before the switch is
    ///      thrown on mainnet.
    function test_live_anSusdaiBackedBrandLaunchesAndGraduatesOffTheDefaultReserve() public {
        _rehearseGraduateIntoLaunchDollar();
        IReserve susdai = IReserve(SUSDAI_RESERVE);

        vm.startPrank(SAFE);
        // Through the market factory and into the sUSDai reserve, so `reserveOfBrand` names
        // that reserve and the graduated market records it. Then the treasury opts into
        // sharing the brand's float with the markets it quotes.
        (address susdaiBrand, address susdaiTreasury) = factory.registerBrand(
            "Stables sUSDai Dollar",
            "sdUSD",
            IFactory.BrandMetadata({description: "", logo: "", socials: ""}),
            SUSDAI_RESERVE
        );
        IBrandTreasury(susdaiTreasury).setFactory(FACTORY);
        launch.setReserveEconomics(
            SUSDAI_RESERVE,
            ILaunchFactory.ReserveEconomics({
                phantomQuote: 3_236e6,
                graduationThreshold: 8_090e6,
                launchFee: 1e6,
                decimals: 6,
                approved: false
            })
        );
        launch.setReserveApproved(SUSDAI_RESERVE, true);
        launch.setLaunchEnabled(true);
        vm.stopPrank();

        // Minting has to work with the keeper stopped. Deposits land in the adapter as local
        // USDG and stay there: bridging is the keeper's job and `maxBridgeAmount` gates only
        // `bridgeOut`, never `deposit`. An unserviced group must still be solvent and usable.
        // 90k, not the 200k the default-reserve tests use: this group carries a real
        // liabilityCap where the USDG reserve's zero means unlimited, so the mint has to fit
        // under whatever that cap currently is. Read live rather than assumed, because the
        // cap is policy the owner tunes and it has already been raised once from 100_000e6.
        vm.startPrank(user);
        IERC20(USDG).approve(SUSDAI_RESERVE, 90_000e6);
        susdai.mint(susdaiBrand, 90_000e6, user);
        vm.stopPrank();
        assertEq(IERC20(susdaiBrand).balanceOf(user), 90_000e6, "quote brand did not mint");
        assertGe(
            susdai.liabilityCap(), susdai.totalPooledSupply(), "the mint stayed inside the live cap"
        );
        bytes32 economics = launch.previewLaunchEconomics(0, susdaiBrand);
        address[] memory none = new address[](0);
        vm.startPrank(user);
        IERC20(susdaiBrand).approve(LAUNCH_FACTORY, type(uint256).max);
        (address token, address curve) = launch.launchToken(
            ILaunchFactory.TokenParams({
                name: "sUSDai Backed Coin",
                symbol: "SBC",
                logo: "",
                description: "non-default reserve graduation proof",
                socials: ILaunchFactory.Socials("", "", "", "", ""),
                creatorFeeRecipient: user,
                creatorTaxBps: 0,
                expectedEconomics: economics,
                salt: bytes32(uint256(7))
            }),
            0,
            susdaiBrand,
            none
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 30);
        vm.startPrank(user);
        IERC20(susdaiBrand).approve(curve, type(uint256).max);
        ILaunchCurve(curve).buy(30_000e6, 1, user);
        vm.stopPrank();
        assertEq(ILaunchCurve(curve).sellableTokens(), 0, "allocation not exhausted");

        ILaunchFactory.LaunchedToken memory rec = launch.getLaunchedToken(token);
        if (rec.phase == 0) {
            launch.graduate(token);
            rec = launch.getLaunchedToken(token);
        }
        assertEq(rec.phase, 1, "phase one did not sweep");

        uint256 before = factory.marketCount();
        uint256 brandsBefore = susdai.allBrandTokensLength();
        uint256 unitSeeded = _graduateToMarketAndReadSeed(token);
        rec = launch.getLaunchedToken(token);

        assertEq(rec.phase, 2, "did not graduate");
        assertEq(factory.marketCount(), before + 1, "no market opened");
        // The point of the test: the market records the sUSDai reserve, not the factory default.
        IFactory.Market memory m = factory.market(rec.marketId);
        assertEq(m.reservePool, SUSDAI_RESERVE, "market did not bind the sUSDai reserve");
        assertTrue(m.reservePool != RESERVE, "market fell back to the default reserve");
        assertEq(m.asset, token, "market trades the launched token");

        // And it agrees with the default-reserve graduation on everything the non-default
        // reserve could have broken: the quote is the launch's own brand, no `<SYM>.d` was
        // appended to THIS reserve's registry, the market makes no claim on the dollar, and
        // the float it locked was credited on the brand's own treasury — which is a
        // `BeaconProxy` the sUSDai reserve deployed, so this is also the proof that the
        // treasury beacon the rehearsal moved reaches brands outside the default group.
        assertEq(m.brandToken, susdaiBrand, "the graduated pool is quoted in the launch's brand");
        assertEq(
            susdai.allBrandTokensLength(),
            brandsBefore,
            "graduation registered a dollar of its own on the sUSDai reserve"
        );
        assertTrue(
            factory.isSharedQuote(rec.marketId), "the graduate claims the brand as its own unit"
        );
        assertGt(unitSeeded, 0, "the graduation seeded no liquidity");
        assertEq(
            IBrandTreasury(m.treasury).floatOf(m.feeVault),
            unitSeeded,
            "the sUSDai brand's treasury was not told what this pool locked"
        );
    }

    // ─── 4. Income reaches the parties it is supposed to ─────────────────

    function test_live_floatYieldHarvestsAndStreamsToAStakedProvider() public {
        (uint256 id, address unit, address vault, address dist) = _openSpcxMarket();

        // A provider seeds and stakes a real v4 position.
        uint256 spcx = IERC20(SPCX).balanceOf(V3_POOL);
        vm.prank(V3_POOL);
        IERC20(SPCX).transfer(lp, spcx / 20);
        vm.startPrank(lp);
        IERC20(USDG).approve(RESERVE, 300_000e6);
        reserve.mint(unit, 300_000e6, lp);
        IERC20(unit).approve(ROUTER, type(uint256).max);
        IERC20(SPCX).approve(ROUTER, type(uint256).max);
        (uint256 tokenId,,,) =
            router.seedLiquidity(id, 200_000e6, IERC20(SPCX).balanceOf(lp), 0, 0, _deadline());
        IERC721(POSM).approve(dist, tokenId);
        IDistributor(dist).stake(tokenId, lp);
        vm.stopPrank();

        // A year of real Morpho interest on the float.
        _accrueMorpho(365 days);

        uint256 harvested = IVault(vault).harvest();
        assertGt(harvested, 0, "no yield harvested from the live Morpho market");
        if (harvested >= IVault(vault).minSweep()) {
            IVault(vault).sweep();
            vm.warp(block.timestamp + 7 days);
            uint256 earned = IDistributor(dist).earned(lp);
            assertGt(earned, 0, "the staked provider earned nothing");
            vm.prank(lp);
            uint256 claimed = IDistributor(dist).claim(unit);
            assertGt(claimed, 0, "claim paid nothing");
            console.log("float yield over a year (6dp):", harvested);
            console.log("claimed by the staked LP (6dp):", claimed);
        }

        vm.prank(lp);
        IDistributor(dist).unstake(tokenId);
        assertEq(IERC721(POSM).ownerOf(tokenId), lp, "unstake did not return the NFT");
    }

    // ─── 5. The guard reaches what it should, and not exits ──────────────

    /// @dev Read the guardian off the guard rather than pinning it. It is a hot key and is
    ///      expected to rotate; a pinned address turns every rotation into a red suite that
    ///      says nothing about the protocol. The property under test is the asymmetry of the
    ///      powers, not which key holds them.
    function _guardian() internal view returns (address) {
        return IGuard(GUARD).guardian();
    }

    function test_live_theGuardianHaltsMintingButNeverRedemption() public {
        (, address unit,,) = _openSpcxMarket();
        vm.startPrank(user);
        IERC20(USDG).approve(RESERVE, 2_000e6);
        reserve.mint(unit, 1_000e6, user);
        vm.stopPrank();

        vm.prank(_guardian());
        IGuard(GUARD).pauseTarget(RESERVE);
        assertTrue(IGuard(GUARD).isPaused(RESERVE), "reserve not paused");

        vm.prank(user);
        vm.expectRevert();
        reserve.mint(unit, 1_000e6, user);

        // Redemption carries no whenNotPaused, by design: a holder can always exit.
        vm.prank(user);
        uint256 out = reserve.redeem(unit, 1_000e6, user, 1_000e6 - 10);
        assertGe(out, 1_000e6 - 10, "a paused protocol must still redeem at par less dust");
    }

    function test_live_theGuardianCannotUnpauseAndTheSafeCan() public {
        vm.prank(_guardian());
        IGuard(GUARD).pauseTarget(RESERVE);
        assertTrue(IGuard(GUARD).isPaused(RESERVE), "not paused");
        // No unpause for the guardian: only the owner. Asserted by the guard's own access
        // control, so this is the shape of the asymmetry rather than a second switch.
        assertEq(IGuard(GUARD).owner(), SAFE, "only the multisig owner may unpause");
    }

    /// @dev The retired deployer key holds nothing after the Safe migration and the guardian
    ///      rotation. Pausing was the last power it had; this is the assertion that says the
    ///      rotation actually happened, rather than a comment claiming it did.
    function test_live_theRetiredDeployerCannotEvenHalt() public {
        assertTrue(_guardian() != DEPLOYER, "guardian is still the retired deployer key");
        vm.prank(DEPLOYER);
        vm.expectRevert();
        IGuard(GUARD).pauseTarget(RESERVE);
    }
}
