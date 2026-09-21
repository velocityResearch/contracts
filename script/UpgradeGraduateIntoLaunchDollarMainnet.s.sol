// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {AssetMarketFactory} from "../src/markets/AssetMarketFactory.sol";
import {BrandFeeVault} from "../src/markets/BrandFeeVault.sol";
import {LpRewardDistributor} from "../src/markets/LpRewardDistributor.sol";
import {LaunchFactory} from "../src/launchpad/LaunchFactory.sol";
import {LaunchGuardDeployer} from "../src/launchpad/libraries/LaunchGuardDeployer.sol";
import {LaunchGraduation} from "../src/launchpad/LaunchGraduation.sol";
import {GraduationPhase} from "../src/launchpad/interfaces/ILaunchpad.sol";
import {PoolBrandTreasury} from "../src/pool/PoolBrandTreasury.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";

/// @notice Graduate a launch into the dollar it was funded in. A graduated market stops minting
///         a `<SYM>.d` unit of its own and becomes an ordinary shared-quote market in the
///         launch's `pairToken`, so the seed liquidity it locks is AIUSD against the token
///         rather than a third dollar nobody asked for.
///
/// @dev    **Why the float has to be shared rather than harvested.** A market that mints its
///         own unit owns that unit's treasury, so its fee vault harvests the float behind the
///         dollars locked in its pool and streams them to its LPs. A market quoted in AIUSD
///         cannot: the float behind AIUSD belongs to AIUSD, to coins in wallets and to every
///         other pool quoting it, and no contract can divide it by reading a Uniswap v4
///         singleton. The treasury now keeps a per-vault float ledger — credited at graduation
///         by `AssetMarketFactory.recordLaunchFloat`, drawn by `claimFloatShare` — and
///         `BrandFeeVault.harvest` routes through it whenever the vault is not the treasury's
///         admin. That is the whole of what replaces the old manual top-up script, and it is
///         why the LP stream on a shared quote is now automatic like everywhere else.
///
///         **Six steps, and only one of them needs an issuer's consent.**
///
///         1. Upgrade the `AssetMarketFactory` proxy. `createLaunchMarket` takes the brand to
///            quote in and no longer returns a minted one, and `recordLaunchFloat` is new. No
///            storage moved — both are function-body changes plus one `onlyLaunchpad` entry
///            point — so `upgradeToAndCall` carries empty calldata deliberately.
///         2. Upgrade the `LaunchFactory` proxy. The float-yield rate is gone from it: a locked
///            position renounces its reward stream at `recordPosition`, so there is no yield
///            leg left for anyone to take a share of. Its 2 bytes stay behind as a private
///            retired field rather than being deleted, because `lpFundRecipient` sits after
///            them in the same packed slot and removing them would slide a live address two
///            bytes down. Nothing to initialise, so empty calldata again.
///         3. Upgrade the `PoolBrandTreasury`, `BrandFeeVault` and `LpRewardDistributor`
///            beacons. Every per-market vault and distributor, and every brand treasury of the
///            reserves these brands sit in, is a `BeaconProxy`, so one `upgradeTo` each moves
///            all of them at once. The treasury beacon is read off each brand's own reserve
///            rather than named here, because that is the contract that deployed it; the other
///            two are read off the market factory.
///         4. The rates, recipient first. Every share setter refuses a nonzero rate while
///            `lpFundRecipient` is unset, so that order is load-bearing rather than tidy. The
///            graduated pair ends at 40% creator / 30% LP fund / 30% protocol of the locked
///            position's LP fees, which is the only leg a graduated launch still has.
///         5. `PoolBrandTreasury.setFactory(assetMarketFactory)` for every live quote brand.
///            This is the issuer's opt-in to sharing the float of the markets their dollar
///            quotes, and it is `onlyAdmin`. It is checked per launch now rather than at
///            approval time — `launchEconomics` reverts `PairTokenFloatShareUnavailable` for a
///            brand whose treasury does not name the market factory — so it is still REQUIRED
///            for that brand to be launchable at all, and a market graduating into an unwired
///            brand would earn nothing on the float it locks. Nothing about the move to
///            per-reserve economics makes this step optional; it only moves when it bites.
///         6. `setReserveEconomics` once per reserve. The launch factory's economics mapping is
///            now keyed by the reserve rather than by the brand, and the new mapping is a fresh
///            slot appended below everything already written: after step 2 every reserve reads
///            zero, which is closed, and every launch reverts `ReserveClosed` until this runs.
///            One call per reserve re-opens every brand of it, including the ones the old
///            per-brand mapping listed and any dollar issued afterwards. It is last because it
///            is the step that re-opens the platform, and it should not re-open ahead of the
///            float-share opt-in in step 5.
///
///            **slUSD is not closed by hand, and cannot be.** Under the old mapping a
///            deliberately-retired dollar was shut by flipping its own approval flag off.
///            Approval has no per-brand key any more and that setter is retired, so there is
///            nothing left to flip and no way to close one brand of an open reserve. slUSD
///            needs none: it was registered straight on its reserve and never through the
///            market factory, so `reserveOfBrand(slUSD)` is the zero address and
///            `launchEconomics(slUSD)` reverts `PairTokenNotRegistered` before any approval is
///            consulted. Opening its reserve here does not open slUSD.
///
///         **This deliberately does NOT deploy `LaunchGraduation` or `LaunchLocker`, and the
///         window it opens is a real one.** Neither is upgradeable — that is what makes "the
///         liquidity is locked forever" a property of the bytecode rather than a promise — so
///         both arrive as a fresh deployment from a separate step, which then points
///         `LaunchFactory.setGraduation` and `AssetMarketFactory.setLaunchpad` at the new
///         module. `LaunchLocker.setGraduation` is one-shot, so a new graduation module always
///         needs a new locker beside it; the old locker keeps holding and paying the three
///         positions already staked under it (markets 16, 17 and 18), on the terms their
///         records were snapshotted with, and no function moves a position between lockers.
///
///         Until that step lands, graduation is CLOSED: `createLaunchMarket`'s signature
///         changed in step 1 and the live module still calls the old one, so phase two would
///         revert. Curves keep trading and keep filling. That is why this refuses to run while
///         a launch is mid-graduation — a swept launch's retry would be executed against a
///         factory that no longer answers the call it makes.
///
///         The proxies and the beacons are owned by the deployer EOA with no timelock, so
///         every step here takes effect the moment it is mined.
///
///         **The fresh `LaunchFactory` implementation needs `LaunchGuardDeployer` linked.**
///         That external library holds `LaunchGraduationGuard`'s creation code so the factory
///         fits under EIP-170; forge deploys and links it as part of this broadcast, and the
///         address is printed for the manifest. Pin an existing one with
///         `--libraries src/launchpad/libraries/LaunchGuardDeployer.sol:LaunchGuardDeployer:<addr>`.
///         The assertion below runs before `startBroadcast`, because an unlinked build
///         simulates cleanly all the way through `upgradeToAndCall` — the live proxy is
///         already initialised, so nothing here would touch the dead delegatecall, and the
///         breakage would only surface on the next fresh deployment.
///
///         Usage:
///           DEPLOYER=0x… PRIVATE_KEY=0x… \
///             forge script script/UpgradeGraduateIntoLaunchDollarMainnet.s.sol:UpgradeGraduateIntoLaunchDollarMainnet \
///             --rpc-url robinhood --broadcast --slow
///
///         Environment:
///         - DEPLOYER                 required. Owns both proxies and all three beacons, and
///                                    must be the admin of every quote brand's treasury.
///         - LAUNCH_LP_FUND_RECIPIENT optional. Defaults to the market factory's
///                                    `protocolTreasury`, which is where the fund's share is
///                                    held while its mandate is decided.
///         - QUOTE_BRANDS             optional, comma-separated. Brands to wire on top of the
///                                    ones the live launches name. See `_quoteBrands`.
contract UpgradeGraduateIntoLaunchDollarMainnet is Script {
    address constant LAUNCH_FACTORY = 0x95fe000285DA7797cC01394cCc410628B26e898d;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The creator's share of a graduated position's LP fees, snapshotted per launch.
    ///         Unchanged from the live value; written again so a run configures the whole split
    ///         rather than half of it.
    uint16 constant GRADUATED_CREATOR_SHARE_BPS = 4_000;
    /// @notice The LP fund's share of the same leg, subtracted from the protocol's remainder.
    uint16 constant GRADUATED_LP_FUND_SHARE_BPS = 3_000;

    /// @notice The curve every brand of an opened reserve launches on, in the reserve asset's
    ///         own decimals. These are the shipped figures, re-stated rather than carried over:
    ///         the economics mapping is re-keyed by this upgrade, so there is no live entry at
    ///         the new key to read and the terms have to be named somewhere. Only
    ///         `graduationThreshold / (graduationThreshold + phantomQuote)` sets the fraction of
    ///         supply that reaches the graduated pool, so the pair moves together or not at all.
    uint256 constant PHANTOM_QUOTE = 3_236e6;
    uint256 constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 constant LAUNCH_FEE = 1e6;
    uint8 constant QUOTE_DECIMALS = 6;

    /// @dev Everything read off the live contracts before the upgrade, so the post-checks
    ///      compare against what was actually there rather than against a constant in this file.
    struct Before {
        address launchImplementation;
        address marketImplementation;
        address marketFactory;
        address feeEscrow;
        address launchDeployer;
        address positionManager;
        address launchForwarder;
        address protocolFeeRecipient;
        address graduation;
        address locker;
        address launchpadOnMarketFactory;
        address protocolTreasury;
        address lpFundRecipient;
        uint16 graduatedCreatorShareBps;
        uint16 graduatedLpFundShareBps;
        bool launchEnabled;
        uint256 launchCount;
        uint256 marketCount;
    }

    /// @dev The implementations behind the three beacons, before they move. Held separately
    ///      from `Before` because the treasury beacon list is discovered rather than fixed.
    struct BeaconSet {
        address[] treasury;
        address vault;
        address distributor;
        address[] treasuryImplementation;
        address vaultImplementation;
        address distributorImplementation;
    }

    function run() external {
        require(block.chainid == 4663, "mainnet only");
        address deployer = vm.envAddress("DEPLOYER");

        LaunchFactory factory = LaunchFactory(LAUNCH_FACTORY);
        Before memory was = _read(factory);
        AssetMarketFactory marketFactory = AssetMarketFactory(was.marketFactory);
        address lpFund = vm.envOr("LAUNCH_LP_FUND_RECIPIENT", was.protocolTreasury);
        require(lpFund != address(0), "no LP fund recipient, and the factory names no treasury");

        address[] memory brands = _quoteBrands(factory, was.launchCount);
        address[] memory treasuries = _treasuries(marketFactory, brands);
        address[] memory reserves = _reserves(marketFactory, brands);
        BeaconSet memory beacons = _beacons(marketFactory, reserves);

        // Every authority this run needs, checked before a single implementation is deployed:
        // a half-applied upgrade of a stack whose parts read each other is worse than a run
        // that never started.
        require(factory.owner() == deployer, "signer does not own the launch factory");
        require(marketFactory.owner() == deployer, "signer does not own the market factory");
        _requireBeaconOwners(beacons, deployer);
        _requireTreasuryAdmins(treasuries, marketFactory, deployer);
        _requireOpenableReserves(marketFactory, reserves);
        _requireNothingMidGraduation(factory, was.launchCount);
        // And the one dependency that is not an authority: the library the fresh
        // implementation delegatecalls from `initialize`. Unlinked, this run would broadcast a
        // perfectly plausible implementation that no future proxy could ever initialise.
        require(
            address(LaunchGuardDeployer).code.length > 0,
            "LaunchGuardDeployer library is not linked"
        );

        vm.startBroadcast(deployer);

        // 1 & 2. The proxies. No initializer on either: nothing was added, moved or retyped.
        address freshMarketImplementation = address(new AssetMarketFactory());
        marketFactory.upgradeToAndCall(freshMarketImplementation, "");
        address freshLaunchImplementation = address(new LaunchFactory());
        factory.upgradeToAndCall(freshLaunchImplementation, "");

        // 3. The beacons, one implementation each however many proxies hang off them.
        address freshTreasuryImplementation = address(new PoolBrandTreasury());
        for (uint256 i; i < beacons.treasury.length; ++i) {
            UpgradeableBeacon(beacons.treasury[i]).upgradeTo(freshTreasuryImplementation);
        }
        address freshVaultImplementation = address(new BrandFeeVault());
        UpgradeableBeacon(beacons.vault).upgradeTo(freshVaultImplementation);
        address freshDistributorImplementation = address(new LpRewardDistributor());
        UpgradeableBeacon(beacons.distributor).upgradeTo(freshDistributorImplementation);

        // 4. The recipient BEFORE any rate, and the fund's share before the creator's: the
        //    two are bounded jointly against a whole leg, and the live creator rate already
        //    leaves room for this fund rate, so this order needs no intermediate state.
        factory.setLpFundRecipient(lpFund);
        factory.setGraduatedLpFundShareBps(GRADUATED_LP_FUND_SHARE_BPS);
        factory.setGraduatedCreatorShareBps(GRADUATED_CREATOR_SHARE_BPS);

        // 5. The issuer's opt-in, once per brand. Skipped where it already names this factory,
        //    so a re-run after a partial broadcast sends nothing it does not have to.
        //    BEFORE step 6, because step 6 re-opens launching and a brand that reaches this
        //    run unwired should not be launchable in the same block it was upgraded in.
        for (uint256 i; i < treasuries.length; ++i) {
            if (PoolBrandTreasury(treasuries[i]).factory() != address(marketFactory)) {
                PoolBrandTreasury(treasuries[i]).setFactory(address(marketFactory));
            }
        }

        // 6. Re-open the platform, once per reserve rather than once per brand. Step 2 moved
        //    economics to a mapping keyed by the reserve, so every reserve reads closed until
        //    this lands. `approved: true` is written with the figures it is validated against.
        for (uint256 i; i < reserves.length; ++i) {
            factory.setReserveEconomics(
                reserves[i],
                LaunchFactory.ReserveEconomics({
                    phantomQuote: PHANTOM_QUOTE,
                    graduationThreshold: GRADUATION_THRESHOLD,
                    launchFee: LAUNCH_FEE,
                    decimals: QUOTE_DECIMALS,
                    approved: true
                })
            );
        }

        vm.stopBroadcast();

        _verify(factory, marketFactory, was, beacons, brands, treasuries, lpFund);
        _report(
            was,
            beacons,
            brands,
            treasuries,
            reserves,
            freshLaunchImplementation,
            freshMarketImplementation,
            lpFund
        );
    }

    function _read(LaunchFactory factory) internal view returns (Before memory was) {
        was.launchImplementation = address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))));
        was.marketFactory = address(factory.marketFactory());
        was.marketImplementation = address(uint160(uint256(vm.load(was.marketFactory, IMPL_SLOT))));
        was.feeEscrow = address(factory.feeEscrow());
        was.launchDeployer = address(factory.launchDeployer());
        was.positionManager = address(factory.positionManager());
        was.launchForwarder = factory.launchForwarder();
        was.protocolFeeRecipient = factory.protocolFeeRecipient();
        was.graduation = address(factory.graduation());
        // Read off the module rather than hardcoded, so the report names whatever the live
        // module actually holds.
        was.locker = address(LaunchGraduation(was.graduation).locker());
        was.lpFundRecipient = factory.lpFundRecipient();
        was.graduatedCreatorShareBps = factory.graduatedCreatorShareBps();
        was.graduatedLpFundShareBps = factory.graduatedLpFundShareBps();
        was.launchEnabled = factory.launchEnabled();
        was.launchCount = factory.launchCount();

        AssetMarketFactory marketFactory = AssetMarketFactory(was.marketFactory);
        was.launchpadOnMarketFactory = marketFactory.launchpad();
        was.protocolTreasury = marketFactory.protocolTreasury();
        was.marketCount = marketFactory.marketCount();
    }

    /// @dev Economics are keyed by reserve now, but the float-share opt-in of step 5 is still
    ///      per brand and lives on a treasury nothing enumerates, so the live set of quote
    ///      brands is still reconstructed: from the launches that name one, widened by
    ///      `QUOTE_BRANDS` for a brand that has never been launched against. It also supplies
    ///      the reserve set of step 6, which is this list deduplicated through
    ///      `reserveOfBrand`. Missing a brand is loud rather than silent: its treasury is left
    ///      unwired, so every launch against it reverts `PairTokenFloatShareUnavailable` on the
    ///      first attempt, not as a market that quietly earns nothing.
    function _quoteBrands(LaunchFactory factory, uint256 count)
        internal
        view
        returns (address[] memory brands)
    {
        address[] memory extra = vm.envOr("QUOTE_BRANDS", ",", new address[](0));
        address[] memory found = new address[](count + extra.length);
        uint256 n;

        for (uint256 i; i < count; ++i) {
            address brand = factory.getLaunchedToken(factory.launchAt(i)).pairToken;
            if (!_contains(found, n, brand)) found[n++] = brand;
        }
        for (uint256 i; i < extra.length; ++i) {
            require(extra[i] != address(0), "QUOTE_BRANDS holds the zero address");
            if (!_contains(found, n, extra[i])) found[n++] = extra[i];
        }
        require(n != 0, "no quote brand to wire; pass QUOTE_BRANDS");

        brands = new address[](n);
        for (uint256 i; i < n; ++i) {
            brands[i] = found[i];
        }
    }

    function _treasuries(AssetMarketFactory marketFactory, address[] memory brands)
        internal
        view
        returns (address[] memory treasuries)
    {
        treasuries = new address[](brands.length);
        for (uint256 i; i < brands.length; ++i) {
            treasuries[i] = marketFactory.treasuryOfBrand(brands[i]);
            // A brand registered straight on its reserve has no treasury here, and the launch
            // factory would refuse its economics for that reason alone. Stopped now rather
            // than discovered as a revert mid-broadcast.
            require(treasuries[i] != address(0), "a quote brand was not registered here");
        }
    }

    /// @dev The reserves behind the quote brands, deduplicated: several brands of one reserve
    ///      are the normal case and the reserve is what both the beacon walk and the economics
    ///      of step 6 are keyed by, so collapsing them here is what makes those one call each
    ///      rather than one per brand.
    function _reserves(AssetMarketFactory marketFactory, address[] memory brands)
        internal
        view
        returns (address[] memory reserves)
    {
        address[] memory found = new address[](brands.length);
        uint256 n;
        for (uint256 i; i < brands.length; ++i) {
            address reserve = marketFactory.reserveOfBrand(brands[i]);
            require(reserve != address(0), "a quote brand names no reserve");
            if (!_contains(found, n, reserve)) found[n++] = reserve;
        }

        reserves = new address[](n);
        for (uint256 i; i < n; ++i) {
            reserves[i] = found[i];
        }
    }

    /// @dev Everything `setReserveEconomics` will check, checked before the first
    ///      implementation is deployed. A reserve the market factory does not serve, or one
    ///      whose asset is not scaled the way the figures above are, would revert step 6 — and
    ///      step 6 is the step that re-opens the platform, so failing it mid-broadcast leaves
    ///      an upgraded stack that nobody can launch on.
    function _requireOpenableReserves(AssetMarketFactory marketFactory, address[] memory reserves)
        internal
        view
    {
        for (uint256 i; i < reserves.length; ++i) {
            require(
                reserves[i] == address(marketFactory.reservePool())
                    || marketFactory.approvedReservePool(reserves[i]),
                "a quote brand's reserve is not served by the market factory"
            );
            require(
                SharedReservePool(reserves[i]).assetDecimals() == QUOTE_DECIMALS,
                "a quote brand's reserve is not scaled to the economics above"
            );
        }
    }

    /// @dev The treasury beacon is read off each reserve, which is the contract that deployed
    ///      the treasury, rather than named as a constant: two reserves sharing one beacon is
    ///      the live arrangement but not a property anything enforces. The other two beacons
    ///      belong to the market factory, which stamps them into every market.
    function _beacons(AssetMarketFactory marketFactory, address[] memory reserves)
        internal
        view
        returns (BeaconSet memory set)
    {
        address[] memory found = new address[](reserves.length);
        uint256 n;
        for (uint256 i; i < reserves.length; ++i) {
            address beacon = SharedReservePool(reserves[i]).treasuryBeacon();
            if (!_contains(found, n, beacon)) found[n++] = beacon;
        }

        set.treasury = new address[](n);
        set.treasuryImplementation = new address[](n);
        for (uint256 i; i < n; ++i) {
            set.treasury[i] = found[i];
            set.treasuryImplementation[i] = UpgradeableBeacon(found[i]).implementation();
        }

        (set.vault, set.distributor) = marketFactory.beacons();
        set.vaultImplementation = UpgradeableBeacon(set.vault).implementation();
        set.distributorImplementation = UpgradeableBeacon(set.distributor).implementation();
    }

    function _requireBeaconOwners(BeaconSet memory beacons, address deployer) internal view {
        for (uint256 i; i < beacons.treasury.length; ++i) {
            require(
                UpgradeableBeacon(beacons.treasury[i]).owner() == deployer,
                "signer does not own a treasury beacon"
            );
        }
        require(
            UpgradeableBeacon(beacons.vault).owner() == deployer,
            "signer does not own the fee vault beacon"
        );
        require(
            UpgradeableBeacon(beacons.distributor).owner() == deployer,
            "signer does not own the distributor beacon"
        );
    }

    /// @dev `setFactory` is `onlyAdmin` — the issuer's, not the protocol's — so a brand whose
    ///      treasury answers to someone else is a conversation and not a transaction. Refused
    ///      up front unless it is already wired, because the alternative is an upgraded stack
    ///      with a quote brand nobody can write economics for.
    function _requireTreasuryAdmins(
        address[] memory treasuries,
        AssetMarketFactory marketFactory,
        address deployer
    ) internal view {
        for (uint256 i; i < treasuries.length; ++i) {
            PoolBrandTreasury treasury = PoolBrandTreasury(treasuries[i]);
            if (treasury.factory() == address(marketFactory)) continue;
            if (treasury.admin() == deployer) continue;
            console.log("Treasury this signer cannot wire:", treasuries[i]);
            console.log("  its admin:", treasury.admin());
            revert("a quote brand's treasury has another admin; it must call setFactory itself");
        }
    }

    /// @dev A launch in `Swept` has had its reserves taken into the launch factory and waits on
    ///      a permissionless `graduateToMarket` retry. That retry runs through the module wired
    ///      right now, which calls the `createLaunchMarket` this upgrade replaces, so leaving
    ///      one open here turns a two-phase operation into a stuck one. The retry is
    ///      permissionless, so clearing this costs a single call from anyone.
    function _requireNothingMidGraduation(LaunchFactory factory, uint256 count) internal view {
        for (uint256 i; i < count; ++i) {
            address token = factory.launchAt(i);
            if (factory.getLaunchedToken(token).phase == GraduationPhase.Swept) {
                console.log("Mid-graduation, seed it before upgrading:", token);
                revert("a launch is swept but not seeded; call graduateToMarket first");
            }
        }
    }

    function _verify(
        LaunchFactory factory,
        AssetMarketFactory marketFactory,
        Before memory was,
        BeaconSet memory beacons,
        address[] memory brands,
        address[] memory treasuries,
        address lpFund
    ) internal view {
        require(
            address(uint160(uint256(vm.load(LAUNCH_FACTORY, IMPL_SLOT))))
                != was.launchImplementation,
            "the launch factory proxy did not move"
        );
        require(
            address(uint160(uint256(vm.load(was.marketFactory, IMPL_SLOT))))
                != was.marketImplementation,
            "the market factory proxy did not move"
        );

        // Read back through the proxies, not from this script's memory: the point is that the
        // storage behind them still answers, which is what a layout mistake would break.
        require(address(factory.marketFactory()) == was.marketFactory, "market factory moved");
        require(address(factory.feeEscrow()) == was.feeEscrow, "fee escrow moved");
        require(address(factory.launchDeployer()) == was.launchDeployer, "launch deployer moved");
        require(address(factory.positionManager()) == was.positionManager, "posm moved");
        require(factory.launchForwarder() == was.launchForwarder, "forwarder moved");
        require(factory.protocolFeeRecipient() == was.protocolFeeRecipient, "recipient moved");
        require(factory.launchEnabled() == was.launchEnabled, "launchEnabled moved");
        require(factory.launchCount() == was.launchCount, "launch count moved");
        require(marketFactory.marketCount() == was.marketCount, "market count moved");
        require(marketFactory.protocolTreasury() == was.protocolTreasury, "treasury moved");
        // The graduation module is repointed by the separate redeploy, not here. If this moved,
        // two steps are racing each other.
        require(
            address(factory.graduation()) == was.graduation
                && marketFactory.launchpad() == was.launchpadOnMarketFactory,
            "the graduation module moved under this run"
        );

        _verifyBeacons(beacons);

        require(factory.lpFundRecipient() == lpFund, "LP fund recipient not applied");
        require(
            factory.graduatedCreatorShareBps() == GRADUATED_CREATOR_SHARE_BPS,
            "graduated creator share not applied"
        );
        require(
            factory.graduatedLpFundShareBps() == GRADUATED_LP_FUND_SHARE_BPS,
            "graduated fund share not applied"
        );
        // The invariant the locker's split depends on, asserted here so a bad pair is caught by
        // this script rather than by the first collect after it.
        require(
            uint256(factory.graduatedCreatorShareBps()) + factory.graduatedLpFundShareBps()
                <= 10_000,
            "graduated split exceeds a whole leg"
        );

        for (uint256 i; i < treasuries.length; ++i) {
            require(
                PoolBrandTreasury(treasuries[i]).factory() == address(marketFactory),
                "a quote brand's treasury does not name the market factory"
            );
        }

        // Read the economics back through the brands rather than through the reserves. Every
        // reserve written above came from this list, so the coverage is the same, and going
        // through `launchEconomics` also runs the two per-brand conditions — registration and
        // the float-share opt-in — so this proves the brands are launchable rather than that a
        // mapping entry was written.
        for (uint256 i; i < brands.length; ++i) {
            (, LaunchFactory.ReserveEconomics memory economics) = factory.launchEconomics(brands[i]);
            require(economics.approved, "a quote brand's reserve did not end up open");
            require(economics.phantomQuote == PHANTOM_QUOTE, "phantom quote did not take");
            require(economics.graduationThreshold == GRADUATION_THRESHOLD, "threshold did not take");
            require(economics.launchFee == LAUNCH_FEE, "launch fee did not take");
            require(economics.decimals == QUOTE_DECIMALS, "decimals did not take");
        }
    }

    function _verifyBeacons(BeaconSet memory beacons) internal view {
        for (uint256 i; i < beacons.treasury.length; ++i) {
            address implementation = UpgradeableBeacon(beacons.treasury[i]).implementation();
            require(
                implementation != beacons.treasuryImplementation[i],
                "a treasury beacon did not move"
            );
            require(implementation.code.length > 0, "a treasury implementation has no code");
        }
        address vault = UpgradeableBeacon(beacons.vault).implementation();
        require(vault != beacons.vaultImplementation, "the fee vault beacon did not move");
        require(vault.code.length > 0, "the fee vault implementation has no code");
        address distributor = UpgradeableBeacon(beacons.distributor).implementation();
        require(
            distributor != beacons.distributorImplementation, "the distributor beacon did not move"
        );
        require(distributor.code.length > 0, "the distributor implementation has no code");
    }

    function _report(
        Before memory was,
        BeaconSet memory beacons,
        address[] memory brands,
        address[] memory treasuries,
        address[] memory reserves,
        address launchImplementation,
        address marketImplementation,
        address lpFund
    ) internal view {
        console.log("LaunchFactory proxy:     ", LAUNCH_FACTORY);
        console.log("  implementation before: ", was.launchImplementation);
        console.log("  implementation after:  ", launchImplementation);
        console.log("  runtime size (bytes):  ", launchImplementation.code.length);
        console.log("  LaunchGuardDeployer (library, linked, RECORD THIS):");
        console.log("   ", address(LaunchGuardDeployer));
        console.log("AssetMarketFactory proxy:", was.marketFactory);
        console.log("  implementation before: ", was.marketImplementation);
        console.log("  implementation after:  ", marketImplementation);
        console.log("");
        for (uint256 i; i < beacons.treasury.length; ++i) {
            console.log("PoolBrandTreasury beacon:", beacons.treasury[i]);
            console.log("  was:", beacons.treasuryImplementation[i]);
            console.log("  now:", UpgradeableBeacon(beacons.treasury[i]).implementation());
        }
        console.log("BrandFeeVault beacon:", beacons.vault);
        console.log("  was:", beacons.vaultImplementation);
        console.log("  now:", UpgradeableBeacon(beacons.vault).implementation());
        console.log("LpRewardDistributor beacon:", beacons.distributor);
        console.log("  was:", beacons.distributorImplementation);
        console.log("  now:", UpgradeableBeacon(beacons.distributor).implementation());
        console.log("");
        console.log("Quote brands wired to the market factory:");
        for (uint256 i; i < brands.length; ++i) {
            console.log("  brand:", brands[i]);
            console.log("    treasury:", treasuries[i]);
        }
        console.log("");
        console.log("Reserves opened for launches. Every brand the market factory registered on");
        console.log("one of these launches on these terms, including dollars issued later:");
        for (uint256 i; i < reserves.length; ++i) {
            console.log("  reserve:", reserves[i]);
        }
        console.log("  phantom quote:", PHANTOM_QUOTE);
        console.log("  graduation threshold:", GRADUATION_THRESHOLD);
        console.log("  launch fee:", LAUNCH_FEE);
        console.log("");
        console.log("Graduated LP fees, per 10,000:");
        console.log(
            "  creator (was", was.graduatedCreatorShareBps, "):", GRADUATED_CREATOR_SHARE_BPS
        );
        console.log(
            "  LP fund (was", was.graduatedLpFundShareBps, "):", GRADUATED_LP_FUND_SHARE_BPS
        );
        console.log("  protocol takes the remainder.");
        console.log("LP fund recipient (was", was.lpFundRecipient, "):", lpFund);
        console.log("There is no float-yield leg: a locked position renounces its rewards, so");
        console.log("a graduated market's float is paid entirely to its LPs.");
        console.log("");
        console.log("############################################################");
        console.log("## GRADUATION IS CLOSED UNTIL THE MODULE IS REDEPLOYED.   ##");
        console.log("############################################################");
        console.log("LaunchGraduation and LaunchLocker are not upgradeable. Deploy the pair,");
        console.log("then point both sides at it:");
        console.log("  LaunchFactory.setGraduation(<newGraduation>)");
        console.log("  AssetMarketFactory.setLaunchpad(<newGraduation>)");
        console.log("The locker's setGraduation is one-shot, so the new module needs a new");
        console.log("locker. The old locker keeps serving the positions already staked in it:");
        console.log("  graduation module:", was.graduation);
        console.log("  locker:", was.locker);
        console.log("  launchCount:", was.launchCount);
    }

    function _contains(address[] memory list, uint256 length, address needle)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < length; ++i) {
            if (list[i] == needle) return true;
        }
        return false;
    }
}
