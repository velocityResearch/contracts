# kyberswap-dex-lib — staged contribution

Go source destined for `github.com/KyberNetwork/kyberswap-dex-lib`, kept here so it is reviewable
in this repository before it becomes a pull request against theirs. **Nothing here is part of this
repository's build.** There is no `go.mod`: these files only compile inside dex-lib's module, and
`gofmt` is the only check that runs on them locally.

**This directory is the source of truth.** The PR branch (`feat/stables-robinhood` in a dex-lib
clone) carries these files byte-for-byte, plus the two registration edits that only make sense
inside their module — the exchange constant in `pkg/valueobject/exchange.go` and the blank import
that triggers the package's `RegisterHooksFactory` side effect. `pkg/pooltypes` is NOT touched
and msgpack is NOT regenerated; see "Why a hook plugin" below for why. Edit here, copy there.
The two drifted once already, and the copy in the branch is the one that gets reviewed.

Background, the measurements behind it, and the order to make the ask in:
`docs/KYBERSWAP_INTEGRATION.md` §3.

## What is here

| Staged at | Lands at | What it does |
|---|---|---|
| `hooks/stables/` | `pkg/liquidity-source/uniswap/v4/hooks/stables/` | A `Hook` plugin for `ProtocolFeeHook`, so Kyber prices our v4 pools from the rate the contract returns instead of one fitted from quoter probes |

## Why a hook plugin and not a new liquidity source

Kyber **already routes through Stables markets** — measured 2026-09-18, with hops coming back as
`exchange: uniswap-v4-fee`. dex-lib's Uniswap v4 source is live on Robinhood Chain against
PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, discovering our pools on its own.

What it does not have is our hook. Unregistered hook addresses fall through to
`SetFallbackHookFactory`, an auto-detection model that *fits* a fee by probing a quoter.
`ProtocolFeeHook.feePipsFor(poolId)` returns that number for free, exactly, and it can change
between blocks. Registering the plugin replaces a guess with a read.

The `cashcat` plugin in the same directory — also on Robinhood Chain — states the precedence rule
plainly in its package comment: explicit registration in `HookFactories` takes priority over the
fallback. It is also the closest template, and this plugin is deliberately shaped like it so a
reviewer can diff the two.

## The four things a reviewer should look at

1. **The whole fee is charged in `afterSwap`, on the swap's UNSPECIFIED leg.** This is the
   claim to check first, because it is the one that changed. `beforeSwap` returns
   `BeforeSwapDeltaLibrary.ZERO_DELTA` unconditionally and charges nothing; it is in the
   callback list only to write a V3-style oracle observation. `afterSwap` is handed the
   `BalanceDelta` the pool actually produced and takes the pips off the leg the caller did not
   name:

   - exact-input (`amountSpecified < 0`): the unspecified leg is the **OUTPUT**, so the trader
     receives `amountOut - ⌊amountOut·feePips/1e6⌋`;
   - exact-output (`amountSpecified > 0`): the unspecified leg is the **INPUT**, so the trader
     pays `amountIn + ⌊amountIn·feePips/1e6⌋`.

   One rule covering both directions, so there is no swap type to flip into to escape the fee.
   The reason it moved out of `beforeSwap` matters to an aggregator specifically: `beforeSwap`
   runs before `pool.swap` and can only see the amount the caller ASKED for, so a caller who
   passes a binding `sqrtPriceLimitX96` and gets a partial fill was being billed on notional
   that never traded. A router that sets its own price limit is exactly that caller. Do not
   reintroduce an input-side term: `TestBeforeSwap_ChargesNothingInEitherDirection` and
   `TestAfterSwap_PartialFill_IsChargedOnTheFill` are the tripwires.
2. **The rate is mutable, but an increase is announced an hour ahead.** `cashcat` reads its rate
   once and persists it, because it is immutable for the pool's life. Ours is owner-settable per
   pool up to `MAX_FEE_PIPS` (**10,000 = 1.00%**, lowered from 5% on 2026-09-19 precisely to
   give an integrator a tight bound). An INCREASE is scheduled by `setPoolFeePips` and can only
   be applied `FEE_INCREASE_DELAY` (3,600 seconds) later by a permissionless
   `commitPoolFeePips`; a DECREASE applies immediately and cancels any pending increase. So a
   rate read during `Track` is good for at least an hour in the upward direction. `Track` still
   re-reads unconditionally — a decrease needs no notice, and the halt in (3) needs none either
   — and only falls back to a persisted value when there is no RPC client at all.

   Treat the delay as a **reliability** property, not a security one. The hook is a UUPS proxy
   owned by a 2-of-3 Gnosis Safe with **no upgrade timelock**, so the owner can replace the
   implementation, and the delay with it, in one transaction.
3. **`feePipsFor`, never `feePipsOf`.** `feePipsFor` returns 0 when the pool has no fee recipient
   bound *and* while the protocol guard reports a halt — and in both cases trading continues
   normally. `feePipsOf` is the raw stored value and would over-charge every quote during a halt.
4. **Exact-output is flat, not grossed up.** The contract charges the pips on the pool's realised
   (net) input, so total input is `net + ⌊net·fee/1e6⌋` — not `net·fee/(1e6 − fee)`.
   `TestAfterSwap_ExactOut_IsFlatNotGrossedUp` pins the difference (5,000,000 against 5,025,125
   on a 1,000-unit leg at 0.50%) so a refactor cannot quietly align this with the neighbouring
   hooks that do gross up.

## The precedent to follow

`stable-stable` — hook `0x3b64660a35a09AfDe554cE545bca9166D6A23CC0`, **also on Robinhood Chain** —
was added by PR #1669, opened 2026-09-13 and merged 2026-09-16. Read that diff before opening
ours; it is the closest thing to a worked example of this exact submission. Measured turnaround on
external v4 hook PRs generally is 1–8 days.

A hook plugin is a deliberately small change: every hook shares `DexType = "uniswap-v4"` and
differs only by its `Exchange` constant, so `pkg/pooltypes` is untouched and msgpack is not
regenerated. Contrast the reserve leg (`docs/KYBERSWAP_INTEGRATION.md` §3.4), which would be a
standalone source and does need all three.

**A merged PR does not enable the source.** Which sources run on which chain is Kyber-side
deployment config in their `pool-service`, invisible from the public repo. Ask for it in the PR,
and give them the chain-4663 values they will need:

| Config | Value |
|---|---|
| `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` (already in their `constant.go`) |
| `Multicall3Address` | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| `StateViewAddress` | `0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804` — Uniswap's own `StateView`, unmodified, already deployed on 4663. Nothing to deploy |
| `V4QuoterAddress` | `0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F` — Uniswap's own `V4Quoter`, unmodified. Only relevant to the auto-detection fallback this plugin replaces |
| `SubgraphAPI` | none — Robinhood has no v4 subgraph |
| `FetchTickFromStateView` | `true`, consequently |

Discovery is the one genuinely open question. Their v4 lister is subgraph-driven; with no subgraph
the route is log-based discovery off the PoolManager's `Initialize` event
(`poolfactory.RegisterFactoryC`, as `stable-stable` does) plus `FetchTickFromStateView`. That is
also what their own guidance prefers: *"Prefer discovering pools on-chain over off-chain
indexes."*

One thing to confirm rather than assume: `NewPoolSimulator` refuses a pool outright
(`shared.ErrUnsupportedHook`) when `HasSwapPermissions` is true and nothing is registered for the
hook address. Our pools quote today, so something already handles ours — see
`docs/KYBERSWAP_INTEGRATION.md` §1.1, and ask in the PR what `uniswap-v4-fee` currently does with
them.

## Applying it to a dex-lib checkout

Two edits in their tree beyond copying the directory:

1. `pkg/valueobject/exchange.go` — add the constant the plugin references:
   `ExchangeUniswapV4Stables = "uniswap-v4-stables"`, in the `ExchangeUniswapV4*` block.
2. Import the package for its registration side effect, wherever the other v4 hooks are imported.

Then, from the dex-lib root:

```
goimports -local github.com/KyberNetwork/kyberswap-dex-lib -w pkg/liquidity-source/uniswap/v4/hooks/stables
```

```
go test ./pkg/liquidity-source/uniswap/v4/hooks/stables/...
```

`go generate ./pkg/msgpack/...` is not needed: this adds no simulator type.

## Ground truth used in the tests

Read from Robinhood Chain mainnet (chainId 4663) on 2026-09-18 and re-read at block
**68,293,146** on 2026-09-20. Every value below was unchanged between the two reads except the
`MarketLens` address, which was redeployed later the same day; see the note under the table.
The quoted amounts did not move with it.

| Thing | Value |
|---|---|
| `ProtocolFeeHook` | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` (UUPS proxy; permissions `0x00CC` mined into the address and permanent) |
| `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| `MarketLens` | `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` — ownerless, stateless, the surface a simulator reads caps and quotes from |
| Market 13 pool id | `0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61` |
| `MAX_FEE_PIPS()` | `10000` = 1.00% |
| `FEE_INCREASE_DELAY()` | `3600` seconds |
| `feePipsFor(poolId)` | `0x1388` = 5,000 pips = 0.50%, on every live pool, with no increase pending on any of them |

**Do not hardcode the `MarketLens` address in the plugin.** It is a plain immutable contract,
not a proxy, so a revision is a new address rather than an upgrade in place, and the row above
is already its second replacement: the 2026-09-20 redeploy that superseded
`0x0a3d8332D949b4aE650f3aC6468620e403a50fF1`. Resolve it from `core.marketLens` in
`deployments/asset-markets-mainnet-v6.json`, or make it a pool-list config field the way the
other v4 hook plugins take their addresses. Every function on the current lens is `view`,
including the four quote functions, so a simulator can `STATICCALL` the whole surface; the
predecessor could not be reached that way, which is the practical reason to be sure which one
you are pointed at.

**Only market ids 13 to 18 are live.** Ids 1 to 12 exist on the factory but are zero-liquidity
leftovers from earlier deploys and must be filtered out of any pool list. All six live pools
carry `fee = 5000` (the 0.50% LP tier), `tickSpacing = 50` and `hooks =
0xc9932584c5154e4F58313a2e5423522E74e540Cc`:

| id | Asset | currency0 | currency1 | poolId |
|---|---|---|---|---|
| 13 | NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` (NVDA) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD) | `0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61` |
| 14 | SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` (SPCX) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD) | `0x973ed4693085eef0e03837dd45ea535684824f56787bf71987cd7cfb70f06576` |
| 15 | AI | `0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18` (AI) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD) | `0x9f8629af761ca0c5f5ed8dfc08c4922495900f30074a0e53f7839e7b5d318f58` |
| 16 | SDOGE | `0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C` (SDOGE) | `0xA138D500c4f96B6Fa319719bA325e6DE62C567b4` (SDOGE.d) | `0x55db22f2da53a8dd00b9fa6098abd910e65459287a3e43f855ddee595774536e` |
| 17 | ABR | `0x1Aa1526302625de02791538DB45c45E96bb75A70` (ABR.d BRAND) | `0x2165962eb8BF56354bF7053071E515dC9818DfbF` (ABR ASSET) | `0xd13cae7d56ec36517d98d07a9150a741a43bedc7e08b780c5bc96239643a6cc8` |
| 18 | CORGIGG | `0x17A5C7E9293199271f985eDAC74366015DA96FaD` (CORGIGG) | `0xe0588f17797e79B51a42CBE4bEbab0C1241F98a4` (CORGIGG.d) | `0xa9f88e287df2fbb721eaf51ad7354abed40eb21851434f66fc5c5a77a84912f7` |

**Market 17 has the BRAND as `currency0`; the other five have the asset as `currency0`.** Read
the ordering off `AssetMarketFactory.poolKeyOf(id)` and never assume it. That one row is the
concrete proof of why.

Reproduce the live rate on market 13 (`feePipsFor(poolId)`, selector `0xe7a39528`):

```
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0xc9932584c5154e4F58313a2e5423522E74e540Cc","data":"0xe7a39528f71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61"},"latest"]}' https://rpc.mainnet.chain.robinhood.com
```

## Still missing before the PR

Their contribution rules want sample transactions and quote-comparison evidence — the
simulator's output against real on-chain fills. **We do not have those yet, and they are the
remaining blocker.** Somebody has to produce real fills on the six live pools and diff them
against the simulator.

What is no longer open is the pricing question this section used to end on. Kyber's fallback
priced 1,000 brand units at $898 and quoted a 29% loss on a $1,000 brand→asset route, and it was
not clear whether the pools were genuinely that thin or the fitted model was wrong about them.
`MarketLens.quoteBuy`, read at block 68,293,146, settles it: **the pools really are that thin,
and if anything the fallback flatters them.** Buying market 13's asset with 1,000 USDG moves the
price +108.31% against the 1-unit reference, against Kyber's implied ~29%. Measured price impact
across the six pools, a snapshot of current seed liquidity at that block:

| id | Asset | spot (USDG) | impact at 100 | at 1,000 | at 10,000 |
|---|---|---|---|---|---|
| 13 | NVDA | 249.4821 | +10.73% | +108.31% | +1084.04% |
| 14 | SPCX | 170.8470 | +13.13% | +132.47% | +1325.86% |
| 15 | AI | 0.2865 | +10.93% | +110.31% | +1104.04% |
| 16 | SDOGE | 0.00004087 | +1.18% | +11.93% | +119.40% |
| 17 | ABR | 0.00000515 | +3.40% | +34.26% | +342.95% |
| 18 | CORGIGG | 0.0000120 | +2.22% | +22.44% | +224.61% |

These numbers will not describe the pools after launch. Re-measure with `MarketLens.quoteBuy`
at integration time.

Two things follow, and both belong in the PR rather than being discovered by a reviewer:

1. **Describe the v4 pools as what they are.** Liquidity is deliberately small right now; these
   are seed pools, and the integrations are going in ahead of a hard launch rather than
   afterwards, so that routing works from day one instead of arriving months later. The deep leg
   of this system is the reserve, not the pool: `SharedReservePool` at
   `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` backs all six live markets and holds ~9.96M USDG
   of mint headroom with ~35,276 USDG redeemable at par less a 20 bps fee. That is the liquidity
   worth routing through today, and it needs the separate source described in
   `docs/KYBERSWAP_INTEGRATION.md` §3.4.
2. **The plugin's value is not depth, it is accuracy.** A fitted fee is a guess about a number
   the contract will hand over for free and that can move between blocks. Registering the plugin
   is what makes a discrepancy like the one above diagnosable instead of mysterious.

See `docs/KYBERSWAP_INTEGRATION.md` §1.1 for the original measurement.
