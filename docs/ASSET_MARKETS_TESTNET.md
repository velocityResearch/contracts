# AssetMarkets on Robinhood Chain testnet

What `script/DeployAssetMarketsTestnet.s.sol` builds, how to run it, and what to exercise once
it is up. Everything below was read out of the script and the contracts it calls on 2026-09-19.

This document was rewritten from a runbook that described a Uniswap v3 fixture built from
pinned npm artifacts, with a per-market buyback and lockbox and a two-step brand/market flow.
None of that exists any more. The testnet stack is the same gen-6 shape as mainnet.

## What the script deploys, and what it deliberately does not

The script is chain-gated to 46630 or a local 31337 and refuses to run anywhere else
(`script/DeployAssetMarketsTestnet.s.sol:64`). It reads one environment variable, `DEPLOYER`,
a public address (`:65-66`). **No private key environment variable is read.** Sign with
`--account` against an encrypted keystore.

| Component | What it is |
| --- | --- |
| Uniswap v4 `PoolManager` | **The chain's own singleton, not a copy.** Same address on 4663 and 46630, which is what a deterministic deployment looks like, so testnet trades in the venue mainnet trades in (`:46-48`). The script asserts it has code before using it (`:79`) |
| `ProtocolFeeHook` | Deployed behind an `ERC1967Proxy` at a **mined** address: v4 reads a hook's permissions from the low 14 bits of its address, and the salt is bound to those exact constructor arguments, so mining and deploying happen in one run (`:81-95`). The script asserts the proxy landed on the mined address (`:106`) |
| `ProtocolGuard`, the four beacons, `SharedReservePool`, `AssetMarketFactory`, `MarketRouter` | Built through `src/upgrade/ProtocolStack.sol`, the same library the mainnet script uses (`:87-148`) |
| Faucet `tUSDG` (6 dp) and `tASSET` (18 dp) | Unrestricted public ERC20s with no monetary value and no equity provenance. Their constructor is itself gated to 46630 or 31337 (`:177`). Deployed first and in this order, because the tests and the seeding script address them by the deployer's nonce (`:70-73`) |
| `AssetMarketTestYieldSource` | Per-consumer balances with a transfer-backed `simulateYield` (`:190-223`). **Not Morpho.** It cannot validate lending utilisation, interest accrual or withdrawal availability; those need mainnet fork tests |

Three things are deliberately absent.

**No timelock.** The guard, the beacons, the reserve, the factory and the router all answer to
the deploying address (`:84-87`). The stack exists to be torn down and rebuilt, and a two-day
delay on every fix would defeat that. This is not a production governance configuration.

**No approved asset, so no market can exist yet.** An approval fixes the price a pool opens at,
and that belongs to whoever is launching, not to a fixture (`:117-118`). Creating a market is
therefore a separate, deliberate step.

**No equity verification.** The reference equity is `address(0)`, which disables canonicality
checking, because there is no Robinhood equity on a test chain and a zero codehash must never
read as a match (`:114-115`). Faucet assets must appear unverified in any UI.

Two numbers are stamped into every market created here, and they are the mainnet defaults
rather than a shortened test schedule: `rewardsDuration` 7 days and `minObservationCardinality`
62 slots (`:57-61`). The protocol's share of float yield is zero, so the whole of it goes to the
market's liquidity providers (`:112-113`).

## Deploy

No npm install, no `UNISWAP_NODE_MODULES`, no Foundry profile and no filesystem permissions.
An earlier revision needed all four to read pinned Uniswap V3 artifacts off disk; the script
uses the chain's v4 deployment instead and needs none of it (`:38-41`).

Dry run first, with a placeholder address that can never be a signer:

```sh
DEPLOYER=<fresh-funded-testnet-public-address> forge script script/DeployAssetMarketsTestnet.s.sol:DeployAssetMarketsTestnet --rpc-url https://rpc.testnet.chain.robinhood.com
```

`AssetMarketFactory`'s runtime is 24,229 bytes against the EIP-170 limit of 24,576, so it fits
without `--code-size-limit`. Re-measure before assuming that still holds: the margin is 347
bytes.

Then broadcast with an encrypted signer:

```sh
DEPLOYER=<same-address> forge script script/DeployAssetMarketsTestnet.s.sol:DeployAssetMarketsTestnet --rpc-url https://rpc.testnet.chain.robinhood.com --account <encrypted-testnet-account> --broadcast --slow
```

Never use an Anvil key on a public network. Do not pass a secret key on the command line and do
not commit one. `broadcast/.../dry-run/` is not a deployment record: verify every receipt and
the deployed runtime bytecode before copying an address anywhere.

The script re-checks its own work before returning: that the `MarketDeployer` library linked,
that the hook's registrar is the factory, and that the router's `PoolManager` and
`PositionManager` are the ones it was given (`:154-157`). A missing registrar link is worth
understanding rather than just asserting: `ProtocolFeeHook.registerPool` is registrar-only, so
without `setRegistrar` every `createMarket` reverts, and the two contracts each need the other's
address so it cannot be a constructor argument (`:134-136`).

## Seed and exercise

`script/SeedAssetMarketsTestnet.s.sol` does the first market end to end and is the shortest
description of the current flow: `approveAsset` as owner (`script/SeedAssetMarketsTestnet.s.sol:73`),
then permissionless `createMarket(asset, address(0))` (`:86`), then
`router.seedLiquidity(...)` (`:117`), which mints a Uniswap v4 `PositionManager` NFT to the
caller and logs its token id (`:122`). It is chain-gated the same way (`:33`).

Market creation is **one call**, not the two-step `registerBrand` then `openMarket` an older
revision of this document described. `approveAsset` carries the fee tier, the opening price and
the unit's name and symbol, so a creator chooses nothing about a market's economics.

Worth exercising by hand after that, in this order:

1. **Trade both directions.** `buyWithUsdg` with a quote-derived nonzero `minAssetOut`, then
   `sellForBrand` with a nonzero `minBrandOut`. Every router entry point takes a short
   Unix-seconds deadline and reverts `DeadlineExpired`; include a deliberately expired one as a
   negative case and never use an unbounded deadline.
2. **Par operations on the reserve.** Mint a brand with an exact USDG approval, then `redeem`
   and `swap`, neither of which needs an approval because both burn from `msg.sender`. Compare
   exact 1:1 balance deltas and check that pooled supply and backing stay in step.
3. **Cross-brand buys.** `buyWithBrand` accepts any brand registered to the market's reserve
   and crosses it 1:1 into the market's own brand before the pool leg. Another reserve's brand
   must revert.
4. **Yield.** `reserve.deployIdle()`, then approve tUSDG to the yield source and call
   `simulateYield(tUSDG, reserve, amount)` to transfer and credit simulated yield
   (`script/DeployAssetMarketsTestnet.s.sol:219`).
5. **The payout path.** `BrandFeeVault.sweep()` is permissionless and reverts below `minSweep`,
   one whole unit of the reserve asset (`src/markets/BrandFeeVault.sol:132`). It pays the
   protocol its share and transfers the rest to the market's `LpRewardDistributor`, calling
   `notifyReward` (`src/markets/BrandFeeVault.sol:253`, `src/markets/LpRewardDistributor.sol:435`).
   **There is no buyback and no lockbox**, and nothing is donated to the pool.
6. **Staking, because that is now how an LP earns the float.** Approve the position NFT to the
   distributor and `stake(tokenId, beneficiary)` (`src/markets/LpRewardDistributor.sol:296`).
   Only a full-range position is accepted: anything narrower reverts `NotFullRange` (`:308-310`).
   Then `claim(brandOut)` (`:403`), and `unstake` (`:343`), which is deliberately never pausable.
   Rewards notified while nothing is staked go to an `undistributed` counter and are folded into
   the next notify rather than handed to the first staker in one block (`:148`, `:435-444`).

## What the offline suite already covers

`test/markets/AssetMarketsTestnet.t.sol` drives the deploy script and then uses what it built,
so a script that compiles but produces an unusable stack fails there. It runs unconditionally:
locally it places a real `PoolManager` plus narrow periphery stand-ins at the production
addresses, and under `--fork-url https://rpc.testnet.chain.robinhood.com` it leaves those
addresses alone and exercises the chain's real v4 singleton, `PositionManager` and Permit2
(`test/markets/AssetMarketsTestnet.t.sol:19-31`, `:41-43`).

```sh
forge test --match-contract AssetMarketsTestnetTest -vv
```

A passing fork test is contract evidence, not browser acceptance, and simulated yield is not
evidence of a live Morpho integration.

## Signing, and what is not in this repository

The deploy and seed scripts read a public `DEPLOYER` address and never a private key, so the
signer is supplied by `--account` against an encrypted keystore and nothing secret is ever on
a command line or in the tree.

There used to be a local Chrome QA wallet bridge here, `script/asset-markets-qa-wallet.mjs`
plus its `node --test` suite, which brokered signing for a browser QA session against a
Next.js instance on port 3002. Both files imported from the web application and did not
survive the extraction of this contracts-only tree, and the application they served is not in
this repository either. Nothing in `src/`, `test/` or `script/` depends on them, and the
deployed application never had a key or signing-server dependency. If you find a reference to
`node script/asset-markets-qa-wallet.mjs` anywhere, it is stale.

For contract-level exercise, drive the flows above with `cast` against the testnet RPC, or run
the offline and fork suite described in the previous section. Neither needs a browser.

## Network

Robinhood testnet is chain **46630**, RPC `https://rpc.testnet.chain.robinhood.com`, explorer
`https://explorer.testnet.chain.robinhood.com`, faucet
<https://faucet.testnet.chain.robinhood.com>.

Earlier deployments on this chain are abandoned in place rather than migrated: testnet state is
disposable by design, and `deployments/asset-markets-testnet.json` records which stack is
current and what each superseded one was.
