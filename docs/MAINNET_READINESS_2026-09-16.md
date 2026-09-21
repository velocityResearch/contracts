# Mainnet readiness, 2026-09-16 (historical snapshot)

**This is a dated snapshot, not a live checklist.** It was written on 2026-09-16 against the
gen-4 stack, and the deployment it recommends happened on 2026-09-17. Read it for the reasoning
that produced gen-6, and read `deployments/asset-markets-mainnet-v6.json` plus
`deployments/mainnet-state.json` for what is actually deployed. Every address, balance, market
count and owner below belongs to gen-4 and is stale by construction; the generated state file
is the only place those are current, and `deployments/README.md` explains the split.

Four things in it went a different way than planned and are worth stating plainly, because
reading the ordered path below as instructions would be wrong:

- **There is no timelock.** Steps 1 and 9 of the ordered path were not taken. Gen-6 was
  deployed with `TIMELOCK_MIN_DELAY=0`, which is a documented branch of
  `script/DeploySharedReservePool.s.sol` that deploys no `TimelockController` at all
  (`script/DeploySharedReservePool.s.sol:72-79`, `:93`). One key is the owner, the guardian and
  the protocol treasury, and every `_authorizeUpgrade` in the stack is a bare `onlyOwner`, so an
  upgrade lands in one transaction. The manifest records this as a deliberate open item, not an
  oversight, and as a launch blocker for third-party deposits. `docs/audit-history.md` carries it
  as A3-CRITICAL-1.
- **`script/HandOverMainnetOwnership.s.sol` is not the path to that fix.** It is hardcoded to the
  gen-5 proxies and to the gen-5 timelock (`script/HandOverMainnetOwnership.s.sol:104-123`), both
  of which the v6 manifest records as abandoned. Running it as written moves nothing that is in
  use. It needs retargeting and a `SALT_VERSION` bump first.
- **Gen-4 has been unwound.** All five deployer LP positions were burned to zero liquidity and
  the deployer's brands were redeemed 1:1. What is left in the gen-4 reserve backs brand tokens
  held by third parties, and it stays redeemable because `SharedReservePool._redeem` carries no
  `whenNotPaused` by design. The per-position and per-brand figures are under the `gen4` key of
  `deployments/mainnet-state.json`; the dollar amounts quoted below were true on 2026-09-16 and
  are not true now.
- **The doc defect item at the end of this file is closed.** `docs/ASSET_MARKETS_MAINNET.md` has
  been rewritten and no longer describes gen-1.

---

Everything below was read off the live chains on 2026-09-16, not from a manifest.
`deployments/asset-markets-mainnet-v4.json` was stale on the two facts that mattered most at the
time: it claimed `marketCount() == 0` and "nothing is exposed yet". Both were false by then.

## Status at a glance, as at 2026-09-16

The State column is the 2026-09-16 state. Item 1 is still open and is now wider, item 6 is
closed, and items 2 to 4 were overtaken by the 2026-09-17 deployment.

| # | Item | Owner | State on 2026-09-16 |
|---|---|---|---|
| 1 | CRITICAL-1: three proxies owned by a hot key | me → you to run | **Script ready and simulated** |
| 2 | Mainnet factory cannot host the launchpad | decision → you | **Analysed: fresh stack required** |
| 3 | Arbitrum deployer has 0 ETH | you | Funding |
| 4 | Robinhood deployer funding thin | you | Funding |
| 5 | `buybackBurnBps` has no ceiling | — | **Moot — not in deployed code** |
| 6 | `docs/ASSET_MARKETS_MAINNET.md` describes gen-1 | me | Pending rewrite |
| 7 | Blockscout verification untested | you | Unknown |
| 8 | Regulatory counsel on yield→LP shape | you | Not obtained |

Two of the manifest's original blockers are **already resolved** (see §Resolved).

---

## 1. CRITICAL-1 — a hot key can rewrite the protocol, and the cheap window closed

Verified live on chain 4663:

| Proxy | `owner()` |
|---|---|
| `AssetMarketFactory` `0xbE2f…a5E7` | `0xeA6A…12A9` (deployer EOA) |
| `MarketRouter` `0xcCDe…73ce` | `0xeA6A…12A9` (deployer EOA) |
| `ProtocolFeeHook` `0x082c…C0CC` | `0xeA6A…12A9` (deployer EOA) |
| Timelock that owns everything else | `0x5f43…872a` (48 h) |

That key can `upgradeToAndCall` all three instantly. The manifest argued this was tolerable
because no market existed and the reserve was empty — "that is the window to fix it in".
The window is gone:

- `marketCount()` = **11**
- `reservePool.totalAssets()` = **362212925** = **$362.21 real USDG**
- `totalPooledSupply()` = **362007234**, of which the deployer holds only ~**$6.15**

So **~$356 belongs to third parties**, behind a single key with no delay, on the contracts
every issuance and trade routes through. Live brands include `ZZZUSD` ($127.07),
`AIUSD` ($128.26), `BONEUSD` ($101.28) and `LGA` ($0.50).

### What I built

`script/HandOverMainnetOwnership.s.sol`. All three proxies are `Ownable2Step`, so a transfer
only nominates — the new owner must accept, and the timelock can only act through a
scheduled operation. Hence two runs 48 h apart:

```
PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'nominateAndSchedule()' --rpc-url robinhood --broadcast --slow
# ...48 hours...
PRIVATE_KEY=0x... forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'executeHandover()' --rpc-url robinhood --broadcast --slow
```

Read-only status at any point:

```
forge script script/HandOverMainnetOwnership.s.sol:HandOverMainnetOwnership --sig 'status()' --rpc-url robinhood
```

- **Simulated against mainnet: passes.** 4 transactions, 321,453 gas, **0.000032 ETH**.
- The three `acceptOwnership` calls are scheduled as **one batch**, so either all three move
  or none do — no window where the protocol is split across two owners.
- The salt is derived from the purpose, so run 2 reproduces run 1's operation id without
  carrying state between them. Bump `SALT_VERSION` only if a cancellation forces a reschedule.
- Both entry points re-check every precondition on chain, so a re-run diagnoses rather than
  compounds a partial application.
- **Ownership does not move until run 2.** If run 2 never happens, the nomination expires into
  nothing and the EOA is still owner.

**This is safe to do before anything else and independent of the rest.** I have not
broadcast it — that is your call.

### What it does not fix

The same EOA remains the sole timelock proposer, the guardian, and the protocol treasury.
The timelock stops instant upgrades; it does not split those three roles. Moving the
guardian to a second key is a separate decision, and the manifest already recommends it.

---

## 2. The launchpad cannot go on the existing mainnet factory — fresh stack required

Both selectors revert on `0xbE2f…a5E7`:

```
positionManager()  -> reverted
launchpad()        -> reverted
```

`DeployLaunchpad.s.sol:_readEnv` reads `marketFactory.positionManager()`, so it fails before
broadcasting anything.

### An in-place upgrade is not available

I first assumed this was one inserted slot and could be fixed by moving `positionManager`
into the trailing `__gap`. **It cannot.** Comparing state variables at the deployed commit
`53f80f5` against `HEAD`, the layout diverges in eight places, not one:

| Slot | Deployed (`53f80f5`) | Current (`HEAD`) |
|---|---|---|
| 3 | `beacons.vault` | **`positionManager`** ← inserted |
| 4–5 | `beacons.distributor`, `equityCodehash` | `beacons` (shifted) |
| 8/9 packed | `protocolTreasury`+`protocolBps`+**`lpBps`**+`protocolFeePips` | same minus `lpBps`, plus **`rewardsDuration`**, **`minObservationCardinality`** |
| — | — | **`_listings`**, **`listedAssets`**, **`_everListed`** inserted before `_markets` |
| — | **`_marketsOfBrand`** | removed |
| — | — | **`marketOfAsset`**, **`approvedReservePool`**, **`reserveOfBrand`** added |
| — | — | **`launchpad`** + `__gap[39]` |

`lpBps` was removed, `_marketsOfBrand` was removed, three mappings were inserted mid-layout,
and the `Market` struct itself gained a `reservePool` field. This is the accumulated result of
the multi-reserve work, the market-unit migration and the launchpad — spread over several
commits. There is no reinitialiser that rescues it; every mapping after the insertion point
would read from the wrong slot.

Confirmation that slot 3 really is live beacon data, not zero: reading it on chain returns
`0x4c990ba2004afbc1010e0506b913cf5210b3710a`, the old vault beacon. An upgrade would
reinterpret that as the v4 PositionManager under 11 live markets.

### So: deploy a fresh stack, and migrate holders off the old one

The deployed stack is effectively gen-4; current code is gen-5 with an incompatible layout.
Gen-1 was already abandoned the same way (the manifest records it: 0 markets, 0 USDG, "not
migrated"). The difference this time is that **gen-4 has real third-party money in it**, so it
cannot simply be walked away from.

What makes this tractable: **redemption is deliberately never pausable.**
`SharedReservePool._redeem` carries no `whenNotPaused` and `PooledBrandToken` does not inherit
`GuardedUpgradeable` at all, so every holder can exit 1:1 at any time regardless of protocol
state. The migration is therefore an announcement and a window, not a contract problem:

1. Announce the redemption window for the four live brands.
2. Let holders redeem 1:1 into USDG on the old reserve. Total exposure is ~$356.
3. Deploy the fresh stack (below). Leave gen-4 on chain, unused, like gen-1.
4. Re-list the brands anyone still wants on the new stack.

I recommend the fresh stack over any attempted migration: the amounts are small, the exit
path is guaranteed by design, and gen-4 also still carries the orphaned-beacon waste the
manifest documents (~10 deployments of dead beacons).

### The deploy path already exists

`script/DeployAssetMarkets.s.sol` is current-gen — it is gated to chain 4663, wires
`IPositionManagerV4`, asserts `factory.positionManager()` afterwards, and takes a
**`DEPLOY_LAUNCHPAD`** flag that calls `ProtocolStack.deployLaunchpad` inline. So the market
stack and the launchpad land in one run; I do not need to write a new mainnet script.

---

## 3–4. Funding (yours)

| Chain | Deployer balance | Needed |
|---|---|---|
| Arbitrum One | **0.000000 ETH** | `DeploySUSDaiHub.s.sol` (step 1 of the sUSDai pair) |
| Robinhood 4663 | **0.01165 ETH** | fresh stack + launchpad + sUSDai group |

Reference points: the gen-4 stack cost **0.005227 ETH across 36 txs** (measured). The
launchpad alone estimated **~54.05M gas** on Base Sepolia; at Robinhood's observed
0.099–0.304 gwei that is roughly **0.005–0.016 ETH**. The ownership handover is negligible
at 0.000032 ETH. Fund both chains with comfortable headroom before starting.

---

## 5. `buybackBurnBps` — moot, withdraw the finding

The overnight audit flagged an unbounded `buybackBurnBps` setter. It does not apply to
anything that deploys: `grep -rln buybackBurnBps src/` returns **nothing**. The symbol exists
only in `vendor/pons-v2/`, which is the upstream reference fork — never compiled into a
deploy, referenced from `src/` only in provenance comments. The buyback itself is gone from
this codebase: `BuybackEngine` and `AssetLockbox` were removed and float yield now streams to
LPs (`BrandFeeVault`, commit `1a13a28`). **No action needed.**

---

## Resolved since the manifest was written

Both never-diagnosed fork failures in the manifest's blocker #1 are gone, and I fixed a third
that had gone stale. `MainnetLaunchFork` is now **7/7 green** against a Robinhood fork:

- `test_fork_funded_fullFlowThroughBuybackAndLockbox` — the arithmetic underflow (panic 0x11)
  in the buyback path. **Gone**: the buyback was replaced by LP rewards, and its successor
  `test_fork_funded_fullFlowThroughHarvestAndLpRewards` passes.
- `test_fork_opensFourMarketsWithFourSeparateBrands` — the address assertion. **Passes.**
- `test_fork_realWallet_floatIsFarTooSmallToEverPayLps` — was failing, but as a *stale
  assertion*, not a bug. It asserted a year of yield on the launch wallet's float could never
  reach `minSweep`; the wallet has since been funded, so yield is now 1.92 USDG against a
  1 USDG floor and the documented finding inverted. Re-pinning it to the new number would only
  move the tripwire, so I rewrote it as
  `test_fork_realWallet_aVaultBelowTheFloorRefusesToPay`: float figures are logged, and the
  assertion is on the durable mechanism — a vault under `minSweep` refuses with the named
  error.

Manifest blocker #2 ("the buyback cannot fire at current funding") is also obsolete for the
same reason the buyback is: float yield now goes to LPs, and it clears the distribution floor.

## Verified ready

Every external integration address checks out live, so `PreflightMainnet.s.sol` should pass:

| Address | Check | Result |
|---|---|---|
| sUSDai `0x0B2b…5ef9` (Arbitrum) | `symbol()` | `sUSDai` |
| Curve sUSDai/USDC `0xa7CF…0E4E` | `N_COINS()` | `2` |
| Across SpokePool `0xe35e…5f2A` (Arbitrum) | `depositQuoteTimeBuffer()` | `3600` |
| Across SpokePool `0xD29C…7978` (Robinhood) | `depositQuoteTimeBuffer()` | `3600` |

And the launchpad itself: no Critical/High across four scout audits, **549** offline tests and
**16** Robinhood-fork launchpad tests green, deployed and smoke-tested end to end on Base
Sepolia.

---

## Ordered path to mainnet

1. **Hand the three proxies to the timelock.** Two runs, 48 h apart, 0.000032 ETH. Do this
   first — it is live exposure and independent of everything else.
2. **Fund Arbitrum and Robinhood.**
3. **Announce the gen-4 redemption window** and let the four brands' holders exit 1:1 (~$356).
4. **`PreflightMainnet.s.sol`** against 4663. Expect a pass.
5. **`DeploySharedReservePool.s.sol`** — the fresh reserve.
6. **`DeployAssetMarkets.s.sol` with `DEPLOY_LAUNCHPAD=true`** — fresh market stack plus the
   launchpad in one run.
7. **`DeploySUSDaiHub.s.sol`** on Arbitrum One (step 1).
8. **`DeploySUSDaiGroup.s.sol`** on Robinhood, taking `SUSDAI_HUB` from step 7 (step 2).
9. **Point the fresh stack's proxies at the timelock immediately**, using the same script with
   the new addresses — do not repeat gen-4's mistake of leaving them on the deploying key.
10. **Keeper**: stand up `services/susdai-keeper/` against the mainnet pair and prove one
    controlled Across round trip before letting float accumulate.
11. **Frontend**: set `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` and the mainnet launchpad block in
    `deployments/app-networks.json`, then deploy.

## Carried over

- ~~`docs/ASSET_MARKETS_MAINNET.md` still documents gen-1.~~ **Closed.** It was rewritten
  against the gen-6 stack and is now the deployment reference.
- The Robinhood public RPC rate-limits a full fork suite (429s). Use a paid endpoint for CI.
- Contract verification through the Blockscout instance is still untested — it sits behind
  Cloudflare and nothing has been verified through it.
- Regulatory counsel on "float interest funds LP rewards" has not been obtained.
- `forge` hangs on mainnet scripts unless Sourcify is short-circuited:
  `HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com`.
  Needed for `DeployAssetMarkets.s.sol`; not for the preflight, the verifier, or the handover
  script.
