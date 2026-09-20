# Mainnet runbook

The ordered sequence for standing a stack up on Robinhood Chain mainnet (chainId 4663), and
for the operations that are routine once one is live. First written 2026-09-16 for the gen-6
deployment; kept current since, because the sequence is still the sequence.

**Gen-6 is deployed and live.** Steps 1 to 6 below describe how it was built and how the next
one would be; unless you are deploying a fresh stack, you want section B. Addresses are in
`deployments/asset-markets-mainnet-v6.json`; live chain state is in
`deployments/mainnet-state.json`; the governance picture is [`UPGRADING.md`](../UPGRADING.md).

This is a contracts-only repository. There is no `web-stable/`, no `backend/` and no
`services/` here; where a step needs one of them, it says so and says where it is not.

Rehearse the whole thing first. `script/rehearse-mainnet.sh` runs the entire sequence against
an anvil fork of 4663, launchpad included, using the same scripts and the same commands. Re-run
it whenever `src/` has changed.

---

# A. Deploying a fresh stack

## 1. Fund the deployer on both chains

| Chain | Suggested |
|---|---|
| Robinhood 4663 | **0.05 ETH** |
| Arbitrum One (only for the sUSDai pair) | **0.01 ETH** |

Reference: the gen-4 stack cost 0.005227 ETH across 36 measured transactions. The launchpad
added ~54M gas on Base Sepolia, so budget 0.005-0.016 ETH at Robinhood's observed 0.099-0.304
gwei. Headroom is cheap; a half-finished deploy is not.

## 2. Preflight

```
forge script script/PreflightMainnet.s.sol --rpc-url robinhood
```

Read-only, no key. It asserts every hardcoded external integration address against the live
chain: sUSDai reports `sUSDai`, the Curve pool reports `N_COINS = 2`, both Across SpokePools
report `depositQuoteTimeBuffer() = 3600`, and the `PositionManager` reports the same
`PoolManager` singleton every market will be created in.

## 3. Short-circuit Sourcify before the two deploy steps

`forge` hangs on mainnet scripts otherwise. The trace contains `PoolManager`,
`PositionManager` and Permit2, none of which are in local artifacts, so it tries to label them
through sourcify.dev and that request never returns. It looks exactly like a chain problem and
is not; `--disable-labels` does not stop it.

```
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
```

Needed for steps 4 and 5. Not needed for the preflight, the verifier, or the Sourcify
publication in step 7.

## 4. Deploy the reserve layer

```
PRIVATE_KEY=0x... TIMELOCK_MIN_DELAY=0 forge script script/DeploySharedReservePool.s.sol --rpc-url robinhood --broadcast --slow
```

Deploys a fresh `MorphoBlueYieldSource`, the `ProtocolGuard`, the four beacons and the
`SharedReservePool` behind an ERC1967 proxy. A nonzero `TIMELOCK_MIN_DELAY` additionally
deploys a `TimelockController` and gives it everything; zero takes the documented branch that
deploys none and leaves the deploying key owning the stack. **Gen-6 used zero and then migrated
custody to a Safe (step 6).** Decide which of those you are doing before you run this, not
after.

Record `SharedReservePool`, `ProtocolGuard` and, if you passed a nonzero delay,
`TimelockController` from the output.

## 5. Deploy the market stack and the launchpad, in one run

```
PRIVATE_KEY=0x... SHARED_RESERVE_POOL=0x<step4> DEPLOY_LAUNCHPAD=true forge script script/DeployAssetMarkets.s.sol --rpc-url robinhood --broadcast --slow
```

`DEPLOY_LAUNCHPAD=true` calls `ProtocolStack.deployLaunchpad` inline and then makes the one
owner call that crosses into the market factory, `setLaunchpad`. Without it, every graduation
later reverts `OnlyLaunchpad` and each launch sits stuck in `Swept`.

**Do not run a separate no-`--broadcast` simulation first.** `--broadcast` simulates the whole
script including the post-deploy wiring and venue assertions, and sends nothing if any of it
fails. A standalone simulation is redundant and hangs the same way step 3 fixes.

Record `ProtocolFeeHook`, `AssetMarketFactory`, `MarketRouter`, `MarketDeployer (library)`,
`LaunchFeeEscrow`, `LaunchFactory (proxy)`, `LaunchGraduationGuard`, `LaunchLocker`,
`LaunchDeployer`, `LaunchGraduation`, `LaunchRouter`, and the launch config id.

## 6. Verify the wiring, then hand custody to a Safe

```
SHARED_RESERVE_POOL=0x... ASSET_MARKET_FACTORY=0x... MARKET_ROUTER=0x... forge script script/VerifyAssetMarketsMainnet.s.sol --rpc-url robinhood
```

Then the two properties the rehearsal checks and nothing else re-checks:

```
cast call <assetMarketFactory> 'launchpad()(address)'        --rpc-url robinhood   # == LaunchGraduation
cast call <assetMarketFactory> 'positionManager()(address)'  --rpc-url robinhood   # == 0x58daec…4fA7
```

**Then move ownership off the deploying key immediately.** Every handle ships owned by it, and
that is the state gen-4 was criticised for. The migration that gen-6 ran is recorded, with its
Safe Transaction Builder batches, in `deployments/safe-batches/`; it is a two-phase sequence
because twelve handles are `Ownable2Step` (nominate, then the Safe accepts) and four beacons
are plain `Ownable` (one step, irreversible). Do the registry first as a cheap proof that the
Safe's signers work, then the rest, then the beacons.

`script/HandOverMainnetOwnership.s.sol` is **not** the path: it is hardcoded to the gen-5
proxies and the abandoned gen-5 timelock and moves nothing in use.

Confirm the end state against the chain:

```
forge test --match-contract OwnershipMigrationMainnetForkTest --threads 1 --fork-url https://rpc.mainnet.chain.robinhood.com
```

## 7. Publish the source

```
./script/verify-mainnet-sourcify.sh
```

Idempotent, signs nothing, spends no gas. Sourcify by standard-JSON input, never flattened and
never Blockscout directly — see `DEPLOYMENT.md` for why. Update the address table at the top of
the script for a new generation before running it.

## 8. The sUSDai pair — Arbitrum first

```
PRIVATE_KEY=0x... forge script script/DeploySUSDaiHub.s.sol --rpc-url arbitrum --broadcast --slow
```

Record `SUSDAI_HUB`, then back on Robinhood:

```
PRIVATE_KEY=0x... SUSDAI_HUB=0x<step8> SHARED_RESERVE_POOL=0x<step4> forge script script/DeploySUSDaiGroup.s.sol --rpc-url robinhood --broadcast --slow
```

The order is forced: the group's adapter takes the hub's address as a constructor argument, and
the hub is on the other chain.

## 9. Prove one Across round trip before letting float accumulate

Run one controlled cycle — `bridgeOut`, `buyShares`, `sync`, then `sellShares`, `bridgeHome`,
`sync` — at a size you are willing to lose to a bridge timeout. The keeper that drives this
lives outside this repository. The Base Sepolia rehearsal did exactly this and its accounting
is recorded in `deployments/asset-markets-base-sepolia.json`: 0.993023 USDC against 1.000000
branded supply, with the difference booked to `lossCarryforward`, which is the shape a healthy
cycle has.

Do not skip to funding the reserve. A keeper that cannot complete a round trip is a reserve
that cannot honour a redemption at par.

## 10. Publish the addresses

Add the new generation as `deployments/asset-markets-mainnet-v<n>.json` and update
`deployments/app-networks.json`, which is the address feed the web application consumes at
build time. That application is not in this repository, so this is where the handoff ends:
these two files are the deliverable.

---

# B. Operating a live stack

Everything here is a Safe transaction unless it says otherwise. There is no timelock: two
signatures and it is done. `UPGRADING.md` has the procedures and the honest limits.

## Changing a fee

Increases are announced, not applied. Both knobs take one hour and then anyone can commit.

```
cast calldata 'setPoolFeePips(bytes32,uint24)' <poolId> <pips>     # hook, <= MAX_FEE_PIPS 10000
cast calldata 'setRedemptionFee(uint16)' <bps>                     # reserve, <= 100
```

Sign either from the Safe, wait the hour, then anybody calls `commitPoolFeePips(poolId)` or
`commitRedemptionFee()`. A decrease applies in the transaction that makes it and cancels any
pending increase, so the owner can always make a fee smaller at once.

Announce an increase to integrators when you schedule it, not when you commit it. The whole
point of the hour is that a filling quote cannot be repriced underneath it.

## Halting

The guardian key `0xc1d844d6478e450E62293882d2d6739c4a8693F9` halts, alone and immediately:

```
cast send 0x013D1974F8215a12280e6b9a33F9732277F38C0e 'pause()' --rpc-url robinhood --private-key $GUARDIAN_KEY
cast send 0x013D1974F8215a12280e6b9a33F9732277F38C0e 'pauseTarget(address)' <target> --rpc-url robinhood --private-key $GUARDIAN_KEY
```

**Only the Safe can resume.** That asymmetry is the design: a stolen guardian key costs uptime
and nothing more. Redemption and brand-token transfers are never halted, so holders can exit
1:1 throughout.

## Collecting fees

`ProtocolFeeHook.collect(key)` is permissionless and pays whoever is the pool's recipient **at
the moment it runs**, not when the fee accrued. So: collect first, repoint second. The batch
that repoints the recipients to the Safe is prepared and unsent in
`deployments/safe-batches/03-repoint-fee-recipients.json`, and
`script/SweepFeesToSafeMainnet.s.sol` is the sweep that should precede it.

## Upgrading

See [`UPGRADING.md`](../UPGRADING.md). In outline: deploy the implementation with any funded
key, rehearse on a fork, have the Safe call `upgradeToAndCall(impl, 0x)`, re-read the ERC-1967
slot, publish to Sourcify. The `script/Upgrade*Mainnet.s.sol` scripts assert that the
broadcasting signer owns the proxy, so they no longer broadcast; use them in simulation for
their verification blocks and to read out the calldata.

---

## Known limits

- **No upgrade timelock.** Two Safe signatures change any implementation in one transaction,
  with no window to read or cancel in. Carried in `docs/audit-history.md` as A3-CRITICAL-1;
  the custody migration narrowed it from one key to two, and did not close it.
- **Protocol fee recipients still point at the retired deployer EOA.** Prepared batch above.
- **The pools are thin.** Roughly $37.7k of total v4 liquidity across the six live markets, so
  a 1,000 USDG buy moves most of them double digits. The deep leg is the reserve, not the
  pools. Do not let a quote surface imply otherwise.
- **Morpho utilisation.** `SharedReservePool._recallIfNeeded` pulls on demand and reverts at
  100% utilisation, and there is no idle-buffer policy.
- **The public Robinhood RPC rate-limits a full fork suite** (429s). Add `--threads 1`, or use
  a paid endpoint for CI.
- **Regulatory counsel on "float interest funds LP rewards" has not been obtained.**
