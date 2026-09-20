# AssetMarkets — second security audit, 2026-09-09 (multi-leg and buyback surface)

> Scope: the surface the [first audit](ASSET_MARKETS_AUDIT.md) explicitly says it never saw, plus
> everything that changed after it. `BuybackEngine`, `AssetLockbox`, the rewritten
> `MarketYieldSplitter` (liquidity-seconds weighting, several legs per brand), the two-step
> `registerBrand` / `openMarket` split in `AssetMarketFactory`, `MarketRouter`,
> `SharedReservePool` and `PoolBrandTreasury`, and `script/DeployAssetMarketsTestnet.s.sol`.
>
> Reviewed against the source at commit `1135dc7a`, which is what the live testnet stack
> (factory `0x5F81D1E2D24BE4bB31E675C3EB7951Ca95796782`) was built from.
>
> **Two HIGH, three MEDIUM and three LOW findings. None is fixed.** Every finding marked PoC has
> a passing exploit in `test/audit/Audit2026_09_09_Redeploy.t.sol`, written so that a fix turns
> it red:
>
> ```sh
> FOUNDRY_PROFILE=asset_markets_testnet UNISWAP_NODE_MODULES=/private/tmp/asset-markets-deps/node_modules forge test --offline --code-size-limit 40000 --match-contract Audit2026_09_09_Redeploy -vv
> ```

---

## 1. What was verified as sound

**The lockbox is what it claims.** `AssetLockbox` has one state-changing function, gated on an
immutable engine address, and no owner, withdrawal, upgrade or delegatecall. The engine deploys it
in its own constructor, so neither can be repointed at the other.

**The buyback schedule really is immutable.** `minNotional`, `minInterval`, `twapWindow` and
`maxDeviationBps` are stamped into engine immutables at attach time. `setBuybackParams` and
`setProtocolParams` on the factory move future markets only; no path reaches a live engine or a
live splitter.

**The TWAP guard is oriented correctly.** Buying the asset moves `sqrtPriceX96` down when the brand
is `token0` and up when it is `token1`, and `sqrtPriceLimitX96()` places a floor and a ceiling
respectively. The mean tick floors for negative cumulative deltas, matching Uniswap's own
`OracleLibrary.consult`, and both branches clamp to the tick bounds before the `uint160` cast.

**The splitter ledger balances.** Every harvest increments `totalOwed` by exactly
`protocolCut + assigned + remainder`, which sums to `claimed + carried`. Carried yield never enters
`totalOwed` twice, `push` is the only debit, and `unallocated()` cannot go negative.

**Fail-soft holds through the new path.** `harvest` calls no destination; `onYieldReceived` only
counts; everything that can revert lives in `execute`. A paused asset costs one buyback round.

**Reserve yield attribution is still correct across mint, redeem and swap.** `_settleBrand` runs
`_accrueGlobal` before any change to `outstanding`, so a brand that mints just before an accrual
earns nothing retroactively, and a new brand's `indexCheckpoint` starts at the current index.

**Router approval hygiene survives the rewrite.** Allowances to the swap router and the position
manager are zeroed after each use, every entry point is `nonReentrant`, and both periphery
contracts are identity-checked against the V3 factory in the constructor.

---

## 2. Findings

### HIGH-1 — the router never refunds input the pool could not absorb (PoC)

`MarketRouter._swapExactIn` passes `sqrtPriceLimitX96: 0` and `amountOutMinimum: 0`, checking the
caller's minimum only against what arrived. Uniswap fills as far as the seeded range reaches and
pulls only the input it actually spent, so the remainder stays in the router. Nothing gives it
back. `MarketRouter` has no rescue, no sweep, and no owner, and the leftover is invisible to every
later call because each one measures its own balance delta.

The PoC buys $100,000 into a market whose seeded range holds $1,000:

| | |
| --- | --- |
| USDG paid | 100,000.000000 |
| Asset received | 999.999999 |
| Brand stranded in the router, permanently | 98,966.446350 |

A caller who passes a real `minAssetOut` is protected — the transaction reverts instead. The loss
needs a weak or zero minimum, which the contract accepts and the ABI invites. `BuybackEngine`
already handles exactly this case correctly: it rolls its unspent brand forward to the next round.

**Fix.** After the swap, redeem or return the unspent input the same way `seedLiquidity._refund`
does, and consider rejecting a zero `minAssetOut` outright.

### HIGH-2 — leg weight measures pool liquidity, not brand float (PoC)

`MarketYieldSplitter` divides a brand's yield by liquidity-seconds read from each pool's
`secondsPerLiquidityCumulativeX128`. That measure is immune to the balance-parking attack it
replaced, which is the property it was chosen for. It is not, however, denominated in brand units.

For a position spanning the price, Uniswap's `L` is `sqrt(x·y)` in **raw** token units, so for a
pool holding `b` raw brand at raw price `P`:

```
L  =  b / sqrt(P)
```

`P` carries the decimal difference between the two tokens. Two pools of the same brand, each
holding exactly the same brand float, are therefore weighted differently purely by what they are
paired against. The PoC seeds $10,000 of one brand into each of two pools, one against an
18-decimal asset and one against a 6-decimal asset, both priced at $1:

| Leg | Brand float | Weight after one hour |
| --- | --- | --- |
| 18-decimal asset | $10,000 | 36,000,000,000,000,000,000 |
| 6-decimal asset | $10,000 | 36,000,000,000,000 |

A ratio of exactly 1,000,000 to 1. Price skews it too, by the square root: of the two markets on
the live testnet stack, the pool holding 2.5× the brand carries 1.58× the liquidity.

The consequence is that `openMarket` is not the narrow authority the contract documents it as. A
brand operator picks the asset, and picking a high-decimal or low-priced one hands the new leg most
of the brand's yield stream — which that leg's engine then spends buying that same asset, from a
pool the operator seeded. The doc comment on `openMarket` says the authority "cannot touch the fee,
the weighting, a lockbox, or any engine's schedule". It reaches the weighting.

No brand on the live stack has a second leg yet, so nothing is currently exposed.

**Fix.** Weigh by a brand-denominated quantity. The pool's brand balance is spoofable, which is why
it was dropped, but liquidity-seconds can be converted to brand units using the pool's own TWAP
over the same period — a quantity that is already read for the buyback guard and is just as
expensive to move.

### MEDIUM-1 — handing over the brand operator role moves almost nothing (PoC)

Two contracts hold an operator address and they are never reconciled:

- `AssetMarketFactory.brandOperatorOf` gates `openMarket`. It is written once, in `_registerBrand`,
  and has no setter anywhere in the codebase.
- `MarketYieldSplitter.brandOperator` gates `retireLeg` and `setBrandOperator`.

`setBrandOperator` is documented as "hand the right to attach further pools to someone else". It
does not do that. After the call the successor can retire legs but cannot open a market, and the
predecessor — who believes they have stepped down — keeps the power to pair the brand with new
assets forever. Combined with HIGH-2, that is a retained lever over the brand's yield.

**Fix.** Give the factory a `setBrandOperator` that moves `brandOperatorOf` and calls through to
the splitter, and make the splitter's own setter factory-only.

### MEDIUM-2 — splitting registration from listing turns a price squat into a permanent block

The first audit closed HIGH-1 by band-checking a pre-existing pool's price against
`assetPriceE18`, with `maxSqrtDeviationBps = 0` demanding an exact match. That fix assumed one
transaction: the brand token did not exist until the call that also created the pool, so the
squatter's window was a mempool.

With `registerBrand` and `openMarket` as separate calls the brand token address is public for as
long as the issuer waits. Anyone can create and initialise the V3 pool for that pair at a price of
their choosing, and every later `openMarket` with the safe default band reverts
`PoolPriceOutOfBand`. Four fee tiers is four cheap transactions. The issuer's remaining options are
to widen the band and adopt the attacker's price, or to fund and trade the pool back to fair before
listing. There is no direct theft, but a brand can be denied a listing against a chosen asset
indefinitely.

**Fix.** Let `openMarket` accept a caller-supplied `sqrtPriceX96` for an existing empty pool, or
allow the operator to re-price a pool that holds no liquidity.

### MEDIUM-3 — the live testnet's yield source reverts on any redemption that empties the reserve (PoC)

`SharedReservePool._recallIfNeeded` always requests `shortfall + 1` from the yield source, a buffer
for share↔asset rounding. Every production adapter caps the withdrawal at the caller's own
position: `MorphoBlueYieldSource` and `MorphoVaultYieldSource` both redeem all of the caller's
shares when `amount >= callerAssets`, and the test-suite `MockYieldSource` caps explicitly.

`AssetMarketTestYieldSource`, deployed by `script/DeployAssetMarketsTestnet.s.sol` and live on the
current testnet stack, does not:

```solidity
function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
    balances[asset][msg.sender] -= amount;   // reverts when amount = balance + 1
```

So any redeem or yield claim for the reserve's entire deployed balance reverts. This is not
theoretical on testnet: `MarketRouter.seedLiquidity` refunds an unused brand leg by redeeming it,
and on a fresh stack that refund is the whole reserve. The very first seed with a one-sided range
fails.

The production contracts are unaffected. The fixture is what is wrong, and it is wrong on a stack
that exists to validate the production contracts.

**Fix.** Cap the withdrawal at the recorded balance in `AssetMarketTestYieldSource`, then redeploy.

### LOW-1 — a leg under-credits itself after a period it could not be read

`_poke` credits `elapsed² · 2¹²⁸ / delta`, where `elapsed` is time since the last **global** poke
and `delta` spans time since that leg's last **successful** read. When a leg misses one or more
pokes the two diverge and the leg is credited by the ratio between them, not the full period. The
code comment claims the next successful poke "measures across the gap rather than losing the
period"; it recovers only part of it. `observe([0])` on an initialised canonical pool does not
fail, so this needs a non-pool address in a leg, which `_ensurePool` prevents.

### LOW-2 — `retireLeg` cannot be used from an EOA on a pool that still quotes

Retiring requires `weight == 0` and `owed[engine] == 0` after an internal poke. A pool with live
in-range liquidity earns weight on every poke where `elapsed > 0`, so the three steps — harvest,
push the engine, retire — must land in one block. That needs a helper contract. The stated purpose,
recovering a slot from "a market that never took off", still works, because a pool nobody quotes on
produces a delta large enough that the weight floors to zero.

### LOW-3 — three comments now describe contracts that no longer behave that way

- `CreateParams.operator` says the operator "carries **no on-chain authority at all**". Since the
  registration split it is written to `brandOperatorOf` and gates `openMarket`.
- `retireLeg` says "the leg's pool and engine must hold none of the brand". Neither balance is
  checked; only weight and unpaid credit are.
- `MarketYieldSplitterTest`'s contract docstring still describes weight as "balance × seconds
  credited at the previous poke's balance", two rewrites out of date.
- The regression test named `test_fix_theOperatorIsALabelNotAnAuthority` asserts only that the
  operator receives no payout. It does not check the authority its name claims, and that authority
  now exists — see MEDIUM-1.

---

## 3. Exposure of the live testnet stack

| Finding | Reachable on `0x5F81…6782` today |
| --- | --- |
| HIGH-1 | Yes, on any market with a bounded range and a weak minimum |
| HIGH-2 | Not yet — every brand has exactly one leg |
| MEDIUM-1 | Yes |
| MEDIUM-2 | Yes |
| MEDIUM-3 | Yes, and it blocks ordinary seeding |
| LOW-1/2/3 | Informational |

Nothing here puts mainnet funds at risk, because none of these contracts is deployed to mainnet.
MEDIUM-3 should be fixed before the testnet stack is used for acceptance, since it breaks a flow
the acceptance matrix depends on.

---

## 4. Remediation plan

**Status: every finding below is OPEN.** Nothing in this section has been implemented. The
proof-of-concept suite still passes, which is the check for whether that is still true — each test
is written to fail once its finding is fixed, so a green run means nothing has been done yet.

### Land these as one batch, not seven

Any change to a contract means new addresses, a reseed, and a frontend rewiring, which is what the
2026-09-09 redeploy already cost once. `MarketRouter`, `AssetMarketFactory` and
`MarketYieldSplitter` are each touched by at least one fix, so fixing them separately means three
redeploys and three rounds of `.env.local` and ABI churn. One pass, one redeploy, one rerun of the
suite in inverted form.

Note `AssetMarketFactory` is already 2,142 bytes over EIP-170. MEDIUM-1 adds to it. Robinhood
Chain accepts the oversize runtime, but the margin only gets worse, and a chain that enforces the
limit would reject it outright.

### Effort

| Finding | Shape of the change | Estimate |
| --- | --- | --- |
| MEDIUM-3 | Cap the withdrawal at the recorded balance | 10 minutes |
| LOW-3 | Comment corrections only | 15 minutes |
| LOW-1 | Per-leg read clock instead of the global one | 30 minutes |
| MEDIUM-1 | Factory-side operator setter, splitter setter made factory-only | 1 hour |
| HIGH-1 | Refund unspent input, per entry point | Half a day |
| MEDIUM-2 | New router entry point | Most of a day |
| HIGH-2 | New weighting math and its tests | One to two days |

### Approach, finding by finding

**MEDIUM-3.** One guard in `AssetMarketTestYieldSource.withdraw`, matching what every production
adapter already does: clamp `amount` to `balances[asset][msg.sender]` before subtracting. This is
the only fix here that changes no deployed interface, so it can ship on its own if the testnet
needs unblocking before the rest is ready.

**HIGH-1.** Have `_swapExactIn` return what it actually spent alongside what arrived, and refund
the difference at each of the three call sites, reusing the shape `seedLiquidity._refund` already
has. The refund differs per entry point and that is the reason this is not a two-line change:
`buyWithUsdg` must redeem the unspent brand back to USDG, `buyWithBrand` must return the brand the
caller arrived in, and `sellForUsdg` must return the asset. Ordering matters against MEDIUM-3,
because the USDG refund path redeems and can therefore drain the reserve.

**MEDIUM-1.** Add `AssetMarketFactory.setBrandOperator(brandToken, newOperator)`, gated on the
current `brandOperatorOf`, writing that mapping and calling through to the splitter. Then gate
`MarketYieldSplitter.setBrandOperator` on the factory so the two records cannot diverge again.

**MEDIUM-2.** Needs a decision before any code is written. A squatted pool holds no liquidity, so
its price can be moved by a trivial swap. The clean fix is a router entry point that reprices an
empty pool to the operator's target and seeds it in one transaction. That is new user-facing
surface, which is why it costs more than its size suggests. The cheap alternative is to document
that an operator facing a squat should pass `assetPriceE18 = 0`, adopt the price, and arbitrage it
back, which is worse for the operator and leaves the griefing intact.

**HIGH-2.** Weigh each leg by its liquidity multiplied by the square root of its own time-weighted
price over the same window. `observe` already returns both accumulators in one call, so the extra
read costs nothing; the work is the fixed-point math, the two token-ordering cases, and an overflow
argument for each. This changes the `Leg` struct again, so the frontend client in
`web-stable/src/web3/asset-markets.ts` moves with it.

There is a cheaper option if the testnet needs to be usable sooner. Capture each leg's price
scaling factor once at attach time and divide by it thereafter. That removes the millionfold
decimals skew, which is the exploitable part, and leaves a slow drift as price moves. Roughly two
hours rather than two days. It is a mitigation, not a fix, and the finding should stay open if it
is the one taken.
