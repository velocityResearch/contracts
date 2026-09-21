# Mainnet launch runbook — fresh stack

Companion to `docs/MAINNET_READINESS_2026-09-16.md`. That document says *why*; this one is
the ordered sequence. Every step is either **[you]** (funds, keys, broadcasts) or **[done]**
(prepared and rehearsed already).

The whole thing has been rehearsed end to end against a Robinhood mainnet fork with
`script/rehearse-mainnet.sh` — including the launchpad. Re-run it before you start if
anything in `src/` has changed since.

---

## Correction to an earlier claim

An earlier revision of the readiness doc said ~$356 of the $362 in the gen-4 reserve
belonged to third parties. **That was wrong.** I inferred it from `balanceOf(deployer)`
being small without checking where the rest sat. It sits in the Uniswap v4 `PoolManager`
as your own pool liquidity:

| Brand | Supply | Your wallet | In the v4 pool |
|---|---|---|---|
| ZZZUSD | 127.068752 | 3.116618 | 123.952134 |
| AIUSD | 128.255150 | 1.529836 | 126.670878 |
| BONEUSD | 101.278886 | 1.500000 | 99.778886 |

You hold **5 LP NFTs** on the v4 PositionManager `0x58daec…4fA7`, and gen-4's `Market`
struct has no `lpDistributor` — it predates LP rewards — so the seeder holds the position
directly. `test_theSeederCanWithdrawThroughPositionManagerWithoutTheRouter` covers exactly
this: you exit through Uniswap's PositionManager without the router, the factory, or anyone's
permission. **There is nobody to announce a window to.**

---

## 0. [you] Fund both chains

| Chain | Now | Suggested |
|---|---|---|
| Robinhood 4663 | 0.01165 ETH | **0.05 ETH** |
| Arbitrum One | 0.000000 ETH | **0.01 ETH** |

Reference: gen-4's stack cost 0.005227 ETH / 36 txs measured. The launchpad added ~54M gas
on Base Sepolia, so budget 0.005–0.016 ETH at Robinhood's 0.099–0.304 gwei. The ownership
handover is 0.000032 ETH. Headroom is cheap; a half-finished deploy is not.

## 1. [you] Hand gen-4's three proxies to the timelock

Do this first. It is live exposure, it is independent of the fresh stack, and it costs
0.000032 ETH. Prepared and simulated against mainnet in
`script/HandOverMainnetOwnership.s.sol`.

```
PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'nominateAndSchedule()' --rpc-url robinhood --broadcast --slow
```

Wait 48 h, then:

```
PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'executeHandover()' --rpc-url robinhood --broadcast --slow
```

Check progress any time, no key needed:

```
forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'status()' --rpc-url robinhood
```

Ownership does not move until run 2. If you never run it, the nomination expires into
nothing and you are still the owner.

**Why bother, if gen-4 is being retired?** Because it holds your money for the 48 h plus
however long the unwind takes, and because whoever finds the key does not care that you
planned to abandon it. Cheap insurance on a live contract.

## 2. [you] Unwind gen-4

Nothing here needs the protocol's cooperation.

1. Decrease liquidity to zero on your 5 LP NFTs through the v4 PositionManager
   `0x58daec3116aae6D93017bAAea7749052E8a04fA7`. Returns brand tokens plus the paired
   assets.
2. Redeem each brand 1:1 into USDG on the gen-4 reserve
   `0x076e361b535B236471BEA7f444D5E70971172338`:
   `redeem(address token, uint256 amount, address receiver, uint256 minAssetsOut)`.
   Redemption carries no `whenNotPaused` by design, so this works regardless of protocol
   state.
3. Leave gen-4 on chain, unused. Gen-1 was retired the same way and the manifest records it.

Total at stake: ~$362. Sanity-check `totalPooledSupply()` trends to 0 as you go.

## 3. [you] Preflight

```
forge script script/PreflightMainnet.s.sol --rpc-url robinhood
```

Read-only, no key. I verified all four external integration addresses live, so expect a
pass: sUSDai reports `sUSDai`, the Curve pool reports `N_COINS = 2`, and both Across
SpokePools report `depositQuoteTimeBuffer() = 3600`.

## 4. [you] Deploy the fresh reserve

`forge` hangs on mainnet scripts unless Sourcify is short-circuited — it tries to label
PoolManager/PositionManager/Permit2 through sourcify.dev and that request never returns.
It looks exactly like a chain problem and is not. Prefix the next two steps:

```
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
```

```
PRIVATE_KEY=0x... TIMELOCK_MIN_DELAY=172800 forge script script/DeploySharedReservePool.s.sol --rpc-url robinhood --broadcast --slow
```

Record `SharedReservePool`, `TimelockController` and `ProtocolGuard` from the output.

## 5. [you] Deploy the market stack and the launchpad, in one run

```
PRIVATE_KEY=0x... SHARED_RESERVE_POOL=0x<step4> DEPLOY_LAUNCHPAD=true forge script script/DeployAssetMarkets.s.sol --rpc-url robinhood --broadcast --slow
```

`DEPLOY_LAUNCHPAD=true` is what makes this a launchpad-capable stack; the flag calls
`ProtocolStack.deployLaunchpad` inline and then makes the one owner call that crosses into
the market factory, `setLaunchpad`. The rehearsal asserts both landed.

Do **not** run a separate no-`--broadcast` simulation first: `--broadcast` simulates the
whole script including the post-deploy wiring and venue assertions, sends nothing if any of
it fails, and a standalone simulation hangs the same way step 4 does.

Record: `ProtocolFeeHook`, `AssetMarketFactory`, `MarketRouter`, `MarketDeployer (library)`,
`LaunchFeeEscrow`, `LaunchFactory (proxy)`, `LaunchGraduationGuard`, `LaunchLocker`,
`LaunchDeployer`, `LaunchGraduation`, `LaunchRouter`, and the launch config id.

## 6. [you] Verify

```
SHARED_RESERVE_POOL=0x... ASSET_MARKET_FACTORY=0x... MARKET_ROUTER=0x... forge script script/VerifyAssetMarketsMainnet.s.sol --rpc-url robinhood
```

Then the two properties the rehearsal checks and nothing else re-checks:

```
cast call <assetMarketFactory> 'launchpad()(address)'        --rpc-url robinhood   # == LaunchGraduation
cast call <assetMarketFactory> 'positionManager()(address)'  --rpc-url robinhood   # == 0x58daec…4fA7
```

## 7. [you] Hand the NEW proxies to the timelock

**Do not repeat gen-4's mistake.** The fresh factory, router and hook will be owned by the
deploying key exactly as gen-4's were. Update the three address constants at the top of
`script/HandOverMainnetOwnership.s.sol`, bump `SALT_VERSION` to `2` so it schedules a fresh
operation, and run the same two-step flow from §1.

Tell me the new addresses and I will make that edit.

## 8. [you] The sUSDai pair — Arbitrum first

Step 1, on Arbitrum One:

```
PRIVATE_KEY=0x... forge script script/DeploySUSDaiHub.s.sol --rpc-url arbitrum --broadcast --slow
```

Record `SUSDAI_HUB`. Step 2, back on Robinhood:

```
PRIVATE_KEY=0x... SUSDAI_HUB=0x<step1> SHARED_RESERVE_POOL=0x<step4> forge script script/DeploySUSDaiGroup.s.sol --rpc-url robinhood --broadcast --slow
```

The order is forced: the group's adapter takes the hub's address as a constructor argument,
and the hub is on the other chain.

## 9. [you] Prove one Across round trip before letting float accumulate

Stand up `services/susdai-keeper/` against the mainnet pair and run one controlled cycle —
`bridgeOut`, `buyShares`, `sync`, then `sellShares`, `bridgeHome`, `sync` — at a size you are
willing to lose to a bridge timeout. The Base Sepolia rehearsal did exactly this and is
recorded in `deployments/asset-markets-base-sepolia.json`; its final accounting showed
0.993023 USDC against 1.000000 branded supply with the difference booked to
`lossCarryforward`, which is the shape a healthy cycle has.

Do not skip to funding the reserve. A keeper that cannot complete a round trip is a reserve
that cannot honour a redemption at par.

## 10. [you] Frontend

1. Set `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` in the production environment. The redesigned
   app throws on boot without it.
2. Add the chain-4663 entry in `deployments/app-networks.json`: replace the gen-4 `factory`,
   `router`, `reservePool` and `zapper` with the step-5 addresses, and add the `launchpad`
   block with `factory`, `router`, `feeEscrow`, `locker`.
3. `npm --prefix web-stable run build`, then deploy.

Tell me the addresses and I will make that edit and re-run the frontend checks.

---

## What is already done

| | |
|---|---|
| Launchpad audit | 4 scouts, no Critical/High |
| Offline tests | 549 pass |
| Launchpad fork tests | 16 pass against Robinhood |
| `MainnetLaunchFork` | 7/7 (was 6/7; both manifest blockers resolved) |
| Frontend | typecheck, lint, build, 531 tests pass |
| Base Sepolia | deployed, launch + buy smoke-tested live |
| Full mainnet deploy | rehearsed on a fork, launchpad included |
| Ownership handover | script written, simulated on mainnet |

## Still open, not blocking

- `docs/ASSET_MARKETS_MAINNET.md` documents gen-1 throughout — wrong flow, wrong gas table,
  wrong timelock address. I can rewrite it; say the word.
- Blockscout verification is untested; it sits behind Cloudflare. Treat `--verify` as
  something to try, not a step the runbook promises.
- Regulatory counsel on "float interest funds LP rewards" has not been obtained.
- The same EOA remains sole timelock proposer, guardian and protocol treasury. The timelock
  stops instant upgrades; it does not split those roles. Moving the guardian to a second key
  is worth doing and is not something I can do for you.
- The Robinhood public RPC rate-limits a full fork suite (429s). Use a paid endpoint for CI.
