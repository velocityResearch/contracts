# Stored LP fee keeper

`script/dynamic-fee-keeper.mjs` is a one-shot, off-chain fee calculator. It submits one symmetric fee through `ProtocolFeeHook.setPoolLpFee(PoolKey,uint24)`. Uniswap stores the fee; swaps do not call a pricing policy or external oracle. This is independent code, not Fables' unpublished algorithm or a profitability claim.

## Operating model

The keeper reads one market at a pinned block and produces a JSON plan. Planning is the default. Execution additionally requires `--execute`, a Foundry encrypted-account name and its public `--sender` address. It never reads raw private keys, mnemonic phrases or env files. Signing uses a subprocess argument array, not a shell, with an explicit `cast send --chain` binding.

The owner appoints one revocable fee keeper. Its contract authority is limited to setting this hook's registered dynamic pools to 100–50,000 pips (0.01–5%). Optional per-market bounds are enforced by this program, not against a malicious authorized signer. The keeper has no custody, upgrade or protocol-skim privileges.

A stored fee does not expire. If a scheduler stops, a reference fails, or the keeper is revoked, the last rate remains until an authorized transaction changes it. There is no automatic baseline fallback or guardian-cleared override.

## Off-chain baseline

Choose the model explicitly:

- `flat`: `--base-pips` is the baseline at every time.
- `equity`: fees are piecewise constant across opening, regular, closing, overnight and closed sessions. The pinned block timestamp is interpreted in `America/New_York`, including the runtime timezone database's DST rules. The regular weekday session starts at 09:30 inclusive and ends at 16:00 exclusive. The first `--open-window-minutes` uses `--open-pips`; the final `--close-window-minutes` uses `--close-pips`; the middle uses `--base-pips`. Weekdays outside session, including Friday evening, use `--overnight-pips`. Weekends and explicit holidays use `--closed-pips`.

The default open/close windows are 30 minutes each. Zero disables a window; windows must not overlap, including on configured early-close dates. These are deliberately simple windows, not the removed on-chain linear ramps.

`--holidays YYYY-MM-DD,...` and `--early-closes YYYY-MM-DD@HH:MM,...` are explicit operator inputs. No complete exchange-holiday database is bundled. Early closes must be after 09:30 and no later than 16:00. Malformed, duplicate and conflicting dates are rejected. All configured session rates must lie within `--floor-pips` and `--cap-pips`, whose defaults are 100 and 50,000.

Calendar transitions only take effect when a scheduled run submits a transaction. Merely crossing the market-open time does not update the on-chain rate.

## Optional reference premium

Without a reference, the keeper can submit the baseline. With a configured V3 reference, it validates the exact asset/reserve-underlying pair, expected factory and factory lookup, decimals, current and harmonic liquidity, observation history/freshness, and spot-versus-TWAP distance. The V4 StateView must name the factory's PoolManager. The market must be initialized with active liquidity and an exact matching PoolKey/PoolId; its unit must be registered in its reserve with compatible decimals.

A configured but unavailable or invalid reference aborts without writing. It is not silently converted into baseline-only execution. The previous fee persists, so failure alerting is required.

The reference must be economically independent enough to be useful. Factory authentication alone does not establish manipulation resistance. `--min-reference-liquidity` is mandatory with a reference and uses raw V3 liquidity units; calibrate it for the actual pair and decimals.

For independent V3 TWAP price `F` and our V4 spot price `M`, the algorithm measures `abs(F-M)/M` with exact rational/BigInt price arithmetic. Cumulative mean ticks round down, including negative values. It adds a premium only beyond the deadband:

`premiumPips = min(maxPremiumPips, floor(excessDivergencePpm * premiumPipsPerBps / 100))`

`targetPips = min(capPips, baselinePips + premiumPips)`

The sign of divergence does not select a trade direction: the target applies equally to buying and selling. This is simpler to integrate, but can also penalize the direction that would improve inventory. No directional premium or half-baseline floor exists on chain.

Default reference calibration is a 1,800-second TWAP, 900-second observation-age limit, 500-bps reference spot/TWAP limit, 25-bps divergence deadband, 1,000-bps market/reference circuit breaker, 20 fee pips per excess divergence basis point, and 10,000-pip maximum premium. These are illustrative safeguards, not optimized rates or expected returns.

## Commands and output

Install the maintained web dependencies first; the script uses their pinned `viem` package. The following examples use shell variables for public deployment addresses. Set them to independently verified values; they are not deployment recommendations.

Flat baseline planning, without a reference:

```sh
node script/dynamic-fee-keeper.mjs --rpc-url "$RPC_URL" --chain-id 4663 --factory "$FACTORY" --market-id "$MARKET_ID" --state-view "$STATE_VIEW" --model flat --base-pips 5000
```

Equity baseline planning, also without a reference; the rates and dates are illustrative inputs, not a complete exchange calendar:

```sh
node script/dynamic-fee-keeper.mjs --rpc-url "$RPC_URL" --chain-id 4663 --factory "$FACTORY" --market-id "$MARKET_ID" --state-view "$STATE_VIEW" --model equity --base-pips 2000 --overnight-pips 3000 --closed-pips 5000 --open-pips 7000 --close-pips 4000 --holidays 2026-12-25 --early-closes 2026-11-27@13:00
```

Reference-backed planning:

```sh
node script/dynamic-fee-keeper.mjs --rpc-url "$RPC_URL" --chain-id 4663 --factory "$FACTORY" --market-id "$MARKET_ID" --state-view "$STATE_VIEW" --model flat --base-pips 5000 --reference-pool "$REFERENCE_POOL" --reference-factory "$REFERENCE_FACTORY" --min-reference-liquidity "$MIN_REFERENCE_LIQUIDITY"
```

Append `--execute --account dynamic-fee-keeper --sender "$KEEPER_ADDRESS"` to a reviewed command to permit submission. The account must already exist in the operator's approved signing setup; this implementation does not create or import credentials.

The plan contains the pinned block, market/hook identities, baseline session/rate, stored LP fee, exact reference/market prices, calibration, target fee and calldata. BigInt values serialize as decimal strings. `decision` is `set-pool-lp-fee` or `no-write`; `action` is null when the stored rate already matches. Matching rates do not need periodic refresh transactions because they have no expiry.

Before sending, the keeper repeats the full snapshot and calculation, checks the sender against hook owner/keeper, and simulates the call. It then signs with the expected chain, waits for a successful receipt, checks the exact `PoolLpFeeUpdated` event, and reads the stored LP fee at the receipt block. This detects failures, but does not eliminate state changes before inclusion or later same-block authorized updates.

## Scheduling and intervention

Use an external scheduler; the script has no daemon, lock file or persistent policy store. Serialize runs for each `(chain, hook, poolId)` and choose a cadence consistent with market-session changes and reference quality. Retain plan/receipt logs and alert on failures or missed runs. Do not automatically retry with missing reference arguments after a reference failure.

For an incident, the owner can revoke the keeper with `setFeeKeeper(address(0))` and separately set an appropriate fee through `setPoolLpFee`. Revocation alone leaves the old fee in place. Treat keeper account compromise as an economic incident even though it cannot withdraw principal directly.

No production scheduler, account, transaction or aggregator registration is created by this change. Current validation and unexercised execution paths are listed in [FABLES_VERIFICATION.md](FABLES_VERIFICATION.md).
