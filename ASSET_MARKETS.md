# AssetMarkets — yield-funded markets on assets that already exist

> **Status: Phase 1 built and tested on Uniswap v4; an earlier generation is deployed and now
> superseded.** The offline suite passes 196 tests. Two fork suites pass against live Robinhood
> Chain mainnet state — `test/markets/AssetMarketV4Fork.t.sol` (7) and
> `test/markets/MarketRouterV4Fork.t.sol` (5) — using the real deployed v4 singleton, real USDG
> and the real `SPCX` token. Phases 2–4 are still design.
>
> **The v4 migration is done.** `AssetMarketFactory`, `MarketRouter` and `BuybackEngine` all run
> on Uniswap v4; markets are created in the singleton the rest of the chain already uses, and
> `ProtocolFeeHook` takes the protocol's share of trading fees and doubles as the pools' oracle,
> because v4 core keeps no observations of its own (§6). The fork suites confirm no interface
> mismatch between our vendored `v4-core` and the deployed bytecode.
>
> Three things changed materially after the 2026-09-09 mainnet deployment, so the live stack at
> `deployments/asset-markets-mainnet.json` no longer matches this document: the pools moved from
> v3 to v4, the yield splitter was deleted in favour of one market per brand (§6, §9), and
> issuing a stablecoin and standing up its market became a single transaction (§6). That stack
> holds no markets and its reserve is empty, so the next deployment should replace it wholesale
> rather than patch it.
>
> This is a third product line layered on top of `SharedReservePool`, which is itself built and
> tested but not yet deployed (see [SHARED_RESERVE_POOL.md](SHARED_RESERVE_POOL.md)). Every chain
> figure below was read off Robinhood Chain mainnet (4663) on 2026-09-08 and is reproducible —
> see [§3](#3-what-the-chain-actually-looks-like).

---

## 1. The pivot

The launchpad model in this repo mints a *new* asset — `MemecoinFactory` deploys a bonding curve,
the curve graduates to a Uniswap pool. That competes head-on with every other launchpad, on the
one axis where incumbents are strongest: attention at the moment of launch.

AssetMarkets inverts it. Nobody mints anything. An **operator** takes an asset that already
exists on chain — a tokenized equity like `SPCX`, or a memecoin that graduated somewhere else —
attaches a branded stablecoin they control, and stands up a market for the pair. Users mint the
brand stable 1:1 against USDG and trade the asset against it. The USDG behind every outstanding
brand token earns Morpho yield, and **all of that yield, less a fixed protocol fee, buys the
market's own asset and locks it forever**. The operator is paid nothing. Both shares are fixed
in each market's own contracts at creation and cannot be changed afterwards by the operator, by
the protocol, or by anyone else.

The mechanism that makes this work is already in `SharedReservePool` and needs no change: a
brand's yield accrues on its **outstanding supply**, and outstanding supply counts tokens no
matter who holds them — including a Uniswap pool. So the AMM's stable-side reserves *are* the
float. Deeper market → more float → more yield → bigger buyback → deeper market.

The loop closes twice over, because the buyback buys *from the market's own pool*. The brandUSD
it spends stays in the pool as permanent quote-side depth, and therefore as permanent float. The
buyback grows the thing that funds it.

## 2. Why this is complementary to launchpads

The complementarity is structural, not a positioning claim:

- **No token is created.** No curve, no launch fee, no supply, no allocation. A launchpad's
  economics are entirely upstream of anything here.
- **This is the T+30 layer.** A graduated token's problem is not launch liquidity, it is that
  thirty days later there is no bid that isn't a holder. Float interest is a bid that is
  non-dilutive, doesn't sell treasury, and doesn't emit. Nothing a launchpad ships does this.
- **A referrer slice makes them a partner.** One of the yield destinations is a referrer address
  fixed at market creation. A launchpad that routes its graduated tokens here earns float yield
  on them in perpetuity, for no ongoing work. That is a revenue line they cannot build
  themselves without becoming a stablecoin issuer.
- **A launchpad can quote its graduation pool in a brand stable.** The factory does not care
  where an asset came from or who deployed it.

The corollary used to be that a bonding curve is the part of this repo that *does* compete, and
should be frozen rather than advanced. `MemecoinFactory` / `Memecoin` were deleted on that
reasoning in `b0e3018`.

**That is reversed.** A launchpad is being built again on branch `feature/launchpad`, forked
from Pons V2 rather than from the deleted curve, and it is not a second product line: a launch
*graduates into* an asset market. The curve is quoted in a brand stable, so the float it holds
while trading earns for that brand's treasury — the thing Pons's own USDG curves leave on the
table — and at the threshold `LaunchGraduation` calls
`AssetMarketFactory.createLaunchMarket`, so a graduated token arrives with the unit, the pool,
the hook skim, the LP yield stream and the locked seed position already wired. The competitive
claim is no longer "we do not compete at launch"; it is that everything above stays true of a
token that did not exist an hour ago. See [docs/LAUNCHPAD_PLAN.md](docs/LAUNCHPAD_PLAN.md).

## 3. What the chain actually looks like

Two measurements drove every design decision below. Both were taken against mainnet, not assumed.

### 3.1 The tokenized equities are real, deep at the top, and dead in the tail

`web/src/web3/generated/tokenized-stocks.ts` holds 194 bytecode-verified equities. Querying the
V3 factory at `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` for `<ticker>/USDG` pools across all
four enabled fee tiers, and summing the USDG balance of each pool that exists:

| | |
|---|---|
| Tickers scanned | 193 of 194 (`KSS` skipped — an apostrophe in `Kohl's` broke the parser, not the data) |
| Have at least one pool deployed | 165 |
| **Total USDG parked across all of them** | **$23,592,520** |
| Pools holding > $100k | 30 |
| $10k – $100k | 23 |
| $1k – $10k | 6 |
| **≤ $1k — effectively no market** | **134** |

Top of book: `NVDA` $4.18M, `SGOV` $2.57M, `GLD` $2.18M, `SPCX` $1.99M, `TSLA` $1.10M.

`SPCX` (`0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa`) is worth looking at closely, because it is
the asset that prompted this design. Its 0.05% pool holds ~$1.58M USDG against 3,065 SPCX at a
spot of ~$154, and its observation cardinality is **3,100** — somebody paid real gas to grow that
ring buffer, which only a professional market maker does.

**Conclusion: do not build a competing brandUSD pool for the top 30 names.** It would be thinner,
price worse, and lose every trader who compares. But 134 tickers have no market at all, and
neither does any memecoin. That is the open ground, and it is the same shape as the `$CASHCAT` /
`POSN` case.

Reproduce a single reading with `cast` unavailable (it panics on macOS proxy config in some
sandboxes) via a raw call — the SPCX 0.05% pool's USDG balance:

```bash
curl -s -X POST https://rpc.mainnet.chain.robinhood.com -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168","data":"0x70a08231000000000000000000000000c61284332117c3fb23a2a56cceffd07f7af60029"},"latest"]}'
```

### 3.2 The equities are issuer-controlled, and that is a hard constraint

Every genuine token is a beacon proxy delegating to `0xe10b6f6b275De231345c20d14aB812db62151b00`,
which currently resolves to implementation `0xb35490d6f9163de4f80d88dc75c3516eb64c5ae2`. That
implementation's runtime bytecode contains, among others:

| Selector | Function | What it means for us |
|---|---|---|
| `0x8456cb59` / `0x3f4ba83a` | `pause()` / `unpause()` | The issuer can freeze all transfers of the asset |
| `0xfbac3951` | `isBlocked(address)` | The issuer can blocklist a specific address — including ours |
| `0x9dc29fac` | `burn(address,uint256)` | The issuer can burn tokens out of any address |
| `0x91d14854` | `hasRole(bytes32,address)` | AccessControl gates the above |

`SPCX.paused()` returns `false` today. It will not necessarily always.

Three design rules fall out of this, and they are not negotiable:

1. **The reserve never touches the asset.** `SharedReservePool` backs brand tokens with USDG
   only. A paused, blocked or burnt equity must be unable to affect anyone's ability to redeem a
   brand stable for USDG. This is already true and must stay true — no design here may add the
   asset to the redemption path.
2. **The buyback fails soft.** If the asset is paused, or the splitter's address is blocked, the
   buyback leg must *skip and roll the funds forward*, never revert the whole harvest. A hard
   revert would let the issuer brick an operator's yield claim.
3. **LP inventory is freezable, and the UI must say so.** An LP in a Mode B market holds a V3
   position containing an issuer-controlled token. That risk belongs on the screen, not in a
   footnote.

## 4. Two market modes

| | **Mode A — routed** | **Mode B — native** |
|---|---|---|
| Applies to | The ~30 deep names | The 134 empty tickers, and every memecoin |
| New pool? | No | Yes — brandUSD/asset |
| Execution | brandUSD → redeem 1:1 → USDG → the existing deep pool → asset | brandUSD → the market's own pool → asset |
| Float source | Users' uninvested brand-stable balances | The pool's brandUSD reserves, plus idle balances |
| Analogy | Brokerage cash sweep | A venue that did not exist |
| Competes with the incumbent MM? | No | Nothing to compete with |

**Phase 1 ships Mode B.** It is the case the pivot was conceived for, and §3.1 says it is where
the unserved market actually is. Mode A is a strictly smaller amount of work layered on the same
registry later, and it is what lets a `SPCX` or `NVDA` market exist at all without picking a
fight it loses.

The router quotes both paths per trade regardless, so the mode is a bootstrapping decision, not a
user-facing one.

## 5. What already exists and needs no changes

`SharedReservePool` is the right primitive as written. Nothing in this design forks, upgrades or
modifies it:

- **`registerBrand(name, symbol, admin)` is permissionless and takes an arbitrary `admin`**, and
  `PoolBrandTreasury.claim(receiver)` is admin-gated with a free receiver. So the yield splitter
  can simply *be* the treasury admin. That is the whole integration — one address, set at
  registration.
- **Yield accrues per brand on `outstanding`**, which is maintained by mint/redeem/swap and is
  indifferent to who holds the tokens. A brandUSD balance sitting in a Uniswap pool earns for the
  brand exactly like one in a wallet. This is the flywheel, and it already works.
- **`swap()` moves between brands at exactly 1:1 with no slippage and no approval.** N brand
  stables therefore do *not* fragment the quote layer the way USDC and USDT do — crossing between
  them is free. A user holding brand X can enter a market quoted in brand Y at no cost.
- **A brand stable is a costless wrapper of USDG**, mintable and redeemable 1:1 on demand. That
  is what makes Mode A's routing free, and what stops a Mode B pool from being a liquidity trap.

Also already present and reusable:

| Asset | Where | Reuse |
|---|---|---|
| Bytecode-verified equity registry | `web/src/web3/generated/tokenized-stocks.ts` | The listing allowlist and the on-chain verification rule |
| Quoter-less V3 quoting | `web/src/web3/quote-v3.ts` | Every price preview — the chain ships no `QuoterV2` |
| Keeper job/threshold/interval pattern | `src/keepers/SweepKeeper.sol` | Copy wholesale for buyback scheduling |
| V3 pool creation and single-sided seeding | `src/integrations/PoolDeployer.sol` | Generalize from vault-share/underlying to brand/any-asset |
| Per-consumer yield adapters | `src/yield/MorphoBlueYieldSource.sol` | Unchanged — one instance per consumer, as always |

## 6. New contracts

All of these sit strictly above the existing stack, and all of them are **built**:

| Contract | File | Status |
|---|---|---|
| `AssetMarketFactory` | `src/markets/AssetMarketFactory.sol` | Built |
| `BrandFeeVault` | `src/markets/BrandFeeVault.sol` | Built |
| `BuybackEngine` | `src/markets/BuybackEngine.sol` | Built |
| `AssetLockbox` | `src/markets/AssetLockbox.sol` | Built |
| `ProtocolFeeHook` | `src/markets/ProtocolFeeHook.sol` | Built |
| `MarketRouter` | `src/markets/MarketRouter.sol` | Built |
| `BuybackKeeper` | — | Optional; `execute` is permissionless without one |

`LpRewardEscrow` is gone. It held a protocol-enforced floor of the split for liquidity providers,
which only made sense while the split had parts. See §8 for what that costs and why it went.

`MarketYieldSplitter`, `SplitterDeployer` and `IYieldDestination` are also gone, and their
absence is the largest single simplification in this document's history — 695 lines deleted for
about 200 added. They existed to divide one brand's single yield stream across several Uniswap
pools, weighted by liquidity-seconds so that the division could not be spoofed by parking a
balance. That machinery was the cost of one feature: letting a single stablecoin be paired with
many assets. **A brand now gets exactly one market**, so there is nothing to divide, and the
whole apparatus — legs, accumulator snapshots, the carried remainder, the per-destination
ledger — collapses into a balance. An operator who wants a second pair registers a second brand,
which costs one transaction and leaves both markets' economics readable without reference to
each other. See `BrandFeeVault` below.

Deploy with `script/DeployAssetMarkets.s.sol`, which requires a deployed `SharedReservePool`
address in `SHARED_RESERVE_POOL` and refuses to guess at one.

### `AssetMarketFactory`

Registry and one-transaction creation. Holds `(asset, brandToken) → Market` plus reverse indexes
so the UI can list every market for an asset and every market for a brand.

Its notable job is **on-chain listing verification**. `scripts/discover-stocks.mjs` already
establishes the only test that distinguishes a genuine tokenized equity from an impersonator: the
proxy's runtime bytecode must be byte-identical to the Robinhood beacon proxy. That test is a
single `EXTCODEHASH` comparison plus a beacon read, so it belongs in Solidity rather than in a
build script. A market gets a `verified` flag from it; memecoins cannot be verified this way and
are marked `unverified`, with curation and deployer attestation handled above the contract.

Creation is permissionless. Nothing about an unverified market can affect a verified one, or any
other brand's yield — same rationale as `BrandedVaultFactory.createVault` and
`SharedReservePool.registerBrand`.

### `BrandFeeVault`

Set as the `admin` of the market's `PoolBrandTreasury`. Everything a market earns lands here, and
everything that lands here buys the market's asset and locks it.

**One income stream arrives here: float yield.** `harvest()` claims the brand's accrued USDG out
of the reserve. Trading fees do *not* come here — `ProtocolFeeHook` skims them off every swap's
input and `collect` pays them to the protocol treasury, which is the protocol's revenue and the
only thing the protocol takes. See [§7](#7-the-yield-split-is-decided) for the split, and
[§7a](#7a-the-trading-fee) for the fee.

**Three currencies can be sitting here, and each has one sensible fate.** USDG is the reserve
underlying. brandUSD is a 1:1 claim on that same reserve — the same value in a different
wrapper — and the engine already accepts both, since its budget is `brandUSD + USDG` and its
first act is to mint one into the other. The LP donation has to be brandUSD specifically,
because that is the currency the pool holds, so `sweep()` mints what it needs on the way
through. The market's own asset is the thing the buyback exists to acquire, so buying more of it
with itself would be a round trip that pays a spread for nothing; `forwardAsset()` locks it
directly instead, and takes no cut for anyone, because the protocol's and the LPs' shares are
denominated in the reserve asset and paying either in an arbitrary market token would hand them
a position they never asked for.

`protocolBps` and `lpBps` are fixed at construction and have no setters, and the engine is
written once by the factory during creation. What a market does with its income is a fact about its bytecode rather
than a setting its operator maintains — see [§7](#7-the-yield-split-is-decided).

`harvest()` and `sweep()` are both permissionless, for the same reason `StablecoinLauncher.sweep`
is: both destinations are fixed, so the caller chooses only the moment, and anyone should be able
to pay the gas to keep a market current. They are deliberately separate calls — harvesting is
cheap and idempotent, sweeping moves money. Neither triggers the engine: buying is rate-limited
and price-guarded on its own schedule, and coupling them would let anyone force a round by
donating dust.

### `ProtocolFeeHook`

A Uniswap v4 hook that takes the protocol's share of trading fees, and the reason the markets
move from v3 to v4 at all. One singleton per chain, shared by every market's pool.

**What "before the LPs" means in v4, precisely.** There is no mechanism in v4 for a hook to take
a cut of the LP fee: `key.fee` accrues entirely to in-range liquidity through `feeGrowthGlobal`
and has no splitter. What a hook *can* do is take its slice off the swap amount in `beforeSwap`,
so that slice never enters `pool.swap` at all and the LP fee is charged only on the remainder.
That is what every launchpad doing this is doing. From the trader's side it is an extra fee on
top of the LP fee; from the accounting's side it is strictly upstream of it. The distinction
matters because the first framing is achievable and the second is not.

**Both swap directions pay, and always on the input currency.** On an exact-input swap the
specified currency is the input, so `beforeSwap` takes it. On an exact-output swap the input is
the *unspecified* currency and its amount is not known until the swap has run, so `afterSwap`
takes it there. Charging only one would let anyone route around the fee by flipping the swap
type.

**Fees accrue as ERC-6909 claims rather than transfers.** `poolManager.mint` moves no tokens; it
credits the hook inside the PoolManager. That keeps the per-swap cost to a storage write, and
more importantly it works no matter how the calling router orders its settlement — a hook that
called `poolManager.take` mid-swap would require the PoolManager to already hold the trader's
input, which is only true for routers that prepay. `BrandedVaultPSMHook` has exactly that
constraint and needed a custom prepaying router to work around it; this one does not.

**Nothing a parameter change would touch is immutable, and that is deliberate.** A v4 hook's
permissions are encoded in the low 14 bits of its own address, so the address is mined against
its exact creation code *and constructor arguments*. Making the fee or the treasury an immutable
constructor argument would mean changing either produces a different address — and since
`PoolKey.hooks` is part of a pool's identity, every pool ever launched would be orphaned. So
they are storage behind an owner. A pool's fee *destination*, by contrast, is one-shot: letting
it be repointed would make "this market's trading fees buy this market's asset" a promise the
owner could revoke, which is the one property the lockbox exists to make unrevokable.

An unregistered pool is charged nothing. A stranger who points a `PoolKey` at this hook gets a
hook that does nothing, rather than one that quietly confiscates their traders' input into a
balance nobody can withdraw.

**The venue is Uniswap's own, not ours.** Uniswap v4 is deployed on Robinhood Chain at a
non-canonical address, exactly as v3 is, and at the *same* address on mainnet and testnet:
`0x8366a39CC670B4001A1121B8F6A443A643e40951`, with the real `PositionManager` at
`0x58DaEc3116aAe6D93017BaAEA7749052e8A04fa7` and canonical Permit2. It is busy — a 9,000-block
window exceeds the RPC's 10,000-log cap on `Swap` alone. Markets created here therefore sit in
the same singleton as every other v4 pool on the chain, and anything that already routes v4 here
can route to them.

This is worth recording because it was got wrong once, in a way that would have been expensive
and unrecoverable. Checking the canonical Ethereum and Base PoolManager addresses finds nothing
on this chain and looks like proof of absence; it is not. The reliable test is to search for
v4's own `Initialize` or `Swap` events and read the emitting address. Had the mistake survived,
the stack would have deployed its own singleton, and since a pool's `PoolKey` names a singleton,
every market ever created would have named the wrong one, invisible to every aggregator and
unmigratable afterwards.

**What the incumbents do differently.** The launchpad hook already operating here
(`0x4e3468951d49f2eea976ed0d6e75ffcb44a9a544`) carries flags `0x2544` — `beforeInitialize`,
`afterAddLiquidity`, `afterRemoveLiquidity`, `afterSwap`, `afterSwapReturnDelta` — and creates
its pools with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. So it takes its cut in `afterSwap`, on the
*unspecified* currency, which means the side of the trade it lands on depends on the swap type.
This hook takes the input side in both cases, which is why it carries `beforeSwap` as well.

### `BuybackEngine`

Takes the whole harvest less the protocol fee, mints brandUSD 1:1 through the reserve, swaps to
the asset, and sends it to that market's `AssetLockbox`. One per market, deployed alongside its
`BrandFeeVault`.

**Receiving and spending are separate transactions.** `onYieldReceived` only counts; everything
that can fail lives in `execute`, which anyone may call. Inventory is held as brandUSD rather
than USDG — minting is 1:1 and free, and brandUSD counts toward outstanding supply, so yield
waiting to be spent keeps earning yield.

- **Price guard.** No `QuoterV2` exists on this chain, so the guard is the pool's own TWAP via
  `observe()`, a max-deviation bound in bps, and a `sqrtPriceLimitX96` derived from it. The SPCX
  pool's cardinality of 3,100 shows the deep pools support this; a freshly created Mode B pool
  will need `increaseObservationCardinalityNext` called at creation, which the factory should do.
- **Fails soft.** Paused asset, blocked address, price outside the band → the round reverts on
  its own and the funds roll forward. The harvest is never touched. (See §3.2 rule 2.)
- **Partial fills are the intended outcome, not an error.** Uniswap fills only as far as the
  price limit and leaves the rest of the input with the caller. That remainder becomes the next
  round's budget, so a manipulated pool costs a partial fill rather than a bad price.
- **Thresholds.** Minimum notional and minimum interval, same shape as `SweepKeeper.Job`, and
  fixed per market: no setter anywhere widens the band or shortens the interval on a live
  market. They are written once at initialisation, so changing them takes a timelocked upgrade
  of the engine beacon rather than a transaction any owner can send.
- **A market cannot buy back until its pool has a full TWAP window of history.** The factory
  grows every new pool's observation buffer to at least `MIN_OBSERVATION_CARDINALITY`; time
  still has to pass. `canExecute()` reports this as `"no-twap"` rather than making a caller
  guess.
- **A useful property, in Mode B.** The buyback buys the asset *from the market's own pool*,
  which leaves the brandUSD inside that pool. The buyback capital therefore becomes permanent
  quote-side depth and permanent float, rather than leaving. The buyback grows the thing that
  funds it.
- **A matching hazard.** A predictable buyback is front-runnable, and in a thin pool the
  buyback's own price impact is the price. The threshold-plus-interval schedule, the TWAP band,
  and not publishing exact timing are the mitigations. A market whose only buyer is its own
  buyback is not a market, and the UI should not pretend otherwise.

### `MarketRouter`

The user-facing periphery, and what keeps brand stables from fragmenting liquidity. Buy and sell
with USDG *or any other brand stable*, doing mint / redeem / 1:1 brand-swap and the V3 hop
atomically:

```
buy:  USDG --mint 1:1--> brandUSD --V3--> asset
      brandY --swap 1:1--> brandUSD --V3--> asset
sell: asset --V3--> brandUSD --redeem 1:1--> USDG
```

Only the mint leg needs an approval of USDG. `redeem` and `swap` burn from the caller directly
and must not render an approve step — and `redeem` can return a wei less than requested, so the
router must propagate the returned amount rather than the requested one. Both are documented in
[SHARED_RESERVE_POOL.md §7](SHARED_RESERVE_POOL.md).

### `AssetLockbox`

Where a market's purchases end up. One per market, deployed by its engine. No owner, no admin,
no `withdraw`, no `rescue`: the only state-changing function is `lock`, which the engine alone
may call and which does nothing but move a counter.

**It is upgradeable, and that qualifies the promise.** Instances sit behind a beacon owned by
the protocol timelock, so a future implementation could add a withdrawal path and release
everything held here. What the lockbox guarantees is therefore not "nobody can ever move these
assets" but "nobody can move them without an upgrade proposed in public that waits out the
timelock first". Surfaces should say assets are **locked**, and that releasing them would take a
timelocked upgrade. They should not say "locked forever" — that is no longer true. The trade was
made deliberately: an immutable sink cannot be repaired, so a bug in it strands the assets with
exactly the same finality as the feature working.

It is **not** an ERC-20 burn, and no surface should call it one. `totalSupply` does not move and
an explorer keeps counting these tokens as outstanding. What it removes is the float,
permanently. A supply-reducing `burn()` was not available: Robinhood equities gate `burn` behind
the issuer's AccessControl and `Memecoin` has no burn function at all, so an address that
provably cannot spend is the only sink that works for every asset — including ones that do not
exist yet.

### `BuybackKeeper` *(optional)*

`execute()` is permissionless and cheap to call, so a market stays current as long as anyone is
willing to pay the gas. A keeper — `SweepKeeper` with the target changed — would make that
reliable rather than merely possible, and is worth building if markets go quiet.

## 7. Where a market's yield goes

**All of a market's float yield, less a protocol share shipped at zero, goes to the people who
provide the market's liquidity.** The operator is paid nothing. Both numbers are stamped into
the market's `BrandFeeVault` at initialisation and neither has a setter.

`harvest()` pulls the brand's accrued USDG out of its `PoolBrandTreasury`. `sweep()` then
divides what is held two ways: `protocolBps` to the protocol treasury, and every remaining wei —
the rounding dust included — to the market's `LpRewardDistributor`. The payout is denominated in
the brand unit, because that is what the distributor pays out and what the pool holds; USDG held
by the vault is minted into it 1:1 on the way through, and existing brand balance is spent first,
so a vault holding enough of it never touches the reserve at all.

**This replaced a three-way split whose third leg bought the market's asset and locked it
forever**, and the replacement is a product decision rather than a bug fix. The argument for the
buyback was that a standing, verifiable bid is the thing a long-tail asset lacks. The argument
against it, which won, is that a market needs depth before it needs a bid, and that paying for
depth directly beats paying for it through a price. The consequence belongs on every surface,
stated plainly: **nothing here buys the asset any more.**

**Why a distributor rather than `PoolManager.donate`.** Donation is the better mechanism while
the LP share is a *slice* of the yield. It credits `feeGrowthGlobal` exactly as a swap fee does,
so there is no ledger, no claim surface and nothing new to trust, and Uniswap rather than a
contract of ours does the weighting. It becomes the wrong mechanism the moment the LP share is
all of it: `sweep` is permissionless, so anyone could add a large full-range position, sweep, and
remove it in the same transaction, taking almost the whole harvest for a position that carried
risk for zero seconds. Donation weights by liquidity at an instant, and an instant is exactly
what an attacker picks. `LpRewardDistributor` weights by liquidity times time, which they cannot.

The price of that is custody: a staked position's NFT is transferred to the distributor and held.
Two properties bound it. `unstake` is not pausable and does not depend on a reward transfer
succeeding, so a halted protocol or a broken reward leg never traps a position; and staking is
optional, so an LP who wants nothing to do with this keeps their NFT and still earns the pool's
own swap fees.

**Only full-range positions may stake.** The float being distributed is earned on the pool's
whole stable-side balance rather than on any tick, so admitting a concentrated position would
mean paying one that stops backing the market the moment price leaves its band, in proportion to
a liquidity number that is not comparable with a full-range one.

An earlier revision of this section weighed a menu of destinations: an operator payout, a burn,
a redistribution, a referrer slice, a lockbox. Two of those verdicts still carry. The operator
payout was dropped because it is pure extraction from float that somebody else supplied, and that
is why `operator` remains a label rather than a claim. The referrer slice is still the mechanism
in §2 that would make a launchpad a partner, and it is unbuilt. The rest of the menu was about
choosing a buyback sink, and there is no sink to choose.

The protocol take is a deploy-time number capped at `MAX_PROTOCOL_BPS` (2,000), shipped at zero,
and fixed per market once stamped, so changing it moves future markets only. "Fixed" means fixed
for the life of the implementation rather than of the bytecode: every market's vault shares one
beacon, so a beacon upgrade could change how these numbers are read, and there is no timelock
in front of that (§10).

## 7a. The trading fee

**A trader pays about 1%, split down the middle: 0.50% to the pool's LPs through Uniswap's own
fee accounting, and 0.50% to the protocol through `ProtocolFeeHook`.** Every live market runs at
exactly those numbers — `key.fee` is 5,000 and `feePipsFor(poolId)` is 5,000, against a
1,000,000 denominator in both cases. The 0.50% tier is the one Uniswap v3 never had;
`AssetMarketFactory.tickSpacingForFee` pins it to a spacing of 50.

**The protocol's half is taken in `afterSwap`, on the swap's UNSPECIFIED leg.** A v4 swap names
exactly one side: `amountSpecified` is the input on an exact-input swap and the output on an
exact-output one. Whichever side it did not name is the side this hook charges. So on an
exact-input swap — the ordinary case, and what an aggregator sends — **the fee comes out of the
OUTPUT token** and the trader receives `amountOut - fee`. On an exact-output swap the unspecified
leg is the input, and the trader pays `amountIn + fee`. One rule covers both directions, so there
is no swap type to flip into to escape it.

`beforeSwap` returns `ZERO_DELTA` unconditionally and charges nothing. It survives only to write
the pool's oracle observation.

**Why it moved, because this section used to say the opposite.** The fee was taken in
`beforeSwap`, off the input, which is where a hook has to take its slice if it wants that slice
charged upstream of the LP fee. The defect is that `beforeSwap` runs before `pool.swap` and so
can only see the amount the caller *asked* for. A v4 swap is under no obligation to fill that: a
caller passing a `sqrtPriceLimitX96` short of where the pool would have to travel gets a partial
fill, and the old ordering billed them on notional that never traded, up to the full fee on the
unfilled remainder. Our own `MarketRouter` never reached that case, because it passes the extreme
limits and so fills or reverts. An aggregator quoting these pools straight against the
`PoolManager` sets its own limit and is precisely the caller that does. `afterSwap` is handed the
`BalanceDelta` the pool actually produced, so a partial fill is charged on the fill and on
nothing else.

**That is an economic change rather than a refactor, and it moved value to the LPs.** Under the
old ordering the skim came off the top and the pool swapped only the remainder, so the LP fee was
charged on less than the trader brought. Now the pool sees the whole input and the LPs earn on
all of it, while the protocol takes its pips out of an output already net of the LP fee and of
price impact. The protocol's take on an exact-input swap is therefore slightly smaller than it
used to be, and it accrues in the output currency rather than the input one.

**The fee is already inside the returned delta, and must not be subtracted twice.** It is a hook
return delta on the unspecified currency, so it is netted into the `BalanceDelta` that
`PoolManager.swap` gives back. An unmodified `V4Quoter` is exact against these pools with no
adjustment. See [docs/0x/HOOK_SPECIFICATION.md](docs/0x/HOOK_SPECIFICATION.md).

**Fees accrue as ERC-6909 claims rather than transfers.** `poolManager.mint` moves no tokens; it
credits the hook inside the PoolManager. That keeps the per-swap cost to a storage write, and
more importantly it leaves the calling router's settlement ordering unconstrained — a hook that
called `poolManager.take` mid-swap would need the PoolManager to already hold the trader's input,
which is only true for routers that prepay.

Four things are worth stating plainly about this:

- **The rate is bounded in bytecode at `MAX_FEE_PIPS = 10_000`, which is 1%.** It was lowered
  from 5% once aggregators began quoting these pools: at a 5% ceiling the owner could multiply a
  live 0.50% skim tenfold in one transaction and invalidate every quote in flight. The ceiling is
  checked when an increase is scheduled and again when it is committed.
- **An increase is announced an hour ahead; a decrease is immediate.** `setPoolFeePips` schedules
  a rise `FEE_INCREASE_DELAY` (3,600 seconds) out, a permissionless `commitPoolFeePips` applies
  it, and a cut lands at once and cancels anything pending. This is a reliability guarantee for a
  quote in flight, not a governance guarantee, because the owner can upgrade the hook in a single
  transaction (§10). The same asymmetry, with the same delay, governs the reserve's redemption
  fee.
- **The destination is repointable by the owner, and used not to be.** `registerPool` binds a
  pool's recipient one-shot, but `setFeeRecipient` moves it afterwards. The old immutability
  protected the promise that a market's trading fees bought that market's asset, and the engine
  and lockbox that made that promise are both deleted; every live pool is registered to the
  protocol treasury rather than to a per-market vault. It was never a real constraint on this
  owner in any case, who could always ship an implementation that repoints. Fees already accrued
  are unaffected: they sit in `pendingFees` and are paid to whoever is named when `collect` runs.
- **The treasury accumulates market assets.** On an exact-input buy the output leg is the asset,
  so the fee arrives as the asset, which can be an issuer-upgradeable proxy (§3.2). On a sell it
  arrives as the brand unit. That is the cost of charging every swap rather than half of them.

## 8. The LP problem, and the bet this design makes on it

In a Mode B pool, the brand units sitting in the reserves were supplied by **liquidity
providers**. It is their capital that generates the float yield. Routing 100% of it anywhere else
is extraction from LPs, and a rational LP responds by providing to a plain USDG pool instead —
where they keep nothing but at least lose nothing.

Naive versions of this design die exactly here, and quietly: the market looks fine, it just never
gets deep.

The first answer was a protocol-enforced floor of the split, held in an `LpRewardEscrow` until a
gauge could distribute it. Then, for a stretch, there was no floor at all: everything went to the
buyback, an LP on a brand pool earned swap fees and nothing more, and the paragraph above ran
against this design rather than for it.

**The floor is now the whole thing.** All of the float yield, less a protocol share shipped at
zero, goes to the LPs who supplied the stable side that earns it. Providing to a brand pool
therefore strictly dominates providing to a plain USDG pool: swap fees **plus** the reserve's
yield on the stable side.

What made it affordable is the venue, twice over. V4 made the first version free — `donate` pays
in-range liquidity through the pool's own fee accounting, so no escrow, no gauge and no LP
wrapper were needed. Making the LP share *all* of the yield then made `donate` unusable, for the
reason in §7, and what replaced it is still far short of the original gauge: one distributor per
market, holding staked full-range position NFTs, paying by liquidity times time.

Three things it does not solve, and none should be papered over:

- **Staking is a second transaction.** An LP who seeds and walks away earns the pool's swap fees
  and no float at all. That is a real drop-off, and the UI has to carry it rather than hide it.
- **Custody.** A staked NFT is held by the distributor, which is a beacon proxy with no timelock
  above it. `unstake` is not pausable and never depends on a reward transfer succeeding, so a
  halt or a broken reward leg cannot trap a position, but the beacon key can.
- **Concentrated LPs get no float.** Deliberate, per §7, and it means the strategy this venue
  rewards is the full-range one.

The remaining bet is that paying for depth in cash is a better way to buy depth than paying for
it through a price. The evidence is not in yet: the six live pools hold roughly $37.7k between
them. If the bet is wrong, the alternatives are known and both are large — a gauge with a
fungible full-range wrapper, or restoring a bid of some kind. Watch staked depth against total
depth before creating many more markets.

A clean special case: when the operator is the sole LP, they are earning float yield on their own
inventory and the whole question is a no-op. That is a genuinely good product on its own —
*market making with a quote asset that pays you* — and it is the easiest first market to stand
up, because it needs no third party.

## 9. One stablecoin, one pool — and why that reversed

**This section used to argue the opposite, and the argument lost.** A brand was not limited to
one pair: `createMarket` registered a brand and its first pool, `openMarket` added further pools
up to 32, and spaceXUSD could quote spaceX, DOGE and PEPE at once behind one reserve position and
one yield stream.

Dividing that stream was the whole problem. The reserve accrues yield on a brand's *total
outstanding supply* and has no idea where those tokens sit. With one pool that does not matter.
With several, each pool's share has to be measured — and the measure has to survive somebody
minting brandUSD, parking it in a pool for one block to buy weight, and redeeming it. Balances
are trivially spoofable that way, because reserve minting is 1:1, reversible, and the poke that
records weight is permissionless. `MarketYieldSplitter` solved it properly, using the pool's own
`secondsPerLiquidityCumulativeX128` accumulator to weigh legs by liquidity-seconds, which cannot
be moved by a flash balance. That solution was correct and it was tested. It was also 632 lines,
and it dragged `SplitterDeployer` and `IYieldDestination` along behind it, and it pushed
`AssetMarketFactory` past the EIP-170 limit.

**The feature was not worth its machinery.** Nothing was lost that a second brand does not
recover: registering one costs a single transaction, and `SharedReservePool.swap()` moves between
brands at exactly 1:1 with no slippage and no approval, so N brand stables do not fragment the
quote layer the way USDC and USDT do. A user holding spaceXUSD can enter a DOGE market quoted in
dogeUSD at no cost. What the split bought was a shared *name*; what it cost was a spoof-resistant
weighting system, a per-destination ledger, a carried remainder for periods with no weight, and a
factory that no longer fit in a contract.

So a brand now gets exactly one market. `openMarket` reverts `BrandAlreadyHasMarket` on a second
call, and each market's budget is simply its `BrandFeeVault`'s balance. The economics of a market
are now readable without reference to any other market, which was never true before.

The one genuine loss is worth naming: a brand with several pools earned yield on float held in
*all* of them, including float in pools the operator did not have to seed separately. Separate
brands each start their float at zero. That is a real cost to an operator running several pairs,
and it is the price of the deletion.

## 10. Risks

- **Issuer control of the asset** (§3.2). Redemption is structurally safe because the reserve is
  USDG-only; LP inventory is not. Disclose it.
- **One reserve per strategy group, and one adapter under each.** Brands sharing a
  `SharedReservePool` share its yield source. A bad market cannot hurt another brand — yield
  splits strictly by outstanding supply — but a bad adapter hurts every brand on that reserve
  at once. There are two live reserves, one backed by sUSDai and the factory-default one backed
  by Morpho, and `StrategyGroupRegistry` is what keeps a market pointed at the right one. Every
  live market is on the sUSDai reserve.
- **Redemption liquidity, and a redemption fee.** `_recallIfNeeded` pulls from the yield source
  on demand and can fail when the underlying market is fully utilized; the reserve keeps no idle
  buffer, so a redemption's liveness is the adapter's liveness. Redemption is also not free: the
  sUSDai reserve charges 20 bps, bounded by `MAX_REDEMPTION_FEE_BPS` of 1%, and an increase is
  announced `FEE_INCREASE_DELAY` (one hour) ahead while a decrease takes effect immediately and
  cancels any pending increase. Read `previewRedeem` rather than assuming par.
- **Listing squatting on memecoins.** The bytecode test has no analogue outside the equity
  registry. Needs curation plus attestation from the token's deployer, and a UI that visibly
  separates `verified` from `unverified`.
- **Thin pools, and the MEV that follows from them.** The six live pools hold roughly $37.7k
  between them, so price impact is severe at sizes an aggregator would consider routine — 1,000
  USDG moves the NVDA market more than 100%. The deep leg of this system is the reserve, not the
  AMM: about $9.96M of mint headroom against ~$35.3k redeemable at par less 20 bps. Any surface
  presenting the pools as the liquidity is overselling them. The buyback that used to be the
  standing counterweight here, and the front-running hazard that came with it, went together.
- **The oracle outlived its consumer.** `ProtocolFeeHook` still writes a V3-style observation
  ring on every swap, throttled to one entry per `PoolObservations.MIN_INTERVAL` (15s), but
  nothing inside the protocol prices anything off it any more — the TWAP existed for the
  buyback's price band. It is now a public good the pools emit rather than a safety-critical
  input, which is the right way round: manipulating it costs an attacker inventory and buys them
  nothing here. `consultTick` ends its window at `now` and is the unsafe reader; it is declared
  on `IPoolOracle` and has no caller anywhere in `src/`.
- **Assets that tax their own transfers cannot have a working market, and this is deliberately
  not checked.** Uniswap v4 is paid by transferring into the `PoolManager` between `sync` and
  `settle` and then asserting the exact amount arrived, so a token that skims a plain `transfer`
  cannot be sold; and because Permit2 does the pulling on the liquidity path, one that skims
  `transferFrom` cannot be seeded. Both worked under v3, which pulled and measured. A
  creation-time probe was considered and rejected: it would answer a question about a moment
  while reading as an answer about the asset, and against issuer-upgradeable proxies (§3.1) that
  is a misleading guard rather than a weak one — the issuer can add the tax the next day. It
  would also fail hardest on its intended targets, since a token that taxes selectively is
  written to let a transfer between two factory-controlled addresses through. The failure is
  instead made legible where it happens, in the app's error copy.
- **Regulatory shape.** "Issuer keeps the float, holders get a 1:1 peg" is the Tether/Circle
  shape and is the most defensible version of this. The design used to ship a harder version —
  float interest funding a buyback of the market's own token — and no longer does. The float now
  pays the market's liquidity providers, which reads as a rebate on capital they supplied rather
  than as a bid under an asset they hold. Still worth counsel, and no longer prospectively: the
  live markets hold real float today.
- **There is no upgrade timelock.** Custody is a 2-of-3 Gnosis Safe at
  `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, which is a real improvement on the single hot
  key that preceded it, but every `_authorizeUpgrade` in the stack is still a bare `onlyOwner`.
  Two signatures can replace the hook, the factory, the router or either reserve in one
  transaction, with no delay and no notice. The one-hour delay on fee increases is a reliability
  guarantee for quotes in flight, not a governance guarantee, and must never be described as
  one. See [docs/0x/SECURITY_AND_GOVERNANCE.md](docs/0x/SECURITY_AND_GOVERNANCE.md).

## 11. Sequencing

**Phase 0 — the prerequisites this document used to list as blockers. Done.**
`SharedReservePool` is deployed and holds real float, the yield adapters carry per-consumer
share accounting, and custody moved off the deployer EOA. One item did not close the way it was
written: the timelock whose delay was to be raised off zero no longer exists at all. It was
retired in the migration to the Safe, so an upgrade now lands in the transaction that proposes
it, signed by two of three. That is a reduction in delay, not an increase, and §10 says so.

**Phase 1 — the market. Live.** `AssetMarketFactory` + `BrandFeeVault` + `LpRewardDistributor`
+ `ProtocolFeeHook` + `MarketRouter`, Mode B only, with the float yield less the protocol share
streaming to staked full-range LPs. Six markets are live, ids **13 through 18**. Ids 1 to 12 are
zero-liquidity leftovers from earlier deploys and any enumeration should filter them out.

**Phase 2 — liquidity.** Whatever the live markets show is needed to get deep. This is where the
open question in §12 gets answered, and the pools are thin enough today that it is not answered
yet.

**Phase 4 — Mode A and referrals.** Routed markets for the deep names, and the launchpad
referrer integration from §2.

## 12. Decisions still open

1. ~~The buyback sink~~ — **moot**. There is no buyback; the float yield pays LPs (§7).
2. ~~Protocol take rate~~ — **decided**: a fixed bps stamped per market, shipped at zero (§7).
3. **Whether paying LPs directly attracts the liquidity the buyback was supposed to attract.**
   This replaces the question the buyback posed and is the one the design now lives or dies on
   (§8). The measurement is staked depth against total depth on the live markets, and today the
   pools are thin enough that the answer is still pending rather than negative.
4. ~~The buyback's schedule and band~~ — **moot** with the engine. What survives of that
   machinery is the oracle, which now has no in-protocol consumer (§10).
5. ~~Attribution across several pools per brand~~ — **abandoned, and the machinery deleted**.
   It was built: a brand could be paired into up to 32 pools and `MarketYieldSplitter` divided
   each harvest by liquidity-seconds read off each pool's own accumulator. It worked and it was
   not worth its weight. A brand now gets exactly one market, so there is nothing to attribute
   and a market's budget is simply its vault's balance. See §9 for the full reversal and what
   it costs an operator.
6. **Memecoin listing curation** — attestation-only, allowlist, or a bond.
7. **Whether the operator is the token's team, a third-party KOL, or a launchpad.** Deliberately
   left open: `operator` carries no payout and no authority beyond opening the brand's market,
   so nothing about the contracts changes depending on who holds it. Worth revisiting now that
   real markets exist.

## 13. What the tests actually prove

The suites below are the ones that carry this design's load-bearing claims. Counts are
deliberately not quoted here: they were wrong in every earlier revision of this section within a
week of being written, and `forge test` reports them accurately on demand.

```bash
forge test --no-match-path 'test/*Fork*'
```

```bash
forge test -v --fork-url https://rpc.mainnet.chain.robinhood.com
```

**The fee lands where this document says it lands.** `test/markets/ProtocolFeeHook.t.sol` is the
authority on §7a. `test_exactIn_skimsTheOutputCurrency` and
`test_exactIn_theSkimComesOutOfTheOutputAndLeavesTheSwapUntouched` pin the exact-input case to
the output leg; `test_exactOut_stillSkimsTheInputCurrency` pins the other direction;
`test_neitherSwapTypeEscapesTheFee` is the reason one rule covers both. The finding that moved
the fee out of `beforeSwap` has its own regression in
`test_exactIn_aPartialFillIsNeverChargedOnTheUnfilledRemainder`, which is the whole point of the
change and the one test to read if you read only one.

**The fee-increase delay behaves like a delay.** `test_anIncreaseDoesNotTakeEffectUntilItIsCommitted`,
`test_anIncreaseCannotBeCommittedEarly`, `test_anyoneMayCommitAnAnnouncedIncrease`,
`test_aDecreaseIsImmediateAndAbandonsAPendingIncrease` and
`test_theCeilingIsCheckedAtCommitAsWellAsAtSchedule` cover the asymmetry between increases and
decreases, and that the ceiling binds twice.

**LPs are paid by liquidity times time, not by liquidity at an instant.**
`test/markets/LpRewardDistributor.t.sol` carries §8. `test_justInTimeLiquidityEarnsNothing` is
the attack that killed the `donate` mechanism, asserted in its closed form;
`test_rewardsSplitByLiquidityAndTime` is the property that replaced it;
`test_rewardStreamedWithNothingStakedIsBankedNotGiftedToTheNextStaker` and
`test_partialIdleTimeIsSplitBetweenBankAndStream` cover the case a market with no stakers falls
into. `test_stakeRejectsAConcentratedPosition` enforces the full-range rule and
`test_pauseStopsStakeClaimAndFeesButNeverUnstake` is the custody bound: a halt never traps a
position.

**It works against the real singleton, not a mock.** `test/markets/AssetMarketV4Fork.t.sol` runs
against the deployed v4 `PoolManager`:
`test_fork_theDeployedPoolManagerIsTheOneTheAddressesFileNames` is the check that would have
caught deploying our own singleton (see §6), `test_fork_theHookValidatesAtItsFlaggedAddressAgainstTheRealManager`
proves the mined address carries the permissions the hook declares, and
`test_fork_theVaultSplitsItsYieldToTheLpsOfTheRealPool` is the income path end to end.
`test/markets/MarketRouterV4Fork.t.sol` covers seeding against the real `PositionManager`,
including that the seeder — not the router — owns the resulting NFT.

**Canonicality holds against the real tokens.** `test/markets/AssetMarketFork.t.sol` runs the
`EXTCODEHASH` test on live equities and on things that are not equities. The check is sufficient
rather than merely suggestive: every genuine token is the same 283-byte beacon proxy, and the
beacon address is an `immutable` compiled into that runtime code, so equal codehash implies the
same beacon. §3.2 is where that matters.

### Notes for whoever runs these

- Foundry crashes on macOS inside a restricted sandbox (`SCDynamicStore` returns NULL when it
  reads the system proxy configuration). `forge build` is unaffected; anything that opens an HTTP
  client — a fork URL, the OpenChain signature lookup — panics. `--offline` avoids it for local
  runs; a fork run needs the sandbox off.
- The public RPC is not an archive node and prunes aggressively. A fork run at head can fail
  mid-suite with `layer stale`. Pin it: `--fork-block-number <recent>`.
