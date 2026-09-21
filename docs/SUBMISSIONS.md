# External review submissions

A log of the exact trees handed to third parties. Each entry pins a git tag, so a future
question from a reviewer can be answered against what they were actually shown rather than
against whatever `main` has become since.

**Answering a reviewer: diff against the tag, never against `main`.**

```
git fetch --tags
git diff review/0x-kyberswap-2026-09-20..main -- src/
git log --oneline review/0x-kyberswap-2026-09-20..main -- src/
```

---

## 0x and KyberSwap, 2026-09-20

| | |
|---|---|
| Tag | `review/0x-kyberswap-2026-09-20` |
| This repository | `9139ca1ac28fbc36049350b6e5e384c999a20fff` |
| Monorepo counterpart | `StableLaunchpad` `39215860e4efc536f45bcf107daf342cfd1ae274`, same tag name |
| Measured numbers in the package | block **68,293,146**, Robinhood Chain mainnet, chainId 4663 |
| Parameters re-confirmed unchanged at | block **68,460,340** |
| Submitted to | 0x, via the Custom Uniswap v4 Hook Request form; KyberSwap, via the `dex-lib` adapter |
| Package | [`docs/0x/`](./0x/) and [`docs/KYBERSWAP_INTEGRATION.md`](./KYBERSWAP_INTEGRATION.md) |

### Addresses as submitted

| Contract | Address |
|---|---|
| `ProtocolFeeHook` proxy, flags `0x00CC` | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` |
| `ProtocolFeeHook` implementation | `0xd4AC6b17338866E43E1922cfb563A81Ff36b425B` |
| Uniswap v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` |
| `MarketLens` | `0x704E7a0e7864250303B05b25EabC2417CE99ceb6` |
| sUSDai reserve | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` |
| Owner Safe, 2-of-3 | `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` |

### Parameters as submitted

| Parameter | Value |
|---|---|
| Hook fee, all six live pools | 5,000 pips (0.50%), denominator 1e6 |
| `MAX_FEE_PIPS` | 10,000 (1.00%) |
| `FEE_INCREASE_DELAY` | 3,600 seconds, increases only |
| Redemption fee | 20 bps on sUSDai, 0 on USDG/Morpho |
| Live markets | ids 13 through 18; ids 1 through 12 are dead |
| Build | solc `v0.8.26+commit.8a97fa7a`, optimizer 200 runs, `via_ir = true` |

### The claim under review

The protocol fee is taken in `afterSwap` on the swap's **unspecified** leg as a return delta,
so it is already inside the `BalanceDelta` that `PoolManager.swap` returns. A stock `V4Quoter`
is therefore exact and an integrator must not subtract the fee again. This was measured
wei-exact against an unmodified `V4Quoter` on all six pools; see
[`docs/0x/SETTLER_COMPATIBILITY.md`](./0x/SETTLER_COMPATIBILITY.md) section 6.

### What changes would invalidate the submission

If any of these move, tell both teams rather than waiting for them to find it:

- the hook's fee basis, denominator, or which leg it charges
- `MAX_FEE_PIPS` or `FEE_INCREASE_DELAY`
- the hook proxy address, or its permission flags, which cannot change without a new address
- `MarketLens`, which is not upgradeable, so every revision is a new address. Already replaced
  twice: `0x1727ffB1...` then `0x0a3d8332...` then the current one
- the set of live markets, or the reserve backing them
- ownership or the guardian

### Known state at submission, disclosed rather than hidden

- Liquidity is deliberately small; these are seed pools, wired up ahead of a hard launch.
- Every proxy is UUPS behind the Safe with **no upgrade timelock**, so an upgrade lands in one
  transaction. The fee-increase delay is a reliability property, not a security one.
- No external audit. Internal review only.
- USDG's issuer can pause or freeze the reserve asset, which no code here can mitigate.

### Deliberately excluded

The Kyber adapter was submitted as `integrations/kyberswap-dex-lib/hooks/stables/` with exchange
id `uniswap-v4-stables`. A rename to `stables-fast` and `uniswap-v4-stables-fast`, part of the stables.fast rebrand, was
staged but uncommitted when the submission went out. It is **not** part of this tag, and `main`
has been restored to the submitted path so the repository matches what KyberSwap was pointed at
while the review is open. The rebrand is preserved and should land as its own deliberate commit,
at which point **KyberSwap must be told**: both the directory and the exchange id move, and they
were pointed at both directly.
