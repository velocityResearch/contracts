// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MainnetAddresses
/// @notice The Robinhood Chain mainnet integration constants, in one place.
///
///         These were previously copied into each deploy script by hand. None of them can be
///         checked by a test — every one of these contracts exists only on chain 4663 — so a
///         copy that drifted would be found by a broadcast transaction and nothing earlier.
///         `script/PreflightMainnet.s.sol` asserts every value here against the live chain and
///         is the only thing standing between a wrong constant and a real deployment. Run it
///         before any broadcast, and again after changing anything in this file.
///
///         Last verified against chain 4663 on 2026-09-10, including the three Uniswap v4
///         constants — which the preflight did NOT cover until that date, despite this note
///         claiming it covered everything here.
library MainnetAddresses {
    /// @notice Robinhood Chain mainnet. The testnet is 46630 — one digit apart, which is
    ///         exactly why every mainnet script guards on this rather than trusting `--rpc-url`.
    uint256 internal constant CHAIN_ID = 4663;

    // ─── Money ───────────────────────────────────────────────────────────

    /// @notice USDG (Paxos Global Dollar), the reserve asset. Verified: symbol "USDG".
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// @notice USDG is 6-decimal, which is what `BrandFeeVault.minSweep` is denominated in: one
    ///         whole reserve unit is 1e6, not 1e18.
    uint8 internal constant USDG_DECIMALS = 6;

    // ─── Lending ─────────────────────────────────────────────────────────

    /// @notice Morpho Blue singleton.
    address internal constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    /// @notice The USDG market the reserve's adapter supplies into: USDG loan token, USDe
    ///         collateral. Verified: `idToMarketParams(...).loanToken == USDG`.
    bytes32 internal constant USDE_MARKET_ID =
        0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;

    // ─── Uniswap V4 ──────────────────────────────────────────────────────
    //
    // **Uniswap v4 IS deployed on Robinhood Chain, at non-canonical addresses**, the same way
    // v3 is. An earlier note in this file claimed the opposite; it was wrong, and the mistake
    // came from checking only the two canonical PoolManager addresses used on Ethereum and
    // Base, both of which are empty here. The right way to find it is to look for v4's own
    // events, which is how these were confirmed on 2026-09-10:
    //
    //   cast logs --rpc-url https://rpc.mainnet.chain.robinhood.com --from-block <recent> $(cast keccak "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)")
    //
    // The emitting address is the PoolManager. It is heavily used — a 9,000-block window
    // exceeded the RPC's 10,000-log cap on `Swap` alone — so these pools are live venues, not
    // a dormant deployment.
    //
    // This matters beyond saving a deployment. Because our markets sit on the SAME singleton
    // everyone else uses, an aggregator or interface that already routes v4 on this chain can
    // route to them. Deploying our own PoolManager would have produced pools nobody else could
    // find.

    /// @notice Uniswap V4 `PoolManager`. NON-canonical address on this chain. 24,009 bytes,
    ///         reports an `owner` and a `protocolFeeController`.
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice Uniswap V4 `PositionManager` — the real one. Reports name "Uniswap v4 Positions
    ///         NFT", symbol `UNI-V4-POSM`, `poolManager() == POOL_MANAGER`, `permit2() ==
    ///         PERMIT2`, and had minted 2,295,265 positions when checked.
    address internal constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @notice Permit2, at its canonical cross-chain address. `PositionManager` pulls tokens
    ///         exclusively through this, so a contract that mints positions must approve it.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // `ProtocolFeeHook` is still a per-deployment output rather than a constant, and has to be:
    // a v4 hook's address encodes its permission bits, so it is mined by CREATE2 against its
    // own constructor arguments. See `HookSaltMiner` in `script/DeployAssetMarkets.s.sol`.

    // ─── Uniswap V3 ──────────────────────────────────────────────────────
    //
    // Still live on this chain and still verified by `script/PreflightMainnet.s.sol`, but the
    // asset-market stack no longer uses any of them: `AssetMarketFactory` and `MarketRouter`
    // are v4-only. They remain because the deep incumbent pools for the tokenized equities
    // are v3, and Mode A routing will have to reach them.

    /// @notice Uniswap V3 factory. NON-canonical address on this chain.
    address internal constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    /// @notice Position manager, also non-canonical. Verified: reports `UNISWAP_V3_FACTORY`.
    address internal constant NONFUNGIBLE_POSITION_MANAGER =
        0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;

    /// @notice SwapRouter02, also non-canonical. The canonical `SwapRouter` address holds an
    ///         unrelated funds-forwarding contract here — approving it would be a real loss.
    ///         Verified: reports `UNISWAP_V3_FACTORY`.
    ///
    ///         The asset-market stack gives it no standing allowance and never did under v4:
    ///         a swap is `unlock`/`swap`/settle against the singleton, so there is no router to
    ///         approve. Kept because the deep incumbent equity pools are v3 and `LiquidityZapper`
    ///         sells through this address.
    address internal constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    /// @notice Canonical WETH9, as `SWAP_ROUTER_02.WETH9()` reports it. Verified on chain
    ///         2026-09-12.
    ///
    ///         Recorded here for preflight and for tests that need to name the token; nothing in
    ///         `src/` reads it. `LiquidityZapper` derives its wrapper from the router it is given,
    ///         so the address it wraps into cannot disagree with the address it sells through.
    address internal constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @notice The deepest WETH/USDG v3 pool at the time of writing, and the tier the app quotes
    ///         an ETH zap against. 0.01% — 100 hundredths of a bip. Measured 2026-09-12: about
    ///         5,483 WETH and 15.9M USDG, against 795/2.89M at 0.05%, 119/615k at 0.3% and
    ///         1.79/7,969 at 1%. Depth moves, so this is a default to quote against and not a
    ///         constant to trust: `zapLiquidityWithEth` takes the tier per call.
    uint24 internal constant WETH_USDG_FEE = 100;

    /// @notice The fee tier the first markets are expected to use. Not stamped into anything —
    ///         the tier is a field of the owner's per-asset approval — but preflighted so a
    ///         launch does not discover an unenabled tier mid-transaction. Verified: spacing 60.
    uint24 internal constant DEFAULT_FEE = 3000;

    // ─── Equity verification ─────────────────────────────────────────────

    /// @notice A live canonical tokenized equity, used only for its `EXTCODEHASH`. Every genuine
    ///         Robinhood token is the same beacon proxy with the beacon compiled in as an
    ///         immutable, so this one address pins the canonicality test for all of them.
    ///         SPCX is used because it is the asset this design was conceived for; any other
    ///         genuine token gives the identical hash. Verified: symbol "SPCX".
    address internal constant REFERENCE_EQUITY = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;

    // ─── The first three market assets ───────────────────────────────────
    //
    // Each asset, plus the live v3 pool its opening price is read off. Those pools are price
    // SOURCES and nothing else: a market's own liquidity lives in its own v4 pool, and nothing
    // here ever trades against them. Verified against chain 4663 on 2026-09-17; asserted by
    // `PreflightMainnet`, which is the only thing that will notice if one of them drifts.

    /// @notice SPCX, Robinhood's tokenized SpaceX Class A. Same address as `REFERENCE_EQUITY`,
    ///         which is not a coincidence — it is the asset this design was conceived for.
    address internal constant SPCX = REFERENCE_EQUITY;

    /// @notice The SPCX/USDG 0.05% v3 pool, the deepest of the four SPCX tiers. Oracle ring of
    ///         3,100 observations, so a 30-minute TWAP reads off it.
    address internal constant SPCX_USDG_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;

    /// @notice NVDA, Robinhood's tokenized NVIDIA. Verified: symbol "NVDA", 18 decimals, and a
    ///         codehash the factory reads as canonical.
    ///
    ///         **Not `0x86923f96…`.** That address is a genuine Robinhood token too, which is
    ///         why it looks right and passes a canonicality check — it reports symbol "AMD".
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    /// @notice The NVDA/USDG 0.05% v3 pool. Oracle ring of 6,000, TWAP-capable.
    address internal constant NVDA_USDG_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    /// @notice AI, "Artificial Inu" — a Pons memecoin, not an equity, so the factory records its
    ///         market as unverified. Deliberate: the badge describes the asset's provenance and
    ///         is not a judgement about whether a market is worth trading.
    address internal constant AI = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;

    /// @notice The AI/USDG 1% v3 pool — about 38,000 USDG and 84,000 AI. Its oracle ring is 1,
    ///         so `observe` over any window reverts `OLD` and a TWAP is not available here.
    address internal constant AI_USDG_POOL = 0xe547c18f46Db55AB788343bcC503F9CF0bd7d564;

    /// @notice The AI/WETH 1% pool, and the WETH/USDG 0.01% pool. Together they price AI a
    ///         second way, which is what stands in for the TWAP this asset cannot offer: two
    ///         independent routes that agree are much harder to push than one thin pool.
    address internal constant AI_WETH_POOL = 0xc4a21f9d6485FC5893DD4A491B320a83DAF4Da1D;
    address internal constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
}
