# KyberSwap integration — what it is, what is built, what is left

Written 2026-09-18; technical claims re-verified against chain and against `src/` on 2026-09-20
at block **68,293,146**. Every number and behaviour marked **measured** below came from a live
call against Robinhood Chain mainnet; everything else is from Kyber's documentation and source,
cited inline.

**Two things to know before reading.** First, this repository is contracts and tests only: §2
describes work that lives in the separate application repository, and the `web-stable/` paths it
cites do not resolve here. §1, §3 and §4 are the parts a KyberSwap reviewer needs, and they are
self-contained. Second, the protocol fee moved from `beforeSwap` to `afterSwap` on 2026-09-19
and is now charged on the swap's UNSPECIFIED leg. If you have an older copy of this document,
or of `docs/AGGREGATOR_INTEGRATION.md`, that is the claim to re-read: §3.3 states the current
behaviour and the Go plugin under `integrations/kyberswap-dex-lib/hooks/stables-fast/`
implements it.

`docs/AGGREGATOR_INTEGRATION.md` is the companion to this file. It describes the Stables stack to
an aggregator in aggregator-neutral terms and was written for 0x Settler. This one is
KyberSwap-specific, and it goes in **both** directions, because with Kyber the two are genuinely
different pieces of work:

| Direction | What it means | Whose repo the work lands in | Status |
|---|---|---|---|
| **Demand side** — *we use Kyber* | The app sources a leg of a trade from Kyber, so a wallet holding any routable token can buy or sell a Stables market asset | ours | **built here**, see §2 |
| **Supply side** — *Kyber uses us* | Stables markets become a liquidity source Kyber's router can quote and settle through | `KyberNetwork/kyberswap-dex-lib`, plus their executor | **partly live already** — the v4 leg routes today; the reserve leg does not. See §1.1 and §3 |

**What exists today, before any of the detail below.** A typed TypeScript client for Kyber's
aggregator API, the arithmetic that joins an aggregator leg to a market leg, and a live dry run
that proves the path end to end against mainnet. The supported shape is **two transactions**: the
aggregator swap, then `MarketRouter` or a `BrandPsm` window, both of which are already on chain.
The one-transaction zap contract is not shipped and is not in this repo; see §2.5.

---

## 1. The headline: Kyber is already on our chain

**Measured.** KyberSwap serves Robinhood Chain under the slug `robinhood`, and the full
quote → encode → calldata loop works today:

```
GET  https://aggregator-api.kyberswap.com/robinhood/api/v1/routes?tokenIn=…&tokenOut=…&amountIn=…
POST https://aggregator-api.kyberswap.com/robinhood/api/v1/route/build
```

| Thing | Value |
|---|---|
| Chain slug | `robinhood` (chainId 4663). `arc` is also listed; neither Robinhood testnet nor Base Sepolia is. |
| Router | `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5` (`MetaAggregationRouterV2`) — returned as `routerAddress`, and the address the input token is approved to. **Read it off the response, never hardcode it:** Robinhood is one of only four chains that also has `KSAggregationRouterV3` deployed, at `0x6868d319c8c9a78f7d39dc3602c5c917315132d7` (verified: both have code). |
| Input rescaler | `InputScalingHelperV2` `0x2f577A41BeC1BE1152AeEA12e73b7391d15f655D`, an upgradeable proxy. See §2.5. |
| Approval model | Direct. **No Permit2, no transfer proxy** — the router pulls with `transferFrom(msg.sender)`. `permit` (EIP-2612, selector stripped) is the alternative. |
| Encoded selector | `0xe21fd0e9` = `swap(SwapExecutionParams)` |
| Native sentinel | `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` |
| WETH | `0x0bd7d308f8e1639fab988df18a8011f41eacad73` |
| Tokens it knows | USDG `0x5fc5…d168` **yes**; sUSDai `0x0B2b…5ef9` **no** (`4011 token not found`) |
| Venues it indexes there | **92 enabled sources**, per `https://ks-setting.kyberswap.com/api/v1/dexes?chain=robinhood&isEnabled=true`. Includes `uniswap-v4-fee` (ours — §1.1) and a dozen other `uniswap-v4-*` hooks, plus RFQ/market-maker sources (`bebop`, `native-v2`, `pmm-18`, the `*-prop` family) that are reachable only through the V1 endpoints and are the reason a route must not be held more than a few seconds |
| Stables markets | **already indexed.** See §1.1 — this is not what we expected to find. |

So the demand side is available immediately, and the supply side turns out to be half done already.

### 1.1 Kyber already routes through our markets

**Measured.** Asked for a route between market 13's two tokens — brand `0xe7bb…e596` and asset
`0xd060…9eec`, whose `poolKeyOf(13)` names hook `0xc9932584…40Cc` and `PoolManager`
`0x8366a39C…0951` — the aggregator returns a route, and the hop's `exchange` is
**`uniswap-v4-fee`** with `poolType: uniswap-v4`. Several of our pool ids appear across the four
directions tested: `0xf71c2e4f…`, `0x973ed469…`, `0x9f8629af…`.

That is confirmed in dex-lib's source: `pkg/liquidity-source/uniswap/v4/constant.go` maps
`valueobject.ChainIDRobinhood` to PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951` —
byte for byte the canonical manager in `docs/AGGREGATOR_INTEGRATION.md`. Kyber's Uniswap v4 source
is live on our chain and discovering our pools.

**How, and what is still unknown.** dex-lib handles hooks by plugin: a `Hook` implementation
is registered against its own address in `HookFactories`, and anything unregistered falls through
to `SetFallbackHookFactory` — an auto-detection model that *fits* a hook's fee from quoter probes
rather than reading it. The `cashcat` plugin, also on Robinhood Chain, states the precedence rule
in its own package comment: *"pools on this hook must NOT fall through to the auto-detection
fallback: explicit registration in HookFactories takes precedence over it."*

What is certain: **there is no `stables` plugin.** `pkg/liquidity-source/uniswap/v4/hooks/`
contains ~32 packages and none of them names our hook address.

What is not certain is what `uniswap-v4-fee` actually is. It has no constant in the public
`pkg/valueobject/exchange.go` alongside the thirty-odd named `ExchangeUniswapV4*` entries, which
points at the fallback — but it *is* in Kyber's live enabled-source list for this chain, which a
pure fallback arguably would not be, and Kyber runs a `kyberswap-dex-lib-private` alongside the
public repo. So it is either the auto-detection fallback or a generic fee-hook plugin we cannot
read. **Either way our fee is being inferred rather than read**, and either way the ask in §3 is
the same. Worth asking them outright rather than guessing.

**The pricing discrepancy, and its answer.** In the same measurement, Kyber priced 1,000 units
of a brand token at **$898**, not $1,000 — and a brand is a 1:1 claim on a reserve holding USDG.
At 1 brand the quote is sane (−0.3% round trip); at 1,000 brand the route reported a 29% loss.
Either the pools really were that thin at that size, or the fallback's fitted model was wrong
about them.

**Settled on 2026-09-20 against `MarketLens.quoteBuy` at block 68,293,146: the pools really are
that thin, and the fallback if anything flatters them.** Buying market 13's asset with 1,000
USDG moves the price **+108.31%** against the 1-unit reference price, where Kyber's quote
implied roughly 29%. The same shape holds across all six live pools (§3.5 carries the table).
So there is nothing mispriced to fix on our side. The framing for a listing conversation is that
the v4 pools hold seed liquidity today, deliberately, because we are getting the integrations in
place ahead of a hard launch rather than afterwards, while the deep leg is the reserve, which is
§3.4. The plugin in §3.3 is still worth doing, but for accuracy rather than for depth: it
replaces a fitted fee with a free exact read that can change between blocks.

---

## 2. Demand side — the app sources a leg from Kyber

### 2.1 Why this is worth doing

Every market's stable side is a brand token, a 1:1 claim on a `SharedReservePool` holding USDG,
so a USDG trade is already two legs. `MarketRouter.buyWithUsdg` hides both on the way in.
**There is a one-call sell to USDG on chain too, as of 2026-09-19:** `sellForUsdg`
(`src/markets/MarketRouter.sol:430`, selector `0xb9077071`) does the pool leg and the redemption
in one transaction, and `docs/AGGREGATOR_INTEGRATION.md` §4 carries the deployment detail. This
paragraph used to say it was in source but not on chain; that stopped being true on 2026-09-19.
`sellForBrand` remains for a caller who wants to stop at the market's own dollar and price the
exit themselves. What the router cannot do in either case is *start from a token that is not
USDG*.

The app's only answer to that today is `web-stable/src/web3/eth-zap.ts`: one hand-picked Uniswap
v3 WETH/USDG pool, chosen by reading `liquidity()` on four fee tiers, and quoted by
`quoteEthSale()` — which multiplies by `sqrtPriceX96²` and **ignores price impact entirely**, as
its own comment admits. One token, one venue, one spot price. Kyber replaces exactly that: every
pool on the chain, impact priced in, multi-hop, in one HTTP call.

```
buy  with X:  X --KyberSwap--> USDG --MarketRouter.buyWithUsdg--> asset
sell to   X:  asset --MarketRouter.sellForUsdg--> USDG --KyberSwap--> X
              (or asset --sellForBrand--> brand --SharedReservePool.redeem--> USDG --KyberSwap--> X)
```

### 2.2 The finding that shapes everything: `/route/build` is an encoder, not a re-quote

**Measured, and this is the important paragraph in this document.** Post a `routeSummary` to
`/route/build` with `amountOut` doubled and `checksum` deleted, and the API returns **HTTP 200**,
a doubled `amountOut`, `outputChange.percent: 0`, and calldata whose encoded `minReturnAmount` is
doubled to match — word 85 of the calldata moved from `260476487` to `520952976`. The endpoint
verifies neither the checksum nor the price.

Three consequences, each of which is load-bearing in the code:

1. **`outputChange` is not a staleness signal.** It compares the build against the summary it was
   handed, so a summary that is minutes old reports no change at all. Freshness is ours to
   enforce: `KYBER_ROUTE_MAX_AGE_MS = 8_000`, under Kyber's own documented 5–10 second ceiling,
   and `buildKyberSwap` refuses a stale route rather than encoding a transaction that will
   revert.
2. **A `routeSummary` is attacker-controlled input that sets an on-chain minimum.** Never forward
   one on a caller's behalf, and never let a contract of ours rely on Kyber's encoded minimum.
   Measure the balance delta on chain instead; see §2.5.
3. **The summary must round-trip byte for byte** — but not for the reason the field names
   suggest. `checksum` and `routeID` are *telemetry*: a build with `checksum` set to `"0"`, or
   with `routeID` deleted entirely, returns byte-identical calldata. What is load-bearing is each
   hop's `extra._ce`, which carries the executor's plan for that hop and is read when the route
   is encoded. A zod `.parse()` returns a *new* object holding only the declared keys and would
   drop it. `assertRouteSummary` is therefore an assertion function that narrows in place; a test
   pins the whole object's identity through a fetch-then-build cycle.

Mutating a summary was tested more broadly than the doubled `amountOut` above, and every one was
accepted silently: a rewritten hop pool address, a doubled per-hop `amountOut`, a `timestamp`
rolled back an hour, and a summary 299 seconds old. Nothing server-side rejects any of it.

The safe failure mode is worth stating too: a stale route still encodes, and then simply reverts
on chain against its own stale minimum. Nobody loses money; they lose gas.

### 2.3 What is built

| File | What it is |
|---|---|
| `web-stable/packages/market-core/src/kyberswap.ts` | The typed client. Chain-slug table, `fetchKyberRoute`, `buildKyberSwap`, freshness, error mapping from Kyber's numeric codes, `kyberRouteVenues`. Environment-free and dependency-light: it takes a base URL and never reads `process.env`. A deliberate leaf module — no relative imports — so `node --test` can load it directly. |
| `web-stable/packages/market-core/src/kyberswap-route.ts` | The arithmetic that joins an aggregator leg to a market leg: `composeRoute`, `splitTolerance`, `floorBy`, `externalShare`, `measuredDeparture`. Pure, no imports at all. |
| `web-stable/src/web3/kyberswap.ts` | The one place that decides *where* calls go — Kyber directly, or this app's own pass-through — plus `kyberSwapAvailable`. |
| `web-stable/src/app/api/kyberswap/[...path]/route.ts` | The optional server pass-through, for a deployment holding a gateway API key. |
| `web-stable/tests/kyberswap-client.test.mjs` | 11 tests, three of them pinning the §2.2 behaviour. |
| `web-stable/tests/kyberswap-route.test.mjs` | 7 tests on the composition arithmetic. |
| `web-stable/scripts/kyberswap-dry-run.mjs` | An end-to-end live dry run against mainnet — quote, encode, and `eth_call` the encoded swap against the real router. Signs nothing. See §2.8. |
| `integrations/kyberswap-dex-lib/hooks/stables-fast/` | The dex-lib hook plugin, staged for a PR into Kyber's repo. See §3.3. |

### 2.4 Slippage across two venues — the bug this design avoids

Applying the user's tolerance to each leg compounds it. 100 bps on the aggregator leg and 100 bps
on the market leg is a trade that can settle **199 bps** below the quote with both legs reporting
success, and the user agreed to 100. `splitTolerance` divides one tolerance across the legs
instead, remainder to the externally-priced leg, so the end-to-end bound is what was asked for.
Each leg is then individually tighter and marginally likelier to revert — which costs gas, where
the alternative costs money. `kyberswap-route.test.mjs` asserts both halves of that: that the
split bound clears the user's tolerance and that the naive version does not.

This is the same decision the application repository's slippage work is about to make for the
single-venue case. The two should ship with one `<SlippageSettings>` control and one default; a
route that crosses a venue we do not control is a good place for a warning. (The plan document
that used to be cited here lives in that repository, not this one.)

### 2.5 One transaction or two

**Two transactions works today and needs no new contract.** Both legs are live: Kyber's router,
and `MarketRouter`. The app sends the aggregator swap, measures what actually arrived, re-quotes
the market leg on the *measured* amount, and sends the second transaction. The existing
`createTradeLifecycle` already runs exactly this shape of continuation for the sell-zap
(`sellForBrand` then `redeem`), including the replay guard that stops a confirmed transaction
becoming a re-executable quote.

**One transaction is not shipped.** `KyberZapRouter`, the contract that would have collapsed both
legs into a single call, was removed from this repo before the external audit. It was never
deployed, it had no fork test, and paying an auditor to review a contract nobody uses is not a
good trade. It is recoverable in full, with its Foundry suite, at commit `2b4145bc`. **The
supported integration is the two-step flow above**, through the live `BrandPsm` windows and
`MarketRouter`, and nothing else in this document depends on the removed contract.

The rationale below is kept as guidance for whoever builds that path later, not as a description
of live code. A zap contract's whole risk surface is one call to an opaque payload, and three
rules contain it:

1. **The target must be immutable.** `aggregator` belongs in the constructor, unreachable by any
   caller, so the contract is not an arbitrary-call primitive holding approvals.
2. **The output must be measured, never quoted**: balance before and after, checked against the
   caller's own `minReserveOut` / `minTokenOut`. Per §2.2, Kyber's encoded minimum is worth
   nothing here. Measuring also makes a route built with the wrong `recipient` fail closed,
   because the measured delta is then zero and the trade reverts.
3. **Nothing may be left behind.** Allowances are set for the call and cleared after it, and every
   unspent input goes back to `msg.sender` in the same transaction.

Such a contract wants no owner, no pause, no upgrade path and no fee, because it holds nothing and
configures nothing. Deploy it when the one-transaction UX is worth an audit of its own, and not by
extending an existing upgradeable proxy: every one of those is owned by the 2-of-3 Safe
`0x28569c1716EF81f307d666A1EC08bDAE92AC0373` and upgradeable in one signed batch with no timelock
(`deployments/mainnet-state.json`, `deployments/safe-batches/README.md`).

### 2.5a Rescaling a leg whose amount is not yet known

**This is the correction that cost the most, and it is why this section outlives the contract.**
An early revision of the zap assumed Kyber's executor rescales a route's input to whatever the
caller actually holds. It does not: the executor spends the amount the calldata was encoded with.
That matters only on the sell side of a one-transaction zap, where the aggregator leg is encoded
against an *estimate* of what the market leg will produce and the true figure is discovered on
chain.

The real mechanism is a separate contract, `InputScalingHelperV2`:

```solidity
function getScaledInputData(bytes calldata inputData, uint256 newAmount) external view returns (bool isSuccess, bytes memory newScaledData);
```

**Measured** against `0x2f577A41BeC1BE1152AeEA12e73b7391d15f655D` on Robinhood Chain 2026-09-18,
with real calldata from a `onlyScalableSources=true` route: ±3% returned `isSuccess: true` with
rewritten calldata, and 80% of the encoded amount returned `isSuccess: false` with empty bytes.
So roughly a ±5% band, and a refusal rather than a revert outside it.

The shape that worked, for a future implementation: take the helper as an immutable constructor
argument, `staticcall` it with the measured amount, and forward the original calldata on any
failure. A refusal means "this route cannot be rescaled", not "this trade is unsafe", and a
minimum enforced on the contract's own measured balance is unaffected either way. Zero disables
the call, which is the kill switch Kyber asks integrators to have for an upgradeable proxy, and
the only one a contract with no owner can offer.

Two consequences for whoever builds it: request the sell route with `onlyScalableSources=true`
(the client already takes the flag), and keep the estimate fresh, because an estimate more than
~5% adrift cannot be rewritten. The transaction must then revert rather than force the trade
through, so that the seller keeps their asset. None of this applies to the two-step flow, which
encodes the aggregator leg only after the market leg has settled, on the amount that actually
arrived.

### 2.6 Configuration

| Variable | Where | Meaning |
|---|---|---|
| *(none)* | — | The default. The browser calls Kyber's public endpoint with `X-Client-Id: stables`, which is not a credential. |
| `NEXT_PUBLIC_KYBERSWAP_PROXY=1` | client + server | Route calls through `/api/kyberswap` instead. |
| `KYBERSWAP_API_KEY` | server only | Attached as `X-Api-Key` against `https://api.kyberswap.com/swap`, the paid gateway. Never reaches a bundle. Setting it *without* the flag changes nothing, which is the safe way round. |

The pass-through is a pass-through and not a proxy: one upstream host, two upstream paths, one
chain slug, and a fixed allowlist of query parameters — `feeAmount` and `feeReceiver` are
deliberately not forwardable, so a caller cannot redirect a fee through our key.

**A client id is no longer a way to raise a rate limit.** Kyber's docs: *"client-id whitelisting
is no longer offered for the Aggregator API. Rate limit increases are handled through API keys.
To request one, contact the KyberSwap team at business@kyber.network."* The public limit is 3 rps.
`X-Client-Id` is still worth sending (it is what appears as `Source` on chain when `source` is
omitted, and it is what their support will ask for), but if the app's quote polling ever outgrows
3 rps, the answer is an email and then `KYBERSWAP_API_KEY`, not a different client id.

### 2.7 What is left on the demand side

1. **UI.** A "pay with" / "receive as" token selector in `swap-panel.tsx`'s `extras` slot, the
   two-leg route shown as two lines with its venues named, and the aggregator leg's share of the
   trade surfaced (`externalShare`) so a user can see how much of the price is ours.
2. **Wiring the two-transaction flow** into a flow beside `createTradeLifecycle` rather than
   inside it. The machine quotes pools through one `deps.quote` signature, proves outputs by
   decoding `MarketRouter` events, and pins a trade identity across a continuation; an aggregator
   leg satisfies none of the three (HTTP quote, balance-delta proof, opaque calldata). Threading
   it through would mean loosening three invariants that exist to stop a confirmed transaction
   being replayed.
3. **A token list.** Kyber quotes anything it knows, but the app needs a curated list to show;
   `4011 token not found` is the failure for anything it does not (sUSDai, today).
4. **Retire or re-point `eth-zap.ts`.** Once the aggregator leg exists, the hand-picked v3 pool
   and its impact-free spot quote have no reason to remain. Note `LiquidityZapper`
   (`src/markets/LiquidityZapper.sol`) takes the v3 fee tier as a *contract* parameter, so the
   deposit path cannot be re-pointed without a contract change; the trade path can. **Point at
   V2, `0x57FA92648c722Bb28A0d011f020685B952110a2D`, and never at V1
   `0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd`:** V1 is ownerless and sandwichable, and is not
   a surface to recommend to anyone, integrator or user.
5. **Decide on `feeAmount` / `chargeFeeBy`.** Kyber can take a fee for us on either side of its
   leg, and in both cases `routeSummary.amountOut` comes back already net of it, so nothing needs
   subtracting client-side. The standing decision is to hold protocol fees at zero for now; this
   is the same decision and should get the same answer unless someone re-opens
   it. Note separately that positive slippage and the dust collector both accrue to **KyberSwap**,
   not to the user and not to us — neither is configurable.

### 2.9 Two things that will bite whoever wires the UI

**`tradeIdentity` is a safety mechanism, not a cache key.** `trade-lifecycle.ts` re-checks it at
every `await` boundary and `execute` refuses to submit against a quote whose identity has drifted.
A route id, an aggregator name or a scalable-sources flag that is *not* in that string will let a
stale route reach a wallet — and §2.2 established that nothing server-side will catch it. Extend
`tradeIdentity` first, before anything else.

**The quote seam and the calldata seam are not the same seam.** `TradeLifecycleDependencies.quote`
is cleanly injectable, but three other things are hardwired to `MarketRouter`: the send call, the
`Bought`/`Sold` receipt verifier, and `MarketTransactionContext.send`, which is ABI-encoded and has
no raw-calldata path at all. An aggregator settlement emits neither event and arrives as opaque
`data`, so all three need work. `LaunchPlan` in `packages/market-core/src/launchpad-write.ts` is
this repo's own precedent for describing a trade as data before executing it, and is the natural
thing to generalise.

**One placement decision to make deliberately.** The new client lives in
`packages/market-core/src/`, but web-stable's market and trade path re-exports from
`@stables/market-reader` (compiled, hash-verified by `check:market-reader` on every
pretest/prebuild); `@stables/market-core` is launchpad-only from web-stable's side. market-core
was chosen here because it ships TypeScript sources and needs no rebuild step, which keeps the
aggregator client testable without touching the verified artifact — but it does mean the trade
path would import from two shared packages. Decide it rather than let it drift.

### 2.8 Proof that it works, and why it is a script rather than a fork test

`node scripts/kyberswap-dry-run.mjs` quotes a route, encodes it, and `eth_call`s the encoded
transaction against Kyber's live router with the caller's balance supplied as a state override.
It signs nothing and broadcasts nothing; a failure is a real failure of the path. Run against
block 66,623,262 on 2026-09-18:

```
=== BUY: native → USDG → market 13's asset ===
  aggregator leg: 10000000000000000 wei → 26103602 USDG
  venues:         orvex-cl-feemanager
  encoded:        4036 bytes, selector 0xe21fd0e9
  simulation:     OK — the aggregator leg settles against the live router
  tolerance:      50 bps split 25 / 25 across two legs
```

**It is a script and not a Foundry fork test on purpose, and the reason is a property of this
chain.** The natural way to pin this would be a fork test at a fixed block with committed
calldata. Robinhood Chain's public RPC is not an archive node — it prunes state to roughly 100
seconds to 17 minutes of history, as `packages/market-core/src/chains.ts` documents at length —
so a pinned block stops answering within minutes of being chosen. A live dry run against the head
is the only end-to-end proof this chain supports. Plan for that when reviewing: there is no way to
make the aggregator half of this reproducible in CI without an archive node.

`MarketLens` IS deployed, at `0x704E7a0e7864250303B05b25EabC2417CE99ceb6`, and its source is
verified `exact_match` on Sourcify. This paragraph used to say it was not and that the market
leg was a placeholder; that stopped being true on 2026-09-19, and the address above is its
2026-09-20 redeploy, on which every function including the four quote functions is `view` and
therefore `STATICCALL`-able by a simulator. The predecessor
`0x0a3d8332D949b4aE650f3aC6468620e403a50fF1` is still live and still returns identical
amounts, but it wrapped Uniswap's `V4Quoter` and so could only be reached by a top-level
`eth_call`. The lens is not upgradeable, so every revision is a new address rather than a new
implementation behind a fixed one: read the live address from `core.marketLens` in
`deployments/asset-markets-mainnet-v6.json` rather than from here, and confirm the code at it
on chain, which cannot go stale the way this sentence did.

---

## 3. Supply side — Stables as a liquidity source

### 3.1 Where this actually stands

Not "get us listed". §1.1 measured that the v4 leg is **already routable**. What is left is
narrower and more specific:

| Leg | Status | Work |
|---|---|---|
| brand ↔ asset (the v4 pool) | **live**, quoted by dex-lib's auto-detection fallback as `uniswap-v4-fee` | replace the fitted fee with a read one — a hook plugin, §3.3 |
| USDG ↔ brand (`SharedReservePool`) | **absent**. Kyber reaches a brand only through whatever third-party v3/v4 pool happens to exist, at whatever price that pool is at | model the reserve, §3.4 |

The second row is the one that costs users money. A brand token is a 1:1 claim on USDG, mintable
and redeemable at par with at most a 20 bps redemption fee, and Kyber does not know that: it
prices a brand off thin external pools and, measured, values 1,000 of them at $898. Every route
into or out of a Stables market currently pays that spread instead of using the reserve.

### 3.2 How Kyber adds a venue, in general

Two halves, and only the first is open source.

**Off chain** is `github.com/KyberNetwork/kyberswap-dex-lib`, a public Go library external teams
contribute to by pull request. A source lives at `pkg/liquidity-source/<name>/` and implements:

| Interface | Methods | Job |
|---|---|---|
| `IPoolsListUpdater` | `GetNewPools(ctx)`, `UpdatePool(ctx, pool)` | Discover pools. **Must not** fetch reserves (use `0`) or token decimals; lowercase every address; prefer on-chain discovery to an index. |
| `IPoolTracker` | `GetNewPoolStateForListingUpdates(ctx, pools)`, `GetMetaInfo(ctx, pool)` | Refresh state. Batch through multicall, pin every read to one block, mutable state into `Extra` and immutable into `StaticExtra`. |
| `IPoolSimulator` | `CalcAmountOut(tokenIn, amountIn)`, `UpdateBalance(swapInfo)`, `CloneState()` | Price a swap in memory, mirroring the on-chain integer math **to the wei**. `CalcAmountOut` must be pure; zero output is an error; `CloneState` deep-copies. `uint256.Int` over `big.Int`. |

Optional: `IPoolExactOutSimulator` (`CalcAmountIn`), `IPoolSupportNativeSwap`, and
`CalculateLimit()` for shared inventory — which is the one that matters to us, see §3.4.

Registration for a **standalone source** is four steps: an exchange constant in
`pkg/valueobject`, a `DexType` in `pkg/pooltypes`, factory registration keyed by `DexType`, and
`go generate ./pkg/msgpack/...` (CI has a `generate-check` job that fails on a dirty tree).
Naming is `<protocol>-<family>`; `-v4` is reserved for V4/hooks and `-prop` for proprietary
venues.

A **hook plugin is much less than that** — one exchange constant plus a regenerated
`pkg/msgpack/register_pool_types.gen.go`. Every hook shares `DexType = "uniswap-v4"` and differs
only by its `Exchange` string, so `pkg/pooltypes` is not touched and no factory registration is
needed. Do not skip the generate step: that generated file is the *only* place v4 hook packages
are imported, so its `RegisterConcreteType` line is what fires the package's
`RegisterHooksFactory` side effect. Skip it and the plugin compiles, never registers, and
`generate-check` fails on the dirty tree. That is still the whole reason §3.3 is the cheap ask.

Reviewers hold contributors to a specific set of correctness rules, worth knowing before writing
anything: `CalcAmountOut` must be pure (no mutation on success *or* failure); `UpdateBalance`
must consume the `SwapInfo` the calculation returned rather than recompute it; `CloneState` must
deep-copy everything `UpdateBalance` writes in place; on-chain integer math must be mirrored to
the wei; a zero-output swap is an error, never a zero quote; unconsumed input must be reported as
a remaining amount; and every flag the on-chain swap path checks — paused, capped, halted — must
be tracked so the simulator refuses what would revert. `uint256.Int` over `big.Int`. CODEOWNERS
is three people (`@NgoKimPhu @lehainam-dev @SunSpirit`), and measured turnaround on external v4
hook PRs is 1–8 days.

**On chain** is Kyber's `AggregationExecutor`, which is not open source. A genuinely new pool type
generally needs a handler there first, on Kyber's schedule. Both proposals below are shaped to
avoid that where possible.

There is, however, a documented escape hatch when it cannot be avoided: `ks-dex-adapter-lib`, a
second public repo where **the protocol writes its own Solidity adapter** (`executeXxx(bytes data,
uint256 amountIn, address tokenIn, address tokenOut, address recipient)`, input tokens already
transferred in, leftovers allowed to stay). `MachimaAdapter.sol` there is exactly the
"adapter calls the protocol's own router" shape ours would take. Treat it as a last resort: of
15 PRs, one external adapter has ever merged, it took 24 days, three others were closed unmerged,
and five are open now. Note also that its PR rules require the fork to be owned by a personal
account rather than an organisation, with "allow edits from maintainers" enabled.

Worth recording since it shaped an earlier draft of this document: **`swapSimpleMode` is not a
generic executor**. Its own source comment says it is for pools that can receive `tokenIn`
directly, i.e. a Uniswap-v2-style gas optimisation, and the per-sequence payload still goes to the
closed executor. There is no "unknown pool type" passthrough in the router.

### 3.3 The v4 leg: a hook plugin, not a new source

`pkg/liquidity-source/uniswap/v4/hooks/` holds ~32 plugins — `cashcat`, `doppler`, `clanker`,
`pons-v2`, `zora` and the rest — each registered against its hook's address:

```go
var _ = uniswapv4.RegisterHooksFactory(func(param *uniswapv4.HookParam) uniswapv4.Hook {
    /* … */
}, HookAddresses...)
```

The two callbacks the plugin has to model are shaped like this in dex-lib:

```go
type BeforeSwapResult struct {
    DeltaSpecified   *big.Int // CalcOut: in  -= specified
    DeltaUnspecified *big.Int // CalcOut: out -= unspecified
    SwapFee          FeeAmount
    Gas              int64
    SwapInfo         any
}

type AfterSwapResult struct {
    HookFee *big.Int // CalcOut: out -= hook fee; CalcIn: in += hook fee
    Gas     int64
}
```

**Only the second one carries our fee, and that is the single most important sentence in this
section.** Since 2026-09-19 `ProtocolFeeHook.beforeSwap` returns
`BeforeSwapDeltaLibrary.ZERO_DELTA` unconditionally and charges nothing — it is in the callback
list purely to write an oracle observation — so **`DeltaSpecified` and `DeltaUnspecified` are
both always zero**. The entire fee is `AfterSwapResult.HookFee`, taken off the swap's
UNSPECIFIED leg and computed from the `BalanceDelta` the pool actually produced, on the same
`1e6` denominator (`FeeDenom`) the other fee hooks use. dex-lib's own comment on `HookFee`
("CalcOut: out -= hook fee; CalcIn: in += hook fee") is exactly our rule stated in the
simulator's vocabulary, so the mapping is direct. `hookData` is empty, so `GetHookData` returns
`EmptyBytes`.

An earlier revision of this document said the hook skimmed the **input** — exact-in as a
`BeforeSwapDelta` in `beforeSwap`, exact-out in `afterSwap`. That is the pre-2026-09-19
behaviour and it is now wrong in both halves. The staged Go plugin is correct; if the two ever
disagree, the code and `src/markets/ProtocolFeeHook.sol` win over this file.

dex-lib reads hook permissions by decoding the last two bytes of the hook address as a bitmap,
exactly as v4 does, so our mined `0x00CC` is understood with no work. One detail to confirm
rather than assume: `NewPoolSimulator` **refuses a pool outright** (`shared.ErrUnsupportedHook`)
when `HasSwapPermissions` is true and nothing is registered for the address. Our pools quote
today, so something is handling ours — the §1.1 question restated from the other side.

Three ways the plugin must differ from the `cashcat` template, all of them easy to get wrong:

1. **Our fee is mutable, and an increase is announced an hour ahead.** It is owner-settable per
   pool up to `MAX_FEE_PIPS`, which was lowered from 5% to **1% (10,000 pips)** on 2026-09-19.
   A DECREASE applies immediately and cancels anything pending; an INCREASE is scheduled by
   `setPoolFeePips` and can only be applied `FEE_INCREASE_DELAY` — **3,600 seconds** — later, by
   a permissionless `commitPoolFeePips(poolId)`, with the ceiling re-checked at commit. So a
   rate a router read cannot be raised under a quote inside the hour. `cashcat` reads its rate
   once and persists it because it is immutable for the pool's life; ours re-reads on every
   `Track`, because a decrease needs no notice and neither does the halt in item 2.

   **Read the delay as reliability, not as governance.** The hook is a UUPS proxy owned by a
   2-of-3 Gnosis Safe (`0x28569c1716EF81f307d666A1EC08bDAE92AC0373`) with **no upgrade
   timelock**, so the owner can replace the implementation — and the ceiling and the delay with
   it — in a single transaction. Say that plainly to Kyber rather than letting them infer a
   guarantee that is not there.
2. **Read `feePipsFor`, never `feePipsOf`.** `feePipsFor` returns 0 both when the pool has no fee
   recipient bound and while the protocol guard reports a halt — and trading continues in both
   cases. `feePipsOf` is the raw stored value and would over-charge every quote during a halt.
3. **Both directions charge the UNSPECIFIED currency, on realised amounts.** Since 2026-09-19
   the hook takes its cut in `afterSwap` for exact-input as well as exact-output, measured from
   the pool's own `BalanceDelta`. So an exact-INPUT swap pays its pips on the OUTPUT, and an
   exact-OUTPUT swap pays them on the realised INPUT. Neither is grossed up: the total on
   exact-out is `net + ⌊net·fee/1e6⌋`, not `net·fee/(1e6 − fee)`, which is what inverting a
   gross-input path would give and what the neighbouring hooks in that directory do.

   This replaced a `beforeSwap` skim on the REQUESTED input, which over-charged a partial fill
   on notional that never traded — the reason the change was made, and the reason a plugin must
   not reintroduce an input-side term. `MarketLens._grossInputFor` exists because quoting
   happens in the opposite mode from settlement, so "the unspecified currency" names a
   different leg in each; it carries two correction terms and no direction branch.

A hook plugin is also a much smaller change than a new source: every hook shares
`DexType = "uniswap-v4"` and differs only by its `Exchange` constant, so `pkg/pooltypes` is not
touched. One line in `pkg/valueobject/exchange.go`, the package itself, and
`go generate ./pkg/msgpack/...` to emit the import that registers it.

**The exchange id is `uniswap-v4-stables-fast`.** It is the protocol's actual name — the domain
is **stables.fast**, and the on-chain branding matches (`AIUSD.name()` is `"Stables AI USD"`).
It also avoids a collision that bare `uniswap-v4-stables` would have caused:
`uniswap-v4-stable-stable` already exists in their tree, is enabled on this same chain, and
displays as "Uniswap V4 Stable", so the two would be one character apart in their dashboards and
ops tooling. Give both reasons in the PR and offer to rename anyway: it is their namespace, and
a rename before merge costs nothing.

**The precedent to point at is on our own chain.** `stable-stable`
(`0x3b64660a35a09AfDe554cE545bca9166D6A23CC0`, Robinhood Chain) was added by PR #1669, opened
2026-09-13 and merged 2026-09-16. Read its diff before writing ours. Measured turnaround on
external v4 hook PRs generally is 1–8 days.

A merged PR does *not* enable the source, though. Which sources run on which chain is Kyber-side
deployment config in their `pool-service`, invisible from the public repo — ask for the flip in
the PR conversation, and name the chain-4663 values they will need: `UniversalRouterAddress`,
`Permit2Address` (`0x000000000022D473030F116dDEE9F6B43aC78BA3`), `Multicall3Address`
(`0xcA11bde05977b3631167028862bE2a173976CA11`) and `StateViewAddress`
(`0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804`, Uniswap's own, unmodified, already deployed).
Discovery is the open question there: the v4 lister is subgraph-driven and
Robinhood has no subgraph, so the route is log-based discovery off the PoolManager's `Initialize`
event plus `FetchTickFromStateView` — which is what dex-lib's own guidance prefers anyway
("discover pools on-chain over off-chain indexes").

`integrations/kyberswap-dex-lib/hooks/stables-fast/` carries the plugin — `hook.go`, `constant.go`,
the ABI, and `hook_test.go` plus `hook_live_test.go` pinned to the live 5,000-pip rate — staged
for a PR into `pkg/liquidity-source/uniswap/v4/hooks/stables-fast/`. Its README lists the two edits
their tree needs beyond the directory itself, and is the file to keep in step with the Go code.

**Why this is worth doing even though routing already works:** the fallback fits a fee by probing
a quoter. Ours is a number that can be read for free and can change between blocks. Reading it is
strictly more accurate, and it is what makes the §1.1 pricing discrepancy diagnosable instead of
mysterious.

### 3.4 The reserve leg

The v4 pool trades *brand ↔ asset*. Nothing on chain trades *USDG ↔ asset*. For Kyber to route
from USDG at par it needs the `SharedReservePool` as its own hop:

| Call | Arithmetic | Cap |
|---|---|---|
| `mint(brand, amount, receiver)` | `out = in`, 1:1, no fee | `liabilityCap − totalPooledSupply`; zero while paused. On the live sUSDai reserve that headroom is ~9.96M USDG |
| `redeem(brand, amount, receiver, minAssetsOut)` | `out = in − ⌊in·feeBps/10000⌋` — 20 bps on the live sUSDai reserve, 0 on the USDG/Morpho one | idle balance + what the yield source releases, **less one unit**. ~35,276 USDG redeemable on sUSDai |
| `swap(brandIn, brandOut, amount, receiver)` | `out = in`, no fee, same reserve only. Note the amount is the THIRD argument, so its calldata offset is 68 and not 36 | none |

Two properties of the fee that a simulator needs and would not otherwise infer:

- **`redemptionFeeBps` is capped at `MAX_REDEMPTION_FEE_BPS` = 100 (1%)**, and an INCREASE must
  be announced `FEE_INCREASE_DELAY` = 3,600 seconds ahead and then committed by a permissionless
  `commitRedemptionFee()`. A decrease is immediate and cancels a pending increase. So
  `previewRedeem`, which quotes the LIVE fee and never a pending one, is good for at least an
  hour in the adverse direction; `redemptionFeeEffectiveAt() == 0` is the single read that says
  nothing is scheduled. The same no-timelock caveat as §3.3 applies: the owner can upgrade the
  pool and remove the delay in one transaction.
- **Use the four-argument `redeem`.** The three-argument overload is now strict too — it derives
  its floor from par less the live fee, the same number `previewRedeem` returns, and reverts
  rather than under-paying — but it binds the caller to whatever fee happens to be live when the
  transaction lands. The four-argument form lets the simulator's own quote be the bound.

Three ways to give Kyber that hop, best first:

**(a) `litepsm` — config only, no Go, no executor work, and the one to lead with.** `BrandPsm`
(`src/pool/BrandPsm.sol`) exists precisely for this: it wears MakerDAO's `DssLitePsm` interface
over one brand's mint and redeem, so an aggregator that already integrates a PSM reaches the
reserve as a pool-list entry rather than a new venue. It is **deployed and permissionless** —
factory `0xB1e0ED28e24d3999216979847f9473b5C7bf12bA`, and the AIUSD window on the sUSDai reserve
is `0x1339b306Ce53d1393995D306BF7a365d4c825300`, reading `gem()` USDG (`dec()` 6), `dai()` AIUSD,
`pocket()` the reserve, `tin()` 0, `tout()` 2004008016032065 (the fee-on-top form of the 20 bps
fee-inclusive redemption fee). Configure it with `IsMint: true`.

  The caveat to hand them rather than let them find: with `IsMint: true` their tracker
  synthesises the dai-side reserve as `10^(9+decimals)` and only reads a real `balanceOf` on the
  gem side (`pool_tracker.go:133-161`). So the **redeem** direction is bounded by the reserve's
  idle USDG, conservatively, while the **mint** direction is modelled as unbounded and ignores
  `liabilityCap`. `MarketLens.maxMint` is the real bound.

**(b) `generic-simple-rate` — also config only, but strictly worse here.** Driven by
`RateMethod`, `RateUnit`, `IsRateInversed`, `IsBidirectional`, `PausedMethod` plus a pool-list
JSON. Two mismatches: it carries **one** rate in both directions, so it can model the 1:1 mint
or the fee-bearing redeem but not both; and it models **no capacity at all**. Usable on the
**zero-fee USDG/Morpho reserve** `0xdB48…d9F3`, which really is 1:1 bidirectional with no
liability cap. Not usable for the sUSDai reserve `0xCFa8…33B2` every live market uses. Mention
it only if they reject (a).

**(c) A `stables-reserve` source — exact, and the long pole.** Structurally the same as
`dai-usds`, `mkr-sky` or `litepsm`, all 1:1-ish converters with caps. It models the fee in the
redeem direction only and implements `CalculateLimit()` so the router knows the reserve's
capacity is **shared inventory across every brand in the group** rather than per pool — which is
true, and which nothing else in dex-lib would infer. This needs Kyber's executor to learn one
new call, so do not open with it.

**That shared-inventory shape is about to matter more, not less.** Today six markets draw on the
sUSDai reserve through four brands: the equities (13, 14, 15) share `AIUSD`, and the three
launchpad graduates (16, 17, 18) each have a brand of their own, minted when they graduated. A
pending contract change stops graduation from minting one — a launch keeps the dollar it raised
in — so new markets will keep arriving without adding brands, and the ratio of pools to brands
only grows. A per-brand capacity model would have been wrong from the start; it gets wronger with
every graduation. Model the reserve once, per reserve, and let `CalculateLimit()` share it.

`MarketLens` (`src/markets/MarketLens.sol`, written for the 0x work) is the on-chain surface all
three read: `maxMint`, `redeemableAssets`, `brandForRedeem`, `route`. **It is deployed, at
`0x704E7a0e7864250303B05b25EabC2417CE99ceb6`** — ownerless, stateless, every function `view` —
so the answer to "how is a simulator meant to learn the caps" is a live address rather than a
promise.

### 3.5 What a dex-lib PR has to contain

The repo's own rules: DEX background, pricing logic, documentation links, contract addresses,
explorer links, sample transactions, fixtures, and quote-comparison evidence — the simulator's
output against real on-chain fills. Full test coverage, `goimports -local`, and
`go generate ./pkg/msgpack/...` if simulator types changed.

One of those is still open, and it is the only real blocker left:

- **Stability.** `deployments/asset-markets-mainnet-v6.json` documents gen-4, gen-5 and gen-6
  inside a fortnight. A listing pins addresses; the stack needs to stop moving.

**Sample fills and quote-comparison evidence are no longer missing.** Two Foundry tests produce
them and both were re-run at head on 2026-09-20:
`test/markets/KyberAdapterParityMainnetFork.t.sol` (4/4) runs real exact-in, exact-out and
partial-fill swaps against the deployed hook and checks `pendingFees` against
`floor(base·pips/1e6)`; `test/markets/HookGasOverhead.t.sol` measures the hook against an
identical hookless pool. The quote comparison is `V4Quoter` against `/routes` back to back on
market 13: their fitted fee is within −0.20 bps at 0.01 NVDA in, −2.03 at 0.001, −8.71 at
0.0001 and −1,245 at 0.000001 — accurate where it matters, degrading as the amount shrinks,
which is exactly the case for reading the rate instead of fitting it.

The seed-liquidity picture below still holds and still belongs in the PR, as context for why
the pools are thin rather than broken:

| id | Asset | spot (USDG) | impact at 100 | at 1,000 | at 10,000 |
|---|---|---|---|---|---|
| 13 | NVDA | 249.4821 | +10.73% | +108.31% | +1084.04% |
| 14 | SPCX | 170.8470 | +13.13% | +132.47% | +1325.86% |
| 15 | AI | 0.2865 | +10.93% | +110.31% | +1104.04% |
| 16 | SDOGE | 0.00004087 | +1.18% | +11.93% | +119.40% |
| 17 | ABR | 0.00000515 | +3.40% | +34.26% | +342.95% |
| 18 | CORGIGG | 0.0000120 | +2.22% | +22.44% | +224.61% |

Measured through `MarketLens.quoteBuy` at block 68,293,146. It is a snapshot of current seed
liquidity and will not describe the pools after launch, so re-measure with
`MarketLens.quoteBuy` at integration time. Frame the reserve as the deep leg and the pools as
seed liquidity being wired up ahead of the hard launch.

**Verified source is no longer a blocker.** The v6 contracts are verified on **Sourcify** as
`exact_match`, compiler `v0.8.26+commit.8a97fa7a`, optimizer 200 runs, `via_ir = true`. Sourcify
rather than Blockscout because Blockscout's verify API on this chain sits behind a Cloudflare
challenge; verify by standard-JSON input, never flattened (`script/verify-mainnet-sourcify.sh`).
An earlier draft of this section listed "nothing in the v6 stack is verified" as a blocker.

### 3.6 The ask, in the order to make it

Everything dex-lib's contribution rules ask for now exists: `MarketLens` is deployed at
`0x704E7a0e7864250303B05b25EabC2417CE99ceb6`, the v6 contracts are verified on Sourcify as
`exact_match`, the fee model is verified against the deployed hook by fork test, and the
`MarketLens.quoteBuy` reconciliation against Kyber's live quote is done — its answer, that the
pools are genuinely thin and the fallback flatters them, is §1.1 and §3.5. What remains is
submission:

1. File the **issue** first. Their PR template says the project only accepts pull requests
   related to open issues, and a new feature should be discussed in one. Put the two open
   questions in it: what `uniswap-v4-fee` currently does with our pools, and whether log-based
   discovery plus `FetchTickFromStateView` is the path they want with no subgraph.
2. Open the **hook plugin** PR (§3.3), linking the issue. Smallest possible change, an executor
   path that already settles our pools today, and a named exchange id instead of a fitted
   fallback. Offer the rename on the exchange id rather than defending it.
3. In the same conversation, ask them to configure the existing **`litepsm`** source for
   `BrandPsm` as the USDG↔brand hop (§3.4a), flagging the `IsMint: true` capacity blindness
   explicitly so nobody is surprised by a revert on an oversized mint.
4. Ask for the per-chain enablement flip in `pool-service`, with the chain-4663 config values.
   A merged PR does not turn the source on.
5. Only if they reject (3): propose `stables-reserve` (§3.4c) and ask what executor work it
   implies. Expect this to be the long pole.

A dex-lib PR alone is necessary but not sufficient: the executor and per-chain enablement are
Kyber's, so there is a conversation to have alongside the code.

---

## 4. Appendix — reproducing the measurements

Each of these is a single line; run them from anywhere.

Quote native → USDG on Robinhood Chain:

```
curl -s -H 'X-Client-Id: stables' 'https://aggregator-api.kyberswap.com/robinhood/api/v1/routes?tokenIn=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE&tokenOut=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168&amountIn=100000000000000000&gasInclude=true'
```

Confirm a token Kyber does not know (expect `{"code":4011,…}`):

```
curl -s -H 'X-Client-Id: stables' 'https://aggregator-api.kyberswap.com/robinhood/api/v1/routes?tokenIn=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE&tokenOut=0x0B2b2B2076d95dda7817e785989fE353fe955ef9&amountIn=100000000000000000'
```

Encode a route (put the `routeSummary` from the first call into `body.json` alongside
`sender`, `recipient`, `slippageTolerance`):

```
curl -s -X POST -H 'Content-Type: application/json' -H 'X-Client-Id: stables' --data @body.json 'https://aggregator-api.kyberswap.com/robinhood/api/v1/route/build'
```

The §2.2 result is reproduced by doubling `routeSummary.amountOut` in `body.json`, deleting
`checksum`, and comparing word 85 of the returned `data` against the honest build's.

Confirm Kyber already routes through a Stables market — market 13's brand into its asset. The hop
comes back as `exchange: uniswap-v4-fee`:

```
curl -s -H 'X-Client-Id: stables' 'https://aggregator-api.kyberswap.com/robinhood/api/v1/routes?tokenIn=0xe7bb388959d89f809be24da16a1daba0dc58e596&tokenOut=0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec&amountIn=1000000'
```

Read the same market's `PoolKey` straight off the factory, to check the tokens above against the
hook at `0xc9932584c5154e4F58313a2e5423522E74e540Cc`:

```
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0x22AA61c589B90731752236c07d1455D0065bfc79","data":"0x18fe2928000000000000000000000000000000000000000000000000000000000000000d"},"latest"]}' https://rpc.mainnet.chain.robinhood.com
```

Error codes, for the client's message table: `4001` malformed query, `4002` malformed body,
`4005`/`4007` fee larger than the amount, `4008` no route, `4009` amount too large, `4010` no
eligible pools, `4011` unknown token, `4221` no WETH configured.

---

## 5. Where the code lives

This document was written in a worktree that no longer exists, and the section that used to sit
here described that worktree's branch, its symlinked `lib/`, its Foundry artifact directories and
a locally corrupted `npm ci`. None of that survives the extraction into this repository, and none
of it was ever of any use to a reviewer, so it is gone.

What matters for locating the work:

- **The dex-lib plugin is in this repository**, at
  `integrations/kyberswap-dex-lib/hooks/stables-fast/`. It is not part of this repository's build:
  there is no `go.mod`, and the files only compile inside dex-lib's module. Its own README is the
  authority on what it does and how to apply it to a dex-lib checkout.
- **The PR branch is not in this repository.** It is `feat/stables-fast-robinhood` in a clone of
  `KyberNetwork/kyberswap-dex-lib` at `../kyber/kyberswap-dex-lib`, carrying those files
  byte-for-byte plus the exchange constant and the regenerated msgpack registration. That clone
  also holds the three gitignored submission drafts — `ISSUE_DRAFT.md`, `PR_DESCRIPTION.md` and
  `SUBMISSION_RUNBOOK.md` — the last of which is the step-by-step for filing and opening.
- **The contracts it models are in this repository**, principally
  `src/markets/ProtocolFeeHook.sol` (the hook), `src/markets/MarketLens.sol` (the quoting and
  capacity surface), `src/markets/MarketRouter.sol` and `src/pool/SharedReservePool.sol` (the
  reserve leg of §3.4).
- **The TypeScript aggregator client of §2 is not in this repository.** It lives in the
  application repository, which is not part of this handoff. Every `web-stable/` and
  `packages/market-core/` path in §2 refers to that repository.

The one thing worth carrying forward from the old section, because it constrains how anything
here can be tested: **Robinhood Chain's public RPC is not an archive node.** It prunes state to
roughly 100 seconds to 17 minutes of history, so a Foundry fork test pinned to a block stops
answering within minutes of being chosen. Every end-to-end proof on this chain is a live run
against the head, and there is no way to make one reproducible in CI without an archive node.
§2.8 explains why the aggregator dry run is a script rather than a fork test for exactly this
reason.
