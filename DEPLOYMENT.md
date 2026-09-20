# Deployment

What is deployed, how to deploy it again, and the three things about this repository that
will waste an afternoon if nobody tells you.

This is a **contracts-only checkout**. There is no `web-stable/`, no `backend/` and no
`services/`; nothing here needs them to build, test, deploy or verify. Any instruction
elsewhere that tells you to run an `npm --prefix web-stable` build or to stand up an indexer
is describing a different repository.

The ordered sequence for a fresh deployment is
[`docs/MAINNET_RUNBOOK_2026-09-16.md`](docs/MAINNET_RUNBOOK_2026-09-16.md). Changing something
already deployed is [`UPGRADING.md`](UPGRADING.md), and it is a Safe transaction, not a
`forge script --broadcast`.

## What is live

Robinhood Chain mainnet, **chainId 4663**, RPC `https://rpc.mainnet.chain.robinhood.com`,
explorer `https://robinhoodchain.blockscout.com`.

| Contract | Address |
|---|---|
| `ProtocolFeeHook` (UUPS proxy, hook flags `0x00CC`) | `0xc9932584c5154e4F58313a2e5423522E74e540Cc` |
| `AssetMarketFactory` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| `MarketRouter` | `0x7553919210B172438853C3694Fd88fAfD4bE3Eb4` |
| `MarketLens` (ownerless, stateless) | `0x0a3d8332D949b4aE650f3aC6468620e403a50fF1` |
| `SharedReservePool`, sUSDai | `0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2` |
| `SharedReservePool`, USDG/Morpho | `0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3` |
| `ProtocolGuard` | `0x013D1974F8215a12280e6b9a33F9732277F38C0e` |
| `StrategyGroupRegistry` | `0xBd02B0f3253F31dD02A752582e7b8974589333f7` |
| `BrandPsmFactory` | `0xB1e0ED28e24d3999216979847f9473b5C7bf12bA` |
| `LiquidityZapper` **V2** | `0x57FA92648c722Bb28A0d011f020685B952110a2D` |
| Owner of all of the above | Safe `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` (v1.4.1, 2-of-3) |

Venue contracts are Uniswap's own, unmodified: `PoolManager`
`0x8366a39CC670B4001A1121B8F6A443A643e40951`, `V4Quoter`
`0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F`, `StateView`
`0xa7D3DeD16C94F4FBAb1Fc24a0c6243043A67A804`.

**Live markets are ids 13 through 18.** Ids 1-12 exist on the factory and are dead
zero-liquidity leftovers from earlier deploys; filter them out rather than presenting them.

**`LiquidityZapper` V1 `0x6f67108e7716A1f00902Ed219B055633fB2FE8Fd` is ownerless, has no
slippage protection and is sandwichable. Never recommend it to anyone.** It stays verified on
Sourcify so its bytecode is readable, and it is not in the table above on purpose.

Do not pin an implementation address anywhere an integrator can read it. Implementations move;
proxies do not. `deployments/mainnet-state.json` records every ERC-1967 slot as read from
chain, and `deployments/asset-markets-mainnet-v6.json` is the address book and the reasoning
behind it. Read an address from those, never from prose — including this page.

## Building

```bash
git clone --recurse-submodules <url> && cd stables-contracts && forge build
```

Compiler `v0.8.26+commit.8a97fa7a`, optimizer enabled, 200 runs, `via_ir = true`. A cold build
is slow because of `viaIR`. Dependencies are pinned git submodules, so `forge install` has
nothing to resolve; if the clone missed them, `git submodule update --init --recursive`.

No contract exceeds the 24,576-byte EIP-170 limit, so mainnet deploys need no special flags.
`AssetMarketFactory` used to, at ~26.7KB, which forced `--code-size-limit 32768` on every
script that deployed it; moving `MarketYieldSplitter`'s creation code behind `SplitterDeployer`
brought it back under. Re-measure rather than assume:

```bash
forge build --sizes --offline
```

If a contract ever goes over again, `code_size_limit` in `foundry.toml` does **not** rescue it.
`forge` runs a separate size check between simulation and broadcast that reads only the CLI
flag, so an oversized deploy simulates cleanly, prints its addresses, and then refuses to
broadcast.

## There is no `[etherscan]` block in `foundry.toml`, and that is load-bearing

It used to carry a Blockscout entry
`robinhood = { key = "${ROBINHOOD_EXPLORER_API_KEY}", chain = 4663, url = ... }`.

foundry 1.5.1-stable rejects an `[etherscan]` entry whose `chain` is not in its built-in chain
registry, and it does so **while loading the config**. So the failure was not confined to
`--verify`: every `forge script` against chain 4663 died with `Error: Chain 4663 not supported`
before running a line, whatever `--rpc-url`, `--chain` or `--skip-simulation` was passed.
Removing the block is what makes a mainnet script runnable at all.

Nothing was lost, because verification never went through that instance anyway (see below). If
you ever want to try explorer verification, pass it per invocation
(`--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api`) rather than
restoring a config key that breaks config load for every other command.

Do not add it back. `foundry.toml` carries the same warning at the bottom of the file.

## Verification goes through Sourcify, by standard-JSON input

```bash
./script/verify-mainnet-sourcify.sh            # verify everything still unverified
./script/verify-mainnet-sourcify.sh --status   # report only, submit nothing
```

Idempotent, resumable, signs nothing and spends no gas: every target is checked first and
skipped if already verified, so re-running after a partial run is free. Safe to run unattended.

**Blockscout is not the route.** The Blockscout instance for chain 4663 puts its API behind a
Cloudflare interactive JS challenge. `forge verify-contract --verifier blockscout` receives an
HTML "Just a moment..." page instead of JSON and dies deserialising it, and no API key changes
that, because it is a bot challenge and not an auth failure. Driving it from a real browser
does clear the challenge, and the API then rate-limits hard enough that a batch of this size
takes hours.

Sourcify supports 4663 natively, has no challenge and no meaningful rate limit, and **Blockscout
consumes Sourcify verifications** — so publishing to Sourcify is what makes source readable at
`https://robinhoodchain.blockscout.com/address/<address>?tab=contract`.

Two properties of Sourcify matter here:

- It matches on compiled bytecode plus embedded metadata, so **no constructor arguments are
  needed**. Half of these contracts take constructor arguments that would otherwise have to be
  recovered from broadcast artifacts by hand.
- It must be given **standard-JSON input, never a flattened source**. A flattened file will not
  reproduce the bytecode, because the build uses `viaIR`.

The live contracts came back `exact_match` on both creation and runtime bytecode.

The script verifies **implementations, not proxies**. A proxy's own source is OpenZeppelin's
`ERC1967Proxy` and carries no protocol logic, and Blockscout links a proxy to its verified
implementation by itself once the implementation is published.

## `forge` hangs on mainnet scripts unless Sourcify is short-circuited

A mainnet trace contains `PoolManager`, `PositionManager` and Permit2, none of which are in
local artifacts, so `forge` tries to label them through sourcify.dev and that request never
returns. It looks exactly like a chain problem and is not. `--disable-labels` does not stop it.
What works:

```bash
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
```

Needed for `script/DeployAssetMarkets.s.sol` and `script/DeploySharedReservePool.s.sol`. Not
needed for `PreflightMainnet.s.sol`, `VerifyAssetMarketsMainnet.s.sol`, or the Sourcify
verifier, none of which produce a trace over unknown contracts.

Related: **do not run a standalone no-`--broadcast` simulation of the market-layer step.**
`--broadcast` already simulates the entire script including the post-deploy wiring and venue
assertions, and sends nothing if any of it fails. A bare `forge script` is redundant and hangs
the same way.

## Rehearsing

```bash
script/rehearse-mainnet.sh
```

Forks 4663 locally and runs the entire deployment — reserve, market stack, launchpad — followed
by a real market creation, a reserve mint, and a seeded Uniswap v4 position, using the same
scripts and the same runbook commands a real deployment uses. It asserts the properties no unit
test reaches: that the hook's mined address really carries permission bits `0xcc`, that the
`MarketDeployer` library linked, and that `setLaunchpad` landed.

It redirects `FOUNDRY_BROADCAST` to a temp directory, because `broadcast/<script>/4663/` is the
record of the **real** mainnet deployment and a rehearsal would otherwise overwrite
`run-latest.json` with addresses that only ever existed locally. Do not remove that redirect.

For a bare fork with no deployment, `script/anvil-fork.sh`.

## Preflight

```bash
forge script script/PreflightMainnet.s.sol --rpc-url robinhood
```

Read-only, no key needed. It asserts every hardcoded external integration address against the
live chain, including that the `PositionManager` reports the same `PoolManager` singleton every
market will be created in.

## Testnet

Robinhood testnet is chain **46630**, RPC `https://rpc.testnet.chain.robinhood.com`. The testnet
stack is the same gen-6 shape as mainnet and is documented in
[`docs/ASSET_MARKETS_TESTNET.md`](docs/ASSET_MARKETS_TESTNET.md); its deploy script reads a
public `DEPLOYER` address and no private key, and is signed with `--account` against an
encrypted keystore. Earlier testnet deployments are abandoned in place rather than migrated;
`deployments/asset-markets-testnet.json` records which stack is current.
