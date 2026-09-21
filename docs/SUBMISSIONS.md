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

### Pending, not yet shipped: graduates stop minting their own dollar

This is the "set of live markets" row above, called early rather than after the fact.

Launchpad graduation currently registers a fresh brand on the reserve and quotes the new pool in
it — that is where `SDOGE.d`, `ABR.d` and `CORGIGG.d` came from. A change on
`feature/graduate-into-launch-dollar-main` (see [`GRADUATE_INTO_LAUNCH_DOLLAR.md`](./GRADUATE_INTO_LAUNCH_DOLLAR.md))
removes that step: a graduating launch keeps the dollar it raised in, so the new market is a shared
quote from its first block and `allBrandTokens` stops growing on graduation.

What this does and does not move:

- **Markets 13 through 18 are untouched.** They are not migrated, they keep their units, and every
  address and number in the tables above still reads the same.
- **No submitted address changes, and no re-submission is implied.** Re-checked against the
  submission base on 2026-09-21: `git diff c7b9f407 -- src/markets/ProtocolFeeHook.sol
  src/markets/MarketRouter.sol src/markets/MarketLens.sol src/markets/V4SwapSimulator.sol
  src/pool/SharedReservePool.sol src/pool/BrandPsm.sol` prints nothing. Every contract either
  team was pointed at except `AssetMarketFactory` is byte-identical to what was submitted —
  the hook implementation included, and `MarketLens` included, where one changed byte would
  mean a new address. `PoolManager`, the sUSDai reserve and the Safe are not ours to move.
- **The rollout is seven contracts, and none of them changes an address.** Five are upgrades
  behind an address that stays: `AssetMarketFactory` and `LaunchFactory` as UUPS proxies, and
  `PoolBrandTreasury`, `BrandFeeVault` and `LpRewardDistributor` as beacons behind per-market
  proxies. The only submitted address among those is `AssetMarketFactory`
  (`0x22AA61c589B90731752236c07d1455D0065bfc79`), which is upgraded in place. The other two are
  launchpad-only redeploys neither team was pointed at, `LaunchGraduation` and `LaunchLocker`.
  `LaunchDeployer` was an eighth contract in an earlier shape of this change and is no longer
  replaced: the live deployer at `0x7979708A371E9f9dDb43A432595c3F59f77dd5E7` still serves a
  factory built from this tree, pinned as a live assertion by
  `test_live_theLiveLaunchDeployerStillServesAFactoryFromThisTree`
  (`test/LiveGen5Mainnet.t.sol:1159`) rather than trusted. So nothing in the tables above moves
  and there is nothing to re-submit; this is a notification, not a new package.
- **The live market set changes shape**, which is exactly the row this section already commits us
  to reporting. The next graduate will read `isSharedQuote(id) == true` and quote an existing brand,
  where 16, 17 and 18 read `false` and quote their own.
- **Tick spacing stops being derivable from the fee tier.** A graduated market's whole `PoolKey`
  is public before it graduates and `PoolManager.initialize` on it is permissionless, so the same
  change adds a 32-rung spacing ladder on the launch path: a squatted canonical key is stepped
  over rather than refused, and the market opens at `canonical + k`. Two things follow for an
  integrator, both already written into [`0x/MARKETS.md`](./0x/MARKETS.md) §2 and §8 — spacing
  MUST be read from `poolKeyOf(marketId)` and never from a v3-style fee-to-spacing table, and a
  pool sitting at the canonical key for a graduated asset is not necessarily ours. This is the
  only part of the change that reaches a quoting integrator at all, and it is a doc correction
  rather than an interface change: `poolKeyOf` already answered correctly.

**Both teams must be told when it deploys, and told what to read rather than what to hardcode:**
`AssetMarketFactory.isSharedQuote(marketId)` for the shared-quote flag, and `poolKeyOf(id)` for the
quote token, never the symbol and never the creation path. For KyberSwap the practical consequence
is that a per-brand capacity model gets less correct over time — see
[`KYBERSWAP_INTEGRATION.md`](./KYBERSWAP_INTEGRATION.md) §3.4.

No tag and no date here yet: this is recorded as **pending**, and this entry gets the tag and the
deploy date when it ships. The operator sequence, its preconditions and its post-conditions are
[`GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md`](./GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md), whose
"Who must be told" section is the other half of this entry.

### Separately pending, and NOT in this change: the dynamic fee would move the fee basis

Recorded here because it trips the first invalidation row above and nothing else was tracking it.

**It is not in this change, and it is not in this tree.** `git diff c7b9f407 --
src/markets/ProtocolFeeHook.sol` on `feature/graduate-into-launch-dollar-main` prints nothing:
the hook here is byte-identical to what 0x reviewed. `src/markets/VolatilityFeePolicy.sol` and
`src/markets/IDynamicFeePolicy.sol` do not exist on this branch. Nothing below should be read as
saying the hook shipping with the graduation change has drifted — it has not.

**The work is real, and it is queued on a separate branch.** A dynamic fee policy
(`dynamicFeeEnabled`, `feePolicy`, an effective-fee path and pre-swap transient sampling) that
did not exist at `c7b9f407` arrived with the concentrated-liquidity work and stays with it, on
`feature/dynamic-fee-hook` and `backup/grad-dollar-pre-rebase`, headed for its own pull request.
It is not described anywhere in [`0x/`](./0x/).

**It is not deployed.** The proxy `0xc9932584c5154e4F58313a2e5423522E74e540Cc` still points at
the submitted implementation `0xd4AC6b17338866E43E1922cfb563A81Ff36b425B`, and
`dynamicFeeEnabled(bytes32)` reverts on chain — verified against mainnet. So the claim under
review holds today, and a stock `V4Quoter` is still exact.

**It stops holding the moment that implementation is deployed.** A fee that varies with pool
state is a change to the fee basis, which is the first thing this section says to report. That
deployment needs its own notification and, unlike the graduation change, probably its own
package: the submitted claim is specifically that the fee is a flat 5,000 pips taken in
`afterSwap` on the unspecified leg. Whoever ships that branch owns this entry; it is not a
loose end of this one.

### Resolved 2026-09-21: both pending items shipped together, as one release

The two sections above are left as written — they say what was true when the package went
out — and this is what happened to them.

| | |
|---|---|
| Tag | `review/keeper-lp-fees-2026-09-21` |
| Monorepo | `StableLaunchpad` `staging/main`, the merge of `feature/keeper-lp-fees` into `feature/graduate-into-launch-dollar-main` plus `origin/main` |
| Upgraded on chain | 2026-09-21, Safe batch [`deployments/safe-batches/04-upgrade-implementations.json`](../deployments/safe-batches/04-upgrade-implementations.json) |
| Wiring | [`05-wire-graduation-and-keeper.json`](../deployments/safe-batches/05-wire-graduation-and-keeper.json), recorded pending in `deployments/asset-markets-mainnet-v6.json` until it executes |
| Runbook | [`GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md`](./GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md), §11 for the fee half |

**The graduation change shipped**, with one correction to the entry above: `LaunchDeployer`
*is* replaced after all. The merge with `origin/main` brought segmented launch curves onto the
same tree, so the live deployer's one-argument `initialize` no longer serves a factory built
from it — `test_live_upgradingTheLaunchFactoryWithoutItsDeployerBreaksEveryNewLaunch` now pins
the opposite of what its predecessor pinned. `0x50571945e7CdBa099745A20Deb762deB81f81331` is
the new deployer; it is launchpad-only and neither team was pointed at it.

**The dynamic fee shipped in a different shape than the one described above, and it does NOT
move the fee basis.** The per-swap policy (`feePolicy`, `dynamicFeeEnabled`, transient
sampling) was removed before deployment. What deployed instead, at hook implementation
`0xfe4014D1ee20cC77349fAd24C1e9CeA69b03db03` (`exact_match` on Sourcify, proxy address
unchanged), leaves the skim exactly as submitted — `afterSwap`, unspecified leg, `feePipsFor`,
1% ceiling, one-hour notice on increases — and adds a keeper-set **LP** fee: markets created
from now on may carry `PoolKey.fee = 0x800000`, and for those `ProtocolFeeHook.setPoolLpFee`
(owner or one authorised keeper) writes Uniswap's stored `slot0.lpFee` within 100–50,000
pips, both directions, no expiry, nothing per swap. `beforeSwap` still returns no override.
The claim under review therefore still holds: a stock `V4Quoter` reads `slot0.lpFee` the way
`Pool.swap` charges it, so it stays exact, and the hook's own fee is unchanged. The six live
pools are static-tier and cannot change. Full description:
[`FABLES_DYNAMIC_FEES.md`](./FABLES_DYNAMIC_FEES.md); the integrator-facing paragraphs are in
[`0x/HOOK_SPECIFICATION.md`](./0x/HOOK_SPECIFICATION.md) §beforeSwap and
[`AGGREGATOR_INTEGRATION.md`](./AGGREGATOR_INTEGRATION.md).

**Addresses that changed, and the one that did not.** Implementations: `AssetMarketFactory`
`0x77153c0482e393375f25cbdbfe47e204d22cf951`, `LaunchFactory`
`0x1fd586D714F66c120aa258ce29671634Cff556bC`, `ProtocolFeeHook` as above,
`PoolBrandTreasury` `0x317d1C9319E461658F6716382Dcf81d0C39C8A77`, `BrandFeeVault`
`0x57f700f8AbC9FB73B9Ee6e5297304421f041065D`, `LpRewardDistributor`
`0xCe9F3b9e864EDD05a64544B228c509E6Ff63fb44`; all behind the proxies and beacons already
recorded, all verified. Every address in the "as submitted" tables reads the same.

**What each team was told**, both after batch 04 landed: KyberSwap, a comment on PR #1699
pointing at the description's 2026-09-21 update and the new implementation; 0x, the same
three facts — new markets may carry `0x800000`, read the LP fee off `getSlot0`, skim
unchanged, nothing new to encode.

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
