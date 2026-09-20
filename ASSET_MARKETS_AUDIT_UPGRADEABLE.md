# AssetMarkets — security audit of the upgradeable stack, 2026-09-10

> Scope: the whole of `src/` as deployed to Robinhood Chain mainnet (4663) on 2026-09-10 —
> `src/upgrade/*`, `src/pool/*`, `src/yield/MorphoBlueYieldSource.sol`, `src/markets/*`, and the
> three deploy scripts. Reviewed against the live deployment recorded in
> [deployments/asset-markets-mainnet-v4.json](deployments/asset-markets-mainnet-v4.json).
>
> **Unlike the two prior audits, this one reviews contracts that are already on mainnet.**
> Runtime bytecode of every deployed implementation was rebuilt locally and compared byte for
> byte against the chain, so this is an audit of what is live rather than of what might be.
>
> Supersedes the posture described in [ASSET_MARKETS_AUDIT.md](ASSET_MARKETS_AUDIT.md) and
> [ASSET_MARKETS_AUDIT_MULTILEG.md](ASSET_MARKETS_AUDIT_MULTILEG.md); verdicts on every open
> finding from those two documents are in section 2.
>
> **One CRITICAL, two HIGH and four MEDIUM findings. The CRITICAL is live right now and is the
> only finding exploitable without a market existing.** Everything else needs a pool, and
> `marketCount() == 0`, so there is a clean window to fix before launch.

## 1. Confidence: the audited source is the deployed source

HEAD is `53f80f5` "Deploy the upgradeable stack and record the mainnet run"; the tree is clean.
Every deployed implementation was rebuilt locally and its runtime size compared against the
chain — all match exactly, modulo the two OZ `UUPSUpgradeable.__self` immutable slots:

| Contract | Local runtime | On chain |
|---|---|---|
| `AssetMarketFactory` (impl) | 16,169 | 16,169 |
| `MarketRouter` (impl) | 15,847 | 15,847 |
| `ProtocolFeeHook` (impl) | 11,728 | 11,728 |
| `BuybackEngine` | 11,533 | 11,533 |
| `BrandFeeVault` | 8,160 | 8,160 |
| `MarketDeployer` (library) | 2,593 | 2,593 |
| `AssetLockbox` | 1,137 | 1,137 |

The factory implementation contains the `MarketDeployer` link exactly once. All five live
proxies read `_initialized == 1`; all sixteen implementations read `0xffff…ffff` at the OZ
`Initializable` slot, so `_disableInitializers()` ran everywhere.

**EIP-170 is no longer breached.** `ASSET_MARKETS_AUDIT.md` recorded the factory 2,142 bytes
over the limit; extracting `MarketDeployer` as a linked library fixed it, with 8,407 bytes to
spare.

## 2. Verdicts on the prior audits' open findings

| Finding | Verdict | Evidence |
|---|---|---|
| **HIGH-1** router never refunds unabsorbed input | **FIXED** | `_swapExactIn` now returns `spent`, measured as the router's own balance delta (`MarketRouter.sol:517`), and all four entry points refund it (`:273`, `:308`, `:339`, `:426`). Arithmetic verified sound. Its secondary recommendation — reject `minAssetOut == 0` — was **not** implemented, and that omission is what exposes M-2 below. |
| **HIGH-2** leg weight measures liquidity, not float | **OBSOLETE** | `MarketYieldSplitter` is deleted. One-brand-one-market is enforced at `AssetMarketFactory.sol:735`; `BrandFeeVault.sweep` holds no weighting at all. |
| **MEDIUM-1** brand operator handover moves nothing | **SPLIT** | The splitter divergence is obsolete. The root cause survives: `brandOperatorOf` still has exactly one write (`AssetMarketFactory.sol:683`) and no setter — see L-1. |
| **MEDIUM-2** registration/listing split enables a permanent price squat | **STILL REACHABLE, amplified** | See M-3. |
| **MEDIUM-3** testnet yield source reverts on a full redemption | **FIXED** | `DeployAssetMarketsTestnet.s.sol:199-208` clamps to the available balance. Testnet fixture only; production adapters were always correct. |
| **LOW-1**, **LOW-2** | **OBSOLETE** | The per-leg read clock and `retireLeg` no longer exist anywhere in `src/`. |
| **LOW-3** stale comments | **PARTLY OPEN** | `AssetMarketFactory.sol:521` still says the operator "carries no on-chain authority at all"; it still receives the brand's metadata admin at `:678`. Several others are listed in section 5. |

## 3. Findings

### CRITICAL-1 — three of the six UUPS proxies are owned by the deployer EOA, not the timelock

Read off chain 4663:

| Proxy | `owner()` |
|---|---|
| `ProtocolGuard`, `SharedReservePool`, `MorphoBlueYieldSource` | `0x5f43E1e7…872a` — the 48h timelock ✅ |
| `ProtocolFeeHook`, `AssetMarketFactory`, `MarketRouter` | `0xeA6Af6c4…12A9` — the deployer EOA ❌ |

Proven by simulated `eth_call`, nothing broadcast: `upgradeToAndCall(currentImpl, "")` from that
EOA **returns `0x`** on all three; from any other address it reverts `0x118cdaa7`
(`OwnableUnauthorizedAccount`). `pendingOwner()` is `0x0` on all three, so no transfer is in
flight. **The 48h timelock does not stand in front of these contracts at all.**

Cause: step 1 passes `address(timelock)` to everything it deploys; `DeployAssetMarkets.s.sol`
passes `deployer` at lines 281, 289, 302 and 327, and never transfers ownership afterwards. The
only post-deploy governance call is `feeHook.setRegistrar`.

What that one key can do today, with no delay:

1. **Drain every outstanding router approval in one transaction.** `seedLiquidity` /
   `buyWithUsdg` / `sellForUsdg` pull user funds with `asset.safeTransferFrom(msg.sender, …)`
   *after* the user approves the router for both sides, which the deploy script's own runbook
   instructs them to do. A replacement router implementation takes all of it.
2. **Brick or overcharge every swap in every market, permanently.** The hook proxy sits at a
   CREATE2-mined address whose low 14 bits carry `0x00CC` = `beforeSwap | afterSwap | both
   return-deltas`. Because v4 reads permissions from the *address*, the PoolManager keeps calling
   the hook on every pool that names it no matter what the implementation does. Emptying the
   implementation slot makes `Hooks.callHook` revert `InvalidHookResponse` on every swap — and
   the address cannot be re-derived, so recovery means re-creating and re-seeding every pool.
   A malicious implementation instead returns an inflated `beforeSwapDelta`, which
   `Hooks.sol:317` moves onto the swapper while the hook's own delta nets to zero, so the swap
   still settles. `Hooks.validateHookPermissions` runs only in `initialize`
   (`ProtocolFeeHook.sol:213`) and is never re-checked on upgrade.
3. **Point every future market's vault, engine and lockbox at arbitrary code.** `beacons` sits
   in plain proxy storage slots 3/4/5 (verified: the raw slots equal the `beacons()` getter),
   and its NatSpec at `:186-192` argues a setter would create "two routes to the same power, one
   of them unaudited." Today the unaudited route is one key with zero delay. This defeats
   `AssetLockbox`'s entire timelock argument for every market created afterwards.
4. **Re-rate and redirect live economics.** `hook.setRegistrar(attacker)` then `registerPool`
   any not-yet-registered key with an arbitrary recipient — and because `registerPool` is
   one-shot, pre-registering also permanently blocks that market from ever being created.
   `hook.setPoolFeePips` can raise any live pool to `MAX_FEE_PIPS = 50_000` (5%, versus the 0.50%
   deployed). `factory.setLpBps(9999)` reduces the buyback to 1 bp for all future markets
   (`_setLpBps:1063` only requires `lpBps + protocolBps < 10_000`). `setProtocolParams` moves
   the treasury; `setBuybackParams` widens the band to its 500 bps ceiling and shortens the
   window to its 300 s floor.

Aggravating context: the same address is also `protocolTreasury` (receives every market's trading
skim), the `ProtocolGuard` guardian (instant global pause), and holds both `PROPOSER_ROLE` and
`EXECUTOR_ROLE` on the timelock. It carries an **EIP-7702 delegation** —
`cast code` returns `0xef010063c0c19a282a1b52b07dd5a65b58948a07dae32b` — to an unidentified
11,185-byte contract. Even if that delegate enforces an m-of-n policy on outgoing calls, the
EOA's own key can still sign a plain transaction and can revoke the delegation at will, so
control reduces to one key regardless.

**Why every check missed it.** `DeployAssetMarkets.s.sol:462` does contain an EOA-ownership
warning, but it inspects `Ownable(address(pool)).owner()` — the *reserve pool's* owner, which
genuinely is the timelock, so it correctly stays silent. The hook, factory and router owners are
never checked. And even if they were, the test is `owner.code.length == 0`, which is false for a
7702-delegated EOA (23 bytes). `VerifyAssetMarketsMainnet.s.sol:101` requires a contract owner
for the pool only; line 164 merely *prints* the factory's. `test_everyBeaconIsOwnedByTheTimelock`
covers beacons, not UUPS proxies, and passes. The deploy log line "TimelockController (owns every
proxy and beacon)" and this repo's own manifest repeated the claim without checking the chain.

**Exploitable on the deployed contracts: yes, immediately, with no pool required.** This is the
only finding of which that is true.

**Present exposure is nonetheless zero**, because `marketCount() == 0`: there are no pools for a
malicious hook to touch and no users with router approvals to drain. That is the window.

**Remediation.** Simulated and confirmed working — `transferOwnership(timelock)` from the EOA
returns `0x` on all three, and the 7702 delegation does not block it (a delegation designator
affects calls *to* an address, not transactions *from* it):

1. From the EOA: `transferOwnership(0x5f43E1e7…872a)` on the hook, factory and router.
2. After 48h: the timelock executes `acceptOwnership()` on each.

These are `Ownable2Step`, so the EOA retains full upgrade power until step 2 completes and may
re-point `pendingOwner` meanwhile — the window does not close until acceptance. Then fix the
cause: have `ProtocolStack.deployFactory` / `deployRouter` / `hookProxyInitCode` assert
`owner.code.length > 0` *and* that the code is not a `0xef0100` designator, or better, positively
assert the owner is the known timelock; and extend `VerifyAssetMarketsMainnet` to require a
contract owner on **every** proxy and beacon.

### HIGH-1 — `ProtocolGuard` does not disable `renounceOwnership()`

`ProtocolGuard.sol:41` inherits `Ownable2StepUpgradeable`; `renounceOwnership()` is `public
onlyOwner` and is neither overridden nor disabled. Proven reachable: `cast call <guard>
'renounceOwnership()' --from <timelock>` succeeds; from any other address it reverts.

If the timelock ever executes it, `owner()` becomes `address(0)`. Since `msg.sender` can never be
`address(0)` in a transaction, `unpause()`, `unpauseTarget()`, `setGuardian()` and
`_authorizeUpgrade()` (`:138`) all become permanently uncallable — while `pause()` **still works
for the guardian**, because `onlyGuardianOrOwner` is `msg.sender != guardian && msg.sender !=
owner()`. Every guarded function in every market then reverts `ProtocolPaused` forever, with no
repair path short of redeploying the guard.

This is the actual irreversible brick. It stays High rather than Critical for one reason, and it
is the reason that matters: `SharedReservePool._redeem` carries no `whenNotPaused` and
`PooledBrandToken` does not inherit `GuardedUpgradeable` at all, so holders can still exit 1:1.
The protocol dies; the money is not trapped.

Requires the timelock, so it is 48h, publicly visible, and cancellable by the EOA's
`CANCELLER_ROLE` — a footgun with no guard rail rather than an external attack. **Fix:** override
`renounceOwnership()` in `ProtocolGuard` to revert unconditionally, and add a regression test
asserting that after `pause()` some caller can always still `unpause()`.

### HIGH-2 — the trading skim is levied on the requested input, so a partial fill is skimmed at up to 10× the intended rate

`ProtocolFeeHook.sol:382-383` computes the fee from `params.amountSpecified` — the swapper's
**gross** request — because the fill is unknowable at `beforeSwap` time:

```solidity
uint256 feeAmount =
    FullMath.mulDiv(uint256(-params.amountSpecified), feePipsFor(id), PIPS_DENOMINATOR);
```

Core then trades only the remainder (`Hooks.sol:273`) but credits the hook the **full**
`feeAmount` regardless of how much the pool absorbed (`Hooks.sol:308-318`). `Pool.swap`'s loop
terminates on the price limit *without reverting* (`Pool.sol:344`) and returns what was actually
consumed. And `MarketRouter.sol:474-477` deliberately sets the limit to the extreme
(`MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`), so a liquidity-exhausted pool produces a partial
fill rather than a revert. `:517` then refunds only the unspent input.

Net: **the swapper pays `filled + fee(gross)`.** Worked example — a market with $50k of in-range
liquidity, a trader calls `buyWithUsdg(marketId, 1_000_000e6, minAssetOut, …)`. The pool absorbs
~$50k; the skim is `1_000_000 × 5000 / 1e6` = **$5,000**; the router refunds the other ~$945k.
That is a **10% effective fee instead of 0.50%**. If `minAssetOut` was quoted against the full
$1M the transaction reverts and nothing is lost — but `minAssetOut == 0` is still accepted
(HIGH-1's unimplemented secondary recommendation), and with a loose or zero minimum the excess
is simply gone.

No attacker is required; it is a loss to the trader and a windfall to the treasury. This is the
residual of the prior HIGH-1 that the refund fix *exposed* rather than removed: before, the whole
remainder was stranded; now it is returned minus a fee computed on money never traded.

**The fix belongs in the router, not the hook.** `beforeSwap` cannot know the fill, and
`afterSwap`'s return value lands on the *unspecified* (output) currency (`Hooks.sol:311-315`), so
an excess-skim refund is not expressible on the input side. Quote and cap `amountIn` against
`marketLiquidity` before swapping, and/or reject `minAssetOut == 0`.

**Exploitable today: no** — `marketCount() == 0`. Live the moment a pool exists with bounded
depth, which is the normal condition for the thin markets this product targets.

### MEDIUM-1 — `sweep()` is hard-coupled to the yield source, defeating the documented fail-soft rule

`BrandFeeVault._donateToLps` mints brandUSD (`:396`, `reservePool.mint`) whenever the vault's
brand balance is short of the LP leg — which is the **normal** case, because `harvest()` pays
yield in USDG. `SharedReservePool.mint` is `whenNotPaused` and calls `_deployIdle()` →
`yieldSource.deposit()`. If that reverts, the whole `sweep()` reverts: the protocol's cut is
unpaid, the LP donation is unmade, and — the part that matters — **the buyback budget never
reaches the engine**, so `execute()` sits at `BelowMinNotional` indefinitely.

This contradicts `BuybackEngine.sol:32-40`, which promises "`harvest` calls no destination; …
everything that can revert lives in `execute`." `sweep` does call a destination that reaches the
adapter.

No attacker needed. The timelock runs `SharedReservePool.setYieldSource` — which deliberately
recalls everything and leaves it idle — and until `deployIdle()` succeeds against the new
adapter, **every market's income distribution freezes at once**. Same for a Morpho market at its
supply cap or paused. **Fix is small:** the zero-liquidity branch already has the right shape
(`LpShareRolledToBuyback`, `:349-359`); wrap the mint in try/catch and roll the LP leg to the
buyback on failure.

### MEDIUM-2 — redemption liveness: no idle buffer, so every redemption depends on Morpho

`mint` calls `_deployIdle()` inline (`:344`), sweeping **every** idle unit into Morpho, so the
pool holds a standing idle balance of ~0 and every redemption must cross `_recallIfNeeded` →
`MorphoBlueYieldSource.withdraw` → `morphoBlue.withdraw`. Morpho Blue reverts
`InsufficientLiquidity` when the singleton's loan-token balance is below the request, and that
revert propagates out of `redeem`. There is no partial-recall fallback and no `minIdle` or
reserve-ratio parameter anywhere in the file. Live utilization was 90.08% at deploy time.

Calibration: this is a **revert, not a haircut** — Morpho never underpays, so tokens are never
burned without payment. The `_cappedByIdle` silent-haircut path (`:398-402`) only ever fires on
≤1-2 units of share↔asset rounding. An adversarial version (borrow the singleton's idle USDG
down below the pool's recall size) is real but economically absurd at current scale: the
singleton holds ~46.6M USDG idle against a pool that may hold thousands. **Medium at present
AUM, rising with it.** Fix: keep a target idle buffer in `_deployIdle`, and let
`_recallIfNeeded` fall back to best-effort plus `_cappedByIdle` so the `minAssetsOut` overload
degrades instead of bricking.

Related, both LOW: `setYieldSource` recalls inline with no fallback, so migration away from a
failing adapter is impossible exactly when needed; and `deployIdle()` is public and
permissionless with no `onlyOwner`, so the instant a migration lands anyone can push the whole
reserve into the new adapter, defeating the "funds sit idle until we decide" property its own
comment claims.

### MEDIUM-3 — the first market can be pre-poisoned, and that window is open now

`_ensurePool` (`AssetMarketFactory.sol:868-895`) still *adopts* a pre-initialised pool and still
reverts `PoolPriceOutOfBand` at `:891` when `assetPriceE18 != 0` with band 0. Brand tokens are
`CREATE`d by the reserve pool, so their addresses are `keccak(rlp([reservePool, nonce]))` —
public, and each registration consumes exactly two nonce values. v4 `PoolManager.initialize`
deploys nothing and is cheap, and the factory pins five fee tiers (`:947-953`), so an attacker
can enumerate the next K future brand addresses and pre-initialise K × 5 poisoned keys for a few
thousand cheap transactions.

`marketCount() == 0`, so **the first brand's address is computable today**. For the two-step
`registerBrand`/`openMarket` path the block is permanent (the address is already fixed, so every
later `openMarket` at band 0 reverts forever). For `createMarket` it is per-attempt — the revert
unwinds `_registerBrand` too, so the nonce never advances and the poisoned key stays valid; the
attacker only has to keep winning the ordering race.

The danger is in the response: widening the band adopts the attacker's price, and passing
`assetPriceE18 = 0` **silently adopts whatever the pool holds** (`:887-889`). Either hands over a
priced pool that the operator then seeds liquidity into via `MarketRouter`, converting a grief
into a theft. With band 0 it stays a grief. The prior audit's recommended fix — caller-supplied
`sqrtPriceX96`, or repricing an empty pool — is still absent.

### MEDIUM-4 — `pause()` does not stop market creation

`AssetMarketFactory` inherits `GuardedUpgradeable` (`:78`) and calls `__Guarded_init(_guard)`
(`:449`) but has **zero** `whenNotPaused` usages anywhere in the file. Both
`SharedReservePool.registerBrand` overloads (`:215`, `:246`) are likewise unguarded; the guarded
pool functions are `mint` (`:322`), `swap` (`:424`), `claimYield` (`:453`) and `deployIdle`
(`:489`).

So during a global halt anyone can still call `createMarket` / `registerBrand`, deploy two fresh
`BeaconProxy` instances, call `poolManager.initialize(key, sqrtPriceX96)` at an attacker-chosen
price, and `feeHook.registerPool(...)`. `ProtocolGuard.sol:14-19` advertises "a single `pause()`
halts every guarded contract at once," which is not true here, and an incident responder would
reasonably believe it.

Traced for value movement and found none: `createMarket`/`openMarket` take no deposit, a new
brand registers with zero supply and checkpoints at the current `cumulativeYieldPerToken`
(`:288`) so it cannot claim past yield, `openMarket` for an existing brand is gated by
`brandOperatorOf` (`:619-621`), and the factory passes `guard: address(guard())` into every
market it creates (`:719`), so a market born during a halt has its vault and engine already
halted. **An incident-response gap, not a theft.** Either add `whenNotPaused` to
`createMarket`/`registerBrand`/`openMarket`, or drop `GuardedUpgradeable` from the factory and
say plainly in the guard's note that registration is never halted.

### LOW findings

- **L-1 — `brandOperatorOf` has no setter** (`AssetMarketFactory.sol:683`, the only write).
  `_registerBrand` installs the *factory* as `PoolBrandTreasury` admin (`:665`) and only
  `_openMarket` moves it to the vault (`:756`), which gates on `msg.sender ==
  brandOperatorOf[brand]`. An issuer who calls `registerBrand` with a wrong or lost operator
  address strands that brand's yield **permanently** — the factory exposes no claim path and no
  reassignment. `createMarket` is not exposed (it installs the vault in the same call). Fix:
  `setBrandOperator(brand, newOperator)` gated on the current operator; the splitter half of the
  old MEDIUM-1 is gone, so this is now ~15 minutes.
- **L-2 — `receiver == address(router)` permanently strands swap output.** `MarketRouter.sol:520`
  guards the transfer with `if (receiver != address(this))`, and `receiver` is only checked
  against `address(0)` (`:254`, `:290`, `:327`). `_refund` covers only unspent *input*, and the
  router has no `multicall`/`sweep`/`rescue`/`recover` (verified by grep). Self-harm, not theft,
  and unreachable by anyone else — but the ABI invites the mistake and the loss is silent.
  Fix: `if (receiver == address(this)) revert ZeroAddress();`.
- **L-3 — refunds are redeemed with no minimum payout.** `MarketRouter.sol:646` uses the 3-arg
  `redeem`, which forwards `minAssetsOut = 0`; `_redeem` caps at idle rather than reverting.
  Deliberate — the pool's docstring at `:363-366` names router refunds as the intended caller —
  and the *main* legs are protected (`sellForUsdg` checks `minUsdgOut` at `:342`). Recorded
  because M-2 above makes non-zero refunds common rather than rare.
- **L-4 — neither the hook nor the router declares a `__gap`.** Their bases are correctly
  namespaced (ERC-7201 / fixed slots), but their *own* variables are plain sequential slots. The
  router can survive a layout mistake by redeploying; **the hook cannot** — its address is mined
  against its creation code and `PoolKey.hooks` is part of every pool's identity, so inserting a
  variable anywhere but the end relocates the per-pool oracle ring buffers and the accrued-fee
  ledger under a live proxy with no redeploy available. Given CRITICAL-1 this is the failure most
  likely to be hit by accident.
- **L-5 — permissionless brand and asset binding.** Nothing checks name or symbol uniqueness.
  Anyone can `createMarket` a token literally named "Stables USD" / "sphUSD"; and because
  `_validateListing` accepts any address with code, an attacker can point a market at a
  *genuine* canonical Robinhood equity and earn `Market.verified = true` (`:824`) and a
  `verified: true` `MarketCreated` event on an attacker-chosen brand, price and liquidity
  profile. `createMarket` also accepts an arbitrary `p.operator` (`:645`), so a victim can be
  named as the operator of a fraudulent brand in an indexed event. `marketCount() == 0` means
  first mover wins every name. A product decision, not a code one: gate `createMarket` behind a
  curator, or rename `verified` to something that cannot read as endorsement.
- **L-6 — `_validateListing` does not reject the reserve underlying as the asset**
  (`:796-799` checks only zero address, code length and cardinality). `createMarket({asset:
  USDG})` succeeds, creating a brandUSD/USDG pool between two tokens the protocol treats as
  interchangeable at 1:1 — `BrandFeeVault.balance()` and `BuybackEngine.budget()` simply add
  them. Another market's brand token is likewise accepted. No direct extraction (the mint is 1:1
  and both legs stay backed), so a degenerate-market issue. One line:
  `if (assetToken == address(reservePool.asset())) revert`.
- **L-7 — `deployIdle()` omits `_syncAccrualBaseline()`.** `mint` documents the rule at
  `:340-345` and follows it; the public `deployIdle()` (`:489`) calls `_deployIdle()` and returns
  without re-syncing, against `_deployIdle`'s own instruction at `:494-496`. Each rounding loss
  leaves `totalAssets()` one unit below `lastAccrualAssets`, so the next `_accrueGlobal()` adds 1
  to `lossCarryforward`, suppressing yield credit. **Not profitably exploitable:** `_deployIdle`
  returns early when idle is 0, so each unit of `lossCarryforward` costs a fresh donation plus a
  transaction; suppressing meaningful yield would cost millions in gas. One-line fix.
- **L-8 — `renounceOwnership()` is also live on the other five proxies.** On those it merely
  forfeits future upgradeability, arguably a legitimate "freeze it" move. The guard is uniquely
  dangerous (HIGH-1) because renouncing destroys the *resume* path while leaving *halt* armed.
- **L-9 — `PooledBrandToken.handOverMetadataAdmin` accepts `address(0)`** (`:220-227`) and burns
  the one-shot flag doing it, permanently freezing all three metadata strings with no recovery
  short of a beacon upgrade. Every other authority transition in the file is two-step
  specifically to make this impossible. `PoolBrandTreasury.setAdmin` (`:112`) is likewise
  single-step with no acceptance, and a typo orphans the brand's entire yield stream.
- **L-10 — band-exceeded surfaces a v4 core error and `canExecute()` reports ready.**
  `AssetMarketFactory.sol:141-142` claims pushing past the band "makes the round fill nothing and
  revert `NoProgress`." It does not: v4 checks the limit against `slot0Start.sqrtPriceX96` before
  the loop and reverts `PriceLimitAlreadyExceeded`. Safety is unaffected — both paths revert the
  whole transaction, `lastExecutedAt` is untouched and the interval is not consumed — but
  `canExecute()` (`:478-485`) probes only `sqrtPriceLimitX96()`, which succeeds even when the
  limit it returns is already breached, so a keeper gets `(true, "")` then a revert the engine
  does not name. Substantively: with the deployed band (200 bps on sqrt ≈ 4.04% on price), **any
  adverse move over ~4% inside the 1800 s window halts the buyback until the TWAP catches up** —
  self-healing, attacker-inducible at the cost of holding inventory, and it stops the buyback in
  exactly the volatile conditions the product exists for.
- **L-11 — `MarketDeployer` is a permissionless external library.** `deploy` is `external`, so
  anyone may `DELEGATECALL` the live library, and `BrandFeeVault.initialize` takes `_factory` as
  an *argument* rather than from `msg.sender`, so a direct caller supplies its own factory and
  owns `setEngine`. Anyone can also `new BeaconProxy(realVaultBeacon, "")` — OZ 5.7.0 only
  delegatecalls init data when non-empty — leaving an uninitialised proxy against the real beacon
  that anyone can then initialise. **Traced and contained:** a counterfeit vault cannot reach
  real funds, because `harvest()` routes to `PoolBrandTreasury.claim`, which is `onlyAdmin`, and
  every real treasury's admin is the factory or the real vault, neither of which a counterfeit
  can become (`setAdmin` is `onlyAdmin`). Counterfeit *surface*, not theft — but an indexer that
  discovers markets by scanning beacon deployments or `Locked`/`Swept`/`BoughtBack` events rather
  than `AssetMarketFactory.market(id)` will report markets that do not exist.
- **L-12 — unchecked external call into an attacker-supplied asset mid-creation.**
  `quoteSqrtPriceX96` calls `IERC20Metadata(asset).decimals()` (`:997-998`) inside `_ensurePool`,
  after `brandOperatorOf` and `treasuryOfBrand` are written but before the market is recorded.
  All five reentrancy routes were traced and none pays: reentrant `openMarket` on the same key
  hits `PoolAlreadyRegistered` (`:737`); on a different key the outer's `setAdmin` reverts
  `OnlyAdmin`; reentrant `poolManager.initialize` hits `PoolAlreadyInitialized`; reentrant
  `registerPool` hits `OnlyRegistrar`. Not exploitable as written, but an unnecessary
  arbitrary-code point mid-creation — read both `decimals()` in `_validateListing` before any
  registry write.
- **L-13 — `sweep` and `forwardAsset` lack a reentrancy guard while calling an arbitrary asset.**
  `forwardAsset` transfers to the engine before `lockHeldAsset()` and before
  `totalAssetLockedDirectly += amount`, so a transfer hook that re-enters double-counts the
  counter. **Bound: every destination is written once at initialisation and none is
  caller-supplied, so no value can be redirected** — only a counter misstated. A reentrant `sweep`
  nesting `poolManager.unlock` is stopped by `AlreadyUnlocked`. `nonReentrant` costs nothing.

### INFORMATIONAL — initializers and future upgrades

All four per-market initializers (`BrandFeeVault:187`, `BuybackEngine:211`, `AssetLockbox:72`,
`PoolBrandTreasury:70`) are `external initializer` with **no `msg.sender` gate**. Safe today only
because every legitimate instance is initialised inside its own `BeaconProxy` constructor and
every implementation carries `_disableInitializers()` (verified on chain for all sixteen). The
forward-looking hazard: OZ gives initializers no access control, so any future implementation
shipped behind these beacons that adds a `reinitializer(n)` without an explicit caller check is
callable by anyone on every live instance simultaneously. `setEngine`
(`BrandFeeVault.sol:240-247`) is the pattern to copy — one-shot **and** `onlyFactory`. Worth a
line in the upgrade runbook before the first beacon upgrade is proposed.

Beacon upgrades validate nothing beyond `newImplementation.code.length > 0`. Unlike UUPS's
`upgradeToAndCall`, which checks `proxiableUUID() == IMPLEMENTATION_SLOT`, a beacon performs no
layout or interface validation, so one wrong argument rewrites every brand token, treasury,
vault, engine and lockbox at once with no revert to catch it. Inherent to the pattern and
accepted explicitly at `ProtocolStack.sol:36-41`; the only defence is off-chain review, and no
test asserts that an incompatible implementation is rejected, because nothing rejects it.

## 4. Two structural constraints that cannot be changed later

- **The hook's permission bits are permanent.** `getHookPermissions()` sets
  `beforeDonate: false, afterDonate: false`, and the address is mined against exactly that. Adding
  either flag changes the low 14 bits, changes the address, and orphans every pool. Consequence:
  the protocol's own LP-fee donation (`lpBps = 5000`) is **permanently undefendable against a
  sandwich** — add a large position before the donation lands, take a pro-rata share, remove it
  after. The hook cannot see it and cannot react.
- **A hook that swaps through its own `unlock` would trade fee-free.** `Hooks.beforeSwap` /
  `afterSwap` early-return zero when `msg.sender == address(self)` (`Hooks.sol:252`, `:296`), and
  the hook only calls `unlock` from `collect`. Not exploitable today; a hard constraint on any
  future hook implementation. Belongs in the upgrade checklist.
- **The skim is enforceable on exactly one pool per market.** `feePipsFor` returns 0 for an
  unregistered pool and `PoolManager.initialize` is permissionless, so anyone can open a
  fee-free sibling venue for the same `(brand, asset, fee)` with a different `tickSpacing` — or
  with `hooks = address(0)`. Inherent to v4 and deliberately documented at
  `ProtocolFeeHook.sol:253-256`; recorded so the skim is not assumed enforceable at the *pair*
  level.
- **The global `NonzeroDeltaCount` check is what makes the shared singleton safe.**
  `PoolManager.unlock` reverts `CurrencyNotSettled` if *any* address's delta is nonzero at the
  end (`PoolManager.sol:112`), not just the unlocker's. So a malicious token's transfer hook, or
  any re-entrant contract reached during an unlock, cannot `mint` or `take` from the singleton and
  walk away. This matters because the PoolManager is shared with other projects and has minted
  2.3M v4 positions.

## 5. Documentation defects that will mislead the next reader

The code is right and the prose is wrong in each of these:

- `BuybackEngine.sol:348-355` states the trading skim "makes a round trip and returns to next
  round's budget rather than leaving the market." Under the settled design
  (`AssetMarketFactory.sol:773` registers the pool with `protocolTreasury`) it does not. The real
  number: **~1% of every buyback round never reaches the lockbox** — 0.50% skim to the treasury
  plus the 0.50% preset LP fee — across up to 1,460 rounds a year.
- `ProtocolFeeHook.sol:34-38`, `registerPool`'s `@param recipient`, and the `feeRecipientOf`
  NatSpec at `:135-137` all still name the market's `BrandFeeVault` as the destination. The
  factory's own comment at `:760-772` is correct. An integrator reading the hook would conclude
  the buyback is fee-funded.
- `AssetMarketFactory.sol:141-142` mis-describes the band-exceeded revert (L-10).
- `AssetMarketFactory.sol:521` still says the operator "carries no on-chain authority at all."
- `SharedReservePool.deployIdle`'s contract is contradicted by its missing baseline re-sync (L-7).
- `ProtocolGuard.sol:14-19` claims a single `pause()` halts every guarded contract (MEDIUM-4).
- `deployments/asset-markets-mainnet-v4.json`'s `architecture` field asserts the timelock "owns
  every proxy and every beacon" — false for three of six (CRITICAL-1). So does the deploy log
  line "TimelockController (owns every proxy and beacon)".
- `docs/ASSET_MARKETS_MAINNET.md` describes the pre-upgradeable generation throughout:
  `SplitterDeployer`, a two-step `registerBrand`/`openMarket` launch flow, a six-transaction gas
  table rather than thirty-six, and a "raising the timelock delay" section targeting gen-1's
  timelock at `0x71300c2D…05db`.

## 6. Verified safe — the load-bearing negative results

Recorded deliberately, because these are what make the peg and the venue defensible.

**Peg and backing.** No unbacked-mint path exists: `mint` charges `asset.safeTransferFrom` before
crediting `outstanding`, `totalPooledSupply` and `token.mint`, all with the same `amount` in the
same transaction. `PooledBrandToken.mint`/`burn` are `onlyPool` and `pool` is written once in
`initialize` with no setter anywhere in the file. `_registerBrand` always deploys a fresh
`BeaconProxy` passing `pool = address(this)`, so an attacker cannot register an attacker-controlled
ERC20 as a brand. The invariant `totalPooledSupply == Σ outstanding == Σ totalSupply()` holds
across `mint`, `_redeem` and `swap`.

**No share-inflation surface.** Brand tokens are not shares — there is no pool-level share price,
no `convertToShares`, and 1 brand == 1 asset unit by construction, so the ERC-4626
first-depositor attack does not apply. All four manipulation routes were checked and none is
profitable: donating to the pool is booked as growth and distributed pro-rata, so a donor
recovers only their own share; repaying a Morpho borrow does not move `totalSupplyAssets` (it is
`balanceOf(morpho) + totalBorrowAssets`); donating to the Morpho singleton raises share value but
the donor gets no shares; and the `supply == 1` `mulDiv` blow-up is capped because `claimYield`
pays `min(owed, surplus)` and the attacker's `owed` equals exactly what they donated. The only
share math is Morpho's own, wrapped by `_toAssetsDown`, which mirrors `SharesMathLib` including
the `1e6`/`1` virtual offsets and is bounded at 1 unit per deposit, always against the depositor.

**Yield cannot reach principal or be redirected.** `claimYield` pays
`min(owed, assets - totalPooledSupply)` (`:466-470`), so a brand treasury cannot extract a single
wei of depositor principal and unpaid entitlement stays owed rather than being forgiven.
`claimYield` requires `msg.sender == brands[token].treasury`, an address the pool itself deployed.
`BrandFeeVault.harvest()` is permissionless but calls `treasury.claim(address(this))` with a
hard-coded receiver, and `sweep()` computes all three destinations from values written once at
initialisation with no setters — so the permissionless caller chooses only the moment.

**Redemption survives a full protocol pause.** `_redeem` carries no `whenNotPaused`,
`PooledBrandToken` does not inherit `GuardedUpgradeable` at all, and `MorphoBlueYieldSource` has
no pause mechanism. A guardian pausing the pool, the treasury beacon and the adapter still leaves
the holder's 1:1 exit fully functional.

**Upgrade surface, other than CRITICAL-1.** All ten beacons — five live and five orphaned — are
owned by the 48h timelock; `upgradeTo` from the EOA or a random address reverts
`OwnableUnauthorizedAccount`. The five orphaned implementations are **byte-identical** to their
live counterparts (`cast codehash` matches all five pairs), so the split-beacon issue is a
runbook trap and not stale bytecode, and all five are initializer-locked. Beacon *addresses* are
immutable after initialisation — `brandTokenBeacon`/`treasuryBeacon` and `factory.beacons` are
written only inside `initialize` with no setter in `src/` — so they cannot be repointed at a rogue
beacon even by the owner. `_authorizeUpgrade` is `onlyOwner` = timelock on the guard, pool and
yield source (EOA rejected by probe). No `transferOwnership`, `acceptOwnership` or
`renounceOwnership` call appears anywhere in `script/`.

**Initializers and storage.** Re-initialisation is blocked on all sixteen implementations and all
five proxies — every `initialize` returns `InvalidInitialization()` (`0xf92ee8a9`), and a direct
takeover probe against the guard implementation reverted on `initialize`, `pause`,
`setGuardian` and `upgradeToAndCall` (the last with `UUPSUnauthorizedCallContext`, confirming
`onlyProxy`). The five beacon implementations are not UUPS at all, so the "take over the impl,
then move the beacon" vector is closed twice over. No initialisation front-running window exists:
every `ERC1967Proxy` and `BeaconProxy` is constructed with its initializer calldata in the same
`new` expression. Both custom slots are correctly derived ERC-7201 —
`keccak256(abi.encode(uint256(keccak256("stables.storage.Guarded")) - 1)) & ~0xff` =
`0x0d34567d…385a400` and the `ReentrancyGuard` equivalent `0xf5000d51…3e00`, both recomputed
independently — with no collision against the ERC-1967 implementation/admin/beacon slots or OZ
5.7.0's namespaced `Initializable`, `OwnableUpgradeable` and `Ownable2StepUpgradeable` slots.
Proven empirically rather than by inspection: on the live guard proxy, slot 0 reads `0`
(`paused == false`) while `0xf0c57e…` reads `1` — had they shared a slot, `paused()` would read
`true` on a fresh proxy. All four guarded contracts return the same `guard()`. Every
constructor-to-initializer migration was checked field by field against the chain and nothing was
dropped; the adapter's `marketParams` are byte-identical to Morpho's own
`idToMarketParams(0xc845da…)`. All `__gap` arrays are present and intact.

**`ReentrancyGuardSlot` is correct.** SSTORE rolls back with the call frame, so a reverting
protected body leaves the flag at its pre-call value; zero-means-not-entered is handled explicitly
so it works behind a proxy with no init function; one slot per proxy storage blocks cross-function
reentrancy within a contract; cross-contract is not blocked, matching OZ, and the call graph was
traced to confirm it does not matter. The most likely way to break it is not broken:
`MarketRouter.seedLiquidity` and `BuybackEngine.execute` are `nonReentrant` and both round-trip
through `poolManager.unlock` → `unlockCallback`, so had the callbacks also been `nonReentrant`
every seed and buyback would deadlock on its own guard — all three callbacks were checked and
none is. No double-guard exists (`ReentrancyGuardUpgradeable` appears nowhere in `src/`), and
`MarketDeployer` is delegatecalled but declares no state variables, so it touches no factory
storage.

**Hook delta accounting is exact in both directions.** Exact-input: the hook returns
`toBeforeSwapDelta(+fee, 0)`, core sets `amountToSwap = amountSpecified + fee` so the pool and LP
fee see only the remainder, `afterSwap` maps the specified delta onto the input currency in all
four `zeroForOne`/sign combinations, and `swapDelta -= hookDelta` moves the fee onto the swapper,
whose settled obligation is `consumed + fee`. Exact-output: `beforeSwap` returns `ZERO_DELTA` so
the pool targets the full output, and `afterSwap` reads the unspecified currency, which is the
input side in both orientations — so flipping the swap type does not route around the skim.
Nobody can get a swap settled while owing the hook: `_accrue` mints ERC-6909 claims, which debits
the hook by `amount` while the returned delta credits it by the same, netting to zero, and it is
only reached when `feeAmount != 0`. The skim cannot exceed or flip the input — `MAX_FEE_PIPS =
50_000` (5%) is enforced at both write sites and read back from the live hook, so
`amountToSwap` can never cross zero and `HookDeltaExceedsSwapAmount` is unreachable. Zero-amount
and self-paired swaps are impossible (`SwapAmountCannotBeZero`, `CurrenciesOutOfOrderOrEqual`).
`flash` and `donate` cannot dodge the skim (neither calls the swap hooks; `donate` moves
`feeGrowthGlobal`, not `sqrtPriceX96` or `tick`), and `modifyLiquidity` is correctly not skimmed.
The dynamic-fee override is unreachable: `beforeSwap` returns `lpFeeOverride = 0`, consumed only
when `key.fee.isDynamicFee()` (`0x800000`), and `tickSpacingForFee` pins the set to
`{100, 500, 3000, 5000, 10000}`.

**`collect` is not abusable.** A spoofed `PoolKey` would need a second keccak preimage of
`abi.encode(key)`. Cross-pool drain is impossible: `pendingFees` is per `(PoolId, Currency)` while
the hook's ERC-6909 claims are per `Currency`, and the invariant `claims[c] == Σ_pools
pendingFees[pool][c]` is maintained by the only two writers, so pool A's `collect` can only burn
and take A's own accrual. The destination is read from storage, never taken as an argument, so
front-running only pays gas. `pendingFees` is zeroed *before* `poolManager.unlock`, so a
re-entrant `collect` returns `(0,0)` and a nested unlock hits `AlreadyUnlocked` — it needs no
`nonReentrant`. `registerPool` is genuinely one-shot (`AlreadyRegistered`) with no setter for
`feeRecipientOf` anywhere in the file, is registrar-gated, and the live `registrar()` is the
factory, so a front-runner cannot bind a pool's skim to themselves. Unregistered pools are inert
rather than confiscatory: `feePipsFor` returns 0, `_writeObservation` returns on
`cardinality == 0`, `collect` reverts `NotRegistered`. `_haltedSafely` is a `staticcall` that
treats any failure as "not halted" and validates `ret.length == 32`, so a broken registry stops
the skim without taking the venue offline — while `collect` reverts on halt, correctly, because it
moves money off the swap path. `guard` and `poolManager` have no setters.

**The mined hook address carries exactly the declared permissions.** This pinned v4-core uses a
*reversed* bit order from canonical Uniswap (`BEFORE_SWAP_FLAG = 1 << 7`, `AFTER_SWAP_FLAG =
1 << 6`, `BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3`, `AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2`), and
`0x082c…C0CC & 0x3FFF = 0x00CC = 0x80|0x40|0x08|0x04` matches `getHookPermissions()` bit for bit
across all fourteen flags. The deployed PoolManager's ABI was diffed against the pinned v4-core
build by walking the live bytecode for PUSH4s: 32 of 33 method identifiers match, the sole
exception being `balanceOf(address,uint256)`, which nothing in scope calls — including the newer
`SwapParams`-struct `swap` form the router uses. `getSlot0`/`getLiquidity` are *not* present and a
naive `cast call` reverts with empty data; that is expected, because this v4-core's `StateLibrary`
reads via `manager.extsload(stateSlot)` and `extsload(bytes32)` **is** present, so all four call
sites resolve.

**A broken hook cannot affect other projects' pools.** Other pools carry different hook addresses,
so `Hooks.beforeSwap`/`afterSwap` are never invoked with this contract as `self`; `setProtocolFee`
is PoolManager-`onlyOwner` and `updateDynamicLPFee` requires `msg.sender == key.hooks` plus a
dynamic-fee key. Both deployed implementations were walked at opcode level (not byte-searched,
which false-positives on mask constants) and contain **no `SELFDESTRUCT`**, exactly one
`DELEGATECALL` each (OZ's `functionDelegateCall` inside `upgradeToAndCall`) and no `CALLCODE`.

**The oracle is sound.** `_writeObservation` runs first in `beforeSwap`, above the fee logic's
early returns, and reads `getSlot0` before core mutates it — V3's `slot0Start.tick` semantics, the
only place they exist in a v4 hook. `PoolManager.swap` calls `checkPoolInitialized()` before
`beforeSwap`, so `slot0` is always live. `write` no-ops when `elapsed < MIN_INTERVAL`, so a
spike-and-revert inside one interval plants nothing: **a same-block manipulation is worth exactly
zero.** A spike held across blocks still earns `(k − 15)/1800` of the move, which saturating the
200 bps band requires a ~4× spot move held ~51 s — an open inventory position, bounded by the
band, and worst in exactly the thin quiet markets this product targets, as the engine's own
docstring prices. The cheaper attack is grief rather than profit: holding a pump raises the TWAP
floor above the unwound spot so later rounds revert instead of overpaying, blocking a market's
buyback for up to ~30 min per manipulation, with funds staying in the engine and the interval not
consumed. `observe` cannot be spoofed or cross-wired (both endpoints derive from the same
`key.toId()`, and it reverts `NotInitialized` rather than fabricating a zero); observations are
writable only by a real swap on that pool; `increaseObservationCardinalityNext` only grows and
cannot overwrite real history. The V3 port is faithful where it matters — `lte`'s 2^32 epoch
adjustment, `binarySearch`'s bounds and uninitialised-slot skip, `getSurroundingObservations`'s
`self[0]` fallback, `transform`'s wrapping accumulator — the `int56` range was checked
(|tick| ≤ 8388607 and delta ≤ 2^32−1 gives ≤ 36,028,792,724,226,065, just inside max, and it is
`unchecked` by design), and dropping `secondsPerLiquidityCumulativeX128` is safe because the three
consumers compare timestamps only. Per-pool array bases are `keccak256(id ‖ slot)`, so collision
is ~2^-191. `consultTick` *is* the unsafe reader — its window ends at `now`, crediting up to
`MIN_INTERVAL` of an in-transaction spike — and **nothing safety-critical calls it**:
`BuybackEngine.twapSqrtPriceX96` uses `observe(poolKey(), [twapWindow + lag, lag])` with both
endpoints at least `MIN_INTERVAL` in the past, and grep confirms `consultTick` has no caller in
`src/`. `cardinalityForWindow` sizes for `window + MIN_INTERVAL`, giving 122 slots for the live
`twapWindow = 1800`.

**Router.** All four entry points are `nonReentrant`; `unlockCallback` is gated on
`msg.sender == address(poolManager)` and the PoolManager only calls it on the address that opened
the unlock, so a malicious token cannot forge it. Partial fills roll forward rather than to the
pool: `unlockCallback` settles from the returned delta, never from `amountIn`, and pays only
`uint256(-inputDelta)` — the correct handling of the pattern the prior HIGH-1 flagged. No standing
approvals: both `forceApprove` sites approve exactly the amount consumed in the same call. The
unlimited non-expiring Permit2 allowance cannot be turned against the router, because Permit2 only
pulls when `msg.sender == spender` (only PositionManager) and PositionManager's `_settlePair` pays
from `msgSender()` = `_getLocker()` = the original caller of `modifyLiquidities` — an attacker
calling it is their own payer, and the router is the payer only inside its own `nonReentrant`
`seedLiquidity`. A stale router balance (L-2) cannot be siphoned this way either, since
`_settlePair` settles `_getFullDebt`, bounded by `amount0Max`/`amount1Max` set to exactly what
this caller brought. `nextTokenId` is read immediately before `modifyLiquidities` with no
intervening external call. `_mapRecipient` cannot divert the LP NFT — the router passes a concrete
`msg.sender`, returned unchanged unless it equals the `address(1)`/`address(2)` sentinels — so the
seeder gets their own NFT and the router never holds a position. There is no multicall, no owner
withdraw and no rescue, and with delta-based measurement everywhere a stale balance cannot corrupt
a later call's accounting.

**Buyback.** `execute()` takes no caller parameters and never transfers to `msg.sender` — every
transfer in it was enumerated (`usdg.forceApprove`→`mint`, `_settle`→poolManager, `take`→self,
`safeTransfer`→lockbox) — so it cannot leak value to its caller directly; what a caller chooses is
timing, and the round is fully public via `budget()` and `readyAt()`. The band is the loss bound:
the limit sits 200 bps of sqrt (~4.04% of price) from the TWAP and v4 fills only up to it, so the
worst a searcher extracts per round is roughly 4% of `spent` — a persistent drag, not a
catastrophic one. `sqrtPriceLimitX96` orientation and clamping are correct (floor for
`brandIsCurrency0`, ceiling otherwise, clamped to `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`,
with the floor-toward-negative-infinity correction on the mean tick present). The engine cannot be
re-entered: `execute` and `lockHeldAsset` are `nonReentrant`, `onYieldReceived` and
`lockHeldAsset` are `feeVault`-only, and both `unlockCallback`s are `poolManager`-only with
caller-encoded data no third party can inject. The pool cannot be rogue or poisoned — it is a
`PoolKey` inside the live singleton naming the mined hook, and `initialize` rejects a key whose
currencies are not exactly `(brand, asset)` in either order or which has no hook.

**Vault ledger.** Verified arithmetically: after the protocol and LP legs,
`usdgLeft + brandLeft == toBuyback` exactly, so `engine.onYieldReceived(usdg, toBuyback)` matches
what actually moved; rounding dust is routed to the buyback, favouring holders; and
`LpShareRolledToBuyback` correctly re-adds an undonatable LP leg rather than stranding it.

**Lockbox.** Bytecode clean against every exit considered: no owner, no `withdraw`, no `rescue`,
no `receive`/`fallback`, no `delegatecall`, no `selfdestruct`. The only state-changing function is
`lock`, gated on an `engine` address written once in `initialize`; it is deliberately not pausable;
the operator holds no reference to it anywhere in the factory or vault; and the factory owner
cannot reach an existing lockbox because `BeaconProxy._beacon` is `immutable` and
`UpgradeableBeacon.upgradeTo` is timelock-only. See MEDIUM-5 in section 6 for what "locked"
actually guarantees.

**Reserve accounting.** `_redeem`'s haircut path is internally consistent: a haircut retires
`amount` of liability while removing only `payout` of assets, growing surplus by exactly
`haircut`, and `lossCarryforward -= min(lossCarryforward, haircut)` retires the matching loss so
surplus is not later double-counted as yield; `_accrueGlobal` symmetrically requires a loss to be
recovered before new yield is credited, and capital deposits do not erase the deficit. `swap`
cannot shift yield entitlement between brands — both `_settleBrand` calls run before either
`outstanding` changes, and a swap leaves `totalPooledSupply` and `totalAssets()` unchanged, so the
comment justifying the absent re-sync is correct. Unbounded permissionless brand registration does
not DoS the reserve: it accrues through one global index and never iterates `allBrandTokens` on a
state-changing path. `quoteSqrtPriceX96` is safe — `mulDiv` at 512-bit intermediate, one
`Math.sqrt`, bounds-checked before the `uint160` cast, with the decimal asymmetry handled by
squaring ratio and scale together. No reentrancy guards exist in `src/pool` or `src/yield`, and
none are needed today because USDG has no transfer callbacks and the adapter is trusted, with
correct CEI discipline throughout (burn-before-transfer at `:388`, counters updated before
`_recallIfNeeded`) — worth stating as an assumption rather than a property.

**Adapter.** `withdraw` reads `sharesOf[msg.sender]`, returns 0 immediately if it is 0, and debits
the ledger before the external call, so an outsider with no deposits moves nothing and two
consumers sharing one instance stay isolated (corroborated by
`test/audit/YieldSourceDrain.t.sol`). `PooledBrandToken.mint` is `onlyPool` and the pool mints in
exactly two places, both after charging, and `PoolBrandTreasury` holds no reference to `mint` at
all — **the mint authority does not leak**. The residual is the beacon itself, which is
timelock-owned: a beacon upgrade could install an implementation with an open minter. That is the
design's fundamental trust assumption, correctly timelocked, not a code defect.

## 6. Risks that are not code defects

**MEDIUM-5 — "locked forever" is really "48 hours' public notice that one EOA can start."** The
lockbox bytecode is clean and the only extraction path is a beacon upgrade, but
`hasRole(PROPOSER_ROLE, 0xeA6A…) == true` **and** `hasRole(EXECUTOR_ROLE, 0xeA6A…) == true`. One
key proposes and executes with 48h between. Any surface claiming assets are locked forever is
overstated — on two counts, the second being that the buyback is not fee-funded at all.

**MEDIUM-6 — USDG's issuer can pause or freeze the reserve asset.** Probing
`0x5fc5360D…d168` on chain: it is an ERC1967 proxy (impl `0x68184c44…`) exposing `paused()`
(currently `false`), `isFrozen(address)` (currently `false` for the pool) and a role-gated
`pause()`. If the issuer pauses or freezes, `redeem` stops working no matter how correct this code
is — and the unpausable-redemption design does not help, because the block is in the token, not
the pool. This is the dominant centralization risk in the system and it is invisible from
`src/`; it appears in none of the three audit documents.

**The split beacon set is a runbook trap, not a privilege exposure.** Step 2 calls
`ProtocolStack.deployBeacons` a second time instead of adopting step 1's, so the live set is split:
the pool uses step 1's brandToken and treasury beacons, the factory uses step 2's vault, engine
and lockbox beacons. Confirmed by reading `pool.brandTokenBeacon()`, `pool.treasuryBeacon()` and
`factory.beacons()` off chain. All ten beacons are timelock-owned and the five orphaned
implementations are byte-identical to their live counterparts, so there is no non-timelock upgrade
path. The real risk is a **silent no-op fix on the most urgent path in the system**:
`upgradeTo` on an orphan succeeds for the timelock, emits `Upgraded`, and changes no market. An
incident responder who upgrades step 1's vault beacon `0x65e0…340d` instead of the live
`0x4c99…710A` gets a clean transaction and zero patched vaults while believing every market is
fixed, with no on-chain signal distinguishing the two. `deployBeacons` should not silently mint a
second equally valid set — split it into `deployBeacons` (step 1) and `adoptBeacons` (step 2), or
have step 2 read the pool's two and take the other three as inputs. Already deployed and cannot be
un-split, so the live remediation is runbook-only.

**The buyback cannot fire at current funding.** The deployer holds 304,847,650 base units =
$304.85 USDG. `test_fork_realWallet_floatIsFarTooSmallToEverBuyBack` passes and measures it
directly: $229.34 of float earns $10.97 of Morpho yield across four markets in a year, against a
`minNotional` of $100 per round and a minimum interval of 6h. Since only float yield funds the
buyback, roughly $2,000+ of float is needed for a single $100 round per year. A decision, not a
patch: fund the wallet or lower `minNotional`.

**Morpho utilization.** 90.08% at preflight, 90.12% at audit time (`totalSupplyAssets`
315,041,382 vs `totalBorrowAssets` 283,914,421), with 46.6M USDG idle in the singleton. See
MEDIUM-2.

## 7. Recommended order of work

Before opening any market:

1. **CRITICAL-1** — `transferOwnership(timelock)` on the hook, factory and router (simulated,
   returns `0x`), then `acceptOwnership` from the timelock after 48h. Then fix `ProtocolStack`
   and `VerifyAssetMarketsMainnet` so the check is enforced rather than printed, and make it
   7702-aware.
2. **HIGH-2** — cap `amountIn` against `marketLiquidity` and/or reject `minAssetOut == 0`. This
   bites on the first large trade in a thin market, which is the launch condition.
3. **MEDIUM-3** — decide the first market's price band and be aware the first brand address is
   computable today. Do not respond to a squat by widening the band or passing
   `assetPriceE18 = 0`.
4. **MEDIUM-1** — try/catch the LP-donation mint and roll to the buyback on failure.
5. **HIGH-1** — override `renounceOwnership()` in `ProtocolGuard`.
6. **MEDIUM-4** — add `whenNotPaused` to `createMarket`/`registerBrand`/`openMarket`, or stop
   claiming the pause covers them.

Then, before scaling: MEDIUM-2 (idle buffer), MEDIUM-5 and MEDIUM-6 (governance and USDG issuer
risk — both need a multisig and a documented position, not code), L-1 (`setBrandOperator`), and
the documentation defects in section 5, which are cheap and will otherwise cost the next reader a
wrong mental model of where the money goes.

Test-coverage gaps that let CRITICAL-1 ship: no test asserts the hook, factory or router proxies
are timelock-owned (`test_everyBeaconIsOwnedByTheTimelock` covers beacons only, and passes);
`test_implementationsCannotBeInitialised` covers only `SharedReservePool`; nothing asserts that
after `pause()` some caller can still `unpause()`; `ReentrancyGuardSlot` has no dedicated unit
test; and `test/helpers/StackFixture.sol:56-57` calls `deployGuard` and `deployBeacons` once each,
so no test ever reproduces the split-beacon state.

## 8. How this audit was performed

Four independent reviews over disjoint file sets — the `src/upgrade/` privilege layer; the pooled
1:1 and yield surface; the market lifecycle and buyback; the v4 hook, router and oracle — plus a
separate pass over the live governance state. Roughly 150 read-only `cast call` / `cast storage` /
`cast codehash` / `cast code` queries against chain 4663. Authorization claims were proven by
simulated `eth_call` with `--from` spoofing rather than inferred from source, and the remediation
for CRITICAL-1 was simulated before being recommended. ERC-7201 slots were recomputed from first
principles and OZ 5.7.0's slot constants were read out of `lib/` rather than from memory. The v4
analysis is against the pinned `lib/v4-core` and the in-tree `lib/v4-periphery` fork, with the
live PoolManager's ABI diffed against a local build by walking its bytecode for PUSH4s.

`forge test` against a fork pinned at block 59479303: **280 passed, 9 failed** across 23 suites,
18 suites fully green. All nine failures are stale assertions in the fork suites that still expect
the trading skim to land in the market's `BrandFeeVault`; the offline suites already encode the
current design and pass (`AssetMarketFactory.t.sol:359-360` asserts
`feeRecipientOf(id) == protocolTreasury` **and** `!= feeVault`). The one that looks worst —
`test_fork_funded_fullFlowThroughBuybackAndLockbox`'s arithmetic underflow — was traced to
completion: every contract frame returns cleanly (`Swept(toBuyback: 2092540837, toProtocol: 0,
toLps: 2092540836)`, `BuybackEngine::onYieldReceived` returns), and the revert is in the test's
own arithmetic at the top level after reading `usdg.balanceOf(protocolTreasury)`, which is
legitimately 0 because the skim now arrives as brand tokens and the asset, not USDG. **No contract
defect is implicated by any of the nine.**

Two things this audit could not settle. The 7702 delegate `0x63c0c19a282a1b52b07dd5a65b58948a07dae32b`
(11,185 bytes) is unidentified — it answers `VERSION() → "1.3.0"` but every storage-reading
selector reverts and the EOA's own storage is all-zero, so it is not a functioning Safe. And the
deployed `PositionManager` is not built from this repo: `lib/v4-periphery` is an in-tree fork on
branch `js/upgradeable-stack` carrying actions upstream lacks (`UNWIND_WITH_FALLBACK`,
`SUBSCRIBE`, `UNSUBSCRIBE`). Its observable ABI was verified and the `MintParams` encoding matches
`CalldataDecoder` word for word, but a mint could not be executed end to end because
`marketCount() == 0`. **One dust `seedLiquidity` after the first market exists retires that item**
— confirm the `UNI-V4-POSM` NFT lands on the caller and both refunds arrive.

No files were modified by the four reviews and no state-changing command was run. All on-chain
interaction was read-only.
