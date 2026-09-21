# Stables: 0x integration package

Everything 0x needs to evaluate and route our Uniswap v4 pools on Robinhood Chain mainnet
(`chainId 4663`).

## Read in this order

| # | Document | Question it answers |
|---|---|---|
| 1 | [SETTLER_COMPATIBILITY.md](./SETTLER_COMPATIBILITY.md) | Can 0x settle us with the code it already has? |
| 2 | [HOOK_SPECIFICATION.md](./HOOK_SPECIFICATION.md) | What does the hook do, mechanically? |
| 3 | [QUOTING_AND_SETTLEMENT.md](./QUOTING_AND_SETTLEMENT.md) | How do I price it and land a trade? |
| 4 | [MARKETS.md](./MARKETS.md) | What is tradeable and how deep is it? |
| 5 | [SECURITY_AND_GOVERNANCE.md](./SECURITY_AND_GOVERNANCE.md) | Who can change what, and how fast? |
| - | [FORM_ANSWERS.md](./FORM_ANSWERS.md) | Prepared submission text, for us rather than for them |

The broader venue-neutral document is [../AGGREGATOR_INTEGRATION.md](../AGGREGATOR_INTEGRATION.md).

## The five facts that matter

1. **The chain is already supported.** 0x lists Robinhood 4663 as GA for Swap and Gasless, and
   lists Uniswap V4 among its Robinhood liquidity sources. A Settler is deployed at
   `0x6aa80DbBed9ae5aB45FbF61f9644faDA3b29326E`, with canonical Permit2 and AllowanceHolder.
   This is not a new-chain request.

2. **Our pools are in the PoolManager Settler already targets.** Settler pins
   `ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951`. All six of our pools
   live there.

3. **The hook fee is inside the delta, so a stock quoter is exact.** The entire fee is taken in
   `afterSwap` on the unspecified leg as a return delta. Settler credits the actual
   `BalanceDelta` the PoolManager returns, so the fee is netted automatically. Measured at block
   68,293,146: an unmodified Uniswap `V4Quoter` and our independently written `MarketLens` agree
   **to the wei on all six pools**. Do not subtract the fee again.

4. **Liquidity is deliberately small right now.** These are seed pools. We are getting the
   integrations in place ahead of a hard launch rather than afterwards, so that routing works
   from day one instead of arriving months later. The deep leg is the reserve: roughly 9.96M
   USDG of mint headroom and about 35,276 USDG currently redeemable, 1:1 less 20 bps. Measured
   price impact per pool, and the size that fills today, are in [MARKETS.md](./MARKETS.md).

5. **It is upgradeable, with no timelock.** A 2-of-3 Safe can upgrade the hook in one
   transaction. Fee increases are delayed an hour and decreases are immediate, which makes a
   quote reliable for an hour, but that is a reliability property and not a security one because
   an upgrade could remove it. Stated plainly in
   [SECURITY_AND_GOVERNANCE.md](./SECURITY_AND_GOVERNANCE.md).

## Key addresses

| Contract | Address |
|---|---|
| `ProtocolFeeHook` (flags `0x00CC`) | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` |
| Uniswap v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| `MarketLens` | `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` |
| sUSDai reserve (backs all six markets) | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` |
| Owner Safe, 2-of-3 | `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` |
| USDG (the chain's dollar, 6dp) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |

**AIUSD `0xE7BB388959d89f809BE24da16A1DaBa0dC58E596` is a brand dollar, not USDG.** It is a 1:1
claim on the sUSDai reserve. The two have been confused before. See [MARKETS.md](./MARKETS.md).

**`MarketLens` is the one row here that moves.** It is ownerless, stateless and not a proxy,
so it is never upgraded in place; a revision is a new address, and the one above is the
2026-09-20 redeploy that made every quote function `view`. Resolve it from `core.marketLens`
in `deployments/asset-markets-mainnet-v6.json` rather than hardcoding it. Everything else in
the table is either a proxy at a fixed address or Uniswap's own canonical deployment.

## How to submit

Canonical page: <https://docs.0x.org/liquidity-integration/liquidity-integrations>

File the **Custom Uniswap v4 Hook Request**:
<https://0x.portal.usepylon.com/forms/custom-uniswap-v4-hook-request>

Prepared answers for all ten fields are in [FORM_ANSWERS.md](./FORM_ANSWERS.md). Do not file the
DEX Integration Request unsolicited; ask in the hook submission whether they want it for the
reserve leg.

0x states that submission does not guarantee integration and that they prioritize on liquidity
quality, technical readiness and ecosystem fit. Lead with technical readiness and the launch
timeline: the code is done and the pools are seed liquidity being wired up before the hard
launch, not after it. Give the measured depth as measured depth.

## Cover message

Short, because the documents carry the detail. Paste into the form's Subject and body, or send
through the Pylon messenger in the 0x dashboard.

**Subject:** `ProtocolFeeHook - afterSwap fee hook on Robinhood Chain (4663), 6 live pools`

```
Hi,

We run Stables, a tokenized-equity and launchpad protocol on Robinhood Chain (4663). We have
six live Uniswap v4 pools behind one custom hook and would like them routable through 0x.

Hook:        0xc9932584c5154e4F58313a2e5423522E74e540Cc  (flags 0x00CC)
PoolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951
             - the same one pinned as ROBINHOOD_POOL_MANAGER in 0x-settler

Three things that should make this a short review:

1. The hook takes its entire fee in afterSwap, on the unspecified leg, as a return delta.
   Because Settler credits the actual BalanceDelta the PoolManager returns, the fee is netted
   automatically and no adapter work looks necessary. We read your v4 code carefully before
   writing this.

2. Quote equals execution, which we understand is your central concern with v4 hooks. An
   unmodified Uniswap V4Quoter with empty hookData and our own independently written lens
   agree to the wei on all six pools. Table and method in SETTLER_COMPATIBILITY.md section 6.
   The one thing not to do is subtract our protocol fee yourself, since it is already gone
   from the quoted amount.

3. No hookData, no subhooks, no external oracle read, no sender or origin dependence, no calls
   to other DEX protocols during a swap. The hook writes its own TWAP buffer; it never reads a
   price feed.

Two things we would rather state plainly than have you discover:

- Liquidity is deliberately small right now. These are seed pools. We are getting the
  integrations in place ahead of a hard launch rather than afterwards, so that routing works
  from day one instead of arriving months later. The deep leg is our 1:1 reserve, with roughly
  9.96M USDG of mint headroom. Measured price impact per pool, and the size that fills today,
  are in MARKETS.md.
- The hook is a UUPS proxy behind a 2-of-3 Safe with no upgrade timelock. Fee increases are
  delayed one hour and decreases are immediate, so a quote is good for an hour, but we are not
  going to describe that as a security guarantee when an upgrade could remove it.

Full package, including PoolKeys, closed-form quoting math, settlement paths and a governance
writeup: <link to docs/0x/>

Happy to co-sign a settled test trade through the Robinhood Settler, or to write and maintain
a Settler mixin or sampler if you decide one is needed.

Two questions from our side:
- Does your production v4 quoter already execute arbitrary afterSwap return-delta hooks when
  sampling, or does a hook need to be modeled or allowlisted first?
- Should we also file the DEX Integration Request for the 1:1 reserve mint and redeem leg, or
  does the hook form cover it?

Thanks,
<name>
```

## Provenance

Every address and number in this package was read from chain at block **68,293,146** via
`https://rpc.mainnet.chain.robinhood.com`. Claims about 0x's own code cite
`0xProject/0x-settler` at commit `cdf29a06769749674ffe7846e154f1d1566b0cc2`, with the deployed
Robinhood Settler declaring `gitCommit` `1df908742d38cf407f667df6518dae6e04a01ac3`.
