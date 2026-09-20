# Audit history: internal review record

**This is a record of internal review, not an external audit.** Nobody outside the team has
looked at this code. Three internal passes were written between 2026-09-09 and 2026-09-10 as
separate documents; this file consolidates them and replaces all three.

**The architecture those passes described has been replaced twice since.** They were written
against a generation built from `MarketYieldSplitter`, `BuybackEngine`, `AssetLockbox`,
`SplitterDeployer`, `LpRewardEscrow` and a Uniswap v3 periphery. None of those contracts exist
in `src/` any more, and the names appear below only to say what a finding was about and why it
no longer applies. The live generation is gen-6: Uniswap v4, one market per brand, a fee vault
that splits to a staking distributor, and no buyback at all.

Findings are carried forward rather than deleted because an auditor needs the trail: what was
looked at, what was decided, and what was knowingly left open. Every verdict below was
re-checked against current `src/` on 2026-09-20, and each cites the `path:line` that was read on
that date. Line numbers move whenever the file above them is edited; treat them as a pointer to
a named function or field, not as a hash.

Verdicts:

- **FIXED**: the defect is gone and the code that closed it is cited.
- **RESOLVED**: closed after the passes were written, by a change made for that reason. Same
  meaning as FIXED; kept separate only so the September 2026 changes are legible as a group.
- **OPEN**: reproducible in current `src/` today.
- **OBSOLETE**: the contract or code path the finding was about no longer exists.

Original documents, all now deleted: `docs/ASSET_MARKETS_AUDIT.md` (2026-09-08, the reserve and
router review, prefix **AM**), `ASSET_MARKETS_AUDIT.md` (2026-09-09, first pass, prefix **A1**),
`ASSET_MARKETS_AUDIT_MULTILEG.md` (2026-09-09, multi-leg and buyback surface, prefix **A2**),
`ASSET_MARKETS_AUDIT_UPGRADEABLE.md` (2026-09-10, the upgradeable stack, prefix **A3**). The
four root-level copies were removed on 2026-09-20 once everything in them was either already
carried here or established as describing contracts that no longer exist. A3-MEDIUM-6 below is
the one finding that had to be carried across in that pass rather than being here already.

**The SR series is not here.** `docs/SECURITY_AUDIT_2026-09-10.md` is kept as a separate dated
record because it is the only document carrying SR-01 to SR-08, and it holds its own re-check
table. Where the two overlap — SR-04 is AM-08, SR-03 is the hook's fee surface — that document
defers to this one for the current verdict. Nothing is listed as open in both with different
answers.

---

## Still open

These are the findings an auditor should start from. Each was reproduced in current `src/`.

### A3-MEDIUM-6: USDG's issuer can pause or freeze the reserve asset out from under us

**Carried forward on 2026-09-20 from `ASSET_MARKETS_AUDIT_UPGRADEABLE.md:697`, which has since
been deleted. It is recorded nowhere else, and it is the largest single centralization risk in
the system.** It is also invisible from `src/`, which is why it keeps getting lost: nothing in
this repository references the mechanism, because the mechanism is not ours.

USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` is an ERC-1967 proxy over implementation
`0x68184c449e1a8f34fa18d289737129fd27b66f8f`. It exposes `paused()`, false at the time of
reading, and `isFrozen(address)`, false for the sUSDai reserve
`0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2`. `pause()` is role-gated on the issuer. We hold
none of those roles and cannot obtain them.

If the issuer pauses the token or freezes the reserve's address, `redeem` stops working, and no
property of our code changes that. The reserve's redemption path is deliberately not behind the
protocol pause — `SharedReservePool.redeem` is not `whenNotPaused`, precisely so that a halt
cannot trap holders — and that design buys nothing here, because the block lives in the asset
contract rather than in the pool. Every brand dollar is a claim on a token whose transferability
is a third party's discretionary decision.

There is no fix inside this repository. The honest mitigations are all off-chain: disclose it,
watch `paused()` and `isFrozen()` on the live reserves, and do not describe a brand dollar as
redeemable without naming the dependency. Recorded as **OPEN** and outside our control.

### AM-08: a late brand is credited with interest earned before it existed

`MorphoBlueYieldSource.balanceOf` converts the consumer's shares using the market totals as
they are *stored* (`src/yield/MorphoBlueYieldSource.sol:208-213`), with no interest accrual
first. `withdrawable` (`:231-240`) and `totalAssets` (`:244-253`) read the same stored totals.
`SharedReservePool.mint` checkpoints against that stale valuation in `_settleBrand` before it
raises `totalPooledSupply` (`src/pool/SharedReservePool.sol:448-451`), so interest that Morpho
had earned but not yet booked is apportioned afterwards across the larger supply, including the
brand that just arrived.

Measured on a mainnet fork at the time of the original review: after 180 days without a call to
Morpho's permissionless `accrueInterest`, a brand minting 100,000 USDG showed zero pending
yield at mint and 3,093.053005 USDG immediately after the accrual was triggered, with no time
elapsed since its deposit. **Still open.** The fix that was asked for, a fresh underlying
valuation before every entitlement or supply checkpoint, is not present, and the reproduction
lives at `test/markets/MorphoAttributionFork.t.sol`. Accruing during `deployIdle` is too late,
because the checkpoint has already happened by then. Adapter withdrawal sizing reads the same
stored totals and belongs in the same change.

This is misattribution between brands, not a path to unbacked value: total backing is
unchanged, and every brand's claim still pays only out of surplus above pooled supply.

### AM-07: a codehash match is not issuer-authorised provenance

`isCanonicalEquity` compares the asset's bytecode (`src/markets/AssetMarketFactory.sol:1162`)
and the result is stored on the market as `verified` (`:997`, field at `:336`). Matching
bytecode says the contract behaves like a genuine Robinhood equity token; it says nothing about
who deployed it or authorised the market. Same substance as A3-L-5 and A1-LOW-6 below, recorded
separately because it was raised first and because it is a UI contract as much as a contract
one: the badge must read as a statement about the underlying asset's bytecode, never as an
endorsement of the market, its brand, its liquidity or its operator.

### A3-CRITICAL-1 (custody half resolved): no upgrade timelock anywhere in the stack

Originally: three of six UUPS proxies were owned by the deployer EOA rather than the 48h
timelock, and gen-6 widened that to an `ownedByTheDeployerEoa` list covering both reserve
pools, both yield adapters, the guard, all eight beacons, the market factory, the router and
the launchpad, with the same address also serving as guardian and protocol treasury.

**The single-key part is resolved as of 2026-09-20.** Custody migrated to a Gnosis Safe
v1.4.1, 2-of-3, at `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, in two phases: twelve
`Ownable2Step` handles accepted first, then the four beacons, which are irreversible and were
deliberately gated on the Safe having already accepted a phase-1 handle as proof its signers
work. Sixteen of sixteen handles are Safe-owned with no nomination outstanding. The deployer
EOA `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` is no longer an owner, no longer the
guardian, and no longer the protocol treasury. The guardian is now a separate pause-only key,
`0xc1d844d6478e450E62293882d2d6739c4a8693F9`, which can halt but cannot resume.

**The no-timelock part is still open and was accepted deliberately.** Every `_authorizeUpgrade`
in the stack remains a bare `onlyOwner` with no delay, so an upgrade lands in the transaction
that proposes it: `src/upgrade/ProtocolGuard.sol:151`, `src/pool/SharedReservePool.sol:303`,
`src/markets/AssetMarketFactory.sol:542`, `src/markets/MarketRouter.sol:237`,
`src/markets/ProtocolFeeHook.sol:300`, `src/yield/MorphoBlueYieldSource.sol:151`,
`src/yield/SUSDaiYieldSource.sol:292`, `src/launchpad/LaunchFactory.sol:400`,
`src/registry/StrategyGroupRegistry.sol:133`, `src/susdai/SUSDaiHub.sol:222`. What changed is
that proposing it now takes two of three signers instead of one hot key. See `UPGRADING.md`.

**What the September parameter delays do and do not buy.** Two fee surfaces gained a one-hour
announced delay on INCREASES: `ProtocolFeeHook.FEE_INCREASE_DELAY`
(`src/markets/ProtocolFeeHook.sol:153`) and `SharedReservePool.FEE_INCREASE_DELAY`
(`src/pool/SharedReservePool.sol:183`). Decreases are immediate and cancel a pending increase,
and the ceiling is re-checked at commit. That is a reliability guarantee for a quote in flight,
not a mitigation for this finding: the same owner can upgrade either contract in one
transaction and remove the delay along with anything else. Do not read the delay as a timelock.

Residual, and tracked separately: six un-graduated `LaunchCurve`s have `protocolFeeRecipient`
frozen in storage with no setter, still pointing at the retired deployer EOA, so that key
cannot be destroyed until they graduate.

### A3-MEDIUM-1: `sweep()` reverts wholesale when the yield source cannot take a deposit

`src/markets/BrandFeeVault.sol:254`. The LP leg is paid in brandUSD, and harvested income
arrives as USDG, so the normal path mints through the reserve at
`src/markets/BrandFeeVault.sol:286-287`. `SharedReservePool.mint` is `whenNotPaused` and calls
`_deployIdle()`, which calls `yieldSource.deposit`. If the adapter cannot accept, the whole
sweep reverts: the protocol's cut goes unpaid and the LP reward is not delivered, for every
market at once. A Morpho market at its supply cap, or the window after `setYieldSource`
recalls and leaves the position idle, is enough to trigger it.

### A3-MEDIUM-2: no idle buffer in the reserve, so redemption liveness depends on the adapter

`src/pool/SharedReservePool.sol:662-666`. `_deployIdle` moves **every** idle unit into the yield
source; there is no `minIdle` or reserve-ratio parameter anywhere in the file. `mint` calls it
inline, so the standing idle balance is approximately zero and every redemption has to cross
`_recallIfNeeded` into the adapter. Morpho Blue reverts rather than underpaying when the
singleton is short, so this is a liveness failure and not a haircut. Severity scales with AUM.

### A3-MEDIUM-4: market creation and brand registration sit outside the global pause

`AssetMarketFactory` inherits `GuardedUpgradeable` (`src/markets/AssetMarketFactory.sol:93`) and
initialises it (`:515`), and then uses `whenNotPaused` nowhere. `createMarket` (`:711`),
`registerBrand` (`:612`) and `createMarketForBrand` (`:775`) all run during a global halt, as do
both `SharedReservePool.registerBrand` overloads (`src/pool/SharedReservePool.sol:329`, `:360`).

`ProtocolGuard`'s own note says a single `pause()` halts every guarded contract at once
(`src/upgrade/ProtocolGuard.sol:14-19`), which an incident responder would reasonably believe.
Traced for value movement and there is none: creation takes no deposit, a fresh brand
checkpoints at the current yield index, and the factory hands the new market the same guard it
holds. It is an incident-response gap, not a theft.

### A3-L-1 / A2-MEDIUM-1: `brandOperatorOf` is write-once with no setter

`src/markets/AssetMarketFactory.sol:688` is the only write. There is no `setBrandOperator`
anywhere in the file. An issuer who registers a brand against a wrong or lost operator address
can never open a market for it, and the brand's treasury admin sits with the factory. The only
escape is the owner, who is accepted in place of the operator at
`src/markets/AssetMarketFactory.sol:786`, which is an escape hatch held by the same key as
A3-CRITICAL-1, not a repair path an issuer can use.

The half of A2-MEDIUM-1 about `MarketYieldSplitter.brandOperator` diverging is obsolete; the
splitter is gone.

### A3-MEDIUM-3 / A2-MEDIUM-2: a squatted pool key permanently blocks that market

`src/markets/AssetMarketFactory.sol:1035-1042`. `_ensurePool` now reverts
`PoolAlreadyInitialised` on any pre-initialised key (`:1042`), which closes the theft half of
this finding (the factory can no longer adopt an attacker's price, and there is no
`assetPriceE18 == 0` opt-in left). The grief half survives: brand tokens are `CREATE`d by the
reserve pool, so their
addresses are predictable, `PoolManager.initialize` is permissionless and cheap, and the factory
pins a small set of fee tiers. Pre-initialising the key for a future brand blocks that
`(brand, asset, fee)` market forever. The remedy is a different fee tier, which is a different
key.

### A3-L-2: `receiver == address(router)` silently strands swap output

`src/markets/MarketRouter.sol:646` guards the payout with `if (receiver != address(this))`, and
the entry points check `receiver` only against zero (`:295`, `:334`, `:384`, `:439`). The router
has no sweep, rescue or recover. Self-harm rather than theft, and unreachable by anyone else,
but the ABI invites the mistake and the loss is silent.

### A3-L-4: neither the hook nor the router declares a `__gap`

`AssetMarketFactory` (`:394`), `BrandFeeVault` (`:143`), `LpRewardDistributor` (`:178`),
`SharedReservePool` (`:164`), `PooledBrandToken` (`:99`), `PoolBrandTreasury` (`:122`) and
`ProtocolGuard` (`:55`) all reserve one. `ProtocolFeeHook` and `MarketRouter` do not; the hook's
own storage runs to `src/markets/ProtocolFeeHook.sol:222` and simply stops.

The router can survive a layout mistake by being redeployed. **The hook cannot.** Its address is
mined so that its low 14 bits are the permission flags, and `PoolKey.hooks` is part of every
pool's identity, so the proxy address can never move. A variable inserted anywhere but the end
relocates the per-pool oracle ring buffers and the accrued-fee ledger under a live proxy.

**Still open, but the hazard has now been navigated once in anger and the reasoning is written
down in the contract.** The September fee-delay upgrade added `pendingFeePipsOf` and
`feePipsEffectiveAt` to the hook, and appended them after every pre-existing field; the NatSpec
at `src/markets/ProtocolFeeHook.sol:216-221` records that appending is safe here specifically
because the contract is a leaf that nothing inherits from, which is why no gap was ever
reserved. That is a convention, not a compiler-enforced constraint, so the finding stands: an
upgrade that inserts rather than appends is still unrecoverable.

### A3-L-5 / A1-LOW-6: permissionless binding, and `verified` is a property of the asset

`src/markets/AssetMarketFactory.sol:567-577`: `_validateListing` checks the asset for a nonzero
address, code, a valid fee tier, non-empty unit metadata and a nonzero price. Nothing checks
brand name or symbol uniqueness. `verified` is computed by `isCanonicalEquity(asset)` at
`src/markets/AssetMarketFactory.sol:997` and then stored on the **market** (`:336`), so anyone
can point a market at a genuine Robinhood equity and earn `verified: true` on a brand, price and
liquidity profile of their choosing.

Inherent to permissionless listing rather than a code defect, but it is a UI contract: the badge
must read as "the underlying asset is the genuine token" and never as an endorsement of the
market.

### A3-L-6: `_validateListing` does not reject the reserve underlying as the asset

`src/markets/AssetMarketFactory.sol:567-577`. A market whose asset is USDG itself, or another
market's brand token, is accepted. Both legs stay backed and the mint is 1:1, so there is no
extraction; the result is a degenerate market that the vault's own accounting treats as
interchangeable with its reserve leg.

### A3-L-7: `deployIdle()` omits `_syncAccrualBaseline()`

`src/pool/SharedReservePool.sol:655-657` calls `_deployIdle()` and returns, against the rule
`mint` follows and `_deployIdle`'s own comment states (`:659-661`). Each rounding loss leaves
`totalAssets()` a unit below `lastAccrualAssets`, which the next accrual books as
`lossCarryforward` and suppresses yield credit by that much. Not profitably exploitable: each
unit costs a donation plus a transaction, because `_deployIdle` returns early on zero idle.

### A3-L-9 (partial): `PoolBrandTreasury.setAdmin` is single-step

`src/pool/PoolBrandTreasury.sol:112`. A typo orphans that brand's entire yield stream, because
`claim` is admin-only. The `PooledBrandToken` half of this finding is fixed (see below).

### A3-L-11: `MarketDeployer` is a permissionless external library

`src/markets/MarketDeployer.sol:71-72`: `deploy` is `external`, so anyone may `DELEGATECALL` the
live library. `BrandFeeVault.initialize` takes `_factory` as an argument rather than reading
`msg.sender` (`src/markets/BrandFeeVault.sol:172`, and the NatSpec at `:162-164` explains why it
has to), so a direct caller supplies its own factory.

Traced and contained: a counterfeit vault cannot reach real funds, because payouts route through
`PoolBrandTreasury.claim`, which is admin-only, and a counterfeit cannot become any real
treasury's admin. It is counterfeit surface, not theft. The consequence is for indexers: anything
that discovers markets by scanning beacon deployments or `Swept` events rather than
`AssetMarketFactory.market(id)` will report markets that do not exist.

### A3-L-12: unchecked external call into an attacker-supplied asset mid-creation

`src/markets/AssetMarketFactory.sol:1044` calls `quoteSqrtPriceX96`, which reads
`IERC20Metadata(asset).decimals()` at `:1134-1135`, from inside `_ensurePool`, after the brand
and treasury registry writes and before the market is recorded. All the reentrancy routes were
traced in the original pass and none pays out; it remains an unnecessary arbitrary-code point in
the middle of a state transition. Reading both `decimals()` in `_validateListing`, before any
registry write, would remove it.

### A3-L-13 (partial): `sweepStrayAsset` calls an arbitrary asset with no reentrancy guard

`src/markets/BrandFeeVault.sol:315`. The `forwardAsset` half of this finding is obsolete; that
function no longer exists. What remains transfers an arbitrary market asset with no
`nonReentrant`. Every destination is written once at initialisation and none is caller-supplied,
so no value can be redirected: a transfer hook can only misstate `totalStrayAssetRecovered`.

### A3-INFORMATIONAL: per-market initializers have no `msg.sender` gate

`src/markets/BrandFeeVault.sol:165-174` is `external initializer` with no caller check, and the
other beacon-backed contracts follow the same shape. Safe today only because every legitimate
instance is initialised inside its own `BeaconProxy` constructor and every implementation
disables initializers. The forward hazard is the next beacon upgrade: OpenZeppelin gives
initializers no access control, so an implementation that adds a `reinitializer(n)` without an
explicit caller check is callable by anyone on every live instance at once. `setEngine`'s
one-shot-plus-`onlyFactory` shape is the pattern to copy.

A beacon upgrade also validates nothing beyond `newImplementation.code.length > 0`. Unlike UUPS,
there is no `proxiableUUID` check and no layout validation, so one wrong argument rewrites every
brand token, treasury, vault and distributor simultaneously with no revert to catch it. Accepted
explicitly at `src/upgrade/ProtocolStack.sol:48-52`; the only defence is off-chain review.

### A1-LOW-4: `marketsOfAsset` is unbounded and permissionlessly grown

`src/markets/AssetMarketFactory.sol:1291` returns the whole array;
`_marketsOfAsset[asset].push` at `:1004` is reached by any `createMarket`. There is still no
paginated getter, only `marketsOfAssetLength` (`:1295`). Costs the attacker a full market
creation per entry and degrades only a view.

### A1-LOW-3 (partial): no rescue path on the router

The vault half is fixed (`sweepStrayAsset`, `src/markets/BrandFeeVault.sol:315`). The router
still has no sweep of any kind, which is what makes A3-L-2 above silent rather than recoverable.

---

## Resolved by the September 2026 changes

Findings that were open when the passes were written and are now closed by a specific change,
kept at full length rather than compressed into the table below because what moved is
economically interesting and an integrator reading old material needs the whole story.

### A3-HIGH-2: the trading skim is levied on the requested input, not the filled input

**Resolved 2026-09-19 by the change this finding asked for.** The entire fee now accrues in
`afterSwap`, computed from the `BalanceDelta` the pool actually produced, so a partial fill is
charged on the fill and nothing else. `beforeSwap` returns `ZERO_DELTA` unconditionally and
charges nothing; it survives only to write the oracle observation.

Originally: `beforeSwap` could not know the fill, so it computed the fee from the gross
request. The router deliberately sets the price limit to the extreme so a liquidity-exhausted
pool produces a partial fill instead of a revert (`src/markets/MarketRouter.sol:590-596`). The
unspent input was refunded, but the fee on the unfilled portion was not, so a trader who asked
for more than a thin pool could absorb paid `filled + fee(requested)`, which on a 10% fill is a
10x effective rate. The mitigation at the time was passing a real `minAssetOut`, which the
caller had to choose.

Note the side effect, because it is an economic change and not a refactor: the fee is now taken
off the swap's UNSPECIFIED leg, which on an exact-input swap is the OUTPUT. The pool therefore
sees the whole input and LPs earn their fee on all of it, where previously the skim came off
the top and diluted them.

### SR-03's residue: the skim's ceiling and how fast it can move

`docs/SECURITY_AUDIT_2026-09-10.md` recorded SR-03 as fixed in source on 2026-09-10 when the
hook-wide `defaultFeePips` fallback was deleted, but the finding text left two numbers standing
that an integrator would have read as current and that have both since moved. Recorded here so
the two documents do not disagree:

- `MAX_FEE_PIPS` is **10,000 pips = 1.00%**, not the 50,000 = 5% that finding quotes
  (`src/markets/ProtocolFeeHook.sol:140`). It was lowered deliberately to bound what governance
  can do to a quote, and `commitPoolFeePips` re-checks the ceiling at commit
  (`:449-452`) so a value authorised under the old ceiling cannot land under the new one.
- The rate is no longer instantly raisable. An INCREASE is announced `FEE_INCREASE_DELAY`
  (3,600 seconds) ahead through `setPoolFeePips` (`:407`) and applied by a permissionless
  `commitPoolFeePips` (`:441`); a DECREASE applies immediately and cancels any pending increase
  (`:411-422`). `SharedReservePool` gained the identical shape for `redemptionFeeBps`
  (`src/pool/SharedReservePool.sol:764`, `:794`).
- The owner in that finding text, the deployer EOA `0xeA6A…12A9`, is no longer the owner of
  anything. See A3-CRITICAL-1.

None of this is a timelock, and A3-CRITICAL-1 remains open: the same owner can upgrade the hook
in one transaction and remove both the ceiling and the delay. The delay bounds a quote in
flight, which is the reliability property an aggregator needs; it does not bound the owner.

---

## Structural constraints, unchanged and unchangeable

Not defects. They are properties of the deployed shape that no upgrade can alter, and an
integrator needs all four.

- **The hook's permission bits are permanent.** The proxy address is mined so its low 14 bits
  are `0x00CC`. Changing `getHookPermissions()` changes the required address and orphans every
  pool that names the old one. Consequence: the protocol's own LP fee donation is permanently
  undefendable against a sandwich, because the hook has no `beforeDonate`/`afterDonate` to react
  with.
- **The skim is enforceable on exactly one pool per market.** `feePipsFor` returns zero for an
  unregistered pool (`src/markets/ProtocolFeeHook.sol:535-536`, and the reasoning at `:513-516`)
  and `PoolManager.initialize` is permissionless, so anyone may open a fee-free sibling venue for
  the same pair with a different tick spacing, or with no hook at all. Inherent to v4. The skim
  is not enforceable at the pair level.
- **A hook that swapped through its own `unlock` would trade fee-free.** v4 early-returns zero
  from `beforeSwap`/`afterSwap` when the caller is the hook itself. Not reachable in the current
  implementation, which only unlocks from `collect`, and a hard constraint on every future one.
- **The global nonzero-delta check is what makes the shared singleton safe.**
  `PoolManager.unlock` reverts if *any* address's delta is nonzero at the end, not just the
  unlocker's, so a malicious token's transfer hook reached during an unlock cannot take from the
  singleton and walk away. This matters because the PoolManager is shared with the rest of the
  chain.

---

## Fixed

| Finding | What it was | Verified fixed at |
|---|---|---|
| **AM-01** | Recovery from a reserve loss was paid out as fresh yield, creating an unfunded claim | `lossCarryforward` is carried across capital flows (`src/pool/SharedReservePool.sol:121`) and observed growth repays it before the yield index moves (`:929-932`) |
| **AM-02** | Previously credited yield could be withdrawn out of principal after a later loss | `claimYield` pays at most the surplus above pooled supply: `src/pool/SharedReservePool.sol:632-635`. The remaining entitlement stays on the brand ledger |
| **AM-03** | Reserve migration discarded uncheckpointed yield entitlements | `_setYieldSource` runs `_accrueGlobal()` before recalling: `src/pool/SharedReservePool.sol:705`, recall at `:709`, re-sync at `:724` |
| **AM-04** | A buy minimum protected the router's balance rather than the recipient's net receipt | The router measures the receiver's balance across the payout and checks the minimum against that, so a transfer tax cannot slip past it: `src/markets/MarketRouter.sol:646-652` |
| **AM-05** | Liquidity seeding had no user minimums and no expiry | `src/markets/MarketRouter.sol:507-520`, same fix as A1-HIGH-2 |
| **AM-06** | Trades carried no caller-supplied expiry | Every router entry point takes a `deadline` and reverts `DeadlineExpired`: `src/markets/MarketRouter.sol:293` (`buyWithUsdg`), `:332` (`buyWithBrand`), `:382` (`sellForBrand`), `:437` (`sellForUsdg`) and `:520` (`seedLiquidity`) |
| **A1-HIGH-1** | `createMarket` silently adopted a pre-initialised pool's price | `src/markets/AssetMarketFactory.sol:1042` reverts `PoolAlreadyInitialised` instead. The grief residue is A3-MEDIUM-3 above. |
| **A1-HIGH-2** | `seedLiquidity` had no slippage protection and a no-op deadline | `src/markets/MarketRouter.sol:507-520` takes `minBrandUsed`, `minAssetUsed` and a real `deadline`, checked at `:520`. |
| **A1-MEDIUM-4** | no identity check on the Uniswap periphery | `src/markets/MarketRouter.sol:266-277`: the singleton is read off the factory, and a `PositionManager` bound to a different one reverts `PoolManagerMismatch` at construction. |
| **A1-LOW-5** | no two-step ownership on the factory | `src/markets/AssetMarketFactory.sol:92` is `Ownable2StepUpgradeable`. |
| **A2-HIGH-1** | the router never refunded input the pool could not absorb | `_swapExactIn` returns `spent` (`src/markets/MarketRouter.sol:633`, `:643`) and every entry point refunds the remainder: `:311`, `:354`, `:399`, `:463`, and `:551` for the seed path. |
| **A2-MEDIUM-3** | the testnet yield source reverted on a redemption that emptied the reserve | `script/DeployAssetMarketsTestnet.s.sol:204-209` caps the withdrawal at the recorded balance. Fixture only; the production adapters were always correct. |
| **A2-LOW-3** | comments describing behaviour the contracts no longer had | The "carries no on-chain authority at all" comment is gone from `src/`; the contracts the others described are gone with them. |
| **A3-HIGH-1** | `ProtocolGuard` did not disable `renounceOwnership()`, so the timelock could brick resume while leaving halt armed | `src/upgrade/ProtocolGuard.sol:147` reverts unconditionally. |
| **A3-L-3** | router refunds were redeemed through the reserve with no minimum payout | `src/markets/MarketRouter.sol:777-782` refunds by plain transfer and never redeems. The NatSpec at `:768-776` explains why: a partial fill is the pool declining to trade, not the holder choosing to exit, so charging them a redemption fee for it would be wrong. |
| **A3-L-8** | `renounceOwnership()` live on every proxy | Disabled on all ten: `ProtocolGuard:147`, `SharedReservePool:310`, `AssetMarketFactory:538`, `MarketRouter:233`, `ProtocolFeeHook:296`, `MorphoBlueYieldSource:147`, `SUSDaiYieldSource:422`, `LaunchFactory:405`, `StrategyGroupRegistry:140`, `SUSDaiHub:278`. |
| **A3-L-9** (brand token half) | `handOverMetadataAdmin` accepted `address(0)` and burned its one-shot flag doing it | Replaced by a two-step transfer: `src/pool/PooledBrandToken.sol:181-192`. The treasury half is still open above. |

---

## Obsolete

The contract or code path each of these was about no longer exists in `src/`. Listed so the
trail is complete and so nobody re-reports them from an old document.

| Finding | What it was about | Why it is gone |
|---|---|---|
| **A1-MEDIUM-1** | `setSplit` retroactively repriced accrued yield | `MarketYieldSplitter` is deleted. A market's income now splits in `BrandFeeVault.sweep` at fixed, initialisation-time destinations (`src/markets/BrandFeeVault.sol:247-249`). |
| **A1-MEDIUM-2** | `setOperator` moved control but not the payout | Same contract, same deletion. There is no per-destination payout table any more. |
| **A1-MEDIUM-3** | the LP floor was custodial: `LpRewardEscrow.distribute(to, amount)` could send the whole escrow anywhere | `LpRewardEscrow` is deleted. LPs now stake their own v4 position NFTs and claim per account: `src/markets/LpRewardDistributor.sol:296` and `:403`. Nobody can redirect the stream. |
| **A1-LOW-1** | harvest-spam rounded a small market's whole yield into the LP escrow | Both the escrow and the per-slice rounding are gone; `sweep` is a single two-way split with the remainder deliberately going to LPs (`src/markets/BrandFeeVault.sol:262-264`). |
| **A1-LOW-2** | a `lpFloorBps` + `protocolBps` combination could brick market creation | The splitter constructor that enforced the strict sum is deleted. The surviving parameter is validated in `_setProtocolBps` at `src/markets/AssetMarketFactory.sol:1253-1259`. |
| **A2-HIGH-2** | leg weight measured pool liquidity rather than brand float | `MarketYieldSplitter` is deleted and a brand has one market; there is no weighting anywhere. |
| **A2-LOW-1** | a leg under-credited itself after a period it could not be read | Per-leg read clocks do not exist. |
| **A2-LOW-2** | `retireLeg` was unusable from an EOA on a pool that still quoted | `retireLeg` does not exist. |
| **A3-L-10** | the buyback band surfaced a v4 core error while `canExecute()` reported ready | `BuybackEngine` and `AssetLockbox` are deleted. There is no buyback: float yield streams to LPs instead. |

---

## How the original passes were performed

Recorded because it bounds what the trail is worth. All three were source review plus Foundry
proof-of-concepts, with on-chain reads against Robinhood Chain 4663 for the deployed-state
claims. The third pass additionally compared local runtime bytecode against the deployed
bytecode for every implementation it reviewed, so that its findings were known to be about the
code that was actually live. No external firm was engaged, no formal verification was run, and
no economic or MEV modelling was done beyond the worked examples in the findings above.
