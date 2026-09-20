# Security review, 2026-09-10 (historical)

> **STATUS: POINT-IN-TIME RECORD. Read this box before anything below it.**
>
> - **Review date: 2026-09-10.** Every finding body in this file describes source as it read on
>   that day. Most of that source no longer exists.
> - **Last re-checked against `src/`: 2026-09-20.** The verdict table immediately below is the
>   re-check. The finding bodies were deliberately NOT rewritten, so they contain numbers and
>   addresses that were true on 2026-09-10 and are not true now.
> - **Resolved since this review was written:** SR-02, SR-03, SR-05, SR-06, SR-07 and SR-08 are
>   all closed, either by a fix or by deletion of the contract. **SR-01 and SR-04 are the only
>   two still open**, and SR-04 is carried as AM-08 in `docs/audit-history.md`.
> - **Four things changed in September 2026 that contradict the finding text below.** Every one
>   of them is stated correctly in `docs/audit-history.md` and in `docs/0x/`; none of them is
>   corrected inline here, because the finding text is the historical artefact:
>   1. **The protocol fee moved from `beforeSwap` to `afterSwap`** on 2026-09-19 and is now
>      taken on the swap's UNSPECIFIED leg, which on an exact-input swap is the OUTPUT token.
>      SR-03's body says "5% of every swap's input". The input-side skim no longer exists;
>      `beforeSwap` returns `ZERO_DELTA` and only writes an oracle observation.
>   2. **`MAX_FEE_PIPS` is 10,000 pips = 1.00%**, not the 50,000 = 5% SR-03's body quotes.
>   3. **Custody is a Gnosis Safe**, `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, v1.4.1,
>      2-of-3. The deployer EOA `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` named in SR-03's
>      body is no longer owner, guardian or treasury of anything. There is still **no upgrade
>      timelock**: the Safe can upgrade any proxy in a single transaction.
>   4. **Fee increases are announced an hour ahead.** Both `ProtocolFeeHook` and
>      `SharedReservePool` carry `FEE_INCREASE_DELAY = 3600`; decreases are immediate and cancel
>      a pending increase. This is a quote-reliability guarantee, not a governance limit, for
>      the reason in (3).
> - **`web-stable/` paths below do not resolve here.** This repository is contracts and tests
>   only. Where a finding cites a frontend file it is describing the application repository,
>   which is not part of this handoff; nothing in a review of this repository depends on it.
>
> Anything in this file that disagrees with `docs/audit-history.md` is wrong and that file wins.

**Historical internal review of an architecture that has since been replaced twice.** It is
kept because its findings are part of the audit trail and because it is the only document that
carries the SR-numbered series: `docs/audit-history.md` consolidates the four earlier passes
(the AM, A1, A2 and A3 series) and does not carry SR-01 to SR-08. **`docs/audit-history.md`
holds the current verdicts for everything else, and it is where an auditor should start.**

Every SR finding below was re-checked against current `src/` on 2026-09-20. The table is that
re-check; the finding text itself is left as written on 2026-09-10 and describes source that in
most cases no longer exists. Nothing was dropped.

| ID | 2026-09-20 verdict | Why |
| --- | --- | --- |
| SR-01 | **Obsolete in source, unresolved on chain** | `StablecoinLauncher` and `BrandedVault` are deleted from `src/`. The deployed launcher is still live on 4663 and no manifest under `deployments/` records it. See the note under SR-01. |
| SR-02 | **Obsolete** | `BuybackEngine` is deleted; `grep -rn BuybackEngine src/` is empty. There is no buyback to grief. |
| SR-03 | **Fixed, and the ceiling has since been lowered** | `grep -rn defaultFeePips src/` is empty. `ProtocolFeeHook.feePipsFor` returns the pool's own stored rate, and zero for an unregistered pool (`src/markets/ProtocolFeeHook.sol:535-536`). Two things the finding body below gets wrong about today: `MAX_FEE_PIPS` is 10,000 pips = 1.00% (`:140`), not 50,000; and an increase now has to be announced `FEE_INCREASE_DELAY` = 3,600 seconds ahead (`:153`, `:407`, `:441`) while a decrease is immediate. `docs/audit-history.md` carries this under "Resolved by the September 2026 changes". |
| SR-04 | **Open, and carried elsewhere** | SR-04 is AM-08 restated. `docs/audit-history.md` carries AM-08 as open with the current citation; read it there. Re-checked here on 2026-09-20: `grep -rn accrueInterest src/` is still empty and `MorphoBlueYieldSource.balanceOf` still values shares off `morphoBlue.market(marketId)`'s stored totals (`src/yield/MorphoBlueYieldSource.sol:208-213`). |
| SR-05 | **Fixed, and the three-argument form is now strict too** | `SharedReservePool.redeem` has the four-argument overload (`src/pool/SharedReservePool.sol:527`) and `_redeem` reverts `InsufficientPayout` (`:555`). The three-argument overload (`:503`) no longer absorbs a silent haircut either: it derives its own floor as par less the live `redemptionFeeBps` (`:510`), which is exactly what `previewRedeem` (`:863`) quotes, and reverts rather than under-paying. Integrators should still prefer the four-argument overload, because it lets the caller choose the bound instead of inheriting the fee that happened to be live at settlement. |
| SR-06 | **Obsolete** | `grep -rn MAX_BUYBACK_DEVIATION_BPS src/` is empty. The buyback and its price band went with the engine. |
| SR-07 | **Fixed** | `MarketRouter.seedLiquidity` (`src/markets/MarketRouter.sol:507`) mints the LP NFT to `msg.sender` through `_mintPosition` (`:540`, `:670`), and the remainder goes home in the token it arrived as rather than being redeemed (`:551`, `_refund` at `:777-782`). That also closes the second half of the finding, where the UI promised a brandUSD refund the contract did not deliver. |
| SR-08 | **Obsolete** | `BrandedVaultFactory` is deleted. |

The "Re-checked and unchanged" section at the end of this file is historical in the same way.
`MinimalSwapRouter`, `AssetLockbox`, `VaultTreasury` and `Memecoin` are all deleted from `src/`,
so those observations describe nothing that ships. The `MinimalSwapRouter` one is worth calling
out because it was that section's only live complaint: it reported a test double sitting in
production source, and the contract is now gone.

---

Scope, as written on 2026-09-10: every contract under `src/`, read in full, with emphasis on the
code written since the 2026-09-08 review: the Uniswap v4 market stack (`AssetMarketFactory`,
`ProtocolFeeHook`, `PoolObservations`, `BuybackEngine`, `BrandFeeVault`, `AssetLockbox`,
`MarketDeployer`, `MarketRouter`), which no earlier review covered because it did not exist. The
launcher/vault/memecoin stack was re-checked rather than re-derived.

A bounded engineering review, not an audit certification. Findings describe the source as read
on 2026-09-10.

The working tree did not compile at the time: `src/markets/MarketRouter.sol` was mid-migration to
Uniswap's canonical v4 `PositionManager` and was being written to by a concurrent session. The
PoC below was run from a `git archive` of that day's `HEAD` in a scratch directory.

## Findings, as written on 2026-09-10

The Status column is the 2026-09-10 status. For the current one, read the table above.

| ID | Severity | Finding | Status on 2026-09-10 |
| --- | --- | --- | --- |
| SR-01 | **Critical** | Anyone can reprice a launched stablecoin's whole sell wall and take the vault's backing | Confirmed by passing mainnet-fork PoC. **Live contract still affected; source now deleted from the tree, which fixes nothing on chain** |
| SR-02 | High | A market's buyback can never execute once its pool is busy, and is cheap to grief | **Fixed in source** (throttled oracle writes + window-derived buffer), regression added |
| SR-03 | Medium | A market's trading skim is not immutable, contrary to its documentation | **Fixed in source** (hook-wide default removed), regression added |
| SR-04 | Medium | AM-08 (Morpho stale valuation) is still unfixed | Open, deliberately deferred. Carried forward from 2026-09-08 |
| SR-05 | Medium | `SharedReservePool.redeem` pays a silent, unbounded haircut | **Fixed in source** (`minAssetsOut` overload), regression added |
| SR-06 | Low | Buyback rounds have no minimum output; MEV is bounded only by the price band | **Addressed by tightening the band ceiling.** A minimum-out was investigated and is redundant — see below |
| SR-07 | Low | `MarketRouter` liquidity and the LP fees it earns are permanently unrecoverable | **Resolved elsewhere** by the migration to Uniswap's v4 `PositionManager`; seeders now hold their own NFTs. UI copy corrected |
| SR-08 | Low | `BrandedVaultFactory.setVaultPool`'s first write is open to anyone | Moot: the contract was deleted with the legacy product lines |

## Fixes applied 2026-09-10

`forge test --offline --no-match-path 'test/*Fork*'` → **192 passed, 0 failed, 2 skipped**.

- **SR-03.** `ProtocolFeeHook.defaultFeePips`, `setDefaultFeePips` and `DefaultFeeUpdated` are
  gone, along with the constructor's third argument; `feePipsFor` returns the pool's own stored
  rate. Both deploy scripts follow (the hook's mined address changes with its initcode). The test
  that asserted the fallback is replaced by its inverse:
  `test_aZeroPoolRateIsZeroAndStaysThere` and `test_onePoolsRateDoesNotFollowAnother`.
- **SR-02.** Two halves. `PoolObservations.write` now throttles to one entry per
  `MIN_INTERVAL` (15s) so a ring's reach stops depending on how often the pool trades, and
  `AssetMarketFactory.cardinalityForWindow` derives a market's buffer from its own `twapWindow`
  rather than a flat 32, sized for `window + MIN_INTERVAL` because the consumer reads the window
  lagged by one interval. `MAX_OBSERVATION_CARDINALITY` 1,000 → 4,000, and a window no buffer
  could serve is refused at `setBuybackParams` with `BuybackWindowTooLong`. Regression:
  `test_createMarket_sizesTheBufferForItsOwnTwapWindow`.

  The throttle has a cost that must not be lost: `observeSingle` extends the newest stored
  observation to the requested instant at the **live** tick, so a window ending at `now` credits
  up to `MIN_INTERVAL` seconds to the current price. `BuybackEngine.twapSqrtPriceX96` must read
  `[window + MIN_INTERVAL, MIN_INTERVAL]` so both endpoints land on stored observations. **That
  lagged read is owned by the concurrent v4 session and is not in this change.** Until it lands,
  a spike held at the moment of the read leaks about `MIN_INTERVAL / window` of the spot move,
  ~0.83% at a 1,800-second window.

  What the lagged read leaves behind is narrower than it first looks, and the mechanism is worth
  stating exactly because a first reading of it overstates the risk. The live tick enters only
  when the requested target is strictly newer than the newest stored observation, so the
  extrapolated stretch is `max(0, now - newest - MIN_INTERVAL)`. A swap zeroes it: any swap writes
  an observation *before* moving the price, at the then-true tick, and on a quiet pool
  `MIN_INTERVAL` has certainly elapsed so that write always happens. An attacker's own spike is
  therefore recorded honestly and contributes nothing at the instant it lands, however quiet the
  pool was beforehand. Exposure begins only once the manipulated price has been held for more
  than `MIN_INTERVAL` with no intervening trade, and grows with how much longer it is held —
  which is a TWAP charging for real inventory risk, i.e. working. The residual asymmetry still
  favours thin markets, because holding a price is cheapest where there is least liquidity to
  hold it against. The concurrent session is measuring the boundary orderings empirically rather
  than by analysis; that number belongs in `BuybackEngine`'s NatSpec, not here.
- **SR-05.** `SharedReservePool.redeem` gains a four-argument overload taking `minAssetsOut`,
  reverting `InsufficientPayout` before anything moves. The three-argument form is unchanged and
  still absorbs a haircut, which is what `MarketRouter._refund` wants. Regression:
  `test_redeemHonoursAMinimumPayout`, which shows the bare overload burning brand for a zero
  payout and returning normally.

  **2026-09-20: both halves of that last sentence have since changed.** The three-argument
  `redeem` is now strict — it derives its own floor from par less the live `redemptionFeeBps`,
  the same number `previewRedeem` quotes, and reverts rather than under-paying
  (`src/pool/SharedReservePool.sol:508-510`). And `MarketRouter._refund` no longer redeems at
  all; it returns each side in the token it is holding (`src/markets/MarketRouter.sol:777-782`,
  with the reasoning at `:768-776`), which is A3-L-3 in `docs/audit-history.md`. So the
  three-argument overload's silence was removed rather than preserved, and the caller that
  wanted the silence no longer exists. Integrators should still use the four-argument overload,
  because it bounds the payout at a number the caller chose rather than at whatever fee is live
  when the transaction lands.
- **SR-06.** `MAX_BUYBACK_DEVIATION_BPS` 2,000 → 500. **No minimum-output check was added, and
  that is deliberate.** An exact-input swap under a `sqrtPriceLimitX96` placed a band from the
  TWAP can only execute between the pool's starting price and that limit, so output per unit of
  input is already bounded below by the band. A floor derived from the same TWAP and the same
  band is therefore redundant with the limit that enforces it, and could only ever bind on fee
  drag — which is not the threat. The band *is* the loss bound, so the band is what was tightened.
- **SR-07.** UI copy in `web-stable/src/features/asset-markets/liquidity.tsx` corrected: it
  promised the stable remainder comes back as the brand token, and `_refund` redeems it through
  the reserve and returns USDG.

Not fixed: **SR-01**, whose contract left the tree (see below), and **SR-04**, deferred on
purpose (see below).

### SR-01's source was deleted, which changes nothing on chain

`src/integrations/StablecoinLauncher.sol` was removed during this review by a third session
retiring the vault, memecoin and sell-wall product lines, tagged `legacy-product-lines`. The
deployed contract at `0xecF46dC819Ef7523b842852B1026a5622889FB11` is untouched by that, still
owns sell-wall tokenId `1088997`, and still holds the exploit. `test/audit/SweepRepriceFork.t.sol`
went with the sweep; it is preserved outside the repo and reproduced verbatim above.

If sphUSDG is genuinely retired, the action is to ensure nobody ever buys through that pool and
to record the launcher as dangerous rather than merely superseded. If it is not, the clamp
described above has to land in a redeployed launcher, which means restoring the file.

**2026-09-19.** Still the position. `StablecoinLauncher` and `BrandedVault` are absent from
`src/`, and no manifest under `deployments/` names the deployed launcher, so nothing in the
repository currently records it as dangerous. That is the open action: the finding survives
deletion of its source, and deleting the source is what removed it from every generated
inventory. `deployments/README.md` explains which file is the address book and which is
generated; neither carries this contract, because it belongs to a product line that predates
both.

Investigated and **refuted**: a first hypothesis that `sweep` could place the wall *below*
par was wrong, and the PoC proved it wrong before it was reported. `_nextRange` snaps to the
live tick, and the live tick cannot leave the wall's own range while the wall still holds
both tokens. SR-01 is the corrected version: the attacker supplies the missing inventory
from the vault's own mint function, which is what makes the price free to leave the range.

---

### SR-01 — Critical: anyone can reprice the sell wall and take the vault's backing

**Obsolete in source as at 2026-09-19: `StablecoinLauncher` and `BrandedVault` are deleted
from `src/`.** The deployed contracts are untouched by that; see the note above.

`StablecoinLauncher.sweep` is permissionless by design — it "can only move USDG into the
vault and re-arm the wall, never extract". Re-arming calls `_nextRange`, which reads the
pool's **live tick** and places the new wall against it. There is no liquidity anywhere past
the wall's far tick, because the launcher's single-sided position is the only liquidity the
pool has ever had. So the live tick is free, in both directions, the moment the position is
single-sided again.

Making it single-sided again is normally impossible: the price can only leave the wall's
range if every token sold out of it comes back. `BrandedVault` supplies exactly that.
It is an open ERC-4626 — anyone may `deposit` USDG and receive branded shares at NAV —
so the attacker mints the inventory rather than buying it from holders.

One transaction, no privileged access, no flash loan needed beyond recoverable working capital:

1. Deposit USDG into the vault, receive branded shares at NAV (~1.0).
2. Sell those shares into the pool. The wall's own liquidity is consumed on the way, handing
   back the USDG honest buyers paid in, and past its far tick the price runs to any limit
   for nothing. A factor of 2^20 on the price is ~138,000 ticks.
3. Call `sweep`. It banks the collected fee dust as backing (enough to clear the
   `usdgSwept == 0` guard) and re-lists the **entire** remaining supply around the tick the
   attacker just chose.
4. Buy the whole re-listed supply for dust.
5. Redeem. The attacker now holds essentially all circulating supply, so redemption pays
   them essentially all of the vault's assets.

`test/audit/SweepRepriceFork.t.sol` runs this against real deployed Uniswap V3 on Robinhood
Chain mainnet:

```sh
forge test --match-contract SweepRepriceFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number 58898477
```

Result — **1 passed**:

| Quantity | Value |
| --- | --- |
| Attacker starting USDG | 500,000.000000 |
| Attacker ending USDG | 699,036.609820 |
| Attacker net profit | **+199,036.609820** |
| Honest buyer's deposit | 200,000.000000 |
| Honest buyer's redeemable value after | **0** |
| Wall range before / after | `[-200, 0]` → `[138436, 138636]` |
| Supply re-listed | 1,000,000,019,999,959 (the full 1B seed) |
| Cost to buy all of it | 2,000.000000 |

The profit is the honest buyer's deposit, near-exactly. These are deterministic fork values,
not a broadcast transaction.

**The live contract has this code.** `src/integrations/StablecoinLauncher.sol` has exactly
one commit (`eb5dddc`, 2026-09-07) and `_nextRange` has never been changed; the mainnet
deploy followed on 2026-09-08. Read back off chain 4663:

| | |
| --- | --- |
| `StablecoinLauncher` | `0xecF46dC819Ef7523b842852B1026a5622889FB11` |
| `BrandedVault` sphUSDG | `0x6040E2672Ca869dd0b74362A8D164B2F47705B0C` |
| Sell wall | tokenId `1088997`, ticks `[-200, 0]`, liquidity `1.005e17` |
| `totalAssets()` / `circulatingSupply()` | `0` / `0` |

Nothing is stealable today: the vault holds nothing and nobody has bought, so
`sweep` still reverts `NothingToSweep` for want of fee dust. **The exploit arms with the
first purchase**, and from then on the maximum loss is every unswept and swept dollar of
backing the vault holds.

Fixes, in order of how much they buy:

1. **Clamp the wall to par in `_nextRange`.** The product invariant is already written down —
   "a single-sided sell wall priced at or above par" — and it is simply not enforced on
   re-arm. `tickLower >= 0` for a token0 brand, `tickUpper <= 0` for a token1 brand. This
   alone removes the entire value of the attack: every step still runs, and the supply is
   re-listed at par, where buying it is not profitable.
2. Give the tear-down real execution bounds. `decreaseLiquidity` and the re-mint both pass
   `amount0Min: 0, amount1Min: 0` and `deadline: block.timestamp`, which is the same class
   of gap AM-05 raised about `seedLiquidity`.
3. Consider gating `sweep` to `SweepKeeper` and keeping the permissionless path behind a
   TWAP sanity check. Weaker than (1) on its own — a keeper still sweeps into a manipulated
   tick — so treat it as defence in depth, not the fix.

### SR-02 — High: the buyback cannot execute on a busy market, and is cheap to grief

**Obsolete as at 2026-09-19: `BuybackEngine` is deleted from `src/`, so there is nothing to
grief.** The observation throttle and the window-derived oracle buffer this finding produced
are still in the code and still serve the application's price history.

`BuybackEngine.execute` prices every round against the pool's TWAP, read from
`ProtocolFeeHook`'s observation ring. Three numbers do not fit together:

| Quantity | Value | Where |
| --- | --- | --- |
| Chain block time | ~0.101 s (measured over blocks 58,897,477–58,898,477) | Robinhood Chain mainnet |
| Observations retained at a market's creation minimum | 32 | `AssetMarketFactory.MIN_OBSERVATION_CARDINALITY` |
| Most the factory can provision | 1,000 | `AssetMarketFactory.MAX_OBSERVATION_CARDINALITY` |
| TWAP window stamped into every market | 1,800 s | `DeployAssetMarkets.s.sol` `TWAP_WINDOW`, immutable in the engine |

`PoolObservations.write` skips when the last observation carries the current
`block.timestamp`, and timestamps are whole seconds — so a ring holds at most one entry per
wall-clock second regardless of how fast blocks arrive. Thirty-two entries are therefore at
most 32 seconds of history. `consultTick(1800)` reverts `TargetPredatesOldestObservation`,
`execute` reverts, and `canExecute` reports `"no-twap"` — forever, for as long as the pool
keeps trading about once a second. A 1,800-second window needs 1,801 slots and the factory
cannot ask for more than 1,000.

Two consequences:

- **No attacker required.** An actively traded market — a memecoin venue, which is the case
  the product is aimed at — silently never buys back. The mechanism the whole design rests
  on fails closed and reports a string.
- **Griefing is cheap.** One dust swap per second pins the ring's oldest entry inside the
  window on any market. Sustained cost, but trivial on a 0.1-second chain.

`ProtocolFeeHook.increaseObservationCardinalityNext` is permissionless and not bound by the
factory's cap, and the chain's block gas limit is effectively unbounded (2^50), so the buffer
*can* be grown out of band. That is an operational workaround for a default that cannot work.

Fix: derive the minimum from the window rather than pinning a constant — grow to at least
`twapWindow + 1` at creation — and raise or drop `MAX_OBSERVATION_CARDINALITY` so the
factory can satisfy the window it is stamping in. The v4 stack is not deployed anywhere
(`deployments/asset-markets-mainnet.json` is marked stale, `markets: []`), so this costs
nothing to change now.

### SR-03 — Medium: a market's trading skim is not immutable

`ProtocolFeeHook.feePipsFor` reads a per-pool zero as "inherit":

```solidity
uint24 own = feePipsOf[id];
return own == 0 ? defaultFeePips : own;
```

Both `DEFAULT_PROTOCOL_FEE_PIPS` and `DEFAULT_PROTOCOL_BPS` are zero, and
`DeployAssetMarkets.s.sol` only calls `setProtocolFeePips` when non-zero — so every market
created is registered with `feePips = 0` and thereafter tracks a mutable global. One
`setDefaultFeePips` by the hook's owner raises the skim on **every existing market at once**,
up to `MAX_FEE_PIPS` = 50,000 pips = 5% of every swap's input. The owner is the deployer EOA
`0xeA6A…12A9`; the hook is not behind the timelock.

`AssetMarketFactory.protocolFeePips` documents the opposite ("Changing it moves future
markets only… The hook's owner can move a live market's rate afterwards, within the hook's
own ceiling"), and there is no way to express "pin this pool at exactly zero" at all.

Fix: store `feePips + 1`, or carry a separate `feeSetOf[id]` flag, so zero is a value rather
than a sentinel.

### SR-04 — Medium: AM-08 remains open

`grep -rn accrueInterest src/` returns nothing. `MorphoBlueYieldSource.balanceOf` still
converts consumer shares with `morphoBlue.market(marketId)`'s stored totals, so the
misattribution characterised at fork block 58,080,481 by the 2026-09-08 pass (now consolidated
into `docs/audit-history.md` as AM-08)
stands unchanged: a brand that mints just before someone accrues Morpho's interest collects
history it did not earn. That review recorded it as a mainnet-release blocker. It still is.

### SR-05 — Medium: `SharedReservePool.redeem` pays a silent haircut

```solidity
_recallIfNeeded(amount);
uint256 payout = _cappedByIdle(amount);
uint256 haircut = amount - payout;
```

The brand tokens are burned first, there is no `minAssetsOut`, and nothing reverts when
`payout < amount`. The adapter cooperates in the silence: `MorphoBlueYieldSource.withdraw`
returns `0` rather than reverting when the caller has no shares or when the requested amount
rounds to zero shares. A redeemer can therefore burn a full balance and receive less, with
no bound and no signal. `lossCarryforward` books the shortfall, which is correct accounting
and no comfort to the redeemer.

Fix: take a `minAssetsOut` on `redeem` (and on `claimYield`'s caller path), and revert rather
than truncate.

### SR-06 — Low: buyback rounds have no minimum output

**Obsolete as at 2026-09-19: the buyback is deleted from `src/`, so there are no rounds.**

`execute` deliberately passes no `amountOutMinimum` — the comment explains that a minimum
would turn the partial fill the price limit exists to produce into a revert. The remaining
bound is `sqrtPriceLimitX96`, which bounds where the swap may **end**, not the average price
it pays. A sandwicher pushes the pool to just inside the band, the round buys at that price,
and they exit into it. The deployed band is 200 bps on the square root (~4% on price), which
is tolerable; `MAX_BUYBACK_DEVIATION_BPS` would allow 2,000 bps (~40%), which is not.

Fix: derive a minimum output from the TWAP and the amount actually spent (checkable after the
swap, so it does not conflict with partial fills), and lower `MAX_BUYBACK_DEVIATION_BPS`.

### SR-07 — Low: router liquidity, and the fees it earns, cannot be recovered

**Fixed as at 2026-09-20.** Seeders hold their own position NFTs
(`src/markets/MarketRouter.sol:507`, minted through `_mintPosition` at `:540` and `:670`).

`MarketRouter.seedLiquidity` adds to one full-range position keyed to the router itself with
a shared salt, and there is no `modifyLiquidity` with a negative delta anywhere in `src/` —
no removal, and no fee collection either, so the LP fees that position earns accrue to it
permanently. The UI states the deposit is permanent, prominently and in its own words, so
this is a disclosed product decision rather than a surprise; the unclaimable **fees** are
worth stating too.

Two smaller notes on the same panel: it passes `0, 0` for `minBrandUsed`/`minAssetUsed`,
which is the exposure AM-05 was raised about; and its text promises the brand side is
refunded as brandUSD, while `_refund` redeems it through the reserve and returns USDG.

The router is being migrated to Uniswap's canonical v4 `PositionManager` as this is written,
which looks aimed squarely at this finding.

### SR-08 — Low: `setVaultPool`'s first write is open

**Obsolete as at 2026-09-19: `BrandedVaultFactory` is deleted from `src/`.**

`BrandedVaultFactory.setVaultPool` gates overwrites behind `_checkOwner()` but leaves the
first registration open, so anyone can point the index at a pool of their choosing for a
vault that has none. The contract documents itself as a convenience index rather than a
source of truth, and no surface in `web-stable/` reads it. Worth keeping true.

## Re-checked and unchanged, as at 2026-09-10

**Historical.** Of the contracts named below, `VaultTreasury`, `Memecoin`, `BuybackEngine`,
`AssetLockbox` and `MinimalSwapRouter` have all since been deleted from `src/`, so those five
observations describe nothing that ships. They are kept because "we looked at this and it was
fine" is part of the trail.

- The three 2026-09-08 fixes are present: per-caller `sharesOf` in the Morpho adapters,
  deployer-gated one-shot `bindController` on the Aave adapter, `onlyAdmin` on
  `VaultTreasury.redeemAll`/`redeem`, `nonReentrant` on `Memecoin.buy`/`sell`.
- `PoolObservations` is a faithful port of Uniswap V3's `Oracle` library — `transform`,
  `write`, `grow`, `lte`, `binarySearch`, `getSurroundingObservations` and `observeSingle`
  all match, including the uninitialised-slot skip in the binary search.
- The v4 payment idioms are right in all three places that settle (`ProtocolFeeHook`,
  `BuybackEngine`, `MarketRouter`): `sync` → transfer → `settle`, deltas read from the swap's
  return value rather than the amount requested, and `unlockCallback` reachable only from the
  singleton.
- A pool squatter cannot register a market's pool with the hook: `registerPool` is
  registrar-only and one-shot. They can still pre-initialise the key of a brand that already
  exists, which makes a later `openMarket` revert `PoolPriceOutOfBand` — griefing with a
  workaround (another fee tier), already covered by `test/audit/AssetMarketAudit.t.sol`.
- `AssetLockbox` has no exit, as advertised. `MarketDeployer` is a library, so its `CREATE`s
  run in the factory's context and `BrandFeeVault.factory` means what it says.
- `MinimalSwapRouter` is a test double sitting in `src/`: `quote()` returns its input
  unchanged and `uniswapV3SwapCallback` always reverts, so it cannot trade a real V3 pool.
  Nothing in `web-stable/` resolves it.

Already recorded elsewhere and not re-litigated here: the zero timelock delay, the 90% Morpho
utilisation with no idle-buffer policy, and codehash matching not being issuer provenance
(AM-07). All three are carried with current verdicts in `docs/audit-history.md`; the timelock
one is wider now than it was, because gen-6 has no timelock at all.
