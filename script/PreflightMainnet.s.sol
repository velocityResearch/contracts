// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {IMorphoBlue} from "../src/yield/MorphoBlueYieldSource.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {
    IUniswapV3Factory,
    INonfungiblePositionManager,
    IUniswapV3PoolLike
} from "../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @dev The narrowest v4 surface that can prove these three addresses are what they claim.
///      Declared here rather than imported so this script keeps compiling if the periphery
///      remapping ever moves: a preflight that cannot run is worse than a verbose one.
interface IPoolManagerLike {
    function owner() external view returns (address);
    function protocolFeeController() external view returns (address);
}

interface IPositionManagerLike {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function nextTokenId() external view returns (uint256);
}

/// @title PreflightMainnet
/// @notice Read-only. Broadcasts nothing, deploys nothing, needs no key.
///
///         Every mainnet integration address in `MainnetAddresses` is a hardcoded constant that
///         no test can check, because none of these contracts exist anywhere but chain 4663.
///         Until now the first thing that would have noticed a wrong one is a broadcast
///         transaction. This asserts all of them against the live chain instead.
///
///         What it proves:
///         - each address holds code, and the ERC20s report the name, symbol and decimals the
///           deploy scripts assume;
///         - Uniswap's deployed v4 `PositionManager` reports the SAME `PoolManager` singleton
///           every market will be created in, and the same Permit2 it pulls tokens through —
///           the check that matters most now, because a `PoolKey` names its singleton and a
///           market created against the wrong one is unreachable rather than merely broken;
///         - `SwapRouter02` and the position manager both report the SAME V3 factory the deploy
///           scripts pass in — the check that catches the canonical-address trap described on
///           `MainnetAddresses.SWAP_ROUTER_02`;
///         - the fee tier the first markets will use is enabled and has the tick spacing the
///           factory will derive from it;
///         - the Morpho market id resolves to a real market whose LOAN token is USDG, and that
///           market currently holds supply — a market id that is merely well-formed would
///           otherwise silently accept the pool's whole reserve;
///         - the reference equity has code, so `equityCodehash` will be non-zero and market
///           verification will actually be on rather than silently disabled.
///
///         What it cannot prove: that the Morpho market stays solvent, that the V3 deployment is
///         the audited Uniswap source rather than a look-alike with the same interface, or that
///         the equity issuer will not freeze the asset (ASSET_MARKETS.md §3.2). Those are read
///         as risks, not as preconditions.
///
///         Usage:
///         forge script script/PreflightMainnet.s.sol --rpc-url robinhood
contract PreflightMainnet is Script {
    /// @notice A market with no supply cannot be distinguished from a market id that happens to
    ///         be well-formed but was never created. Any non-zero figure settles it; this floor
    ///         is set low deliberately, because the size of the market is a judgement for the
    ///         runbook and not a reason for a script to refuse.
    uint256 constant MIN_MORPHO_SUPPLY = 1;

    function run() external view {
        require(block.chainid == MainnetAddresses.CHAIN_ID, "not Robinhood Chain mainnet (4663)");

        console.log("=== Robinhood Chain mainnet preflight ===");
        console.log("Chain ID:", block.chainid);
        console.log("");

        _checkCode("USDG", MainnetAddresses.USDG);
        _checkCode("Morpho Blue", MainnetAddresses.MORPHO_BLUE);
        _checkCode("Uniswap V4 PoolManager", MainnetAddresses.POOL_MANAGER);
        _checkCode("Uniswap V4 PositionManager", MainnetAddresses.V4_POSITION_MANAGER);
        _checkCode("Permit2", MainnetAddresses.PERMIT2);
        _checkCode("Uniswap V3 factory", MainnetAddresses.UNISWAP_V3_FACTORY);
        _checkCode("Position manager", MainnetAddresses.NONFUNGIBLE_POSITION_MANAGER);
        _checkCode("SwapRouter02", MainnetAddresses.SWAP_ROUTER_02);
        _checkCode("Reference equity", MainnetAddresses.REFERENCE_EQUITY);
        console.log("");

        _checkUsdg();
        _checkUniswapV4();
        _checkUniswap();
        _checkMorphoMarket();
        _checkReferenceEquity();
        _checkMarketAssets();

        console.log("");
        console.log("=== Preflight PASSED ===");
        console.log("Every hardcoded mainnet constant matches the live chain.");
        console.log("This says nothing about the two governance blockers. See");
        console.log("docs/ASSET_MARKETS_MAINNET.md before broadcasting anything.");
    }

    function _checkCode(string memory label, address target) private view {
        uint256 size = target.code.length;
        require(size > 0, string.concat(label, ": no code at the hardcoded address"));
        console.log(string.concat(label, ":"), target);
        console.log("    code size:", size);
    }

    function _checkUsdg() private view {
        IERC20Metadata usdg = IERC20Metadata(MainnetAddresses.USDG);
        string memory symbol = usdg.symbol();
        uint8 decimals = usdg.decimals();

        require(
            keccak256(bytes(symbol)) == keccak256(bytes("USDG")), "USDG: unexpected token symbol"
        );
        require(decimals == MainnetAddresses.USDG_DECIMALS, "USDG: unexpected decimals");

        console.log("USDG name:", usdg.name());
        console.log("USDG symbol:", symbol);
        console.log("USDG decimals:", decimals);
        console.log("USDG total supply (base units):", usdg.totalSupply());
    }

    /// @dev The venue the asset markets actually live in. Everything here is a state the
    ///      stack can reach and still look finished, which is why each is asserted rather
    ///      than printed:
    ///
    ///      - a `PoolKey` names its `PoolManager`, so a market opened against the wrong
    ///        singleton is not broken, it is INVISIBLE — no aggregator, router or interface
    ///        on this chain would ever find it, and nothing about the deployment would say so;
    ///      - `MarketRouter` mints LP positions through the `PositionManager`, which pulls
    ///        tokens exclusively through Permit2. A PositionManager bound to a different
    ///        singleton, or a wrong Permit2, fails at the first `seedLiquidity` — long after
    ///        the deployment looked complete.
    ///
    ///      These addresses are non-canonical on this chain, exactly as the v3 ones are, and
    ///      were found by their own `Initialize` events rather than by assuming the Ethereum
    ///      addresses. `MainnetAddresses` records how.
    function _checkUniswapV4() private view {
        IPositionManagerLike posm = IPositionManagerLike(MainnetAddresses.V4_POSITION_MANAGER);

        require(
            posm.poolManager() == MainnetAddresses.POOL_MANAGER,
            "v4 PositionManager reports a different PoolManager"
        );
        require(
            posm.permit2() == MainnetAddresses.PERMIT2,
            "v4 PositionManager pulls through a different Permit2"
        );

        // A real v4 singleton owns itself in the governance sense: it answers `owner` and
        // `protocolFeeController`. An unrelated contract at this address would revert here
        // rather than quietly returning a plausible number.
        IPoolManagerLike manager = IPoolManagerLike(MainnetAddresses.POOL_MANAGER);
        address managerOwner = manager.owner();
        address feeController = manager.protocolFeeController();

        console.log("");
        console.log("v4 PositionManager -> PoolManager: MATCHES");
        console.log("v4 PositionManager -> Permit2: MATCHES");
        console.log("v4 PositionManager name:", posm.name());
        console.log("v4 PositionManager symbol:", posm.symbol());
        console.log("v4 positions minted so far:", posm.nextTokenId() - 1);
        console.log("PoolManager owner:", managerOwner);
        console.log("PoolManager protocol fee controller:", feeController);
    }

    function _checkUniswap() private view {
        // The single most important check here. Both periphery contracts are at non-canonical
        // addresses on this chain, and the canonical `SwapRouter` address holds an unrelated
        // funds-forwarding contract. A router paired with the wrong factory would take approvals
        // and route them somewhere nobody intended. `AssetMarketFactory` and `MarketRouter` both
        // repeat this check in their constructors; doing it here means a mismatch costs a read
        // rather than a reverted broadcast.
        address routerFactory = ISwapRouter02(MainnetAddresses.SWAP_ROUTER_02).factory();
        require(
            routerFactory == MainnetAddresses.UNISWAP_V3_FACTORY,
            "SwapRouter02 reports a different V3 factory"
        );

        address managerFactory =
            INonfungiblePositionManager(MainnetAddresses.NONFUNGIBLE_POSITION_MANAGER).factory();
        require(
            managerFactory == MainnetAddresses.UNISWAP_V3_FACTORY,
            "position manager reports a different V3 factory"
        );

        int24 tickSpacing = IUniswapV3Factory(MainnetAddresses.UNISWAP_V3_FACTORY)
            .feeAmountTickSpacing(MainnetAddresses.DEFAULT_FEE);
        require(tickSpacing != 0, "default fee tier is not enabled on this V3 factory");

        console.log("");
        console.log("SwapRouter02 -> factory: MATCHES");
        console.log("Position manager -> factory: MATCHES");
        console.log("Fee tier:", MainnetAddresses.DEFAULT_FEE);
        console.log("Tick spacing for that tier:", int256(tickSpacing));
    }

    function _checkMorphoMarket() private view {
        IMorphoBlue morpho = IMorphoBlue(MainnetAddresses.MORPHO_BLUE);
        IMorphoBlue.MarketParams memory p = morpho.idToMarketParams(MainnetAddresses.USDE_MARKET_ID);

        // The loan token is what the pool supplies. A market id pointing at anything but USDG
        // would take the reserve's deposits and be unable to account for them.
        require(p.loanToken == MainnetAddresses.USDG, "Morpho market's loan token is not USDG");
        require(p.oracle != address(0), "Morpho market has no oracle - id was never created");
        require(p.irm != address(0), "Morpho market has no IRM - id was never created");

        IMorphoBlue.Market memory m = morpho.market(MainnetAddresses.USDE_MARKET_ID);
        require(m.totalSupplyAssets >= MIN_MORPHO_SUPPLY, "Morpho market holds no supply");

        console.log("");
        console.log("Morpho market loan token: USDG (MATCHES)");
        console.log("Morpho market collateral:", p.collateralToken);
        console.log("Morpho collateral symbol:", IERC20Metadata(p.collateralToken).symbol());
        console.log("Morpho oracle:", p.oracle);
        console.log("Morpho IRM:", p.irm);
        console.log("Morpho LLTV (1e18):", p.lltv);
        console.log("Morpho total supply assets:", m.totalSupplyAssets);
        console.log("Morpho total borrow assets:", m.totalBorrowAssets);

        // Utilization is the number that decides whether a redemption can be served on demand.
        // `SharedReservePool._recallIfNeeded` pulls from Morpho when idle is short, and that
        // pull fails outright at 100% utilization (ASSET_MARKETS.md §10). Printed, not enforced:
        // it moves every block and is a launch judgement, not a constant to assert against.
        if (m.totalSupplyAssets > 0) {
            uint256 utilizationBps =
                (uint256(m.totalBorrowAssets) * 10_000) / uint256(m.totalSupplyAssets);
            console.log("Morpho utilization (bps):", utilizationBps);
            console.log("    Redemptions are served from idle first, then by recalling from");
            console.log("    Morpho. A recall reverts at 100% utilization. Watch this number.");
        }
    }

    function _checkReferenceEquity() private view {
        // `AssetMarketFactory` stores `_referenceEquity.codehash`, and reads a zero codehash as
        // "verification disabled". An address with no code therefore does not fail loudly — it
        // silently ships a factory that marks every market unverified.
        bytes32 codehash = MainnetAddresses.REFERENCE_EQUITY.codehash;
        require(codehash != bytes32(0), "reference equity has no code: verification would be OFF");

        console.log("");
        console.log("Reference equity:", MainnetAddresses.REFERENCE_EQUITY);
        console.log("Reference symbol:", IERC20Metadata(MainnetAddresses.REFERENCE_EQUITY).symbol());
        console.log("Equity codehash is non-zero: market verification will be ACTIVE");
    }

    /// @dev The three assets the first markets are opened for, and the pools their opening
    ///      prices are read off. A wrong asset address here is the worst constant in this file:
    ///      every genuine Robinhood token is the same proxy, so a mistyped one still reports a
    ///      canonical codehash, still lists, still trades — as the wrong company. The symbol is
    ///      the only thing that tells them apart, so it is asserted, not printed.
    function _checkMarketAssets() private view {
        _checkAsset("NVDA", MainnetAddresses.NVDA, MainnetAddresses.NVDA_USDG_POOL);
        _checkAsset("SPCX", MainnetAddresses.SPCX, MainnetAddresses.SPCX_USDG_POOL);
        _checkAsset("AI", MainnetAddresses.AI, MainnetAddresses.AI_USDG_POOL);

        // AI's own pool has an oracle ring of one, so its listing leans on a second route
        // instead of a TWAP. Both legs of that route have to be real for the check to mean
        // anything.
        _checkPair(
            "AI/WETH", MainnetAddresses.AI_WETH_POOL, MainnetAddresses.AI, MainnetAddresses.WETH9
        );
        _checkPair(
            "WETH/USDG",
            MainnetAddresses.WETH_USDG_POOL,
            MainnetAddresses.WETH9,
            MainnetAddresses.USDG
        );
    }

    function _checkAsset(string memory symbol, address asset, address pool) private view {
        require(asset.code.length > 0, string.concat(symbol, ": no code at the asset address"));
        require(
            keccak256(bytes(IERC20Metadata(asset).symbol())) == keccak256(bytes(symbol)),
            string.concat(symbol, ": asset address reports a different symbol")
        );
        require(IERC20Metadata(asset).decimals() == 18, string.concat(symbol, ": not 18 decimals"));

        _checkPair(symbol, pool, asset, MainnetAddresses.USDG);
        uint128 liquidity = IUniswapV3PoolLike(pool).liquidity();
        require(liquidity > 0, string.concat(symbol, ": price source pool is empty"));

        console.log("");
        console.log(string.concat(symbol, ":"), asset);
        console.log(string.concat("    name: ", IERC20Metadata(asset).name()));
        console.log("    USDG price pool:", pool);
        console.log("    pool liquidity:", liquidity);
    }

    function _checkPair(string memory label, address pool, address tokenA, address tokenB)
        private
        view
    {
        require(pool.code.length > 0, string.concat(label, ": no code at the pool address"));
        address token0 = IUniswapV3PoolLike(pool).token0();
        address token1 = IUniswapV3PoolLike(pool).token1();
        bool matches =
            (token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA);
        require(matches, string.concat(label, ": pool holds the wrong pair"));
    }
}
