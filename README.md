# Stables contracts

Solidity for the Stables protocol (**stables.fast**) on Robinhood Chain mainnet
(`chainId 4663`): tokenized-equity and launchpad markets built on Uniswap v4, a 1:1 pooled
reserve behind them, and the launchpad that graduates a bonding curve into a market.

This repository is contracts and tests only. The web application, the indexer and the operational
tooling live elsewhere and are not needed to build, test or audit anything here.

## Integrators start here

If you are an aggregator or router, read [`docs/AGGREGATOR_INTEGRATION.md`](docs/AGGREGATOR_INTEGRATION.md)
first. It is venue-neutral and covers quoting and settlement on one page.

| Audience | Start at |
|---|---|
| 0x | [`docs/0x/README.md`](docs/0x/README.md) |
| KyberSwap | [`docs/KYBERSWAP_INTEGRATION.md`](docs/KYBERSWAP_INTEGRATION.md) and [`integrations/kyberswap-dex-lib/`](integrations/kyberswap-dex-lib/) |
| Security reviewer | [`docs/0x/SECURITY_AND_GOVERNANCE.md`](docs/0x/SECURITY_AND_GOVERNANCE.md), then [`docs/audit-history.md`](docs/audit-history.md) |

**Under review.** This tree was submitted to 0x and KyberSwap on 2026-09-20 at tag
`review/0x-kyberswap-2026-09-20`. When answering either team, diff against that tag rather
than `main`, so the answer describes what they were actually shown. See
[`docs/SUBMISSIONS.md`](docs/SUBMISSIONS.md).

The single most important integration fact: **the protocol fee is taken in `afterSwap`, on the
swap's unspecified leg, as a hook return delta.** It is therefore already inside the
`BalanceDelta` that `PoolManager.swap` returns, so a stock `V4Quoter` is exact and you must not
subtract the fee yourself. Measured wei-exact against an unmodified `V4Quoter` on all six live
pools; see [`docs/0x/SETTLER_COMPATIBILITY.md`](docs/0x/SETTLER_COMPATIBILITY.md) section 6.

## Layout

| Path | What is in it |
|---|---|
| `src/markets/` | Asset-market factory, router, the `ProtocolFeeHook`, per-market vault and reward distributor, `MarketLens` |
| `src/pool/` | The pooled 1:1 reserve, brand tokens, treasuries, and the `BrandPsm` window |
| `src/launchpad/` | Bonding-curve launch stack and graduation |
| `src/yield/` | Reserve yield adapters |
| `src/susdai/` | Arbitrum hub and its bridger |
| `src/upgrade/` | Pause guard and proxy scaffolding |
| `src/registry/` | Strategy-group discovery |
| `src/testnet/` | Fixtures that cannot deploy to mainnet (see the note below) |
| `test/` | Foundry tests; `test/audit/` holds security regressions |
| `script/` | Deployment and operations scripts |
| `deployments/` | Address manifests. `asset-markets-mainnet-v6.json` is the authority for live addresses |
| `broadcast/` | Transaction records for mainnet 4663 only |
| `integrations/` | The KyberSwap `dex-lib` hook adapter |

`src/testnet/SUSDaiTestnetMocks.sol` is the one mock in a deploy path, and it is deliberately the
opposite of a production dependency: every contract in it inherits `TestnetOnly`, whose
constructor requires chainid 46630, 421614 or 31337, so construction reverts on mainnet 4663. A
new fixture added there without `TestnetOnly` would silently become mainnet-deployable, which is
the invariant to protect.

## Build and test

Dependencies are pinned git submodules, so a bare `forge install` has nothing to resolve.

```
git clone --recurse-submodules <url> && cd stables-contracts
```

Already cloned without submodules:

```
git submodule update --init --recursive
```

Then:

| Command | What it does |
|---|---|
| `forge build` | Compiles. `via_ir = true`, so a cold build takes a while |
| `forge test --no-match-path 'test/*Fork*'` | Everything that works offline |
| `forge test -v --fork-url https://rpc.mainnet.chain.robinhood.com` | Includes the fork suite |
| `forge test --match-contract SharedReservePool -vv` | One area |
| `forge fmt --check` | Formatting |

Fork tests are rate-limit sensitive; add `--threads 1` if the RPC starts returning 429.

## Verification

Compiler `v0.8.26+commit.8a97fa7a`, optimizer enabled with 200 runs, `via_ir = true`.

Verified on **Sourcify**, by standard-JSON input. A flattened source will not reproduce the
bytecode because the build uses `viaIR`. Blockscout's verification API on this chain sits behind
a Cloudflare challenge, which is why Sourcify is the canonical route.

## Conventions

Four-space indentation, double quotes, 100-character lines, all configured in `foundry.toml`.
Tests follow the existing `test_*` and `testFuzz_*` naming; fuzzing defaults to 256 runs.
Add a Foundry regression test for any behavioral change.
