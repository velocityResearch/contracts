# kyberswap-dex-lib — staged contribution

Go source destined for `github.com/KyberNetwork/kyberswap-dex-lib`, kept here so it is reviewable
in this repository before it becomes a pull request against theirs. **Nothing here is part of this
repository's build.** There is no `go.mod`: these files only compile inside dex-lib's module, and
`gofmt` is the only check that runs on them locally.

**This directory is the source of truth.** The PR branch (`feat/stables-robinhood` in a dex-lib
clone) carries these files byte-for-byte, plus the three registration edits that only make sense
inside their module — `pkg/valueobject/exchange.go`, `pkg/pooltypes/pooltypes.go` and the
regenerated `pkg/msgpack/register_pool_types.gen.go` — and a `hook_live_test.go` that reads the
deployed hook over RPC. Edit here, copy there. The two drifted once already, and the copy in the
branch is the one that gets reviewed.

Background, the measurements behind it, and the order to make the ask in:
`docs/KYBERSWAP_INTEGRATION.md` §3.

## What is here

| Staged at | Lands at | What it does |
|---|---|---|
| `hooks/stables/` | `pkg/liquidity-source/uniswap/v4/hooks/stables/` | A `Hook` plugin for `ProtocolFeeHook`, so Kyber prices our v4 pools from the rate the contract returns instead of one fitted from quoter probes |

## Why a hook plugin and not a new liquidity source

Kyber **already routes through Stables markets** — measured 2026-09-18, with hops coming back as
`exchange: uniswap-v4-fee`. dex-lib's Uniswap v4 source is live on Robinhood Chain against
PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, discovering our pools on its own.

What it does not have is our hook. Unregistered hook addresses fall through to
`SetFallbackHookFactory`, an auto-detection model that *fits* a fee by probing a quoter.
`ProtocolFeeHook.feePipsFor(poolId)` returns that number for free, exactly, and it can change
between blocks. Registering the plugin replaces a guess with a read.

The `cashcat` plugin in the same directory — also on Robinhood Chain — states the precedence rule
plainly in its package comment: explicit registration in `HookFactories` takes priority over the
fallback. It is also the closest template, and this plugin is deliberately shaped like it so a
reviewer can diff the two.

## The three things a reviewer should look at

1. **The rate is mutable.** `cashcat` reads its rate once and persists it, because it is immutable
   for the pool's life. Ours is owner-settable per pool, in one transaction, with no timelock, up
   to `MAX_FEE_PIPS` (50,000 = 5%). `Track` therefore re-reads unconditionally and only falls back
   to a persisted value when there is no RPC client at all.
2. **`feePipsFor`, never `feePipsOf`.** `feePipsFor` returns 0 when the pool has no fee recipient
   bound *and* while the protocol guard reports a halt — and in both cases trading continues
   normally. `feePipsOf` is the raw stored value and would over-charge every quote during a halt.
3. **Exact-output is flat, not grossed up.** The contract charges the skim on the pool's realised
   (net) input in `afterSwap`, so total input is `net + ⌊net·fee/1e6⌋` — not
   `net·fee/(1e6 − fee)`. `TestCalcIn_ChargesTheNetInputFlat` pins the difference (5,000,000
   against 5,025,125 on a 1,000-unit leg at 0.50%) so a refactor cannot quietly align this with
   the hooks that do gross up.

## The precedent to follow

`stable-stable` — hook `0x3b64660a35a09AfDe554cE545bca9166D6A23CC0`, **also on Robinhood Chain** —
was added by PR #1669, opened 2026-09-13 and merged 2026-09-16. Read that diff before opening
ours; it is the closest thing to a worked example of this exact submission. Measured turnaround on
external v4 hook PRs generally is 1–8 days.

A hook plugin is a deliberately small change: every hook shares `DexType = "uniswap-v4"` and
differs only by its `Exchange` constant, so `pkg/pooltypes` is untouched and msgpack is not
regenerated. Contrast the reserve leg (`docs/KYBERSWAP_INTEGRATION.md` §3.4), which would be a
standalone source and does need all three.

**A merged PR does not enable the source.** Which sources run on which chain is Kyber-side
deployment config in their `pool-service`, invisible from the public repo. Ask for it in the PR,
and give them the chain-4663 values they will need:

| Config | Value |
|---|---|
| `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` (already in their `constant.go`) |
| `Multicall3Address` | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| `StateViewAddress` | deploy via `script/deploy-v4-lens.sh`, then record it |
| `SubgraphAPI` | none — Robinhood has no v4 subgraph |
| `FetchTickFromStateView` | `true`, consequently |

Discovery is the one genuinely open question. Their v4 lister is subgraph-driven; with no subgraph
the route is log-based discovery off the PoolManager's `Initialize` event
(`poolfactory.RegisterFactoryC`, as `stable-stable` does) plus `FetchTickFromStateView`. That is
also what their own guidance prefers: *"Prefer discovering pools on-chain over off-chain
indexes."*

One thing to confirm rather than assume: `NewPoolSimulator` refuses a pool outright
(`shared.ErrUnsupportedHook`) when `HasSwapPermissions` is true and nothing is registered for the
hook address. Our pools quote today, so something already handles ours — see
`docs/KYBERSWAP_INTEGRATION.md` §1.1, and ask in the PR what `uniswap-v4-fee` currently does with
them.

## Applying it to a dex-lib checkout

Two edits in their tree beyond copying the directory:

1. `pkg/valueobject/exchange.go` — add the constant the plugin references:
   `ExchangeUniswapV4Stables = "uniswap-v4-stables"`, in the `ExchangeUniswapV4*` block.
2. Import the package for its registration side effect, wherever the other v4 hooks are imported.

Then, from the dex-lib root:

```
goimports -local github.com/KyberNetwork/kyberswap-dex-lib -w pkg/liquidity-source/uniswap/v4/hooks/stables
```

```
go test ./pkg/liquidity-source/uniswap/v4/hooks/stables/...
```

`go generate ./pkg/msgpack/...` is not needed: this adds no simulator type.

## Ground truth used in the tests

Read from Robinhood Chain mainnet on 2026-09-18.

| Thing | Value |
|---|---|
| `ProtocolFeeHook` | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` (UUPS proxy; permissions `0x00CC` mined into the address and permanent) |
| `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| Market 13 pool id | `0xf71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61` |
| `feePipsFor(poolId)` | `0x1388` = 5,000 pips = 0.50%, on every live pool checked |

Reproduce the last row:

```
curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0xc9932584c5154e4F58313a2e5423522E74e540Cc","data":"0xe7a39528f71c2e4fd2dee46e714a146f63235b4246e1cef46e40de59eec4dadedef95e61"},"latest"]}' https://rpc.mainnet.chain.robinhood.com
```

## Still missing before the PR

Their contribution rules want sample transactions and quote-comparison evidence — the simulator's
output against real on-chain fills. We do not have those yet, and the same measurements settle an
open question of our own: Kyber currently prices 1,000 brand units at $898 rather than $1,000, and
quotes a 29% loss on a $1,000 brand→asset route. Reconcile against `MarketLens.quoteBuy` before
opening anything. See `docs/KYBERSWAP_INTEGRATION.md` §1.1.
