# Upgrading

How to change deployed contract logic on Robinhood Chain mainnet (`chainId 4663`), who is
allowed to, and what nobody can change.

Every address here was read back from chain and is pinned by a test, not by this file:
`test/OwnershipMigrationMainnetFork.t.sol` for the ownership end state,
`test/LiveGen5Mainnet.t.sol` for the live behaviour, `test/upgrade/UpgradeInvariants.t.sol`
for storage layout. If this page and one of those disagree, the test is right.

> **There is no timelock. None.** The Safe can deploy an implementation and point a proxy at
> it in a single transaction, with no announcement and no window in which anyone can react.
> This is the honest description of the current deployment and it is stated first because
> every other control below is weaker than a reader might assume from it. The two fee delays
> that do exist (see *Delayed parameters*) are reliability guarantees for quoting integrators,
> not security guarantees, because an upgrade can remove them in one transaction.

---

## Who holds what

| Role | Address | Powers |
|---|---|---|
| Owner | Gnosis Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` | Everything: upgrade any proxy, move any beacon, set every parameter, resume from a pause, replace the guardian |
| Guardian | `0xc1d844d6478e450E62293882d2d6739c4a8693F9` | `pause` and `pauseTarget`, immediately. Nothing else |
| Retired deployer | `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` | No ownership anywhere, not the guardian. Still named as a fee *recipient* — see below |

The Safe is v1.4.1 (SafeL2 singleton), **threshold 2 of 3**. Its three signers are
`0x668da5c12aF33106EEdbC298bF4Ec5555B803437`,
`0x176658D816C15a30Fa4165d48584037Bb89Ee4b2` and
`0xAc865dda2d00A8683B87B45d9F3598CF11f92Cb9`; none of them is the retired deployer.
`test_fork_theSafeIsATwoOfThreeThatHasAlreadyTransacted` asserts the threshold, the signer
count, their distinctness and that the Safe has executed before, so the signing path is
proven by the chain rather than by assertion here.

### The guardian is deliberately not the Safe

`ProtocolGuard` (`0x013D1974F8215a12280e6b9a33F9732277F38C0e`) splits halting from resuming.
`pause`/`pauseTarget` are `onlyGuardianOrOwner`; `unpause`, `unpauseTarget`, `setGuardian` and
`_authorizeUpgrade` are `onlyOwner`. Halting is incident response and has to work in the
minute an exploit starts, with one key, without waking a second signer. Resuming is the slow
path on purpose: a stolen guardian key buys an attacker a denial of service that the Safe
unwinds, whereas a key that could resume could un-halt a drain in progress.

`test_fork_theGuardianIsStillAHotKeyThatActsAlone` proves all three halves of this against
live state: the guardian is not the Safe, it can halt a target, it reverts on unpause, and
the Safe can resume.

Two things pausing deliberately does **not** reach, and both must stay that way:

- `SharedReservePool.redeem` carries no `whenNotPaused`. A brand token is a 1:1 claim, and a
  claim that can be suspended is not a claim. Holders can exit while everything else is
  halted, especially then. (`test_redemptionSurvivesAPause`)
- Brand-token transfers. A holder who cannot move the token cannot reach wherever they would
  redeem or sell it. (`test_brandTransfersSurviveAPause`)

`ProtocolFeeHook` also does not revert when paused: `feePipsFor` returns zero and trading
continues fee-free. A halt must never brick a Uniswap v4 pool that other people's routers
are already quoting.

---

## The sixteen handles

These are every address with an owner. The list is pinned by
`test_fork_everySingleHandleIsOwnedByTheSafe`; add a handle to the protocol and add it there
too, or the sweep silently stops covering it.

**Two-step (`Ownable2Step`): transfer nominates, the successor must accept.**

| Contract | Address | Mechanism |
|---|---|---|
| `StrategyGroupRegistry` | `0xBd02B0f3253F31dD02A752582e7b8974589333f7` | UUPS |
| gen-4 `AssetMarketFactory` (abandoned) | `0xbE2fb491C37F19E723F86A8cAcA625B4Ba75a5E7` | UUPS |
| `LaunchLocker` | `0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C` | Not upgradeable |
| `ProtocolGuard` | `0x013D1974F8215a12280e6b9a33F9732277F38C0e` | UUPS |
| `MorphoBlueYieldSource` | `0x8e4E5e5EE25DF4721D845600F82bf2Bca48Fa358` | UUPS |
| `SUSDaiYieldSource` | `0x460f319E43428387bff58ec262C992Ec7DA22fDc` | UUPS |
| `LaunchFactory` | `0x95fe000285DA7797cC01394cCc410628B26e898d` | UUPS |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` | UUPS |
| `ProtocolFeeHook` | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` | UUPS |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` | UUPS |
| `SharedReservePool`, USDG/Morpho | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` | UUPS |
| `SharedReservePool`, sUSDai | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` | UUPS |

**Beacons (plain `Ownable`): transfer is one step and irreversible.**

| Beacon | Address | Moves |
|---|---|---|
| `BrandFeeVault` | `0x65876276feE875e1A120F63575150593E6AEa0d3` | Every market's fee vault |
| `LpRewardDistributor` | `0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6` | Every market's reward distributor |
| `PooledBrandToken` | `0x1964b405C09CF252d835A80556536C86dcbE105F` | Every brand stablecoin in every reserve |
| `PoolBrandTreasury` | `0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E` | Every brand treasury |

`pendingOwner()` is the zero address on all twelve two-step handles: no nomination is
outstanding anywhere, which matters because a stale nomination is a live claim anybody
holding that address can accept later.
(`test_fork_noNominationIsLeftOutstanding`)

**One beacon upgrade changes every clone at once**, existing and future, instantly, with no
per-instance migration. That is the feature and the danger.
(`test_oneBeaconUpgradeMovesEveryBrandAtOnce`,
`test_brandsRegisteredAfterAnUpgradeUseTheNewImplementation`)

`MarketLens` (`0x704E7a0e7864250303B05b25EabC2417CE99ceb6`) has no owner and no state. It is
replaced by deploying a new one and re-pointing readers, not upgraded. That is not a
hypothetical: the address above is the second replacement. The first was forced when the
hook's fee moved legs, and the second, on 2026-09-20, swapped the `V4Quoter` wrapper for an
in-memory replay of `Pool.swap` over `extsload` state, which made every quote function `view`
and therefore `STATICCALL`-able. The lens it replaced,
`0x0a3d8332D949b4aE650f3aC6468620e403a50fF1`, is still live and still returns identical
amounts; nothing expires it. So the cost of "not upgradeable" here is not risk, it is
coordination: a reader that hardcoded the old address keeps getting correct-but-orphaned
answers from a contract nobody is maintaining. Re-point readers from `core.marketLens` in
`deployments/asset-markets-mainnet-v6.json` rather than from a constant, and treat a lens
change as a release step with a consumer list, not as a silent redeploy.

---

## Before you upgrade anything: storage rules

This is the part that loses money. A bad layout does not revert. The proxy silently
reinterprets live state, and on a reserve holding real backing that means `totalPooledSupply`
starts being read as `lossCarryforward` against real balances.

`test/upgrade/UpgradeInvariants.t.sol` is the alarm. It pins the total storage footprint of
every upgradeable contract and the individual slot of every field on the reserve and the
registry, by writing through a probe and reading raw slots. Run it before proposing anything:

```
forge test --match-contract UpgradeInvariants -vv
```

Rules for any new version:

1. **Only append.** New variables go immediately before `__gap`, never inserted, reordered,
   retyped or removed.
2. **Shrink `__gap` by exactly the number of slots you added**, so the footprint is unchanged.
   `SharedReservePool` already did this once: its gap is `uint256[39]`, shrunk from 40 when
   the packed `pendingRedemptionFeeBps`/`redemptionFeeEffectiveAt` slot was added, which is
   why the end of storage is exactly where it was for both live proxies.
3. **`ProtocolFeeHook` carries no `__gap` and that is correct** — it is a leaf that nothing
   inherits, so appending at the end is safe and no existing slot moves. Do not add a gap to
   it now; that would itself be a layout change.
4. **Update the footprint number in `UpgradeInvariants` deliberately**, as a review
   checkpoint. Never edit it to make a red test green. That test failing is the alarm working.
5. `initialize` carries `initializer` and cannot run again. New state needs a
   `reinitializer(n)`, called through `upgradeToAndCall`'s data argument in the same
   transaction as the upgrade.
6. Every implementation ships with its initializer locked in the constructor
   (`_disableInitializers()`), and
   `test_everyImplementationShipsWithItsInitializerLocked` sweeps for it. An unlocked
   implementation can be initialized by a stranger who then owns a contract a live proxy
   delegates into.

---

## Rehearse on a fork first

Non-negotiable for a beacon, because it touches every clone at once, and strongly advised for
the reserves, which hold the backing.

```bash
script/rehearse-mainnet.sh
```

That stands the whole stack up on a local fork using the same deploy scripts and the same
runbook commands a real deployment uses, then launches and seeds a market on it. It redirects
`FOUNDRY_BROADCAST` to a temp directory so a rehearsal cannot overwrite the real mainnet
records under `broadcast/<script>/4663/`.

For a single upgrade, a bare fork plus impersonation is enough:

```bash
script/anvil-fork.sh
```

Then `cast rpc anvil_impersonateAccount 0x28569c1716EF81f307d666A1EC08bDAE92AC0373` and send
the upgrade from the Safe address directly. Afterwards confirm the proxy still answers the
same: for a reserve that is `asset()`, `yieldSource()`, `owner()`, `totalPooledSupply()`,
`liabilityCap()`, `redemptionFeeBps()` and `totalAssets() >= totalPooledSupply()`.

---

## Procedure A — upgrade a UUPS proxy

Authority is `_authorizeUpgrade`'s `onlyOwner`, so the upgrade call itself must come from the
Safe. Deploying the implementation does not.

**1. Deploy the new implementation.** Permissionless, any funded key. It must never be
initialized directly; the constructor already calls `_disableInitializers()`.

```bash
forge create src/pool/SharedReservePool.sol:SharedReservePool --rpc-url robinhood --private-key $PRIVATE_KEY
```

**2. Build the calldata.** OpenZeppelin v5 removed plain `upgradeTo` from UUPS; calling it
fails. Pass `0x` for `data` unless a `reinitializer` must run atomically with the upgrade.

```bash
cast calldata 'upgradeToAndCall(address,bytes)' <NEW_IMPL> 0x
```

**3. Execute it from the Safe.** Paste the target proxy and that calldata into the Safe
Transaction Builder as a raw transaction and sign it 2-of-3. There is nothing to schedule and
nothing to wait for: it lands when the second signature does.

**4. Verify the implementation slot moved**, reading the ERC-1967 slot rather than trusting a
getter:

```bash
cast storage <PROXY> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url robinhood
```

**5. Publish the source.** `script/verify-mainnet-sourcify.sh` is idempotent and signs
nothing; it submits standard-JSON input to Sourcify, which is the only route that works on
this chain (Blockscout's verify API sits behind a Cloudflare challenge). An implementation
nobody can read is an implementation nobody can review.

### The `script/Upgrade*Mainnet.s.sol` scripts

There is one per shipped upgrade — `UpgradeReserveStrictRedeemMainnet`,
`UpgradeHookFeeDelayMainnet`, `UpgradeProtocolFeeCapMainnet`, and so on. Each one deploys the
implementation, points the proxies at it, and then re-reads a struct of everything the upgrade
must not disturb and reverts if any of it moved. That verification block is the reason to keep
using them.

**They assert that the broadcasting signer owns the proxy**, which since the custody migration
is the Safe, so they can no longer broadcast a mainnet upgrade. Use them in simulation (no
`--broadcast`) against a fork to rehearse and to read out the exact calldata, then execute
that calldata from the Safe. `script/RotateGuardianMainnet.s.sol` is the shape a *new*
governance script should take: it validates hard and prints a transaction for the multisig to
sign, and broadcasts nothing.

## Procedure B — upgrade a beacon

Same two halves, one step and no acceptance: deploy the implementation with any key, then have
the Safe call `upgradeTo(address)` on the beacon. Read `implementation()` back afterwards.

Rehearse this one. A beacon upgrade is live on every clone the moment it lands, and there is
no per-clone rollback short of a second upgrade.

**Do not upgrade these two beacons:** `0xF360132A1156f9E7843001F83F78768a29A772Ad` and
`0x422E356fb62852D4D24D457991BBc1D777ab2Db4`. They are live `UpgradeableBeacon`s on 4663 with
their own implementations, and `AssetMarketFactory.beacons()` references neither: they are
orphans from an earlier generation. An `upgradeTo` aimed at either succeeds, emits `Upgraded`,
costs gas and moves zero live markets, which is worse than a revert because it reads as a
completed upgrade. See the note in `deployments/asset-markets-mainnet-v6.json`.

## Procedure C — replace a yield-source adapter

Adapters behind a reserve are swapped, not upgraded in place, when the target protocol
changes. `setYieldSource` is `onlyOwner`, so it is a Safe transaction.

```bash
cast calldata 'setYieldSource(address)' <NEW_ADAPTER>
```

It recalls the **entire** deployed balance from the old adapter first, then swaps the pointer,
and deliberately leaves the capital idle rather than auto-committing it to an adapter that has
never been exercised. Someone calls `deployIdle()` afterwards, which is permissionless.

The strict path reverts `MigrationWouldStrand(deployed, recalled)` if the outgoing adapter
returns less than it booked beyond `MAX_MIGRATION_DUST` (2 wei). That revert is the feature:
migrating anyway requires the explicit `setYieldSource(address,bool)` overload with
`acceptStranding = true`, which charges the difference to `lossCarryforward` and emits
`MigrationStranded`, so a write-off is a decision on the record rather than a silent
disappearance.

One adapter per consumer remains the rule. `SUSDaiYieldSource` and `MorphoBlueYieldSource`
attribute shares per calling consumer, so sharing an instance is *safe*, but two consumers
sharing one instance still share one position's liquidity, and a recall for one can be short
because of the other.

---

## Delayed parameters

Two fee knobs are announce-then-commit. Both are on the *increase* only; a decrease applies
in the same transaction and cancels any pending increase.

| | `ProtocolFeeHook` | `SharedReservePool` |
|---|---|---|
| Announce | `setPoolFeePips(id, pips)` | `setRedemptionFee(bps)` |
| Commit | `commitPoolFeePips(id)`, permissionless | `commitRedemptionFee()`, permissionless |
| Cancel | `cancelPendingPoolFeePips(id)` | `cancelPendingRedemptionFee()` |
| Delay | `FEE_INCREASE_DELAY` = 1 hour | `FEE_INCREASE_DELAY` = 1 hour |
| Ceiling | `MAX_FEE_PIPS` = 10000 (1%, denominator 1e6) | `MAX_REDEMPTION_FEE_BPS` = 100 (1%) |
| Live today | 5000 pips (0.50%) on all six live pools | 20 bps on sUSDai, 0 on USDG/Morpho |

The ceiling is re-checked at commit as well as at announcement, because a constant that has
already been lowered once can be lowered again and a value authorised under the old ceiling
must not be able to land under the new one. `MAX_FEE_PIPS` came down from 50000 to 10000
exactly that way.

Neither delay survives an upgrade. The Safe can ship an implementation without them in one
transaction. What the hour genuinely buys is that an aggregator's quote cannot be repriced
under it inside the hour by a parameter change, which is a reliability property and worth
having. Do not sell it as a security property.

`test_fork_theSafeCanGovernEveryClassOfHandle` asserts that an increase from the Safe still
only *schedules*, so the delay survived the handover rather than being bypassed by the new
owner.

---

## Fee recipients did not move with ownership

`ProtocolFeeHook.feeRecipientOf` on every pool, and `LaunchFactory.protocolFeeRecipient`,
still point at the retired deployer `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9`, read back in
`deployments/mainnet-state.json`. A recipient is not an ownership handle: it cannot upgrade,
halt or reconfigure anything, and repointing it is a separate `onlyOwner` call.

`deployments/safe-batches/03-repoint-fee-recipients.json` is the prepared batch that moves the
ones worth moving. **Collect before repointing:** `ProtocolFeeHook.collect` pays whoever is
named when it runs, not when the fee accrued.

---

## Limits you should know

**No timelock, and no plan for one in this deployment.** Two signatures upgrade any proxy in
one transaction. There is no window in which a pending change can be read, argued with, or
cancelled. An integrator cannot pin behaviour by watching for an announcement, because for
upgrades there is no announcement to watch.

**A 2-of-3 compromise is total.** Two keys can repoint every reserve's yield source, move the
implementation behind every brand token, and set every fee to its ceiling after an hour. The
mitigation is key custody, not code.

**Ownership cannot be renounced** on `ProtocolGuard` or `SharedReservePool`; both override
`renounceOwnership` to revert. On the guard, renouncing would leave every guarded contract in
the protocol pointed at a registry whose resume path is permanently unreachable, with the
guardian key alone deciding whether the protocol ever runs again. `transferOwnership` is the
handover path, and it is two-step so a typo cannot land.
(`test_guardOwnershipCannotBeRenounced`, `test_ownershipTransfersInTwoStepsAndCannotBeDropped`)

**A hook's address is its permission bits.** `ProtocolFeeHook` lives at an address mined so
that its low 14 bits are `0x00CC`. Upgrading the implementation behind the proxy is fine, but
a *different* hook address means different pools: every live market would have to be
redeployed and reseeded. The hook is the one contract where the proxy is not a convenience.

**The gen-4 `MarketRouter` `0xcCDe2EcDE7072Efe61822551152663F204CF73ce` is still owned by the
retired key** and carries an unaccepted `pendingOwner` nomination to the Safe. It is a dead
UUPS proxy that no live manifest references, which is why the original address sweep missed
it. The nomination is inert because only the Safe can accept it. The residual risk, stated
rather than buried: someone holding the retired key could ship an implementation to a router
that still looks official. Accept the nomination if that ever matters.

---

## Pre-flight checklist

- [ ] `forge test --match-contract UpgradeInvariants` green, footprint unchanged or changed deliberately
- [ ] `forge test --match-contract UpgradeAndPause` green
- [ ] Fork rehearsal completed; proxy state read back identical afterwards
- [ ] New implementation deployed, and its constructor locked its initializer
- [ ] Exact target and calldata recorded before it goes to the Safe
- [ ] Two signers available and the transaction reviewed by the second, not just signed
- [ ] Implementation published to Sourcify (`script/verify-mainnet-sourcify.sh`)
- [ ] Post-execute: ERC-1967 slot re-read, and for a reserve, `totalAssets() >= totalPooledSupply()`
- [ ] `test/OwnershipMigrationMainnetFork.t.sol` updated if the upgrade added an owned handle
