# Aggregator integration — quoting and settling Stables markets

For a router that holds the input token and needs two answers per venue: *given a sell token and
amount, how much of the paired token comes out*, and *how do I settle that on chain*. Written for
0x Settler; nothing here is specific to it. Chain: Robinhood Chain mainnet, `chainId 4663`.
Addresses are the gen-6 stack in `deployments/asset-markets-mainnet-v6.json`; that manifest is the
authority and this document repeats only what an integrator needs on one page.

## 1. The shape of a market

Every market is a Uniswap v4 pool between an **asset** (a tokenized equity, a launchpad graduate)
and a **brand token** — a 6-decimal dollar that is a 1:1 claim on a `SharedReservePool` holding
USDG. There is no USDG in any pool. A USDG-denominated trade is therefore always two legs:

```
buy:   USDG --mint 1:1--> brand --v4 swap--> asset
sell:  asset --v4 swap--> brand --redeem 1:1 less fee--> USDG
```

| Venue | Contract | Quote | Settle |
|---|---|---|---|
| v4 pool | canonical `PoolManager` `0x8366a39CC670B4001A1121B8F6A443A643e40951` | stock `V4Quoter` (see §5) | `unlock → swap → settle/take`; hook needs no `hookData` |
| Reserve mint | `SharedReservePool.mint(brand, amount, receiver)` | `amount`, if `amount <= MarketLens.maxMint(pool)` | `transferFrom` — approve USDG to the pool |
| Reserve redeem | `SharedReservePool.redeem(brand, amount, receiver, minAssetsOut)` | `previewRedeem(amount)`, valid while `<= MarketLens.redeemableAssets(pool)` | burns caller's brand, **no approval** |
| Reserve swap | `SharedReservePool.swap(brandIn, brandOut, amount, receiver)` | `amount`, same reserve only | burns caller's brand, no approval, no fee |
| PSM window (optional) | `BrandPsm.sellGem/buyGem` — one per brand, see §6 | `tin`/`tout` | Maker's `DssLitePsm` surface over the two rows above |

**One brand per launchpad graduate; the equity markets share one.** A brand is not one token per
chain. Each launchpad graduate mints its own — `SDOGE.d`, `ABR.d`, `CORGIGG.d` — while the
tokenized equities (ids 13–15) all quote against the same `AIUSD`. Markets 13–15 are therefore
fungible on their dollar side; 16, 17 and 18 are not.

Six live markets, every one with `fee` 5000 (0.50%), `tickSpacing` 50 and `hooks`
`0xc9932584c5154e4F58313a2e5423522E74e540Cc`:

| id | Asset | Asset address | Brand | Brand address |
|---|---|---|---|---|
| 13 | NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | AIUSD | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` |
| 14 | SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | AIUSD | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` |
| 15 | AI | `0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18` | AIUSD | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` |
| 16 | SDOGE | `0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C` | SDOGE.d | `0xA138D500c4f96B6Fa319719bA325e6DE62C567b4` |
| 17 | ABR | `0x2165962eb8BF56354bF7053071E515dC9818DfbF` | ABR.d | `0x1Aa1526302625de02791538DB45c45E96bb75A70` |
| 18 | CORGIGG | `0x17A5C7E9293199271f985eDAC74366015DA96FaD` | CORGIGG.d | `0xe0588f17797e79B51a42CBE4bEbab0C1241F98a4` |

Every asset is 18-decimal, every brand 6-decimal. `PoolKey` sorts `currency0`/`currency1` by
address, so the brand is **not** reliably one side of the pool — read `poolKeyOf(id)` and take the
ordering from it, never assume it.

Two reserves are live. Both hold USDG; a brand belongs to exactly one of them and cannot cross.

| Reserve | Address | Redemption fee | Liability cap |
|---|---|---|---|
| sUSDai-backed (every live market today) | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` | 20 bps | 10,000,000 USDG |
| USDG / Morpho (default) | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` | 0 | none |

The sUSDai reserve's redemption fee has a hard ceiling in the implementation:
`SharedReservePool.MAX_REDEMPTION_FEE_BPS` is 100, so the owner can move the 20 bps up to 1% and
no further. The cap is `liabilityCap()` = 10000000000000 at 6 decimals.

**A redemption fee INCREASE is announced an hour before it can take effect.** `setRedemptionFee`
with a higher value writes `pendingRedemptionFeeBps` and `redemptionFeeEffectiveAt =
block.timestamp + FEE_INCREASE_DELAY` (one hour, a constant) and changes nothing live; a
separate, permissionless `commitRedemptionFee()` applies it at or after that time. So
`previewRedeem`, both `redeem` overloads, `MarketLens.route(id).redemptionFeeBps` and
`BrandPsm.tout` are all good for at least an hour from the moment you read them, and a fill
cannot be repriced under a quote you have already given.

Read `redemptionFeeEffectiveAt()` to see a change coming — **zero means nothing is pending**.
A DECREASE is not delayed: it applies in one transaction and cancels any announced increase,
which can only ever move a quote in the redeemer's favour.

### Use the 4-argument `redeem`, not the 3-argument one

`SharedReservePool` exposes two overloads:

```solidity
redeem(address brandToken, uint256 amount, address receiver);                        // strict
redeem(address brandToken, uint256 amount, address receiver, uint256 minAssetsOut);  // explicit
```

The 3-argument form no longer accepts a haircut. It derives its own floor as
`previewRedeem(amount)` and reverts `InsufficientPayout(actual, required)` if the reserve cannot
pay it in full. That is the right default for a naive caller, but it has a sharp edge you
should know about before you wire it up.

`previewRedeem` accounts for the redemption fee and nothing else. It does not model the
rounding of the underlying yield source. A real Morpho deposit-then-withdraw round trip is
structurally a base unit or two below book, because both legs round down. On a reserve whose
redemption fee is **zero** the derived floor is therefore the full par amount, and the redeem
reverts on dust that nobody did anything wrong to cause. The live USDG/Morpho reserve
`0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` is exactly this case: its fee is 0. The sUSDai
reserve is not, because its 20 bps fee is far larger than the dust and absorbs it.

**So: always call the 4-argument overload and pass your own `minAssetsOut`.** Every in-protocol
caller already does — `LaunchRouter`, `MarketRouter` and `BrandPsm` all pass explicit minimums.
Size yours off `previewRedeem` with whatever tolerance your quote already carries. The strict
overload is a safety net for humans, not an integration surface.

## 2. The hook

One hook, `ProtocolFeeHook` `0xc9932584c5154e4F58313a2e5423522E74e540Cc`, on every market pool.
Flags `0x00CC`: `beforeSwap`, `afterSwap`, both return-deltas. Nothing on liquidity, initialize or
donate.

- **What it does to amounts.** The ENTIRE fee is taken in `afterSwap`, on the **unspecified**
  leg of the swap, measured from the delta the pool actually produced. `beforeSwap` returns
  `ZERO_DELTA` unconditionally and never charges anything; it exists only to write the oracle
  observation. Which leg is "unspecified" follows core's own rule,
  `amountSpecified < 0 == zeroForOne`:

  | Swap | Unspecified leg | Fee currency |
  |---|---|---|
  | Exact-input (`amountSpecified < 0`) | the OUTPUT | you receive `amountOut − fee` |
  | Exact-output (`amountSpecified > 0`) | the INPUT | you pay `amountIn + fee` |

  **So on an exact-input swap the fee comes out of the token you receive, not the token you
  send.** That is the opposite of the usual "skim the input" hook and it is deliberate:
  `beforeSwap` can only see the amount the caller *asked* for, which a swap with a binding
  `sqrtPriceLimitX96` need not fill, so charging there would bill a trader for volume the
  pool never moved. Charging in `afterSwap` means **a partial fill is charged on the fill**
  and nothing else.

  Either way it is a hook delta folded into the swap result, so **the `BalanceDelta` that
  `PoolManager.swap` returns already includes it** and a stock `V4Quoter` is exact — you do
  not add or subtract the fee yourself. Live rate: 5,000 pips (0.50%) on a 0.50% LP tier
  ≈ 1% all-in.
- **A rate INCREASE is announced an hour ahead, exactly like the reserve fee.**
  `setPoolFeePips` with a higher value writes `pendingFeePipsOf(poolId)` and
  `feePipsEffectiveAt(poolId) = block.timestamp + FEE_INCREASE_DELAY` (one hour, a constant)
  and changes nothing live; a separate, permissionless `commitPoolFeePips(poolId)` applies it
  at or after that time. `feePipsFor(poolId)` — and therefore every quote a stock quoter
  produces — is good for at least an hour from the moment you read it. Zero in
  `feePipsEffectiveAt` means nothing is pending. A DECREASE applies immediately and cancels
  any announced increase. The ceiling is re-checked at commit, not only at announcement, so a
  value authorised under an older `MAX_FEE_PIPS` cannot land under a newer one.
- **What it does not do.** No `sender` check, no `hookData`, no exact-out block, no pause revert:
  when the protocol is halted `feePipsFor` returns 0 and trading continues. Fees accrue as
  ERC-6909 claims, never a mid-swap `take`, so settlement order is unconstrained.
- **What can change.** The rate is per pool and owner-settable up to
  `ProtocolFeeHook.MAX_FEE_PIPS`, a hard ceiling in the implementation rather than a policy.
  It is **10,000 pips (1%)**, twice the live rate, lowered from 50,000. Read `feePipsFor` per
  quote — never the raw `feePipsOf` mapping, which ignores both the registration check and the
  pause. You MAY cache it for up to `FEE_INCREASE_DELAY`, because an increase cannot land
  inside that window; a decrease can, so a cached value is only ever conservative. The hook is
  a UUPS proxy; an upgrade can change fee logic, never flags — the `PoolManager` derives a
  hook's permissions from the low bits of its ADDRESS on every single call, and a UUPS upgrade
  cannot move the proxy's address. Note the mechanism precisely: there is no re-validation on
  upgrade. `Hooks.validateHookPermissions` runs only inside `initialize`, which is
  initializer-guarded. A future implementation could therefore ship a `getHookPermissions()`
  that disagrees with its own address, and nothing would revert — but core would keep
  dispatching on the address bits, so the callback set a pool sees is still fixed.

  Live implementation as of 2026-09-20: `0xd4AC6b17338866E43E1922cfb563A81Ff36b425B`, which is
  the build that added the announced increase. Do not pin an implementation address in your
  integration; read the ERC-1967 slot if you need it.

## 3. Discovery

`AssetMarketFactory` `0x22AA61c589B90731752236c07d1455D0065bfc79`:

- `marketCount()` then `market(id)` → `{asset, brandToken, …, poolId, fee, tickSpacing, …,
  reservePool}`; `poolKeyOf(id)` → the exact `PoolKey` (`currency0/1` sorted, `hooks` set).
- **Filter, do not enumerate.** Ids 1–12 are dead — zero-liquidity leftovers from earlier
  deploys. Ids 13–18 are the live markets. `marketFor(address reserve, address asset) external
  view returns (uint256)` names the canonical market for a pair (pass `address(0)` for the
  factory's default reserve), and `MarketRouter.marketLiquidity(id) > 0` is the cheap test for
  the rest. `reservePool == address(0)` on a record means the factory's default reserve.
- `MarketLens.route(id)` returns everything above plus the live `protocolFeePips` and the
  reserve's `redemptionFeeBps` in one call — once the lens is deployed, see §5.
- Events: `MarketCreated(marketId, asset, creator, brandToken, …, poolId, fee, …)`;
  `SharedReservePool.BrandRegistered(token, …)`. `registerBrand` is permissionless, so allowlist
  brands by market rather than indexing every brand.

## 4. Settling from a router that holds the input

```mermaid
sequenceDiagram
    participant S as Settler
    participant R as SharedReservePool
    participant P as PoolManager
    Note over S,P: BUY: USDG → asset
    S->>R: mint(brand, amt, Settler)  — approve USDG first
    S->>P: swap brand→asset, recipient = user
    Note over S,P: SELL: asset → USDG
    S->>P: swap asset→brand, recipient = Settler
    S->>R: redeem(brand, amt, user, minOut)  — no approval; minOut unwinds a short payout
```

- **Generic-call actions.** Both reserve functions take the amount as their second word:
  calldata offset **36** (`4 + 32`) for `mint(address,uint256,address)` and for both
  `redeem` overloads. `mint` needs a USDG allowance to the pool; `redeem` burns from
  `msg.sender` and needs none.
- **Use the 4-arg `redeem`, and pass a real `minAssetsOut`.** This is the one place where the
  obvious choice loses money. `SharedReservePool._redeem` burns the whole amount and then pays
  `min(par − fee, what the reserve can raise)`, retiring the shortfall against
  `lossCarryforward` rather than reverting — so with the 3-arg overload a short reserve leaves
  you holding less USDG and no brand, with nothing to re-try. `minAssetsOut` makes the pool
  revert instead, which unwinds the burn with the transaction. If the amount is patched from a
  balance and cannot be known when the calldata is built, patch `minAssetsOut` from the same
  quote, or bound the whole route on your own terminal slippage check *and* accept that a
  short reserve is a realised loss rather than a bad fill.
- **One-call alternative.** `MarketRouter` `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` does the
  buy direction in one call, exact-input, with `receiver` and `deadline`:
  `buyWithUsdg(marketId, usdgIn, minAssetOut, receiver, deadline)`. Amount offset **36**. A
  partial fill refunds the unspent side to `msg.sender`, as brand on a buy.
- **There IS a one-call sell to USDG on chain, as of 2026-09-19.** `sellForUsdg`
  (`src/markets/MarketRouter.sol:425`, selector `0xb9077071`) is live behind the router proxy on
  implementation `0x95106c6424B81A8f45590Ff64B31DdB40897Dc2A`. It was missing until then: the
  aggregator-surface release had landed on the two yield adapters and silently not on the
  router, so this document advertised an entrypoint that did not exist. `UpgradeAggregatorSurfaceMainnet`
  now decides each leg by whether that leg's selector already answers, which is both the fix
  and the drift check.

  It hands `minUsdgOut` to the reserve as well as checking it on the receiver's measured
  balance, which is the difference between a bad fill and a loss: the reserve burns the brand
  leg whole before it pays, so a bound checked only afterwards cannot unwind anything.
- **Or sell in two calls, which is still supported and still has one advantage.**
  `sellForBrand(marketId, assetIn, minBrandOut, receiver, deadline)` (selector `0x4357400b`,
  amount offset **36**) stops at the market's own dollar, then the receiver redeems that dollar
  1:1 with the 4-arg `SharedReservePool.redeem` and its `minAssetsOut`, per the bullet above.
  Splitting it keeps the redemption minimum in the caller's hands and lets the two legs be
  priced at different moments. A partial fill refunds the unspent asset to `msg.sender`.
- **`redeem(address,uint256,address)` changed on 2026-09-19 and the change is in your favour.**
  The three-argument overload, selector `0x5c833bfd`, used to pass `minAssetsOut = 0`: it
  burned the brand leg and then paid whatever the reserve could raise, booking the difference
  as protocol loss. Because the burn came first there was nothing left to retry with, so a
  short reserve turned a redemption into a realised loss with no revert to catch. It now
  demands `previewRedeem(amount)` and REVERTS rather than under-paying.

  If you want a haircut, ask for one explicitly with the 4-argument overload and a lower
  bound. Nothing a caller could do before has been removed; what changed is what happens when
  you do not choose.
- **Direct `PoolManager` access** needs `IUnlockCallback`; `MarketRouter.unlockCallback`,
  `_settleDelta`, `_settle` are the reference (`src/markets/MarketRouter.sol`).

**Selectors, for patching an amount into prebuilt calldata.** The offset is the 4-byte selector
plus one word per argument ahead of the amount. It is **36** for every row below except
`swap`, where the amount is argument three, so patching 36 there overwrites `tokenOut`.

| Selector | Function | Amount offset | On chain |
|---|---|---|---|
| `0x0d4d1513` | `SharedReservePool.mint(address,uint256,address)` | 36 | yes |
| `0x5c833bfd` | `SharedReservePool.redeem(address,uint256,address)` | 36 | yes |
| `0xf3f094a1` | `SharedReservePool.redeem(address,uint256,address,uint256)` | 36 | yes |
| `0x6e81221c` | `SharedReservePool.swap(address,address,uint256,address)` | **68** | yes |
| `0x6e973991` | `MarketRouter.buyWithUsdg(uint256,uint256,uint256,address,uint256)` | 36 | yes |
| `0x4357400b` | `MarketRouter.sellForBrand(uint256,uint256,uint256,address,uint256)` | 36 | yes |
| `0xb9077071` | `MarketRouter.sellForUsdg(uint256,uint256,uint256,address,uint256)` | 36 | yes |

## 5. Quoting

| Contract | Address |
|---|---|
| `MarketLens` | `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` |
| `V4Quoter` (Uniswap's, unmodified) | `0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F` |
| `StateView` (Uniswap's, unmodified) | `0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804` |

The lens was redeployed 2026-09-20 from `0x0a3d8332D949b4aE650f3aC6468620e403a50fF1`, which is
still live and still returns identical numbers but is `nonpayable`. Both Uniswap contracts are
ownerless and stateless. Reading the lens required upgrading both yield adapters first —
`redeemableAssets` calls `withdrawable` on them, and the implementations deployed before
2026-09-19 did not have it.

`MarketLens` composes both legs and exposes both caps. **Every call on it is `view`**: it
replays the v4 swap from state read through `extsload` rather than calling `V4Quoter`, so an
aggregator can `STATICCALL` it — from a batched sampler, or from inside an `unlock` it already
holds. Amounts are identical to the stock quoter's to the base unit, which
`test/markets/MarketLensSimulatorFork.t.sol` checks across 24 buy and 24 sell sizes on all six
live markets.

`MarketLens` is a plain immutable contract, not a proxy and not upgradeable, so it cannot
change under you and a revision is always a new address. The table above is already the second
such revision. Resolve it at startup from `core.marketLens` in
`deployments/asset-markets-mainnet-v6.json` rather than compiling the constant in, and you
inherit the next one for free. `V4Quoter`, `StateView` and the `PoolManager` are Uniswap's
canonical deployments and do not move.

| Call | Returns | `view`? |
|---|---|---|
| `quoteBuy(id, usdgIn)` | `(assetOut, gas)`; reverts `MintCapacityExceeded(req, avail)` | yes |
| `quoteSell(id, assetIn)` | `(usdgOut, brandOut, gas)`; reverts `RedeemCapacityExceeded(req, avail)` | yes |
| `quoteBuyExactOut(id, assetOut)` | least `usdgIn` that clears it **through an exact-input fill**; can revert `MintCapacityExceeded` | yes |
| `quoteSellExactOut(id, usdgOut)` | least `assetIn` that clears it, plus the brand it burns; can revert `RedeemCapacityExceeded` | yes |
| `maxMint(pool)` | mint headroom; 0 while paused; `uint256.max` when uncapped | yes |
| `redeemableAssets(pool)` | idle USDG + what the yield source will release, less one unit | yes |
| `brandForRedeem(pool, usdg)` | least brand to burn for that payout; capacity-checked | yes |
| `route(id)` | reserve, asset, brand, `PoolKey`, live fee pips, redemption fee | yes |

**A quote is a size that settles, or it is a revert.** Neither leg returns a haircut: over the
reserve's mint cap is `MintCapacityExceeded`, over what it can pay out is
`RedeemCapacityExceeded`, and a pool that cannot fill is `NotEnoughLiquidity(bytes32 poolId)`,
selector `0x7a5ed734` — the same error `BaseV4Quoter` raises, and raised directly rather than
wrapped. Size a partial fill from `redeemableAssets` and `quoteSellExactOut`.

Arithmetic, for an off-chain model: `mint` and `swap` are `out = in`; `redeem` is
`in − ⌊in·fee/10000⌋`, valid up to `redeemableAssets`. The v4 leg is a full-range
constant-product pool: the LP fee `key.fee` applies to the WHOLE input, and the hook then
takes `⌊out·feePips/1e6⌋` off the output the pool produced. The redemption
fee is owner-mutable with next-block effect; `redeemableAssets` moves with every mint, redeem
and keeper action. `redeemableAssets` deliberately reports one unit below the arithmetic sum,
because the pool pads its recall from the yield source by one and a lending adapter reverts on
the over-request rather than clamping.

**Exact-out is defined for exact-input settlement.** The hook charges the unspecified leg in
both directions — the OUTPUT on exact-in, the realised INPUT on exact-out — so a v4
exact-output number settled exact-in lands short. The often-quoted "square of the fee"
(~25 pips at 0.50%) is only the zero-impact limit, and these pools are thin enough that it
badly understates the gap: the extra input buys output at the MARGIN, not at the average.
Measured on market 13 at live state, the shortfall is 31.1 pips at 1 USDG, 78.4 pips at
10 USDG, 511.8 pips at 100 USDG and 2,607.5 pips at 1,000 USDG. It converges on the fee
squared only as size goes to zero.

So do not model the gap with a constant. Quote exact-out with the lens, which inverts the
exact-input path and verifies the inversion against it inside the call, then settle exact-in.

## 6. The PSM window

`BrandPsm` is the same reserve leg wearing MakerDAO's `DssLitePsm` interface, for an aggregator
that already integrates a PSM and would rather configure one than write one. It is optional:
everything it does is reachable through `SharedReservePool` directly, and the native calls are
cheaper. One instance per brand, deployed and indexed by `BrandPsmFactory`
(`deploy(reserve, brand)`, `psmOf(reserve, brand)`, `predict(reserve, brand)`, event
`PsmDeployed`).

Live on the sUSDai reserve since 2026-09-19. `BrandPsmFactory`
`0xB1e0ED28e24d3999216979847f9473b5C7bf12bA`.

| Brand | Window |
|---|---|
| AIUSD | `0x1339b306Ce53d1393995D306BF7a365d4c825300` |
| SDOGE.d | `0x6f36300eA9486e7615f29EFA5C6eAC5Ee2bb5A4A` |
| ABR.d | `0x1539CE28BD6837EFaA9EadEB8aa76669Fcef3f35` |
| CORGIGG.d | `0x61bCD58B76cb703AAD74cAa64B85D094dcb0554f` |

The AIUSD window reads `tin` 0, `tout` 2004008016032065, `dec` 6, `to18ConversionFactor` 1,
`live` 1, and `daiForGem(10e6)` 10020040.

It holds nothing, has no owner and grants no authority: `sellGem` mints through the reserve and
`buyGem` pulls the caller's brand and redeems it, burning the facade's own transient balance.

| Call | Meaning here |
|---|---|
| `gem()` | USDG, the reserve asset |
| `dai()` | the brand token |
| `pocket()` | the reserve — read `gem.balanceOf(pocket())` for redeem-side depth |
| `gemJoin()` | itself; it is its own join, and the approval target |
| `tin()` | `0`; minting a brand is free. `HALTED` while the reserve is paused |
| `tout()` | the redemption fee as a WAD rate. **Never `HALTED`** — redeeming is not pausable |
| `sellGem(usr, gemAmt)` | USDG in, brand out, 1:1. Exact-input |
| `buyGem(usr, gemAmt)` | brand in, exactly `gemAmt` USDG out. **Exact-output** |

Three departures from Maker, each of which breaks a copy-pasted formula if missed:

- **`dai` is 6-decimal, not 18.** A brand mirrors the reserve asset so the peg is exact in
  integer units, so `to18ConversionFactor()` is `1` and any hardcoded `WAD / GEM_basis` ratio
  must go.
- **`tout` is the fee-on-top equivalent of a fee-inclusive charge.** `redeem` takes its fee out
  of the amount burned; a PSM adds it on top. `tout` is therefore `bps / (10000 − bps)` rounded
  up, not the raw fee — 2.004008…e15 at 20 bps. This is what makes both
  `gemOut = daiIn / (1 + tout)` and `gemOut = daiIn − daiIn·tout` land at or below what the
  reserve will actually pay, instead of asking `buyGem` for more gem than `daiIn` can buy.
- **`psm()` does not exist**, deliberately. An indexer that finds it treats this as a wrapper
  around an inner PSM and reads fees off the wrong address.

**For KyberSwap's `lite-psm` source, configure `IsMint: true`.** This PSM mints its dai on
demand rather than holding an inventory, so a dai-balance read would report zero capacity and
the venue would never quote. Note the consequence: that mode reports a fixed synthetic dai
reserve and therefore does **not** model `liabilityCap`. Read `MarketLens.maxMint` for the real
mint headroom.

## 7. Live state and known caveats (read 2026-09-19)

- **KyberSwap already quotes these pools, and at single-hop sizes it prices the hook to within
  0.16 bps.** Its aggregator API on `robinhood` returns routes through our pool ids under the
  exchange label `uniswap-v4-fee`. Measured on market 13 (brand `0xE7BB…E596` → NVDA), comparing
  its `amountOut` against the deployed stock `V4Quoter` on the same pool at the same block:

  | brand in | `V4Quoter`, this pool | KyberSwap, best route | |
  |---|---|---|---|
  | 1 | 3967325306255644 | 3967387238519164 | +0.16 bps, single hop |
  | 10 | 39293721730518382 | 39294369711329680 | +0.16 bps, single hop |
  | 100 | 358629210876496073 | 358634604736215872 | +0.15 bps, single hop |
  | 1,000 | 1914612164479679063 | 2862841579808426828 | +49.5%, six hops |
  | 10,000 | 3381927569571174210 | 8302444383823316480 | +145%, eight hops |

  Two things follow. Its fee model for this hook is right — had the 0.50% skim been ignored the
  small-size rows would be ~50 bps high, not 0.16. And **the pool is genuinely thin**: 1,000
  brand through it alone gets 52% of the linear amount, which is why Kyber starts splitting and
  beats the single pool outright. An earlier reading of that split as a mispriced quote was
  wrong; it is real depth. What Kyber still infers rather than reads is the rate itself, which
  is what the hook plugin in `docs/KYBERSWAP_INTEGRATION.md` §3.3 fixes.
- **What KyberSwap does not have is the reserve leg.** `USDG → AIUSD` routes through a
  UniswapV3 pool and market 14 rather than through `SharedReservePool.mint`, so the free 1:1
  window is invisible to it and a brand trading above par quotes worse than it should. That is
  the gap §6 exists to close.
- **0x Settler is deployed for this chain** and already carries the right PoolManager constant,
  and its `UNISWAPV4` action encodes an arbitrary hook address and hook data. The AMM leg needs
  no new code there; the reserve leg is its `BASIC` action against the selectors in §4, or the
  PSM window in §6.
- 18 markets in the factory. Ids 1–12 are dead (`marketLiquidity` 0); ids 13–18 are live and all
  six sit on the sUSDai reserve. Mint headroom is not the binding constraint today — the
  `liabilityCap()` is 10,000,000 USDG against a reserve in the tens of thousands — so the redeem
  side is what to size against, and `MarketLens.redeemableAssets(reserve)` is the number to read.
  It moves with every mint, redeem and keeper action, and drops to the adapter's local buffer
  once the keeper starts moving float to Arbitrum. **Do not use the figures below as inputs**;
  they are a dated snapshot, and `deployments/mainnet-state.json` carries the same reads at a
  stated block, regenerated by `node script/sync-mainnet-state.mjs`.

  At block 68196940 (2026-09-20T19:40:51Z) the sUSDai reserve's `totalPooledSupply()` was
  35735288258 and `redeemableAssets` 36004451363, both 6-decimal.
- **Governance: a 2-of-3 Safe, and one hot key that can only stop things.** Changed 2026-09-20;
  an earlier revision of this document described the single deployer EOA it replaced.

  | Role | Address | What it can do |
  |---|---|---|
  | Owner of every proxy and all four beacons | Safe v1.4.1 `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, threshold 2 of 3 | everything: implementations, fees, caps |
  | `ProtocolGuard.guardian` | `0xc1d844d6478e450E62293882d2d6739c4a8693F9`, a single hot key | `pause` only — it cannot unpause, upgrade, or move a token |
  | Retired deployer `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` | — | nothing. It is not an authority on any live contract |

  There is **no timelock**, so an upgrade is one signed Safe batch rather than one EOA
  transaction. Read owners off chain rather than off this table:
  `deployments/mainnet-state.json` records `owner()` and `pendingOwner()` for all sixteen
  handles, and `deployments/safe-batches/README.md` records how they were moved.

  **What a pause does to you.** `feePipsFor` returns 0 and the v4 pools keep trading; the
  reserve's `mint` reverts and `BrandPsm.tin` reads `HALTED`; `redeem` is deliberately never
  pausable, so the sell leg survives a halt and only the buy leg's 1:1 window closes.

  **Neither of the two rates that can invalidate a quote you are holding moves without
  warning.** A protocol fee INCREASE on a pool and a reserve redemption fee INCREASE are each
  announced an hour ahead and applied by a separate permissionless commit, so each takes two
  transactions an hour apart and you can see it coming before it lands:

  | Rate | Announced in | Commit | Live value |
  |---|---|---|---|
  | Pool trading fee | `ProtocolFeeHook.pendingFeePipsOf(poolId)` / `feePipsEffectiveAt(poolId)` | `commitPoolFeePips(poolId)` | `feePipsFor(poolId)` |
  | Reserve redemption fee | `SharedReservePool.pendingRedemptionFeeBps()` / `redemptionFeeEffectiveAt()` | `commitRedemptionFee()` | `redemptionFeeBps()` |

  A zero `...EffectiveAt` means nothing is pending. Decreases still land in one transaction,
  and a decrease CANCELS any announced increase, so reaching a higher rate after a cut means
  announcing again and serving a fresh hour.

  **Read this as a reliability guarantee, not a security one.** Because the proxies are
  upgradeable in one batch with no timelock, the owner could ship an implementation without
  the delay. It makes a published quote good for an hour against mistakes and against
  ordinary repricing; two of three signers can still bypass it, and you should size your
  exposure on the caps rather than on the delay. Those caps are hard: `MAX_FEE_PIPS` is 1%
  and `MAX_REDEMPTION_FEE_BPS` is 1%.
- **Source is verified on Sourcify**, not on Blockscout directly. All 21 contracts an
  integrator touches are verified as of 2026-09-20, including every implementation currently
  behind a proxy. Twenty are `exact_match`; `AssetMarketFactory`
  `0x45Ce2F93aD46d1393Eff5da56fFc4537740022C0` is a metadata-level `match`, so its source is
  authoritative and its metadata hash is not. Reproduce with
  `./script/verify-mainnet-sourcify.sh --status`, or query one address directly at
  `https://sourcify.dev/server/v2/contract/4663/<address>`. The older
  `check-all-by-addresses` endpoint has been withdrawn and now answers 404.

  The route matters: Blockscout's verification API on this chain sits behind a Cloudflare
  challenge that returns an HTML interstitial to `forge verify-contract`, so submitting there
  is not currently possible. Blockscout imports Sourcify matches, so source is still readable
  at `https://robinhoodchain.blockscout.com/address/<address>?tab=contract`.

  Compiler `v0.8.26+commit.8a97fa7a`, optimizer on at 200 runs, `via_ir = true` — so verify by
  standard-JSON input, never by flattened source, or the bytecode will not match. The
  *proxies* read as unverified while their implementations are verified; that is a UI
  artefact, not a gap. The gen-6 proxy addresses are in
  `deployments/asset-markets-mainnet-v6.json`.
- **Launchpad curves** (`LaunchCurve.buy/sell`) are a third venue and are not covered by the lens:
  buys can partial-fill and refund `msg.sender`, `quoteBuy` depends on `recipient` and
  `block.timestamp` (snipe tax), `sell` reverts once `readyToGraduate()`, and there is a window
  between phase-1 graduation and `graduateToMarket` where neither venue is live. Integrate the
  pools and the reserves first.
