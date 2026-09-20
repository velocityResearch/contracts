# Robinhood Chain mainnet runbook — asset markets, launchpad and the sUSDai group

Supersedes the gen-1 revision of this file, which documented `SplitterDeployer`, a two-step
`registerBrand`/`openMarket` flow, a six-transaction gas table and a timelock. None of that is
how this deploys any more, and there is no timelock at all.

**This file carries no addresses on purpose.** Two of the four gen-6 beacon addresses that were
recorded as live turned out to be orphans that nothing references, and they circulated as live
until they were checked against the chain. `deployments/asset-markets-mainnet-v6.json` is the
address book and the reasoning behind it; `deployments/mainnet-state.json` is a dated snapshot
read off chain 4663 and holds anything a getter can answer, including which implementation
sits behind every proxy and which beacons are actually wired. `deployments/README.md`
documents the split and notes that the generator that produced the snapshot is not in this
contracts-only tree. Read an address out of those, never out of prose.

Companions: `docs/MAINNET_READINESS_2026-09-16.md` is the historical snapshot of what was
blocking before the gen-6 deployment; `docs/MAINNET_RUNBOOK_2026-09-16.md` is the ordered
checklist. This file is the reference: what the stack is, how it upgrades, and who can change
what.

---

## 1. What deploys

Three layers, deployed in this order because each needs the previous one's addresses.

| Layer | Script | Chain |
|---|---|---|
| Reserve, guard, beacons, yield adapter | `DeploySharedReservePool.s.sol` | 4663 |
| Market factory, router, hook, zapper, **and the launchpad** | `DeployAssetMarkets.s.sol` with `DEPLOY_LAUNCHPAD=true` | 4663 |
| sUSDai hub | `DeploySUSDaiHub.s.sol` | 42161 |
| sUSDai reserve group | `DeploySUSDaiGroup.s.sol` | 4663 |

`DeploySharedReservePool.s.sol` takes `TIMELOCK_MIN_DELAY` and branches on it. Anything nonzero
deploys a `TimelockController` and gives it everything. **Zero deploys no timelock at all** and
leaves the deploying EOA owning the guard, the beacons, the adapter and the pool; the script
prints a loud warning when it takes that branch (`script/DeploySharedReservePool.s.sol:72-79`,
`:93`). Gen-6 was deployed on the zero branch, deliberately. Ownership has since moved to a
2-of-3 Safe, which removes the single-key risk but adds no delay. See section 5.

The launchpad is **not** a separate deployment any more. `DeployAssetMarkets.s.sol` takes a
`DEPLOY_LAUNCHPAD` flag, calls `ProtocolStack.deployLaunchpad` inline, and then makes the one
owner call that crosses into the market factory, `setLaunchpad`. `DeployLaunchpad.s.sol` still
exists for adding a launchpad to a market stack that already shipped without one.

`script/rehearse-mainnet.sh` runs the whole sequence against an anvil fork of 4663, with the
launchpad included, using the same runbook commands. Run it before any real deployment.

## 2. How a market is created

There is one path, and it is one call.

```
approveAsset(asset, listing)     # owner, once per asset
createMarket(asset, reserve)    # permissionless thereafter; zero reserve means the default
```

`_openMarket` does the rest in a fixed order, and the order is load-bearing: the v4 pool first
(the distributor records its key), then the vault and the distributor together (each needs the
other's address and only one of the two links can be an initialiser argument), then
`feeHook.registerPool`, then the oracle buffer, then the registry entry.

The gen-1 flow this file used to describe — `registerBrand` then `openMarket` as two owner
transactions — is gone. So is `MarketYieldSplitter`, and so is `SplitterDeployer`.

**The buyback is gone too.** `BuybackEngine` and `AssetLockbox` no longer exist. A market's
float yield is harvested by `BrandFeeVault` and streamed to the staked LPs through
`LpRewardDistributor`. Anything in older docs about float interest buying and locking the
traded asset describes a design that was removed.

## 3. How a launch reaches a market

```
launchToken(params, configId, pairToken, exemptions)   # or LaunchRouter.launchAndBuy, atomically with the first buy
  -> curve trades in a branded stablecoin
graduate(token)            # permissionless, drains the curve into the factory
graduateToMarket(token)    # permissionless, retryable, opens the market
```

Phase two hands the swept reserves to `LaunchGraduation`, which calls
`AssetMarketFactory.createLaunchMarket` — the launchpad-only entry point, gated on
`msg.sender == launchpad`. That is why `setLaunchpad` matters: without it every graduation
reverts `OnlyLaunchpad` and the launch sits in `Swept`, retryable but stuck.

Both phases are permissionless and phase two is all-or-nothing, so a failed graduation strands
nothing: the reserves stay in the factory and anyone can retry.

### What the deployed router exposes

`MarketRouter` was upgraded on gen-6 after the initial deployment, and **`sellForUsdg` is now
live**: `deployments/mainnet-state.json` records its selector `0xb9077071` under
`gen6.selectorPresence` with `presentInRuntimeCode: true`, alongside `buyWithUsdg`
(`0x6e973991`). An earlier revision of this file said the opposite, correctly at the time,
because the proxy then carried only its deploy-time `Upgraded` event.

The lesson survives the fix: **check `selectorPresence` rather than `src/` before telling an
integrator a function exists.** Source on the branch is not the same thing as runtime on the
proxy, and the gap is invisible from a compile.

`sellForBrand` (`0x4357400b`) followed by a separate `SharedReservePool.redeem` remains a valid
sell path and is what an integrator that wants to choose its own redemption bound should use,
since `redeem`'s three-argument overload is now strict.

## 4. Upgradeability — what can be fixed, and how

Three mechanisms, chosen per contract by what it holds.

### UUPS proxies — upgraded in place, keep their address and state

| Contract | Why in place |
|---|---|
| `SharedReservePool` | holds the reserve and every brand's ledger |
| `AssetMarketFactory` | holds the market registry |
| `MarketRouter` | holds standing Permit2 allowances |
| `ProtocolFeeHook` | **its address encodes its permission bits** — see below |
| `MorphoBlueYieldSource` | custodies the Morpho position |
| `SUSDaiYieldSource` | holds the buffer and the in-flight counters |
| `SUSDaiHub` (42161) | holds USDC and sUSDai |
| `StrategyGroupRegistry` | directory |
| `ProtocolGuard` | every guarded contract read its address at init |
| `LaunchFactory` | holds every launch record |

`ProtocolFeeHook` is the one that can never be replaced rather than upgraded. Uniswap v4 reads
a hook's permissions from the low 14 bits of its address, and a `PoolKey` names its hook, so
moving it would orphan every pool. Its address is mined so that its low 14 bits are `0xcc`, and
that is permanent.
**An upgrade must never change `getHookPermissions`**: ship a different set and the manager
keeps calling the callbacks the old bits named while the new code expects others, silently.

### Beacon proxies — one upgrade moves every instance at once

`PooledBrandToken`, `PoolBrandTreasury`, `BrandFeeVault`, `LpRewardDistributor`. There is one
of each per market, so they sit behind `UpgradeableBeacon`s and a single `upgradeTo` reaches
every market at once. Asserted by `test_oneBeaconUpgradeMovesEveryBrandAtOnce` in
`test/upgrade/UpgradeAndPause.t.sol`. All four beacons are owned by the Safe;
`test_fork_everySingleHandleIsOwnedByTheSafe` in `test/OwnershipMigrationMainnetFork.t.sol`
pins that against live state.

**Resolve the beacon you are about to upgrade from `deployments/mainnet-state.json`, never from
a document and never from an older manifest revision.** Two `UpgradeableBeacon`s on 4663 are
live, carrying their own implementations, and
`AssetMarketFactory.beacons()` references neither. They were recorded as the live fee-vault and
reward-distributor beacons until 2026-09-19. An `upgradeTo` aimed at one of them succeeds,
emits `Upgraded`, costs gas and moves zero live markets, which is worse than a revert because
it reads as a completed upgrade. The v6 manifest names both orphans under `openItems` so they
can be recognised and avoided.

### Plain contracts — replaced by redeploying and re-pointing

These hold nothing that a successor needs, so they are swapped rather than upgraded. Each has
a setter, and **none of those setters is one-shot**:

| Contract | Re-pointed by |
|---|---|
| `LaunchGraduation` | `LaunchFactory.setGraduation` + `AssetMarketFactory.setLaunchpad` |
| `LaunchDeployer` | `LaunchFactory.setLaunchDeployer` |
| `LaunchRouter` | `LaunchFactory.setLaunchForwarder` |
| `LaunchFeeEscrow` | `LaunchFactory.setFeeEscrow` |
| `LiquidityZapper` | no on-chain reference; redeploy and update the app config |
| `MarketDeployer` (library) | linked at factory deploy; a factory upgrade relinks it |

`setGraduation` and `setLaunchDeployer` **used to be one-shot** and were opened deliberately.
The lock bought nothing — `LaunchFactory` is a UUPS proxy whose `_authorizeUpgrade` is
`onlyOwner`, so an owner who wanted to repoint could already do it by shipping an
implementation that does — while costing the ability to replace a defective module without
redeploying the factory and abandoning every launch record in it. `LaunchGraduation`'s own
documentation says it was split out so it could be "replaced independently"; this is what
makes that true. Both setters still refuse a helper that names a different factory, and refuse
zero. Covered by `test_theFactorysWiringRotatesButTheLockersDoesNot`.

Swapping `LaunchFeeEscrow` does not strand anything: a balance is claimable from the escrow
that recorded it, gated on nothing but the claimant's own ledger entry, so old credits stay
claimable from the old contract forever and only new revenue moves.

### Deliberately immutable, with no swap path

| Contract | Why |
|---|---|
| `LaunchCurve`, `LaunchToken` | one per launch, terms frozen at creation; graduation drains them |
| `LaunchLocker` | holds the permanently locked LP positions. Its `setGraduation` **is** one-shot: repointing it would let a second module record positions against custody the first established |
| `LaunchGraduationGuard` | pure and stateless, deployed by `LaunchFactory.initialize`; a factory upgrade can point elsewhere |

### What cannot be re-pointed, by design

`AssetMarketFactory.marketFactory`-equivalents on the launch side — `marketFactory`,
`positionManager` — and the market factory's own `beacons` have no setters. These are venue
identity: changing the market factory would orphan every graduated market, changing the
PositionManager would break every distributor's custody, and repointing the beacons would move
the implementation behind live markets from the factory rather than through the beacon's own
owner. If any of them must change, that is a new deployment, not a setting.

## 5. Ownership

**Every owned contract uses `Ownable2Step`.** Transfer is two-step — nominate, then the
successor accepts — so a typo cannot hand the protocol to an address nobody controls.
Nomination alone changes no authority. Asserted by
`test_ownershipTransfersInTwoStepsAndCannotBeDropped` in `test/upgrade/UpgradeAndPause.t.sol`.

**`renounceOwnership` reverts on every contract that has an owner.** On a UUPS proxy
`_authorizeUpgrade` is `onlyOwner`, so dropping the owner freezes that implementation
permanently, over live funds, with no way to fix a defect. The consequence is worst on
`ProtocolGuard`: it owns every `unpause`, and `GuardedUpgradeable` has no setter for the guard
address its dependents read at initialisation, so an ownerless guard means the guardian key
alone decides whether the protocol ever runs again. `transferOwnership` is the handover path
everywhere.

### Who owns what today

**Custody is a Gnosis Safe, `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`** — v1.4.1, SafeL2
singleton, threshold **2 of 3**, none of whose signers is the retired deployer. It owns all
twelve two-step handles and all four beacons: both reserves, both yield adapters, the guard,
the market factory, the router, the fee hook, the launch factory, the launch locker, the
strategy registry, the abandoned gen-4 factory, and the four beacons behind
`PooledBrandToken`, `PoolBrandTreasury`, `BrandFeeVault` and `LpRewardDistributor`. No
`pendingOwner` is outstanding anywhere. `test/OwnershipMigrationMainnetFork.t.sol` asserts all
of that against live chain state, including that the retired key reverts on every owner-only
call it used to be able to make.

**The guardian is a separate hot key**, `0xc1d844d6478e450E62293882d2d6739c4a8693F9`, rotated
off the retired deployer. It can `pause` and `pauseTarget` and nothing else: `unpause`,
`unpauseTarget`, `setGuardian` and `_authorizeUpgrade` are all `onlyOwner`. So the asymmetry
the guard was designed for now actually exists on this deployment — a stolen guardian key buys
a denial of service that the Safe unwinds, and it cannot un-halt a drain in progress.

**There is still no timelock, and this is the honest limit.** Every `_authorizeUpgrade` in the
stack is a bare `onlyOwner`. Two signatures upgrade any proxy or move any beacon in a single
transaction, with no announcement, no window to read a pending change in, and nothing to
cancel. What the migration fixed is that one leaked key is no longer enough; what it did not
fix is that there is no delay. `docs/audit-history.md` carries the original single-key finding
as A3-CRITICAL-1. Two fee knobs do carry a one-hour announce-then-commit delay — the hook's
`setPoolFeePips` and the reserve's `setRedemptionFee`, increases only — and both survive the
handover (`test_fork_theSafeCanGovernEveryClassOfHandle`), but neither survives an upgrade, so
they are reliability guarantees for quoting integrators rather than security guarantees.

**Fee recipients did not move with ownership.** `ProtocolFeeHook.feeRecipientOf` per pool and
`LaunchFactory.protocolFeeRecipient` still point at the retired deployer. A recipient is not an
authority — it cannot upgrade, halt or reconfigure anything — and repointing it is a separate
`onlyOwner` call whose batch is prepared but unsent in
`deployments/safe-batches/03-repoint-fee-recipients.json`. Collect before repointing:
`ProtocolFeeHook.collect` pays whoever is named when it runs, not when the fee accrued.

What the chain reports for `owner()` and `pendingOwner()` on every proxy, `owner()` on every
beacon, and the guardian on the guard, is in `deployments/mainnet-state.json`. Read it there
rather than from any list, including this one: a pending nomination is one transaction away and
leaves no trace in a hand-written file.

Still open, and worth an auditor's attention:

| Role | Today | Wanted |
|---|---|---|
| Upgrade authority | 2-of-3 Safe, no delay | A delay, or a published change window, before third-party deposits scale |
| Guardian | separate hot key | Correct as is |
| Protocol fee recipients | the retired deployer EOA | The Safe, via the prepared batch |
| sUSDai hub owner (42161) | see `mainnet-state.json` | A multisig; a Robinhood-side owner could not reach it anyway |
| Keeper | a hot key with no custody | Correct as is: it may move value between protocol contracts and report, nothing else |

**Handing ownership over again.** `script/HandOverMainnetOwnership.s.sol` is hardcoded to the
gen-5 proxies and the abandoned gen-5 timelock (`:104-123`) and is not the path for anything
live. The pattern that works now is `script/RotateGuardianMainnet.s.sol`: validate hard, print
an exact transaction, broadcast nothing, and let the Safe sign it. `UPGRADING.md` has the full
procedure.

## 6. Pausing

`ProtocolGuard` is one registry every guarded contract reads, so a single `pause()` halts every
guarded contract at once, including markets that did not exist when the guard was written
(`src/upgrade/ProtocolGuard.sol:13-19`). The guardian may pause the whole protocol or a single
target instantly; only the owner may unpause, replace the guardian, or upgrade the guard
(`:97`, `:105`, `:113`, `:118`, `:123`, `:151`). The guardian and the owner are now different
addresses, so the asymmetry is real: the fast key can stop the protocol and cannot restart it.

Two surfaces are outside the pause and should be: `AssetMarketFactory` inherits
`GuardedUpgradeable` and then uses `whenNotPaused` nowhere, so `createMarket`, `registerBrand`
and `createMarketForBrand` all run during a global halt. That is an incident-response gap
rather than a theft, and it is carried as A3-MEDIUM-4 in `docs/audit-history.md`.

Pausing stops new exposure, not exits:

| Halted | Not halted |
|---|---|
| `mint`, `swap`, `claimYield`, `deployIdle` | **`redeem`** — no `whenNotPaused`, ever |
| `LaunchFactory.launchToken`, `graduateToMarket` | brand token transfers |
| `SUSDaiYieldSource.bridgeOut` | `SUSDaiYieldSource.withdraw` |
| `LaunchFactory.rescueSweptGraduation` | selling a curve back to its own quote brand |

The rescue path being pausable is deliberate and worth understanding: what legitimises its
7-day window is that seeding stays permissionless throughout, so any holder can end the window
early. A guardian who could pause seeding while sweeps kept accumulating would hand the owner
a guaranteed harvest. Making the rescue `whenNotPaused` keeps the guardian's only power a
denial of service.

## 7. Operational notes that cost real time to learn

**`forge` hangs on mainnet scripts unless Sourcify is short-circuited.** The trace contains
PoolManager, PositionManager and Permit2, none of which are in local artifacts, so forge tries
to label them through sourcify.dev and that request never returns. `--disable-labels` does not
stop it. What works:

```
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
```

Needed for `DeployAssetMarkets.s.sol`. Not needed for `PreflightMainnet.s.sol` or
`VerifyAssetMarketsMainnet.s.sol`.

**Do not run a standalone simulation of the market-layer step.** `--broadcast` already
simulates the entire script, including the post-deploy wiring and venue assertions, and sends
nothing if any of it fails. A bare `forge script` without `--broadcast` is redundant and hangs
the same way.

**The rehearsal writes to `broadcast/<script>/4663/`** — the same directory that holds the
record of the real deployment. `rehearse-mainnet.sh` redirects `FOUNDRY_BROADCAST` to a temp
directory for exactly this reason. Do not remove that.

**Verification goes through Sourcify, not Blockscout.** The Blockscout instance sits behind a
Cloudflare challenge that `forge verify-contract --verifier blockscout` cannot clear, so
`--verify` is not a step this runbook promises. `script/verify-mainnet-sourcify.sh` publishes
standard-JSON input to Sourcify instead, which Blockscout then imports; the live contracts came
back `exact_match`. `DEPLOYMENT.md` has the full reasoning, including why `foundry.toml` must
not regain an `[etherscan]` block.

## 8. Before real float arrives

- A delay on upgrades, or a published change window. Custody is a 2-of-3 Safe, which is a real
  improvement on the single key this originally said, but two signatures still upgrade any
  proxy in one transaction (§5).
- `PreflightMainnet.s.sol` passing — it asserts every hardcoded integration address against
  the live chain, including that the PositionManager reports the same PoolManager singleton
  every market will be created in.
- For the sUSDai group: one controlled Across round trip completed end to end before any float
  accumulates. A keeper that cannot complete a round trip is a reserve that cannot honour a
  redemption at par. The Base Sepolia rehearsal did this and its accounting is recorded in
  `deployments/asset-markets-base-sepolia.json`.
- Morpho utilisation checked. `SharedReservePool._recallIfNeeded` pulls on demand and reverts
  at 100% utilisation, and there is no idle-buffer policy.
- Regulatory counsel on "float interest funds LP rewards". Not obtained.

`deployments/asset-markets-mainnet-v6.json` keeps the authoritative version of this list under
`openItems`, and it is longer than the five above. Check it rather than this section before
claiming anything is clear.
