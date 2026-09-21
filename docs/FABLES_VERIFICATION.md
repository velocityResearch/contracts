# Keeper-set LP fee verification

Branch `feature/keeper-lp-fees`, based on `main` at `57db3d0` (the tree that records the 2026-09-21 production release). This supersedes the earlier report written against the stale `8198a40` base. Historical policy benchmarks and review JSON are not evidence for this revision.

## Change boundary

Against the deployed `ProtocolFeeHook` implementation (`0xd4AC6b17…`, the `staging/main` source that the open KyberSwap pull request describes), the hook gains **51 lines and loses 2**; `AssetMarketFactory` gains 5 and loses 1. No production contract is added. The per-swap `IDynamicFeePolicy`/`VolatilityFeePolicy` consultation that `main` had staged for the skim — never deployed, `feePolicy()` reverts on the live proxy — is removed with its test (three files, about 900 lines), so `main`'s hook and the live hook now differ only by the keeper additions.

The stored LP fee starts at 5,000 pips (0.50%), is bounded inclusively to 100–50,000 pips (0.01–5%), applies in both directions, and persists until another authorised update. The skim is untouched: still charged in `afterSwap` on the unspecified leg, still capped at 1%, increases still announced an hour ahead.

## Executed contract checks

- **792 offline tests passed, 0 failed, 2 skipped** across 55 suites (`forge test --no-match-path 'test/*Fork*'`). This includes the 10 `DynamicFeeHookTest` cases, whose skim assertions were rewritten for the live `afterSwap` rule (expected from the pool's own `Swap` event, the gross amount before the hook's cut) and whose legacy-layout fixture is now the exact deployed layout, seeded with an in-flight scheduled increase that the upgrade must preserve.
- **Fork suites: 13 suites, 80 passed, 1 failed** (`forge test --match-path 'test/markets/*Fork*' --fork-url https://rpc.mainnet.chain.robinhood.com --threads 1`). The failure is `SharedQuoteMainnetFork.test_fork_theThreeAssetsReopenQuotedInAiusd`, which asserts a constant issuer address against `PoolBrandTreasury.admin()`; the live admin is now the 2-of-3 Safe. The file is unchanged from `main` and the assertion does not touch this change.
- The passing fork suites include `DynamicFeesMainnetForkTest` (5), `KyberAdapterParityMainnetFork` (4) and `MarketLensSimulatorFork` (5). `MarketLens` on `main` replays swaps through `V4SwapSimulator` rather than calling the deployed quoter; the simulator reads `slot0.lpFee` as `Pool.swap` does, so a keeper-set rate is quoted exactly, and the dynamic-fee fork suite checks its quotes against real executions on the live PoolManager.
- The public RPC rate-limits parallel fork runs (HTTP 429); run fork suites with `--threads 1`.

## Storage and size

`feeKeeper` is appended below the deployed `pendingFeePipsOf` and `feePipsEffectiveAt` slots. `test_upgradeFromExactDeployedLayoutPreservesEveryOriginalSlot` upgrades a proxy initialised from the deployed layout and checks every original slot, including a seeded scheduled increase, before and after the keeper is set. `ProtocolFeeHook` compiles to 14,024 bytes of runtime, `AssetMarketFactory` to 22,378, both under EIP-170.

## Keeper and consumer checks

- **14 keeper behavioural tests passed** (`node --test script/dynamic-fee-keeper.test.mjs`); the CLI `--help` completes.
- **Frontend**: typecheck passed, **950 tests passed**, lint clean apart from four pre-existing warnings in tests, production build passed (`NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` supplied in the environment). The liquidity page's pools table now labels a pool without an indexed last-swap fee through `marketFeeLabel`, so a dynamic pool's `0x800000` identity flag is never rendered as a rate.
- **Backend**: typecheck passed, **333 tests passed, 1 skipped** (no `TEST_POSTGRES_URL`).
- **Mobile**: **5 tests passed**. `tsc` reports four `brandName`/`brandSymbol` errors in `mobile/src/services/chain-service.ts` that are present on `main` unchanged; not part of this change.
- ABIs and the reader package were regenerated with `npm --prefix web-stable run abis` from the current build. `main`'s committed ABI file was stale (it lacked, for example, `FEE_INCREASE_DELAY`, which is live), so the regenerated `asset-markets.ts` and `launchpad-abis.ts` carry that catch-up as well as the keeper surface. The installed copy passes `check:market-reader`.
- **KyberSwap adapter** (`integrations/kyberswap-dex-lib/hooks/stables-fast`, mirrored on PR #1699's branch): `go vet` clean, `CI=1 go test -race -cover` **ok, 94.1%**. `TestDynamicFeePool_QuotesAtTheTrackedStoredRate` runs dex-lib's whole v4 simulator over a `0x800000` pool and a static pool at the same tracked `slot0` rate and requires identical output, and pins that output to 1.2% LP + 0.50% skim rather than the flag read as a fee.

## Limits

No local Anvil transaction smoke was repeated for this base; the contract lines are identical to the ones smoked on the previous base and the fork suite exercises the same setter, authorisation and persistence paths against the live PoolManager. No production deployment, hook upgrade, keeper scheduler, encrypted signer setup, independent audit, profitability claim or aggregator acceptance is claimed. The keeper role can move any registered dynamic pool anywhere inside the allowed range; revocation stops future writes but does not reset the last fee.
