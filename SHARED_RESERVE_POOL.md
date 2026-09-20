# SharedReservePool — one reserve, many brands, permanent 1:1

> **Status: built and tested, not deployed.** 26 tests pass (17 unit, 1 integration, 8 against a
> mainnet fork with real USDG and real Morpho Blue). Only a dry run exists on chain 4663
> (`broadcast/DeploySharedReservePool.s.sol/4663/dry-run/`). Nothing in the frontend surfaces it.

`SharedReservePool` is the second issuance model in this repo. It is **independent of
`BrandedVault`** — it touches no vault, no beacon, no factory, no launcher, and no sell wall. A
brand picks one model or the other.

| | `BrandedVault` | `SharedReservePool` |
|---|---|---|
| Brand token | ERC-4626 share | Flat `PooledBrandToken` |
| Redemption value | Share price, appreciates | Always exactly 1.000000 USDG |
| Where yield goes | Into the share price, minus a management fee to the brand | 100% to the brand's treasury, as a claim |
| Reserve | One vault, one brand | One reserve, many brands |
| Brand ↔ brand swap | Only through a DEX pool, with slippage | `swap()`, exactly 1:1, no slippage, no pool |
| Deployed | Yes, mainnet | No |

---

## 1. Why pooling is what makes 1:1 swaps safe

The obvious way to let two branded stablecoins swap for each other is to burn X of one and mint X
of the other. Across two independent `BrandedVault`s that is **wrong**, and quietly so: each vault
carries its own share price, and those prices drift apart as the two vaults earn different yield.
Swapping share-for-share therefore hands value from whichever vault's price has drifted higher to
whoever noticed. There is no fee or slippage parameter that fixes it — the mispricing *is* the
trade.

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

This is the same shape as `BrandedVault._harvestFees`, which distributes yield by share-price
delta. The difference is that the "price" here is a single pool-wide rate, and the thing it
multiplies is one brand's outstanding supply rather than one vault's entire supply.

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
the same path yield takes. A native-USDG reserve leaves it at zero. A reserve whose backing sits
behind a bridge and a swap ([docs/SUSDAI_COLLATERAL.md](docs/SUSDAI_COLLATERAL.md)) sets it to
the measured round-trip cost, so the costs the keeper books as losses are netted by the
redeemers who cause them rather than by every holder.
(`test_redeem_feeRepaysBookedCostsBeforeItBecomesYield`)

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
| `registerBrand` | anyone | A brand with no minted supply earns nothing and affects nobody. Same rationale as `BrandedVaultFactory.createVault` |
| `mint` / `redeem` / `swap` | anyone | Acts on the caller's own balance only |
| `deployIdle` | anyone | Sweeps idle reserve into the yield source. Normally a no-op — `mint` supplies inline |
| `claimYield` | that brand's treasury only | `OnlyBrandTreasury` |
| `setYieldSource` | pool owner (the timelock) | Recalls everything to idle first; does not auto-redeploy |
| `setRedemptionFee` | pool owner (the timelock) | `FeeTooHigh` above 100 bps; applies to every redemption from the next block |
| `PoolBrandTreasury.claim` / `distribute` / `setAdmin` | treasury admin | Explicit receiver, so it must be gated |

`PoolBrandTreasury.claim` is admin-only for the same reason `VaultTreasury.redeem` is: a payout
function with an arbitrary `receiver` is redirectable by whoever calls it. Owning the claim is not
enough — the destination has to be gated too.

## 4. Flows

### Mint (1:1 in)

Requires an ERC-20 approval of the **underlying asset** to the pool.

```
approve(USDG, pool, amount) → pool.mint(token, amount, receiver)
```

Pulls `amount` USDG from the caller, mints `amount` of `token` to `receiver`. Returns `amount`.

### Redeem (1:1 out)

**No approval needed.** The pool burns the caller's tokens directly (`PooledBrandToken.burn` is
pool-only and takes no allowance path), so this is one transaction, not two.

```
pool.redeem(token, amount, receiver)                 # accepts any payout
pool.redeem(token, amount, receiver, minAssetsOut)   # reverts InsufficientPayout below minAssetsOut
```

Burns `amount` from the caller, recalls from the yield source if idle is short, pays `receiver`
`amount - fee` where `fee = amount * redemptionFeeBps / 10_000` (zero unless the owner set one).
Returns the amount actually paid — normally `previewRedeem(amount)`, occasionally a wei less (see
[Rounding dust](#rounding-dust)), and possibly much less if the yield source cannot deliver.
**Pass `previewRedeem(amount)` as `minAssetsOut` to insist on par less the fee**; the
three-argument overload is for callers who have already decided a short payout beats not
redeeming. Either way, **a caller must read the return value rather than assuming `amount`.**

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

**`mint` already does this inline**, so on a healthy pool this is a no-op and there is no keeper
obligation the way `BrandedVault.deployIdle` has one. It remains for reserves that arrive by
another route: a direct transfer to the pool, rounding dust, or the entire position sitting idle
after `setYieldSource` recalls it and deliberately does not re-commit it.

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

```bash
forge script script/DeploySharedReservePool.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --broadcast --slow
```

Deploys three things:

1. **A dedicated `MorphoBlueYieldSource`** targeting the top USDG/USDe market. It must not be the
   instance `DeployMainnet.s.sol`'s flagship vault uses — one adapter per consumer is the rule.
2. **A `TimelockController`** that owns the pool, with the deployer as sole proposer/executor and
   `admin = address(0)`.
3. **The `SharedReservePool`**, owned by that timelock.

It deliberately registers **no brand**: `registerBrand` is permissionless and brand-specific
(name, symbol, admin), so the script stands up shared infrastructure and prints the follow-up
commands rather than guessing at a brand to launch.

> **⚠ `TIMELOCK_MIN_DELAY` is 0.** At zero the timelock is not a timelock — schedule and execute
> land in the same block, and a leaked deployer key can point the pool's entire reserve at a
> malicious yield source in one transaction. It is set to zero because `updateDelay` is gated by
> the *current* delay, so raising it later is instant while lowering it costs the current delay.
> **Raise it before real deposits arrive.** Same posture, same reasoning as
> [UPGRADING.md](UPGRADING.md).

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
redeem(token, amount, receiver)    -> paidOut       # no approval; pays amount - fee; may be less
redeem(token, amount, receiver, minAssetsOut) -> paidOut # reverts InsufficientPayout below minAssetsOut
swap(tokenIn, tokenOut, amount, receiver) -> amount # no approval; always 1:1
claimYield(token, receiver)        -> amount        # brand treasury only
deployIdle()
setYieldSource(newYieldSource)                      # owner (timelock) only
setRedemptionFee(feeBps)                            # owner (timelock) only; <= MAX_REDEMPTION_FEE_BPS (100)

totalAssets() / totalPooledSupply() / cumulativeYieldPerToken() / lastAccrualAssets() / lossCarryforward()
previewRedeem(amount) -> amount - amount * redemptionFeeBps / 10_000   # what to pass as minAssetsOut
redemptionFeeBps() / MAX_REDEMPTION_FEE_BPS()
pendingYield(token) / outstandingOf(token) / isRegistered(token)
brands(token) -> (registered, treasury, outstanding, indexCheckpoint, accruedYield)
allBrandTokens(i) / allBrandTokensLength()
asset() / assetDecimals() / yieldSource() / owner()
```

Errors: `ZeroAddress`, `ZeroAmount`, `UnknownBrand`, `SameToken`, `OnlyBrandTreasury`,
`InsufficientPayout(payout, minimum)`, `FeeTooHigh(feeBps, maximum)`.

Events: `BrandRegistered`, `Minted`, `Redeemed`, `Swapped`, `YieldClaimed`, `Deployed`,
`Recalled`, `YieldSourceUpdated`, `RedemptionFeeUpdated(oldFeeBps, newFeeBps)`,
`RedemptionFeeRetained(token, fee)` (alongside `Redeemed`, whose amount is the payout).

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

## 7. Notes for whoever builds the UI

Nothing in `web/` reads this stack today. When it does:

- **Mint is the only flow that needs an approval.** Redeem and swap burn from the caller directly.
  Do not render an approve step for them.
- **`swap` has no slippage surface.** No min-out, no deadline, no price impact, no route. A swap UI
  here is an amount box and two token pickers — anything more is inventing risk that does not
  exist.
- **`redeem` can return less than requested** by a wei or two. Show the returned amount, not the
  requested one, and do not treat the difference as an error.
- **Pooled brand tokens are not vault shares.** They never appreciate, so a share-price or APY
  column is meaningless on them. The yield figure that belongs to a pooled brand is
  `pendingYield`, and it belongs to the brand operator's dashboard, not to a holder's.
- **A pooled brand's holders see no yield at all.** That is the trade the model makes: holders get
  a permanent peg and free swaps, the brand gets 100% of the yield. Any UI that implies otherwise
  is lying.
- **Discovery is `allBrandTokensLength()` then `allBrandTokens(i)`** — the same shape as
  `BrandedVaultFactory.allVaults`, so it batches through multicall3 the same way.
