# Graduate-into-launch-dollar runbook — mainnet

Companion to [`GRADUATE_INTO_LAUNCH_DOLLAR.md`](./GRADUATE_INTO_LAUNCH_DOLLAR.md). That document
says *what* and *why*; this one is the ordered sequence, the checks either side of it, and what
cannot be undone.

Every step is either **[you]** — a plain transaction from the deployer EOA, which needs only gas —
or **[Safe]** — an owner call, which needs two of three signatures. Nothing here is behind a
timelock: the v6 stack was deployed with `SAFE_MIN_DELAY=0`, so a Safe call lands the moment the
second signature is collected.

Rehearsed end to end against live mainnet state by `test/LiveGen5Mainnet.t.sol`, which pranks the
Safe and performs this exact sequence. Re-run it before you start if anything in `src/` has
changed since.

> **This release is now two changes on one tree.** `feature/keeper-lp-fees` was merged into
> `staging/main` behind this work (`894d1075`), so the same implementations carry keeper-set
> dynamic LP fees, segmented launch curves and capital-weighted LP staking from `origin/main`.
> Every size in P1 and step 2 was measured before that merge and **must be re-measured**; the
> slot numbers in step 4 have grown and are restated in §11; and there is a sixth
> implementation, `ProtocolFeeHook`, with its own proxy and its own Safe calls. Read §11 before
> step 2, and run the whole of it after step 10.

---

## Who signs what, and why that is not what the script assumes

`script/UpgradeGraduateIntoLaunchDollarMainnet.s.sol` requires `DEPLOYER` to own both proxies,
all three beacons, and every quote brand's treasury. **That is no longer true of any key you
hold.** Since the custody migration the owner of both proxies, all three beacons, both reserves
and the guard is the 2-of-3 Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, and AIUSD's
treasury admin is the same Safe. The deployer EOA `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9`
owns nothing except gas.

So the script is a **fork rehearsal tool, not a mainnet broadcast**. On mainnet, the deploys are
EOA transactions and every `upgradeToAndCall`, `upgradeTo`, `set*` is a Safe transaction. The
steps below are written that way. The repository's convention for a Safe batch is
`deployments/safe-batches/`; each `[Safe]` step prints the exact calldata to paste into the Safe
Transaction Builder.

---

## Addresses

| | |
|---|---|
| Owner Safe, 2-of-3 | `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` |
| Deployer EOA (gas only) | `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` |
| `LaunchFactory` proxy | `0x95fe000285DA7797cC01394cCc410628B26e898d` |
| `AssetMarketFactory` proxy | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| `PoolBrandTreasury` beacon (both reserves) | `0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E` |
| `BrandFeeVault` beacon | `0x65876276feE875e1A120F63575150593E6AEa0d3` |
| `LpRewardDistributor` beacon | `0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6` |
| `LaunchGraduation`, live | `0xF5f4Eb45347ec69CB56D1c682a0FdA83bb9f4efC` |
| `LaunchLocker`, live, **holds nothing** | `0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C` |
| `LaunchLocker` holding markets 16/17/18 | `0xACf51B066b90596e8536A1423Df4A6b94D5815c9` |
| `LaunchDeployer`, live — **still serves this tree**, nothing to do | `0x7979708A371E9f9dDb43A432595c3F59f77dd5E7` |
| `LaunchFeeEscrow` | `0xb1BeEbb3c077705273bcC4F80f560F43941205b6` |
| v4 `PositionManager` | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| sUSDai reserve | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` |
| AIUSD | `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` |
| AIUSD treasury (admin = the Safe) | `0xE2d144F8b18d4743fdC4D74e4AE621307e443e38` |
| slUSD (**not factory-registered**, therefore not launchable) | `0xE20cE31a996f07b3d70F9C840e6810F0f572C884` |
| Market 16 / 17 / 18 tokens | `0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C` / `0x2165962eb8BF56354bF7053071E515dC9818DfbF` / `0x17A5C7E9293199271f985eDAC74366015DA96FaD` |

Paste this once per shell; every command below uses it.

```
export R=https://rpc.mainnet.chain.robinhood.com SAFE=0x28569c1716EF81f307d666A1EC08bDAE92AC0373 LF=0x95fe000285DA7797cC01394cCc410628B26e898d AMF=0x22AA61c589B90731752236c07d1455D0065bfc79 TB=0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E VB=0x65876276feE875e1A120F63575150593E6AEa0d3 DB=0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6 OLDLOCKER=0xACf51B066b90596e8536A1423Df4A6b94D5815c9 AIUSD=0xE7BB388959d89f809BE24da16A1DaBa0dC58E596 AIUSD_TREASURY=0xE2d144F8b18d4743fdC4D74e4AE621307e443e38 SLUSD=0xE20cE31a996f07b3d70F9C840e6810F0f572C884 SUSDAI_RESERVE=0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2 POSM=0x58daec3116aae6D93017bAAea7749052E8a04fA7 PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 ESCROW=0xb1BeEbb3c077705273bcC4F80f560F43941205b6
```

`forge` hangs on mainnet scripts unless Sourcify is short-circuited — it tries to label
PoolManager/PositionManager/Permit2 through sourcify.dev and that request never returns. It looks
exactly like a chain problem and is not. Export this before any `forge create`:

```
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
```

---

## 0. Preconditions

Each of these is read-only. Run all nine before the first broadcast; P5a is a note rather than a
check. A failure here is cheap; the same failure at step 5 is not.

### P1 — the tree builds, and both tight contracts are under EIP-170

```
forge build --sizes --skip test | grep -E "AssetMarketFactory|LaunchFactory |LaunchGuardDeployer"
```

Expect `AssetMarketFactory 24,365 … 211`, `LaunchFactory 20,287 … 4,289`,
`LaunchGuardDeployer 3,203`. Any different number means the tree moved since this runbook was
written; re-read the watch list at the end before continuing. **`AssetMarketFactory`'s margin is
211 bytes** — the spacing ladder spent the difference against the 472 an earlier revision
quoted. `LaunchFactory`'s 4,289 is not slack to spend either: it is the whole of what moving
`LaunchGraduationGuard`'s creation code into `LaunchGuardDeployer` bought.
`--skip test` hides `Probe_AssetMarketFactory`, the test contract that inherits the factory; it
is tighter still at 24,406 (170 bytes) and so fails before anything deployable does. Drop
`--skip test` if an addition to that contract is what you are checking.

### P2 — the offline suite is green

```
forge test --no-match-path 'test/*Fork*'
```

Expect **742 passed, 0 failed, 2 skipped**.

### P3 — the live rehearsal is green

```
forge test --match-path test/LiveGen5Mainnet.t.sol --fork-url $R --threads 1
```

Expect **17 passed**. This file performs the whole sequence below against live mainnet state,
including `test_live_theLiveLaunchDeployerStillServesAFactoryFromThisTree`, which runs the
rollout *without* rotating the launch deployer and then launches a token through the live one
(`test/LiveGen5Mainnet.t.sol:1159-1177`). That is the assertion behind P5.

### P4 — no launch is in `Swept`

A `Swept` launch is waiting on a permissionless `graduateToMarket` retry, and that retry calls
the `createLaunchMarket` whose signature step 4 replaces. Leaving one open turns a two-phase
operation into a stuck one.

```
for i in $(seq 0 $(( $(cast call $LF 'launchCount()(uint256)' --rpc-url $R) - 1 ))); do t=$(cast call $LF 'launchAt(uint256)(address)' $i --rpc-url $R); echo "$i $t phase=$(cast call $LF 'getLaunchedToken(address)((address,address,address,address,address,address,uint256,uint24,uint16,uint16,uint8,uint256,uint256,uint256,uint256,bool))' $t --rpc-url $R | cut -d, -f11 | tr -d ' ')"; done
```

Expect every `phase=` to read `0` (`NotGraduated`) or `2` (`Graduated`). **Any `1` blocks the
rollout** — clear it first with `cast send $LF 'graduateToMarket(address)' <token>`, which anyone
may call. At the time of writing the answer is `0 0 2 2 2 0 0 0 0` across nine launches.

### P5 — the live `LaunchDeployer` does NOT serve this tree: the rotation is back

```
echo "6508e7ac in live deployer: $(cast code 0x7979708A371E9f9dDb43A432595c3F59f77dd5E7 --rpc-url $R | grep -o 6508e7ac | wc -l)   in this tree's curve: $(jq -r .deployedBytecode.object out/LaunchCurve.sol/LaunchCurve.json | grep -o 6508e7ac | wc -l)"
```

Expect `0` and a **non-zero** count. `0x6508e7ac` is the segmented
`LaunchCurve.initialize(address,(uint16,uint32)[])`, which every `LaunchFactory` built from
this tree calls; the live deployer embeds a curve whose only entry point is the one-argument
`initialize(address)` (`0xc4d66de8`), so a factory from this tree calling it dies in the
curve's dispatcher with no revert data, on every launch. Step 11i deploys the deployer and
rotates the factory onto it; `LaunchFactory.setLaunchDeployer` re-checks
`deployer.factory() == address(this)` itself.

### P5a — the history of this step, kept on the record

The graduate-into-launch-dollar branch was cut without the concentrated-liquidity stack and
deleted this step, pinning "the live deployer still serves this tree" as a live test. The
merge with `origin/main` (`894d1075`) brought segmented curves onto the same tree, so that
assertion flipped: `test/LiveGen5Mainnet.t.sol`
`test_live_upgradingTheLaunchFactoryWithoutItsDeployerBreaksEveryNewLaunch` now performs the
rollout one call short, shows `launchToken` fail, rotates the deployer and shows it succeed.
A curve already deployed is untouched by the rotation; it governs launches created after it.

### P6 — the old locker pays today, and you have the numbers to compare against

This is the baseline half of the critical finding's regression check. `collect` is
state-changing, so `cast call` simulates it without sending.

```
for t in 0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C 0x2165962eb8BF56354bF7053071E515dC9818DfbF 0x17A5C7E9293199271f985eDAC74366015DA96FaD; do echo "$t -> $(cast call $OLDLOCKER 'collect(address)(uint256,uint256)' $t --rpc-url $R | tr '\n' ' ')"; done
```

Expect three lines, each two non-reverting numbers — a quote-leg amount and a token-leg amount.
Record them. They must still be produced after step 7; see post-condition C4.

### P7 — `slUSD` is already refused, and nothing has to be done about it

`slUSD` was registered straight onto the sUSDai reserve rather than through the market factory,
so the market factory holds no treasury and no reserve for it. Launch collateral is keyed by
reserve now and the per-brand conditions are read at launch time, so this is a read-only check
rather than the owner transaction it used to be.

```
echo "treasuryOfBrand=$(cast call $AMF 'treasuryOfBrand(address)(address)' $SLUSD --rpc-url $R) reserveOfBrand=$(cast call $AMF 'reserveOfBrand(address)(address)' $SLUSD --rpc-url $R)"
```

Expect both to be zero. That is slUSD being refused: `reserveOfBrand(slUSD) == 0` makes
`LaunchFactory.launchEconomics(slUSD)` revert `PairTokenNotRegistered`
(`LaunchFactory.sol:1416`, reached through `_quoteReserve` at `:1414`) before any figures are
read, so there is no approval to take off and no way for the sUSDai reserve's economics to reach
slUSD. Step 3 verifies the same thing after the upgrade. If both addresses are already non-zero,
somebody registered slUSD properly in the meantime and it is a normal quote brand — it needs its
issuer's `setFactory` opt-in (step 8) and nothing else, because the sUSDai reserve's economics
already cover it.

### P8 — every authority is where this runbook says it is

```
for p in $LF $AMF $TB $VB $DB; do echo "$p owner=$(cast call $p 'owner()(address)' --rpc-url $R)"; done && echo "AIUSD treasury admin=$(cast call $AIUSD_TREASURY 'admin()(address)' --rpc-url $R)"
```

Expect all six to be the Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`. If a beacon answers
anything else, the beacon steps need a different signer and the whole sequence needs re-planning.

### P9 — gas

```
cast balance 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9 --rpc-url $R --ether
```

Eight deploys — the library, five implementations, the locker and the graduation module. The
largest is the `AssetMarketFactory` implementation at 24,365 runtime bytes. **0.02 ETH** is
comfortable at Robinhood's 0.099–0.304 gwei; the Safe pays its own gas separately.

---

## Ordering hazards

Read these before executing. Five hazards; four of them will not announce themselves — H4 joined
that set when its check moved from owner time to launch time.

**H1 — graduation is CLOSED from step 4 until step 7, and that window is real.** Step 4
replaces `AssetMarketFactory.createLaunchMarket`, whose signature changed, while the graduation
module wired right now still calls the old one — so from the first of the two
`upgradeToAndCall`s until `setLaunchpad` lands, every `graduateToMarket` reverts. Curves keep
trading and keep filling, and a curve that crosses its threshold inside the window sweeps into
the launch factory and waits; recoverable, but only once step 7 lands. **Plan steps 4 through 7
as one sitting and do not leave the window open across a weekend.** This is also why P4 exists:
a launch already in `Swept` when you start is stuck for the whole window rather than part of it.

**H2 — the treasury beacon must be upgraded before any `setFactory`.** `setFactory` does not
exist on the `PoolBrandTreasury` implementation mainnet is running today; calling it before
step 5 reverts with no data. Verify with
`cast call $AIUSD_TREASURY 'factory()(address)' --rpc-url $R`, which reverts before step 5 and
returns the zero address after it.

**H3 — `setLpFundRecipient` must precede `setGraduatedLpFundShareBps`.** Every share setter
refuses a non-zero rate while `lpFundRecipient` is unset (`LaunchFactory.sol:863`, and `:791`
for `setLpFundShareBps`). The live recipient is already the protocol treasury, so today this is
a re-assertion rather than a first write — but if a rollback ever zeroes it, the order becomes
load-bearing again.

**H4 — the per-brand float-share opt-in is now a live read, so a missing one is silent in
production instead of loud at the Safe.** Two things moved at once and they pull in opposite
directions.

What moved *out* of owner time: launch terms are keyed by **reserve** now. Step 10's
`setReserveEconomics` names a reserve and reads no brand at all
(`LaunchFactory.sol:704`, `:692-703` for why), so it cannot fail on, warn about, or tell you
anything at all concerning AIUSD's opt-in. The old `setPairTokenEconomics` did — that call is
retired, not aliased, and the check it used to carry went with it.

What moved *into* launch time: the opt-in itself is still mandatory and still per **brand**.
`_quoteReserve` (`LaunchFactory.sol:1414-1425`) re-reads
`PoolBrandTreasury(marketFactory.treasuryOfBrand(pairToken)).factory()` on **every single read**
— `launchToken`, `previewLaunchEconomics`, `launchEconomics` and therefore every router quote —
and reverts `PairTokenFloatShareUnavailable` (`:1421-1424`) when it does not name the market
factory. That is strictly tighter than the old one-time approval: an issuer who revokes with
`setFactory(0)` stops quoting new launches in the same block, where before a stale approval
would have stood.

The operational consequence is the whole of this hazard. A brand whose issuer has not opted in
used to be an owner transaction that refused to land; it is now a brand that configures
perfectly and quietly refuses every launch, with the creator's failed transaction as the only
notice anybody gets. **Keep step 8 before step 10 anyway** — the ordering costs nothing — and
assert the result in C3 rather than trusting it.

**H5 — the `LaunchGuardDeployer` library must be deployed and verified before the `LaunchFactory`
implementation.** The implementation `DELEGATECALL`s it from `initialize`. An unlinked build
simulates cleanly all the way through `upgradeToAndCall`, because the live proxy is already
initialised and nothing in the upgrade touches the dead delegatecall — the breakage surfaces only
on the *next* fresh deployment, months later. Step 1a and its check exist for exactly this.

---

## 1. [you] Deploy `LaunchGuardDeployer`, then check it before anything links against it

### 1a — deploy the library

```
forge create src/launchpad/libraries/LaunchGuardDeployer.sol:LaunchGuardDeployer --rpc-url $R --private-key 0x... --broadcast
```

Record the address as `LGD`, then `export LGD=0x...`.

### 1b — the code-hash check (H5)

The library embeds its own address as an immutable at byte offset 38, so a raw hash will not
match the artifact. Mask that one slot and compare:

```
[ "$(cast code $LGD --rpc-url $R | sed -E "s/^(.{78}).{64}/\1$(printf '0%.0s' $(seq 1 64))/")" = "$(jq -r '.deployedBytecode.object' out/LaunchGuardDeployer.sol/LaunchGuardDeployer.json)" ] && echo MATCH || echo MISMATCH
```

Expect `MATCH`. For this tree the masked runtime hashes to
`0x4c700222eaac0cbb1ec76f0df2f477053ed368dccae8d4fe05ad2af1395b93b8` and is 3,203 bytes; recompute
rather than trusting the literal, since it moves with any compiler or source change. On
`MISMATCH`, stop — you are about to link a `LaunchFactory` implementation against something that
is not this library, and no later step will notice.

---

## 2. [you] Deploy the five implementations

Nothing is wired by these; they are inert until a Safe call points at them. Deploy all five,
then collect the addresses.

`AssetMarketFactory` links against `MarketDeployer`, exactly as it does today.
**`MarketDeployer.sol` is untouched on this branch, so pin the live library rather than letting
`forge` auto-deploy a second copy** — the executable body of
`0xbd7706Ffa5856232C3d64dE6269cc78c13229bdf` is byte-identical to a compile of this tree, and
only the two embedded metadata hashes differ, because its imports changed even though its own
source did not. Confirm before pinning:

```
[ "$(cast code 0xbd7706Ffa5856232C3d64dE6269cc78c13229bdf --rpc-url $R | sed -E "s/^(.{80}).{64}/\1$(printf '0%.0s' $(seq 1 64))/" | sed -E 's/a264697066735822.*//')" = "$(jq -r '.deployedBytecode.object' out/MarketDeployer.sol/MarketDeployer.json | sed -E 's/a264697066735822.*//')" ] && echo MATCH || echo MISMATCH
```

Expect `MATCH`. The `sed`s mask the library's own-address immutable (byte offset 39) and cut
everything from the first CBOR metadata marker. On `MISMATCH`, `MarketDeployer`'s logic really
did change: drop the `--libraries` flag below, let forge deploy a fresh one, and record it.

```
forge create src/markets/AssetMarketFactory.sol:AssetMarketFactory --libraries src/markets/MarketDeployer.sol:MarketDeployer:0xbd7706Ffa5856232C3d64dE6269cc78c13229bdf --rpc-url $R --private-key 0x... --broadcast
```

```
forge create src/launchpad/LaunchFactory.sol:LaunchFactory --libraries src/launchpad/libraries/LaunchGuardDeployer.sol:LaunchGuardDeployer:$LGD --rpc-url $R --private-key 0x... --broadcast
```

```
forge create src/pool/PoolBrandTreasury.sol:PoolBrandTreasury --rpc-url $R --private-key 0x... --broadcast
```

```
forge create src/markets/BrandFeeVault.sol:BrandFeeVault --rpc-url $R --private-key 0x... --broadcast
```

```
forge create src/markets/LpRewardDistributor.sol:LpRewardDistributor --rpc-url $R --private-key 0x... --broadcast
```

Export them: `export AMF_IMPL=0x... LF_IMPL=0x... PBT_IMPL=0x... BFV_IMPL=0x... LPRD_IMPL=0x...`

Sanity-check that each has code and the right size before handing anything to the Safe:

```
for c in $AMF_IMPL $LF_IMPL $PBT_IMPL $BFV_IMPL $LPRD_IMPL; do echo "$c $(cast codesize $c --rpc-url $R)"; done
```

Expect `24365`, `20287`, `5247`, `5452`, `8980` in that order — the same runtime sizes
`forge build --sizes` reports in P1, measured off `out/<file>/<Contract>.json`.

---

## 3. [you] Confirm `slUSD` is refused — no transaction

There is nothing to send here. Under per-brand collateral this was a Safe call,
`setPairTokenApproved(slUSD, false)`, batched ahead of step 4; that function is retired and the
stale per-brand approval it existed to take off is no longer readable by anything. slUSD is
refused structurally instead, so this step is one read and a signature saved.

```
echo "reserveOfBrand=$(cast call $AMF 'reserveOfBrand(address)(address)' $SLUSD --rpc-url $R) treasuryOfBrand=$(cast call $AMF 'treasuryOfBrand(address)(address)' $SLUSD --rpc-url $R)"
```

Expect both to be zero, the same as P7. Run it again after step 4 as post-condition C8, where
`launchEconomics(slUSD)` itself is the assertion.

---

## 4. [Safe] The two proxies

Both carry **empty** calldata, deliberately: nothing was added, moved or retyped that needs an
initialiser. `AssetMarketFactory` gained `launchFloatOf` at slot 25 and `LaunchFactory` gained
`reserveEconomics` at slot 18 — its retired per-brand mapping is left in place at slot 13 as an
unread placeholder rather than repurposed. `LpRewardDistributor` gained three slots,
`rewardsRenounced` (22), `minStakeWeight` (23) and the private `_floorSet` (24). All are
appended below existing state with each `__gap` shrunk to match, so no live slot moves. The
spacing ladder added no storage at all. `test/upgrade/GraduateIntoLaunchDollarLayout.t.sol` is
the authority for every one of those numbers; do not carry them over from an older revision.

```
cast calldata 'upgradeToAndCall(address,bytes)' $AMF_IMPL 0x
```

Target: `AssetMarketFactory` `0x22AA61c589B90731752236c07d1455D0065bfc79`.

```
cast calldata 'upgradeToAndCall(address,bytes)' $LF_IMPL 0x
```

Target: `LaunchFactory` `0x95fe000285DA7797cC01394cCc410628B26e898d`.

**From the moment the first of these lands, graduation is closed (H1).**

---

## 5. [Safe] The three beacons

One `upgradeTo` each, however many proxies hang off them. Both reserves share the one treasury
beacon today; nothing enforces that, so check rather than assume:

```
echo "usdg=$(cast call 0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3 'treasuryBeacon()(address)' --rpc-url $R) susdai=$(cast call $SUSDAI_RESERVE 'treasuryBeacon()(address)' --rpc-url $R)"
```

Expect both to be `0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E`. If they differ, the treasury
beacon step is two transactions, not one.

```
cast calldata 'upgradeTo(address)' $PBT_IMPL
```

Target: treasury beacon `0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E`.

```
cast calldata 'upgradeTo(address)' $BFV_IMPL
```

Target: fee-vault beacon `0x65876276feE875e1A120F63575150593E6AEa0d3`.

```
cast calldata 'upgradeTo(address)' $LPRD_IMPL
```

Target: distributor beacon `0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6`.

---

## 6. [you] Deploy the locker and the graduation module

Order is forced: the graduation module takes the locker as a constructor argument, and the
locker's `setGraduation` is one-shot.

```
forge create src/launchpad/LaunchLocker.sol:LaunchLocker --constructor-args $SAFE $LF --rpc-url $R --private-key 0x... --broadcast
```

`export LOCKER=0x...` — note the first constructor argument is the **Safe**, because
`setGraduation` in step 7 is `onlyOwner`.

```
forge create src/launchpad/LaunchGraduation.sol:LaunchGraduation --constructor-args $LF $AMF $POSM $PERMIT2 $LOCKER $ESCROW --rpc-url $R --private-key 0x... --broadcast
```

`export GRAD=0x...`, then:

```
echo "grad.factory=$(cast call $GRAD 'factory()(address)' --rpc-url $R) grad.locker=$(cast call $GRAD 'locker()(address)' --rpc-url $R) locker.owner=$(cast call $LOCKER 'owner()(address)' --rpc-url $R) locker.graduation=$(cast call $LOCKER 'graduation()(address)' --rpc-url $R)"
```

Expect the launch factory, `$LOCKER`, the Safe, and the zero address respectively.

---

## 7. [Safe] The three wiring calls — this is what reopens graduation

All three in one batch, in this order.

```
cast calldata 'setGraduation(address)' $GRAD
```

Target: the **new locker** `$LOCKER`. One-shot; a second call reverts `AlreadyInitialized`.

```
cast calldata 'setGraduation(address)' $GRAD
```

Target: `LaunchFactory` `0x95fe000285DA7797cC01394cCc410628B26e898d`.

```
cast calldata 'setLaunchpad(address)' $GRAD
```

Target: `AssetMarketFactory` `0x22AA61c589B90731752236c07d1455D0065bfc79`.

If `AssetMarketFactory.launchpad()` and `LaunchFactory.graduation()` ever disagree, phase two of
every graduation reverts `OnlyLaunchpad`. Post-condition C1 checks exactly that.

---

## 8. [Safe] The issuer opt-in, per quote brand

AIUSD only, today. **AIUSD's treasury admin is the Safe itself** — verified live, not assumed — so
the Safe performs this call as the issuer rather than asking anyone. A third-party brand would
have to make this call itself; `setFactory` is `onlyAdmin` and nothing the protocol owns can
substitute for it.

```
cast calldata 'setFactory(address)' $AMF
```

Target: AIUSD's treasury `0xE2d144F8b18d4743fdC4D74e4AE621307e443e38`.

This is **one-way**: `0x22AA61…` becomes AIUSD's `namedFactory` and is the only non-zero address
the treasury will ever accept again. `address(0)` stays available as an off switch and
`namedFactory` as the way back, but a second, different factory is refused forever
(`FactoryAlreadyNamed`). Make sure `$AMF` is the market factory proxy and not an implementation
before signing.

---

## 9. [Safe] The rates — recipient first (H3)

All three are already at target on the live factory (`lpFundRecipient` = the protocol treasury,
`graduatedLpFundShareBps` = 3000, `graduatedCreatorShareBps` = 4000). They are re-asserted so a
run configures the whole split rather than half of it, and so a drifted value is corrected rather
than discovered by the first `collect`.

```
cast calldata 'setLpFundRecipient(address)' 0x28569c1716EF81f307d666A1EC08bDAE92AC0373
```

```
cast calldata 'setGraduatedLpFundShareBps(uint16)' 3000
```

```
cast calldata 'setGraduatedCreatorShareBps(uint16)' 4000
```

Target for all three: `LaunchFactory` `0x95fe000285DA7797cC01394cCc410628B26e898d`.

`setGraduatedLpFundShareBps` is bounded against `graduatedCreatorYieldShareBps` as well as
`graduatedCreatorShareBps` — `4000 + 3000 <= 10000` on both counts
(`LaunchFactory.sol:860-862`). The yield-rate bound is belt-and-braces today:
`MAX_LP_FUND_SHARE_BPS` is 5,000 (`LaunchFactory.sol:87`), so `4000 + bps` can never reach
10,000 through this setter. Keep it anyway. The locker holding markets 16/17/18 reverts
`ShareTooHigh` when the yield rate plus the fund rate exceeds a whole leg, that locker is not
upgradeable, and the day somebody raises `MAX_LP_FUND_SHARE_BPS` the bound stops being
decoration and starts being the only thing between an owner transaction and three permanently
uncollectable positions.

---

## 10. [Safe] `setReserveEconomics`, once per reserve (H4)

This write is mandatory, not a re-assertion: the mapping it fills is new storage, so every
reserve reads zero — which is closed — until it lands. One call per **reserve**, not one per
quote brand; every brand of the reserve then launches on these figures with no further owner
action, and a dollar issued on it tomorrow needs none either.

The sUSDai reserve, at AIUSD's live figures (`phantomQuote` 3,236e6, `graduationThreshold`
8,090e6, `launchFee` 1e6, 6 decimals, approved):

```
cast calldata 'setReserveEconomics(address,(uint256,uint256,uint256,uint8,bool))' $SUSDAI_RESERVE "(3236000000,8090000000,1000000,6,true)"
```

Target: `LaunchFactory` `0x95fe000285DA7797cC01394cCc410628B26e898d`.

`decimals` must equal `SharedReservePool(reserve).assetDecimals()` or the call reverts
`ReserveEconomicsInvalid` (`LaunchFactory.sol:719-721`); sUSDai reports 6. The reserve must also
be the market factory's default or an `approvedReservePool`, else `ReserveNotApproved`
(`:715-718`). No brand is named or read anywhere in this function, so it cannot tell you
anything about AIUSD or slUSD — that is H4, and C3 is where the float-share opt-in gets
asserted. `setReserveApproved(reserve, bool)` (`:735`) is the same switch without the figures.

There is nothing to run for slUSD, and nothing that would admit it: it is not registered
through the market factory, so it never reaches this reserve's figures. Admitting it means
registering it through the market factory and having its issuer opt into float sharing, which
is a separate piece of work — and needs no launchpad owner transaction once done.

---

## 11. [you + Safe] Keeper-set LP fees, on the same release

What `feature/keeper-lp-fees` adds, and what the merge with `origin/main` changed in the
contracts this runbook already upgrades. Design and limits: [`FABLES_DYNAMIC_FEES.md`](./FABLES_DYNAMIC_FEES.md);
operating the keeper: [`FABLES_KEEPER.md`](./FABLES_KEEPER.md); evidence:
[`FABLES_VERIFICATION.md`](./FABLES_VERIFICATION.md). The Kyber PR (#1699) and the 0x packet
(`docs/0x/`) already describe this behaviour as "markets created from 2026-09-21 on"; keep that
date honest by sending §"Who must be told" only after 11d lands.

### 11a — what changed in the implementations you are already deploying

| Contract | Beyond this runbook's description | Layout, in addition to step 4 |
|---|---|---|
| `LaunchFactory` | Segmented curves: `addLaunchConfig(config, segments)`, `updateLaunchConfig(id, config, segments)`, `getLaunchConfigSegments`. Reserve economics as described here. | `_launchConfigSegments` at **slot 19**, below `reserveEconomics` (18); `__gap` is 38. Footprint still 58. |
| `LpRewardDistributor` | Any range may stake, weighted by capital at the hook's 30-minute TWAP (`stakedWeightOf`, `weightForPosition`). The renounced stream and floor as described here, **with `minStakeWeight` measured in weight, not liquidity** — a narrow band buys liquidity for free and would walk under a liquidity floor. | The five weighting slots (`_stakedWeight` 25, `_stakedWeightOfPosition` 26, `weightsActivatedAt`+`legacySqrtPriceX96` 27, `weightEpoch` 28, `totalStakedLiquidity` 29) below the three at 22–24; `__gap` is 32. Footprint still 62. |
| `AssetMarketFactory` | `tickSpacingForFee(0x800000)` returns 50: an approval may now name Uniswap's dynamic-fee flag. | No storage change beyond this runbook's. |
| `ProtocolFeeHook` (**new to this release**) | `setFeeKeeper(address)`, `setPoolLpFee(PoolKey,uint24)` bounded 100–50,000 pips, registration seeds a `0x800000` pool at 5,000. Skim, cap and one-hour notice unchanged. | `feeKeeper` at **slot 10**, below the live `pendingFeePipsOf` (8) and `feePipsEffectiveAt` (9). No gap in this contract. |

`test/upgrade/GraduateIntoLaunchDollarLayout.t.sol` and `test/markets/DynamicFeeHook.t.sol`
(`test_upgradeFromExactDeployedLayoutPreservesEveryOriginalSlot`) are the authorities; the
numbers above are restated from them, not the other way round.

**One behaviour to know before step 5.** A live distributor that already holds full-range
stakes converts them to capital weight on its first state change after the beacon upgrade
(`_activateWeights`, emitting `WeightsActivated`), priced at the hook's TWAP with a spot
fallback. It is one-shot and lazy: nothing happens at upgrade time, and every account converts
at the same recorded price when it is next touched. Rewards already earned are settled on the
old basis first. Markets 16/17/18's locked positions convert the same way.

### 11b — [you] re-measure, then deploy the sixth implementation

Measured on the merged tree at `e85dfbb0` (`forge build --sizes`): `AssetMarketFactory`
**24,375** (201 to spare — the dynamic-flag branch in `tickSpacingForFee` cost 10 of the 211),
`LaunchFactory` **23,201** (1,375 to spare), `PoolBrandTreasury` 5,247, `BrandFeeVault` 8,224,
`LpRewardDistributor` 12,543, `ProtocolFeeHook` 14,024, `LaunchDeployer` 20,470,
`LaunchLocker` 5,027, `LaunchGraduation` 9,056, `LaunchGuardDeployer` 3,203. Use these in
place of P1's and step 2's older numbers; re-measure again if `src/` moves. Then, with step
2's five:

```
forge create src/markets/ProtocolFeeHook.sol:ProtocolFeeHook --rpc-url $R --private-key 0x... --broadcast
```

`export HOOK=0xc9932584c5154e4F58313a2e5423522E74e540Cc HOOK_IMPL=0x...`. The hook has no
library links and no constructor arguments; its constructor only disables initialisers.

Every `forge create` in this runbook takes `--ledger` in place of `--private-key 0x...` if the
deployer EOA lives on the Ledger; the Safe batches are signed in the Safe app either way.

### 11c — [Safe] the hook proxy, empty calldata

Batch it with step 4; ordering against the other two is free. `feeKeeper` is appended below
the live schedule slots and reads zero until 11d, so the upgrade alone changes nothing a
trader or an aggregator can observe.

```
cast calldata 'upgradeToAndCall(address,bytes)' $HOOK_IMPL 0x
```

Target: `ProtocolFeeHook` `0xc9932584c5154e4F58313a2e5423522E74e540Cc`.

Check immediately after:

```
echo "impl=$(cast implementation $HOOK --rpc-url $R) keeper=$(cast call $HOOK 'feeKeeper()(address)' --rpc-url $R) maxLp=$(cast call $HOOK 'MAX_DYNAMIC_LP_FEE()(uint24)' --rpc-url $R) cap=$(cast call $HOOK 'MAX_FEE_PIPS()(uint24)' --rpc-url $R) delay=$(cast call $HOOK 'FEE_INCREASE_DELAY()(uint64)' --rpc-url $R)"
```

Expect `$HOOK_IMPL`, zero, `50000`, `10000`, `3600`. Then, for every live pool id in
`deployments/asset-markets-mainnet-v6.json`, `feePipsFor` and `feeRecipientOf` must read
exactly what they read before the batch — the aggregator promise is that this upgrade moved
no rate.

### 11d — [Safe] authorise the keeper

A dedicated EOA, funded with gas only, imported into Foundry's encrypted keystore on the
machine that will run the scheduler (`cast wallet import`). It can move a dynamic pool's LP fee
anywhere inside 0.01–5% and nothing else: not the skim, not the registrar, not the
implementation, not a static pool.

```
cast calldata 'setFeeKeeper(address)' $KEEPER
```

Target: the hook. `setFeeKeeper(0x0)` is the rollback and takes effect on the next block; it
stops future writes and leaves the last fee where it is, so pair it with a `setPoolLpFee` from
the Safe if the last fee is wrong.

### 11e — [Safe] opening the first dynamic market — optional, and not on launch day

No live pool changes: the flag is part of a pool's identity. A dynamic market is created by
approving an asset with `fee = 0x800000` (`approveAsset`, or the admin page's "Dynamic —
keeper-updated" option) and then opening its market as usual; registration seeds it at 0.50%.
A future launch can graduate into one by setting that config's `poolFee` to `0x800000` with
`updateLaunchConfig` — the spacing ladder resolves it to 50 — but leave the live configs alone
until a plain market has run under the keeper for a while.

**Ship the frontend and backend from this tree before any of this.** They read the stored
`slot0.lpFee` and label the flag; the deployed ones would render `0x800000` as an 838.86% fee.

### 11f — the keeper itself

`script/dynamic-fee-keeper.mjs` is a one-shot planner/executor, not a daemon. Run it from an
external scheduler per `(chain, pool)`, plan-only first, `--execute --account <name> --sender
<keeper>` once the plan is right; it re-reads the stored fee and does nothing when it already
matches. The flags, the equity calendar and the optional reference-pool guard are in
`FABLES_KEEPER.md`. There is no production scheduler yet; standing one up is its own task.

### 11g — post-conditions to add to the list below

- **C10** — `feeKeeper()` is the keeper, and a `setPoolLpFee` simulated from any other address
  reverts `OnlyFeeSetter`.
- **C11** — every live pool's `feePipsFor`, `feeRecipientOf`, `pendingFeePipsOf` and
  `feePipsEffectiveAt` read what they read before 11c.
- **C12** — `getLaunchConfigSegments(id)` returns empty for every existing config, and
  `reserveEconomics(sUSDai)` still reads what step 10 wrote — the two mappings share nothing.
- **C13** — on a market with a live distributor, `stakedWeightOf(staker)` is non-zero after the
  first stake/claim and `totalStaked()` equals the sum of non-renounced weights; on markets
  16/17/18 the locker's weight is non-zero and `totalStaked()` excludes it.

### 11h — who must be told, in addition

After 11c and 11d, not before: post the addendum already on Kyber PR #1699 as a comment, and
send 0x the note in `docs/0x/HOOK_SPECIFICATION.md` §beforeSwap terms — new markets may carry
`0x800000`, the LP fee is `getSlot0(...).lpFee`, the skim is unchanged, nothing new to encode.

### 11i — [you, then Safe] the `LaunchDeployer` rotation (P5)

With step 6's two:

```
forge create src/launchpad/LaunchDeployer.sol:LaunchDeployer --constructor-args $LF --rpc-url $R --private-key 0x... --broadcast
```

`export LAUNCH_DEPLOYER=0x...`, then `cast call $LAUNCH_DEPLOYER 'factory()(address)'` must be
the launch factory. The Safe call is `setLaunchDeployer(address)` on `LaunchFactory`, batched
right after `setLaunchpad` in batch 05 — it must land before the first `launchToken` after the
proxy upgrade, and it can land any time after it. Nothing already launched moves.

### 11j — the two batches, generated rather than hand-assembled

```
AMF_IMPL=$AMF_IMPL LF_IMPL=$LF_IMPL HOOK_IMPL=$HOOK_IMPL PBT_IMPL=$PBT_IMPL BFV_IMPL=$BFV_IMPL LPRD_IMPL=$LPRD_IMPL LOCKER=$LOCKER GRAD=$GRAD LAUNCH_DEPLOYER=$LAUNCH_DEPLOYER KEEPER=$KEEPER ./script/build-release-safe-batches.sh
```

writes `deployments/safe-batches/04-upgrade-implementations.json` (steps 4, 5, 11c — six
upgrades) and `05-wire-graduation-and-keeper.json` (steps 7, 11i, 8, 9, 10, 11d — nine calls),
in this runbook's order, after checking every address against the chain: implementations have
code and are not proxies, every proxy and beacon is the Safe's, the module points at the
factory and the locker, the deployer names the factory, the keeper is an EOA. Load each in the
Safe app's Transaction Builder, sign with two of three, execute 04, run C2 and 11c, then 05.

### 11k — after the batches: verify, record, tell

1. **Sourcify.** Add the six new implementation rows plus `LAUNCH_DEPLOYER`, `LOCKER` and `GRAD`
   to `script/verify-mainnet-sourcify.sh`'s `TARGETS` and run it; `--status` afterwards must
   report each verified. Blockscout imports from there. Done 2026-09-21: nine `exact_match`,
   and `AssetMarketFactory` a metadata-level `match`, because it is the one contract with a
   linked library and via-IR compiles it **differently when the library address is in the
   compiler settings** — 25,318 bytes with `--libraries`, 24,375 without. So: deploy it by
   `cast send --create` from the linked `out/` artifact (the tested bytes), and verify it by
   POSTing the build's full standard-JSON input to `sourcify.dev/server/v2/verify/4663/<addr>`
   (`forge build --skip test --force --build-info` in a scratch checkout gives you the input;
   strip every top-level field but `language`, `sources`, `settings`). `forge verify-contract`
   with or without `--libraries` cannot reproduce it.
2. **Records.** `node script/sync-mainnet-state.mjs` regenerates `deployments/mainnet-state.json`;
   update `deployments/asset-markets-mainnet-v6.json`'s `protocolFeeHookImplementation` (and
   its note), and `docs/0x/FORM_ANSWERS.md` where it cites `0xd4AC6b17…` as the hook
   implementation. Commit the batches and the records together.
3. **Frontend/backend** were deployed from this tree before batch 04 (11e); nothing further.
4. **Kyber PR #1699** — comment with the new implementation address and Sourcify link, and
   note that the description's "from 2026-09-21" is now literally true. **0x** — the note in
   11h, with the same address.

---

## Post-conditions

Run all of these. C4 and C5 together are the critical finding's regression check and are the two
that matter most.

### C1 — the two factories agree on the graduation module

```
echo "amf.launchpad=$(cast call $AMF 'launchpad()(address)' --rpc-url $R) lf.graduation=$(cast call $LF 'graduation()(address)' --rpc-url $R) grad.locker=$(cast call $GRAD 'locker()(address)' --rpc-url $R)"
```

Expect all three to name the new module and the new locker: `$GRAD`, `$GRAD`, `$LOCKER`.

### C2 — the proxies and beacons point at the new implementations

```
for p in $LF $AMF; do echo "$p impl=$(cast storage $p 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R)"; done && for b in $TB $VB $DB; do echo "$b impl=$(cast call $b 'implementation()(address)' --rpc-url $R)"; done
```

Expect the two storage words to end in `$LF_IMPL` / `$AMF_IMPL` and the three beacons to return
`$PBT_IMPL`, `$BFV_IMPL`, `$LPRD_IMPL`. The pre-upgrade values, for comparison, were
`0xFCC13E959E4e441F0d83dd05B4dfaEA7CE459be3` (launch factory),
`0x45Ce2F93aD46d1393Eff5da56fFc4537740022C0` (market factory),
`0xb2Dc3fdDBa4A892184947575430FDdB1DacC06B9`, `0xB714D2E06a081929824381Fc360ada2c2e7f9fcF`,
`0xad46f2a29317096047aD6D036dDa24Bf260C5f62`.

### C3 — the float share is wired and the treasury answers the new surface

```
echo "aiusd.factory=$(cast call $AIUSD_TREASURY 'factory()(address)' --rpc-url $R) aiusd.namedFactory=$(cast call $AIUSD_TREASURY 'namedFactory()(address)' --rpc-url $R) totalFloat=$(cast call $AIUSD_TREASURY 'totalFloat()(uint256)' --rpc-url $R) marketReserve=$(cast call $AIUSD_TREASURY 'marketReserve()(uint256)' --rpc-url $R)"
```

Expect `0x22AA61c589B90731752236c07d1455D0065bfc79` twice, then `0` and `0`. No market has
graduated into AIUSD yet, so both ledgers are empty and the issuer's `claim` is unchanged —
which is the property that makes this upgrade a no-op for AIUSD's economics until the first
shared-quote graduation.

### C4 — `graduatedCreatorYieldShareBps()` still answers, and still answers `4000`

```
cast call $LF 'graduatedCreatorYieldShareBps()(uint16)' --rpc-url $R
```

Expect **`4000`**. A revert here means the getter was dropped from the implementation and markets
16, 17 and 18 have just been stranded permanently. There is no fix short of another upgrade, and
every hour it stays wrong is an hour those three creators cannot collect.

### C5 — `collect()` on the old locker still succeeds

```
for t in 0x85B0a0d2DaC3F43F48A4F0304bD57314c101d76C 0x2165962eb8BF56354bF7053071E515dC9818DfbF 0x17A5C7E9293199271f985eDAC74366015DA96FaD; do echo "$t -> $(cast call $OLDLOCKER 'collect(address)(uint256,uint256)' $t --rpc-url $R | tr '\n' ' ')"; done
```

Expect three lines of two numbers each, at least as large as the P6 baseline — fees keep accruing,
so they should have grown, never shrunk, and never reverted. **This is the check that C4 exists
to protect.** The locker is not upgradeable and its factory is immutable; a revert here is
unrecoverable by any means the protocol has.

### C6 — the launch deployer was rotated and carries the curve this tree calls

Two reads, no transaction:

```
LD=$(cast call $LF 'launchDeployer()(address)' --rpc-url $R) && echo "deployer=$LD factory=$(cast call $LD 'factory()(address)' --rpc-url $R) 6508e7ac=$(cast code $LD --rpc-url $R | grep -o 6508e7ac | wc -l)"
```

Expect `$LAUNCH_DEPLOYER` from step 11i — **not** `0x7979708A371E9f9dDb43A432595c3F59f77dd5E7` —
the launch factory, and a non-zero count. The old address means batch 05 did not land its
`setLaunchDeployer`, and the next `launchToken` will revert with empty data; a count of `0`
means the deployer was built from a tree without segmented curves. Either way, read P5 and
P5a before doing anything else.

### C7 — the rates

```
echo "creator=$(cast call $LF 'graduatedCreatorShareBps()(uint16)' --rpc-url $R) lpFund=$(cast call $LF 'graduatedLpFundShareBps()(uint16)' --rpc-url $R) recipient=$(cast call $LF 'lpFundRecipient()(address)' --rpc-url $R)"
```

Expect `4000`, `3000`, `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`. The protocol takes the
remaining 3,000 bps.

### C8 — slUSD is refused, structurally

```
cast call $LF 'launchEconomics(address)(address,(uint256,uint256,uint256,uint8,bool))' $SLUSD --rpc-url $R
```

Expect a **revert**, `PairTokenNotRegistered(0xE20cE31a996f07b3d70F9C840e6810F0f572C884,
0x0000000000000000000000000000000000000000)`. A successful return means slUSD was registered
through the market factory since P7 and now quotes on the sUSDai reserve's figures — which is
legitimate, but it is a change of the launchable set and belongs in the *Who must be told*
note.

### C9 — the reserve carries its economics and AIUSD launches on them

```
echo "reserve=$(cast call $LF 'reserveEconomics(address)(uint256,uint256,uint256,uint8,bool)' $SUSDAI_RESERVE --rpc-url $R | tr '\n' ' ') aiusd=$(cast call $LF 'launchEconomics(address)(address,(uint256,uint256,uint256,uint8,bool))' $AIUSD --rpc-url $R | tr '\n' ' ')"
```

Expect `3236000000 8090000000 1000000 6 true` for the reserve, and for AIUSD the sUSDai reserve
address followed by the same five figures. A revert on the AIUSD read is H4 having bitten:
`PairTokenFloatShareUnavailable` means step 8 never landed, and every launch quoted in AIUSD
reverts until it does. All-zero figures with `false` mean step 10 never landed and the reserve
is closed.

---

## After a graduation — the spacing check

**Not a rollout post-condition. A standing check, run once per graduated market**, starting with
the first one after this rollout. The spacing ladder means a graduation can legitimately open on
a non-canonical tick spacing, and this is the only thing that tells an operator it happened.
Pair it with an alert on `LaunchPoolSpacingShifted`; this check is what you run when that alert
fires, and also when it does not, because a missed log is cheaper to catch here than in a venue
listing.

### G1 — the market opened on its tier's canonical spacing

```
MID=<marketId> && K=$(cast call $AMF 'poolKeyOf(uint256)((address,address,uint24,int24,address))' $MID --rpc-url $R | tr -d '()\n ') && FEE=$(echo $K | cut -d, -f3) && echo "market $MID fee=$FEE spacing=$(echo $K | cut -d, -f4) canonical=$(cast call $AMF 'tickSpacingForFee(uint24)(int24)' $FEE --rpc-url $R)"
```

Expect `spacing == canonical`. That is the normal, unattacked outcome and there is nothing
further to do.

**When they differ, the graduation was squatted.** The market itself is correct — every
in-protocol consumer reads `poolKeyOf`/`market(id).tickSpacing` and none of them can be fooled —
but two things are now true and both need recording:

- **`Market.tickSpacing` no longer follows from `Market.fee`.** Anything outside this repo that
  rebuilds a `PoolKey` from a v3-style fee → spacing table will miss this market. Tell the
  aggregator contacts in *Who must be told* if the market is one they route.
- **The canonical key holds somebody else's pool**, initialised at a price they chose and
  seedable by them at any time. Record its pool id and exclude it from every venue listing,
  dashboard and depth measurement.

### G2 — record the decoy's pool id

Only when G1 shows a difference. Same `$MID`, run immediately after G1 so `$K` and `$FEE` are
still set:

```
C0=$(echo $K | cut -d, -f1) && C1=$(echo $K | cut -d, -f2) && HOOK=$(echo $K | cut -d, -f5) && CANON=$(cast call $AMF 'tickSpacingForFee(uint24)(int24)' $FEE --rpc-url $R) && echo "decoy poolId=$(cast keccak $(cast abi-encode 'k((address,address,uint24,int24,address))' "($C0,$C1,$FEE,$CANON,$HOOK)"))"
```

A v4 pool id is `keccak256(abi.encode(PoolKey))` and every `PoolKey` field is static, so this is
the same hash `PoolManager` used. Confirm the pool really exists before recording it — a zero
`sqrtPriceX96` means the spacing shifted for some other reason and there is no decoy:

```
cast call $(cast call $AMF 'poolManager()(address)' --rpc-url $R) 'getSlot0(bytes32)(uint160,int24,uint24,uint24)' <decoy poolId> --rpc-url $R
```

Put the pool id on the exclusion list with the market id beside it. The protocol cannot close or
reclaim that pool; excluding it is the whole remedy. See `AMF-POOLSQUAT-RESIDUAL-2` and
`AMF-LADDER-DECOY` in the design doc for why this is an accepted cost rather than a bug.

---

## Rollback

Be honest about which half of this is reversible, because the two halves are not alike.

### Reversible

| Step | How |
|---|---|
| 4, both proxies | `upgradeToAndCall(<previous impl>, 0x)` from the Safe. Previous: `0xFCC13E959E4e441F0d83dd05B4dfaEA7CE459be3` (launch factory), `0x45Ce2F93aD46d1393Eff5da56fFc4537740022C0` (market factory). |
| 5, all three beacons | `upgradeTo(<previous impl>)` from the Safe. Previous: `0xb2Dc3fdDBa4A892184947575430FDdB1DacC06B9`, `0xB714D2E06a081929824381Fc360ada2c2e7f9fcF`, `0xad46f2a29317096047aD6D036dDa24Bf260C5f62`. |
| 9, the knobs | Plain setters, both directions. Step 3 sends nothing, so there is nothing to undo. |
| 10, the economics | Re-runnable with any accepted figures, and `setReserveApproved($SUSDAI_RESERVE, false)` closes the reserve to new launches without disturbing them. That switch is per **reserve**: it closes every brand of it at once, and there is no per-brand equivalent. |

There is no deployer row, because there is no deployer step — see P5a.

Rolling the proxies back does **not** roll back storage. `AssetMarketFactory.launchFloatOf`
(slot 25) and `LpRewardDistributor.rewardsRenounced` / `minStakeWeight` / `_floorSet`
(slots 22, 23, 24) keep whatever they were written with; the old implementations simply do not
read them. That is safe, and it is also why a re-upgrade later resumes rather than restarts.

`reserveEconomics` is the same story in the other direction, and it is why the old per-brand
slot was retired rather than reused. The new mapping is appended at **slot 18**, below
everything already written, and slot 13 — where the per-brand `pairTokenEconomics` mapping
lived — is now an unread private `uint256` placeholder rather than a mapping of a different
value type, precisely so the live proxy's old entries are not decoded as garbage. A rolled-back
`LaunchFactory` therefore finds its old per-brand entries exactly as it left them — including
slUSD's stale `approved == true`, which becomes live again the moment the old implementation is
back. **If you roll step 4 back, take that approval off in the same batch** with
`setPairTokenApproved(slUSD, false)` — retired by this rollout, and callable again only because
the rolled-back implementation is the one that still has it. Re-upgrading forward does not need
step 10 re-run; the reserve's figures are still there. Both slot numbers are pinned by
`test/upgrade/GraduateIntoLaunchDollarLayout.t.sol:95-106`.

### Not reversible

- **The locker and the graduation module.** Neither is upgradeable, and
  `LaunchLocker.setGraduation` is one-shot, so a new graduation module always needs a new locker
  beside it. Pointing `LaunchFactory.setGraduation` and `AssetMarketFactory.setLaunchpad` back at
  the previous module `0xF5f4Eb45347ec69CB56D1c682a0FdA83bb9f4efC` is possible and is the correct
  move if you roll the proxies back in the same batch — but the new locker `$LOCKER` is then dead
  weight and can never be reused for anything.
- **Any graduation that lands in between.** Once a launch graduates under the new module it is a
  shared-quote market quoted in AIUSD, its locked position is staked and has renounced its reward
  stream, and its float is registered on AIUSD's treasury. None of that unwinds. Rolling the
  market factory back to an implementation without `recordLaunchFloat` leaves that market's
  `launchFloatOf` unreadable by the factory while the treasury keeps paying its vault — a split
  brain, not a clean revert. **If a graduation has landed, do not roll back; fix forward.**
- **`PoolBrandTreasury.setFactory` on AIUSD.** `namedFactory` is write-once. You can set `factory`
  back to zero, which stops new registrations, but you can never name a different factory. If you
  roll the market factory proxy back the address is unchanged, so this is harmless; if you ever
  redeploy the market factory at a new address, AIUSD can never opt into it.
- **`LaunchGuardDeployer` and the five implementations.** Deployed code is permanent. Harmless —
  nothing points at them after a rollback — but they are on chain and they cost gas.

---

## Who must be told

Per [`SUBMISSIONS.md`](./SUBMISSIONS.md) §"What changes would invalidate the submission", **the set
of live markets** is one of the six rows that obliges us to tell both teams rather than wait for
them to find it. This rollout changes the shape of that set.

- **0x**, via the Custom Uniswap v4 Hook Request contact.
- **KyberSwap**, via the `dex-lib` adapter contact.

What to say, and it is short: no submitted address moves. The hook, `PoolManager`,
`AssetMarketFactory`, `MarketRouter`, `MarketLens`, the sUSDai reserve and the Safe are all
unchanged — the contracts that move are either UUPS proxies that keep their address, beacons
behind per-market proxies, or launchpad-only modules neither team was pointed at. No
re-submission is implied and no tag is cut for this.

What does change: the next launchpad graduate will read `isSharedQuote(marketId) == true` and
quote an existing brand, where markets 16, 17 and 18 read `false` and quote a `<SYM>.d` of their
own. Tell both teams to read `AssetMarketFactory.isSharedQuote(marketId)` and `poolKeyOf(id)`
rather than inferring the quote token from a symbol or from the creation path. For KyberSwap the
practical consequence is that a per-brand capacity model gets less correct over time — see
[`KYBERSWAP_INTEGRATION.md`](./KYBERSWAP_INTEGRATION.md) §3.4.

Update `SUBMISSIONS.md`'s pending entry with the deploy date once this lands.

---

## Indexer notes

Anything reading events off this stack needs these fifteen changes. The first three are breaking
for an existing indexer; the other twelve are additions.

**Breaking:**

- **`SharedReservePool.YieldClaimed.receiver` is now the brand's treasury, not the issuer.**
  `PoolBrandTreasury.claim` asks the pool to pay this contract, because the claim has to be
  divided before it can be paid. Attributing a brand's yield to a recipient from the pool's event
  now attributes all of it to the treasury address.
- **`PoolBrandTreasury.Claimed` is now `(uint256 claimed, uint256 amount, address indexed
  receiver)`.** It was two fields. `claimed` is what the pool paid the treasury; `amount` is what
  left for `receiver`, which is the fresh claim less the markets' share plus any stray balance.
  They coincide only on a brand with no float. `totalYieldClaimed` tracks `claimed`, not `amount`.
  **This is now the correct source for issuer yield attribution.**
- **`PairTokenEconomicsUpdated` and `PairTokenApprovalUpdated` are gone**, replaced by
  `ReserveEconomicsUpdated(address indexed reserve, uint256 phantomQuote, uint256
  graduationThreshold, uint256 launchFee, uint8 decimals, bool approved)` and
  `ReserveApprovalUpdated(address indexed reserve, bool approved)` on `LaunchFactory`. The
  indexed address is a **reserve**, not a brand, and the economics struct no longer carries a
  `reserve` field. An index that kept a per-brand row of launch terms cannot be fed from these:
  the terms are per reserve, and the set of brands they apply to is whatever
  `AssetMarketFactory.reserveOfBrand` says at launch time, so `BrandRegistered` is the event
  that grows the launchable set now. Nothing emits when a newly registered dollar becomes
  launchable, because nothing happens — `launchEconomics(brand)` is the read that answers it.

**New:**

| Event | Contract | Means |
|---|---|---|
| `FloatRegistered(vault, previous, current)` | `PoolBrandTreasury` | A market's recorded float changed. `current == 0` is a deregistration, which `retireMarket` does. |
| `FloatSharePulled(claimed, toMarkets)` | `PoolBrandTreasury` | A pull happened. `toMarkets` is what was actually booked to `marketReserve`, which is what the index can pay — not the nominal share. |
| `FloatShareClaimed(vault, amount)` | `PoolBrandTreasury` | A market vault was paid its float share. |
| `LaunchFloatRecorded(marketId, amount, landed)` | `AssetMarketFactory` | A graduation's seed was pinned. `landed == false` means the treasury refused and `retryLaunchFloat` can still land it. |
| `RewardsRenounced(account, liquidityGivenUp)` | `LpRewardDistributor` | Emitted once per graduation, by the locker (`LpRewardDistributor.sol:242`). The account stops accruing rewards permanently. `liquidityGivenUp` is raw v4 position liquidity, the same unit `stake` books. |
| `MinStakeWeightRaised(minStakeWeight)` | `LpRewardDistributor` | The market's stake-admission floor was measured by a renunciation, at one basis point of the liquidity given up. At most once per market, and only when the measurement actually raises it. On a **graduated** market this is routine and expected. **Alert on it for a market that never graduated** — that is `LPRD-FLOOR-SOLESTAKER`: somebody staked into an empty distributor, renounced to pin a floor, and unstaked. Clear it with one `configAdmin` `setMinStakeWeight(0)`. |
| `MinStakeWeightSet(minStakeWeight)` | `LpRewardDistributor` | `configAdmin` moved the admission floor, in either direction. Zero restores the original rule. This is the recovery path for a wrong floor, so an unexplained one is worth asking about. |
| `LaunchFloatDeferred(marketId, amount)` | `LaunchGraduation` | The float leg did not land at graduation. **Alert on this** — it means somebody should call `AssetMarketFactory.retryLaunchFloat(marketId)`, and until they do the market's LPs earn nothing on the float they locked. |
| `LaunchPoolSpacingShifted(asset, brandToken, fee, canonicalTickSpacing, tickSpacing)` | `AssetMarketFactory` | **Alert on this.** The launch was squatted, the market opened off-canonical, and the canonical key now holds somebody else's pool — initialised at a price they chose and seedable by them at any time. The graduation itself is fine and needs no intervention. What needs doing is the *After a graduation* check above: record the decoy's pool id and exclude it from every venue listing, and tell anyone who derives a pool key from the fee tier. |
| `LaunchPoolLadderExhausted(asset, brandToken, fee)` | `AssetMarketFactory` | **Escalate.** An error, not an event — it reverts `graduateToMarket`, so it shows up as a failed transaction rather than a log. All 32 rungs at the launch's fee tier are taken; the launch stays `Swept`. The exit is `LaunchFactory.setSweptLaunchPoolFee(token, newFee)`, which is permitted only in exactly this state, and past all five tiers the 7-day `rescueSweptGraduation`. See `AMF-POOLSQUAT-RESIDUAL-2` in the design doc. |
| `LaunchPoolFeeRetiered(token, previousFee, newFee)` | `LaunchFactory` | An ungraduated launch's pool fee tier was moved by the owner. The spacing ladder is tried first and automatically, inside `createLaunchMarket`, so this fires **only** after a whole tier's 32 rungs were exhausted — it is the escalation of `LaunchPoolLadderExhausted`, not the first response to a squat. |
| `StraySwept(token, amount)` | `LaunchGraduation` | A donated balance was swept to the protocol fee recipient. Routine; not an incident. |

`LaunchLocker.Collected` loses its two yield fields on the **new** locker. The old locker
`0xACf51B…` keeps emitting the old shape, so an indexer covering both must key the decoder on the
emitting address, not on the topic alone.

---

## Watch list

- **`AssetMarketFactory` has 211 bytes of EIP-170 margin**, down from 472 before the spacing
  ladder. Under 1% of the limit. It is the tightest deployable contract in the repo and
  `MarketDeployer` already exists to keep it there. Treat any further addition to that contract
  as needing `forge build --sizes` *before* the code is written, not after — and note that
  `code_size_limit` in `foundry.toml` does not rescue an oversized deploy: forge runs a separate
  size check between simulation and broadcast, so it simulates cleanly, prints addresses, and
  then refuses to send.
- **`Probe_AssetMarketFactory` has 170 bytes and is what hits the limit first.** It is a
  test-only contract in `test/upgrade/UpgradeInvariants.t.sol:70` that inherits the factory and
  appends one `uint256` plus a getter — 41 bytes over its parent — so it exists precisely to
  fail before a real storage slot is added that would not fit. **170, not 211, is the headroom
  to plan against**, and an addition can break the offline suite while leaving the deployable
  artifact legal. Read both rows of `forge build --sizes`.
- **`LaunchFactory` has 4,289 bytes**, at 20,287 runtime, and only because
  `LaunchGraduationGuard`'s 2,970 bytes of creation code were moved into `LaunchGuardDeployer`.
  That margin is the result of the extraction, not evidence it was unnecessary. The next helper
  that needs `new` in that contract needs the same treatment.
- **`foundry.toml`'s size comment is current**, re-measured on this branch and agreeing with
  every figure above (`foundry.toml:34-77`). If you change either contract's size, change that
  block in the same commit — it is what the next person reads before they read this.
- **`LaunchFloatDeferred` with no follow-up `LaunchFloatRecorded`.** A market silently earning
  nothing on its locked float is the quietest failure this stack has.
- **`totalFloat` approaching `outstanding` on a quote brand.** At and past that point the issuer's
  `claim` returns zero and the whole brand's yield divides among the registered markets by their
  recorded seeds. See *Accepted risks* in the design doc; it is a known, accepted property, not a
  bug, but it should not arrive as a surprise.
- **A graduated market whose `tickSpacing` is not `tickSpacingForFee(fee)`.** It means that
  launch was squatted and the canonical key belongs to somebody else. Run *After a graduation*
  above, record the decoy's pool id, and keep it off every listing. There is no fix to apply;
  the market is correct and the decoy is not reclaimable.
