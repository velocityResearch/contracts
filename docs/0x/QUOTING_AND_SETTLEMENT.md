# Quoting and settlement

How to produce a number for a Stables market on Robinhood Chain (chainId 4663), and how to land
the transaction that pays it. Written for a 0x integrations engineer.

For what the hook does and why it is safe to route through, see
[Hook specification](./HOOK_SPECIFICATION.md). For who can change the parameters this document
reads, see [Security and governance](./SECURITY_AND_GOVERNANCE.md). For the pool inventory,
token decimals and discovery, see [Markets](./MARKETS.md). The venue-neutral version of this
material is [`docs/AGGREGATOR_INTEGRATION.md`](../AGGREGATOR_INTEGRATION.md); this file is the
0x-specific layer and does not restate it.

Addresses used below:

| Role | Address |
|---|---|
| Uniswap `PoolManager` (canonical, unmodified) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap `V4Quoter` (canonical, unmodified) | `0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F` |
| Uniswap `StateView` (canonical, unmodified) | `0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804` |
| `ProtocolFeeHook` | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` |
| `MarketLens` | `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| sUSDai reserve (backs all six live markets) | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` |
| USDG (reserve asset, 6 decimals) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

A USDG-denominated trade is always two legs, because there is no USDG in any pool. The pools
pair an 18-decimal asset against a 6-decimal brand dollar, and the brand dollar is a 1:1 claim
on a `SharedReservePool` holding USDG:

```
buy:   USDG --reserve mint, 1:1, free--> brand --v4 swap--> asset
sell:  asset --v4 swap--> brand --reserve redeem, 1:1 less redemptionFeeBps--> USDG
```

---

## 1. The three ways to quote, and when to use each

### (a) Stock `V4Quoter`, straight against the pool

Zero custom code. Build the `PoolKey` from `AssetMarketFactory.poolKeyOf(id)` (or
`MarketLens.route(id).poolKey`), pass empty `hookData`, and call the canonical `V4Quoter`
already deployed at `0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F`. The number that comes back
is the number the swap settles, protocol fee included. See §3 for why.

This covers the v4 leg only. The reserve leg has to be composed on top, and it is trivial
arithmetic (§2).

### (b) `MarketLens`

One call per direction that composes the reserve leg and the pool leg and enforces both
reserve capacities. Reference in §4. Use it when you want the whole USDG-to-asset route
priced by one call, or when you want the reserve's mint and redeem headroom checked for
you rather than reading `maxMint` and `redeemableAssets` and doing the comparison yourself.

**Every function on it is `view`, the four quote functions included.** `quoteBuy`,
`quoteSell`, `quoteBuyExactOut` and `quoteSellExactOut` can be `STATICCALL`ed: from a `view`
function, from a staticcall-based multicall, from a batched sampler, or from inside a
`PoolManager.unlock` you have already opened. It does not call Uniswap's `V4Quoter` — that
contract runs a real swap inside `unlock`, which is state-mutating and is why a quoter built
on it cannot be sampled. This one replays `Pool.swap` in memory from state read through
`extsload`, using v4-core's own `SwapMath`, `TickMath` and `LiquidityMath`, and applies the
hook's skim itself.

> **If you are working from a copy of this document dated before 2026-09-20:** the lens then
> deployed at `0x0a3d8332D949b4aE650f3aC6468620e403a50fF1` was `nonpayable` and could only be
> reached by a top-level `eth_call`. That address is still live and still returns the same
> numbers; it is simply not samplable. Use the address in the table above.

`MarketLens` is ownerless and stateless. It is not a proxy, so it cannot be upgraded under
you; a change means a new address.

### (c) Closed-form off-chain math

Full formulas in §2. All six live pools are single full-range constant-product positions, so
the whole curve is two numbers (`L`, `sqrtPriceX96`) plus two fee rates. A router that models
venues itself can price any size from one `StateView` read per pool per block and never make a
quoting `eth_call` at all.

### Recommendation for 0x

**Model the v4 leg off-chain (c) for the routing loop, and treat the reserve leg as a separate
`BASIC` action. Sample `MarketLens` (b) on the path that has to be exact.**

Before 2026-09-20 the second half of that sentence was not available: the lens could not be
`STATICCALL`ed, so the only way to reach it was a top-level `eth_call`, and a sampler that
already batches its venue reads into one call could not include this venue at all. That
constraint is gone. The lens is now `view`, so it drops into whatever batching you already do,
including a sampler contract running inside an `unlock`. The recommendation below is therefore
about cost and about split routing, not about reachability.

- 0x already models Uniswap v4 as a liquidity source on this chain, and the only thing that
  makes these pools different from a plain v4 pool is a fee rate that is one `feePipsFor(poolId)`
  read. There is no new curve to implement. The six pools are single full-range positions, so
  the sampler never has to walk a tick bitmap.
- Split routing needs a model it can differentiate and evaluate at many sizes per block. That
  is an argument for closed form regardless of how cheap a quote is: an on-chain sample gives
  you one point on the curve, and the router wants the curve.
- The pools hold seed liquidity today (see [Markets](./MARKETS.md) for measured price impact).
  At the sizes 0x routes, the marginal value of a pool-accurate on-chain quote per candidate
  size is low, even now that the sample is batchable and costs one `STATICCALL` rather than a
  round trip of its own.
- The deep leg is the reserve, not the pools: about 9.96M USDG of mint headroom and about
  35,276 USDG redeemable at 1:1 less 20 bps, read at block 68,293,146. That leg is exact
  integer arithmetic with no curve at all, so modeling it costs nothing and unlocks the only
  size that is actually large here.

Where the lens now earns its place: as the pre-trade confirmation on the size you actually
chose, batched with your other reads or called from inside your own settlement path, and as
the reference implementation you diff your sampler against. It also enforces both reserve
capacities for you, which a closed-form model has to remember to do itself. Use `V4Quoter` (a)
as the ground truth in tests: if your off-chain model and the stock quoter disagree by more
than the rounding described in §2, your model is wrong. Note that `V4Quoter` is the one piece
here that is still `nonpayable` and still needs a top-level `eth_call`; the lens is not.

---

## 2. Closed-form math

### 2.1 The reserve leg

`SharedReservePool` on `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2`. Both the asset (USDG) and
every brand token are 6 decimals, so there is no scaling anywhere in this leg.

| Operation | Formula | Bound |
|---|---|---|
| `mint(brand, a, to)` | `brandOut = a` exactly | `a <= MarketLens.maxMint(reserve)`, else reverts `LiabilityCapExceeded`. Zero while the reserve is paused |
| `redeem(brand, a, to, min)` | `assetsOut = a - floor(a * redemptionFeeBps / 10000)` | `assetsOut <= MarketLens.redeemableAssets(reserve)` |
| `swap(brandIn, brandOut, a, to)` | `out = a` exactly, same reserve only | none; not paused-gated on the redeem side, but `swap` is `whenNotPaused` |

`redemptionFeeBps` is 20 on the sUSDai reserve. The floor is a true floor, taken on the amount
burned: `SharedReservePool.sol:547`, `uint256 fee = amount * redemptionFeeBps / BPS;` with
`BPS = 10_000`. `previewRedeem` is the same expression (`SharedReservePool.sol:864`).

Rounding direction: the fee rounds **down**, so the payout rounds **up**. The reserve is
therefore never short by rounding on this leg; the dust risk is entirely in the yield source,
which is why §7 exists.

### 2.2 The v4 leg: verifying the full-range constant-product claim

I did not assume this. Two independent checks:

**Source.** `MarketRouter.seedLiquidity` mints through the canonical v4 `PositionManager` over
`_fullRange(tickSpacing)`, which is `(TickMath.minUsableTick(s), TickMath.maxUsableTick(s))`
(`MarketRouter.sol:760`). So the router only ever creates full-range positions. That is not
sufficient on its own, because anyone can add a concentrated position through `PositionManager`
directly.

**Chain.** For each of the six live pools I read `getLiquidity(poolId)` and the tick liquidity
at both usable extremes (`tickSpacing` is 50, so `minUsableTick = -887250` and
`maxUsableTick = 887250`), at block 68,293,146:

```bash
cast call --rpc-url https://rpc.mainnet.chain.robinhood.com --block 68293146 0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804 "getLiquidity(bytes32)(uint128)" 0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61
cast call --rpc-url https://rpc.mainnet.chain.robinhood.com --block 68293146 0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804 "getTickLiquidity(bytes32,int24)(uint128,int128)" 0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61 -- -887250
```

| id | `getLiquidity` (active L) | gross at `-887250` | net at `-887250` | net at `887250` |
|---|---|---|---|---|
| 13 | 58365587137148 | 58365587137148 | +58365587137148 | -58365587137148 |
| 14 | 57659062169074 | 57659062169074 | +57659062169074 | -57659062169074 |
| 15 | 1691218231700442 | 1691218231700442 | +1691218231700442 | -1691218231700442 |
| 16 | 1309846509422923213 | 1309846509422923213 | +1309846509422923213 | -1309846509422923213 |
| 17 | 1284920390121674938 | 1284920390121674938 | +1284920390121674938 | -1284920390121674938 |
| 18 | 1284920390325882663 | 1284920390325882663 | +1284920390325882663 | -1284920390325882663 |

Active liquidity equals gross liquidity at the minimum usable tick, and the net at the maximum
usable tick is exactly its negation, on every pool. There is no other liquidity anywhere on the
curve: the nearest spaced tick below spot on market 13 (`-221250`, against a current tick of
`-221239`) reads gross 0, net 0. **Conclusion: every live pool is one full-range band. No tick
is ever crossed, so constant product with the real reserves holds exactly, at any size, up to
v4's own fixed-point rounding.**

Caveat to re-check, not to assume: this is a property of today's liquidity, not an invariant.
Nothing stops an LP from minting a concentrated position through `PositionManager` tomorrow. If
you model off-chain, read `getLiquidity` and compare it against the extreme-tick gross on some
cadence, and fall back to a tick-walking sampler or to `V4Quoter` if they ever diverge.

Virtual reserves, which are the real reserves under a single full-range position:

```
x0 = L * 2^96 / sqrtPriceX96        (raw units of currency0)
x1 = L * sqrtPriceX96 / 2^96        (raw units of currency1)
```

### 2.3 The v4 leg: exact integer math

This is v4-core's `SwapMath.computeSwapStep` specialized to the no-tick-crossing case, plus
the hook. Denominators: `lpFee = slot0.lpFee` over `1e6` — equal to `key.fee` on a static pool
(5000 on every live pool), and the keeper-set stored rate on a `0x800000` dynamic pool —
`hookPips = ProtocolFeeHook.feePipsFor(poolId)` over `1e6` (5000 on every live pool).
`Q96 = 2**96`.

**Exact input, currency1 in, currency0 out (`zeroForOne = false`):**

```python
aLessFee  = (amountIn * (10**6 - lpFee)) // 10**6          # floor
sqrtNext  = sqrtP + (aLessFee * Q96) // L                  # floor
grossOut  = ((L * Q96) * (sqrtNext - sqrtP) // sqrtNext) // sqrtP   # floor, floor
hookFee   = (grossOut * hookPips) // 10**6                 # floor
amountOut = grossOut - hookFee
```

**Exact input, currency0 in, currency1 out (`zeroForOne = true`):**

```python
aLessFee  = (amountIn * (10**6 - lpFee)) // 10**6          # floor
num1      = L * Q96
den       = num1 + aLessFee * sqrtP
sqrtNext  = -(-(num1 * sqrtP) // den)                      # ceil
grossOut  = (L * (sqrtP - sqrtNext)) // Q96                # floor
hookFee   = (grossOut * hookPips) // 10**6                 # floor
amountOut = grossOut - hookFee
```

**Exact output, currency1 in, currency0 out (`zeroForOne = false`)** - quoted here for
completeness; read §5 before you settle anything against it:

```python
num1     = L * Q96
sqrtNext = -(-(num1 * sqrtP) // (num1 - amountOut * sqrtP))        # ceil
curveIn  = -(-(L * (sqrtNext - sqrtP)) // Q96)                     # ceil
lpPart   = -(-(curveIn * lpFee) // (10**6 - lpFee))                # ceil
poolIn   = curveIn + lpPart
hookFee  = (poolIn * hookPips) // 10**6                            # floor
amountIn = poolIn + hookFee
```

Rounding summary, which is the part that is easy to get wrong:

| Step | Direction | Why |
|---|---|---|
| LP fee on exact input | floor the post-fee amount | `FullMath.mulDiv(amount, 1e6 - fee, 1e6)` |
| LP fee on exact output | ceil the fee added on top | `mulDivRoundingUp(amountIn, fee, 1e6 - fee)` |
| `sqrtNext` from amount1 added | floor the quotient | pushes price less far, favors the pool |
| `sqrtNext` from amount0 added | ceil | same direction |
| output amount delta | floor | pool keeps the dust |
| input amount delta (exact out) | ceil | pool keeps the dust |
| hook fee | floor | `FullMath.mulDiv(base, feePips, 1e6)`, `ProtocolFeeHook.sol:644` |

One consequence of that last row is worth building into a model rather than discovering in a
fuzz test: the hook fee is a plain floor with no minimum, so at 5000 pips any unspecified-leg
magnitude below 200 base units pays **zero** fee, and the hook returns early
(`ProtocolFeeHook.sol:645`). That is only reachable on dust, but a model that asserts
`fee > 0` will disagree with the chain there.

Every one of these formulas was checked to the wei against the deployed `V4Quoter` on market 13
at the live pool state (`L = 58365587137148`, `sqrtPriceX96 = 1244476806409958294375662`):

| Call | Model | `V4Quoter` |
|---|---|---|
| exact-in 100000000 (AIUSD in) | 361978989930279627 | 361978989930279627 |
| exact-in 10000000000000000 (NVDA in) | 2436123 | 2436123 |
| exact-in 1000000000000000000 (NVDA in) | 192671600 | 192671600 |
| exact-in 400000000000000000 (NVDA in) | 88253004 | 88253004 |
| exact-out 361978989930279627 (NVDA out) | 99943266 | 99943266 |

### 2.4 Composing the two legs

```
buy  (USDG -> asset):  assetOut = v4ExactIn(pool, brand, usdgIn)        # mint is 1:1, identity
sell (asset -> USDG):  brandOut = v4ExactIn(pool, asset, assetIn)
                       usdgOut  = brandOut - floor(brandOut * redemptionFeeBps / 10000)
```

The mint leg contributes no arithmetic at all, only a capacity check. That is worth stating
plainly because it is unusual: crossing from USDG into a brand dollar is free and exact, in
both integer directions, so the only price in a buy is the pool's.

---

## 3. A stock `V4Quoter` is exact. Do not subtract the fee yourself

### Why it is exact

`ProtocolFeeHook` has flags `0x00CC`: `beforeSwap`, `afterSwap`, and both return-delta
permissions. `beforeSwap` returns `BeforeSwapDeltaLibrary.ZERO_DELTA` unconditionally and
charges nothing (`ProtocolFeeHook.sol:592`); it exists only to write an oracle observation.

The entire fee is taken in `afterSwap`, which returns an `int128`
(`ProtocolFeeHook.sol:631, 649`). Core's `Hooks.afterSwap` folds that return value into
`hookDeltaUnspecified`, orders it into a `BalanceDelta` by the same
`amountSpecified < 0 == zeroForOne` predicate the hook itself uses, and computes
`swapDelta = swapDelta - hookDelta`. The result of that subtraction is what
`PoolManager.swap` returns to its caller.

`V4Quoter` is not a model. It opens `PoolManager.unlock`, performs the real `swap`, reads the
returned `BalanceDelta`, and reverts with it as the payload. So the quoter's answer is
literally the post-hook delta. There is no path by which a hook return-delta can be present in
settlement and absent from the quote: they are the same number, produced by the same call.

Measured confirmation, market 13, 100 USDG of AIUSD in, empty `hookData`, at block 68,293,146:

| Source | Result |
|---|---|
| `V4Quoter.quoteExactInputSingle` | 361978989930279627 |
| `MarketLens.quoteBuy(13, 100000000)` | 361978989930279627 |
| Closed-form model (§2.3) | 361978989930279627 |

This is one row of a wider measurement. The stock `V4Quoter` and the deployed `MarketLens`
agree to the wei on **all six** live pools at the same block, on a 100-unit exact-input quote;
that table is in
[SETTLER_COMPATIBILITY.md §6](./SETTLER_COMPATIBILITY.md#6-quote-to-execution-equivalence-measured)
and is not repeated here. Read that agreement precisely: the deployed lens prices its v4 leg by
delegating to the same canonical `V4Quoter` (§4.1), so those two columns are one implementation
of the curve, and what they jointly establish is that composing the reserve leg on top changes
nothing about the pool leg. The genuinely independent check on the curve itself is the
closed-form model in §2.3, which reproduces the same number from `L` and `sqrtPriceX96` alone
without calling either contract.

The same property is what makes the Settler v4 path correct without changes: it accumulates
`settledBuyAmount.asCredit` from the actual `BalanceDelta` and checks `minBuyAmount` against
`state.buy().amount()`. It never assumes a per-venue fee, so a hook delta on the unspecified
leg nets automatically.

### The bug to avoid

**Do not apply `feePipsFor(poolId)` to a `V4Quoter` result.** If you take the quoter's
`amountOut` and then subtract 0.50% "for the hook", you have counted the hook fee twice. You
will underquote by exactly `feePips`, which is 50 bps today:

```
correct:  361978989930279627
wrong:    361978989930279627 - floor(361978989930279627 * 5000 / 1e6)
        = 360169094980628229          (50 bps low)
```

Symptoms in production, in the order you will notice them:

1. You lose every auction against a router that quotes correctly, by a suspiciously round
   number that tracks `feePipsFor` exactly.
2. When you do win, the fill comes in 50 bps **above** your quoted `minBuyAmount`, consistently
   and in one direction. A real slippage model produces a two-sided distribution around the
   quote; a double-counted fee produces a one-sided offset with near-zero variance.
3. If you also use `MarketLens` anywhere, its numbers and your numbers differ by a clean
   `1 - feePips/1e6` factor.

The rule, stated once: **`feePipsFor` is an input to an off-chain curve model (§2.3) and to
nothing else.** Any number that came out of `V4Quoter`, out of `MarketLens`, or out of
`PoolManager.swap` already has it applied.

---

## 4. `MarketLens` reference

`0x704E7a0e7864250303B05b25EabC2417CE99ceb6`. Ownerless, stateless, not a proxy.

`maxMint`, `redeemableAssets` and `brandForRedeem` take a **reserve pool address**, not a
market id. Get it from `route(id).reservePool`. Everything else takes a market id.

| Function | Mutability on chain | Returns | Reverts with |
|---|---|---|---|
| `route(uint256 marketId)` | `view` | `Route{reservePool, reserveAsset, brandToken, asset, PoolKey, protocolFeePips, redemptionFeeBps}` | - |
| `reserveOf(uint256 marketId)` | `view` | `address` reserve for that market | - |
| `maxMint(address reserve)` | `view` | mint headroom in reserve-asset units; `0` while paused; `type(uint256).max` when uncapped | - |
| `redeemableAssets(address reserve)` | `view` | idle balance plus what the yield source will release, less one unit | - |
| `brandForRedeem(address reserve, uint256 assetsOut)` | `view` | least brand to burn for that payout | `RedeemCapacityExceeded(requested, available)` |
| `quoteBuy(uint256 marketId, uint256 reserveAssetIn)` | `view` | `(assetOut, gasEstimate)` | `ZeroAmount`, `MintCapacityExceeded(requested, available)`, `AmountTooLarge(amount)`, `NotEnoughLiquidity(poolId)` |
| `quoteSell(uint256 marketId, uint256 assetIn)` | `view` | `(reserveAssetOut, brandOut, gasEstimate)` | `ZeroAmount`, `RedeemCapacityExceeded`, `AmountTooLarge`, `NotEnoughLiquidity` |
| `quoteBuyExactOut(uint256 marketId, uint256 assetOut)` | `view` | `(reserveAssetIn, gasEstimate)` | `ZeroAmount`, `MintCapacityExceeded`, `QuoteUnavailable(amountOut)`, `AmountTooLarge`, `NotEnoughLiquidity` |
| `quoteSellExactOut(uint256 marketId, uint256 reserveAssetOut)` | `view` | `(assetIn, brandNeeded, gasEstimate)` | `ZeroAmount`, `RedeemCapacityExceeded`, `QuoteUnavailable`, `AmountTooLarge`, `NotEnoughLiquidity` |
| `poolManager()` | `view` | the singleton it reads: `0x8366a39CC670B4001A1121B8F6A443A643e40951` | - |
| `factory()` | `view` | `0x22AA61c589B90731752236c07d1455D0065bfc79` | - |

The mutability column is read from the deployed contract's verified ABI on Sourcify, not from
the repository. **All ten functions are `view`**, so the whole surface can be `STATICCALL`ed,
batched into a multicall, or sampled from inside an `unlock` you have already opened. The
lens does not call `V4Quoter`; it replays `Pool.swap` from `extsload` state using v4-core's
own `SwapMath`, `TickMath` and `LiquidityMath`, then applies the hook's skim. There is no
`quoter()` function — that call reverts.

`NotEnoughLiquidity(bytes32 poolId)` is the same name and the same selector `0x7a5ed734` that
`BaseV4Quoter` uses, and here it is raised directly rather than wrapped, so it decodes with
the handler you already have.

`gasEstimate` is a routing input and not a measurement: a `view` quote has no swap to measure,
so the lens returns a declared model of settlement cost — `130,000 + 25,000` per initialised
tick the fill crosses. For comparison, `V4Quoter` measured 139,414 on market 13 at 100 USDG.

### A quote is a size that settles, or it is a revert

Neither leg of the lens ever returns a silent haircut. This is deliberate and it is the
property you should rely on when sizing:

- Over the reserve's mint cap, `quoteBuy` reverts `MintCapacityExceeded(requested, available)`
  rather than quoting the capped size.
- Over what the reserve can pay this block, `quoteSell` reverts
  `RedeemCapacityExceeded(requested, available)` rather than quoting the reduced payout.
- A pool that cannot fill reverts `NotEnoughLiquidity(poolId)` rather than being turned into
  a smaller number.

The reason a capped sell figure would be actively dangerous, rather than merely unhelpful, is
that the brand leg is burned whole either way. `SharedReservePool._redeem` burns first
(`SharedReservePool.sol:543`) and pays `min(owed, what it can raise)` afterwards
(`SharedReservePool.sol:554`). A caller who set a capped quote as their minimum would have
authorized burning brand worth more than the payout. A revert makes that impossible.

Both errors carry `available` as their second argument, so a failed quote is also a sizing
answer: catch the revert, decode it, and re-quote at `available` or split the order. Size a
partial sell from `redeemableAssets` and `quoteSellExactOut`.

### 4.1 Source and deployed bytecode agree

They did not until 2026-09-20. The lens then deployed at
`0x0a3d8332D949b4aE650f3aC6468620e403a50fF1` wrapped Uniswap's `V4Quoter` and so was
`nonpayable`; the read-only simulator existed only in the repository. It is now deployed at
the address above, and `src/markets/MarketLens.sol` plus `src/markets/V4SwapSimulator.sol`
build to exactly that runtime bytecode. Both are verified `exact_match` on Sourcify.

The old address is still live, still ownerless, and still returns identical amounts — it just
cannot be `STATICCALL`ed. Nothing points at it any more. `MarketLens` is not upgradeable, so
every revision is a new address; pin the one in the table at the top of this document, or read
`core.marketLens` from `deployments/asset-markets-mainnet-v6.json`.

How to check what you are talking to, in three calls:

```bash
cast call --rpc-url https://rpc.mainnet.chain.robinhood.com 0x704E7a0e7864250303B05b25EabC2417CE99ceb6 "poolManager()(address)"
# 0x8366a39CC670B4001A1121B8F6A443A643e40951   (reverts on the old lens)
cast call --rpc-url https://rpc.mainnet.chain.robinhood.com 0x704E7a0e7864250303B05b25EabC2417CE99ceb6 "quoter()(address)"
# execution reverted                            (answers on the old lens)
curl -s "https://sourcify.dev/server/v2/contract/4663/0x704E7a0e7864250303B05b25EabC2417CE99ceb6?fields=abi" | jq -r '.abi[] | select(.type=="function") | "\(.name) \(.stateMutability)"'
# every function, quoteBuy included, reads view
```

The equivalence is not asserted, it is measured. `test/markets/MarketLensSimulatorFork.t.sol`
quotes 24 buy and 24 sell sizes across all six live markets against the canonical `V4Quoter`
at the same block and requires equality to the base unit, and it proves reachability the way
the EVM does: a contract-level `STATICCALL` of `quoteBuy(13, 1e6)` returns success against
this lens and reverts against the old one.

---

## 5. Exact-output

### The subtlety

The hook always charges the **unspecified** leg. Which leg that is depends on the swap mode,
and v4 defines it, not us:

| Mode | `amountSpecified` | Unspecified leg | Effect |
|---|---|---|---|
| Exact input | negative | the output | you receive `amountOut - fee` |
| Exact output | positive | the input | you pay `amountIn + fee` |

So a v4 **exact-output** quote prices a fee on the input that an **exact-input** settlement
never charges, and omits the fee on the output that an exact-input settlement does charge.
Settle a v4 exact-output number as exact-input and you land short.

### How short, measured

The prior venue-neutral document states this shortfall as "the square of the fee (about 25
pips at 0.50%)". **That figure is the deep-pool limit and it materially understates the error
in these pools.** `f^2` assumes the marginal output per unit of extra input equals the average
output per unit of input, which is only true when price impact is negligible. Market 13 moves
10.73% on 100 USDG, so the extra input buys output at the margin, well below the average.

Measured on market 13 at the live state, by quoting exact-in for size `s`, taking that output
as the exact-out target, quoting exact-out for it, then settling that input exact-in:

| Nominal size | Exact-in output (target) | v4 exact-out quote | Settled exact-in with that quote | Shortfall |
|---|---|---|---|---|
| 1 USDG | 4008303711377360 | 999969 | 4008178964939144 | 31.1 pips |
| 10 USDG | 39695713454708127 | 9999208 | 39692599517856651 | 78.4 pips |
| 100 USDG | 361978989930279627 | 99943266 | 361793718823513639 | 511.8 pips |
| 1,000 USDG | 1924236222954610153 | 994577810 | 1919218725207445579 | 2607.5 pips |

The shortfall converges downward toward 25 pips as size goes to zero, and grows roughly with
price impact above that. At routable sizes on these pools it is a 50 bps to 250 bps error, not
a 25-pip one. Treating it as 25 pips and padding your bound by that much will still miss.

### What the lens does instead

`MarketLens.quoteBuyExactOut` and `quoteSellExactOut` are **not** v4 exact-output quotes. They
invert the exact-input path:

1. Gross up the target by the hook's output-side fee: `grossOut = _grossFor(amountOut, 1e6, feePips)`,
   the least gross whose floored post-fee remainder still reaches the target.
2. Take a v4 exact-output quote for `grossOut`, which returns pool input **plus** the
   exact-output-mode hook fee on the input.
3. Strip that added fee back off with `_netFor`, recovering the pool's own input.
4. Run a real exact-input quote on that figure and check it clears the target. If it is one
   unit short, increment and retry once. Two rounds is the bound; a third failure reverts
   `QuoteUnavailable(amountOut)`.

Step 4 is the self-verification: the returned number is never reported without having been
confirmed against an exact-input quote in the same call. Round-trip check on market 13 at
block 68,293,146:

```
MarketLens.quoteBuyExactOut(13, 361978989930279627) -> 100000000
MarketLens.quoteBuy(13, 100000000)                  -> 361978989930279627
```

### Guidance

**Quote exact-out with the lens. Settle exact-in.**

If you must produce an exact-output number without an `eth_call`, implement steps 1 to 4 above
against your own §2.3 model rather than calling the exact-out formula directly. Do not ship a
raw v4 exact-output quote for these pools. And regardless of how the number was produced,
settle it as an exact-input swap with a `minBuyAmount`: exact-output settlement against a hook
that charges the input leg is a strictly worse shape for a router that holds the sell token.

---

## 6. Settlement

All three paths below are live. Nothing requires `hookData`: `ProtocolFeeHook` never reads it
and there is no `sender` check, so empty bytes is correct in every case.

### (a) Direct `PoolManager.unlock` -> `swap` -> `settle` / `take`

This is what 0x's `UNISWAPV4` action already does. Nothing here is special. The only two
things to get right are that `hookData` is empty and that you settle from the **returned
delta**, not from the amount you asked for, because a pool that runs out of liquidity mid-swap
fills partially and charges only what it consumed.

The reference implementation in this repository is `MarketRouter.unlockCallback`
(`src/markets/MarketRouter.sol:581`), with `_settleDelta` at `:739` and `_settle` at `:753`:

```solidity
// MarketRouter.sol:581 - the shape, verbatim in spirit
function unlockCallback(bytes calldata data) external returns (bytes memory) {
    if (msg.sender != address(poolManager)) revert OnlyPoolManager();

    (PoolKey memory key, bool zeroForOne, uint256 amountIn) =
        abi.decode(data, (PoolKey, bool, uint256));

    BalanceDelta delta = poolManager.swap(
        key,
        SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),          // negative == exact input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        }),
        ""                                                // hookData: empty
    );

    _settleDelta(key, delta);                             // settle what is owed, take what is owed to you
    return "";
}
```

Paying the pool is `sync` then ERC-20 `transfer` then `settle` (`MarketRouter.sol:753`); no
allowance is ever granted to the `PoolManager`. Ordering is unconstrained: the hook accrues
its fee as an ERC-6909 claim via `poolManager.mint` (`ProtocolFeeHook.sol:819`), never a
mid-swap `take`, so a prepay-style settlement works.

### (b) One-call `MarketRouter` entrypoints

`0x7553919210B172438853C3694Fd88fAfD4bE3Eb4`. Each does both legs, exact-input, with a
receiver and a deadline. Approve the router for the incoming token.

```solidity
// USDG in, asset out. Approve USDG to the router.
uint256 assetOut = IMarketRouter(0x7553919210B172438853C3694Fd88fAfD4bE3Eb4)
    .buyWithUsdg(13, 100_000_000, minAssetOut, receiver, deadline);

// Asset in, USDG out. Approve the asset to the router.
uint256 usdgOut = IMarketRouter(0x7553919210B172438853C3694Fd88fAfD4bE3Eb4)
    .sellForUsdg(13, assetIn, minUsdgOut, receiver, deadline);

// Asset in, brand out. Stops at the market's own dollar; you redeem separately.
uint256 brandOut = IMarketRouter(0x7553919210B172438853C3694Fd88fAfD4bE3Eb4)
    .sellForBrand(13, assetIn, minBrandOut, receiver, deadline);
```

Three properties that matter to a router:

- Every minimum is checked on the **receiver's measured balance** after the transfer, not on
  a return value (`MarketRouter.sol:642-648`). A token that taxes its own transfer is caught.
- A partial fill refunds the unspent side to `msg.sender` - as brand on a buy
  (`MarketRouter.sol:307`), as the asset on a sell (`:395`, `:459`).
- `sellForUsdg` passes `minUsdgOut` down into `SharedReservePool.redeem` as well as checking it
  on the balance afterwards (`MarketRouter.sol:453, 457`). See §7 for why both.

### (c) Raw reserve legs

```solidity
// Mint: 1:1, no fee. Requires a USDG allowance to the RESERVE, not to the router.
IERC20(USDG).approve(reserve, amount);
uint256 brandOut = ISharedReservePool(reserve).mint(brandToken, amount, receiver);  // == amount

// Redeem: burns msg.sender's brand. No approval. ALWAYS use the 4-argument overload (§7).
uint256 usdgOut = ISharedReservePool(reserve).redeem(brandToken, amount, receiver, minAssetsOut);

// Brand-to-brand inside one reserve: exactly 1:1, no fee, no approval.
uint256 out = ISharedReservePool(reserve).swap(brandIn, brandOut, amount, receiver);  // == amount
```

### Selectors and amount offsets for calldata patching

The offset is the 4-byte selector plus one 32-byte word per argument ahead of the amount.

| Selector | Function | Amount offset |
|---|---|---|
| `0x0d4d1513` | `SharedReservePool.mint(address,uint256,address)` | 36 |
| `0x5c833bfd` | `SharedReservePool.redeem(address,uint256,address)` | 36 |
| `0xf3f094a1` | `SharedReservePool.redeem(address,uint256,address,uint256)` | 36 |
| `0x6e81221c` | `SharedReservePool.swap(address,address,uint256,address)` | **68** |
| `0x6e973991` | `MarketRouter.buyWithUsdg(uint256,uint256,uint256,address,uint256)` | 36 |
| `0x4357400b` | `MarketRouter.sellForBrand(uint256,uint256,uint256,address,uint256)` | 36 |
| `0xb9077071` | `MarketRouter.sellForUsdg(uint256,uint256,uint256,address,uint256)` | 36 |

**`swap`'s amount offset is 68, not 36.** It is the only row that differs, because the amount
is its third argument rather than its second. Patching 36 there overwrites `tokenOut` with an
integer, which will be read as an address and fail the reserve's brand-registration check -
or, if the low 20 bytes happen to collide with a registered brand, succeed as the wrong trade.
If your generic-call action hardcodes offset 36, either special-case this selector or reorder
your route to avoid it: `SharedReservePool.swap` is only needed when crossing between two
brands of the same reserve, and a USDG-denominated route never touches it.

Note also that when the amount is patched from a runtime balance, `minAssetsOut` on the 4-arg
`redeem` has to be patched from the same quote (offset 100). A patched amount with a stale
minimum is not a bound.

---

## 7. The 4-argument `redeem` is mandatory

`SharedReservePool` exposes two overloads:

```solidity
function redeem(address token, uint256 amount, address receiver) external returns (uint256);
function redeem(address token, uint256 amount, address receiver, uint256 minAssetsOut) external returns (uint256);
```

**Always call the 4-argument overload and pass your own `minAssetsOut`.** Both alternatives are
wrong, in opposite directions.

### Why the 3-argument overload is too strict

It derives its own floor inline as `amount - amount * redemptionFeeBps / BPS`
(`SharedReservePool.sol:510`), which is exactly `previewRedeem`. That expression models the
redemption fee and **nothing else**. It does not model the rounding of the underlying yield
source.

A real deposit-then-withdraw round trip through a lending market is structurally a base unit or
two below book, because both legs round down on share-to-asset conversion. The reserve tolerates
that deliberately: `_cappedByIdle` truncates rather than reverting
(`SharedReservePool.sol:554`), because a hard revert on dust would brick redemptions entirely.

On a reserve whose `redemptionFeeBps` is **zero**, the derived floor is the full par amount, so
there is no fee margin to absorb the dust, and the check at `SharedReservePool.sol:555` fires:

```
payout    = amount - dust
minimum   = amount            (previewRedeem with a zero fee)
=> revert InsufficientPayout(payout, minimum)
```

The live USDG/Morpho reserve `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` has
`redemptionFeeBps = 0` and is exactly this case. No live market uses it today, but it is the
factory default, so the next market created without an explicit reserve lands on it. The sUSDai
reserve does not have this problem because its 20 bps fee is orders of magnitude larger than
the dust and absorbs it.

### Why passing zero is too lax

`_redeem` burns the brand first (`SharedReservePool.sol:543`), then pays
`min(owed, what it can raise)` (`:554`), then retires the difference against `lossCarryforward`
(`:558-559`) and transfers (`:560`). With `minAssetsOut = 0` a short reserve does not revert:
the brand is gone, the payout is short, and there is nothing left to retry with. The shortfall
is a realized loss, not a bad fill.

### Why a bound checked only on the receiver's balance afterwards is not equivalent

This is the part that is genuinely counterintuitive, because a revert in your own settlement
contract also unwinds the whole transaction. The difference is not reachability, it is
**tightness and denomination**:

- The reserve's own check runs at `SharedReservePool.sol:555`, **before**
  `asset.safeTransfer` at `:560` and after the burn at `:543`. It compares against the number
  you chose for this specific leg. Only a bound passed *into* the call is checked against the
  redemption's own economics.
- Your terminal check compares against a **route-wide** `minBuyAmount` that already carries
  your slippage tolerance, and on a multi-hop route may be denominated in a different token
  entirely. A reserve paying 30 bps short inside a 100 bps tolerance clears it. The trade
  settles, and the user has eaten a shortfall that was not price movement - it was an
  underbacked payout against brand burned at par. There is no revert, no distinguishing event,
  and no claim left to represent the difference.

`MarketRouter.sellForUsdg` does both: it hands `minUsdgOut` to the reserve
(`MarketRouter.sol:453`) *and* re-checks the receiver's measured balance afterwards (`:456-457`).
The second check exists to catch a reserve asset that taxes its own transfer, which the
reserve's internal guard cannot see. Neither check subsumes the other. Copy that shape.

Size `minAssetsOut` off `previewRedeem(amount)` with whatever tolerance your quote already
carries. On the sUSDai reserve, `previewRedeem` exactly is safe today; a small tolerance is
safer against a zero-fee reserve appearing later.

---

## 8. Worked example: 100 USDG into NVDA, market 13

All inputs read from chain at block 68,293,146. Measured result:
`MarketLens.quoteBuy(13, 100000000)` returns `361978989930279627`, which is
0.361978989930279627 NVDA. Reference spot is 249.4821 USDG per NVDA.

### Inputs

| Quantity | Value | Source |
|---|---|---|
| `poolId` | `0xf71c2e4f…f95e61` | `AssetMarketFactory.poolKeyOf(13)` |
| `currency0` | NVDA `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, 18 dp | same |
| `currency1` | AIUSD `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596`, 6 dp | same |
| `key.fee` (LP) | 5000 pips = 0.50% | same |
| `feePipsFor(poolId)` (hook) | 5000 pips = 0.50% | `ProtocolFeeHook` |
| `L` | 58365587137148 | `StateView.getLiquidity` |
| `sqrtPriceX96` | 1244476806409958294375662 | `StateView.getSlot0` |
| `redemptionFeeBps` | 20 | sUSDai reserve; not used on a buy |

Derived real reserves, from §2.2:

```
x0 = L * 2^96 / sqrtPriceX96 = 3.7157769426673464e18 raw  =  3.71577694 NVDA
x1 = L * sqrtPriceX96 / 2^96 =       916777786.83 raw     =  916.777787 AIUSD
```

### Step 1 - reserve mint, USDG to AIUSD

100 USDG is `100_000_000` at 6 decimals. `mint` is 1:1 with no fee, so the pool sees
`100_000_000` of AIUSD. Capacity check: `maxMint(0xCFa8…33B2)` was 9,964,932,271,009, which is
about 9.96M USDG, so 100 USDG is far inside the cap.

```
brandIn = 100_000_000
```

### Step 2 - LP fee, taken on the whole input

AIUSD is `currency1`, so this is `zeroForOne = false`.

```
aLessFee = floor(100_000_000 * (1_000_000 - 5_000) / 1_000_000)
         = floor(100_000_000 * 995_000 / 1_000_000)
         = 99_500_000
```

The LP fee is 500,000 raw AIUSD, that is 0.50 AIUSD.

### Step 3 - the curve

```
sqrtNext = sqrtP + floor(aLessFee * 2^96 / L)
         = 1244476806409958294375662 + floor(99_500_000 * 79228162514264337593543950336 / 58365587137148)
         = 1379542734071154946842805
```

Output, `getAmount0Delta` rounded down:

```
grossOut = floor( floor(L * 2^96 * (sqrtNext - sqrtP) / sqrtNext) / sqrtP )
         = 363797979829426760                        (0.363797979829426760 NVDA)
```

Sanity check against plain constant product with the reserves from §2.2:

```
x0 * aLessFee / (x1 + aLessFee)
  = 3.7157769426673464e18 * 99_500_000 / (916_777_786.83 + 99_500_000)
  = 3.63797979829e17
```

Same to the precision of the float, which is what confirms the constant-product reading.

### Step 4 - hook fee, taken off the output

Exact-input, so the unspecified leg is the output. The hook takes a floored share of what the
pool actually produced:

```
hookFee = floor(363797979829426760 * 5_000 / 1_000_000)
        = 1818989899147133                           (0.001818989899147133 NVDA)

netOut  = 363797979829426760 - 1818989899147133
        = 361978989930279627
```

### Result

| Step | Value |
|---|---|
| USDG in | 100.000000 |
| AIUSD minted (1:1) | 100.000000 |
| LP fee (0.50% of input) | 0.500000 AIUSD |
| To the curve | 99.500000 AIUSD |
| Pool output before hook | 0.363797979829426760 NVDA |
| Hook fee (0.50% of output) | 0.001818989899147133 NVDA |
| **Asset out** | **0.361978989930279627 NVDA** |
| Measured `MarketLens.quoteBuy(13, 100000000)` (deployed contract) | **361978989930279627** |
| Measured `V4Quoter.quoteExactInputSingle` (v4 leg alone) | **361978989930279627** |
| **Residual error** | **0 wei** |

The deployed lens and the stock quoter agreeing here is not specific to market 13; they agree
to the wei on all six pools at this block, per
[SETTLER_COMPATIBILITY.md §6](./SETTLER_COMPATIBILITY.md#6-quote-to-execution-equivalence-measured).

The closed-form math reproduces the measured quote exactly, to the wei, in both the exact-input
and exact-output directions and in both swap directions (§2.3 table). No approximation, no
tolerance.

### Reading the price impact

At the 1 USDG reference, `quoteBuy(13, 1000000)` returns `4008303711377360`, giving
1 / 0.004008303711377360 = 249.4821 USDG per NVDA, which is the spot figure quoted above. A
linear extrapolation of that to 100 USDG would be 0.400830371137736 NVDA. The actual fill is
0.361978989930279627, so the effective price is 1.10734x the reference, that is **+10.73% price
impact on 100 USDG**. This pool holds roughly 917 AIUSD and 3.72 NVDA. That is what a seed pool
does at 100 USDG of size, and it is why the reserve leg, not the pool leg, is the deep side of
this venue today. Size accordingly, and see [Markets](./MARKETS.md) for the measured impact
table and the max routable size derived from it.
