# Graduate into the launch's own dollar

Branch `feature/graduate-into-launch-dollar-main`, worktree `StableLaunchpad-grad-dollar`, cut
from `staging/main` @ `0d4251e4`.

**The concentrated-liquidity stack is deliberately not on this branch.** Nothing here has
`CurveSegmentConfig`, `LaunchCurveSegments`, `VolatilityFeePolicy`, `IDynamicFeePolicy`, the
managed vaults, or a segmented `LaunchCurve.initialize`; those live on
`backup/grad-dollar-pre-rebase` / `feature/dynamic-fee-hook` and ship as a separate PR.
`ProtocolFeeHook` is byte-identical to the 0x submission here. Every figure in this document is
measured against this tree.

## What changes

On the deployed implementation a launch quoted in AIUSD graduates into a pool quoted in a
**freshly minted `<SYM>.d`**: `LaunchFactory._seed` names the unit,
`AssetMarketFactory.createLaunchMarket` registers it as a new brand on the reserve, and
`LaunchGraduation.graduate` swaps the whole raise into it 1:1. None of those three lines exist
on this tree any more, which is why none of them is cited by line here.

After this change the graduated pool is `ASSET / AIUSD`. No brand is minted, no swap happens, and
`allBrandTokens` stops growing on graduation.

The one thing `<SYM>.d` bought — float yield for the market's LPs — is preserved by a **float
share** on `PoolBrandTreasury`: the quote brand's treasury splits its reserve yield between its
issuer and the market vaults that locked float in their pools.

Nothing about markets 13–18, the hook, `MarketLens`, or the 0x / KyberSwap submissions is touched.
Shared-quote markets are already live (13, 14, 15 quote AIUSD) and already fork-tested against a
stock `V4Quoter`.

---

## The float share

### Weight

A market's weight is **the brand amount its graduation seeded into the pool** — `Result.unitSeeded`,
recorded once, never updated.

This is deliberately static. A pool's live brand balance is not readable: Uniswap v4 holds every
pool's tokens in one singleton, and the hook cannot be taught to track it without new permission
flags, which would change the hook address and invalidate the 0x submission
(`docs/SUBMISSIONS.md:66`). A recorded seed is exact at graduation, drifts with trading afterwards,
and needs no ongoing accounting anywhere. The drift is documented and accepted rather than
chased — see **Accepted risks** for what it costs and what a later release could do about it.

### Where the split lives

`PoolBrandTreasury`, not `SharedReservePool`. The reserve keeps its single-principal
`claimYield` gate — `if (msg.sender != b.treasury) revert OnlyBrandTreasury()`
(`SharedReservePool.sol:624`) — so nothing on the redeem path or the aggregator read surface
moves. `docs/0x/SECURITY_AND_GOVERNANCE.md:348` stays true.

The split is an **index**, the same shape the reserve already uses for
`cumulativeYieldPerToken` — O(1) per market, no loop over vaults.

### New state on `PoolBrandTreasury`

Appended below the existing state, slots 4 through 10. The `__gap` shrinks from `uint256[45]`
to `uint256[38]` (`PoolBrandTreasury.sol:376`) — seven slots, not six, because consent is
remembered as well as held. The footprint is therefore unchanged at 49 slots, gap 11..48, and
**the next field appended to this contract goes after slot 48**.

```solidity
address public factory;                                  // slot 4, the only registrar
mapping(address vault => uint256 float) public floatOf;  // slot 5, recorded seed, brand units
uint256 public totalFloat;                               // slot 6
uint256 public cumulativePerFloat;                       // slot 7, WAD, underlying per float
mapping(address vault => uint256) public checkpointOf;   // slot 8
uint256 public marketReserve;                            // slot 9, owed to vaults, unpaid
address public namedFactory;                             // slot 10, the one factory consented to
```

`test/upgrade/GraduateIntoLaunchDollarLayout.t.sol:113-124` states every one of those numbers
and `:504` proves them against a live float ledger through a beacon upgrade.

### New functions

| Function | Caller | Does |
|---|---|---|
| `setFactory(address)` | `onlyAdmin` | Issuer opts the brand into float sharing — **one-way** (`PoolBrandTreasury.sol:218-229`). The first non-zero address is recorded in `namedFactory` and is the only non-zero address ever accepted again; anything else reverts `FactoryAlreadyNamed`. `address(0)` is always accepted and always re-openable back to `namedFactory`. Without that shape the brand's own admin could point `factory` at itself and either `registerFloat(victimVault, 0)` a graduated market out of its share, or register a vault of its own with a huge float and take nearly all of the split — see **Accepted risks** and the audit's `PBT-REVOKE`. Deliberately NOT an `initialize` parameter: changing that signature would force a `SharedReservePool` upgrade (`SharedReservePool.sol:396`) for no gain. |
| `registerFloat(address vault, uint256 amount)` | `factory` | Settles the vault's checkpoint, then sets `floatOf[vault]` and adjusts `totalFloat` (`:239`). Idempotent; `0` deregisters. |
| `claimFloatShare()` | a vault with float | Pulls the brand's accrued yield from the reserve **into this treasury**, credits the market slice to the index, then pays `msg.sender` what the index owes it (`:258`). |

There is no public `pull()`. The pull is the private `_pull()` and has exactly three callers —
`claim`, `registerFloat` and `claimFloatShare` — because a pull that settles nobody's
checkpoint has no reason to be reachable on its own.

`_pull()` (`PoolBrandTreasury.sol:300-321`), with the zero-guards elided:

```
got = pool.claimYield(brandToken, address(this));        // receiver is now self, not the admin
outstanding = pool.outstandingOf(brandToken);
weight = min(totalFloat, outstanding);                   // markets can never exceed 100%
share = mulDiv(got, weight, outstanding);
delta = mulDiv(share, WAD, totalFloat);                  // what an index scaled by WAD expresses
cumulativePerFloat += delta;
booked = mulDiv(delta, totalFloat, WAD);                 // read back out
marketReserve += booked;                                 // NOT `share`
```

**`marketReserve` is credited with `booked`, not with `share`.** Crediting `share` while the
index can only ever pay out `booked` would withhold `share - booked` from the issuer on every
pull without promising it to any vault, and both `claim` and `distribute` subtract
`marketReserve` in full — so that difference would be unspendable by anyone for the life of the
brand. `delta == 0`, reachable whenever `float > share * WAD`, is the extreme of the same error:
it would freeze the entire `share`. Booking `booked` leaves the remainder on the issuer's side,
where `claim` can still reach it, and costs the markets at most one wei of index resolution per
pull. This is the audit's `PBT-DUST`.

### Changed function

`claim(address receiver)` stays `onlyAdmin whenNotPaused`, but now routes through the treasury
instead of paying the reserve straight out to `receiver` (`PoolBrandTreasury.sol:174-186`):

```
claimed = _pull();
amount  = underlying.balanceOf(this) - marketReserve;    // clamped at zero
underlying.safeTransfer(receiver, amount);
emit Claimed(claimed, amount, receiver);
```

The two numbers are not the same number, so the event carries both: `claimed` is what the pool
paid this treasury, `amount` is what left for `receiver`. They coincide only on a brand with no
float and no stray balance. Two consequences for anyone reading the chain: `totalYieldClaimed`
tracks `claimed`, and `SharedReservePool.YieldClaimed.receiver` is now the treasury rather than
the issuer, so yield must be attributed from `Claimed` here rather than from the pool's event.

The issuer's economics are unchanged when `totalFloat == 0`, which is every brand today.

### `BrandFeeVault.harvest()`

```solidity
// BrandFeeVault.sol:228-232
claimed = treasury.admin() == address(this)
    ? treasury.claim(address(this))      // market owns its brand — unchanged path
    : treasury.claimFloatShare();        // shared quote
```

One extra view call, no new init parameter, no new storage, and it self-corrects if the admin is
ever rotated. `sweep`, the split list and `LpRewardDistributor` are untouched: to the vault a
balance is a balance.

This retires the manual workaround that was `script/FundSharedQuoteRewardsMainnet.s.sol`: funding
a shared quote's LP stream by minting the dollar into the market's fee vault and sweeping. The
script is deleted — `harvest()` now reaches the float share on its own, and a hand-funded stream
would double-pay it.

---

## Who earns what, after this change

Two income rails, and they stop crossing.

| Rail | Source | Goes to |
|---|---|---|
| **Float yield** | reserve yield on the dollars sitting in the pool | **liquidity providers, all of it** |
| **Locked-position trading fees** | the Uniswap fee the permanently locked seed earns | 40% creator / 30% LP fund / 30% protocol |
| Hook fee | 0.5% of every swap's output | protocol treasury, unchanged |

### Float yield: LPs only

On the deployed implementation the locked seed position is staked in `LpRewardDistributor` with
`LaunchLocker` as the beneficiary, so it accrues a share of the float stream, and that locker's
`collect` splits the share between creator, LP fund and protocol. That locker
(`0xACf51B066b90596e8536A1423Df4A6b94D5815c9`) is not upgradeable and keeps doing exactly that
for markets 16/17/18; the code is not in this tree, so there is nothing here to cite by line.

That leg is deleted from the new locker. The locked position keeps its stake — it has to,
because the distributor custodies the NFT and `collectFees` is what pays the trading-fee rail —
but it **renounces reward accrual**, so the entire float stream divides among the LPs who
actually took risk.

New on `LpRewardDistributor` (`__gap` is now `uint256[37]`, `:236` — three slots spent, on
`rewardsRenounced`, `minStakeWeight` and the one-shot flag `_floorSet`):

```solidity
mapping(address account => bool) public rewardsRenounced;   // slot 22 (`:213`)
uint256 public minStakeWeight;                              // slot 23, the admission floor
bool private _floorSet;                                     // slot 24, one measurement per market
uint256 public constant RENOUNCED_FLOOR_DIVISOR = 10_000;   // `:119`, 1 bp — a constant, no slot
```

**These are not the slot numbers an earlier revision of this document carried.** They were
re-derived against this base, where the concentrated stack's weight fields do not exist: the
three sit directly below `_positionIndex` (slot 21), not below a weight book. The gap was 40
starting at 22 and is now 37 starting at 25, so the footprint is unchanged at 62 slots and
**the next field appended to this contract goes after slot 61**.
`test/upgrade/GraduateIntoLaunchDollarLayout.t.sol:138-143` states all five numbers and `:701`
asserts slot 24 directly, because `_floorSet` is `private` and has no getter.

`renounceRewards()` (`LpRewardDistributor.sol:523-565`) is self-service — no new authority,
because only a staker can give up its own stream. It settles first (`:530`), so whatever the
caller earned while its liquidity still divided the stream stays claimable; only the future
stream is given up. It then sets `rewardsRenounced[msg.sender]` and subtracts the caller's
`stakedLiquidityOf` from `totalStaked` (`:539-540`) — and that is the whole of the bookkeeping.
There is no weight cache to clear and no per-position loop, because a position's contribution
here is its raw v4 liquidity: `stake` books `positionManager.getPositionLiquidity(tokenId)`
(`:397`) and adds it to `totalStaked` only when the beneficiary has not renounced (`:422`),
and `unstake` subtracts it under the same flag (`:446-452`). The two sides are paired on the
flag, so a renounced account's liquidity never enters the book and is never taken out of it.

**And it may measure `minStakeWeight` at one basis point of the liquidity it gave up**
(`:555-562`), emitting `MinStakeWeightRaised` only when the measurement actually raises the
floor (`:558-561`). This is the audit's `LPRD-DUSTCAPTURE`. Renouncing takes `totalStaked` to
zero on a freshly graduated market, where the locked seed is the only liquidity — so without a
floor the first account to stake a single unit of liquidity would take the whole float stream on
the whole raise, plus everything banked in `undistributed`, until a real LP arrived to dilute it.

**The floor is not a plain upward ratchet.** Three properties, and they are the whole of why it
is safe:

- **It is measured at most once per market**, on the explicit `_floorSet` flag rather than on
  `minStakeWeight != 0` (`:556-557`) — a market that never graduated has a zero floor forever
  and would otherwise still owe anybody one free measurement, and `setMinStakeWeight(0)` must
  not re-arm the ratchet. The shot is spent on the measurement, not on the write, so a caller
  who clears all three guards cannot come back afterwards with a larger position.
- **Only an account holding the whole earning book may measure it** — `totalStaked == given`,
  read *before* the subtraction that takes the caller out of the very book it is compared
  against (`:532-537`). `totalStaked` is the non-renounced book, so the test asks whether
  anyone still earning is staked here besides the caller. True of a graduation's seed by
  construction, because `LaunchGraduation.graduate` creates the distributor, stakes the seed to
  the locker and has `LaunchLocker.recordPosition` renounce in the same transaction; false of
  every market that already has a liquidity provider, since `unstake` is `onlyStaker` (`:442`)
  and nobody can evict anybody into satisfying it.
- **`configAdmin` can move it afterwards, in either direction**, through the new
  `setMinStakeWeight(uint256)` (`:605-611`), which emits `MinStakeWeightSet`. Zero restores the
  original rule — any position carrying liquidity at all. This is the way back from a floor
  that is wrong, and it is what keeps `LPRD-FLOOR-SOLESTAKER` a grief rather than a permanent
  lockout. Raising it cannot evict and lowering it cannot dilute anyone already in, because
  `stake` is the only place the floor is read (`:405-406`), so no settlement is needed either.

`configAdmin` is not a stored role: it is `IGuardOwner(guard()).owner()`, read live (`:575-577`),
which on mainnet is the Safe that already owns the beacon this implementation is served from.

The measurement is unforgeable on any market that has a liquidity provider: the number is the
caller's own `stakedLiquidityOf`, which only its own `stake` and `unstake` can move, taken from
an account the invariant proves is the only earner. The one case that survives is a distributor
with *no* stakers, where the sole-staker test is trivially true — `LPRD-FLOOR-SOLESTAKER` in
*Accepted risks*.

A renounced account is exempt from the floor (`stake`, `:404-406`) because it takes no share of
the stream whatever it stakes, so it can capture nothing — and because a second graduation's
locked position has to be admitted for `collectFees` to reach it. Admission is a one-time rule,
not an eviction rule: nothing re-tests it.

`collectFees` is gated on `stakerOf[tokenId]`, never on entitlement, so the trading-fee rail is
untouched by any of this.

`LaunchLocker.recordPosition` calls `renounceRewards()` once (`LaunchLocker.sol:158`), in the
same transaction as the stake, so no reward is ever credited to it. Routing the renunciation
through `configAdmin` would mean a governance transaction per graduation — self-service avoids
that entirely, and only a staker can give away its own stream in any case.

### Trading fees: 40 / 30 / 30

`LaunchLocker.collect` keeps only the fee legs and splits both the unit side and the token side on
the same three rates:

| Leg | Rate | Source |
|---|---|---|
| Creator | 4,000 bps | `p.creatorShareBps`, snapshotted per position at launch |
| LP fund | 3,000 bps | `graduatedLpFundShareBps`, read live |
| Protocol | remainder, 3,000 bps | whatever the other two leave |

**The rates are configuration, not code.** `graduatedCreatorShareBps` initialises to `4_000`
(`LaunchFactory.sol:441`) and reads `4000` live; `graduatedLpFundShareBps` already reads
`3000` and `lpFundRecipient` already names the protocol treasury, so the three owner calls in
the rollout are re-assertions rather than first writes. The frontend's hardcoded "Creator
share of pool fees after graduation — 100.00%" was wrong against the contract even before this
change; the wizard now renders the live `creatorFeeShareBps` instead of any literal, and says
in the same sentence that the yield on the dollars sitting in the pool goes to the market's
liquidity providers (`web-stable/src/features/launchpad/launch-wizard.tsx:1159-1164`).

`lpFundRecipient` is the protocol treasury for now, deliberately. It is a single global address, so
it cannot be a per-market destination; when a real LP fund exists, one `setLpFundRecipient` moves
the leg with no redeploy.

### What the creator loses, stated plainly

The creator's cut of float yield goes from `graduatedCreatorYieldShareBps` (4,000 bps,
`LaunchFactory.sol:359`) to **nothing** — for launches graduated by the NEW locker. There is no
yield leg left for it to be a share of: the locked position renounces its reward stream at
`recordPosition`, so the whole float stream goes to the market's real LPs.

**The getter is NOT retired, and this matters more than it looks.** An earlier revision of this
plan deleted `graduatedCreatorYieldShareBps` outright. That would have been a critical,
irreversible break: the `LaunchLocker` that custodies markets 16, 17 and 18
(`0xACf51B066b90596e8536A1423Df4A6b94D5815c9`) is not upgradeable, holds its factory address
immutably, and reads that getter **unconditionally** inside `collect()`. Removing the selector
from the upgraded `LaunchFactory` implementation would have made every `collect()` that locker
can ever make revert, and it has no function that moves a position or its income anywhere else
— three creators' fees, the LP fund's fees, the protocol's fees and the accrued float yield,
stranded permanently. This is the audit's `LF-ABI-BREAK`.

What actually shipped:

- `uint16 public graduatedCreatorYieldShareBps` stays, `public`, at the same byte offset
  (`LaunchFactory.sol:359`; slot 12, byte 3). The live slot holds `4_000`, which is exactly the
  term those three creators were sold. The slot also cannot be moved: those 2 bytes sit between
  `launchEnabled` and `lpFundRecipient` inside one packed slot, so removing them would slide a
  live proxy's `lpFundRecipient` two bytes down.
  `test/upgrade/GraduateIntoLaunchDollarLayout.t.sol:267` pins every byte offset in that slot.
- `setGraduatedCreatorYieldShareBps`, its event and its `initialize` default of `4_000` are
  deleted. No owner can reprice a leg that is already running, and a fresh deployment reads 0,
  which is correct — a fresh deployment's locker never reads it at all.
- `setGraduatedLpFundShareBps` keeps its `graduatedCreatorYieldShareBps + bps <= BASIS_POINTS`
  bound (`:862`), because the old locker reverts `ShareTooHigh` when that sum exceeds a whole
  leg. It is belt-and-braces while `MAX_LP_FUND_SHARE_BPS` is 5,000 (`:87`) — `4_000 + bps`
  cannot reach 10,000 through this setter — but the locker is not upgradeable and the cap is a
  constant somebody may raise, so the bound stays.

Existing positions in the old locker are unaffected: they are split by that contract's code,
which still has the yield leg, against a rate this factory still answers for.

## The spacing ladder

A graduated market's pool is quoted in a dollar that already exists, so its whole `PoolKey` is
public from the moment the launch is — `(quoteBrand, launchToken, listing.fee,
tickSpacingForFee(fee), ProtocolFeeHook)` — and `ProtocolFeeHook` declares
`beforeInitialize: false`, so `PoolManager.initialize` on that key needs no liquidity and no
permission. Pinning one spacing per fee tier left exactly five keys per launch token and
therefore a five-transaction denial of service over an entire raise. That is the audit's
`AMF-POOLSQUAT`.

`tickSpacing` is an independent field of pool identity in v4, so the remediation is a ladder:

| | |
|---|---|
| Depth | `LAUNCH_SPACING_RUNGS = 32`, `private constant` (`AssetMarketFactory.sol:146`) |
| The walk | `_walkSpacings` (`:1391-1410`) — `canonical = tickSpacingForFee(fee)`, then `canonical + 1 … canonical + 31`, stopping at the first key whose `getSlot0` reads zero |
| The launch path | `_resolveLaunchSpacing` (`:977-987`), called from `createLaunchMarket` and nowhere else (`:956`) |
| The owner paths | `_canonicalTickSpacing` (`:963-971`) — the tier's own spacing and nothing else |
| The view | `nextFreeTickSpacing(brandToken, asset, fee)` (`:1379-1385`) |

**The ladder is launch-path-only, deliberately.** `createMarket` and `createMarketForBrand` go
through `_canonicalTickSpacing`, which still reverts `PoolAlreadyInitialised` when the tier's
own key is taken: an occupied canonical key on an owner listing is a listing error the owner
fixes by re-approving at another tier, not something to route around behind their back. Only a
graduation — which has already swept a raise and cannot be asked to come back later — walks.

**`nextFreeTickSpacing` returns `0` when the ladder is exhausted rather than reverting**
(`:1368-1372`), because two different callers have to tell the two failures apart.
`_resolveLaunchSpacing` turns zero into `LaunchPoolLadderExhausted(asset, brandToken, fee)`
(`:534`, `:983`), and `LaunchFactory.setSweptLaunchPoolFee` must be *permitted* precisely when
the ladder is gone — a reverting view would make the one case the escape hatch exists for the
one case it could not read. It still reverts `UnsupportedFeeTier` for a tier with no canonical
spacing.

What comes out of the walk:

- `LaunchPoolSpacingShifted(asset, brandToken, fee, canonicalTickSpacing, tickSpacing)`
  (`:479-485`) — the market opened above the canonical rung. Emitted only when the two differ,
  so an unattacked graduation is silent. **This is the squat alarm**, and the runbook's event
  table says to alert on it.
- `LaunchPoolLadderExhausted(asset, brandToken, fee)` (`:534`) — an error, not an event: all 32
  rungs at this tier are taken, `createLaunchMarket` reverts, and the launch stays `Swept`
  behind `setSweptLaunchPoolFee` and, past that, the 7-day `rescueSweptGraduation`. See
  `AMF-POOLSQUAT-RESIDUAL-2` in *Accepted risks*.

An unattacked graduation pays one cold `getSlot0`, so the depth is only spent by a launch that
is actually under attack.

### `Market.tickSpacing` may now exceed `tickSpacingForFee(fee)`

This is the load-bearing consequence and the one thing to carry out of this section. **A
graduated market's tick spacing is no longer derivable from its fee tier.**

Everything in this repo is correct by construction: `_record` stamps `key.tickSpacing` into
`Market.tickSpacing` (`:1228`), `poolKeyOf` rebuilds the key from `m.fee, m.tickSpacing`
(`:1413-1417`), and `MarketLens`, `MarketRouter`, `LiquidityZapper`, `V4SwapSimulator`,
`LpRewardDistributor.poolKey()`/`fullRange()`, `LaunchGraduation._mintFullRange` and the
frontend all read the stored spacing or `poolKeyOf` — never a fee→spacing table. The audit
traced all of them.

Anything *outside* this repo that reconstructs a `PoolKey` from a v3-style fee→spacing table
finds the squatter's pool instead of the market's on an attacked launch. That is
`AMF-LADDER-DECOY`, and it is why the ladder has a documentation cost as well as a gas one:

- `docs/0x/MARKETS.md` §2 no longer states a venue-wide `tickSpacing`, and §8 says that a
  graduation under attack opens off-canonical and that the canonical key may then hold a
  hostile pool.
- The runbook's post-graduation check asserts
  `market(id).tickSpacing == tickSpacingForFee(market(id).fee)` and records the decoy's pool id
  when it does not hold, so the decoy can be excluded from any venue listing.

The squatted key is *left in place*, initialised at a price the squatter chose and seedable by
them at any time. Refusing an occupied key was what previously guaranteed the canonical key was
either the market or nothing; the ladder trades that guarantee for availability, which is the
right trade, but the discarded guarantee was load-bearing for off-chain discovery and that is
now a documented fact rather than a silent one.

## What was built, file by file

### 1. `src/launchpad/interfaces/ILaunchpad.sol`

- `Seed` (`:123-134`) no longer carries `unitName` or `unitSymbol`: graduation mints no unit.
- `ILaunchFactory.graduatedCreatorYieldShareBps()` stays (`:84`), with NatSpec saying exactly
  who reads it and that it is not settable.

### 2. `src/launchpad/LaunchFactory.sol`

- `_seed` (`:1192-1209`): the two `string.concat` lines and the
  `IERC20Metadata(token).symbol()` read are gone, and the `@dev` above it says why — "no unit
  is named: the market opens quoted in the brand the curve was quoted in".
- Launch collateral is keyed by **reserve**, not by brand. `ReserveEconomics` (`:178-186`) drops
  the struct's old `reserve` field — the market factory already answers that — and lives in
  `mapping(address reserve => ReserveEconomics) public reserveEconomics` (`:398`, slot 18),
  written by `setReserveEconomics` (`:704-731`) and switched by `setReserveApproved`
  (`:735-740`). The per-brand pair `setPairTokenEconomics` / `setPairTokenApproved` is retired,
  not aliased, and the slot the old mapping occupied is left as an unread placeholder
  (`__retiredPairTokenEconomics`, slot 13) rather than repurposed.

  The motivation is rollout cost. Collateral approval was per brand, so every new platform
  stablecoin needed a manual owner transaction before anyone could launch against it, and
  until that transaction landed the dollar was unlaunchable for no economic reason. Economics
  are a property of the reserve: every brand is a costless 1:1 wrapper of the reserve asset,
  minted at the reserve's `assetDecimals`, so a phantom reserve and a graduation threshold
  sized for one brand of a reserve are sized for all of them. The reserve is the right key,
  and a dollar issued tomorrow is launchable immediately.
- The two per-brand guards still exist and are still mandatory. They moved from **owner time**
  to **launch time**, into the private `_quoteReserve(pairToken)` (`:1414-1425`) that
  `launchEconomics` (`:509-516`) — and therefore every launch, every preview and every router
  quote — calls through.
  - `marketFactory.reserveOfBrand(pairToken) != 0` (`:1415-1416`), else
    `PairTokenNotRegistered` (`:209`). Without this, a brand registered straight on the reserve
    leaves `reserveOfBrand` zero and `_record` stamps the **default reserve** into
    `Market.reservePool`, which silently corrupts `MarketLens.maxMint` / `redeemableAssets`.
  - That reserve must be the market factory's default or an `approvedReservePool`
    (`:1417-1420`), else `ReserveNotApproved` (`:214`). Previously implied by the stored
    `reserve` field; now re-read on every launch, because the owner may retire a reserve
    afterwards and a launch created against a retired one is pinned in `Swept` forever.
  - `PoolBrandTreasury(marketFactory.treasuryOfBrand(pairToken)).factory() == address(marketFactory)`
    (`:1421-1424`), else `PairTokenFloatShareUnavailable` (`:213`). The issuer must have opted
    in before their dollar can be a launch quote. **`slUSD` has no treasury here at all** and
    so never reaches this check — it fails the first one — see the deployment section.

  Checking them per launch rather than per approval is strictly tighter: a treasury that
  revoked `setFactory` after an owner approval used to leave a stale approval standing, and now
  stops quoting new launches the moment it revokes. It is also strictly quieter, which is the
  operational cost — see H4 in the runbook. The closed-reserve refusal is
  `ReserveClosed(reserve)` (`:207`, raised at `:969`), which replaces the factory's
  `PairTokenNotApproved`; `LaunchRouter.PairTokenNotApproved(address)` keeps its name and
  selector (`LaunchRouter.sol:113`, raised at `:546`) and is what a caller sees when the
  brand's reserve is closed. The `@dev` on the setter (`:692-703`) states the split — the
  reserve is chosen here, the brands are not — and no longer describes the 1:1 unit swap that
  is gone.
- **`graduatedCreatorYieldShareBps` survives as a `public` getter** (`:359`); only its setter,
  its event and its `initialize` default of `4_000` are deleted, and
  `setGraduatedLpFundShareBps` keeps its bound against it (`:862`). See *What the creator
  loses* above; `ILaunchFactory` keeps the getter (`interfaces/ILaunchpad.sol:84`).
- **New: `setSweptLaunchPoolFee(address token, uint24 fee)`, `onlyOwner`**
  (`LaunchFactory.sol:1261`). This is the second half of the audit's `AMF-POOLSQUAT`; the
  spacing ladder above is the first and it fires first, automatically, inside
  `createLaunchMarket`. What this setter still covers is the case the ladder cannot: an
  attacker who has taken **every one of the 32 rungs** at the launch's current tier, which
  `createLaunchMarket` reports as `LaunchPoolLadderExhausted`. Moving the tier hands graduation
  a whole fresh ladder for one owner transaction. Accordingly the gate is
  `marketFactory.nextFreeTickSpacing(launch.pairToken, token, previousFee) != 0` (`:1272-1273`),
  which reverts `LaunchPoolLadderNotExhausted(token)` (`:229`) — occupying only the canonical
  key does **not** unlock the setter, because graduation walks past that by itself. The earlier
  gate compared the view against `tickSpacingForFee(previousFee)`, which was the right test for
  "is the canonical key taken" and the wrong one for "has the ladder run out"; the old error
  name `LaunchPoolNotSquatted` is deleted, not aliased. Owner-only because the tier is a
  term the creator was quoted and is part of `_economicsDigest`; accepted only in
  `NotGraduated` and `Swept`; and the new tier is run back through `tickSpacingForFee` and
  `LaunchGraduationGuard.assertSeedableEitherOrdering` on the launch's actual amounts — using
  the new tier's canonical spacing, the conservative choice whichever rung graduation lands on
  — so a squatted tier cannot be swapped for one the mint would then refuse. Emits
  `LaunchPoolFeeRetiered(token, previousFee, newFee)` (`:256`).
- **New dependency: `LaunchGuardDeployer`**, an external library holding
  `LaunchGraduationGuard`'s 2,970 bytes of creation code
  (`src/launchpad/libraries/LaunchGuardDeployer.sol:39`), called by `initialize`
  (`LaunchFactory.sol:435`). This is an EIP-170 measure and nothing else: an inline `new`
  would carry the guard's creation code in the factory's own runtime, which is the whole of why
  the factory went over the limit. Because it is a `DELEGATECALL`, **a `LaunchFactory`
  implementation deployed unlinked deploys a proxy whose `initialize` reverts** — and an
  unlinked build simulates cleanly through `upgradeToAndCall` against an already-initialised
  proxy, so the breakage only surfaces on the next fresh deployment. Measured sizes below.

### 3. `src/markets/AssetMarketFactory.sol`

- `createLaunchMarket` (`:927-958`): gains a `brand` argument, drops `_registerBrand`.
  Validates like `createMarketForBrand`: `reserveOfBrand[brand]` nonzero (`BrandNotRegistered`),
  that reserve equal to the resolved one (`ReserveNotApproved`), `asset != brand`. Then
  `_openMarket(brand, creator, asset, listing, /*shared=*/ true,
  _resolveLaunchSpacing(brand, asset, listing.fee))` (`:955-957`).
- **New: the spacing ladder** — `LAUNCH_SPACING_RUNGS` (`:146`), `_walkSpacings`
  (`:1391-1410`), `_resolveLaunchSpacing` (`:977-987`), `_canonicalTickSpacing` (`:963-971`),
  the `nextFreeTickSpacing` view (`:1379-1385`), the `LaunchPoolSpacingShifted` event
  (`:479-485`) and the `LaunchPoolLadderExhausted` error (`:534`). `_openMarket` gained a
  `tickSpacing` argument so the policy lives in one place. Full treatment in *The spacing
  ladder* above, including the consequence that `Market.tickSpacing` may exceed
  `tickSpacingForFee(fee)`. No new storage: the spacing was already a `Market` field.
- `_validateListing`: the `unitName`/`unitSymbol` emptiness check is split into the two paths
  that still mint a unit. The launch path no longer supplies them.
- **New `recordLaunchFloat(uint256 marketId, uint256 amount) returns (bool landed)`**,
  `msg.sender == launchpad` (`:1029-1051`). Three validations, in this order:
  1. `marketOfBrand[m.brandToken] != marketId`, else `NotSharedQuote` — a market that owns its
     brand already draws the whole of that brand's yield through its treasury, so float on top
     double-counts.
  2. `amount <= SharedReservePool(m.reservePool).outstandingOf(m.brandToken)`, else
     `FloatExceedsSupply` — a float above the brand's whole supply is not a measurement of
     anything, and it is destructive rather than merely unfair: once `totalFloat` is large
     enough that the treasury's index credit floors to zero while `marketReserve` still grows,
     that underlying is unreachable by the issuer and by every vault, permanently.
  3. `launchFloatOf[marketId] == 0`, else `FloatAlreadyRecorded` — a market's seed is measured
     once, by its graduation. The guard keys on `launchFloatOf` and not on the treasury's
     `floatOf`, because `retireMarket` zeroes the latter.
  This is the audit's `AMF-FLOATTRUST`.
- **New `launchFloatOf[marketId]`** (`:431`), written BEFORE the treasury is touched, and the
  treasury call is wrapped in `try/catch`: `landed == false` means the figure is pinned and
  retryable. `__gap` shrinks to `uint256[38]` (`:434`). See §4 for why.
- **New `retryLaunchFloat(uint256 marketId)`, permissionless** (`:1079-1091`). The only figure
  it can register is `launchFloatOf[marketId]`, so there is nothing for a caller to steer, and
  making it `onlyOwner` would replace a third party's veto over a graduated market's yield with
  the protocol owner's. It reverts rather than swallowing, so a caller sees the treasury's own
  reason (`OnlyFactory` while consent is revoked, `EnforcedPause` while the reserve is paused).
  Guards: not retired (`marketOfAsset` still names it), and not already registered. The supply
  bound is deliberately NOT re-checked — it was checked when the graduation measured it, and
  the treasury caps the markets' weight at `outstanding` on every pull anyway.
- `retireMarket`: also `registerFloat(m.feeVault, 0)` when the market is a shared quote,
  so a retired market stops drawing the issuer's yield.

### 4. `src/launchpad/LaunchGraduation.sol`

- `_createMarket` (`:313-338`): passes `seed.pairToken`, and the listing's `unitName` /
  `unitSymbol` are empty strings and stay empty — this listing mints nothing.
- `graduate`: the `SharedReservePool(seed.reserve).swap(...)` step is gone. `r.unit` is
  `seed.pairToken`, and the contract already holds exactly `seed.quoteAmount` of it.
- After `locker.recordPosition`, `marketFactory.recordLaunchFloat(r.marketId, r.unitSeeded)` —
  **best-effort, in a `try/catch`** (`:254-258`), emitting `LaunchFloatDeferred(marketId,
  amount)` when it does not land. This is the audit's `LF-FLOATSTRAND`. The opt-in behind it is
  a third party's and is revocable, and the pull runs through a reserve that can be paused, so
  an unconditional call would have handed a party outside the protocol's trust boundary a
  unilateral freeze on every in-flight graduation in that brand — total revert, whole raise
  stuck in `Swept`, only exit the owner's 7-day `rescueSweptGraduation`. Two halves: `landed ==
  false` means the amount is pinned in `launchFloatOf` and anyone can finish it with
  `retryLaunchFloat`; the `catch` covers a revert on the factory's own side, which rolls the
  record away with it, so there is nothing to retry and the event is all that is left to say so.
- **`_creditUnitDust` computes a residue, not a balance** (`:367-376`): the signature is now
  `(unit, quoteAmount, unitSeeded)` and the body is `dust = quoteAmount - unitSeeded`. This is
  the audit's `LG-DUSTDOS`. Reading `balanceOf(address(this))` was safe only while `unit` was a
  brand minted inside the same transaction; the quote leg is now a live ERC-20 that anybody
  holds and can transfer to this contract's fixed, public address, and one donation above
  `MAX_DUST_BPS` (10 bps) of a raise would have made every graduation in that brand revert
  forever — permanently, because the revert undoes the credit and the module is not upgradeable.
  The subtraction cannot underflow: `amount0Max`/`amount1Max` are set to exactly `quoteAmount`,
  so `SETTLE_PAIR` can never pull more. The `MAX_DUST_BPS` ceiling keeps its original meaning —
  it still catches a coarse `assetPriceE18`.
- **New `sweepStray(address token)`, permissionless** (`:294-303`). A donated balance is now
  ignored by the dust path, so it needs a way out; it is credited to `protocolFeeRecipient`
  through the escrow, like every other protocol fee. It cannot take anything a graduation is
  holding: `graduate` disposes of everything the factory sent it before it returns, and
  `nonReentrant` is shared with `graduate`. Emits `StraySwept(token, amount)`.
- Drop the `SharedReservePool` import.

### 5. `src/pool/PoolBrandTreasury.sol`

As above, plus `namedFactory` and the one-way `setFactory`. `initialize` is **unchanged**, so
`SharedReservePool` needs no edit and no upgrade: every treasury, live or future, opts in
through `setFactory`. `Claimed` is now `(uint256 claimed, uint256 amount, address indexed
receiver)`; `FloatRegistered`, `FloatSharePulled` and `FloatShareClaimed` are new.

### 6. `src/markets/BrandFeeVault.sol`

`harvest()` only (`:228-235`): it routes to `treasury.claimFloatShare()` when the vault is not
the treasury's admin, and keeps the old `treasury.claim(address(this))` path when it is. One
extra view call, no new init parameter, no new storage.

### 7. `src/markets/LpRewardDistributor.sol`

- New `rewardsRenounced` mapping (`:213`, slot 22), `minStakeWeight` (`:227`, slot 23),
  `_floorSet` (`:233`, slot 24), `RENOUNCED_FLOOR_DIVISOR` (`:119`), `renounceRewards()` and
  `setMinStakeWeight(uint256)`, as above. `__gap` shrinks from `uint256[40]` to `uint256[37]`
  (`:236`) and the footprint stays 62 slots.
- `stake` (`:404-406`): exempts a renounced beneficiary, and enforces `minStakeWeight` against
  the position's raw liquidity for everyone else — `StakeBelowFloor(liquidity, floor)` (`:272`).
  The liquidity is `positionManager.getPositionLiquidity(tokenId)` (`:397`); it enters
  `totalStaked` only for a non-renounced beneficiary (`:422`).
- `renounceRewards` (`:523-565`) measures the floor at most once per market (`_floorSet`,
  `:556-557`) and only from an account holding the whole **earning** book — `totalStaked ==
  stakedLiquidityOf[msg.sender]`, read at `:532-537` before the subtraction — which is the
  graduation seed by construction. It writes only upwards (`:558`).
- **New `setMinStakeWeight(uint256)`, `configAdmin`-gated** (`:605-611`): moves the floor in
  either direction, with no bound and no settlement, because `stake` is the only reader. Zero
  restores the original rule. This is the recovery path for a floor that is wrong, and the
  reason `LPRD-FLOOR-SOLESTAKER` is a grief rather than a lockout. `configAdmin` is derived
  live from the shared guard's owner (`:575-577`), not stored.
- `unstake` (`:439-461`) subtracts the position's recorded liquidity from `stakedLiquidityOf`
  unconditionally and from `totalStaked` only when the account has not renounced (`:446-452`) —
  the exact mirror of what `stake` added. That pairing, not a cache sweep, is what keeps the
  book honest across a renunciation.
- New events `RewardsRenounced(address indexed account, uint256 liquidityGivenUp)` (`:242`),
  `MinStakeWeightRaised(minStakeWeight)` (`:246`) — emitted only when the measurement actually
  raises the floor — and `MinStakeWeightSet(minStakeWeight)` (`:249`), emitted by the setter.

### 8. `src/launchpad/LaunchLocker.sol`

- `recordPosition` (`:137`): calls
  `LpRewardDistributor(position.distributor).renounceRewards()` (`:158`) after the custody
  check, in the same transaction as the stake, so no reward is ever credited.
- `collect` (`:199`): the yield leg is gone entirely — the `distributor.earned` /
  `distributor.claim` block, `yieldOut`, `yieldShareBps`, `yieldToCreator`, `yieldToLpFund`,
  and the second unit-balance read that only existed to separate the two streams. `unitOut`
  became `feeUnit`. The `Collected` event lost its two yield fields and `ILaunchLocker`
  followed. **This is the new locker only**; the deployed one keeps both legs and keeps
  reading `graduatedCreatorYieldShareBps()`.

### 9. Frontend — `web-stable/` — landed

The user-visible half of the original complaint. Past `.d` units still exist and still pollute,
so every one of these is a filter rather than a migration. All four have shipped; the suite is
906 passing with typecheck and lint clean.

- `src/config/platform-contracts.ts:213-216`: brands with `marketId !== 0n` are classed as
  units and kept out of the `stablecoins` catalogue, the way
  `src/features/launchpad/quote-choices.ts:107` already did. This removes `.d` from
  `/stablecoins`, header search, and the stablecoin counter in
  `src/components/shell/platform-stats.ts:61`.
- `src/features/asset-markets/stable-convert.tsx:89-93`: the same filter on the mint/convert
  list, so a `.d` can no longer be seeded as `brands[0]` or offered in the token menu. A
  deep-linked unit is still resolvable, but only when explicitly requested.
- `packages/market-core/src/reserve-brands.ts:85,170`: `marketId` is read from the registry
  multicall and carried on every `ReserveBrand`, rather than defaulting to `0n` whenever
  `config.factory` is absent — which used to disable **every** `marketId === 0n` filter for
  reserve-only strategy groups. Note the path: this module lives in `packages/market-core/`,
  not under `backend/market-reader/` as an earlier revision of this document said.
- `src/features/launchpad/launch-wizard.tsx:1159-1164`: the hardcoded "Creator share of pool
  fees after graduation — 100.00%" is gone. The wizard renders the live `creatorFeeShareBps`
  and states in the same paragraph that the yield on the dollars in the pool goes to the
  market's liquidity providers.

### 10. Docs

Seven statements become false. They are prose, not contracts — no re-submission, but
`docs/SUBMISSIONS.md:61-71` obliges telling both teams that the live market set is changing
shape, because "the set of live markets" is one of the six listed rows.

**All seven have landed.** Checked against this worktree rather than assumed:

- `docs/0x/MARKETS.md:44-49` still states the `.d` split as today's fact, which it is, and
  `:51-57` immediately qualifies it — "**That split is history, not the rule.**" — with the
  pending change, the fact that 16/17/18 are not migrated, and the set of `.d` dollars being
  closed at three. The token table follows the same shape.
- `docs/0x/MARKETS.md:70-71` no longer states a venue-wide `tickSpacing` as fact: the `= 50` is
  now explicitly "a measurement of these six pools, **not a venue rule**", which is what the
  spacing ladder made necessary, and §8 carries the off-canonical case.
- `docs/AGGREGATOR_INTEGRATION.md:28-31` is the same today-statement and `:33-38` the same
  retirement note, plus the instruction that matters operationally: ask
  `AssetMarketFactory.isSharedQuote(marketId)` rather than inferring from a symbol.
- `docs/KYBERSWAP_INTEGRATION.md` — the `SDOGE.d` / `ABR.d` / `CORGIGG.d` framing is gone.
- `docs/MARKET_UNIT_STACK.md:24` — the unit/brand table now states the float-yield split:
  "its issuer, less the share owed to any markets quoted in it".
- `AGENTS.md` and `web-stable/src/config/market-logos.ts:6-11`, which now describe a graduated
  launch as quoted in the launch's own quote dollar rather than as minting `<TOKEN>.d`.

`docs/0x/SETTLER_COMPATIBILITY.md` §6 keeps its `.d` pair labels: that is a historical
measurement of six real pools and stays accurate.

---

## Tests

Foundry, in `test/`. Items 1–9 were the plan; 10 was revised during the audit and 11–15 are
what the three audit passes added.

1. **`test/launchpad/GraduateIntoLaunchDollar.t.sol`** (planned as `LaunchGraduationSharedQuote`)
   — launch against AIUSD, graduate, assert:
   the pool key is `(AIUSD, TOKEN)`; `allBrandTokensLength` did not grow; `marketOfBrand(AIUSD)` is
   still `0`; `Market.reservePool` is the launch's reserve, not the factory default.
2. **Float share** — `test/pool/PoolBrandTreasuryFloatShare.t.sol`. After graduation, accrue
   yield in the reserve, then `BrandFeeVault.harvest()` on the graduated market pays it
   `yield × unitSeeded / outstanding(AIUSD)`, and the issuer's `claim` pays the remainder.
   Assert the two sum to the whole claim within dust.
3. **Caps** — `totalFloat > outstanding` gives markets the whole claim and the issuer zero, never a
   revert or an underflow.
4. **Two graduated markets on one dollar** split pro-rata by their recorded seeds.
5. **`retireMarket`** zeroes a market's float and stops its accrual.
6. Existing `test/markets/SharedQuoteMarket.t.sol:522-544` pins `harvest()` reverting
   `OnlyAdmin` for a shared quote. That behaviour is what we are replacing — **delete that case**
   and replace it with the float-share assertion.
7. **Float yield reaches LPs and not the locker** — stake an ordinary LP beside a graduated
   position, accrue float, assert the locker's `earned` is zero and the LP took the whole stream.
8. **Trading fees still reach the locker** after `renounceRewards` — `collectFees` is weight-blind,
   so the 40/30/30 split must still pay out.
9. **40/30/30** — one `collect` credits the escrow `4000/3000/3000` bps of both the unit leg and
   the token leg, and the three sum to exactly what arrived.
10. **The yield-split tests were NOT removed.** The plan said to delete every locker test that
    asserts a `graduatedCreatorYieldShareBps` split. That was wrong for the same reason the
    getter's deletion was wrong — those splits are live behaviour on the locker serving markets
    16/17/18. `test/launchpad/GraduationAuditFixes.t.sol` now transcribes the pre-change
    locker's `collect` prologue into a probe contract and calls it against the upgraded
    factory, so a future upgrade that drops the selector fails there rather than on mainnet.
11. **`test/upgrade/GraduateIntoLaunchDollarLayout.t.sol`** is the authority on layout for all
    three upgraded contracts, re-derived against this base. It pins the packed slot (`:267`) —
    `graduatedCreatorShareBps` (2 bytes), `launchEnabled` (1), `graduatedCreatorYieldShareBps`
    (2), `lpFundRecipient` (20), `lpFundShareBps` (2), `graduatedLpFundShareBps` (2) — so
    nothing slides `lpFundRecipient`; the retired economics slot and `reserveEconomics` below
    it (`:302`, `:393`); the treasury's seven appended fields (`:504`); and the distributor's
    three, including slot 24 read directly because `_floorSet` has no getter (`:652`, `:701`).
    Each contract also gets an appended-field test proving the footprint did not move
    (`:458`, `:575`, `:730`). **Take slot numbers from here, never from an older revision of
    this document.**
12. **The spacing ladder and `setSweptLaunchPoolFee`** — `GraduationAuditFixes.t.sol`. A
    squatted canonical key graduates on the next rung and emits `LaunchPoolSpacingShifted`
    (`:300`), several squatted rungs are walked past (`:343`), an exhausted ladder is named
    `LaunchPoolLadderExhausted` and leaves the launch retryable (`:360`), and **both owner
    paths still refuse an occupied key** (`:404`, `:425`) — the ladder is launch-only. The
    setter is refused while the key is free (`:445`) *and* while the ladder still has one rung
    (`:459`, `:491` — one rung short, then gone), refused after graduation (`:532`), owner-only
    (`:543`), refuses an unsupported tier and an unknown token (`:556`, `:567`), and re-runs
    the seed preflight on the new tier's spacing (`:575`).
13. **Dust, stray and deferred float** — `test/launchpad/GraduationDonationAndRetry.t.sol`. A
    donation to the graduation module does not change `_creditUnitDust`'s verdict and
    `sweepStray` moves it to the protocol fee recipient through the escrow; a graduation whose
    treasury refuses still opens the market, emits `LaunchFloatDeferred`, pins `launchFloatOf`
    and is landed later by `retryLaunchFloat`; `recordLaunchFloat` refuses a market-owned
    brand, an over-supply amount and a second registration.
14. **`test/launchpad/LaunchGuardDeployerLink.t.sol`** — the guard deploys from the factory
    proxy's own nonce and not the library's (`DELEGATECALL`, not `CALL`), the factory
    preflights launch terms through the guard it recorded, and a launch whose seed the guard
    refuses fails there. The link itself is not asserted here; the runbook's H5 code-hash
    check is what covers an unlinked implementation, because an unlinked one only misbehaves
    on a *fresh* deployment and this suite never makes one through the upgrade path.
15. **The admission floor** — `test/markets/LpRewardRenounce.t.sol`. `mint → stake → renounce →
    unstake → burn` cannot ratchet a live market's floor (`:795`), a sole staker's renunciation
    still sets the floor that defends a graduation (`:856`), a second renunciation never raises
    it again (`:879`), a non-sole staker sets no floor and spends no shot (`:915`), and
    `setMinStakeWeight` is `configAdmin`-only and lowers the floor without touching a live
    stake (`:957`). Plus the original dust-capture cases: a dust stake is refused in a market
    whose seed renounced (`:584`), a proportionate one is admitted (`:618`), the floor is zero
    without a renunciation (`:643`), the floor never reaches `unstake` or `collectFees`
    (`:669`), and the smallest admissible stake takes only its proportion of a period (`:718`).

Run: `forge test --no-match-path 'test/*Fork*'` — **742 passed, 0 failed, 2 skipped** on this
tree. Fork files one at a time, with `--threads 1`; `test/LiveGen5Mainnet.t.sol` is 17/17 and
rehearses the whole rollout against live mainnet state.

Frontend: `npm --prefix web-stable test` (906 passing), `run typecheck`, `run lint`.

---

## What has to be deployed

**Seven contracts move.** Five are upgrades that keep their address; two are redeploys. An
eighth artifact, `LaunchGuardDeployer`, is deployed as a linked library rather than wired into
anything.

An earlier revision of this document said eight and listed three redeploys, because it carried
a `LaunchDeployer` rotation. **That row is gone on this branch** — see *Why there is no
`LaunchDeployer` step* below for the record of why it existed and what would bring it back.

The ordered operator procedure is `docs/GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md`. This section
says what moves and why; the runbook says in what order and how to check it.

### Upgrade in place — one Safe transaction each, address unchanged

| Contract | Mechanism | Note |
|---|---|---|
| `AssetMarketFactory` | UUPS (`:91`) | Proxy `0x22AA61c589B90731752236c07d1455D0065bfc79` stays. New impl links against the existing `MarketDeployer` library — no relink. |
| `LaunchFactory` | UUPS (`:64`) | |
| `PoolBrandTreasury` | **beacon** (`ProtocolStack.sol:104`) | One `upgradeTo` lifts every brand treasury at once. |
| `BrandFeeVault` | **beacon** (`ProtocolStack.sol:105`) | One `upgradeTo` lifts every market vault at once. |
| `LpRewardDistributor` | **beacon** (`ProtocolStack.sol:106`) | One `upgradeTo` lifts every market's distributor. `__gap` `uint256[40]` → `uint256[37]`: `rewardsRenounced` (slot 22), `minStakeWeight` (23) and `_floorSet` (24). Footprint unchanged at 62 slots. |

### Redeploy — new addresses

| Contract | Why |
|---|---|
| `LaunchGraduation` | Not upgradeable: plain `constructor` + immutables (`:116-145`). Its own NatSpec says replaceability is the reason it is a separate module (`:47-52`). |
| `LaunchLocker` | Forced by the above. Not upgradeable, and `setGraduation` is one-shot — `if (graduation != address(0)) revert AlreadyInitialized()` (`LaunchLocker.sol:118`). A new graduation module cannot be authorised on the live locker. |

### Not touched, not redeployed

`ProtocolFeeHook` — **byte-identical to the 0x submission on this branch** — `MarketLens`,
`V4SwapSimulator`, `MarketRouter`, `LiquidityZapper`, `SharedReservePool`, `LaunchFeeEscrow`
(`creditToken` is permissionless, `:40`), `LaunchRouter`, `MarketDeployer`, `LaunchDeployer`,
`LaunchCurve`, and every `PooledBrandToken`.

**This is what keeps the 0x and KyberSwap submissions intact.** Every address in
`docs/SUBMISSIONS.md:30-39` is either unchanged or a proxy that keeps its address.

### Wiring, after deployment

```
newLocker.setGraduation(newGraduation)                     // new locker's own owner
LaunchFactory.setGraduation(newGraduation)
AssetMarketFactory.setLaunchpad(newGraduation)
PoolBrandTreasury(AIUSD).setFactory(assetMarketFactory)    // issuer opt-in, per quote dollar
LaunchFactory.setLpFundRecipient(protocolTreasury)         // the LP fund, for now
LaunchFactory.setGraduatedLpFundShareBps(3_000)
LaunchFactory.setGraduatedCreatorShareBps(4_000)           // live value is already 4_000
```

Then `LaunchFactory.setReserveEconomics` is called once per **reserve**, not once per quote
dollar — a first write rather than a re-assertion, because the reserve-keyed mapping is new
storage and reads zero, which is closed, until it lands. `setLpFundRecipient` must precede
`setGraduatedLpFundShareBps`; that one is load-bearing, not tidy. `setFactory` no longer has to
precede the economics write — the float-share opt-in is read at launch time now — but it still
has to land before anybody launches in AIUSD, and a missing opt-in is now a silently
unlaunchable brand rather than a refused owner transaction. See H4 in the runbook.

**AIUSD's treasury admin is the Safe itself**
(`PoolBrandTreasury(0xE2d144F8b18d4743fdC4D74e4AE621307e443e38).admin()` →
`0x28569c1716EF81f307d666A1EC08bDAE92AC0373`), so the Safe performs AIUSD's `setFactory`. Its
`brandOperatorOf` is still the deployer EOA `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` —
that is a metadata role, not an authority on the treasury.

**`slUSD` is the other brand that used to carry an approval, and it cannot take this wiring at
all.** Verified live:
`AssetMarketFactory.treasuryOfBrand(0xE20cE31a996f07b3d70F9C840e6810F0f572C884)` and
`reserveOfBrand(...)` are both zero, because slUSD was registered straight onto the sUSDai
reserve rather than through the market factory. Under the old per-brand keying that was a
rollout step: the stale `approved == true` entry had to be taken off by hand, and a launch
quoted in slUSD would otherwise sweep and then revert `BrandNotRegistered` in
`createLaunchMarket` forever.

Keying by reserve removes the step instead of leaving a gap. slUSD is refused automatically and
structurally: `launchEconomics(slUSD)` reverts `PairTokenNotRegistered` at
`LaunchFactory.sol:1416` — `reserveOfBrand(slUSD)` is zero — before any figures are read, so
there is no entry to close and no path that reads the sUSDai reserve's economics on slUSD's
behalf. Registering slUSD properly through the market factory, and its issuer opting into float
sharing, is the only thing that would make it launchable, which is the same bar every other
dollar meets. The runbook's step 3, which used to be a `setPairTokenApproved(slUSD, false)`
Safe call, is now a verification read.

### The locker swap

Positions locked by the three existing graduates stay in the locker that took them,
`0xACf51B066b90596e8536A1423Df4A6b94D5815c9`, which keeps working: `LaunchFactory` stores no
locker pointer, and it already documents multi-locker turnover ("positions staked through an
earlier locker are split by that contract's code"). Those creators keep their 100% fee rate
and their yield leg, because that is the contract their launches were sold under — and that
is exactly why `graduatedCreatorYieldShareBps()` had to stay on the factory.

The locker the live graduation module names today, `0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C`,
holds no positions: nothing has graduated since the 2026-09-19 LP-fund rotation. It is retired
by this rollout with nothing stranded in it.

`web-stable/src/web3/launchpad-config.ts:38` reads a single `NEXT_PUBLIC_LAUNCH_LOCKER` and will
point at the new one, so the old graduates lose their fee-collect UI. **Out of scope by decision:**
two creators, helped by hand. `collect` and the escrow claim are both permissionless, so nothing is
stranded.

### Build risk — measured, not assumed

`forge build --sizes` on this tree, EIP-170 limit 24,576:

| Contract | Runtime bytes | Margin |
|---|---|---|
| `Probe_AssetMarketFactory` (test-only) | 24,406 | **170** |
| `AssetMarketFactory` | 24,365 | **211** |
| `LaunchFactory` | 20,287 | 4,289 |
| `LaunchGraduation` | 9,056 | 15,520 |
| `LpRewardDistributor` | 8,980 | 15,596 |
| `BrandFeeVault` | 5,452 | 19,124 |
| `PoolBrandTreasury` | 5,247 | 19,329 |
| `LaunchLocker` | 5,027 | 19,549 |
| `LaunchGuardDeployer` (library) | 3,203 | — |

**The test probe hits the limit first, so 170 is the headroom to plan against, not 211.**
`Probe_AssetMarketFactory` (`test/upgrade/UpgradeInvariants.t.sol:70`) inherits the factory and
appends one `uint256` plus an explicit getter — 41 bytes over its parent — precisely so the
build fails before a real storage slot is added that would not fit. An addition that leaves
the deployable artifact legal can still break the offline suite, so read both rows.

`AssetMarketFactory`'s **211 bytes** is the number to watch after that: the spacing ladder
spent 261 of the 472 this document reported before the audit remediations, and the contract is
now under 1% of the limit. `MarketDeployer` already exists to keep it under
(`MarketDeployer.sol:16-19`). Treat any further addition to that contract as needing a size
check *before* the code is written, not after.

`LaunchFactory`'s 4,289 is not slack. It is the whole of what moving `LaunchGraduationGuard`'s
2,970 bytes of creation code into `LaunchGuardDeployer` bought; the next helper that needs
`new` in that contract needs the same treatment.

`foundry.toml:34-77` carries the same figures, re-measured on this branch. Change both together.

## Explicit non-goals

- **Existing `.d` markets are not migrated.** Markets 13–18 and every past graduate keep their unit
  and keep working. Only graduations after this change use the shared quote.
- **No live-float tracking.** The weight is the recorded seed; it does not follow the pool's
  balance, and later LPs do not add to it.
- **No hook change.** Any new hook permission is a new hook address and a new 0x submission.
- **No `SharedReservePool.claimYield` gate change.** The reserve keeps one principal per brand.
- **No creator claim UI for the old locker.** See above.
- **No per-market LP fund.** `lpFundRecipient` is one global address and points at the protocol
  treasury until a real fund exists.
- **No re-measurement of a market's float.** See *Accepted risks*, next.
- **The pool squat is priced, not closed.** No randomised ladder start and no adoption of a
  squatted pool. See `AMF-POOLSQUAT-RESIDUAL-2` in *Accepted risks*.
- **No `floorSetter` on the distributor.** The admission floor is still guarded by a
  sole-staker test rather than by a named account. See `LPRD-FLOOR-SOLESTAKER`.

## Accepted risks

### The float seed is recorded once and never re-measured (`PBT-STALEFLOAT`)

Raised by the audit as medium and **deliberately not fixed**. Written down here rather than
left as a silence.

`PoolBrandTreasury.floatOf[vault]` is `Result.unitSeeded` — the quote-brand amount the
graduation's mint actually consumed — written once by `recordLaunchFloat` and never touched
again except by `retireMarket`, which zeroes it. It is not a measurement of what the pool holds
now. It is a measurement of what the pool held at graduation.

**Why it is not fixed.** A pool's live brand balance is not readable: Uniswap v4 holds every
pool's tokens in one singleton, and the hook cannot be taught to track it without new
permission flags — which would change the hook address and invalidate the 0x submission
(`docs/SUBMISSIONS.md:66`). A recorded seed is exact at graduation, needs no ongoing accounting
anywhere, and costs one storage slot.

**What it means when the pool trades down.** The locked position is full-range, so as the
launch token is bought the pool's quote-brand balance falls and its token balance rises. The
market's recorded float does not follow it down. That market then draws a share of the brand's
yield sized to dollars that are no longer sitting in its pool, and the difference comes out of
the issuer's side of `claim` and out of every other float-registered market's share. The
converse also holds and is the more common case in practice: a pool that trades *up*, or that
later LPs add depth to, holds more of the brand than its recorded seed and is under-paid,
because later LPs do not add to the weight either.

**The dilution ceiling.** `_pull` caps the markets' weight at
`min(totalFloat, outstanding)`, so the markets between them can never be owed more than the
whole claim. The failure mode at the ceiling is therefore not an underflow or a revert — it is
that once `totalFloat >= outstanding`, the issuer's `claim` returns **zero** and the entire
brand's yield divides among the registered markets pro-rata by their stale seeds. Holders of
the brand in wallets are not harmed — their redemption is 1:1 and carries no `whenNotPaused` —
but the issuer's own economics go to nothing. On a brand whose supply is mostly locked in
graduated pools that is arguably correct; on a brand whose holders have redeemed down below
the sum of the seeds it is not, and nothing re-measures it back.

**The sketched remedy, for a later release.** A permissionless
`AssetMarketFactory.repriceLaunchFloat(marketId)` could re-run `registerFloat` with a fresh
figure, and `registerFloat` already handles that correctly: it pulls and settles the vault's
checkpoint before the weight moves, so a changed float never reprices what a vault already
earned. `recordLaunchFloat`'s once-only guard (`launchFloatOf != 0`,
`AssetMarketFactory.sol:1044`) would have to become a bound rather than a latch — that latch
is exactly what currently makes an arbitrary float unregisterable, so replacing it is the
whole of the security work.

**Where the fresh figure comes from is the open question, and this branch makes it harder
rather than easier.** `LpRewardDistributor` here weighs a staked position by its raw v4
liquidity (`stake`, `:397`) and nothing else — no tick range, no price, no `reprice`. Raw
liquidity is constant as a full-range position's pool trades, which is precisely why it does
not answer "how much of the brand is in that pool now". So the arithmetic has to come from
somewhere else: the position's current quote-leg amount at a manipulation-resistant price,
pinned to a mean the caller cannot move within a block. That is a real piece of design, not a
reuse of something already present, and it is why this is a sketch rather than a plan.

### The spacing ladder prices the pool squat, it does not close it (`AMF-POOLSQUAT-RESIDUAL-2`)

Raised by the third audit as medium and **deliberately not fixed in this release.** Written down
in the audit's own terms, because a ladder is easy to mistake for a closed finding.

**What the ladder buys.** Against an opportunistic squatter — one who takes one key, or five —
it is a complete and invisible fix. The walk and the `initialize` are in the same transaction,
so there is no front-running window: graduation steps past the squat, emits
`LaunchPoolSpacingShifted`, and nobody has to do anything. That is a real improvement over a
one-transaction kill, and the implementation of it is correct.

**What it does not buy.** Every rung is as predictable as the first. The key is
`(quoteBrand, launchToken, fee, canonical + k, ProtocolFeeHook)`; there is no salt, no
block-dependent offset and no per-launch entropy, and `ProtocolFeeHook` still declares
`beforeInitialize: false`. So all **160** keys — 32 rungs across five fee tiers — are computable
the moment the launch token's address is public, which the launch event makes it hours or days
before the curve crosses. An attacker who pre-initialises all 160 makes `_resolveLaunchSpacing`
revert `LaunchPoolLadderExhausted` on every tier the owner can select, and
`setSweptLaunchPoolFee` has nowhere left to move the launch. The raise then sits in `Swept`
behind the owner's 7-day `rescueSweptGraduation` and an off-chain distribution — which is
exactly the outcome the first audit rated high.

**The cost, without flattering ourselves.** `PoolManager.initialize` against a hook with no
`beforeInitialize` permission writes one slot and emits: order 50–70k gas each, around 11M gas
for all 160. That is roughly $600 on mainnet at 20 gwei and **single-digit dollars on the L2
this deploys to** — not a meaningful deterrent against a raise worth thousands. The ladder is a
160× cost multiplier, not a wall. The contract's own NatSpec says so (`:136-143`); this
document is where an operator or a creator will actually read it.

**The mitigation, stated honestly.** A determined attacker can, for single-digit dollars of
gas, force any launch into the 7-day rescue path and an off-chain distribution. The protocol's
defence is that this is **loud** — `LaunchPoolSpacingShifted` on the first rung it steps over,
`LaunchPoolLadderExhausted` when it runs out — **not that it is impossible.** Nothing on a
public chain can make it impossible while initialisation is permissionless. Both are in the
runbook's alert table for that reason. The ladder also has a discovery cost, `AMF-LADDER-DECOY`
— see *The spacing ladder* above.

**The two candidate real fixes, for a later release**, recorded with their caveats rather than
left to be rediscovered:

1. **Randomise the ladder's start rung.**
   `uint256 start = uint256(blockhash(block.number - 1)) % LAUNCH_SPACING_RUNGS`, then walk
   `canonical + ((start + i) % LAUNCH_SPACING_RUNGS)`. Roughly four lines, no ABI change, and
   the honest path still stops at the first free rung. A squatter must still take all 32 to be
   sure, but can no longer pre-commit to a cheaper partial squat. *Caveat:*
   `nextFreeTickSpacing` would have to stay deterministic for `setSweptLaunchPoolFee`'s gate,
   so it would have to report the canonical-occupancy answer only — a different view from the
   one graduation walks.
2. **Adopt the squatted pool instead of routing around it.** A squatted key carries no
   liquidity, and `PoolManager.swap` on a zero-liquidity pool with `sqrtPriceLimitX96` set to
   the target moves the price to the limit while settling zero tokens. `_ensurePool` could,
   when `getSlot0 != 0` **and** the pool's liquidity is zero, unlock and price-correct the
   squatted pool, keeping the ladder as the fallback for a squatter who also seeded liquidity.
   *Caveats:* the tick-bitmap walk from an extreme squatted price is gas-linear in the words
   crossed — worst case around 3,400 iterations at spacing 1 — and a squatter who front-runs
   with real liquidity defeats adoption outright. So this complements the ladder rather than
   replacing it.

### The admission floor can be set once on a market with no stakers (`LPRD-FLOOR-SOLESTAKER`)

Raised by the third audit as low, **deferred rather than fixed**, for the reason at the end.

**What is sound, and it is most of it.** The sole-staker test is `totalStaked == given`, where
`given` is the caller's own `stakedLiquidityOf` read before the subtraction (`:532-537`). Both
quantities move together and only through `stake` (`:421-422`) and `unstake` (`:447-452`),
under the same `rewardsRenounced` flag, and `unstake` refuses anyone but the staker
(`OnlyStaker`, `:442`). So `totalStaked == SUM(stakedLiquidityOf)` over non-renounced accounts
holds exactly, the test is true if and only if the caller is the only account still earning,
and nobody can be evicted into satisfying it. **The graduation path is provably immune:**
`LaunchGraduation.graduate` deploys the market and its distributor, mints, calls
`stake(positionId, address(locker))`, then `locker.recordPosition` calls `renounceRewards()`.
The distributor does not exist before that transaction, so nothing can have staked first, and
`positionManager.transferFrom` inside `stake` is plain ERC-721 with no receiver callback —
there is no reentrancy point between the stake and the renounce.

**What survives.** The test is *trivially* true on a distributor with no earning stakers at
all: the state of every market created by `createMarket`/`createMarketForBrand` between
deployment and its first LP, and of any market whose LPs have all exited. From a fresh address
— mint a position, `stake`, `renounceRewards()`, `unstake`, burn — one transaction, all capital
recovered, only gas and one block of carry paid. `minStakeWeight` is left pinned at 1 bp of
whatever liquidity was briefly posted, and every LP below it is refused `StakeBelowFloor`
until `configAdmin` calls `setMinStakeWeight`.

**The bound, and its units.** `RENOUNCED_FLOOR_DIVISOR` divides **raw v4 position liquidity**,
not a capital weight: the floor lands at `given / 10_000` where `given` is
`stakedLiquidityOf[msg.sender]`, and `stake` compares the same quantity —
`positionManager.getPositionLiquidity(tokenId)` (`:397`) — against it. Both sides of the
comparison are therefore in one unit, which is the whole of why 1 bp means 1 bp here. To lock
out an LP a hundredth the size of the briefly-posted position, an attacker must post that
position: locking out a $10k LP needs roughly $100M of liquidity assembled and unwound, and
the round trip pays the reserve's redemption fee — 20 bps on the shipped reserve
(`docs/0x/MARKETS.md:281`) — on the notional, so about $20k of real cost for a $1,000 floor.

There is no boost multiplier to widen that: this branch has no tightness boost, no
`boostCapBps`, and no `inRangeOnly`, so the mismatch an earlier revision of this document
warned about does not exist. If a boosted weight is ever introduced, the two sides of the
`stake` comparison must be introduced with it or the ratio stops being 1 bp.

**Recovery is one transaction.** `setMinStakeWeight` is `configAdmin`-gated and moves the floor
in either direction with no bound (`:605-611`), which is what makes this a grief rather than a
permanent lockout. It also means the admin can set an arbitrary floor at will. That is not a new
trust boundary — `configAdmin` is read live off the shared guard's owner (`:575-577`), which is
the same key that upgrades the beacon this implementation is served from — but the power now
exists in a cheaper form, and it is written down here rather than left implicit.

**The clean fix, for a later release.** Name the account allowed to measure, instead of
inferring it from the book. Add `address public floorSetter` to `LpRewardDistributor.initialize`
— one slot out of the 37 left in `__gap` — have `AssetMarketFactory._deployParams` (`:1181`)
set it to the graduation module's `locker` (`LaunchGraduation.sol:112`, a public immutable) on
the `createLaunchMarket` path and `address(0)` on the two owner paths, and change the guard to
`if (floor != 0 && !_floorSet && msg.sender == floorSetter)`. The sole-staker test then becomes
redundant and can go, and the floor is unforgeable by construction rather than by a structural
argument that holds on only one of the three market-creation paths. Block-number or timestamp
gating does **not** work here and should not be reached for: `createMarket` is permissionless,
so an attacker can create the market and stake-and-renounce in the same transaction.

**Why it was deferred.** It changes the parameters `MarketDeployer.deploy` takes (`:1128`), and
`MarketDeployer` is a **linked library** — so the fix adds a relink and a redeploy to a rollout
that already moves seven contracts. What it leaves behind is a temporary admission floor of at
most 1 bp of liquidity an attacker had to assemble and pay a redemption fee on, on one market,
clearable by one `setMinStakeWeight` call. The runbook's alert table now carries
`MinStakeWeightRaised` on a market that never graduated, so an operator sees it happen.

### The issuer may withdraw consent at any time

`setFactory(0)` stops new markets being registered and stops `retireMarket` deregistering one.
It does **not** confiscate: `floatOf`, `totalFloat`, `marketReserve` and the index are all
untouched, and `claimFloatShare` is not gated on `factory` at all, so a registered market keeps
earning and keeps claiming. Revocation is also reversible — `namedFactory` is the way home.
What an issuer can do unilaterally is deny a *pending* graduation its float share until
somebody calls `retryLaunchFloat`; graduation itself proceeds regardless.

## Why there is no `LaunchDeployer` step

Kept as a record rather than deleted, because the step comes back if the concentrated-liquidity
stack lands.

**The blocker was never this change.** `LaunchDeployer` embeds `LaunchCurve`'s creation code,
so a deployer is frozen to the curve it was compiled against. The concentrated stack gives
`LaunchCurve` a **segmented** `initialize(address,(uint16,uint32)[])` — selector `0x6508e7ac` —
which the live deployer `0x7979708A371E9f9dDb43A432595c3F59f77dd5E7` has no idea about, so a
`LaunchFactory` built from *that* tree dies in the curve's dispatcher with no revert data on the
first `launchToken` after the upgrade, and on every one after that. An earlier revision of this
document carried the rotation in the redeploy list for exactly that reason, which is why it said
eight contracts and three redeploys.

**This branch does not carry that stack.** `LaunchCurve` declares one `initialize`, the
one-argument form (`LaunchCurve.sol:212`), and `LaunchFactory` calls exactly that
(`LaunchFactory.sol:930`) — selector `0xc4d66de8`, which is what the live deployer already
embeds. So the rollout is seven contracts, five upgrades and two redeploys, and the launch
deployer is not touched.

**Pinned as a live assertion, not a belief.**
`test_live_theLiveLaunchDeployerStillServesAFactoryFromThisTree`
(`test/LiveGen5Mainnet.t.sol:1159-1177`) performs the whole rollout with the deployer rotation
switched off, launches a token through the deployed deployer against live mainnet state, and
asserts the whole 1e27 supply reaches the curve. This is a claim about a contract this repo does
not control, so it is measured every run.

**What brings the step back.** That test failing. If it does, the curve's entry point has moved
and the rollout regains one deploy and one owner call:

```
LaunchDeployer newDeployer = new LaunchDeployer(LAUNCH_FACTORY)   // constructor takes the factory
LaunchFactory.setLaunchDeployer(newDeployer)                       // onlyOwner; :608
```

`setLaunchDeployer` checks `deployer.factory() == address(this)` and refuses anything else.
Rotation governs only launches created after it: a curve and its token are CREATE2-deployed by
whichever deployer was set at the time and are immutable afterwards, so the nine live launches do
not move. Their `predictLaunchAddresses` answers do change for *future* salts, which matters only
to an address predicted before the rotation and launched after it.
