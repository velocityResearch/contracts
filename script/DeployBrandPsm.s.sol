// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {BrandPsm} from "../src/pool/BrandPsm.sol";
import {BrandPsmFactory} from "../src/pool/BrandPsmFactory.sol";
import {SharedReservePool} from "../src/pool/SharedReservePool.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @title DeployBrandPsm
/// @notice Open one `BrandPsm` window per brand on a `SharedReservePool`, behind one
///         `BrandPsmFactory`.
///
///         **This changes nothing that is already deployed.** A `BrandPsm` has no owner, no
///         initializer and no privileged caller, and the factory is permissionless and
///         ownerless. Nothing here calls the reserve, the market factory or the launchpad; no
///         parameter moves. What the run produces is an address an aggregator that already
///         integrates MakerDAO's `DssLitePsm` can point at to reach the reserve's 1:1
///         mint/redeem without writing a new venue.
///
///         Usage, against the recorded gen-6 stack (the defaults below are the sUSDai reserve
///         and its four brands, so the reserve and brand list may be omitted entirely):
///
///         PRIVATE_KEY=0x... forge script script/DeployBrandPsm.s.sol --rpc-url robinhood --broadcast
///
///         Environment variables:
///         - PRIVATE_KEY        deployer key (required)
///         - RESERVE_POOL       the `SharedReservePool` to open windows onto. Defaults to the
///                              sUSDai reserve `0xCFa8…33B2`. The default USDG/Morpho reserve
///                              is `0xdB48…d9F3` and has its own brands; pass it explicitly
///                              together with its own BRAND_TOKENS.
///         - BRAND_TOKENS       comma-separated brand token addresses. Defaults to the four
///                              brands registered on the sUSDai reserve. Whitespace around a
///                              comma is tolerated. A brand not registered on RESERVE_POOL is
///                              refused before anything is broadcast.
///         - BRAND_PSM_FACTORY  optional. An existing factory to open windows through instead
///                              of deploying one. This is what makes a re-run cheap: pass the
///                              factory already recorded in the manifest and only brands with
///                              no window yet are deployed. Unset deploys a fresh factory,
///                              whose index is empty, so every brand in the list is opened.
///
///         Re-running is safe either way: a brand that already has a window under the factory
///         in use is skipped, not reverted — `BrandPsmFactory.deploy` reverts `AlreadyDeployed`
///         and one already-open brand would otherwise abort the whole batch.
contract DeployBrandPsm is Script {
    /// @notice The sUSDai group's reserve — `susdaiGroup.reserve` in the gen-6 manifest. The
    ///         brands below are registered here and nowhere else.
    address internal constant SUSDAI_RESERVE = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;

    /// @notice Stables AI USD, the quote brand shared by markets 13, 14 and 15.
    address internal constant AIUSD = 0xE7BB388959d89f809BE24da16A1DaBa0dC58E596;
    /// @notice SDOGE.d — a graduated launchpad token's dollar.
    address internal constant SDOGE_D = 0xA138D500c4f96B6Fa319719bA325e6DE62C567b4;
    /// @notice ABR.d — a graduated launchpad token's dollar.
    address internal constant ABR_D = 0x1Aa1526302625de02791538DB45c45E96bb75A70;
    /// @notice CORGIGG.d — a graduated launchpad token's dollar.
    address internal constant CORGIGG_D = 0xe0588f17797e79B51a42CBE4bEbab0C1241F98a4;

    function run() external returns (BrandPsmFactory, address[] memory) {
        // The testnet is 46630 and mainnet is 4663. The defaults above are mainnet addresses
        // and nothing else, so a mistyped `--rpc-url` must refuse rather than deploy a factory
        // indexing windows onto contracts that do not exist there.
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        SharedReservePool reserve = SharedReservePool(vm.envOr("RESERVE_POOL", SUSDAI_RESERVE));
        address[] memory brands = vm.envOr("BRAND_TOKENS", ",", _defaultBrands());
        address existingFactory = vm.envOr("BRAND_PSM_FACTORY", address(0));

        console.log("=== Opening BrandPsm windows on Robinhood Chain mainnet ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Reserve:", address(reserve));
        console.log("Brands requested:", brands.length);
        console.log("");

        _preflight(reserve, brands);

        vm.startBroadcast(deployerKey);

        BrandPsmFactory factory;
        if (existingFactory == address(0)) {
            factory = new BrandPsmFactory();
            console.log("BrandPsmFactory (new):", address(factory));
        } else {
            factory = BrandPsmFactory(existingFactory);
            console.log("BrandPsmFactory (existing, from BRAND_PSM_FACTORY):", address(factory));
        }
        console.log("  windows already indexed:", factory.psmCount());
        console.log("");

        address[] memory windows = new address[](brands.length);
        for (uint256 i = 0; i < brands.length; ++i) {
            address brand = brands[i];
            string memory symbol = IERC20Metadata(brand).symbol();

            // Computed before the deploy, not after, so the number logged is a prediction the
            // deploy then has to match rather than a restatement of where it landed.
            address predicted = factory.predict(reserve, brand);
            address existing = factory.psmOf(address(reserve), brand);

            if (existing != address(0)) {
                windows[i] = existing;
                console.log(string.concat(symbol, " (", vm.toString(brand), ")"));
                console.log("  SKIPPED - window already open:", existing);
                console.log("  predicted:", predicted);
                continue;
            }

            windows[i] = factory.deploy(reserve, brand);
            console.log(string.concat(symbol, " (", vm.toString(brand), ")"));
            console.log("  BrandPsm: ", windows[i]);
            console.log("  predicted:", predicted);
        }

        vm.stopBroadcast();

        _assertWiring(factory, reserve, brands, windows);
        _report(factory, reserve, brands, windows);

        return (factory, windows);
    }

    /// @dev Everything that would otherwise surface as a revert in the middle of a broadcast
    ///      batch, with some windows already open and the operator reading a stack trace to
    ///      find out which brand did it. All pure reads, costing nothing but simulation time.
    function _preflight(SharedReservePool reserve, address[] memory brands) private view {
        require(address(reserve).code.length > 0, "RESERVE_POOL has no code");
        require(brands.length > 0, "BRAND_TOKENS is empty");

        uint8 gemDecimals = IERC20Metadata(address(reserve.asset())).decimals();
        console.log("Reserve asset (gem):", address(reserve.asset()));
        console.log("Reserve asset decimals:", gemDecimals);
        console.log("Reserve redemptionFeeBps:", reserve.redemptionFeeBps());

        for (uint256 i = 0; i < brands.length; ++i) {
            address brand = brands[i];
            require(brand != address(0), "BRAND_TOKENS contains the zero address");
            require(brand.code.length > 0, string.concat("brand has no code: ", vm.toString(brand)));
            // `BrandPsm`'s constructor enforces both of these. Repeating them here is what
            // turns a mid-broadcast `UnknownBrand(0x…)` into a refusal naming the brand by
            // symbol before the first transaction is signed.
            require(
                reserve.isRegistered(brand),
                string.concat(
                    "brand is not registered on this reserve: ",
                    IERC20Metadata(brand).symbol(),
                    " ",
                    vm.toString(brand)
                )
            );
            require(
                IERC20Metadata(brand).decimals() == gemDecimals,
                string.concat(
                    "brand decimals do not match the reserve asset: ",
                    IERC20Metadata(brand).symbol(),
                    " ",
                    vm.toString(brand)
                )
            );

            // A brand registered here and also already deployed with a window keeps its
            // window; this is only the pre-broadcast inventory of what the run will do.
            console.log(
                string.concat(
                    "Preflight OK: ", IERC20Metadata(brand).symbol(), " ", vm.toString(brand)
                )
            );
        }
        console.log("");
    }

    /// @dev CREATE2 determinism is the reason the factory exists — a manifest records a window
    ///      for a brand before it is opened — so a deployed address that does not equal the
    ///      predicted one means the recorded address is wrong for every brand, not just this
    ///      one. Checked for skipped brands too: that is where a factory from the wrong chain
    ///      or a changed `BrandPsm` bytecode would show up.
    function _assertWiring(
        BrandPsmFactory factory,
        SharedReservePool reserve,
        address[] memory brands,
        address[] memory windows
    ) private view {
        for (uint256 i = 0; i < brands.length; ++i) {
            BrandPsm psm = BrandPsm(windows[i]);
            require(windows[i] != address(0), "window is the zero address");
            require(
                windows[i] == factory.predict(reserve, brands[i]),
                string.concat("predict does not match deploy for ", vm.toString(brands[i]))
            );
            require(
                factory.psmOf(address(reserve), brands[i]) == windows[i],
                string.concat("factory index missed ", vm.toString(brands[i]))
            );
            require(psm.pocket() == address(reserve), "window points at another reserve");
            require(address(psm.dai()) == brands[i], "window's dai is not the brand");
            require(address(psm.gem()) == address(reserve.asset()), "window's gem is not the asset");
        }

        console.log("");
        console.log("Wiring assertions: PASSED (predict == deploy for every brand)");
    }

    /// @dev The manifest snippet, printed rather than written: `deployments/` is edited by hand
    ///      and the `brandPsm` section already carries the prose that explains these addresses.
    function _report(
        BrandPsmFactory factory,
        SharedReservePool reserve,
        address[] memory brands,
        address[] memory windows
    ) private view {
        console.log("");
        console.log("=== Windows open ===");
        console.log("Reserve:", address(reserve));
        console.log("Windows indexed by this factory:", factory.psmCount());
        console.log("");
        console.log("Record under brandPsm in deployments/asset-markets-mainnet-v6.json:");
        console.log("");
        console.log(string.concat('    "factory": "', vm.toString(address(factory)), '",'));
        console.log('    "windows": {');
        for (uint256 i = 0; i < brands.length; ++i) {
            console.log(
                string.concat(
                    '      "',
                    IERC20Metadata(brands[i]).symbol(),
                    '": "',
                    vm.toString(windows[i]),
                    i + 1 == brands.length ? '"' : '",'
                )
            );
        }
        console.log("    }");
        console.log("");
        console.log("Nothing already deployed was modified: no owner call, no reserve call, no");
        console.log("parameter change. A window holds no funds and can be redeployed at the same");
        console.log("address by this factory alone, so losing the manifest entry costs nothing.");
        console.log("");
        console.log("KyberSwap's public lite-psm source must be configured with IsMint: true.");
        console.log("A BrandPsm mints its dai through the reserve rather than holding an");
        console.log("inventory of it, so a quoter reading a dai balance here quotes zero.");
    }

    function _defaultBrands() private pure returns (address[] memory brands) {
        brands = new address[](4);
        brands[0] = AIUSD;
        brands[1] = SDOGE_D;
        brands[2] = ABR_D;
        brands[3] = CORGIGG_D;
    }
}
