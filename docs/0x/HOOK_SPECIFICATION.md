# ProtocolFeeHook - specification for 0x

The safety and predictability review document for the single Uniswap v4 hook attached to every
Stables market pool on Robinhood Chain mainnet (`chainId 4663`). Source of truth is
`src/markets/ProtocolFeeHook.sol` (962 lines) and `src/markets/PoolObservations.sol`; every
mechanical claim below carries a `file:line` citation into those, into `v4-core` where the
behavior is core's rather than ours, or into the repository's own gas test.

Companion documents, which this one does not repeat:

- [Quoting and settlement](./QUOTING_AND_SETTLEMENT.md) - how to turn this into a number and settle it.
- [Security and governance](./SECURITY_AND_GOVERNANCE.md) - who can change what, and how fast.
- [Markets](./MARKETS.md) - the pool inventory, tokens, decimals and measured depth.
- [`docs/AGGREGATOR_INTEGRATION.md`](../AGGREGATOR_INTEGRATION.md) - the venue-neutral integration page this layer sits on top of.

Section 10 answers the 0x custom v4 hook request form directly.

## 1. Summary

`ProtocolFeeHook` is a fee-skimming hook that is also the pools' TWAP oracle. It runs on exactly
two callbacks. `beforeSwap` charges nothing and only writes an observation. `afterSwap` takes the
entire protocol fee as a return delta on the **unspecified** leg of the swap, computed from the
`BalanceDelta` the pool actually produced. Because that return delta is folded into the
`BalanceDelta` that `PoolManager.swap` returns to the caller, a router or quoter that reads the
returned delta already sees the fee. There is nothing for an integrator to add or subtract.

| Property | Value | Source |
|---|---|---|
| Hook address (UUPS proxy) | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` | facts sheet; `guard()`, `owner()`, `poolManager()` read on chain at block 68,299,112 |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` (canonical) | `poolManager()` on chain |
| Permission flags | `0x00CC` (address low 14 bits = `0x00CC`) | `getHookPermissions()` on chain; `ProtocolFeeHook.sol:320-337` |
| What it charges | a flat share of the swap, per pool | `ProtocolFeeHook.sol:644` |
| Where it charges | `afterSwap` only, on the unspecified currency | `ProtocolFeeHook.sol:636-649` |
| Denominator | `PIPS_DENOMINATOR = 1_000_000` (hundredths of a bp, same units as `key.fee`) | `ProtocolFeeHook.sol:120` |
| Live rate | 5,000 pips (0.50%) on all six live pools, no pending change | facts sheet, all six at block 68,293,146; pool id 13 re-confirmed at block 68,299,112 (`feePipsFor` 5000, `feePipsEffectiveAt` 0) |
| Hard ceiling | `MAX_FEE_PIPS = 10_000` (1.00%), a bytecode constant | `ProtocolFeeHook.sol:140` |
| Fee increase notice | `FEE_INCREASE_DELAY = 1 hours`, announce-then-commit | `ProtocolFeeHook.sol:153`, `407-464` |
| Fee accounting | ERC-6909 claim via `poolManager.mint`, never a mid-swap `take` | `ProtocolFeeHook.sol:819` |
| Upgradeable | yes, UUPS, `_authorizeUpgrade` is `onlyOwner` with **no timelock** | `ProtocolFeeHook.sol:300` |
| Flags upgradeable | no - they are the address | `lib/v4-core/src/libraries/Hooks.sol:337-339` |
| Owner | Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`, 2-of-3 | `owner()` on chain; facts sheet |

Liquidity is deliberately small right now. These are seed pools, and the integrations are going
in ahead of a hard launch rather than afterwards. See [Markets](./MARKETS.md) for measured price
impact before sizing anything, and re-measure at integration time.

## 2. Permission flags

v4 encodes a hook's permissions in the low 14 bits of the hook's own address. `Hooks.hasPermission`
is a bit test against `uint160(address(self))`
(`lib/v4-core/src/libraries/Hooks.sol:337-339`); the `PoolManager` never asks the contract what it
is allowed to do, it asks the address. Bit assignments are
`lib/v4-core/src/libraries/Hooks.sol:29-47`.

`0xc9932584c5154e4F58313a2e5423522E74e540Cc & 0x3FFF == 0x00CC`.

| Bit | Flag | Set | Consequence |
|---|---|---|---|
| 13 | `BEFORE_INITIALIZE` | no | no callback on `initialize` |
| 12 | `AFTER_INITIALIZE` | no | no callback on `initialize` |
| 11 | `BEFORE_ADD_LIQUIDITY` | no | LPs are never gated by this hook |
| 10 | `AFTER_ADD_LIQUIDITY` | no | no add-liquidity callback |
| 9 | `BEFORE_REMOVE_LIQUIDITY` | no | **an LP can always withdraw**, halted or not |
| 8 | `AFTER_REMOVE_LIQUIDITY` | no | no remove-liquidity callback |
| 7 | `BEFORE_SWAP` | **yes** | oracle write only, see section 3 |
| 6 | `AFTER_SWAP` | **yes** | the whole fee, see section 4 |
| 5 | `BEFORE_DONATE` | no | donate is unhooked |
| 4 | `AFTER_DONATE` | no | donate is unhooked |
| 3 | `BEFORE_SWAP_RETURNS_DELTA` | **yes** | declared, never exercised - `beforeSwap` returns `ZERO_DELTA` (`ProtocolFeeHook.sol:592`) |
| 2 | `AFTER_SWAP_RETURNS_DELTA` | **yes** | this is what lets `afterSwap` claim anything |
| 1 | `AFTER_ADD_LIQUIDITY_RETURNS_DELTA` | no | |
| 0 | `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` | no | |

Verified live: `getHookPermissions()` on the proxy returns exactly
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` true and the other ten
false, matching `ProtocolFeeHook.sol:320-337` and matching the address bits.

Bit 3 being set with no corresponding delta is deliberate and documented at
`ProtocolFeeHook.sol:307-319`. It was load-bearing when the exact-input skim lived in `beforeSwap`
and became vestigial when the skim moved. Declaring a permission the code does not use is safe in
this direction only: the manager calls the callback, the callback returns a zero delta, nothing is
claimed. `Hooks.isValidHookAddress` (`lib/v4-core/src/libraries/Hooks.sol:109-127`) also requires
that a return-delta flag is only set alongside its action flag, which holds here.

### The flags cannot change across an upgrade

This is the claim worth checking carefully, because the contract *is* upgradeable.

The `PoolManager` derives the permission set from the hook address on every single call, via
`hasPermission` (`lib/v4-core/src/libraries/Hooks.sol:337-339`). A UUPS upgrade replaces code
behind a proxy; it cannot move the proxy's address. Therefore the set of callbacks the manager
invokes is fixed for the life of the deployment, independent of any implementation.

What the implementation says about itself is a separate thing.
`Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions())` runs in `initialize`
(`ProtocolFeeHook.sol:288`), which is `initializer`-guarded and therefore runs exactly once, on
the proxy, at deployment. It does **not** re-run on `upgradeToAndCall`. So a future implementation
could ship a `getHookPermissions()` that disagrees with the address and nothing would revert. That
disagreement would be a documentation bug, not a behavior change: the manager would keep calling
`beforeSwap` and `afterSwap` and nothing else. The comment at `ProtocolFeeHook.sol:264-273` states
this and the comment at `ProtocolFeeHook.sol:307-319` is the standing instruction not to do it.

Practical consequence for routing: **the callback surface of this hook is immutable.** An upgrade
can change what `afterSwap` computes, bounded by `MAX_FEE_PIPS`; it cannot make the hook start
gating liquidity, start intercepting `initialize`, or start returning a `beforeSwap` delta that
changes the specified amount. For what an upgrade *can* do, see
[Security and governance](./SECURITY_AND_GOVERNANCE.md).

## 3. `beforeSwap` charges nothing

```solidity
function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
    external
    onlyPoolManager
    returns (bytes4, BeforeSwapDelta, uint24)
{
    _writeObservation(key.toId());

    return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```

`ProtocolFeeHook.sol:585-593`, quoted verbatim. Three things to read off it:

1. The return delta is `BeforeSwapDeltaLibrary.ZERO_DELTA`, unconditionally, with no branch above
   it (`ProtocolFeeHook.sol:592`). There is no path through this function that charges anything or
   modifies `amountToSwap`.
2. The third return value is `0`, the LP fee override. Our pools are static-fee
   (`key.fee = 5000` on all six), and `Hooks.beforeSwap` only parses an override when
   `key.fee.isDynamicFee()` (`lib/v4-core/src/libraries/Hooks.sol:263`), which is false here. The
   LP fee you read off the `PoolKey` is the LP fee that is charged.
3. It ignores its `sender` and `hookData` arguments, both unnamed in the signature.

The only work it does is `_writeObservation` (`ProtocolFeeHook.sol:590`), which records the
**pre-swap** tick into a V3-style ring buffer (`ProtocolFeeHook.sol:666-685`). This callback exists
because v4 core deleted observations and a v4 pool keeps no price history at all, so the oracle has
to live in the only contract invoked on every swap. The rationale for the pre-swap tick, and why
recording the post-swap tick in `afterSwap` would be a manipulation vector rather than a rounding
quibble, is at `ProtocolFeeHook.sol:558-584`.

The write is cheap and self-limiting:

| Behavior | Source |
|---|---|
| Pool the hook does not know: `cardinality == 0`, return immediately. One cold SLOAD, nothing else. | `ProtocolFeeHook.sol:667-668` |
| At most one observation per `MIN_INTERVAL = 15` seconds; later writes in the window are no-ops | `PoolObservations.sol:68`, `PoolObservations.sol:182` |
| `Observation` is a single storage slot (the V3 `secondsPerLiquidity` series was dropped) | `PoolObservations.sol:83`, and the rationale at `PoolObservations.sol:21-31` |
| Buffer opened only in `registerPool`, not in an `afterInitialize` hook | `ProtocolFeeHook.sol:373-377` |

The observation is written above every early return, including when the protocol is paused, so
oracle history survives a halt (`ProtocolFeeHook.sol:530-531`).

## 4. `afterSwap` and the fee

This is the whole fee mechanism, in full:

```solidity
function afterSwap(
    address,
    PoolKey calldata key,
    SwapParams calldata params,
    BalanceDelta delta,
    bytes calldata
) external onlyPoolManager returns (bytes4, int128) {
    PoolId id = key.toId();

    bool exactInput = params.amountSpecified < 0;

    (Currency unspecified, int128 unspecifiedAmount) = exactInput == params.zeroForOne
        ? (key.currency1, delta.amount1())
        : (key.currency0, delta.amount0());

    // Widened to `int256` before negating: `-type(int128).min` does not fit in an `int128`.
    int256 base = exactInput ? int256(unspecifiedAmount) : -int256(unspecifiedAmount);
    if (base <= 0) return (IHooks.afterSwap.selector, 0);

    uint256 feeAmount = FullMath.mulDiv(uint256(base), feePipsFor(id), PIPS_DENOMINATOR);
    if (feeAmount == 0) return (IHooks.afterSwap.selector, 0);

    _accrue(id, unspecified, feeAmount);

    return (IHooks.afterSwap.selector, feeAmount.toInt128());
}
```

`ProtocolFeeHook.sol:625-650`, quoted verbatim.

### 4.1 Which leg is the unspecified one

A v4 swap names exactly one side. `amountSpecified` is the input on an exact-input swap (negative)
and the output on an exact-output swap (positive). The other side is the unspecified one.

The hook's currency selection at `ProtocolFeeHook.sol:636-638` is the predicate
`exactInput == params.zeroForOne`, which is literally core's own test
`params.amountSpecified < 0 == params.zeroForOne`. Core uses that same expression to order the
hook's returned `int128` into a `BalanceDelta`:

```solidity
hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
    ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)
    : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);

// the caller has to pay for (or receive) the hook's delta
swapDelta = swapDelta - hookDelta;
```

`lib/v4-core/src/libraries/Hooks.sol:307-312`. Because the hook derives its accrual currency from
the same predicate core uses to place the returned number, the currency the hook books and the
currency core settles against cannot disagree.

### 4.2 The sign, and what the trader sees

`Hooks.afterSwap` computes `swapDelta = swapDelta - hookDelta`, so a **positive** returned `int128`
always means "credit the hook, charge the swapper", whichever leg the unspecified currency is. What
flips between the two swap types is the sign of the delta the hook reads, which is why line 641
normalizes to a positive magnitude and line 642 returns a zero delta for anything that does not
carry the expected sign, rather than casting through it.

| Swap type | `amountSpecified` | Unspecified leg | `unspecifiedAmount` sign | Fee denominated in | What the trader observes |
|---|---|---|---|---|---|
| Exact input | `< 0` | the **OUTPUT** | positive (pool credited the swapper) | the **token being bought** | receives `amountOut - fee` |
| Exact output | `> 0` | the **INPUT** | negative (swapper owes it) | the **token being sold** | pays `amountIn + fee` |

**On an exact-input swap the fee comes out of the token you receive, not the token you send.** This
is the opposite of the usual skim-the-input hook. It is also invisible to a caller who reads the
returned `BalanceDelta`, because core has already subtracted the hook delta from it at
`lib/v4-core/src/libraries/Hooks.sol:312` before `PoolManager.swap` returns. A stock `V4Quoter`
(`0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F` on 4663, Uniswap's own, unmodified) is therefore
already exact. Do not add or subtract the fee yourself. See
[Quoting and settlement](./QUOTING_AND_SETTLEMENT.md) for the quoting path.

### 4.3 Rounding

`FullMath.mulDiv(base, feePips, 1e6)` at `ProtocolFeeHook.sol:644` is a floor. The remainder is
discarded, never rounded up, in both directions:

- exact input: the fee subtracted from the trader's output is rounded down, so the trader receives
  at least the exact-arithmetic amount.
- exact output: the fee added to the trader's input is rounded down, so the trader pays at most the
  exact-arithmetic amount.

Rounding is therefore always in the trader's favor, by at most one base unit.

Two early returns bound the degenerate cases:

- `base <= 0` returns a zero delta (`ProtocolFeeHook.sol:642`). This covers a swap that filled
  nothing because `sqrtPriceLimitX96` was already reached. It costs the caller nothing and does not
  revert.
- `feeAmount == 0` returns a zero delta and skips the `mint` entirely
  (`ProtocolFeeHook.sol:645`). At 5,000 pips that is any unspecified-leg magnitude below 200 base
  units, which for a 6-decimal brand dollar is under 0.0002 units. Dust swaps pay no fee and pay no
  extra gas for the accrual.

`feeAmount.toInt128()` at line 649 is v4-core's `SafeCast`. `feeAmount <= base` and `base` came out
of an `int128`, so the cast cannot overflow for any real swap; there is no revert path here that a
router could trip.

### 4.4 Worked arithmetic at the live parameters

The hook's own worked example (`ProtocolFeeHook.sol:64-73`) uses a 0.30% LP tier. Every live pool
is a 0.50% LP tier with a 5,000 pip (0.50%) protocol fee, so here is the same arithmetic at the
live numbers. Price impact is ignored in order to isolate the fee; on these pools impact dominates
at almost any size and is reported in [Markets](./MARKETS.md).

**Exact input, 1,000 units in:**

| Step | Amount |
|---|---|
| Trader sends | 1,000.000 |
| Pool swaps the whole input, LPs earn `key.fee` on all of it | 5.000 to LPs |
| Pool produces (the unspecified leg) | 995.000 |
| Hook takes `995.000 x 5000 / 1e6` | 4.975 |
| Trader receives | 990.025 |

All-in cost `1 - 0.995^2 = 0.9975%`. Note that the LPs earn their fee on the entire input. Under
the older ordering, where the skim ran ahead of `pool.swap`, the pool only saw 995 and the LPs were
diluted by the skim; the trader's all-in rate was materially the same, and what moved was which
currency the protocol is paid in (`ProtocolFeeHook.sol:55-73`).

**Exact output, 1,000 units out:**

| Step | Amount |
|---|---|
| Trader asks for | 1,000.000 out |
| Pool requires (the unspecified leg), `1000 / 0.995` | 1,005.025126 |
| Hook takes `1,005.025126 x 5000 / 1e6` | 5.025125 |
| Trader pays | 1,010.050251 |

Effective rate `1000 / 1010.050251 = 0.99004975` against the exact-input `0.995^2 = 0.990025`. The
two differ by `0.005^2 = 25` pips, the fee squared, and the exact-output path is the cheaper of
the two for the trader. So a v4 exact-output number that is then settled as an exact-input fill
delivers about 25 pips less than it quoted. Quote an exact-output number only against the
settlement mode you will actually use; see [Quoting and settlement](./QUOTING_AND_SETTLEMENT.md).

**Integer example, to pin the rounding.** Exact input against an 18-decimal asset, pool produces
`3987654321098765432` wei on the unspecified leg:

```
base     = 3987654321098765432
feeAmount = 3987654321098765432 * 5000 / 1000000 = 19938271605493827   (floored; exact value ends .16)
trader   = 3987654321098765432 - 19938271605493827 = 3967716049493271605
```

`PoolManager.swap` returns a `BalanceDelta` whose unspecified-leg amount is already
`3967716049493271605`.

## 5. Why the fee is in `afterSwap` and not `beforeSwap`

`beforeSwap` runs before `pool.swap`. The only quantity available to it is the amount the caller
*asked* for. A v4 swap is under no obligation to fill that: a caller who passes a
`sqrtPriceLimitX96` short of where the pool would have to travel gets a partial fill, and the
remainder is silently unfilled with no revert. Charging in `beforeSwap` therefore bills the trader
on notional that never traded (`ProtocolFeeHook.sol:42-53`, `ProtocolFeeHook.sol:580-584`).

`afterSwap` is handed the `BalanceDelta` that `pool.swap` actually produced, so an unfilled
remainder is simply absent from the number the fee is computed on. There is no partial-fill branch
in the code because there is nothing for one to do (`ProtocolFeeHook.sol:622-624`, and the
computation at `ProtocolFeeHook.sol:641-644` reads only `delta`).

This matters specifically to 0x. Our own `MarketRouter` never reached the bad case, because it
passes extreme price limits and so either fills completely or reverts. An aggregator quoting these
pools directly against the `PoolManager` sets its own `sqrtPriceLimitX96` and is precisely the
caller that gets partial fills. Under the current design a partially filled leg is charged on what
filled and nothing else.

To be clear about what this does and does not buy: it is a correctness property of the fee, not a
liquidity guarantee. A partial fill is still a partial fill, and on pools this small a binding
price limit is easy to hit. It means only that the fee never exceeds the stated rate on the volume
that actually moved.

## 6. Fee accounting: ERC-6909 claims, never a mid-swap `take`

```solidity
function _accrue(PoolId id, Currency currency, uint256 amount) internal {
    poolManager.mint(address(this), currency.toId(), amount);
    pendingFees[id][currency] += amount;

    emit FeeAccrued(id, currency, amount);
}
```

`ProtocolFeeHook.sol:818-823`, quoted verbatim.

`poolManager.mint` moves no tokens. It credits this contract with an ERC-6909 claim inside the
`PoolManager` and debits the hook's own delta by the same amount; the positive `int128` the hook
returns credits it back, so the pair nets to zero by the end of the unlock
(`ProtocolFeeHook.sol:815-817`).

The reason this is the right primitive, from a router's point of view: **a `mint` imposes no
ordering constraint on the caller's settlement.** A hook that called `poolManager.take` mid-swap
would require the `PoolManager` to already hold the trader's input at the moment `afterSwap` runs,
which is only true for routers that prepay their input before calling `swap`. A router that settles
after the swap, or that nets several swaps and settles once at the end of a single `unlock`, would
see that `take` fail or would see its own accounting broken. This hook never calls `take` on the
swap path. `take` appears exactly once in the contract, in `_settleOne`
(`ProtocolFeeHook.sol:876`), which is reached only from `collect` through the hook's own separate
`unlock` (`ProtocolFeeHook.sol:832-879`).

`collect` is permissionless, takes no destination argument, and reverts when the protocol is paused
(`ProtocolFeeHook.sol:830-838`). It is not on the swap path and is not an integration surface; it
is listed here only so a reviewer can see where the accrued claims go.

## 7. What the hook does NOT do

| Not done | Evidence |
|---|---|
| **No `sender` check.** Both swap callbacks take `address` as an unnamed, unread first parameter. Pricing is not caller-dependent, so a 0x quote and a 0x fill see the same rate as anyone else. | `ProtocolFeeHook.sol:585`, `ProtocolFeeHook.sol:625-626` |
| **No allowlist, no KYC gate, no per-caller rate.** The only address check on the swap path is `onlyPoolManager`, which is an authenticity check on the caller being the `PoolManager` itself. | `ProtocolFeeHook.sol:255-258` |
| **No `hookData` read.** Both callbacks take `bytes calldata` unnamed and never decode it. Pass empty bytes. Passing anything else is harmless and costs only calldata gas. | `ProtocolFeeHook.sol:585`, `ProtocolFeeHook.sol:630` |
| **No exact-out block.** Exact-output swaps are supported and charged by the same expression as exact-input. There is no swap type that reverts and no swap type that escapes the fee. | `ProtocolFeeHook.sol:634-649` |
| **No revert when paused.** `feePipsFor` returns 0 when the protocol is halted and trading continues untouched. A hook that reverted would take a public Uniswap pool offline for every trader, ours or not. | `ProtocolFeeHook.sol:535-539`, rationale at `523-534` |
| **The pause read cannot revert either.** `_haltedSafely` is a raw `staticcall` that treats any failure (reverting registry, no code, self-destructed) as "not halted". It fails toward charging the fee, never toward bricking the pool. | `ProtocolFeeHook.sol:550-554` |
| **No liquidity callbacks.** LPs can add and remove regardless of hook state or protocol pause. Nothing can trap liquidity in these pools through the hook. | flags in section 2; `ProtocolFeeHook.sol:324-327` |
| **No interaction with any other DEX protocol during a swap.** The only external calls on the swap path are to the `PoolManager` itself and to the pause registry. There is no router call, no flash accounting against a third venue, no rebalance. | `ProtocolFeeHook.sol:670`, `ProtocolFeeHook.sol:819`, `ProtocolFeeHook.sol:551-552` |
| **No reentrancy into the pool.** The hook never calls `poolManager.swap`, `modifyLiquidity`, `donate` or `unlock` from `beforeSwap` or `afterSwap`. `unlock` is called only from `collect`. | `ProtocolFeeHook.sol:847` is the sole `unlock` call site |
| **No subhooks, hooklets or extensions.** There is no registry of delegate hooks, no `delegatecall` other than the UUPS proxy's own call into its implementation, and no address the owner can point the swap path at. `feeRecipientOf` is a payout destination read only by `collect`, never by `beforeSwap` or `afterSwap`. | `ProtocolFeeHook.sol:179`, `ProtocolFeeHook.sol:837` |
| **No unused callbacks reachable.** The eight unpermissioned `IHooks` functions (the ten unset flags include two add/remove-liquidity return-delta bits, which have no separate function) exist only to satisfy the interface, are `onlyPoolManager`, and are never invoked because the address bits do not name them. | `ProtocolFeeHook.sol:881-961` |

### External oracles: the hook writes one, it does not read one

This distinction needs to be exact, because the 0x form asks about it directly.

**The hook does not read any oracle, internal or external, to price a swap.** The fee is
`FullMath.mulDiv(base, feePipsFor(id), 1e6)` where `base` comes from the `BalanceDelta` the pool
produced and `feePipsFor` reads two storage mappings (`ProtocolFeeHook.sol:644`,
`ProtocolFeeHook.sol:535-539`). There is no price feed, no Chainlink or Pyth read, no external
quote, and no reference to any other venue anywhere on the swap path. Execution price is entirely
the pool's own AMM curve.

**The hook does write its own internal TWAP observations.** `_writeObservation`
(`ProtocolFeeHook.sol:666-685`) appends the pre-swap tick to a per-pool ring buffer ported from
Uniswap V3's `Oracle.sol` (`PoolObservations.sol:15-19`). This exists because v4 core removed
observations from the pool and something downstream needs a manipulation-resistant price band. That
data is produced by the hook, stored in the hook, and read back through the hook's own
`observe`/`consultTick` view functions (`ProtocolFeeHook.sol:721-728`,
`ProtocolFeeHook.sol:750-769`). Nothing on the swap path reads it.

Summarized for the form: **"Depend on External Oracles" - No.** The hook publishes an oracle; it
consumes none. A failure, staleness or manipulation of any oracle anywhere cannot change the price
a swap through this hook executes at.

## 8. Gas

### What is actually asserted

`test/markets/HookGasOverhead.t.sol` runs the identical swap against two pools that differ only in
whether the hook is attached, and asserts bounds on the difference
(`test/markets/HookGasOverhead.t.sol:91-135`). The bounds exist as a tripwire against a new
`SSTORE` appearing on the swap path, because an off-chain aggregator adapter hard-codes the
numbers (`test/markets/HookGasOverhead.t.sol:31-37`). The figures below are that test's
assertions as written in the repository. They were not re-measured for this document and the
suite was not run as part of producing it.

| Case | Asserted overhead vs an unhooked pool | Assertion |
|---|---|---|
| Exact input, first swap, fee-currency storage cold | 80,000 +/- 15,000 | `HookGasOverhead.t.sol:126` |
| Exact input, fee-currency storage warm | 20,000 +/- 8,000 | `HookGasOverhead.t.sol:127` |
| Exact output, fee-currency storage warm | 20,000 +/- 8,000 | `HookGasOverhead.t.sol:128` |
| First swap in a direction that touches its own fee currency's storage for the first time | bounded below 70,000 | `HookGasOverhead.t.sol:130-134` |

**Read the first row carefully: it does not include an observation write.** The test warps 12
seconds before its first swap (`HookGasOverhead.t.sol:94`) while the oracle throttle is
`MIN_INTERVAL = 15` seconds (`PoolObservations.sol:68`), so `PoolObservations.write` returns at
`PoolObservations.sol:182` without touching the ring on every swap in that test. The assertion
message on line 126 says "observation + accrue" and the comment on line 92 says the swap pays for
the first observation of the block; both predate the throttle, which replaced V3's
once-per-block rule (`PoolObservations.sol:158-168`). The 80,000 band is therefore the
cold-storage cost of the fee accrual and the hook's cold `SLOAD`s, not accrual plus an
observation. This is reported to 0x as a gap in our own instrumentation rather than papered over.

### The steady-state decomposition

Every swap, in `beforeSwap`:

- one `SLOAD` of the packed `observationStates[id]` slot (`ProtocolFeeHook.sol:667`). For a pool
  the hook does not know, `cardinality == 0` and that `SLOAD` is the entire cost of the hook
  (`ProtocolFeeHook.sol:668`).

In `afterSwap`, once the unspecified-leg delta carries the expected sign
(`ProtocolFeeHook.sol:642`):

- one `SLOAD` of `feeRecipientOf`, a `staticcall` to the pause registry, and one `SLOAD` of
  `feePipsOf` (`ProtocolFeeHook.sol:536-538`, `551-552`). All three are skipped on a swap that
  filled nothing.

On a swap that then produces a nonzero fee, additionally:

- one `poolManager.mint`, which is an ERC-6909 balance `SSTORE` inside the `PoolManager`, and one
  `pendingFees` `SSTORE` here (`ProtocolFeeHook.sol:819-820`). This is the 20,000 warm band.

At most once per 15 seconds per pool, additionally:

- a `poolManager.getSlot0` read and an `SLOAD` of the newest observation
  (`ProtocolFeeHook.sol:670`, `PoolObservations.sol:156`), one `SSTORE` into the ring
  (`PoolObservations.sol:195`), and one `SSTORE` to the packed cursor slot when the index or
  cardinality moved (`ProtocolFeeHook.sol:681-684`). No assertion in the repository bounds this
  path today, for the reason above. Note that `increaseObservationCardinalityNext` prepays the
  ring slots it opens, specifically so the ring `SSTORE` is a nonzero-to-nonzero write rather
  than a zero-to-nonzero one for the trader who happens to wrap into a new slot
  (`PoolObservations.sol:198-203`).

Because exact-input and exact-output accrue in different currencies, the two directions touch two
different `pendingFees` slots and two different ERC-6909 balances, so the first swap in each
direction pays cold-slot prices once (`HookGasOverhead.t.sol:103-113`).

## 9. Determinism checklist

| Question | Answer | Citation |
|---|---|---|
| Is the fee a pure function of pool state and swap params? | Yes. Inputs are the `BalanceDelta` the pool produced, `params.amountSpecified`, `params.zeroForOne`, and two storage reads (`feeRecipientOf`, `feePipsOf`). Nothing else enters the arithmetic. | `ProtocolFeeHook.sol:634-644`, `535-539` |
| Is the execution price a pure function of pool state and swap params? | Yes. The hook does not touch `sqrtPrice`, liquidity, ticks or the LP fee. It returns no `beforeSwap` delta and no LP fee override, so the AMM math is stock v4. | `ProtocolFeeHook.sol:592` |
| Does it depend on `block.timestamp`? | Not for pricing. `feePipsFor` never reads it. `block.timestamp` is read only by `_writeObservation` for the oracle and by the governance schedule functions, neither of which is on the pricing path. | `ProtocolFeeHook.sol:535-539` (no timestamp); `675`; `431`, `444` |
| Does it depend on `block.number`, `blockhash`, `prevrandao`, `gasleft`? | No. None appear in the contract. | `ProtocolFeeHook.sol:585-650` |
| Does it depend on `tx.origin`? | No. `tx.origin` does not appear in the contract. | `ProtocolFeeHook.sol:585-650` |
| Does it depend on `msg.sender`? | Only to authenticate the `PoolManager`. The swapper's address arrives as an unnamed, unread parameter. Note that v4 core itself skips all hook calls when the hook is the swap caller (`msg.sender == address(self)`), which is a core behavior and not reachable by an external router. | `ProtocolFeeHook.sol:255-258`, `585`, `625-626`; `lib/v4-core/src/libraries/Hooks.sol:293` |
| Does it make external calls during a swap? | At most three, and only to two addresses, both written once in `initialize` and unchangeable without an upgrade: `poolManager.getSlot0` and `poolManager.mint` on the canonical `PoolManager`, and a `staticcall` to our pause registry `0x013D1974F8215a12280e6b9a33F9732277F38C0e`. No third-party protocol is called. | `ProtocolFeeHook.sol:670`, `819`, `551-552`; sole writes at `285-286`; `guard()` read on chain |
| Can any of those calls change the price between quote and fill? | Only the pause read, and only downward: a pause sets the fee to 0, which can only improve the trader's fill. The pool state read is the same state the quoter read. | `ProtocolFeeHook.sol:537` |
| Can the rate change between quote and fill? | An increase cannot land within `FEE_INCREASE_DELAY` (1 hour) of its announcement, and `feePipsEffectiveAt(poolId)` tells you whether one is pending (zero means none). A decrease can land immediately, which is in the trader's favor. This is a reliability property, not a security one; see the next row. | `ProtocolFeeHook.sol:407-464`, `222` |
| Can an upgrade bypass that? | Yes. `_authorizeUpgrade` is `onlyOwner` with no timelock, so the owner can ship an implementation without the delay in a single transaction. Stated plainly in the contract's own comment. Bound your fills with `minBuyAmount` regardless. | `ProtocolFeeHook.sol:300`, rationale at `397-403`; see [Security and governance](./SECURITY_AND_GOVERNANCE.md) |
| Is the fee bounded? | Yes, by `MAX_FEE_PIPS = 10_000` (1.00%), a bytecode constant re-checked on both write paths and again at commit. Changing it requires shipping an implementation. | `ProtocolFeeHook.sol:140`, `358`, `409`, `452` |

## 10. The 0x custom v4 hook request form, answered

Fields as rendered at `https://0x.portal.usepylon.com/forms/custom-uniswap-v4-hook-request`.

| Form field | Answer |
|---|---|
| Contract Address | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` (UUPS proxy). One hook, all six live pools. Do not pin the implementation address. |
| Contracts Verified On Chain? | Yes, on Sourcify as `exact_match`. solc `v0.8.26+commit.8a97fa7a`, optimizer 200 runs, `via_ir = true`, standard-JSON input. Blockscout's verify API sits behind a Cloudflare challenge on this chain, so Sourcify is the route. |
| Contracts immutable? | **No.** UUPS proxy, `_authorizeUpgrade` is `onlyOwner` with no timelock (`ProtocolFeeHook.sol:300`). Owner is a 2-of-3 Gnosis Safe, `0x28569c1716EF81f307d666A1EC08bDAE92AC0373`. What an upgrade **cannot** change is the permission-flag set, which is the address itself (section 2). The fee is bounded at 1.00% by a bytecode constant unless an implementation is shipped. Full blast-radius analysis in [Security and governance](./SECURITY_AND_GOVERNANCE.md). |
| Returns delta flags set? | **Yes, both.** `BEFORE_SWAP_RETURNS_DELTA` (bit 3) and `AFTER_SWAP_RETURNS_DELTA` (bit 2). The `beforeSwap` one is declared but never exercised; `beforeSwap` returns `ZERO_DELTA` unconditionally (`ProtocolFeeHook.sol:592`). The `afterSwap` one carries the entire fee, on the unspecified leg, and is already netted into the `BalanceDelta` that `PoolManager.swap` returns (section 4). |
| Interact with other DEX protocols during swapping? | **No.** The only external calls during a swap are `poolManager.getSlot0`, `poolManager.mint`, and a `staticcall` to our own pause registry (section 9). |
| Hook extensions / subhooks / hooklets? | **No.** No delegate registry, no dynamic dispatch, no owner-settable address on the swap path (section 7). |
| Depend on External Oracles | **No.** The hook writes its own V3-style TWAP observations for downstream consumers and reads no oracle of any kind to price a swap (section 7). |

Two things a router integrator must get right, restated because they are the two that break
integrations:

1. **Do not adjust for the fee.** It is already in the returned `BalanceDelta`. Adding it again
   double-counts and will cause your `minBuyAmount` check to fail or your quote to be wrong by the
   fee.
2. **Pass empty `hookData`.** Nothing is read from it.

Everything else an integrator needs - discovery, the two-leg USDG route, quoting, settlement
calldata - is in [Quoting and settlement](./QUOTING_AND_SETTLEMENT.md), [Markets](./MARKETS.md) and
[`docs/AGGREGATOR_INTEGRATION.md`](../AGGREGATOR_INTEGRATION.md).
