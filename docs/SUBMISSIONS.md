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

### What the tag does not contain, and why that is fine

At the tag the Kyber adapter sits at `integrations/kyberswap-dex-lib/hooks/stables/` with
exchange id `uniswap-v4-stables`. The `stables.fast` rebrand was staged but uncommitted when
the tag was cut, so the tag shows the pre-rebrand names.

**The pull request that KyberSwap actually received uses the rebranded names.**
[KyberNetwork/kyberswap-dex-lib#1699](https://github.com/KyberNetwork/kyberswap-dex-lib/pull/1699),
opened 2026-09-21 from `Snojj25/kyberswap-dex-lib:feat/stables-fast-robinhood`, registers
`uniswap-v4-stables-fast` under `hooks/stables-fast/`. `main` here has been realigned to match
that branch, so the tag and `main` differ on this point by design: the tag records what the 0x
documentation described, and `main` tracks what Kyber is reviewing.

So when answering KyberSwap, diff against the PR branch rather than the tag. When answering 0x,
use the tag. Nothing about the contracts differs between them; only the adapter's directory and
exchange id changed, and neither is on chain.

### Review activity since submission

PR #1699 received one automated review comment, from GitHub Copilot: `Track`'s RPC path was
covered only by live tests that skip when `CI` is set. Answered by `hook_track_test.go`, which
stubs the JSON-RPC endpoint and covers the ordinary decode, the unregistered sentinel, a rate
above `MAX_FEE_PIPS`, and the ceiling itself. **No contract change was required**, and none was
made; the hook Solidity is untouched since the tag.
