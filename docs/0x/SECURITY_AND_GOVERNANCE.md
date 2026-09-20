# Security and governance: what we can change, and how fast

Robinhood Chain mainnet, chainId 4663. All on-chain values below were read at block
68,293,146 (2026-09-20) unless a later spot check is noted inline.

This document answers one question: if 0x routes through our hook, what can we do to 0x and to
0x's users, and how quickly. It does not restate mechanics. For what the hook computes see
[Hook specification](./HOOK_SPECIFICATION.md); for how to produce and settle a number see
[Quoting and settlement](./QUOTING_AND_SETTLEMENT.md); for the pool and token inventory see
[Markets](./MARKETS.md). The venue-neutral integration document,
[`docs/AGGREGATOR_INTEGRATION.md`](../AGGREGATOR_INTEGRATION.md), carries a shorter version of
sections 4, 6 and 8 in its section 7; this document is the long form, with source citations.

Read the three-sentence version first, because the rest of this document is detail hung off it:

1. A 2-of-3 Safe owns every proxy and can replace the fee logic in a single transaction. There
   is no timelock.
2. What the Safe cannot change is the hook's callback surface, because the permission bits are
   mined into its address and `PoolKey.hooks` is part of pool identity.
3. A fee increase is delayed one hour on both rates that can invalidate a held quote, which
   makes a cached quote reliable for an hour but is not a security bound, because an upgrade
   could remove the delay.

---

## 1. Ownership

| Property | Value |
|---|---|
| Owner of every live proxy and all four beacons | Gnosis Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` |
| Safe version / singleton | v1.4.1, `SafeL2` |
| Threshold | 2 of 3 |
| Nonce at block 68,293,146 | 4 |
| Signer 1 | `0x668da5c12aF33106EEdbC298bF4Ec5555B803437` |
| Signer 2 | `0x176658D816C15a30Fa4165d48584037Bb89Ee4b2` |
| Signer 3 | `0xAc865dda2d00A8683B87B45d9F3598CF11f92Cb9` |

The three signers are EOAs on the same chain. We make no claim about how they are held, how
they are geographically or organizationally separated, or whether any two of them could be
compromised together. Treat the Safe as "two keys" for risk purposes, not as an institutional
control.

### What the Safe controls

`deployments/safe-batches/README.md:6` records sixteen ownership handles moved to the Safe. The
ones that matter to a router:

| Handle | Address | Owner power that matters to 0x |
|---|---|---|
| `ProtocolFeeHook` (UUPS proxy) | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` | upgrade the implementation; set per-pool `feePips`; set per-pool fee recipient; set the registrar |
| `SharedReservePool` (sUSDai, backs all six live markets) | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` | upgrade; `setRedemptionFee`; `setLiabilityCap`; `setYieldSource` |
| `SharedReservePool` (USDG/Morpho, no live market uses it) | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` | same |
| `ProtocolGuard` (the pause registry) | `0x013D1974F8215a12280e6b9a33F9732277F38C0e` | upgrade; `unpause`; `unpauseTarget`; `setGuardian` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` | upgrade; listing and market parameters for future markets |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` | upgrade |
| `LaunchFactory` | `0x95fe000285DA7797cC01394cCc410628B26e898d` | upgrade; launch fee policy for future launches |
| `StrategyGroupRegistry` | `0xBd02B0f3253F31dD02A752582e7b8974589333f7` | upgrade; read-only metadata |
| `BrandPsmFactory` | `0xB1e0ED28e24d3999216979847f9473b5C7bf12bA` | upgrade |
| `LiquidityZapper` V2 | `0x57FA92648c722Bb28A0d011f020685B952110a2D` | upgrade; not an aggregator surface |
| Both yield adapters, and all four market beacons | see `deployments/mainnet-state.json` | upgrade |

`MarketLens` `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` is ownerless and stateless, so it is
outside this table by construction. It is also not upgradeable, which is why it was redeployed
rather than upgraded when the hook's fee leg moved.

`pendingOwner()` on the hook is the zero address. There is no outstanding ownership nomination,
so no second party is one `acceptOwnership` call away from control. Verified by direct
`eth_call`. The same holds for every handle in `deployments/mainnet-state.json`, which records
`owner()` and `pendingOwner()` per handle.

`renounceOwnership()` is disabled on all ten UUPS proxies (`docs/audit-history.md:309`, and for
the two contracts an integrator depends on directly, `src/upgrade/ProtocolGuard.sol:147` and
`src/pool/SharedReservePool.sol:305`). The Safe therefore cannot orphan a contract into a state
where its resume path or its implementation is permanently frozen.

### Custody was migrated off a single EOA

Until 2026-09-20 one deployer EOA, `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9`, was the owner
of every proxy, the guardian, and the protocol treasury at once. It is now neither owner nor
guardian of any live contract. `deployments/safe-batches/README.md:56-58` records the end state
and the fork test that asserts it
(`test_live_theRetiredDeployerCannotEvenHalt` in `test/LiveGen5Mainnet.t.sol`).

Two honest residuals, both verified by `eth_call` and both covered again in section 9:

- The retired EOA still holds non-governance **revenue** roles: it is the hook's
  `feeRecipientOf` for market 17 (ABR) and market 18 (CORGIGG), and the frozen
  `protocolFeeRecipient` on all nine launch curves. Fee recipients are not authority; they only
  decide where already-accrued ERC-6909 claims are swept by `collect`. Markets 13, 14, 15 and 16
  were repointed to the Safe, as were `LaunchFactory.protocolFeeRecipient` and `lpFundRecipient`.
- An abandoned gen-4 `MarketRouter` at `0xcCDe2EcDE7072Efe61822551152663F204CF73ce` is still
  owned by the retired key and carries an unaccepted `pendingOwner` nomination to the Safe. It is
  dead code holding nothing. Do not route through it. Recorded as a conscious decision at
  `deployments/safe-batches/README.md:33-42`.

---

## 2. The guardian

`ProtocolGuard.guardian` is `0xc1d844d6478e450E62293882d2d6739c4a8693F9`, a single hot key, not
the Safe and not a multisig. It was rotated onto this address off the retired deployer EOA by a
Safe transaction (`deployments/safe-batches/README.md:44-54`).

What the guardian can do, exhaustively:

| Function | Gate | Source |
|---|---|---|
| `pause()` | `onlyGuardianOrOwner` | `src/upgrade/ProtocolGuard.sol:97` |
| `pauseTarget(address)` | `onlyGuardianOrOwner` | `src/upgrade/ProtocolGuard.sol:105` |

That is the complete list. The modifier is `src/upgrade/ProtocolGuard.sol:89-92`, and it admits
exactly `guardian` and `owner()`. Everything else on the registry is `onlyOwner`:

| Function | Gate | Source |
|---|---|---|
| `unpause()` | `onlyOwner` | `src/upgrade/ProtocolGuard.sol:113` |
| `unpauseTarget(address)` | `onlyOwner` | `src/upgrade/ProtocolGuard.sol:118` |
| `setGuardian(address)` | `onlyOwner` | `src/upgrade/ProtocolGuard.sol:123` |
| `_authorizeUpgrade(address)` | `onlyOwner` | `src/upgrade/ProtocolGuard.sol:151` |

So the guardian cannot resume, cannot rotate itself, cannot change any fee or cap, cannot
upgrade anything, and cannot move a token. It has no authority on the hook or on the reserve
other than flipping the flag those contracts read.

### Why the asymmetry is deliberate

The reasoning is written into the contract at `src/upgrade/ProtocolGuard.sol:21-33`. Halting an
active exploit is worthless if it has to wait for a second signer to wake up and a coordination
call to happen, so the halt path is one hot key with no delay. Resuming is the opposite: a key
that could resume could also un-halt a drain in progress, which is not recoverable, whereas the
worst a stolen guardian key achieves is downtime, which is. Downtime the Safe then unwinds is an
acceptable failure mode; a single key that can end a halt is not.

The consequence for 0x is that the *blast radius of a stolen guardian key is a denial of
service, bounded to the guarded set*, and section 6 shows the guarded set does not include v4
pool trading or reserve redemption. A stolen guardian key cannot stop a swap through our pools
and cannot stop a holder exiting a brand dollar. It can stop the USDG-to-brand mint leg.

One structural note. `GuardedUpgradeable` has no setter for the guard address it reads at
initialization (`src/upgrade/GuardedUpgradeable.sol:36-38` is the only write), and the hook
likewise sets its `guard` pointer once in `initialize`
(`src/markets/ProtocolFeeHook.sol:286`, no setter anywhere in `src/`). Repointing a contract at
a different pause registry therefore requires an upgrade, not a parameter change.

---

## 3. Upgradeability, stated without softening

**Every singleton in the stack is a UUPS proxy whose `_authorizeUpgrade` is a bare `onlyOwner`
with no delay of any kind. The Safe can replace the hook implementation in a single
transaction, the moment two of three signatures exist. There is no timelock, no delay, no
veto, and no escape hatch for an integrator.**

| Contract | Upgrade gate | Source |
|---|---|---|
| `ProtocolFeeHook` | `onlyOwner`, no delay | `src/markets/ProtocolFeeHook.sol:300` |
| `SharedReservePool` | `onlyOwner`, no delay | `src/pool/SharedReservePool.sol:303` |
| `ProtocolGuard` | `onlyOwner`, no delay | `src/upgrade/ProtocolGuard.sol:151` |

The same shape holds for the factory, the router, both yield adapters, the launch factory and
the registry; `docs/audit-history.md:76-82` enumerates all ten, though its line numbers are
stale relative to current `src/` and the three citations above were re-read directly.

`deployments/asset-markets-mainnet-v6.json` records `governance.timelockController: null` and
`timelockMinDelaySeconds: 0`, and its own `openItems` list still carries "THERE IS NO TIMELOCK"
as an unclosed action. The multisig half of that item is done. The timelock half is not.

### What an upgrade cannot change

The hook's **permission flags are permanent**. A v4 hook's callbacks are encoded in the low 14
bits of its own address, so the proxy address `0xc9932584c5154e4F58313a2e5423522E74e540Cc` was
mined against `0x00CC` (`beforeSwap`, `afterSwap`, and both return-delta bits). Because
`PoolKey.hooks` is part of a pool's identity, a hook that wanted different flags would need a
different address, and every pool ever launched against the old one would be orphaned. The
reasoning is in the contract at `src/markets/ProtocolFeeHook.sol:83-89` and again at `:99-100`,
and it is recorded as a structural constraint at `docs/audit-history.md:269-273`.

Concretely, and this is the part that is actually useful to a router: **no upgrade can give this
hook a liquidity, initialize, or donate callback, and no upgrade can remove its swap callbacks.**
The set of moments at which our code runs during your transaction is frozen for the life of the
address. `Hooks.validateHookPermissions` is re-asserted in `initialize`
(`src/markets/ProtocolFeeHook.sol:288`), so an implementation that declared different
permissions would fail its own initializer rather than silently diverge.

### What an upgrade can change, and the honest blast radius

Everything else. The fee logic inside `afterSwap`, the rate, `MAX_FEE_PIPS` itself, the
one-hour delay, the recipient, the oracle, and the pause behavior are all implementation or
storage, and all reachable in one transaction.

The worst case that matters to 0x is a malicious or mistaken implementation whose `afterSwap`
returns a delta taking up to 100% of the unspecified currency. That would make an exact-input
swap produce zero net output for the trader. Three things bound it:

1. **Your own `minBuyAmount` is the real bound.** Settler's v4 path consumes the actual
   `BalanceDelta` the `PoolManager` returns and `Take.take` checks `state.buy().amount()`
   against `minBuyAmount`, so a hook that inflated its fee mid-block causes a revert, not a
   loss. This is the only bound that does not depend on our good behavior. Size your slippage
   tolerance on that basis and not on `MAX_FEE_PIPS`.
2. **The hook cannot reach value outside the swap it was called for.** It has no
   liquidity callbacks, and `PoolManager.unlock` reverts if *any* address's delta is nonzero at
   the end of the lock rather than only the unlocker's, so a hook cannot take from the shared
   singleton and walk away (`docs/audit-history.md:282-286`). An upgrade cannot turn the hook
   into a drain on other Uniswap v4 pools on this chain.
3. **A hostile upgrade is loud.** The implementation slot is ERC-1967 and the Safe transaction
   is on chain. It is detectable, not preventable.

A denial of service is also reachable: an implementation that reverts in `beforeSwap` bricks
every pool carrying the hook, for every trader, us included. That is a liveness risk to 0x's
route, not a theft.

One self-inflicted risk worth disclosing because a reviewer would find it: the hook declares no
storage `__gap` (`docs/audit-history.md:161-171`). The hook's address can never move, so a
layout mistake in a future upgrade cannot be fixed by redeploying, and it would relocate the
per-pool oracle rings and the accrued-fee ledger under a live proxy. That is our operational
risk, but its failure mode is visible to you as a pool that suddenly quotes or charges wrongly.

---

## 4. The fee-change delay, and exactly what it is worth

Two rates can invalidate a quote you are already holding: the hook's per-pool `feePips` and the
reserve's `redemptionFeeBps`. Both delay **increases** by `FEE_INCREASE_DELAY` = 3600 seconds
and apply them through a **separate, permissionless commit**. Both apply **decreases
immediately**, and a decrease **cancels** any announced increase.

| | Hook trading fee | Reserve redemption fee |
|---|---|---|
| Live value | 5000 pips = 0.50% on all six live pools | 20 bps on the sUSDai reserve; 0 bps on the USDG/Morpho reserve |
| Denominator | 1,000,000 (pips) | 10,000 (bps) |
| Ceiling in the current implementation | `MAX_FEE_PIPS` = 10000 = 1.00% (`src/markets/ProtocolFeeHook.sol:140`) | `MAX_REDEMPTION_FEE_BPS` = 100 = 1.00% (`src/pool/SharedReservePool.sol:169`) |
| Delay on an increase | 3600 s (`src/markets/ProtocolFeeHook.sol:153`) | 3600 s (`src/pool/SharedReservePool.sol:183`) |
| Announce (owner only) | `setPoolFeePips(poolId, pips)` (`:407`) | `setRedemptionFee(bps)` (`:764`) |
| Commit (permissionless) | `commitPoolFeePips(poolId)` (`:441`) | `commitRedemptionFee()` (`:794`) |
| Cancel (owner only) | `cancelPendingPoolFeePips(poolId)` (`:467`) | `cancelPendingRedemptionFee()` (`:822`) |
| Delay on a decrease | none, one transaction (`:411-425`) | none, one transaction (`:767-783`) |
| Read the pending value | `pendingFeePipsOf(poolId)` (`:212`) | `pendingRedemptionFeeBps()` (`:148`) |
| Read the earliest landing time | `feePipsEffectiveAt(poolId)` (`:222`) | `redemptionFeeEffectiveAt()` (`:158`) |
| "Nothing is pending" | `feePipsEffectiveAt(poolId) == 0` | `redemptionFeeEffectiveAt() == 0` |
| Live value read | `feePipsFor(poolId)` (`:535`) | `redemptionFeeBps()` (`:139`); `previewRedeem` (`:863`) |

At block 68,293,146 neither rate had anything pending: `feePipsEffectiveAt` is zero on all six
live pools and `redemptionFeeEffectiveAt()` is zero on both reserves.

Note the pending slots are **meaningless on their own**. A committed or cancelled increase
leaves `pendingFeePipsOf` / `pendingRedemptionFeeBps` zeroed, and zero is also a legitimate
rate. The `...EffectiveAt` reads are the ones to branch on.

### The cache guarantee, stated precisely

If you read `feePipsEffectiveAt(poolId) == 0` at a block with timestamp `T`, then the live
`feePipsFor(poolId)` cannot exceed the value you read at that block, at any time before
`T + 3600`. The argument is mechanical: raising the rate requires `setPoolFeePips` at some
`T' >= T`, which writes `effectiveAt = T' + 3600 >= T + 3600`
(`src/markets/ProtocolFeeHook.sol:431`), and `commitPoolFeePips` refuses to land before
`effectiveAt` (`:444-446`). The identical argument holds for the reserve at
`src/pool/SharedReservePool.sol:773` and `:797-799`.

A decrease inside the window is only ever in the trader's favor: on exact-input it produces
more output, on exact-output it requires less input. So the one-hour window is a one-sided
bound, and **an integrator may safely cache a fee for up to one hour** from the block at which
the `...EffectiveAt` read was zero.

### The crucial caveat

**This is a reliability guarantee, not a security guarantee.** The hook is a UUPS proxy whose
`_authorizeUpgrade` is `onlyOwner` with no timelock, so an owner who wanted to raise a rate
instantly could ship an implementation without the delay in the same transaction. The contract
says so itself at `src/markets/ProtocolFeeHook.sol:397-403`; the reserve says the same at
`src/pool/SharedReservePool.sol:802-805`.

What the delay actually buys is protection against *mistakes* and against *ordinary repricing*:
a published quote cannot be repriced under you within the hour by an honest operator following
the intended process. It buys nothing against a hostile or compromised Safe. Size exposure on
your own `minBuyAmount`, not on the delay and not on the ceiling.

### Two parameters with no delay at all

The delay covers the two rates and nothing else. On the reserve, both of these land in one
owner transaction with no announcement:

| Parameter | Effect if changed adversely | Source |
|---|---|---|
| `setLiabilityCap(uint256)` | Lowering the cap below current `totalPooledSupply` makes `mint` revert `LiabilityCapExceeded` immediately, closing the USDG-to-brand leg. `MarketLens.maxMint` then returns 0. | `src/pool/SharedReservePool.sol:842` |
| `setYieldSource(address)` | Points the reserve at a different adapter. `mint` calls `_deployIdle()` inline, so an adapter that cannot accept a deposit makes `mint` revert. | `src/pool/SharedReservePool.sol:684`, `:697` |

Neither can take value from a trade already quoted, and neither touches `redeem`. Both can
close the mint leg with no warning, so **re-read `MarketLens.maxMint(reserve)` at fill time
rather than caching it for the hour you may cache the fee for.**

---

## 5. Parameter ceilings hard-coded in the implementation

| Constant | Value | Meaning | Source |
|---|---|---|---|
| `MAX_FEE_PIPS` | 10000 | 1.00% of the unspecified leg, denominator 1e6 | `src/markets/ProtocolFeeHook.sol:140` |
| `MAX_REDEMPTION_FEE_BPS` | 100 | 1.00% of a redemption, denominator 1e4 | `src/pool/SharedReservePool.sol:169` |

Both are `constant`, so they live in the implementation's bytecode rather than in proxy storage.
That has a precise consequence worth stating plainly: **they bind the owner within a given
implementation, and they are themselves replaceable by an upgrade.** A ceiling in an upgradeable
contract is a bound on the parameter setter, not a bound on the protocol.

Within an implementation the enforcement is thorough, and specifically it is re-checked at
**commit**, not only at announcement:

| Check point | Hook | Reserve |
|---|---|---|
| At registration | `src/markets/ProtocolFeeHook.sol:358` | n/a |
| At announcement | `:409` | `src/pool/SharedReservePool.sol:765` |
| At commit | `:452` | `:806` |

The commit-time re-check is the non-obvious one, and it exists for a reason that has already
happened once: `MAX_FEE_PIPS` was lowered from 5% to 1%, and the comment at
`src/markets/ProtocolFeeHook.sol:449-451` states the intent directly, that a pending value
authorized under an older, higher ceiling must not be able to land under the new one. The
reserve carries the same re-check with the same reasoning at
`src/pool/SharedReservePool.sol:802-805`. So a downgrade of the ceiling is effective against
anything already in flight, and there is no path by which an announcement made under an old
ceiling becomes a live rate above the current one.

Checking at announcement as well means an out-of-range value can never sit in the pending slot
where an integrator would read it (`src/pool/SharedReservePool.sol:761-763`).

---

## 6. Pause semantics for a router

This is the section most likely to break an integration, because "paused" means two different
things on the two legs of a USDG-denominated trade. The AMM leg keeps trading and gets
*cheaper*. The reserve leg stops.

`ProtocolGuard.isPaused(target)` is the global flag OR the per-target flag
(`src/upgrade/ProtocolGuard.sol:131-133`), so a global `pause()` and a `pauseTarget(hook)` are
indistinguishable to a reader. At block 68,293,146 the guard reports `paused() == false` and the
sUSDai reserve reports `paused() == false`.

| Surface | Behavior while paused | What you observe | Source |
|---|---|---|---|
| `ProtocolFeeHook.beforeSwap` / `afterSwap` | **Does not revert.** `feePipsFor` returns 0, so `afterSwap` takes no delta at all. | v4 pools keep trading. Your quote through `V4Quoter` gets 50 bps *better* with no other signal. | `src/markets/ProtocolFeeHook.sol:535-538`, rationale at `:523-534` |
| The guard read on the swap path | A raw `staticcall` treating any failure as "not paused" | A broken or self-destructed guard cannot brick a pool; it fails open to "charge the fee" | `src/markets/ProtocolFeeHook.sol:551-553` |
| `ProtocolFeeHook.collect` | Reverts `ProtocolPaused` | Irrelevant to routing; this is our own fee sweep | `src/markets/ProtocolFeeHook.sol:835` |
| v4 pool trading generally | Unaffected. The `PoolManager` is Uniswap's, not ours, and we have no pause over it. | Swaps settle normally | n/a |
| `SharedReservePool.mint` | Reverts `ProtocolPaused` | **This is the gate.** USDG-to-brand mint fails, so a USDG-denominated buy has no first leg. | `src/pool/SharedReservePool.sol:434-439` |
| `MarketLens.maxMint(reserve)` | Returns **0** | The convenience read to branch on. It returns 0 for a paused reserve before it even looks at the cap. | `src/markets/MarketLens.sol:173-174`, and see the caveat below |
| `SharedReservePool.paused()` | Returns `true` | The authoritative read, straight off the reserve. `guard().isPaused(reserve)` under the hood. | `src/upgrade/GuardedUpgradeable.sol:47-49` |
| `SharedReservePool.redeem` (both overloads) | **Not guarded. Never reverts for a pause.** | The sell leg survives a halt. A brand holder can always exit at 1:1 less the redemption fee. | `src/pool/SharedReservePool.sol:503-506`, `:527-530`; the design note is `src/upgrade/ProtocolGuard.sol:35-40` |
| `SharedReservePool.swap` (brand to brand, 1:1) | Reverts `ProtocolPaused` | A brand-to-brand hop is unavailable during a halt | `src/pool/SharedReservePool.sol:586-590` |
| `SharedReservePool.claimYield`, `deployIdle` | Revert `ProtocolPaused` | Irrelevant to routing | `:616-620`, `:655` |

Three practical consequences.

**A pause is invisible on the AMM leg unless you look for it.** Nothing reverts, so a router
that infers "venue down" from a revert learns nothing. The hook exposes no `paused()` getter of
its own, only `guard()`, so the read is one hop: call
`ProtocolGuard.isPaused(0xc9932584c5154e4F58313a2e5423522E74e540Cc)` on the registry at
`0x013D1974F8215a12280e6b9a33F9732277F38C0e`. If you do not want to know, you do not have to:
the quote is still correct, because a stock `V4Quoter` runs the same `feePipsFor` you would.

**The pause boundary is the one place the one-hour cache guarantee does not protect you, and it
protects you in the wrong direction.** A quote taken *while paused* prices the fee at zero. An
`unpause()` is a single Safe transaction with no delay, so that quote can become 50 bps
optimistic in the very next block. Section 4's guarantee is about `setPoolFeePips`, which is not
the path a resume takes. Two safe habits: quote at fill time through `V4Quoter` and derive
`minBuyAmount` from that single read, or read the stored rate `feePipsOf(poolId)` rather than
the pause-masked `feePipsFor(poolId)` if you want the rate that will apply after a resume.

**Detect the closed mint leg on the reserve, not on the hook.** The two legs have independent
pause consequences, and the reserve is the one that actually refuses. `MarketLens.maxMint`
returning 0 is the single read that covers both "paused" and "at the liability cap".

`maxMint(address)` is `view`, as is every other function on the lens, and
`src/markets/MarketLens.sol` builds to the deployed bytecode at
`0x704E7a0e7864250303B05b25EabC2417CE99ceb6` — verified `exact_match` on Sourcify — so the
line citation and the runtime are the same thing. An earlier lens,
`0x0a3d8332D949b4aE650f3aC6468620e403a50fF1`, is still live and is NOT this one; see
[Quoting and settlement](./QUOTING_AND_SETTLEMENT.md) §4.1. If you want a read with no
composition at all, `SharedReservePool.paused()`, `liabilityCap()` and `totalPooledSupply()`
are the three values `maxMint` combines.

---

## 7. Audit status

**There has been no external third-party audit. No firm outside the team has reviewed this
code.** `docs/audit-history.md:3-5` states it in those words: "This is a record of internal
review, not an external audit. Nobody outside the team has looked at this code." No formal
verification has been run, and no economic or MEV modeling has been done beyond worked examples
inside individual findings (`docs/audit-history.md:333-340`).

What does exist:

| Pass | Date | Prefix | Where it lives now |
|---|---|---|---|
| Reserve and router review | 2026-09-08 | AM | consolidated into `docs/audit-history.md` |
| First asset-markets pass | 2026-09-09 | A1 | consolidated into `docs/audit-history.md` |
| Multi-leg and buyback surface | 2026-09-09 | A2 | consolidated into `docs/audit-history.md` |
| Upgradeable stack | 2026-09-10 | A3 | consolidated into `docs/audit-history.md` |
| Full `src/` review with fork PoCs | 2026-09-10 | SR | `docs/SECURITY_AUDIT_2026-09-10.md` |

Method, as recorded: source review plus Foundry proof-of-concepts, with on-chain reads against
chain 4663 for deployed-state claims. The A3 pass additionally compared locally compiled runtime
bytecode against the deployed bytecode for every implementation it reviewed, so its findings are
known to be about live code. The SR pass carries a passing mainnet-fork PoC for its one critical
finding. Every finding in both documents was re-checked against `src/` on 2026-09-19 with a
`path:line` citation per verdict. `docs/SECURITY_AUDIT_2026-09-10.md:38-39` describes itself as
"a bounded engineering review, not an audit certification", which is the right characterization
of the whole trail.

### What that trail does and does not cover

The coverage gap matters more than the finding count. `docs/audit-history.md:7-12` records that
the architecture the four passes described **has since been replaced twice**. The live generation
is gen-6, and contracts the passes reviewed in detail (`MarketYieldSplitter`, `BuybackEngine`,
`AssetLockbox`, `LpRewardEscrow`, `StablecoinLauncher`, `BrandedVault`) no longer exist in
`src/`. Reviewed line counts from those passes should not be read as coverage of what is live.

Specifically for the surface 0x would route through:

- **The current `afterSwap` fee mechanism has not been reviewed by any of the five passes.** The
  fee moved out of `beforeSwap` after the last pass was written. `docs/audit-history.md:87-98`
  carries A3-HIGH-2, "the trading skim is levied on the requested input, not the filled input",
  as still open with a citation to `src/markets/ProtocolFeeHook.sol:407-408`. That finding
  describes the old implementation and the citation now points at `setPoolFeePips`. The finding
  was in fact resolved by moving the charge to `afterSwap`, which is exactly the change the
  finding asked for, but no review has been performed *since* that change. The single most
  important behavior in this integration is the least reviewed.
- The one-hour fee delay, the commit-time ceiling re-check, and the ownership migration to the
  Safe all postdate every pass as well.

### Findings that are open and relevant to an integrator

| Finding | Substance | Relevance to routing |
|---|---|---|
| A3-CRITICAL-1 (`docs/audit-history.md:67-85`) | One key owns every proxy, beacon, the guard and the treasury, with no timelock | Partly closed: it is now a 2-of-3 Safe, not an EOA. The no-timelock half is still true. The finding's own text is stale, see section 9. |
| AM-08 / SR-04 (`docs/audit-history.md:35-55`) | `MorphoBlueYieldSource` values shares off stored Morpho totals without accruing first, misattributing interest between brands | Misattribution between brands, not a path to unbacked value. All six live markets sit on the sUSDai reserve, not the Morpho one. |
| A3-MEDIUM-2 (`docs/audit-history.md:110-116`) | `_deployIdle` moves every idle unit to the yield source, so there is no idle buffer and every redemption crosses into the adapter | A liveness risk on the redeem leg. Size against `MarketLens.redeemableAssets`, not against `totalAssets`. |
| A3-MEDIUM-1 (`docs/audit-history.md:100-108`) | `BrandFeeVault.sweep` reverts wholesale when the adapter cannot take a deposit | Our revenue path, not your trade path. |
| A3-MEDIUM-4 (`docs/audit-history.md:118-129`) | Market creation and brand registration run during a global halt | An incident-response gap. Traced for value movement and there is none. |
| A3-L-4 (`docs/audit-history.md:161-171`) | Neither the hook nor the router declares a storage `__gap` | Upgrade-safety risk on our side, visible to you as section 3's failure mode. |
| AM-07 / A3-L-5 (`docs/audit-history.md:57-65`, `:173-184`) | The `verified` flag is computed from the asset's bytecode and stored on the market | Do not surface `verified` as an endorsement of a market, its brand, or its liquidity. |
| SR-01 (`docs/SECURITY_AUDIT_2026-09-10.md:144-225`) | A critical, unpatched, still-live exploit in the retired `StablecoinLauncher` | Not part of the market stack. See section 9; do not route through it. |

---

## 8. Source verification

Sourcify is the canonical route, not Blockscout.

| Property | Value |
|---|---|
| Compiler | `v0.8.26+commit.8a97fa7a` |
| Optimizer | enabled, 200 runs |
| `via_ir` | `true` |
| Submission form | standard-JSON input only |
| Registry | Sourcify, chain 4663 |

**Verify by standard-JSON input, never by flattened source.** With `via_ir = true` the IR
pipeline is sensitive to the exact compilation unit, and a flattened submission will not
reproduce the deployed bytecode.

21 contracts an integrator touches are verified, including every implementation currently behind
a live proxy. **20 of the 21 are `exact_match`. One is not:** `AssetMarketFactory`
implementation `0x45Ce2F93aD46d1393Eff5da56fFc4537740022C0` is a metadata-level `match`, meaning
its source is authoritative and its metadata hash is not. Confirmed live against the Sourcify v2
API while writing this document, alongside the hook implementation
`0xd4AC6b17338866E43E1922cfb563A81Ff36b425B`, which is `exact_match`.

Check any single address:

```sh
curl -s https://sourcify.dev/server/v2/contract/4663/0xc9932584c5154e4F58313a2e5423522E74e540Cc | jq '{match, creationMatch, runtimeMatch}'
```

Or check the whole set with our own script: `./script/verify-mainnet-sourcify.sh --status`. The
older `check-all-by-addresses` endpoint has been withdrawn and answers 404.

**Why not Blockscout.** Blockscout's verification API on chain 4663 sits behind a Cloudflare
challenge that returns an HTML interstitial to `forge verify-contract`, so submitting there is
not currently possible. Blockscout imports Sourcify matches, so the source is still readable in
its UI at `https://robinhoodchain.blockscout.com/address/<address>?tab=contract`. The *proxies*
read as unverified there while their implementations are verified; that is a UI artifact of how
Blockscout treats ERC-1967 proxies, not a verification gap.

Do not pin an implementation address in any configuration. Section 3 means implementations move.
Pin the proxy `0xc9932584c5154e4F58313a2e5423522E74e540Cc`, which cannot move, and read the
implementation from the ERC-1967 slot if you want to know what is behind it.

---

## 9. Known limitations

Ordered roughly by what a reviewer would flag first. Everything here is something 0x would find
on its own; it is listed here so nothing is a surprise.

1. **No external audit.** Internal review only. See section 7. The current `afterSwap` fee
   mechanism, the fee delay, and the Safe migration all postdate every review that exists.

2. **No upgrade timelock.** Two of three Safe signers can replace the hook's fee logic in a
   single transaction. `deployments/asset-markets-mainnet-v6.json` still lists adopting a
   timelock as an open item. Your `minBuyAmount` is the only bound that does not depend on our
   good behavior.

3. **The pools are small.** Approximately $37.7k of total TVL across all six live v4 pools,
   with measured price impact reaching +108% on a 1,000 USDG buy of the largest equity market.
   See [Markets](./MARKETS.md) for the per-pool measurements. The deep leg is the reserve:
   roughly 9.96M USDG of mint headroom and roughly 35,276 USDG redeemable at 1:1 less 20 bps.
   Route size against the reserve, not against the pools.

4. **Six un-graduated launch curves have a frozen `protocolFeeRecipient` with no setter.**
   `LaunchCurve` snapshots the factory's fee policy in `initialize`
   (`src/launchpad/LaunchCurve.sol:231`, the only write in the file) and exposes no setter for it;
   the only recipient a curve can repoint is the creator's
   (`src/launchpad/LaunchCurve.sol:293`). All nine deployed curves, including the six that have
   not graduated, therefore carry the retired deployer EOA as the protocol fee destination
   permanently. Verified by `eth_call` on all nine curve addresses. Launch curves are not v4
   pools and are not a routing surface, but this is revenue accruing to a retired key with no
   on-chain repair path.

5. **The retired deployer EOA still holds non-governance operational roles.** It is the hook's
   `feeRecipientOf` on markets 17 and 18, the frozen recipient on all nine curves, and the
   recorded `creator` on the market records. None of these is authority: a fee recipient only
   decides where already-accrued ERC-6909 claims are swept by `collect`, and `collect` pays
   whoever is named when it runs. It also still owns the dead gen-4 `MarketRouter`
   `0xcCDe2EcDE7072Efe61822551152663F204CF73ce` with an unaccepted nomination to the Safe; the
   residual risk is that someone holding that key ships an implementation to a contract that
   still looks official. Do not route through it.

6. **Two live legacy contracts carry known, unpatched defects.** Neither is part of the market
   stack, and neither is reachable from the hook or the reserve, but both are live on 4663:
   - `StablecoinLauncher` `0xecF46dC819Ef7523b842852B1026a5622889FB11` with `BrandedVault`
     sphUSDG `0x6040E2672Ca869dd0b74362A8D164B2F47705B0C`. SR-01 is a critical sell-wall
     repricing exploit, proven by a passing mainnet-fork PoC, still present in the deployed
     bytecode. It holds nothing today and arms with the first purchase
     (`docs/SECURITY_AUDIT_2026-09-10.md:116-134`, `:197-211`).
   - `LiquidityZapper` V1 `0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd`, ownerless, accepting
     zero slippage bounds on both doors and passing `amountOutMinimum: 0` downstream, therefore
     sandwichable and unfixable (`deployments/asset-markets-mainnet-v6.json`,
     `liquidityZapperNote`). Do not point any client at it.

7. **Redemption liveness depends on the yield adapter.** There is no idle buffer in the reserve:
   `mint` calls `_deployIdle()` inline and it moves every idle unit into the yield source, so the
   standing idle balance is approximately zero and every redemption crosses `_recallIfNeeded`
   into the adapter (A3-MEDIUM-2, `docs/audit-history.md:110-116`). Quote the redeem leg off
   `MarketLens.redeemableAssets(reserve)`, which moves with every mint, redeem and keeper action.

8. **The sUSDai brand is fully backed but not yet yield-bearing.** While the bridging keeper is
   stopped, deposits are held as local USDG in the adapter rather than bridged, so the brand
   earns no sUSDai yield. It is redeemable throughout, because `maxBridgeAmount` gates `bridgeOut`
   and never `deposit` or `redeem` (`deployments/asset-markets-mainnet-v6.json`,
   `backingCaveat`). The keeper is a separate operational key with no governance authority.

9. **The skim is not enforceable at the pair level.** `feePipsFor` returns 0 for an unregistered
   pool and `PoolManager.initialize` is permissionless, so anyone can open a fee-free sibling
   pool for the same pair with a different tick spacing or no hook at all
   (`docs/audit-history.md:274-278`). Discover pools through `AssetMarketFactory.poolKeyOf`
   rather than by scanning the `PoolManager`, or you will route through a venue we do not
   operate and cannot vouch for.

10. **Beacon upgrades are less protected than UUPS upgrades.** The four market beacons are
    OpenZeppelin `UpgradeableBeacon`s owned by the Safe from the instant they are deployed
    (`src/upgrade/ProtocolStack.sol:99-106`), and a beacon `upgradeTo` validates only
    `newImplementation.code.length > 0`, with no `proxiableUUID` check and no layout
    validation, so one wrong argument rewrites every market's brand token, treasury, fee vault
    and reward distributor simultaneously with no revert to catch it
    (`docs/audit-history.md:245-248`). None of these contracts is on the swap path.

11. **`verified` on a market record is not an endorsement.** It is computed from the asset
    token's bytecode (AM-07, `docs/audit-history.md:57-65`). Listing is permissionless and
    nothing checks brand name or symbol uniqueness, so anyone can point a market at a genuine
    Robinhood equity token and earn `verified: true` on a brand, price and liquidity profile of
    their choosing.

12. **`deployments/mainnet-state.json` is a dated snapshot and drifts.** Its fee-recipient
    entries, for instance, predate the repointing of markets 13 through 16 to the Safe, which is
    live on chain. Read governance and balances from the chain, using the manifest only as an
    address book. Regenerate it with `node script/sync-mainnet-state.mjs` from the application
    repository, which is where that script lives because it resolves its dependencies through
    that project.

13. **USDG's issuer can pause or freeze the reserve asset, and that dominates everything else
    here.** USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` is not a plain ERC20. It is an
    ERC-1967 proxy, implementation `0x68184c449e1a8f34fa18d289737129fd27b66f8f` at the time of
    writing, and it exposes both `paused()` and `isFrozen(address)`. Both currently read false,
    including `isFrozen` for the sUSDai reserve `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2`,
    and `pause()` is role-gated on the issuer rather than on us.

    If the issuer pauses the token or freezes the reserve's address, redemption stops working
    no matter how correct our code is. Our deliberately unpausable redemption path does not
    help, because the block lives in the token and not in the pool. Nothing in this repository
    can mitigate it and no amount of review of our contracts will surface it, since it is
    invisible from `src/`. It is the largest centralization risk in the system and it is
    entirely outside our control. We would rather state it than have it found.
