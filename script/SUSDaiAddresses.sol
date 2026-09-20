// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SUSDaiAddresses
/// @notice The integration constants for the sUSDai-backed reserve, on both chains it spans.
///
///         Robinhood Chain's own constants (USDG, the timelock, the guard, the beacons) live in
///         `MainnetAddresses` and `deployments/asset-markets-mainnet-v4.json`; this file holds
///         only what the sUSDai group adds: the Across SpokePools on both sides and the Arbitrum
///         side of the position. Same rule as `MainnetAddresses`: no test can check any of these,
///         so each deploy script re-reads the live contract it is about to trust in its preflight
///         and refuses to broadcast on a mismatch.
///
///         Every value here was read back from chain on 2026-09-13.
library SUSDaiAddresses {
    // ─── Chains ──────────────────────────────────────────────────────────

    /// @notice Arbitrum One, where sUSDai is canonical and where `SUSDaiHub` lives.
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

    // ─── Arbitrum ────────────────────────────────────────────────────────

    /// @notice Native USDC on Arbitrum (6 decimals). What Across delivers to the hub and what
    ///         the hub trades on Curve. Not USDC.e.
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice USD.AI's `StakedUSDai` (sUSDai), 18 decimals. `asset() == USDAI`. Verified against
    ///         the deployed v1.12 implementation's ABI. On 2026-09-13: `depositSharePrice()` =
    ///         1.11217e18, `redemptionSharePrice()` = 1.10721e18 (gap ~44 bps).
    address internal constant SUSDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;

    /// @notice USDai, sUSDai's underlying, 18 decimals. The hub never holds it; it is here so
    ///         the preflight can assert `IStakedUSDai(SUSDAI).asset()` points where we think.
    address internal constant USDAI = 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF;

    /// @notice Curve StableSwap-NG plain pool sUSDai/USDC. Read back 2026-09-13: `N_COINS` = 2,
    ///         `coins(0)` = SUSDAI, `coins(1)` = ARB_USDC, `A` = 500, `fee` = 1e6 (0.01%),
    ///         `stored_rates()` = [sUSDai deposit share price, 1e30]. `get_dy(1,0,10_000e6)` =
    ///         8990.84e18 shares; `get_dy(0,1,9000e18)` = 10007.61e6 USDC. `SUSDaiHub`'s
    ///         constructor discovers the coin order itself; the preflight asserts it anyway so a
    ///         swapped pool address fails before the deploy transaction rather than in it.
    address internal constant CURVE_SUSDAI_USDC = 0xa7CF5543a27BaDC3a74d51EA0A02E84799140E4E;

    /// @notice Across V3 SpokePool on Arbitrum. `depositQuoteTimeBuffer()` = 3600,
    ///         `fillDeadlineBuffer()` = 21600. Origin of `bridgeHome` (USDC -> USDG on 4663).
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;

    // ─── Robinhood Chain ─────────────────────────────────────────────────

    /// @notice Across V3 SpokePool on Robinhood Chain. `depositQuoteTimeBuffer()` = 3600,
    ///         `fillDeadlineBuffer()` = 21600. Origin of `bridgeOut` (USDG -> USDC on 42161).
    ///         `app.across.to/api/swap/approval` quotes USDG(4663) <-> USDC(42161) as a plain
    ///         `depositV3` against this address, ~6 bps, ~2 s expected fill.
    address internal constant ROBINHOOD_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;

    /// @notice Both SpokePools reported these on 2026-09-13. A quote's `quoteTimestamp` must be
    ///         within the first of `getCurrentTime()`; its `fillDeadline` at most the second
    ///         beyond it. Asserted by both deploy scripts because a changed buffer changes what
    ///         the keeper's quotes must look like.
    uint32 internal constant SPOKE_QUOTE_TIME_BUFFER = 3600;
    uint32 internal constant SPOKE_FILL_DEADLINE_BUFFER = 21600;
}
