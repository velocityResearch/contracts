# Markets inventory for 0x

What is tradeable on Robinhood Chain mainnet (`chainId 4663`), how deep it actually is, and how to
discover the set programmatically.

Every address and every measured number in this document was read from chain at block
**68,293,146** on 2026-09-20, except the handful of structural reads noted inline as "read at head",
which are mappings and counters rather than prices.

Companion documents, which this one does not repeat:

- Hook mechanics and the safety review: [HOOK_SPECIFICATION.md](./HOOK_SPECIFICATION.md)
- Producing a number and settling it: [QUOTING_AND_SETTLEMENT.md](./QUOTING_AND_SETTLEMENT.md)
- Who can change what, and how fast: [SECURITY_AND_GOVERNANCE.md](./SECURITY_AND_GOVERNANCE.md)
- The venue-neutral integration write-up: [../AGGREGATOR_INTEGRATION.md](../AGGREGATOR_INTEGRATION.md)

## 1. Market model

A market is a Uniswap v4 pool on the canonical `PoolManager`
`0x8366a39CC670B4001A1121B8F6A443A643e40951` between two tokens:

- an **asset**, 18 decimals: a tokenized equity or a launchpad graduate. We never mint it and never
  control its supply.
- a **brand dollar**, 6 decimals: a `PooledBrandToken` that is a permanent 1:1 claim on a
  `SharedReservePool` holding USDG.

**There is no USDG in any pool.** USDG is the reserve's asset, not a pool currency. A
USDG-denominated trade is therefore always two legs:

```text
buy:   USDG --mint 1:1, free--> brand --v4 swap--> asset
sell:  asset --v4 swap--> brand --redeem 1:1 less redemption fee--> USDG
```

The mint leg is free and exactly 1:1. The redeem leg is 1:1 less the reserve's redemption fee (20
bps on the reserve every live market uses). Neither leg touches a curve, so neither leg has price
impact; the only slippage in a route is the v4 leg.

The reason the quote side is a brand rather than USDG directly is that the brand's backing earns
yield in the reserve and that yield pays the pool's liquidity providers. The pool gets a stable
quote token, the LPs get the float, and the reserve keeps the redemption promise. The cost to an
integrator is the extra leg described above.

**Three of the six markets share one brand.** The tokenized equities - NVDA (13), SPCX (14) and AI
(15) - all quote against the same `AIUSD`, so they are fungible on their dollar side: brand received
from selling NVDA can buy SPCX with no reserve round trip. Each launchpad graduate mints its own
brand instead (`SDOGE.d`, `ABR.d`, `CORGIGG.d`), so markets 16, 17 and 18 are not fungible with each
other or with the equity block. The factory exposes this directly as
`AssetMarketFactory.isSharedQuote(marketId)`, which reads `true` for 13, 14 and 15 and `false` for
16, 17 and 18 (read at head).

Two brands in the **same** reserve are freely interchangeable at 1:1 through
`SharedReservePool.swap(tokenIn, tokenOut, amount, receiver)`, no fee. Two brands in **different**
reserves are not interchangeable at all. See [section 4](#4-reserves).

## 2. The six live pools

All six share `fee` = 5000 (0.50% LP tier), `tickSpacing` = 50, and `hooks` =
`0xc9932584c5154e4F58313a2e5423522E74e540Cc` (`ProtocolFeeHook`).

| id | Asset | `currency0` | `currency1` | `poolId` |
|---|---|---|---|---|
| 13 | NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` (NVDA, asset) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD, brand) | `0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61` |
| 14 | SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` (SPCX, asset) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD, brand) | `0x973ed4693085eef0e03837dd45ea535684824f56787bf71987cd7cfb70f06576` |
| 15 | AI | `0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18` (AI, asset) | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` (AIUSD, brand) | `0x9f8629af761ca0c5f5ed8dfc08c4922495900f30074a0e53f7839e7b5d318f58` |
| 16 | SDOGE | `0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C` (SDOGE, asset) | `0xA138D500c4f96B6Fa319719bA325e6DE62C567b4` (SDOGE.d, brand) | `0x55db22f2da53a8dd00b9fa6098abd910e65459287a3e43f855ddee595774536e` |
| 17 | ABR | `0x1Aa1526302625de02791538DB45c45E96bb75A70` (ABR.d, **brand**) | `0x2165962eb8BF56354bF7053071E515dC9818DfbF` (ABR, **asset**) | `0xd13cae7d56ec36517d98d07a9150a741a43bedc7e08b780c5bc96239643a6cc8` |
| 18 | CORGIGG | `0x17A5C7E9293199271f985eDAC74366015DA96FaD` (CORGIGG, asset) | `0xe0588f17797e79B51a42CBE4bEbab0C1241F98a4` (CORGIGG.d, brand) | `0xa9f88e287df2fbb721eaf51ad7354abed40eb21851434f66fc5c5a77a84912f7` |

### WARNING: market 17 inverts the currency ordering

> **Five of the six pools have the asset as `currency0`. Market 17 has the BRAND as `currency0`.**
>
> `PoolKey` sorts by raw address, and `0x1Aa1...` (ABR.d) sorts below `0x2165...` (ABR). Nothing
> about being an asset or a brand determines the side. Any code that assumes "brand is always
> `currency1`" or infers `zeroForOne` from token role will produce a **backwards swap direction on
> market 17**, which is not a bad quote - it is a swap in the wrong direction against a thin pool.
>
> Read the ordering from `AssetMarketFactory.poolKeyOf(marketId)` or
> `MarketLens.route(marketId).poolKey` and derive direction by address comparison only:
>
> ```solidity
> PoolKey memory key = factory.poolKeyOf(marketId);
> bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
> ```
>
> Market 17 exists as a live, funded counterexample. Use it as the regression test for this
> assumption before routing any of the six.

## 3. Dead markets: ids 1 to 12

`AssetMarketFactory.marketCount()` reads **18** (read at head). Ids 1 through 12 are zero-liquidity
leftovers from earlier deploys. They are real registry records with real `PoolKey`s and initialized
pools, so they will not revert when you query them; they simply have nothing in them. Spot reads at
head: `MarketRouter.marketLiquidity(1)`, `(6)` and `(12)` all return 0, while `(13)`, `(16)` and
`(18)` return non-zero.

Do not hardcode "13 through 18". Filter:

```solidity
// MarketRouter 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4
// marketLiquidity(id) == poolManager.getLiquidity(factory.poolKeyOf(id).toId())
bool live = router.marketLiquidity(marketId) > 0;
```

Two supporting lookups on the factory:

| Call | Use |
|---|---|
| `marketFor(address reserve, address asset) -> uint256` | The one canonical market for a (reserve, asset) pair. Returns 0 rather than reverting when there is none. |
| `marketOfPool(bytes32 poolId) -> uint256` | Reverse lookup, pool to market id. Verified at head: the market-13 `poolId` maps back to 13. |

`marketFor` takes the reserve explicitly because the same asset may have one market per reserve.
**Passing `address(0)` means the factory's default reserve**, which is
`0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` (the USDG/Morpho reserve, confirmed by
`factory.reservePool()` at head). No live market uses that reserve, so `marketFor(address(0), asset)`
returns 0 for all six of our assets. To find them, pass the sUSDai reserve address explicitly.

The same zero-means-default convention appears on the market record itself: a `Market.reservePool`
of `address(0)` is a record written before the factory served more than one reserve and belongs to
the factory's default. `MarketLens` already resolves this for you in `route(id).reservePool`. All
six live records carry an explicit reserve, so you will not hit the zero case today, but the
convention is load-bearing if you read `market(id)` raw.

## 4. Reserves

Both reserves hold USDG. A brand belongs to **exactly one** reserve and cannot cross: the free 1:1
`SharedReservePool.swap` only works between brands in the same pool, and there is no path that
converts a brand of one reserve into a brand of another without a full redeem and mint.

| Reserve | Address | `redemptionFeeBps` | `totalAssets` (6dp) | `liabilityCap` (6dp) |
|---|---|---|---|---|
| sUSDai-backed | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` | 20 | 35,276,269,401 (~35,276 USDG) | 10,000,000,000,000 (10M USDG) |
| USDG / Morpho (factory default) | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` | 0 | 1,000,440 (~1.00 USDG) | 0 (uncapped) |

Neither reserve has a pending fee change at the read block.

**All six live markets sit on the sUSDai reserve.** The USDG/Morpho reserve is the factory's default
but backs no live market and holds about one dollar; treat it as unused. If you index reserves
generically, index them by the reserve that `MarketLens.route(id)` reports, not by the factory
default.

Capacity on the sUSDai reserve, both from `MarketLens`:

| Quantity | Value | Meaning |
|---|---|---|
| `maxMint(pool)` | 9,964,932,271,009 (~9.96M USDG) | How much USDG the buy leg can still absorb before `liabilityCap` binds |
| `redeemableAssets(pool)` | 35,276,269,400 (~35,276 USDG) | How much USDG the sell leg can pay out this block |

`previewRedeem(1000 USDG)` on the sUSDai reserve returns 998,000,000, which is 998.00 USDG: the 20
bps fee and nothing else. The redemption fee has a hard implementation ceiling,
`SharedReservePool.MAX_REDEMPTION_FEE_BPS` = 100 (1%).

Both capacity figures move with every mint, redeem and keeper action, so read them per quote rather
than caching. The mechanics of the two legs and the correct `redeem` overload are in
[Quoting and settlement](./QUOTING_AND_SETTLEMENT.md); the governance question of who can move the
fee and the cap is in [Security and governance](./SECURITY_AND_GOVERNANCE.md).

## 5. Depth, stated honestly

These pools are small. The numbers below are measured `MarketLens.quoteBuy(id, usdgIn)` results at
block 68,293,146, not estimates, and they are not flattering.

Price impact is stated against the 1-USDG reference quote on the same pool at the same block. The
reference quote pays the same LP fee and the same hook fee, so these columns are approximately pure
slippage. Total cost to a taker is slippage **plus** the roughly 1% all-in fee (0.50% LP tier plus
0.50% hook skim).

| id | Asset | spot (USDG) | 100 USDG | 1,000 USDG | 10,000 USDG |
|---|---|---|---|---|---|
| 13 | NVDA | 249.4821 | +10.73% | +108.31% | +1084.04% |
| 14 | SPCX | 170.8470 | +13.13% | +132.47% | +1325.86% |
| 15 | AI | 0.2865 | +10.93% | +110.31% | +1104.04% |
| 16 | SDOGE | 0.00004087 | +1.18% | +11.93% | +119.40% |
| 17 | ABR | 0.00000515 | +3.40% | +34.26% | +342.95% |
| 18 | CORGIGG | 0.0000120 | +2.22% | +22.44% | +224.61% |

Approximate TVL, from a constant-product fit that reproduces the measured quotes to within 0.5%:

| id | Asset | asset side | brand side | TVL |
|---|---|---|---|---|
| 13 | NVDA | 3.72 | 927.61 | ~$1,855 |
| 14 | SPCX | 4.44 | 757.78 | ~$1,516 |
| 15 | AI | 3,179.69 | 910.98 | ~$1,822 |
| 16 | SDOGE | 214,117,668 | 8,751.70 | ~$17,503 |
| 17 | ABR | 575,478,769 | 2,961.92 | ~$5,924 |
| 18 | CORGIGG | 379,836,157 | 4,558.20 | ~$9,116 |
| | | | **TOTAL** | **~$37,736** |

Total pool TVL across all six markets is about **$37.7k**. Market 13 is under two thousand dollars
deep. A thousand-dollar buy on market 14 costs 132% in slippage. There is no reading of these
numbers under which the v4 pools are a meaningful venue at institutional size today, and we are not
going to pretend otherwise.

**The deep leg is the reserve, not the pools.** The sUSDai reserve will absorb about 9.96M USDG of
mint and pay out about 35,276 USDG of redemption, both at 1:1 with no price impact. That is two to
three orders of magnitude more capacity than the pools, which means: on any USDG-denominated route,
the v4 leg is the binding constraint and the reserve legs never are. Size against the pool.

### Deriving a maximum routable size

The measured table is linear in size: on every pool, impact at 1,000 USDG is 10.1x its impact at
100 USDG, and impact at 10,000 USDG is 101x. Constant product is not just a good fit here, it is
exact: every one of the six pools holds a single full-range position and no other initialized tick,
so there is no concentrated liquidity to step through. For an exact-input trade of `dx` against
reserves `(X_brand, Y_asset)`, the average execution price is `(X + dx) / Y` against a spot of
`X / Y`, so

```text
impact(dx) = dx / X_brand      exactly, for any dx
```

Impact is therefore exactly proportional to size, and the measured 100 USDG row inverts directly:

```text
size_at_impact(p) = 100 USDG * p / impact_at_100_USDG
```

Applying that to the measured column, and rounding **down** to stay conservative:

| id | Asset | impact @ 100 USDG | 0.5% cap | **1% cap** | 2% cap |
|---|---|---|---|---|---|
| 13 | NVDA | 10.73% | 4.6 USDG | **9.3 USDG** | 18.6 USDG |
| 14 | SPCX | 13.13% | 3.8 USDG | **7.6 USDG** | 15.2 USDG |
| 15 | AI | 10.93% | 4.5 USDG | **9.1 USDG** | 18.2 USDG |
| 16 | SDOGE | 1.18% | 42 USDG | **84 USDG** | 169 USDG |
| 17 | ABR | 3.40% | 14 USDG | **29 USDG** | 58 USDG |
| 18 | CORGIGG | 2.22% | 22 USDG | **45 USDG** | 90 USDG |
| | | | | **184 USDG total** | |

Worked example for id 16: `100 * 1.0 / 1.18 = 84.7`, rounded down to 84 USDG. Cross-check against
the fitted brand reserve, `0.01 * 8,751.70 = 87.5 USDG`; the measured inversion is the more
conservative of the two, which is why we use it.

**Recommendation.** Cap routable size per pool at the 1% column, which is 184 USDG across all six
markets combined. Below that the venue is priced correctly and settles cleanly. Above roughly the 2%
column, a split route through any other venue will beat us and the quote is not worth serving.

Two qualifications, both in your favor:

- These are buy-side figures. The sell side runs the same curve, and the extra reserve leg on a sell
  is capped at 35,276 USDG redeemable, which is about 190x the aggregate 1% size. The reserve is not
  the binding constraint at any size the pools can support.
- Depth is a snapshot, not a constant. Re-read it. `MarketRouter.marketLiquidity(id)` is the cheap
  per-block liquidity read, and `MarketLens.quoteBuy` is the exact one. If liquidity grows, the
  derivation above regenerates from one fresh 100 USDG quote per pool.

## 6. Discovery

### Enumeration

```solidity
// AssetMarketFactory 0x22AA61c589B90731752236c07d1455D0065bfc79
// MarketRouter      0x7553919210B172438853C3694Fd88fAfD4bE3Eb4
// MarketLens        0x704E7a0e7864250303B05b25EabC2417CE99ceb6

uint256 n = factory.marketCount();                 // 18 at head
for (uint256 id = 1; id <= n; ++id) {
    if (router.marketLiquidity(id) == 0) continue; // drops ids 1-12
    AssetMarketFactory.Market memory m = factory.market(id);
    PoolKey memory key = factory.poolKeyOf(id);    // authoritative currency ordering
    // m.asset, m.brandToken, m.poolId, m.fee, m.tickSpacing, m.reservePool
}
```

`market(id)` reverts `UnknownMarket` for an id that was never created, so bound the loop with
`marketCount()` rather than probing.

`MarketLens.route(id)` collapses all of that into one `view` call and adds the two live rates you
cannot get from the registry:

| `Route` field | Content |
|---|---|
| `reservePool` | The market's reserve, with the `address(0)` default already resolved |
| `reserveAsset` | USDG on this chain |
| `brandToken`, `asset` | The two sides, unambiguously labeled |
| `poolKey` | The full `PoolKey`, hook included, to pass to `PoolManager.swap` verbatim |
| `protocolFeePips` | Live hook skim, hundredths of a bip. **5000 (0.50%) on all six pools** |
| `redemptionFeeBps` | The reserve's live redemption fee. 20 on the sUSDai reserve |

`route` is `view` and needs no `PoolManager` unlock, so it is safe to batch into a multicall
alongside your own reads. **So are the four quote functions.** Since the 2026-09-20 redeploy
`quoteBuy`, `quoteSell`, `quoteBuyExactOut` and `quoteSellExactOut` are `view` on the deployed
bytecode, so the whole lens can be `STATICCALL`ed: from another contract, from a
`staticcall`-based multicall, or from inside a `PoolManager.unlock` you have already opened.
The details are in [Quoting and settlement](./QUOTING_AND_SETTLEMENT.md), which owns that topic.

### Events worth indexing

| Event | Emitter | Why |
|---|---|---|
| `MarketCreated(uint256 indexed marketId, address indexed asset, address indexed creator, address brandToken, address treasury, address feeVault, address lpDistributor, bytes32 poolId, uint24 fee, bool verified, uint160 sqrtPriceX96)` | `AssetMarketFactory` | The authoritative "a new venue exists" signal |
| `MarketReserve(uint256 indexed marketId, address indexed reservePool)` | `AssetMarketFactory` | Emitted beside `MarketCreated`; names the reserve without changing that event's signature |
| `MarketRetired(uint256 indexed marketId, address indexed asset, address reservePool)` | `AssetMarketFactory` | Clears the uniqueness slot. The pool keeps trading so LPs can exit, so treat this as a delisting signal, not a hard stop |
| `BrandRegistered(address indexed token, address indexed treasury, address indexed admin, string name, string symbol)` | `SharedReservePool` | Informational only. See the warning below |

### WARNING: `registerBrand` is permissionless, so allowlist by MARKET

> Anyone with gas can call `SharedReservePool.registerBrand(name, symbol, admin)` and get a real
> `PooledBrandToken` with a real 1:1 claim on the reserve, arbitrary `name` and arbitrary `symbol`.
> This is intentional and safe at the protocol level: a brand with no minted supply cannot earn
> yield or affect anyone else's accounting. It is **not** safe as an indexing key.
>
> An attacker can register a brand with the symbol `AIUSD`, or `USDG`, or `USDC`, and it will emit a
> perfectly well-formed `BrandRegistered` event from our reserve. An indexer that builds its token
> list by consuming `BrandRegistered` and keying on symbol will list a token that has no pool, no
> market and no relationship to anything you want to route through. Worse, it is genuinely
> redeemable 1:1, so naive validity checks pass.
>
> **Derive the brand allowlist from the market set, not from brand events.** The trusted set of
> brand dollars is exactly the image of `market(id).brandToken` over live market ids, which is the
> loop in the previous subsection. Nothing else.
>
> One trap if you try to shortcut this: the factory's `marketOfBrand(brand)` mapping is **not** a
> membership test. It is only written for a market that owns its unit outright, so
> `marketOfBrand(AIUSD)` reads **0** even though AIUSD is the quote token of three live markets
> (verified at head). That is the shared-quote case from [section 1](#1-market-model), reported by
> `isSharedQuote(id)`. Use `marketOfBrand` to ask "does this market own its brand", never to ask "is
> this brand real".

## 7. Token reference

| Symbol | Address | Decimals | What it is |
|---|---|---|---|
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 | The chain's dollar and the reserve asset. **In no pool.** |
| AIUSD | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` | 6 | Brand dollar, shared quote token of markets 13, 14 and 15 |
| SDOGE.d | `0xA138D500c4f96B6Fa319719bA325e6DE62C567b4` | 6 | Brand dollar, market 16 only |
| ABR.d | `0x1Aa1526302625de02791538DB45c45E96bb75A70` | 6 | Brand dollar, market 17 only. `currency0` of that pool |
| CORGIGG.d | `0xe0588f17797e79B51a42CBE4bEbab0C1241F98a4` | 6 | Brand dollar, market 18 only |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18 | Asset, tokenized equity, market 13 |
| SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | 18 | Asset, tokenized equity, market 14 |
| AI | `0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18` | 18 | Asset, tokenized equity, market 15 |
| SDOGE | `0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C` | 18 | Asset, launchpad graduate, market 16 |
| ABR | `0x2165962eb8BF56354bF7053071E515dC9818DfbF` | 18 | Asset, launchpad graduate, market 17. `currency1` of that pool |
| CORGIGG | `0x17A5C7E9293199271f985eDAC74366015DA96FaD` | 18 | Asset, launchpad graduate, market 18 |

Every brand dollar on this venue is 6 decimals. Every asset is 18 decimals. There is no mixed case
to handle within a category.

### WARNING: AIUSD is a brand dollar. It is not USDG.

> | | Address | Role |
> |---|---|---|
> | **USDG** | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | The chain's dollar. Reserve asset. Appears in **no** pool |
> | **AIUSD** | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` | A 1:1 claim on the sUSDai reserve. Appears in three pools |
>
> Both are 6 decimals. Both are named like a dollar. They are different tokens with different
> contracts and different roles, and this has been confused before.
>
> - Quoting `USDG -> NVDA` as a single v4 swap will not find a pool, because there is no USDG/NVDA
>   pool and never will be. The route is `mint AIUSD, then swap`.
> - Treating AIUSD as a settlement dollar and handing it to a user who asked for USDG leaves them
>   holding a brand token that needs a separate `redeem` call, and a 20 bps fee they did not price.
> - AIUSD trades at par by construction, but only through the reserve. Its price inside a v4 pool is
>   whatever the pool says, and the arbitrage that keeps those equal is the reserve window, not a
>   market maker.

## 8. New markets appear without warning

The market set is **not static**, and it grows without a governance step you can watch for.

Two creation paths exist:

1. **Owner approval, then permissionless creation.** The Safe calls `approveAsset(asset, listing)`,
   which fixes the fee tier, starting price, brand name and symbol, and oracle depth. After that
   anyone may call `createMarket(asset, reserve)`. The parameters travel with the approval, not with
   the caller, so the caller chooses nothing but the timing.
2. **Launchpad graduation, with no owner step at all.** When a launch curve graduates, the launchpad
   module hands its swept reserves over to be seeded as liquidity, and the market must exist in the
   same transaction for that to be atomic. `createLaunchMarket` is callable only by the registered
   `launchpad` address, currently `0xF5f4Eb45347ec69CB56D1c682a0FdA83bb9f4efC` (read at head), and
   the listing terms travel with that call. The asset never enters the approved-asset list.

Path 2 is how markets 16, 17 and 18 came to exist, and it is how the next one will. There is no
announcement, no delay and no approval transaction to index ahead of it.

**Watch `AssetMarketFactory.MarketCreated`.** It is emitted on both paths, carries `marketId`,
`asset`, `brandToken`, `poolId` and `fee`, and is the only signal that fires before the pool has its
first trade. Pair it with `MarketReserve` from the same transaction to learn which reserve backs the
new brand, then run the new id through [section 6](#6-discovery) and
[section 5](#5-depth-stated-honestly) before routing anything through it: a freshly graduated pool
is seeded with whatever the curve swept, which can be smaller than any pool listed here.

`AssetMarketFactory` enforces one market per (reserve, asset) pair, so a new `MarketCreated` for an
asset you already index means either a different reserve or a replacement after a `MarketRetired`.
It never means a competing pool for the same pair in the same reserve.

Launch curves themselves (`LaunchCurve.buy` / `sell`) are a separate pre-graduation venue with
different semantics - partial fills, a time-dependent snipe tax, and a window around graduation
where neither venue is live. They are not covered by `MarketLens` and we do not recommend routing
through them. See the closing section of
[../AGGREGATOR_INTEGRATION.md](../AGGREGATOR_INTEGRATION.md).
