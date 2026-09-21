# Fables economic evidence — research snapshot 2026-09-21

## Scope and reproducibility

Read-only direct HTTP research, using agent-reach's Jina web route for the JavaScript-rendered official site and direct reads for APIs and source. No builds, tests, formatting, commits, or worktree edits. Retrieval date: 2026-09-21. Exact wall-clock retrieval time was not exposed by this scout's tools; do not invent one. API timestamps below provide actual observation dates. The latest TVL observation is Unix 1789965551, i.e. 2026-09-21 04:39:11 UTC. Some Jina documentation responses expose Published Time Sun, 20 Sep 2026 23:29:54 GMT; that is source metadata, not retrieval time.

Primary endpoints:
- https://api.llama.fi/summary/fees/fables?dataType=dailyFees
- https://api.llama.fi/summary/dexs/fables
- https://api.llama.fi/protocol/fables
- https://defillama.com/protocol/fables
- https://raw.githubusercontent.com/DefiLlama/dimension-adapters/master/dexs/fables.ts
- https://raw.githubusercontent.com/DefiLlama/DefiLlama-Adapters/main/projects/fables/index.js

The normalized dated series is preserved below and in metrics.csv; the linked APIs and mutable GitHub branches can change. Calculations must join timestamps, not assume '24h' fields from different responses refer to the same day.

## 1. The 2.1x claim: verified marketing, not verified performance

The rendered official homepage https://www.fables.fi/ (readable through https://r.jina.ai/https://www.fables.fi/) says verbatim: 'Pools adapted to their assets earn Liquidity Providers up to 2.1x more yield on identical risk.' It also says pools ingest real-world cues on time, volatility and sentiment to reprice fees.

No supporting dataset, benchmark pool, observation window, code notebook, backtest assumptions, confidence intervals, risk definition, or independent attestation was linked in the inspected homepage and official docs. Searches for Fables 2.1x yield audit backtest and fables.fi audit/backtest/license did not identify a relevant validation report; the second search was mostly irrelevant name collisions. This is evidence unavailable in the inspected public materials, NOT proof no private backtest exists. The figure cannot be reproduced from DefiLlama aggregate data. 'Up to' is a selected upper bound, not an expectation; 'yield' need not mean net mark-to-market LP profit; 'identical risk' is undefined.

Official fee-model description: https://www.fables.fi/docs/dynamic-fees. The documented architecture is autonomous calendar / flat baseline / directional models plus an authorized, bounded, expiring offchain keeper override. Reference divergence or realized volatility may inform the keeper. A keeper outage falls back to the autonomous fee. Do not turn the marketing phrase into a claim that every pool has a permissionless onchain volatility estimator.

## 2. Dated time series, USD

These are API-reported estimates, not independently reconstructed chain accounting. CSV columns are Unix UTC day, UTC date, estimated swap fees, chosen-leg volume, daily TVL. NA means no TVL sample in the returned daily series, not zero.

```csv
unix,date,fees_usd,volume_usd,tvl_usd
1787011200,2026-08-18,2.85,7271,NA
1787097600,2026-08-19,29.51,47720,NA
1787184000,2026-08-20,21.38,38059,NA
1787270400,2026-08-21,46.67,95005,NA
1787356800,2026-08-22,24.77,62110,NA
1787443200,2026-08-23,44.98,96594,NA
1787529600,2026-08-24,185,228227,NA
1787616000,2026-08-25,613,984676,NA
1787702400,2026-08-26,964,1700438,422789
1787788800,2026-08-27,1493,2071657,512885
1787875200,2026-08-28,2722,3168229,742881
1787961600,2026-08-29,5343,8907603,832776
1788048000,2026-08-30,13658,12135536,1100001
1788134400,2026-08-31,10173,10041834,2225194
1788220800,2026-09-01,15833,13699728,3311859
1788307200,2026-09-02,18499,19215625,4050484
1788393600,2026-09-03,36177,34571464,7790816
1788480000,2026-09-04,36698,42816189,12015838
1788566400,2026-09-05,20953,35114940,13252308
1788652800,2026-09-06,34113,44403566,15554010
1788739200,2026-09-07,37452,40812802,14802597
1788825600,2026-09-08,47002,43033770,14581054
1788912000,2026-09-09,58478,44441683,15308283
1788998400,2026-09-10,71424,46071134,17134356
1789084800,2026-09-11,148119,57875565,17503573
1789171200,2026-09-12,59036,43337084,18265173
1789257600,2026-09-13,89793,58109882,19911539
1789344000,2026-09-14,133088,70945937,19626322
1789430400,2026-09-15,137933,60640023,20935697
1789516800,2026-09-16,112859,54525078,19857283
1789603200,2026-09-17,148913,71375044,21023629
1789689600,2026-09-18,148030,80489985,23622266
1789776000,2026-09-19,120152,71880726,27099040
1789862400,2026-09-20,146458,70627552,29031638
1789948800,2026-09-21,165748,72830500,30121543
```

Additional intraday TVL: 1789965551 -> $31,717,677. Treat September 21 as potentially partial/revisable, not a known completed UTC day.

API summary fields:
- Fees total24h $165,748; total7d $947,433; total30d $1,656,230.75; totalAllTime $1,822,079.16; annualized1y $17,781,202.15882353.
- Volume total24h $72,830,500; total7d $480,484,345; total30d $1,043,384,681; totalAllTime $1,116,403,236.
- The dashboard instead displayed $31.67m TVL, $146,458 24h fees and $72.83m 24h volume. Its fee and volume headlines therefore did not represent the same dated series row. Its cumulative fees $1.66m also differed from the API totalAllTime $1.822m.
- API seven-day summary equals September 14–20 series, excluding September 21. 'total24h' includes September 21. These semantics make blind ratios of headline fields unsafe.

Reproducible calculations (not causal estimates):
- Matched September 20 effective fee proxy in bps = 10000 × 146458 / 70627552.
- Matched September 21 proxy = 10000 × 165748 / 72830500 (potentially partial).
- Matched seven-day proxy = 10000 × 947433 / 480484345, approximately 19.72 bps.
- API thirty-day aggregate proxy = 10000 × 1656230.75 / 1043384681, approximately 15.87 bps.
- September 20 crude simple gross fee/TVL annualization = 365 × 146458 / 29031638, approximately 184% per year. This pairs a flow with one snapshot denominator, not time-weighted capital. It is neither compounded APY, net return nor forecast.
- Correctly time-weighted pool fee intensity would use daily fees divided by an explicitly defined daily mean marked capital, then aggregate consistently. A position requires its own fee growth and active-liquidity shares, not pool TVL.

The source reports substantial growth but cannot identify its cause. New capital, token prices, pool listings, incentive activity, changes in asset mix and fee policy all confound a before/after comparison.

## 3. Adapter mechanics and measurement caveats

Verified dimensions adapter constants:
- PoolManager: 0x8366a39cc670b4001a1121b8f6a443a643e40951.
- FablesPoolRegistry: 0x159a113e012593d9b3cc63ad45e30f0467e13ef3.
- Swap topic0: 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f.
- start 2026-08-15; returned time series begins August 18; do not impute zero for preceding days.

It calls activePools(), selects one valuation leg (currency0 if native, a core asset, or currency1 is not core; otherwise currency1), reads PoolManager Swap logs restricted to those pool IDs, and computes:

V_s = abs(Number(selected amount0 or amount1)); estimated F_s = V_s × emitted fee / 1,000,000.

Balances receive USD conversion through DefiLlama pricing. This is useful as a uniform approximation but is not exact collected fee-token accounting. If the selected leg is gross input, the formula aligns more closely with input fee charging, subject to rounding and protocol composition. If the selected leg is output, multiplying net output by the rate does not reconstruct input-denominated fees; price movement, slippage and the fee deduction matter. Even under constant-price simplification output value = input value × (1−f), so the output-leg estimate is true input fee × (1−f). Real concentrated swaps need exact swap-step and accounting data rather than this simplification. Selecting a liquid/core leg limits thin-token price manipulation but does not remove price-source, depeg or issuer risk.

The code converts int128 quantities to JavaScript Number, losing integer exactness for large raw values. It never allocates fees by position, active range, treasury accrual or collected cashflow. It treats all fees as LP revenue and returns dailyRevenue and dailyProtocolRevenue zero. Registry enumeration excludes pools not returned at the query state; historical backfills need correct historical registry state, and registry retirement can affect coverage if queried at a later state. Verify the API's historical-call semantics before asserting completeness.

The adapter comments state Fables pools are absent from Uniswap PositionManager.poolKeys and therefore skipped by the Uniswap v4 volume adapter. This is a source-author assertion inspected in code, not independently replayed by this scout.

TVL adapter uses the same registry and StateView 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b. It enumerates initialized ticks via bitmaps, accumulates liquidityNet using Number, and feeds consecutive intervals to addUniV3LikePosition with the current integer tick. It fetches sqrtPriceX96 but passes tick rather than the exact square-root price. Thus TVL is reconstructed liquidity principal, not the PoolManager's omnibus ERC20 balance and not a direct count of unclaimed fee claims. Exact helper behavior should be inspected before assigning an error bound. Source has doublecounted:true while API metadata returned doublecounted:false; labels should not substitute for tracing chain aggregation. Volume nonoverlap and TVL doublecounting are separate questions.

## 4. Material treasury contradiction

Official detailed documentation https://www.fables.fi/docs/fees-and-returns and https://www.fables.fi/terms says, based on September 14 state:
- Fables ledger takes 10% of accrued swap fees on every pool except ETH/USDG, GLD/USDG and SPY/USDG, where zero.
- Contract ceiling 20%; no deduction from deposits, withdrawals or principal.
- Recipient treasury 0x9F887B9930E9e716286333Bd8e291f64a8710F6f.
- Deduction occurs on a range sync, which deposits/adds/claims/withdrawals can trigger. It is not merely charged at an individual user's collection time.
- Backlogs spanning rate changes receive the lowest applicable rate over the sync interval.
- Displayed earned/claimable fee amounts are already net, while displayed APR is gross of the treasury share and gas.
- Uniswap protocol fee is documented as zero on all Fables pools, but externally controlled and distinct from the Fables ledger share.

These official claims directly conflict with the inspected DefiLlama adapter's 'All swap fees accrue to liquidity providers; Fables takes no protocol fee yet' and hardcoded zero revenue. A zero Uniswap protocol switch does not imply zero Fables revenue. Do NOT simply reduce all reported fees by 10%: exempt pools dominate some activity, policy can change, accrual windows matter, and event-based fees are already approximate. Reconciliation needs per-pool gross accrual plus ledger events/state at dated blocks. Until then DefiLlama fees should be described as approximate gross swap fees, not validated net LP income; zero protocol revenue is not established.

There is also documentation-version inconsistency: current fee-return docs say deposit and position projections both use active-liquidity share, while Terms describe the predeposit projection using a full-range concentration multiplier. This does not establish a frontend bug; it means current frontend formulas need direct source verification before reuse.

## 5. Fees, incentives and actual economic return

Let initial contributed assets be x0 and y0, terminal ex-fee principal inventory xT,yT, terminal marks pX,pY, net fees FT (valued consistently), realized cash rewards RT, and gas/rebalancing costs CT. For a simple no-external-flow position:

LP terminal wealth = xT pX + yT pY + FT + RT − CT.
HODL terminal wealth = x0 pX + y0 pY.
Excess versus holding = (xT−x0)pX + (yT−y0)pY + FT + RT − CT.

Deposits, withdrawals, fee reinvestments, token transfers and reward claims require cashflow-adjusted accounting. Do not subtract divergence loss and LVR as if independent additive losses without specifying the benchmark: they can describe overlapping economic effects versus different reference strategies.

Dynamic fees may compensate adverse selection; they do not abolish inventory risk, one-sided inventory, out-of-range inactivity, reference-market gaps, depegs, token issuer risk or liquidation-free but substantial mark-to-market losses. Gross fee APR alone cannot prove LPs beat holding or have identical risk.

Official incentives https://www.fables.fi/docs/points-and-rewards:
- Six-week points programme August 24 2026 02:00 UTC–October 5 2026 02:00 UTC, 1bn-point ceiling, daily budgets weighted by eligible earned swap fees; later weeks larger budgets.
- 10% additive referral points from a 100m reserve, subject to terms; points are not a token, claim, conversion promise or assured future distribution.
- Creator fee rewards are discretionary USDG weekly pots from PROLOGUE creator-fee proceeds, allocated by eligible earned fee share, not points. ETH/USDG and PROLOGUE/ETH excluded from this creator distribution under current policy.
- Announced amounts listed: 600 USDG Aug31, 3000 Sep7, 5000 Sep14, 5000 Sep21, 5000 Sep28. Future announcements are not proof payments have occurred.
- Offchain settlement/correction policies and exclusions apply.

Treat uncertain points value as zero in base-case realized PnL and show a separate scenario if assigning speculative value. Report creator cash rewards separately from organic swap fee revenue. Incentives can change liquidity, routing, self-trading economics and participant composition; there is no evidence here establishing wash volume, but aggregate data cannot exclude it.

## 6. When dynamic fees help, and when they fail

Economic reasoning, not an empirically measured Fables result:

At state z and fee f, let gross fee revenue be f Q(f,z), and adverse-selection cost A(f,z), all in comparable value units. Net objective also includes treasury, operating cost and inventory benchmark choice. Ignoring these extras, d[fQ]/df = Q + fQ'. With fee elasticity epsilon = −fQ'/Q, gross fee revenue rises locally with fees only when epsilon < 1. Including adverse selection gives marginal net benefit Q + fQ' − A'. A loss of toxic flow may improve net results even while gross fees fall; a loss of benign flow may worsen them.

Helps when elevated fees precede predictable informed flow (market open, closed reference markets, discontinuities), when selective directional pricing better distinguishes harmful from helpful trades, when lower quiet-period fees attract sufficient benign elastic flow, and when the keeper/reference is reliable and costs do not consume the benefit. Calendar signals are cheap and predictable but coarse.

Fails when the update lags the informed trade, when volatility is estimated from manipulable pool activity, when reference prices are stale, caps are below jump risk, competitive routing removes benign volume, demand is highly elastic, rebates or points distort optimization, or high fees inhibit inventory-rebalancing trades. A calendar can miss earnings, halts and exceptional closures; noncustodial bounded administration still changes economic outcomes. Identical initial capital/range does not imply identical realized risk: fees alter execution, inventory paths and time in range.

To substantiate 2.1x, request a timestamped dataset and executable specification with pool IDs, precise fee functions, reference prices, fee and treasury changes, positions/ranges, capital flows, gas, incentives, benchmark and predeclared risk metrics. Replaying identical historical swaps with a different fee is only a mechanical counterfactual: flow and routing would change. Use out-of-sample tests and sensitivity to elasticity/adverse selection; ideally randomized/controlled simultaneous pools. Report realized net excess versus holding, drawdown, time-in-range and inventory exposure in addition to fee income.

## 7. Audit and licensing evidence

Official security https://www.fables.fi/docs/security describes Olympix, Sherlock AI, pashov AI security tooling, tests, immutable hooks and audited Alphix foundations. This is not a named independent human audit of current Fables deployments. The DefiLlama dashboard says Audits: No; API audits:'3' is a categorical encoding and must not be read as three audits; audit_links was null.

Alphix security page https://alphix.gitbook.io/docs/tech/security links an actual Sherlock report:
https://raw.githubusercontent.com/alphixfi/alphix-core/main/security/2025.12.17-Final-AlphixCollaborativeAuditReport.pdf

Verified report text: audited December 1–8 2025, 0 high, 0 medium, 6 low/info, all resolved. Scope is alphixfi/alphix-core and files src/AlphixLogic.sol, src/Alphix.sol, src/BaseDynamicFee.sol, associated interfaces/constants, src/libraries/DynamicFee.sol and src/Registry.sol. Audited commit as printed: 6acc8c14887beaf42e759fc8d01aed4c34d1f0ca; final commit c059d7f3f1af876928bb78a8d45a892a07ab7d64. The described architecture includes replaceable/upgradable fee logic and volume/TVL EMA logic; it is not evidence that current Fables custom pooled-ledger, calendar/directional hooks or keeper deployment have been audited. Alphix's linked $30k critical bug bounty should likewise not be assumed to cover Fables without checking scope.

Verified upstream license https://raw.githubusercontent.com/alphixfi/alphix-core/main/LICENSE is Business Source License 1.1, Licensed Work Alphix v1.0, licensor Alphix Association, change date December 25 2028, change license MIT. It grants nonproduction use, copying/modification/derivation/redistribution subject to its terms; no Additional Use Grant is shown. It explicitly does not grant patent rights. Therefore public visibility is not permission for production copying today. Contracts scout separately reports custom Fables verified source SPDX UNLICENSED; that claim should be cited to its exact source in the combined report, not attributed to this scout's direct verification.

The official Terms reserve branding, copy and interface design and grant no license to third-party protocol/chain/token marks. Avoid copying Fables/Alphix implementation into production without verifying exact source-specific rights and obtaining permission where needed. Independently implementing documented economic concepts is a different question from code copying, but legal review may still be needed; this research is not legal advice.

## Bottom line

There is verified public activity and a plausible rationale for asset-specific adaptive fees, but no public evidence inspected here demonstrates the 2.1x identical-risk claim, net LP outperformance, or a portable uplift for StableLaunchpad. The most immediate quantitative correction is to stop equating DefiLlama gross estimated swap fees with net LP revenue or zero Fables treasury revenue. Preserve dynamic fees as a hypothesis to measure, not a yield guarantee.
