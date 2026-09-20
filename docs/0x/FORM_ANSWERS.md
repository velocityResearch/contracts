# 0x submission: prepared answers

Copy-paste text for 0x's intake forms. Every factual claim here is verified on chain at block
68,293,146 on Robinhood Chain mainnet, `chainId 4663`.

Canonical onboarding page (0x's own help article calls it canonical):
<https://docs.0x.org/liquidity-integration/liquidity-integrations>

| Form | URL | File it? |
|---|---|---|
| Custom Uniswap v4 Hook Request | <https://0x.portal.usepylon.com/forms/custom-uniswap-v4-hook-request> | Yes, this is the primary one |
| DEX Integration Request | <https://0x.portal.usepylon.com/forms/dex-integration-request> | Only if 0x asks, for the reserve leg. See note at the end |
| RFQ Interest Form | <https://zeroex.notion.site/238ac66a853780acb4bcfd882a97a541> | No, we are not a market maker |

0x states plainly that submitting does not guarantee integration and that they prioritize on
liquidity quality, technical readiness and ecosystem fit. Our liquidity is small today. Lead
with technical readiness, which is where we are genuinely strong, and be upfront about size.

---

## Custom Uniswap v4 Hook Request

### Name
*Your name.*

### Email
*Your email. Use one you will actually monitor; this is how they reply.*

### Subject

```
ProtocolFeeHook - afterSwap fee hook on Robinhood Chain (4663), 6 live pools
```

### Contract Address

```
0xc9932584c5154e4F58313a2e5423522E74e540Cc
```

Add, in whatever free-text room the form gives:

```
Hook: 0xc9932584c5154e4F58313a2e5423522E74e540Cc (hook flags 0x00CC)
Chain: Robinhood Chain mainnet, chainId 4663
PoolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951
  (this is the same PoolManager already pinned as ROBINHOOD_POOL_MANAGER in
   0x-settler src/core/UniswapV4Addresses.sol)
6 live pools, all fee tier 5000, tickSpacing 50, all on this hook.
Full PoolKeys, poolIds and token decimals: see MARKETS.md in the package below.

Liquidity, stated upfront rather than discovered: the v4 pools are early and thin,
about $37.7k across all six. The deep leg is our 1:1 reserve, with roughly 9.96M USDG
of mint headroom and about 35,276 USDG currently redeemable at par less 20 bps.
Measured price impact per pool, and a derived max routable size, are in MARKETS.md.
If you have a depth threshold before a source is worth indexing, we would rather hear
it now than guess.
```

### Contracts Verified On Chain?

```
Yes. Verified on Sourcify as exact_match.

Compiler v0.8.26+commit.8a97fa7a, optimizer enabled with 200 runs, viaIR true.
Verify by standard-JSON input rather than a flattened source; the build uses viaIR
and flattened verification will not reproduce the bytecode.

Note on the explorer: Blockscout's verification API on this chain sits behind a
Cloudflare challenge, so Sourcify is the working route. Happy to supply the exact
standard-JSON input on request.
```

### Contracts immutable?

Answer honestly. Do not fudge this; they can read the ERC-1967 slot in ten seconds.

```
No. The hook is a UUPS proxy owned by a 2-of-3 Gnosis Safe
(0x28569c1716EF81f307d666A1EC08bDAE92AC0373, Safe v1.4.1). There is no upgrade timelock,
so the Safe can upgrade in a single transaction. We would rather tell you that than have
you find it.

What an upgrade CANNOT change: the hook's permission flags. They are mined into the low
bits of the hook address, and PoolKey.hooks is part of pool identity, so the callback set
is fixed at 0x00CC for the life of every pool. An upgrade can change fee logic, not which
callbacks fire.

What is bounded inside the current implementation:
  - MAX_FEE_PIPS = 10000, i.e. a 1.00% ceiling on the hook fee (denominator 1e6)
  - MAX_REDEMPTION_FEE_BPS = 100, i.e. a 1.00% ceiling on the reserve redemption fee
  These are constants in the implementation, so they bind the owner but not an upgrade.

Rate changes are rate-limited in the direction that can hurt a quote. An INCREASE to
either rate is announced and cannot take effect for FEE_INCREASE_DELAY = 3600 seconds;
it is then applied by a permissionless commit call. A DECREASE applies immediately and
cancels any pending increase. So a fee you read is good for at least an hour, and the
only thing that can change inside that hour moves in the taker's favor.

We are explicit that this is a reliability guarantee and not a security guarantee,
because the owner could upgrade the delay away. We are not going to describe it as
something it is not.
```

### Returns delta flags set?

```
Yes. Both BEFORE_SWAP_RETURNS_DELTA and AFTER_SWAP_RETURNS_DELTA are set (flags 0x00CC).

In practice only the afterSwap one is used:
  - beforeSwap returns ZERO_DELTA unconditionally and charges nothing. It exists solely to
    write a TWAP observation into an internal V3-style ring buffer.
  - afterSwap takes the entire protocol fee, on the UNSPECIFIED leg, computed from the
    BalanceDelta the pool actually produced. For an exact-input swap that is the OUTPUT
    leg, so the taker receives amountOut minus fee.

Why afterSwap and not beforeSwap: beforeSwap only sees the amount the caller ASKED for,
and a swap with a binding sqrtPriceLimitX96 need not fill it. Charging there bills a
trader for volume that never traded. Charging in afterSwap means a partial fill is charged
on the fill and nothing else. An aggregator that sets its own price limit is precisely the
caller that would have been overcharged, so this change was made with routers in mind.

Consequences for your router, which we think are all favorable:
  - The fee is inside the BalanceDelta that PoolManager.swap returns. A stock unmodified
    V4Quoter is already exact. Do NOT subtract the fee yourself; that double-counts it.
  - We measured this. At block 68293146, for all six pools, an unmodified V4Quoter
    (0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F) and our own independently written
    MarketLens agree to the wei on a 100-unit exact-input quote. Table in
    SETTLER_COMPATIBILITY.md section 6.
  - Fees accrue as ERC-6909 claims via poolManager.mint, never a mid-swap take. Settlement
    ordering is therefore unconstrained and routers that do not prepay still work.
  - Settler's v4 action only ever builds exact-input fills, so the exact-output branch of
    our hook is never reached on your path.

Current rate: 5000 pips = 0.50%, denominator 1e6, on every pool. Combined with the 0.50%
LP tier that is about 1% all-in. Read it live with feePipsFor(poolId); read
feePipsEffectiveAt(poolId) to see a pending increase, where zero means nothing pending.
```

### Interact with other DEX protocols during swapping?

```
No. The hook makes no external calls during a swap other than back into the PoolManager
that invoked it, and that call is poolManager.mint to credit the fee as an ERC-6909 claim.
No router, no other AMM, no lending market, no bridge, no token transfers.

For completeness about the wider protocol, since it is adjacent but NOT in the swap path:
the brand dollars traded in these pools are 1:1 claims on a reserve that deploys its idle
USDG into a yield source. That happens in the reserve's own mint, redeem and keeper calls,
never inside a v4 swap. A swap touches the PoolManager and the hook, nothing else.
```

### Hook extensions/subhooks/hooklets?

```
No. No subhooks, no hooklets, no delegatecall to third-party logic, no plugin registry,
no per-pool custom callback. One singleton hook contract serves every pool, with per-pool
configuration held in its own storage as plain values.

The only indirection is the UUPS proxy to its own implementation, which the Safe controls
and which is disclosed under the immutability question above.
```

### Depend on External Oracles

```
No. Nothing in the swap path reads any external price source. Pricing is a pure function
of pool state and the swap parameters.

To be precise rather than merely reassuring, because the word oracle cuts both ways here:
this hook WRITES an oracle, it does not READ one. Uniswap v4 core removed observations, so
a v4 pool keeps no price history. Our buyback engine needs a manipulation-resistant TWAP,
and the only contract already invoked on every swap is the hook, so the hook maintains a
V3-style PoolObservations ring buffer and writes one observation per swap in beforeSwap
from the pre-swap tick.

That buffer is a consumer of pool state, never an input to pricing. Removing it entirely
would not change a single quote. No Chainlink, Pyth, Redstone, or any other feed is read
anywhere in the hook.
```

---

## If 0x asks you to also file the DEX Integration Request

This covers the reserve mint and redeem leg, which is a separate venue from the v4 pools.
Do not file it unsolicited; ask in the hook submission whether they want it.

| Field | Answer |
|---|---|
| Team Name | *your team name* |
| Telegram Handle | *optional, but give one; it is how they will actually talk to you* |
| Blockchain | `Robinhood Chain mainnet, chainId 4663` |
| Contract Address | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` (the sUSDai reserve, which backs all six live markets) |
| Fork of? | `Not a fork. Original implementation. The closest familiar analogue is MakerDAO's DssLitePsm, and we expose exactly that interface as an optional wrapper via BrandPsm if configuring a PSM is easier for you than writing a new source.` |
| Notable differences | `It is a 1:1 mint and redeem window between USDG and a set of 6-decimal brand dollars, not a constant-product pool. mint is exactly 1:1 with no fee. redeem is 1:1 less a redemption fee, currently 20 bps, ceiling 100 bps. Capacity is finite and readable: MarketLens.maxMint(reserve) and MarketLens.redeemableAssets(reserve). Idle USDG is deployed to a yield source, which is why redeemable capacity is smaller than notional liabilities.` |
| Pool Discovery, derivable? | `Yes, fully enumerable on chain with no subgraph. AssetMarketFactory 0x22AA61c589B90731752236c07d1455D0065bfc79: marketCount(), then market(id), then poolKeyOf(id) for the exact PoolKey. MarketLens.route(id) returns the reserve, asset, brand, PoolKey, live fee pips and redemption fee in a single call. Ids 1-12 are dead zero-liquidity leftovers; filter with MarketRouter.marketLiquidity(id) > 0. Live ids today are 13 through 18.` |
| Pool Discovery, subgraph or JSON | `Not needed. If you would prefer a static file we will publish and maintain one, but derivation is exact and we would rather you not depend on us for freshness.` |
| Sampling | `Three options, pick whichever fits your stack. (1) Stock unmodified Uniswap V4Quoter at 0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F for the pool leg. Exact, including our hook fee. (2) MarketLens at 0x0a3d8332D949b4aE650f3aC6468620e403a50fF1, which composes the reserve leg and the pool leg and enforces capacity. quoteBuy, quoteSell, quoteBuyExactOut, quoteSellExactOut, all via eth_call against non-view functions in the usual revert-based style. (3) Pure off-chain math: mint is 1:1, redeem is in minus floor(in*feeBps/10000), the v4 leg is full-range constant product with the LP fee on the whole input, then the hook takes floor(out*feePips/1e6) off the produced output. All three agree; closed form is documented in QUOTING_AND_SETTLEMENT.md. A quote is either a size that settles or a revert. We never return a silent haircut.` |
| Settling | `The pool leg settles through the standard PoolManager unlock, swap, settle and take, with EMPTY hookData. Your existing UNISWAPV4 action already does this and already targets the correct PoolManager. The reserve leg is a plain call: mint(address brandToken, uint256 amount, address receiver), selector 0x0d4d1513, amount at calldata offset 36, requires a USDG approval to the reserve; and redeem(address brandToken, uint256 amount, address receiver, uint256 minAssetsOut), selector 0xf3f094a1, amount at offset 36, burns from msg.sender so no approval is needed. Always use the 4-argument redeem and pass a real minAssetsOut; the 3-argument overload derives its own floor from previewRedeem and reverts on yield-source dust. There is also a one-call MarketRouter that does both legs, at 0x7553919210B172438853C3694Fd88fAfD4bE3Eb4.` |
| Multiple trades, same pool, one transaction? | `Yes. The pool leg is ordinary Uniswap v4, so multiple fills against the same pool compose normally inside one unlock. The hook holds no per-transaction state and imposes no ordering constraint, because fees accrue as ERC-6909 claims rather than a mid-swap take.` |
| Native token supported? | `No. Every pool is ERC20 to ERC20. No pool has the native asset as a currency, and the reserve deals only in ERC20 USDG.` |
| Fee on Transfer tokens supported? | `Not applicable, and we would ask you not to set feeOnTransfer for our pools. No asset token and no brand dollar is fee-on-transfer; all are plain ERC20s. Our protocol fee is charged by the hook through a return delta, not by the tokens, so it is not a transfer-fee condition.` |

---

## What to attach or link

The four documents in this directory, plus this one. If the form has no attachment field, link
the repository and name the files.

| File | What it answers |
|---|---|
| [HOOK_SPECIFICATION.md](./HOOK_SPECIFICATION.md) | Exactly what the hook does, with source citations |
| [QUOTING_AND_SETTLEMENT.md](./QUOTING_AND_SETTLEMENT.md) | How to produce a number and land a trade |
| [SECURITY_AND_GOVERNANCE.md](./SECURITY_AND_GOVERNANCE.md) | Who can change what, how fast |
| [MARKETS.md](./MARKETS.md) | The pool and token inventory, and honest depth |
| [SETTLER_COMPATIBILITY.md](./SETTLER_COMPATIBILITY.md) | Why their existing v4 action already works |

The broader venue-neutral integration document is
[docs/AGGREGATOR_INTEGRATION.md](../AGGREGATOR_INTEGRATION.md).
