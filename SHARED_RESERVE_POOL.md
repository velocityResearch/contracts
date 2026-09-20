# SharedReservePool — one reserve, many brands, permanent 1:1

> **Status: live on Robinhood Chain mainnet (chainId 4663), in two deployments.**
>
> | Reserve | Address | `redemptionFeeBps` | Role |
> |---|---|---|---|
> | sUSDai | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` | **20** | Backs all six live asset markets (ids 13-18). Yield source `SUSDaiYieldSource` |
> | USDG/Morpho | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` | **0** | The market factory's default. No live market draws on it. Yield source `MorphoBlueYieldSource` |
>
> Both are UUPS proxies owned by the 2-of-3 Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`,
> with **no timelock** — see [UPGRADING.md](UPGRADING.md). Balances, caps, fees and the
> implementation behind each proxy are read from chain into
> `deployments/mainnet-state.json`. Take them from there, never from this page.

`SharedReservePool` is the issuance layer the whole protocol sits on. A market's unit — its
"brand dollar" — is a `PooledBrandToken` registered here, and `MarketRouter`, `LaunchRouter`
and `BrandPsm` mint and redeem against this contract rather than holding inventory of their
own. The v4 pools are the thin leg; the reserve is the deep one.

A pooled brand token is a flat 1:1 claim on a shared pot, not a share in a vault:

| | |
|---|---|
| Brand token | Flat `PooledBrandToken`, decimals mirrored from the reserve asset (6 for USDG) |
| Redemption value | Always exactly 1.000000 of the asset, less `redemptionFeeBps` |
| Where yield goes | 100% to the brand's treasury, as a ledger claim — never into a price |
| Reserve | One pot, many brands |
| Brand to brand | `swap()`, exactly 1:1, no slippage, no pool, no underlying movement |

---

## 1. Why pooling is what makes 1:1 swaps safe

The obvious way to let two branded stablecoins swap for each other is to burn X of one and mint X
of the other. Across two independent ERC-4626-style vaults — one vault per brand, each brand a
share — that is **wrong**, and quietly so: each vault carries its own share price, and those
prices drift apart as the two vaults earn different yield. Swapping share-for-share therefore
hands value from whichever vault's price has drifted higher to whoever noticed. There is no fee
or slippage parameter that fixes it — the mispricing *is* the trade. That per-brand-vault design
was the protocol's first issuance model and is why this one replaced it.

Pooling removes the drift instead of pricing it. Every `PooledBrandToken` in a pool is a flat,
non-appreciating claim on the **same** pot of backing, so its par value never moves relative to any
other brand's. Burning X of one and minting X of another changes neither side's redemption value.
There is nothing left to arbitrage.

That leaves one problem: the reserve still earns yield, and the yield has to end up somewhere. It
cannot show up as price appreciation without reintroducing exactly the drift that was just removed.
So it is tracked as a per-brand ledger entry instead.

## 2. The yield model

`totalAssets()` grows as the yield source earns interest. `totalPooledSupply` — the sum of every
brand's outstanding tokens — does not, because it only ever moves 1:1 against real backing entering
or leaving. The gap between them is yield.

That gap is distributed with a cumulative index:

```
cumulativeYieldPerToken += (totalAssets() - lastAccrualAssets) * 1e18 / totalPooledSupply
```

and each brand settles against it using **its own** outstanding supply:

```
brand.accruedYield += brand.outstanding * (cumulativeYieldPerToken - brand.indexCheckpoint) / 1e18
brand.indexCheckpoint = cumulativeYieldPerToken
```

The "price" here is a single pool-wide rate rather than a per-brand share price, and the thing
it multiplies is one brand's outstanding supply. That is the whole reason the model can offer
a 1:1 swap between two brands: neither side has a price of its own to drift.

Three properties fall out of it, and each has a test:

- **A swap cannot move yield between brands.** `_settleBrand` runs on both sides *before* either
  `outstanding` changes, so the entitlement already earned on the old amount is banked first. The
  swap then only relabels which brand's ledger a future claim sits under.
  (`test_fork_swap_movesNoRealUsdgAndPreservesYieldEntitlement`)
- **A brand that joins late earns nothing retroactively.** `registerBrand` sets
  `indexCheckpoint = cumulativeYieldPerToken` at registration, so its delta starts at zero.
  (`test_fullLifecycle_manyBrandsManyActorsManyYieldRounds`, phase 3)
- **Yield splits strictly by outstanding supply.** Three brands at 1000/2000/500 split a 350 yield
  round as 100/200/50. (`test_fork_yield_splitsProportionally_withRealInterest`)

Every supply-changing call re-syncs `lastAccrualAssets` immediately afterwards
(`_syncAccrualBaseline`), so growth from a mint is never mistaken for yield. `swap()` deliberately
does **not** re-sync: it changes neither `totalPooledSupply` nor `totalAssets()`, so the baseline
`_settleBrand` just set is still correct.

### The solvency invariant

```
totalAssets() >= totalPooledSupply
sum(pendingYield(brand)) <= totalAssets() - totalPooledSupply
```

Every pooled token stays redeemable 1:1, and unclaimed yield is always real surplus rather than a
claim on another brand's principal. `SharedReservePoolIntegrationTest._assertSolvent` asserts both
after every phase of a multi-brand, multi-actor, multi-yield-round lifecycle.

### Rounding dust

`redeem` and `claimYield` **cap their payout at the pool's actual idle balance** rather than
reverting when it comes up short.

This is not defensive padding — a fork test found it. A real yield source's principal can be a wei
or two below book value from Morpho's share↔asset floor division in a non-empty market, and no
amount of recalling can manufacture the missing wei. A hard revert on that dust would brick
redemptions outright. So the shortfall comes back as a payout a wei smaller than requested. For
`claimYield` the difference stays *owed* rather than forgiven, and is paid on the next claim.

### The redemption fee is income

`redemptionFeeBps` (owner-set, capped at `MAX_REDEMPTION_FEE_BPS = 100`, zero by default) is
retained by the reserve on every redemption: the redeemer burns `amount` and is paid
`amount - amount * redemptionFeeBps / 10_000`. The fee is not sent anywhere. `_redeem` re-syncs the
baseline and then lowers `lastAccrualAssets` by the fee, so the next `_accrueGlobal` sees it as
growth — which repays `lossCarryforward` first and only then reaches `cumulativeYieldPerToken`,
the same path yield takes. A native-USDG reserve leaves it at zero, which is why the
USDG/Morpho reserve charges nothing. A reserve whose backing sits behind a bridge and a swap
([docs/SUSDAI_COLLATERAL.md](docs/SUSDAI_COLLATERAL.md)) sets it to the measured round-trip
cost, which is why the sUSDai reserve charges 20 bps: the costs the keeper books as losses are
netted by the redeemers who cause them rather than by every holder.
(`test_redeem_feeRepaysBookedCostsBeforeItBecomesYield`)

### An increase to the fee is announced an hour ahead

`setRedemptionFee` does not apply an increase. It writes `pendingRedemptionFeeBps` and sets
`redemptionFeeEffectiveAt = block.timestamp + FEE_INCREASE_DELAY` (1 hour), and the live fee
does not move until someone calls the permissionless `commitRedemptionFee()` at or after that
time. `FeeIncreaseNotReady` if it lands early. The ceiling is re-checked at commit as well as
at announcement, so a value authorised under an older, higher `MAX_REDEMPTION_FEE_BPS` cannot
land under a lower one.

A **decrease applies immediately** and clears any pending increase, so the owner can always
make the fee smaller at once and can never surprise anyone by making it larger.
`cancelPendingRedemptionFee()` drops an announced increase without changing the live fee; both
it and `commitRedemptionFee` revert `NoPendingFeeIncrease` when nothing is scheduled, rather
than returning quietly, so an owner cannot believe they cancelled something they never
scheduled.

**What this is worth, precisely.** `previewRedeem` and both `redeem` overloads read only the
live fee, so a quote cannot be repriced under a filling integrator inside the hour, and
`redemptionFeeEffectiveAt == 0` is the single read that proves nothing is pending. That is a
reliability guarantee. It is **not** a security guarantee: the Safe can upgrade the
implementation in one transaction and remove the delay. Say it that way to integrators.

## 3. Contracts

| Contract | File | Role |
|---|---|---|
| `SharedReservePool` | `src/pool/SharedReservePool.sol` | The reserve, the ledger, the swap |
| `PooledBrandToken` | `src/pool/PooledBrandToken.sol` | One per brand. Plain ERC-20; only the pool may mint/burn |
| `PoolBrandTreasury` | `src/pool/PoolBrandTreasury.sol` | One per brand. The only address the pool pays that brand's yield to |

`PooledBrandToken` takes its decimals from the pool's asset, so a USDG pool issues 6-decimal
tokens and 1 unit of a brand token always lines up with 1 unit of USDG.

### Access control

| Function | Who | Notes |
|---|---|---|
| `registerBrand` | anyone | A brand with no minted supply earns nothing and affects nobody, so gating it would only add a bottleneck |
| `mint` / `redeem` / `swap` | anyone | Acts on the caller's own balance only |
| `deployIdle` | anyone | Sweeps idle reserve into the yield source. Normally a no-op — `mint` supplies inline |
| `claimYield` | that brand's treasury only | `OnlyBrandTreasury` |
| `setYieldSource` | pool owner (the Safe) | Recalls everything to idle first; does not auto-redeploy. Reverts `MigrationWouldStrand` beyond `MAX_MIGRATION_DUST` unless the two-argument overload accepts the write-off |
| `setRedemptionFee` | pool owner (the Safe) | `FeeTooHigh` above 100 bps. An increase is announced, not applied — see above |
| `commitRedemptionFee` | anyone | Applies an announced increase once its hour is served |
| `cancelPendingRedemptionFee` | pool owner (the Safe) | Drops an announced increase |
| `setLiabilityCap` | pool owner (the Safe) | Ceiling on aggregate brand principal; zero means uncapped |
| `PoolBrandTreasury.claim` / `distribute` / `setAdmin` | treasury admin | Explicit receiver, so it must be gated |

`mint`, `swap`, `claimYield` and `deployIdle` are `whenNotPaused` against `ProtocolGuard`.
**`redeem` is not, and must never become so.** A claim that can be suspended is not a claim;
holders exit 1:1 while everything else is halted, especially then.

`PoolBrandTreasury.claim` is admin-only for one reason: a payout function with an arbitrary
`receiver` is redirectable by whoever calls it. Owning the claim is not enough — the
destination has to be gated too.

## 4. Flows

### Mint (1:1 in)

Requires an ERC-20 approval of the **underlying asset** to the pool.

```
approve(USDG, pool, amount) → pool.mint(token, amount, receiver)
```

Pulls `amount` USDG from the caller, mints `amount` of `token` to `receiver`. Returns `amount`.

Two gates apply. `mint` is `whenNotPaused`, so a halt closes entry while leaving exit open.
And if `liabilityCap` is nonzero, a mint that would push `totalPooledSupply` past it reverts
`LiabilityCapExceeded(currentSupply, mintAmount, cap)`. The sUSDai reserve is capped at
10,000,000 USDG; the USDG/Morpho reserve is uncapped. Read the live figures from
`deployments/mainnet-state.json`, and `MarketLens.maxMint(pool)` for the headroom an
integrator actually has.

### Redeem (1:1 out)

**No approval needed.** The pool burns the caller's tokens directly (`PooledBrandToken.burn` is
pool-only and takes no allowance path), so this is one transaction, not two.

```
pool.redeem(token, amount, receiver)                 # demands previewRedeem(amount); reverts otherwise
pool.redeem(token, amount, receiver, minAssetsOut)   # reverts InsufficientPayout below minAssetsOut
```

Burns `amount` from the caller, recalls from the yield source if idle is short, pays `receiver`
`amount - fee` where `fee = amount * redemptionFeeBps / 10_000`.

**The three-argument overload is strict.** It derives its own floor from
`previewRedeem(amount)` — par less the live fee — and reverts
`InsufficientPayout(payout, minimum)` rather than paying less. It used to pass a floor of zero:
it burned the caller's tokens and then paid whatever the reserve could raise, booking the
difference against `lossCarryforward`, with no revert and no event distinguishing that from a
good redemption. Because the burn happened first there was nothing left to retry with. An
aggregator calling selector `0x5c833bfd` now gets a revert instead of a silent haircut.

**Integrators should call the four-argument overload** and choose their own bound. A holder who
would rather exit at a loss than not exit at all passes a lower `minAssetsOut`; that is a
decision only the caller can make, and it is the only way to reach a haircut now. Pass
`previewRedeem(amount)` to demand exactly par less the fee.

The return value is what was actually paid. It is normally `previewRedeem(amount)` and can be a
wei less (see [Rounding dust](#rounding-dust)) — which is precisely why the strict default
still reverts rather than silently rounding: `_cappedByIdle` truncates, so the dust tolerance
now lives in the caller's chosen bound instead of being an unbounded promise attached to the
simplest entrypoint. **Read the return value rather than assuming `amount`.**

### Swap (brand → brand)

**No approval needed, and no underlying moves.**

```
pool.swap(tokenIn, tokenOut, amount, receiver)
```

Burns `amount` of `tokenIn` from the caller, mints `amount` of `tokenOut` to `receiver`. Always
exactly 1:1 — there is no price, no slippage parameter, no minimum-out, and no deadline, because
there is no path along which the rate could move. Reverts on `tokenIn == tokenOut` (`SameToken`) or
an unregistered token (`UnknownBrand`).

### Claim yield (brand operator)

```
treasury.claim(receiver)   # admin only
```

The treasury calls `pool.claimYield(brandToken, receiver)`, which settles the brand and pays out
its accrued entitlement. `treasury.pendingYield()` previews it without a transaction, including
yield earned since the last on-chain settle.

### Deploy idle (anyone, keeper-shaped)

```
pool.deployIdle()
```

Pushes the whole idle balance into the yield source.

**`mint` already does this inline**, so on a healthy pool this is a no-op and no keeper is
obliged to call it. It remains for reserves that arrive by another route: a direct transfer to
the pool, rounding dust, or the entire position sitting idle after `setYieldSource` recalls it
and deliberately does not re-commit it.

Two consequences of supplying inline are worth stating plainly:

- **Minting is coupled to the yield source.** A paused market, a supply cap or a broken adapter
  makes `mint` revert — and because `MarketRouter.buyWithUsdg` mints, buying stops with it.
  Redemption only ever pulls the other way, so the peg holds for anyone already holding a brand
  token. The failure mode is "cannot enter", never "cannot exit".
- **Every mint/redeem pair round-trips the yield source's share maths**, which floors. A round
  trip at a non-unit share price can retire up to a wei of backing. `claimYield` refuses to pay
  yield while `totalAssets()` sits under `totalPooledSupply()`, so that dust is repaid out of the
  next yield earned rather than forgiven.

## 5. Deploying

**Both live reserves are already deployed.** This section is for standing up a new one, and
for reading what the live ones were built from. Nothing here re-deploys anything: see
[UPGRADING.md](UPGRADING.md) for changing a live reserve, which is a Safe transaction.

```bash
PRIVATE_KEY=0x... TIMELOCK_MIN_DELAY=0 forge script script/DeploySharedReservePool.s.sol --rpc-url robinhood --broadcast --slow
```

Deploys, in one run:

1. **A dedicated `MorphoBlueYieldSource`** targeting the top USDG/USDe market, always fresh.
   The script never accepts an existing adapter address: one adapter per consumer is the rule,
   and the adapters already on chain predate the per-consumer share accounting.
2. **A `ProtocolGuard`** — the pause registry every contract in the stack reads.
3. **The four beacons and the `SharedReservePool` itself**, behind an ERC1967 proxy.
4. **A `TimelockController`, only if `TIMELOCK_MIN_DELAY` is nonzero.** Zero takes a documented
   branch that deploys no timelock at all and leaves the deploying key owning the stack.

It deliberately registers **no brand**: `registerBrand` is permissionless and brand-specific
(name, symbol, admin), and a market's unit is created by `AssetMarketFactory.createMarket`
from the owner's asset approval rather than attached from a pre-existing brand. The script
stands up shared infrastructure and prints the follow-up commands.

> **The live reserves took the zero branch, so neither has a timelock.** Ownership was later
> migrated to the 2-of-3 Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, which is where it
> sits now. That removes the single-key risk and does not add a delay: the Safe can point a
> reserve's entire backing at a new yield source in one transaction. Stated plainly rather
> than implied. `UPGRADING.md` has the full governance picture.
>
> `script/anvil-fork.sh` plus `script/rehearse-mainnet.sh` exercise this whole sequence against
> a fork of 4663 before anything is broadcast.

### Operator commands

Register a brand (permissionless; read `(token, treasury)` from the `BrandRegistered` event):

```bash
cast send <pool> 'registerBrand(string,string,address)' 'Stables USD' 'sphUSD' <brandAdmin> --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY
```

Mint 1,000 USDG into a brand (6 decimals; approve first):

```bash
cast send 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 'approve(address,uint256)' <pool> 1000000000 --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY
```

```bash
cast send <pool> 'mint(address,uint256,address)' <token> 1000000000 <receiver> --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY
```

Swap between two pooled brands:

```bash
cast send <pool> 'swap(address,address,uint256,address)' <tokenIn> <tokenOut> 1000000000 <receiver> --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY
```

Deploy idle reserve into the yield source:

```bash
cast send <pool> 'deployIdle()' --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $PRIVATE_KEY
```

Claim a brand's yield (brand admin key):

```bash
cast send <treasury> 'claim(address)' <receiver> --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key <brandAdminKey>
```

### Monitoring

```bash
# Solvency: must always be >= totalPooledSupply.
cast call <pool> 'totalAssets()(uint256)' --rpc-url https://rpc.mainnet.chain.robinhood.com
cast call <pool> 'totalPooledSupply()(uint256)' --rpc-url https://rpc.mainnet.chain.robinhood.com

# Idle reserve. Should sit near zero — `mint` supplies inline, so a persistently large
# balance means something arrived by direct transfer, or a deposit is reverting.
cast call 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 'balanceOf(address)(uint256)' <pool> --rpc-url https://rpc.mainnet.chain.robinhood.com

# One brand's outstanding supply and unclaimed yield.
cast call <pool> 'outstandingOf(address)(uint256)' <token> --rpc-url https://rpc.mainnet.chain.robinhood.com
cast call <pool> 'pendingYield(address)(uint256)' <token> --rpc-url https://rpc.mainnet.chain.robinhood.com
```

## 6. Function reference

### SharedReservePool

```
registerBrand(name, symbol, admin) -> (token, treasury)
mint(token, amount, receiver)      -> minted        # needs asset approval
redeem(token, amount, receiver)    -> paidOut       # no approval; STRICT: demands previewRedeem(amount)
redeem(token, amount, receiver, minAssetsOut) -> paidOut # reverts InsufficientPayout below minAssetsOut
swap(tokenIn, tokenOut, amount, receiver) -> amount # no approval; always 1:1
claimYield(token, receiver)        -> amount        # brand treasury only
deployIdle()
setYieldSource(newYieldSource)                      # owner only; strict, reverts MigrationWouldStrand
setYieldSource(newYieldSource, acceptStranding)     # owner only; writes the shortfall off deliberately
setRedemptionFee(feeBps)                            # owner only; <= MAX_REDEMPTION_FEE_BPS (100). An INCREASE only schedules
commitRedemptionFee()                               # anyone, once FEE_INCREASE_DELAY has passed
cancelPendingRedemptionFee()                        # owner only
setLiabilityCap(newCap)                             # owner only; zero means uncapped

totalAssets() / totalPooledSupply() / cumulativeYieldPerToken() / lastAccrualAssets() / lossCarryforward()
previewRedeem(amount) -> amount - amount * redemptionFeeBps / 10_000   # what to pass as minAssetsOut
redemptionFeeBps() / MAX_REDEMPTION_FEE_BPS() / FEE_INCREASE_DELAY() / MAX_MIGRATION_DUST()
pendingRedemptionFeeBps() / redemptionFeeEffectiveAt()   # effectiveAt == 0 means nothing is pending
liabilityCap()
pendingYield(token) / outstandingOf(token) / isRegistered(token)
brands(token) -> (registered, treasury, outstanding, indexCheckpoint, accruedYield)
allBrandTokens(i) / allBrandTokensLength()
asset() / assetDecimals() / yieldSource() / owner()
```

Errors: `ZeroAddress`, `ZeroAmount`, `UnknownBrand`, `SameToken`, `OnlyBrandTreasury`,
`InsufficientPayout(payout, minimum)`, `FeeTooHigh(feeBps, maximum)`,
`LiabilityCapExceeded(currentSupply, mintAmount, cap)`, `NoPendingFeeIncrease`,
`FeeIncreaseNotReady(effectiveAt, timestamp)`, `MigrationWouldStrand(deployed, recalled)`,
`OwnershipCannotBeRenounced`.

Events: `BrandRegistered`, `BrandMetadataSet`, `Minted`, `Redeemed`, `Swapped`, `YieldClaimed`,
`Deployed`, `Recalled`, `YieldSourceUpdated`, `MigrationStranded`, `LiabilityCapUpdated`,
`RedemptionFeeRetained(token, fee)` (alongside `Redeemed`, whose amount is the payout), and the
four fee-governance events: `RedemptionFeeUpdated(oldFeeBps, newFeeBps)` for a live change,
`RedemptionFeeIncreaseScheduled`, `RedemptionFeeIncreaseCommitted`,
`RedemptionFeeIncreaseCancelled`. An indexer that tracks only `RedemptionFeeUpdated` still sees
exactly the value every payout uses, because scheduling never emits it.

### PoolBrandTreasury

```
claim(receiver) -> amount            # admin only
distribute(token, to, amount)        # admin only
setAdmin(newAdmin)                   # admin only
pendingYield() / totalYieldClaimed() / pool() / brandToken() / admin()
```

### PooledBrandToken

Standard ERC-20, plus `mint(to, amount)` and `burn(from, amount)` restricted to `pool()`.
`decimals()` mirrors the pool's asset.

## 7. Notes for integrators and anyone building a UI

- **Mint is the only flow that needs an approval.** Redeem and swap burn from the caller directly.
  Do not render an approve step for them.
- **`swap` has no slippage surface.** No min-out, no deadline, no price impact, no route. A swap UI
  here is an amount box and two token pickers — anything more is inventing risk that does not
  exist.
- **`redeem` can return less than requested** by a wei or two on the four-argument overload.
  Show the returned amount, not the requested one, and do not treat the difference as an
  error. The three-argument overload reverts instead of short-paying, so a caller that wants
  the haircut has to ask for it explicitly.
- **Check `redemptionFeeEffectiveAt()` before caching a quote.** Zero means no fee increase is
  pending and the number you just read is good for at least an hour.
- **Pooled brand tokens are not vault shares.** They never appreciate, so a share-price or APY
  column is meaningless on them. The yield figure that belongs to a pooled brand is
  `pendingYield`, and it belongs to the brand operator's dashboard, not to a holder's.
- **A pooled brand's holders see no yield at all.** That is the trade the model makes: holders get
  a permanent peg and free swaps, the brand gets 100% of the yield. Any UI that implies otherwise
  is lying.
- **Discovery is `allBrandTokensLength()` then `allBrandTokens(i)`**, so it batches through
  multicall3.
