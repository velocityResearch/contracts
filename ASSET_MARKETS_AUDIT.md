# AssetMarkets — security audit, 2026-09-09

> Scope: `src/markets/*` (`AssetMarketFactory`, `MarketYieldSplitter`, `LpRewardEscrow`,
> `MarketRouter`, `IYieldDestination`) plus the `SharedReservePool` / `PoolBrandTreasury` /
> `PooledBrandToken` surface they depend on, and `script/DeployAssetMarkets.s.sol`.
> Reviewed against [ASSET_MARKETS.md](ASSET_MARKETS.md) and
> [ASSET_MARKETS_SPEC.md](ASSET_MARKETS_SPEC.md). Nothing was deployed at the time of review.
>
> **Two HIGH and two MEDIUM findings are fixed.** One MEDIUM and six LOW findings are recorded
> below and deliberately not fixed — each says why.
>
> ⚠️ **This document describes the contracts as they stood on 2026-09-09.** `MarketYieldSplitter`
> has since been rewritten: the operator-configurable `Destination[]` and its `setSplit` /
> `setOperator` are gone, and `LpRewardEscrow` with them. All of a market's yield less a fixed
> protocol fee now goes to an immutable `BuybackEngine`, which buys the market's asset and sends
> it to an `AssetLockbox`. **F-2, F-3 and F-4 were all consequences of having a configurable
> split; none is reachable in the current contracts.** The findings are kept as written, because
> the reasoning is what makes the current shape defensible. The buyback introduces surface this
> review never saw — a TWAP price guard, a live V3 swap and a permissionless `execute` — which
> has not been audited.
>
> **A second review, 2026-09-09, covers exactly that surface** — the buyback, the lockbox, the
> multi-leg splitter and the two-step brand registration that came after this document. Two HIGH,
> three MEDIUM and three LOW findings, all open, each with a proof-of-concept exploit. See
> [ASSET_MARKETS_AUDIT_MULTILEG.md](ASSET_MARKETS_AUDIT_MULTILEG.md).
>
> Regression tests: `test/audit/AssetMarketAudit.t.sol`. Every `test_fix_*` began as a passing
> exploit against the pre-fix contracts and is asserted here in inverted form, so a regression
> re-opens the hole and fails the suite. The tests for F-2, F-3 and F-4 now assert the structural
> property that retired them rather than the original fix.
>
> ```bash
> forge test --offline --match-contract AssetMarketAudit -vv
> ```

---

## 1. What was verified as sound

These are the load-bearing claims in the design. Each was checked rather than assumed.

**The `EXTCODEHASH` verification really is sufficient.** SPCX's runtime code was pulled from
mainnet: 283 bytes, containing `PUSH32 0x000…e10b6f6b275de231345c20d14ab812db62151b00` and **no**
ERC-1967 beacon-slot read (`a3f0ad74…3d50` is absent). The beacon address is an `immutable`
compiled into the runtime code, so equal codehash does imply the same beacon. Had this been the
OpenZeppelin 4.x storage-slot `BeaconProxy`, an impersonator could have deployed byte-identical
code pointing at their own beacon and been stamped `verified` — a critical break of the only
on-chain trust signal the system has. Reproduce:

```bash
curl -s -X POST https://rpc.mainnet.chain.robinhood.com -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa","latest"]}'
```

**Fail-soft works as documented.** `harvest` credits an internal ledger and calls no destination;
`push` delivers one recipient at a time. A paused asset, a blocklisted address or a reverting
sink cannot brick a harvest or another destination's payout.

**The LP floor is genuinely out of the operator's reach.** `lpEscrow` is deployed by the
splitter's own constructor and immutable in it; `setSplit` rejects both it and `protocolTreasury`
as operator-chosen destinations; `lpBps` can never go below `lpFloorBps`; flooring dust rounds
toward the escrow. (Its *custody* is a separate matter — see MEDIUM-3.)

**Router approval hygiene is correct.** A malicious asset's transfer hook fires during the V3
swap callback, while the router still holds a live `swapRouter` allowance. It cannot spend it:
both SwapRouter02 and the position manager pull from their own `msg.sender`, which during a
re-entrant call is the malicious token, not the router. Every router entry point is
`nonReentrant`, so re-entering the router itself is blocked too.

**`createMarket` makes no untrusted non-static external call.** The attacker-supplied asset is
reached only through `decimals()` inside a `view` function, which the compiler emits as
`STATICCALL`. Everything else it calls (the reserve pool, the treasury, the Uniswap factory) is
trusted.

**Ledger invariants hold.** `sum(owed) == totalOwed` and `totalOwed <= asset.balanceOf(splitter)`
on every path; `harvest` credits exactly the amount actually received, never the requested one,
so `SharedReservePool`'s idle-capping cannot desynchronise the ledger.

**The reserve is structurally isolated from the asset.** Redemption touches USDG only. A paused,
blocklisted or burnt equity cannot affect anyone's ability to redeem a brand stable, which is
rule 1 of ASSET_MARKETS.md §3.2 and it holds.

---

## 2. Fixed

### HIGH-1 — `createMarket` silently adopted a pre-initialised pool's price

`_ensurePool` only initialised a pool whose `slot0().sqrtPriceX96 == 0`. On a pool that was
already priced, **`assetPriceE18` was discarded with no revert, no event and no return value the
caller could check.**

The brand token is deployed by `SharedReservePool` with `CREATE`, so its address is a pure
function of that pool's public nonce. A mempool watcher computes it, creates the V3 pool for
`(predictedBrand, asset, fee)` and initialises it at any price they choose. The victim's
`createMarket` then succeeded at the attacker's price, and the operator seeded liquidity into it.

Same class as the pre-created-pool squat that `Memecoin._graduate` was hardened against in
`1cbf270` — there the squatter bricked graduation, here they would price it.

**Fix.** `CreateParams` gains `uint16 maxSqrtDeviationBps`. When the pool is already priced and
`assetPriceE18 != 0`, the live price must sit within that band of the requested one, or the call
reverts `PoolPriceOutOfBand(live, requested)`. **Zero is the default and demands an exact match**,
which in practice means "this call must be the one that prices the pool". `assetPriceE18 == 0`
remains the explicit opt-in for attaching a market to a pool that already exists. `MarketCreated`
now carries the `sqrtPriceX96` the market actually starts at.

The band is on the square-root price, so `d` bps of band is roughly `2d` bps of price. That is
deliberate: comparing in price space needs a `Q96` reduction that collapses to zero at the bottom
of Uniswap's range, which would silently accept wildly different prices there. The sqrt-space
comparison is exact across the whole range.

### HIGH-2 — `seedLiquidity` had no slippage protection at all

The router passed `amount0Min: 0, amount1Min: 0` and `deadline: block.timestamp` (a no-op) to the
position manager, and its signature gave the caller no way to bound anything.

This is the classic add-liquidity sandwich: move the pool, let the deposit land at the
manipulated ratio, move it back. Cheap in a Mode B pool, which is thin by construction and
full-range by design recommendation. The refund path limits the loss to impermanent loss on what
was actually deposited rather than the whole amount — a smaller number, not a safe one.

**Fix — landed independently on `main` in `cbc4495`, and went further than this finding asked.**
`seedLiquidity` takes `minBrandUsed`, `minAssetUsed` and a real `deadline`, mapped onto
`amount0Min`/`amount1Min` by token ordering and forwarded to the position manager. That work also
put a `deadline` on **every** router entry point, not just this one, closing the "no deadline on
the swap path" gap listed under *Reiterated from the spec* below. The parameter order on `main` is
`(…, tickUpper, recipient, minBrandUsed, minAssetUsed, deadline)`; coverage lives in
`test/audit/AssetMarketsSecurity.t.sol`, so this audit's own suite does not duplicate it.

**The frontend must set these.** Zero for both is an unbounded ratio, and this is exactly the
`amountOutMinimum` situation the spec already flags for swaps.

### MEDIUM-1 — `setSplit` retroactively repriced yield that had already accrued

Weights were applied at harvest time, not accrual time. An operator could advertise a generous LP
share, let float earn under it for months, then drop to the floor in the transaction before a
harvest and keep the difference. `harvest` being permissionless was no defence — the operator
simply ordered the two calls themselves. Measured on the pre-fix contracts: of $100,000 accrued
entirely under an advertised 80% LP share, LPs received $20,000 and the operator took $75,000.

**Fix.** `setSplit` calls `_harvest()` before installing new weights, so the backlog is credited
at the rates that were in force while it was being earned and the new weights bind only what comes
after. `setSplit` is now `nonReentrant`.

### MEDIUM-2 — `setOperator` transferred control but not the payout

The constructor seeds `_destinations[0].to` with the operator's address, and that entry is what
the split actually pays. `setOperator` updated only the `operator` field, so a sold or handed-over
market kept paying its previous owner indefinitely. The existing
`test_setOperator_transfersControl` asserted only the `operator` field, so the suite did not catch
it.

**Fix.** `setOperator` settles first (yield earned under the old operator is credited to *them*
and stays claimable through `push`), then repoints any destination holding the outgoing operator's
address at the new one, carrying the `isSink` flag across. It rejects `newOperator` if it is
already a destination — repointing would collapse two entries onto one address, and `isSink` is
keyed by address — and rejects `lpEscrow` and `protocolTreasury` for the same reason `setSplit`
does.

### MEDIUM-4 — no identity check on the Uniswap periphery

`ISwapRouter02` declares `factory()` with the comment *"so a deployment can identity-check the
router against the V3 factory rather than trust a config file"*, and the docs warn that the
canonical `SwapRouter` address holds an unrelated funds-forwarding contract on this chain. Nothing
called it. A wrong constant would have produced a router that `forceApprove`s a stranger on every
trade.

**Fix.** Moved into `MarketRouter`'s constructor rather than the deploy script, so it binds every
deployment: both `swapRouter.factory()` and `positionManager.factory()` must equal
`factory.uniFactory()`, or construction reverts `PeripheryFactoryMismatch`. `factory()` was added
to `INonfungiblePositionManager` and to both position-manager mocks.

---

## 3. Open — accepted, with rationale

### MEDIUM-3 — the LP floor is custodial, and the deploy script defaults it to a hot EOA

`LpRewardEscrow.distribute(to, amount)` is unconstrained: the distributor may send the whole
escrow anywhere. There is no on-chain rule about who the LPs are, and cannot be until the Phase 2
gauge. The spec calls this "the single largest trust concession in the design," which is fair.

What sharpens it is the default. `script/DeployAssetMarkets.s.sol` resolves both
`PROTOCOL_TREASURY` and `PROTOCOL_ADMIN` with `vm.envOr(..., deployer)`, and each escrow's
`distributor` defaults to `protocolAdmin`. Deployed as written with those variables unset, **one
hot deployer key custodies every market's LP floor**, with no timelock and no multisig.

**Not fixed** — changing deployment defaults was explicitly out of scope for this pass. Before
broadcast, set `PROTOCOL_ADMIN` and `PROTOCOL_TREASURY` explicitly and point them at the timelock
or a multisig. Consider making the script `require` them rather than defaulting.

The user-facing wording deserves a second look too: ASSET_MARKETS_SPEC.md §1.3 says a minimum
share "is locked away for LPs and the operator cannot reach it." The second clause is true. The
first reads stronger than "held by a protocol-appointed address pending a distribution mechanism
that does not exist yet."

### LOW-1 — harvest-spam rounds a small market's whole yield into the LP escrow

Every slice floors and the remainder goes to `lpEscrow`. A griefer who harvests at 1-wei
granularity therefore routes 100% of the yield there: at `claimed == 1`, every `mulDiv` floors to
zero and the entire wei becomes dust. Demonstrated in
`test_known_harvestSpamRoundsEverythingIntoTheLpEscrow` — 200 rounds, operator and protocol
receive nothing.

**Accepted.** It costs a transaction per wei, it can only ever favour the party the floor exists
to protect, and it stops mattering as soon as a market's per-block accrual exceeds
`BPS_DENOMINATOR / min(bps)` — a few hundred wei. A `MIN_HARVEST` threshold would close it if a
market ever runs thin enough for it to bite.

### LOW-2 — a protocol-parameter combination can brick market creation

`MarketYieldSplitter`'s constructor requires `initialLpBps + protocolBps < 10_000` strictly, while
the factory permits `lpFloorBps` up to `MAX_LP_FLOOR_BPS` (8000) and `protocolBps` up to
`MAX_PROTOCOL_BPS` (2000). Set both to their ceilings and `initialLpBps` must be simultaneously
`>= 8000` and `< 8000`: every `createMarket` reverts permanently. `setProtocolParams` does not
validate the sum.

**Accepted** — the owner is trusted, live markets are unaffected, and the condition is reversible
by another `setProtocolParams`. A `require(lpFloorBps + protocolBps < BPS_DENOMINATOR)` in both
the constructor and the setter would make it unreachable.

### LOW-3 — no rescue path for stranded funds

Three places where value can arrive and never leave:

- An operator naming the **splitter itself** as a destination: `push` zeroes `owed` and decrements
  `totalOwed`, but the transfer is a self-transfer, so the balance stays as permanently
  unallocated. Operator self-harm only.
- Donations to the **splitter** or the **router** — neither has a sweep.
- Anything reaching a **`PoolBrandTreasury`**: its admin is the splitter, permanently, and the
  splitter never calls `treasury.distribute`.

**Accepted** — none is reachable by an attacker against someone else's funds, and a rescue
function is itself a privilege worth not having in Phase 1. Worth a passthrough on the splitter
for `treasury.distribute` if a market ever receives an airdrop.

### LOW-4 — `marketsOfAsset` is unbounded and permissionlessly grown

`_marketsOfAsset[asset]` is appended to by anyone calling `createMarket`, and `marketsOfAsset()`
returns the whole array. Enough markets on one popular asset and the view exceeds an RPC's gas
cap. `marketsOfAssetLength` exists but there is no paginated getter.

**Accepted** — it costs the attacker a full market creation per entry, and only a view degrades.
Add `marketsOfAssetSlice(asset, offset, limit)` when the UI needs it.

### LOW-5 — no two-step ownership, no timelock on the factory

`AssetMarketFactory` uses plain `Ownable`, so a mistyped `transferOwnership` is unrecoverable, and
`setProtocolParams` takes effect immediately. Live markets hold their terms immutably in their own
splitter, so the blast radius is future markets only.

**Accepted for Phase 1.** `Ownable2Step` is a drop-in if the owner becomes anything other than the
deployer.

### LOW-6 — `verified` is a property of the asset, displayed on a market

`isCanonicalEquity` tests the asset's bytecode. The flag is then stored on the *market*. Anyone
can permissionlessly create ten markets on SPCX with misleading brand names and zero liquidity,
and every one of them is `verified: true`.

**Accepted** — this is inherent to permissionless listing and the spec says as much in §1.5. It is
a UI requirement rather than a contract one: the badge must read as *"the underlying asset is the
genuine Robinhood token"* and never as an endorsement of the market, its brand, its liquidity or
its operator.

### Reiterated from the spec, unchanged

**~~Swaps carry no deadline.~~ Closed.** Every router entry point now takes a `deadline` and
reverts `DeadlineExpired` past it, done as part of `cbc4495` rather than by this audit.

**One reserve, one adapter.** A bad yield adapter harms every brand at once. Unchanged by this
work, and gated by the Phase 0 blockers in ASSET_MARKETS.md §10 — which remain the real
prerequisite: `SharedReservePool` has never been broadcast, both live `MorphoBlueYieldSource`
instances have an unguarded `withdraw(asset, amount, to)`, and the timelock delay is zero.

---

## 4. Signature changes

Anything already written against these needs updating. Nothing is deployed, so no migration.

```solidity
// AssetMarketFactory.CreateParams — new field, between observationCardinality and lpBps
uint16 maxSqrtDeviationBps;

// AssetMarketFactory — new error
error PoolPriceOutOfBand(uint160 live, uint160 requested);

// AssetMarketFactory.MarketCreated — new trailing field
uint160 sqrtPriceX96;

// MarketRouter — slippage bounds and a deadline (landed on main as cbc4495)
function seedLiquidity(
    uint256 marketId, uint256 usdgIn, uint256 assetIn,
    int24 tickLower, int24 tickUpper, address recipient,
    uint256 minBrandUsed, uint256 minAssetUsed, uint256 deadline
) external returns (uint256 tokenId, uint128 liquidity);
// …and a `deadline` on buyWithUsdg / buyWithBrand / sellForUsdg too.

// MarketRouter — new error from this audit
error PeripheryFactoryMismatch(address periphery, address reported, address expected);

// INonfungiblePositionManager — new member
function factory() external view returns (address);
```

`MarketYieldSplitter.setSplit` and `setOperator` keep their signatures but now harvest first and
are `nonReentrant`; `setOperator` additionally reverts `DuplicateDestination` /
`ReservedDestination` on the cases described above.
