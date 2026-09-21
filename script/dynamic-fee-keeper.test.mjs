import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  arithmeticMeanTick,
  baselineForTimestamp,
  buildPlan,
  computeStoredFee,
  DYNAMIC_FEE_FLAG,
  parseCli,
  poolIdOf,
  priceOfBaseInQuote,
  runKeeper,
  sqrtPriceAtTick,
} from "./dynamic-fee-keeper.mjs";

const require = createRequire(new URL("../web-stable/package.json", import.meta.url));
const { decodeFunctionData, encodeAbiParameters, encodeEventTopics, parseAbi } = require("viem");
const setterAbi = parseAbi([
  "function setPoolLpFee((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks),uint24)",
  "event PoolLpFeeUpdated(bytes32 indexed poolId,uint24 feePips)",
]);
const address = (value) => `0x${BigInt(value).toString(16).padStart(40, "0")}`;
const factory = address(1);
const brand = address(2);
const asset = address(3);
const reserveAsset = address(4);
const reserve = address(5);
const hook = address(6);
const sender = address(7);
const stateView = address(8);
const referencePool = address(9);
const referenceFactory = address(10);
const Q96 = 1n << 96n;
const Q128 = 1n << 128n;
const transactionHash = `0x${"ab".repeat(32)}`;

function settings(changes = {}) {
  return {
    execute: false,
    rpcUrl: "http://127.0.0.1:8545",
    chainId: 31337n,
    factory,
    marketId: 1n,
    stateView,
    model: "flat",
    basePips: 1000n,
    floorPips: 100n,
    capPips: 50000n,
    referencePool,
    referenceFactory,
    minReferenceLiquidity: 1_000_000n,
    twapWindow: 1800n,
    maxObservationAge: 900n,
    maxReferenceSpotDeviationBps: 500n,
    thresholdBps: 25n,
    maxDivergenceBps: 2000n,
    premiumPipsPerBps: 20n,
    maxPremiumPips: 10000n,
    account: null,
    sender: null,
    ...changes,
  };
}
const baselineSettings = (changes = {}) =>
  settings({ referencePool: null, referenceFactory: null, ...changes });
const equitySettings = (changes = {}) =>
  baselineSettings({
    model: "equity",
    overnightPips: 2000n,
    closedPips: 4000n,
    openPips: 3000n,
    closePips: 2500n,
    openWindowMinutes: 30n,
    closeWindowMinutes: 30n,
    holidays: [],
    earlyCloses: {},
    ...changes,
  });
const timestamp = (iso) => BigInt(Date.parse(iso) / 1000);

function snapshot(changes = {}) {
  const poolKey = {
    currency0: brand,
    currency1: asset,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: 50n,
    hooks: hook,
  };
  const window = 1800n;
  const tick = 1000n;
  const liquidity = 2_000_000n;
  const base = {
    chainId: 31337n,
    blockNumber: 100n,
    blockHash: `0x${"11".repeat(32)}`,
    blockTimestamp: 1_000_000n,
    hookAddress: hook,
    signer: null,
    pool: { sqrtPriceX96: Q96, liquidity: 1_000_000n, lpFee: 5000n },
    market: {
      asset,
      brandToken: brand,
      poolId: poolIdOf(poolKey),
      fee: DYNAMIC_FEE_FLAG,
      tickSpacing: 50n,
      reservePool: reserve,
      poolKey,
      reserveAsset,
      assetDecimals: 18n,
      brandDecimals: 6n,
      reserveDecimals: 6n,
      brandRegistered: true,
    },
    reference: {
      factory: referenceFactory,
      canonicalPool: referencePool,
      fee: 3000n,
      token0: asset,
      token1: reserveAsset,
      assetDecimals: 18n,
      quoteDecimals: 6n,
      sqrtPriceX96: sqrtPriceAtTick(tick),
      observationCardinality: 16n,
      unlocked: true,
      currentLiquidity: liquidity,
      latestObservationTimestamp: 999_950n,
      latestObservationInitialized: true,
      tickCumulatives: [0n, tick * window],
      secondsPerLiquidityCumulatives: [0n, (window * Q128) / liquidity],
    },
  };
  return {
    ...base,
    ...changes,
    market: { ...base.market, ...(changes.market ?? {}) },
    pool: { ...base.pool, ...(changes.pool ?? {}) },
    reference:
      changes.reference === null ? null : { ...base.reference, ...(changes.reference ?? {}) },
  };
}

function fee(changes = {}) {
  return computeStoredFee({
    ...settings(),
    fairPrice: { numerator: 110n, denominator: 100n },
    poolPrice: { numerator: 1n, denominator: 1n },
    baselinePips: 1000n,
    thresholdBps: 0n,
    premiumPipsPerBps: 2n,
    ...changes,
  });
}

test("equal absolute divergence charges one symmetric fee regardless of sign", () => {
  const above = fee();
  const below = fee({ fairPrice: { numerator: 90n, denominator: 100n } });
  assert.equal(above.feePips, 3000n);
  assert.deepEqual(below, above);
});

test("premium and final fee obey separate bounds including the 5% hard maximum", () => {
  const capped = fee({ baselinePips: 49500n, premiumPipsPerBps: 100n, maxPremiumPips: 5000n });
  assert.equal(capped.premiumPips, 5000n);
  assert.equal(capped.feePips, 50000n);
  assert.equal(fee({ capPips: 2000n }).feePips, 2000n);
  assert.throws(() => fee({ capPips: 50001n }), /fee bounds/);
  assert.throws(() => fee({ baselinePips: 99n }), /baseline/);
  assert.equal(fee({ thresholdBps: 1000n }).feePips, 1000n);
  assert.throws(() => fee({ maxDivergenceBps: 999n }), /circuit breaker/);
});

test("price conversion and negative TWAP ticks retain exact decimal arithmetic", () => {
  const price = priceOfBaseInQuote(Q96, true, 18n, 6n);
  assert.equal(price.numerator / price.denominator, 1_000_000_000_000n);
  assert.equal(price.numerator % price.denominator, 0n);
  const inverse = priceOfBaseInQuote(Q96, false, 6n, 18n);
  assert.equal(inverse.numerator * 1_000_000_000_000n, inverse.denominator);
  assert.equal(arithmeticMeanTick([0n, -1801n], 1800n), -2n);
});

test("New York open, regular, close, and overnight boundaries use local time across DST", () => {
  const calendar = equitySettings();
  for (const [iso, session, feePips] of [
    ["2026-03-06T14:29:59Z", "overnight", 2000n],
    ["2026-03-06T14:30:00Z", "open", 3000n],
    ["2026-03-09T13:30:00Z", "open", 3000n],
    ["2026-03-09T13:59:59Z", "open", 3000n],
    ["2026-03-09T14:00:00Z", "regular", 1000n],
    ["2026-03-09T19:29:59Z", "regular", 1000n],
    ["2026-03-09T19:30:00Z", "close", 2500n],
    ["2026-03-09T20:00:00Z", "overnight", 2000n],
    ["2026-11-02T14:30:00Z", "open", 3000n],
  ]) {
    const result = baselineForTimestamp(timestamp(iso), calendar);
    assert.equal(result.session, session, iso);
    assert.equal(result.feePips, feePips, iso);
  }
});

test("weekend, holiday and early-close inputs change the baseline without a reference", () => {
  const calendar = equitySettings({
    holidays: ["2026-07-03"],
    earlyCloses: { "2026-11-27": 780n },
  });
  for (const [iso, expected] of [
    ["2026-07-04T15:00:00Z", 4000n],
    ["2026-07-03T15:00:00Z", 4000n],
    ["2026-11-27T17:29:59Z", 1000n],
    ["2026-11-27T17:30:00Z", 2500n],
    ["2026-11-27T18:00:00Z", 2000n],
  ]) {
    const plan = buildPlan(snapshot({ reference: null, blockTimestamp: timestamp(iso) }), calendar);
    assert.equal(plan.result.feePips, expected, iso);
    assert.equal(plan.decision, "set-pool-lp-fee");
  }
});

test("no-reference flat baseline produces a setter; matching native fee stays unchanged indefinitely", () => {
  const plan = buildPlan(snapshot({ reference: null }), baselineSettings());
  const decoded = decodeFunctionData({ abi: setterAbi, data: plan.action.calldata });
  assert.equal(plan.action.to, hook);
  assert.equal(decoded.functionName, "setPoolLpFee");
  assert.equal(decoded.args[1], 1000);
  assert.equal(poolIdOf(decoded.args[0]), plan.poolId);
  const same = buildPlan(
    snapshot({ reference: null, blockTimestamp: 9_000_000n, pool: { lpFee: 1000n } }),
    baselineSettings(),
  );
  assert.equal(same.decision, "no-write");
  assert.equal(same.action, null);
});

test("invalid reference identity, age, liquidity and spot drift fail closed", () => {
  for (const [change, expected] of [
    [{ latestObservationTimestamp: 998_000n }, /stale/],
    [{ token1: address(99) }, /exact market asset/],
    [{ canonicalPool: address(99) }, /does not recognize/],
    [{ currentLiquidity: 999_999n }, /current liquidity/],
    [{ secondsPerLiquidityCumulatives: [0n, (1800n * Q128) / 999_999n] }, /harmonic/],
    [{ sqrtPriceX96: Q96 }, /spot is too far/],
    [{ quoteDecimals: 18n }, /quote decimals/],
  ])
    assert.throws(() => buildPlan(snapshot({ reference: change }), settings()), expected);
  assert.throws(() => buildPlan(snapshot({ chainId: 1n }), settings()), /RPC chain/);
  assert.throws(() => buildPlan(snapshot({ market: { reserveDecimals: 18n } }), settings()), /1:1/);
});

test("a configured but missing or invalid reference never broadcasts, even when baseline matches", async () => {
  for (const reference of [null, { latestObservationTimestamp: 998_000n }]) {
    let broadcasts = 0;
    await assert.rejects(
      runKeeper(settings({ execute: true, account: "keeper", sender }), {
        client: {},
        loadSnapshot: async () => snapshot({ reference, pool: { lpFee: 1000n } }),
        executor: async () => {
          broadcasts += 1;
          return transactionHash;
        },
      }),
      /reference/,
    );
    assert.equal(broadcasts, 0);
  }
});

test("default plan mode never broadcasts a symmetric reference update", async () => {
  let broadcasts = 0;
  const plan = await runKeeper(settings(), {
    client: {},
    loadSnapshot: async () => snapshot(),
    executor: async () => {
      broadcasts += 1;
      return transactionHash;
    },
  });
  const decoded = decodeFunctionData({ abi: setterAbi, data: plan.action.calldata });
  assert.equal(BigInt(decoded.args[1]), plan.result.feePips);
  assert.equal(plan.result.feePips, 11000n);
  assert.equal(broadcasts, 0);
});

function executionClient(
  feePips,
  { eventFee = feePips, storedFee = feePips, logs, status = "success" } = {},
) {
  return {
    call: async () => {},
    waitForTransactionReceipt: async () => ({
      status,
      blockNumber: 101n,
      logs: logs ?? [
        {
          address: hook,
          topics: encodeEventTopics({
            abi: setterAbi,
            eventName: "PoolLpFeeUpdated",
            args: { poolId: snapshot().market.poolId },
          }),
          data: encodeAbiParameters([{ type: "uint24" }], [eventFee]),
        },
      ],
    }),
    readContract: async ({ address: target, functionName, args, blockNumber }) => {
      assert.equal(target, stateView);
      assert.equal(functionName, "getSlot0");
      assert.equal(args[0], snapshot().market.poolId);
      assert.equal(blockNumber, 101n);
      return [Q96, 0, 0, storedFee];
    },
  };
}
const authorizedSnapshot = (changes = {}) =>
  snapshot({ reference: null, signer: { owner: address(90), keeper: sender }, ...changes });
const executeSettings = (changes = {}) =>
  baselineSettings({ execute: true, account: "keeper", sender, ...changes });

test("fresh replan skips matched state and aborts changed chain, revoked signer, or invalid reference before sending", async () => {
  for (const [updated, options, error] of [
    [authorizedSnapshot({ pool: { lpFee: 1000n } }), executeSettings(), null],
    [authorizedSnapshot({ chainId: 1n }), executeSettings(), /RPC chain/],
    [
      authorizedSnapshot({ signer: { owner: address(90), keeper: address(0) } }),
      executeSettings(),
      /authorized keeper/,
    ],
    [
      snapshot({ reference: { latestObservationTimestamp: 998_000n } }),
      settings({ execute: true, account: "keeper", sender }),
      /stale/,
    ],
  ]) {
    let loads = 0;
    let broadcasts = 0;
    const promise = runKeeper(options, {
      client: executionClient(1000n),
      loadSnapshot: async () =>
        ++loads === 1 ? (options.referencePool ? snapshot() : authorizedSnapshot()) : updated,
      executor: async () => {
        broadcasts += 1;
        return transactionHash;
      },
    });
    if (error) await assert.rejects(promise, error);
    else assert.equal((await promise).execution.skippedAfterRecheck, true);
    assert.equal(broadcasts, 0);
  }
});

test("execution uses fresh calendar decision and verifies the exact event plus authoritative stored fee", async () => {
  let loads = 0;
  const plan = await runKeeper(
    executeSettings({ ...equitySettings(), execute: true, account: "keeper", sender }),
    {
      client: executionClient(3000n),
      loadSnapshot: async () =>
        authorizedSnapshot({
          blockTimestamp: timestamp(
            ++loads === 1 ? "2026-03-09T13:29:59Z" : "2026-03-09T13:30:00Z",
          ),
        }),
      executor: async ({ calldata }) => {
        assert.equal(decodeFunctionData({ abi: setterAbi, data: calldata }).args[1], 3000);
        return transactionHash;
      },
    },
  );
  assert.equal(plan.execution.verifiedLpFee, 3000n);
  for (const [client, error] of [
    [executionClient(1000n, { eventFee: 1001n }), /exact PoolLpFeeUpdated/],
    [executionClient(1000n, { logs: [] }), /exact PoolLpFeeUpdated/],
    [executionClient(1000n, { storedFee: 1001n }), /stored LP fee/],
    [executionClient(1000n, { status: "reverted" }), /reverted/],
  ])
    await assert.rejects(
      runKeeper(executeSettings(), {
        client,
        loadSnapshot: async () => authorizedSnapshot(),
        executor: async () => transactionHash,
      }),
      error,
    );
});

test("cast command binds signing chain and encrypted account without raw-key flags", async () => {
  const directory = mkdtempSync(join(tmpdir(), "stored-fee-cast-"));
  const previousPath = process.env.PATH;
  const captured = join(directory, "arguments.json");
  try {
    writeFileSync(
      join(directory, "cast"),
      `#!${process.execPath}\nconst fs = require('node:fs'); fs.writeFileSync(${JSON.stringify(captured)}, JSON.stringify(process.argv.slice(2))); console.log(JSON.stringify({transactionHash:${JSON.stringify(transactionHash)}}));\n`,
      { mode: 0o700 },
    );
    process.env.PATH = `${directory}:${previousPath ?? ""}`;
    await runKeeper(executeSettings(), {
      client: executionClient(1000n),
      loadSnapshot: async () => authorizedSnapshot(),
    });
    const args = JSON.parse(readFileSync(captured, "utf8"));
    assert.equal(args[0], "send");
    assert.equal(args[1], hook);
    assert.equal(args[args.indexOf("--chain") + 1], "31337");
    assert.equal(args[args.indexOf("--account") + 1], "keeper");
    assert.equal(args[args.indexOf("--from") + 1], sender);
    assert.equal(args.includes("--private-key"), false);
  } finally {
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
    rmSync(directory, { recursive: true, force: true });
  }
});

const cli = (extra = []) => [
  "--rpc-url",
  "http://127.0.0.1:8545",
  "--chain-id",
  "31337",
  "--factory",
  factory,
  "--market-id",
  "1",
  "--state-view",
  stateView,
  ...extra,
];
const flatCli = (extra = []) => cli(["--model", "flat", "--base-pips", "1000", ...extra]);
const equityCli = (extra = []) =>
  cli([
    "--model",
    "equity",
    "--base-pips",
    "1000",
    "--overnight-pips",
    "2000",
    "--closed-pips",
    "4000",
    "--open-pips",
    "3000",
    "--close-pips",
    "2500",
    ...extra,
  ]);

test("CLI accepts baseline-only execution and rejects unsafe bounds, obsolete flags and raw secrets", () => {
  assert.equal(
    parseCli(flatCli(["--execute", "--account", "keeper", "--sender", sender])).execute,
    true,
  );
  assert.throws(() => parseCli(flatCli(["--cap-pips", "50001"])), /allowed range/);
  assert.throws(() => parseCli(flatCli(["--floor-pips", "1001"])), /baseline/);
  for (const flag of ["--policy", "--ttl", "--refresh-before", "--private-key"]) {
    assert.throws(() => parseCli(flatCli([flag, "123"])), /unknown option/);
  }
  assert.throws(() => parseCli(flatCli(["--account", `0x${"ab".repeat(32)}`])), /account name/);
  assert.throws(() => parseCli(flatCli(["--reference-pool", referencePool])), /supplied together/);
  assert.throws(() => parseCli(flatCli(["--divergence-threshold-bps", "1000"])), /threshold/);
});

test("CLI rejects impossible, conflicting or overlapping calendar inputs", () => {
  assert.throws(() => parseCli(equityCli(["--holidays", "2026-02-30"])), /does not exist/);
  assert.throws(
    () => parseCli(equityCli(["--holidays", "2026-11-27", "--early-closes", "2026-11-27@13:00"])),
    /conflicting/,
  );
  assert.throws(() => parseCli(equityCli(["--early-closes", "2026-11-27@10:00"])), /overlap/);
  assert.throws(() => parseCli(equityCli(["--early-closes", "2026-11-27@09:30"])), /after 09:30/);
  assert.throws(() => parseCli(flatCli(["--holidays", "2026-07-03"])), /equity/);
  const calendar = parseCli(
    equityCli(["--early-closes", "2026-11-27@13:00", "--holidays", "2026-07-03"]),
  );
  assert.equal(baselineForTimestamp(timestamp("2026-11-27T18:00:00Z"), calendar).feePips, 2000n);
});
